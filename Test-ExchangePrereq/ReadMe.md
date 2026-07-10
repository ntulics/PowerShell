# Test-ExchangePrereq.ps1

A **read-only** pre-flight readiness check for **Exchange Server 2019** setup /
`PrepareAD`. It reproduces the checks Exchange setup's prerequisite analysis makes —
plus the surrounding conditions that commonly break it — so you can clear them
*before* re-running `Setup.exe`.

It was built to diagnose the two classic `PrepareAD` blockers:

- **`RebootPending`** — a pending reboot blocks all AD preparation.
- **`AdUpdateRequired`** — *"the current user account doesn't have the permissions
  required even though it's a member of the 'Enterprise Admins' group."* This
  misleading message is usually a **stale security token** (the account was added
  to the required groups but the session was never logged off/rebooted), a
  **non-elevated** shell, or **AD replication lag**.

> This script changes **nothing** — no registry, AD, or service writes. Safe to
> run as many times as you like.

---

## What it checks

| # | Section | Purpose |
|---|---------|---------|
| 1 | **Elevation** | Confirms the shell is elevated. A non-elevated session alone can trip the "no permission" check. |
| 2 | **Pending reboot** | The `RebootPending` blocker. Inspects CBS, Windows Update, `PendingFileRenameOperations`, pending computer-rename, Server Manager, and the SCCM client — and prints *which* key is set. |
| 3 | **Account rights — token vs AD** | The heart of `AdUpdateRequired`. Compares what your **current session token** carries against what **AD** says you're a member of. Flags the case where you're in Schema/Enterprise Admins or Organization Management *in AD* but the group is **missing from your token** (→ log off/reboot to refresh). |
| 4 | **FSMO / Schema Master** | Identifies the Schema Master (setup must reach it) and tests reachability. |
| 5 | **AD replication** | Parses `repadmin /replsummary` for non-zero failures and warns on large replication deltas (inter-site lag). |
| 6 | **Site / DC** | Shows the server's AD site and the DC it locates. |
| 7 | **Local privilege — Manage auditing and security log** | Checks that the **current process token** holds `SeSecurityPrivilege` **and** that the **local** security policy grants "Manage auditing and security log" to **Administrators**. Setup's `Set-LocalPermissions` writes SACLs on the local box and fails with `PrivilegeNotHeldException` when a hardening baseline/GPO strips this right — even in an elevated shell. This is the local counterpart to section 8. |
| 8 | **DC security policy (RSoP)** | Checks the **resultant** "Manage auditing and security log" (`SeSecurityPrivilege`) user right on every domain controller. Exchange setup grants this to the **Exchange Servers** group via the Default Domain Controllers Policy; a custom GPO that overrides the default and drops the group **breaks setup/PrepareAD**. Flags DCs where the Exchange group is missing and names the **overriding GPO** when RSoP reports it. |
| 9 | **AD Exchange versions** | Reads live schema `rangeUpper`, org and domain `objectVersion`, and compares against the target CU so you can see exactly what `PrepareAD`/`PrepareDomain` still needs to raise. |
| 10 | **OS prerequisites** | .NET Framework 4.8, Visual C++ 2012/2013 redistributables, RSAT-ADDS tools. |
| 11 | **Environment** | Free disk space on the install drive, PowerShell execution policy, **time skew vs the PDC** (Kerberos 5-minute limit — another silent permission-killer), and NetBIOS name length. |

Each check prints `PASS` / `WARN` / `FAIL` / `INFO`, and the script ends with a
summary that lists any hard blockers and the recommended remediation order.

### About the local-privilege check (section 7)

This catches the setup failure:

```
System.Security.AccessControl.PrivilegeNotHeldException: The process does not
possess the 'SeSecurityPrivilege' privilege which is required for this operation.
   at Microsoft.Exchange.Management.Deployment.SetLocalPermissions.InternalProcessRecord()
```

`Set-LocalPermissions` runs on the **local** Exchange server and writes SACLs
(audit entries), which require the `SeSecurityPrivilege` right — the friendly name
is **"Manage auditing and security log"**. Running elevated is **not** enough: the
right must be granted in the local security policy **and** present in your logon
token. A CIS/STIG/DISA hardening baseline or a GPO commonly strips **Administrators**
out of it. The check:

1. Reads the **current process token** (`whoami /priv`) — the exact thing setup
   tests — and `FAIL`s if `SeSecurityPrivilege` is absent.
2. Exports the **local** security policy (`secedit /export /areas USER_RIGHTS`),
   resolves the SIDs granted the right, and `FAIL`s if **Administrators** is missing
   (or the assignment is empty), naming who currently holds it.

