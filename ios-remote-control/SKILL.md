---
name: ios-remote-control
description: Remote-control iOS simulators (and real devices) for agentic app development — install apps, launch them, tap/swipe/type, take screenshots that Claude can see, stream logs, simulate push/location/permissions, and iterate. Use this skill whenever the user wants to drive an iOS app from a terminal, debug a running iOS app, automate iOS QA, reproduce iOS bugs, test deep links, inspect UI state, read simulator logs or crash reports, or build/iterate on an iPhone/iPad app with Claude in the loop — even if they don't say the word "simulator" (phrases like "boot the app", "take a screenshot of the app", "why is my app crashing", "try my React Native / Expo / SwiftUI app", "open this deep link on iOS" all trigger it). The skill gives Claude full agentic control over iPhone/iPad simulators via xcrun simctl + idb and real devices via devicectl + pymobiledevice3, with screenshots saved as files Claude can Read and JSON-structured output on every command so Claude can correlate actions with logs and errors.
---

# ios-remote-control

Drive iOS simulators and real devices for agentic app development. Every script emits structured JSON, saves artifacts (screenshots, logs) to a session directory you can Read back, and keeps errors composable.

**The loop:** `state` → `screenshot` or `ui_tree` (see what's on screen) → `tap`/`input_text`/`deeplink` (act) → `screenshot` + `log_tail` (observe result) → iterate.

## Setup expectations

This skill assumes:
- **Xcode command-line tools** (`xcrun simctl`, `xcrun devicectl`) — ships with Xcode.
- **idb** (Meta's bridge, for UI interaction): `~/.local/bin/idb` or in `PATH`. Install with `brew install facebook/fb/idb-companion && pipx install --python python3.12 fb-idb`. Note: `fb-idb` is broken on Python 3.14 — pin to 3.12.
- **pymobiledevice3** (real-device syslog, screenshots): `pipx install pymobiledevice3`.
- **Maestro** (optional, only for declarative flows): `brew install maestro`.

Run `scripts/diagnose.sh` if something fails — it reports which tools are present and which are missing.

## Session directory

All artifacts (screenshots, logs, UI trees, videos) land in `$IOS_REMOTE_ROOT/$IOS_REMOTE_SESSION`, default `/tmp/ios-remote/default`. Set `IOS_REMOTE_SESSION` to isolate sessions:

```bash
export IOS_REMOTE_SESSION="bug-repro-$(date +%s)"
```

The session dir is created lazily and contains:

```
screenshots/   20260415-183141.png, latest.png (symlink)
logs/          20260415-183145.log
ui-tree/       (reserved)
videos/        (reserved)
```

**Agents: always Read the path returned by `screenshot.sh` to see what's on screen.** The `latest.png` symlink is a stable path for "the most recent screenshot."

## Commands

Every script lives in `scripts/` and can be invoked directly, or via the dispatcher at `scripts/ios`:

```bash
scripts/ios state                    # same as scripts/state.sh
scripts/ios tap 140 222              # same as scripts/tap.sh 140 222
scripts/ios help                     # full command list
```

### Discovery

| Command | Purpose |
| --- | --- |
| `state` | Booted sims, foreground app, installed apps. Your first call in any session. |
| `devices` | All sims + connected real devices. |

### Simulator lifecycle

| Command | Purpose |
| --- | --- |
| `boot [UDID\|NAME]` | Boot a sim. No arg = first available iPhone. |
| `shutdown [UDID\|NAME\|all]` | Shut down. |
| `erase UDID` | Factory reset a sim (wipes user data). |

### App lifecycle

| Command | Purpose |
| --- | --- |
| `install PATH.app` | Install an Xcode-built `.app` bundle. |
| `launch BUNDLE_ID [--env K=V] [-- ARGS]` | Launch. Returns PID. |
| `terminate BUNDLE_ID` | Force-quit. |
| `uninstall BUNDLE_ID` | Remove. |

### Vision

| Command | Purpose |
| --- | --- |
| `screenshot [--label X]` | PNG to session dir. **Read the returned path** to see it. |
| `ui_tree [--filter TEXT]` | Accessibility tree as JSON. Cheaper than a screenshot and gives exact tap coordinates via `element.center.x/y`. |

**When to use which:** Use `ui_tree` when you know a label or accessibility id — it's cheaper and gives exact coords. Use `screenshot` when you need to see layout, styling, or states that aren't exposed in the accessibility tree.

### Interaction

| Command | Purpose |
| --- | --- |
| `tap X Y` | Tap at (x, y) in points. Get coords from `ui_tree`. |
| `swipe X1 Y1 X2 Y2 [--duration S]` | Swipe gesture. |
| `input_text "STRING"` | Type into the currently focused field. (Tap the field first.) |
| `press_button HOME\|LOCK\|SIDE_BUTTON\|SIRI\|APPLE_PAY` | Hardware buttons. |
| `deeplink URL` | Open URL. Handles custom schemes (`myapp://…`), https, mailto, tel, etc. |

### Logs & errors

| Command | Purpose |
| --- | --- |
| `log_tail [--duration N] [--bundle X] [--level L]` | Stream logs for N seconds (default 5). `--bundle com.foo` filters to one app. |
| `log_tail --save` | Write to `<session>/logs/<ts>.log` instead of streaming. |
| `log_capture` | Alias: `log_tail --save`. |
| `crash_logs [--bundle X]` | Recent crash reports. |

**Correlating actions with errors:** run `log_tail --save --duration 10 &` before a tap, then Read the saved log file after to find errors that happened during the interaction.

### State simulation (Phase 2 — coming)

| Command | Purpose |
| --- | --- |
| `push PAYLOAD.json` | Send APNS push. |
| `set_location LAT LON` | Spoof GPS. |
| `status_bar_clean` | Clean carrier/battery/time for screenshots. |
| `permissions grant BUNDLE SERVICE` | Grant Photos, Camera, Location, etc. |

### Real devices

| Command | Purpose |
| --- | --- |
| `device_list` | List connected real iOS devices (via `xcrun devicectl`). |
| `device_install PATH.ipa --device UDID` | Install on a real device. |
| `device_launch BUNDLE_ID --device UDID` | Launch. |
| `device_syslog --device UDID [--save]` | Stream device syslog via `pymobiledevice3`. |

**Real-device caveats:**
- UI interaction (tap/swipe/input) is limited to Maestro flows on real devices — `idb` doesn't support them reliably.
- Screenshots on real devices need `pymobiledevice3 developer screenshot` (mounts the Developer Disk Image).
- Deep introspection requires the device to be paired and (for some operations) in Developer Mode.

## Global flags

Every script accepts:
- `--udid UDID_OR_NAME` — target a specific simulator. Default is the currently-booted sim. You can pass a name like `"iPhone 16"` and it resolves to the UDID.

## The agentic loop — canonical recipe

When the user says "try my app and tell me what's broken":

```bash
# 1. See the world
scripts/state.sh                                      # What's booted? What's foreground?

# 2. If the app isn't running, launch it
scripts/install.sh ~/path/to/MyApp.app                # If needed
scripts/launch.sh com.example.MyApp

# 3. Give UI a moment to render, then capture
sleep 2
scripts/screenshot.sh                                 # Agent Reads the returned path

# 4. Find a button and tap it
scripts/ui_tree.sh --filter "sign in"                 # Exact frame coords
scripts/tap.sh <x> <y>                                # Tap the center
sleep 1
scripts/screenshot.sh --label after-signin            # Observe result

# 5. If something looks wrong, check logs
scripts/log_tail.sh --duration 5 --bundle com.example.MyApp --save
# Agent Reads the .log file to find errors
```

## When to escalate to Maestro

This skill is for **ad-hoc** control — one-shot operations during dev/debug. For **repeatable** flows (regression tests, demos, CI), author a [Maestro](references/maestro.md) flow YAML. The two work together: use this skill to explore and verify a flow works, then codify it in Maestro for the test suite.

## Deeper references

Read these when the SKILL.md summary isn't enough:
- [references/simctl.md](references/simctl.md) — full `xcrun simctl` capabilities (push, location, media, permissions, privacy, clocks).
- [references/idb.md](references/idb.md) — idb internals, accessibility tree shape, troubleshooting companion.
- [references/devicectl.md](references/devicectl.md) — real-device ops and what's not possible vs. simulators.
- [references/logs.md](references/logs.md) — log predicate cookbook: RN/Expo/Hermes, crash extraction, subsystem filters.
- [references/maestro.md](references/maestro.md) — when and how to escalate to declarative flows.
- [references/troubleshooting.md](references/troubleshooting.md) — common failure modes and fixes.

## Design notes for future Claude

- **JSON everywhere:** every script prints JSON on stdout. Human-readable context goes to stderr. This lets agents parse success/failure uniformly without branching on prose.
- **Exit codes are load-bearing:** non-zero means the requested action did not happen. The JSON payload explains why.
- **Don't swallow errors:** if a tap's `idb` call fails, the script surfaces the failure. Tests should never retry silently — agents should observe and decide.
- **Session dirs are disposable:** it's fine to `rm -rf $IOS_REMOTE_ROOT/<session>` between experiments.
- **Screenshots are canonical vision:** when debugging UI, the answer is often "take a screenshot and look at it." Don't try to reason about UI without one.