<#
  make-release.ps1 - packs the release zip and (with -Upload) publishes it.

    powershell -ExecutionPolicy Bypass -File tools\make-release.ps1 -Version 0.3.0 [-Upload] [-DryRun]

  Before running it, rebuild both macros in SOLIDWORKS: open each .swp,
  remove its module, File > Import File the .bas, Debug > Compile, and
  save (Ctrl+S).
    ClaudeReviewDrawing.swp      <- src\ClaudeReviewDrawing.bas
    demo\BuildDemoDrawing.swp    <- demo\BuildDemoDrawing.bas
  The script reads the code inside each .swp and refuses one whose code
  differs from its .bas (-AllowStale makes that a warning, for testing
  only).

  Output:
    dist\ClaudeSolidWorksReview-<version>.zip
      Install.cmd, Install.ps1        the installer
      app\                            what gets installed
    dist\release-notes-<version>.md   the release notes, to preview

  -Upload attaches the zip to GitHub release v<version>, creating the
  release (notes from that version's CHANGELOG.md section) if it doesn't
  exist. It first checks that:
    - CHANGELOG.md has a "## <version>" section;
    - the working tree has no uncommitted changes, and HEAD is pushed;
    - tag v<version>, if it already exists, points at HEAD;
    - the tests pass (tests\Run-Tests.ps1; -SkipTests skips them);
    - the zip passes tools\verify-release.ps1.
  A new release is created on HEAD (--target), the commit just tested.
  -DryRun runs every one of those checks and stops before uploading.

  Keep this file ASCII (Windows PowerShell 5.1).
#>
param(
    [Parameter(Mandatory = $true)][string]$Version,
    [switch]$Upload,
    [switch]$DryRun,
    [switch]$SkipTests,
    [switch]$AllowStale
)

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$name = "ClaudeSolidWorksReview-$Version"
$tag = "v$Version"
$ghRepo = 'kilwizac/claude-solidworks-review'
$utf8 = New-Object System.Text.UTF8Encoding $false
$publish = $Upload -or $DryRun

if ($Version -notmatch '^\d+\.\d+\.\d+(-[0-9A-Za-z.]+)?$') {
    throw "Version '$Version' isn't of the form 1.2.3 (or 1.2.3-rc.1)."
}

# Runs git in the repo; returns its output lines, $null when it fails.
function Invoke-Git {
    # Under 'Stop', Windows PowerShell turns git's stderr into an error.
    $ErrorActionPreference = 'Continue'
    $out = & git -C $repo @args 2>$null
    if ($LASTEXITCODE -ne 0) { return $null }
    return $out
}

# ---------------------------------------------------------------------
# Built macros must hold the code in their source
# ---------------------------------------------------------------------
Import-Module (Join-Path $PSScriptRoot 'SwpSource.psm1') -Force
$macros = @(
    @{ Swp = 'ClaudeReviewDrawing.swp'; Bas = 'src\ClaudeReviewDrawing.bas' },
    @{ Swp = 'demo\BuildDemoDrawing.swp'; Bas = 'demo\BuildDemoDrawing.bas' }
)
foreach ($m in $macros) {
    $swp = Join-Path $repo $m.Swp
    $bas = Join-Path $repo $m.Bas
    if (-not (Test-Path -LiteralPath $swp)) { throw "$($m.Swp) is missing. Build it in SOLIDWORKS from $($m.Bas)." }
    try { $cmp = Compare-SwpSource -Swp $swp -Bas $bas }
    catch { $cmp = [pscustomobject]@{ Match = $false; Detail = "Its code couldn't be read: $($_.Exception.Message)" } }
    if ($cmp.Match) {
        Write-Host "$($m.Swp): $($cmp.Detail)"
    } else {
        $msg = "$($m.Swp) doesn't hold the code in $($m.Bas). $($cmp.Detail)`n" +
               "Re-import the .bas in SOLIDWORKS, compile, and save (Ctrl+S)."
        if ($AllowStale) { Write-Warning $msg } else { throw $msg }
    }
}

# ---------------------------------------------------------------------
# Release checks (-Upload, -DryRun), the quick ones before building
# ---------------------------------------------------------------------
$log = [IO.File]::ReadAllText((Join-Path $repo 'CHANGELOG.md'))
$section = [regex]::Match($log, "(?ms)^## $([regex]::Escape($Version))\b.*?\r?\n(.*?)(?=^## |\z)")
$head = @(Invoke-Git rev-parse HEAD)[0]

if ($publish) {
    Write-Host ''
    Write-Host "Release checks for $tag"
    $failed = New-Object System.Collections.Generic.List[string]
    function Write-Check([string]$text, [string]$problem) {
        if ($problem) {
            Write-Host "[FAIL] $text`: $problem" -ForegroundColor Red
            $failed.Add($problem)
        } else {
            Write-Host "[ OK ] $text" -ForegroundColor Green
        }
    }

    if ($section.Success -and $section.Groups[1].Value.Trim()) {
        Write-Check "CHANGELOG.md has a '## $Version' section" $null
    } else {
        Write-Check "CHANGELOG.md has a '## $Version' section" "Rename '## Unreleased' to '## $Version - $(Get-Date -Format yyyy-MM-dd)' (or add the section) and commit."
    }

    if (-not $head) {
        Write-Check 'Git repository' "$repo isn't a git repository."
    } else {
        $changes = @(Invoke-Git status --porcelain --untracked-files=no)
        if ($changes.Count -eq 0) {
            Write-Check 'No uncommitted changes' $null
        } else {
            Write-Check 'No uncommitted changes' ("Commit or stash these first: " + (($changes | ForEach-Object { $_.Trim() }) -join ', '))
        }

        # What the remote has now, not when it was last fetched.
        $null = Invoke-Git fetch --quiet --tags origin
        $remoteBranches = @(Invoke-Git branch -r --contains HEAD | ForEach-Object { $_.Trim() } | Where-Object { $_ -like 'origin/*' })
        if ($remoteBranches.Count -gt 0) {
            Write-Check "HEAD ($($head.Substring(0, 7))) is pushed" $null
        } else {
            Write-Check "HEAD ($($head.Substring(0, 7))) is pushed" 'Push it first (git push); the release is made from the commit on GitHub.'
        }

        # An existing tag, local or on the remote, must be this commit.
        $tagCommits = @()
        $local = @(Invoke-Git rev-parse -q --verify "refs/tags/$tag^{commit}")[0]
        if ($local) { $tagCommits += $local }
        $remote = @(Invoke-Git ls-remote --tags origin | Where-Object { $_ -match "\srefs/tags/$([regex]::Escape($tag))(\^\{\})?$" })
        # An annotated tag's commit is on its peeled ("^{}") line.
        $peeled = $remote | Where-Object { $_ -match '\^\{\}$' } | Select-Object -First 1
        if (-not $peeled) { $peeled = $remote | Select-Object -First 1 }
        if ($peeled) { $tagCommits += ($peeled -split '\s+')[0] }
        $other = @($tagCommits | Where-Object { $_ -ne $head } | Select-Object -Unique)
        if ($tagCommits.Count -eq 0) {
            Write-Check "Tag $tag" $null
            Write-Host "       (doesn't exist yet; it will be created on HEAD)"
        } elseif ($other.Count -eq 0) {
            Write-Check "Tag $tag points at HEAD" $null
        } else {
            Write-Check "Tag $tag points at HEAD" "It points at $($other[0].Substring(0, 7)), not HEAD. Release from that commit, or use a new version."
        }
    }

    if ($failed.Count -gt 0) {
        throw "Not releasing: $($failed.Count) check(s) failed (see above)."
    }

    if ($SkipTests) {
        Write-Host '[SKIP] Tests (-SkipTests)' -ForegroundColor Yellow
    } else {
        Write-Host 'Running the tests (tests\Run-Tests.ps1) ...'
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'tests\Run-Tests.ps1')
        if ($LASTEXITCODE -ne 0) { throw "Not releasing: the tests failed (exit code $LASTEXITCODE)." }
        Write-Check 'Tests pass' $null
    }
}
else {
    $dirty = Invoke-Git status --porcelain
    if ($dirty) { Write-Warning 'The working tree has uncommitted changes; the zip uses the files on disk.' }
}

