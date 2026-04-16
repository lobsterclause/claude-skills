#!/usr/bin/env bash
# Shared helpers for ios-remote-control scripts.
# Source this file; do not execute directly.

set -euo pipefail

IOS_REMOTE_ROOT="${IOS_REMOTE_ROOT:-/tmp/ios-remote}"
IOS_REMOTE_SESSION="${IOS_REMOTE_SESSION:-default}"

# Resolve a session directory, creating it lazily.
session_dir() {
  local dir="${IOS_REMOTE_ROOT}/${IOS_REMOTE_SESSION}"
  mkdir -p "${dir}/screenshots" "${dir}/logs" "${dir}/ui-tree" "${dir}/videos"
  printf '%s' "${dir}"
}

log_info() { printf '[ios] %s\n' "$*" >&2; }
log_err()  { printf '[ios:error] %s\n' "$*" >&2; }

# Exit with a structured error: prints to stderr and emits a short JSON blob
# on stdout so agent callers can parse failures uniformly.
die() {
  local msg="$1"; local hint="${2:-}"
  log_err "${msg}"
  if [[ -n "${hint}" ]]; then
    log_err "hint: ${hint}"
  fi
  printf '{"ok":false,"error":%s,"hint":%s}\n' \
    "$(json_string "${msg}")" \
    "$(json_string "${hint}")"
  exit 1
}

# Minimal JSON string escaper (good enough for error messages and paths).
# For rich JSON we shell out to python3 -c 'import json,sys; ...'.
json_string() {
  local s="${1:-}"
  python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "${s}"
}

require_tool() {
  local name="$1"; local hint="${2:-}"
  if ! command -v "${name}" >/dev/null 2>&1; then
    die "required tool not found: ${name}" "${hint}"
  fi
}

# Locate idb, preferring $IDB_PATH, falling back to ~/.local/bin/idb (pipx
# install target) and PATH. idb is broken on Python 3.14; we install via pipx
# with Python 3.12 and it lands in ~/.local/bin.
idb_path() {
  if [[ -n "${IDB_PATH:-}" ]]; then
    printf '%s' "${IDB_PATH}"; return 0
  fi
  if [[ -x "${HOME}/.local/bin/idb" ]]; then
    printf '%s' "${HOME}/.local/bin/idb"; return 0
  fi
  if command -v idb >/dev/null 2>&1; then
    command -v idb; return 0
  fi
  return 1
}

# Resolve a simulator UDID. Accepts:
#   - explicit UDID (36-char hex-hyphen form)
#   - a device name ("iPhone 16e")
#   - empty/"booted" → the currently booted simulator
# Prints the UDID on stdout, or exits with an error.
resolve_udid() {
  local arg="${1:-booted}"

  # Already a UDID-shaped string?
  if [[ "${arg}" =~ ^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$ ]]; then
    printf '%s' "${arg}"; return 0
  fi

  local json
  json="$(xcrun simctl list devices --json 2>/dev/null)" || die "xcrun simctl list failed"

  if [[ "${arg}" == "booted" || -z "${arg}" ]]; then
    # First booted device across all runtimes.
    local udid
    udid="$(printf '%s' "${json}" | python3 -c '
import json, sys
data = json.load(sys.stdin)
for runtime, devs in data.get("devices", {}).items():
    for d in devs:
        if d.get("state") == "Booted":
            print(d["udid"]); sys.exit(0)
')" || true
    if [[ -z "${udid}" ]]; then
      die "no booted simulator" "Boot one with: xcrun simctl boot <UDID>, or open -a Simulator"
    fi
    printf '%s' "${udid}"
    return 0
  fi

  # Match by device name (case-insensitive, first match wins).
  local udid
  udid="$(printf '%s' "${json}" | python3 -c '
import json, sys
target = sys.argv[1].lower()
data = json.load(sys.stdin)
for runtime, devs in data.get("devices", {}).items():
    for d in devs:
        if d.get("name", "").lower() == target:
            print(d["udid"]); sys.exit(0)
' "${arg}")" || true
  if [[ -z "${udid}" ]]; then
    die "no simulator matching: ${arg}" "Run 'xcrun simctl list devices' to see available names"
  fi
  printf '%s' "${udid}"
}

# Ensure a given UDID is booted (boot + wait if needed). Safe to call on an
# already-booted device.
ensure_booted() {
  local udid="$1"
  local state
  state="$(xcrun simctl list devices --json | python3 -c '
import json, sys
udid = sys.argv[1]
data = json.load(sys.stdin)
for devs in data.get("devices", {}).values():
    for d in devs:
        if d.get("udid") == udid:
            print(d.get("state", "")); sys.exit(0)
print("NotFound")
' "${udid}")"

  case "${state}" in
    Booted) return 0 ;;
    NotFound) die "simulator not found: ${udid}" ;;
    *) xcrun simctl boot "${udid}" >/dev/null 2>&1 || true
       # Wait up to 30s for boot to complete.
       for _ in $(seq 1 30); do
         if xcrun simctl list devices --json | python3 -c '
import json, sys
udid = sys.argv[1]
data = json.load(sys.stdin)
for devs in data.get("devices", {}).values():
    for d in devs:
        if d.get("udid") == udid and d.get("state") == "Booted":
            sys.exit(0)
sys.exit(1)
' "${udid}"; then
           return 0
         fi
         sleep 1
       done
       die "simulator did not boot within 30s: ${udid}"
       ;;
  esac
}

# Ensure idb_companion is attached to a given UDID. Idempotent.
ensure_idb_connected() {
  local udid="$1"
  local idb
  idb="$(idb_path)" || die "idb not installed" "pipx install --python python3.12 fb-idb"
  "${idb}" connect "${udid}" >/dev/null 2>&1 || true
}