# Get-MailboxSizeReport.ps1

A **read-only** inventory of every mailbox in an on-premises **Exchange**
organization, showing **how big each mailbox is** and **when it was last
logged on**. Results open in an interactive, sortable **Out-GridView** window by
default, and can optionally be exported to **CSV**.

It can also **filter by activity** — return only mailboxes that *have* logged on
within the last 6/12/24/36/48 months (`-ActiveWithinMonths`), or only the
**dormant** ones that have *not* (`-InactiveForMonths`, which also catches
never-logged-on mailboxes).

> This script changes **nothing** — no mailbox, AD, or server writes. Safe to
> run as many times as you like.

---

## What it reports

For each mailbox (`Get-Mailbox` + `Get-MailboxStatistics`):

| Column | Source | Meaning |
|--------|--------|---------|
| **DisplayName** | `Get-Mailbox` | The mailbox display name. |
| **EmailAddress** | `PrimarySmtpAddress` | The primary SMTP address. |
| **MailboxSizeGB** | `TotalItemSize` | Total mailbox size in GB (sorted largest-first). |
| **LastLogon** | `LastLogonTime` | When the mailbox was last accessed. Blank = never logged on. |
| MailboxSizeMB | `TotalItemSize` | Same size in MB. |
| ItemCount | `Get-MailboxStatistics` | Number of items in the mailbox. |
| LastLoggedOnUser | `LastLoggedOnUserAccount` | Account that last opened the mailbox. |
| RecipientTypeDetails | `Get-Mailbox` | UserMailbox / SharedMailbox / RoomMailbox, etc. |
| Database | `Get-Mailbox` | Mailbox database. |

The four **requested** columns — DisplayName, EmailAddress, MailboxSizeGB and
LastLogon — come first (in both the grid and the CSV); the rest follow as
extra context.

## Requirements

- **On-premises Exchange** (2016 / 2019) organization.
- Run from the **Exchange Management Shell**, or any Windows PowerShell where the
  Exchange snap-in / RBAC access is available. If neither is present, the script
  will try to **discover an Exchange server from Active Directory** and connect
  to it automatically.
- An account with at least **View-Only Organization Management** rights.
- **Out-GridView** needs a GUI-capable host. On Server Core (or if it is
  unavailable) the script automatically falls back to a formatted table.

## Usage

**Zero-touch — no editing required.** The Exchange connection is discovered at
runtime (existing session → on-box snap-in → AD-discovered server), so the
script runs unmodified in any on-premises Exchange organization.

Show every mailbox in the interactive grid:

```powershell
.\Get-MailboxSizeReport.ps1
```

Grid **plus** a CSV on your Desktop:

```powershell
.\Get-MailboxSizeReport.ps1 -ExportCsv
```

CSV only (no grid), to a chosen path, for a single database:

```powershell
.\Get-MailboxSizeReport.ps1 -Database 'DB01' -CsvPath 'C:\Temp\DB01.csv' -NoGridView
```

Only mailboxes **active** in the last 6 months:

```powershell
.\Get-MailboxSizeReport.ps1 -ActiveWithinMonths 6
```

Only **dormant** mailboxes — no logon in the last 12 months (including
never-logged-on) — to a CSV:

```powershell
.\Get-MailboxSizeReport.ps1 -InactiveForMonths 12 -ExportCsv
```

> `-ActiveWithinMonths` and `-InactiveForMonths` are **mutually exclusive** —
> specify only one. Both accept `6`, `12`, `24`, `36`, or `48` months.

If execution policy blocks the script:

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\Get-MailboxSizeReport.ps1
```

### Parameters (all optional)

| Parameter | Default | Description |
|-----------|---------|-------------|
| `-Identity` | *all mailboxes* | One or more specific mailboxes to report on. |
| `-Database` | *all* | Limit the report to a single mailbox database. |
| `-OrganizationalUnit` | *all* | Limit the report to mailboxes under an OU. |
| `-RecipientTypeDetails` | *all types* | Filter by mailbox type (e.g. `UserMailbox`, `SharedMailbox`, `RoomMailbox`, `EquipmentMailbox`). Accepts multiple values. |
| `-ActiveWithinMonths` | *off* | Return only mailboxes that **have** logged on within the last N months. Valid: `6`, `12`, `24`, `36`, `48`. |
| `-InactiveForMonths` | *off* | Return only mailboxes that have **not** logged on in the last N months (**includes** never-logged-on mailboxes). Valid: `6`, `12`, `24`, `36`, `48`. |
| `-ExportCsv` | *off* | Also export the results to CSV. |
| `-CsvPath` | Desktop `MailboxSizeReport_<timestamp>.csv` | Where to write the CSV. Supplying it implies `-ExportCsv`. |
| `-NoGridView` | *off* | Suppress the grid window (for CSV-only or headless runs). |

## Output

- **Out-GridView** (default): a sortable, filterable window titled
  *"Mailbox Size & Last Logon Report (N mailboxes)"*. Click a column header to
  sort (e.g. by `MailboxSizeGB` to find the biggest mailboxes, or by `LastLogon`
  to find dormant ones).
- **CSV** (with `-ExportCsv` / `-CsvPath`): UTF-8, headers
  `DisplayName,EmailAddress,MailboxSizeGB,LastLogon,...`.
- The report objects are also returned to the pipeline, so you can post-process,
  e.g. `... | Where-Object MailboxSizeGB -gt 10`.

## Notes

- Mailboxes that have **never been logged on** have no statistics: their size
  columns are blank and they sort to the bottom of the list.
- Sorting is by **raw bytes** (an internal `SizeBytes` value), so `MailboxSizeGB`
  ordering is exact rather than string-based.
- Nothing is hardcoded: the Exchange connection, server, and organization are all
  resolved from the environment, so the script needs no editing before it runs in
  a different environment.

## Disclaimer

Provided as-is. It only reads state, but you remain responsible for validating
the findings against your environment.
