# Nerdio Health Check

A read-only tool that connects to a customer's **Nerdio Manager for Enterprise (NME)** environment, checks it against Nerdio best practice, and produces a single branded HTML report you can walk a customer through.

It does two things:

1. **Health check** — scores the configuration (auto-scale, FSLogix, images, notifications, and more) and lists what's Required, Recommended, Optional, or needs a Manual check.
2. **Cost optimisation** (optional) — estimates how much the customer could save with Nerdio's cost features and puts a monthly/annual pound-or-dollar figure on it, for a value conversation.

Everything is **read-only** — it only ever reads data, never changes the customer's environment. The report is one self-contained HTML file (logo and images embedded), so you can email it or drop it in Teams.

---

## Prerequisites

This tool talks to NME through the **NME REST API** — that's how it reads the environment. Before you can run it against a customer, two things must be in place:

1. **The NME REST API must be enabled** in that customer's Nerdio Manager (in the NME portal under **Settings → Integrations → REST API**). This is a one-time switch-on per NME instance, and it creates an API client (an Entra app registration) that the tool authenticates as. If it's not enabled, the tool has nothing to connect to.

2. **You must add the credentials** for that API client. Copy `config/credentials.example.json` to `config/credentials.local.json` and fill in the values NME gives you when the REST API is enabled:
   - `tokenUrl` / `tenantId` — the customer's Entra tenant
   - `clientId` — the API client's application ID
   - `clientSecret` — the client secret
   - `scope` — `api://<nmeApiAppId>/.default`
   - `baseUrl` — the customer's NME URL (`https://<nmw-app-xxxxx>.azurewebsites.net`)

   `credentials.local.json` is gitignored and holds the secret — never commit it.

Also needed:

- **PowerShell** (Windows PowerShell 5.1 or PowerShell 7 — `pwsh`).
- **`az` CLI (optional)** — only for the enriched cost figures. If you're not signed in, the tool skips enrichment and still runs. See [What permissions do I need?](#what-permissions-do-i-need) for the access levels.

> **No NME REST API access = the tool can't run.** It's the single hard dependency. Everything else (Azure enrichment, observed data) is optional and only sharpens the cost numbers.

---

## Quick start

