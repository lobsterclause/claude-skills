#!/usr/bin/env bash
# test_tool_policy.sh — fixture tests for scripts/tool_policy.sh, the per-seat
# tool-arm learner. Every decision must be reproducible from a ledger, so
# each case writes a small runlog (+ events) and asserts the arm and basis.
#
# Run:  bash tests/test_tool_policy.sh
# Exit: 0 all green, 1 any failure.

set -uo pipefail
# run_tests.sh pins CROSS_REVIEW_TOOL_MODE=off for the single-shot suites; this
# suite exercises the learner, so the inherited pin must not leak in.
unset CROSS_REVIEW_TOOL_MODE

SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
S="$SKILL_DIR/scripts"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

PASS=0; FAIL=0
ok()  { echo "  ok   $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL $1"; FAIL=$((FAIL + 1)); }
assert_eq() { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 (got: '$2' want: '$3')"; fi; }

command -v jq >/dev/null 2>&1 || { echo "jq required" >&2; exit 1; }

# A minimal profile: two chat-lane seats, one pinned; learner constants explicit
# so the assertions do not drift with the production profile.
PROF="$T/profiles.json"
cat >"$PROF" <<'EOF'
{
  "_synthesis_rules": {
    "tool_policy": {
      "default_mode": "read", "arms": ["off", "read", "check"],
      "ucb_c": 0.5, "min_samples": 3, "cost_lambda": 2.0, "window": 40,
      "optimistic_prior": 0.75, "demote_reliability_below": 0.5, "max_steps": 8
    }
  },
  "glm":    { "cli": "openrouter", "provider": "zhipu" },
  "qwen":   { "cli": "openrouter", "provider": "alibaba", "tools": { "mode": "off", "max_steps": 3 } },
  "kimi3":  { "cli": "moonshot",   "provider": "moonshot" },
  "codex":  { "cli": null,         "provider": "openai" }
}
EOF
export CROSS_REVIEW_PROFILES_FILE="$PROF"
export CROSS_REVIEW_RUNLOG="$T/runlog.jsonl"
export CROSS_REVIEW_FINDING_EVENTS="$T/events.jsonl"
NOCHECK="$T/nocheck"; mkdir -p "$NOCHECK"
WITHCHECK="$T/withcheck/.claude"; mkdir -p "$WITHCHECK"; printf 'true\n' >"$WITHCHECK/verify.sh"

# run_entry <run_id> <reviewer> <status> <cli> <arm|-> <cost> <findings_total|null> <dropped> [extra json fields]
# A failed row is only arm evidence when the model answered (tokens_prompt
# set) — pass ',"tokens_prompt":N' for those; a bare failed row with no
# tokens and no output is the provider-outage shape and is excluded.
run_entry() {
  local ts='{"status":"'"$3"'","cli":"'"$4"'","cost_usd":'"$6"',"findings_total":'"$7"',"findings_dropped":'"$8"${9:-}
  if [[ "$5" != "-" ]]; then ts="$ts"',"tool_stats":{"mode":"'"$5"'"}'; fi
  ts="$ts}"
  printf '{"run_id":"%s","reviewers":{"%s":%s}}\n' "$1" "$2" "$ts" >>"$CROSS_REVIEW_RUNLOG"
}
reset() { : >"$CROSS_REVIEW_RUNLOG"; : >"$CROSS_REVIEW_FINDING_EVENTS"; }
decide() { bash "$S/tool_policy.sh" --reviewer "$1" --repo-root "${2:-$NOCHECK}" 2>"$T/err"; }

echo "── no ledger data → default_mode ──"
reset
D="$(decide glm)"
assert_eq "mode=read" "$(jq -r .mode <<<"$D")" "read"
assert_eq "basis=default" "$(jq -r .basis <<<"$D")" "default"
assert_eq "check arm absent without an entrypoint" "$(jq -r '.arms | has("check")' <<<"$D")" "false"
assert_eq "window_runs=0" "$(jq -r .window_runs <<<"$D")" "0"

echo "── precedence: override > pin > learned ──"
D="$(CROSS_REVIEW_TOOL_MODE=off decide glm)"
assert_eq "override wins" "$(jq -r '[.mode,.basis] | join("/")' <<<"$D")" "off/override"
D="$(decide qwen)"
assert_eq "pinned seat uses its pin" "$(jq -r '[.mode,.basis] | join("/")' <<<"$D")" "off/pinned"
assert_eq "pinned max_steps surfaces" "$(jq -r .max_steps <<<"$D")" "3"
D="$(CROSS_REVIEW_TOOL_MODE=read decide qwen)"
assert_eq "override beats the pin" "$(jq -r '[.mode,.basis] | join("/")' <<<"$D")" "read/override"
D="$(decide glm)"
assert_eq "unpinned seat has no max_steps override (env/profile default applies)" "$(jq -r '.max_steps' <<<"$D")" "null"

echo "── check availability ──"
D="$(decide glm "$T/withcheck")"
assert_eq "check arm present with .claude/verify.sh" "$(jq -r '.arms | has("check")' <<<"$D")" "true"
assert_eq "check_available=true" "$(jq -r .check_available <<<"$D")" "true"
D="$(CROSS_REVIEW_TOOL_MODE=check decide glm)"
assert_eq "requested check without entrypoint → read" "$(jq -r .mode <<<"$D")" "read"
assert_eq "…basis explains" "$(jq -r .basis <<<"$D")" "override:no_check_entrypoint"
D="$(CROSS_REVIEW_TOOL_MODE=check decide glm "$T/withcheck")"
assert_eq "requested check with entrypoint honoured" "$(jq -r '[.mode,.basis] | join("/")' <<<"$D")" "check/override"

echo "── learned: historical single-shot rows are the off arm ──"
reset
# Five pre-feature rows (no tool_stats) with mediocre precision: off mean well
# below the optimistic prior for the untried read arm.
for i in 1 2 3 4 5; do run_entry "r$i" glm ok openrouter - 0.01 4 2; done
D="$(decide glm)"
assert_eq "rows without tool_stats count as off" "$(jq -r .arms.off.n <<<"$D")" "5"
assert_eq "read untried" "$(jq -r .arms.read.n <<<"$D")" "0"
assert_eq "off mean = 0.6*0.5 + 0.4 - 2*0.01 = 0.68" "$(jq -r .arms.off.mean <<<"$D")" "0.68"
assert_eq "learned → read (untried arm explores)" "$(jq -r '[.mode,.basis] | join("/")' <<<"$D")" "read/learned"

echo "── learned: a strong off arm beats a weak read arm ──"
reset
for i in 1 2 3 4 5 6; do run_entry "o$i" glm ok openrouter off 0.001 5 0; done       # r_q 1.0 → reward 0.998
for i in 1 2 3 4 5 6; do run_entry "t$i" glm ok openrouter read 0.02 4 3; done       # r_q 0.25 → reward 0.51
D="$(decide glm)"
assert_eq "off mean ≈ 0.998" "$(jq -r .arms.off.mean <<<"$D")" "0.998"
assert_eq "read mean = 0.6*0.25 + 0.4 - 0.04 = 0.51" "$(jq -r .arms.read.mean <<<"$D")" "0.51"
assert_eq "learned → off" "$(jq -r '[.mode,.basis] | join("/")' <<<"$D")" "off/learned"

echo "── learned: a strong read arm beats off ──"
reset
for i in 1 2 3 4 5 6; do run_entry "o$i" glm ok openrouter off 0.01 4 3; done
for i in 1 2 3 4 5 6; do run_entry "t$i" glm ok openrouter read 0.01 4 0; done
D="$(decide glm)"
assert_eq "learned → read" "$(jq -r .mode <<<"$D")" "read"

echo "── demotion: an arm that breaks the model is taken out ──"
reset
for i in 1 2 3; do run_entry "t$i" glm failed openrouter read 0 null 0 ',"tokens_prompt":800,"output_bytes":40'; done   # answered, then broke: 0/3 delivered
for i in 1 2 3; do run_entry "o$i" glm ok openrouter off 0.05 4 3; done              # weak but reliable
D="$(decide glm)"
assert_eq "read reliability 0" "$(jq -r .arms.read.reliability <<<"$D")" "0"
assert_eq "read demoted (eligible=false)" "$(jq -r .arms.read.eligible <<<"$D")" "false"
assert_eq "read ucb=-1" "$(jq -r .arms.read.ucb <<<"$D")" "-1"
assert_eq "learned → off despite read's failures being 'cheap'" "$(jq -r .mode <<<"$D")" "off"
reset
for i in 1 2; do run_entry "t$i" glm failed openrouter read 0 null 0 ',"tokens_prompt":800'; done   # below min_samples
D="$(decide glm)"
assert_eq "2 failures < min_samples: not demoted yet" "$(jq -r .arms.read.eligible <<<"$D")" "true"

echo "── only chat-lane runs are samples ──"
reset
run_entry a1 codex ok null - 0.05 3 0              # first-party codex: not an off-arm sample
run_entry a2 codex fallback openrouter - 0.02 2 0  # its OpenRouter fallback: is one
D="$(decide codex)"
assert_eq "one sample (the fallback run)" "$(jq -r .window_runs <<<"$D")" "1"
assert_eq "fallback counts as delivered" "$(jq -r .arms.off.ok <<<"$D")" "1"
reset
run_entry m1 kimi3 ok moonshot read 0 3 0
D="$(decide kimi3)"
assert_eq "moonshot cli rows count" "$(jq -r .arms.read.n <<<"$D")" "1"

echo "── provider outages are not arm evidence ──"
reset
# Three classified 402s on the read arm: pre-fix this demoted read (n>=3, rel 0).
for i in 1 2 3; do printf '{"run_id":"b%d","reviewers":{"glm":{"status":"failed","cli":"openrouter","cost_usd":null,"findings_total":null,"findings_dropped":0,"failure_kind":"provider_billing","tokens_prompt":null,"output_bytes":0,"tool_stats":{"mode":"read","steps":0}}}}\n' "$i" >>"$CROSS_REVIEW_RUNLOG"; done
run_entry o1 glm ok openrouter off 0.01 4 2
D="$(decide glm)"
assert_eq "billing rows excluded (excluded_runs=3)" "$(jq -r .excluded_runs <<<"$D")" "3"
assert_eq "…read arm still untried" "$(jq -r .arms.read.n <<<"$D")" "0"
assert_eq "…read stays eligible" "$(jq -r .arms.read.eligible <<<"$D")" "true"
assert_eq "…window_runs counts only judged runs" "$(jq -r .window_runs <<<"$D")" "1"
reset
# Pre-classification rows (failure_kind null) with the outage shape: no tokens, no output.
for i in 1 2 3; do printf '{"run_id":"l%d","reviewers":{"glm":{"status":"failed","cli":"openrouter","cost_usd":null,"findings_total":null,"findings_dropped":0,"failure_kind":null,"tokens_prompt":null,"output_bytes":0,"tool_stats":{"mode":"read","steps":0}}}}\n' "$i" >>"$CROSS_REVIEW_RUNLOG"; done
D="$(decide glm)"
assert_eq "legacy unclassified outage rows excluded" "$(jq -r .excluded_runs <<<"$D")" "3"
assert_eq "…read not demoted" "$(jq -r .arms.read.eligible <<<"$D")" "true"
reset
# A generic provider_error (e.g. tools rejected on this route) IS arm evidence.
for i in 1 2 3; do printf '{"run_id":"p%d","reviewers":{"glm":{"status":"failed","cli":"openrouter","cost_usd":null,"findings_total":null,"findings_dropped":0,"failure_kind":"provider_error","tokens_prompt":null,"output_bytes":0,"tool_stats":{"mode":"read","steps":0}}}}\n' "$i" >>"$CROSS_REVIEW_RUNLOG"; done
D="$(decide glm)"
assert_eq "provider_error rows are samples" "$(jq -r .arms.read.n <<<"$D")" "3"
assert_eq "…and demote read" "$(jq -r .arms.read.eligible <<<"$D")" "false"
assert_eq "…excluded_runs=0" "$(jq -r .excluded_runs <<<"$D")" "0"
reset
# quota_exhausted (the agy classification) on a fallback-to-OpenRouter row is likewise excluded;
# a failed row WITH tokens (the model answered, then broke) is a sample.
printf '{"run_id":"q1","reviewers":{"glm":{"status":"failed","cli":"openrouter","cost_usd":0,"findings_total":null,"findings_dropped":0,"failure_kind":"quota_exhausted","tokens_prompt":null,"output_bytes":0}}}\n' >>"$CROSS_REVIEW_RUNLOG"
printf '{"run_id":"q2","reviewers":{"glm":{"status":"failed","cli":"openrouter","cost_usd":0.01,"findings_total":null,"findings_dropped":0,"failure_kind":null,"tokens_prompt":900,"output_bytes":0,"tool_stats":{"mode":"read","steps":2}}}}\n' >>"$CROSS_REVIEW_RUNLOG"
D="$(decide glm)"
assert_eq "quota_exhausted excluded, answered-then-failed kept" "$(jq -r '[.excluded_runs, .arms.read.n] | join("/")' <<<"$D")" "1/1"

echo "── unanchored findings cost half a finding each ──"
reset
run_entry u1 glm ok openrouter read 0 4 0
printf '{"event":"anchored","resolved":false,"run_id":"u1","sources":["glm"]}\n{"event":"anchored","resolved":false,"run_id":"u1","sources":["kimi"]}\n{"event":"anchored","resolved":true,"run_id":"u1","sources":["glm"]}\n' >"$CROSS_REVIEW_FINDING_EVENTS"
D="$(decide glm)"
# r_q = (4 - 0 - 0.5*1)/4 = 0.875 → reward 0.6*0.875 + 0.4 = 0.925
assert_eq "one unanchored event for glm on u1 → mean 0.925" "$(jq -r .arms.read.mean <<<"$D")" "0.925"

echo "── window: only the last N structured rows count ──"
reset
for i in $(seq 1 45); do run_entry "w$i" glm ok openrouter off 0 2 0; done
for i in 1 2; do run_entry "x$i" glm ok openrouter read 0 2 0; done
D="$(decide glm)"
assert_eq "47 rows, window 40 → 40 samples" "$(jq -r .window_runs <<<"$D")" "40"

echo "── determinism & --all ──"
reset
for i in 1 2 3; do run_entry "d$i" glm ok openrouter off 0.01 4 1; done
A="$(decide glm)"; B="$(decide glm)"
assert_eq "same ledger → same decision" "$A" "$B"
ALL="$(bash "$S/tool_policy.sh" --all --repo-root "$NOCHECK" 2>/dev/null)"
assert_eq "--all lists the three chat-lane seats, not codex" "$(jq -r .reviewer <<<"$ALL" | sort | tr '\n' ',')" "glm,kimi3,qwen,"
TBL="$(bash "$S/tool_policy.sh" --reviewer glm --repo-root "$NOCHECK" --mode table 2>/dev/null)"
[[ "$TBL" == *"glm: mode="*"off "*"n=3"* ]] && ok "--mode table renders the arm rows" || bad "--mode table output unexpected: $TBL"

echo "── argument hygiene ──"
bash "$S/tool_policy.sh" >/dev/null 2>&1; assert_eq "no --reviewer → exit 2" "$?" "2"
CROSS_REVIEW_TOOL_MODE=bogus bash "$S/tool_policy.sh" --reviewer glm >/dev/null 2>&1; assert_eq "bogus override → exit 2" "$?" "2"
# The live ledger is megabytes: it must go to jq as a file, never argv.
reset
for i in $(seq 1 400); do printf '{"run_id":"big%d","reviewers":{"glm":{"status":"ok","cli":"openrouter","cost_usd":0,"findings_total":1,"findings_dropped":0,"pad":"%s"}}}\n' "$i" "$(head -c 4000 /dev/zero | tr '\0' x)" >>"$CROSS_REVIEW_RUNLOG"; done
D="$(decide glm)"; rc=$?
assert_eq "1.6MB runlog decides cleanly (no argv limit)" "$rc" "0"
assert_eq "…window applied" "$(jq -r .window_runs <<<"$D")" "40"

echo
echo "══ $PASS passed, $FAIL failed ══"
[[ $FAIL -eq 0 ]]
