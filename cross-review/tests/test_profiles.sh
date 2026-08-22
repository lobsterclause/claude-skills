#!/usr/bin/env bash
# test_profiles.sh — standalone offline fixture test for
# references/reviewer_profiles.json. NO network, no reviewer CLIs, no tokens.
#
# Mirrors run_tests.sh's fixture/assertion conventions (assert_eq/assert_contains,
# mktemp -d + trap cleanup) but is intentionally NOT wired into run_tests.sh —
# the parent orchestrating session wires it in later (collision avoidance; see
# tests/test_digest.sh / tests/test_score_findings.sh for the same pattern).
#
# Added 2026-08-03 alongside benching the disproven-heavy rotation tail
# (north, laguna, devstral, qwen, mimo) via draw_boost + bench_note, and the
# kimi3 timeout_s 600 -> 700 bump. Asserts the profile file stays internally
# consistent as those knobs keep moving.
#
# Run:  bash tests/test_profiles.sh
# Exit: 0 all green, 1 any failure.

set -uo pipefail

SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROFILES="$SKILL_DIR/references/reviewer_profiles.json"

PASS=0
FAIL=0
ok()  { echo "  ok   $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL $1"; FAIL=$((FAIL + 1)); }
assert_eq() {
  if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 (got: '$2' want: '$3')"; fi
}

command -v jq >/dev/null 2>&1 || { echo "jq required to run these tests" >&2; exit 1; }
[[ -f "$PROFILES" ]] || { echo "FATAL: $PROFILES missing"; exit 1; }

echo "── reviewer_profiles.json parses as valid JSON ──"
if jq empty "$PROFILES" >/dev/null 2>&1; then
  ok "reviewer_profiles.json is valid JSON"
else
  bad "reviewer_profiles.json failed to parse — aborting remaining checks"
  echo
  echo "══ $PASS passed, $FAIL failed ══"
  exit 1
fi

echo "── benched seats: draw_boost <= 0.3 wherever bench_note is present ──"
# A bench is a draw-side demotion, not a removal — draw_boost must stay low
# (<= 0.3) for every profile that carries a bench_note. This also guards
# against a future bench_note being added without its accompanying draw_boost.
OVER_BOOSTED="$(jq -r '
  to_entries[]
  | select(.value | type == "object")
  | select(.value.bench_note != null)
  | select((.value.draw_boost // 999) > 0.3)
  | .key
' "$PROFILES")"
assert_eq "no benched profile exceeds draw_boost 0.3" "$OVER_BOOSTED" ""

# 600 -> 700 (2026-08-03) was sized off a p95 of 574s, which left under 10%
# headroom; the seat then timed out in 33% of its last 3 runs with a p95 of
# 700s — sitting exactly ON the budget, which is the shape of a ceiling being
# hit rather than a slow run. 950 restores ~35% headroom over that p95. The pin
# moves with the profile deliberately: it exists so a bump arrives with the
# numbers that justify it, not so the number never changes.
echo "── kimi3.timeout_s bumped to 950 (p95 700s was sitting ON the old budget) ──"
assert_eq "kimi3.timeout_s == 950" "$(jq -r '.kimi3.timeout_s' "$PROFILES")" "950"

echo "── kimi3.draw_boost RETIRED 2026-08-22 (bring-up complete, per Gabriel) ──"
# This asserted 2.5 "unchanged by this bench" while kimi3 was still earning
# leaderboard data. That condition has now been met, so the assertion is
# inverted rather than deleted -- the retirement itself is the thing worth
# pinning, exactly as kimi27's was on 2026-07-12. Both Moonshot rotation
# seats are back to 1.0.
assert_eq "kimi3.draw_boost == 1.0 (retired after bring-up)" "$(jq -r '.kimi3.draw_boost' "$PROFILES")" "1.0"
assert_eq "kimi27.draw_boost == 1.0 (retired 2026-07-12)" "$(jq -r '.kimi27.draw_boost' "$PROFILES")" "1.0"

echo "── the five disproven-heavy tail seats each carry a bench_note ──"
for seat in north laguna devstral qwen mimo; do
  note="$(jq -r --arg s "$seat" '.[$s].bench_note // "MISSING"' "$PROFILES")"
  if [[ "$note" != "MISSING" && -n "$note" ]]; then
    ok "$seat carries a bench_note"
  else
    bad "$seat is missing bench_note"
  fi
  boost="$(jq -r --arg s "$seat" '.[$s].draw_boost // "MISSING"' "$PROFILES")"
  assert_eq "$seat.draw_boost == 0.2" "$boost" "0.2"
done

echo
echo "══ $PASS passed, $FAIL failed ══"
[[ "$FAIL" -eq 0 ]]
