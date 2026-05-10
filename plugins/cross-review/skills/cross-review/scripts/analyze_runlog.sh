#!/usr/bin/env bash
# analyze_runlog.sh — read runlog.jsonl and emit a per-reviewer reliability
# report plus tuning suggestions. Read by:
#   - SKILL.md step 1.5 (pre-run check, --recent <n>) — surfaces warnings
#     when a reviewer's recent timeout rate or empty-output rate is high.
#   - /cross-review --self-check (--mode report) — full health snapshot,
#     written for humans to scan and humans/Claude to use as input to
#     editing reviewer_profiles.json.
#
# Never edits reviewer_profiles.json itself — surfaces suggestions only.
# The intentional manual-confirm step is the same pattern splitstream uses
# for its pre-flight table.
#
# Usage:
#   analyze_runlog.sh [--recent <n>] [--mode warn|report] [--quiet]
#
#   --recent <n>      window (default 20). Older entries ignored.
#   --mode warn       emit one-line warnings when a reviewer is degraded
#                     (timeout rate >30% OR empty-output rate >40% OR
#                     reliability <60% over the window). Default.
#   --mode report     emit the full report (reliability %, p50/p95 duration,
#                     timeout rate, empty rate, suggested timeout edits).
#   --quiet           silence informational lines; warnings/report still print.
#
# Reads only the structured Phase-2 entries (those with a `reviewers` field).
# Hand-curated legacy entries are silently skipped — they don't have the
# fields needed for telemetry math.

set -uo pipefail

recent=20
mode="warn"
quiet=0

need_val() {
  # set -u + missing flag value crashes with raw "$2: unbound variable" instead
  # of a usage hint. Check argc before consuming the next positional.
  local flag="$1"
  local argc="$2"
  if [[ "$argc" -lt 2 ]]; then
    echo "missing value for $flag" >&2
    exit 2
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --recent) need_val --recent "$#"; recent="$2"; shift 2 ;;
    --mode)   need_val --mode   "$#"; mode="$2";   shift 2 ;;
    --quiet)  quiet=1;     shift ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

if ! command -v jq >/dev/null 2>&1; then
  echo "analyze_runlog: jq required (brew install jq)" >&2
  exit 1
fi

skill_dir="$(cd "$(dirname "$0")/.." && pwd)"
runlog="$skill_dir/runlog.jsonl"
profile_file="$skill_dir/references/reviewer_profiles.json"

if [[ ! -f "$runlog" ]]; then
  [[ "$quiet" -eq 0 ]] && echo "no runlog at $runlog" >&2
  exit 0
fi

# Filter to structured entries (have .reviewers), keep last $recent.
# Legacy hand-curated entries don't have .reviewers and are skipped.
structured=$(jq -c 'select(.reviewers != null)' "$runlog" 2>/dev/null | tail -n "$recent")
n_entries=$(printf '%s\n' "$structured" | grep -c '^.' || true)

if [[ "$n_entries" -eq 0 ]]; then
  [[ "$quiet" -eq 0 ]] && echo "analyze_runlog: no structured entries yet (need at least 1 Phase-2 run)" >&2
  exit 0
fi

