#!/usr/bin/env bash
# detect_reviewers.sh — report which review CLIs are available.
# Prints JSON to stdout: {"codex": bool, "antigravity": bool, "gemini-pro": bool, "kimi": bool}
#
# As of the 2026-06-18 Gemini-CLI consumer sunset, BOTH Gemini-family reviewers
# run on Google's `agy` (Antigravity) CLI:
#   - antigravity → agy --model "Gemini 3.5 Flash (High)"   (fast lap)
#   - gemini-pro  → agy --model "Gemini 3.1 Pro (High)"     (deep lap)
# So their availability both track the single `agy` binary. The standalone
# `gemini` CLI is no longer used (it stopped serving consumer requests on
# 2026-06-18). codex and kimi are unchanged.

set -euo pipefail

has() {
  command -v "$1" >/dev/null 2>&1 && return 0
  # Antigravity's installer drops `agy` in $HOME/.local/bin, which is often not
  # on $PATH for non-interactive shells. Fall back to a direct check so we don't
  # false-negative when the user installed via the official script and just
  # hasn't restarted their shell.
  [[ -x "$HOME/.local/bin/$1" ]]
}

codex=false
antigravity=false
gemini_pro=false
kimi=false

has codex && codex=true
# Both Gemini reviewers ride the same agy binary — but `agy --model` silently
# falls back to Flash on an unrecognized model string. So only report gemini-pro
# (the Pro lap) available if `agy models` actually lists a Gemini 3.1 Pro entry;
# otherwise a rename would make us run a 2nd Flash while claiming it was Pro.
if has agy; then
  antigravity=true
  if agy models 2>/dev/null | grep -qi 'Gemini 3.1 Pro'; then
    gemini_pro=true
  fi
fi
has kimi && kimi=true

printf '{"codex": %s, "antigravity": %s, "gemini-pro": %s, "kimi": %s}\n' \
  "$codex" "$antigravity" "$gemini_pro" "$kimi"
