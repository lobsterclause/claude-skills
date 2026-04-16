#!/usr/bin/env bash
# erase.sh — reset a simulator to factory state (wipes all user data).
#
# Usage: erase.sh UDID_OR_NAME
# Unlike other scripts this requires an explicit target — erasing the
# currently-booted sim by accident is a mistake you only make once.

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${HERE}/lib/common.sh"

[[ $# -lt 1 ]] && die "target required" "Usage: erase.sh UDID_OR_NAME (no default for safety)"
udid="$(resolve_udid "$1")"

# Must be shutdown first.
xcrun simctl shutdown "${udid}" 2>/dev/null || true
xcrun simctl erase "${udid}" >/dev/null 2>&1 || die "erase failed"

printf '{"ok":true,"action":"erase","udid":"%s"}\n' "${udid}"
