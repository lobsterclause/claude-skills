#!/usr/bin/env bash
# log_tail.sh — stream simulator logs to stdout for a bounded time window.
#
# Usage: log_tail.sh [--duration SECONDS] [--bundle BUNDLE_ID]
#                    [--level default|info|debug] [--predicate PREDICATE]
#                    [--udid UDID] [--save]
#
# Why a time window? Unbounded `log stream` blocks forever — useless for
# an agent loop. --duration defaults to 5s: long enough to capture the
# result of a tap/launch, short enough to keep the loop moving.
#
# --bundle filters to one app (equivalent to predicate: subsystem contains
# BUNDLE_ID). Use this when you want only your app's logs, not OS noise.
#
# --save writes to <session>/logs/<ts>.log and prints the path as JSON
# instead of streaming. Useful for passing a large log to a grader.

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${HERE}/lib/common.sh"

duration=5
bundle=""
level="default"
predicate=""
udid=""
save=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --duration) duration="$2"; shift 2 ;;
    --bundle) bundle="$2"; shift 2 ;;
    --level) level="$2"; shift 2 ;;
    --predicate) predicate="$2"; shift 2 ;;
    --udid) udid="$2"; shift 2 ;;
    --save) save=true; shift ;;
    *) die "unknown flag: $1" ;;
  esac
done

udid="$(resolve_udid "${udid:-booted}")"

# Build the log predicate.
pred="${predicate}"
if [[ -z "${pred}" && -n "${bundle}" ]]; then
  pred="subsystem == \"${bundle}\" OR process == \"${bundle##*.}\""
fi

log_args=(spawn "${udid}" log stream --style compact --level "${level}")
if [[ -n "${pred}" ]]; then
  log_args+=(--predicate "${pred}")
fi

if [[ "${save}" == true ]]; then
  sess="$(session_dir)"
  ts="$(date +%Y%m%d-%H%M%S)"
  out="${sess}/logs/${ts}.log"
  # Run log stream for `duration` seconds then kill it.
  ( xcrun simctl "${log_args[@]}" > "${out}" 2>&1 ) &
  pid=$!
  sleep "${duration}"
  kill "${pid}" 2>/dev/null || true
  wait "${pid}" 2>/dev/null || true
  lines="$(wc -l < "${out}" | tr -d ' ')"
  python3 -c '
import json, sys
print(json.dumps({
    "ok": True,
    "path": sys.argv[1],
    "lines": int(sys.argv[2]),
    "duration_seconds": float(sys.argv[3]),
}, indent=2))
' "${out}" "${lines}" "${duration}"
else
  # Stream to stdout, time-bounded. Using `timeout` if available, else a
  # background + sleep + kill pattern.
  if command -v gtimeout >/dev/null 2>&1; then
    gtimeout "${duration}" xcrun simctl "${log_args[@]}" || true
  elif command -v timeout >/dev/null 2>&1; then
    timeout "${duration}" xcrun simctl "${log_args[@]}" || true
  else
    ( xcrun simctl "${log_args[@]}" ) &
    pid=$!
    sleep "${duration}"
    kill "${pid}" 2>/dev/null || true
    wait "${pid}" 2>/dev/null || true
  fi
fi