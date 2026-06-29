<#
.SYNOPSIS
    Plaud Exporter - WinForms GUI (Phase 4: download engine + branding).

.DESCRIPTION
    Sign in/out, list recordings with per-row checkboxes and Transcript/Summary/Notes/Audio
    availability (filled in the background), then download the selected artifact types for
    the selected recordings in parallel.

    Threading: all network work (session check, login, list, availability, downloads,
    logout) runs on background runspaces. A single UI-thread Timer harvests finished jobs
    and is the only code that touches the grid. Availability uses a shared pool (max 6);
    downloads use a dedicated pool sized to the configured max-parallel.

    Layout uses a root TableLayoutPanel (top bar / toolbar / grid / footer / status) so the
    logo, footer and copyright land deterministically regardless of control z-order.

    The window/taskbar icon is embedded as base64 in src\PlaudIcon.ps1 (self-contained);
    assets\appicon.ico is the full-resolution icon used when compiling the EXE (Phase 5).

.NOTES
    Windows PowerShell 5.1 compatible, ASCII-only source. Run from a normal PowerShell
    console (not the ISE - its message loop conflicts with Application.Run).

    Icon attribution: "Radio" icons created by Freepik - Flaticon
    (https://www.flaticon.com/free-icons/radio).
#>

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()
[System.Windows.Forms.Application]::SetCompatibleTextRenderingDefault($false)

# --- Single-file support ---
# When compiled to a standalone EXE, the build prepends a base64 payload
# ($script:PlaudEmbeddedPayload) holding src\ and assets\. Unpack it to a per-user folder
# (%LOCALAPPDATA%\PlaudExporter\runtime) and run from there, re-extracting only when the
# embedded payload changes (detected via a stored signature) - so subsequent launches are
# fast and nothing lands in shared/system locations. In dev (.ps1) mode the variable is
# absent and we run from the script's own folder.
$script:RuntimeRoot = $null
$payloadVar = Get-Variable -Name PlaudEmbeddedPayload -Scope Script -ErrorAction SilentlyContinue
if ($payloadVar -and $payloadVar.Value) {
    try {
        Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue

        # Per-user base: %LOCALAPPDATA% -> %APPDATA% -> %TEMP%.
        $baseDir = $env:LOCALAPPDATA
        if (-not $baseDir) { $baseDir = $env:APPDATA }
        if (-not $baseDir) { $baseDir = $env:TEMP }
        $runDir  = Join-Path $baseDir 'PlaudExporter\runtime'
        $sigFile = Join-Path $runDir 'payload.sig'

        # Signature of the embedded payload; used to decide whether a re-extract is needed.
        $sha = [System.Security.Cryptography.SHA256]::Create()
        try { $hashBytes = $sha.ComputeHash([System.Text.Encoding]::ASCII.GetBytes([string]$payloadVar.Value)) }
        finally { $sha.Dispose() }
        $sig = -join ($hashBytes | ForEach-Object { $_.ToString('x2') })

        # Reuse the existing extraction when the signature matches and a key file is present.
        $marker  = Join-Path $runDir 'src\PlaudAuth.psm1'
        $current = ''
        if (Test-Path -LiteralPath $sigFile) { try { $current = (Get-Content -LiteralPath $sigFile -Raw).Trim() } catch { } }
        $needExtract = -not ((Test-Path -LiteralPath $marker) -and ($current -eq $sig))

        if ($needExtract) {
            if (Test-Path -LiteralPath $runDir) { Remove-Item -LiteralPath $runDir -Recurse -Force -ErrorAction SilentlyContinue }
            New-Item -ItemType Directory -Path $runDir -Force | Out-Null
            $zipTmp = Join-Path $runDir '_payload.zip'
            [System.IO.File]::WriteAllBytes($zipTmp, [Convert]::FromBase64String(($payloadVar.Value -replace '\s', '')))
            [System.IO.Compression.ZipFile]::ExtractToDirectory($zipTmp, $runDir)
            Remove-Item -LiteralPath $zipTmp -Force -ErrorAction SilentlyContinue
            Set-Content -LiteralPath $sigFile -Value $sig -Encoding ASCII
        }
        $script:RuntimeRoot = $runDir
    } catch {
        [System.Windows.Forms.MessageBox]::Show(('Failed to unpack embedded resources:' + "`r`n" + $_.Exception.Message), 'Plaud Exporter', 'OK', 'Error') | Out-Null
        return
    }
}

# --- Paths + modules ---
# Prefer the unpacked runtime folder (single-file EXE); else the script folder ($PSScriptRoot);
# else the running executable's folder; else the current directory.
$script:ScriptRoot = $script:RuntimeRoot
if (-not $script:ScriptRoot) { $script:ScriptRoot = $PSScriptRoot }
if (-not $script:ScriptRoot) {
    try {
        $exe = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
        if ($exe -and (Test-Path -LiteralPath $exe)) { $script:ScriptRoot = Split-Path -Parent $exe }
    } catch { }
}
if (-not $script:ScriptRoot) { $script:ScriptRoot = (Get-Location).Path }
$script:AuthPath      = Join-Path $script:ScriptRoot 'src\PlaudAuth.psm1'
$script:DataPath      = Join-Path $script:ScriptRoot 'src\PlaudData.psm1'
$script:ConfigPath    = Join-Path $script:ScriptRoot 'src\PlaudConfig.psm1'
$script:DownloadPath  = Join-Path $script:ScriptRoot 'src\PlaudDownload.psm1'
$script:IconDataFile  = Join-Path $script:ScriptRoot 'src\PlaudIcon.ps1'
foreach ($p in @($script:AuthPath, $script:DataPath, $script:ConfigPath, $script:DownloadPath)) {
    if (-not (Test-Path -LiteralPath $p)) { throw "Required module not found: $p" }
}
Import-Module $script:AuthPath    -Force
Import-Module $script:DataPath    -Force
Import-Module $script:ConfigPath  -Force
Import-Module $script:DownloadPath -Force
# Embedded icon data (defines $script:AppIconBase64). Optional - app still runs without it.
if (Test-Path -LiteralPath $script:IconDataFile) { . $script:IconDataFile }

# --- Branding constants (edit these to taste) ---
$script:AppName        = 'Plaud Exporter'
$script:AppGitHubUrl   = 'https://github.com/kevinshoaf/PlaudExporter'   # <-- confirm/change
$script:AppLogoFile    = Join-Path $script:ScriptRoot 'assets\logo.png'
$script:AppIconFile    = Join-Path $script:ScriptRoot 'assets\appicon.ico'
$script:AppCopyright   = '{0} {1} Kevin Shoaf. All rights reserved.' -f [char]0x00A9, (Get-Date).Year
$script:IconAttribUrl  = 'https://www.flaticon.com/free-icons/radio'
$script:IconAttribText = 'Radio icons created by Freepik - Flaticon'
$script:AppVersion     = '1.0'
# About / legal text. Plaud Inc. is the trademark owner (Delaware-incorporated, San Francisco).
$script:AppDisclaimer  = @(
    'Plaud Exporter is an unofficial, independent tool. It is not affiliated with, authorized',
    'by, endorsed by, or sponsored by Plaud Inc.',
    '',
    'Plaud is a trademark of Plaud Inc. All other product and company names are the property',
    'of their respective owners.',
    '',
    'This app uses Plaud''s API and OAuth on your behalf. Your use of Plaud''s services through',
    'this app is subject to Plaud''s Terms of Service, and you are solely responsible for',
    'complying with them.',
    '',
    'The project''s open-source license (see the LICENSE file) covers this app''s source code',
    'only. It grants no rights to Plaud''s services, data, accounts, or trademarks.',
    '',
    'App icon: "Radio" icons created by Freepik - Flaticon.'
) -join "`r`n"

# --- Theme colors ---
$script:ClrWhite  = [System.Drawing.Color]::White
$script:ClrBlack  = [System.Drawing.Color]::Black
$script:ClrHover  = [System.Drawing.Color]::FromArgb(45, 45, 45)
$script:ClrLink   = [System.Drawing.Color]::FromArgb(0, 102, 204)
$script:ClrMuted  = [System.Drawing.Color]::FromArgb(90, 90, 90)
$script:ClrOkRow  = [System.Drawing.Color]::FromArgb(223, 240, 216)
$script:ClrBadRow = [System.Drawing.Color]::FromArgb(242, 222, 222)
$script:ClrGreen  = [System.Drawing.Color]::FromArgb(0, 128, 0)
$script:ClrGray   = [System.Drawing.Color]::Gray

# --- Shared state ---
$script:Config        = Get-PlaudConfig
$script:Pool          = $null
$script:DownloadPool  = $null
$script:Jobs          = New-Object System.Collections.ArrayList
$script:RowById       = @{}
$script:Recordings    = @()
$script:Token         = $null
$script:AppIcon       = $null
$script:FilterFrom    = $null
$script:FilterTo      = $null
$script:SuppressFilterEvents = $false
$script:AvailTotal    = 0
$script:AvailDone     = 0
$script:LoggedIn      = $false
$script:DlTotal       = 0
$script:DlDone        = 0
$script:DlSaved       = 0
$script:DlSkipped     = 0
$script:DlFailed      = 0
$script:DlRoot        = ''
$script:DlFailureList = New-Object System.Collections.ArrayList

# ---------------------------------------------------------------------------
# Region: Background job plumbing
# ---------------------------------------------------------------------------

function Initialize-PlaudPool {
    if ($script:Pool) { return }
    $script:Pool = [runspacefactory]::CreateRunspacePool(1, 6)
    $script:Pool.Open()
}

function Start-PlaudJob {
    param(
        [Parameter(Mandatory = $true)][string]$Kind,
        [Parameter(Mandatory = $true)][scriptblock]$Script,
        [object[]]$Arguments = @(),
        [string]$Id = $null,
        $Pool = $null
    )
    if (-not $Pool) { Initialize-PlaudPool; $Pool = $script:Pool }
    $ps = [powershell]::Create()
    $ps.RunspacePool = $Pool
    [void]$ps.AddScript($Script)
    foreach ($a in $Arguments) { [void]$ps.AddArgument($a) }
    $handle = $ps.BeginInvoke()
    [void]$script:Jobs.Add([pscustomobject]@{ Kind = $Kind; Id = $Id; PS = $ps; Handle = $handle })
}

$script:SbSession = {
    param($authPath)
    if (-not (Get-Command Get-PlaudCurrentUser -ErrorAction SilentlyContinue)) { Import-Module $authPath -Force }
    Get-PlaudCurrentUser
}
$script:SbLogin = {
    param($authPath)
    if (-not (Get-Command Connect-PlaudAccount -ErrorAction SilentlyContinue)) { Import-Module $authPath -Force }
    Connect-PlaudAccount
}
$script:SbLogout = {
    param($authPath)
    if (-not (Get-Command Disconnect-PlaudAccount -ErrorAction SilentlyContinue)) { Import-Module $authPath -Force }
    Disconnect-PlaudAccount
}
$script:SbList = {
    param($authPath, $dataPath, $token, $dateFrom, $dateTo)
    if (-not (Get-Command Get-PlaudRecordingList -ErrorAction SilentlyContinue)) {
        Import-Module $authPath -Force; Import-Module $dataPath -Force
    }
    Get-PlaudRecordingList -AccessToken $token -DateFrom $dateFrom -DateTo $dateTo
}
$script:SbAvail = {
    param($authPath, $dataPath, $token, $id)
    if (-not (Get-Command Get-PlaudRecordingAvailability -ErrorAction SilentlyContinue)) {
        Import-Module $authPath -Force; Import-Module $dataPath -Force
    }
    try { Get-PlaudRecordingAvailability -Id $id -AccessToken $token }
    catch { [pscustomobject]@{ Id = $id; Error = $_.Exception.Message } }
}
$script:SbDownload = {
    param($authPath, $dataPath, $downloadPath, $token, $id, $root, $types, $overwrite)
    if (-not (Get-Command Invoke-PlaudRecordingDownload -ErrorAction SilentlyContinue)) {
        Import-Module $authPath -Force; Import-Module $dataPath -Force; Import-Module $downloadPath -Force
    }
    try {
        Invoke-PlaudRecordingDownload -Id $id -DownloadRoot $root -Types $types -AccessToken $token -Overwrite:$overwrite
    } catch {
        [pscustomobject]@{
            Id = $id; Name = $id; Folder = $root
            SavedCount = 0; SkippedCount = 0; FailedCount = 1
            Saved = @(); Skipped = @()
            Failures = @([pscustomobject]@{ Name = '(recording)'; Error = $_.Exception.Message })
        }
    }
}

# ---------------------------------------------------------------------------
# Region: UI helpers
# ---------------------------------------------------------------------------

function Set-Status { param([string]$Text) $script:StatusLabel.Text = $Text }

function Show-Progress {
    param([int]$Done, [int]$Total)
    if ($Total -le 0) { $script:ProgressBar.Visible = $false; return }
    $script:ProgressBar.Visible = $true
    $script:ProgressBar.Maximum = $Total
    $script:ProgressBar.Value   = [Math]::Min($Done, $Total)
}

function Format-WhenForDisplay {
    param([string]$When)
    $dt = [datetime]::MinValue
    if ([datetime]::TryParse($When, [ref]$dt)) { return $dt.ToString('yyyy-MM-dd HH:mm') }
    return $When
}

function Set-BlackButtonStyle {
    param($Button)
    $Button.BackColor = $script:ClrBlack
    $Button.ForeColor = $script:ClrWhite
    $Button.FlatStyle = 'Flat'
    $Button.FlatAppearance.BorderColor = $script:ClrBlack
    $Button.FlatAppearance.MouseOverBackColor = $script:ClrHover
    $Button.UseVisualStyleBackColor = $false
}

function Get-AppIcon {
    # Builds a System.Drawing.Icon from the embedded base64, or $null if unavailable.
    if (-not $script:AppIconBase64) { return $null }
    try {
        $bytes = [Convert]::FromBase64String(($script:AppIconBase64 -replace '\s', ''))
        $ms = New-Object System.IO.MemoryStream(, $bytes)
        return New-Object System.Drawing.Icon($ms)
    } catch { return $null }
}

function Set-LogoImage {
    # Prefer assets\logo.png; otherwise fall back to the embedded app icon.
    param($PictureBox)
    if (Test-Path -LiteralPath $script:AppLogoFile) {
        try {
            $bytes = [System.IO.File]::ReadAllBytes($script:AppLogoFile)
            $ms = New-Object System.IO.MemoryStream(, $bytes)
            $PictureBox.Image = [System.Drawing.Image]::FromStream($ms)
            return
        } catch { }
    }
    if ($script:AppIcon) { try { $PictureBox.Image = $script:AppIcon.ToBitmap() } catch { } }
}

# ---------------------------------------------------------------------------
# Region: Grid population + availability updates
# ---------------------------------------------------------------------------

function Add-RecordingRow {
    param($Recording)
    $idx = $script:Grid.Rows.Add()
    $row = $script:Grid.Rows[$idx]
    $row.Cells['Sel'].Value        = $false
    $row.Cells['When'].Value       = (Format-WhenForDisplay $Recording.When)
    $row.Cells['Length'].Value     = $Recording.DurationText
    $row.Cells['Name'].Value       = $Recording.Name
    $row.Cells['Transcript'].Value = '...'
    $row.Cells['Summary'].Value    = '...'
    $row.Cells['Notes'].Value      = '...'
    $row.Cells['Audio'].Value      = '...'
    $row.Cells['Tabs'].Value       = ''
    $row.Cells['Id'].Value         = $Recording.Id
    $script:RowById[$Recording.Id] = $row
}

function Set-AvailabilityCell {
    param($Cell, [bool]$Available)
    if ($Available) { $Cell.Value = 'Yes'; $Cell.Style.ForeColor = $script:ClrGreen }
    else { $Cell.Value = '-'; $Cell.Style.ForeColor = $script:ClrGray }
}

function Update-RowAvailability {
    param($Availability)
    $row = $script:RowById[$Availability.Id]
    if (-not $row) { return }
    Set-AvailabilityCell -Cell $row.Cells['Transcript'] -Available $Availability.Transcript
    Set-AvailabilityCell -Cell $row.Cells['Summary']    -Available $Availability.Summary
    Set-AvailabilityCell -Cell $row.Cells['Notes']      -Available $Availability.Notes
    Set-AvailabilityCell -Cell $row.Cells['Audio']      -Available $Availability.Audio
    if ($Availability.NoteTabCount -gt 0) {
        $row.Cells['Tabs'].Value = [string]$Availability.NoteTabCount
        $row.Cells['Notes'].ToolTipText = (@($Availability.NoteTabNames) -join ', ')
    } else {
        $row.Cells['Tabs'].Value = ''
    }
}

function Set-RowAvailabilityError {
    param([string]$Id)
    $row = $script:RowById[$Id]
    if (-not $row) { return }
    foreach ($c in 'Transcript', 'Summary', 'Notes', 'Audio') {
        $row.Cells[$c].Value = '?'
        $row.Cells[$c].Style.ForeColor = [System.Drawing.Color]::DarkOrange
    }
}

function Set-RowDownloadColor {
    param([string]$Id, [bool]$Ok)
    $row = $script:RowById[$Id]
    if (-not $row) { return }
    if ($Ok) { $row.DefaultCellStyle.BackColor = $script:ClrOkRow }
    else { $row.DefaultCellStyle.BackColor = $script:ClrBadRow }
}

# ---------------------------------------------------------------------------
# Region: Workflow actions
# ---------------------------------------------------------------------------

function Set-LoggedInUi {
    param($User)
    $script:LoggedIn = $true
    $name = if ($User.nickname) { $User.nickname } elseif ($User.email) { $User.email } else { 'Signed in' }
    $script:AccountLabel.Text = ('Signed in: {0}' -f $name)
    $script:BtnLogin.Visible  = $false
    $script:BtnLogout.Visible = $true
    $script:BtnRefresh.Enabled = $true
    Set-FilterControlsEnabled $true
}

function Reset-LoggedOutUi {
    param([string]$StatusText = 'Not signed in')
    $script:LoggedIn = $false
    $script:AccountLabel.Text = 'Not signed in'
    $script:BtnLogin.Visible  = $true
    $script:BtnLogin.Enabled  = $true
    $script:BtnLogout.Visible = $false
    $script:BtnRefresh.Enabled = $false
    $script:Grid.Rows.Clear()
    $script:RowById = @{}
    Reset-FilterToAll
    Set-FilterControlsEnabled $false
    Show-Progress -Done 0 -Total 0
    Set-Status $StatusText
}

function Start-SessionCheck {
    Set-Status 'Checking session...'
    Start-PlaudJob -Kind 'session' -Script $script:SbSession -Arguments @($script:AuthPath)
}

function Start-Login {
    $script:BtnLogin.Enabled = $false
    Set-Status 'Opening your browser to sign in to Plaud...'
    Start-PlaudJob -Kind 'login' -Script $script:SbLogin -Arguments @($script:AuthPath)
}

function Start-Logout {
    Set-Status 'Signing out...'
    Start-PlaudJob -Kind 'logout' -Script $script:SbLogout -Arguments @($script:AuthPath)
}

function Start-ListLoad {
    $filtered = ($script:FilterFrom -or $script:FilterTo)
    $loadMsg = if ($filtered) { 'Loading recordings (date filter applied)...' } else { 'Loading recordings...' }
    Set-Status $loadMsg
    $script:Grid.Rows.Clear()
    $script:RowById = @{}
    $script:Token = Get-PlaudAccessToken
    if (-not $script:Token) { Reset-LoggedOutUi 'Session expired. Please sign in again.'; return }
    Start-PlaudJob -Kind 'list' -Script $script:SbList `
        -Arguments @($script:AuthPath, $script:DataPath, $script:Token, $script:FilterFrom, $script:FilterTo)
}

function Set-FilterPickersEnabled {
    param([bool]$Enabled)
    $script:DtpFrom.Enabled = $Enabled
    $script:DtpTo.Enabled   = $Enabled
}

function Set-FilterControlsEnabled {
    param([bool]$Enabled)
    $script:CmbPreset.Enabled      = $Enabled
    $script:BtnApplyFilter.Enabled = $Enabled
    $script:BtnClearFilter.Enabled = $Enabled
    # Pickers are editable only in Custom mode (and only while controls are enabled).
    $custom = ($Enabled -and ([string]$script:CmbPreset.SelectedItem -eq 'Custom'))
    Set-FilterPickersEnabled $custom
}

function Get-PresetRange {
    # Returns @($from, $to) as dates for a named preset, or @($null, $null) for All/unknown.
    param([string]$Preset)
    $today = (Get-Date).Date
    switch ($Preset) {
        'Today'        { return @($today, $today) }
        'Last 7 days'  { return @($today.AddDays(-6), $today) }
        'Last 30 days' { return @($today.AddDays(-29), $today) }
        'This month'   { return @((Get-Date -Day 1).Date, $today) }
        default        { return @($null, $null) }
    }
}

function Invoke-PresetChanged {
    if ($script:SuppressFilterEvents) { return }
    $sel = [string]$script:CmbPreset.SelectedItem
    if ($sel -eq 'All') {
        $script:FilterFrom = $null; $script:FilterTo = $null
        Set-FilterPickersEnabled $false
        if ($script:LoggedIn) { Start-ListLoad }
        return
    }
    if ($sel -eq 'Custom') {
        Set-FilterPickersEnabled $true     # wait for the user to click Apply
        return
    }
    $range = Get-PresetRange -Preset $sel
    $from = $range[0]; $to = $range[1]
    $script:SuppressFilterEvents = $true
    if ($from) { $script:DtpFrom.Value = $from }
    if ($to)   { $script:DtpTo.Value   = $to }
    $script:SuppressFilterEvents = $false
    $script:FilterFrom = $from; $script:FilterTo = $to
    Set-FilterPickersEnabled $false
    if ($script:LoggedIn) { Start-ListLoad }
}

function Invoke-ApplyFilter {
    $from = $script:DtpFrom.Value.Date
    $to   = $script:DtpTo.Value.Date
    if ($from -gt $to) {
        $tmp = $from; $from = $to; $to = $tmp
        $script:SuppressFilterEvents = $true
        $script:DtpFrom.Value = $from; $script:DtpTo.Value = $to
        $script:SuppressFilterEvents = $false
    }
    $script:FilterFrom = $from; $script:FilterTo = $to
    if ([string]$script:CmbPreset.SelectedItem -ne 'Custom') {
        $script:SuppressFilterEvents = $true
        $script:CmbPreset.SelectedItem = 'Custom'
        $script:SuppressFilterEvents = $false
        Set-FilterPickersEnabled $true
    }
    if ($script:LoggedIn) { Start-ListLoad }
}

function Reset-FilterToAll {
    # Used on sign-out: silently return the filter to 'All' without triggering a reload.
    $script:SuppressFilterEvents = $true
    $script:CmbPreset.SelectedItem = 'All'
    $script:SuppressFilterEvents = $false
    $script:FilterFrom = $null; $script:FilterTo = $null
    Set-FilterPickersEnabled $false
}

function Start-AvailabilityFill {
    $script:AvailTotal = @($script:Recordings).Count
    $script:AvailDone  = 0
    if ($script:AvailTotal -eq 0) { Set-Status 'No recordings found.'; return }
    Show-Progress -Done 0 -Total $script:AvailTotal
    Set-Status ('Checking availability 0/{0}...' -f $script:AvailTotal)
    foreach ($r in $script:Recordings) {
        Start-PlaudJob -Kind 'avail' -Id $r.Id -Script $script:SbAvail `
            -Arguments @($script:AuthPath, $script:DataPath, $script:Token, $r.Id)
    }
}

