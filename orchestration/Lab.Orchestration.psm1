#Requires -Version 7.2
# Lab.Orchestration: MGMT side of the pipeline (PowerShell 7).
#
# Requires: powershell-yaml, Microsoft.PowerShell.SecretManagement,
#           SecretManagement.KeePass (vault named in inventory.secrets.vault),
#           terraform, packer, git on PATH.

$script:RepoRoot = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $script:RepoRoot 'platform/modules/Lab.Inventory/Lab.Inventory.psm1') -Force -DisableNameChecking -Global
Import-Module powershell-yaml -ErrorAction Stop

# ── Repo, inventory, ledger ───────────────────────────────────────────────

function Get-LabRepoRoot { $script:RepoRoot }

function Get-LabInventoryPath { Join-Path $script:RepoRoot 'inventory/lab.yaml' }
function Get-LabSitePath      { Join-Path $script:RepoRoot 'inventory/site.yaml' }
function Get-LabResolvedPath  { Join-Path $script:RepoRoot 'inventory/resolved/inventory.json' }

function Get-LabResolvedInventory {
    # lab.yaml + site.yaml -> resolved inventory. Also writes it to
    # inventory/resolved/inventory.json (gitignored), which Terraform and
    # Packer read, so every tool sees the same merge.
    [CmdletBinding()]
    param([switch] $NoExport)
    $inv = Import-LabInventory -ProductPath (Get-LabInventoryPath) -SitePath (Get-LabSitePath)
    if (-not $NoExport) { Export-LabResolvedInventory -Inventory $inv }
    $inv
}

function Export-LabResolvedInventory {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Inventory)
    $path = Get-LabResolvedPath
    New-Item -ItemType Directory -Path (Split-Path $path -Parent) -Force | Out-Null
    $Inventory | ConvertTo-Json -Depth 30 | Set-Content -Path $path -Encoding utf8NoBOM
}
function Get-LabLedgerPath    { Join-Path $script:RepoRoot 'inventory/instances.yaml' }

function Get-LabRelease {
    # The release name from lab.yaml (LAB-<YYMMDD>-<NN>), read without YAML so it
    # works anywhere; $null if the line is missing.
    $line = Select-String -Path (Join-Path $script:RepoRoot 'inventory/lab.yaml') -Pattern '^release:\s*"?([A-Za-z0-9-]+)' -List
    if ($line) { $line.Matches[0].Groups[1].Value } else { $null }
}

function Get-LabPlatformVersion {
    # What built a machine or template: the release name plus the exact commit,
    # e.g. "LAB-261105-00 (7598827)". "-dirty" means uncommitted changes.
    Push-Location $script:RepoRoot
    try {
        $sha = (& git rev-parse --short HEAD 2>$null)
        $commit = if (-not $sha) { 'uncommitted' } elseif (& git status --porcelain 2>$null) { "$sha-dirty" } else { $sha }
    } finally { Pop-Location }
    $release = Get-LabRelease
    if ($release) { "$release ($commit)" } else { $commit }
}

function Save-LabLedger {
    # Writes instances.yaml. -Templates replaces the template list; without it
    # the template list already in the file is kept, so callers that only
    # change instances never drop template records.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Instances,
        [AllowEmptyCollection()] [object[]] $Templates,
        [string] $Path = (Get-LabLedgerPath)
    )
    if (-not $PSBoundParameters.ContainsKey('Templates')) {
        # Keep what the file has; a new file (e.g. a plan-only copy) inherits the real ledger's.
        $from = if (Test-Path $Path) { $Path } else { Get-LabLedgerPath }
        $Templates = if (Test-Path $from) { @(Get-LabTemplateVersions -Path $from) } else { @() }
    }
    $header = @(
        '# Instance ledger. WRITTEN BY THE PIPELINE; do not edit by hand.'
        '#'
        '# Records which machines exist: build date, sequence and (for DCs and MGMT) slot,'
        '# so generated hostnames stay stable across Terraform runs, and which template'
        '# version each was cloned from. Commit it after every pipeline run, so git'
        '# history doubles as the build history.'
        '#'
        '# instances state: building | active | retiring'
        '# templates state: current | superseded (deleted once no instance uses it)'
    ) -join "`n"
    $ordered = foreach ($i in $Instances) {
        $h = [ordered]@{}
        foreach ($k in 'name', 'role', 'origin', 'sequence', 'build_date', 'slot', 'vmid', 'ipv4', 'template_vmid', 'clone_mode', 'state', 'dc_mode', 'replaces', 'created_utc', 'updated_utc') {
            $v = $i.$k
            if ($null -ne $v -and "$v" -ne '') { $h[$k] = $v }
        }
        $h
    }
    $tOrdered = foreach ($t in $Templates) {
        $h = [ordered]@{}
        foreach ($k in 'name', 'family', 'key', 'vmid', 'build_date', 'sequence', 'state', 'created_utc', 'updated_utc') {
            $v = $t.$k
            if ($null -ne $v -and "$v" -ne '') { $h[$k] = $v }
        }
        $h
    }
    $iBody = if (@($ordered).Count -eq 0) { 'instances: []' } else { (ConvertTo-Yaml @{ instances = @($ordered) }) -join "`n" }
    $tBody = if (@($tOrdered).Count -eq 0) { 'templates: []' } else { (ConvertTo-Yaml @{ templates = @($tOrdered) }) -join "`n" }
    Set-Content -Path $Path -Value "$header`n$($iBody.TrimEnd())`n$($tBody.TrimEnd())`n" -Encoding utf8NoBOM
}

# ── Template versions ─────────────────────────────────────────────────────

function Get-LabCurrentTemplate {
    # The current version of a template family (e.g. WIN2022-TEMPLATE), or $null.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Family,
        [AllowEmptyCollection()] [object[]] $Templates = @(Get-LabTemplateVersions -Path (Get-LabLedgerPath))
    )
    @($Templates | Where-Object { $_.family -eq $Family -and $_.state -eq 'current' } | Sort-Object { [int] $_.vmid })[-1]
}

function New-LabTemplateVersion {
    # Allocates the next version of a template: name <family>-<YYMMDD>-<NN>,
    # VMID = lowest in the template's range that the ledger doesn't hold and
    # Proxmox doesn't have. Doesn't save anything.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Inventory,
        [Parameter(Mandatory)] [string] $Key,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Templates,
        [Parameter(Mandatory)] [string] $Token,
        [datetime] $Date = (Get-Date)
    )
    $tpl    = $Inventory.templates.$Key
    $family = $tpl.template_name
    $stamp  = $Date.ToString('yyMMdd')
    # Sequence: one past the highest used today (ledger or Proxmox), so a name
    # is never reused even after an older version is deleted.
    $node = $Inventory.proxmox.node
    $pveNames = @()
    try { $pveNames = @(Invoke-LabPveApi -Inventory $Inventory -Token $Token -Method GET -Path "/nodes/$node/qemu" | ForEach-Object name) } catch { }
    $prefix = "$family-$stamp-"
    $usedSeq = @(@($Templates | Where-Object { $_.family -eq $family -and "$($_.build_date)" -eq $stamp } | ForEach-Object { [int] $_.sequence }) +
                 @($pveNames | Where-Object { $_ -like "$prefix*" } | ForEach-Object { $n = $_.Substring($prefix.Length); if ($n -match '^\d+$') { [int] $n } }))
    $seq = if ($usedSeq.Count -gt 0) { [int] ($usedSeq | Measure-Object -Maximum).Maximum + 1 } else { 0 }
    $held = @($Templates | ForEach-Object { [int] $_.vmid })
    $vmid = $null
    foreach ($id in ([int] $tpl.vmid_first)..([int] $tpl.vmid_last)) {
        if ($held -contains $id) { continue }
        if (Test-LabPveVm -Inventory $Inventory -Token $Token -VmId $id) { continue }
        # Cluster-wide: is the ID free anywhere (other nodes, VMs the token can't see)?
        try { $null = Invoke-LabPveApi -Inventory $Inventory -Token $Token -Method GET -Path "/cluster/nextid?vmid=$id" } catch { continue }
        $vmid = $id; break
    }
    if ($null -eq $vmid) {
        throw "No free VMID for a new $family in $($tpl.vmid_first)-$($tpl.vmid_last): every slot holds a version that's still in use. Rotate the VMs still on old versions, then run Build-LabTemplate again (it deletes unused versions first)."
    }
    [pscustomobject][ordered]@{
        name        = '{0}-{1}-{2:D2}' -f $family, $stamp, $seq
        family      = $family
        key         = $Key
        vmid        = $vmid
        build_date  = $stamp
        sequence    = '{0:D2}' -f $seq
        state       = 'current'
        created_utc = (Get-Date).ToUniversalTime().ToString('o')
    }
}

