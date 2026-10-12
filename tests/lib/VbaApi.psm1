<#
  VbaApi.psm1 - checks the SOLIDWORKS API names a VBA module uses against
  the SOLIDWORKS interop assemblies, without SOLIDWORKS running:

  - every sw... constant is a member of an enum in swconst;
  - every member used on a variable declared As SldWorks.<Type> exists on
    that type, following property and method types along a chain
    (swModel.Extension.SaveAs3);
  - every member named in a string for TryValue / CallByName exists: on
    the variable's type when it's declared As SldWorks.<Type>, else on
    some SOLIDWORKS interface. VBA can't check these names at all - a
    misspelt one just returns the fallback.

  VBA only reports a wrong early-bound name when the macro compiles in
  SOLIDWORKS; these checks run in any test run on a PC with SOLIDWORKS
  installed. Keep this file ASCII.
#>

# The api\redist folder of an installed SOLIDWORKS (2025 by default), or
# $env:SW_INTEROP_DIR. $null when there is none.
function Find-SolidWorksInterop([int]$Year = 2025) {
    if ($env:SW_INTEROP_DIR -and (Test-Path -LiteralPath (Join-Path $env:SW_INTEROP_DIR 'SolidWorks.Interop.sldworks.dll'))) {
        return $env:SW_INTEROP_DIR
    }
    foreach ($root in 'HKLM:\SOFTWARE\SolidWorks', 'HKLM:\SOFTWARE\WOW6432Node\SolidWorks') {
        $setup = Get-ItemProperty -LiteralPath "$root\SOLIDWORKS $Year\Setup" -ErrorAction SilentlyContinue
        if ($setup -and $setup.'SolidWorks Folder') {
            $dir = Join-Path $setup.'SolidWorks Folder' 'api\redist'
            if (Test-Path -LiteralPath (Join-Path $dir 'SolidWorks.Interop.sldworks.dll')) { return $dir }
        }
    }
    return $null
}

$script:Api = $null
function Get-SolidWorksApi([string]$InteropDir) {
    if ($script:Api -and $script:Api.Dir -eq $InteropDir) { return $script:Api }
    $const = [Reflection.Assembly]::LoadFrom((Join-Path $InteropDir 'SolidWorks.Interop.swconst.dll'))
    $sw = [Reflection.Assembly]::LoadFrom((Join-Path $InteropDir 'SolidWorks.Interop.sldworks.dll'))
    $enumMembers = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($e in $const.GetTypes() | Where-Object { $_.IsEnum }) {
        foreach ($n in [Enum]::GetNames($e)) { [void]$enumMembers.Add($n) }
    }
    $types = @{}
    $anyMember = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($t in $sw.GetTypes() | Where-Object { $_.IsInterface }) {
        $types[$t.Name.ToLowerInvariant()] = $t
        foreach ($m in $t.GetMembers()) { [void]$anyMember.Add($m.Name) }
    }
    $script:Api = [pscustomobject]@{ Dir = $InteropDir; EnumMembers = $enumMembers; Types = $types; AnyMember = $anyMember }
    return $script:Api
}

# The member of an interop interface (or the interfaces it inherits),
# ignoring case as VBA does; $null if none.
function Find-ApiMember([Type]$type, [string]$name) {
    foreach ($t in @($type) + @($type.GetInterfaces())) {
        $m = $t.GetMember($name, [Reflection.BindingFlags]'Public, Instance, IgnoreCase')
        if ($m.Count -gt 0) { return $m[0] }
    }
    return $null
}

# The interop interface a member returns, or $null (Object, Variant,
# values).
function Get-ApiMemberType($api, $member) {
    $rt = $null
    if ($member -is [Reflection.PropertyInfo]) { $rt = $member.PropertyType }
    elseif ($member -is [Reflection.MethodInfo]) { $rt = $member.ReturnType }
    if ($rt -and $rt.IsInterface -and $rt.Namespace -eq 'SolidWorks.Interop.sldworks') { return $rt }
    return $null
}

# Logical lines (continuations joined), each split into Code (strings
# and comments blanked out) and Raw (code and strings, no comment).
function Get-VbaLines([string]$path) {
    $physical = [IO.File]::ReadAllLines($path)
    $logical = New-Object System.Collections.Generic.List[object]
    $buf = ''; $start = 0
    for ($i = 0; $i -lt $physical.Count; $i++) {
        if ($buf -eq '') { $start = $i + 1 }
        $l = $physical[$i]
        if ($l -match '^(.*\s)_\s*$') { $buf += $Matches[1]; continue }
        $buf += $l
        $code = New-Object System.Text.StringBuilder
        $raw = New-Object System.Text.StringBuilder
        $inStr = $false
        foreach ($ch in $buf.ToCharArray()) {
            if ($inStr) {
                [void]$raw.Append($ch)
                if ($ch -eq '"') { $inStr = $false; [void]$code.Append('"') } else { [void]$code.Append(' ') }
            } elseif ($ch -eq '"') {
                $inStr = $true; [void]$raw.Append($ch); [void]$code.Append('"')
            } elseif ($ch -eq "'") {
                break
            } else {
                [void]$raw.Append($ch); [void]$code.Append($ch)
            }
        }
        $logical.Add([pscustomobject]@{ Line = $start; Code = $code.ToString(); Raw = $raw.ToString() })
        $buf = ''
    }
    return ,$logical.ToArray()
}

