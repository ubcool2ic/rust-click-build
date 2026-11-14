@echo off
setlocal
rem Opens the rtk GUI (builds it first if needed). Falls back to the classic window.
rem ExecutionPolicy Bypass applies only to this one PowerShell process.
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File "%~dp0build.ps1" -Gui -NoPause %*
set RC=%ERRORLEVEL%
if not "%RC%"=="0" pause
endlocal & exit /b %RC%
