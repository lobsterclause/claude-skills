#!/usr/bin/env bash
# test_leaderboard_epochs.sh — standalone fixture tests for leaderboard.sh's
# model-epoch scoring (#90), the new finding_events.jsonl terminal events it
# now folds into the value/survival axes (#88), and the --mode report
# additions (#93: epoch boundary dates, per-context_mode kept/drop rate).
#
# STANDALONE: no network, no reviewer CLIs. Follows the preamble conventions
# of tests/test_leaderboard_cost.sh (PASS/FAIL counters, assert_eq/
# assert_contains, CROSS_REVIEW_RUNLOG / CROSS_REVIEW_FINDING_EVENTS
# overrides, its own harness) — leaderboard.sh and this file are the only
# things this shard owns.
#
# Run:  bash tests/test_leaderboard_epochs.sh
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
command -v jq >/dev/null 2>&1 || { echo "test_leaderboard_epochs: jq required" >&2; exit 1; }

RUN_LB() {
  # --recent 200: the combined fixture below has more structured rows than
  # the default 40-row window, and this suite is about epoch/terminal-event
  # logic, not window truncation -- keep the whole fixture in scope.
  CROSS_REVIEW_RUNLOG="$RUNLOG" CROSS_REVIEW_FINDING_EVENTS="$EVENTS" \
    bash "$S/leaderboard.sh" --recent 200 "$@"
}

