# Lab.Inventory: read inventory and ledger, generate hostnames, derive AD paths.
#
# On MGMT it reads YAML (needs the powershell-yaml module). Inside guests
# it reads inventory.json, which the orchestrator resolves from lab.yaml + site.yaml, so
# guests need nothing beyond Windows PowerShell 5.1.

function Get-LabInventory {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Path)
    if (-not (Test-Path $Path)) { throw "Inventory not found: $Path" }
    $raw = Get-Content -Path $Path -Raw -Encoding UTF8   # inventory.json is UTF-8 without BOM; 5.1 would read it as ANSI
    if ($Path -match '\.ya?ml$') {
        if (-not (Get-Command ConvertFrom-Yaml -ErrorAction SilentlyContinue)) {
            Import-Module powershell-yaml -ErrorAction Stop
        }
        # Round-trip through JSON so YAML and JSON inventories behave identically.
        return (ConvertFrom-Yaml -Yaml $raw | ConvertTo-Json -Depth 20 | ConvertFrom-Json)
    }
    $raw | ConvertFrom-Json
}

# ── Site resolution ─────────────────────────────────────────────────────
# lab.yaml (product) + site.yaml (site) -> one resolved inventory with the
# same shape the rest of the pipeline uses: absolute IPv4 addresses, absolute
# VMIDs, site values filled in. This is the ONLY place the two are merged;
# Terraform, Packer and guests read the resolved output.

# Top-level keys a site file may contain, and the product file may not.
$script:SiteKeys = @('site', 'identity', 'network', 'proxmox', 'isos')

function Copy-LabObject {
    param($Object)
    $Object | ConvertTo-Json -Depth 30 | ConvertFrom-Json
}

function Set-LabValue {
    # Sets a dotted path on a PSCustomObject, creating intermediate objects.
    param($Object, [string] $Path, $Value)
    $parts = $Path.Split('.')
    $cur = $Object
    for ($i = 0; $i -lt $parts.Count - 1; $i++) {
        $p = $parts[$i]
        if ($null -eq $cur.$p -or $cur.$p -isnot [pscustomobject]) {
            $cur | Add-Member -NotePropertyName $p -NotePropertyValue ([pscustomobject]@{}) -Force
        }
        $cur = $cur.$p
    }
    $cur | Add-Member -NotePropertyName $parts[-1] -NotePropertyValue $Value -Force
}

function ConvertTo-LabHostAddress {
    # '10.50.10.0/24' + 30 -> '10.50.10.30'
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Subnet,
        [Parameter(Mandatory)] [int] $HostNumber
    )
    $net, $bits = $Subnet -split '/'
    $bits = [int] $bits
    $size = [math]::Pow(2, 32 - $bits)
    if ($HostNumber -lt 1 -or $HostNumber -ge $size - 1) {
        throw "Host number $HostNumber doesn't fit in $Subnet (usable 1-$($size - 2))."
    }
    $b = ([System.Net.IPAddress]::Parse($net)).GetAddressBytes()
    [Array]::Reverse($b)
    $n = [BitConverter]::ToUInt32($b, 0)
    $mask = [uint32] (([uint64] 4294967295 -shl (32 - $bits)) -band [uint64] 4294967295)
    $v = [uint32] (($n -band $mask) + $HostNumber)
    $o = [BitConverter]::GetBytes($v)
    [Array]::Reverse($o)
    ([System.Net.IPAddress]::new($o)).ToString()
}

