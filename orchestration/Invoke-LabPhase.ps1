#Requires -Version 7.2
<#
.SYNOPSIS
    Runs a deployment phase: inventory validation -> Terraform -> bootstrap -> validation.

.DESCRIPTION
    Phase 1 (ActiveDirectory) builds the forest from nothing:
      1. Validate inventory; allocate two DC instances in the ledger (slots A, B).
      2. terraform apply: clone both VMs from WIN2022-TEMPLATE.
      3. First DC: push platform + metadata (dc_mode=forest) + secrets; wait;
         gate on its validation report (Critical = stop).
      4. Second DC: same, dc_mode=replica, replicating from the first.
      Each DC is marked active in the ledger as soon as its own bootstrap and
      validation pass.
      5. Point every DC's DNS client at its partner(s) first, loopback last;
         re-validate all DCs. Critical failures stop the run.

    Re-running is safe: instances already active are skipped; -Retry resumes
    a DC whose bootstrap failed, from the stage that failed. If every DC is
    already active (e.g. only the final validation failed), -Retry re-runs
    step 5 alone.

    Phases 2 and 3 are not implemented yet.

.EXAMPLE
    ./orchestration/Invoke-LabPhase.ps1 -Phase 1
.EXAMPLE
    ./orchestration/Invoke-LabPhase.ps1 -Phase 1 -Retry
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [ValidateSet(1, 2, 3)] [int] $Phase,
    [switch] $Retry,
    # Show the Terraform plan and stop.
    [switch] $PlanOnly
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Lab.Orchestration.psm1') -Force -DisableNameChecking

if ($Phase -ne 1) { throw "Phase $Phase is not implemented yet." }