# ---------------------------------------------------------------------
# Stage
# ---------------------------------------------------------------------
$stageRoot = Join-Path ([IO.Path]::GetTempPath()) 'claude-review-release'
$stage = Join-Path $stageRoot $name
if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force }
New-Item -ItemType Directory -Force -Path (Join-Path $stage 'app\demo') | Out-Null

# SOLIDWORKS may hold the .swp open: copy with shared read.
function Copy-Shared([string]$from, [string]$to) {
    $in = [IO.File]::Open($from, 'Open', 'Read', 'ReadWrite')
    try {
        $out = [IO.File]::Create($to)
        try { $in.CopyTo($out) } finally { $out.Close() }
    } finally { $in.Close() }
}
Copy-Item -LiteralPath (Join-Path $repo 'installer\Install.cmd') -Destination $stage
Copy-Item -LiteralPath (Join-Path $repo 'installer\Install.ps1') -Destination $stage
Copy-Shared (Join-Path $repo 'ClaudeReviewDrawing.swp') (Join-Path $stage 'app\ClaudeReviewDrawing.swp')
Copy-Shared (Join-Path $repo 'demo\BuildDemoDrawing.swp') (Join-Path $stage 'app\demo\BuildDemoDrawing.swp')
foreach ($f in 'run-review.ps1', 'review-instructions.md', 'README.md', 'LICENSE') {
    Copy-Item -LiteralPath (Join-Path $repo $f) -Destination (Join-Path $stage 'app')
}