# ── main combined fixture ───────────────────────────────────────────────────
RUNLOG="$T/runlog.jsonl"
cat >"$RUNLOG" <<'EOF'
{"ts":"2026-08-01T01:00:00Z","run_id":"df1","reviewers":{"deepseek":{"status":"ok","duration_s":10,"model":"deepseek/v4-flash","findings_total":1,"findings_convergent":0,"findings_dropped":1}}}
{"ts":"2026-08-01T02:00:00Z","run_id":"df2","reviewers":{"deepseek":{"status":"ok","duration_s":10,"model":"deepseek/v4-flash","findings_total":1,"findings_convergent":0,"findings_dropped":1}}}
{"ts":"2026-08-01T03:00:00Z","run_id":"df3","reviewers":{"deepseek":{"status":"ok","duration_s":10,"model":"deepseek/v4-flash","findings_total":1,"findings_convergent":0,"findings_dropped":1}}}
{"ts":"2026-08-01T04:00:00Z","run_id":"df4","reviewers":{"deepseek":{"status":"ok","duration_s":10,"model":"deepseek/v4-flash","findings_total":1,"findings_convergent":0,"findings_dropped":1}}}
{"ts":"2026-08-01T05:00:00Z","run_id":"df5","reviewers":{"deepseek":{"status":"ok","duration_s":10,"model":"deepseek/v4-flash","findings_total":1,"findings_convergent":0,"findings_dropped":1}}}
{"ts":"2026-08-01T06:00:00Z","run_id":"df6","reviewers":{"deepseek":{"status":"ok","duration_s":10,"model":"deepseek/v4-flash","findings_total":1,"findings_convergent":0,"findings_dropped":1}}}
{"ts":"2026-08-01T07:00:00Z","run_id":"df7","reviewers":{"deepseek":{"status":"ok","duration_s":10,"model":"deepseek/v4-flash","findings_total":1,"findings_convergent":0,"findings_dropped":1}}}
{"ts":"2026-08-01T08:00:00Z","run_id":"df8","reviewers":{"deepseek":{"status":"ok","duration_s":10,"model":"deepseek/v4-flash","findings_total":1,"findings_convergent":0,"findings_dropped":1}}}
{"ts":"2026-08-01T09:00:00Z","run_id":"df9","reviewers":{"deepseek":{"status":"ok","duration_s":10,"model":"deepseek/v4-flash","findings_total":1,"findings_convergent":0,"findings_dropped":1}}}
{"ts":"2026-08-02T01:00:00Z","run_id":"df10","reviewers":{"deepseek":{"status":"ok","duration_s":10,"model":"deepseek/v4-flash","findings_total":1,"findings_convergent":0,"findings_dropped":1}}}
{"ts":"2026-08-05T01:00:00Z","run_id":"dp1","reviewers":{"deepseek":{"status":"ok","duration_s":10,"model":"deepseek/v4-pro","findings_total":2,"findings_convergent":2,"findings_dropped":0}}}
{"ts":"2026-08-05T02:00:00Z","run_id":"dp2","reviewers":{"deepseek":{"status":"ok","duration_s":10,"model":"deepseek/v4-pro","findings_total":2,"findings_convergent":2,"findings_dropped":0}}}
{"ts":"2026-08-05T03:00:00Z","run_id":"dp3","reviewers":{"deepseek":{"status":"ok","duration_s":10,"model":"deepseek/v4-pro","findings_total":2,"findings_convergent":2,"findings_dropped":0}}}
{"ts":"2026-08-01T01:00:00Z","run_id":"lg1","reviewers":{"glm":{"status":"ok","duration_s":10}}}
{"ts":"2026-08-01T02:00:00Z","run_id":"lg2","reviewers":{"glm":{"status":"ok","duration_s":10}}}
{"ts":"2026-08-01T03:00:00Z","run_id":"lg3","reviewers":{"glm":{"status":"ok","duration_s":10}}}
{"ts":"2026-08-01T04:00:00Z","run_id":"lg4","reviewers":{"glm":{"status":"ok","duration_s":10}}}
{"ts":"2026-08-03T01:00:00Z","run_id":"lgm1","reviewers":{"glm":{"status":"ok","duration_s":10,"model":"modelX"}}}
{"ts":"2026-08-03T02:00:00Z","run_id":"lgm2","reviewers":{"glm":{"status":"ok","duration_s":10,"model":"modelX"}}}
{"ts":"2026-08-03T03:00:00Z","run_id":"lgm3","reviewers":{"glm":{"status":"ok","duration_s":10,"model":"modelX"}}}
{"ts":"2026-08-03T04:00:00Z","run_id":"lgm4","reviewers":{"glm":{"status":"ok","duration_s":10,"model":"modelX"}}}
{"ts":"2026-08-03T05:00:00Z","run_id":"lgm5","reviewers":{"glm":{"status":"ok","duration_s":10,"model":"modelX"}}}
{"ts":"2026-08-03T06:00:00Z","run_id":"lgm6","reviewers":{"glm":{"status":"ok","duration_s":10,"model":"modelX"}}}
{"ts":"2026-08-01T01:00:00Z","run_id":"ta1","reviewers":{"qwen":{"status":"ok","duration_s":10,"model":"old-x"}}}
{"ts":"2026-08-01T02:00:00Z","run_id":"ta2","reviewers":{"qwen":{"status":"ok","duration_s":10,"model":"old-x"}}}
{"ts":"2026-08-01T03:00:00Z","run_id":"ta3","reviewers":{"qwen":{"status":"ok","duration_s":10,"model":"old-x"}}}
{"ts":"2026-08-01T04:00:00Z","run_id":"ta4","reviewers":{"qwen":{"status":"ok","duration_s":10,"model":"old-x"}}}
{"ts":"2026-08-01T05:00:00Z","run_id":"ta5","reviewers":{"qwen":{"status":"ok","duration_s":10,"model":"old-x"}}}
{"ts":"2026-08-04T01:00:00Z","run_id":"tb1","reviewers":{"qwen":{"status":"ok","duration_s":10,"model":"new-y"}}}
{"ts":"2026-08-04T02:00:00Z","run_id":"tb2","reviewers":{"qwen":{"status":"ok","duration_s":10,"model":"new-y"}}}
{"ts":"2026-08-01T01:00:00Z","run_id":"pv1","reviewers":{"devstral":{"status":"ok","duration_s":10}}}
{"ts":"2026-08-01T01:00:00Z","run_id":"fv1","reviewers":{"laguna":{"status":"ok","duration_s":10}}}
{"ts":"2026-08-01T01:00:00Z","run_id":"kb1","reviewers":{"kat":{"status":"ok","duration_s":10}}}
{"ts":"2026-08-01T01:00:00Z","run_id":"du1","reviewers":{"north":{"status":"ok","duration_s":10}}}
{"ts":"2026-08-01T01:00:00Z","run_id":"hr1","reviewers":{"nemotron":{"status":"ok","duration_s":10}}}
{"ts":"2026-08-01T01:00:00Z","run_id":"dfr1","reviewers":{"spark":{"status":"ok","duration_s":10}}}
{"ts":"2026-08-01T01:00:00Z","run_id":"cd1","reviewers":{"seed":{"status":"ok","duration_s":10,"context_mode":"diff"}}}
{"ts":"2026-08-01T02:00:00Z","run_id":"cd2","reviewers":{"seed":{"status":"ok","duration_s":10,"context_mode":"diff"}}}
{"ts":"2026-08-01T03:00:00Z","run_id":"cd3","reviewers":{"seed":{"status":"ok","duration_s":10,"context_mode":"diff"}}}
{"ts":"2026-08-01T04:00:00Z","run_id":"cd4","reviewers":{"seed":{"status":"ok","duration_s":10,"context_mode":"diff"}}}
{"ts":"2026-08-01T05:00:00Z","run_id":"cd5","reviewers":{"seed":{"status":"ok","duration_s":10,"context_mode":"diff"}}}
{"ts":"2026-08-01T06:00:00Z","run_id":"cf1","reviewers":{"seed":{"status":"ok","duration_s":10,"context_mode":"files"}}}
{"ts":"2026-08-01T07:00:00Z","run_id":"cf2","reviewers":{"seed":{"status":"ok","duration_s":10,"context_mode":"files"}}}
{"ts":"2026-08-01T08:00:00Z","run_id":"cf3","reviewers":{"seed":{"status":"ok","duration_s":10,"context_mode":"files"}}}
{"ts":"2026-08-01T09:00:00Z","run_id":"cf4","reviewers":{"seed":{"status":"ok","duration_s":10,"context_mode":"files"}}}
{"ts":"2026-08-01T10:00:00Z","run_id":"cf5","reviewers":{"seed":{"status":"ok","duration_s":10,"context_mode":"files"}}}
EOF

