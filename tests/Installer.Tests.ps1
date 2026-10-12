<#
  Installer.Tests.ps1 - installer\Install.ps1 and Install.cmd, run on a
  package laid out like the release zip (with stand-in .swp files), always
  with -Quiet so nothing is downloaded or installed beyond the test folder.
#>

BeforeDiscovery {
    $repoForTags = Split-Path -Parent $PSScriptRoot
    & git -C $repoForTags rev-parse -q --verify 'refs/tags/v0.2.0^{commit}' *> $null
    $script:HasV020 = ($LASTEXITCODE -eq 0)
}

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'TestHelpers.psm1') -Force
    $script:Repo = Get-RepoRoot
    # Install.ps1's own Get-TextHash (and friends), to compare hashes.
    . (Get-ScriptFunctions (Join-Path $Repo 'installer\Install.ps1'))

    $script:DefaultA = "# Drawing review instructions`n`nVersion A of the checklist.`n"
    $script:DefaultB = "# Drawing review instructions`n`nVersion B of the checklist, with a new rule.`n"

    # A package like the release zip's top folder; returns its path.
    function New-Package([string]$Parent, [string]$Instructions = $DefaultA, [string]$SwpText = 'SWP v1') {
        $pkg = Join-Path $Parent 'ClaudeSolidWorksReview-9.9.9'
        $app = Join-Path $pkg 'app'
        New-Item -ItemType Directory -Force -Path (Join-Path $app 'demo') | Out-Null
        Copy-Item -LiteralPath (Join-Path $Repo 'installer\Install.cmd') -Destination $pkg
        Copy-Item -LiteralPath (Join-Path $Repo 'installer\Install.ps1') -Destination $pkg
        [IO.File]::WriteAllText((Join-Path $app 'ClaudeReviewDrawing.swp'), "$SwpText review macro")
        [IO.File]::WriteAllText((Join-Path $app 'demo\BuildDemoDrawing.swp'), "$SwpText demo macro")
        [IO.File]::WriteAllText((Join-Path $app 'review-instructions.md'), $Instructions)
        foreach ($f in 'run-review.ps1', 'README.md', 'LICENSE') { Copy-Item -LiteralPath (Join-Path $Repo $f) -Destination $app }
        return $pkg
    }

    # Install.ps1 -Quiet in a child Windows PowerShell. -Claude: the fake
    # claude.exe is on PATH; otherwise no Claude Code can be found.
    function Invoke-Installer([string]$Package, [string]$InstallDir, [switch]$Claude, [string[]]$More = @()) {
        $envVars = @{ PATH = (Get-PathWithoutClaude); USERPROFILE = (Get-TestOut 'installer-profile') }
        if ($Claude) { $envVars.PATH = (Get-FakeClaudeDir) + ';' + $envVars.PATH }
        $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $Package 'Install.ps1'), '-Quiet')
        if ($InstallDir) { $argList += @('-InstallDir', $InstallDir) }
        $r = Invoke-Process -FilePath 'powershell.exe' -ArgumentList ($argList + $More) -WorkingDirectory $Package -Environment $envVars
        $r | Add-Member -NotePropertyName Output -NotePropertyValue ($r.StdOut + $r.StdErr) -PassThru
    }

    function Get-Zone([string]$Path) {
        Get-Item -LiteralPath $Path -Stream Zone.Identifier -ErrorAction SilentlyContinue
    }
    function Set-Zone([string]$Path) {
        Set-Content -LiteralPath $Path -Stream Zone.Identifier -Value "[ZoneTransfer]`r`nZoneId=3"
    }
    function Read-Text([string]$Path) { [IO.File]::ReadAllText($Path) }
}

