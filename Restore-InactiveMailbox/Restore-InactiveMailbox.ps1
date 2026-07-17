<#
.SYNOPSIS
    GUI tool to merge Exchange Online inactive mailbox content into a reinstated user's mailbox,
    across multiple client tenants, with awareness of cloud-only vs. Entra Connect-synced targets.

.DESCRIPTION
    - No tenant/customer details are hardcoded in this script - it's safe to share as-is.
    - No tenant list needs to be configured up front: click "Sign In / Connect" and the tool
      detects which tenant you're connected to from the Exchange Online session itself
      (via Get-OrganizationConfig / Get-AcceptedDomain) and labels everything accordingly.
    - Each tenant you sign into is remembered locally in tenants.json (next to the script)
      purely as a convenience "recent" list - nothing is required to be typed in advance.
    - The only case that needs manual input is GDAP/delegated access (signing in once with
      your own partner credentials to act on a customer tenant) - tick "GDAP: act on customer
      tenant" and enter that customer's *.onmicrosoft.com domain, since the target tenant can't
      be inferred from your own sign-in in that scenario.
    - Lists all inactive mailboxes in the connected tenant.
    - Lets you pick an inactive mailbox and a target (reinstated user) mailbox.
    - Detects whether the target mailbox is cloud-only or synced from on-prem AD via Entra Connect,
      and adjusts the X500 proxy step accordingly (synced mailboxes must have the proxy added on-prem,
      not in EXO, or Entra Connect will overwrite it on the next sync cycle).
    - Captures pre-restore metadata to a log file (for compliance / chain-of-custody).
    - Kicks off New-MailboxRestoreRequest and lets you poll its status.
    - Logs every action with a timestamp to a per-tenant log file next to the script.

.REQUIREMENTS
    - PowerShell 5.1 or 7+ on Windows, with WinForms
    - An account with Exchange Admin rights in each target tenant (or GDAP delegated access)
    - The ExchangeOnlineManagement module - if it's missing, the script offers to install it
      automatically (Install-Module -Scope CurrentUser) the first time it runs
#>

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# ---------------------------------------------------------------------------
# Ensure the ExchangeOnlineManagement module is available before anything else
# ---------------------------------------------------------------------------
function Ensure-EXOModuleInstalled {
    if (Get-Module -ListAvailable -Name ExchangeOnlineManagement) {
        return $true
    }

    $prompt = [System.Windows.Forms.MessageBox]::Show(
        "The ExchangeOnlineManagement PowerShell module isn't installed on this machine.`n`nInstall it now for the current user?",
        "Module Required", "YesNo", "Question")
    if ($prompt -ne "Yes") { return $false }

    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

        if (-not (Get-PackageProvider -Name NuGet -ErrorAction SilentlyContinue)) {
            Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -Scope CurrentUser -ErrorAction Stop | Out-Null
        }

        Install-Module -Name ExchangeOnlineManagement -Scope CurrentUser -Force -AllowClobber -ErrorAction Stop
        [System.Windows.Forms.MessageBox]::Show("ExchangeOnlineManagement module installed successfully.", "Done", "OK", "Information") | Out-Null
        return $true
    }
    catch {
        [System.Windows.Forms.MessageBox]::Show(
            "Couldn't install the module automatically:`n$($_.Exception.Message)`n`nTry running this manually in an elevated PowerShell window, then relaunch this tool:`n`nInstall-Module ExchangeOnlineManagement -Scope CurrentUser -Force",
            "Install Failed", "OK", "Error") | Out-Null
        return $false
    }
}

if (-not (Ensure-EXOModuleInstalled)) {
    [System.Windows.Forms.MessageBox]::Show("ExchangeOnlineManagement is required to run this tool. Exiting.", "Exiting", "OK", "Warning") | Out-Null
    return
}

# ---------------------------------------------------------------------------
# Theme
# ---------------------------------------------------------------------------
$Theme = [PSCustomObject]@{
    HeaderBg    = [System.Drawing.Color]::FromArgb(10, 22, 40)
    HeaderSub   = [System.Drawing.Color]::FromArgb(148, 163, 184)
    PageBg      = [System.Drawing.Color]::FromArgb(243, 244, 246)
    CardBg      = [System.Drawing.Color]::White
    CardBorder  = [System.Drawing.Color]::FromArgb(229, 231, 235)
    TextDark    = [System.Drawing.Color]::FromArgb(17, 24, 39)
    TextGray    = [System.Drawing.Color]::FromArgb(107, 114, 128)
    Accent      = [System.Drawing.Color]::FromArgb(37, 99, 235)
    AccentHover = [System.Drawing.Color]::FromArgb(29, 78, 216)
    Success     = [System.Drawing.Color]::FromArgb(5, 150, 105)
    Danger      = [System.Drawing.Color]::FromArgb(220, 38, 38)
    Warn        = [System.Drawing.Color]::FromArgb(217, 119, 6)
    ConsoleBg   = [System.Drawing.Color]::FromArgb(10, 15, 26)
    ConsoleText = [System.Drawing.Color]::FromArgb(203, 213, 225)
    LogInfo     = [System.Drawing.Color]::FromArgb(148, 163, 184)
    LogWarn     = [System.Drawing.Color]::FromArgb(251, 191, 36)
    LogError    = [System.Drawing.Color]::FromArgb(248, 113, 113)
    LogAction   = [System.Drawing.Color]::FromArgb(52, 211, 153)
}
$FontFamily = "Segoe UI"

