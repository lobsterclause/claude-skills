#!/usr/bin/env bash
# permissions.sh — grant or revoke a privacy permission for an app.
#
# Usage: permissions.sh grant|revoke|reset BUNDLE_ID SERVICE [--udid UDID]
#
# Services (per `xcrun simctl privacy`):
#   all, calendar, contacts-limited, contacts, location, location-always,
#   photos-add, photos, media-library, microphone, motion, reminders, siri
#   (camera isn't in this list — handled differently by iOS)

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${HERE}/lib/common.sh"

[[ $# -lt 3 ]] && die "missing args" "Usage: permissions.sh grant|revoke|reset BUNDLE_ID SERVICE [--udid UDID]"
action="$1"; bundle="$2"; service="$3"; shift 3

case "${action}" in grant|revoke|reset) ;; *) die "invalid action: ${action}" "grant|revoke|reset" ;; esac

udid=""
while [[ $# -gt 0 ]]; do
  case "$1" in --udid) udid="$2"; shift 2 ;; *) die "unknown flag: $1" ;; esac
done
udid="$(resolve_udid "${udid:-booted}")"

xcrun simctl privacy "${udid}" "${action}" "${service}" "${bundle}" >/dev/null 2>&1 \
  || die "privacy ${action} failed" "Is the app installed? Check valid services with: xcrun simctl privacy"

printf '{"ok":true,"action":"permissions_%s","bundle_id":"%s","service":"%s","udid":"%s"}\n' \
  "${action}" "${bundle}" "${service}" "${udid}"