#!/usr/bin/env bash
# tool_policy.sh — decide, per seat, which tool arm the chat-completions lane
# runs with this round: off | read | check. Self-learning, stateless.
#
# The decision is derived every time from the ledgers this skill already
# keeps — runlog.jsonl (per-run telemetry incl. tool_stats) and
# finding_events.jsonl (per-finding outcomes) — exactly the way leaderboard.sh
# derives a seat's score. No hidden state file: the next decision sees what
# the last round stamped into meta.json → runlog, and a human can reproduce
# any decision from the ledgers with --explain.
#
# Per (seat, arm) over the window of structured runlog entries, counting only
# that seat's CHAT-COMPLETIONS runs (cli openrouter|moonshot — a first-party
# codex run is not an "off" arm sample; its OpenRouter fallback runs are):
#
#   reward(run) = 0.6 * r_q + 0.4 * r_ok - cost_lambda * cost_usd
#     r_ok = 1 if the lane delivered a review (status ok|fallback) else 0
#     r_q  = 0.5 when the run has no findings data or zero findings
#            (uninformative — a clean diff says nothing about the arm)
#          = (findings - dropped - 0.5*unanchored) / findings, clipped to
#            [0,1], otherwise. `dropped` = fact-check disproven (runlog
#            findings_dropped); `unanchored` = anchored resolved=false events
#            naming this seat for this run (a finding whose line could not be
#            found — the shape a hunk-only seat produces).
#
#   ucb(arm) = mean_reward + ucb_c * sqrt(ln(N + 1) / (n_arm + 1))
#     untried arm: mean := optimistic_prior, so every arm gets sampled
#     demotion:    n_arm >= min_samples and reliability < demote_below
#                  → the arm is out (the loop breaks that model: malformed
#                  tool calls, loops, refusals)
#
#   choose argmax ucb; ties by fixed priority read > check > off.
#
#   Not a sample: a run the provider never judged — failure_kind in
#   provider_billing | provider_rate_limited | provider_auth | transport_error
#   | quota_exhausted (run_reviewers.sh / lib_tool_loop.sh classify these), or
#   a pre-classification row that shows the same shape (status failed, no
#   failure_kind, no tokens, no output). An outage says nothing about the arm
#   that happened to be drawn; counting it demoted `read` on three 402s
#   (2026-08-27). Those rows are reported as excluded_runs, never scored.
#   A generic provider_error IS a sample: "tools not supported on this route"
#   is exactly what demotion exists for.
#   `check` is only an arm when the repo declares a verify entrypoint
#   (lib_tool_loop.sh tl_resolve_check_cmd) — the model never chooses the
#   command, so there is nothing to learn where there is nothing to run.
#
# Deterministic on purpose (no Thompson draw): a shell tool that decides
# differently on the same ledgers is not auditable.
#
# Precedence, highest first:
#   1. CROSS_REVIEW_TOOL_MODE=off|read|check   → basis "override" (auto/unset = learn)
#   2. profile <seat>.tools.mode               → basis "pinned"
#   3. learned                                 → basis "learned"
#   4. no ledger data at all                   → basis "default" (tool_policy.default_mode)
# A requested `check` with no entrypoint degrades to `read`, basis suffixed
# ":no_check_entrypoint".
#
# Constants live in reviewer_profiles.json `_synthesis_rules.tool_policy`
# (single source of truth; defaults below only cover an older profile file).
#
# Usage:
#   tool_policy.sh --reviewer <slug> [--repo-root <dir>] [--mode json|table] [--explain]
#   tool_policy.sh --all [--repo-root <dir>] [--mode table]        # every chat-lane seat
# Env (fixture tests): CROSS_REVIEW_RUNLOG, CROSS_REVIEW_FINDING_EVENTS,
#   CROSS_REVIEW_PROFILES.
# Output (json): {reviewer, mode, basis, check_available, arms:{<arm>:{n, ok,
#   reliability, mean, ucb, cost_avg, eligible}}, window_runs, excluded_runs}

set -uo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib_tool_loop.sh
source "$script_dir/lib_tool_loop.sh"

reviewer=""; repo_root=""; mode="json"; explain=false; all=false
need_val() { [[ "$2" -ge 2 ]] || { echo "missing value for $1" >&2; exit 2; }; }
while [[ $# -gt 0 ]]; do
  case "$1" in
    --reviewer)  need_val "$1" "$#"; reviewer="$2";  shift 2 ;;
    --repo-root) need_val "$1" "$#"; repo_root="$2"; shift 2 ;;
    --mode)      need_val "$1" "$#"; mode="$2";      shift 2 ;;
    --explain)   explain=true; shift ;;
    --all)       all=true; shift ;;
    -h|--help)   sed -n '2,60p' "$0"; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done
