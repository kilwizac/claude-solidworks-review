@echo off
rem Installs "Review with Claude" for SOLIDWORKS. Double-click to run.
rem The steps are in Install.ps1 next to this file; read it first if you like.

rem Group Policy can forbid PowerShell scripts, and -ExecutionPolicy Bypass
rem doesn't override it. A -Command line isn't a script, so it can still
rem check, and explain instead of PowerShell's bare error.
powershell.exe -NoProfile -Command "$p = Get-ExecutionPolicy -Scope MachinePolicy; if ($p -eq 'Undefined') { $p = Get-ExecutionPolicy -Scope UserPolicy }; if ($p -eq 'Restricted' -or $p -eq 'AllSigned') { exit 3 }"
if "%ERRORLEVEL%"=="3" (
    echo.
    echo Group Policy on this PC blocks unsigned PowerShell scripts, so this
    echo installer can't run, and neither can the default background review.
    echo.
    echo Copy the files in the app folder to a folder of your own instead. Then
    echo open ClaudeReviewDrawing.swp with Tools, Macro, Edit in SOLIDWORKS, set
    echo LAUNCH_MODE to 0 or 1 to review in Claude Desktop, and save.
    goto end
)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Install.ps1" %*
:end
echo.
pause
