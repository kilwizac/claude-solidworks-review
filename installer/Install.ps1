<#
  Install.ps1 - installs "Review with Claude" for SOLIDWORKS from the
  release zip (run it through Install.cmd).

  1. Checks for SOLIDWORKS 2025+, the Claude Code CLI (offers to install
     it with Anthropic's official installer and to sign in) and Claude
     Desktop (optional). Install.cmd has already checked that Group
     Policy allows PowerShell scripts.
  2. Removes the "downloaded from the internet" flag from the files.
  3. Copies the macros and scripts to a folder you choose. A customised
     review-instructions.md is kept; the default checklist is always
     saved beside it as review-instructions.default.md.

  -InstallDir <folder>  install there without asking
  -Quiet                no questions: default folder, don't install or
                        sign in to Claude Code, don't open the folder

  Keep this file ASCII: Windows PowerShell 5.1 reads BOM-less scripts in
  the ANSI code page.
#>
[CmdletBinding()]
param(
    [string]$InstallDir,
    [switch]$Quiet
)

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$app = Join-Path $here 'app'
# GetFolderPath gives "" when Documents doesn't exist (e.g. a broken
# folder redirection).
$documents = [Environment]::GetFolderPath('MyDocuments')
if (-not $documents) { $documents = Join-Path $env:USERPROFILE 'Documents' }
$defaultDir = Join-Path $documents 'SOLIDWORKS Macros\Claude Review'
$results = New-Object System.Collections.Generic.List[object]

function Add-Result([string]$item, [string]$status, [string]$detail) {
    $results.Add([pscustomobject]@{ Item = $item; Status = $status; Detail = $detail })
}
function Write-Step([string]$text) { Write-Host ''; Write-Host $text -ForegroundColor Cyan }
function Read-YesNo([string]$question, [bool]$default) {
    if ($Quiet) { return $default }
    $suffix = '[y/N]'; if ($default) { $suffix = '[Y/n]' }
    $answer = Read-Host "$question $suffix"
    if (-not $answer) { return $default }
    return ($answer -match '^\s*(y|yes)\s*$')
}
function Find-Claude {
    $cmd = Get-Command claude -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($cmd) { return $cmd.Source }
    $native = Join-Path $env:USERPROFILE '.local\bin\claude.exe'
    if (Test-Path -LiteralPath $native) { return $native }
    return $null
}

Write-Host ''
Write-Host 'Review with Claude for SOLIDWORKS - installer' -ForegroundColor White
Write-Host '---------------------------------------------'

# ---------------------------------------------------------------------
# The package must be extracted, not run from inside the zip
# ---------------------------------------------------------------------
$payload = @('ClaudeReviewDrawing.swp', 'run-review.ps1', 'review-instructions.md')
foreach ($p in $payload) {
    if (-not (Test-Path -LiteralPath (Join-Path $app $p))) {
        Write-Host ''
        Write-Host "Can't find app\$p next to this installer." -ForegroundColor Red
        Write-Host 'Extract the whole zip first (right-click > Extract All), then run Install.cmd from the extracted folder.'
        exit 1
    }
}

# ---------------------------------------------------------------------
# 1. Unblock the downloaded files
# ---------------------------------------------------------------------
Write-Step 'Unblocking the downloaded files'
Get-ChildItem -LiteralPath $here -Recurse -File | Unblock-File
Add-Result 'Downloaded files' 'OK' 'Unblocked'

# ---------------------------------------------------------------------
# 2. SOLIDWORKS
# ---------------------------------------------------------------------
Write-Step 'Checking SOLIDWORKS'
$years = @()
foreach ($root in 'HKLM:\SOFTWARE\SolidWorks', 'HKLM:\SOFTWARE\WOW6432Node\SolidWorks') {
    if (Test-Path $root) {
        foreach ($key in Get-ChildItem $root -ErrorAction SilentlyContinue) {
            $m = [regex]::Match($key.PSChildName, '^SOLIDWORKS (\d{4})$')
            if ($m.Success) { $years += [int]$m.Groups[1].Value }
        }
    }
}
$years = @($years | Sort-Object -Unique)
if ($years.Count -eq 0) {
    Add-Result 'SOLIDWORKS' 'WARN' 'Not found. The macros need SOLIDWORKS 2025 or newer.'
} elseif (($years | Measure-Object -Maximum).Maximum -ge 2025) {
    Add-Result 'SOLIDWORKS' 'OK' ('Found ' + (($years | ForEach-Object { "$_" }) -join ', '))
} else {
    Add-Result 'SOLIDWORKS' 'WARN' ('Found ' + (($years | ForEach-Object { "$_" }) -join ', ') + '. The macros are built for 2025 and may not open in older versions.')
}

# ---------------------------------------------------------------------
# 3. Claude Code CLI (needed for the default background review)
# ---------------------------------------------------------------------
Write-Step 'Checking Claude Code'
$claude = Find-Claude
$justInstalled = $false
if (-not $claude) {
    Write-Host 'Claude Code is not installed. The default review mode needs it.'
    Write-Host 'It needs a Claude Pro, Max, Team, Enterprise or Console account (not the free plan).'
    if (Read-YesNo "Install it now with Anthropic's official installer (irm https://claude.ai/install.ps1 | iex)?" (-not $Quiet)) {
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -Command 'irm https://claude.ai/install.ps1 | iex'
        $claude = Find-Claude
        $justInstalled = [bool]$claude
        if (-not $claude) { Write-Host 'The Claude Code installer did not finish. See https://code.claude.com/docs/en/setup' -ForegroundColor Yellow }
    }
}
if ($claude) {
    $ver = ''
    try { $ver = (& $claude --version 2>$null | Select-Object -First 1) } catch { }
    Add-Result 'Claude Code' 'OK' ("$ver at $claude").Trim()
    $signInPrompt = 'Open a window to sign in to Claude Code? (needed once; skip if you already have)'
    if (Read-YesNo $signInPrompt $justInstalled) {
        Start-Process powershell.exe -WorkingDirectory $env:USERPROFILE -ArgumentList '-NoExit', '-Command',
            "Write-Host 'Sign in when Claude Code asks, then type /exit and close this window.'; & '$claude'"
        Add-Result 'Claude Code sign-in' 'INFO' 'Opened a sign-in window'
    } else {
        Add-Result 'Claude Code sign-in' 'INFO' 'If you have never signed in, run "claude" once in a terminal'
    }
} else {
    Add-Result 'Claude Code' 'MISS' 'Not installed: background reviews will not run. Install: https://code.claude.com/docs/en/setup'
}

# ---------------------------------------------------------------------
# 4. Claude Desktop (only for the Desktop launch modes)
# ---------------------------------------------------------------------
$desktop = (Test-Path 'Registry::HKEY_CURRENT_USER\Software\Classes\claude\shell\open\command') -or
           (Test-Path 'Registry::HKEY_LOCAL_MACHINE\Software\Classes\claude\shell\open\command')
if ($desktop) { Add-Result 'Claude Desktop' 'OK' 'Installed (optional; used by LAUNCH_MODE 0, 1 and 3)' }
else { Add-Result 'Claude Desktop' 'INFO' 'Not installed (optional; only needed for LAUNCH_MODE 0, 1 and 3)' }

# ---------------------------------------------------------------------
# 5. Install folder
# ---------------------------------------------------------------------
Write-Step 'Choosing the install folder'
if (-not $InstallDir) {
    $InstallDir = $defaultDir
    if (-not $Quiet) {
        Write-Host "Default: $defaultDir"
        $answer = Read-Host 'Press Enter to use it, type B to browse, or type another folder'
        if ($answer -match '^\s*b\s*$') {
            Add-Type -AssemblyName System.Windows.Forms
            $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
            $dlg.Description = 'Choose where to install Review with Claude'
            $dlg.ShowNewFolderButton = $true
            if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { $InstallDir = $dlg.SelectedPath }
        } elseif ($answer.Trim()) {
            $InstallDir = $answer.Trim().Trim('"')
        }
    }
}
$InstallDir = [IO.Path]::GetFullPath($InstallDir)
# Installing over a clone of the repo would overwrite its working files.
if (Test-Path -LiteralPath (Join-Path $InstallDir 'src\ClaudeReviewDrawing.bas')) {
    Write-Host ''
    Write-Host "$InstallDir is a copy of the source repository; install somewhere else." -ForegroundColor Red
    exit 1
}
New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $InstallDir 'demo') | Out-Null

