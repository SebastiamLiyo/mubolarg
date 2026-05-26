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
        [int] $Option = 0,           # 0-7 (mapea +0/+4/+8/+12/+16/+20/+24/+28)
        [int] $Excellent = 0,        # Valor literal del PDF: 0/7/11/21/40
        [int] $Durability = 255,
        [bool] $IsMisc = $false
    )
    $b = New-Object byte[] 16
    $b[0] = [byte]($Index -band 0xFF)
    # Byte 1: bits 0-1 = option low (0-3); bit 2 = luck; bits 3-6 = level; bit 7 = skill
    $b1 = (($Level -band 0x0F) -shl 3) -bor (($Option -band 0x03))
    if ($Luck)  { $b1 = $b1 -bor 0x04 }
    if ($Skill) { $b1 = $b1 -bor 0x80 }
    $b[1] = [byte]$b1
    $b[2] = [byte]($Durability -band 0xFF)
    # Byte 3: Excellent value literal (del PDF: 0,7,11,21,40)
    $b[3] = [byte]($Excellent -band 0xFF)
    for ($i = 4; $i -le 8; $i++) { $b[$i] = 0x00 }
    $b[9] = [byte]((($Type -band 0x0F) -shl 4) -bor (($Index -shr 8) -band 0x0F))
    if ($IsMisc) {
        for ($i = 10; $i -le 15; $i++) { $b[$i] = 0x00 }
    } else {
        $b[10] = 0xFF; $b[11] = 0xFF; $b[12] = 0xFF; $b[13] = 0xFF
        $b[14] = [byte]$script:rng.Next(1, 256)
        $b[15] = [byte]$script:rng.Next(1, 256)
    }
    # Option3 bit (extiende option a +16/+20/+24/+28): bit 7 de byte 7
    # Si Option >= 4, prendemos el bit
    if ($Option -ge 4) { $b[7] = [byte]($b[7] -bor 0x80) }
    return ,$b
}

# Catálogo de presets de SET completos basados en el PDF de comandos GM
$script:SetPresets = @{
    'DK/BK Dark Phoenix + Wings Dragon' = @{
        Pieces = @(
            @{ T=7;  I=17 }, @{ T=8;  I=17 }, @{ T=9;  I=17 }, @{ T=10; I=17 }, @{ T=11; I=17 }
        )
        Weapon = @{ T=0; I=22; Name='Bone Blade' }
        Wings  = @{ T=12; I=5;  Name='Wings of Dragon' }
        Excellent = 11
    }
    'DK/BK Great Dragon + Wings Dragon' = @{
        Pieces = @(
            @{ T=7;  I=21 }, @{ T=8;  I=21 }, @{ T=9;  I=21 }, @{ T=10; I=21 }, @{ T=11; I=21 }
        )
        Weapon = @{ T=0; I=20; Name='Knight Blade' }
        Wings  = @{ T=12; I=5; Name='Wings of Dragon' }
        Excellent = 11
    }
    'DK Black Dragon S1 + Wings Dragon' = @{
        Pieces = @(
            @{ T=7;  I=16 }, @{ T=8;  I=16 }, @{ T=9;  I=16 }, @{ T=10; I=16 }, @{ T=11; I=16 }
        )
        Weapon = @{ T=0; I=19; Name='Sword of Archangel' }
        Wings  = @{ T=12; I=5; Name='Wings of Dragon' }
        Excellent = 11
    }
    'DW Grand Soul + Wings Soul' = @{
        Pieces = @(
            @{ T=7;  I=18 }, @{ T=8;  I=18 }, @{ T=9;  I=18 }, @{ T=10; I=18 }, @{ T=11; I=18 }
        )
        Weapon = @{ T=5; I=9; Name='Dragon Soul Staff' }
        Wings  = @{ T=12; I=4; Name='Wings of Soul' }
        Excellent = 11
    }
    'DW Venon Mist + Wings Soul' = @{
        Pieces = @(
            @{ T=7;  I=30 }, @{ T=8;  I=30 }, @{ T=9;  I=30 }, @{ T=10; I=30 }, @{ T=11; I=30 }
        )
        Weapon = @{ T=5; I=12; Name='Grand Viper Staff' }
        Wings  = @{ T=12; I=4; Name='Wings of Soul' }
        Excellent = 11
    }
    'ELF Iris + Wings Spirits' = @{
        Pieces = @(
            @{ T=7;  I=36 }, @{ T=8;  I=36 }, @{ T=9;  I=36 }, @{ T=10; I=36 }, @{ T=11; I=36 }
        )
        Weapon = @{ T=4; I=22; Name='Albatross Bow' }
        Wings  = @{ T=12; I=3; Name='Wings of Spirits' }
        Excellent = 11
    }
    'MG Valiant + Wings Darkness' = @{
        Pieces = @(
            @{ T=8;  I=37 }, @{ T=9;  I=37 }, @{ T=10; I=37 }, @{ T=11; I=37 }
        )
        Weapon = @{ T=0; I=25; Name='Sword Dancer' }
        Wings  = @{ T=12; I=6; Name='Wings of Darkness' }
        Excellent = 11
    }
    'DL Adamantine + Cape of Lord' = @{
        Pieces = @(
            @{ T=7;  I=26 }, @{ T=8;  I=26 }, @{ T=9;  I=26 }, @{ T=10; I=26 }, @{ T=11; I=26 }
        )
        Weapon = @{ T=2; I=10; Name='Great Scepter' }
        Wings  = @{ T=13; I=30; Name='Cape of Lord' }
        Excellent = 11
    }
}

