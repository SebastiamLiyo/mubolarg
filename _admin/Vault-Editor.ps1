<#
.SYNOPSIS
  Editor de vault (warehouse) para MuEMU 1.04.05 - server mubolarg.

.DESCRIPTION
  GUI Windows Forms que:
    - Lista los chars de la DB con su vault status
    - Muestra el contenido del vault del char seleccionado
    - Aplica presets (kits, jewels, boxes) o ítems individuales
    - Hace backup automatico antes de cada guardado
    - Escribe al SQL con formato 16-byte/slot exacto del server

  Formato del slot (16 bytes), reverse-engineered del server:
    Byte 0   : Item index low (8 bits)
    Byte 1   : (skill<<7) | (level<<3) | (luck<<2) | option(2bit)
    Byte 2   : Durability
    Byte 3   : Excellent options (6 bits)
    Bytes 4-8: 0x00
    Byte 9   : (Type<<4) | indexHigh
    Bytes 10-13: 0xFF (weapons/armor sockets empty) | 0x00 (misc/jewels)
    Bytes 14-15: random serial (weapons/armor/wings) | 0x00 (misc)
    Slot vacio: 16 bytes de 0xFF

.PARAMETER SqlInstance
  Instancia SQL. Default: .\SQLEXPRESS

.PARAMETER Database
  Nombre DB. Default: MuOnline

.EXAMPLE
  .\Vault-Editor.ps1
#>

[CmdletBinding()]
param(
    [string] $SqlInstance = '.\SQLEXPRESS',
    [string] $Database = 'MuOnline'
)

Set-StrictMode -Off  # ConvertFrom-Json y otros tiran false positives con strict
$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Data

# ============================================================
# Helpers de bytes
# ============================================================

$script:rng = [System.Random]::new()

function New-EmptySlot {
    $b = New-Object byte[] 16
    for ($i = 0; $i -lt 16; $i++) { $b[$i] = 0xFF }
    return ,$b
}

function New-ItemBytes {
    param(
        [Parameter(Mandatory)] [int] $Type,
        [Parameter(Mandatory)] [int] $Index,
        [int]    $Level = 0,
        [bool]   $Luck = $false,
        [bool]   $Skill = $false,
        [int]    $Option = 0,           # 0-3 (mapea +0/+4/+8/+12)
        [int]    $Excellent = 0,        # bitmask 0..0x3F (6 bits = 6 exc options)
        [int]    $Durability = 255,     # 0-255
        [switch] $IsMisc                # boxes, jewels, scrolls -> bytes 10-15 = 0
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
        # Misc/consumibles: bytes 10-15 todos 0x00
        for ($i = 10; $i -le 15; $i++) { $b[$i] = 0x00 }
    } else {
        # Equipables: sockets vacios + serial random
        $b[10] = 0xFF; $b[11] = 0xFF; $b[12] = 0xFF; $b[13] = 0xFF
        $b[14] = [byte]$script:rng.Next(1, 256)
        $b[15] = [byte]$script:rng.Next(1, 256)
    }
    return ,$b
}

# ============================================================
# Catalogo de items y presets
# ============================================================

