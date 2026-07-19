#!/usr/bin/env bash
# score_findings.sh — deterministic merge/score pass over cross-review
# findings.json: applies per-reviewer priors (reviewer_profiles.json) and
# provider-vote math so SKILL.md step 4's synthesis arithmetic (convergence
# counting, provider independence, prior-based disposition, severity/vote/
# weight ordering) is computed by a script instead of held in the
# orchestrating LLM's head. Pure bash + jq. No network, no LLM calls.
#
# Usage:
#   score_findings.sh --findings <findings.json> [--profiles <reviewer_profiles.json>] --out <out.json>
#
# --profiles defaults to this skill's own references/reviewer_profiles.json
# (mirrors run_reviewers.sh's `profile_file` resolution).
#
# findings.json shape (SKILL.md step 4):
#   { "findings": [ {id, severity, file, line, snippet, claim, sources:[...], ...}, ... ] }
#
# Output: the same top-level object, with each finding enriched with:
#   providers          — sorted unique list of distinct providers behind `sources`
#                         (mapped via each profile's `provider` field; an
#                         unknown reviewer's provider falls back to the
#                         reviewer's own name, and a warning is printed to
#                         stderr).
#   provider_votes      — count of distinct providers (kimi+kimi27 → moonshot →
#                         1 vote; antigravity+gemini-pro → google → 1 vote).
#   convergent          — true iff provider_votes >= 2.
#   disposition         — "keep" | "drop" | "verify", per SKILL.md step 4's
#                         "Apply per-reviewer priors" section:
#                           - every source tags this severity
#                             skip_unless_convergent AND provider_votes==1
#                             → drop (disposition_reason records why)
#                           - any source tags this severity high_precision
#                             → keep, even solo
#                           - any source tags this severity
#                             trust_if_convergent AND provider_votes==1
#                             → verify
#                           - else → keep
#   disposition_reason  — non-null only for "drop"; explains which sources
#                         and severity triggered it.
#   rank_score          — integer used to order findings: severity band
#                         (Critical>High>Medium>Low) first, then
#                         provider_votes, then max synthesis_weight among
#                         sources (the same synthesis_weight SKILL.md step 4
#                         uses to break severity disagreements). Findings in
#                         the output are sorted by rank_score descending,
#                         id ascending as a deterministic tie-break.
#
# Also emits a top-level "summary": { total, by_severity, convergent, dropped }.
#
# Provider-scale note (codex): codex's severity_priors use its own [P1]/[P2]/
# [P3] labels (run_reviewers.sh: "equivalent to High/Medium/Low"), not
# Critical/High/Medium/Low. Any reviewer whose severity_priors object lacks a
# key matching the finding's severity but does have "P1"/"P2"/"P3" keys is
# looked up via: Critical→P1, High→P1 (Critical is at least as severe as High,
# so it inherits P1's prior), Medium→P2, Low→P3.
#
# Determinism: sorted object keys (jq -S) + explicit array sort + tie-break by
# id → same input always produces byte-identical output.
#
# Exit: 0 ok, 2 usage, 1 io/dependency error.

set -uo pipefail

findings=""
profiles=""
out=""

need_val() { [[ "$2" -lt 2 ]] && { echo "missing value for $1" >&2; exit 2; }; }
while [[ $# -gt 0 ]]; do
  case "$1" in
    --findings) need_val "$1" "$#"; findings="$2"; shift 2 ;;
    --profiles) need_val "$1" "$#"; profiles="$2"; shift 2 ;;
    --out)      need_val "$1" "$#"; out="$2";      shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

script_dir="$(cd "$(dirname "$0")" && pwd)"
default_profiles="$(cd "$script_dir/.." && pwd)/references/reviewer_profiles.json"
profiles="${profiles:-$default_profiles}"

if [[ -z "$findings" || -z "$out" ]]; then
  echo "usage: $0 --findings <findings.json> [--profiles <reviewer_profiles.json>] --out <out.json>" >&2
  exit 2
fi
command -v jq >/dev/null 2>&1 || { echo "score_findings: jq required" >&2; exit 1; }
[[ -f "$findings" ]] || { echo "score_findings: findings file not found: $findings" >&2; exit 1; }
[[ -f "$profiles" ]] || { echo "score_findings: profiles file not found: $profiles" >&2; exit 1; }

jq -e . "$findings" >/dev/null 2>&1 || { echo "score_findings: findings file is not valid JSON: $findings" >&2; exit 1; }
jq -e . "$profiles" >/dev/null 2>&1 || { echo "score_findings: profiles file is not valid JSON: $profiles" >&2; exit 1; }

