#!/usr/bin/env bash
# install.sh — install a .app bundle (built by Xcode) to the simulator.
#
# Usage: install.sh PATH_TO_APP [--udid UDID]
# Example: install.sh ~/Library/Developer/Xcode/DerivedData/.../MyApp.app
#
# For signed .ipa files or real devices, see device_install.sh.

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${HERE}/lib/common.sh"

[[ $# -lt 1 ]] && die "missing path" "Usage: install.sh /path/to/MyApp.app [--udid UDID]"
app="$1"; shift
udid=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --udid) udid="$2"; shift 2 ;;
    *) die "unknown flag: $1" ;;
  esac
done

[[ ! -e "${app}" ]] && die "app bundle not found: ${app}"

udid="$(resolve_udid "${udid:-booted}")"
ensure_booted "${udid}"

xcrun simctl install "${udid}" "${app}" 2>&1 \
  || die "install failed" "Check the .app is built for the simulator arch (arm64 for Apple silicon)"

python3 -c '
import json, sys
print(json.dumps({"ok": True, "action": "install", "app": sys.argv[1], "udid": sys.argv[2]}))
' "${app}" "${udid}"
