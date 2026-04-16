# xcrun simctl reference

`simctl` is Apple's command-line controller for iOS simulators. This skill wraps it but sometimes you need to drop down to raw `simctl` for something we haven't scripted. Here's the map.

## Discovery

```bash
xcrun simctl list devices --json             # JSON of every sim + state
xcrun simctl list runtimes                   # Installed iOS versions
xcrun simctl list devicetypes                # Available device models
xcrun simctl list devices booted             # Only booted sims
```

## Lifecycle

```bash
xcrun simctl create "My iPhone" "com.apple.CoreSimulator.SimDeviceType.iPhone-16" "com.apple.CoreSimulator.SimRuntime.iOS-26-4"
xcrun simctl boot <UDID>
xcrun simctl shutdown <UDID>          # Or `shutdown all`
xcrun simctl erase <UDID>             # Factory reset (data wipe)
xcrun simctl delete <UDID>            # Remove the sim entirely
xcrun simctl clone <UDID> "Clone 1"   # Duplicate sim with data
```

## Apps

```bash
xcrun simctl install <UDID> MyApp.app
xcrun simctl launch <UDID> com.example.MyApp [ARG1 ARG2...]
xcrun simctl launch --console-pty <UDID> com.example.MyApp   # Stream stdout/stderr
xcrun simctl terminate <UDID> com.example.MyApp
xcrun simctl uninstall <UDID> com.example.MyApp
xcrun simctl listapps <UDID>           # OpenStep plist — pipe to `plutil -convert json -o - -`
xcrun simctl get_app_container <UDID> com.example.MyApp [app|data|groups]
```

**Passing env vars to a launch** — export `SIMCTL_CHILD_<NAME>` in your shell before running `launch`. Those become normal env vars inside the app process.

## IO

```bash
xcrun simctl io <UDID> screenshot /tmp/out.png
xcrun simctl io <UDID> recordVideo /tmp/out.mov   # Ctrl-C to stop
xcrun simctl io <UDID> enumerate                  # List IO ports (camera/mic)
```

## Logs

```bash
xcrun simctl spawn <UDID> log stream --style compact --level debug \
  --predicate 'subsystem == "com.example.MyApp"'
xcrun simctl spawn <UDID> log collect --output /tmp/sim.logarchive
```

Predicate syntax is NSPredicate. See `references/logs.md` for a cookbook.

## Interaction (limited — for taps/swipes use idb)

```bash
xcrun simctl openurl <UDID> "myapp://route/123"
xcrun simctl addmedia <UDID> photo.jpg         # Add to Photos library
xcrun simctl addmedia <UDID> video.mp4
xcrun simctl pbcopy <UDID>                     # Read from clipboard
xcrun simctl pbpaste <UDID>                    # Write to clipboard
xcrun simctl keyboard <UDID> layout US         # Set keyboard
```

## State simulation

```bash
# Push notification — payload must be a file with top-level "aps" dict.
xcrun simctl push <UDID> com.example.MyApp payload.json

# Location
xcrun simctl location <UDID> set 37.7749,-122.4194
xcrun simctl location <UDID> clear

# Status bar overrides (for clean screenshots)
xcrun simctl status_bar <UDID> override --time "9:41" --batteryLevel 100 \
  --cellularBars 4 --wifiBars 3 --operatorName " "
xcrun simctl status_bar <UDID> clear

# Privacy / permissions
xcrun simctl privacy <UDID> grant|revoke|reset <service> com.example.MyApp
# Services: all, calendar, contacts, location, photos, microphone, motion, reminders, siri

# Keychain
xcrun simctl keychain <UDID> reset

# Clock (freezing time for deterministic UI tests)
xcrun simctl ui <UDID> appearance light|dark
xcrun simctl ui <UDID> content_size large|extra-extra-large|...
```

## Gotchas

- Many subcommands silently accept an invalid UDID and exit 0 — always verify with `xcrun simctl list devices booted` after a lifecycle operation.
- `listapps` emits OpenStep plist, not JSON. Pipe to `plutil -convert json -r -o - -` to parse.
- `launch` prints `bundle.id: <pid>`. Parse the pid if you need to attach a debugger.
- `install` fails silently if the .app arch doesn't match the sim (arm64 for Apple Silicon sims).
- `booted` is a special target name that matches the first booted sim — handy for quick scripts but ambiguous if multiple sims are booted.
