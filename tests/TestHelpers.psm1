<#
  TestHelpers.psm1 - shared helpers for the Pester tests in this folder.
  Keep this file ASCII (Windows PowerShell 5.1).
#>

$script:Repo = Split-Path -Parent $PSScriptRoot
$script:Out = Join-Path $PSScriptRoot '.out'
$script:Utf8 = New-Object System.Text.UTF8Encoding $false

function Get-RepoRoot { $script:Repo }

# Scratch folder for build outputs that outlive one test (tests\.out).
function Get-TestOut([string]$child) {
    $p = $script:Out
    if ($child) { $p = Join-Path $p $child }
    New-Item -ItemType Directory -Force -Path $p | Out-Null
    return $p
}

# .NET Framework's C# compiler, present on every Windows install.
function Get-Csc {
    $csc = Join-Path ([Runtime.InteropServices.RuntimeEnvironment]::GetRuntimeDirectory()) 'csc.exe'
    if ($PSVersionTable.PSEdition -eq 'Core' -or -not (Test-Path -LiteralPath $csc)) {
        $csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
    }
    if (-not (Test-Path -LiteralPath $csc)) { throw "The .NET Framework C# compiler wasn't found ($csc)." }
    return $csc
}

# Folder holding the fake claude.exe (tests\lib\FakeClaude.cs), built on
# first use.
function Get-FakeClaudeDir {
    $dir = Get-TestOut 'fake-claude'
    $exe = Join-Path $dir 'claude.exe'
    $src = Join-Path $PSScriptRoot 'lib\FakeClaude.cs'
    if (-not (Test-Path -LiteralPath $exe) -or (Get-Item -LiteralPath $exe).LastWriteTime -lt (Get-Item -LiteralPath $src).LastWriteTime) {
        $out = & (Get-Csc) /nologo /target:exe "/out:$exe" $src 2>&1
        if ($LASTEXITCODE -ne 0) { throw "Building the fake claude.exe failed:`n$($out -join "`n")" }
    }
    return $dir
}

# PATH without any folder that holds a claude command, so the only
# claude a child process can find is the one a test puts there.
function Get-PathWithoutClaude {
    $keep = foreach ($p in ($env:PATH -split ';')) {
        if (-not $p) { continue }
        $hit = $false
        foreach ($ext in '.exe', '.cmd', '.bat', '.ps1', '') {
            if (Test-Path -LiteralPath (Join-Path $p "claude$ext") -PathType Leaf -ErrorAction SilentlyContinue) { $hit = $true; break }
        }
        if (-not $hit) { $p }
    }
    return ($keep -join ';')
}

# Quotes one argument for a Windows command line.
function ConvertTo-CommandLineArg([string]$a) {
    if ($a -and $a -notmatch '[\s"]') { return $a }
    return '"' + ($a -replace '(\\*)"', '$1$1\"' -replace '(\\+)$', '$1$1') + '"'
}

# Runs a process to completion; returns ExitCode, StdOut, StdErr. Env
# entries replace the inherited ones ($null removes one).
function Invoke-Process {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [string[]]$ArgumentList = @(),
        [string]$WorkingDirectory = (Get-Location).Path,
        [hashtable]$Environment = @{},
        [string]$StdIn,
        [int]$TimeoutSeconds = 300
    )
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $FilePath
    $psi.Arguments = ($ArgumentList | ForEach-Object { ConvertTo-CommandLineArg $_ }) -join ' '
    $psi.WorkingDirectory = $WorkingDirectory
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.RedirectStandardInput = $true
    foreach ($k in $Environment.Keys) {
        if ($null -eq $Environment[$k]) { $psi.EnvironmentVariables.Remove($k) } else { $psi.EnvironmentVariables[$k] = [string]$Environment[$k] }
    }
    $p = [System.Diagnostics.Process]::Start($psi)
    $outTask = $p.StandardOutput.ReadToEndAsync()
    $errTask = $p.StandardError.ReadToEndAsync()
    if ($StdIn) { $p.StandardInput.Write($StdIn) }
    $p.StandardInput.Close()
    if (-not $p.WaitForExit($TimeoutSeconds * 1000)) {
        try { & taskkill.exe /PID $p.Id /T /F *> $null } catch { }
        throw "$FilePath $($psi.Arguments) didn't finish within $TimeoutSeconds s."
    }
    $p.WaitForExit()
    [pscustomobject]@{ ExitCode = $p.ExitCode; StdOut = $outTask.Result; StdErr = $errTask.Result }
}

<#
  Runs run-review.ps1 on a run folder the way the macro does (Windows
  PowerShell 5.1; -Pwsh for PowerShell 7), always with -NoOpen -NoDialog.
  Claude is the fake claude.exe, unless -NoClaude (none to be found at
  all) or -RealClaude (the installed Claude Code CLI).
  Returns ExitCode, StdOut, StdErr, Log (claude-log.txt) and Html (the
  path of review.html, $null if none).
#>
function Invoke-RunReview {
    param(
        [Parameter(Mandatory = $true)][string]$Folder,
        [switch]$RenderOnly,
        [switch]$Pwsh,
        [switch]$NoClaude,
        [switch]$RealClaude,
        [hashtable]$FakeClaude = @{},
        [double]$TimeoutMinutes = 0,
        [string]$ScriptPath = (Join-Path $script:Repo 'run-review.ps1'),
        [string]$WorkingDirectory = $Folder
    )
    $exe = 'powershell.exe'
    if ($Pwsh) { $exe = 'pwsh.exe' }
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $ScriptPath, '-Folder', $Folder, '-NoOpen', '-NoDialog')
    if ($RenderOnly) { $argList += '-RenderOnly' }
    if ($TimeoutMinutes -gt 0) { $argList += @('-TimeoutMinutes', $TimeoutMinutes.ToString([Globalization.CultureInfo]::InvariantCulture)) }

    $envVars = @{ PATH = (Get-PathWithoutClaude) }
    if ($RealClaude) {
        $envVars = @{}
    } elseif ($NoClaude) {
        # Nor the fallback at %USERPROFILE%\.local\bin\claude.exe.
        $envVars.USERPROFILE = Get-TestOut 'no-claude-profile'
    } else {
        $envVars.PATH = (Get-FakeClaudeDir) + ';' + $envVars.PATH
    }
    foreach ($k in $FakeClaude.Keys) { $envVars["FAKE_CLAUDE_$($k.ToUpperInvariant())"] = $FakeClaude[$k] }

    $wait = 300
    if ($TimeoutMinutes -gt 0) { $wait = [int]($TimeoutMinutes * 60) + 120 } elseif ($RealClaude) { $wait = 32 * 60 }
    $r = Invoke-Process -FilePath $exe -ArgumentList $argList -WorkingDirectory $WorkingDirectory -Environment $envVars -TimeoutSeconds $wait
    $full = $Folder
    if (-not [IO.Path]::IsPathRooted($full)) { $full = Join-Path $WorkingDirectory $Folder }
    $logPath = Join-Path $full 'claude-log.txt'
    $htmlPath = Join-Path $full 'review.html'
    $log = ''
    if (Test-Path -LiteralPath $logPath) { $log = [IO.File]::ReadAllText($logPath) }
    if (-not (Test-Path -LiteralPath $htmlPath)) { $htmlPath = $null }
    [pscustomobject]@{ ExitCode = $r.ExitCode; StdOut = $r.StdOut; StdErr = $r.StdErr; Log = $log; Html = $htmlPath }
}

<#
  The function definitions of a script, as a script block to dot-source
  in a test's scope, so its functions can be called one at a time without
  running the script:  . (Get-ScriptFunctions run-review.ps1)
#>
function Get-ScriptFunctions([string]$Path) {
    $tokens = $null; $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    if ($errors.Count -gt 0) { throw "$Path doesn't parse: $($errors[0].Message)" }
    $defs = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false)
    return [scriptblock]::Create((($defs | ForEach-Object { $_.Extent.Text }) -join "`n`n"))
}

<#
  Writes a simple PDF that stands in for a drawing: each page has a
  border, a 10% grid with labels, "SHEET n" in the middle, and optional
  markers (x,y in percent of the page from its top-left, like Pin) so a
  balloon's position can be checked by eye. Default size ANSI B
  landscape (17 x 11 in).
#>
function New-TestPdf {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [int]$Pages = 1,
        [double]$Width = 1224,
        [double]$Height = 792,
        [object[]]$Markers = @()
    )
    $inv = [Globalization.CultureInfo]::InvariantCulture
    $f = { param([double]$v) $v.ToString('0.##', $inv) }
    $objs = New-Object System.Collections.Generic.List[string]
    $fontId = 3 + 2 * $Pages
    $kids = (0..($Pages - 1) | ForEach-Object { "$(3 + 2 * $_) 0 R" }) -join ' '
    $objs.Add('<< /Type /Catalog /Pages 2 0 R >>')
    $objs.Add("<< /Type /Pages /Kids [$kids] /Count $Pages >>")
    for ($p = 1; $p -le $Pages; $p++) {
        $sb = New-Object System.Text.StringBuilder
        [void]$sb.Append("0.85 G 0.5 w`n")
        for ($i = 1; $i -lt 10; $i++) {
            $x = $Width * $i / 10; $y = $Height * $i / 10
            [void]$sb.Append("$(& $f $x) 0 m $(& $f $x) $(& $f $Height) l S 0 $(& $f $y) m $(& $f $Width) $(& $f $y) l S`n")
        }
        [void]$sb.Append("0 G 2 w $(& $f ($Width * 0.02)) $(& $f ($Height * 0.02)) $(& $f ($Width * 0.96)) $(& $f ($Height * 0.96)) re S`n")
        [void]$sb.Append("BT /F1 10 Tf`n")
        for ($i = 1; $i -lt 10; $i++) {
            [void]$sb.Append("1 0 0 1 $(& $f ($Width * $i / 10 + 2)) $(& $f ($Height - 14)) Tm ($($i * 10)) Tj`n")
            [void]$sb.Append("1 0 0 1 4 $(& $f ($Height * (1 - $i / 10) + 2)) Tm ($($i * 10)) Tj`n")
        }
        [void]$sb.Append("/F1 48 Tf 1 0 0 1 $(& $f ($Width / 2 - 110)) $(& $f ($Height / 2 - 16)) Tm (SHEET $p) Tj ET`n")
        foreach ($m in $Markers) {
            if ([int]$m.Page -ne $p) { continue }
            $mx = $Width * [double]$m.X / 100; $my = $Height * (1 - [double]$m.Y / 100)
            [void]$sb.Append("1 0 0 RG 1.5 w $(& $f ($mx - 8)) $(& $f $my) m $(& $f ($mx + 8)) $(& $f $my) l S $(& $f $mx) $(& $f ($my - 8)) m $(& $f $mx) $(& $f ($my + 8)) l S`n")
            if ($m.Label) { [void]$sb.Append("BT /F1 9 Tf 1 0 0 1 $(& $f ($mx + 6)) $(& $f ($my + 6)) Tm ($($m.Label)) Tj ET`n") }
        }
        $content = $sb.ToString()
        $objs.Add("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 $(& $f $Width) $(& $f $Height)] /Contents $(4 + 2 * ($p - 1)) 0 R /Resources << /Font << /F1 $fontId 0 R >> >> >>")
        $objs.Add("<< /Length $($content.Length) >>`nstream`n$content`nendstream")
    }
    $objs.Add('<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>')

    $sbPdf = New-Object System.Text.StringBuilder
    [void]$sbPdf.Append("%PDF-1.4`n")
    $offsets = @()
    for ($i = 0; $i -lt $objs.Count; $i++) {
        $offsets += $sbPdf.Length
        [void]$sbPdf.Append("$($i + 1) 0 obj`n$($objs[$i])`nendobj`n")
    }
    $xref = $sbPdf.Length
    [void]$sbPdf.Append("xref`n0 $($objs.Count + 1)`n0000000000 65535 f`r`n")
    foreach ($o in $offsets) { [void]$sbPdf.Append(('{0:D10} 00000 n' -f $o) + "`r`n") }
    [void]$sbPdf.Append("trailer`n<< /Size $($objs.Count + 1) /Root 1 0 R >>`nstartxref`n$xref`n%%EOF`n")
    [IO.File]::WriteAllText($Path, $sbPdf.ToString(), [Text.Encoding]::ASCII)
}

<#
  A run folder like the macro makes, under $Parent: <Name>.pdf (a test
  PDF unless -Pdf is given), drawing-data.md, prompt.txt (with a BOM, as
  the macro writes it) and, with -Review, review.md. Returns its path.
#>
function New-TestRunFolder {
    param(
        [Parameter(Mandatory = $true)][string]$Parent,
        [string]$Name = 'TEST-100',
        [string]$Review,
        [string]$ReviewText,
        [string]$Pdf,
        [int]$Pages = 1,
        [object[]]$Markers = @(),
        [switch]$NoPdf
    )
    $dir = Join-Path $Parent ($Name + '_20261011-120000')
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    [IO.File]::WriteAllText((Join-Path $dir '.claude-review-run'), 'Made by tests.', $script:Utf8)
    if (-not $NoPdf) {
        $pdfPath = Join-Path $dir "$Name.pdf"
        if ($Pdf) { Copy-Item -LiteralPath $Pdf -Destination $pdfPath } else { New-TestPdf -Path $pdfPath -Pages $Pages -Markers $Markers }
    }
    [IO.File]::WriteAllText((Join-Path $dir 'drawing-data.md'), "# Drawing data: $Name`n", $script:Utf8)
    [IO.File]::WriteAllText((Join-Path $dir 'prompt.txt'), "Please review the SOLIDWORKS drawing `"$Name`". Reply with the review only.", (New-Object System.Text.UTF8Encoding $true))
    if ($Review) { Copy-Item -LiteralPath $Review -Destination (Join-Path $dir 'review.md') }
    elseif ($ReviewText) { [IO.File]::WriteAllText((Join-Path $dir 'review.md'), $ReviewText, $script:Utf8) }
    return $dir
}

<#
  What review.html shows, read back from its markup: Title, Verdict,
  Counts, Items (Id, Sev, Sheet, NoPin, Issue, Fix, Where), Pins (Id,
  Sheet, Sev, X, Y), Sheets (image names), PdfViewer, Tabs, Html.
#>
function Get-ReportModel([string]$HtmlPath) {
    $html = [IO.File]::ReadAllText($HtmlPath)
    $dec = { param($t) [System.Net.WebUtility]::HtmlDecode(($t -replace '<[^>]+>', '')).Trim() }
    $items = foreach ($m in [regex]::Matches($html, '(?s)<article class="item sev-(\w+)" data-sev="\w+" data-id="([^"]*)"( data-sheet="(\d+)")?>(.*?)</article>')) {
        $body = $m.Groups[5].Value
        [pscustomobject]@{
            Id    = [System.Net.WebUtility]::HtmlDecode($m.Groups[2].Value)
            Sev   = $m.Groups[1].Value
            Sheet = if ($m.Groups[4].Success) { [int]$m.Groups[4].Value } else { $null }
            NoPin = $body -match 'class="balloon no-pin"'
            Issue = & $dec ([regex]::Match($body, '(?s)<p class="issue">(.*?)</p>').Groups[1].Value)
            Fix   = & $dec ([regex]::Match($body, '(?s)<p class="fix"><span class="fix-k">Fix</span>(.*?)</p>').Groups[1].Value)
            Where = & $dec ([regex]::Match($body, '(?s)<span class="where">(.*?)</span>').Groups[1].Value)
            Raw   = $body
        }
    }
    $pins = New-Object System.Collections.Generic.List[object]
    foreach ($s in [regex]::Matches($html, '(?s)<div class="stage" data-sheet="(\d+)"[^>]*><img src="([^"]+)"[^>]*>(.*?)</div>')) {
        foreach ($p in [regex]::Matches($s.Groups[3].Value, '<button class="pin sev-(\w+)" data-id="([^"]*)" style="left: ([\d.]+)%; top: ([\d.]+)%"')) {
            $pins.Add([pscustomobject]@{
                Id = [System.Net.WebUtility]::HtmlDecode($p.Groups[2].Value); Sheet = [int]$s.Groups[1].Value; Sev = $p.Groups[1].Value
                X = [double]::Parse($p.Groups[3].Value, [Globalization.CultureInfo]::InvariantCulture)
                Y = [double]::Parse($p.Groups[4].Value, [Globalization.CultureInfo]::InvariantCulture)
            })
        }
    }
    $sheets = @([regex]::Matches($html, '<div class="stage" data-sheet="\d+"[^>]*><img src="([^"]+)"') | ForEach-Object { [Uri]::UnescapeDataString($_.Groups[1].Value) })
    [pscustomobject]@{
        Title     = & $dec ([regex]::Match($html, '<title>(.*?)</title>').Groups[1].Value)
        Verdict   = & $dec ([regex]::Match($html, '<span class="v-label">(.*?)</span>').Groups[1].Value)
        VerdictClass = [regex]::Match($html, '<section class="verdict v-(\w+)">').Groups[1].Value
        Counts    = & $dec ([regex]::Match($html, '<span class="v-counts">(.*?)</span>').Groups[1].Value)
        Summary   = & $dec ([regex]::Match($html, '(?s)<section class="verdict[^>]*>.*?</p>(.*?)</section>').Groups[1].Value)
        Items     = @($items)
        # .ToArray(): @() around a List[object] trips a 5.1 binder bug.
        Pins      = $pins.ToArray()
        Sheets    = $sheets
        PdfViewer = $html -match '<section class="viewer viewer-pdf"'
        Tabs      = @([regex]::Matches($html, '<button class="tab[^"]*" data-filter="(\w+)"') | ForEach-Object { $_.Groups[1].Value })
        Rest      = [regex]::Match($html, '(?s)<div class="rest">(.*?)</div>\s*<div class="foot">').Groups[1].Value
        Html      = $html
    }
}

Export-ModuleMember -Function Get-RepoRoot, Get-TestOut, Get-Csc, Get-FakeClaudeDir, Get-PathWithoutClaude,
    Invoke-Process, Invoke-RunReview, Get-ScriptFunctions, New-TestPdf, New-TestRunFolder, Get-ReportModel
