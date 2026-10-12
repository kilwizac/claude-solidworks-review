<#
  verify-release.ps1 - checks a release zip the way a user gets it.

    powershell -ExecutionPolicy Bypass -File tools\verify-release.ps1 -Zip dist\ClaudeSolidWorksReview-0.3.0.zip [-CheckLinks]

  Checks:
    - the zip's entry names use "/" (Windows PowerShell's Compress-Archive
      writes "\", which only Windows reads);
    - the layout: ClaudeSolidWorksReview-<version>\ with exactly the
      installer and the app\ files;
    - Install.cmd, Install.ps1 and run-review.ps1 are ASCII with CRLF line
      endings (Windows PowerShell 5.1 and cmd.exe need both);
    - the code inside each .swp is the code in its .bas at -SourceRef;
    - README links to files that aren't installed go to GitHub at
      v<version>, and the rest point at installed files;
    - Install.ps1 -Quiet installs it into a temporary folder;
    - the installed run-review.ps1 renders a review page with balloons;
    - with -CheckLinks, those GitHub links answer (needs the tag pushed).

  -Version     default: from the zip's name
  -SourceRef   git ref the .bas files are read from; default: tag
               v<version> if it exists, else the files on disk
  -SkipInstall only the checks that don't install or render
  -Keep        keep the temporary folder (its path is printed)

  Prints [PASS] / [FAIL] per check. The exit code is the number of failed
  checks, 0 when the zip is good.

  Needs this repository beside it (tests\TestHelpers.psm1,
  tools\SwpSource.psm1). Keep this file ASCII (Windows PowerShell 5.1).
#>
param(
    [Parameter(Mandatory = $true)][string]$Zip,
    [string]$Version,
    [string]$SourceRef,
    [switch]$CheckLinks,
    [switch]$SkipInstall,
    [switch]$Keep
)

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$ghRepo = 'kilwizac/claude-solidworks-review'
Import-Module (Join-Path $PSScriptRoot 'SwpSource.psm1') -Force
Import-Module (Join-Path $repo 'tests\TestHelpers.psm1') -Force
Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem

$Zip = Convert-Path -LiteralPath $Zip
if (-not $Version) {
    $m = [regex]::Match((Split-Path $Zip -Leaf), '^ClaudeSolidWorksReview-(.+)\.zip$')
    if (-not $m.Success) { throw "Can't tell the version from the zip's name; pass -Version." }
    $Version = $m.Groups[1].Value
}
$name = "ClaudeSolidWorksReview-$Version"
$tag = "v$Version"

$failures = New-Object System.Collections.Generic.List[string]
function Write-Result([string]$check, [string[]]$problems, [string]$okDetail) {
    $problems = @($problems | Where-Object { $_ })
    if ($problems.Count -eq 0) {
        $line = "[PASS] $check"
        if ($okDetail) { $line += ": $okDetail" }
        Write-Host $line -ForegroundColor Green
    } else {
        Write-Host "[FAIL] $check" -ForegroundColor Red
        foreach ($p in $problems) { Write-Host "       $p" }
        $failures.Add($check)
    }
}

# Byte-exact copy of a file at a git ref (git show, unconverted).
function Save-GitBlob([string]$spec, [string]$outFile) {
    $psi = New-Object System.Diagnostics.ProcessStartInfo 'git'
    $psi.Arguments = "-C `"$repo`" show `"$spec`""
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $p = [Diagnostics.Process]::Start($psi)
    $errTask = $p.StandardError.ReadToEndAsync()
    $fs = [IO.File]::Create($outFile)
    try { $p.StandardOutput.BaseStream.CopyTo($fs) } finally { $fs.Close() }
    $p.WaitForExit()
    if ($p.ExitCode -ne 0) { throw "git show $spec failed: $($errTask.Result.Trim())" }
}

$work = Join-Path ([IO.Path]::GetTempPath()) ('verify-release-' + [IO.Path]::GetRandomFileName().Replace('.', ''))
New-Item -ItemType Directory -Force -Path $work | Out-Null
Write-Host "Verifying $(Split-Path $Zip -Leaf) (version $Version)"

