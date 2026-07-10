# Sending email from apps & multifunction devices (MFDs) via Microsoft 365

How to configure mail flow so a printer / scanner / line-of-business app can send
email through Microsoft 365 (Exchange Online) — for **internal-only** delivery and
for **internal + external** delivery — with the requirements, limits, and gotchas
for each method.

Based on Microsoft's guidance:
[How to set up a multifunction device or application to send email using Microsoft 365 or Office 365](https://learn.microsoft.com/en-us/exchange/mail-flow-best-practices/how-to-set-up-a-multifunction-device-or-application-to-send-email-using-microsoft-365-or-office-365).

> Replace `contoso.com` / `contoso-com.mail.protection.outlook.com` and any IP
> addresses below with your own values. Nothing here is specific to one tenant.

---

## 1. Pick a method

Microsoft supports three ways for a device/app to send through Microsoft 365. Choose
by **who the recipients are** and **whether the device can sign in**.

| You need… | Use | Auth | Sends to |
|-----------|-----|------|----------|
| Simplest, device can sign in, needs **external** recipients | **SMTP AUTH client submission** | Mailbox login | Internal **and** external |
| Send only to people **in your own domains** | **Direct send** | None | Internal only |
| Higher volume / many devices, needs **external**, no per-mailbox login | **SMTP relay (connector)** | IP or certificate | Internal **and** external |
| **High volume**, mostly **internal** app/device mail | **High Volume Email (HVE)** | HVE account login | Internal (external needs a licensed HVE tier) |

Quick decision:

- **Internal only** → **Direct send** (no mailbox, no connector). Simplest.
- **Internal + external, one device** → **SMTP AUTH** with a dedicated licensed mailbox.
- **Internal + external, many devices / higher volume** → **SMTP relay** via a connector.
- **High volume, mostly internal** → **High Volume Email (HVE)** — Microsoft's purpose-built
  service for bulk internal app/device mail (see §5a).

---

## 2. Common prerequisites

- The device/app must support **SMTP** and, for authenticated/TLS methods, **TLS 1.2+**
  (Microsoft 365 rejects TLS 1.0/1.1 — update firmware if the device is old).
- Outbound network path open to the chosen port (**587** for SMTP AUTH, **25** for
  direct send / relay). **Port 25 is frequently blocked outbound by ISPs/firewalls.**
- A verified **accepted domain** in the tenant (e.g. `contoso.com`).
- Your public egress IP should have good reputation (see §7 — this is what bites most
  real deployments, e.g. a **Spamhaus** listing silently dropping mail).

---

## 3. Option 1 — SMTP AUTH client submission  *(internal + external)*

The device authenticates as a real mailbox and submits mail to the client submission
endpoint. This is the most flexible option and the only one that works from a
**dynamic IP**.

### Settings

| Field | Value |
|-------|-------|
| Server / smart host | `smtp.office365.com` |
| Port | **587** (recommended; 25 also works for submission) |
| Encryption | **STARTTLS** (TLS 1.2+) |
| Username | a **licensed** mailbox, full UPN e.g. `scanner@contoso.com` |
| Password | that mailbox's password (or an **app password** if MFA) |
| From / sender | **must** match the authenticated mailbox (or an address it can *Send As*) |

### Setup steps

1. **Create/choose a mailbox** for the device and assign it a license (e.g. a cheap
   Exchange Online plan). A shared mailbox will **not** work here — it has no license
   and sign-in is blocked.
2. **Enable SMTP AUTH** for that mailbox. It's **disabled by default** in tenants
   created after ~2020.
   - EAC → **Recipients → Mailboxes → (mailbox) → Manage email apps settings** →
     tick **Authenticated SMTP**, **or**
   - PowerShell:
     ```powershell
     Set-CASMailbox -Identity scanner@contoso.com -SmtpClientAuthenticationDisabled $false
     ```
   - Ensure it isn't disabled **org-wide**:
     ```powershell
     Get-TransportConfig | Select-Object SmtpClientAuthenticationDisabled
     ```
3. **Set the device's From address** to the same mailbox (`scanner@contoso.com`).
4. If the mailbox has **MFA / security defaults**, either use an **app password**, or
   move to **OAuth** where the device supports it (see §10).

### Limits (client submission)

- **30 messages per minute**
- **10,000 recipients per day**
- Standard Exchange Online message size limits apply.

### Limitations

- Requires a **licensed** mailbox (a recurring cost).
- **Basic-auth** SMTP AUTH is on a **deprecation path** — plan for OAuth or High
  Volume Email (§10).
- Not for **bulk/marketing** mail.
- If the From ≠ the authenticated mailbox, Microsoft 365 treats it as **spoofing**
  (quarantine / drop).

---

## 4. Option 2 — Direct send  *(internal only)*

The device sends straight to your tenant's **MX / protection endpoint** with **no
authentication**. Delivers **only to recipients in your own accepted domains** — it
**cannot** send to external addresses.

### Settings

| Field | Value |
|-------|-------|
| Server / smart host | your MX host, e.g. `contoso-com.mail.protection.outlook.com` |
| Port | **25** |
| Encryption | None, or STARTTLS if the device supports it (opportunistic) |
| Auth | **None** |
| From / sender | an address in your **accepted domain** (e.g. `scanner@contoso.com`) |

> Find the MX host: it's your domain's MX record. For Microsoft 365 it's
> `<domain-with-dashes>.mail.protection.outlook.com`. Confirm with
> `Resolve-DnsName contoso.com -Type MX` or `nslookup -type=MX contoso.com`.

### Setup steps

1. Give the device a **static public IP** for its outbound traffic (or a stable NAT
   egress IP).
2. Point the device at the **MX host**, port **25**, no auth.
3. **Update SPF** to include that IP so the mail passes authentication (see §7).
4. Set the **From** to a real address in your accepted domain.

### Limits

- No 30/min submission limit, but subject to Exchange Online receiving throttles and
  anti-spam. Fine for **low/moderate** scan-to-email volume; not for bulk.

### Limitations

- **External recipients are not delivered** — internal only.
- More likely to be **filtered/junked** if SPF/reputation isn't right.
- **Port 25** must be open outbound (often blocked).
- No delivery guarantees / limited bounce handling; sensitive to **IP reputation**
  (a blocklisted egress IP → mail silently dropped, nothing in message trace).

---

## 5. Option 3 — SMTP relay via a connector  *(internal + external)*

Like direct send (same host/port, no per-mailbox login) but a **connector** in
Exchange Online trusts your device's source, which **allows relay to external
recipients**. Best for **many devices** or **higher volume** without managing
mailbox credentials on each device.

### Settings

| Field | Value |
|-------|-------|
| Server / smart host | your MX host, e.g. `contoso-com.mail.protection.outlook.com` |
| Port | **25** |
| Encryption | STARTTLS recommended |
| Auth | **None on the device** — the tenant authenticates it by **IP** or **certificate** |
| From / sender | an address in an **accepted domain** |

### Setup steps

1. Get the device/app's **static public IP** (must not be shared with other, untrusted
   senders). Alternatively, use a **TLS certificate** whose subject/SAN matches your
   domain.
