<#
.SYNOPSIS
  Azure Retail Prices API client with a local region-keyed cache.
.DESCRIPTION
  Public API (no auth): https://prices.azure.com/api/retail/prices
  Provides VM hourly rates (base/Linux = AHB rate, plus Windows PAYG),
  managed-disk monthly rates (P/E/S tiers) and Log Analytics per-GB ingestion.
  All lookups go through the cache (config/pricing-cache.json, TTL in
  cost-assumptions.json) so repeat runs are fast and -FromFile runs can work
  offline once the cache is warm. Hard fallback rates from the assumptions
  file are used as a last resort and flagged in the result ('source').
#>

function Get-AzureRetailPrice {
    <# Raw pager. Returns an array of price items for an OData filter. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Filter,
        [string]$Currency = 'USD',
        [int]$MaxPages = 10,
        [string]$ApiVersion   # e.g. '2023-01-01-preview' to expose the savingsPlan field
    )
    $items = [System.Collections.Generic.List[object]]::new()
    $verParam = if ($ApiVersion) { "api-version=$ApiVersion&" } else { '' }
    $url = "https://prices.azure.com/api/retail/prices?$($verParam)currencyCode=$Currency&`$filter=$([uri]::EscapeDataString($Filter))"
    $page = 0
    while ($url -and $page -lt $MaxPages) {
        $page++
        try {
            $resp = Invoke-RestMethod -Uri $url -Method GET -TimeoutSec 30
        } catch {
            Write-Warning "Retail Prices API call failed: $($_.Exception.Message)"
            return $items.ToArray()
        }
        foreach ($i in @($resp.Items)) { $items.Add($i) }
        $url = $resp.NextPageLink
    }
    return $items.ToArray()
}

function Get-NmePricingCache {
    [CmdletBinding()]
    param([string]$Path = (Join-Path $PSScriptRoot '..\..\config\pricing-cache.json'))
    $cache = @{ path = $Path; entries = @{}; dirty = $false }
    if (Test-Path $Path) {
        try {
            $raw = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
            foreach ($p in $raw.entries.PSObject.Properties) { $cache.entries[$p.Name] = $p.Value }
        } catch {
            Write-Warning "Pricing cache unreadable ($($_.Exception.Message)) - starting fresh."
        }
    }
    return $cache
}

function Save-NmePricingCache {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Cache)
    if (-not $Cache.dirty) { return }
    $out = [pscustomobject]@{ savedAt = (Get-Date).ToString('o'); entries = [pscustomobject]$Cache.entries }
    $out | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $Cache.path -Encoding UTF8
    $Cache.dirty = $false
}

function Test-NmeCacheEntryFresh {
    param($Entry, [int]$TtlDays)
    if (-not $Entry -or -not $Entry.fetchedAt) { return $false }
    try { $age = (Get-Date) - [datetime]$Entry.fetchedAt } catch { return $false }
    return ($age.TotalDays -lt $TtlDays)
}

function Get-NmeVmHourlyRate {
    <#
      Returns @{ linuxHr; windowsHr; currency; source; linuxMeter; windowsMeter }.
      linuxHr is the base compute rate (= Windows with Azure Hybrid Benefit).
      Either rate can be $null if the SKU/region combination is not listed.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Region,
        [Parameter(Mandatory)][string]$SkuName,
        [Parameter(Mandatory)][hashtable]$Cache,
        [string]$Currency = 'USD',
        [int]$TtlDays = 7
    )
    $key = "$Currency|$Region|vm|$SkuName"
    if (Test-NmeCacheEntryFresh -Entry $Cache.entries[$key] -TtlDays $TtlDays) {
        $e = $Cache.entries[$key]
        return @{ linuxHr = $e.linuxHr; windowsHr = $e.windowsHr; currency = $Currency; source = 'cache'; linuxMeter = $e.linuxMeter; windowsMeter = $e.windowsMeter }
    }

    $filter = "serviceName eq 'Virtual Machines' and armRegionName eq '$Region' and armSkuName eq '$SkuName' and priceType eq 'Consumption'"
    $items = Get-AzureRetailPrice -Filter $filter -Currency $Currency
    # Drop Spot / Low Priority / DevTest variants.
    $items = @($items | Where-Object { $_.skuName -notmatch 'Spot|Low Priority' -and $_.type -ne 'DevTestConsumption' })

    $win   = @($items | Where-Object { $_.productName -match 'Windows$' }) | Sort-Object retailPrice | Select-Object -First 1
    $linux = @($items | Where-Object { $_.productName -notmatch 'Windows$' }) | Sort-Object retailPrice | Select-Object -First 1

    if (-not $linux -and -not $win) {
        Write-Warning "No retail price found for VM '$SkuName' in '$Region' - compute plays for this size will be skipped."
        return @{ linuxHr = $null; windowsHr = $null; currency = $Currency; source = 'unavailable'; linuxMeter = $null; windowsMeter = $null }
    }

    $entry = [pscustomobject]@{
        fetchedAt    = (Get-Date).ToString('o')
        linuxHr      = if ($linux) { [double]$linux.retailPrice } else { $null }
        windowsHr    = if ($win)   { [double]$win.retailPrice }   else { $null }
        linuxMeter   = if ($linux) { "$($linux.productName) / $($linux.meterName)" } else { $null }
        windowsMeter = if ($win)   { "$($win.productName) / $($win.meterName)" }     else { $null }
    }
    $Cache.entries[$key] = $entry
    $Cache.dirty = $true
    return @{ linuxHr = $entry.linuxHr; windowsHr = $entry.windowsHr; currency = $Currency; source = 'retail-api'; linuxMeter = $entry.linuxMeter; windowsMeter = $entry.windowsMeter }
}

