#Requires -Version 5.1
<#
.SYNOPSIS
    DC validation. Returns a report object and writes JSON to
    C:\ProgramData\MidCoastLab\Logs\Validation (latest.json + timestamped).

.DESCRIPTION
    Runs as SYSTEM (read-only checks). The common checks (NET, TS, MEM, EVAL)
    come from Lab.Validation; this file adds the directory, DNS, SYSVOL, FSMO,
    replication, time, LAPS and Remote Desktop checks. Severity and recovery
    actions come from catalog.psd1. To run it by hand on a DC:
        C:\ProgramData\MidCoastLab\Platform\validate.ps1
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] $Metadata,
    [Parameter(Mandatory)] $Inventory
)

$ErrorActionPreference = 'Stop'
Import-Module ActiveDirectory
$domain   = $Inventory.identity.active_directory.domain
$domainDN = Get-LabDomainDN -Inventory $Inventory
$me       = $env:COMPUTERNAME
$myFqdn   = "$me.$domain".ToLower()
$results  = @(Invoke-LabCommonChecks -Metadata $Metadata -Inventory $Inventory)
$dcCount  = @(Get-ADDomainController -Filter * -Server localhost).Count

$results += Invoke-LabCheck -Id 'AD-001' -Check {
    $names = 'NTDS', 'ADWS', 'Netlogon', 'Kdc', 'DNS', 'DFSR', 'W32Time'
    $down  = @(Get-Service -Name $names | Where-Object Status -ne 'Running' | ForEach-Object Name)
    @{ Passed = ($down.Count -eq 0); Detail = if ($down) { "not running: $($down -join ', ')" } else { '' } }
}

$results += Invoke-LabCheck -Id 'AD-002' -Check {
    (Get-ADDomainController -Identity $me -Server localhost).IsGlobalCatalog
}

$results += Invoke-LabCheck -Id 'AD-003' -Check {
    $out = & dcdiag.exe /s:localhost /test:Advertising /test:Services /test:NetLogons /test:MachineAccount /test:RidManager /test:FsmoCheck 2>&1
    $failed = @($out | Select-String -Pattern 'failed test (\S+)' | ForEach-Object { $_.Matches[0].Groups[1].Value })
    @{ Passed = ($failed.Count -eq 0); Detail = if ($failed) { "failed: $($failed -join ', ')" } else { '' } }
}

$results += Invoke-LabCheck -Id 'DNS-001' -Check {
    [bool] (Resolve-DnsName -Name $domain -Server 127.0.0.1 -DnsOnly -ErrorAction Stop)
}

$results += Invoke-LabCheck -Id 'DNS-002' -Check {
    $srv = Resolve-DnsName -Name "_ldap._tcp.dc._msdcs.$domain" -Type SRV -Server 127.0.0.1 -DnsOnly -ErrorAction Stop
    $targets = @($srv | Where-Object QueryType -eq 'SRV' | ForEach-Object { $_.NameTarget.ToLower() })
    @{ Passed = ($targets -contains $myFqdn); Detail = "SRV targets: $($targets -join ', ')" }
}

$results += Invoke-LabCheck -Id 'DNS-003' -Check {
    [bool] (Resolve-DnsName -Name 'www.microsoft.com' -Server 127.0.0.1 -DnsOnly -ErrorAction Stop)
}

$results += Invoke-LabCheck -Id 'DNS-004' -Check {
    $adapter = Get-LabPrimaryAdapter
    $servers = @((Get-DnsClientServerAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4).ServerAddresses)
    if ($dcCount -le 1) {
        @{ Passed = ($servers -contains '127.0.0.1'); Detail = "DNS client: $($servers -join ', ')" }
    } else {
        $ok = ($servers.Count -ge 2) -and ($servers[0] -ne '127.0.0.1') -and ($servers[0] -ne $Metadata.ipv4) -and ($servers[-1] -eq '127.0.0.1')
        @{ Passed = $ok; Detail = "DNS client: $($servers -join ', ')" }
    }
}

$results += Invoke-LabCheck -Id 'SYSVOL-001' -Check {
    $shares = @(Get-SmbShare -Name SYSVOL, NETLOGON -ErrorAction SilentlyContinue | ForEach-Object Name)
    @{ Passed = ($shares.Count -eq 2); Detail = "shares present: $($shares -join ', ')" }
}

$results += Invoke-LabCheck -Id 'SYSVOL-002' -Check {
    $rf = Get-CimInstance -Namespace 'root\microsoftdfs' -ClassName DfsrReplicatedFolderInfo -Filter "ReplicatedFolderName='SYSVOL Share'"
    # 0 Uninitialized, 1 Initialized, 2 Initial Sync, 3 Auto Recovery, 4 Normal, 5 In Error
    @{ Passed = ($rf.State -eq 4); Detail = "DFSR state $($rf.State)" }
}

$results += Invoke-LabCheck -Id 'FSMO-001' -Check {
    $holders = Get-LabFsmoHolders -Server localhost
    $bad = @()
    foreach ($k in $holders.Keys) {
        $ok = (Test-NetConnection -ComputerName $holders[$k] -Port 389 -WarningAction SilentlyContinue).TcpTestSucceeded
        if (-not $ok) { $bad += "$k ($($holders[$k]))" }
    }
    @{ Passed = ($bad.Count -eq 0); Detail = if ($bad) { "unreachable: $($bad -join ', ')" } else { ($holders.Values | Sort-Object -Unique) -join ', ' }; Data = $holders }
}

