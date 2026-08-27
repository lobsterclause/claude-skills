#!/usr/bin/env bash
# test_audit_roster.sh — standalone fixture test for audit_roster.sh (#94).
#
# NO network, NO reviewer CLIs, NO tokens: pure fixture JSONL + jq math.
# Standalone: NOT wired into run_tests.sh yet (the parent wires new test
# files in after the round) -- run directly:
#   bash cross-review/tests/test_audit_roster.sh
#
# Fixture: 40 entries with roster_decision, one candidate pool per entry
# {nemotron: weight 1 (draw_boost 0), ghost: weight 50 (never selected),
#  alpha: weight 60, beta: weight 65, gamma: weight 70}. Exactly one
# candidate is selected per entry: nemotron on 5 of the 40 rounds (the
# recorded 5/40 nemotron-boost-0 case), alpha/beta/gamma round-robin on the
# rest. ghost is never selected despite a healthy weight -> starved.
# 3 trailing entries carry no roster_decision at all (legacy rows).
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
assert_gt() {
  # numeric >, via awk (portable, no bc dependency)
  if awk -v a="$2" -v b="$3" 'BEGIN{exit !(a > b)}'; then ok "$1"; else bad "$1 (got: '$2', want > $3)"; fi
}

# ── build fixture runlog ─────────────────────────────────────────────────────
FIXLOG="$T/runlog.jsonl"
: >"$FIXLOG"

for i in $(seq 0 39); do
  ts=$(printf '2026-07-%02dT%02d:00:00Z' $((1 + i / 24)) $((i % 24)))
  policy="v1"
  if [[ "$i" -ge 30 ]]; then policy="v2"; fi

  # decide who is selected this round
  nemotron_selected="false"
  alpha_selected="false"
  beta_selected="false"
  gamma_selected="false"
  if (( i % 8 == 0 )); then
    nemotron_selected="true"
  else
    case $(( i % 3 )) in
      0) alpha_selected="true" ;;
      1) beta_selected="true" ;;
      2) gamma_selected="true" ;;
    esac
  fi

  candidates=$(jq -nc \
    --argjson nsel "$nemotron_selected" \
    --argjson asel "$alpha_selected" \
    --argjson bsel "$beta_selected" \
    --argjson gsel "$gamma_selected" \
    '[
      {reviewer:"nemotron", score:80, attempts:1, latest_status:"ok", p50_duration_s:90, cost_usd:0, draw_boost:0, weight:1,  selected:$nsel},
      {reviewer:"ghost",    score:70, attempts:1, latest_status:"ok", p50_duration_s:90, cost_usd:0, draw_boost:1, weight:50, selected:false},
      {reviewer:"alpha",    score:75, attempts:1, latest_status:"ok", p50_duration_s:90, cost_usd:0, draw_boost:1, weight:60, selected:$asel},
      {reviewer:"beta",     score:75, attempts:1, latest_status:"ok", p50_duration_s:90, cost_usd:0, draw_boost:1, weight:65, selected:$bsel},
      {reviewer:"gamma",    score:75, attempts:1, latest_status:"ok", p50_duration_s:90, cost_usd:0, draw_boost:1, weight:70, selected:$gsel}
    ]')

  selected_list=$(printf '%s' "$candidates" | jq -c '[.[] | select(.selected==true) | .reviewer]')

  jq -nc --arg ts "$ts" --arg policy "$policy" --argjson candidates "$candidates" --argjson selected "$selected_list" '
    {
      ts: $ts,
      roster_decision: {
        roster: (["codex","kimi"] + $selected | join(",")),
        baselines: ["codex","kimi"],
        selected: $selected,
        seed: 12345,
        policy_version: $policy,
        candidates: $candidates
      }
    }' >>"$FIXLOG"
done

