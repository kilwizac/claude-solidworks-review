<#
  A real review by Claude Code (tag Live; run with tests\Run-Tests.ps1
  -Live). Takes a few minutes and counts toward your Claude plan's usage.
  Needs the Claude Code CLI, signed in; not SOLIDWORKS.

  Reviews the demo drawing as the macro exported it (tests\fixtures\demo,
  refreshed by -SolidWorks -UpdateFixtures), with today's
  review-instructions.md in place of the checklist it was exported with.
  So a change to the checklist is tested against the real model.

  Claude's wording varies from run to run, so each planted mistake is
  looked for by keywords, and the test asks for the critical one plus
  five of the six. The review is kept in tests\.out\live for reading;
  CRD_UPDATE_FIXTURES=1 also saves it as tests\fixtures\demo\review.md.
  CRD_LIVE_REUSE=<a kept review's folder> checks that review again
  without asking Claude (e.g. after changing these checks).
#>

BeforeDiscovery {
    $script:NoClaude = -not (Get-Command claude -CommandType Application -ErrorAction SilentlyContinue) -and
                       -not (Test-Path -LiteralPath (Join-Path $env:USERPROFILE '.local\bin\claude.exe'))
}

Describe 'A real review of the demo drawing' -Tag 'Live' -Skip:$NoClaude {
    BeforeAll {
        Import-Module (Join-Path $PSScriptRoot 'TestHelpers.psm1') -Force
        $repo = Get-RepoRoot
        $fixture = Join-Path $PSScriptRoot 'fixtures\demo'
        $inv = [Globalization.CultureInfo]::InvariantCulture
        . (Get-ScriptFunctions (Join-Path $repo 'run-review.ps1'))

        # A run folder from the fixture, with today's checklist - under
        # %TEMP% like the macro's, away from this repo's files.
        $script:Out = Get-TestOut 'live'
        $script:Dir = Join-Path ([IO.Path]::GetTempPath()) ('crd-live\DEMO-100_' + (Get-Date).ToString('yyyyMMdd-HHmmss'))
        New-Item -ItemType Directory -Force -Path $Dir | Out-Null
        foreach ($f in 'DEMO-100.pdf', 'prompt.txt') { Copy-Item -LiteralPath (Join-Path $fixture $f) -Destination $Dir }
        $data = [IO.File]::ReadAllText((Join-Path $fixture 'drawing-data.md'))
        $at = $data.IndexOf('> **Drawing content starts here.**')
        if ($at -lt 0) { throw 'tests\fixtures\demo\drawing-data.md has no "Drawing content starts here" line.' }
        $checklist = [IO.File]::ReadAllText((Join-Path $repo 'review-instructions.md'))
        [IO.File]::WriteAllText((Join-Path $Dir 'drawing-data.md'), $checklist + "`r`n`r`n---`r`n`r`n" + $data.Substring($at), (New-Object System.Text.UTF8Encoding $false))
        $script:DimAt = @{}
        foreach ($m in [regex]::Matches($data, '\| (D\d@[^|]+?) \|[^\r\n]*\| (\d+),(\d+) \|')) { $DimAt[$m.Groups[1].Value] = @([int]$m.Groups[2].Value, [int]$m.Groups[3].Value) }

        if ($env:CRD_LIVE_REUSE) {
            # Re-check an earlier review without asking Claude again.
            Copy-Item -LiteralPath (Join-Path $env:CRD_LIVE_REUSE 'review.md') -Destination $Dir
            Write-Host "    Re-checking the review in $env:CRD_LIVE_REUSE"
            $script:Result = Invoke-RunReview -Folder $Dir -RenderOnly
        } else {
            Write-Host "    Claude Code is reviewing $Dir (a few minutes) ..."
            $sw = [Diagnostics.Stopwatch]::StartNew()
            $script:Result = Invoke-RunReview -Folder $Dir -RealClaude -TimeoutMinutes 30
            Write-Host ("    Done in {0:0} s." -f $sw.Elapsed.TotalSeconds)
        }
        $script:Md = ''
        if (Test-Path -LiteralPath (Join-Path $Dir 'review.md')) { $script:Md = [IO.File]::ReadAllText((Join-Path $Dir 'review.md')) }
        $script:Parts = Get-ReviewParts ($Md -split "`r?`n")
        # .ToArray(): @() around a List[object] trips a 5.1 binder bug.
        $script:Findings = @(); if ($Parts) { $script:Findings = $Parts.Findings.ToArray() }
        if ($env:CRD_UPDATE_FIXTURES -and $Result.ExitCode -eq 0) {
            Copy-Item -LiteralPath (Join-Path $Dir 'review.md') -Destination $fixture -Force
            Write-Host '    Updated tests\fixtures\demo\review.md'
        }

        # The planted mistakes (demo\BuildDemoDrawing.bas), by keywords
        # in one finding's location, issue and fix.
        $script:Planted = [ordered]@{
            'the 4.00 length overridden to show 4.10'   = { param($t) $t -match '4\.10?\b|overrid' }
            'holes without locations'                   = { param($t) $t -match 'hole' -and $t -match 'locat|position' }
            'hole callout without 4X / THRU'            = { param($t) $t -match '\b4X\b|THRU|quantit' }
            'blank material'                            = { param($t) $t -match 'material' }
            'blank drawn by / date'                     = { param($t) $t -match 'drawn' }
            'misspelt note (DEBUR)'                     = { param($t) $t -match 'DEBUR|spell' }
        }
        function script:Find-Planted([string]$name) {
            foreach ($f in $Findings) { if (& $Planted[$name] ($f.Loc + ' ' + $f.Issue + ' ' + $f.Fix)) { return $f } }
            return $null
        }
    }

    AfterAll {
        # Kept for reading in tests\.out\live.
        if ($Dir -and (Test-Path -LiteralPath $Dir)) {
            Copy-Item -LiteralPath $Dir -Destination $Out -Recurse -Force
            Remove-Item -LiteralPath (Split-Path $Dir -Parent) -Recurse -Force -ErrorAction SilentlyContinue
            Write-Host "    The review is in $(Join-Path $Out (Split-Path $Dir -Leaf))"
        }
    }

    It 'finishes, and the report renders' {
        $Result.ExitCode | Should -Be 0 -Because $Result.Log
        $Result.Html | Should -Not -BeNullOrEmpty
    }
    It 'answers in the format the checklist asks for' {
        $Md | Should -Match '(?m)^\W*Verdict: (Ready to release|Needs minor fixes|Needs rework)'
        $Parts | Should -Not -BeNullOrEmpty -Because 'the answer should have a findings table'
        $Findings.Count | Should -BeGreaterOrEqual 4
        @($Findings | Where-Object { $_.Sev -eq 'info' }).Count | Should -Be 0 -Because 'every Severity is Critical, Major or Minor'
    }
    It 'does not pass a drawing with a critical mistake' {
        (Get-ReportModel $Result.Html).Verdict | Should -Be 'Needs rework'
    }
    It 'reports the overridden dimension as Critical' {
        $f = Find-Planted 'the 4.00 length overridden to show 4.10'
        $f | Should -Not -BeNullOrEmpty
        $f.Sev | Should -Be 'critical'
    }
    It 'finds at least five of the six planted mistakes' {
        $missed = @($Planted.Keys | Where-Object { -not (Find-Planted $_) })
        Write-Host "    Found $($Planted.Count - $missed.Count) of $($Planted.Count) planted mistakes$(if ($missed) { '; missed: ' + ($missed -join ', ') })"
        $missed.Count | Should -BeLessOrEqual 1 -Because "missed: $($missed -join ', ')"
    }
    It 'pins most findings on the sheet, the override near its dimension' {
        $pinned = @($Findings | Where-Object { $null -ne $_.Pin })
        ($pinned.Count / [Math]::Max(1, $Findings.Count)) | Should -BeGreaterOrEqual 0.6
        $f = Find-Planted 'the 4.00 length overridden to show 4.10'
        $f.Pin | Should -Not -BeNullOrEmpty
        $d = $DimAt['D1@Sketch1@DEMO-100.Part']
        [Math]::Abs($f.Pin[0] - $d[0]) | Should -BeLessOrEqual 10
        [Math]::Abs($f.Pin[1] - $d[1]) | Should -BeLessOrEqual 10
    }
}
