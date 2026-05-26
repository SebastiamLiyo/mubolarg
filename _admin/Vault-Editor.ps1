<#
.SYNOPSIS
  Editor de vault (warehouse) avanzado para MuEMU 1.04.05 - mubolarg.

.DESCRIPTION
  GUI que lee Data/Item/Item.txt del server para tener TODOS los items disponibles,
  organizados por categoria. Permite:
    - Elegir item de cualquier tipo
    - Setear nivel, luck, skill, option, excellent (bitmask)
    - Colocar en slot especifico o siguiente libre
    - Click derecho en slot del vault para borrar
    - Backup automatico antes de guardar
#>

[CmdletBinding()]
param(
    [string] $SqlInstance = '.\SQLEXPRESS',
    [string] $Database = 'MuOnline',
    [string] $ItemTxtPath = 'C:\Users\liyar\Documents\muserver\MuServer\Data\Item\Item.txt'
)

Set-StrictMode -Off
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Data

$script:rng = [System.Random]::new()

# ============================================================
# Robust path detection (works in .ps1 and PS2EXE)
# ============================================================
function Get-AppRoot {
    if ($PSCommandPath) { return Split-Path -Parent $PSCommandPath }
    if ($MyInvocation.MyCommand.Path) { return Split-Path -Parent $MyInvocation.MyCommand.Path }
    try {
        $loc = [System.Reflection.Assembly]::GetExecutingAssembly().Location
        if ($loc) { return Split-Path -Parent $loc }
    } catch {}
    try {
        $proc = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
        if ($proc) { return Split-Path -Parent $proc }
    } catch {}
    return (Get-Location).Path
}

# ============================================================
# Item bytes
# ============================================================

function New-EmptySlot {
    $b = New-Object byte[] 16
    for ($i = 0; $i -lt 16; $i++) { $b[$i] = 0xFF }
    return ,$b
}

function New-ItemBytes {
    param(
        [int] $Type, [int] $Index,
        [int] $Level = 0,
        [bool] $Luck = $false, [bool] $Skill = $false,
        [int] $Option = 0,
        [int] $Excellent = 0,
        [int] $Durability = 255,
        [bool] $IsMisc = $false
    )
    $b = New-Object byte[] 16
    $b[0] = [byte]($Index -band 0xFF)
    $b1 = (($Level -band 0x0F) -shl 3) -bor (($Option -band 0x03))
    if ($Luck)  { $b1 = $b1 -bor 0x04 }
    if ($Skill) { $b1 = $b1 -bor 0x80 }
    $b[1] = [byte]$b1
    $b[2] = [byte]($Durability -band 0xFF)
    $b[3] = [byte]($Excellent -band 0x3F)
    for ($i = 4; $i -le 8; $i++) { $b[$i] = 0x00 }
    $b[9] = [byte]((($Type -band 0x0F) -shl 4) -bor (($Index -shr 8) -band 0x0F))
    if ($IsMisc) {
        for ($i = 10; $i -le 15; $i++) { $b[$i] = 0x00 }
    } else {
        $b[10] = 0xFF; $b[11] = 0xFF; $b[12] = 0xFF; $b[13] = 0xFF
        $b[14] = [byte]$script:rng.Next(1, 256)
        $b[15] = [byte]$script:rng.Next(1, 256)
    }
    return ,$b
}

# ============================================================
# Parser de Item.txt - construye catalogo completo
# ============================================================

# Mapeo de seccion -> categoria visible
$script:TypeNames = @{
    0='Swords'; 1='Axes'; 2='Maces/Scepters'; 3='Spears'; 4='Bows/Crossbows'
    5='Staves'; 6='Shields'; 7='Helms'; 8='Armors'; 9='Pants'; 10='Gloves'
    11='Boots'; 12='Wings/Pets'; 13='Pendants/Rings'; 14='Misc/Jewels/Scrolls'
}

