<#
  End to end in SOLIDWORKS 2025 (tag SolidWorks; run with
  tests\Run-Tests.ps1 -SolidWorks). Needs SOLIDWORKS installed; starts it,
  or uses the one that's running.

  Installs the built macros (ClaudeReviewDrawing.swp, demo\
  BuildDemoDrawing.swp - they must match their .bas files) into a folder
  whose path has spaces, "&" and a non-ASCII letter, then, as a user
  would:
    1. runs the demo macro, which builds DEMO-100 and its drawing;
    2. runs the review macro on that drawing, and checks the run folder
       it exports: the PDF, drawing-data.md (the planted mistakes must be
       pre-flagged), the prompt, and old run folders cleaned up;
    3. lets the macro start run-review.ps1, as it does for every review.
       Here a stand-in records how it was started, then runs the real
       run-review.ps1 with the fake Claude Code, so the report is made
       from the real export without using Claude;
    4. runs the review macro without its checklist, on a part, and with
       nothing open, and checks what it tells the user.
  Message boxes are answered by tests\lib\SwHarness.cs, which records
  their text.

  CRD_SW_PROGID picks another SOLIDWORKS version (default
  SldWorks.Application.33 = 2025). CRD_UPDATE_FIXTURES=1 copies the
  export to tests\fixtures\demo. CRD_KEEP_E2E=1 keeps the run folders.
#>

BeforeDiscovery {
    Import-Module (Join-Path $PSScriptRoot 'lib\VbaApi.psm1') -Force
    $script:NoSolidWorks = -not (Find-SolidWorksInterop)
}

