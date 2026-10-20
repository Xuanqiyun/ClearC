@echo off
rem Run CleanC-UI.ps1 directly with the built-in Windows PowerShell 5.1 (no build needed).
rem The script asks for administrator rights (UAC) by itself.
set "HERE=%~dp0"
if not exist "%HERE%CleanC-UI.ps1" (echo CleanC-UI.ps1 not found next to this file. & pause & exit /b 1)
start "" "%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%HERE%CleanC-UI.ps1"
