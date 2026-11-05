# Lab.Metadata: deployment metadata (pushed by the orchestrator), build
# metadata (stamped into the registry) and runtime metadata (live facts).
# Compatible with Windows PowerShell 5.1 and PowerShell 7.

$script:MetadataPath = 'C:\ProgramData\MidCoastLab\metadata.json'
$script:RegistryPath = 'HKLM:\SOFTWARE\MidCoastLab'

function Get-LabMetadata {
    [CmdletBinding()]
    param([string] $Path = $script:MetadataPath)
    if (-not (Test-Path $Path)) { throw "Deployment metadata not found at $Path." }
    $m = Get-Content -Path $Path -Raw | ConvertFrom-Json
    foreach ($field in 'hostname', 'role', 'build_date', 'sequence', 'ipv4', 'prefix_length', 'gateway', 'dns_servers', 'mgmt_ipv4s') {
        if ($null -eq $m.$field) { throw "Deployment metadata is missing '$field'." }
    }
    $m
}

function Set-LabBuildMetadata {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Metadata)
    if (-not (Test-Path $script:RegistryPath)) { New-Item -Path $script:RegistryPath -Force | Out-Null }
    $values = [ordered]@{
        Hostname        = [string] $Metadata.hostname
        Role            = [string] $Metadata.role
        Sequence        = [string] $Metadata.sequence
        BuildDate       = [string] $Metadata.build_date
        Slot            = [string] $Metadata.slot
        VmId            = [string] $Metadata.vmid
        PlatformVersion = [string] $Metadata.platform_version
        DeployedUtc     = (Get-Date).ToUniversalTime().ToString('o')
    }
    foreach ($k in $values.Keys) {
        Set-ItemProperty -Path $script:RegistryPath -Name $k -Value $values[$k] -Type String
    }
}

function Get-LabBuildMetadata {
    [CmdletBinding()]
    param()
    if (-not (Test-Path $script:RegistryPath)) { return $null }
    $p = Get-ItemProperty -Path $script:RegistryPath
    [pscustomobject]@{
        Hostname        = $p.Hostname
        Role            = $p.Role
        Sequence        = $p.Sequence
        BuildDate       = $p.BuildDate
        Slot            = $p.Slot
        VmId            = $p.VmId
        PlatformVersion = $p.PlatformVersion
        DeployedUtc     = $p.DeployedUtc
    }
}

function Get-LabRuntimeMetadata {
    [CmdletBinding()]
    param()
    $os = Get-CimInstance -ClassName Win32_OperatingSystem
    # Evaluation clock: GracePeriodRemaining is in minutes.
    $license = Get-CimInstance -ClassName SoftwareLicensingProduct `
        -Filter "PartialProductKey IS NOT NULL AND ApplicationID='55c92734-d682-4d71-983e-d6ec3f16059f'" `
        -ErrorAction SilentlyContinue | Select-Object -First 1
    $evalDays = $null
    if ($license -and $license.GracePeriodRemaining) {
        $evalDays = [math]::Floor($license.GracePeriodRemaining / 1440)
    }
    [pscustomobject]@{
        ComputerName           = $env:COMPUTERNAME
        OperatingSystem        = $os.Caption
        OsBuild                = $os.BuildNumber
        LastBoot               = $os.LastBootUpTime
        UptimeHours            = [math]::Round(((Get-Date) - $os.LastBootUpTime).TotalHours, 1)
        LicenseDescription     = if ($license) { $license.Description } else { $null }
        EvaluationDaysLeft     = $evalDays
        PartOfDomain           = (Get-CimInstance -ClassName Win32_ComputerSystem).PartOfDomain
        Build                  = Get-LabBuildMetadata
    }
}

Export-ModuleMember -Function Get-LabMetadata, Set-LabBuildMetadata, Get-LabBuildMetadata, Get-LabRuntimeMetadata