try {
    # -----------------------------------------------------------------
    # Entry names and layout
    # -----------------------------------------------------------------
    $archive = [IO.Compression.ZipFile]::OpenRead($Zip)
    try {
        $entries = @($archive.Entries | Where-Object { $_.FullName -notmatch '[\\/]$' })
        $raw = @($entries | ForEach-Object { $_.FullName })
        $backslashed = @($raw | Where-Object { $_ -match '\\' })
        $problems = @()
        if ($backslashed.Count -gt 0) {
            $problems += "$($backslashed.Count) of $($raw.Count) entry names use '\' (e.g. $($backslashed[0])); the zip format needs '/'."
        }
        Write-Result 'Zip entry names use /' $problems "$($raw.Count) entries"

        $expected = @('Install.cmd', 'Install.ps1', 'app/ClaudeReviewDrawing.swp', 'app/run-review.ps1',
                      'app/review-instructions.md', 'app/README.md', 'app/LICENSE', 'app/demo/BuildDemoDrawing.swp') |
                    ForEach-Object { "$name/$_" }
        $actual = @($raw | ForEach-Object { $_.Replace('\', '/') })
        $missing = @($expected | Where-Object { $actual -notcontains $_ })
        $extra = @($actual | Where-Object { $expected -notcontains $_ })
        $problems = @()
        if ($missing.Count) { $problems += 'Missing: ' + ($missing -join ', ') }
        if ($extra.Count) { $problems += 'Not expected: ' + ($extra -join ', ') }
        Write-Result 'Layout' $problems "$name\ with the installer and $($expected.Count - 2) app files"

        # Extract with "/" or "\" names alike.
        $root = Join-Path $work 'zip'
        foreach ($e in $entries) {
            $dest = Join-Path $root ($e.FullName.Replace('/', '\'))
            New-Item -ItemType Directory -Force -Path (Split-Path $dest) | Out-Null
            [IO.Compression.ZipFileExtensions]::ExtractToFile($e, $dest, $true)
        }
    } finally { $archive.Dispose() }
    $pkg = Join-Path $root $name
    $app = Join-Path $pkg 'app'

    # -----------------------------------------------------------------
    # Scripts: ASCII, CRLF
    # -----------------------------------------------------------------
    $problems = @()
    foreach ($f in 'Install.cmd', 'Install.ps1', 'app\run-review.ps1') {
        $p = Join-Path $pkg $f
        if (-not (Test-Path -LiteralPath $p)) { continue }
        $bytes = [IO.File]::ReadAllBytes($p)
        $nonAscii = @($bytes | Where-Object { $_ -gt 127 }).Count
        if ($nonAscii) { $problems += "${f}: $nonAscii non-ASCII bytes" }
        $lf = 0; $bare = 0
        for ($i = 0; $i -lt $bytes.Length; $i++) {
            if ($bytes[$i] -eq 10) { $lf++; if ($i -eq 0 -or $bytes[$i - 1] -ne 13) { $bare++ } }
        }
        if ($lf -eq 0 -or $bare -gt 0) { $problems += "${f}: $bare of $lf line endings are LF, not CRLF" }
    }
    Write-Result 'Scripts are ASCII with CRLF line endings' $problems 'Install.cmd, Install.ps1, run-review.ps1'

    # -----------------------------------------------------------------
    # Macros hold the code at SourceRef
    # -----------------------------------------------------------------
    if (-not $SourceRef) {
        $hasTag = $false
        try {
            $ErrorActionPreference = 'Continue'
            & git -C $repo rev-parse -q --verify "refs/tags/$tag^{commit}" *> $null
            $hasTag = ($LASTEXITCODE -eq 0)
        } catch { } finally { $ErrorActionPreference = 'Stop' }
        if ($hasTag) { $SourceRef = $tag }
    }
    $from = 'the files on disk'; if ($SourceRef) { $from = $SourceRef }
    $problems = @()
    $details = @()
    foreach ($pair in @(@('app\ClaudeReviewDrawing.swp', 'src/ClaudeReviewDrawing.bas'), @('app\demo\BuildDemoDrawing.swp', 'demo/BuildDemoDrawing.bas'))) {
        $swp = Join-Path $pkg $pair[0]
        if (-not (Test-Path -LiteralPath $swp)) { $problems += "$($pair[0]) is missing"; continue }
        try {
            if ($SourceRef) {
                $bas = Join-Path $work ([IO.Path]::GetFileName($pair[1]))
                Save-GitBlob "$($SourceRef):$($pair[1])" $bas
            } else {
                $bas = Join-Path $repo $pair[1].Replace('/', '\')
            }
            $cmp = Compare-SwpSource -Swp $swp -Bas $bas
            if ($cmp.Match) { $details += $cmp.Detail } else { $problems += "$($pair[0]): $($cmp.Detail)" }
        } catch {
            $problems += "$($pair[0]): $($_.Exception.Message)"
        }
    }
    Write-Result "Macros hold the code in their .bas at $from" $problems ($details -join '; ')

    # -----------------------------------------------------------------
    # README links
    # -----------------------------------------------------------------
    $problems = @()
    $ghLinks = New-Object System.Collections.Generic.List[string]
    $readme = Join-Path $app 'README.md'
    if (Test-Path -LiteralPath $readme) {
        $text = [IO.File]::ReadAllText($readme)
        foreach ($m in [regex]::Matches($text, '(?:\]\(|src="|srcset=")([^)"\s]+)')) {
            $link = $m.Groups[1].Value
            if ($link -match '^(mailto:|#)') { continue }
            $gh = [regex]::Match($link, "^https://github\.com/$([regex]::Escape($ghRepo))/(blob|raw)/([^/]+)/(.+)$")
            if ($gh.Success) {
                $kind = $gh.Groups[1].Value; $ref = $gh.Groups[2].Value; $path = $gh.Groups[3].Value
                if ($ref -ne $tag) { $problems += "$link points at $ref, not $tag" }
                $wantKind = 'blob'; if ($path -match '\.(png|jpe?g|gif|svg)$') { $wantKind = 'raw' }
                if ($kind -ne $wantKind) { $problems += "$link should be a $wantKind link" }
                $ghLinks.Add($link)
            } elseif ($link -notmatch '^https?:') {
                if (-not (Test-Path -LiteralPath (Join-Path $app ($link -replace '#.*$', '')))) {
                    $problems += "$link isn't installed, so it should go to GitHub"
                }
            }
        }
    } else {
        $problems += 'app\README.md is missing'
    }
    Write-Result "README links go to installed files or GitHub at $tag" $problems "$($ghLinks.Count) GitHub links"

    if ($CheckLinks) {
        $problems = @()
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        foreach ($url in @($ghLinks | ForEach-Object { $_ -replace '#.*$', '' } | Select-Object -Unique)) {
            try {
                $r = Invoke-WebRequest -UseBasicParsing -Uri $url -Method Head -MaximumRedirection 5
                if ($r.StatusCode -ne 200) { $problems += "$url answered $($r.StatusCode)" }
            } catch {
                $code = ''
                if ($_.Exception.Response) { $code = [int]$_.Exception.Response.StatusCode }
                $problems += "$url failed: $code $($_.Exception.Message)".Trim()
            }
        }
        Write-Result 'GitHub links answer' $problems "$(@($ghLinks | Select-Object -Unique).Count) checked"
    }

    if (-not $SkipInstall) {
        # -------------------------------------------------------------
        # Install, as Install.cmd would, without questions
        # -------------------------------------------------------------
        $target = Join-Path $work 'installed'
        $problems = @()
        $r = Invoke-Process -FilePath 'powershell.exe' -WorkingDirectory $pkg `
            -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $pkg 'Install.ps1'), '-Quiet', '-InstallDir', $target) `
            -Environment @{ PATH = (Get-PathWithoutClaude); USERPROFILE = (Join-Path $work 'profile') } -TimeoutSeconds 300
        if ($r.ExitCode -ne 0) {
            $tail = @(($r.StdOut + $r.StdErr).Trim() -split "`r?`n" | Select-Object -Last 3) -join ' / '
            $problems += "Install.ps1 exited with $($r.ExitCode): $tail"
        }
        $installedFiles = @('ClaudeReviewDrawing.swp', 'run-review.ps1', 'review-instructions.md', 'review-instructions.default.md',
                            'README.md', 'LICENSE', 'demo\BuildDemoDrawing.swp')
        foreach ($f in $installedFiles) {
            if (-not (Test-Path -LiteralPath (Join-Path $target $f))) { $problems += "$f wasn't installed" }
        }
        Write-Result 'Install.ps1 -Quiet installs it' $problems "$($installedFiles.Count) files in a temporary folder"

        # -------------------------------------------------------------
        # The installed run-review.ps1 makes a page with balloons
        # -------------------------------------------------------------
        $problems = @()
        $installedScript = Join-Path $target 'run-review.ps1'
        $fixture = Join-Path $repo 'tests\fixtures\reviews\standard.md'
        if (-not (Test-Path -LiteralPath $installedScript)) {
            $problems += "run-review.ps1 wasn't installed"
        } elseif (-not (Test-Path -LiteralPath $fixture)) {
            $problems += "The test review $fixture is missing"
        } else {
            $run = New-TestRunFolder -Parent (Join-Path $work 'runs') -Name 'VERIFY-100' -Review $fixture -Pages 2
            # Rendering only: no Claude Code needed (or found).
            $res = Invoke-RunReview -Folder $run -RenderOnly -NoClaude -ScriptPath $installedScript
            if ($res.ExitCode -ne 0) {
                $why = @(($res.Log + "`n" + $res.StdErr).Trim() -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -First 2) -join ' / '
                $problems += "run-review.ps1 exited with $($res.ExitCode): $why"
            }
            if (-not $res.Html) {
                $problems += 'No review.html was written'
            } else {
                $model = Get-ReportModel $res.Html
                if ($model.Items.Count -ne 6) { $problems += "The page lists $($model.Items.Count) findings, not 6" }
                if ($model.Pins.Count -lt 1) { $problems += "The page has no balloons on the drawing. $($res.Log.Trim())" }
            }
        }
        $okText = ''
        if ($problems.Count -eq 0) { $okText = "$($model.Items.Count) findings, $($model.Pins.Count) balloons on $($model.Sheets.Count) sheets" }
        Write-Result 'The installed run-review.ps1 renders a review' $problems $okText
    }
}
finally {
    if ($Keep) { Write-Host "Kept $work" }
    else { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue }
}

Write-Host ''
if ($failures.Count -eq 0) {
    Write-Host "$name.zip passed every check." -ForegroundColor Green
} else {
    Write-Host "$name.zip failed $($failures.Count) check(s): $($failures -join '; ')" -ForegroundColor Red
}
exit $failures.Count
