<#
.SYNOPSIS
    PlaudDownload - per-recording download engine for Plaud Exporter (Phase 4).

.DESCRIPTION
    Invoke-PlaudRecordingDownload does all the work for ONE recording:
        1. Re-fetches the recording detail (fresh presigned links - note/polished links
           live only ~300s, so we must fetch immediately before downloading).
        2. Builds the artifact list (via Get-PlaudRecordingArtifacts) and keeps only the
           available artifacts whose Kind matches the requested types.
        3. Orders them so the short-lived link artifacts (notes/polished/summary) are
           written first and the large, long-lived audio file is written last.
        4. Writes each artifact into a per-recording subfolder, skipping files that
           already exist (unless -Overwrite), and records a saved/skipped/failed summary.

    Inline artifacts are formatted here:
        - Transcript : the 'transaction' JSON -> readable "[time] Speaker: text" lines
        - Outline    : the 'outline' JSON     -> a markdown topic list
        - Summary / inline notes : written as-is (already markdown)
    Link/audio artifacts are streamed straight to disk (the presigned URLs need no auth).

    Returns a summary object:
        Id, Name, Folder, SavedCount, SkippedCount, FailedCount, Saved[], Skipped[], Failures[]

.NOTES
    Windows PowerShell 5.1 compatible, ASCII-only source.
    Requires PlaudAuth.psm1 and PlaudData.psm1 (auto-imported from the same src folder).
    Logs to %LOCALAPPDATA%\PlaudExporter\Logs (fallback %APPDATA%, then %TEMP%) with a PlaudDownload_ prefix.
#>

try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch { }

# Auto-import sibling modules if the caller has not already loaded them.
$script:HereDir = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not (Get-Command Get-PlaudRecordingDetail -ErrorAction SilentlyContinue)) {
    Import-Module (Join-Path $script:HereDir 'PlaudAuth.psm1') -Force
    Import-Module (Join-Path $script:HereDir 'PlaudData.psm1') -Force
}

# UTF-8 without BOM for all text we write ourselves.
$script:Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

# --- Logging (delegates to PlaudAuth's Write-PlaudLog when present) ---
function Resolve-PlaudDownloadLogDir {
    $candidates = @()
    if ($env:LOCALAPPDATA) { $candidates += (Join-Path $env:LOCALAPPDATA 'PlaudExporter\Logs') }
    if ($env:APPDATA)      { $candidates += (Join-Path $env:APPDATA 'PlaudExporter\Logs') }
    $candidates += (Join-Path $env:TEMP 'PlaudExporter\Logs')
    foreach ($dir in $candidates) {
        try {
            if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force -ErrorAction Stop | Out-Null }
            return $dir
        } catch { continue }
    }
    return $env:TEMP
}
$script:LogDir = Resolve-PlaudDownloadLogDir

function Write-PlaudDownloadLog {
    param([string]$Message, [ValidateSet('INFO', 'WARN', 'ERROR', 'DEBUG')][string]$Level = 'INFO')
    if (Get-Command -Name Write-PlaudLog -ErrorAction SilentlyContinue) { Write-PlaudLog -Level $Level -Message $Message; return }
    $line = '{0} [{1,-5}] {2}' -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss.fff'), $Level, $Message
    try { Add-Content -LiteralPath (Join-Path $script:LogDir ('PlaudDownload_{0}.log' -f (Get-Date -Format 'yyyyMMdd'))) -Value $line -Encoding ASCII -ErrorAction Stop } catch { }
    Write-Verbose $line
}

# ---------------------------------------------------------------------------
# Region: Inline content formatters
# ---------------------------------------------------------------------------

function ConvertFrom-PlaudTranscript {
    <#
        Turns the 'transaction' data_content JSON (array of utterances) into readable
        text: one "[h:mm:ss] Speaker: content" line per utterance, with a small header.
    #>
    param([Parameter(Mandatory = $true)][string]$JsonContent, [string]$Title = 'Transcript')
    $items = $JsonContent | ConvertFrom-Json
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine($Title)
    [void]$sb.AppendLine(('Generated {0}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm')))
    [void]$sb.AppendLine('')
    foreach ($it in $items) {
        $ts = ''
        if ($null -ne $it.start_time) { $ts = '[{0}] ' -f (Format-PlaudDuration -Ms ([long]$it.start_time)) }
        $speaker = if ($it.speaker) { $it.speaker } else { 'Speaker' }
        [void]$sb.AppendLine(('{0}{1}: {2}' -f $ts, $speaker, $it.content))
    }
    return $sb.ToString()
}

function ConvertFrom-PlaudOutline {
    <# Turns the 'outline' data_content JSON (topic spans) into a markdown topic list. #>
    param([Parameter(Mandatory = $true)][string]$JsonContent, [string]$Title = 'Outline')
    $items = $JsonContent | ConvertFrom-Json
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine(('# {0}' -f $Title))
    [void]$sb.AppendLine('')
    foreach ($it in $items) {
        $start = if ($null -ne $it.start_time) { Format-PlaudDuration -Ms ([long]$it.start_time) } else { '' }
        $end   = if ($null -ne $it.end_time)   { Format-PlaudDuration -Ms ([long]$it.end_time) }   else { '' }
        [void]$sb.AppendLine(('- [{0} - {1}] {2}' -f $start, $end, $it.topic))
    }
    return $sb.ToString()
}

# ---------------------------------------------------------------------------
# Region: Artifact selection / ordering / single-file write
# ---------------------------------------------------------------------------

