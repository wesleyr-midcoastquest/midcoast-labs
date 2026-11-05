# Lab.Validation: validation framework, severity mapping and reporting.
#
# Checks only report pass/fail. Severity and recovery action come from
# platform/validation/catalog.psd1, so one file maps every validation ID to
# what it means and what to do about it.
# Compatible with Windows PowerShell 5.1 and PowerShell 7.

$script:Catalog = $null

function Import-LabValidationCatalog {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Path)
    $script:Catalog = Import-PowerShellDataFile -Path $Path
    $script:Catalog
}

function Get-LabValidationCatalogEntry {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Id)
    if (-not $script:Catalog) { throw 'Validation catalog not loaded; call Import-LabValidationCatalog first.' }
    $entry = $script:Catalog[$Id]
    if (-not $entry) { throw "Validation ID '$Id' is not in the catalog." }
    $entry
}

function Invoke-LabCheck {
    # Runs one check. The script block returns $true/$false, or a hashtable
    # @{ Passed = <bool>; Detail = <string>; Data = <object> }.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]      $Id,
        [Parameter(Mandatory)] [scriptblock] $Check
    )
    $entry  = Get-LabValidationCatalogEntry -Id $Id
    $passed = $false
    $detail = ''
    $data   = $null
    $start  = Get-Date
    try {
        $r = & $Check
        if ($r -is [hashtable]) {
            $passed = [bool] $r.Passed
            $detail = [string] $r.Detail
            $data   = $r.Data
        } else {
            $passed = [bool] $r
        }
    } catch {
        $passed = $false
        $detail = "Check threw: $($_.Exception.Message)"
    }
    [pscustomobject]@{
        id          = $Id
        name        = $entry.Name
        severity    = if ($passed) { 'Pass' } else { $entry.Severity }
        passed      = $passed
        detail      = $detail
        recovery    = if ($passed) { $null } else { $entry.Recovery }
        data        = $data
        duration_ms = [int] ((Get-Date) - $start).TotalMilliseconds
    }
}

function Complete-LabValidationReport {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object[]] $Results,
        [Parameter(Mandatory)] [string]   $Role,
        [string] $OutputDirectory = 'C:\ProgramData\MidCoastLab\Logs\Validation'
    )
    $failed  = @($Results | Where-Object { -not $_.passed })
    $counts  = [ordered]@{}
    foreach ($sev in 'Critical', 'High', 'Medium', 'Low') {
        $counts[$sev] = @($failed | Where-Object severity -eq $sev).Count
    }
    $status = 'Passed'
    if ($counts['Critical'] -gt 0) { $status = 'Failed' }
    elseif ($failed.Count -gt 0)    { $status = 'PassedWithWarnings' }

    $report = [pscustomobject]@{
        computer        = $env:COMPUTERNAME
        role            = $Role
        generated_utc   = (Get-Date).ToUniversalTime().ToString('o')
        status          = $status
        stop_deployment = ($counts['Critical'] -gt 0)
        failures        = $counts
        results         = $Results
    }
    if (-not (Test-Path $OutputDirectory)) { New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null }
    $json = $report | ConvertTo-Json -Depth 8
    $json | Set-Content -Path (Join-Path $OutputDirectory ('{0}-{1}.json' -f $env:COMPUTERNAME, (Get-Date -Format 'yyyyMMdd-HHmmss'))) -Encoding UTF8
    $json | Set-Content -Path (Join-Path $OutputDirectory 'latest.json') -Encoding UTF8
    $report
}

function Format-LabValidationReport {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Report)
    $lines = @("$($Report.computer) [$($Report.role)] validation: $($Report.status)")
    foreach ($r in $Report.results) {
        $mark = if ($r.passed) { 'PASS' } else { $r.severity.ToUpper() }
        $line = '  {0,-8} {1,-10} {2}' -f $mark, $r.id, $r.name
        if (-not $r.passed -and $r.detail) { $line += " -- $($r.detail)" }
        if (-not $r.passed -and $r.recovery) { $line += " [recovery: $($r.recovery)]" }
        $lines += $line
    }
    $lines -join [Environment]::NewLine
}

Export-ModuleMember -Function Import-LabValidationCatalog, Get-LabValidationCatalogEntry,
    Invoke-LabCheck, Complete-LabValidationReport, Format-LabValidationReport
