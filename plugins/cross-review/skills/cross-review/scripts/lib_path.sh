#!/usr/bin/env bash
# lib_path.sh — put the reviewer CLIs on $PATH. Source this; do not execute it.
#
# WHY THIS IS SHARED
# ------------------
# Three scripts need the same two PATH fixups, and for most of this skill's
# life each carried its own copy:
#
#   detect_reviewers.sh   ~/.local/bin  +  nvm bin
#   select_roster.sh      ~/.local/bin  only
#   run_reviewers.sh      ~/.local/bin  only
#
# The nvm half was never copied forward, so `detect_reviewers.sh` reported
# codex and kimi available (it resolves nvm) while `select_roster.sh` decided
# they were not installed (bare `command -v`) and `run_reviewers.sh` could not
# have executed them anyway. Detection disagreed with both selection and
# execution, in the same direction, silently.
#
# Measured 2026-08-26 (kindred-mama-ai, five re-review rounds): every one of
# five draws came back WITHOUT codex while detect_reviewers.sh printed
# `"codex": true` and exited 0. The rounds looked healthy — four seats each,
# the rotation count silently raised to compensate for the "missing" baseline.
#
# This is the same shape as the 2026-08-14 incident the fail-closed guard in
# detect_reviewers.sh was written for (nine consecutive rounds with no codex),
# recurring one layer below that guard. A guard that a PATH difference can walk
# around is not a guard, so the resolution now lives in exactly one place.
#
# WHAT IT FIXES
# -------------
# 1. ~/.local/bin — where Antigravity's installer drops `agy`. Frequently
#    absent from $PATH in non-interactive shells.
# 2. The nvm bin dir — codex and kimi are npm globals installed under
#    $NVM_DIR/versions/node/<version>/bin. nvm is a shell FUNCTION sourced
#    from an rc file; it never runs in a non-interactive shell, so that
#    directory is not on $PATH no matter how correct the install is.
#
# Both fixups are idempotent and prepend-only: sourcing twice is a no-op, and
# nothing already on $PATH is removed or reordered.
#
# Exports: PATH (modified in place), and CROSS_REVIEW_NVM_BIN for callers that
# want the resolved directory itself (detect_reviewers.sh uses it for a direct
# -x fallback when a binary is present but the shell still will not resolve it).

if [[ -d "$HOME/.local/bin" && ":$PATH:" != *":$HOME/.local/bin:"* ]]; then
  PATH="$HOME/.local/bin:$PATH"
fi

CROSS_REVIEW_NVM_BIN=""
_cr_nvm_root="${NVM_DIR:-$HOME/.nvm}"
if [[ -d "$_cr_nvm_root/versions/node" ]]; then
  # alias/default may hold a bare major ("22") or a full version ("v22.22.2").
  _cr_default="$(cat "$_cr_nvm_root/alias/default" 2>/dev/null || true)"
  if [[ -n "$_cr_default" ]]; then
    for _cr_d in "$_cr_nvm_root/versions/node/${_cr_default}/bin" \
                 "$_cr_nvm_root/versions/node/v${_cr_default}".*/bin; do
      if [[ -d "$_cr_d" ]]; then CROSS_REVIEW_NVM_BIN="$_cr_d"; break; fi
    done
  fi
  if [[ -z "$CROSS_REVIEW_NVM_BIN" ]]; then
    # No usable default alias — fall back to the highest installed version.
    _cr_d="$(ls -d "$_cr_nvm_root"/versions/node/*/bin 2>/dev/null | sort -V | tail -1 || true)"
    if [[ -n "$_cr_d" ]]; then CROSS_REVIEW_NVM_BIN="$_cr_d"; fi
  fi
fi
if [[ -n "$CROSS_REVIEW_NVM_BIN" && ":$PATH:" != *":$CROSS_REVIEW_NVM_BIN:"* ]]; then
  PATH="$CROSS_REVIEW_NVM_BIN:$PATH"
fi
unset _cr_nvm_root _cr_default _cr_d
export PATH CROSS_REVIEW_NVM_BIN
