<#
.SYNOPSIS
    Build Plaud Exporter into a Windows EXE with PS2EXE.

.DESCRIPTION
    Two modes:

    SINGLE-FILE (default): bundles src\ and assets\ into the script as a compressed base64
    payload, compiles that to ONE standalone dist\PlaudExporter.exe. At launch the EXE unpacks those
    resources to a per-user folder (%LOCALAPPDATA%\PlaudExporter\runtime), re-extracting only
    when the build changes - so you distribute a single file with no loose folders.

    PORTABLE (-Portable): compiles the EXE and copies src\ and assets\ next to it into
    dist\PlaudExporter\ (EXE + folders). Useful for debugging the unbundled layout.

    Both modes produce a 64-bit, no-console (GUI), non-elevated EXE using assets\appicon.ico and
    embedding version/company/copyright/trademark resource info. The window/taskbar icon still
    comes from the embedded base64 in src\PlaudIcon.ps1; -iconFile sets the EXE file's own icon.

.PARAMETER Version
    File/product version resource, format a.b.c.d. Default 1.0.0.0.

.PARAMETER Company
    Company/author name for the version resource. Default 'Kevin Shoaf'.

.PARAMETER Portable
    Build the EXE + loose src\/assets\ folders instead of a single self-contained EXE.

.PARAMETER Zip
    Also create a zip in dist\ (the single EXE, or the portable folder).

.PARAMETER WhatIf
    Show what would happen without building.

.NOTES
    Windows PowerShell 5.1, ASCII-only. Run from a normal console.
    Requires the PS2EXE module (auto-installed for the current user if missing, which needs
    access to the PowerShell Gallery). Logs to D:\Logs\PlaudExporter (fallback C:\Logs, then %TEMP%).
#>
[CmdletBinding()]
param(
    [string]$Version = '1.0.0.0',
    [string]$Company = 'Kevin Shoaf',
    [switch]$Portable,
    [switch]$Zip,
    [switch]$WhatIf
)

# --- Resolve repo paths (this script sits at the project root) ---
$repo       = $PSScriptRoot
$mainScript = Join-Path $repo 'PlaudExporter.ps1'
$iconFile   = Join-Path $repo 'assets\appicon.ico'
$srcDir     = Join-Path $repo 'src'
$assetsDir  = Join-Path $repo 'assets'
$distRoot   = Join-Path $repo 'dist'

# --- Logging (house convention: D:\Logs -> C:\Logs -> %TEMP%) ---
function Resolve-BuildLogDir {
    $candidates = @()
    if (Test-Path -LiteralPath 'D:\') { $candidates += 'D:\Logs\PlaudExporter' }
    $candidates += 'C:\Logs\PlaudExporter'
    $candidates += (Join-Path $env:TEMP 'PlaudExporter\Logs')
    foreach ($d in $candidates) {
        try { if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d -Force -ErrorAction Stop | Out-Null }; return $d } catch { continue }
    }
    return $env:TEMP
}
$logDir  = Resolve-BuildLogDir
$logFile = Join-Path $logDir ('Build_{0}.log' -f (Get-Date -Format 'yyyyMMdd'))
function Write-BuildLog {
    param([string]$Message, [ValidateSet('INFO', 'WARN', 'ERROR')][string]$Level = 'INFO')
    $line = '{0} [{1,-5}] {2}' -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'), $Level, $Message
    try { Add-Content -LiteralPath $logFile -Value $line -Encoding ASCII -ErrorAction Stop } catch { }
    $color = 'Gray'; if ($Level -eq 'WARN') { $color = 'Yellow' }; if ($Level -eq 'ERROR') { $color = 'Red' }
    Write-Host $line -ForegroundColor $color
}

$mode = if ($Portable) { 'Portable' } else { 'Single-file' }
Write-BuildLog ('Build start. Mode={0} Version={1} Company="{2}" Zip={3} WhatIf={4}' -f $mode, $Version, $Company, [bool]$Zip, [bool]$WhatIf)

# --- Validate required inputs ---
$missing = @()
foreach ($p in @($mainScript, $iconFile, $srcDir, $assetsDir)) { if (-not (Test-Path -LiteralPath $p)) { $missing += $p } }
if ($missing.Count -gt 0) {
    foreach ($m in $missing) { Write-BuildLog ('Missing required path: {0}' -f $m) -Level ERROR }
    throw 'Build aborted: required files/folders are missing (run from the project root).'
}

# --- Ensure PS2EXE is available ---
$havePs2exe = [bool](Get-Module -ListAvailable -Name ps2exe)
if (-not $havePs2exe) {
    if ($WhatIf) {
        Write-BuildLog 'PS2EXE not installed; would run: Install-Module ps2exe -Scope CurrentUser' -Level WARN
    } else {
        Write-BuildLog 'PS2EXE not found; installing for current user...'
        try {
            Install-Module -Name ps2exe -Scope CurrentUser -Force -ErrorAction Stop
            $havePs2exe = $true
        } catch {
            Write-BuildLog ('Could not install PS2EXE automatically: {0}' -f $_.Exception.Message) -Level ERROR
            throw 'Install PS2EXE manually (Install-Module ps2exe -Scope CurrentUser) and re-run.'
        }
    }
}
if ($havePs2exe) { Import-Module ps2exe -Force }

