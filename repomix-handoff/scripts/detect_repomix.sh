#!/usr/bin/env bash
# detect_repomix.sh — emit JSON describing whether repomix is available.
# Output: {"available": true|false, "version": "X.Y.Z"|null, "via": "global"|"npx"|null}
#
# Detection is offline-only (uses `npx --no-install` not `npx --yes`) so this
# script never blocks on a network round-trip — handoff.sh handles the
# `--yes` fallback when it actually needs to fetch the package.
set -u

emit() {
  # Use python3 for JSON encoding so version strings with quotes/newlines/
  # backslashes don't break the output.
  python3 - "$1" "$2" "$3" <<'PY'
import json, sys
avail = sys.argv[1] == "true"
ver = sys.argv[2] if sys.argv[2] != "" else None
via = sys.argv[3] if sys.argv[3] != "" else None
print(json.dumps({"available": avail, "version": ver, "via": via}))
PY
}

# 1. Prefer a globally-installed binary.
if command -v repomix >/dev/null 2>&1; then
  ver="$(repomix --version 2>/dev/null | head -n1 | tr -d '\n' || true)"
  if [ -n "${ver:-}" ]; then
    emit "true" "$ver" "global"
    exit 0
  fi
fi

# 2. Fall back to a locally-installed npx binary (no network).
if command -v npx >/dev/null 2>&1; then
  ver="$(npx --no-install --quiet repomix --version 2>/dev/null | head -n1 | tr -d '\n' || true)"
  if [ -n "${ver:-}" ]; then
    emit "true" "$ver" "npx"
    exit 0
  fi
fi

emit "false" "" ""
exit 0
