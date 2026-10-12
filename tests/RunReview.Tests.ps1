<#
  run-review.ps1: the background review and the report it writes.

  The parsing functions are loaded from the script without running it.
  The script itself runs as the macro runs it - a child Windows
  PowerShell 5.1 - against the fake claude.exe (tests\lib\FakeClaude.cs).
#>

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'TestHelpers.psm1') -Force
    $script:RunReview = Join-Path (Get-RepoRoot) 'run-review.ps1'
    $script:Reviews = Join-Path $PSScriptRoot 'fixtures\reviews'
    # Script-level variables the functions use.
    $inv = [Globalization.CultureInfo]::InvariantCulture
    . (Get-ScriptFunctions $RunReview)

    function script:Lines([string]$text) { return ,($text -split "`r?`n") }
    # Non-ASCII test text, built from code points: Windows PowerShell 5.1
    # reads a BOM-less script in the ANSI code page.
    $script:Dia = [string][char]0x00D8; $script:Pm = [string][char]0x00B1; $script:Deg = [string][char]0x00B0
    $script:Mid = [string][char]0x00B7; $script:Ue = [string][char]0x00FC
}

Describe 'Get-Pin' {
    It 'reads "<text>"' -TestCases @(
        @{ Text = '62,41';             X = 62;   Y = 41 }
        @{ Text = '62.5, 41.25';       X = 62.5; Y = 41.25 }
        @{ Text = '62%, 41%';          X = 62;   Y = 41 }
        @{ Text = '62 %,41 %';         X = 62;   Y = 41 }
        @{ Text = '5;95';              X = 5;    Y = 95 }
        @{ Text = '5/95';              X = 5;    Y = 95 }
        @{ Text = '5 95';              X = 5;    Y = 95 }
        @{ Text = '`62,41`';           X = 62;   Y = 41 }
        @{ Text = '62,41 (D1 at)';     X = 62;   Y = 41 }
        @{ Text = '120,5';             X = 100;  Y = 5 }
    ) {
        $p = Get-Pin $Text
        $p | Should -Not -BeNullOrEmpty
        $p[0] | Should -Be $X
        $p[1] | Should -Be $Y
    }

    It 'gives no pin for "<Text>"' -TestCases @(
        @{ Text = '-' }, @{ Text = '' }, @{ Text = 'n/a' }, @{ Text = 'whole sheet' }, @{ Text = '62' }
    ) {
        Get-Pin $Text | Should -BeNullOrEmpty
    }
}

Describe 'Get-Severity' {
    It 'maps "<Text>" to <Sev>' -TestCases @(
        @{ Text = 'Critical'; Sev = 'critical' }, @{ Text = '**CRITICAL**'; Sev = 'critical' }
        @{ Text = 'Major'; Sev = 'major' }, @{ Text = 'Minor'; Sev = 'minor' }
        @{ Text = 'Info'; Sev = 'info' }, @{ Text = ''; Sev = 'info' }
    ) {
        Get-Severity $Text | Should -Be $Sev
    }
}

Describe 'Split-TableRow' {
    It 'splits cells and keeps escaped pipes' {
        $c = Split-TableRow '| 1 | a \| b | c |'
        $c.Count | Should -Be 3
        $c[1] | Should -Be 'a | b'
    }
    It 'handles a row without outer pipes' {
        $c = Split-TableRow 'a | b'
        $c | Should -Be @('a', 'b')
    }
}

