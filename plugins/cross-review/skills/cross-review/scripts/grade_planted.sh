#!/usr/bin/env bash
# grade_planted.sh — score each roster seat's catch of a planted mutation
# (see plant_mutation.sh) by LOCATION, not by fingerprint id.
#
# WHY location, not id: fingerprint_findings.sh hashes claim TEXT
# (project|file|claim), so the planted defect's own synthetic id never equals
# a reviewer's wording of the same bug — two different reviewers describing
# the same planted defect in different words mint two different fingerprint
# ids, and neither equals the planted site's identity. So catching is scored
# by whether a seat reported a finding anchored at (or claimed at) the
# planted (file, line) +/- a window, not by id equality.
#
# Matching rule: a finding is a CANDIDATE for the planted defect when
#   .file == planted.file
#   AND effective_line in [line_range[0]-window, line_range[1]+window]
# where effective_line = .anchor.start_line when .anchor.resolved == true,
# else .line (mirrors anchor_findings.sh's correction of "line" on resolve).
# A roster seat CATCHES the planted defect when it appears in .sources[] of
# ANY candidate finding (first candidate encountered wins for that seat's
# matched_finding_id / severity_called). A seat with no matching finding
# across the whole roster call is MISSED — a seat that never ran (not in
# --roster) is not counted at all in either bucket, since it never had a
# chance to see the diff.
#
# Severity scoring: severity_accuracy is 1.0 when the seat's called severity
# on the matched finding equals planted.expected_severity, else 0.5 for ANY
# mismatch (both an under-call by one level and an over-call score the same
# 0.5 -- this is a recall/calibration drill, not a precision ladder, so we
# don't reward being "close"; see the issue #97 proposal). Severity rank
# order (informational only, not consulted by the 1.0/0.5 rule above):
#   Critical > High > Medium > Low
#
# Synthetic id: f-planted-<first 8 hex of SHA1("project|file|operator@line")>
# where line = line_range[0]. Reuses the exact hash tool fallback chain
# fingerprint_findings.sh uses (shasum -a 1 / sha1sum / openssl dgst -sha1)
# so the two scripts agree on the hash function -- fingerprint_findings.sh
# hashes with SHA-1 (shasum -a 1), not SHA-256, despite the "sha256" word in
# the issue #97 proposal text; matching the ACTUAL tool fingerprint uses
# (per the proposal's own "reuse the hashing utility fingerprint_findings.sh
# uses ... match it" instruction) takes precedence over that literal word.
#
# --judge agy|openrouter (a per-candidate factcheck-lane "does this describe
# the planted defect?" call) is NOT wired in this pass -- exits 3 with a
# clear message. Only --judge none (location match only, the default) works
# today. See the PR / FOLLOW_UP_ISSUE for wiring judge lanes.
#
# Usage:
#   grade_planted.sh --planted <planted.json> --findings <findings.anchored.json>
#                     --roster a,b,c
#                     [--run-id ID] [--project NAME | --repo-root DIR]
#                     [--window N] [--judge none|agy|openrouter]
#                     --out <grade.json> [--emit-events]
#
#   --planted PATH     planted.json from plant_mutation.sh (required)
#   --findings PATH    findings.anchored.json -- the findings[] array with
#                       file/line/severity/sources[]/optional anchor
#                       (required)
#   --roster a,b,c      every seat that ran this round, comma-separated
#                       (required) -- a seat with no matching finding is
#                       scored "missed"
#   --run-id ID         default: planted.run_id
#   --project NAME      literal fingerprint namespace (mutually exclusive
#                       with --repo-root; same contract as
#                       fingerprint_findings.sh)
#   --repo-root DIR     derive the namespace from repo identity, like
#                       fingerprint_findings.sh --repo-root does
#   --window N          line-range slop in each direction (default 3)
#   --judge MODE        none (default, location match only) | agy |
#                       openrouter (NOT wired -- exit 3)
#   --out PATH          where to write grade.json (required)
#   --emit-events        append planted/caught/missed events to
#                       finding_events.jsonl via append_finding_event.sh
#                       (respects $CROSS_REVIEW_FINDING_EVENTS, like that
#                       script does)
#
# grade.json shape:
#   { schema_version: 1, synthetic: true, run_id, planted_id,
#     planted: {file, line_range, operator, class, expected_severity},
#     caught: [{reviewer, matched_finding_id, severity_called, severity_accuracy}],
#     missed: [reviewer, ...],
#     candidates: [finding id, ...],
#     recall: caught_count / (caught_count + missed_count), 2 decimal places }
#
# Exit: 0 on a successful grade (always, even 0 caught); 2 on bad usage or
# unreadable input files; 3 if --judge is agy/openrouter (not wired yet).

