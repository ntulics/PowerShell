<#
.SYNOPSIS
    Pre-flight readiness check for Exchange Server 2019 setup / PrepareAD.

.DESCRIPTION
    Read-only diagnostic. Reproduces the checks that Exchange setup's prereq
    analysis makes and the surrounding conditions that commonly break it, so you
    can clear them BEFORE running Setup.exe again.

    Targets the two failures Exchange setup commonly reports during PrepareAD:
      * RebootPending   - a pending reboot blocks all AD prep.
      * AdUpdateRequired - "no permission even though member of Enterprise Admins",
                           usually a stale security token (groups added but never
                           logged off) or a non-elevated / non-replicated session.

    Zero-touch: the install drive, Exchange organization name, domain and forest
    are all discovered from the environment at runtime. Nothing is hardcoded, so
    it runs unmodified in any Exchange 2019 forest.

    Nothing here writes to AD, the registry, or the server. Safe to run anytime.

.NOTES
    Run in an ELEVATED Windows PowerShell (Run as administrator) on the Exchange
    box, signed in as the account you'll use for Setup.
    The CU target versions are auto-selected from the locally installed Exchange
    build. If the build isn't recognised, the newest known CU is used and a note
    is shown; you can also pass -TargetSchema/-TargetOrg/-TargetDomain to override.
#>

[CmdletBinding()]
param(
    # Drive where Exchange is installed. Auto-discovered from the Exchange
    # install path when omitted.
    [string]$InstallDrive,
    # Exchange organization name. Auto-discovered from Active Directory when omitted.
    [string]$OrganizationName,
    # Groups the account must hold for PrepareAD (Org Management included by default).
    [string[]]$RequiredGroups = @('Schema Admins','Enterprise Admins','Organization Management'),
    # Optional overrides for the AD version targets (else auto-selected from build).
    [int]$TargetSchema,
    [int]$TargetOrg,
    [int]$TargetDomain
)

# ---- Known Exchange 2019 AD version targets, keyed by build (rangeUpper/org/domain).
#      Used to auto-select the right targets from the installed build.  The newest
#      entry is the fallback when the exact build isn't listed.
$Exchange2019Targets = @(
    [pscustomobject]@{ Name='CU8';  Build='15.2.792';  Schema=17003; Org=16759; Domain=13239 }
    [pscustomobject]@{ Name='CU9';  Build='15.2.858';  Schema=17003; Org=16759; Domain=13239 }
    [pscustomobject]@{ Name='CU10'; Build='15.2.922';  Schema=17003; Org=16760; Domain=13240 }
    [pscustomobject]@{ Name='CU11'; Build='15.2.986';  Schema=17003; Org=16761; Domain=13241 }
    [pscustomobject]@{ Name='CU12'; Build='15.2.1118'; Schema=17003; Org=16761; Domain=13242 }
    [pscustomobject]@{ Name='CU13'; Build='15.2.1258'; Schema=17004; Org=16762; Domain=13243 }
    [pscustomobject]@{ Name='CU14'; Build='15.2.1544'; Schema=17004; Org=16762; Domain=13243 }
    [pscustomobject]@{ Name='CU15'; Build='15.2.1748'; Schema=17004; Org=16763; Domain=13244 }
)

# ---- output helpers ----------------------------------------------------------
$script:Results = New-Object System.Collections.Generic.List[object]
function Add-Result {
    param([string]$Area,[ValidateSet('PASS','WARN','FAIL','INFO')]$Status,[string]$Message)
    $script:Results.Add([pscustomobject]@{ Area=$Area; Status=$Status; Message=$Message })
    $color = switch ($Status) { 'PASS'{'Green'} 'WARN'{'Yellow'} 'FAIL'{'Red'} default{'Gray'} }
    Write-Host ('  [{0,-4}] ' -f $Status) -ForegroundColor $color -NoNewline
    Write-Host ("{0,-22} {1}" -f $Area, $Message)
}
function Section($t){ Write-Host "`n=== $t ===" -ForegroundColor Cyan }
function Compare-Ver {
    param([string]$Area,[int]$Actual,[int]$Target)
    if ($Actual -ge $Target) { Add-Result $Area 'PASS' "objectVersion/rangeUpper = $Actual (target $Target for $($Cu.Name)) - up to date." }
    else { Add-Result $Area 'WARN' "objectVersion/rangeUpper = $Actual is BELOW target $Target -> PrepareAD/PrepareDomain still required." }
}

