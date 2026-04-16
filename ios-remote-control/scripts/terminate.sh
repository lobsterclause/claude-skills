#!/usr/bin/env bash
# terminate.sh — force-quit an app by bundle id.
#
# Usage: terminate.sh BUNDLE_ID [--udid UDID]

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${HERE}/lib/common.sh"

[[ $# -lt 1 ]] && die "missing bundle id" "Usage: terminate.sh com.example.app [--udid UDID]"
bundle="$1"; shift
udid=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --udid) udid="$2"; shift 2 ;;
    *) die "unknown flag: $1" ;;
  esac
done

udid="$(resolve_udid "${udid:-booted}")"
xcrun simctl terminate "${udid}" "${bundle}" 2>/dev/null || true

printf '{"ok":true,"action":"terminate","bundle_id":"%s","udid":"%s"}\n' "${bundle}" "${udid}"