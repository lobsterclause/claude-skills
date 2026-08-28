#!/usr/bin/env bash
# test_leaderboard_calibration.sh — standalone fixture tests for #106:
# leaderboard.sh's optional --calibration multiplier on the value axis.
#
# STANDALONE: no network, no reviewer CLIs. Follows the preamble conventions
# of tests/test_leaderboard_recall.sh (PASS/FAIL counters, assert_eq/
# assert_contains/assert_num_eq, CROSS_REVIEW_RUNLOG / CROSS_REVIEW_FINDING_EVENTS
# overrides, its own harness) — leaderboard.sh and this file are the only
# things this shard owns.
#
# Run:  bash tests/test_leaderboard_calibration.sh
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
command -v jq >/dev/null 2>&1 || { echo "test_leaderboard_calibration: jq required" >&2; exit 1; }

# ═══════════════════════════════════════════════════════════════════════════
# Fixture: four seats, all corroborated (tier 0.85, not solo except kat) so
# the value axis is driven by severity weight + kept/dropped, not the solo
# discount -- except kat, deliberately built to trip BOTH the solo discount
# AND calibration (assertion e).
#
#   glm  (seat A) -- 12 proposed (8 Critical, 4 Low), 6 of the 8 Critical
#                    dropped -> high inflation, resolved=12 (>= floor 10)
#   mimo (seat B) -- 12 proposed (8 Critical, 4 Low), all kept -> zero
#                    inflation, resolved=12 (>= floor 10)
#   qwen (seat C) -- 4 proposed (2 Medium kept, 2 Low dropped), resolved=4
#                    (BELOW floor 10) -- 5 attempts/4 ok (rel=0.8) tunes its
#                    base score to exactly 69, deliberately sandwiched
#                    between kat's base (70) and calibrated (68) scores so
#                    --calibration flips their rank (assertion g)
#   kat  (seat D) -- 10 SOLO proposed (6 Critical, 4 Low), 3 of the 6
#                    Critical dropped -> own drop rate 3/10=0.30 exceeds the
#                    existing solo_discount_drop_rate_threshold (0.15, n>=5)
#                    AND resolved=10 (>= floor) trips calibration too
# ═══════════════════════════════════════════════════════════════════════════
RUNLOG="$T/runlog.jsonl"
EVENTS="$T/events.jsonl"
: >"$RUNLOG"; : >"$EVENTS"

add_runlog() { printf '%s\n' "$1" >>"$RUNLOG"; }
add_event()  { printf '%s\n' "$1" >>"$EVENTS"; }

# -- glm (seat A) --
for i in $(seq 1 12); do
  add_runlog "{\"ts\":\"2026-08-01T00:00:00Z\",\"run_id\":\"a$i\",\"reviewers\":{\"glm\":{\"status\":\"ok\",\"exit_code\":0,\"duration_s\":10,\"output_bytes\":10,\"timeout_budget_s\":300}}}"
done
for i in 1 2 3 4 5 6; do
  add_event "{\"event\":\"proposed\",\"finding_id\":\"a-crit-$i\",\"run_id\":\"a$i\",\"reviewer\":\"glm\",\"severity\":\"Critical\",\"all_sources\":[\"glm\",\"minimax\"],\"ts\":\"2026-08-01T00:00:05Z\"}"
  add_event "{\"event\":\"factcheck_dropped\",\"finding_id\":\"a-crit-$i\",\"run_id\":\"a$i\",\"ts\":\"2026-08-01T00:00:06Z\"}"
done
for i in 7 8; do
  add_event "{\"event\":\"proposed\",\"finding_id\":\"a-crit-$i\",\"run_id\":\"a$i\",\"reviewer\":\"glm\",\"severity\":\"Critical\",\"all_sources\":[\"glm\",\"minimax\"],\"ts\":\"2026-08-01T00:00:05Z\"}"
  add_event "{\"event\":\"factcheck_kept\",\"finding_id\":\"a-crit-$i\",\"run_id\":\"a$i\",\"ts\":\"2026-08-01T00:00:06Z\"}"
done
for i in 9 10 11 12; do
  add_event "{\"event\":\"proposed\",\"finding_id\":\"a-low-$i\",\"run_id\":\"a$i\",\"reviewer\":\"glm\",\"severity\":\"Low\",\"all_sources\":[\"glm\",\"minimax\"],\"ts\":\"2026-08-01T00:00:05Z\"}"
  add_event "{\"event\":\"factcheck_kept\",\"finding_id\":\"a-low-$i\",\"run_id\":\"a$i\",\"ts\":\"2026-08-01T00:00:06Z\"}"
