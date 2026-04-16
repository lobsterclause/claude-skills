#!/usr/bin/env bash
# device_launch.sh — launch an installed app on a real device.
#
# Usage: device_launch.sh BUNDLE_ID --device UDID [-- ARG1 ARG2]

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${HERE}/lib/common.sh"

[[ $# -lt 1 ]] && die "missing bundle id" "Usage: device_launch.sh com.example.app --device UDID"
bundle="$1"; shift
device=""; app_args=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --device) device="$2"; shift 2 ;;
    --) shift; app_args=("$@"); break ;;
    *) die "unknown flag: $1" ;;
  esac
done
[[ -z "${device}" ]] && die "--device UDID required"

out="$(xcrun devicectl device process launch --device "${device}" "${bundle}" "${app_args[@]}" 2>&1)" \
  || die "launch failed: ${out}"

printf '{"ok":true,"action":"device_launch","bundle_id":"%s","device":"%s"}\n' "${bundle}" "${device}"