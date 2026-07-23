<#
.SYNOPSIS
  Tier 2 enrichment — optional Azure data via the az CLI.
.DESCRIPTION
  Pulls what the NME REST API cannot provide: Azure Advisor rightsizing
  recommendations, actual managed-disk SKUs, Log Analytics ingestion by
  performance counter, and Azure Files provisioned-vs-used capacity.
  Everything is read-only and best-effort: if az is missing, unauthenticated,
  or any call fails, that slice returns $null/empty and the analysis falls
  back to modelled figures. Never throws.
#>

function Invoke-NmeAz {
    <# Run an az command, parse JSON, swallow failures. $Args is the argument list after 'az'. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string[]]$Arguments)
    try {
        $raw = & az @Arguments --output json --only-show-errors 2>$null
        $failed = ($LASTEXITCODE -ne 0)
        $global:LASTEXITCODE = 0   # don't leak native exit codes to callers
        if ($failed -or -not $raw) { return $null }
        return ($raw -join "`n") | ConvertFrom-Json
    } catch {
        return $null
    }
}

function Test-NmeAzExtension {
    <# Ensure an az extension is present (install is local tooling, not customer-system state). #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name)
    $found = Invoke-NmeAz -Arguments @('extension', 'show', '--name', $Name)
    if ($found) { return $true }
    Write-Host "  installing az extension '$Name'..." -ForegroundColor DarkYellow
    try { & az extension add --name $Name --only-show-errors 2>$null | Out-Null } catch {}
    $global:LASTEXITCODE = 0
    return ($null -ne (Invoke-NmeAz -Arguments @('extension', 'show', '--name', $Name)))
}

function Test-NmeAzCli {
    [CmdletBinding()]
    param()
    $az = Get-Command az -ErrorAction SilentlyContinue
    if (-not $az) { return $false }
    $acct = Invoke-NmeAz -Arguments @('account', 'show')
    return ($null -ne $acct)
}

function Get-NmeAdvisorRightsizing {
    <# Azure Advisor cost recommendations for VMs, matched to session-host vmIds. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SubscriptionId,
        [string[]]$SessionHostVmIds = @()
    )
    $recs = Invoke-NmeAz -Arguments @('advisor', 'recommendation', 'list', '--category', 'Cost', '--subscription', $SubscriptionId)
    if (-not $recs) { return @() }

    $out = [System.Collections.Generic.List[object]]::new()
    $hostIdSet = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($id in $SessionHostVmIds) { [void]$hostIdSet.Add($id) }

    foreach ($r in @($recs)) {
        $ep = $r.extendedProperties
        if (-not $ep) { continue }
        # Savings can arrive as monthly (savingsAmount) or annual (annualSavingsAmount, e.g. RI purchase recs).
        $monthly = 0.0
        if ($ep.PSObject.Properties['savingsAmount']) { [void][double]::TryParse("$($ep.savingsAmount)", [ref]$monthly) }
        if ($monthly -le 0 -and $ep.PSObject.Properties['annualSavingsAmount']) {
            $annual = 0.0
            if ([double]::TryParse("$($ep.annualSavingsAmount)", [ref]$annual)) { $monthly = $annual / 12 }
        }
        if ($monthly -le 0) { continue }   # informational recs (e.g. unattached disks) carry no figure
        $resId = "$($r.resourceMetadata.resourceId)"
        if (-not $resId) { $resId = "$($r.impactedValue)" }
        $isSessionHost = $false
        if ($hostIdSet.Count -gt 0 -and $resId) { $isSessionHost = $hostIdSet.Contains($resId) }
        $isRightsize = ($ep.PSObject.Properties['currentSku'] -and $ep.PSObject.Properties['targetSku'])
        $target = ''
        if ($isRightsize) { $target = "$($ep.targetSku)" }
        elseif ($ep.PSObject.Properties['displaySKU']) { $target = "$($ep.displaySKU)" }
        elseif ($ep.PSObject.Properties['recommendedAction']) { $target = "$($ep.recommendedAction)" }
        $kind = 'Other'
        if ($isRightsize) { $kind = 'Rightsize' }
        elseif ("$($ep.recommendationSubCategory)") { $kind = "$($ep.recommendationSubCategory)" }
        $out.Add([pscustomobject]@{
            vmName         = "$($r.impactedValue)"
            resourceId     = $resId
            kind           = $kind
            summary        = "$($r.shortDescription.solution)"
            currentSku     = "$($ep.currentSku)"
            targetSku      = $target
            monthlySavings = [math]::Round($monthly, 2)
            currency       = "$($ep.savingsCurrency)"
            isSessionHost  = $isSessionHost
            isRightsize    = $isRightsize
        })
    }
    return $out.ToArray()
}

