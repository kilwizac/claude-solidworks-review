<#
  tools\SwpSource.psm1: reading the VBA code out of a built macro and
  comparing it with its .bas. Releases depend on this comparison, so
  both directions matter: the VBA editor's own rewriting of imported code
  must not count as a change, and any real edit must.
#>

BeforeAll {
    $repo = Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $repo 'tools\SwpSource.psm1') -Force
    if (-not ('ClaudeReview.Tests.FakeSwp' -as [type])) { Add-Type -Path (Join-Path $PSScriptRoot 'lib\FakeSwp.cs') }
    $script:Bas = Join-Path $repo 'src\ClaudeReviewDrawing.bas'
    $script:Source = [IO.File]::ReadAllText($Bas, [Text.Encoding]::GetEncoding(1252))

    # A macro built from the .bas, then the .bas edited to $to.
    function script:Compare-Edited([string]$from, [string]$to) {
        $Source.Contains($from) | Should -BeTrue -Because "the macro should contain '$from'"
        $swp = Join-Path $TestDrive 'Macro.swp'
        [ClaudeReview.Tests.FakeSwp]::FromBas($swp, $Bas)
        $edited = Join-Path $TestDrive 'ClaudeReviewDrawing.bas'
        [IO.File]::WriteAllText($edited, $Source.Replace($from, $to), [Text.Encoding]::GetEncoding(1252))
        return Compare-SwpSource -Swp $swp -Bas $edited
    }
}

Describe 'Reading a built macro' {
    It 'finds the module in a macro built from the .bas' {
        $swp = Join-Path $TestDrive 'Built.swp'
        [ClaudeReview.Tests.FakeSwp]::FromBas($swp, $Bas)
        $c = Compare-SwpSource -Swp $swp -Bas $Bas
        $c.Match | Should -BeTrue -Because $c.Detail
    }
    It "matches this repo's built <Swp>" -TestCases @(
        @{ Swp = 'ClaudeReviewDrawing.swp'; Source = 'src\ClaudeReviewDrawing.bas' }
        @{ Swp = 'demo\BuildDemoDrawing.swp'; Source = 'demo\BuildDemoDrawing.bas' }
    ) {
        $path = Join-Path (Split-Path -Parent $PSScriptRoot) $Swp
        if (-not (Test-Path -LiteralPath $path)) { Set-ItResult -Skipped -Because "$Swp isn't built here (it never is on GitHub)"; return }
        $c = Compare-SwpSource -Swp $path -Bas (Join-Path (Split-Path -Parent $PSScriptRoot) $Source)
        $c.Match | Should -BeTrue -Because $c.Detail
    }
    It 'refuses a file that is not a macro' {
        $p = Join-Path $TestDrive 'not-a-macro.swp'
        [IO.File]::WriteAllText($p, 'hello')
        { Get-SwpModule $p } | Should -Throw '*compound file*'
    }
}

Describe "The VBA editor's rewriting is not a change" {
    It '<What>' -TestCases @(
        @{ What = 'number literals (7.0 written as 7#)'; From = 'mLenFactor = 1000#'; To = 'mLenFactor = 1000.0' }
        @{ What = 'identifier case'; From = 'Dim errNum As Long'; To = 'DIM ERRNUM AS LONG' }
        @{ What = 'spacing around operators'; From = 'errNum = Err.Number'; To = 'errNum   =   Err.Number' }
        @{ What = 'a leading zero'; From = 'If p > 0 Then'; To = 'If p > .0 Then' }
        @{ What = 'Attribute lines'; From = 'Option Explicit'; To = "Attribute VB_Exposed = False`r`nOption Explicit" }
    ) {
        $c = Compare-Edited $From $To
        $c.Match | Should -BeTrue -Because $c.Detail
    }
}

Describe 'A real edit is a change' {
    It '<What>' -TestCases @(
        @{ What = 'a letter in a string'; From = '"Review with Claude"'; To = '"Review with claude"' }
        @{ What = 'a number'; From = 'mLenFactor = 1000#'; To = 'mLenFactor = 1001#' }
        @{ What = 'a comment'; From = "' Folder that holds one subfolder per run."; To = "' Folder holding one subfolder per run." }
        @{ What = 'an operator'; From = 'If rc <= 32 Then'; To = 'If rc < 32 Then' }
        @{ What = 'a removed line'; From = "    mIssues = """"`r`n"; To = '' }
    ) {
        $c = Compare-Edited $From $To
        $c.Match | Should -BeFalse
        $c.Detail | Should -Match 'differs'
    }
}