# Per-reviewer aggregation.
# For each reviewer in {codex, gemini, kimi}, compute:
#   total: number of times the reviewer was attempted (status != "skipped")
#   ok: status == "ok"
#   timed_out: status == "timed_out"
#   empty: status == "empty" (ran rc=0 but produced 0 bytes)
#   failed: status == "failed"
#   p50_duration, p95_duration, current_timeout
analyze_reviewer() {
  local r="$1"
  printf '%s\n' "$structured" | jq -s --arg r "$r" '
    map(.reviewers[$r] // {status:"skipped"}) as $rs
    | ($rs | map(select(.status != "skipped"))) as $attempts
    | ($attempts | length) as $total
    | ($attempts | map(select(.status == "ok"))        | length) as $ok
    | ($attempts | map(select(.status == "timed_out")) | length) as $to
    | ($attempts | map(select(.status == "empty"))     | length) as $empty
    | ($attempts | map(select(.status == "failed"))    | length) as $failed
    | ($attempts | map(.duration_s // 0) | sort) as $durs
    | ($durs | length) as $dn
    | (if $dn == 0 then 0 else $durs[($dn / 2 | floor)] end) as $p50
    | (if $dn == 0 then 0 else $durs[($dn * 0.95 | floor) | (if . >= $dn then $dn - 1 else . end)] end) as $p95
    | ($attempts | map(.timeout_budget_s // 0) | max // 0) as $cur_to
    | {
        reviewer: $r,
        total: $total,
        ok: $ok,
        timed_out: $to,
        empty: $empty,
        failed: $failed,
        reliability: (if $total == 0 then null else (($ok * 100) / $total | floor) end),
        timeout_rate: (if $total == 0 then null else (($to * 100) / $total | floor) end),
        empty_rate:   (if $total == 0 then null else (($empty * 100) / $total | floor) end),
        p50_duration_s: $p50,
        p95_duration_s: $p95,
        current_timeout_budget_s: $cur_to
      }
  '
}

codex_stats=$(analyze_reviewer codex)
gemini_stats=$(analyze_reviewer gemini)
kimi_stats=$(analyze_reviewer kimi)

# Suggest timeout bump if p95 is within 10% of current budget OR timeout rate >20%.
suggest_timeout_bump() {
  local stats="$1"
  echo "$stats" | jq -r '
    if .total == 0 or .current_timeout_budget_s == 0 then empty
    elif .timeout_rate >= 20 then
      "  SUGGEST: bump \(.reviewer).timeout_s from \(.current_timeout_budget_s) → \(.current_timeout_budget_s + 200) (timeout rate \(.timeout_rate)% over window)"
    elif (.p95_duration_s * 10) >= (.current_timeout_budget_s * 9) then
      "  SUGGEST: bump \(.reviewer).timeout_s from \(.current_timeout_budget_s) → \(.current_timeout_budget_s + 100) (p95 \(.p95_duration_s)s within 10% of budget)"
    else empty end
  '
}

# Warning thresholds.
emit_warning() {
  local stats="$1"
  echo "$stats" | jq -r '
    if .total < 3 then empty   # not enough data
    elif .timeout_rate > 30 then
      "  WARN: \(.reviewer) timed out \(.timeout_rate)% of last \(.total) runs (p95 \(.p95_duration_s)s, budget \(.current_timeout_budget_s)s) — consider --timeout-\(.reviewer) \(.current_timeout_budget_s + 200)"
    elif .empty_rate > 40 then
      "  WARN: \(.reviewer) empty-output rate \(.empty_rate)% over last \(.total) runs — likely auth/wrapper issue, not a timeout fix"
    elif .reliability != null and .reliability < 60 then
      "  WARN: \(.reviewer) reliability \(.reliability)% over last \(.total) runs (ok=\(.ok), timeout=\(.timed_out), empty=\(.empty), failed=\(.failed))"
    else empty end
  '
}

case "$mode" in
  warn)
    out=$({
      emit_warning "$codex_stats"
      emit_warning "$gemini_stats"
      emit_warning "$kimi_stats"
    })
    if [[ -n "$out" ]]; then
      echo "── cross-review pre-run check (last $n_entries runs) ──"
      echo "$out"
      echo "──"
    elif [[ "$quiet" -eq 0 ]]; then
      echo "cross-review pre-run check: all reviewers nominal over last $n_entries runs" >&2
    fi
    ;;
  report)
    echo "── cross-review reviewer health (last $n_entries runs) ──"
    for stats in "$codex_stats" "$gemini_stats" "$kimi_stats"; do
      echo "$stats" | jq -r '
        if .total == 0 then "  \(.reviewer): no data in window"
        else
          "  \(.reviewer): reliability=\(.reliability // "—")%  ok=\(.ok)/\(.total)  timed_out=\(.timed_out)  empty=\(.empty)  failed=\(.failed)  p50=\(.p50_duration_s)s  p95=\(.p95_duration_s)s  budget=\(.current_timeout_budget_s)s"
        end'
    done
    echo ""
    echo "── tuning suggestions ──"
    suggestions=$({
      suggest_timeout_bump "$codex_stats"
      suggest_timeout_bump "$gemini_stats"
      suggest_timeout_bump "$kimi_stats"
      emit_warning "$codex_stats"
      emit_warning "$gemini_stats"
      emit_warning "$kimi_stats"
    } | sort -u)
    if [[ -n "$suggestions" ]]; then
      echo "$suggestions"
      echo ""
      echo "Edit $profile_file to apply (or pass per-run flags via --timeout-<reviewer>)."
    else
      echo "  none — all reviewers within tolerance"
    fi
    echo "──"
    ;;
  *)
    echo "unknown mode: $mode (use warn|report)" >&2
    exit 2
    ;;
esac