Describe 'Get-ReviewParts' {
    It 'finds the findings table and splits the answer around it' {
        $parts = Get-ReviewParts (Lines ([IO.File]::ReadAllText((Join-Path $Reviews 'standard.md'))))
        $parts.Findings.Count | Should -Be 6
        ($parts.Pre -join "`n") | Should -Match 'Verdict: Needs rework'
        ($parts.Post -join "`n") | Should -Match 'Looks good'
        $parts.Findings[3].SheetNo | Should -Be 2
        $parts.Findings[5].Pin | Should -BeNullOrEmpty
        $parts.Findings[0].Sev | Should -Be 'critical'
        $parts.Findings[0].Fix | Should -Match 'Remove the override'
    }

    It 'recognises other header wordings' {
        $md = @(
            '| No. | Severity | Sheet | Position | Location | Finding | Recommendation |'
            '|---|---|---|---|---|---|---|'
            '| 1 | Major | 1 | 10,20 | Front | Something | Do this |'
        )
        $f = (Get-ReviewParts $md).Findings[0]
        $f.Num | Should -Be '1'
        $f.Pin | Should -Be @(10, 20)
        $f.Loc | Should -Be 'Front'
        $f.Issue | Should -Be 'Something'
        $f.Fix | Should -Be 'Do this'
    }

    It 'skips a table that has no severity column' {
        $md = @(
            '| Item | Checked |', '|---|---|', '| Title block | yes |', '',
            '| # | Severity | Sheet | Pin | View / location | Issue | Suggested fix |'
            '|---|---|---|---|---|---|---|'
            '| 1 | Minor | 1 | 1,1 | Notes | Real finding | Fix it |'
        )
        $parts = Get-ReviewParts $md
        $parts.Findings.Count | Should -Be 1
        $parts.Findings[0].Issue | Should -Be 'Real finding'
        ($parts.Pre -join "`n") | Should -Match 'Title block'
    }

    It 'returns nothing when there is no findings table' {
        Get-ReviewParts (Lines ([IO.File]::ReadAllText((Join-Path $Reviews 'no-table.md')))) | Should -BeNullOrEmpty
    }

    It 'folds unescaped pipes in the Issue back into it, so later columns line up' {
        $md = @(
            '| # | Severity | Sheet | Pin | View / location | Issue | Suggested fix |'
            '|---|---|---|---|---|---|---|'
            '| 1 | Critical | 1 | 5,5 | Front | Frame [ FLAT | 0.05 | A ] has no datum | Add datum A |'
        )
        $f = (Get-ReviewParts $md).Findings[0]
        $f.Issue | Should -Be 'Frame [ FLAT | 0.05 | A ] has no datum'
        $f.Fix | Should -Be 'Add datum A'
    }

    It 'reads the sheet number from "<Text>"' -TestCases @(
        @{ Text = '2'; No = 2 }, @{ Text = 'Sheet 2'; No = 2 }, @{ Text = 'Sheet2'; No = 2 }
        @{ Text = '2 (Detail)'; No = 2 }, @{ Text = ''; No = 1 }, @{ Text = '-'; No = 1 }
    ) {
        $md = @(
            '| # | Severity | Sheet | Pin | View / location | Issue | Suggested fix |'
            '|---|---|---|---|---|---|---|'
            "| 1 | Minor | $Text | 5,5 | Front | X | Y |"
        )
        (Get-ReviewParts $md).Findings[0].SheetNo | Should -Be $No
    }

    It 'numbers findings without a number and strips bold from numbers' {
        $md = @(
            '| # | Severity | Issue |', '|---|---|---|', '| **7** | Minor | A |', '|  | Minor | B |'
        )
        $f = (Get-ReviewParts $md).Findings
        $f[0].Num | Should -Be '7'
        $f[1].Num | Should -Be '2'
    }
}

Describe 'Remove-VerdictLine' {
    It 'keeps a summary on the next line' {
        $out = Remove-VerdictLine @('**Verdict: Needs minor fixes**', 'Two small cleanups.')
        $out | Should -Be @('Two small cleanups.')
    }
    It 'keeps a summary on the same line: "<Line>"' -TestCases @(
        @{ Line = 'Verdict: Needs minor fixes - small cleanup only.'; Rest = 'small cleanup only.' }
        @{ Line = '**Verdict:** Ready to release. All good.'; Rest = 'All good.' }
        @{ Line = 'Verdict: Needs rework: the hole pattern is undefined.'; Rest = 'the hole pattern is undefined.' }
    ) {
        Remove-VerdictLine @($Line) | Should -Be @($Rest)
    }
    It 'drops only the first verdict line' {
        $out = Remove-VerdictLine @('Verdict: Needs rework', 'The verdict above is final.')
        $out | Should -Be @('The verdict above is final.')
    }
}

