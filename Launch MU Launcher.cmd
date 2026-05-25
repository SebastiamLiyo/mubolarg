@echo off
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0MuLauncher.ps1"
if errorlevel 1 (
  echo.
  echo === Error al iniciar launcher (exit code %ERRORLEVEL%) ===
  echo Sacale screenshot a esto y mandamelo.
  pause
)