# ---------------------------------------------------------------------
# 6. Copy
# ---------------------------------------------------------------------
Write-Step "Installing to $InstallDir"
function Test-Locked([string]$path) {
    if (-not (Test-Path -LiteralPath $path)) { return $false }
    try { $fs = [IO.File]::Open($path, 'Open', 'ReadWrite', 'None'); $fs.Close(); return $false } catch { return $true }
}
$copies = @(
    @{ From = 'ClaudeReviewDrawing.swp'; To = 'ClaudeReviewDrawing.swp' },
    @{ From = 'run-review.ps1'; To = 'run-review.ps1' },
    @{ From = 'README.md'; To = 'README.md' },
    @{ From = 'LICENSE'; To = 'LICENSE' },
    @{ From = 'demo\BuildDemoDrawing.swp'; To = 'demo\BuildDemoDrawing.swp' }
)
$installed = New-Object System.Collections.Generic.List[string]
foreach ($c in $copies) {
    $src = Join-Path $app $c.From
    $dst = Join-Path $InstallDir $c.To
    if (-not (Test-Path -LiteralPath $src)) { continue }
    while (Test-Locked $dst) {
        Write-Host "$($c.To) is open in SOLIDWORKS (or another program)." -ForegroundColor Yellow
        if ($Quiet) { throw "$dst is in use. Close it and run the installer again." }
        Read-Host 'Close the macro (or SOLIDWORKS), then press Enter to retry'
    }
    Copy-Item -LiteralPath $src -Destination $dst -Force
    $installed.Add($dst)
}