2. In **EAC → Mail flow → Connectors → + Add a connector**:
   - **From:** *Your organization's email server*  **To:** *Office 365*
   - Name the connector.
   - Authenticate the sender by **verifying the IP address** (add the device's public
     IP), **or** by **certificate** (subject name matching your domain).
   - Save.
3. Point the device at the **MX host**, port **25**.
4. **Update SPF** to include that IP (§7).

### Limits

- Higher than client submission, but external relay still counts against your tenant's
  reputation and Exchange Online limits. See the service limits doc (§9).

### Limitations

- Requires a **tenant admin** to create the connector.
- Needs a **static, dedicated public IP** (or a valid certificate).
- Misconfigured connectors can create an **open relay** risk — scope the IP tightly.

---

## 5a. High Volume Email (HVE)  *(high volume, internal)*

**High Volume Email (HVE)** is Microsoft's purpose-built service for **high-volume,
internal** app/device email (notifications, reports, scan-to-email at scale) — a
modern replacement for using SMTP relay for bulk internal mail. You create dedicated
**HVE accounts** (not full mailboxes) and the device signs in with those.

### Settings

| Field | Value |
|-------|-------|
| Server / smart host | `smtp-hve.office365.com` |
| Port | **587** |
| Encryption | **STARTTLS** (TLS 1.2+) |
| Username | an **HVE account** you create in the Exchange admin center |
| Password | that account's secret (basic auth today; **OAuth** is the recommended direction) |
| From / sender | an address in your **accepted domain** |

