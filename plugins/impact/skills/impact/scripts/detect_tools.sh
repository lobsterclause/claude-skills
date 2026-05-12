#!/usr/bin/env bash
# detect_tools.sh — emit JSON describing which import-graph tools are available.
#
# Checks (in order, for each tool):
#   1. local node_modules .bin
#   2. global $PATH (which)
#   3. `npx --no-install` (project-local without printing)
#
# Output: {"madge": bool, "depcruiser": bool, "preferred": "depcruiser"|"madge"|"none"}

set -euo pipefail

repo_root="${IMPACT_REPO_ROOT:-$(pwd)}"

has_local_bin() {
  local name="$1"
  [ -x "$repo_root/node_modules/.bin/$name" ]
}

has_global() {
  command -v "$1" >/dev/null 2>&1
}

has_npx_local() {
  # `npx --no-install <bin> --version` returns non-zero if the bin is not resolvable
  # from a local package. Suppress all output.
  ( cd "$repo_root" && npx --no-install "$1" --version >/dev/null 2>&1 )
}

detect() {
  local name="$1"
  if has_local_bin "$name" || has_global "$name" || has_npx_local "$name"; then
    echo "true"
  else
    echo "false"
  fi
}

madge=$(detect madge)
# dependency-cruiser ships its binary as `depcruise`
depcruiser="false"
if has_local_bin depcruise || has_global depcruise || has_npx_local depcruise; then
  depcruiser="true"
fi

if [ "$depcruiser" = "true" ]; then
  preferred="depcruiser"
elif [ "$madge" = "true" ]; then
  preferred="madge"
else
  preferred="none"
fi

printf '{"madge": %s, "depcruiser": %s, "preferred": "%s"}\n' "$madge" "$depcruiser" "$preferred"