# =============================================================================
# Auto-discovery - pick everything up from the environment (nothing hardcoded)
# =============================================================================
$exSetupKey    = 'HKLM:\SOFTWARE\Microsoft\ExchangeServer\v15\Setup'
$exInstallPath = (Get-ItemProperty $exSetupKey -Name MsiInstallPath -EA SilentlyContinue).MsiInstallPath
if (-not $exInstallPath) { $exInstallPath = $env:ExchangeInstallPath }
if (-not $InstallDrive) {
    if ($exInstallPath) { $InstallDrive = Split-Path -Qualifier $exInstallPath }
    else                { $InstallDrive = $env:SystemDrive }
}

# Locally installed Exchange build (e.g. 15.2.792)
$exBuild = $null
$v = Get-ItemProperty $exSetupKey -EA SilentlyContinue
if ($v -and $null -ne $v.MsiProductMajor) {
    $exBuild = '{0}.{1}.{2}' -f $v.MsiProductMajor, $v.MsiProductMinor, $v.MsiBuildMajor
}

# Select AD version targets from the installed build (fallback: newest known)
$sel = $null
if ($exBuild) { $sel = $Exchange2019Targets | Where-Object { $_.Build -eq $exBuild } | Select-Object -First 1 }
$fallbackTargets = $false
if (-not $sel) { $sel = $Exchange2019Targets[-1]; $fallbackTargets = $true }
$Cu = [ordered]@{
    Name          = "Exchange 2019 $($sel.Name)"
    SchemaRange   = if ($TargetSchema) { $TargetSchema } else { $sel.Schema }
    OrgVersion    = if ($TargetOrg)    { $TargetOrg }    else { $sel.Org }
    DomainVersion = if ($TargetDomain) { $TargetDomain } else { $sel.Domain }
}

# Exchange organization name from AD (module-free via ADSI)
if (-not $OrganizationName) {
    try {
        $configNC  = ([ADSI]'LDAP://RootDSE').configurationNamingContext
        $exOrgRoot = [ADSI]("LDAP://CN=Microsoft Exchange,CN=Services,$configNC")
        foreach ($child in $exOrgRoot.Children) {
            if ($child.objectClass -contains 'msExchOrganizationContainer') { $OrganizationName = "$($child.cn)"; break }
        }
    } catch {}
}

