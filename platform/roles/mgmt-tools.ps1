#Requires -Version 5.1
<#
.SYNOPSIS
    Installs the MGMT toolchain. The single implementation, used by both the
    MGMT role (bootstrap, as SYSTEM) and setup/mgmt/Install-MgmtTools.ps1
    (the one-time hand-build).

.DESCRIPTION
    Inventory services: Git, Terraform, Packer, VSCode, RSAT. Plus what the
    pipeline needs: PowerShell 7, KeePassXC, the Windows ADK Deployment Tools
    (oscdimg.exe for Packer's generated CD), and the PowerShell modules
    powershell-yaml, SecretManagement, SecretManagement.KeePass.

    Direct vendor downloads, not winget: winget isn't reliably available to
    SYSTEM. HashiCorp zips are checked against the published SHA256SUMS.
    Every step is skipped when the tool is already present. Safe to re-run.

.PARAMETER Rsat
    'standard' (default): what the lab uses: AD DS/LDS, DNS, Group Policy, Server
    Manager. 'all': every RSAT tool Windows offers (3+ hours from Windows Update).
    Or capability names, e.g. 'Rsat.Dhcp.Tools~~~~0.0.1.0', alone or with 'standard'.

.PARAMETER Versions
    Hashtable or object with git, terraform, packer, vscode, keepassxc,
    each "latest" or an exact version (inventory: MGMT software_versions).
    Git for Windows and KeePassXC pins are release TAGS, e.g. "v2.47.1.windows.1"
    and "2.7.9"; HashiCorp and VS Code pins are plain versions.
#>
[CmdletBinding()]
param(
    $Versions = @{ git = 'latest'; terraform = 'latest'; packer = 'latest'; vscode = 'latest'; keepassxc = 'latest' },
    # 'standard', 'all', or RSAT capability names (inventory: MGMT rsat).
    [string[]] $Rsat = @('standard')
)

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$work = Join-Path $env:SystemRoot 'Temp\mgmt-tools'
New-Item -ItemType Directory -Path $work -Force | Out-Null
$hashiBin = Join-Path $env:ProgramFiles 'HashiCorp\bin'
$ua = @{ 'User-Agent' = 'MidCoastLab-Installer' }

function Write-Step([string] $Message) {
    if (Get-Command Write-LabLog -ErrorAction SilentlyContinue) { Write-LabLog $Message -Category 'Installers' }
    else { Write-Host $Message }
}

function Get-Version([string] $Name) {
    $v = $null
    if ($Versions -is [hashtable]) { $v = $Versions[$Name] } elseif ($Versions) { $v = $Versions.$Name }
    if (-not $v) { 'latest' } else { [string] $v }
}

function Save-Download([string] $Uri, [string] $FileName) {
    $out = Join-Path $work $FileName
    Invoke-WebRequest -Uri $Uri -OutFile $out -UseBasicParsing -Headers $ua
    $out
}

function Invoke-Installer([string] $FilePath, [string[]] $Arguments, [int[]] $OkCodes = @(0, 3010)) {
    $p = Start-Process -FilePath $FilePath -ArgumentList $Arguments -Wait -PassThru
    if ($OkCodes -notcontains $p.ExitCode) { throw "$(Split-Path $FilePath -Leaf) exited with $($p.ExitCode)." }
}

function Get-GitHubAsset([string] $Repo, [string] $Version, [string] $Pattern) {
    $uri = if ($Version -eq 'latest') { "https://api.github.com/repos/$Repo/releases/latest" } else { "https://api.github.com/repos/$Repo/releases/tags/$Version" }
    $rel = Invoke-RestMethod -Uri $uri -UseBasicParsing -Headers $ua
    $asset = @($rel.assets | Where-Object { $_.name -match $Pattern })[0]
    if (-not $asset) { throw "No asset matching '$Pattern' in $Repo $($rel.tag_name). Assets: $(@($rel.assets | ForEach-Object name) -join ', ')" }
    [pscustomobject]@{ Tag = $rel.tag_name; Name = $asset.name; Url = $asset.browser_download_url }
}

function Add-MachinePath([string] $Dir) {
    $path = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    if (($path -split ';') -notcontains $Dir) {
        [Environment]::SetEnvironmentVariable('Path', "$path;$Dir", 'Machine')
    }
    if (($env:Path -split ';') -notcontains $Dir) { $env:Path = "$env:Path;$Dir" }
}

function Install-HashiCorpTool([string] $Name) {
    $exe = Join-Path $hashiBin "$Name.exe"
    if (Test-Path $exe) { Write-Step "  $Name already installed"; return }
    $v = Get-Version $Name
    if ($v -eq 'latest') {
        $v = (Invoke-RestMethod -Uri "https://checkpoint-api.hashicorp.com/v1/check/$Name" -UseBasicParsing -Headers $ua).current_version
    }
    $zipName = "${Name}_${v}_windows_amd64.zip"
    $base    = "https://releases.hashicorp.com/$Name/$v"
    $zip     = Save-Download "$base/$zipName" $zipName
    # Read SUMS from disk: on 5.1, .Content can be a byte[] for non-text content types.
    $sums    = Get-Content -Raw -Path (Save-Download "$base/${Name}_${v}_SHA256SUMS" "${Name}_SHA256SUMS")
    $expected = (($sums -split "`n") | Where-Object { $_ -match [regex]::Escape($zipName) } | ForEach-Object { ($_ -split '\s+')[0] })
    $actual   = (Get-FileHash -Path $zip -Algorithm SHA256).Hash
    if (-not $expected -or $actual -ne $expected.ToUpper()) { throw "$zipName failed its SHA256 check." }
    New-Item -ItemType Directory -Path $hashiBin -Force | Out-Null
    Expand-Archive -Path $zip -DestinationPath $hashiBin -Force
    Write-Step "  installed $Name $v"
}

Write-Step '==> MGMT toolchain'

# ── PowerShell 7 (already in pipeline templates; the hand-build needs it) ─
$pwsh = Join-Path $env:ProgramFiles 'PowerShell\7\pwsh.exe'
if (-not (Test-Path $pwsh)) {
    $a = Get-GitHubAsset -Repo 'PowerShell/PowerShell' -Version 'latest' -Pattern '^PowerShell-[\d\.]+-win-x64\.msi$'
    $msi = Save-Download $a.Url $a.Name
    Invoke-Installer msiexec.exe @('/i', "`"$msi`"", '/qn', '/norestart', 'ADD_PATH=1', 'ENABLE_PSREMOTING=0', 'REGISTER_MANIFEST=1', 'USE_MU=1', 'ENABLE_MU=1')
    Write-Step "  installed PowerShell $($a.Tag)"
} else { Write-Step '  PowerShell 7 already installed' }

# ── Git ────────────────────────────────────────────────────────────────────
$gitExe = Join-Path $env:ProgramFiles 'Git\cmd\git.exe'
if (-not (Test-Path $gitExe)) {
    $a = Get-GitHubAsset -Repo 'git-for-windows/git' -Version (Get-Version 'git') -Pattern '^Git-[\d\.]+-64-bit\.exe$'
    $exe = Save-Download $a.Url $a.Name
    Invoke-Installer $exe @('/VERYSILENT', '/NORESTART', '/NOCANCEL', '/SP-', '/SUPPRESSMSGBOXES', '/NOICONS')
    Write-Step "  installed Git $($a.Tag)"
} else { Write-Step '  Git already installed' }
Add-MachinePath (Join-Path $env:ProgramFiles 'Git\cmd')

# ── Terraform, Packer ─────────────────────────────────────────────────────
Install-HashiCorpTool 'terraform'
Install-HashiCorpTool 'packer'
Add-MachinePath $hashiBin

# ── VS Code (system installer) ────────────────────────────────────────────
$codeExe = Join-Path $env:ProgramFiles 'Microsoft VS Code\Code.exe'
if (-not (Test-Path $codeExe)) {
    $v = Get-Version 'vscode'
    $exe = Save-Download "https://update.code.visualstudio.com/$v/win32-x64/stable" 'VSCodeSetup-x64.exe'
    Invoke-Installer $exe @('/VERYSILENT', '/NORESTART', '/MERGETASKS=!runcode,addtopath,addcontextmenufiles,addcontextmenufolders')
    Write-Step "  installed VS Code ($v)"
} else { Write-Step '  VS Code already installed' }

# ── Visual C++ runtime (KeePassXC needs it; a fresh Windows may not have it) ─
$vc = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\VisualStudio\14.0\VC\Runtimes\x64' -ErrorAction SilentlyContinue
if (-not $vc -or $vc.Installed -ne 1) {
    $exe = Save-Download 'https://aka.ms/vs/17/release/vc_redist.x64.exe' 'vc_redist.x64.exe'
    # 1638: a newer version is already installed.
    Invoke-Installer $exe @('/install', '/quiet', '/norestart') -OkCodes @(0, 1638, 3010)
    Write-Step '  installed Visual C++ runtime (x64)'
} else { Write-Step "  Visual C++ runtime already installed ($($vc.Version))" }

# ── KeePassXC ─────────────────────────────────────────────────────────────
$kpExe = Join-Path $env:ProgramFiles 'KeePassXC\KeePassXC.exe'
if (-not (Test-Path $kpExe)) {
    $a = Get-GitHubAsset -Repo 'keepassxreboot/keepassxc' -Version (Get-Version 'keepassxc') -Pattern '^KeePassXC-[\d\.]+-(Win64|x64)\.msi$'   # x64 since 2.8.0, Win64 before
    $msi = Save-Download $a.Url $a.Name
    Invoke-Installer msiexec.exe @('/i', "`"$msi`"", '/qn', '/norestart', 'AUTOSTARTPROGRAM=0', 'LAUNCHAPPONEXIT=0')
    Write-Step "  installed KeePassXC $($a.Tag)"
} else { Write-Step '  KeePassXC already installed' }

# ── Windows ADK Deployment Tools (oscdimg.exe) ────────────────────────────
$oscdimgDir = "${env:ProgramFiles(x86)}\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\amd64\Oscdimg"
if (-not (Test-Path (Join-Path $oscdimgDir 'oscdimg.exe'))) {
    # Microsoft's link for the latest ADK (learn.microsoft.com/windows-hardware/get-started/adk-install).
    $exe = Save-Download 'https://go.microsoft.com/fwlink/?linkid=2289980' 'adksetup.exe'
    Invoke-Installer $exe @('/quiet', '/norestart', '/ceip', 'off', '/features', 'OptionId.DeploymentTools')
    if (-not (Test-Path (Join-Path $oscdimgDir 'oscdimg.exe'))) { throw 'ADK installed but oscdimg.exe is missing.' }
    Write-Step '  installed ADK Deployment Tools'
} else { Write-Step '  ADK Deployment Tools already installed' }
Add-MachinePath $oscdimgDir

# ── RSAT ──────────────────────────────────────────────────────────────────
# Installed from Windows Update, roughly 5-20 minutes per tool. 'standard' is what
# the lab uses; 'all' is every RSAT tool Windows offers (about 20, 3+ hours).
$rsatStandard = @(
    'Rsat.ActiveDirectory.DS-LDS.Tools~~~~0.0.1.0'   # AD users and computers, AD PowerShell, ADAC
    'Rsat.Dns.Tools~~~~0.0.1.0'
    'Rsat.GroupPolicy.Management.Tools~~~~0.0.1.0'
    'Rsat.ServerManager.Tools~~~~0.0.1.0'
)
$rsatWanted = if (@($Rsat) -contains 'all') {
    @(Get-WindowsCapability -Online -Name 'Rsat.*' | ForEach-Object Name)
} else {
    @($Rsat | ForEach-Object { if ($_ -eq 'standard') { $rsatStandard } else { $_ } } | Select-Object -Unique)
}
$rsatRestart = $false
foreach ($cap in $rsatWanted) {
    $state = (Get-WindowsCapability -Online -Name $cap).State
    if ($state -eq 'Installed') { Write-Step "  $cap already installed" }
    elseif ($state -eq 'InstallPending') { Write-Step "  $cap installed; restart Windows to finish"; $rsatRestart = $true }
    else {
        $r = Add-WindowsCapability -Online -Name $cap
        if ($r.RestartNeeded) { $rsatRestart = $true }
        Write-Step "  installed $cap$(if ($r.RestartNeeded) { ' (restart Windows to finish)' })"
    }
}
if ($rsatRestart) { Write-Step '  RSAT: restart Windows to finish installing.' }

# ── PowerShell 7 modules (AllUsers) ───────────────────────────────────────
$moduleScript = @'
$ErrorActionPreference = 'Stop'
# On a profile that has never used PSResourceGet, its repository store doesn't
# exist yet and Set-PSResourceRepository fails ("Loading repository store
# failed"). Create the folder, let Get- initialise the store, then register or
# trust PSGallery as needed.
if ($env:LOCALAPPDATA) { New-Item -ItemType Directory -Path (Join-Path $env:LOCALAPPDATA 'PSResourceGet') -Force | Out-Null }
$gallery = Get-PSResourceRepository -Name PSGallery -ErrorAction SilentlyContinue
if (-not $gallery) { Register-PSResourceRepository -PSGallery -Trusted }
elseif (-not $gallery.Trusted) { Set-PSResourceRepository -Name PSGallery -Trusted }
foreach ($m in 'powershell-yaml', 'Microsoft.PowerShell.SecretManagement', 'SecretManagement.KeePass') {
    if (-not (Get-InstalledPSResource -Name $m -Scope AllUsers -ErrorAction SilentlyContinue)) {
        Install-PSResource -Name $m -Scope AllUsers -TrustRepository
        Write-Output ('installed ' + $m)
    } else { Write-Output ($m + ' already installed') }
}
'@
# Run from a file: Windows PowerShell 5.1 does not escape embedded quotes when
# passing -Command to a native exe, which would mangle the script.
$moduleFile = Join-Path $work 'install-modules.ps1'
Set-Content -Path $moduleFile -Value $moduleScript -Encoding UTF8
$prevEap = $ErrorActionPreference; $ErrorActionPreference = 'Continue'   # 5.1: stderr must not become terminating
try { $out = & $pwsh -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $moduleFile 2>&1 } finally { $ErrorActionPreference = $prevEap }
if ($LASTEXITCODE -ne 0) { throw "PowerShell module install failed: $($out -join ' ')" }
$out | ForEach-Object { Write-Step "  $_" }

# ── Folders the pipeline expects ──────────────────────────────────────────
foreach ($d in 'C:\MidCoastLab', 'C:\MidCoastLab\state', 'C:\ProgramData\MidCoastLab\Logs\Orchestration') {
    New-Item -ItemType Directory -Path $d -Force | Out-Null
}
# Restrict C:\MidCoastLab (Terraform state, KeePass vault) BEFORE anything lands in
# it: SYSTEM and Administrators, plus SG-ROLE-DomainAdmins once domain-joined
# (granted at handover; UAC filters Administrators from non-elevated tokens).
# On the hand-build the installing account is granted too: UAC strips
# Administrators from a non-elevated token, and that account needs to clone the
# repo, save the vault and write Terraform state without "Run as administrator".
$grants = @('*S-1-5-18:(OI)(CI)F', '*S-1-5-32-544:(OI)(CI)F')
$me = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
if ($me -ne 'S-1-5-18') { $grants += "*${me}:(OI)(CI)F" }
# Root only, then everything below reset to inherit it (a single /T pass can leave
# children with an empty ACL).
$aclOut = & icacls.exe 'C:\MidCoastLab' /inheritance:r /grant:r @grants /Q 2>&1
if ($LASTEXITCODE -ne 0) { throw "icacls on C:\MidCoastLab failed: $aclOut" }
if (Get-ChildItem -Path 'C:\MidCoastLab' -Force -ErrorAction SilentlyContinue) {
    $aclOut = & icacls.exe 'C:\MidCoastLab\*' /reset /T /C /Q 2>&1
    if ($LASTEXITCODE -ne 0) { throw "icacls /reset under C:\MidCoastLab failed: $aclOut" }
}

Remove-Item -Path $work -Recurse -Force -ErrorAction SilentlyContinue
Write-Step 'MGMT toolchain complete'
