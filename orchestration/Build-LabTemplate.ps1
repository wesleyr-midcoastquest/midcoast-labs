#Requires -Version 7.2
<#
.SYNOPSIS
    Builds a new version of a golden template (WIN2022-TEMPLATE or
    WIN11-TEMPLATE) with Packer.

.DESCRIPTION
    Templates are versioned, because VMs are linked clones of the version they
    were built from and Proxmox can't delete a template that has linked clones.
    1. Validates inventory and the site; deletes superseded versions that no VM
       uses any more.
    2. Removes any leftover staging VM, then runs Packer at the template's
       staging VMID (vmid_base + 149 for Server 2022, + 148 for Windows 11).
    3. On success: full-clones staging into the next free VMID of the template's
       range as <family>-<YYMMDD>-<NN>, converts it to a template, records it in
       the ledger as current (the previous version becomes superseded), and
       deletes staging.
    New VMs clone the current version; existing VMs keep theirs until they are
    replaced. A failed build changes nothing.

    Run monthly, or after critical security updates.

.EXAMPLE
    ./orchestration/Build-LabTemplate.ps1                        # WIN2022-TEMPLATE
.EXAMPLE
    ./orchestration/Build-LabTemplate.ps1 -Template windows_11   # WIN11-TEMPLATE
#>
[CmdletBinding()]
param(
    [ValidateSet('windows_server_2022', 'windows_11')] [string] $Template = 'windows_server_2022'
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Lab.Orchestration.psm1') -Force -DisableNameChecking

# A transcript, like the other orchestration scripts: a build takes an hour or two, and
# if MGMT restarts meanwhile (Windows Update), this is where to see how far it got.
$runLog = Join-Path 'C:\ProgramData\MidCoastLab\Logs\Orchestration' ("template-$Template-{0}.txt" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
New-Item -ItemType Directory -Path (Split-Path $runLog) -Force | Out-Null
Start-Transcript -Path $runLog | Out-Null
trap { try { Stop-Transcript | Out-Null } catch { }; break }
$repo = Get-LabRepoRoot

$findings = & (Join-Path $PSScriptRoot 'Test-LabInventory.ps1') -PassThru
if (@($findings | Where-Object Level -eq 'Error').Count -gt 0) { throw 'Inventory validation failed.' }

# Live site pre-flight: Proxmox (node, storage, bridge, ISOs, pool, VMIDs) and lab addresses.

$site = & (Join-Path $PSScriptRoot 'Test-LabSite.ps1') -PassThru

if (@($site | Where-Object Level -eq 'Error').Count -gt 0) { throw 'Site pre-flight failed; see above.' }

$inv   = Get-LabResolvedInventory
Assert-LabNotHandedOver -Inventory $inv
$tpl   = $inv.templates.$Template
if (-not $tpl.build) { throw "templates.$Template has no build section in lab.yaml." }
$node  = $inv.proxmox.node
$sa    = $inv.proxmox.service_account
$stage = [int] $tpl.build.staging_vmid
$token = "$($sa.user)!$($sa.packer_token_name)=" + (Get-LabSecretText -Inventory $inv -Name $inv.secrets.entries.proxmox_packer_token)

# Free the range first: delete versions no VM uses any more.
Remove-LabUnusedTemplates -Inventory $inv -Token $token
$templates = @(Get-LabTemplateVersions -Path (Get-LabLedgerPath))
$previous  = Get-LabCurrentTemplate -Family $tpl.template_name -Templates $templates
$version   = New-LabTemplateVersion -Inventory $inv -Key $Template -Templates $templates -Token $token
$final     = [int] $version.vmid
Write-Host "Building $($version.name) (VMID $final)$(if ($previous) { "; current is $($previous.name)" })"

# Packer's cd_content needs an ISO tool; on Windows that's oscdimg (ADK Deployment Tools).
if (-not (Get-Command oscdimg.exe -ErrorAction SilentlyContinue)) {
    $adk = Get-ChildItem 'C:\Program Files (x86)\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\amd64\Oscdimg\oscdimg.exe' -ErrorAction SilentlyContinue
    if (-not $adk) { throw 'oscdimg.exe not found. Install the Windows ADK Deployment Tools (see docs/mgmt-00.md).' }
    $env:PATH = "$($adk.DirectoryName);$env:PATH"
}

# ── Clean up a staging VM from an earlier failed run ──────────────────────
$left = Test-LabPveVm -Inventory $inv -Token $token -VmId $stage
if ($left) {
    # Only ever delete a VM that is provably this lab's leftover build.
    $isBuild = $left.name -like '*-BUILD-*' -or $left.name -eq "$($tpl.template_name)-STAGING"   # Packer renames it on success
    if (@(([string] $left.tags) -split '[;,\s]+') -notcontains 'midcoast-lab' -or -not $isBuild) {
        throw "VMID $stage holds '$($left.name)', which isn't a MidCoast Lab build VM; refusing to delete it. Check proxmox.vmid_base in site.yaml."
    }
    Write-Host "Removing leftover staging VM $stage"
    $vm = Invoke-LabPveApi -Inventory $inv -Token $token -Method GET -Path "/nodes/$node/qemu/$stage/status/current"
    if ($vm.status -eq 'running') {
        Wait-LabPveTask -Inventory $inv -Token $token -Upid (Invoke-LabPveApi -Inventory $inv -Token $token -Method POST -Path "/nodes/$node/qemu/$stage/status/stop")
    }
    Wait-LabPveTask -Inventory $inv -Token $token -Upid (Invoke-LabPveApi -Inventory $inv -Token $token -Method DELETE -Path "/nodes/$node/qemu/${stage}?purge=1&destroy-unreferenced-disks=1")
}

# ── Packer ────────────────────────────────────────────────────────────────
$env:PKR_VAR_proxmox_token_secret = Get-LabSecretText -Inventory $inv -Name $inv.secrets.entries.proxmox_packer_token
$env:PKR_VAR_local_admin_password = Get-LabSecretText -Inventory $inv -Name $inv.secrets.entries.local_administrator
$packerDir = Join-Path $repo 'packer/windows'
$env:PKR_VAR_template_key = $Template
$env:PKR_VAR_inventory_path = Get-LabResolvedPath   # resolved lab.yaml + site.yaml
$log = Join-Path $inv.logging.path ("Orchestration/packer-{0}.log" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
New-Item -ItemType Directory -Path (Split-Path $log) -Force | Out-Null
try {
    Push-Location $packerDir
    & packer init .
    if ($LASTEXITCODE -ne 0) { throw 'packer init failed.' }
    & packer validate .
    if ($LASTEXITCODE -ne 0) { throw 'packer validate failed.' }
    $env:PACKER_LOG = '1'; $env:PACKER_LOG_PATH = $log
    & packer build -on-error=cleanup .
    $buildExit = $LASTEXITCODE
    if ($buildExit -ne 0) { throw "packer build failed; nothing changed$(if ($previous) { " ($($previous.name) is still current)" }). Log: $log" }
} finally {
    Pop-Location
    Remove-Item Env:\PKR_VAR_proxmox_token_secret, Env:\PKR_VAR_local_admin_password, Env:\PKR_VAR_template_key, Env:\PKR_VAR_inventory_path, Env:\PACKER_LOG, Env:\PACKER_LOG_PATH -ErrorAction SilentlyContinue
}

# ── Staging -> new template version ───────────────────────────────────────
$recorded = $false
try {
    Write-Host "Cloning staging $stage -> $final ($($version.name))"
    $upid = Invoke-LabPveApi -Inventory $inv -Token $token -Method POST -Path "/nodes/$node/qemu/$stage/clone" -Body @{
        newid   = $final
        name    = $version.name
        full    = 1
        storage = $inv.proxmox.storage.templates
        pool    = $inv.proxmox.pool
    }
    Wait-LabPveTask -Inventory $inv -Token $token -Upid $upid
    Wait-LabPveTask -Inventory $inv -Token $token -Upid (Invoke-LabPveApi -Inventory $inv -Token $token -Method POST -Path "/nodes/$node/qemu/$final/template")

    $desc = "$($tpl.operating_system) golden image $($version.name). Built $(Get-Date -Format 'yyyy-MM-dd HH:mm') from platform $(Get-LabPlatformVersion). Managed by Build-LabTemplate.ps1; deleted automatically once superseded and unused."
    $null = Invoke-LabPveApi -Inventory $inv -Token $token -Method PUT -Path "/nodes/$node/qemu/$final/config" -Body @{ description = $desc; tags = "midcoast-lab;template;$($tpl.build.tag)" }

    # Record it: the new version is current, the previous one superseded.
    # Re-read first: the build took an hour, and the ledger may have changed.
    $templates = @(Get-LabTemplateVersions -Path (Get-LabLedgerPath))
    $now = (Get-Date).ToUniversalTime().ToString('o')
    foreach ($t in $templates) {
        if ($t.family -eq $tpl.template_name -and $t.state -eq 'current') {
            $t.state = 'superseded'
            $t | Add-Member -NotePropertyName updated_utc -NotePropertyValue $now -Force
        }
    }
    $templates += $version
    Save-LabLedger -Instances @(Get-LabInstances -Path (Get-LabLedgerPath)) -Templates $templates
    $recorded = $true
} finally {
    if (-not $recorded) {
        # Don't leak a half-made version into the range: remove it if it's ours.
        $half = Test-LabPveVm -Inventory $inv -Token $token -VmId $final
        if ($half -and $half.name -eq $version.name) {
            Write-Warning "Build failed after cloning; removing the unrecorded $($version.name) (VMID $final)."
            try { Wait-LabPveTask -Inventory $inv -Token $token -Upid (Invoke-LabPveApi -Inventory $inv -Token $token -Method DELETE -Path "/nodes/$node/qemu/${final}?purge=1&destroy-unreferenced-disks=1") }
            catch { Write-Warning "Couldn't remove VMID ${final}: $($_.Exception.Message). Delete it by hand." }
        }
    }
}

Write-Host "Removing staging VM $stage"
Wait-LabPveTask -Inventory $inv -Token $token -Upid (Invoke-LabPveApi -Inventory $inv -Token $token -Method DELETE -Path "/nodes/$node/qemu/${stage}?purge=1&destroy-unreferenced-disks=1")

# The previous version goes as soon as nothing is cloned from it.
Remove-LabUnusedTemplates -Inventory $inv -Token $token

Write-Host "$($version.name) is ready at VMID $final and is now the current $($tpl.template_name)." -ForegroundColor Green
Write-Host "Commit the ledger: git add inventory/instances.yaml; git commit -m `"Template $($version.name)`""
Stop-Transcript | Out-Null
