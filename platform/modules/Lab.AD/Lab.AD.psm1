# Lab.AD: Active Directory operations driven by inventory.
# Runs on domain controllers under Windows PowerShell 5.1.
# Every function is idempotent: safe to re-run after a partial failure.
#
# Security context: these run as a domain admin, via Invoke-LabAsCredential
# (Lab.System). Bootstrap itself runs as SYSTEM, which on a DC is the DC's
# computer account and cannot extend the schema, create GPOs or run dsacls.

function Install-LabDirectoryFeatures {
    [CmdletBinding()]
    param()
    # RSAT-DFS-Mgmt-Con: dfsrdiag.exe, for SYSVOL (DFSR) checks and troubleshooting.
    $features = 'AD-Domain-Services', 'DNS', 'RSAT-AD-PowerShell', 'RSAT-ADDS', 'RSAT-DNS-Server', 'GPMC', 'RSAT-DFS-Mgmt-Con'
    $result = Install-WindowsFeature -Name $features -IncludeManagementTools
    if (-not $result.Success) { throw "Feature install failed: $($result.ExitCode)" }
    [bool] ($result.RestartNeeded -eq 'Yes')
}

function Wait-LabADReady {
    [CmdletBinding()]
    param(
        [string] $Server = 'localhost',
        [pscredential] $Credential,
        [int] $TimeoutSeconds = 1200
    )
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ($true) {
        try {
            $svc = Get-Service -Name ADWS, NTDS, DNS, Netlogon -ErrorAction Stop
            if (@($svc | Where-Object Status -ne 'Running').Count -eq 0) {
                $p = @{ Server = $Server; ErrorAction = 'Stop' }
                if ($Credential) { $p.Credential = $Credential }
                $null = Get-ADDomain @p
                return
            }
        } catch { }
        if ((Get-Date) -gt $deadline) { throw "Active Directory did not become ready on $Server within $TimeoutSeconds s." }
        Start-Sleep -Seconds 15
    }
}

function New-LabOrganizationalUnits {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Inventory
    )
    $domainDN = Get-LabDomainDN -Inventory $Inventory
    # Parents before children: sort by depth.
    $paths = @($Inventory.organizational_units) | Sort-Object { ($_ -split '/').Count }
    foreach ($path in $paths) {
        $dn     = ConvertTo-LabOUDistinguishedName -OUPath $path -DomainDN $domainDN
        $name   = ($path -split '/')[-1]
        $parent = $dn.Substring($dn.IndexOf(',') + 1)
        $exists = Get-ADOrganizationalUnit -Filter "DistinguishedName -eq '$dn'" -ErrorAction SilentlyContinue
        if (-not $exists) {
            New-ADOrganizationalUnit -Name $name -Path $parent -ProtectedFromAccidentalDeletion $true
            Write-LabLog "Created OU $dn"
        }
    }
}