function Resolve-LabInventory {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Product,
        [Parameter(Mandatory)] $Site
    )
    $r    = Copy-LabObject $Product
    $base = [int] $Site.proxmox.vmid_base
    $net  = [string] $Site.network.subnet

    Set-LabValue $r 'site' (Copy-LabObject $Site.site)
    Set-LabValue $r 'environment.time_zone' $Site.site.time_zone

    Set-LabValue $r 'identity.active_directory.domain'  $Site.identity.active_directory.domain
    Set-LabValue $r 'identity.active_directory.netbios' $Site.identity.active_directory.netbios
    # Assign arrays directly: an if-expression would unroll a one-element array.
    $fwd = @($Site.network.dns_forwarders)
    if ($fwd.Count -eq 0 -or -not $fwd[0]) { $fwd = @($Site.network.gateway) }
    Set-LabValue $r 'identity.active_directory.dns_forwarders' $fwd
    Set-LabValue $r 'identity.entra.tenant_domain' $Site.identity.entra.tenant_domain
    Set-LabValue $r 'identity.administrative_model.administrators' @(Copy-LabObject @($Site.identity.administrators))

    Set-LabValue $r 'network.bridge'  $Site.proxmox.bridge
    Set-LabValue $r 'network.subnet'  $net
    Set-LabValue $r 'network.gateway' $Site.network.gateway
    Set-LabValue $r 'network.ntp'     @($Site.network.ntp)
    # Optional: join the site's tailnet (key in the vault). Which roles join is
    # the product's choice, per role (lab.yaml servers[].tailscale; 1.8: MGMT only).
    Set-LabValue $r 'tailscale.enabled' ([bool] ($Site.tailscale -and $Site.tailscale.enabled -eq $true))
    # Optional: networks besides the lab subnet allowed Remote Desktop to MGMT.
    Set-LabValue $r 'network.remote_desktop_from' @($Site.network.remote_desktop_from | Where-Object { $_ })
    Set-LabValue $r 'network.static_range.start' (ConvertTo-LabHostAddress -Subnet $net -HostNumber ([int] $Product.network.static_range.start_host))
    Set-LabValue $r 'network.static_range.end'   (ConvertTo-LabHostAddress -Subnet $net -HostNumber ([int] $Product.network.static_range.end_host))

    foreach ($k in 'cluster', 'node', 'endpoint', 'insecure_tls', 'vmid_base') { Set-LabValue $r "proxmox.$k" $Site.proxmox.$k }
    # The lab's names on the cluster: the site's value when it sets one, else the
    # product default; "{site}" in either becomes the site slug (1.6, issue #24).
    $slug = ConvertTo-LabSiteSlug ([string] $Site.site.name)
    Set-LabValue $r 'proxmox.site_slug' $slug
    foreach ($k in 'pool', 'role', 'tag') {
        $v = if ($Site.proxmox.$k) { [string] $Site.proxmox.$k } else { [string] $Product.proxmox.$k }
        Set-LabValue $r "proxmox.$k" ($v.Replace('{site}', $slug))
    }
    $user = if ($Site.proxmox.service_account -and $Site.proxmox.service_account.user) { [string] $Site.proxmox.service_account.user } else { [string] $Product.proxmox.service_account.user }
    Set-LabValue $r 'proxmox.service_account.user' ($user.Replace('{site}', $slug))
    Set-LabValue $r 'proxmox.storage' (Copy-LabObject $Site.proxmox.storage)
    # clone_mode: the product default, unless the site's storage needs 'full'.
    if ($Site.proxmox.clone_mode) { Set-LabValue $r 'proxmox.clone_mode' ([string] $Site.proxmox.clone_mode).ToLowerInvariant() }
    elseif (-not $r.proxmox.clone_mode) { Set-LabValue $r 'proxmox.clone_mode' 'linked' }

    # Borrowed templates (1.7, site.yaml templates.shared_from): this site clones
    # another lab's templates instead of building its own. Its own template range
    # stays reserved (vmid_first/last, unchanged); shared_vmid_first/last are the
    # owner's range, where the current version is the newest site-neutral one.
    $from = $null
    if ($Site.templates -and $Site.templates.shared_from -and "$($Site.templates.shared_from.vmid_base)" -match '^\d+$') {
        $from = [int] $Site.templates.shared_from.vmid_base
    }
    Set-LabValue $r 'proxmox.templates_from' $from

    foreach ($t in $r.templates.PSObject.Properties) {
        if ($null -ne $from) {
            $t.Value | Add-Member -NotePropertyName shared_vmid_first -NotePropertyValue ($from + [int] $t.Value.vmid_offsets.first) -Force
            $t.Value | Add-Member -NotePropertyName shared_vmid_last  -NotePropertyValue ($from + [int] $t.Value.vmid_offsets.last) -Force
        }
        # Versioned templates: each build takes the next free VMID in the range.
        $t.Value | Add-Member -NotePropertyName vmid_first -NotePropertyValue ($base + [int] $t.Value.vmid_offsets.first) -Force
        $t.Value | Add-Member -NotePropertyName vmid_last  -NotePropertyValue ($base + [int] $t.Value.vmid_offsets.last) -Force
        if ($t.Value.build) {
            $t.Value.build | Add-Member -NotePropertyName staging_vmid -NotePropertyValue ($base + [int] $t.Value.build.staging_vmid_offset) -Force
            $t.Value.build | Add-Member -NotePropertyName iso -NotePropertyValue $Site.isos.($t.Name) -Force
            $t.Value.build | Add-Member -NotePropertyName virtio_iso -NotePropertyValue $Site.isos.virtio -Force
        }
    }

    foreach ($srv in @($r.servers)) {
        if ($srv.slots) {
            foreach ($sl in @($srv.slots)) {
                $sl | Add-Member -NotePropertyName vmid -NotePropertyValue ($base + [int] $sl.vmid_offset) -Force
                $sl | Add-Member -NotePropertyName ipv4 -NotePropertyValue (ConvertTo-LabHostAddress -Subnet $net -HostNumber ([int] $sl.host)) -Force
            }
        } else {
            $srv | Add-Member -NotePropertyName vmid -NotePropertyValue ($base + [int] $srv.vmid_offset) -Force
            $srv | Add-Member -NotePropertyName ipv4 -NotePropertyValue (ConvertTo-LabHostAddress -Subnet $net -HostNumber ([int] $srv.host)) -Force
        }
    }
    $r
}