function Remove-LabUnusedTemplates {
    # Deletes superseded template versions that no instance in the ledger was
    # cloned from, and drops them from the ledger. Proxmox itself refuses to
    # delete a template that still has linked clones; that is reported and the
    # version is kept. Never touches the current version of a family.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Inventory,
        [string] $Token = (Get-LabPveToken -Inventory $Inventory)
    )
    $path      = Get-LabLedgerPath
    $instances = @(Get-LabInstances -Path $path)
    $templates = @(Get-LabTemplateVersions -Path $path)
    $inUse     = @($instances | Where-Object { $_.template_vmid } | ForEach-Object { [int] $_.template_vmid })
    $node      = $Inventory.proxmox.node
    $keep      = [System.Collections.Generic.List[object]]::new()
    foreach ($t in $templates) {
        if ($t.state -ne 'superseded' -or $inUse -contains [int] $t.vmid) { $keep.Add($t); continue }
        $vm = Test-LabPveVm -Inventory $Inventory -Token $Token -VmId ([int] $t.vmid)
        if (-not $vm) { Write-Host "Template $($t.name) (VMID $($t.vmid)) is already gone; dropping it from the ledger."; continue }
        $tags = @(([string] $vm.tags) -split '[;,\s]+')
        if (-not $vm.template -or $tags -notcontains $Inventory.proxmox.tag -or $vm.name -ne $t.name) {
            Write-Warning "VMID $($t.vmid) is '$($vm.name)', not template $($t.name); leaving it alone. Check it by hand."
            $keep.Add($t); continue
        }
        try {
            Wait-LabPveTask -Inventory $Inventory -Token $Token -Upid (Invoke-LabPveApi -Inventory $Inventory -Token $Token -Method DELETE -Path "/nodes/$node/qemu/$($t.vmid)?purge=1&destroy-unreferenced-disks=1")
            Write-Host "Deleted unused template $($t.name) (VMID $($t.vmid))."
        } catch {
            Write-Warning "Couldn't delete template $($t.name) (VMID $($t.vmid)); it probably still has linked clones: $($_.Exception.Message)"
            $keep.Add($t)
        }
    }
    if ($keep.Count -ne $templates.Count) { Save-LabLedger -Instances $instances -Templates @($keep) }
}

