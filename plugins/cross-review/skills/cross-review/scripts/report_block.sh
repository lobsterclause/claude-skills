#!/usr/bin/env bash
# report_block.sh — deterministically render the SKILL.md step-9 "report back
# to the caller" block from a verified findings JSON + a roster decision.
#
# Pure bash + jq. No network, no LLM calls. Same inputs -> byte-identical
# output (parent agents key off the exact field names/shape, per step 9).
#
# Usage:
#   report_block.sh --findings <findings.verified.json> --pass <N> \
#     --verdict <CLEAN|FIXES_APPLIED|NEEDS_DECISION|BLOCKED> \
#     --record <path> --next <stop|re-review|ask-user|apply-fixes> \
#     [--pr-url <url>] [--notes <text>] \
#     [--profiles <reviewer_profiles.json>] \
#     [--roster-decision <roster_decision.json>]
#
# findings JSON shape (step 4 / step 4.5):
#   { "findings": [ {severity, file, line, claim, sources:[...],
#                    factcheck: {verdict: "keep"|"drop", ...}?, ...}, ... ] }
# A bare top-level array is also accepted.
#
# --profiles defaults to the skill's own references/reviewer_profiles.json
# (resolved relative to this script's location) — each profile's "provider"
# field is read dynamically so a newly added reviewer needs no code change
# here, only an entry in reviewer_profiles.json.
#
# --roster-decision is an optional JSON object of the shape:
#   { "dropped": [{"reviewer": "<name>", "reason": "<text>"}, ...],
#     "failed":  [{"reviewer": "<name>", "reason": "<text>"}, ...] }
# When --notes is empty/omitted and this file is given, any dropped/failed
# reviewers are summarized into the Notes line instead of leaving it "—".
#
# Behavior:
#   - Findings with factcheck.verdict=="drop" are EXCLUDED from all counts,
#     convergence, and Top selection.
#   - "convergent" = a finding's own `convergent` field when the input is
#     score_findings.sh output (that scorer also weighs what the agreeing
#     seats could SEE — two hunk-only seats do not converge, issue #70);
#     otherwise kept findings whose `sources` map to >= 2 DISTINCT providers
#     (not raw reviewer count) — e.g. kimi+kimi27 (both moonshot) is NOT
#     convergent; codex+kimi (openai+moonshot) IS.
#   - "Top" selection: highest severity first (Critical > High > Medium >
#     Low), then the scorer's capability_votes when present (falling back
#     to most distinct providers on unscored input), then first occurrence in the
#     input array (stable, deterministic tie-break). Formatted exactly:
#       <file>:<line> — <claim> [<severity>][<source1>+<source2>]
#   - Empty/all-dropped findings -> C:0 H:0 M:0 L:0 and `Top:     —`.
#   - No --pr-url -> `(posted to PR: —)`.
#
# Exit: 0 ok, 2 usage/validation error, 1 io error.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DEFAULT_PROFILES="$SCRIPT_DIR/../references/reviewer_profiles.json"

findings="" ; pass="" ; verdict="" ; record="" ; next=""
pr_url="" ; notes="" ; profiles="$DEFAULT_PROFILES" ; roster_decision="" ; meta_dir=""

need_val() { [[ "$2" -lt 2 ]] && { echo "missing value for $1" >&2; exit 2; }; }
while [[ $# -gt 0 ]]; do
  case "$1" in
    --findings)        need_val "$1" "$#"; findings="$2";        shift 2 ;;
    --pass)             need_val "$1" "$#"; pass="$2";             shift 2 ;;
    --verdict)          need_val "$1" "$#"; verdict="$2";          shift 2 ;;
    --record)           need_val "$1" "$#"; record="$2";           shift 2 ;;
    --next)             need_val "$1" "$#"; next="$2";             shift 2 ;;
    --pr-url)           need_val "$1" "$#"; pr_url="$2";           shift 2 ;;
    --notes)            need_val "$1" "$#"; notes="$2";            shift 2 ;;
    --profiles)         need_val "$1" "$#"; profiles="$2";         shift 2 ;;
    --roster-decision)  need_val "$1" "$#"; roster_decision="$2";  shift 2 ;;
    --meta-dir)         need_val "$1" "$#"; meta_dir="$2";         shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

