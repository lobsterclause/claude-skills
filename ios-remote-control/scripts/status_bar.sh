#!/usr/bin/env bash
# status_bar.sh — override the simulator status bar for clean screenshots.
#
# Usage:
#   status_bar.sh clean [--udid UDID]              # 9:41 · Carrier · full battery
#   status_bar.sh set KEY=VALUE... [--udid UDID]   # Custom overrides
#   status_bar.sh clear [--udid UDID]              # Restore defaults
#
# Valid keys: time, dataNetwork, wifiMode, wifiBars, cellularMode,
# cellularBars, batteryState, batteryLevel, operatorName. See:
#   xcrun simctl status_bar --help

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${HERE}/lib/common.sh"

sub="${1:-}"; shift || true
case "${sub}" in
  clean|set|clear) ;;
  *) die "missing subcommand" "Usage: status_bar.sh clean|set|clear" ;;
esac

udid=""
kvs=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --udid) udid="$2"; shift 2 ;;
    *=*) kvs+=("$1"); shift ;;
    *) die "unknown arg: $1" ;;
  esac
done
udid="$(resolve_udid "${udid:-booted}")"

case "${sub}" in
  clean)
    xcrun simctl status_bar "${udid}" override \
      --time "9:41" \
      --dataNetwork wifi \
      --wifiMode active --wifiBars 3 \
      --cellularMode active --cellularBars 4 \
      --batteryState charged --batteryLevel 100 \
      --operatorName " " \
      >/dev/null 2>&1 || die "status_bar override failed"
    printf '{"ok":true,"action":"status_bar_clean","udid":"%s"}\n' "${udid}" ;;
  set)
    args=()
    for kv in "${kvs[@]}"; do
      args+=("--${kv%%=*}" "${kv#*=}")
    done
    xcrun simctl status_bar "${udid}" override "${args[@]}" >/dev/null 2>&1 \
      || die "status_bar set failed"
    printf '{"ok":true,"action":"status_bar_set","udid":"%s"}\n' "${udid}" ;;
  clear)
    xcrun simctl status_bar "${udid}" clear >/dev/null 2>&1 || die "clear failed"
    printf '{"ok":true,"action":"status_bar_clear","udid":"%s"}\n' "${udid}" ;;
esac