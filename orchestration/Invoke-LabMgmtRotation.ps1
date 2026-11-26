#Requires -Version 7.2
<#
.SYNOPSIS
    Replaces MGMT, the machine that runs the pipeline, with a fresh one built
    from WIN11-TEMPLATE.

.DESCRIPTION
    MGMT can't destroy and rebuild itself, so the replacement runs in three stages:

    Prepare   run on the CURRENT MGMT
      1. Validates inventory; records the hand-built MGMT-00 in the ledger if needed.
      2. Checks WIN11-TEMPLATE exists and at least one DC is active.
      3. Allocates the replacement in the spare MGMT slot (e.g. MGMT-YYMMDD-00, .31).
      4. terraform apply: clones it.
      5. Bootstraps it (toolchain, Remote Desktop, domain join, LAPS) and gates on validation.
      6. Hands over: ledger (new = active, old = retiring), the repo with git history,
         Terraform state and the KeePass vault, each copied and hash-verified.
      7. Locks this MGMT: from now on it refuses every pipeline action except Abort.

    Complete  run on the NEW MGMT (sign in as your -a account over Remote Desktop)
      1. Checks it is the active MGMT and can reach Proxmox and every DC.
      2. terraform init, and confirms the handed-over state matches the ledger
         (any create or delete stops it; in-place updates are only warned about).
      3. Retires the old MGMT: shuts it down, destroys the VM (Terraform, or the
         Proxmox API if it was hand-built) and confirms it's gone, then removes its
         computer object and DNS records. With -KeepOld it is only shut down; run Complete again later
         to destroy it.

    Abort     run on the OLD MGMT, any time before Complete destroys it
      Unlocks it, marks it active again, destroys the replacement and removes its
      computer object. Anything done ON the new MGMT after the handover (Terraform
      changes, ledger edits) is lost, so Abort after handover needs -Force.

.PARAMETER Stage
    Prepare (on the current MGMT), Complete (on the new MGMT) or Abort (on the
    old MGMT); see above.

.EXAMPLE
    ./orchestration/Invoke-LabMgmtRotation.ps1 -Stage Prepare     # on the current MGMT
.EXAMPLE
    ./orchestration/Invoke-LabMgmtRotation.ps1 -Stage Complete    # on the new MGMT
.EXAMPLE
    ./orchestration/Invoke-LabMgmtRotation.ps1 -Stage Abort -Force
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [ValidateSet('Prepare', 'Complete', 'Abort')] [string] $Stage,
    # Prepare: resume a replacement whose bootstrap failed, from the failed stage.
    [switch] $Retry,
    # Complete: shut the old MGMT down but keep its VM for now.
    [switch] $KeepOld,
    # Abort: roll back even though the handover already happened.
    [switch] $Force
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Lab.Orchestration.psm1') -Force -DisableNameChecking

