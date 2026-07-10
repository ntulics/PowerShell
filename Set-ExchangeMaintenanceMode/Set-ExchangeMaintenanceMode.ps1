<#
.SYNOPSIS
    Interactively places an Exchange DAG member into (or takes it out of)
    maintenance mode, including active-database evacuation and redistribution.

.DESCRIPTION
    - Loads the Exchange management shell.
    - Discovers the Exchange servers in the organisation and lets you pick one.
    - Detects whether the chosen server is currently in maintenance mode.
    - ENTER: drains transport, redirects messages, evacuates active databases
      (balance the DAG *or* activate them on a specific server, optionally
      setting the activation preference), suspends the node and takes the
      server offline.
    - EXIT: brings the server back, then offers post-maintenance database
      activation: balance by activation preference, balance by site +
      activation preference, prefer a specific AD site, or activate specific
      databases back on this server.

.PARAMETER WhatIf
    Dry run. Walks the entire flow and shows every change it *would* make
    without altering anything.

.EXAMPLE
    .\Set-ExchangeMaintenanceMode.ps1
    .\Set-ExchangeMaintenanceMode.ps1 -WhatIf

.NOTES
    Run from an elevated Windows PowerShell 5.1 session on a server (or
    management workstation) with the Exchange management tools installed.
    Requires appropriate Exchange RBAC rights.
#>

[CmdletBinding(SupportsShouldProcess)]
param()

# ------------------------------------------------------------------------------
# Action log + graceful exit (so the window never just disappears)
# ------------------------------------------------------------------------------
$script:Steps = @()

function Step {
    param([string]$Message)
    $script:Steps += $Message
    Write-Host " -> $Message"
}

function Pause-BeforeExit {
    param([string]$Reason)

    if ($Reason) { Write-Host "`n$Reason" -ForegroundColor Yellow }

    Write-Host "`n==== Summary of actions ====" -ForegroundColor Cyan
    if ($script:Steps.Count -eq 0) {
        Write-Host "  (no changes were made)"
    }
    else {
        $i = 1
        foreach ($s in $script:Steps) { Write-Host ("  {0}. {1}" -f $i++, $s) }
    }
    if ($WhatIfPreference) {
        Write-Host "`n(WhatIf mode: nothing was actually changed.)" -ForegroundColor Yellow
    }

    Read-Host "`nPress Enter to quit" | Out-Null
}

# ------------------------------------------------------------------------------
# Load the Exchange management snap-in (ignore if already loaded)
# ------------------------------------------------------------------------------
if (-not (Get-PSSnapin -Name Microsoft.Exchange.Management.PowerShell.SnapIn -ErrorAction SilentlyContinue)) {
    try {
        Add-PSSnapin Microsoft.Exchange.Management.PowerShell.SnapIn -ErrorAction Stop
    }
    catch {
        Write-Warning "Could not load the Exchange management snap-in."
        Write-Warning "Run this from Windows PowerShell on a server with the Exchange management tools installed (or from the Exchange Management Shell)."
        Write-Warning "Details: $_"
        Pause-BeforeExit -Reason "Exchange cmdlets are not available, so nothing was done."
        return
    }
}

# ------------------------------------------------------------------------------
# Load the Failover Clustering module (needed for Suspend/Resume-ClusterNode).
# It is not auto-loaded by the Exchange Management Shell.
# ------------------------------------------------------------------------------
Import-Module FailoverClusters -ErrorAction SilentlyContinue
$script:HasClusterCmdlets = [bool](Get-Command Suspend-ClusterNode -ErrorAction SilentlyContinue)
if (-not $script:HasClusterCmdlets) {
    Write-Warning "The FailoverClusters module is not available on this machine, so the cluster node will NOT be paused/resumed automatically."
    Write-Warning "Install the Failover Clustering tools (RSAT-Clustering) or run this on a DAG member. Database moves and component states will still be handled."
}

# ------------------------------------------------------------------------------
# Generic helpers
# ------------------------------------------------------------------------------

