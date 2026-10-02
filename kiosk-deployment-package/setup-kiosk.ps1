# setup-kiosk.ps1
# Configure a Windows 11 Pro single-app kiosk using Assigned Access + Edge kiosk mode.
# Run as Administrator.

#Requires -RunAsAdministrator

[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [string]$KioskUrl,

  [string]$DisplayName = "Skriin AI TV",
  [string]$BreakoutSequence = "Ctrl+Alt+Shift+S",
  [string]$CameraSiteUrl = "https://skriin.com/",

  [string]$OwnerAdminUserName = "skriinadmin",
  [string]$OwnerAdminFullName = "Skriin Admin",
  [string]$OwnerAdminPasswordPlainText,
  [ValidateSet("ShowAdminTile", "RequireTypedCredentials")]
  [string]$OwnerAdminLogonWorkflow = "ShowAdminTile",

  [ValidateRange(0, 23)]
  [int]$ActiveHoursStart = 6,
  [ValidateRange(0, 23)]
  [int]$ActiveHoursEnd = 23,
  [ValidateRange(0, 23)]
  [int]$ScheduledInstallHour = 3,

  [string]$LogonBackgroundImagePath,

  [switch]$ConfigureScancodeHardening,
  [switch]$RebootAfterApply
)

$ErrorActionPreference = "Stop"

# Fail fast before changing anything: the Assigned Access step at the end of
# this script needs LocalSystem (see invoke-technician-onetouch.ps1, which
# relaunches itself as SYSTEM automatically). Running this as a normal
# Administrator used to apply every other setting and then die on the very
# last step, leaving the device on its previous kiosk URL.
if (-not [System.Security.Principal.WindowsIdentity]::GetCurrent().IsSystem) {
  throw "setup-kiosk.ps1 must run as SYSTEM (the MDM_AssignedAccess WMI provider only exposes 'Configuration' to LocalSystem). Run invoke-technician-onetouch.ps1 instead - it relaunches itself as SYSTEM."
}

function Ensure-RegistryKey {
  param(
    [Parameter(Mandatory = $true)][string]$Path
  )

  if (-not (Test-Path -Path $Path)) {
    New-Item -Path $Path -Force | Out-Null
  }
}

function Set-PolicyDword {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][string]$Name,
    [Parameter(Mandatory = $true)][int]$Value
  )

  Ensure-RegistryKey -Path $Path
  Set-ItemProperty -Path $Path -Name $Name -Type DWord -Value $Value
}

function Get-RegistryValueBackupRecord {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][string]$Name
  )

  $record = [ordered]@{
    Path   = $Path
    Name   = $Name
    Exists = $false
    Value  = $null
  }

  if (Test-Path -Path $Path) {
    try {
      $value = Get-ItemPropertyValue -Path $Path -Name $Name -ErrorAction Stop
      $record.Exists = $true
      $record.Value = $value
    }
    catch {
      $record.Exists = $false
    }
  }

  return [pscustomobject]$record
}

function Backup-AccountPickerPolicy {
  param(
    [Parameter(Mandatory = $true)][string]$BackupPath,
    [Parameter(Mandatory = $true)][string]$SystemPolicyPath,
    [Parameter(Mandatory = $true)][string]$UserListPath
  )

  if (Test-Path -Path $BackupPath) {
    Write-Host "Account picker policy backup already exists: $BackupPath"
    return
  }

  $backup = [ordered]@{
    CreatedUtc         = [DateTime]::UtcNow.ToString("o")
    SystemPolicyValues = @(
      Get-RegistryValueBackupRecord -Path $SystemPolicyPath -Name "DontDisplayLastUserName"
      Get-RegistryValueBackupRecord -Path $SystemPolicyPath -Name "DontDisplayLockedUserId"
    )
    UserListValues     = @()
  }

  $localUsers = Get-LocalUser -ErrorAction Stop | Sort-Object Name
  foreach ($user in $localUsers) {
    $backup.UserListValues += Get-RegistryValueBackupRecord -Path $UserListPath -Name $user.Name
  }

  $backup | ConvertTo-Json -Depth 10 | Set-Content -Path $BackupPath -Encoding UTF8
  Write-Host "Saved account picker policy backup: $BackupPath"
}

