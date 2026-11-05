#Requires -Version 5.1
<#
.SYNOPSIS
    MGMT validation: toolchain, domain membership, and reach to everything
    MGMT manages (DCs over WinRM/HTTPS, the Proxmox API). Runs as SYSTEM.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] $Metadata,
    [Parameter(Mandatory)] $Inventory
)

$ErrorActionPreference = 'Stop'
$domain  = $Inventory.identity.active_directory.domain
$results = @()
$adkDir  = "${env:ProgramFiles(x86)}\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\amd64\Oscdimg"

$results += Invoke-LabCheck -Id 'NET-001' -Check {
    $ip = Get-NetIPAddress -AddressFamily IPv4 -IPAddress $Metadata.ipv4 -ErrorAction SilentlyContinue
    @{ Passed = [bool] ($ip -and $ip.PrefixOrigin -eq 'Manual'); Detail = "expected $($Metadata.ipv4) (manual)" }
}

$results += Invoke-LabCheck -Id 'NET-002' -Check {
    @{ Passed = ($env:COMPUTERNAME -eq $Metadata.hostname.ToUpper()); Detail = "is $env:COMPUTERNAME, expected $($Metadata.hostname)" }
}

$results += Invoke-LabCheck -Id 'MGMT-001' -Check {
    $tools = [ordered]@{
        'PowerShell 7' = Join-Path $env:ProgramFiles 'PowerShell\7\pwsh.exe'
        'Git'          = Join-Path $env:ProgramFiles 'Git\cmd\git.exe'
        'Terraform'    = Join-Path $env:ProgramFiles 'HashiCorp\bin\terraform.exe'
        'Packer'       = Join-Path $env:ProgramFiles 'HashiCorp\bin\packer.exe'
        'VS Code'      = Join-Path $env:ProgramFiles 'Microsoft VS Code\Code.exe'
        'KeePassXC'    = Join-Path $env:ProgramFiles 'KeePassXC\KeePassXC.exe'
        'oscdimg'      = Join-Path $adkDir 'oscdimg.exe'
    }
    $missing = @($tools.Keys | Where-Object { -not (Test-Path $tools[$_]) })
    @{ Passed = ($missing.Count -eq 0); Detail = if ($missing) { "missing: $($missing -join ', ')" } else { '' } }
}

$results += Invoke-LabCheck -Id 'MGMT-002' -Check {
    $caps = 'Rsat.ActiveDirectory.DS-LDS.Tools~~~~0.0.1.0', 'Rsat.Dns.Tools~~~~0.0.1.0', 'Rsat.GroupPolicy.Management.Tools~~~~0.0.1.0'
    $missing = @($caps | Where-Object { (Get-WindowsCapability -Online -Name $_).State -ne 'Installed' })
    @{ Passed = ($missing.Count -eq 0); Detail = if ($missing) { "missing: $($missing -join ', ')" } else { '' } }
}

$results += Invoke-LabCheck -Id 'MGMT-003' -Check {
    $pwsh = Join-Path $env:ProgramFiles 'PowerShell\7\pwsh.exe'
    $out = & $pwsh -NoProfile -NonInteractive -Command "@('powershell-yaml','Microsoft.PowerShell.SecretManagement','SecretManagement.KeePass') | Where-Object { -not (Get-Module -ListAvailable -Name `$_) }" 2>&1
    $missing = @($out | Where-Object { $_ })
    @{ Passed = ($LASTEXITCODE -eq 0 -and $missing.Count -eq 0); Detail = if ($missing) { "missing: $($missing -join ', ')" } else { '' } }
}

$results += Invoke-LabCheck -Id 'MGMT-004' -Check {
    $cs = Get-CimInstance -ClassName Win32_ComputerSystem
    if (-not ($cs.PartOfDomain -and $cs.Domain -eq $domain)) { return @{ Passed = $false; Detail = "domain: $($cs.Domain)" } }
    @{ Passed = (Test-ComputerSecureChannel); Detail = 'secure channel' }
}

