#Requires -Version 7.2
<#
.SYNOPSIS
    Resets the ledger and Terraform state after a lab has been torn down, so
    the pipeline can build again from nothing (runbook, "Starting over").

.DESCRIPTION
    proxmox-teardown.sh destroys the lab's VMs on Proxmox, but the ledger
    (instances.yaml, in the site folder) still lists the old DCs,
    MGMT and template versions, and C:\MidCoastLab\state still holds Terraform
    state for them. The next Invoke-LabPhase then believes the lab is deployed
    (issue #20). This script:
      1. Asks Proxmox about every VMID the ledger lists. It REFUSES to run if any
         listed instance or template still exists, so it can't wipe a live lab:
         retire machines with the rotations, or tear the site down first.
      2. Empties instances:, drops every template version that is gone from
         Proxmox (a version that still exists is kept), removes the Terraform
         state file and its backup, and the handover and CERT lock files.
      3. Commits the ledger in the site's repo (git -C site add + commit, or
         the product repo for the old inventory/ layout; push is left to you).
    Run it on the machine that will run the pipeline next (MGMT-00 of the new
    build), after Initialize-LabRepo.ps1. A fresh clone of your repo carries
    the old ledger too, so a new MGMT-00 needs it as much as an old one.

.PARAMETER PlanOnly
    Show what would change; write nothing.

.PARAMETER SkipProxmox
    Don't ask Proxmox whether the listed VMs exist (for a ledger that belongs
    to a Proxmox you can no longer reach). Dangerous with a live lab: without
    the check, nothing stops the reset. Prefer tearing down, then resetting.

.EXAMPLE
    ./orchestration/Reset-LabLedger.ps1 -PlanOnly
    ./orchestration/Reset-LabLedger.ps1
#>
[CmdletBinding()]
param(
    [switch] $PlanOnly,
    [switch] $SkipProxmox
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Lab.Orchestration.psm1') -Force -DisableNameChecking

$inv       = Get-LabResolvedInventory -NoExport
$path      = Get-LabLedgerPath
$instances = @(Get-LabInstances -Path $path)
$templates = @(Get-LabTemplateVersions -Path $path)
$state     = [string] $inv.terraform.state.path
$mgmt      = Get-LabMgmtDefinition -Inventory $inv
$locks     = @($mgmt.handover.lock_path, $mgmt.handover.cert_lock_path) | Where-Object { $_ }

if ($instances.Count -eq 0 -and $templates.Count -eq 0 -and -not (Test-Path $state)) {
    Write-Host 'The ledger is already empty and there is no Terraform state; nothing to reset.' -ForegroundColor Green
    return
}

# ── 1. Nothing listed may still exist ─────────────────────────────────────
$existing = @{}
if (-not $SkipProxmox) {
    $token = Get-LabPveToken -Inventory $inv
    $seen = @(Invoke-LabPveApi -Inventory $inv -Token $token -Method GET -Path '/cluster/resources?type=vm')
    foreach ($vm in $seen) { $existing[[int] $vm.vmid] = $vm }
    $alive = @()
    foreach ($i in $instances) { if ($existing.ContainsKey([int] $i.vmid)) { $alive += "$($i.name) (VMID $($i.vmid), $($i.state))" } }
    foreach ($t in $templates) { if ($existing.ContainsKey([int] $t.vmid)) { $alive += "template $($t.name) (VMID $($t.vmid), $($t.state))" } }
    $aliveInstances = @($instances | Where-Object { $existing.ContainsKey([int] $_.vmid) })
    if ($aliveInstances.Count -gt 0) {
        throw "These machines in the ledger still exist on Proxmox: $(@($alive) -join '; '). This script only resets a ledger whose lab is gone. Retire machines with the rotations, or run proxmox-teardown.sh on the node first."
    }
} else {
    Write-Warning 'Skipping the Proxmox check (-SkipProxmox): every listed VM is assumed gone, and every template version will be dropped.'
}

# ── 2. What changes ───────────────────────────────────────────────────────
$keepTemplates = @($templates | Where-Object { -not $SkipProxmox -and $existing.ContainsKey([int] $_.vmid) })
$dropTemplates = @($templates | Where-Object { $keepTemplates -notcontains $_ })
$files = @()
foreach ($f in @($state, "$state.backup") + $locks) { if ($f -and (Test-Path $f)) { $files += $f } }

Write-Host "Ledger: $path"
Write-Host "  instances removed : $($instances.Count)$(if ($instances.Count) { ' (' + (@($instances | ForEach-Object name) -join ', ') + ')' })"
Write-Host "  templates removed : $($dropTemplates.Count)$(if ($dropTemplates.Count) { ' (' + (@($dropTemplates | ForEach-Object name) -join ', ') + ')' })"
Write-Host "  templates kept    : $($keepTemplates.Count)$(if ($keepTemplates.Count) { ' (still on Proxmox: ' + (@($keepTemplates | ForEach-Object name) -join ', ') + ')' })"
Write-Host "  files removed     : $(if ($files.Count) { $files -join ', ' } else { 'none' })"
if ($PlanOnly) { Write-Host 'Plan only; nothing changed.' -ForegroundColor Yellow; return }

# ── 3. Do it ──────────────────────────────────────────────────────────────
foreach ($f in $files) { Remove-Item -Path $f -Force; Write-Host "Removed $f" }
Save-LabLedger -Instances @() -Templates $keepTemplates
Write-Host "Reset $path"

# The ledger is committed where it lives: the site's repo (site\), or the
# product repo for the old inventory\ layout. git -C works for both.
$siteDir = Split-Path $path -Parent
$leaf    = Split-Path $path -Leaf
if (Get-Command git -ErrorAction SilentlyContinue) {
    & git -C $siteDir add -- $leaf
    if (& git -C $siteDir status --porcelain -- $leaf) {
        & git -C $siteDir commit -q -m "Reset the ledger after teardown ($($inv.site.name))" -- $leaf
        if ($LASTEXITCODE -eq 0) { Write-Host "Committed the ledger in $siteDir (git push when you are ready)." }
        else { Write-Warning "git commit failed; commit $path yourself." }
    } else { Write-Host 'Ledger unchanged in git.' }
} else { Write-Warning "git is not on the PATH; commit $path yourself." }

Write-Host "`nDone. The next Invoke-LabPhase.ps1 -Phase 1 builds a new forest." -ForegroundColor Green
