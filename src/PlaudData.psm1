<#
.SYNOPSIS
    PlaudData - Recording list / detail / availability layer for Plaud Exporter (Phase 2).

.DESCRIPTION
    Talks to the Plaud developer REST API (the same endpoints the CLI and the export
    script use) to:

        Get-PlaudRecordingList         - all recordings, paginated and normalized
        Get-PlaudRecordingDetail       - raw detail payload for one recording
        Get-PlaudRecordingAvailability - LIGHT per-recording availability (grid columns)
        Get-PlaudRecordingArtifacts    - HEAVY descriptors w/ download pointers (Phase 4)
        ConvertTo-PlaudSafeName        - Windows-safe file/folder name

    Endpoints:
        List   : GET {ApiBase}/open/third-party/files/?page={n}&page_size={m}
        Detail : GET {ApiBase}/open/third-party/files/{id}

    Availability mapping (verified against live payloads):
        Transcript : source_list entry data_type 'transaction' with non-empty data_content
        Summary    : note_list  entry data_type 'auto_sum_note'
        Notes      : note_list  entry of ANY other type (consumer_note, high_light, ...)
        Audio      : top-level presigned_url present
        Polished   : source_list entry data_type 'transaction_polish' with a data_link
        Outline    : source_list entry data_type 'outline' with non-empty data_content

    IMPORTANT (Phase 4): note / polished data_link presigned URLs expire in ~300s, while
    the audio presigned_url lasts ~24h. So the availability pass stores ONLY booleans; the
    download step must re-fetch the detail to obtain fresh links right before saving.

.NOTES
    - Windows PowerShell 5.1 compatible, ASCII-only source.
    - Requires PlaudAuth.psm1 to be imported (uses Get-PlaudAccessToken). Each public
      function also accepts an explicit -AccessToken to stay decoupled/testable.
    - Logs to %LOCALAPPDATA%\PlaudExporter\Logs (fallback %APPDATA%, then %TEMP%) with a PlaudData_ prefix.
#>

# ---------------------------------------------------------------------------
# Region: One-time setup
# ---------------------------------------------------------------------------

try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch { }

$script:ApiBase    = if ($env:PLAUD_API_BASE) { $env:PLAUD_API_BASE } else { 'https://platform.plaud.ai/developer/api' }
$script:ListPath   = '/open/third-party/files/'
$script:DetailPath = '/open/third-party/files/{0}'
$script:DefaultPageSize = 100   # API maximum observed page size
$script:MaxListPages    = 100   # hard guard against runaway pagination

function Resolve-PlaudDataLogDir {
    <# Same %LOCALAPPDATA% -> %APPDATA% -> %TEMP% policy used across the app. #>
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
$script:LogDir = Resolve-PlaudDataLogDir

function Write-PlaudDataLog {
    <#
        Logs via PlaudAuth's Write-PlaudLog when that module is loaded (so everything
        lands in one place); otherwise writes to a PlaudData_ file of its own.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR', 'DEBUG')][string]$Level = 'INFO'
    )
    if (Get-Command -Name Write-PlaudLog -ErrorAction SilentlyContinue) {
        Write-PlaudLog -Level $Level -Message $Message
        return
    }
    $stamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss.fff')
    $line  = '{0} [{1,-5}] {2}' -f $stamp, $Level, $Message
    try {
        $logFile = Join-Path $script:LogDir ('PlaudData_{0}.log' -f (Get-Date -Format 'yyyyMMdd'))
        Add-Content -LiteralPath $logFile -Value $line -Encoding ASCII -ErrorAction Stop
    } catch { }
    Write-Verbose $line
}

# ---------------------------------------------------------------------------
# Region: Auth + HTTP plumbing
# ---------------------------------------------------------------------------

function Resolve-PlaudToken {
    <#
        Returns a usable access token: the one passed in, or one obtained from
        PlaudAuth's Get-PlaudAccessToken. Throws a clear error if neither is available.
    #>
    param([string]$AccessToken)
    if ($AccessToken) { return $AccessToken }
    if (Get-Command -Name Get-PlaudAccessToken -ErrorAction SilentlyContinue) {
        $tok = Get-PlaudAccessToken
        if ($tok) { return $tok }
        throw 'No valid Plaud session. Run Connect-PlaudAccount (PlaudAuth) first.'
    }
    throw 'PlaudAuth module not loaded and no -AccessToken supplied. Import PlaudAuth.psm1 first.'
}

