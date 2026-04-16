#!/usr/bin/env bash
# diagnose.sh — report which prerequisites are present and which are missing.
#
# Run this when another script fails for murky reasons. It checks every
# tool this skill touches and prints install hints for any missing ones.

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${HERE}/lib/common.sh"

check() {
  local name="$1" cmd="$2" install_hint="$3"
  if command -v "${cmd}" >/dev/null 2>&1; then
    local v
    v="$("${cmd}" --version 2>&1 | head -1 || echo)"
    printf '{"tool":"%s","present":true,"path":"%s","version":%s}\n' \
      "${name}" "$(command -v "${cmd}")" "$(python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "${v}")"
  else
    printf '{"tool":"%s","present":false,"install_hint":%s}\n' \
      "${name}" "$(python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "${install_hint}")"
  fi
}

python3 <<'PY'
import json, subprocess, shutil, os

def vers(cmd):
    try:
        return subprocess.run([cmd, "--version"], capture_output=True, text=True, timeout=3).stdout.strip().splitlines()[0]
    except Exception:
        return ""

def where(cmd):
    return shutil.which(cmd) or ""

def check(name, cmd, hint, alt_path=""):
    path = where(cmd) or (alt_path if os.path.exists(alt_path) else "")
    if path:
        return {"tool": name, "present": True, "path": path, "version": vers(path)}
    return {"tool": name, "present": False, "install_hint": hint}

home = os.path.expanduser("~")
tools = [
    check("xcrun", "xcrun", "Install Xcode from the App Store"),
    check("xcrun simctl", "xcrun", "Ships with Xcode"),
    check("xcrun devicectl", "xcrun", "Requires Xcode 15+"),
    check("idb", "idb", "pipx install --python python3.12 fb-idb (fb-idb is broken on Python 3.14)", f"{home}/.local/bin/idb"),
    check("idb_companion", "idb_companion", "brew install facebook/fb/idb-companion"),
    check("pymobiledevice3", "pymobiledevice3", "pipx install pymobiledevice3", f"{home}/.local/bin/pymobiledevice3"),
    check("maestro", "maestro", "brew install maestro (optional, for declarative flows)"),
    check("bats", "bats", "brew install bats-core (optional, only for running this skill's tests)"),
    check("python3", "python3", "Ships with macOS"),
    check("plutil", "plutil", "Ships with macOS"),
]

# devicectl special-cases — it's a subcommand not a bare binary.
try:
    dc = subprocess.run(["xcrun", "devicectl", "--version"], capture_output=True, text=True, timeout=3)
    tools.append({"tool": "xcrun devicectl", "present": dc.returncode == 0, "version": dc.stdout.strip().splitlines()[0] if dc.stdout.strip() else ""})
except Exception:
    tools.append({"tool": "xcrun devicectl", "present": False, "install_hint": "Xcode 15+ required"})

# Booted simulators
try:
    j = subprocess.run(["xcrun", "simctl", "list", "devices", "--json"], capture_output=True, text=True, timeout=5)
    devs = json.loads(j.stdout)
    booted = [d["name"] for ds in devs.get("devices", {}).values() for d in ds if d.get("state") == "Booted"]
except Exception:
    booted = []

print(json.dumps({
    "ok": all(t.get("present") for t in tools if t["tool"] in ("xcrun", "python3", "plutil")),
    "tools": tools,
    "booted_simulators": booted,
    "session_root": os.environ.get("IOS_REMOTE_ROOT", "/tmp/ios-remote"),
    "hints": [
        "Missing tools: install using the hint shown, then rerun.",
        "For fb-idb: Python 3.14 is incompatible. Use: pipx install --python python3.12 fb-idb",
        "No booted sim? Run: scripts/boot.sh",
    ],
}, indent=2))
PY