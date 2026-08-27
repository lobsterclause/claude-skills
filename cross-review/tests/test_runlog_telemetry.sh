#!/usr/bin/env bash
# test_runlog_telemetry.sh — offline fixture tests for round wall-clock,
# trailing-reviewer, phases (#91), telemetry completeness (#89), and the
# roster-draw-audit section (#103, analyze half) added to append_runlog.sh /
# analyze_runlog.sh.
#
# Standalone: run directly, or from run_tests.sh. NO network, NO reviewer
# CLIs, NO tokens — everything is fixture JSON under a temp dir.
#
# Run:  bash tests/test_runlog_telemetry.sh
# Exit: 0 all green, 1 any failure.
#
# Portability: macOS bash 3.2 + ubuntu bash 5; needs jq.

set -uo pipefail

SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
S="$SKILL_DIR/scripts"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

PASS=0
FAIL=0
ok()  { echo "  ok   $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL $1"; FAIL=$((FAIL + 1)); }
assert_eq() {
  if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 (got: '$2' want: '$3')"; fi
}
assert_contains() {
  if [[ "$2" == *"$3"* ]]; then ok "$1"; else bad "$1 (no '$3' in output)"; fi
}

# UTC epoch->compact-stamp helper, portable across BSD (macOS) and GNU date.
utc_stamp_for_epoch() {
  local epoch="$1"
  if date -u -r 0 +%Y%m%dT%H%M%S >/dev/null 2>&1; then
    date -u -r "$epoch" +%Y%m%dT%H%M%S
  else
    date -u -d "@$epoch" +%Y%m%dT%H%M%S
  fi
}

# ── fixture (a): round_wall_s + trailing_reviewer derived from context.json
# + reviewer meta ────────────────────────────────────────────────────────────
echo "── append_runlog.sh: round_wall_s + trailing_reviewer (#91) ──"
NOW_EPOCH="$(date +%s)"
STARTED_90S_AGO="$(utc_stamp_for_epoch $((NOW_EPOCH - 90)))"
RUN_A="$T/run-a"; mkdir -p "$RUN_A/raw"
printf '{"started_at":"%s"}\n' "$STARTED_90S_AGO" >"$RUN_A/context.json"
printf '{"exit_code":0,"duration_s":30,"timed_out":false,"output_bytes":10,"attempt":1,"timeout_budget_s":300}\n' >"$RUN_A/raw/codex.meta.json"
printf '{"exit_code":0,"duration_s":75,"timed_out":false,"output_bytes":10,"attempt":1,"timeout_budget_s":600}\n' >"$RUN_A/raw/kimi.meta.json"
LOG_A="$T/log-a.jsonl"
CROSS_REVIEW_RUNLOG="$LOG_A" bash "$S/append_runlog.sh" \
  --run-dir "$RUN_A" --project test --base main --pr - --pass 1 \
  --verdict CLEAN --convergent 0 --top "-" >/dev/null 2>&1
ENTRY_A="$(tail -1 "$LOG_A")"
RWS_A="$(jq -r '.round_wall_s' <<<"$ENTRY_A")"
if [[ "$RWS_A" =~ ^[0-9]+$ ]] && [[ "$RWS_A" -ge 90 ]]; then
  ok "round_wall_s >= 90 from a context.json started 90s ago (got $RWS_A)"
else
  bad "round_wall_s >= 90 from a context.json started 90s ago (got: '$RWS_A' want: >=90)"
fi
assert_eq "trailing_reviewer.reviewer is the 75s seat" \
  "$(jq -r '.trailing_reviewer.reviewer' <<<"$ENTRY_A")" "kimi"
assert_eq "trailing_reviewer.duration_s matches the max" \
  "$(jq -r '.trailing_reviewer.duration_s' <<<"$ENTRY_A")" "75"

# ── fixture (b): no context.json, no --phases → keys absent ─────────────────
echo "── append_runlog.sh: round_wall_s/phases absent without inputs (#91) ──"
RUN_B="$T/run-b"; mkdir -p "$RUN_B/raw"
printf '{"exit_code":0,"duration_s":10,"timed_out":false,"output_bytes":10,"attempt":1,"timeout_budget_s":300}\n' >"$RUN_B/raw/codex.meta.json"
LOG_B="$T/log-b.jsonl"
CROSS_REVIEW_RUNLOG="$LOG_B" bash "$S/append_runlog.sh" \
  --run-dir "$RUN_B" --project test --base main --pr - --pass 1 \
  --verdict CLEAN --convergent 0 --top "-" >/dev/null 2>&1