# The checklist is replaced unless it was customised. It counts as stock
# if it matches the default an earlier install saved beside it, or a
# release that saved none.
function Get-TextHash([string]$path) {
    # Line endings and a BOM aren't edits.
    $text = ([IO.File]::ReadAllText($path) -replace "`r`n", "`n").Trim()
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $bytes = $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($text)) } finally { $sha.Dispose() }
    return [BitConverter]::ToString($bytes).Replace('-', '')
}
$newInstr = Join-Path $app 'review-instructions.md'
$curInstr = Join-Path $InstallDir 'review-instructions.md'
$defInstr = Join-Path $InstallDir 'review-instructions.default.md'
$stock = @(
    '397285AAA4C232DD0E8D18309F0F0BA78E3EBB55C4E7D1A2ED27891C83750FF3'  # 0.1.0 and 0.2.0
    (Get-TextHash $newInstr)
)
if (Test-Path -LiteralPath $defInstr) { $stock += Get-TextHash $defInstr }
if (-not (Test-Path -LiteralPath $curInstr) -or ((Get-TextHash $curInstr) -in $stock)) {
    Copy-Item -LiteralPath $newInstr -Destination $curInstr -Force
    Add-Result 'Review checklist' 'OK' 'review-instructions.md installed'
} else {
    Add-Result 'Review checklist' 'INFO' 'Kept your customised review-instructions.md; the new default is review-instructions.default.md'
}
Copy-Item -LiteralPath $newInstr -Destination $defInstr -Force
$installed.Add($curInstr); $installed.Add($defInstr)
# Only the installed files: the folder may hold other downloads.
Unblock-File -LiteralPath $installed
Add-Result 'Macros' 'OK' "Installed to $InstallDir"

# ---------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------
Write-Host ''
Write-Host 'Summary' -ForegroundColor White
Write-Host '-------'
foreach ($r in $results) {
    $color = 'Gray'
    switch ($r.Status) { 'OK' { $color = 'Green' } 'WARN' { $color = 'Yellow' } 'MISS' { $color = 'Red' } }
    Write-Host ('[{0,-4}] ' -f $r.Status) -ForegroundColor $color -NoNewline
    Write-Host ('{0}: {1}' -f $r.Item, $r.Detail)
}

$swp = Join-Path $InstallDir 'ClaudeReviewDrawing.swp'
Write-Host ''
Write-Host 'Next' -ForegroundColor White
Write-Host '----'
Write-Host "1. In SOLIDWORKS, open a drawing and run Tools > Macro > Run > $swp"
Write-Host '2. Optional, for one-click use: Tools > Customize > Commands > Macro > drag "New Macro Button"'
Write-Host '   onto a toolbar and pick the same .swp (method: Main).'
Write-Host "3. To try it on a demo drawing first, run $(Join-Path $InstallDir 'demo\BuildDemoDrawing.swp') the same way."
Write-Host ''
if (Read-YesNo 'Open the install folder now?' (-not $Quiet)) { Start-Process explorer.exe $InstallDir }
