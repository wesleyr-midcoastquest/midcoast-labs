#Requires -Version 7.2
<#
.SYNOPSIS
    Inventory validation: syntax, schema and semantic rules, for the product
    design (lab.yaml), the site settings (site.yaml), and the resolved result.

.DESCRIPTION
    Runs before every pipeline action. Errors stop the pipeline; warnings
    don't. Returns the findings; exits 1 when run directly with errors.

    Site checks: required values, no placeholders, subnet size, gateway,
    VMID base, ISO names, and that site.yaml holds only site settings. Product
    checks: lab.yaml holds no site settings. Then every semantic rule runs on
    the resolved inventory.

.EXAMPLE
    ./orchestration/Test-LabInventory.ps1
.EXAMPLE
    ./orchestration/Test-LabInventory.ps1 -SitePath ./inventory/site.template.yaml
#>
[CmdletBinding()]
param(
    [string] $InventoryPath,
    [string] $SitePath,
    [string] $LedgerPath,
    [switch] $PassThru
)

$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
if (-not $InventoryPath) { $InventoryPath = Join-Path $repo 'inventory/lab.yaml' }
if (-not $SitePath)      { $SitePath      = Join-Path $repo 'inventory/site.yaml' }
if (-not $LedgerPath)    { $LedgerPath    = Join-Path $repo 'inventory/instances.yaml' }
Import-Module (Join-Path $repo 'platform/modules/Lab.Inventory/Lab.Inventory.psm1') -Force -DisableNameChecking
Import-Module powershell-yaml -ErrorAction Stop

$findings = [System.Collections.Generic.List[object]]::new()
function Add-Finding([string] $Level, [string] $Rule, [string] $Message) {
    $findings.Add([pscustomobject]@{ Level = $Level; Rule = $Rule; Message = $Message })
}
function Get-Path($Object, [string] $Path) {
    $cur = $Object
    foreach ($p in $Path.Split('.')) {
        if ($null -eq $cur) { return $null }
        $cur = $cur.$p
    }
    $cur
}
function ConvertTo-UInt32([string] $Ip) {
    $b = ([System.Net.IPAddress]::Parse($Ip)).GetAddressBytes()
    [Array]::Reverse($b)
    [BitConverter]::ToUInt32($b, 0)
}

function Stop-Here {
    $findings | Format-Table -AutoSize -Wrap | Out-String -Width 220 | Write-Host
    Write-Host "Inventory has $(@($findings | Where-Object Level -eq 'Error').Count) error(s)." -ForegroundColor Red
    if ($PassThru) { return $findings }
    exit 1
}

# ── Syntax ────────────────────────────────────────────────────────────────
$product = $null; $siteRaw = $null
try { $product = Get-LabInventory -Path $InventoryPath } catch { Add-Finding 'Error' 'Syntax' "lab.yaml is not valid YAML: $($_.Exception.Message)" }
try { $siteRaw = Get-LabInventory -Path $SitePath }      catch { Add-Finding 'Error' 'Syntax' "site.yaml is not valid YAML (or missing): $($_.Exception.Message)" }
if (-not $product -or -not $siteRaw) { return (Stop-Here) }

# ── Site file: shape, required values, placeholders ──────────────────────
$siteSchema = [ordered]@{
    'site'     = @('name', 'time_zone')
    'identity' = @('active_directory', 'entra', 'administrators')
    'network'  = @('subnet', 'gateway', 'dns_forwarders', 'ntp', 'remote_desktop_from')
    'proxmox'  = @('cluster', 'node', 'endpoint', 'insecure_tls', 'bridge', 'storage', 'vmid_base', 'clone_mode', 'pool', 'role', 'tag', 'service_account')
    'isos'     = @('windows_server_2022', 'windows_11', 'virtio')
    'tailscale' = @('enabled')
}
foreach ($p in $siteRaw.PSObject.Properties) {
    if (-not $siteSchema.Contains($p.Name)) { Add-Finding 'Error' 'SiteSchema' "site.yaml has '$($p.Name)', which is not a site setting (allowed: $($siteSchema.Keys -join ', '))." ; continue }
    foreach ($q in @($p.Value.PSObject.Properties)) {
        if ($siteSchema[$p.Name] -notcontains $q.Name) { Add-Finding 'Error' 'SiteSchema' "site.yaml has '$($p.Name).$($q.Name)', which is not a site setting; product settings belong in lab.yaml." }
    }
}
$siteRequired = @('site.name', 'site.time_zone', 'identity.active_directory.domain', 'identity.active_directory.netbios',
    'identity.entra.tenant_domain', 'identity.administrators', 'network.subnet', 'network.gateway', 'network.ntp',
    'proxmox.node', 'proxmox.endpoint', 'proxmox.bridge', 'proxmox.storage.templates', 'proxmox.storage.virtual_machines',
    'proxmox.storage.iso_repository', 'proxmox.vmid_base', 'isos.windows_server_2022', 'isos.windows_11', 'isos.virtio')
