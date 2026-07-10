# Get-ExchangeEnvironmentReport

Creates an HTML report describing the On-Premises Exchange environment.

Maintained by Chris Ntuli. Based on the original Get-ExchangeEnvironmentReport by Steve Goodman (later maintained by Thomas Stensitzki).

## Description

This script creates an HTML report showing the following information about an Exchange 2019, 2016, 2013, 2010, and, to a lesser extent, 2007 and 2003 environment.

The HTML report requires the CSS file that is part of this repository for proper HTML formatting.

### Dashboard layout (v2.7)

The report is a modern, server-centric dashboard rather than one very wide table:

* A header with **KPI severity tiles** — Critical, Warnings, Servers, Databases, Mailboxes — that summarise environment health at a glance.
* One **collapsible card per server** (native HTML, click to expand). Each card shows the server's details, a **disk-usage donut per volume**, and its **databases underneath**.
* Each database shows a **size-vs-maximum donut** with colour thresholds, its backup state (all backup types), mount/activation status, and full paths.

Note: the per-server cards use collapsible `<details>` elements. These expand on click in a web browser; when the report is opened inside an email preview pane the sections may render collapsed. Open the attached HTML file in a browser for the full experience.

### Edition-aware capacity intelligence (v2.7)

Verified against [Microsoft Learn](https://learn.microsoft.com/en-us/exchange/plan-and-deploy/deployment-ref/editions-and-versions) and [KB 3059008](https://learn.microsoft.com/en-us/troubleshoot/exchange/administration/exchange-cannot-mount-database-larger-than-1024-gb):

| | Standard | Enterprise |
|---|---|---|
| Max mounted databases / server | **5** | **100** |
| Default database size limit | **1,024 GB** (store auto-dismounts at limit) | **No hard limit** (hardware-bound) |

* The maximum database size is taken from the per-database registry value `Database Size Limit in GB` (`HKLM\SYSTEM\CurrentControlSet\Services\MSExchangeIS\<Server>\Private-<DB GUID>`) when present — it propagates to all DAG copies — otherwise the edition default. Enterprise (no hard limit) uses a configurable best-practice ceiling for the donut and warnings (`-EnterpriseMaxDatabaseSizeGB`, default 2048 GB).
* Databases at/above `-DatabaseSizeCautionPercent` (amber) or `-DatabaseSizeWarningPercent` (red) are highlighted, with advice to move mailboxes, add a database (if under the edition count limit), expand storage, or upgrade the edition.
* The report counts database **copies hosted per server** (active + passive) against the 5/100 edition limit and advises when a server is near or at its limit. The DAG section shows this per member — the limit is per server and counts all copies a member holds.

### Version-aware roles (v2.6)

The report only shows Exchange Server roles that actually exist in the environment, matching the role model of the installed version:

* **Exchange 2007 / 2010** - separate Client Access, Hub Transport, Mailbox, Unified Messaging, and Edge Transport roles.
* **Exchange 2013** - Client Access and Mailbox roles (Hub Transport and Unified Messaging are part of the Mailbox role).
* **Exchange 2016 / 2019** - Mailbox role only (Client Access is part of the Mailbox role), plus the optional Edge Transport role.

Empty CAS/HUB/UM columns are no longer rendered for modern deployments. In a pure Exchange 2019 environment, only the Mailbox (and, if present, Edge) role is shown.

### Database backup state (v2.6)

The database tables always show the backup state of every database for **all backup types** — **Last Full Backup**, and (when present in the environment) **Last Incremental Backup**, **Last Differential Backup**, and **Last Copy Backup**. A **Last Backup (Days Ago)** column summarises how recently each database was protected by a backup of *any* type. Databases that have never been backed up, or whose most recent backup of any type is older than `-MaxBackupAgeDays` (default 1 day), are highlighted. The incremental, differential, and copy columns are only rendered when at least one database actually has a backup of that type.

### Database paths, activation preferences, and site config (v2.6)

* **Database and log file paths** are always shown as full on-disk paths, so **mount points (mounted folders)** and **direct drive letters** are both visible.
* For DAG / multi-copy databases, the report shows the **activation preference** order for every copy, the **preferred owner**, whether each database is currently **mounted**, and whether it is **active on its preferred copy** (highlighted when it is not, or when a database is dismounted).
* A new **Active Directory Site Configuration** section lists AD sites (with hub-site status and Exchange server counts) and AD site links (with AD cost, Exchange cost, and maximum message size).
* DAG headers now include the **witness server**, **witness directory**, and **alternate witness server**.

### Certificates, accepted domains, and validity (v2.6)

* An **Exchange Certificates** section lists each server's certificates with subject, issuer, enabled services, key size, validity window, and expiry. **Self-signed certificates are excluded** (v2.7). Certificates expiring within `-CertificateWarningDays` (default 30) are highlighted in amber; already-expired certificates are shown in red.
* A new **Accepted Domains** section lists each accepted domain, its type (Authoritative / Internal Relay / External Relay), and which is the default.

### Build numbers, updates, and support lifecycle (v2.8)

Each server card shows:

* **Exchange version** with the full build number, the identified Cumulative Update, and whether a newer CU is available (compared against the latest builds from the Microsoft [build numbers page](https://learn.microsoft.com/en-us/exchange/new-features/build-numbers-and-release-dates)).
* **Exchange support status** — Mainstream, Extended, or **Out of support** — per the Microsoft lifecycle. (Note: Exchange 2016 and 2019 reached end of support on **14 October 2025**.) **Exchange Server SE** is detected separately (it shares the 15.2 version family with Exchange 2019 but is identified by build — SE RTM starts at `15.2.2562`) and is shown as **In support (Modern Lifecycle Policy)**, not confused with Exchange 2019.
* **OS update level** — the Windows build including UBR (`10.0.<build>.<UBR>`), display version, and the most recently installed update KB — plus the **Windows Server support status**.

The latest-build, CU-name, and lifecycle data live in maintainable tables near the top of the script. Because Microsoft publishes new Cumulative and Security Updates regularly, update those tables periodically from the Microsoft build-numbers and lifecycle pages. Exchange `AdminDisplayVersion` identifies the CU precisely; confirm the exact Security Update level with the [Exchange HealthChecker](https://aka.ms/exchangehealthchecker).

### Single-file, zero-touch design (v2.6)

Everything lives in a single script — there is no separate run wrapper. No email addresses, SMTP servers, or file names are hard-coded. Run the script **without** `-HTMLReport` and it prompts interactively for the report file name, whether to email the report, and (only if emailing) the SMTP server and the From/To addresses. Supplying `-HTMLReport` (and, for mail, `-SendMail`/`-MailServer`/`-MailFrom`/`-MailTo`) runs unattended, which is ideal for scheduled tasks.

The report shows the following:

* As summary
  * Total number of servers per Exchange Server version
  * Total number of mailboxes per On-Premises Exchange Server version, Office 365, and Exchange Organisation
  * Total number of Exchange Server functional roles

* Per Active Directory Site
  * Total number of mailboxes
  * Internal, External, and CAS Array names
  * Exchange Server computers
    * Product version
    * Service Pack, Update Rollup, and/or Cumulative Update
    * Number of preferred and maximum active databases
    * Functional Roles
    * Operating System with Service Pack

* Active Directory Site Configuration
  * AD sites (hub-site status and Exchange server count)
  * AD site links (AD cost, Exchange cost, maximum message size, connected sites)

* Accepted Domains
  * Domain name, type (Authoritative / Internal Relay / External Relay), and default domain

* Exchange Certificates
  * Per server: subject, enabled services, expiry date, and validity (expiring/expired highlighted)

* Per Database Availability Group
  * Total number of member servers
  * List of member servers
  * Witness server, witness directory, and alternate witness server
  * DAG databases
    * Number of mailboxes and average mailbox size
    * Number of archive mailboxes and average archive mailbox size
    * Database size
    * Database whitespace
    * Disk space available for database and log file volume
    * Backup state for all backup types (full, incremental, differential, copy) and last backup age
    * Circular logging enabled
    * Full database and log file paths (mount points or drive letters)
    * Activation preference, mounted state, preferred owner, and active-on-preferred status
    * Mailbox server hosting an active copy
    * List of mailbox servers hosting database copies

* Per Database (Non-DAG, pre-DAG Exchange Server)
  * Storage group and database name
  * Server name hosting the database
  * Number of mailboxes and average mailbox size
  * Number of archive mailboxes and average archive mailbox size
  * Database size
  * Database whitespace
  * Disk space available for database and log file volume
  * Backup state for all backup types and last backup age
  * Circular logging enabled
  * Full database and log file paths (mount points or drive letters)

The PowerShell script does not gather information on public folders or analyzes Exchange cluster technologies like Exchange Server 2007/2003 CCR/SCR.

## Requirements

* Exchange Server Management Shell 2010 or newer
* WMI and Remote Registry access from the computer running the script to all internal Exchange Servers
* CSS file for HTML formatting

## Release

* 2.0 : Initial Community Release of the updated original script
* 2.1 : Table header label updated for a more consistent labeling
* 2.2 : Bug fixes and enhancements
  * CCS fixes for Html header tags (issue #5)
  * New script parameter _ShowDriveNames_ added to optionally show drive names for EDB/LOG file paths in database table (issue #4)
  * Exchange organization name added to report header
* 2.4 : Bug fix for empty ExternalUrl parameter values
* 2.5 : Issue #6 fixed - CSS file check added
* 2.6 : (Chris Ntuli)
  * Version-aware role columns - only roles that exist in the environment are shown (no empty CAS/HUB/UM columns for Exchange 2016/2019)
  * Database backup state always shown for all backup types (full, incremental, differential, copy), with a Last Backup (Days Ago) column and highlighting for stale or never-backed-up databases
  * Full database and log file paths always shown (mount points and drive letters)
  * Database activation preferences, currently active (mounted) copy, and active-on-preferred status, with highlighting for dismounted or non-preferred-active databases
  * New Active Directory Site Configuration section (AD sites and site links)
  * DAG witness / alternate witness configuration in DAG headers
  * New Exchange Certificates section with validity highlighting (`-CertificateWarningDays`)
  * New Accepted Domains section
  * Link to the original project added to the report footer
  * New `-MaxBackupAgeDays` and `-CertificateWarningDays` parameters
  * Single-file, zero-touch design - the interactive prompts are built in (the separate run wrapper has been removed); no hard-coded email addresses or SMTP servers
* 2.7 : (Chris Ntuli)
  * Redesigned into a server-centric dashboard - header with KPI severity tiles and one collapsible card per server, replacing the single very wide table
  * Per-volume disk-usage donuts and per-database size-vs-maximum donuts (SVG, no JavaScript)
  * Edition-aware maximum database size (registry override or Standard 1024 GB / Enterprise best-practice ceiling) with approaching-limit warnings and advice
  * Edition database-count reporting (Standard 5 / Enterprise 100) per server and per DAG member, with advice
  * Certificates now exclude self-signed certificates and show issuer and key size
  * New `-StandardMaxDatabaseSizeGB`, `-EnterpriseMaxDatabaseSizeGB`, `-DatabaseSizeWarningPercent`, `-DatabaseSizeCautionPercent` parameters
* 2.8 : (Chris Ntuli)
  * OS update level replaces "OS Service Pack": Windows build with UBR (`10.0.<build>.<UBR>`), display version, and the most recent installed update KB
  * Exchange version shows the full build number, identifies the Cumulative Update, flags whether a newer CU is available, and shows the support lifecycle (Mainstream / Extended / Out of support) - same lifecycle status shown for Windows Server
  * "Preferred / Max active DBs" replaced with real counts: databases active on the server vs. databases it is the preferred (activation-preference 1) owner of, highlighted on mismatch
  * Maintainable reference tables (latest builds, CU maps, support dates) near the top of the script; sourced from the Microsoft [build numbers](https://learn.microsoft.com/en-us/exchange/new-features/build-numbers-and-release-dates) and lifecycle pages - update periodically
  * Exchange Server SE detected separately from Exchange 2019 (same 15.2 family, distinguished by build >= 15.2.2562) and correctly shown as supported under the Modern Lifecycle Policy

## Example Report

Run the script (see *Interactive usage* below) to generate the HTML dashboard for your own environment. The report opens in any web browser.

## Parameters

### HTMLReport

File name to write HTML Report to

### SendMail

Send Mail after completion. Set to $True to enable. If enabled, -MailFrom, -MailTo, -MailServer are mandatory

### MailFrom

Email address to send from. Passed directly to Send-MailMessage as -From

### MailTo

Email address to send to. Passed directly to Send-MailMessage as -To

### MailServer

SMTP Mail server to attempt to send through. Passed directly to Send-MailMessage as -SmtpServer

### ViewEntireForest

By default, true. Set the option in Exchange 2007 or 2010 to view all Exchange servers and recipients in the forest.

### ServerFilter

Use a text based string to filter Exchange Servers by, e.g., NL-*
Note the use of the wildcard (*) character to allow for multiple matches.

### ShowDriveNames

Include drive names of EDB file path and LOG file folder in database report table

### MaxBackupAgeDays

Highlight a database if its most recent backup (of any type) is older than this number of days, or if the database has never been backed up. Default: 1

### CertificateWarningDays

Highlight an Exchange certificate if it expires within this number of days (amber) or has already expired (red). Default: 30

### StandardMaxDatabaseSizeGB

Default maximum database size (GB) for Exchange Standard Edition databases when no per-database registry override is present. Default: 1024

### EnterpriseMaxDatabaseSizeGB

Best-practice ceiling (GB) used for the size-vs-maximum donut and warnings for Exchange Enterprise Edition databases (which have no hard size limit). A per-database registry override always wins. Default: 2048

### DatabaseSizeWarningPercent

Percentage of a database's maximum size at which it is flagged red (approaching the limit). Default: 90

### DatabaseSizeCautionPercent

Percentage of a database's maximum size at which it is flagged amber (caution). Default: 75

### CssFileName

The filename containing the Cascading Style Sheet (CSS) information fpr the HTML report
Default: EnvironmentReport.css

## Interactive usage (recommended)

Run the script with no `-HTMLReport` argument. It prompts for the report file name, whether to email the report, and - only if you choose to email - the SMTP server and the From/To addresses. Nothing is hard-coded.

``` PowerShell
.\Get-ExchangeEnvironmentReport.ps1
```

## Examples

### Example 1

Generate an HTML report and save the report as 'report.html'

``` PowerShell
.\Get-ExchangeEnvironmentReport.ps1 -HTMLReport .\report.html
```

### Example 2

Generate an HTML report and send the result as HTML email with attachment. Supply your own SMTP server and addresses at run time (no values are hard-coded in the script).

``` PowerShell
.\Get-ExchangeEnvironmentReport.ps1 -HTMLReport ExchangeEnvironment.html -SendMail -ViewEntireForest $true -MailFrom <from-address> -MailTo <to-address> -MailServer <smtp-server>
```

### Example 3

Generate the HTML report including EDB and LOG drive names

``` PowerShell
.\Get-ExchangeEnvironmentReport.ps1 -ShowDriveNames -HTMLReport .\report.html
```

### Example 4

Generate the HTML report and highlight databases whose last full backup is older than 3 days

``` PowerShell
.\Get-ExchangeEnvironmentReport.ps1 -HTMLReport .\report.html -MaxBackupAgeDays 3
```

### Example 5

Generate the HTML report using a custom CSS file

``` PowerShell
.\Get-ExchangeEnvironmentReport.ps1 -HTMLReport .\report.html -CssFileName MyCustomCSSFile.css
```

## Note

THIS CODE IS MADE AVAILABLE AS IS, WITHOUT WARRANTY OF ANY KIND. THE ENTIRE
RISK OF THE USE OR THE RESULTS FROM THE USE OF THIS CODE REMAINS WITH THE USER.

## Credits

Maintained by **Chris Ntuli**.

This project: [https://github.com/ntulics/PowerShell/tree/main/Get-ExchangeEnvironmentReport](https://github.com/ntulics/PowerShell/tree/main/Get-ExchangeEnvironmentReport)

Based on the original project: [https://github.com/Apoc70/Get-ExchangeEnvironmentReport](https://github.com/Apoc70/Get-ExchangeEnvironmentReport)