$runLog = Join-Path 'C:\ProgramData\MidCoastLab\Logs\Orchestration' ("phase$Phase-{0}.txt" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
New-Item -ItemType Directory -Path (Split-Path $runLog) -Force | Out-Null
Start-Transcript -Path $runLog | Out-Null

try {
    # ── 1. Inventory and ledger ──────────────────────────────────────────
    Write-Host "`n== Phase 1: ActiveDirectory ==" -ForegroundColor Cyan
    $findings = & (Join-Path $PSScriptRoot 'Test-LabInventory.ps1') -PassThru
    if (@($findings | Where-Object Level -eq 'Error').Count -gt 0) { throw 'Inventory validation failed.' }
    # Live site pre-flight: Proxmox (node, storage, bridge, ISOs, pool, VMIDs) and lab addresses.
    $site = & (Join-Path $PSScriptRoot 'Test-LabSite.ps1') -PassThru
    if (@($site | Where-Object Level -eq 'Error').Count -gt 0) { throw 'Site pre-flight failed; see above.' }

    $inv       = Get-LabResolvedInventory
    Assert-LabNotHandedOver -Inventory $inv
    $instances = @(Get-LabInstances -Path (Get-LabLedgerPath))
    # Record the hand-built MGMT-00 the first time the pipeline runs.
    $instances = @(Register-LabInitialInstances -Inventory $inv -Instances $instances -NoSave:$PlanOnly)
    $ad        = $inv.identity.active_directory
    $dcDef     = Get-LabRoleDefinition -Inventory $inv -Role 'DC'
    $want      = [int] $dcDef.instances
    $sec       = $inv.secrets.entries

    $dcs = @($instances | Where-Object role -eq 'DC')
    $finalOnly = $false
    if (@($dcs | Where-Object state -eq 'active').Count -ge $want) {
        # Belt and braces after the site pre-flight: "already deployed" must be true.
        $token = Get-LabPveToken -Inventory $inv
        $missing = @($dcs | Where-Object state -eq 'active' | Where-Object { -not (Test-LabPveVm -Inventory $inv -Token $token -VmId ([int] $_.vmid)) } | ForEach-Object name)
        if ($missing.Count -gt 0) { throw "The ledger says $($missing -join ', ') is an active DC, but no such VM exists on Proxmox. The lab was torn down or the VM deleted by hand: reset the ledger with ./orchestration/Reset-LabLedger.ps1 (see the runbook, 'Starting over')." }
        if (-not $Retry -or $PlanOnly) {
            Write-Host "Phase 1 is already deployed ($want active DCs). DC replacement is done by rotation, not by this phase. (-Retry re-runs the final DNS and validation step.)" -ForegroundColor Yellow
            return
        }
        $finalOnly = $true
        Write-Host 'All DCs are active; re-running the final DNS and validation step only.' -ForegroundColor Yellow
    }
    # ── Credentials (read once from KeePass) ─────────────────────────────
    $cred        = Get-LabGuestCredentials -Inventory $inv
    $domainAdmin = $cred.DomainAdmin
    $labDeploy   = $cred.LabDeploy
    $done = @()
    if ($finalOnly) {
        $done = @(Get-LabActiveDCs -Instances $instances)
    } else {
        if (@($dcs | Where-Object state -eq 'retiring').Count -gt 0) { throw 'A DC is mid-rotation (state retiring); finish the rotation first.' }

        # Build-from-nothing only: either no DCs, or the DCs this phase allocated earlier.
        $planLedger = $null
        if ($dcs.Count -eq 0) {
            $first  = New-LabInstance -Inventory $inv -Instances $instances -Role 'DC'
            $first | Add-Member -NotePropertyName dc_mode -NotePropertyValue 'forest'
            $instances += $first
            for ($n = 2; $n -le $want; $n++) {
                $next = New-LabInstance -Inventory $inv -Instances $instances -Role 'DC'
                $next | Add-Member -NotePropertyName dc_mode -NotePropertyValue 'replica'
                $instances += $next
            }
            if ($PlanOnly) {
                # Plan only: allocate in a temporary ledger, never the real one.
                $planLedger = Join-Path ([IO.Path]::GetTempPath()) "midcoast-plan-$([guid]::NewGuid()).yaml"
                Save-LabLedger -Instances $instances -Path $planLedger
            } else {
                Save-LabLedger -Instances $instances
            }
            Write-Host "Allocated: $((@($instances | Where-Object role -eq 'DC') | ForEach-Object { "$($_.name) (slot $($_.slot), $($_.ipv4), $($_.dc_mode))" }) -join '; ')"
        }
        $dcs    = @($instances | Where-Object role -eq 'DC' | Sort-Object { $_.dc_mode -ne 'forest' }, sequence)
        $forest = $dcs | Where-Object dc_mode -eq 'forest' | Select-Object -First 1
        if (-not $forest) { throw 'Ledger has DCs but none with dc_mode forest; this phase only builds a new forest.' }

        # ── 2. Terraform ──────────────────────────────────────────────────────
        Write-Host "`n-- Terraform" -ForegroundColor Cyan
        Invoke-LabTerraform -Inventory $inv -Command init | Out-Host
        if ($PlanOnly) {
            try { Invoke-LabTerraform -Inventory $inv -Command plan -LedgerPath $planLedger | Out-Host }
            finally { if ($planLedger) { Remove-Item $planLedger -Force -ErrorAction SilentlyContinue } }
            return
        }
        Invoke-LabTerraform -Inventory $inv -Command apply | Out-Host
        $tf = (Invoke-LabTerraform -Inventory $inv -Command output).servers.value

        # Secrets each DC mode needs (read from KeePass as each DC is deployed).
        $accountNames = @($inv.identity.administrative_model.administrators | ForEach-Object { $_.username; "$($_.username)$($inv.identity.administrative_model.account_suffix)" }) +
                        @($inv.identity.service_accounts | ForEach-Object name)
        function Get-DcSecrets([string] $Mode) {
            $h = @{ $sec.dsrm = Get-LabSecretText -Inventory $inv -Name $sec.dsrm }
            if ($Mode -eq 'forest') {
                $h[$sec.domain_administrator] = Get-LabSecretText -Inventory $inv -Name $sec.domain_administrator
                foreach ($a in $accountNames) { $h[$a] = Get-LabSecretText -Inventory $inv -Name $a }
            } else {
                $h['svc-labdeploy'] = Get-LabSecretText -Inventory $inv -Name 'svc-labdeploy'
            }
            Add-LabTailscaleSecret -Inventory $inv -Secrets $h
        }

        # ── 3-4. Bootstrap each DC in order ──────────────────────────────────
        $done = @()
        foreach ($dc in $dcs) {
            Write-Host "`n-- $($dc.name) ($($dc.dc_mode), slot $($dc.slot), $($dc.ipv4))" -ForegroundColor Cyan
            if ($dc.state -eq 'active') { Write-Host '   already active; skipping'; $done += $dc; continue }

            $creds = if ($dc.dc_mode -eq 'forest') {
                @($cred.LocalAdmin, $cred.LocalAdmin2, $cred.LocalAsDa, $domainAdmin)
            } else {
                @($cred.LocalAdmin, $cred.LocalAdmin2, $labDeploy, $domainAdmin)
            }
            $dnsServers = if ($dc.dc_mode -eq 'forest') { @($inv.network.gateway) } else { @($forest.ipv4) }
            $metadata = New-LabMetadata -Inventory $inv -Instance $dc -DnsServers $dnsServers -Extra @{
                dc_mode            = $dc.dc_mode
                replication_source = if ($dc.dc_mode -eq 'replica') { "$($forest.name).$($ad.domain)".ToLower() } else { $null }
            }

            $result = Deploy-LabInstance -Inventory $inv -Instance $dc -Metadata $metadata -Secrets (Get-DcSecrets $dc.dc_mode) `
                -Credential $creds -ExtraAddress @($tf.($dc.name).agent_ipv4) -Retry:$Retry
            $final = $result.State

            if ($final.status -ne 'Complete') {
                throw "$($dc.name) bootstrap failed at $($final.stage): $($final.detail). Fix the cause, then re-run with -Retry."
            }
            $instances = @(Set-LabInstanceState -Instances $instances -Name $dc.name -State 'active')
            Save-LabLedger -Instances $instances
            $done += $dc
        }
    }

    # ── 5. Cross-DC DNS client order, then re-validate everything ────────
    Write-Host "`n-- Final DNS client order and validation" -ForegroundColor Cyan
    $pveTok = Get-LabPveToken -Inventory $inv
    $allIps = @($done | ForEach-Object ipv4)
    $failed = $false
    foreach ($dc in $done) {
        $session = Wait-LabGuest -Address @($dc.ipv4) -Credential @($domainAdmin, $labDeploy) -TimeoutSeconds 600 `
            -ExpectedMac @(Get-LabVmMac -Inventory $inv -Token $pveTok -VmId ([int] $dc.vmid))
        try {
            $partners = @($allIps | Where-Object { $_ -ne $dc.ipv4 })
            Invoke-Command -Session $session -ArgumentList (, (@($partners) + '127.0.0.1')) -ScriptBlock {
                param($Servers)
                Import-Module 'C:\ProgramData\MidCoastLab\Platform\modules\Lab.System\Lab.System.psm1' -Force -DisableNameChecking
                Set-LabDnsClient -Servers $Servers
                & ipconfig.exe /registerdns | Out-Null
            }
        } finally { Remove-PSSession $session -ErrorAction SilentlyContinue }
    }
    # Intra-site replication settles within seconds; give it a margin.
    Start-Sleep -Seconds 120
    foreach ($dc in $done) {
        $session = Wait-LabGuest -Address @($dc.ipv4) -Credential @($domainAdmin, $labDeploy) -TimeoutSeconds 600 `
            -ExpectedMac @(Get-LabVmMac -Inventory $inv -Token $pveTok -VmId ([int] $dc.vmid))
        try { $report = Invoke-LabRemoteValidation -Session $session } finally { Remove-PSSession $session -ErrorAction SilentlyContinue }
        Write-LabReport -Report $report
        if ($report.stop_deployment) { $failed = $true }
    }
    if ($failed) { throw 'Phase 1 final validation has Critical failures; see the reports above.' }

    Write-Host "`nPhase 1 complete. DCs: $($allIps -join ', ')." -ForegroundColor Green
    Write-LabCommitHint -Message 'Phase 1'
    $mgmt = @($instances | Where-Object { $_.role -eq 'MGMT' -and $_.origin -eq 'manual' })[0]
    if ($mgmt) {
        Write-Host "Next (runbook step 8): join $($mgmt.name) to $($ad.domain), in an elevated PowerShell 7:  ./setup/mgmt/Join-LabDomain.ps1"
    }
} finally {
    Stop-Transcript | Out-Null
}
