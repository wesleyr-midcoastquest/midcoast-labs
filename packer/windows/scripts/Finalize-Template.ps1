<#
.SYNOPSIS
    Packer provisioner, last step: clean up, enable Cloudbase-Init, sysprep /generalize.

.DESCRIPTION
    Checks the staged files are there, records template provenance, removes
    per-user packages that make sysprep fail, refuses a BitLocker-encrypted
    image, cleans temp files and the component store, forgets the build VM's
    DHCP lease (so clones ask for a fresh one), then runs sysprep /generalize
    /oobe /quit, up to three times, removing a package sysprep names as the
    blocker between tries. /quit keeps this WinRM session alive; Packer then
    stops the VM and converts it to a template.
#>
$ErrorActionPreference = 'Stop'

foreach ($f in @(
    'C:\Program Files\Cloudbase Solutions\Cloudbase-Init\conf\cloudbase-init.conf',
    'C:\Program Files\Cloudbase Solutions\Cloudbase-Init\conf\cloudbase-init-unattend.conf',
    'C:\Program Files\Cloudbase Solutions\Cloudbase-Init\LocalScripts\Initialize-LabRemoting.ps1',
    'C:\Windows\Panther\unattend-midcoast.xml')) {
    if (-not (Test-Path $f)) { throw "Missing staged file: $f" }
}

# Cloudbase-Init runs on clones, not on the template.
Set-Service -Name cloudbase-init -StartupType Automatic

# Template provenance (bootstrap adds deployment metadata to the same key).
if (-not (Test-Path 'HKLM:\SOFTWARE\MidCoastLab')) { New-Item -Path 'HKLM:\SOFTWARE\MidCoastLab' | Out-Null }
Set-ItemProperty -Path 'HKLM:\SOFTWARE\MidCoastLab' -Name TemplateBuiltUtc -Value (Get-Date).ToUniversalTime().ToString('o')
$pwshExe = Join-Path $env:ProgramFiles 'PowerShell\7\pwsh.exe'
if (-not (Test-Path $pwshExe)) { throw "PowerShell 7 not found at $pwshExe." }
Set-ItemProperty -Path 'HKLM:\SOFTWARE\MidCoastLab' -Name TemplatePwsh -Value (Get-Item $pwshExe).VersionInfo.ProductVersion

# Sysprep fails if an app is installed for a user but not provisioned for all
# users (0x80073cf2). It happens on Server too: Edge updates itself during the
# build and registers Microsoft.MicrosoftEdge.Stable for the build account.
# Stop Edge's updater so it can't do it again, then remove such packages.
foreach ($svc in 'edgeupdate', 'edgeupdatem', 'MicrosoftEdgeElevationService') {
    Get-Service -Name $svc -ErrorAction SilentlyContinue | Stop-Service -Force -ErrorAction SilentlyContinue
}
Get-ScheduledTask -TaskName 'MicrosoftEdgeUpdate*' -ErrorAction SilentlyContinue | Disable-ScheduledTask -ErrorAction SilentlyContinue | Out-Null

function Remove-LabUserOnlyPackage([string] $Name) {
    # Remove every installed copy of package $Name, for all users and the current one.
    foreach ($pkg in @(Get-AppxPackage -AllUsers -Name $Name -ErrorAction SilentlyContinue)) {
        Write-Host "Removing per-user package $($pkg.PackageFullName)"
        try { Remove-AppxPackage -Package $pkg.PackageFullName -AllUsers -ErrorAction Stop }
        catch {
            try { Remove-AppxPackage -Package $pkg.PackageFullName -ErrorAction Stop }
            catch { Write-Warning "Couldn't remove $($pkg.PackageFullName): $($_.Exception.Message)" }
        }
    }
}
$provisioned = @(Get-AppxProvisionedPackage -Online | ForEach-Object DisplayName)
Get-AppxPackage -AllUsers |
    Where-Object { -not $_.IsFramework -and $provisioned -notcontains $_.Name -and $_.SignatureKind -ne 'System' } |
    ForEach-Object { Remove-LabUserOnlyPackage $_.Name }

