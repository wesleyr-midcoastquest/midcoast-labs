# Lab.Logging: structured logs, transcripts and retention.
# Compatible with Windows PowerShell 5.1 and PowerShell 7.

$script:LogRoot       = 'C:\ProgramData\MidCoastLab\Logs'
$script:RetentionDays = 90
$script:Category      = 'Bootstrap'

function Initialize-LabLogging {
    [CmdletBinding()]
    param(
        [string] $Path = 'C:\ProgramData\MidCoastLab\Logs',
        [int]    $RetentionDays = 90,
        [string] $Category = 'Bootstrap'
    )
    $script:LogRoot       = $Path
    $script:RetentionDays = $RetentionDays
    $script:Category      = $Category
    foreach ($c in 'Bootstrap', 'Validation', 'Installers', 'Cloudbase-Init', 'Orchestration') {
        $dir = Join-Path $script:LogRoot $c
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    }
    Invoke-LabLogRetention
}

function Get-LabLogPath {
    [CmdletBinding()]
    param([string] $Category = $script:Category)
    $dir = Join-Path $script:LogRoot $Category
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    Join-Path $dir ('{0}-{1}.log' -f $env:COMPUTERNAME, (Get-Date -Format 'yyyyMMdd'))
}

function Write-LabLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)] [string] $Message,
        [ValidateSet('Info', 'Warn', 'Error', 'Debug')] [string] $Level = 'Info',
        [string] $Category = $script:Category
    )
    $line = '{0} [{1,-5}] {2}' -f (Get-Date -Format 'yyyy-MM-ddTHH:mm:ss.fffK'), $Level.ToUpper(), $Message
    Add-Content -Path (Get-LabLogPath -Category $Category) -Value $line -Encoding UTF8
    switch ($Level) {
        'Error' { Write-Error   $Message -ErrorAction Continue }
        'Warn'  { Write-Warning $Message }
        default { Write-Host    $line }
    }
}

function Start-LabTranscript {
    [CmdletBinding()]
    param([string] $Category = $script:Category)
    $dir = Join-Path $script:LogRoot $Category
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $file = Join-Path $dir ('{0}-transcript-{1}.txt' -f $env:COMPUTERNAME, (Get-Date -Format 'yyyyMMdd-HHmmss'))
    try { Start-Transcript -Path $file -Append | Out-Null } catch { }
    $file
}

function Stop-LabTranscript {
    try { Stop-Transcript | Out-Null } catch { }
}

function Invoke-LabLogRetention {
    [CmdletBinding()]
    param()
    if (-not (Test-Path $script:LogRoot)) { return }
    $cutoff = (Get-Date).AddDays(-$script:RetentionDays)
    Get-ChildItem -Path $script:LogRoot -File -Recurse -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -lt $cutoff } |
        Remove-Item -Force -ErrorAction SilentlyContinue
}

Export-ModuleMember -Function Initialize-LabLogging, Get-LabLogPath, Write-LabLog,
    Start-LabTranscript, Stop-LabTranscript, Invoke-LabLogRetention