Write-Host "Exchange Setup / PrepareAD pre-flight  ($($Cu.Name))" -ForegroundColor White
Write-Host ("Host: {0}   User: {1}   {2}" -f $env:COMPUTERNAME, "$env:USERDOMAIN\$env:USERNAME", (Get-Date))
Write-Host ("Discovered: InstallDrive={0}  Org={1}  Build={2}" -f `
    $InstallDrive, $(if ($OrganizationName) { $OrganizationName } else { '<not found>' }), $(if ($exBuild) { $exBuild } else { '<not installed>' })) -ForegroundColor DarkGray
if ($fallbackTargets -and $exBuild) {
    Write-Host "  (build $exBuild not in the target table; using newest known targets [$($sel.Name)]. Override with -TargetSchema/-TargetOrg/-TargetDomain if needed.)" -ForegroundColor DarkYellow
}

# =============================================================================
# 1. Elevation
# =============================================================================
Section '1. Elevation'
$id = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($id)
$elevated = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if ($elevated) { Add-Result 'Elevation' 'PASS' 'PowerShell is running elevated (Run as administrator).' }
else { Add-Result 'Elevation' 'FAIL' 'NOT elevated. Setup''s AD checks misfire when not elevated. Re-launch as administrator.' }

# =============================================================================
# 2. Pending reboot  (the RebootPending rule)
# =============================================================================
Section '2. Pending reboot'
$reasons = @()
if (Get-Item 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending' -EA SilentlyContinue) { $reasons += 'Component Based Servicing (CBS)' }
if (Get-Item 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired' -EA SilentlyContinue) { $reasons += 'Windows Update' }
$pfro = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -Name PendingFileRenameOperations -EA SilentlyContinue).PendingFileRenameOperations
if ($pfro) { $reasons += "PendingFileRenameOperations ($($pfro.Count) entr$(if($pfro.Count -eq 1){'y'}else{'ies'}))" }
$cv = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ActiveComputerName' -EA SilentlyContinue
$cvp = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ComputerName' -EA SilentlyContinue
if ($cv -and $cvp -and ($cv.ComputerName -ne $cvp.ComputerName)) { $reasons += "Pending computer rename ($($cv.ComputerName) -> $($cvp.ComputerName))" }
if (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\ServerManager\CurrentRebootAttempts' -EA SilentlyContinue) { $reasons += 'Server Manager reboot attempts' }
if (Get-ChildItem 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce' -EA SilentlyContinue) { $reasons += 'RunOnce entries (informational)' }
# SCCM client, if present
try {
    $ccm = Invoke-CimMethod -Namespace 'root\ccm\ClientSDK' -ClassName 'CCM_ClientUtilities' -MethodName 'DetermineIfRebootPending' -EA Stop
    if ($ccm.RebootPending -or $ccm.IsHardRebootPending) { $reasons += 'SCCM/ConfigMgr client reboot pending' }
} catch {}

if ($reasons.Count -eq 0) {
    Add-Result 'PendingReboot' 'PASS' 'No pending reboot detected. This clears the RebootPending rule.'
} else {
    Add-Result 'PendingReboot' 'FAIL' ("Pending reboot from: {0}. REBOOT before running Setup." -f ($reasons -join '; '))
    if ($pfro) { Write-Host "        PendingFileRenameOperations entries:" -ForegroundColor DarkYellow; $pfro | Where-Object {$_} | ForEach-Object { Write-Host "          $_" -ForegroundColor DarkGray } }
}

# =============================================================================
# 3. Account: token groups vs actual AD groups  (the AdUpdateRequired rule)
# =============================================================================
Section '3. Account rights (token vs AD)'

# 3a. What the CURRENT SESSION token actually carries (what Setup sees)
$tokenGroups = $id.Groups | ForEach-Object {
    try { $_.Translate([Security.Principal.NTAccount]).Value } catch { $_.Value }
}
# well-known privileged RIDs
$wellKnown = @{ 'Domain Admins'='512'; 'Schema Admins'='518'; 'Enterprise Admins'='519' }
foreach ($g in $wellKnown.Keys) {
    $inToken = $tokenGroups -match [regex]::Escape($g)
    if ($inToken) { Add-Result "Token:$g" 'PASS' 'Present in current session token.' }
    else          { Add-Result "Token:$g" 'INFO' 'Not in token (may be fine if not required, but note for PrepareAD).' }
}

# 3b. What AD says the account is a member of (recursive), to catch stale token
$adModule = $false
try { Import-Module ActiveDirectory -EA Stop; $adModule = $true } catch {
    Add-Result 'AD module' 'WARN' 'ActiveDirectory PowerShell module not available; skipping AD-vs-token comparison. (Install RSAT-AD-PowerShell.)'
}

if ($adModule) {
    try {
        $me = Get-ADUser $env:USERNAME -Properties memberOf -EA Stop
        # recursive group membership by SID
        $myGroups = (Get-ADPrincipalGroupMembership $me -EA Stop | Select-Object -Expand Name)
        # add nested via tokenGroups attribute for accuracy
        foreach ($grpName in $RequiredGroups) {
            $inAD    = $myGroups -contains $grpName
            $inToken = ($tokenGroups -match [regex]::Escape($grpName)) -ne $null -and ($tokenGroups -match [regex]::Escape($grpName)).Count -gt 0
            if ($inAD -and $inToken)      { Add-Result "Grp:$grpName" 'PASS' 'Member in AD and present in current token.' }
            elseif ($inAD -and -not $inToken) { Add-Result "Grp:$grpName" 'FAIL' 'Member in AD but MISSING from current token -> LOG OFF/REBOOT to refresh, then rerun Setup. (This is the classic AdUpdateRequired cause.)' }
            elseif (-not $inAD)           { Add-Result "Grp:$grpName" 'WARN' 'NOT a member in AD. Add the account, then log off/reboot.' }
        }
    } catch {
        Add-Result 'AD lookup' 'WARN' ("Could not resolve account groups in AD: {0}" -f $_.Exception.Message)
    }
}

# =============================================================================
# 4. FSMO / Schema Master reachability
# =============================================================================
Section '4. FSMO and Schema Master'
if ($adModule) {
    try {
        $forest = Get-ADForest
        $domain = Get-ADDomain
        $schemaMaster = $forest.SchemaMaster
        Add-Result 'SchemaMaster' 'INFO' "Schema Master: $schemaMaster"
        Add-Result 'InfraMaster'  'INFO' "Infrastructure Master: $($domain.InfrastructureMaster)  PDC: $($domain.PDCEmulator)"
        if (Test-Connection -ComputerName ($schemaMaster.Split('.')[0]) -Count 1 -Quiet) {
            Add-Result 'SchemaMaster' 'PASS' "Schema Master $schemaMaster is reachable (ping)."
        } else {
            Add-Result 'SchemaMaster' 'WARN' "Schema Master $schemaMaster did not respond to ping (ICMP may be firewalled; verify LDAP 389/GC 3268)."
        }
    } catch { Add-Result 'FSMO' 'WARN' ("Could not query FSMO: {0}" -f $_.Exception.Message) }
} else {
    Add-Result 'FSMO' 'INFO' 'Run: netdom query fsmo   (AD module not loaded)'
}

# =============================================================================
# 5. AD replication health
# =============================================================================
Section '5. AD replication'
$repl = & repadmin /replsummary 2>$null
if ($LASTEXITCODE -eq 0 -and $repl) {
    # any non-zero in the "fails/total" column?
    $failLines = $repl | Where-Object { $_ -match '\b([1-9]\d*)\s*/\s*\d+' }
    if ($failLines) {
        Add-Result 'Replication' 'FAIL' 'repadmin /replsummary shows replication FAILURES:'
        $failLines | ForEach-Object { Write-Host "        $_" -ForegroundColor Red }
    } else {
        Add-Result 'Replication' 'PASS' 'repadmin /replsummary shows 0 failures.'
    }
    # large deltas -> inter-site lag; warn if > 60 min
    $bigDelta = $repl | Where-Object { $_ -match '(\d+)d' -or $_ -match '(0[1-9]|[1-9]\d)h' }
    if ($bigDelta) { Add-Result 'Replication' 'WARN' 'Some replication deltas are large (hours/days). Force convergence: repadmin /syncall <SchemaMaster> /AdeP' }
} else {
    Add-Result 'Replication' 'WARN' 'repadmin not available or returned no data. Run repadmin /replsummary manually.'
}

# =============================================================================
# 6. AD site and DC affinity
# =============================================================================
Section '6. Site / DC'
try {
    $site = (nltest /dsgetsite 2>$null | Select-Object -First 1)
    if ($site) { Add-Result 'ADSite' 'INFO' "This server's AD site: $site" }
    $dc = nltest "/dsgetdc:$env:USERDNSDOMAIN" 2>$null | Select-String 'DC:' | Select-Object -First 1
    if ($dc) { Add-Result 'DCLocator' 'INFO' ($dc.ToString().Trim()) }
} catch { Add-Result 'Site/DC' 'WARN' 'nltest not available.' }

# =============================================================================
# 7. Local server privilege - SeSecurityPrivilege ("Manage auditing and
#    security log"). Setup's Set-LocalPermissions writes SACLs on the LOCAL box
#    and needs this privilege in the CURRENT process token. When a hardening
#    baseline/GPO strips Administrators out of this right in the LOCAL security
#    policy, setup dies with:
#       PrivilegeNotHeldException: ... 'SeSecurityPrivilege' ...
#       at Microsoft.Exchange.Management.Deployment.SetLocalPermissions
#    Being elevated is NOT sufficient - the right must be granted in policy and
#    present in the logon token. This is the local counterpart to section 8,
#    which checks the same right on domain controllers.
# =============================================================================
Section '7. Local privilege - Manage auditing and security log (Set-LocalPermissions)'

$privConstant = 'SeSecurityPrivilege'
$privFriendly = 'Manage auditing and security log'

# 7a. Does the CURRENT process token actually hold the privilege? This is exactly
#     what Set-LocalPermissions checks; elevation alone is not enough.
$heldInToken = $null
try {
    $priv = & whoami /priv 2>$null
    $heldInToken = [bool]($priv -match [regex]::Escape($privConstant))
} catch {}

if ($heldInToken -eq $true) {
    Add-Result 'LocalPriv:Token' 'PASS' "Process token holds $privConstant ('$privFriendly'). Set-LocalPermissions will succeed."
} elseif ($heldInToken -eq $false) {
    Add-Result 'LocalPriv:Token' 'FAIL' "Process token does NOT hold $privConstant ('$privFriendly') - this is the exact cause of setup's PrivilegeNotHeldException in Set-LocalPermissions. Grant 'Administrators' this right in Local Security Policy (or the winning GPO), then LOG OFF/ON and rerun Setup."
} else {
    Add-Result 'LocalPriv:Token' 'WARN' "Could not read process privileges. Check manually: whoami /priv | findstr $privConstant"
}

# 7b. Effective LOCAL security policy - who is granted the right. Confirms the
#     token gap comes from local policy and names who currently holds it, so you
#     can see whether Administrators was stripped by a baseline/GPO.
try {
    $inf = Join-Path $env:TEMP ("secpol_local_{0}.inf" -f [guid]::NewGuid())
    secedit /export /areas USER_RIGHTS /cfg $inf | Out-Null
    $line = Select-String -Path $inf -Pattern '^SeSecurityPrivilege\s*=' -EA SilentlyContinue
    Remove-Item $inf -Force -EA SilentlyContinue
    if ($line) {
        $entries = ($line.Line -split '=', 2)[1].Trim() -split ',' | ForEach-Object { $_.Trim() }
        # secedit emits '*S-1-...' SIDs; resolve to friendly names where possible.
        $names = foreach ($e in $entries) {
            if ($e -match '^\*?(S-1-[\d-]+)$') {
                try { (New-Object Security.Principal.SecurityIdentifier($Matches[1])).Translate([Security.Principal.NTAccount]).Value }
                catch { $Matches[1] }
            } elseif ($e) { $e }
        }
        $adminsPresent = ($names -match 'Administrators') -or ($entries -contains '*S-1-5-32-544')
        $shown = if ($names) { ($names | Sort-Object -Unique) -join ', ' } else { '(empty)' }
        if ($adminsPresent) {
            Add-Result 'LocalPriv:Policy' 'PASS' "Local policy grants '$privFriendly' to: $shown"
        } else {
            Add-Result 'LocalPriv:Policy' 'FAIL' "Local policy grants '$privFriendly' to: $shown - 'Administrators' is MISSING. A hardening baseline/GPO stripped it. Add 'Administrators' (secpol.msc -> User Rights Assignment), reapply, then log off/on."
        }
    } else {
        # No assignment line at all = nobody holds the right.
        Add-Result 'LocalPriv:Policy' 'FAIL' "Local policy assigns '$privFriendly' to NO accounts. Add 'Administrators' to this right (secpol.msc -> User Rights Assignment), then log off/on and rerun Setup."
    }
} catch {
    Add-Result 'LocalPriv:Policy' 'WARN' ("Could not export local security policy: {0}. Check secpol.msc -> User Rights Assignment -> '$privFriendly'." -f $_.Exception.Message)
}

# =============================================================================
# 8. Domain Controller security policy (RSoP) - "Manage auditing and security log"
#    Exchange setup grants the Exchange Servers group the SeSecurityPrivilege
#    ("Manage auditing and security log") right on domain controllers via the
#    Default Domain Controllers Policy. A custom GPO that redefines this right and
#    wins precedence can strip Exchange's group out, which breaks setup/PrepareAD.
#    This checks the RESULTANT set of policy on each DC, not just one GPO.
# =============================================================================
Section '8. DC security policy - Manage auditing and security log (RSoP)'

$privConstant = 'SeSecurityPrivilege'
$privFriendly = 'Manage auditing and security log'
$exchGroupNames = @('Exchange Servers','Exchange Enterprise Servers')

# Resolve the Exchange group SIDs (domain-relative) so we can match by SID too.
$exchGroupSids = @{}
if ($adModule) {
    foreach ($gn in $exchGroupNames) {
        try {
            $g = Get-ADGroup -Filter "Name -eq '$gn'" -EA SilentlyContinue
            if ($g) { $exchGroupSids[$gn] = $g.SID.Value }
        } catch {}
    }
}

# Discover domain controllers to evaluate.
$dcList = @()
if ($adModule) {
    try { $dcList = @(Get-ADDomainController -Filter * -EA Stop | Select-Object -Expand HostName) } catch {}
}
if (-not $dcList -and $env:LOGONSERVER) { $dcList = @($env:LOGONSERVER.TrimStart('\')) }

$haveGpModule = $false
try { Import-Module GroupPolicy -EA Stop; $haveGpModule = $true } catch {}

if (-not $dcList) {
    Add-Result 'DCPolicy' 'WARN' "Could not enumerate DCs. Check '$privFriendly' on each DC manually (rsop.msc / secedit /export /areas USER_RIGHTS)."
}

foreach ($dc in $dcList) {
    $members = $null; $winningGpo = $null; $method = $null

    # --- Preferred: RSoP - shows the resultant members and (often) the winning GPO
    if ($haveGpModule) {
        $tmp = Join-Path $env:TEMP ("rsop_{0}.xml" -f [guid]::NewGuid())
        try {
            Get-GPResultantSetOfPolicy -Computer $dc -ReportType Xml -Path $tmp -EA Stop | Out-Null
            [xml]$rsop = Get-Content $tmp -Raw
            $node = $rsop.SelectNodes("//*[local-name()='UserRightsAssignment']") |
                Where-Object {
                    $nm = $_.SelectSingleNode("*[local-name()='Name']").'#text'
                    $nm -eq $privConstant -or $nm -eq $privFriendly
                } | Select-Object -First 1
            if ($node) {
                $members = @($node.SelectNodes("*[local-name()='Member']") | ForEach-Object {
                    $nm = $_.SelectSingleNode("*[local-name()='Name']").'#text'
                    if ($nm) { $nm } else { $_.SelectSingleNode("*[local-name()='SID']").'#text' }
                })
                $gpoName = $node.SelectSingleNode("*[local-name()='GPO']/*[local-name()='Name']")
                if ($gpoName) { $winningGpo = $gpoName.'#text' }
                $method = 'RSoP'
            }
        } catch {
            Write-Verbose "RSoP against $dc failed: $($_.Exception.Message)"
        } finally {
            Remove-Item $tmp -Force -EA SilentlyContinue
        }
    }

    # --- Fallback: effective security policy on the DC via secedit --------------
    if (-not $members) {
        try {
            $members = Invoke-Command -ComputerName $dc -ErrorAction Stop -ScriptBlock {
                $t = Join-Path $env:TEMP ("secpol_{0}.inf" -f [guid]::NewGuid())
                secedit /export /areas USER_RIGHTS /cfg $t | Out-Null
                $line = Select-String -Path $t -Pattern '^SeSecurityPrivilege\s*=' -EA SilentlyContinue
                Remove-Item $t -Force -EA SilentlyContinue
                if ($line) { ($line.Line -split '=', 2)[1].Trim() -split ',' | ForEach-Object { $_.Trim() } }
            }
            if ($members) { $method = 'secedit' }
        } catch {
            Write-Verbose "secedit against $dc failed: $($_.Exception.Message)"
        }
    }

    if (-not $members) {
        Add-Result "DCPol:$dc" 'WARN' "Could not read '$privFriendly' on $dc (needs RSAT GroupPolicy or WinRM). Check with rsop.msc."
        continue
    }

    # Normalise members: secedit yields '*S-1-...' SIDs; RSoP yields DOMAIN\Name.
    $memberSids = @(); $memberNames = @()
    foreach ($m in $members) {
        $mm = "$m".Trim()
        if ($mm -match '^\*?(S-1-[\d-]+)$') { $memberSids += $Matches[1] } elseif ($mm) { $memberNames += $mm }
    }

    $exchPresent = $false
    foreach ($gn in $exchGroupNames) {
        if ($memberNames -match [regex]::Escape($gn)) { $exchPresent = $true; break }
        if ($exchGroupSids.ContainsKey($gn) -and ($memberSids -contains $exchGroupSids[$gn])) { $exchPresent = $true; break }
    }
    $adminsPresent = ($memberNames -match 'Administrators') -or ($memberSids -contains 'S-1-5-32-544')
    $shown = if ($memberNames) { $memberNames -join ', ' } elseif ($memberSids) { $memberSids -join ', ' } else { '(empty)' }

    if ($exchPresent -and $adminsPresent) {
        Add-Result "DCPol:$dc" 'PASS' "'$privFriendly' includes Exchange + Administrators [$method]. Granted to: $shown"
    } elseif (-not $exchPresent) {
        Add-Result "DCPol:$dc" 'FAIL' "'$privFriendly' does NOT include the Exchange Servers group [$method] - a GPO is overriding the Default Domain Controllers Policy. Add 'Exchange Servers' (and 'Administrators') back to this right in the winning GPO. Granted to: $shown"
    } else {
        Add-Result "DCPol:$dc" 'WARN' "'$privFriendly' is missing 'Administrators' [$method]. Granted to: $shown"
    }

    if ($winningGpo -and $winningGpo -notmatch 'Default Domain Controllers Policy') {
        Add-Result "DCPol:$dc" 'WARN' "'$privFriendly' is being set by GPO '$winningGpo' (not the Default Domain Controllers Policy) - that is the overriding policy. Fix it there, or remove the setting so the default applies."
    }
}

# =============================================================================
# 9. Current AD Exchange versions vs CU target
# =============================================================================
Section "9. AD Exchange prep versions (target = $($Cu.Name))"
if ($adModule) {
    try {
        $rootDSE   = Get-ADRootDSE
        $configNC  = $rootDSE.configurationNamingContext
        $schemaNC  = $rootDSE.schemaNamingContext
        $domainNC  = $rootDSE.defaultNamingContext

        # schema rangeUpper
        $schemaObj = Get-ADObject "CN=ms-Exch-Schema-Version-Pt,$schemaNC" -Properties rangeUpper -EA SilentlyContinue
        if ($schemaObj) { Compare-Ver 'Schema' $schemaObj.rangeUpper $Cu.SchemaRange } else { Add-Result 'Schema' 'INFO' 'ms-Exch-Schema-Version-Pt not found (schema not yet extended).' }

        # org objectVersion - found by object class, so it works whatever the org is named
        $orgObj = Get-ADObject -SearchBase "CN=Microsoft Exchange,CN=Services,$configNC" `
            -LDAPFilter '(objectClass=msExchOrganizationContainer)' -Properties objectVersion -EA SilentlyContinue | Select-Object -First 1
        if ($orgObj) { Compare-Ver 'OrgConfig' $orgObj.objectVersion $Cu.OrgVersion } else { Add-Result 'OrgConfig' 'INFO' 'Exchange organization container not found (organization not yet prepared).' }

        # domain objectVersion
        $domObj = Get-ADObject "CN=Microsoft Exchange System Objects,$domainNC" -Properties objectVersion -EA SilentlyContinue
        if ($domObj) { Compare-Ver 'DomainConfig' $domObj.objectVersion $Cu.DomainVersion } else { Add-Result 'DomainConfig' 'INFO' 'Microsoft Exchange System Objects not found (domain not yet prepared).' }
    } catch { Add-Result 'ADVersions' 'WARN' ("Could not read AD versions: {0}" -f $_.Exception.Message) }
} else {
    Add-Result 'ADVersions' 'INFO' 'AD module not loaded; skipping version comparison.'
}

