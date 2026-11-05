#Requires -Version 5.1
<#
.SYNOPSIS
    MidCoast Lab bootstrap. Runs inside every pipeline-built guest.

.DESCRIPTION
    Cloudbase-Init -> bootstrap.ps1 -> role script -> validation script.

    The orchestrator pushes the platform (this folder), metadata.json and the
    role's secrets over WinRM/HTTPS, registers the "MidCoastLab-Bootstrap"
    scheduled task (SYSTEM, at startup) and starts it. Bootstrap is a state
    machine persisted in C:\ProgramData\MidCoastLab\State\bootstrap.json, so
    it resumes after every reboot.

    Stages:  Common -> Role:<stage>... -> Validate -> Complete
#>
[CmdletBinding()]
param(
    # Re-run after a failure, starting from the stage that failed.
    [switch] $Retry
)

$ErrorActionPreference = 'Stop'
$Root         = 'C:\ProgramData\MidCoastLab'
$PlatformRoot = Join-Path $Root 'Platform'
$TaskName     = 'MidCoastLab-Bootstrap'

# One bootstrap at a time (startup trigger and a manual start can overlap).
$mutex = New-Object System.Threading.Mutex($false, 'Global\MidCoastLabBootstrap')
if (-not $mutex.WaitOne(0)) { Write-Host 'Bootstrap already running.'; exit 0 }

try {
    foreach ($m in 'Lab.Logging', 'Lab.Metadata', 'Lab.Inventory', 'Lab.System', 'Lab.Validation', 'Lab.AD', 'Lab.Entra') {
        Import-Module (Join-Path $PlatformRoot "modules\$m\$m.psm1") -Force -DisableNameChecking -Global
    }

    $Inventory = Get-LabInventory -Path (Join-Path $PlatformRoot 'inventory.json')
    $Metadata  = Get-LabMetadata
    Initialize-LabLogging -Path $Inventory.logging.path -RetentionDays ([int] $Inventory.logging.retention_days) -Category 'Bootstrap'
    $null = Start-LabTranscript
    Import-LabValidationCatalog -Path (Join-Path $PlatformRoot 'validation\catalog.psd1') | Out-Null

    $state = Get-LabState
    if ($state.status -eq 'Complete') { Write-LabLog 'Bootstrap already complete.'; exit 0 }
    if ($state.status -eq 'Failed' -and -not $Retry) {
        Write-LabLog "Bootstrap previously failed at '$($state.stage)': $($state.detail). Run with -Retry." -Level Warn
        exit 1
    }
    $stage = if ($state.stage -eq 'Start') { 'Common' } else { $state.stage }
    $role  = ([string] $Metadata.role).ToLower()
    $roleScript = Join-Path $PlatformRoot "roles\$role.ps1"
    if (-not (Test-Path $roleScript)) { throw "No role script for role '$($Metadata.role)'." }

    Write-LabLog "Bootstrap $($Metadata.hostname) role=$($Metadata.role) stage=$stage platform=$($Metadata.platform_version)"

    while ($true) {
        Set-LabState -Stage $stage -Status 'Running'

        if ($stage -eq 'Common') {
            # Windows 11 clones: OOBE created this account only so it could finish.
            if (Get-LocalUser -Name 'MidCoastSetup' -ErrorAction SilentlyContinue) {
                Remove-LocalUser -Name 'MidCoastSetup'
                Write-LabLog 'Removed the OOBE setup account MidCoastSetup'
            }
            # Time zone, build stamp, static address, name.
            & tzutil.exe /s $Inventory.environment.time_zone
            Set-LabBuildMetadata -Metadata $Metadata
            # Let the orchestrator's push session finish before the DHCP address goes away.
            if (-not (Get-NetIPAddress -IPAddress $Metadata.ipv4 -ErrorAction SilentlyContinue)) { Start-Sleep -Seconds 30 }
            Set-LabStaticAddress -IPv4 $Metadata.ipv4 -PrefixLength ([int] $Metadata.prefix_length) `
                -Gateway $Metadata.gateway -DnsServers @($Metadata.dns_servers)
            Write-LabLog "Static address $($Metadata.ipv4)/$($Metadata.prefix_length), DNS $(@($Metadata.dns_servers) -join ', ')"

            if (-not (Test-LabComputerName -Expected $Metadata.hostname)) {
                Write-LabLog "Renaming $env:COMPUTERNAME -> $($Metadata.hostname)"
                Rename-Computer -NewName $Metadata.hostname -Force
                Restart-LabComputer -NextStage 'Role:Start' -Reason "Rename to $($Metadata.hostname)"
                exit 0
            }
            $stage = 'Role:Start'
            continue
        }

        if ($stage -like 'Role:*') {
            $roleStage = $stage.Substring(5)
            Write-LabLog "Role $($Metadata.role): stage $roleStage"
            # Take the last object: the role script's Step result.
            $result = & $roleScript -Metadata $Metadata -Inventory $Inventory -Stage $roleStage | Select-Object -Last 1
            if (-not $result -or -not ($result.PSObject.Properties.Name -contains 'Next')) { throw "Role script returned no step for stage $roleStage." }
            $next = if ($result.Next) { "Role:$($result.Next)" } else { 'Validate' }
            if ($result.Reboot) {
                Restart-LabComputer -NextStage $next -Reason "$($Metadata.role) $roleStage complete"
                exit 0
            }
            $stage = $next
            continue
        }

        if ($stage -eq 'Validate') {
            $validation = Join-Path $PlatformRoot "validation\$role-validation.ps1"
            $report = & $validation -Metadata $Metadata -Inventory $Inventory
            Write-LabLog (Format-LabValidationReport -Report $report) -Category 'Validation'
            Remove-LabSecrets
            Disable-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue | Out-Null
            if ($report.stop_deployment) {
                Set-LabState -Stage 'Validate' -Status 'Failed' -Detail "Critical validation failure(s): $(@($report.results | Where-Object { -not $_.passed -and $_.severity -eq 'Critical' } | ForEach-Object id) -join ', ')"
                exit 2
            }
            Set-LabState -Stage 'Complete' -Status 'Complete' -Detail $report.status
            Write-LabLog "Bootstrap complete: $($report.status)"
            exit 0
        }

        throw "Unknown bootstrap stage '$stage'."
    }
} catch {
    $msg = $_.Exception.Message
    try {
        Write-LabLog "Bootstrap failed: $msg`n$($_.ScriptStackTrace)" -Level Error
        $current = Get-LabState
        Set-LabState -Stage $current.stage -Status 'Failed' -Detail $msg
        # Never leave secrets behind; -Retry pushes them again.
        Remove-LabSecrets
    } catch { }
    exit 1
} finally {
    Stop-LabTranscript
    $mutex.ReleaseMutex()
}
