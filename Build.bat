@echo off
setlocal
rem Click-and-go Rust builder. Double-click, or drag a project folder onto this file.
rem ExecutionPolicy Bypass applies only to this one PowerShell process.
rem
rem Do not put an unquoted %~1 inside a parenthesized if-block: cmd expands
rem %~1 before parsing, so a folder name with ) ends the block early and &
rem would run the rest of the path as a command. Test the first character
rem via a substring of a quoted variable, then goto (no paren block).
set "SCRIPT=%~dp0build.ps1"
if "%~1"=="" goto :noargs
set "A1=%~1"
if "%A1:~0,1%"=="-" goto :switches
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File "%SCRIPT%" -Path "%~1" %2 %3 %4 %5 %6 %7 %8 %9
set RC=%ERRORLEVEL%
endlocal & exit /b %RC%

:switches
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File "%SCRIPT%" %*
set RC=%ERRORLEVEL%
endlocal & exit /b %RC%

:noargs
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File "%SCRIPT%"
set RC=%ERRORLEVEL%
endlocal & exit /b %RC%
