#Requires -Version 7.2
<#
.SYNOPSIS
    Puts the repo where the pipeline expects it on MGMT-00, as a git repository,
    with a git identity (runbook step 5).

.DESCRIPTION
    Run from any copy of the repo (a clone, an extracted zip, a copied folder)
    on MGMT-00, in a normal PowerShell 7 window, after Install-MgmtTools.ps1.
    The site's files (site.yaml, the ledger instances.yaml) belong in site\ in
    the repo folder: gitignored by the product, and a git repository of its own
    (a clone of your private site repo, or a new one). The old layout,
    inventory\site.yaml, still works with a warning. MIDCOAST_LAB_SITE is not
    accepted here: on MGMT the site must be inside the repo folder.
    1. Copies this folder to the repo path from lab.yaml (handover.repo_path,
       C:\MidCoastLab\repo) unless it is already there, site\ included.
    2. Makes site\ a git repository if it isn't one, starts an empty ledger
       there if it has none, and commits site.yaml and instances.yaml. In the
       old layout there is no site repo, and both files are committed in the
       product repo as before.
    3. Makes the product folder a git repository if it isn't one (a copied or
       extracted folder has no .git), sets core.filemode=false in both repos (a
       clone copied from Linux would otherwise show every .sh file as modified),
       and commits everything. You don't need a remote: the pipeline only needs
       the local history. Add a private remote later if you want a copy
       elsewhere (README, Requirements). It refuses if the product repo tracks
       a site file, secrets or state.
    4. Sets git's user.name and user.email for your account, from site.yaml's
       administrator (given name, surname, <username>@<tenant domain>), unless
       you set them already.
    5. Runs Test-LabInventory.ps1 from the new location.

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

# On MGMT the site lives inside the repo folder, so the handover carries it.
if ($env:MIDCOAST_LAB_SITE) { throw "MIDCOAST_LAB_SITE is set ($env:MIDCOAST_LAB_SITE). On MGMT the site must be the site\ folder in the repo: copy it there and clear the variable." }
$siteDir  = Get-LabSiteDirectory -RepoRoot $source
$sitePath = Join-Path $siteDir 'site.yaml'
if (-not (Test-Path $sitePath)) { throw "No site\site.yaml in $source. Put your filled-in site.yaml (or a clone of your site repo) in site\ first (README checklist, step 5)." }
$oldLayout = (Split-Path $siteDir -Leaf) -eq 'inventory'
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

# ── 2. The site's own repository ──────────────────────────────────────────
Push-Location $target
try {
    # ./orchestration/Lab.Orchestration.psm1 holds Set-LabGitIdentity; import it from the final location.
    Import-Module (Join-Path $target 'orchestration/Lab.Orchestration.psm1') -Force -DisableNameChecking
    Write-Host (Set-LabGitIdentity -Inventory $inv)
    Import-Module (Join-Path $target 'platform/modules/Lab.System/Lab.System.psm1') -Force -DisableNameChecking
    $siteTarget = Join-Path $target ([IO.Path]::GetRelativePath($source, $siteDir))
    $ledger = Join-Path $siteTarget 'instances.yaml'
    if (-not (Test-Path $ledger)) {
        # A new site starts with no machines.
        Set-Content -Path $ledger -Encoding utf8NoBOM -Value @(
            '# Instance ledger. WRITTEN BY THE PIPELINE; do not edit by hand.'
            '# A new site starts empty; commit it after every pipeline run.'
            'instances: []'
            'templates: []')
        Write-Host "Started an empty ledger: $ledger"
    }
    if (-not $oldLayout) {
        if (-not (Test-Path (Join-Path $siteTarget '.git'))) {
            & git -C $siteTarget init -q
            if ($LASTEXITCODE -ne 0) { throw 'git init failed in site\.' }
            Write-Host "Initialised the site's git repository in $siteTarget (no remote; add your private site repo as origin to keep a copy elsewhere)"
        }
        Write-Host (Set-LabGitRepoConfig -Path $siteTarget)
        & git -C $siteTarget add -A
        if (& git -C $siteTarget status --porcelain) {
            & git -C $siteTarget commit -q -m "MidCoast Lab site: $($inv.site.name)"
            if ($LASTEXITCODE -ne 0) { throw 'git commit failed in site\.' }
            Write-Host 'Committed the site'
        } else { Write-Host 'Site: nothing to commit' }
    }

    # ── 3. The product repository, everything committed ──────────────────
    if (-not (Test-Path (Join-Path $target '.git'))) {
        & git init -q
        if ($LASTEXITCODE -ne 0) { throw 'git init failed.' }
        Write-Host "Initialised a git repository in $target (no remote; the pipeline doesn't need one)"
    }
    # A clone made on Linux and copied here keeps core.filemode=true, and every
    # .sh file then shows as modified on Windows (issue #22).
    Write-Host (Set-LabGitRepoConfig -Path $target)
    & git add -A
    if ($oldLayout) {
        # The old layout keeps the site in the product repo, as before; .gitignore
        # now lists inventory/site.yaml, so add it by name.
        & git add -f -- inventory/site.yaml inventory/instances.yaml
    }
    if (& git status --porcelain) {
        & git commit -q -m "MidCoast Lab: $($inv.site.name)"
        if ($LASTEXITCODE -ne 0) { throw 'git commit failed.' }
        Write-Host 'Committed the working tree'
    } else { Write-Host 'Nothing to commit' }
    # Secrets and state must never be in the repo; .gitignore keeps them out.
    $never = @('*.kdbx', '*.tfstate', 'inventory/resolved', 'site')
    if (-not $oldLayout) { $never += 'inventory/site.yaml' }   # the site's files belong in site\, its own repo
    $tracked = @(& git ls-files -- $never)
    if ($tracked.Count -gt 0) { throw "These files must not be committed in the product repo: $($tracked -join ', '). Remove them from git (git rm --cached <file>) and commit again." }

    # ── 4. Check the inventory from here ──────────────────────────────────
    & (Join-Path $target 'orchestration/Test-LabInventory.ps1')
    if ($LASTEXITCODE -ne 0) { throw "Inventory validation failed; fix $(Join-Path $siteTarget 'site.yaml') and re-run." }
} finally { Pop-Location }

Write-Host @"

Repo ready at $target.
Next (runbook step 6): the vault.
    cd $target
    ./setup/mgmt/Initialize-LabVault.ps1 -DatabasePath $((Get-LabRoleDefinition -Inventory $inv -Role 'MGMT').handover.vault_path)
"@ -ForegroundColor Green