function Get-SelectedRecordingIds {
    $ids = New-Object System.Collections.ArrayList
    foreach ($row in $script:Grid.Rows) {
        if ([bool]$row.Cells['Sel'].Value -eq $true) { [void]$ids.Add([string]$row.Cells['Id'].Value) }
    }
    return $ids
}

function Get-SelectedArtifactTypes {
    $types = New-Object System.Collections.ArrayList
    if ($script:ChkTranscript.Checked) { [void]$types.Add('Transcript') }
    if ($script:ChkSummary.Checked)    { [void]$types.Add('Summary') }
    if ($script:ChkNotes.Checked)      { [void]$types.Add('Notes') }
    if ($script:ChkAudio.Checked)      { [void]$types.Add('Audio') }
    if ($script:ChkPolished.Checked)   { [void]$types.Add('PolishedTranscript') }
    if ($script:ChkOutline.Checked)    { [void]$types.Add('Outline') }
    return $types
}

function Save-CurrentSelectionToConfig {
    $script:Config.ArtifactTypes.Transcript = $script:ChkTranscript.Checked
    $script:Config.ArtifactTypes.Summary    = $script:ChkSummary.Checked
    $script:Config.ArtifactTypes.Notes      = $script:ChkNotes.Checked
    $script:Config.ArtifactTypes.Audio      = $script:ChkAudio.Checked
    $script:Config.ArtifactTypes.Polished   = $script:ChkPolished.Checked
    $script:Config.ArtifactTypes.Outline    = $script:ChkOutline.Checked
    $script:Config.Overwrite                = $script:ChkOverwrite.Checked
    Save-PlaudConfig -Config $script:Config
}

