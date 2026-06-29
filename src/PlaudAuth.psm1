<#
.SYNOPSIS
    PlaudAuth - Authentication module for the Plaud Exporter app (Phase 1).

.DESCRIPTION
    Implements the same OAuth 2.0 Authorization Code + PKCE flow that the official
    Plaud CLI (@plaud-ai/cli v0.3.3) uses, so the user logs in through Plaud's own
    web page and this app never sees their password. The module handles:

        Connect-PlaudAccount      - interactive browser login (PKCE) + token capture
        Get-PlaudAccessToken      - returns a valid access token, refreshing if needed
        Get-PlaudCurrentUser      - validates a token via /users/current
        Test-PlaudSession         - boolean "are we logged in and valid?"
        Import-PlaudCliSession    - FALLBACK: import tokens written by `plaud login`
        Disconnect-PlaudAccount   - server-side revoke + clear the local session
        Get-PlaudAuthContext      - paths/constants for the rest of the app

    Auth endpoints / client (extracted from the CLI bundle, overridable via env):
        Authorization page : https://web.plaud.ai/platform/oauth
        Token endpoint     : https://platform.plaud.ai/developer/api/oauth/third-party/access-token
        Refresh endpoint   : .../access-token/refresh
        Public client_id   : client_f9e0b214-c11f-434b-8b95-c4497d1feb81  (client_secret empty)
        Redirect URI       : http://localhost:8199/auth/callback   (port 8199 is FIXED by Plaud)
        Validate           : GET  /open/third-party/users/current
        Revoke (logout)    : POST /open/third-party/users/current/revoke

    Tokens are stored DPAPI-encrypted (CurrentUser scope) at
    %APPDATA%\PlaudExporter\session.dat so the session survives app restarts until
    it expires or the user logs out.

.NOTES
    Conventions:
      - Windows PowerShell 5.1 compatible, ASCII-only source.
      - Logs to %LOCALAPPDATA%\PlaudExporter\Logs (fallback %APPDATA%, then %TEMP%).
      - All public functions log their activity and surface errors instead of swallowing them.

    This module CANNOT be unit-run in a non-Windows / headless environment (it needs a
    browser and DPAPI). Use Test-PlaudAuth.ps1 on a Windows box to verify.
#>

# ---------------------------------------------------------------------------
# Region: One-time module setup
# ---------------------------------------------------------------------------

# Ensure TLS 1.2 for all HTTPS calls on Windows PowerShell 5.1 (older default
# protocols are rejected by the Plaud endpoints).
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch { }

# DPAPI lives in the System.Security assembly. Load it once.
try { Add-Type -AssemblyName System.Security -ErrorAction Stop } catch { }

# --- OAuth / API constants (env overrides mirror the CLI's own override knobs) ---
$script:ClientId         = if ($env:PLAUD_CLI_CLIENT_ID) { $env:PLAUD_CLI_CLIENT_ID }
                           elseif ($env:PLAUD_CLIENT_ID) { $env:PLAUD_CLIENT_ID }
                           else { 'client_f9e0b214-c11f-434b-8b95-c4497d1feb81' }
$script:ClientSecret     = if ($null -ne $env:PLAUD_CLIENT_SECRET) { $env:PLAUD_CLIENT_SECRET } else { '' }
$script:RedirectUri      = 'http://localhost:8199/auth/callback'
$script:CallbackPort     = 8199
$script:CallbackPath     = '/auth/callback'
$script:AuthorizationUrl = if ($env:PLAUD_AUTH_URL)    { $env:PLAUD_AUTH_URL }    else { 'https://web.plaud.ai/platform/oauth' }
$script:TokenUrl         = if ($env:PLAUD_TOKEN_URL)   { $env:PLAUD_TOKEN_URL }   else { 'https://platform.plaud.ai/developer/api/oauth/third-party/access-token' }
$script:RefreshUrl       = if ($env:PLAUD_REFRESH_URL) { $env:PLAUD_REFRESH_URL } else { 'https://platform.plaud.ai/developer/api/oauth/third-party/access-token/refresh' }
$script:ApiBase          = if ($env:PLAUD_API_BASE)    { $env:PLAUD_API_BASE }    else { 'https://platform.plaud.ai/developer/api' }
$script:UserCurrentPath  = '/open/third-party/users/current'
$script:RevokePath       = '/open/third-party/users/current/revoke'