function Set-OwnerAdminLogonWorkflowPolicy {
  param(
    [Parameter(Mandatory = $true)][string]$SystemPolicyPath,
    [Parameter(Mandatory = $true)]
    [ValidateSet("ShowAdminTile", "RequireTypedCredentials")]
    [string]$Workflow
  )

  if ($Workflow -eq "RequireTypedCredentials") {
    Write-Host "Configuring owner admin logon workflow: require typed credentials after breakout."
    Write-Warning "DontDisplayLastUserName can affect Assigned Access autologon on some Windows 11 Pro builds. Validate reboot behavior on target hardware."
    Set-PolicyDword -Path $SystemPolicyPath -Name "DontDisplayLastUserName" -Value 1
    Set-PolicyDword -Path $SystemPolicyPath -Name "DontDisplayLockedUserId" -Value 3
    return
  }

  Write-Host "Configuring owner admin logon workflow: show owner admin tile when Windows displays account tiles."
  if (Test-Path -Path $SystemPolicyPath) {
    Remove-ItemProperty -Path $SystemPolicyPath -Name "DontDisplayLastUserName" -ErrorAction SilentlyContinue
    Remove-ItemProperty -Path $SystemPolicyPath -Name "DontDisplayLockedUserId" -ErrorAction SilentlyContinue
  }
}

function Get-EnabledLocalUsers {
  Get-LocalUser -ErrorAction Stop |
  Where-Object { $_.Enabled } |
  Sort-Object Name
}

function Get-LocalAdministratorSids {
  try {
    return @(Get-LocalGroupMember -Group "Administrators" -ErrorAction Stop | ForEach-Object { $_.SID.Value })
  }
  catch {
    Write-Warning "Could not enumerate local Administrators group. Skipping standard-user inference."
    throw
  }
}

function Get-EnabledStandardLocalUsers {
  param(
    [Parameter(Mandatory = $true)]
    [AllowEmptyCollection()]
    [object[]]$Users
  )

  try {
    $adminSids = Get-LocalAdministratorSids
  }
  catch {
    return @()
  }

  return @($Users | Where-Object { $adminSids -notcontains $_.SID.Value } | Sort-Object Name)
}

function Resolve-AssignedAccessKioskUserName {
  param(
    [Parameter(Mandatory = $true)]
    [AllowEmptyCollection()]
    [object[]]$PreAssignedAccessUsers,
    [Parameter(Mandatory = $true)]
    [AllowEmptyCollection()]
    [object[]]$PostAssignedAccessUsers,
    [Parameter(Mandatory = $true)][string]$PersistPath
  )

  $preUserNames = @($PreAssignedAccessUsers | ForEach-Object { $_.Name })
  $newUsers = @($PostAssignedAccessUsers | Where-Object { $preUserNames -notcontains $_.Name })
  $newStandardUsers = Get-EnabledStandardLocalUsers -Users $newUsers

  if ($newStandardUsers.Count -eq 1) {
    $kioskUserName = [string]$newStandardUsers[0].Name
    $kioskUserName | Set-Content -Path $PersistPath -Encoding ASCII
    Write-Host "Inferred Assigned Access kiosk account: $kioskUserName"
    return $kioskUserName
  }

  if (Test-Path -Path $PersistPath) {
    $persistedUserName = (Get-Content -Path $PersistPath -Raw).Trim()
    if (-not [string]::IsNullOrWhiteSpace($persistedUserName)) {
      $persistedUser = $PostAssignedAccessUsers | Where-Object { $_.Name -eq $persistedUserName -and $_.Enabled } | Select-Object -First 1
      if ($null -ne $persistedUser) {
        Write-Host "Using persisted Assigned Access kiosk account: $persistedUserName"
        return $persistedUserName
      }
    }
  }

  $standardUsers = Get-EnabledStandardLocalUsers -Users $PostAssignedAccessUsers
  if ($standardUsers.Count -eq 1) {
    $kioskUserName = [string]$standardUsers[0].Name
    $kioskUserName | Set-Content -Path $PersistPath -Encoding ASCII
    Write-Host "Inferred sole enabled standard local user as kiosk account: $kioskUserName"
    return $kioskUserName
  }

  Write-Warning "Could not safely infer the Assigned Access kiosk account. Assigned Access autologon policy was preserved, but bulk account hiding was skipped."
  return $null
}

