#!/usr/bin/env bash
# shutdown.sh — shut down a simulator.
#
# Usage: shutdown.sh [UDID_OR_NAME|all]
# With no arg, shuts down the currently booted sim. `all` shuts down every
# booted simulator.

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${HERE}/lib/common.sh"

target="${1:-booted}"

if [[ "${target}" == "all" ]]; then
  xcrun simctl shutdown all
  printf '{"ok":true,"action":"shutdown","target":"all"}\n'
  exit 0
fi

udid="$(resolve_udid "${target}")"
xcrun simctl shutdown "${udid}" 2>/dev/null || true
printf '{"ok":true,"action":"shutdown","udid":"%s"}\n' "${udid}"
