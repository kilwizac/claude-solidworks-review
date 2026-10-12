<#
  Repo checks: the rules in CONTRIBUTING.md that nothing else enforces,
  and the contracts between files (the checklist's answer format and the
  report that reads it; the README's settings table and the macro).
#>

BeforeDiscovery {
    $repo = Split-Path -Parent $PSScriptRoot
    # Tracked files and new ones that aren't ignored.
    $script:Files = @(git -C $repo ls-files -co --exclude-standard | Where-Object { Test-Path -LiteralPath (Join-Path $repo $_) -PathType Leaf })
    $script:Scripts = @($Files | Where-Object { $_ -match '\.(ps1|psm1)$' } | ForEach-Object { @{ File = $_ } })
    $script:Basics = @($Files | Where-Object { $_ -match '\.bas$' } | ForEach-Object { @{ File = $_ } })
    $script:CodeFiles = @($Files | Where-Object { $_ -match '\.(ps1|psm1|bas|cmd|cs)$' } | ForEach-Object { @{ File = $_ } })

    # Line-ending rules from .gitattributes: "*.ext text eol=crlf".
    $rules = @{}
    foreach ($l in Get-Content (Join-Path $repo '.gitattributes')) {
        if ($l -match '^\*\.(\w+)\s+.*\beol=(crlf|lf)\b') { $rules[$Matches[1].ToLowerInvariant()] = $Matches[2] }
    }
    $script:Eol = @(foreach ($f in $Files) {
        $ext = [IO.Path]::GetExtension($f).TrimStart('.').ToLowerInvariant()
        if ($rules.ContainsKey($ext)) { @{ File = $f; Eol = $rules[$ext] } }
    })
}

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'TestHelpers.psm1') -Force
    $script:Repo = Get-RepoRoot
    function script:Bytes([string]$f) { [IO.File]::ReadAllBytes((Join-Path $Repo $f)) }
}

Describe 'Encoding and line endings' {
    It '<File> is ASCII' -TestCases $CodeFiles {
        # Windows PowerShell 5.1 reads BOM-less scripts, and the VBA editor
        # imports .bas files, in the ANSI code page.
        $b = Bytes $File
        $bad = @(for ($i = 0; $i -lt $b.Length; $i++) { if ($b[$i] -gt 127) { $i } })
        if ($bad.Count -gt 0) {
            $line = ([Text.Encoding]::ASCII.GetString($b, 0, $bad[0]) -split "`n").Count
            throw "$File has non-ASCII bytes, the first on line $line."
        }
    }

    It '<File> has <Eol> line endings' -TestCases $Eol {
        $text = [Text.Encoding]::ASCII.GetString((Bytes $File))
        $crlf = ([regex]::Matches($text, "`r`n")).Count
        $lf = ([regex]::Matches($text, "(?<!`r)`n")).Count
        if ($Eol -eq 'crlf') { $lf | Should -Be 0 -Because "$File must use CRLF (.gitattributes); it has $lf bare LF" }
        else { $crlf | Should -Be 0 -Because "$File must use LF (.gitattributes); it has $crlf CRLF" }
    }
}

Describe 'PowerShell scripts' {
    It '<File> parses in Windows PowerShell 5.1' -TestCases $Scripts {
        $tokens = $null; $errors = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile((Join-Path $Repo $File), [ref]$tokens, [ref]$errors)
        ($errors | ForEach-Object { "line $($_.Extent.StartLineNumber): $($_.Message)" }) -join '; ' | Should -BeNullOrEmpty
    }

    It 'every script parses in PowerShell 7' -Skip:(-not (Get-Command pwsh -ErrorAction SilentlyContinue)) {
        $list = Join-Path $TestDrive 'scripts.txt'
        $paths = @(git -C $Repo ls-files -co --exclude-standard | Where-Object { $_ -match '\.(ps1|psm1)$' } | ForEach-Object { Join-Path $Repo $_ })
        [IO.File]::WriteAllLines($list, $paths)
        $check = 'foreach ($p in Get-Content -LiteralPath $args[0]) { $t = $null; $e = $null; ' +
                 '[void][System.Management.Automation.Language.Parser]::ParseFile($p, [ref]$t, [ref]$e); ' +
                 'foreach ($x in $e) { "$p line $($x.Extent.StartLineNumber): $($x.Message)" } }'
        $r = Invoke-Process -FilePath 'pwsh.exe' -ArgumentList @('-NoProfile', '-Command', "& { $check } '$list'")
        $r.StdOut.Trim() | Should -BeNullOrEmpty
        $r.StdErr.Trim() | Should -BeNullOrEmpty
    }
}

Describe 'VBA sources' {
    It '<File> is a module named after its file, with Option Explicit and Public Sub Main' -TestCases $Basics {
        $lines = [IO.File]::ReadAllLines((Join-Path $Repo $File))
        $lines[0] | Should -Be ('Attribute VB_Name = "' + [IO.Path]::GetFileNameWithoutExtension($File) + '"')
        $lines | Should -Contain 'Option Explicit'
        ($lines -match '^Public Sub Main\(\)\s*$').Count | Should -Be 1
    }

    It '<File> stays within what the VBA editor imports' -TestCases $Basics {
        $lines = [IO.File]::ReadAllLines((Join-Path $Repo $File))
        # Lines over 1023 characters, or more than 24 continuations in one
        # statement, are compile errors that only show on import.
        $long = @(for ($i = 0; $i -lt $lines.Count; $i++) { if ($lines[$i].Length -gt 1023) { $i + 1 } })
        $long | Should -BeNullOrEmpty -Because 'VBA lines are limited to 1023 characters'
        $run = 0; $worst = 0; $at = 0
        for ($i = 0; $i -lt $lines.Count; $i++) {
            if ($lines[$i] -match '\s_\s*$') { $run++; if ($run -gt $worst) { $worst = $run; $at = $i + 1 } } else { $run = 0 }
        }
        $worst | Should -BeLessOrEqual 24 -Because "line $at continues a statement more than 24 times"
    }
}

