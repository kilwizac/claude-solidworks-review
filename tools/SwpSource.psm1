<#
  SwpSource.psm1 - the VBA source inside a built macro (.swp), and whether
  it matches the .bas it was built from. Doesn't need SOLIDWORKS.

    Import-Module .\tools\SwpSource.psm1
    Get-SwpModule ClaudeReviewDrawing.swp
    Compare-SwpSource -Swp ClaudeReviewDrawing.swp -Bas src\ClaudeReviewDrawing.bas

  Keep this file ASCII (Windows PowerShell 5.1).
#>

if (-not ('ClaudeReview.SwpSource' -as [type])) {
    Add-Type -Path (Join-Path $PSScriptRoot 'SwpSource.cs')
}
if ($PSVersionTable.PSEdition -eq 'Core') {
    # .NET Core has no Windows-1252 until the code-page provider is added.
    [Text.Encoding]::RegisterProvider([Text.CodePagesEncodingProvider]::Instance)
}

# Modules in the macro: Name, StreamName, Source.
function Get-SwpModule {
    param([Parameter(Mandatory = $true)][string]$Path)
    $full = Convert-Path -LiteralPath $Path
    foreach ($m in [ClaudeReview.SwpSource]::ReadModules($full)) {
        [pscustomobject]@{ Name = $m.Name; StreamName = $m.StreamName; Source = $m.Source }
    }
}

# Source lines as compared. The VBA editor rewrites code it imports: it
# re-cases identifiers to match their declarations, re-spaces operators
# and rewrites number literals (7.0 -> 7#). So outside strings and
# comments, case, spacing and number spelling aren't edits; strings and
# comments must match exactly. Attribute lines (VBA writes its own) and
# blank lines at either end are left out.
function ConvertTo-ComparableCode([string]$code) {
    $c = $code.ToLowerInvariant()
    # Number literals: 7.0 / 7# / 7.50 -> 7 / 7 / 7.5; .5 -> 0.5
    $c = [regex]::Replace($c, '(?<![\w.])\.(\d)', '0.$1')
    $c = [regex]::Replace($c, '(?<![\w.])(\d+)\.(\d*?)0*(?![\d])', { param($m) if ($m.Groups[2].Value) { $m.Groups[1].Value + '.' + $m.Groups[2].Value } else { $m.Groups[1].Value } })
    $c = [regex]::Replace($c, '(?<![\w.])(\d+(?:\.\d+)?)[#!@]', '$1')
    # Spacing: none around punctuation and operators, one space elsewhere.
    $c = [regex]::Replace($c, '\s+', ' ')
    $c = [regex]::Replace($c, '\s*([(),=+\-*/\\&<>:;^])\s*', '$1')
    return $c.Trim()
}

function ConvertTo-ComparableVba([string]$text) {
    $out = New-Object System.Collections.Generic.List[string]
    foreach ($line in ($text -replace "`r`n", "`n" -replace "`r", "`n") -split "`n") {
        if ($line -match '^\s*Attribute\s+VB_') { continue }
        $sb = New-Object System.Text.StringBuilder
        $code = New-Object System.Text.StringBuilder
        $inString = $false
        for ($i = 0; $i -lt $line.Length; $i++) {
            $ch = $line[$i]
            if ($inString) {
                [void]$sb.Append($ch)
                if ($ch -eq '"') { $inString = $false }
            } elseif ($ch -eq '"') {
                [void]$sb.Append((ConvertTo-ComparableCode $code.ToString()))
                [void]$code.Clear()
                $inString = $true
                [void]$sb.Append($ch)
            } elseif ($ch -eq "'") {
                [void]$sb.Append((ConvertTo-ComparableCode $code.ToString()))
                [void]$code.Clear()
                [void]$sb.Append($line.Substring($i).TrimEnd())
                break
            } else {
                [void]$code.Append($ch)
            }
        }
        [void]$sb.Append((ConvertTo-ComparableCode $code.ToString()))
        $out.Add($sb.ToString().Trim())
    }
    while ($out.Count -gt 0 -and $out[$out.Count - 1] -eq '') { $out.RemoveAt($out.Count - 1) }
    while ($out.Count -gt 0 -and $out[0] -eq '') { $out.RemoveAt(0) }
    return ,$out.ToArray()
}

# True when a module holds code, not just Attribute / Option lines.
function Test-VbaHasCode([string]$text) {
    foreach ($l in ConvertTo-ComparableVba $text) {
        if ($l -and $l -notmatch '^\s*option\s+explicit\s*$' -and $l -notmatch "^\s*'") { return $true }
    }
    return $false
}

<#
  Compares a .swp with the .bas it should be built from. The matching
  module is the one whose name starts with the .bas's VB_Name (VBA renames
  a module that shares the project's name: ClaudeReviewDrawing ->
  ClaudeReviewDrawing1). Returns Match, Module, Detail; Detail says what
  differs: the first differing line, a missing module, or other modules
  with code in them.
#>
function Compare-SwpSource {
    param(
        [Parameter(Mandatory = $true)][string]$Swp,
        [Parameter(Mandatory = $true)][string]$Bas
    )
    $basText = [IO.File]::ReadAllText((Convert-Path -LiteralPath $Bas), [Text.Encoding]::GetEncoding(1252))
    $vbName = ''
    if ($basText -match 'Attribute\s+VB_Name\s*=\s*"([^"]+)"') { $vbName = $Matches[1] }
    $modules = @(Get-SwpModule -Path $Swp)

    $mine = @($modules | Where-Object { $vbName -and $_.Name -match ('^' + [regex]::Escape($vbName) + '\d*$') })
    $others = @($modules | Where-Object { $mine -notcontains $_ -and (Test-VbaHasCode $_.Source) })
    $result = [pscustomobject]@{ Match = $false; Module = $null; Detail = '' }

    if ($mine.Count -ne 1) {
        $names = ($modules | ForEach-Object { $_.Name }) -join ', '
        $result.Detail = "Expected one module named $vbName in $(Split-Path $Swp -Leaf); it has: $names"
        return $result
    }
    $result.Module = $mine[0].Name
    $a = ConvertTo-ComparableVba $mine[0].Source
    $b = ConvertTo-ComparableVba $basText
    $n = [Math]::Max($a.Count, $b.Count)
    for ($i = 0; $i -lt $n; $i++) {
        $la = if ($i -lt $a.Count) { $a[$i] } else { '<end of module>' }
        $lb = if ($i -lt $b.Count) { $b[$i] } else { '<end of file>' }
        if ($la -cne $lb) {
            $result.Detail = "Line $($i + 1) of the code differs.`n  .swp: $($la.Trim())`n  .bas: $($lb.Trim())"
            return $result
        }
    }
    if ($others.Count -gt 0) {
        $result.Detail = 'The .swp has other modules with code in them: ' + (($others | ForEach-Object { $_.Name }) -join ', ')
        return $result
    }
    $result.Match = $true
    $result.Detail = "$($mine[0].Name) matches $(Split-Path $Bas -Leaf) ($($b.Count) lines)"
    return $result
}

Export-ModuleMember -Function Get-SwpModule, Compare-SwpSource, ConvertTo-ComparableVba
