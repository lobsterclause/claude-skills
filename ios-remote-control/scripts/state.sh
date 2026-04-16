#!/usr/bin/env bash
# state.sh — emit a JSON snapshot of the current simulator state.
#
# Output shape:
#   {
#     "ok": true,
#     "booted": [{"udid": "...", "name": "...", "runtime": "..."}],
#     "foreground_app": "com.example.app" | null,
#     "installed_apps": ["com.example.app", ...],
#     "session_dir": "/tmp/ios-remote/<session>"
#   }
#
# On error: {"ok": false, "error": "...", "hint": "..."} (non-zero exit).
#
# Why JSON on both paths: callers (LLM agents, other scripts) should never
# have to branch on "did this print prose or JSON?" The shape is uniform.

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${HERE}/lib/common.sh"

sess="$(session_dir)"

# 1. Gather booted sims.
devices_json="$(xcrun simctl list devices --json 2>/dev/null)" \
  || die "xcrun simctl list failed" "Is Xcode command-line tools installed?"

booted_count="$(printf '%s' "${devices_json}" | python3 -c '
import json, sys
data = json.load(sys.stdin)
n = 0
for devs in data.get("devices", {}).values():
    for d in devs:
        if d.get("state") == "Booted":
            n += 1
print(n)
')"

if [[ "${booted_count}" == "0" ]]; then
  die "no booted simulator" "Boot one: xcrun simctl boot <UDID>; or: open -a Simulator"
fi

# 2. For the first booted sim, collect foreground app and installed apps.
#    `simctl listapps` emits a plist; convert to JSON with plutil.
python3 - "${devices_json}" "${sess}" <<'PY'
import json, os, subprocess, sys

devices_raw, session_dir = sys.argv[1], sys.argv[2]
data = json.loads(devices_raw)

booted = []
for runtime, devs in data.get("devices", {}).items():
    for d in devs:
        if d.get("state") == "Booted":
            booted.append({
                "udid": d["udid"],
                "name": d.get("name", ""),
                "runtime": runtime.split(".")[-1].replace("-", "."),
            })

primary = booted[0]["udid"]

# Foreground app via `simctl spawn <udid> launchctl list` — UIKitApplication
# labels indicate running apps; the first one printed is typically the fg app.
# This is a best-effort heuristic; for precise fg detection use idb.
try:
    out = subprocess.run(
        ["xcrun", "simctl", "spawn", primary, "launchctl", "list"],
        capture_output=True, text=True, timeout=5,
    ).stdout
    fg = None
    for line in out.splitlines():
        if "UIKitApplication:" in line:
            # line like: "1234  0  UIKitApplication:com.example.app[0x1234]"
            label = line.split("UIKitApplication:")[1].split("[")[0].strip()
            fg = label
            break
except Exception:
    fg = None

# Installed apps via listapps (plist → JSON via plutil).
installed = []
try:
    plist = subprocess.run(
        ["xcrun", "simctl", "listapps", primary],
        capture_output=True, text=True, timeout=10,
    ).stdout
    # Convert plist to JSON. plutil accepts stdin via '-'.
    conv = subprocess.run(
        ["plutil", "-convert", "json", "-r", "-o", "-", "-"],
        input=plist, capture_output=True, text=True, timeout=10,
    )
    if conv.returncode == 0 and conv.stdout.strip():
        parsed = json.loads(conv.stdout)
        installed = sorted(parsed.keys())
    else:
        # Fallback: extract bundle IDs with a regex from plist-ish output.
        import re
        installed = sorted(set(re.findall(r'"([a-zA-Z0-9_.\-]+\.[a-zA-Z0-9_.\-]+)"\s*=', plist)))
except Exception:
    installed = []

out = {
    "ok": True,
    "booted": booted,
    "foreground_app": fg,
    "installed_apps": installed,
    "session_dir": session_dir,
}
print(json.dumps(out, indent=2))
PY
