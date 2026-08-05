#!/usr/bin/env bash
# test_leaderboard_events.sh — standalone offline fixture test for
# leaderboard.sh's finding_events.jsonl-based scoring (leaderboard v2).
# NO network, no reviewer CLIs, no tokens.
#
# What v2 adds over the aggregate-count formula (and what this suite pins):
#   - severity weighting: Critical 5 / High 3 / Medium 2 / Low 1
#   - unique-discovery credit per finding: provider-solo 1.0,
#     multi-provider-without-a-baseline 0.85, baseline-corroborated 0.7
#   - anchor discount: anchored resolved=false halves the credit
#   - factcheck_dropped zeroes the credit and feeds the survival axis
#   - value    = sum(sev_w * credit) / sum(sev_w)
#   - survival = 1 - sum(sev_w over dropped) / sum(sev_w)
#   - score    = round(100 * (0.45*reliability + 0.35*value + 0.20*survival))
#   - events join the runlog window by run_id; reviewers with no window
#     events fall back to the v1 aggregate-count formula unchanged.
#
# Mirrors run_tests.sh's fixture/assertion conventions (assert_eq, mktemp -d
# + trap cleanup). Wired into run_tests.sh's standalone-suite loop.
#
# Run:  bash tests/test_leaderboard_events.sh
# Exit: 0 all green, 1 any failure.

set -uo pipefail

SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
S="$SKILL_DIR/scripts"

PASS=0
FAIL=0
ok()  { echo "  ok   $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL $1"; FAIL=$((FAIL + 1)); }
assert_eq() {
  if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 (got: '$2' want: '$3')"; fi
}

command -v jq >/dev/null 2>&1 || { echo "jq required to run these tests" >&2; exit 1; }

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

# ── fixtures ────────────────────────────────────────────────────────────────
# One structured runlog entry, run_id fix-r1. Every reviewer under test has a
# single ok attempt (reliability 1.0) so the findings axes are isolated.
# north ALSO carries perfect aggregate counts (v1 would score it 100) — the
# events path must win, which is what pins precedence.
FIXLOG="$T/runlog.jsonl"
cat > "$FIXLOG" <<'EOF'
{"ts":"2026-08-04T01:00:00Z","run_id":"fix-r1","reviewers":{"codex":{"status":"ok","duration_s":90},"kimi":{"status":"ok","duration_s":90},"north":{"status":"ok","duration_s":100,"findings_total":4,"findings_convergent":4,"findings_dropped":0},"laguna":{"status":"ok","duration_s":100},"qwen":{"status":"ok","duration_s":100},"mimo":{"status":"ok","duration_s":100},"devstral":{"status":"ok","duration_s":100},"kimi3":{"status":"ok","duration_s":100},"nemotron":{"status":"ok","duration_s":100},"spark":{"status":"ok","duration_s":100,"findings_total":4,"findings_convergent":1,"findings_dropped":0}}}
EOF

