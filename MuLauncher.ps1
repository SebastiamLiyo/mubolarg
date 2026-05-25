param(
    [switch]$SelfTest
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$script:Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:ConfigPath = Join-Path $script:Root 'MuLauncher.config.json'
$script:MainInfoPath = Join-Path $script:Root 'MainInfo.ini'
$script:RegistryPath = 'HKCU:\Software\Webzen\Mu\Config'
$script:UpdateStateOk = $false   # se setea true cuando termina update OK (o cuando no hay UpdateUrl)
$script:DefaultUpdateUrl = 'https://raw.githubusercontent.com/SebastiamLiyo/mubolarg/main/manifest.json'

$script:Resolutions = @(
    [pscustomobject]@{ Value = 1; Label = '800 x 600 (recomendado - M se ve bien)' }
    [pscustomobject]@{ Value = 2; Label = '1024 x 768' }
    [pscustomobject]@{ Value = 3; Label = '1280 x 1024' }
    [pscustomobject]@{ Value = 4; Label = '1366 x 768' }
    [pscustomobject]@{ Value = 5; Label = '1600 x 900' }
    [pscustomobject]@{ Value = 6; Label = '1920 x 1080 (M puede solaparse)' }
)

function Ensure-RegistryPath {
    if (-not (Test-Path $script:RegistryPath)) { New-Item -Path $script:RegistryPath -Force | Out-Null }
}

function Get-IniValue {
    param([string]$Path, [string]$Section, [string]$Key)
    if (-not (Test-Path $Path)) { return $null }
    $currentSection = ''
    foreach ($line in Get-Content $Path) {
        $trim = $line.Trim()
        if (-not $trim) { continue }
        if ($trim -match '^\[(.+)\]$') { $currentSection = $matches[1]; continue }
        if ($currentSection -eq $Section -and $trim -match '^([^=]+)=(.*)$') {
            if ($matches[1].Trim() -eq $Key) { return $matches[2].Trim() }
        }
    }
    return $null
}

function Get-LauncherConfig {
    $default = [ordered]@{
        ClientPath = (Join-Path $script:Root 'main.exe')
        WindowTitle = (Get-IniValue -Path $script:MainInfoPath -Section 'MainInfo' -Key 'WindowName')
        Username = ''
        VolumeLevel = 5
        SoundOn = $true
        MusicOn = $true
        WindowMode = $true
        Resolution = 1
        ForceTypeLogin = $false
        UpdateUrl = $script:DefaultUpdateUrl   # URL al manifest.json; vacio = sin auto-update
        SkipUpdate = $false  # opcion debug: saltear update aunque UpdateUrl este seteado
    }

    if (Test-Path $script:ConfigPath) {
        $loaded = Get-Content $script:ConfigPath -Raw | ConvertFrom-Json
        foreach ($property in @($default.Keys)) {
            if ($null -ne $loaded.$property) { $default[$property] = $loaded.$property }
        }
    }

    Ensure-RegistryPath
    $reg = Get-ItemProperty -Path $script:RegistryPath -ErrorAction SilentlyContinue
    if ($null -ne $reg) {
        $props = $reg.PSObject.Properties
        if ($props.Match('VolumeLevel').Count -gt 0) { $default.VolumeLevel = [int]$reg.VolumeLevel }
        if ($props.Match('SoundOnOff').Count -gt 0)  { $default.SoundOn = ([int]$reg.SoundOnOff -ne 0) }
        if ($props.Match('MusicOnOff').Count -gt 0)  { $default.MusicOn = ([int]$reg.MusicOnOff -ne 0) }
        if ($props.Match('WindowMode').Count -gt 0)  { $default.WindowMode = ([int]$reg.WindowMode -ne 0) }
        if ($props.Match('Resolution').Count -gt 0)  { $default.Resolution = [int]$reg.Resolution }
        if ($props.Match('ID').Count -gt 0 -and -not [string]::IsNullOrWhiteSpace([string]$reg.ID)) {
            $default.Username = [string]$reg.ID
        }
    }

    return [pscustomobject]$default
}

function Save-LauncherConfig {
    param([psobject]$Config)
    $Config | ConvertTo-Json | Set-Content -Path $script:ConfigPath -Encoding UTF8
}

function Save-ClientSettings {
    param([psobject]$Config)
    Ensure-RegistryPath
    Set-ItemProperty -Path $script:RegistryPath -Name 'VolumeLevel' -Type DWord -Value ([int]$Config.VolumeLevel)
    Set-ItemProperty -Path $script:RegistryPath -Name 'SoundOnOff'  -Type DWord -Value $(if ($Config.SoundOn) { 1 } else { 0 })
    Set-ItemProperty -Path $script:RegistryPath -Name 'MusicOnOff'  -Type DWord -Value $(if ($Config.MusicOn) { 1 } else { 0 })
    Set-ItemProperty -Path $script:RegistryPath -Name 'WindowMode'  -Type DWord -Value $(if ($Config.WindowMode) { 1 } else { 0 })
    Set-ItemProperty -Path $script:RegistryPath -Name 'Resolution'  -Type DWord -Value ([int]$Config.Resolution)
    Set-ItemProperty -Path $script:RegistryPath -Name 'ID'          -Type String -Value $Config.Username
}

function Apply-CompatLayer {
    param([string]$ExePath)
    $layers = 'HKCU:\Software\Microsoft\Windows NT\CurrentVersion\AppCompatFlags\Layers'
    if (-not (Test-Path $layers)) { New-Item -Path $layers -Force | Out-Null }
    $current = (Get-ItemProperty -Path $layers -Name $ExePath -ErrorAction SilentlyContinue).$ExePath
    if (-not $current -or $current -notmatch 'WIN7RTM') {
        Set-ItemProperty -Path $layers -Name $ExePath -Value '~ WIN7RTM RUNASADMIN' -Type String
    }
}

function Get-FileHashSafe {
    param([string]$Path)
    if (-not (Test-Path $Path)) { return $null }
    try { (Get-FileHash -Path $Path -Algorithm SHA256).Hash.ToLowerInvariant() } catch { return $null }
}

# --- Auto-update ---
# Manifest format:
#   { "version": "...", "base_url": "https://...optional", "files": [ { "path": "main.exe", "sha256": "lowercase64hex", "size": 12345 }, ... ] }
# Si base_url es null/missing, los archivos se buscan en URLs relativas al manifest URL.

function Run-AutoUpdate {
    param(
        [string]$ManifestUrl,
        [System.Windows.Forms.Label]$Status,
        [System.Windows.Forms.ProgressBar]$Progress
    )

    if ([string]::IsNullOrWhiteSpace($ManifestUrl)) {
        $Status.Text = 'Sin URL de update configurada. Saltando.'
        $script:UpdateStateOk = $true
        return
    }

    $Status.Text = "Verificando updates en $ManifestUrl ..."
    [System.Windows.Forms.Application]::DoEvents()

    try {
        # TLS 1.2 obligatorio para hostings modernos
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls11 -bor [Net.SecurityProtocolType]::Tls
        $manifestJson = Invoke-WebRequest -Uri $ManifestUrl -UseBasicParsing -TimeoutSec 30 | Select-Object -ExpandProperty Content
        # Sacar BOM si esta presente (ConvertFrom-Json en PS 5.1 se rompe con BOM)
        if ($manifestJson.Length -gt 0 -and [int][char]$manifestJson[0] -eq 65279) {
            $manifestJson = $manifestJson.Substring(1)
        }
        $manifest = $manifestJson | ConvertFrom-Json
    } catch {
        $Status.Text = "X No se pudo bajar el manifest: $($_.Exception.Message)"
        $script:UpdateStateOk = $false
        return
    }

    # Resolver base URL
    $baseUrl = $manifest.base_url
    if ([string]::IsNullOrWhiteSpace($baseUrl)) {
        $baseUrl = $ManifestUrl.Substring(0, $ManifestUrl.LastIndexOf('/') + 1)
    } elseif ($baseUrl[-1] -ne '/') { $baseUrl = "$baseUrl/" }

    $files = @($manifest.files)
    $Progress.Maximum = $files.Count
    $Progress.Value = 0

    $diffs = @()
    $i = 0
    foreach ($f in $files) {
        $i++
        $Progress.Value = $i
        $Status.Text = "Comparando ($i/$($files.Count))..."
        [System.Windows.Forms.Application]::DoEvents()
        $localPath = Join-Path $script:Root $f.path
        $localHash = Get-FileHashSafe -Path $localPath
        if ($localHash -ne $f.sha256.ToLowerInvariant()) {
            $diffs += $f
        }
    }

    if ($diffs.Count -eq 0) {
        $Status.Text = 'Cliente al dia.'
        $script:UpdateStateOk = $true
        $Progress.Value = $Progress.Maximum
        return
    }

    $Progress.Value = 0
    $Progress.Maximum = $diffs.Count
    $i = 0
    foreach ($f in $diffs) {
        $i++
        $Progress.Value = $i
        $Status.Text = "Bajando ($i/$($diffs.Count)) $($f.path) ..."
        [System.Windows.Forms.Application]::DoEvents()

        $localPath = Join-Path $script:Root $f.path
        $localDir = Split-Path $localPath -Parent
        if (-not (Test-Path $localDir)) { New-Item -ItemType Directory -Path $localDir -Force | Out-Null }

        $url = $baseUrl + ($f.path -replace '\\', '/')
        $tmp = "$localPath.dl-tmp"

        try {
            Invoke-WebRequest -Uri $url -OutFile $tmp -UseBasicParsing -TimeoutSec 300
        } catch {
            $Status.Text = "X Fallo descargando $($f.path): $($_.Exception.Message)"
            Remove-Item $tmp -ErrorAction SilentlyContinue
            $script:UpdateStateOk = $false
            return
        }

        $newHash = Get-FileHashSafe -Path $tmp
        if ($newHash -ne $f.sha256.ToLowerInvariant()) {
            $Status.Text = "X Hash mismatch en $($f.path) tras descargar."
            Remove-Item $tmp -ErrorAction SilentlyContinue
            $script:UpdateStateOk = $false
            return
        }

        try {
            # Swap atomico (replace si existe)
            Move-Item -LiteralPath $tmp -Destination $localPath -Force
        } catch {
            $Status.Text = "X No pude reemplazar $($f.path) (archivo en uso?): $($_.Exception.Message)"
            $script:UpdateStateOk = $false
            return
        }
    }

    $Status.Text = "Actualizado $($diffs.Count) archivo(s). Listo."
    $script:UpdateStateOk = $true
}

function Try-TypeLogin {
    param([System.Diagnostics.Process]$Process, [string]$Username)
    if ([string]::IsNullOrWhiteSpace($Username)) { return }
    $shell = New-Object -ComObject WScript.Shell
    $deadline = (Get-Date).AddSeconds(12)
    while ((Get-Date) -lt $deadline) {
        $Process.Refresh()
        if ($Process.HasExited) { return }
        if ($shell.AppActivate($Process.Id)) {
            [System.Windows.Forms.SendKeys]::SendWait($Username); return
        }
        Start-Sleep -Milliseconds 400
    }
}

if ($SelfTest) {
    $config = Get-LauncherConfig
    Save-ClientSettings -Config $config
    $reg = Get-ItemProperty -Path $script:RegistryPath
    [pscustomobject]@{
        ClientPath = $config.ClientPath; Username = $config.Username
        VolumeLevel = $reg.VolumeLevel; SoundOnOff = $reg.SoundOnOff
        MusicOnOff = $reg.MusicOnOff; WindowMode = $reg.WindowMode
        Resolution = $reg.Resolution; ID = $reg.ID
        UpdateUrl = $config.UpdateUrl
    } | Format-List | Out-String | Write-Host
    exit 0
}

$config = Get-LauncherConfig

$form = New-Object System.Windows.Forms.Form
$form.Text = 'MU Launcher'
$form.Size = New-Object System.Drawing.Size(460, 480)
$form.StartPosition = 'CenterScreen'
$form.FormBorderStyle = 'FixedDialog'
$form.MaximizeBox = $false

$titleLabel = New-Object System.Windows.Forms.Label
$titleLabel.Text = 'Cliente MU'
$titleLabel.Font = New-Object System.Drawing.Font('Segoe UI', 16, [System.Drawing.FontStyle]::Bold)
$titleLabel.Location = New-Object System.Drawing.Point(20, 14); $titleLabel.Size = New-Object System.Drawing.Size(200, 34)

$userLabel = New-Object System.Windows.Forms.Label
$userLabel.Text = 'Login'; $userLabel.Location = New-Object System.Drawing.Point(20, 62); $userLabel.Size = New-Object System.Drawing.Size(80, 22)
$userBox = New-Object System.Windows.Forms.TextBox
$userBox.Location = New-Object System.Drawing.Point(110, 58); $userBox.Size = New-Object System.Drawing.Size(300, 24); $userBox.Text = [string]$config.Username

$resLabel = New-Object System.Windows.Forms.Label
$resLabel.Text = 'Resolucion'; $resLabel.Location = New-Object System.Drawing.Point(20, 96); $resLabel.Size = New-Object System.Drawing.Size(80, 22)
$resCombo = New-Object System.Windows.Forms.ComboBox
$resCombo.Location = New-Object System.Drawing.Point(110, 92); $resCombo.Size = New-Object System.Drawing.Size(300, 24); $resCombo.DropDownStyle = 'DropDownList'
foreach ($r in $script:Resolutions) { [void]$resCombo.Items.Add($r.Label) }
$selIndex = 0
for ($i = 0; $i -lt $script:Resolutions.Count; $i++) {
    if ($script:Resolutions[$i].Value -eq [int]$config.Resolution) { $selIndex = $i; break }
}
$resCombo.SelectedIndex = $selIndex

$volumeLabel = New-Object System.Windows.Forms.Label
$volumeLabel.Text = 'Volumen'; $volumeLabel.Location = New-Object System.Drawing.Point(20, 130); $volumeLabel.Size = New-Object System.Drawing.Size(80, 22)
$volumeBar = New-Object System.Windows.Forms.TrackBar
$volumeBar.Location = New-Object System.Drawing.Point(110, 120); $volumeBar.Size = New-Object System.Drawing.Size(240, 45)
$volumeBar.Minimum = 0; $volumeBar.Maximum = 10; $volumeBar.TickFrequency = 1
$volumeBar.Value = [Math]::Max(0, [Math]::Min(10, [int]$config.VolumeLevel))
$volumeValue = New-Object System.Windows.Forms.Label
$volumeValue.Text = [string]$volumeBar.Value; $volumeValue.Location = New-Object System.Drawing.Point(360, 130); $volumeValue.Size = New-Object System.Drawing.Size(50, 22)

$soundCheck = New-Object System.Windows.Forms.CheckBox
$soundCheck.Text = 'Sound'; $soundCheck.Location = New-Object System.Drawing.Point(24, 170); $soundCheck.Size = New-Object System.Drawing.Size(80, 24); $soundCheck.Checked = [bool]$config.SoundOn
$musicCheck = New-Object System.Windows.Forms.CheckBox
$musicCheck.Text = 'Music'; $musicCheck.Location = New-Object System.Drawing.Point(120, 170); $musicCheck.Size = New-Object System.Drawing.Size(80, 24); $musicCheck.Checked = [bool]$config.MusicOn
$windowCheck = New-Object System.Windows.Forms.CheckBox
$windowCheck.Text = 'Modo ventana'; $windowCheck.Location = New-Object System.Drawing.Point(220, 170); $windowCheck.Size = New-Object System.Drawing.Size(130, 24); $windowCheck.Checked = [bool]$config.WindowMode

$forceTypeCheck = New-Object System.Windows.Forms.CheckBox
$forceTypeCheck.Text = 'Forzar escritura del login al abrir'
$forceTypeCheck.Location = New-Object System.Drawing.Point(24, 200); $forceTypeCheck.Size = New-Object System.Drawing.Size(280, 24); $forceTypeCheck.Checked = [bool]$config.ForceTypeLogin

$clientPathLabel = New-Object System.Windows.Forms.Label
$clientPathLabel.Text = 'Cliente'; $clientPathLabel.Location = New-Object System.Drawing.Point(20, 234); $clientPathLabel.Size = New-Object System.Drawing.Size(80, 22)
$clientPathBox = New-Object System.Windows.Forms.TextBox
$clientPathBox.Location = New-Object System.Drawing.Point(110, 230); $clientPathBox.Size = New-Object System.Drawing.Size(300, 24); $clientPathBox.Text = [string]$config.ClientPath

$updateUrlLabel = New-Object System.Windows.Forms.Label
$updateUrlLabel.Text = 'Update URL'; $updateUrlLabel.Location = New-Object System.Drawing.Point(20, 266); $updateUrlLabel.Size = New-Object System.Drawing.Size(80, 22)
$updateUrlBox = New-Object System.Windows.Forms.TextBox
$updateUrlBox.Location = New-Object System.Drawing.Point(110, 262); $updateUrlBox.Size = New-Object System.Drawing.Size(300, 24); $updateUrlBox.Text = [string]$config.UpdateUrl

$progressBar = New-Object System.Windows.Forms.ProgressBar
$progressBar.Location = New-Object System.Drawing.Point(20, 298); $progressBar.Size = New-Object System.Drawing.Size(390, 16)

$status = New-Object System.Windows.Forms.Label
$status.Text = 'Listo'; $status.Location = New-Object System.Drawing.Point(20, 320); $status.Size = New-Object System.Drawing.Size(420, 36); $status.Font = New-Object System.Drawing.Font('Segoe UI', 8)

$saveButton = New-Object System.Windows.Forms.Button
$saveButton.Text = 'Guardar'; $saveButton.Location = New-Object System.Drawing.Point(20, 392); $saveButton.Size = New-Object System.Drawing.Size(100, 32)
$updateButton = New-Object System.Windows.Forms.Button
$updateButton.Text = 'Verificar update'; $updateButton.Location = New-Object System.Drawing.Point(130, 392); $updateButton.Size = New-Object System.Drawing.Size(120, 32)
$launchButton = New-Object System.Windows.Forms.Button
$launchButton.Text = 'Jugar'; $launchButton.Location = New-Object System.Drawing.Point(260, 392); $launchButton.Size = New-Object System.Drawing.Size(80, 32)
$launchButton.Enabled = $true   # siempre habilitado; update no bloquea
$closeButton = New-Object System.Windows.Forms.Button
$closeButton.Text = 'Cerrar'; $closeButton.Location = New-Object System.Drawing.Point(350, 392); $closeButton.Size = New-Object System.Drawing.Size(80, 32)

$volumeBar.Add_ValueChanged({ $volumeValue.Text = [string]$volumeBar.Value })

$saveAction = {
    $resValue = $script:Resolutions[$resCombo.SelectedIndex].Value
    $current = [pscustomobject]@{
        ClientPath = $clientPathBox.Text.Trim()
        WindowTitle = $config.WindowTitle
        Username = $userBox.Text.Trim()
        VolumeLevel = [int]$volumeBar.Value
        SoundOn = [bool]$soundCheck.Checked
        MusicOn = [bool]$musicCheck.Checked
        WindowMode = [bool]$windowCheck.Checked
        Resolution = [int]$resValue
        ForceTypeLogin = [bool]$forceTypeCheck.Checked
        UpdateUrl = $updateUrlBox.Text.Trim()
        SkipUpdate = [bool]$config.SkipUpdate
    }
    if (-not (Test-Path $current.ClientPath)) { throw "No existe el cliente: $($current.ClientPath)" }
    Save-ClientSettings -Config $current
    Save-LauncherConfig -Config $current
    Apply-CompatLayer -ExePath $current.ClientPath
    $script:SavedLauncherConfig = $current
    $status.Text = 'Config guardada.'
}

$runUpdateAction = {
    & $saveAction
    Run-AutoUpdate -ManifestUrl $script:SavedLauncherConfig.UpdateUrl -Status $status -Progress $progressBar
    # Jugar siempre habilitado, update es informativo
    if (-not $script:UpdateStateOk) {
        $status.Text += " | Update fallo - igual podes jugar."
    }
}

$saveButton.Add_Click({
    try { & $saveAction } catch { [System.Windows.Forms.MessageBox]::Show($_.Exception.Message,'MU Launcher','OK','Error') | Out-Null }
})
$updateButton.Add_Click({
    try { & $runUpdateAction } catch { [System.Windows.Forms.MessageBox]::Show($_.Exception.Message,'MU Launcher','OK','Error') | Out-Null }
})
$launchButton.Add_Click({
    try {
        & $saveAction
        $process = Start-Process -FilePath $script:SavedLauncherConfig.ClientPath -WorkingDirectory (Split-Path $script:SavedLauncherConfig.ClientPath) -PassThru
        $status.Text = "Cliente iniciado. PID $($process.Id)"
        if ($script:SavedLauncherConfig.ForceTypeLogin) {
            Try-TypeLogin -Process $process -Username $script:SavedLauncherConfig.Username
        }
    } catch { [System.Windows.Forms.MessageBox]::Show($_.Exception.Message,'MU Launcher','OK','Error') | Out-Null }
})
$closeButton.Add_Click({ $form.Close() })

$form.Controls.AddRange(@(
    $titleLabel, $userLabel, $userBox,
    $resLabel, $resCombo,
    $volumeLabel, $volumeBar, $volumeValue,
    $soundCheck, $musicCheck, $windowCheck,
    $forceTypeCheck,
    $clientPathLabel, $clientPathBox,
    $updateUrlLabel, $updateUrlBox,
    $progressBar, $status,
    $saveButton, $updateButton, $launchButton, $closeButton
))

# Auto-update al abrir si hay UpdateUrl configurada
$form.Add_Shown({
    # Jugar siempre habilitado. Update corre en background si hay URL.
    if (-not [string]::IsNullOrWhiteSpace($config.UpdateUrl) -and -not $config.SkipUpdate) {
        try {
            $script:SavedLauncherConfig = $config
            Run-AutoUpdate -ManifestUrl $config.UpdateUrl -Status $status -Progress $progressBar
            if (-not $script:UpdateStateOk) {
                $status.Text += " | (igual podes jugar)"
            }
        } catch {
            $status.Text = "Update fallo: $($_.Exception.Message) - igual podes jugar"
        }
    } else {
        $script:UpdateStateOk = $true
        $status.Text = 'Listo (sin URL de update configurada)'
    }
})

[void]$form.ShowDialog()