function Select-FromList {
    param(
        [Parameter(Mandatory)] [object[]] $Items,
        [Parameter(Mandatory)] [string]   $Prompt,
        [scriptblock] $Display = { param($i) "$i" }
    )

    for ($i = 0; $i -lt $Items.Count; $i++) {
        Write-Host ("  [{0}] {1}" -f ($i + 1), (& $Display $Items[$i]))
    }
    do {
        $choice = Read-Host $Prompt
    } while (-not ($choice -as [int]) -or [int]$choice -lt 1 -or [int]$choice -gt $Items.Count)

    return $Items[[int]$choice - 1]
}

function Read-YesNo {
    param([string]$Prompt, [string]$Default = 'n')
    do {
        $a = Read-Host "$Prompt (y/n, default: $Default)"
        if ([string]::IsNullOrWhiteSpace($a)) { $a = $Default }
    } while ($a -notmatch '^(y|yes|n|no)$')
    return ($a -match '^(y|yes)$')
}

function Get-ServerSite {
    param([string]$Server)
    try { (Get-ExchangeServer -Identity $Server).Site.Name } catch { $null }
}

function Get-ServerFqdn {
    <#
        Redirect-Message requires a fully qualified domain name. DAG member
        objects only expose a short Name, so resolve the FQDN from AD.
    #>
    param([string]$Server)
    try {
        $fqdn = (Get-ExchangeServer -Identity $Server -ErrorAction Stop).Fqdn
        if ($fqdn) { $fqdn } else { $Server }
    }
    catch { $Server }
}

function Test-ServerInMaintenance {
    <#
        True if the server is offline for maintenance or otherwise unable to
        host active database copies (so it is not a valid redirect/move target).
    #>
    param([string]$Server)
    try {
        $swo = (Get-ServerComponentState -Identity $Server -Component ServerWideOffline).State
        $mbx = Get-MailboxServer -Identity $Server -ErrorAction Stop
        return ($swo -eq 'Inactive') -or
               ($mbx.DatabaseCopyAutoActivationPolicy -eq 'Blocked') -or
               ($mbx.DatabaseCopyActivationDisabledAndMoveNow -eq $true)
    }
    catch { return $false }
}

function Restart-TransportServices {
    param([string]$Server)
    if ($WhatIfPreference) {
        Step "WHATIF: would restart transport services on '$Server'"
        return
    }
    Step "Restarting transport services on '$Server'..."
    Invoke-Command -ComputerName $Server -ScriptBlock {
        Restart-Service MSExchangeTransport -ErrorAction SilentlyContinue
        Restart-Service MSExchangeFrontEndTransport -ErrorAction SilentlyContinue
    } -ErrorAction SilentlyContinue
}

function Suspend-DagNode {
    param([string]$Server, [string]$DagName)
    if (-not $script:HasClusterCmdlets) {
        Step "SKIPPED suspending cluster node '$Server' (FailoverClusters module not available)"
        return
    }
    if ($WhatIfPreference) { Step "WHATIF: would suspend cluster node '$Server'"; return }
    Step "Suspending the cluster node '$Server'..."
    try {
        if ($DagName) { Suspend-ClusterNode -Name $Server -Cluster $DagName -ErrorAction Stop | Out-Null }
        else          { Suspend-ClusterNode -Name $Server -ErrorAction Stop | Out-Null }
    }
    catch { Write-Warning "Suspend-ClusterNode failed for '$Server': $_" }
}

function Resume-DagNode {
    param([string]$Server, [string]$DagName)
    if (-not $script:HasClusterCmdlets) {
        Step "SKIPPED resuming cluster node '$Server' (FailoverClusters module not available)"
        return
    }
    if ($WhatIfPreference) { Step "WHATIF: would resume cluster node '$Server'"; return }
    Step "Resuming the cluster node '$Server'..."
    try {
        if ($DagName) { Resume-ClusterNode -Name $Server -Cluster $DagName -ErrorAction Stop | Out-Null }
        else          { Resume-ClusterNode -Name $Server -ErrorAction Stop | Out-Null }
    }
    catch { Write-Warning "Resume-ClusterNode failed for '$Server': $_" }
}

