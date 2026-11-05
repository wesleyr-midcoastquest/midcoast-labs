#Requires -Version 5.1
<#
.SYNOPSIS
    DC role. Called by bootstrap.ps1 once per stage; returns the next stage.

.DESCRIPTION
    metadata.dc_mode decides the path:
      Start turns on Remote Desktop (lab subnet, NLA) and installs AD DS and DNS.
      forest   Start -> Promote -> ConfigureDomain -> Finalize   (first DC ever)
      replica  Start -> Promote -> PostPromote     -> Finalize   (every other DC)

    Secrets used (delivered by the orchestrator):
      forest:  domain_administrator, dsrm, every admin and service account
      replica: dsrm, svc-labdeploy
      both:    the Tailscale auth key, when site.yaml tailscale.enabled
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] $Metadata,
    [Parameter(Mandatory)] $Inventory,
    [Parameter(Mandatory)] [string] $Stage
)

$ErrorActionPreference = 'Stop'
$ad      = $Inventory.identity.active_directory
$secrets = $Inventory.secrets.entries
$mode    = [string] $Metadata.dc_mode
if ($mode -notin 'forest', 'replica') { throw "metadata.dc_mode must be 'forest' or 'replica', got '$mode'." }

function Step([string] $Next, [bool] $Reboot = $false) {
    [pscustomobject]@{ Next = $Next; Reboot = $Reboot }
}

function Join-LabTailnetIfEnabled {
    # site.yaml tailscale.enabled: join the tailnet. A failure is logged as a
    # warning (TS-001 reports it); the lab works without the tailnet.
    param([switch] $Dc)
    if (-not $Inventory.tailscale.enabled) { return }
    try {
        $key = [System.Net.NetworkCredential]::new('', (Get-LabSecret -Name $Inventory.secrets.entries.tailscale_authkey)).Password
        if ($Dc) {
            # Before the adapter gets an address: AD and DNS stay on the lab address.
            Set-LabDcSingleHomed -Address $Metadata.ipv4 -Domain $Inventory.identity.active_directory.domain
            Write-LabLog "DNS records and Netlogon limited to $($Metadata.ipv4)"
        }
        Write-LabLog "Tailscale: $(Install-LabTailscale -AuthKey $key -Hostname $Metadata.hostname)"
        if ($Dc) {
            Start-Sleep -Seconds 30
            $n = Remove-LabTailnetDnsRecords -Domain $Inventory.identity.active_directory.domain
            if ($n -gt 0) { Write-LabLog "Removed $n DNS record(s) pointing at a Tailscale address" -Level Warn }
        }
    } catch {
        Write-LabLog "Tailscale skipped: $($_.Exception.Message)" -Level Warn
    }
}

