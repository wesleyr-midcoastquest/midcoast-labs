#Requires -Version 5.1
<#
.SYNOPSIS
    MGMT role. Called by bootstrap.ps1 once per stage; returns the next stage.

.DESCRIPTION
    Start -> Join -> Finalize

      Start     toolchain (mgmt-tools.ps1), Remote Desktop for admins
      Join      join the domain into the MGMT placement OU, with svc-domainjoin
      Finalize  Remote Desktop for the Tier 0 group, Group Policy (including
                LAPS), the tailnet, then validation

    The handover of the repo, Terraform state and vault is NOT done here; the
    outgoing MGMT pushes those during rotation (Invoke-LabMgmtRotation.ps1).
    The hand-built MGMT-00 gets the equivalent of these stages from
    setup/mgmt/Install-MgmtTools.ps1 and setup/mgmt/Join-LabDomain.ps1.

    Secrets used: svc-domainjoin; the Tailscale auth key, when site.yaml tailscale.enabled
    (MGMT is the one role with lab.yaml tailscale: true)
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
        # handover: from the lab subnet and site.yaml network.remote_desktop_from.
        $rdpFrom = @(@($Inventory.network.subnet) + @($Inventory.network.remote_desktop_from))
        Write-LabLog "Toolchain installed; $(Enable-LabRemoteDesktop -RemoteAddress $rdpFrom)"
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
        Write-LabLog (Grant-LabRemoteDesktopGroup -Group "$($ad.netbios)\SG-ROLE-DomainAdmins")
        & gpupdate.exe /target:computer /force | Out-Null
        # Process LAPS now rather than waiting for the next policy cycle.
        if (Get-Command Invoke-LapsPolicyProcessing -ErrorAction SilentlyContinue) {
            try { Invoke-LapsPolicyProcessing } catch { Write-LabLog "LAPS processing deferred: $($_.Exception.Message)" -Level Warn }
        }
        Join-LabTailnet -Inventory $Inventory -Metadata $Metadata
        return (Step $null)
    }

    default { throw "Unknown MGMT stage '$Stage'." }
}