function New-LabInstance {
    # Allocates the next instance of a role: build date = today, lowest free
    # sequence for that role and day, and (DCs) the first free slot.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Inventory,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Instances,
        [Parameter(Mandatory)] [string] $Role,
        [datetime] $Date = (Get-Date)
    )
    # Note: PowerShell names are case-insensitive, so never reuse "$date" here.
    $def   = Get-LabRoleDefinition -Inventory $Inventory -Role $Role
    $stamp = $Date.ToString('yyMMdd')
    $used  = @($Instances | Where-Object { $_.role -eq $Role -and "$($_.build_date)" -eq $stamp } | ForEach-Object { [int] $_.sequence })
    $seq  = 0
    while ($used -contains $seq) { $seq++ }

    $inst = [ordered]@{
        role        = $Role
        sequence    = '{0:D2}' -f $seq
        build_date  = $stamp
        state       = 'building'
        created_utc = (Get-Date).ToUniversalTime().ToString('o')
    }
    if ($def.slots) {
        $taken = @($Instances | Where-Object { $_.role -eq $Role } | ForEach-Object slot)
        $slot  = @($def.slots | Where-Object { $taken -notcontains $_.id })[0]
        if (-not $slot) { throw "No free $Role slot; every slot is in use." }
        $inst.slot = $slot.id
        $inst.vmid = [int] $slot.vmid
        $inst.ipv4 = $slot.ipv4
    } else {
        if (@($Instances | Where-Object role -eq $Role).Count -gt 0) { throw "$Role already has an instance." }
        $inst.vmid = [int] $def.vmid
        $inst.ipv4 = $def.ipv4
    }
    $inst.name = New-LabHostname -Role $Role -BuildDate $stamp -Sequence $inst.sequence `
        -Format $Inventory.naming.format -MaxLength ([int] $Inventory.naming.max_length)
    # Pin the template version: the VM stays a (linked) clone of exactly this
    # template, even after a newer version is built.
    $current = Get-LabCurrentTemplate -Family $def.template
    if (-not $current) { throw "No $($def.template) has been built yet. Run ./orchestration/Build-LabTemplate.ps1 -Template $(Get-LabTemplateKey -Inventory $Inventory -Family $def.template) first." }
    $inst.template_vmid = [int] $current.vmid
    # And the clone mode: changing proxmox.clone_mode later affects only new VMs
    # (changing it on an existing VM would force Terraform to replace it).
    $inst.clone_mode = [string] $Inventory.proxmox.clone_mode
    [pscustomobject] $inst
}

function Set-LabInstanceState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object[]] $Instances,
        [Parameter(Mandatory)] [string] $Name,
        [Parameter(Mandatory)] [ValidateSet('building', 'active', 'retiring')] [string] $State
    )
    foreach ($i in $Instances) {
        if ($i.name -eq $Name) {
            $i.state = $State
            $i | Add-Member -NotePropertyName updated_utc -NotePropertyValue ((Get-Date).ToUniversalTime().ToString('o')) -Force
        }
    }
    $Instances
}

# ── Secrets (KeePass via SecretManagement) ───────────────────────────────

function Unlock-LabVault {
    # Unlocks the KeePass vault for this session, asking for the master password.
    # Every pipeline script calls Get-LabSecretText, which calls this the first
    # time a read fails, so a new window never needs a separate Unlock-SecretVault.
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Inventory)
    $vault = $Inventory.secrets.vault
    if (-not (Get-SecretVault -Name $vault -ErrorAction SilentlyContinue)) {
        throw "Vault $vault isn't registered for this account. Run ./setup/mgmt/Initialize-LabVault.ps1 -DatabasePath $((Get-LabMgmtDefinition -Inventory $Inventory).handover.vault_path)"
    }
    if (-not [Environment]::UserInteractive) { throw "Vault $vault is locked and this session can't prompt. Run  Unlock-SecretVault -Name $vault  first." }
    Unlock-SecretVault -Name $vault -Password (Read-Host "KeePass master password for vault $vault" -AsSecureString)
}

function Get-LabSecretText {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Inventory,
        [Parameter(Mandatory)] [string] $Name
    )
    $vault = $Inventory.secrets.vault
    try { $value = Get-Secret -Vault $vault -Name $Name -AsPlainText -ErrorAction Stop }
    catch {
        # The usual cause is a locked vault (a new window, or its unlock timed
        # out): ask for the master password once and try again.
        $first = $_.Exception.Message
        if ($script:VaultUnlockTried) { throw "Couldn't read '$Name' from vault ${vault}: $first" }
        $script:VaultUnlockTried = $true
        try { Unlock-LabVault -Inventory $Inventory } catch { throw "Couldn't read '$Name' from vault ${vault} ($first). $($_.Exception.Message)" }
        try { $value = Get-Secret -Vault $vault -Name $Name -AsPlainText -ErrorAction Stop }
        catch { throw "Couldn't read '$Name' from vault ${vault} after unlocking it; the entry is probably missing: run ./setup/mgmt/Initialize-LabVault.ps1. ($($_.Exception.Message))" }
    }
    $script:VaultUnlockTried = $false   # a later lock (timeout) may ask again
    if ($value -is [pscredential]) { $value = $value.GetNetworkCredential().Password }
    if (-not $value) { throw "Secret '$Name' is empty in vault $($Inventory.secrets.vault)." }
    [string] $value
}

# ── Git identity ──────────────────────────────────────────────────────────

function Get-LabGitIdentity {
    # The name and e-mail the pipeline's commits are made under, derived from
    # site.yaml: the administrator whose username matches the signed-in account
    # (with or without the -a suffix), else the first tier 0 administrator;
    # e-mail <username>@<tenant domain> (their UPN). No separate site setting to
    # fill in, and the same answer on every MGMT.
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Inventory)
    $model  = $Inventory.identity.administrative_model
    $admins = @($model.administrators)
    $me     = [string] $env:USERNAME
    if ($model.account_suffix -and $me.EndsWith($model.account_suffix)) { $me = $me.Substring(0, $me.Length - $model.account_suffix.Length) }
    $a = @($admins | Where-Object { $_.username -eq $me })[0]
    if (-not $a) { $a = @($admins | Where-Object { [int] $_.tier -eq 0 })[0] }
    if (-not $a) { $a = $admins[0] }
    if (-not $a) { throw 'site.yaml has no administrators; git needs a name and e-mail for commits.' }
    [pscustomobject]@{
        Name  = (("$($a.given_name) $($a.surname)").Trim() -replace '\s+', ' ')
        Email = "$($a.username)@$($Inventory.identity.entra.tenant_domain)"
    }
}

function Set-LabGitIdentity {
    # Sets git's global user.name / user.email for the signed-in account when
    # they aren't set yet (a new profile on a new MGMT). Never overwrites a
    # value the person set themselves. Returns a one-line status.
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Inventory)
    $git = Get-Command git -ErrorAction SilentlyContinue
    if (-not $git) { return 'git not on PATH; identity not set' }
    $id = Get-LabGitIdentity -Inventory $Inventory
    $set = @()
    foreach ($pair in @(@('user.name', $id.Name), @('user.email', $id.Email))) {
        $current = & git config --global --get $pair[0] 2>$null
        if (-not $current) { & git config --global $pair[0] $pair[1]; $set += "$($pair[0])=$($pair[1])" }
    }
    if ($set.Count -gt 0) { "git identity set for $env:USERNAME: $($set -join ', ')" } else { "git identity already set for $env:USERNAME" }
}

function Get-LabSecretCredential {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Inventory,
        [Parameter(Mandatory)] [string] $UserName,
        [Parameter(Mandatory)] [string] $SecretName
    )
    [pscredential]::new($UserName, (ConvertTo-SecureString (Get-LabSecretText -Inventory $Inventory -Name $SecretName) -AsPlainText -Force))
}

# ── Proxmox API ───────────────────────────────────────────

function Invoke-LabPveApi {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Inventory,
        [Parameter(Mandatory)] [string] $Token,         # "user@realm!name=secret"
        [Parameter(Mandatory)] [ValidateSet('GET', 'POST', 'PUT', 'DELETE')] [string] $Method,
        [Parameter(Mandatory)] [string] $Path,          # e.g. /nodes/pve01/qemu
        [hashtable] $Body
    )
    $base = $Inventory.proxmox.endpoint.TrimEnd('/') + '/api2/json'
    $p = @{
        Method               = $Method
        Uri                  = $base + $Path
        Headers              = @{ Authorization = "PVEAPIToken=$Token" }
        # .NET rejects Proxmox's "PVEAPIToken=user!name=secret" as a malformed
        # Authorization header unless validation is skipped.
        SkipHeaderValidation = $true
        SkipCertificateCheck = [bool] $Inventory.proxmox.insecure_tls
        ErrorAction          = 'Stop'
    }
    if ($Body) { $p.Body = $Body }
    try { (Invoke-RestMethod @p).data }
    catch {
        # Never let the token secret reach the console or a log.
        $secret = ($Token -split '=', 2)[-1]
        $text = "$($_.Exception.Message) $($_.ErrorDetails.Message)"
        if ($secret -and $text.Contains($secret)) {
            throw "Proxmox API $Method $Path failed: $($_.Exception.Message.Replace($secret, '<redacted>'))"
        }
        throw
    }
}

function Wait-LabPveTask {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Inventory,
        [Parameter(Mandatory)] [string] $Token,
        [string] $Upid,
        [int] $TimeoutSeconds = 1800
    )
    if (-not $Upid -or $Upid -notmatch '^UPID:') { return }
    $node = $Inventory.proxmox.node
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        $s = Invoke-LabPveApi -Inventory $Inventory -Token $Token -Method GET -Path "/nodes/$node/tasks/$([uri]::EscapeDataString($Upid))/status"
        if ($s.status -eq 'stopped') {
            if ($s.exitstatus -ne 'OK' -and $s.exitstatus -notlike 'WARNINGS*') { throw "Proxmox task failed: $($s.exitstatus) ($Upid)" }
            if ($s.exitstatus -like 'WARNINGS*') { Write-Warning "Proxmox task finished with $($s.exitstatus) ($Upid)" }
            return
        }
        Start-Sleep -Seconds 5
    }
    throw "Proxmox task timed out: $Upid"
}

function Test-LabPveVm {
    [CmdletBinding()]
    param($Inventory, [string] $Token, [int] $VmId)
    $node = $Inventory.proxmox.node
    $vms = Invoke-LabPveApi -Inventory $Inventory -Token $Token -Method GET -Path "/nodes/$node/qemu"
    @($vms | Where-Object vmid -eq $VmId)[0]
}

# ── Terraform ─────────────────────────────────────────────────────────────

function ConvertFrom-LabPlanJson {
    # Fails closed: no readable plan, no apply.
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $PlanFile)
    $json = & terraform show -json $PlanFile
    if ($LASTEXITCODE -ne 0) { throw "terraform show -json failed (exit $LASTEXITCODE)." }
    $plan = $json | ConvertFrom-Json
    if (-not $plan -or -not $plan.format_version) { throw 'terraform show -json returned no plan; refusing to continue.' }
    $plan
}

function Invoke-LabTerraform {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Inventory,
        [Parameter(Mandatory)] [ValidateSet('init', 'plan', 'apply', 'output')] [string] $Command,
        # Plan against a different ledger (used by -PlanOnly so nothing is written).
        [string] $LedgerPath,
        # plan: return the parsed JSON plan instead of printing it.
        [switch] $Json,
        # Only Invoke-LabMgmtRotation -Stage Abort may apply while handed over.
        [switch] $IgnoreHandoverLock,
        # apply: the instance names this run expects Terraform to destroy. Any
        # other delete or replace refuses the whole plan.
        [string[]] $AllowDelete = @()
    )
    if ($Command -eq 'apply' -and -not $IgnoreHandoverLock) { Assert-LabNotHandedOver -Inventory $Inventory }
    Export-LabResolvedInventory -Inventory $Inventory
    $tfDir = Join-Path $script:RepoRoot 'terraform'
    $state = $Inventory.terraform.state.path
    $stateDir = Split-Path $state -Parent
    if (-not (Test-Path $stateDir)) { New-Item -ItemType Directory -Path $stateDir -Force | Out-Null }

    $sa = $Inventory.proxmox.service_account
    $tokenSecret = Get-LabSecretText -Inventory $Inventory -Name $Inventory.secrets.entries.proxmox_terraform_token
    $env:PROXMOX_VE_API_TOKEN = "$($sa.user)!$($sa.token_name)=$tokenSecret"
    try {
        Push-Location $tfDir
        switch ($Command) {
            'init'   { & terraform init -input=false -no-color }
            'plan'   {
                $planArgs = @('plan', '-input=false', '-no-color', "-state=$state")
                if ($LedgerPath) { $planArgs += "-var=ledger_path=$LedgerPath" }
                if (-not $Json) { & terraform @planArgs }
                else {
                    $planFile = Join-Path ([IO.Path]::GetTempPath()) "midcoast-$([guid]::NewGuid()).tfplan"
                    try {
                        & terraform @planArgs "-out=$planFile" | Out-Host
                        if ($LASTEXITCODE -ne 0) { throw "terraform plan failed (exit $LASTEXITCODE)." }
                        return (ConvertFrom-LabPlanJson -PlanFile $planFile)
                    } finally { Remove-Item $planFile -Force -ErrorAction SilentlyContinue }
                }
            }
            'apply'  {
                # Plan to a file, refuse anything that would delete an active
                # instance (or this machine), then apply exactly that plan.
                $planFile = Join-Path ([IO.Path]::GetTempPath()) "midcoast-$([guid]::NewGuid()).tfplan"
                try {
                    & terraform plan -input=false -no-color "-state=$state" "-out=$planFile"
                    if ($LASTEXITCODE -ne 0) { throw "terraform plan failed (exit $LASTEXITCODE)." }
                    $plan = ConvertFrom-LabPlanJson -PlanFile $planFile
                    Assert-LabSafePlan -Plan $plan -AllowDelete $AllowDelete
                    & terraform apply -input=false -no-color "-state=$state" $planFile
                } finally {
                    Remove-Item $planFile -Force -ErrorAction SilentlyContinue
                }
            }
            'output' { return (& terraform output -no-color -json "-state=$state" | ConvertFrom-Json) }
        }
        if ($LASTEXITCODE -ne 0) { throw "terraform $Command failed (exit $LASTEXITCODE)." }
    } finally {
        Pop-Location
        Remove-Item Env:\PROXMOX_VE_API_TOKEN -ErrorAction SilentlyContinue
    }
}

# ── Guest sessions (WinRM over HTTPS) ─────────────────────────────────────

# Some options exist only on Windows; MGMT gets all of them.
$known = (Get-Command New-PSSessionOption).Parameters.Keys
$sessionOptionArgs = @{}
foreach ($kv in @{ SkipCACheck = $true; SkipCNCheck = $true; SkipRevocationCheck = $true; OperationTimeout = 120000; OpenTimeout = 30000 }.GetEnumerator()) {
    if ($known -contains $kv.Key) { $sessionOptionArgs[$kv.Key] = $kv.Value }
}
$script:SessionOption = New-PSSessionOption @sessionOptionArgs

function Connect-LabGuest {
    # Tries each address, then each credential. Credentials change as a guest
    # moves from local Administrator to domain accounts during bootstrap.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string[]] $Address,
        [Parameter(Mandatory)] [pscredential[]] $Credential,
        # The VM's MAC address(es), from Proxmox. When given, a session is only
        # accepted if the guest has one of them: an address can belong to a
        # different machine (a reused DHCP lease, a stale agent report).
        [string[]] $ExpectedMac
    )
    $want = @($ExpectedMac | Where-Object { $_ } | ForEach-Object { ($_ -replace '[-:]', '').ToUpperInvariant() })
    foreach ($a in @($Address | Where-Object { $_ } | Select-Object -Unique)) {
        if (-not (Test-Connection -TargetName $a -TcpPort 5986 -TimeoutSeconds 3 -Quiet)) { continue }
        foreach ($c in $Credential) {
            $s = $null
            try {
                $s = New-PSSession -ComputerName $a -Port 5986 -UseSSL -Authentication Negotiate `
                    -Credential $c -SessionOption $script:SessionOption -ErrorAction Stop
            } catch { continue }
            # Windows client editions default to the Restricted execution policy,
            # which blocks Import-Module of the lab's modules in this session.
            # Process scope: this session only; nothing on the machine changes.
            Invoke-Command -Session $s -ScriptBlock {
                Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force -ErrorAction SilentlyContinue
            } -ErrorAction SilentlyContinue
            if ($want.Count -eq 0) { return $s }
            $have = @(Invoke-Command -Session $s -ScriptBlock {
                Get-NetAdapter -ErrorAction SilentlyContinue | ForEach-Object { ($_.MacAddress -replace '[-:]', '').ToUpperInvariant() }
            } -ErrorAction SilentlyContinue)
            if (@($have | Where-Object { $want -contains $_ }).Count -gt 0) { return $s }
            Remove-PSSession $s -ErrorAction SilentlyContinue
            if (-not $script:WrongHostWarned) { $script:WrongHostWarned = @{} }
            if (-not $script:WrongHostWarned.ContainsKey($a)) {
                $script:WrongHostWarned[$a] = $true
                Write-Warning "$a answers, but it's a different machine (MAC $($have -join ', '), expected $($want -join ', ')); ignoring it."
            }
            break   # same machine for every credential: try the next address
        }
    }
    $null
}

