<#
.SYNOPSIS
  Phase 2 rules engine — evaluate a collected NME environment against best practice.
.DESCRIPTION
  Pure functions: take the environment object (from Get-NmeEnvironment) plus the
  rules config, return findings. No API calls, no writes. Thresholds and reference
  links come from config/rules.json so they can be tuned without code changes.

  Severities:
    Required     - supportability/security must-fix
    Recommended  - strong best-practice alignment
    Optional     - nice-to-have / stretch
    Pass         - check passed (good news to show the customer)
    Manual       - not assessable via REST API; review in the console
    Info         - context, no action
#>

function New-Finding {
    param(
        [string]$Id, [string]$Area, [string]$Severity, [string]$Scope,
        [string]$Title, [string]$Observation, [string]$Recommendation,
        [string]$Rationale, [string]$Reference, $Observed
    )
    [pscustomobject]@{
        id = $Id; area = $Area; severity = $Severity; scope = $Scope
        title = $Title; observation = $Observation; recommendation = $Recommendation
        rationale = $Rationale; reference = $Reference; observed = $Observed
    }
}

function Test-NmeIsPooled {
    param($HostPool)
    # assignmentType is often blank via the API; load balancer is the reliable signal.
    # Pooled pools use BreadthFirst/DepthFirst; personal pools use Persistent.
    $lb = $HostPool.wvd.loadBalancerType
    if ($lb -in 'BreadthFirst', 'DepthFirst') { return $true }
    if ($HostPool.autoScale.isSingleUserDesktop -eq $true) { return $false }
    return ($lb -ne 'Persistent')
}