function New-RoundedPath {
    param([int]$Width, [int]$Height, [int]$Radius)
    $path = New-Object System.Drawing.Drawing2D.GraphicsPath
    $d = $Radius * 2
    if ($d -gt ($Width - 1)) { $d = $Width - 1 }
    if ($d -gt ($Height - 1)) { $d = $Height - 1 }
    $path.AddArc(0, 0, $d, $d, 180, 90)
    $path.AddArc($Width - $d - 1, 0, $d, $d, 270, 90)
    $path.AddArc($Width - $d - 1, $Height - $d - 1, $d, $d, 0, 90)
    $path.AddArc(0, $Height - $d - 1, $d, $d, 90, 90)
    $path.CloseFigure()
    return $path
}

function Set-RoundedRegion {
    param($Control, [int]$Radius = 10)
    if ($Control.Width -le 0 -or $Control.Height -le 0) { return }
    $path = New-RoundedPath -Width $Control.Width -Height $Control.Height -Radius $Radius
    $Control.Region = New-Object System.Drawing.Region($path)
}

function Add-RoundedBorderPaint {
    param($Control, [int]$Radius, $BorderColor)
    $Control.Add_Paint({
        param($s, $e)
        $path = New-RoundedPath -Width ($s.Width - 1) -Height ($s.Height - 1) -Radius $Radius
        $pen = New-Object System.Drawing.Pen($BorderColor, 1)
        $e.Graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $e.Graphics.DrawPath($pen, $path)
        $pen.Dispose()
        $path.Dispose()
    }.GetNewClosure())
}

function Set-PrimaryButtonStyle {
    param($Button)
    $Button.FlatStyle = "Flat"
    $Button.FlatAppearance.BorderSize = 0
    $Button.FlatAppearance.MouseOverBackColor = $Theme.AccentHover
    $Button.BackColor = $Theme.Accent
    $Button.ForeColor = [System.Drawing.Color]::White
    $Button.Font = New-Object System.Drawing.Font($FontFamily, 9.5, [System.Drawing.FontStyle]::Bold)
    $Button.Cursor = [System.Windows.Forms.Cursors]::Hand
    $Button.UseVisualStyleBackColor = $false
    Set-RoundedRegion -Control $Button -Radius 8
}

function Set-SecondaryButtonStyle {
    param($Button)
    $Button.FlatStyle = "Flat"
    $Button.FlatAppearance.BorderSize = 0
    $Button.FlatAppearance.MouseOverBackColor = [System.Drawing.Color]::FromArgb(219, 234, 254)
    $Button.FlatAppearance.MouseDownBackColor = [System.Drawing.Color]::FromArgb(191, 219, 254)
    $Button.BackColor = [System.Drawing.Color]::FromArgb(239, 246, 255)
    $Button.ForeColor = $Theme.Accent
    $Button.Font = New-Object System.Drawing.Font($FontFamily, 9.5, [System.Drawing.FontStyle]::Bold)
    $Button.Cursor = [System.Windows.Forms.Cursors]::Hand
    $Button.UseVisualStyleBackColor = $false
    Set-RoundedRegion -Control $Button -Radius 8
}

function Set-LinkButtonStyle {
    param($Button)
    $Button.FlatStyle = "Flat"
    $Button.FlatAppearance.BorderSize = 0
    $Button.BackColor = [System.Drawing.Color]::White
    $Button.ForeColor = $Theme.TextGray
    $Button.Font = New-Object System.Drawing.Font($FontFamily, 8.5)
    $Button.Cursor = [System.Windows.Forms.Cursors]::Hand
}

function Set-FieldStyle {
    param($TextBox)
    $TextBox.BorderStyle = "FixedSingle"
    $TextBox.Font = New-Object System.Drawing.Font($FontFamily, 9.5)
}

# ---------------------------------------------------------------------------
# Tenant config - loaded from / saved to a local JSON file. No customer data
# ships with this script.
# ---------------------------------------------------------------------------
$script:ConfigPath = Join-Path $PSScriptRoot "tenants.json"
$script:Tenants = @()

function Load-Tenants {
    if (Test-Path $script:ConfigPath) {
        try {
            $raw = Get-Content -Path $script:ConfigPath -Raw | ConvertFrom-Json
            $script:Tenants = @($raw | ForEach-Object {
                [PSCustomObject]@{
                    Name         = $_.Name
                    Organization = $_.Organization
                    Delegated    = [bool]$_.Delegated
                }
            })
        }
        catch {
            $script:Tenants = @()
        }
    }
    else {
        $script:Tenants = @()
    }
}

function Save-Tenants {
    $script:Tenants | ConvertTo-Json | Set-Content -Path $script:ConfigPath -Encoding UTF8
}

# ---------------------------------------------------------------------------
# Logging (per tenant, per day)
# ---------------------------------------------------------------------------
$script:LogPath = $null

function Set-LogPathForTenant {
    param([string]$TenantName)
    $safe = ($TenantName -replace '[^a-zA-Z0-9\-]', '_')
    $script:LogPath = Join-Path $PSScriptRoot ("Restore-InactiveMailbox_{0}_{1}.log" -f $safe, (Get-Date -Format "yyyy-MM-dd"))
}

function Write-Log {
    param(
        [Parameter(Mandatory)] [string]$Message,
        [ValidateSet("INFO","WARN","ERROR","ACTION")] [string]$Level = "INFO"
    )
    $line = "[{0}] [{1}] {2}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Level, $Message
    if ($script:LogPath) { Add-Content -Path $script:LogPath -Value $line }

    if ($script:txtLog) {
        $color = switch ($Level) {
            "WARN"   { $Theme.LogWarn }
            "ERROR"  { $Theme.LogError }
            "ACTION" { $Theme.LogAction }
            default  { $Theme.LogInfo }
        }
        $script:txtLog.SelectionStart = $script:txtLog.TextLength
        $script:txtLog.SelectionLength = 0
        $script:txtLog.SelectionColor = $color
        $script:txtLog.AppendText($line + [Environment]::NewLine)
        $script:txtLog.SelectionColor = $Theme.ConsoleText
        $script:txtLog.ScrollToCaret()
    }
}