$script:LoginTimeoutMs   = 120000   # 2 minutes, matching the CLI
$script:RefreshSkewMs    = 60000    # refresh when within 60s of expiry, matching the CLI

# --- Filesystem paths ---
$script:AppDir       = Join-Path $env:APPDATA 'PlaudExporter'
$script:SessionFile  = Join-Path $script:AppDir 'session.dat'
$script:CliTokenFile = Join-Path $env:USERPROFILE '.plaud\tokens.json'

# Resolve the log directory once (%LOCALAPPDATA% -> %APPDATA% -> %TEMP%), then ensure it exists.
function Resolve-PlaudLogDir {
    <# Returns a writable per-user log directory (%LOCALAPPDATA% -> %APPDATA% -> %TEMP%). #>
    $candidates = @()
    if ($env:LOCALAPPDATA) { $candidates += (Join-Path $env:LOCALAPPDATA 'PlaudExporter\Logs') }
    if ($env:APPDATA)      { $candidates += (Join-Path $env:APPDATA 'PlaudExporter\Logs') }
    $candidates += (Join-Path $env:TEMP 'PlaudExporter\Logs')
    foreach ($dir in $candidates) {
        try {
            if (-not (Test-Path -LiteralPath $dir)) {
                New-Item -ItemType Directory -Path $dir -Force -ErrorAction Stop | Out-Null
            }
            return $dir
        } catch { continue }
    }
    # Should never get here, but never let logging crash the app.
    return $env:TEMP
}
$script:LogDir = Resolve-PlaudLogDir

# ---------------------------------------------------------------------------
# Region: Logging
# ---------------------------------------------------------------------------

function Write-PlaudLog {
    <#
        Appends a timestamped line to the daily log file and echoes to the verbose
        stream. Secrets are never logged by callers; this helper does no redaction
        of its own, so callers must not pass tokens in the message.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR', 'DEBUG')][string]$Level = 'INFO'
    )
    $stamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss.fff')
    $line  = '{0} [{1,-5}] {2}' -f $stamp, $Level, $Message
    try {
        $logFile = Join-Path $script:LogDir ('PlaudAuth_{0}.log' -f (Get-Date -Format 'yyyyMMdd'))
        Add-Content -LiteralPath $logFile -Value $line -Encoding ASCII -ErrorAction Stop
    } catch {
        # Logging must never throw. Fall back to the verbose stream only.
    }
    Write-Verbose $line
}

# ---------------------------------------------------------------------------
# Region: Small crypto / encoding helpers
# ---------------------------------------------------------------------------

function ConvertTo-PlaudBase64Url {
    <# RFC 7636 base64url: standard base64 with +/ -> -_ and '=' padding stripped. #>
    param([Parameter(Mandatory = $true)][byte[]]$Bytes)
    return ([Convert]::ToBase64String($Bytes)).TrimEnd('=').Replace('+', '-').Replace('/', '_')
}

function New-PlaudRandomBytes {
    <# Cryptographically strong random bytes via RNGCryptoServiceProvider. #>
    param([Parameter(Mandatory = $true)][int]$Count)
    $buffer = New-Object 'System.Byte[]' $Count
    $rng = [System.Security.Cryptography.RNGCryptoServiceProvider]::new()
    try { $rng.GetBytes($buffer) } finally { $rng.Dispose() }
    return $buffer
}

function New-PlaudPkcePair {
    <#
        Builds the PKCE verifier/challenge/state exactly like the CLI:
          verifier  = base64url(32 random bytes)
          challenge = base64url( SHA256( ASCII bytes of the verifier STRING ) )
          state     = base64url(16 random bytes)
        Note: the challenge hashes the verifier STRING, not the raw random bytes.
    #>
    $verifier = ConvertTo-PlaudBase64Url -Bytes (New-PlaudRandomBytes -Count 32)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $hash = $sha.ComputeHash([System.Text.Encoding]::ASCII.GetBytes($verifier))
    } finally {
        $sha.Dispose()
    }
    $challenge = ConvertTo-PlaudBase64Url -Bytes $hash
    $state     = ConvertTo-PlaudBase64Url -Bytes (New-PlaudRandomBytes -Count 16)
    return [pscustomobject]@{ Verifier = $verifier; Challenge = $challenge; State = $state }
}