# --- Shared PS2EXE resource arguments ---
$copyright = '(c) {0} {1}' -f (Get-Date).Year, $Company
function New-Ps2exeArgs {
    param([string]$InputFile, [string]$OutputFile)
    @{
        InputFile   = $InputFile
        OutputFile  = $OutputFile
        IconFile    = $iconFile
        Title       = 'Plaud Exporter'
        Description = 'Unofficial bulk exporter for Plaud recordings.'
        Product     = 'Plaud Exporter'
        Company     = $Company
        Copyright   = $copyright
        Trademark   = 'Plaud is a trademark of Plaud Inc.'
        Version     = $Version
        noConsole   = $true     # GUI app: no console window
        x64         = $true     # 64-bit
        DPIAware    = $true     # crisp on high-DPI displays
        # No -requireAdmin: runs unelevated (asInvoker), needed for the localhost OAuth callback.
    }
}

# ===========================================================================
# PORTABLE MODE: EXE + loose src\/assets\ folders
# ===========================================================================
if ($Portable) {
    $appDir = Join-Path $distRoot 'PlaudExporter'
    $exeOut = Join-Path $appDir 'PlaudExporter.exe'

    if ($WhatIf) {
        Write-BuildLog '--- WhatIf: portable build ---'
        Write-BuildLog ('  EXE       : {0}' -f $exeOut)
        Write-BuildLog ('  Will copy : src\ and assets\ next to the EXE')
        if ($Zip) { Write-BuildLog ('  Will zip  : {0}' -f (Join-Path $distRoot ('PlaudExporter-{0}-portable.zip' -f $Version))) }
        Write-BuildLog 'WhatIf complete; nothing was built.'
        return
    }

    if (Test-Path -LiteralPath $appDir) { Write-BuildLog ('Cleaning {0}' -f $appDir); Remove-Item -LiteralPath $appDir -Recurse -Force }
    New-Item -ItemType Directory -Path $appDir -Force | Out-Null

    Write-BuildLog 'Compiling EXE (portable)...'
    $p2a = New-Ps2exeArgs -InputFile $mainScript -OutputFile $exeOut
    try { Invoke-ps2exe @p2a }
    catch { Write-BuildLog ('PS2EXE failed: {0}' -f $_.Exception.Message) -Level ERROR; throw }
    if (-not (Test-Path -LiteralPath $exeOut)) { Write-BuildLog 'EXE not produced.' -Level ERROR; throw 'Build failed.' }

    Write-BuildLog 'Copying src\ and assets\ next to the EXE...'
    Copy-Item -LiteralPath $srcDir    -Destination (Join-Path $appDir 'src')    -Recurse -Force
    Copy-Item -LiteralPath $assetsDir -Destination (Join-Path $appDir 'assets') -Recurse -Force

    if ($Zip) {
        $zipPath = Join-Path $distRoot ('PlaudExporter-{0}-portable.zip' -f $Version)
        if (Test-Path -LiteralPath $zipPath) { Remove-Item -LiteralPath $zipPath -Force }
        Write-BuildLog ('Creating zip: {0}' -f $zipPath)
        Compress-Archive -Path (Join-Path $appDir '*') -DestinationPath $zipPath -Force
    }

    Write-BuildLog '--- Verification ---'
    Write-BuildLog ('  EXE present    : {0}' -f (Test-Path -LiteralPath $exeOut))
    Write-BuildLog ('  src\ copied    : {0}' -f (Test-Path -LiteralPath (Join-Path $appDir 'src\PlaudAuth.psm1')))
    Write-BuildLog ('  assets\ copied : {0}' -f (Test-Path -LiteralPath (Join-Path $appDir 'assets\appicon.ico')))
    Write-BuildLog ('Portable folder: {0}' -f $appDir)
    Write-BuildLog 'Build complete.'
    Write-Host ''
    Write-Host 'Distribute the whole PlaudExporter folder (EXE + src + assets).' -ForegroundColor Cyan
    return
}

# ===========================================================================
# SINGLE-FILE MODE (default): bundle src\ + assets\ into one standalone EXE
# ===========================================================================
$exeOut = Join-Path $distRoot 'PlaudExporter.exe'

if ($WhatIf) {
    Write-BuildLog '--- WhatIf: single-file build ---'
    Write-BuildLog ('  EXE       : {0}' -f $exeOut)
    Write-BuildLog ('  Bundles   : src\ and assets\ as an embedded compressed payload')
    Write-BuildLog ('  Runtime   : unpacks to %LOCALAPPDATA%\PlaudExporter\runtime (cached by signature)')
    Write-BuildLog ('  Flags     : -noConsole -x64 -DPIAware (no admin manifest)')
    if ($Zip) { Write-BuildLog ('  Will zip  : {0}' -f (Join-Path $distRoot ('PlaudExporter-{0}.zip' -f $Version))) }
    Write-BuildLog 'WhatIf complete; nothing was built.'
    return
}

