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
