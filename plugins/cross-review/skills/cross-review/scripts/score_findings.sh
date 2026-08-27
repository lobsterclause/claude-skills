#!/usr/bin/env bash
# score_findings.sh — deterministic merge/score pass over cross-review
# findings.json: applies per-reviewer priors (reviewer_profiles.json) and
# provider-vote math so SKILL.md step 4's synthesis arithmetic (convergence
# counting, provider independence, prior-based disposition, severity/vote/
# weight ordering) is computed by a script instead of held in the
# orchestrating LLM's head. Pure bash + jq. No network, no LLM calls.
#
# Usage:
#   score_findings.sh --findings <findings.json> [--profiles <reviewer_profiles.json>]
#                     [--meta-dir <run_dir/raw>] --out <out.json>
#
# --profiles defaults to this skill's own references/reviewer_profiles.json
# (mirrors run_reviewers.sh's `profile_file` resolution).
#
# --meta-dir: the run_reviewers.sh output dir (SKILL.md: $run_dir/raw). Each
# <reviewer>.meta.json there carries `context_access` — what that seat could
# actually SEE this run (run_reviewers.sh stamps it per lane). When given, it
# is authoritative for every reviewer that has one; without it, or for a
# reviewer with no meta there, context_access is DERIVED from the profile's
# `prompt_style`:
#   builtin_review     → agent          (codex: roams the worktree)
#   custom_with_tools  → workspace_read (agy laps: repo mounted, file tools)
#   diff_only_no_tools → diff_only      (the hunk and nothing around it)
# The derivation is deliberately the CONSERVATIVE reading of the lane — a
# text-only seat is assumed to have seen only the hunk unless its meta says
# it got the whole files (`file_context`) or a snapshot. Forgetting --meta-dir
# therefore under-counts, never over-trusts.
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
#   context_access      — {reviewer: access} for every source, see --meta-dir.
#   capability_votes    — sum over distinct providers of the BEST context
#                         weight among that provider's seats. Weights come from
#                         profiles._synthesis_rules.context_access_weights
#                         (defaults: agent 1.0, workspace_read 1.0,
#                         file_context 1.0, snapshot 1.0, diff_only 0.5; an
#                         unknown access counts 1.0 with a stderr warning so
#                         old fixtures and unprofiled reviewers keep their
#                         vote).
#   convergent          — true iff provider_votes >= 2 AND capability_votes >=
#                         profiles._synthesis_rules.convergence_min_capability
#                         (default 1.5). The provider rule exists because two
#                         seats sharing a model share a blind spot; two seats
#                         sharing an INPUT TRUNCATION share one for the same
#                         reason (issue #70). So: one capable seat + one
#                         hunk-only seat = 1.5 → convergent; two hunk-only
#                         seats = 1.0 → not, however many providers; three
#                         hunk-only seats = 1.5 → convergent again (three
#                         independent partial views).
#   convergence_note    — non-null only when provider_votes >= 2 but the
#                         capability floor blocked convergence; names the
#                         seats and their access so the report can say why.
#   disposition         — "keep" | "drop" | "verify", per SKILL.md step 4's
#                         "Apply per-reviewer priors" section:
#                           - every source tags this severity
#                             skip_unless_convergent AND NOT convergent
#                             → drop (disposition_reason records why)
#                           - any source tags this severity high_precision
#                             → keep, even solo
#                           - any source tags this severity
#                             trust_if_convergent AND NOT convergent
#                             → verify
#                           - else → keep
#   disposition_reason  — non-null only for "drop"; explains which sources
#                         and severity triggered it.
#   rank_score          — integer used to order findings: severity band
#                         (Critical>High>Medium>Low) first, then
#                         capability_votes, then max synthesis_weight among
#                         sources (the same synthesis_weight SKILL.md step 4
#                         uses to break severity disagreements). Findings in
#                         the output are sorted by rank_score descending,
#                         id ascending as a deterministic tie-break.
#
# Also emits a top-level "summary": { total, by_severity, convergent,
# convergence_blocked_by_capability, dropped }.
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
meta_dir=""
out=""