function New-LabGroups {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Inventory
    )
    $domainDN = Get-LabDomainDN -Inventory $Inventory
    # Each group lives in its tier's Groups OU (Admin/Tier<n>/Groups).
    foreach ($g in @($Inventory.groups.administrative)) {
        $groupOU = ConvertTo-LabOUDistinguishedName -OUPath (Get-LabTierOU -Inventory $Inventory -Tier ([int] $g.tier) -Kind Groups) -DomainDN $domainDN
        if (-not (Get-ADGroup -Filter "Name -eq '$($g.name)'" -ErrorAction SilentlyContinue)) {
            New-ADGroup -Name $g.name -SamAccountName $g.name -GroupScope Global -GroupCategory Security -Path $groupOU `
                -Description "Tier $($g.tier) administrative role group"
            Write-LabLog "Created group $($g.name) (tier $($g.tier))"
        }
    }
    # Nesting: lab group -> built-in group (e.g. SG-ROLE-DomainAdmins -> Domain Admins).
    if ($Inventory.groups.nesting) {
        foreach ($prop in $Inventory.groups.nesting.PSObject.Properties) {
            foreach ($target in @($prop.Value)) {
                $members = Get-ADGroupMember -Identity $target | Select-Object -ExpandProperty SamAccountName
                if ($members -notcontains $prop.Name) {
                    Add-ADGroupMember -Identity $target -Members $prop.Name
                    Write-LabLog "Nested $($prop.Name) into $target"
                }
            }
        }
    }
}

function New-LabAccount {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $SamAccountName,
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [securestring] $Password,
        [Parameter(Mandatory)] [string] $UpnSuffix,
        [string] $GivenName,
        [string] $Surname,
        [string] $Description,
        [switch] $Sensitive,
        [switch] $NeverExpires
    )
    $existing = Get-ADUser -Filter "SamAccountName -eq '$SamAccountName'" -ErrorAction SilentlyContinue
    if ($existing) { return $existing }
    $display = if ($GivenName -and $Surname) { "$GivenName $Surname" } else { $SamAccountName }
    if ($SamAccountName -match '-a$') { $display += ' (Admin)' }
    $p = @{
        Name                  = $SamAccountName
        SamAccountName        = $SamAccountName
        UserPrincipalName     = "$SamAccountName@$UpnSuffix"
        DisplayName           = $display
        Path                  = $Path
        AccountPassword       = $Password
        Enabled               = $true
        PasswordNeverExpires  = $false
        ChangePasswordAtLogon = $false
    }
    if ($GivenName)   { $p.GivenName   = $GivenName }
    if ($Surname)     { $p.Surname     = $Surname }
    if ($Description) { $p.Description = $Description }
    New-ADUser @p
    if ($Sensitive) {
        # Admin and service accounts must never be delegated.
        Set-ADAccountControl -Identity $SamAccountName -AccountNotDelegated $true
    }
    if ($NeverExpires) {
        # Pipeline credentials live in KeePass; expiry would break rotation.
        Set-ADUser -Identity $SamAccountName -PasswordNeverExpires $true
    }
    Write-LabLog "Created account $SamAccountName"
    Get-ADUser -Identity $SamAccountName
}

function New-LabAccounts {
    # Passwords come from secrets pushed by the orchestrator, one per account,
    # named after the account (<user>, <user>-a, svc-labdeploy, ...).
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Inventory
    )
    $domainDN = Get-LabDomainDN -Inventory $Inventory
    $suffix   = $Inventory.identity.administrative_model.account_suffix
    # UPN uses the Entra domain so accounts are ready for sync in Phase 3.
    $upn      = $Inventory.identity.entra.tenant_domain
    $usersOU  = ConvertTo-LabOUDistinguishedName -OUPath $Inventory.placement.standard_users -DomainDN $domainDN

    # Standard account in placement.standard_users; the -a account in its tier's Accounts OU.
    foreach ($a in @($Inventory.identity.administrative_model.administrators)) {
        New-LabAccount -SamAccountName $a.username -Path $usersOU -Password (Get-LabSecret -Name $a.username) `
            -UpnSuffix $upn -GivenName $a.given_name -Surname $a.surname | Out-Null
        $adminName = "$($a.username)$suffix"
        $adminOU   = ConvertTo-LabOUDistinguishedName -OUPath (Get-LabTierOU -Inventory $Inventory -Tier ([int] $a.tier) -Kind Accounts) -DomainDN $domainDN
        New-LabAccount -SamAccountName $adminName -Path $adminOU -Password (Get-LabSecret -Name $adminName) `
            -UpnSuffix $upn -GivenName $a.given_name -Surname $a.surname -Sensitive | Out-Null
        foreach ($g in @($a.groups)) { if ($g) { Add-LabGroupMember -Group $g -Member $adminName } }
    }

    # The built-in Administrator is a pipeline credential too.
    Set-ADUser -Identity Administrator -PasswordNeverExpires $true -AccountNotDelegated $true

    foreach ($s in @($Inventory.identity.service_accounts)) {
        $svcOU = ConvertTo-LabOUDistinguishedName -OUPath (Get-LabTierOU -Inventory $Inventory -Tier ([int] $s.tier) -Kind ServiceAccounts) -DomainDN $domainDN
        New-LabAccount -SamAccountName $s.name -Path $svcOU -Password (Get-LabSecret -Name $s.name) `
            -UpnSuffix $upn -Description $s.description -Sensitive -NeverExpires | Out-Null
        Set-ADUser -Identity $s.name -PasswordNeverExpires $true   # also on re-runs
        foreach ($g in @($s.groups)) {
            if ($g) { Add-LabGroupMember -Group $g -Member $s.name }
        }
    }
}