function Get-NmeActualDisks {
    <# Ground-truth managed-disk inventory for the environment's resource groups. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SubscriptionId,
        [Parameter(Mandatory)][string[]]$ResourceGroups
    )
    $out = [System.Collections.Generic.List[object]]::new()
    foreach ($rg in $ResourceGroups | Sort-Object -Unique) {
        $disks = Invoke-NmeAz -Arguments @('disk', 'list', '--resource-group', $rg, '--subscription', $SubscriptionId)
        foreach ($d in @($disks)) {
            $out.Add([pscustomobject]@{
                name          = $d.name
                resourceGroup = $rg
                skuName       = $d.sku.name
                tier          = $d.tier
                diskSizeGb    = $d.diskSizeGb
                managedBy     = $d.managedBy
            })
        }
    }
    return $out.ToArray()
}

function Get-NmeLawIngestion {
    <#
      Billable ingestion for the last 30 days across Log Analytics workspaces in the
      subscription, split out for the User Input Delay counters. Returns
      @{ workspaceName; totalGbPerMonth; uidGbPerMonth; topCounters } or $null.
      Queries every workspace and keeps the one with the most Perf data (the AVD one).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$SubscriptionId)

    if (-not (Test-NmeAzExtension -Name 'log-analytics')) {
        Write-Warning 'az log-analytics extension unavailable - skipping workspace ingestion queries.'
        return $null
    }
    $wss = Invoke-NmeAz -Arguments @('monitor', 'log-analytics', 'workspace', 'list', '--subscription', $SubscriptionId)
    if (-not $wss) { return $null }

    $best = $null
    foreach ($ws in @($wss)) {
        $cid = "$($ws.customerId)"
        if (-not $cid) { continue }
        # The User Input Delay counters live under ObjectName 'User Input Delay per Process/Session'
        # with CounterName 'Max Input Delay' - match on ObjectName, not CounterName.
        $perf = Invoke-NmeAz -Arguments @('monitor', 'log-analytics', 'query', '-w', $cid, '--analytics-query',
            'Perf | where TimeGenerated > ago(30d) | summarize SizeGB = sum(_BilledSize)/1e9 by ObjectName, CounterName | order by SizeGB desc')
        if (-not $perf -or @($perf).Count -eq 0) { continue }

        $rows = @($perf)
        $uidGb = 0.0; $perfTotal = 0.0
        foreach ($row in $rows) {
            $gb = 0.0
            [void][double]::TryParse("$($row.SizeGB)", [ref]$gb)
            $perfTotal += $gb
            if ("$($row.ObjectName)" -like 'User Input Delay*' -or "$($row.CounterName)" -like '*Input Delay*') { $uidGb += $gb }
        }

        $usage = Invoke-NmeAz -Arguments @('monitor', 'log-analytics', 'query', '-w', $cid, '--analytics-query',
            'Usage | where TimeGenerated > ago(30d) and IsBillable == true | summarize TotalGB = sum(Quantity)/1024')
        $totalGb = $perfTotal
        if ($usage -and @($usage).Count -gt 0) {
            $t = 0.0
            if ([double]::TryParse("$(@($usage)[0].TotalGB)", [ref]$t) -and $t -gt 0) { $totalGb = $t }
        }

        $candidate = [pscustomobject]@{
            workspaceName   = "$($ws.name)"
            totalGbPerMonth = [math]::Round($totalGb, 2)
            uidGbPerMonth   = [math]::Round($uidGb, 2)
            perfGbPerMonth  = [math]::Round($perfTotal, 2)
            topCounters     = @($rows | Select-Object -First 5 | ForEach-Object { "{0}\{1}: {2:N2} GB" -f $_.ObjectName, $_.CounterName, [double]$_.SizeGB })
        }
        if (-not $best -or $candidate.perfGbPerMonth -gt $best.perfGbPerMonth) { $best = $candidate }
    }
    return $best
}

