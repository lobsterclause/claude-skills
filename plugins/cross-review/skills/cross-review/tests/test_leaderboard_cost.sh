#!/usr/bin/env bash
# test_leaderboard_cost.sh — standalone fixture tests for leaderboard.sh's
# cost-per-kept-finding scoring (#92) and --mode report (#105).
#
# STANDALONE: no network, no reviewer CLIs. Follows the preamble conventions
# of tests/run_tests.sh (PASS/FAIL counters, assert_eq/assert_contains,
# CROSS_REVIEW_RUNLOG / CROSS_REVIEW_FINDING_EVENTS overrides) but is its own
# harness — leaderboard.sh, reviewer_profiles.json and this file are the only
# things this shard owns; run_tests.sh is a sibling shard's file.
#
# Run:  bash tests/test_leaderboard_cost.sh
# Exit: 0 all green, 1 any failure.

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

command -v jq >/dev/null 2>&1 || { echo "test_leaderboard_cost: jq required" >&2; exit 1; }

# ── fixture reviewer_profiles.json (isolated from the real profiles file —
#    only the seats this test exercises need pricing) ──────────────────────
PROFILES="$T/reviewer_profiles.json"
cat >"$PROFILES" <<'EOF'
{
  "$schema": "./reviewer_profiles.schema.md",
  "glm": { "provider": "zhipu", "pricing": null },
  "qwen": { "provider": "alibaba", "pricing": { "prompt_per_m": 1.00, "completion_per_m": 3.00 } },
  "kat": { "provider": "kuaishou", "pricing": null },
  "devstral": { "provider": "mistral", "pricing": null }
}
EOF

# ── fixture runlog: seat X (glm) billed, seat Y (qwen) token-only, seat Z
#    (kat) billed-but-zero-kept, seat W (devstral) tokens+diff_lines ────────
RUNLOG="$T/runlog.jsonl"
cat >"$RUNLOG" <<'EOF'
{"ts":"2026-08-27T01:00:00Z","run_id":"r1","reviewers":{"glm":{"status":"ok","exit_code":0,"duration_s":50,"output_bytes":10,"timeout_budget_s":600,"cost_usd":0.10}}}
{"ts":"2026-08-27T02:00:00Z","run_id":"r2","reviewers":{"glm":{"status":"ok","exit_code":0,"duration_s":50,"output_bytes":10,"timeout_budget_s":600,"cost_usd":0.30}}}
{"ts":"2026-08-27T03:00:00Z","run_id":"r3","reviewers":{"qwen":{"status":"ok","exit_code":0,"duration_s":40,"output_bytes":10,"timeout_budget_s":600,"tokens_prompt":1000000,"tokens_completion":100000}}}
{"ts":"2026-08-27T04:00:00Z","run_id":"r4","reviewers":{"kat":{"status":"ok","exit_code":0,"duration_s":10,"output_bytes":10,"timeout_budget_s":600,"cost_usd":0.20}}}
{"ts":"2026-08-27T05:00:00Z","run_id":"r5","diff_size":{"files":3,"lines":100},"reviewers":{"devstral":{"status":"ok","exit_code":0,"duration_s":20,"output_bytes":10,"timeout_budget_s":600,"tokens_prompt":4000,"tokens_completion":1000}}}
EOF

# ── fixture finding_events: glm has 4 kept findings (1 Critical, 3 not);
#    kat has 0 kept findings at all ─────────────────────────────────────────
EVENTS="$T/finding_events.jsonl"
cat >"$EVENTS" <<'EOF'
{"event":"proposed","finding_id":"f1","run_id":"r1","reviewer":"glm","severity":"Critical","all_sources":["glm"],"ts":"2026-08-27T01:00:01Z"}
{"event":"factcheck_kept","finding_id":"f1","run_id":"r1","ts":"2026-08-27T01:00:02Z"}
{"event":"proposed","finding_id":"f2","run_id":"r1","reviewer":"glm","severity":"Medium","all_sources":["glm"],"ts":"2026-08-27T01:00:01Z"}
{"event":"factcheck_kept","finding_id":"f2","run_id":"r1","ts":"2026-08-27T01:00:02Z"}
{"event":"proposed","finding_id":"f3","run_id":"r2","reviewer":"glm","severity":"Low","all_sources":["glm"],"ts":"2026-08-27T02:00:01Z"}
{"event":"factcheck_kept","finding_id":"f3","run_id":"r2","ts":"2026-08-27T02:00:02Z"}
{"event":"proposed","finding_id":"f4","run_id":"r2","reviewer":"glm","severity":"Medium","all_sources":["glm"],"ts":"2026-08-27T02:00:01Z"}
{"event":"factcheck_kept","finding_id":"f4","run_id":"r2","ts":"2026-08-27T02:00:02Z"}
{"event":"proposed","finding_id":"f5","run_id":"r4","reviewer":"kat","severity":"Low","all_sources":["kat"],"ts":"2026-08-27T04:00:01Z"}
{"event":"factcheck_dropped","finding_id":"f5","run_id":"r4","ts":"2026-08-27T04:00:02Z"}
EOF