function ConvertTo-LabSiteSlug {
    # site.name as it may appear inside a Proxmox pool, role, tag or user name:
    # lower case, [a-z0-9-], no leading/trailing or doubled '-', at most 24
    # characters. "MidCoast Quest" -> "midcoast-quest".
    [CmdletBinding()]
    param([Parameter(Mandatory)] [AllowEmptyString()] [string] $Name)
    $s = $Name.ToLowerInvariant() -replace '[^a-z0-9-]+', '-' -replace '-{2,}', '-'
    $s = $s.Trim('-')
    if ($s.Length -gt 24) { $s = $s.Substring(0, 24).TrimEnd('-') }
    $s
}

function Import-LabInventory {
    # Reads and resolves lab.yaml + site.yaml (needs powershell-yaml).
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $ProductPath,
        [Parameter(Mandatory)] [string] $SitePath
    )
    $product = Get-LabInventory -Path $ProductPath
    $site    = Get-LabInventory -Path $SitePath
    Resolve-LabInventory -Product $product -Site $site
}

# ── Where the site's files are ──────────────────────────────────────────
# A site's own files (site.yaml, the ledger instances.yaml, an optional
# deny.txt) live in one site directory, outside the product: the product repo
# is shared by every site. The directory is the first of:
#   1. $env:MIDCOAST_LAB_SITE (workstations; refused on MGMT, where the
#      handover must carry the site with the repo folder)
#   2. <repo>/site/   (gitignored in the product; a clone of the site's repo)
#   3. <repo>/inventory/  (the old layout, before LAB-261128-00; warns)
# that holds site.yaml. site/site.yaml and inventory/site.yaml both present is
# an error: two copies would drift. With none, it's <repo>/site, so "not found"
# messages name the place a new site should use.

$script:LabSiteFileNames = @{ site = 'site.yaml'; ledger = 'instances.yaml'; deny = 'deny.txt' }
$script:LabOldLayoutWarned = $false

