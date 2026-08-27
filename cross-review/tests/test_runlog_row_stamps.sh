#!/usr/bin/env bash
# test_runlog_row_stamps.sh — offline fixture tests for per-row stamping
# added to append_runlog.sh:
#   - context_mode on every non-skipped reviewer row (#93)
#   - cost_usd_estimated / cost_estimated on rows with unbilled tokens and a
#     priced seat (#123)
#   - profile_hash on every non-skipped reviewer row (#90)
#   - worktree.sh's `started_at` and append_runlog.sh's round_wall_s "now"
#     both on the UTC clock, not local (#118)
#
# Standalone: run directly, or from run_tests.sh. NO network, NO reviewer
# CLIs, NO tokens — everything is fixture JSON under a temp dir.
#
# Run:  bash tests/test_runlog_row_stamps.sh
# Exit: 0 all green, 1 any failure.
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

# ── fixture profiles: kimi3 priced 1.00/3.00, glm priced 1.40/4.40 ──────────
cat >"$T/profiles.json" <<'EOF'
{
  "codex": { "provider": "openai", "baseline": true, "pricing": null },
  "kimi3": { "provider": "moonshot", "pricing": { "prompt_per_m": 1.00, "completion_per_m": 3.00 } },
  "glm": { "provider": "zhipu", "pricing": { "prompt_per_m": 1.40, "completion_per_m": 4.40 } }
}
EOF

RUN="$T/run1"; mkdir -p "$RUN/raw"
printf '{"exit_code":0,"duration_s":30,"timed_out":false,"output_bytes":500,"attempt":1,"timeout_budget_s":300,"cli":"codex","context_access":"agent"}\n' >"$RUN/raw/codex.meta.json"
printf '{"exit_code":0,"duration_s":40,"timed_out":false,"output_bytes":500,"attempt":1,"timeout_budget_s":950,"cli":"moonshot","context_access":"file_context","tokens_prompt":1000000,"tokens_completion":100000}\n' >"$RUN/raw/kimi3.meta.json"
printf '{"exit_code":0,"duration_s":50,"timed_out":false,"output_bytes":500,"attempt":1,"timeout_budget_s":900,"cli":"openrouter","context_access":"diff_only","cost_usd":0.02}\n' >"$RUN/raw/glm.meta.json"

LOG="$T/log.jsonl"
CROSS_REVIEW_RUNLOG="$LOG" bash "$S/append_runlog.sh" \
  --run-dir "$RUN" --project test --base main --pr - --pass 1 \
  --verdict CLEAN --convergent 0 --top "-" --profiles "$T/profiles.json" >/dev/null 2>"$T/err.txt"
ENTRY="$(tail -1 "$LOG")"

echo "── append_runlog.sh: context_mode (#93) ──"
assert_eq "codex (context_access=agent) -> tools" \
  "$(jq -r '.reviewers.codex.context_mode' <<<"$ENTRY")" "tools"
assert_eq "kimi3 (context_access=file_context) -> files" \
  "$(jq -r '.reviewers.kimi3.context_mode' <<<"$ENTRY")" "files"
assert_eq "glm (context_access=diff_only) -> diff" \
  "$(jq -r '.reviewers.glm.context_mode' <<<"$ENTRY")" "diff"

echo "── append_runlog.sh: cost_estimated (#123) ──"
assert_eq "kimi3 cost_usd_estimated == 1.3" \
  "$(jq -r '.reviewers.kimi3.cost_usd_estimated' <<<"$ENTRY")" "1.3"
assert_eq "kimi3 cost_estimated == true" \
  "$(jq -r '.reviewers.kimi3.cost_estimated' <<<"$ENTRY")" "true"
assert_eq "glm cost_estimated == false" \
  "$(jq -r '.reviewers.glm.cost_estimated' <<<"$ENTRY")" "false"
assert_eq "glm has no cost_usd_estimated key" \
  "$(jq -r '.reviewers.glm | has("cost_usd_estimated")' <<<"$ENTRY")" "false"
assert_eq "codex has no cost_estimated key (no tokens, no pricing)" \
  "$(jq -r '.reviewers.codex | has("cost_estimated")' <<<"$ENTRY")" "false"

echo "── append_runlog.sh: profile_hash (#90) ──"
for r in codex kimi3 glm; do
  h="$(jq -r ".reviewers.$r.profile_hash" <<<"$ENTRY")"
  if [[ "$h" =~ ^[0-9a-f]{12}$ ]]; then
    ok "$r has a 12-hex profile_hash (got $h)"
  else
    bad "$r has a 12-hex profile_hash (got: '$h')"
  fi
done

# profile_hash changes when the profile entry changes
cat >"$T/profiles2.json" <<'EOF'
{
  "codex": { "provider": "openai", "baseline": true, "pricing": null, "timeout_s": 999 }
}
EOF
LOG2="$T/log2.jsonl"
CROSS_REVIEW_RUNLOG="$LOG2" bash "$S/append_runlog.sh" \
  --run-dir "$RUN" --project test --base main --pr - --pass 1 \
  --verdict CLEAN --convergent 0 --top "-" --profiles "$T/profiles2.json" >/dev/null 2>&1
ENTRY2="$(tail -1 "$LOG2")"
H1="$(jq -r '.reviewers.codex.profile_hash' <<<"$ENTRY")"
H2="$(jq -r '.reviewers.codex.profile_hash' <<<"$ENTRY2")"
if [[ "$H1" != "$H2" ]]; then
  ok "profile_hash changes when the profile entry changes ($H1 != $H2)"
else
  bad "profile_hash changes when the profile entry changes (both $H1)"
fi

