<#
  Release.Tests.ps1 - tools\make-release.ps1 and tools\verify-release.ps1.

  Each test runs the scripts in a copy of the repository (tracked and
  new files, as on disk) under TestDrive, so dist\ and the stage folder
  stay out of the real repo. The built macros are gitignored, so the
  copies get stand-in .swp files made from the .bas files
  (tests\lib\FakeSwp.cs); the real ones are used too when they're here.
  Nothing is uploaded: the -Upload checks run with -DryRun.
#>

BeforeDiscovery {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    $script:HasRealSwp = (Test-Path -LiteralPath (Join-Path $repoRoot 'ClaudeReviewDrawing.swp')) -and
                         (Test-Path -LiteralPath (Join-Path $repoRoot 'demo\BuildDemoDrawing.swp'))
}

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'TestHelpers.psm1') -Force
    Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'tools\SwpSource.psm1') -Force
    if (-not ('ClaudeReview.Tests.FakeSwp' -as [type])) { Add-Type -Path (Join-Path $PSScriptRoot 'lib\FakeSwp.cs') }
    Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
    $script:Repo = Get-RepoRoot
    $script:Gh = 'https://github.com/kilwizac/claude-solidworks-review'
    $script:Expected = @('Install.cmd', 'Install.ps1', 'app/ClaudeReviewDrawing.swp', 'app/run-review.ps1',
                         'app/review-instructions.md', 'app/README.md', 'app/LICENSE', 'app/demo/BuildDemoDrawing.swp')

    # git in $GitDir; the rest are git's arguments. (The parameter's name
    # mustn't start like a git switch: -d would bind to a -Dir parameter.)
    function Invoke-Git([string]$GitDir) {
        $r = Invoke-Process -FilePath 'git' -ArgumentList (@('-C', $GitDir, '-c', 'user.name=Test', '-c', 'user.email=test@example.com',
                                                            '-c', 'init.defaultBranch=main', '-c', 'core.safecrlf=false') + $args)
        if ($r.ExitCode -ne 0) { throw "git $($args -join ' ') failed: $($r.StdErr)" }
        return $r.StdOut.Trim()
    }

    # A copy of the repo's files as on disk (tracked, and new files that
    # aren't ignored), with stand-in .swp files built from the .bas files
    # (-RealSwp: the real ones). -Git makes it a repository with one commit.
    function New-RepoCopy([string]$Dest, [switch]$RealSwp, [switch]$Git) {
        $list = Invoke-Process -FilePath 'git' -ArgumentList @('-C', $Repo, 'ls-files', '--cached', '--others', '--exclude-standard', '-z')
        foreach ($rel in ($list.StdOut -split "`0")) {
            if (-not $rel) { continue }
            $src = Join-Path $Repo $rel
            if (-not (Test-Path -LiteralPath $src -PathType Leaf)) { continue }
            $dst = Join-Path $Dest $rel
            New-Item -ItemType Directory -Force -Path (Split-Path $dst) | Out-Null
            Copy-Item -LiteralPath $src -Destination $dst
        }
        foreach ($m in @(@('ClaudeReviewDrawing.swp', 'src\ClaudeReviewDrawing.bas'), @('demo\BuildDemoDrawing.swp', 'demo\BuildDemoDrawing.bas'))) {
            if ($RealSwp) {
                Copy-Item -LiteralPath (Join-Path $Repo $m[0]) -Destination (Join-Path $Dest $m[0])
            } else {
                [ClaudeReview.Tests.FakeSwp]::FromBas((Join-Path $Dest $m[0]), (Join-Path $Dest $m[1]))
            }
        }
        if ($Git) {
            Invoke-Git $Dest init -q | Out-Null
            Invoke-Git $Dest add -A | Out-Null
            Invoke-Git $Dest commit -q -m 'Copy for tests' | Out-Null
        }
        return $Dest
    }

    # A stand-in .swp holding a .bas with one edit.
    function New-EditedSwp([string]$Swp, [string]$Bas, [string]$From, [string]$To) {
        $cp = [Text.Encoding]::GetEncoding(1252)
        $edited = Join-Path (Split-Path $Swp) ('edited-' + (Split-Path $Bas -Leaf))
        $text = [IO.File]::ReadAllText($Bas, $cp)
        if (-not $text.Contains($From)) { throw "'$From' isn't in $Bas" }
        [IO.File]::WriteAllText($edited, $text.Replace($From, $To), $cp)
        [ClaudeReview.Tests.FakeSwp]::FromBas($Swp, $edited)
        Remove-Item -LiteralPath $edited
    }

    # A CHANGELOG section for a version, above the newest release.
    function Add-ChangelogSection([string]$Copy, [string]$Version, [string]$Line) {
        $path = Join-Path $Copy 'CHANGELOG.md'
        $text = [IO.File]::ReadAllText($path)
        $at = [regex]::Match($text, '(?m)^## \d').Index
        $text = $text.Insert($at, "## $Version - 2026-10-12`n`n### Added`n- $Line`n`n")
        [IO.File]::WriteAllText($path, $text)
    }

    # Runs a tools\ script of a copy in Windows PowerShell, with TEMP in
    # TestDrive so the stage and work folders stay there too.
    function Invoke-Tool([string]$Copy, [string]$Script, [string[]]$More) {
        $tmp = Join-Path $TestDrive 'tmp'
        New-Item -ItemType Directory -Force -Path $tmp | Out-Null
        $r = Invoke-Process -FilePath 'powershell.exe' -WorkingDirectory $Copy -TimeoutSeconds 600 `
            -ArgumentList (@('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $Copy "tools\$Script")) + $More) `
            -Environment @{ TEMP = $tmp; TMP = $tmp; PATH = (Get-PathWithoutClaude) }
        $r | Add-Member -NotePropertyName Output -NotePropertyValue ($r.StdOut + "`n" + $r.StdErr) -PassThru
    }

    function Get-ZipNames([string]$Zip) {
        $z = [IO.Compression.ZipFile]::OpenRead($Zip)
        try { @($z.Entries | ForEach-Object { $_.FullName }) } finally { $z.Dispose() }
    }
    function Read-ZipText([string]$Zip, [string]$Name) {
        $z = [IO.Compression.ZipFile]::OpenRead($Zip)
        try {
            $r = New-Object IO.StreamReader($z.GetEntry($Name).Open())
            try { $r.ReadToEnd() } finally { $r.Dispose() }
        } finally { $z.Dispose() }
    }
    function Save-ZipEntry([string]$Zip, [string]$Name, [string]$Dest) {
        $z = [IO.Compression.ZipFile]::OpenRead($Zip)
        try { [IO.Compression.ZipFileExtensions]::ExtractToFile($z.GetEntry($Name), $Dest, $true) } finally { $z.Dispose() }
    }
    # A copy of a zip with one entry replaced (bytes) or removed ($null).
    function Copy-ZipWith([string]$Zip, [string]$Dest, [string]$Name, $Bytes) {
        Copy-Item -LiteralPath $Zip -Destination $Dest -Force
        $fs = [IO.File]::Open($Dest, 'Open', 'ReadWrite')
        $z = New-Object IO.Compression.ZipArchive($fs, [IO.Compression.ZipArchiveMode]::Update)
        try {
            $z.GetEntry($Name).Delete()
            if ($null -ne $Bytes) {
                $s = $z.CreateEntry($Name).Open()
                try { $s.Write($Bytes, 0, $Bytes.Length) } finally { $s.Dispose() }
            }
        } finally { $z.Dispose(); $fs.Dispose() }
        return $Dest
    }
}

