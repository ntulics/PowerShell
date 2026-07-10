<#
.SYNOPSIS
    Simulate a multifunction printer's "Scan to Email" send against Microsoft 365,
    with the same knobs the device exposes, and print the full SMTP transcript.

.DESCRIPTION
    A standalone tester that reproduces exactly what the MFP does when it sends a
    scan by email, so you can see WHY a send fails (or silently disappears) without
    reading the printer's terse job log. It speaks SMTP by hand over a raw socket
    and logs every request/response line - so the real server codes (235 auth OK,
    250 accepted, 535 auth failed, 550 relay/policy denied, 5.7.x spoof) are shown
    verbatim, the way the printer receives them but never tells you.

    Run with no options beyond -From/-To and it walks you through the same choices
    the printer's screen offers, one prompt at a time:

      1. SMTP Server Address  - look it up from the From domain's MX record, or
                                type the host manually.
      2. Sending method       - SMTP AUTH (sign in) or No authentication
                                (direct send / relay).
      3. If AUTH: port + security - STARTTLS/587, STARTTLS/25, SSL/465, none/25,
                                or a custom port + SSL/TLS mode.
      4. If AUTH: username + password (use an app password if the mailbox has MFA).

    These cover the three approaches in Microsoft's doc "How to set up a
    multifunction device or application to send email using Microsoft 365 or
    Office 365":
      * SMTP AUTH client submission -> Auth, smtp.office365.com, 587/STARTTLS.
      * Direct send                 -> No auth, the From domain's MX host, 25.
      * SMTP relay (via connector)   -> No auth, MX/manual host, 25.

    Any prompt can be pre-answered on the command line (-SmtpServer/-UseMxRecord,
    -Send, -Port, -Encryption, -Credential) so the same script runs unattended and
    can reproduce a specific printer screen field-for-field.

    Zero-touch: the server is discovered from the sender domain's live MX record
    and the local FQDN is used for EHLO. Nothing about any org, domain or server is
    hardcoded, so it runs unmodified in any tenant.

.PARAMETER From
    Sender address the device presents (MAIL FROM and the From: header). With
    SMTP AUTH this must match the authenticated mailbox (or an address it may
    Send As), otherwise Microsoft 365 treats it as spoofing.

.PARAMETER To
    One or more recipient addresses. Use an internal address first to prove the
    path, then an external one to test relay/auth scope.

.PARAMETER SmtpServer
    SMTP host. If omitted you're asked to look it up from the From domain's MX
    record or enter it manually.

.PARAMETER UseMxRecord
    Skip the prompt and derive the host from the From domain's MX record.

.PARAMETER Send
    Auth or NoAuth. Omit to be asked interactively.

.PARAMETER Port
    TCP port. Asked interactively when authenticating; defaults to 25 for no-auth.