need_val() { [[ "$2" -lt 2 ]] && { echo "missing value for $1" >&2; exit 2; }; }
while [[ $# -gt 0 ]]; do
  case "$1" in
    --findings) need_val "$1" "$#"; findings="$2"; shift 2 ;;
    --profiles) need_val "$1" "$#"; profiles="$2"; shift 2 ;;
    --meta-dir) need_val "$1" "$#"; meta_dir="$2"; shift 2 ;;
    --out)      need_val "$1" "$#"; out="$2";      shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

script_dir="$(cd "$(dirname "$0")" && pwd)"
default_profiles="$(cd "$script_dir/.." && pwd)/references/reviewer_profiles.json"
profiles="${profiles:-$default_profiles}"

if [[ -z "$findings" || -z "$out" ]]; then
  echo "usage: $0 --findings <findings.json> [--profiles <reviewer_profiles.json>] [--meta-dir <dir>] --out <out.json>" >&2
  exit 2
fi
command -v jq >/dev/null 2>&1 || { echo "score_findings: jq required" >&2; exit 1; }
[[ -f "$findings" ]] || { echo "score_findings: findings file not found: $findings" >&2; exit 1; }
[[ -f "$profiles" ]] || { echo "score_findings: profiles file not found: $profiles" >&2; exit 1; }

jq -e . "$findings" >/dev/null 2>&1 || { echo "score_findings: findings file is not valid JSON: $findings" >&2; exit 1; }
jq -e . "$profiles" >/dev/null 2>&1 || { echo "score_findings: profiles file is not valid JSON: $profiles" >&2; exit 1; }
if [[ -n "$meta_dir" && ! -d "$meta_dir" ]]; then
  echo "score_findings: --meta-dir is not a directory: $meta_dir" >&2; exit 1
fi

# Observed context_access per reviewer, from <meta_dir>/<reviewer>.meta.json.
# Only reviewers referenced by some finding's `sources` are looked up. A meta
# file that exists but carries no context_access (pre-2026-08-26 runs) leaves
# that reviewer on the profile-derived default.
observed_json='{}'
if [[ -n "$meta_dir" ]]; then
  while IFS= read -r r; do
    [[ -n "$r" ]] || continue
    mf="$meta_dir/$r.meta.json"
    [[ -f "$mf" ]] || continue
    ca="$(jq -r '.context_access // empty' "$mf" 2>/dev/null || true)"
    [[ -n "$ca" ]] || continue
    observed_json="$(jq -c --arg r "$r" --arg ca "$ca" '. + {($r): $ca}' <<<"$observed_json")"
  done < <(jq -r '[ (.findings // [])[]?.sources[]? | select(type == "string") ] | unique | .[]' "$findings" 2>/dev/null)
fi