function Get-LabVmMac {
    # MAC address(es) of a VM's network devices, from its Proxmox config.
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Inventory, [Parameter(Mandatory)] [string] $Token, [Parameter(Mandatory)] [int] $VmId)
    $cfg = Invoke-LabPveApi -Inventory $Inventory -Token $Token -Method GET -Path "/nodes/$($Inventory.proxmox.node)/qemu/$VmId/config"
    @($cfg.PSObject.Properties | Where-Object Name -match '^net\d+$' | ForEach-Object {
        if ([string] $_.Value -match '([0-9A-Fa-f]{2}(:[0-9A-Fa-f]{2}){5})') { $Matches[1].Replace(':', '').ToUpperInvariant() }
    })
}

function Get-LabVmGuestAddress {
    # IPv4 addresses the VM's guest agent reports right now (empty if the agent
    # isn't answering yet).
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Inventory, [Parameter(Mandatory)] [string] $Token, [Parameter(Mandatory)] [int] $VmId)
    try {
        $r = Invoke-LabPveApi -Inventory $Inventory -Token $Token -Method GET -Path "/nodes/$($Inventory.proxmox.node)/qemu/$VmId/agent/network-get-interfaces"
        @(@($r.result) | ForEach-Object { @($_.'ip-addresses') } |
            Where-Object { $_.'ip-address-type' -eq 'ipv4' -and $_.'ip-address' -notmatch '^(127\.|169\.254\.|100\.(6[4-9]|[7-9]\d|1[01]\d|12[0-7])\.)' } |
            ForEach-Object { $_.'ip-address' })
    } catch { @() }
}

function Wait-LabGuest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string[]] $Address,
        [Parameter(Mandatory)] [pscredential[]] $Credential,
        [int] $TimeoutSeconds = 1800,
        [string[]] $ExpectedMac,
        # With these, the VM's current addresses are asked from its guest agent
        # on every attempt, in addition to -Address.
        $Inventory, [string] $Token, [int] $VmId
    )
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        $try = @($Address)
        if ($Inventory -and $Token -and $VmId) { $try += @(Get-LabVmGuestAddress -Inventory $Inventory -Token $Token -VmId $VmId) }
        $s = Connect-LabGuest -Address $try -Credential $Credential -ExpectedMac $ExpectedMac
        if ($s) { return $s }
        Start-Sleep -Seconds 20
    }
    throw "No WinRM/HTTPS session to $($Address -join ' or ') within $TimeoutSeconds s."
}

function New-LabPayloadArchive {
    # platform/ + inventory.json (the resolved inventory) in one zip.
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Inventory)
    $stage = Join-Path ([IO.Path]::GetTempPath()) ("midcoast-payload-" + [guid]::NewGuid())
    Copy-Item -Path (Join-Path $script:RepoRoot 'platform') -Destination $stage -Recurse
    $Inventory | ConvertTo-Json -Depth 20 | Set-Content -Path (Join-Path $stage 'inventory.json') -Encoding utf8NoBOM
    $zip = "$stage.zip"
    Compress-Archive -Path (Join-Path $stage '*') -DestinationPath $zip -Force
    Remove-Item -Path $stage -Recurse -Force
    $zip
}

function Publish-LabPayload {
    # Pushes platform, metadata and secrets, registers the bootstrap task and
    # starts it. Re-running it is safe; with -Retry it resumes a failed stage.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [System.Management.Automation.Runspaces.PSSession] $Session,
        [Parameter(Mandatory)] $Inventory,
        [Parameter(Mandatory)] [hashtable] $Metadata,
        [Parameter(Mandatory)] [hashtable] $Secrets,    # name -> plaintext
        [switch] $Retry
    )
    $zip = New-LabPayloadArchive -Inventory $Inventory
    try {
        Invoke-Command -Session $Session -ScriptBlock {
            New-Item -ItemType Directory -Path 'C:\ProgramData\MidCoastLab' -Force | Out-Null
        }
        Copy-Item -Path $zip -Destination 'C:\ProgramData\MidCoastLab\payload.zip' -ToSession $Session -Force

        Invoke-Command -Session $Session -ArgumentList @(($Metadata | ConvertTo-Json -Depth 5), $Secrets, $Retry.IsPresent) -ScriptBlock {
            param($MetadataJson, $Secrets, $Retry)
            $ErrorActionPreference = 'Stop'
            $root = 'C:\ProgramData\MidCoastLab'
            $platform = Join-Path $root 'Platform'
            if (Test-Path $platform) { Remove-Item -Path $platform -Recurse -Force }
            Expand-Archive -Path (Join-Path $root 'payload.zip') -DestinationPath $platform -Force
            Remove-Item -Path (Join-Path $root 'payload.zip') -Force
            $MetadataJson | Set-Content -Path (Join-Path $root 'metadata.json') -Encoding UTF8

            Import-Module (Join-Path $platform 'modules\Lab.System\Lab.System.psm1') -Force -DisableNameChecking
            foreach ($k in $Secrets.Keys) { Save-LabSecret -Name $k -Value $Secrets[$k] }

            if ($Retry) {
                $s = Get-LabState
                if ($s.status -eq 'Failed') { Set-LabState -Stage $s.stage -Status 'Pending' -Detail 'Retry requested' }
            }

            $task = 'MidCoastLab-Bootstrap'
            $action = New-ScheduledTaskAction -Execute 'powershell.exe' `
                -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$platform\bootstrap.ps1`""
            $trigger = New-ScheduledTaskTrigger -AtStartup
            $trigger.Delay = 'PT1M'
            $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
            # 8 hours: room for a MGMT installing RSAT from Windows Update.
            $settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Hours 8) -StartWhenAvailable -MultipleInstances IgnoreNew
            Register-ScheduledTask -TaskName $task -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
            Enable-ScheduledTask -TaskName $task | Out-Null
            Start-ScheduledTask -TaskName $task
        }
    } finally {
        Remove-Item -Path $zip -Force -ErrorAction SilentlyContinue
    }
}