usage="usage: $0 --findings <json> --pass <N> --verdict <CLEAN|FIXES_APPLIED|NEEDS_DECISION|BLOCKED> --record <path> --next <stop|re-review|ask-user|apply-fixes> [--pr-url <url>] [--notes <text>] [--profiles <json>] [--roster-decision <json>] [--meta-dir <run_dir/raw>]"

[[ -z "$findings" || -z "$pass" || -z "$verdict" || -z "$record" || -z "$next" ]] && {
  echo "$usage" >&2; exit 2;
}
[[ -f "$findings" ]] || { echo "report_block: findings file not found: $findings" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "report_block: jq required" >&2; exit 1; }

[[ "$pass" =~ ^[0-9]+$ ]] || { echo "report_block: --pass must be an integer, got '$pass'" >&2; exit 2; }

case "$verdict" in
  CLEAN|FIXES_APPLIED|NEEDS_DECISION|BLOCKED) ;;
  *) echo "report_block: --verdict must be one of CLEAN|FIXES_APPLIED|NEEDS_DECISION|BLOCKED, got '$verdict'" >&2; exit 2 ;;
esac

case "$next" in
  stop|re-review|ask-user|apply-fixes) ;;
  *) echo "report_block: --next must be one of stop|re-review|ask-user|apply-fixes, got '$next'" >&2; exit 2 ;;
esac

if [[ -n "$roster_decision" && ! -f "$roster_decision" ]]; then
  echo "report_block: --roster-decision file not found: $roster_decision" >&2; exit 1
fi

# ── Provider floor ────────────────────────────────────────────────────────
# SKILL.md has always said a round needs >=3 reviewers and >=3 providers to
# count. Nothing checked it, and on 2026-09-01 a census of the previous 25
# rounds found PR #3677 graded CLEAN on two returning seats and PR #173
# reporting NEEDS_DECISION on ONE. A verdict is the thing callers act on, so
# the floor binds here: with --meta-dir, a round that did not clear it cannot
# report anything but BLOCKED, whatever the caller passed.
#
# The check itself fails OPEN (see check_provider_floor.sh) so a missing meta
# dir never stops a report; only a round we can SEE was thin is overridden.
floor_note=""
if [[ -n "$meta_dir" ]]; then
  floor_json="$("$SCRIPT_DIR/check_provider_floor.sh" --meta-dir "$meta_dir" --profiles "$profiles" --json 2>/dev/null)"
  floor_rc=$?
  if [[ $floor_rc -eq 3 ]]; then
    got="$(printf '%s' "$floor_json" | jq -r '.providers_returned // 0' 2>/dev/null)"
    need="$(printf '%s' "$floor_json" | jq -r '.floor // 3' 2>/dev/null)"
    who="$(printf '%s' "$floor_json" | jq -r '(.seats // []) | join("+")' 2>/dev/null)"
    if [[ "$verdict" != "BLOCKED" ]]; then
      echo "report_block: provider floor not met (${got}/${need}) — overriding verdict ${verdict} -> BLOCKED" >&2
      verdict="BLOCKED"
      next="ask-user"
    fi
    floor_note="INVALID ROUND: only ${got} of ${need} required providers returned output (${who:-none}); not a cross-review, do not stamp"
  fi
fi