function Set-DownloadControlsEnabled {
    param([bool]$Enabled)
    $script:BtnDownload.Enabled = $Enabled
    $script:BtnRefresh.Enabled  = ($Enabled -and $script:LoggedIn)
    $script:BtnLogout.Enabled   = $Enabled
    $script:BtnSelAll.Enabled   = $Enabled
    $script:BtnSelNone.Enabled  = $Enabled
    Set-FilterControlsEnabled $Enabled
}

function Invoke-DownloadStart {
    $ids   = @(Get-SelectedRecordingIds)
    $types = [string[]]@(Get-SelectedArtifactTypes)
    if ($ids.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show('Select at least one recording first.', 'Nothing selected', 'OK', 'Information') | Out-Null
        return
    }
    if ($types.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show('Select at least one artifact type to download.', 'Nothing to download', 'OK', 'Information') | Out-Null
        return
    }

    Save-CurrentSelectionToConfig
    $script:Token = Get-PlaudAccessToken
    if (-not $script:Token) { Reset-LoggedOutUi 'Session expired. Please sign in again.'; return }

    $root = $script:Config.DownloadPath
    try {
        if (-not (Test-Path -LiteralPath $root)) { New-Item -ItemType Directory -Path $root -Force | Out-Null }
    } catch {
        [System.Windows.Forms.MessageBox]::Show(('Cannot create download folder:' + "`r`n" + $root + "`r`n`r`n" + $_.Exception.Message),
            'Download folder error', 'OK', 'Error') | Out-Null
        return
    }

    $overwrite = [bool]$script:ChkOverwrite.Checked
    $maxPar    = [int]$script:Config.MaxParallel
    if ($maxPar -lt 1) { $maxPar = 1 }

    $script:DownloadPool = [runspacefactory]::CreateRunspacePool(1, $maxPar)
    $script:DownloadPool.Open()

    $script:DlTotal = $ids.Count
    $script:DlDone = 0; $script:DlSaved = 0; $script:DlSkipped = 0; $script:DlFailed = 0
    $script:DlRoot = $root
    $script:DlFailureList.Clear()

    Set-DownloadControlsEnabled -Enabled $false
    Show-Progress -Done 0 -Total $script:DlTotal
    Set-Status ('Downloading 0/{0} (up to {1} at a time)...' -f $script:DlTotal, $maxPar)

    foreach ($id in $ids) {
        $row = $script:RowById[$id]
        if ($row) { $row.DefaultCellStyle.BackColor = $script:ClrWhite }
        Start-PlaudJob -Kind 'download' -Id $id -Pool $script:DownloadPool -Script $script:SbDownload `
            -Arguments @($script:AuthPath, $script:DataPath, $script:DownloadPath, $script:Token, $id, $root, $types, $overwrite)
    }
}

function Complete-DownloadRunIfDone {
    if ($script:DlTotal -le 0 -or $script:DlDone -lt $script:DlTotal) { return }

    try { if ($script:DownloadPool) { $script:DownloadPool.Close(); $script:DownloadPool.Dispose() } } catch { }
    $script:DownloadPool = $null

    Show-Progress -Done 0 -Total 0
    Set-DownloadControlsEnabled -Enabled $true

    $summary = ("Download complete.`r`n`r`n" +
                "Recordings : {0}`r`n" +
                "Files saved: {1}`r`n" +
                "Skipped    : {2}`r`n" +
                "Failed     : {3}`r`n`r`n" +
                "Folder: {4}") -f `
                $script:DlTotal, $script:DlSaved, $script:DlSkipped, $script:DlFailed, $script:DlRoot
    if ($script:DlFailed -gt 0) {
        $first = @($script:DlFailureList | Select-Object -First 5) -join "`r`n"
        $summary = $summary + "`r`n`r`nFirst failures:`r`n" + $first
    }
    Set-Status ('Done. Saved {0}, skipped {1}, failed {2}.' -f $script:DlSaved, $script:DlSkipped, $script:DlFailed)

    $ask = $summary + "`r`n`r`nOpen the download folder now?"
    $res = [System.Windows.Forms.MessageBox]::Show($ask, 'Download complete', 'YesNo', 'Information')
    if ($res -eq [System.Windows.Forms.DialogResult]::Yes) {
        try { Start-Process -FilePath 'explorer.exe' -ArgumentList ('"{0}"' -f $script:DlRoot) } catch { }
    }
}

function Show-SettingsDialog {
    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = 'Settings'
    $dlg.FormBorderStyle = 'FixedDialog'
    $dlg.StartPosition = 'CenterParent'
    $dlg.MaximizeBox = $false
    $dlg.MinimizeBox = $false
    $dlg.BackColor = $script:ClrWhite
    if ($script:AppIcon) { $dlg.Icon = $script:AppIcon }
    $dlg.ClientSize = New-Object System.Drawing.Size(520, 160)

    $lblPath = New-Object System.Windows.Forms.Label
    $lblPath.Text = 'Download folder:'; $lblPath.Location = New-Object System.Drawing.Point(12, 18); $lblPath.AutoSize = $true
    $dlg.Controls.Add($lblPath)

    $txtPath = New-Object System.Windows.Forms.TextBox
    $txtPath.Location = New-Object System.Drawing.Point(12, 40); $txtPath.Size = New-Object System.Drawing.Size(400, 23)
    $txtPath.Text = $script:Config.DownloadPath
    $dlg.Controls.Add($txtPath)

    $btnBrowse = New-Object System.Windows.Forms.Button
    $btnBrowse.Text = 'Browse...'; $btnBrowse.Location = New-Object System.Drawing.Point(420, 39); $btnBrowse.Size = New-Object System.Drawing.Size(85, 25)
    Set-BlackButtonStyle $btnBrowse
    $btnBrowse.Add_Click({
        $fb = New-Object System.Windows.Forms.FolderBrowserDialog
        if (Test-Path -LiteralPath $txtPath.Text) { $fb.SelectedPath = $txtPath.Text }
        if ($fb.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { $txtPath.Text = $fb.SelectedPath }
    })
    $dlg.Controls.Add($btnBrowse)

    $lblPar = New-Object System.Windows.Forms.Label
    $lblPar.Text = 'Max parallel downloads:'; $lblPar.Location = New-Object System.Drawing.Point(12, 80); $lblPar.AutoSize = $true
    $dlg.Controls.Add($lblPar)

    $numPar = New-Object System.Windows.Forms.NumericUpDown
    $numPar.Location = New-Object System.Drawing.Point(170, 78); $numPar.Minimum = 1; $numPar.Maximum = 10
    $numPar.Value = $script:Config.MaxParallel
    $dlg.Controls.Add($numPar)

    $btnOk = New-Object System.Windows.Forms.Button
    $btnOk.Text = 'Save'; $btnOk.Location = New-Object System.Drawing.Point(335, 120); $btnOk.Size = New-Object System.Drawing.Size(80, 27)
    $btnOk.DialogResult = [System.Windows.Forms.DialogResult]::OK
    Set-BlackButtonStyle $btnOk
    $dlg.Controls.Add($btnOk)

    $btnCancel = New-Object System.Windows.Forms.Button
    $btnCancel.Text = 'Cancel'; $btnCancel.Location = New-Object System.Drawing.Point(423, 120); $btnCancel.Size = New-Object System.Drawing.Size(80, 27)
    $btnCancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    Set-BlackButtonStyle $btnCancel
    $dlg.Controls.Add($btnCancel)

    $dlg.AcceptButton = $btnOk
    $dlg.CancelButton = $btnCancel

    if ($dlg.ShowDialog($script:Form) -eq [System.Windows.Forms.DialogResult]::OK) {
        $script:Config.DownloadPath = $txtPath.Text
        $script:Config.MaxParallel  = [int]$numPar.Value
        Save-PlaudConfig -Config $script:Config
        Set-Status ('Settings saved. Download folder: {0}' -f $script:Config.DownloadPath)
    }
    $dlg.Dispose()
}

function Show-AboutDialog {
    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = ('About {0}' -f $script:AppName)
    $dlg.FormBorderStyle = 'FixedDialog'
    $dlg.StartPosition = 'CenterParent'
    $dlg.MaximizeBox = $false
    $dlg.MinimizeBox = $false
    $dlg.BackColor = $script:ClrWhite
    if ($script:AppIcon) { $dlg.Icon = $script:AppIcon }
    $dlg.ClientSize = New-Object System.Drawing.Size(540, 386)

    $lblTitle = New-Object System.Windows.Forms.Label
    $lblTitle.Text = ('{0}  v{1}' -f $script:AppName, $script:AppVersion)
    $lblTitle.Font = New-Object System.Drawing.Font('Segoe UI', 12, [System.Drawing.FontStyle]::Bold)
    $lblTitle.AutoSize = $true
    $lblTitle.Location = New-Object System.Drawing.Point(14, 12)
    $dlg.Controls.Add($lblTitle)

    $lblCopy = New-Object System.Windows.Forms.Label
    $lblCopy.Text = $script:AppCopyright
    $lblCopy.ForeColor = $script:ClrMuted
    $lblCopy.AutoSize = $true
    $lblCopy.Location = New-Object System.Drawing.Point(14, 40)
    $dlg.Controls.Add($lblCopy)

    # Read-only multiline box so the disclaimer is selectable/copyable.
    $txt = New-Object System.Windows.Forms.TextBox
    $txt.Multiline = $true
    $txt.ReadOnly = $true
    $txt.WordWrap = $true
    $txt.ScrollBars = 'Vertical'
    $txt.BorderStyle = 'FixedSingle'
    $txt.BackColor = $script:ClrWhite
    $txt.Location = New-Object System.Drawing.Point(14, 66)
    $txt.Size = New-Object System.Drawing.Size(512, 224)
    $txt.Text = $script:AppDisclaimer
    $txt.Select(0, 0)
    $dlg.Controls.Add($txt)

    $lnkGit = New-Object System.Windows.Forms.LinkLabel
    $lnkGit.Text = 'Project on GitHub'
    $lnkGit.AutoSize = $true
    $lnkGit.LinkColor = $script:ClrLink
    $lnkGit.Location = New-Object System.Drawing.Point(14, 300)
    $lnkGit.Add_LinkClicked({ try { Start-Process $script:AppGitHubUrl } catch { } })
    $dlg.Controls.Add($lnkGit)

    $lnkIcon = New-Object System.Windows.Forms.LinkLabel
    $lnkIcon.Text = $script:IconAttribText
    $lnkIcon.AutoSize = $true
    $lnkIcon.LinkColor = $script:ClrMuted
    $lnkIcon.Location = New-Object System.Drawing.Point(14, 322)
    $lnkIcon.Add_LinkClicked({ try { Start-Process $script:IconAttribUrl } catch { } })
    $dlg.Controls.Add($lnkIcon)

    $btnClose = New-Object System.Windows.Forms.Button
    $btnClose.Text = 'Close'
    $btnClose.Size = New-Object System.Drawing.Size(90, 28)
    $btnClose.Location = New-Object System.Drawing.Point(436, 348)
    $btnClose.DialogResult = [System.Windows.Forms.DialogResult]::OK
    Set-BlackButtonStyle $btnClose
    $dlg.Controls.Add($btnClose)
    $dlg.AcceptButton = $btnClose

    [void]$dlg.ShowDialog($script:Form)
    $dlg.Dispose()
}

# ---------------------------------------------------------------------------
# Region: Timer - harvest completed jobs (UI thread only)
# ---------------------------------------------------------------------------

function Complete-AvailabilityFillIfDone {
    if ($script:AvailTotal -gt 0 -and $script:AvailDone -ge $script:AvailTotal) {
        Show-Progress -Done 0 -Total 0
        Set-Status ('Ready. {0} recordings.' -f $script:AvailTotal)
    }
}

function Invoke-JobHarvest {
    if ($script:Jobs.Count -eq 0) { return }
    $done = New-Object System.Collections.ArrayList
    foreach ($job in $script:Jobs) { if ($job.Handle.IsCompleted) { [void]$done.Add($job) } }

    foreach ($job in $done) {
        $results = $null; $jobError = $null
        try { $results = $job.PS.EndInvoke($job.Handle) } catch { $jobError = $_ }
        try { $job.PS.Dispose() } catch { }
        $script:Jobs.Remove($job)

        switch ($job.Kind) {

            'session' {
                $user = @($results) | Select-Object -Last 1
                if ($user) { Set-LoggedInUi $user; Start-ListLoad }
                else { Reset-LoggedOutUi 'Not signed in. Click Sign In to begin.' }
            }

            'login' {
                if ($jobError) {
                    $script:BtnLogin.Enabled = $true
                    Set-Status 'Sign-in failed.'
                    [System.Windows.Forms.MessageBox]::Show($jobError.Exception.Message, 'Sign-in failed', 'OK', 'Warning') | Out-Null
                } else {
                    $user = @($results) | Select-Object -Last 1
                    if ($user) { Set-LoggedInUi $user; Start-ListLoad }
                    else { $script:BtnLogin.Enabled = $true; Set-Status 'Sign-in did not complete.' }
                }
            }

            'logout' { Reset-LoggedOutUi 'Signed out.' }

            'list' {
                if ($jobError) {
                    Set-Status 'Failed to load recordings.'
                    [System.Windows.Forms.MessageBox]::Show($jobError.Exception.Message, 'Load failed', 'OK', 'Warning') | Out-Null
                } else {
                    $script:Recordings = @($results)
                    foreach ($r in $script:Recordings) { Add-RecordingRow $r }
                    Set-Status ('Loaded {0} recordings. Checking availability...' -f $script:Recordings.Count)
                    Start-AvailabilityFill
                }
            }

            'avail' {
                $a = @($results) | Select-Object -Last 1
                if ($jobError) { Set-RowAvailabilityError -Id $job.Id }
                elseif ($a -and ($a.PSObject.Properties.Name -contains 'Error')) { Set-RowAvailabilityError -Id $a.Id }
                elseif ($a) { Update-RowAvailability $a }
                $script:AvailDone++
                Show-Progress -Done $script:AvailDone -Total $script:AvailTotal
                Set-Status ('Checking availability {0}/{1}...' -f $script:AvailDone, $script:AvailTotal)
                Complete-AvailabilityFillIfDone
            }

            'download' {
                $r = @($results) | Select-Object -Last 1
                if ($r) {
                    $script:DlSaved   += [int]$r.SavedCount
                    $script:DlSkipped += [int]$r.SkippedCount
                    $script:DlFailed  += [int]$r.FailedCount
                    if ($r.Failures) { foreach ($f in $r.Failures) { [void]$script:DlFailureList.Add(('{0}: {1}' -f $r.Name, $f.Error)) } }
                    Set-RowDownloadColor -Id $job.Id -Ok ([int]$r.FailedCount -eq 0)
                    Set-Status ('Downloaded {0}/{1}: {2}' -f ($script:DlDone + 1), $script:DlTotal, $r.Name)
                } elseif ($jobError) {
                    $script:DlFailed++
                    [void]$script:DlFailureList.Add(('{0}: {1}' -f $job.Id, $jobError.Exception.Message))
                    Set-RowDownloadColor -Id $job.Id -Ok $false
                }
                $script:DlDone++
                Show-Progress -Done $script:DlDone -Total $script:DlTotal
                Complete-DownloadRunIfDone
            }
        }
    }
}

# ---------------------------------------------------------------------------
# Region: Build the UI (root TableLayoutPanel)
# ---------------------------------------------------------------------------

$script:AppIcon = Get-AppIcon

$script:Form = New-Object System.Windows.Forms.Form
$script:Form.Text = $script:AppName
$script:Form.StartPosition = 'CenterScreen'
$script:Form.Size = New-Object System.Drawing.Size(1020, 660)
$script:Form.MinimumSize = New-Object System.Drawing.Size(860, 500)
$script:Form.BackColor = $script:ClrWhite
if ($script:AppIcon) { $script:Form.Icon = $script:AppIcon }

$root = New-Object System.Windows.Forms.TableLayoutPanel
$root.Dock = 'Fill'
$root.BackColor = $script:ClrWhite
$root.ColumnCount = 1
$root.RowCount = 6
[void]$root.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100)))
[void]$root.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 54)))
[void]$root.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 38)))
[void]$root.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 40)))
[void]$root.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100)))
[void]$root.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 28)))
[void]$root.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 26)))
$script:Form.Controls.Add($root)