function Invoke-PlaudGet {
    <#
        Authenticated GET that decodes the body as UTF-8 by hand (Windows PowerShell 5.1
        Invoke-RestMethod can mangle UTF-8 JSON - e.g. accented names). Returns the parsed
        object. Throws on HTTP error so callers can react to 401 vs other failures.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$AccessToken
    )
    $uri     = $script:ApiBase + $Path
    $headers = @{ Authorization = ('Bearer {0}' -f $AccessToken); Accept = 'application/json' }
    if ($env:PLAUD_ENV)    { $headers['x-pld-env']    = $env:PLAUD_ENV }
    if ($env:PLAUD_REGION) { $headers['x-pld-region'] = $env:PLAUD_REGION }

    $resp  = Invoke-WebRequest -Method Get -Uri $uri -Headers $headers -UseBasicParsing -ErrorAction Stop
    $bytes = $resp.RawContentStream.ToArray()
    if ($bytes.Length -eq 0) { return $null }
    $json  = [System.Text.Encoding]::UTF8.GetString($bytes)
    return ($json | ConvertFrom-Json)
}

# ---------------------------------------------------------------------------
# Region: Small formatting / naming helpers
# ---------------------------------------------------------------------------

function Format-PlaudDuration {
    <# Milliseconds -> "h:mm:ss" (or "m:ss" under an hour) for display. #>
    param([long]$Ms)
    if ($Ms -le 0) { return '0:00' }
    $total = [math]::Floor($Ms / 1000)
    $h = [math]::Floor($total / 3600)
    $m = [math]::Floor(($total % 3600) / 60)
    $s = $total % 60
    if ($h -gt 0) { return ('{0}:{1:d2}:{2:d2}' -f [int]$h, [int]$m, [int]$s) }
    return ('{0}:{1:d2}' -f [int]$m, [int]$s)
}

