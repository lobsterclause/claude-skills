#!/usr/bin/env bash
# lib_agy_routes.sh — is any model on gemini-pro's router offered by
# `agy models`? Sourced by detect_reviewers.sh and select_roster.sh so the two
# availability checks cannot drift apart.
#
# The model names live ONLY in references/reviewer_profiles.json
# (.gemini-pro.routes, plus .model). This file hardcodes none.
#
# `agy models` prints either display names ("Gemini 4 Hydrogen (High)") or slugs
# ("gemini-4-hydrogen-high") depending on the agy version (1.1.10 switched), so
# each route name is matched in both shapes, case-insensitively.
#
#   agy_routes_listed <models-cache-file> <profiles-file>
#     exit 0 when at least one routed model is listed; 1 otherwise (including
#     an unreadable profile or no jq — callers decide what "unknown" means).

agy_routes_listed() {
  local cache="$1" profile="$2" name slug
  [[ -s "$cache" && -f "$profile" ]] || return 1
  command -v jq >/dev/null 2>&1 || return 1
  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    slug="$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]' | sed -E 's/[()]//g; s/[[:space:]]+/-/g')"
    if grep -Fqix -- "$name" "$cache" 2>/dev/null \
       || grep -Fqi -- "$name" "$cache" 2>/dev/null \
       || grep -Fqi -- "$slug" "$cache" 2>/dev/null; then
      return 0
    fi
  done < <(jq -r '.["gemini-pro"] | ([.model] + ((.routes // {}) | [.[]])) | .[] | select(. != null)' "$profile" 2>/dev/null)
  return 1
}
