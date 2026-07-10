# PowerShell

Operational PowerShell scripts for administering **Exchange Server 2019**. Each
script lives in its own folder with a dedicated README.

> **Zero-touch.** These scripts hardcode no server, domain, forest, or
> organization names — every environment value is discovered at runtime, so they
> run unmodified anywhere. Any names shown in the docs are illustrative examples
> only.

## Scripts

| Script | What it does |
|--------|--------------|
| [Test-ExchangePrereq](Test-ExchangePrereq/) | Read-only pre-flight readiness check for Exchange 2019 setup / `PrepareAD`. Catches the `RebootPending` and `AdUpdateRequired` blockers, plus permissions, AD replication, schema/org versions, and OS prerequisites. |
| [Set-ExchangeMaintenanceMode](Set-ExchangeMaintenanceMode/) | Interactive, `-WhatIf`-capable script to place a DAG member into or out of maintenance mode, including active-database evacuation and redistribution. |
| [Clear-ExchangeLogs](Clear-ExchangeLogs/) | Safe cleanup of IIS and Exchange **diagnostic** logs to reclaim disk space. Dry-run by default; never touches database transaction logs. |

## General requirements

- Windows Server with Exchange Server 2019 (or the Exchange management tools)
- Windows PowerShell 5.1
- Run **as Administrator**

See each script's folder README for detailed usage, parameters, and safety notes.
