#Requires -Version 7.2
<#
.SYNOPSIS
    Generates the site kit: a filled-in runbook and the Proxmox setup script,
    from inventory/lab.yaml + inventory/site.yaml.

.DESCRIPTION
    Run on any machine with PowerShell 7 and the powershell-yaml module (your
    workstation is fine; MGMT-00 doesn't exist yet). It validates the
    inventory, resolves it, and writes:

      out/site-kit/<site>/RUNBOOK.md        docs/runbook.md with every value filled in
      out/site-kit/<site>/proxmox-setup.sh  the Proxmox setup script with this site's values

    Re-run it after any change to site.yaml. out/ is gitignored.

.EXAMPLE
    Install-Module powershell-yaml -Scope CurrentUser    # once
    ./setup/New-LabSiteKit.ps1
#>
[CmdletBinding()]
param(
    [string] $SitePath,
    [string] $OutputRoot
)

$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
if (-not $SitePath)   { $SitePath   = Join-Path $repo 'inventory/site.yaml' }
if (-not $OutputRoot) { $OutputRoot = Join-Path $repo 'out/site-kit' }
Import-Module (Join-Path $repo 'platform/modules/Lab.Inventory/Lab.Inventory.psm1') -Force -DisableNameChecking
Import-Module powershell-yaml -ErrorAction Stop

# 1. Validate (product + site + resolved).
$findings = & (Join-Path $repo 'orchestration/Test-LabInventory.ps1') -SitePath $SitePath -PassThru
if (@($findings | Where-Object Level -eq 'Error').Count -gt 0) { throw 'Inventory validation failed; fix site.yaml first.' }

# 2. Resolve.
$inv = Import-LabInventory -ProductPath (Join-Path $repo 'inventory/lab.yaml') -SitePath $SitePath
$site = $inv.site.name
$outDir = Join-Path $OutputRoot $site
New-Item -ItemType Directory -Path $outDir -Force | Out-Null

$domainDN = Get-LabDomainDN -Inventory $inv
$mgmtDef  = Get-LabRoleDefinition -Inventory $inv -Role 'MGMT'
$mgmt00   = @($mgmtDef.slots | Where-Object id -eq $mgmtDef.initial.slot)[0]
$suffix   = $inv.identity.administrative_model.account_suffix
$admin    = @($inv.identity.administrative_model.administrators | Where-Object { [int] $_.tier -eq 0 })[0]
if (-not $admin) { throw 'site.yaml needs at least one tier 0 administrator.' }
$w11      = $inv.templates.windows_11

# 3. Token values for the runbook (docs/runbook.md uses {{token}}). Every token the
#    runbook uses must be here: Expand-LabTemplate refuses an unknown one.
$tokens = [ordered]@{
    'site.name'          = $site
    'site.time_zone'     = $inv.environment.time_zone
    'ad.domain'          = $inv.identity.active_directory.domain
    'ad.netbios'         = $inv.identity.active_directory.netbios
    'ad.dn'              = $domainDN
    'tenant.domain'      = $inv.identity.entra.tenant_domain
    'admin.account'      = "$($admin.username)$suffix"
    'tier0.group'        = 'SG-ROLE-DomainAdmins'
    'mgmt00.name'        = $mgmtDef.initial.hostname
    'mgmt00.name_lower'  = ([string] $mgmtDef.initial.hostname).ToLowerInvariant()   # the tailnet device name
    'mgmt00.vmid'        = $mgmt00.vmid
    'mgmt00.ip'          = $mgmt00.ipv4
    'mgmt.b.ip'          = @($mgmtDef.slots | Where-Object id -ne $mgmtDef.initial.slot)[0].ipv4
    'mgmt00.local_user'  = 'LabAdmin'
    'mgmt00.cores'       = $mgmtDef.cpu
    'mgmt00.memory_gb'   = [int] ($mgmtDef.memory_mb / 1024)
    'mgmt00.disk_gb'     = $mgmtDef.disk_gb
    'dc.a.ip'            = @((Get-LabRoleDefinition -Inventory $inv -Role 'DC').slots | Where-Object id -eq 'A')[0].ipv4
    'dc.b.ip'            = @((Get-LabRoleDefinition -Inventory $inv -Role 'DC').slots | Where-Object id -eq 'B')[0].ipv4
    'mgmt.ou_dn'         = ConvertTo-LabOUDistinguishedName -OUPath $inv.placement.roles.MGMT -DomainDN $domainDN
    'network.subnet'     = $inv.network.subnet
    'network.prefix'     = Get-LabPrefixLength -Inventory $inv
    'network.gateway'    = $inv.network.gateway
    'dns.forwarder'      = @($inv.identity.active_directory.dns_forwarders)[0]
    'static.start'       = $inv.network.static_range.start
    'static.end'         = $inv.network.static_range.end
    'proxmox.node'       = $inv.proxmox.node
    'proxmox.endpoint'   = $inv.proxmox.endpoint
    'proxmox.pool'       = $inv.proxmox.pool
    'proxmox.bridge'     = $inv.network.bridge
    'proxmox.vmid_base'  = $inv.proxmox.vmid_base
    'proxmox.vmid_last'  = [int] $inv.proxmox.vmid_base + 149
    'tailscale.enabled'  = $(if ($inv.tailscale.enabled) { 'true' } else { 'false' })
    'storage.vm'         = $inv.proxmox.storage.virtual_machines
    'storage.iso'        = $inv.proxmox.storage.iso_repository
    'iso.windows_server_2022'      = $inv.templates.windows_server_2022.build.iso
    'iso.windows_server_2022.file' = ([string] $inv.templates.windows_server_2022.build.iso -replace '^[^:]+:iso/', '')
    'iso.windows_11'     = $w11.build.iso
    'iso.windows_11.file' = ([string] $w11.build.iso -replace '^[^:]+:iso/', '')
    'iso.virtio'         = $w11.build.virtio_iso
    'iso.virtio.file'    = ([string] $w11.build.virtio_iso -replace '^[^:]+:iso/', '')
    'vault.name'         = $inv.secrets.vault
    'repo.path'          = $mgmtDef.handover.repo_path
    'repo.path_fwd'      = ([string] $mgmtDef.handover.repo_path).Replace('\', '/')
    'lab.root'           = ([string] $mgmtDef.handover.repo_path) -replace '[\\/][^\\/]+$', ''
    'vault.path'         = $mgmtDef.handover.vault_path
    'state.path'         = $inv.terraform.state.path
}

function Expand-LabTemplate([string] $Text, $Map) {
    $missing = [System.Collections.Generic.List[string]]::new()
    $out = [regex]::Replace($Text, '\{\{\s*([a-z0-9_.]+)\s*\}\}', {
        param($m)
        $k = $m.Groups[1].Value
        if ($Map.Contains($k)) { [string] $Map[$k] } else { $missing.Add($k); $m.Value }
    })
    if ($missing.Count -gt 0) { throw "Unknown template token(s): $(($missing | Sort-Object -Unique) -join ', ')" }
    $out
}

# 4. RUNBOOK.md
$raw = Get-Content -Raw (Join-Path $repo 'docs/runbook.md')
# Drop the "this page is a template" note first (it shows token syntax itself).
$raw = $raw -replace '(?s)<!-- TEMPLATE-NOTE -->.*?<!-- /TEMPLATE-NOTE -->\s*', ''
$runbook = Expand-LabTemplate $raw $tokens
$header = "<!-- Generated by setup/New-LabSiteKit.ps1 for site '$site' on $(Get-Date -Format 'yyyy-MM-dd HH:mm'). Re-generate after changing site.yaml. -->`n"
Set-Content -Path (Join-Path $outDir 'RUNBOOK.md') -Value ($header + $runbook) -Encoding utf8NoBOM

# 5. proxmox-setup.sh
function ConvertTo-ShellLiteral([string] $Value) { "'" + $Value.Replace("'", "'\''") + "'" }
# Plain hashtable: an [ordered] dictionary treats integer keys as positions.
$labIds = @{}
foreach ($t in $inv.templates.PSObject.Properties) {
    foreach ($id in ([int] $t.Value.vmid_first)..([int] $t.Value.vmid_last)) { $labIds[$id] = "$($t.Value.template_name)_versions" }
    if ($t.Value.build) { $labIds[[int] $t.Value.build.staging_vmid] = "build_staging_$($t.Value.template_name)" }
}
foreach ($srv in @($inv.servers)) {
    if ($srv.slots) { foreach ($sl in @($srv.slots)) { $labIds[[int] $sl.vmid] = "$($srv.role)_slot_$($sl.id)" } }
    else { $labIds[[int] $srv.vmid] = $srv.role }
}
$isoFiles = @($inv.templates.PSObject.Properties | ForEach-Object { $_.Value.build.iso; $_.Value.build.virtio_iso }) | Where-Object { $_ } | Sort-Object -Unique
$values = [ordered]@{
    SITE_NAME        = $site
    NODE             = $inv.proxmox.node
    POOL             = $inv.proxmox.pool
    USER_ID          = $inv.proxmox.service_account.user
    ROLE             = 'MidCoastProvisioner'
    TOKENS           = "$($inv.proxmox.service_account.token_name) $($inv.proxmox.service_account.packer_token_name)"
    TEMPLATE_STORAGE = $inv.proxmox.storage.templates
    VM_STORAGE       = $inv.proxmox.storage.virtual_machines
    ISO_STORAGE      = $inv.proxmox.storage.iso_repository
    BRIDGE           = $inv.network.bridge
    CLONE_MODE       = $inv.proxmox.clone_mode
    MGMT00_MEMORY_MIN = [string] $mgmtDef.memory_min_mb
    LAB_VMIDS        = (($labIds.Keys | Sort-Object | ForEach-Object { "$_=$($labIds[$_])" }) -join ' ')
    ISO_FILES        = ($isoFiles -join ' ')
    MGMT00_VMID      = [string] $mgmt00.vmid
    MGMT00_NAME      = $mgmtDef.initial.hostname
    MGMT00_CORES     = [string] $mgmtDef.cpu
    MGMT00_MEMORY    = [string] $mgmtDef.memory_mb
    MGMT00_DISK_GB   = [string] $mgmtDef.disk_gb
    MGMT00_ISO       = $w11.build.iso
    VIRTIO_ISO       = $w11.build.virtio_iso
    # MGMT-00's unattended install (answer CD built on the node).
    MGMT00_IP          = $mgmt00.ipv4
    MGMT00_PREFIX      = [string] (Get-LabPrefixLength -Inventory $inv)
    MGMT00_GATEWAY     = $inv.network.gateway
    MGMT00_DNS         = @($inv.identity.active_directory.dns_forwarders)[0]
    MGMT00_TIME_ZONE   = $inv.environment.time_zone
    MGMT00_IMAGE_INDEX = [string] $w11.build.image_index
    MGMT00_DRIVER_OS   = [string] $w11.build.driver_os
    MGMT00_LOCAL_USER  = 'LabAdmin'
    LAB_SUBNET         = $inv.network.subnet
    RDP_FROM           = (@($inv.network.remote_desktop_from | Where-Object { $_ }) -join ' ')
    TAILSCALE_ENABLED  = $(if ($inv.tailscale.enabled) { '1' } else { '0' })   # MGMT-00 may join with a one-time key
    VAULT_NAME       = $inv.secrets.vault
    TOKEN_SECRET_NAMES = "$($inv.secrets.entries.proxmox_terraform_token) (terraform token), $($inv.secrets.entries.proxmox_packer_token) (packer token)"
}
$block = ($values.Keys | ForEach-Object { "$_=$(ConvertTo-ShellLiteral ([string] $values[$_]))" }) -join "`n"
$script = (Get-Content -Raw (Join-Path $repo 'setup/proxmox/proxmox-setup.sh')).Replace('#@@SITE_VALUES@@', "# Site '$site', generated $(Get-Date -Format 'yyyy-MM-dd HH:mm' ) by New-LabSiteKit.ps1`n$block")
$script = $script -replace "`r`n", "`n"
$shPath = Join-Path $outDir 'proxmox-setup.sh'
[System.IO.File]::WriteAllText($shPath, $script, [System.Text.UTF8Encoding]::new($false))

Write-Host "`nSite kit for '$site' written to $outDir" -ForegroundColor Green
Write-Host "  RUNBOOK.md        follow it from step 1"
Write-Host "  proxmox-setup.sh  copy to $($inv.proxmox.node) and run as root: bash proxmox-setup.sh check, then bash proxmox-setup.sh"
Write-Host ("  Lab VMIDs {0}-{1}, addresses {2}-{3}, domain {4}" -f $inv.proxmox.vmid_base, ([int] $inv.proxmox.vmid_base + 149), $inv.network.static_range.start, $inv.network.static_range.end, $inv.identity.active_directory.domain)