foreach ($r in $siteRequired) {
    $v = Get-Path $siteRaw $r
    if ($null -eq $v -or "$v" -eq '') { Add-Finding 'Error' 'SiteSchema' "site.yaml is missing $r." }
}
# Placeholders left from site.template.yaml.
$siteText = Get-Content -Path $SitePath -Raw
foreach ($m in [regex]::Matches(($siteText -split "`n" | ForEach-Object { ($_ -split '#')[0] }) -join "`n", '<[^<>\s]+>|CHANGE-ME')) {
    Add-Finding 'Error' 'Placeholder' "site.yaml still contains the placeholder '$($m.Value)'."
}
foreach ($a in @($siteRaw.identity.administrators)) {
    foreach ($k in 'username', 'given_name', 'surname', 'tier', 'groups') {
        if ($null -eq $a.$k) { Add-Finding 'Error' 'SiteSchema' "An administrator in site.yaml is missing '$k'." }
    }
}
if ($siteRaw.proxmox.vmid_base -isnot [long] -and $siteRaw.proxmox.vmid_base -isnot [int] -and "$($siteRaw.proxmox.vmid_base)" -notmatch '^\d+$') {
    Add-Finding 'Error' 'SiteSchema' "proxmox.vmid_base must be a whole number."
} elseif ([int64] $siteRaw.proxmox.vmid_base -lt 100 -or [int64] $siteRaw.proxmox.vmid_base + 149 -gt 999999999) {
    Add-Finding 'Error' 'VMIDBase' "proxmox.vmid_base $($siteRaw.proxmox.vmid_base) must be at least 100 (Proxmox reserves lower IDs)."
}
if ("$($siteRaw.network.subnet)" -notmatch '^\d{1,3}(\.\d{1,3}){3}/\d{1,2}$') {
    Add-Finding 'Error' 'SiteSchema' "network.subnet '$($siteRaw.network.subnet)' isn't CIDR (e.g. 10.50.10.0/24)."
} else {
    # Exactly /24: host numbers are the last octet, and the reverse DNS zone is
    # the three-octet zone for the subnet.
    $parts = ($siteRaw.network.subnet -split '/')[0].Split('.')
    $pfx = [int] ($siteRaw.network.subnet -split '/')[1]
    if ($pfx -ne 24) {
        Add-Finding 'Error' 'SubnetSize' "network.subnet must be a /24 (got /$pfx): lab hosts sit at fixed last-octet host numbers."
    } elseif ($parts[3] -ne '0' -or @($parts | Where-Object { [int] $_ -gt 255 }).Count -gt 0) {
        Add-Finding 'Error' 'SiteSchema' "network.subnet '$($siteRaw.network.subnet)' isn't a network address; write it as a.b.c.0/24."
    }
}
if ("$($siteRaw.site.name)" -and "$($siteRaw.site.name)" -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$') {
    Add-Finding 'Error' 'SiteSchema' "site.name '$($siteRaw.site.name)' may only use letters, digits, '.', '_' and '-' (it names the site kit folder)."
}
foreach ($iso in 'windows_server_2022', 'windows_11', 'virtio') {
    $v = [string] $siteRaw.isos.$iso
    $store = [string] $siteRaw.proxmox.storage.iso_repository
    if ($v -and $v -notmatch "^$([regex]::Escape($store)):iso/.+\.iso$") {
        Add-Finding 'Error' 'IsoName' "isos.$iso '$v' should look like '${store}:iso/<file>.iso' (on proxmox.storage.iso_repository)."
    }
}
if ("$($siteRaw.proxmox.endpoint)" -match '\.ts\.net[:/]|//100\.(6[4-9]|[7-9]\d|1[01]\d|12[0-7])\.') {
    Add-Finding 'Warning' 'Endpoint' "proxmox.endpoint '$($siteRaw.proxmox.endpoint)' is a Tailscale address. Pipeline-built MGMTs aren't on your tailnet: use an address the lab subnet reaches directly."
}
if ($null -ne $siteRaw.proxmox.clone_mode -and "$($siteRaw.proxmox.clone_mode)" -cnotin 'linked', 'full') {
    Add-Finding 'Error' 'SiteSchema' "proxmox.clone_mode must be 'linked' or 'full', lower case (got '$($siteRaw.proxmox.clone_mode)')."
}
if ($siteRaw.proxmox.service_account) {
    foreach ($q in @($siteRaw.proxmox.service_account.PSObject.Properties)) {
        if ($q.Name -ne 'user') { Add-Finding 'Error' 'SiteSchema' "site.yaml has proxmox.service_account.$($q.Name); only 'user' may be set per site (token names are product settings)." }
    }
}
if ("$($siteRaw.proxmox.endpoint)" -notmatch '^https://[^/\s]+(:\d+)?/?$') {
    Add-Finding 'Error' 'SiteSchema' "proxmox.endpoint '$($siteRaw.proxmox.endpoint)' should look like https://<host>:8006/."
}
if ($siteRaw.site.time_zone) {
    # Windows IDs only (guests use tzutil / unattend). IANA names such as
    # America/New_York are refused on every platform.
    $ianaId = $null
    if (-not [TimeZoneInfo]::TryConvertWindowsIdToIanaId([string] $siteRaw.site.time_zone, [ref] $ianaId)) {
        Add-Finding 'Error' 'TimeZone' "site.time_zone '$($siteRaw.site.time_zone)' isn't a Windows time zone ID, e.g. 'Eastern Standard Time' (list: tzutil /l)."
    }
}

# ── Release name ─────────────────────────────────────────────────────────
if (-not $product.release) { Add-Finding 'Warning' 'Release' "lab.yaml has no 'release' (LAB-<YYMMDD>-<NN>); machines will record only the commit they were built from." }
elseif ("$($product.release)" -notmatch '^LAB-\d{6}-\d{2}$') { Add-Finding 'Error' 'Release' "lab.yaml release '$($product.release)' isn't LAB-<YYMMDD>-<NN>, e.g. LAB-261105-00." }

# ── Product file: must not carry site settings ───────────────────────────
$siteOnly = @('environment.time_zone', 'identity.active_directory.domain', 'identity.active_directory.netbios',
    'identity.active_directory.dns_forwarders', 'identity.entra.tenant_domain', 'identity.administrative_model.administrators',
    'network.subnet', 'network.gateway', 'network.bridge', 'network.ntp', 'network.static_range.start', 'network.static_range.end',
    'network.remote_desktop_from', 'tailscale.enabled', 'proxmox.node', 'proxmox.endpoint', 'proxmox.insecure_tls', 'proxmox.storage', 'proxmox.vmid_base', 'proxmox.cluster')
