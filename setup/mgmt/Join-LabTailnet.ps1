#Requires -Version 7.2
#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Joins the hand-built MGMT-00 to the site's tailnet (site.yaml tailscale.enabled).

.DESCRIPTION
    Pipeline-built machines join during their bootstrap; MGMT-00 is built before
    the vault exists, so it joins here, once, after Initialize-LabVault. Same
    settings as every other lab machine (Lab.System Install-LabTailscale):
    --unattended --accept-routes=false --accept-dns=false, the Tailscale adapter
    kept out of DNS, Remote Desktop allowed on that adapter only.

    The key in the vault must be reusable, tagged and NOT ephemeral: an ephemeral
    device drops off the tailnet when it's offline and can't rejoin.

.EXAMPLE
    ./setup/mgmt/Join-LabTailnet.ps1      # elevated PowerShell 7
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
foreach ($m in 'Lab.Inventory', 'Lab.System') {
    Import-Module (Join-Path $repo "platform/modules/$m/$m.psm1") -Force -DisableNameChecking
}
Import-Module Microsoft.PowerShell.SecretManagement, SecretManagement.KeePass, powershell-yaml
$inv = Import-LabInventory -ProductPath (Join-Path $repo 'inventory/lab.yaml') -SitePath (Join-Path $repo 'inventory/site.yaml')
if (-not $inv.tailscale.enabled) { Write-Host 'site.yaml has tailscale.enabled false (or unset); nothing to do.'; return }

$vault = $inv.secrets.vault
$name  = $inv.secrets.entries.tailscale_authkey
Unlock-SecretVault -Name $vault -Password (Read-Host "KeePass master password for $vault" -AsSecureString)
$key = Get-Secret -Vault $vault -Name $name -AsPlainText -ErrorAction SilentlyContinue
if (-not $key) { throw "The vault has no $name. Run ./setup/mgmt/Initialize-LabVault.ps1 (it asks for the key when tailscale.enabled is true)." }
Install-LabTailscale -AuthKey $key -Hostname $env:COMPUTERNAME