### Setup steps

1. In the **Exchange admin center**, create one or more **High Volume Email accounts**.
2. Point the device at `smtp-hve.office365.com`, port **587**, STARTTLS, and sign in
   with the HVE account.
3. Configure **SPF/DKIM/DMARC** for the sending domain (§7).

### Limits & scope

- Designed for **much higher volume** than client submission's 30/min · 10,000/day.
- **Internal** recipients are the primary scenario; **external** sending requires a
  **licensed** HVE tier. Confirm current recipient/volume caps in the official doc
  (Microsoft adjusts these).

### Limitations

- Requires creating and managing **HVE accounts**.
- Feature availability, exact limits, and external-send licensing evolve — **verify
  against the live doc** before you design around specific numbers.
- Official documentation:
  [High Volume Email for Microsoft 365](https://learn.microsoft.com/en-us/exchange/mail-flow-best-practices/high-volume-mails-m365).

---

## 6. Side-by-side comparison

| Capability | SMTP AUTH submission | Direct send | SMTP relay (connector) | High Volume Email |
|------------|:--------------------:|:-----------:|:----------------------:|:-----------------:|
| Endpoint | `smtp.office365.com` | MX host | MX host | `smtp-hve.office365.com` |
| Port | 587 | 25 | 25 | 587 |
| TLS | STARTTLS (required) | optional | STARTTLS (recommended) | STARTTLS (required) |
| Authentication | mailbox login | none | IP / certificate connector | HVE account login |
| Send to your domains | ✅ | ✅ | ✅ | ✅ |
| Relay to **external** | ✅ | ❌ | ✅ | ⚠️ (licensed tier) |
| Needs a **licensed mailbox** | ✅ (one) | ❌ | ❌ | ❌ (HVE account) |
| Works from **dynamic IP** | ✅ | ⚠️ (static recommended) | ❌ (static/cert required) | ✅ |
| Needs **admin connector** | ❌ | ❌ | ✅ | ❌ |
| Rate limit | 30/min, 10k/day | server throttles | server throttles | high (see doc) |
| Good for | one device, internal+external | internal-only | many devices / higher volume | high-volume internal |

---

## 7. DNS & deliverability (do this regardless of method)

Getting **accepted** by Microsoft 365 (a `250`) is not the same as getting
**delivered** to the Inbox. These control whether mail lands, gets junked, or is
silently dropped:

- **SPF** — add every public IP your device sends from. For direct send / relay:
  ```
  v=spf1 ip4:203.0.113.10 include:spf.protection.outlook.com -all
  ```
  ([Configure SPF](https://learn.microsoft.com/en-us/defender-office-365/email-authentication-spf-configure))
- **DKIM / DMARC** — configure for the sending domain so relayed/direct-send mail
  aligns and isn't treated as spoofing.
- **Reverse DNS (PTR)** — the egress IP should have a matching PTR record.
- **IP reputation / blocklists** — a listing on **Spamhaus** or similar causes
  Microsoft 365 to **reject or silently drop** mail; it won't appear in message trace
  and the device may report no error. Check and delist:
  - Spamhaus lookup / removal: <https://check.spamhaus.org/>
  - Prefer a **dedicated, known-good egress IP** for device mail so a shared NAT IP's
    reputation can't sink your scans. Authenticated submission (Option 1) is the least
    reputation-sensitive because it's tied to a mailbox, not just an IP.

---

## 8. Testing

Use the tester scripts in this folder to reproduce each method and see the full SMTP
transcript (`235` auth OK, `250` accepted, `535`/`550`/`504` failures):

```powershell
# Authenticated submission (Option 1):
.\Test-ScanToEmail.ps1 -From scanner@contoso.com -To user@gmail.com `
    -SmtpServer smtp.office365.com -Send Auth -Port 587 -Encryption StartTls -SimulateScan

# High Volume Email (§5a):
.\Test-ScanToEmail.ps1 -From scanner@contoso.com -To staff@contoso.com `
    -SmtpServer smtp-hve.office365.com -Send Auth -Port 587 -Encryption StartTls

# Direct send (Option 2), host from the domain's MX record:
.\Test-ScanToEmail.ps1 -From scanner@contoso.com -To staff@contoso.com -UseMxRecord -Send NoAuth
```

Or run the GUI **SMTP Diagnostics and Testing Tool** (`.\Test-ScanToEmail.UI.ps1`),
which has one-click provider presets — **Microsoft 365**, **M365 High Volume Email**,
SendGrid, Amazon SES, Postmark, Mailgun, SMTP2GO, Brevo, Gmail/Workspace, and a
Custom/Lookup-MX option. See [ReadMe.md](ReadMe.md).

Then confirm delivery with a **message trace**:

```powershell
Connect-ExchangeOnline
Get-MessageTraceV2 -SenderAddress scanner@contoso.com `
    -StartDate (Get-Date).ToUniversalTime().AddHours(-2) -EndDate (Get-Date).ToUniversalTime().AddMinutes(5) |
    Sort-Object Received | Format-Table Received, RecipientAddress, Subject, Status, Detail -AutoSize
```

- **`250` at end-of-DATA but no trace row** → Microsoft 365 never accepted it →
  IP reputation / SPF / blocklist (§7), or a network path problem.
- **Trace shows `Delivered`** but not in Inbox → check **Junk**.
- **Trace shows `Quarantined` / `FilteredAsSpam`** → release from Quarantine and tune
  anti-spam / SPF.

---

## 9. Common error codes

| Code | Meaning | Fix |
|------|---------|-----|
| `504 5.7.4 Unrecognized authentication type` | You tried to **authenticate against the MX host** | Use `smtp.office365.com:587` for auth; the MX host is no-auth only |
| `535 5.7.x Authentication unsuccessful` | Login failed | Enable SMTP AUTH on the mailbox; check password; use an **app password** if MFA |
| `550 5.7.1 / 5.7.64 Unable to relay` | Relay denied | External recipient on **direct send**, or no **connector** for relay |
| `550 5.7.x` spoof / SPF | Sender not permitted | Fix **From** to an accepted-domain address; fix **SPF** |
| Timeout on connect | Port blocked / wrong host | Port **25** often blocked outbound; verify host and firewall |

---

## 10. Deprecations & modern options

- **Basic authentication for SMTP AUTH (client submission)** is being phased out.
  Where the device supports it, prefer **OAuth 2.0** for SMTP AUTH.
  ([Authenticated client SMTP submission](https://learn.microsoft.com/en-us/exchange/clients-and-mobile-in-exchange-online/authenticated-client-smtp-submission))
- **High Volume Email (HVE)** for Microsoft 365 is Microsoft's option for
  **high-volume internal** app/device mail, replacing older relay patterns for that
  scenario — see **§5a** above. ([High Volume Email](https://learn.microsoft.com/en-us/exchange/mail-flow-best-practices/high-volume-mails-m365))
- Verify current **limits and deprecation dates against the live docs** — Microsoft
  changes these periodically.

---

## 11. Official Microsoft documentation

- **Set up a device/app to send mail (all three options)** —
  <https://learn.microsoft.com/en-us/exchange/mail-flow-best-practices/how-to-set-up-a-multifunction-device-or-application-to-send-email-using-microsoft-365-or-office-365>
- **Authenticated client SMTP submission (Option 1, enabling SMTP AUTH)** —
  <https://learn.microsoft.com/en-us/exchange/clients-and-mobile-in-exchange-online/authenticated-client-smtp-submission>
- **Set up connectors to route mail (Option 3 relay)** —
  <https://learn.microsoft.com/en-us/exchange/mail-flow-best-practices/use-connectors-to-configure-mail-flow/set-up-connectors-to-route-mail>
- **Configure SPF** —
  <https://learn.microsoft.com/en-us/defender-office-365/email-authentication-spf-configure>
- **DKIM** —
  <https://learn.microsoft.com/en-us/defender-office-365/email-authentication-dkim-configure>
- **DMARC** —
  <https://learn.microsoft.com/en-us/defender-office-365/email-authentication-dmarc-configure>
- **Exchange Online limits (sending/receiving)** —
  <https://learn.microsoft.com/en-us/office365/servicedescriptions/exchange-online-service-description/exchange-online-limits>
- **High Volume Email for Microsoft 365** —
  <https://learn.microsoft.com/en-us/exchange/mail-flow-best-practices/high-volume-mails-m365>
- **Run a message trace** —
  <https://learn.microsoft.com/en-us/exchange/monitoring/trace-an-email-message/message-trace-modern-eac>

*Links current as of writing; Microsoft occasionally moves docs — search the title if a link 404s.*
