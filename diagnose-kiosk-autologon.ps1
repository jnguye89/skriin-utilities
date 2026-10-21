# diagnose-kiosk-autologon.ps1
# Run as Administrator on the kiosk mini PC, right after reproducing the
# "lands on sign-in screen instead of autologon" issue (no need to be at the
# console when you run this - RDP is fine for just gathering diagnostics).
# Copy the full output and send it back for analysis.

Write-Host "===== Sessions (quser) =====" -ForegroundColor Cyan
quser.exe 2>&1

Write-Host "`n===== Personalization policy (NoLockScreen should be ABSENT) =====" -ForegroundColor Cyan
Get-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Personalization" -ErrorAction SilentlyContinue |
  Select-Object NoLockScreen, LockScreenImage, NoChangingLockScreen

Write-Host "`n===== Logon UI / last logged on user policy =====" -ForegroundColor Cyan
Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" -ErrorAction SilentlyContinue |
  Select-Object DontDisplayLastUserName, DontDisplayLockedUserId, HideFastUserSwitching, DisableTaskMgr

Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Authentication\LogonUI" -ErrorAction SilentlyContinue |
  Select-Object LastLoggedOnUser, LastLoggedOnSAMUser, LastLoggedOnProvider, LastLoggedOnDisplayName

Write-Host "`n===== Assigned Access configuration (via MDM Bridge) =====" -ForegroundColor Cyan
try {
  $aa = Get-CimInstance -Namespace "root\cimv2\mdm\dmmap" -ClassName "MDM_AssignedAccess" -ErrorAction Stop
  if ($aa.Configuration) {
    [System.Net.WebUtility]::HtmlDecode($aa.Configuration)
  } else {
    Write-Host "Configuration property is EMPTY."
  }
}
catch {
  Write-Warning "Could not read MDM_AssignedAccess: $($_.Exception.Message)"
}

Write-Host "`n===== AssignedAccess registry state =====" -ForegroundColor Cyan
Get-ItemProperty -Path "HKLM:\Software\Microsoft\Windows\AssignedAccessConfiguration" -ErrorAction SilentlyContinue
Get-ItemProperty -Path "HKLM:\Software\Microsoft\Windows\AssignedAccessCsp" -ErrorAction SilentlyContinue

Write-Host "`n===== Recent Assigned Access events (last 24h) =====" -ForegroundColor Cyan
$since = (Get-Date).AddHours(-24)
foreach ($log in @(
  "Microsoft-Windows-AssignedAccess/Admin",
  "Microsoft-Windows-AssignedAccess/Operational",
  "Microsoft-Windows-AssignedAccessBroker/Admin",
  "Microsoft-Windows-AssignedAccessBroker/Operational"
)) {
  try {
    Get-WinEvent -FilterHashtable @{ LogName = $log; StartTime = $since } -ErrorAction Stop |
      Sort-Object TimeCreated |
      ForEach-Object { Write-Host "[$log] $($_.TimeCreated) id=$($_.Id) $($_.LevelDisplayName): $($_.Message)" }
  }
  catch { Write-Host "[$log] (no events or log unavailable)" }
}

Write-Host "`n===== Authentication User Interface events (last 24h, if available) =====" -ForegroundColor Cyan
try {
  $auiLog = "Microsoft-Windows-WinLogon/Operational"
  Get-WinEvent -FilterHashtable @{ LogName = $auiLog; StartTime = $since } -ErrorAction Stop |
    Sort-Object TimeCreated |
    ForEach-Object { Write-Host "[$auiLog] $($_.TimeCreated) id=$($_.Id) $($_.LevelDisplayName): $($_.Message)" }
}
catch { Write-Host "(WinLogon operational log not available or no events)" }

Write-Host "`n===== Enabled local users =====" -ForegroundColor Cyan
Get-LocalUser | Where-Object Enabled | Select-Object Name, Enabled, PasswordRequired, PasswordExpires

Write-Host "`n===== Done. Copy everything above and send it back. =====" -ForegroundColor Green