function Parse-ItemTxt {
    param([string] $Path)
    $cat = @{}   # Type -> array of @{ Index, Name, Width, Height, HasSerial, HasOption, Skill, Dur, MaxDur }
    if (-not (Test-Path $Path)) { return $cat }
    $lines = Get-Content $Path
    $type = $null
    $inSection = $false
    foreach ($raw in $lines) {
        $line = $raw.Trim()
        if (-not $line) { continue }
        if ($line -eq 'end') { $inSection = $false; $type = $null; continue }
        if ($line -match '^\d+$' -and -not $inSection) { $type = [int]$line; $inSection = $true; $cat[$type] = @(); continue }
        if (-not $inSection) { continue }
        if ($line.StartsWith('//')) { continue }   # header comments

        # Parsear linea de item: campos separados por espacios, nombre en comillas
        # Formato: Type Slot Skill Width Height HaveSerial HaveOption DropItem "Name" Level Dur Dur ...
        if ($line -match '^(\d+)\s+\S+\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s+\S+\s+"([^"]*)"') {
            $idx = [int]$matches[1]
            $skill = [int]$matches[2]
            $width = [int]$matches[3]
            $height = [int]$matches[4]
            $hasSer = [int]$matches[5]
            $hasOpt = [int]$matches[6]
            $name = $matches[7]
            # Heuristica de durabilidad / IsMisc: en categoria 14, ciertos items son misc (consumibles)
            $isMisc = ($type -eq 14)
            $dur = if ($isMisc) { 1 } else { 100 }
            $cat[$type] += [pscustomobject]@{
                Index = $idx
                Name = $name
                Skill = $skill
                Width = $width
                Height = $height
                HasSerial = $hasSer
                HasOption = $hasOpt
                IsMisc = $isMisc
                DefaultDur = $dur
            }
        }
    }
    return $cat
}

$script:ItemCatalog = Parse-ItemTxt -Path $ItemTxtPath
if ($script:ItemCatalog.Count -eq 0) {
    [System.Windows.Forms.MessageBox]::Show(
        "No se pudo leer Item.txt en $ItemTxtPath`nEl editor anda igual pero sin lista de items.",
        'Aviso', 'OK', 'Warning') | Out-Null
}

# ============================================================
# DB helpers
# ============================================================

function Open-DbConnection {
    $cn = New-Object System.Data.SqlClient.SqlConnection "Server=$SqlInstance;Database=$Database;Integrated Security=SSPI;"
    $cn.Open()
    return $cn
}

function Get-Characters {
    $cn = Open-DbConnection
    $cmd = $cn.CreateCommand()
    $cmd.CommandText = @"
SELECT c.AccountID, c.Name, c.Class, c.cLevel, w.Money
FROM Character c
LEFT JOIN warehouse w ON w.AccountID = c.AccountID
ORDER BY c.AccountID, c.Name
"@
    $rd = $cmd.ExecuteReader()
    $rows = @()
    while ($rd.Read()) {
        $rows += [pscustomobject]@{
            AccountID = [string]$rd['AccountID']
            Name = [string]$rd['Name']
            Class = [int]$rd['Class']
            Level = [int]$rd['cLevel']
            Money = if ($rd['Money'] -isnot [DBNull]) { [int]$rd['Money'] } else { 0 }
        }
    }
    $rd.Close(); $cn.Close()
    return $rows
}

function Get-VaultBlob {
    param([string] $AccountID)
    $cn = Open-DbConnection
    $cmd = $cn.CreateCommand()
    $cmd.CommandText = "SELECT Items FROM warehouse WHERE AccountID=@a"
    [void]$cmd.Parameters.AddWithValue('@a', $AccountID)
    $blob = $cmd.ExecuteScalar()
    $cn.Close()
    if (-not $blob) { return $null }
    return $blob
}

function Save-VaultBlob {
    param([string] $AccountID, [byte[]] $Bytes)
    if ($Bytes.Length -ne 1920) { throw "Vault blob debe ser 1920 bytes, recibi $($Bytes.Length)" }
    $appRoot = Get-AppRoot
    $clientRoot = if ((Split-Path -Leaf $appRoot) -eq '_admin') { Split-Path -Parent $appRoot } else { $appRoot }
    $backupDir = Join-Path $clientRoot 'vault-backup'
    if (-not (Test-Path $backupDir)) { New-Item -ItemType Directory -Path $backupDir -Force | Out-Null }
    $current = Get-VaultBlob -AccountID $AccountID
    if ($current) {
        $bkPath = Join-Path $backupDir ("$AccountID-" + (Get-Date -Format 'yyyyMMdd-HHmmss') + '-editor.bin')
        [IO.File]::WriteAllBytes($bkPath, $current)
    }
    $cn = Open-DbConnection
    $up = $cn.CreateCommand()
    $up.CommandText = "UPDATE warehouse SET Items=@b WHERE AccountID=@a"
    $p = $up.Parameters.Add('@b', [System.Data.SqlDbType]::VarBinary, 1920); $p.Value = $Bytes
    [void]$up.Parameters.AddWithValue('@a', $AccountID)
    $n = $up.ExecuteNonQuery()
    $cn.Close()
    return $n
}

