@echo off
setlocal
set "SCRIPT=%~dp0buildbox_status_log.ps1"
powershell -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" -UseSsh %*
