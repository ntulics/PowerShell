# Inactive Mailbox Restore Tool

A Windows GUI (PowerShell WinForms) tool for merging Exchange Online **inactive mailbox** content
into a **reinstated user's** mailbox — for cases where a former employee's mailbox is being kept
under retention/litigation hold, and that person later returns after their original account (and
its 30-day Entra ID recovery window) is long gone.

Single file, no install required beyond the prerequisites below. Safe to share as-is — no tenant
or customer data is hardcoded in the script.

---

## Requirements

- **Windows** — the GUI uses WinForms, which is Windows-only (won't run on macOS/Linux, even with
  PowerShell 7 installed).
- **PowerShell 5.1** (built into Windows) **or PowerShell 7+**.
- **Exchange Admin rights** in the target tenant, or a **GDAP** delegated admin relationship if
  you're managing it as an external/MSP admin.
- **ExchangeOnlineManagement module** — you don't need to install this yourself; the script checks
  for it on startup and offers to install it (`Install-Module -Scope CurrentUser`) if missing.

## Running it

1. Right-click `Restore-InactiveMailbox.ps1` → **Run with PowerShell** (or run it from a PowerShell
   prompt: `.\Restore-InactiveMailbox.ps1`).
2. If prompted, allow the ExchangeOnlineManagement module to install.
3. Click **Sign In / Connect** and complete the Microsoft sign-in in the browser window that opens.
   - The tool automatically detects which tenant you're connected to (its display name and
     `.onmicrosoft.com` domain) — you don't need to type anything for a normal, direct sign-in.
   - **Only if you're connecting via GDAP** (signing in once with your own partner/admin
     credentials to act on a customer tenant): tick **"GDAP: act on customer tenant"** and enter
     that customer's `*.onmicrosoft.com` domain. This can't be auto-detected because the target
     tenant isn't implied by your own login.
   - Tenants you've signed into before appear in the "recent" dropdown next to the GDAP field, as
     a convenience — this list is stored locally in `tenants.json` next to the script and is never
     required.

## Using the tool

1. **Load Inactive Mailboxes** — populates the grid with every inactive mailbox in the connected
   tenant (name, SMTP address, GUID, soft-deleted date, litigation hold status).
2. Click a row to see full details, including its `LegacyExchangeDN`.
3. Enter the **reinstated user's** mailbox (UPN or SMTP address) and click **Verify Target**.
   - The tool checks whether the target is **cloud-only** or **synced from on-prem AD via Entra
     Connect**, and tells you which.
4. **Add X500 Proxy to Target**
   - *Cloud-only target:* this button adds the inactive mailbox's `LegacyExchangeDN` as an X500
     proxy address directly, via `Set-Mailbox`. This preserves old replies/rules resolving to the
     right person.
   - *Synced target:* this button is disabled. Instead you'll see the exact command to run
     **on-premises** against Active Directory:
     ```powershell
     Set-ADUser -Identity <sAMAccountName> -Add @{proxyAddresses='X500:<LegacyExchangeDN>'}
     ```
     Adding it via `Set-Mailbox` on a synced mailbox would just get overwritten on the next Entra
     Connect sync cycle — it has to be set at the AD source.
5. **Start Restore Request** — runs `New-MailboxRestoreRequest` to merge the inactive mailbox's
   content into the target. You'll be asked to confirm; for synced targets, you're also asked to
   confirm the on-prem proxy step has already synced through.
   - Before starting, the tool writes a full metadata snapshot of the inactive mailbox to the log
     file, for chain-of-custody purposes.
   - **Allow legacy DN mismatch** — see below.
6. **Check Restore Status** — polls `Get-MailboxRestoreRequestStatistics` for progress
   (percent complete, bytes transferred). Once the request shows **Completed**, Exchange Online
   automatically removes the now-empty inactive mailbox.

## "Allow legacy DN mismatch" option

By default, `New-MailboxRestoreRequest` checks that the source mailbox's `LegacyExchangeDN` is
registered as an X500 proxy address on the target mailbox before it will proceed. That's the same
check the **Add X500 Proxy** step exists to satisfy — Exchange keeps this pairing so that old
internal mail addressed to the former identity (replies to old messages, address book entries
cached on other mailboxes, etc.) still resolves to the new mailbox after the merge.

If that X500 proxy isn't in place — most commonly because the on-prem step for a synced mailbox
hasn't synced through yet, or the step was skipped — the restore fails with an error like:

```
Source mailbox's legacyExchangeDN '...' doesn't match the legacyExchangeDN or X500 proxy for
target mailbox '...'. Use the 'AllowLegacyDNMismatch' switch if you want to allow this operation.
```

The tool now shows this error's meaning directly in a dialog if it happens, and offers a checkbox,
**"Allow legacy DN mismatch (bypass X500/LegacyExchangeDN check)"**, next to the restore button.
Ticking it adds Exchange's `-AllowLegacyDNMismatch` switch to the restore request, which skips that
check and lets the restore proceed anyway.

**What you're trading off by using it:** the mailbox content still restores correctly either way —
this switch only affects whether *old* internal mail addressed to the former identity keeps
resolving to the new mailbox afterward. If that legacy routing doesn't matter for a given case (or
you'll add the X500 proxy separately later), it's safe to use. If it does matter, it's better to
complete the X500 proxy step (on-prem or via `Set-Mailbox`, per step 4 above) and let it sync
through first, rather than bypassing the check.

## Logs and local files

Everything below is created **next to the script**, on the machine you run it from — nothing is
sent anywhere else:

- `tenants.json` — remembered tenant names/domains, for the "recent" dropdown only.
- `Restore-InactiveMailbox_<tenant>_<date>.log` — timestamped log of every connection, lookup, and
  action (especially the pre-restore snapshot and restore start/completion), per tenant per day.

If you're handing this script to someone else, share only the `.ps1` file — don't include your own
`tenants.json` or log files.

## Troubleshooting

- **"Failed to connect" / module errors on first run** — make sure you have internet access to
  the PowerShell Gallery, or install manually beforehand:
  `Install-Module ExchangeOnlineManagement -Scope CurrentUser -Force`
- **GDAP connection fails** — double-check the customer's tenant domain is their initial
  `*.onmicrosoft.com` domain, not a custom domain (e.g. not `contoso.com`).
- **Restore request stays at 0% for a while** — this is normal for large mailboxes; Exchange Online
  queues restore requests and processes them in the background. Keep clicking **Check Restore
  Status** periodically.
- **Auto-expanding archive on the source mailbox** — `New-MailboxRestoreRequest` doesn't support
  these; you'd need a Content Search / eDiscovery export instead.