function Test-LabMgmtRepo {
    # True when RepoRoot is the pipeline's repo on MGMT (lab.yaml
    # handover.repo_path, C:\MidCoastLab\repo). Read without YAML.
    param([Parameter(Mandatory)] [string] $RepoRoot)
    $lab = Join-Path $RepoRoot 'inventory/lab.yaml'
    $mgmtRepo = 'C:\MidCoastLab\repo'
    if (Test-Path $lab) {
        $line = Select-String -Path $lab -Pattern '^\s*repo_path:\s*"?([^"#]+?)"?\s*(#.*)?$' -List
        if ($line) { $mgmtRepo = $line.Matches[0].Groups[1].Value.Trim() }
    }
    $a = [IO.Path]::GetFullPath($RepoRoot).TrimEnd('\', '/')
    $b = $mgmtRepo.TrimEnd('\', '/')
    [string]::Equals($a, $b, [StringComparison]::OrdinalIgnoreCase)
}

function Get-LabSiteDirectory {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $RepoRoot)
    $fromEnv = $env:MIDCOAST_LAB_SITE
    if ($fromEnv) {
        if (Test-LabMgmtRepo -RepoRoot $RepoRoot) {
            throw "MIDCOAST_LAB_SITE is set ($fromEnv), but this is the pipeline's repo on MGMT ($RepoRoot): there the site must be the site\ folder in the repo, so the handover carries it. Clear the variable."
        }
        if (-not (Test-Path (Join-Path $fromEnv 'site.yaml'))) {
            throw "MIDCOAST_LAB_SITE is $fromEnv, which has no site.yaml."
        }
        return [IO.Path]::GetFullPath($fromEnv)
    }
    $new = Join-Path $RepoRoot 'site'
    $old = Join-Path $RepoRoot 'inventory'
    $hasNew = Test-Path (Join-Path $new 'site.yaml')
    $hasOld = Test-Path (Join-Path $old 'site.yaml')
    if ($hasNew -and $hasOld) {
        throw "Two site.yaml files: $(Join-Path $new 'site.yaml') and $(Join-Path $old 'site.yaml'). Keep the one in site\ (with instances.yaml next to it) and delete the other."
    }
    if ($hasOld) {
        if (-not $script:LabOldLayoutWarned) {
            Write-Warning "This site still uses the old layout (inventory/site.yaml and inventory/instances.yaml). It works, but move both into site/ when convenient (CHANGELOG, LAB-261128-00)."
            $script:LabOldLayoutWarned = $true
        }
        return $old
    }
    $new
}

function Get-LabSiteFile {
    # A site file's path (which may not exist yet): site (site.yaml), ledger
    # (instances.yaml) or deny (deny.txt), all from Get-LabSiteDirectory.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $RepoRoot,
        [Parameter(Mandatory)] [ValidateSet('site', 'ledger', 'deny')] [string] $Name
    )
    Join-Path (Get-LabSiteDirectory -RepoRoot $RepoRoot) $script:LabSiteFileNames[$Name]
}

function ConvertTo-LabYymmdd {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Date)
    if ($Date -is [datetime]) { return $Date.ToString('yyMMdd') }
    $s = [string] $Date
    if ($s -notmatch '^\d{6}$') { throw "Build date '$s' is not YYMMDD." }
    $s
}

function New-LabHostname {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Role,
        [Parameter(Mandatory)] $BuildDate,
        [Parameter(Mandatory)] [string] $Sequence,
        [string] $Format = '{role}-{yymmdd}-{sequence}',
        [int]    $MaxLength = 15
    )
    $seq  = '{0:D2}' -f [int] $Sequence
    $name = $Format.Replace('{role}', $Role.ToUpper()).Replace('{yymmdd}', (ConvertTo-LabYymmdd $BuildDate)).Replace('{sequence}', $seq)
    if ($name.Length -gt $MaxLength) {
        throw "Generated hostname '$name' is $($name.Length) characters; the limit is $MaxLength."
    }
    if ($name -notmatch '^[A-Za-z0-9-]+$' -or $name -match '^\d+$') {
        throw "Generated hostname '$name' is not a valid computer name."
    }
    $name
}