$results += Invoke-LabCheck -Id 'REPL-001' -Check {
    if ($dcCount -le 1) { return @{ Passed = $true; Detail = 'single DC; nothing to replicate' } }
    # Each inbound link's own failure count, for every naming context (the DNS
    # application partitions too). Not Get-ADReplicationFailure: it reads the
    # KCC's in-memory failure cache, which a successful replication doesn't
    # clear, so a DC rolled back to a snapshot with RAM kept failing this check
    # for a failure from before the snapshot.
    $rows = @(& repadmin.exe /showrepl $me /csv 2>$null | ConvertFrom-Csv | Where-Object { $_.'Number of Failures' -match '^\d+$' })
    if (-not $rows) { return @{ Passed = $false; Detail = 'repadmin /showrepl listed no inbound replication links' } }
    $bad = @($rows | Where-Object { [int] $_.'Number of Failures' -gt 0 })
    @{ Passed = ($bad.Count -eq 0); Detail = if ($bad) { ($bad | ForEach-Object { "$($_.'Naming Context') from $($_.'Source DSA'): $($_.'Number of Failures') failure(s), last status $($_.'Last Failure Status')" }) -join '; ' } else { "$($rows.Count) inbound link(s), no failures" } }
}

$results += Invoke-LabCheck -Id 'REPL-002' -Check {
    if ($dcCount -le 1) { return @{ Passed = $true; Detail = 'single DC' } }
    $meta  = @(Get-ADReplicationPartnerMetadata -Target $me -PartnerType Inbound -ErrorAction Stop)
    # Within a site, a quiet domain replicates on change notification plus an hourly
    # schedule, so up to an hour between successes is normal; stale means 3 hours.
    $stale = @($meta | Where-Object { $_.LastReplicationSuccess -lt (Get-Date).AddMinutes(-180) })
    @{ Passed = ($meta.Count -gt 0 -and $stale.Count -eq 0); Detail = "inbound partners: $($meta.Count), stale: $($stale.Count)" }
}

$results += Invoke-LabCheck -Id 'TIME-001' -Check {
    $source = (& w32tm.exe /query /source 2>&1 | Out-String).Trim()
    $isPdc  = ((Get-ADDomain -Server localhost).PDCEmulator.ToLower() -eq $myFqdn)
    $ok = $source -notmatch 'Local CMOS Clock|Free-running'
    @{ Passed = $ok; Detail = "source '$source' (PDC: $isPdc)" }
}

$results += Invoke-LabCheck -Id 'LAPS-001' -Check {
    $schemaNC = (Get-ADRootDSE -Server localhost).schemaNamingContext
    [bool] (Get-ADObject -SearchBase $schemaNC -Filter "lDAPDisplayName -eq 'msLAPS-Password'" -Server localhost)
}

$results += Invoke-LabCheck -Id 'LAPS-002' -Check {
    Import-Module GroupPolicy
    $key   = 'HKLM\Software\Microsoft\Windows\CurrentVersion\Policies\LAPS'
    $links = @((Get-GPInheritance -Target "OU=Domain Controllers,$domainDN").GpoLinks | ForEach-Object DisplayName)
    $bad   = @()
    foreach ($g in 'MidCoast-LAPS-Members', 'MidCoast-LAPS-DSRM') {
        $v = Get-GPRegistryValue -Name $g -Key $key -ValueName 'BackupDirectory' -ErrorAction SilentlyContinue
        if (-not $v -or $v.Value -ne 2) { $bad += "$g has no BackupDirectory=2" }
    }
    $dsrm = Get-GPRegistryValue -Name 'MidCoast-LAPS-DSRM' -Key $key -ValueName 'ADBackupDSRMPassword' -ErrorAction SilentlyContinue
    if (-not $dsrm -or $dsrm.Value -ne 1) { $bad += 'DSRM backup not enabled' }
    if ($links -notcontains 'MidCoast-LAPS-DSRM') { $bad += 'MidCoast-LAPS-DSRM not linked to Domain Controllers' }
    @{ Passed = ($bad.Count -eq 0); Detail = if ($bad) { $bad -join '; ' } else { "DC OU links: $($links -join ', ')" } }
}

# Remote Desktop on, listening, open to the lab subnet.
$results += Invoke-LabCheck -Id 'RDP-001' -Check { Test-LabRemoteDesktop }

$results += Invoke-LabCheck -Id 'DNS-005' -Check {
    # No Tailscale address in AD's DNS: domain members would try to reach a DC on it.
    $bad = @(Get-LabTailnetDnsRecords -Domain $domain)
    @{ Passed = ($bad.Count -eq 0); Detail = if ($bad) { ($bad | ForEach-Object { "$($_.Name).$($_.Zone) -> $($_.Address)" }) -join '; ' } else { '' } }
}

Complete-LabValidationReport -Results $results -Role 'DC' -OutputDirectory (Join-Path $Inventory.logging.path 'Validation')
