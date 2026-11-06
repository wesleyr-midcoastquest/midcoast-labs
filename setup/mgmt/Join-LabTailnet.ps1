#Requires -Version 7.2
#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Puts the hand-built MGMT-00 on the site's tailnet the way every lab machine
    is (site.yaml tailscale.enabled), with the reusable key from the vault
    (runbook step 6).

.DESCRIPTION
    Pipeline-built machines join during their bootstrap; MGMT-00 is built before
    the vault exists, so it gets this step here, once, after Initialize-LabVault.
    Same settings as every other lab machine (Lab.System Install-LabTailscale):
    --unattended --accept-routes=false --accept-dns=false, the Tailscale adapter
    kept out of DNS, Remote Desktop allowed on that adapter only, the AuthKey
    system policy and the MidCoastLab-Tailscale watchdog task, so a restart or
    an update can't log it out.

    If proxmox-setup.sh already joined MGMT-00 with a one-time key (runbook
    step 3), this re-authenticates it with the vault's reusable key and adds the
    policy and watchdog; the device keeps its name on the tailnet.

    The key in the vault must be reusable, tagged and NOT ephemeral: an ephemeral
    device drops off the tailnet when it's offline and can't rejoin.

.EXAMPLE
    ./setup/mgmt/Join-LabTailnet.ps1      # elevated PowerShell 7
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
Import-Module (Join-Path $repo 'orchestration/Lab.Orchestration.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $repo 'platform/modules/Lab.System/Lab.System.psm1') -Force -DisableNameChecking
Import-Module Microsoft.PowerShell.SecretManagement, SecretManagement.KeePass
$inv = Get-LabResolvedInventory -NoExport
if (-not $inv.tailscale.enabled) { Write-Host 'site.yaml has tailscale.enabled false (or unset); nothing to do.'; return }

# Get-LabSecretText asks for the vault's master password if it's locked.
$key = Get-LabSecretText -Inventory $inv -Name $inv.secrets.entries.tailscale_authkey
Write-Host (Install-LabTailscale -AuthKey $key -Hostname $env:COMPUTERNAME)