Describe 'make-release.ps1' {
    Context 'Building the zip' {
        BeforeAll {
            $copy = New-RepoCopy (Join-Path $TestDrive 'repo')
            Add-ChangelogSection $copy '9.8.7' 'A feature only this test knows about.'
            $res = Invoke-Tool $copy 'make-release.ps1' @('-Version', '9.8.7')
            $zip = Join-Path $copy 'dist\ClaudeSolidWorksReview-9.8.7.zip'
            $readme = ''
            if (Test-Path -LiteralPath $zip) { $readme = Read-ZipText $zip 'ClaudeSolidWorksReview-9.8.7/app/README.md' }
        }
        It 'succeeds' {
            $res.ExitCode | Should -Be 0 -Because $res.Output
            $zip | Should -Exist
        }
        It 'checks the code in both macros' {
            $res.Output | Should -Match 'ClaudeReviewDrawing\.swp: ClaudeReviewDrawing1 matches ClaudeReviewDrawing\.bas'
            $res.Output | Should -Match 'BuildDemoDrawing\.swp: BuildDemoDrawing1 matches BuildDemoDrawing\.bas'
        }
        It 'has exactly the installer and app files, under one top folder' {
            $names = Get-ZipNames $zip
            ($names | Sort-Object) | Should -Be ($Expected | ForEach-Object { "ClaudeSolidWorksReview-9.8.7/$_" } | Sort-Object)
        }
        It 'uses / in entry names' {
            Get-ZipNames $zip | Where-Object { $_ -match '\\' } | Should -BeNullOrEmpty
        }
        It 'packs the macros holding the code in their .bas' {
            $swp = Join-Path $TestDrive 'packed.swp'
            Save-ZipEntry $zip 'ClaudeSolidWorksReview-9.8.7/app/ClaudeReviewDrawing.swp' $swp
            (Compare-SwpSource -Swp $swp -Bas (Join-Path $Repo 'src\ClaudeReviewDrawing.bas')).Match | Should -BeTrue
        }
        It 'removes its stage folder' {
            Join-Path $TestDrive 'tmp\claude-review-release\ClaudeSolidWorksReview-9.8.7' | Should -Not -Exist
        }
        It 'keeps README links to installed files and to headings' {
            $readme | Should -Match '\]\(review-instructions\.md\)'
            $readme | Should -Match '\]\(LICENSE\)'
            $readme | Should -Match '\]\(#requirements\)'
        }
        It 'points README links to files that are not installed at GitHub, at the version' {
            $readme | Should -Match ([regex]::Escape("srcset=`"$Gh/raw/v9.8.7/docs/review-dark.png`""))
            $readme | Should -Match ([regex]::Escape("src=`"$Gh/raw/v9.8.7/docs/review-light.png`""))
            $readme | Should -Match ([regex]::Escape("]($Gh/blob/v9.8.7/installer/Install.ps1)"))
            $readme | Should -Match ([regex]::Escape("]($Gh/blob/v9.8.7/demo/BuildDemoDrawing.bas)"))
            $readme | Should -Match ([regex]::Escape("]($Gh/blob/v9.8.7/CONTRIBUTING.md)"))
        }
        It 'leaves no relative link to a file that is not installed' {
            $left = foreach ($m in [regex]::Matches($readme, '(?:\]\(|src="|srcset=")(?!https?:|mailto:|#)([^)"\s]+)')) {
                $p = $m.Groups[1].Value -replace '#.*$', ''
                if ($p -notin 'review-instructions.md', 'run-review.ps1', 'README.md', 'LICENSE') { $p }
            }
            $left | Should -BeNullOrEmpty
        }
        It "writes the version's CHANGELOG section as the release notes" {
            $notes = [IO.File]::ReadAllText((Join-Path $copy 'dist\release-notes-9.8.7.md'))
            $notes | Should -Match '^Download \*\*ClaudeSolidWorksReview-9\.8\.7\.zip\*\*, extract it, and double-click \*\*Install\.cmd\*\*\.'
            $notes | Should -Match 'A feature only this test knows about\.'
            $notes | Should -Not -Match 'One-step install'
            $notes | Should -Not -Match '(?m)^## '
        }
        It 'makes a zip that verify-release.ps1 passes' {
            $v = Invoke-Tool $copy 'verify-release.ps1' @('-Zip', $zip)
            $v.ExitCode | Should -Be 0 -Because $v.Output
            $v.Output | Should -Match 'passed every check'
            ([regex]::Matches($v.Output, '\[PASS\]')).Count | Should -Be 7
        }
    }

    Context 'A version without a CHANGELOG section' {
        It 'still builds, with a warning, and notes that are only the download line' {
            $copy = New-RepoCopy (Join-Path $TestDrive 'repo')
            $res = Invoke-Tool $copy 'make-release.ps1' @('-Version', '9.8.8')
            $res.ExitCode | Should -Be 0 -Because $res.Output
            $res.Output | Should -Match "CHANGELOG\.md has no '## 9\.8\.8' section"
            ([IO.File]::ReadAllText((Join-Path $copy 'dist\release-notes-9.8.8.md'))).Trim() |
                Should -Be 'Download **ClaudeSolidWorksReview-9.8.8.zip**, extract it, and double-click **Install.cmd**.'
        }
    }

    Context 'Built macros' {
        It 'refuses a missing .swp' {
            $copy = New-RepoCopy (Join-Path $TestDrive 'r1')
            Remove-Item -LiteralPath (Join-Path $copy 'demo\BuildDemoDrawing.swp')
            $res = Invoke-Tool $copy 'make-release.ps1' @('-Version', '9.8.7')
            $res.ExitCode | Should -Not -Be 0
            $res.Output | Should -Match 'demo\\BuildDemoDrawing\.swp is missing'
        }
        It 'refuses a .swp whose code differs from its .bas, and says where' {
            $copy = New-RepoCopy (Join-Path $TestDrive 'r2')
            New-EditedSwp (Join-Path $copy 'ClaudeReviewDrawing.swp') (Join-Path $copy 'src\ClaudeReviewDrawing.bas') '"Review with Claude"' '"Review with Claudia"'
            $res = Invoke-Tool $copy 'make-release.ps1' @('-Version', '9.8.7')
            $res.ExitCode | Should -Not -Be 0
            $res.Output | Should -Match "ClaudeReviewDrawing\.swp doesn't hold the code in src\\ClaudeReviewDrawing\.bas"
            $res.Output | Should -Match 'Review with Claudia'
            Join-Path $copy 'dist\ClaudeSolidWorksReview-9.8.7.zip' | Should -Not -Exist
        }
        It 'builds anyway with -AllowStale, with a warning' {
            $copy = New-RepoCopy (Join-Path $TestDrive 'r3')
            New-EditedSwp (Join-Path $copy 'demo\BuildDemoDrawing.swp') (Join-Path $copy 'demo\BuildDemoDrawing.bas') 'DEBUR ALL EDGES' 'DEBURR ALL EDGES'
            $res = Invoke-Tool $copy 'make-release.ps1' @('-Version', '9.8.7', '-AllowStale')
            $res.ExitCode | Should -Be 0 -Because $res.Output
            $res.Output | Should -Match "WARNING: demo\\BuildDemoDrawing\.swp doesn't hold the code"
            Join-Path $copy 'dist\ClaudeSolidWorksReview-9.8.7.zip' | Should -Exist
        }
        It "refuses a file that isn't a macro" {
            $copy = New-RepoCopy (Join-Path $TestDrive 'r4')
            [IO.File]::WriteAllText((Join-Path $copy 'ClaudeReviewDrawing.swp'), 'not a macro')
            $res = Invoke-Tool $copy 'make-release.ps1' @('-Version', '9.8.7')
            $res.ExitCode | Should -Not -Be 0
            $res.Output | Should -Match "Its code couldn't be read"
        }
        It 'accepts the real macros built in SOLIDWORKS' -Skip:(-not $HasRealSwp) {
            $copy = New-RepoCopy (Join-Path $TestDrive 'r5') -RealSwp
            $res = Invoke-Tool $copy 'make-release.ps1' @('-Version', '9.8.7')
            $res.ExitCode | Should -Be 0 -Because $res.Output
        }
    }

    Context 'Release checks (-DryRun)' {
        BeforeAll {
            $copy = New-RepoCopy (Join-Path $TestDrive 'repo') -Git
            Add-ChangelogSection $copy '9.8.7' 'Dry run feature.'
            Invoke-Git $copy commit -q -am 'Release notes' | Out-Null
            $origin = Join-Path $TestDrive 'origin.git'
            Invoke-Git $TestDrive init -q --bare $origin | Out-Null
            Invoke-Git $copy remote add origin $origin | Out-Null
            Invoke-Git $copy push -q -u origin main | Out-Null
            $head = Invoke-Git $copy rev-parse HEAD
            function Invoke-DryRun([string]$Version = '9.8.7') {
                Invoke-Tool $copy 'make-release.ps1' @('-Version', $Version, '-Upload', '-DryRun', '-SkipTests')
            }
        }

        It 'passes a clean, pushed commit with a CHANGELOG section, and stops before uploading' {
            $res = Invoke-DryRun
            $res.ExitCode | Should -Be 0 -Because $res.Output
            $res.Output | Should -Match "\[ OK \] CHANGELOG\.md has a '## 9\.8\.7' section"
            $res.Output | Should -Match '\[ OK \] No uncommitted changes'
            $res.Output | Should -Match "\[ OK \] HEAD \($($head.Substring(0, 7))\) is pushed"
            $res.Output | Should -Match "doesn't exist yet; it will be created on HEAD"
            $res.Output | Should -Match '\[SKIP\] Tests'
            $res.Output | Should -Match 'passed every check'
            $res.Output | Should -Match "Dry run: every check passed"
            $res.Output | Should -Match "--target $head"
            $res.Output | Should -Not -Match 'Published'
        }

        It 'refuses a version with no CHANGELOG section' {
            $res = Invoke-DryRun '9.9.0'
            $res.ExitCode | Should -Not -Be 0
            $res.Output | Should -Match "\[FAIL\] CHANGELOG\.md has a '## 9\.9\.0' section"
            $res.Output | Should -Not -Match 'Dry run: every check passed'
        }

        It 'refuses uncommitted changes' {
            $readme = Join-Path $copy 'README.md'
            $was = [IO.File]::ReadAllBytes($readme)
            try {
                [IO.File]::AppendAllText($readme, "`nAn edit nobody committed.`n")
                $res = Invoke-DryRun
            } finally { [IO.File]::WriteAllBytes($readme, $was) }
            $res.ExitCode | Should -Not -Be 0
            $res.Output | Should -Match '\[FAIL\] No uncommitted changes: Commit or stash these first: M README\.md'
        }

        It "refuses a commit that isn't pushed" {
            Invoke-Git $copy commit -q --allow-empty -m 'Not pushed' | Out-Null
            try { $res = Invoke-DryRun } finally { Invoke-Git $copy reset -q --soft HEAD~1 | Out-Null }
            $res.ExitCode | Should -Not -Be 0
            $res.Output | Should -Match '\[FAIL\] HEAD \(\w{7}\) is pushed: Push it first'
        }

        It 'refuses a tag that points at another commit (local)' {
            Invoke-Git $copy tag v9.8.7 HEAD~1 | Out-Null
            try { $res = Invoke-DryRun } finally { Invoke-Git $copy tag -d v9.8.7 | Out-Null }
            $res.ExitCode | Should -Not -Be 0
            $res.Output | Should -Match '\[FAIL\] Tag v9\.8\.7 points at HEAD: It points at \w{7}, not HEAD'
        }

        It 'refuses a tag on GitHub that points at another commit' {
            Invoke-Git $copy tag -a v9.8.7 -m 'Old tag' HEAD~1 | Out-Null
            Invoke-Git $copy push -q origin v9.8.7 | Out-Null
            Invoke-Git $copy tag -d v9.8.7 | Out-Null
            try { $res = Invoke-DryRun } finally {
                Invoke-Git $copy push -q origin ':refs/tags/v9.8.7' | Out-Null
                # The dry run fetched the tag back.
                try { Invoke-Git $copy tag -d v9.8.7 | Out-Null } catch { }
            }
            $res.ExitCode | Should -Not -Be 0
            $res.Output | Should -Match '\[FAIL\] Tag v9\.8\.7 points at HEAD'
        }

        It 'accepts an annotated tag on HEAD' {
            Invoke-Git $copy tag -a v9.8.7 -m 'Release' | Out-Null
            Invoke-Git $copy push -q origin v9.8.7 | Out-Null
            try { $res = Invoke-DryRun } finally {
                Invoke-Git $copy push -q origin ':refs/tags/v9.8.7' | Out-Null
                Invoke-Git $copy tag -d v9.8.7 | Out-Null
            }
            $res.ExitCode | Should -Be 0 -Because $res.Output
            $res.Output | Should -Match '\[ OK \] Tag v9\.8\.7 points at HEAD'
            $res.Output | Should -Match 'Macros hold the code in their \.bas at v9\.8\.7'
        }

        It 'rejects a version that is not x.y.z' {
            $res = Invoke-DryRun 'latest'
            $res.ExitCode | Should -Not -Be 0
            $res.Output | Should -Match "isn't of the form 1\.2\.3"
        }
    }
}

Describe 'verify-release.ps1' {
    BeforeAll {
        $copy = New-RepoCopy (Join-Path $TestDrive 'repo')
        $built = Invoke-Tool $copy 'make-release.ps1' @('-Version', '9.8.7')
        if ($built.ExitCode -ne 0) { throw "make-release.ps1 failed: $($built.Output)" }
        $good = Join-Path $copy 'dist\ClaudeSolidWorksReview-9.8.7.zip'
        $prefix = 'ClaudeSolidWorksReview-9.8.7/'
        $bad = Join-Path $TestDrive 'bad'
        New-Item -ItemType Directory -Force -Path $bad | Out-Null
        function Invoke-Verify([string]$Zip, [switch]$Full) {
            $more = @('-Zip', $Zip, '-Version', '9.8.7')
            if (-not $Full) { $more += '-SkipInstall' }
            Invoke-Tool $copy 'verify-release.ps1' $more
        }
    }

    It 'passes the zip make-release.ps1 built (static checks)' {
        $res = Invoke-Verify $good
        $res.ExitCode | Should -Be 0 -Because $res.Output
        ([regex]::Matches($res.Output, '\[PASS\]')).Count | Should -Be 5
    }

    It 'fails a zip with a file missing' {
        $zip = Copy-ZipWith $good (Join-Path $bad 'missing.zip') "${prefix}app/LICENSE" $null
        $res = Invoke-Verify $zip
        $res.ExitCode | Should -BeGreaterThan 0
        $res.Output | Should -Match '\[FAIL\] Layout'
        $res.Output | Should -Match "Missing: ${prefix}app/LICENSE"
    }

    It 'fails a .swp that holds other code than its .bas' {
        $swp = Join-Path $bad 'other.swp'
        New-EditedSwp $swp (Join-Path $copy 'src\ClaudeReviewDrawing.bas') 'Private Const KEEP_DAYS As Long = 14' 'Private Const KEEP_DAYS As Long = 7'
        $zip = Copy-ZipWith $good (Join-Path $bad 'swp.zip') "${prefix}app/ClaudeReviewDrawing.swp" ([IO.File]::ReadAllBytes($swp))
        $res = Invoke-Verify $zip
        $res.ExitCode | Should -Be 1 -Because $res.Output
        $res.Output | Should -Match '\[FAIL\] Macros hold the code in their \.bas'
        $res.Output | Should -Match 'KEEP_DAYS'
    }

    It 'fails a README link to another version' {
        $text = (Read-ZipText $good "${prefix}app/README.md").Replace('/raw/v9.8.7/', '/raw/main/')
        $zip = Copy-ZipWith $good (Join-Path $bad 'readme1.zip') "${prefix}app/README.md" ([Text.Encoding]::UTF8.GetBytes($text))
        $res = Invoke-Verify $zip
        $res.ExitCode | Should -Be 1 -Because $res.Output
        $res.Output | Should -Match '\[FAIL\] README links'
        $res.Output | Should -Match 'points at main, not v9\.8\.7'
    }

    It "fails a README link to a file that isn't installed" {
        $text = (Read-ZipText $good "${prefix}app/README.md").Replace("$Gh/blob/v9.8.7/CONTRIBUTING.md", 'CONTRIBUTING.md')
        $zip = Copy-ZipWith $good (Join-Path $bad 'readme2.zip') "${prefix}app/README.md" ([Text.Encoding]::UTF8.GetBytes($text))
        $res = Invoke-Verify $zip
        $res.ExitCode | Should -Be 1 -Because $res.Output
        $res.Output | Should -Match "CONTRIBUTING\.md isn't installed"
    }

    It 'fails LF line endings in Install.cmd' {
        $text = (Read-ZipText $good "${prefix}Install.cmd").Replace("`r`n", "`n")
        $zip = Copy-ZipWith $good (Join-Path $bad 'lf.zip') "${prefix}Install.cmd" ([Text.Encoding]::ASCII.GetBytes($text))
        $res = Invoke-Verify $zip
        $res.ExitCode | Should -Be 1 -Because $res.Output
        $res.Output | Should -Match '\[FAIL\] Scripts are ASCII with CRLF line endings'
        $res.Output | Should -Match 'Install\.cmd: \d+ of \d+ line endings are LF'
    }

    It 'fails entry names with backslashes (Compress-Archive in Windows PowerShell)' {
        $zip = Join-Path $bad 'backslash.zip'
        $in = [IO.Compression.ZipFile]::OpenRead($good)
        $fs = [IO.File]::Open($zip, 'Create')
        $out = New-Object IO.Compression.ZipArchive($fs, [IO.Compression.ZipArchiveMode]::Create)
        try {
            foreach ($e in $in.Entries) {
                $src = $e.Open(); $dst = $out.CreateEntry($e.FullName.Replace('/', '\')).Open()
                try { $src.CopyTo($dst) } finally { $dst.Dispose(); $src.Dispose() }
            }
        } finally { $out.Dispose(); $fs.Dispose(); $in.Dispose() }
        $res = Invoke-Verify $zip
        $res.ExitCode | Should -Be 1 -Because $res.Output
        $res.Output | Should -Match "\[FAIL\] Zip entry names use /"
        $res.Output | Should -Match '\[PASS\] Layout'
    }

    It 'fails when the installed run-review.ps1 makes no page' {
        $broken = [Text.Encoding]::ASCII.GetBytes("param([string]`$Folder, [switch]`$RenderOnly, [switch]`$NoOpen, [switch]`$NoDialog)`r`nexit 1`r`n")
        $zip = Copy-ZipWith $good (Join-Path $bad 'broken.zip') "${prefix}app/run-review.ps1" $broken
        $res = Invoke-Verify $zip -Full
        $res.ExitCode | Should -Be 1 -Because $res.Output
        $res.Output | Should -Match '\[PASS\] Install\.ps1 -Quiet installs it'
        $res.Output | Should -Match '\[FAIL\] The installed run-review\.ps1 renders a review'
    }
}
