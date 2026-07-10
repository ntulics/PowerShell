<#
    .SYNOPSIS
    Creates an HTML report describing the On-Premises Exchange environment.

    Maintained by: Chris Ntuli
    Based on the original Get-ExchangeEnvironmentReport by Steve Goodman (later maintained by Thomas Stensitzki)

    THIS CODE IS MADE AVAILABLE AS IS, WITHOUT WARRANTY OF ANY KIND. THE ENTIRE
    RISK OF THE USE OR THE RESULTS FROM THE USE OF THIS CODE REMAINS WITH THE USER.

    Version 2.8 July 2026

    Based on the original 1.6.2 version by Steve Goodman

    Version 2.8 changes (Chris Ntuli):
    * OS "Service Pack" replaced with OS update level: the Windows build including UBR
      (10.0.<build>.<UBR>), display version, and the most recent installed update KB.
    * Exchange version now shows the full build number and identifies the Cumulative
      Update, flags whether a newer CU is available (per the Microsoft build-numbers
      page), and shows the support-lifecycle status (Mainstream / Extended / Out of
      support). The same lifecycle status is shown for the Windows Server OS.
    * "Preferred / Max active DBs" replaced with the real counts: databases currently
      active on the server vs. databases for which it is the preferred (activation
      preference 1) owner, highlighted when they differ.
    * Reference data (latest builds, CU maps, support dates) lives in maintainable
      tables near the top of the script - update periodically from the Microsoft pages.
    * Exchange Server SE is detected separately from Exchange 2019 (both are version
      15.2; SE is identified by build >= 15.2.2562) and shown as supported under the
      Modern Lifecycle Policy rather than being mistaken for out-of-support Exchange 2019.

    Version 2.7 changes (Chris Ntuli):
    * Redesigned into a modern, server-centric dashboard: a header with KPI severity
      tiles (Critical / Warnings / Servers / Databases / Mailboxes) and one collapsible
      card per server. Each server card shows its details, disk-usage donuts per volume,
      and its databases underneath - no more single very wide table.
    * Edition-aware capacity intelligence. Each database shows a size-vs-maximum donut.
      The maximum comes from the per-database registry value 'Database Size Limit in GB'
      if set, otherwise the edition default: Exchange Standard 1024 GB (-StandardMaxDatabaseSizeGB),
      Exchange Enterprise has no hard limit so a best-practice ceiling is used for the donut
      (-EnterpriseMaxDatabaseSizeGB, default 2048). Databases at/above -DatabaseSizeCautionPercent
      (amber) or -DatabaseSizeWarningPercent (red) are highlighted with advice.
    * Edition database-count reporting. Standard allows 5 mounted databases per server,
      Enterprise 100. The report counts copies hosted per server (active + passive) and
      advises when a server is near/at its limit, including the DAG per-member view.
    * Certificates now EXCLUDE self-signed certificates and show issuer, services, key
      size, validity window and expiry, grouped per server.
    * Database and log file full paths remain visible (mount points and drive letters).

    Version 2.6 changes (Chris Ntuli):
    * Version-aware role columns. Only Exchange Server roles that actually exist in
      the environment are shown. Exchange 2016/2019 consolidated the Client Access,
      Hub Transport and Unified Messaging roles into the Mailbox role, and Exchange
      2013 consolidated Hub Transport and Unified Messaging into the Mailbox role.
      Empty CAS/HUB/UM columns are no longer rendered for those versions.
    * Database backup state is always shown for all backup types - full,
      incremental, differential and copy - plus a "Last Backup (Days Ago)" value.
      Databases never backed up (or whose most recent backup of any type is older
      than -MaxBackupAgeDays) are highlighted.
    * Single-file, zero-touch design. No email addresses or SMTP servers are
      hard-coded. Run the script without -HTMLReport to be prompted interactively
      for the report file name, whether to email it, and (only if emailing) the
      SMTP server and the From/To addresses. Supplying -HTMLReport (and, for mail,
      -SendMail/-MailServer/-MailFrom/-MailTo) runs unattended for scheduled tasks.
    * Database and log file full paths are always shown, so mounted folders
      (mount points) and direct drive letters are both visible.
    * DAG database activation preferences, the currently active (mounted) copy,
      and whether each database is active on its preferred copy are reported and
      highlighted when a database is dismounted or not active on its preferred copy.
    * New sections for transparency: Active Directory site configuration (sites and
      site links), Accepted Domains, DAG witness/alternate-witness configuration,
      and Exchange certificates with validity (expiring/expired certificates are
      highlighted; threshold via -CertificateWarningDays).

    This project: https://github.com/ntulics/PowerShell/tree/main/Get-ExchangeEnvironmentReport
    Based on the original project: https://github.com/Apoc70/Get-ExchangeEnvironmentReport

    .DESCRIPTION

    This script creates an HTML report showing the following information about an Exchange
    2019, 2016, 2013, 2010, and, to a lesser extent, 2007 and 2003 environment.

    Requirements
    * Exchange Server Management Shell 2010 or newer
    * WMI and Remote Registry access from the computer running the script to all internal Exchange Servers
    * CSS file for HTML formatting

    The reports shows the following:

    * Report Generation Time
    * Total Servers per Exchange Version (2003 > 2010 or 2007 > 2019)
    * Total Mailboxes per Exchange Version, Office 365, and Organisation
    * Total Roles in the environment

    Then, per site:
    * Total Mailboxes per site
    * Internal, External and CAS Array Hostnames
    * Exchange Servers with:
      o Exchange Server Version
      o Service Pack
      o Number of preferred and maximum active databases
      o Update Rollup and rollup version
      o Roles installed on server and mailbox counts
      o OS Version and Service Pack

    Then, per Database availability group (Exchange 2010/2013/2016/2019):
    * Total members per DAG
    * Member list
    * Databases, detailing:
      o Mailbox Count and Average Size
      o Archive Mailbox Count and Average Size (Only shown if DAG includes Archive Mailboxes)
      o Database Size and whitespace
      o Database and log disk free
      o Last Full Backup (Only shown if one or more DAG database has been backed up)
      o Circular Logging Enabled (Only shown if one or more DAG database has Circular Logging enabled)
      o Mailbox server hosting active copy
      o List of mailbox servers hosting copies and number of copies

    Finally, per Database (Non DAG DBs/Exchange 2007/Exchange 2003)
    * Databases, detailing:
      o Storage Group (if applicable) and DB name
      o Server hosting database
      o Mailbox Count and Average Size
      o Archive Mailbox Count and Average Size (Only shown if DAG includes Archive Mailboxes)
      o Database Size and whitespace
      o Database and log disk free
      o Last Full Backup (Only shown if one or more DAG database has been backed up)
      o Circular Logging Enabled (Only shown if one or more DAG database has Circular Logging enabled)

    This does not detail public folder infrastructure, or examine Exchange 2007/2003 CCR/SCC clusters
    (although it attempts to detect Clustered Exchange 2007/2003 servers, signified by ClusMBX).

    IMPORTANT NOTE: The script requires WMI and Remote Registry access to Exchange servers from the server
    it is run from to determine OS version, Update Rollup, Exchange 2007/2003 cluster and DB size information.

    .LINK
    https://github.com/ntulics/PowerShell/tree/main/Get-ExchangeEnvironmentReport

    .PARAMETER HTMLReport
    Filename to write HTML Report to

    .PARAMETER SendMail
    Send Mail after completion. Set to $True to enable. If enabled, -MailFrom, -MailTo, -MailServer are mandatory

    .PARAMETER MailFrom
    Email address to send from. Passed directly to Send-MailMessage as -From

    .PARAMETER MailTo
    Email address to send to. Passed directly to Send-MailMessage as -To

    .PARAMETER MailServer
    SMTP Mail server to attempt to send through. Passed directly to Send-MailMessage as -SmtpServer

    .PARAMETER ViewEntireForest
    By default, true. Set the option in Exchange 2007 or 2010 to view all Exchange servers and recipients in the forest.

    .PARAMETER ServerFilter
    Use a text based string to filter Exchange Servers by, e.g., NL-*
    Note the use of the wildcard (*) character to allow for multiple matches.

    .PARAMETER ShowDriveNames
    Include drive names of EDB file path and LOG file folder in database report table

    .PARAMETER MaxBackupAgeDays
    Highlight a database in the report if its last full backup is older than this
    number of days, or if the database has never been backed up. Default: 1

    .PARAMETER CertificateWarningDays
    Highlight an Exchange certificate in the report if it expires within this number
    of days (amber) or has already expired (red). Default: 30

    .PARAMETER StandardMaxDatabaseSizeGB
    Default maximum mailbox database size (GB) for Exchange Standard Edition databases
    when no per-database registry override is present. Default: 1024 (the Exchange
    Standard Edition default at which the store auto-dismounts a database).

    .PARAMETER EnterpriseMaxDatabaseSizeGB
    Best-practice ceiling (GB) used for the size-vs-maximum donut and warnings for
    Exchange Enterprise Edition databases, which have no hard size limit. A per-database
    registry override ('Database Size Limit in GB'), if present, always takes precedence.
    Default: 2048

    .PARAMETER DatabaseSizeWarningPercent
    Percentage of a database's maximum size at which it is flagged red (approaching the
    limit). Default: 90

    .PARAMETER DatabaseSizeCautionPercent
    Percentage of a database's maximum size at which it is flagged amber (caution).
    Default: 75

    .PARAMETER CssFileName
    The filename containing the Cascading Style Sheet (CSS) information fpr the HTML report
    Default: EnvironmentReport.css

    .EXAMPLE
    Generate the HTML report
    .\Get-ExchangeEnvironmentReport.ps1 -HTMLReport .\report.html

    .EXAMPLE
    Generate the HTML report using a custom CSS file
    .\Get-ExchangeEnvironmentReport.ps1 -HTMLReport .\report.html -CssFileName MyCustomCSSFile.css

    .EXAMPLE
    Generate an HTML report and send the result as HTML email with attachment to the specified recipient using a dedicated smart host. Supply your own SMTP server and addresses; nothing is hard-coded.
    .\Get-ExchangeEnvironmentReport.ps1 -HTMLReport ExchangeEnvironment.html -SendMail -ViewEntireForest $true -MailFrom <from-address> -MailTo <to-address> -MailServer <smtp-server>

    .EXAMPLE
    Generate the HTML report including EDB and LOG drive names
    .\Get-ExchangeEnvironmentReport.ps1 -ShowDriveNames -HTMLReport .\report.html

    .EXAMPLE
    Run interactively (prompts for save location, email choice, and SMTP/from/to)
    .\Get-ExchangeEnvironmentReport.ps1
#>
[CmdletBinding()]
param(
  [parameter(Position = 0, HelpMessage = 'Filename to write HTML report to. If omitted, the script prompts interactively.')]
  [string]$HTMLReport,
  [switch]$SendMail,
  [string]$MailFrom = '',
  [string]$MailTo = '',
  [string]$MailServer = '',
  [bool]$ViewEntireForest = $true,
  [string]$ServerFilter = '*',
  [switch]$ShowDriveNames,
  [string]$CssFileName = 'EnvironmentReport.css',
  [int]$MaxBackupAgeDays = 1,
  [int]$CertificateWarningDays = 30,
  [int]$StandardMaxDatabaseSizeGB = 1024,
  [int]$EnterpriseMaxDatabaseSizeGB = 2048,
  [int]$DatabaseSizeWarningPercent = 90,
  [int]$DatabaseSizeCautionPercent = 75
)

# Warning Limits, adjust as needed
$MinFreeDiskspace = 10 # Mark free space less than this value (%) in red
$MaxDatabaseSize = 250 # Best-practice soft target; mark database larger than this value (GB) in red
# Mark a database in red if its last full backup is older than this many days,
# or if it has never been backed up. Overridable via the -MaxBackupAgeDays parameter.

# Exchange edition mounted-database limits (Standard 5 / Enterprise 100, per server,
# counting all copies active + passive in a DAG). Recovery databases do not count.
# Reference: https://learn.microsoft.com/en-us/exchange/plan-and-deploy/deployment-ref/editions-and-versions
$StandardMaxDatabases = 5
$EnterpriseMaxDatabases = 100

# Default variables
$NotAvailable = 'N/A'
$ScriptDir = Split-Path -Path $script:MyInvocation.MyCommand.Path

# Set TLS version o TLS 1.2
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# Sub-Function to normalise an Exchange server Edition value to 'Standard' or 'Enterprise'.
# The Edition property may be e.g. 'Standard', 'Enterprise', 'StandardEvaluation', etc.
function Get-EditionKind {
  [CmdletBinding()]
  param(
    $Edition
  )

  if ("$Edition" -like '*Enterprise*') { 'Enterprise' } else { 'Standard' }
}

# Sub-Function to determine a database's effective maximum size (GB) and where that
# limit comes from. Precedence:
#   1. Per-database registry override 'Database Size Limit in GB' (propagated to all copies)
#   2. Edition default - Standard 1024 GB, Enterprise best-practice ceiling (no hard limit)
# Registry path: HKLM\SYSTEM\CurrentControlSet\Services\MSExchangeIS\<Server>\Private-<DB GUID>
# Reference: https://learn.microsoft.com/en-us/troubleshoot/exchange/administration/exchange-cannot-mount-database-larger-than-1024-gb
function Get-DatabaseMaxSizeGB {
  [CmdletBinding()]
  param(
    [string]$Server,
    $DatabaseGuid,
    [string]$EditionKind,
    [int]$StandardDefaultGB,
    [int]$EnterpriseDefaultGB
  )

  $RegistryValue = $null

  try {
    $RemoteRegistry = [Microsoft.Win32.RegistryKey]::OpenRemoteBaseKey('LocalMachine', $Server)
    $StoreKey = $RemoteRegistry.OpenSubKey(('SYSTEM\CurrentControlSet\Services\MSExchangeIS\{0}' -f $Server))

    if ($null -ne $StoreKey) {
      $GuidString = "$DatabaseGuid"
      $TargetSubKey = $null

      foreach ($SubKeyName in $StoreKey.GetSubKeyNames()) {
        if ($SubKeyName -like ('Private-*{0}*' -f $GuidString)) { $TargetSubKey = $SubKeyName; break }
      }

      if ($TargetSubKey) {
        $DatabaseKey = $StoreKey.OpenSubKey($TargetSubKey)
        if ($null -ne $DatabaseKey) {
          $RegistryValue = $DatabaseKey.GetValue('Database Size Limit in GB')
        }
      }
    }
  }
  catch {
    $RegistryValue = $null
  }

  if (($null -ne $RegistryValue) -and ([int]$RegistryValue -gt 0)) {
    @{ MaxGB = [int]$RegistryValue; Source = 'Registry override' }
  }
  elseif ($EditionKind -eq 'Enterprise') {
    @{ MaxGB = $EnterpriseDefaultGB; Source = 'Enterprise best practice' }
  }
  else {
    @{ MaxGB = $StandardDefaultGB; Source = 'Standard default' }
  }
}

