# Lab.System: system utilities, bootstrap state, secrets at rest, reboots.
# Compatible with Windows PowerShell 5.1 and PowerShell 7.

$script:Root       = 'C:\ProgramData\MidCoastLab'
$script:StatePath  = Join-Path $script:Root 'State\bootstrap.json'
$script:SecretsDir = Join-Path $script:Root 'Secrets'

# ── Bootstrap state ───────────────────────────────────────────────────────
# The orchestrator polls this file to follow progress across reboots.

function Get-LabState {
    [CmdletBinding()]
    param()
    if (-not (Test-Path $script:StatePath)) {
        return [pscustomobject]@{ stage = 'Start'; status = 'Pending'; detail = ''; updated = $null; history = @() }
    }
    Get-Content -Path $script:StatePath -Raw | ConvertFrom-Json
}

function Set-LabState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Stage,
        [ValidateSet('Pending', 'Running', 'Rebooting', 'Waiting', 'Complete', 'Failed')]
        [string] $Status = 'Running',
        [string] $Detail = ''
    )
    $dir = Split-Path $script:StatePath -Parent
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $previous = Get-LabState
    $history = @()
    if ($previous.history) { $history = @($previous.history) }
    $now = (Get-Date).ToUniversalTime().ToString('o')
    if ($previous.stage -ne $Stage -or $previous.status -ne $Status) {
        $history += [pscustomobject]@{ stage = $Stage; status = $Status; at = $now }
    }
    $state = [pscustomobject]@{
        stage   = $Stage
        status  = $Status
        detail  = $Detail
        updated = $now
        history = $history
    }
    $tmp = "$($script:StatePath).tmp"
    $state | ConvertTo-Json -Depth 5 | Set-Content -Path $tmp -Encoding UTF8
    Move-Item -Path $tmp -Destination $script:StatePath -Force
}

# ── Secrets at rest ───────────────────────────────────────────────────────
# The orchestrator pushes secrets over WinRM/HTTPS. They are stored with
# DPAPI (LocalMachine scope) in a folder only SYSTEM and Administrators can
# read, and deleted when bootstrap finishes.

function Initialize-LabSecretStore {
    [CmdletBinding()]
    param()
    if (-not (Test-Path $script:SecretsDir)) { New-Item -ItemType Directory -Path $script:SecretsDir -Force | Out-Null }
    $acl = New-Object System.Security.AccessControl.DirectorySecurity
    $acl.SetAccessRuleProtection($true, $false)
    $inherit = [System.Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit'
    foreach ($sid in 'S-1-5-18', 'S-1-5-32-544') {   # SYSTEM, BUILTIN\Administrators
        $id = New-Object System.Security.Principal.SecurityIdentifier($sid)
        $rule = New-Object System.Security.AccessControl.FileSystemAccessRule($id, 'FullControl', $inherit, 'None', 'Allow')
        $acl.AddAccessRule($rule)
    }
    Set-Acl -Path $script:SecretsDir -AclObject $acl
}

function Save-LabSecret {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Name,
        [Parameter(Mandatory)] [string] $Value
    )
    Add-Type -AssemblyName System.Security
    Initialize-LabSecretStore
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Value)
    $protected = [System.Security.Cryptography.ProtectedData]::Protect(
        $bytes, $null, [System.Security.Cryptography.DataProtectionScope]::LocalMachine)
    [System.IO.File]::WriteAllBytes((Join-Path $script:SecretsDir "$Name.bin"), $protected)
}

function Get-LabSecret {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Name)
    Add-Type -AssemblyName System.Security
    $file = Join-Path $script:SecretsDir "$Name.bin"
    if (-not (Test-Path $file)) { throw "Secret '$Name' was not delivered to this machine." }
    $bytes = [System.Security.Cryptography.ProtectedData]::Unprotect(
        [System.IO.File]::ReadAllBytes($file), $null,
        [System.Security.Cryptography.DataProtectionScope]::LocalMachine)
    ConvertTo-SecureString -String ([System.Text.Encoding]::UTF8.GetString($bytes)) -AsPlainText -Force
}

