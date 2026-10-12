<#
  render-fixtures.ps1 - makes the review.html pages the browser tests
  open, with the real run-review.ps1 (-RenderOnly, no Claude).

    powershell -NoProfile -ExecutionPolicy Bypass -File render-fixtures.ps1 -Out <folder>

  Writes <folder>\fixtures.json: fixture name -> full path of its
  review.html. Run by global-setup.js. -ScriptPath renders with another
  copy of run-review.ps1 (global-setup.js passes REPORT_SCRIPT). Keep
  this file ASCII (Windows PowerShell 5.1).
#>
param(
    [Parameter(Mandatory = $true)][string]$Out,
    [string]$ScriptPath
)

$ErrorActionPreference = 'Stop'
# Full path: the run folders are handed to child processes.
$Out = [IO.Path]::GetFullPath([IO.Path]::Combine((Get-Location).Path, $Out))
Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'TestHelpers.psm1') -Force
$fixtures = Join-Path (Split-Path -Parent $PSScriptRoot) 'fixtures'
$reviews = Join-Path $fixtures 'reviews'

if (Test-Path -LiteralPath $Out) { Remove-Item -LiteralPath $Out -Recurse -Force }
New-Item -ItemType Directory -Force -Path $Out | Out-Null
$manifest = [ordered]@{}

$scriptArgs = @{}
if ($ScriptPath) { $scriptArgs.ScriptPath = (Resolve-Path -LiteralPath $ScriptPath).Path }

function Render([string]$key, [string]$folder, [switch]$Pwsh) {
    $r = Invoke-RunReview -Folder $folder -RenderOnly -Pwsh:$Pwsh @scriptArgs
    if ($r.ExitCode -ne 0 -or -not $r.Html) {
        throw "Rendering the '$key' fixture failed (exit $($r.ExitCode)).`n$($r.Log)`n$($r.StdErr)"
    }
    $manifest[$key] = $r.Html
}

# Markers on the test PDF where standard.md pins its findings, so a
# balloon off its spot is visible in a screenshot.
$standardMarkers = @(
    @{ Page = 1; X = 30; Y = 62; Label = '1' }, @{ Page = 1; X = 22; Y = 48; Label = '2' },
    @{ Page = 1; X = 40; Y = 40; Label = '3' }, @{ Page = 2; X = 55; Y = 30; Label = '4' },
    @{ Page = 1; X = 88; Y = 90; Label = '5' }
)

Render 'standard' (New-TestRunFolder -Parent (Join-Path $Out 'standard') -Review (Join-Path $reviews 'standard.md') -Pages 2 -Markers $standardMarkers)
Render 'edge' (New-TestRunFolder -Parent (Join-Path $Out 'edge') -Name 'EDGE-1' -Review (Join-Path $reviews 'edge-cases.md'))
Render 'next-line' (New-TestRunFolder -Parent (Join-Path $Out 'next-line') -Name 'NEXT-2' -Review (Join-Path $reviews 'summary-next-line.md') -Pages 2 `
    -Markers @(@{ Page = 2; X = 50; Y = 50; Label = '1' }, @{ Page = 1; X = 10; Y = 10; Label = '2' }))
Render 'no-table' (New-TestRunFolder -Parent (Join-Path $Out 'no-table') -Name 'CLEAN-3' -Review (Join-Path $reviews 'no-table.md'))
Render 'no-pdf' (New-TestRunFolder -Parent (Join-Path $Out 'no-pdf') -Name 'NOPDF-4' -Review (Join-Path $reviews 'standard.md') -NoPdf)

# A drawing name with spaces, &, # and non-ASCII letters, as file and
# folder names can have: the image and PDF links must still resolve.
$odd = ([char]0x00D8) + '10 BRACKET & PLATE #2 ' + ([char]0x00FC)
Render 'unicode' (New-TestRunFolder -Parent (Join-Path $Out 'unicode') -Name $odd -Review (Join-Path $reviews 'standard.md') -Pages 2 -Markers $standardMarkers)

# PowerShell 7 can't reach the Windows PDF renderer, so the page falls
# back to showing the PDF itself.
if (Get-Command pwsh.exe -ErrorAction SilentlyContinue) {
    Render 'pdf-fallback' (New-TestRunFolder -Parent (Join-Path $Out 'pdf-fallback') -Name 'FALLBACK-5' -Review (Join-Path $reviews 'standard.md')) -Pwsh
}

# A real run of the macro on the demo drawing, when the repo has one.
$demo = Join-Path $fixtures 'demo'
$demoPdf = Get-ChildItem -LiteralPath $demo -Filter '*.pdf' -ErrorAction SilentlyContinue | Select-Object -First 1
if ($demoPdf -and (Test-Path -LiteralPath (Join-Path $demo 'review.md'))) {
    $dir = Join-Path $Out ('demo\' + $demoPdf.BaseName + '_20261011-120000')
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    Get-ChildItem -LiteralPath $demo -File | Where-Object { $_.Name -notmatch '^(review\.html|sheet-\d+\.png|claude-log\.txt)$' } |
        Copy-Item -Destination $dir
    Render 'demo' $dir
}

$json = ConvertTo-Json $manifest
[IO.File]::WriteAllText((Join-Path $Out 'fixtures.json'), $json, (New-Object System.Text.UTF8Encoding $false))
Write-Host "Rendered $($manifest.Count) report fixtures in $Out"