Describe 'Markdown to HTML' {
    It 'encodes HTML and formats code, bold and italic' {
        ConvertTo-Html-Inline 'a <b> & "c"' | Should -Be 'a &lt;b&gt; &amp; &quot;c&quot;'
        ConvertTo-Html-Inline 'use `x<1>` here' | Should -Be 'use <code>x&lt;1&gt;</code> here'
        ConvertTo-Html-Inline '**bold** and *italic*' | Should -Be '<strong>bold</strong> and <em>italic</em>'
        ConvertTo-Html-Inline '2*3*4 and a * b' | Should -Be '2*3*4 and a * b'
    }
    It 'turns headings, bold lines, lists and tables into blocks' {
        $html = ConvertTo-Html-Blocks @(
            '## Looks good', '- one', '  continued', '- two', '',
            '**Questions**', '1. first?', '2. second?', '',
            '| A | B |', '|---|---|', '| 1 | 2 |', '',
            'Plain paragraph', 'on two lines.'
        )
        $html | Should -Match '<h2 class="sec-head sec-good">Looks good</h2>'
        $html | Should -Match '<ul class="list list-good">\s*<li>one continued</li>\s*<li>two</li>'
        $html | Should -Match '<h2 class="sec-head sec-questions">Questions</h2>'
        $html | Should -Match '<ol class="list list-questions">\s*<li>first\?</li>'
        $html | Should -Match '<table><thead><tr><th>A</th><th>B</th></tr></thead><tbody>\s*<tr><td>1</td><td>2</td></tr>'
        $html | Should -Match '<p>Plain paragraph on two lines\.</p>'
    }
}