foreach ($k in $siteOnly) { if ($null -ne (Get-Path $product $k)) { Add-Finding 'Error' 'ProductPurity' "lab.yaml sets $k, which is a site setting; move it to site.yaml." } }
foreach ($t in @($product.templates.PSObject.Properties)) {
    foreach ($k in 'vmid', 'vmid_offset') { if ($null -ne $t.Value.$k) { Add-Finding 'Error' 'ProductPurity' "lab.yaml templates.$($t.Name) sets '$k'; templates are versioned, use vmid_offsets: { first, last }." } }
    if ($null -eq $t.Value.vmid_offsets -or $null -eq $t.Value.vmid_offsets.first -or $null -eq $t.Value.vmid_offsets.last) {
        Add-Finding 'Error' 'Schema' "lab.yaml templates.$($t.Name) needs vmid_offsets: { first, last }."
    }
    foreach ($k in 'iso', 'virtio_iso', 'staging_vmid') { if ($t.Value.build -and $null -ne $t.Value.build.$k) { Add-Finding 'Error' 'ProductPurity' "lab.yaml templates.$($t.Name).build sets '$k'; it comes from site.yaml." } }
}
foreach ($srv in @($product.servers)) {
    $entries = if ($srv.slots) { @($srv.slots) } else { @($srv) }
    foreach ($e in $entries) {
        if ($null -ne $e.ipv4) { Add-Finding 'Error' 'ProductPurity' "lab.yaml role $($srv.role) sets ipv4; use a host number ('host')." }
        if ($null -ne $e.vmid) { Add-Finding 'Error' 'ProductPurity' "lab.yaml role $($srv.role) sets vmid; use vmid_offset." }
        if ($null -eq $e.host -or $null -eq $e.vmid_offset) { Add-Finding 'Error' 'Schema' "lab.yaml role $($srv.role) needs 'host' and 'vmid_offset'$(if ($srv.slots) { ' on every slot' })." }
    }
}
if (@($findings | Where-Object Level -eq 'Error').Count -gt 0) { return (Stop-Here) }

# ── Resolve ───────────────────────────────────────────────────────────────
try { $inv = Resolve-LabInventory -Product $product -Site $siteRaw }
catch { Add-Finding 'Error' 'Resolve' "Couldn't resolve lab.yaml + site.yaml: $($_.Exception.Message)"; return (Stop-Here) }
$gwU = ConvertTo-UInt32 ([string] $inv.network.gateway)
$ledger = @()
if (Test-Path $LedgerPath) {
    try { $ledger = Get-LabInstances -Path $LedgerPath }
    catch { Add-Finding 'Error' 'Syntax' "instances.yaml is not valid YAML: $($_.Exception.Message)" }
}

# ── Schema ────────────────────────────────────────────────────────────────
$required = @(
    'version', 'environment.name', 'environment.time_zone',
    'naming.format', 'naming.max_length',
    'identity.active_directory.domain', 'identity.active_directory.netbios',
    'identity.active_directory.forest_mode', 'identity.active_directory.domain_mode', 'identity.active_directory.site',
    'identity.entra.tenant_domain', 'identity.administrative_model.account_suffix',
    'network.bridge', 'network.subnet', 'network.gateway', 'network.static_range.start', 'network.static_range.end', 'network.ntp',
    'proxmox.node', 'proxmox.endpoint', 'proxmox.pool',
    'proxmox.storage.templates', 'proxmox.storage.virtual_machines', 'proxmox.storage.iso_repository',
    'proxmox.service_account.user', 'proxmox.service_account.token_name', 'proxmox.service_account.packer_token_name',
    'templates', 'servers', 'organizational_units', 'groups.administrative',
    'placement.default_computers', 'tiering.tiers', 'tiering.computer_ous', 'secrets.vault', 'secrets.entries.local_administrator',
    'secrets.entries.domain_administrator', 'secrets.entries.dsrm',
    'secrets.entries.proxmox_terraform_token', 'secrets.entries.proxmox_packer_token',
    'deployment.phases', 'logging.path', 'logging.retention_days', 'terraform.state.path'
)
foreach ($r in $required) {
    if ($null -eq (Get-Path $inv $r)) { Add-Finding 'Error' 'Schema' "Missing required key: $r" }
}
foreach ($t in @($inv.templates.PSObject.Properties)) {
    foreach ($k in 'vmid_first', 'vmid_last', 'template_name') {
        if ($null -eq $t.Value.$k) { Add-Finding 'Error' 'Schema' "templates.$($t.Name) is missing '$k'." }
    }
    if ([int] $t.Value.vmid_last -lt [int] $t.Value.vmid_first + 1) {
        Add-Finding 'Error' 'TemplateRange' "templates.$($t.Name) needs at least two VMIDs (a current and a superseded version)."
    }
}
foreach ($s in @($inv.servers)) {
    foreach ($k in 'role', 'template', 'cpu', 'memory_mb', 'disk_gb') {
        if ($null -eq $s.$k) { Add-Finding 'Error' 'Schema' "Server '$($s.role)' is missing '$k'." }
    }
    if ($s.slots) {
        if ($null -eq $s.instances) { Add-Finding 'Error' 'Schema' "Role '$($s.role)' has slots but no 'instances' count." }
        foreach ($sl in @($s.slots)) {
            foreach ($k in 'id', 'vmid', 'ipv4') { if ($null -eq $sl.$k) { Add-Finding 'Error' 'Schema' "A $($s.role) slot is missing '$k'." } }
        }
    } else {
        foreach ($k in 'sequence', 'vmid', 'ipv4') {
            if ($null -eq $s.$k) { Add-Finding 'Error' 'Schema' "Server '$($s.role)' is missing '$k'." }
        }
    }
}
if (@($findings | Where-Object Level -eq 'Error').Count -gt 0) { return (Stop-Here) }

# ── Semantic ──────────────────────────────────────────────────────────────

# One definition per role.
$dupRoles = @($inv.servers | Group-Object role | Where-Object Count -gt 1 | ForEach-Object Name)
foreach ($r in $dupRoles) { Add-Finding 'Error' 'DuplicateRole' "Role '$r' is defined more than once." }

