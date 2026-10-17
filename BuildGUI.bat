@echo off
rem Opens the simple window (GUI mode).
start "" powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0build.ps1" -Gui
