#!/usr/bin/env bash
# detect_repomix.sh — emit JSON describing whether repomix is available.
# Output: {"available": true|false, "version": "X.Y.Z"|null, "via": "global"|"npx"|null}
set -u

emit() {
  printf '{"available": %s, "version": %s, "via": %s}\n' "$1" "$2" "$3"
}

# 1. Prefer a globally-installed binary.
if command -v repomix >/dev/null 2>&1; then
  ver="$(repomix --version 2>/dev/null | head -n1 | tr -d '\n' | sed 's/"/\\"/g')"
  if [ -n "${ver:-}" ]; then
    emit "true" "\"${ver}\"" "\"global\""
    exit 0
  fi
fi

# 2. Fall back to npx (only if npx itself exists).
if command -v npx >/dev/null 2>&1; then
  ver="$(npx --yes --quiet repomix --version 2>/dev/null | head -n1 | tr -d '\n' | sed 's/"/\\"/g' || true)"
  if [ -n "${ver:-}" ]; then
    emit "true" "\"${ver}\"" "\"npx\""
    exit 0
  fi
fi

emit "false" "null" "null"
exit 0
