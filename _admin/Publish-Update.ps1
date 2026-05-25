<#
.SYNOPSIS
  Publica un update del cliente: regenera manifest, commitea, pushea a GitHub.

.DESCRIPTION
  Flujo end-to-end para vos (admin) cada vez que haces cambios en el cliente:
    1. Corre Build-Manifest.ps1 para regenerar manifest.json
    2. git add -A
    3. git commit con timestamp
    4. git push

  Los jugadores reciben el update en su proximo Launch del cliente.

.PARAMETER Message
  Mensaje del commit. Default: "Update <fecha hora>"
#>

[CmdletBinding()]
param(
    [string] $Message = ''
)

$ErrorActionPreference = 'Continue'   # git escribe warnings a stderr que con Stop matarian el script
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
# Si vivimos en _admin/, operamos sobre el parent (root del cliente)
$repoRoot = if ((Split-Path -Leaf $here) -eq '_admin') { Split-Path -Parent $here } else { $here }
Set-Location $repoRoot

if (-not $Message) { $Message = "Update $(Get-Date -Format 'yyyy-MM-dd HH:mm')" }

Write-Host "1/4  Regenerando manifest.json..." -ForegroundColor Cyan
& "$here\Build-Manifest.ps1" | Select-Object -Last 5

Write-Host ""
Write-Host "2/4  git add -A ..." -ForegroundColor Cyan
git add -A 2>$null

$changes = git status --short
if (-not $changes) {
    Write-Host ""
    Write-Host "Nada para commitear (no hubo cambios). Done." -ForegroundColor Yellow
    return
}
Write-Host "Cambios detectados:"
$changes | Select-Object -First 20 | ForEach-Object { "  $_" }
$count = ($changes | Measure-Object -Line).Lines
if ($count -gt 20) { "  ... y $($count - 20) mas" }

Write-Host ""
Write-Host "3/4  git commit ..." -ForegroundColor Cyan
git commit -m $Message --quiet
git log --oneline -1

Write-Host ""
Write-Host "4/4  git push ..." -ForegroundColor Cyan
git push 2>$null
$pushOk = $LASTEXITCODE
if ($pushOk -ne 0) { Write-Host "Push fallo (codigo $pushOk)" -ForegroundColor Red; return }

Write-Host ""
Write-Host "Listo. Los jugadores van a recibir este update en su proximo abrir del launcher." -ForegroundColor Green
