# Troubleshooting

Run `scripts/diagnose.sh` first. It tells you which tools are present and which are missing.

## "no booted simulator"

```
{"ok":false,"error":"no booted simulator","hint":"Boot one: xcrun simctl boot <UDID>; or: open -a Simulator"}
```

Either no sim is running, or you passed `--udid` pointing at a shutdown sim. Fix:

```bash
scripts/boot.sh                    # Boot first available iPhone
# Or:
xcrun simctl list devices          # Find a UDID
xcrun simctl boot <UDID>
open -a Simulator                  # Show the window
```

## idb hangs / taps don't register

The companion daemon has desynced from the simulator. Hard reset:

```bash
pkill -f idb_companion
~/.local/bin/idb connect <UDID>
```

Then retry the tap. If it still fails, the sim itself may be wedged — `xcrun simctl shutdown <UDID> && xcrun simctl boot <UDID>`.

## "idb: No module named 'idb'" / RuntimeError about event loops

You're on Python 3.14. `fb-idb 1.1.7` calls the removed `asyncio.get_event_loop()`. Reinstall on 3.12:

```bash
pipx uninstall fb-idb
brew install python@3.12
pipx install --python /opt/homebrew/bin/python3.12 fb-idb
```

## App install fails: "Bundle failed to load" / "incompatible architecture"

The `.app` you're installing was built for device, not simulator. Xcode sometimes picks the wrong scheme — rebuild with `-destination "generic/platform=iOS Simulator"` or choose a sim destination in Xcode.

## Deep link doesn't open my app

- The scheme must be registered in `Info.plist` under `CFBundleURLTypes`, or for universal links, in `apple-app-site-association`.
- The app must be installed.
- Test the scheme directly: `xcrun simctl openurl <UDID> "myapp://"`. If nothing happens, the scheme isn't registered.
- Expo / React Native apps need the scheme in `app.json` → `ios.scheme` or `expo.scheme`.

## Screenshot is all black

- The sim just booted and hasn't rendered yet. Sleep 1-2s.
- If using `status_bar_clean` right before, a bug in iOS 17.4-17.5 occasionally blanks the screen — clear it and retry.
- The app is using `UIScreenCapture` protection (DRM content, some keyboards). You can't capture those.

## Log stream shows nothing

- Your predicate is too narrow. Try `--predicate 'process CONTAINS "MyApp"'` with no other filters.
- The app might not be emitting logs — add `--level debug` to catch `os_log(.debug, …)`.
- The app might be crashing before logging. Check `crash_logs.sh`.

## Real device: "device is not trusted"

1. Plug device into this Mac over USB at least once.
2. On the device, tap "Trust this computer."
3. Unlock the device.
4. Retry.

## Real device: pymobiledevice3 operations fail with "DeveloperDiskImageNotFoundError"

The Developer Disk Image isn't mounted. Mount it:

```bash
pymobiledevice3 mounter auto-mount --udid <UDID>
```

This downloads the DDI for the device's iOS version from Apple and mounts it. It's a one-time-per-boot operation.

## Push payload rejected

- Must be JSON. Use `python3 -m json.tool payload.json` to validate.
- Must have top-level `aps` dict.
- Bundle id in the payload (or as an arg to `simctl push`) must match the installed app.
- The app must have been launched at least once so iOS knows about its push capability.

## "Operation too slow" / tests time out

- `log stream` is unbounded by default. All our scripts time-bound it — if you're calling `simctl spawn … log stream` directly, wrap in `timeout <seconds>` or it'll hang forever.
- `idb ui describe-all` on a complex screen can take 3-5s. Budget for it.
- Sim boot can take 15-30s from cold. The `ensure_booted` helper waits up to 30s before giving up.