function ConvertTo-PlaudSafeName {
    <#
        Makes a string safe for a Windows file or folder name:
          - removes characters Windows forbids ( < > : " / \ | ? * ) and control chars
          - collapses whitespace, trims trailing dots/spaces
          - guards reserved device names (CON, PRN, AUX, NUL, COM1-9, LPT1-9)
          - caps length (default 120) to help keep full paths under MAX_PATH
        Legal symbols (& # ( ) , - etc.) are preserved.
    #>
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Name,
        [int]$MaxLength = 120
    )
    if ([string]::IsNullOrWhiteSpace($Name)) { return 'untitled' }
    # Replace forbidden and control characters with a space.
    $clean = [System.Text.RegularExpressions.Regex]::Replace($Name, '[<>:"/\\|?*\x00-\x1F]', ' ')
    # Collapse runs of whitespace and trim.
    $clean = [System.Text.RegularExpressions.Regex]::Replace($clean, '\s+', ' ').Trim()
    # Trim trailing dots/spaces (illegal at end of a Windows name).
    $clean = $clean.TrimEnd('.', ' ')
    if ([string]::IsNullOrWhiteSpace($clean)) { return 'untitled' }
    # Reserved device names (case-insensitive, with or without extension).
    $reserved = '^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(\.|$)'
    if ([System.Text.RegularExpressions.Regex]::IsMatch($clean, $reserved, 'IgnoreCase')) {
        $clean = '_' + $clean
    }
    if ($clean.Length -gt $MaxLength) { $clean = $clean.Substring(0, $MaxLength).TrimEnd('.', ' ') }
    return $clean
}

function Get-PlaudUrlExtension {
    <# Best-effort file extension from a URL path (default '.mp3' for audio). #>
    param([string]$Url, [string]$Default = '.mp3')
    if ([string]::IsNullOrWhiteSpace($Url)) { return $Default }
    try {
        $path = ([Uri]$Url).AbsolutePath
        $ext  = [System.IO.Path]::GetExtension($path)
        if ($ext) { return $ext }
    } catch { }
    return $Default
}

# ---------------------------------------------------------------------------
# Region: Recording list
# ---------------------------------------------------------------------------

function Get-PlaudListItems {
    <#
        Defensively extracts the array of recording items from the list response,
        whether the API returns a bare array or wraps it under data/items/results/etc.
    #>
    param($Response)
    if ($null -eq $Response) { return @() }
    if ($Response -is [System.Array]) { return $Response }
    foreach ($prop in 'data', 'items', 'results', 'files', 'list') {
        if ($Response.PSObject.Properties.Name -contains $prop -and $null -ne $Response.$prop) {
            return @($Response.$prop)
        }
    }
    return @()
}

function ConvertTo-PlaudRecording {
    <# Normalizes one raw list item into the app's recording object. #>
    param([Parameter(Mandatory = $true)]$Item)
    $durationMs = 0
    if ($Item.PSObject.Properties.Name -contains 'duration' -and $Item.duration) { $durationMs = [long]$Item.duration }
    # Prefer start_at for the "when" column, fall back to created_at.
    $when = if ($Item.start_at) { $Item.start_at } else { $Item.created_at }
    return [pscustomobject]@{
        Id           = $Item.id
        Name         = $Item.name
        StartAt      = $Item.start_at
        CreatedAt    = $Item.created_at
        When         = $when
        DurationMs   = $durationMs
        DurationText = (Format-PlaudDuration -Ms $durationMs)
        SerialNumber = $Item.serial_number
    }
}

function Get-PlaudRecordingList {
    <#
        Returns ALL recordings as normalized objects, newest first. Pages through the
        list endpoint until a short page is returned (or the page guard trips).
    #>
    [CmdletBinding()]
    param(
        [string]$AccessToken,
        [int]$PageSize = $script:DefaultPageSize,
        $DateFrom = $null,   # DateTime, 'yyyy-MM-dd', or $null - inclusive lower bound (by recording date)
        $DateTo   = $null    # DateTime, 'yyyy-MM-dd', or $null - inclusive upper bound
    )

    # Normalize optional date bounds into a start-of-day .. end-of-day window.
    $fromDt = $null
    if ($DateFrom) {
        if ($DateFrom -is [datetime]) { $fromDt = $DateFrom.Date }
        else { $t = [datetime]::MinValue; if ([datetime]::TryParse([string]$DateFrom, [ref]$t)) { $fromDt = $t.Date } }
    }
    $toDt = $null
    if ($DateTo) {
        if ($DateTo -is [datetime]) { $toDt = $DateTo.Date.AddDays(1).AddSeconds(-1) }
        else { $t = [datetime]::MinValue; if ([datetime]::TryParse([string]$DateTo, [ref]$t)) { $toDt = $t.Date.AddDays(1).AddSeconds(-1) } }
    }

    $token = Resolve-PlaudToken -AccessToken $AccessToken
    $all   = New-Object System.Collections.Generic.List[object]
    $page  = 1
    do {
        $path = '{0}?page={1}&page_size={2}' -f $script:ListPath, $page, $PageSize
        Write-PlaudDataLog -Level DEBUG -Message ('Fetching recording list page {0} (size {1}).' -f $page, $PageSize)
        $resp  = Invoke-PlaudGet -Path $path -AccessToken $token
        $items = Get-PlaudListItems -Response $resp
        $count = @($items).Count
        foreach ($it in $items) { $all.Add((ConvertTo-PlaudRecording -Item $it)) }
        $page++
    } while ($count -eq $PageSize -and $page -le $script:MaxListPages)

    Write-PlaudDataLog -Level INFO -Message ('Retrieved {0} recordings.' -f $all.Count)

    # Optional client-side date filter (re-query path: caller asks for a specific window).
    if ($fromDt -or $toDt) {
        $before = $all.Count
        $all = @($all | Where-Object {
            $d = [datetime]::MinValue
            if ([datetime]::TryParse($_.When, [ref]$d)) {
                ((-not $fromDt) -or ($d -ge $fromDt)) -and ((-not $toDt) -or ($d -le $toDt))
            } else { $false }
        })
        $fromStr = if ($fromDt) { $fromDt.ToString('yyyy-MM-dd') } else { '*' }
        $toStr   = if ($toDt)   { $toDt.ToString('yyyy-MM-dd') }   else { '*' }
        Write-PlaudDataLog -Level INFO -Message ('Date filter [{0}..{1}] kept {2} of {3} recordings.' -f $fromStr, $toStr, @($all).Count, $before)
    }

    # Sort newest first by When (string ISO dates sort correctly; parse where possible).
    $sorted = $all | Sort-Object -Property @{ Expression = {
        $dt = [datetime]::MinValue
        [void][datetime]::TryParse($_.When, [ref]$dt)
        $dt
    } } -Descending
    return $sorted
}

# ---------------------------------------------------------------------------
# Region: Recording detail + availability
# ---------------------------------------------------------------------------

function Get-PlaudRecordingDetail {
    <# Returns the raw detail payload (note_list, source_list, presigned_url, ...). #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Id,
        [string]$AccessToken
    )
    $token = Resolve-PlaudToken -AccessToken $AccessToken
    $path  = $script:DetailPath -f $Id
    return Invoke-PlaudGet -Path $path -AccessToken $token
}