# VMIDs: unique and in range.
$vmids = @()
foreach ($t in @($inv.templates.PSObject.Properties)) {
    foreach ($id in ([int] $t.Value.vmid_first)..([int] $t.Value.vmid_last)) {
        $vmids += [pscustomobject]@{ Id = $id; Owner = "template $($t.Value.template_name) versions"; Range = 'template' }
    }
    if ($t.Value.build.staging_vmid) {
        $vmids += [pscustomobject]@{ Id = [int] $t.Value.build.staging_vmid; Owner = "staging for $($t.Value.template_name)"; Range = 'template' }
    }
}
foreach ($s in @($inv.servers)) {
    if ($s.slots) { foreach ($sl in @($s.slots)) { $vmids += [pscustomobject]@{ Id = [int] $sl.vmid; Owner = "$($s.role) slot $($sl.id)"; Range = 'infra' } } }
    else          { $vmids += [pscustomobject]@{ Id = [int] $s.vmid; Owner = "$($s.role)-$($s.sequence)"; Range = 'infra' } }
}
foreach ($g in @($vmids | Group-Object Id | Where-Object Count -gt 1)) {
    Add-Finding 'Error' 'DuplicateVMID' "VMID $($g.Name) is used by: $(($g.Group | ForEach-Object Owner) -join ', ')"
}
foreach ($v in $vmids) {
    $b = [int] $inv.proxmox.vmid_base
    if ($v.Range -eq 'infra'    -and ($v.Id -lt $b -or $v.Id -gt $b + 99))         { Add-Finding 'Error' 'VMIDRange' "$($v.Owner) VMID $($v.Id) is outside the server range $b-$($b + 99) (offset 0-99)." }
    if ($v.Range -eq 'template' -and ($v.Id -lt $b + 100 -or $v.Id -gt $b + 149)) { Add-Finding 'Error' 'VMIDRange' "$($v.Owner) VMID $($v.Id) is outside the template range $($b + 100)-$($b + 149) (offset 100-149)." }
}

# Addresses: unique, in the subnet, in the static range, not the gateway.
$net, $bits = $inv.network.subnet -split '/'
$full   = [uint64] 4294967295
$mask   = if ([int] $bits -eq 0) { [uint32] 0 } else { [uint32] ((($full -shl (32 - [int] $bits))) -band $full) }
$netU   = (ConvertTo-UInt32 $net) -band $mask
$startU = ConvertTo-UInt32 $inv.network.static_range.start
$endU   = ConvertTo-UInt32 $inv.network.static_range.end
$ips = @()
foreach ($s in @($inv.servers)) {
    if ($s.slots) { foreach ($sl in @($s.slots)) { $ips += [pscustomobject]@{ Ip = $sl.ipv4; Owner = "$($s.role) slot $($sl.id)" } } }
    else          { $ips += [pscustomobject]@{ Ip = $s.ipv4; Owner = "$($s.role)-$($s.sequence)" } }
}
foreach ($g in @($ips | Group-Object Ip | Where-Object Count -gt 1)) {
    Add-Finding 'Error' 'DuplicateIP' "$($g.Name) is used by: $(($g.Group | ForEach-Object Owner) -join ', ')"
}
foreach ($i in $ips) {
    $u = ConvertTo-UInt32 $i.Ip
    if (($u -band $mask) -ne $netU)         { Add-Finding 'Error' 'IPOutsideSubnet' "$($i.Owner) $($i.Ip) is not in $($inv.network.subnet)." }
    if ($u -lt $startU -or $u -gt $endU)   { Add-Finding 'Error' 'IPOutsideStaticRange' "$($i.Owner) $($i.Ip) is outside $($inv.network.static_range.start)-$($inv.network.static_range.end)." }
    if ($i.Ip -eq $inv.network.gateway)     { Add-Finding 'Error' 'IPIsGateway' "$($i.Owner) uses the gateway address." }
}
if (($gwU -band $mask) -ne $netU) { Add-Finding 'Error' 'Gateway' "Gateway $($inv.network.gateway) is not in $($inv.network.subnet)." }
if ($gwU -ge $startU -and $gwU -le $endU) { Add-Finding 'Error' 'Gateway' "Gateway $($inv.network.gateway) is inside the lab's static range ($($inv.network.static_range.start)-$($inv.network.static_range.end))." }
if ($null -ne $siteRaw.tailscale -and $null -ne $siteRaw.tailscale.enabled -and $siteRaw.tailscale.enabled -isnot [bool]) {
    Add-Finding 'Error' 'Tailscale' "site.yaml tailscale.enabled must be true or false, not '$($siteRaw.tailscale.enabled)'."
}
foreach ($src in @($inv.network.remote_desktop_from | Where-Object { $_ })) {
    $a, $b = ([string] $src) -split '/', 2
    $okAddr = [bool] ($a -match '^\d{1,3}(\.\d{1,3}){3}$' -and [System.Net.IPAddress]::TryParse($a, [ref] $null))
    $okBits = (-not $b) -or ($b -match '^\d{1,2}$' -and [int] $b -ge 8 -and [int] $b -le 32)
    if (-not ($okAddr -and $okBits)) { Add-Finding 'Error' 'RemoteDesktopFrom' "network.remote_desktop_from '$src' isn't an IPv4 address or a.b.c.d/nn network (/8 or narrower)." }
    elseif ($b -and [int] $b -lt 16) { Add-Finding 'Warning' 'RemoteDesktopFrom' "network.remote_desktop_from '$src' is a very wide range for Remote Desktop to a Tier 0 machine." }
}
foreach ($f in @($inv.identity.active_directory.dns_forwarders)) {
    if ($f -and (((ConvertTo-UInt32 $f) -band $mask) -eq $netU) -and (ConvertTo-UInt32 $f) -ge $startU -and (ConvertTo-UInt32 $f) -le $endU) {
        Add-Finding 'Error' 'ForwarderIsLab' "DNS forwarder $f is a lab address; forwarders must be upstream."
    }
}

# Subnets that commonly collide: default home-router ranges (a problem when the
# lab is reached over Tailscale from another network) and container defaults.
$collide = @{ '192.168.0.0/24' = 'home routers'; '192.168.1.0/24' = 'home routers'; '192.168.86.0/24' = 'Google/Nest Wifi';
              '10.0.0.0/24' = 'home routers'; '10.0.1.0/24' = 'home routers'; '10.42.0.0/16' = 'k3s pods'; '10.43.0.0/16' = 'k3s services';
              '172.17.0.0/16' = 'Docker' }
