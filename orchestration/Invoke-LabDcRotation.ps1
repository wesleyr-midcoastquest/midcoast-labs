#Requires -Version 7.2
<#
.SYNOPSIS
    Replaces a domain controller with a fresh one from the current WIN2022
    template, in two stages with a checkpoint between them.

.DESCRIPTION
    Run on the active MGMT, in an elevated PowerShell 7 window (the last step of
    Add points this machine's own DNS client at the new set of DCs).

    Add      builds the replacement and moves everything onto it:
      1. Pre-flight: inventory, site, both DCs pass validation, a free DC slot,
         the current WIN2022 template exists.
      2. Picks the DC to replace (the oldest, or -Replace <name>) and allocates
         DC-<today>-NN in the free slot (ledger: building, replaces <old>).
      3. Terraform clones it; it bootstraps as a replica of the DC that stays,
         and is gated on its own validation (ledger: active).
      4. Moves every FSMO role the old DC holds to the new one (and with the PDC
         emulator, the external time source).
      5. Marks the old DC retiring and points every DNS client in the lab (DCs,
         every other lab machine, this MGMT) at the new set of DCs.
      6. Re-validates the active DCs.
      The old DC keeps running as a third DC until Retire. Check anything you
      like in between; nothing depends on it any more.

    Retire   removes the old DC: moves any FSMO role still on it, demotes it,
             removes its leftover DNS records and computer object, destroys the
             VM and drops it from the ledger.

    Abort    (before Retire) undoes Add: the old DC becomes active again, FSMO
             and DNS clients move back, and the replacement is demoted and
             destroyed, the same way Retire removes a DC.

    Every stage can be re-run after a failure; it picks up where it stopped.
    -Force (Retire/Abort only) handles a DC that can't be reached: FSMO roles
    are seized and its metadata is cleaned out of AD instead of a demotion.

.PARAMETER Stage
    Add, Retire or Abort; see above.

.EXAMPLE
    ./orchestration/Invoke-LabDcRotation.ps1 -Stage Add
    ./orchestration/Invoke-LabDcRotation.ps1 -Stage Retire
.EXAMPLE
    ./orchestration/Invoke-LabDcRotation.ps1 -Stage Add -Replace DC-261028-01
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [ValidateSet('Add', 'Retire', 'Abort')] [string] $Stage,
    # Add: the active DC to replace (default: the oldest).
    [string] $Replace,
    # Add: resume a replacement whose bootstrap failed.
    [switch] $Retry,
    # Retire/Abort: the DC being removed can't be reached; seize and clean up.
    [switch] $Force
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Lab.Orchestration.psm1') -Force -DisableNameChecking

$runLog = Join-Path 'C:\ProgramData\MidCoastLab\Logs\Orchestration' ("dc-rotation-$($Stage.ToLower())-{0}.txt" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
New-Item -ItemType Directory -Path (Split-Path $runLog) -Force | Out-Null
Start-Transcript -Path $runLog | Out-Null

$guestModules = 'C:\ProgramData\MidCoastLab\Platform\modules'

function Get-DcState {
    param($Instances)
    $dcs = @($Instances | Where-Object role -eq 'DC')
    [pscustomobject]@{
        Active   = @($dcs | Where-Object state -eq 'active' | Sort-Object build_date, sequence)
        Building = @($dcs | Where-Object state -eq 'building')
        Retiring = @($dcs | Where-Object state -eq 'retiring')
    }
}

function Connect-Dc {
    # A session to a DC, identified by its VM's MAC. $null with -Optional if unreachable.
    param($Dc, [switch] $Optional, [int] $TimeoutSeconds = 600)
    $mac = @(Get-LabVmMac -Inventory $inv -Token $pveTok -VmId ([int] $Dc.vmid))
    if ($Optional) {
        $s = Connect-LabGuest -Address @($Dc.ipv4) -Credential @($cred.DomainAdmin, $cred.LabDeploy) -ExpectedMac $mac
        return $s
    }
    Wait-LabGuest -Address @($Dc.ipv4) -Credential @($cred.DomainAdmin, $cred.LabDeploy) -TimeoutSeconds $TimeoutSeconds -ExpectedMac $mac
}

function Invoke-OnDc {
    param($Dc, [scriptblock] $ScriptBlock, [object[]] $ArgumentList = @())
    $s = Connect-Dc $Dc
    try { Invoke-Command -Session $s -ScriptBlock $ScriptBlock -ArgumentList $ArgumentList }
    finally { Remove-PSSession $s -ErrorAction SilentlyContinue }
}

function Test-DcHealth {
    # Runs each DC's validation; $true if none has a Critical failure.
    param([object[]] $Dcs)
    $ok = $true
    foreach ($dc in $Dcs) {
        $s = Connect-Dc $dc
        try { $report = Invoke-LabRemoteValidation -Session $s } finally { Remove-PSSession $s -ErrorAction SilentlyContinue }
        Write-LabReport -Report $report
        $script:lastStatus += [string] $report.status
        if ($report.stop_deployment) { $ok = $false }
    }
    $ok
}

function Test-IsDc {
    # Is $Name still a domain controller, as the DC $Via sees it?
    param([string] $Name, $Via)
    [bool] (Invoke-OnDc $Via -ArgumentList $Name -ScriptBlock {
        param($N)
        Import-Module ActiveDirectory
        @(Get-ADDomainController -Filter "Name -eq '$N'" -Server localhost).Count -gt 0
    })
}

function Move-Fsmo {
    # Moves every FSMO role $From holds to $To (run on $To). With -Seize, a
    # transfer that fails because $From is gone becomes a seizure.
    param($From, $To, [switch] $Seize)
    $fromFqdn  = "$($From.name).$($ad.domain)".ToLower()
    $seizeFlag = [bool] $Seize
    $moved = Invoke-OnDc $To -ArgumentList $fromFqdn, $To.name, $cred.DomainAdmin, $seizeFlag -ScriptBlock {
        param($FromFqdn, $ToName, $Cred, $Seize)
        $ErrorActionPreference = 'Stop'
        Import-Module ActiveDirectory
        $d = Get-ADDomain -Server localhost; $f = Get-ADForest -Server localhost
        $held = [ordered]@{
            SchemaMaster = $f.SchemaMaster; DomainNamingMaster = $f.DomainNamingMaster
            PDCEmulator = $d.PDCEmulator; RIDMaster = $d.RIDMaster; InfrastructureMaster = $d.InfrastructureMaster
        }
        $roles = @($held.Keys | Where-Object { "$($held[$_])".ToLower() -eq $FromFqdn })
        if ($roles.Count -gt 0) {
            # Credential explicitly: this runs in a remote session, and the move has
            # to talk to the current holder (no second hop with the session's own).
            Move-ADDirectoryServerOperationMasterRole -Identity $ToName -OperationMasterRole $roles -Server localhost `
                -Credential $Cred -Force:$Seize -Confirm:$false
        }
        $roles
    }
    $moved = @($moved)
    if ($moved.Count -gt 0) { Write-Host "   FSMO $($From.name) -> $($To.name): $($moved -join ', ')" }
    else                    { Write-Host "   $($From.name) holds no FSMO roles" }
    if ($moved -contains 'PDCEmulator') {
        # The PDC emulator is the domain's time source; the old one follows the hierarchy.
        Invoke-OnDc $To -ArgumentList $guestModules -ScriptBlock {
            param($M)
            Import-Module "$M\Lab.Inventory\Lab.Inventory.psm1", "$M\Lab.AD\Lab.AD.psm1" -Force -DisableNameChecking
            Set-LabTimeSource -Inventory (Get-LabInventory -Path 'C:\ProgramData\MidCoastLab\Platform\inventory.json') -Pdc
        } | Out-Null
        $s = Connect-Dc $From -Optional
        if ($s) {
            try {
                Invoke-Command -Session $s -ArgumentList $guestModules -ScriptBlock {
                    param($M)
                    Import-Module "$M\Lab.Inventory\Lab.Inventory.psm1", "$M\Lab.AD\Lab.AD.psm1" -Force -DisableNameChecking
                    Set-LabTimeSource -Inventory (Get-LabInventory -Path 'C:\ProgramData\MidCoastLab\Platform\inventory.json')
                } | Out-Null
            } finally { Remove-PSSession $s -ErrorAction SilentlyContinue }
        }
        Write-Host "   time source: $($To.name) (PDC emulator) syncs from $(@($inv.network.ntp) -join ', ')"
    }
}

# Sets the DNS client on the default-route adapter (works on machines without the
# lab's platform modules, e.g. a hand-built one).
$setDns = {
    param($Servers, $DcIps)
    $r = Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction Stop | Sort-Object RouteMetric | Select-Object -First 1
    Set-DnsClientServerAddress -InterfaceIndex $r.ifIndex -ServerAddresses $Servers
    Clear-DnsClientCache
    & ipconfig.exe /registerdns | Out-Null
    # The guest's metadata records the lab's DNS servers (validation reads them).
    $p = 'C:\ProgramData\MidCoastLab\metadata.json'
    if ($DcIps -and (Test-Path $p)) {
        $md = Get-Content -Path $p -Raw | ConvertFrom-Json
        $md.dns_servers = @($DcIps)
        $md | ConvertTo-Json -Depth 6 | Set-Content -Path $p -Encoding UTF8
    }
}

function Set-LabDnsClients {
    # Every DNS client in the lab -> the active DCs. DCs: partners first,
    # loopback last. The retiring DC (if any): the active DCs only, so it can
    # still find the domain while it's demoted. Everything else: the active DCs.
    param([object[]] $ActiveDcs, $RetiringDc)
    $ips = @($ActiveDcs | ForEach-Object ipv4)
    foreach ($dc in $ActiveDcs) {
        $list = @($ips | Where-Object { $_ -ne $dc.ipv4 }) + '127.0.0.1'
        Invoke-OnDc $dc -ArgumentList $list, $ips -ScriptBlock $setDns | Out-Null
        Write-Host "   $($dc.name): $($list -join ', ')"
    }
    if ($RetiringDc) {
        $s = Connect-Dc $RetiringDc -Optional
        if ($s) {
            try { Invoke-Command -Session $s -ArgumentList $ips, $null -ScriptBlock $setDns | Out-Null; Write-Host "   $($RetiringDc.name) (retiring): $($ips -join ', ')" }
            finally { Remove-PSSession $s -ErrorAction SilentlyContinue }
        } else { Write-Warning "$($RetiringDc.name) isn't reachable; its DNS client wasn't changed." }
    }
    $others = @($instances | Where-Object { $_.role -ne 'DC' -and $_.state -eq 'active' -and $_.name -ne $env:COMPUTERNAME })
    foreach ($o in $others) {
        $mac = @(Get-LabVmMac -Inventory $inv -Token $pveTok -VmId ([int] $o.vmid))
        $s = Connect-LabGuest -Address @($o.ipv4) -Credential @($cred.DomainAdmin, $cred.LabDeploy) -ExpectedMac $mac
        if (-not $s) { Write-Warning "$($o.name) ($($o.ipv4)) isn't reachable; set its DNS servers to $($ips -join ', ') by hand."; continue }
        try { Invoke-Command -Session $s -ArgumentList $ips, $ips -ScriptBlock $setDns | Out-Null; Write-Host "   $($o.name): $($ips -join ', ')" }
        finally { Remove-PSSession $s -ErrorAction SilentlyContinue }
    }
    # This machine.
    $elevated = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if ($elevated) {
        & $setDns $ips $ips
        Write-Host "   $env:COMPUTERNAME (this MGMT): $($ips -join ', ')"
    } else {
        Write-Warning "Not elevated: set this machine's DNS servers yourself, in an elevated window: Set-DnsClientServerAddress -InterfaceIndex <n> -ServerAddresses $($ips -join ',')"
    }
}

function Remove-RotationDc {
    # Removes a DC from the domain and destroys its VM. $Target is in state
    # 'retiring'; $Keepers are the active DCs. Re-runnable at every step.
    param($Target, [object[]] $Keepers)
    $keeper = $Keepers[0]
    Write-Host "`n-- Removing $($Target.name) (VMID $($Target.vmid), $($Target.ipv4))" -ForegroundColor Cyan

    $isDc = Test-IsDc -Name $Target.name -Via $keeper
    if ($isDc) {
        # 1. FSMO off it (normally done by Add already).
        $reach = Connect-Dc $Target -Optional
        if (-not $reach -and -not $Force) {
            throw "$($Target.name) is still a DC but can't be reached. Bring it back up, or re-run with -Force to seize its roles and clean it out of AD without a demotion."
        }
        Move-Fsmo -From $Target -To $keeper -Seize:([bool] (-not $reach))

        # 2. Demote, or (-Force, unreachable) metadata cleanup.
        if ($reach) {
            Write-Host '   demoting (a few minutes)'
            try {
                Invoke-Command -Session $reach -ArgumentList $cred.DomainAdmin, $cred.LocalAdmin.Password -ScriptBlock {
                    param($Cred, $LocalPassword)
                    $ErrorActionPreference = 'Stop'
                    Import-Module ADDSDeployment
                    Uninstall-ADDSDomainController -Credential $Cred -LocalAdministratorPassword $LocalPassword `
                        -DemoteOperationMasterRole:$true -NoRebootOnCompletion:$true -Force:$true | Out-Null
                }
            } catch {
                # The session can drop as directory services stop; the check below decides.
                Write-Warning "Demotion call ended with: $($_.Exception.Message)"
            } finally { Remove-PSSession $reach -ErrorAction SilentlyContinue }
        } else {
            Write-Warning "Cleaning $($Target.name) out of AD without a demotion (-Force)."
            Invoke-OnDc $keeper -ArgumentList $Target.name -ScriptBlock {
                param($N)
                $ErrorActionPreference = 'Stop'
                Import-Module ActiveDirectory
                $dc = Get-ADDomainController -Identity $N -Server localhost
                # popups off: no confirmation dialog (there's no desktop in a remote session).
                & ntdsutil.exe 'popups off' 'metadata cleanup' "remove selected server $($dc.ServerObjectDN)" q q | Out-Null
                if ($LASTEXITCODE -ne 0) { throw "ntdsutil metadata cleanup failed (exit $LASTEXITCODE)." }
                $srv = Get-ADObject -Identity $dc.ServerObjectDN -Server localhost -ErrorAction SilentlyContinue
                if ($srv) { Remove-ADObject -Identity $srv -Recursive -Confirm:$false -Server localhost }
            }
        }
        $deadline = (Get-Date).AddMinutes(15)
        while ((Test-IsDc -Name $Target.name -Via $keeper) -and (Get-Date) -lt $deadline) { Start-Sleep -Seconds 30 }
        if (Test-IsDc -Name $Target.name -Via $keeper) { throw "$($Target.name) is still listed as a DC on $($keeper.name) after 15 minutes. Check the demotion on $($Target.name), then re-run." }
        Write-Host "   no longer a domain controller"
    } else {
        Write-Host '   not a domain controller (already demoted, or never promoted)'
    }

    # 3. Out of the tailnet (best-effort), then power off; nothing should talk to it any more.
    $ts = Disconnect-LabGuestTailscale -Inventory $inv -Instance $Target -Credential @($cred.DomainAdmin, $cred.LocalAdmin, $cred.LocalAdmin2)
    if ($ts) { Write-Host "   $ts" }
    if (Test-LabPveVm -Inventory $inv -Token $pveTok -VmId ([int] $Target.vmid)) {
        Stop-LabPveVm -Inventory $inv -Token $pveTok -VmId ([int] $Target.vmid)
        Write-Host '   shut down'
    }

    # 4. DNS it may have left behind (demotion removes most), then its computer object.
    $fqdn = "$($Target.name).$($ad.domain)".ToLower()
    Invoke-OnDc $keeper -ArgumentList $ad.domain, $fqdn, $Target.ipv4 -ScriptBlock {
        param($Zone, $Fqdn, $Ip)
        Import-Module DnsServer
        $n = 0
        foreach ($z in @($Zone, "_msdcs.$Zone")) {
            if (-not (Get-DnsServerZone -Name $z -ErrorAction SilentlyContinue)) { continue }
            foreach ($r in @(Get-DnsServerResourceRecord -ZoneName $z -RRType NS -ErrorAction SilentlyContinue |
                    Where-Object { $_.RecordData.NameServer.TrimEnd('.').ToLower() -eq $Fqdn })) {
                Remove-DnsServerResourceRecord -ZoneName $z -InputObject $r -Force; $n++
            }
            foreach ($r in @(Get-DnsServerResourceRecord -ZoneName $z -RRType A -ErrorAction SilentlyContinue |
                    Where-Object { $_.HostName -in '@', 'gc', 'DomainDnsZones', 'ForestDnsZones' -and $_.RecordData.IPv4Address.IPAddressToString -eq $Ip })) {
                Remove-DnsServerResourceRecord -ZoneName $z -InputObject $r -Force; $n++
            }
            # A Tailscale address under those names is always wrong (a DC that joined the
            # tailnet without the pipeline's DNS safeguards registers them).
            foreach ($t in 'A', 'AAAA') {
                foreach ($r in @(Get-DnsServerResourceRecord -ZoneName $z -RRType $t -ErrorAction SilentlyContinue |
                        Where-Object { $_.HostName -in '@', 'gc', 'DomainDnsZones', 'ForestDnsZones' })) {
                    $a = if ($t -eq 'A') { $r.RecordData.IPv4Address.IPAddressToString } else { $r.RecordData.IPv6Address.IPAddressToString }
                    if ($a -match '^100\.(6[4-9]|[7-9]\d|1[01]\d|12[0-7])\.' -or $a -like 'fd7a:115c:a1e0:*') {
                        Remove-DnsServerResourceRecord -ZoneName $z -InputObject $r -Force; $n++
                    }
                }
            }
        }
        "removed $n leftover DNS record(s) (NS, domain, gc, partition, Tailscale)"
    } | ForEach-Object { Write-Host "   $_" }
    Remove-LabComputerRecords -Inventory $inv -ComputerName $Target.name -DcAddress @($Keepers | ForEach-Object ipv4) -Credential $cred.DomainAdmin |
        ForEach-Object { Write-Host "   $_" }

    # 5. Destroy the VM: out of the ledger, Terraform removes exactly that VM.
    $script:instances = @(Get-LabInstances -Path (Get-LabLedgerPath))
    if (@($script:instances | Where-Object name -eq $Target.name).Count -gt 0) {
        $kept = $script:instances
        $script:instances = @(Remove-LabInstance -Instances $script:instances -Name $Target.name)
        Save-LabLedger -Instances $script:instances
        try {
            Invoke-LabTerraform -Inventory $inv -Command init | Out-Host
            Invoke-LabTerraform -Inventory $inv -Command apply -AllowDelete @($Target.name) | Out-Host
        } catch {
            Save-LabLedger -Instances $kept
            throw "Destroying $($Target.name) failed; ledger restored, re-run this stage: $($_.Exception.Message)"
        }
    }
    # Terraform can only remove what its state knows; anything left goes directly.
    Remove-LabPveVm -Inventory $inv -Token $pveTok -VmId ([int] $Target.vmid) -AllowMissing
    Write-Host "   destroyed VM $($Target.vmid)"
    try { Remove-LabUnusedTemplates -Inventory $inv -Token $pveTok } catch { Write-Warning "Template cleanup skipped: $($_.Exception.Message)" }
}

try {
    $findings = & (Join-Path $PSScriptRoot 'Test-LabInventory.ps1') -PassThru
    if (@($findings | Where-Object Level -eq 'Error').Count -gt 0) { throw 'Inventory validation failed.' }
    $site = & (Join-Path $PSScriptRoot 'Test-LabSite.ps1') -PassThru
    if (@($site | Where-Object Level -eq 'Error').Count -gt 0) { throw 'Site pre-flight failed; see above.' }

    $inv       = Get-LabResolvedInventory
    Assert-LabNotHandedOver -Inventory $inv
    $instances = @(Get-LabInstances -Path (Get-LabLedgerPath))
    $ad        = $inv.identity.active_directory
    $want      = [int] (Get-LabRoleDefinition -Inventory $inv -Role 'DC').instances
    $pveTok    = Get-LabPveToken -Inventory $inv
    $cred      = Get-LabGuestCredentials -Inventory $inv
    $m         = Get-DcState $instances

    switch ($Stage) {

    # ════════════════════════════════════════════════════════════════════════
    'Add' {
        Write-Host "`n== DC rotation: Add ==" -ForegroundColor Cyan
        if ($m.Retiring.Count -gt 0) { throw "$($m.Retiring[0].name) is already retiring. Run -Stage Retire to finish that rotation (or -Stage Abort to undo it)." }

        # Resume, or start a new replacement.
        $new = @($m.Building) + @($m.Active | Where-Object { $_.replaces -and (@($m.Active | ForEach-Object name) -contains $_.replaces) }) | Select-Object -First 1
        if ($new) {
            $old = @($instances | Where-Object name -eq $new.replaces)[0]
            if (-not $old) { throw "$($new.name) replaces $($new.replaces), which isn't in the ledger. Run -Stage Abort." }
            Write-Host "Resuming: $($new.name) replaces $($old.name)"
        } else {
            if ($m.Active.Count -ne $want) { throw "Expected $want active DCs, found $($m.Active.Count) ($(($m.Active | ForEach-Object name) -join ', ')). Finish Phase 1 first." }
            $old = if ($Replace) { @($m.Active | Where-Object name -eq $Replace)[0] } else { $m.Active[0] }
            if (-not $old) { throw "$Replace isn't an active DC ($(($m.Active | ForEach-Object name) -join ', '))." }

            # Template: the replacement is cloned from the current WIN2022 version.
            $family = (Get-LabRoleDefinition -Inventory $inv -Role 'DC').template
            $tplCur = Get-LabCurrentTemplate -Family $family
            $tplVm  = if ($tplCur) { Test-LabPveVm -Inventory $inv -Token $pveTok -VmId ([int] $tplCur.vmid) }
            if (-not $tplVm -or -not $tplVm.template) { throw "No current $family template in Proxmox. Build it: ./orchestration/Build-LabTemplate.ps1 -Template $(Get-LabTemplateKey -Inventory $inv -Family $family)" }

            Write-Host "`n-- Health of the current DCs" -ForegroundColor Cyan
            if (-not (Test-DcHealth $m.Active)) { throw 'A current DC has Critical validation failures. Fix them before rotating; a rotation needs healthy replication.' }

            $new = New-LabInstance -Inventory $inv -Instances $instances -Role 'DC'
            $new | Add-Member -NotePropertyName dc_mode  -NotePropertyValue 'replica'
            $new | Add-Member -NotePropertyName replaces -NotePropertyValue $old.name
            $instances += $new
            Save-LabLedger -Instances $instances
            Write-Host "Allocated $($new.name) (slot $($new.slot), $($new.ipv4), VMID $($new.vmid)) to replace $($old.name) ($($old.ipv4))"
        }
        $keepers = @($m.Active | Where-Object { $_.name -ne $old.name -and $_.name -ne $new.name })
        if ($keepers.Count -eq 0) { throw "No DC other than $($old.name) to replicate from." }
        $source = $keepers[0]

        # ── Clone and bootstrap ──────────────────────────────────────────────
        if ($new.state -eq 'building') {
            Write-Host "`n-- Terraform" -ForegroundColor Cyan
            Invoke-LabTerraform -Inventory $inv -Command init | Out-Host
            Invoke-LabTerraform -Inventory $inv -Command apply | Out-Host
            $tf = (Invoke-LabTerraform -Inventory $inv -Command output).servers.value

            Write-Host "`n-- $($new.name) (replica of $($source.name))" -ForegroundColor Cyan
            $secrets = Add-LabTailscaleSecret -Inventory $inv -Secrets @{
                $inv.secrets.entries.dsrm = Get-LabSecretText -Inventory $inv -Name $inv.secrets.entries.dsrm
                'svc-labdeploy'           = Get-LabSecretText -Inventory $inv -Name 'svc-labdeploy'
            }
            $metadata = New-LabMetadata -Inventory $inv -Instance $new -DnsServers @($keepers | ForEach-Object ipv4) -Extra @{
                dc_mode            = 'replica'
                replication_source = "$($source.name).$($ad.domain)".ToLower()
            }
            $result = Deploy-LabInstance -Inventory $inv -Instance $new -Metadata $metadata -Secrets $secrets `
                -Credential @($cred.LocalAdmin, $cred.LocalAdmin2, $cred.LabDeploy, $cred.DomainAdmin) `
                -ExtraAddress @($tf.($new.name).agent_ipv4) -Retry:$Retry
            if ($result.State.status -ne 'Complete') {
                throw "$($new.name) bootstrap failed at $($result.State.stage): $($result.State.detail). Fix the cause and re-run -Stage Add -Retry, or undo with -Stage Abort."
            }
            if ($result.Report -and $result.Report.stop_deployment) {
                throw "$($new.name) failed Critical validation. Re-run -Stage Add -Retry after fixing, or -Stage Abort. $($old.name) is untouched."
            }
            $instances = @(Set-LabInstanceState -Instances $instances -Name $new.name -State 'active')
            Save-LabLedger -Instances $instances
        }

        # ── FSMO, then the old DC out of every DNS client ───────────────────
        Write-Host "`n-- FSMO roles" -ForegroundColor Cyan
        Move-Fsmo -From $old -To $new
        $instances = @(Set-LabInstanceState -Instances $instances -Name $old.name -State 'retiring')
        Save-LabLedger -Instances $instances
        $active = @(Get-DcState $instances).Active
        Write-Host "`n-- DNS clients -> $(($active | ForEach-Object ipv4) -join ', ')" -ForegroundColor Cyan
        Set-LabDnsClients -ActiveDcs $active -RetiringDc $old

        # ── Re-validate ─────────────────────────────────────────────────────
        Write-Host "`n-- Validation" -ForegroundColor Cyan
        # Right after the FSMO move, DCs can still be locating the old PDC emulator
        # (DNS SRV records and the DC locator cache take a few minutes): dcdiag's
        # FsmoCheck and the Group Policy cmdlets, which talk to the PDC, fail until
        # then. So: validate, and if anything isn't clean, settle and validate again.
        Start-Sleep -Seconds 120
        $script:lastStatus = @()
        $healthy = Test-DcHealth $active
        if (@($script:lastStatus | Where-Object { $_ -ne 'Passed' }).Count -gt 0) {
            Write-Host '   not clean yet; letting DNS and the DC locator settle (5 minutes), then validating again' -ForegroundColor Yellow
            foreach ($dc in $active) { Invoke-OnDc $dc -ScriptBlock { & nltest.exe /dsregdns | Out-Null; & ipconfig.exe /registerdns | Out-Null } | Out-Null }
            Start-Sleep -Seconds 300
            $script:lastStatus = @()
            $healthy = Test-DcHealth $active
        }
        if (-not $healthy) { Write-Warning 'An active DC has Critical failures (above). Fix them, or undo with -Stage Abort, before Retire.' }

        Write-Host "`n$($new.name) is a DC and holds what $($old.name) held; $($old.name) still runs as a third DC." -ForegroundColor Green
        Write-LabCommitHint -Message "DC rotation: add $($new.name)"
        Write-Host @"

Check what you like (dcdiag, repadmin /replsummary, sign-ins), then:
  Finish:  ./orchestration/Invoke-LabDcRotation.ps1 -Stage Retire     (demotes and destroys $($old.name))
  Undo:    ./orchestration/Invoke-LabDcRotation.ps1 -Stage Abort

Outside the lab: anything you pointed at $($old.ipv4) by hand for DNS (OPNsense
DNS overrides or forwarding to the lab domain, a Tailscale split-DNS entry, your
workstation) should now use $(($active | ForEach-Object ipv4) -join ' / ').
"@
    }

    # ════════════════════════════════════════════════════════════════════════
    'Retire' {
        Write-Host "`n== DC rotation: Retire ==" -ForegroundColor Cyan
        if ($m.Building.Count -gt 0) { throw "$($m.Building[0].name) is still building. Finish -Stage Add (or -Stage Abort) first." }
        $old = $m.Retiring | Select-Object -First 1
        if (-not $old) { Write-Host 'No retiring DC; nothing to retire.' -ForegroundColor Yellow; return }
        if ($m.Active.Count -lt $want) { throw "Only $($m.Active.Count) active DC(s); retiring $($old.name) would leave fewer than $want. Run -Stage Abort instead." }

        Write-Host "`n-- Health of the DCs that stay" -ForegroundColor Cyan
        if (-not (Test-DcHealth $m.Active)) { throw "An active DC has Critical failures; $($old.name) is kept until they're fixed." }
        Write-Host "`n-- DNS clients -> $(($m.Active | ForEach-Object ipv4) -join ', ')" -ForegroundColor Cyan
        Set-LabDnsClients -ActiveDcs $m.Active -RetiringDc $old

        Remove-RotationDc -Target $old -Keepers $m.Active

        $instances = @(Get-LabInstances -Path (Get-LabLedgerPath))
        foreach ($i in $instances) { if ($i.role -eq 'DC' -and $i.replaces -eq $old.name) { $i.replaces = $null } }
        Save-LabLedger -Instances $instances
        Write-Host "`nDC rotation complete: $($old.name) retired." -ForegroundColor Green
        Write-LabCommitHint -Message "DC rotation: retire $($old.name)"
    }

    # ════════════════════════════════════════════════════════════════════════
    'Abort' {
        Write-Host "`n== DC rotation: Abort ==" -ForegroundColor Cyan
        $new = @($instances | Where-Object { $_.role -eq 'DC' -and $_.replaces }) | Select-Object -First 1
        if (-not $new) { Write-Host 'No DC rotation in progress; nothing to abort.' -ForegroundColor Yellow; return }
        $old = @($instances | Where-Object name -eq $new.replaces)[0]
        if (-not $old) { throw "$($new.replaces) is gone already (retired); a finished rotation can't be undone. Rotate again instead." }

        # The old DC is active again; the replacement becomes the one to remove.
        $instances = @(Set-LabInstanceState -Instances $instances -Name $old.name -State 'active')
        $instances = @(Set-LabInstanceState -Instances $instances -Name $new.name -State 'retiring')
        Save-LabLedger -Instances $instances
        $keepers = @(Get-DcState $instances).Active
        Write-Host "   $($old.name) active again; removing $($new.name)"
        Write-Host "`n-- DNS clients -> $(($keepers | ForEach-Object ipv4) -join ', ')" -ForegroundColor Cyan
        Set-LabDnsClients -ActiveDcs $keepers -RetiringDc $new

        # FSMO goes back to the DC it came from (Remove-RotationDc would pick any keeper).
        if (Test-IsDc -Name $new.name -Via $keepers[0]) {
            $reach = Connect-Dc $new -Optional
            if ($reach) { Remove-PSSession $reach -ErrorAction SilentlyContinue }
            Write-Host "`n-- FSMO roles" -ForegroundColor Cyan
            # Unreachable without -Force: Remove-RotationDc stops with the explanation.
            if ($reach -or $Force) { Move-Fsmo -From $new -To $old -Seize:([bool] (-not $reach)) }
        }
        Remove-RotationDc -Target $new -Keepers @(@($old) + @($keepers | Where-Object name -ne $old.name))

        $instances = @(Get-LabInstances -Path (Get-LabLedgerPath))
        Write-Host "`nRolled back: $($old.name) is active, $($new.name) is gone." -ForegroundColor Green
        Write-LabCommitHint -Message "DC rotation: abort $($new.name)"
    }
    }
} finally {
    Stop-Transcript | Out-Null
}
