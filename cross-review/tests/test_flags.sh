#!/usr/bin/env bash
# test_flags.sh — the 2026-09-07 fleet flags, offline.
#
# NO network, NO reviewer CLIs, NO tokens: reviewer binaries are PATH shims and
# curl is a shim that returns a canned response. Same conventions as
# run_tests.sh (assert_eq/assert_contains, mktemp -d + trap), and it is picked
# up automatically by that file's tests/test_*.sh discovery.
#
# WHY THIS FILE EXISTS SEPARATELY. run_tests.sh pins the LEGACY fleet
# (CROSS_REVIEW_KIMI_BASELINE=1, CROSS_REVIEW_OPENROUTER=1) at the top, because
# its ~40 selector/pool cases were written against it. That leaves the DEFAULT
# fleet -- glm-coding as the second baseline, OpenRouter off -- untested, which
# is the wrong half to leave uncovered: the default is what every real round
# runs. Every case below therefore sets the flags it means, explicitly, and
# never inherits them.
#
# Run:  bash tests/test_flags.sh
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
refute_contains() {
  if [[ "$2" != *"$3"* ]]; then ok "$1"; else bad "$1 (unexpected '$3' in output)"; fi
}

command -v jq >/dev/null 2>&1 || { echo "jq required to run these tests" >&2; exit 1; }

# Inherited flags would defeat the whole point of this file (see the header):
# the parent suite exports the legacy fleet, and a case that forgot to set its
# own flag would silently test the parent's choice instead of its own.
unset CROSS_REVIEW_GLM_BASELINE CROSS_REVIEW_KIMI_BASELINE CROSS_REVIEW_OPENROUTER
export CROSS_REVIEW_TOOL_MODE=off

# ── PATH shims + sandbox HOME (same reasoning as run_tests.sh) ───────────────
mkdir -p "$T/bin"
printf '#!/bin/sh\ncat >/dev/null 2>&1 || true\nprintf "shim review: no findings\\n"\n' >"$T/bin/kimi"
printf '#!/bin/sh\nprintf "shim\\n"\n' >"$T/bin/codex"
printf '#!/bin/sh\nif [ "$1" = "models" ]; then printf "Gemini 3.5 Flash (High)\\nGemini 3.1 Pro (High)\\n"; fi\n' >"$T/bin/agy"
chmod +x "$T/bin/"*
export PATH="$T/bin:$PATH"
export HOME="$T/home"; mkdir -p "$HOME"
export OPENROUTER_API_KEY="sk-or-test-shim"
export ZAI_API_KEY="sk-zai-test-shim"
unset MOONSHOT_API_KEY Z_AI_API_KEY

echo "── lib_flags.sh: parsing and defaults ──"
# shellcheck source=../scripts/lib_flags.sh
. "$S/lib_flags.sh"

assert_eq "glm baseline defaults ON"  "$(cr_flag CROSS_REVIEW_GLM_BASELINE 1)"  "1"
assert_eq "kimi baseline defaults OFF" "$(cr_flag CROSS_REVIEW_KIMI_BASELINE 0)" "0"
assert_eq "openrouter defaults OFF"    "$(cr_flag CROSS_REVIEW_OPENROUTER 0)"    "0"
assert_eq "'true' parses as on"   "$(CROSS_REVIEW_OPENROUTER=true  cr_flag CROSS_REVIEW_OPENROUTER 0)" "1"
assert_eq "'OFF' parses as off"   "$(CROSS_REVIEW_GLM_BASELINE=OFF cr_flag CROSS_REVIEW_GLM_BASELINE 1)" "0"
assert_eq "'yes' parses as on"    "$(CROSS_REVIEW_OPENROUTER=yes   cr_flag CROSS_REVIEW_OPENROUTER 0)" "1"

# A typo must be LOUD. The whole value of a kill switch is that setting it does
# something; a flag that falls back to its default on 'ture' is a switch that
# silently isn't wired, which is the exact failure these flags exist to prevent.
FLAG_ERR="$(CROSS_REVIEW_OPENROUTER=ture cr_flag CROSS_REVIEW_OPENROUTER 0 2>&1 >/dev/null)"
rc=0; (CROSS_REVIEW_OPENROUTER=ture cr_flag CROSS_REVIEW_OPENROUTER 0 >/dev/null 2>&1) || rc=$?
assert_eq "a malformed flag returns 2" "$rc" "2"
assert_contains "a malformed flag explains itself" "$FLAG_ERR" "must be 1|0"

assert_eq "default baselines are codex + glm-coding" "$(cr_baseline_names)" "codex glm-coding"
assert_eq "kimi flag adds kimi as a second baseline" \
  "$(CROSS_REVIEW_KIMI_BASELINE=1 cr_baseline_names)" "codex glm-coding kimi"
assert_eq "the old fleet is one flag pair away" \
  "$(CROSS_REVIEW_GLM_BASELINE=0 CROSS_REVIEW_KIMI_BASELINE=1 cr_baseline_names)" "codex kimi"