# A template must never be encrypted (clones couldn't unlock it).
$vol = Get-CimInstance -Namespace 'root\CIMV2\Security\MicrosoftVolumeEncryption' -ClassName Win32_EncryptableVolume -Filter "DriveLetter='C:'" -ErrorAction SilentlyContinue
if ($vol -and $vol.ProtectionStatus -ne 0) { throw 'C: is BitLocker-protected; the template would be unusable. Rebuild after checking PreventDeviceEncryption.' }
if ($vol) {
    $conv = Invoke-CimMethod -InputObject $vol -MethodName GetConversionStatus
    if ($conv.ConversionStatus -ne 0) { throw "C: encryption conversion status is $($conv.ConversionStatus), not FullyDecrypted." }
}

Write-Host 'Cleaning temp files and the component store...'
Remove-Item -Path "$env:TEMP\*", 'C:\Windows\Temp\*' -Recurse -Force -ErrorAction SilentlyContinue
Start-Process -FilePath dism.exe -Wait -NoNewWindow -ArgumentList '/Online', '/Cleanup-Image', '/StartComponentCleanup', '/ResetBase'

# Forget the build VM's DHCP lease. Sysprep keeps it, so every clone would boot
# believing it holds the build VM's address and ask to keep it (INIT-REBOOT);
# a non-authoritative DHCP server stays silent and Windows keeps the address,
# so two clones end up on the same IP. Without a cached lease, clones ask for
# a fresh one. (Only the registry record goes: this WinRM session stays up.)
Get-ChildItem 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces' | ForEach-Object {
    foreach ($v in 'DhcpIPAddress', 'DhcpSubnetMask', 'DhcpServer', 'DhcpDefaultGateway', 'DhcpNameServer',
                   'DhcpDomain', 'Lease', 'LeaseObtainedTime', 'LeaseTerminatesTime', 'T1', 'T2', 'DhcpClassIdBin') {
        Remove-ItemProperty -Path $_.PSPath -Name $v -ErrorAction SilentlyContinue
    }
}
Write-Host 'Cleared cached DHCP lease records.'

# Sysprep, up to three tries: if it names a package that is "installed for a
# user, but not provisioned for all users", remove that package and retry.
$stateKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Setup\State'
$errLog   = "$env:WINDIR\System32\Sysprep\Panther\setuperr.log"
for ($try = 1; $try -le 3; $try++) {
    $seen = if (Test-Path $errLog) { @(Get-Content $errLog).Count } else { 0 }
    Write-Host "Running sysprep /generalize (attempt $try)..."
    & "$env:WINDIR\System32\Sysprep\Sysprep.exe" /generalize /oobe /quit /quiet /mode:vm /unattend:C:\Windows\Panther\unattend-midcoast.xml

    $deadline = (Get-Date).AddMinutes(20)
    $state = $null
    while ((Get-Date) -lt $deadline) {
        $state = (Get-ItemProperty -Path $stateKey).ImageState
        if ($state -eq 'IMAGE_STATE_GENERALIZE_RESEAL_TO_OOBE') { break }
        # Sysprep has exited without generalizing: stop waiting.
        if (-not (Get-Process -Name sysprep -ErrorAction SilentlyContinue)) { Start-Sleep -Seconds 5; $state = (Get-ItemProperty -Path $stateKey).ImageState; break }
        Start-Sleep -Seconds 10
    }
    if ($state -eq 'IMAGE_STATE_GENERALIZE_RESEAL_TO_OOBE') { Write-Host 'Image generalized.'; exit 0 }   # exit 0: Packer checks the exit code

    $new = if (Test-Path $errLog) { @(Get-Content $errLog | Select-Object -Skip $seen) } else { @() }
    $new | Select-Object -Last 40 | ForEach-Object { Write-Host $_ }
    $blockers = @($new | ForEach-Object { if ($_ -match 'Package (\S+?)_\S+ was installed for a user, but not provisioned') { $Matches[1] } } | Sort-Object -Unique)
    if ($blockers.Count -eq 0 -or $try -eq 3) { throw "Sysprep did not finish (ImageState = $state)." }
    foreach ($b in $blockers) { Remove-LabUserOnlyPackage $b }
}