EVENTS="$T/finding_events.jsonl"
cat >"$EVENTS" <<'EOF'
{"event":"proposed","finding_id":"f-pv","run_id":"pv1","reviewer":"devstral","severity":"Low","all_sources":["devstral"],"ts":"2026-08-01T01:10:00Z"}
{"event":"parent_verified_dropped","finding_id":"f-pv","run_id":"pv1","ts":"2026-08-01T01:12:00Z"}
{"event":"proposed","finding_id":"f-fv","run_id":"fv1","reviewer":"laguna","severity":"Low","all_sources":["laguna"],"ts":"2026-08-01T01:10:00Z"}
{"event":"fix_verified","finding_id":"f-fv","run_id":"fv1","ts":"2026-08-01T01:12:00Z"}
{"event":"proposed","finding_id":"f-kb","run_id":"kb1","reviewer":"kat","severity":"Low","all_sources":["kat"],"ts":"2026-08-01T01:10:00Z"}
{"event":"factcheck_kept","finding_id":"f-kb","run_id":"kb1","ts":"2026-08-01T01:12:00Z"}
{"event":"proposed","finding_id":"f-du","run_id":"du1","reviewer":"north","severity":"Low","all_sources":["north"],"ts":"2026-08-01T01:10:00Z"}
{"event":"duplicate_merged","finding_id":"f-du","run_id":"du1","ts":"2026-08-01T01:12:00Z"}
{"event":"proposed","finding_id":"f-hr","run_id":"hr1","reviewer":"nemotron","severity":"Low","all_sources":["nemotron"],"ts":"2026-08-01T01:10:00Z"}
{"event":"human_rejected","finding_id":"f-hr","run_id":"hr1","ts":"2026-08-01T01:12:00Z"}
{"event":"proposed","finding_id":"f-df","run_id":"dfr1","reviewer":"spark","severity":"Low","all_sources":["spark"],"ts":"2026-08-01T01:10:00Z"}
{"event":"deferred","finding_id":"f-df","run_id":"dfr1","ts":"2026-08-01T01:12:00Z"}
{"event":"proposed","finding_id":"f-cd1","run_id":"cd1","reviewer":"seed","severity":"Low","all_sources":["seed"],"ts":"2026-08-01T01:10:00Z"}
{"event":"factcheck_kept","finding_id":"f-cd1","run_id":"cd1","ts":"2026-08-01T01:12:00Z"}
{"event":"proposed","finding_id":"f-cd2","run_id":"cd2","reviewer":"seed","severity":"Low","all_sources":["seed"],"ts":"2026-08-01T02:10:00Z"}
{"event":"factcheck_kept","finding_id":"f-cd2","run_id":"cd2","ts":"2026-08-01T02:12:00Z"}
{"event":"proposed","finding_id":"f-cd3","run_id":"cd3","reviewer":"seed","severity":"Low","all_sources":["seed"],"ts":"2026-08-01T03:10:00Z"}
{"event":"factcheck_kept","finding_id":"f-cd3","run_id":"cd3","ts":"2026-08-01T03:12:00Z"}
{"event":"proposed","finding_id":"f-cd4","run_id":"cd4","reviewer":"seed","severity":"Low","all_sources":["seed"],"ts":"2026-08-01T04:10:00Z"}
{"event":"factcheck_kept","finding_id":"f-cd4","run_id":"cd4","ts":"2026-08-01T04:12:00Z"}
{"event":"proposed","finding_id":"f-cd5","run_id":"cd5","reviewer":"seed","severity":"Low","all_sources":["seed"],"ts":"2026-08-01T05:10:00Z"}
{"event":"factcheck_kept","finding_id":"f-cd5","run_id":"cd5","ts":"2026-08-01T05:12:00Z"}
{"event":"proposed","finding_id":"f-cf1","run_id":"cf1","reviewer":"seed","severity":"Low","all_sources":["seed"],"ts":"2026-08-01T06:10:00Z"}
{"event":"factcheck_dropped","finding_id":"f-cf1","run_id":"cf1","ts":"2026-08-01T06:12:00Z"}
{"event":"proposed","finding_id":"f-cf2","run_id":"cf2","reviewer":"seed","severity":"Low","all_sources":["seed"],"ts":"2026-08-01T07:10:00Z"}
{"event":"factcheck_dropped","finding_id":"f-cf2","run_id":"cf2","ts":"2026-08-01T07:12:00Z"}
{"event":"proposed","finding_id":"f-cf3","run_id":"cf3","reviewer":"seed","severity":"Low","all_sources":["seed"],"ts":"2026-08-01T08:10:00Z"}
{"event":"factcheck_dropped","finding_id":"f-cf3","run_id":"cf3","ts":"2026-08-01T08:12:00Z"}
{"event":"proposed","finding_id":"f-cf4","run_id":"cf4","reviewer":"seed","severity":"Low","all_sources":["seed"],"ts":"2026-08-01T09:10:00Z"}
{"event":"factcheck_dropped","finding_id":"f-cf4","run_id":"cf4","ts":"2026-08-01T09:12:00Z"}
{"event":"proposed","finding_id":"f-cf5","run_id":"cf5","reviewer":"seed","severity":"Low","all_sources":["seed"],"ts":"2026-08-01T10:10:00Z"}
{"event":"factcheck_dropped","finding_id":"f-cf5","run_id":"cf5","ts":"2026-08-01T10:12:00Z"}
EOF