# Sub-Function to Get Database Information. Shorter than expected..
function Get-DatabaseAvailabilityGroupInformation {
  [CmdletBinding()]
  param(
    $DAG
  )

  @{Name                     = $DAG.Name.ToUpper()
    MemberCount	             = $DAG.Servers.Count
    Members                  = [array]($DAG.Servers | ForEach-Object { $_.Name })
    WitnessServer            = if ($DAG.WitnessServer) { $DAG.WitnessServer.ToString() } else { 'N/A' }
    WitnessDirectory         = if ($DAG.WitnessDirectory) { $DAG.WitnessDirectory.ToString() } else { 'N/A' }
    AlternateWitnessServer   = if ($DAG.AlternateWitnessServer) { $DAG.AlternateWitnessServer.ToString() } else { 'N/A' }
    Databases                = @()
  }
}

# Sub-Function to Get Database Information
function Get-DatabaseInformation {
  [CmdletBinding()]
  param(
    $Database,
    $ExchangeEnvironment,
    $Mailboxes,
    $ArchiveMailboxes,
    $E2010
  )

  # Circular Logging
  if ($Database.CircularLoggingEnabled) { $CircularLoggingEnabled = 'Yes' } else { $CircularLoggingEnabled = 'No' }

  # Backup state. Capture every backup type Exchange tracks (full, incremental,
  # differential and copy) so the report reflects the complete protection status
  # of each database, not just full backups. The "last backup age" is measured
  # against the most recent backup of *any* type.
  if ($Database.LastFullBackup) { $LastFullBackup = $Database.LastFullBackup.ToString() } else { $LastFullBackup = 'Never' }
  if ($Database.LastIncrementalBackup) { $LastIncrementalBackup = $Database.LastIncrementalBackup.ToString() } else { $LastIncrementalBackup = 'Never' }
  if ($Database.LastDifferentialBackup) { $LastDifferentialBackup = $Database.LastDifferentialBackup.ToString() } else { $LastDifferentialBackup = 'Never' }
  if ($Database.LastCopyBackup) { $LastCopyBackup = $Database.LastCopyBackup.ToString() } else { $LastCopyBackup = 'Never' }

  # Most recent backup of any type, used for the age/staleness indicator
  $BackupDates = @($Database.LastFullBackup, $Database.LastIncrementalBackup, $Database.LastDifferentialBackup, $Database.LastCopyBackup) | Where-Object { $_ }

  if ($BackupDates) {
    $LastAnyBackup = ($BackupDates | Sort-Object -Descending)[0]
    $BackupAgeDays = [int][math]::Round(((Get-Date) - $LastAnyBackup).TotalDays)
  }
  else {
    $BackupAgeDays = $null
  }

  # Database and log file locations. Capture both the compact drive/mount-point
  # name (GitHub issue #4) and the full paths so that the report shows the actual
  # location whether the volume is a mounted folder (mount point) or a direct
  # drive letter. Mount points have no drive letter, so the full path is what
  # reveals where the database and logs really live.
  $DriveNameEdb = ''
  try {
    $DriveNameEdb = $Database.EdbFilePath.DriveName
  }
  catch {
    $DriveNameEdb = $NotAvailable
  }

  $DriveNameLog = ''
  try {
    $DriveNameLog = $Database.LogFolderPath.DriveName
  }
  catch {
    $DriveNameLog = $NotAvailable
  }

  try { $EdbFilePath = $Database.EdbFilePath.PathName } catch { $EdbFilePath = $NotAvailable }
  if ([string]::IsNullOrWhiteSpace($EdbFilePath)) { $EdbFilePath = $NotAvailable }

  try { $LogFolderPath = $Database.LogFolderPath.PathName } catch { $LogFolderPath = $NotAvailable }
  if ([string]::IsNullOrWhiteSpace($LogFolderPath)) { $LogFolderPath = $NotAvailable }

  # Mailbox Average Sizes
  $MailboxStatistics = [array]($ExchangeEnvironment.Servers[$Database.Server.Name].MailboxStatistics | Where-Object { $_.Database -eq $Database.Identity })

  if ($MailboxStatistics) {
    [long]$MailboxItemSizeB = 0
    $MailboxStatistics | ForEach-Object { $MailboxItemSizeB += $_.TotalItemSizeB }
    [long]$MailboxAverageSize = $MailboxItemSizeB / $MailboxStatistics.Count
  }
  else {
    $MailboxAverageSize = 0
  }

  # Free Disk Space Percentage
  if ($ExchangeEnvironment.Servers[$Database.Server.Name].Disks) {

    foreach ($Disk in $ExchangeEnvironment.Servers[$Database.Server.Name].Disks) {
      if ($Database.EdbFilePath.PathName -like ('{0}*' -f $Disk.Name)) {
        $FreeDatabaseDiskSpace = $Disk.FreeSpace / $Disk.Capacity * 100
      }
      if ($Database.ExchangeVersion.ExchangeBuild.Major -ge 14) {

        if ($Database.LogFolderPath.PathName -like ('{0}*' -f $Disk.Name)) {
          $FreeLogDiskSpace = ($Disk.FreeSpace / $Disk.Capacity) * 100
        }
      }
      else {
        $StorageGroupDN = $Database.DistinguishedName.Replace(('CN={0},' -f $Database.Name), '')
        $Adsi = [adsi]"LDAP://$($Database.OriginatingServer)/$($StorageGroupDN)"
        if ($Adsi.msExchESEParamLogFilePath -like ('{0}*' -f $Disk.Name)) {
          $FreeLogDiskSpace = $Disk.FreeSpace / $Disk.Capacity * 100
        }
      }
    }
  }
  else {
    $FreeLogDiskSpace = $null
    $FreeDatabaseDiskSpace = $null
  }

  if ($Database.ExchangeVersion.ExchangeBuild.Major -ge 14 -and $E2010) {
    # Exchange 2010 Database Only
    $CopyCount = [int]$Database.Servers.Count

    if ($Database.MasterServerOrAvailabilityGroup.Name -ne $Database.Server.Name) {
      $Copies = [array]($Database.Servers | ForEach-Object { $_.Name })
    }
    else {
      $Copies = @()
    }

    # Full list of servers hosting a copy (active + passive). Used to count copies
    # per server against the edition mounted-database limit (5 Standard / 100 Enterprise).
    try { $AllCopyServers = [array]($Database.Servers | ForEach-Object { $_.Name.ToUpper() }) } catch { $AllCopyServers = @($Database.Server.Name.ToUpper()) }

    # Activation preference, currently active copy and mount state (DAG / multi-copy).
    # ActivationPreference is a list of <server, preference> pairs; preference 1 is
    # the most preferred copy. We report the full preference order, the preferred
    # owner, where the database is currently active (mounted), and whether that
    # active copy is the preferred one.
    $ActivationPreference = @()
    $PreferredServer = $NotAvailable
    try {
      if ($Database.ActivationPreference) {
        $ActivationPreference = @($Database.ActivationPreference | Sort-Object -Property Value | ForEach-Object { '{0} ({1})' -f $_.Key.Name.ToUpper(), $_.Value })
        $Pref1 = $Database.ActivationPreference | Where-Object { [int]$_.Value -eq 1 } | Select-Object -First 1
        if ($Pref1) { $PreferredServer = $Pref1.Key.Name.ToUpper() }
      }
    }
    catch {
      $ActivationPreference = @()
    }

    # Currently active (mounted) server. -Status populates MountedOnServer as an FQDN.
    if ($Database.MountedOnServer) {
      $CurrentActiveServer = (($Database.MountedOnServer -split '\.')[0]).ToUpper()
    }
    else {
      $CurrentActiveServer = $Database.Server.Name.ToUpper()
    }

    if ($null -ne $Database.Mounted) {
      if ($Database.Mounted) { $Mounted = 'Yes' } else { $Mounted = 'No' }
    }
    else {
      $Mounted = $NotAvailable
    }

    # Only meaningful for databases with more than one copy.
    if (($PreferredServer -ne $NotAvailable) -and ($CopyCount -gt 1)) {
      if ($CurrentActiveServer -eq $PreferredServer) { $ActiveOnPreferred = 'Yes' } else { $ActiveOnPreferred = 'No' }
    }
    else {
      $ActiveOnPreferred = $NotAvailable
    }

    # Archive Info
    $ArchiveMailboxCount = [int]([array]($ArchiveMailboxes | Where-Object { $_.ArchiveDatabase -eq $Database.Name })).Count

    $ArchiveStatistics = [array]($ArchiveMailboxes | Where-Object { $_.ArchiveDatabase -eq $Database.Name } | Get-MailboxStatistics -Archive )

    if ($ArchiveStatistics) {
      [long]$ArchiveItemSizeB = 0
      $ArchiveStatistics | ForEach-Object { $ArchiveItemSizeB += $_.TotalItemSize.Value.ToBytes() }
      [long]$ArchiveAverageSize = $ArchiveItemSizeB / $ArchiveStatistics.Count
    }
    else {
      $ArchiveAverageSize = 0
    }

    # DB Size / Whitespace Info
    [long]$Size = $Database.DatabaseSize.ToBytes()
    [long]$Whitespace = $Database.AvailableNewMailboxSpace.ToBytes()
    $StorageGroup = $null

  }
  else {
    $ArchiveMailboxCount = 0
    $CopyCount = 0
    $Copies = @()
    # Activation preference / active-copy concepts do not apply pre-DAG (2003/2007)
    $ActivationPreference = @()
    $PreferredServer = $NotAvailable
    $CurrentActiveServer = $Database.Server.Name.ToUpper()
    $Mounted = $NotAvailable
    $ActiveOnPreferred = $NotAvailable
    $AllCopyServers = @($Database.Server.Name.ToUpper())
    # 2003 & 2007, Use WMI (Based on code by Gary Siepser, http://bit.ly/kWWMb3)
    $Size = [long](get-wmiobject -Class cim_datafile -ComputerName $Database.Server.Name -Filter ('name=''' + $Database.edbfilepath.pathname.replace('\', '\\') + '''')).filesize

    if (!$Size) {
      Write-Warning -Message ('Cannot detect database size via WMI for {0}' -f $Database.Server.Name)
      [long]$Size = 0
      [long]$Whitespace = 0
    }
    else {
      [long]$MailboxDeletedItemSizeB = 0
      if ($MailboxStatistics) {
        $MailboxStatistics | ForEach-Object { $MailboxDeletedItemSizeB += $_.TotalDeletedItemSizeB }
      }

      # Calculate database whitespace
      $Whitespace = $Size - $MailboxItemSizeB - $MailboxDeletedItemSizeB
      if ($Whitespace -lt 0) { $Whitespace = 0 }
    }

    $StorageGroup = $Database.DistinguishedName.Split(',')[1].Replace('CN=', '')
  }

  # Edition-aware maximum database size and current utilisation. The edition comes from
  # the server currently hosting the active copy (already collected into ExchangeEnvironment.Servers).
  $ServerInfo = $ExchangeEnvironment.Servers[$Database.Server.Name]
  if ($ServerInfo) { $EditionKind = Get-EditionKind -Edition $ServerInfo.Edition } else { $EditionKind = 'Standard' }

  $MaxSizeInfo = Get-DatabaseMaxSizeGB -Server $Database.Server.Name -DatabaseGuid $Database.Guid -EditionKind $EditionKind -StandardDefaultGB $StandardMaxDatabaseSizeGB -EnterpriseDefaultGB $EnterpriseMaxDatabaseSizeGB
  $MaxSizeGB = $MaxSizeInfo.MaxGB
  $MaxSizeSource = $MaxSizeInfo.Source

  if ($MaxSizeGB -gt 0) {
    $SizePercentOfMax = [math]::Round((($Size / 1GB) / $MaxSizeGB) * 100, 1)
  }
  else {
    $SizePercentOfMax = 0
  }

  @{
    Name                   = $Database.Name
    StorageGroup           = $StorageGroup
    ActiveOwner            = $Database.Server.Name.ToUpper()
    MailboxCount           = [long]([array]($Mailboxes | Where-Object { $_.Database -eq $Database.Identity })).Count
    MailboxAverageSize     = $MailboxAverageSize
    ArchiveMailboxCount    = $ArchiveMailboxCount
    ArchiveAverageSize     = $ArchiveAverageSize
    CircularLoggingEnabled = $CircularLoggingEnabled
    LastFullBackup         = $LastFullBackup
    LastIncrementalBackup  = $LastIncrementalBackup
    LastDifferentialBackup = $LastDifferentialBackup
    LastCopyBackup         = $LastCopyBackup
    BackupAgeDays          = $BackupAgeDays
    Size                   = $Size
    Whitespace             = $Whitespace
    Copies                 = $Copies
    CopyCount              = $CopyCount
    FreeLogDiskSpace       = $FreeLogDiskSpace
    FreeDatabaseDiskSpace  = $FreeDatabaseDiskSpace
    DriveNameEdb           = $DriveNameEdb
    DriveNameLog           = $DriveNameLog
    EdbFilePath            = $EdbFilePath
    LogFolderPath          = $LogFolderPath
    ActivationPreference   = $ActivationPreference
    PreferredServer        = $PreferredServer
    CurrentActiveServer    = $CurrentActiveServer
    ActiveOnPreferred      = $ActiveOnPreferred
    Mounted                = $Mounted
    AllCopyServers         = $AllCopyServers
    EditionKind            = $EditionKind
    MaxSizeGB              = $MaxSizeGB
    MaxSizeSource          = $MaxSizeSource
    SizePercentOfMax       = $SizePercentOfMax
  }
}

# Sub-Function to get mailbox count per server.
# New in 1.5.2
function Get-ExchangeServerMailboxCount {
  [CmdletBinding()]
  param(
    $Mailboxes,
    $ExchangeServer,
    $Databases
  )
  # The following *should* work, but it doesn't. Apparently, ServerName is not always returned correctly which may be the cause of
  # reports of counts being incorrect
  #([array]($Mailboxes | Where {$_.ServerName -eq $ExchangeServer.Name})).Count

  # ..So as a workaround, I'm going to check what databases are assigned to each server and then get the mailbox counts on a per-
  # database basis and return the resulting total. As we already have this information resident in memory it should be cheap, just
  # not as quick.
  $MailboxCount = 0

  foreach ($Database in [array]($Databases | Where-Object { $_.Server -eq $ExchangeServer.Name })) {
    $MailboxCount += ([array]($Mailboxes | Where-Object { $_.Database -eq $Database.Identity })).Count
  }

  $MailboxCount

}

# 2021-12-23 Function added to handle empty virtual directory hostname strings (Issue #9)
function Test-vDirHost {
  [CmdletBinding()]
  param(
    $VDirHost
  )

  [string]$Hostname = 'None'

  if ($null -ne $VDirHost) {
    $Hostname = ([string]$VDirHost).Trim()
  }

  $Hostname
}

# Sub-Function to Get Exchange Server information
function Get-ExchangeServerInformation {
  [CmdletBinding()]
  param(
    $E2010,
    $ExchangeServer,
    $Mailboxes,
    $Databases,
    $Hybrids
  )

  # Set Basic Variables
  $MailboxCount = 0
  $RollupLevel = 0
  $RollupVersion = ''
  $ExtNames = @()
  $IntNames = @()
  $CASArrayName = ''

  # Added to handle max preferred/active databases per server
  $MaxPrefDatabases = 0
  $MaxActiveDatabases = 0
  $NotSet = '--'

  # Get WMI Information: Operatin System
  $tWMI = Get-WmiObject -Class Win32_OperatingSystem -ComputerName $ExchangeServer.Name -ErrorAction SilentlyContinue

  if ($tWMI) {
    $OSVersion = $tWMI.Caption.Replace('(R)', '').Replace('Microsoft ', '').Replace('Enterprise', 'Ent').Replace('Standard', 'Std').Replace(' Edition', '')
    $OSServicePack = $tWMI.CSDVersion
    $RealName = $tWMI.CSName.ToUpper()
  }
  else {
    Write-Warning -Message ('Cannot detect OS information via WMI for {0}' -f $ExchangeServer.Name)
    $OSVersion = $NotAvailable
    $OSServicePack = $NotAvailable
    $RealName = $ExchangeServer.Name.ToUpper()
  }

  # OS update level. Modern Windows Server has no Service Packs; the cumulative-update
  # level is identified by the build's UBR (Update Build Revision), i.e. 10.0.<Build>.<UBR>.
  # We also try to surface the most recent installed update KB.
  $OSBuild = $NotAvailable
  $OSDisplayVersion = ''
  $OSLatestUpdate = $NotAvailable

  try {
    $RemoteRegistry = [Microsoft.Win32.RegistryKey]::OpenRemoteBaseKey('LocalMachine', $ExchangeServer.Name)
    $CurrentVersionKey = $RemoteRegistry.OpenSubKey('SOFTWARE\Microsoft\Windows NT\CurrentVersion')

    if ($null -ne $CurrentVersionKey) {
      $CurrentBuild = $CurrentVersionKey.GetValue('CurrentBuildNumber')
      $Ubr = $CurrentVersionKey.GetValue('UBR')
      $DisplayVersion = $CurrentVersionKey.GetValue('DisplayVersion')
      if (-not $DisplayVersion) { $DisplayVersion = $CurrentVersionKey.GetValue('ReleaseId') }

      if ($CurrentBuild) {
        if ($null -ne $Ubr) { $OSBuild = ('10.0.{0}.{1}' -f $CurrentBuild, $Ubr) } else { $OSBuild = ('10.0.{0}' -f $CurrentBuild) }
      }
      if ($DisplayVersion) { $OSDisplayVersion = "$DisplayVersion" }
    }
  }
  catch {
    $OSBuild = $NotAvailable
  }

  # Most recently installed update KB (best effort; not all cumulative updates appear here)
  try {
    $Hotfixes = Get-WmiObject -Class Win32_QuickFixEngineering -ComputerName $ExchangeServer.Name -ErrorAction SilentlyContinue | Where-Object { $_.HotFixID -match 'KB' }
    if ($Hotfixes) {
      $LatestHotfix = $Hotfixes | Sort-Object -Property @{Expression = { try { [datetime]$_.InstalledOn } catch { [datetime]'1900-01-01' } } } | Select-Object -Last 1
      if ($LatestHotfix) {
        if ($LatestHotfix.InstalledOn) { $OSLatestUpdate = ('{0} ({1})' -f $LatestHotfix.HotFixID, ([string]$LatestHotfix.InstalledOn)) } else { $OSLatestUpdate = $LatestHotfix.HotFixID }
      }
    }
  }
  catch {
    $OSLatestUpdate = $NotAvailable
  }

  # Get WMI Information: Disk Space
  $tWMI = Get-WmiObject -Query 'Select * from Win32_Volume' -ComputerName $ExchangeServer.Name -ErrorAction SilentlyContinue

  if ($tWMI) {
    $Disks = $tWMI | Select-Object -Property Name, Capacity, FreeSpace | Sort-Object -Property Name
  }
  else {
    Write-Warning -Message ('Cannot detect OS information via WMI for {0}' -f $ExchangeServer.Name)
    $Disks = $null
  }

  # Get Exchange Version
  if ($ExchangeServer.AdminDisplayVersion.Major -eq 6) {
    $ExchangeMajorVersion = [double]('{0}.{1}' -f $ExchangeServer.AdminDisplayVersion.Major, $ExchangeServer.AdminDisplayVersion.Minor)
    $ExchangeSPLevel = $ExchangeServer.AdminDisplayVersion.FilePatchLevelDescription.Replace('Service Pack ', '')
  }
  elseif ($ExchangeServer.AdminDisplayVersion.Major -eq 15 -and $ExchangeServer.AdminDisplayVersion.Minor -ge 1) {
    $ExchangeMajorVersion = [double]('{0}.{1}' -f $ExchangeServer.AdminDisplayVersion.Major, $ExchangeServer.AdminDisplayVersion.Minor)
    $ExchangeSPLevel = 0
  }
  else {
    $ExchangeMajorVersion = $ExchangeServer.AdminDisplayVersion.Major
    $ExchangeSPLevel = $ExchangeServer.AdminDisplayVersion.Minor
  }

  # Full build number (Major.Minor.Build.Revision) from AdminDisplayVersion. Note this
  # identifies the CU level accurately; the exact Security Update revision may be higher
  # than what AdminDisplayVersion reports (confirm SU level with the Exchange HealthChecker).
  $adv = $ExchangeServer.AdminDisplayVersion
  try {
    $ExchangeBuildFull = ('{0}.{1}.{2}.{3}' -f $adv.Major, $adv.Minor, $adv.Build, $adv.Revision)
    $ExchangeBuildCU = [int]$adv.Build
  }
  catch {
    $ExchangeBuildFull = $NotAvailable
    $ExchangeBuildCU = 0
  }

  # Exchange 2007+
  if ($ExchangeMajorVersion -ge 8) {
    # Get Roles
    $MailboxStatistics = $null
    [array]$Roles = $ExchangeServer.ServerRole.ToString().Replace(' ', '').Split(',')

    # Add Hybrid "Role" for report
    if ($Hybrids -contains $ExchangeServer.Name) {
      $Roles += 'Hybrid'
    }

    if ($Roles -contains 'Mailbox') {

      $MailboxCount = Get-ExchangeServerMailboxCount -Mailboxes $Mailboxes -ExchangeServer $ExchangeServer -Databases $Databases
      if ($ExchangeServer.Name.ToUpper() -ne $RealName) {
        $Roles = [array]($Roles | Where-Object { $_ -ne 'Mailbox' })
        $Roles += 'ClusteredMailbox'
      }

      # Get Mailbox Statistics the normal way, return in a consitent format
      # try/catch added
      try {
        $MailboxStatistics = Get-MailboxStatistics -Server $ExchangeServer -ErrorAction SilentlyContinue | Select-Object -Property DisplayName, @{Name = 'TotalItemSizeB'; Expression = { $_.TotalItemSize.Value.ToBytes() } }, @{Name = 'TotalDeletedItemSizeB'; Expression = { $_.TotalDeletedItemSize.Value.ToBytes() } }, Database
      }
      catch {
        $MailboxStatistics = $null
        Write-Warning -Message ('Cannot get mailbox statistics for server {0}' -f $ExchangeServer)
      }

      if ($ExchangeMajorVersion -ge 14) {
        $mailboxServer = Get-MailboxServer -Identity $($ExchangeServer.Name)

        # Gather max active/max preferred database config
        if ($ExchangeMajorVersion -lt 15) {
          # Exchange 2010
          $MaxActiveDatabases = $mailboxServer.MaximumActiveDatabases
        }
        else {
          # Exchange 2013+
          if ($null -ne $mailboxServer.MaximumPreferredActiveDatabases) {
            $MaxPrefDatabases = $mailboxServer.MaximumPreferredActiveDatabases
          }
          else {
            $MaxPrefDatabases = $NotSet
          }

          if ($null -ne $mailboxServer.MaximumActiveDatabases) {
            $MaxActiveDatabases = $mailboxServer.MaximumActiveDatabases
          }
          else {
            $MaxActiveDatabases = $NotSet
          }
        }
      }
    }

    # Get HTTPS Names (Exchange 2010 only due to time taken to retrieve data)
    # Update to support 'Mailbox' role for gathering namespace information
    if (($Roles -contains 'ClientAccess' -and $E2010) -or ($Roles -contains 'Mailbox' -and $E2010)) {
      Get-OWAVirtualDirectory -Server $ExchangeServer -ADPropertiesOnly | ForEach-Object { $ExtNames += (Test-vDirHost -VDirHost $_.ExternalURL.Host); $IntNames += (Test-vDirHost -VDirHost $_.InternalURL.Host) }

      Get-WebServicesVirtualDirectory -Server $ExchangeServer -ADPropertiesOnly | ForEach-Object { $ExtNames += (Test-vDirHost -VDirHost $_.ExternalURL.Host); $IntNames += (Test-vDirHost -VDirHost $_.InternalURL.Host) }

      Get-OABVirtualDirectory -Server $ExchangeServer -ADPropertiesOnly | ForEach-Object { $ExtNames += (Test-vDirHost -VDirHost $_.ExternalURL.Host); $IntNames += (Test-vDirHost -VDirHost $_.InternalURL.Host) }

      Get-ActiveSyncVirtualDirectory -Server $ExchangeServer -ADPropertiesOnly | ForEach-Object { $ExtNames += (Test-vDirHost -VDirHost $_.ExternalURL.Host); $IntNames += (Test-vDirHost -VDirHost $_.InternalURL.Host) }

      if (Get-Command -Name Get-MAPIVirtualDirectory -ErrorAction SilentlyContinue) {
        Get-MAPIVirtualDirectory -Server $ExchangeServer -ADPropertiesOnly | ForEach-Object { $ExtNames += (Test-vDirHost -VDirHost $_.ExternalURL.Host); $IntNames += (Test-vDirHost -VDirHost $_.InternalURL.Host) }
      }

      if (Get-Command -Name Get-ClientAccessService -ErrorAction SilentlyContinue) {
        $IntNames += (Test-vDirHost -VDirHost (Get-ClientAccessService -Identity $ExchangeServer.Name).AutoDiscoverServiceInternalURI.Host)
      }
      else {
        # Fallback to use Get-ClientAccessServer cmdlet
        $IntNames += (Test-vDirHost -VDirHost (Get-ClientAccessServer -Identity $ExchangeServer.Name).AutoDiscoverServiceInternalURI.Host)
      }

      if ($ExchangeMajorVersion -ge 14) {
        Get-ECPVirtualDirectory -Server $ExchangeServer -ADPropertiesOnly | ForEach-Object { $ExtNames += (Test-vDirHost -VDirHost $_.ExternalURL.Host); $IntNames += (Test-vDirHost -VDirHost $_.InternalURL.Host); }
      }

      $IntNames = $IntNames | Sort-Object -Unique
      $ExtNames = $ExtNames | Sort-Object -Unique
      $CASArray = Get-ClientAccessArray -Site $ExchangeServer.Site.Name

      if ($CASArray) {
        $CASArrayName = $CASArray.Fqdn
      }
    }

    # Rollup Level / Versions (Thanks to Bhargav Shukla https://bhargavs.com/index.php/2009/12/14/how-do-i-check-update-rollup-version-on-exchange-20xx-server/)
    switch ([string]$ExchangeMajorVersion) {
      # Exchange Server 2016 / 2019
      '15.2' { $RegKey = "SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Installer\\UserData\\S-1-5-18\\Products\\442189DC8B9EA5040962A6BED9EC1F1F\\Patches" }
      '15.1' { $RegKey = "SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Installer\\UserData\\S-1-5-18\\Products\\442189DC8B9EA5040962A6BED9EC1F1F\\Patches" }
      # Exchange Server 2010 / 2013
      '15' { $RegKey = "SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Installer\\UserData\\S-1-5-18\\Products\\AE1D439464EB1B8488741FFA028E291C\\Patches" }
      '14' { $RegKey = "SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Installer\\UserData\\S-1-5-18\\Products\\AE1D439464EB1B8488741FFA028E291C\\Patches" }
      # Exchange 2007
      default { $RegKey = "SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Installer\\UserData\\S-1-5-18\\Products\\461C2B4266EDEF444B864AD6D9E5B613\\Patches" }
    }

    # try/catch added
    try {
      $RemoteRegistry = [Microsoft.Win32.RegistryKey]::OpenRemoteBaseKey('LocalMachine', $ExchangeServer.Name)
    }
    catch {
      $RemoteRegistry = $null
    }

    if ($null -ne $RemoteRegistry) {

      $RUKeys = $RemoteRegistry.OpenSubKey($RegKey).GetSubKeyNames() | ForEach-Object { "$RegKey\\$_" }

      if ($RUKeys) {
        [array]($RUKeys | ForEach-Object { $RemoteRegistry.OpenSubKey($_).GetValue('DisplayName') }) | `
          ForEach-Object {
          if ($_ -like 'Update Rollup *') {
            $tRU = $_.Split(' ')[2]
            if ($tRU -like '*-*') { $tRUV = $tRU.Split('-')[1]; $tRU = $tRU.Split('-')[0] } else { $tRUV = '' }
            if ([int]$tRU -ge [int]$RollupLevel) { $RollupLevel = $tRU; $RollupVersion = $tRUV }
          }
        }
      }
    }
    else {
      Write-Warning -Message ('Cannot detect Rollup Version via Remote Registry for {0}' -f $ExchangeServer.Name)
    }

    # Exchange 2013+ CU or SP Level
    if ($ExchangeMajorVersion -ge 15) {
      $RegKey = "SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\Microsoft Exchange v15"
      # try/catch added
      try {
        $RemoteRegistry = [Microsoft.Win32.RegistryKey]::OpenRemoteBaseKey('LocalMachine', $ExchangeServer.Name)
      }
      catch {
        $RemoteRegistry = $null
      }

      if ($RemoteRegistry) {
        $ExchangeSPLevel = $RemoteRegistry.OpenSubKey($RegKey).GetValue('DisplayName')

        if ($ExchangeSPLevel -like '*Service Pack*' -or $ExchangeSPLevel -like '*Cumulative Update*') {
          $ExchangeSPLevel = $ExchangeSPLevel.Replace('Microsoft Exchange Server 2013 ', '')
          $ExchangeSPLevel = $ExchangeSPLevel.Replace('Microsoft Exchange Server 2016 ', '')
          $ExchangeSPLevel = $ExchangeSPLevel.Replace('Microsoft Exchange Server 2019 ', '')
          $ExchangeSPLevel = $ExchangeSPLevel.Replace('Service Pack ', 'SP')
          $ExchangeSPLevel = $ExchangeSPLevel.Replace('Cumulative Update ', 'CU')
        }
        else {
          $ExchangeSPLevel = 0
        }
      }
      else {
        Write-Warning -Message ('Cannot detect CU/SP via Remote Registry for {0}' -f $ExchangeServer.Name)
      }
    }
  }

  # Exchange 2003
  if ($ExchangeMajorVersion -eq 6.5) {

    # Mailbox Count
    $MailboxCount = Get-ExchangeServerMailboxCount -Mailboxes $Mailboxes -ExchangeServer $ExchangeServer -Databases $Databases

    # Get Role via WMI
    $tWMI = Get-WMIObject -Class Exchange_Server -Namespace 'root\microsoftexchangev2' -ComputerName $ExchangeServer.Name -Filter "Name='$($ExchangeServer.Name)'"

    if ($tWMI) {
      if ($tWMI.IsFrontEndServer) { $Roles = @('FE') } else { $Roles = @('BE') }
    }
    else {
      Write-Warning -Message ('Cannot detect Front End/Back End Server information via WMI for {0}' -f $ExchangeServer.Name)
      $Roles += 'Unknown'
    }

    # Get Mailbox Statistics using WMI, return in a consistent format
    $tWMI = Get-WMIObject -class Exchange_Mailbox -Namespace ROOT\MicrosoftExchangev2 -ComputerName $ExchangeServer.Name -Filter ("ServerName='$($ExchangeServer.Name)'")
    if ($tWMI) {
      $MailboxStatistics = $tWMI | Select-Object -Property @{Name = 'DisplayName'; Expression = { $_.MailboxDisplayName } }, @{Name = 'TotalItemSizeB'; Expression = { $_.Size } }, @{Name = 'TotalDeletedItemSizeB'; Expression = { $_.DeletedMessageSizeExtended } }, @{Name = 'Database'; Expression = { ((Get-MailboxDatabase -Identity "$($_.ServerName)\$($_.StorageGroupName)\$($_.StoreName)").Identity) } }
    }
    else {
      Write-Warning -Message ('Cannot retrieve Mailbox Statistics via WMI for {0}' -f $ExchangeServer.Name)
      $MailboxStatistics = $null
    }
  }

  # Exchange 2000
  if ($ExchangeMajorVersion -eq '6.0') {
    # Mailbox Count
    $MailboxCount = Get-ExchangeServerMailboxCount -Mailboxes $Mailboxes -ExchangeServer $ExchangeServer -Databases $Databases

    # Get Role via ADSI
    $tADSI = [ADSI]"LDAP://$($ExchangeServer.OriginatingServer)/$($ExchangeServer.DistinguishedName)"

    if ($tADSI) {
      if ($tADSI.ServerRole -eq 1) { $Roles = @('FE') } else { $Roles = @('BE') }
    }
    else {
      Write-Warning -Message ('Cannot detect Front End/Back End Server information via ADSI for {0}' -f $ExchangeServer.Name)
      $Roles += 'Unknown'
    }
    $MailboxStatistics = $null
  }

  # Return Hashtable
  @{
    Name                      = $ExchangeServer.Name.ToUpper()
    RealName                  = $RealName
    ExchangeMajorVersion      = $ExchangeMajorVersion
    ExchangeSPLevel           = $ExchangeSPLevel
    Edition                   = $ExchangeServer.Edition
    EditionKind               = (Get-EditionKind -Edition $ExchangeServer.Edition)
    HostedDatabaseCopies      = 0
    ActiveDatabaseCount       = 0
    PreferredDatabaseCount    = 0
    ExchangeBuildFull         = $ExchangeBuildFull
    ExchangeBuildCU           = $ExchangeBuildCU
    Mailboxes                 = $MailboxCount
    OSVersion                 = $OSVersion;
    OSServicePack             = $OSServicePack
    OSBuild                   = $OSBuild
    OSDisplayVersion          = $OSDisplayVersion
    OSLatestUpdate            = $OSLatestUpdate
    Roles                     = $Roles
    RollupLevel               = $RollupLevel
    RollupVersion             = $RollupVersion
    Site                      = $ExchangeServer.Site.Name
    MailboxStatistics         = $MailboxStatistics
    Disks                     = $Disks
    IntNames                  = $IntNames
    ExtNames                  = $ExtNames
    CASArrayName              = $CASArrayName
    MaximumPreferredDatabases = $MaxPrefDatabases
    MaximumActiveDatabases    = $MaxActiveDatabases
  }
}

# Sub Function to Get Totals by Version
function Get-TotalsByVersion {
  [CmdletBinding()]
  param(
    $ExchangeEnvironment
  )

  # Create empty hash table
  $TotalMailboxesByVersion = @{}

  if ($ExchangeEnvironment.Sites) {
    foreach ($Site in $ExchangeEnvironment.Sites.GetEnumerator()) {
      foreach ($Server in $Site.Value) {
        if (!$TotalMailboxesByVersion["$($Server.ExchangeMajorVersion).$($Server.ExchangeSPLevel)"]) {
          $TotalMailboxesByVersion.Add("$($Server.ExchangeMajorVersion).$($Server.ExchangeSPLevel)", @{ServerCount = 1; MailboxCount = $Server.Mailboxes })
        }
        else {
          $TotalMailboxesByVersion["$($Server.ExchangeMajorVersion).$($Server.ExchangeSPLevel)"].ServerCount++
          $TotalMailboxesByVersion["$($Server.ExchangeMajorVersion).$($Server.ExchangeSPLevel)"].MailboxCount += $Server.Mailboxes
        }
      }
    }
  }

  if ($ExchangeEnvironment.Pre2007) {
    foreach ($FakeSite in $ExchangeEnvironment.Pre2007.GetEnumerator()) {
      foreach ($Server in $FakeSite.Value) {
        if (!$TotalMailboxesByVersion["$($Server.ExchangeMajorVersion).$($Server.ExchangeSPLevel)"]) {
          $TotalMailboxesByVersion.Add("$($Server.ExchangeMajorVersion).$($Server.ExchangeSPLevel)", @{ServerCount = 1; MailboxCount = $Server.Mailboxes })
        }
        else {
          $TotalMailboxesByVersion["$($Server.ExchangeMajorVersion).$($Server.ExchangeSPLevel)"].ServerCount++
          $TotalMailboxesByVersion["$($Server.ExchangeMajorVersion).$($Server.ExchangeSPLevel)"].MailboxCount += $Server.Mailboxes
        }
      }
    }
  }
  $TotalMailboxesByVersion
}

# Sub Function to Get Totals by Role
function Get-TotalsByRole {
  [CmdletBinding()]
  param(
    $ExchangeEnvironment
  )

  # Version-aware roles: start with an empty table and only add roles that are
  # actually present on discovered servers. This ensures the report reflects the
  # role model of the installed Exchange version(s):
  #   * Exchange 2007/2010 - separate ClientAccess, HubTransport, Mailbox,
  #     UnifiedMessaging and Edge roles.
  #   * Exchange 2013 - ClientAccess and Mailbox roles (Hub Transport and Unified
  #     Messaging are part of the Mailbox role).
  #   * Exchange 2016/2019 - Mailbox role only (Client Access is part of the
  #     Mailbox role), plus the optional Edge Transport role.
  # Roles that do not exist in the environment are never added, so no empty
  # CAS/HUB/UM columns are rendered for modern deployments.
  $TotalServersByRole = @{}

  if ($ExchangeEnvironment.Sites) {

    foreach ($Site in $ExchangeEnvironment.Sites.GetEnumerator()) {

      foreach ($Server in $Site.Value) {

        foreach ($Role in $Server.Roles) {
          if ($null -eq $TotalServersByRole[$Role]) {
            $TotalServersByRole.Add($Role, 1)
          }
          else {
            $TotalServersByRole[$Role]++
          }
        }
      }
    }
  }

  if ($ExchangeEnvironment.Pre2007['Pre 2007 Servers']) {

    foreach ($Server in $ExchangeEnvironment.Pre2007['Pre 2007 Servers']) {

      foreach ($Role in $Server.Roles) {
        if ($null -eq $TotalServersByRole[$Role]) {
          $TotalServersByRole.Add($Role, 1)
        }
        else {
          $TotalServersByRole[$Role]++
        }
      }
    }
  }

  $TotalServersByRole
}

# Sub-Function to return HTML Table for Active Directory Site configuration
function Get-HtmlSiteConfiguration {
  [CmdletBinding()]
  param(
    $ExchangeEnvironment
  )

  $Inner = ''

  # Active Directory sites (as Exchange sees them)
  if (Get-Command -Name Get-AdSite -ErrorAction SilentlyContinue) {

    $Sites = @(Get-AdSite -ErrorAction SilentlyContinue | Sort-Object -Property Name)

    if ($Sites) {
      $Inner += "<table class='grid'><tr><th>Site Name</th><th>Hub Site Enabled</th><th>Exchange Servers</th></tr>"

      foreach ($Site in $Sites) {
        if ($Site.HubSiteEnabled) { $HubEnabled = 'Yes' } else { $HubEnabled = 'No' }

        $ServerCount = 0
        if ($ExchangeEnvironment.Sites[$Site.Name]) {
          $ServerCount = @($ExchangeEnvironment.Sites[$Site.Name]).Count
        }

        $Inner += ("<tr><td>{0}</td><td class='center'>{1}</td><td class='center'>{2}</td></tr>" -f $Site.Name, $HubEnabled, $ServerCount)
      }

      $Inner += '</table>'
    }
  }

  # Active Directory site links (including the Exchange-specific cost, if set)
  if (Get-Command -Name Get-AdSiteLink -ErrorAction SilentlyContinue) {

    $SiteLinks = @(Get-AdSiteLink -ErrorAction SilentlyContinue | Sort-Object -Property Name)

    if ($SiteLinks) {
      $Inner += "<table class='grid'><tr><th>Site Link</th><th>AD Cost</th><th>Exchange Cost</th><th>Max Message Size</th><th>Connected Sites</th></tr>"

      foreach ($Link in $SiteLinks) {
        if ($null -ne $Link.ExchangeCost) { $ExchangeCost = $Link.ExchangeCost } else { $ExchangeCost = $NotAvailable }
        if ($Link.MaxMessageSize) { $MaxMessageSize = $Link.MaxMessageSize.ToString() } else { $MaxMessageSize = 'Unlimited' }
        $ConnectedSites = [string]::Join(', ', @($Link.Sites | ForEach-Object { $_.Name }))

        $Inner += ("<tr><td>{0}</td><td class='center'>{1}</td><td class='center'>{2}</td><td class='center'>{3}</td><td>{4}</td></tr>" -f $Link.Name, $Link.ADCost, $ExchangeCost, $MaxMessageSize, $ConnectedSites)
      }

      $Inner += '</table>'
    }
  }

  if (-not $Inner) { return '' }

  "<div class='card'><div class='card-head'>Active Directory Site Configuration</div><div class='card-body'>$Inner</div></div>"
}

# Sub-Function to return HTML Table for Accepted Domains
function Get-HtmlAcceptedDomains {
  [CmdletBinding()]
  param()

  if (-not (Get-Command -Name Get-AcceptedDomain -ErrorAction SilentlyContinue)) { return '' }

  $Domains = @(Get-AcceptedDomain -ErrorAction SilentlyContinue | Sort-Object -Property DomainName)

  if (-not $Domains) { return '' }

  $Inner = "<table class='grid'><tr><th>Domain Name</th><th>Domain Type</th><th>Default</th><th>Name</th></tr>"

  foreach ($Domain in $Domains) {
    if ($Domain.Default) { $IsDefault = 'Yes' } else { $IsDefault = 'No' }
    $Inner += ("<tr><td>{0}</td><td class='center'>{1}</td><td class='center'>{2}</td><td>{3}</td></tr>" -f $Domain.DomainName, $Domain.DomainType, $IsDefault, $Domain.Name)
  }

  $Inner += '</table>'

  "<div class='card'><div class='card-head'>Accepted Domains</div><div class='card-body'>$Inner</div></div>"
}

# Sub-Function to build a certificate inventory across all servers, EXCLUDING
# self-signed certificates (the internal Exchange auth/transport certs). Returns an
# array of hashtables so both the KPI tiles and the certificate section can use it.
function Get-CertificateInventory {
  [CmdletBinding()]
  param(
    $ExchangeServers,
    [int]$WarningDays = 30
  )

  $Inventory = @()

  if (-not (Get-Command -Name Get-ExchangeCertificate -ErrorAction SilentlyContinue)) { return $Inventory }

  foreach ($Server in $ExchangeServers) {

    try {
      $Certificates = @(Get-ExchangeCertificate -Server $Server.Name -ErrorAction SilentlyContinue)
    }
    catch {
      Write-Warning -Message ('Cannot retrieve certificates for {0}' -f $Server.Name)
      $Certificates = @()
    }

    foreach ($Certificate in $Certificates) {

      # Skip self-signed certificates
      if ($Certificate.IsSelfSigned) { continue }

      if ($Certificate.Services) { $Services = $Certificate.Services.ToString() } else { $Services = 'None' }
      $DaysLeft = [int][math]::Round(($Certificate.NotAfter - (Get-Date)).TotalDays)

      $Inventory += @{
        Server     = $Server.Name.ToUpper()
        Subject    = $Certificate.Subject
        Issuer     = $Certificate.Issuer
        Services   = $Services
        NotBefore  = $Certificate.NotBefore
        NotAfter   = $Certificate.NotAfter
        DaysLeft   = $DaysLeft
        Status     = "$($Certificate.Status)"
        KeySize    = $Certificate.PublicKeySize
        Thumbprint = $Certificate.Thumbprint
      }
    }
  }

  $Inventory
}

# Sub-Function to render the certificate section (cards grouped by server) from the
# certificate inventory. Self-signed certs are already excluded by the inventory.
function Get-HtmlCertificateSection {
  [CmdletBinding()]
  param(
    $Certificates,
    [int]$WarningDays = 30
  )

  if (-not $Certificates -or @($Certificates).Count -eq 0) { return '' }

  $Inner = ''
  $Servers = $Certificates | ForEach-Object { $_.Server } | Sort-Object -Unique

  foreach ($ServerName in $Servers) {
    $Inner += ("<div class='cert-server'><div class='cert-server-name'>{0}</div><table class='grid'><tr><th>Subject</th><th>Issuer</th><th>Services</th><th>Valid From</th><th>Valid Until</th><th>Validity</th><th>Key</th><th>Thumbprint</th></tr>" -f $ServerName)

    foreach ($Cert in ($Certificates | Where-Object { $_.Server -eq $ServerName } | Sort-Object -Property DaysLeft)) {
      if ($Cert.DaysLeft -lt 0) { $ValidityClass = 'crit-text'; $ValidityText = 'Expired' }
      elseif ($Cert.DaysLeft -le $WarningDays) { $ValidityClass = 'warn-text'; $ValidityText = ('Expires in {0} d' -f $Cert.DaysLeft) }
      else { $ValidityClass = ''; $ValidityText = ('{0} d' -f $Cert.DaysLeft) }

      $Inner += ("<tr><td>{0}</td><td>{1}</td><td class='center'>{2}</td><td class='center'>{3}</td><td class='center'>{4}</td><td class='center {5}'>{6}</td><td class='center'>{7}</td><td class='thumb'>{8}</td></tr>" -f `
          $Cert.Subject, $Cert.Issuer, $Cert.Services, $Cert.NotBefore.ToString('yyyy-MM-dd'), $Cert.NotAfter.ToString('yyyy-MM-dd'), $ValidityClass, $ValidityText, $Cert.KeySize, $Cert.Thumbprint)
    }

    $Inner += '</table></div>'
  }

  $Body = $Inner + ("<p class='muted'>Self-signed certificates are excluded. Certificates expiring within {0} day(s) are amber; already-expired certificates are red.</p>" -f $WarningDays)

  "<div class='card'><div class='card-head'>Exchange Certificates</div><div class='card-body'>$Body</div></div>"
}

# Sub-Function to compute a support-lifecycle status (Mainstream / Extended / Out of support)
# from mainstream and extended end dates versus today. Returns @{ Text; Level }.
function Get-SupportStatus {
  [CmdletBinding()]
  param(
    [string]$MainstreamEnd,
    [string]$ExtendedEnd
  )

  $Now = Get-Date

  try {
    $Extended = [datetime]$ExtendedEnd
  }
  catch {
    return @{ Text = 'Unknown'; Level = 'info' }
  }

  if ($Now -gt $Extended) {
    return @{ Text = ('Out of support (ended {0})' -f $Extended.ToString('yyyy-MM-dd')); Level = 'crit' }
  }

  if ($MainstreamEnd) {
    try {
      $Mainstream = [datetime]$MainstreamEnd
      if ($Now -gt $Mainstream) {
        return @{ Text = ('Extended support (until {0})' -f $Extended.ToString('yyyy-MM-dd')); Level = 'warn' }
      }
      return @{ Text = ('Mainstream support (until {0})' -f $Mainstream.ToString('yyyy-MM-dd')); Level = 'ok' }
    }
    catch { }
  }

  @{ Text = ('Supported (until {0})' -f $Extended.ToString('yyyy-MM-dd')); Level = 'ok' }
}

# Sub-Function to map an OS caption to a Windows Server lifecycle key (order matters:
# '2012 R2' must be tested before '2012').
function Get-WindowsVersionKey {
  [CmdletBinding()]
  param(
    [string]$Caption
  )

  if ($Caption -match '2025') { return '2025' }
  if ($Caption -match '2022') { return '2022' }
  if ($Caption -match '2019') { return '2019' }
  if ($Caption -match '2016') { return '2016' }
  if ($Caption -match '2012 R2') { return '2012 R2' }
  if ($Caption -match '2012') { return '2012' }
  ''
}

# Sub-Function to render a self-contained SVG donut chart (no JavaScript). Colour is
# driven by Level so it renders identically in a browser, print, or saved HTML file.
function Get-SvgDonut {
  [CmdletBinding()]
  param(
    [double]$Percent,
    [string]$CenterText = '',
    [string]$Label = '',
    [string]$Caption = '',
    [ValidateSet('ok', 'warn', 'crit', 'info')]
    [string]$Level = 'ok'
  )

  $Radius = 52
  $Circumference = [math]::Round(2 * [math]::PI * $Radius, 2)
  $BoundedPercent = [math]::Max(0, [math]::Min(100, $Percent))
  $Dash = [math]::Round($Circumference * $BoundedPercent / 100, 2)
  $Gap = [math]::Round($Circumference - $Dash, 2)

  if ([string]::IsNullOrEmpty($CenterText)) { $CenterText = ('{0}%' -f [math]::Round($Percent)) }

  switch ($Level) {
    'crit' { $Color = '#d9362b' }
    'warn' { $Color = '#e07b00' }
    'info' { $Color = '#2f6fb0' }
    default { $Color = '#2e9e5b' }
  }

  @"
<div class="donut donut-$Level">
  <svg viewBox="0 0 120 120" width="112" height="112" role="img" aria-label="$Label $CenterText">
    <circle cx="60" cy="60" r="$Radius" fill="none" stroke="#e6e8eb" stroke-width="12" />
    <circle cx="60" cy="60" r="$Radius" fill="none" stroke="$Color" stroke-width="12" stroke-linecap="round" stroke-dasharray="$Dash $Gap" transform="rotate(-90 60 60)" />
    <text x="60" y="67" text-anchor="middle" font-size="22" font-weight="700" fill="$Color">$CenterText</text>
  </svg>
  <div class="donut-title">$Label</div>
  <div class="donut-caption">$Caption</div>
</div>
"@
}

# Sub-Function to render the dashboard header: title bar, KPI severity tiles, and a
# compact version/role summary. KPI counts summarise environment health across all
# collected data (databases, disks, certificates, edition limits).
function Get-HtmlDashboardHeader {
  [CmdletBinding()]
  param(
    $ExchangeEnvironment
  )

  $CriticalCount = 0
  $WarningCount = 0

  foreach ($Db in $ExchangeEnvironment.AllDatabases) {
    if ($null -eq $Db.BackupAgeDays) { $CriticalCount++ }
    elseif ([int]$Db.BackupAgeDays -gt $MaxBackupAgeDays) { $WarningCount++ }

    if ($Db.Mounted -eq 'No') { $CriticalCount++ }
    if ($Db.ActiveOnPreferred -eq 'No') { $WarningCount++ }

    if ($Db.SizePercentOfMax -ge $DatabaseSizeWarningPercent) { $CriticalCount++ }
    elseif ($Db.SizePercentOfMax -ge $DatabaseSizeCautionPercent) { $WarningCount++ }

    if (($null -ne $Db.FreeDatabaseDiskSpace) -and ([double]$Db.FreeDatabaseDiskSpace -lt $MinFreeDiskspace)) { $WarningCount++ }
    if (($null -ne $Db.FreeLogDiskSpace) -and ([double]$Db.FreeLogDiskSpace -lt $MinFreeDiskspace)) { $WarningCount++ }
  }

  foreach ($ServerEntry in $ExchangeEnvironment.Servers.GetEnumerator()) {
    $Server = $ServerEntry.Value
    if ($Server.EditionKind -eq 'Standard') { $Limit = $StandardMaxDatabases } else { $Limit = $EnterpriseMaxDatabases }
    if ($Server.HostedDatabaseCopies -ge $Limit) { $CriticalCount++ }
    elseif ($Server.HostedDatabaseCopies -ge ($Limit - 1)) { $WarningCount++ }
  }

  if ($ExchangeEnvironment.Certificates) {
    foreach ($Cert in $ExchangeEnvironment.Certificates) {
      if ($Cert.DaysLeft -lt 0) { $CriticalCount++ }
      elseif ($Cert.DaysLeft -le $CertificateWarningDays) { $WarningCount++ }
    }
  }

  $ServerCount = @($ExchangeEnvironment.Servers.Keys).Count
  $DatabaseCount = @($ExchangeEnvironment.AllDatabases).Count
  $MailboxCount = $ExchangeEnvironment.TotalMailboxes

  $Output = ("<div class='app-header'><div class='app-title'>Exchange Environment Report</div><div class='app-sub'>Organization: {0} &nbsp;&bull;&nbsp; Generated {1}</div></div>" -f $ExchangeEnvironment.OrganizationName, (Get-Date -Format 'yyyy-MM-dd HH:mm'))

  $Output += "<div class='kpi-row'>"
  $Output += ("<div class='kpi kpi-crit'><div class='kpi-num'>{0}</div><div class='kpi-label'>Critical</div></div>" -f $CriticalCount)
  $Output += ("<div class='kpi kpi-warn'><div class='kpi-num'>{0}</div><div class='kpi-label'>Warnings</div></div>" -f $WarningCount)
  $Output += ("<div class='kpi kpi-info'><div class='kpi-num'>{0}</div><div class='kpi-label'>Servers</div></div>" -f $ServerCount)
  $Output += ("<div class='kpi kpi-info'><div class='kpi-num'>{0}</div><div class='kpi-label'>Databases</div></div>" -f $DatabaseCount)
  $Output += ("<div class='kpi kpi-info'><div class='kpi-num'>{0}</div><div class='kpi-label'>Mailboxes</div></div>" -f $MailboxCount)
  $Output += '</div>'

  # Compact version summary card
  $Output += "<div class='card'><div class='card-head'>Servers &amp; mailboxes by Exchange version</div><div class='card-body'><table class='grid'><tr><th>Version</th><th>Servers</th><th>Mailboxes</th></tr>"
  $ExchangeEnvironment.TotalMailboxesByVersion.GetEnumerator() | Sort-Object -Property Name | ForEach-Object {
    $Output += ("<tr><td>{0}</td><td class='center'>{1}</td><td class='center'>{2}</td></tr>" -f $ExVersionStrings[$_.Key].Long, $_.Value.ServerCount, $_.Value.MailboxCount)
  }
  if ($ExchangeEnvironment.RemoteMailboxes) {
    $Output += ("<tr><td>Office 365 / Remote</td><td class='center'>-</td><td class='center'>{0}</td></tr>" -f $ExchangeEnvironment.RemoteMailboxes)
  }
  $Output += ("<tr class='grid-total'><td>Total</td><td class='center'>{0}</td><td class='center'>{1}</td></tr>" -f $ServerCount, $MailboxCount)
  $Output += '</table></div></div>'

  $Output
}

# Sub-Function to render one collapsible per-server card with its databases, disk
# usage donuts, edition capacity, and advice. Databases are grouped by the server
# hosting their active copy.
function Get-HtmlServerCard {
  [CmdletBinding()]
  param(
    $Server,
    $ExchangeEnvironment,
    $ExVersionStrings,
    $ExRoleStrings
  )

  $VersionLong = $ExVersionStrings["$($Server.ExchangeMajorVersion).$($Server.ExchangeSPLevel)"].Long
  if ($Server.RollupLevel -gt 0) { $VersionLong += (' UR{0}' -f $Server.RollupLevel) }

  $RoleShort = [string]::Join(', ', @($Server.Roles | ForEach-Object { if ($ExRoleStrings[$_]) { $ExRoleStrings[$_].Short } else { $_ } }))

  # Databases whose active copy is on this server
  $ServerDatabases = @($ExchangeEnvironment.AllDatabases | Where-Object { $_.ActiveOwner -eq $Server.Name })

  # Edition mounted-database limit
  if ($Server.EditionKind -eq 'Enterprise') { $DbLimit = $EnterpriseMaxDatabases } else { $DbLimit = $StandardMaxDatabases }

  # Exchange build / CU name / update currency and support lifecycle.
  # Exchange Server SE shares the 15.2 version family with Exchange 2019; distinguish it
  # by build number (SE RTM starts at 15.2.2562) so it is not mistaken for Exchange 2019.
  $MajorKey = "$($Server.ExchangeMajorVersion)"
  if (($MajorKey -eq '15.2') -and ($Server.ExchangeBuildCU -ge $ExchangeSeMinBuild)) { $RelKey = 'SE' } else { $RelKey = $MajorKey }
  $RelInfo = $ExchangeReleaseInfo[$RelKey]

  $CuName = ''
  if ($ExchangeCuNames[$RelKey] -and $ExchangeCuNames[$RelKey][$Server.ExchangeBuildCU]) {
    $CuName = $ExchangeCuNames[$RelKey][$Server.ExchangeBuildCU]
  }
  elseif ($Server.RollupLevel -gt 0) {
    $CuName = ('UR{0}' -f $Server.RollupLevel)
  }

  # Product display name (correct for SE vs 2019)
  if ($RelInfo) { $ProductName = $RelInfo.Product } else { $ProductName = $VersionLong }

  $ExCurrencyText = 'Unknown - see the Microsoft build numbers page'
  $ExCurrencyLevel = 'info'
  if ($RelInfo) {
    if ($Server.ExchangeBuildCU -ge $RelInfo.LatestCUBuild) {
      $ExCurrencyText = ('Latest release ({0}). Confirm the Security Update level with the Exchange HealthChecker - newest published build is {1} ({2}).' -f $RelInfo.LatestCUName, $RelInfo.LatestFull, $RelInfo.LatestRelease)
      $ExCurrencyLevel = 'ok'
    }
    else {
      $ExCurrencyText = ('Update available - newest is {0} ({1}, {2}).' -f $RelInfo.LatestCUName, $RelInfo.LatestFull, $RelInfo.LatestRelease)
      $ExCurrencyLevel = 'warn'
    }
  }

  # Support lifecycle. Exchange Server SE follows the Modern Lifecycle Policy (supported
  # while kept current), so it has no fixed end-of-support date.
  if ($RelInfo -and $RelInfo.Modern) {
    $ExSupport = @{ Text = 'In support (Modern Lifecycle Policy - stay current)'; Level = 'ok' }
  }
  elseif ($RelInfo) {
    $ExSupport = Get-SupportStatus -MainstreamEnd $RelInfo.MainstreamEnd -ExtendedEnd $RelInfo.ExtendedEnd
  }
  else {
    $ExSupport = @{ Text = 'Unknown'; Level = 'info' }
  }

  # OS lifecycle
  $WinKey = Get-WindowsVersionKey -Caption "$($Server.OSVersion)"
  if ($WinKey -and $WindowsLifecycle[$WinKey]) { $OSSupport = Get-SupportStatus -MainstreamEnd $WindowsLifecycle[$WinKey].MainstreamEnd -ExtendedEnd $WindowsLifecycle[$WinKey].ExtendedEnd } else { $OSSupport = @{ Text = 'Unknown'; Level = 'info' } }

  # Determine overall server health (drives the summary dot and advice)
  $ServerLevel = 'ok'
  $Advice = @()

  if ($Server.HostedDatabaseCopies -ge $DbLimit) {
    $ServerLevel = 'crit'
    if ($Server.EditionKind -eq 'Standard') {
      $Advice += ("This server hosts {0} of the {1} databases allowed by Exchange Standard Edition. To add more databases you must upgrade this server to Enterprise Edition (up to {2} databases)." -f $Server.HostedDatabaseCopies, $DbLimit, $EnterpriseMaxDatabases)
    }
    else {
      $Advice += ("This server hosts {0} of the {1} databases allowed by Exchange Enterprise Edition. Redistribute databases or add another server." -f $Server.HostedDatabaseCopies, $DbLimit)
    }
  }
  elseif ($Server.HostedDatabaseCopies -ge ($DbLimit - 1)) {
    if ($ServerLevel -eq 'ok') { $ServerLevel = 'warn' }
    $Advice += ("This server is close to its edition limit: {0} of {1} databases hosted." -f $Server.HostedDatabaseCopies, $DbLimit)
  }

  foreach ($Db in $ServerDatabases) {
    if (($null -eq $Db.BackupAgeDays) -or ($Db.Mounted -eq 'No') -or ($Db.SizePercentOfMax -ge $DatabaseSizeWarningPercent)) { $ServerLevel = 'crit' }
    elseif (($ServerLevel -ne 'crit') -and (($Db.SizePercentOfMax -ge $DatabaseSizeCautionPercent) -or ($Db.ActiveOnPreferred -eq 'No'))) { $ServerLevel = 'warn' }
  }

  # Fold Exchange / OS support status into overall health
  if (($ExSupport.Level -eq 'crit') -or ($OSSupport.Level -eq 'crit')) { $ServerLevel = 'crit' }
  elseif (($ServerLevel -ne 'crit') -and (($ExSupport.Level -eq 'warn') -or ($OSSupport.Level -eq 'warn') -or ($ExCurrencyLevel -eq 'warn'))) { $ServerLevel = 'warn' }

  if ($ExSupport.Level -eq 'crit') { $Advice += ('{0} is out of support. Plan migration to a supported version (e.g. Exchange Server SE).' -f $RelInfo.Product) }

  # --- Summary line ---
  $Output = "<details class='server-card'>"
  $Output += ("<summary class='server-summary'><span class='dot dot-{0}'></span><span class='srv-name'>{1}</span>" -f $ServerLevel, $Server.Name)
  if ($Server.RealName -ne $Server.Name) { $Output += (" <span class='srv-real'>({0})</span>" -f $Server.RealName) }
  $Output += "<span class='srv-badges'>"
  $Output += ("<span class='badge'>{0}{1}</span>" -f $ProductName, $(if ($CuName) { " $CuName" } else { '' }))
  $Output += ("<span class='badge badge-edition'>{0}</span>" -f $Server.EditionKind)
  if ($RoleShort) { $Output += ("<span class='badge'>Roles: {0}</span>" -f $RoleShort) }
  $Output += ("<span class='badge'>Mailboxes: {0}</span>" -f $Server.Mailboxes)
  $Output += ("<span class='badge'>DBs: {0}/{1}</span>" -f $Server.HostedDatabaseCopies, $DbLimit)
  $Output += '</span><span class="srv-toggle"></span></summary>'

  $Output += "<div class='server-body'>"

  # --- Server facts ---
  # Level -> text-colour class helper (inline)
  $ExSupportClass = if ($ExSupport.Level -eq 'crit') { 'crit-text' } elseif ($ExSupport.Level -eq 'warn') { 'warn-text' } else { '' }
  $OSSupportClass = if ($OSSupport.Level -eq 'crit') { 'crit-text' } elseif ($OSSupport.Level -eq 'warn') { 'warn-text' } else { '' }
  $ExCurrencyClass = if ($ExCurrencyLevel -eq 'crit') { 'crit-text' } elseif ($ExCurrencyLevel -eq 'warn') { 'warn-text' } else { '' }

  # Version label incl. CU + build (uses the corrected product name, e.g. Exchange Server SE)
  $VersionLabel = $ProductName
  if ($CuName) { $VersionLabel = ('{0} {1}' -f $ProductName, $CuName) }
  $VersionLabel += (' &nbsp;<span class="muted">(build {0})</span>' -f $Server.ExchangeBuildFull)

  # OS label incl. display version
  $OSLabel = $Server.OSVersion
  if ($Server.OSDisplayVersion) { $OSLabel += (' {0}' -f $Server.OSDisplayVersion) }

  # Active vs preferred database counts (highlight if a DB is active off its preferred copy)
  $ActivePreferredClass = if ($Server.ActiveDatabaseCount -ne $Server.PreferredDatabaseCount) { 'warn-text' } else { '' }

  # Hosted copies vs edition limit
  $HostedClass = if ($Server.HostedDatabaseCopies -ge $DbLimit) { 'crit-text' } elseif ($Server.HostedDatabaseCopies -ge ($DbLimit - 1)) { 'warn-text' } else { '' }

  $Output += "<div class='card'><div class='card-head'>Server details</div><div class='card-body'><table class='grid'>"
  $Output += ("<tr><th>Exchange version</th><td>{0}</td><th>Edition</th><td>{1} ({2})</td></tr>" -f $VersionLabel, $Server.Edition, $Server.EditionKind)
  $Output += ("<tr><th>Exchange updates</th><td colspan='3' class='{0}'>{1}</td></tr>" -f $ExCurrencyClass, $ExCurrencyText)
  $Output += ("<tr><th>Exchange support</th><td colspan='3' class='{0}'>{1}</td></tr>" -f $ExSupportClass, $ExSupport.Text)
  $Output += ("<tr><th>Roles</th><td>{0}</td><th>Site</th><td>{1}</td></tr>" -f $RoleShort, $Server.Site)
  $Output += ("<tr><th>Operating system</th><td>{0}</td><th>OS build / update</th><td>{1}</td></tr>" -f $OSLabel, $Server.OSBuild)
  $Output += ("<tr><th>Latest OS update</th><td>{0}</td><th>OS support</th><td class='{1}'>{2}</td></tr>" -f $Server.OSLatestUpdate, $OSSupportClass, $OSSupport.Text)
  $Output += ("<tr><th>Databases active / preferred</th><td class='{0}'>{1} active / {2} preferred</td><th>Databases hosted (copies)</th><td class='{3}'>{4} of {5} (edition limit)</td></tr>" -f $ActivePreferredClass, $Server.ActiveDatabaseCount, $Server.PreferredDatabaseCount, $HostedClass, $Server.HostedDatabaseCopies, $DbLimit)
  if (($Server.MaximumActiveDatabases -ne '--') -and ($Server.MaximumActiveDatabases -ne 0) -and ($null -ne $Server.MaximumActiveDatabases)) {
    $Output += ("<tr><th>Configured max active DBs</th><td>{0}</td><th>Configured preferred</th><td>{1}</td></tr>" -f $Server.MaximumActiveDatabases, $Server.MaximumPreferredDatabases)
  }
  $Output += '</table></div></div>'

  # --- Disk volume donuts ---
  if ($Server.Disks) {
    $Output += "<div class='card'><div class='card-head'>Disk volumes</div><div class='card-body donut-grid'>"
    foreach ($Disk in $Server.Disks) {
      if ($Disk.Capacity -gt 0) {
        $FreePercent = [math]::Round(($Disk.FreeSpace / $Disk.Capacity) * 100, 1)
        $UsedPercent = [math]::Round(100 - $FreePercent, 1)
        if ($FreePercent -lt $MinFreeDiskspace) { $Lvl = 'crit' } elseif ($FreePercent -lt 20) { $Lvl = 'warn' } else { $Lvl = 'ok' }
        $Caption = ('{0:N0} GB free of {1:N0} GB' -f ($Disk.FreeSpace / 1GB), ($Disk.Capacity / 1GB))
        $Output += Get-SvgDonut -Percent $UsedPercent -CenterText ('{0}%' -f [math]::Round($UsedPercent)) -Label ($Disk.Name) -Caption $Caption -Level $Lvl
      }
    }
    $Output += '</div></div>'
  }

  # --- Databases active on this server ---
  $Output += ("<div class='card'><div class='card-head'>Databases active on this server ({0})</div><div class='card-body'>" -f $ServerDatabases.Count)

  if ($ServerDatabases.Count -eq 0) {
    $Output += "<p class='muted'>No active mailbox databases on this server.</p>"
  }

  foreach ($Db in $ServerDatabases) {

    # Size-vs-max level
    if ($Db.SizePercentOfMax -ge $DatabaseSizeWarningPercent) { $SizeLevel = 'crit' }
    elseif ($Db.SizePercentOfMax -ge $DatabaseSizeCautionPercent) { $SizeLevel = 'warn' }
    else { $SizeLevel = 'ok' }

    $Output += "<div class='db'>"
    $Output += ("<div class='db-head'><span class='db-name'>{0}</span><span class='badges'>" -f $Db.Name)

    # Backup badge
    if ($null -eq $Db.BackupAgeDays) { $Output += "<span class='badge badge-crit'>No backup</span>" }
    elseif ([int]$Db.BackupAgeDays -gt $MaxBackupAgeDays) { $Output += ("<span class='badge badge-warn'>Backup {0}d ago</span>" -f $Db.BackupAgeDays) }
    else { $Output += ("<span class='badge badge-ok'>Backup {0}d ago</span>" -f $Db.BackupAgeDays) }

    # Mount badge
    if ($Db.Mounted -eq 'No') { $Output += "<span class='badge badge-crit'>Dismounted</span>" }
    elseif ($Db.Mounted -eq 'Yes') { $Output += "<span class='badge badge-ok'>Mounted</span>" }

    # Active-on-preferred badge
    if ($Db.ActiveOnPreferred -eq 'No') { $Output += "<span class='badge badge-warn'>Not on preferred copy</span>" }
    elseif ($Db.ActiveOnPreferred -eq 'Yes') { $Output += "<span class='badge badge-ok'>On preferred copy</span>" }

    $Output += '</span></div>'

    $Output += "<div class='db-body'>"

    # Donuts: size-vs-max
    $Output += "<div class='donut-grid'>"
    $SizeCaption = ('{0:N1} GB of {1:N0} GB max<br/><span class="muted">{2}</span>' -f ($Db.Size / 1GB), $Db.MaxSizeGB, $Db.MaxSizeSource)
    $Output += Get-SvgDonut -Percent $Db.SizePercentOfMax -CenterText ('{0}%' -f [math]::Round($Db.SizePercentOfMax)) -Label 'Size vs Max' -Caption $SizeCaption -Level $SizeLevel
    $Output += '</div>'

    # Facts
    $Output += "<table class='grid db-facts'>"
    $Output += ("<tr><th>Mailboxes</th><td>{0}</td><th>Avg mailbox size</th><td>{1:N2} MB</td></tr>" -f $Db.MailboxCount, ($Db.MailboxAverageSize / 1MB))
    $Output += ("<tr><th>Database size</th><td>{0:N2} GB</td><th>Whitespace</th><td>{1:N2} GB</td></tr>" -f ($Db.Size / 1GB), ($Db.Whitespace / 1GB))
    $Output += ("<tr><th>Maximum size</th><td>{0} GB <span class='muted'>({1})</span></td><th>Utilisation</th><td class='{2}'>{3}% of max</td></tr>" -f $Db.MaxSizeGB, $Db.MaxSizeSource, $(if ($SizeLevel -eq 'ok') { 'center' } else { "center $SizeLevel-text" }), $Db.SizePercentOfMax)

    # Backups row
    $BackupCells = ("Full: {0}" -f $Db.LastFullBackup)
    if ($Db.LastIncrementalBackup -ne 'Never') { $BackupCells += (" &nbsp;|&nbsp; Incremental: {0}" -f $Db.LastIncrementalBackup) }
    if ($Db.LastDifferentialBackup -ne 'Never') { $BackupCells += (" &nbsp;|&nbsp; Differential: {0}" -f $Db.LastDifferentialBackup) }
    if ($Db.LastCopyBackup -ne 'Never') { $BackupCells += (" &nbsp;|&nbsp; Copy: {0}" -f $Db.LastCopyBackup) }
    $Output += ("<tr><th>Backups</th><td colspan='3'>{0}</td></tr>" -f $BackupCells)

    if ($Db.ActivationPreference.Count -gt 0) {
      $Output += ("<tr><th>Activation preference</th><td>{0}</td><th>Preferred owner</th><td>{1}</td></tr>" -f [string]::Join(', ', $Db.ActivationPreference), $Db.PreferredServer)
    }

    $Output += ("<tr><th>Circular logging</th><td>{0}</td><th>Copies</th><td>{1}</td></tr>" -f $Db.CircularLoggingEnabled, $Db.CopyCount)
    $Output += ("<tr><th>Database path</th><td colspan='3'>{0}</td></tr>" -f $Db.EdbFilePath)
    $Output += ("<tr><th>Log folder path</th><td colspan='3'>{0}</td></tr>" -f $Db.LogFolderPath)
    $Output += '</table>'

    # Per-database advice
    if ($Db.SizePercentOfMax -ge $DatabaseSizeCautionPercent) {
      $DbAdvice = ("Database is at {0}% of its {1} GB maximum ({2})." -f $Db.SizePercentOfMax, $Db.MaxSizeGB, $Db.MaxSizeSource)
      if ($Server.HostedDatabaseCopies -lt $DbLimit) {
        $DbAdvice += (" Consider moving mailboxes to a new database (this server can host {0} more) and/or expanding the volume." -f ($DbLimit - $Server.HostedDatabaseCopies))
      }
      else {
        $DbAdvice += ' The server is at its edition database limit, so free space by moving mailboxes to another server or upgrading the edition.'
      }
      if ($Server.EditionKind -eq 'Standard' -and $Db.MaxSizeSource -eq 'Standard default') {
        $DbAdvice += ' Standard Edition caps databases at 1024 GB; upgrade to Enterprise to remove this limit.'
      }
      $AdviceLevel = if ($Db.SizePercentOfMax -ge $DatabaseSizeWarningPercent) { 'crit' } else { 'warn' }
      $Output += ("<div class='advice advice-{0}'>{1}</div>" -f $AdviceLevel, $DbAdvice)
    }

    $Output += '</div></div>'
  }

  $Output += '</div></div>'

  # --- Server-level advice ---
  foreach ($Line in $Advice) {
    $Output += ("<div class='advice advice-{0}'>{1}</div>" -f $ServerLevel, $Line)
  }

  $Output += '</div></details>'

  $Output
}

# Sub-Function to render the DAG summary section (membership, witness, per-member copies).
function Get-HtmlDagSection {
  [CmdletBinding()]
  param(
    $ExchangeEnvironment
  )

  if (-not $ExchangeEnvironment.DAGs -or @($ExchangeEnvironment.DAGs | Where-Object { $_.MemberCount -gt 0 }).Count -eq 0) { return '' }

  $Output = "<div class='card'><div class='card-head'>Database Availability Groups</div><div class='card-body'>"

  foreach ($DAG in $ExchangeEnvironment.DAGs) {
    if ($DAG.MemberCount -gt 0) {
      $Output += "<table class='grid'>"
      $Output += ("<tr><th>DAG</th><td>{0}</td><th>Members</th><td>{1}</td></tr>" -f $DAG.Name, $DAG.MemberCount)
      $Output += ("<tr><th>Member servers</th><td colspan='3'>{0}</td></tr>" -f [string]::Join(', ', $DAG.Members))
      $Output += ("<tr><th>Databases</th><td>{0}</td><th>Witness server</th><td>{1}</td></tr>" -f @($DAG.Databases).Count, $DAG.WitnessServer)
      $Output += ("<tr><th>Witness directory</th><td>{0}</td><th>Alternate witness</th><td>{1}</td></tr>" -f $DAG.WitnessDirectory, $DAG.AlternateWitnessServer)
      $Output += '</table>'

      # Per-member copy counts vs edition limit
      $Output += "<table class='grid'><tr><th>Member</th><th>Database copies hosted</th><th>Edition limit</th></tr>"
      foreach ($MemberName in ($DAG.Members | ForEach-Object { $_.ToUpper() })) {
        $MemberInfo = $ExchangeEnvironment.Servers[$MemberName]
        if ($MemberInfo) {
          if ($MemberInfo.EditionKind -eq 'Enterprise') { $Limit = $EnterpriseMaxDatabases } else { $Limit = $StandardMaxDatabases }
          $Cls = if ($MemberInfo.HostedDatabaseCopies -ge $Limit) { 'center crit-text' } elseif ($MemberInfo.HostedDatabaseCopies -ge ($Limit - 1)) { 'center warn-text' } else { 'center' }
          $Output += ("<tr><td>{0}</td><td class='{1}'>{2}</td><td class='center'>{3} ({4})</td></tr>" -f $MemberName, $Cls, $MemberInfo.HostedDatabaseCopies, $Limit, $MemberInfo.EditionKind)
        }
      }
      $Output += '</table>'
      $Output += "<p class='muted'>The Standard (5) / Enterprise (100) database limit is per server and counts all copies (active + passive) a member hosts.</p>"
    }
  }

  $Output += '</div></div>'
  $Output
}

# Sub-Function for interactive yes/no prompts. Returns $true for yes, $false for no.
function Read-YesNo {
  [CmdletBinding()]
  param(
    [string]$Question,
    [bool]$DefaultYes = $false
  )

  if ($DefaultYes) { $suffix = '[Y/n]' } else { $suffix = '[y/N]' }

  do {
    $answer = (Read-Host -Prompt ('{0} {1}' -f $Question, $suffix)).Trim()

    if ([string]::IsNullOrWhiteSpace($answer)) { return $DefaultYes }

    switch -Regex ($answer) {
      '^(y|yes)$' { return $true }
      '^(n|no)$' { return $false }
      default { Write-Host 'Please answer y or n.' -ForegroundColor Yellow }
    }
  } while ($true)
}

# Sub Function to neatly update progress
function Show-ProgressBar {
  [CmdletBinding()]
  param(
    [int]$PercentComplete,
    [string]$Status,
    [int]$Stage
  )

  $TotalStages = 5
  Write-Progress -Id 1 -Activity 'Get-ExchangeEnvironmentReport' -Status $Status -PercentComplete (($PercentComplete / $TotalStages) + (1 / $TotalStages * $Stage * 100))
}

# 1. Initial Startup

# 1.0 Interactive mode
# If no -HTMLReport file name was supplied, prompt for everything at run time so
# that nothing (report name, email addresses, SMTP server) has to be hard-coded.
# Supplying -HTMLReport (e.g. for scheduled/unattended runs) skips all prompts.
if (-not $PSBoundParameters.ContainsKey('HTMLReport')) {

  Write-Host ''
  Write-Host 'Exchange Environment Report - interactive run' -ForegroundColor Cyan
  Write-Host '---------------------------------------------' -ForegroundColor Cyan

  # Report file name / location on disk (report is always saved to disk).
  $DefaultReportName = ('ExchangeEnvironment_{0}.html' -f (Get-Date -Format 'yyyyMMdd_HHmm'))
  $HTMLReport = (Read-Host -Prompt ('HTML report file name to save on disk (default: {0})' -f $DefaultReportName)).Trim()

  if ([string]::IsNullOrWhiteSpace($HTMLReport)) {
    $HTMLReport = $DefaultReportName
  }

  # Optionally include EDB/LOG drive names.
  if (Read-YesNo -Question 'Include EDB/LOG drive names in the database table?' -DefaultYes $false) {
    $ShowDriveNames = $true
  }

  # Optionally email the report. Only ask for SMTP details if the user opts in.
  if (Read-YesNo -Question 'Email the report after it is generated?' -DefaultYes $false) {

    do {
      $MailServer = (Read-Host -Prompt 'SMTP server (host name or IP)').Trim()
      if ([string]::IsNullOrWhiteSpace($MailServer)) { Write-Host 'SMTP server is required.' -ForegroundColor Yellow }
    } while ([string]::IsNullOrWhiteSpace($MailServer))

    do {
      $MailFrom = (Read-Host -Prompt 'From address').Trim()
      if ([string]::IsNullOrWhiteSpace($MailFrom)) { Write-Host 'From address is required.' -ForegroundColor Yellow }
    } while ([string]::IsNullOrWhiteSpace($MailFrom))

    do {
      $MailTo = (Read-Host -Prompt 'To address (separate multiple recipients with a comma)').Trim()
      if ([string]::IsNullOrWhiteSpace($MailTo)) { Write-Host 'To address is required.' -ForegroundColor Yellow }
    } while ([string]::IsNullOrWhiteSpace($MailTo))

    $SendMail = $true
  }

  Write-Host ''
  Write-Host 'Generating Exchange environment report...' -ForegroundColor Cyan
}

# 1.0.1 Check Powershell Version
if ((Get-Host).Version.Major -eq 1) {
  throw 'Powershell Version 1 not supported'
}

# 1.1 Check Exchange Management Shell, attempt to load
if (!(Get-Command -Name Get-ExchangeServer -ErrorAction SilentlyContinue)) {
  # Support for Exchange Scripts located in non-default locations
  # Use $env:ExchangeInstallPath for Exchange 2010/2013+ installations
  $ExchangeInstallPath = $env:ExchangeInstallPath

  if (($ExchangeInstallPath -eq '') -or ($null -eq $ExchangeInstallPath)) {
    # $env:ExchangeInstallPath not available on Exchange Server 2007 Setups
    try {
      $ExchangeInstallPath = (Get-ItemProperty -Path HKLM:\SOFTWARE\Microsoft\Exchange\Setup).MsiInstallPath
    }
    catch {}
  }

  Write-Verbose -Message ('Exchange Install Path: {0}' -f $ExchangeInstallPath)

  $RemoteExchangePath = Join-Path -Path $ExchangeInstallPath -ChildPath 'bin\RemoteExchange.ps1'
  $LocalExchangePath = Join-Path -Path $ExchangeInstallPath -ChildPath 'bin\Exchange.ps1'

  if (Test-Path -Path $RemoteExchangePath) {
    . $RemoteExchangePath
    Connect-ExchangeServer -auto
  }
  elseif (Test-Path -Path $LocalExchangePath) {
    Add-PSSnapIn -Name Microsoft.Exchange.Management.PowerShell.Admin
    . $LocalExchangePath
  }
  else {
    throw 'Exchange Management Shell cannot be loaded'
  }
}

# 1.1.1 Check if CSS file is present
# Issue #6
if (Test-Path -Path (Join-Path -Path $ScriptDir -ChildPath $CssFileName)) {
  Write-Verbose ('Using {0} as CSS file for HTML report.' -f $CssFileName )
}
else {
  throw ('CSS file {0} is missing. It is required for a proper HTML report. Please see the GitHub repository for more information.' -f $CssFileName)
}

# 1.2 Check if -SendMail parameter set and if so check -MailFrom, -MailTo and -MailServer are set
if ($SendMail) {
  if (!$MailFrom -or !$MailTo -or !$MailServer) {
    throw 'If -SendMail specified, you must also specify -MailFrom, -MailTo and -MailServer'
  }
}

# 1.3 Check Exchange Management Shell Version
if ((Get-PSSnapin -Name Microsoft.Exchange.Management.PowerShell.Admin -ErrorAction SilentlyContinue)) {
  $E2010 = $false;
  if (Get-ExchangeServer | Where-Object { $_.AdminDisplayVersion.Major -gt 14 }) {
    Write-Warning -Message "Exchange 2010 or higher detected. You'll get better results if you run this script from the latest management shell"
  }
}
else {

  $E2010 = $true

  # Support for Exchange 2013+ servers with installed management tools
  $localversion = $localserver = (Get-ItemProperty -Path HKLM:\SOFTWARE\Microsoft\ExchangeServer\v15\Setup).MsiProductMajor

  if ($localversion -eq 15) { $E2013 = $true }
}

# 1.4 Check view entire forest if set (by default, true)
if ($E2010) {
  Set-ADServerSettings -ViewEntireForest:$ViewEntireForest
}
else {
  $global:AdminSessionADSettings.ViewEntireForest = $ViewEntireForest
}

# 1.5 Initial Variables

# 1.5.1 Hashtable to update with environment data
$ExchangeEnvironment = @{
  Sites            = @{}
  Pre2007          = @{}
  Servers          = @{}
  DAGs             = @()
  NonDAGDatabases  = @()
  AllDatabases     = @()
  Certificates     = @()
  OrganizationName = ''
}

# 1.5.7 Exchange Major Version String Mapping
$ExMajorVersionStrings = @{
  '6.0'  = @{Long = 'Exchange 2000'; Short = 'E2000' }
  '6.5'  = @{Long = 'Exchange 2003'; Short = 'E2003' }
  '8'    = @{Long = 'Exchange 2007'; Short = 'E2007' }
  '14'   = @{Long = 'Exchange 2010'; Short = 'E2010' }
  '15'   = @{Long = 'Exchange 2013'; Short = 'E2013' }
  '15.1' = @{Long = 'Exchange 2016'; Short = 'E2016' }
  '15.2' = @{Long = 'Exchange 2019'; Short = 'E2019' } # Exchange Server 2019 added
}

# 1.5.8 Exchange Service Pack String Mapping
$ExSPLevelStrings = @{
  '0'   = 'RTM'
  '1'   = 'SP1'
  '2'   = 'SP2'
  '3'   = 'SP3'
  '4'   = 'SP4'
  'SP1' = 'SP1'
  'SP2' = 'SP2'
}

# Add many CUs
for ($i = 1; $i -le 40; $i++) {
  $ExSPLevelStrings.Add("CU$($i)", "CU$($i)");
}

# 1.5.9 Populate Full Mapping using above info
$ExVersionStrings = @{}

foreach ($Major in $ExMajorVersionStrings.GetEnumerator()) {
  foreach ($Minor in $ExSPLevelStrings.GetEnumerator()) {
    $ExVersionStrings.Add("$($Major.Key).$($Minor.Key)", @{Long = "$($Major.Value.Long) $($Minor.Value)"; Short = "$($Major.Value.Short)$($Minor.Value)" })
  }
}
# 1.5.10 Exchange Role String Mapping
$ExRoleStrings = @{'ClusteredMailbox' = @{Short = 'ClusMBX'; Long = 'CCR/SCC Clustered Mailbox' }
  'Mailbox'                           = @{Short = 'MBX'; Long = 'Mailbox' }
  'ClientAccess'                      = @{Short = 'CAS'; Long = 'Client Access' }
  'HubTransport'                      = @{Short = 'HUB'; Long = 'Hub Transport' }
  'UnifiedMessaging'                  = @{Short = 'UM'; Long = 'Unified Messaging' }
  'Edge'                              = @{Short = 'EDGE'; Long = 'Edge Transport' }
  'FE'                                = @{Short = 'FE'; Long = 'Front End' }
  'BE'                                = @{Short = 'BE'; Long = 'Back End' }
  'Hybrid'                            = @{Short = 'HYB'; Long = 'Hybrid' }
  'Coexistence'                       = @{Short = 'COEX'; Long = 'Coexistence' } # Coexistence added
  'Unknown'                           = @{Short = 'Unknown'; Long = 'Unknown' }
}

# 1.5.11 Exchange release / support reference data.
# Keyed by "Major.Minor". LatestCUBuild is the third octet of the newest CU; LatestFull
# is the newest published build (CU + latest SU). Support dates per Microsoft lifecycle.
# UPDATE PERIODICALLY from:
#   https://learn.microsoft.com/en-us/exchange/new-features/build-numbers-and-release-dates
#   https://learn.microsoft.com/en-us/exchange/plan-and-deploy/supportability-matrix
# Data below current as of the June 2026 Microsoft build/lifecycle pages.
# Exchange Server SE shares the 15.2 version family with Exchange 2019, but is a
# separate, currently-supported product (Modern Lifecycle Policy). It is distinguished
# by build: Exchange 2019 tops out at CU15 (15.2.1748), SE RTM starts at 15.2.2562.
$ExchangeSeMinBuild = 2562
$ExchangeReleaseInfo = @{
  'SE'   = @{ Product = 'Exchange Server SE'; LatestCUBuild = 2562; LatestCUName = 'SE RTM'; LatestFull = '15.2.2562.43'; LatestRelease = 'SE RTM Jun26SU'; Modern = $true; MainstreamEnd = ''; ExtendedEnd = '' }
  '15.2' = @{ Product = 'Exchange 2019'; LatestCUBuild = 1748; LatestCUName = 'CU15'; LatestFull = '15.2.1748.46'; LatestRelease = 'CU15 Jun26SU'; MainstreamEnd = '2024-01-09'; ExtendedEnd = '2025-10-14' }
  '15.1' = @{ Product = 'Exchange 2016'; LatestCUBuild = 2507; LatestCUName = 'CU23'; LatestFull = '15.1.2507.69'; LatestRelease = 'CU23 Jun26SU'; MainstreamEnd = '2020-10-13'; ExtendedEnd = '2025-10-14' }
  '15'   = @{ Product = 'Exchange 2013'; LatestCUBuild = 1497; LatestCUName = 'CU23'; LatestFull = '15.0.1497.48'; LatestRelease = 'CU23 Mar23SU'; MainstreamEnd = '2018-04-10'; ExtendedEnd = '2023-04-11' }
  '14'   = @{ Product = 'Exchange 2010'; LatestCUBuild = 0; LatestCUName = 'SP3 RU32'; LatestFull = '14.3.513.0'; LatestRelease = 'SP3 RU32'; MainstreamEnd = '2015-01-13'; ExtendedEnd = '2020-10-13' }
  '8'    = @{ Product = 'Exchange 2007'; LatestCUBuild = 0; LatestCUName = 'SP3 RU23'; LatestFull = '8.3.517.0'; LatestRelease = 'SP3 RU23'; MainstreamEnd = '2012-04-10'; ExtendedEnd = '2017-04-11' }
}

# CU name by build (third octet), keyed by "Major.Minor" - used to name the installed CU.
$ExchangeCuNames = @{
  'SE'   = @{ 2562 = 'RTM' }
  '15.2' = @{ 221 = 'RTM'; 330 = 'CU1'; 397 = 'CU2'; 464 = 'CU3'; 529 = 'CU4'; 595 = 'CU5'; 659 = 'CU6'; 721 = 'CU7'; 792 = 'CU8'; 858 = 'CU9'; 922 = 'CU10'; 986 = 'CU11'; 1118 = 'CU12'; 1258 = 'CU13'; 1544 = 'CU14'; 1748 = 'CU15' }
  '15.1' = @{ 225 = 'RTM'; 396 = 'CU1'; 466 = 'CU2'; 544 = 'CU3'; 669 = 'CU4'; 845 = 'CU5'; 1034 = 'CU6'; 1261 = 'CU7'; 1415 = 'CU8'; 1466 = 'CU9'; 1531 = 'CU10'; 1591 = 'CU11'; 1713 = 'CU12'; 1779 = 'CU13'; 1847 = 'CU14'; 1913 = 'CU15'; 1979 = 'CU16'; 2044 = 'CU17'; 2106 = 'CU18'; 2176 = 'CU19'; 2242 = 'CU20'; 2308 = 'CU21'; 2375 = 'CU22'; 2507 = 'CU23' }
  '15'   = @{ 516 = 'RTM'; 847 = 'SP1'; 1497 = 'CU23' }
}

# 1.5.12 Windows Server support-lifecycle reference data (per Microsoft Lifecycle).
# UPDATE PERIODICALLY from https://learn.microsoft.com/en-us/lifecycle/products/
$WindowsLifecycle = @{
  '2025'    = @{ MainstreamEnd = '2029-10-09'; ExtendedEnd = '2034-10-10' }
  '2022'    = @{ MainstreamEnd = '2026-10-13'; ExtendedEnd = '2031-10-14' }
  '2019'    = @{ MainstreamEnd = '2024-01-09'; ExtendedEnd = '2029-01-09' }
  '2016'    = @{ MainstreamEnd = '2022-01-11'; ExtendedEnd = '2027-01-12' }
  '2012 R2' = @{ MainstreamEnd = '2018-10-09'; ExtendedEnd = '2023-10-10' }
  '2012'    = @{ MainstreamEnd = '2018-10-09'; ExtendedEnd = '2023-10-10' }
}

# 2 Get Relevant Exchange Information Up-Front

# 2.1 Get Server, Exchange and Mailbox Information
Show-ProgressBar -PercentComplete 1 -Status 'Getting Exchange Server List' -Stage 1

$ExchangeServers = [array](Get-ExchangeServer $ServerFilter | Sort-Object Name)
if (!$ExchangeServers) {
  throw ('No Exchange Servers matched by -ServerFilter {0}' -f $ServerFilter)
}

$HybridServers = @()
if (Get-Command -Name Get-HybridConfiguration -ErrorAction SilentlyContinue) {
  $HybridConfig = Get-HybridConfiguration
  $HybridConfig.ReceivingTransportServers | ForEach-Object { $HybridServers += $_.Name }
  $HybridConfig.SendingTransportServers | ForEach-Object { $HybridServers += $_.Name }
  $HybridServers = $HybridServers | Sort-Object -Unique
}

Show-ProgressBar -PercentComplete 10 -Status 'Getting Mailboxes' -Stage 1

$Mailboxes = [array](Get-Mailbox -ResultSize Unlimited) | Where-Object { $_.ServerName -like $ServerFilter }

if ($E2010) {

  Show-ProgressBar -PercentComplete 60 -Status 'Getting Archive Mailboxes' -Stage 1

  $ArchiveMailboxes = [array](Get-Mailbox -Archive -ResultSize Unlimited) | Where-Object { $_.ServerName -like $ServerFilter }

  Show-ProgressBar -PercentComplete 70 -Status 'Getting Remote Mailboxes' -Stage 1

  $RemoteMailboxes = [array](Get-RemoteMailbox -ResultSize Unlimited)
  $ExchangeEnvironment.Add('RemoteMailboxes', $RemoteMailboxes.Count)

  Show-ProgressBar -PercentComplete 90 -Status 'Getting Databases' -Stage 1

  if ($E2013) {
    # Sorting added
    $Databases = [array](Get-MailboxDatabase -IncludePreExchange2013 -Status) | Sort-Object -Property Name | Where-Object { $_.Server -like $ServerFilter }
  }
  elseif ($E2010) {
    # Sorting added
    $Databases = [array](Get-MailboxDatabase -IncludePreExchange2010 -Status) | Sort-Object -Property Name | Where-Object { $_.Server -like $ServerFilter }
  }

  $DAGs = [array](Get-DatabaseAvailabilityGroup) | Where-Object { $_.Servers -like $ServerFilter }
}
else {
  $ArchiveMailboxes = $null
  $ArchiveMailboxStats = $null
  $DAGs = $null

  Show-ProgressBar -PercentComplete 90 -Status 'Getting Databases' -Stage 1
  $Databases = [array](Get-MailboxDatabase -IncludePreExchange2007 -Status) | Where-Object { $_.Server -like $ServerFilter }
  $ExchangeEnvironment.Add('RemoteMailboxes', 0)
}

# 2.3 Populate Information we know
$ExchangeEnvironment.Add('TotalMailboxes', $Mailboxes.Count + $ExchangeEnvironment.RemoteMailboxes)

# 2.4 Organizational Info

$ExchangeEnvironment.OrganizationName = (Get-OrganizationConfig).Name

# 3 Process High-Level Exchange Information

# 3.1 Collect Exchange Server Information
for ($i = 0; $i -lt $ExchangeServers.Count; $i++) {
  Show-ProgressBar -PercentComplete ($i / $ExchangeServers.Count * 100) -Status 'Getting Exchange Server Information' -Stage 2

  # Get Exchange Info
  $ExSvr = Get-ExchangeServerInformation -E2010 $E2010 -ExchangeServer $ExchangeServers[$i] -Mailboxes $Mailboxes -Databases $Databases -Hybrids $HybridServers

  # Add to site or pre-Exchange 2007 list
  if ($ExSvr.Site) {
    # Exchange 2007 or higher
    if (!$ExchangeEnvironment.Sites[$ExSvr.Site]) {
      $ExchangeEnvironment.Sites.Add($ExSvr.Site, @($ExSvr))
    }
    else {
      $ExchangeEnvironment.Sites[$ExSvr.Site] += $ExSvr
    }
  }
  else {
    # Exchange 2003 or lower
    if (!$ExchangeEnvironment.Pre2007['Pre 2007 Servers']) {
      $ExchangeEnvironment.Pre2007.Add('Pre 2007 Servers', @($ExSvr))
    }
    else {
      $ExchangeEnvironment.Pre2007['Pre 2007 Servers'] += $ExSvr
    }
  }

  # Add to Servers List
  $ExchangeEnvironment.Servers.Add($ExSvr.Name, $ExSvr)
}

# 3.2 Calculate Environment Totals for Version/Role using collected data
Show-ProgressBar -PercentComplete 1 -Status 'Getting Totals' -Stage 3

$ExchangeEnvironment.Add('TotalMailboxesByVersion', (Get-TotalsByVersion -ExchangeEnvironment $ExchangeEnvironment))
$ExchangeEnvironment.Add('TotalServersByRole', (Get-TotalsByRole -ExchangeEnvironment $ExchangeEnvironment))

# 3.4 Populate Environment DAGs
Show-ProgressBar -PercentComplete 5 -Status 'Getting DAG Info' -Stage 3

if ($DAGs) {
  foreach ($DAG in $DAGs) {
    $ExchangeEnvironment.DAGs += (Get-DatabaseAvailabilityGroupInformation -DAG $DAG)
  }
}

# 3.5 Get Database information
Show-ProgressBar -PercentComplete 60 -Status 'Getting Database Info' -Stage 3

for ($i = 0; $i -lt $Databases.Count; $i++) {
  $Database = Get-DatabaseInformation -Database $Databases[$i] -ExchangeEnvironment $ExchangeEnvironment -Mailboxes $Mailboxes -ArchiveMailboxes $ArchiveMailboxes -E2010 $E2010
  $ExchangeEnvironment.AllDatabases += $Database
  $DAGDB = $false
  for ($j = 0; $j -lt $ExchangeEnvironment.DAGs.Count; $j++) {
    if ($ExchangeEnvironment.DAGs[$j].Members -contains $Database.ActiveOwner) {
      $DAGDB = $true
      $ExchangeEnvironment.DAGs[$j].Databases += $Database
    }
  }
  if (!$DAGDB) {
    $ExchangeEnvironment.NonDAGDatabases += $Database
  }
}

# 3.6 Count database copies hosted per server (active + passive) for edition
# mounted-database-limit reporting (Standard 5 / Enterprise 100). Server info
# hashtables are shared by reference with the Sites collection, so updating them
# here updates the per-site view too.
foreach ($ServerEntry in $ExchangeEnvironment.Servers.GetEnumerator()) {
  $ServerName = $ServerEntry.Key
  $HostedCopies = 0
  $ActiveCount = 0
  $PreferredCount = 0
  foreach ($Db in $ExchangeEnvironment.AllDatabases) {
    if ($Db.AllCopyServers -contains $ServerName) { $HostedCopies++ }
    if ($Db.ActiveOwner -eq $ServerName) { $ActiveCount++ }
    if ($Db.PreferredServer -eq $ServerName) { $PreferredCount++ }
  }
  $ServerEntry.Value.HostedDatabaseCopies = $HostedCopies
  $ServerEntry.Value.ActiveDatabaseCount = $ActiveCount
  $ServerEntry.Value.PreferredDatabaseCount = $PreferredCount
}

# 3.7 Certificate inventory (self-signed certificates excluded). Gathered once so both
# the KPI tiles and the certificate section use the same data.
Show-ProgressBar -PercentComplete 90 -Status 'Getting Certificate Information' -Stage 3
$ExchangeEnvironment.Certificates = Get-CertificateInventory -ExchangeServers $ExchangeServers -WarningDays $CertificateWarningDays

# 4 Write Information (modern dashboard layout)
Show-ProgressBar -PercentComplete 5 -Status 'Writing HTML Report' -Stage 4

# 4.1 HTML document head with embedded CSS
$CssPath = Join-Path -Path (Split-Path -Parent $MyInvocation.MyCommand.Path) -ChildPath $CssFileName
$Css = ''
if (Test-Path -Path $CssPath) { $Css = (Get-Content -Path $CssPath -Raw) }

$Output = "<html><head><meta charset=""utf-8""><meta name=""viewport"" content=""width=device-width, initial-scale=1""><title>Exchange Environment Report</title><style type=""text/css"">$Css</style></head><body><div class=""page"">"

# 4.2 Dashboard header + KPI severity tiles + version summary
$Output += Get-HtmlDashboardHeader -ExchangeEnvironment $ExchangeEnvironment

# 4.3 Per-server collapsible cards, grouped by Active Directory site
Show-ProgressBar -PercentComplete 30 -Status 'Writing HTML Server Cards' -Stage 4
$Output += "<h2 class='section'>Servers</h2>"

foreach ($Site in ($ExchangeEnvironment.Sites.GetEnumerator() | Sort-Object -Property Name)) {
  $Output += ("<div class='site-label'>Site: {0}</div>" -f $Site.Key)
  foreach ($Server in $Site.Value) {
    $Output += Get-HtmlServerCard -Server $Server -ExchangeEnvironment $ExchangeEnvironment -ExVersionStrings $ExVersionStrings -ExRoleStrings $ExRoleStrings
  }
}

foreach ($FakeSite in $ExchangeEnvironment.Pre2007.GetEnumerator()) {
  $Output += ("<div class='site-label'>{0}</div>" -f $FakeSite.Key)
  foreach ($Server in $FakeSite.Value) {
    $Output += Get-HtmlServerCard -Server $Server -ExchangeEnvironment $ExchangeEnvironment -ExVersionStrings $ExVersionStrings -ExRoleStrings $ExRoleStrings
  }
}

# 4.4 Database Availability Groups
Show-ProgressBar -PercentComplete 60 -Status 'Writing HTML DAG Information' -Stage 4
$Output += Get-HtmlDagSection -ExchangeEnvironment $ExchangeEnvironment

# 4.5 Active Directory site configuration
Show-ProgressBar -PercentComplete 75 -Status 'Writing HTML Site Configuration' -Stage 4
$Output += Get-HtmlSiteConfiguration -ExchangeEnvironment $ExchangeEnvironment

# 4.6 Accepted domains
Show-ProgressBar -PercentComplete 82 -Status 'Writing HTML Accepted Domains' -Stage 4
$Output += Get-HtmlAcceptedDomains

# 4.7 Exchange certificates (self-signed excluded)
Show-ProgressBar -PercentComplete 88 -Status 'Writing HTML Certificate Information' -Stage 4
$Output += Get-HtmlCertificateSection -Certificates $ExchangeEnvironment.Certificates -WarningDays $CertificateWarningDays

# 4.8 Footer (generation timestamp only - attribution and project links live in the README)
Show-ProgressBar -PercentComplete 90 -Status 'Finishing off..' -Stage 4
$Output += ("<div class='footer'>Report generated {0} by Get-ExchangeEnvironmentReport.ps1 (v2.8).</div>" -f (Get-Date -Format 'yyyy-MM-dd HH:mm'))

$Output += '</div></body></html>'

# Updated to ensure script path as storage location
$HtmlReportFullPath = Join-Path -Path (Split-Path -Path $script:MyInvocation.MyCommand.Path) -ChildPath $HTMLReport

$Output | Out-File -FilePath $HtmlReportFullPath -Force -Encoding utf8


if ($SendMail) {
  Show-ProgressBar -PercentComplete 95 -Status 'Sending mail message..' -Stage 4

  # Changed to .NET send method to work as scheduled job

  $smtpMail = New-Object Net.Mail.SmtpClient($MailServer)

  $smtpMessage = New-Object System.Net.Mail.MailMessage $MailFrom, $MailTo

  if (Test-Path -Path $HtmlReportFullPath) {
    $smtpAttachment = New-Object Net.Mail.Attachment($HtmlReportFullPath, 'text/plain')
    $smtpMessage.Attachments.Add($smtpAttachment)
  }

  $smtpMessage.Subject = 'Exchange Environment Report'
  $smtpMessage.Body = $Output
  $smtpMessage.IsBodyHtml = $true

  $smtpMail.Send($smtpMessage)

  Return 0
}