# Events ledger. Every scored event carries run_id fix-r1; the fix-r0 event at
# the bottom is OUTSIDE the runlog window and must be ignored (north stays 96).
EVENTS="$T/finding_events.jsonl"
cat > "$EVENTS" <<'EOF'
{"event":"proposed","reviewer":"north","all_sources":["north"],"severity":"Critical","file":"a.ts","claim":"solo crit","finding_id":"f-n1","run_id":"fix-r1","ts":"2026-08-04T01:10:00Z"}
{"event":"proposed","reviewer":"north","all_sources":["north","codex"],"severity":"Low","file":"a.ts","claim":"low 1","finding_id":"f-n2","run_id":"fix-r1","ts":"2026-08-04T01:10:00Z"}
{"event":"proposed","reviewer":"north","all_sources":["north","kimi"],"severity":"Low","file":"a.ts","claim":"low 2","finding_id":"f-n3","run_id":"fix-r1","ts":"2026-08-04T01:10:00Z"}
{"event":"proposed","reviewer":"north","all_sources":["north","codex"],"severity":"Low","file":"a.ts","claim":"low 3","finding_id":"f-n4","run_id":"fix-r1","ts":"2026-08-04T01:10:00Z"}
{"event":"proposed","reviewer":"codex","all_sources":["north","codex"],"severity":"Low","file":"a.ts","claim":"low 1","finding_id":"f-n2","run_id":"fix-r1","ts":"2026-08-04T01:10:00Z"}
{"event":"anchored","resolved":true,"sources":["north"],"file":"a.ts","start_line":1,"end_line":2,"side":"new","finding_id":"f-n1","run_id":"fix-r1","ts":"2026-08-04T01:11:00Z"}
{"event":"factcheck_kept","finding_id":"f-n1","run_id":"fix-r1","ts":"2026-08-04T01:12:00Z"}
{"event":"proposed","reviewer":"laguna","all_sources":["laguna","codex"],"severity":"Low","file":"b.ts","claim":"l1","finding_id":"f-l1","run_id":"fix-r1","ts":"2026-08-04T01:10:00Z"}
{"event":"proposed","reviewer":"laguna","all_sources":["laguna","codex"],"severity":"Low","file":"b.ts","claim":"l2","finding_id":"f-l2","run_id":"fix-r1","ts":"2026-08-04T01:10:00Z"}
{"event":"proposed","reviewer":"laguna","all_sources":["laguna","kimi"],"severity":"Low","file":"b.ts","claim":"l3","finding_id":"f-l3","run_id":"fix-r1","ts":"2026-08-04T01:10:00Z"}
{"event":"proposed","reviewer":"laguna","all_sources":["laguna","codex"],"severity":"Low","file":"b.ts","claim":"l4","finding_id":"f-l4","run_id":"fix-r1","ts":"2026-08-04T01:10:00Z"}
{"event":"proposed","reviewer":"qwen","all_sources":["qwen"],"severity":"Critical","file":"c.ts","claim":"q crit","finding_id":"f-q1","run_id":"fix-r1","ts":"2026-08-04T01:10:00Z"}
{"event":"proposed","reviewer":"qwen","all_sources":["qwen"],"severity":"Low","file":"c.ts","claim":"q low","finding_id":"f-q2","run_id":"fix-r1","ts":"2026-08-04T01:10:00Z"}
{"event":"factcheck_dropped","reason":"diff contradicts it","sources":["qwen"],"file":"c.ts","severity":"Critical","finding_id":"f-q1","run_id":"fix-r1","ts":"2026-08-04T01:12:00Z"}
{"event":"proposed","reviewer":"mimo","all_sources":["mimo"],"severity":"Low","file":"d.ts","claim":"m low","finding_id":"f-m1","run_id":"fix-r1","ts":"2026-08-04T01:10:00Z"}
{"event":"proposed","reviewer":"mimo","all_sources":["mimo"],"severity":"Critical","file":"d.ts","claim":"m crit","finding_id":"f-m2","run_id":"fix-r1","ts":"2026-08-04T01:10:00Z"}
{"event":"factcheck_dropped","reason":"diff contradicts it","sources":["mimo"],"file":"d.ts","severity":"Low","finding_id":"f-m1","run_id":"fix-r1","ts":"2026-08-04T01:12:00Z"}
{"event":"proposed","reviewer":"devstral","all_sources":["devstral"],"severity":"High","file":"e.ts","claim":"dv high","finding_id":"f-d1","run_id":"fix-r1","ts":"2026-08-04T01:10:00Z"}
{"event":"anchored","resolved":false,"sources":["devstral"],"file":"e.ts","start_line":0,"end_line":0,"side":"new","finding_id":"f-d1","run_id":"fix-r1","ts":"2026-08-04T01:11:00Z"}
{"event":"proposed","reviewer":"kimi3","all_sources":["kimi3","kimi"],"severity":"Medium","file":"f.ts","claim":"k3 med","finding_id":"f-k1","run_id":"fix-r1","ts":"2026-08-04T01:10:00Z"}
{"event":"proposed","reviewer":"nemotron","all_sources":["nemotron",null,"glm"],"severity":"Medium","file":"g.ts","claim":"ne med","finding_id":"f-ne1","run_id":"fix-r1","ts":"2026-08-04T01:10:00Z"}
{"event":"proposed","reviewer":"north","all_sources":["north"],"severity":"Critical","file":"z.ts","claim":"stale round","finding_id":"f-n9","run_id":"fix-r0","ts":"2026-08-01T01:10:00Z"}
EOF