function Get-LabGuestState {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [System.Management.Automation.Runspaces.PSSession] $Session)
    Invoke-Command -Session $Session -ScriptBlock {
        $p = 'C:\ProgramData\MidCoastLab\State\bootstrap.json'
        if (Test-Path $p) { Get-Content -Path $p -Raw | ConvertFrom-Json } else { $null }
    }
}

function Wait-LabBootstrap {
    # Follows bootstrap across reboots and the DHCP -> static address change.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Name,
        [Parameter(Mandatory)] [string[]] $Address,
        [Parameter(Mandatory)] [pscredential[]] $Credential,
        [int] $TimeoutSeconds = 7200,
        [string[]] $ExpectedMac,
        $Inventory, [string] $Token, [int] $VmId
    )
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $last = ''
    while ((Get-Date) -lt $deadline) {
        $try = @($Address)
        if ($Inventory -and $Token -and $VmId) { $try += @(Get-LabVmGuestAddress -Inventory $Inventory -Token $Token -VmId $VmId) }
        $s = Connect-LabGuest -Address $try -Credential $Credential -ExpectedMac $ExpectedMac
        if ($s) {
            try {
                $state = Get-LabGuestState -Session $s
                if ($state) {
                    $now = "$($state.stage)/$($state.status)"
                    if ($now -ne $last) { Write-Host ("  {0}  {1,-28} {2}" -f (Get-Date -Format 'HH:mm:ss'), $now, $state.detail); $last = $now }
                    if ($state.status -in 'Complete', 'Failed') { return $state }
                }
            } catch { } finally { Remove-PSSession $s -ErrorAction SilentlyContinue }
        }
        Start-Sleep -Seconds 30
    }
    throw "$Name did not finish bootstrap within $TimeoutSeconds s (last: $last)."
}

function Get-LabValidationReport {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [System.Management.Automation.Runspaces.PSSession] $Session)
    Invoke-Command -Session $Session -ScriptBlock {
        $p = 'C:\ProgramData\MidCoastLab\Logs\Validation\latest.json'
        if (Test-Path $p) { Get-Content -Path $p -Raw | ConvertFrom-Json } else { $null }
    }
}

function Invoke-LabRemoteValidation {
    # Re-runs the guest's role validation as SYSTEM (scheduled task), waits
    # for it, and returns the report. No secrets needed.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [System.Management.Automation.Runspaces.PSSession] $Session,
        [int] $TimeoutSeconds = 900
    )
    Invoke-Command -Session $Session -ArgumentList $TimeoutSeconds -ScriptBlock {
        param($TimeoutSeconds)
        $ErrorActionPreference = 'Stop'
        $task   = 'MidCoastLab-Validate'
        $latest = 'C:\ProgramData\MidCoastLab\Logs\Validation\latest.json'
        $before = if (Test-Path $latest) { (Get-Item $latest).LastWriteTimeUtc } else { [datetime]::MinValue }

        $action    = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument '-NoProfile -ExecutionPolicy Bypass -File "C:\ProgramData\MidCoastLab\Platform\validate.ps1"'
        $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
        $settings  = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Minutes 30) -MultipleInstances IgnoreNew
        Register-ScheduledTask -TaskName $task -Action $action -Principal $principal -Settings $settings -Force | Out-Null
        Start-ScheduledTask -TaskName $task

        $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
        do {
            Start-Sleep -Seconds 10
            $running = (Get-ScheduledTask -TaskName $task).State -eq 'Running'
            $fresh   = (Test-Path $latest) -and ((Get-Item $latest).LastWriteTimeUtc -gt $before)
        } while (($running -or -not $fresh) -and (Get-Date) -lt $deadline)
        if (-not $fresh) { throw "Validation did not produce a new report within $TimeoutSeconds s." }
        Get-Content -Path $latest -Raw | ConvertFrom-Json
    }
}

# ── Safety: handover lock and destructive-plan guard ─────────────────────

function Get-LabMgmtDefinition {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Inventory)
    Get-LabRoleDefinition -Inventory $Inventory -Role 'MGMT'
}

function Get-LabHandoverLock {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Inventory)
    $path = (Get-LabMgmtDefinition -Inventory $Inventory).handover.lock_path
    if ($path -and (Test-Path $path)) { Get-Content -Path $path -Raw | ConvertFrom-Json } else { $null }
}

function Get-LabCertLock {
    # CERT (the break/fix scenario runner, a separate project) writes this file
    # while a scenario is active: the lab's VMs are snapshotted and will be
    # rolled back. The file is JSON (scenario, started, snapshot set) but any
    # content counts as locked.
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Inventory)
    $path = (Get-LabMgmtDefinition -Inventory $Inventory).handover.cert_lock_path
    if (-not $path -or -not (Test-Path $path)) { return $null }
    try { Get-Content -Path $path -Raw | ConvertFrom-Json } catch { [pscustomobject]@{ scenario = '(unreadable)'; path = $path } }
}

function Assert-LabNotHandedOver {
    # After a MGMT handover, the old MGMT must never change the lab again:
    # its Terraform state and ledger are no longer authoritative.
    # The same check refuses to run while a CERT scenario is active: a rotation
    # or a phase in the middle of a scenario would be undone by its rollback,
    # and the ledger would then describe machines that no longer exist.
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Inventory)
    $lock = Get-LabHandoverLock -Inventory $Inventory
    if ($lock) {
        throw "This MGMT handed over to $($lock.handed_over_to) ($($lock.ipv4)) at $($lock.at). Run the pipeline from there, or roll back with Invoke-LabMgmtRotation.ps1 -Stage Abort."
    }
    $cert = Get-LabCertLock -Inventory $Inventory
    if ($cert) {
        $what = if ($cert.scenario) { "scenario '$($cert.scenario)'" } else { 'a scenario' }
        $since = if ($cert.started) { " since $($cert.started)" } else { '' }
        throw "A CERT $what is active$since (lock: $((Get-LabMgmtDefinition -Inventory $Inventory).handover.cert_lock_path)). Roll it back or close it in CERT first; the pipeline won't change a lab that is about to be rolled back."
    }
}

function Assert-LabSafePlan {
    # Refuses a Terraform plan that deletes (or replaces) any VM the caller didn't
    # name in -AllowDelete, whatever the ledger says: an emptied or damaged ledger
    # must never turn into "destroy the domain controllers". Also refuses an
    # in-place update that drops a disk from an active instance or this machine.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Plan,
        [string[]] $AllowDelete = @()
    )
    $ledger = @(Get-LabInstances -Path (Get-LabLedgerPath))
    $active = @($ledger | Where-Object state -eq 'active' | ForEach-Object name)
    $self   = $env:COMPUTERNAME
    $bad = @()
    foreach ($rc in @($Plan.resource_changes)) {
        if ($rc.type -ne 'proxmox_virtual_environment_vm') { continue }
        $name    = [string] $rc.index
        $actions = @($rc.change.actions)
        if ($actions -contains 'delete') {
            if ($self -and $name -eq $self)      { $bad += "$name (this machine; $($actions -join '+'))"; continue }
            if ($AllowDelete -notcontains $name) { $bad += "$name ($($actions -join '+'); not expected by this run)"; continue }
            if ($actions -contains 'create')     { $bad += "$name (replace; a retiring VM is destroyed, never rebuilt in place)"; continue }
            continue
        }
        # An in-place update that drops a disk is as destructive as a delete. (EFI
        # and TPM disks come from the template and aren't managed by Terraform,
        # so a plan can't remove them; only 'disk' is checked.)
        $protected = ($active -contains $name -or ($self -and $name -eq $self))
        if ($protected -and $actions -contains 'update') {
            foreach ($blk in @('disk')) {
                $before = @($rc.change.before.$blk).Count
                $after  = @($rc.change.after.$blk).Count
                if ($after -lt $before) { $bad += "$name (update removes $blk)" }
            }
        }
    }
    if ($bad.Count -gt 0) {
        throw "Refusing to apply: the plan would delete or damage: $($bad -join ', '). Nothing was changed. If the ledger (inventory/instances.yaml) was edited or lost, restore it from git; machines are retired only through the pipeline."
    }
}

# ── Ledger: hand-built instances ──────────────────────────────────────────