# ============================================================
# Vault parsing
# ============================================================

function Find-ItemName {
    param([int] $Type, [int] $Index, [int] $Level)
    if ($script:ItemCatalog.ContainsKey($Type)) {
        foreach ($it in $script:ItemCatalog[$Type]) {
            if ($it.Index -eq $Index) { return $it.Name }
        }
    }
    return "T=$Type I=$Index"
}

function Read-VaultSlots {
    param([byte[]] $Blob)
    $slots = @()
    for ($s = 0; $s -lt 120; $s++) {
        $off = $s * 16
        $isEmpty = $true
        for ($i = 0; $i -lt 16; $i++) { if ($Blob[$off + $i] -ne 0xFF) { $isEmpty = $false; break } }
        if ($isEmpty) { continue }
        $type   = ($Blob[$off + 9] -shr 4) -band 0x0F
        $idxLo  = $Blob[$off + 0]
        $idxHi  = $Blob[$off + 9] -band 0x0F
        $idx    = ($idxHi -shl 8) -bor $idxLo
        $b1     = $Blob[$off + 1]
        $level  = ($b1 -shr 3) -band 0x0F
        $option = $b1 -band 0x03
        $luck   = ($b1 -band 0x04) -ne 0
        $skill  = ($b1 -band 0x80) -ne 0
        $exc    = $Blob[$off + 3] -band 0x3F
        $slots += [pscustomobject]@{
            Slot  = $s
            Name  = (Find-ItemName -Type $type -Index $idx -Level $level)
            Type  = $type; Idx = $idx
            Level = $level
            Luck  = $luck; Skill = $skill
            Opt   = $option; Exc = $exc
        }
    }
    return $slots
}

function Find-FreeSlot {
    param([byte[]] $Blob)
    for ($s = 0; $s -lt 120; $s++) {
        $off = $s * 16
        $isEmpty = $true
        for ($i = 0; $i -lt 16; $i++) { if ($Blob[$off+$i] -ne 0xFF) { $isEmpty = $false; break } }
        if ($isEmpty) { return $s }
    }
    return -1
}

function Clear-SlotInBlob {
    param([byte[]] $Blob, [int] $Slot)
    for ($i = 0; $i -lt 16; $i++) { $Blob[$Slot * 16 + $i] = 0xFF }
}

function Place-ItemInBlob {
    param([byte[]] $Blob, [int] $Slot, [byte[]] $Item)
    [Array]::Copy($Item, 0, $Blob, $Slot * 16, 16)
}

# ============================================================
# State
# ============================================================
$script:CurrentBlob = $null
$script:CurrentAccount = $null
$script:CurrentChar = $null

# ============================================================
# GUI
# ============================================================

$form = New-Object System.Windows.Forms.Form
$form.Text = 'Vault Editor v2 - mubolarg MuEMU 1.04.05'
$form.Size = New-Object System.Drawing.Size(1100, 700)
$form.StartPosition = 'CenterScreen'

# --- LEFT: characters list ---
$lblChars = New-Object System.Windows.Forms.Label
$lblChars.Text = 'Characters:'
$lblChars.Location = New-Object System.Drawing.Point(10, 10); $lblChars.Size = New-Object System.Drawing.Size(200, 20)
$listChars = New-Object System.Windows.Forms.ListBox
$listChars.Location = New-Object System.Drawing.Point(10, 32); $listChars.Size = New-Object System.Drawing.Size(260, 580)
$listChars.Font = New-Object System.Drawing.Font('Consolas', 9)
$btnRefresh = New-Object System.Windows.Forms.Button
$btnRefresh.Text = 'Refresh chars'
$btnRefresh.Location = New-Object System.Drawing.Point(10, 620); $btnRefresh.Size = New-Object System.Drawing.Size(260, 28)