.PARAMETER Encryption
    None      no TLS (matches the printer's "SSL/TLS: Off").
    StartTls  upgrade the plaintext connection with STARTTLS (587, or 25).
    Ssl       implicit TLS from the first byte (SMTPS, port 465).

.PARAMETER Credential
    Mailbox credential for SMTP AUTH. Prompted for (username + password) when you
    choose the Auth method and none is supplied. Use an app password if MFA is on.

.PARAMETER Subject
    Message subject. Defaults to a scan-style subject with a timestamp.

.PARAMETER Body
    Message body text.

.PARAMETER AttachmentPath
    File to attach, to mimic the scanned PDF. If omitted and -SimulateScan is
    set, a small placeholder file is generated and attached.

.PARAMETER SimulateScan
    Generate and attach a small placeholder "scan" when no -AttachmentPath given.

.PARAMETER SkipCertificateCheck
    Accept any TLS certificate (mirrors the printer's "Certificate Verification"
    toggles being off). Use only for testing.

.PARAMETER TimeoutSeconds
    Socket read/connect timeout. Default 30.

.EXAMPLE
    # Interactive - just supply who it's from/to and answer the prompts (server via
    # MX or manual, auth or not, port, credentials), like the printer's screen.
    .\Test-ScanToEmail.ps1 -From scanner@contoso.com -To staff@contoso.com -SimulateScan

.EXAMPLE
    # Authenticated client submission (internal + external), fully unattended.
    .\Test-ScanToEmail.ps1 -From scanner@contoso.com -To someone@gmail.com `
        -SmtpServer smtp.office365.com -Send Auth -Port 587 -Encryption StartTls `
        -Credential (Get-Credential) -SimulateScan

.EXAMPLE
    # Direct send to an internal recipient, host taken from the domain's MX record.
    .\Test-ScanToEmail.ps1 -From scanner@contoso.com -To staff@contoso.com `
        -UseMxRecord -Send NoAuth

.EXAMPLE
    # Reproduce the exact printer screen: MX host, port 25, SSL/TLS Off, no auth.
    .\Test-ScanToEmail.ps1 -From scanner@contoso.com -To staff@contoso.com `
        -UseMxRecord -Send NoAuth -Port 25 -Encryption None

.NOTES
    Read-only against your mailbox - it only sends a test message. Pair it with a
    Message Trace in the Exchange admin center: a 250 here plus "Quarantined" in
    the trace means the transport accepted it and Defender filtered it, not a
    printer problem.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$From,

    [Parameter(Mandatory)]
    [string[]]$To,

    # SMTP host. If omitted you're asked to look it up from the From domain's MX
    # record or type it manually - the way the printer's SMTP Server field works.
    [string]$SmtpServer,

    # Skip the prompt and derive the host from the From domain's MX record.
    [switch]$UseMxRecord,

    # Sending mode. Omit to be asked Auth vs No-auth interactively.
    [ValidateSet('Auth','NoAuth')]
    [string]$Send,

    [int]$Port,

    [ValidateSet('None','StartTls','Ssl')]
    [string]$Encryption,

    [System.Management.Automation.PSCredential]$Credential,

    [string]$Subject = "Scan to Email test - $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')",

    [string]$Body = "This is a Scan to Email simulation sent by Test-ScanToEmail.ps1.`r`nIf you received it, the SMTP path and delivery are working.",

    [string]$AttachmentPath,

    [switch]$SimulateScan,

    [switch]$SkipCertificateCheck,

    [int]$TimeoutSeconds = 30
)

# ---- interactive helpers -----------------------------------------------------
function Read-Menu {
    # Present a numbered menu, return the chosen option's Value. Loops until valid.
    param([string]$Title, [object[]]$Options, [int]$Default = 1)
    Write-Host ""
    Write-Host $Title -ForegroundColor White
    for ($i = 0; $i -lt $Options.Count; $i++) {
        Write-Host ("  [{0}] {1}" -f ($i + 1), $Options[$i].Label)
    }
    while ($true) {
        $sel = Read-Host ("Choose 1-{0} [{1}]" -f $Options.Count, $Default)
        if ([string]::IsNullOrWhiteSpace($sel)) { return $Options[$Default - 1].Value }
        if ($sel -match '^\d+$' -and [int]$sel -ge 1 -and [int]$sel -le $Options.Count) {
            return $Options[[int]$sel - 1].Value
        }
        Write-Host "  Enter a number between 1 and $($Options.Count)." -ForegroundColor Yellow
    }
}

function Get-MxHosts {
    # Return the domain's MX hosts, lowest preference first. Uses Resolve-DnsName
    # where available (Windows), falling back to nslookup so it works anywhere.
    param([string]$Domain)
    $result = @()
    if (Get-Command Resolve-DnsName -ErrorAction SilentlyContinue) {
        try {
            $result = Resolve-DnsName -Name $Domain -Type MX -ErrorAction Stop |
                Where-Object { $_.QueryType -eq 'MX' -and $_.NameExchange } |
                Sort-Object Preference |
                ForEach-Object { [pscustomobject]@{ Preference = $_.Preference; Host = $_.NameExchange } }
        } catch { $result = @() }
    }
    if (-not $result) {
        try {
            $out = & nslookup -type=MX $Domain 2>$null
            # nslookup prints "... mail exchanger = <preference> <host>".
            $result = $out |
                Select-String 'mail exchanger\s*=\s*(\d+)\s+(\S+)' |
                ForEach-Object { [pscustomobject]@{ Preference = [int]$_.Matches[0].Groups[1].Value; Host = $_.Matches[0].Groups[2].Value.TrimEnd('.') } } |
                Sort-Object Preference
        } catch { $result = @() }
    }
    return $result
}