# ------------------------------------------------------------------------------
# State detection
# ------------------------------------------------------------------------------

function Test-MaintenanceMode {
    param([string]$Server)

    $swo = (Get-ServerComponentState -Identity $Server -Component ServerWideOffline).State
    $hub = (Get-ServerComponentState -Identity $Server -Component HubTransport).State
    $mbx = Get-MailboxServer -Identity $Server

    [pscustomobject]@{
        Server                                   = $Server
        Site                                     = Get-ServerSite -Server $Server
        DAG                                      = $mbx.DatabaseAvailabilityGroup
        ServerWideOffline                        = $swo
        HubTransport                             = $hub
        DatabaseCopyAutoActivationPolicy         = $mbx.DatabaseCopyAutoActivationPolicy
        DatabaseCopyActivationDisabledAndMoveNow = $mbx.DatabaseCopyActivationDisabledAndMoveNow
        InMaintenance                            = ($swo -eq 'Inactive')
    }
}

function Get-ActiveDatabasesOnServer {
    param([string]$Server)
    Get-MailboxDatabaseCopyStatus -Server $Server |
        Where-Object { $_.ActiveCopy -eq $true -or $_.Status -eq 'Mounted' }
}

# ------------------------------------------------------------------------------
# Activation-preference helpers
# ------------------------------------------------------------------------------

function Set-ServerActivationPreferred {
    param([string]$Server)

    Step "Setting ActivationPreference = 1 for all copies on '$Server'..."
    Get-MailboxDatabaseCopyStatus -Server $Server | ForEach-Object {
        $copyId = "{0}\{1}" -f $_.DatabaseName, $Server
        try {
            Set-MailboxDatabaseCopy -Identity $copyId -ActivationPreference 1 -Confirm:$false -ErrorAction Stop
            Write-Host ("    set {0} -> pref 1" -f $copyId)
        }
        catch { Write-Warning "    could not set preference on $copyId : $_" }
    }
}

function Set-SiteActivationPreferred {
    param([string]$DagName, [string]$Site)

    Step "Preferring site '$Site' (ActivationPreference 1 for its copies)..."
    $dbs = Get-MailboxDatabase | Where-Object {
        $_.MasterServerOrAvailabilityGroup -and $_.MasterServerOrAvailabilityGroup.Name -eq $DagName
    }

    foreach ($db in $dbs) {
        $copyInSite = $db.Servers | Where-Object { (Get-ServerSite $_.Name) -eq $Site } | Select-Object -First 1
        if ($copyInSite) {
            $copyId = "{0}\{1}" -f $db.Name, $copyInSite.Name
            try {
                Set-MailboxDatabaseCopy -Identity $copyId -ActivationPreference 1 -Confirm:$false -ErrorAction Stop
                Write-Host ("    {0} -> pref 1" -f $copyId)
            }
            catch { Write-Warning "    could not set preference on $copyId : $_" }
        }
    }
}

# ------------------------------------------------------------------------------
# Evacuation (ENTER) and redistribution (EXIT)
# ------------------------------------------------------------------------------

function Move-DatabasesOffServer {
    param(
        [Parameter(Mandatory)] [string] $Server,
        [ValidateSet('Balance', 'Target')] [string] $Mode = 'Balance',
        [string] $TargetServer
    )

    $active = Get-ActiveDatabasesOnServer -Server $Server
    if (-not $active) {
        Step "No active databases on '$Server' to move."
        return
    }

    foreach ($copy in $active) {
        $db = $copy.DatabaseName
        try {
            if ($Mode -eq 'Target') {
                Step "Moving '$db' to '$TargetServer'..."
                Move-ActiveMailboxDatabase -Identity $db -ActivateOnServer $TargetServer `
                    -SkipClientExperienceChecks -Confirm:$false -ErrorAction Stop
            }
            else {
                Step "Moving '$db' to its best available copy..."
                Move-ActiveMailboxDatabase -Identity $db `
                    -SkipClientExperienceChecks -Confirm:$false -ErrorAction Stop
            }
        }
        catch { Write-Warning "    failed to move $db : $_" }
    }
}