set -uo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib_project_namespace.sh
source "$script_dir/lib_project_namespace.sh"

planted="" ; findings="" ; roster="" ; run_id="" ; project="" ; repo_root=""
window=3 ; judge="none" ; out="" ; emit_events=0

need_val() { [[ "$2" -lt 2 ]] && { echo "missing value for $1" >&2; exit 2; }; }
while [[ $# -gt 0 ]]; do
  case "$1" in
    --planted)     need_val "$1" "$#"; planted="$2";     shift 2 ;;
    --findings)    need_val "$1" "$#"; findings="$2";    shift 2 ;;
    --roster)      need_val "$1" "$#"; roster="$2";      shift 2 ;;
    --run-id)      need_val "$1" "$#"; run_id="$2";      shift 2 ;;
    --project)     need_val "$1" "$#"; project="$2";     shift 2 ;;
    --repo-root)   need_val "$1" "$#"; repo_root="$2";   shift 2 ;;
    --window)      need_val "$1" "$#"; window="$2";      shift 2 ;;
    --judge)       need_val "$1" "$#"; judge="$2";       shift 2 ;;
    --out)         need_val "$1" "$#"; out="$2";         shift 2 ;;
    --emit-events) emit_events=1;                        shift ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

usage="usage: $0 --planted <json> --findings <json> --roster a,b,c (--project <name> | --repo-root <dir>) [--run-id <id>] [--window <n>] [--judge none|agy|openrouter] --out <json> [--emit-events]"

[[ -n "$planted" && -n "$findings" && -n "$roster" && -n "$out" ]] || { echo "$usage" >&2; exit 2; }
[[ -f "$planted"  ]] || { echo "grade_planted: planted file not found: $planted" >&2; exit 2; }
[[ -f "$findings" ]] || { echo "grade_planted: findings file not found: $findings" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "grade_planted: jq required" >&2; exit 2; }
[[ "$window" =~ ^(0|[1-9][0-9]*)$ ]] || { echo "grade_planted: --window must be a non-negative integer (got '$window')" >&2; exit 2; }
# A malformed findings file must not grade as "everyone missed" (codex + kimi,
# PR #114 review): require a .findings array of objects up front.
jq -e '.findings | type == "array" and all(.[]; type == "object")' "$findings" >/dev/null 2>&1 \
  || { echo "grade_planted: $findings must contain a .findings array of objects" >&2; exit 2; }

case "$judge" in
  none) ;;
  agy|openrouter)
    echo "grade_planted: --judge $judge is not wired yet (location-match-only for now; see FOLLOW_UP_ISSUE)" >&2
    exit 3
    ;;
  *) echo "grade_planted: --judge must be none|agy|openrouter (got '$judge')" >&2; exit 2 ;;
esac

if [[ -n "$project" && -n "$repo_root" ]]; then
  echo "grade_planted: --project and --repo-root are mutually exclusive (pick one namespace source)" >&2
  exit 2
fi
if [[ -n "$repo_root" ]]; then
  [[ -d "$repo_root" ]] || { echo "grade_planted: --repo-root not a directory: $repo_root" >&2; exit 2; }
  project="$(derive_project "$repo_root")"
fi
[[ -n "$project" ]] || { echo "grade_planted: give --project <name> or --repo-root <dir>" >&2; exit 2; }

[[ -z "$run_id" ]] && run_id="$(jq -r '.run_id // ""' "$planted")"
[[ -n "$run_id" ]] || { echo "grade_planted: no --run-id and planted.json has no run_id" >&2; exit 2; }

# Portable SHA-1: same fallback chain as fingerprint_findings.sh, so the two
# scripts agree on the hash function.
if command -v shasum >/dev/null 2>&1; then
  sha1_of() { shasum -a 1 | awk '{print $1}'; }
elif command -v sha1sum >/dev/null 2>&1; then
  sha1_of() { sha1sum | awk '{print $1}'; }
elif command -v openssl >/dev/null 2>&1; then
  sha1_of() { openssl dgst -sha1 -r | awk '{print $1}'; }
else
  echo "grade_planted: no sha1 tool found (need shasum, sha1sum, or openssl)" >&2
  exit 2
fi