function Add-LabGroupMember {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Group,
        [Parameter(Mandatory)] [string] $Member
    )
    $current = Get-ADGroupMember -Identity $Group | Select-Object -ExpandProperty SamAccountName
    if ($current -notcontains $Member) {
        Add-ADGroupMember -Identity $Group -Members $Member
        Write-LabLog "Added $Member to $Group"
    }
}

function Set-LabDomainJoinDelegation {
    # Least privilege for joining: create/delete computers, reset password,
    # validated writes, account restrictions. Nothing else.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Inventory,
        [Parameter(Mandatory)] [string] $Account
    )
    $domainDN = Get-LabDomainDN -Inventory $Inventory
    $netbios  = $Inventory.identity.active_directory.netbios
    $who      = "$netbios\$Account"
    # Every OU a computer can be joined into, Tier 0 OUs included; that's why
    # the join account is itself Tier 0 (inventory validation enforces it).
    $targets  = Get-LabComputerOUs -Inventory $Inventory | ForEach-Object { ConvertTo-LabOUDistinguishedName -OUPath $_ -DomainDN $domainDN }
    foreach ($ou in $targets) {
        $grants = @(
            @('/I:T', "${who}:CCDC;computer"),
            @('/I:S', "${who}:CA;Reset Password;computer"),
            @('/I:S', "${who}:WS;Validated write to DNS host name;computer"),
            @('/I:S', "${who}:WS;Validated write to service principal name;computer"),
            @('/I:S', "${who}:RPWP;Account Restrictions;computer")
        )
        foreach ($g in $grants) {
            $out = & dsacls.exe $ou $g[0] /G $g[1] 2>&1
            if ($LASTEXITCODE -ne 0) { throw "dsacls failed on ${ou}: $out" }
        }
        Write-LabLog "Delegated domain join on $ou to $who"
    }
}

function Set-LabComputersContainer {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Inventory)
    $domainDN = Get-LabDomainDN -Inventory $Inventory
    $target   = ConvertTo-LabOUDistinguishedName -OUPath $Inventory.placement.default_computers -DomainDN $domainDN
    $current  = (Get-ADDomain).ComputersContainer
    if ($current -ne $target) {
        $out = & redircmp.exe $target 2>&1
        if ($LASTEXITCODE -ne 0) { throw "redircmp failed: $out" }
        Write-LabLog "New computer objects now land in $target"
    }
}

function Set-LabDnsServerConfiguration {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Inventory)
    $forwarders = @($Inventory.identity.active_directory.dns_forwarders)
    if ($forwarders.Count -gt 0) {
        Set-DnsServerForwarder -IPAddress $forwarders -UseRootHint $true
    }
    # Reverse lookup zone for the lab subnet, replicated forest-wide.
    $subnet = $Inventory.network.subnet
    $octets = ($subnet -split '/')[0].Split('.')
    $zone   = '{0}.{1}.{2}.in-addr.arpa' -f $octets[2], $octets[1], $octets[0]
    if (-not (Get-DnsServerZone -Name $zone -ErrorAction SilentlyContinue)) {
        Add-DnsServerPrimaryZone -NetworkId $subnet -ReplicationScope Forest -DynamicUpdate Secure
        Write-LabLog "Created reverse zone $zone"
    }
}

function Add-LabSiteSubnet {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Inventory)
    $subnet = $Inventory.network.subnet
    $site   = $Inventory.identity.active_directory.site
    if (-not (Get-ADReplicationSubnet -Filter "Name -eq '$subnet'" -ErrorAction SilentlyContinue)) {
        New-ADReplicationSubnet -Name $subnet -Site $site
        Write-LabLog "Added subnet $subnet to site $site"
    }
}

function Set-LabTimeSource {
    # PDC emulator syncs from external NTP; every other DC follows the domain hierarchy.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Inventory,
        [switch] $Pdc
    )
    if ($Pdc) {
        $peers = (@($Inventory.network.ntp) | ForEach-Object { "$_,0x8" }) -join ' '
        & w32tm.exe /config "/manualpeerlist:$peers" /syncfromflags:manual /reliable:yes /update | Out-Null
    } else {
        & w32tm.exe /config /syncfromflags:domhier /reliable:no /update | Out-Null
    }
    Restart-Service -Name W32Time -Force
    & w32tm.exe /resync /nowait | Out-Null
}