Describe 'review.html from a review' {
    BeforeAll {
        $script:Std = New-TestRunFolder -Parent (Join-Path $TestDrive 'std') -Review (Join-Path $Reviews 'standard.md') -Pages 2
        $script:StdRun = Invoke-RunReview -Folder $Std -RenderOnly
        $script:StdModel = Get-ReportModel $StdRun.Html
    }

    It 'renders without errors' {
        $StdRun.ExitCode | Should -Be 0
        $StdRun.Log | Should -BeNullOrEmpty
        $StdRun.StdErr | Should -BeNullOrEmpty
    }
    It 'shows the drawing name, verdict, counts and summary' {
        $StdModel.Title | Should -Be 'Drawing review: TEST-100'
        $StdModel.Verdict | Should -Be 'Needs rework'
        $StdModel.VerdictClass | Should -Be 'rework'
        $StdModel.Counts | Should -Match '2 critical . 2 major . 2 minor'
        $StdModel.Summary | Should -Match '^The 4\.00 length is overridden'
    }
    It 'lists every finding in order with its severity and location' {
        $StdModel.Items.Id | Should -Be @('1', '2', '3', '4', '5', '6')
        $StdModel.Items.Sev | Should -Be @('critical', 'critical', 'major', 'major', 'minor', 'minor')
        $StdModel.Items[0].Where | Should -Be "Sheet 1 $Mid Drawing View1, overall length"
        $StdModel.Items[0].Issue | Should -Match 'shows 4\.10'
        $StdModel.Items[1].Fix | Should -Be 'Add 4X to the callout and dimension the hole pattern.'
    }
    It 'makes one sheet image per PDF page' {
        $StdModel.Sheets | Should -Be @('sheet-1.png', 'sheet-2.png')
        Join-Path $Std 'sheet-2.png' | Should -Exist
    }
    It 'puts a balloon on the right sheet at each Pin' {
        $StdModel.Pins.Count | Should -Be 5
        $p = $StdModel.Pins | Where-Object Id -eq '1'
        $p.Sheet | Should -Be 1; $p.X | Should -Be 30; $p.Y | Should -Be 62
        ($StdModel.Pins | Where-Object Id -eq '4').Sheet | Should -Be 2
    }
    It 'gives a finding without a Pin a dashed balloon and no pin' {
        $StdModel.Items[5].NoPin | Should -BeTrue
        $StdModel.Pins.Id | Should -Not -Contain '6'
    }
    It 'has filter tabs for the severities present' {
        $StdModel.Tabs | Should -Be @('all', 'critical', 'major', 'minor')
    }
    It 'shows Looks good and Questions after the findings' {
        $StdModel.Rest | Should -Match 'sec-good'
        $StdModel.Rest | Should -Match '<ol class="list list-questions">'
    }
    It 'links the PDF and the data file' {
        $StdModel.Html | Should -Match 'href="TEST-100\.pdf"'
        $StdModel.Html | Should -Match 'href="drawing-data\.md"'
    }

    Context 'edge cases' {
        BeforeAll {
            $script:Edge = New-TestRunFolder -Parent (Join-Path $TestDrive 'edge') -Name 'EDGE' -Review (Join-Path $Reviews 'edge-cases.md')
            $script:EdgeRun = Invoke-RunReview -Folder $Edge -RenderOnly
            $script:EdgeModel = Get-ReportModel $EdgeRun.Html
        }
        It 'renders' { $EdgeRun.ExitCode | Should -Be 0 }
        It 'keeps a summary written on the verdict line' {
            $EdgeModel.Verdict | Should -Be 'Needs minor fixes'
            $EdgeModel.Summary | Should -Be 'the drawing is close; see the notes below.'
        }
        It 'reads a Pin written with percent signs' {
            $p = $EdgeModel.Pins | Where-Object Id -eq '1'
            $p.X | Should -Be 62; $p.Y | Should -Be 41
        }
        It 'folds unescaped pipes into the Issue and unescapes \|' {
            $EdgeModel.Items[0].Issue | Should -Be 'Flatness frame reads [ <MOD-FLAT> | 0.05 | A ] with no datum A tag.'
            $EdgeModel.Items[0].Fix | Should -Be 'Add datum tag A.'
            $EdgeModel.Items[1].Issue | Should -Match 'escaped \| pipe'
        }
        It 'keeps a pin outside the sheet on the sheet' {
            ($EdgeModel.Pins | Where-Object Id -eq '2').X | Should -Be 98.5
        }
        It 'moves balloons at the same spot apart' {
            $same = @($EdgeModel.Pins | Where-Object { $_.Id -in '3', '4', '5' })
            $same.Count | Should -Be 3
            @($same | ForEach-Object { "$($_.X),$($_.Y)" } | Sort-Object -Unique).Count | Should -Be 3
        }
        It 'escapes drawing text instead of running it' {
            $EdgeModel.Html | Should -Not -Match '<img src=x'
            $EdgeModel.Html | Should -Not -Match '<script>window\.__xss'
            $EdgeModel.Items[5].Issue | Should -Match '<img src=x onerror="window\.__xss=1">'
        }
        It 'keeps symbols and formats code' {
            $EdgeModel.Items[6].Issue | Should -Match "$Dia 0\.257 $($Pm)0\.005 at 90$Deg"
            $EdgeModel.Items[6].Raw | Should -Match '2\*3\*4'
            $EdgeModel.Items[6].Raw | Should -Match '<code>code</code>'
        }
        It 'gives findings on a sheet that does not exist (<Id>) no balloon' -TestCases @(@{ Id = '8' }, @{ Id = '9' }) {
            ($EdgeModel.Items | Where-Object Id -eq $Id).NoPin | Should -BeTrue
            ($EdgeModel.Items | Where-Object Id -eq $Id).Sheet | Should -BeNullOrEmpty
            $EdgeModel.Pins.Id | Should -Not -Contain $Id
        }
    }

    Context 'other answers' {
        It 'shows an answer without a findings table as a document' {
            $d = New-TestRunFolder -Parent (Join-Path $TestDrive 'nt') -Review (Join-Path $Reviews 'no-table.md')
            $m = Get-ReportModel (Invoke-RunReview -Folder $d -RenderOnly).Html
            $m.Verdict | Should -Be 'Ready to release'
            $m.Items.Count | Should -Be 0
            $m.Tabs.Count | Should -Be 0
            $m.Rest | Should -Match 'sec-good'
            $m.Rest | Should -Match 'found nothing to change'
            $m.Rest | Should -Not -Match 'Verdict:' -Because 'the verdict is shown once, in the header'
        }
        It 'puts a "Sheet 2" finding on sheet 2 and keeps the next-line summary' {
            $d = New-TestRunFolder -Parent (Join-Path $TestDrive 'nl') -Review (Join-Path $Reviews 'summary-next-line.md') -Pages 2
            $m = Get-ReportModel (Invoke-RunReview -Folder $d -RenderOnly).Html
            $m.Verdict | Should -Be 'Needs minor fixes'
            $m.Summary | Should -Be 'Two small cleanups before release.'
            ($m.Pins | Where-Object Id -eq '1').Sheet | Should -Be 2
        }
        It 'says Needs rework when there is no verdict line but a critical finding' {
            $md = "Here is the review.`n`n| # | Severity | Issue |`n|---|---|---|`n| 1 | Critical | Wrong |`n"
            $d = New-TestRunFolder -Parent (Join-Path $TestDrive 'nv') -ReviewText $md
            (Get-ReportModel (Invoke-RunReview -Folder $d -RenderOnly).Html).Verdict | Should -Be 'Needs rework'
        }
        It 'hides the drawing pane when the folder has no PDF' {
            $d = New-TestRunFolder -Parent (Join-Path $TestDrive 'np') -Review (Join-Path $Reviews 'standard.md') -NoPdf
            $m = Get-ReportModel (Invoke-RunReview -Folder $d -RenderOnly).Html
            $m.Html | Should -Match '<body class="no-drawing">'
            $m.Html | Should -Not -Match 'class="viewer'
            $m.Items.Count | Should -Be 6
        }
    }

    Context 'sheet images' {
        It 'reuses images made from the same PDF' {
            $first = (Get-Item (Join-Path $Std 'sheet-1.png')).LastWriteTimeUtc
            (Invoke-RunReview -Folder $Std -RenderOnly).ExitCode | Should -Be 0
            (Get-Item (Join-Path $Std 'sheet-1.png')).LastWriteTimeUtc | Should -Be $first
        }
        It 'makes new images when the PDF is newer' {
            $img = Get-Item (Join-Path $Std 'sheet-1.png')
            $old = (Get-Item (Join-Path $Std 'TEST-100.pdf')).LastWriteTime.AddHours(-1)
            $img.LastWriteTime = $old
            (Invoke-RunReview -Folder $Std -RenderOnly).ExitCode | Should -Be 0
            (Get-Item (Join-Path $Std 'sheet-1.png')).LastWriteTime | Should -BeGreaterThan $old
        }
        It 'keeps balloons with a relative -Folder' {
            $d = New-TestRunFolder -Parent (Join-Path $TestDrive 'rel') -Review (Join-Path $Reviews 'standard.md') -Pages 2
            $r = Invoke-RunReview -Folder (Split-Path $d -Leaf) -WorkingDirectory (Split-Path $d -Parent) -RenderOnly
            $r.ExitCode | Should -Be 0
            (Get-ReportModel $r.Html).Pins.Count | Should -Be 5
        }
        It 'falls back to the PDF, and leaves no images behind, when the PDF cannot be rendered' {
            $d = New-TestRunFolder -Parent (Join-Path $TestDrive 'bad') -Review (Join-Path $Reviews 'standard.md') -NoPdf
            [IO.File]::WriteAllText((Join-Path $d 'TEST-100.pdf'), 'this is not a PDF')
            $r = Invoke-RunReview -Folder $d -RenderOnly
            $r.ExitCode | Should -Be 0
            $r.Log | Should -Match 'Sheet images could not be made'
            @(Get-ChildItem $d -Filter 'sheet-*.png').Count | Should -Be 0
            (Get-ReportModel $r.Html).PdfViewer | Should -BeTrue
        }
        It 'falls back to the PDF in PowerShell 7, which cannot reach the Windows PDF renderer' -Skip:(-not (Get-Command pwsh -ErrorAction SilentlyContinue)) {
            $d = New-TestRunFolder -Parent (Join-Path $TestDrive 'ps7') -Review (Join-Path $Reviews 'standard.md')
            $r = Invoke-RunReview -Folder $d -RenderOnly -Pwsh
            $r.ExitCode | Should -Be 0
            $r.Log | Should -Match 'need Windows PowerShell 5\.1'
            $m = Get-ReportModel $r.Html
            $m.PdfViewer | Should -BeTrue
            $m.Items.Count | Should -Be 6
            $m.Items[0].NoPin | Should -BeTrue
        }
    }
}

