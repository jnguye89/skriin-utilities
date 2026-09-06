# reset-kiosk.ps1
# Clears Assigned Access kiosk configuration and optionally reverts selected hardening values.
# Run as Administrator.

#Requires -RunAsAdministrator

[CmdletBinding()]
param(
	[switch]$RemoveScancodeHardening,
	[switch]$RemoveLogonBackgroundPolicy,
	[switch]$RestoreAccountPickerPolicy,
	[switch]$EnableTaskManager,
	[switch]$RebootAfterReset
)

$ErrorActionPreference = "Stop"

function Ensure-RegistryKey {
	param(
		[Parameter(Mandatory = $true)][string]$Path
	)

	if (-not (Test-Path -Path $Path)) {
		New-Item -Path $Path -Force | Out-Null
	}
}

function Restore-RegistryValueFromBackup {
	param(
		[Parameter(Mandatory = $true)]$Record
	)

	if ($Record.Exists) {
		Ensure-RegistryKey -Path ([string]$Record.Path)
		Set-ItemProperty -Path ([string]$Record.Path) -Name ([string]$Record.Name) -Value $Record.Value
	}
	elseif (Test-Path -Path ([string]$Record.Path)) {
		Remove-ItemProperty -Path ([string]$Record.Path) -Name ([string]$Record.Name) -ErrorAction SilentlyContinue
	}
}

Write-Host "Clearing Assigned Access configuration..."

$namespaceName = "root\cimv2\mdm\dmmap"
$className = "MDM_AssignedAccess"

$assignedAccess = Get-CimInstance -Namespace $namespaceName -ClassName $className -ErrorAction Stop
$assignedAccess.Configuration = $null
Set-CimInstance -CimInstance $assignedAccess | Out-Null

if ($RemoveScancodeHardening.IsPresent) {
	Write-Host "Removing Scancode Map hardening..."
	Remove-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Keyboard Layout" -Name "Scancode Map" -ErrorAction SilentlyContinue
}

if ($RemoveLogonBackgroundPolicy.IsPresent) {
	Write-Host "Removing lock/logon background policy values..."
	$personalizationPolicy = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Personalization"
	Remove-ItemProperty -Path $personalizationPolicy -Name "LockScreenImage" -ErrorAction SilentlyContinue
	Remove-ItemProperty -Path $personalizationPolicy -Name "NoChangingLockScreen" -ErrorAction SilentlyContinue

	$personalizationCsp = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\PersonalizationCSP"
	Remove-ItemProperty -Path $personalizationCsp -Name "LockScreenImagePath" -ErrorAction SilentlyContinue
	Remove-ItemProperty -Path $personalizationCsp -Name "LockScreenImageUrl" -ErrorAction SilentlyContinue
	Remove-ItemProperty -Path $personalizationCsp -Name "LockScreenImageStatus" -ErrorAction SilentlyContinue
}

if ($RestoreAccountPickerPolicy.IsPresent) {
	$backupPath = "C:\KioskSetup\account-picker-policy-backup.json"
	if (-not (Test-Path -Path $backupPath)) {
		Write-Warning "Account picker policy backup not found: $backupPath"
	}
	else {
		Write-Host "Restoring account picker policy values from: $backupPath"
		$backup = Get-Content -Path $backupPath -Raw | ConvertFrom-Json

		foreach ($record in @($backup.SystemPolicyValues)) {
			Restore-RegistryValueFromBackup -Record $record
		}

		foreach ($record in @($backup.UserListValues)) {
			Restore-RegistryValueFromBackup -Record $record
		}
	}
}

if ($EnableTaskManager.IsPresent) {
	Write-Host "Re-enabling Task Manager policy..."
	Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" -Name "DisableTaskMgr" -Type DWord -Value 0
}

Write-Host "Assigned Access configuration cleared."

if ($RebootAfterReset.IsPresent) {
	Write-Host "Rebooting now..."
	Restart-Computer -Force
}
else {
	Write-Host "Reboot recommended before reconfiguration."
}