function Get-LabCredential {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $UserName,
        [Parameter(Mandatory)] [string] $SecretName
    )
    New-Object System.Management.Automation.PSCredential($UserName, (Get-LabSecret -Name $SecretName))
}

function Remove-LabSecrets {
    [CmdletBinding()]
    param()
    if (Test-Path $script:SecretsDir) {
        Get-ChildItem -Path $script:SecretsDir -File | ForEach-Object {
            # Overwrite before delete; small files, cheap insurance.
            $len = $_.Length
            [System.IO.File]::WriteAllBytes($_.FullName, (New-Object byte[] $len))
            Remove-Item -Path $_.FullName -Force
        }
    }
}

# ── Network and identity ──────────────────────────────────────────────────

function Get-LabPrimaryAdapter {
    [CmdletBinding()]
    param()
    $adapter = Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object Status -eq 'Up' | Sort-Object ifIndex | Select-Object -First 1
    if (-not $adapter) { throw 'No connected network adapter found.' }
    $adapter
}

function Set-LabStaticAddress {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]   $IPv4,
        [Parameter(Mandatory)] [int]      $PrefixLength,
        [Parameter(Mandatory)] [string]   $Gateway,
        [Parameter(Mandatory)] [string[]] $DnsServers
    )
    $adapter = Get-LabPrimaryAdapter
    $current = Get-NetIPAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.PrefixOrigin -ne 'WellKnown' }
    $already = $current | Where-Object { $_.IPAddress -eq $IPv4 -and $_.PrefixOrigin -eq 'Manual' -and $_.PrefixLength -eq $PrefixLength }
    if (-not $already) {
        Set-NetIPInterface -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -Dhcp Disabled
        $current | Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue
        Get-NetRoute -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
            Remove-NetRoute -Confirm:$false -ErrorAction SilentlyContinue
        New-NetIPAddress -InterfaceIndex $adapter.ifIndex -IPAddress $IPv4 -PrefixLength $PrefixLength -DefaultGateway $Gateway | Out-Null
    }
    Set-LabDnsClient -Servers $DnsServers
}

function Set-LabDnsClient {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string[]] $Servers)
    $adapter = Get-LabPrimaryAdapter
    Set-DnsClientServerAddress -InterfaceIndex $adapter.ifIndex -ServerAddresses $Servers
    Clear-DnsClientCache
}

function Test-LabComputerName {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Expected)
    $env:COMPUTERNAME -eq $Expected.ToUpper()
}

function Wait-LabCondition {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [scriptblock] $Condition,
        [Parameter(Mandatory)] [string]      $Description,
        [int] $TimeoutSeconds  = 1800,
        [int] $IntervalSeconds = 15
    )
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ($true) {
        $ok = $false
        try { $ok = [bool] (& $Condition) } catch { $ok = $false }
        if ($ok) { return }
        if ((Get-Date) -gt $deadline) { throw "Timed out after $TimeoutSeconds s waiting for: $Description" }
        Start-Sleep -Seconds $IntervalSeconds
    }
}

function Invoke-LabAsCredential {
    # Runs a script block on THIS machine as another account, through a
    # one-shot scheduled task with a real (batch) logon. Unlike a loopback
    # remoting session, that logon carries full network credentials, so SMB
    # writes to SYSVOL (New-GPO) and Kerberos work normally.
    # The script block must take $PlatformRoot as its first parameter and
    # import what it needs. Output goes to the Bootstrap log; errors throw.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [pscredential] $Credential,
        [Parameter(Mandatory)] [scriptblock]  $ScriptBlock,
        [string] $PlatformRoot   = 'C:\ProgramData\MidCoastLab\Platform',
        [int]    $TimeoutSeconds = 3600
    )
    $work = Join-Path $script:Root 'State\runas'
    if (-not (Test-Path $work)) { New-Item -ItemType Directory -Path $work -Force | Out-Null }
    $id     = [guid]::NewGuid().ToString('N')
    $runFile = Join-Path $work "$id.ps1"
    $result = Join-Path $work "$id.result.json"
    $log    = Join-Path $work "$id.log"
    $wrapper = @"
