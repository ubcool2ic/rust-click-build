@echo off
setlocal
rem Click-and-go Rust builder. Double-click, or drag a project folder onto this file.
rem ExecutionPolicy Bypass applies only to this one PowerShell process.
set "SCRIPT=%~dp0build.ps1"
if "%~1"=="" (
  powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File "%SCRIPT%"
) else (
  rem Quote the first argument so a dragged path containing & is not interpreted by cmd.
  echo %~1| findstr /b /c:"-" >nul
  if not errorlevel 1 (
    powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File "%SCRIPT%" %*
  ) else (
    powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File "%SCRIPT%" -Path "%~1" %2 %3 %4 %5 %6 %7 %8 %9
  )
)
set RC=%ERRORLEVEL%
endlocal & exit /b %RC%