$fromDomain = ($From -split '@')[-1]
if (-not $fromDomain -or $fromDomain -eq $From) {
    throw "-From '$From' has no domain part (expected name@domain)."
}

# ---- 1. SMTP server: MX lookup or manual (the printer's SMTP Server field) ----
if (-not $SmtpServer) {
    $source = if ($UseMxRecord) { 'MX' } else {
        Read-Menu -Title "SMTP Server Address - how do you want to set it?" -Options @(
            [pscustomobject]@{ Label = "Look up the MX record of $fromDomain (automatic)"; Value = 'MX' }
            [pscustomobject]@{ Label = "Enter the server address manually";                Value = 'Manual' }
        )
    }
    if ($source -eq 'MX') {
        Write-Host "Looking up MX for $fromDomain ..." -ForegroundColor DarkGray
        $mx = Get-MxHosts -Domain $fromDomain
        if (-not $mx) {
            Write-Host "  No MX records found (or DNS unavailable) - enter the server manually." -ForegroundColor Yellow
            $SmtpServer = (Read-Host "SMTP Server Address").Trim()
        } elseif ($mx.Count -eq 1) {
            $SmtpServer = $mx[0].Host
            Write-Host ("  MX: {0}" -f $SmtpServer) -ForegroundColor DarkGray
        } else {
            $opts = $mx | ForEach-Object { [pscustomobject]@{ Label = ("{0}  (pref {1})" -f $_.Host, $_.Preference); Value = $_.Host } }
            $SmtpServer = Read-Menu -Title "Multiple MX hosts - pick one:" -Options $opts
        }
    } else {
        $SmtpServer = (Read-Host "SMTP Server Address").Trim()
    }
}
if ([string]::IsNullOrWhiteSpace($SmtpServer)) { throw "No SMTP server was provided." }

# ---- 2. Send: authenticated or not (the printer's SMTP Authentication toggle) --
if ($Send) {
    $needsAuth = $Send -eq 'Auth'
} elseif ($Credential) {
    $needsAuth = $true
} else {
    $needsAuth = Read-Menu -Title "Sending method:" -Options @(
        [pscustomobject]@{ Label = 'SMTP AUTH - sign in with a mailbox (required for external recipients)'; Value = $true }
        [pscustomobject]@{ Label = 'No authentication - direct send / relay (own-domain recipients only)';   Value = $false }
    )
}

# ---- 3. Port + connection security --------------------------------------------
if (-not $Port -or -not $Encryption) {
    if ($needsAuth) {
        # Auth was chosen: ask which port/security to use, unless already supplied.
        if (-not $PSBoundParameters.ContainsKey('Port') -and -not $PSBoundParameters.ContainsKey('Encryption')) {
            $pick = Read-Menu -Title "Connection security / port:" -Options @(
                [pscustomobject]@{ Label = 'STARTTLS on port 587  (recommended for Microsoft 365)'; Value = '587:StartTls' }
                [pscustomobject]@{ Label = 'STARTTLS on port 25';                                    Value = '25:StartTls' }
                [pscustomobject]@{ Label = 'SSL/TLS on port 465  (implicit TLS)';                    Value = '465:Ssl' }
                [pscustomobject]@{ Label = 'No encryption on port 25  (not recommended)';            Value = '25:None' }
                [pscustomobject]@{ Label = 'Custom port + security';                                 Value = 'custom' }
            )
            if ($pick -eq 'custom') {
                $Port = [int](Read-Host "Port No. (1-65535)")
                $Encryption = Read-Menu -Title "SSL/TLS:" -Options @(
                    [pscustomobject]@{ Label = 'None (off)';        Value = 'None' }
                    [pscustomobject]@{ Label = 'STARTTLS';          Value = 'StartTls' }
                    [pscustomobject]@{ Label = 'SSL/TLS (implicit)'; Value = 'Ssl' }
                )
            } else {
                $parts = $pick -split ':'
                if (-not $Port)       { $Port = [int]$parts[0] }
                if (-not $Encryption) { $Encryption = $parts[1] }
            }
        } else {
            if (-not $Port)       { $Port = 587 }
            if (-not $Encryption) { $Encryption = 'StartTls' }
        }
    } else {
        # No auth: direct send / relay defaults (port 25, no TLS), like the printer.
        if (-not $Port)       { $Port = 25 }
        if (-not $Encryption) { $Encryption = 'None' }
    }
}