function Hide-EnabledLocalUsersExcept {
  param(
    [Parameter(Mandatory = $true)]
    [AllowEmptyCollection()]
    [object[]]$Users,
    [Parameter(Mandatory = $true)]
    [AllowEmptyCollection()]
    [string[]]$VisibleUserNames,
    [Parameter(Mandatory = $true)][string]$UserListPath
  )

  Ensure-RegistryKey -Path $UserListPath

  foreach ($user in $Users) {
    if ($VisibleUserNames -contains $user.Name) {
      Write-Host "Leaving local account visible on sign-in screen: $($user.Name)"
      Remove-ItemProperty -Path $UserListPath -Name $user.Name -ErrorAction SilentlyContinue
      continue
    }

    Write-Host "Hiding local account from sign-in picker: $($user.Name)"
    Set-ItemProperty -Path $UserListPath -Name $user.Name -Type DWord -Value 0
  }
}

function Resolve-LogonBackgroundImage {
  param(
    [string]$Path
  )

  if ([string]::IsNullOrWhiteSpace($Path)) {
    return $null
  }

  $resolved = Resolve-Path -Path $Path -ErrorAction Stop
  $sourcePath = $resolved.ProviderPath
  $extension = [System.IO.Path]::GetExtension($sourcePath).ToLowerInvariant()
  $allowedExtensions = @(".jpg", ".jpeg", ".png")

  if ($allowedExtensions -notcontains $extension) {
    throw "Logon background image must be a .jpg, .jpeg, or .png file: $sourcePath"
  }

  return $sourcePath
}

function Set-LogonBackgroundImage {
  param(
    [Parameter(Mandatory = $true)][string]$SourcePath,
    [Parameter(Mandatory = $true)][string]$AssetDirectory
  )

  $extension = [System.IO.Path]::GetExtension($SourcePath).ToLowerInvariant()
  New-Item -Path $AssetDirectory -ItemType Directory -Force | Out-Null

  $stagedPath = Join-Path -Path $AssetDirectory -ChildPath "logon-background$extension"
  Copy-Item -Path $SourcePath -Destination $stagedPath -Force

  $personalizationPolicy = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Personalization"
  Ensure-RegistryKey -Path $personalizationPolicy
  Set-ItemProperty -Path $personalizationPolicy -Name "LockScreenImage" -Type String -Value $stagedPath
  Set-ItemProperty -Path $personalizationPolicy -Name "NoChangingLockScreen" -Type DWord -Value 1

  $personalizationCsp = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\PersonalizationCSP"
  Ensure-RegistryKey -Path $personalizationCsp
  Set-ItemProperty -Path $personalizationCsp -Name "LockScreenImagePath" -Type String -Value $stagedPath
  Set-ItemProperty -Path $personalizationCsp -Name "LockScreenImageUrl" -Type String -Value $stagedPath
  Set-ItemProperty -Path $personalizationCsp -Name "LockScreenImageStatus" -Type DWord -Value 1

  Write-Host "Configured lock/logon background image: $stagedPath"
  Write-Host "Windows 11 Pro lock/logon image behavior must be verified on target hardware."
}

function Ensure-OwnerAdminAccount {
  param(
    [Parameter(Mandatory = $true)][string]$UserName,
    [Parameter(Mandatory = $true)][string]$FullName,
    [Parameter(Mandatory = $true)][string]$Password
  )

  $securePassword = ConvertTo-SecureString -String $Password -AsPlainText -Force
  $existingUser = Get-LocalUser -Name $UserName -ErrorAction SilentlyContinue

  if ($null -eq $existingUser) {
    Write-Host "Creating owner admin account '$UserName'..."
    New-LocalUser -Name $UserName -Password $securePassword -FullName $FullName -PasswordNeverExpires | Out-Null
  }
  else {
    Write-Host "Updating password and display name for existing owner admin account '$UserName'..."
    $existingUser | Set-LocalUser -Password $securePassword -FullName $FullName
  }

  $adminMembership = Get-LocalGroupMember -Group "Administrators" -ErrorAction SilentlyContinue |
  Where-Object { $_.Name -match "\\$UserName$" }

  if ($null -eq $adminMembership) {
    Add-LocalGroupMember -Group "Administrators" -Member $UserName
  }

  Write-Host "Owner admin account '$UserName' remains usable by typing credentials directly."
}