# --- Row 0: top bar ---
$topBar = New-Object System.Windows.Forms.Panel
$topBar.Dock = 'Fill'; $topBar.BackColor = $script:ClrWhite

$leftFlow = New-Object System.Windows.Forms.FlowLayoutPanel
$leftFlow.Dock = 'Left'; $leftFlow.FlowDirection = 'LeftToRight'; $leftFlow.AutoSize = $true
$leftFlow.WrapContents = $false; $leftFlow.BackColor = $script:ClrWhite

$logo = New-Object System.Windows.Forms.PictureBox
$logo.Size = New-Object System.Drawing.Size(40, 40)
$logo.SizeMode = 'Zoom'
$logo.Margin = New-Object System.Windows.Forms.Padding(8, 7, 6, 0)
Set-LogoImage -PictureBox $logo
$leftFlow.Controls.Add($logo)

$logoTip = New-Object System.Windows.Forms.ToolTip
$logoTip.SetToolTip($logo, $script:IconAttribText)

$titleLabel = New-Object System.Windows.Forms.Label
$titleLabel.Text = $script:AppName
$titleLabel.Font = New-Object System.Drawing.Font('Segoe UI', 13, [System.Drawing.FontStyle]::Bold)
$titleLabel.AutoSize = $true
$titleLabel.Margin = New-Object System.Windows.Forms.Padding(0, 14, 12, 0)
$leftFlow.Controls.Add($titleLabel)