done

# -- mimo (seat B) --
for i in $(seq 1 12); do
  add_runlog "{\"ts\":\"2026-08-01T01:00:00Z\",\"run_id\":\"b$i\",\"reviewers\":{\"mimo\":{\"status\":\"ok\",\"exit_code\":0,\"duration_s\":10,\"output_bytes\":10,\"timeout_budget_s\":300}}}"
done
for i in 1 2 3 4 5 6 7 8; do
  add_event "{\"event\":\"proposed\",\"finding_id\":\"b-crit-$i\",\"run_id\":\"b$i\",\"reviewer\":\"mimo\",\"severity\":\"Critical\",\"all_sources\":[\"mimo\",\"minimax\"],\"ts\":\"2026-08-01T01:00:05Z\"}"
  add_event "{\"event\":\"factcheck_kept\",\"finding_id\":\"b-crit-$i\",\"run_id\":\"b$i\",\"ts\":\"2026-08-01T01:00:06Z\"}"
done
for i in 9 10 11 12; do
  add_event "{\"event\":\"proposed\",\"finding_id\":\"b-low-$i\",\"run_id\":\"b$i\",\"reviewer\":\"mimo\",\"severity\":\"Low\",\"all_sources\":[\"mimo\",\"minimax\"],\"ts\":\"2026-08-01T01:00:05Z\"}"
  add_event "{\"event\":\"factcheck_kept\",\"finding_id\":\"b-low-$i\",\"run_id\":\"b$i\",\"ts\":\"2026-08-01T01:00:06Z\"}"
done

# -- qwen (seat C) --
for i in $(seq 1 4); do
  add_runlog "{\"ts\":\"2026-08-01T02:00:00Z\",\"run_id\":\"c$i\",\"reviewers\":{\"qwen\":{\"status\":\"ok\",\"exit_code\":0,\"duration_s\":10,\"output_bytes\":10,\"timeout_budget_s\":300}}}"
done
add_runlog "{\"ts\":\"2026-08-01T02:04:00Z\",\"run_id\":\"c5\",\"reviewers\":{\"qwen\":{\"status\":\"error\",\"exit_code\":1,\"duration_s\":10,\"output_bytes\":0,\"timeout_budget_s\":300}}}"
for i in 1 2; do
  add_event "{\"event\":\"proposed\",\"finding_id\":\"c-med-$i\",\"run_id\":\"c$i\",\"reviewer\":\"qwen\",\"severity\":\"Medium\",\"all_sources\":[\"qwen\",\"minimax\"],\"ts\":\"2026-08-01T02:00:05Z\"}"
  add_event "{\"event\":\"factcheck_kept\",\"finding_id\":\"c-med-$i\",\"run_id\":\"c$i\",\"ts\":\"2026-08-01T02:00:06Z\"}"
done
for i in 3 4; do
  add_event "{\"event\":\"proposed\",\"finding_id\":\"c-low-$i\",\"run_id\":\"c$i\",\"reviewer\":\"qwen\",\"severity\":\"Low\",\"all_sources\":[\"qwen\",\"minimax\"],\"ts\":\"2026-08-01T02:00:05Z\"}"
  add_event "{\"event\":\"factcheck_dropped\",\"finding_id\":\"c-low-$i\",\"run_id\":\"c$i\",\"ts\":\"2026-08-01T02:00:06Z\"}"
done

# -- kat (seat D) --
for i in $(seq 1 10); do
  add_runlog "{\"ts\":\"2026-08-01T03:00:00Z\",\"run_id\":\"d$i\",\"reviewers\":{\"kat\":{\"status\":\"ok\",\"exit_code\":0,\"duration_s\":10,\"output_bytes\":10,\"timeout_budget_s\":300}}}"
done
for i in 1 2 3; do
  add_event "{\"event\":\"proposed\",\"finding_id\":\"d-crit-$i\",\"run_id\":\"d$i\",\"reviewer\":\"kat\",\"severity\":\"Critical\",\"all_sources\":[\"kat\"],\"ts\":\"2026-08-01T03:00:05Z\"}"
  add_event "{\"event\":\"factcheck_dropped\",\"finding_id\":\"d-crit-$i\",\"run_id\":\"d$i\",\"ts\":\"2026-08-01T03:00:06Z\"}"
