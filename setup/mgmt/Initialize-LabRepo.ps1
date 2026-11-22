#Requires -Version 7.2
<#
.SYNOPSIS
    Puts the repo where the pipeline expects it on MGMT-00, as a git repository,
    with a git identity (runbook step 5).

.DESCRIPTION
    Run from any copy of the repo (a clone, an extracted zip, a copied folder)
    on MGMT-00, in a normal PowerShell 7 window, after Install-MgmtTools.ps1.
    1. Copies this folder to the repo path from lab.yaml (handover.repo_path,
       C:\MidCoastLab\repo) unless it is already there, including site.yaml.
    2. Makes it a git repository if it isn't one (a copied or extracted folder
       has no .git), sets core.filemode=false (a clone copied from Linux would
       otherwise show every .sh file as modified), and commits everything. You don't need a remote: the
       pipeline only needs the local history. Add a private remote later if you
       want a copy elsewhere (README, Requirements).
    3. Sets git's user.name and user.email for your account, from site.yaml's
       administrator (given name, surname, <username>@<tenant domain>), unless
       you set them already.
    4. Runs Test-LabInventory.ps1 from the new location.

.EXAMPLE
    cd C:\Users\LabAdmin\Downloads\midcoast-labs
    ./setup/mgmt/Initialize-LabRepo.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$source = (Resolve-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent)).Path
Import-Module (Join-Path $source 'platform/modules/Lab.Inventory/Lab.Inventory.psm1') -Force -DisableNameChecking
Import-Module powershell-yaml -ErrorAction Stop

$sitePath = Join-Path $source 'inventory/site.yaml'
if (-not (Test-Path $sitePath)) { throw "No inventory/site.yaml in $source. Copy your filled-in site.yaml into the repo first (README checklist, step 5)." }
$inv    = Import-LabInventory -ProductPath (Join-Path $source 'inventory/lab.yaml') -SitePath $sitePath
$target = [string] (Get-LabRoleDefinition -Inventory $inv -Role 'MGMT').handover.repo_path
if (-not (Get-Command git -ErrorAction SilentlyContinue)) { throw 'git is not on the PATH. Run setup/mgmt/Install-MgmtTools.ps1 first, then open a new window.' }

# ── 1. Put the repo at its path ───────────────────────────────────────────
$same = (Test-Path $target) -and ((Resolve-Path $target).Path.TrimEnd('\') -eq $source.TrimEnd('\'))
if ($same) {
    Write-Host "Repo is already at $target"
} elseif ((Test-Path $target) -and (Get-ChildItem -Path $target -Force | Select-Object -First 1)) {
    throw "$target already exists and isn't empty. Run this script from that copy instead, or move it out of the way."
} else {
    # Copy, not move: the source may be a mounted share or a folder you want to keep.
    Write-Host "Copying $source -> $target"
    New-Item -ItemType Directory -Path $target -Force | Out-Null
    Get-ChildItem -Path $source -Force | Copy-Item -Destination $target -Recurse -Force
}

# ── 2. A git repository with everything committed ─────────────────────────
Push-Location $target
try {
    # ./orchestration/Lab.Orchestration.psm1 holds Set-LabGitIdentity; import it from the final location.
    Import-Module (Join-Path $target 'orchestration/Lab.Orchestration.psm1') -Force -DisableNameChecking
    Write-Host (Set-LabGitIdentity -Inventory $inv)
    if (-not (Test-Path (Join-Path $target '.git'))) {
        & git init -q
        if ($LASTEXITCODE -ne 0) { throw 'git init failed.' }
        Write-Host "Initialised a git repository in $target (no remote; the pipeline doesn't need one)"
    }
    # A clone made on Linux and copied here keeps core.filemode=true, and every
    # .sh file then shows as modified on Windows (issue #22).
    Import-Module (Join-Path $target 'platform/modules/Lab.System/Lab.System.psm1') -Force -DisableNameChecking
    Write-Host (Set-LabGitRepoConfig -Path $target)
    & git add -A
    if (& git status --porcelain) {
        & git commit -q -m "MidCoast Lab: $($inv.site.name)"
        if ($LASTEXITCODE -ne 0) { throw 'git commit failed.' }
        Write-Host 'Committed the working tree'
    } else { Write-Host 'Nothing to commit' }
    # Secrets and state must never be in the repo; .gitignore keeps them out.
    $tracked = @(& git ls-files -- '*.kdbx' '*.tfstate' 'inventory/resolved')
    if ($tracked.Count -gt 0) { throw "These files must not be committed: $($tracked -join ', '). Remove them from git (git rm --cached <file>) and commit again." }

    # ── 3. Check the inventory from here ──────────────────────────────────
    & (Join-Path $target 'orchestration/Test-LabInventory.ps1')
    if ($LASTEXITCODE -ne 0) { throw 'Inventory validation failed; fix inventory/site.yaml and re-run.' }
} finally { Pop-Location }

Write-Host @"

Repo ready at $target.
Next (runbook step 6): the vault.
    cd $target
    ./setup/mgmt/Initialize-LabVault.ps1 -DatabasePath $((Get-LabRoleDefinition -Inventory $inv -Role 'MGMT').handover.vault_path)
"@ -ForegroundColor Green
