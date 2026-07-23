<#
.SYNOPSIS
  Phase 1 collectors — read-only gather of an NME environment into one object.
.DESCRIPTION
  Depends on Connect-Nme.ps1 (dot-source it first). Every call is a GET.
  Host pools have no list endpoint in the REST API, so they are derived from
  session-host records across all workspaces (see Get-NmeHostPoolInventory).
  Limitation: host pools with zero session hosts are not discoverable via REST.
#>

function Get-NmeHostPoolInventory {
    [CmdletBinding()]
    param([Parameter(Mandatory)][psobject]$Session, [array]$Workspaces)

    $pools = @{}   # key "sub/rg/name" -> ref object
    foreach ($ws in $Workspaces) {
        $id = $ws.id
        [array]$hosts = Invoke-NmeApi -Session $Session -Path "/api/v1/arm/workspace/$($id.subscriptionId)/$($id.resourceGroup)/$($id.name)/host"
        foreach ($h in $hosts) {
            $hp = $h.hostpool
            if (-not $hp -or -not $hp.hostpoolName) { continue }
            $key = "$($hp.subscription)/$($hp.resourceGroup)/$($hp.hostpoolName)"
            if (-not $pools.ContainsKey($key)) {
                $pools[$key] = [pscustomobject]@{
                    subscriptionId = $hp.subscription
                    resourceGroup  = $hp.resourceGroup
                    name           = $hp.hostpoolName
                    hostCount      = 0
                    location       = $ws.location
                }
            }
            $pools[$key].hostCount++
        }
    }
    return $pools.Values | Sort-Object name
}

function Get-NmeHostPoolDetail {
    [CmdletBinding()]
    param([Parameter(Mandatory)][psobject]$Session, [Parameter(Mandatory)][psobject]$Pool)

    $base = "/api/v1/arm/hostpool/$($Pool.subscriptionId)/$($Pool.resourceGroup)/$($Pool.name)"
    [pscustomobject]@{
        ref            = $Pool
        config         = Invoke-NmeApi -Session $Session -Path $base
        wvd            = Invoke-NmeApi -Session $Session -Path "$base/wvd"
        autoScale      = Invoke-NmeApi -Session $Session -Path "$base/auto-scale"
        fslogix        = Invoke-NmeApi -Session $Session -Path "$base/fslogix"
        rdp            = Invoke-NmeApi -Session $Session -Path "$base/rdp"
        sessionTimeout = Invoke-NmeApi -Session $Session -Path "$base/session-timeout"
        vmDeployment   = Invoke-NmeApi -Session $Session -Path "$base/vm-deployment"
        schedule       = Invoke-NmeApi -Session $Session -Path "$base/schedule"
        activeDirectory= Invoke-NmeApi -Session $Session -Path "$base/active-directory"
        hosts          = Invoke-NmeApi -Session $Session -Path "$base/host"
    }
}

