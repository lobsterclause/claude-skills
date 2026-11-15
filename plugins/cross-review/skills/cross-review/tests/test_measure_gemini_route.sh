#!/usr/bin/env bash
# test_measure_gemini_route.sh — fixture test for scripts/measure_gemini_route.sh:
# the per-route arithmetic, the --if-due banner gate (silent before the review
# date, banner after), and never failing a round.
#
# Run:  bash tests/test_measure_gemini_route.sh   ·   Exit: 0 all green, 1 any failure.
set -uo pipefail
SKILL="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
M="$SKILL/scripts/measure_gemini_route.sh"
PASS=0; FAIL=0
ok()  { echo "  ok   $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL $1"; FAIL=$((FAIL + 1)); }
command -v jq >/dev/null 2>&1 || { echo "  skip measure_gemini_route (jq unavailable)"; exit 0; }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
RL="$TMP/runlog.jsonl"

# row <ts> <verdict> <route|-> <reason> <status> <duration> <findings>
row() {
  local r='null'; [[ "$3" != "-" ]] && r="\"$3\""
  printf '{"ts":"%s","verdict":"%s","reviewers":{"gemini-pro":{"route":%s,"route_reason":"%s","status":"%s","duration_s":%s,"findings_total":%s}}}\n' \
    "$1" "$2" "$r" "$4" "$5" "$6" "$7" >>"$RL"
}
# 20 argon:high runs: 4 timed out (20%), findings 2 each, 5 CLEAN (25%), median 100.
for i in $(seq 1 20); do
  st=ok; [[ $i -le 4 ]] && st=timed_out
  v=FIXES_APPLIED; [[ $i -le 5 ]] && v=CLEAN
  row "2026-11-2${i:0:1}T00:00:00Z" "$v" argon:high "pass1(lines=$i)" "$st" 100 2
done
# 3 thin hydrogen:medium runs and one pre-router (no route) run, plus a row before --since.
for i in 1 2 3; do row "2026-11-25T00:00:0${i}Z" CLEAN hydrogen:medium "pass3_plus(pass=3)" ok 40 0; done
row "2026-11-26T00:00:00Z" CLEAN - "" ok 10 1
row "2026-10-01T00:00:00Z" CLEAN argon:high "pass1(lines=1)" ok 10 9
printf 'not json at all\n' >>"$RL"

OUT="$(bash "$M" --runlog "$RL" --since 2026-11-01 2>&1)"; rc=$?
[[ $rc -eq 0 ]] && ok "exits 0 on a readable runlog" || bad "rc=$rc"
grep -Eq 'argon:high +\| +20 \| +20% \| +100 \| +2 \| +25%' <<<"$OUT" && ok "argon:high row: n=20, 20% timed out, median 100, 2 findings/run, 25% CLEAN" || bad "argon:high row wrong: $OUT"
grep -Eq 'hydrogen:medium +\| +3\*' <<<"$OUT" && ok "a thin cell is starred" || bad "no star on the thin cell"
grep -q "routed runs: 23 .* 1" <<<"$OUT" && ok "unrouted rows are counted apart, pre---since rows excluded" || bad "routed/unrouted counts: $OUT"
grep -q "unparseable" <<<"$OUT" && ok "a torn row is reported, not fatal" || bad "torn row not reported"
grep -q "pass1" <<<"$OUT" && ok "groups by the rule that fired" || bad "no rule grouping"

echo "── --if-due ──"
OUT="$(CROSS_REVIEW_ROUTE_REVIEW_DUE=2099-01-01 bash "$M" --runlog "$RL" --if-due 2>&1)"; rc=$?
[[ $rc -eq 0 && -z "$OUT" ]] && ok "silent before the review date" || bad "not silent before due (rc=$rc out=${OUT:0:80})"
OUT="$(CROSS_REVIEW_ROUTE_REVIEW_DUE=2000-01-01 bash "$M" --runlog "$RL" --since 2026-11-01 --if-due 2>&1)"; rc=$?
[[ $rc -eq 0 ]] && grep -q "REVIEW DUE" <<<"$OUT" && grep -q "argon:high" <<<"$OUT" && ok "banner + report once due" || bad "no banner after due"
OUT="$(bash "$M" --runlog "$TMP/missing" --if-due 2>&1)"; rc=$?
[[ $rc -eq 0 && -z "$OUT" ]] && ok "--if-due with no runlog never stops a round" || bad "if-due failed on a missing runlog (rc=$rc)"
bash "$M" --runlog "$TMP/missing" >/dev/null 2>&1; [[ $? -eq 2 ]] && ok "without --if-due a missing runlog is exit 2" || bad "missing runlog rc"
# The profile's own review date drives the gate when no override is set.
OUT="$(bash "$M" --runlog "$RL" --if-due 2>&1)"
due="$(jq -r '.["gemini-pro"].router.review_due' "$SKILL/references/reviewer_profiles.json")"
if [[ "$(date +%F)" < "$due" ]]; then [[ -z "$OUT" ]] && ok "profile review_due ($due) gates the banner" || bad "banner before profile review_due"
else grep -q "REVIEW DUE" <<<"$OUT" && ok "past profile review_due ($due): banner" || bad "no banner past review_due"; fi

echo; echo "══ $PASS passed, $FAIL failed ══"
[[ "$FAIL" -eq 0 ]]