To fix a `FAIL`: add **Administrators** to **Local Security Policy (`secpol.msc`) →
Local Policies → User Rights Assignment → Manage auditing and security log** — or,
if a GPO controls it, fix the winning GPO (`gpresult /h rsop.html` to find it) and
`gpupdate /force`. Then **log off and back on** (privilege changes only take effect
in a new logon token) and re-run this script; the token check should flip to `PASS`
before you retry Setup.

### About the DC security-policy check (section 8)

This is the check for the *"Manage auditing and security log"* override. It:

1. Discovers all domain controllers (`Get-ADDomainController`).
2. Reads the **Resultant Set of Policy** for each DC — preferring
   `Get-GPResultantSetOfPolicy` (which also names the *winning* GPO), and falling
   back to `secedit /export /areas USER_RIGHTS` over WinRM if the GroupPolicy
   module isn't installed.
3. Confirms the effective `SeSecurityPrivilege` right still includes the
   **Exchange Servers** group (matched by name **or** SID) and **Administrators**.
4. If the Exchange group is missing, reports `FAIL` and — when RSoP provides it —
   names the GPO that overrode the Default Domain Controllers Policy, so you know
   exactly where to fix it.

To fix a `FAIL`: edit the winning GPO (or the Default Domain Controllers Policy)
so **Computer Configuration → Policies → Windows Settings → Security Settings →
Local Policies → User Rights Assignment → Manage auditing and security log**
grants both **Administrators** and **Exchange Servers**, then `gpupdate /force`
on the DCs and re-run this script.

## Requirements

- **Windows Server** hosting (or destined to host) Exchange Server 2019
- **Windows PowerShell 5.1**, run **as Administrator**, signed in as the account
  you'll use for Setup
- The **ActiveDirectory** module (`RSAT-AD-PowerShell`) for the AD-vs-token,
  FSMO, version, and DC-policy checks. The **GroupPolicy** module
  (`RSAT-GPMC` / GPMC) enriches the DC-policy check with the winning GPO name;
  without it the check falls back to `secedit` over WinRM. Missing modules cause
  those sections to degrade or skip gracefully.

## Usage

**Zero-touch — no editing required.** The install drive, Exchange organization
name, domain/forest, and the target CU versions are all discovered from the
environment at runtime, so the script runs unmodified in any Exchange 2019 forest:

```powershell
.\Test-ExchangePrereq.ps1
```

All parameters are optional and only for overrides:

```powershell
.\Test-ExchangePrereq.ps1 -InstallDrive 'E:' -OrganizationName 'Contoso'
```

If execution policy blocks the script:

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\Test-ExchangePrereq.ps1
```

The header prints what it discovered, e.g.
`Discovered: InstallDrive=C:  Org=Contoso  Build=15.2.792`.

### Parameters (all optional)

| Parameter | Default | Description |
|-----------|---------|-------------|
| `-InstallDrive` | *auto* | Discovered from the Exchange install path (registry / `$env:ExchangeInstallPath`), else the system drive. |
| `-OrganizationName` | *auto* | Discovered from Active Directory (the `msExchOrganizationContainer`). |
| `-RequiredGroups` | `Schema Admins, Enterprise Admins, Organization Management` | Groups the account must hold for `PrepareAD`. |
| `-TargetSchema` / `-TargetOrg` / `-TargetDomain` | *auto* | Override the AD version targets. Normally auto-selected from the installed build. |

## Target CU versions (auto-selected)

Section 9 compares the live AD values (schema `rangeUpper`, org and domain
`objectVersion`) against the target for your **installed Exchange build**, chosen
automatically from a built-in table (Exchange 2019 CU8–CU15). If the exact build
isn't listed, the newest known target is used and a note is printed — or pass
`-TargetSchema` / `-TargetOrg` / `-TargetDomain` to set them explicitly. No
in-script editing needed.

## Recommended workflow

1. Run the script and read the summary.
2. If it reports a **pending reboot** or a **token/membership mismatch**:
   **reboot → log back in fresh → open an elevated shell → re-run the script**
   and confirm those items flip to `PASS`.
3. When all blockers are clear, run the exact `Setup.exe` command the script
   prints in its summary (it fills in the discovered install drive and, if this
   is a first-time org, the organization name):
   ```powershell
   <InstallDrive>\Setup.exe /IAcceptExchangeServerLicenseTerms_DiagnosticDataON /PrepareAD
   ```

## Notes

- `Get-CimInstance Win32_Product` (the VC++ check in section 10) is slightly slow
  and triggers an MSI consistency check on some servers. If it hangs, comment out
  that single line — the rest of the script is instant.
- Nothing is hardcoded: server, domain, forest, organization, install drive and
  CU targets are all read from the environment, so the script needs no editing
  before it runs in a different environment.

## Disclaimer

Provided as-is. It only reads state, but you remain responsible for validating
the findings against your environment before running Setup.