function Initialize-LabLaps {
    # Windows LAPS: schema, self-write permission, and two GPOs:
    #   MidCoast-LAPS-Members  -> every computer OU (Get-LabComputerOUs: Staging, Servers,
    #                             Workstations, Admin/Tier0/Servers, Admin/Tier0/Devices)
    #   MidCoast-LAPS-DSRM     -> Domain Controllers (DSRM password backup)
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Inventory)
    Import-Module LAPS -ErrorAction Stop
    $domainDN = Get-LabDomainDN -Inventory $Inventory
    $laps     = $Inventory.identity.active_directory.laps
    # Windows LAPS reads Group Policy from this key (not ...\Policies\Microsoft Windows\LAPS).
    $key      = 'HKLM\Software\Microsoft\Windows\CurrentVersion\Policies\LAPS'

    $schemaNC = (Get-ADRootDSE).schemaNamingContext
    if (-not (Get-ADObject -SearchBase $schemaNC -Filter "lDAPDisplayName -eq 'msLAPS-Password'" -ErrorAction SilentlyContinue)) {
        Update-LapsADSchema -Confirm:$false
        Write-LabLog 'Extended schema for Windows LAPS'
    }

    $memberOUs = Get-LabComputerOUs -Inventory $Inventory | ForEach-Object { ConvertTo-LabOUDistinguishedName -OUPath $_ -DomainDN $domainDN }
    $dcOU      = "OU=Domain Controllers,$domainDN"
    foreach ($ou in $memberOUs + $dcOU) {
        Set-LapsADComputerSelfPermission -Identity $ou | Out-Null
    }

    $policies = @(
        @{ Name = 'MidCoast-LAPS-Members'; Targets = $memberOUs; Dsrm = $false },
        @{ Name = 'MidCoast-LAPS-DSRM';    Targets = @($dcOU);   Dsrm = [bool] $laps.backup_dsrm_password }
    )
    foreach ($p in $policies) {
        $gpo = Get-GPO -Name $p.Name -ErrorAction SilentlyContinue
        if (-not $gpo) { $gpo = New-GPO -Name $p.Name -Comment 'Managed by MidCoast Lab pipeline' }
        Set-GPRegistryValue -Name $p.Name -Key $key -ValueName 'BackupDirectory'             -Type DWord -Value 2 | Out-Null
        Set-GPRegistryValue -Name $p.Name -Key $key -ValueName 'PasswordComplexity'          -Type DWord -Value 4 | Out-Null
        Set-GPRegistryValue -Name $p.Name -Key $key -ValueName 'PasswordLength'              -Type DWord -Value ([int] $laps.password_length) | Out-Null
        Set-GPRegistryValue -Name $p.Name -Key $key -ValueName 'PasswordAgeDays'             -Type DWord -Value ([int] $laps.password_age_days) | Out-Null
        Set-GPRegistryValue -Name $p.Name -Key $key -ValueName 'ADPasswordEncryptionEnabled' -Type DWord -Value 1 | Out-Null
        if ($p.Dsrm) {
            Set-GPRegistryValue -Name $p.Name -Key $key -ValueName 'ADBackupDSRMPassword' -Type DWord -Value 1 | Out-Null
        }
        foreach ($t in $p.Targets) {
            $linked = (Get-GPInheritance -Target $t).GpoLinks | Where-Object DisplayName -eq $p.Name
            if (-not $linked) { New-GPLink -Name $p.Name -Target $t -LinkEnabled Yes | Out-Null }
        }
        Write-LabLog "LAPS policy $($p.Name) linked to $($p.Targets -join '; ')"
    }
}

function Add-LabUpnSuffix {
    # Accounts use the Entra tenant domain as their UPN suffix (ready for sync).
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Inventory)
    $suffix = $Inventory.identity.entra.tenant_domain
    $forest = Get-ADForest
    if ($forest.UPNSuffixes -notcontains $suffix) {
        Set-ADForest -Identity $forest -UPNSuffixes @{ Add = $suffix }
        Write-LabLog "Added UPN suffix $suffix"
    }
}