function Invoke-RedistributeActiveDatabases {
    param(
        [Parameter(Mandatory)] [string] $DagName,
        [ValidateSet('Preference', 'SiteAndPreference')] [string] $Mode = 'Preference'
    )

    if ($WhatIfPreference) {
        Step "WHATIF: would run RedistributeActiveDatabases.ps1 for DAG '$DagName' ($Mode)"
        return
    }

    $script = Join-Path $env:ExchangeInstallPath 'Scripts\RedistributeActiveDatabases.ps1'
    if (-not (Test-Path $script)) {
        Write-Warning "RedistributeActiveDatabases.ps1 not found at $script. Skipping automatic redistribution."
        return
    }

    Step "Running RedistributeActiveDatabases.ps1 for DAG '$DagName' ($Mode)..."
    if ($Mode -eq 'SiteAndPreference') {
        & $script -DagName $DagName -BalanceDbsBySiteAndActivationPreference `
            -ShowFinalDatabaseDistribution -Confirm:$false
    }
    else {
        & $script -DagName $DagName -BalanceDbsByActivationPreference `
            -ShowFinalDatabaseDistribution -Confirm:$false
    }
}

# ------------------------------------------------------------------------------
# ENTER maintenance
# ------------------------------------------------------------------------------

function Enter-MaintenanceMode {
    param(
        [Parameter(Mandatory)] [string] $Server,
        [Parameter(Mandatory)] [string] $RedirectTarget,
        [object[]] $DagPeers,
        [string] $DagName
    )

    Write-Host "`nPutting '$Server' INTO maintenance mode..." -ForegroundColor Yellow

    Step "Draining HubTransport on '$Server'..."
    Set-ServerComponentState -Identity $Server -Component HubTransport -State Draining -Requester Maintenance

    Restart-TransportServices -Server $Server

    Step "Redirecting queued messages to '$RedirectTarget'..."
    Redirect-Message -Server $Server -Target $RedirectTarget -Confirm:$false

    # --- Active-database evacuation -------------------------------------------
    Write-Host "`nHow should active databases be moved off '$Server'?"
    $evacChoice = Select-FromList `
        -Items @('Balance the DAG (best copy per database, by activation preference)',
                 'Activate all databases on a specific server') `
        -Prompt "Choose an evacuation method"

    if ($evacChoice -like 'Activate all*') {
        $target = Select-FromList -Items $DagPeers -Prompt "Select the target server" -Display { param($s) $s.Name }
        Move-DatabasesOffServer -Server $Server -Mode Target -TargetServer $target.Name
        if (Read-YesNo "Set ActivationPreference = 1 for those copies on '$($target.Name)'?" 'n') {
            Set-ServerActivationPreferred -Server $target.Name
        }
    }
    else {
        Move-DatabasesOffServer -Server $Server -Mode Balance
    }

    Suspend-DagNode -Server $Server -DagName $DagName

    Step "Disabling database copy activation and moving any remaining active databases off '$Server'..."
    Set-MailboxServer -Identity $Server -DatabaseCopyActivationDisabledAndMoveNow $true

    Write-Host " -> Current auto-activation policy:"
    Get-MailboxServer -Identity $Server | Select-Object -ExpandProperty DatabaseCopyAutoActivationPolicy

    Step "Blocking database copy auto-activation on '$Server'..."
    Set-MailboxServer -Identity $Server -DatabaseCopyAutoActivationPolicy Blocked

    Write-Host " -> Databases still mounted on '$Server' (should be none):"
    Get-MailboxDatabaseCopyStatus -Server $Server |
        Where-Object { $_.Status -eq 'Mounted' } | Format-Table -AutoSize

    Step "Taking '$Server' offline (ServerWideOffline = Inactive)..."
    Set-ServerComponentState -Identity $Server -Component ServerWideOffline -State Inactive -Requester Maintenance

    Write-Host "`n'$Server' is now in maintenance mode." -ForegroundColor Green
}

