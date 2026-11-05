# Install-LabSoftware.ps1: PowerShell 7 and Cloudbase-Init for the template.
# Versions come from inventory (templates.*.build.software_versions) via
# LAB_PWSH_VERSION and LAB_CBI_CHANNEL.
$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$work = 'C:\Windows\Temp\lab-software'
New-Item -ItemType Directory -Path $work -Force | Out-Null

function Install-Msi([string] $Path, [string[]] $Properties = @()) {
    $log  = "$Path.log"
    $msiArgs = @('/i', "`"$Path`"", '/qn', '/norestart', '/l*v', "`"$log`"") + $Properties
    $p = Start-Process -FilePath msiexec.exe -ArgumentList $msiArgs -Wait -PassThru
    if ($p.ExitCode -notin 0, 3010) { throw "msiexec $Path failed with exit code $($p.ExitCode); see $log" }
}

# ── PowerShell 7 ───────────────────────────────────────────────────────────
$version = $env:LAB_PWSH_VERSION
if (-not $version -or $version -eq 'latest') {
    $rel = Invoke-RestMethod -Uri 'https://api.github.com/repos/PowerShell/PowerShell/releases/latest' -UseBasicParsing
    $version = $rel.tag_name.TrimStart('v')
}
$pwshMsi = Join-Path $work "PowerShell-$version-win-x64.msi"
Invoke-WebRequest -UseBasicParsing -OutFile $pwshMsi `
    -Uri "https://github.com/PowerShell/PowerShell/releases/download/v$version/PowerShell-$version-win-x64.msi"
Install-Msi $pwshMsi @('ADD_PATH=1', 'ENABLE_PSREMOTING=0', 'REGISTER_MANIFEST=1', 'USE_MU=1', 'ENABLE_MU=1')
Write-Host "Installed PowerShell $version"

# ── Cloudbase-Init ─────────────────────────────────────────────────────────
$channel = if ($env:LAB_CBI_CHANNEL) { $env:LAB_CBI_CHANNEL } else { 'stable' }
$cbiName = if ($channel -eq 'stable') { 'CloudbaseInitSetup_Stable_x64.msi' } else { 'CloudbaseInitSetup_x64.msi' }
$cbiMsi  = Join-Path $work $cbiName
Invoke-WebRequest -UseBasicParsing -OutFile $cbiMsi -Uri "https://cloudbase.it/downloads/$cbiName"
# Configuration files are replaced by Packer after install.
Install-Msi $cbiMsi @('RUN_SERVICE_AS_LOCAL_SYSTEM=1', 'USERNAME=Administrator', 'INJECTMETADATAPASSWORD=FALSE', 'LOGGINGSERIALPORTNAME=')

# The service must not run during the build (no config drive yet).
Set-Service -Name cloudbase-init -StartupType Manual
Stop-Service -Name cloudbase-init -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path 'C:\Program Files\Cloudbase Solutions\Cloudbase-Init\LocalScripts' | Out-Null
New-Item -ItemType Directory -Force -Path 'C:\ProgramData\MidCoastLab\Logs\Cloudbase-Init' | Out-Null
Write-Host 'Installed Cloudbase-Init'

# ── QEMU guest agent sanity check ──────────────────────────────────────────
if ((Get-Service -Name QEMU-GA -ErrorAction SilentlyContinue).Status -ne 'Running') {
    throw 'QEMU guest agent (QEMU-GA) is not running.'
}

Remove-Item -Path $work -Recurse -Force -ErrorAction SilentlyContinue
