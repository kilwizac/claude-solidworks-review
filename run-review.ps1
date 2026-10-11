<#
  run-review.ps1 - background half of LAUNCH_MODE 2 in ClaudeReviewDrawing.

  Runs the Claude Code CLI headless in a run folder the macro made, locked
  down: --restricted (no command-running tools, user/project settings
  ignored, file tools confined to the run folder), --tools Read (Read is
  the only tool) and --strict-mcp-config (no MCP servers). It reads the PDF and
  drawing-data.md, and its answer is saved as review.md. That answer is
  turned into review.html - the findings list beside the drawing, with a
  numbered balloon on the sheet for each finding - which is then opened.
  Errors land in claude-log.txt and a message box.

  -RenderOnly rebuilds review.html from an existing review.md without
  asking Claude again (e.g. after editing the page below). -NoOpen skips
  opening the page.

  Follow-up questions: open a terminal in the run folder and run
  `claude --continue`.

  Run it with Windows PowerShell 5.1 (powershell.exe, as the macro does):
  the sheet images come from the Windows PDF renderer, which PowerShell 7
  can't reach; there the page falls back to the plain PDF without
  balloons. Keep this file ASCII: 5.1 reads BOM-less scripts in the ANSI
  code page.
#>
param(
    [Parameter(Mandatory = $true)][string]$Folder,
    [switch]$RenderOnly,
    [switch]$NoOpen
)

$ErrorActionPreference = 'Stop'
$utf8 = New-Object System.Text.UTF8Encoding $false
$inv = [Globalization.CultureInfo]::InvariantCulture

$promptPath = Join-Path $Folder 'prompt.txt'
$stdinPath  = Join-Path $Folder 'prompt-stdin.txt'
$reviewPath = Join-Path $Folder 'review.md'
$htmlPath   = Join-Path $Folder 'review.html'
$logPath    = Join-Path $Folder 'claude-log.txt'

function Show-Error([string]$message) {
    Add-Type -AssemblyName PresentationFramework
    [System.Windows.MessageBox]::Show(
        "Claude couldn't finish the review:`n`n$message`n`nFolder: $Folder",
        'Review with Claude', 'OK', 'Error') | Out-Null
}

function Write-Log([string]$message) {
    try { Add-Content -LiteralPath $logPath -Value $message -Encoding UTF8 } catch { }
}

# =====================================================================
#  Claude
# =====================================================================
function Invoke-ClaudeReview {
    # Applications only: an npm install also has claude.ps1, which
    # PowerShell would prefer but Start-Process can't redirect.
    $claude = (Get-Command claude -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1).Source
    if (-not $claude) { $claude = Join-Path $env:USERPROFILE '.local\bin\claude.exe' }
    if (-not (Test-Path -LiteralPath $claude)) {
        throw "The Claude Code CLI wasn't found (not on PATH, not at $claude)."
    }

    # The macro writes prompt.txt with a BOM; Claude gets it without one.
    $prompt = [IO.File]::ReadAllText($promptPath)
    [IO.File]::WriteAllText($stdinPath, $prompt, $utf8)

    # The prompt goes in on stdin and the answer comes out on stdout,
    # file to file, so PowerShell never re-encodes either.
    $proc = Start-Process -FilePath $claude `
        -ArgumentList '-p', '--restricted', '--strict-mcp-config', '--tools', 'Read', '--allowedTools', 'Read' `
        -WorkingDirectory $Folder `
        -RedirectStandardInput $stdinPath `
        -RedirectStandardOutput $reviewPath `
        -RedirectStandardError $logPath `
        -NoNewWindow -Wait -PassThru

    if ($proc.ExitCode -ne 0) {
        throw "Claude Code exited with code $($proc.ExitCode). Details are in claude-log.txt."
    }
    if (-not (Test-Path -LiteralPath $reviewPath) -or (Get-Item -LiteralPath $reviewPath).Length -eq 0) {
        throw "Claude Code returned an empty review. Details are in claude-log.txt."
    }
    Remove-Item -LiteralPath $stdinPath -ErrorAction SilentlyContinue
}