`$ErrorActionPreference = 'Stop'
`$block = [scriptblock]::Create([IO.File]::ReadAllText('$runFile.body'))
try {
    & `$block '$PlatformRoot' *>> '$log'
    @{ ok = `$true } | ConvertTo-Json | Set-Content -Path '$result'
} catch {
    @{ ok = `$false; error = "`$(`$_.Exception.Message) `$(`$_.ScriptStackTrace)" } | ConvertTo-Json | Set-Content -Path '$result'
}
"@
    Set-Content -Path "$runFile.body" -Value $ScriptBlock.ToString() -Encoding UTF8
    Set-Content -Path $runFile -Value $wrapper -Encoding UTF8

    $task   = "MidCoastLab-RunAs-$id"
    $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$runFile`""
    $settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Seconds $TimeoutSeconds)
    $plain  = $Credential.GetNetworkCredential().Password
    try {
        Register-ScheduledTask -TaskName $task -Action $action -Settings $settings -RunLevel Highest `
            -User $Credential.UserName -Password $plain -Force | Out-Null
        Start-ScheduledTask -TaskName $task
        $deadline = (Get-Date).AddSeconds($TimeoutSeconds + 60)
        while (-not (Test-Path $result)) {
            if ((Get-Date) -gt $deadline) { throw "Run-as task timed out after $TimeoutSeconds s." }
            $info = Get-ScheduledTaskInfo -TaskName $task
            # 267009 = running, 267011 = not yet run; anything else without a result file is a launch failure.
            if ((Get-ScheduledTask -TaskName $task).State -ne 'Running' -and $info.LastTaskResult -notin 0, 267009, 267011) {
                Start-Sleep -Seconds 5
                if (-not (Test-Path $result)) { throw "Run-as task failed to start (result $($info.LastTaskResult))." }
            }
            Start-Sleep -Seconds 5
        }
        if (Test-Path $log) { Get-Content -Path $log | ForEach-Object { Write-LabLog "  [runas] $_" } }
        $r = Get-Content -Path $result -Raw | ConvertFrom-Json
        if (-not $r.ok) { throw "Run-as block failed: $($r.error)" }
    } finally {
        $plain = $null
        Unregister-ScheduledTask -TaskName $task -Confirm:$false -ErrorAction SilentlyContinue
        Remove-Item -Path $runFile, "$runFile.body", $result, $log -Force -ErrorAction SilentlyContinue
    }
}

function Restart-LabComputer {
    # Records the next stage, then reboots. The startup task resumes bootstrap.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $NextStage,
        [string] $Reason = 'Reboot required'
    )
    Set-LabState -Stage $NextStage -Status 'Rebooting' -Detail $Reason
    shutdown.exe /r /t 15 /c "MidCoast Lab bootstrap: $Reason" /d p:4:1 | Out-Null
}

# ── Tailscale (site.yaml tailscale.enabled) ───────────────────────────────

function Test-LabTailnetAddress {
    # True for a Tailscale address: 100.64.0.0/10 or fd7a:115c:a1e0::/48.
    [CmdletBinding()]
    param([Parameter(Mandatory)] [AllowEmptyString()] [string] $Address)
    if ($Address -match '^100\.(\d{1,3})\.\d{1,3}\.\d{1,3}$') { return ([int] $Matches[1] -ge 64 -and [int] $Matches[1] -le 127) }
    return ($Address.ToLowerInvariant() -like 'fd7a:115c:a1e0:*')
}

function Get-LabTailscaleExe { Join-Path $env:ProgramFiles 'Tailscale\tailscale.exe' }

function Get-LabTailscaleStatus {
    # tailscale status --json as an object, or $null.
    [CmdletBinding()]
    param()
    $exe = Get-LabTailscaleExe
    if (-not (Test-Path $exe)) { return $null }
    $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try { $out = & $exe status --json 2>$null } finally { $ErrorActionPreference = $prev }
    try { ($out -join "`n") | ConvertFrom-Json } catch { $null }
}

function Install-LabTailscale {
    # Installs Tailscale and joins this machine to the tailnet with -AuthKey.
    #   --unattended         runs without anyone signed in
    #   --accept-routes=false  the lab's own subnet route must not hijack lab traffic
    #   --accept-dns=false   the tailnet's DNS must never replace the lab's (AD)
    # The Tailscale adapter never registers its address in DNS, and Remote
    # Desktop is allowed on that adapter only (only tailnet peers can reach it;
    # Tailscale's access rules decide which). Returns a one-line status; throws
    # on failure (callers treat it as a warning: the lab works without it).
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $AuthKey,
        [Parameter(Mandatory)] [string] $Hostname,
        [string] $MsiUri = 'https://pkgs.tailscale.com/stable/tailscale-setup-latest-amd64.msi'
    )
    $exe = Get-LabTailscaleExe
    # System policies (read by the Tailscale service). On Windows, a login made with
    # "tailscale up --authkey --unattended" doesn't reliably survive a restart
    # (tailscale/tailscale#3186); with the AuthKey policy the service logs itself back
    # in whenever it needs to. The policy key is readable by SYSTEM and Administrators
    # only, since it holds the key. The settings flags are policies too, so nothing
    # (the tray app included) can switch DNS or routes back on.
    Set-LabTailscalePolicy -AuthKey $AuthKey -Hostname $Hostname
    if (-not (Test-Path $exe)) {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $msi = Join-Path $env:TEMP 'tailscale-setup.msi'
        Invoke-WebRequest -Uri $MsiUri -OutFile $msi -UseBasicParsing
        $p = Start-Process -FilePath msiexec.exe -ArgumentList "/i `"$msi`" /quiet /norestart TS_UNATTENDEDMODE=always" -Wait -PassThru
        Remove-Item -Path $msi -Force -ErrorAction SilentlyContinue
        if ($p.ExitCode -notin 0, 3010) { throw "Tailscale installer failed (exit $($p.ExitCode))." }
    }
    # The adapter appears when the service starts. Stop it registering in DNS
    # before it has a tailnet address.
    $deadline = (Get-Date).AddMinutes(2)
    while (-not (Get-NetAdapter -Name 'Tailscale' -ErrorAction SilentlyContinue) -and (Get-Date) -lt $deadline) { Start-Sleep -Seconds 3 }
    if (-not (Get-NetAdapter -Name 'Tailscale' -ErrorAction SilentlyContinue)) { throw 'The Tailscale network adapter did not appear.' }
    Set-DnsClient -InterfaceAlias 'Tailscale' -RegisterThisConnectionsAddress $false

    $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try {
        $out = & $exe up "--authkey=$AuthKey" --unattended --accept-routes=false --accept-dns=false "--hostname=$($Hostname.ToLowerInvariant())" --reset 2>&1
        $code = $LASTEXITCODE
    } finally { $ErrorActionPreference = $prev }
    if ($code -ne 0) {
        # Never echo the command line (it holds the key); the output doesn't.
        throw "tailscale up failed (exit $code): $((@($out) | ForEach-Object { "$_" }) -join ' ')"
    }
    $deadline = (Get-Date).AddMinutes(2)
    do { $st = Get-LabTailscaleStatus; if ($st -and $st.BackendState -eq 'Running') { break }; Start-Sleep -Seconds 3 } while ((Get-Date) -lt $deadline)
    if (-not $st -or $st.BackendState -ne 'Running') { throw "Tailscale didn't connect (state: $(if ($st) { $st.BackendState } else { 'unknown' }))." }
    # Again, now that the adapter has its addresses.
    Set-DnsClient -InterfaceAlias 'Tailscale' -RegisterThisConnectionsAddress $false

    Get-NetFirewallRule -Name 'MidCoastLab-RDP-Tailscale' -ErrorAction SilentlyContinue | Remove-NetFirewallRule
    New-NetFirewallRule -Name 'MidCoastLab-RDP-Tailscale' -DisplayName 'MidCoast Lab Remote Desktop (Tailscale adapter)' `
        -Direction Inbound -Protocol TCP -LocalPort 3389 -InterfaceAlias 'Tailscale' `
        -RemoteAddress '100.64.0.0/10', 'fd7a:115c:a1e0::/48' -Action Allow -Profile Any | Out-Null
    # Restarts and updates can log Windows Tailscale out; the watchdog logs it back in.
    $wd = & (Join-Path $PSScriptRoot '..\..\tailscale\Enable-LabTailscaleWatchdog.ps1') -AuthKey $AuthKey -Hostname $Hostname
    "joined the tailnet as $($Hostname.ToLowerInvariant()) ($(@($st.TailscaleIPs) -join ', ')); Remote Desktop allowed on the Tailscale adapter; $wd"
}

function Set-LabTailscalePolicy {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $AuthKey, [Parameter(Mandatory)] [string] $Hostname)
    $key = 'HKLM:\SOFTWARE\Policies\Tailscale'
    New-Item -Path $key -Force | Out-Null
    $acl = New-Object System.Security.AccessControl.RegistrySecurity
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($sid in 'S-1-5-18', 'S-1-5-32-544') {   # SYSTEM, BUILTIN\Administrators
        $id = New-Object System.Security.Principal.SecurityIdentifier($sid)
        $acl.AddAccessRule((New-Object System.Security.AccessControl.RegistryAccessRule($id, 'FullControl', 'ContainerInherit, ObjectInherit', 'None', 'Allow')))
    }
    Set-Acl -Path $key -AclObject $acl
    $values = [ordered]@{
        AuthKey                  = $AuthKey
        UnattendedMode           = 'always'
        UseTailscaleDNSSettings  = 'never'
        UseTailscaleSubnets      = 'never'
        Hostname                 = $Hostname.ToLowerInvariant()
        OnboardingFlow           = 'hide'
    }
    foreach ($k in $values.Keys) { New-ItemProperty -Path $key -Name $k -Value $values[$k] -PropertyType String -Force | Out-Null }
}

function Disconnect-LabTailscale {
    # Logs this machine out of the tailnet (it disappears from the device list). Best-effort.
    # The AuthKey policy goes first, or the service would log straight back in.
    [CmdletBinding()]
    param()
    Remove-ItemProperty -Path 'HKLM:\SOFTWARE\Policies\Tailscale' -Name AuthKey -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName 'MidCoastLab-Tailscale' -Confirm:$false -ErrorAction SilentlyContinue
    Remove-Item -Path 'C:\ProgramData\MidCoastLab\Tailscale\authkey.bin' -Force -ErrorAction SilentlyContinue
    $exe = Get-LabTailscaleExe
    if (-not (Test-Path $exe)) { return 'Tailscale not installed' }
    $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try { & $exe logout 2>&1 | Out-Null; $code = $LASTEXITCODE } finally { $ErrorActionPreference = $prev }
    if ($code -eq 0) { 'logged out of the tailnet' } else { "tailscale logout exit $code" }
}

Export-ModuleMember -Function Get-LabState, Set-LabState, Initialize-LabSecretStore, Save-LabSecret,
    Get-LabSecret, Get-LabCredential, Remove-LabSecrets, Get-LabPrimaryAdapter, Set-LabStaticAddress,
    Set-LabDnsClient, Test-LabComputerName, Wait-LabCondition, Invoke-LabAsCredential, Restart-LabComputer,
    Test-LabTailnetAddress, Get-LabTailscaleExe, Get-LabTailscaleStatus, Install-LabTailscale, Set-LabTailscalePolicy, Disconnect-LabTailscale
