<#
.SYNOPSIS
    Reports mailbox size and last-logon time for every mailbox in the
    Exchange organization.

.DESCRIPTION
    Read-only inventory. For each mailbox it collects, from Get-Mailbox and
    Get-MailboxStatistics:

      * DisplayName
      * EmailAddress   (PrimarySmtpAddress)
      * MailboxSize    (GB / MB, plus raw bytes for accurate sorting)
      * LastLogon      (when the mailbox was last accessed)

    By default the results are shown in an interactive Out-GridView window
    (sortable, filterable). Add -ExportCsv to also write a CSV whose columns
    are DisplayName, EmailAddress, MailboxSizeGB and LastLogon (with a few
    extra useful columns after them).

    Zero-touch: nothing is hardcoded. The script uses whatever Exchange
    connection is already available (Exchange Management Shell), or auto-loads
    the on-box Exchange snap-in, or - as a last resort - discovers an Exchange
    server from Active Directory and opens an implicit remoting session to it.
    It therefore runs unmodified in any on-premises Exchange organization.

    Nothing here writes to mailboxes, AD, or the servers. Safe to run anytime.

.PARAMETER Identity
    One or more specific mailboxes to report on. Omit to report on all
    mailboxes (default).

.PARAMETER Database
    Limit the report to a single mailbox database.

.PARAMETER OrganizationalUnit
    Limit the report to mailboxes under a specific OU.

.PARAMETER RecipientTypeDetails
    Filter by mailbox type (e.g. UserMailbox, SharedMailbox, RoomMailbox,
    EquipmentMailbox). Accepts multiple values. Default: all mailbox types.

.PARAMETER ActiveWithinMonths
    Return only mailboxes whose last logon falls within the last N months.
    Valid values: 6, 12, 24, 36, 48. Mutually exclusive with -InactiveForMonths.

.PARAMETER InactiveForMonths
    Return only mailboxes that have NOT logged on in the last N months,
    including mailboxes that have never been logged on at all.
    Valid values: 6, 12, 24, 36, 48. Mutually exclusive with -ActiveWithinMonths.

.PARAMETER ExportCsv
    Also export the results to a CSV file.

.PARAMETER CsvPath
    Where to write the CSV. Defaults to the current user's Desktop as
    MailboxSizeReport_<yyyyMMdd_HHmmss>.csv. Implies -ExportCsv when supplied.

.PARAMETER NoGridView
    Suppress the Out-GridView window (useful when you only want the CSV, or
    when running on a machine with no GUI). Results are still returned to the
    pipeline and, if requested, written to CSV.

.EXAMPLE
    .\Get-MailboxSizeReport.ps1
    Report every mailbox and open the interactive grid.

.EXAMPLE
    .\Get-MailboxSizeReport.ps1 -ExportCsv
    Grid view plus a CSV on the Desktop.

.EXAMPLE
    .\Get-MailboxSizeReport.ps1 -Database 'DB01' -ExportCsv -CsvPath 'C:\Temp\DB01.csv' -NoGridView
    CSV only, limited to one database.

.EXAMPLE
    .\Get-MailboxSizeReport.ps1 -InactiveForMonths 12 -ExportCsv
    Only mailboxes with no logon in the last 12 months (incl. never), to grid + CSV.

.EXAMPLE
    .\Get-MailboxSizeReport.ps1 -ActiveWithinMonths 6
    Only mailboxes that have logged on within the last 6 months.

.NOTES
    Run from the Exchange Management Shell (or any Windows PowerShell where the
    Exchange snap-in / RBAC access is available) as an account with at least
    View-Only Organization Management rights.
    Out-GridView requires a GUI-capable host; on Server Core (or if it is
    unavailable) the script falls back to a formatted table automatically.
#>

[CmdletBinding()]
param(
    [string[]]$Identity,
    [string]$Database,
    [string]$OrganizationalUnit,
    [string[]]$RecipientTypeDetails,

    # Return only mailboxes whose last logon falls within the last N months.
    [ValidateSet(6, 12, 24, 36, 48)]
    [int]$ActiveWithinMonths,

    # Return only mailboxes that have NOT logged on in the last N months
    # (includes mailboxes that have never been logged on at all).
    [ValidateSet(6, 12, 24, 36, 48)]
    [int]$InactiveForMonths,

    [switch]$ExportCsv,
    [string]$CsvPath,
    [switch]$NoGridView
)

if ($PSBoundParameters.ContainsKey('ActiveWithinMonths') -and
    $PSBoundParameters.ContainsKey('InactiveForMonths')) {
    Write-Error "-ActiveWithinMonths and -InactiveForMonths are mutually exclusive; specify only one."
    return
}

