#Requires -Version 5
<#
.SYNOPSIS
  Builds the WifiSetupService for Windows x64 deployment.
#>
$ErrorActionPreference = "Stop"

$out = "WifiSetupService\publish\win-x64"

Write-Host "Building WifiSetupService..." -ForegroundColor Cyan

dotnet publish WifiSetupService `
    -c Release `
    -r win-x64 `
    --self-contained true `
    -p:PublishSingleFile=true `
    -o $out

if ($LASTEXITCODE -eq 0) {
    Write-Host "Build succeeded -> $out" -ForegroundColor Green
} else {
    Write-Host "Build failed" -ForegroundColor Red
    exit 1
}
