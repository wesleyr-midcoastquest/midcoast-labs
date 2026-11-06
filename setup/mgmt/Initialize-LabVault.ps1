#Requires -Version 7.2
<#
.SYNOPSIS
    Creates the KeePass vault if needed, registers it for your account, and
    fills in every secret the inventory names (runbook step 6; again for each
    new account or MGMT).

.DESCRIPTION
    1. If the database doesn't exist yet, creates it with keepassxc-cli (asks
       for a new master password, twice). Keep that password outside the lab:
       without it and the .kdbx, the lab's secrets are gone.
    2. Registers the database as the SecretManagement vault named in lab.yaml
       (secrets.vault) for the account running this script, and unlocks it.
    3. For each secret the inventory names:
         - Proxmox token secrets: asks you (paste from proxmox-setup.sh's output)
         - the Tailscale auth key, when site.yaml tailscale.enabled: asks you
         - everything else: generates a random 24-character password
       Existing entries are never changed.
    4. Sets your git identity from site.yaml (Set-LabGitIdentity), since this
       runs once per account on every MGMT.

    Run it again on a new MGMT, or as a new account: it then only registers the
    existing vault and reports every entry as 'exists'.

.PARAMETER DatabasePath
    The .kdbx file, outside the repo: lab.yaml handover.vault_path
    (C:\MidCoastLab\MidCoastLab.kdbx).

.EXAMPLE
    ./setup/mgmt/Initialize-LabVault.ps1 -DatabasePath C:\MidCoastLab\MidCoastLab.kdbx
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $DatabasePath
)

$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
Import-Module (Join-Path $repo 'orchestration/Lab.Orchestration.psm1') -Force -DisableNameChecking
Import-Module Microsoft.PowerShell.SecretManagement, SecretManagement.KeePass
$inv   = Import-LabInventory -ProductPath (Join-Path $repo 'inventory/lab.yaml') -SitePath (Join-Path $repo 'inventory/site.yaml')
$vault = $inv.secrets.vault
$e     = $inv.secrets.entries

function Read-Password([string] $Prompt) {
    # A SecureString from the console, as plain text for the tools that need it.
    [System.Net.NetworkCredential]::new('', (Read-Host $Prompt -AsSecureString)).Password
}

# ── 1. The database ───────────────────────────────────────────────────────
if (-not (Test-Path $DatabasePath)) {
    $cli = Join-Path $env:ProgramFiles 'KeePassXC\keepassxc-cli.exe'
    if (-not (Test-Path $cli)) { throw "KeePassXC isn't installed ($cli), so the vault can't be created. Run setup/mgmt/Install-MgmtTools.ps1 first." }
    Write-Host "Creating $DatabasePath. Choose a strong master password and keep it outside the lab." -ForegroundColor Yellow
    do {
        $pw1 = Read-Password 'New master password'
        $pw2 = Read-Password 'Repeat it'
        if ($pw1 -ne $pw2) { Write-Host "  They don't match; again." -ForegroundColor Yellow }
        elseif ($pw1.Length -lt 12) { Write-Host '  Use at least 12 characters.' -ForegroundColor Yellow; $pw2 = $null }
    } until ($pw1 -eq $pw2 -and $pw1.Length -ge 12)
    New-Item -ItemType Directory -Path (Split-Path $DatabasePath -Parent) -Force | Out-Null
    # keepassxc-cli reads the password and its confirmation from stdin.
    $out = ("$pw1`n$pw1`n" | & $cli db-create -q -p $DatabasePath 2>&1)
    $pw1 = $pw2 = $null
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path $DatabasePath)) { throw "keepassxc-cli db-create failed: $($out -join ' ')" }
    Write-Host "Created $DatabasePath"
}

# ── 2. Register and unlock for this account ───────────────────────────────
if (-not (Get-SecretVault -Name $vault -ErrorAction SilentlyContinue)) {
    Register-SecretVault -Name $vault -ModuleName SecretManagement.KeePass -VaultParameters @{
        Path              = $DatabasePath
        UseMasterPassword = $true
    }
    Write-Host "Registered vault $vault -> $DatabasePath for $env:USERNAME"
}
Unlock-SecretVault -Name $vault -Password (Read-Host "KeePass master password for $vault" -AsSecureString)

# ── 3. Entries ────────────────────────────────────────────────────────────
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
        Write-Host "  Tailscale auth key: make it REUSABLE, tagged (e.g. tag:midcoast-lab) and NOT ephemeral (leave 'Ephemeral' off)." -ForegroundColor Yellow
        Write-Host "  It goes to every lab machine; an ephemeral device drops off the tailnet when it's offline and can't rejoin." -ForegroundColor Yellow
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

# ── 4. Git identity for this account ──────────────────────────────────────
Write-Host "  $(Set-LabGitIdentity -Inventory $inv)"

Write-Host "`nVault $vault is ready for $env:USERNAME. Back up $DatabasePath and its master password outside the lab." -ForegroundColor Green
Write-Host "Pipeline scripts ask for the master password when the vault is locked (or run: Unlock-SecretVault -Name $vault)."
if ($inv.tailscale.enabled) {
    Write-Host "Tailscale auth keys expire. To replace it later (reusable, tagged, not ephemeral): Set-Secret -Vault $vault -Name $($e.tailscale_authkey) -Secret (Read-Host -AsSecureString 'New key')"
}
