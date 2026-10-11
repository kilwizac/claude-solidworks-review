@echo off
rem Installs "Review with Claude" for SOLIDWORKS. Double-click to run.
rem The steps are in Install.ps1 next to this file; read it first if you like.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Install.ps1" %*
echo.
pause