foreach ($c in $collide.Keys) {
    $cn, $cb = $c -split '/'
    $cm = [uint32] (((([uint64] 4294967295) -shl (32 - [int] $cb))) -band ([uint64] 4294967295))
    $small = [Math]::Min([int] $bits, [int] $cb)
    $sm = [uint32] (((([uint64] 4294967295) -shl (32 - $small))) -band ([uint64] 4294967295))
    if ((($netU -band $sm) -eq ((ConvertTo-UInt32 $cn) -band $sm))) {
        Add-Finding 'Warning' 'CommonSubnet' "Lab subnet $($inv.network.subnet) overlaps $c ($($collide[$c])); routing over Tailscale or a VPN may collide."
    }
}

# Naming: worst case (sequence 99) must fit, for every pipeline-built role.
$max = [int] $inv.naming.max_length
foreach ($s in @($inv.servers)) {
    if ($s.initial -and $s.initial.hostname -and $s.initial.hostname.Length -gt $max) {
        Add-Finding 'Error' 'InvalidNaming' "Initial hostname $($s.initial.hostname) is longer than $max."
    }
    try { $null = New-LabHostname -Role $s.role -BuildDate (Get-Date) -Sequence '99' -Format $inv.naming.format -MaxLength $max }
    catch { Add-Finding 'Error' 'InvalidNaming' "Role $($s.role): $($_.Exception.Message)" }
}
$nb = $inv.identity.active_directory.netbios
if ($nb.Length -gt 15 -or $nb -match '\.') { Add-Finding 'Error' 'InvalidNaming' "NetBIOS name '$nb' must be 15 characters or fewer, without dots." }

# AD domain: never single-label, never .local (mDNS collision, no public certs).
$dom = [string] $inv.identity.active_directory.domain
if ($dom -notmatch '\.') { Add-Finding 'Error' 'DomainName' "AD domain '$dom' is single-label; use a subdomain of a domain you own." }
if ($dom -match '\.local$') { Add-Finding 'Error' 'DomainName' "AD domain '$dom' ends in .local, which collides with multicast DNS; use a subdomain of a domain you own." }
$tenant = [string] $inv.identity.entra.tenant_domain
if ($tenant -and $dom -ne $tenant -and -not $dom.EndsWith(".$tenant")) {
    Add-Finding 'Warning' 'DomainName' "AD domain '$dom' isn't under the Entra domain '$tenant'; that works (UPN suffix), but a subdomain keeps the namespace in one owned domain."
}

# Templates referenced by servers must exist.
$tplNames = @($inv.templates.PSObject.Properties | ForEach-Object { $_.Value.template_name })
foreach ($s in @($inv.servers)) {
    if ($tplNames -notcontains $s.template) { Add-Finding 'Error' 'MissingTemplate' "Role $($s.role) uses template '$($s.template)', which is not defined." }
}
foreach ($t in @($inv.templates.PSObject.Properties)) {
    if (-not $t.Value.build -and @($inv.servers | Where-Object { $_.template -eq $t.Value.template_name }).Count -gt 0) {
        Add-Finding 'Warning' 'MissingTemplateBuild' "Template $($t.Value.template_name) has no build section yet; roles using it can't be deployed."
    }
    if ($t.Value.build) {
        foreach ($k in 'staging_vmid', 'iso', 'virtio_iso', 'image_index', 'disk_gb', 'driver_os', 'tag', 'software_versions') {
            if ($null -eq $t.Value.build.$k) { Add-Finding 'Error' 'Schema' "templates.$($t.Name).build is missing '$k'." }
        }
        if ($t.Value.template_name -like 'WIN11*' -and -not $t.Value.build.tpm) {
            Add-Finding 'Error' 'TemplateTpm' "$($t.Value.template_name) needs build.tpm: true (Windows 11 requires TPM 2.0)."
        }
        if ([int] $t.Value.build.disk_gb -lt 64 -and $t.Value.template_name -like 'WIN11*') {
            Add-Finding 'Error' 'TemplateDisk' "$($t.Value.template_name) disk_gb must be at least 64 for Windows 11."
        }
    }
}

# Memory: ballooning floor within the role's memory.
foreach ($s in @($inv.servers)) {
    if ($null -ne $s.memory_min_mb) {
        if ([int] $s.memory_min_mb -gt [int] $s.memory_mb) { Add-Finding 'Error' 'Memory' "Role $($s.role): memory_min_mb ($($s.memory_min_mb)) is above memory_mb ($($s.memory_mb))." }
        if ([int] $s.memory_min_mb -lt 1024) { Add-Finding 'Error' 'Memory' "Role $($s.role): memory_min_mb below 1024 starves Windows; use 1024 or more." }
    }
}

# A clone's disk can grow from the template's, never shrink.
foreach ($s in @($inv.servers)) {
    $tdef = @($inv.templates.PSObject.Properties.Value | Where-Object template_name -eq $s.template)[0]
    if ($tdef -and $tdef.build -and [int] $s.disk_gb -lt [int] $tdef.build.disk_gb) {
        Add-Finding 'Error' 'Disk' "Role $($s.role): disk_gb $($s.disk_gb) is smaller than $($s.template)'s $($tdef.build.disk_gb) GB; clones can't shrink a disk."
    }
}