Describe 'Install.ps1' {
    Context 'Fresh install' {
        BeforeAll {
            $pkg = New-Package (Join-Path $TestDrive 'pkg')
            $dir = Join-Path $TestDrive 'Claude Review & Co'
            $res = Invoke-Installer $pkg $dir -Claude
        }
        It 'succeeds' {
            $res.ExitCode | Should -Be 0 -Because $res.Output
        }
        It 'installs every file of the package' {
            foreach ($f in 'ClaudeReviewDrawing.swp', 'run-review.ps1', 'review-instructions.md', 'README.md', 'LICENSE', 'demo\BuildDemoDrawing.swp') {
                Join-Path $dir $f | Should -Exist
            }
            Read-Text (Join-Path $dir 'ClaudeReviewDrawing.swp') | Should -Be 'SWP v1 review macro'
            Read-Text (Join-Path $dir 'demo\BuildDemoDrawing.swp') | Should -Be 'SWP v1 demo macro'
            (Get-FileHash (Join-Path $dir 'run-review.ps1')).Hash | Should -Be (Get-FileHash (Join-Path $Repo 'run-review.ps1')).Hash
        }
        It 'installs the checklist and saves the default beside it' {
            Read-Text (Join-Path $dir 'review-instructions.md') | Should -Be $DefaultA
            Read-Text (Join-Path $dir 'review-instructions.default.md') | Should -Be $DefaultA
            $res.Output | Should -Match '\[OK  \] Review checklist: review-instructions.md installed'
        }
        It 'reports Claude Code with its version' {
            $res.Output | Should -Match '\[OK  \] Claude Code: 9\.9\.9 \(Fake Claude Code\) at .*claude\.exe'
        }
        It 'says how to run the macro' {
            $res.Output | Should -Match ([regex]::Escape("Tools > Macro > Run > $(Join-Path $dir 'ClaudeReviewDrawing.swp')"))
        }
    }

    Context 'Claude Code is not installed' {
        BeforeAll {
            $pkg = New-Package (Join-Path $TestDrive 'pkg')
            $dir = Join-Path $TestDrive 'install'
            $res = Invoke-Installer $pkg $dir
        }
        It 'still installs' {
            $res.ExitCode | Should -Be 0 -Because $res.Output
            Join-Path $dir 'ClaudeReviewDrawing.swp' | Should -Exist
        }
        It 'reports it missing without trying to install it (-Quiet)' {
            $res.Output | Should -Match '\[MISS\] Claude Code: Not installed'
            $res.Output | Should -Not -Match 'The Claude Code installer did not finish'
        }
    }

    Context 'Upgrade' {
        It 'replaces a checklist that was never edited' {
            $dir = Join-Path $TestDrive 'up1'
            (Invoke-Installer (New-Package (Join-Path $TestDrive 'a1')) $dir).ExitCode | Should -Be 0
            $res = Invoke-Installer (New-Package (Join-Path $TestDrive 'b1') -Instructions $DefaultB -SwpText 'SWP v2') $dir
            $res.ExitCode | Should -Be 0 -Because $res.Output
            Read-Text (Join-Path $dir 'review-instructions.md') | Should -Be $DefaultB
            Read-Text (Join-Path $dir 'review-instructions.default.md') | Should -Be $DefaultB
            Read-Text (Join-Path $dir 'ClaudeReviewDrawing.swp') | Should -Be 'SWP v2 review macro'
        }

        It 'keeps a customised checklist and refreshes the default beside it' {
            $dir = Join-Path $TestDrive 'up2'
            (Invoke-Installer (New-Package (Join-Path $TestDrive 'a2')) $dir).ExitCode | Should -Be 0
            $custom = $DefaultA + "`n- Our shop always deburrs to 0.010 max.`n"
            [IO.File]::WriteAllText((Join-Path $dir 'review-instructions.md'), $custom)
            $res = Invoke-Installer (New-Package (Join-Path $TestDrive 'b2') -Instructions $DefaultB) $dir
            $res.ExitCode | Should -Be 0 -Because $res.Output
            Read-Text (Join-Path $dir 'review-instructions.md') | Should -Be $custom
            Read-Text (Join-Path $dir 'review-instructions.default.md') | Should -Be $DefaultB
            $res.Output | Should -Match '\[INFO\] Review checklist: Kept your customised review-instructions.md'
        }

        It 'counts CRLF line endings and a BOM as unchanged' {
            $dir = Join-Path $TestDrive 'up3'
            (Invoke-Installer (New-Package (Join-Path $TestDrive 'a3')) $dir).ExitCode | Should -Be 0
            # What an editor might do to a file it only opened and saved.
            [IO.File]::WriteAllText((Join-Path $dir 'review-instructions.md'), $DefaultA.Replace("`n", "`r`n"), (New-Object System.Text.UTF8Encoding $true))
            $res = Invoke-Installer (New-Package (Join-Path $TestDrive 'b3') -Instructions $DefaultB) $dir
            $res.ExitCode | Should -Be 0 -Because $res.Output
            Read-Text (Join-Path $dir 'review-instructions.md') | Should -Be $DefaultB
        }

        It 'replaces the 0.1.0 / 0.2.0 checklist, which had no default saved beside it' -Skip:(-not $HasV020) {
            $dir = Join-Path $TestDrive 'up4'
            New-Item -ItemType Directory -Force -Path $dir | Out-Null
            $old = Invoke-Process -FilePath 'git' -ArgumentList @('-C', $Repo, 'show', 'v0.2.0:review-instructions.md')
            [IO.File]::WriteAllText((Join-Path $dir 'review-instructions.md'), $old.StdOut.Replace("`n", "`r`n"))
            $res = Invoke-Installer (New-Package (Join-Path $TestDrive 'b4') -Instructions $DefaultB) $dir
            $res.ExitCode | Should -Be 0 -Because $res.Output
            Read-Text (Join-Path $dir 'review-instructions.md') | Should -Be $DefaultB
        }

        It 'has the right hash for the 0.1.0 / 0.2.0 checklist' -Skip:(-not $HasV020) {
            $installer = Read-Text (Join-Path $Repo 'installer\Install.ps1')
            $known = [regex]::Match($installer, "'([0-9A-F]{64})'\s*#\s*0\.1\.0").Groups[1].Value
            $known | Should -Not -BeNullOrEmpty
            $file = Join-Path $TestDrive 'v020-instructions.md'
            $old = Invoke-Process -FilePath 'git' -ArgumentList @('-C', $Repo, 'show', 'v0.2.0:review-instructions.md')
            [IO.File]::WriteAllText($file, $old.StdOut)
            Get-TextHash $file | Should -Be $known
        }
    }

    Context 'Refusals' {
        It 'refuses to install over a clone of the repository' {
            $dir = Join-Path $TestDrive 'clone'
            New-Item -ItemType Directory -Force -Path (Join-Path $dir 'src') | Out-Null
            [IO.File]::WriteAllText((Join-Path $dir 'src\ClaudeReviewDrawing.bas'), 'Attribute VB_Name = "ClaudeReviewDrawing"')
            $before = @(Get-ChildItem -LiteralPath $dir -Recurse | ForEach-Object { $_.FullName })
            $res = Invoke-Installer (New-Package (Join-Path $TestDrive 'c1')) $dir
            $res.ExitCode | Should -Be 1
            $res.Output | Should -Match 'is a copy of the source repository'
            @(Get-ChildItem -LiteralPath $dir -Recurse | ForEach-Object { $_.FullName }) | Should -Be $before
        }

        It 'refuses a package that was run without extracting it' {
            $pkg = New-Package (Join-Path $TestDrive 'c2')
            Remove-Item -LiteralPath (Join-Path $pkg 'app\run-review.ps1')
            $dir = Join-Path $TestDrive 'c2-install'
            $res = Invoke-Installer $pkg $dir
            $res.ExitCode | Should -Be 1
            $res.Output | Should -Match "Can't find app\\run-review.ps1"
            $res.Output | Should -Match 'Extract the whole zip first'
            $dir | Should -Not -Exist
        }

        It 'stops with a clear message when the macro is open in SOLIDWORKS (-Quiet)' {
            $dir = Join-Path $TestDrive 'locked'
            (Invoke-Installer (New-Package (Join-Path $TestDrive 'c3a')) $dir).ExitCode | Should -Be 0
            $lock = [IO.File]::Open((Join-Path $dir 'ClaudeReviewDrawing.swp'), 'Open', 'ReadWrite', 'None')
            try {
                $res = Invoke-Installer (New-Package (Join-Path $TestDrive 'c3b') -SwpText 'SWP v2') $dir
            } finally { $lock.Close() }
            $res.ExitCode | Should -Not -Be 0
            $res.Output | Should -Match 'is in use\. Close it and run the installer again'
            Read-Text (Join-Path $dir 'ClaudeReviewDrawing.swp') | Should -Be 'SWP v1 review macro'
        }
    }

    Context 'Downloaded-file flags (Zone.Identifier)' {
        BeforeAll {
            $pkg = New-Package (Join-Path $TestDrive 'z')
            Get-ChildItem -LiteralPath $pkg -Recurse -File | ForEach-Object { Set-Zone $_.FullName }
            $dir = Join-Path $TestDrive 'z-install'
            New-Item -ItemType Directory -Force -Path $dir | Out-Null
            # Someone else's download in the same folder, and a customised
            # checklist that was copied in from a download.
            $other = Join-Path $dir 'someone-elses-download.exe'
            [IO.File]::WriteAllText($other, 'not ours')
            Set-Zone $other
            $custom = Join-Path $dir 'review-instructions.md'
            [IO.File]::WriteAllText($custom, "My own checklist`n")
            Set-Zone $custom
            $res = Invoke-Installer $pkg $dir
        }
        It 'installs' { $res.ExitCode | Should -Be 0 -Because $res.Output }
        It 'unblocks the package' {
            Get-Zone (Join-Path $pkg 'app\run-review.ps1') | Should -BeNullOrEmpty
        }
        It 'unblocks every installed file, a kept checklist too' {
            foreach ($f in 'ClaudeReviewDrawing.swp', 'run-review.ps1', 'review-instructions.md', 'review-instructions.default.md', 'demo\BuildDemoDrawing.swp') {
                Get-Zone (Join-Path $dir $f) | Should -BeNullOrEmpty -Because $f
            }
            Read-Text $custom | Should -Be "My own checklist`n"
        }
        It "leaves other files' flags alone" {
            Get-Zone $other | Should -Not -BeNullOrEmpty
        }
    }
}

