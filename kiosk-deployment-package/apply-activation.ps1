# apply-activation.ps1
# Native Windows activation helper for kiosk deployments.
# Run as Administrator.

#Requires -RunAsAdministrator

[CmdletBinding()]
param(
  [string]$ProductKey,
  [string]$CsvPath,
  [string]$CsvSerialColumn = "SerialNumber",
  [string]$CsvKeyColumn = "ProductKey",
  [switch]$SkipOnlineActivation
)

$ErrorActionPreference = "Stop"

function Get-DeviceSerialNumber {
  $serial = (Get-CimInstance -ClassName Win32_BIOS).SerialNumber
  if ([string]::IsNullOrWhiteSpace($serial)) {
    throw "Could not determine device serial number from BIOS."
  }

  return $serial.Trim()
}

function Get-EmbeddedProductKey {
  $lic = Get-CimInstance -Query "SELECT OA3xOriginalProductKey FROM SoftwareLicensingService"
  if ($null -eq $lic) {
    return $null
  }

  return $lic.OA3xOriginalProductKey
}

function Get-ProductKeyFromCsv {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][string]$SerialColumn,
    [Parameter(Mandatory = $true)][string]$KeyColumn,
    [Parameter(Mandatory = $true)][string]$SerialNumber
  )

  if (-not (Test-Path -Path $Path)) {
    throw "CSV path not found: $Path"
  }

  $rows = Import-Csv -Path $Path
  $match = $rows | Where-Object { $_.$SerialColumn -eq $SerialNumber } | Select-Object -First 1
  if ($null -eq $match) {
    return $null
  }

  return $match.$KeyColumn
}

function Invoke-Slmgr {
  param(
    [Parameter(Mandatory = $true)][string[]]$Arguments
  )

  $slmgrPath = Join-Path -Path $env:windir -ChildPath "System32\slmgr.vbs"
  & cscript.exe //NoLogo $slmgrPath @Arguments
}

$selectedKey = $null
$keySource = $null

if ($PSBoundParameters.ContainsKey("ProductKey") -and -not [string]::IsNullOrWhiteSpace($ProductKey)) {
  $selectedKey = $ProductKey.Trim()
  $keySource = "DirectParameter"
}

if ([string]::IsNullOrWhiteSpace($selectedKey) -and $PSBoundParameters.ContainsKey("CsvPath")) {
  $serial = Get-DeviceSerialNumber
  $csvKey = Get-ProductKeyFromCsv -Path $CsvPath -SerialColumn $CsvSerialColumn -KeyColumn $CsvKeyColumn -SerialNumber $serial

  if (-not [string]::IsNullOrWhiteSpace($csvKey)) {
    $selectedKey = $csvKey.Trim()
    $keySource = "CsvMap"
  }
}

if ([string]::IsNullOrWhiteSpace($selectedKey) -and -not $PSBoundParameters.ContainsKey("CsvPath")) {
  $embeddedKey = Get-EmbeddedProductKey
  if (-not [string]::IsNullOrWhiteSpace($embeddedKey)) {
    $selectedKey = $embeddedKey.Trim()
    $keySource = "EmbeddedFirmware"
  }
}

if ([string]::IsNullOrWhiteSpace($selectedKey)) {
  Write-Warning "No activation key available from direct parameter, CSV mapping, or embedded firmware."
  Write-Output "ActivationStatus=Skipped"
  exit 0
}

Write-Host "Applying product key from source: $keySource"
Invoke-Slmgr -Arguments @("/ipk", $selectedKey)

if (-not $SkipOnlineActivation.IsPresent) {
  Write-Host "Attempting online activation..."
  Invoke-Slmgr -Arguments @("/ato")
}
else {
  Write-Host "Online activation skipped by request."
}

$licenseProducts = Get-CimInstance -Query "SELECT Name, LicenseStatus, Description FROM SoftwareLicensingProduct WHERE PartialProductKey IS NOT NULL"
$licensed = $licenseProducts | Where-Object { $_.LicenseStatus -eq 1 } | Select-Object -First 1

if ($null -ne $licensed) {
  Write-Output "ActivationStatus=Licensed"
  Write-Output "ActivationProduct=$($licensed.Name)"
}
else {
  Write-Output "ActivationStatus=UnknownOrUnlicensed"
}
