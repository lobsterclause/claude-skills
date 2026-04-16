#!/usr/bin/env bash
# push.sh — send an APNS push notification to an app on a simulator.
#
# Usage:
#   push.sh BUNDLE_ID PAYLOAD.json [--udid UDID]
#   push.sh BUNDLE_ID --inline '{"aps": {"alert": "hi"}}' [--udid UDID]
#
# PAYLOAD.json must be a valid APNS payload (top-level "aps" dict). See
# assets/push_template.json for a starter.

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${HERE}/lib/common.sh"

[[ $# -lt 2 ]] && die "missing args" 'Usage: push.sh BUNDLE_ID PAYLOAD.json [--udid UDID]'
bundle="$1"; shift
payload_src="$1"; shift

udid=""
inline=false
if [[ "${payload_src}" == "--inline" ]]; then
  inline=true
  payload_src="$1"; shift
fi
while [[ $# -gt 0 ]]; do
  case "$1" in
    --udid) udid="$2"; shift 2 ;;
    *) die "unknown flag: $1" ;;
  esac
done

udid="$(resolve_udid "${udid:-booted}")"

if [[ "${inline}" == true ]]; then
  tmp="$(mktemp -t push.XXXXXX.json)"
  printf '%s' "${payload_src}" > "${tmp}"
  payload="${tmp}"
else
  [[ ! -f "${payload_src}" ]] && die "payload file not found: ${payload_src}"
  payload="${payload_src}"
fi

xcrun simctl push "${udid}" "${bundle}" "${payload}" 2>&1 \
  || die "push failed" "Ensure the app has requested push perms and is installed."

printf '{"ok":true,"action":"push","bundle_id":"%s","udid":"%s"}\n' "${bundle}" "${udid}"