function Get-LabTemplateKey {
    # The templates.<key> in lab.yaml whose template_name is $Family
    # (WIN2022-TEMPLATE -> windows_server_2022), or $null. Build-LabTemplate's
    # -Template takes the key, so messages that tell someone what to build use this.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Inventory,
        [Parameter(Mandatory)] [string] $Family
    )
    @($Inventory.templates.PSObject.Properties | Where-Object { $_.Value.template_name -eq $Family } | ForEach-Object Name)[0]
}

function Test-LabRoleTailscale {
    # True when machines of this role join the tailnet: site.yaml
    # tailscale.enabled for the whole site, and tailscale: true on the role in
    # lab.yaml (1.8; a missing value is false). Before 1.8 every DC and MGMT
    # joined; since 1.8 lab.yaml turns it on for MGMT only (issue #26).
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Inventory,
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $Role
    )
    if (-not ($Inventory.tailscale -and $Inventory.tailscale.enabled -eq $true)) { return $false }
    $defs = @($Inventory.servers | Where-Object { $_.role -eq $Role })
    [bool] (@($defs | Where-Object { $_.tailscale -eq $true }).Count -gt 0)
}

function Get-LabRoleDefinition {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Inventory,
        [Parameter(Mandatory)] [string] $Role,
        [string] $Sequence
    )
    $defs = @($Inventory.servers | Where-Object { $_.role -eq $Role })
    if ($Sequence) {
        $match = @($defs | Where-Object { -not $_.sequence -or ('{0:D2}' -f [int] $_.sequence) -eq ('{0:D2}' -f [int] $Sequence) })
        if ($match.Count -ge 1) { $defs = $match }
    }
    if ($defs.Count -eq 0) { throw "No server definition for role '$Role'." }
    $defs[0]
}

function Get-LabDomainDN {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Inventory)
    (($Inventory.identity.active_directory.domain -split '\.') | ForEach-Object { "DC=$_" }) -join ','
}

function ConvertTo-LabOUDistinguishedName {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $OUPath,
        [Parameter(Mandatory)] [string] $DomainDN
    )
    # 'Admin/Tier0/Accounts' -> 'OU=Accounts,OU=Tier0,OU=Admin,DC=ad,DC=midcoast,DC=quest'
    $parts = $OUPath.Split('/')
    [array]::Reverse($parts)
    (($parts | ForEach-Object { "OU=$_" }) -join ',') + ',' + $DomainDN
}

function Get-LabPrefixLength {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Inventory)
    [int] ($Inventory.network.subnet -split '/')[1]
}

function Get-LabRoleAddresses {
    # Every address a role can hold (all slots, or its single ipv4).
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Inventory,
        [Parameter(Mandatory)] [string] $Role
    )
    $def = Get-LabRoleDefinition -Inventory $Inventory -Role $Role
    if ($def.slots) { @($def.slots | ForEach-Object { [string] $_.ipv4 }) } else { @([string] $def.ipv4) }
}

function Get-LabDnsClientServers {
    # A lab machine's DNS servers (LAB-261127-01, issue #27). They come from the DC
    # pool's slots, not from which DCs are active, so they never change and a DC
    # rotation has no DNS client to update.
    #   A DC:              the other slots (slot order), then loopback (DNS-004).
    #   Everything else:   every DC slot, in slot order (A, B, C).
    # One slot is empty outside a rotation; Windows moves past a server that doesn't
    # answer after about a second and prefers the one that did, so it costs an
    # occasional slow lookup, not failures. At least two slots always hold a DC.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Inventory,
        [Parameter(Mandatory)] [string] $Role,
        # A DC's own address (left out of its list).
        [string] $IPv4
    )
    $def = Get-LabRoleDefinition -Inventory $Inventory -Role 'DC'
    if (-not $def.slots) { throw "lab.yaml role DC has no slots." }
    $slots = @(@($def.slots) | Sort-Object { [string] $_.id } | ForEach-Object { [string] $_.ipv4 })
    if ($Role -ne 'DC') { return $slots }
    if (-not $IPv4) { throw "Get-LabDnsClientServers: a DC needs -IPv4 (its own address)." }
    @(@($slots | Where-Object { $_ -ne $IPv4 }) + '127.0.0.1')
}