function Register-LabInitialInstances {
    # Roles with an 'initial' block (MGMT) start hand-built. Record that
    # instance in the ledger the first time the pipeline sees it.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Inventory,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Instances,
        # Register in memory only (e.g. -PlanOnly runs).
        [switch] $NoSave
    )
    $changed = $false
    foreach ($def in @($Inventory.servers | Where-Object initial)) {
        if (@($Instances | Where-Object role -eq $def.role).Count -gt 0) { continue }
        $slot = @($def.slots | Where-Object id -eq $def.initial.slot)[0]
        $Instances += [pscustomobject]@{
            name        = $def.initial.hostname
            role        = $def.role
            origin      = $def.initial.origin
            sequence    = '00'
            slot        = $slot.id
            vmid        = [int] $slot.vmid
            ipv4        = $slot.ipv4
            state       = 'active'
            created_utc = (Get-Date).ToUniversalTime().ToString('o')
        }
        $changed = $true
        Write-Host "Registered hand-built $($def.role) $($def.initial.hostname) (slot $($slot.id)) in the ledger."
    }
    if ($changed -and -not $NoSave) { Save-LabLedger -Instances $Instances }
    # Callers wrap the result in @(); a leading comma here would nest the array.
    @($Instances)
}

function Remove-LabInstance {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object[]] $Instances,
        [Parameter(Mandatory)] [string] $Name
    )
    @($Instances | Where-Object name -ne $Name)
}

# ── Proxmox VM lifecycle (outside Terraform) ──────────────────────────────

function Get-LabPveToken {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Inventory,
        [ValidateSet('terraform', 'packer')] [string] $Purpose = 'terraform'
    )
    $sa = $Inventory.proxmox.service_account
    if ($Purpose -eq 'packer') {
        "$($sa.user)!$($sa.packer_token_name)=" + (Get-LabSecretText -Inventory $Inventory -Name $Inventory.secrets.entries.proxmox_packer_token)
    } else {
        "$($sa.user)!$($sa.token_name)=" + (Get-LabSecretText -Inventory $Inventory -Name $Inventory.secrets.entries.proxmox_terraform_token)
    }
}

function Stop-LabPveVm {
    # Graceful ACPI shutdown, then a hard stop if it doesn't finish in time.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Inventory,
        [Parameter(Mandatory)] [string] $Token,
        [Parameter(Mandatory)] [int] $VmId,
        [int] $TimeoutSeconds = 300
    )
    $node = $Inventory.proxmox.node
    $status = Invoke-LabPveApi -Inventory $Inventory -Token $Token -Method GET -Path "/nodes/$node/qemu/$VmId/status/current"
    if ($status.status -ne 'running') { return }
    try {
        $upid = Invoke-LabPveApi -Inventory $Inventory -Token $Token -Method POST -Path "/nodes/$node/qemu/$VmId/status/shutdown" -Body @{ timeout = $TimeoutSeconds }
        Wait-LabPveTask -Inventory $Inventory -Token $Token -Upid $upid -TimeoutSeconds ($TimeoutSeconds + 60)
    } catch {
        Write-Warning "Graceful shutdown of $VmId failed ($($_.Exception.Message)); stopping."
        $upid = Invoke-LabPveApi -Inventory $Inventory -Token $Token -Method POST -Path "/nodes/$node/qemu/$VmId/status/stop"
        Wait-LabPveTask -Inventory $Inventory -Token $Token -Upid $upid
    }
}

function Remove-LabPveVm {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Inventory,
        [Parameter(Mandatory)] [string] $Token,
        [Parameter(Mandatory)] [int] $VmId,
        # Succeed quietly if the VM is already gone (default: it must be visible).
        [switch] $AllowMissing
    )
    if (-not (Test-LabPveVm -Inventory $Inventory -Token $Token -VmId $VmId)) {
        if ($AllowMissing) { return }
        throw "VM $VmId isn't visible to the provisioning token. If it exists, add it to pool $($Inventory.proxmox.pool) (the hand-built MGMT-00 must be in the pool)."
    }
    Stop-LabPveVm -Inventory $Inventory -Token $Token -VmId $VmId
    $node = $Inventory.proxmox.node
    $upid = Invoke-LabPveApi -Inventory $Inventory -Token $Token -Method DELETE -Path "/nodes/$node/qemu/${VmId}?purge=1&destroy-unreferenced-disks=1"
    Wait-LabPveTask -Inventory $Inventory -Token $Token -Upid $upid
    if (Test-LabPveVm -Inventory $Inventory -Token $Token -VmId $VmId) { throw "VM $VmId still exists after delete." }
}

# ── Deploying one instance (shared by phases and rotations) ──────────────

function Deploy-LabInstance {
    # Connects to a freshly cloned instance, pushes platform + metadata +
    # secrets (or follows a bootstrap already running), waits for it across
    # reboots, and returns @{ State; Report }. Does not touch the ledger.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Inventory,
        [Parameter(Mandatory)] $Instance,
        [Parameter(Mandatory)] [System.Collections.IDictionary] $Metadata,
        [Parameter(Mandatory)] [hashtable] $Secrets,
        [Parameter(Mandatory)] [pscredential[]] $Credential,
        [string[]] $ExtraAddress = @(),
        [switch] $Retry
    )
    # Never a Tailscale address (100.64.0.0/10): guests allow WinRM from MGMT's lab addresses only.
    $addresses = @($Instance.ipv4) + @($ExtraAddress | Where-Object { $_ -and $_ -ne $Instance.ipv4 -and $_ -notmatch '^100\.(6[4-9]|[7-9]\d|1[01]\d|12[0-7])\.' })
    # Identify the VM by its MAC, and ask its guest agent where it is now:
    # Terraform's address can be stale or belong to another machine.
    $pveToken = Get-LabPveToken -Inventory $Inventory
    $mac = @(Get-LabVmMac -Inventory $Inventory -Token $pveToken -VmId ([int] $Instance.vmid))
    if ($mac.Count -eq 0) { throw "Couldn't read the MAC address of VM $($Instance.vmid) from Proxmox." }
    $find = @{ ExpectedMac = $mac; Inventory = $Inventory; Token = $pveToken; VmId = [int] $Instance.vmid }
    $session = Wait-LabGuest -Address $addresses -Credential $Credential -TimeoutSeconds 2400 @find
    try {
        # A guest that already has lab metadata must have been set up as THIS
        # instance; otherwise it is some other instance's machine.
        $theirs = Invoke-Command -Session $session -ScriptBlock {
            $p = 'C:\ProgramData\MidCoastLab\metadata.json'
            if (Test-Path $p) { Get-Content -Path $p -Raw | ConvertFrom-Json } else { $null }
        }
        if ($theirs -and ($theirs.hostname -ne $Instance.name -or [int] $theirs.vmid -ne [int] $Instance.vmid)) {
            throw "VM $($Instance.vmid) was set up as $($theirs.hostname) (VMID $($theirs.vmid)), not $($Instance.name). An earlier run reached the wrong machine; rebuild both (see docs/decisions.md, 'Guest identity')."
        }
        $state = Get-LabGuestState -Session $session
        if ($state -and $state.status -eq 'Complete') {
            Write-Host '   bootstrap already complete'
        } elseif ($state -and $state.status -ne 'Failed' -and $state.stage -ne 'Start') {
            # Never re-publish under a running bootstrap, -Retry or not.
            Write-Host "   bootstrap in progress ($($state.stage)); following it"
        } else {
            Write-Host '   pushing platform, metadata and secrets'
            Publish-LabPayload -Session $session -Inventory $Inventory -Metadata $Metadata -Secrets $Secrets -Retry:$Retry
        }
    } finally { Remove-PSSession $session -ErrorAction SilentlyContinue }

    # Up to 6 hours: a MGMT's Role:Start installs every RSAT tool from Windows
    # Update, which took over 3 hours on the first real run.
    $final = Wait-LabBootstrap -Name $Instance.name -Address $addresses -Credential $Credential -TimeoutSeconds 21600 @find

    $report = $null
    $session = Wait-LabGuest -Address @($Instance.ipv4) -Credential $Credential -TimeoutSeconds 600 @find
    try { $report = Get-LabValidationReport -Session $session } finally { Remove-PSSession $session -ErrorAction SilentlyContinue }
    if ($report) { Write-LabReport -Report $report }
    [pscustomobject]@{ State = $final; Report = $report }
}

function New-LabMetadata {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Inventory,
        [Parameter(Mandatory)] $Instance,
        [Parameter(Mandatory)] [string[]] $DnsServers,
        [hashtable] $Extra = @{}
    )
    $m = [ordered]@{
        hostname         = $Instance.name
        role             = $Instance.role
        sequence         = $Instance.sequence
        build_date       = $Instance.build_date
        slot             = $Instance.slot
        vmid             = $Instance.vmid
        ipv4             = $Instance.ipv4
        prefix_length    = Get-LabPrefixLength -Inventory $Inventory
        gateway          = $Inventory.network.gateway
        dns_servers      = $DnsServers
        mgmt_ipv4s       = @(Get-LabRoleAddresses -Inventory $Inventory -Role 'MGMT')
        platform_version = Get-LabPlatformVersion
    }
    foreach ($k in $Extra.Keys) { $m[$k] = $Extra[$k] }
    $m
}

