<#
.SYNOPSIS
  Cost Optimisation engine — quantifies potential savings from Nerdio features.
.DESCRIPTION
  Pure functions over the collected environment plus optional observed data
  (Tier 1, from the NME console) and Azure enrichment (Tier 2, az CLI).
  Every figure carries an evidence tier and its assumptions. Modelled (Tier 3)
  figures are conservative-typical ranges; measured figures are point values.

  Plays:
    1 autoscale-base-capacity   3 rolling-drain        5 osdisk-right-tier   7 law-counters
    2 prestage-optimisation     4 stopped-disk-tier    6 vm-rightsizing      8 storage-autoscale
#>

function New-CostPlay {
    param(
        [string]$Id, [string]$Title, [string]$Scope, [string]$Tier,
        [string]$CurrentState, [string]$Recommendation,
        $MonthlyLow, $MonthlyTypical,
        [string[]]$Assumptions = @(), [string[]]$Evidence = @(),
        [string[]]$DependsOn = @(), [string]$Reference = ''
    )
    $quantified = ($null -ne $MonthlyTypical -and $MonthlyTypical -gt 0)
    [pscustomobject]@{
        id = $Id; title = $Title; scope = $Scope; tier = $Tier
        currentState = $CurrentState; recommendation = $Recommendation
        monthlyLow = $MonthlyLow; monthlyTypical = $MonthlyTypical
        quantified = $quantified; dependsOn = $DependsOn
        assumptions = $Assumptions; evidence = $Evidence; reference = $Reference
    }
}

function Get-NmePoolRegion {
    param($HostPool, $Environment)
    if ($HostPool.ref.PSObject.Properties['location'] -and $HostPool.ref.location) { return $HostPool.ref.location }
    $ws = @($Environment.workspaces) | Select-Object -First 1
    if ($ws -and $ws.location) { return $ws.location }
    return 'eastus'
}