LB="$(RUN_LB --mode json)"
field() { jq -r --arg r "$1" --arg f "$2" '.[] | select(.reviewer==$r) | .[$f]' <<<"$LB"; }

echo "── model epochs (#90): current epoch scores its own rows only ──"
assert_eq "deepseek: model is the current (post-swap) model" \
  "$(field deepseek model)" "deepseek/v4-pro"
assert_eq "deepseek: epoch_runs is the current epoch's row count" \
  "$(field deepseek epoch_runs)" "3"
assert_eq "deepseek: previous_epochs[0].model is the retired model" \
  "$(jq -r '.[] | select(.reviewer=="deepseek") | .previous_epochs[0].model' <<<"$LB")" "deepseek/v4-flash"
assert_eq "deepseek: previous_epochs[0].runs is the retired epoch's row count" \
  "$(jq -r '.[] | select(.reviewer=="deepseek") | .previous_epochs[0].runs' <<<"$LB")" "10"

# The good new-model epoch (3 kept/convergent runs, blended toward the
# rookie prior since 3 < epoch_rookie_min_n) must still outscore what
# merging all 13 rows (10 bad + 3 good) into one undivided window would
# give — computed from a SEPARATE fixture with no `model` field so every
# row lands in one legacy epoch, the pre-#90 behavior. Direction pinned,
# not a magic merged number.
RUNLOG_MERGED="$T/runlog_merged.jsonl"
jq -c 'del(.reviewers.deepseek.model)' "$RUNLOG" >"$RUNLOG_MERGED"
LB_MERGED="$(CROSS_REVIEW_RUNLOG="$RUNLOG_MERGED" CROSS_REVIEW_FINDING_EVENTS="$EVENTS" bash "$S/leaderboard.sh" --recent 200 --mode json)"
DEEPSEEK_SCORE="$(field deepseek score)"
MERGED_SCORE="$(jq -r '.[] | select(.reviewer=="deepseek") | .score' <<<"$LB_MERGED")"
if [[ "$DEEPSEEK_SCORE" -gt "$MERGED_SCORE" ]]; then
  ok "deepseek: current-epoch score ($DEEPSEEK_SCORE) beats the undivided merge ($MERGED_SCORE)"