# Staging area for the payload zip + combined script.
$stageDir = Join-Path $env:TEMP ('PlaudExporter_bundle_{0}' -f ([guid]::NewGuid().ToString('N')))
New-Item -ItemType Directory -Path $stageDir -Force | Out-Null
try {
    # 1. Zip src\ + assets\ (folder names preserved at archive root: src\..., assets\...).
    $stageZip = Join-Path $stageDir 'payload.zip'
    Write-BuildLog 'Bundling src\ and assets\ into payload zip...'
    Compress-Archive -Path $srcDir, $assetsDir -DestinationPath $stageZip -Force
    $zipBytes = [System.IO.File]::ReadAllBytes($stageZip)
    Write-BuildLog ('Payload zip: {0:N0} bytes' -f $zipBytes.Length)

    # 2. Base64-encode and wrap to fixed-width lines (base64 has no $, backtick or quote,
    #    so it is safe inside a double-quoted here-string).
    $b64 = [Convert]::ToBase64String($zipBytes)
    $wrapped = New-Object System.Collections.Generic.List[string]
    for ($i = 0; $i -lt $b64.Length; $i += 120) {
        $len = [Math]::Min(120, $b64.Length - $i)
        $wrapped.Add($b64.Substring($i, $len))
    }

    # 3. Compose the combined single script: payload here-string + the full GUI script.
    $mainText = Get-Content -LiteralPath $mainScript -Raw
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine('# ==========================================================================')
    [void]$sb.AppendLine('# Auto-generated single-file build of Plaud Exporter. DO NOT EDIT BY HAND.')
    [void]$sb.AppendLine('# Generated: ' + (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))
    [void]$sb.AppendLine('# ==========================================================================')
    [void]$sb.AppendLine('$script:PlaudEmbeddedPayload = @"')
    foreach ($line in $wrapped) { [void]$sb.AppendLine($line) }
    [void]$sb.AppendLine('"@')
    [void]$sb.AppendLine('')
    [void]$sb.Append($mainText)

    $combined = Join-Path $stageDir 'PlaudExporter.combined.ps1'
    [System.IO.File]::WriteAllText($combined, $sb.ToString(), (New-Object System.Text.ASCIIEncoding))
    Write-BuildLog ('Combined script: {0:N0} bytes' -f (Get-Item -LiteralPath $combined).Length)

    # 4. Compile the combined script to a single EXE.
    if (-not (Test-Path -LiteralPath $distRoot)) { New-Item -ItemType Directory -Path $distRoot -Force | Out-Null }
    if (Test-Path -LiteralPath $exeOut) { Remove-Item -LiteralPath $exeOut -Force }
    Write-BuildLog 'Compiling single-file EXE with PS2EXE...'
    $p2a = New-Ps2exeArgs -InputFile $combined -OutputFile $exeOut
    try { Invoke-ps2exe @p2a }
    catch { Write-BuildLog ('PS2EXE failed: {0}' -f $_.Exception.Message) -Level ERROR; throw }
    if (-not (Test-Path -LiteralPath $exeOut)) { Write-BuildLog 'EXE not produced.' -Level ERROR; throw 'Build failed.' }
    Write-BuildLog ('EXE created: {0} ({1:N0} bytes)' -f $exeOut, (Get-Item -LiteralPath $exeOut).Length)

    # 5. Optional zip of the single EXE.
    if ($Zip) {
        $zipPath = Join-Path $distRoot ('PlaudExporter-{0}.zip' -f $Version)
        if (Test-Path -LiteralPath $zipPath) { Remove-Item -LiteralPath $zipPath -Force }
        Write-BuildLog ('Creating zip: {0}' -f $zipPath)
        Compress-Archive -Path $exeOut -DestinationPath $zipPath -Force
    }
}
finally {
    # 6. Always clean the staging area.
    if (Test-Path -LiteralPath $stageDir) { Remove-Item -LiteralPath $stageDir -Recurse -Force -ErrorAction SilentlyContinue }
}

Write-BuildLog '--- Verification ---'
Write-BuildLog ('  Single EXE present : {0}' -f (Test-Path -LiteralPath $exeOut))
Write-BuildLog ('  Output             : {0}' -f $exeOut)
Write-BuildLog 'Build complete.'

Write-Host ''
Write-Host 'Next steps:' -ForegroundColor Cyan
Write-Host ('  1. Run the single EXE:  "{0}"' -f $exeOut)
Write-Host '  2. It is one self-contained file - no src\ or assets\ folders needed beside it.'
Write-Host '  3. Unsigned, so SmartScreen may warn on first launch (More info -> Run anyway).'
Write-Host '  4. On launch it unpacks resources to %LOCALAPPDATA%\PlaudExporter\runtime (cached; re-extracted only after a rebuild).'