# Catalogo simplificado: nombres -> (Type, Index, IsMisc, DefaultDur)
$script:Catalog = @{
    # === Knight Swords (T0) ===
    'Sword of Destruction' = @{ T=0;  I=16; M=$false; D=84  }
    'Knight Blade'         = @{ T=0;  I=20; M=$false; D=90  }
    'Bone Blade'           = @{ T=0;  I=22; M=$false; D=95  }
    'Flameberge'           = @{ T=0;  I=26; M=$false; D=90  }
    'Sword Breaker'        = @{ T=0;  I=27; M=$false; D=90  }
    'Daybreak'             = @{ T=0;  I=24; M=$false; D=90  }
    # === MG Swords ===
    'Dark Breaker'         = @{ T=0;  I=17; M=$false; D=89  }
    'Thunder Blade'        = @{ T=0;  I=18; M=$false; D=86  }
    'Dark Reign Blade'     = @{ T=0;  I=21; M=$false; D=100 }
    'Sword Dancer'         = @{ T=0;  I=25; M=$false; D=90  }
    'Rune Blade'           = @{ T=0;  I=31; M=$false; D=93  }
    # === DL Scepters (T2) ===
    'Battle Scepter'       = @{ T=2;  I=8;  M=$false; D=40  }
    'Master Scepter'       = @{ T=2;  I=9;  M=$false; D=45  }
    'Great Scepter'        = @{ T=2;  I=10; M=$false; D=65  }
    # === ELF Bows (T4) ===
    'Arrow Viper Bow'      = @{ T=4;  I=20; M=$false; D=86  }
    'Sylph Wind Bow'       = @{ T=4;  I=21; M=$false; D=93  }
    'Albatross Bow'        = @{ T=4;  I=22; M=$false; D=70  }
    'Great Reign Crossbow' = @{ T=4;  I=19; M=$false; D=80  }
    # === DW/MG Staffs (T5) ===
    'Staff of Kundun'      = @{ T=5;  I=11; M=$false; D=95  }
    'Grand Viper Staff'    = @{ T=5;  I=12; M=$false; D=100 }
    'Platina Staff'        = @{ T=5;  I=13; M=$false; D=78  }
    # === Sets - Dark Phoenix (DK tier-2) ===
    'Dark Phoenix Helm'    = @{ T=7;  I=17; M=$false; D=80  }
    'Dark Phoenix Armor'   = @{ T=8;  I=17; M=$false; D=80  }
    'Dark Phoenix Pants'   = @{ T=9;  I=17; M=$false; D=80  }
    'Dark Phoenix Gloves'  = @{ T=10; I=17; M=$false; D=80  }
    'Dark Phoenix Boots'   = @{ T=11; I=17; M=$false; D=80  }
    # === Great Dragon (DK tier-3) ===
    'Great Dragon Helm'    = @{ T=7;  I=21; M=$false; D=86  }
    'Great Dragon Armor'   = @{ T=8;  I=21; M=$false; D=86  }
    'Great Dragon Pants'   = @{ T=9;  I=21; M=$false; D=86  }
    'Great Dragon Gloves'  = @{ T=10; I=21; M=$false; D=86  }
    'Great Dragon Boots'   = @{ T=11; I=21; M=$false; D=86  }
    # === Grand Soul (DW) ===
    'Grand Soul Helm'      = @{ T=7;  I=18; M=$false; D=67  }
    'Grand Soul Armor'     = @{ T=8;  I=18; M=$false; D=67  }
    'Grand Soul Pants'     = @{ T=9;  I=18; M=$false; D=67  }
    'Grand Soul Gloves'    = @{ T=10; I=18; M=$false; D=67  }
    'Grand Soul Boots'     = @{ T=11; I=18; M=$false; D=67  }
    # === Divine (ELF) ===
    'Divine Helm'          = @{ T=7;  I=19; M=$false; D=74  }
    'Divine Armor'         = @{ T=8;  I=19; M=$false; D=74  }
    'Divine Pants'         = @{ T=9;  I=19; M=$false; D=74  }
    'Divine Gloves'        = @{ T=10; I=19; M=$false; D=74  }
    'Divine Boots'         = @{ T=11; I=19; M=$false; D=74  }
    # === Wings S2 (T12) ===
    'Wings of Spirits'     = @{ T=12; I=3;  M=$false; D=200 }
    'Wings of Soul'        = @{ T=12; I=4;  M=$false; D=200 }
    'Wings of Dragon'      = @{ T=12; I=5;  M=$false; D=200 }
    'Wings of Darkness'    = @{ T=12; I=6;  M=$false; D=200 }
    # === Jewels (T14 - Misc) ===
    'Jewel of Bless'       = @{ T=14; I=13; M=$true;  D=1 }
    'Jewel of Soul'        = @{ T=14; I=14; M=$true;  D=1 }
    'Jewel of Life'        = @{ T=14; I=16; M=$true;  D=1 }
    'Jewel of Chaos'       = @{ T=12; I=15; M=$true;  D=1 }
    'Jewel of Creation'    = @{ T=14; I=22; M=$true;  D=1 }
    'Jewel of Harmony'     = @{ T=14; I=42; M=$true;  D=1 }
    # === Event boxes ===
    'Box of Kundun 5'      = @{ T=14; I=11; M=$true;  D=0; Level=12 }
    'Box of Kundun 4'      = @{ T=14; I=11; M=$true;  D=0; Level=11 }
    'Box of Kundun 3'      = @{ T=14; I=11; M=$true;  D=0; Level=10 }
    'Box of Kundun 2'      = @{ T=14; I=11; M=$true;  D=0; Level=9 }
    'Box of Kundun 1'      = @{ T=14; I=11; M=$true;  D=0; Level=8 }
}

