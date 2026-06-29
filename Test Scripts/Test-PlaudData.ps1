<#
.SYNOPSIS
    Verification harness for the Phase 2 PlaudData module.

.DESCRIPTION
    Exercises the data layer against your live Plaud account. Requires a valid session
    (run Test-PlaudAuth.ps1 -Login first). Pick one action per run.

.PARAMETER RawList
    Dump the raw first-page list envelope as JSON, to confirm the REST response shape
    (which wrapper key holds the array, whether a total/paging field exists, etc.).

.PARAMETER List
    Fetch ALL recordings and print the count plus the newest 20 (date, duration, name).

.PARAMETER Availability
    For the newest N recordings (-Top, default 8), fetch detail and print an availability
    table: Transcript / Summary / Notes / Audio (+ Polished / Outline + note tab count).

.PARAMETER Detail
    Dump the artifact descriptors (kind, available, source, suggested filename) for a
    single recording id.

.PARAMETER Top
    Number of recordings for -Availability (default 8).

.PARAMETER Id
    Recording id for -Detail.

.EXAMPLE
    .\Test-PlaudData.ps1 -RawList
.EXAMPLE
    .\Test-PlaudData.ps1 -List
.EXAMPLE
    .\Test-PlaudData.ps1 -Availability -Top 12
.EXAMPLE
    .\Test-PlaudData.ps1 -Detail -Id 2e136d5bc090adad523c91d175ecd32c
#>
[CmdletBinding(DefaultParameterSetName = 'List')]
param(
    [Parameter(ParameterSetName = 'RawList')]      [switch]$RawList,
    [Parameter(ParameterSetName = 'List')]         [switch]$List,
    [Parameter(ParameterSetName = 'Availability')] [switch]$Availability,
    [Parameter(ParameterSetName = 'Availability')] [int]$Top = 8,
    [Parameter(ParameterSetName = 'Detail')]       [switch]$Detail,
    [Parameter(ParameterSetName = 'Detail', Mandatory = $true)][string]$Id
)

# Import both modules fresh so edits are picked up. PlaudData uses PlaudAuth's token.
$authPath = Join-Path $PSScriptRoot 'src\PlaudAuth.psm1'
$dataPath = Join-Path $PSScriptRoot 'src\PlaudData.psm1'
foreach ($p in @($authPath, $dataPath)) { if (-not (Test-Path -LiteralPath $p)) { throw "Module not found: $p" } }
Import-Module $authPath -Force
Import-Module $dataPath -Force

# Confirm we are authenticated before doing anything else.
$token = Get-PlaudAccessToken
if (-not $token) {
    Write-Host 'No valid session. Run: .\Test-PlaudAuth.ps1 -Login' -ForegroundColor Red
    return
}

function Write-Mark { param([bool]$Value) if ($Value) { 'Yes' } else { '-' } }

switch ($PSCmdlet.ParameterSetName) {

    'RawList' {
        Write-Host '== RAW first-page list envelope ==' -ForegroundColor Cyan
        # Call the endpoint directly through the auth-aware path so we see the real shape.
        $uri = 'https://platform.plaud.ai/developer/api/open/third-party/files/?page=1&page_size=10'
        $headers = @{ Authorization = ('Bearer {0}' -f $token); Accept = 'application/json' }
        $resp = Invoke-WebRequest -Method Get -Uri $uri -Headers $headers -UseBasicParsing
        $json = [System.Text.Encoding]::UTF8.GetString($resp.RawContentStream.ToArray())
        # Pretty-print, but trim each recording to keep the dump readable.
        try {
            $obj = $json | ConvertFrom-Json
            Write-Host ('Top-level type: {0}' -f ($obj.GetType().Name))
            if ($obj -isnot [System.Array]) {
                Write-Host ('Top-level keys: {0}' -f (($obj.PSObject.Properties.Name) -join ', '))
            }
            $obj | ConvertTo-Json -Depth 4 | Write-Output
        } catch {
            Write-Output $json
        }
    }

    'Availability' {
        Write-Host ('== Availability for newest {0} recordings ==' -f $Top) -ForegroundColor Cyan
        $recordings = Get-PlaudRecordingList
        Write-Host ('Total recordings: {0}' -f @($recordings).Count) -ForegroundColor Green
        $subset = @($recordings | Select-Object -First $Top)
        $rows = foreach ($r in $subset) {
            $a = Get-PlaudRecordingAvailability -Id $r.Id
            [pscustomobject]@{
                When  = $r.When
                Dur   = $r.DurationText
                Tx    = (Write-Mark $a.Transcript)
                Sum   = (Write-Mark $a.Summary)
                Notes = (Write-Mark $a.Notes)
                Tabs  = $a.NoteTabCount
                Audio = (Write-Mark $a.Audio)
                Poly  = (Write-Mark $a.Polished)
                Name  = ($r.Name.Substring(0, [Math]::Min(50, $r.Name.Length)))
            }
        }
        $rows | Format-Table -AutoSize | Out-Host
    }

    'Detail' {
        Write-Host ('== Artifact descriptors for {0} ==' -f $Id) -ForegroundColor Cyan
        $d = Get-PlaudRecordingDetail -Id $Id
        if (-not $d) { Write-Host 'No detail returned.' -ForegroundColor Red; return }
        $full = Get-PlaudRecordingArtifacts -Detail $d
        Write-Host ('Name: {0}' -f $full.Name)
        $full.Artifacts |
            Select-Object Kind, Available, Source, DataType, TabName, FileName |
            Format-Table -AutoSize | Out-Host
    }

    default {
        Write-Host '== Recording list ==' -ForegroundColor Cyan
        $recordings = Get-PlaudRecordingList
        Write-Host ('Total recordings: {0}' -f @($recordings).Count) -ForegroundColor Green
        @($recordings | Select-Object -First 20) |
            Select-Object When, DurationText, Name |
            Format-Table -AutoSize | Out-Host
    }
}
