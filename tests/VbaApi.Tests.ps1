<#
  SOLIDWORKS API names in the VBA macros, checked against the SOLIDWORKS
  2025 interop assemblies (tests\lib\VbaApi.psm1). Needs SOLIDWORKS
  installed, not running; skipped where it isn't (e.g. GitHub Actions).
  Set SW_INTEROP_DIR to check against another version's api\redist.
#>

BeforeDiscovery {
    Import-Module (Join-Path $PSScriptRoot 'lib\VbaApi.psm1') -Force
    $script:NoInterop = -not (Find-SolidWorksInterop)
    $script:Macros = @(
        @{ File = 'src\ClaudeReviewDrawing.bas' }
        @{ File = 'demo\BuildDemoDrawing.bas' }
    )
}

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'lib\VbaApi.psm1') -Force
    $script:Repo = Split-Path -Parent $PSScriptRoot
    $script:Interop = Find-SolidWorksInterop
}

Describe 'SOLIDWORKS API names in <File>' -ForEach $Macros -Skip:$NoInterop {
    BeforeAll {
        $stats = $null
        $script:Problems = Test-VbaApiNames -Path (Join-Path $Repo $File) -InteropDir $Interop -Stats ([ref]$stats)
        $script:Stats = $stats
        Write-Host "    $File`: $($stats.Constant) constants, $($stats.Member) members, $($stats.LateBound) late-bound names checked"
    }
    It 'uses only SOLIDWORKS constants that exist' {
        (@($Problems | Where-Object Kind -eq 'Constant') | ForEach-Object { "line $($_.Line): $($_.Message)" }) -join "`n" | Should -BeNullOrEmpty
    }
    It 'calls only members that exist on the declared types' {
        (@($Problems | Where-Object Kind -eq 'Member') | ForEach-Object { "line $($_.Line): $($_.Message)" }) -join "`n" | Should -BeNullOrEmpty
    }
    It 'names only members that exist in TryValue / CallByName' {
        (@($Problems | Where-Object Kind -eq 'LateBound') | ForEach-Object { "line $($_.Line): $($_.Message)" }) -join "`n" | Should -BeNullOrEmpty
    }
}

Describe 'The API name check itself' -Skip:$NoInterop {
    BeforeAll {
        $src = [IO.File]::ReadAllText((Join-Path $Repo 'src\ClaudeReviewDrawing.bas'))
        function script:Check-Mutant([string]$from, [string]$to) {
            $src.Contains($from) | Should -BeTrue -Because "the macro should contain '$from' to mutate"
            $p = Join-Path $TestDrive 'Mutant.bas'
            [IO.File]::WriteAllText($p, $src.Replace($from, $to))
            return ,(Test-VbaApiNames -Path $p -InteropDir $Interop)
        }
    }
    It 'catches a misspelt constant' {
        $p = Check-Mutant 'swModel.GetType <> swDocDRAWING' 'swModel.GetType <> swDocDRAWINGS'
        $p.Message | Should -Contain 'swDocDRAWINGS is not a SOLIDWORKS constant (swconst)'
    }
    It 'catches a missing member deep in a chain' {
        $p = Check-Mutant 'swModel.Extension.SaveAs3(' 'swModel.Extension.SaveAs33('
        ($p | Where-Object Kind -eq 'Member').Message | Should -Match 'ModelDocExtension has no member SaveAs33'
    }
    It 'catches a missing member after a call' {
        $p = Check-Mutant 'Set swDim = swDispDim.GetDimension2(0)' 'Set swDim = swDispDim.GetDimension3(0)'
        ($p | Where-Object Kind -eq 'Member').Message | Should -Match 'has no member GetDimension3'
    }
    It 'catches a misspelt late-bound member on a typed variable' {
        $p = Check-Mutant 'TryValue(swAnn, "Visible"' 'TryValue(swAnn, "Visibel"'
        ($p | Where-Object Kind -eq 'LateBound').Message | Should -Match 'Annotation has no member Visibel'
    }
    It 'catches a late-bound member no SOLIDWORKS interface has' {
        $p = Check-Mutant 'TryValue(gt, "GetFrameCount"' 'TryValue(gt, "GetFrameCounts"'
        ($p | Where-Object Kind -eq 'LateBound').Message | Should -Match 'no SOLIDWORKS interface has a member GetFrameCounts'
    }
}
