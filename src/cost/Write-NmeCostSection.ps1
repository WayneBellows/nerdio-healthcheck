<#
.SYNOPSIS
  Renders the Cost Optimisation section as an HTML fragment for the report.
.DESCRIPTION
  Returns a string. Self-contained: brings its own scoped CSS so the main
  report styles are untouched when the section is absent. Relies on
  ConvertTo-HtmlText from Write-NmeReport.ps1 (dot-sourced by the orchestrator).
#>

function Format-NmeMoney {
    param([double]$Value, [string]$Currency = 'USD', [int]$Decimals = 0)
    $sym = switch ($Currency) {
        'USD' { '$' }
        'GBP' { [char]0x00A3 }
        'EUR' { [char]0x20AC }
        default { "$Currency " }
    }
    $fmt = "{0:N$Decimals}"
    return "$sym$($fmt -f $Value)"
}

function Write-NmeCostSection {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][psobject]$CostAnalysis,
        [string]$CustomerName = 'Customer'
    )
    $ca = $CostAnalysis
    $cur = $ca.currency
    $t = $ca.totals

    $tierMeta = @{
        Measured = @{ label = 'MEASURED';        bg = '#ECFDF3'; fg = '#067647'; desc = 'Read from the NME console or the customer''s own telemetry - actual figures, not estimates.' }
        Enriched = @{ label = 'ENRICHED - AZURE'; bg = '#EFF6FF'; fg = '#1D4ED8'; desc = 'Derived from live Azure data (Advisor, Log Analytics, disk inventory) gathered read-only during this assessment.' }
        Modelled = @{ label = 'MODELLED';        bg = '#F1F5F9'; fg = '#475569'; desc = 'Estimated from the current NME configuration and stated assumptions - a starting point for the conversation, not a quote.' }
        Manual   = @{ label = 'REVIEW';          bg = '#FFFAEB'; fg = '#B54708'; desc = 'Opportunity identified but not quantifiable from available data - review together in the console.' }
    }

    $sb = [System.Text.StringBuilder]::new()
    $null = $sb.AppendLine(@"
<style>
  .costbar{display:flex; align-items:center; gap:28px; background:linear-gradient(135deg, var(--ink) 0%, #14455C 100%);
           border-radius:var(--radius-lg); box-shadow:var(--shadow-sm); padding:26px 30px; margin:8px 0 14px; color:#fff;}
  .costbar .big{font-family:var(--font-sans); font-weight:800; font-size:34px; line-height:1.15; color:#fff;}
  .costbar .big .per{font-size:16px; font-weight:600; color:#9FD6E4;}
  .costbar .sub{color:#C9E6EF; font-size:13px; margin-top:8px; max-width:720px; line-height:1.55;}
  .costbar .eyebrow{color:#7FC4D8;}
  .tierlegend{display:flex; gap:14px; flex-wrap:wrap; margin:0 0 22px; font-size:12px; color:var(--slate-500);}
  .tierlegend .tl{display:flex; align-items:center; gap:8px; background:var(--bg-surface); border:1px solid var(--border);
                  border-radius:var(--radius-full); padding:6px 14px 6px 8px;}
  .covnote{border-radius:var(--radius-lg); padding:12px 16px; margin:0 0 22px; font-size:13px; line-height:1.5;
           border:1px solid var(--border); background:var(--bg-surface);}
  .covnote.ok{border-left:4px solid var(--success-500);}
  .covnote.action{border-left:4px solid var(--warning-500); background:#FFFBEB;}
  .covnote .h{font-family:var(--font-sans); font-weight:700; font-size:12px; text-transform:uppercase;
              letter-spacing:0.04em; margin-right:6px;}
  .covnote.action .h{color:#B54708;}
  .realised{display:flex; align-items:center; gap:16px; background:var(--bg-surface); border:1px solid var(--border);
            border-left:4px solid var(--success-500); border-radius:var(--radius-lg); padding:14px 18px; margin:0 0 22px;
            box-shadow:var(--shadow-sm);}
  .realised .rv{font-family:var(--font-sans); font-weight:800; font-size:24px; color:var(--success-500); white-space:nowrap;}
  .realised .rt{font-size:13px; color:var(--slate-600);}
  .play{background:var(--bg-surface); border:1px solid var(--border); border-left-width:4px; border-left-color:var(--teal-500);
        border-radius:var(--radius-lg); padding:16px 18px; margin-bottom:14px; box-shadow:var(--shadow-sm);}
  .play .top{display:flex; align-items:flex-start; justify-content:space-between; gap:12px; margin-bottom:10px;}
  .play h3{font-size:16px; font-weight:600;}
  .play .grid{display:grid; grid-template-columns:1fr 1fr 220px; gap:16px; align-items:start;}
  .play .cell .lab{font-weight:600; color:var(--slate-700); font-family:var(--font-sans); font-size:12px;
                   text-transform:uppercase; letter-spacing:0.03em; display:block; margin-bottom:4px;}
  .play .cell{font-size:14px; color:var(--slate-600);}
  .play .save{font-family:var(--font-sans); font-weight:800; font-size:22px; color:var(--teal-600); line-height:1.2;}
  .play .save .per{font-size:13px; font-weight:600; color:var(--slate-500);}
  .play details{margin-top:12px; font-size:13px; color:var(--slate-500);}
  .play details summary{cursor:pointer; font-family:var(--font-sans); font-weight:600; font-size:12px;
                        color:var(--teal-600); text-transform:uppercase; letter-spacing:0.03em;}
  .play details ul{margin:8px 0 0; padding-left:18px;}
  .play details li{margin-bottom:4px;}
  .play .shots{display:flex; gap:12px; flex-wrap:wrap; margin-top:12px;}
  .play .shots figure{margin:0; max-width:420px;}
  .play .shots img{max-width:100%; border:1px solid var(--border); border-radius:var(--radius-sm); display:block;}
  .play .shots figcaption{font-size:12px; color:var(--slate-500); margin-top:4px;}
  @media (max-width:860px){ .play .grid{grid-template-columns:1fr;} }
  @media print{ .costbar{-webkit-print-color-adjust:exact; print-color-adjust:exact;} .play{box-shadow:none;} }
</style>
<details class="sec" id="sec-cost" open>
<summary><span class="chev">&#9654;</span><h2><span style="display:inline-block;width:12px;height:12px;border-radius:50%;background:var(--teal-500)"></span>Cost Optimisation</h2></summary>
<div class="sd">Potential monthly savings from Nerdio optimisation features, based on the current configuration. Figures are estimates to guide the conversation, not quotes.</div>
"@)

    # ---- Headline banner ----
    $priceNote = "Prices: Azure Retail ($((@($ca.regions) -join ', ')))"
    if ($ca.hybridBenefit) { $priceNote += ' &middot; compute priced assuming Azure Hybrid Benefit' }
    if ($t.quantifiedPlays -gt 0) {
        $rangeTxt = if ([math]::Round($t.monthlyLow) -eq [math]::Round($t.monthlyTypical)) {
            (Format-NmeMoney -Value $t.monthlyTypical -Currency $cur)
        } else {
            "$(Format-NmeMoney -Value $t.monthlyLow -Currency $cur)&ndash;$(Format-NmeMoney -Value $t.monthlyTypical -Currency $cur)"
        }
        $annualTxt = if ([math]::Round($t.annualLow) -eq [math]::Round($t.annualTypical)) {
            (Format-NmeMoney -Value $t.annualTypical -Currency $cur)
        } else {
            "$(Format-NmeMoney -Value $t.annualLow -Currency $cur)&ndash;$(Format-NmeMoney -Value $t.annualTypical -Currency $cur)"
        }
        $overlapHtml = ''
        if ($t.overlapNote) { $overlapHtml = " $(ConvertTo-HtmlText $t.overlapNote)" }
        $null = $sb.AppendLine(@"
<div class="costbar">
  <div>
    <div class="eyebrow">Estimated Savings Opportunity</div>
    <div class="big">$rangeTxt <span class="per">/ month</span>&nbsp;&nbsp;&middot;&nbsp;&nbsp;$annualTxt <span class="per">/ year</span></div>
    <div class="sub">Across $($t.quantifiedPlays) quantified optimisation play$(if ($t.quantifiedPlays -ne 1) {'s'}). $priceNote. $(ConvertTo-HtmlText $ca.workingHoursNote)$overlapHtml</div>
  </div>
</div>
"@)
    } else {
        $null = $sb.AppendLine(@"
<div class="costbar">
  <div>
    <div class="eyebrow">Cost Optimisation Review</div>
    <div class="big">No quantifiable savings identified</div>
    <div class="sub">The environment's savings features are already in use, or the data needed to quantify further opportunity was not available for this run. $priceNote.</div>
  </div>
</div>
"@)
    }

    # ---- Tier legend (only tiers present) ----
    $null = $sb.AppendLine('<div class="tierlegend">')
    foreach ($tk in 'Measured', 'Enriched', 'Modelled', 'Manual') {
        if (@($ca.tiersPresent) -notcontains $tk) { continue }
        $tm = $tierMeta[$tk]
        $null = $sb.AppendLine("  <span class='tl'><span class='badge' style='background:$($tm.bg);color:$($tm.fg)'>$($tm.label)</span>$($tm.desc)</span>")
    }
    $null = $sb.AppendLine('</div>')

    # ---- Reservations / Savings Plan coverage basis ----
    if ($ca.coverage) {
        $cv = $ca.coverage
        $cls = if ($cv.needsManual) { 'action' } else { 'ok' }
        $hdr = if ($cv.needsManual) { 'Action needed' } else { 'Reservations / Savings Plans' }
        $null = $sb.AppendLine("<div class='covnote $cls'><span class='h'>$hdr</span>$(ConvertTo-HtmlText $cv.message)</div>")
    }

    # ---- Realised value strip (Tier 1) ----
    if ($ca.realised) {
        $r = $ca.realised
        $amt = $null; $pct = $null
        if ($r.environment) { $amt = [double]$r.environment.amount; $pct = $r.environment.percent }
        elseif (@($r.hostPools).Count -gt 0) {
            $amt = (@($r.hostPools) | ForEach-Object { [double]$_.autoScaleSavings.amount } | Measure-Object -Sum).Sum
        }
        if ($amt) {
            $pctTxt = if ($pct) { " ($pct% of what the workload would otherwise have cost)" } else { '' }
            $periodTxt = if ($r.period) { " over the period '$(ConvertTo-HtmlText $r.period)'" } else { '' }
            $null = $sb.AppendLine(@"
<div class="realised">
  <div class="rv">$(Format-NmeMoney -Value $amt -Currency $cur) saved</div>
  <div class="rt"><strong>Already being delivered:</strong> Nerdio auto-scale savings recorded in the NME console$periodTxt$pctTxt. The opportunities below are additional to this.</div>
</div>
"@)
        }
    }

    # ---- Play cards: quantified (largest first), then review items ----
    $quantified = @($ca.plays | Where-Object { $_.quantified } | Sort-Object monthlyTypical -Descending)
    $review = @($ca.plays | Where-Object { -not $_.quantified })
    $shots = @($ca.screenshots)

    foreach ($p in ($quantified + $review)) {
        $tm = $tierMeta["$($p.tier)"]
        if (-not $tm) { $tm = $tierMeta.Modelled }
        $badge = "<span class='badge' style='background:$($tm.bg);color:$($tm.fg)'>$($tm.label)</span>"

        if ($p.quantified) {
            $isPoint = ([math]::Round([double]$p.monthlyLow, 0) -eq [math]::Round([double]$p.monthlyTypical, 0))
            $saveTxt = if ($isPoint) { Format-NmeMoney -Value $p.monthlyTypical -Currency $cur }
                       else { "$(Format-NmeMoney -Value $p.monthlyLow -Currency $cur)&ndash;$(Format-NmeMoney -Value $p.monthlyTypical -Currency $cur)" }
            $saveHtml = "<div class='save'>$saveTxt <span class='per'>/ month</span></div>"
        } else {
            $saveHtml = "<div class='save' style='color:var(--slate-500);font-size:15px'>Review together</div>"
        }

        $detailBits = @()
        foreach ($a in @($p.assumptions)) { if ($a) { $detailBits += "<li>$(ConvertTo-HtmlText $a)</li>" } }
        foreach ($e in @($p.evidence))    { if ($e) { $detailBits += "<li><em>$(ConvertTo-HtmlText $e)</em></li>" } }
        $detailsHtml = ''
        if ($detailBits.Count -gt 0) {
            $detailsHtml = "<details><summary>Assumptions &amp; basis</summary><ul>$($detailBits -join '')</ul></details>"
        }

        $shotHtml = ''
        $matched = @($shots | Where-Object { $_.play -eq $p.id -and (-not $_.scope -or $_.scope -eq $p.scope) })
        if ($matched.Count -gt 0) {
            $figs = ($matched | ForEach-Object { "<figure><img src='$($_.dataUri)' alt='$(ConvertTo-HtmlText $_.caption)'><figcaption>$(ConvertTo-HtmlText $_.caption)</figcaption></figure>" }) -join ''
            $shotHtml = "<div class='shots'>$figs</div>"
        }

        $null = $sb.AppendLine(@"
<div class="play">
  <div class="top">
    <div><h3>$(ConvertTo-HtmlText $p.title)</h3><div class="scope">$(ConvertTo-HtmlText $p.scope)</div></div>
    $badge
  </div>
  <div class="grid">
    <div class="cell"><span class="lab">Current state</span>$(ConvertTo-HtmlText $p.currentState)</div>
    <div class="cell"><span class="lab">Recommended change</span>$(ConvertTo-HtmlText $p.recommendation)</div>
    <div class="cell"><span class="lab">Estimated saving</span>$saveHtml</div>
  </div>
  $detailsHtml
  $shotHtml
</div>
"@)
    }

    # Unmatched screenshots -> evidence gallery.
    $unmatched = @($shots | Where-Object { $s = $_; -not (@($ca.plays) | Where-Object { $_.id -eq $s.play }) })
    if ($unmatched.Count -gt 0) {
        $figs = ($unmatched | ForEach-Object { "<figure><img src='$($_.dataUri)' alt='$(ConvertTo-HtmlText $_.caption)'><figcaption>$(ConvertTo-HtmlText $_.caption)</figcaption></figure>" }) -join ''
        $null = $sb.AppendLine("<div class='play'><div class='top'><div><h3>Evidence from the NME console</h3></div></div><div class='shots'>$figs</div></div>")
    }

    $null = $sb.AppendLine(@"
<div class="sd" style="margin:6px 0 0 0">Savings figures are indicative estimates based on Azure retail pricing and the stated assumptions; actual savings depend on usage patterns, reservations/discounts and the customer's Enterprise Agreement rates. They are not a quotation.</div>
</details>
"@)
    return $sb.ToString()
}