ENTRY_B="$(tail -1 "$LOG_B")"
assert_eq "no context.json -> no round_wall_s key" \
  "$(jq 'has("round_wall_s")' <<<"$ENTRY_B")" "false"
assert_eq "no --phases -> no phases key" \
  "$(jq 'has("phases")' <<<"$ENTRY_B")" "false"
# trailing_reviewer IS derivable here (one meta with duration_s) — confirm it
# still fires independently of context.json/--phases being present.
assert_eq "trailing_reviewer still derives from meta alone" \
  "$(jq -r '.trailing_reviewer.reviewer' <<<"$ENTRY_B")" "codex"

# ── fixture (c): --phases copies verbatim, absent keys stay absent ──────────
echo "── append_runlog.sh: --phases attaches verbatim (#91) ──"
cat >"$T/phases.json" <<'EOF'
{"worktree_s": 12, "dispatch_s": 340, "synthesis_s": 8}
EOF
LOG_C="$T/log-c.jsonl"
CROSS_REVIEW_RUNLOG="$LOG_C" bash "$S/append_runlog.sh" \
  --run-dir "$RUN_B" --project test --base main --pr - --pass 1 \
  --verdict CLEAN --convergent 0 --top "-" --phases "$T/phases.json" >/dev/null 2>&1
ENTRY_C="$(tail -1 "$LOG_C")"
assert_eq "phases object copied verbatim" \
  "$(jq -Sc '.phases' <<<"$ENTRY_C")" "$(jq -Sc . "$T/phases.json")"
assert_eq "skipped phase key (anchor_s) stays absent, not 0" \
  "$(jq 'has("anchor_s")' <<<"$(jq '.phases' <<<"$ENTRY_C")")" "false"

# ── fixture (d): omitting --run-id warns to stderr, still appends ───────────
echo "── append_runlog.sh: missing --run-id warns but never blocks (#89) ──"
LOG_D="$T/log-d.jsonl"
CROSS_REVIEW_RUNLOG="$LOG_D" bash "$S/append_runlog.sh" \
  --run-dir "$RUN_B" --project test --base main --pr - --pass 1 \
  --verdict CLEAN --convergent 0 --top "-" >/dev/null 2>"$T/d.err"
RC_D=$?
assert_eq "append still exits 0 without --run-id" "$RC_D" "0"
assert_contains "stderr names --run-id" "$(cat "$T/d.err")" "--run-id"
assert_eq "entry still written" "$(wc -l <"$LOG_D" | tr -d ' ')" "1"

# ── fixture (e): telemetry completeness — warn threshold + report block ─────
echo "── analyze_runlog.sh: telemetry completeness (#89) ──"
COMPLOG="$T/completeness-runlog.jsonl"
: >"$COMPLOG"
for i in 1 2 3 4 5 6; do
  printf '{"ts":"2026-08-0%dT00:00:00Z","run_id":"r%d","reviewers":{"codex":{"status":"ok","duration_s":5,"model":"m","cost_usd":0.01,"context_access":"agent","findings_total":1}}}\n' "$i" "$i" >>"$COMPLOG"
done
for i in 7 8 9; do
  printf '{"ts":"2026-08-0%dT00:00:00Z","reviewers":{"codex":{"status":"ok","duration_s":5}}}\n' "$i" >>"$COMPLOG"
done
printf '{"ts":"2026-08-10T00:00:00Z","reviewers":{"codex":{"status":"ok","duration_s":5}}}\n' >>"$COMPLOG"
N_COMP="$(wc -l <"$COMPLOG" | tr -d ' ')"
assert_eq "fixture has 10 entries" "$N_COMP" "10"
COMP_WARN="$(CROSS_REVIEW_RUNLOG="$COMPLOG" bash "$S/analyze_runlog.sh" --mode warn 2>&1)"
assert_contains "warn fires on low run_id completeness" "$COMP_WARN" "WARN"
assert_contains "warn names the rate (60%, pinned)" "$COMP_WARN" "60%"
COMP_REPORT="$(CROSS_REVIEW_RUNLOG="$COMPLOG" bash "$S/analyze_runlog.sh" --mode report 2>&1)"
assert_contains "report lists run_id completeness" "$COMP_REPORT" "run_id="
assert_contains "report lists findings completeness" "$COMP_REPORT" "findings="
assert_contains "report lists roster_decision completeness" "$COMP_REPORT" "roster_decision="
assert_contains "report lists model completeness" "$COMP_REPORT" "model="
assert_contains "report lists cost_usd completeness" "$COMP_REPORT" "cost_usd="
assert_contains "report lists context_access completeness" "$COMP_REPORT" "context_access="