Describe 'Install.cmd' {
    BeforeAll {
        # A folder name with spaces and "&", which cmd.exe treats specially.
        $pkg = New-Package (Join-Path $TestDrive 'Downloads & Stuff\pkg')
        $dir = Join-Path $TestDrive 'Macros & Add-Ons\Claude Review'
        $cmd = Join-Path $pkg 'Install.cmd'
        # cmd /s /c "<line>": the line is run as written. Stdin is empty,
        # so "pause" at the end returns at once.
        $psi = New-Object System.Diagnostics.ProcessStartInfo 'cmd.exe'
        $psi.Arguments = "/d /s /c `"`"$cmd`" -Quiet -InstallDir `"$dir`"`""
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $psi.RedirectStandardInput = $true
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.EnvironmentVariables['PATH'] = (Get-FakeClaudeDir) + ';' + (Get-PathWithoutClaude)
        $p = [System.Diagnostics.Process]::Start($psi)
        $outTask = $p.StandardOutput.ReadToEndAsync()
        $errTask = $p.StandardError.ReadToEndAsync()
        $p.StandardInput.Close()
        if (-not $p.WaitForExit(180000)) { $p.Kill(); throw 'Install.cmd did not finish in 3 minutes.' }
        $output = $outTask.Result + $errTask.Result
    }
    It 'passes its arguments to Install.ps1 and installs' {
        Join-Path $dir 'ClaudeReviewDrawing.swp' | Should -Exist -Because $output
        Join-Path $dir 'review-instructions.md' | Should -Exist
        $output | Should -Match '\[OK  \] Macros: Installed to'
    }
    It "finishes with pause, so the window stays open" {
        $output | Should -Match 'Press any key'
    }
    It "doesn't report Group Policy blocking scripts" {
        $output | Should -Not -Match 'Group Policy on this PC blocks'
    }
}