# =============================================================================
# 10. OS prerequisites (.NET, VC++, RSAT, features)
# =============================================================================
Section '10. OS prerequisites'
# .NET Framework (CU8 needs 4.8 = release >= 528040)
$rel = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full' -Name Release -EA SilentlyContinue).Release
if ($rel -ge 528040) { Add-Result '.NET' 'PASS' ".NET 4.8+ present (release $rel)." }
elseif ($rel)        { Add-Result '.NET' 'WARN' ".NET release $rel < 528040. Exchange 2019 CU8 requires .NET 4.8." }
else                 { Add-Result '.NET' 'WARN' 'Could not read .NET version.' }

# VC++ redistributables (2012 + 2013 required by Exchange)
$vc = Get-CimInstance Win32_Product -Filter "Name LIKE 'Microsoft Visual C++ 201%Redistributable%'" -EA SilentlyContinue | Select-Object -Expand Name -Unique
if ($vc -match '2012') { Add-Result 'VC++2012' 'PASS' 'Visual C++ 2012 redistributable present.' } else { Add-Result 'VC++2012' 'WARN' 'Visual C++ 2012 redistributable not detected.' }
if ($vc -match '2013') { Add-Result 'VC++2013' 'PASS' 'Visual C++ 2013 redistributable present.' } else { Add-Result 'VC++2013' 'WARN' 'Visual C++ 2013 redistributable not detected.' }

