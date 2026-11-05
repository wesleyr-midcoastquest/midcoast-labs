#Requires -Version 5.1
<#
.SYNOPSIS
    MGMT role. Called by bootstrap.ps1 once per stage; returns the next stage.

.DESCRIPTION
    Start -> Join -> Finalize

      Start     toolchain (mgmt-tools.ps1), Remote Desktop for admins
      Join      join the domain into the MGMT placement OU, with svc-domainjoin
      Finalize  Group Policy (including LAPS), then validation

    The handover of the repo, Terraform state and vault is NOT done here; the
    outgoing MGMT pushes those during rotation (Invoke-LabMgmtRotation.ps1).

    Secrets used: svc-domainjoin; the Tailscale auth key, when site.yaml tailscale.enabled
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] $Metadata,
    [Parameter(Mandatory)] $Inventory,
    [Parameter(Mandatory)] [string] $Stage
)

$ErrorActionPreference = 'Stop'
$ad  = $Inventory.identity.active_directory
$def = Get-LabRoleDefinition -Inventory $Inventory -Role 'MGMT'

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
            Write-LabLog "DNS server and Netlogon limited to $($Metadata.ipv4)"
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
        # MGMT runs the pipeline's scripts locally. Windows client editions
        # default to Restricted; RemoteSigned is what the hand-built MGMT-00 uses
        # (runbook step 5).
        # Bootstrap itself runs with -ExecutionPolicy Bypass, so Set-ExecutionPolicy
        # sets the machine policy and then raises "Security error" ("overridden by
        # a more specific scope"). Expected here: ignore it and verify the result.
        try { Set-ExecutionPolicy -Scope LocalMachine -ExecutionPolicy RemoteSigned -Force -ErrorAction Stop } catch { }
        $machinePolicy = Get-ExecutionPolicy -Scope LocalMachine
        if ($machinePolicy -ne 'RemoteSigned') { throw "Couldn't set the LocalMachine execution policy to RemoteSigned (it is $machinePolicy)." }
        $rsat = if ($def.rsat) { @($def.rsat) } else { @('standard') }
        & (Join-Path $PSScriptRoot 'mgmt-tools.ps1') -Versions $def.software_versions -Rsat $rsat | Out-Null

        # Remote Desktop, so an admin (<user>-a) can sign in to finish the
        # handover. Network Level Authentication stays on. Allowed only from the lab
        # subnet and site.yaml network.remote_desktop_from.
        # The Terminal Services provider (as Settings does) rather than the registry
        # alone; the service set to start automatically; the firewall rules found by
        # their language-independent group, and their absence is an error, not silence.
        $ts = Get-CimInstance -Namespace 'root\cimv2\TerminalServices' -ClassName Win32_TerminalServiceSetting
        $null = Invoke-CimMethod -InputObject $ts -MethodName SetAllowTSConnections -Arguments @{ AllowTSConnections = 1; ModifyFirewallException = 0 }
        Set-ItemProperty -Path 'HKLM:\System\CurrentControlSet\Control\Terminal Server' -Name fDenyTSConnections -Value 0
        Set-ItemProperty -Path 'HKLM:\System\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp' -Name UserAuthentication -Value 1
        Set-Service -Name TermService -StartupType Automatic
        Start-Service -Name TermService
        $rdpRules = @(Get-NetFirewallRule -Group '@FirewallAPI.dll,-28752' -Direction Inbound -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -like 'RemoteDesktop-UserMode-In-*' })
        if ($rdpRules.Count -eq 0) { throw 'No built-in Remote Desktop firewall rules (RemoteDesktop-UserMode-In-*) found.' }
        # The lab subnet, plus site.yaml network.remote_desktop_from (e.g. Tailscale clients).
        $rdpFrom = @(@($Inventory.network.subnet) + @($Inventory.network.remote_desktop_from) | Where-Object { $_ } | Select-Object -Unique)
        $rdpRules | Set-NetFirewallRule -RemoteAddress $rdpFrom -Profile Any -Enabled True
        Write-LabLog "Toolchain installed; Remote Desktop enabled from $($rdpFrom -join ', ') ($(($rdpRules | ForEach-Object Name) -join ', '))"
        # Reboot so PATH and the PowerShell 7 module paths are clean for the next stages.
        return (Step 'Join' $true)
    }

    'Join' {
        $cs = Get-CimInstance -ClassName Win32_ComputerSystem
        if ($cs.PartOfDomain -and $cs.Domain -eq $ad.domain) {
            Write-LabLog "Already joined to $($ad.domain)"
            return (Step 'Finalize')
        }
        # DNS comes from metadata (the active DCs). Wait until the domain answers.
        Wait-LabCondition -Description "domain $($ad.domain) reachable" -TimeoutSeconds 1800 -Condition {
            [bool] (Resolve-DnsName -Name "_ldap._tcp.dc._msdcs.$($ad.domain)" -Type SRV -DnsOnly -ErrorAction Stop)
        }
        $domainDN = Get-LabDomainDN -Inventory $Inventory
        $ouPath   = ConvertTo-LabOUDistinguishedName -OUPath $Inventory.placement.roles.MGMT -DomainDN $domainDN
        $joiner   = Get-LabCredential -UserName "$($ad.netbios)\svc-domainjoin" -SecretName 'svc-domainjoin'
        Write-LabLog "Joining $($ad.domain) into $ouPath"
        Add-Computer -DomainName $ad.domain -OUPath $ouPath -Credential $joiner -Force
        return (Step 'Finalize' $true)
    }

    'Finalize' {
        # Remote Desktop for the Tier 0 admin group only. Its members are local
        # admins already (through Domain Admins), but an explicit grant doesn't
        # depend on that nesting. Standard accounts never sign in to MGMT: it's
        # a Tier 0 admin workstation.
        $rdpGroup = "$($ad.netbios)\SG-ROLE-DomainAdmins"
        $rdpUsers = Get-LocalGroup -SID 'S-1-5-32-555'   # Remote Desktop Users, any language
        if (-not (Get-LocalGroupMember -Group $rdpUsers -ErrorAction SilentlyContinue | Where-Object Name -eq $rdpGroup)) {
            Add-LocalGroupMember -Group $rdpUsers -Member $rdpGroup
            Write-LabLog "Granted Remote Desktop to $rdpGroup"
        }
        & gpupdate.exe /target:computer /force | Out-Null
        # Process LAPS now rather than waiting for the next policy cycle.
        if (Get-Command Invoke-LapsPolicyProcessing -ErrorAction SilentlyContinue) {
            try { Invoke-LapsPolicyProcessing } catch { Write-LabLog "LAPS processing deferred: $($_.Exception.Message)" -Level Warn }
        }
        Join-LabTailnetIfEnabled
        return (Step $null)
    }

    default { throw "Unknown MGMT stage '$Stage'." }
}