# The *.mail.protection.outlook.com endpoint is receive-only and has NO SMTP AUTH -
# logging in there returns "504 Unrecognized authentication type". If the user chose
# Auth against it, warn and offer to switch to the submission endpoint.
if ($needsAuth -and $SmtpServer -match 'mail\.protection\.outlook\.com$') {
    Write-Host ""
    Write-Host "WARNING: $SmtpServer does not support authentication (it's the receive/MX host)." -ForegroundColor Yellow
    Write-Host "         Authenticated send must use smtp.office365.com:587 STARTTLS." -ForegroundColor Yellow
    if (-not $PSBoundParameters.ContainsKey('SmtpServer')) {
        $switch = Read-Menu -Title "Switch to the authenticated submission endpoint?" -Options @(
            [pscustomobject]@{ Label = 'Yes - use smtp.office365.com:587 STARTTLS'; Value = $true }
            [pscustomobject]@{ Label = 'No  - keep this host (will get 504)';       Value = $false }
        )
        if ($switch) {
            $SmtpServer = 'smtp.office365.com'
            if (-not $PSBoundParameters.ContainsKey('Port'))       { $Port = 587 }
            if (-not $PSBoundParameters.ContainsKey('Encryption')) { $Encryption = 'StartTls' }
        }
    }
}

# ---- 4. Credentials, only when authenticating ---------------------------------
if ($needsAuth -and -not $Credential) {
    $user = Read-Host "Username (mailbox) [$From]"
    if ([string]::IsNullOrWhiteSpace($user)) { $user = $From }
    $pass = Read-Host "Password (use an app password if MFA is on)" -AsSecureString
    $Credential = New-Object System.Management.Automation.PSCredential($user, $pass)
}

# ---- transcript logging ------------------------------------------------------
$script:Transcript = New-Object System.Collections.Generic.List[string]
function Write-Smtp {
    param([ValidateSet('C','S','I','E')][string]$Direction, [string]$Text)
    $tag = @{ C = '  C:'; S = '  S:'; I = '  --'; E = '  !!' }[$Direction]
    $color = @{ C = 'Cyan'; S = 'Gray'; I = 'DarkGray'; E = 'Red' }[$Direction]
    foreach ($line in ($Text -split "`r?`n")) {
        $script:Transcript.Add("$tag $line")
        Write-Host "$tag $line" -ForegroundColor $color
    }
}

# ---- raw SMTP primitives -----------------------------------------------------
function Send-SmtpLine {
    param([System.IO.Stream]$Stream, [string]$Line, [switch]$Secret)
    $bytes = [System.Text.Encoding]::ASCII.GetBytes($Line + "`r`n")
    $Stream.Write($bytes, 0, $bytes.Length)
    $Stream.Flush()
    if ($Secret) { Write-Smtp -Direction C -Text '<redacted>' } else { Write-Smtp -Direction C -Text $Line }
}

