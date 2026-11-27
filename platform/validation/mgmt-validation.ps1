#Requires -Version 5.1
<#
.SYNOPSIS
    MGMT validation: toolchain, domain membership, and reach to everything
    MGMT manages (DCs over WinRM/HTTPS, the Proxmox API). Runs as SYSTEM.

.DESCRIPTION
    The common checks (NET, TS, MEM, EVAL) come from Lab.Validation; this file
    adds MGMT-001..007. Severity and recovery actions come from catalog.psd1.
    Writes Logs\Validation\latest.json. To run it by hand on MGMT:
        C:\ProgramData\MidCoastLab\Platform\validate.ps1
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] $Metadata,
    [Parameter(Mandatory)] $Inventory
)

$ErrorActionPreference = 'Stop'
$domain  = $Inventory.identity.active_directory.domain
$adkDir  = "${env:ProgramFiles(x86)}\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\amd64\Oscdimg"
$results = @(Invoke-LabCommonChecks -Metadata $Metadata -Inventory $Inventory)

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
    # Every DC slot (MGMT's DNS servers since LAB-261127-01, issue #27). One slot is
    # empty outside a rotation, so this passes when at least the DC role's instance
    # count (two) answer, and names the slot that doesn't.
    $slots  = @(Get-LabDnsClientServers -Inventory $Inventory -Role 'MGMT')
    $want   = [int] (Get-LabRoleDefinition -Inventory $Inventory -Role 'DC').instances
    if ($want -lt 1) { $want = 1 }
    $bad    = @($slots | Where-Object { -not (Test-NetConnection -ComputerName $_ -Port 5986 -WarningAction SilentlyContinue).TcpTestSucceeded })
    $ok     = @($slots | Where-Object { $bad -notcontains $_ })
    $passed = $ok.Count -ge $want
    $detail = if ($ok) { "DCs: $($ok -join ', ')" } else { 'no DC answers' }
    if ($bad) { $detail += "; no WinRM/HTTPS to: $($bad -join ', ')$(if ($passed) { ' (the empty slot)' })" }
    if (-not $passed) { $detail = "only $($ok.Count) of $want DCs answer. $detail" }
    @{ Passed = $passed; Detail = $detail }
}

$results += Invoke-LabCheck -Id 'MGMT-006' -Check {
    $uri  = [uri] $Inventory.proxmox.endpoint
    $port = if ($uri.Port -gt 0) { $uri.Port } else { 8006 }
    $ok   = (Test-NetConnection -ComputerName $uri.Host -Port $port -WarningAction SilentlyContinue).TcpTestSucceeded
    @{ Passed = [bool] $ok; Detail = "$($uri.Host):$port" }
}

# The way in for the handover: Remote Desktop on, listening, firewall open to the lab.
$results += Invoke-LabCheck -Id 'MGMT-007' -Check { Test-LabRemoteDesktop }

Complete-LabValidationReport -Results $results -Role 'MGMT' -OutputDirectory (Join-Path $Inventory.logging.path 'Validation')