function Add-LabTailscaleSecret {
    # Adds the Tailscale auth key to a guest's secrets when site.yaml
    # tailscale.enabled. A missing key is a warning: the guest builds without it.
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Inventory, [Parameter(Mandatory)] [hashtable] $Secrets)
    if (-not $Inventory.tailscale.enabled) { return $Secrets }
    $name = $Inventory.secrets.entries.tailscale_authkey
    try { $Secrets[$name] = Get-LabSecretText -Inventory $Inventory -Name $name }
    catch { Write-Warning "Tailscale is enabled but the vault has no $name; this machine won't join the tailnet. ($($_.Exception.Message))" }
    $Secrets
}

function Disconnect-LabGuestTailscale {
    # Logs a machine that's about to be destroyed out of the tailnet, so it
    # doesn't linger in the device list. Best-effort; returns a status line.
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Inventory, [Parameter(Mandatory)] $Instance, [Parameter(Mandatory)] [pscredential[]] $Credential)
    if (-not $Inventory.tailscale.enabled) { return $null }
    $s = Connect-LabGuest -Address @($Instance.ipv4) -Credential $Credential
    if (-not $s) { return "couldn't reach $($Instance.name) to log it out of the tailnet; remove it in the Tailscale admin console" }
    try {
        Invoke-Command -Session $s -ScriptBlock {
            $exe = Join-Path $env:ProgramFiles 'Tailscale\tailscale.exe'
            if (-not (Test-Path $exe)) { return 'Tailscale not installed' }
            # The AuthKey policy and the watchdog first, or it would log straight back in.
            Remove-ItemProperty -Path 'HKLM:\SOFTWARE\Policies\Tailscale' -Name AuthKey -ErrorAction SilentlyContinue
            Unregister-ScheduledTask -TaskName 'MidCoastLab-Tailscale' -Confirm:$false -ErrorAction SilentlyContinue
            Remove-Item -Path 'C:\ProgramData\MidCoastLab\Tailscale\authkey.bin' -Force -ErrorAction SilentlyContinue
            & $exe logout 2>&1 | Out-Null
            if ($LASTEXITCODE -eq 0) { 'logged out of the tailnet' } else { "tailscale logout exit $LASTEXITCODE" }
        }
    } catch { "tailscale logout failed: $($_.Exception.Message)" }
    finally { Remove-PSSession $s -ErrorAction SilentlyContinue }
}

function Get-LabGuestCredentials {
    # Every credential a guest may accept, in the order they become valid:
    # local Administrator (template password) -> domain accounts after join.
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Inventory)
    $sec = $Inventory.secrets.entries
    $nb  = $Inventory.identity.active_directory.netbios
    [ordered]@{
        LocalAdmin   = Get-LabSecretCredential -Inventory $Inventory -UserName 'Administrator'   -SecretName $sec.local_administrator
        LocalAdmin2  = Get-LabSecretCredential -Inventory $Inventory -UserName '.\Administrator' -SecretName $sec.local_administrator
        LocalAsDa    = Get-LabSecretCredential -Inventory $Inventory -UserName 'Administrator'   -SecretName $sec.domain_administrator
        DomainAdmin  = Get-LabSecretCredential -Inventory $Inventory -UserName "$nb\Administrator" -SecretName $sec.domain_administrator
        LabDeploy    = Get-LabSecretCredential -Inventory $Inventory -UserName "$nb\svc-labdeploy" -SecretName 'svc-labdeploy'
    }
}

# ── MGMT handover (files) ─────────────────────────────────────────────────

function Copy-LabFileToSession {
    # Copies one file and verifies it arrived intact (SHA256 on both ends).
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [System.Management.Automation.Runspaces.PSSession] $Session,
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [string] $Destination
    )
    if (-not (Test-Path $Path)) { throw "Handover source missing: $Path" }
    $local = (Get-FileHash -Path $Path -Algorithm SHA256).Hash
    Invoke-Command -Session $Session -ArgumentList (Split-Path $Destination -Parent) -ScriptBlock {
        param($Dir) New-Item -ItemType Directory -Path $Dir -Force | Out-Null
    }
    Copy-Item -Path $Path -Destination $Destination -ToSession $Session -Force
    $remote = Invoke-Command -Session $Session -ArgumentList $Destination -ScriptBlock {
        param($P) (Get-FileHash -Path $P -Algorithm SHA256).Hash
    }
    if ($remote -ne $local) { throw "Hash mismatch copying $Path -> $Destination." }
    [pscustomobject]@{ Path = $Path; Destination = $Destination; Sha256 = $local }
}

function Send-LabHandover {
    # Copies the repo working tree (with .git), Terraform state and the KeePass
    # vault to the new MGMT, verified by hash, and locks the folder down.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Inventory,
        [Parameter(Mandatory)] [System.Management.Automation.Runspaces.PSSession] $Session
    )
    $h = (Get-LabMgmtDefinition -Inventory $Inventory).handover
    $repo = Get-LabRepoRoot
    $copied = @()

    # Repo: zip it locally, minus provider binaries and caches (re-created by terraform init).
    $stage = Join-Path ([IO.Path]::GetTempPath()) "midcoast-repo-$([guid]::NewGuid())"
    $zip   = "$stage.zip"
    try {
        $exclude = @('.terraform', 'packer_cache')
        New-Item -ItemType Directory -Path $stage -Force | Out-Null
        Get-ChildItem -Path $repo -Force | Where-Object { $exclude -notcontains $_.Name } |
            Copy-Item -Destination $stage -Recurse -Force
        Get-ChildItem -Path $stage -Recurse -Force -Directory | Where-Object { $exclude -contains $_.Name } |
            Remove-Item -Recurse -Force
        # ZipFile, not Compress-Archive: Compress-Archive skips hidden items,
        # and .git is hidden on Windows.
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        [System.IO.Compression.ZipFile]::CreateFromDirectory($stage, $zip)
        $remoteZip = Join-Path (Split-Path $h.repo_path -Parent) 'handover-repo.zip'
        $copied += Copy-LabFileToSession -Session $Session -Path $zip -Destination $remoteZip
        Invoke-Command -Session $Session -ArgumentList $remoteZip, $h.repo_path -ScriptBlock {
            param($Zip, $Dest)
            $ErrorActionPreference = 'Stop'
            if (Test-Path $Dest) { Remove-Item -Path $Dest -Recurse -Force }
            Add-Type -AssemblyName System.IO.Compression.FileSystem
            [System.IO.Compression.ZipFile]::ExtractToDirectory($Zip, $Dest)
            Remove-Item -Path $Zip -Force
        }
    } finally {
        Remove-Item -Path $stage -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item -Path $zip -Force -ErrorAction SilentlyContinue
    }

    # The repo must arrive with its history and its ledger.
    $check = Invoke-Command -Session $Session -ArgumentList $h.repo_path -ScriptBlock {
        param($Dest)
        [pscustomobject]@{
            Git    = Test-Path (Join-Path $Dest '.git\HEAD')
            Ledger = Test-Path (Join-Path $Dest 'inventory\instances.yaml')
        }
    }
    if (-not $check.Git -or -not $check.Ledger) { throw "Repo handover incomplete (git history: $($check.Git), ledger: $($check.Ledger))." }

    # Terraform state (and its backup, if present).
    $state = $Inventory.terraform.state.path
    $copied += Copy-LabFileToSession -Session $Session -Path $state -Destination $state
    if (Test-Path "$state.backup") { $copied += Copy-LabFileToSession -Session $Session -Path "$state.backup" -Destination "$state.backup" }

    # KeePass vault.
    $copied += Copy-LabFileToSession -Session $Session -Path $h.vault_path -Destination $h.vault_path

    # The same post-copy rules as MGMT-00 gets after its domain join
    # (Join-LabDomain.ps1), from the same Lab.System functions, run on the new
    # MGMT from the platform its bootstrap received: git may use the repo under
    # any account (safe.directory), and only SYSTEM, Administrators and the Tier 0
    # admin group may use C:\MidCoastLab; core.filemode off, since .git came from
    # another machine (issue #22).
    $adminGroup = "$($Inventory.identity.active_directory.netbios)\SG-ROLE-DomainAdmins"
    $folderRoot = Split-Path $h.repo_path -Parent
    Invoke-Command -Session $Session -ArgumentList $adminGroup, $h.repo_path, $folderRoot -ScriptBlock {
        param($Group, $Repo, $Root)
        $ErrorActionPreference = 'Stop'
        Import-Module 'C:\ProgramData\MidCoastLab\Platform\modules\Lab.System\Lab.System.psm1' -Force -DisableNameChecking
        Add-LabGitSafeDirectory -Path $Repo
        Set-LabGitRepoConfig -Path $Repo
        Set-LabMgmtFolderAcl -Group $Group -Root $Root -ProbePath (Join-Path $Repo 'inventory\lab.yaml')
    } | ForEach-Object { Write-Host "   $_" }
    # Last step: the marker Complete requires. Its absence means the copy is partial.
    $marker = Join-Path (Split-Path $h.repo_path -Parent) 'HANDOVER.complete'
    Invoke-Command -Session $Session -ArgumentList $marker, $env:COMPUTERNAME, ($copied | ConvertTo-Json -Depth 3) -ScriptBlock {
        param($Path, $From, $Files)
        [pscustomobject]@{ from = $From; at = (Get-Date).ToUniversalTime().ToString('o'); files = ($Files | ConvertFrom-Json) } |
            ConvertTo-Json -Depth 4 | Set-Content -Path $Path -Encoding UTF8
    }
    $copied
}