$rightFlow = New-Object System.Windows.Forms.FlowLayoutPanel
$rightFlow.Dock = 'Right'; $rightFlow.FlowDirection = 'RightToLeft'; $rightFlow.AutoSize = $true
$rightFlow.WrapContents = $false; $rightFlow.BackColor = $script:ClrWhite

$script:BtnLogin = New-Object System.Windows.Forms.Button
$script:BtnLogin.Text = 'Sign In'; $script:BtnLogin.Size = New-Object System.Drawing.Size(90, 30)
$script:BtnLogin.Margin = New-Object System.Windows.Forms.Padding(6, 11, 8, 0)
Set-BlackButtonStyle $script:BtnLogin
$script:BtnLogin.Add_Click({ Start-Login })
$rightFlow.Controls.Add($script:BtnLogin)

$script:BtnLogout = New-Object System.Windows.Forms.Button
$script:BtnLogout.Text = 'Sign Out'; $script:BtnLogout.Size = New-Object System.Drawing.Size(90, 30)
$script:BtnLogout.Margin = New-Object System.Windows.Forms.Padding(6, 11, 8, 0)
$script:BtnLogout.Visible = $false
Set-BlackButtonStyle $script:BtnLogout
$script:BtnLogout.Add_Click({ Start-Logout })
$rightFlow.Controls.Add($script:BtnLogout)