LB="$(CROSS_REVIEW_RUNLOG="$FIXLOG" CROSS_REVIEW_FINDING_EVENTS="$EVENTS" \
      bash "$S/leaderboard.sh" --mode json)"
field() { jq -r --arg r "$1" --arg f "$2" '.[] | select(.reviewer==$r) | .[$f]' <<<"$LB"; }

echo "── events path: severity weighting + unique-discovery credit ──"
# north: solo Critical (5*1.0) + 3 baseline-corroborated Lows (3*1*0.7) over
# tw 8 → value 0.8875, survival 1.0 → 96. Its perfect aggregate counts would
# give 100 on v1, so 96 also proves the events path takes precedence. The
# fix-r0 event outside the window must not move this.
assert_eq "north: solo Critical + corroborated Lows scores 96 (events beat counts)" \
  "$(field north score)" "96"
assert_eq "north: score_basis is events" "$(field north score_basis)" "events"
assert_eq "north: ev_findings counts window proposed events only" \
  "$(field north ev_findings)" "4"
assert_eq "north: ev_solo counts provider-solo findings" "$(field north ev_solo)" "1"
assert_eq "north: ev_dropped is 0" "$(field north ev_dropped)" "0"

echo "── baseline-corroborated-only reviewer sits at the 0.7 credit floor ──"
# laguna: 4 baseline-corroborated Lows → value 0.7 → 89.5 → 90.
assert_eq "laguna: all-corroborated scores 90" "$(field laguna score)" "90"

echo "── factcheck_dropped is severity-weighted ──"
# qwen: dropped solo Critical + kept solo Low → value 1/6, survival 1/6 → 54.
# mimo: dropped solo Low + kept solo Critical → value 5/6, survival 5/6 → 91.
# Same shapes, opposite severities — the Critical drop must hurt far more.
assert_eq "qwen: dropped Critical craters the score (54)" "$(field qwen score)" "54"
assert_eq "qwen: ev_dropped is 1" "$(field qwen ev_dropped)" "1"
assert_eq "mimo: dropped Low barely dents the score (91)" "$(field mimo score)" "91"

echo "── unanchored findings earn half credit ──"
# devstral: one solo High with anchored resolved=false → value 0.5 → 83.
assert_eq "devstral: unanchored solo High scores 83" "$(field devstral score)" "83"
assert_eq "devstral: ev_unanchored is 1" "$(field devstral ev_unanchored)" "1"

echo "── provider-solo: same-provider corroboration is one Moonshot vote ──"
# kimi3 corroborated only by kimi (both moonshot) → provider-solo 1.0 → 100.
assert_eq "kimi3: kimi-only corroboration counts as provider-solo (100)" \
  "$(field kimi3 score)" "100"

echo "── baseline-incremental tier: multi-provider without a baseline ──"
# nemotron + glm (nvidia + zhipu, no codex/kimi) → 0.85 credit → 94.75 → 95.
# The null in nemotron's all_sources is the codex-P1 regression pin from
# PR #47: null sources are legal upstream and must be filtered, not indexed
# ($provmap[null] kills the whole jq scorer).
assert_eq "nemotron: no-baseline corroboration earns 0.85 credit (95)" \
  "$(field nemotron score)" "95"

echo "── v1 fallback: reviewers with no window events keep the old formula ──"
# spark: counts only (4 findings, 1 convergent, 0 dropped) → 73.75 → 74.
assert_eq "spark: aggregate-count formula unchanged (74)" "$(field spark score)" "74"
assert_eq "spark: score_basis is counts" "$(field spark score_basis)" "counts"

echo "── missing events file: every reviewer scores v1 ──"
LB2="$(CROSS_REVIEW_RUNLOG="$FIXLOG" CROSS_REVIEW_FINDING_EVENTS="$T/nonexistent.jsonl" \
       bash "$S/leaderboard.sh" --mode json)"
assert_eq "no events file: north scores v1 off its counts (100)" \
  "$(jq -r '.[] | select(.reviewer=="north") | .score' <<<"$LB2")" "100"
assert_eq "no events file: north score_basis is counts" \
  "$(jq -r '.[] | select(.reviewer=="north") | .score_basis' <<<"$LB2")" "counts"

echo
echo "══ $PASS passed, $FAIL failed ══"
[[ "$FAIL" -eq 0 ]] || exit 1
exit 0