function Set-BootExperience {
  Write-Host "Applying best-effort quiet boot settings..."

  try {
    bcdedit /set { current } bootux disabled | Out-Null
  }
  catch {
    Write-Warning "Could not set bootux disabled. Continuing."
  }

  try {
    bcdedit /set { current } quietboot yes | Out-Null
  }
  catch {
    Write-Warning "Could not set quietboot yes. Continuing."
  }

  Write-Host "Boot spinner/logo suppression is hardware and edition dependent on Windows 11 Pro."
}

function Set-ScancodeHardening {
  # Disables only dedicated OS navigation keys. Do not disable Ctrl/Alt to preserve breakout sequence.
  # Mappings disabled: Left Win (E05B), Right Win (E05C), Application/Menu key (E05D).
  [byte[]]$scancodeMap = @(
    0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00,
    0x04, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x5B, 0xE0,
    0x00, 0x00, 0x5C, 0xE0,
    0x00, 0x00, 0x5D, 0xE0,
    0x00, 0x00, 0x00, 0x00
  )

  Ensure-RegistryKey -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Keyboard Layout"
  Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Keyboard Layout" -Name "Scancode Map" -Type Binary -Value $scancodeMap
}

Write-Host "Configuring Windows 11 Assigned Access kiosk for: $KioskUrl"

# Confirm Edge exists.
$edgePath = "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe"
if (-not (Test-Path -Path $edgePath)) {
  $edgePath = "${env:ProgramFiles}\Microsoft\Edge\Application\msedge.exe"
}

if (-not (Test-Path -Path $edgePath)) {
  throw "Microsoft Edge was not found. Install Microsoft Edge Stable first."
}

$artifactDir = "C:\KioskSetup"
$assetDir = Join-Path -Path $artifactDir -ChildPath "Assets"
$accountPickerBackupPath = Join-Path -Path $artifactDir -ChildPath "account-picker-policy-backup.json"
$kioskUserPersistPath = Join-Path -Path $artifactDir -ChildPath "assigned-access-kiosk-user.txt"
$systemPolicy = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System"
$userListPath = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon\SpecialAccounts\UserList"
$resolvedLogonBackgroundImage = Resolve-LogonBackgroundImage -Path $LogonBackgroundImagePath

# Basic device power/display behavior.
Write-Host "Disabling lock screen, sleep, hibernate, monitor timeout, and screen saver..."

powercfg /change monitor-timeout-ac 0
powercfg /change monitor-timeout-dc 0
powercfg /change standby-timeout-ac 0
powercfg /change standby-timeout-dc 0
powercfg /change hibernate-timeout-ac 0
powercfg /change hibernate-timeout-dc 0
powercfg /hibernate off

Set-PolicyDword -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Personalization" -Name "NoLockScreen" -Value 1

if ($null -ne $resolvedLogonBackgroundImage) {
  Set-LogonBackgroundImage -SourcePath $resolvedLogonBackgroundImage -AssetDirectory $assetDir
}

# Disable screen saver for current user and default profile hive.
Ensure-RegistryKey -Path "HKCU:\Control Panel\Desktop"
Set-ItemProperty -Path "HKCU:\Control Panel\Desktop" -Name "ScreenSaveActive" -Value "0"
Set-ItemProperty -Path "HKCU:\Control Panel\Desktop" -Name "ScreenSaverIsSecure" -Value "0"

Ensure-RegistryKey -Path "Registry::HKEY_USERS\.DEFAULT\Control Panel\Desktop"
Set-ItemProperty -Path "Registry::HKEY_USERS\.DEFAULT\Control Panel\Desktop" -Name "ScreenSaveActive" -Value "0"
Set-ItemProperty -Path "Registry::HKEY_USERS\.DEFAULT\Control Panel\Desktop" -Name "ScreenSaverIsSecure" -Value "0"

# Edge policy hardening for kiosk reliability and no-prompt startup.
Write-Host "Applying Microsoft Edge policy defaults..."

$edgePolicy = "HKLM:\SOFTWARE\Policies\Microsoft\Edge"
Ensure-RegistryKey -Path $edgePolicy

Set-ItemProperty -Path $edgePolicy -Name "HideFirstRunExperience" -Type DWord -Value 1
Set-ItemProperty -Path $edgePolicy -Name "PromotionalTabsEnabled" -Type DWord -Value 0
Set-ItemProperty -Path $edgePolicy -Name "DefaultBrowserSettingEnabled" -Type DWord -Value 0
Set-ItemProperty -Path $edgePolicy -Name "BrowserSignin" -Type DWord -Value 0
Set-ItemProperty -Path $edgePolicy -Name "SyncDisabled" -Type DWord -Value 1
Set-ItemProperty -Path $edgePolicy -Name "UserFeedbackAllowed" -Type DWord -Value 0
Set-ItemProperty -Path $edgePolicy -Name "ShowRecommendationsEnabled" -Type DWord -Value 0
Set-ItemProperty -Path $edgePolicy -Name "PasswordManagerEnabled" -Type DWord -Value 0