function ConvertTo-PlaudFormBody {
    <# URL-encodes a hashtable into an application/x-www-form-urlencoded body string. #>
    param([Parameter(Mandatory = $true)][hashtable]$Fields)
    $pairs = foreach ($k in $Fields.Keys) {
        '{0}={1}' -f [Uri]::EscapeDataString([string]$k), [Uri]::EscapeDataString([string]$Fields[$k])
    }
    return ($pairs -join '&')
}

function Get-PlaudUnixMs {
    <# Current UTC time as Unix epoch milliseconds (matches the CLI's expires_at units). #>
    $epoch = [datetime]'1970-01-01T00:00:00Z'
    return [long](((Get-Date).ToUniversalTime() - $epoch.ToUniversalTime()).TotalMilliseconds)
}

# ---------------------------------------------------------------------------
# Region: DPAPI-protected token store
# ---------------------------------------------------------------------------

function Protect-PlaudString {
    <# Encrypts a string with DPAPI (CurrentUser) and returns base64 ciphertext. #>
    param([Parameter(Mandatory = $true)][string]$PlainText)
    $bytes  = [System.Text.Encoding]::UTF8.GetBytes($PlainText)
    $cipher = [System.Security.Cryptography.ProtectedData]::Protect(
        $bytes, $null, [System.Security.Cryptography.DataProtectionScope]::CurrentUser)
    return [Convert]::ToBase64String($cipher)
}

function Unprotect-PlaudString {
    <# Reverses Protect-PlaudString. Throws if the blob was written by another user/machine. #>
    param([Parameter(Mandatory = $true)][string]$CipherBase64)
    $cipher = [Convert]::FromBase64String($CipherBase64)
    $bytes  = [System.Security.Cryptography.ProtectedData]::Unprotect(
        $cipher, $null, [System.Security.Cryptography.DataProtectionScope]::CurrentUser)
    return [System.Text.Encoding]::UTF8.GetString($bytes)
}

function Save-PlaudTokenSet {
    <#
        Persists a token set (PSCustomObject) to %APPDATA%\PlaudExporter\session.dat,
        DPAPI-encrypted. Creates the app directory if needed.
    #>
    param([Parameter(Mandatory = $true)][psobject]$TokenSet)
    if (-not (Test-Path -LiteralPath $script:AppDir)) {
        New-Item -ItemType Directory -Path $script:AppDir -Force | Out-Null
    }
    $json   = $TokenSet | ConvertTo-Json -Depth 6 -Compress
    $cipher = Protect-PlaudString -PlainText $json
    Set-Content -LiteralPath $script:SessionFile -Value $cipher -Encoding ASCII
    Write-PlaudLog -Level INFO -Message 'Session saved (DPAPI-encrypted).'
}

function Read-PlaudTokenSet {
    <#
        Loads and decrypts the stored token set, or $null if missing / unreadable.
        A decrypt failure (e.g. roamed profile) is treated as "no session" so the
        app can fall back to a fresh login.
    #>
    if (-not (Test-Path -LiteralPath $script:SessionFile)) { return $null }
    try {
        $cipher = Get-Content -LiteralPath $script:SessionFile -Raw -Encoding ASCII
        if ([string]::IsNullOrWhiteSpace($cipher)) { return $null }
        $json = Unprotect-PlaudString -CipherBase64 $cipher.Trim()
        return ($json | ConvertFrom-Json)
    } catch {
        Write-PlaudLog -Level WARN -Message ('Stored session could not be read: {0}' -f $_.Exception.Message)
        return $null
    }
}

function ConvertTo-PlaudTokenSet {
    <#
        Normalizes a raw token endpoint response into the app's canonical token set.
        Computes expires_at (Unix ms) from expires_in when present.
    #>
    param(
        [Parameter(Mandatory = $true)][psobject]$Response,
        [string]$FallbackRefreshToken
    )
    $expiresAt = $null
    if ($Response.PSObject.Properties.Name -contains 'expires_in' -and $Response.expires_in) {
        $expiresAt = (Get-PlaudUnixMs) + ([long]$Response.expires_in * 1000)
    }
    $refresh = if ($Response.refresh_token) { $Response.refresh_token } else { $FallbackRefreshToken }
    return [pscustomobject]@{
        access_token  = $Response.access_token
        refresh_token = $refresh
        token_type    = if ($Response.token_type) { $Response.token_type } else { 'Bearer' }
        expires_at    = $expiresAt
        obtained_at   = (Get-PlaudUnixMs)
    }
}

