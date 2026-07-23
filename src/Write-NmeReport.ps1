<#
.SYNOPSIS
  Phase 3 — render findings to a self-contained HTML report in the NME design system.
.DESCRIPTION
  Single-file output: design tokens inlined, Nerdio logo base64-embedded, no external
  CSS. Poppins loaded from Google Fonts as progressive enhancement with a system-ui
  fallback so the file still reads correctly offline. Severity badges follow the
  product's ALL-CAPS status-badge convention.
#>

function ConvertTo-HtmlText {
    param([string]$Text)
    if ($null -eq $Text) { return '' }
    $Text.Replace('&', '&amp;').Replace('<', '&lt;').Replace('>', '&gt;').Replace('"', '&quot;')
}

function Get-LogoDataUri {
    param([string]$LogoPath)
    if (-not $LogoPath -or -not (Test-Path $LogoPath)) { return $null }
    $bytes = [System.IO.File]::ReadAllBytes($LogoPath)
    $ext = [System.IO.Path]::GetExtension($LogoPath).TrimStart('.').ToLower()
    $mime = if ($ext -in 'jpg', 'jpeg') { 'image/jpeg' } else { "image/$ext" }
    "data:$mime;base64,$([Convert]::ToBase64String($bytes))"
}

function Write-NmeReport {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][psobject]$Environment,
        [Parameter(Mandatory)][array]$Findings,
        [string]$CustomerName = 'Customer',
        [string]$OutPath,
        [string]$LogoPath,
        [psobject]$CostAnalysis
    )

    # Prefer the vendored logo (self-contained repo); fall back to the design system.
    if (-not $LogoPath) {
        $vendored = Join-Path $PSScriptRoot '..\assets\logos\nme-logo-navy-horz.png'
        $external = Join-Path $PSScriptRoot '..\..\..\NME Design System\assets\logos\nme-logo-navy-horz.png'
        $LogoPath = if (Test-Path $vendored) { $vendored } else { $external }
    }

    $summary = Get-NmeFindingSummary -Findings $Findings
    $health  = Get-NmeHealthScore -Findings $Findings -Environment $Environment
    $dep = $Environment.deployment
    $generated = Get-Date -Format 'dd MMMM yyyy, HH:mm'
    $logo = Get-LogoDataUri -LogoPath $LogoPath

    # severity -> display + colour token
    $sevMeta = [ordered]@{
        Required    = @{ label = 'REQUIRED';    bg = '#FEF3F2'; fg = '#B42318'; dot = '#F04438' }
        Recommended = @{ label = 'RECOMMENDED'; bg = '#FFFAEB'; fg = '#B54708'; dot = '#F59E0B' }
        Optional    = @{ label = 'OPTIONAL';    bg = '#F1F5F9'; fg = '#475569'; dot = '#64748B' }
        Manual      = @{ label = 'MANUAL';      bg = '#EFF6FF'; fg = '#1D4ED8'; dot = '#3B82F6' }
        Pass        = @{ label = 'PASS';        bg = '#ECFDF3'; fg = '#067647'; dot = '#17B26A' }
        Info        = @{ label = 'INFO';        bg = '#F1F5F9'; fg = '#475569'; dot = '#94A3B8' }
    }

    $sb = [System.Text.StringBuilder]::new()
    $null = $sb.AppendLine(@"
<!DOCTYPE html>
<html lang="en-GB">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Nerdio Health Check — $(ConvertTo-HtmlText $CustomerName)</title>
<link rel="preconnect" href="https://fonts.googleapis.com">
<link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
<link href="https://fonts.googleapis.com/css2?family=Poppins:wght@400;500;600;700;800&family=Open+Sans:wght@400;600&display=swap" rel="stylesheet">
<style>
  :root{
    --teal-500:#1E9DB8; --teal-600:#1B8CA4; --teal-700:#156D80; --teal-50:#EDF9FC;
    --ink:#0F2A3A; --navy:#12131A;
    --slate-50:#F8FAFC; --slate-100:#F1F5F9; --slate-200:#E2E8F0; --slate-300:#CBD5E1;
    --slate-500:#64748B; --slate-600:#475569; --slate-700:#334155; --slate-800:#1E293B;
    --success-500:#17B26A; --warning-500:#F59E0B; --error-500:#F04438;
    --bg-surface:#FFFFFF; --bg-app:#F8FAFC; --border:#E2E8F0;
    --radius-lg:10px; --radius-sm:6px; --radius-full:9999px;
    --shadow-sm:0 1px 2px 0 rgba(16,24,40,0.06), 0 1px 3px 0 rgba(16,24,40,0.10);
    --font-sans:'Poppins', system-ui, -apple-system, 'Segoe UI', sans-serif;
    --font-body:'Open Sans', system-ui, -apple-system, 'Segoe UI', sans-serif;
  }
  *{box-sizing:border-box;}
  body{margin:0; background:var(--bg-app); color:var(--slate-700);
       font-family:var(--font-body); font-size:15px; line-height:1.5;
       -webkit-font-smoothing:antialiased;}
  .wrap{max-width:1080px; margin:0 auto; padding:32px 24px 64px;}
  h1,h2,h3,h4{font-family:var(--font-sans); color:var(--slate-800); margin:0; letter-spacing:-0.01em;}
  a{color:var(--teal-600); text-decoration:none;} a:hover{text-decoration:underline;}
  .eyebrow{font-family:var(--font-sans); font-weight:700; font-size:12px; letter-spacing:0.06em;
           text-transform:uppercase; color:var(--slate-500);}

  /* Header */
  header.hd{display:flex; align-items:center; justify-content:space-between; gap:24px;
            padding-bottom:24px; border-bottom:3px solid var(--teal-500); margin-bottom:28px;}
  header.hd img{height:116px; margin-bottom:14px;}
  header.hd .titles h1{font-size:30px; font-weight:700;}
  header.hd .titles .sub{color:var(--slate-500); font-size:14px; margin-top:4px;}
  .meta{text-align:right; font-size:13px; color:var(--slate-500); line-height:1.7;}
  .meta strong{color:var(--slate-700); font-weight:600;}

  /* Health score banner */
  .scorebar{display:flex; align-items:center; gap:28px; background:var(--bg-surface);
            border:1px solid var(--border); border-radius:var(--radius-lg);
            box-shadow:var(--shadow-sm); padding:22px 26px; margin:8px 0 18px;}
  .ring{position:relative; width:128px; height:128px; flex:0 0 auto; border-radius:50%;
        display:flex; align-items:center; justify-content:center;}
  .ring::before{content:''; position:absolute; width:98px; height:98px; border-radius:50%; background:var(--bg-surface);}
  .ring .inner{position:relative; text-align:center; font-family:var(--font-sans);}
  .ring .inner .v{font-size:36px; font-weight:800; line-height:1;}
  .ring .inner .o{font-size:11px; color:var(--slate-400); letter-spacing:0.06em; margin-top:2px;}
  .scoremeta h2{font-size:22px; font-weight:700; margin-top:2px;}
  .scoremeta .desc{color:var(--slate-500); font-size:13px; margin-top:6px; max-width:600px; line-height:1.55;}
  .scoremeta .mini{margin-top:12px; display:flex; gap:18px; font-size:13px; color:var(--slate-600); flex-wrap:wrap;}
  .scoremeta .mini b{font-family:var(--font-sans); font-weight:700;}

  /* Summary cards */
  .cards{display:grid; grid-template-columns:repeat(6,1fr); gap:12px; margin:8px 0 32px;}
  .card{background:var(--bg-surface); border:1px solid var(--border); border-radius:var(--radius-lg);
        padding:16px; box-shadow:var(--shadow-sm); text-align:center;}
  .card .n{font-family:var(--font-sans); font-weight:700; font-size:32px; line-height:1;}
  .card .l{font-size:11px; letter-spacing:0.05em; text-transform:uppercase; color:var(--slate-500); margin-top:8px;}
  .card .bar{height:4px; border-radius:var(--radius-full); margin-bottom:12px;}
  a.card{text-decoration:none; transition:transform .12s ease, box-shadow .12s ease; cursor:pointer; display:block;}
  a.card:hover{transform:translateY(-2px); box-shadow:0 6px 16px -4px rgba(16,24,40,0.14); border-color:var(--slate-300);}
  a.card .l{display:flex; align-items:center; justify-content:center; gap:4px;}
  a.card .l::after{content:'\2193'; font-size:11px; color:var(--slate-400);}

  /* Overview strip */
  .overview{display:grid; grid-template-columns:repeat(4,1fr); gap:12px; margin-bottom:36px;}
  .ov{background:var(--bg-surface); border:1px solid var(--border); border-radius:var(--radius-lg); padding:14px 16px;}
  .ov .k{font-size:12px; color:var(--slate-500); text-transform:uppercase; letter-spacing:0.04em;}
  .ov .v{font-family:var(--font-sans); font-weight:700; font-size:20px; color:var(--slate-800); margin-top:4px;}

  /* View tabs */
  .tabs{display:flex; gap:18px; margin:4px 0 22px; border-bottom:1px solid var(--border);}
  .tab{padding:9px 2px; cursor:pointer; font-family:var(--font-sans); font-weight:600; font-size:14px;
       color:var(--slate-500); background:none; border:none; border-bottom:2px solid transparent; margin-bottom:-1px;}
  .tab.active{color:var(--teal-600); border-bottom-color:var(--teal-500);}
  .tab:hover{color:var(--teal-600);}

  /* Per-host-pool view */
  .pool{background:var(--bg-surface); border:1px solid var(--border); border-radius:var(--radius-lg);
        box-shadow:var(--shadow-sm); margin-bottom:16px; overflow:hidden;}
  .pool-hd{display:flex; align-items:center; justify-content:space-between; gap:12px;
           padding:13px 18px; border-bottom:1px solid var(--border); background:var(--slate-50);}
  .pool-hd h3{font-size:17px; font-weight:700;}
  .pool-hd .mc{display:flex; gap:6px; flex-wrap:wrap;}
  .minicount{font-family:var(--font-sans); font-weight:700; font-size:11px; padding:2px 9px; border-radius:var(--radius-full);}
  .pool-body{padding:4px 18px 10px;}
  .pool-body .none{color:var(--success-500); font-size:13px; padding:12px 0; font-weight:600;}
  .frow{display:flex; gap:11px; padding:11px 0; border-bottom:1px solid var(--slate-100); align-items:flex-start;}
  .frow:last-child{border-bottom:none;}
  .frow .sevdot{flex:0 0 auto; width:10px; height:10px; border-radius:50%; margin-top:5px;}
  .frow .ftext{flex:1;}
  .frow .ftext .ft{font-family:var(--font-sans); font-weight:600; font-size:14px; color:var(--slate-800);}
  .frow .ftext .fr{font-size:13px; color:var(--slate-600); margin-top:2px;}
  .frow .fsev{flex:0 0 auto;}

  /* Section (collapsible via <details>) */
  details.sec{margin-bottom:32px; scroll-margin-top:16px;}
  details.sec > summary{list-style:none; cursor:pointer; display:flex; align-items:center; gap:10px;
                        padding:6px 0; user-select:none;}
  details.sec > summary::-webkit-details-marker{display:none;}
  details.sec > summary h2{font-size:20px; font-weight:700; display:flex; align-items:center; gap:10px;}
  .chev{display:inline-block; color:var(--slate-400); font-size:13px; transition:transform .15s ease; transform:rotate(0deg);}
  details.sec[open] > summary .chev{transform:rotate(90deg);}
  details.sec > .sd{color:var(--slate-500); font-size:13px; margin:0 0 16px 24px;}

  /* Finding card */
  .finding{background:var(--bg-surface); border:1px solid var(--border); border-left-width:4px;
           border-radius:var(--radius-lg); padding:16px 18px; margin-bottom:12px; box-shadow:var(--shadow-sm);}
  .finding .top{display:flex; align-items:center; justify-content:space-between; gap:12px; margin-bottom:8px;}
  .finding h3{font-size:16px; font-weight:600;}
  .finding .scope{font-size:12px; color:var(--slate-500); font-family:var(--font-sans); font-weight:500;}
  .badge{display:inline-block; font-family:var(--font-sans); font-weight:700; font-size:11px;
         letter-spacing:0.05em; padding:3px 10px; border-radius:var(--radius-full); white-space:nowrap;}
  .finding .row{margin:6px 0; font-size:14px;}
  .finding .row .lab{font-weight:600; color:var(--slate-700); font-family:var(--font-sans);
                     font-size:12px; text-transform:uppercase; letter-spacing:0.03em; display:block; margin-bottom:2px;}
  .finding .obs{color:var(--slate-600);}
  .finding .rec{color:var(--slate-800);}
  .finding .rat{color:var(--slate-500); font-size:13px;}
  .finding .ref a{font-size:13px;}
  .finding .count{font-family:var(--font-sans); font-weight:600; font-size:13px; color:var(--slate-500);}
  .scopes{display:flex; flex-wrap:wrap; gap:6px; margin-top:4px;}
  .chip{font-family:var(--font-sans); font-size:12px; font-weight:600; padding:4px 11px;
        border-radius:var(--radius-full); background:var(--teal-50); color:var(--teal-700);
        border:1px solid #C8EEF6; white-space:nowrap;}

  footer{margin-top:48px; padding-top:20px; border-top:1px solid var(--border);
         color:var(--slate-500); font-size:12px; line-height:1.7;}
  @media print{ body{background:#fff;} .finding,.card,.ov{box-shadow:none;} }
</style>
</head>
<body>
<div class="wrap">
"@)

    # ---- Header ----
    $logoTag = if ($logo) { "<img src=`"$logo`" alt=`"Nerdio Manager for Enterprise`">" } else { "<h1 style='color:var(--teal-600)'>nerdio</h1>" }
    $null = $sb.AppendLine(@"
<header class="hd">
  <div class="titles">
    $logoTag
    <h1>Nerdio Health Check</h1>
    <div class="sub">$(ConvertTo-HtmlText $CustomerName) — environment assessment</div>
  </div>
  <div class="meta">
    <div>Generated <strong>$generated</strong></div>
    <div>NME version <strong>$(ConvertTo-HtmlText "$($dep.deployedVersion)")</strong></div>
    <div>Edition <strong>$(ConvertTo-HtmlText "$($dep.productEdition)")</strong></div>
  </div>
</header>
"@)

    # ---- Health score banner ----
    $poolNote = "$($Environment.hostPools.Count) host pool$(if ($Environment.hostPools.Count -ne 1) {'s'})"
    $null = $sb.AppendLine(@"
<div class="scorebar">
  <div class="ring" style="background:conic-gradient($($health.color) $($health.score)%, var(--slate-200) 0)">
    <div class="inner"><div class="v" style="color:$($health.color)">$($health.score)</div><div class="o">/ 100</div></div>
  </div>
  <div class="scoremeta">
    <div class="eyebrow">Overall Health Score</div>
    <h2 style="color:$($health.color)">$(ConvertTo-HtmlText $health.label)</h2>
    <div class="desc">Weighted across open findings (Required, Recommended, Optional) and normalised to estate size ($poolNote). Manual and informational items do not affect the score.</div>
    <div class="mini">
      <span>Required <b style="color:#B42318">$($health.required)</b></span>
      <span>Recommended <b style="color:#B54708">$($health.recommended)</b></span>
      <span>Optional <b style="color:#475569">$($health.optional)</b></span>
    </div>
  </div>
</div>
"@)

    # ---- Summary cards ----
    $null = $sb.AppendLine('<div class="cards">')
    foreach ($sev in $sevMeta.Keys) {
        $m = $sevMeta[$sev]
        $n = $summary.$sev
        # Clickable (anchor) only when there is a section to jump to.
        if ($n -gt 0) {
            $null = $sb.AppendLine(@"
  <a class="card" href="#sec-$sev" title="Jump to $($m.label)">
    <div class="bar" style="background:$($m.dot)"></div>
    <div class="n" style="color:$($m.fg)">$n</div>
    <div class="l">$($m.label)</div>
  </a>
"@)
        } else {
            $null = $sb.AppendLine(@"
  <div class="card">
    <div class="bar" style="background:$($m.dot)"></div>
    <div class="n" style="color:$($m.fg)">$n</div>
    <div class="l">$($m.label)</div>
  </div>
"@)
        }
    }
    $null = $sb.AppendLine('</div>')

    # ---- Overview strip ----
    $passEnv = $Environment
    $null = $sb.AppendLine(@"
<div class="overview">
  <div class="ov"><div class="k">Workspaces</div><div class="v">$($passEnv.workspaces.Count)</div></div>
  <div class="ov"><div class="k">Host Pools</div><div class="v">$($passEnv.hostPools.Count)</div></div>
  <div class="ov"><div class="k">Desktop Images</div><div class="v">$($passEnv.desktopImages.Count)</div></div>
  <div class="ov"><div class="k">Scripted Actions</div><div class="v">$($passEnv.scriptedActions.Count)</div></div>
</div>
"@)

    # ---- Cost Optimisation section (optional) ----
    if ($CostAnalysis) {
        $null = $sb.AppendLine((Write-NmeCostSection -CostAnalysis $CostAnalysis -CustomerName $CustomerName))
    }

    # ---- View tabs ----
    $null = $sb.AppendLine(@"
<div class="tabs">
  <button class="tab active" data-v="sev" onclick="showView('sev')">By Severity</button>
  <button class="tab" data-v="pool" onclick="showView('pool')">By Host Pool</button>
</div>
"@)

    # ---- View 1: findings grouped by severity ----
    $null = $sb.AppendLine('<div id="view-severity">')
    $sevOrder = 'Required', 'Recommended', 'Optional', 'Manual', 'Pass', 'Info'
    $sevDesc = @{
        Required    = 'Must fix for supportability or security.'
        Recommended = 'Strong alignment with Nerdio best practice.'
        Optional    = 'Nice-to-have improvements and cost trims.'
        Manual      = 'Telemetry the REST API does not expose — review live in the console.'
        Pass        = 'Already aligned with best practice.'
        Info        = 'Context, no action required.'
    }

    foreach ($sev in $sevOrder) {
        $items = $Findings | Where-Object severity -eq $sev
        if (-not $items) { continue }
        $m = $sevMeta[$sev]
        $title = $m.label.Substring(0, 1) + $m.label.Substring(1).ToLower()
        $null = $sb.AppendLine("<details class='sec' id='sec-$sev' open>")
        $null = $sb.AppendLine("<summary><span class='chev'>&#9654;</span><h2><span style='display:inline-block;width:12px;height:12px;border-radius:50%;background:$($m.dot)'></span>$title <span style='color:var(--slate-400);font-weight:600;font-size:15px'>($($items.Count))</span></h2></summary>")
        $null = $sb.AppendLine("<div class='sd'>$($sevDesc[$sev])</div>")

        # Consolidate findings that share the same rule id (same recommendation) into
        # one card, listing the affected scopes as distinct chips. Group order follows
        # first appearance.
        $seen = [System.Collections.Generic.List[string]]::new()
        foreach ($it in $items) { if (-not $seen.Contains($it.id)) { $seen.Add($it.id) } }

        foreach ($gid in $seen) {
            $group = @($items | Where-Object id -eq $gid)
            $rep = $group[0]
            $scopes = @($group | ForEach-Object { "$($_.scope)" } | Select-Object -Unique)
            $multi = $scopes.Count -gt 1

            $badge = "<span class='badge' style='background:$($m.bg);color:$($m.fg)'>$($m.label)</span>"
            $refHtml = ''
            if ($rep.reference) { $refHtml = "<div class='row ref'><a href='$(ConvertTo-HtmlText $rep.reference)' target='_blank' rel='noopener'>Reference &rarr;</a></div>" }
            $recHtml = ''
            if ($rep.recommendation) { $recHtml = "<div class='row'><span class='lab'>Recommendation</span><span class='rec'>$(ConvertTo-HtmlText $rep.recommendation)</span></div>" }
            $ratHtml = ''
            if ($rep.rationale) { $ratHtml = "<div class='row'><span class='lab'>Why it matters</span><span class='rat'>$(ConvertTo-HtmlText $rep.rationale)</span></div>" }

            if ($multi) {
                $chips = ($scopes | ForEach-Object { "<span class='chip'>$(ConvertTo-HtmlText $_)</span>" }) -join ''
                $countLbl = "<span class='count'>&times;$($scopes.Count)</span>"
                $subtitle = ConvertTo-HtmlText $rep.area
                $bodyTop = "  <div class=`"row`"><span class=`"lab`">Affected ($($scopes.Count))</span><div class=`"scopes`">$chips</div></div>"
            } else {
                $countLbl = ''
                $subtitle = "$(ConvertTo-HtmlText $rep.area) &middot; $(ConvertTo-HtmlText $rep.scope)"
                $bodyTop = "  <div class=`"row`"><span class=`"lab`">Observation</span><span class=`"obs`">$(ConvertTo-HtmlText $rep.observation)</span></div>"
            }

            $null = $sb.AppendLine(@"
<div class="finding" style="border-left-color:$($m.dot)">
  <div class="top">
    <div><h3>$(ConvertTo-HtmlText $rep.title) $countLbl</h3><div class="scope">$subtitle</div></div>
    $badge
  </div>
$bodyTop
  $recHtml
  $ratHtml
  $refHtml
</div>
"@)
        }
        $null = $sb.AppendLine('</details>')
    }
    $null = $sb.AppendLine('</div>')   # end view-severity

    # ---- View 2: findings grouped by host pool ----
    $null = $sb.AppendLine('<div id="view-pool" style="display:none">')

    # Scope ordering: each host pool (in natural order), then any other scopes, then Environment.
    $poolNames = @($Environment.hostPools | ForEach-Object { "$($_.ref.name)" })
    $allScopes = @($Findings | ForEach-Object { "$($_.scope)" } | Select-Object -Unique)
    $otherScopes = @($allScopes | Where-Object { $_ -ne 'Environment' -and $poolNames -notcontains $_ })
    $scopeOrder = @($poolNames) + @($otherScopes | Sort-Object)
    if ($allScopes -contains 'Environment') { $scopeOrder += 'Environment' }

    foreach ($scope in $scopeOrder) {
        $scopeItems = @($Findings | Where-Object { "$($_.scope)" -eq $scope })
        # mini severity counts for this scope
        $mc = ''
        foreach ($sev in 'Required', 'Recommended', 'Optional', 'Manual', 'Pass', 'Info') {
            $c = @($scopeItems | Where-Object severity -eq $sev).Count
            if ($c -gt 0) {
                $mm = $sevMeta[$sev]
                $mc += "<span class='minicount' style='background:$($mm.bg);color:$($mm.fg)'>$c $($mm.label)</span>"
            }
        }
        $null = $sb.AppendLine(@"
<div class="pool">
  <div class="pool-hd"><h3>$(ConvertTo-HtmlText $scope)</h3><div class="mc">$mc</div></div>
  <div class="pool-body">
"@)
        # actionable items first; if none, show an all-clear note
        $actionable = @($scopeItems | Where-Object severity -in 'Required', 'Recommended', 'Optional', 'Manual')
        if ($actionable.Count -eq 0) {
            $null = $sb.AppendLine('<div class="none">No actionable findings &mdash; aligned with best practice.</div>')
        }
        $svRank = @{ Required = 0; Recommended = 1; Optional = 2; Manual = 3; Pass = 4; Info = 5 }
        foreach ($it in ($scopeItems | Sort-Object @{ E = { $svRank["$($_.severity)"] } }, title)) {
            $mm = $sevMeta["$($it.severity)"]
            $rec = if ($it.recommendation) { ConvertTo-HtmlText $it.recommendation } else { ConvertTo-HtmlText $it.observation }
            $null = $sb.AppendLine(@"
    <div class="frow">
      <span class="sevdot" style="background:$($mm.dot)"></span>
      <div class="ftext"><div class="ft">$(ConvertTo-HtmlText $it.title)</div><div class="fr">$rec</div></div>
      <span class="fsev"><span class="badge" style="background:$($mm.bg);color:$($mm.fg)">$($mm.label)</span></span>
    </div>
"@)
        }
        $null = $sb.AppendLine('  </div></div>')
    }
    $null = $sb.AppendLine('</div>')   # end view-pool

    # ---- Footer ----
    $null = $sb.AppendLine(@"
<footer>
  <div>Generated by the Nerdio Health Check tool against $(ConvertTo-HtmlText "$($passEnv.baseUrl)") on $generated.</div>
  <div>Read-only assessment via the NME REST API. <strong>Manual</strong> items (Log Analytics counters, RI Analytics, auto-scale history, Insights dashboards, Azure Monitor) are not exposed by the API and must be reviewed in the console. Host pools with zero session hosts cannot be discovered via the API — confirm none were missed.</div>
  <div>Internal / TAM-facing. Produce the customer deliverable from the Customer-Facing Template.</div>
</footer>
</div>
<script>
  // Toggle between the By Severity and By Host Pool views.
  function showView(v){
    document.getElementById('view-severity').style.display = (v === 'sev') ? '' : 'none';
    document.getElementById('view-pool').style.display     = (v === 'pool') ? '' : 'none';
    document.querySelectorAll('.tab').forEach(function(t){ t.classList.toggle('active', t.dataset.v === v); });
  }
  // Summary-tile clicks jump to the severity view; expand the target section if collapsed.
  document.querySelectorAll('a.card').forEach(function(a){
    a.addEventListener('click', function(){
      showView('sev');
      var t = document.querySelector(a.getAttribute('href'));
      if (t && t.tagName === 'DETAILS') { t.open = true; }
    });
  });
</script>
</body>
</html>
"@)

    if (-not $OutPath) {
        $safe = ($CustomerName -replace '[^\w\-]', '_')
        $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
        $OutPath = Join-Path $PSScriptRoot "..\output\$safe-healthcheck-$stamp.html"
    }
    $sb.ToString() | Set-Content -LiteralPath $OutPath -Encoding UTF8
    Write-Host "HTML report written: $OutPath" -ForegroundColor Green
    return $OutPath
}
