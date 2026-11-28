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
set "MORE="
if not "%~2"=="" set "MORE=%MORE% "%~2""
if not "%~3"=="" set "MORE=%MORE% "%~3""
if not "%~4"=="" set "MORE=%MORE% "%~4""
if not "%~5"=="" set "MORE=%MORE% "%~5""
if not "%~6"=="" set "MORE=%MORE% "%~6""
if not "%~7"=="" set "MORE=%MORE% "%~7""
if not "%~8"=="" set "MORE=%MORE% "%~8""
if not "%~9"=="" set "MORE=%MORE% "%~9""
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File "%SCRIPT%" -Path "%~1"%MORE%
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
