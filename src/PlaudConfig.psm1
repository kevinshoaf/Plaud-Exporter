<#
.SYNOPSIS
    PlaudConfig - persistent settings for Plaud Exporter (download path, parallelism,
    artifact-type selections).

.DESCRIPTION
    Stores a small JSON config at %APPDATA%\PlaudExporter\config.json. Missing keys are
    backfilled with defaults on load, so older config files keep working as the app grows.

.NOTES
    Windows PowerShell 5.1 compatible, ASCII-only source.
#>

$script:ConfigDir  = Join-Path $env:APPDATA 'PlaudExporter'
$script:ConfigFile = Join-Path $script:ConfigDir 'config.json'

function Get-PlaudConfigDefaults {
    <# The canonical default config. Also defines the full set of valid keys. #>
    return [pscustomobject]@{
        DownloadPath  = (Join-Path $env:USERPROFILE 'Downloads\PlaudExports')
        MaxParallel   = 5
        Overwrite     = $false
        ArtifactTypes = [pscustomobject]@{
            Transcript = $true
            Summary    = $true
            Notes      = $true
            Audio      = $true
            Polished   = $false
            Outline    = $false
        }
    }
}

function Get-PlaudConfigPath { return $script:ConfigFile }

function Get-PlaudConfig {
    <#
        Loads the config, merging in any missing keys from defaults. Returns the default
        config (without writing it) if the file is absent or unreadable.
    #>
    [CmdletBinding()]
    param()
    $defaults = Get-PlaudConfigDefaults
    if (-not (Test-Path -LiteralPath $script:ConfigFile)) { return $defaults }
    try {
        $raw = Get-Content -LiteralPath $script:ConfigFile -Raw -Encoding UTF8 | ConvertFrom-Json
    } catch {
        return $defaults
    }

    # Top-level scalar keys (precomputed; PS 5.1-safe, no inline if in the literal).
    $dlPath = if ($raw.DownloadPath) { [string]$raw.DownloadPath } else { $defaults.DownloadPath }
    $maxPar = if ($raw.MaxParallel)  { [int]$raw.MaxParallel }     else { $defaults.MaxParallel }
    $ovr    = if ($null -ne $raw.Overwrite) { [bool]$raw.Overwrite } else { $defaults.Overwrite }
    $cfg = [pscustomobject]@{
        DownloadPath  = $dlPath
        MaxParallel   = $maxPar
        Overwrite     = $ovr
        ArtifactTypes = $defaults.ArtifactTypes
    }
    # Clamp parallelism to a sane range.
    if ($cfg.MaxParallel -lt 1)  { $cfg.MaxParallel = 1 }
    if ($cfg.MaxParallel -gt 10) { $cfg.MaxParallel = 10 }

    # Artifact-type booleans (each falls back to its default when absent).
    if ($raw.ArtifactTypes) {
        foreach ($key in 'Transcript', 'Summary', 'Notes', 'Audio', 'Polished', 'Outline') {
            if ($null -ne $raw.ArtifactTypes.$key) {
                $cfg.ArtifactTypes.$key = [bool]$raw.ArtifactTypes.$key
            }
        }
    }
    return $cfg
}

function Save-PlaudConfig {
    <# Persists the given config object to disk, creating the folder if needed. #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][psobject]$Config)
    if (-not (Test-Path -LiteralPath $script:ConfigDir)) {
        New-Item -ItemType Directory -Path $script:ConfigDir -Force | Out-Null
    }
    $Config | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $script:ConfigFile -Encoding UTF8
}

Export-ModuleMember -Function @('Get-PlaudConfig', 'Save-PlaudConfig', 'Get-PlaudConfigPath', 'Get-PlaudConfigDefaults')
