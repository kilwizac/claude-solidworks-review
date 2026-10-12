<#
  Run-Tests.ps1 - runs this repo's tests.

    powershell -ExecutionPolicy Bypass -File tests\Run-Tests.ps1

  By default: everything that doesn't need SOLIDWORKS or Claude - the repo
  checks, run-review.ps1 and its report, the installer, the release
  tooling, and the report page in a browser (Node.js and Microsoft Edge).
  The VBA API name check also runs when SOLIDWORKS 2025 is installed.

    -SolidWorks     also the end-to-end test in SOLIDWORKS 2025: builds the
                    demo drawing, runs the review macro on it and checks
                    what it exported. Starts SOLIDWORKS, or uses the one
                    that's running.
    -Live           also a real review by Claude Code of the demo drawing,
                    checked for the planted mistakes. Takes a few minutes
                    and counts toward your Claude plan's usage.
    -UpdateFixtures with -SolidWorks, copy the demo drawing's export to
                    tests\fixtures\demo; with -Live, also Claude's review.
    -SkipBrowser    leave out the report page tests.
    -Path <files>   only these test files (e.g. tests\RunReview.Tests.ps1).
    -CI             also write JUnit results to tests\.out\results\.

  Pester 5 is used; if it isn't installed, a copy is downloaded once into
  tests\.tools (nothing is installed for the user). The exit code is the
  number of failed test files, 0 when everything passed.

  Keep this file ASCII (Windows PowerShell 5.1).
#>
param(
    [switch]$SolidWorks,
    [switch]$Live,
    [switch]$UpdateFixtures,
    [switch]$SkipBrowser,
    [string[]]$Path,
    [switch]$CI
)

$ErrorActionPreference = 'Stop'
$tests = $PSScriptRoot
$repo = Split-Path -Parent $tests

# The scripts under test run in Windows PowerShell 5.1 (the macro starts
# powershell.exe), so the tests do too. Started from PowerShell 7, it
# inherits 7's module folders first and loads the wrong modules
# (Get-FileHash goes missing), so it gets its own.
$winModules = @(
    (Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'WindowsPowerShell\Modules'),
    (Join-Path $env:ProgramFiles 'WindowsPowerShell\Modules'),
    (Join-Path $env:SystemRoot 'system32\WindowsPowerShell\v1.0\Modules')
) -join ';'
if ($PSVersionTable.PSEdition -eq 'Core' -or ($env:PSModulePath -match '\\PowerShell\\' -and -not $env:CRD_TESTS_RELAUNCHED)) {
    $env:PSModulePath = $winModules
    $env:CRD_TESTS_RELAUNCHED = '1'
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $PSCommandPath)
    foreach ($s in 'SolidWorks', 'Live', 'UpdateFixtures', 'SkipBrowser', 'CI') { if ((Get-Variable $s).Value) { $argList += "-$s" } }
    if ($Path) { $argList += '-Path'; $argList += ($Path | ForEach-Object { (Resolve-Path $_).Path }) -join ',' }
    & powershell.exe @argList
    exit $LASTEXITCODE
}
if ($Path.Count -eq 1 -and $Path[0] -match ',') { $Path = $Path[0] -split ',' }
if ($UpdateFixtures) { $env:CRD_UPDATE_FIXTURES = '1' }