function Test-PlaudHasText {
    <# True when a value is a non-empty / non-whitespace string. #>
    param($Value)
    return (-not [string]::IsNullOrWhiteSpace([string]$Value))
}

function Get-PlaudRecordingArtifacts {
    <#
        HEAVY: given a detail payload, returns availability booleans AND a list of
        artifact descriptors that the Phase 4 download engine consumes directly.

        Each artifact descriptor:
            Kind         - Transcript | PolishedTranscript | Outline | Summary | Note | Audio
            Available    - [bool]
            TabName      - human tab name (notes)
            Source       - Inline | Link | Presigned   (how to fetch the bytes)
            Pointer      - inline content string, OR a presigned URL (Link/Presigned)
            FileName     - suggested file name within the recording's folder
            DataType     - raw Plaud data_type (for logging/debugging)

        NOTE: Pointers for Link/Presigned artifacts are time-limited (notes/polished
        ~300s). Always call this on a freshly fetched detail at download time.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Detail)

    $sources = @($Detail.source_list)
    $notes   = @($Detail.note_list)
    $artifacts = New-Object System.Collections.Generic.List[object]

    # NOTE: PowerShell 5.1 does not allow a parenthesized 'if' as an expression inside a
    # hashtable literal, so every conditional value below is precomputed into a variable
    # first, then placed into the [pscustomobject] hashtable.

    # --- Transcript (plain, inline JSON) ---
    $tx = $sources | Where-Object { $_.data_type -eq 'transaction' } | Select-Object -First 1
    $hasTranscript = [bool]($tx -and (Test-PlaudHasText $tx.data_content))
    $txPointer = $null
    if ($tx) { $txPointer = $tx.data_content }
    $artifacts.Add([pscustomobject]@{
        Kind = 'Transcript'; Available = $hasTranscript; TabName = $null
        Source = 'Inline'; Pointer = $txPointer
        FileName = 'Transcript.txt'; DataType = 'transaction'
    })

    # --- Polished transcript (downloadable link) ---
    $poly = $sources | Where-Object { $_.data_type -eq 'transaction_polish' } | Select-Object -First 1
    $hasPolished = [bool]($poly -and (Test-PlaudHasText $poly.data_link))
    $polyPointer = $null
    if ($poly) { $polyPointer = $poly.data_link }
    $artifacts.Add([pscustomobject]@{
        Kind = 'PolishedTranscript'; Available = $hasPolished; TabName = $null
        Source = 'Link'; Pointer = $polyPointer
        FileName = 'Polished Transcript.md'; DataType = 'transaction_polish'
    })

    # --- Outline (inline JSON topics) ---
    $out = $sources | Where-Object { $_.data_type -eq 'outline' } | Select-Object -First 1
    $hasOutline = [bool]($out -and (Test-PlaudHasText $out.data_content))
    $outPointer = $null
    if ($out) { $outPointer = $out.data_content }
    $artifacts.Add([pscustomobject]@{
        Kind = 'Outline'; Available = $hasOutline; TabName = $null
        Source = 'Inline'; Pointer = $outPointer
        FileName = 'Outline.md'; DataType = 'outline'
    })

    # --- Summary (auto_sum_note; inline content, occasionally a link) ---
    $sum = $notes | Where-Object { $_.data_type -eq 'auto_sum_note' } | Select-Object -First 1
    $sumInline = [bool]($sum -and (Test-PlaudHasText $sum.data_content))
    $sumLink   = [bool]($sum -and (Test-PlaudHasText $sum.data_link))
    $hasSummary = [bool]($sumInline -or $sumLink)
    $sumSource  = 'Link'
    $sumPointer = $null
    if ($sumInline) { $sumSource = 'Inline'; $sumPointer = $sum.data_content }
    elseif ($sum)   { $sumSource = 'Link';   $sumPointer = $sum.data_link }
    $artifacts.Add([pscustomobject]@{
        Kind = 'Summary'; Available = $hasSummary; TabName = 'Summary'
        Source = $sumSource; Pointer = $sumPointer
        FileName = 'Summary.md'; DataType = 'auto_sum_note'
    })

    # --- Custom notes (every note tab that is NOT the auto summary) ---
    $customNotes = @($notes | Where-Object {
        $_.data_type -ne 'auto_sum_note' -and ((Test-PlaudHasText $_.data_content) -or (Test-PlaudHasText $_.data_link))
    })
    $usedNames = @{}
    foreach ($n in $customNotes) {
        if (Test-PlaudHasText $n.data_tab_name)   { $tab = $n.data_tab_name }
        elseif (Test-PlaudHasText $n.data_title)  { $tab = $n.data_title }
        else                                      { $tab = $n.data_type }
        $safe = ConvertTo-PlaudSafeName -Name $tab -MaxLength 80
        # De-duplicate identical tab names within one recording.
        $fileBase = $safe
        $i = 2
        while ($usedNames.ContainsKey($fileBase.ToLower())) { $fileBase = ('{0} ({1})' -f $safe, $i); $i++ }
        $usedNames[$fileBase.ToLower()] = $true

        $noteInline = (Test-PlaudHasText $n.data_content)
        if ($noteInline) { $noteSource = 'Inline'; $notePointer = $n.data_content }
        else             { $noteSource = 'Link';   $notePointer = $n.data_link }
        $artifacts.Add([pscustomobject]@{
            Kind = 'Note'; Available = $true; TabName = $tab
            Source = $noteSource; Pointer = $notePointer
            FileName = ('{0}.md' -f $fileBase); DataType = $n.data_type
        })
    }
    $hasNotes = [bool]($customNotes.Count -gt 0)

    # --- Audio (top-level presigned URL; ~24h lifetime) ---
    $audioUrl = $Detail.presigned_url
    $hasAudio = [bool](Test-PlaudHasText $audioUrl)
    $audioExt = Get-PlaudUrlExtension -Url $audioUrl -Default '.mp3'
    $artifacts.Add([pscustomobject]@{
        Kind = 'Audio'; Available = $hasAudio; TabName = $null
        Source = 'Presigned'; Pointer = $audioUrl
        FileName = ('Audio{0}' -f $audioExt); DataType = 'audio'
    })

    # Precompute the custom-note tab-name list (no inline if inside the hashtable).
    $noteTabNames = @($customNotes | ForEach-Object {
        if (Test-PlaudHasText $_.data_tab_name)  { $_.data_tab_name }
        elseif (Test-PlaudHasText $_.data_title) { $_.data_title }
        else                                     { $_.data_type }
    })

    $availability = [pscustomobject]@{
        Transcript   = $hasTranscript
        Summary      = $hasSummary
        Notes        = $hasNotes
        Audio        = $hasAudio
        Polished     = $hasPolished
        Outline      = $hasOutline
        NoteTabCount = $customNotes.Count
        NoteTabNames = $noteTabNames
    }
    return [pscustomobject]@{
        Id           = $Detail.id
        Name         = $Detail.name
        Availability = $availability
        Artifacts    = $artifacts.ToArray()
    }
}