# a meta with neither context_access nor cli -> diff
RUN2="$T/run2"; mkdir -p "$RUN2/raw"
printf '{"exit_code":0,"duration_s":10,"timed_out":false,"output_bytes":100,"attempt":1,"timeout_budget_s":300}\n' >"$RUN2/raw/codex.meta.json"
LOG3="$T/log3.jsonl"
CROSS_REVIEW_RUNLOG="$LOG3" bash "$S/append_runlog.sh" \
  --run-dir "$RUN2" --project test --base main --pr - --pass 1 \
  --verdict CLEAN --convergent 0 --top "-" --profiles "$T/profiles.json" >/dev/null 2>&1
ENTRY3="$(tail -1 "$LOG3")"
assert_eq "no context_access, no cli -> context_mode diff" \
  "$(jq -r '.reviewers.codex.context_mode' <<<"$ENTRY3")" "diff"

# a skipped reviewer gets no row change (no context_mode/profile_hash keys)
assert_eq "skipped reviewer (kimi3, no meta) has no context_mode key" \
  "$(jq -r '.reviewers.kimi3 | has("context_mode")' <<<"$ENTRY3")" "false"
assert_eq "skipped reviewer (kimi3, no meta) has no profile_hash key" \
  "$(jq -r '.reviewers.kimi3 | has("profile_hash")' <<<"$ENTRY3")" "false"
assert_eq "skipped reviewer status stays skipped" \
  "$(jq -r '.reviewers.kimi3.status' <<<"$ENTRY3")" "skipped"

echo "── worktree.sh start: started_at is UTC (#118) ──"
GITROOT="$T/repo"
mkdir -p "$GITROOT"
(
  cd "$GITROOT" || exit 1
  git init -q
  git config user.email test@test.com
  git config user.name test
  echo hi >f.txt
  git add f.txt
  git commit -q -m init
  git branch -q -m master 2>/dev/null || true
)
WT_ROOT="$T/worktrees"
RUN_ROOT="$T/runs"
NOW_UTC_EPOCH="$(date -u +%s)"
OUT="$(cd "$GITROOT" && CROSS_REVIEW_WORKTREE_ROOT="$WT_ROOT" CROSS_REVIEW_RUN_ROOT="$RUN_ROOT" \
  bash "$S/worktree.sh" start --ref HEAD --id stamp-test --base HEAD 2>"$T/wt.err")"
STARTED_AT="$(jq -r '.started_at' <<<"$OUT")"
# jq's strptime/mktime parse as UTC regardless of OS `date` flavor or local
# TZ — the same portability trick append_runlog.sh's round_wall_s uses.
STARTED_EPOCH="$(jq -rn --arg s "$STARTED_AT" '$s | strptime("%Y%m%dT%H%M%S") | mktime')"
DIFF=$(( STARTED_EPOCH > NOW_UTC_EPOCH ? STARTED_EPOCH - NOW_UTC_EPOCH : NOW_UTC_EPOCH - STARTED_EPOCH ))
if [[ "$DIFF" -le 2 ]]; then
  ok "worktree.sh start's started_at ($STARTED_AT) is within 2s of date -u epoch (diff ${DIFF}s)"
else
  bad "worktree.sh start's started_at ($STARTED_AT) is within 2s of date -u epoch (diff ${DIFF}s, TZ=$(date +%Z))"
fi

echo "── append_runlog.sh: existing byte-identical pin still holds ──"
# Reproduce the run_tests.sh pin: two appends against the SAME run-dir,
# differing only in --run-id/--roster-decision, must agree on every other
# field (context_mode/cost_estimated/profile_hash included on both sides
# equally, since neither depends on run_id/roster_decision).
PINRUN="$T/pinrun"; mkdir -p "$PINRUN/raw"
printf '{"exit_code": 0, "duration_s": 60, "timed_out": false, "output_bytes": 500, "attempt": 1, "timeout_budget_s": 300}\n' >"$PINRUN/raw/codex.meta.json"
printf '{"exit_code": 3, "duration_s": 6, "timed_out": false, "output_bytes": 0, "attempt": 1, "timeout_budget_s": 600, "model": "Gemini 3.5 Flash (High)", "cli": "agy", "failure_kind": "quota_exhausted", "quota_resets_in": "41h"}\n' >"$PINRUN/raw/antigravity.meta.json"
PINLOG="$T/pin-runlog.jsonl"
CROSS_REVIEW_RUNLOG="$PINLOG" bash "$S/append_runlog.sh" \
  --run-dir "$PINRUN" --project test --base main --pr - --pass 1 \
  --verdict CLEAN --convergent 0 --top "-" >/dev/null 2>&1
PIN_BASELINE="$(jq -Sc 'del(.ts)' "$PINLOG")"
cat >"$T/pin-roster.json" <<'EOF'
{"roster":"codex,kimi","baselines":["codex","kimi"],"selected":[],"seed":1,"candidates":[],"policy_version":"weighted-draw-v1"}
EOF
: >"$PINLOG"
CROSS_REVIEW_RUNLOG="$PINLOG" bash "$S/append_runlog.sh" \
  --run-dir "$PINRUN" --project test --base main --pr - --pass 1 \
  --verdict CLEAN --convergent 0 --top "-" \
  --run-id pin-test-xyz --roster-decision "$T/pin-roster.json" >/dev/null 2>&1
PIN_WITH="$(tail -1 "$PINLOG")"
assert_eq "pin: omitting run-id/roster-decision still byte-matches on everything else" \
  "$PIN_BASELINE" "$(jq -Sc 'del(.ts, .run_id, .roster_decision)' <<<"$PIN_WITH")"

echo ""
echo "══ $PASS passed, $FAIL failed ══"
[[ "$FAIL" -eq 0 ]] || exit 1
