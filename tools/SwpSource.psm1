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

# Source lines as compared with a .bas: the VBA editor's own rewriting
# of imported code (case, spacing, number literals) is evened out, while
# strings and comments must match exactly. See ComparableLines in
# SwpSource.cs (done there: a character loop in PowerShell took a second
# per macro).
function ConvertTo-ComparableVba([string]$text) {
    return ,[ClaudeReview.SwpSource]::ComparableLines($text)
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