function Read-SmtpResponse {
    param([System.IO.Stream]$Stream)
    # SMTP replies are one or more lines "NNN-text" ending with "NNN text".
    $sb = New-Object System.Text.StringBuilder
    $lineChars = New-Object System.Text.StringBuilder
    $code = $null
    while ($true) {
        $b = $Stream.ReadByte()
        if ($b -lt 0) { break }                       # connection closed
        if ($b -eq 10) {                              # LF ends a line
            $line = $lineChars.ToString().TrimEnd("`r")
            [void]$sb.AppendLine($line)
            $lineChars.Clear() | Out-Null
            if ($line.Length -ge 4 -and $line[3] -eq ' ') {   # final line
                $code = [int]$line.Substring(0,3); break
            } elseif ($line.Length -lt 4) { break }
        } else {
            [void]$lineChars.Append([char]$b)
        }
    }
    $text = $sb.ToString().TrimEnd("`r","`n")
    Write-Smtp -Direction S -Text $text
    [pscustomobject]@{ Code = $code; Text = $text }
}

function Assert-Smtp {
    param($Response, [int[]]$Expected, [string]$Stage)
    if ($Response.Code -notin $Expected) {
        throw "SMTP $Stage failed: server replied $($Response.Code) (expected $($Expected -join '/')).`r`n$($Response.Text)"
    }
}

function Get-TlsStream {
    param([System.IO.Stream]$Inner, [string]$TargetHost, [bool]$SkipCheck)
    $cb = { param($s,$cert,$chain,$errs) if ($SkipCheck) { $true } else { $errs -eq [System.Net.Security.SslPolicyErrors]::None } }
    $ssl = New-Object System.Net.Security.SslStream($Inner, $false, $cb)
    # Let the OS negotiate the best protocol (TLS 1.2/1.3).
    $ssl.AuthenticateAsClient($TargetHost, $null, [System.Security.Authentication.SslProtocols]::None, $false)
    Write-Smtp -Direction I -Text "TLS established: $($ssl.SslProtocol), cipher $($ssl.CipherAlgorithm) $($ssl.CipherStrength)-bit"
    $ssl
}