function Get-NmeCommitRate {
    <#
      Committed-use hourly rates for a VM size: pay-as-you-go vs 1-year / 3-year
      Savings Plan (compute). Savings-plan rates are embedded on the base Linux
      Consumption record (the .savingsPlan array), so this is directly comparable
      to the PAYG hourly rate. Returns:
        @{ payg; sp1yr; sp3yr; currency; source }
      Any rate can be $null if unavailable; caller skips the commit play then.
      Reservation (RI) rates track the Savings Plan closely and are surfaced
      separately from Azure Advisor when enrichment is available.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Region,
        [Parameter(Mandatory)][string]$SkuName,
        [Parameter(Mandatory)][hashtable]$Cache,
        [string]$Currency = 'USD',
        [int]$TtlDays = 7
    )
    $key = "$Currency|$Region|commit|$SkuName"
    if (Test-NmeCacheEntryFresh -Entry $Cache.entries[$key] -TtlDays $TtlDays) {
        $e = $Cache.entries[$key]
        return @{ payg = $e.payg; sp1yr = $e.sp1yr; sp3yr = $e.sp3yr; currency = $Currency; source = 'cache' }
    }

    $filter = "serviceName eq 'Virtual Machines' and armRegionName eq '$Region' and armSkuName eq '$SkuName' and priceType eq 'Consumption'"
    # The savingsPlan schedule is only returned by the preview api-version.
    $items = Get-AzureRetailPrice -Filter $filter -Currency $Currency -ApiVersion '2023-01-01-preview'
    $items = @($items | Where-Object { $_.skuName -notmatch 'Spot|Low Priority' -and $_.type -ne 'DevTestConsumption' })
    # Base (Linux/AHB) record carries the compute Savings Plan schedule.
    $base = @($items | Where-Object { $_.productName -notmatch 'Windows$' }) | Sort-Object retailPrice | Select-Object -First 1
    if (-not $base) {
        return @{ payg = $null; sp1yr = $null; sp3yr = $null; currency = $Currency; source = 'unavailable' }
    }

    $sp1 = $null; $sp3 = $null
    foreach ($sp in @($base.savingsPlan)) {
        $term = "$($sp.term)"
        if ($term -match '^1')      { $sp1 = [double]$sp.retailPrice }
        elseif ($term -match '^3')  { $sp3 = [double]$sp.retailPrice }
    }
    $entry = [pscustomobject]@{
        fetchedAt = (Get-Date).ToString('o')
        payg      = [double]$base.retailPrice
        sp1yr     = $sp1
        sp3yr     = $sp3
    }
    $Cache.entries[$key] = $entry
    $Cache.dirty = $true
    return @{ payg = $entry.payg; sp1yr = $entry.sp1yr; sp3yr = $entry.sp3yr; currency = $Currency; source = 'retail-api' }
}

function Get-NmeDiskMonthlyRate {
    <# Monthly price for a managed disk SKU letter+tier, e.g. 'P10', 'E15', 'S20'. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Region,
        [Parameter(Mandatory)][string]$DiskSku,
        [Parameter(Mandatory)][hashtable]$Cache,
        [psobject]$Assumptions,
        [string]$Currency = 'USD',
        [int]$TtlDays = 7
    )
    $key = "$Currency|$Region|disk|$DiskSku"
    if (Test-NmeCacheEntryFresh -Entry $Cache.entries[$key] -TtlDays $TtlDays) {
        $e = $Cache.entries[$key]
        return @{ monthly = $e.monthly; currency = $Currency; source = 'cache'; meter = $e.meter }
    }

    $filter = "serviceName eq 'Storage' and armRegionName eq '$Region' and skuName eq '$DiskSku LRS' and priceType eq 'Consumption'"
    $items = Get-AzureRetailPrice -Filter $filter -Currency $Currency
    $disk = @($items | Where-Object { $_.meterName -eq "$DiskSku LRS Disk" -and $_.productName -match 'Managed Disks' -and $_.unitOfMeasure -match 'Month' }) |
        Sort-Object retailPrice | Select-Object -First 1

    if ($disk) {
        $entry = [pscustomobject]@{
            fetchedAt = (Get-Date).ToString('o')
            monthly   = [double]$disk.retailPrice
            meter     = "$($disk.productName) / $($disk.meterName)"
        }
        $Cache.entries[$key] = $entry
        $Cache.dirty = $true
        return @{ monthly = $entry.monthly; currency = $Currency; source = 'retail-api'; meter = $entry.meter }
    }

    # Fallback table (USD ballpark) - flagged so the report can caveat it.
    $fb = $null
    if ($Assumptions -and $Assumptions.pricing.fallbackRates.diskMonthly.PSObject.Properties[$DiskSku]) {
        $fb = [double]$Assumptions.pricing.fallbackRates.diskMonthly.$DiskSku
    }
    if ($null -ne $fb) {
        Write-Warning "No retail price for disk '$DiskSku' in '$Region' - using fallback rate $fb."
        return @{ monthly = $fb; currency = $Currency; source = 'fallback'; meter = "fallback table ($DiskSku)" }
    }
    Write-Warning "No retail price or fallback for disk '$DiskSku' in '$Region'."
    return @{ monthly = $null; currency = $Currency; source = 'unavailable'; meter = $null }
}