# Presets: cada preset es una lista de placements { Slot, Item, Level, Luck, Skill, Option, Excellent, Qty(opcional) }
$script:Presets = @{
    'Kit DK/BK full +13 +L+S+12 exc6' = @(
        @{ Slot=0;  Item='Dark Phoenix Helm';    Level=13; Luck=$true; Excellent=0x3F }
        @{ Slot=2;  Item='Dark Phoenix Armor';   Level=13; Luck=$true; Excellent=0x3F }
        @{ Slot=4;  Item='Dark Phoenix Pants';   Level=13; Luck=$true; Excellent=0x3F }
        @{ Slot=6;  Item='Dark Phoenix Gloves';  Level=13; Luck=$true; Excellent=0x3F }
        @{ Slot=20; Item='Dark Phoenix Boots';   Level=13; Luck=$true; Excellent=0x3F }
        @{ Slot=24; Item='Wings of Dragon';      Level=13; Luck=$true; Excellent=0x3F }
        @{ Slot=48; Item='Bone Blade';           Level=13; Luck=$true; Skill=$true; Option=3; Excellent=0x3F }
        @{ Slot=49; Item='Knight Blade';         Level=13; Luck=$true; Skill=$true; Option=3; Excellent=0x3F }
        @{ Slot=50; Item='Sword of Destruction'; Level=13; Luck=$true; Skill=$true; Option=3; Excellent=0x3F }
    )
    'Kit ELF full +13 +L+S+12 exc6' = @(
        @{ Slot=0;  Item='Divine Helm';      Level=13; Luck=$true; Excellent=0x3F }
        @{ Slot=2;  Item='Divine Armor';     Level=13; Luck=$true; Excellent=0x3F }
        @{ Slot=4;  Item='Divine Pants';     Level=13; Luck=$true; Excellent=0x3F }
        @{ Slot=6;  Item='Divine Gloves';    Level=13; Luck=$true; Excellent=0x3F }
        @{ Slot=20; Item='Divine Boots';     Level=13; Luck=$true; Excellent=0x3F }
        @{ Slot=24; Item='Wings of Spirits'; Level=13; Luck=$true; Excellent=0x3F }
        @{ Slot=48; Item='Sylph Wind Bow';   Level=13; Luck=$true; Skill=$true; Option=3; Excellent=0x3F }
        @{ Slot=49; Item='Arrow Viper Bow';  Level=13; Luck=$true; Skill=$true; Option=3; Excellent=0x3F }
    )
    'Kit DW full +13 +L+S+12 exc6' = @(
        @{ Slot=0;  Item='Grand Soul Helm';   Level=13; Luck=$true; Excellent=0x3F }
        @{ Slot=2;  Item='Grand Soul Armor';  Level=13; Luck=$true; Excellent=0x3F }
        @{ Slot=4;  Item='Grand Soul Pants';  Level=13; Luck=$true; Excellent=0x3F }
        @{ Slot=6;  Item='Grand Soul Gloves'; Level=13; Luck=$true; Excellent=0x3F }
        @{ Slot=20; Item='Grand Soul Boots';  Level=13; Luck=$true; Excellent=0x3F }
        @{ Slot=24; Item='Wings of Soul';     Level=13; Luck=$true; Excellent=0x3F }
        @{ Slot=48; Item='Grand Viper Staff'; Level=13; Luck=$true; Skill=$true; Option=3; Excellent=0x3F }
        @{ Slot=49; Item='Staff of Kundun';   Level=13; Luck=$true; Skill=$true; Option=3; Excellent=0x3F }
    )
    'Pack Jewels (30 Bless, 30 Soul, 20 Life, 10 Chaos, 10 Creation)' = @(
        @{ Item='Jewel of Bless';    Qty=30 }
        @{ Item='Jewel of Soul';     Qty=30 }
        @{ Item='Jewel of Life';     Qty=20 }
        @{ Item='Jewel of Chaos';    Qty=10 }
        @{ Item='Jewel of Creation'; Qty=10 }
    )
    '120 Box of Kundun 5 (lleno vault)' = @(
        @{ Item='Box of Kundun 5'; Qty=120 }
    )
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

function Get-AppRoot {
    # Funciona en ps1 directo, ps2exe compilado, y standalone
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

function Save-VaultBlob {
    param([string] $AccountID, [byte[]] $Bytes)
    if ($Bytes.Length -ne 1920) { throw "Vault blob debe ser 1920 bytes, recibi $($Bytes.Length)" }

    # Backup primero - detectar root robustamente (compilado o no, en _admin o root)
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
# Lectura del vault (decodificar slots ocupados)
# ============================================================

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

        # Buscar nombre en catalogo
        $name = "Unknown T=$type I=$idx"
        foreach ($k in $script:Catalog.Keys) {
            $c = $script:Catalog[$k]
            if ($c.T -eq $type -and $c.I -eq $idx) {
                # Para box of Kundun discriminamos por level
                if ($c.ContainsKey('Level')) {
                    if ($c.Level -eq $level) { $name = $k; break }
                } else {
                    $name = $k; break
                }
            }
        }

        $slots += [pscustomobject]@{
            Slot  = $s
            Name  = $name
            Type  = $type
            Idx   = $idx
            Level = $level
            Luck  = $luck
            Skill = $skill
            Opt   = $option
            Exc   = $exc
        }
    }
    return $slots
}

# ============================================================
# Aplicar presets / placements al blob
# ============================================================

function Apply-Placements {
    param([byte[]] $Blob, [array] $Placements)
    # Encontrar slot libre o usar slot dado
    function Find-FreeSlot([byte[]]$b) {
        for ($s = 0; $s -lt 120; $s++) {
            $off = $s * 16
            $isEmpty = $true
            for ($i = 0; $i -lt 16; $i++) { if ($b[$off+$i] -ne 0xFF) { $isEmpty = $false; break } }
            if ($isEmpty) { return $s }
        }
        return -1
    }

    $applied = 0
    foreach ($p in $Placements) {
        $itemName = $p.Item
        if (-not $script:Catalog.ContainsKey($itemName)) {
            Write-Warning "Item desconocido en preset: $itemName"
            continue
        }
        $c = $script:Catalog[$itemName]
        $qty = if ($p.ContainsKey('Qty')) { [int]$p.Qty } else { 1 }
        $level = if ($p.ContainsKey('Level')) { [int]$p.Level } elseif ($c.ContainsKey('Level')) { [int]$c.Level } else { 0 }
        $luck = if ($p.ContainsKey('Luck')) { [bool]$p.Luck } else { $false }
        $skill = if ($p.ContainsKey('Skill')) { [bool]$p.Skill } else { $false }
        $option = if ($p.ContainsKey('Option')) { [int]$p.Option } else { 0 }
        $exc = if ($p.ContainsKey('Excellent')) { [int]$p.Excellent } else { 0 }

        for ($q = 0; $q -lt $qty; $q++) {
            $slotIdx = if ($p.ContainsKey('Slot') -and $q -eq 0) { [int]$p.Slot } else { Find-FreeSlot $Blob }
            if ($slotIdx -lt 0) { Write-Warning "Vault lleno - no se pudo colocar $itemName"; break }
            $params = @{
                Type = $c.T
                Index = $c.I
                Level = $level
                Luck = $luck
                Skill = $skill
                Option = $option
                Excellent = $exc
                Durability = $c.D
            }
            if ($c.M) { $params['IsMisc'] = $true }
            $bytes = New-ItemBytes @params
            [Array]::Copy($bytes, 0, $Blob, $slotIdx * 16, 16)
            $applied++
        }
    }
    return $applied
}

# ============================================================
# GUI
# ============================================================

$script:CurrentBlob = $null
$script:CurrentAccount = $null
$script:CurrentChar = $null

$form = New-Object System.Windows.Forms.Form
$form.Text = 'Vault Editor - mubolarg MuEMU 1.04.05'
$form.Size = New-Object System.Drawing.Size(900, 600)
$form.StartPosition = 'CenterScreen'
$form.FormBorderStyle = 'Sizable'

# --- Left: lista de chars ---
$lblChars = New-Object System.Windows.Forms.Label
$lblChars.Text = 'Characters:'
$lblChars.Location = New-Object System.Drawing.Point(10, 10); $lblChars.Size = New-Object System.Drawing.Size(200, 20)

$listChars = New-Object System.Windows.Forms.ListBox
$listChars.Location = New-Object System.Drawing.Point(10, 32); $listChars.Size = New-Object System.Drawing.Size(280, 480)
$listChars.Font = New-Object System.Drawing.Font('Consolas', 9)

$btnRefresh = New-Object System.Windows.Forms.Button
$btnRefresh.Text = 'Refresh chars'
$btnRefresh.Location = New-Object System.Drawing.Point(10, 520); $btnRefresh.Size = New-Object System.Drawing.Size(280, 28)

# --- Right top: info char ---
$lblInfo = New-Object System.Windows.Forms.Label
$lblInfo.Text = 'Selecciona un char a la izquierda'
$lblInfo.Location = New-Object System.Drawing.Point(310, 10); $lblInfo.Size = New-Object System.Drawing.Size(560, 40)
$lblInfo.Font = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)