$script:BtnRefresh = New-Object System.Windows.Forms.Button
$script:BtnRefresh.Text = 'Refresh'; $script:BtnRefresh.Size = New-Object System.Drawing.Size(90, 30)
$script:BtnRefresh.Margin = New-Object System.Windows.Forms.Padding(6, 11, 0, 0)
$script:BtnRefresh.Enabled = $false
Set-BlackButtonStyle $script:BtnRefresh
$script:BtnRefresh.Add_Click({ if ($script:LoggedIn) { Start-ListLoad } })
$rightFlow.Controls.Add($script:BtnRefresh)

$script:BtnSettings = New-Object System.Windows.Forms.Button
$script:BtnSettings.Text = 'Settings'; $script:BtnSettings.Size = New-Object System.Drawing.Size(90, 30)
$script:BtnSettings.Margin = New-Object System.Windows.Forms.Padding(6, 11, 0, 0)
Set-BlackButtonStyle $script:BtnSettings
$script:BtnSettings.Add_Click({ Show-SettingsDialog })
$rightFlow.Controls.Add($script:BtnSettings)

$script:BtnAbout = New-Object System.Windows.Forms.Button
$script:BtnAbout.Text = 'About'; $script:BtnAbout.Size = New-Object System.Drawing.Size(80, 30)
$script:BtnAbout.Margin = New-Object System.Windows.Forms.Padding(6, 11, 0, 0)
Set-BlackButtonStyle $script:BtnAbout
$script:BtnAbout.Add_Click({ Show-AboutDialog })
$rightFlow.Controls.Add($script:BtnAbout)