Describe 'Contracts between files' {
    BeforeAll {
        $inv = [Globalization.CultureInfo]::InvariantCulture
        . (Get-ScriptFunctions (Join-Path $Repo 'run-review.ps1'))
        $script:Checklist = [IO.File]::ReadAllText((Join-Path $Repo 'review-instructions.md'))
        $script:Macro = [IO.File]::ReadAllText((Join-Path $Repo 'src\ClaudeReviewDrawing.bas'))
    }

    It "the report reads every column of the checklist's findings table" {
        $header = ($Checklist -split "`r?`n" | Where-Object { $_ -match '^\s*\|\s*#\s*\|' } | Select-Object -First 1).Trim()
        $header | Should -Not -BeNullOrEmpty -Because 'review-instructions.md shows the findings table header'
        $parts = Get-ReviewParts @($header, '| - | - | - | - | - | - | - |', '| 1 | Major | 2 | 10,20 | Front | The issue | The fix |')
        $f = $parts.Findings[0]
        $f.Num | Should -Be '1'
        $f.Sev | Should -Be 'major'
        $f.SheetNo | Should -Be 2
        $f.Pin | Should -Be @(10, 20)
        $f.Loc | Should -Be 'Front'
        $f.Issue | Should -Be 'The issue'
        $f.Fix | Should -Be 'The fix'
    }

    It 'the report knows each verdict the checklist asks for (<Verdict>)' -TestCases @(
        @{ Verdict = 'Ready to release'; Class = 'ready' }
        @{ Verdict = 'Needs minor fixes'; Class = 'minor' }
        @{ Verdict = 'Needs rework'; Class = 'rework' }
    ) {
        $Checklist | Should -Match ([regex]::Escape("``Verdict: $Verdict``"))
        $Macro | Should -Match ([regex]::Escape("'Verdict: $Verdict'"))
        $d = New-TestRunFolder -Parent (Join-Path $TestDrive $Class) -ReviewText "Verdict: $Verdict`n`nSummary.`n" -NoPdf
        $m = Get-ReportModel (Invoke-RunReview -Folder $d -RenderOnly).Html
        $m.Verdict | Should -Be $Verdict
        $m.VerdictClass | Should -Be $Class
    }

    It "the macro's built-in checklist asks for the same table" {
        $Macro | Should -Match ([regex]::Escape('| # | Severity | Sheet | Pin | View / location | Issue | Suggested fix |'))
    }

    It "the README's settings table gives the macro's defaults" {
        $readme = [IO.File]::ReadAllText((Join-Path $Repo 'README.md'))
        $rows = [regex]::Matches($readme, '(?m)^\| `([A-Z][A-Z_]+)` \|[^|]*\| ([^|]+?) \|\s*$')
        $rows.Count | Should -BeGreaterThan 3
        foreach ($r in $rows) {
            $name = $r.Groups[1].Value
            $doc = $r.Groups[2].Value.Trim().Trim('`')
            $m = [regex]::Match($Macro, "(?m)^Private Const $name As \w+ = (?:_\s*\r?\n\s*)?(.+?)\s*$")
            $m.Success | Should -BeTrue -Because "the README lists $name, which the macro should define"
            $value = $m.Groups[1].Value.Trim('"')
            if ($doc -eq 'blank') { $doc = '' }
            ($value -replace '\s', '') | Should -Be ($doc -replace '\s', '') -Because "README default for $name"
        }
    }
}

Describe 'What the repo holds' {
    It 'commits no built macros, drawings or PDFs (except test fixtures)' {
        $bad = @(git -C $Repo ls-files | Where-Object { $_ -match '\.(swp|swb|sldprt|slddrw|sldasm)$' -or ($_ -match '\.pdf$' -and $_ -notmatch '^tests/fixtures/') })
        $bad | Should -BeNullOrEmpty
    }

    It 'the CHANGELOG lists versions newest first' {
        $log = [IO.File]::ReadAllText((Join-Path $Repo 'CHANGELOG.md'))
        $heads = @([regex]::Matches($log, '(?m)^## (.+)$') | ForEach-Object { $_.Groups[1].Value.Trim() })
        $heads.Count | Should -BeGreaterThan 0
        $versions = @($heads | Where-Object { $_ -ne 'Unreleased' } | ForEach-Object {
            $_ | Should -Match '^\d+\.\d+\.\d+ - \d{4}-\d{2}-\d{2}$' -Because 'version headings read "## x.y.z - yyyy-mm-dd"'
            [version]($_ -split ' ')[0]
        })
        if ($heads -contains 'Unreleased') { $heads[0] | Should -Be 'Unreleased' }
        for ($i = 1; $i -lt $versions.Count; $i++) { $versions[$i] | Should -BeLessThan $versions[$i - 1] }
    }
}