# ---------------------------------------------------------------------------
# State
# ---------------------------------------------------------------------------
$script:Connected = $false
$script:ConnectedTenant = $null
$script:InactiveMailboxes = @()
$script:SelectedInactive = $null
$script:TargetIsDirSynced = $null

function Disconnect-EXOIfConnected {
    if ($script:Connected) {
        try { Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue } catch {}
        $script:Connected = $false
        $script:ConnectedTenant = $null
    }
}

function Get-CurrentTenantInfo {
    # Auto-detect who we're connected to - no need for the user to type this in.
    try {
        $org = Get-OrganizationConfig -ErrorAction Stop
        $initial = $null
        try {
            $domains = Get-AcceptedDomain -ErrorAction Stop
            $initial = ($domains | Where-Object { $_.InitialDomain }).DomainName | Select-Object -First 1
        } catch {}
        if (-not $initial) { $initial = $org.Identity }
        $name = $org.DisplayName
        if (-not $name) { $name = $org.Name }
        if (-not $name) { $name = $initial }
        return [PSCustomObject]@{ Name = $name; Organization = $initial }
    }
    catch {
        return $null
    }
}

function Add-OrUpdateRecentTenant {
    param($TenantInfo, [bool]$Delegated)
    $existing = $script:Tenants | Where-Object { $_.Organization -eq $TenantInfo.Organization }
    if ($existing) {
        $existing.Name = $TenantInfo.Name
        $existing.Delegated = $Delegated
    } else {
        $script:Tenants += [PSCustomObject]@{
            Name         = $TenantInfo.Name
            Organization = $TenantInfo.Organization
            Delegated    = $Delegated
        }
    }
    Save-Tenants
}

function Connect-EXOInteractive {
    param(
        [string]$DelegatedOrganization = ""
    )

    Disconnect-EXOIfConnected

    try {
        Write-Log "Signing in to Exchange Online..." "INFO"
        Import-Module ExchangeOnlineManagement -ErrorAction Stop

        if ($DelegatedOrganization) {
            Connect-ExchangeOnline -DelegatedOrganization $DelegatedOrganization -ShowBanner:$false -ErrorAction Stop
        } else {
            Connect-ExchangeOnline -ShowBanner:$false -ErrorAction Stop
        }

        $detected = Get-CurrentTenantInfo
        if (-not $detected) {
            $detected = [PSCustomObject]@{ Name = "Unknown tenant"; Organization = $DelegatedOrganization }
        }

        $script:Connected = $true
        $script:ConnectedTenant = $detected
        Set-LogPathForTenant -TenantName $detected.Name
        $lblStatus.Text = "Connected: $($detected.Name)"
        $lblStatus.ForeColor = $Theme.Success
        Write-Log "Connected to '$($detected.Name)' ($($detected.Organization))." "INFO"

        Add-OrUpdateRecentTenant -TenantInfo $detected -Delegated ([bool]$DelegatedOrganization)
        Refresh-TenantDropdown
        return $true
    }
    catch {
        Write-Log "Connection failed: $($_.Exception.Message)" "ERROR"
        [System.Windows.Forms.MessageBox]::Show("Failed to connect:`n$($_.Exception.Message)", "Connection Error", "OK", "Error") | Out-Null
        return $false
    }
}

# ---------------------------------------------------------------------------
# Main form
# ---------------------------------------------------------------------------
Load-Tenants

$form = New-Object System.Windows.Forms.Form
$form.Text = "Inactive Mailbox Restore Tool"
$form.Size = New-Object System.Drawing.Size(1040, 860)
$form.MinimumSize = New-Object System.Drawing.Size(900, 500)
$form.StartPosition = "CenterScreen"
$form.BackColor = $Theme.PageBg
$form.Font = New-Object System.Drawing.Font($FontFamily, 9.5)
$form.AutoScroll = $true

# ---- Header --------------------------------------------------------------
$pnlHeader = New-Object System.Windows.Forms.Panel
$pnlHeader.Dock = "Top"
$pnlHeader.Height = 72
$pnlHeader.BackColor = $Theme.HeaderBg

$lblTitle = New-Object System.Windows.Forms.Label
$lblTitle.Text = "Inactive Mailbox Restore Tool"
$lblTitle.ForeColor = [System.Drawing.Color]::White
$lblTitle.Font = New-Object System.Drawing.Font($FontFamily, 14, [System.Drawing.FontStyle]::Bold)
$lblTitle.Location = New-Object System.Drawing.Point(26, 12)
$lblTitle.AutoSize = $true

$lblSubtitle = New-Object System.Windows.Forms.Label
$lblSubtitle.Text = "Merge retained mailbox content into a reinstated user's mailbox, across tenants."
$lblSubtitle.ForeColor = $Theme.HeaderSub
$lblSubtitle.Font = New-Object System.Drawing.Font($FontFamily, 9)
$lblSubtitle.Location = New-Object System.Drawing.Point(27, 42)
$lblSubtitle.AutoSize = $true

$pnlHeader.Controls.AddRange(@($lblTitle, $lblSubtitle))