done
for i in 4 5 6; do
  add_event "{\"event\":\"proposed\",\"finding_id\":\"d-crit-$i\",\"run_id\":\"d$i\",\"reviewer\":\"kat\",\"severity\":\"Critical\",\"all_sources\":[\"kat\"],\"ts\":\"2026-08-01T03:00:05Z\"}"
  add_event "{\"event\":\"factcheck_kept\",\"finding_id\":\"d-crit-$i\",\"run_id\":\"d$i\",\"ts\":\"2026-08-01T03:00:06Z\"}"
done
for i in 7 8 9 10; do
  add_event "{\"event\":\"proposed\",\"finding_id\":\"d-low-$i\",\"run_id\":\"d$i\",\"reviewer\":\"kat\",\"severity\":\"Low\",\"all_sources\":[\"kat\"],\"ts\":\"2026-08-01T03:00:05Z\"}"
  add_event "{\"event\":\"factcheck_kept\",\"finding_id\":\"d-low-$i\",\"run_id\":\"d$i\",\"ts\":\"2026-08-01T03:00:06Z\"}"
done

RUN_LB() {
  CROSS_REVIEW_RUNLOG="$RUNLOG" CROSS_REVIEW_FINDING_EVENTS="$EVENTS" \
    bash "$S/leaderboard.sh" --recent 200 "$@"
}

# ═══════════════════════════════════════════════════════════════════════════
# (a) --calibration OFF (default) is byte-identical to today: with-flag
# output, once the documented additions are stripped, equals the without-
# flag output exactly. Uses a dedicated CONTROL fixture (no runlog/events at
# all) rather than the main A-D fixture below: the main fixture deliberately
# makes --calibration CHANGE scores (that's the feature under test in (b)-
# (g)), which reorders `sort_by(-.score)` -- a legitimate difference, not an
# "additional" one, so it isn't a valid input for a strip-and-compare check.
# A fixture where calibration provably has zero effect on any score isolates
# the purely additive/structural claim: with it off, nothing about the
# existing fields or their order changes.
# ═══════════════════════════════════════════════════════════════════════════
echo "── (a) --calibration off is unaffected; with-flag output differs ONLY in the documented additions ──"

RUN_LB_CONTROL() {
  CROSS_REVIEW_RUNLOG="$T/does-not-exist-runlog.jsonl" CROSS_REVIEW_FINDING_EVENTS="$T/does-not-exist-events.jsonl" \
    bash "$S/leaderboard.sh" --recent 200 "$@"
}

JSON_NOFLAG="$(RUN_LB_CONTROL --mode json 2>/dev/null)"
JSON_CALFLAG="$(RUN_LB_CONTROL --mode json --calibration 2>/dev/null)"
JSON_CALFLAG_STRIPPED="$(jq -c 'map(del(.calibration))' <<<"$JSON_CALFLAG")"
JSON_NOFLAG_NORM="$(jq -c '.' <<<"$JSON_NOFLAG")"
assert_eq "json: with-flag output stripped of 'calibration' equals without-flag output" \
  "$JSON_CALFLAG_STRIPPED" "$JSON_NOFLAG_NORM"

TABLE_NOFLAG_CTRL="$(RUN_LB_CONTROL --mode table 2>/dev/null)"
TABLE_CALFLAG_CTRL="$(RUN_LB_CONTROL --mode table --calibration 2>/dev/null)"
# Strip the "  ·  cal=X.XX" column and the three calibration explainer lines
# appended at the bottom -- the only documented table additions.
TABLE_CALFLAG_CTRL_STRIPPED="$(sed -E 's/  · +cal=[0-9]+\.[0-9]+//' <<<"$TABLE_CALFLAG_CTRL" \
  | grep -v '^  (cal= is the severity-calibration' \
  | grep -v '^   clamp(1 - inflation' \
  | grep -Ev '^   [0-9]+\+ resolved findings; 1\.00 elsewhere\)')"
assert_eq "table: with-flag output stripped of the cal column/explainer equals without-flag output" \
  "$TABLE_CALFLAG_CTRL_STRIPPED" "$TABLE_NOFLAG_CTRL"

