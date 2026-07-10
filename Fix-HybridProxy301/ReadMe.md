# Hybrid Configuration Wizard — WinRM HTTP 301 via WinHTTP proxy

Troubleshooting note for the Exchange **Hybrid Configuration Wizard (HCW)** failing at
**"Gathering Configuration Information"** with:

```
Connecting to remote server failed with the following error message: Connecting to
remote server ExchSvr01 failed with the following error message : The WinRM client
received an HTTP status code of 301 from the remote WS-Management service. For more
information, see the about_Remote_Troubleshooting Help topic.
```

The on-prem (red) row fails while the Office 365 (green) row succeeds.

---

## Root cause

The HCW reaches the on-prem server over **WinRM**, which uses the **WinHTTP** stack.
When a **system WinHTTP proxy** is configured, the WinRM request to `ExchSvr01` is
routed **through the proxy** instead of going direct. The proxy answers with an
**HTTP 301 (redirect)** rather than completing the WS-Management handshake — hence
the error.

The subtle part is the **bypass list**. A bypass entry like `*.examples.co.za` only
matches **dotted FQDNs**. The HCW connects by **bare NetBIOS name** (`ExchSvr01`,
no period), which does **not** match that pattern — so the short-name request still
goes through the proxy and still gets the 301.

### Why `<local>` matters
In WinHTTP, **`<local>` bypasses the proxy for any hostname that contains no
periods** — i.e. exactly bare names like `ExchSvr01`. Adding it (or the explicit
short name) is what closes the gap.

---

## Diagnosis

```cmd
netsh winhttp show proxy
```

Example of the broken state:

```
Proxy Server(s) :  http=10.0.0.10
Bypass List     :  *.examples.co.za
```

`*.examples.co.za` covers FQDNs but **not** the bare name the HCW uses → 301.

---

## Fix

Keep the proxy for general/internet traffic, but add the on-prem Exchange servers
to the bypass list. `<local>` covers all bare hostnames:

```cmd
netsh winhttp set proxy proxy-server="http=10.0.0.10" bypass-list="*.examples.co.za;<local>"
```

Belt-and-suspenders (also list the explicit name, in case anything connects by FQDN):

```cmd
netsh winhttp set proxy proxy-server="http=10.0.0.10" bypass-list="ExchSvr01;*.examples.co.za;<local>"
```

Notes:
- `netsh winhttp set proxy` **overwrites** — re-supply the existing proxy server value.
- Entries are **semicolon-separated**.
- Include **both** the NetBIOS name and the FQDN pattern to cover either connection form.
- The change is **persistent** across reboots. No reboot needed, but **restart the
  HCW app** so it re-reads the WinHTTP config.

### Build the bypass list from your actual servers (no hardcoding)

Let EMS enumerate every Exchange server and print the exact `netsh` command, so it
works regardless of server/domain names:

```powershell
$servers = Get-ExchangeServer
$suffix  = (Get-CimInstance Win32_ComputerSystem).Domain     # e.g. examples.co.za

$bypass  = @()
$bypass += $servers.Name                                     # NetBIOS
$bypass += ($servers.Name | ForEach-Object { "$_.$suffix" }) # FQDN
$bypass += "*.$suffix"                                        # whole internal domain
$bypass += "<local>"                                          # all bare hostnames

$bypassList = ($bypass | Select-Object -Unique) -join ';'
"netsh winhttp set proxy proxy-server=`"http=10.0.0.10`" bypass-list=`"$bypassList`""
```

Swap `http=10.0.0.10` for the real proxy value from `netsh winhttp show proxy`.

---

## Verify

```cmd
netsh winhttp show proxy
```
```powershell
Test-WSMan -ComputerName ExchSvr01
```

A successful `Test-WSMan` returns the **WS-Management identity XML** (`wsmid`,
`ProductVendor : Microsoft Corporation`, `Stack: 3.0`) with **no 301** — confirming
WinRM to `ExchSvr01` now goes **direct**. Restart the HCW and re-run; the on-prem
row should turn green.

---

## Why Office 365 was unaffected

The O365 side of the HCW reaches `outlook.office365.com` over the internet, which
**correctly still goes through the proxy** — that row was green all along. The
bypass only diverts internal (`.examples.co.za` / short-name) traffic, so external
O365 connectivity is unchanged.

## Rollback

To remove the proxy entirely (direct access):

```cmd
netsh winhttp reset proxy
```

Or re-apply the previous value without the added bypass entries.