1. **Set up credentials once** (see [Setup](#setup) below).
2. **Run it:**

```powershell
pwsh ./Invoke-NerdioHealthCheck.ps1 -Report -CustomerName "Acme Corp"
```

3. Open the HTML report from the `output/` folder.

Add `-CostAnalysis` to include the cost optimisation section:

```powershell
pwsh ./Invoke-NerdioHealthCheck.ps1 -Report -CustomerName "Acme Corp" -CostAnalysis
```

That's the whole tool. The rest of this document explains what's in the report and how to get the most accurate numbers.

---

## Part 1 — The health check

Reads the NME REST API and checks:

- **Version & supportability** — NME version, edition, and whether it's within the supported N/N-1 window.
- **Auto-Scale** — is it on, auto-heal, sizing, the stopped-disk type, pre-staging, scale triggers.
- **Host pool config** — FSLogix, session time limits, scheduled agent updates, validation flag, friendly name, availability zones, time-zone redirection, RDP Shortpath.
- **Images** — OS disk optimisation, Azure Compute Gallery.
- **App delivery** — UAM policies, repositories, Shell Apps, App-Attach.
- **Notifications, RBAC, usage** — including named users vs monthly active users.

Each finding is graded **Required** (must fix), **Recommended** (best practice), **Optional** (nice-to-have), **Pass** (already good), or **Manual**.

**"Manual" findings** are things the REST API simply doesn't expose, so the tool can't check them automatically — it lists them for you to review live in the NME console: Log Analytics counters, RI Analytics, 30-day auto-scale history, Insights dashboards, Azure Monitor enablement, empty host pools, Azure Capacity Extender.

The report shows an overall **health score out of 100**, summary tiles, and two views: **By Severity** and **By Host Pool**.

---

## Part 2 — The cost optimisation section (`-CostAnalysis`)

Adds a customer-facing section with a **headline savings range** (per month and per year) and one card per opportunity ("play"). Each card shows the current state, the recommended change, the estimated saving, and the assumptions behind it.

### The plays it quantifies

| Play | What it looks at |
|---|---|
| **Enable / right-size auto-scale** | Hosts running 24/7 that could power down out of hours |
| **Trim pre-staging** | More hosts warmed up before the workday than needed |
| **Rolling drain** | Hosts that could empty and switch off sooner |
| **Stopped-disk tiering** | Premium OS disks still billing at full rate while a host is off |
| **OS disk right-tiering** | Premium OS disks on hosts where Standard SSD would do |
| **VM right-sizing** | Oversized session-host VMs (uses Azure Advisor when available) |
| **Log Analytics counters** | The "User Input Delay" counter — often 80–91% of monitoring cost |
| **Storage auto-scaling** | Over-provisioned Azure Files profile shares |
| **Reserved Instances / Savings Plans** | Committing the always-on base to a 1- or 3-year rate |

### How trustworthy is each number? (the three tiers)

Every figure is **badged** so you and the customer know exactly how solid it is:

| Tier | Where the number comes from | Shown as |
|---|---|---|
| 🟢 **Measured** | Real figures you read off the NME console (and type into a small file) | A single confident value |
| 🔵 **Enriched** | Live data pulled read-only from the customer's Azure via the `az` CLI | A single value |
| ⚪ **Modelled** | Worked out from the NME config plus stated assumptions | A conservative–typical **range** |

Measured beats Enriched beats Modelled. If you give it nothing extra, it still produces defensible Modelled ranges from the config alone.

Prices come from the **public Azure Retail Prices API** (no login needed) and are cached locally for 7 days, so repeat runs are fast and work offline. Compute is priced assuming **Azure Hybrid Benefit** (the Windows pay-as-you-go rate is also fetched and noted).

Every card lists its assumptions, and the section states plainly that these are **estimates, not quotes**.

### Reserved Instances & Savings Plans

Reservations matter two ways, and the tool handles both:

- **They reduce some savings.** If a customer already has reservations, powering hosts off saves nothing on that pre-paid compute. Tell the tool the coverage % (see below) and it shrinks the auto-scale / pre-stage / rolling-drain figures accordingly.
- **They're an opportunity.** For a base of hosts that genuinely runs 24/7, the tool prices a 1-year and 3-year Savings Plan against pay-as-you-go and shows the discount. It deliberately **won't** suggest committing capacity that auto-scale would otherwise switch off, and won't suggest a reservation for a pool that isn't even running yet — that needs auto-scale first.

**Where does the coverage % come from?** The tool tries to check Azure automatically and always tells you the basis, in the console, in a note box in the report, and in the JSON:

| What happened | Note shown |
|---|---|
| You supplied the % | 🟢 uses your figure |
| Azure confirmed the customer has none | 🟢 0% is correct |
| Reservations exist but no % given, or Azure couldn't be read | 🟠 **"Action needed"** — go get the figure, otherwise savings may be overstated |

Reading reservations from Azure needs a **tenant-level role** (Reservation Reader or Cost Management Reader) that plain subscription Reader doesn't include. When that role isn't there, the tool says so clearly and you just type the number in — it never invents a coverage figure.

---

## Getting the best numbers (optional inputs)

The tool works with nothing extra, but two optional inputs sharpen it:

### 1. Azure enrichment (automatic if you're logged in)

If the `az` CLI is authenticated and can reach the customer's subscription, the tool automatically pulls:
- Azure Advisor right-sizing and reservation recommendations
- Actual disk SKUs
- Log Analytics ingestion broken down by counter
- Azure Files provisioned-vs-used capacity
- Whether reservations exist

It degrades gracefully — anything it can't read is simply skipped, and you can turn it off entirely with `-SkipAzureEnrichment`.

### 2. Observed data (figures you read from the NME console)

Some of the best numbers (actual auto-scale savings, Log Analytics volume, reservation coverage) live in the NME console, not the API. Record them in a small file so the report can show them as **Measured**:

1. Copy `config/observed-data.example.json` to `config/observed-data.local.json`.
2. Fill in what you have (all fields optional).
3. It's picked up automatically, or pass it explicitly with `-ObservedData`.

You can also reference **screenshots** (e.g. the NME auto-scale history screen) — put PNG/JPG files under `evidence/` (keep them under ~1.5 MB) and list them in the observed-data file. They're embedded into the report as proof.

---

## What permissions do I need?

| You want… | You need |
|---|---|
| The health check + Modelled cost estimates | Just the NME REST API credentials (below). Nothing else. |
| Azure-enriched figures (Advisor, disks, Log Analytics) | `az` logged in with **Reader** on the customer's subscription |
| Automatic reservation-coverage detection | **Reservation Reader** or **Cost Management Reader** at tenant scope (beyond Reader) |

If you only have the NME credentials, everything still runs — you just get Modelled ranges instead of Measured/Enriched values, and you type in the coverage % yourself.

---

## Setup

See [Prerequisites](#prerequisites) above — enable the NME REST API and fill in `config/credentials.local.json`. That's the whole setup.

Credentials use OAuth2 client-credentials against Entra ID; the token is held in memory for the run only and never written to disk.

---

## Common commands

```powershell
# Just test the connection
pwsh ./Invoke-NerdioHealthCheck.ps1

# Health check + branded HTML report
pwsh ./Invoke-NerdioHealthCheck.ps1 -Report -CustomerName "Acme Corp"

# Add the cost optimisation section (uses az CLI automatically if available)
pwsh ./Invoke-NerdioHealthCheck.ps1 -Report -CustomerName "Acme Corp" -CostAnalysis

# Cost analysis with your console figures added
pwsh ./Invoke-NerdioHealthCheck.ps1 -Report -CustomerName "Acme Corp" -CostAnalysis -ObservedData config/observed-data.local.json

# Cost analysis without touching Azure (config-based only)
pwsh ./Invoke-NerdioHealthCheck.ps1 -Report -CustomerName "Acme Corp" -CostAnalysis -SkipAzureEnrichment

# Collect the raw data now, report on it later (no credentials needed to re-run)
pwsh ./Invoke-NerdioHealthCheck.ps1 -Collect
pwsh ./Invoke-NerdioHealthCheck.ps1 -FromFile output/raw/environment-YYYYMMDD-HHMMSS.json -CostAnalysis
```

Reports, findings, and raw data all land in `output/` (gitignored).

### The switches

| Switch | What it does |
|---|---|
| `-Report` | Produce the HTML report |
| `-CustomerName "…"` | Name shown on the report |
| `-CostAnalysis` | Include the cost optimisation section |
| `-ObservedData <path>` | Use figures you captured from the NME console |
| `-SkipAzureEnrichment` | Don't call the `az` CLI (config-based estimates only) |
| `-Collect` | Save the raw environment data without assessing |
| `-FromFile <path>` | Re-run against previously saved data (offline, no credentials) |

---

## Tuning (no code changes)

- **`config/rules.json`** — every health-check threshold, severity, reference link, and the health-score weighting. Set `version.knownLatestVersion` to the current NME version to switch on the supportability check (update it each release, roughly every 8 weeks).
- **`config/cost-assumptions.json`** — the cost assumptions: business hours, conservative factor, Log Analytics sample-rate targets, currency, and fallback prices. Change `currency` to `GBP` to price everything in pounds.

---

## File layout

```
Invoke-NerdioHealthCheck.ps1   the tool you run
config/    credentials, rules.json, cost-assumptions.json, observed-data example
src/       core: Connect-Nme, Collect-NmeEnvironment, Test-NmeRules, Write-NmeReport
src/cost/  cost engine: pricing, Azure enrichment, observed data,
           savings calculations, report section
assets/    Nerdio logo
evidence/  your screenshots for observed data (gitignored)
output/    raw data, findings, cost analysis, reports (gitignored)
```

The report uses the NME design system (brand teal, Poppins) with everything inlined, so the HTML is one portable file.

---

## Good to know

- **Read-only, always.** The tool never changes the customer's environment.
- **Estimates, not quotes.** Cost figures are indicative and the report says so; actual savings depend on usage, discounts, and the customer's Enterprise Agreement rates.
- **Host pools with no session hosts** can't be discovered via the API — the report flags this so you can confirm none were missed in the console.
