<#
.SYNOPSIS
  NME REST API connection helpers — OAuth2 client-credentials token + GET wrapper.
.DESCRIPTION
  Read-only. Acquires an Azure AD bearer token for the NME API and exposes
  Invoke-NmeApi for GET calls. Credentials come from a local JSON file
  (option 4: config/credentials.local.json, gitignored) or explicit params.
#>

function Get-NmeConfig {
    [CmdletBinding()]
    param(
        [string]$ConfigPath = (Join-Path $PSScriptRoot '..\config\credentials.local.json')
    )
    if (-not (Test-Path $ConfigPath)) {
        throw "Credentials file not found: $ConfigPath. Copy credentials.example.json to credentials.local.json and fill it in."
    }
    $cfg = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
    foreach ($k in 'tokenUrl','clientId','scope','clientSecret','baseUrl') {
        if ([string]::IsNullOrWhiteSpace($cfg.$k) -or $cfg.$k -like 'PASTE_*' -or $cfg.$k -like '<*>') {
            throw "Credential field '$k' is not set in $ConfigPath."
        }
    }
    $cfg | Add-Member -NotePropertyName baseUrl -NotePropertyValue ($cfg.baseUrl.TrimEnd('/')) -Force
    return $cfg
}

function Connect-Nme {
    [CmdletBinding()]
    param(
        [psobject]$Config = (Get-NmeConfig)
    )
    $body = @{
        grant_type    = 'client_credentials'
        client_id     = $Config.clientId
        client_secret = $Config.clientSecret
        scope         = $Config.scope
    }
    try {
        $resp = Invoke-RestMethod -Method Post -Uri $Config.tokenUrl `
            -ContentType 'application/x-www-form-urlencoded' -Body $body -ErrorAction Stop
    }
    catch {
        throw "Token request failed: $($_.Exception.Message)"
    }
    if (-not $resp.access_token) { throw 'Token response contained no access_token.' }

    # Session object carried through the run. Secret is not retained here.
    [pscustomobject]@{
        BaseUrl     = $Config.baseUrl
        Token       = $resp.access_token
        TokenExpiry = (Get-Date).AddSeconds([int]($resp.expires_in | ForEach-Object { $_ -as [int] }) - 60)
    }
}

function Invoke-NmeApi {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][psobject]$Session,
        [Parameter(Mandatory)][string]$Path,        # e.g. /api/v1/deployment/current
        [hashtable]$Query
    )
    $uri = $Session.BaseUrl + ($Path.StartsWith('/') ? $Path : "/$Path")
    if ($Query -and $Query.Count) {
        $pairs = $Query.GetEnumerator() | ForEach-Object {
            "{0}={1}" -f [uri]::EscapeDataString($_.Key), [uri]::EscapeDataString([string]$_.Value)
        }
        $uri += '?' + ($pairs -join '&')
    }
    $headers = @{ Authorization = "Bearer $($Session.Token)" }
    try {
        return Invoke-RestMethod -Method Get -Uri $uri -Headers $headers -ErrorAction Stop
    }
    catch {
        $status = $null
        try { $status = [int]$_.Exception.Response.StatusCode } catch {}
        Write-Warning "GET $Path failed$(if($status){" (HTTP $status)"}): $($_.Exception.Message)"
        return $null
    }
}