# --- CENTER: vault contents ---
$lblInfo = New-Object System.Windows.Forms.Label
$lblInfo.Text = 'Selecciona un char a la izquierda'
$lblInfo.Location = New-Object System.Drawing.Point(285, 10); $lblInfo.Size = New-Object System.Drawing.Size(500, 22)
$lblInfo.Font = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)
$lblVault = New-Object System.Windows.Forms.Label
$lblVault.Text = 'Vault (click derecho en item para borrar):'
$lblVault.Location = New-Object System.Drawing.Point(285, 35); $lblVault.Size = New-Object System.Drawing.Size(400, 20)
$listVault = New-Object System.Windows.Forms.ListBox
$listVault.Location = New-Object System.Drawing.Point(285, 58); $listVault.Size = New-Object System.Drawing.Size(500, 510)
$listVault.Font = New-Object System.Drawing.Font('Consolas', 9)
# Context menu
$cmenu = New-Object System.Windows.Forms.ContextMenuStrip
$mDel = $cmenu.Items.Add('Borrar slot')
$listVault.ContextMenuStrip = $cmenu

$btnClear = New-Object System.Windows.Forms.Button
$btnClear.Text = 'Vaciar vault'
$btnClear.Location = New-Object System.Drawing.Point(285, 575); $btnClear.Size = New-Object System.Drawing.Size(130, 28)
$btnClear.BackColor = [System.Drawing.Color]::MistyRose
$btnSave = New-Object System.Windows.Forms.Button
$btnSave.Text = 'Guardar a DB'
$btnSave.Location = New-Object System.Drawing.Point(425, 575); $btnSave.Size = New-Object System.Drawing.Size(180, 28)
$btnSave.BackColor = [System.Drawing.Color]::PaleGreen
$btnSave.Font = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
$btnReload = New-Object System.Windows.Forms.Button
$btnReload.Text = 'Recargar (descartar)'
$btnReload.Location = New-Object System.Drawing.Point(615, 575); $btnReload.Size = New-Object System.Drawing.Size(170, 28)

# --- RIGHT: item picker ---
$gbPicker = New-Object System.Windows.Forms.GroupBox
$gbPicker.Text = 'Agregar item'
$gbPicker.Location = New-Object System.Drawing.Point(800, 10); $gbPicker.Size = New-Object System.Drawing.Size(280, 600)

$y = 25
$lblCat = New-Object System.Windows.Forms.Label
$lblCat.Text = 'Categoria:'; $lblCat.Location = New-Object System.Drawing.Point(10, $y); $lblCat.Size = New-Object System.Drawing.Size(100, 20)
$cmbCat = New-Object System.Windows.Forms.ComboBox
$cmbCat.Location = New-Object System.Drawing.Point(110, ($y-2)); $cmbCat.Size = New-Object System.Drawing.Size(155, 22); $cmbCat.DropDownStyle = 'DropDownList'
foreach ($t in $script:TypeNames.Keys | Sort-Object) {
    if ($script:ItemCatalog.ContainsKey($t)) {
        [void]$cmbCat.Items.Add("$t - $($script:TypeNames[$t])")
    }
}

$y += 30
$lblItem = New-Object System.Windows.Forms.Label
$lblItem.Text = 'Item:'; $lblItem.Location = New-Object System.Drawing.Point(10, $y); $lblItem.Size = New-Object System.Drawing.Size(100, 20)
$cmbItem = New-Object System.Windows.Forms.ComboBox
$cmbItem.Location = New-Object System.Drawing.Point(10, ($y+22)); $cmbItem.Size = New-Object System.Drawing.Size(255, 22); $cmbItem.DropDownStyle = 'DropDownList'

$y += 60
$lblLevel = New-Object System.Windows.Forms.Label
$lblLevel.Text = 'Nivel:'; $lblLevel.Location = New-Object System.Drawing.Point(10, $y); $lblLevel.Size = New-Object System.Drawing.Size(60, 20)
$numLevel = New-Object System.Windows.Forms.NumericUpDown
$numLevel.Location = New-Object System.Drawing.Point(70, ($y-2)); $numLevel.Size = New-Object System.Drawing.Size(60, 22)
$numLevel.Minimum = 0; $numLevel.Maximum = 15; $numLevel.Value = 13
$lblOpt = New-Object System.Windows.Forms.Label
$lblOpt.Text = 'Option:'; $lblOpt.Location = New-Object System.Drawing.Point(150, $y); $lblOpt.Size = New-Object System.Drawing.Size(60, 20)
$cmbOpt = New-Object System.Windows.Forms.ComboBox
$cmbOpt.Location = New-Object System.Drawing.Point(210, ($y-2)); $cmbOpt.Size = New-Object System.Drawing.Size(55, 22); $cmbOpt.DropDownStyle = 'DropDownList'
foreach ($o in '+0','+4','+8','+12') { [void]$cmbOpt.Items.Add($o) }
$cmbOpt.SelectedIndex = 3

