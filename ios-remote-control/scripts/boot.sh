#!/usr/bin/env bash
# boot.sh — boot a simulator and (optionally) bring Simulator.app to front.
#
# Usage: boot.sh [UDID_OR_NAME] [--no-window]
#
# Without args, boots the first available iPhone simulator. By default we
# also `open -a Simulator` so the window is visible — pass --no-window for
# headless runs (CI, background tests).

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${HERE}/lib/common.sh"

target=""
show_window=true
while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-window) show_window=false; shift ;;
    -*) die "unknown flag: $1" ;;
    *) target="$1"; shift ;;
  esac
done

if [[ -z "${target}" ]]; then
  # Pick the first available non-watchOS iPhone.
  target="$(xcrun simctl list devices --json | python3 -c '
import json, sys
data = json.load(sys.stdin)
best = None
for runtime, devs in data.get("devices", {}).items():
    if "iOS" not in runtime: continue
    for d in devs:
        if not d.get("isAvailable"): continue
        if "iPhone" in d.get("name", ""):
            best = d["udid"]; break
    if best: break
if best: print(best)
')"
  [[ -z "${target}" ]] && die "no iPhone simulator available" "Install one via Xcode > Settings > Platforms"
fi

udid="$(resolve_udid "${target}")"
ensure_booted "${udid}"

if [[ "${show_window}" == true ]]; then
  open -a Simulator 2>/dev/null || true
fi

printf '{"ok":true,"action":"boot","udid":"%s"}\n' "${udid}"