assert_eq "flag state is stampable as JSON" \
  "$(cr_flags_json | jq -c '[.glm_baseline, .kimi_baseline, .openrouter]')" "[true,false,false]"

echo "── detect_reviewers.sh under the new defaults ──"
DET="$(bash "$S/detect_reviewers.sh" 2>"$T/det.err")"; det_rc=$?
assert_eq "detection exits 0 when the glm-coding key is present" "$det_rc" "0"
assert_eq "glm-coding reported available" "$(jq -r '."glm-coding"' <<<"$DET")" "true"
# The OpenRouter key IS present in this environment. Reporting the pool as
# available while nothing will dispatch it is exactly the detection/dispatch
# drift lib_flags.sh exists to prevent.
assert_eq "openrouter reported UNavailable despite a live key" "$(jq -r '.openrouter' <<<"$DET")" "false"
assert_eq "an OR pool seat reports unavailable too" "$(jq -r '.glm' <<<"$DET")" "false"

DET_OR="$(CROSS_REVIEW_OPENROUTER=1 bash "$S/detect_reviewers.sh" 2>/dev/null)"
assert_eq "the flag brings the pool back" "$(jq -r '.openrouter' <<<"$DET_OR")" "true"

# Moonshot rides its own key and its own bill: the OpenRouter switch must not
# take it with it. (Probed with a key present so the assertion is about the
# gate, not about the key.)
DET_MS="$(MOONSHOT_API_KEY=sk-ms-shim bash "$S/detect_reviewers.sh" 2>/dev/null)"
assert_eq "the OR switch does not disable the direct-Moonshot seats" \
  "$(jq -r '.kimi27' <<<"$DET_MS")" "true"

# Baselines still fail CLOSED — now on a missing KEY, not a missing binary.
NOKEY_ERR="$(env -u ZAI_API_KEY bash "$S/detect_reviewers.sh" 2>&1 >/dev/null)"; nokey_rc=$?
assert_eq "no glm-coding key → detection exits nonzero" "$([[ $nokey_rc -ne 0 ]] && echo yes || echo no)" "yes"
assert_contains "and says it is a key, not a PATH problem" "$NOKEY_ERR" "~/.config/zai/key"
assert_contains "and names the way back to kimi" "$NOKEY_ERR" "CROSS_REVIEW_KIMI_BASELINE=1"

echo "── select_roster.sh under the new defaults ──"
FIXLOG="$T/runlog.jsonl"; : >"$FIXLOG"
ROSTER="$(CROSS_REVIEW_RUNLOG="$FIXLOG" bash "$S/select_roster.sh" --seed 99 2>/dev/null)"
assert_contains "codex is still a baseline" "$ROSTER" "codex"
assert_contains "glm-coding is the second baseline" "$ROSTER" "glm-coding"
refute_contains "kimi is not drafted by default" ",kimi" ",$ROSTER,"
for or_seat in glm deepseek minimax qwen grok; do
  refute_contains "OR seat '$or_seat' is not drawn while the lane is off" ",$ROSTER," ",$or_seat,"
done

ROSTER_LEGACY="$(CROSS_REVIEW_GLM_BASELINE=0 CROSS_REVIEW_KIMI_BASELINE=1 CROSS_REVIEW_OPENROUTER=1 \
  CROSS_REVIEW_RUNLOG="$FIXLOG" bash "$S/select_roster.sh" --seed 99 2>/dev/null)"
assert_contains "the legacy flags restore the kimi baseline" ",$ROSTER_LEGACY," ",kimi,"
refute_contains "and drop glm-coding" ",$ROSTER_LEGACY," ",glm-coding,"

echo "── run_reviewers.sh: the glm-coding lane ──"
REPO="$T/repo"; mkdir -p "$REPO"; cd "$REPO"
git init -q -b main 2>/dev/null || git init -q
seq 1 20 >f.txt; git add .; git -c user.email=t@t -c user.name=t commit -qm init >/dev/null
git checkout -qb feat
seq 1 60 >f.txt; git add .; git -c user.email=t@t -c user.name=t commit -qm change >/dev/null

cat >"$T/canned.json" <<'EOF'
{"choices":[{"message":{"content":"## Critical\nNone.\n\n## High\nNone. Clean — no findings."}}],"usage":{"prompt_tokens":100,"completion_tokens":20}}
EOF
cat >"$T/bin/curl" <<SHIM
#!/bin/sh
cat >"$T/curl_stdin.txt"
printf '%s\n' "\$@" >"$T/curl_argv.txt"
cat "$T/canned.json"
SHIM
chmod +x "$T/bin/curl"

bash "$S/run_reviewers.sh" --base main --out "$T/o_glmc" --reviewers glm-coding >/dev/null 2>&1 || true
assert_eq "glm-coding lane writes meta" "$([[ -f "$T/o_glmc/glm-coding.meta.json" ]] && echo yes || echo no)" "yes"
assert_eq "meta records the Z.ai lane, not OpenRouter" \
  "$(jq -r '.cli' "$T/o_glmc/glm-coding.meta.json")" "zai"
