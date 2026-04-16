#!/usr/bin/env bash
# press_button.sh — press a hardware button on the simulator.
#
# Usage: press_button.sh BUTTON [--udid UDID]
# Valid BUTTON values (idb): HOME, LOCK, SIDE_BUTTON, SIRI, APPLE_PAY
#
# HOME returns to springboard; LOCK toggles device lock. SIRI brings up Siri.
# APPLE_PAY pops the double-press side-button Pay sheet.

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${HERE}/lib/common.sh"

[[ $# -lt 1 ]] && die "missing button" "Usage: press_button.sh HOME|LOCK|SIDE_BUTTON|SIRI|APPLE_PAY [--udid UDID]"
btn="$1"; shift

case "${btn}" in
  HOME|LOCK|SIDE_BUTTON|SIRI|APPLE_PAY) ;;
  *) die "invalid button: ${btn}" "Use HOME, LOCK, SIDE_BUTTON, SIRI, or APPLE_PAY" ;;
esac

udid=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --udid) udid="$2"; shift 2 ;;
    *) die "unknown flag: $1" ;;
  esac
done

udid="$(resolve_udid "${udid:-booted}")"
idb="$(idb_path)" || die "idb not installed"
ensure_idb_connected "${udid}"

"${idb}" ui button "${btn}" --udid "${udid}" >/dev/null 2>&1 \
  || die "button press failed: ${btn}"

printf '{"ok":true,"action":"press_button","button":"%s","udid":"%s"}\n' "${btn}" "${udid}"