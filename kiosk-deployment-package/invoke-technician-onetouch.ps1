# invoke-technician-onetouch.ps1
# One-touch technician workflow for per-device kiosk provisioning.
# Run as Administrator in a local console session.

#Requires -RunAsAdministrator

[CmdletBinding()]
param(
  [string]$ConfigPath,
  [switch]$AllowRdpSession
)

$ErrorActionPreference = "Stop"
$repoRoot = Split-Path -Path $MyInvocation.MyCommand.Path -Parent
$defaultConfigPath = Join-Path -Path $repoRoot -ChildPath "technician-config.json"

$sessionName = [Environment]::GetEnvironmentVariable("SESSIONNAME")
if (-not $AllowRdpSession.IsPresent -and -not [string]::IsNullOrWhiteSpace($sessionName) -and $sessionName -like "RDP-*") {
  throw "Assigned Access configuration must run from a local console session. Current session: $sessionName"
}

if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
  $ConfigPath = $defaultConfigPath
  if (-not (Test-Path -Path $ConfigPath)) {
    throw "ConfigPath was not specified and default config file was not found: $ConfigPath"
  }
}
elseif (-not (Test-Path -Path $ConfigPath)) {
  throw "Config file not found: $ConfigPath"
}

$ConfigPath = (Resolve-Path -Path $ConfigPath -ErrorAction Stop).ProviderPath
Write-Host "Using config file: $ConfigPath"

$config = Get-Content -Path $ConfigPath -Raw | ConvertFrom-Json
$activationRequested = (
  ($null -ne $config.ProductKey -and -not [string]::IsNullOrWhiteSpace($config.ProductKey)) -or
  ($null -ne $config.ActivationCsvPath -and -not [string]::IsNullOrWhiteSpace($config.ActivationCsvPath))
)

if ([string]::IsNullOrWhiteSpace($config.KioskUrl)) {
  throw "Config must include KioskUrl."
}

if ([string]::IsNullOrWhiteSpace($config.OwnerAdminPasswordPlainText)) {
  throw "Config must include OwnerAdminPasswordPlainText."
}

if ($null -ne $config.ActivationCsvPath -and -not [string]::IsNullOrWhiteSpace($config.ActivationCsvPath)) {
  $activationCsvCandidate = [string]$config.ActivationCsvPath
  $activationCsvPath = if ([System.IO.Path]::IsPathRooted($activationCsvCandidate)) {
    $activationCsvCandidate
  }
  else {
    Join-Path -Path $repoRoot -ChildPath $activationCsvCandidate
  }

  if (-not (Test-Path -Path $activationCsvPath)) {
    throw "ActivationCsvPath was specified, but the file was not found: $activationCsvPath"
  }
}


# Assigned Access is applied through the MDM Bridge WMI provider
# (root\cimv2\mdm\dmmap / MDM_AssignedAccess), which only exposes its
# writable 'Configuration' property to LocalSystem. Run as a normal elevated
# Administrator, Get-CimInstance silently returns an object without that
# property and setup-kiosk.ps1 dies at the very end with "The property
# 'Configuration' cannot be found on this object" - after every other
# setting has been applied, but before Edge's kiosk URL is updated. The
# device then keeps booting into whatever Assigned Access config it had
# before. So when not already SYSTEM, re-run this same script as SYSTEM via
# a one-time scheduled task and relay its result.
$currentIdentity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $currentIdentity.IsSystem) {
  Write-Host "Assigned Access must be applied as SYSTEM - relaunching this workflow as SYSTEM via a one-time scheduled task..."

  $taskName = "SkriinKioskOneTouch-" + [guid]::NewGuid().ToString("N").Substring(0, 8)
  $scriptPath = $MyInvocation.MyCommand.Path
  $taskArgs = "-NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`" -ConfigPath `"$ConfigPath`""
  if ($AllowRdpSession.IsPresent) { $taskArgs += " -AllowRdpSession" }

  $logDirForTask = Join-Path -Path $repoRoot -ChildPath "logs"
  New-Item -Path $logDirForTask -ItemType Directory -Force | Out-Null
  $existingLogs = @(Get-ChildItem -Path $logDirForTask -Filter "technician-run-*.log" -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })

  $action    = New-ScheduledTaskAction -Execute "powershell.exe" -Argument $taskArgs -WorkingDirectory $repoRoot
  $principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
  $settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 30)
  Register-ScheduledTask -TaskName $taskName -Action $action -Principal $principal -Settings $settings -Force | Out-Null

  if ($config.RebootAfterApply) {
    Write-Host "Note: RebootAfterApply is enabled - if setup succeeds the device will reboot on its own shortly."
  }

  try {
    Start-ScheduledTask -TaskName $taskName
    $deadline = (Get-Date).AddMinutes(30)
    Start-Sleep -Seconds 2
    while ((Get-ScheduledTask -TaskName $taskName).State -eq "Running" -and (Get-Date) -lt $deadline) {
      Start-Sleep -Seconds 2
    }
    $taskResult = (Get-ScheduledTaskInfo -TaskName $taskName).LastTaskResult
  }
  finally {
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
  }

  $newLog = Get-ChildItem -Path $logDirForTask -Filter "technician-run-*.log" -ErrorAction SilentlyContinue |
    Where-Object { $existingLogs -notcontains $_.FullName } |
    Sort-Object LastWriteTime -Descending | Select-Object -First 1
  if ($null -ne $newLog) {
    Write-Host ""
    Write-Host "----- SYSTEM run log: $($newLog.FullName) -----"
    Get-Content -Path $newLog.FullName | Write-Host
    Write-Host "----- end of SYSTEM run log -----"
  }

  if ($taskResult -ne 0) {
    throw "SYSTEM run of the one-touch workflow failed (exit code $taskResult). See the log above."
  }
  Write-Host "One-touch workflow completed successfully (ran as SYSTEM)."
  return
}


