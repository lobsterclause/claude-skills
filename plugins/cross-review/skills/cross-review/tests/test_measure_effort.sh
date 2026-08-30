#!/usr/bin/env bash
# test_measure_effort.sh — offline fixture test for scripts/measure_codex_effort.sh.
#
# The script exists so "check back in a week" is a mechanism rather than
# something someone remembers. That only holds if the mechanism is right when
# it is finally run — a week from now, against data nobody has seen, by someone
# who will read its table at face value. So the arithmetic is pinned here
# against a synthetic runlog with known answers, and so are the two ways it
# could mislead: a thin cell presented as a signal, and a cell that is empty.
#
# Run:  bash tests/measure_effort.sh   ·   Exit: 0 all green, 1 any failure.

set -uo pipefail

SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
M="$SKILL_DIR/scripts/measure_codex_effort.sh"

PASS=0; FAIL=0
ok()  { echo "  ok   $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL $1"; FAIL=$((FAIL + 1)); }

[[ -f "$M" ]] || { echo "FATAL: $M missing"; exit 1; }
if ! command -v jq >/dev/null 2>&1; then
  echo "  skip measure_codex_effort (jq unavailable)"; exit 0
fi

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
RL="$TMP/runlog.jsonl"

# row <ts> <pass> <verdict> <duration> <findings> <account_limit:0|1>
row() {
  local fb='null'
  [[ "$6" == 1 ]] && fb='{"used":true,"reason":"account_limit"}'
  printf '{"ts":"%s","pass":%s,"verdict":"%s","reviewers":{"codex":{"duration_s":%s,"findings_total":%s,"fallback":%s}}}\n' \
    "$1" "$2" "$3" "$4" "$5" "$fb" >> "$RL"
}

CUT=2026-09-01
# 20 before-window pass-1 rows: 5 hit the quota wall -> 25%, median duration 10.
for i in $(seq 1 20); do
  al=0; [[ $i -le 5 ]] && al=1
  row "2026-08-2${i:0:1}T00:00:00Z" 1 FIXES_APPLIED 10 2 "$al"
done
# 20 after-window pass-1 rows: 1 hits the wall -> 5%, median duration 4.
for i in $(seq 1 20); do
  al=0; [[ $i -le 1 ]] && al=1
  row "2026-09-0${i:0:1}T00:00:00Z" 1 CLEAN 4 1 "$al"
done
# Passes 3 and 4 must land in the SAME bucket — the ladder treats them alike,
# so a report that split them would describe a policy that does not exist.
for i in $(seq 1 20); do
  row "2026-09-05T00:00:0${i:0:1}Z" 3 CLEAN 7 0 0
  row "2026-09-06T00:00:0${i:0:1}Z" 4 CLEAN 7 0 0
done
# One lone pass-2 row after the cutover: a cell too thin to mean anything.
row "2026-09-07T00:00:00Z" 2 CLEAN 99 9 0

OUT="$(bash "$M" --runlog "$RL" --since "$CUT" 2>&1)"
rc=$?
[[ $rc -eq 0 ]] && ok "exits 0 on a readable runlog" || bad "exit (rc=$rc want=0)"

line_for() { grep -E "^  $1 +\| $2" <<<"$OUT" | head -1; }

# The number the ladder actually targets.
if [[ "$(line_for 1 before)" == *"25%"* ]]; then ok "pass-1 before: account_limit rate is 25%"
else bad "pass-1 before acct rate"; echo "      $(line_for 1 before)"; fi
if [[ "$(line_for 1 after)" == *" 5%"* ]]; then ok "pass-1 after: account_limit rate is 5%"
else bad "pass-1 after acct rate"; echo "      $(line_for 1 after)"; fi

# Split on the cutover, not on the whole file.
if [[ "$(line_for 1 before)" =~ 20[[:space:]] ]] && [[ "$(line_for 1 after)" =~ 20[[:space:]] ]]; then
  ok "the cutover splits the rows 20/20"
else bad "cutover split"; echo "      $(line_for 1 before) / $(line_for 1 after)"; fi

# 20 pass-3 + 20 pass-4 = 40 in one cell.
if [[ "$(line_for '3\+' after)" =~ 40 ]]; then ok "pass 3 and pass 4 share the 3+ bucket"
else bad "3+ bucketing"; echo "      $(line_for '3\+' after)"; fi