function Get-NmeAzureFilesUsage {
    <# Provisioned vs used GiB for the FSLogix Azure Files shares NME resolved. Best effort. #>
    [CmdletBinding()]
    param([array]$StorageLocations)

    $out = [System.Collections.Generic.List[object]]::new()
    foreach ($loc in @($StorageLocations)) {
        if ($loc.type -ne 'AzureFiles' -or -not $loc.subscriptionId -or -not $loc.resourceGroup) { continue }
        $share = Invoke-NmeAz -Arguments @('storage', 'share-rm', 'show',
            '--storage-account', $loc.account, '--name', $loc.share,
            '--resource-group', $loc.resourceGroup, '--subscription', $loc.subscriptionId, '--include-stats')
        if (-not $share) { continue }
        $usedGib = $null
        if ($share.PSObject.Properties['shareUsageBytes'] -and $share.shareUsageBytes) {
            $usedGib = [math]::Round($share.shareUsageBytes / 1GB, 1)
        }
        $out.Add([pscustomobject]@{
            account        = $loc.account
            share          = $loc.share
            provisionedGib = $share.shareQuota
            usedGib        = $usedGib
            accessTier     = "$($share.accessTier)"
            perGibMonthly  = $null   # filled by the engine from retail pricing when quantifying
        })
    }
    return $out.ToArray()
}

function Get-NmeAzureEnrichment {
    <# Orchestrator. Returns $null when az is unavailable; otherwise a best-effort bundle. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][psobject]$Environment)

    if (-not (Test-NmeAzCli)) {
        Write-Host '  az CLI not available/authenticated - skipping Azure enrichment (modelled figures only).' -ForegroundColor DarkYellow
        return $null
    }

    # Distinct subscriptions + RGs actually referenced by the environment's host pools.
    $subs = @($Environment.hostPools | ForEach-Object { $_.ref.subscriptionId } | Sort-Object -Unique)
    $vmIds = @($Environment.hostPools | ForEach-Object { @($_.hosts) } | ForEach-Object { "$($_.vmId)" } | Where-Object { $_ })

    $advisor = [System.Collections.Generic.List[object]]::new()
    $disks = [System.Collections.Generic.List[object]]::new()
    $law = $null
    foreach ($sub in $subs) {
        Write-Host "  Azure enrichment: subscription $sub"
        $rgs = @($Environment.hostPools | Where-Object { $_.ref.subscriptionId -eq $sub } | ForEach-Object { $_.ref.resourceGroup } | Sort-Object -Unique)
        foreach ($a in @(Get-NmeAdvisorRightsizing -SubscriptionId $sub -SessionHostVmIds $vmIds)) { $advisor.Add($a) }
        foreach ($d in @(Get-NmeActualDisks -SubscriptionId $sub -ResourceGroups $rgs)) { $disks.Add($d) }
        if (-not $law) { $law = Get-NmeLawIngestion -SubscriptionId $sub }
    }
    $files = Get-NmeAzureFilesUsage -StorageLocations $Environment.storageLocations

    Write-Host ("  Azure enrichment: {0} advisor rec(s), {1} disk(s), LAW data: {2}, {3} share(s)." -f `
        $advisor.Count, $disks.Count, $(if ($law) { "$($law.uidGbPerMonth) GB UID / $($law.totalGbPerMonth) GB total" } else { 'none' }), @($files).Count)

    [pscustomobject]@{
        collectedAt  = (Get-Date).ToString('o')
        advisor      = @($advisor | Where-Object { $_.isSessionHost })
        advisorOther = @($advisor | Where-Object { -not $_.isSessionHost })
        disks        = $disks.ToArray()
        lawIngestion = $law
        azureFiles   = $files
    }
}