function Get-NmePoolComputeRate {
    <# Hourly rate for a pool's VM template, honouring the hybrid-benefit assumption.
       Returns @{ rate; skuName; note; windowsHr; available } #>
    param($HostPool, [string]$Region, [hashtable]$Cache, [psobject]$Assumptions, [string]$Currency, [int]$TtlDays)
    $size = "$($HostPool.autoScale.vmTemplate.size)"
    if (-not $size) { return @{ available = $false } }
    $r = Get-NmeVmHourlyRate -Region $Region -SkuName $size -Cache $Cache -Currency $Currency -TtlDays $TtlDays
    $useAhb = ($Assumptions.hybridBenefit -eq $true)
    $rate = $null
    if ($useAhb -and $null -ne $r.linuxHr) { $rate = $r.linuxHr }
    elseif ($null -ne $r.windowsHr)        { $rate = $r.windowsHr }
    elseif ($null -ne $r.linuxHr)          { $rate = $r.linuxHr }
    if ($null -eq $rate) { return @{ available = $false; skuName = $size } }
    $note = "Compute priced at {0:N4}/hr ({1}, {2}, {3}). Windows PAYG rate {4}/hr shown as upper bound where relevant." -f `
        $rate, $size, $Region, $(if ($useAhb) { 'base rate - assumes Azure Hybrid Benefit' } else { 'Windows PAYG' }), $(if ($null -ne $r.windowsHr) { '{0:N4}' -f $r.windowsHr } else { 'n/a' })
    return @{ available = $true; rate = [double]$rate; skuName = $size; note = $note; windowsHr = $r.windowsHr; source = $r.source }
}

function Get-NmeUncoveredFraction {
    <#
      Fraction of a pool's compute NOT already covered by an RI/Savings Plan.
      Per-pool riCoveragePercent (observed data) overrides the environment figure,
      which overrides the assumptions default. Returns @{ fraction; coveragePct }.
      Compute savings from powering hosts off apply only to this uncovered fraction -
      pre-paid capacity saves nothing when it is switched off.
    #>
    param($HostPool, [hashtable]$Ctx)
    $pct = $null
    $name = $HostPool.ref.name
    if ($Ctx.observed -and $Ctx.observed.hostPools) {
        $po = @($Ctx.observed.hostPools) | Where-Object { $_.name -eq $name } | Select-Object -First 1
        if ($po -and $po.PSObject.Properties['riCoveragePercent'] -and $null -ne $po.riCoveragePercent) { $pct = [double]$po.riCoveragePercent }
    }
    if ($null -eq $pct -and $Ctx.observed -and $Ctx.observed.environment -and
        $Ctx.observed.environment.PSObject.Properties['riCoveragePercent'] -and $null -ne $Ctx.observed.environment.riCoveragePercent) {
        $pct = [double]$Ctx.observed.environment.riCoveragePercent
    }
    if ($null -eq $pct) { $pct = [double]$Ctx.assum.commitDiscount.defaultCoveragePercent }
    $pct = [math]::Max(0, [math]::Min(100, $pct))
    return @{ fraction = (1 - $pct / 100); coveragePct = $pct }
}

function Measure-AutoScaleBaseCapacity {
    param($HostPool, [bool]$Pooled, [hashtable]$Ctx)
    $as = $HostPool.autoScale
    $name = $HostPool.ref.name
    if (-not $as -or -not $Pooled) { return $null }
    $cov = Get-NmeUncoveredFraction -HostPool $HostPool -Ctx $Ctx
    $covNote = if ($cov.coveragePct -gt 0) { ("Reduced to the {0:P0} of compute not already covered by a reservation/savings plan (powering off pre-paid capacity saves nothing)." -f $cov.fraction) } else { $null }
    $rateInfo = $Ctx.rates[$name]
    if (-not $rateInfo.available) { return $null }
    $R = $rateInfo.rate
    $hOff = $Ctx.hoursOff
    $hostCount = [int]$HostPool.ref.hostCount

    # Measured figure from the NME console wins outright for this pool.
    $measured = $null
    if ($Ctx.observed -and $Ctx.observed.hostPools) {
        $measured = @($Ctx.observed.hostPools) | Where-Object { $_.name -eq $name -and $_.autoScaleSavings.amount } | Select-Object -First 1
    }

    if ($as.isEnabled -ne $true) {
        $typical = $hostCount * $R * $hOff * $cov.fraction
        $low = [math]::Max(0, $hostCount - 1) * $R * $hOff * $cov.fraction
        $deallocCount = @($HostPool.hosts | Where-Object { "$($_.powerState)" -match 'deallocated' }).Count
        $stateNote = if ($deallocCount -ge $hostCount) {
            "All $hostCount host(s) are currently deallocated (manually managed). The figure represents avoided cost versus running them through the month without auto-scale switching them off."
        } elseif ($deallocCount -gt 0) {
            "$deallocCount of $hostCount host(s) are currently deallocated; the rest run without scheduled power management."
        } else {
            "All $hostCount host(s) are currently running with no automated power management."
        }
        return New-CostPlay -Id 'autoscale-base-capacity' -Title 'Enable auto-scale' -Scope $name -Tier 'Modelled' `
            -CurrentState ("Auto-scale is OFF for this pool of {0} x {1}. Without it, capacity only powers off when someone remembers to do it. {2}" -f $hostCount, $rateInfo.skuName, $stateNote) `
            -Recommendation 'Enable dynamic auto-scale so hosts power off outside the business window and scale to demand within it.' `
            -MonthlyLow $low -MonthlyTypical $typical `
            -Assumptions (@(
                ("Business window {0}h x {1}d/week; ~{2:N0} off-hours per month reclaimable per host." -f $Ctx.assum.workingHours.hoursPerDay, $Ctx.assum.workingHours.daysPerWeek, $hOff),
                $rateInfo.note,
                'Conservative figure keeps one host running 24x7.'
            ) + @($covNote | Where-Object { $_ })) -Evidence @("Pricing source: $($rateInfo.source)")
    }

    # Auto-scale on - check the standing base capacity.
    $svoc = $false
    if ($as.extensions -and $as.extensions.startVmOnConnect -eq $true) { $svoc = $true }
    $recMin = if ($svoc) { [int]$Ctx.assum.autoScale.recommendedMinActiveWithStartOnConnect } else { [int]$Ctx.assum.autoScale.recommendedMinActiveWithoutStartOnConnect }
    $min = [int]$as.minActiveHostsCount
    if ($min -le $recMin) {
        if ($measured) {
            return New-CostPlay -Id 'autoscale-base-capacity' -Title 'Auto-scale savings (already realised)' -Scope $name -Tier 'Measured' `
                -CurrentState ("Auto-scale is ON and the base capacity is lean (min active hosts: {0})." -f $min) `
                -Recommendation 'No change - keep the current configuration.' `
                -MonthlyLow $null -MonthlyTypical $null `
                -Evidence @(("NME auto-scale history: {0:N2} {1} ({2}%) saved over the reported period." -f $measured.autoScaleSavings.amount, $Ctx.currency, $measured.autoScaleSavings.percent))
        }
        return $null
    }
    $excess = $min - $recMin
    $typical = $excess * $R * $hOff * $cov.fraction
    $low = [math]::Round($typical * [double]$Ctx.assum.conservativeFactor, 2)
    $svocText = if ($svoc) { 'Start VM on Connect is enabled, so the base can drop to zero - the first user powers a host on.' } else { 'Consider enabling Start VM on Connect to allow a zero-host base outside hours.' }
    return New-CostPlay -Id 'autoscale-base-capacity' -Title 'Reduce base host pool capacity' -Scope $name -Tier $(if ($measured) { 'Measured' } else { 'Modelled' }) `
        -CurrentState ("Auto-scale is ON but keeps {0} host(s) always active; recommended base here is {1}." -f $min, $recMin) `
        -Recommendation ("Lower minimum active hosts from {0} to {1}. {2}" -f $min, $recMin, $svocText) `
        -MonthlyLow $low -MonthlyTypical $typical `
        -Assumptions (@(
            ("Each surplus base host runs ~{0:N0} avoidable off-hours per month." -f $Ctx.hoursOff),
            $rateInfo.note
        ) + @($covNote | Where-Object { $_ })) -Evidence @(if ($measured) { ("NME auto-scale history: {0:N2} {1} ({2}%) saved over the reported period." -f $measured.autoScaleSavings.amount, $Ctx.currency, $measured.autoScaleSavings.percent) } else { "Pricing source: $($rateInfo.source)" })
}

function Measure-PreStageOptimisation {
    param($HostPool, [bool]$Pooled, [hashtable]$Ctx)
    $as = $HostPool.autoScale
    $name = $HostPool.ref.name
    if (-not $as -or -not $Pooled -or $as.isEnabled -ne $true) { return $null }
    if (-not $as.preStageHosts -or $as.preStageHosts.enable -ne $true) { return $null }

    $cfgs = @()
    if ($as.preStageHosts.isMultipleConfigsMode -eq $true -and $as.preStageHosts.configs) { $cfgs = @($as.preStageHosts.configs) }
    elseif ($as.preStageHosts.config) { $cfgs = @($as.preStageHosts.config) }
    if (-not $cfgs) { return $null }

    $ready = ($cfgs | ForEach-Object { [int]$_.hostsToBeReady } | Measure-Object -Maximum).Maximum
    $cap = [math]::Max(1, [int]$as.hostPoolCapacity)
    $recommendedReady = [math]::Ceiling($cap * [double]$Ctx.assum.preStage.recommendedReadyFraction)
    if ($ready -le $recommendedReady) { return $null }

    $rateInfo = $Ctx.rates[$name]
    if (-not $rateInfo.available) { return $null }
    $cov = Get-NmeUncoveredFraction -HostPool $HostPool -Ctx $Ctx
    $excess = $ready - $recommendedReady
    $typical = $excess * $rateInfo.rate * [double]$Ctx.assum.preStage.leadHours * [double]$Ctx.assum.workdaysPerMonth * $cov.fraction
    $low = [math]::Round($typical * [double]$Ctx.assum.conservativeFactor, 2)
    $covNote = if ($cov.coveragePct -gt 0) { ("Reduced to the {0:P0} of compute not covered by a reservation/savings plan." -f $cov.fraction) } else { $null }
    return New-CostPlay -Id 'prestage-optimisation' -Title 'Trim pre-staged capacity' -Scope $name -Tier 'Modelled' `
        -CurrentState ("Pre-staging brings {0} host(s) online ahead of the workday against a pool capacity of {1}." -f $ready, $cap) `
        -Recommendation ("Reduce pre-staged hosts towards ~{0} (about {1:P0} of capacity) and let auto-scale triggers add the rest as demand builds. Review NME's intelligent pre-staging if logon storms are the concern." -f $recommendedReady, [double]$Ctx.assum.preStage.recommendedReadyFraction) `
        -MonthlyLow $low -MonthlyTypical $typical `
        -Assumptions (@(
            ("Each surplus pre-staged host runs ~{0}h before demand needs it, {1} workdays/month." -f $Ctx.assum.preStage.leadHours, $Ctx.assum.workdaysPerMonth),
            $rateInfo.note,
            'Low-confidence heuristic - validate against the pool''s logon pattern before acting.'
        ) + @($covNote | Where-Object { $_ }))
}

function Measure-RollingDrainMode {
    param($HostPool, [bool]$Pooled, [hashtable]$Ctx)
    $as = $HostPool.autoScale
    $name = $HostPool.ref.name
    if (-not $as -or -not $Pooled -or $as.isEnabled -ne $true) { return $null }
    if ($as.rollingDrainMode -and $as.rollingDrainMode.isEnabled -eq $true) { return $null }

    $rateInfo = $Ctx.rates[$name]
    if (-not $rateInfo.available) { return $null }
    $cov = Get-NmeUncoveredFraction -HostPool $HostPool -Ctx $Ctx
    $cap = [int]$as.hostPoolCapacity
    $min = [int]$as.minActiveHostsCount
    $scalingHosts = [math]::Max(0, $cap - $min) * [double]$Ctx.assum.rollingDrain.drainingHostsFraction
    if ($scalingHosts -le 0) { return $null }
    $wd = [double]$Ctx.assum.workdaysPerMonth
    $low = $scalingHosts * $rateInfo.rate * [double]$Ctx.assum.rollingDrain.hoursSavedPerHostPerDayLow * $wd * $cov.fraction
    $typical = $scalingHosts * $rateInfo.rate * [double]$Ctx.assum.rollingDrain.hoursSavedPerHostPerDayTypical * $wd * $cov.fraction
    $covNote = if ($cov.coveragePct -gt 0) { ("Reduced to the {0:P0} of compute not covered by a reservation/savings plan." -f $cov.fraction) } else { $null }
    return New-CostPlay -Id 'rolling-drain' -Title 'Enable rolling drain mode' -Scope $name -Tier 'Modelled' `
        -CurrentState 'Rolling drain mode is OFF - scaling-in hosts keep accepting new sessions, so they empty (and power off) later than they could.' `
        -Recommendation 'Enable rolling drain so hosts marked for scale-in stop taking new sessions and can deallocate as soon as existing sessions end.' `
        -MonthlyLow $low -MonthlyTypical $typical `
        -Assumptions (@(
            ("~{0:N1} host(s) assumed draining at a time (half of the {1}-host scaling range); each powers off {2}-{3}h sooner per workday." -f $scalingHosts, [math]::Max(0, $cap - $min), $Ctx.assum.rollingDrain.hoursSavedPerHostPerDayLow, $Ctx.assum.rollingDrain.hoursSavedPerHostPerDayTypical),
            $rateInfo.note
        ) + @($covNote | Where-Object { $_ }))
}

function Measure-StoppedDiskTiering {
    param($HostPool, [bool]$Pooled, [hashtable]$Ctx, [string[]]$DependsOn = @())
    $as = $HostPool.autoScale
    $name = $HostPool.ref.name
    if (-not $as) { return $null }
    $vt = $as.vmTemplate
    if (-not $vt -or $vt.hasEphemeralOSDisk -eq $true) { return $null }

    $runType = "$($vt.storageType)"
    $stopType = "$($as.stoppedDiskType)"
    $effectiveStop = if ($stopType) { $stopType } else { $runType }
    if ($effectiveStop -notin 'Premium_LRS', 'PremiumV2_LRS') { return $null }

    $size = [int]$vt.diskSize
    $curSku = ConvertTo-NmeDiskSku -DiskSizeGb $size -StorageType 'Premium_LRS'
    $tgtSku = ConvertTo-NmeDiskSku -DiskSizeGb $size -StorageType 'StandardSSD_LRS'
    if (-not $curSku -or -not $tgtSku) { return $null }
    $region = $Ctx.regions[$name]
    $cur = Get-NmeDiskMonthlyRate -Region $region -DiskSku $curSku -Cache $Ctx.cache -Assumptions $Ctx.assum -Currency $Ctx.currency -TtlDays $Ctx.ttlDays
    $tgt = Get-NmeDiskMonthlyRate -Region $region -DiskSku $tgtSku -Cache $Ctx.cache -Assumptions $Ctx.assum -Currency $Ctx.currency -TtlDays $Ctx.ttlDays
    if ($null -eq $cur.monthly -or $null -eq $tgt.monthly) { return $null }

    $hostCount = [int]$HostPool.ref.hostCount
    $deallocFraction = $Ctx.hoursOff / [double]$Ctx.assum.hoursPerMonth
    $typical = $hostCount * ($cur.monthly - $tgt.monthly) * $deallocFraction
    $low = [math]::Round($typical * [double]$Ctx.assum.conservativeFactor, 2)
    return New-CostPlay -Id 'stopped-disk-tier' -Title 'Down-tier OS disks while deallocated' -Scope $name -Tier 'Modelled' `
        -CurrentState ("Stopped (deallocated) hosts keep a {0} OS disk ({1}), which bills at the premium rate even while powered off." -f $effectiveStop, $curSku) `
        -Recommendation ("Set the stopped disk type to Standard SSD - NME swaps each OS disk to {0} on deallocation and back on start, with no user impact." -f $tgtSku) `
        -MonthlyLow $low -MonthlyTypical $typical -DependsOn $DependsOn `
        -Assumptions @(
            ("{0} host(s), {1} {2:N2} vs {3} {4:N2} per month, deallocated ~{5:P0} of the month." -f $hostCount, $curSku, $cur.monthly, $tgtSku, $tgt.monthly, $deallocFraction),
            'Only accrues while hosts are actually deallocated - depends on auto-scale powering hosts off.'
        ) -Evidence @("Disk pricing: $($cur.meter); $($tgt.meter)")
}

function Measure-OsDiskRightTiering {
    param($HostPool, [bool]$Pooled, [hashtable]$Ctx, [string[]]$DependsOn = @())
    $as = $HostPool.autoScale
    $name = $HostPool.ref.name
    if (-not $as -or -not $Pooled) { return $null }
    $vt = $as.vmTemplate
    if (-not $vt -or $vt.hasEphemeralOSDisk -eq $true) { return $null }
    if ("$($vt.storageType)" -ne 'Premium_LRS') { return $null }
    if ($HostPool.fslogix.enable -ne $true) { return $null }   # only safe when profile IO is offloaded

    $size = [int]$vt.diskSize
    $curSku = ConvertTo-NmeDiskSku -DiskSizeGb $size -StorageType 'Premium_LRS'
    $tgtSku = ConvertTo-NmeDiskSku -DiskSizeGb $size -StorageType 'StandardSSD_LRS'
    $region = $Ctx.regions[$name]
    $cur = Get-NmeDiskMonthlyRate -Region $region -DiskSku $curSku -Cache $Ctx.cache -Assumptions $Ctx.assum -Currency $Ctx.currency -TtlDays $Ctx.ttlDays
    $tgt = Get-NmeDiskMonthlyRate -Region $region -DiskSku $tgtSku -Cache $Ctx.cache -Assumptions $Ctx.assum -Currency $Ctx.currency -TtlDays $Ctx.ttlDays
    if ($null -eq $cur.monthly -or $null -eq $tgt.monthly) { return $null }

    # If the stopped-disk swap is already in place, only the running hours remain premium.
    $stopType = "$($as.stoppedDiskType)"
    $runningFraction = 1.0
    if ($stopType -and $stopType -notin 'Premium_LRS', 'PremiumV2_LRS') {
        $runningFraction = ($Ctx.assum.hoursPerMonth - $Ctx.hoursOff) / [double]$Ctx.assum.hoursPerMonth
    }
    $hostCount = [int]$HostPool.ref.hostCount
    $typical = $hostCount * ($cur.monthly - $tgt.monthly) * $runningFraction
    $low = [math]::Round($typical * [double]$Ctx.assum.conservativeFactor, 2)
    return New-CostPlay -Id 'osdisk-right-tier' -Title 'Right-tier session host OS disks' -Scope $name -Tier 'Modelled' `
        -CurrentState ("Session hosts run Premium SSD OS disks ({0}) while FSLogix already offloads profile IO to file storage." -f $curSku) `
        -Recommendation ("Move session host OS disks to Standard SSD ({0}) - on pooled hosts with FSLogix, OS disk IO rarely justifies Premium." -f $tgtSku) `
        -MonthlyLow $low -MonthlyTypical $typical -DependsOn $DependsOn `
        -Assumptions @(
            ("{0} host(s), {1} {2:N2} vs {3} {4:N2} per month, premium-billed fraction {5:P0}." -f $hostCount, $curSku, $cur.monthly, $tgtSku, $tgt.monthly, $runningFraction),
            'Validate disk latency needs for any IO-heavy app before changing tier.'
        ) -Evidence @("Disk pricing: $($cur.meter); $($tgt.meter)")
}

function Measure-VmRightsizing {
    param($Environment, [hashtable]$Ctx)
    $enrich = $Ctx.enrichment
    if ($enrich -and $enrich.advisor -and @($enrich.advisor).Count -gt 0) {
        $recs = @($enrich.advisor)
        $total = ($recs | Measure-Object -Property monthlySavings -Sum).Sum
        $lines = $recs | ForEach-Object { "{0}: {1} -> {2} ({3:N2} {4}/month)" -f $_.vmName, $_.currentSku, $_.targetSku, $_.monthlySavings, $Ctx.currency }
        return New-CostPlay -Id 'vm-rightsizing' -Title 'Right-size session host VMs' -Scope 'Environment' -Tier 'Enriched' `
            -CurrentState ("Azure Advisor flags {0} VM(s) as oversized for their observed utilisation." -f $recs.Count) `
            -Recommendation 'Apply the recommended sizes via Nerdio Advisor / host pool VM template, one pool at a time, validating user experience.' `
            -MonthlyLow $total -MonthlyTypical $total `
            -Evidence (@('Source: Azure Advisor cost recommendations.') + $lines)
    }
    return New-CostPlay -Id 'vm-rightsizing' -Title 'Right-size session host VMs' -Scope 'Environment' -Tier 'Manual' `
        -CurrentState 'VM rightsizing telemetry is not exposed by the NME REST API, and no Azure Advisor rightsizing recommendations were available for the session hosts in this run.' `
        -Recommendation 'Review Nerdio Advisor (NME console) and Auto-scale History CPU/RAM utilisation. Below ~60% sustained utilisation, smaller VM sizes or higher session density usually fit.' `
        -MonthlyLow $null -MonthlyTypical $null `
        -Assumptions @('Nerdio Advisor recommendations are visible in the NME console only.')
}

function Measure-CommitDiscount {
    <#
      Reserved Instance / Savings Plan opportunity on the always-on base capacity.
      Prices the recommended steady 24x7 floor (auto-scale ON with a >=1 host base,
      Start-VM-on-Connect off) at 1-year and 3-year compute Savings Plan rates.
      Never recommends committing capacity that auto-scale powers off, nor
      unmanaged/deallocated pools (those need auto-scale first, not a reservation).
      Coverage-adjusted so only the uncommitted portion is counted.
    #>
    param($Environment, [hashtable]$Ctx)
    if ($Ctx.assum.commitDiscount.enabled -ne $true) { return $null }

    # Environment-level existing coverage (RI/SP are bought at subscription/tenant level).
    $covPct = [double]$Ctx.assum.commitDiscount.defaultCoveragePercent
    if ($Ctx.observed -and $Ctx.observed.environment -and
        $Ctx.observed.environment.PSObject.Properties['riCoveragePercent'] -and $null -ne $Ctx.observed.environment.riCoveragePercent) {
        $covPct = [double]$Ctx.observed.environment.riCoveragePercent
    }
    $covPct = [math]::Max(0, [math]::Min(100, $covPct))
    $uncovered = 1 - $covPct / 100

    # Aggregate the recommended always-on floor by VM size.
    $bySize = @{}
    foreach ($hp in @($Environment.hostPools)) {
        $as = $hp.autoScale
        if (-not $as -or -not (Test-NmeIsPooled -HostPool $hp)) { continue }
        if ($as.isEnabled -ne $true) { continue }                 # unmanaged -> enable auto-scale first
        $min = [int]$as.minActiveHostsCount
        if ($min -lt 1) { continue }                              # already scales to zero -> nothing runs 24x7
        $svoc = ($as.extensions -and $as.extensions.startVmOnConnect -eq $true)
        if ($svoc) { continue }                                   # first user powers a host on -> no committed floor
        $size = "$($as.vmTemplate.size)"
        if (-not $size) { continue }
        # Conservative: price the recommended 1-host floor; the per-host rate lets a
        # larger justified base be extrapolated.
        if (-not $bySize.ContainsKey($size)) { $bySize[$size] = @{ hosts = 0; region = $Ctx.regions[$hp.ref.name] } }
        $bySize[$size].hosts += 1
    }

    # Azure Advisor reservation recommendations (measured), if enrichment ran.
    $riRecs = @()
    if ($Ctx.enrichment -and $Ctx.enrichment.advisorOther) {
        $riRecs = @($Ctx.enrichment.advisorOther | Where-Object { "$($_.kind)" -match 'Reservation' -and $_.monthlySavings -gt 0 })
    }
    $riMonthly = ($riRecs | Measure-Object -Property monthlySavings -Sum).Sum

    $save1yr = 0.0; $save3yr = 0.0; $lines = @(); $any = $false
    foreach ($size in ($bySize.Keys | Sort-Object)) {
        $hosts = $bySize[$size].hosts
        $rate = Get-NmeCommitRate -Region $bySize[$size].region -SkuName $size -Cache $Ctx.cache -Currency $Ctx.currency -TtlDays $Ctx.ttlDays
        if ($null -eq $rate.payg -or ($null -eq $rate.sp1yr -and $null -eq $rate.sp3yr)) { continue }
        $any = $true
        $s1 = if ($null -ne $rate.sp1yr) { $hosts * ($rate.payg - $rate.sp1yr) * $Ctx.assum.hoursPerMonth * $uncovered } else { 0 }
        $s3 = if ($null -ne $rate.sp3yr) { $hosts * ($rate.payg - $rate.sp3yr) * $Ctx.assum.hoursPerMonth * $uncovered } else { $s1 }
        $save1yr += $s1; $save3yr += $s3
        $lines += ("{0} x {1}: PAYG {2:N4}/hr vs SP {3:N4} (1yr) / {4:N4} (3yr) per host." -f $hosts, $size, $rate.payg, $rate.sp1yr, $rate.sp3yr)
    }

    $covAssume = if ($covPct -gt 0) { ("Priced on the {0:P0} of the base not already covered by an existing reservation/savings plan." -f $uncovered) } else { 'Assumes no existing reservation/savings-plan coverage - set riCoveragePercent in observed data if the customer already has some.' }
    $tradeoff = 'Applies only to capacity that stays on 24x7 after auto-scale optimisation. Commit the steady floor; let auto-scale handle the peaks. Do not reserve capacity you intend to power off.'

    if ($any -and $save1yr -gt 0) {
        $tier = if ($riRecs.Count -gt 0) { 'Enriched' } else { 'Modelled' }
        $evidence = @('Savings Plan rates: Azure Retail Prices API (compute, 1yr/3yr).') + $lines
        if ($riRecs.Count -gt 0) { $evidence += ("Azure Advisor independently recommends {0} reserved-instance purchase(s) worth ~{1:N0} {2}/month." -f $riRecs.Count, $riMonthly, $Ctx.currency) }
        return New-CostPlay -Id 'commit-discount' -Title 'Commit the always-on base (Reserved Instances / Savings Plan)' -Scope 'Environment' -Tier $tier `
            -CurrentState 'Host pools keep a base of hosts running 24x7 that is billed at pay-as-you-go rates.' `
            -Recommendation 'Cover the steady 24x7 base with a 1-year or 3-year compute Savings Plan (or Reserved Instances). Nerdio''s RI Analytics (Premium) shows exactly how many CPU-hours are steady enough to commit.' `
            -MonthlyLow ([math]::Round($save1yr, 2)) -MonthlyTypical ([math]::Round($save3yr, 2)) `
            -Assumptions @(
                'Range is 1-year Savings Plan (lower) to 3-year (higher discount, longer commitment).',
                'Priced on the recommended 1-host steady floor per qualifying pool - a larger justified 24x7 base scales the saving pro-rata (see per-host rates).',
                $covAssume,
                $tradeoff
            ) -Evidence $evidence
    }

    # Nothing genuinely runs 24x7 (or auto-scale not yet enabled) -> educational/review card.
    $reviewState = if ($riRecs.Count -gt 0) {
        ("No steady 24x7 base was found in the auto-scale configuration, but Azure Advisor flags {0} reserved-instance opportunity worth ~{1:N0} {2}/month against current running patterns." -f $riRecs.Count, $riMonthly, $Ctx.currency)
    } else {
        'No steady 24x7 base was found: pools either scale to zero or are not yet under auto-scale management, so there is no fixed floor to commit today.'
    }
    return New-CostPlay -Id 'commit-discount' -Title 'Reserved Instances / Savings Plan' -Scope 'Environment' -Tier $(if ($riRecs.Count -gt 0) { 'Enriched' } else { 'Manual' }) `
        -CurrentState $reviewState `
        -Recommendation 'Once auto-scale is enabled and the steady 24x7 floor is known, cover that floor with a 1yr/3yr Savings Plan or Reserved Instances. Use NME RI Analytics (Premium) to size the commitment; keep auto-scale for the variable layer above it.' `
        -MonthlyLow $null -MonthlyTypical $null `
        -Assumptions @($tradeoff, $covAssume) `
        -Evidence @($lines + $(if ($riRecs.Count -gt 0) { $riRecs | ForEach-Object { "Advisor: $($_.summary) (~$([math]::Round($_.monthlySavings)) $($Ctx.currency)/mo)" } }) | Where-Object { $_ })
}

