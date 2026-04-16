#!/usr/bin/env bash
# deeplink.sh — open a URL on the simulator (deep link, https, tel, etc.).
#
# Usage: deeplink.sh URL [--udid UDID]
# Examples:
#   deeplink.sh "prosperxo://scan/123"
#   deeplink.sh "https://apple.com"
#   deeplink.sh "mailto:foo@bar.com"
#
# This is the right entry point for testing deep-link routing, universal
# links, and custom URL schemes without building a launcher UI.

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${HERE}/lib/common.sh"

[[ $# -lt 1 ]] && die "missing url" 'Usage: deeplink.sh "scheme://path" [--udid UDID]'
url="$1"; shift
udid=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --udid) udid="$2"; shift 2 ;;
    *) die "unknown flag: $1" ;;
  esac
done

udid="$(resolve_udid "${udid:-booted}")"

xcrun simctl openurl "${udid}" "${url}" >/dev/null 2>&1 \
  || die "openurl failed" "Ensure an app on the sim handles scheme '${url%%:*}'"

python3 -c '
import json, sys
print(json.dumps({"ok": True, "action": "deeplink", "url": sys.argv[1], "udid": sys.argv[2]}))
' "${url}" "${udid}"