function Get-NmeStorageLocations {
    <#
      Derive FSLogix storage locations from host-pool FSLogix config (the API has no
      storage list endpoint). For Azure Files shares, best-effort resolve the auto-scale
      state by probing the auto-scale endpoint across the known subscriptions/resource
      groups (the FSLogix path gives account+share but not subscription/RG).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][psobject]$Session, [array]$HostPools, [array]$ResourceGroups)

    # Build subscription -> resource groups map for probing.
    $subRgs = @{}
    foreach ($rg in $ResourceGroups) {
        if (-not $subRgs.ContainsKey($rg.subscriptionId)) { $subRgs[$rg.subscriptionId] = [System.Collections.Generic.List[string]]::new() }
        $subRgs[$rg.subscriptionId].Add($rg.name)
    }

    $locations = @{}   # key "account/share" -> object
    foreach ($hp in $HostPools) {
        $cfg = $hp.fslogix.effectiveConfig
        if (-not $cfg) { continue }
        foreach ($path in @($cfg.profilesPath, $cfg.officeContainerPath, $cfg.secondaryProfilesPath, $cfg.secondaryOfficeContainerPath)) {
            if ([string]::IsNullOrWhiteSpace("$path")) { continue }
            $p = "$path"
            $type = 'Other'; $account = ''; $share = ''
            if ($p -match '^\\\\([^.\\]+)\.file\.core\.windows\.net\\(.+)$') {
                $type = 'AzureFiles'; $account = $Matches[1]; $share = ($Matches[2] -replace '\\.*$', '')
            } elseif ($p -match '^\\\\([^\\]+)\\(.+)$') {
                $type = 'Other'; $account = $Matches[1]; $share = $Matches[2]
            }
            $key = "$account/$share"
            if ($locations.ContainsKey($key)) {
                if ($locations[$key].hostPools -notcontains $hp.ref.name) { $locations[$key].hostPools += $hp.ref.name }
                continue
            }
            $locations[$key] = [pscustomobject]@{
                type = $type; account = $account; share = $share; path = $p
                hostPools = @($hp.ref.name)
                resolved = $false; isEnabled = $null; subscriptionId = $null; resourceGroup = $null
            }
        }
    }

    # Best-effort resolve Azure Files auto-scale state (bounded probe; 404s are expected).
    foreach ($loc in $locations.Values) {
        if ($loc.type -ne 'AzureFiles') { continue }
        :found foreach ($sub in $subRgs.Keys) {
            foreach ($rg in $subRgs[$sub]) {
                $r = Invoke-NmeApi -Session $Session -Quiet `
                    -Path "/api/v1/storage/azure-files/$sub/$rg/$($loc.account)/$($loc.share)/auto-scale"
                if ($null -ne $r) {
                    $loc.resolved = $true; $loc.isEnabled = $r.isEnabled
                    $loc.subscriptionId = $sub; $loc.resourceGroup = $rg
                    break found
                }
            }
        }
    }
    return $locations.Values | Sort-Object account, share
}

function Get-NmeEnvironment {
    [CmdletBinding()]
    param([Parameter(Mandatory)][psobject]$Session)

    Write-Host 'Collecting environment...' -ForegroundColor Cyan

    Write-Host '  deployment / workspaces / resource groups'
    $deployment = Invoke-NmeApi -Session $Session -Path '/api/v1/deployment/current'
    [array]$workspaces = Invoke-NmeApi -Session $Session -Path '/api/v1/workspace'
    [array]$resourceGroups = Invoke-NmeApi -Session $Session -Path '/api/v1/resourcegroup'

    Write-Host '  host pool inventory (derived from session hosts)'
    [array]$poolRefs = Get-NmeHostPoolInventory -Session $Session -Workspaces $workspaces
    Write-Host "    found $($poolRefs.Count) host pool(s): $(( $poolRefs.name ) -join ', ')"

    Write-Host '  per-host-pool detail'
    [array]$hostPools = foreach ($p in $poolRefs) {
        Write-Host "    - $($p.name)"
        Get-NmeHostPoolDetail -Session $Session -Pool $p
    }

    Write-Host '  FSLogix storage locations (+ auto-scale resolve)'
    [array]$storageLocations = Get-NmeStorageLocations -Session $Session -HostPools $hostPools -ResourceGroups $resourceGroups
    Write-Host "    found $($storageLocations.Count) storage location(s)"

    Write-Host '  images / apps / scripted actions / profiles'
    [array]$desktopImages   = Invoke-NmeApi -Session $Session -Path '/api/v1/desktop-image'
    [array]$scriptedActions = Invoke-NmeApi -Session $Session -Path '/api/v1/scripted-actions'
    [array]$scriptedGroups  = Invoke-NmeApi -Session $Session -Path '/api/v1/scripted-actions-group'
    [array]$autoScaleProfiles = Invoke-NmeApi -Session $Session -Path '/api/v1/auto-scale-profile'
    [array]$appPolicyRecurrent = Invoke-NmeApi -Session $Session -Path '/api/v1/app-management/policy/recurrent'
    [array]$appPolicyOnetime   = Invoke-NmeApi -Session $Session -Path '/api/v1/app-management/policy/onetime' -Query @{ createdSince = '2000-01-01'; createdUntil = '2100-01-01' }
    [array]$appRepositories    = Invoke-NmeApi -Session $Session -Path '/api/v1/app-management/repository'
    [array]$shellApps          = Invoke-NmeApi -Session $Session -Path '/api/v1/shell-app'
    [array]$appAttachImages    = Invoke-NmeApi -Session $Session -Path '/api/v1/app-attach/image'

    Write-Host '  notifications / RBAC / usage'
    [array]$notifActions    = Invoke-NmeApi -Session $Session -Path '/api/v1/notifications/actions'
    [array]$notifConditions = Invoke-NmeApi -Session $Session -Path '/api/v1/notifications/conditions/nerdio'
    [array]$notifWebhooks   = Invoke-NmeApi -Session $Session -Path '/api/v1/notifications/webhooks'
    [array]$roleAssignments = Invoke-NmeApi -Session $Session -Path '/api/v1/users-and-roles/assignment'
    $workspaceUsage  = Invoke-NmeApi -Session $Session -Path '/api/v1/usages/arm/workspace'

    [pscustomobject]@{
        collectedAt        = (Get-Date).ToString('o')
        baseUrl            = $Session.BaseUrl
        deployment         = $deployment
        workspaces         = $workspaces
        resourceGroups     = $resourceGroups
        hostPools          = @($hostPools)
        storageLocations   = @($storageLocations)
        desktopImages      = $desktopImages
        scriptedActions    = $scriptedActions
        scriptedGroups     = $scriptedGroups
        autoScaleProfiles  = $autoScaleProfiles
        appPolicyRecurrent = $appPolicyRecurrent
        appPolicyOnetime   = $appPolicyOnetime
        appRepositories    = $appRepositories
        shellApps          = $shellApps
        appAttachImages    = $appAttachImages
        notifActions       = $notifActions
        notifConditions    = $notifConditions
        notifWebhooks      = $notifWebhooks
        roleAssignments    = $roleAssignments
        workspaceUsage     = $workspaceUsage
    }
}

function Save-NmeEnvironment {
    [CmdletBinding()]
    param([Parameter(Mandatory)][psobject]$Environment, [string]$OutDir = (Join-Path $PSScriptRoot '..\output\raw'))
    if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Path $OutDir -Force | Out-Null }
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $file = Join-Path $OutDir "environment-$stamp.json"
    $Environment | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $file -Encoding UTF8
    Write-Host "Raw environment saved: $file" -ForegroundColor Green
    return $file
}
