#!/usr/bin/env bash
# set_location.sh — spoof GPS location on a simulator.
#
# Usage: set_location.sh LAT LON [--udid UDID]
#   set_location.sh 37.7749 -122.4194      # San Francisco
#   set_location.sh clear                  # Clear simulated location
#
# The app sees the new location on the next CoreLocation update. For custom
# GPX tracks (moving location), use Xcode's Features > Location menu.

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${HERE}/lib/common.sh"

[[ $# -lt 1 ]] && die "missing args" "Usage: set_location.sh LAT LON [--udid UDID] | set_location.sh clear"

if [[ "$1" == "clear" ]]; then
  shift
  udid=""
  while [[ $# -gt 0 ]]; do
    case "$1" in --udid) udid="$2"; shift 2 ;; *) die "unknown flag: $1" ;; esac
  done
  udid="$(resolve_udid "${udid:-booted}")"
  xcrun simctl location "${udid}" clear >/dev/null 2>&1 || die "clear failed"
  printf '{"ok":true,"action":"location_clear","udid":"%s"}\n' "${udid}"
  exit 0
fi

[[ $# -lt 2 ]] && die "missing LON" "Usage: set_location.sh LAT LON"
lat="$1"; lon="$2"; shift 2
udid=""
while [[ $# -gt 0 ]]; do
  case "$1" in --udid) udid="$2"; shift 2 ;; *) die "unknown flag: $1" ;; esac
done

udid="$(resolve_udid "${udid:-booted}")"
xcrun simctl location "${udid}" set "${lat}" "${lon}" >/dev/null 2>&1 \
  || die "location set failed"

printf '{"ok":true,"action":"location_set","lat":%s,"lon":%s,"udid":"%s"}\n' \
  "${lat}" "${lon}" "${udid}"