p_file="$(jq -r '.file // ""' "$planted")"
p_operator="$(jq -r '.operator // ""' "$planted")"
p_class="$(jq -r '.class // ""' "$planted")"
p_expected_severity="$(jq -r '.expected_severity // ""' "$planted")"
p_line0="$(jq -r '.line_range[0] // empty' "$planted")"
p_line1="$(jq -r '.line_range[1] // empty' "$planted")"
[[ -n "$p_file" && -n "$p_line0" && -n "$p_line1" ]] || { echo "grade_planted: planted.json missing file/line_range" >&2; exit 2; }
[[ "$p_line0" =~ ^[1-9][0-9]*$ && "$p_line1" =~ ^[1-9][0-9]*$ && "$p_line0" -le "$p_line1" ]] \
  || { echo "grade_planted: planted.json line_range must be two positive integers, low <= high (got [$p_line0, $p_line1])" >&2; exit 2; }

planted_norm="$(printf '%s\x1f%s\x1f%s@%s' "$project" "$p_file" "$p_operator" "$p_line0")"
planted_hash="$(printf '%s' "$planted_norm" | sha1_of)"
planted_id="f-planted-${planted_hash:0:8}"

low=$(( p_line0 - window ))
high=$(( p_line1 + window ))

tmp_dir="$(mktemp -d)"; trap 'rm -rf "$tmp_dir"' EXIT
cand_jsonl="$tmp_dir/candidates.jsonl"
: > "$cand_jsonl"

skipped_no_id=0
while IFS= read -r f; do
  file="$(jq -r '.file // ""' <<<"$f")"
  [[ "$file" == "$p_file" ]] || continue
  # a candidate without an id cannot be reported as matched_finding_id (kimi)
  if [[ "$(jq -r '.id // ""' <<<"$f")" == "" ]]; then skipped_no_id=$((skipped_no_id + 1)); continue; fi
  resolved="$(jq -r '.anchor.resolved // false' <<<"$f")"
  if [[ "$resolved" == "true" ]]; then
    eff_line="$(jq -r '.anchor.start_line // 0' <<<"$f")"
  else
    eff_line="$(jq -r '.line // 0' <<<"$f")"
  fi
  # line 0 / unknown line is "no location", never a match -- with a mutation
  # planted near line 1 the window reaches <= 0 and an unanchored finding
  # would otherwise land inside it (antigravity, PR #114 review)
  [[ "$eff_line" =~ ^[1-9][0-9]*$ ]] || continue
  if [[ "$eff_line" -ge "$low" && "$eff_line" -le "$high" ]]; then
    jq -c '.' <<<"$f" >> "$cand_jsonl"
  fi
done < <(jq -c '.findings[]' "$findings")
[[ "$skipped_no_id" -gt 0 ]] && echo "grade_planted: WARN skipped $skipped_no_id finding(s) at the planted file with no id" >&2

# Dedup candidate ids for the output "candidates" list, preserving first-seen order.
candidates_json="$(jq -c -s '[.[].id] | reduce .[] as $id ([]; if index($id) then . else . + [$id] end)' "$cand_jsonl" 2>/dev/null || echo '[]')"
[[ -z "$candidates_json" ]] && candidates_json='[]'

caught_json="[]"
missed_json="[]"
# roster: trim whitespace and dedupe, so "codex, kimi" matches sources and
# "codex,codex" does not double-count (kimi + antigravity, PR #114 review)
roster_arr=()
while IFS= read -r seat; do
  [[ -n "$seat" ]] && roster_arr+=("$seat")