# Warn (stderr) about any reviewer referenced in `sources` that has no entry
# (or no `provider` field) in the profiles file — its provider will fall back
# to its own reviewer name in the main pass below.
unknown_reviewers="$(jq -r \
  --slurpfile profiles "$profiles" '
  ($profiles[0]) as $p
  | [ (.findings // [])[]?.sources[]? ] | unique
  | map(select((($p[.] // {}) | type) != "object" or (($p[.].provider // null)) == null))
  | .[]
' "$findings" 2>/dev/null)"
if [[ -n "$unknown_reviewers" ]]; then
  while IFS= read -r r; do
    [[ -n "$r" ]] && echo "score_findings: unknown reviewer '$r' not in profiles ($profiles); using reviewer name as provider" >&2
  done <<<"$unknown_reviewers"
fi

jq_prog="$(mktemp)"
trap 'rm -f "$jq_prog"' EXIT
cat > "$jq_prog" <<'JQ'
def severity_band($sev):
  if $sev == "Critical" then 4
  elif $sev == "High" then 3
  elif $sev == "Medium" then 2
  elif $sev == "Low" then 1
  else 0 end;

# codex-style [P1]/[P2]/[P3] equivalence (run_reviewers.sh: "equivalent to
# High/Medium/Low"); Critical inherits P1 since it is at least as severe as High.
def p_scale_key($sev):
  if $sev == "Critical" then "P1"
  elif $sev == "High" then "P1"
  elif $sev == "Medium" then "P2"
  elif $sev == "Low" then "P3"
  else null end;

def prior_for($reviewer; $sev; $priormap):
  ($priormap[$reviewer]) as $sp
  | if ($sp | type) != "object" then null
    elif ($sp | has($sev)) then $sp[$sev]
    else ($sp[p_scale_key($sev)] // null)
    end;

($profiles[0]) as $p
| ($p | to_entries | map(select(.value | type == "object" and has("provider")))
     | map({key: .key, value: .value.provider}) | from_entries) as $provmap
| ($p | to_entries | map(select(.value | type == "object" and has("severity_priors")))
     | map({key: .key, value: .value.severity_priors}) | from_entries) as $priormap
| ($p | to_entries | map(select(.value | type == "object" and has("synthesis_weight")))
     | map({key: .key, value: .value.synthesis_weight}) | from_entries) as $swmap
| (.findings // []) as $raw
| ($raw | map(
    . as $f
    | ($f.sources // []) as $sources
    | ($f.severity // "") as $sev
    | ($sources | map($provmap[.] // .) | unique | sort) as $providers
    | ($providers | length) as $votes
    | ($votes >= 2) as $conv
    | ($sources | map(prior_for(.; $sev; $priormap))) as $tags
    | (($tags | length) > 0 and ($tags | all(. == "skip_unless_convergent"))) as $all_skip
    | ($tags | any(. == "high_precision")) as $any_hp
    | ($tags | any(. == "trust_if_convergent")) as $any_tic
    | (if $all_skip and $votes == 1 then "drop"
       elif $any_hp then "keep"
       elif $any_tic and $votes == 1 then "verify"
       else "keep" end) as $disp
    | ($sources | join(", ")) as $srcjoin
    | (if $disp == "drop"
       then "every source (" + $srcjoin + ") tags severity " + $sev + " skip_unless_convergent and provider_votes=1"
       else null end) as $reason
    | ($sources | map($swmap[.] // 0) | (if length == 0 then 0 else max end)) as $maxw
    | ((severity_band($sev) * 10000000)
       + ($votes * 10000)
       + ($maxw * 1000 | round)) as $rank
    | $f + {
        providers: $providers,
        provider_votes: $votes,
        convergent: $conv,
        disposition: $disp,
        disposition_reason: $reason,
        rank_score: $rank
      }
  )) as $enriched
| ($enriched | sort_by(-.rank_score, .id)) as $sorted
| {
    Critical: ($sorted | map(select(.severity == "Critical")) | length),
    High:     ($sorted | map(select(.severity == "High"))     | length),
    Medium:   ($sorted | map(select(.severity == "Medium"))   | length),
    Low:      ($sorted | map(select(.severity == "Low"))      | length)
  } as $by_sev
| (. + {
    findings: $sorted,
    summary: {
      total: ($sorted | length),
      by_severity: $by_sev,
      convergent: ($sorted | map(select(.convergent)) | length),
      dropped: ($sorted | map(select(.disposition == "drop")) | length)
    }
  })
JQ

if ! jq -S --slurpfile profiles "$profiles" -f "$jq_prog" "$findings" > "$out.tmp" 2>"$out.tmp.err"; then
  cat "$out.tmp.err" >&2
  rm -f "$out.tmp" "$out.tmp.err"
  exit 1
fi
rm -f "$out.tmp.err"
mv "$out.tmp" "$out"

total_n="$(jq -r '.summary.total' "$out")"
dropped_n="$(jq -r '.summary.dropped' "$out")"
convergent_n="$(jq -r '.summary.convergent' "$out")"
echo "score_findings: $total_n findings scored (convergent=$convergent_n, dropped=$dropped_n)" >&2
