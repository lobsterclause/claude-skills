# xcrun devicectl (real devices) reference

`devicectl` is Apple's CoreDevice CLI, introduced in Xcode 15. It replaces the old `ios-deploy` / `instruments` toolchain for most real-device operations.

## What works on real devices

| Operation | Tool | Notes |
| --- | --- | --- |
| List devices | `xcrun devicectl list devices` | Needs a trusted, paired device |
| Install app | `xcrun devicectl device install app` | `.ipa` must be signed for this device |
| Launch app | `xcrun devicectl device process launch` | Returns PID |
| Terminate app | `xcrun devicectl device process terminate` | By PID |
| Stream syslog | `pymobiledevice3 syslog live` | devicectl doesn't do this well |
| Screenshot | `pymobiledevice3 developer screenshot` | Mounts Developer Disk Image first |
| Deep links | `xcrun devicectl device openurl` | Xcode 16+ only |
| Crash reports | `pymobiledevice3 crash list` | Easier than devicectl's variant |

## What DOESN'T work on real devices

| Operation | Why |
| --- | --- |
| Tap/swipe/type via idb | `idb` companion doesn't support real-device UI interaction reliably |
| Status bar override | Simulator-only |
| APNS push via simctl | Real devices need actual APNS — use your server |
| Location spoofing | Simulator-only (simctl). For devices, you'd need to jailbreak or use Xcode's GPX. |
| Keychain reset | Simulator-only |

For UI automation on a real device, use **Maestro** — it uses iOS's native XCUITest runner and works on real devices.

## Commands

```bash
# List every paired, connected device with JSON output.
xcrun devicectl list devices --json-output -

# Install. Device UDID comes from the list command.
xcrun devicectl device install app --device <UDID> /path/to/MyApp.ipa

# Launch. Pass launch-arguments after the bundle id.
xcrun devicectl device process launch --device <UDID> com.example.MyApp

# Terminate.
xcrun devicectl device process terminate --device <UDID> --pid <PID>

# Run arbitrary command inside the app's sandbox (Xcode 16+).
xcrun devicectl device process exec --device <UDID> --process com.example.MyApp \
  --argument "command"
```

## pymobiledevice3 bits

```bash
# Syslog
pymobiledevice3 syslog live --udid <UDID>

# Screenshot (requires DDI mount)
pymobiledevice3 mounter auto-mount --udid <UDID>
pymobiledevice3 developer screenshot --udid <UDID> /tmp/shot.png

# Crashes
pymobiledevice3 crash list --udid <UDID>
pymobiledevice3 crash pull --udid <UDID> /tmp/crashes/

# Device info
pymobiledevice3 lockdown info --udid <UDID>
```

`pymobiledevice3 developer ...` commands need the Developer Disk Image mounted. The `mounter auto-mount` subcommand pulls the right DDI for your device's iOS version from Apple's servers and mounts it. This is a one-time (per device boot) step.

## Trust and pairing

- First time you plug a device in, you'll get "Trust this computer?" on the device — tap Trust. Without this, every command fails with "device is not trusted."
- Device must be unlocked for pairing, and for most operations on iOS 17+.
- For iOS 16+, Developer Mode must be enabled: Settings > Privacy & Security > Developer Mode.

## When to prefer `devicectl` vs `pymobiledevice3`

- **devicectl** — official, stable, but limited feature surface. Use for install/launch.
- **pymobiledevice3** — community tool, broader feature surface (syslog, crashes, DDI, file system, services). Use when devicectl can't do what you need.

The two can coexist; they don't fight over locks.