function Get-NmeFindings {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][psobject]$Environment,
        [psobject]$Rules = (Get-Content (Join-Path $PSScriptRoot '..\config\rules.json') -Raw | ConvertFrom-Json)
    )
    $f = [System.Collections.Generic.List[object]]::new()
    $env = $Environment
    $edition = "$($env.deployment.productEdition)"
    $isPremium = $edition -match 'Premium'

    # ---------- Environment: version & edition ----------
    $ver = $env.deployment.deployedVersion
    $latest = $Rules.version.knownLatestVersion
    if ($latest) {
        if ($ver -eq $latest) {
            $f.Add((New-Finding -Id 'env-version' -Area 'Version & Supportability' -Severity 'Pass' -Scope 'Environment' `
                -Title 'NME version current' -Observation "Running $ver (latest known)." `
                -Recommendation 'No action.' -Rationale 'On the current release; within supported window.' -Reference $Rules.version.ref -Observed $ver))
        } else {
            $f.Add((New-Finding -Id 'env-version' -Area 'Version & Supportability' -Severity 'Recommended' -Scope 'Environment' `
                -Title 'NME update available' -Observation "Running $ver; latest known is $latest." `
                -Recommendation "Plan an update to $latest. Stay within current and prior version (N/N-1) for support." `
                -Rationale 'Outside N/N-1 falls out of Nerdio support and misses security/feature updates.' -Reference $Rules.version.ref -Observed $ver))
        }
    } else {
        $f.Add((New-Finding -Id 'env-version' -Area 'Version & Supportability' -Severity 'Info' -Scope 'Environment' `
            -Title 'NME version' -Observation "Running $ver. Edition: $edition." `
            -Recommendation 'Set knownLatestVersion in rules.json to enable the N/N-1 supportability check.' `
            -Rationale 'Customers should stay within current and prior version (N/N-1) for support.' -Reference $Rules.version.ref -Observed $ver))
    }
    $f.Add((New-Finding -Id 'env-edition' -Area 'Version & Supportability' -Severity 'Info' -Scope 'Environment' `
        -Title 'Product edition' -Observation "Edition: $edition." `
        -Recommendation '' -Rationale 'Premium-only checks (stopped-disk cost, LAW, advanced auto-scale) apply only on Premium.' -Reference '' -Observed $edition))

    # ---------- Per host pool ----------
    foreach ($hp in $env.hostPools) {
        $name = $hp.ref.name
        $pooled = Test-NmeIsPooled -HostPool $hp
        $as = $hp.autoScale

        # Auto-scale enabled (pooled)
        if ($pooled -and $Rules.autoScale.requireEnabledForPooled) {
            if ($as.isEnabled -ne $true) {
                $f.Add((New-Finding -Id 'hp-autoscale-off' -Area 'Auto-Scale' -Severity 'Required' -Scope $name `
                    -Title 'Auto-scale disabled' -Observation "Auto-scale is OFF on pooled host pool '$name'." `
                    -Recommendation 'Enable dynamic auto-scale to right-size compute and control spend.' `
                    -Rationale 'Without auto-scale, hosts run 24x7 regardless of demand - the primary source of AVD overspend.' -Reference $Rules.autoScale.ref -Observed $as.isEnabled))
            } else {
                $f.Add((New-Finding -Id 'hp-autoscale-on' -Area 'Auto-Scale' -Severity 'Pass' -Scope $name `
                    -Title 'Auto-scale enabled' -Observation "Auto-scale is ON for '$name'." `
                    -Recommendation 'No action.' -Rationale 'Compute scales to demand.' -Reference $Rules.autoScale.ref -Observed $as.isEnabled))
            }
        }

        # Auto-heal
        if ($Rules.autoScale.requireAutoHeal) {
            if ($as.autoHeal.enable -ne $true) {
                $f.Add((New-Finding -Id 'hp-autoheal-off' -Area 'Auto-Scale' -Severity 'Recommended' -Scope $name `
                    -Title 'Auto-heal disabled' -Observation "Auto-heal broken hosts is OFF on '$name'." `
                    -Recommendation 'Enable Auto-Heal with a sensible action ladder (Restart Agent -> Restart VM -> Reinstall Agent -> Recreate). On personal pools drop the final Delete/Recreate action.' `
                    -Rationale 'Auto-heal recovers failed hosts without manual intervention, reducing downtime.' -Reference $Rules.hostPool.refAutoHeal -Observed $as.autoHeal.enable))
            } else {
                $f.Add((New-Finding -Id 'hp-autoheal-on' -Area 'Auto-Scale' -Severity 'Pass' -Scope $name `
                    -Title 'Auto-heal enabled' -Observation "Auto-heal is ON for '$name'." `
                    -Recommendation 'No action.' -Rationale 'Failed hosts recover automatically.' -Reference $Rules.hostPool.refAutoHeal -Observed $as.autoHeal.enable))
            }
        }

        # Session time limits
        if ($Rules.hostPool.recommendSessionTimeLimits -and $hp.sessionTimeout.isSessionTimeoutsEnabled -ne $true) {
            $f.Add((New-Finding -Id 'hp-session-limits' -Area 'Host Pool Configuration' -Severity 'Recommended' -Scope $name `
                -Title 'Session time limits not set' -Observation "Session time limits are not configured on '$name'." `
                -Recommendation 'Configure session time limits (NME or GPO) to log off idle/disconnected sessions.' `
                -Rationale 'Frees sessions so hosts can scale in faster - cost saving plus a security benefit.' -Reference $Rules.hostPool.refSessionLimits -Observed $hp.sessionTimeout.isSessionTimeoutsEnabled))
        }

        # Scheduled AVD agent update
        if ($Rules.hostPool.recommendScheduledAgentUpdate -and "$($hp.wvd.agentUpdate.type)" -eq $Rules.hostPool.agentUpdateDefaultType) {
            $f.Add((New-Finding -Id 'hp-agent-update' -Area 'Host Pool Configuration' -Severity 'Recommended' -Scope $name `
                -Title 'AVD agent update not scheduled' -Observation "Host pool '$name' uses default (unscheduled) AVD agent updates." `
                -Recommendation 'Set a scheduled maintenance window for AVD agent updates.' `
                -Rationale 'Controls when Microsoft agent flighting lands, and gives a window to apply OS/app/agent updates predictably.' -Reference $Rules.hostPool.refAgentUpdate -Observed $hp.wvd.agentUpdate.type))
        }

        # FSLogix (pooled)
        if ($pooled -and $Rules.hostPool.requireFslogixForPooled -and $hp.fslogix.enable -ne $true) {
            $f.Add((New-Finding -Id 'hp-fslogix-off' -Area 'Host Pool Configuration' -Severity 'Required' -Scope $name `
                -Title 'FSLogix not enabled' -Observation "FSLogix profile management is not enabled on pooled host pool '$name'." `
                -Recommendation 'Enable an FSLogix profile and manage the FSLogix version.' `
                -Rationale 'Pooled multi-session needs roaming profiles; without FSLogix users get a fresh local profile each logon.' -Reference '' -Observed $hp.fslogix.enable))
        }

        # Validation environment flagged in production
        if ($Rules.autoScale.flagValidationEnvInProduction -and $hp.wvd.validationEnv -eq $true) {
            $f.Add((New-Finding -Id 'hp-validation-env' -Area 'Host Pool Configuration' -Severity 'Recommended' -Scope $name `
                -Title 'Validation environment flag set' -Observation "Host pool '$name' is flagged as a validation environment." `
                -Recommendation 'Confirm this is a test pool. Validation pools receive service updates early and should not carry production users.' `
                -Rationale 'Validation pools get Microsoft service updates before GA - fine for testing, risky in production.' -Reference $Rules.hostPool.refValidationEnv -Observed $hp.wvd.validationEnv))
        }

        # Friendly name
        if ($Rules.hostPool.recommendFriendlyName) {
            $fn = "$($hp.wvd.friendlyName)".Trim()
            if (-not $fn -or $fn -eq $name) {
                $f.Add((New-Finding -Id 'hp-friendly-name' -Area 'Host Pool Configuration' -Severity 'Optional' -Scope $name `
                    -Title 'Friendly name not user-facing' -Observation "Host pool '$name' has no distinct friendly name (shows the internal pool name to users)." `
                    -Recommendation 'Set a friendly name that means something to end users.' `
                    -Rationale 'The friendly name is what users see in their AVD client.' -Reference '' -Observed $fn))
            }
        }

        # Stopped OS disk cost (Premium)
        if ($isPremium -and "$($as.stoppedDiskType)" -and $as.stoppedDiskType -in $Rules.autoScale.premiumStoppedDiskCostlyTypes) {
            $f.Add((New-Finding -Id 'hp-stopped-disk' -Area 'Auto-Scale' -Severity 'Optional' -Scope $name `
                -Title 'Costly stopped-disk type' -Observation "Stopped OS disk type on '$name' is $($as.stoppedDiskType)." `
                -Recommendation 'Switch the stopped (deallocated) OS disk to Standard/StandardSSD to cut storage cost while VMs are off.' `
                -Rationale 'A less performant disk while a VM is powered off has no user impact and reduces standing storage cost.' -Reference $Rules.autoScale.ref -Observed $as.stoppedDiskType))
        }

        # Pre-stage hosts (only meaningful on pooled pools with auto-scale on)
        if ($Rules.hostPool.recommendPreStage -and $pooled -and $as.isEnabled -eq $true -and $as.preStageHosts.enable -ne $true) {
            $f.Add((New-Finding -Id 'hp-prestage' -Area 'Auto-Scale' -Severity 'Optional' -Scope $name `
                -Title 'Pre-staging not configured' -Observation "Pre-stage hosts is off on '$name'." `
                -Recommendation 'Consider pre-staging hosts ahead of known peaks so capacity is online before a logon storm.' `
                -Rationale 'Pre-staged hosts improve login performance at shift start; idle ones scale back in via auto-scale logic.' -Reference $Rules.hostPool.refPreStage -Observed $as.preStageHosts.enable))
        }

        # Availability zones (resilience)
        if ($Rules.hostPool.recommendAvailabilityZones -and $hp.vmDeployment.useAvailabilityZones -ne $true) {
            $f.Add((New-Finding -Id 'hp-avail-zones' -Area 'Host Pool Configuration' -Severity 'Optional' -Scope $name `
                -Title 'Availability zones not used' -Observation "Host pool '$name' does not spread hosts across availability zones." `
                -Recommendation 'Enable availability zones for the host pool where the region supports them.' `
                -Rationale 'Spreading session hosts across zones improves resilience to a single-zone outage.' -Reference $Rules.hostPool.refAvailabilityZones -Observed $hp.vmDeployment.useAvailabilityZones))
        }

        # Time zone redirection (user experience)
        if ($Rules.hostPool.recommendTimezoneRedirection -and $hp.vmDeployment.enableTimezoneRedirection -ne $true) {
            $f.Add((New-Finding -Id 'hp-tz-redirect' -Area 'Host Pool Configuration' -Severity 'Optional' -Scope $name `
                -Title 'Time zone redirection off' -Observation "Time zone redirection is not enabled on '$name'." `
                -Recommendation 'Enable time zone redirection so sessions follow the user''s local time zone.' `
                -Rationale 'Without it, multi-session hosts show the host time zone, not the user''s - a common UX complaint.' -Reference '' -Observed $hp.vmDeployment.enableTimezoneRedirection))
        }

        # Personal-pool auto-heal that deletes/recreates VMs
        if ($Rules.hostPool.flagPersonalAutoHealDeleteVm -and -not $pooled -and $as.autoHeal.enable -eq $true) {
            $delActions = @($as.autoHeal.config.actions | Where-Object { "$($_.type)" -in 'RemoveVm', 'DeleteVm', 'RecreateVm' })
            if ($delActions.Count -gt 0) {
                $f.Add((New-Finding -Id 'hp-autoheal-delete-personal' -Area 'Auto-Scale' -Severity 'Recommended' -Scope $name `
                    -Title 'Auto-heal deletes VMs on a personal pool' -Observation "Personal host pool '$name' has an auto-heal action that deletes/recreates the VM." `
                    -Recommendation 'Remove the Delete/Recreate VM action on personal pools - recreation wipes the user''s persistent desktop.' `
                    -Rationale 'Personal desktops are persistent; auto-recreating a broken host destroys user data.' -Reference $Rules.hostPool.refAutoHeal -Observed ($delActions.type -join ',')))
            }
        }

        # RDP Shortpath state (informational)
        if ($Rules.hostPool.reportShortpath -and $null -ne $hp.vmDeployment.rdpShortpath) {
            $f.Add((New-Finding -Id 'hp-shortpath' -Area 'Host Pool Configuration' -Severity 'Info' -Scope $name `
                -Title 'RDP Shortpath' -Observation "RDP Shortpath on '$name': $($hp.vmDeployment.rdpShortpath)." `
                -Recommendation 'If Shortpath is in use, ensure the required firewall/UDP rules are in place (Microsoft scope).' `
                -Rationale 'Shortpath improves connection quality over UDP; it depends on customer network/firewall configuration.' -Reference $Rules.hostPool.refShortpath -Observed $hp.vmDeployment.rdpShortpath))
        }
    }

    # ---------- Images ----------
    foreach ($im in $env.desktopImages) {
        if ($Rules.image.recommendOsDiskOptimization -and [string]::IsNullOrWhiteSpace("$($im.osDiskPerformanceTier)")) {
            $f.Add((New-Finding -Id 'img-osdisk-opt' -Area 'Image & Application Management' -Severity 'Optional' -Scope "$($im.name)" `
                -Title 'OS disk optimisation not set' -Observation "Desktop image '$($im.name)' has no OS disk performance tier configured." `
                -Recommendation 'Configure OS Disk Optimization on the desktop image for a small additional cost saving.' `
                -Rationale 'Right-sizing the image OS disk tier trims cost with no operational impact.' -Reference $Rules.image.ref -Observed $im.osDiskPerformanceTier))
        }
    }
    if ($Rules.image.recommendComputeGallery -and $env.desktopImages.Count -gt 0) {
        $f.Add((New-Finding -Id 'img-acg' -Area 'Image & Application Management' -Severity 'Optional' -Scope 'Environment' `
            -Title 'Verify Azure Compute Gallery + version limit' -Observation "$($env.desktopImages.Count) desktop image(s) present." `
            -Recommendation 'Save images to an Azure Compute Gallery and set a version limit so old versions are pruned automatically; enables multi-region spin-up.' `
            -Rationale 'ACG gives versioning and cross-region reuse without manual portal cleanup.' -Reference $Rules.image.ref -Observed $env.desktopImages.Count))
    }

    # ---------- App delivery posture ----------
    $appBits = $env.appPolicyRecurrent.Count + $env.appPolicyOnetime.Count + $env.shellApps.Count + $env.appAttachImages.Count
    if ($appBits -gt 0) {
        $f.Add((New-Finding -Id 'app-delivery' -Area 'Image & Application Management' -Severity 'Info' -Scope 'Environment' `
            -Title 'Application delivery in use' -Observation "UAM policies: $($env.appPolicyRecurrent.Count) recurrent / $($env.appPolicyOnetime.Count) one-time; repositories: $($env.appRepositories.Count); Shell Apps: $($env.shellApps.Count); App-Attach images: $($env.appAttachImages.Count)." `
            -Recommendation 'Review deployment policies keep key apps current; confirm the mix (UAM/Shell Apps/App-Attach) matches the app strategy.' `
            -Rationale 'Managed app delivery reduces image rebuilds and configuration drift.' -Reference $Rules.appDelivery.ref -Observed $appBits))
    } elseif ($Rules.appDelivery.recommendIfAbsent) {
        $f.Add((New-Finding -Id 'app-delivery-absent' -Area 'Image & Application Management' -Severity 'Optional' -Scope 'Environment' `
            -Title 'No managed app delivery configured' -Observation 'No UAM policies, Shell Apps or App-Attach images found.' `
            -Recommendation 'Consider Unified Application Management (UAM) with deployment policies to keep apps current without rebuilding images.' `
            -Rationale 'Managed app delivery reduces update effort and configuration drift.' -Reference $Rules.appDelivery.ref -Observed 0))
    }

    # ---------- FSLogix storage auto-scaling ----------
    if ($Rules.storage.recommendAzureFilesAutoScale) {
        foreach ($loc in @($env.storageLocations)) {
            $pools = ($loc.hostPools -join ', ')
            if ($loc.type -eq 'AzureFiles') {
                if ($loc.resolved -and $loc.isEnabled -eq $true) {
                    $f.Add((New-Finding -Id 'storage-autoscale-on' -Area 'Storage' -Severity 'Pass' -Scope "$($loc.account)/$($loc.share)" `
                        -Title 'Azure Files auto-scale enabled' -Observation "Storage auto-scale is ON for \\$($loc.account)\$($loc.share) (used by: $pools)." `
                        -Recommendation 'No action.' -Rationale 'Share scales with demand, avoiding quota exhaustion and over-provisioning.' -Reference $Rules.storage.ref -Observed $true))
                } elseif ($loc.resolved -and $loc.isEnabled -ne $true) {
                    $f.Add((New-Finding -Id 'storage-autoscale-off' -Area 'Storage' -Severity 'Recommended' -Scope "$($loc.account)/$($loc.share)" `
                        -Title 'Azure Files auto-scale disabled' -Observation "FSLogix profiles on \\$($loc.account)\$($loc.share) (used by: $pools); storage auto-scale is OFF." `
                        -Recommendation 'Enable Azure Files auto-scale so the share grows/shrinks with demand.' `
                        -Rationale 'Avoids profile-share quota exhaustion (logon failures) while controlling cost.' -Reference $Rules.storage.ref -Observed $false))
                } else {
                    $f.Add((New-Finding -Id 'storage-autoscale-verify' -Area 'Storage' -Severity 'Manual' -Scope "$($loc.account)/$($loc.share)" `
                        -Title 'Verify Azure Files auto-scale' -Observation "FSLogix profiles on Azure Files \\$($loc.account)\$($loc.share) (used by: $pools). Auto-scale state could not be read via the API (share may not be onboarded to NME storage management)." `
                        -Recommendation 'In NME, add this share to storage management and enable auto-scale (Premium).' `
                        -Rationale 'Auto-scale avoids profile-share quota exhaustion and controls cost.' -Reference $Rules.storage.ref -Observed $null))
                }
            } elseif ($loc.type -eq 'Other' -and $loc.account) {
                $f.Add((New-Finding -Id 'storage-non-azurefiles' -Area 'Storage' -Severity 'Info' -Scope "$($loc.account)/$($loc.share)" `
                    -Title 'FSLogix on non-Azure-Files storage' -Observation "FSLogix profiles on \\$($loc.account)\$($loc.share) (used by: $pools) - not Azure Files (could be ANF, on-prem or other)." `
                    -Recommendation 'If this is Azure NetApp Files, review ANF volume auto-scale; otherwise confirm the storage scales for the user base.' `
                    -Rationale 'Profile storage must scale with demand regardless of platform.' -Reference $Rules.storage.ref -Observed $loc.type))
            }
        }
    }

    # ---------- Notifications ----------
    if ($Rules.notifications.recommendConfigured) {
        $hasNotif = ($env.notifActions.Count + $env.notifConditions.Count + $env.notifWebhooks.Count) -gt 0
        if ($hasNotif) {
            $f.Add((New-Finding -Id 'notif-configured' -Area 'Notifications' -Severity 'Pass' -Scope 'Environment' `
                -Title 'Notifications configured' -Observation "Notification actions/conditions/webhooks present." `
                -Recommendation 'No action.' -Rationale 'Failure events surface proactively.' -Reference $Rules.notifications.ref -Observed $true))
        } else {
            $f.Add((New-Finding -Id 'notif-missing' -Area 'Notifications' -Severity 'Manual' -Scope 'Environment' `
                -Title 'Notifications not retrievable' -Observation 'No notification config returned (endpoint unavailable on this deployment or none configured).' `
                -Recommendation 'In NME, configure notifications for failed events and new-version alerts; optionally webhook to a Teams channel.' `
                -Rationale 'Real-time awareness of failures/versioning; can feed ITSM.' -Reference $Rules.notifications.ref -Observed $false))
        }
    }

    # ---------- RBAC ----------
    $f.Add((New-Finding -Id 'rbac-inventory' -Area 'RBAC' -Severity 'Info' -Scope 'Environment' `
        -Title 'Role assignments' -Observation "$($env.roleAssignments.Count) role assignment(s) configured." `
        -Recommendation 'Review for least privilege; use built-in Help Desk / End User roles, add custom roles only where needed.' `
        -Rationale 'Appropriate permissions maintain security and auditability.' -Reference '' -Observed $env.roleAssignments.Count))

    # ---------- Named users vs MAU ----------
    $u = $env.workspaceUsage
    if ($u) {
        $mauTxt = if ($null -ne $u.monthlyActiveUsers) { $u.monthlyActiveUsers } else { 'not available' }
        $f.Add((New-Finding -Id 'usage-named-mau' -Area 'Nerdio Insights' -Severity 'Info' -Scope 'Environment' `
            -Title 'Named users vs MAU' -Observation "Named users: $($u.namedUsers); concurrent: $($u.concurentUsers); MAU: $mauTxt." `
            -Recommendation 'If named-user count far exceeds MAU, explore enabling more users on AVD (expansion). Confirm MAU in Insights.' `
            -Rationale 'A large named-vs-active gap signals adoption headroom.' -Reference '' -Observed $u))
    }

    # ---------- Manual checks (telemetry not in REST API) ----------
    foreach ($m in $Rules.manualChecks) {
        $f.Add((New-Finding -Id $m.id -Area $m.area -Severity 'Manual' -Scope 'Environment' `
            -Title $m.title -Observation 'Not assessable via the REST API.' `
            -Recommendation $m.note -Rationale 'Telemetry/visual data the NME REST API does not expose.' -Reference $m.ref -Observed $null))
    }

    return $f.ToArray()
}

function Get-NmeHealthScore {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][array]$Findings,
        [Parameter(Mandatory)][psobject]$Environment,
        [psobject]$Rules = (Get-Content (Join-Path $PSScriptRoot '..\config\rules.json') -Raw | ConvertFrom-Json)
    )
    $sc = $Rules.score
    $summary = Get-NmeFindingSummary -Findings $Findings
    $penalty = ($summary.Required * $sc.weights.Required) +
               ($summary.Recommended * $sc.weights.Recommended) +
               ($summary.Optional * $sc.weights.Optional)
    # Normalise to estate size so a larger environment is not unfairly penalised.
    $pools = [math]::Max(1, [int]$Environment.hostPools.Count)
    $perPool = $penalty / $pools
    $score = [math]::Round(100 - ($perPool * $sc.deductionPerUnit))
    $score = [math]::Max(0, [math]::Min(100, $score))

    $grade = $sc.grades | Where-Object { $score -ge $_.min } | Select-Object -First 1

    [pscustomobject]@{
        score    = [int]$score
        label    = $grade.label
        color    = $grade.color
        penalty  = [math]::Round($penalty, 1)
        perPool  = [math]::Round($perPool, 1)
        required = $summary.Required
        recommended = $summary.Recommended
        optional = $summary.Optional
    }
}

function Get-NmeFindingSummary {
    param([Parameter(Mandatory)][array]$Findings)
    $order = 'Required', 'Recommended', 'Optional', 'Manual', 'Pass', 'Info'
    $counts = [ordered]@{}
    foreach ($s in $order) { $counts[$s] = ($Findings | Where-Object severity -eq $s).Count }
    [pscustomobject]$counts
}
