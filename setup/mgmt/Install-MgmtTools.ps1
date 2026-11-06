#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Installs the MGMT toolchain on the hand-built MGMT-00 (runbook step 5).

.DESCRIPTION
    A thin wrapper. The implementation is platform/roles/mgmt-tools.ps1,
    the same script a pipeline-built MGMT runs during bootstrap, so the
    hand-built MGMT-00 and every replacement get an identical toolchain:
    PowerShell 7, Git, Terraform, Packer, VS Code, KeePassXC, the ADK
    Deployment Tools (oscdimg.exe), RSAT and the PowerShell modules.

    Run once, in an elevated Windows PowerShell, from any copy of the repo. It
    also creates C:\MidCoastLab and grants your account access, so the steps
    that follow don't need elevation. Then open a NEW PowerShell 7 window (the
    PATH changed) and continue with setup/mgmt/Initialize-LabRepo.ps1.

.PARAMETER Rsat
    'standard' (default: AD DS/LDS, DNS, Group Policy, Server Manager), 'all'
    (every RSAT tool; 3+ hours), or capability names, e.g.
        .\Install-MgmtTools.ps1 -Rsat standard, 'Rsat.Dhcp.Tools~~~~0.0.1.0'
    Keep it the same as lab.yaml's MGMT rsat, so every MGMT gets the same tools.

.PARAMETER Versions
    Versions default to "latest". To match pinned versions in lab.yaml
    (MGMT software_versions), pass them, e.g.
        .\Install-MgmtTools.ps1 -Versions @{ terraform = '1.9.8'; packer = '1.11.2' }

.EXAMPLE
    .\setup\mgmt\Install-MgmtTools.ps1
#>
[CmdletBinding()]
param($Versions, [string[]] $Rsat = @('standard'))

$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$impl = Join-Path $repo 'platform\roles\mgmt-tools.ps1'
if ($Versions) { & $impl -Versions $Versions -Rsat $Rsat } else { & $impl -Rsat $Rsat }
Write-Host @"

Done. Next (runbook step 5, item 3): close this window, open a NEW PowerShell 7
window (not elevated), and from this folder run:
    ./setup/mgmt/Initialize-LabRepo.ps1
"@ -ForegroundColor Green
