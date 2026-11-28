#Requires -Version 7.2
<#
.SYNOPSIS
    Creates the KeePass vault if needed, registers it for your account, and
    fills in every secret the inventory names (runbook step 6; again for each
    new account or MGMT).

.DESCRIPTION
    1. If the database doesn't exist yet, creates it with keepassxc-cli (asks
       for a new master password, twice; at least 12 characters). Keep that
       password outside the lab: without it and the .kdbx, the lab's secrets
       are gone.
    2. Registers the database as the SecretManagement vault named in lab.yaml
       (secrets.vault) for the account running this script, and unlocks it.
       A wrong master password is asked again (three tries), and nothing is
       written until the vault really opens.
    3. For each secret the inventory names:
         - Proxmox token secrets: asks you (paste from proxmox-setup.sh's output)
         - the Tailscale auth key, when site.yaml tailscale.enabled: asks you
         - your administrators' <username> and <username>-a accounts: asks
           whether to generate each password or let you choose it (12+
           characters, three character classes); -GeneratePasswords skips the
           question and generates them all
         - everything else (built-in Administrator, DSRM, service accounts):
           generates a random 24-character password
       Existing entries are never changed.
    4. Sets your git identity from site.yaml (Set-LabGitIdentity), since this
       runs once per account on every MGMT.

    Run it again on a new MGMT, or as a new account: it then only registers the
    existing vault and reports every entry as 'exists'.

.PARAMETER DatabasePath
    The .kdbx file, outside the repo: lab.yaml handover.vault_path
    (C:\MidCoastLab\MidCoastLab.kdbx).

.PARAMETER GeneratePasswords
    Generate every account password without asking, including your own
    <username> and <username>-a accounts (read them later with
    Get-Secret -Vault <vault> -Name <account> -AsPlainText).

.EXAMPLE
    ./setup/mgmt/Initialize-LabVault.ps1 -DatabasePath C:\MidCoastLab\MidCoastLab.kdbx
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $DatabasePath,
    [switch] $GeneratePasswords
)

$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
Import-Module (Join-Path $repo 'orchestration/Lab.Orchestration.psm1') -Force -DisableNameChecking
Import-Module Microsoft.PowerShell.SecretManagement, SecretManagement.KeePass
$inv   = Import-LabInventory -ProductPath (Join-Path $repo 'inventory/lab.yaml') -SitePath (Get-LabSiteFile -RepoRoot $repo -Name site)
$vault = $inv.secrets.vault
$e     = $inv.secrets.entries

function Read-Password([string] $Prompt) {
    # A SecureString from the console, as plain text for the tools that need it.
    [System.Net.NetworkCredential]::new('', (Read-Host $Prompt -AsSecureString)).Password
}

function Test-PasswordRules([string] $Password, [int] $MinLength, [int] $MinClasses) {
    # Returns the first rule the password breaks, or $null when it passes.
    if ($Password.Length -lt $MinLength) { return "Use at least $MinLength characters." }
    $classes = @(($Password -cmatch '[A-Z]'), ($Password -cmatch '[a-z]'), ($Password -match '[0-9]'), ($Password -match '[^A-Za-z0-9]')) | Where-Object { $_ }
    if ($classes.Count -lt $MinClasses) { return "Use at least $MinClasses of: upper case, lower case, digits, symbols." }
    $null
}

function Read-NewPassword([string] $What, [int] $MinLength = 12, [int] $MinClasses = 1) {
    # Asks twice, states the rules before asking, and repeats until they're met.
    $rules = "at least $MinLength characters"
    if ($MinClasses -gt 1) { $rules += ", $MinClasses of: upper case, lower case, digits, symbols" }
    Write-Host "  $What ($rules):"
    while ($true) {
        $pw1 = Read-Password "  New $What"
        $problem = Test-PasswordRules $pw1 $MinLength $MinClasses
        if ($problem) { Write-Host "  $problem" -ForegroundColor Yellow; continue }
        $pw2 = Read-Password '  Repeat it'
        if ($pw1 -ne $pw2) { Write-Host "  They don't match; again." -ForegroundColor Yellow; continue }
        return $pw1
    }
}

# ── 1. The database ───────────────────────────────────────────────────────
$masterSecure = $null   # set when the database is created here; otherwise asked for below
if (-not (Test-Path $DatabasePath)) {
    $cli = Join-Path $env:ProgramFiles 'KeePassXC\keepassxc-cli.exe'
    if (-not (Test-Path $cli)) { throw "KeePassXC isn't installed ($cli), so the vault can't be created. Run setup/mgmt/Install-MgmtTools.ps1 first." }
    Write-Host "Creating $DatabasePath. Choose a strong master password and keep it outside the lab." -ForegroundColor Yellow
    $master = Read-NewPassword 'master password' -MinLength 12
    New-Item -ItemType Directory -Path (Split-Path $DatabasePath -Parent) -Force | Out-Null
    # keepassxc-cli reads the password and its confirmation from stdin.
    $out = ("$master`n$master`n" | & $cli db-create -q -p $DatabasePath 2>&1)
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path $DatabasePath)) { $master = $null; throw "keepassxc-cli db-create failed: $($out -join ' ')" }
    Write-Host "Created $DatabasePath"
    # The password you just chose unlocks the vault below; it isn't asked again.
    $masterSecure = ConvertTo-SecureString $master -AsPlainText -Force
    $master = $null
}