# =============================================================================
# Ensure we have the Exchange cmdlets (zero-touch: nothing hardcoded)
# =============================================================================
function Initialize-ExchangeConnection {
    # 1. Already connected (Exchange Management Shell / prior session)?
    if (Get-Command Get-Mailbox -ErrorAction SilentlyContinue) { return $true }

    # 2. On-box Exchange 2016/2019 management snap-in.
    $snapin = 'Microsoft.Exchange.Management.PowerShell.SnapIn'
    if (Get-PSSnapin -Registered -Name $snapin -ErrorAction SilentlyContinue) {
        try {
            Add-PSSnapin $snapin -ErrorAction Stop
            Write-Host "Loaded Exchange management snap-in." -ForegroundColor DarkGray
            if (Get-Command Get-Mailbox -ErrorAction SilentlyContinue) { return $true }
        } catch { }
    }

    # 3. Discover an Exchange server from AD (module-free ADSI) and open an
    #    implicit remoting session to its PowerShell endpoint.
    try {
        $configNC = ([ADSI]'LDAP://RootDSE').configurationNamingContext
        $searcher = New-Object System.DirectoryServices.DirectorySearcher
        $searcher.SearchRoot = [ADSI]("LDAP://CN=Microsoft Exchange,CN=Services,$configNC")
        $searcher.Filter     = '(objectClass=msExchExchangeServer)'
        [void]$searcher.PropertiesToLoad.Add('networkAddress')
        [void]$searcher.PropertiesToLoad.Add('cn')
        $exServer = $null
        foreach ($r in $searcher.FindAll()) {
            # networkAddress holds entries like "ncacn_ip_tcp:server.contoso.com"
            foreach ($na in $r.Properties['networkaddress']) {
                if ($na -match 'ncacn_ip_tcp:(.+)$') { $exServer = $Matches[1]; break }
            }
            if (-not $exServer -and $r.Properties['cn']) { $exServer = "$($r.Properties['cn'][0])" }
            if ($exServer) { break }
        }
        if ($exServer) {
            Write-Host "Connecting to discovered Exchange server: $exServer" -ForegroundColor DarkGray
            $uri = "http://$exServer/PowerShell/"
            $session = New-PSSession -ConfigurationName Microsoft.Exchange `
                -ConnectionUri $uri -Authentication Kerberos -ErrorAction Stop
            Import-PSSession $session -DisableNameChecking -AllowClobber `
                -CommandName Get-Mailbox,Get-MailboxStatistics | Out-Null
            if (Get-Command Get-Mailbox -ErrorAction SilentlyContinue) { return $true }
        }
    } catch {
        Write-Warning "Could not auto-connect to Exchange: $($_.Exception.Message)"
    }

    return $false
}

if (-not (Initialize-ExchangeConnection)) {
    Write-Error "Exchange cmdlets are not available. Run this from the Exchange Management Shell, or on a machine that can reach an Exchange server."
    return
}

# =============================================================================
# Helpers
# =============================================================================
# TotalItemSize is a ByteQuantifiedSize when local, but a plain string like
# "1.234 GB (1,325,400,064 bytes)" when the cmdlets come from a remote session.
# Handle both and always return a byte count.
function Get-SizeInBytes {
    param($Size)
    if ($null -eq $Size) { return $null }
    # Local ByteQuantifiedSize exposes .Value.ToBytes()
    try {
        if ($Size.PSObject.Properties['Value'] -and $Size.Value) {
            return [double]$Size.Value.ToBytes()
        }
    } catch { }
    # Fall back to parsing "... (1,234,567 bytes)" out of the string form.
    $text = "$Size"
    if ($text -match '\(([\d,]+)\s*bytes\)') {
        return [double]($Matches[1] -replace ',', '')
    }
    return $null
}

# =============================================================================
# Gather mailboxes
# =============================================================================
$getMailboxParams = @{ ResultSize = 'Unlimited'; ErrorAction = 'Stop' }
if ($Database)             { $getMailboxParams.Database             = $Database }
if ($OrganizationalUnit)   { $getMailboxParams.OrganizationalUnit   = $OrganizationalUnit }
if ($RecipientTypeDetails) { $getMailboxParams.RecipientTypeDetails = $RecipientTypeDetails }

Write-Host "Retrieving mailboxes..." -ForegroundColor Cyan
try {
    if ($Identity) {
        $mailboxes = foreach ($id in $Identity) { Get-Mailbox -Identity $id -ErrorAction Stop }
    } else {
        $mailboxes = Get-Mailbox @getMailboxParams
    }
} catch {
    Write-Error "Failed to retrieve mailboxes: $($_.Exception.Message)"
    return
}

$total = @($mailboxes).Count
if ($total -eq 0) { Write-Warning "No mailboxes matched the given criteria."; return }
Write-Host "Found $total mailbox(es). Collecting statistics..." -ForegroundColor Cyan