# ---------------------------------------------------------------------
# Pester 5
# ---------------------------------------------------------------------
$pesterVersion = '5.7.1'
function Find-Pester {
    $local = Get-ChildItem -LiteralPath (Join-Path $tests '.tools\Pester') -Filter 'Pester.psd1' -Recurse -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($local) { return $local.FullName }
    $installed = Get-Module -ListAvailable Pester | Where-Object { $_.Version -ge [version]'5.5.0' } |
        Sort-Object Version -Descending | Select-Object -First 1
    if ($installed) { return $installed.Path }
    return $null
}
$pester = Find-Pester
if (-not $pester) {
    Write-Host "Pester 5 isn't installed; downloading Pester $pesterVersion into tests\.tools ..."
    $dest = Join-Path $tests ".tools\Pester\$pesterVersion"
    $zip = Join-Path ([IO.Path]::GetTempPath()) "Pester.$pesterVersion.zip"
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    Invoke-WebRequest -UseBasicParsing -Uri "https://www.powershellgallery.com/api/v2/package/Pester/$pesterVersion" -OutFile $zip
    New-Item -ItemType Directory -Force -Path $dest | Out-Null
    Expand-Archive -LiteralPath $zip -DestinationPath $dest -Force
    Remove-Item -LiteralPath $zip -Force
    $pester = Find-Pester
    if (-not $pester) { throw "Pester $pesterVersion couldn't be set up in $dest." }
}
Get-Module Pester | Remove-Module -Force
Import-Module $pester -Force

# ---------------------------------------------------------------------
# Pester tests
# ---------------------------------------------------------------------
$failed = 0
$resultsDir = Join-Path $tests '.out\results'
if ($CI) { New-Item -ItemType Directory -Force -Path $resultsDir | Out-Null }

$cfg = New-PesterConfiguration
if ($Path) { $cfg.Run.Path = @($Path | ForEach-Object { (Resolve-Path $_).Path }) } else { $cfg.Run.Path = $tests }
$cfg.Run.PassThru = $true
$cfg.Output.Verbosity = 'Detailed'
$exclude = @()
if (-not $SolidWorks) { $exclude += 'SolidWorks' }
if (-not $Live) { $exclude += 'Live' }
$cfg.Filter.ExcludeTag = $exclude
if ($CI) {
    $cfg.TestResult.Enabled = $true
    $cfg.TestResult.OutputFormat = 'JUnitXml'
    $cfg.TestResult.OutputPath = Join-Path $resultsDir 'pester.xml'
}
$result = Invoke-Pester -Configuration $cfg
$failed += @($result.Containers | Where-Object { $_.Result -eq 'Failed' }).Count

# ---------------------------------------------------------------------
# Report page in a browser (Playwright, Microsoft Edge)
# ---------------------------------------------------------------------
if (-not $SkipBrowser -and -not $Path) {
    Write-Host ''
    Write-Host 'Report page tests (tests\browser)' -ForegroundColor Cyan
    $node = Get-Command node -ErrorAction SilentlyContinue
    if (-not $node) {
        Write-Warning 'Node.js is not installed, so the report page tests were skipped. Install it from https://nodejs.org or pass -SkipBrowser.'
        if ($CI) { $failed++ }
    } else {
        Push-Location (Join-Path $tests 'browser')
        try {
            $lock = Get-Item 'package-lock.json' -ErrorAction SilentlyContinue
            $stamp = Get-Item 'node_modules\.package-lock.json' -ErrorAction SilentlyContinue
            if (-not $stamp -or ($lock -and $lock.LastWriteTime -gt $stamp.LastWriteTime)) {
                & npm ci --no-audit --no-fund
                if ($LASTEXITCODE -ne 0) { throw 'npm ci failed in tests\browser.' }
            }
            # Playwright's CLI through node, not npx: npm's .cmd launchers
            # break on a "&" in the folder path and then exit 0.
            $cli = Join-Path (Get-Location) 'node_modules\@playwright\test\cli.js'
            if (-not (Test-Path -LiteralPath $cli)) { throw "Playwright isn't installed in tests\browser ($cli)." }
            $pwArgs = @($cli, 'test')
            if ($CI) { $env:PLAYWRIGHT_JUNIT_OUTPUT_NAME = Join-Path $resultsDir 'browser.xml'; $pwArgs += '--reporter=list,junit' }
            & node @pwArgs
            if ($LASTEXITCODE -ne 0) { $failed++ }
        } finally {
            Pop-Location
        }
    }
}

Write-Host ''
if ($failed -eq 0) { Write-Host 'All tests passed.' -ForegroundColor Green }
else { Write-Host "$failed test file(s) failed." -ForegroundColor Red }
exit $failed