# 3 trailing entries WITHOUT roster_decision (legacy rows).
for i in 40 41 42; do
  ts=$(printf '2026-07-%02dT%02d:00:00Z' $((1 + i / 24)) $((i % 24)))
  jq -nc --arg ts "$ts" '{ts: $ts}' >>"$FIXLOG"
done

n_nemotron_selected=$(jq -c 'select(.roster_decision != null) | .roster_decision.selected[]' "$FIXLOG" | grep -c '"nemotron"' || true)
n_ghost_selected=$(jq -c 'select(.roster_decision != null) | .roster_decision.selected[]' "$FIXLOG" | grep -c '"ghost"' || true)
echo "fixture check: nemotron selected $n_nemotron_selected/40, ghost selected $n_ghost_selected/40"

# ── RED-confirmed-then-implemented target ────────────────────────────────────
SCRIPT="$S/audit_roster.sh"
if [[ ! -f "$SCRIPT" ]]; then
  bad "audit_roster.sh exists"
  echo ""
  echo "PASS=$PASS FAIL=$FAIL"
  exit 1
fi
ok "audit_roster.sh exists"

echo "── audit_roster.sh (text report) ──"
OUT="$(CROSS_REVIEW_RUNLOG="$FIXLOG" bash "$SCRIPT" 2>&1)"
RC=$?
assert_eq "exits 0 (report, not a gate)" "$RC" "0"
assert_contains "reports skipped legacy entries" "$OUT" "skipped 3"
assert_contains "reports used entries" "$OUT" "entries: 40"
assert_contains "WARN present" "$OUT" "WARN"
assert_contains "nemotron flagged" "$OUT" "nemotron"
assert_contains "nemotron flagged over-drawn" "$OUT" "over-drawn"
assert_contains "ghost flagged" "$OUT" "ghost"
assert_contains "ghost flagged starved" "$OUT" "starved"
assert_contains "days_since_drawn column present" "$OUT" "days_since_drawn"
assert_contains "policy_version distribution present" "$OUT" "policy_version:"
assert_contains "policy_version v1 count present" "$OUT" "v1=30"
assert_contains "policy_version v2 count present" "$OUT" "v2=10"

echo "── audit_roster.sh --json ──"
JOUT="$(CROSS_REVIEW_RUNLOG="$FIXLOG" bash "$SCRIPT" --json 2>&1)"
if printf '%s' "$JOUT" | jq -e . >/dev/null 2>&1; then
  ok "--json output is valid JSON"
else
  bad "--json output is valid JSON (got: $JOUT)"
fi
assert_eq "--json entries_used" "$(printf '%s' "$JOUT" | jq -r '.entries_used')" "40"
assert_eq "--json entries_skipped" "$(printf '%s' "$JOUT" | jq -r '.entries_skipped')" "3"
nem_ratio="$(printf '%s' "$JOUT" | jq -r '.seats[] | select(.reviewer=="nemotron") | .ratio')"
assert_gt "nemotron ratio > 2 in json" "$nem_ratio" "2"
nem_draws="$(printf '%s' "$JOUT" | jq -r '.seats[] | select(.reviewer=="nemotron") | .draws')"
assert_eq "nemotron draws == 5" "$nem_draws" "5"
ghost_starved="$(printf '%s' "$JOUT" | jq -r '.seats[] | select(.reviewer=="ghost") | .starved')"
assert_eq "ghost starved == true in json" "$ghost_starved" "true"

echo "── audit_roster.sh --recent (window) ──"
# Last 10 raw entries: indices 33..39 (7 with roster_decision) + 40,41,42
# (3 without). nemotron is drawn 0 times in the used window (i=32 is outside;
# i=40 has no roster_decision).
ROUT="$(CROSS_REVIEW_RUNLOG="$FIXLOG" bash "$SCRIPT" --recent 10 2>&1)"
assert_contains "--recent narrows the window" "$ROUT" "entries: 7"
assert_contains "--recent still reports skipped legacy rows" "$ROUT" "skipped 3"

