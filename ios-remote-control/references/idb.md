# idb reference

`idb` is Meta's simulator/device bridge. It speaks to `idb_companion` (a daemon) over gRPC. Where `simctl` stops (UI interaction, accessibility introspection), `idb` picks up.

## Setup

```bash
brew install facebook/fb/idb-companion
pipx install --python python3.12 fb-idb   # MUST be py3.12; fb-idb breaks on 3.14
idb connect <UDID>                         # Launches a companion if needed
```

The companion is a long-lived daemon. If taps/swipes start hanging, kill any orphaned companion processes:

```bash
pkill -f idb_companion
idb connect <UDID>
```

## UI interaction

```bash
idb ui tap X Y --udid <UDID> [--duration SECONDS]
idb ui swipe X1 Y1 X2 Y2 --udid <UDID> [--duration S] [--delta PIXELS]
idb ui text "hello world" --udid <UDID>        # Types into focused field
idb ui button HOME|LOCK|SIDE_BUTTON|SIRI|APPLE_PAY --udid <UDID>
idb ui key <KEYCODE> --udid <UDID>             # Raw keycodes
idb ui key-sequence <seq> --udid <UDID>        # Multiple keys
```

Coordinates are in **points** (iOS logical pixels), not device pixels. iPhone 16 is roughly 393×852 points regardless of @3x physical resolution.

## Accessibility tree

```bash
idb ui describe-all --udid <UDID> --json       # Full tree
idb ui describe-point X Y --udid <UDID>        # Element under a point
```

The tree is a flat list of elements. Each element has:
- `type`: `Button`, `StaticText`, `TextField`, `ScrollView`, etc.
- `AXLabel`: accessibility label (what VoiceOver reads)
- `AXValue`: current value (e.g., text content of a TextField)
- `AXUniqueId`: custom accessibility id (React Native: `testID`)
- `frame`: `{x, y, width, height}` in points
- `enabled`, `selected`, `hasKeyboardFocus`

**Best strategy for tapping:** query the tree, filter for the element, use `frame.x + frame.width/2, frame.y + frame.height/2` as the tap point. The `ui_tree.sh` script does this automatically.

## Misc

```bash
idb screenshot --udid <UDID> /tmp/out.png
idb record-video --udid <UDID> /tmp/out.mp4    # Better quality than simctl
idb file push <local> <remote> --bundle-id com.example.MyApp --udid <UDID>
idb file pull <remote> <local> --bundle-id com.example.MyApp --udid <UDID>
idb crash list --udid <UDID>                   # Device crash reports
idb log --udid <UDID>                          # Log stream
idb focus --udid <UDID>                        # Bring Simulator window to front
```

## Troubleshooting

**`idb: command not found`** — pipx didn't add `~/.local/bin` to PATH. Either add it or set `IDB_PATH=/Users/.../.local/bin/idb` in your env.

**`RuntimeError: There is no current event loop`** — you're on Python 3.14, fb-idb 1.1.7 is broken. Reinstall with `--python python3.12`.

**Taps don't land** — usually means the UI is mid-transition. Add a `sleep 0.5` after navigation before tapping, or use `ui_tree` to confirm the target is present.

**Companion dies mid-session** — nothing persists state across restarts; just `idb connect <UDID>` again. All scripts in this skill call `ensure_idb_connected` first.
