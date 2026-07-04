#!/usr/bin/env bash
# leaderboard.sh — score every reviewer from runlog.jsonl telemetry and emit a
# ranked leaderboard. The score is what select_roster.sh uses to weight the
# rotation draw, and what humans read to decide who earns a permanent seat.
#
# Scoring (documented here, implemented once below — keep in sync):
#   reliability = ok / attempts                     (delivered a review at all)
#   signal      = convergent / findings             (cross-PROVIDER convergence
#                                                    is our best precision proxy
#                                                    absent ground truth)
#   noise       = dropped / findings                (findings the fact-check
#                                                    pass disproved from the diff)
#   with findings data:  score = 100*(0.45*reliability + 0.35*signal + 0.20*(1-noise))
#   telemetry-only:      score = 100*reliability*0.75      (quality unknown → discount)
#   never attempted:     score = 50                        (rookie prior — optimistic
#                                                    init so new reviewers get drawn
#                                                    and earn real data)
#
# KNOWN LIMITATION: signal rewards agreeing with the crowd — a reviewer that
# uniquely finds real bugs scores low on signal until others corroborate.
# That's the price of having no ground truth; don't tune a reviewer out of the
# fleet on signal alone, look at its actual findings first.
#
# The per-reviewer findings counts come from append_runlog.sh --findings
# (entries older than that feature have telemetry only — they score on the
# telemetry-only branch).
#
# Usage:
#   leaderboard.sh [--recent <n>] [--mode table|json]
#     --recent <n>   window of structured runlog entries (default 40)
#     --mode table   human-ranked leaderboard (default)
#     --mode json    one JSON array, consumed by select_roster.sh
#
# JSON fields per reviewer: reviewer, provider, attempts, ok, quota,
# reliability_pct, findings, convergent, dropped, latest_status, rookie, score,
# sleep_excluded (timed_out samples whose wall clock overran the enforced
# budget — machine slept mid-run; dropped from the attempt set, see below).

set -uo pipefail

recent=40
mode="table"

need_val() {
  if [[ "$2" -lt 2 ]]; then
    echo "missing value for $1" >&2
    exit 2
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --recent) need_val "$1" "$#"; recent="$2"; shift 2 ;;
    --mode)   need_val "$1" "$#"; mode="$2";   shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

command -v jq >/dev/null 2>&1 || { echo "leaderboard: jq required" >&2; exit 1; }

skill_dir="$(cd "$(dirname "$0")/.." && pwd)"
# CROSS_REVIEW_RUNLOG override exists for the fixture tests (tests/run_tests.sh)
# — production callers never set it.
runlog="${CROSS_REVIEW_RUNLOG:-$skill_dir/runlog.jsonl}"
profile_file="$skill_dir/references/reviewer_profiles.json"

# Full fleet — keep in sync with run_reviewers.sh dispatch and analyze_runlog.sh.
REVIEWERS=(codex antigravity gemini-pro kimi glm deepseek mimo minimax qwen devstral laguna kat north nemotron kimi27)

structured=""
if [[ -f "$runlog" ]]; then
  structured=$(jq -c 'select(.reviewers != null)' "$runlog" 2>/dev/null | tail -n "$recent")
fi

# provider_of <reviewer> — profile `.provider` wins, else the built-in map.
provider_of() {
  local r="$1" p=""
  if [[ -f "$profile_file" ]]; then
    p="$(jq -r --arg r "$r" '.[$r].provider // empty' "$profile_file" 2>/dev/null)"
  fi
  if [[ -z "$p" ]]; then
    case "$r" in
      codex) p="openai" ;;
      antigravity|gemini-pro) p="google" ;;
      kimi) p="moonshot" ;;
      glm) p="zhipu" ;;
      deepseek) p="deepseek" ;;
      mimo) p="xiaomi" ;;
      minimax) p="minimax" ;;
      qwen) p="alibaba" ;;
      devstral) p="mistral" ;;
      laguna) p="poolside" ;;
      kat) p="kuaishou" ;;
      north) p="cohere" ;;
      nemotron) p="nvidia" ;;
      kimi27) p="moonshot" ;;
      *) p="unknown" ;;
    esac
  fi
  printf '%s' "$p"
}

