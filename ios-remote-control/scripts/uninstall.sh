#!/usr/bin/env bash
# uninstall.sh — remove an installed app by bundle id.
#
# Usage: uninstall.sh BUNDLE_ID [--udid UDID]

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${HERE}/lib/common.sh"

[[ $# -lt 1 ]] && die "missing bundle id" "Usage: uninstall.sh com.example.app [--udid UDID]"
bundle="$1"; shift
udid=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --udid) udid="$2"; shift 2 ;;
    *) die "unknown flag: $1" ;;
  esac
done

udid="$(resolve_udid "${udid:-booted}")"
xcrun simctl uninstall "${udid}" "${bundle}" 2>/dev/null \
  || die "uninstall failed: ${bundle}" "Is the app installed? Check with state.sh"

printf '{"ok":true,"action":"uninstall","bundle_id":"%s","udid":"%s"}\n' "${bundle}" "${udid}"