# ---------------------------------------------------------------------------
# Region: Authenticated API helper (Bearer + UTF-8-safe JSON)
# ---------------------------------------------------------------------------

function Invoke-PlaudApi {
    <#
        Calls an API path under $ApiBase with a Bearer token. Decodes the response
        body as UTF-8 by hand because Windows PowerShell 5.1's Invoke-RestMethod can
        mis-decode UTF-8 JSON (e.g. accented nicknames), which we carry over from the
        export script. Returns the parsed object. Throws on HTTP error so callers can
        distinguish 401 (auth) from other failures.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [string]$AccessToken,
        [ValidateSet('GET', 'POST')][string]$Method = 'GET'
    )
    if (-not $AccessToken) { throw 'Invoke-PlaudApi requires an access token.' }
    $uri     = $script:ApiBase + $Path
    $headers = @{ Authorization = ('Bearer {0}' -f $AccessToken); Accept = 'application/json' }
    if ($env:PLAUD_ENV)    { $headers['x-pld-env']    = $env:PLAUD_ENV }
    if ($env:PLAUD_REGION) { $headers['x-pld-region'] = $env:PLAUD_REGION }

    $resp  = Invoke-WebRequest -Method $Method -Uri $uri -Headers $headers -UseBasicParsing -ErrorAction Stop
    $bytes = $resp.RawContentStream.ToArray()
    if ($bytes.Length -eq 0) { return $null }
    $json  = [System.Text.Encoding]::UTF8.GetString($bytes)
    return ($json | ConvertFrom-Json)
}

# ---------------------------------------------------------------------------
# Region: Localhost OAuth callback (raw TcpListener -> no admin / no URL ACL)
# ---------------------------------------------------------------------------

