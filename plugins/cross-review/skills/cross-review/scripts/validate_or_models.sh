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
#                         [--catalog <file>] [--pricing-json] [--strict-pricing]
#
#   --no-fetch  validate against the existing cache only, never hit the network
#               (used by the dispatch preflight — see the note at the fetch)
#   --strict  exit 1 when a slug is missing from the catalog (for CI/self-check)
#   --json    machine-readable report on stdout instead of WARN lines on stderr
#   --catalog <file>   path to the cached OpenRouter catalog (full `data[]`,
#                       with pricing) used for the pricing-drift check below.
#                       Defaults to $HOME/.cross-review/cache/or_catalog.json,
#                       which a network fetch (see --no-fetch) populates
#                       alongside the plain-id cache. Mainly for tests, which
#                       point it at a fixture instead of the real cache.
#   --pricing-json      machine-readable pricing-drift report on stdout, one
#                       JSON array: [{seat, model, profile, catalog, drift}]
#   --strict-pricing    exit 1 when any OpenRouter seat's pinned pricing
#                       drifted from the catalog (advisory otherwise — pricing
#                       drift never fails a round on its own)
#
# Pricing drift: for every OpenRouter seat with a non-null `pricing` in the
# profile and a slug present in the cached catalog, prompt_per_m and
# completion_per_m (USD per MILLION tokens) are compared against the
# catalog's per-token USD pricing (converted ×1,000,000). A component WARNs
# when |catalog − profile| > max(0.01, 5% of profile); the WARN names only
# the components that drifted. A seat with `pricing: null` and a catalog
# match gets an INFO line surfacing the catalog's numbers (so the nulls left
# by #121 get real numbers without this script ever rewriting the profile).
# Missing the catalog file entirely (no fetch has happened yet) means the
# pricing check is silently skipped — same offline-must-never-block posture
# as the slug check above.
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
catalog_override=""
pricing_json=0
strict_pricing=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --profiles)         profiles="$2"; shift 2 ;;
    --cache-ttl-hours)  cache_ttl_hours="$2"; shift 2 ;;
    --refresh)          refresh=1; shift ;;
    --no-fetch)         no_fetch=1; shift ;;
    --strict)           strict=1; shift ;;
    --json)             as_json=1; shift ;;
    --catalog)          catalog_override="$2"; shift 2 ;;
    --pricing-json)     pricing_json=1; shift ;;
    --strict-pricing)   strict_pricing=1; shift ;;
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
catalog="${catalog_override:-$cache_dir/or_catalog.json}"
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
  tmp_catalog="$catalog.tmp.$$"
  resp="$(curl -fsS --max-time 20 "https://openrouter.ai/api/v1/models" \
       -H "Authorization: Bearer $key" 2>/dev/null)"
  if [[ -n "$resp" ]] \
     && printf '%s' "$resp" | jq -r '.data[].id' >"$tmp" 2>/dev/null && [[ -s "$tmp" ]]; then
    mv "$tmp" "$cache"
    # Best-effort: the full catalog (with pricing) feeds the drift check
    # below. A failure here must not undo the slug-list cache we just wrote.
    if printf '%s' "$resp" | jq -c '.data' >"$tmp_catalog" 2>/dev/null && [[ -s "$tmp_catalog" ]]; then
      mv "$tmp_catalog" "$catalog"
    else
      rm -f "$tmp_catalog" 2>/dev/null || true
    fi
  else
    rm -f "$tmp" "$tmp_catalog" 2>/dev/null || true
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

# --- pricing drift -----------------------------------------------------
# Compare each OpenRouter seat's pinned pricing.{prompt,completion}_per_m
# against the cached catalog (USD/token, converted to USD/M). Skipped
# entirely when there is no catalog on disk (no fetch has happened yet) —
# same "stay quiet, never block" posture as the slug check above.
any_drift=0
if [[ -s "$catalog" ]] && jq -e . "$catalog" >/dev/null 2>&1; then
  pricing_data="$(jq -n --slurpfile p "$profiles" --slurpfile c "$catalog" '
    ($c[0] | map(select(.id != null) | {(.id): (.pricing // {})}) | add // {}) as $catmap
    | ($p[0] | to_entries
        | map(select((.value|type)=="object") | select(.value.cli=="openrouter")))
    | map(
        .key as $seat
        | .value.model as $model
        | .value.pricing as $pp
        | $catmap[$model] as $cat
        | if $cat == null then empty else
            (($cat.prompt // "0") | tonumber * 1000000) as $catp
            | (($cat.completion // "0") | tonumber * 1000000) as $catc
            | ($pp.prompt_per_m) as $profp
            | ($pp.completion_per_m) as $profc
            | (if $profp == null then false
               else (($catp - $profp) | fabs) > (if (0.05 * $profp) > 0.01 then 0.05 * $profp else 0.01 end)
               end) as $pdrift
            | (if $profc == null then false
               else (($catc - $profc) | fabs) > (if (0.05 * $profc) > 0.01 then 0.05 * $profc else 0.01 end)
               end) as $cdrift
            | {
                seat: $seat, model: $model,
                profile: {prompt: $profp, completion: $profc},
                catalog: {prompt: $catp, completion: $catc},
                has_profile_pricing: ($profp != null or $profc != null),
                prompt_drift: $pdrift, completion_drift: $cdrift,
                drift: ($pdrift or $cdrift)
              }
          end)
  ' 2>/dev/null)"
  if [[ -n "$pricing_data" ]]; then
    while IFS=$'\t' read -r seat model hasp profp profc catp catc pdrift cdrift; do
      [[ -n "$seat" ]] || continue
      catp_fmt="$(printf '%.2f' "$catp" 2>/dev/null)"
      catc_fmt="$(printf '%.2f' "$catc" 2>/dev/null)"
      if [[ "$hasp" == "false" ]]; then
        echo "INFO: $seat has no pricing in the profile; catalog says prompt $catp_fmt completion $catc_fmt /M" >&2
      else
        parts=()
        if [[ "$pdrift" == "true" ]]; then
          profp_fmt="$(printf '%.2f' "$profp" 2>/dev/null)"
          parts+=("prompt $profp_fmt → $catp_fmt /M (catalog)")
        fi
        if [[ "$cdrift" == "true" ]]; then
          profc_fmt="$(printf '%.2f' "$profc" 2>/dev/null)"
          parts+=("completion $profc_fmt → $catc_fmt /M (catalog)")
        fi
        if [[ ${#parts[@]} -gt 0 ]]; then
          any_drift=1
          joined="$(IFS=', '; echo "${parts[*]}")"
          echo "WARN: $seat pricing drift: $joined" >&2
        fi
      fi
    done < <(printf '%s' "$pricing_data" | jq -r '.[] | [.seat, .model, (.has_profile_pricing|tostring), (.profile.prompt // 0), (.profile.completion // 0), .catalog.prompt, .catalog.completion, (.prompt_drift|tostring), (.completion_drift|tostring)] | @tsv')
    if [[ "$pricing_json" -eq 1 ]]; then
      printf '%s' "$pricing_data" | jq -c 'map({seat, model, profile, catalog, drift})'
    fi
  fi
elif [[ "$pricing_json" -eq 1 ]]; then
  echo "[]"
fi

exit_code=0
[[ "$strict" -eq 1 && "$missing" -gt 0 ]] && exit_code=1
[[ "$strict_pricing" -eq 1 && "$any_drift" -eq 1 ]] && exit_code=1
exit "$exit_code"
