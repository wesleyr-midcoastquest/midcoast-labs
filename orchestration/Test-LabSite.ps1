#Requires -Version 7.2
<#
.SYNOPSIS
    Live pre-flight check of the site: does this Proxmox and this network
    match site.yaml, and is everything the lab will claim actually free?

.DESCRIPTION
    Runs from MGMT with the provisioning token. Checks:
      Proxmox  API and token, node, storages (content types), bridge, ISO files,
               pool; every lab VMID is either free or already the lab's own
               (in the pool, tagged midcoast-lab)
      Network  no device outside the lab answers on a lab address (ping + ARP),
               the gateway answers, the DNS forwarders resolve

    The token only sees VMs in the lab's pool, so for VMIDs it can't see it
    asks Proxmox whether the ID is free. If Proxmox won't say (permissions),
    that VMID is reported as unverified: the root-side check in the site kit's
    proxmox-setup.sh is authoritative.

    Invoke-LabPhase, Build-LabTemplate and Invoke-LabMgmtRotation run this
    automatically; errors stop them.

.EXAMPLE
    ./orchestration/Test-LabSite.ps1
.EXAMPLE
    ./orchestration/Test-LabSite.ps1 -SkipNetwork      # Proxmox checks only
#>
[CmdletBinding()]
param(
    [switch] $SkipNetwork,
    [switch] $PassThru
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Lab.Orchestration.psm1') -Force -DisableNameChecking

$inv       = Get-LabResolvedInventory -NoExport
$instances = @(Get-LabInstances -Path (Get-LabLedgerPath))
$pve       = $inv.proxmox
$node      = $pve.node
$findings  = [System.Collections.Generic.List[object]]::new()
function Add-Finding([string] $Level, [string] $Area, [string] $Message) {
    $findings.Add([pscustomobject]@{ Level = $Level; Area = $Area; Message = $Message })
}

function Invoke-Probe {
    # Like Invoke-LabPveApi, but returns the HTTP status instead of throwing.
    param([string] $Path)
    try {
        [pscustomobject]@{ Ok = $true; Status = 200; Data = (Invoke-LabPveApi -Inventory $inv -Token $token -Method GET -Path $Path); Message = '' }
    } catch {
        $status = 0
        try { $status = [int] $_.Exception.Response.StatusCode } catch { }
        $msg = $_.ErrorDetails.Message
        if (-not $msg) { $msg = $_.Exception.Message }
        [pscustomobject]@{ Ok = $false; Status = $status; Data = $null; Message = $msg }
    }
}

# ── This MGMT's repo ──────────────────────────────────────────────────────
# The pipeline commits the ledger and hands the git history to every new MGMT.
$repoRoot = Get-LabRepoRoot
if (-not (Test-Path (Join-Path $repoRoot '.git'))) {
    Add-Finding 'Error' 'Repo' "$repoRoot isn't a git repository (a copied folder, not a clone?). Run in it: git init; git add -A; git commit -m 'MidCoast Lab'  (runbook step 5)."
}

# ── Proxmox ───────────────────────────────────────────────────────────────
$token = Get-LabPveToken -Inventory $inv
$v = Invoke-Probe '/version'
if (-not $v.Ok) {
    Add-Finding 'Error' 'Proxmox' "API at $($pve.endpoint) rejected the provisioning token or is unreachable ($($v.Status)): $($v.Message)"
} else {
    Add-Finding 'Info' 'Proxmox' "API OK: Proxmox VE $($v.Data.version)"

    $nodes = Invoke-Probe '/nodes'
    if (-not $nodes.Ok -or @($nodes.Data | Where-Object node -eq $node).Count -eq 0) {
        Add-Finding 'Error' 'Proxmox' "Node '$node' not found (visible: $(@($nodes.Data | ForEach-Object node) -join ', '))."
    }

    $st = Invoke-Probe "/nodes/$node/storage"
    if ($st.Ok) {
        # Pairs, not a hash literal: sites often use one storage for templates and VMs.
        $need = @(
            @{ Name = $pve.storage.templates;        Content = 'images' }
            @{ Name = $pve.storage.virtual_machines; Content = 'images' }
            @{ Name = $pve.storage.iso_repository;   Content = 'iso' }
        )
        $seen = @{}
        foreach ($pair in $need) {
            $name = $pair.Name; $content = $pair.Content
            if ($seen.ContainsKey("$name|$content")) { continue }
            $seen["$name|$content"] = $true
            $s = @($st.Data | Where-Object storage -eq $name)[0]
            if (-not $s) { Add-Finding 'Error' 'Storage' "Storage '$name' isn't visible on $node (missing, not enabled on this node, or the token lacks access)." ; continue }
            if (@(([string] $s.content) -split ',') -notcontains $content) { Add-Finding 'Error' 'Storage' "Storage '$name' doesn't allow '$content' content (has: $($s.content))." }
            if ($s.PSObject.Properties.Name -contains 'active' -and -not $s.active) { Add-Finding 'Error' 'Storage' "Storage '$name' is not active on $node." }
        }
        # Linked clones (the default) need storage that can do them with raw disks.
        if ($inv.proxmox.clone_mode -ceq 'linked') {
            $ts = @($st.Data | Where-Object storage -eq $pve.storage.templates)[0]
            if ($ts -and $ts.type -notin 'lvmthin', 'zfspool', 'rbd') {
                Add-Finding 'Error' 'Storage' "Storage '$($ts.storage)' is type '$($ts.type)', which can't hold linked clones of the lab's templates. Use LVM-thin, ZFS or Ceph RBD, or set proxmox.clone_mode: full in site.yaml."
            }
        }
    } else { Add-Finding 'Error' 'Storage' "Couldn't list storage on ${node}: $($st.Message)" }

    $netw = Invoke-Probe "/nodes/$node/network"
    if ($netw.Ok) {
        if (@($netw.Data | Where-Object { $_.iface -eq $inv.network.bridge -and $_.type -match 'bridge' }).Count -eq 0) {
            Add-Finding 'Error' 'Network' "Bridge '$($inv.network.bridge)' not found on $node."
        }
    } else { Add-Finding 'Warning' 'Network' "Couldn't list network interfaces on $node (needs Sys.Audit): $($netw.Message)" }

    $isoStore = $pve.storage.iso_repository
    $iso = Invoke-Probe "/nodes/$node/storage/$isoStore/content?content=iso"
    if ($iso.Ok) {
        $volids = @($iso.Data | ForEach-Object volid)
        foreach ($t in $inv.templates.PSObject.Properties) {
            foreach ($f in @($t.Value.build.iso, $t.Value.build.virtio_iso) | Sort-Object -Unique) {
                if ($f -and $volids -cnotcontains $f) { <#case-sensitive, like Proxmox#> Add-Finding 'Error' 'ISO' "$f isn't on $isoStore (needed by $($t.Value.template_name)). Upload it, or fix isos in site.yaml." }
            }
        }
    } else { Add-Finding 'Error' 'ISO' "Couldn't list ISOs on ${isoStore}: $($iso.Message)" }

    $pool = Invoke-Probe "/pools/$($pve.pool)"
    if (-not $pool.Ok) { Add-Finding 'Error' 'Pool' "Pool '$($pve.pool)' not found or not visible: run the site kit's proxmox-setup.sh." }

    # VMIDs: every ID the lab can ever claim.
    # Plain hashtable: an [ordered] dictionary treats integer keys as positions.
    $labIds = @{}
    foreach ($t in $inv.templates.PSObject.Properties) {
        foreach ($id in ([int] $t.Value.vmid_first)..([int] $t.Value.vmid_last)) { $labIds[$id] = "$($t.Value.template_name) versions" }
        if ($t.Value.build) { $labIds[[int] $t.Value.build.staging_vmid] = "build staging for $($t.Value.template_name)" }
    }
    foreach ($srv in @($inv.servers)) {
        if ($srv.slots) { foreach ($sl in @($srv.slots)) { $labIds[[int] $sl.vmid] = "$($srv.role) slot $($sl.id)" } }
        else { $labIds[[int] $srv.vmid] = $srv.role }
    }
    # The hand-built MGMT-00 counts as the lab's by VMID + name, even before it
    # is in the ledger or tagged (same rule as proxmox-setup.sh).
    $mgmtDef    = @($inv.servers | Where-Object role -eq 'MGMT')[0]
    $mgmt00Id   = [int] (@($mgmtDef.slots | Where-Object id -eq $mgmtDef.initial.slot)[0]).vmid
    $mgmt00Name = [string] $mgmtDef.initial.hostname
    $visible = Invoke-Probe '/cluster/resources?type=vm'
    $byId = @{}
    if ($visible.Ok) { foreach ($vm in @($visible.Data)) { $byId[[int] $vm.vmid] = $vm } }
    $unverified = @()
    foreach ($id in ($labIds.Keys | Sort-Object)) {
        $what = $labIds[$id]
        if ($byId.ContainsKey($id)) {
            $vm = $byId[$id]
            $tags = @(([string] $vm.tags) -split '[;,\s]+')
            $manual = @($instances | Where-Object { [int] $_.vmid -eq $id -and $_.origin -eq 'manual' -and $_.name -eq $vm.name })
            if ($tags -contains 'midcoast-lab' -or $manual.Count -gt 0) { continue }   # the lab's own
            if ($id -eq $mgmt00Id -and $vm.name -eq $mgmt00Name) { continue }            # hand-built MGMT-00
            Add-Finding 'Error' 'VMID' "VMID $id ($what) is in use by '$($vm.name)', which isn't a MidCoast Lab VM. Change proxmox.vmid_base in site.yaml."
            continue
        }
        $free = Invoke-Probe "/cluster/nextid?vmid=$id"
        if ($free.Ok) { continue }
        if ($free.Status -eq 400 -or $free.Message -match 'already exists') {
            Add-Finding 'Error' 'VMID' "VMID $id ($what) is already used by a VM outside the lab's pool. Change proxmox.vmid_base in site.yaml."
        } else { $unverified += $id }
    }
    if ($unverified.Count -gt 0) {
        Add-Finding 'Warning' 'VMID' "Couldn't verify VMIDs $($unverified -join ', ') with this token; the root-side check in proxmox-setup.sh covers them."
    }
}

# ── Network ───────────────────────────────────────────────────────────────
if (-not $SkipNetwork) {
    $mine = @()
    if ($IsWindows) { $mine = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue | ForEach-Object IPAddress) }
    $owned = @($instances | Where-Object { $_.state -in 'building', 'active', 'retiring' } | ForEach-Object { [string] $_.ipv4 })
    $start = [int] ($inv.network.static_range.start -split '\.')[-1]
    $end   = [int] ($inv.network.static_range.end   -split '\.')[-1]
    $prefix = ($inv.network.static_range.start -split '\.')[0..2] -join '.'
    $candidates = @($start..$end | ForEach-Object { "$prefix.$_" } | Where-Object { $mine -notcontains $_ -and $owned -notcontains $_ })

    $answered = @($candidates | ForEach-Object -Parallel {
        if (Test-Connection -TargetName $_ -Count 1 -TimeoutSeconds 1 -Quiet -ErrorAction SilentlyContinue) { $_ }
    } -ThrottleLimit 20)
    # ARP catches devices that drop ping (Windows only). The pings above made
    # Windows resolve every candidate just now, so only 'Reachable' counts:
    # 'Stale' entries outlive a deleted VM by minutes and would be false alarms.
    if ($IsWindows) {
        $answered += @(Get-NetNeighbor -AddressFamily IPv4 -ErrorAction SilentlyContinue |
            Where-Object { $candidates -contains $_.IPAddress -and $_.State -eq 'Reachable' } |
            ForEach-Object IPAddress)
    }
    foreach ($ip in @($answered | Sort-Object -Unique)) {
        Add-Finding 'Error' 'Address' "$ip is in the lab's static range ($($inv.network.static_range.start)-$($inv.network.static_range.end)) but something outside the lab answers on it. Move that device, or exclude the range from DHCP."
    }

    if (-not (Test-Connection -TargetName $inv.network.gateway -Count 1 -TimeoutSeconds 2 -Quiet -ErrorAction SilentlyContinue)) {
        Add-Finding 'Warning' 'Network' "Gateway $($inv.network.gateway) doesn't answer ping."
    }
    if ($IsWindows) {
        foreach ($f in @($inv.identity.active_directory.dns_forwarders)) {
            try { $null = Resolve-DnsName -Name 'www.microsoft.com' -Server $f -DnsOnly -QuickTimeout -ErrorAction Stop }
            catch { Add-Finding 'Warning' 'Network' "DNS forwarder $f didn't resolve www.microsoft.com." }
        }
    }
}

# ── Report ────────────────────────────────────────────────────────────────
$errors = @($findings | Where-Object Level -eq 'Error')
$findings | Where-Object Level -ne 'Info' | Format-Table -AutoSize -Wrap | Out-String -Width 220 | Write-Host
if ($errors.Count -eq 0) { Write-Host "Site '$($inv.site.name)' pre-flight OK." -ForegroundColor Green }
else { Write-Host "Site '$($inv.site.name)' pre-flight: $($errors.Count) error(s)." -ForegroundColor Red }
if ($PassThru) { return $findings }
if ($errors.Count -gt 0) { exit 1 }
