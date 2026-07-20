#!/usr/bin/env bash
# check_recurrence.sh — deterministically classify findings from the current
# review pass against one or more previous passes' findings.json, so
# SKILL.md's re-review loop (step 6, "the same finding recurs across passes
# -> stop and ask the user") can key off a computed verdict instead of
# eyeballing diffs across runs by hand.
#
# Pure bash + jq. No network, no LLM calls, no reviewer CLIs.
#
# Usage:
#   check_recurrence.sh --current <findings.json> \
#                        --previous <findings.json> [--previous <findings.json> ...]
#
# findings.json shape (fingerprinted; unchanged from fingerprint/anchor/
# factcheck's output): { "findings": [ {id, file, claim, ...,
# factcheck: {verdict: "keep"|"drop", ...}?}, ... ] }. A bare top-level
# array is also accepted (same convention as report_block.sh).
#
# --previous is ordered and repeatable: the FIRST one given is pass 1 (the
# oldest), the second pass 2, etc. — 1-based, matching how a caller
# accumulates prior findings.json files pass-by-pass through a re-review
# loop. At least one --previous is required.
#
# Output (stdout, jq -S canonical/sorted key order — deterministic):
#   {
#     "recurring": [ <current finding fields> + {passes_seen, first_seen_pass}, ... ],
#     "fresh":     [ <id>, ... ],
#     "resolved":  [ <id>, ... ],
#     "revenant":  [ <id>, ... ],
#     "summary": {"recurring": N, "fresh": N, "resolved": N, "revenant": N,
#                 "verdict": "ok"|"recurrence_detected"}
#   }
#
# Classification (per current-finding id):
#   - not seen in ANY previous pass                              -> fresh
#   - seen in >=1 previous pass, NOT all-dropped there            -> recurring
#     (passes_seen = # of previous passes the id appeared in;
#      first_seen_pass = lowest such pass number)
#   - seen in >=1 previous pass, factcheck.verdict=="drop" in
#     EVERY previous pass where it appeared                       -> revenant
#     (vetoed by factcheck, not fixed by anyone — must NOT count as
#     recurring and must NOT trip the stop-and-ask verdict)
#   - id seen in any previous pass but absent from current        -> resolved
#
# summary.verdict is "recurrence_detected" iff recurring is non-empty;
# revenant/fresh/resolved never trip it on their own.
#
# Exit: 0 whenever all inputs parse (the verdict itself is data, not an
# error). 2 on missing/unknown args, a missing --previous, an unreadable
# file, or invalid JSON — always with a clear stderr message. This script
# deliberately never uses exit 1: every input problem is a usage/validation
# error, so 2 is used uniformly.

set -uo pipefail

current="" ; previous_files=()

need_val() { [[ "$2" -lt 2 ]] && { echo "check_recurrence: missing value for $1" >&2; exit 2; }; }
while [[ $# -gt 0 ]]; do
  case "$1" in
    --current)  need_val "$1" "$#"; current="$2";               shift 2 ;;
    --previous) need_val "$1" "$#"; previous_files+=("$2");     shift 2 ;;
    *) echo "check_recurrence: unknown arg: $1" >&2; exit 2 ;;
  esac
done

usage="usage: $0 --current <findings.json> --previous <findings.json> [--previous <findings.json> ...]"

if [[ -z "$current" ]]; then
  echo "check_recurrence: --current is required" >&2
  echo "$usage" >&2
  exit 2
fi
if [[ "${#previous_files[@]}" -eq 0 ]]; then
  echo "check_recurrence: at least one --previous <findings.json> is required" >&2
  echo "$usage" >&2
  exit 2
fi

command -v jq >/dev/null 2>&1 || { echo "check_recurrence: jq required" >&2; exit 2; }

tmp_dir="$(mktemp -d)"; trap 'rm -rf "$tmp_dir"' EXIT

