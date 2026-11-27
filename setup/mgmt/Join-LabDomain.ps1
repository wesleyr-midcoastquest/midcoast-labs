#Requires -Version 7.2
#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Joins the hand-built MGMT-00 to the lab domain and applies everything a
    pipeline-built MGMT gets after its join (runbook step 8).

.DESCRIPTION
    Run once on MGMT-00, in an ELEVATED PowerShell 7 window, after Phase 1.
    1. Points this machine's DNS client at the DC pool's three slot addresses
       (slot order; fixed, so DC rotations never change it) and waits until the
       domain answers.
    2. Joins the domain into the MGMT placement OU (Admin/Tier0/Devices) with
       svc-domainjoin, whose password comes from the vault.
    3. Registers a one-shot task that runs as SYSTEM at the next start-up and
       applies the post-join rules, the same ones every pipeline-built MGMT gets
       (platform/roles/mgmt.ps1 and the handover): the Tier 0 admin group may use
       Remote Desktop, git may use the repo under any account (safe.directory),
       and only SYSTEM, Administrators and the Tier 0 admin group may use
       C:\MidCoastLab. They need the domain, so they run after the restart and
       log to C:\ProgramData\MidCoastLab\Logs\Bootstrap\mgmt00-postjoin.log.
    4. Restarts the machine. Sign in as <you>-a afterwards (runbook step 8).

    Before you run it, have a way back in: the local account's password
    (printed by proxmox-setup.sh) and your -a account's password from the vault.
    The script shows that reminder and asks you to confirm.

    Re-runnable: already joined -> only the post-join task is (re)registered.

.PARAMETER NoRestart
    Don't restart at the end (the post-join rules then wait for your restart).

.EXAMPLE
    ./setup/mgmt/Join-LabDomain.ps1
#>
[CmdletBinding()]
param(
    [switch] $NoRestart
)

