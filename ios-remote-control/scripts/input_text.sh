#!/usr/bin/env bash
# input_text.sh — type text into the currently focused text field.
#
# Usage: input_text.sh "the text to type" [--udid UDID]
#
# The text is delivered via the hardware keyboard, so a text input must
# already be focused (tap it first with tap.sh). Unicode works — idb
# handles the encoding. Newlines type as Return.

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${HERE}/lib/common.sh"

[[ $# -lt 1 ]] && die "missing text" 'Usage: input_text.sh "text to type" [--udid UDID]'

text="$1"; shift
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

"${idb}" ui text "${text}" --udid "${udid}" >/dev/null 2>&1 \
  || die "text input failed" "A focused text field must be present. Tap one first with tap.sh."

python3 -c '
import json, sys
print(json.dumps({"ok": True, "action": "input_text", "text": sys.argv[1], "udid": sys.argv[2]}))
' "${text}" "${udid}"