command -v jq >/dev/null 2>&1 || { echo "tool_policy: jq required" >&2; exit 1; }
[[ -n "$reviewer" || "$all" == true ]] || { echo "usage: $0 --reviewer <slug> | --all" >&2; exit 2; }
[[ -n "$repo_root" ]] || repo_root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"

profiles="${CROSS_REVIEW_PROFILES:-$script_dir/../references/reviewer_profiles.json}"
runlog="${CROSS_REVIEW_RUNLOG:-$script_dir/../runlog.jsonl}"
events="${CROSS_REVIEW_FINDING_EVENTS:-$(dirname "$runlog")/finding_events.jsonl}"

# `check` runs a command the REVIEWED BRANCH controls (.claude/verify.sh,
# package.json verify, Makefile verify/check) in the wrapper's own
# environment — HOME, keys, network. Whether that is acceptable is the
# operator's call, never the learner's: the arm exists only when the repo
# declares an entrypoint AND the operator vouched for it — for this round
# (CROSS_REVIEW_TOOL_MODE=check) or standing (CROSS_REVIEW_TOOL_CHECK_TRUST=1).
# Leave both unset for pull requests from strangers. (codex P1, PR #154.)
override="${CROSS_REVIEW_TOOL_MODE:-auto}"
check_entrypoint=false; check_trusted=false; check_available=false
tl_resolve_check_cmd "$repo_root" >/dev/null 2>&1 && check_entrypoint=true
[[ "$override" == "check" || "${CROSS_REVIEW_TOOL_CHECK_TRUST:-0}" == "1" ]] && check_trusted=true
[[ "$check_entrypoint" == true && "$check_trusted" == true ]] && check_available=true

case "$override" in off|read|check|auto) ;; *) echo "CROSS_REVIEW_TOOL_MODE must be off|read|check|auto (got '$override')" >&2; exit 2 ;; esac

[[ -f "$profiles" ]] || { echo "tool_policy: profiles not found: $profiles" >&2; exit 1; }
# The ledgers are megabytes — they go to jq as files (--slurpfile), never
# argv (--argjson hit "Argument list too long" on the first live run). Trim
# to the learner's window and the fields it reads, once, before deciding.
tp_tmp="$(mktemp -d)"; trap 'rm -rf "$tp_tmp"' EXIT
window="$(jq -r '((._synthesis_rules // {}).tool_policy // {}).window // 40' "$profiles" 2>/dev/null)"
[[ "$window" =~ ^[0-9]+$ ]] || window=40
if [[ -f "$runlog" ]]; then
  jq -c 'select(.reviewers != null)' "$runlog" 2>/dev/null | tail -n "$window" \
    | jq -c '{run_id, reviewers: (.reviewers | with_entries(.value |= {status, cli, cost_usd, findings_total, findings_dropped, tool_stats, failure_kind, tokens_prompt, output_bytes}))}' \
    | jq -c -s '.' >"$tp_tmp/runs.json" 2>/dev/null || echo '[]' >"$tp_tmp/runs.json"
else
  echo '[]' >"$tp_tmp/runs.json"
fi
[[ -s "$tp_tmp/runs.json" ]] || echo '[]' >"$tp_tmp/runs.json"
if [[ -f "$events" ]]; then
  jq -c 'select(.event == "anchored" and .resolved == false) | {run_id, sources: (.sources // [])}' "$events" 2>/dev/null \
    | jq -c -s '.' >"$tp_tmp/ev.json" 2>/dev/null || echo '[]' >"$tp_tmp/ev.json"
else
  echo '[]' >"$tp_tmp/ev.json"
fi
[[ -s "$tp_tmp/ev.json" ]] || echo '[]' >"$tp_tmp/ev.json"