# --- Right middle: contenido del vault ---
$lblVault = New-Object System.Windows.Forms.Label
$lblVault.Text = 'Vault (slot - item - +X - flags):'
$lblVault.Location = New-Object System.Drawing.Point(310, 56); $lblVault.Size = New-Object System.Drawing.Size(560, 20)

$listVault = New-Object System.Windows.Forms.ListBox
$listVault.Location = New-Object System.Drawing.Point(310, 80); $listVault.Size = New-Object System.Drawing.Size(560, 220)
$listVault.Font = New-Object System.Drawing.Font('Consolas', 9)

# --- Right bottom: presets y acciones ---
$lblPreset = New-Object System.Windows.Forms.Label
$lblPreset.Text = 'Preset:'
$lblPreset.Location = New-Object System.Drawing.Point(310, 310); $lblPreset.Size = New-Object System.Drawing.Size(80, 22)

$cmbPreset = New-Object System.Windows.Forms.ComboBox
$cmbPreset.Location = New-Object System.Drawing.Point(380, 306); $cmbPreset.Size = New-Object System.Drawing.Size(380, 24)
$cmbPreset.DropDownStyle = 'DropDownList'
foreach ($k in $script:Presets.Keys | Sort-Object) { [void]$cmbPreset.Items.Add($k) }
if ($cmbPreset.Items.Count -gt 0) { $cmbPreset.SelectedIndex = 0 }

