#Requires -Version 7.2
<#
.SYNOPSIS
    Registers the KeePass vault and fills in every secret the inventory names.

.DESCRIPTION
    1. Create an empty KeePass database in KeePassXC first (master password),
       e.g. C:\MidCoastLab\MidCoastLab.kdbx, outside the repo.
    2. Run this script. It registers the database as SecretManagement vault
       "<inventory.secrets.vault>", then for each required secret:
         - Proxmox token secrets: prompts you (paste from the setup script output)
         - the Tailscale auth key, when site.yaml tailscale.enabled: prompts you
         - everything else: generates a random 24-character password
       Existing entries are never overwritten.

.EXAMPLE
    ./setup/mgmt/Initialize-LabVault.ps1 -DatabasePath C:\MidCoastLab\MidCoastLab.kdbx
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $DatabasePath
)

$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
Import-Module (Join-Path $repo 'platform/modules/Lab.Inventory/Lab.Inventory.psm1') -Force -DisableNameChecking
Import-Module Microsoft.PowerShell.SecretManagement, SecretManagement.KeePass, powershell-yaml
$inv   = Import-LabInventory -ProductPath (Join-Path $repo 'inventory/lab.yaml') -SitePath (Join-Path $repo 'inventory/site.yaml')
$vault = $inv.secrets.vault
$e     = $inv.secrets.entries

if (-not (Test-Path $DatabasePath)) { throw "Create $DatabasePath in KeePassXC first." }
if (-not (Get-SecretVault -Name $vault -ErrorAction SilentlyContinue)) {
    Register-SecretVault -Name $vault -ModuleName SecretManagement.KeePass -VaultParameters @{
        Path              = $DatabasePath
        UseMasterPassword = $true
    }
    Write-Host "Registered vault $vault -> $DatabasePath"
}
Unlock-SecretVault -Name $vault -Password (Read-Host "KeePass master password for $vault" -AsSecureString)

function New-LabPassword([int] $Length = 24) {
    # At least one of each class; unattend- and cmd-safe symbols only.
    $sets = 'ABCDEFGHJKLMNPQRSTUVWXYZ', 'abcdefghijkmnopqrstuvwxyz', '23456789', '!#%+-=?@_'
    $all  = -join $sets
    $chars = @($sets | ForEach-Object { $_[[System.Security.Cryptography.RandomNumberGenerator]::GetInt32($_.Length)] })
    while ($chars.Count -lt $Length) { $chars += $all[[System.Security.Cryptography.RandomNumberGenerator]::GetInt32($all.Length)] }
    -join ($chars | Sort-Object { [System.Security.Cryptography.RandomNumberGenerator]::GetInt32([int]::MaxValue) })
}

$generated = @($e.local_administrator, $e.domain_administrator, $e.dsrm)
foreach ($a in @($inv.identity.administrative_model.administrators)) {
    $generated += $a.username
    $generated += "$($a.username)$($inv.identity.administrative_model.account_suffix)"
}
$generated += @($inv.identity.service_accounts | ForEach-Object name)
$prompted = @($e.proxmox_terraform_token, $e.proxmox_packer_token)
if ($inv.tailscale.enabled) { $prompted += $e.tailscale_authkey }

$existing = @(Get-SecretInfo -Vault $vault | ForEach-Object Name)
foreach ($name in $prompted) {
    if ($existing -contains $name) { Write-Host "  $name exists"; continue }
    if ($name -eq $e.tailscale_authkey) {
        Write-Host "  Tailscale auth key: make it reusable, tagged and NOT ephemeral (leave 'Ephemeral' off)." -ForegroundColor Yellow
        Write-Host "  An ephemeral device drops off the tailnet when it's offline and can't rejoin." -ForegroundColor Yellow
    }
    $v = Read-Host "Paste the secret for $name" -AsSecureString
    Set-Secret -Vault $vault -Name $name -SecureStringSecret $v
    Write-Host "  $name stored"
}
foreach ($name in $generated) {
    if ($existing -contains $name) { Write-Host "  $name exists"; continue }
    Set-Secret -Vault $vault -Name $name -Secret (New-LabPassword)
    Write-Host "  $name generated"
}
Write-Host "`nVault $vault is ready. Back up $DatabasePath and its master password."
if ($inv.tailscale.enabled) {
    Write-Host "Tailscale auth keys expire. To replace it later (reusable, tagged, not ephemeral): Set-Secret -Vault $vault -Name $($e.tailscale_authkey) -Secret (Read-Host -AsSecureString 'New key')"
}