# Presets de Excellent (valor literal del PDF)
$script:ExcellentPresets = @(
    @{ Value = 0;  Label = '0  - Sin Excellent' }
    @{ Value = 7;  Label = '7  - Armor Reflejo (luck+luck+def28+reflejo+rango+zen)' }
    @{ Value = 11; Label = '11 - Armor Reduce (luck+luck+def28+reduce+rango+zen)' }
    @{ Value = 21; Label = '21 - Wings (hp+ignore+vel+luck+luck+dmg)' }
    @{ Value = 40; Label = '40 - Weapon (skill+luck+luck+dmg28+excDmg+aumDmg)' }
)

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

# Detectar columnas disponibles en Character (varia por fork de MuEMU)
$script:CharColumns = $null
function Get-CharColumns {
    if ($script:CharColumns) { return $script:CharColumns }
    $cn = Open-DbConnection
    $cmd = $cn.CreateCommand()
    $cmd.CommandText = "SELECT COLUMN_NAME FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_NAME='Character'"
    $rd = $cmd.ExecuteReader()
    $cols = @()
    while ($rd.Read()) { $cols += [string]$rd[0] }
    $rd.Close(); $cn.Close()
    $script:CharColumns = $cols
    return $cols
}

function Get-CharFull {
    param([string] $Name)
    $cn = Open-DbConnection
    $cmd = $cn.CreateCommand()
    $cmd.CommandText = "SELECT * FROM Character WHERE Name=@n"
    [void]$cmd.Parameters.AddWithValue('@n', $Name)
    $rd = $cmd.ExecuteReader()
    $row = @{}
    if ($rd.Read()) {
        for ($i = 0; $i -lt $rd.FieldCount; $i++) {
            $colName = $rd.GetName($i)
            $val = $rd.GetValue($i)
            if ($val -isnot [DBNull]) { $row[$colName] = $val } else { $row[$colName] = $null }
        }
    }
    $rd.Close(); $cn.Close()
    return $row
}

function Set-CharField {
    param([string] $Name, [string] $Column, $Value)
    $cn = Open-DbConnection
    $up = $cn.CreateCommand()
    # Validar que la columna exista (whitelist contra SQL injection)
    $cols = Get-CharColumns
    if ($Column -notin $cols) { $cn.Close(); throw "Columna '$Column' no existe en Character" }
    $up.CommandText = "UPDATE Character SET [$Column] = @v WHERE Name=@n"
    [void]$up.Parameters.AddWithValue('@v', $Value)
    [void]$up.Parameters.AddWithValue('@n', $Name)
    $n = $up.ExecuteNonQuery()
    $cn.Close()
    return $n
}

