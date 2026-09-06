# Skriin AI TV Kiosk Technician Guide

This guide covers the human technician workflow for configuring a Windows 11 Pro device as a native Microsoft Edge Assigned Access kiosk.

## Purpose

This deployment bundle configures:

- Windows 11 Pro single-app Assigned Access kiosk mode.
- Microsoft Edge fullscreen kiosk launch to the configured Skriin URL.
- Native Assigned Access autologon to the kiosk account.
- Owner admin maintenance access through the breakout sequence.
- Optional lock/logon background image.
- Hardening to reduce prompts, notifications, update interruptions, and common escape paths.
- Native activation handling when enabled.

## Files

- `technician-config.json`: per-client deployment settings. This file may contain sensitive passwords.
- `technician-config.sample.json`: safe template for creating a config.
- `invoke-technician-onetouch.ps1`: primary local technician workflow.
- `New-KioskDeploymentArchive.ps1`: creates a shareable deployment ZIP.
- `invoke-remote-kiosk-deploy.ps1`: lab/development helper for PowerShell Remoting.
- `setup-kiosk.ps1`: applies kiosk configuration and hardening.
- `reset-kiosk.ps1`: clears Assigned Access and optional hardening.
- `apply-activation.ps1`: optional native activation workflow.
- `sysprep-capture.ps1`: prepares a reference unit for image capture.
- `unattend-kiosk.xml`: optional Windows Setup/Sysprep answer file.
- `activation-keys.sample.csv`: optional activation key mapping template.
- `caveats.md`: known Windows 11 Pro limitations.

## Before You Start

Run the one-touch workflow from the target computer's local console as Administrator. Assigned Access should not be validated only over RDP.

Check that:

1. Microsoft Edge Stable is installed.
2. The device has the intended Windows 11 Pro build and updates.
3. The config file has the correct Skriin URL, owner admin password, display names, and optional activation settings.
4. Any referenced image or CSV files exist beside the deployment bundle or at the configured path.
5. You have physical access for reboot and breakout validation.
6. **The SkriinWifiSetup service (see `../wifi-setup/`) is already installed and running** (`Get-Service SkriinWifiSetup`). Assigned Access launches Edge straight at `KioskUrl` (`http://127.0.0.1:5757/`), so if that service isn't running yet, the kiosk has nothing to load. Run `wifi-setup/install.ps1` before `invoke-technician-onetouch.ps1`, and bake it into the reference image before `sysprep-capture.ps1` for fleet imaging.
7. **Camera/microphone access needs `CameraSiteUrl` set correctly.** Edge's `--kiosk` mode runs as an InPrivate-style session (per Microsoft's own kiosk-mode docs) that never persists a granted site permission, and there's no window chrome in a locked single-app kiosk for anyone to click "Allow" on a media prompt anyway. Without pre-authorizing the site, `getUserMedia()` (webcam access) silently fails every time the kiosk restarts, even though the same site works fine when tested in a normal (non-kiosk) Edge window/profile where the permission was granted once and persisted. `setup-kiosk.ps1` sets the `VideoCaptureAllowedUrls`/`AudioCaptureAllowedUrls` Edge policies for `CameraSiteUrl` (default `https://skriin.com/`) so this is handled automatically — just make sure `CameraSiteUrl` matches wherever the real site is actually served from before running this on a new client.

## Current Client Defaults

Current client configuration values:

- Kiosk URL: `http://127.0.0.1:5757/` (local WifiSetupService launcher — shows WiFi setup when offline, redirects to `https://skriin.com/` once connected)
- Camera site URL: `https://skriin.com/` (see item 7 below — camera/mic won't work in the kiosk without this)
- Kiosk display name: `Skriin AI TV`
- Breakout sequence: `Ctrl+Alt+Shift+S`
- Owner admin username: `skriinadmin`
- Owner admin display name: `Skriin Admin`
- Owner admin logon workflow: `ShowAdminTile`
- Logon background image path: `.\logon-background.png`
- Scancode hardening: enabled
- Activation workflow: not run by default

By default, Windows embedded-key and automatic activation behavior is left alone. Add `ActivationCsvPath` only when a per-device CSV key map is required.

To opt into the CSV activation workflow, add these fields to `technician-config.json` and place the CSV beside the bundle or at the configured path:

```json
{
  "ActivationCsvPath": ".\\activation-keys.csv",
  "ActivationCsvKeyColumn": "ProductKey",
  "ActivationCsvSerialColumn": "SerialNumber"
}
```

Security note: live passwords should be kept only in the local `technician-config.json` used for deployment.

## Local Deployment

Open an elevated PowerShell window on the target device:

```powershell
Set-ExecutionPolicy -Scope Process Bypass -Force
.\invoke-technician-onetouch.ps1
```

By default, the script looks for `technician-config.json` beside `invoke-technician-onetouch.ps1`. To use a different config file, pass `-ConfigPath`; the script fails if the specified file does not exist.

If your package only includes `technician-config.sample.json`, create a real `technician-config.json` from that sample and edit it before running the one-touch script.

The script will:

1. Load and validate the config.
2. Run activation only when `ProductKey` or `ActivationCsvPath` is specified.
3. Apply kiosk setup and hardening.
4. Configure Assigned Access.
5. Write a transcript under `.\logs`.
6. Reboot if `RebootAfterApply` is enabled in config.

## Create a Deployment ZIP

Create a safe technician package without live secrets:

```powershell
.\New-KioskDeploymentArchive.ps1
```

This creates `.\kiosk-deployment-package.zip` with the one-touch script, runtime dependencies, `README.md`, and `technician-config.sample.json`.

Before running the safe package on a target device, create `technician-config.json` from `technician-config.sample.json` and set the production password and any client-specific paths.

To intentionally include a real config and referenced local assets, such as the logon image:

```powershell
.\New-KioskDeploymentArchive.ps1 `
  -OutputPath .\skriin-kiosk-client.zip `
  -ConfigPath .\technician-config.json
```

To include the full technician/imaging package, matching the full remote staging file set:

```powershell
.\New-KioskDeploymentArchive.ps1 `
  -OutputPath .\skriin-kiosk-full.zip `
  -FullPackage `
  -ConfigPath .\technician-config.json
```

Security note: archives built with `-ConfigPath` may contain live passwords, activation data, or client-specific assets.

## Owner Maintenance Access

The normal boot path should autologon to the Assigned Access kiosk account and launch Edge.

For maintenance:

1. Press the breakout sequence: `Ctrl+Alt+Shift+S`.
2. Use the sign-in or switch-user path that Windows presents.
3. Sign in with the owner admin account.

If the owner admin tile is hidden, type the username directly:

```text
.\skriinadmin
```

The setup supports two owner admin logon workflows:

- `ShowAdminTile`: default. The owner admin account is left visible in the logon account list where Windows shows account tiles. Other non-kiosk local accounts are hidden where Windows honors the policy.
- `RequireTypedCredentials`: applies `DontDisplayLastUserName` so the owner admin username and password must be typed after breakout. This must be reboot-tested because this policy can affect Assigned Access autologon on some Windows 11 Pro builds.

Fast User Switching entry points are left available for the owner breakout path.

## Remote Lab Deployment

For development and lab testing, the bundle can be staged and run over PowerShell Remoting. This is not a substitute for final physical validation.

Prerequisites on the target:

1. PowerShell Remoting enabled.
2. WinRM allowed through firewall/network.
3. Connecting account is a local administrator.
4. The target and config files are trusted.

Stage files only:

```powershell
.\invoke-remote-kiosk-deploy.ps1 `
  -ComputerName KIOSK-LAB-01 `
  -Credential (Get-Credential) `
  -ConfigPath .\technician-config.json `
  -StageOnly
```

Stage and run:

```powershell
.\invoke-remote-kiosk-deploy.ps1 `
  -ComputerName KIOSK-LAB-01 `
  -Credential (Get-Credential) `
  -ConfigPath .\technician-config.json
```

If `RebootAfterApply` is true, the target may restart and disconnect the PSSession before all output is returned.

By default, remote staging copies only the runtime scripts, selected config, and referenced assets. Add `-FullPackage` to also stage technician/imaging support files such as `README.md`, `caveats.md`, `unattend-kiosk.xml`, and sample config/CSV files.

## Reset

Run locally as Administrator:

```powershell
.\reset-kiosk.ps1 -RemoveScancodeHardening -RemoveLogonBackgroundPolicy -RestoreAccountPickerPolicy -EnableTaskManager -RebootAfterReset
```

Remote lab reset:

```powershell
.\invoke-remote-kiosk-deploy.ps1 `
  -ComputerName KIOSK-LAB-01 `
  -Credential (Get-Credential) `
  -Reset `
  -RemoveScancodeHardening `
  -RemoveLogonBackgroundPolicy `
  -RestoreAccountPickerPolicy `
  -EnableTaskManager
```

Add `-RebootAfterReset` when you want the target to restart after reset completes.

## Validation Checklist

After deployment, validate on physical hardware:

1. Reboot three times and confirm the device lands in the Skriin web app.
2. Confirm Edge launches fullscreen without normal browser chrome.
3. Confirm the breakout sequence exits to sign-in.
4. Confirm the owner admin account can sign in.
5. Confirm closing or killing Edge relaunches the kiosk app under Assigned Access.
6. Confirm notifications and Action Center are suppressed.
7. Confirm the screen does not lock, sleep, hibernate, or time out.
8. Confirm the custom lock/logon image appears where Windows 11 Pro honors it.
9. Confirm the configured owner admin logon workflow works after breakout.
10. Confirm activation is licensed or intentionally skipped/deferred.

## Imaging Workflow

Recommended fleet flow:

1. Prepare and patch a reference unit.
2. Run the kiosk setup with production parameters.
3. Validate reboot and breakout behavior.
4. Run `sysprep-capture.ps1`.
5. Capture and deploy the reference image with your native imaging process.
6. Run `invoke-technician-onetouch.ps1` on each unit for per-device values and final assertions.

## Known Windows 11 Pro Limitations

- Assigned Access must be validated at the local console.
- Keyboard Filter is not available on Windows 11 Pro.
- Unbranded Boot is not available on Windows 11 Pro.
- Some key suppression is best-effort without Enterprise-only features.
- Boot-logo and BIOS power-loss behavior are hardware dependent.
- Custom lock/logon background behavior on Windows 11 Pro must be visually verified.
- Account picker cleanup is best-effort. `ShowAdminTile` is the default owner admin workflow because Assigned Access autologon takes priority.
- Web app authentication persistence depends on Skriin's server-side/device-registration behavior.

## Client-Confirmed Decisions

1. Production kiosk URL: `http://127.0.0.1:5757/`, served locally by the SkriinWifiSetup service, which redirects to `https://skriin.com/` once the device has internet access (see `wifi-setup/` for that service)
2. Breakout sequence target: `Ctrl+Alt+Shift+S`
3. Owner admin username: `skriinadmin`
4. Owner admin display name: `Skriin Admin`
5. Kiosk display name: `Skriin AI TV`
6. Owner admin logon workflow: `ShowAdminTile`
7. Update protection window: Active Hours `06:00-23:00` local time.
8. Update/reboot preference: maintenance install window around `03:00-05:00` local time.
9. Device URL allow/block filtering: disabled.
10. Web authentication persistence: handled by Skriin device registration flow.
11. Power-loss behavior: BIOS should be set to auto power-on after AC restore.
