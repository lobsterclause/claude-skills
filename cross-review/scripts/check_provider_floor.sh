#!/usr/bin/env bash
# check_provider_floor.sh — did this round actually have enough INDEPENDENT
# reviewers to be a cross-review?
#
# WHY
# ---
# SKILL.md states the floor twice — "Every round has at least 3 reviewers" and
# the three-provider convergence floor — and until now nothing checked either.
# It was prose, and prose lost. A census of the 25 rounds before 2026-09-01
# found rounds at 11:52 onward degrading to 2 of 4 dispatched reviewers
# returning output, every one of them still emitting a normal verdict: PR #3677
# was graded CLEAN on two seats, PR #173 reported NEEDS_DECISION on ONE. The
# cause that day was billing (OpenRouter credits exhausted, Moonshot balance
# suspended), but the defect is not billing-specific: a round has no way to
# notice it was thin, whatever thinned it.
#
# This is deliberately a POST-HOC check on what came back, not a pre-flight
# probe of what should work. A pre-flight probe only catches the failure mode it
# knows about; counting what actually returned catches every cause — billing,
# quota, timeout, an agy panic, a delisted model slug — and cannot be wrong
# about it, because it reads the bytes on disk.
#
# WHAT COUNTS
# -----------
# A seat "returned" when its meta.json reports output_bytes > 0. Seats are
# grouped into PROVIDERS via reviewer_profiles.json, because provider is the
# independence axis that matters: kimi + kimi27 + kimi3 are three seats and one
# brain. A first-party lane that fell back to OpenRouter keeps its own provider
# (policy: the fallback never changes .provider), so codex-via-OpenRouter is
# still one OpenAI vote and never a second independent one.
#
# Usage:
#   check_provider_floor.sh --meta-dir <run_dir/raw> [--floor N] [--profiles <json>] [--json]
#
# Exit: 0 floor met · 3 floor NOT met · 2 usage error
# Fails OPEN on a missing/unreadable meta dir (exit 0): this must never be the
# reason a round cannot report. It answers a question about evidence; with no
# evidence to read it declines to answer rather than inventing a verdict.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DEFAULT_PROFILES="$SCRIPT_DIR/../references/reviewer_profiles.json"

meta_dir=""; floor="${CROSS_REVIEW_PROVIDER_FLOOR:-3}"; profiles=""; as_json=0
while [ $# -gt 0 ]; do
  case "$1" in
    --meta-dir) meta_dir="${2:-}"; shift 2 ;;
    --floor)    floor="${2:-}";    shift 2 ;;
    --profiles) profiles="${2:-}"; shift 2 ;;
    --json)     as_json=1;         shift ;;
    -h|--help)  sed -n '2,36p' "$0"; exit 0 ;;
    *) echo "check_provider_floor: unknown arg '$1'" >&2; exit 2 ;;
  esac
done

[ -n "$meta_dir" ] || { echo "usage: $0 --meta-dir <run_dir/raw> [--floor N] [--profiles <json>] [--json]" >&2; exit 2; }
case "$floor" in ''|*[!0-9]*) echo "check_provider_floor: --floor must be a non-negative integer, got '$floor'" >&2; exit 2 ;; esac
[ -n "$profiles" ] || profiles="$DEFAULT_PROFILES"

emit() { # $1 json, $2 exit
  if [ "$as_json" = 1 ]; then printf '%s\n' "$1"; fi
  exit "$2"
}

# Fail open: no evidence to read is not a floor violation.
if [ ! -d "$meta_dir" ]; then
  emit "$(jq -nc --arg d "$meta_dir" '{skipped:true, reason:"meta dir not found: \($d)", meets_floor:true}')" 0
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "check_provider_floor: jq not found — skipping (fail open)" >&2
  emit '{"skipped":true,"reason":"jq unavailable","meets_floor":true}' 0
fi

# reviewer -> provider. Guard the map behind a readable profiles file; an
# unreadable one means we cannot group seats, which is not the same as a thin
# round, so it also fails open.
if [ ! -s "$profiles" ]; then
  echo "check_provider_floor: profiles not readable at $profiles — skipping (fail open)" >&2
  emit '{"skipped":true,"reason":"profiles unreadable","meets_floor":true}' 0
fi

# Iterate the KNOWN SEATS from profiles rather than globbing the directory.
# The raw dir holds artifacts that are not seats and must never be counted as
# one: `<seat>.primary-failed.meta.json` (the preserved first-party failure a
# fallback replaced), `<seat>.attempt<N>.meta.json` (per-retry artifacts), and
# `context.files.meta.json`. Globbing counted the preserved kimi failure as a
# returned seat under a synthetic "unknown" provider and turned a 1-provider
# round into a 2-provider one — an under-strict floor, which is the only
# direction that matters here. A whitelist cannot be fooled by an artifact name
# nobody has invented yet.
returned=""   # "seat<TAB>provider" lines
seats_all="$(jq -r 'to_entries[] | select(.value|type=="object") | select(.value.provider != null) | .key' "$profiles" 2>/dev/null)"
while IFS= read -r seat; do
  [ -n "$seat" ] || continue
  f="$meta_dir/$seat.meta.json"
  [ -f "$f" ] || continue
  bytes="$(jq -r '.output_bytes // 0' "$f" 2>/dev/null)"
  case "$bytes" in ''|*[!0-9]*) bytes=0 ;; esac
  [ "$bytes" -gt 0 ] || continue
  prov="$(jq -r --arg s "$seat" '(.[$s].provider) // empty' "$profiles" 2>/dev/null)"
  [ -n "$prov" ] || continue
  returned="$returned$seat	$prov"$'\n'
done <<EOF
$seats_all
EOF

seats_returned=$(printf '%s' "$returned" | grep -c . || true)
provider_list="$(printf '%s' "$returned" | awk -F'\t' 'NF>1{print $2}' | sort -u | paste -sd, - 2>/dev/null)"
providers_returned=$(printf '%s' "$returned" | awk -F'\t' 'NF>1{print $2}' | sort -u | grep -c . || true)
seat_list="$(printf '%s' "$returned" | awk -F'\t' 'NF>1{print $1}' | sort | paste -sd, - 2>/dev/null)"

meets=true; rc=0
if [ "$providers_returned" -lt "$floor" ]; then meets=false; rc=3; fi

out="$(jq -nc \
  --argjson pr "$providers_returned" --argjson sr "$seats_returned" \
  --argjson fl "$floor" --argjson meets "$meets" \
  --arg pl "$provider_list" --arg sl "$seat_list" \
  '{providers_returned:$pr, seats_returned:$sr, floor:$fl, meets_floor:$meets,
    providers: ($pl|select(length>0)|split(",")), seats: ($sl|select(length>0)|split(","))}')"

if [ "$meets" = false ]; then
  printf 'check_provider_floor: FLOOR NOT MET — %s provider(s) returned output, need %s.\n' \
    "$providers_returned" "$floor" >&2
  printf '  returned: %s\n' "${seat_list:-<none>}" >&2
  printf '  This round is not a cross-review. Report it BLOCKED and do not stamp the PR.\n' >&2
fi

emit "$out" "$rc"