# RSAT-ADDS tools
try {
    $feat = Get-WindowsFeature RSAT-ADDS -EA Stop
    if ($feat.Installed) { Add-Result 'RSAT-ADDS' 'PASS' 'RSAT AD DS tools installed.' } else { Add-Result 'RSAT-ADDS' 'WARN' 'RSAT-ADDS not installed. Install-WindowsFeature RSAT-ADDS' }
} catch { Add-Result 'RSAT-ADDS' 'INFO' 'Get-WindowsFeature unavailable (not a server SKU?).' }

# =============================================================================
# 11. Environment sanity (disk, exec policy, time skew, hostname)
# =============================================================================
Section '11. Environment'
# disk space on install drive
try {
    $d = Get-PSDrive ($InstallDrive.TrimEnd(':','\')) -EA Stop
    $freeGB = [math]::Round($d.Free/1GB,1)
    if ($freeGB -ge 30) { Add-Result 'DiskSpace' 'PASS' "$InstallDrive has $freeGB GB free." }
    else                { Add-Result 'DiskSpace' 'WARN' "$InstallDrive has only $freeGB GB free (want 30GB+)." }
} catch { Add-Result 'DiskSpace' 'WARN' "Could not read drive $InstallDrive." }

# execution policy (RemoteSigned/Unrestricted needed by setup scripts)
$ep = Get-ExecutionPolicy
if ($ep -in 'RemoteSigned','Unrestricted','Bypass') { Add-Result 'ExecPolicy' 'PASS' "ExecutionPolicy=$ep." }
else { Add-Result 'ExecPolicy' 'WARN' "ExecutionPolicy=$ep. Setup expects RemoteSigned or looser. Set-ExecutionPolicy RemoteSigned" }

# time skew vs a DC (Kerberos tolerates 5 min)
if ($adModule) {
    try {
        $pdc = (Get-ADDomain).PDCEmulator
        $remote = (Invoke-Command -ComputerName $pdc -ScriptBlock { Get-Date } -EA Stop)
        $skew = [math]::Abs(((Get-Date) - $remote).TotalSeconds)
        if ($skew -lt 120) { Add-Result 'TimeSkew' 'PASS' ("Clock within {0}s of PDC $pdc." -f [int]$skew) }
        else { Add-Result 'TimeSkew' 'WARN' ("Clock differs from PDC by {0}s (Kerberos limit 300s). Resync w32time." -f [int]$skew) }
    } catch { Add-Result 'TimeSkew' 'INFO' 'Could not remote to PDC to check time (WinRM). Verify w32tm /query /status manually.' }
}

# hostname length / netbios
if ($env:COMPUTERNAME.Length -gt 15) { Add-Result 'Hostname' 'WARN' 'Computer name exceeds 15 chars (NetBIOS limit).' } else { Add-Result 'Hostname' 'PASS' "Computer name '$env:COMPUTERNAME' OK." }

# =============================================================================
# Summary
# =============================================================================
Section 'SUMMARY'
$fail = ($script:Results | Where-Object Status -eq 'FAIL').Count
$warn = ($script:Results | Where-Object Status -eq 'WARN').Count
$pass = ($script:Results | Where-Object Status -eq 'PASS').Count
Write-Host ("  PASS: {0}   WARN: {1}   FAIL: {2}" -f $pass, $warn, $fail)
if ($fail -gt 0) {
    Write-Host "`n  BLOCKERS (fix before running Setup):" -ForegroundColor Red
    $script:Results | Where-Object Status -eq 'FAIL' | ForEach-Object { Write-Host "   - [$($_.Area)] $($_.Message)" -ForegroundColor Red }
    Write-Host "`n  Recommended order: reboot -> log back in fresh -> elevated shell -> rerun Setup." -ForegroundColor Yellow
} elseif ($warn -gt 0) {
    Write-Host "`n  No hard blockers. Review WARN items above, then rerun Setup." -ForegroundColor Yellow
} else {
    # /OrganizationName is only needed when first creating the org; include it if discovered.
    $orgSwitch = if ($OrganizationName) { " /OrganizationName:`"$OrganizationName`"" } else { '' }
    Write-Host "`n  All green. Safe to run: $InstallDrive\Setup.exe /IAcceptExchangeServerLicenseTerms_DiagnosticDataON /PrepareAD$orgSwitch" -ForegroundColor Green
}