# Linked clones live on the template's storage.
# The lab's names on the cluster (1.6): what Proxmox accepts for a pool, role, tag
# and user id, after "{site}" has been filled in. Two labs on one cluster need
# different names, so a site that shares a cluster should use "{site}" in them.
$nameRules = [ordered]@{
    'proxmox.pool'                 = @($inv.proxmox.pool,                 '^[A-Za-z0-9][A-Za-z0-9._-]{0,62}$',          'letters, digits, . _ -')
    'proxmox.role'                 = @($inv.proxmox.role,                 '^[A-Za-z0-9][A-Za-z0-9._-]{0,62}$',          'letters, digits, . _ -')
    'proxmox.tag'                  = @($inv.proxmox.tag,                  '^[a-z0-9_][a-z0-9_.+-]{0,62}$',              'lower-case letters, digits, _ . + -')
    'proxmox.service_account.user' = @($inv.proxmox.service_account.user, '^[A-Za-z0-9][A-Za-z0-9._-]{0,62}@[a-z0-9-]+$', '<name>@<realm>, e.g. terraform-prov-mylab@pve')
}
foreach ($k in $nameRules.Keys) {
    $v, $rx, $hint = $nameRules[$k]
    if (-not $v) { Add-Finding 'Error' 'ProxmoxNames' "$k is empty; lab.yaml must give a default." }
    elseif ($v -notmatch $rx) { Add-Finding 'Error' 'ProxmoxNames' "$k '$v' isn't a name Proxmox accepts ($hint). site.name becomes the slug '$($inv.proxmox.site_slug)' inside it." }
}
if ($inv.proxmox.tag -eq 'midcoast-lab' -and $siteRaw.proxmox.tag) {
    Add-Finding 'Info' 'ProxmoxNames' "proxmox.tag is the pre-1.6 default 'midcoast-lab'; another lab on this cluster must use a different tag."
}
if (-not $inv.proxmox.site_slug) { Add-Finding 'Error' 'ProxmoxNames' "site.name '$($siteRaw.site.name)' has no letters or digits to make a slug from." }
if ($inv.proxmox.clone_mode -ceq 'linked' -and $inv.proxmox.storage.templates -ne $inv.proxmox.storage.virtual_machines) {
    Add-Finding 'Error' 'CloneMode' "Linked clones need templates and VMs on the same storage (site.yaml has templates: $($inv.proxmox.storage.templates), virtual_machines: $($inv.proxmox.storage.virtual_machines)). Use one storage for both, or set proxmox.clone_mode: full."
}

# Initial (hand-built) instances must point at a real slot.
foreach ($s in @($inv.servers | Where-Object initial)) {
    if (-not $s.slots) { Add-Finding 'Error' 'Schema' "Role $($s.role) has 'initial' but no slots." ; continue }
    if (@($s.slots | Where-Object id -eq $s.initial.slot).Count -ne 1) {
        Add-Finding 'Error' 'InitialSlot' "Role $($s.role) initial slot '$($s.initial.slot)' is not one of its slots."
    }
}

# MGMT: handover paths, and the role every guest firewall trusts.
$mgmt = @($inv.servers | Where-Object role -eq 'MGMT')
if ($mgmt.Count -eq 1) {
    foreach ($k in 'repo_path', 'vault_path', 'lock_path', 'cert_lock_path') {
        if (-not $mgmt[0].handover.$k) { Add-Finding 'Error' 'Schema' "MGMT is missing handover.$k." }
    }
    foreach ($k in 'git', 'terraform', 'packer', 'vscode', 'keepassxc') {
        if (-not $mgmt[0].software_versions.$k) { Add-Finding 'Error' 'Schema' "MGMT is missing software_versions.$k." }
    }
} else {
    Add-Finding 'Error' 'Schema' 'Exactly one MGMT role is required.'
}

# Slot pools need a spare for rotation.
foreach ($s in @($inv.servers | Where-Object slots)) {
    if (@($s.slots).Count -lt ([int] $s.instances + 1)) {
        Add-Finding 'Error' 'NoSpareSlot' "Role $($s.role) has $(@($s.slots).Count) slots for $($s.instances) instances; rotation needs at least one spare."
    }
}

# OUs: parents exist; placement targets exist.
$ous = @($inv.organizational_units)
foreach ($o in $ous) {
    $parts = $o -split '/'
    if ($parts.Count -gt 1) {
        $parent = ($parts[0..($parts.Count - 2)]) -join '/'
        if ($ous -notcontains $parent) { Add-Finding 'Error' 'MissingParentOU' "OU '$o' has no parent '$parent' in the list." }
    }
}
if (-not $inv.placement.standard_users) { Add-Finding 'Error' 'Schema' "placement.standard_users (the OU for standard accounts) is missing." }
foreach ($required in @($inv.placement.standard_users, $inv.placement.default_computers) + @($inv.placement.roles.PSObject.Properties.Value)) {
    if ($required -and $ous -notcontains $required) { Add-Finding 'Error' 'MissingOU' "OU '$required' is required but not in organizational_units." }
}
# Top-level OUs can't share a name with the built-in containers at the domain
# root: AD names must be unique under a parent, whatever the object type.
$builtIn = 'Users', 'Computers', 'Builtin', 'System', 'Program Data', 'ForeignSecurityPrincipals',
    'Managed Service Accounts', 'Keys', 'LostAndFound', 'Infrastructure', 'NTDS Quotas', 'TPM Devices'
foreach ($o in $ous | Where-Object { $_ -notmatch '/' }) {
    if ($builtIn -contains $o) { Add-Finding 'Error' 'ReservedOU' "Top-level OU '$o' clashes with the built-in CN=$o container; pick another name." }
}

# ── Tiering ───────────────────────────────────────────────────────────────
$tierIds = @($inv.tiering.tiers | ForEach-Object { [int] $_.id })
if ($tierIds.Count -eq 0) { Add-Finding 'Error' 'Schema' 'tiering.tiers is empty.' }
if (@($tierIds | Group-Object | Where-Object Count -gt 1).Count -gt 0) { Add-Finding 'Error' 'Tiering' 'tiering.tiers has duplicate ids.' }
if ($tierIds -notcontains 0) { Add-Finding 'Error' 'Tiering' 'tiering.tiers must define tier 0.' }
function Test-Tier($Value, [string] $What) {
    if ($null -eq $Value -or "$Value" -notmatch '^\d+$' -or $tierIds -notcontains [int] $Value) {
        Add-Finding 'Error' 'Tiering' "$What has no valid tier (got '$Value'; defined: $($tierIds -join ', '))."
        return $false
    }
    $true
}
foreach ($t in @($inv.tiering.tiers)) {
    foreach ($kind in 'Accounts', 'Groups') {
        if ($ous -notcontains "$($t.ou)/$kind") { Add-Finding 'Error' 'MissingOU' "Tier $($t.id) needs OU '$($t.ou)/$kind'." }
    }
}
foreach ($p in @($inv.tiering.computer_ous.PSObject.Properties)) {
    $null = Test-Tier $p.Value "Computer OU '$($p.Name)'"
    if ($p.Name -ne 'Domain Controllers' -and $ous -notcontains $p.Name) { Add-Finding 'Error' 'MissingOU' "tiering.computer_ous lists '$($p.Name)', which isn't in organizational_units." }
}