assert_eq "meta records the pinned model from the profile" \
  "$(jq -r '.model' "$T/o_glmc/glm-coding.meta.json")" "glm-5.3"
assert_eq "the lane succeeded end to end" \
  "$(jq -r '.exit_code' "$T/o_glmc/glm-coding.meta.json")" "0"
# The key must be the Z.ai one and must arrive on stdin, never argv — the same
# contract the OpenRouter lane is held to (PR #18 pass 1 / the 14 leaked tokens).
assert_contains "the Z.ai key reaches curl on stdin" \
  "$(cat "$T/curl_stdin.txt" 2>/dev/null)" "Authorization: Bearer sk-zai-test-shim"
refute_contains "the Z.ai key never appears in argv" "$(cat "$T/curl_argv.txt" 2>/dev/null)" "sk-zai-test-shim"
refute_contains "the OpenRouter key is not what this lane sends" \
  "$(cat "$T/curl_stdin.txt" 2>/dev/null)" "sk-or-test-shim"
assert_contains "the endpoint is the coding-plan endpoint" \
  "$(cat "$T/curl_argv.txt" 2>/dev/null)" "api.z.ai/api/coding/paas/v4/chat/completions"
# X-Title is OpenRouter-specific attribution; other endpoints must not get it.
refute_contains "no OpenRouter X-Title header on the Z.ai lane" \
  "$(cat "$T/curl_argv.txt" 2>/dev/null)" "X-Title"

ENDPOINT_ALT="https://example.invalid/v4/chat/completions"
CROSS_REVIEW_ZAI_ENDPOINT="$ENDPOINT_ALT" \
  bash "$S/run_reviewers.sh" --base main --out "$T/o_glmc2" --reviewers glm-coding >/dev/null 2>&1 || true
assert_contains "CROSS_REVIEW_ZAI_ENDPOINT redirects the lane" \
  "$(cat "$T/curl_argv.txt" 2>/dev/null)" "$ENDPOINT_ALT"

echo "── run_reviewers.sh: the OpenRouter kill switch ──"
OR_ERR="$(bash "$S/run_reviewers.sh" --base main --out "$T/o_or" --reviewers glm 2>&1 >/dev/null || true)"
assert_contains "an explicitly requested OR seat is refused, with the reason" \
  "$OR_ERR" "CROSS_REVIEW_OPENROUTER=0"
assert_eq "and it never ran" "$([[ -f "$T/o_or/glm.meta.json" ]] && echo ran || echo skipped)" "skipped"
# CONTROL: the same request with the lane on must dispatch, or the assertion
# above would also pass on a build that simply broke the glm seat.
CROSS_REVIEW_OPENROUTER=1 bash "$S/run_reviewers.sh" --base main --out "$T/o_or2" --reviewers glm >/dev/null 2>&1 || true
assert_eq "control: the flag on dispatches the same seat" \
  "$([[ -f "$T/o_or2/glm.meta.json" ]] && echo ran || echo skipped)" "ran"

# The or_fallback rescue lane is part of the OpenRouter implementation, so the
# switch has to cover it too: a seat whose profile says or_fallback.enabled must
# NOT reach OpenRouter while the lane is off. kimi is that seat (its profile
# carries or_fallback), and the trigger has to be an ACCOUNT WALL, not any old
# failure — fallback_eligible.sh is deliberately narrow, so a shim that merely
# exits 1 would prove nothing in either direction (both arms would "stay down").
printf '#!/bin/sh\necho "insufficient balance for this account" >&2\nexit 1\n' >"$T/bin/kimi"; chmod +x "$T/bin/kimi"
bash "$S/run_reviewers.sh" --base main --out "$T/o_fb" --reviewers kimi >/dev/null 2>&1 || true
assert_eq "a failing baseline does not fall back to a disabled OpenRouter" \
  "$([[ -f "$T/o_fb/kimi.fallback.warning" ]] && echo fell-back || echo stayed-down)" "stayed-down"
CROSS_REVIEW_OPENROUTER=1 bash "$S/run_reviewers.sh" --base main --out "$T/o_fb2" --reviewers kimi >/dev/null 2>&1 || true
assert_eq "control: with the lane on it does fall back" \
  "$([[ -f "$T/o_fb2/kimi.fallback.warning" ]] && echo fell-back || echo stayed-down)" "fell-back"
rm -f "$T/bin/curl"

echo "── run_reviewers.sh: a malformed flag stops the round ──"
BAD_RC=0
CROSS_REVIEW_OPENROUTER=ture bash "$S/run_reviewers.sh" --base main --out "$T/o_bad" --reviewers glm-coding >/dev/null 2>&1 || BAD_RC=$?
assert_eq "a typo'd flag fails the run instead of defaulting" "$BAD_RC" "2"

cd "$SKILL_DIR"
echo
echo "══ $PASS passed, $FAIL failed ══"
[[ "$FAIL" -eq 0 ]]
