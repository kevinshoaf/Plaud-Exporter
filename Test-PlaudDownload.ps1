<#
.SYNOPSIS
    Verification harness for the Phase 4 download engine (no GUI).

.DESCRIPTION
    Downloads the selected artifact types for ONE recording and prints the summary plus
    the files that landed on disk. Requires a valid session (Test-PlaudAuth.ps1 -Login).

.PARAMETER Id
    Recording id (from Test-PlaudData.ps1 -List).

.PARAMETER To
    Download root. Defaults to %TEMP%\PlaudExportTest.

.PARAMETER All
    Include every artifact type (Transcript, Summary, Notes, Audio, Polished, Outline).

.PARAMETER NoAudio
    Convenience switch: Transcript + Summary + Notes only (skip the large audio file).

.PARAMETER Overwrite
    Re-download even if files already exist (otherwise existing non-empty files are skipped).

.EXAMPLE
    .\Test-PlaudDownload.ps1 -Id 2e136d5bc090adad523c91d175ecd32c -All
.EXAMPLE
    .\Test-PlaudDownload.ps1 -Id 2e136d5bc090adad523c91d175ecd32c -NoAudio -Overwrite
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Id,
    [string]$To = (Join-Path $env:TEMP 'PlaudExportTest'),
    [switch]$All,
    [switch]$NoAudio,
    [switch]$Overwrite
)

$authPath = Join-Path $PSScriptRoot 'src\PlaudAuth.psm1'
$dataPath = Join-Path $PSScriptRoot 'src\PlaudData.psm1'
$dlPath   = Join-Path $PSScriptRoot 'src\PlaudDownload.psm1'
foreach ($p in @($authPath, $dataPath, $dlPath)) { if (-not (Test-Path -LiteralPath $p)) { throw "Module not found: $p" } }
Import-Module $authPath -Force
Import-Module $dataPath -Force
Import-Module $dlPath   -Force

$token = Get-PlaudAccessToken
if (-not $token) { Write-Host 'No valid session. Run: .\Test-PlaudAuth.ps1 -Login' -ForegroundColor Red; return }

if ($All) {
    $types = @('Transcript', 'Summary', 'Notes', 'Audio', 'PolishedTranscript', 'Outline')
} elseif ($NoAudio) {
    $types = @('Transcript', 'Summary', 'Notes')
} else {
    $types = @('Transcript', 'Summary', 'Notes', 'Audio')
}

Write-Host ('Downloading {0} into {1}' -f $Id, $To) -ForegroundColor Cyan
Write-Host ('Types: {0}' -f ($types -join ', '))
Write-Host ('Overwrite: {0}' -f [bool]$Overwrite)
Write-Host ''

$res = Invoke-PlaudRecordingDownload -Id $Id -DownloadRoot $To -Types $types -AccessToken $token -Overwrite:$Overwrite

Write-Host ('Recording: {0}' -f $res.Name) -ForegroundColor Green
Write-Host ('Folder   : {0}' -f $res.Folder)
Write-Host ('Saved    : {0}  Skipped: {1}  Failed: {2}' -f $res.SavedCount, $res.SkippedCount, $res.FailedCount)
if ($res.SavedCount -gt 0)   { Write-Host ('  Saved:   {0}' -f ($res.Saved -join ', ')) }
if ($res.SkippedCount -gt 0) { Write-Host ('  Skipped: {0}' -f ($res.Skipped -join ', ')) -ForegroundColor Yellow }
if ($res.FailedCount -gt 0) {
    Write-Host '  Failures:' -ForegroundColor Red
    foreach ($f in $res.Failures) { Write-Host ('    {0} -> {1}' -f $f.Name, $f.Error) -ForegroundColor Red }
}

Write-Host ''
Write-Host 'Files on disk:' -ForegroundColor Cyan
if (Test-Path -LiteralPath $res.Folder) {
    Get-ChildItem -LiteralPath $res.Folder | Select-Object Name, @{N = 'KB'; E = { [math]::Round($_.Length / 1KB, 1) } } | Format-Table -AutoSize | Out-Host
}
