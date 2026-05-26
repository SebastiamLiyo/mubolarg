@echo off
echo === Actualizando MuLauncher.exe desde GitHub ===
echo.
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -Command ^
  "$exe = Join-Path $PWD 'MuLauncher.exe';" ^
  "Get-Process -Name MuLauncher -ErrorAction SilentlyContinue ^| Stop-Process -Force -ErrorAction SilentlyContinue;" ^
  "Start-Sleep -Milliseconds 500;" ^
  "if (Test-Path ($exe + '.OLD')) { Remove-Item ($exe + '.OLD') -Force -ErrorAction SilentlyContinue };" ^
  "if (Test-Path $exe) { try { Rename-Item $exe ($exe + '.OLD') -Force } catch {} };" ^
  "[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12;" ^
  "Write-Host 'Descargando...';" ^
  "Invoke-WebRequest 'https://raw.githubusercontent.com/SebastiamLiyo/mubolarg/main/MuLauncher.exe' -OutFile $exe -UseBasicParsing -TimeoutSec 60;" ^
  "$sz = (Get-Item $exe).Length;" ^
  "Write-Host ('OK MuLauncher.exe actualizado: ' + $sz + ' bytes')"
echo.
pause