function Set-CharFields {
    param([string] $Name, [hashtable] $Fields)
    $cols = Get-CharColumns
    $cn = Open-DbConnection
    $up = $cn.CreateCommand()
    $setParts = @()
    $i = 0
    foreach ($k in $Fields.Keys) {
        if ($k -notin $cols) { continue }
        $setParts += "[$k]=@p$i"
        [void]$up.Parameters.AddWithValue("@p$i", $Fields[$k])
        $i++
    }
    if ($setParts.Count -eq 0) { $cn.Close(); return 0 }
    $up.CommandText = "UPDATE Character SET " + ($setParts -join ', ') + " WHERE Name=@n"
    [void]$up.Parameters.AddWithValue('@n', $Name)
    $n = $up.ExecuteNonQuery()
    $cn.Close()
    return $n
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
# Inventory helpers (108 slots * 16 bytes = 1728)
# ============================================================

function Get-InventoryBlob {
    param([string] $CharName)
    $cn = Open-DbConnection
    $cmd = $cn.CreateCommand()
    $cmd.CommandText = "SELECT Inventory FROM Character WHERE Name=@n"
    [void]$cmd.Parameters.AddWithValue('@n', $CharName)
    $blob = $cmd.ExecuteScalar()
    $cn.Close()
    if (-not $blob) { return $null }
    return $blob
}

function Save-InventoryBlob {
    param([string] $CharName, [byte[]] $Bytes)
    if ($Bytes.Length -ne 1728) { throw "Inventory blob debe ser 1728 bytes, recibi $($Bytes.Length)" }
    $appRoot = Get-AppRoot
    $clientRoot = if ((Split-Path -Leaf $appRoot) -eq '_admin') { Split-Path -Parent $appRoot } else { $appRoot }
    $backupDir = Join-Path $clientRoot 'vault-backup'
    if (-not (Test-Path $backupDir)) { New-Item -ItemType Directory -Path $backupDir -Force | Out-Null }
    $current = Get-InventoryBlob -CharName $CharName
    if ($current) {
        $bkPath = Join-Path $backupDir ("$CharName-inv-" + (Get-Date -Format 'yyyyMMdd-HHmmss') + '-editor.bin')
        [IO.File]::WriteAllBytes($bkPath, $current)
    }
    $cn = Open-DbConnection
    $up = $cn.CreateCommand()
    $up.CommandText = "UPDATE Character SET Inventory=@b WHERE Name=@n"
    $p = $up.Parameters.Add('@b', [System.Data.SqlDbType]::VarBinary, 1728); $p.Value = $Bytes
    [void]$up.Parameters.AddWithValue('@n', $CharName)
    $n = $up.ExecuteNonQuery()
    $cn.Close()
    return $n
}

# Nombre humano del slot de inventory (0-11 = equipment slots)
$script:EquipSlotNames = @{
    0='RightHand'; 1='LeftHand'; 2='Helm'; 3='Armor'; 4='Pants'
    5='Gloves'; 6='Boots'; 7='Wings'; 8='Pet'; 9='Pendant'
    10='Ring1'; 11='Ring2'
}

function Get-SlotLabel {
    param([int] $Slot, [bool] $IsInventory)
    if (-not $IsInventory) { return "{0,3}" -f $Slot }
    if ($script:EquipSlotNames.ContainsKey($Slot)) { return "{0,3} [{1}]" -f $Slot, $script:EquipSlotNames[$Slot] }
    if ($Slot -ge 12 -and $Slot -le 75) { return "{0,3} [Inv]" -f $Slot }
    if ($Slot -ge 76 -and $Slot -le 107) { return "{0,3} [Pshop]" -f $Slot }
    return "{0,3}" -f $Slot
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
    param([byte[]] $Blob, [int] $SlotCount = 120)
    $slots = @()
    for ($s = 0; $s -lt $SlotCount; $s++) {
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
    param([byte[]] $Blob, [int] $SlotCount = 120, [int] $StartFrom = 0)
    for ($s = $StartFrom; $s -lt $SlotCount; $s++) {
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
$script:Mode = 'Vault'   # 'Vault' o 'Inventory'

# ============================================================
# GUI
# ============================================================

$form = New-Object System.Windows.Forms.Form
$form.Text = 'Vault Editor v2 - mubolarg MuEMU 1.04.05'
$form.Size = New-Object System.Drawing.Size(1100, 800)
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
$btnRefresh.Location = New-Object System.Drawing.Point(10, 590); $btnRefresh.Size = New-Object System.Drawing.Size(260, 26)

$btnEditChar = New-Object System.Windows.Forms.Button
$btnEditChar.Text = 'Editar character (stats, clase, nombre)'
$btnEditChar.Location = New-Object System.Drawing.Point(10, 622); $btnEditChar.Size = New-Object System.Drawing.Size(260, 32)
$btnEditChar.BackColor = [System.Drawing.Color]::LightGoldenrodYellow
$btnEditChar.Font = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)

# --- CENTER: vault contents ---
$lblInfo = New-Object System.Windows.Forms.Label
$lblInfo.Text = 'Selecciona un char a la izquierda'
$lblInfo.Location = New-Object System.Drawing.Point(285, 10); $lblInfo.Size = New-Object System.Drawing.Size(500, 22)
$lblInfo.Font = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)
# Mode toggle (Vault vs Inventory)
$rbVault = New-Object System.Windows.Forms.RadioButton
$rbVault.Text = 'Vault (120 slots)'; $rbVault.Location = New-Object System.Drawing.Point(285, 33); $rbVault.Size = New-Object System.Drawing.Size(140, 22); $rbVault.Checked = $true
$rbInv = New-Object System.Windows.Forms.RadioButton
$rbInv.Text = 'Inventory (108 slots)'; $rbInv.Location = New-Object System.Drawing.Point(430, 33); $rbInv.Size = New-Object System.Drawing.Size(150, 22)

$lblVault = New-Object System.Windows.Forms.Label
$lblVault.Text = 'Vault (click derecho en item para borrar):'
$lblVault.Location = New-Object System.Drawing.Point(580, 35); $lblVault.Size = New-Object System.Drawing.Size(220, 20)
$lblVault.Font = New-Object System.Drawing.Font('Segoe UI', 8)
$lblVault.ForeColor = [System.Drawing.Color]::Gray
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
$gbPicker.Text = 'Agregar item / SET'
$gbPicker.Location = New-Object System.Drawing.Point(800, 10); $gbPicker.Size = New-Object System.Drawing.Size(280, 720)

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
foreach ($o in '+0','+4','+8','+12','+16','+20','+24','+28') { [void]$cmbOpt.Items.Add($o) }
$cmbOpt.SelectedIndex = 7   # +28 (option=7 del PDF)

$y += 30
$chkLuck = New-Object System.Windows.Forms.CheckBox
$chkLuck.Text = 'Luck'; $chkLuck.Location = New-Object System.Drawing.Point(10, $y); $chkLuck.Size = New-Object System.Drawing.Size(70, 22); $chkLuck.Checked = $true
$chkSkill = New-Object System.Windows.Forms.CheckBox
$chkSkill.Text = 'Skill'; $chkSkill.Location = New-Object System.Drawing.Point(90, $y); $chkSkill.Size = New-Object System.Drawing.Size(70, 22); $chkSkill.Checked = $true

$y += 30
$lblExc = New-Object System.Windows.Forms.Label
$lblExc.Text = 'Excellent (preset PDF):'; $lblExc.Location = New-Object System.Drawing.Point(10, $y); $lblExc.Size = New-Object System.Drawing.Size(180, 20)
$y += 22
$cmbExc = New-Object System.Windows.Forms.ComboBox
$cmbExc.Location = New-Object System.Drawing.Point(10, $y); $cmbExc.Size = New-Object System.Drawing.Size(255, 22); $cmbExc.DropDownStyle = 'DropDownList'
foreach ($e in $script:ExcellentPresets) { [void]$cmbExc.Items.Add($e.Label) }
$cmbExc.SelectedIndex = 2   # "11 - Armor Reduce" default
$chkExc = @()   # placeholder por compat con codigo viejo

$y += 30
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
$lblSetGen = New-Object System.Windows.Forms.Label
$lblSetGen.Text = '--- SET COMPLETO (+13 S L +28 exc) ---'
$lblSetGen.Location = New-Object System.Drawing.Point(10, $y); $lblSetGen.Size = New-Object System.Drawing.Size(255, 20)
$lblSetGen.Font = New-Object System.Drawing.Font('Segoe UI', 8, [System.Drawing.FontStyle]::Bold)
$lblSetGen.ForeColor = [System.Drawing.Color]::DarkGreen

$y += 22
$cmbSet = New-Object System.Windows.Forms.ComboBox
$cmbSet.Location = New-Object System.Drawing.Point(10, $y); $cmbSet.Size = New-Object System.Drawing.Size(255, 22); $cmbSet.DropDownStyle = 'DropDownList'
foreach ($k in $script:SetPresets.Keys | Sort-Object) { [void]$cmbSet.Items.Add($k) }
if ($cmbSet.Items.Count -gt 0) { $cmbSet.SelectedIndex = 0 }

$y += 28
$btnSet = New-Object System.Windows.Forms.Button
$btnSet.Text = 'Agregar SET completo al vault'
$btnSet.Location = New-Object System.Drawing.Point(10, $y); $btnSet.Size = New-Object System.Drawing.Size(255, 32)
$btnSet.BackColor = [System.Drawing.Color]::Khaki
$btnSet.Font = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)

$y += 40
$lblHint = New-Object System.Windows.Forms.Label
$lblHint.Text = "Tip: el dropdown de Excellent usa los valores reales del PDF GM (7/11/21/40). Right-click en item del vault para borrar SOLO ese slot."
$lblHint.Location = New-Object System.Drawing.Point(10, $y); $lblHint.Size = New-Object System.Drawing.Size(255, 60)
$lblHint.ForeColor = [System.Drawing.Color]::Gray
$lblHint.Font = New-Object System.Drawing.Font('Segoe UI', 8)

$gbPicker.Controls.AddRange(@(
    $lblCat, $cmbCat, $lblItem, $cmbItem,
    $lblLevel, $numLevel, $lblOpt, $cmbOpt,
    $chkLuck, $chkSkill, $lblExc, $cmbExc,
    $lblDur, $numDur, $lblSlot, $numSlot, $lblQty, $numQty,
    $btnAdd,
    $lblSetGen, $cmbSet, $btnSet,
    $lblHint
))

$status = New-Object System.Windows.Forms.Label
$status.Text = 'Listo'
$status.Location = New-Object System.Drawing.Point(285, 615); $status.Size = New-Object System.Drawing.Size(795, 22)
$status.BorderStyle = 'FixedSingle'

$form.Controls.AddRange(@(
    $lblChars, $listChars, $btnRefresh, $btnEditChar,
    $lblInfo, $rbVault, $rbInv, $lblVault, $listVault,
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

function Get-SlotCount { if ($script:Mode -eq 'Inventory') { 108 } else { 120 } }
function Get-BlobSize  { if ($script:Mode -eq 'Inventory') { 1728 } else { 1920 } }

function Refresh-VaultDisplay {
    $listVault.Items.Clear()
    if (-not $script:CurrentBlob) { return }
    $count = Get-SlotCount
    $slots = Read-VaultSlots -Blob $script:CurrentBlob -SlotCount $count
    foreach ($s in $slots) {
        $flags = @()
        if ($s.Skill) { $flags += 'S' }
        if ($s.Luck)  { $flags += 'L' }
        if ($s.Opt -gt 0) { $flags += "+$($s.Opt*4)" }
        if ($s.Exc -gt 0) { $flags += "exc=0x{0:X2}" -f $s.Exc }
        $flagStr = if ($flags) { $flags -join ' ' } else { '-' }
        $slotLabel = Get-SlotLabel -Slot $s.Slot -IsInventory ($script:Mode -eq 'Inventory')
        $line = "[$slotLabel] +{0,2}  {1,-28} {2}" -f $s.Level, $s.Name, $flagStr
        [void]$listVault.Items.Add($line)
    }
    $modeTag = if ($script:Mode -eq 'Inventory') { 'INV' } else { 'VAULT' }
    $lblInfo.Text = "[$modeTag] $($script:CurrentAccount) / $($script:CurrentChar)  -  $($slots.Count)/$count ocupados"
    # Ajustar limite del slot input
    $numSlot.Maximum = $count - 1
}

function Load-DataForSelected {
    $sel = $listChars.SelectedIndex
    if ($sel -lt 0) { return }
    $line = $listChars.Items[$sel]
    $acc = ($line -split '\s+')[0]
    $name = ($line -split '\s+')[1]
    $script:CurrentAccount = $acc
    $script:CurrentChar = $name
    try {
        if ($script:Mode -eq 'Inventory') {
            $blob = Get-InventoryBlob -CharName $name
            $size = 1728
            $tag = "inventory de $name"
        } else {
            $blob = Get-VaultBlob -AccountID $acc
            $size = 1920
            $tag = "vault de $acc"
        }
        if (-not $blob) {
            $status.Text = "X no hay $tag"; $script:CurrentBlob = $null
        } else {
            $script:CurrentBlob = New-Object byte[] $size
            [Array]::Copy($blob, $script:CurrentBlob, $size)
            $status.Text = "$tag cargado"
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
$listChars.Add_SelectedIndexChanged({ Load-DataForSelected })
$cmbCat.Add_SelectedIndexChanged({ Update-ItemDropdown })
$rbVault.Add_CheckedChanged({ if ($rbVault.Checked) { $script:Mode='Vault'; Load-DataForSelected } })
$rbInv.Add_CheckedChanged({ if ($rbInv.Checked) { $script:Mode='Inventory'; Load-DataForSelected } })

$btnAdd.Add_Click({
    if (-not $script:CurrentBlob) { $status.Text = 'Selecciona un char primero'; return }
    $sel = Get-SelectedItemDef
    if (-not $sel) { $status.Text = 'Elegi item del dropdown'; return }
    $type = $sel.Type; $def = $sel.Def
    # Excellent del preset (valor literal del PDF: 0/7/11/21/40)
    $excIdx = [int]$cmbExc.SelectedIndex
    if ($excIdx -lt 0) { $excIdx = 0 }
    $excMask = [int]$script:ExcellentPresets[$excIdx].Value
    $option = $cmbOpt.SelectedIndex   # 0-7 (mapea +0..+28)
    $level = [int]$numLevel.Value
    $luck = [bool]$chkLuck.Checked
    $skill = [bool]$chkSkill.Checked -and ($def.Skill -ne 0)
    $dur = [int]$numDur.Value
    $qty = [int]$numQty.Value
    $startSlot = [int]$numSlot.Value
    $isMisc = [bool]$def.IsMisc

    $added = 0
    $count = Get-SlotCount
    # En inventory mode, empezar a buscar slots libres desde 12 (no pisar equipment)
    $startSearch = if ($script:Mode -eq 'Inventory' -and $startSlot -lt 0) { 12 } else { 0 }
    for ($q = 0; $q -lt $qty; $q++) {
        $slot = if ($q -eq 0 -and $startSlot -ge 0) { $startSlot } else { Find-FreeSlot -Blob $script:CurrentBlob -SlotCount $count -StartFrom $startSearch }
        if ($slot -lt 0) { $status.Text = "Sin slots libres - agrego $added items"; break }
        $bytes = New-ItemBytes -Type $type -Index $def.Index -Level $level -Luck $luck -Skill $skill -Option $option -Excellent $excMask -Durability $dur -IsMisc $isMisc
        Place-ItemInBlob -Blob $script:CurrentBlob -Slot $slot -Item $bytes
        $added++
    }
    Refresh-VaultDisplay
    $status.Text = "Agregado $added x $($def.Name) (en memoria - apreta Guardar)"
})

$btnSet.Add_Click({
    if (-not $script:CurrentBlob) { $status.Text = 'Selecciona un char primero'; return }
    $setName = [string]$cmbSet.SelectedItem
    if (-not $setName) { return }
    $set = $script:SetPresets[$setName]
    $count = Get-SlotCount
    $startSearch = if ($script:Mode -eq 'Inventory') { 12 } else { 0 }
    $excArmor = [int]$set.Excellent
    $excWeapon = 40   # weapons siempre usan 40 (PDF)
    $added = 0

    # Piezas de set (armor)
    foreach ($p in $set.Pieces) {
        $slot = Find-FreeSlot -Blob $script:CurrentBlob -SlotCount $count -StartFrom $startSearch
        if ($slot -lt 0) { break }
        # Skill=false en armor (no aplica), Luck=true, Option=7 (+28), Exc=set.Excellent
        $bytes = New-ItemBytes -Type $p.T -Index $p.I -Level 13 -Luck $true -Skill $false -Option 7 -Excellent $excArmor -Durability 100 -IsMisc $false
        Place-ItemInBlob -Blob $script:CurrentBlob -Slot $slot -Item $bytes
        $added++
    }

    # Arma del set
    if ($set.Weapon) {
        $w = $set.Weapon
        $slot = Find-FreeSlot -Blob $script:CurrentBlob -SlotCount $count -StartFrom $startSearch
        if ($slot -ge 0) {
            # Skill=true para armas, Option=7 (+28), Exc=40
            $bytes = New-ItemBytes -Type $w.T -Index $w.I -Level 13 -Luck $true -Skill $true -Option 7 -Excellent $excWeapon -Durability 100 -IsMisc $false
            Place-ItemInBlob -Blob $script:CurrentBlob -Slot $slot -Item $bytes
            $added++
        }
    }

    # Wings del set (Exc=21 del PDF)
    if ($set.Wings) {
        $wg = $set.Wings
        $slot = Find-FreeSlot -Blob $script:CurrentBlob -SlotCount $count -StartFrom $startSearch
        if ($slot -ge 0) {
            $bytes = New-ItemBytes -Type $wg.T -Index $wg.I -Level 13 -Luck $true -Skill $false -Option 7 -Excellent 21 -Durability 200 -IsMisc $false
            Place-ItemInBlob -Blob $script:CurrentBlob -Slot $slot -Item $bytes
            $added++
        }
    }

    Refresh-VaultDisplay
    $status.Text = "SET '$setName' agregado ($added items: 5 armor + arma + alas - apreta Guardar)"
})

# Fix: cuando se abre el menu contextual, seleccionar el item bajo el cursor
$cmenu.Add_Opening({
    $pt = $listVault.PointToClient([System.Windows.Forms.Cursor]::Position)
    $idx = $listVault.IndexFromPoint($pt)
    if ($idx -ge 0) { $listVault.SelectedIndex = $idx }
})

$mDel.add_Click({
    if (-not $script:CurrentBlob) { return }
    $sel = $listVault.SelectedIndex
    if ($sel -lt 0) { $status.Text = 'No hay item seleccionado'; return }
    $line = $listVault.Items[$sel]
    if ($line -match '^\[\s*(\d+)') {
        $slotNum = [int]$matches[1]
        $maxSlot = (Get-SlotCount) - 1
        if ($slotNum -lt 0 -or $slotNum -gt $maxSlot) { $status.Text = "Slot invalido: $slotNum"; return }
        Clear-SlotInBlob -Blob $script:CurrentBlob -Slot $slotNum
        Refresh-VaultDisplay
        $status.Text = "Slot $slotNum borrado (solo este, en memoria)"
    } else {
        $status.Text = "No pude parsear slot del item: '$line'"
    }
})

$btnClear.Add_Click({
    if (-not $script:CurrentBlob) { return }
    $tag = if ($script:Mode -eq 'Inventory') { 'inventory (INCLUYE equipment!)' } else { 'vault' }
    $c = [System.Windows.Forms.MessageBox]::Show("Vaciar $tag completo?", 'Confirmar', 'YesNo', 'Warning')
    if ($c -ne 'Yes') { return }
    $size = Get-BlobSize
    for ($i = 0; $i -lt $size; $i++) { $script:CurrentBlob[$i] = 0xFF }
    Refresh-VaultDisplay
    $status.Text = "$tag vaciado en memoria"
})

$btnSave.Add_Click({
    if (-not $script:CurrentBlob -or -not $script:CurrentAccount) { return }
    if ($script:Mode -eq 'Inventory') {
        $c = [System.Windows.Forms.MessageBox]::Show("Guardar inventory de $($script:CurrentChar)?`n(Char debe estar deslogueado)", 'Confirmar', 'YesNo', 'Question')
        if ($c -ne 'Yes') { return }
        try {
            $n = Save-InventoryBlob -CharName $script:CurrentChar -Bytes $script:CurrentBlob
            $status.Text = "Inventory guardado OK (filas: $n). Backup en vault-backup/"
        } catch {
            $status.Text = "Err: $($_.Exception.Message)"
            [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Error', 'OK', 'Error') | Out-Null
        }
    } else {
        $c = [System.Windows.Forms.MessageBox]::Show("Guardar al vault de $($script:CurrentAccount)?`n(Char debe estar deslogueado)", 'Confirmar', 'YesNo', 'Question')
        if ($c -ne 'Yes') { return }
        try {
            $n = Save-VaultBlob -AccountID $script:CurrentAccount -Bytes $script:CurrentBlob
            $status.Text = "Vault guardado OK (filas: $n). Backup en vault-backup/"
        } catch {
            $status.Text = "Err: $($_.Exception.Message)"
            [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Error', 'OK', 'Error') | Out-Null
        }
    }
})

$btnReload.Add_Click({ Load-DataForSelected })

# ============================================================
# Character Editor (ventana separada)
# ============================================================
function Show-CharEditor {
    param([string] $CharName)
    if (-not $CharName) { return }
    try { $char = Get-CharFull -Name $CharName } catch {
        [System.Windows.Forms.MessageBox]::Show("No se pudo cargar $CharName : $($_.Exception.Message)", 'Error', 'OK', 'Error') | Out-Null
        return
    }
    if ($char.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show("Char '$CharName' no encontrado", 'Error', 'OK', 'Error') | Out-Null
        return
    }

    $cf = New-Object System.Windows.Forms.Form
    $cf.Text = "Editar Character: $CharName"
    $cf.Size = New-Object System.Drawing.Size(520, 620)
    $cf.StartPosition = 'CenterParent'
    $cf.FormBorderStyle = 'FixedDialog'
    $cf.MaximizeBox = $false

    $controls = @{}
    $y = 15

    # Helper para agregar un row "label + input"
    function Add-Row($label, $colName, $value, $isNumeric = $true, $width = 220) {
        $lbl = New-Object System.Windows.Forms.Label
        $lbl.Text = $label; $lbl.Location = New-Object System.Drawing.Point(15, $y); $lbl.Size = New-Object System.Drawing.Size(150, 22)
        $script:cf.Controls.Add($lbl)
        if ($isNumeric) {
            $inp = New-Object System.Windows.Forms.NumericUpDown
            $inp.Location = New-Object System.Drawing.Point(170, $y); $inp.Size = New-Object System.Drawing.Size($width, 22)
            $inp.Minimum = 0; $inp.Maximum = 2147483647
            if ($value -ne $null) { try { $inp.Value = [int64]$value } catch {} }
        } else {
            $inp = New-Object System.Windows.Forms.TextBox
            $inp.Location = New-Object System.Drawing.Point(170, $y); $inp.Size = New-Object System.Drawing.Size($width, 22)
            if ($value -ne $null) { $inp.Text = [string]$value }
        }
        $script:cf.Controls.Add($inp)
        $script:controls[$colName] = $inp
        $script:y += 30
    }

    $script:cf = $cf
    $script:controls = $controls
    $script:y = $y

    Add-Row 'Name' 'Name' $char.Name $false 220
    Add-Row 'Class (16=DK 17=BK 18=BM 0=DW 64=MG 48=ELF 80=DL)' 'Class' $char.Class $true 80
    if ($char.ContainsKey('cLevel'))      { Add-Row 'Level' 'cLevel' $char.cLevel }
    if ($char.ContainsKey('LevelUpPoint')) { Add-Row 'LevelUpPoint (puntos libres)' 'LevelUpPoint' $char.LevelUpPoint }
    if ($char.ContainsKey('Strength'))     { Add-Row 'Strength' 'Strength' $char.Strength }
    if ($char.ContainsKey('Dexterity'))    { Add-Row 'Dexterity' 'Dexterity' $char.Dexterity }
    if ($char.ContainsKey('Vitality'))     { Add-Row 'Vitality' 'Vitality' $char.Vitality }
    if ($char.ContainsKey('Energy'))       { Add-Row 'Energy' 'Energy' $char.Energy }
    if ($char.ContainsKey('Leadership'))   { Add-Row 'Leadership (DL command)' 'Leadership' $char.Leadership }
    if ($char.ContainsKey('Money'))        { Add-Row 'Money (Zen)' 'Money' $char.Money }
    if ($char.ContainsKey('Experience'))   { Add-Row 'Experience' 'Experience' $char.Experience }
    if ($char.ContainsKey('MapNumber'))    { Add-Row 'MapNumber' 'MapNumber' $char.MapNumber }
    if ($char.ContainsKey('MapPosX'))      { Add-Row 'MapPosX' 'MapPosX' $char.MapPosX }
    if ($char.ContainsKey('MapPosY'))      { Add-Row 'MapPosY' 'MapPosY' $char.MapPosY }
    if ($char.ContainsKey('PkCount'))      { Add-Row 'PkCount' 'PkCount' $char.PkCount }
    if ($char.ContainsKey('PkLevel'))      { Add-Row 'PkLevel' 'PkLevel' $char.PkLevel }

    # Quick class buttons
    $y = $script:y + 5
    $lblQuick = New-Object System.Windows.Forms.Label
    $lblQuick.Text = 'Evoluciones rapidas:'; $lblQuick.Location = New-Object System.Drawing.Point(15, $y); $lblQuick.Size = New-Object System.Drawing.Size(200, 22)
    $cf.Controls.Add($lblQuick)
    $y += 22
    $classBtns = @(
        @{ Lbl='DK -> BK (17)'; Val=17 }
        @{ Lbl='BK -> BM (18)'; Val=18 }
        @{ Lbl='SM -> GM (2)';  Val=2 }
        @{ Lbl='FE -> ME (33)'; Val=33 }
        @{ Lbl='MG (64)';       Val=64 }
        @{ Lbl='DL (80)';       Val=80 }
    )
    $bx = 15
    foreach ($cb in $classBtns) {
        $b = New-Object System.Windows.Forms.Button
        $b.Text = $cb.Lbl; $b.Location = New-Object System.Drawing.Point($bx, $y); $b.Size = New-Object System.Drawing.Size(120, 26)
        $val = $cb.Val
        $b.Add_Click({ $controls['Class'].Value = $val }.GetNewClosure())
        $cf.Controls.Add($b)
        $bx += 125
        if ($bx -gt 350) { $bx = 15; $y += 28 }
    }
    $y += 35

    # Status
    $stat = New-Object System.Windows.Forms.Label
    $stat.Text = 'Cambios se guardan en la DB. Char debe estar offline para que persista.'
    $stat.Location = New-Object System.Drawing.Point(15, $y); $stat.Size = New-Object System.Drawing.Size(480, 22)
    $stat.ForeColor = [System.Drawing.Color]::DarkRed
    $stat.Font = New-Object System.Drawing.Font('Segoe UI', 8)
    $cf.Controls.Add($stat)
    $y += 28

    # Save/Cancel
    $btnSv = New-Object System.Windows.Forms.Button
    $btnSv.Text = 'Guardar cambios'; $btnSv.Location = New-Object System.Drawing.Point(15, $y); $btnSv.Size = New-Object System.Drawing.Size(150, 32)
    $btnSv.BackColor = [System.Drawing.Color]::PaleGreen
    $btnSv.Font = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
    $btnCl = New-Object System.Windows.Forms.Button
    $btnCl.Text = 'Cerrar'; $btnCl.Location = New-Object System.Drawing.Point(180, $y); $btnCl.Size = New-Object System.Drawing.Size(100, 32)
    $cf.Controls.AddRange(@($btnSv, $btnCl))

    $btnSv.Add_Click({
        $newFields = @{}
        $newName = $script:controls['Name'].Text.Trim()
        $nameChanged = ($newName -ne $CharName)
        foreach ($k in $script:controls.Keys) {
            if ($k -eq 'Name') {
                if ($nameChanged) { $newFields[$k] = $newName }
            } else {
                $newFields[$k] = $script:controls[$k].Value
            }
        }
        if ($nameChanged) {
            $resp = [System.Windows.Forms.MessageBox]::Show("Cambiar nombre de '$CharName' a '$newName' puede romper guild/friend/post. Confirmas?", 'Cambio de nombre', 'YesNo', 'Warning')
            if ($resp -ne 'Yes') { $newFields.Remove('Name'); $newName = $CharName }
        }
        try {
            $n = Set-CharFields -Name $CharName -Fields $newFields
            $stat.Text = "Guardado OK (filas: $n). Recordar: char offline para que persista."
            $stat.ForeColor = [System.Drawing.Color]::DarkGreen
            Refresh-Characters   # reload list to show new name/class
        } catch {
            [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Error', 'OK', 'Error') | Out-Null
        }
    }.GetNewClosure())
    $btnCl.Add_Click({ $cf.Close() })

    [void]$cf.ShowDialog($form)
}

$btnEditChar.Add_Click({
    if (-not $script:CurrentChar) {
        [System.Windows.Forms.MessageBox]::Show('Seleccioná un char primero', 'Aviso', 'OK', 'Warning') | Out-Null
        return
    }
    Show-CharEditor -CharName $script:CurrentChar
})

$form.Add_Shown({
    Refresh-Characters
    if ($cmbCat.Items.Count -gt 0) { $cmbCat.SelectedIndex = 0; Update-ItemDropdown }
})

[void]$form.ShowDialog()
