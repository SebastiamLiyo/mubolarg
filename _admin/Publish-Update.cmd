@echo off
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Publish-Update.ps1" %*
pause