function Measure-LawCounterOptimisation {
    param($Environment, [hashtable]$Ctx)
    $assum = $Ctx.assum
    $region = $Ctx.defaultRegion
    $law = Get-NmeLawIngestionRate -Region $region -Cache $Ctx.cache -Assumptions $assum -Currency $Ctx.currency -TtlDays $Ctx.ttlDays
    if ($null -eq $law.perGb) { return $null }

    $totalHosts = 0
    foreach ($hp in @($Environment.hostPools)) { $totalHosts += [int]$hp.ref.hostCount }

    $tier = 'Modelled'; $evidence = @("Log Analytics ingestion rate: {0:N2} {1}/GB ({2})" -f $law.perGb, $Ctx.currency, $law.meter)
    $uidLow = $null; $uidTypical = $null; $basisNote = ''
    $sNow = [double]$assum.law.currentSampleSecondsDefault

    if ($Ctx.enrichment -and $Ctx.enrichment.lawIngestion -and $null -ne $Ctx.enrichment.lawIngestion.uidGbPerMonth) {
        $tier = 'Enriched'
        $uidLow = [double]$Ctx.enrichment.lawIngestion.uidGbPerMonth
        $uidTypical = $uidLow
        $basisNote = "User Input Delay ingestion measured from the Log Analytics workspace: {0:N1} GB over the last 30 days." -f $uidLow
        $evidence += "KQL: Perf | summarize sum(_BilledSize) by CounterName (30d), workspace $($Ctx.enrichment.lawIngestion.workspaceName)"
    } elseif ($Ctx.observed -and $Ctx.observed.environment -and $null -ne $Ctx.observed.environment.lawUserInputDelayGbPerMonth) {
        $tier = 'Measured'
        $uidLow = [double]$Ctx.observed.environment.lawUserInputDelayGbPerMonth
        $uidTypical = $uidLow
        if ($Ctx.observed.environment.lawCurrentSampleSeconds) { $sNow = [double]$Ctx.observed.environment.lawCurrentSampleSeconds }
        $basisNote = "User Input Delay ingestion of {0:N1} GB/month recorded from the customer's workspace." -f $uidLow
    } elseif ($Ctx.observed -and $Ctx.observed.environment -and $null -ne $Ctx.observed.environment.lawIngestionGbPerMonth) {
        $tier = 'Measured'
        $totalGb = [double]$Ctx.observed.environment.lawIngestionGbPerMonth
        $uidLow = $totalGb * [double]$assum.law.uidShareOfIngestionLow
        $uidTypical = $totalGb * [double]$assum.law.uidShareOfIngestionTypical
        if ($Ctx.observed.environment.lawCurrentSampleSeconds) { $sNow = [double]$Ctx.observed.environment.lawCurrentSampleSeconds }
        $basisNote = "Total ingestion of {0:N1} GB/month recorded; User Input Delay counters typically account for {1:P0}-{2:P0} of AVD ingestion." -f $totalGb, [double]$assum.law.uidShareOfIngestionLow, [double]$assum.law.uidShareOfIngestionTypical
    } else {
        if ($totalHosts -eq 0) { return $null }
        $uidLow = $totalHosts * [double]$assum.law.uidGbPerHostMonthLow
        $uidTypical = $totalHosts * [double]$assum.law.uidGbPerHostMonthTypical
        $basisNote = "ESTIMATE ONLY: {0} session host(s) x {1}-{2} GB/host/month of User Input Delay data at the default 60s sample rate. Measure the real figure in Azure (Perf table by CounterName) or the NME console before quoting." -f $totalHosts, $assum.law.uidGbPerHostMonthLow, $assum.law.uidGbPerHostMonthTypical
    }

    if ($sNow -ge [double]$assum.law.targetSampleSecondsConservative) { return $null }   # already optimised
    $redLow = 1 - ($sNow / [double]$assum.law.targetSampleSecondsConservative)
    $redTypical = 1 - ($sNow / [double]$assum.law.targetSampleSecondsTypical)
    $mLow = $uidLow * $redLow * $law.perGb
    $mTypical = $uidTypical * $redTypical * $law.perGb
    if ($tier -ne 'Modelled' -and $mTypical -lt 1) { return $null }   # measured and already negligible

    return New-CostPlay -Id 'law-counters' -Title 'Optimise Log Analytics performance counters' -Scope 'Environment' -Tier $tier `
        -CurrentState ("The 'User Input Delay per Process' counter at a {0:N0}s sample rate is typically the single largest AVD monitoring cost - often 80-91% of workspace ingestion." -f $sNow) `
        -Recommendation ("Raise the User Input Delay counter sample interval from {0:N0}s to {1:N0}-{2:N0}s (or disable the per-process counter) in the NME monitoring settings. No operational impact on scaling or Insights." -f $sNow, $assum.law.targetSampleSecondsConservative, $assum.law.targetSampleSecondsTypical) `
        -MonthlyLow $mLow -MonthlyTypical $mTypical `
        -Assumptions @(
            $basisNote,
            ("Ingestion volume scales with sample frequency: {0:N0}s -> {1:N0}s cuts {2:P0}; -> {3:N0}s cuts {4:P0}." -f $sNow, $assum.law.targetSampleSecondsConservative, $redLow, $assum.law.targetSampleSecondsTypical, $redTypical)
        ) -Evidence $evidence
}