function Get-PlaudRecordingAvailability {
    <#
        LIGHT: returns just the availability summary for one recording (the data the
        GUI grid needs). Accepts either a -Detail object or an -Id to fetch. Carries no
        large content pointers, so it is safe to hold for every recording in the grid.
    #>
    [CmdletBinding(DefaultParameterSetName = 'ById')]
    param(
        [Parameter(Mandatory = $true, ParameterSetName = 'ById')][string]$Id,
        [Parameter(Mandatory = $true, ParameterSetName = 'ByDetail')]$Detail,
        [string]$AccessToken
    )
    if ($PSCmdlet.ParameterSetName -eq 'ById') {
        $Detail = Get-PlaudRecordingDetail -Id $Id -AccessToken $AccessToken
    }
    if (-not $Detail) { return $null }
    $full = Get-PlaudRecordingArtifacts -Detail $Detail
    $a = $full.Availability
    return [pscustomobject]@{
        Id           = $full.Id
        Name         = $full.Name
        Transcript   = $a.Transcript
        Summary      = $a.Summary
        Notes        = $a.Notes
        Audio        = $a.Audio
        Polished     = $a.Polished
        Outline      = $a.Outline
        NoteTabCount = $a.NoteTabCount
        NoteTabNames = $a.NoteTabNames
    }
}

# ---------------------------------------------------------------------------
# Region: Exports
# ---------------------------------------------------------------------------
Export-ModuleMember -Function @(
    'Get-PlaudRecordingList',
    'Get-PlaudRecordingDetail',
    'Get-PlaudRecordingAvailability',
    'Get-PlaudRecordingArtifacts',
    'ConvertTo-PlaudSafeName',
    'Format-PlaudDuration'
)