# Now confirm the SAME OFF-flag output on the MAIN fixture (the one that
# actually exercises calibration below) also carries no calibration key --
# --calibration's mere availability never leaks into a run that didn't pass it.
JSON_NOFLAG="$(RUN_LB --mode json 2>/dev/null)"
TABLE_NOFLAG="$(RUN_LB --mode table 2>/dev/null)"
assert_eq "main fixture: --mode json without --calibration carries no 'calibration' key anywhere" \
  "$(jq '[.[] | has("calibration")] | any' <<<"$JSON_NOFLAG")" "false"
assert_eq "main fixture: --mode table without --calibration has no cal= column" \
  "$(grep -c '  ·  cal=' <<<"$TABLE_NOFLAG")" "0"

JSON_CALFLAG="$(RUN_LB --mode json --calibration 2>/dev/null)"
TABLE_CALFLAG="$(RUN_LB --mode table --calibration 2>/dev/null)"

# ═══════════════════════════════════════════════════════════════════════════
# (b)/(c)/(d) per-seat factor/inflation/resolved/applied, and the score
# composing per the documented 45/35/20 blend -- computed from the json
# fields returned by severity_calibration.sh --json and leaderboard.sh
# --mode json (base, uncalibrated), never hand-typed as a final literal.
# ═══════════════════════════════════════════════════════════════════════════
echo "── (b) seat A (glm): factor = clamp(1 - inflation), score follows the 45/35/20 blend ──"

SEV_JSON="$(bash "$S/severity_calibration.sh" --events "$EVENTS" --json 2>/dev/null)"
GLM_INFLATION="$(jq -r '.[] | select(.reviewer=="glm") | .inflation' <<<"$SEV_JSON")"
GLM_RESOLVED="$(jq -r '.[] | select(.reviewer=="glm") | .resolved' <<<"$SEV_JSON")"
assert_eq "glm inflation from severity_calibration.sh is 0.33" "$GLM_INFLATION" "0.33"
assert_eq "glm resolved >= calibration_min_n (10)" "$([[ "$GLM_RESOLVED" -ge 10 ]] && echo yes || echo no)" "yes"

GLM_CAL_JSON="$(jq '.[] | select(.reviewer=="glm")' <<<"$JSON_CALFLAG")"
GLM_FACTOR="$(jq -r '.calibration.factor' <<<"$GLM_CAL_JSON")"
GLM_APPLIED="$(jq -r '.calibration.applied' <<<"$GLM_CAL_JSON")"
EXPECTED_GLM_FACTOR="$(jq -n -r --argjson infl "$GLM_INFLATION" \
  '((1 - $infl) as $raw | (if $raw < 0.5 then 0.5 elif $raw > 1.0 then 1.0 else $raw end)) as $f
   | ($f * 100 | round) as $ip | (($ip / 100 | floor | tostring) + "." + (($ip % 100 | tostring) | if length == 1 then "0" + . else . end))')"
assert_eq "glm calibration.factor == clamp(1 - inflation, 0.5, 1.0)" "$GLM_FACTOR" "$EXPECTED_GLM_FACTOR"
assert_eq "glm calibration.applied is true (resolved >= floor)" "$GLM_APPLIED" "true"

# Reconstruct glm's expected calibrated score directly from the fixture's own
# known severity weights/kept-dropped status (tier 0.85, not solo, no
# baseline -- codex/kimi never appear in this fixture) and glm's reliability
# from the json (never a hand-typed final score).
GLM_REL="$(jq -r '.[] | select(.reviewer=="glm") | .reliability_pct' <<<"$JSON_NOFLAG")"
GLM_EXPECTED_CAL_SCORE="$(jq -n --argjson rel_pct "$GLM_REL" --argjson factor "$GLM_FACTOR" '
  ($rel_pct / 100) as $rel
  | 44 as $tw | 14 as $wkept | 30 as $wdropped   # tw=8*5+4*1; kept=2*5+4*1; dropped=6*5 (fixture-fixed)
  | (0.85 * $wkept / $tw) as $value
  | (1 - ($wdropped / $tw)) as $survival
  | (100 * (0.45 * $rel + 0.35 * ($value * $factor) + 0.20 * $survival) | round)
')"
GLM_ACTUAL_CAL_SCORE="$(jq -r '.calibration.factor as $f | .score' <<<"$GLM_CAL_JSON")"
assert_eq "glm calibrated score matches the 45/35/20 blend computed from json fields" \
  "$GLM_ACTUAL_CAL_SCORE" "$GLM_EXPECTED_CAL_SCORE"

