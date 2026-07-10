<#
.SYNOPSIS
    Safely purges old IIS and Exchange log files to reclaim disk space on an
    Exchange Server 2019 machine.

.DESCRIPTION
    Exchange runs on IIS and neither IIS nor several Exchange components purge
    their own logs, so the system drive fills up over time. This script deletes
    *.log / *.blg / *.etl files older than a retention window from the well-known
    log locations, while leaving the folder structure and any currently open
    (locked) log intact.

    Runs in preview mode by default. Nothing is deleted until you pass -Execute.

.PARAMETER RetentionDays
    Age threshold in days. Files whose LastWriteTime is older than this are
    removed. Default: 14.

.PARAMETER Execute
    Actually delete files. Without this switch the script only reports what it
    WOULD delete (safe dry-run).

.PARAMETER Paths
    Override the default set of log directories to clean.

.PARAMETER LogFile
    Path to the script's own run log.
    Default: <SystemDrive>\LogCleanup\Clear-ExchangeLogs.log

.EXAMPLE
    .\Clear-ExchangeLogs.ps1
    Dry run. Shows how much space would be freed and how many files match.

.EXAMPLE
    .\Clear-ExchangeLogs.ps1 -RetentionDays 7 -Execute
    Deletes matching logs older than 7 days.

.NOTES
    Run as Administrator. Test with a dry run first. Deleting IIS/Exchange logs
    does not affect mail flow or databases. The active log file stays locked and
    is skipped automatically.
#>

[CmdletBinding()]
param(
    [int]    $RetentionDays = 14,
    [switch] $Execute,
    [string[]] $Paths,
    [string] $LogFile = "$env:SystemDrive\LogCleanup\Clear-ExchangeLogs.log"
)

# --- Resolve which directories to clean ------------------------------------

if (-not $Paths) {
    # Default log locations. The Exchange install path is read from the registry
    # so this works regardless of which drive Exchange was installed on.
    $exchangeRoot = $null
    try {
        $exchangeRoot = (Get-ItemProperty `
            'HKLM:\SOFTWARE\Microsoft\ExchangeServer\v15\Setup' `
            -ErrorAction Stop).MsiInstallPath
    } catch {
        # Not an Exchange box, or key missing - IIS-only cleanup still applies.
    }

    # IIS access-log directory: read the configured location from IIS if we can,
    # otherwise fall back to the standard default on the system drive. This keeps
    # the script zero-touch even when IIS logs were moved off the default path.
    $iisLogDir = $null
    try {
        Import-Module WebAdministration -ErrorAction Stop
        $iisLogDir = (Get-WebConfigurationProperty `
            -Filter 'system.applicationHost/sites/siteDefaults/logFile' `
            -Name directory -ErrorAction Stop).Value
        if ($iisLogDir) { $iisLogDir = [Environment]::ExpandEnvironmentVariables($iisLogDir) }
    } catch {
        # IIS module not present or query failed - use the default below.
    }
    if (-not $iisLogDir) { $iisLogDir = "$env:SystemDrive\inetpub\logs\LogFiles" }

    $Paths = @(
        $iisLogDir                                       # IIS access logs
        "$env:SystemRoot\System32\LogFiles\HTTPERR"      # HTTP.sys error logs
    )

    if ($exchangeRoot) {
        $Paths += @(
            (Join-Path $exchangeRoot 'Logging')          # Exchange diagnostic logs
            (Join-Path $exchangeRoot 'TransportRoles\Logs')
            (Join-Path $exchangeRoot 'Bin\Search\Ceres\Diagnostics\Logs')
        )
    }
}

# --- Logging helper ---------------------------------------------------------

$logDir = Split-Path -Path $LogFile -Parent
if ($logDir -and -not (Test-Path $logDir)) {
    New-Item -ItemType Directory -Path $logDir -Force | Out-Null
}

function Write-Log {
    param([string] $Message, [string] $Level = 'INFO')
    $line = "{0}  [{1}]  {2}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    Write-Host $line
    Add-Content -Path $LogFile -Value $line -ErrorAction SilentlyContinue
}

# --- Main -------------------------------------------------------------------

$mode    = if ($Execute) { 'EXECUTE (deleting)' } else { 'DRY RUN (no changes)' }
$cutoff  = (Get-Date).AddDays(-$RetentionDays)
$extensions = @('*.log', '*.blg', '*.etl')

Write-Log "===== Log cleanup started - Mode: $mode ====="
Write-Log "Retention: $RetentionDays days (removing files older than $($cutoff.ToString('yyyy-MM-dd HH:mm')))"

$totalFiles = 0
$totalBytes = 0
$lockedFiles = 0

foreach ($path in $Paths) {
    if (-not (Test-Path $path)) {
        Write-Log "Skipping (not found): $path" 'WARN'
        continue
    }

    Write-Log "Scanning: $path"

    $candidates = Get-ChildItem -Path $path -Recurse -File -Include $extensions -ErrorAction SilentlyContinue |
                  Where-Object { $_.LastWriteTime -lt $cutoff }

    foreach ($file in $candidates) {
        $sizeMB = [math]::Round($file.Length / 1MB, 2)

        if ($Execute) {
            try {
                Remove-Item -Path $file.FullName -Force -ErrorAction Stop
                $totalFiles++
                $totalBytes += $file.Length
                Write-Verbose "Deleted: $($file.FullName) ($sizeMB MB)"
            } catch {
                # Almost always the currently open log, which is locked. Expected.
                $lockedFiles++
                Write-Verbose "Locked/in-use, skipped: $($file.FullName)"
            }
        } else {
            $totalFiles++
            $totalBytes += $file.Length
            Write-Verbose "Would delete: $($file.FullName) ($sizeMB MB)"
        }
    }
}

$totalGB = [math]::Round($totalBytes / 1GB, 3)
$verb    = if ($Execute) { 'Deleted' } else { 'Would delete' }

Write-Log "$verb $totalFiles file(s), reclaiming $totalGB GB."
if ($lockedFiles -gt 0) {
    Write-Log "$lockedFiles file(s) were in use and skipped (normal - active logs)." 'WARN'
}
if (-not $Execute) {
    Write-Log "This was a DRY RUN. Re-run with -Execute to actually delete." 'WARN'
}
Write-Log "===== Log cleanup finished ====="
