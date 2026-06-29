<#
.SYNOPSIS
    Verification harness for the Phase 1 PlaudAuth module.

.DESCRIPTION
    Run on a Windows box (PowerShell 5.1) to verify each auth capability in isolation.
    Pick exactly one action switch per run. Default action is -Status.

.PARAMETER Login
    Run the interactive browser login (Connect-PlaudAccount), then show the user.

.PARAMETER Status
    Show whether a valid session exists (Test-PlaudSession) and the current user.

.PARAMETER Refresh
    Force a token read/refresh cycle (Get-PlaudAccessToken) and show a masked token.

.PARAMETER ImportCli
    Import tokens from the Plaud CLI store as the fallback path (Import-PlaudCliSession).

.PARAMETER Logout
    Revoke server-side and clear the local session (Disconnect-PlaudAccount).

.PARAMETER Force
    Passed through to -Login / -ImportCli to override an existing valid session.

.EXAMPLE
    .\Test-PlaudAuth.ps1 -Login -Verbose
.EXAMPLE
    .\Test-PlaudAuth.ps1 -Status
.EXAMPLE
    .\Test-PlaudAuth.ps1 -Logout
#>
[CmdletBinding(DefaultParameterSetName = 'Status')]
param(
    [Parameter(ParameterSetName = 'Login')]    [switch]$Login,
    [Parameter(ParameterSetName = 'Status')]   [switch]$Status,
    [Parameter(ParameterSetName = 'Refresh')]  [switch]$Refresh,
    [Parameter(ParameterSetName = 'ImportCli')][switch]$ImportCli,
    [Parameter(ParameterSetName = 'Logout')]   [switch]$Logout,
    [switch]$Force
)

# Import the module fresh each run so edits are picked up.
$modulePath = Join-Path $PSScriptRoot 'src\PlaudAuth.psm1'
if (-not (Test-Path -LiteralPath $modulePath)) { throw "Module not found at $modulePath" }
Import-Module $modulePath -Force

function Show-MaskedToken {
    param([string]$Token)
    if (-not $Token) { return '<none>' }
    if ($Token.Length -le 12) { return '<short token>' }
    return ('{0}...{1} (len {2})' -f $Token.Substring(0, 6), $Token.Substring($Token.Length - 4), $Token.Length)
}

function Show-User {
    param($User)
    if (-not $User) { Write-Host 'No user (not authenticated).' -ForegroundColor Red; return }
    Write-Host 'Authenticated user:' -ForegroundColor Green
    $User | Format-List | Out-Host
}

$ctx = Get-PlaudAuthContext
Write-Host '--- Plaud Auth context ---' -ForegroundColor Cyan
Write-Host ('  Client ID    : {0}' -f $ctx.ClientId)
Write-Host ('  Redirect URI : {0}' -f $ctx.RedirectUri)
Write-Host ('  Session file : {0}' -f $ctx.SessionFile)
Write-Host ('  CLI tokens   : {0}' -f $ctx.CliTokenFile)
Write-Host ('  Log dir      : {0}' -f $ctx.LogDir)
Write-Host ''

switch ($PSCmdlet.ParameterSetName) {

    'Login' {
        Write-Host '== ACTION: Interactive login ==' -ForegroundColor Cyan
        $user = Connect-PlaudAccount -Force:$Force
        Show-User $user
    }

    'Refresh' {
        Write-Host '== ACTION: Get/refresh access token ==' -ForegroundColor Cyan
        $token = Get-PlaudAccessToken
        Write-Host ('Access token: {0}' -f (Show-MaskedToken $token))
        if ($token) {
            $user = Get-PlaudCurrentUser -AccessToken $token
            Show-User $user
        }
    }

    'ImportCli' {
        Write-Host '== ACTION: Import CLI session (fallback) ==' -ForegroundColor Cyan
        $user = Import-PlaudCliSession -Force:$Force
        Show-User $user
    }

    'Logout' {
        Write-Host '== ACTION: Logout (revoke + clear) ==' -ForegroundColor Cyan
        Disconnect-PlaudAccount
        Write-Host ('Session file still present? {0}' -f (Test-Path -LiteralPath $ctx.SessionFile))
    }

    default {
        Write-Host '== ACTION: Status ==' -ForegroundColor Cyan
        $valid = Test-PlaudSession
        Write-Host ('Valid session: {0}' -f $valid) -ForegroundColor ($(if ($valid) { 'Green' } else { 'Yellow' }))
        if ($valid) { Show-User (Get-PlaudCurrentUser) }
        else { Write-Host 'Run with -Login to authenticate.' -ForegroundColor Yellow }
    }
}