$script:AccountLabel = New-Object System.Windows.Forms.Label
$script:AccountLabel.Text = 'Not signed in'
$script:AccountLabel.Dock = 'Fill'
$script:AccountLabel.TextAlign = 'MiddleRight'
$script:AccountLabel.Padding = New-Object System.Windows.Forms.Padding(0, 0, 12, 0)

$topBar.Controls.Add($leftFlow)
$topBar.Controls.Add($rightFlow)
$topBar.Controls.Add($script:AccountLabel)
$script:AccountLabel.BringToFront()
$root.Controls.Add($topBar, 0, 0)

# --- Row 1: date filter ---
$filterPanel = New-Object System.Windows.Forms.FlowLayoutPanel
$filterPanel.Dock = 'Fill'; $filterPanel.WrapContents = $false; $filterPanel.BackColor = $script:ClrWhite
$filterPanel.Padding = New-Object System.Windows.Forms.Padding(8, 5, 8, 0)

$lblDates = New-Object System.Windows.Forms.Label
$lblDates.Text = 'Dates:'; $lblDates.AutoSize = $true
$lblDates.Margin = New-Object System.Windows.Forms.Padding(0, 7, 6, 0)
$filterPanel.Controls.Add($lblDates)

$script:CmbPreset = New-Object System.Windows.Forms.ComboBox
$script:CmbPreset.DropDownStyle = 'DropDownList'
$script:CmbPreset.Width = 130
$script:CmbPreset.Margin = New-Object System.Windows.Forms.Padding(0, 3, 12, 0)
[void]$script:CmbPreset.Items.AddRange(@('All', 'Today', 'Last 7 days', 'Last 30 days', 'This month', 'Custom'))
$script:CmbPreset.SelectedItem = 'All'
# Attach the handler AFTER setting the initial value so build-time selection does not fire it.
$script:CmbPreset.Add_SelectedIndexChanged({ Invoke-PresetChanged })
$filterPanel.Controls.Add($script:CmbPreset)

$lblFrom = New-Object System.Windows.Forms.Label
$lblFrom.Text = 'From'; $lblFrom.AutoSize = $true
$lblFrom.Margin = New-Object System.Windows.Forms.Padding(0, 7, 4, 0)
$filterPanel.Controls.Add($lblFrom)

$script:DtpFrom = New-Object System.Windows.Forms.DateTimePicker
$script:DtpFrom.Format = 'Short'; $script:DtpFrom.Width = 110
$script:DtpFrom.Margin = New-Object System.Windows.Forms.Padding(0, 3, 10, 0)
$script:DtpFrom.Enabled = $false
$filterPanel.Controls.Add($script:DtpFrom)

$lblTo = New-Object System.Windows.Forms.Label
$lblTo.Text = 'To'; $lblTo.AutoSize = $true
$lblTo.Margin = New-Object System.Windows.Forms.Padding(0, 7, 4, 0)
$filterPanel.Controls.Add($lblTo)

$script:DtpTo = New-Object System.Windows.Forms.DateTimePicker
$script:DtpTo.Format = 'Short'; $script:DtpTo.Width = 110
$script:DtpTo.Margin = New-Object System.Windows.Forms.Padding(0, 3, 12, 0)
$script:DtpTo.Enabled = $false
$filterPanel.Controls.Add($script:DtpTo)

$script:BtnApplyFilter = New-Object System.Windows.Forms.Button
$script:BtnApplyFilter.Text = 'Apply'; $script:BtnApplyFilter.AutoSize = $true
$script:BtnApplyFilter.Margin = New-Object System.Windows.Forms.Padding(0, 1, 4, 2)
Set-BlackButtonStyle $script:BtnApplyFilter
$script:BtnApplyFilter.Add_Click({ Invoke-ApplyFilter })
$filterPanel.Controls.Add($script:BtnApplyFilter)

$script:BtnClearFilter = New-Object System.Windows.Forms.Button
$script:BtnClearFilter.Text = 'Clear'; $script:BtnClearFilter.AutoSize = $true
$script:BtnClearFilter.Margin = New-Object System.Windows.Forms.Padding(0, 1, 4, 2)
Set-BlackButtonStyle $script:BtnClearFilter
$script:BtnClearFilter.Add_Click({ $script:CmbPreset.SelectedItem = 'All' })
$filterPanel.Controls.Add($script:BtnClearFilter)

$root.Controls.Add($filterPanel, 0, 1)

# --- Row 2: toolbar ---
$toolPanel = New-Object System.Windows.Forms.FlowLayoutPanel
$toolPanel.Dock = 'Fill'; $toolPanel.WrapContents = $false; $toolPanel.BackColor = $script:ClrWhite
$toolPanel.Padding = New-Object System.Windows.Forms.Padding(8, 6, 8, 0)

$lblInclude = New-Object System.Windows.Forms.Label
$lblInclude.Text = 'Include:'; $lblInclude.AutoSize = $true
$lblInclude.Margin = New-Object System.Windows.Forms.Padding(0, 6, 6, 0)
$toolPanel.Controls.Add($lblInclude)

function New-TypeCheckbox {
    param([string]$Text, [bool]$Checked)
    $cb = New-Object System.Windows.Forms.CheckBox
    $cb.Text = $Text; $cb.Checked = $Checked; $cb.AutoSize = $true
    $cb.Margin = New-Object System.Windows.Forms.Padding(0, 4, 10, 0)
    return $cb
}
$script:ChkTranscript = New-TypeCheckbox -Text 'Transcript' -Checked $script:Config.ArtifactTypes.Transcript
$script:ChkSummary    = New-TypeCheckbox -Text 'Summary'    -Checked $script:Config.ArtifactTypes.Summary
$script:ChkNotes      = New-TypeCheckbox -Text 'Notes'      -Checked $script:Config.ArtifactTypes.Notes
$script:ChkAudio      = New-TypeCheckbox -Text 'Audio'      -Checked $script:Config.ArtifactTypes.Audio
$script:ChkPolished   = New-TypeCheckbox -Text 'Polished'   -Checked $script:Config.ArtifactTypes.Polished
$script:ChkOutline    = New-TypeCheckbox -Text 'Outline'    -Checked $script:Config.ArtifactTypes.Outline
foreach ($cb in @($script:ChkTranscript, $script:ChkSummary, $script:ChkNotes, $script:ChkAudio, $script:ChkPolished, $script:ChkOutline)) {
    $toolPanel.Controls.Add($cb)
}

$script:BtnSelAll = New-Object System.Windows.Forms.Button
$script:BtnSelAll.Text = 'Select All'; $script:BtnSelAll.AutoSize = $true
$script:BtnSelAll.Margin = New-Object System.Windows.Forms.Padding(12, 2, 4, 2)
Set-BlackButtonStyle $script:BtnSelAll
$script:BtnSelAll.Add_Click({ foreach ($row in $script:Grid.Rows) { $row.Cells['Sel'].Value = $true } })
$toolPanel.Controls.Add($script:BtnSelAll)

$script:BtnSelNone = New-Object System.Windows.Forms.Button
$script:BtnSelNone.Text = 'Select None'; $script:BtnSelNone.AutoSize = $true
$script:BtnSelNone.Margin = New-Object System.Windows.Forms.Padding(0, 2, 4, 2)
Set-BlackButtonStyle $script:BtnSelNone
$script:BtnSelNone.Add_Click({ foreach ($row in $script:Grid.Rows) { $row.Cells['Sel'].Value = $false } })
$toolPanel.Controls.Add($script:BtnSelNone)

$script:ChkOverwrite = New-Object System.Windows.Forms.CheckBox
$script:ChkOverwrite.Text = 'Overwrite existing'; $script:ChkOverwrite.AutoSize = $true
$script:ChkOverwrite.Checked = [bool]$script:Config.Overwrite
$script:ChkOverwrite.Margin = New-Object System.Windows.Forms.Padding(16, 6, 10, 0)
$toolPanel.Controls.Add($script:ChkOverwrite)