# ── fixture (f): round wall-clock p50/p95 exclude wall_over_budget, critical
# path table ──────────────────────────────────────────────────────────────
echo "── analyze_runlog.sh: round wall-clock stats + critical path (#91) ──"
WALLOG="$T/wall-runlog.jsonl"
: >"$WALLOG"
# 9 clean entries: durations 100..180 step 10 (p50/p95 computable), trailer
# alternates codex/kimi so the critical-path table has two rows with counts.
durs=(100 110 120 130 140 150 160 170 180)
idx=0
for d in "${durs[@]}"; do
  idx=$((idx + 1))
  if (( idx % 2 == 0 )); then trailer="kimi"; else trailer="codex"; fi
  printf '{"ts":"2026-08-1%dT00:00:00Z","reviewers":{"codex":{"status":"ok","duration_s":5}},"round_wall_s":%d,"trailing_reviewer":{"reviewer":"%s","duration_s":%d}}\n' \
    "$idx" "$d" "$trailer" "$d" >>"$WALLOG"
done
# 10th entry: sleep-suspect, must be excluded from p50/p95.
printf '{"ts":"2026-08-20T00:00:00Z","reviewers":{"codex":{"status":"ok","duration_s":5}},"round_wall_s":99999,"wall_over_budget":true,"trailing_reviewer":{"reviewer":"codex","duration_s":99999}}\n' >>"$WALLOG"
N_WALL="$(wc -l <"$WALLOG" | tr -d ' ')"
assert_eq "fixture has 10 entries" "$N_WALL" "10"
WALL_REPORT="$(CROSS_REVIEW_RUNLOG="$WALLOG" bash "$S/analyze_runlog.sh" --mode report 2>&1)"
assert_contains "report prints round wall-clock p50" "$WALL_REPORT" "p50=140s"
assert_contains "report prints round wall-clock p95" "$WALL_REPORT" "p95=180s"
case "$WALL_REPORT" in
  *"99999"*) bad "wall_over_budget entry leaked into p50/p95 stats" ;;
  *) ok "wall_over_budget entry excluded from p50/p95 stats" ;;
esac
assert_contains "critical path lists codex" "$WALL_REPORT" "codex: 5"
assert_contains "critical path lists kimi" "$WALL_REPORT" "kimi: 4"

# ── fixture (g): roster-audit section header + starved-seat WARN ────────────
echo "── analyze_runlog.sh: roster draw audit section (#103) ──"
ROSTERLOG="$T/roster-runlog.jsonl"
: >"$ROSTERLOG"
# 12 entries where "grok" always has positive weight as a candidate but is
# never selected -- audit_roster.sh's starved condition (weight>0 in >=10
# candidate rounds, draws==0).
for i in $(seq -w 1 12); do
  printf '{"ts":"2026-08-%sT00:00:00Z","reviewers":{"codex":{"status":"ok","duration_s":5}},"roster_decision":{"policy_version":"weighted-draw-v1","candidates":[{"reviewer":"codex","weight":10,"selected":true},{"reviewer":"grok","weight":5,"selected":false}]}}\n' "$i" >>"$ROSTERLOG"
done
ROSTER_REPORT="$(CROSS_REVIEW_RUNLOG="$ROSTERLOG" bash "$S/analyze_runlog.sh" --mode report 2>&1)"
assert_contains "report contains the roster draw audit section header" "$ROSTER_REPORT" "roster draw audit"
assert_contains "report surfaces the starved seat" "$ROSTER_REPORT" "grok starved"
ROSTER_WARN="$(CROSS_REVIEW_RUNLOG="$ROSTERLOG" bash "$S/analyze_runlog.sh" --mode warn 2>&1)"
assert_contains "warn mode surfaces the starved-seat WARN line" "$ROSTER_WARN" "WARN grok starved"

echo ""
echo "══ $PASS passed, $FAIL failed ══"
[[ "$FAIL" -eq 0 ]] || exit 1