$runLog = Join-Path 'C:\ProgramData\MidCoastLab\Logs\Orchestration' ("mgmt-$($Stage.ToLower())-{0}.txt" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
New-Item -ItemType Directory -Path (Split-Path $runLog) -Force | Out-Null
Start-Transcript -Path $runLog | Out-Null

function Get-MgmtState {
    param($Instances)
    $mgmt = @($Instances | Where-Object role -eq 'MGMT')
    [pscustomobject]@{
        Active   = @($mgmt | Where-Object state -eq 'active')
        Building = @($mgmt | Where-Object state -eq 'building')
        Retiring = @($mgmt | Where-Object state -eq 'retiring')
        Self     = @($mgmt | Where-Object { $_.name -eq $env:COMPUTERNAME })[0]
    }
}

try {
    $findings = & (Join-Path $PSScriptRoot 'Test-LabInventory.ps1') -PassThru
    if (@($findings | Where-Object Level -eq 'Error').Count -gt 0) { throw 'Inventory validation failed.' }
    # Live site pre-flight: Proxmox (node, storage, bridge, ISOs, pool, VMIDs) and lab addresses.
    $site = & (Join-Path $PSScriptRoot 'Test-LabSite.ps1') -PassThru
    if (@($site | Where-Object Level -eq 'Error').Count -gt 0) { throw 'Site pre-flight failed; see above.' }

    $inv       = Get-LabResolvedInventory
    $instances = @(Get-LabInstances -Path (Get-LabLedgerPath))
    $ad        = $inv.identity.active_directory

    switch ($Stage) {

    # ════════════════════════════════════════════════════════════════════════
    'Prepare' {
        Write-Host "`n== MGMT rotation: Prepare (on $env:COMPUTERNAME) ==" -ForegroundColor Cyan
        # A handover that died midway (crash, Ctrl+C) leaves an in-progress lock.
        # Undo it so Prepare can redo the handover from the start.
        $lock = Get-LabHandoverLock -Inventory $inv
        if ($lock -and $lock.status -eq 'in-progress') {
            Write-Warning "An earlier handover to $($lock.handed_over_to) didn't finish; redoing it."
            foreach ($i in $instances) {
                if ($i.role -ne 'MGMT') { continue }
                if ($i.name -eq $env:COMPUTERNAME) { $i.state = 'active' } elseif ($i.name -eq $lock.handed_over_to) { $i.state = 'building' }
            }
            Save-LabLedger -Instances $instances
            Remove-LabHandoverLock -Inventory $inv
        }
        Assert-LabNotHandedOver -Inventory $inv
        $instances = @(Register-LabInitialInstances -Inventory $inv -Instances $instances)
        $m = Get-MgmtState $instances

        if (-not $m.Self -or $m.Self.state -ne 'active') {
            throw "Run Prepare on the active MGMT ($(($m.Active | ForEach-Object name) -join ', ')); this is $env:COMPUTERNAME."
        }
        if ($m.Retiring.Count -gt 0) { throw "A handover is already done ($($m.Retiring[0].name) is retiring). Run Complete on the new MGMT, or Abort here." }

        $dcs = @(Get-LabActiveDCs -Instances $instances)
        if ($dcs.Count -eq 0) { throw 'No active DCs; Phase 1 must be complete before MGMT can be replaced (the replacement joins the domain).' }

        $token = Get-LabPveToken -Inventory $inv
        $family = (Get-LabMgmtDefinition -Inventory $inv).template
        $tplCur = Get-LabCurrentTemplate -Family $family -Inventory $inv
        $tplVm  = if ($tplCur) { Test-LabPveVm -Inventory $inv -Token $token -VmId ([int] $tplCur.vmid) }
        if (-not $tplVm -or -not $tplVm.template) {
            throw "No current $family template$(if ($tplCur) { " ($($tplCur.name) at VMID $($tplCur.vmid) is missing from Proxmox)" }). $(Get-LabTemplateHint -Inventory $inv -Family $family)"
        }

        Push-Location (Get-LabRepoRoot)
        try {
            if (& git status --porcelain 2>$null) { Write-Warning 'The repo has uncommitted changes. They are handed over as they are; consider committing first.' }
        } finally { Pop-Location }

        # ── Allocate (or resume) the replacement ─────────────────────────────
        $new = $m.Building | Select-Object -First 1
        if ($new) {
            Write-Host "Resuming replacement $($new.name) (slot $($new.slot), $($new.ipv4))"
        } else {
            $new = New-LabInstance -Inventory $inv -Instances $instances -Role 'MGMT'
            $instances += $new
            Save-LabLedger -Instances $instances
            Write-Host "Allocated replacement $($new.name) (slot $($new.slot), $($new.ipv4), VMID $($new.vmid))"
        }

        # ── Clone ──────────────────────────────────────────────────────────
        Write-Host "`n-- Terraform" -ForegroundColor Cyan
        Invoke-LabTerraform -Inventory $inv -Command init | Out-Host
        Invoke-LabTerraform -Inventory $inv -Command apply | Out-Host
        $tf = (Invoke-LabTerraform -Inventory $inv -Command output).servers.value

        # ── Bootstrap ──────────────────────────────────────────────────────
        Write-Host "`n-- $($new.name)" -ForegroundColor Cyan
        $cred = Get-LabGuestCredentials -Inventory $inv
        $creds = @($cred.LocalAdmin, $cred.LocalAdmin2, $cred.DomainAdmin)
        $metadata = New-LabMetadata -Inventory $inv -Instance $new -DnsServers @($dcs | ForEach-Object ipv4)
        $secrets  = Add-LabTailscaleSecret -Inventory $inv -Secrets @{ 'svc-domainjoin' = Get-LabSecretText -Inventory $inv -Name 'svc-domainjoin' }
        $result = Deploy-LabInstance -Inventory $inv -Instance $new -Metadata $metadata -Secrets $secrets `
            -Credential $creds -ExtraAddress @($tf.($new.name).agent_ipv4) -Retry:$Retry
        if ($result.State.status -ne 'Complete') {
            throw "$($new.name) bootstrap failed at $($result.State.stage): $($result.State.detail). Fix it and re-run Prepare -Retry, or roll back with -Stage Abort."
        }
        if ($result.Report -and $result.Report.stop_deployment) {
            throw "$($new.name) failed Critical validation; nothing was handed over. Re-run Prepare -Retry after fixing, or -Stage Abort."
        }

        # ── Handover ───────────────────────────────────────────────────────
        # Order matters: lock first (so a crash mid-way never leaves this MGMT
        # unlocked but "retiring"), then flip the ledger, copy, and only then
        # mark the lock complete. Complete on the new MGMT requires the
        # HANDOVER.complete marker that Send-LabHandover writes last.
        Write-Host "`n-- Handover to $($new.name)" -ForegroundColor Cyan
        Set-LabHandoverLock -Inventory $inv -NewInstance $new -Status 'in-progress'
        $before = $instances
        $session = $null
        try {
            $instances = @(Set-LabInstanceState -Instances $instances -Name $new.name -State 'active')
            $instances = @(Set-LabInstanceState -Instances $instances -Name $m.Self.name -State 'retiring')
            Save-LabLedger -Instances $instances
            # After join + LAPS, only domain accounts are certain to work.
            $session = Wait-LabGuest -Address @($new.ipv4) -Credential @($cred.DomainAdmin, $cred.LocalAdmin, $cred.LocalAdmin2) -TimeoutSeconds 600
            $copied = Send-LabHandover -Inventory $inv -Session $session
            $copied | ForEach-Object { Write-Host ("   {0}  ->  {1}  [{2}]" -f $_.Path, $_.Destination, $_.Sha256.Substring(0, 12)) }
        } catch {
            $err = $_.Exception.Message
            if ($session) { try { Clear-LabHandoverTarget -Inventory $inv -Session $session } catch { Write-Warning "Could not clear partial copies on $($new.name): $($_.Exception.Message)" } }
            foreach ($i in $before) { if ($i.name -eq $new.name) { $i.state = 'building' } elseif ($i.name -eq $m.Self.name) { $i.state = 'active' } }
            Save-LabLedger -Instances $before
            Remove-LabHandoverLock -Inventory $inv
            throw "Handover failed; partial copies removed, ledger restored, this MGMT is still active: $err"
        } finally {
            if ($session) { Remove-PSSession $session -ErrorAction SilentlyContinue }
        }
        Set-LabHandoverLock -Inventory $inv -NewInstance $new -Status 'complete'

        Write-Host "`nHandover complete. $env:COMPUTERNAME is now locked." -ForegroundColor Green
        # Same steps, same wording as docs/replace-mgmt.md and runbook step 9.
        $h = (Get-LabMgmtDefinition -Inventory $inv).handover
        Write-Host @"

Next, on $($new.name):
  1. Remote Desktop to $($new.ipv4) as $($ad.netbios)\<you>$($inv.identity.administrative_model.account_suffix).
  2. In PowerShell 7, register the vault for your account (asks for the master password; also sets your git identity):
       cd $($h.repo_path)
       ./setup/mgmt/Initialize-LabVault.ps1 -DatabasePath $($h.vault_path)
  3. Retire $env:COMPUTERNAME, in two steps so you can still roll back:
       ./orchestration/Invoke-LabMgmtRotation.ps1 -Stage Complete -KeepOld   # shuts it down, keeps the VM
       (check the new MGMT; then, to destroy it)
       ./orchestration/Invoke-LabMgmtRotation.ps1 -Stage Complete
     Or in one go: ./orchestration/Invoke-LabMgmtRotation.ps1 -Stage Complete

To roll back instead, here on ${env:COMPUTERNAME}: ./orchestration/Invoke-LabMgmtRotation.ps1 -Stage Abort -Force
"@
    }

    # ════════════════════════════════════════════════════════════════════════
    'Complete' {
        Write-Host "`n== MGMT rotation: Complete (on $env:COMPUTERNAME) ==" -ForegroundColor Cyan
        Assert-LabNotHandedOver -Inventory $inv
        $m = Get-MgmtState $instances
        if (-not $m.Self -or $m.Self.state -ne 'active') {
            throw "Run Complete on the new, active MGMT ($(($m.Active | ForEach-Object name) -join ', ')); this is $env:COMPUTERNAME."
        }
        # A new profile on a new machine: the ledger commits need a name and e-mail.
        Write-Host "   $(Set-LabGitIdentity -Inventory $inv)"
        $old = $m.Retiring | Select-Object -First 1
        if (-not $old) { Write-Host 'No retiring MGMT; nothing to complete.' -ForegroundColor Yellow; return }
        if (-not (Test-LabHandoverComplete -Inventory $inv)) {
            throw "No HANDOVER.complete marker on $env:COMPUTERNAME: the handover from $($old.name) didn't finish. Re-run Prepare on $($old.name), or Abort there."
        }

        # ── Reach: Proxmox and every DC ─────────────────────────────────────
        $token = Get-LabPveToken -Inventory $inv
        $null = Invoke-LabPveApi -Inventory $inv -Token $token -Method GET -Path '/version'
        Write-Host '   Proxmox API: OK'
        $cred = Get-LabGuestCredentials -Inventory $inv
        $dcs = @(Get-LabActiveDCs -Instances $instances)
        foreach ($dc in $dcs) {
            $s = Connect-LabGuest -Address @($dc.ipv4) -Credential @($cred.DomainAdmin, $cred.LabDeploy)
            if (-not $s) { throw "No WinRM/HTTPS session to $($dc.name) ($($dc.ipv4)) from here. Fix this before retiring $($old.name)." }
            Remove-PSSession $s
            Write-Host "   $($dc.name): OK"
        }

        # ── Terraform: fresh init; the handed-over state must match the ledger ─
        # Any create or delete means state and ledger disagree: stop. In-place
        # updates are usually provider drift: warn and carry on.
        Write-Host "`n-- Terraform" -ForegroundColor Cyan
        Invoke-LabTerraform -Inventory $inv -Command init | Out-Host
        $plan = Invoke-LabTerraform -Inventory $inv -Command plan -Json
        $changes = @($plan.resource_changes | Where-Object { @($_.change.actions) -notcontains 'no-op' -and @($_.change.actions) -notcontains 'read' })
        $structural = @($changes | Where-Object { @($_.change.actions) -contains 'create' -or @($_.change.actions) -contains 'delete' })
        if ($structural.Count -gt 0) {
            throw "Terraform state on $env:COMPUTERNAME doesn't match the ledger ($(($structural | ForEach-Object { "$($_.index): $(@($_.change.actions) -join '+')" }) -join '; ')). Investigate before retiring $($old.name)."
        }
        foreach ($c in $changes) { Write-Warning "Terraform wants an in-place update to $($c.index); likely provider drift. Review it with terraform plan later." }
        Write-Host '   state matches the ledger'

        # ── Retire the old MGMT ─────────────────────────────────────────────
        # Order: shut down -> destroy the VM (and confirm it's gone) -> remove
        # AD/DNS records -> update the ledger. A failure at any point leaves the
        # old MGMT either intact and joined (Abort still possible) or gone, never
        # half-retired, and re-running Complete resumes.
        Write-Host "`n-- Retiring $($old.name) (VMID $($old.vmid))" -ForegroundColor Cyan
        if (-not $KeepOld) {
            $ts = Disconnect-LabGuestTailscale -Inventory $inv -Instance $old -Credential @($cred.DomainAdmin, $cred.LabDeploy)
            if ($ts) { Write-Host "   $ts" }
        }
        Stop-LabPveVm -Inventory $inv -Token $token -VmId ([int] $old.vmid)
        Write-Host '   shut down'
        if ($KeepOld) {
            Write-Host "`n$($old.name) is shut down but kept. Run -Stage Complete again to destroy it." -ForegroundColor Yellow
            return
        }

        if ($old.origin -eq 'manual') {
            # Hand-built: Terraform never knew it. Must be visible (in the pool) and confirmed gone.
            Remove-LabPveVm -Inventory $inv -Token $token -VmId ([int] $old.vmid)
            $instances = @(Remove-LabInstance -Instances $instances -Name $old.name)
            Save-LabLedger -Instances $instances
        } else {
            # Remove from the ledger, let Terraform destroy it; restore the ledger if that fails.
            $kept = $instances
            $instances = @(Remove-LabInstance -Instances $instances -Name $old.name)
            Save-LabLedger -Instances $instances
            try { Invoke-LabTerraform -Inventory $inv -Command apply -AllowDelete @($old.name) | Out-Host }
            catch { Save-LabLedger -Instances $kept; throw "Destroying $($old.name) failed; ledger restored, re-run Complete: $($_.Exception.Message)" }
            if (Test-LabPveVm -Inventory $inv -Token $token -VmId ([int] $old.vmid)) { throw "VM $($old.vmid) still exists after terraform apply." }
        }
        Write-Host "   destroyed VM $($old.vmid)"

        Remove-LabComputerRecords -Inventory $inv -ComputerName $old.name -DcAddress @($dcs | ForEach-Object ipv4) -Credential $cred.DomainAdmin |
            ForEach-Object { Write-Host "   $_" }
        # The old MGMT may have been the last clone of a superseded template.
        try { Remove-LabUnusedTemplates -Inventory $inv -Token $token } catch { Write-Warning "Template cleanup skipped: $($_.Exception.Message)" }
        Write-Host "`nMGMT rotation complete: $($old.name) -> $env:COMPUTERNAME." -ForegroundColor Green
        if ($inv.tailscale.enabled -and $old.origin -eq 'manual') {
            Write-Host "$($old.name) was hand-built; if it joined your tailnet, remove it in the Tailscale admin console." -ForegroundColor Yellow
        }
        Write-LabCommitHint -Message "MGMT rotation: $($old.name) -> $env:COMPUTERNAME"
    }

    # ════════════════════════════════════════════════════════════════════════
    'Abort' {
        Write-Host "`n== MGMT rotation: Abort (on $env:COMPUTERNAME) ==" -ForegroundColor Cyan
        $lock = Get-LabHandoverLock -Inventory $inv
        $m = Get-MgmtState $instances
        if (-not $m.Self) { throw "Run Abort on the MGMT being replaced; $env:COMPUTERNAME isn't in the ledger." }
        if ($lock -and $lock.status -eq 'complete' -and -not $Force) {
            throw "Handover to $($lock.handed_over_to) already happened at $($lock.at). Anything done on $($lock.handed_over_to) since then is lost on rollback. Re-run with -Force to continue."
        }
        $token = Get-LabPveToken -Inventory $inv

        # Targets: every other MGMT in the ledger, plus any VM sitting in a MGMT
        # slot that the ledger no longer knows (an earlier Abort that died midway).
        $targets = @($instances | Where-Object { $_.role -eq 'MGMT' -and $_.name -ne $m.Self.name })
        $def = Get-LabMgmtDefinition -Inventory $inv
        $strays = @($def.slots | Where-Object { $_.id -ne $m.Self.slot -and (@($targets | ForEach-Object slot) -notcontains $_.id) } |
            Where-Object { Test-LabPveVm -Inventory $inv -Token $token -VmId ([int] $_.vmid) })
        if ($targets.Count -eq 0 -and $strays.Count -eq 0 -and -not $lock) { Write-Host 'Nothing to abort.' -ForegroundColor Yellow; return }

        # 0. Out of the tailnet (best-effort), while they still run.
        $credTs = Get-LabGuestCredentials -Inventory $inv
        foreach ($t in $targets) {
            $ts = Disconnect-LabGuestTailscale -Inventory $inv -Instance $t -Credential @($credTs.DomainAdmin, $credTs.LocalAdmin, $credTs.LocalAdmin2)
            if ($ts) { Write-Host "   $($t.name): $ts" }
        }

        # 1. Stop the replacement(s) first, so two MGMTs never run as "active".
        foreach ($v in @($targets | ForEach-Object { [int] $_.vmid }) + @($strays | ForEach-Object { [int] $_.vmid })) {
            if (Test-LabPveVm -Inventory $inv -Token $token -VmId $v) {
                try { Stop-LabPveVm -Inventory $inv -Token $token -VmId $v } catch { Write-Warning "Could not stop VM ${v}: $($_.Exception.Message)" }
            }
        }

        # 2. Destroy them; the lock stays on until this succeeds.
        $instances = @(Set-LabInstanceState -Instances $instances -Name $m.Self.name -State 'active')
        foreach ($t in $targets) { $instances = @(Remove-LabInstance -Instances $instances -Name $t.name) }
        Save-LabLedger -Instances $instances
        Invoke-LabTerraform -Inventory $inv -Command init | Out-Host
        Invoke-LabTerraform -Inventory $inv -Command apply -IgnoreHandoverLock -AllowDelete @($targets | ForEach-Object name) | Out-Host
        foreach ($v in @($targets | ForEach-Object { [int] $_.vmid }) + @($strays | ForEach-Object { [int] $_.vmid })) {
            # Terraform removed pipeline-built ones; anything still there is deleted directly.
            Remove-LabPveVm -Inventory $inv -Token $token -VmId $v -AllowMissing
        }

        # 3. AD/DNS records of the replacement(s).
        $cred = Get-LabGuestCredentials -Inventory $inv
        $dcs = @(Get-LabActiveDCs -Instances $instances)
        foreach ($t in $targets) {
            if ($dcs.Count -gt 0) {
                try {
                    Remove-LabComputerRecords -Inventory $inv -ComputerName $t.name -DcAddress @($dcs | ForEach-Object ipv4) -Credential $cred.DomainAdmin |
                        ForEach-Object { Write-Host "   $_" }
                } catch { Write-Warning "Could not remove AD/DNS records for $($t.name): $($_.Exception.Message)" }
            }
            Write-Host "   removed $($t.name)"
        }

        # 4. Only now unlock.
        Remove-LabHandoverLock -Inventory $inv
        Write-Host "`nRolled back. $env:COMPUTERNAME is the active MGMT again." -ForegroundColor Green
        Write-LabCommitHint -Message "MGMT rotation: abort"
    }
    }
} finally {
    Stop-Transcript | Out-Null
}