# Reduce Edge update interruption UX. Updates should be handled by maintenance windows.
Set-ItemProperty -Path $edgePolicy -Name "RelaunchNotification" -Type DWord -Value 0

# Pre-authorize camera/microphone for the Skriin site so it works in the
# kiosk. Edge's --kiosk mode runs as an InPrivate-style session (see
# Microsoft's own kiosk-mode docs) that never persists a granted site
# permission, and there is no window chrome in a locked single-app kiosk
# for anyone to click "Allow" on a media prompt anyway - so without this,
# getUserMedia() calls just silently fail every time the kiosk (re)starts,
# even though the exact same site works fine in a normal (non-kiosk) Edge
# profile where a permission was granted and persisted once.
Write-Host "Pre-authorizing camera/microphone for $CameraSiteUrl..."
$cameraSiteUri = [Uri]$CameraSiteUrl
$sitePatterns = @(
  "$($cameraSiteUri.Scheme)://$($cameraSiteUri.Host)/",
  "$($cameraSiteUri.Scheme)://[*.]$($cameraSiteUri.Host)/"
)

$videoCaptureKey = "$edgePolicy\VideoCaptureAllowedUrls"
$audioCaptureKey = "$edgePolicy\AudioCaptureAllowedUrls"
Ensure-RegistryKey -Path $videoCaptureKey
Ensure-RegistryKey -Path $audioCaptureKey

for ($i = 0; $i -lt $sitePatterns.Count; $i++) {
  $index = $i + 1
  Set-ItemProperty -Path $videoCaptureKey -Name "$index" -Type String -Value $sitePatterns[$i]
  Set-ItemProperty -Path $audioCaptureKey -Name "$index" -Type String -Value $sitePatterns[$i]
}
Write-Host "[OK] Camera/microphone pre-authorized for $($cameraSiteUri.Host)"

# Block common Windows interruption surfaces.
Write-Host "Disabling common notification and interruption surfaces..."

$pushPolicy = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\CurrentVersion\PushNotifications"
Set-PolicyDword -Path $pushPolicy -Name "NoToastApplicationNotification" -Value 1

$explorerPolicy = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Explorer"
Set-PolicyDword -Path $explorerPolicy -Name "DisableNotificationCenter" -Value 1

Write-Host "Leaving Fast User Switching entry points available for owner breakout path..."
if (Test-Path -Path $systemPolicy) {
  Remove-ItemProperty -Path $systemPolicy -Name "HideFastUserSwitching" -ErrorAction SilentlyContinue
}

Set-PolicyDword -Path $systemPolicy -Name "DisableTaskMgr" -Value 1

# Reduce Windows Update disruption.
Write-Host "Configuring Windows Update to avoid automatic reboots..."

$wuPolicy = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate"
$auPolicy = "$wuPolicy\AU"

Ensure-RegistryKey -Path $wuPolicy
Ensure-RegistryKey -Path $auPolicy

Set-ItemProperty -Path $auPolicy -Name "NoAutoRebootWithLoggedOnUsers" -Type DWord -Value 1
Set-ItemProperty -Path $auPolicy -Name "AUOptions" -Type DWord -Value 4
Set-ItemProperty -Path $auPolicy -Name "ScheduledInstallDay" -Type DWord -Value 0
Set-ItemProperty -Path $auPolicy -Name "ScheduledInstallTime" -Type DWord -Value $ScheduledInstallHour
Set-ItemProperty -Path $wuPolicy -Name "SetActiveHours" -Type DWord -Value 1
Set-ItemProperty -Path $wuPolicy -Name "ActiveHoursStart" -Type DWord -Value $ActiveHoursStart
Set-ItemProperty -Path $wuPolicy -Name "ActiveHoursEnd" -Type DWord -Value $ActiveHoursEnd

Set-BootExperience