# ---- Card (main content) --------------------------------------------------
$pnlCard = New-Object System.Windows.Forms.Panel
$pnlCard.Dock = "Top"
$pnlCard.Height = 490
$pnlCard.BackColor = $Theme.CardBg
$pnlCard.AutoScroll = $true
Add-RoundedBorderPaint -Control $pnlCard -Radius 12 -BorderColor $Theme.CardBorder

# -- Sign in row --
$btnConnect = New-Object System.Windows.Forms.Button
$btnConnect.Text = "Sign In / Connect"
$btnConnect.Location = New-Object System.Drawing.Point(24, 18)
$btnConnect.Size = New-Object System.Drawing.Size(175, 36)
Set-PrimaryButtonStyle -Button $btnConnect

$chkDelegated = New-Object System.Windows.Forms.CheckBox
$chkDelegated.Text = "GDAP: act on customer tenant"
$chkDelegated.Location = New-Object System.Drawing.Point(215, 27)
$chkDelegated.Size = New-Object System.Drawing.Size(250, 20)
$chkDelegated.ForeColor = $Theme.TextDark
$chkDelegated.Font = New-Object System.Drawing.Font($FontFamily, 9.5)

# -- Connection status, top-right (above Clear recent list) --
$lblStatus = New-Object System.Windows.Forms.Label
$lblStatus.Text = "Not connected"
$lblStatus.ForeColor = $Theme.Danger
$lblStatus.Location = New-Object System.Drawing.Point(690, 16)
$lblStatus.Size = New-Object System.Drawing.Size(274, 20)
$lblStatus.TextAlign = "MiddleRight"
$lblStatus.Font = New-Object System.Drawing.Font($FontFamily, 9.5, [System.Drawing.FontStyle]::Bold)

$btnForgetTenants = New-Object System.Windows.Forms.Button
$btnForgetTenants.Text = "Clear recent list"
$btnForgetTenants.Location = New-Object System.Drawing.Point(824, 40)
$btnForgetTenants.Size = New-Object System.Drawing.Size(140, 22)
Set-LinkButtonStyle -Button $btnForgetTenants

# -- GDAP fields row: only shown when the GDAP checkbox is ticked --
$cmbRecent = New-Object System.Windows.Forms.ComboBox
$cmbRecent.Location = New-Object System.Drawing.Point(24, 54)
$cmbRecent.Size = New-Object System.Drawing.Size(220, 26)
$cmbRecent.DropDownStyle = "DropDownList"
$cmbRecent.Font = New-Object System.Drawing.Font($FontFamily, 9)
$cmbRecent.Enabled = $false
$cmbRecent.Visible = $false

function Refresh-TenantDropdown {
    $cmbRecent.Items.Clear()
    foreach ($t in $script:Tenants) { $cmbRecent.Items.Add("$($t.Name)  ($($t.Organization))") | Out-Null }
}
Refresh-TenantDropdown

$cmbRecent.Add_SelectedIndexChanged({
    if ($cmbRecent.SelectedIndex -ge 0 -and $cmbRecent.SelectedIndex -lt $script:Tenants.Count) {
        $txtDelegatedOrg.Text = $script:Tenants[$cmbRecent.SelectedIndex].Organization
    }
})

$txtDelegatedOrg = New-Object System.Windows.Forms.TextBox
$txtDelegatedOrg.Location = New-Object System.Drawing.Point(254, 54)
$txtDelegatedOrg.Size = New-Object System.Drawing.Size(220, 26)
$txtDelegatedOrg.Enabled = $false
$txtDelegatedOrg.Visible = $false
$txtDelegatedOrg.Text = ""
Set-FieldStyle -TextBox $txtDelegatedOrg

$lblDelegatedHint = New-Object System.Windows.Forms.Label
$lblDelegatedHint.Text = "customer's *.onmicrosoft.com domain (GDAP only)"
$lblDelegatedHint.Location = New-Object System.Drawing.Point(484, 58)
$lblDelegatedHint.Size = New-Object System.Drawing.Size(320, 18)
$lblDelegatedHint.ForeColor = $Theme.TextGray
$lblDelegatedHint.Font = New-Object System.Drawing.Font($FontFamily, 8.5)
$lblDelegatedHint.Visible = $false

$chkDelegated.Add_CheckedChanged({
    $cmbRecent.Visible = $chkDelegated.Checked
    $cmbRecent.Enabled = $chkDelegated.Checked
    $txtDelegatedOrg.Visible = $chkDelegated.Checked
    $txtDelegatedOrg.Enabled = $chkDelegated.Checked
    $lblDelegatedHint.Visible = $chkDelegated.Checked
})

# -- Inactive mailbox grid --
$lblGrid = New-Object System.Windows.Forms.Label
$lblGrid.Text = "INACTIVE MAILBOXES"
$lblGrid.Location = New-Object System.Drawing.Point(24, 96)
$lblGrid.Size = New-Object System.Drawing.Size(300, 18)
$lblGrid.ForeColor = $Theme.TextGray
$lblGrid.Font = New-Object System.Drawing.Font($FontFamily, 8.5, [System.Drawing.FontStyle]::Bold)

$btnRefreshInactive = New-Object System.Windows.Forms.Button
$btnRefreshInactive.Text = "Load Inactive Mailboxes"
$btnRefreshInactive.Location = New-Object System.Drawing.Point(798, 90)
$btnRefreshInactive.Size = New-Object System.Drawing.Size(190, 32)
$btnRefreshInactive.Enabled = $false
Set-SecondaryButtonStyle -Button $btnRefreshInactive