$logDir = Join-Path -Path $repoRoot -ChildPath "logs"
New-Item -Path $logDir -ItemType Directory -Force | Out-Null

$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$logPath = Join-Path -Path $logDir -ChildPath "technician-run-$stamp.log"
Start-Transcript -Path $logPath -Force | Out-Null

try {
  Write-Host "Starting one-touch technician workflow..."

  if ($activationRequested) {
    $activationScript = Join-Path -Path $repoRoot -ChildPath "apply-activation.ps1"

    $activationParams = @{}
    if ($null -ne $config.ProductKey -and -not [string]::IsNullOrWhiteSpace($config.ProductKey)) {
      $activationParams.ProductKey = [string]$config.ProductKey
    }

    if ($null -ne $config.ActivationCsvPath -and -not [string]::IsNullOrWhiteSpace($config.ActivationCsvPath)) {
      $csvCandidate = [string]$config.ActivationCsvPath
      if ([System.IO.Path]::IsPathRooted($csvCandidate)) {
        $activationParams.CsvPath = $csvCandidate
      }
      else {
        $activationParams.CsvPath = Join-Path -Path $repoRoot -ChildPath $csvCandidate
      }
    }

    if ($null -ne $config.ActivationCsvSerialColumn -and -not [string]::IsNullOrWhiteSpace($config.ActivationCsvSerialColumn)) {
      $activationParams.CsvSerialColumn = [string]$config.ActivationCsvSerialColumn
    }

    if ($null -ne $config.ActivationCsvKeyColumn -and -not [string]::IsNullOrWhiteSpace($config.ActivationCsvKeyColumn)) {
      $activationParams.CsvKeyColumn = [string]$config.ActivationCsvKeyColumn
    }

    Write-Host "Running activation workflow..."
    & $activationScript @activationParams
  }
  else {
    Write-Host "No activation workflow requested. Windows embedded-key or automatic activation is left unchanged."
  }

  $setupScript = Join-Path -Path $repoRoot -ChildPath "setup-kiosk.ps1"

  $displayName = if ($null -ne $config.DisplayName -and -not [string]::IsNullOrWhiteSpace($config.DisplayName)) { [string]$config.DisplayName } else { "Skriin AI TV" }
  $breakoutSequence = if ($null -ne $config.BreakoutSequence -and -not [string]::IsNullOrWhiteSpace($config.BreakoutSequence)) { [string]$config.BreakoutSequence } else { "Ctrl+Alt+Shift+S" }
  $ownerAdminUser = if ($null -ne $config.OwnerAdminUserName -and -not [string]::IsNullOrWhiteSpace($config.OwnerAdminUserName)) { [string]$config.OwnerAdminUserName } else { "skriinadmin" }
  $ownerAdminFullName = if ($null -ne $config.OwnerAdminFullName -and -not [string]::IsNullOrWhiteSpace($config.OwnerAdminFullName)) { [string]$config.OwnerAdminFullName } else { "Skriin Admin" }
  $ownerAdminLogonWorkflow = if ($null -ne $config.OwnerAdminLogonWorkflow -and -not [string]::IsNullOrWhiteSpace($config.OwnerAdminLogonWorkflow)) { [string]$config.OwnerAdminLogonWorkflow } else { "ShowAdminTile" }
  if (@("ShowAdminTile", "RequireTypedCredentials") -notcontains $ownerAdminLogonWorkflow) {
    throw "OwnerAdminLogonWorkflow must be 'ShowAdminTile' or 'RequireTypedCredentials'. Current value: $ownerAdminLogonWorkflow"
  }
  $cameraSiteUrl = if ($null -ne $config.CameraSiteUrl -and -not [string]::IsNullOrWhiteSpace($config.CameraSiteUrl)) { [string]$config.CameraSiteUrl } else { "https://skriin.com/" }

  $setupParams = @{
    KioskUrl                    = [string]$config.KioskUrl
    DisplayName                 = $displayName
    BreakoutSequence            = $breakoutSequence
    OwnerAdminUserName          = $ownerAdminUser
    OwnerAdminFullName          = $ownerAdminFullName
    OwnerAdminLogonWorkflow     = $ownerAdminLogonWorkflow
    OwnerAdminPasswordPlainText = [string]$config.OwnerAdminPasswordPlainText
    CameraSiteUrl               = $cameraSiteUrl
  }

  if ($null -ne $config.LogonBackgroundImagePath -and -not [string]::IsNullOrWhiteSpace($config.LogonBackgroundImagePath)) {
    $imageCandidate = [string]$config.LogonBackgroundImagePath
    if ([System.IO.Path]::IsPathRooted($imageCandidate)) {
      $setupParams.LogonBackgroundImagePath = $imageCandidate
    }
    else {
      $setupParams.LogonBackgroundImagePath = Join-Path -Path $repoRoot -ChildPath $imageCandidate
    }
  }

  if ($config.ConfigureScancodeHardening) {
    $setupParams.ConfigureScancodeHardening = $true
  }

  if ($config.RebootAfterApply) {
    $setupParams.RebootAfterApply = $true
  }

  Write-Host "Applying kiosk configuration..."
  & $setupScript @setupParams

  Write-Host "One-touch workflow completed successfully."
  Write-Host "Log saved to: $logPath"
}
finally {
  Stop-Transcript | Out-Null
}