# ---- MIME message ------------------------------------------------------------
function New-MimeMessage {
    param([string]$From,[string[]]$To,[string]$Subject,[string]$Body,[string]$AttachmentPath)
    $nl = "`r`n"
    $date = (Get-Date).ToString('r')
    $msgId = "<$([guid]::NewGuid().ToString('N'))@$(($From -split '@')[-1])>"
    $headers = @(
        "From: $From"
        "To: $($To -join ', ')"
        "Subject: $Subject"
        "Date: $date"
        "Message-ID: $msgId"
        "MIME-Version: 1.0"
    )
    if ($AttachmentPath) {
        $boundary = "==Scan_$([guid]::NewGuid().ToString('N'))"
        $fileName = [System.IO.Path]::GetFileName($AttachmentPath)
        $b64 = [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($AttachmentPath))
        $wrapped = ($b64 -split '(.{76})' | Where-Object { $_ }) -join $nl
        $headers += "Content-Type: multipart/mixed; boundary=`"$boundary`""
        $body = @(
            "--$boundary"
            "Content-Type: text/plain; charset=UTF-8"
            "Content-Transfer-Encoding: 8bit"
            ""
            $Body
            ""
            "--$boundary"
            "Content-Type: application/octet-stream; name=`"$fileName`""
            "Content-Transfer-Encoding: base64"
            "Content-Disposition: attachment; filename=`"$fileName`""
            ""
            $wrapped
            ""
            "--$boundary--"
        ) -join $nl
    } else {
        $headers += "Content-Type: text/plain; charset=UTF-8"
        $body = $Body
    }
    ($headers -join $nl) + $nl + $nl + $body
}

# ---- optional placeholder "scan" ---------------------------------------------
if (-not $AttachmentPath -and $SimulateScan) {
    $AttachmentPath = Join-Path ([System.IO.Path]::GetTempPath()) ("scan_{0}.txt" -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
    Set-Content -Path $AttachmentPath -Value "Placeholder scan generated by Test-ScanToEmail.ps1 at $(Get-Date)." -Encoding UTF8
    Write-Verbose "Generated placeholder attachment: $AttachmentPath"
}
if ($AttachmentPath -and -not (Test-Path -LiteralPath $AttachmentPath)) {
    throw "Attachment not found: $AttachmentPath"
}

# ---- run ---------------------------------------------------------------------
$localFqdn = [System.Net.Dns]::GetHostEntry([string]$env:COMPUTERNAME).HostName
if (-not $localFqdn) { $localFqdn = $env:COMPUTERNAME }

Write-Host ""
Write-Host "Scan to Email simulation" -ForegroundColor White
Write-Host ("-" * 60) -ForegroundColor DarkGray
Write-Host ("  Send        : {0}" -f ($(if ($needsAuth) { 'SMTP AUTH' } else { 'No auth (direct send/relay)' })))
Write-Host ("  Server:Port : {0}:{1}" -f $SmtpServer, $Port)
Write-Host ("  Encryption  : {0}" -f $Encryption)
Write-Host ("  Auth        : {0}" -f ($(if ($needsAuth) { "yes ($($Credential.UserName))" } else { 'none' })))
Write-Host ("  From        : {0}" -f $From)
Write-Host ("  To          : {0}" -f ($To -join ', '))
Write-Host ("  Attachment  : {0}" -f ($(if ($AttachmentPath) { Split-Path $AttachmentPath -Leaf } else { '(none)' })))
Write-Host ("-" * 60) -ForegroundColor DarkGray

$client = $null; $stream = $null; $ok = $false; $errMsg = $null
try {
    $client = New-Object System.Net.Sockets.TcpClient
    $iar = $client.BeginConnect($SmtpServer, $Port, $null, $null)
    if (-not $iar.AsyncWaitHandle.WaitOne([TimeSpan]::FromSeconds($TimeoutSeconds))) {
        throw "Connection to $SmtpServer`:$Port timed out after $TimeoutSeconds s."
    }
    $client.EndConnect($iar)
    Write-Smtp -Direction I -Text "Connected to $SmtpServer`:$Port"

    $stream = $client.GetStream()
    $stream.ReadTimeout  = $TimeoutSeconds * 1000
    $stream.WriteTimeout = $TimeoutSeconds * 1000

    if ($Encryption -eq 'Ssl') {
        $stream = Get-TlsStream -Inner $stream -TargetHost $SmtpServer -SkipCheck:$SkipCertificateCheck.IsPresent
    }

    Assert-Smtp (Read-SmtpResponse $stream) 220 'greeting'

    Send-SmtpLine $stream "EHLO $localFqdn"
    $ehlo = Read-SmtpResponse $stream
    Assert-Smtp $ehlo 250 'EHLO'

    if ($Encryption -eq 'StartTls') {
        if ($ehlo.Text -notmatch '(?im)^\d{3}[ -]STARTTLS') {
            throw "Server did not advertise STARTTLS on $SmtpServer`:$Port. Wrong port for TLS? (587 for STARTTLS, 465 for implicit SSL.)"
        }
        Send-SmtpLine $stream "STARTTLS"
        Assert-Smtp (Read-SmtpResponse $stream) 220 'STARTTLS'
        $stream = Get-TlsStream -Inner $stream -TargetHost $SmtpServer -SkipCheck:$SkipCertificateCheck.IsPresent
        Send-SmtpLine $stream "EHLO $localFqdn"           # re-EHLO over the secure channel
        $ehlo = Read-SmtpResponse $stream
        Assert-Smtp $ehlo 250 'EHLO(TLS)'
    }

    if ($needsAuth) {
        if ($ehlo.Text -notmatch '(?im)AUTH.*LOGIN') {
            Write-Smtp -Direction I -Text "Note: server did not advertise AUTH LOGIN - SMTP AUTH may be disabled on this mailbox/tenant."
        }
        Send-SmtpLine $stream "AUTH LOGIN"
        Assert-Smtp (Read-SmtpResponse $stream) 334 'AUTH LOGIN'
        $u = [Convert]::ToBase64String([System.Text.Encoding]::ASCII.GetBytes($Credential.UserName))
        Send-SmtpLine $stream $u -Secret
        Assert-Smtp (Read-SmtpResponse $stream) 334 'AUTH username'
        $p = [Convert]::ToBase64String([System.Text.Encoding]::ASCII.GetBytes($Credential.GetNetworkCredential().Password))
        Send-SmtpLine $stream $p -Secret
        Assert-Smtp (Read-SmtpResponse $stream) 235 'AUTH password'   # 535 = auth failed
    }

    Send-SmtpLine $stream "MAIL FROM:<$From>"
    Assert-Smtp (Read-SmtpResponse $stream) 250 'MAIL FROM'

    foreach ($rcpt in $To) {
        Send-SmtpLine $stream "RCPT TO:<$rcpt>"
        Assert-Smtp (Read-SmtpResponse $stream) @(250,251) "RCPT TO $rcpt"   # 550 = relay/policy denied
    }

    Send-SmtpLine $stream "DATA"
    Assert-Smtp (Read-SmtpResponse $stream) 354 'DATA'

    $message = New-MimeMessage -From $From -To $To -Subject $Subject -Body $Body -AttachmentPath $AttachmentPath
    # Dot-stuffing: any line that starts with '.' must be doubled so it isn't read
    # as the end-of-data terminator.
    $stuffed = ($message -split "`r?`n" | ForEach-Object { if ($_.StartsWith('.')) { '.' + $_ } else { $_ } }) -join "`r`n"
    $dataBytes = [System.Text.Encoding]::UTF8.GetBytes($stuffed + "`r`n.`r`n")
    $stream.Write($dataBytes, 0, $dataBytes.Length); $stream.Flush()
    Write-Smtp -Direction C -Text "[message body: $($dataBytes.Length) bytes] ."
    Assert-Smtp (Read-SmtpResponse $stream) 250 'end-of-DATA'   # 250 + queued id = accepted

    Send-SmtpLine $stream "QUIT"
    Read-SmtpResponse $stream | Out-Null
    $ok = $true
}
catch {
    $errMsg = $_.Exception.Message
    Write-Smtp -Direction E -Text $errMsg
}
finally {
    if ($stream) { $stream.Dispose() }
    if ($client) { $client.Close() }
}

