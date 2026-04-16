#!/usr/bin/env bash
# swipe.sh — swipe from (x1,y1) to (x2,y2).
#
# Usage: swipe.sh X1 Y1 X2 Y2 [--udid UDID] [--duration SECONDS] [--delta PX]
#
# --duration controls how long the swipe takes (default 0.25s for a flick).
# --delta controls the pixel distance between interpolated touch events
# (default 1 — fine-grained, good for scrolls; larger = faster but chunkier).

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${HERE}/lib/common.sh"

[[ $# -lt 4 ]] && die "missing coords" "Usage: swipe.sh X1 Y1 X2 Y2 [--udid UDID]"
x1="$1"; y1="$2"; x2="$3"; y2="$4"; shift 4

udid=""; duration=""; delta=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --udid) udid="$2"; shift 2 ;;
    --duration) duration="$2"; shift 2 ;;
    --delta) delta="$2"; shift 2 ;;
    *) die "unknown flag: $1" ;;
  esac
done

udid="$(resolve_udid "${udid:-booted}")"
idb="$(idb_path)" || die "idb not installed"
ensure_idb_connected "${udid}"

args=(ui swipe "${x1}" "${y1}" "${x2}" "${y2}" --udid "${udid}")
[[ -n "${duration}" ]] && args+=(--duration "${duration}")
[[ -n "${delta}" ]] && args+=(--delta "${delta}")

"${idb}" "${args[@]}" >/dev/null 2>&1 \
  || die "swipe failed" "Check idb_companion is up; try: ${idb} connect ${udid}"

printf '{"ok":true,"action":"swipe","from":[%s,%s],"to":[%s,%s],"udid":"%s"}\n' \
  "${x1}" "${y1}" "${x2}" "${y2}" "${udid}"