# ── Provider map: read dynamically from reviewer_profiles.json so new
# reviewers need no change here. Falls back to an empty map (every source
# then counts as its own distinct provider) if the file is missing/unreadable
# — never fatal, since Top/convergent are still computable, just more
# conservative about what counts as convergent.
if [[ -f "$profiles" ]]; then
  prov_json="$(jq -c '[to_entries[] | select((.value | type) == "object" and (.value.provider != null)) | {(.key): .value.provider}] | add // {}' "$profiles" 2>/dev/null)"
  [[ -z "$prov_json" || "$prov_json" == "null" ]] && prov_json="{}"
else
  prov_json="{}"
fi

# ── Normalize findings to a bare array, keep only non-dropped, and attach
# a stable original-order index for deterministic tie-breaking.
findings_arr="$(jq -c 'if type=="array" then . else (.findings // []) end' "$findings" 2>/dev/null)"
[[ -z "$findings_arr" || "$findings_arr" == "null" ]] && { echo "report_block: could not read .findings from $findings" >&2; exit 1; }

kept="$(jq -c \
  --argjson prov "$prov_json" \
  '
  [ to_entries[] | {orig_index: .key, f: .value} ]
  | map(select((.f.factcheck.verdict // "keep") != "drop"))
  | map(.f.provider_count = (((.f.sources // []) | map($prov[.] // .) | unique) | length))
  | map(.f.sev_rank = ({"Critical":4,"High":3,"Medium":2,"Low":1}[(.f.severity // "")] // 0))
  ' <<<"$findings_arr")"

n_c="$(jq '[.[] | select(.f.severity == "Critical")] | length' <<<"$kept")"
n_h="$(jq '[.[] | select(.f.severity == "High")] | length' <<<"$kept")"
n_m="$(jq '[.[] | select(.f.severity == "Medium")] | length' <<<"$kept")"
n_l="$(jq '[.[] | select(.f.severity == "Low")] | length' <<<"$kept")"
# Prefer the scorer's verdict (it knows capability, not just provider count);
# recompute from providers only for unscored input.
n_convergent="$(jq '[.[] | select(if (.f.convergent | type) == "boolean" then .f.convergent else .f.provider_count >= 2 end)] | length' <<<"$kept")"

top_line="$(jq -r '
  sort_by([-(.f.sev_rank), -(if (.f.capability_votes | type) == "number" then .f.capability_votes else .f.provider_count end), .orig_index])
  | .[0]
  | if . == null then "—"
    else "\(.f.file):\(.f.line) — \(.f.claim) [\(.f.severity)][\((.f.sources // []) | join("+"))]"
    end
' <<<"$kept")"

# ── PR / notes ────────────────────────────────────────────────────────────
posted_pr="${pr_url:-—}"

if [[ -z "$notes" && -n "$roster_decision" ]]; then
  notes="$(jq -r '
    ((.dropped // []) | map("\(.reviewer) dropped (\(.reason // "no reason given"))")) as $d
    | ((.failed // [])  | map("\(.reviewer) failed (\(.reason // "no reason given"))")) as $fl
    | ($d + $fl) as $all
    | if ($all | length) == 0 then "" else ($all | join("; ")) end
  ' "$roster_decision" 2>/dev/null)"
fi
if [[ -n "$floor_note" ]]; then
  if [[ -n "$notes" && "$notes" != "—" ]]; then notes="$floor_note; $notes"; else notes="$floor_note"; fi
fi
[[ -z "$notes" ]] && notes="—"

# ── Emit the block, byte-exact to SKILL.md step 9 ─────────────────────────
printf -- '── cross-review pass %s/3 ──\n' "$pass"
printf 'Verdict: %s\n' "$verdict"
printf 'Counts:  C:%s H:%s M:%s L:%s  (convergent: %s)\n' "$n_c" "$n_h" "$n_m" "$n_l" "$n_convergent"
printf 'Top:     %s\n' "$top_line"
printf 'Record:  %s  (posted to PR: %s)\n' "$record" "$posted_pr"
printf 'Next:    %s\n' "$next"
printf 'Notes:   %s\n' "$notes"
printf -- '──────────────────────────────\n'