Describe 'Review with Claude in SOLIDWORKS' -Tag 'SolidWorks' -Skip:$NoSolidWorks {
    BeforeAll {
        Import-Module (Join-Path $PSScriptRoot 'TestHelpers.psm1') -Force
        Import-Module (Join-Path $PSScriptRoot 'lib\VbaApi.psm1') -Force
        $repo = Get-RepoRoot
        Import-Module (Join-Path $repo 'tools\SwpSource.psm1') -Force
        $script:Repo = $repo
        $script:ProgId = if ($env:CRD_SW_PROGID) { $env:CRD_SW_PROGID } else { 'SldWorks.Application.33' }
        $script:Utf8 = New-Object System.Text.UTF8Encoding $false

        # The built macros must hold the code in src\ and demo\.
        foreach ($m in @(@('ClaudeReviewDrawing.swp', 'src\ClaudeReviewDrawing.bas'), @('demo\BuildDemoDrawing.swp', 'demo\BuildDemoDrawing.bas'))) {
            $swp = Join-Path $repo $m[0]
            if (-not (Test-Path -LiteralPath $swp)) { throw "$($m[0]) is missing. Build it in SOLIDWORKS from $($m[1]) (README: Or build from source)." }
            $c = Compare-SwpSource -Swp $swp -Bas (Join-Path $repo $m[1])
            if (-not $c.Match) { throw "$($m[0]) isn't built from the current $($m[1]); re-import the .bas, compile and save. $($c.Detail)" }
        }

        $interop = Find-SolidWorksInterop
        $dlls = @((Join-Path $interop 'SolidWorks.Interop.sldworks.dll'), (Join-Path $interop 'SolidWorks.Interop.swconst.dll'))
        if (-not ('ClaudeReview.Tests.SwHarness' -as [type])) {
            foreach ($d in $dlls) { Add-Type -Path $d }
            Add-Type -Path (Join-Path $PSScriptRoot 'lib\SwHarness.cs') -ReferencedAssemblies ($dlls + 'System.Drawing')
        }
        $script:H = [ClaudeReview.Tests.SwHarness]

        # Install folder: spaces, "&" and a non-ASCII letter in the path.
        $script:Ws = Join-Path (Get-TestOut 'sw-e2e') ("Macros & Pr" + [char]0x00FC + "fung")
        if (Test-Path -LiteralPath $Ws) { Remove-Item -LiteralPath $Ws -Recurse -Force }
        $script:Install = Join-Path $Ws 'Claude Review'
        New-Item -ItemType Directory -Force -Path (Join-Path $Install 'demo') | Out-Null
        Copy-Item -LiteralPath (Join-Path $repo 'ClaudeReviewDrawing.swp'), (Join-Path $repo 'review-instructions.md') -Destination $Install
        Copy-Item -LiteralPath (Join-Path $repo 'demo\BuildDemoDrawing.swp') -Destination (Join-Path $Install 'demo')
        $script:ReviewSwp = Join-Path $Install 'ClaudeReviewDrawing.swp'
        $script:DemoSwp = Join-Path $Install 'demo\BuildDemoDrawing.swp'
        $script:Drawing = Join-Path $Install 'demo\DEMO-100.SLDDRW'
        $script:Part = Join-Path $Install 'demo\DEMO-100.SLDPRT'

        # Stand-in for run-review.ps1: records how the macro started it,
        # then runs the real script with the fake Claude Code.
        $script:CallLog = Join-Path $Ws 'run-review-calls'
        New-Item -ItemType Directory -Force -Path $CallLog | Out-Null
        $config = [ordered]@{
            Script = (Join-Path $repo 'run-review.ps1')
            Path = (Get-FakeClaudeDir) + ';' + (Get-PathWithoutClaude)
            Review = (Join-Path $PSScriptRoot 'fixtures\reviews\standard.md')
            Calls = $CallLog
        }
        [IO.File]::WriteAllText((Join-Path $Install 'stub-config.json'), ($config | ConvertTo-Json), $Utf8)
        $stub = @'
param([string]$Folder)
# Test stand-in for run-review.ps1 (tests\SolidWorks.Tests.ps1).
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$cfg = [IO.File]::ReadAllText((Join-Path $here 'stub-config.json')) | ConvertFrom-Json
$name = Split-Path $Folder -Leaf
$call = [ordered]@{ Folder = $Folder; CommandLine = [Environment]::CommandLine; Cwd = (Get-Location).Path; PSVersion = $PSVersionTable.PSVersion.ToString() }
$utf8 = New-Object System.Text.UTF8Encoding $false
[IO.File]::WriteAllText((Join-Path $cfg.Calls "$name.json"), ($call | ConvertTo-Json), $utf8)
$env:PATH = $cfg.Path
$env:FAKE_CLAUDE_REVIEW = $cfg.Review
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $cfg.Script -Folder $Folder -NoOpen -NoDialog
[IO.File]::WriteAllText((Join-Path $cfg.Calls "$name.exit"), [string]$LASTEXITCODE, $utf8)
'@
        [IO.File]::WriteAllText((Join-Path $Install 'run-review.ps1'), $stub, [Text.Encoding]::ASCII)

        # Run folders: old ones to clean up, and a list to remove after.
        $script:RunRoot = Join-Path ([IO.Path]::GetTempPath()) 'ClaudeDrawingReview'
        New-Item -ItemType Directory -Force -Path $RunRoot | Out-Null
        $script:Before = @(Get-ChildItem -LiteralPath $RunRoot -Directory | ForEach-Object FullName)
        $old = (Get-Date).AddDays(-30)
        $script:Seeds = @{
            OldMarked = Join-Path $RunRoot 'E2E-SEED-OLD_20200101-000000'
            OldUnmarked = Join-Path $RunRoot 'E2E-SEED-NOMARK_20200101-000000'
            NewMarked = Join-Path $RunRoot ('E2E-SEED-NEW_' + (Get-Date).ToString('yyyyMMdd') + '-000000')
        }
        foreach ($k in $Seeds.Keys) {
            New-Item -ItemType Directory -Force -Path $Seeds[$k] | Out-Null
            [IO.File]::WriteAllText((Join-Path $Seeds[$k] 'note.txt'), 'test seed')
            if ($k -ne 'OldUnmarked') { [IO.File]::WriteAllText((Join-Path $Seeds[$k] '.claude-review-run'), 'seed') }
            if ($k -like 'Old*') { (Get-Item -LiteralPath $Seeds[$k]).LastWriteTime = $old }
        }

        # SOLIDWORKS
        $script:StartedSolidWorks = -not (Get-Process SLDWORKS -ErrorAction SilentlyContinue)
        Write-Host "    Connecting to $ProgId$(if ($StartedSolidWorks) { ' (starting it)' }) ..."
        $H::Connect($ProgId, 600)
        $script:SwPid = $H::ProcessId()
        Write-Host "    SOLIDWORKS $($H::Revision())"
        $script:DocsBefore = @($H::OpenDocuments())

        function script:Invoke-Macro([string]$swp, [int]$timeout = 300) {
            $base = [IO.Path]::GetFileNameWithoutExtension($swp)
            $module = @(Get-SwpModule $swp | Where-Object { $_.Name -match ('^' + [regex]::Escape($base) + '\d*$') })[0].Name
            $r = $H::RunMacro($ProgId, $SwPid, $swp, $module, 'Main', $timeout, (Join-Path $Ws "timeout-$base.png"))
            $shown = ($r.Dialogs | ForEach-Object { '[' + $_.Title + '] ' + (($_.Text -split "`n")[0]) }) -join ' | '
            Write-Host ("    {0}: {1:0.0} s. {2}" -f $base, $r.Seconds, $shown)
            return $r
        }
        # The run folder named in the macro's "Folder: ..." line.
        function script:Get-RunFolder($run) {
            foreach ($d in $run.Dialogs) { if ($d.Text -match '(?m)^Folder:\s*(.+?)\s*$') { return $Matches[1] } }
            foreach ($d in $run.Dialogs) { if ($d.Text -match '(?m)^Files:\s*(.+?)\s*$') { return $Matches[1] } }
            return $null
        }
        function script:Wait-Report([string]$folder, [int]$seconds = 180) {
            $exit = Join-Path $CallLog ((Split-Path $folder -Leaf) + '.exit')
            $t = [Diagnostics.Stopwatch]::StartNew()
            while (-not (Test-Path -LiteralPath $exit) -and $t.Elapsed.TotalSeconds -lt $seconds) { Start-Sleep -Milliseconds 500 }
            if (-not (Test-Path -LiteralPath $exit)) { return $null }
            return [int][IO.File]::ReadAllText($exit)
        }

        # 1. The demo drawing
        foreach ($p in $Drawing, $Part) { [void]$H::Close($p) }
        $script:DemoRun = Invoke-Macro $DemoSwp
        $script:ActiveAfterDemo = $H::ActiveDocument()
        $script:DirtyBefore = $H::IsDirty($Drawing)

        # 2. The review
        $script:ReviewRun = Invoke-Macro $ReviewSwp
        $script:Run = Get-RunFolder $ReviewRun
        $script:ActiveAfterReview = $H::ActiveDocument()
        $script:DirtyAfter = $H::IsDirty($Drawing)
        $script:ReportExit = $null
        if ($Run) { $script:ReportExit = Wait-Report $Run }
        $script:Data = ''
        if ($Run -and (Test-Path -LiteralPath (Join-Path $Run 'drawing-data.md'))) {
            $script:Data = [IO.File]::ReadAllText((Join-Path $Run 'drawing-data.md'))
        }
        if ($env:CRD_UPDATE_FIXTURES -and $Run) {
            $fx = Join-Path $PSScriptRoot 'fixtures\demo'
            New-Item -ItemType Directory -Force -Path $fx | Out-Null
            foreach ($f in 'DEMO-100.pdf', 'drawing-data.md', 'prompt.txt') { Copy-Item -LiteralPath (Join-Path $Run $f) -Destination $fx -Force }
            Write-Host "    Updated tests\fixtures\demo from $Run"
        }
    }

    AfterAll {
        if ($H) {
            foreach ($p in $Part, $Drawing) { try { [void]$H::Close($p) } catch { } }
            if ($StartedSolidWorks) { try { $H::Exit() } catch { } }
        }
        if ($Seeds) { foreach ($s in $Seeds.Values) { Remove-Item -LiteralPath $s -Recurse -Force -ErrorAction SilentlyContinue } }
        if (-not $env:CRD_KEEP_E2E -and $RunRoot) {
            foreach ($d in Get-ChildItem -LiteralPath $RunRoot -Directory -ErrorAction SilentlyContinue) {
                if ($Before -notcontains $d.FullName -and $d.Name -like 'DEMO-100_*') { Remove-Item -LiteralPath $d.FullName -Recurse -Force -ErrorAction SilentlyContinue }
            }
        }
    }

    Context 'the demo macro' {
        It 'finishes and says the drawing is ready' {
            $DemoRun.Finished | Should -BeTrue -Because $DemoRun.Exception
            $DemoRun.Returned | Should -BeTrue
            $DemoRun.Dialogs.Count | Should -Be 1 -Because ($DemoRun.Dialogs -join "`n")
            $DemoRun.Dialogs[0].Title | Should -Be 'Build demo drawing'
            $DemoRun.Dialogs[0].Text | Should -Match 'The demo drawing is ready'
        }
        It 'saves DEMO-100 next to itself and leaves the drawing open' {
            $Drawing | Should -Exist
            $Part | Should -Exist
            $ActiveAfterDemo | Should -Be "$Drawing|3"
            $DirtyBefore | Should -BeFalse
        }
    }

    Context 'the review macro' {
        It 'finishes and says Claude is reviewing in the background, with nothing it could not read' {
            $ReviewRun.Finished | Should -BeTrue -Because $ReviewRun.Exception
            $ReviewRun.Dialogs.Count | Should -Be 1 -Because ($ReviewRun.Dialogs -join "`n")
            $ReviewRun.Dialogs[0].Title | Should -Be 'Review with Claude'
            $ReviewRun.Dialogs[0].Text | Should -Match 'Claude is reviewing the drawing in the background'
        }
        It 'makes a run folder of its own under %TEMP%\ClaudeDrawingReview' {
            $Run | Should -Not -BeNullOrEmpty
            Split-Path $Run -Parent | Should -Be $RunRoot.TrimEnd('\')
            Split-Path $Run -Leaf | Should -Match '^DEMO-100_\d{8}-\d{6}$'
            Join-Path $Run '.claude-review-run' | Should -Exist
        }
        It 'leaves the drawing as it was: open, active and unchanged' {
            $ActiveAfterReview | Should -Be "$Drawing|3"
            $DirtyAfter | Should -BeFalse
            # Nothing new beside the drawing (SOLIDWORKS's own ~$ lock files aside).
            @(Get-ChildItem -LiteralPath (Split-Path $Drawing) -Name -Force | Where-Object { $_ -notlike '~$*' }) |
                Should -Be @('BuildDemoDrawing.swp', 'DEMO-100.SLDDRW', 'DEMO-100.SLDPRT')
        }
        It 'exports the drawing as a one-page PDF' {
            $pdf = Join-Path $Run 'DEMO-100.pdf'
            $pdf | Should -Exist
            $bytes = [IO.File]::ReadAllBytes($pdf)
            $bytes.Length | Should -BeGreaterThan 10KB
            [Text.Encoding]::ASCII.GetString($bytes, 0, 5) | Should -Be '%PDF-'
            ([regex]::Matches([Text.Encoding]::ASCII.GetString($bytes), '/Type\s*/Page(?!s)')).Count | Should -Be 1
        }
        It 'writes the prompt for a one-sheet drawing' {
            $prompt = [IO.File]::ReadAllText((Join-Path $Run 'prompt.txt'))
            $prompt | Should -Match 'Please review the SOLIDWORKS drawing "DEMO-100" \(1 sheet\)'
            $prompt | Should -Match 'DEMO-100\.pdf and drawing-data\.md'
            $prompt | Should -Match 'Reply with the review only\.$'
        }
        It 'puts the checklist first, then marks where drawing content starts' {
            $instr = [IO.File]::ReadAllText((Join-Path $Repo 'review-instructions.md'))
            $Data.StartsWith($instr.TrimEnd()) | Should -BeTrue
            $Data | Should -Match '> \*\*Drawing content starts here\.\*\*'
            $Data | Should -Match '(?m)^# Drawing data: DEMO-100\r?$'
        }
        It 'reads units, sheets and the paper' {
            $Data | Should -Match 'Length units: in \(2 decimal places\)'
            $Data | Should -Match '(?m)^- Sheets: 1\r?$'
            $Data | Should -Match '(?m)^## Sheet 1: '
            $Data | Should -Match 'Paper: ANSI B, 17 x 11 in'
            $Data | Should -Match 'Sheet scale: 1:1'
            $Data | Should -Match 'Projection: third angle'
        }
        It 'pre-flags the overridden 4.00 length that shows 4.10' {
            $Data | Should -Match '(?m)^- Overridden dimension values: 1\r?$'
            $Data | Should -Match 'D1@Sketch1@DEMO-100\.Part shows 4\.1 in, model value 4\.0 in'
            $Data | Should -Match '\| D1@Sketch1@DEMO-100\.Part \| <DIM> \| 4\.0 in \| [^|]+ \| OVERRIDDEN \(shows 4\.1 in\); model dim \| \d+,\d+ \|'
        }
        It 'pre-flags the blank title-block properties, and only those' {
            $Data | Should -Match 'Title-block properties that are blank \([^)]*\): 3'
            foreach ($p in 'Material', 'DrawnBy', 'DrawnDate') { $Data | Should -Match "(?m)^  - $p \(blank or missing on the drawing and DEMO-100\.SLDPRT\)" }
            foreach ($p in 'PartNumber', 'Description', 'Revision') { $Data | Should -Not -Match "(?m)^  - $p \(blank" }
            $Data | Should -Match '\| PartNumber \| DEMO-100 \| DEMO-100 \|'
            $Data | Should -Match '\| Description \| MOUNTING PLATE \| MOUNTING PLATE \|'
        }
        It 'finds no dangling annotations or undefined datums' {
            $Data | Should -Match '(?m)^- Dangling annotations: none'
            $Data | Should -Match '(?m)^- Datum letters used in GD&T frames with no datum tag on the drawing: none'
        }
        It 'lists the views with their areas and every dimension' {
            @([regex]::Matches($Data, '(?m)^### View: ')).Count | Should -Be 4
            @([regex]::Matches($Data, '(?m)^- Area: x \d+-\d+, y \d+-\d+')).Count | Should -Be 4
            $Data | Should -Match '(?m)^- Dimensions read: 7\r?$'
            $Data | Should -Match '\| <MOD-DIAM><DIM> \| 0\.257 in \|'
            $Data | Should -Match '\| <MOD-DIAM><DIM> \| 0\.5 in \|'
        }
        It 'gives positions that match where the demo put things' {
            # The note's anchor is at 0.8 x 1.9 in on a 17 x 11 in sheet.
            $Data | Should -Match 'DEBUR ALL EDGES\. _\(at (\d+),(\d+)\)_'
            [regex]::Match($Data, 'DEBUR ALL EDGES\. _\(at (\d+),(\d+)\)_') | ForEach-Object {
                [int]$_.Groups[1].Value | Should -BeIn (4..6)
                [int]$_.Groups[2].Value | Should -BeIn (82..84)
            }
            # The overridden length sits by the front view.
            $m = [regex]::Match($Data, 'OVERRIDDEN[^|]*\| (\d+),(\d+) \|')
            $front = [regex]::Match($Data, '(?s)### View: Drawing View1.*?- Area: x (\d+)-(\d+), y (\d+)-(\d+)')
            [int]$m.Groups[1].Value | Should -BeGreaterOrEqual ([int]$front.Groups[1].Value)
            [int]$m.Groups[1].Value | Should -BeLessOrEqual ([int]$front.Groups[2].Value)
            [Math]::Abs([int]$m.Groups[2].Value - [int]$front.Groups[4].Value) | Should -BeLessOrEqual 6
        }
        It 'reads the title block text and reports no export problems' {
            $Data | Should -Match 'DO NOT SCALE DRAWING'
            $Data | Should -Match '(?m)^## Export notes\r?\n- Everything was read without errors\.'
        }
        It 'deletes its own old run folders, and nothing else' {
            $Seeds.OldMarked | Should -Not -Exist
            $Seeds.OldUnmarked | Should -Exist
            $Seeds.NewMarked | Should -Exist
        }
    }

    Context 'the background review it starts' {
        BeforeAll {
            $script:Call = $null
            $callFile = if ($Run) { Join-Path $CallLog ((Split-Path $Run -Leaf) + '.json') }
            if ($callFile -and (Test-Path -LiteralPath $callFile)) { $script:Call = [IO.File]::ReadAllText($callFile) | ConvertFrom-Json }
        }
        It 'starts run-review.ps1 from beside the macro in Windows PowerShell 5.1, in the run folder' {
            $Call | Should -Not -BeNullOrEmpty
            $Call.Folder | Should -Be $Run
            $Call.Cwd.TrimEnd('\') | Should -Be $Run.TrimEnd('\')
            $Call.PSVersion | Should -Match '^5\.1\.'
            $Call.CommandLine | Should -Match ([regex]::Escape('-File "' + (Join-Path $Install 'run-review.ps1') + '"'))
            $Call.CommandLine | Should -Match '-WindowStyle Hidden'
            $Call.CommandLine | Should -Match '-ExecutionPolicy Bypass'
        }
        It 'turns the export into a report with balloons on the drawing' {
            $ReportExit | Should -Be 0 -Because ([IO.File]::ReadAllText((Join-Path $Run 'claude-log.txt')))
            Join-Path $Run 'sheet-1.png' | Should -Exist
            $m = Get-ReportModel (Join-Path $Run 'review.html')
            $m.Title | Should -Be 'Drawing review: DEMO-100'
            $m.Sheets | Should -Be @('sheet-1.png')
            # standard.md: 5 findings with a pin, one of them on sheet 2.
            $m.Pins.Count | Should -Be 4
        }
    }

    Context 'without its checklist' {
        BeforeAll {
            Move-Item -LiteralPath (Join-Path $Install 'review-instructions.md') -Destination (Join-Path $Ws 'review-instructions.md.away') -Force
            $script:NoChecklist = Invoke-Macro $ReviewSwp
            $script:NoChecklistRun = Get-RunFolder $NoChecklist
            Move-Item -LiteralPath (Join-Path $Ws 'review-instructions.md.away') -Destination (Join-Path $Install 'review-instructions.md') -Force
            if ($NoChecklistRun) { [void](Wait-Report $NoChecklistRun) }
        }
        It 'uses the built-in checklist and says so' {
            $NoChecklist.Dialogs.Count | Should -Be 2 -Because ($NoChecklist.Dialogs -join "`n")
            $NoChecklist.Dialogs[1].Text | Should -Match "not everything could be read"
            $NoChecklist.Dialogs[1].Text | Should -Match 'review-instructions\.md was not found next to the macro'
            $data = [IO.File]::ReadAllText((Join-Path $NoChecklistRun 'drawing-data.md'))
            $data | Should -Match '^# Drawing review \(short built-in checklist\)'
            $data | Should -Match '\| # \| Severity \| Sheet \| Pin \| View / location \| Issue \| Suggested fix \|'
            $data | Should -Match 'review-instructions\.md was not found next to the macro'
        }
    }

    Context 'on something that is not a drawing' {
        It 'says so when a part is active, and exports nothing' {
            $H::Open($Part) | Should -BeTrue
            $before = @(Get-ChildItem -LiteralPath $RunRoot -Directory).Count
            $r = Invoke-Macro $ReviewSwp
            [void]$H::Close($Part)
            $r.Dialogs.Count | Should -Be 1
            $r.Dialogs[0].Text | Should -Match 'The active document is not a drawing'
            @(Get-ChildItem -LiteralPath $RunRoot -Directory).Count | Should -Be $before
        }
        It 'says so when nothing is open' {
            foreach ($p in $Part, $Drawing) { [void]$H::Close($p) }
            $others = @($H::OpenDocuments())
            if ($others.Count -gt 0) { Set-ItResult -Skipped -Because "other documents are open in SOLIDWORKS: $($others -join ', ')"; return }
            $r = Invoke-Macro $ReviewSwp
            $r.Dialogs.Count | Should -Be 1
            $r.Dialogs[0].Text | Should -Match 'No document is open'
        }
    }
}