# Warn about reviewers whose context_access is unknown from both sources —
# they count as a full capability vote (never penalise what we cannot see),
# but the synthesis should know the scorer is guessing.
unknown_ctx="$(jq -r \
  --slurpfile profiles "$profiles" --argjson obs "$observed_json" '
  ($profiles[0]) as $p
  | [ (.findings // [])[]?.sources[]? | select(type == "string") ] | unique
  | map(select(
      ($obs[.] == null)
      and ((($p[.] // {}) | if type == "object" then .prompt_style else null end) as $ps
           | $ps != "builtin_review" and $ps != "custom_with_tools" and $ps != "diff_only_no_tools")))
  | .[]
' "$findings" 2>/dev/null)"
if [[ -n "$unknown_ctx" ]]; then
  while IFS= read -r r; do
    [[ -n "$r" ]] && echo "score_findings: no context_access known for '$r' (no meta in --meta-dir, no prompt_style in profiles); counting it as a full capability vote" >&2
  done <<<"$unknown_ctx"
fi

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

# Lane → conservative context_access (see the --meta-dir header note).
def access_from_style($ps):
  if $ps == "builtin_review" then "agent"
  elif $ps == "custom_with_tools" then "workspace_read"
  elif $ps == "diff_only_no_tools" then "diff_only"
  else "unknown" end;

($profiles[0]) as $p
| ({agent: 1.0, workspace_read: 1.0, file_context: 1.0, snapshot: 1.0, diff_only: 0.5}
   + (($p._synthesis_rules // {}).context_access_weights // {})) as $ctxw
| ((($p._synthesis_rules // {}).convergence_min_capability // 1.5) | tonumber) as $ctxmin
| ($p | to_entries | map(select(.value | type == "object" and has("prompt_style")))
     | map({key: .key, value: (.value.prompt_style | access_from_style(.))}) | from_entries) as $stylemap
| ($p | to_entries | map(select(.value | type == "object" and has("provider")))
     | map({key: .key, value: .value.provider}) | from_entries) as $provmap
| ($p | to_entries | map(select(.value | type == "object" and has("severity_priors")))
     | map({key: .key, value: .value.severity_priors}) | from_entries) as $priormap
| ($p | to_entries | map(select(.value | type == "object" and has("synthesis_weight")))
     | map({key: .key, value: .value.synthesis_weight}) | from_entries) as $swmap
| (.findings // []) as $raw
| ($raw | map(
    . as $f
    | ($f.sources // [] | map(select(type == "string"))) as $sources
    | ($f.severity // "") as $sev
    | ($sources | map($provmap[.] // .) | unique | sort) as $providers
    | ($providers | length) as $votes
    | ($sources | map({key: ., value: ($observed[.] // $stylemap[.] // "unknown")}) | from_entries) as $ctx
    # Best context weight per provider, summed: a provider's vote is as good
    # as the most capable seat it fielded, never double-counted for fielding
    # two.
    | ($providers | map(. as $prov
        | [ $sources[] | select(($provmap[.] // .) == $prov) | $ctx[.] | ($ctxw[.] // 1.0) ]
        | max) | add // 0) as $cap
    | ($votes >= 2 and $cap >= $ctxmin) as $conv
    | (if $votes >= 2 and ($conv | not)
       then "provider_votes=" + ($votes | tostring) + " but capability_votes=" + ($cap | tostring)
            + " < " + ($ctxmin | tostring) + ": "
            + ($sources | map(. + "=" + $ctx[.]) | join(", "))
            + " — the agreeing seats share an input truncation, not an independent view"
       else null end) as $convnote
    | ($sources | map(prior_for(.; $sev; $priormap))) as $tags
    | (($tags | length) > 0 and ($tags | all(. == "skip_unless_convergent"))) as $all_skip
    | ($tags | any(. == "high_precision")) as $any_hp
    | ($tags | any(. == "trust_if_convergent")) as $any_tic
    | (if $all_skip and ($conv | not) then "drop"
       elif $any_hp then "keep"
       elif $any_tic and ($conv | not) then "verify"
       else "keep" end) as $disp
    | ($sources | join(", ")) as $srcjoin
    | (if $disp == "drop"
       then "every source (" + $srcjoin + ") tags severity " + $sev + " skip_unless_convergent and the finding is not convergent (provider_votes="
            + ($votes | tostring) + ", capability_votes=" + ($cap | tostring) + ")"
       else null end) as $reason
    | ($sources | map($swmap[.] // 0) | (if length == 0 then 0 else max end)) as $maxw
    | ((severity_band($sev) * 10000000)
       + ($cap * 10000 | round)
       + ($maxw * 1000 | round)) as $rank
    | $f + {
        providers: $providers,
        provider_votes: $votes,
        context_access: $ctx,
        capability_votes: $cap,
        convergent: $conv,
        convergence_note: $convnote,
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
      convergence_blocked_by_capability: ($sorted | map(select(.convergence_note != null)) | length),
      dropped: ($sorted | map(select(.disposition == "drop")) | length)
    }
  })
JQ

if ! jq -S --slurpfile profiles "$profiles" --argjson observed "$observed_json" -f "$jq_prog" "$findings" > "$out.tmp" 2>"$out.tmp.err"; then
  cat "$out.tmp.err" >&2
  rm -f "$out.tmp" "$out.tmp.err"
  exit 1
fi
rm -f "$out.tmp.err"
mv "$out.tmp" "$out"

total_n="$(jq -r '.summary.total' "$out")"
dropped_n="$(jq -r '.summary.dropped' "$out")"
convergent_n="$(jq -r '.summary.convergent' "$out")"
blocked_n="$(jq -r '.summary.convergence_blocked_by_capability' "$out")"
echo "score_findings: $total_n findings scored (convergent=$convergent_n, blocked_by_capability=$blocked_n, dropped=$dropped_n)" >&2
if [[ -z "$meta_dir" && "$blocked_n" -gt 0 ]]; then
  echo "score_findings: no --meta-dir given — text-only seats were assumed hunk-only (diff_only); pass --meta-dir \$run_dir/raw so a seat that got the whole files this run counts as one" >&2
fi
