# SMTP Diagnostics and Testing Tool

Submit a test message to **any SMTP provider** and print the **full SMTP transcript**,
so you can see exactly why a send fails — or why it's accepted but never arrives.
Great for setting up scan-to-email on a multifunction device, wiring an app up to a
relay, or just proving a provider's host/port/credentials work.

It speaks SMTP by hand over a raw socket and logs every line, so the real server
codes show up verbatim: `235` auth OK, `250` accepted, **`535`** auth failed,
**`550` / `5.7.x`** relay or spoof/policy denied, **`504`** no auth on this host.

The GUI ships one-click **provider presets** — **Microsoft 365** (default),
**M365 High Volume Email (HVE)**, SendGrid, Amazon SES, Postmark, Mailgun, SMTP2GO,
Brevo, Gmail / Workspace — plus **Custom / Lookup MX** for any other host or for
direct send to a domain's mail servers.

> **Configuring Microsoft 365 mail flow?** See
> [M365-MailFlow-for-Apps-and-MFDs.md](M365-MailFlow-for-Apps-and-MFDs.md) — a full
> reference for the send methods (SMTP AUTH, direct send, SMTP relay, **High Volume
> Email**), internal vs internal+external, limits, SPF/deliverability, and official
> MS doc links.

## Interactive walkthrough

Run it with just `-From` and `-To` and it asks you the same things the printer's
E-mail TX (SMTP) screen does, one prompt at a time:

1. **SMTP Server Address** — look it up from the From domain's **MX record**, or
   type the host **manually**.
2. **Sending method** — **SMTP AUTH** (sign in) or **No authentication**
   (direct send / relay).
3. **If AUTH → port + security** — STARTTLS/587, STARTTLS/25, SSL/465, none/25,
   or a **custom** port + SSL/TLS mode.
4. **If AUTH → username + password** (use an **app password** if the mailbox has MFA).

These cover the three approaches in Microsoft's
[How to set up a multifunction device or application to send email using Microsoft 365 or Office 365](https://learn.microsoft.com/en-us/exchange/mail-flow-best-practices/how-to-set-up-a-multifunction-device-or-application-to-send-email-using-microsoft-365-or-office-365):

| Approach | Host | Port | TLS | Auth | Sends to |
|----------|------|------|-----|------|----------|
| SMTP AUTH client submission | `smtp.office365.com` | 587 | STARTTLS | mailbox login | internal **and** external |
| Direct send | From domain's **MX** host | 25 | none | none | your **own** domains only |
| SMTP relay | MX or manual host | 25 | none | none | external, if a connector trusts this IP |

Any prompt can be pre-answered on the command line — `-SmtpServer` / `-UseMxRecord`,
`-Send Auth|NoAuth`, `-Port`, `-Encryption`, `-Credential` — so the same script runs
unattended and can reproduce a specific printer screen field-for-field.

## GUI — SMTP Diagnostics and Testing Tool

`Test-ScanToEmail.UI.ps1` is a **self-contained WPF** app. Pick a **provider preset**
(radio buttons: **Microsoft 365** default, **M365 High Volume Email**, SendGrid,
Amazon SES, Postmark, Mailgun, SMTP2GO, Brevo, Gmail/Workspace, or **Custom / Lookup
MX**) to auto-fill host/port/TLS/auth, or type a host / look it up from a domain's MX
record. Then send a test and read the full server conversation in a dark, colour-coded
transcript pane. It **embeds the SMTP engine**, so it's a single file — copy it
anywhere and run it, no other files required.

```powershell
# Windows PowerShell (already STA):
.\Test-ScanToEmail.UI.ps1

# PowerShell 7 is MTA, so force STA:
pwsh -STA -File .\Test-ScanToEmail.UI.ps1

# Or right-click the file in Explorer -> Run with PowerShell.
```

Selecting a provider fills the server/port/SSL-TLS/auth defaults (and shows a per-
provider hint, e.g. SendGrid's username is literally `apikey`). Toggling **SMTP
Authentication** shows/hides the User ID / Password fields. Transcript colours:
**blue** = client, **green** = server reply, **red** = error.

## Requirements

- Windows PowerShell 5.1 or PowerShell 7+.
- Outbound access to the chosen port. **Port 25 is frequently blocked outbound** by
  ISPs/firewalls — a timeout on DirectSend usually means that, not a mailbox problem.

## Examples

```powershell
# Interactive — answer the prompts (server via MX or manual, auth or not, port, creds).
.\Test-ScanToEmail.ps1 -From scanner@contoso.com -To staff@contoso.com -SimulateScan

# Authenticated client submission (internal + external), fully unattended.
.\Test-ScanToEmail.ps1 -From scanner@contoso.com -To someone@gmail.com `
    -SmtpServer smtp.office365.com -Send Auth -Port 587 -Encryption StartTls `
    -Credential (Get-Credential) -SimulateScan

# Direct send to an internal recipient; host taken from the domain's MX record.
.\Test-ScanToEmail.ps1 -From scanner@contoso.com -To staff@contoso.com `
    -UseMxRecord -Send NoAuth

# Reproduce the exact printer screen: MX host, port 25, SSL/TLS Off, no auth.
.\Test-ScanToEmail.ps1 -From scanner@contoso.com -To staff@contoso.com `
    -UseMxRecord -Send NoAuth -Port 25 -Encryption None

# Force TLS certificate checks off, mirroring the device's "Certificate Verification" toggles.
.\Test-ScanToEmail.ps1 -From scanner@contoso.com -To staff@contoso.com `
    -Send Auth -SmtpServer smtp.office365.com -SkipCertificateCheck
```

When you choose **Auth**, it prompts for **username** (defaults to the From address)
and **password**; if the mailbox has MFA, enter an **app password**.

## Reading the result

- **`RESULT: ACCEPTED (250)`** — the transport took the message. If it still doesn't
  arrive, it's **delivery/filtering**, not the printer: run a **Message Trace**
  (Exchange admin center → Mail flow → Message trace) and check the recipient's
  **Junk** and the tenant **Quarantine** (`security.microsoft.com`).
- **`535`** — SMTP AUTH disabled on the mailbox/tenant, wrong password, or MFA
  without an app password.
- **`550` / `5.7.x`** — relay or policy denied: an external recipient on direct send,
  a `From` address that isn't an accepted domain, or an SPF/spoof block.
- **STARTTLS not advertised** — wrong port for the TLS mode (587 STARTTLS, 465
  implicit SSL, or 25 with `-Encryption None`).

## Zero-touch

The direct-send host is derived from the sender's domain at runtime and the local
FQDN is used for `EHLO`. No org, domain, or server name is hardcoded, so it runs
unmodified in any tenant.