$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
Import-Module (Join-Path $repo 'orchestration/Lab.Orchestration.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $repo 'platform/modules/Lab.System/Lab.System.psm1') -Force -DisableNameChecking   # Wait-LabCondition
Import-Module Microsoft.PowerShell.SecretManagement, SecretManagement.KeePass

$inv      = Get-LabResolvedInventory -NoExport
$ad       = $inv.identity.active_directory
$mgmtDef  = Get-LabMgmtDefinition -Inventory $inv
$ouPath   = ConvertTo-LabOUDistinguishedName -OUPath $inv.placement.roles.MGMT -DomainDN (Get-LabDomainDN -Inventory $inv)
$group    = "$($ad.netbios)\SG-ROLE-DomainAdmins"
$repoPath = [string] $mgmtDef.handover.repo_path
$root     = Split-Path $repoPath -Parent
$logDir   = Join-Path $inv.logging.path 'Bootstrap'
$admin    = @($inv.identity.administrative_model.administrators | Where-Object { [int] $_.tier -eq 0 })[0]
$adminAcct = "$($admin.username)$($inv.identity.administrative_model.account_suffix)"

$dcs = @(Get-LabActiveDCs -Instances @(Get-LabInstances -Path (Get-LabLedgerPath)))
if ($dcs.Count -eq 0) { throw 'The ledger has no active DC. Run Phase 1 first (runbook step 7).' }
# Every DC slot, not just the active DCs: the list never changes, so a DC rotation
# has nothing to update on this machine (issue #27).
$dnsIps = @(Get-LabDnsClientServers -Inventory $inv -Role 'MGMT')

$cs = Get-CimInstance -ClassName Win32_ComputerSystem
$joined = $cs.PartOfDomain -and $cs.Domain -eq $ad.domain

if (-not $joined) {
    Write-Host @"

About to join $env:COMPUTERNAME to $($ad.domain) (OU $ouPath) and restart.
The vault lives on this machine and Remote Desktop asks for a password before you get a
desktop, so make sure you can still get in afterwards, from somewhere else:
  - the local account's password (printed by proxmox-setup.sh), and
  - your admin account $($ad.netbios)\$adminAcct, whose password is in the vault:
        Get-Secret -Vault $($inv.secrets.vault) -Name $adminAcct -AsPlainText
If you're locked out anyway, the VM's console in the Proxmox UI still works.
"@ -ForegroundColor Yellow
    if ((Read-Host 'Continue? (y/N)') -notmatch '^y') { Write-Host 'Nothing changed.'; return }

    # ── 1. DNS at the DCs ─────────────────────────────────────────────────
    $route = Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction Stop | Sort-Object RouteMetric | Select-Object -First 1
    Set-DnsClientServerAddress -InterfaceIndex $route.ifIndex -ServerAddresses $dnsIps
    Clear-DnsClientCache
    Write-Host "DNS client -> $($dnsIps -join ', ')"
    Wait-LabCondition -Description "domain $($ad.domain) answers" -TimeoutSeconds 300 -IntervalSeconds 10 -Condition {
        [bool] (Resolve-DnsName -Name "_ldap._tcp.dc._msdcs.$($ad.domain)" -Type SRV -DnsOnly -ErrorAction Stop)
    }

    # ── 2. Join (CIM, since Add-Computer isn't in PowerShell 7) ───────────
    $password = Get-LabSecretText -Inventory $inv -Name 'svc-domainjoin'   # asks for the vault password if locked
    Write-Host "Joining $($ad.domain) as $($ad.netbios)\svc-domainjoin into $ouPath"
    # FJoinOptions 3 = join the domain (1) + create the computer account (2).
    $r = Invoke-CimMethod -InputObject $cs -MethodName JoinDomainOrWorkgroup -Arguments @{
        Name = $ad.domain; UserName = "$($ad.netbios)\svc-domainjoin"; Password = $password; AccountOU = $ouPath; FJoinOptions = 3
    }
    $password = $null
    if ($r.ReturnValue -ne 0) {
        $hint = switch ($r.ReturnValue) { 5 { 'access denied: check svc-domainjoin and the OU delegation' } 1326 { 'bad user name or password' } 2224 { 'the computer account already exists in another OU' } default { "Win32 error $($r.ReturnValue)" } }
        throw "Domain join failed ($hint)."
    }
    Write-Host "Joined $($ad.domain)" -ForegroundColor Green
} else {
    Write-Host "$env:COMPUTERNAME is already joined to $($ad.domain); registering the post-join rules only."
}

# ── 3. Post-join rules, as SYSTEM after the restart ───────────────────────
# Written as a script file the task runs once; it removes the task itself.
New-Item -ItemType Directory -Path $logDir -Force | Out-Null
$taskName = 'MidCoastLab-PostJoin'
$postJoin = Join-Path $root 'postjoin.ps1'
$script = @"
# MidCoast Lab: post-join rules for the hand-built MGMT-00 (written by Join-LabDomain.ps1).
`$ErrorActionPreference = 'Stop'
Start-Transcript -Path '$(Join-Path $logDir 'mgmt00-postjoin.log')' -Append | Out-Null
try {
    Import-Module '$(Join-Path $repoPath 'platform\modules\Lab.System\Lab.System.psm1')' -Force -DisableNameChecking
    # The domain may take a minute to answer after a restart: retry the first step.
    `$deadline = (Get-Date).AddMinutes(15)
    do {
        try { `$ok = Grant-LabRemoteDesktopGroup -Group '$group'; `$ok; break }
        catch { if ((Get-Date) -gt `$deadline) { throw }; Start-Sleep -Seconds 20 }
    } while (`$true)
    Add-LabGitSafeDirectory -Path '$repoPath'
    Set-LabMgmtFolderAcl -Group '$group' -Root '$root' -ProbePath '$(Join-Path $repoPath 'inventory\lab.yaml')'
    'Post-join rules applied'
    Unregister-ScheduledTask -TaskName '$taskName' -Confirm:`$false -ErrorAction SilentlyContinue
    Remove-Item -Path '$postJoin' -Force -ErrorAction SilentlyContinue
} catch {
    "FAILED: `$(`$_.Exception.Message)"
    throw
} finally { Stop-Transcript | Out-Null }
"@
Set-Content -Path $postJoin -Value $script -Encoding UTF8
$action    = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$postJoin`""
$trigger   = New-ScheduledTaskTrigger -AtStartup
$trigger.Delay = 'PT1M'
$principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
$settings  = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Minutes 30) -StartWhenAvailable -MultipleInstances IgnoreNew
Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
Write-Host "Post-join rules will run at the next start-up (task $taskName; log: $logDir\mgmt00-postjoin.log)"

Write-Host @"

After the restart (runbook step 8):
  1. Sign in as $($ad.netbios)\$adminAcct (its password: the vault, see above). Work as that account from now on.
  2. Register the vault for it, in PowerShell 7:
       cd $repoPath
       ./setup/mgmt/Initialize-LabVault.ps1 -DatabasePath $($mgmtDef.handover.vault_path)
"@ -ForegroundColor Green
if ($NoRestart) { Write-Host 'Restart the machine yourself (-NoRestart).' -ForegroundColor Yellow; return }
Write-Host 'Restarting in 15 seconds...'
Start-Sleep -Seconds 15
Restart-Computer -Force