decide_one() {
  local r="$1"
  jq -n -c --arg r "$r" --arg override "$override" --argjson check_available "$check_available" --argjson check_entrypoint "$check_entrypoint" --argjson check_trusted "$check_trusted" \
     --slurpfile runs_f "$tp_tmp/runs.json" --slurpfile ev_f "$tp_tmp/ev.json" --slurpfile prof "$profiles" '
    ($runs_f[0]) as $runs | ($ev_f[0]) as $ev |
    def clip: if . < 0 then 0 elif . > 1 then 1 else . end;
    ($prof[0]) as $p
    | (($p._synthesis_rules // {}).tool_policy // {}) as $tp
    | ({default_mode:"read", arms:["off","read","check"], ucb_c:0.5, min_samples:3,
        cost_lambda:2.0, window:40, optimistic_prior:0.75, demote_reliability_below:0.5}
       + $tp) as $c
    | ($p[$r] // {}) as $seat
    | ($seat.tools // {}) as $pin
    | ($c.arms | map(select(. != "check" or $check_available))) as $arms
    | ($runs | if length > $c.window then .[-($c.window):] else . end) as $win
    | def unjudged: ((.failure_kind // "") | IN("provider_billing","provider_rate_limited","provider_auth","transport_error","quota_exhausted"))
        or (.status == "failed" and .failure_kind == null and .tokens_prompt == null and ((.output_bytes // 0) == 0));
      ([ $win[] | (.reviewers[$r] // null)
        | select(. != null and .status != "skipped" and ((.cli // "") | IN("openrouter","moonshot")))
        | select(unjudged) ] | length) as $excluded
    | [ $win[] | . as $run
        | (.reviewers[$r] // null)
        | select(. != null and .status != "skipped" and ((.cli // "") | IN("openrouter","moonshot")))
        | select(unjudged | not)
        | { arm: (.tool_stats.mode // "off"),
            ok: (if (.status == "ok" or .status == "fallback") then 1 else 0 end),
            cost: (.cost_usd | if type == "number" then . else 0 end),
            ft: .findings_total, fd: (.findings_dropped // 0),
            un: ([ $ev[] | select(.run_id == $run.run_id and (.sources | index($r) != null)) ] | length) }
        | .r_q = (if (.ft == null or .ft == 0) then 0.5 else (((.ft - .fd - 0.5 * .un) / .ft) | clip) end)
        | .reward = (0.6 * .r_q + 0.4 * .ok - $c.cost_lambda * .cost) ] as $samples
    | ($samples | length) as $N
    | ($arms | map(. as $a
        | ($samples | map(select(.arm == $a))) as $s
        | ($s | length) as $n
        | ($s | map(.ok) | add // 0) as $okn
        | (if $n == 0 then null else ($okn / $n) end) as $rel
        | (if $n == 0 then $c.optimistic_prior else (($s | map(.reward) | add) / $n) end) as $mean
        | (if $n == 0 then 0 else (($s | map(.cost) | add) / $n) end) as $cost_avg
        | ($n >= $c.min_samples and $rel != null and $rel < $c.demote_reliability_below) as $demoted
        | { key: $a, value: { n: $n, ok: $okn, reliability: $rel,
              mean: (($mean * 10000 | round) / 10000),
              ucb: (if $demoted then -1 else (($mean + $c.ucb_c * ((($N + 1) | log) / ($n + 1) | sqrt)) * 10000 | round) / 10000 end),
              cost_avg: (($cost_avg * 1000000 | round) / 1000000),
              eligible: ($demoted | not) } })
       | from_entries) as $stats
    | (["read","check","off"] | map(select(. as $a | $arms | index($a) != null))) as $prio
    | ($prio | map(select($stats[.].eligible)) | sort_by(-$stats[.].ucb)
       | if length == 0 then "off" else .[0] end) as $learned
    | (if $override != "auto" then {mode: $override, basis: "override"}
       elif ($pin.mode // "") != "" then {mode: $pin.mode, basis: "pinned"}
       elif $N == 0 then {mode: $c.default_mode, basis: "default"}
       else {mode: $learned, basis: "learned"} end) as $d
    | (if $d.mode == "check" and ($check_available | not)
       then {mode: "read", basis: ($d.basis + ":no_check_entrypoint")} else $d end) as $d
    | { reviewer: $r, mode: $d.mode, basis: $d.basis, check_available: $check_available, check_entrypoint: $check_entrypoint, check_trusted: $check_trusted,
        window_runs: $N, excluded_runs: $excluded, arms: $stats,
        max_steps: ($pin.max_steps // null),
        read_budget_bytes: ($pin.read_budget_bytes // null) }'
}

print_table() {
  jq -r '"\(.reviewer): mode=\(.mode) (\(.basis)) window_runs=\(.window_runs) excluded_runs=\(.excluded_runs) check_available=\(.check_available) (entrypoint=\(.check_entrypoint) trusted=\(.check_trusted))"
         + (.arms | to_entries | map("\n    \(.key | . + "     " | .[0:5])  n=\(.value.n)  ok=\(.value.ok)  rel=\(.value.reliability // "-")  mean=\(.value.mean)  ucb=\(.value.ucb)  cost_avg=\(.value.cost_avg)\(if .value.eligible then "" else "  DEMOTED" end)") | join(""))'
}

if [[ "$all" == true ]]; then
  seats="$(jq -r 'to_entries[] | select(.value | type == "object") | select(.value.cli == "openrouter" or .value.cli == "moonshot") | .key' "$profiles")"
  for s in $seats; do
    d="$(decide_one "$s")"
    if [[ "$mode" == "json" ]]; then printf '%s\n' "$d"; else printf '%s\n' "$d" | print_table; fi
  done
  exit 0
fi

d="$(decide_one "$reviewer")"
if [[ "$mode" == "table" || "$explain" == true ]]; then
  printf '%s\n' "$d" | print_table
  [[ "$explain" == true && "$mode" == "json" ]] && printf '%s\n' "$d"
else
  printf '%s\n' "$d"
fi