else
  bad "deepseek: current-epoch score ($DEEPSEEK_SCORE) does not beat the undivided merge ($MERGED_SCORE)"
fi

echo "── null-model rows form the LEGACY epoch, never merged into a later one ──"
assert_eq "glm: epoch_runs excludes the legacy (null-model) rows" \
  "$(field glm epoch_runs)" "6"
assert_eq "glm: previous_epochs[0].model is null (legacy)" \
  "$(jq -r '.[] | select(.reviewer=="glm") | .previous_epochs[0].model // "null"' <<<"$LB")" "null"
assert_eq "glm: previous_epochs[0].runs is the legacy row count" \
  "$(jq -r '.[] | select(.reviewer=="glm") | .previous_epochs[0].runs' <<<"$LB")" "4"

echo "── an under-sampled new epoch blends toward the rookie prior ──"
# qwen: epoch A (old-x, 5 runs, no findings data) then epoch B (new-y,
# 2 runs, no findings data). Epoch B alone: rel=1, no findings ever
# enriched -> telemetry-only branch, ok=2 (<=3) -> multiplier 0.75 -> raw
# 75. Blend weight 2/5=0.4 -> round(0.4*75 + 0.6*50) = round(30+30) = 60.
assert_eq "qwen: score_basis carries the _blend suffix" \
  "$(field qwen score_basis)" "telemetry_blend"
assert_eq "qwen: blended score (0.4*75 + 0.6*50 = 60)" \
  "$(field qwen score)" "60"

echo "── terminal events (#88): folded into the value/survival axes ──"
# devstral: parent_verified_dropped is 0 credit, same as factcheck_dropped ->
# tw=1 (Low), cw=0, dw=1 -> 100*(0.45+0+0) = 45.
assert_eq "devstral: parent_verified_dropped zeroes credit like factcheck_dropped (45)" \
  "$(field devstral score)" "45"
assert_eq "devstral: ev_dropped counts it" "$(field devstral ev_dropped)" "1"