$btnApplyPreset = New-Object System.Windows.Forms.Button
$btnApplyPreset.Text = 'Aplicar preset'
$btnApplyPreset.Location = New-Object System.Drawing.Point(770, 305); $btnApplyPreset.Size = New-Object System.Drawing.Size(100, 26)

$btnClear = New-Object System.Windows.Forms.Button
$btnClear.Text = 'Vaciar vault'
$btnClear.Location = New-Object System.Drawing.Point(310, 340); $btnClear.Size = New-Object System.Drawing.Size(140, 28)
$btnClear.BackColor = [System.Drawing.Color]::MistyRose

$btnSave = New-Object System.Windows.Forms.Button
$btnSave.Text = 'Guardar a DB'
$btnSave.Location = New-Object System.Drawing.Point(460, 340); $btnSave.Size = New-Object System.Drawing.Size(140, 28)
$btnSave.BackColor = [System.Drawing.Color]::PaleGreen
$btnSave.Font = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)

$btnReload = New-Object System.Windows.Forms.Button
$btnReload.Text = 'Recargar (descartar)'
$btnReload.Location = New-Object System.Drawing.Point(610, 340); $btnReload.Size = New-Object System.Drawing.Size(140, 28)

# --- Status bar ---
$status = New-Object System.Windows.Forms.Label
$status.Text = 'Listo'
$status.Location = New-Object System.Drawing.Point(310, 530); $status.Size = New-Object System.Drawing.Size(560, 22)
$status.BorderStyle = 'FixedSingle'

