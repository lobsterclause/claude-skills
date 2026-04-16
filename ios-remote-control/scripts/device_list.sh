#!/usr/bin/env bash
# device_list.sh — list connected real iOS devices (not simulators).
#
# Usage: device_list.sh
# Requires Xcode 15+ (ships with xcrun devicectl).

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${HERE}/lib/common.sh"

raw="$(xcrun devicectl list devices --json-output - 2>/dev/null)" \
  || die "devicectl failed" "Requires Xcode 15+. Check: xcrun devicectl --version"

python3 - "${raw}" <<'PY'
import json, sys
data = json.loads(sys.argv[1])
out = []
for d in data.get("result", {}).get("devices", []):
    hw = d.get("hardwareProperties", {})
    dp = d.get("deviceProperties", {})
    cp = d.get("connectionProperties", {})
    out.append({
        "udid": d.get("identifier") or hw.get("udid", ""),
        "name": dp.get("name") or d.get("name", ""),
        "os": dp.get("osVersionNumber", ""),
        "model": hw.get("marketingName") or d.get("deviceType", ""),
        "paired": cp.get("pairingState") == "paired",
        "transport": cp.get("transportType", ""),
    })
print(json.dumps({"ok": True, "count": len(out), "devices": out}, indent=2))
PY
