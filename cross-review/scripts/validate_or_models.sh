#!/usr/bin/env bash
# validate_or_models.sh — check every API-lane model slug in
# references/reviewer_profiles.json against OpenRouter's live catalog.
#
# WHY: a model slug can be delisted upstream with no warning. The reviewer then
# fails with a 404 in ~1s and the round quietly loses a vote — it reads as
# reviewer flakiness, not as a config problem. Two slugs were dead when this was
# written (2026-08-03): `poolside/laguna-m.1` had already burned a round, and
# `mistralai/devstral-2512` was queued to burn the next one it was drawn for.
#
# Advisory by design: prints WARN lines to stderr, exits 0 unless --strict.
# A catalog fetch that fails (offline, no key, rate limit) is NOT a validation
# failure — it prints nothing and exits 0, because a network hiccup must never
# block a review round.
#
# Usage:
#   validate_or_models.sh [--profiles <file>] [--cache-ttl-hours <n>]
#                         [--refresh] [--strict] [--json]
#
#   --no-fetch  validate against the existing cache only, never hit the network
#               (used by the dispatch preflight — see the note at the fetch)
#   --strict  exit 1 when a slug is missing from the catalog (for CI/self-check)
#   --json    machine-readable report on stdout instead of WARN lines on stderr
#
# Only reviewers whose profile `cli` is `openrouter` are checked; the direct
# Moonshot seats (kimi27/kimi3) and the CLI lanes have no OpenRouter catalog to
# check against.
set -uo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
profiles="$script_dir/../references/reviewer_profiles.json"
cache_ttl_hours=24
refresh=0
no_fetch=0
strict=0
as_json=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --profiles)         profiles="$2"; shift 2 ;;
    --cache-ttl-hours)  cache_ttl_hours="$2"; shift 2 ;;
    --refresh)          refresh=1; shift ;;
    --no-fetch)         no_fetch=1; shift ;;
    --strict)           strict=1; shift ;;
    --json)             as_json=1; shift ;;
    -h|--help)          sed -n '2,25p' "$0"; exit 0 ;;
    *)                  echo "unknown flag: $1" >&2; exit 2 ;;
  esac
done

command -v jq >/dev/null 2>&1 || exit 0          # no jq → nothing to validate with
[[ -f "$profiles" ]] || exit 0

key="${OPENROUTER_API_KEY:-}"
[[ -z "$key" && -s "$HOME/.config/openrouter/key" ]] && key="$(tr -d '[:space:]' <"$HOME/.config/openrouter/key")"
[[ -n "$key" ]] || exit 0                        # no key → the pool is unusable anyway

cache_dir="$HOME/.cross-review/cache"
cache="$cache_dir/or_models.txt"
mkdir -p "$cache_dir" 2>/dev/null || true

# Same bounded-probe discipline as select_roster.sh's `agy models` guard: a slow
# or hanging endpoint must not stall a round.
# --no-fetch: validate against whatever is already cached and never touch the
# network. This is what the dispatch path uses — a preflight check must not put
# a synchronous HTTP round-trip (or a shimmed curl, in the test harness) in
# front of the reviewers it is about to launch. A cold cache there simply means
# no warning this round; the cache gets warmed by the explicit health-check step
# or any --refresh run.
if [[ "$no_fetch" -eq 0 ]] && \
   [[ "$refresh" -eq 1 || ! -s "$cache" || -n "$(find "$cache" -mmin "+$((cache_ttl_hours * 60))" 2>/dev/null)" ]]; then
  tmp="$cache.tmp.$$"
  if curl -fsS --max-time 20 "https://openrouter.ai/api/v1/models" \
       -H "Authorization: Bearer $key" 2>/dev/null \
     | jq -r '.data[].id' >"$tmp" 2>/dev/null && [[ -s "$tmp" ]]; then
    mv "$tmp" "$cache"
  else
    rm -f "$tmp" 2>/dev/null || true
  fi
fi
[[ -s "$cache" ]] || exit 0                      # fetch failed and no cache → stay quiet

missing=0
report="[]"
while IFS=$'\t' read -r slug model; do
  [[ -n "$model" ]] || continue
  if grep -Fxq "$model" "$cache" 2>/dev/null; then
    status="ok"
  else
    status="missing"
    missing=$((missing + 1))
  fi
  if [[ "$as_json" -eq 1 ]]; then
    report="$(printf '%s' "$report" | jq --arg r "$slug" --arg m "$model" --arg s "$status" \
      '. + [{reviewer: $r, model: $m, status: $s}]')"
  elif [[ "$status" == "missing" ]]; then
    echo "WARN: reviewer '$slug' points at '$model', which is not in OpenRouter's catalog — that seat will fail with a 404 and drop out of any round it is drawn for. Fix the \`model\` field in $profiles (see https://openrouter.ai/models)." >&2
  fi
done < <(jq -r 'to_entries[] | select((.value|type)=="object") | select(.value.cli=="openrouter") | "\(.key)\t\(.value.model // "")"' "$profiles" 2>/dev/null)

if [[ "$as_json" -eq 1 ]]; then
  printf '%s' "$report" | jq -c --argjson missing "$missing" '{missing: $missing, models: .}'
fi

[[ "$strict" -eq 1 && "$missing" -gt 0 ]] && exit 1
exit 0
