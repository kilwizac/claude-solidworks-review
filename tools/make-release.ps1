<#
  make-release.ps1 - packs the release zip and (with -Upload) publishes it.

    powershell -ExecutionPolicy Bypass -File tools\make-release.ps1 -Version 0.2.0 [-Upload]

  Before running it, rebuild both macros in SOLIDWORKS: open each .swp,
  remove its module, File > Import File the .bas, Debug > Compile, and
  save (Ctrl+S).
    ClaudeReviewDrawing.swp      <- src\ClaudeReviewDrawing.bas
    demo\BuildDemoDrawing.swp    <- demo\BuildDemoDrawing.bas
  The script refuses a .swp that's older than its .bas (-AllowStale skips
  that check, for testing only).

  Output: dist\ClaudeSolidWorksReview-<version>.zip
    Install.cmd, Install.ps1        the installer
    app\                            what gets installed
  -Upload attaches it to GitHub release v<version>, creating the release
  (notes from that version's CHANGELOG.md section) if it doesn't exist.

  Keep this file ASCII (Windows PowerShell 5.1).
#>
param(
    [Parameter(Mandatory = $true)][string]$Version,
    [switch]$Upload,
    [switch]$AllowStale
)

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$name = "ClaudeSolidWorksReview-$Version"

# Built macros must be current with their source.
$macros = @(
    @{ Swp = 'ClaudeReviewDrawing.swp'; Bas = 'src\ClaudeReviewDrawing.bas' },
    @{ Swp = 'demo\BuildDemoDrawing.swp'; Bas = 'demo\BuildDemoDrawing.bas' }
)
foreach ($m in $macros) {
    $swp = Join-Path $repo $m.Swp
    $bas = Join-Path $repo $m.Bas
    if (-not (Test-Path -LiteralPath $swp)) { throw "$($m.Swp) is missing. Build it in SOLIDWORKS from $($m.Bas)." }
    if ((Get-Item -LiteralPath $swp).LastWriteTime -lt (Get-Item -LiteralPath $bas).LastWriteTime) {
        $msg = "$($m.Swp) is older than $($m.Bas). Re-import the .bas in SOLIDWORKS, compile, and save (Ctrl+S)."
        if ($AllowStale) { Write-Warning $msg } else { throw $msg }
    }
}

$dirty = git -C $repo status --porcelain
if ($dirty) { Write-Warning 'The working tree has uncommitted changes; the zip uses the files on disk.' }

# Stage
$stage = Join-Path ([IO.Path]::GetTempPath()) "claude-review-release\$name"
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
    return $m.Groups[1].Value + "https://github.com/kilwizac/claude-solidworks-review/$kind/v$Version/$path"
})
[IO.File]::WriteAllText($readme, $text, (New-Object System.Text.UTF8Encoding $false))

# Zip
$dist = Join-Path $repo 'dist'
New-Item -ItemType Directory -Force -Path $dist | Out-Null
$zip = Join-Path $dist "$name.zip"
if (Test-Path -LiteralPath $zip) { Remove-Item -LiteralPath $zip -Force }
Compress-Archive -Path $stage -DestinationPath $zip
Write-Host "Built $zip ($([int]((Get-Item -LiteralPath $zip).Length / 1KB)) KB)"

if (-not $Upload) { return }

# Release notes: this version's CHANGELOG section.
$tag = "v$Version"
$log = [IO.File]::ReadAllText((Join-Path $repo 'CHANGELOG.md'))
$m = [regex]::Match($log, "(?ms)^## $([regex]::Escape($Version))\b.*?\r?\n(.*?)(?=^## |\z)")
$notes = Join-Path $stage '..\release-notes.md'
$body = "Download **$name.zip**, extract it, and double-click **Install.cmd**.`n`n"
if ($m.Success) { $body += $m.Groups[1].Value.Trim() + "`n" }
[IO.File]::WriteAllText($notes, $body, (New-Object System.Text.UTF8Encoding $false))

$exists = $true
try { gh release view $tag --repo kilwizac/claude-solidworks-review *> $null; if ($LASTEXITCODE -ne 0) { $exists = $false } } catch { $exists = $false }
if ($exists) {
    gh release upload $tag $zip --clobber --repo kilwizac/claude-solidworks-review
} else {
    gh release create $tag $zip --repo kilwizac/claude-solidworks-review --title "$tag" --notes-file $notes
}
Write-Host "Published $name.zip to $tag"
