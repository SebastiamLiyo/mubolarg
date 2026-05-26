<#
.SYNOPSIS
  Aplica los fixes para que el cliente MU YolaxD se vea bien en Win10/11.

.DESCRIPTION
  Setea en el registro del usuario actual:
    1. HKCU\Software\Webzen\Mu\Config\Resolution = 1   (800x600 ventana, fix M pegado)
    2. HKCU\Software\Webzen\Mu\Config\WindowMode  = 1   (modo ventana)
    3. Compat layer "WIN7RTM RUNASADMIN" para main.exe del cliente

  Detecta main.exe en la MISMA carpeta donde esta este script.
  Es por-usuario, no requiere admin. Para revertir corre con -Revert.

.PARAMETER Revert
  Borra los valores aplicados (deja el registry como estaba antes).

.EXAMPLE
  .\Apply-ClientFix.ps1
  .\Apply-ClientFix.ps1 -Revert
#>

[CmdletBinding()]
param([switch] $Revert)

$ErrorActionPreference = 'Stop'

# Robust path detection (.ps1 directo y PS2EXE compilado)
function Get-AppRoot {
    if ($PSCommandPath) { return Split-Path -Parent $PSCommandPath }
    if ($MyInvocation.MyCommand.Path) { return Split-Path -Parent $MyInvocation.MyCommand.Path }
    try { $loc = [System.Reflection.Assembly]::GetExecutingAssembly().Location; if ($loc) { return Split-Path -Parent $loc } } catch {}
    try { $proc = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName; if ($proc) { return Split-Path -Parent $proc } } catch {}
    return (Get-Location).Path
}
$here = Get-AppRoot
$mainExe = Join-Path $here 'main.exe'

if (-not (Test-Path -LiteralPath $mainExe)) {
  throw "No encontre main.exe en $here. Pone este script en la carpeta del cliente (al lado de main.exe)."
}

$muKey     = 'HKCU:\Software\Webzen\Mu\Config'
$layersKey = 'HKCU:\Software\Microsoft\Windows NT\CurrentVersion\AppCompatFlags\Layers'

if ($Revert) {
  Write-Host "Revirtiendo..."
  if (Test-Path $muKey) {
    Remove-ItemProperty -Path $muKey -Name 'Resolution'  -ErrorAction SilentlyContinue
    Remove-ItemProperty -Path $muKey -Name 'WindowMode'  -ErrorAction SilentlyContinue
  }
  if (Test-Path $layersKey) {
    Remove-ItemProperty -Path $layersKey -Name $mainExe -ErrorAction SilentlyContinue
  }
  Write-Host "Listo. Cerra y volve a abrir el cliente."
  return
}

# Crear claves si no existen
foreach ($k in 'HKCU:\Software\Webzen','HKCU:\Software\Webzen\Mu',$muKey,$layersKey) {
  if (-not (Test-Path $k)) { New-Item -Path $k -Force | Out-Null }
}

Set-ItemProperty -Path $muKey -Name 'Resolution' -Value 1 -Type DWord
Set-ItemProperty -Path $muKey -Name 'WindowMode' -Value 1 -Type DWord
Set-ItemProperty -Path $layersKey -Name $mainExe -Value '~ WIN7RTM RUNASADMIN' -Type String

Write-Host "Aplicado:"
Write-Host "  HKCU\Software\Webzen\Mu\Config\Resolution = 1 (800x600)"
Write-Host "  HKCU\Software\Webzen\Mu\Config\WindowMode = 1 (windowed)"
Write-Host "  Compat layer '$mainExe' = 'WIN7RTM RUNASADMIN'"

# Ocultar archivos feos del cliente para que la carpeta se vea limpia
Write-Host ""
Write-Host "Ocultando archivos internos (no se borran, solo se hacen invisibles)..."
$toHide = @(
    'Custom*.txt', 'main.emu', 'Main.dll', 'MainInfo.ini',
    'GetMainInfo.exe', 'manifest.json', '.gitignore', '.gitattributes',
    'msvcp100.dll', 'msvcr100.dll', 'ogg.dll', 'vorbisfile.dll', 'wzAudio.dll',
    'MuError.log', 'MuError.dmp', 'main.emu.bak', '*.OLD', '*.tmp*'
)
$hiddenCount = 0
foreach ($pattern in $toHide) {
    Get-ChildItem -Path $here -Filter $pattern -Force -ErrorAction SilentlyContinue | ForEach-Object {
        try {
            $_.Attributes = $_.Attributes -bor [System.IO.FileAttributes]::Hidden
            $hiddenCount++
        } catch {}
    }
}
Write-Host "  $hiddenCount archivos ocultos (Customs, dlls, main.emu, etc)"

Write-Host ""
Write-Host "Cerra y volve a abrir el cliente para que tomen efecto."
Write-Host "Para revertir: .\Apply-ClientFix.ps1 -Revert"