# laguna vs kat: same shape (one solo Low, kept), the ONLY difference
# is fix_verified's bonus multiplier -> laguna must outscore a plain kept.
assert_eq "kat: plain factcheck_kept solo Low (100)" \
  "$(field kat score)" "100"
assert_eq "laguna: fix_verified scores above a plain kept (109)" \
  "$(field laguna score)" "109"
if [[ "$(field laguna score)" -gt "$(field kat score)" ]]; then
  ok "laguna > kat (the fix_verified bonus actually moved the score)"
else
  bad "laguna > kat (fix_verified bonus did not raise the score)"
fi

# north: duplicate_merged discounts credit (0.5x) -> below a plain kept but
# still above a dropped finding (still real, just discounted).
assert_eq "north: duplicate_merged discounts credit (83)" \
  "$(field north score)" "83"
if [[ "$(field north score)" -lt "$(field kat score)" ]]; then
  ok "north < kat (duplicate_merged actually discounted the score)"
else
  bad "north < kat (duplicate_merged did not discount the score)"
fi

# nemotron: human_rejected counts as dropped, same as parent_verified_dropped.
assert_eq "nemotron: human_rejected counts as dropped (45)" \
  "$(field nemotron score)" "45"

# spark: deferred is neutral -- excluded from the events axis entirely,
# so this reviewer falls back to the telemetry-only branch (100*1*0.75=75)
# with ev_findings 0, not scored (and definitely not dropped) on this event.
assert_eq "spark: deferred excludes the finding from ev_findings" \
  "$(field spark ev_findings)" "0"
assert_eq "spark: falls back to telemetry-only scoring (75)" \
  "$(field spark score)" "75"
assert_eq "spark: score_basis is telemetry (not events)" \
  "$(field spark score_basis)" "telemetry"

echo "── --mode report: epoch boundary date + per-context_mode table ──"
REPORT="$(RUN_LB --mode report 2>&1)"
assert_contains "report prints deepseek's epoch boundary date" "$REPORT" "epoch started 2026-08-05"
assert_contains "report names the retired model in the epoch line" "$REPORT" "deepseek/v4-flash"
assert_contains "report prints a context_mode table heading" "$REPORT" "context_mode"
assert_contains "report shows seed's diff-mode kept rate (100%, all kept)" "$REPORT" "diff kept=100%"
assert_contains "report shows seed's files-mode drop rate (100%, all dropped)" "$REPORT" "files kept=0%"

# ── PR #133 review: a deferred AFTER a kept neutralises the finding in the
#    cost path too (it is not silently ignored) ──────────────────────────────
DEFLOG="$T/def-runlog.jsonl"; DEFEV="$T/def-events.jsonl"
printf '{"ts":"2026-08-10T00:00:00Z","run_id":"dfx1","reviewers":{"omega":{"status":"ok","exit_code":0,"duration_s":10,"output_bytes":10,"timeout_budget_s":600,"cost_usd":0.50,"model":"m1"}}}\n' >"$DEFLOG"
cat >"$DEFEV" <<'EOF'
{"event":"proposed","finding_id":"f-dx","run_id":"dfx1","reviewer":"omega","severity":"High","all_sources":["omega"],"ts":"2026-08-10T00:00:01Z"}
{"event":"factcheck_kept","finding_id":"f-dx","run_id":"dfx1","ts":"2026-08-10T00:10:00Z"}
{"event":"deferred","finding_id":"f-dx","run_id":"dfx1","ts":"2026-08-10T00:20:00Z"}
EOF
DEFJ="$(CROSS_REVIEW_RUNLOG="$DEFLOG" CROSS_REVIEW_FINDING_EVENTS="$DEFEV" bash "$S/leaderboard.sh" --mode json --profiles "$PROFILES" 2>/dev/null)"
assert_eq "kept then deferred: no kept finding remains for cost_per_kept" "$(jq -r '.[] | select(.reviewer=="omega") | .cost_per_kept' <<<"$DEFJ")" "—"

echo
echo "══ $PASS passed, $FAIL failed ══"
[[ "$FAIL" -eq 0 ]] || exit 1
exit 0