RUN_LB() {
  CROSS_REVIEW_RUNLOG="$RUNLOG" CROSS_REVIEW_FINDING_EVENTS="$EVENTS" \
    bash "$S/leaderboard.sh" --profiles "$PROFILES" "$@"
}

echo "── leaderboard.sh --mode json: cost-per-kept-finding fields ──"
LB="$(RUN_LB --mode json)"

# (a) seat X (glm): 2 billed runs (0.10 + 0.30 = 0.40), 4 kept findings, 1
# Critical kept → $/kept 0.10, $/kept Critical-or-High 0.40 (pinned strings).
assert_eq "glm cost_per_kept (0.40 / 4 kept)" \
  "$(jq -r '.[] | select(.reviewer=="glm") | .cost_per_kept' <<<"$LB")" "0.10"
assert_eq "glm cost_per_kept_ch (0.40 / 1 kept Critical)" \
  "$(jq -r '.[] | select(.reviewer=="glm") | .cost_per_kept_ch' <<<"$LB")" "0.40"
assert_eq "glm cost_estimated false (billed cost_usd on both runs)" \
  "$(jq -r '.[] | select(.reviewer=="glm") | .cost_estimated' <<<"$LB")" "false"

# (b) seat Y (qwen): no cost_usd; 1,000,000 prompt + 100,000 completion
# tokens at pricing 1.00/3.00 per M → estimated cost 1.30, flagged estimated.
assert_eq "qwen estimated avg_cost_usd (tokens x pricing)" \
  "$(jq -r '.[] | select(.reviewer=="qwen") | .avg_cost_usd' <<<"$LB")" "1.3"
assert_eq "qwen cost_estimated true (no billed cost_usd, pricing present)" \
  "$(jq -r '.[] | select(.reviewer=="qwen") | .cost_estimated' <<<"$LB")" "true"

# (c) seat Z (kat): billed cost but zero kept findings → "—", not a
# divide-by-zero crash.
assert_eq "kat cost_per_kept with zero kept findings shows em dash" \
  "$(jq -r '.[] | select(.reviewer=="kat") | .cost_per_kept' <<<"$LB")" "—"
assert_eq "kat cost_per_kept_ch with zero kept findings shows em dash" \
  "$(jq -r '.[] | select(.reviewer=="kat") | .cost_per_kept_ch' <<<"$LB")" "—"

# (d) every pre-existing key survives, new keys are additive only.
for key in reviewer provider attempts ok quota reliability_pct findings \
           convergent dropped latest_status p50_duration_s avg_cost_usd \
           sleep_excluded rookie score_basis ev_findings ev_solo ev_dropped \
           ev_unanchored score; do
  present="$(jq -r --arg k "$key" '.[] | select(.reviewer=="glm") | has($k)' <<<"$LB")"
  assert_eq "pre-existing key '$key' still present" "$present" "true"
done
for key in cost_per_kept cost_per_kept_ch cost_estimated; do
  present="$(jq -r --arg k "$key" '.[] | select(.reviewer=="glm") | has($k)' <<<"$LB")"
  assert_eq "new key '$key' present" "$present" "true"
done

# (f) tokens-per-diff-line: devstral, 5,000 tokens / 100 diff lines → 50.
assert_eq "devstral tokens_per_diff_line (5000 tokens / 100 lines)" \
  "$(jq -r '.[] | select(.reviewer=="devstral") | .tokens_per_diff_line' <<<"$LB")" "50"

echo "── leaderboard.sh --mode report ──"
REPORT="$(RUN_LB --mode report 2>&1)"
assert_contains "report mode prints a severity calibration heading" "$REPORT" "severity calibration"
assert_contains "report mode prints a fleet \$/round line" "$REPORT" "\$/round"
assert_contains "report mode fleet line carries p50" "$REPORT" "p50"
assert_contains "report mode fleet line carries p95" "$REPORT" "p95"

echo
echo "══ $PASS passed, $FAIL failed ══"
[[ "$FAIL" -eq 0 ]]