Write-Host ("-" * 60) -ForegroundColor DarkGray
if ($ok) {
    Write-Host "RESULT: ACCEPTED by the server (250)." -ForegroundColor Green
    Write-Host "  The transport accepted the message. If it never arrives, it is a" -ForegroundColor Green
    Write-Host "  DELIVERY/FILTERING issue - run a Message Trace and check Junk/Quarantine." -ForegroundColor Green
} else {
    Write-Host "RESULT: FAILED - $errMsg" -ForegroundColor Red
    switch -Regex ($errMsg) {
        '504'          { Write-Host "  504 = the server has no SMTP AUTH. You pointed Auth at the MX/protection host - use smtp.office365.com:587 STARTTLS, or send with No auth." -ForegroundColor Yellow }
        '535'          { Write-Host "  535 = authentication failed. SMTP AUTH disabled, wrong password, or MFA (use an app password)." -ForegroundColor Yellow }
        '550|5\.7\.'   { Write-Host "  550/5.7.x = relay or policy denied. External recipient on direct send, From not accepted, or SPF/spoof block." -ForegroundColor Yellow }
        'STARTTLS'     { Write-Host "  TLS mismatch. Use 587 for STARTTLS, 465 for implicit SSL, or 25 with Encryption None." -ForegroundColor Yellow }
        'timed out'    { Write-Host "  Timeout. Port blocked by firewall/ISP (25 is often blocked outbound) or wrong host." -ForegroundColor Yellow }
    }
}

[pscustomobject]@{
    Success    = $ok
    Authenticated = $needsAuth
    Server     = $SmtpServer
    Port       = $Port
    Encryption = $Encryption
    From       = $From
    To         = $To
    Error      = $errMsg
    Transcript = $script:Transcript.ToArray()
}