validate_json() {
  local f="$1" label="$2"
  if [[ ! -f "$f" ]]; then
    echo "check_recurrence: $label file not found: $f" >&2
    exit 2
  fi
  if ! jq empty "$f" >/dev/null 2>"$tmp_dir/jqerr.txt"; then
    echo "check_recurrence: $label file is not valid JSON: $f ($(cat "$tmp_dir/jqerr.txt"))" >&2
    exit 2
  fi
}

# Extract the findings array (object with .findings, or a bare array),
# dropping any entry missing an id (nothing to key recurrence on).
normalize() {
  local f="$1" out="$2" label="$3"
  if ! jq -c '
        (if type == "object" then (.findings // [])
         elif type == "array" then .
         else error("expected an object with .findings or a bare array") end)
        | if (type != "array") then error("findings is not an array") else . end
        | map(select(.id != null))
      ' "$f" > "$out" 2>"$tmp_dir/jqerr2.txt"; then
    echo "check_recurrence: $label: could not read findings from $f ($(cat "$tmp_dir/jqerr2.txt"))" >&2
    exit 2
  fi
}

validate_json "$current" "--current"
normalize "$current" "$tmp_dir/current.json" "--current"

prev_norm_files=()
idx=0
for f in "${previous_files[@]}"; do
  idx=$((idx + 1))
  validate_json "$f" "--previous (pass $idx)"
  norm="$tmp_dir/prev_${idx}.json"
  normalize "$f" "$norm" "--previous (pass $idx)"
  prev_norm_files+=("$norm")
done

# previous_all.json: array of arrays, one per pass, in --previous order.
jq -s '.' "${prev_norm_files[@]}" > "$tmp_dir/previous_all.json"

read -r -d '' JQ_PROGRAM <<'JQ_EOF' || true
($current_arr[0]) as $current
| ($previous_arr[0]) as $previous
| ($previous | to_entries | map({pass: (.key + 1), findings: .value})) as $passes
| ([ $passes[] as $p | $p.findings[] | {id: .id, pass: $p.pass, verdict: (.factcheck.verdict // null)} ]) as $prev_occ
| ($prev_occ | group_by(.id) | map({key: .[0].id, value: (map({pass, verdict}))}) | from_entries) as $prev_by_id
| ($current | map(.id)) as $current_ids
| (
    $current
    | map(
        . as $f
        | ($prev_by_id[$f.id] // []) as $occ
        | ($occ | length) as $n
        | if $n == 0 then
            {kind: "fresh", id: $f.id}
          elif ($occ | all(.verdict == "drop")) then
            {kind: "revenant", id: $f.id}
          else
            {kind: "recurring",
             finding: ($f + {passes_seen: $n, first_seen_pass: ($occ | map(.pass) | min)})}
          end
      )
  ) as $classified
| ([$classified[] | select(.kind == "recurring") | .finding] | sort_by(.id)) as $recurring
| ([$classified[] | select(.kind == "fresh") | .id] | sort) as $fresh
| ([$classified[] | select(.kind == "revenant") | .id] | sort) as $revenant
| (($prev_by_id | keys) - $current_ids | sort) as $resolved
| {
    recurring: $recurring,
    fresh: $fresh,
    resolved: $resolved,
    revenant: $revenant,
    summary: {
      recurring: ($recurring | length),
      fresh: ($fresh | length),
      resolved: ($resolved | length),
      revenant: ($revenant | length),
      verdict: (if ($recurring | length) > 0 then "recurrence_detected" else "ok" end)
    }
  }
JQ_EOF

if ! jq -n -S \
    --slurpfile current_arr "$tmp_dir/current.json" \
    --slurpfile previous_arr "$tmp_dir/previous_all.json" \
    "$JQ_PROGRAM" > "$tmp_dir/result.json" 2>"$tmp_dir/jqerr3.txt"; then
  echo "check_recurrence: internal computation failed ($(cat "$tmp_dir/jqerr3.txt"))" >&2
  exit 2
fi

cat "$tmp_dir/result.json"
exit 0