# =====================================================================
#  Sheet images: each PDF page as sheet-N.png, via the Windows PDF
#  renderer (WinRT Windows.Data.Pdf). Balloons need an image - inside a
#  PDF viewer their positions can't be matched to the sheet.
# =====================================================================
function Export-SheetImages([string]$pdfPath) {
    $names = New-Object System.Collections.Generic.List[string]

    # Reuse images from an earlier render of this PDF (-RenderOnly).
    $existing = @(Get-ChildItem -LiteralPath $Folder -Filter 'sheet-*.png' | Sort-Object { [int]($_.BaseName -replace '\D', '') })
    if ($existing.Count -gt 0 -and $existing[0].LastWriteTime -ge (Get-Item -LiteralPath $pdfPath).LastWriteTime) {
        foreach ($e in $existing) { $names.Add($e.Name) }
        return ,$names
    }
    if ($PSVersionTable.PSVersion.Major -gt 5) {
        Write-Log 'Sheet images need Windows PowerShell 5.1; showing the PDF without balloons.'
        return ,$names
    }

    try {
        Add-Type -AssemblyName System.Runtime.WindowsRuntime
        $null = [Windows.Storage.StorageFile, Windows.Storage, ContentType = WindowsRuntime]
        $null = [Windows.Storage.StorageFolder, Windows.Storage, ContentType = WindowsRuntime]
        $null = [Windows.Data.Pdf.PdfDocument, Windows.Data.Pdf, ContentType = WindowsRuntime]
        $null = [Windows.Data.Pdf.PdfPageRenderOptions, Windows.Data.Pdf, ContentType = WindowsRuntime]
        $null = [Windows.Storage.Streams.IRandomAccessStream, Windows.Storage.Streams, ContentType = WindowsRuntime]
        $asTask = [System.WindowsRuntimeSystemExtensions].GetMethods() |
            Where-Object { $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 }
        $opM = $asTask | Where-Object { $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1' } | Select-Object -First 1
        $actM = $asTask | Where-Object { $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncAction' } | Select-Object -First 1
        $await = { param($op, [Type]$type) $t = $opM.MakeGenericMethod($type).Invoke($null, @($op)); $t.Wait(); $t.Result }
        $awaitAction = { param($op) $t = $actM.Invoke($null, @($op)); $t.Wait() }

        $file = & $await ([Windows.Storage.StorageFile]::GetFileFromPathAsync($pdfPath)) ([Windows.Storage.StorageFile])
        $doc = & $await ([Windows.Data.Pdf.PdfDocument]::LoadFromFileAsync($file)) ([Windows.Data.Pdf.PdfDocument])
        $dir = & $await ([Windows.Storage.StorageFolder]::GetFolderFromPathAsync($Folder)) ([Windows.Storage.StorageFolder])
        for ($i = 0; $i -lt $doc.PageCount; $i++) {
            $page = $doc.GetPage([uint32]$i)
            $name = "sheet-$($i + 1).png"
            $out = & $await ($dir.CreateFileAsync($name, [Windows.Storage.CreationCollisionOption]::ReplaceExisting)) ([Windows.Storage.StorageFile])
            $stream = & $await ($out.OpenAsync([Windows.Storage.FileAccessMode]::ReadWrite)) ([Windows.Storage.Streams.IRandomAccessStream])
            $opts = New-Object Windows.Data.Pdf.PdfPageRenderOptions
            $opts.DestinationWidth = [uint32]2400
            & $awaitAction ($page.RenderToStreamAsync($stream, $opts))
            $stream.Dispose()
            $page.Dispose()
            $names.Add($name)
        }
    }
    catch {
        Write-Log ('Sheet images could not be made; showing the PDF without balloons. ' + $_.Exception.Message)
        $names.Clear()
    }
    return ,$names
}

# =====================================================================
#  Markdown -> HTML (just what review answers use: headings, bold-line
#  headings, lists, paragraphs, pipe tables, **bold**, *italic*, `code`)
# =====================================================================
function ConvertTo-Html-Inline([string]$text) {
    $t = [System.Net.WebUtility]::HtmlEncode($text)
    $t = [regex]::Replace($t, '`([^`]+)`', '<code>$1</code>')
    $t = [regex]::Replace($t, '\*\*(.+?)\*\*', '<strong>$1</strong>')
    $t = [regex]::Replace($t, '(?<![\*\w])\*(?![\s\*])(.+?)(?<![\s\*])\*(?![\*\w])', '<em>$1</em>')
    return $t
}

function Get-SectionKind([string]$heading) {
    if ($heading -match 'good') { return 'good' }
    if ($heading -match 'question') { return 'questions' }
    return 'other'
}

function Split-TableRow([string]$row) {
    $sep = [string][char]0x1F
    $r = $row.Trim().Replace('\|', $sep)
    if ($r.StartsWith('|')) { $r = $r.Substring(1) }
    if ($r.EndsWith('|')) { $r = $r.Substring(0, $r.Length - 1) }
    $cells = @($r.Split('|') | ForEach-Object { $_.Replace($sep, '|').Trim() })
    return ,$cells
}

function Test-TableStart([string[]]$lines, [int]$i) {
    return ($i + 1 -lt $lines.Count) -and ($lines[$i] -match '^\s*\|') -and
           ($lines[$i + 1] -match '^\s*\|[\s:\-|]+$') -and ($lines[$i + 1] -match '-')
}

function ConvertTo-Html-Blocks([string[]]$lines) {
    $sb = New-Object System.Text.StringBuilder
    $section = 'other'
    $listRx = '^\s*([-*+]|\d+[.)])\s+(.*)$'
    $i = 0
    while ($i -lt $lines.Count) {
        $line = $lines[$i]
        if ($line.Trim() -eq '' -or $line.Trim() -match '^-{3,}$') { $i++; continue }

        if ($line -match '^\s*#{1,6}\s+(.*)$') {
            $title = $Matches[1].Trim().TrimEnd('#').Trim()
            $section = Get-SectionKind $title
            [void]$sb.Append("<h2 class=`"sec-head sec-$section`">" + (ConvertTo-Html-Inline $title) + "</h2>`n")
            $i++; continue
        }

        if (Test-TableStart $lines $i) {
            $head = Split-TableRow $lines[$i]
            [void]$sb.Append("<div class=`"table-wrap`"><table><thead><tr>")
            foreach ($h in $head) { [void]$sb.Append('<th>' + (ConvertTo-Html-Inline $h) + '</th>') }
            [void]$sb.Append("</tr></thead><tbody>`n")
            $i += 2
            while ($i -lt $lines.Count -and $lines[$i] -match '^\s*\|') {
                [void]$sb.Append('<tr>')
                foreach ($c in (Split-TableRow $lines[$i])) { [void]$sb.Append('<td>' + (ConvertTo-Html-Inline $c) + '</td>') }
                [void]$sb.Append("</tr>`n")
                $i++
            }
            [void]$sb.Append("</tbody></table></div>`n")
            continue
        }

        if ($line -match $listRx) {
            $tag = 'ul'
            if ($line -match '^\s*\d+[.)]\s+') { $tag = 'ol' }
            [void]$sb.Append("<$tag class=`"list list-$section`">`n")
            $item = $null
            while ($i -lt $lines.Count) {
                $l = $lines[$i]
                if ($l -match $listRx) {
                    if ($null -ne $item) { [void]$sb.Append('<li>' + (ConvertTo-Html-Inline $item) + "</li>`n") }
                    $item = $Matches[2]
                } elseif ($l.Trim() -ne '' -and $l -match '^\s+\S') {
                    $item += ' ' + $l.Trim()
                } else {
                    break
                }
                $i++
            }
            if ($null -ne $item) { [void]$sb.Append('<li>' + (ConvertTo-Html-Inline $item) + "</li>`n") }
            [void]$sb.Append("</$tag>`n")
            continue
        }

        $para = New-Object System.Collections.Generic.List[string]
        while ($i -lt $lines.Count -and $lines[$i].Trim() -ne '' -and
               $lines[$i] -notmatch '^\s*(#{1,6}\s|[-*+]\s|\d+[.)]\s|\|)') {
            $para.Add($lines[$i].Trim())
            $i++
        }
        if ($para.Count -eq 0) { $para.Add($line.Trim()); $i++ }
        $text = $para -join ' '
        if ($text -match '^\*\*([^*]+?):?\*\*:?$') {
            # A paragraph that's only bold text is a section heading.
            $section = Get-SectionKind $Matches[1]
            [void]$sb.Append("<h2 class=`"sec-head sec-$section`">" + (ConvertTo-Html-Inline $Matches[1].Trim()) + "</h2>`n")
        } else {
            [void]$sb.Append('<p>' + (ConvertTo-Html-Inline $text) + "</p>`n")
        }
    }
    return $sb.ToString()
}

# =====================================================================
#  Findings table -> objects
# =====================================================================
function Get-Severity([string]$text) {
    if ($text -match 'crit') { return 'critical' }
    if ($text -match 'maj') { return 'major' }
    if ($text -match 'min') { return 'minor' }
    return 'info'
}

# "62,41" (percent of the sheet from top-left) -> @(62, 41), else $null.
function Get-Pin([string]$text) {
    $m = [regex]::Match($text, '(\d+(?:\.\d+)?)\s*[,;/ ]\s*(\d+(?:\.\d+)?)')
    if (-not $m.Success) { return $null }
    $x = [Math]::Min(100.0, [Math]::Max(0.0, [double]::Parse($m.Groups[1].Value, $inv)))
    $y = [Math]::Min(100.0, [Math]::Max(0.0, [double]::Parse($m.Groups[2].Value, $inv)))
    return ,@($x, $y)
}

# Finds the findings table (# | Severity | Sheet | Pin | View/location |
# Issue | Suggested fix) and splits the answer around it. $null if none.
function Get-ReviewParts([string[]]$lines) {
    for ($k = 0; $k -lt $lines.Count; $k++) {
        if (-not (Test-TableStart $lines $k)) { continue }
        $head = Split-TableRow $lines[$k]
        $col = @{}
        for ($c = 0; $c -lt $head.Count; $c++) {
            $h = $head[$c]
            if ($h -match 'sev') { $col.sev = $c }
            elseif ($h -match '^\W*pin|position|coord') { $col.pin = $c }
            elseif ($h -match '^\W*sheet') { $col.sheet = $c }
            elseif ($h -match 'fix|action|recommend') { $col.fix = $c }
            elseif ($h -match 'view|location|zone|where') { $col.loc = $c }
            elseif ($h -match 'issue|finding|problem') { $col.issue = $c }
            elseif ($h -match '^#$|^no\.?$|^num') { $col.num = $c }
        }
        if (-not ($col.ContainsKey('sev') -and $col.ContainsKey('issue'))) { continue }

        $findings = New-Object System.Collections.Generic.List[object]
        $end = $k + 2
        while ($end -lt $lines.Count -and $lines[$end] -match '^\s*\|') {
            $cells = Split-TableRow $lines[$end]
            # Unescaped pipes in a cell (e.g. a quoted GD&T frame) make extra
            # cells; fold them back into the issue so later columns line up.
            $extra = $cells.Count - $head.Count
            if ($extra -gt 0 -and $col.ContainsKey('issue')) {
                $ii = $col.issue
                $merged = @($cells[$ii..($ii + $extra)]) -join ' | '
                $before = @(); if ($ii -gt 0) { $before = @($cells[0..($ii - 1)]) }
                $after = @(); if ($ii + $extra + 1 -le $cells.Count - 1) { $after = @($cells[($ii + $extra + 1)..($cells.Count - 1)]) }
                $cells = @($before + @($merged) + $after)
            }
            $get = { param($key) if ($col.ContainsKey($key) -and $col[$key] -lt $cells.Count) { $cells[$col[$key]] } else { '' } }
            $num = (& $get 'num').Trim('*').Trim()
            if (-not $num) { $num = [string]($findings.Count + 1) }
            $sheetText = & $get 'sheet'
            $sheetNo = 1
            $sm = [regex]::Match($sheetText, '^\W*(?:sheet\s*)?(\d+)\b')
            if ($sm.Success) { $sheetNo = [int]$sm.Groups[1].Value }
            $findings.Add([pscustomobject]@{
                Num     = $num
                Sev     = Get-Severity (& $get 'sev')
                Sheet   = $sheetText
                SheetNo = $sheetNo
                Pin     = Get-Pin (& $get 'pin')
                Loc     = & $get 'loc'
                Issue   = & $get 'issue'
                Fix     = & $get 'fix'
            })
            $end++
        }
        $pre = @(); if ($k -gt 0) { $pre = $lines[0..($k - 1)] }
        $post = @(); if ($end -lt $lines.Count) { $post = $lines[$end..($lines.Count - 1)] }
        return [pscustomobject]@{ Pre = $pre; Findings = $findings; Post = $post }
    }
    return $null
}

# =====================================================================
#  review.html
# =====================================================================
function Write-ReviewHtml {
    $md = [IO.File]::ReadAllText($reviewPath)
    $lines = $md -split "`r?`n"
    $enc = { param($t) [System.Net.WebUtility]::HtmlEncode($t) }
    $num = { param([double]$v) $v.ToString('0.##', $inv) }

    # The drawing PDF is the one PDF the macro puts in the run folder.
    $pdf = Get-ChildItem -LiteralPath $Folder -Filter '*.pdf' | Select-Object -First 1
    $name = Split-Path $Folder -Leaf
    if ($pdf) { $name = [IO.Path]::GetFileNameWithoutExtension($pdf.Name) }
    $when = (Get-Item -LiteralPath $reviewPath).LastWriteTime.ToString('d MMM yyyy, HH:mm', $inv)

    $images = New-Object System.Collections.Generic.List[string]
    if ($pdf) { $images = Export-SheetImages $pdf.FullName }

    $parts = Get-ReviewParts $lines
    $counts = @{ critical = 0; major = 0; minor = 0; info = 0 }
    $items = New-Object System.Text.StringBuilder
    $pinsBySheet = @{}
    $summaryHtml = ''
    $restHtml = ''

    if ($parts) {
        $summaryHtml = ConvertTo-Html-Blocks $parts.Pre
        # The "Verdict: ..." line and a bold "Summary: ..." lead-in repeat
        # the verdict shown above the summary.
        $summaryHtml = [regex]::Replace($summaryHtml, '^\s*<p>(?:<strong>)?Verdict\b[^<]*(?:</strong>)?[^<]*</p>\s*', '')
        $summaryHtml = [regex]::Replace($summaryHtml, '^\s*<p><strong>(?:Summary|Verdict)[^<]*</strong>\s*', '<p>')
        $restHtml = ConvertTo-Html-Blocks $parts.Post

        $placed = @{}
        $ringOffsets = @(@(0, 0), @(1, 0), @(-1, 0), @(0, -1), @(0, 1), @(1, -1), @(-1, -1), @(1, 1), @(-1, 1),
                         @(2, 0), @(-2, 0), @(2, -1), @(-2, -1), @(2, 1), @(-2, 1), @(0, -2), @(0, 2))
        foreach ($f in $parts.Findings) {
            $counts[$f.Sev]++
            $label = (Get-Culture).TextInfo.ToTitleCase($f.Sev)
            $id = & $enc $f.Num

            $where = @()
            if ($f.Sheet) {
                $st = $f.Sheet
                if ($st -match '^\d+$') { $st = "Sheet $st" }
                $where += ConvertTo-Html-Inline $st
            }
            if ($f.Loc) { $where += ConvertTo-Html-Inline $f.Loc }
            $whereHtml = ''
            if ($where.Count -gt 0) { $whereHtml = '<span class="where">' + ($where -join ' &middot; ') + '</span>' }

            $fixHtml = ''
            if ($f.Fix) { $fixHtml = '<p class="fix"><span class="fix-k">Fix</span>' + (ConvertTo-Html-Inline $f.Fix) + '</p>' }

            $hasPin = ($null -ne $f.Pin) -and ($images.Count -ge $f.SheetNo)
            $pinAttr = ''
            if ($hasPin) {
                # Balloons that would sit on top of one another go to the
                # nearest free spot in a ring around the pin (dy is larger:
                # sheets are wider than tall, so % of height is shorter).
                $key = [string]$f.SheetNo
                if (-not $placed.ContainsKey($key)) { $placed[$key] = New-Object System.Collections.Generic.List[object] }
                $dx = 1.9; $dy = 2.9
                $x = $f.Pin[0]; $y = $f.Pin[1]
                foreach ($o in $ringOffsets) {
                    $cx = [Math]::Min(98.5, [Math]::Max(1.5, $f.Pin[0] + $o[0] * $dx))
                    $cy = [Math]::Min(98.0, [Math]::Max(2.0, $f.Pin[1] + $o[1] * $dy))
                    $hit = $placed[$key] | Where-Object { [Math]::Abs($_[0] - $cx) -lt $dx * 0.95 -and [Math]::Abs($_[1] - $cy) -lt $dy * 0.95 }
                    if (-not $hit) { $x = $cx; $y = $cy; break }
                }
                $placed[$key].Add(@($x, $y))
                $style = "left: $(& $num $x)%; top: $(& $num $y)%"
                if (-not $pinsBySheet.ContainsKey($key)) { $pinsBySheet[$key] = New-Object System.Text.StringBuilder }
                [void]$pinsBySheet[$key].Append("<button class=`"pin sev-$($f.Sev)`" data-id=`"$id`" style=`"$style`" type=`"button`" title=`"#$id $label`">$id</button>")
                $pinAttr = " data-sheet=`"$($f.SheetNo)`""
            }
            $balloonClass = 'balloon'; if (-not $hasPin) { $balloonClass += ' no-pin' }
            $balloonTitle = 'Show on the drawing'; if (-not $hasPin) { $balloonTitle = 'Not tied to one spot on the drawing' }

            [void]$items.Append(@"
<article class="item sev-$($f.Sev)" data-sev="$($f.Sev)" data-id="$id"$pinAttr>
  <button class="$balloonClass" type="button" title="$balloonTitle">$id</button>
  <div class="item-body">
    <div class="item-meta"><span class="sev">$label</span>$whereHtml</div>
    <p class="issue">$(ConvertTo-Html-Inline $f.Issue)</p>
    $fixHtml
  </div>
  <label class="done" title="Mark as fixed"><input type="checkbox"><span class="sr">Fixed</span></label>
</article>

"@)
        }
    } else {
        # No findings table: show the whole answer as a document.
        $restHtml = ConvertTo-Html-Blocks $lines
    }
    $total = $counts.critical + $counts.major + $counts.minor + $counts.info

    # Verdict from the "Verdict: ..." line the checklist asks for, else the
    # first line of the answer.
    $vline = $lines | Where-Object { $_ -match '^\W*verdict\b' } | Select-Object -First 1
    if (-not $vline) { $vline = $lines | Where-Object { $_.Trim() } | Select-Object -First 1 }
    if (-not $vline) { $vline = '' }
    $verdict = 'neutral'; $verdictLabel = 'Review'
    if ($vline -match 'rework') { $verdict = 'rework'; $verdictLabel = 'Needs rework' }
    elseif ($vline -match '\bminor\b') { $verdict = 'minor'; $verdictLabel = 'Needs minor fixes' }
    elseif ($vline -match '\bready\b') { $verdict = 'ready'; $verdictLabel = 'Ready to release' }
    if ($verdict -eq 'neutral' -and $counts.critical -gt 0) { $verdict = 'rework'; $verdictLabel = 'Needs rework' }

    $countParts = @()
    foreach ($k in 'critical', 'major', 'minor') { if ($counts[$k] -gt 0) { $countParts += "$($counts[$k]) $k" } }
    $countText = ''
    if ($countParts.Count -gt 0) { $countText = '<span class="v-counts">' + ($countParts -join ' &middot; ') + '</span>' }

    # Tabs to filter the list
    $tabs = ''
    if ($parts -and $total -gt 0) {
        $tabs = "<button class=`"tab active`" data-filter=`"all`" type=`"button`">All <span class=`"n`">$total</span></button>"
        foreach ($k in 'critical', 'major', 'minor') {
            if ($counts[$k] -eq 0) { continue }
            $label = (Get-Culture).TextInfo.ToTitleCase($k)
            $tabs += "<button class=`"tab`" data-filter=`"$k`" type=`"button`">$label <span class=`"n`">$($counts[$k])</span></button>"
        }
        $tabs = "<nav class=`"tabs`" aria-label=`"Filter findings`">$tabs<span class=`"progress`" id=`"progress`"></span></nav>"
    }

    # Drawing viewer: sheet images with balloons, else the PDF itself.
    $viewer = ''; $pdfLink = ''
    if ($pdf) {
        $pdfHref = [Uri]::EscapeDataString($pdf.Name)
        $pdfLink = "<a class=`"hbtn`" href=`"$pdfHref`" target=`"_blank`">PDF</a>"
        if ($images.Count -gt 0) {
            $stages = New-Object System.Text.StringBuilder
            $sheetTabs = ''
            for ($i = 0; $i -lt $images.Count; $i++) {
                $n = $i + 1
                $pins = ''
                if ($pinsBySheet.ContainsKey([string]$n)) { $pins = $pinsBySheet[[string]$n].ToString() }
                $hidden = ''; if ($i -gt 0) { $hidden = ' hidden' }
                [void]$stages.Append("<div class=`"stage`" data-sheet=`"$n`"$hidden><img src=`"$([Uri]::EscapeDataString($images[$i]))`" alt=`"Sheet $n`" draggable=`"false`">$pins</div>")
                $active = ''; if ($i -eq 0) { $active = ' active' }
                $sheetTabs += "<button class=`"stab$active`" data-sheet=`"$n`" type=`"button`">Sheet $n</button>"
            }
            if ($images.Count -lt 2) { $sheetTabs = '' } else { $sheetTabs = "<div class=`"sheet-tabs`">$sheetTabs</div>" }
            $viewer = @"
<section class="viewer" id="viewer" aria-label="Drawing">
  $sheetTabs
  <div class="viewport" id="viewport">$($stages.ToString())</div>
  <div class="controls">
    <button type="button" data-z="out" title="Zoom out">&minus;</button>
    <span class="zoom" id="zoom">100%</span>
    <button type="button" data-z="in" title="Zoom in">+</button>
    <button type="button" data-z="fit" title="Fit the sheet">Fit</button>
    <label class="markup"><input type="checkbox" id="show-pins" checked> Markup</label>
  </div>
</section>
"@
        } else {
            $viewer = "<section class=`"viewer viewer-pdf`" aria-label=`"Drawing`"><iframe src=`"$pdfHref#toolbar=0&amp;navpanes=0&amp;view=Fit`" title=`"Drawing $(& $enc $name)`"></iframe></section>"
        }
    }
    $bodyClass = ''; if (-not $pdf) { $bodyClass = 'no-drawing' }
    $toggleBtn = ''; if ($pdf) { $toggleBtn = "<button class=`"hbtn`" id=`"toggle-drawing`" type=`"button`">Hide drawing</button>" }

    $head = @"
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Drawing review: $(& $enc $name)</title>
"@

    $css = @'
<style>
  :root {
    color-scheme: light dark;
    --bg: #ffffff; --fg: #1c1b19; --muted: #66645f; --faint: #9b9892; --line: #e8e6e1;
    --hover: #f7f6f3; --sel: #f2f0eb; --stage: #ebe9e4; --paper: #ffffff;
    --crit: #b3261e; --major: #9a5b08; --minor: #3b5a88; --info: #66645f; --good: #2f6b45;
    --sheet-shadow: 0 1px 2px rgba(0, 0, 0, .06), 0 10px 30px rgba(0, 0, 0, .08);
  }
  @media (prefers-color-scheme: dark) {
    :root {
      --bg: #181817; --fg: #e9e7e2; --muted: #a8a59e; --faint: #706d68; --line: #2c2b29;
      --hover: #1f1f1d; --sel: #252422; --stage: #0f0f0e; --paper: #ffffff;
      --crit: #ef8a82; --major: #dba35a; --minor: #93b0dc; --info: #a8a59e; --good: #86c39b;
      --sheet-shadow: 0 0 0 1px rgba(255, 255, 255, .04), 0 10px 30px rgba(0, 0, 0, .5);
    }
  }
  * { box-sizing: border-box; }
  html, body { height: 100%; overflow: hidden; }
  body { margin: 0; display: flex; flex-direction: column; background: var(--bg); color: var(--fg);
         font: 14px/1.6 "Segoe UI Variable Text", "Segoe UI", system-ui, sans-serif;
         -webkit-font-smoothing: antialiased; }
  button { font: inherit; color: inherit; }
  a { color: inherit; }
  code { font-family: "Cascadia Mono", Consolas, monospace; font-size: .9em; }
  .sr { position: absolute; width: 1px; height: 1px; overflow: hidden; clip: rect(0 0 0 0); }

  /* Header */
  .top { flex: none; display: flex; align-items: baseline; gap: 14px; padding: 14px 24px;
         border-bottom: 1px solid var(--line); }
  .top h1 { margin: 0; font-size: 15px; font-weight: 600; letter-spacing: -.005em; }
  .top .sub { color: var(--faint); font-size: 12.5px; white-space: nowrap; }
  .top nav { margin-left: auto; display: flex; gap: 2px; }
  .hbtn { background: none; border: 0; padding: 4px 10px; border-radius: 6px; color: var(--muted);
          font-size: 13px; cursor: pointer; text-decoration: none; white-space: nowrap; }
  .hbtn:hover { color: var(--fg); background: var(--hover); }

  /* Layout */
  .app { flex: 1; min-height: 0; display: grid; grid-template-columns: minmax(400px, 560px) minmax(0, 1fr); }
  .list-pane { overflow-y: auto; border-right: 1px solid var(--line); scrollbar-width: thin; }
  body.no-drawing .app { grid-template-columns: minmax(0, 1fr); }
  body.no-drawing .viewer { display: none; }
  body.no-drawing .list-pane { border-right: 0; }
  body.no-drawing .list-inner { max-width: 760px; margin: 0 auto; }

  /* Verdict */
  .verdict { padding: 22px 24px 18px; }
  .v-line { margin: 0; display: flex; align-items: center; gap: 10px; flex-wrap: wrap; }
  .v-mark { width: 9px; height: 9px; border-radius: 2px; background: var(--faint); flex: none; }
  .v-rework .v-mark { background: var(--crit); }
  .v-minor .v-mark { background: var(--major); }
  .v-ready .v-mark { background: var(--good); }
  .v-label { font-weight: 600; font-size: 15px; }
  .v-counts { color: var(--faint); font-size: 13px; }
  .verdict p:not(.v-line) { margin: 8px 0 0; color: var(--muted); }

  /* Tabs */
  .tabs { display: flex; align-items: center; gap: 18px; padding: 0 24px; border-bottom: 1px solid var(--line);
          position: sticky; top: 0; background: var(--bg); z-index: 2; }
  .tab { background: none; border: 0; padding: 10px 0 9px; cursor: pointer; color: var(--muted);
         font-size: 13px; border-bottom: 2px solid transparent; margin-bottom: -1px; }
  .tab:hover { color: var(--fg); }
  .tab.active { color: var(--fg); border-bottom-color: var(--fg); }
  .tab .n { color: var(--faint); margin-left: 3px; font-variant-numeric: tabular-nums; }
  .progress { margin-left: auto; color: var(--faint); font-size: 12px; }

  /* Findings */
  .item { --c: var(--info); display: grid; grid-template-columns: 26px minmax(0, 1fr) auto; gap: 14px;
          padding: 16px 24px; border-bottom: 1px solid var(--line); }
  .item.sev-critical { --c: var(--crit); }
  .item.sev-major { --c: var(--major); }
  .item.sev-minor { --c: var(--minor); }
  .item:hover { background: var(--hover); }
  .item.selected { background: var(--sel); }
  .item.hidden { display: none; }
  .item[data-sheet] { cursor: pointer; }
  .balloon { width: 26px; height: 26px; border-radius: 50%; border: 1.25px solid var(--c); background: none;
             color: var(--c); padding: 0; font-size: 11.5px; font-weight: 600; font-variant-numeric: tabular-nums;
             display: grid; place-items: center; cursor: pointer; margin-top: 1px; }
  .balloon.no-pin { border-style: dashed; cursor: default; }
  .item.selected .balloon:not(.no-pin) { background: var(--c); color: var(--bg); }
  .item-meta { display: flex; flex-wrap: wrap; gap: 0 8px; font-size: 12px; line-height: 1.5; }
  .sev { font-weight: 600; color: var(--c); }
  .where { color: var(--faint); }
  .issue { margin: 3px 0 0; }
  .fix { margin: 6px 0 0; color: var(--muted); }
  .fix-k { font-size: 10.5px; font-weight: 600; letter-spacing: .07em; text-transform: uppercase;
           color: var(--faint); margin-right: 8px; }
  .done { position: relative; padding-top: 4px; cursor: pointer; }
  .done input { appearance: none; -webkit-appearance: none; margin: 0; width: 15px; height: 15px;
                border: 1.25px solid var(--faint); border-radius: 4px; display: grid; place-items: center; cursor: pointer; }
  .done input:checked { background: var(--muted); border-color: var(--muted); }
  .done input:checked::after { content: ""; width: 4px; height: 8px; border: solid var(--bg);
                               border-width: 0 1.75px 1.75px 0; transform: translateY(-1px) rotate(45deg); }
  .item.is-fixed .issue, .item.is-fixed .fix { color: var(--faint); text-decoration: line-through;
                                               text-decoration-color: var(--faint); }
  .item.is-fixed .balloon { opacity: .4; }

  /* Rest of the answer */
  .rest { padding: 8px 24px 8px; }
  .sec-head { font-size: 11px; font-weight: 600; letter-spacing: .08em; text-transform: uppercase;
              color: var(--faint); margin: 22px 0 8px; }
  .rest p { color: var(--muted); }
  .list { margin: 0; padding: 0; list-style: none; }
  .list li { position: relative; padding-left: 20px; margin: 6px 0; }
  .list li::before { content: "\2013"; position: absolute; left: 2px; color: var(--faint); }
  .list-good li::before { content: ""; left: 3px; top: .55em; width: 4px; height: 8px;
                          border: solid var(--good); border-width: 0 1.5px 1.5px 0; transform: rotate(45deg); }
  ol.list { list-style: decimal; padding-left: 22px; }
  ol.list li { padding-left: 4px; }
  ol.list li::before { content: none; }
  ol.list-questions { list-style: none; padding-left: 0; counter-reset: q; }
  ol.list-questions li { counter-increment: q; padding-left: 28px; }
  ol.list-questions li::before { content: "Q" counter(q); font-size: 11px; font-weight: 600; top: .2em; color: var(--faint); }
  .table-wrap { overflow-x: auto; }
  table { border-collapse: collapse; width: 100%; font-size: 13px; }
  th, td { border-bottom: 1px solid var(--line); padding: 6px 8px; text-align: left; vertical-align: top; }
  th { color: var(--faint); font-weight: 600; }
  .foot { padding: 16px 24px 28px; color: var(--faint); font-size: 11.5px; word-break: break-all; }

  /* Drawing viewer */
  .viewer { position: relative; background: var(--stage); min-height: 0; overflow: hidden; }
  .viewport { position: absolute; inset: 0; overflow: hidden; cursor: grab; touch-action: none; }
  .viewport.dragging { cursor: grabbing; }
  .stage { position: absolute; left: 0; top: 0; transform-origin: 0 0; --inv: 1; }
  .stage.anim { transition: transform .28s cubic-bezier(.2, .7, .2, 1); }
  .stage img { display: block; max-width: none; user-select: none; background: var(--paper);
               box-shadow: var(--sheet-shadow); }
  .pin { --c: #66645f; position: absolute; width: 24px; height: 24px; margin: 0; padding: 0; border-radius: 50%;
         transform: translate(-50%, -50%) scale(var(--inv)); background: #fff; color: var(--c);
         border: 1.5px solid var(--c); font-size: 11.5px; font-weight: 600; line-height: 1; font-variant-numeric: tabular-nums;
         display: grid; place-items: center; cursor: pointer;
         box-shadow: 0 1px 3px rgba(0, 0, 0, .18); transition: background .12s, color .12s; }
  .pin.sev-critical { --c: #b3261e; }
  .pin.sev-major { --c: #9a5b08; }
  .pin.sev-minor { --c: #3b5a88; }
  .pin:hover, .pin.hover { background: var(--c); color: #fff; }
  .pin.selected { background: var(--c); color: #fff; box-shadow: 0 0 0 5px rgba(0, 0, 0, .1), 0 1px 3px rgba(0, 0, 0, .25); z-index: 2; }
  .pin.is-fixed { opacity: .35; }
  .pin.hidden, .viewer.no-pins .pin { display: none; }
  .controls { position: absolute; right: 16px; bottom: 16px; display: flex; align-items: center; gap: 2px;
              padding: 4px; border-radius: 9px; background: var(--bg); border: 1px solid var(--line);
              box-shadow: 0 4px 16px rgba(0, 0, 0, .08); font-size: 12.5px; }
  .controls button { background: none; border: 0; min-width: 28px; height: 26px; padding: 0 8px; border-radius: 6px;
                     cursor: pointer; color: var(--muted); }
  .controls button:hover { background: var(--hover); color: var(--fg); }
  .zoom { min-width: 44px; text-align: center; color: var(--faint); font-variant-numeric: tabular-nums; }
  .markup { display: flex; align-items: center; gap: 6px; padding: 0 8px 0 10px; margin-left: 4px;
            border-left: 1px solid var(--line); color: var(--muted); cursor: pointer; }
  .markup input { margin: 0; accent-color: var(--muted); }
  .sheet-tabs { position: absolute; left: 16px; top: 14px; z-index: 3; display: flex; gap: 2px; padding: 3px;
                border-radius: 8px; background: var(--bg); border: 1px solid var(--line); }
  .stab { background: none; border: 0; padding: 3px 10px; border-radius: 6px; cursor: pointer; font-size: 12.5px; color: var(--muted); }
  .stab.active { background: var(--sel); color: var(--fg); }
  .viewer-pdf { padding: 16px; display: flex; }
  .viewer-pdf iframe { flex: 1; border: 0; border-radius: 4px; box-shadow: var(--sheet-shadow); background: #fff; }

  /* Narrow windows: drawing on top, page scrolls */
  @media (max-width: 1000px) {
    html, body { overflow: visible; }
    body { display: block; height: auto; }
    .app { display: flex; flex-direction: column-reverse; }
    .list-pane { overflow: visible; border-right: 0; }
    .viewer { height: 62vh; border-bottom: 1px solid var(--line); }
    .tabs { position: static; }
    .top .sub { display: none; }
  }
  @media (max-width: 560px) {
    .top { flex-wrap: wrap; padding: 12px 16px; }
    .top nav { margin-left: -10px; width: 100%; }
    .verdict, .rest, .foot { padding-left: 16px; padding-right: 16px; }
    .tabs { padding: 0 16px; gap: 14px; }
    .item { padding: 14px 16px; gap: 12px; }
  }
  @media print {
    html, body { height: auto; display: block; overflow: visible; }
    .viewer, .top nav, .done, .tabs { display: none !important; }
    .app { display: block; }
    .list-pane { overflow: visible; border: 0; }
    .item { break-inside: avoid; }
    .item.hidden { display: grid; }
  }
</style>
</head>
'@

    $js = @'
<script>
(function () {
  var store = {
    get: function (k) { try { return localStorage.getItem(k); } catch (e) { return null; } },
    set: function (k, v) { try { localStorage.setItem(k, v); } catch (e) {} }
  };
  var key = 'drawing-review:' + location.pathname + ':';
  var items = Array.prototype.slice.call(document.querySelectorAll('.item'));
  var pins = Array.prototype.slice.call(document.querySelectorAll('.pin'));
  function pinFor(id) { return pins.filter(function (p) { return p.getAttribute('data-id') === id; })[0]; }
  function itemFor(id) { return items.filter(function (i) { return i.getAttribute('data-id') === id; })[0]; }

  /* ---- Fixed checkboxes ---- */
  var progress = document.getElementById('progress');
  function updateProgress() {
    if (!progress) return;
    var n = items.filter(function (i) { return i.classList.contains('is-fixed'); }).length;
    progress.textContent = n ? n + ' of ' + items.length + ' fixed' : '';
  }
  items.forEach(function (item) {
    var box = item.querySelector('.done input');
    var id = item.getAttribute('data-id');
    var k = key + 'fixed:' + id;
    function set(on) {
      item.classList.toggle('is-fixed', on);
      var p = pinFor(id); if (p) p.classList.toggle('is-fixed', on);
    }
    if (store.get(k) === '1') { box.checked = true; set(true); }
    box.addEventListener('change', function () { set(box.checked); store.set(k, box.checked ? '1' : '0'); updateProgress(); });
    box.addEventListener('click', function (e) { e.stopPropagation(); });
  });
  updateProgress();

  /* ---- Filter tabs ---- */
  var tabs = Array.prototype.slice.call(document.querySelectorAll('.tab'));
  tabs.forEach(function (t) {
    t.addEventListener('click', function () {
      var sev = t.getAttribute('data-filter');
      tabs.forEach(function (o) { o.classList.toggle('active', o === t); });
      items.forEach(function (i) {
        var hide = sev !== 'all' && i.getAttribute('data-sev') !== sev;
        i.classList.toggle('hidden', hide);
        var p = pinFor(i.getAttribute('data-id')); if (p) p.classList.toggle('hidden', hide);
      });
    });
  });

  /* ---- Drawing viewer: zoom, pan, sheets ---- */
  var viewer = document.getElementById('viewer');
  var vp = document.getElementById('viewport');
  var zoomLabel = document.getElementById('zoom');
  var st = { s: 1, tx: 0, ty: 0, fit: 1 };
  var cur = vp ? vp.querySelector('.stage:not([hidden])') : null;

  function img() { return cur.querySelector('img'); }
  function apply(anim) {
    if (!cur) return;
    cur.classList.toggle('anim', !!anim);
    cur.style.transform = 'translate(' + st.tx + 'px,' + st.ty + 'px) scale(' + st.s + ')';
    cur.style.setProperty('--inv', 1 / st.s);
    if (zoomLabel) zoomLabel.textContent = Math.round(st.s / st.fit * 100) + '%';
  }
  function fit(anim) {
    if (!cur || !img().naturalWidth) return;
    var r = vp.getBoundingClientRect(), w = img().naturalWidth, h = img().naturalHeight, pad = 28;
    if (!r.width || !r.height) return;
    st.fit = st.s = Math.min((r.width - 2 * pad) / w, (r.height - 2 * pad) / h);
    st.tx = (r.width - w * st.s) / 2; st.ty = (r.height - h * st.s) / 2;
    apply(anim);
  }
  function zoomAt(f, cx, cy, anim) {
    var s2 = Math.min(st.fit * 10, Math.max(st.fit * 0.5, st.s * f));
    st.tx = cx - (cx - st.tx) * (s2 / st.s); st.ty = cy - (cy - st.ty) * (s2 / st.s); st.s = s2;
    apply(anim);
  }
  function whenLoaded(fn) {
    if (img().complete && img().naturalWidth) fn(); else img().addEventListener('load', fn, { once: true });
  }
  function showSheet(n) {
    if (!vp) return;
    var next = vp.querySelector('.stage[data-sheet="' + n + '"]');
    if (!next || next === cur) return;
    cur.hidden = true; next.hidden = false; cur = next;
    Array.prototype.forEach.call(document.querySelectorAll('.stab'), function (b) {
      b.classList.toggle('active', b.getAttribute('data-sheet') === String(n));
    });
    whenLoaded(function () { fit(); });
  }
  function focusPin(pin) {
    showSheet(pin.parentNode.getAttribute('data-sheet'));
    whenLoaded(function () {
      var r = vp.getBoundingClientRect(), w = img().naturalWidth, h = img().naturalHeight;
      var px = parseFloat(pin.style.left) / 100 * w, py = parseFloat(pin.style.top) / 100 * h;
      st.s = Math.max(st.s, st.fit * 2.4);
      st.tx = r.width / 2 - px * st.s; st.ty = r.height / 2 - py * st.s;
      apply(true);
    });
  }

  if (vp && cur) {
    whenLoaded(function () { fit(); });
    window.addEventListener('resize', function () { fit(); });
    vp.addEventListener('wheel', function (e) {
      e.preventDefault();
      var r = vp.getBoundingClientRect();
      zoomAt(Math.exp(-e.deltaY * 0.0016), e.clientX - r.left, e.clientY - r.top);
    }, { passive: false });
    var drag = null;
    vp.addEventListener('pointerdown', function (e) {
      if (e.target.closest('.pin') || e.button !== 0) return;
      drag = { x: e.clientX, y: e.clientY, tx: st.tx, ty: st.ty };
      vp.setPointerCapture(e.pointerId); vp.classList.add('dragging');
    });
    vp.addEventListener('pointermove', function (e) {
      if (!drag) return;
      st.tx = drag.tx + e.clientX - drag.x; st.ty = drag.ty + e.clientY - drag.y; apply(false);
    });
    function endDrag() { drag = null; vp.classList.remove('dragging'); }
    vp.addEventListener('pointerup', endDrag); vp.addEventListener('pointercancel', endDrag);
    vp.addEventListener('dblclick', function (e) { if (!e.target.closest('.pin')) fit(true); });
    Array.prototype.forEach.call(document.querySelectorAll('.controls [data-z]'), function (b) {
      b.addEventListener('click', function () {
        var r = vp.getBoundingClientRect(), z = b.getAttribute('data-z');
        if (z === 'fit') fit(true); else zoomAt(z === 'in' ? 1.4 : 1 / 1.4, r.width / 2, r.height / 2, true);
      });
    });
    Array.prototype.forEach.call(document.querySelectorAll('.stab'), function (b) {
      b.addEventListener('click', function () { showSheet(b.getAttribute('data-sheet')); });
    });
    var showPins = document.getElementById('show-pins');
    if (showPins) {
      showPins.checked = store.get('drawing-review:markup') !== '0';
      viewer.classList.toggle('no-pins', !showPins.checked);
      showPins.addEventListener('change', function () {
        viewer.classList.toggle('no-pins', !showPins.checked);
        store.set('drawing-review:markup', showPins.checked ? '1' : '0');
      });
    }
  }

  /* ---- List <-> drawing ---- */
  function select(id, from) {
    items.forEach(function (i) { i.classList.toggle('selected', i.getAttribute('data-id') === id); });
    pins.forEach(function (p) { p.classList.toggle('selected', p.getAttribute('data-id') === id); });
    var pin = pinFor(id), item = itemFor(id);
    if (from === 'list' && pin && vp && !document.body.classList.contains('no-drawing')) focusPin(pin);
    if (from === 'pin' && item) item.scrollIntoView({ block: 'nearest', behavior: 'smooth' });
  }
  items.forEach(function (item) {
    var id = item.getAttribute('data-id');
    item.addEventListener('click', function (e) {
      if (e.target.closest('.done') || String(window.getSelection())) return;
      select(id, 'list');
    });
    item.addEventListener('mouseenter', function () { var p = pinFor(id); if (p) p.classList.add('hover'); });
    item.addEventListener('mouseleave', function () { var p = pinFor(id); if (p) p.classList.remove('hover'); });
  });
  pins.forEach(function (p) {
    p.addEventListener('click', function (e) { e.stopPropagation(); select(p.getAttribute('data-id'), 'pin'); });
  });

  /* ---- Hide / show the drawing ---- */
  var toggle = document.getElementById('toggle-drawing');
  function setDrawing(show) {
    document.body.classList.toggle('no-drawing', !show);
    if (toggle) toggle.textContent = show ? 'Hide drawing' : 'Show drawing';
    store.set('drawing-review:show-drawing', show ? '1' : '0');
    if (show && cur) setTimeout(function () { fit(); }, 0);
  }
  if (toggle) {
    setDrawing(store.get('drawing-review:show-drawing') !== '0');
    toggle.addEventListener('click', function () { setDrawing(document.body.classList.contains('no-drawing')); });
  }
})();
</script>
'@

    $body = @"
<body class="$bodyClass">
<header class="top">
  <h1>$(& $enc $name)</h1>
  <span class="sub">Drawing review &middot; $when</span>
  <nav>
    $toggleBtn
    $pdfLink
    <a class="hbtn" href="drawing-data.md" target="_blank">Data</a>
    <button class="hbtn" type="button" onclick="window.print()">Print</button>
  </nav>
</header>
<div class="app">
<div class="list-pane"><div class="list-inner">
<section class="verdict v-$verdict">
  <p class="v-line"><span class="v-mark"></span><span class="v-label">$verdictLabel</span>$countText</p>
  $summaryHtml
</section>
$tabs
<div class="items">
$($items.ToString())</div>
<div class="rest">
$restHtml
</div>
<div class="foot">Reviewed by Claude. Values come from the SOLIDWORKS API; sizes estimated from the sheet are approximate. Raw answer: review.md in $(& $enc (Split-Path $Folder -Leaf))</div>
</div></div>
$viewer
</div>
"@

    [IO.File]::WriteAllText($htmlPath, $head + $css + $body + $js + "</body>`n</html>`n", $utf8)
}

try {
    if (-not $RenderOnly) { Invoke-ClaudeReview }
    Write-ReviewHtml
    if (-not $NoOpen) { Invoke-Item -LiteralPath $htmlPath }
}
catch {
    $msg = $_.Exception.Message
    try { Show-Error $msg } catch { }
    Write-Log ("ERROR: " + $msg)
}
