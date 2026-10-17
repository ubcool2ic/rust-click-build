@echo off
setlocal
rem Click-and-go Rust builder. Double-click, or drag a project folder onto this file.
rem ExecutionPolicy Bypass applies only to this one PowerShell process.
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File "%~dp0build.ps1" %*
set RC=%ERRORLEVEL%
endlocal ^& exit /b %RC%
