<#
.SYNOPSIS
  Genera manifest.json con SHA256 de todos los archivos del cliente para auto-update.

.DESCRIPTION
  Camina la carpeta donde esta este script (asumiendo que es el root del cliente),
  calcula SHA256 de cada archivo, y escribe manifest.json con:
    - version: timestamp ISO actual
    - base_url: vacio por defecto (los archivos se sirven relativos al manifest URL)
    - files[]: { path, sha256, size }

  Workflow:
    1. Hace cambios en archivos del cliente (Movereq, Item, lo que sea).
    2. Corre este script en la carpeta del cliente.
    3. Sube los archivos cambiados + el manifest.json a su hosting (GitHub/Drive/server).
    4. Los players al abrir el launcher reciben el update automaticamente.

.PARAMETER Exclude
  Patrones glob a excluir (ScreenShots, logs, .dl-tmp, etc.).

.PARAMETER BaseUrl
  Si se especifica, queda hardcoded en el manifest.
  Util si los archivos no estan en el mismo path relativo que el manifest.

.PARAMETER Output
  Path del manifest. Default: manifest.json en el folder del script.

.EXAMPLE
  .\Build-Manifest.ps1
  .\Build-Manifest.ps1 -BaseUrl 'https://cdn.midominio.com/mu/'
#>

[CmdletBinding()]
param(
    [string[]] $Exclude = @(
        'ScreenShots\*', 'ScreenShots/*',
        '*.log', '*.dmp', '*.dl-tmp',
        'MuLauncher.config.json',
        'manifest.json',
        'GetMainInfo.log',
        'RegenerateMainEmu.log',
        'ClientCompatibilitySetup.log',
        'main-mitigations-backup.json',
        'MuLauncher.ps1',         # el propio launcher: no se puede auto-reescribir mientras corre
        'MuLauncher.exe',         # mismo, version compilada
        'Apply-ClientFix.exe',
        '_admin\*', '_admin/*',   # toda la carpeta admin (scripts, README, etc.)
        '.git\*', '.git/*', '.gitignore'
    ),
    [string] $BaseUrl = '',
    [string] $Output = ''
)

$ErrorActionPreference = 'Stop'
# Este script vive en _admin/; el root del cliente es su parent
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = if ((Split-Path -Leaf $scriptDir) -eq '_admin') { Split-Path -Parent $scriptDir } else { $scriptDir }
if (-not $Output) { $Output = Join-Path $root 'manifest.json' }

function Should-Exclude {
    param([string]$RelPath)
    foreach ($pat in $Exclude) {
        if ($RelPath -like $pat) { return $true }
        if ($RelPath -like ($pat -replace '/', '\')) { return $true }
    }
    return $false
}

Write-Host "Escaneando $root ..."
$files = Get-ChildItem -Path $root -Recurse -File
$total = $files.Count
$out = @()
$totalBytes = 0L
$i = 0
foreach ($f in $files) {
    $i++
    $rel = $f.FullName.Substring($root.Length).TrimStart('\','/')
    if (Should-Exclude $rel) { continue }
    if ($i % 200 -eq 0) { Write-Host "  $i/$total ..." }
    $hash = (Get-FileHash -Path $f.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    $out += [pscustomobject]@{
        path   = $rel -replace '\\','/'
        sha256 = $hash
        size   = $f.Length
    }
    $totalBytes += $f.Length
}

$manifest = [ordered]@{
    version  = (Get-Date -Format 'o')
    base_url = $BaseUrl
    files    = $out
}
$json = $manifest | ConvertTo-Json -Depth 5
# Si el manifest existe y esta hidden, sacar el flag para poder escribir
if (Test-Path $Output) {
    $existing = Get-Item $Output -Force
    if ($existing.Attributes -band [System.IO.FileAttributes]::Hidden) {
        $existing.Attributes = $existing.Attributes -band (-bnot [System.IO.FileAttributes]::Hidden)
    }
}
# UTF-8 SIN BOM (PS 5.1 Set-Content -Encoding UTF8 mete BOM y rompe ConvertFrom-Json)
[System.IO.File]::WriteAllText($Output, $json, [System.Text.UTF8Encoding]::new($false))
# Re-ocultar
$item = Get-Item $Output -Force
$item.Attributes = $item.Attributes -bor [System.IO.FileAttributes]::Hidden

Write-Host ""
Write-Host "Manifest escrito: $Output"
Write-Host "  archivos incluidos: $($out.Count)"
Write-Host "  excluidos por patron: $($total - $out.Count)"
Write-Host "  size total cliente: $([Math]::Round($totalBytes/1MB, 1)) MB"
Write-Host ""
Write-Host "Siguiente paso: sube TODA la carpeta del cliente (o al menos los archivos modificados) + manifest.json al hosting."
Write-Host "URL del manifest la pone cada player en su launcher (campo Update URL)."