# ── Tiering ─────────────────────────────────────────────────────────────

function Get-LabTierOU {
    # 'Admin/Tier0/Accounts' etc. for a tier and kind (Accounts, Groups, ServiceAccounts, Servers, Devices).
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Inventory,
        [Parameter(Mandatory)] [int] $Tier,
        [Parameter(Mandatory)] [ValidateSet('Accounts', 'Groups', 'ServiceAccounts', 'Servers', 'Devices')] [string] $Kind
    )
    $t = @($Inventory.tiering.tiers | Where-Object { [int] $_.id -eq $Tier })[0]
    if (-not $t) { throw "Tier $Tier is not defined in tiering.tiers." }
    "$($t.ou)/$Kind"
}

function Get-LabOUTier {
    # Tier of a computer OU path: longest matching entry in tiering.computer_ous.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Inventory,
        [Parameter(Mandatory)] [string] $OUPath
    )
    $best = $null; $bestLen = -1
    foreach ($p in $Inventory.tiering.computer_ous.PSObject.Properties) {
        if (($OUPath -eq $p.Name -or $OUPath.StartsWith("$($p.Name)/")) -and $p.Name.Length -gt $bestLen) {
            $best = [int] $p.Value; $bestLen = $p.Name.Length
        }
    }
    $best
}

function Get-LabComputerOUs {
    # Every OU computer objects can land in (excluding the built-in Domain
    # Controllers OU): domain-join delegation and LAPS are applied to these.
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Inventory)
    $paths = @($Inventory.placement.default_computers) +
             @($Inventory.placement.roles.PSObject.Properties | ForEach-Object Value) +
             @($Inventory.tiering.computer_ous.PSObject.Properties | ForEach-Object Name)
    @($paths | Where-Object { $_ -and $_ -ne 'Domain Controllers' } | Sort-Object -Unique)
}

function Get-LabGroupNames {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Inventory)
    @($Inventory.groups.administrative | ForEach-Object { if ($_ -is [string]) { $_ } else { $_.name } })
}

function Get-LabInstances {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Path)
    $ledger = Get-LabInventory -Path $Path
    if ($null -eq $ledger -or $null -eq $ledger.instances) { return @() }
    @($ledger.instances)
}

function Get-LabTemplateVersions {
    # Template versions recorded in the ledger (templates:), oldest first.
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Path)
    $ledger = Get-LabInventory -Path $Path
    if ($null -eq $ledger -or $null -eq $ledger.templates) { return @() }
    @($ledger.templates)
}

function Get-LabActiveDCs {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [object[]] $Instances)
    @($Instances | Where-Object { $_.role -eq 'DC' -and $_.state -eq 'active' } | Sort-Object build_date, sequence)
}

Export-ModuleMember -Function Get-LabInventory, ConvertTo-LabYymmdd, New-LabHostname,
    Get-LabRoleDefinition, Test-LabRoleTailscale, Get-LabTemplateKey, Get-LabDomainDN, ConvertTo-LabOUDistinguishedName,
    Get-LabPrefixLength, Get-LabRoleAddresses, Get-LabDnsClientServers, ConvertTo-LabSiteSlug, Get-LabInstances, Get-LabTemplateVersions, Get-LabActiveDCs,
    Get-LabTierOU, Get-LabOUTier, Get-LabComputerOUs, Get-LabGroupNames,
    ConvertTo-LabHostAddress, Resolve-LabInventory, Import-LabInventory,
    Get-LabSiteDirectory, Get-LabSiteFile