echo "── (c) seat B (mimo): near-zero inflation -> factor pins to 1.00 ──"
MIMO_CAL_JSON="$(jq '.[] | select(.reviewer=="mimo")' <<<"$JSON_CALFLAG")"
assert_eq "mimo calibration.factor is 1.00" "$(jq -r '.calibration.factor' <<<"$MIMO_CAL_JSON")" "1.00"
assert_eq "mimo calibration.inflation is 0.00" "$(jq -r '.calibration.inflation' <<<"$MIMO_CAL_JSON")" "0.00"
MIMO_BASE_SCORE="$(jq -r '.[] | select(.reviewer=="mimo") | .score' <<<"$JSON_NOFLAG")"
MIMO_CAL_SCORE="$(jq -r '.score' <<<"$MIMO_CAL_JSON")"
assert_eq "mimo's score is unchanged by calibration (factor 1.00 is a no-op)" "$MIMO_CAL_SCORE" "$MIMO_BASE_SCORE"

echo "── (d) seat C (qwen): only 4 resolved, below calibration_min_n -> factor 1.00, applied=false ──"
QWEN_CAL_JSON="$(jq '.[] | select(.reviewer=="qwen")' <<<"$JSON_CALFLAG")"
assert_eq "qwen resolved is 4 (below the floor of 10)" "$(jq -r '.calibration.resolved' <<<"$QWEN_CAL_JSON")" "4"
assert_eq "qwen calibration.factor is 1.00 despite having some inflation signal" "$(jq -r '.calibration.factor' <<<"$QWEN_CAL_JSON")" "1.00"
assert_eq "qwen calibration.applied is false" "$(jq -r '.calibration.applied' <<<"$QWEN_CAL_JSON")" "false"
QWEN_BASE_SCORE="$(jq -r '.[] | select(.reviewer=="qwen") | .score' <<<"$JSON_NOFLAG")"
assert_eq "qwen's score is unchanged by calibration (below the floor)" "$(jq -r '.score' <<<"$QWEN_CAL_JSON")" "$QWEN_BASE_SCORE"

# ═══════════════════════════════════════════════════════════════════════════
# (e) the calibration factor composes with the existing solo-discount factor
# -- kat trips BOTH (own drop rate 0.30 > 0.15 threshold with n=10>=5, AND
# resolved=10 >= calibration_min_n).
# ═══════════════════════════════════════════════════════════════════════════
echo "── (e) seat D (kat): trips both the solo discount and calibration ──"
KAT_BASE_SCORE="$(jq -r '.[] | select(.reviewer=="kat") | .score' <<<"$JSON_NOFLAG")"
KAT_CAL_JSON="$(jq '.[] | select(.reviewer=="kat")' <<<"$JSON_CALFLAG")"
KAT_CAL_SCORE="$(jq -r '.score' <<<"$KAT_CAL_JSON")"
KAT_FACTOR="$(jq -r '.calibration.factor' <<<"$KAT_CAL_JSON")"
assert_eq "kat calibration.applied is true" "$(jq -r '.calibration.applied' <<<"$KAT_CAL_JSON")" "true"
assert_eq "kat calibration.factor is below 1.00 (inflation triggered)" \
  "$(awk -v f="$KAT_FACTOR" 'BEGIN{print (f < 1.00) ? "yes" : "no"}')" "yes"
# kat's BASE score already reflects the solo discount (0.7, baked in
# unconditionally by leaderboard.sh regardless of --calibration); its
# CALIBRATED score must be strictly lower still, showing the second discount
# stacked on top -- "gets both".
assert_eq "kat's calibrated score is strictly below its base (solo-discounted) score" \
  "$(awk -v c="$KAT_CAL_SCORE" -v b="$KAT_BASE_SCORE" 'BEGIN{print (c < b) ? "yes" : "no"}')" "yes"
KAT_REL="$(jq -r '.[] | select(.reviewer=="kat") | .reliability_pct' <<<"$JSON_NOFLAG")"
KAT_EXPECTED_CAL_SCORE="$(jq -n --argjson rel_pct "$KAT_REL" --argjson factor "$KAT_FACTOR" '
  ($rel_pct / 100) as $rel
  | 34 as $tw | 19 as $wkept | 15 as $wdropped   # tw=6*5+4*1; kept=3*5+4*1 at tier 1.0*0.7; dropped=3*5
  | ((1.0 * 0.7) * $wkept / $tw) as $value
  | (1 - ($wdropped / $tw)) as $survival
  | (100 * (0.45 * $rel + 0.35 * ($value * $factor) + 0.20 * $survival) | round)