function Clear-LabHandoverTarget {
    # Removes partial handover copies from the new MGMT after a failed handover.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Inventory,
        [Parameter(Mandatory)] [System.Management.Automation.Runspaces.PSSession] $Session
    )
    $h = (Get-LabMgmtDefinition -Inventory $Inventory).handover
    $state = $Inventory.terraform.state.path
    $root = Split-Path $h.repo_path -Parent
    Invoke-Command -Session $Session -ArgumentList $h.repo_path, $h.vault_path, $state, (Join-Path $root 'HANDOVER.complete'), (Join-Path $root 'handover-repo.zip') -ScriptBlock {
        param($Repo, $Vault, $State, $Marker, $Zip)
        foreach ($p in $Marker, $Vault, $State, "$State.backup", $Zip) { Remove-Item -Path $p -Force -ErrorAction SilentlyContinue }
        if (Test-Path $Repo) { Remove-Item -Path $Repo -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

function Test-LabHandoverComplete {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Inventory)
    $h = (Get-LabMgmtDefinition -Inventory $Inventory).handover
    Test-Path (Join-Path (Split-Path $h.repo_path -Parent) 'HANDOVER.complete')
}

function Set-LabHandoverLock {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Inventory,
        [Parameter(Mandatory)] $NewInstance,
        # in-progress: written before the handover starts; complete: after it succeeds.
        [ValidateSet('in-progress', 'complete')] [string] $Status = 'complete'
    )
    $path = (Get-LabMgmtDefinition -Inventory $Inventory).handover.lock_path
    New-Item -ItemType Directory -Path (Split-Path $path -Parent) -Force | Out-Null
    [pscustomobject]@{
        handed_over_to = $NewInstance.name
        ipv4           = $NewInstance.ipv4
        at             = (Get-Date).ToUniversalTime().ToString('o')
        from           = $env:COMPUTERNAME
        status         = $Status
    } | ConvertTo-Json | Set-Content -Path $path -Encoding utf8NoBOM
}

function Remove-LabHandoverLock {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Inventory)
    $path = (Get-LabMgmtDefinition -Inventory $Inventory).handover.lock_path
    Remove-Item -Path $path -Force -ErrorAction SilentlyContinue
}

function Remove-LabComputerRecords {
    # Removes a retired machine's computer object and DNS A records, by
    # running on an active DC (so no RSAT credential plumbing is needed).
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Inventory,
        [Parameter(Mandatory)] [string] $ComputerName,
        [Parameter(Mandatory)] [string[]] $DcAddress,
        [Parameter(Mandatory)] [pscredential] $Credential
    )
    $session = Connect-LabGuest -Address $DcAddress -Credential @($Credential)
    if (-not $session) { throw "No session to any DC ($($DcAddress -join ', ')) to remove $ComputerName." }
    try {
        Invoke-Command -Session $session -ArgumentList $ComputerName, $Inventory.identity.active_directory.domain -ScriptBlock {
            param($Name, $Zone)
            $ErrorActionPreference = 'Stop'
            Import-Module ActiveDirectory, DnsServer
            $c = Get-ADComputer -Filter "Name -eq '$Name'" -ErrorAction SilentlyContinue
            if ($c) {
                # The object may have child objects (e.g. LAPS, BitLocker); remove recursively.
                Remove-ADObject -Identity $c.DistinguishedName -Recursive -Confirm:$false
                "removed computer object $Name"
            } else { "no computer object $Name" }
            # A and AAAA: a machine on the tailnet may have registered its Tailscale addresses.
            $rr = @(foreach ($t in 'A', 'AAAA') { Get-DnsServerResourceRecord -ZoneName $Zone -Name $Name -RRType $t -ErrorAction SilentlyContinue })
            foreach ($r in $rr) { Remove-DnsServerResourceRecord -ZoneName $Zone -InputObject $r -Force }
            "removed $($rr.Count) DNS A/AAAA record(s) for $Name"
            # Matching PTR records in reverse zones.
            $fqdn = "$Name.$Zone.".ToLower()
            $ptr = 0
            foreach ($z in @(Get-DnsServerZone | Where-Object { $_.IsReverseLookupZone -and -not $_.IsAutoCreated })) {
                foreach ($r in @(Get-DnsServerResourceRecord -ZoneName $z.ZoneName -RRType Ptr -ErrorAction SilentlyContinue | Where-Object { $_.RecordData.PtrDomainName.ToLower() -eq $fqdn })) {
                    Remove-DnsServerResourceRecord -ZoneName $z.ZoneName -InputObject $r -Force; $ptr++
                }
            }
            "removed $ptr PTR record(s) for $Name"
        }
    } finally { Remove-PSSession $session -ErrorAction SilentlyContinue }
}

function Write-LabCommitHint {
    # The one line every pipeline run ends with: commit the ledger. Same wording
    # everywhere, and the same as the guides.
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Message)
    Write-Host "Commit the ledger:  git add inventory/instances.yaml; git commit -m `"$Message`"; git push" -ForegroundColor Cyan
    Write-Host '                    (skip git push if the repo has no remote)'
}

function Write-LabReport {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Report)
    $color = switch ($Report.status) { 'Passed' { 'Green' } 'PassedWithWarnings' { 'Yellow' } default { 'Red' } }
    Write-Host "  $($Report.computer) [$($Report.role)]: $($Report.status)" -ForegroundColor $color
    foreach ($r in @($Report.results | Where-Object { -not $_.passed })) {
        Write-Host ("    {0,-8} {1,-10} {2} -- {3} [recovery: {4}]" -f $r.severity.ToUpper(), $r.id, $r.name, $r.detail, $r.recovery) -ForegroundColor $color
    }
}

Export-ModuleMember -Function Get-LabRepoRoot, Get-LabInventoryPath, Get-LabSitePath, Get-LabResolvedPath,
    Get-LabResolvedInventory, Export-LabResolvedInventory, Get-LabLedgerPath, Get-LabPlatformVersion, Get-LabRelease,
    Save-LabLedger, Get-LabCurrentTemplate, New-LabTemplateVersion, Remove-LabUnusedTemplates,
    New-LabInstance, Set-LabInstanceState, Unlock-LabVault, Get-LabSecretText, Get-LabSecretCredential, Get-LabGitIdentity, Set-LabGitIdentity,
    Invoke-LabPveApi, Wait-LabPveTask, Test-LabPveVm, Invoke-LabTerraform, Connect-LabGuest, Wait-LabGuest,
    Get-LabVmMac, Get-LabVmGuestAddress,
    New-LabPayloadArchive, Publish-LabPayload, Get-LabGuestState, Wait-LabBootstrap, Get-LabValidationReport,
    Invoke-LabRemoteValidation, Write-LabReport, Write-LabCommitHint,
    Get-LabMgmtDefinition, Get-LabHandoverLock, Get-LabCertLock, Assert-LabNotHandedOver, Assert-LabSafePlan,
    Register-LabInitialInstances, Remove-LabInstance, ConvertFrom-LabPlanJson, Get-LabPveToken, Stop-LabPveVm, Remove-LabPveVm,
    Deploy-LabInstance, New-LabMetadata, Get-LabGuestCredentials, Add-LabTailscaleSecret, Disconnect-LabGuestTailscale,
    Copy-LabFileToSession, Send-LabHandover, Clear-LabHandoverTarget, Test-LabHandoverComplete, Set-LabHandoverLock, Remove-LabHandoverLock, Remove-LabComputerRecords
