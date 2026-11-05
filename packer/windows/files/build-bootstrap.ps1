# build-bootstrap.ps1: runs once at first logon of the BUILD VM only.
# Installs the VirtIO guest tools (includes the QEMU guest agent Packer uses
# to find the VM's address) and opens WinRM/HTTPS for Packer.
$ErrorActionPreference = 'Stop'
Start-Transcript -Path C:\Windows\Temp\build-bootstrap.log -Append

Get-NetConnectionProfile | Set-NetConnectionProfile -NetworkCategory Private

# Windows client only: keep the image sysprep-safe and unencrypted.
#  - Store app auto-updates install per-user packages that make sysprep fail.
#  - Automatic device encryption would BitLocker every clone (TPM present).
# Registry keys: create only when missing. New-Item -Force on an existing key
# deletes and recreates it, which fails on protected keys such as
# Control\BitLocker ("Cannot delete a subkey tree") and would wipe its values.
$isClient = (Get-CimInstance -ClassName Win32_OperatingSystem).ProductType -eq 1
# These tweaks must never stop the build: the guest tools and WinRM below are
# what Packer waits for, and Finalize-Template refuses an encrypted image anyway.
if ($isClient) { try {
    if (-not (Test-Path 'HKLM:\SOFTWARE\Policies\Microsoft\WindowsStore')) { New-Item -Path 'HKLM:\SOFTWARE\Policies\Microsoft\WindowsStore' | Out-Null }
    Set-ItemProperty -Path 'HKLM:\SOFTWARE\Policies\Microsoft\WindowsStore' -Name AutoDownload -Value 2 -Type DWord
    if (-not (Test-Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent')) { New-Item -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent' | Out-Null }
    Set-ItemProperty -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent' -Name DisableWindowsConsumerFeatures -Value 1 -Type DWord
    if (-not (Test-Path 'HKLM:\SYSTEM\CurrentControlSet\Control\BitLocker')) { New-Item -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\BitLocker' | Out-Null }
    Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\BitLocker' -Name PreventDeviceEncryption -Value 1 -Type DWord
} catch { Write-Warning "Client image tweaks incomplete: $($_.Exception.Message)" } }

$guestTools = Get-PSDrive -PSProvider FileSystem |
    ForEach-Object { Join-Path $_.Root 'virtio-win-guest-tools.exe' } |
    Where-Object { Test-Path $_ } |
    Select-Object -First 1
if (-not $guestTools) { throw 'virtio-win-guest-tools.exe not found on any drive.' }
Start-Process -FilePath $guestTools -ArgumentList '/install', '/quiet', '/norestart' -Wait

# Memory ballooning needs the balloon driver (installed above) and its service,
# which reports guest memory to Proxmox. Make sure the service is there, and
# install it from the VirtIO CD if the guest tools didn't.
$balloon = Get-Service -Name BalloonService -ErrorAction SilentlyContinue
if (-not $balloon) {
    $osDir = if ($isClient) { 'w11' } else { '2k22' }
    $blnsvr = Get-PSDrive -PSProvider FileSystem |
        ForEach-Object { Join-Path $_.Root "Balloon\$osDir\amd64\blnsvr.exe" } |
        Where-Object { Test-Path $_ } |
        Select-Object -First 1
    if (-not $blnsvr) { throw "Balloon service missing and Balloon\$osDir\amd64\blnsvr.exe not found on the VirtIO CD." }
    $dest = Join-Path $env:ProgramFiles 'Balloon'
    New-Item -ItemType Directory -Path $dest -Force | Out-Null
    Copy-Item $blnsvr $dest -Force
    & (Join-Path $dest 'blnsvr.exe') -i
    $balloon = Get-Service -Name BalloonService -ErrorAction Stop
}
Set-Service -Name BalloonService -StartupType Automatic

# Build-only WinRM/HTTPS. Initialize-LabRemoting.ps1 removes all of this on
# each clone's first boot and replaces it with a locked-down listener.
Enable-PSRemoting -SkipNetworkProfileCheck -Force
Set-Service -Name WinRM -StartupType Automatic
$cert = New-SelfSignedCertificate -DnsName $env:COMPUTERNAME -CertStoreLocation Cert:\LocalMachine\My -FriendlyName 'Packer build WinRM'
Get-ChildItem WSMan:\localhost\Listener | Where-Object { $_.Keys -contains 'Transport=HTTPS' } | Remove-Item -Recurse -Force
New-Item -Path WSMan:\localhost\Listener -Transport HTTPS -Address * -CertificateThumbPrint $cert.Thumbprint -Force | Out-Null
Set-Item WSMan:\localhost\Service\Auth\Basic -Value $true
Set-Item WSMan:\localhost\MaxTimeoutms -Value 1800000
New-NetFirewallRule -Name 'WinRM-HTTPS-Build' -DisplayName 'WinRM HTTPS (Packer build)' `
    -Direction Inbound -Protocol TCP -LocalPort 5986 -Action Allow -Profile Any | Out-Null

Stop-Transcript