$grid = New-Object System.Windows.Forms.DataGridView
$grid.Location = New-Object System.Drawing.Point(24, 126)
$grid.Size = New-Object System.Drawing.Size(940, 150)
$grid.Anchor = "Top,Left,Right"
$grid.ReadOnly = $true
$grid.AllowUserToAddRows = $false
$grid.AllowUserToDeleteRows = $false
$grid.SelectionMode = "FullRowSelect"
$grid.MultiSelect = $false
$grid.AutoSizeColumnsMode = "Fill"
$grid.RowHeadersVisible = $false
$grid.BorderStyle = "None"
$grid.CellBorderStyle = "SingleHorizontal"
$grid.GridColor = $Theme.CardBorder
$grid.BackgroundColor = [System.Drawing.Color]::White
$grid.EnableHeadersVisualStyles = $false
$grid.ColumnHeadersHeight = 30
$grid.ColumnHeadersDefaultCellStyle.BackColor = $Theme.HeaderBg
$grid.ColumnHeadersDefaultCellStyle.ForeColor = [System.Drawing.Color]::White
$grid.ColumnHeadersDefaultCellStyle.Font = New-Object System.Drawing.Font($FontFamily, 9, [System.Drawing.FontStyle]::Bold)
$grid.ColumnHeadersDefaultCellStyle.Alignment = "MiddleLeft"
$grid.DefaultCellStyle.Font = New-Object System.Drawing.Font($FontFamily, 9)
$grid.DefaultCellStyle.SelectionBackColor = [System.Drawing.Color]::FromArgb(219, 234, 254)
$grid.DefaultCellStyle.SelectionForeColor = $Theme.TextDark
$grid.AlternatingRowsDefaultCellStyle.BackColor = [System.Drawing.Color]::FromArgb(249, 250, 251)
$grid.RowTemplate.Height = 26
$grid.Columns.Add("Name", "Name") | Out-Null
$grid.Columns.Add("PrimarySmtpAddress", "Primary SMTP") | Out-Null
$grid.Columns.Add("ExchangeGuid", "ExchangeGuid") | Out-Null
$grid.Columns.Add("WhenSoftDeleted", "Soft-Deleted On") | Out-Null
$grid.Columns.Add("LitigationHoldEnabled", "Litigation Hold") | Out-Null

# -- Target mailbox picker, with the mismatch checkbox inline on the same row --
$lblTarget = New-Object System.Windows.Forms.Label
$lblTarget.Text = "TARGET MAILBOX (REINSTATED USER, UPN OR SMTP)"
$lblTarget.Location = New-Object System.Drawing.Point(24, 300)
$lblTarget.Size = New-Object System.Drawing.Size(400, 18)
$lblTarget.ForeColor = $Theme.TextGray
$lblTarget.Font = New-Object System.Drawing.Font($FontFamily, 8.5, [System.Drawing.FontStyle]::Bold)

$txtTarget = New-Object System.Windows.Forms.TextBox
$txtTarget.Location = New-Object System.Drawing.Point(24, 320)
$txtTarget.Size = New-Object System.Drawing.Size(300, 28)
Set-FieldStyle -TextBox $txtTarget

$btnVerifyTarget = New-Object System.Windows.Forms.Button
$btnVerifyTarget.Text = "Verify Target"
$btnVerifyTarget.Location = New-Object System.Drawing.Point(334, 319)
$btnVerifyTarget.Size = New-Object System.Drawing.Size(130, 30)
$btnVerifyTarget.Enabled = $false
Set-SecondaryButtonStyle -Button $btnVerifyTarget

$chkAllowMismatch = New-Object System.Windows.Forms.CheckBox
$chkAllowMismatch.Text = "Allow legacy DN mismatch (bypass X500/LegacyExchangeDN check)"
$chkAllowMismatch.Location = New-Object System.Drawing.Point(478, 325)
$chkAllowMismatch.Size = New-Object System.Drawing.Size(486, 20)
$chkAllowMismatch.ForeColor = $Theme.TextDark
$chkAllowMismatch.Font = New-Object System.Drawing.Font($FontFamily, 9)

$lblTargetStatus = New-Object System.Windows.Forms.Label
$lblTargetStatus.Text = ""
$lblTargetStatus.Location = New-Object System.Drawing.Point(24, 356)
$lblTargetStatus.Size = New-Object System.Drawing.Size(940, 26)
$lblTargetStatus.Font = New-Object System.Drawing.Font($FontFamily, 9)

$lblAllowMismatchHint = New-Object System.Windows.Forms.Label
$lblAllowMismatchHint.Text = "Exchange normally requires the source mailbox's LegacyExchangeDN to appear as an X500 proxy on the target, so old internal replies still resolve. Tick this only if you understand that risk and want to skip that check (adds -AllowLegacyDNMismatch to the restore request)."
$lblAllowMismatchHint.Location = New-Object System.Drawing.Point(24, 384)
$lblAllowMismatchHint.Size = New-Object System.Drawing.Size(940, 32)
$lblAllowMismatchHint.ForeColor = $Theme.TextGray
$lblAllowMismatchHint.Font = New-Object System.Drawing.Font($FontFamily, 8)
$lblAllowMismatchHint.Visible = $false

$chkAllowMismatch.Add_CheckedChanged({
    $lblAllowMismatchHint.Visible = $chkAllowMismatch.Checked
})

# -- Action buttons --
$btnAddX500 = New-Object System.Windows.Forms.Button
$btnAddX500.Text = "1. Add X500 Proxy to Target"
$btnAddX500.Location = New-Object System.Drawing.Point(24, 430)
$btnAddX500.Size = New-Object System.Drawing.Size(296, 38)
$btnAddX500.Enabled = $false
Set-SecondaryButtonStyle -Button $btnAddX500

