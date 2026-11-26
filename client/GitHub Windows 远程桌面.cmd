@echo off
setlocal
set "PSModulePath=%SystemRoot%\System32\WindowsPowerShell\v1.0\Modules"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%LOCALAPPDATA%\SkyWorkflowRemote\connect-other.ps1" -System windows
if errorlevel 1 pause