if ($PSBoundParameters.ContainsKey("OwnerAdminPasswordPlainText")) {
  Ensure-OwnerAdminAccount -UserName $OwnerAdminUserName -FullName $OwnerAdminFullName -Password $OwnerAdminPasswordPlainText
}
else {
  Write-Warning "Owner admin account was not changed because OwnerAdminPasswordPlainText was not provided."
}

if ($ConfigureScancodeHardening.IsPresent) {
  Write-Host "Applying optional scancode hardening (Win/App keys)..."
  Set-ScancodeHardening
}

New-Item -Path $artifactDir -ItemType Directory -Force | Out-Null
$preAssignedAccessUsers = @(Get-EnabledLocalUsers)
Backup-AccountPickerPolicy -BackupPath $accountPickerBackupPath -SystemPolicyPath $systemPolicy -UserListPath $userListPath
Set-OwnerAdminLogonWorkflowPolicy -SystemPolicyPath $systemPolicy -Workflow $OwnerAdminLogonWorkflow

# Assigned Access configuration.
Write-Host "Applying Assigned Access XML through MDM Bridge WMI..."

$profileId = [guid]::NewGuid().ToString("B").ToUpperInvariant()
$edgeArguments = "--kiosk $KioskUrl --edge-kiosk-type=fullscreen --no-first-run --kiosk-idle-timeout-minutes=0"

$assignedAccessXml = @"
<?xml version="1.0" encoding="utf-8"?>
<AssignedAccessConfiguration
  xmlns="http://schemas.microsoft.com/AssignedAccess/2017/config"
  xmlns:rs5="http://schemas.microsoft.com/AssignedAccess/201810/config"
  xmlns:v4="http://schemas.microsoft.com/AssignedAccess/2021/config"
  xmlns:v5="http://schemas.microsoft.com/AssignedAccess/2022/config">
  <Profiles>
    <Profile Id="$profileId" Name="$DisplayName">
      <KioskModeApp
        v4:ClassicAppPath="$edgePath"
        v4:ClassicAppArguments="$edgeArguments" />
      <v4:BreakoutSequence Key="$BreakoutSequence" />
    </Profile>
  </Profiles>
  <Configs>
    <Config>
      <AutoLogonAccount rs5:DisplayName="$DisplayName" />
      <DefaultProfile Id="$profileId" />
    </Config>
  </Configs>
</AssignedAccessConfiguration>
"@

New-Item -Path $artifactDir -ItemType Directory -Force | Out-Null
$xmlPath = Join-Path -Path $artifactDir -ChildPath "assigned-access.xml"
$assignedAccessXml | Set-Content -Path $xmlPath -Encoding UTF8

$namespaceName = "root\cimv2\mdm\dmmap"
$className = "MDM_AssignedAccess"
$assignedAccess = Get-CimInstance -Namespace $namespaceName -ClassName $className -ErrorAction Stop

$assignedAccess.Configuration = [System.Net.WebUtility]::HtmlEncode($assignedAccessXml)
Set-CimInstance -CimInstance $assignedAccess | Out-Null

$postAssignedAccessUsers = @(Get-EnabledLocalUsers)
$kioskUserName = Resolve-AssignedAccessKioskUserName -PreAssignedAccessUsers $preAssignedAccessUsers -PostAssignedAccessUsers $postAssignedAccessUsers -PersistPath $kioskUserPersistPath
if (-not [string]::IsNullOrWhiteSpace($kioskUserName)) {
  $visibleUserNames = @($kioskUserName)
  if ($OwnerAdminLogonWorkflow -eq "ShowAdminTile") {
    $visibleUserNames += $OwnerAdminUserName
  }

  Hide-EnabledLocalUsersExcept -Users $postAssignedAccessUsers -VisibleUserNames $visibleUserNames -UserListPath $userListPath
}

Write-Host ""
Write-Host "Assigned Access kiosk configuration applied successfully."
Write-Host "Saved XML: $xmlPath"
Write-Host "Kiosk URL: $KioskUrl"
Write-Host "Breakout sequence: $BreakoutSequence"
Write-Host "Update install window starts at local hour: $ScheduledInstallHour"
Write-Host "Active Hours: ${ActiveHoursStart}:00 to ${ActiveHoursEnd}:00"
Write-Host ""

if ($RebootAfterApply.IsPresent) {
  Write-Host "Rebooting in 5 seconds..."
  Start-Sleep -Seconds 5
  Restart-Computer -Force
}
else {
  Write-Host "Reboot recommended before validation testing."
}