$y += 30
$chkLuck = New-Object System.Windows.Forms.CheckBox
$chkLuck.Text = 'Luck'; $chkLuck.Location = New-Object System.Drawing.Point(10, $y); $chkLuck.Size = New-Object System.Drawing.Size(70, 22); $chkLuck.Checked = $true
$chkSkill = New-Object System.Windows.Forms.CheckBox
$chkSkill.Text = 'Skill'; $chkSkill.Location = New-Object System.Drawing.Point(90, $y); $chkSkill.Size = New-Object System.Drawing.Size(70, 22); $chkSkill.Checked = $true

$y += 30
$lblExc = New-Object System.Windows.Forms.Label
$lblExc.Text = 'Excellent options:'; $lblExc.Location = New-Object System.Drawing.Point(10, $y); $lblExc.Size = New-Object System.Drawing.Size(150, 20)
$y += 22
$chkExc = @()
for ($i = 0; $i -lt 6; $i++) {
    $c = New-Object System.Windows.Forms.CheckBox
    $c.Text = "Exc${($i+1)}"; $c.Location = New-Object System.Drawing.Point((10 + ($i % 3) * 90), ($y + ([Math]::Floor($i/3)) * 22)); $c.Size = New-Object System.Drawing.Size(85, 22)
    $chkExc += $c
}

$y += 60
$lblDur = New-Object System.Windows.Forms.Label
$lblDur.Text = 'Durability:'; $lblDur.Location = New-Object System.Drawing.Point(10, $y); $lblDur.Size = New-Object System.Drawing.Size(80, 20)
$numDur = New-Object System.Windows.Forms.NumericUpDown
$numDur.Location = New-Object System.Drawing.Point(90, ($y-2)); $numDur.Size = New-Object System.Drawing.Size(60, 22)
$numDur.Minimum = 0; $numDur.Maximum = 255; $numDur.Value = 100

$y += 30
$lblSlot = New-Object System.Windows.Forms.Label
$lblSlot.Text = 'Slot (-1=auto):'; $lblSlot.Location = New-Object System.Drawing.Point(10, $y); $lblSlot.Size = New-Object System.Drawing.Size(100, 20)
$numSlot = New-Object System.Windows.Forms.NumericUpDown
$numSlot.Location = New-Object System.Drawing.Point(110, ($y-2)); $numSlot.Size = New-Object System.Drawing.Size(60, 22)
$numSlot.Minimum = -1; $numSlot.Maximum = 119; $numSlot.Value = -1
$lblQty = New-Object System.Windows.Forms.Label
$lblQty.Text = 'Qty:'; $lblQty.Location = New-Object System.Drawing.Point(180, $y); $lblQty.Size = New-Object System.Drawing.Size(30, 20)
$numQty = New-Object System.Windows.Forms.NumericUpDown
$numQty.Location = New-Object System.Drawing.Point(210, ($y-2)); $numQty.Size = New-Object System.Drawing.Size(55, 22)
$numQty.Minimum = 1; $numQty.Maximum = 120; $numQty.Value = 1

$y += 35
$btnAdd = New-Object System.Windows.Forms.Button
$btnAdd.Text = 'Agregar al vault'
$btnAdd.Location = New-Object System.Drawing.Point(10, $y); $btnAdd.Size = New-Object System.Drawing.Size(255, 32)
$btnAdd.BackColor = [System.Drawing.Color]::LightBlue
$btnAdd.Font = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)

$y += 40
$lblHint = New-Object System.Windows.Forms.Label
$lblHint.Text = "Tip: nivel 13 + Luck + Skill + Op +12 + 2-3 Exc = item top-tier para evento"
$lblHint.Location = New-Object System.Drawing.Point(10, $y); $lblHint.Size = New-Object System.Drawing.Size(255, 50)
$lblHint.ForeColor = [System.Drawing.Color]::Gray
$lblHint.Font = New-Object System.Drawing.Font('Segoe UI', 8)

