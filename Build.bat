@echo off
setlocal EnableExtensions DisableDelayedExpansion
rem Click-and-go Rust builder. Double-click, or drag a project folder onto this file.
rem ExecutionPolicy Bypass applies only to this one PowerShell process.
rem
rem Do not put an unquoted %~1 inside a parenthesized if-block: cmd expands
rem %~1 before parsing, so a folder name with ) ends the block early and &
rem would run the rest of the path as a command. Test the first character
rem via a substring of a quoted variable, then goto (no paren block).
rem
rem Extra args are accumulated with call :append and delayed expansion.
rem Do not use a quoted set that appends a quoted argument — the inner
rem quote ends the quoted assignment early. :append uses unquoted
rem set MORE=!MORE! %1 and endlocal plus set MORE=%MORE% to export it.
set "SCRIPT=%~dp0build.ps1"
if "%~1"=="" goto :noargs
set "A1=%~1"
if "%A1:~0,1%"=="-" goto :switches
set "MORE="
if not "%~2"=="" call :append "%~2"
if not "%~3"=="" call :append "%~3"
if not "%~4"=="" call :append "%~4"
if not "%~5"=="" call :append "%~5"
if not "%~6"=="" call :append "%~6"
if not "%~7"=="" call :append "%~7"
if not "%~8"=="" call :append "%~8"
if not "%~9"=="" call :append "%~9"
setlocal EnableDelayedExpansion
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File "%SCRIPT%" -Path "%~1"!MORE!
set "RC=!ERRORLEVEL!"
endlocal & set "RC=%RC%"
endlocal & exit /b %RC%

:switches
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File "%SCRIPT%" %*
set RC=%ERRORLEVEL%
endlocal & exit /b %RC%

:noargs
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File "%SCRIPT%"
set RC=%ERRORLEVEL%
endlocal & exit /b %RC%

:append
setlocal EnableDelayedExpansion
set MORE=!MORE! %1
endlocal & set MORE=%MORE%
goto :eof
