#!/usr/bin/env bash
# tap.sh — tap at screen coordinates (x, y) on a simulator.
#
# Usage: tap.sh X Y [--udid UDID|NAME] [--duration SECONDS]
#
# Coordinates are in the simulator's logical (point) coordinate space, the
# same space idb and the accessibility tree use. For iPhone 16 that's
# roughly 0..393 wide, 0..852 tall. Use ui_tree.sh to find widget frames.

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${HERE}/lib/common.sh"

if [[ $# -lt 2 ]]; then
  die "missing coordinates" "Usage: tap.sh X Y [--udid UDID]"
fi

x="$1"; y="$2"; shift 2
udid=""
duration=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --udid) udid="$2"; shift 2 ;;
    --duration) duration="$2"; shift 2 ;;
    *) die "unknown flag: $1" ;;
  esac
done

if ! [[ "${x}" =~ ^[0-9]+(\.[0-9]+)?$ && "${y}" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
  die "x,y must be numeric: got '${x}' '${y}'"
fi
# idb only accepts integer coordinates — round any decimals from ui_tree.
x="$(printf '%.0f' "${x}")"
y="$(printf '%.0f' "${y}")"

udid="$(resolve_udid "${udid:-booted}")"
idb="$(idb_path)" || die "idb not installed" "pipx install --python python3.12 fb-idb"
ensure_idb_connected "${udid}"

args=(ui tap "${x}" "${y}" --udid "${udid}")
[[ -n "${duration}" ]] && args+=(--duration "${duration}")

if ! "${idb}" "${args[@]}" >/dev/null 2>&1; then
  die "tap failed at (${x}, ${y})" "Check that idb_companion is running and the sim is booted"
fi

printf '{"ok":true,"action":"tap","x":%s,"y":%s,"udid":"%s"}\n' "${x}" "${y}" "${udid}"