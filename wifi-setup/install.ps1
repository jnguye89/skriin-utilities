#Requires -RunAsAdministrator
<#
.SYNOPSIS
  Installs the Skriin WiFi Setup Windows Service and registers it to run at boot.

.USAGE
  powershell -ExecutionPolicy Bypass -File install.ps1
#>

$ErrorActionPreference = "Stop"

$ServiceName  = "SkriinWifiSetup"
$DisplayName  = "Skriin WiFi Setup"
$Description  = "Serves the kiosk's on-screen WiFi network picker and joins the chosen network."
$InstallDir   = "C:\Program Files\Skriin\WifiSetup"
$ExeName      = "WifiSetupService.exe"
$DataDir      = "C:\ProgramData\Skriin"

Write-Host "=== Skriin WiFi Setup Installer ===" -ForegroundColor Cyan

# -- 1. Create directories -------------------------------------------------
New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
New-Item -ItemType Directory -Force -Path $DataDir    | Out-Null
Write-Host "[OK] Directories created"

# -- 2. Copy files ---------------------------------------------------------
$src = Join-Path $PSScriptRoot "WifiSetupService\publish\win-x64"
if (-not (Test-Path $src)) {
    Write-Host "Build output not found at $src" -ForegroundColor Red
    Write-Host "Run first:  dotnet publish WifiSetupService -c Release -r win-x64 --self-contained"
    exit 1
}
Copy-Item "$src\*" $InstallDir -Recurse -Force
Write-Host "[OK] Files copied to $InstallDir"

# -- 3. Enable Location Services system-wide --------------------------------
# netsh wlan (used internally by WifiHelper to read back SSID/state after
# joining a network) refuses to return WLAN interface info at all -
# "Access is denied" (error 5) - unless Location Services is turned on.
# This device ships to end customers with no technical access, so this
# can never be a manual step: force it on here instead of assuming it's
# already enabled.
$locationPolicyKey = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\LocationAndSensors"
New-Item -Path $locationPolicyKey -Force | Out-Null
Set-ItemProperty -Path $locationPolicyKey -Name "DisableLocation" -Type DWord -Value 0

$consentKey = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\location"
New-Item -Path $consentKey -Force | Out-Null
Set-ItemProperty -Path $consentKey -Name "Value" -Type String -Value "Allow"

# The master "Location services" switch (Settings -> Privacy & security ->
# Location) is a separate gate from the app-consent key above, and netsh
# wlan's per-network scan (mode=bssid, needed to list nearby SSIDs) checks
# it too - confirmed on real hardware: without this, "show interfaces"
# works but "show networks mode=bssid" still refuses with access denied.
$masterSwitchKey = "HKLM:\SYSTEM\CurrentControlSet\Services\lfsvc\Service\Configuration"
New-Item -Path $masterSwitchKey -Force | Out-Null
Set-ItemProperty -Path $masterSwitchKey -Name "Status" -Type DWord -Value 1

Set-Service -Name lfsvc -StartupType Automatic -ErrorAction SilentlyContinue
Start-Service -Name lfsvc -ErrorAction SilentlyContinue
Write-Host "[OK] Location Services enabled (required for netsh wlan)"

# -- 4. Remove existing service if present ---------------------------------
if (Get-Service -Name $ServiceName -ErrorAction SilentlyContinue) {
    Stop-Service -Name $ServiceName -Force -ErrorAction SilentlyContinue
    sc.exe delete $ServiceName | Out-Null
    Start-Sleep -Seconds 2
    Write-Host "[OK] Old service removed"
}

# -- 5. Register the service -----------------------------------------------
$exePath = Join-Path $InstallDir $ExeName
New-Service `
    -Name        $ServiceName `
    -DisplayName $DisplayName `
    -Description $Description `
    -BinaryPathName $exePath `
    -StartupType Automatic | Out-Null

# Grant LocalSystem (the service account) rights to the data dir
$acl = Get-Acl $DataDir
$rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
    "SYSTEM", "FullControl", "ContainerInherit,ObjectInherit", "None", "Allow")
$acl.SetAccessRule($rule)
Set-Acl $DataDir $acl

Write-Host "[OK] Service registered: $ServiceName"

# -- 6. Start the service --------------------------------------------------
Start-Service -Name $ServiceName
Write-Host "[OK] Service started" -ForegroundColor Green

Write-Host ""
Write-Host "Installation complete." -ForegroundColor Green
Write-Host "The service now serves the kiosk launcher at http://127.0.0.1:5757/"
Write-Host "Point Edge --kiosk at that URL (see kiosk-deployment-package/technician-config.json)."