# The installed README has no docs\, src\ or installer\ beside it: its
# links to files that aren't installed go to GitHub, at this version.
$readme = Join-Path $stage 'app\README.md'
$text = [IO.File]::ReadAllText($readme)
$text = [regex]::Replace($text, '(\]\(|src="|srcset=")(?!https?:|mailto:|#)([^)"\s]+)', {
    param($m)
    $path = $m.Groups[2].Value
    if (Test-Path -LiteralPath (Join-Path $stage ('app\' + ($path -replace '#.*$', '')))) { return $m.Value }
    $kind = 'blob'; if ($path -match '\.(png|jpe?g|gif|svg)$') { $kind = 'raw' }
    return $m.Groups[1].Value + "https://github.com/$ghRepo/$kind/$tag/$path"
})
[IO.File]::WriteAllText($readme, $text, $utf8)

# ---------------------------------------------------------------------
# Zip. Entry names use "/" as the zip format requires (Windows
# PowerShell's Compress-Archive writes "\", which only Windows reads).
# ---------------------------------------------------------------------
$dist = Join-Path $repo 'dist'
New-Item -ItemType Directory -Force -Path $dist | Out-Null
$zip = Join-Path $dist "$name.zip"
if (Test-Path -LiteralPath $zip) { Remove-Item -LiteralPath $zip -Force }
Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
$files = @(Get-ChildItem -LiteralPath $stage -Recurse -File | Sort-Object { $_.FullName.Substring($stage.Length) })
$fs = [IO.File]::Open($zip, 'CreateNew')
try {
    $archive = New-Object System.IO.Compression.ZipArchive($fs, [System.IO.Compression.ZipArchiveMode]::Create)
    try {
        foreach ($f in $files) {
            $entryName = $name + '/' + $f.FullName.Substring($stage.Length + 1).Replace('\', '/')
            $entry = $archive.CreateEntry($entryName, [System.IO.Compression.CompressionLevel]::Optimal)
            $entry.LastWriteTime = $f.LastWriteTime
            $in = [IO.File]::OpenRead($f.FullName)
            $out = $entry.Open()
            try { $in.CopyTo($out) } finally { $out.Dispose(); $in.Dispose() }
        }
    } finally { $archive.Dispose() }
} finally { $fs.Dispose() }

# Read it back: every file, "/" names only.
$check = [IO.Compression.ZipFile]::OpenRead($zip)
try {
    $names = @($check.Entries | ForEach-Object { $_.FullName })
} finally { $check.Dispose() }
if ($names.Count -ne $files.Count -or @($names | Where-Object { $_ -match '\\' }).Count -gt 0) {
    throw "The zip didn't come out right: $($names.Count) entries for $($files.Count) files."
}
Remove-Item -LiteralPath $stage -Recurse -Force
if (-not (Get-ChildItem -LiteralPath $stageRoot -ErrorAction SilentlyContinue)) { Remove-Item -LiteralPath $stageRoot -Force -ErrorAction SilentlyContinue }
Write-Host "Built $zip ($([int]((Get-Item -LiteralPath $zip).Length / 1KB)) KB)"

# ---------------------------------------------------------------------
# Release notes: this version's CHANGELOG section.
# ---------------------------------------------------------------------
$notes = Join-Path $dist "release-notes-$Version.md"
$body = "Download **$name.zip**, extract it, and double-click **Install.cmd**.`n`n"
if ($section.Success) { $body += $section.Groups[1].Value.Trim() + "`n" }
else { Write-Warning "CHANGELOG.md has no '## $Version' section, so the release notes are only the download line." }
[IO.File]::WriteAllText($notes, $body, $utf8)
Write-Host "Release notes: $notes"

if (-not $publish) { return }

# ---------------------------------------------------------------------
# Check the zip as a user would get it, then upload
# ---------------------------------------------------------------------
Write-Host ''
Write-Host "Checking the zip (tools\verify-release.ps1) ..."
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'verify-release.ps1') -Zip $zip -Version $Version
if ($LASTEXITCODE -ne 0) { throw "Not releasing: the zip failed $LASTEXITCODE check(s) in verify-release.ps1." }

$exists = $true
if ($DryRun) {
    Write-Host ''
    Write-Host "Dry run: every check passed. -Upload would now run:"
    Write-Host "  gh release view $tag --repo $ghRepo"
    Write-Host "  then, if the release exists:  gh release upload $tag $zip --clobber --repo $ghRepo"
    Write-Host "  otherwise:  gh release create $tag $zip --repo $ghRepo --target $head --title $tag --notes-file $notes"
    return
}

try { gh release view $tag --repo $ghRepo *> $null; if ($LASTEXITCODE -ne 0) { $exists = $false } } catch { $exists = $false }
if ($exists) {
    gh release upload $tag $zip --clobber --repo $ghRepo
} else {
    gh release create $tag $zip --repo $ghRepo --target $head --title "$tag" --notes-file $notes
}
if ($LASTEXITCODE -ne 0) { throw "gh couldn't publish $tag (exit code $LASTEXITCODE)." }
Write-Host "Published $name.zip to $tag"