$gbPicker.Controls.AddRange(@(
    $lblCat, $cmbCat, $lblItem, $cmbItem,
    $lblLevel, $numLevel, $lblOpt, $cmbOpt,
    $chkLuck, $chkSkill, $lblExc
) + $chkExc + @($lblDur, $numDur, $lblSlot, $numSlot, $lblQty, $numQty, $btnAdd, $lblHint))

$status = New-Object System.Windows.Forms.Label
$status.Text = 'Listo'
$status.Location = New-Object System.Drawing.Point(285, 615); $status.Size = New-Object System.Drawing.Size(795, 22)
$status.BorderStyle = 'FixedSingle'

$form.Controls.AddRange(@(
    $lblChars, $listChars, $btnRefresh,
    $lblInfo, $lblVault, $listVault,
    $btnClear, $btnSave, $btnReload,
    $gbPicker, $status
))

# ============================================================
# Logic
# ============================================================

function Refresh-Characters {
    $listChars.Items.Clear()
    try {
        $chars = Get-Characters
        $classMap = @{ 0='DW'; 1='SM'; 2='GM'; 16='DK'; 17='BK'; 18='BM'; 32='ME'; 48='EL'; 64='MG'; 80='DL' }
        foreach ($c in $chars) {
            $cls = if ($classMap.ContainsKey($c.Class)) { $classMap[$c.Class] } else { "?$($c.Class)" }
            $line = "{0,-10} {1,-12} {2,-3} L{3,4}" -f $c.AccountID, $c.Name, $cls, $c.Level
            [void]$listChars.Items.Add($line)
        }
        $status.Text = "$($chars.Count) chars cargados"
    } catch {
        $status.Text = "Err: $($_.Exception.Message)"
    }
}

function Refresh-VaultDisplay {
    $listVault.Items.Clear()
    if (-not $script:CurrentBlob) { return }
    $slots = Read-VaultSlots -Blob $script:CurrentBlob
    foreach ($s in $slots) {
        $flags = @()
        if ($s.Skill) { $flags += 'S' }
        if ($s.Luck)  { $flags += 'L' }
        if ($s.Opt -gt 0) { $flags += "+$($s.Opt*4)" }
        if ($s.Exc -gt 0) { $flags += "exc=0x{0:X2}" -f $s.Exc }
        $flagStr = if ($flags) { $flags -join ' ' } else { '-' }
        $line = "[{0,3}] +{1,2}  {2,-30} {3}" -f $s.Slot, $s.Level, $s.Name, $flagStr
        [void]$listVault.Items.Add($line)
    }
    $lblInfo.Text = "$($script:CurrentAccount) / $($script:CurrentChar)  -  $($slots.Count)/120 ocupados"
}

function Load-VaultForSelected {
    $sel = $listChars.SelectedIndex
    if ($sel -lt 0) { return }
    $line = $listChars.Items[$sel]
    $acc = ($line -split '\s+')[0]
    $name = ($line -split '\s+')[1]
    $script:CurrentAccount = $acc
    $script:CurrentChar = $name
    try {
        $blob = Get-VaultBlob -AccountID $acc
        if (-not $blob) {
            $status.Text = "X no hay vault para $acc"; $script:CurrentBlob = $null
        } else {
            $script:CurrentBlob = New-Object byte[] 1920
            [Array]::Copy($blob, $script:CurrentBlob, 1920)
            $status.Text = "Vault de $acc cargado"
        }
        Refresh-VaultDisplay
    } catch { $status.Text = "Err: $($_.Exception.Message)" }
}

function Update-ItemDropdown {
    $cmbItem.Items.Clear()
    $sel = $cmbCat.SelectedItem
    if (-not $sel) { return }
    $type = [int](($sel -split ' - ')[0])
    if (-not $script:ItemCatalog.ContainsKey($type)) { return }
    foreach ($it in $script:ItemCatalog[$type]) {
        [void]$cmbItem.Items.Add(("{0,3}  {1}" -f $it.Index, $it.Name))
    }
    if ($cmbItem.Items.Count -gt 0) { $cmbItem.SelectedIndex = 0 }
    # Habilitar/desh Skill segun categoria
    $isArmor = $type -ge 7 -and $type -le 12
    $chkSkill.Enabled = -not $isArmor
    if ($isArmor) { $chkSkill.Checked = $false }
}