done < <(printf '%s' "$roster" | tr ',' '\n' | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//' | awk 'NF && !seen[$0]++')
[[ "${#roster_arr[@]}" -gt 0 ]] || { echo "grade_planted: --roster has no seats" >&2; exit 2; }
for seat in "${roster_arr[@]}"; do
  match="$(jq -c --arg seat "$seat" 'select((.sources // []) | index($seat) != null)' "$cand_jsonl" 2>/dev/null | head -n 1)"
  if [[ -n "$match" ]]; then
    matched_id="$(jq -r '.id' <<<"$match")"
    severity_called="$(jq -r '.severity // ""' <<<"$match")"
    if [[ "$severity_called" == "$p_expected_severity" ]]; then
      accuracy="1.00"
    else
      accuracy="0.50"
    fi
    # 2-decimal STRINGS (same convention as severity_calibration.sh): a JSON
    # number 1.0 renders as 1 on jq < 1.7 (codex + antigravity, PR #114 review)
    entry="$(jq -nc --arg reviewer "$seat" --arg matched_finding_id "$matched_id" \
      --arg severity_called "$severity_called" --arg severity_accuracy "$accuracy" \
      '{reviewer: $reviewer, matched_finding_id: $matched_finding_id, severity_called: $severity_called, severity_accuracy: $severity_accuracy}')"
    caught_json="$(jq -c --argjson e "$entry" '. + [$e]' <<<"$caught_json")"
  else
    missed_json="$(jq -c --arg seat "$seat" '. + [$seat]' <<<"$missed_json")"
  fi
done

caught_n="$(jq 'length' <<<"$caught_json")"
missed_n="$(jq 'length' <<<"$missed_json")"
total_n=$(( caught_n + missed_n ))
if [[ "$total_n" -eq 0 ]]; then
  recall="0.00"
else
  recall="$(awk -v c="$caught_n" -v t="$total_n" 'BEGIN{printf "%.2f", c/t}')"
fi

out_dir="$(dirname "$out")"
mkdir -p "$out_dir" 2>/dev/null || { echo "grade_planted: cannot create output directory $out_dir" >&2; exit 2; }
out_tmp="$(mktemp "$out_dir/.grade.XXXXXX" 2>/dev/null)" || { echo "grade_planted: cannot write in $out_dir" >&2; exit 2; }
jq -n \
  --arg run_id "$run_id" \
  --arg planted_id "$planted_id" \
  --arg file "$p_file" \
  --argjson line_range "$(jq -c '.line_range' "$planted")" \
  --arg operator "$p_operator" \
  --arg class "$p_class" \
  --arg expected_severity "$p_expected_severity" \
  --argjson caught "$caught_json" \
  --argjson missed "$missed_json" \
  --argjson candidates "$candidates_json" \
  --arg recall "$recall" \
  --argjson recall_raw "$( [[ "$total_n" -eq 0 ]] && echo 0 || awk -v c="$caught_n" -v t="$total_n" 'BEGIN{printf "%.4f", c/t}')" \
  '{
    schema_version: 1,
    synthetic: true,
    run_id: $run_id,
    planted_id: $planted_id,
    planted: {file: $file, line_range: $line_range, operator: $operator, class: $class, expected_severity: $expected_severity},
    caught: $caught,
    missed: $missed,
    candidates: $candidates,
    recall: $recall,
    recall_raw: $recall_raw
  }' > "$out_tmp" || { rm -f "$out_tmp"; echo "grade_planted: failed to build $out" >&2; exit 2; }
# write-then-rename so a failure never leaves a partial grade.json behind
# (kimi High / codex Medium, PR #114 review)
mv -f "$out_tmp" "$out" || { rm -f "$out_tmp"; echo "grade_planted: failed to write $out" >&2; exit 2; }

echo "grade_planted: $caught_n/$total_n seat(s) caught the planted defect (recall $recall)" >&2

if [[ "$emit_events" -eq 1 ]]; then
  planted_fields="$(jq -nc --arg file "$p_file" --argjson line_range "$(jq -c '.line_range' "$planted")" \
    --arg operator "$p_operator" --arg class "$p_class" --arg expected_severity "$p_expected_severity" \
    '{file: $file, line_range: $line_range, operator: $operator, class: $class, expected_severity: $expected_severity}')"
  bash "$script_dir/append_finding_event.sh" --event planted --finding-id "$planted_id" \
    --run-id "$run_id" --fields "$planted_fields"

  while IFS= read -r c; do
    reviewer="$(jq -r '.reviewer' <<<"$c")"
    matched_finding_id="$(jq -r '.matched_finding_id' <<<"$c")"
    severity_called="$(jq -r '.severity_called' <<<"$c")"
    severity_accuracy="$(jq -r '.severity_accuracy' <<<"$c")"
    fields="$(jq -nc --arg reviewer "$reviewer" --arg matched_finding_id "$matched_finding_id" \
      --arg severity_called "$severity_called" --arg expected_severity "$p_expected_severity" \
      --arg severity_accuracy "$severity_accuracy" \
      '{reviewer: $reviewer, matched_finding_id: $matched_finding_id, severity_called: $severity_called, expected_severity: $expected_severity, severity_accuracy: $severity_accuracy}')"
    bash "$script_dir/append_finding_event.sh" --event caught --finding-id "$planted_id" \
      --run-id "$run_id" --fields "$fields"
  done < <(jq -c '.[]' <<<"$caught_json")

  while IFS= read -r reviewer; do
    fields="$(jq -nc --arg reviewer "$reviewer" --arg expected_severity "$p_expected_severity" \
      '{reviewer: $reviewer, expected_severity: $expected_severity}')"
    bash "$script_dir/append_finding_event.sh" --event missed --finding-id "$planted_id" \
      --run-id "$run_id" --fields "$fields"
  done < <(jq -r '.[]' <<<"$missed_json")
fi

exit 0