$btnStartRestore = New-Object System.Windows.Forms.Button
$btnStartRestore.Text = "2. Start Restore Request"
$btnStartRestore.Location = New-Object System.Drawing.Point(332, 430)
$btnStartRestore.Size = New-Object System.Drawing.Size(296, 38)
$btnStartRestore.Enabled = $false
Set-PrimaryButtonStyle -Button $btnStartRestore

$btnCheckStatus = New-Object System.Windows.Forms.Button
$btnCheckStatus.Text = "3. Check Restore Status"
$btnCheckStatus.Location = New-Object System.Drawing.Point(640, 430)
$btnCheckStatus.Size = New-Object System.Drawing.Size(296, 38)
$btnCheckStatus.Enabled = $false
Set-SecondaryButtonStyle -Button $btnCheckStatus

$pnlCard.Controls.AddRange(@(
    $btnConnect, $chkDelegated, $lblStatus, $btnForgetTenants,
    $cmbRecent, $txtDelegatedOrg, $lblDelegatedHint,
    $lblGrid, $btnRefreshInactive, $grid,
    $lblTarget, $txtTarget, $btnVerifyTarget, $chkAllowMismatch, $lblTargetStatus, $lblAllowMismatchHint,
    $btnAddX500, $btnStartRestore, $btnCheckStatus
))

# ---- Console / activity log -----------------------------------------------
$pnlConsole = New-Object System.Windows.Forms.Panel
$pnlConsole.Dock = "Fill"
$pnlConsole.BackColor = $Theme.ConsoleBg
Add-RoundedBorderPaint -Control $pnlConsole -Radius 12 -BorderColor ([System.Drawing.Color]::FromArgb(30, 41, 59))

$pnlConsole.Padding = New-Object System.Windows.Forms.Padding(16, 8, 16, 10)

$lblLog = New-Object System.Windows.Forms.Label
$lblLog.Text = "ACTIVITY LOG"
$lblLog.Dock = "Top"
$lblLog.Height = 22
$lblLog.ForeColor = [System.Drawing.Color]::FromArgb(148, 163, 184)
$lblLog.Font = New-Object System.Drawing.Font($FontFamily, 8.5, [System.Drawing.FontStyle]::Bold)
$lblLog.BackColor = [System.Drawing.Color]::Transparent

$txtLog = New-Object System.Windows.Forms.RichTextBox
$txtLog.Dock = "Fill"
$txtLog.ReadOnly = $true
$txtLog.ScrollBars = "Vertical"
$txtLog.BorderStyle = "None"
$txtLog.BackColor = $Theme.ConsoleBg
$txtLog.ForeColor = $Theme.ConsoleText
$txtLog.Font = New-Object System.Drawing.Font("Consolas", 9)
$script:txtLog = $txtLog

# Dock order: add txtLog (Fill) first so it's processed last and takes
# whatever remains after the header label claims its Top strip.
$pnlConsole.Controls.Add($txtLog)
$pnlConsole.Controls.Add($lblLog)

$splitter = New-Object System.Windows.Forms.Splitter
$splitter.Dock = "Top"
$splitter.Height = 8
$splitter.BackColor = [System.Drawing.Color]::FromArgb(203, 213, 225)
$splitter.MinSize = 320
$splitter.MinExtra = 70

$pnlBody = New-Object System.Windows.Forms.Panel
$pnlBody.Dock = "Fill"
$pnlBody.BackColor = $Theme.PageBg
$pnlBody.Padding = New-Object System.Windows.Forms.Padding(26, 12, 26, 20)

# Dock stacking order matters: the LAST control added claims space closest to
# the container's edge first. Adding Fill-docked content first, then the
# splitter, then the card last, produces (top to bottom): card, splitter,
# console filling whatever remains - and dragging the splitter resizes the
# card, revealing more or less of the console/log area beneath it.
$pnlBody.Controls.Add($pnlConsole)
$pnlBody.Controls.Add($splitter)
$pnlBody.Controls.Add($pnlCard)

$pnlFooter = New-Object System.Windows.Forms.Panel
$pnlFooter.Dock = "Bottom"
$pnlFooter.Height = 26
$pnlFooter.BackColor = $Theme.PageBg

$lblCreatedBy = New-Object System.Windows.Forms.Label
$lblCreatedBy.Text = "Created by Chris Ntuli"
$lblCreatedBy.ForeColor = $Theme.TextGray
$lblCreatedBy.Font = New-Object System.Drawing.Font($FontFamily, 8.5)
$lblCreatedBy.Width = 220
$lblCreatedBy.Dock = "Right"
$lblCreatedBy.TextAlign = "MiddleRight"
$lblCreatedBy.Padding = New-Object System.Windows.Forms.Padding(0, 0, 12, 0)

$pnlFooter.Controls.Add($lblCreatedBy)

$form.Controls.Add($pnlBody)
$form.Controls.Add($pnlFooter)
$form.Controls.Add($pnlHeader)



# ---------------------------------------------------------------------------
# Event handlers
# ---------------------------------------------------------------------------

$btnForgetTenants.Add_Click({
    $confirm = [System.Windows.Forms.MessageBox]::Show("Clear the remembered tenant list from tenants.json?", "Confirm", "YesNo", "Question")
    if ($confirm -eq "Yes") {
        $script:Tenants = @()
        Save-Tenants
        Refresh-TenantDropdown
        Write-Log "Recent tenant list cleared." "INFO"
    }
})