function Get-SelectedItemDef {
    $sel = $cmbCat.SelectedItem
    if (-not $sel) { return $null }
    $type = [int](($sel -split ' - ')[0])
    if (-not $cmbItem.SelectedItem) { return $null }
    # El item del dropdown viene con padding "  N  Name" - usar el SelectedIndex en su lugar
    $itemList = $script:ItemCatalog[$type]
    if (-not $itemList -or $cmbItem.SelectedIndex -lt 0 -or $cmbItem.SelectedIndex -ge $itemList.Count) { return $null }
    $def = $itemList[$cmbItem.SelectedIndex]
    return @{ Type = $type; Def = $def }
}

# Events
$btnRefresh.Add_Click({ Refresh-Characters })
$listChars.Add_SelectedIndexChanged({ Load-VaultForSelected })
$cmbCat.Add_SelectedIndexChanged({ Update-ItemDropdown })

$btnAdd.Add_Click({
    if (-not $script:CurrentBlob) { $status.Text = 'Selecciona un char primero'; return }
    $sel = Get-SelectedItemDef
    if (-not $sel) { $status.Text = 'Elegi item del dropdown'; return }
    $type = $sel.Type; $def = $sel.Def
    $excMask = 0
    for ($i = 0; $i -lt 6; $i++) { if ($chkExc[$i].Checked) { $excMask = $excMask -bor (1 -shl $i) } }
    $option = $cmbOpt.SelectedIndex
    $level = [int]$numLevel.Value
    $luck = [bool]$chkLuck.Checked
    $skill = [bool]$chkSkill.Checked -and ($def.Skill -ne 0)
    $dur = [int]$numDur.Value
    $qty = [int]$numQty.Value
    $startSlot = [int]$numSlot.Value
    $isMisc = [bool]$def.IsMisc

    $added = 0
    for ($q = 0; $q -lt $qty; $q++) {
        $slot = if ($q -eq 0 -and $startSlot -ge 0) { $startSlot } else { Find-FreeSlot -Blob $script:CurrentBlob }
        if ($slot -lt 0) { $status.Text = "Vault lleno - agrego $added items"; break }
        $bytes = New-ItemBytes -Type $type -Index $def.Index -Level $level -Luck $luck -Skill $skill -Option $option -Excellent $excMask -Durability $dur -IsMisc $isMisc
        Place-ItemInBlob -Blob $script:CurrentBlob -Slot $slot -Item $bytes
        $added++
    }
    Refresh-VaultDisplay
    $status.Text = "Agregado $added x $($def.Name) (en memoria - apreta Guardar)"
})

$mDel.add_Click({
    if (-not $script:CurrentBlob) { return }
    $sel = $listVault.SelectedIndex
    if ($sel -lt 0) { return }
    $line = $listVault.Items[$sel]
    if ($line -match '^\[\s*(\d+)\]') {
        $slotNum = [int]$matches[1]
        Clear-SlotInBlob -Blob $script:CurrentBlob -Slot $slotNum
        Refresh-VaultDisplay
        $status.Text = "Slot $slotNum borrado (en memoria)"
    }
})

$btnClear.Add_Click({
    if (-not $script:CurrentBlob) { return }
    $c = [System.Windows.Forms.MessageBox]::Show('Vaciar vault completo?', 'Confirmar', 'YesNo', 'Warning')
    if ($c -ne 'Yes') { return }
    for ($i = 0; $i -lt 1920; $i++) { $script:CurrentBlob[$i] = 0xFF }
    Refresh-VaultDisplay
    $status.Text = 'Vault vaciado en memoria'
})

$btnSave.Add_Click({
    if (-not $script:CurrentBlob -or -not $script:CurrentAccount) { return }
    $c = [System.Windows.Forms.MessageBox]::Show("Guardar al vault de $($script:CurrentAccount)?`n(Char debe estar deslogueado)", 'Confirmar', 'YesNo', 'Question')
    if ($c -ne 'Yes') { return }
    try {
        $n = Save-VaultBlob -AccountID $script:CurrentAccount -Bytes $script:CurrentBlob
        $status.Text = "Guardado OK (filas: $n). Backup en vault-backup/"
    } catch {
        $status.Text = "Err: $($_.Exception.Message)"
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Error', 'OK', 'Error') | Out-Null
    }
})

$btnReload.Add_Click({ Load-VaultForSelected })

$form.Add_Shown({
    Refresh-Characters
    if ($cmbCat.Items.Count -gt 0) { $cmbCat.SelectedIndex = 0; Update-ItemDropdown }
})

[void]$form.ShowDialog()
