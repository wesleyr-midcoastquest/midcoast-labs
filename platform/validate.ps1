#Requires -Version 5.1
<#
.SYNOPSIS
    Runs this machine's role validation on demand (outside bootstrap).

.DESCRIPTION
    The orchestrator runs this as SYSTEM through the "MidCoastLab-Validate"
    scheduled task, so checks that talk to other DCs use the computer account
    instead of a remoting session that can't pass credentials on.
    Writes Logs\Validation\latest.json.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$PlatformRoot = 'C:\ProgramData\MidCoastLab\Platform'
foreach ($m in 'Lab.Logging', 'Lab.Metadata', 'Lab.Inventory', 'Lab.System', 'Lab.Validation', 'Lab.AD') {
    Import-Module (Join-Path $PlatformRoot "modules\$m\$m.psm1") -Force -DisableNameChecking -Global
}
$inventory = Get-LabInventory -Path (Join-Path $PlatformRoot 'inventory.json')
$metadata  = Get-LabMetadata
Initialize-LabLogging -Path $inventory.logging.path -RetentionDays ([int] $inventory.logging.retention_days) -Category 'Validation'
Import-LabValidationCatalog -Path (Join-Path $PlatformRoot 'validation\catalog.psd1') | Out-Null

$role   = ([string] $metadata.role).ToLower()
$report = & (Join-Path $PlatformRoot "validation\$role-validation.ps1") -Metadata $metadata -Inventory $inventory
Write-LabLog (Format-LabValidationReport -Report $report)
if ($report.stop_deployment) { exit 2 }
exit 0