switch ($Stage) {

    'Start' {
        # Remote Desktop for admins, from the lab subnet only, Network Level
        # Authentication on. (Who may sign in is AD's default for DCs: Administrators.)
        Set-ItemProperty -Path 'HKLM:\System\CurrentControlSet\Control\Terminal Server' -Name fDenyTSConnections -Value 0
        Set-ItemProperty -Path 'HKLM:\System\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp' -Name UserAuthentication -Value 1
        Set-Service -Name TermService -StartupType Automatic
        Start-Service -Name TermService
        $rdpRules = @(Get-NetFirewallRule -Group '@FirewallAPI.dll,-28752' -Direction Inbound -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -like 'RemoteDesktop-UserMode-In-*' })
        if ($rdpRules.Count -eq 0) { throw 'No built-in Remote Desktop firewall rules (RemoteDesktop-UserMode-In-*) found.' }
        $rdpRules | Set-NetFirewallRule -RemoteAddress $Inventory.network.subnet -Profile Any -Enabled True
        Write-LabLog "Remote Desktop enabled from $($Inventory.network.subnet)"

        $restart = Install-LabDirectoryFeatures
        Write-LabLog "AD DS and DNS features installed (restart needed: $restart)"
        return (Step 'Promote' $restart)
    }

    'Promote' {
        # Guard: an unexpected restart can re-enter this stage after promotion.
        if ((Get-CimInstance -ClassName Win32_ComputerSystem).DomainRole -ge 4) {
            Write-LabLog 'Already a domain controller; skipping promotion.'
            if ($mode -eq 'forest') { return (Step 'ConfigureDomain') } else { return (Step 'PostPromote') }
        }
        $dsrm = Get-LabSecret -Name $secrets.dsrm

        if ($mode -eq 'forest') {
            # The local Administrator becomes the domain Administrator, so give
            # it the domain Administrator password before promotion.
            $admin = Get-LocalUser | Where-Object { $_.SID.Value -like 'S-1-5-21-*-500' }
            Set-LocalUser -InputObject $admin -Password (Get-LabSecret -Name $secrets.domain_administrator)

            Write-LabLog "Creating forest $($ad.domain) ($($ad.netbios))"
            Install-ADDSForest `
                -DomainName $ad.domain `
                -DomainNetbiosName $ad.netbios `
                -ForestMode $ad.forest_mode `
                -DomainMode $ad.domain_mode `
                -InstallDns:$true `
                -CreateDnsDelegation:$false `
                -SafeModeAdministratorPassword $dsrm `
                -NoRebootOnCompletion:$true `
                -Force:$true | Out-Null
            return (Step 'ConfigureDomain' $true)
        }

        # Replica: wait until the domain answers through the DNS servers in
        # metadata (the active DCs), then join the replica set.
        $srv = "_ldap._tcp.dc._msdcs.$($ad.domain)"
        Wait-LabCondition -Description "domain $($ad.domain) reachable" -TimeoutSeconds 3600 -Condition {
            $records = Resolve-DnsName -Name $srv -Type SRV -DnsOnly -ErrorAction Stop
            $target  = @($records | Where-Object QueryType -eq 'SRV')[0].NameTarget
            (Test-NetConnection -ComputerName $target -Port 389 -WarningAction SilentlyContinue).TcpTestSucceeded
        }
        $deploy = Get-LabCredential -UserName "$($ad.netbios)\svc-labdeploy" -SecretName 'svc-labdeploy'
        $p = @{
            DomainName                    = $ad.domain
            Credential                    = $deploy
            InstallDns                    = $true
            CreateDnsDelegation           = $false
            SiteName                      = $ad.site
            SafeModeAdministratorPassword = $dsrm
            NoRebootOnCompletion          = $true
            Force                         = $true
        }
        if ($Metadata.replication_source) { $p.ReplicationSourceDC = $Metadata.replication_source }
        Write-LabLog "Promoting replica DC in $($ad.domain) from $($Metadata.replication_source)"
        Install-ADDSDomainController @p | Out-Null
        return (Step 'PostPromote' $true)
    }

    'ConfigureDomain' {
        # Forest root only: everything the domain needs, from inventory.
        Wait-LabADReady
        Set-LabDnsClient -Servers @('127.0.0.1')
        $da = Get-LabCredential -UserName "$($ad.netbios)\Administrator" -SecretName $secrets.domain_administrator

        Invoke-LabAsCredential -Credential $da -ScriptBlock {
            param($PlatformRoot)
            $ErrorActionPreference = 'Stop'
            foreach ($m in 'Lab.Logging', 'Lab.Inventory', 'Lab.System', 'Lab.AD') {
                Import-Module (Join-Path $PlatformRoot "modules\$m\$m.psm1") -Force -DisableNameChecking -Global
            }
            $inv = Get-LabInventory -Path (Join-Path $PlatformRoot 'inventory.json')
            Initialize-LabLogging -Path $inv.logging.path -RetentionDays ([int] $inv.logging.retention_days) -Category 'Bootstrap'
            Import-Module ActiveDirectory, DnsServer, GroupPolicy

            Set-LabDnsServerConfiguration -Inventory $inv
            Add-LabSiteSubnet             -Inventory $inv
            Add-LabUpnSuffix              -Inventory $inv
            New-LabOrganizationalUnits    -Inventory $inv
            New-LabGroups                 -Inventory $inv
            New-LabAccounts               -Inventory $inv
            foreach ($s in @($inv.identity.service_accounts | Where-Object delegation -eq 'domain_join')) {
                Set-LabDomainJoinDelegation -Inventory $inv -Account $s.name
            }
            Set-LabComputersContainer -Inventory $inv
            Initialize-LabLaps        -Inventory $inv
        } | Out-Null

        # This DC holds every FSMO role, so it is the PDC emulator.
        Set-LabTimeSource -Inventory $Inventory -Pdc
        Write-LabLog 'Domain configuration applied'
        return (Step 'Finalize')
    }

    'PostPromote' {
        Wait-LabADReady
        # Partners first, loopback last (never loopback alone on a replica).
        $partners = @($Metadata.dns_servers | Where-Object { $_ -ne $Metadata.ipv4 })
        Set-LabDnsClient -Servers (@($partners) + '127.0.0.1')
        Set-LabTimeSource -Inventory $Inventory
        Write-LabLog "Replica DC ready; DNS client: $((@($partners) + '127.0.0.1') -join ', ')"
        return (Step 'Finalize')
    }

    'Finalize' {
        # A new replica shares SYSVOL only after DFSR's initial sync. Wait for
        # it rather than letting validation fail a healthy DC.
        # Nudge DFSR to read its AD configuration now. Only a speed-up: DFSR
        # polls on its own, so it's best-effort (dfsrdiag.exe comes with the DFS
        # management tools, which a DC built before v1.3 may not have).
        try {
            if (Get-Command dfsrdiag.exe -ErrorAction SilentlyContinue) { & dfsrdiag.exe pollad 2>&1 | Out-Null }
            else { $null = Invoke-CimMethod -Namespace 'root\MicrosoftDFS' -ClassName DfsrConfig -MethodName PollDsNow -ErrorAction Stop }
        } catch { Write-LabLog "DFSR poll skipped: $($_.Exception.Message)" }
        Wait-LabCondition -Description 'SYSVOL ready and DFSR Normal' -TimeoutSeconds 1800 -IntervalSeconds 30 -Condition {
            $ready = (Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\Netlogon\Parameters' -Name SysvolReady -ErrorAction Stop).SysvolReady -eq 1
            $rf = Get-CimInstance -Namespace 'root\microsoftdfs' -ClassName DfsrReplicatedFolderInfo -Filter "ReplicatedFolderName='SYSVOL Share'" -ErrorAction Stop
            $ready -and $rf.State -eq 4
        }
        & gpupdate.exe /target:computer /force | Out-Null
        Join-LabTailnetIfEnabled -Dc
        # Let AD settle before validation. Right after promotion (and after the
        # DNS/Netlogon restarts of the Tailscale step), replication and Group
        # Policy queries can fail with credential errors for a few minutes; the
        # first real run failed REPL-001 that way and passed on -Retry.
        try {
            Wait-LabADReady -TimeoutSeconds 900
            Wait-LabCondition -Description 'replication and Group Policy queries answer' -TimeoutSeconds 900 -IntervalSeconds 30 -Condition {
                $null = Get-ADReplicationPartnerMetadata -Target $env:COMPUTERNAME -PartnerType Inbound -ErrorAction Stop
                $null = Get-GPInheritance -Target "OU=Domain Controllers,$(Get-LabDomainDN -Inventory $Inventory)" -ErrorAction Stop
                $true
            }
        } catch { Write-LabLog "AD still settling before validation: $($_.Exception.Message)" -Level Warn }
        return (Step $null)
    }

    default { throw "Unknown DC stage '$Stage'." }
}
