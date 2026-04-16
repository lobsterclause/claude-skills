#!/usr/bin/env bash
# device_syslog.sh — stream real-device syslog via pymobiledevice3.
#
# Usage: device_syslog.sh [--device UDID] [--duration SECONDS] [--save]
#                        [--filter SUBSTRING]
#
# pymobiledevice3 uses the device's native logging protocol; no Xcode
# needed beyond drivers. Without --duration the stream is bounded to 5s.
# With --save it writes to <session>/logs/device-<ts>.log.
#
# --filter is a plain substring match applied to each line as it streams.

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${HERE}/lib/common.sh"

device=""; duration=5; save=false; filter=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --device) device="$2"; shift 2 ;;
    --duration) duration="$2"; shift 2 ;;
    --save) save=true; shift ;;
    --filter) filter="$2"; shift 2 ;;
    *) die "unknown flag: $1" ;;
  esac
done

pmd3=""
if [[ -x "${HOME}/.local/bin/pymobiledevice3" ]]; then
  pmd3="${HOME}/.local/bin/pymobiledevice3"
elif command -v pymobiledevice3 >/dev/null 2>&1; then
  pmd3="$(command -v pymobiledevice3)"
else
  die "pymobiledevice3 not installed" "pipx install pymobiledevice3"
fi

args=(syslog live)
[[ -n "${device}" ]] && args+=(--udid "${device}")

if [[ "${save}" == true ]]; then
  sess="$(session_dir)"
  ts="$(date +%Y%m%d-%H%M%S)"
  out="${sess}/logs/device-${ts}.log"
  if [[ -n "${filter}" ]]; then
    ( "${pmd3}" "${args[@]}" 2>&1 | grep --line-buffered -F "${filter}" > "${out}" ) &
  else
    ( "${pmd3}" "${args[@]}" > "${out}" 2>&1 ) &
  fi
  pid=$!
  sleep "${duration}"
  kill "${pid}" 2>/dev/null || true
  wait "${pid}" 2>/dev/null || true
  lines="$(wc -l < "${out}" | tr -d ' ')"
  printf '{"ok":true,"path":"%s","lines":%s,"duration_seconds":%s}\n' "${out}" "${lines}" "${duration}"
else
  if command -v timeout >/dev/null 2>&1; then
    if [[ -n "${filter}" ]]; then
      timeout "${duration}" "${pmd3}" "${args[@]}" 2>&1 | grep --line-buffered -F "${filter}"
    else
      timeout "${duration}" "${pmd3}" "${args[@]}" || true
    fi
  else
    ( "${pmd3}" "${args[@]}" ) &
    pid=$!
    sleep "${duration}"
    kill "${pid}" 2>/dev/null || true
    wait "${pid}" 2>/dev/null || true
  fi
fi