function Get-PlaudArtifactRank {
    <#
        Write order within a recording. Short-lived link artifacts first (their presigned
        URLs expire in ~300s), audio last (large file, link valid ~24h).
    #>
    param([string]$Kind)
    switch ($Kind) {
        'Note'               { return 0 }
        'PolishedTranscript' { return 1 }
        'Summary'            { return 2 }
        'Transcript'         { return 3 }
        'Outline'            { return 4 }
        'Audio'              { return 5 }
        default              { return 9 }
    }
}

function Test-PlaudArtifactSelected {
    <# Maps an artifact Kind to a requested type name and tests membership. #>
    param([string]$Kind, [string[]]$Types)
    $wanted = $Kind
    if ($Kind -eq 'Note') { $wanted = 'Notes' }   # 'Notes' type selects every Note tab
    return ($Types -contains $wanted)
}

function Save-PlaudArtifact {
    <#
        Writes a single artifact to $TargetPath. Inline artifacts are formatted by Kind;
        Link/Presigned artifacts are streamed from their presigned URL. Throws on failure.
    #>
    param(
        [Parameter(Mandatory = $true)]$Artifact,
        [Parameter(Mandatory = $true)][string]$TargetPath,
        [string]$RecordingName = ''
    )
    if ($Artifact.Source -eq 'Inline') {
        switch ($Artifact.Kind) {
            'Transcript' { $text = ConvertFrom-PlaudTranscript -JsonContent $Artifact.Pointer -Title ('Transcript - {0}' -f $RecordingName) }
            'Outline'    { $text = ConvertFrom-PlaudOutline    -JsonContent $Artifact.Pointer -Title ('Outline - {0}'    -f $RecordingName) }
            default      { $text = [string]$Artifact.Pointer }   # Summary / inline notes: already markdown
        }
        [System.IO.File]::WriteAllText($TargetPath, $text, $script:Utf8NoBom)
    } else {
        # Link or Presigned: stream the presigned URL straight to disk (no auth header).
        Invoke-WebRequest -Uri $Artifact.Pointer -OutFile $TargetPath -UseBasicParsing -ErrorAction Stop
    }
}

# ---------------------------------------------------------------------------
# Region: Public - download one recording
# ---------------------------------------------------------------------------

function Invoke-PlaudRecordingDownload {
    <#
        Downloads the requested artifact types for one recording into a per-recording
        subfolder under $DownloadRoot. See module help for the returned summary shape.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Id,
        [Parameter(Mandatory = $true)][string]$DownloadRoot,
        [Parameter(Mandatory = $true)][string[]]$Types,
        [string]$AccessToken,
        [switch]$Overwrite
    )

    $saved    = New-Object System.Collections.ArrayList
    $skipped  = New-Object System.Collections.ArrayList
    $failures = New-Object System.Collections.ArrayList

    # 1. Fresh detail (fresh presigned links) + artifact list.
    $detail = Get-PlaudRecordingDetail -Id $Id -AccessToken $AccessToken
    if (-not $detail) { throw ('No detail returned for recording {0}.' -f $Id) }
    $full = Get-PlaudRecordingArtifacts -Detail $detail
    $name = $full.Name

    # 2. Per-recording folder.
    $folderName = ConvertTo-PlaudSafeName -Name $name
    $folder = Join-Path $DownloadRoot $folderName
    if (-not (Test-Path -LiteralPath $folder)) { New-Item -ItemType Directory -Path $folder -Force | Out-Null }

    # 3. Filter to available + requested, then order for safe link lifetimes.
    $selected = @($full.Artifacts | Where-Object { $_.Available -and (Test-PlaudArtifactSelected -Kind $_.Kind -Types $Types) })
    $ordered  = @($selected | Sort-Object -Property @{ Expression = { Get-PlaudArtifactRank -Kind $_.Kind } })

    Write-PlaudDownloadLog -Level INFO -Message ('Downloading {0} artifact(s) for "{1}" into {2}' -f $ordered.Count, $name, $folder)

    # 4. Write each artifact.
    foreach ($art in $ordered) {
        $target = Join-Path $folder $art.FileName
        if ((Test-Path -LiteralPath $target) -and (-not $Overwrite)) {
            $existing = Get-Item -LiteralPath $target -ErrorAction SilentlyContinue
            if ($existing -and $existing.Length -gt 0) {
                [void]$skipped.Add($art.FileName)
                Write-PlaudDownloadLog -Level DEBUG -Message ('Skip existing: {0}' -f $target)
                continue
            }
        }
        try {
            Save-PlaudArtifact -Artifact $art -TargetPath $target -RecordingName $name
            [void]$saved.Add($art.FileName)
            Write-PlaudDownloadLog -Level INFO -Message ('Saved: {0}' -f $target)
        } catch {
            [void]$failures.Add([pscustomobject]@{ Name = $art.FileName; Error = $_.Exception.Message })
            Write-PlaudDownloadLog -Level ERROR -Message ('Failed {0}: {1}' -f $art.FileName, $_.Exception.Message)
        }
    }

    return [pscustomobject]@{
        Id           = $Id
        Name         = $name
        Folder       = $folder
        SavedCount   = $saved.Count
        SkippedCount = $skipped.Count
        FailedCount  = $failures.Count
        Saved        = $saved.ToArray()
        Skipped      = $skipped.ToArray()
        Failures     = $failures.ToArray()
    }
}

Export-ModuleMember -Function @(
    'Invoke-PlaudRecordingDownload',
    'ConvertFrom-PlaudTranscript',
    'ConvertFrom-PlaudOutline'
)
