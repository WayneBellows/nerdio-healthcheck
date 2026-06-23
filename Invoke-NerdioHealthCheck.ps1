<#
.SYNOPSIS
  Nerdio (NME) Health Check — read-only assessment of a customer's NME environment.
.DESCRIPTION
  Phase 0: prove connectivity. Acquires a token, calls /test and /deployment/current,
  prints version + edition posture. Later phases add collectors, rules and HTML report.
.PARAMETER ConfigPath
  Path to credentials JSON. Defaults to config/credentials.local.json.
.EXAMPLE
  pwsh ./Invoke-NerdioHealthCheck.ps1
#>
[CmdletBinding()]
param(
    [string]$ConfigPath = (Join-Path $PSScriptRoot 'config\credentials.local.json'),
    [switch]$Collect,        # Phase 1: full read-only environment collection -> output/raw
    [switch]$Assess,         # Phase 2: run rules engine over collected data, print findings
    [switch]$Report,         # Phase 3: render HTML report from findings
    [string]$CustomerName = 'Customer',
    [string]$FromFile        # Assess an existing output/raw JSON instead of a live collection
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'src\Connect-Nme.ps1')
. (Join-Path $PSScriptRoot 'src\Collect-NmeEnvironment.ps1')
. (Join-Path $PSScriptRoot 'src\Test-NmeRules.ps1')
. (Join-Path $PSScriptRoot 'src\Write-NmeReport.ps1')

$env = $null

if ($FromFile) {
    # Assess an already-collected environment — no credentials needed.
    Write-Host "Loading environment from $FromFile" -ForegroundColor Cyan
    if (-not (Test-Path $FromFile)) { throw "File not found: $FromFile" }
    $env = Get-Content -LiteralPath $FromFile -Raw | ConvertFrom-Json
} else {
    Write-Host 'Nerdio Health Check — Phase 0 connectivity test' -ForegroundColor Cyan
    Write-Host ('-' * 50)

    $cfg = Get-NmeConfig -ConfigPath $ConfigPath
    Write-Host "Base URL : $($cfg.baseUrl)"
    Write-Host 'Acquiring token...'
    $session = Connect-Nme -Config $cfg
    Write-Host "Token acquired. Expires ~$($session.TokenExpiry.ToString('HH:mm:ss'))" -ForegroundColor Green

    Write-Host "`nGET /api/v1/test"
    $test = Invoke-NmeApi -Session $session -Path '/api/v1/test'
    if ($null -ne $test) { Write-Host '  API reachable.' -ForegroundColor Green }
    else { Write-Warning '  /test returned nothing — check base URL / permissions.' }

    Write-Host "`nGET /api/v1/deployment/current"
    $dep = Invoke-NmeApi -Session $session -Path '/api/v1/deployment/current'
    if ($dep) {
        Write-Host "  NME version    : $($dep.deployedVersion)"
        Write-Host "  Edition        : $($dep.productEdition)"
        Write-Host "  Released       : $($dep.released)"
        Write-Host "  AVD agent ver  : $($dep.avdAgentVersion)"
        Write-Host "  FSLogix ver    : $($dep.fsLogixVersion)"
    } else {
        Write-Warning '  Could not read deployment info.'
    }
    Write-Host "`nPhase 0 complete." -ForegroundColor Cyan

    if ($Collect -or $Assess -or $Report) {
        Write-Host "`n=== Phase 1: collection ===" -ForegroundColor Cyan
        $env = Get-NmeEnvironment -Session $session
        Save-NmeEnvironment -Environment $env | Out-Null
        Write-Host ("Summary: {0} workspace(s), {1} host pool(s), {2} image(s), {3} scripted action(s)." -f `
            $env.workspaces.Count, $env.hostPools.Count, $env.desktopImages.Count, $env.scriptedActions.Count)
    }
}

if (($Assess -or $Report -or $FromFile) -and $env) {
    Write-Host "`n=== Phase 2: assessment ===" -ForegroundColor Cyan
    $findings = Get-NmeFindings -Environment $env
    $summary  = Get-NmeFindingSummary -Findings $findings
    $health   = Get-NmeHealthScore -Findings $findings -Environment $env

    Write-Host "`nOverall health score: $($health.score)/100 ($($health.label))" -ForegroundColor Cyan
    Write-Host "`nFindings by severity:" -ForegroundColor Cyan
    $summary.PSObject.Properties | ForEach-Object { Write-Host ("  {0,-12} {1}" -f $_.Name, $_.Value) }

    foreach ($sev in 'Required', 'Recommended', 'Optional', 'Manual') {
        $items = $findings | Where-Object severity -eq $sev
        if (-not $items) { continue }
        Write-Host "`n[$sev]" -ForegroundColor Yellow
        foreach ($it in $items) {
            Write-Host ("  - ({0}) {1}" -f $it.scope, $it.title)
            Write-Host ("      {0}" -f $it.observation) -ForegroundColor DarkGray
        }
    }

    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $outDir = Join-Path $PSScriptRoot 'output'
    $findingsFile = Join-Path $outDir "findings-$stamp.json"
    $findings | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $findingsFile -Encoding UTF8
    Write-Host "`nFindings saved: $findingsFile" -ForegroundColor Green

    if ($Report -or $FromFile) {
        Write-Host "`n=== Phase 3: report ===" -ForegroundColor Cyan
        Write-NmeReport -Environment $env -Findings $findings -CustomerName $CustomerName | Out-Null
    }
}