Describe 'run-review.ps1 with Claude Code' {
    BeforeAll {
        $script:Utf8 = New-Object System.Text.UTF8Encoding $false
        function script:New-Run([string]$name) {
            New-TestRunFolder -Parent (Join-Path $TestDrive $name) -Pages 2
        }
    }

    Context 'when Claude answers' {
        BeforeAll {
            $script:Dir = New-Run 'ok'
            $script:CallLog = Join-Path $TestDrive 'ok-call'
            # Non-ASCII in the answer must survive the trip unchanged.
            $script:Answer = Join-Path $TestDrive 'answer.md'
            [IO.File]::WriteAllText($Answer, ([IO.File]::ReadAllText((Join-Path $Reviews 'standard.md')) -replace '4\.10', "4.10 ($Dia $($Pm)0.01$Deg)"), $Utf8)
            $script:Run = Invoke-RunReview -Folder $Dir -FakeClaude @{ Review = $Answer; Log = $CallLog }
        }
        It 'succeeds and writes review.md and review.html' {
            $Run.ExitCode | Should -Be 0
            $Run.Log | Should -BeNullOrEmpty
            $Run.Html | Should -Not -BeNullOrEmpty
        }
        It 'saves the answer as review.md byte for byte' {
            [IO.File]::ReadAllBytes((Join-Path $Dir 'review.md')) | Should -Be ([IO.File]::ReadAllBytes($Answer))
            (Get-ReportModel $Run.Html).Items[0].Issue | Should -Match "4\.10 \($Dia $($Pm)0\.01$Deg\)"
        }
        It 'runs Claude Code read-only, confined to the run folder' {
            Get-Content (Join-Path $CallLog 'args.txt') | Should -Be @('-p', '--restricted', '--strict-mcp-config', '--tools', 'Read', '--allowedTools', 'Read')
            (Get-Content (Join-Path $CallLog 'cwd.txt')).TrimEnd('\') | Should -Be $Dir.TrimEnd('\')
        }
        It 'sends the prompt on stdin without the BOM the macro writes' {
            $sent = [IO.File]::ReadAllBytes((Join-Path $CallLog 'stdin.bin'))
            $sent[0] | Should -Not -Be 0xEF
            $Utf8.GetString($sent) | Should -Be ([IO.File]::ReadAllText((Join-Path $Dir 'prompt.txt')))
        }
        It 'cleans up its temporary files' {
            Join-Path $Dir 'prompt-stdin.txt' | Should -Not -Exist
            Join-Path $Dir 'claude-output.txt' | Should -Not -Exist
        }
    }

    It 'reports a failing Claude Code with its message and keeps an earlier review' {
        $d = New-Run 'fail'
        [IO.File]::WriteAllText((Join-Path $d 'review.md'), 'earlier review', $Utf8)
        $r = Invoke-RunReview -Folder $d -FakeClaude @{ Mode = 'fail'; Output = 'Invalid API key - Please run /login'; Exit = '1' }
        $r.ExitCode | Should -Be 1
        $r.Log | Should -Match "Claude Code's output:\s+Invalid API key"
        $r.Log | Should -Match 'ERROR: Claude Code exited with code 1\.'
        [IO.File]::ReadAllText((Join-Path $d 'review.md')) | Should -Be 'earlier review'
        $r.Html | Should -BeNullOrEmpty
    }

    It 'reports an empty answer' {
        $d = New-Run 'empty'
        $r = Invoke-RunReview -Folder $d -FakeClaude @{ Mode = 'empty' }
        $r.ExitCode | Should -Be 1
        $r.Log | Should -Match 'returned an empty review'
        Join-Path $d 'review.md' | Should -Not -Exist
    }

    It 'reports a missing Claude Code CLI' {
        $d = New-Run 'missing'
        $r = Invoke-RunReview -Folder $d -NoClaude
        $r.ExitCode | Should -Be 1
        $r.Log | Should -Match "Claude Code CLI wasn't found"
    }

    It 'stops a review that hangs, with everything it started' {
        $d = New-Run 'hang'
        $callLog = Join-Path $TestDrive 'hang-call'
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $r = Invoke-RunReview -Folder $d -FakeClaude @{ Mode = 'hang'; Log = $callLog } -TimeoutMinutes 0.05
        $sw.Elapsed.TotalSeconds | Should -BeLessThan 30
        $r.ExitCode | Should -Be 1
        $r.Log | Should -Match "hadn't finished after 0\.05 min"
        $child = [int](Get-Content (Join-Path $callLog 'child-pid.txt'))
        Get-Process -Id $child -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
    }

    It 'works in a folder whose path has spaces, & and non-ASCII letters' {
        $parent = Join-Path $TestDrive "Zeichnungen & Pr$($Ue)fung"
        $d = New-TestRunFolder -Parent $parent -Name "$($Dia)10 Platte" -Pages 2
        $r = Invoke-RunReview -Folder $d -FakeClaude @{ Review = (Join-Path $Reviews 'standard.md') }
        $r.ExitCode | Should -Be 0
        $r.Log | Should -BeNullOrEmpty
        $m = Get-ReportModel $r.Html
        $m.Title | Should -Be "Drawing review: $($Dia)10 Platte"
        $m.Pins.Count | Should -Be 5
    }
}