function Wait-PlaudOAuthCallback {
    <#
        Listens on 127.0.0.1:<CallbackPort> for the browser redirect to
        /auth/callback?code=...&state=..., validates the state, and returns the code.

        A raw TcpListener is used (not System.Net.HttpListener) so binding the fixed
        port needs no administrative URL ACL reservation - important because the
        compiled EXE runs without elevation.

        Returns: [pscustomobject]@{ Code; Error } - exactly one is non-null.
        Error values: 'port-in-use', 'timeout', 'state-mismatch', '<provider error>'.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$ExpectedState,
        [int]$TimeoutMs = $script:LoginTimeoutMs
    )

    $listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, $script:CallbackPort)
    try {
        try {
            $listener.Start()
        } catch [System.Net.Sockets.SocketException] {
            if ($_.Exception.SocketErrorCode -eq [System.Net.Sockets.SocketError]::AddressAlreadyInUse) {
                Write-PlaudLog -Level ERROR -Message ('Callback port {0} is in use.' -f $script:CallbackPort)
                return [pscustomobject]@{ Code = $null; Error = 'port-in-use' }
            }
            throw
        }

        Write-PlaudLog -Level INFO -Message ('Listening for OAuth callback on 127.0.0.1:{0}.' -f $script:CallbackPort)
        $sw = [System.Diagnostics.Stopwatch]::StartNew()

        while ($sw.ElapsedMilliseconds -lt $TimeoutMs) {
            if (-not $listener.Pending()) { Start-Sleep -Milliseconds 150; continue }

            $client = $listener.AcceptTcpClient()
            try {
                $client.ReceiveTimeout = 5000
                $stream = $client.GetStream()
                $stream.ReadTimeout = 5000
                $reader = New-Object System.IO.StreamReader($stream)

                # The request line carries everything we need: "GET /path?query HTTP/1.1".
                $requestLine = $null
                try { $requestLine = $reader.ReadLine() } catch { }
                if ([string]::IsNullOrWhiteSpace($requestLine)) {
                    Send-PlaudHttpResponse -Stream $stream -StatusLine 'HTTP/1.1 400 Bad Request' -BodyHtml '<h1>Bad request</h1>'
                    continue
                }

                $parts  = $requestLine -split '\s+'
                $target = if ($parts.Count -ge 2) { $parts[1] } else { '/' }
                $path   = ($target -split '\?', 2)[0]

                # Ignore stray requests (favicon, etc.) but keep listening.
                if ($path -ne $script:CallbackPath) {
                    Send-PlaudHttpResponse -Stream $stream -StatusLine 'HTTP/1.1 404 Not Found' -BodyHtml '<h1>Not found</h1>'
                    continue
                }

                $query = ConvertFrom-PlaudQueryString -Target $target

                if ($query.ContainsKey('error')) {
                    $provErr = $query['error']
                    Write-PlaudLog -Level ERROR -Message ('OAuth provider returned error: {0}' -f $provErr)
                    Send-PlaudHttpResponse -Stream $stream -StatusLine 'HTTP/1.1 200 OK' `
                        -BodyHtml '<h1>Login failed</h1><p>You can close this tab and return to Plaud Exporter.</p>'
                    return [pscustomobject]@{ Code = $null; Error = $provErr }
                }

                if (-not $query.ContainsKey('code')) {
                    Send-PlaudHttpResponse -Stream $stream -StatusLine 'HTTP/1.1 400 Bad Request' -BodyHtml '<h1>Missing code</h1>'
                    continue
                }

                # CSRF protection: the returned state must match what we sent.
                $returnedState = if ($query.ContainsKey('state')) { $query['state'] } else { '' }
                if ($returnedState -ne $ExpectedState) {
                    Write-PlaudLog -Level ERROR -Message 'OAuth state mismatch (possible CSRF); rejecting callback.'
                    Send-PlaudHttpResponse -Stream $stream -StatusLine 'HTTP/1.1 400 Bad Request' `
                        -BodyHtml '<h1>State mismatch</h1><p>Login was rejected for security reasons. Please try again.</p>'
                    return [pscustomobject]@{ Code = $null; Error = 'state-mismatch' }
                }

                Send-PlaudHttpResponse -Stream $stream -StatusLine 'HTTP/1.1 200 OK' `
                    -BodyHtml '<h1>Login complete</h1><p>You can close this tab and return to Plaud Exporter.</p>'
                Write-PlaudLog -Level INFO -Message 'OAuth callback received and state validated.'
                return [pscustomobject]@{ Code = $query['code']; Error = $null }
            } finally {
                $client.Close()
            }
        }

        Write-PlaudLog -Level WARN -Message 'OAuth login timed out waiting for the callback.'
        return [pscustomobject]@{ Code = $null; Error = 'timeout' }
    } finally {
        try { $listener.Stop() } catch { }
    }
}

function Send-PlaudHttpResponse {
    <# Writes a minimal HTTP/1.1 response (headers + HTML body) to the socket stream. #>
    param(
        [Parameter(Mandatory = $true)][System.IO.Stream]$Stream,
        [Parameter(Mandatory = $true)][string]$StatusLine,
        [Parameter(Mandatory = $true)][string]$BodyHtml
    )
    $page = ('<!doctype html><html><head><meta charset="utf-8"><title>Plaud Exporter</title>' +
             '<style>body{font-family:Segoe UI,Arial,sans-serif;margin:3rem;color:#222}</style></head>' +
             '<body>' + $BodyHtml + '</body></html>')
    $bodyBytes = [System.Text.Encoding]::UTF8.GetBytes($page)
    $header = ($StatusLine + "`r`n" +
               "Content-Type: text/html; charset=utf-8`r`n" +
               ('Content-Length: {0}' -f $bodyBytes.Length) + "`r`n" +
               "Connection: close`r`n`r`n")
    $headerBytes = [System.Text.Encoding]::ASCII.GetBytes($header)
    try {
        $Stream.Write($headerBytes, 0, $headerBytes.Length)
        $Stream.Write($bodyBytes, 0, $bodyBytes.Length)
        $Stream.Flush()
    } catch { }
}

function ConvertFrom-PlaudQueryString {
    <#
        Parses the query string out of an HTTP request target into a hashtable,
        URL-decoding keys and values. Avoids a System.Web dependency.
    #>
    param([Parameter(Mandatory = $true)][string]$Target)
    $result = @{}
    $qIndex = $Target.IndexOf('?')
    if ($qIndex -lt 0) { return $result }
    $query = $Target.Substring($qIndex + 1)
    foreach ($pair in ($query -split '&')) {
        if ([string]::IsNullOrEmpty($pair)) { continue }
        $kv  = $pair -split '=', 2
        $key = [Uri]::UnescapeDataString($kv[0])
        $val = if ($kv.Count -gt 1) { [Uri]::UnescapeDataString($kv[1]) } else { '' }
        $result[$key] = $val
    }
    return $result
}

# ---------------------------------------------------------------------------
# Region: Token endpoint calls (exchange + refresh)
# ---------------------------------------------------------------------------

function Invoke-PlaudTokenExchange {
    <#
        Exchanges an authorization code for tokens at the token endpoint.
        Uses HTTP Basic auth base64(clientId:clientSecret) like the CLI (secret is
        empty for this public client). Body is form-urlencoded.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Code,
        [Parameter(Mandatory = $true)][string]$CodeVerifier,
        [Parameter(Mandatory = $true)][string]$State
    )
    $basic   = [Convert]::ToBase64String(
                 [System.Text.Encoding]::ASCII.GetBytes(('{0}:{1}' -f $script:ClientId, $script:ClientSecret)))
    $headers = @{ Authorization = ('Basic {0}' -f $basic); Accept = 'application/json' }
    $body    = ConvertTo-PlaudFormBody -Fields @{
        code          = $Code
        redirect_uri  = $script:RedirectUri
        code_verifier = $CodeVerifier
        state         = $State
    }
    $resp = Invoke-RestMethod -Method Post -Uri $script:TokenUrl -Headers $headers `
              -ContentType 'application/x-www-form-urlencoded' -Body $body -ErrorAction Stop
    return ConvertTo-PlaudTokenSet -Response $resp
}

function Invoke-PlaudTokenRefresh {
    <#
        Refreshes the access token using the refresh token. No Basic auth on this
        endpoint (mirrors the CLI). Returns a normalized token set. The old refresh
        token is reused if the server does not issue a new one.
    #>
    param([Parameter(Mandatory = $true)][string]$RefreshToken)
    $headers = @{ Accept = 'application/json' }
    $body    = ConvertTo-PlaudFormBody -Fields @{ refresh_token = $RefreshToken }
    $resp = Invoke-RestMethod -Method Post -Uri $script:RefreshUrl -Headers $headers `
              -ContentType 'application/x-www-form-urlencoded' -Body $body -ErrorAction Stop
    return ConvertTo-PlaudTokenSet -Response $resp -FallbackRefreshToken $RefreshToken
}

# ---------------------------------------------------------------------------
# Region: Public API
# ---------------------------------------------------------------------------

function Get-PlaudAuthContext {
    <# Returns paths/constants the rest of the app needs (no secrets). #>
    [CmdletBinding()]
    param()
    return [pscustomobject]@{
        ClientId      = $script:ClientId
        RedirectUri   = $script:RedirectUri
        CallbackPort  = $script:CallbackPort
        ApiBase       = $script:ApiBase
        AppDir        = $script:AppDir
        SessionFile   = $script:SessionFile
        CliTokenFile  = $script:CliTokenFile
        LogDir        = $script:LogDir
    }
}

function Get-PlaudCurrentUser {
    <#
        Validates a token by calling /users/current. Returns the user object on
        success, or $null on 401 (invalid/expired). Other errors are re-thrown so
        callers can distinguish network problems from auth problems.
    #>
    [CmdletBinding()]
    param([string]$AccessToken)
    if (-not $AccessToken) {
        $AccessToken = Get-PlaudAccessToken
        if (-not $AccessToken) { return $null }
    }
    try {
        return Invoke-PlaudApi -Path $script:UserCurrentPath -AccessToken $AccessToken -Method GET
    } catch {
        $status = $null
        if ($_.Exception.Response) { $status = [int]$_.Exception.Response.StatusCode }
        if ($status -eq 401 -or $status -eq 403) {
            Write-PlaudLog -Level WARN -Message ('Token validation failed (HTTP {0}).' -f $status)
            return $null
        }
        throw
    }
}

function Get-PlaudAccessToken {
    <#
        Returns a currently-valid access token, refreshing silently when within the
        skew window of expiry. Returns $null when there is no usable session (caller
        should then prompt Connect-PlaudAccount).
    #>
    [CmdletBinding()]
    param()
    $set = Read-PlaudTokenSet
    if (-not $set -or -not $set.access_token) { return $null }

    $needsRefresh = $false
    if ($set.expires_at) {
        if ((Get-PlaudUnixMs) -gt ([long]$set.expires_at - $script:RefreshSkewMs)) { $needsRefresh = $true }
    }

    if ($needsRefresh) {
        if (-not $set.refresh_token) {
            Write-PlaudLog -Level WARN -Message 'Access token expired and no refresh token is available.'
            return $null
        }
        try {
            Write-PlaudLog -Level INFO -Message 'Access token near expiry; refreshing.'
            $refreshed = Invoke-PlaudTokenRefresh -RefreshToken $set.refresh_token
            Save-PlaudTokenSet -TokenSet $refreshed
            return $refreshed.access_token
        } catch {
            Write-PlaudLog -Level ERROR -Message ('Token refresh failed: {0}' -f $_.Exception.Message)
            return $null
        }
    }
    return $set.access_token
}

function Test-PlaudSession {
    <# $true if a stored session exists and validates against /users/current. #>
    [CmdletBinding()]
    param()
    $token = Get-PlaudAccessToken
    if (-not $token) { return $false }
    return [bool](Get-PlaudCurrentUser -AccessToken $token)
}

function Connect-PlaudAccount {
    <#
        Interactive browser login via OAuth 2.0 Authorization Code + PKCE.

        Flow:
          1. If a valid session already exists and -Force is not set, return that user.
          2. Generate PKCE (verifier/challenge/state) and build the authorization URL.
          3. Start the localhost callback listener, then open the system browser.
          4. On callback: validate state, exchange code -> tokens, save (DPAPI).
          5. Validate via /users/current and return the user object.

        Returns the user object on success; throws on failure with a clear message.
    #>
    [CmdletBinding()]
    param(
        [switch]$Force,
        [int]$TimeoutSeconds = ([int]($script:LoginTimeoutMs / 1000))
    )

    if (-not $Force) {
        $existing = Get-PlaudCurrentUser
        if ($existing) {
            Write-PlaudLog -Level INFO -Message 'Already logged in; reusing existing session.'
            return $existing
        }
    }

    $pkce  = New-PlaudPkcePair
    $params = ConvertTo-PlaudFormBody -Fields @{
        client_id             = $script:ClientId
        redirect_uri          = $script:RedirectUri
        response_type         = 'code'
        code_challenge        = $pkce.Challenge
        code_challenge_method = 'S256'
        state                 = $pkce.State
    }
    $authUrl = '{0}?{1}' -f $script:AuthorizationUrl, $params

    Write-PlaudLog -Level INFO -Message 'Starting OAuth login.'
    Write-Host 'Opening your browser to sign in to Plaud...' -ForegroundColor Cyan
    Write-Host ('If it does not open automatically, paste this URL into your browser:') -ForegroundColor DarkGray
    Write-Host $authUrl -ForegroundColor DarkGray

    # Open the default browser. Start-Process is the most reliable launcher under
    # both script and compiled-EXE execution.
    try { Start-Process $authUrl | Out-Null }
    catch { Write-PlaudLog -Level WARN -Message ('Could not auto-open browser: {0}' -f $_.Exception.Message) }

    $callback = Wait-PlaudOAuthCallback -ExpectedState $pkce.State -TimeoutMs ($TimeoutSeconds * 1000)

    if ($callback.Error) {
        switch ($callback.Error) {
            'port-in-use' {
                throw ("OAuth callback port $($script:CallbackPort) is already in use. Another Plaud " +
                       "process (e.g. 'plaud-mcp http' or a 'plaud login') is likely holding it. " +
                       "Free the port and try again.")
            }
            'timeout'        { throw 'Login timed out. Please try again and complete the sign-in promptly.' }
            'state-mismatch' { throw 'Login was rejected for security reasons (state mismatch). Please try again.' }
            default          { throw ("Login failed: {0}" -f $callback.Error) }
        }
    }

    Write-PlaudLog -Level INFO -Message 'Exchanging authorization code for tokens.'
    $tokenSet = Invoke-PlaudTokenExchange -Code $callback.Code -CodeVerifier $pkce.Verifier -State $pkce.State
    if (-not $tokenSet.access_token) { throw 'Token exchange returned no access token.' }
    Save-PlaudTokenSet -TokenSet $tokenSet

    $user = Get-PlaudCurrentUser -AccessToken $tokenSet.access_token
    if (-not $user) { throw 'Logged in but token validation failed unexpectedly.' }

    Write-PlaudLog -Level INFO -Message 'Login successful.'
    Write-Host 'Login successful.' -ForegroundColor Green
    return $user
}

function Import-PlaudCliSession {
    <#
        FALLBACK login path: import tokens previously written by `plaud login` from
        %USERPROFILE%\.plaud\tokens.json, store them in our DPAPI session, and
        validate. Returns the user object on success, or $null if the file is
        missing/invalid. Use when interactive browser login is unavailable.

        -Force re-imports even if a valid app session already exists.
    #>
    [CmdletBinding()]
    param([switch]$Force)

    if (-not $Force) {
        $existing = Get-PlaudCurrentUser
        if ($existing) {
            Write-PlaudLog -Level INFO -Message 'App session already valid; skipping CLI import.'
            return $existing
        }
    }

    if (-not (Test-Path -LiteralPath $script:CliTokenFile)) {
        Write-PlaudLog -Level WARN -Message ('No CLI token file at {0}.' -f $script:CliTokenFile)
        return $null
    }

    try {
        $raw = Get-Content -LiteralPath $script:CliTokenFile -Raw -Encoding UTF8 | ConvertFrom-Json
    } catch {
        Write-PlaudLog -Level ERROR -Message ('CLI token file is unreadable: {0}' -f $_.Exception.Message)
        return $null
    }
    if (-not $raw.access_token) {
        Write-PlaudLog -Level WARN -Message 'CLI token file contains no access_token.'
        return $null
    }

    # The CLI store already uses expires_at in Unix ms, so carry it across directly.
    $set = [pscustomobject]@{
        access_token  = $raw.access_token
        refresh_token = $raw.refresh_token
        token_type    = if ($raw.token_type) { $raw.token_type } else { 'Bearer' }
        expires_at    = if ($raw.expires_at) { [long]$raw.expires_at } else { $null }
        obtained_at   = (Get-PlaudUnixMs)
    }
    Save-PlaudTokenSet -TokenSet $set

    # Validate, letting Get-PlaudAccessToken refresh first if the imported token is stale.
    $token = Get-PlaudAccessToken
    if (-not $token) {
        Write-PlaudLog -Level WARN -Message 'Imported CLI token could not be validated/refreshed.'
        return $null
    }
    $user = Get-PlaudCurrentUser -AccessToken $token
    if ($user) {
        Write-PlaudLog -Level INFO -Message 'Imported and validated CLI session.'
    }
    return $user
}

function Disconnect-PlaudAccount {
    <#
        Logs out: best-effort server-side revoke of the current token, then deletes
        the local DPAPI session file. Always clears the local session even if the
        revoke call fails (e.g. offline), so the app reflects a logged-out state.
    #>
    [CmdletBinding()]
    param()
    $token = Get-PlaudAccessToken
    if ($token) {
        try {
            Invoke-PlaudApi -Path $script:RevokePath -AccessToken $token -Method POST | Out-Null
            Write-PlaudLog -Level INFO -Message 'Server-side token revoked.'
        } catch {
            Write-PlaudLog -Level WARN -Message ('Revoke call failed (continuing to clear local session): {0}' -f $_.Exception.Message)
        }
    }
    if (Test-Path -LiteralPath $script:SessionFile) {
        try {
            Remove-Item -LiteralPath $script:SessionFile -Force -ErrorAction Stop
            Write-PlaudLog -Level INFO -Message 'Local session cleared.'
        } catch {
            Write-PlaudLog -Level ERROR -Message ('Could not delete session file: {0}' -f $_.Exception.Message)
            throw
        }
    }
    Write-Host 'Logged out.' -ForegroundColor Yellow
}

# ---------------------------------------------------------------------------
# Region: Exports
# ---------------------------------------------------------------------------
Export-ModuleMember -Function @(
    'Connect-PlaudAccount',
    'Disconnect-PlaudAccount',
    'Get-PlaudAccessToken',
    'Get-PlaudCurrentUser',
    'Test-PlaudSession',
    'Import-PlaudCliSession',
    'Get-PlaudAuthContext',
    'Write-PlaudLog'
)
