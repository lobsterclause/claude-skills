#!/usr/bin/env bash
# test_baseline_hang_streak.sh — #3587 case 2: a baseline CLI that is present,
# executable and authenticated but HANGS every call must read as unavailable,
# so detect_reviewers.sh's fail-closed baseline rule sees it — and nothing
# else may make it read that way.
#
# The "nothing else" half is most of this file (#189 pass 1):
#   - a machine-sleep timeout (wall_over_budget) is not a hang;
#   - the streak must clear itself: once detection fails closed no new rounds
#     run, so no new runlog rows could ever break a streak made of old ones;
#   - streak mode is on detection's hot path (once per baseline per round), so
#     it must not compute the whole fleet report first.
#
# Offline: CLIs are shims, HOME is a sandbox, and the runlog is a fixture from
# the first case on — never the live one beside the skill.
#
# Run:  bash tests/test_baseline_hang_streak.sh   ·   Exit: 0 all green, 1 any failure.

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

command -v jq >/dev/null 2>&1 || { echo "  skip baseline hang streak (jq unavailable)"; exit 0; }

unset CROSS_REVIEW_GLM_BASELINE CROSS_REVIEW_KIMI_BASELINE CROSS_REVIEW_OPENROUTER \
      CROSS_REVIEW_ALLOW_MISSING_BASELINE CROSS_REVIEW_ZAI_ENDPOINT CROSS_REVIEW_HANG_WINDOW_H \
      MOONSHOT_API_KEY Z_AI_API_KEY OPENROUTER_API_KEY
export CROSS_REVIEW_TOOL_MODE=off
FIXLOG="$T/runlog.jsonl"; : >"$FIXLOG"
export CROSS_REVIEW_RUNLOG="$FIXLOG"

mkdir -p "$T/bin"
printf '#!/bin/sh\nprintf "shim\\n"\n' >"$T/bin/codex"
printf '#!/bin/sh\ncat >/dev/null 2>&1 || true\nprintf "shim review: no findings\\n"\n' >"$T/bin/kimi"
printf '#!/bin/sh\nif [ "$1" = "models" ]; then printf "Gemini 3.8 Flash (High)\\nGemini 3.1 Pro (High)\\n"; fi\n' >"$T/bin/agy"
chmod +x "$T/bin/"*
export PATH="$T/bin:$PATH"
export HOME="$T/home"; mkdir -p "$HOME"
export ZAI_API_KEY="sk-zai-test-shim"

# row <minutes-ago> <reviewer> <status> [wall_over_budget]
ts_ago() {
  date -u -d "-$1 minutes" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v-"$1"M +%Y-%m-%dT%H:%M:%SZ
}
row() {
  jq -nc --arg ts "$(ts_ago "$1")" --arg r "$2" --arg s "$3" --argjson w "${4:-false}" \
    '{ts:$ts, reviewers:{($r):{status:$s, wall_over_budget:$w}}}' >>"$FIXLOG"
}
streak() { bash "$S/analyze_runlog.sh" --mode streak --reviewer "$1" --streak-n 3 2>/dev/null; }

echo "── analyze_runlog.sh --mode streak ──"
: >"$FIXLOG"; row 30 kimi timed_out; row 20 kimi timed_out; row 10 kimi timed_out
assert_eq "three recent consecutive timeouts are a streak" "$(streak kimi)" "3"
assert_eq "a reviewer with no rows streaks 0, not an error" "$(streak codex)" "0"
assert_eq "an empty runlog prints an explicit 0" "$(: >"$T/empty.jsonl"; CROSS_REVIEW_RUNLOG="$T/empty.jsonl" streak kimi)" "0"
assert_eq "a missing runlog prints an explicit 0" "$(CROSS_REVIEW_RUNLOG="$T/nope.jsonl" streak kimi)" "0"

: >"$FIXLOG"; row 30 kimi timed_out; row 20 kimi timed_out; row 10 kimi ok
assert_eq "a streak broken by a recent success reads 0" "$(streak kimi)" "0"

# Machine sleep freezes the timer, so the wall clock overruns the budget and
# the row reads timed_out without the CLI having hung (#189 pass 1).
: >"$FIXLOG"; row 30 kimi timed_out; row 20 kimi timed_out true; row 10 kimi timed_out
assert_eq "a sleep-suspect timeout does not count toward a streak" "$(streak kimi)" "0"
: >"$FIXLOG"; row 40 kimi timed_out; row 30 kimi timed_out; row 20 kimi ok true; row 10 kimi timed_out
assert_eq "…nor break one: it is skipped, and the real attempts around it decide" "$(streak kimi)" "3"

