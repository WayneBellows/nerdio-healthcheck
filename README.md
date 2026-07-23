# Nerdio Health Check

Read-only assessment of a customer's Nerdio Manager for Enterprise (NME) environment via the NME REST API. Scores configuration against Nerdio best practice and produces a branded HTML report with Required / Recommended / Optional / Manual findings and an overall health score.

Standalone tool — **not** part of Nerdio Compass. Sibling in spirit to `avd-assess` / `rds-assess`.

## What it checks

Via the NME REST API (read-only GETs only — never writes):

- **Version & supportability** — NME version, edition, N/N-1 posture (set `knownLatestVersion`)
- **Auto-Scale** — enabled, auto-heal, sizing, stopped-disk type (Premium), pre-stage, scale triggers
- **Host pool config** — FSLogix, session time limits, scheduled agent updates, validation flag, friendly name, availability zones, time-zone redirection, RDP Shortpath
- **Images** — OS disk optimisation, Azure Compute Gallery
- **App delivery** — UAM policies, repositories, Shell Apps, App-Attach
- **Notifications, RBAC, usage** (named users vs MAU)

**Not in the REST API** (reported as *Manual*): Log Analytics counters/savings, RI Analytics, 30-day auto-scale CPU/RAM history, Insights dashboards, Azure Monitor enablement, empty host pools, Azure Capacity Extender.

## Cost Optimisation analysis (`-CostAnalysis`)

Adds a customer-facing **Cost Optimisation** section to the report: a headline monthly/annual savings range plus one card per optimisation play — auto-scale base capacity, pre-staging, rolling drain, stopped-disk tiering, OS disk right-tiering, VM rightsizing, Log Analytics counter optimisation, and storage auto-scaling.

Every figure carries an **evidence tier**:

| Tier | Source | Shown as |
|---|---|---|
| **Measured** | Figures you record from the NME console (`-ObservedData`) — auto-scale savings, LAW ingestion — plus optional screenshots embedded as evidence | Point value |
| **Enriched** | Live Azure data via `az` CLI (Advisor rightsizing, disk SKUs, LAW ingestion by counter). Skipped cleanly if `az` is absent, or with `-SkipAzureEnrichment` | Point value |
| **Modelled** | NME config + stated assumptions (`config/cost-assumptions.json`) | Conservative–typical range |

Compute/disk/Log Analytics rates come from the public Azure Retail Prices API and are cached in `config/pricing-cache.json` (7-day TTL), so `-FromFile` re-runs work offline once the cache is warm. Compute is priced at the base rate (assumes Azure Hybrid Benefit) — the Windows PAYG rate is fetched too and noted.

```powershell
# Full run with cost analysis (uses az CLI if authenticated)
pwsh ./Invoke-NerdioHealthCheck.ps1 -Report -CustomerName "Acme Corp" -CostAnalysis

# With measured figures from the NME console (copy config/observed-data.example.json)
pwsh ./Invoke-NerdioHealthCheck.ps1 -Report -CustomerName "Acme Corp" -CostAnalysis -ObservedData config/observed-data.local.json

# Offline re-run, no Azure calls
pwsh ./Invoke-NerdioHealthCheck.ps1 -FromFile output/raw/environment-....json -CostAnalysis -SkipAzureEnrichment
```

`config/observed-data.local.json` is picked up automatically when present. Screenshot evidence (PNG/JPG, under ~1.5 MB) goes in `evidence/` and is referenced from the observed-data file. Assumptions (business window, conservative factor, LAW sample-rate targets, fallback prices) are all tunable in `config/cost-assumptions.json`. Savings figures are indicative estimates, not quotes — the report says so and lists each play's assumptions.

## Setup

1. Copy `config/credentials.example.json` to `config/credentials.local.json` (gitignored).
2. Fill in `clientSecret` and `baseUrl`. The other fields (tenant/client/scope) come from your NME REST API app registration.

Credentials use OAuth2 client-credentials against Azure AD; the bearer token is held in memory for the run only.

## Usage

```powershell
# Connectivity test only
pwsh ./Invoke-NerdioHealthCheck.ps1

# Full run: collect + assess + branded HTML report
pwsh ./Invoke-NerdioHealthCheck.ps1 -Report -CustomerName "Acme Corp"

# Collect raw data only (-> output/raw/)
pwsh ./Invoke-NerdioHealthCheck.ps1 -Collect

# Re-assess / re-report previously collected data (no credentials needed)
pwsh ./Invoke-NerdioHealthCheck.ps1 -FromFile output/raw/environment-YYYYMMDD-HHMMSS.json
```

Output (HTML report, findings JSON, raw collection) lands in `output/` (gitignored).

## Tuning

All thresholds, severities, reference links, and the health-score weighting live in `config/rules.json` — edit there, no code change needed. Set `version.knownLatestVersion` to activate the N/N-1 supportability check (update each NME release, ~8 weeks).

## Layout

```
Invoke-NerdioHealthCheck.ps1   entry point / orchestrator
config/   credentials + rules.json + cost-assumptions.json + observed-data example
src/      Connect-Nme, Collect-NmeEnvironment, Test-NmeRules, Write-NmeReport
src/cost/ Get-NmePricing, Get-NmeAzureEnrichment, Get-NmeObservedData,
          Measure-NmeCostSavings, Write-NmeCostSection
assets/   vendored Nerdio logo
evidence/ screenshot evidence for observed data (gitignored)
output/   raw collection, findings, cost analysis, reports (gitignored)
```

The report is styled with the NME Design System (brand teal, Poppins, status-badge conventions). Tokens are inlined and the logo is base64-embedded so the HTML is a single portable file.