# ------------------------------------------------------------------------------
# EXIT maintenance
# ------------------------------------------------------------------------------

function Exit-MaintenanceMode {
    param(
        [Parameter(Mandatory)] [string] $Server,
        [string] $DagName
    )

    Write-Host "`nTaking '$Server' OUT of maintenance mode..." -ForegroundColor Yellow

    Step "Bringing '$Server' online (ServerWideOffline = Active)..."
    Set-ServerComponentState -Identity $Server -Component ServerWideOffline -State Active -Requester Maintenance

    Resume-DagNode -Server $Server -DagName $DagName

    Step "Re-enabling database copy activation on '$Server'..."
    Set-MailboxServer -Identity $Server -DatabaseCopyActivationDisabledAndMoveNow $false

    Step "Restoring database copy auto-activation policy (Unrestricted) on '$Server'..."
    Set-MailboxServer -Identity $Server -DatabaseCopyAutoActivationPolicy Unrestricted

    Step "Re-activating HubTransport on '$Server'..."
    Set-ServerComponentState -Identity $Server -Component HubTransport -State Active -Requester Maintenance

    Restart-TransportServices -Server $Server

    # --- Post-maintenance database activation ---------------------------------
    Write-Host "`nPost-maintenance database activation:"
    $opt = Select-FromList `
        -Items @('Balance DAG by activation preference',
                 'Balance DAG by site AND activation preference',
                 'Prefer a specific AD site, then balance',
                 'Activate specific databases back on this server',
                 'Skip (leave databases where they are)') `
        -Prompt "Choose an activation option"

    switch -Wildcard ($opt) {
        'Balance DAG by activation preference' {
            Invoke-RedistributeActiveDatabases -DagName $DagName -Mode Preference
        }
        'Balance DAG by site*' {
            Invoke-RedistributeActiveDatabases -DagName $DagName -Mode SiteAndPreference
        }
        'Prefer a specific AD site*' {
            $sites = Get-DatabaseAvailabilityGroup $DagName |
                Select-Object -ExpandProperty Servers |
                ForEach-Object { Get-ServerSite $_.Name } |
                Sort-Object -Unique
            $site = Select-FromList -Items $sites -Prompt "Select the preferred site"
            Set-SiteActivationPreferred -DagName $DagName -Site $site
            Invoke-RedistributeActiveDatabases -DagName $DagName -Mode Preference
        }
        'Activate specific databases back*' {
            $copies = Get-MailboxDatabaseCopyStatus -Server $Server |
                Where-Object { $_.Status -ne 'Mounted' }
            if (-not $copies) { Write-Host "No inactive copies found on '$Server'."; break }
            Write-Host "Databases with a copy on '$Server' (not currently active):"
            $copies | ForEach-Object { Write-Host "  - $($_.DatabaseName)" }
            if (Read-YesNo "Activate ALL of these on '$Server'?" 'n') {
                foreach ($c in $copies) {
                    try {
                        Step "Activating '$($c.DatabaseName)' on '$Server'..."
                        Move-ActiveMailboxDatabase -Identity $c.DatabaseName -ActivateOnServer $Server `
                            -SkipClientExperienceChecks -Confirm:$false -ErrorAction Stop
                    }
                    catch { Write-Warning "  failed to activate $($c.DatabaseName): $_" }
                }
                if (Read-YesNo "Set ActivationPreference = 1 for these copies on '$Server'?" 'n') {
                    Set-ServerActivationPreferred -Server $Server
                }
            }
        }
        default { Step "Skipping redistribution." }
    }

    Write-Host "`n'$Server' is back in production." -ForegroundColor Green
}

# ------------------------------------------------------------------------------
# Main
# ------------------------------------------------------------------------------

if ($WhatIfPreference) {
    Write-Host "*** WhatIf mode: this is a DRY RUN. No changes will be made. ***`n" -ForegroundColor Magenta
}

Write-Host "Discovering Exchange servers..." -ForegroundColor Cyan
$servers = Get-ExchangeServer | Sort-Object Name
if (-not $servers) { Pause-BeforeExit -Reason "No Exchange servers found."; return }

Write-Host "`nSelect the server you want to work with:"
$selected = Select-FromList -Items $servers -Prompt "Enter the number of the server" -Display {
    param($s) "{0}  (Site: {1}; Roles: {2})" -f $s.Name, (Get-ServerSite $s.Name), $s.ServerRole
}
$serverName = $selected.Name

$state = Test-MaintenanceMode -Server $serverName
Write-Host "`nCurrent state of '$serverName':" -ForegroundColor Cyan
$state | Format-List

$dagName  = $state.DAG
$dagPeers = if ($dagName) {
    Get-DatabaseAvailabilityGroup $dagName |
        Select-Object -ExpandProperty Servers |
        Where-Object { $_.Name -ne $serverName }
} else { $servers | Where-Object { $_.Name -ne $serverName } }

# Exclude peers that are themselves in maintenance mode - they cannot host
# active copies or accept redirected mail, so they are invalid targets.
Write-Host "`nChecking peer server availability..." -ForegroundColor Cyan
$peersInMaintenance = @($dagPeers | Where-Object { Test-ServerInMaintenance $_.Name })
$availablePeers     = @($dagPeers | Where-Object { -not (Test-ServerInMaintenance $_.Name) })
if ($peersInMaintenance.Count -gt 0) {
    Write-Host "The following peers are IN maintenance mode and will be excluded as targets:" -ForegroundColor Yellow
    $peersInMaintenance | ForEach-Object { Write-Host "  - $($_.Name)" -ForegroundColor Yellow }
}

# Decide direction, defaulting to the opposite of the current state
if ($state.InMaintenance) {
    Write-Host "'$serverName' appears to be IN maintenance mode." -ForegroundColor Yellow
    $default = 'out'
}
else {
    Write-Host "'$serverName' appears to be in PRODUCTION (not in maintenance mode)." -ForegroundColor Yellow
    $default = 'in'
}

do {
    $answer = Read-Host "Do you want to put it [in] or take it [out] of maintenance mode? (default: $default)"
    if ([string]::IsNullOrWhiteSpace($answer)) { $answer = $default }
    $answer = $answer.Trim().ToLower()
} while ($answer -notin @('in', 'out'))

if ($answer -eq 'in') {
    if ($state.InMaintenance) {
        Pause-BeforeExit -Reason "'$serverName' is already in maintenance mode. Nothing to do."; return
    }
    if (-not $availablePeers -or $availablePeers.Count -eq 0) {
        Pause-BeforeExit -Reason "No healthy peer server available to redirect/evacuate to (all peers are in maintenance mode)."; return
    }

    Write-Host "`nSelect the server to redirect queued messages to:"
    $target = Select-FromList -Items $availablePeers -Prompt "Enter the number of the target server" -Display {
        param($s) Get-ServerFqdn $s.Name
    }
    # Redirect-Message requires an FQDN; resolve it from AD regardless of source.
    $targetName = Get-ServerFqdn $target.Name

    if (-not (Read-YesNo "Put '$serverName' INTO maintenance mode (redirect to '$targetName')?" 'n')) {
        Pause-BeforeExit -Reason "Aborted."; return
    }
    Enter-MaintenanceMode -Server $serverName -RedirectTarget $targetName -DagPeers $availablePeers -DagName $dagName
}
else {
    if (-not $state.InMaintenance) {
        Pause-BeforeExit -Reason "'$serverName' is not in maintenance mode. Nothing to do."; return
    }
    if (-not (Read-YesNo "Take '$serverName' OUT of maintenance mode?" 'n')) {
        Pause-BeforeExit -Reason "Aborted."; return
    }
    Exit-MaintenanceMode -Server $serverName -DagName $dagName
}

Write-Host "`nFinal state of '$serverName':" -ForegroundColor Cyan
Test-MaintenanceMode -Server $serverName | Format-List

Pause-BeforeExit