# Groups: name + tier, unique.
$groupDefs = @($inv.groups.administrative)
$groupTier = @{}
foreach ($g in $groupDefs) {
    if ($g -is [string] -or -not $g.name) { Add-Finding 'Error' 'Schema' "groups.administrative entries need 'name' and 'tier' (got '$g')."; continue }
    if ($groupTier.ContainsKey($g.name)) { Add-Finding 'Error' 'Tiering' "Group $($g.name) is listed twice." }
    if (Test-Tier $g.tier "Group $($g.name)") {
        $groupTier[$g.name] = [int] $g.tier
    }
}
$groups = @($groupTier.Keys)

# Membership never crosses tiers: an account only joins groups of its own tier.
function Test-Memberships([string] $Account, $Tier, $Groups) {
    foreach ($g in @($Groups)) {
        if (-not $g) { continue }
        if ($groups -notcontains $g) { Add-Finding 'Error' 'MissingGroup' "$Account references unknown group '$g'."; continue }
        if ($groupTier[$g] -ne [int] $Tier) { Add-Finding 'Error' 'CrossTier' "$Account (tier $Tier) is a member of $g (tier $($groupTier[$g])); membership must stay within a tier." }
    }
}

# Administrators.
$suffix = $inv.identity.administrative_model.account_suffix
foreach ($a in @($inv.identity.administrative_model.administrators)) {
    $n = "$($a.username)$suffix"
    if ($n.Length -gt 20) { Add-Finding 'Error' 'InvalidNaming' "Account '$n' exceeds the 20-character sAMAccountName limit." }
    if (Test-Tier $a.tier "Administrator $n") {
        Test-Memberships -Account $n -Tier $a.tier -Groups $a.groups
        if ($ous -notcontains (Get-LabTierOU -Inventory $inv -Tier ([int] $a.tier) -Kind Accounts)) { Add-Finding 'Error' 'MissingOU' "No Accounts OU for tier $($a.tier) ($n)." }
    }
}

# Service accounts.
$prefix = $inv.identity.service_account_prefix
$tier0ComputerOUs = @($inv.tiering.computer_ous.PSObject.Properties | Where-Object { [int] $_.Value -eq 0 -and $_.Name -ne 'Domain Controllers' } | ForEach-Object Name)
foreach ($s in @($inv.identity.service_accounts)) {
    if (-not $s.name.StartsWith($prefix)) { Add-Finding 'Error' 'InvalidNaming' "Service account '$($s.name)' must start with '$prefix'." }
    if ($s.name.Length -gt 20) { Add-Finding 'Error' 'InvalidNaming' "Service account '$($s.name)' exceeds 20 characters." }
    if (Test-Tier $s.tier "Service account $($s.name)") {
        Test-Memberships -Account $s.name -Tier $s.tier -Groups $s.groups
        $svcOU = Get-LabTierOU -Inventory $inv -Tier ([int] $s.tier) -Kind ServiceAccounts
        if ($ous -notcontains $svcOU) { Add-Finding 'Error' 'MissingOU' "Service account $($s.name) needs OU '$svcOU'." }
        # Join rights on a Tier 0 OU make the account Tier 0.
        if ($s.delegation -eq 'domain_join' -and [int] $s.tier -ne 0 -and $tier0ComputerOUs.Count -gt 0) {
            Add-Finding 'Error' 'CrossTier' "$($s.name) is delegated domain join on Tier 0 OUs ($($tier0ComputerOUs -join ', ')), so it must be tier 0."
        }
    }
}

# Machines: each role's placement OU must be in the role's tier.
foreach ($srv in @($inv.servers)) {
    if (-not (Test-Tier $srv.tier "Role $($srv.role)")) { continue }
    $ou = if ($srv.role -eq 'DC') { 'Domain Controllers' } else { $inv.placement.roles.($srv.role) }
    if (-not $ou) { Add-Finding 'Error' 'Tiering' "Role $($srv.role) has no placement.roles entry."; continue }
    $ouTier = Get-LabOUTier -Inventory $inv -OUPath $ou
    if ($null -eq $ouTier) { Add-Finding 'Error' 'Tiering' "Role $($srv.role) is placed in '$ou', which has no tier in tiering.computer_ous." }
    elseif ($ouTier -ne [int] $srv.tier) { Add-Finding 'Error' 'CrossTier' "Role $($srv.role) is tier $($srv.tier) but placed in '$ou' (tier $ouTier)." }
}
if ($inv.tiering.enforced) { Add-Finding 'Warning' 'Tiering' 'tiering.enforced is true, but enforcement (logon restrictions) is not implemented yet.' }

if ($inv.groups.nesting) {
    foreach ($p in $inv.groups.nesting.PSObject.Properties) {
        if ($groups -notcontains $p.Name) { Add-Finding 'Error' 'MissingGroup' "Nesting refers to unknown group '$($p.Name)'." }
    }
}
if (@($inv.identity.service_accounts | Where-Object name -eq 'svc-labdeploy').Count -eq 0) {
    Add-Finding 'Error' 'MissingAccount' 'svc-labdeploy is required: replica DCs promote with it.'
}

# Phases reference real roles.
$roles = @($inv.servers | ForEach-Object role)
foreach ($ph in @($inv.deployment.phases.PSObject.Properties)) {
    foreach ($r in @($ph.Value.roles)) {
        if ($roles -notcontains $r) { Add-Finding 'Error' 'UnknownRole' "Phase $($ph.Name) lists unknown role '$r'." }
    }
}

