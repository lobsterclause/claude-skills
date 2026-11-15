#!/usr/bin/env bash
# lib_agy_routes.sh — is any model on gemini-pro's router offered by
# `agy models`? Sourced by detect_reviewers.sh and select_roster.sh so the two
# availability checks cannot drift apart.
#
# The model names live ONLY in references/reviewer_profiles.json
# (.gemini-pro.routes + .router, plus .model). This file hardcodes none.
#
# `agy models` prints either display names ("Gemini 4 Hydrogen (High)") or slugs
# ("gemini-4-hydrogen-high") depending on the agy version (1.1.10 switched), so
# each route name is matched in both shapes, case-insensitively.
#
#   agy_routes_listed <models-cache-file> <profiles-file>
#     exit 0 when at least one routed model is listed; 1 otherwise (including
#     an unreadable profile or no jq — callers decide what "unknown" means).

#   agy_model_listed <models-cache-file> <display-name>
#     exit 0 when that one model is listed (display name or slug). run_reviewers.sh
#     uses it to check the model the router ACTUALLY picked, not just "any route".
agy_model_listed() {
  local cache="$1" name="$2" slug esc cand
  [[ -s "$cache" && -n "$name" ]] || return 1
  slug="$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]' | sed -E 's/[()]//g; s/[[:space:]]+/-/g')"
  # Match at identifier boundaries, not as a substring: a listed
  # "gemini-4-argon-high-preview" must not read as "gemini-4-argon-high"
  # (agy would then silently serve its default model for the unlisted one).
  for cand in "$name" "$slug"; do
    esc="$(printf '%s' "$cand" | sed -E 's/[][\\.^$*+?(){}|\/-]/\\&/g')"
    grep -Eqi -- "(^|[^[:alnum:]_.-])${esc}($|[^[:alnum:]_.-])" "$cache" 2>/dev/null && return 0
  done
  return 1
}

agy_routes_listed() {
  local cache="$1" profile="$2" name
  [[ -s "$cache" && -f "$profile" ]] || return 1
  command -v jq >/dev/null 2>&1 || return 1
  # Only the models run_reviewers.sh can pick WITHOUT an override: the router's
  # own targets (or the plain .model when there is no router). Advertising a
  # seat whose only listed model is one the router never selects (e.g. argon:low)
  # would admit a round that then dispatches an unlisted model.
  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    agy_model_listed "$cache" "$name" && return 0
  done < <(jq -r '.["gemini-pro"] as $g
    | (if ($g.router | type) == "object" then
         [$g.router.pass1, $g.router.pass1_small, $g.router.pass2, $g.router.pass3_plus] | map($g.routes[.])
       else [$g.model] end)
    | .[] | select(. != null)' "$profile" 2>/dev/null)
  return 1
}
