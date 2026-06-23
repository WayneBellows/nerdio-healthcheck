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
config/   credentials + rules.json
src/      Connect-Nme, Collect-NmeEnvironment, Test-NmeRules, Write-NmeReport
assets/   vendored Nerdio logo
output/   raw collection, findings, reports (gitignored)
```

The report is styled with the NME Design System (brand teal, Poppins, status-badge conventions). Tokens are inlined and the logo is base64-embedded so the HTML is a single portable file.
