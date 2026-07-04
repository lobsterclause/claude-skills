#!/usr/bin/env bash
# detect_reviewers.sh — report which review CLIs are available.
# Prints JSON to stdout:
#   {"codex": bool, "antigravity": bool, "gemini-pro": bool, "kimi": bool,
#    "glm": bool, "deepseek": bool, "mimo": bool, "minimax": bool, "qwen": bool,
#    "devstral": bool, "laguna": bool, "kat": bool,
#    "north": bool, "nemotron": bool, "openrouter": bool}
#
# As of the 2026-06-18 Gemini-CLI consumer sunset, BOTH Gemini-family reviewers
# run on Google's `agy` (Antigravity) CLI:
#   - antigravity → agy --model "Gemini 3.5 Flash (High)"   (fast lap)
#   - gemini-pro  → agy --model "Gemini 3.1 Pro (High)"     (deep lap)
# So their availability both track the single `agy` binary. The standalone
# `gemini` CLI is no longer used (it stopped serving consumer requests on
# 2026-06-18). codex and kimi are unchanged.
#
# The OpenRouter pool (glm, deepseek, mimo, minimax, qwen, devstral, laguna,
# kat, north, nemotron)
# runs via the OpenRouter API — no CLI; all ten track the same condition:
# an OpenRouter key ($OPENROUTER_API_KEY or ~/.config/openrouter/key) + curl.
# `openrouter` reports that shared condition. NOTE: there is NO OpenRouter
# fallback for the first-party reviewers (policy, 2026-07-01) — a failed agy
# lap drops out of the round and roster rotation covers the gap.

set -euo pipefail

# Same PATH guard as run_reviewers.sh / select_roster.sh: without it, `has agy`
# succeeds via the direct ~/.local/bin fallback below but the bare `agy models`
# probe fails (127) and gemini-pro false-negatives — detection disagreeing with
# execution. codex+fugu convergent finding, PR #18 pass 1.
if [[ -d "$HOME/.local/bin" && ":$PATH:" != *":$HOME/.local/bin:"* ]]; then
  PATH="$HOME/.local/bin:$PATH"
fi

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
openrouter=false
kimi27=false

has codex && codex=true
# Both Gemini reviewers ride the same agy binary — but `agy --model` silently
# falls back to Flash on an unrecognized model string. So only report gemini-pro
# (the Pro lap) available if `agy models` actually lists a Gemini 3.1 Pro entry.
# The probe MUST be bounded and cached: an unhealthy agy (quota/auth) can hang
# `agy models` for minutes and it ignores SIGTERM (codex P2, PR #18 pass 2).
# Shares select_roster.sh's 6h cache; with no timeout binary available the
# probe is skipped and Pro is assumed available (matches execution — the
# wrapper pins the exact model string either way).
if has agy; then
  antigravity=true
  models_cache="$HOME/.cross-review/cache/agy_models.txt"
  if [[ ! -s "$models_cache" || -n "$(find "$models_cache" -mmin +360 2>/dev/null)" ]]; then
    TIMEOUT_BIN=""
    command -v timeout  >/dev/null 2>&1 && TIMEOUT_BIN="timeout"
    if [[ -z "$TIMEOUT_BIN" ]] && command -v gtimeout >/dev/null 2>&1; then TIMEOUT_BIN="gtimeout"; fi
    if [[ -z "$TIMEOUT_BIN" ]]; then
      for _tb in /opt/homebrew/bin/gtimeout /usr/local/bin/gtimeout; do
        if [[ -x "$_tb" ]]; then TIMEOUT_BIN="$_tb"; break; fi
      done
    fi
    if [[ -n "$TIMEOUT_BIN" ]]; then
      mkdir -p "$(dirname "$models_cache")"
      models_tmp="$models_cache.tmp.$$"
      if "$TIMEOUT_BIN" -k 5 15 agy models >"$models_tmp" 2>/dev/null; then
        mv "$models_tmp" "$models_cache"
      else
        rm -f "$models_tmp"
      fi
    fi
  fi
  if [[ -s "$models_cache" ]]; then
    if grep -qi 'Gemini 3.1 Pro' "$models_cache"; then gemini_pro=true; fi
  else
    gemini_pro=true
  fi
fi
has kimi && kimi=true

# OpenRouter key + curl → the whole OpenRouter reviewer pool lights up.
if command -v curl >/dev/null 2>&1; then
  if [[ -n "${OPENROUTER_API_KEY:-}" || -s "$HOME/.config/openrouter/key" ]]; then
    openrouter=true
  fi
  # kimi27 (k2.7-code rotation seat) rides the DIRECT Moonshot API — its own
  # key, independent of both the kimi CLI baseline and the OpenRouter pool.
  if [[ -n "${MOONSHOT_API_KEY:-}" || -s "$HOME/.config/moonshot/key" ]]; then
    kimi27=true
  fi
fi

printf '{"codex": %s, "antigravity": %s, "gemini-pro": %s, "kimi": %s, "glm": %s, "deepseek": %s, "mimo": %s, "minimax": %s, "qwen": %s, "devstral": %s, "laguna": %s, "kat": %s, "north": %s, "nemotron": %s, "kimi27": %s, "openrouter": %s}\n' \
  "$codex" "$antigravity" "$gemini_pro" "$kimi" \
  "$openrouter" "$openrouter" "$openrouter" "$openrouter" "$openrouter" "$openrouter" "$openrouter" "$openrouter" "$openrouter" "$openrouter" \
  "$kimi27" "$openrouter"