$results += Invoke-LabCheck -Id 'MGMT-005' -Check {
    $dcs = @($Metadata.dns_servers)
    $bad = @($dcs | Where-Object { -not (Test-NetConnection -ComputerName $_ -Port 5986 -WarningAction SilentlyContinue).TcpTestSucceeded })
    @{ Passed = ($dcs.Count -gt 0 -and $bad.Count -eq 0); Detail = if ($bad) { "no WinRM/HTTPS to: $($bad -join ', ')" } else { "DCs: $($dcs -join ', ')" } }
}

$results += Invoke-LabCheck -Id 'MGMT-006' -Check {
    $uri  = [uri] $Inventory.proxmox.endpoint
    $port = if ($uri.Port -gt 0) { $uri.Port } else { 8006 }
    $ok   = (Test-NetConnection -ComputerName $uri.Host -Port $port -WarningAction SilentlyContinue).TcpTestSucceeded
    @{ Passed = [bool] $ok; Detail = "$($uri.Host):$port" }
}

$results += Invoke-LabCheck -Id 'MGMT-007' -Check {
    # The way in for the handover: Remote Desktop on, listening, firewall open to the lab.
    $problems = @()
    if ((Get-ItemProperty 'HKLM:\System\CurrentControlSet\Control\Terminal Server').fDenyTSConnections -ne 0) { $problems += 'connections denied' }
    $svc = Get-Service -Name TermService -ErrorAction SilentlyContinue
    if (-not $svc -or $svc.Status -ne 'Running') { $problems += "TermService $(if ($svc) { $svc.Status } else { 'missing' })" }
    if (-not (Get-NetTCPConnection -LocalPort 3389 -State Listen -ErrorAction SilentlyContinue)) { $problems += 'nothing listening on 3389' }
    $rules = @(Get-NetFirewallRule -Group '@FirewallAPI.dll,-28752' -Direction Inbound -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -like 'RemoteDesktop-UserMode-In-*' -and $_.Enabled -eq 'True' })
    if ($rules.Count -eq 0) { $problems += 'firewall rule not enabled' }
    $scope = @($rules | Get-NetFirewallAddressFilter | ForEach-Object RemoteAddress) | Select-Object -Unique
    @{ Passed = ($problems.Count -eq 0); Detail = if ($problems) { $problems -join '; ' } else { "from $($scope -join ', ')" } }
}

$results += Invoke-LabCheck -Id 'TS-001' -Check {
    # site.yaml tailscale.enabled: joined and connected.
    if (-not $Inventory.tailscale.enabled) { return @{ Passed = $true; Detail = 'not enabled for this site' } }
    $st = Get-LabTailscaleStatus
    if (-not $st) { return @{ Passed = $false; Detail = 'Tailscale not installed, or not answering' } }
    @{ Passed = ($st.BackendState -eq 'Running'); Detail = "state $($st.BackendState); $(@($st.TailscaleIPs) -join ', ')" }
}

$results += Invoke-LabCheck -Id 'MEM-001' -Check {
    # Without it Proxmox can't balloon this VM (memory_min_mb in lab.yaml).
    $svc = Get-Service -Name BalloonService -ErrorAction SilentlyContinue
    @{ Passed = ($svc -and $svc.Status -eq 'Running'); Detail = if ($svc) { "BalloonService $($svc.Status)" } else { 'BalloonService not installed' } }
}

$results += Invoke-LabCheck -Id 'EVAL-001' -Check {
    $days = (Get-LabRuntimeMetadata).EvaluationDaysLeft
    if ($null -eq $days) { return @{ Passed = $true; Detail = 'not an evaluation license' } }
    @{ Passed = ($days -gt 30); Detail = "$days days left"; Data = $days }
}

Complete-LabValidationReport -Results $results -Role 'MGMT' -OutputDirectory (Join-Path $Inventory.logging.path 'Validation')