function Measure-StorageAutoScaling {
    param($Environment, [hashtable]$Ctx)
    $plays = [System.Collections.Generic.List[object]]::new()
    foreach ($loc in @($Environment.storageLocations)) {
        if ($loc.type -ne 'AzureFiles') { continue }
        if ($loc.resolved -and $loc.isEnabled -eq $true) { continue }
        $scope = "$($loc.account)/$($loc.share)"

        $enriched = $null
        if ($Ctx.enrichment -and $Ctx.enrichment.azureFiles) {
            $enriched = @($Ctx.enrichment.azureFiles) | Where-Object { $_.account -eq $loc.account -and $_.share -eq $loc.share } | Select-Object -First 1
        }
        if ($enriched -and $enriched.provisionedGib -and $enriched.usedGib -and $enriched.perGibMonthly) {
            $headroom = [double]$Ctx.assum.storage.provisionedHeadroomFactor
            $reclaim = [math]::Max(0, $enriched.provisionedGib - ($enriched.usedGib * $headroom))
            if ($reclaim -gt 0) {
                $m = $reclaim * $enriched.perGibMonthly
                $plays.Add((New-CostPlay -Id 'storage-autoscale' -Title 'Enable storage auto-scaling' -Scope $scope -Tier 'Enriched' `
                    -CurrentState ("Share is provisioned at {0:N0} GiB but uses {1:N0} GiB." -f $enriched.provisionedGib, $enriched.usedGib) `
                    -Recommendation 'Enable Azure Files auto-scale in NME so provisioned capacity tracks actual usage plus headroom.' `
                    -MonthlyLow ([math]::Round($m * [double]$Ctx.assum.conservativeFactor, 2)) -MonthlyTypical $m `
                    -Assumptions @(("Reclaimable = provisioned - used x {0:N1} headroom." -f $headroom))))
                continue
            }
        }
        $plays.Add((New-CostPlay -Id 'storage-autoscale' -Title 'Enable storage auto-scaling' -Scope $scope -Tier 'Manual' `
            -CurrentState ("FSLogix share \\{0}\{1} does not have NME storage auto-scale enabled (or is not onboarded to NME storage management)." -f $loc.account, $loc.share) `
            -Recommendation 'Onboard the share to NME storage management and enable auto-scale: provisioned size then tracks demand instead of being manually over-provisioned.' `
            -MonthlyLow $null -MonthlyTypical $null `
            -Assumptions @('Savings depend on current over-provisioning - check provisioned vs used capacity in the Azure portal or enable Azure enrichment.')))
    }
    return $plays.ToArray()
}