# =============================================================================
# Collect size + last logon per mailbox
# =============================================================================
$report = New-Object System.Collections.Generic.List[object]
$i = 0
foreach ($mbx in $mailboxes) {
    $i++
    Write-Progress -Activity 'Collecting mailbox statistics' `
        -Status ("[{0}/{1}] {2}" -f $i, $total, $mbx.DisplayName) `
        -PercentComplete (($i / $total) * 100)

    $stats = $null
    try { $stats = Get-MailboxStatistics -Identity $mbx.Guid.ToString() -ErrorAction Stop }
    catch {
        try { $stats = Get-MailboxStatistics -Identity $mbx.DistinguishedName -ErrorAction Stop } catch { }
    }

    $bytes    = if ($stats) { Get-SizeInBytes $stats.TotalItemSize } else { $null }
    $sizeGB   = if ($null -ne $bytes) { [math]::Round($bytes / 1GB, 2) } else { $null }
    $sizeMB   = if ($null -ne $bytes) { [math]::Round($bytes / 1MB, 2) } else { $null }
    $lastLogon = if ($stats) { $stats.LastLogonTime } else { $null }

    $report.Add([pscustomobject]@{
        DisplayName          = $mbx.DisplayName
        EmailAddress         = "$($mbx.PrimarySmtpAddress)"
        MailboxSizeGB        = $sizeGB
        LastLogon            = $lastLogon
        MailboxSizeMB        = $sizeMB
        ItemCount            = if ($stats) { $stats.ItemCount } else { $null }
        LastLoggedOnUser     = if ($stats) { $stats.LastLoggedOnUserAccount } else { $null }
        RecipientTypeDetails = "$($mbx.RecipientTypeDetails)"
        Database             = "$($mbx.Database)"
        SizeBytes            = $bytes
    })
}
Write-Progress -Activity 'Collecting mailbox statistics' -Completed

# =============================================================================
# Optional last-logon filter (active-within / inactive-for a number of months)
# =============================================================================
if ($PSBoundParameters.ContainsKey('ActiveWithinMonths')) {
    $cutoff = (Get-Date).AddMonths(-$ActiveWithinMonths)
    # Active = has logged on AND that logon is on/after the cutoff.
    $report = $report | Where-Object { $_.LastLogon -and $_.LastLogon -ge $cutoff }
    Write-Host ("Filter: last logon within {0} months (on/after {1:yyyy-MM-dd}) - {2} match(es)." -f `
        $ActiveWithinMonths, $cutoff, @($report).Count) -ForegroundColor Cyan
}
elseif ($PSBoundParameters.ContainsKey('InactiveForMonths')) {
    $cutoff = (Get-Date).AddMonths(-$InactiveForMonths)
    # Inactive = never logged on, OR the last logon is before the cutoff.
    $report = $report | Where-Object { -not $_.LastLogon -or $_.LastLogon -lt $cutoff }
    Write-Host ("Filter: no logon in the last {0} months (before {1:yyyy-MM-dd}, incl. never) - {2} match(es)." -f `
        $InactiveForMonths, $cutoff, @($report).Count) -ForegroundColor Cyan
}

# Largest mailboxes first; never-logged-on ($null bytes) sort to the bottom.
$report = $report | Sort-Object -Property @{ Expression = 'SizeBytes'; Descending = $true }
$shown  = @($report).Count
if ($shown -eq 0) { Write-Warning "No mailboxes matched after filtering."; return }

# =============================================================================
# Output: CSV (optional) + Out-GridView (default)
# =============================================================================
if ($CsvPath) { $ExportCsv = $true }

if ($ExportCsv) {
    if (-not $CsvPath) {
        $desktop = [Environment]::GetFolderPath('Desktop')
        $stamp   = Get-Date -Format 'yyyyMMdd_HHmmss'
        $CsvPath = Join-Path $desktop "MailboxSizeReport_$stamp.csv"
    }
    try {
        # Core requested columns first, then the extras.
        $report |
            Select-Object DisplayName, EmailAddress, MailboxSizeGB, LastLogon,
                          MailboxSizeMB, ItemCount, LastLoggedOnUser,
                          RecipientTypeDetails, Database |
            Export-Csv -Path $CsvPath -NoTypeInformation -Encoding UTF8
        Write-Host "Exported $shown row(s) to: $CsvPath" -ForegroundColor Green
    } catch {
        Write-Error "Failed to write CSV to '$CsvPath': $($_.Exception.Message)"
    }
}

if (-not $NoGridView) {
    if (Get-Command Out-GridView -ErrorAction SilentlyContinue) {
        $report |
            Select-Object DisplayName, EmailAddress, MailboxSizeGB, LastLogon,
                          MailboxSizeMB, ItemCount, LastLoggedOnUser,
                          RecipientTypeDetails, Database |
            Out-GridView -Title "Mailbox Size & Last Logon Report  ($shown mailboxes)"
    } else {
        Write-Warning "Out-GridView is not available on this host; showing a table instead."
        $report |
            Select-Object DisplayName, EmailAddress, MailboxSizeGB, LastLogon |
            Format-Table -AutoSize
    }
}

# Always return the objects so the script composes in a pipeline.
$report
