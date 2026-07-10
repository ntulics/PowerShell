# PowerShell

Operational PowerShell scripts for administering **Exchange Server** (on-premises
2019/2016) and **Microsoft 365** mail flow. Each script lives in its own folder
with a dedicated README.

> **Zero-touch.** These scripts hardcode no server, domain, forest, or
> organization names — every environment value is discovered at runtime, so they
> run unmodified anywhere. Any names shown in the docs are illustrative examples
> only.

## Scripts

| Script | What it does |
|--------|--------------|
| [Test-ExchangePrereq](Test-ExchangePrereq/) | **Read-only** pre-flight readiness check for Exchange 2019 setup / `PrepareAD`. Catches the `RebootPending` and `AdUpdateRequired` blockers, plus permissions (token vs AD), FSMO reachability, AD replication, schema/org/domain versions, local & DC security policy, and OS prerequisites. |
| [Set-ExchangeMaintenanceMode](Set-ExchangeMaintenanceMode/) | Interactive, `-WhatIf`-capable script to place a DAG member into or out of maintenance mode, including active-database evacuation and post-maintenance redistribution. |
| [Clear-ExchangeLogs](Clear-ExchangeLogs/) | Safe cleanup of IIS and Exchange **diagnostic** logs to reclaim disk space. Dry-run by default; never touches database transaction logs. |
| [Get-ExchangeEnvironmentReport](Get-ExchangeEnvironmentReport/) | Generates a modern, server-centric **HTML dashboard** of the on-prem Exchange environment — KPI health tiles, collapsible per-server cards, disk-usage and database size-vs-limit donuts, backup/mount state, and edition-aware capacity intelligence. Ships with `EnvironmentReport.css`. |
| [Get-MailboxSizeReport](Get-MailboxSizeReport/) | **Read-only** inventory of every mailbox — size and last-logon time — in an interactive Out-GridView (optional CSV export). Can filter by activity (`-ActiveWithinMonths` / `-InactiveForMonths`). |
| [Test-ScanToEmail](Test-ScanToEmail/) | SMTP diagnostics tool that submits a test message to **any SMTP provider** and prints the full SMTP transcript so you can see exactly why a send fails. GUI (`.UI.ps1`) with one-click provider presets (Microsoft 365, HVE, SendGrid, SES, Postmark, Mailgun, and more). Includes an M365 mail-flow reference for apps and MFDs. |

## Troubleshooting notes

| Note | Covers |
|------|--------|
| [Fix-HybridProxy301](Fix-HybridProxy301/) | Fixing the Hybrid Configuration Wizard (HCW) failing at "Gathering Configuration Information" with a **WinRM HTTP 301** caused by a system WinHTTP proxy — root cause, diagnosis, and the `<local>` bypass fix. |

## General requirements

- Windows Server with Exchange Server (or the Exchange management tools) for the
  on-prem scripts; `Test-ScanToEmail` runs anywhere PowerShell does.
- Windows PowerShell 5.1
- Run **as Administrator**

See each script's folder README for detailed usage, parameters, and safety notes.
