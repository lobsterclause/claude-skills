#!/usr/bin/env bash
# screenshot.sh — capture the current simulator screen to the session dir.
#
# Usage: screenshot.sh [--udid UDID|NAME] [--label LABEL]
#
# Writes a PNG to <session>/screenshots/<timestamp>[-label].png and
# updates <session>/screenshots/latest.png (symlink) to point at it.
# Emits JSON: {"ok": true, "path": "...", "latest": "...", "bytes": N}.
#
# Agents should Read the returned path to see what's on screen. The `latest`
# symlink is a stable path to reference the most recent screenshot.

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${HERE}/lib/common.sh"

udid=""
label=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --udid) udid="$2"; shift 2 ;;
    --label) label="$2"; shift 2 ;;
    -h|--help)
      sed -n '2,12p' "$0"; exit 0 ;;
    *) die "unknown flag: $1" "Usage: screenshot.sh [--udid UDID] [--label NAME]" ;;
  esac
done

udid="$(resolve_udid "${udid:-booted}")"
sess="$(session_dir)"

ts="$(date +%Y%m%d-%H%M%S)"
suffix="${label:+-${label}}"
out="${sess}/screenshots/${ts}${suffix}.png"

xcrun simctl io "${udid}" screenshot "${out}" >/dev/null 2>&1 \
  || die "screenshot capture failed" "Try: xcrun simctl io ${udid} screenshot /tmp/test.png"

# Update the 'latest' symlink atomically.
ln -sfn "${out}" "${sess}/screenshots/latest.png"

bytes="$(stat -f%z "${out}" 2>/dev/null || stat -c%s "${out}" 2>/dev/null || echo 0)"

python3 -c '
import json, sys
print(json.dumps({
    "ok": True,
    "path": sys.argv[1],
    "latest": sys.argv[2],
    "bytes": int(sys.argv[3]),
    "hint": "Read the path above to view the screenshot.",
}, indent=2))
' "${out}" "${sess}/screenshots/latest.png" "${bytes}"