function Get-NmeCostTotals {
    param([array]$Plays, [psobject]$Assumptions)
    $low = 0.0; $typical = 0.0; $count = 0; $overlap = $false
    foreach ($p in @($Plays)) {
        if (-not $p.quantified) { continue }
        $count++
        if ($p.dependsOn -and $p.dependsOn.Count -gt 0) {
            # Interacting play: count only its conservative figure to avoid double-counting.
            $low += [double]$p.monthlyLow
            $typical += [double]$p.monthlyLow
            $overlap = $true
        } else {
            $low += [double]$p.monthlyLow
            $typical += [double]$p.monthlyTypical
        }
    }
    [pscustomobject]@{
        monthlyLow = [math]::Round($low, 2); monthlyTypical = [math]::Round($typical, 2)
        annualLow = [math]::Round($low * 12, 2); annualTypical = [math]::Round($typical * 12, 2)
        quantifiedPlays = $count
        overlapNote = if ($overlap) { 'Interacting plays (e.g. disk savings that rely on auto-scale deallocating hosts) contribute only their conservative figure to the total, to avoid double counting.' } else { '' }
    }
}

function Get-NmeCostAnalysis {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][psobject]$Environment,
        [psobject]$Assumptions = (Get-Content (Join-Path $PSScriptRoot '..\..\config\cost-assumptions.json') -Raw | ConvertFrom-Json),
        [psobject]$Observed,
        [psobject]$Enrichment,
        [hashtable]$PricingCache
    )
    if (-not $PricingCache) { $PricingCache = Get-NmePricingCache }
    $currency = "$($Assumptions.currency)"
    $ttlDays = [int]$Assumptions.pricing.cacheTtlDays
    $weeksPerMonth = 4.345
    $hoursActive = [double]$Assumptions.workingHours.hoursPerDay * [double]$Assumptions.workingHours.daysPerWeek * $weeksPerMonth
    $hoursOff = [double]$Assumptions.hoursPerMonth - $hoursActive

    $ctx = @{
        assum = $Assumptions; observed = $Observed; enrichment = $Enrichment
        cache = $PricingCache; currency = $currency; ttlDays = $ttlDays
        hoursActive = $hoursActive; hoursOff = $hoursOff
        rates = @{}; regions = @{}
    }

    # Resolve region + compute rate per pool once.
    $regions = [System.Collections.Generic.HashSet[string]]::new()
    foreach ($hp in @($Environment.hostPools)) {
        $name = $hp.ref.name
        $region = Get-NmePoolRegion -HostPool $hp -Environment $Environment
        $ctx.regions[$name] = $region
        [void]$regions.Add($region)
        $ctx.rates[$name] = Get-NmePoolComputeRate -HostPool $hp -Region $region -Cache $PricingCache -Assumptions $Assumptions -Currency $currency -TtlDays $ttlDays
    }
    $ctx.defaultRegion = if ($regions.Count -gt 0) { @($regions)[0] } else { 'eastus' }

    $plays = [System.Collections.Generic.List[object]]::new()
    foreach ($hp in @($Environment.hostPools)) {
        $pooled = Test-NmeIsPooled -HostPool $hp
        $p1 = Measure-AutoScaleBaseCapacity -HostPool $hp -Pooled $pooled -Ctx $ctx
        if ($p1) { $plays.Add($p1) }
        $dependsOn = @()
        if ($p1 -and $p1.quantified) { $dependsOn = @('autoscale-base-capacity') }
        $p2 = Measure-PreStageOptimisation -HostPool $hp -Pooled $pooled -Ctx $ctx
        if ($p2) { $plays.Add($p2) }
        $p3 = Measure-RollingDrainMode -HostPool $hp -Pooled $pooled -Ctx $ctx
        if ($p3) { $plays.Add($p3) }
        $p4 = Measure-StoppedDiskTiering -HostPool $hp -Pooled $pooled -Ctx $ctx -DependsOn $dependsOn
        if ($p4) { $plays.Add($p4) }
        $p5 = Measure-OsDiskRightTiering -HostPool $hp -Pooled $pooled -Ctx $ctx -DependsOn @()
        if ($p5) { $plays.Add($p5) }
    }
    $p6 = Measure-VmRightsizing -Environment $Environment -Ctx $ctx
    if ($p6) { $plays.Add($p6) }
    $p7 = Measure-LawCounterOptimisation -Environment $Environment -Ctx $ctx
    if ($p7) { $plays.Add($p7) }
    foreach ($p8 in @(Measure-StorageAutoScaling -Environment $Environment -Ctx $ctx)) { $plays.Add($p8) }
    $p9 = Measure-CommitDiscount -Environment $Environment -Ctx $ctx
    if ($p9) { $plays.Add($p9) }

    # Realised value (Tier 1): auto-scale savings already delivered, shown separately from opportunity.
    $realised = $null
    if ($Observed) {
        $envSav = $null
        if ($Observed.environment -and $Observed.environment.autoScaleSavings -and $Observed.environment.autoScaleSavings.amount) {
            $envSav = $Observed.environment.autoScaleSavings
        }
        $poolSavs = @()
        if ($Observed.hostPools) { $poolSavs = @($Observed.hostPools | Where-Object { $_.autoScaleSavings.amount }) }
        if ($envSav -or $poolSavs.Count -gt 0) {
            $realised = [pscustomobject]@{
                environment = $envSav
                hostPools = $poolSavs
                period = "$($Observed.period)"
                capturedAt = "$($Observed.capturedAt)"
            }
        }
    }

    $tiers = [System.Collections.Generic.HashSet[string]]::new()
    foreach ($p in $plays) { [void]$tiers.Add($p.tier) }

    [pscustomobject]@{
        generatedAt = (Get-Date).ToString('o')
        currency = $currency
        regions = @($regions)
        hybridBenefit = ($Assumptions.hybridBenefit -eq $true)
        workingHoursNote = ("Assumed business window: {0}h x {1} days/week (~{2:N0} active hours/month)." -f $Assumptions.workingHours.hoursPerDay, $Assumptions.workingHours.daysPerWeek, $hoursActive)
        tiersPresent = @($tiers)
        plays = $plays.ToArray()
        realised = $realised
        totals = Get-NmeCostTotals -Plays $plays.ToArray() -Assumptions $Assumptions
        screenshots = if ($Observed -and $Observed.screenshots) { @($Observed.screenshots) } else { @() }
    }
}