function Get-LabFsmoHolders {
    [CmdletBinding()]
    param([string] $Server = 'localhost')
    $f = Get-ADForest -Server $Server
    $d = Get-ADDomain -Server $Server
    [ordered]@{
        SchemaMaster         = $f.SchemaMaster
        DomainNamingMaster   = $f.DomainNamingMaster
        PDCEmulator          = $d.PDCEmulator
        RIDMaster            = $d.RIDMaster
        InfrastructureMaster = $d.InfrastructureMaster
    }
}

function Set-LabDcSingleHomed {
    # Keeps a DC's AD and DNS on its lab address only, so a second adapter
    # (Tailscale) never ends up in AD's DNS, where domain members would try it:
    #   - the DNS server publishes only the lab address in its own records (it
    #     keeps listening on every address: Windows DNS won't take loopback in its
    #     listen list, and dropping loopback would break the DC's own lookups);
    #   - Netlogon doesn't register the domain-name and gc A records from every
    #     address (DnsAvoidRegisterRecords LdapIpAddress, GcIpAddress); this DC
    #     registers them for its lab address itself, as static records.
    # The rotation's DNS cleanup removes those static records with the DC.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Address,
        [Parameter(Mandatory)] [string] $Domain
    )
    Import-Module DnsServer
    Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\DNS\Parameters' -Name PublishAddresses -Value $Address -Type String
    New-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\Netlogon\Parameters' -Name DnsAvoidRegisterRecords `
        -PropertyType MultiString -Value @('LdapIpAddress', 'GcIpAddress') -Force | Out-Null
    Restart-Service -Name DNS -Force
    Restart-Service -Name Netlogon -Force

    $records = @(
        @{ Zone = $Domain;          Name = '@' }
        @{ Zone = $Domain;          Name = 'DomainDnsZones' }
        @{ Zone = $Domain;          Name = 'ForestDnsZones' }
        @{ Zone = "_msdcs.$Domain"; Name = 'gc' }
    )
    foreach ($r in $records) {
        if (-not (Get-DnsServerZone -Name $r.Zone -ErrorAction SilentlyContinue)) { continue }
        $have = @(Get-DnsServerResourceRecord -ZoneName $r.Zone -Name $r.Name -RRType A -ErrorAction SilentlyContinue |
            Where-Object { $_.RecordData.IPv4Address.IPAddressToString -eq $Address })
        if ($have.Count -eq 0) { Add-DnsServerResourceRecordA -ZoneName $r.Zone -Name $r.Name -IPv4Address $Address }
    }
}

function Get-LabTailnetDnsRecords {
    # A/AAAA records in the domain's zones that point at a Tailscale address.
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Domain)
    Import-Module DnsServer
    foreach ($z in @($Domain, "_msdcs.$Domain")) {
        if (-not (Get-DnsServerZone -Name $z -ErrorAction SilentlyContinue)) { continue }
        foreach ($t in 'A', 'AAAA') {
            foreach ($r in @(Get-DnsServerResourceRecord -ZoneName $z -RRType $t -ErrorAction SilentlyContinue)) {
                $ip = if ($t -eq 'A') { $r.RecordData.IPv4Address.IPAddressToString } else { $r.RecordData.IPv6Address.IPAddressToString }
                if (Test-LabTailnetAddress -Address $ip) { [pscustomobject]@{ Zone = $z; Record = $r; Name = $r.HostName; Address = $ip } }
            }
        }
    }
}

function Remove-LabTailnetDnsRecords {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Domain)
    $n = 0
    foreach ($x in @(Get-LabTailnetDnsRecords -Domain $Domain)) {
        Remove-DnsServerResourceRecord -ZoneName $x.Zone -InputObject $x.Record -Force; $n++
    }
    $n
}

Export-ModuleMember -Function Install-LabDirectoryFeatures, Wait-LabADReady, New-LabOrganizationalUnits,
    New-LabGroups, New-LabAccount, New-LabAccounts, Add-LabGroupMember, Set-LabDomainJoinDelegation,
    Set-LabComputersContainer, Set-LabDnsServerConfiguration, Add-LabSiteSubnet, Set-LabTimeSource,
    Initialize-LabLaps, Add-LabUpnSuffix, Get-LabFsmoHolders,
    Set-LabDcSingleHomed, Get-LabTailnetDnsRecords, Remove-LabTailnetDnsRecords