$btnConnect.Add_Click({
    $delegatedOrg = ""
    if ($chkDelegated.Checked) {
        $delegatedOrg = $txtDelegatedOrg.Text.Trim()
        if (-not $delegatedOrg) {
            [System.Windows.Forms.MessageBox]::Show("Enter the customer's tenant domain (e.g. contoso.onmicrosoft.com) for the GDAP connection.", "Missing input", "OK", "Warning") | Out-Null
            return
        }
    }

    if (Connect-EXOInteractive -DelegatedOrganization $delegatedOrg) {
        $btnRefreshInactive.Enabled = $true
        $btnVerifyTarget.Enabled = $true
        $grid.Rows.Clear()
        $txtTarget.Clear()
        $lblTargetStatus.Text = ""
        $btnAddX500.Enabled = $false
        $btnStartRestore.Enabled = $false
        $btnCheckStatus.Enabled = $false
        $script:SelectedInactive = $null
        $script:TargetIsDirSynced = $null
    }
})

$btnRefreshInactive.Add_Click({
    try {
        $grid.Rows.Clear()
        Write-Log "Querying inactive mailboxes in '$($script:ConnectedTenant.Name)'..." "INFO"
        $script:InactiveMailboxes = Get-Mailbox -InactiveMailboxOnly -ResultSize Unlimited |
            Select-Object Name, PrimarySmtpAddress, ExchangeGuid, DistinguishedName, LegacyExchangeDN,
                           WhenSoftDeleted, LitigationHoldEnabled, RetentionHoldEnabled

        foreach ($mbx in $script:InactiveMailboxes) {
            $grid.Rows.Add(
                $mbx.Name,
                $mbx.PrimarySmtpAddress,
                $mbx.ExchangeGuid,
                $mbx.WhenSoftDeleted,
                $mbx.LitigationHoldEnabled
            ) | Out-Null
        }
        Write-Log "Loaded $($script:InactiveMailboxes.Count) inactive mailbox(es)." "INFO"
    }
    catch {
        Write-Log "Failed to load inactive mailboxes: $($_.Exception.Message)" "ERROR"
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, "Error", "OK", "Error") | Out-Null
    }
})

$grid.Add_SelectionChanged({
    if ($grid.SelectedRows.Count -eq 0) { return }
    $guidStr = $grid.SelectedRows[0].Cells["ExchangeGuid"].Value
    $script:SelectedInactive = $script:InactiveMailboxes | Where-Object { $_.ExchangeGuid -eq $guidStr }
    if ($script:SelectedInactive) {
        $m = $script:SelectedInactive
        $btnStartRestore.Enabled = $true
        Update-AddX500ButtonState
        Write-Log "Selected inactive mailbox: $($m.PrimarySmtpAddress) | GUID=$($m.ExchangeGuid) | LegacyExchangeDN=$($m.LegacyExchangeDN) | WhenSoftDeleted=$($m.WhenSoftDeleted) | LitigationHold=$($m.LitigationHoldEnabled) | RetentionHold=$($m.RetentionHoldEnabled)" "INFO"
    }
})

function Update-AddX500ButtonState {
    if ($script:SelectedInactive -and $txtTarget.Text.Trim() -and $script:TargetIsDirSynced -eq $false) {
        $btnAddX500.Enabled = $true
        $btnAddX500.Text = "1. Add X500 Proxy to Target"
    }
    elseif ($script:SelectedInactive -and $txtTarget.Text.Trim() -and $script:TargetIsDirSynced -eq $true) {
        $btnAddX500.Enabled = $false
        $btnAddX500.Text = "1. Add X500 Proxy (on-prem - see below)"
    }
    else {
        $btnAddX500.Enabled = $false
    }
}

$btnVerifyTarget.Add_Click({
    $target = $txtTarget.Text.Trim()
    if (-not $target) {
        [System.Windows.Forms.MessageBox]::Show("Enter a target mailbox UPN or SMTP address first.", "Missing input", "OK", "Warning") | Out-Null
        return
    }
    try {
        $mbx = Get-Mailbox -Identity $target -ErrorAction Stop
        $script:TargetIsDirSynced = [bool]$mbx.IsDirSynced

        if ($script:TargetIsDirSynced) {
            $lblTargetStatus.Text = "Found: $($mbx.PrimarySmtpAddress)  -  SYNCED from on-prem AD via Entra Connect.`r`nThe X500 proxy must be added on-prem (see log/message), not via Set-Mailbox - Entra Connect will overwrite it on the next sync cycle otherwise."
            $lblTargetStatus.ForeColor = $Theme.Warn
        } else {
            $lblTargetStatus.Text = "Found: $($mbx.PrimarySmtpAddress)  -  Cloud-only mailbox. X500 proxy can be added directly via Set-Mailbox."
            $lblTargetStatus.ForeColor = $Theme.Success
        }
        Write-Log "Verified target mailbox: $($mbx.PrimarySmtpAddress). IsDirSynced=$($script:TargetIsDirSynced)" "INFO"
        Update-AddX500ButtonState
    }
    catch {
        $script:TargetIsDirSynced = $null
        $lblTargetStatus.Text = "Not found"
        $lblTargetStatus.ForeColor = $Theme.Danger
        Write-Log "Target mailbox not found: $target" "WARN"
        Update-AddX500ButtonState
    }
})

