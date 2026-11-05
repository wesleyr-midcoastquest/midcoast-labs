#Requires -Version 5.1
<#
.SYNOPSIS
    Keeps this machine on the tailnet: a SYSTEM task that logs Tailscale back in
    whenever it has dropped out (after a restart, an update, a Tailscale upgrade).

.DESCRIPTION
    On Windows, a login made with "tailscale up --authkey --unattended" doesn't
    reliably survive a restart (tailscale/tailscale#3186), and the AuthKey system
    policy didn't fix it on the first real lab either. So this installs a watchdog:

      C:\ProgramData\MidCoastLab\Tailscale\
        authkey.bin    the auth key, DPAPI-encrypted for this machine
        watchdog.json  hostname
        watchdog.ps1   checks "tailscale status"; NeedsLogin/Stopped -> "tailscale up"
        watchdog.log   what it did (kept under 1 MB)

    The folder is readable by SYSTEM and Administrators only. The scheduled task
    "MidCoastLab-Tailscale" runs watchdog.ps1 as SYSTEM 2 minutes after every start
    and every 15 minutes. The same flags as the first join: --unattended
    --accept-routes=false --accept-dns=false --hostname=<name>.

    Run it on a lab machine that's already on the tailnet (from MGMT, for an
    existing machine):
      Invoke-Command -ComputerName <ip> -UseSSL -SessionOption $o -Credential <you>-a `
          -FilePath ./platform/tailscale/Enable-LabTailscaleWatchdog.ps1 -ArgumentList $key
    New machines get it from the pipeline (Lab.System Install-LabTailscale).

    -Remove takes it all away (retiring a machine).
#>
[CmdletBinding()]
param(
    [string] $AuthKey,
    [string] $Hostname = $env:COMPUTERNAME,
    [switch] $Remove
)
$ErrorActionPreference = 'Stop'
$dir  = 'C:\ProgramData\MidCoastLab\Tailscale'
$task = 'MidCoastLab-Tailscale'

if ($Remove) {
    Unregister-ScheduledTask -TaskName $task -Confirm:$false -ErrorAction SilentlyContinue
    Remove-Item -Path (Join-Path $dir 'authkey.bin') -Force -ErrorAction SilentlyContinue
    return 'Tailscale watchdog removed'
}
if (-not $AuthKey) { throw 'Give -AuthKey.' }

# Folder: SYSTEM and Administrators only.
New-Item -ItemType Directory -Path $dir -Force | Out-Null
$acl = New-Object System.Security.AccessControl.DirectorySecurity
$acl.SetAccessRuleProtection($true, $false)
foreach ($sid in 'S-1-5-18', 'S-1-5-32-544') {
    $id = New-Object System.Security.Principal.SecurityIdentifier($sid)
    $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($id, 'FullControl', 'ContainerInherit, ObjectInherit', 'None', 'Allow')))
}
Set-Acl -Path $dir -AclObject $acl

Add-Type -AssemblyName System.Security
$enc = [System.Security.Cryptography.ProtectedData]::Protect([System.Text.Encoding]::UTF8.GetBytes($AuthKey), $null,
    [System.Security.Cryptography.DataProtectionScope]::LocalMachine)
[System.IO.File]::WriteAllBytes((Join-Path $dir 'authkey.bin'), $enc)
@{ hostname = $Hostname.ToLowerInvariant() } | ConvertTo-Json | Set-Content -Path (Join-Path $dir 'watchdog.json') -Encoding UTF8

$watchdog = @'
# MidCoast Lab Tailscale watchdog (Enable-LabTailscaleWatchdog.ps1). Runs as SYSTEM.
$ErrorActionPreference = 'Continue'
$dir = 'C:\ProgramData\MidCoastLab\Tailscale'
$log = Join-Path $dir 'watchdog.log'
$exe = Join-Path $env:ProgramFiles 'Tailscale\tailscale.exe'
function Write-Log([string] $m) {
    Add-Content -Path $log -Value ("{0} {1}" -f (Get-Date).ToUniversalTime().ToString('o'), $m)
    if ((Get-Item $log).Length -gt 1MB) { Get-Content $log -Tail 2000 | Set-Content $log }
}
if (-not (Test-Path $exe)) { exit 0 }
$svc = Get-Service -Name Tailscale -ErrorAction SilentlyContinue
if ($svc -and $svc.Status -ne 'Running') { Write-Log 'Tailscale service not running; starting it'; Start-Service Tailscale; Start-Sleep -Seconds 15 }
$st = $null
try { $st = ((& $exe status --json 2>$null) -join "`n") | ConvertFrom-Json } catch { }
$state = if ($st) { [string] $st.BackendState } else { 'unknown' }
if ($state -in 'Running', 'Starting') { exit 0 }
Write-Log "state $state; logging in again"
try {
    Add-Type -AssemblyName System.Security
    $key = [System.Text.Encoding]::UTF8.GetString([System.Security.Cryptography.ProtectedData]::Unprotect(
        [System.IO.File]::ReadAllBytes((Join-Path $dir 'authkey.bin')), $null, [System.Security.Cryptography.DataProtectionScope]::LocalMachine))
    $cfg = Get-Content -Path (Join-Path $dir 'watchdog.json') -Raw | ConvertFrom-Json
    $out = & $exe up "--authkey=$key" --unattended --accept-routes=false --accept-dns=false "--hostname=$($cfg.hostname)" --reset 2>&1
    Write-Log "tailscale up: exit $LASTEXITCODE $((@($out) | ForEach-Object { "$_" }) -join ' ')"
} catch { Write-Log "failed: $($_.Exception.Message)" }
'@
Set-Content -Path (Join-Path $dir 'watchdog.ps1') -Value $watchdog -Encoding UTF8

$action    = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$dir\watchdog.ps1`""
$atStart   = New-ScheduledTaskTrigger -AtStartup
$atStart.Delay = 'PT2M'
$every     = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(2) -RepetitionInterval (New-TimeSpan -Minutes 15) -RepetitionDuration (New-TimeSpan -Days 3650)
$principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
$settings  = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Minutes 10) -MultipleInstances IgnoreNew -StartWhenAvailable
Register-ScheduledTask -TaskName $task -Action $action -Trigger @($atStart, $every) -Principal $principal -Settings $settings -Force | Out-Null
Start-ScheduledTask -TaskName $task
"Tailscale watchdog installed (task ${task}: at start-up and every 15 minutes)"
