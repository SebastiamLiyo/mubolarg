<#
.SYNOPSIS
  Cicla por valores de Resolution en el registry para encontrar uno donde la M se vea bien.

.DESCRIPTION
  Setea HKCU\Software\Webzen\Mu\Config\Resolution al valor pasado.
  Despues abris el cliente, apretas M, y si se ve mal cerras y probas el siguiente.

.PARAMETER Value
  Valor a probar (0..8). Si no se pasa, abre menu interactivo.
#>

[CmdletBinding()]
param(
    [int] $Value = -1
)

$mu = 'HKCU:\Software\Webzen\Mu\Config'

$descriptions = @{
    0 = '640 x 480 (chiquito)'
    1 = '800 x 600 (esta puesto ahora)'
    2 = '1024 x 768'
    3 = '1280 x 720'
    4 = '1280 x 1024'
    5 = '1366 x 768'
    6 = '1440 x 900'
    7 = '1600 x 900'
    8 = '1920 x 1080'
}

if ($Value -lt 0) {
    $current = (Get-ItemProperty $mu).Resolution
    Write-Host "Resolution actual: $current ($($descriptions[$current]))"
    Write-Host ""
    Write-Host "Valores disponibles:"
    foreach ($k in 0..8) {
        $mark = if ($k -eq $current) { '<-- actual' } else { '' }
        "  $k = $($descriptions[$k])  $mark"
    }
    Write-Host ""
    $input = Read-Host "Que valor probar? (0-8, Enter para salir)"
    if (-not $input) { return }
    $Value = [int]$input
}

if ($Value -lt 0 -or $Value -gt 8) {
    Write-Host "Valor invalido. Usa 0-8." -ForegroundColor Red
    exit 1
}

Set-ItemProperty -Path $mu -Name 'Resolution' -Value $Value -Type DWord
Write-Host "Resolution = $Value ($($descriptions[$Value]))" -ForegroundColor Green
Write-Host ""
Write-Host "Ahora:"
Write-Host "  1. Abri el cliente (main.exe o Launcher)"
Write-Host "  2. Logueate, apreta M"
Write-Host "  3. Si la M se ve BIEN -> dejala asi, no toques nada"
Write-Host "  4. Si se ve mal -> cerra el cliente, volve a correr este script con otro valor"
Write-Host ""
Write-Host "Tip: corre como '.\Test-Resolution.ps1 -Value 2' para probar 1024x768 directo."
