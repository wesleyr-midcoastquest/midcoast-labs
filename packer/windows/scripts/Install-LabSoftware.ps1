<#
.SYNOPSIS
    Packer provisioner: installs PowerShell 7 and Cloudbase-Init into the template.

.DESCRIPTION
    Versions come from inventory (templates.<key>.build.software_versions) through
    the environment variables LAB_PWSH_VERSION and LAB_CBI_CHANNEL, which
    windows.pkr.hcl sets. PowerShell "latest" is the newest stable release with a
    Windows x64 MSI (not every release has one); the MSI's SHA-256 is checked
    against the digest GitHub publishes. Cloudbase-Init is installed but left stopped: it runs
    on clones, not during the build.
#>
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
# The release is chosen by its Windows x64 MSI, not its tag: PowerShell 7.7.0 shipped
# without one, so the newest tag isn't always installable. "latest" is the highest
# stable version that has the MSI; a pinned version must have one.
$api     = 'https://api.github.com/repos/PowerShell/PowerShell/releases'
$headers = @{ 'User-Agent' = 'MidCoastLab-Packer'; Accept = 'application/vnd.github+json' }
function Get-PwshMsiAsset($Release) {
    $v = $Release.tag_name.TrimStart('v')
    $Release.assets | Where-Object name -eq "PowerShell-$v-win-x64.msi" | Select-Object -First 1
}
$version = $env:LAB_PWSH_VERSION
if (-not $version -or $version -eq 'latest') {
    # Assigned before piping: Invoke-RestMethod writes a JSON array as one object.
    $all    = Invoke-RestMethod -Uri "$api`?per_page=50" -Headers $headers -UseBasicParsing
    $stable = @($all | Where-Object { -not $_.draft -and -not $_.prerelease -and ($_.tag_name.TrimStart('v') -as [version]) } |
        Sort-Object { [version] $_.tag_name.TrimStart('v') } -Descending)
    $release = $stable | Where-Object { Get-PwshMsiAsset $_ } | Select-Object -First 1
    if (-not $release) { throw 'No stable PowerShell release in the last 50 has a win-x64 MSI on GitHub.' }
    foreach ($skipped in $stable) {
        if ($skipped.tag_name -eq $release.tag_name) { break }
        Write-Host "Skipping PowerShell $($skipped.tag_name): it has no win-x64 MSI."
    }
} else {
    try {
        $release = Invoke-RestMethod -Uri "$api/tags/v$version" -Headers $headers -UseBasicParsing
    } catch {
        throw "PowerShell $version isn't a release on GitHub (software_versions.powershell in lab.yaml): $($_.Exception.Message)"
    }
    if (-not (Get-PwshMsiAsset $release)) {
        throw "PowerShell $version has no win-x64 MSI on GitHub; pin a version that has one (software_versions.powershell in lab.yaml), or use latest."
    }
}
$asset   = Get-PwshMsiAsset $release
$version = $release.tag_name.TrimStart('v')
$pwshMsi = Join-Path $work $asset.name
Invoke-WebRequest -UseBasicParsing -OutFile $pwshMsi -Uri $asset.browser_download_url
# GitHub publishes each asset's SHA-256 (older assets have none).
if ($asset.digest -match '^sha256:([0-9a-fA-F]{64})$') {
    $hash = (Get-FileHash -Algorithm SHA256 -Path $pwshMsi).Hash
    if ($hash -ne $Matches[1].ToUpperInvariant()) { throw "$($asset.name): SHA-256 $hash doesn't match GitHub's $($asset.digest)." }
} else {
    Write-Host "$($asset.name): GitHub publishes no SHA-256 for it; not checked."
}
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