# A cell of one must be visibly untrustworthy. Without the marker its 9
# findings/run reads as a finding rather than as a single round.
if [[ "$(line_for 2 after)" == *"*"* ]]; then ok "a 1-run cell is starred as thin"
else bad "thin-cell marker"; echo "      $(line_for 2 after)"; fi
if [[ "$(line_for 1 after)" != *"*"* ]]; then ok "a 20-run cell is not starred"
else bad "20-run cell wrongly starred"; echo "      $(line_for 1 after)"; fi

# An empty cell must print as empty, not as zero — "0 findings/run" and "no
# data" are opposite conclusions.
if [[ "$(line_for 2 before)" == *"—"* ]]; then ok "an empty cell prints em-dashes, not zeros"
else bad "empty cell"; echo "      $(line_for 2 before)"; fi

# The caveats are load-bearing: this report is read once, cold, a week later.
grep -q "PROXY for review quality" <<<"$OUT" \
  && ok "names findings/run as a proxy, not as quality" || bad "proxy caveat missing"
grep -q "CHECK THE CUTOVER" <<<"$OUT" \
  && ok "warns that a wrong cutover fakes the after rows" || bad "cutover caveat missing"

# All-thin after-data must say so instead of inviting a reading.
: > "$RL"
row "2026-08-01T00:00:00Z" 1 CLEAN 5 1 0
row "2026-09-02T00:00:00Z" 1 CLEAN 5 1 0
if bash "$M" --runlog "$RL" --since "$CUT" 2>&1 | grep -q "NO USABLE AFTER-DATA YET"; then
  ok "all-thin after-data reports itself as unusable"
else bad "thin-data verdict"; fi

# It reports; it does not gate. A bad result must never fail a caller.
bash "$M" --runlog "$RL" --since "$CUT" >/dev/null 2>&1
[[ $? -eq 0 ]] && ok "an unfavourable report still exits 0 (reports, never gates)" \
               || bad "must not gate"

bash "$M" --runlog "$TMP/nope.jsonl" >/dev/null 2>&1
[[ $? -eq 2 ]] && ok "a missing runlog exits 2, not 0" || bad "missing runlog exit"

# ── --if-due: the part that makes this a mechanism rather than a note ──
#
# It runs in front of every round via SKILL.md step 1.5, so it has exactly two
# jobs: say nothing until the date, and say something after it. Both are
# exercised here because a scheduled check first observed on the day it fires
# is a check nobody has ever seen work — and the failure mode (silence) is
# indistinguishable from the healthy one.
due_out="$(CROSS_REVIEW_EFFORT_REVIEW_DUE=2099-01-01 bash "$M" --if-due --runlog "$RL" 2>&1)"
if [[ -z "$due_out" && $? -eq 0 ]]; then ok "--if-due is silent before the review date"
else bad "--if-due should be silent before the date"; echo "      $due_out"; fi

due_out="$(CROSS_REVIEW_EFFORT_REVIEW_DUE=2026-01-01 bash "$M" --if-due --runlog "$RL" 2>&1)"
if grep -q "REVIEW DUE" <<<"$due_out"; then ok "--if-due prints the banner once due"
else bad "--if-due banner"; echo "      ${due_out:0:120}"; fi
if grep -q "before/after" <<<"$due_out"; then ok "--if-due prints the report, not just a nudge"
else bad "--if-due report"; fi
# The banner has to say what to DO, or it becomes a line people scroll past
# every round forever.
if grep -q "REVIEW_DUE" <<<"$due_out"; then ok "the banner says how to make it stop"
else bad "banner must name the way to silence it"; fi

# Due, but nothing to report on: it still must not fail the round it precedes.
CROSS_REVIEW_EFFORT_REVIEW_DUE=2026-01-01 bash "$M" --if-due --runlog "$TMP/nope.jsonl" >/dev/null 2>&1
[[ $? -eq 0 ]] && ok "--if-due with no runlog stays quiet instead of failing the round" \
               || bad "--if-due must never break a round"

echo
echo "══ $PASS passed, $FAIL failed ══"
[[ "$FAIL" -eq 0 ]]
