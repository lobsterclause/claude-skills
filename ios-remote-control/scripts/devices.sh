#!/usr/bin/env bash
# devices.sh — list every known sim and every connected real device.
#
# Output: {"ok": true, "simulators": [...], "real_devices": [...]}
# Simulators show state ("Booted"/"Shutdown"). Real devices require Xcode
# 15+ and a trusted, paired device.

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${HERE}/lib/common.sh"

sim_json="$(xcrun simctl list devices --json 2>/dev/null || echo '{"devices": {}}')"

# devicectl emits a long-ish JSON blob; --json flag requires recent Xcode.
dev_json="$(xcrun devicectl list devices --json-output - 2>/dev/null || echo '{"result":{"devices":[]}}')"

python3 - "${sim_json}" "${dev_json}" <<'PY'
import json, sys

sim = json.loads(sys.argv[1])
dev = json.loads(sys.argv[2])

sims = []
for runtime, ds in sim.get("devices", {}).items():
    for d in ds:
        if not d.get("isAvailable"):
            continue
        sims.append({
            "udid": d["udid"],
            "name": d.get("name", ""),
            "state": d.get("state", ""),
            "runtime": runtime.split(".")[-1].replace("-", "."),
        })

real = []
for d in dev.get("result", {}).get("devices", []):
    # devicectl schema varies; pull what's stable.
    real.append({
        "udid": d.get("identifier") or d.get("hardwareProperties", {}).get("udid", ""),
        "name": d.get("deviceProperties", {}).get("name") or d.get("name", ""),
        "os": d.get("deviceProperties", {}).get("osVersionNumber", ""),
        "model": d.get("hardwareProperties", {}).get("marketingName") or d.get("deviceType", ""),
        "state": d.get("connectionProperties", {}).get("pairingState", "unknown"),
    })

print(json.dumps({"ok": True, "simulators": sims, "real_devices": real}, indent=2))
PY