# Self-clearing: a streak older than the window no longer counts, so a
# baseline benched by detection gets tried again instead of staying benched
# until someone sets the escape hatch.
: >"$FIXLOG"; row 3000 kimi timed_out; row 2990 kimi timed_out; row 2980 kimi timed_out
assert_eq "a streak older than the 24h window has cleared" "$(streak kimi)" "0"
assert_eq "…and the window is configurable" \
  "$(CROSS_REVIEW_HANG_WINDOW_H=72 bash "$S/analyze_runlog.sh" --mode streak --reviewer kimi --streak-n 3 2>/dev/null)" "3"

# The window ages out the STREAK, keyed on its most recent attempt — not each
# attempt separately. A live streak that began more than 24h ago is still a
# live streak (antigravity, #189 pass 2).
: >"$FIXLOG"; row 1500 kimi timed_out; row 720 kimi timed_out; row 10 kimi timed_out
assert_eq "a live streak whose first timeout is outside the window still counts" "$(streak kimi)" "3"
# Other reviewers' rounds must not push a benched baseline's own attempts out
# of view: the streak is about that reviewer's history, not the fleet's.
: >"$FIXLOG"; row 60 kimi timed_out; row 55 kimi timed_out; row 50 kimi timed_out
for i in $(seq 25 -1 1); do row "$i" codex ok; done
assert_eq "25 later rounds of another reviewer do not hide a streak" "$(streak kimi)" "3"
# A success breaks a streak whatever its timestamp looks like.
: >"$FIXLOG"; row 40 kimi timed_out; row 30 kimi timed_out
printf '%s\n' '{"ts":"not-a-time","reviewers":{"kimi":{"status":"ok"}}}' >>"$FIXLOG"
row 10 kimi timed_out
assert_eq "an ok with an unparseable ts still breaks the streak" "$(streak kimi)" "0"

# Hot path: streak mode must answer from the runlog alone. The full report
# also walks wrapper ancestry with git; a git shim records any call.
: >"$FIXLOG"; row 30 kimi timed_out; row 20 kimi timed_out; row 10 kimi timed_out
printf '#!/bin/sh\necho "$@" >>"%s/git-calls"\nexit 1\n' "$T" >"$T/bin/git"; chmod +x "$T/bin/git"
jq -c '. + {wrapper_sha:"0123456789012345678901234567890123456789", wrapper_branch:"master"}' "$FIXLOG" >"$FIXLOG.tmp" && mv "$FIXLOG.tmp" "$FIXLOG"
streak kimi >/dev/null
assert_eq "streak mode answers without the full report (no git calls)" "$(cat "$T/git-calls" 2>/dev/null | wc -l | tr -d ' ')" "0"
rm -f "$T/bin/git"

echo "── detect_reviewers.sh: a hung baseline fails closed ──"
: >"$FIXLOG"; row 30 kimi timed_out; row 20 kimi timed_out; row 10 kimi timed_out
HANG_ERR="$(CROSS_REVIEW_KIMI_BASELINE=1 bash "$S/detect_reviewers.sh" 2>&1 >"$T/hang.out")"; HANG_RC=$?
assert_eq "a baseline hung 3/3 recent attempts fails detection closed" "$([[ "$HANG_RC" -ne 0 ]] && echo yes || echo no)" "yes"
assert_eq "…and the JSON reports it unavailable, not present" "$(jq -r '.kimi' "$T/hang.out")" "false"
assert_contains "…and the warning explains why (present but not completing)" "$HANG_ERR" "timed out on its last"
assert_contains "…and names the escape hatch" "$HANG_ERR" "CROSS_REVIEW_ALLOW_MISSING_BASELINE=1"

ALLOW_RC=0
CROSS_REVIEW_KIMI_BASELINE=1 CROSS_REVIEW_ALLOW_MISSING_BASELINE=1 \
  bash "$S/detect_reviewers.sh" >/dev/null 2>&1 || ALLOW_RC=$?
assert_eq "the escape hatch still lets a degraded round proceed" "$ALLOW_RC" "0"

# CONTROLS: a healthy history, and a sleep-only history, must both pass —
# proving the hang case tested the streak and nothing unconditional.
: >"$FIXLOG"; row 30 kimi ok; row 20 kimi ok; row 10 kimi ok
HEALTHY_RC=0; CROSS_REVIEW_KIMI_BASELINE=1 bash "$S/detect_reviewers.sh" >/dev/null 2>&1 || HEALTHY_RC=$?
assert_eq "control: a healthy kimi history passes detection" "$HEALTHY_RC" "0"
: >"$FIXLOG"; row 30 kimi timed_out true; row 20 kimi timed_out true; row 10 kimi timed_out true
SLEEP_RC=0; CROSS_REVIEW_KIMI_BASELINE=1 bash "$S/detect_reviewers.sh" >/dev/null 2>&1 || SLEEP_RC=$?
assert_eq "three sleep-suspect timeouts do not bench a baseline" "$SLEEP_RC" "0"

echo
echo "══ $PASS passed, $FAIL failed ══"
[[ "$FAIL" -eq 0 ]]