# ── 2. Register and unlock for this account ───────────────────────────────
if (-not (Get-SecretVault -Name $vault -ErrorAction SilentlyContinue)) {
    Register-SecretVault -Name $vault -ModuleName SecretManagement.KeePass -VaultParameters @{
        Path              = $DatabasePath
        UseMasterPassword = $true
    }
    Write-Host "Registered vault $vault -> $DatabasePath for $env:USERNAME"
}
# Unlock-SecretVault only warns on a wrong password, and every Set-Secret after
# it would then "succeed" without writing anything (issue #19). So: unlock,
# check with Test-SecretVault, and ask again, up to three times.
$unlocked = $false
for ($try = 1; $try -le 3 -and -not $unlocked; $try++) {
    if (-not $masterSecure) { $masterSecure = Read-Host "KeePass master password for $vault" -AsSecureString }
    Unlock-SecretVault -Name $vault -Password $masterSecure -WarningAction SilentlyContinue
    $masterSecure = $null
    $unlocked = [bool] (Test-SecretVault -Name $vault -WarningAction SilentlyContinue -ErrorAction SilentlyContinue)
    if (-not $unlocked) {
        if ($try -lt 3) { Write-Host "  That master password didn't open $DatabasePath; try again ($(3 - $try) left)." -ForegroundColor Yellow }
    }
}
if (-not $unlocked) { throw "Couldn't unlock vault $vault at $DatabasePath after 3 attempts. Nothing was written. Check the master password (or, for a database you just created and can't open, delete it and run this script again)." }
Write-Host "Unlocked vault $vault"

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
$generated += @($inv.identity.service_accounts | ForEach-Object name)
# Your own accounts: the passwords you will type at a logon screen, so you may
# choose them (AD's default policy: 7+ characters, 3 of 4 classes; the lab asks
# for 12+, which also satisfies the domain policy the DCs apply).
$chosen = @()
foreach ($a in @($inv.identity.administrative_model.administrators)) {
    $chosen += $a.username
    $chosen += "$($a.username)$($inv.identity.administrative_model.account_suffix)"
}
$prompted = @($e.proxmox_terraform_token, $e.proxmox_packer_token)
if ($inv.tailscale.enabled) { $prompted += $e.tailscale_authkey }
# Borrowed templates (site.yaml templates.shared_from) carry the owner lab's local
# Administrator password; this site needs it once per clone (1.7).
if ($null -ne $inv.proxmox.templates_from) { $prompted += $e.template_administrator }

$existing = @(Get-SecretInfo -Vault $vault | ForEach-Object Name)
foreach ($name in $prompted) {
    if ($existing -contains $name) { Write-Host "  $name exists"; continue }
    if ($name -eq $e.tailscale_authkey) {
        Write-Host "  Tailscale auth key: make it REUSABLE, tagged (e.g. tag:midcoast-lab) and NOT ephemeral (leave 'Ephemeral' off)." -ForegroundColor Yellow
        Write-Host "  It goes to every MGMT the pipeline builds; an ephemeral device drops off the tailnet when it's offline and can't rejoin." -ForegroundColor Yellow
    }
    if ($name -eq $e.template_administrator) {
        Write-Host "  This site borrows the templates of the lab at vmid_base $($inv.proxmox.templates_from). Paste THAT lab's local Administrator" -ForegroundColor Yellow
        Write-Host "  password (its vault: $($e.local_administrator)). Each clone gets this site's own password on first connection." -ForegroundColor Yellow
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
$pending = @($chosen | Where-Object { $existing -notcontains $_ })
if ($pending.Count -gt 0) {
    $generateAll = [bool] $GeneratePasswords
    if (-not $generateAll) {
        Write-Host "  Your accounts ($($pending -join ', ')) need passwords: these are the ones you type to sign in." -ForegroundColor Yellow
        Write-Host "  Generated ones are random 24-character strings you read from the vault (Get-Secret -Vault $vault -Name <account> -AsPlainText)."
        $answer = Read-Host '  Generate them all [G], or choose each one [C]? (G/c)'
        $generateAll = ($answer -notmatch '^[cC]')
    }
    foreach ($name in $pending) {
        if ($generateAll) {
            Set-Secret -Vault $vault -Name $name -Secret (New-LabPassword)
            Write-Host "  $name generated"
        } else {
            $pw = Read-NewPassword "password for $name" -MinLength 12 -MinClasses 3
            Set-Secret -Vault $vault -Name $name -Secret $pw
            $pw = $null
            Write-Host "  $name stored"
        }
    }
}
foreach ($name in $chosen) { if ($existing -contains $name) { Write-Host "  $name exists" } }

# ── 4. Git identity for this account ──────────────────────────────────────
Write-Host "  $(Set-LabGitIdentity -Inventory $inv)"

Write-Host "`nVault $vault is ready for $env:USERNAME. Back up $DatabasePath and its master password outside the lab." -ForegroundColor Green
Write-Host "Pipeline scripts ask for the master password when the vault is locked (or run: Unlock-SecretVault -Name $vault)."
if ($inv.tailscale.enabled) {
    Write-Host "Tailscale auth keys expire. To replace it later (reusable, tagged, not ephemeral): Set-Secret -Vault $vault -Name $($e.tailscale_authkey) -Secret (Read-Host -AsSecureString 'New key')"
}