# Ledger consistency.
foreach ($g in @($ledger | Group-Object name | Where-Object Count -gt 1)) { Add-Finding 'Error' 'LedgerDuplicate' "Ledger lists $($g.Name) twice." }
$activeMgmt = @($ledger | Where-Object { $_.role -eq 'MGMT' -and $_.state -eq 'active' })
if ($activeMgmt.Count -gt 1) { Add-Finding 'Error' 'LedgerMgmt' "More than one active MGMT: $(($activeMgmt | ForEach-Object name) -join ', ')." }
foreach ($g in @($ledger | Where-Object slot | Group-Object { "$($_.role)/$($_.slot)" } | Where-Object Count -gt 1)) {
    Add-Finding 'Error' 'LedgerSlotConflict' "Slot $($g.Name) is held by: $(($g.Group | ForEach-Object name) -join ', ')"
}
foreach ($i in $ledger) {
    if ($roles -notcontains $i.role) { Add-Finding 'Error' 'LedgerUnknownRole' "Ledger instance $($i.name) has unknown role '$($i.role)'." }
    if ($i.state -notin 'building', 'active', 'retiring') { Add-Finding 'Error' 'LedgerState' "Ledger instance $($i.name) has unknown state '$($i.state)'." }
    # A ledger copied from another site would point at that site's machines.
    $b = [int] $inv.proxmox.vmid_base
    if ($i.ipv4 -and (((ConvertTo-UInt32 ([string] $i.ipv4)) -band $mask) -ne $netU)) {
        Add-Finding 'Error' 'LedgerSite' "Ledger instance $($i.name) has $($i.ipv4), outside this site's subnet $($inv.network.subnet). Is instances.yaml from another site? A new site starts with 'instances: []'."
    }
    if ($i.vmid -and ([int] $i.vmid -lt $b -or [int] $i.vmid -gt $b + 99)) {
        Add-Finding 'Error' 'LedgerSite' "Ledger instance $($i.name) has VMID $($i.vmid), outside this site's server range $b-$($b + 99). Is instances.yaml from another site?"
    }
    if ($i.origin -eq 'manual') { continue }
    try {
        $expected = New-LabHostname -Role $i.role -BuildDate $i.build_date -Sequence $i.sequence -Format $inv.naming.format -MaxLength $max
        if ($expected -ne $i.name) { Add-Finding 'Error' 'LedgerName' "Ledger name $($i.name) should be $expected." }
    } catch { Add-Finding 'Error' 'LedgerName' "Ledger instance $($i.name): $($_.Exception.Message)" }
}

# Ledger: template versions and the version each instance is pinned to.
$tplLedger = @()
if (Test-Path $LedgerPath) { try { $tplLedger = @(Get-LabTemplateVersions -Path $LedgerPath) } catch { } }
$families = @($inv.templates.PSObject.Properties | ForEach-Object { $_.Value.template_name })
foreach ($g in @($tplLedger | Group-Object vmid | Where-Object Count -gt 1)) { Add-Finding 'Error' 'LedgerTemplate' "Ledger lists template VMID $($g.Name) more than once." }
foreach ($t in $tplLedger) {
    $def = @($inv.templates.PSObject.Properties.Value | Where-Object template_name -eq $t.family)[0]
    if (-not $def) { Add-Finding 'Error' 'LedgerTemplate' "Ledger template $($t.name) has unknown family '$($t.family)'."; continue }
    if ($t.state -notin 'current', 'superseded') { Add-Finding 'Error' 'LedgerTemplate' "Ledger template $($t.name) has unknown state '$($t.state)'." }
    if ([int] $t.vmid -lt [int] $def.vmid_first -or [int] $t.vmid -gt [int] $def.vmid_last) {
        Add-Finding 'Error' 'LedgerSite' "Ledger template $($t.name) has VMID $($t.vmid), outside $($t.family)'s range $($def.vmid_first)-$($def.vmid_last). Is instances.yaml from another site?"
    }
}
foreach ($f in $families) {
    $cur = @($tplLedger | Where-Object { $_.family -eq $f -and $_.state -eq 'current' })
    if ($cur.Count -gt 1) { Add-Finding 'Error' 'LedgerTemplate' "More than one current $f in the ledger: $(($cur | ForEach-Object name) -join ', ')." }
}
foreach ($i in $ledger) {
    if ($i.origin -eq 'manual') { continue }
    if (-not $i.template_vmid) { Add-Finding 'Error' 'LedgerTemplate' "Ledger instance $($i.name) has no template_vmid (the template version it was cloned from)."; continue }
    if ("$($i.clone_mode)" -cnotin 'linked', 'full') { Add-Finding 'Error' 'LedgerTemplate' "Ledger instance $($i.name) has clone_mode '$($i.clone_mode)'; expected 'linked' or 'full' (recorded when it was allocated)." }
    $t = @($tplLedger | Where-Object { [int] $_.vmid -eq [int] $i.template_vmid })[0]
    $roleDef = @($inv.servers | Where-Object role -eq $i.role)[0]
    if (-not $t) { Add-Finding 'Error' 'LedgerTemplate' "Ledger instance $($i.name) is pinned to template VMID $($i.template_vmid), which the ledger doesn't list." }
    elseif ($roleDef -and $t.family -ne $roleDef.template) { Add-Finding 'Error' 'LedgerTemplate' "Ledger instance $($i.name) ($($i.role)) is pinned to $($t.name), but $($i.role) uses $($roleDef.template)." }
}

# ── Report ────────────────────────────────────────────────────────────────
$errors = @($findings | Where-Object Level -eq 'Error')
if ($findings.Count -gt 0) { $findings | Format-Table -AutoSize -Wrap | Out-String -Width 220 | Write-Host }
if ($errors.Count -eq 0) { Write-Host "Inventory OK ($($findings.Count) warning(s))." -ForegroundColor Green }
else { Write-Host "Inventory has $($errors.Count) error(s)." -ForegroundColor Red }

if ($PassThru) { return $findings }
if ($errors.Count -gt 0) { exit 1 }