$script:BtnDownload = New-Object System.Windows.Forms.Button
$script:BtnDownload.Text = 'Download Selected'; $script:BtnDownload.AutoSize = $true
$script:BtnDownload.Margin = New-Object System.Windows.Forms.Padding(16, 2, 4, 2)
Set-BlackButtonStyle $script:BtnDownload
$script:BtnDownload.Add_Click({ Invoke-DownloadStart })
$toolPanel.Controls.Add($script:BtnDownload)

$root.Controls.Add($toolPanel, 0, 2)

# --- Row 2: recordings grid ---
$script:Grid = New-Object System.Windows.Forms.DataGridView
$script:Grid.Dock = 'Fill'
$script:Grid.AllowUserToAddRows = $false
$script:Grid.AllowUserToDeleteRows = $false
$script:Grid.AllowUserToResizeRows = $false
$script:Grid.RowHeadersVisible = $false
$script:Grid.SelectionMode = 'FullRowSelect'
$script:Grid.MultiSelect = $true
$script:Grid.AutoSizeColumnsMode = 'None'
$script:Grid.EditMode = 'EditOnEnter'
$script:Grid.BackgroundColor = $script:ClrWhite
$script:Grid.BorderStyle = 'None'
$script:Grid.EnableHeadersVisualStyles = $false
$script:Grid.ColumnHeadersDefaultCellStyle.BackColor = $script:ClrWhite
$script:Grid.ColumnHeadersDefaultCellStyle.ForeColor = $script:ClrBlack
$script:Grid.ColumnHeadersDefaultCellStyle.Font = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
$script:Grid.GridColor = [System.Drawing.Color]::FromArgb(225, 225, 225)
$script:Grid.DefaultCellStyle.SelectionBackColor = [System.Drawing.Color]::FromArgb(232, 240, 254)
$script:Grid.DefaultCellStyle.SelectionForeColor = $script:ClrBlack

$colSel = New-Object System.Windows.Forms.DataGridViewCheckBoxColumn
$colSel.Name = 'Sel'; $colSel.HeaderText = ''; $colSel.Width = 30
[void]$script:Grid.Columns.Add($colSel)

function Add-TextColumn {
    param([string]$Name, [string]$Header, [int]$Width, [bool]$Fill = $false)
    $col = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $col.Name = $Name; $col.HeaderText = $Header; $col.ReadOnly = $true
    if ($Fill) { $col.AutoSizeMode = 'Fill' } else { $col.Width = $Width }
    [void]$script:Grid.Columns.Add($col)
}
Add-TextColumn -Name 'When'       -Header 'When'       -Width 130
Add-TextColumn -Name 'Length'     -Header 'Length'     -Width 70
Add-TextColumn -Name 'Name'       -Header 'Recording'  -Width 100 -Fill $true
Add-TextColumn -Name 'Transcript' -Header 'Transcript' -Width 80
Add-TextColumn -Name 'Summary'    -Header 'Summary'    -Width 70
Add-TextColumn -Name 'Notes'      -Header 'Notes'      -Width 60
Add-TextColumn -Name 'Tabs'       -Header '#'          -Width 34
Add-TextColumn -Name 'Audio'      -Header 'Audio'      -Width 60

$colId = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
$colId.Name = 'Id'; $colId.HeaderText = 'Id'; $colId.Visible = $false
[void]$script:Grid.Columns.Add($colId)

$script:Grid.Add_CurrentCellDirtyStateChanged({
    if ($script:Grid.IsCurrentCellDirty) {
        $script:Grid.CommitEdit([System.Windows.Forms.DataGridViewDataErrorContexts]::Commit)
    }
})
$root.Controls.Add($script:Grid, 0, 3)

# --- Row 3: footer (copyright + GitHub link on the left; icon attribution on the right) ---
$footer = New-Object System.Windows.Forms.Panel
$footer.Dock = 'Fill'; $footer.BackColor = $script:ClrWhite

$footerLeft = New-Object System.Windows.Forms.FlowLayoutPanel
$footerLeft.Dock = 'Left'; $footerLeft.FlowDirection = 'LeftToRight'; $footerLeft.AutoSize = $true
$footerLeft.WrapContents = $false; $footerLeft.BackColor = $script:ClrWhite

$copyrightLabel = New-Object System.Windows.Forms.Label
$copyrightLabel.Text = $script:AppCopyright
$copyrightLabel.AutoSize = $true
$copyrightLabel.ForeColor = $script:ClrMuted
$copyrightLabel.Margin = New-Object System.Windows.Forms.Padding(8, 7, 0, 0)
$footerLeft.Controls.Add($copyrightLabel)

$githubLink = New-Object System.Windows.Forms.LinkLabel
$githubLink.Text = 'GitHub'; $githubLink.AutoSize = $true; $githubLink.LinkColor = $script:ClrLink
$githubLink.Margin = New-Object System.Windows.Forms.Padding(10, 7, 0, 0)
$githubLink.Add_LinkClicked({ try { Start-Process $script:AppGitHubUrl } catch { } })
$footerLeft.Controls.Add($githubLink)

$footer.Controls.Add($footerLeft)

$footerRight = New-Object System.Windows.Forms.FlowLayoutPanel
$footerRight.Dock = 'Right'; $footerRight.FlowDirection = 'RightToLeft'; $footerRight.AutoSize = $true
$footerRight.WrapContents = $false; $footerRight.BackColor = $script:ClrWhite

$attribLink = New-Object System.Windows.Forms.LinkLabel
$attribLink.Text = $script:IconAttribText; $attribLink.AutoSize = $true; $attribLink.LinkColor = $script:ClrMuted
$attribLink.Margin = New-Object System.Windows.Forms.Padding(12, 6, 8, 0)
$attribLink.Add_LinkClicked({ try { Start-Process $script:IconAttribUrl } catch { } })
$footerRight.Controls.Add($attribLink)

$footer.Controls.Add($footerRight)
$root.Controls.Add($footer, 0, 4)

# --- Row 4: status (label left, progress right) ---
$statusPanel = New-Object System.Windows.Forms.Panel
$statusPanel.Dock = 'Fill'; $statusPanel.BackColor = [System.Drawing.Color]::FromArgb(245, 245, 245)

$script:ProgressBar = New-Object System.Windows.Forms.ProgressBar
$script:ProgressBar.Dock = 'Right'; $script:ProgressBar.Width = 220; $script:ProgressBar.Visible = $false
$statusPanel.Controls.Add($script:ProgressBar)

$script:StatusLabel = New-Object System.Windows.Forms.Label
$script:StatusLabel.Text = 'Starting...'
$script:StatusLabel.Dock = 'Fill'
$script:StatusLabel.TextAlign = 'MiddleLeft'
$script:StatusLabel.Padding = New-Object System.Windows.Forms.Padding(8, 0, 0, 0)
$statusPanel.Controls.Add($script:StatusLabel)
$script:StatusLabel.BringToFront()
$root.Controls.Add($statusPanel, 0, 5)

# --- Timer ---
$script:Timer = New-Object System.Windows.Forms.Timer
$script:Timer.Interval = 200
$script:Timer.Add_Tick({ Invoke-JobHarvest })
$script:Timer.Start()

# --- Lifecycle ---
$script:Form.Add_Shown({ Start-SessionCheck })
$script:Form.Add_FormClosing({
    try { $script:Timer.Stop() } catch { }
    try { if ($script:DownloadPool) { $script:DownloadPool.Close(); $script:DownloadPool.Dispose() } } catch { }
    try { if ($script:Pool) { $script:Pool.Close(); $script:Pool.Dispose() } } catch { }
})

[void][System.Windows.Forms.Application]::Run($script:Form)