score_reviewer() {
  local r="$1" provider="$2"
  printf '%s\n' "$structured" | jq -s --arg r "$r" --arg provider "$provider" '
    map(.reviewers[$r] // {status:"skipped"}) as $rs
    # Sleep-killed timeouts (2026-07-03): a timed_out sample whose wall-clock
    # duration overran the ENFORCED budget by >60s means the machine slept
    # mid-run (gtimeout/curl timers freeze during system sleep) — it says
    # nothing about the provider and must not ding reliability. Excluded from
    # the attempt set entirely. ok-status over-budget runs are KEPT: they
    # delivered a review, and their durations feed the --fast speed signal.
    | ($rs | map(select((.status == "timed_out")
                        and ((.timeout_budget_s // 0) > 0)
                        and ((.duration_s // 0) > ((.timeout_budget_s // 0) + 60))))
           | length) as $sleep_excluded
    | ($rs | map(select(.status != "skipped"
                        and (((.status == "timed_out")
                              and ((.timeout_budget_s // 0) > 0)
                              and ((.duration_s // 0) > ((.timeout_budget_s // 0) + 60))) | not)))) as $attempts
    | ($attempts | length) as $n
    | ($attempts | map(select(.status == "ok"))    | length) as $ok
    | ($attempts | map(select(.status == "quota")) | length) as $quota
    | ($attempts | map(select(.findings_total != null))) as $scored
    | ($scored | map(.findings_total      // 0) | add // 0) as $findings
    | ($scored | map(.findings_convergent // 0) | add // 0) as $convergent
    | ($scored | map(.findings_dropped    // 0) | add // 0) as $dropped
    | (if $n == 0 then null else ($ok / $n) end) as $rel
    | (if $n == 0 then "never_run" else ($attempts | last | .status) end) as $latest
    | ($attempts | map(.duration_s // 0) | sort) as $durs
    | ($durs | length) as $dn
    | (if $dn == 0 then 0 else $durs[($dn / 2 | floor)] end) as $p50
    | (if $n == 0 then 50
       elif $findings > 0 then
         (100 * (0.45 * $rel
                 + 0.35 * ($convergent / $findings)
                 + 0.20 * (1 - ($dropped / $findings)))) | round
       else (100 * $rel * 0.75) | round
       end) as $score
    | { reviewer: $r,
        provider: $provider,
        attempts: $n,
        ok: $ok,
        quota: $quota,
        reliability_pct: (if $rel == null then null else ($rel * 100 | round) end),
        findings: $findings,
        convergent: $convergent,
        dropped: $dropped,
        latest_status: $latest,
        p50_duration_s: $p50,
        sleep_excluded: $sleep_excluded,
        rookie: ($n == 0),
        score: $score }
  '
}

rows=""
for r in "${REVIEWERS[@]}"; do
  row="$(score_reviewer "$r" "$(provider_of "$r")")"
  rows="$rows$row"$'\n'
done

case "$mode" in
  json)
    printf '%s' "$rows" | jq -s 'sort_by(-.score)'
    ;;
  table)
    echo "── cross-review leaderboard (window: last $recent structured runs) ──"
    printf '%s' "$rows" | jq -s -r '
      sort_by(-.score) | to_entries[] |
      "  #\(.key + 1)  \(.value.reviewer) [\(.value.provider)] — score \(.value.score)\(if .value.rookie then " (rookie prior)" else "" end)  ·  runs \(.value.ok)/\(.value.attempts)\(if .value.quota > 0 then " (quota ×\(.value.quota))" else "" end)\(if (.value.sleep_excluded // 0) > 0 then " (sleep-excl ×\(.value.sleep_excluded))" else "" end)\(if .value.findings > 0 then "  ·  findings \(.value.findings), convergent \(.value.convergent), disproven \(.value.dropped)" else "" end)  ·  p50 \(.value.p50_duration_s)s  ·  last: \(.value.latest_status)"
    '
    echo "──"
    echo "  score = 45% reliability + 35% cross-provider convergence + 20% fact-check survival"
    echo "  (telemetry-only reviewers: reliability × 0.75 · never-run reviewers: rookie prior 50)"
    ;;
  *)
    echo "unknown mode: $mode (use table|json)" >&2
    exit 2
    ;;
esac
