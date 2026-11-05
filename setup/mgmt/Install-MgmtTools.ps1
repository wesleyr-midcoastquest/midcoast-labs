#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Installs the MGMT toolchain on the hand-built MGMT-00.

.DESCRIPTION
    A thin wrapper. The implementation is platform/roles/mgmt-tools.ps1,
    the same script a pipeline-built MGMT runs during bootstrap, so the
    hand-built MGMT-00 and every replacement get an identical toolchain.

    Run once in an elevated Windows PowerShell (it grants your account access to
    C:\MidCoastLab, so later steps don't need elevation), then open a NEW PowerShell 7
    window so the PATH changes take effect.

    RSAT: -Rsat standard (default: AD DS/LDS, DNS, Group Policy, Server Manager),
    'all' (every RSAT tool; 3+ hours), or capability names, e.g.
        .\Install-MgmtTools.ps1 -Rsat standard, 'Rsat.Dhcp.Tools~~~~0.0.1.0'
    Keep it the same as lab.yaml's MGMT rsat, so every MGMT gets the same tools.

    Versions default to "latest". To match pinned versions in lab.yaml
    (MGMT software_versions), pass them, e.g.
        .\Install-MgmtTools.ps1 -Versions @{ terraform = '1.9.8'; packer = '1.11.2' }
#>
[CmdletBinding()]
param($Versions, [string[]] $Rsat = @('standard'))

$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$impl = Join-Path $repo 'platform\roles\mgmt-tools.ps1'
if ($Versions) { & $impl -Versions $Versions -Rsat $Rsat } else { & $impl -Rsat $Rsat }
Write-Host "`nDone. Open a new PowerShell 7 window, then continue with docs/mgmt-00.md (vault, repo)."