echo "── argument validation ──"
CROSS_REVIEW_RUNLOG="$FIXLOG" bash "$SCRIPT" --recent abc >/dev/null 2>"$T/err"; rc=$?
assert_eq "--recent abc exits 2" "$rc" "2"
assert_contains "--recent abc names the bad value" "$(cat "$T/err")" "invalid --recent"
CROSS_REVIEW_RUNLOG="$FIXLOG" bash "$SCRIPT" --recent -5 >/dev/null 2>&1; rc=$?
assert_eq "--recent -5 exits 2" "$rc" "2"

echo "── multi-pick expectation (without replacement) ──"
# One entry, two picks, weights 50/30/20. Inclusion probabilities:
#   A: .5 + .3*.5/.7 + .2*.5/.8 = 0.8393   (nsel*w/total would say 1.0)
#   B: .3 + .5*.3/.5 + .2*.3/.8 = 0.6750
#   C: .2 + .5*.2/.5 + .3*.2/.7 = 0.4857   (sum = 2 = nsel)
MPLOG="$T/multipick.jsonl"
jq -nc '{ts:"2026-07-05T00:00:00Z", roster_decision:{policy_version:"v2", candidates:[
  {reviewer:"A", weight:50, selected:true},
  {reviewer:"B", weight:30, selected:true},
  {reviewer:"C", weight:20, selected:false}]}}' >"$MPLOG"
MP="$(bash "$SCRIPT" --runlog "$MPLOG" --json 2>&1)"
assert_eq "A expected is inclusion probability, not nsel*share" "$(printf '%s' "$MP" | jq -r '.seats[] | select(.reviewer=="A") | .expected')" "0.8393"
assert_eq "B expected" "$(printf '%s' "$MP" | jq -r '.seats[] | select(.reviewer=="B") | .expected')" "0.675"
assert_eq "C expected" "$(printf '%s' "$MP" | jq -r '.seats[] | select(.reviewer=="C") | .expected')" "0.4857"
assert_eq "expectations sum to nsel" "$(printf '%s' "$MP" | jq -r '[.seats[].expected] | add | . * 1000 | round')" "2000"

echo "── same-second entries and legacy tail ──"
# Two entries in the same second: X drawn in the first, Y in the second, then
# a legacy row 30 days later without roster_decision. rounds_since_drawn for X
# must count the same-second entry (1), and days_since_drawn must ignore the
# legacy tail (0 for Y, not 30).
SSLOG="$T/samesec.jsonl"
{
  jq -nc '{ts:"2026-07-05T00:00:00Z", roster_decision:{candidates:[{reviewer:"X",weight:50,selected:true},{reviewer:"Y",weight:50,selected:false}]}}'
  jq -nc '{ts:"2026-07-05T00:00:00Z", roster_decision:{candidates:[{reviewer:"X",weight:50,selected:false},{reviewer:"Y",weight:50,selected:true}]}}'
  jq -nc '{ts:"2026-08-04T00:00:00Z", verdict:"CLEAN"}'
} >"$SSLOG"
SS="$(bash "$SCRIPT" --runlog "$SSLOG" --json 2>&1)"
assert_eq "X rounds_since_drawn counts the same-second entry" "$(printf '%s' "$SS" | jq -r '.seats[] | select(.reviewer=="X") | .rounds_since_drawn')" "1"
assert_eq "Y days_since_drawn ignores the legacy tail" "$(printf '%s' "$SS" | jq -r '.seats[] | select(.reviewer=="Y") | .days_since_drawn')" "0"

echo "── starved message counts positive-weight rounds ──"
SOUT="$(CROSS_REVIEW_RUNLOG="$FIXLOG" bash "$SCRIPT" 2>&1)"
assert_contains "starved line reports positive-weight rounds" "$SOUT" "ghost starved (weight > 0 in 40 of 40 candidate rounds"

echo ""
echo "PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]] || exit 1
