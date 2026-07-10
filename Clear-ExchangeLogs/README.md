# Clear-ExchangeLogs.ps1

A safe PowerShell cleanup script that reclaims disk space on **Exchange Server 2019**
(and IIS servers generally) by purging old **IIS and Exchange diagnostic log files**.

Exchange runs on IIS, and neither IIS nor several Exchange components purge their
own logs. Over time these fill the system drive and can take the server down.
This script deletes log files older than a retention window from the well-known
log locations — while leaving the folder structure and any currently open
(locked) log intact.

> ⚠️ **This script does NOT delete Exchange database transaction logs.** It only
> removes IIS and Exchange *diagnostic/protocol* logs. See
> [What it does NOT touch](#what-it-does-not-touch).

---

## What it cleans

By default the script targets these directories and removes `*.log`, `*.blg`, and
`*.etl` files older than the retention window:

| Path | Contents |
|------|----------|
| IIS log directory (auto-detected) | IIS access logs |
| `%SystemRoot%\System32\LogFiles\HTTPERR` | HTTP.sys error logs |
| `<ExchangeInstall>\Logging` | Exchange diagnostic logs (protocol, health, etc.) |
| `<ExchangeInstall>\TransportRoles\Logs` | Message tracking / connectivity / protocol logs |
| `<ExchangeInstall>\Bin\Search\Ceres\Diagnostics\Logs` | Search indexer diagnostic logs |

Nothing is hardcoded. The **IIS log directory** is read from the live IIS
configuration (falling back to `%SystemDrive%\inetpub\logs\LogFiles` if the IIS
module isn't present), and the **Exchange install path** is read from the registry
(`HKLM:\SOFTWARE\Microsoft\ExchangeServer\v15\Setup`), so it works regardless of
which drive IIS or Exchange were installed on. On a non-Exchange (IIS-only) box,
the Exchange paths are skipped automatically.

## What it does NOT touch

- **ESE database transaction logs** (`E00*.log` / `Exx*.log`) that live in the
  **mailbox database directory** alongside your `.edb` files. These are *not* in
  the scanned path list and are never seen by the script.
- The **transport queue database** (`mail.que` and its logs) under
  `TransportRoles\data\` — the script targets `TransportRoles\Logs`, not `...\data`.

**Never manually delete ESE transaction logs.** They are truncated automatically
by a successful VSS-aware backup (Windows Server Backup, Veeam, DPM, etc.). If
transaction logs are filling your disk, the fix is a working backup job — not
deletion, which can corrupt the database or break your recovery chain.

## Safety features

- **Dry-run by default.** With no arguments it only *reports* what would be
  deleted and how much space would be freed. Nothing is removed until you pass
  `-Execute`.
- **Skips locked files.** The currently open log is in use and is skipped
  automatically — this is normal and reported as such.
- **Audit trail.** Every run is logged to `%SystemDrive%\LogCleanup\Clear-ExchangeLogs.log`.
- **No service restart needed.** IIS and Exchange keep running; new logs are
  created as usual.

## Requirements

- Windows Server with IIS and/or Exchange Server 2019
- PowerShell 5.1+
- Run **as Administrator**

## Usage

Preview (safe — deletes nothing):

```powershell
.\Clear-ExchangeLogs.ps1
```

Delete logs older than 14 days:

```powershell
.\Clear-ExchangeLogs.ps1 -RetentionDays 14 -Execute
```

Show per-file detail:

```powershell
.\Clear-ExchangeLogs.ps1 -Verbose
```

If execution policy blocks the script:

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\Clear-ExchangeLogs.ps1
```

### Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| `-RetentionDays` | `14` | Delete files older than this many days. |
| `-Execute` | *(off)* | Actually delete. Without it, the script is a dry run. |
| `-Paths` | *(auto)* | Override the set of directories to clean. |
| `-LogFile` | `%SystemDrive%\LogCleanup\Clear-ExchangeLogs.log` | Path to the script's run log. |

## Schedule it (daily automatic cleanup)

Run once in an elevated PowerShell after confirming a dry run looks correct:

```powershell
$action  = New-ScheduledTaskAction -Execute 'powershell.exe' `
    -Argument '-NoProfile -ExecutionPolicy Bypass -File "C:\Scripts\Clear-ExchangeLogs.ps1" -RetentionDays 14 -Execute'
$trigger = New-ScheduledTaskTrigger -Daily -At 2:00AM
$principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -RunLevel Highest
Register-ScheduledTask -TaskName 'Exchange Log Cleanup' `
    -Action $action -Trigger $trigger -Principal $principal `
    -Description 'Purges IIS/Exchange logs older than 14 days.'
```

Adjust the `-File` path to wherever the script lives on the server.

## Recommendations

- **Always run a dry run first** on a new server to confirm the paths and volume.
- Keep at least 7–14 days of logs for troubleshooting and security/forensic needs.
- If you have compliance or audit retention requirements, archive logs before
  deleting.
- Ensure your Exchange backups are running successfully — that, not this script,
  is what manages database transaction logs.

## Disclaimer

Provided as-is. Test in your environment before scheduling in production. You are
responsible for verifying the target paths and retention window suit your setup.