$btnAddX500.Add_Click({
    if (-not $script:SelectedInactive) { return }
    $target = $txtTarget.Text.Trim()
    if (-not $target) {
        [System.Windows.Forms.MessageBox]::Show("Enter and verify a target mailbox first.", "Missing input", "OK", "Warning") | Out-Null
        return
    }
    if ($script:TargetIsDirSynced) {
        [System.Windows.Forms.MessageBox]::Show(
            "This target is synced from on-prem AD. Adding the proxy here would be overwritten on the next Entra Connect sync.`n`nRun this on a domain controller / management server instead:`n`nSet-ADUser -Identity <sAMAccountName> -Add @{proxyAddresses='X500:$($script:SelectedInactive.LegacyExchangeDN)'}",
            "On-prem action required", "OK", "Warning") | Out-Null
        return
    }

    $confirm = [System.Windows.Forms.MessageBox]::Show(
        "Add X500:$($script:SelectedInactive.LegacyExchangeDN) as a proxy address on '$target'?",
        "Confirm", "YesNo", "Question")
    if ($confirm -ne "Yes") { return }

    try {
        $x500 = "X500:$($script:SelectedInactive.LegacyExchangeDN)"
        Set-Mailbox -Identity $target -EmailAddresses @{Add = $x500 } -ErrorAction Stop
        Write-Log "ACTION: Added X500 proxy '$x500' to target '$target' (cloud-only)." "ACTION"
        [System.Windows.Forms.MessageBox]::Show("X500 proxy address added.", "Done", "OK", "Information") | Out-Null
    }
    catch {
        Write-Log "Failed to add X500 proxy: $($_.Exception.Message)" "ERROR"
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, "Error", "OK", "Error") | Out-Null
    }
})

$btnStartRestore.Add_Click({
    if (-not $script:SelectedInactive) { return }
    $target = $txtTarget.Text.Trim()
    if (-not $target) {
        [System.Windows.Forms.MessageBox]::Show("Enter and verify a target mailbox first.", "Missing input", "OK", "Warning") | Out-Null
        return
    }
    if ($script:TargetIsDirSynced -eq $true) {
        $proceed = [System.Windows.Forms.MessageBox]::Show(
            "Target is a synced mailbox. Have you already added the X500 proxy on-prem and let it sync through?`n`nContinue with the restore request anyway?",
            "Synced target - confirm on-prem step", "YesNo", "Warning")
        if ($proceed -ne "Yes") { return }
    }

    $confirmText = "Start a restore request merging inactive mailbox '$($script:SelectedInactive.PrimarySmtpAddress)' into '$target'?`n`nThis is the compliance-relevant action - it will be logged."
    if ($chkAllowMismatch.Checked) {
        $confirmText += "`n`n'Allow legacy DN mismatch' is ON - the restore will proceed even though the source's LegacyExchangeDN isn't present as an X500 proxy on the target. Old internal replies to the former mailbox may not resolve correctly."
    }
    $confirm = [System.Windows.Forms.MessageBox]::Show($confirmText, "Confirm Restore", "YesNo", "Warning")
    if ($confirm -ne "Yes") { return }

    try {
        Write-Log "PRE-RESTORE SNAPSHOT: $($script:SelectedInactive | Out-String)" "ACTION"

        $restoreParams = @{
            SourceMailbox = $script:SelectedInactive.ExchangeGuid
            TargetMailbox = $target
            ErrorAction   = "Stop"
        }
        if ($chkAllowMismatch.Checked) {
            $restoreParams["AllowLegacyDNMismatch"] = $true
            Write-Log "AllowLegacyDNMismatch is enabled for this restore request." "WARN"
        }

        $req = New-MailboxRestoreRequest @restoreParams
        Write-Log "ACTION: Restore request created. RequestGuid=$($req.RequestGuid) Source=$($script:SelectedInactive.PrimarySmtpAddress) Target=$target Tenant=$($script:ConnectedTenant.Name) AllowLegacyDNMismatch=$($chkAllowMismatch.Checked)" "ACTION"
        $btnCheckStatus.Enabled = $true
        [System.Windows.Forms.MessageBox]::Show("Restore request started. Use 'Check Restore Status' to monitor progress.", "Started", "OK", "Information") | Out-Null
    }
    catch {
        Write-Log "Failed to start restore request: $($_.Exception.Message)" "ERROR"
        if ($_.Exception.Message -match "AllowLegacyDNMismatch") {
            [System.Windows.Forms.MessageBox]::Show(
                "This restore failed because the source mailbox's LegacyExchangeDN isn't registered as an X500 proxy on the target.`n`nEither run the 'Add X500 Proxy' step (or its on-prem equivalent) and try again, or tick 'Allow legacy DN mismatch' below and retry to bypass the check.",
                "LegacyExchangeDN Mismatch", "OK", "Warning") | Out-Null
        }
        else {
            [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, "Error", "OK", "Error") | Out-Null
        }
    }
})

$btnCheckStatus.Add_Click({
    $target = $txtTarget.Text.Trim()
    try {
        $requests = Get-MailboxRestoreRequest -TargetMailbox $target -ErrorAction Stop
        if (-not $requests) {
            Write-Log "No restore requests found for target '$target'." "INFO"
            return
        }
        foreach ($r in $requests) {
            $stats = Get-MailboxRestoreRequestStatistics -Identity $r.Identity
            $line = "RequestGuid=$($r.RequestGuid) Status=$($r.Status) PercentComplete=$($stats.PercentComplete)% BytesTransferred=$($stats.BytesTransferred)"
            Write-Log $line "INFO"
            if ($r.Status -eq "Completed") {
                Write-Log "Restore COMPLETED for target '$target'. The inactive mailbox will be removed by Exchange Online automatically." "ACTION"
            }
        }
    }
    catch {
        Write-Log "Failed to check restore status: $($_.Exception.Message)" "ERROR"
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, "Error", "OK", "Error") | Out-Null
    }
})

$form.Add_FormClosing({
    Disconnect-EXOIfConnected
})

Write-Log "Tool started." "INFO"
[System.Windows.Forms.Application]::EnableVisualStyles()
[System.Windows.Forms.Application]::Run($form)
