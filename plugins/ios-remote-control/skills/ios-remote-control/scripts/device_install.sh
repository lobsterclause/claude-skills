#!/usr/bin/env bash
# device_install.sh — install a signed .ipa on a real iOS device.
#
# Usage: device_install.sh PATH.ipa --device UDID
# The .ipa must be signed with a profile that includes this device.

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${HERE}/lib/common.sh"

[[ $# -lt 1 ]] && die "missing ipa" "Usage: device_install.sh /path/to/App.ipa --device UDID"
ipa="$1"; shift
device=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --device) device="$2"; shift 2 ;;
    *) die "unknown flag: $1" ;;
  esac
done
[[ -z "${device}" ]] && die "--device UDID required"
[[ ! -f "${ipa}" ]] && die "ipa not found: ${ipa}"

xcrun devicectl device install app --device "${device}" "${ipa}" 2>&1 \
  || die "install failed" "Check device is trusted and the ipa is signed for this device."

printf '{"ok":true,"action":"device_install","ipa":"%s","device":"%s"}\n' "${ipa}" "${device}"
