#!/usr/bin/env bash
# detect_reviewers.sh — report which review CLIs are available.
# Prints JSON to stdout: {"codex": true|false, "gemini": true|false}

set -euo pipefail

has() { command -v "$1" >/dev/null 2>&1; }

codex=false
gemini=false

has codex && codex=true
has gemini && gemini=true

printf '{"codex": %s, "gemini": %s}\n' "$codex" "$gemini"