<#
  Problems with the SOLIDWORKS API names in one .bas: objects with Line,
  Kind (Constant / Member / LateBound) and Message. Also returns, through
  -Stats, how many of each were checked.
#>
function Test-VbaApiNames {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$InteropDir,
        [ref]$Stats
    )
    $api = Get-SolidWorksApi $InteropDir
    $lines = Get-VbaLines $Path
    $problems = New-Object System.Collections.Generic.List[object]
    $counts = @{ Constant = 0; Member = 0; LateBound = 0 }

    # Everything the module declares, so its own sw... names (swApp)
    # aren't taken for constants; and each procedure's variable types.
    $declared = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $declRx = '\b(\w+)(?:\(\s*\))?\s+As\s+(?:New\s+)?([\w.]+)'
    $moduleTypes = @{}
    $procTypes = @{}
    $inProc = $false
    $scopes = New-Object System.Collections.Generic.List[object]
    foreach ($l in $lines) {
        if ($l.Code -match '^\s*(?:(?:Public|Private|Friend)\s+)?(?:Static\s+)?(?:Sub|Function|Property\s+\w+)\s+(\w+)') {
            [void]$declared.Add($Matches[1])
            $inProc = $true
            $procTypes = @{}
        }
        if ($l.Code -match '^\s*(?:(?:Public|Private)\s+)?Const\s+(\w+)') { [void]$declared.Add($Matches[1]) }
        if ($l.Code -match '^\s*(?:Public|Private)?\s*Declare\s+(?:PtrSafe\s+)?(?:Function|Sub)\s+(\w+)') { [void]$declared.Add($Matches[1]) }
        foreach ($m in [regex]::Matches($l.Code, $declRx)) {
            [void]$declared.Add($m.Groups[1].Value)
            $target = $moduleTypes; if ($inProc) { $target = $procTypes }
            $target[$m.Groups[1].Value.ToLowerInvariant()] = $m.Groups[2].Value
        }
        $scopes.Add($procTypes)
        if ($l.Code -match '^\s*End\s+(Sub|Function|Property)\b') { $inProc = $false; $procTypes = @{} }
    }

    $typeOf = {
        param([int]$i, [string]$name)
        $k = $name.ToLowerInvariant()
        $decl = $null
        if ($scopes[$i].ContainsKey($k)) { $decl = $scopes[$i][$k] } elseif ($moduleTypes.ContainsKey($k)) { $decl = $moduleTypes[$k] }
        if ($decl -and $decl -match '^SldWorks\.(\w+)$') {
            $t = $api.Types[$Matches[1].ToLowerInvariant()]
            if ($t) { return $t }
        }
        return $null
    }

    for ($i = 0; $i -lt $lines.Count; $i++) {
        $l = $lines[$i]
        # 1. Constants: sw... names that aren't the module's own.
        foreach ($m in [regex]::Matches($l.Code, '(?<![\w.])(sw[A-Za-z0-9_]+)\b')) {
            $n = $m.Groups[1].Value
            if ($declared.Contains($n)) { continue }
            $counts.Constant++
            if (-not $api.EnumMembers.Contains($n)) {
                $problems.Add([pscustomobject]@{ Line = $l.Line; Kind = 'Constant'; Message = "$n is not a SOLIDWORKS constant (swconst)" })
            }
        }
        # 2. Early-bound members along a chain: var.A(...).B
        foreach ($m in [regex]::Matches($l.Code, '(?<![\w.])(\w+)((?:\.\w+(?:\((?:[^()]|\([^()]*\))*\))?)+)')) {
            $t = & $typeOf $i $m.Groups[1].Value
            if (-not $t) { continue }
            $path = $m.Groups[1].Value
            foreach ($seg in [regex]::Matches($m.Groups[2].Value, '\.(\w+)')) {
                $name = $seg.Groups[1].Value
                $counts.Member++
                $member = Find-ApiMember $t $name
                if (-not $member) {
                    $problems.Add([pscustomobject]@{ Line = $l.Line; Kind = 'Member'; Message = "$path.$name - $($t.Name) has no member $name" })
                    break
                }
                $path += ".$name"
                $t = Get-ApiMemberType $api $member
                if (-not $t) { break }
            }
        }
        # 3. Late-bound members named in strings.
        foreach ($m in [regex]::Matches($l.Raw, '\b(?:TryValue|CallByName)\s*\(\s*([^,]+?)\s*,\s*"(\w+)"')) {
            $obj = $m.Groups[1].Value.Trim(); $name = $m.Groups[2].Value
            $counts.LateBound++
            $t = $null
            if ($obj -match '^\w+$') { $t = & $typeOf $i $obj }
            if ($t) {
                if (-not (Find-ApiMember $t $name)) {
                    $problems.Add([pscustomobject]@{ Line = $l.Line; Kind = 'LateBound'; Message = "TryValue($obj, `"$name`") - $($t.Name) has no member $name" })
                }
            } elseif (-not $api.AnyMember.Contains($name)) {
                $problems.Add([pscustomobject]@{ Line = $l.Line; Kind = 'LateBound'; Message = "TryValue($obj, `"$name`") - no SOLIDWORKS interface has a member $name" })
            }
        }
    }
    if ($Stats) { $Stats.Value = $counts }
    return ,$problems.ToArray()
}

Export-ModuleMember -Function Find-SolidWorksInterop, Test-VbaApiNames