function Get-NmeLawIngestionRate {
    <# Per-GB Log Analytics pay-as-you-go ingestion rate. Probes both historic service names. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Region,
        [Parameter(Mandatory)][hashtable]$Cache,
        [psobject]$Assumptions,
        [string]$Currency = 'USD',
        [int]$TtlDays = 7
    )
    $key = "$Currency|$Region|law|ingestion"
    if (Test-NmeCacheEntryFresh -Entry $Cache.entries[$key] -TtlDays $TtlDays) {
        $e = $Cache.entries[$key]
        return @{ perGb = $e.perGb; currency = $Currency; source = 'cache'; meter = $e.meter }
    }

    # Meter naming has changed over time; probe known variants (paid analytics-logs
    # ingestion first, then legacy pay-as-you-go naming). Free/benefit meters are 0.00,
    # so take the highest-priced GB record of the first meter that matches.
    $hit = $null
    $probes = @(
        @{ svc = 'Log Analytics'; meter = 'Analytics Logs Data Ingestion' },
        @{ svc = 'Log Analytics'; meter = 'Pay-as-you-go Data Ingestion' },
        @{ svc = 'Azure Monitor'; meter = 'Pay-as-you-go Data Ingestion' }
    )
    foreach ($p in $probes) {
        $filter = "serviceName eq '$($p.svc)' and armRegionName eq '$Region' and meterName eq '$($p.meter)' and priceType eq 'Consumption'"
        $items = Get-AzureRetailPrice -Filter $filter -Currency $Currency
        $hit = @($items | Where-Object { $_.unitOfMeasure -match 'GB' -and [double]$_.retailPrice -gt 0 }) |
            Sort-Object retailPrice -Descending | Select-Object -First 1
        if ($hit) { break }
    }

    if ($hit) {
        $entry = [pscustomobject]@{
            fetchedAt = (Get-Date).ToString('o')
            perGb     = [double]$hit.retailPrice
            meter     = "$($hit.serviceName) / $($hit.meterName)"
        }
        $Cache.entries[$key] = $entry
        $Cache.dirty = $true
        return @{ perGb = $entry.perGb; currency = $Currency; source = 'retail-api'; meter = $entry.meter }
    }

    $fb = $null
    if ($Assumptions) { $fb = [double]$Assumptions.pricing.fallbackRates.lawIngestionPerGb }
    if ($null -ne $fb -and $fb -gt 0) {
        Write-Warning "No retail price for LAW ingestion in '$Region' - using fallback rate $fb/GB."
        return @{ perGb = $fb; currency = $Currency; source = 'fallback'; meter = 'fallback table' }
    }
    return @{ perGb = $null; currency = $Currency; source = 'unavailable'; meter = $null }
}

function ConvertTo-NmeDiskSku {
    <#
      Map a disk size + storage type to the managed-disk SKU letter+tier.
      Premium_LRS -> P, StandardSSD_LRS -> E, Standard_LRS -> S.
      PremiumV2/UltraSSD are capacity-billed, not tiered - returns $null (caller skips).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][int]$DiskSizeGb,
        [Parameter(Mandatory)][string]$StorageType
    )
    $letter = switch -Regex ($StorageType) {
        '^Premium_LRS$'     { 'P'; break }
        '^StandardSSD_LRS$' { 'E'; break }
        '^Standard_LRS$'    { 'S'; break }
        default             { $null }
    }
    if (-not $letter) { return $null }
    $tier = switch ($DiskSizeGb) {
        { $_ -le 4 }    { 1; break }
        { $_ -le 8 }    { 2; break }
        { $_ -le 16 }   { 3; break }
        { $_ -le 32 }   { 4; break }
        { $_ -le 64 }   { 6; break }
        { $_ -le 128 }  { 10; break }
        { $_ -le 256 }  { 15; break }
        { $_ -le 512 }  { 20; break }
        { $_ -le 1024 } { 30; break }
        { $_ -le 2048 } { 40; break }
        { $_ -le 4096 } { 50; break }
        default         { 60 }
    }
    # Standard SSD/HDD have no tiers below E/S4 in common use; clamp small sizes up.
    if ($letter -ne 'P' -and $tier -lt 4) { $tier = 4 }
    return "$letter$tier"
}