')"
assert_eq "kat's calibrated score matches the blend with BOTH discounts composed" "$KAT_CAL_SCORE" "$KAT_EXPECTED_CAL_SCORE"

# ═══════════════════════════════════════════════════════════════════════════
# (f) bad usage exits 2: an unrecognized value glued to --calibration, and a
# mistyped flag name.
# ═══════════════════════════════════════════════════════════════════════════
echo "── (f) --calibration with an unknown extra value or a mistyped flag exits 2 ──"
RUN_LB --mode json --calibration=true >/dev/null 2>&1
RC_GLUED=$?
assert_eq "--calibration=true (glued value) exits 2" "$RC_GLUED" "2"
RUN_LB --mode json --calibrat >/dev/null 2>&1
RC_TYPO=$?
assert_eq "--calibrat (typo) exits 2" "$RC_TYPO" "2"

# ═══════════════════════════════════════════════════════════════════════════
# (g) draw weight order changes when the flag is on: kat (base 70) ranks
# above qwen (base 69) without the flag; with it, kat drops to 68 and qwen
# (unaffected, below the floor) stays at 69 -- the rank flips.
# ═══════════════════════════════════════════════════════════════════════════
echo "── (g) draw weight order changes: kat drops below qwen once calibrated ──"
assert_eq "base order: kat (70) ranks above qwen (69)" \
  "$([[ "$KAT_BASE_SCORE" -gt "$QWEN_BASE_SCORE" ]] && echo yes || echo no)" "yes"
assert_eq "calibrated order: qwen (69, unaffected) now ranks above kat (68, discounted)" \
  "$([[ "$(jq -r '.score' <<<"$QWEN_CAL_JSON")" -gt "$KAT_CAL_SCORE" ]] && echo yes || echo no)" "yes"

SORTED_CAL_REVIEWERS="$(jq -r '.[] | select(.reviewer=="kat" or .reviewer=="qwen") | .reviewer' <<<"$JSON_CALFLAG")"
assert_eq "sorted --mode json (calibrated) lists qwen before kat" "$SORTED_CAL_REVIEWERS" "$(printf 'qwen\nkat')"

# --mode table reflects the same flip in its rank markers.
TABLE_KAT_RANK="$(grep -oE '#[0-9]+  kat ' <<<"$TABLE_CALFLAG" | grep -oE '[0-9]+')"
TABLE_QWEN_RANK="$(grep -oE '#[0-9]+  qwen ' <<<"$TABLE_CALFLAG" | grep -oE '[0-9]+')"
assert_eq "calibrated table ranks qwen above kat" \
  "$([[ "$TABLE_QWEN_RANK" -lt "$TABLE_KAT_RANK" ]] && echo yes || echo no)" "yes"

# ═══════════════════════════════════════════════════════════════════════════
# Extra: --mode report prints a "severity calibration applied" block listing
# every applied=true seat (and only those), and never appears without the
# flag.
# ═══════════════════════════════════════════════════════════════════════════
echo "── --mode report: severity calibration applied block ──"
REPORT_NOFLAG="$(RUN_LB --mode report 2>/dev/null)"
REPORT_CALFLAG="$(RUN_LB --mode report --calibration 2>/dev/null)"
assert_contains "report (no flag) has no calibration-applied heading" \
  "$( [[ "$REPORT_NOFLAG" == *"severity calibration applied"* ]] && echo present || echo absent )" "absent"
assert_contains "report (--calibration) has the calibration-applied heading" "$REPORT_CALFLAG" "severity calibration applied"
assert_contains "calibration-applied block lists glm" "$REPORT_CALFLAG" "glm [zhipu] — factor 0.67"
assert_contains "calibration-applied block lists kat" "$REPORT_CALFLAG" "kat [kuaishou] — factor 0.83"
assert_contains "calibration-applied block lists mimo (applied even at factor 1.00)" "$REPORT_CALFLAG" "mimo [xiaomi] — factor 1.00"
assert_eq "calibration-applied block does NOT list qwen (below the floor)" \
  "$(grep -c 'qwen \[alibaba\] — factor' <<<"$REPORT_CALFLAG")" "0"

echo
echo "══ $PASS passed, $FAIL failed ══"
[[ "$FAIL" -eq 0 ]] || exit 1
exit 0