# --- Actions ---
function Refresh-Characters {
    $listChars.Items.Clear()
    try {
        $chars = Get-Characters
        $classMap = @{ 0='DW'; 1='SM'; 2='GM'; 16='DK'; 17='BK'; 18='BM'; 32='ME'; 33='ME+'; 48='EL'; 64='MG'; 80='DL'; 96='SU'; 112='RF' }
        foreach ($c in $chars) {
            $cls = if ($classMap.ContainsKey($c.Class)) { $classMap[$c.Class] } else { "?$($c.Class)" }
            $line = "{0,-10}  {1,-12}  {2,-4}  L{3,4}" -f $c.AccountID, $c.Name, $cls, $c.Level
            [void]$listChars.Items.Add($line)
        }
        $status.Text = "Cargados $($chars.Count) chars"
    } catch {
        $status.Text = "Error: $($_.Exception.Message)"
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
        $line = "[{0,3}]  +{1,2}  {2,-30}  {3}" -f $s.Slot, $s.Level, $s.Name, $flagStr
        [void]$listVault.Items.Add($line)
    }
    $occupied = $slots.Count
    $lblInfo.Text = "$($script:CurrentAccount) / $($script:CurrentChar)  -  $occupied/120 slots ocupados"
}

function Load-VaultForSelected {
    $sel = $listChars.SelectedIndex
    if ($sel -lt 0) { return }
    $line = $listChars.Items[$sel]
    # AccountID es el primer token
    $acc = ($line -split '\s+')[0]
    $name = ($line -split '\s+')[1]
    $script:CurrentAccount = $acc
    $script:CurrentChar = $name
    try {
        $blob = Get-VaultBlob -AccountID $acc
        if (-not $blob) {
            $status.Text = "X no hay vault para $acc"
            $script:CurrentBlob = $null
        } else {
            $script:CurrentBlob = New-Object byte[] 1920
            [Array]::Copy($blob, $script:CurrentBlob, 1920)
            $status.Text = "Vault de $acc cargado ($($blob.Length) bytes)"
        }
        Refresh-VaultDisplay
    } catch {
        $status.Text = "Error: $($_.Exception.Message)"
    }
}

$btnRefresh.Add_Click({ Refresh-Characters })
$listChars.Add_DoubleClick({ Load-VaultForSelected })
$listChars.Add_SelectedIndexChanged({ Load-VaultForSelected })

$btnApplyPreset.Add_Click({
    if (-not $script:CurrentBlob) { $status.Text = 'Selecciona un char primero'; return }
    $presetName = [string]$cmbPreset.SelectedItem
    if (-not $presetName) { return }
    $placements = $script:Presets[$presetName]
    try {
        $n = Apply-Placements -Blob $script:CurrentBlob -Placements $placements
        Refresh-VaultDisplay
        $status.Text = "Preset aplicado en memoria: $n items. Apreta Guardar para persistir."
    } catch {
        $status.Text = "Error aplicar preset: $($_.Exception.Message)"
    }
})

$btnClear.Add_Click({
    if (-not $script:CurrentBlob) { return }
    $confirm = [System.Windows.Forms.MessageBox]::Show("Vaciar vault completo (en memoria)? Hace falta Guardar para persistir.", 'Confirmar', 'YesNo', 'Warning')
    if ($confirm -ne 'Yes') { return }
    for ($i = 0; $i -lt 1920; $i++) { $script:CurrentBlob[$i] = 0xFF }
    Refresh-VaultDisplay
    $status.Text = 'Vault vaciado en memoria. Apreta Guardar.'
})

$btnSave.Add_Click({
    if (-not $script:CurrentBlob -or -not $script:CurrentAccount) { return }
    $confirm = [System.Windows.Forms.MessageBox]::Show("Guardar cambios al vault de $($script:CurrentAccount)?`n(El char debe estar deslogueado para que persista)", 'Confirmar guardado', 'YesNo', 'Question')
    if ($confirm -ne 'Yes') { return }
    try {
        $n = Save-VaultBlob -AccountID $script:CurrentAccount -Bytes $script:CurrentBlob
        $status.Text = "Guardado OK (filas: $n). Backup automatico en vault-backup/"
    } catch {
        $status.Text = "Error guardar: $($_.Exception.Message)"
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Error', 'OK', 'Error') | Out-Null
    }
})

$btnReload.Add_Click({ Load-VaultForSelected })

$form.Controls.AddRange(@(
    $lblChars, $listChars, $btnRefresh,
    $lblInfo, $lblVault, $listVault,
    $lblPreset, $cmbPreset, $btnApplyPreset,
    $btnClear, $btnSave, $btnReload,
    $status
))

# Carga inicial
$form.Add_Shown({ Refresh-Characters })

[void]$form.ShowDialog()
