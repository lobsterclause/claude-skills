#!/usr/bin/env bash
# detect_reviewers.sh — report which review CLIs are available.
# Prints JSON to stdout: {"codex": true|false, "gemini": true|false, "kimi": true|false}

set -euo pipefail

has() { command -v "$1" >/dev/null 2>&1; }

codex=false
gemini=false
kimi=false

has codex && codex=true
has gemini && gemini=true
has kimi && kimi=true

printf '{"codex": %s, "gemini": %s, "kimi": %s}\n' "$codex" "$gemini" "$kimi"