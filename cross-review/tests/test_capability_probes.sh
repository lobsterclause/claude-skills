#!/usr/bin/env bash
# test_capability_probes.sh — #3587: detect_reviewers.sh must fail closed on a
# broken-but-PRESENT account (OpenRouter balance too thin for a seat's
# declared max_tokens) and on a broken-but-PRESENT baseline CLI (a reviewer
# that hangs every call rather than erroring). Offline: curl and bash are
# shimmed, no network, no real keys. Same conventions as test_flags.sh
# (assert_eq/assert_contains, mktemp -d + trap, PATH shims, sandbox HOME) and
# picked up automatically by run_tests.sh's tests/test_*.sh discovery.
#
# Run:  bash tests/test_capability_probes.sh
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

command -v jq >/dev/null 2>&1 || { echo "jq required to run these tests" >&2; exit 1; }

# Same isolation discipline as test_flags.sh: explicit flags, sandbox HOME,
# PATH shims — nothing inherited from the environment this happens to run in.
unset CROSS_REVIEW_GLM_BASELINE CROSS_REVIEW_KIMI_BASELINE CROSS_REVIEW_OPENROUTER
export CROSS_REVIEW_TOOL_MODE=off

mkdir -p "$T/bin"
printf '#!/bin/sh\nprintf "shim\\n"\n' >"$T/bin/codex"
printf '#!/bin/sh\ncat >/dev/null 2>&1 || true\nprintf "shim review: no findings\\n"\n' >"$T/bin/kimi"
printf '#!/bin/sh\nif [ "$1" = "models" ]; then printf "Gemini 3.5 Flash (High)\\nGemini 3.1 Pro (High)\\n"; fi\n' >"$T/bin/agy"
chmod +x "$T/bin/"*
export PATH="$T/bin:$PATH"
export HOME="$T/home"; mkdir -p "$HOME"
export ZAI_API_KEY="sk-zai-test-shim"
export CROSS_REVIEW_OPENROUTER=1
export OPENROUTER_API_KEY="sk-or-test-shim"
unset MOONSHOT_API_KEY Z_AI_API_KEY

# A minimal fixture profiles file, isolated from the live one so this test
# can pin exact pricing/max_tokens_reserve values instead of asserting
# against numbers that may be re-tuned later.
cat >"$T/profiles.json" <<'EOF'
{
  "codex": { "baseline": true },
  "glm-coding": { "baseline": true },
  "glm": { "provider": "zhipu", "cli": "openrouter", "pricing": { "prompt_per_m": 1.0, "completion_per_m": 4.0 }, "max_tokens_reserve": 65536 },
  "deepseek": { "provider": "deepseek", "cli": "openrouter", "pricing": null }
}
EOF
export CROSS_REVIEW_PROFILES_FILE="$T/profiles.json"

echo "── OpenRouter balance probe (#3587 case 1) ──"

# `timeout -k 3 10 curl ...` — the real `timeout` binary passes its trailing
# argv straight through to curl. This shim does the same so detect_reviewers'
# `"$OR_TIMEOUT_BIN" -k 3 10 curl ...` invocation reaches the curl shim below.
cat >"$T/bin/timeout" <<'SHIM'
#!/bin/sh
# drop leading option flags/values (-k 3 10) down to the real command
while [ $# -gt 0 ]; do
  case "$1" in
    -k) shift 2 ;;
    [0-9]*) shift ;;
    *) break ;;
  esac
done
exec "$@"
SHIM
chmod +x "$T/bin/timeout"

# Case A: thin balance ($0.001 left) cannot cover glm's 65536-token reserve
# at $4.00/M completion (~$0.26 needed) — glm must be downgraded, the rest of
# the pool (deepseek, which has no pricing on file) must NOT be touched.
cat >"$T/bin/curl" <<'SHIM'
#!/bin/sh
printf '{"data":{"total_credits": 5.0, "total_usage": 4.999}}\n'
SHIM
chmod +x "$T/bin/curl"
POOR_ERR="$(bash "$S/detect_reviewers.sh" 2>&1 >"$T/poor.out")"
POOR_OUT="$(cat "$T/poor.out")"
assert_eq "thin balance: glm downgraded to unavailable" "$(jq -r '.glm' <<<"$POOR_OUT")" "false"
assert_eq "thin balance: deepseek (no pricing on file) is untouched by the probe" \
  "$(jq -r '.deepseek' <<<"$POOR_OUT")" "true"
assert_contains "thin balance: warning names the seat" "$POOR_ERR" "OpenRouter seat \"glm\""
assert_contains "thin balance: warning states the actual balance" "$POOR_ERR" "0.001"

# CONTROL: a healthy balance must NOT downgrade glm — proves case A tested
# the balance logic and not some unconditional downgrade.
cat >"$T/bin/curl" <<'SHIM'
#!/bin/sh
printf '{"data":{"total_credits": 500.0, "total_usage": 1.0}}\n'
SHIM
chmod +x "$T/bin/curl"
RICH_OUT="$(bash "$S/detect_reviewers.sh" 2>/dev/null)"
assert_eq "control: healthy balance leaves glm available" "$(jq -r '.glm' <<<"$RICH_OUT")" "true"

# Case B: GET /api/v1/key shape (limit: null, no derivable balance) must NOT
# be mistaken for a usable response — the issue's own point that this
# endpoint reads an exhausted account as healthy. Fails safe: no override.
cat >"$T/bin/curl" <<'SHIM'
#!/bin/sh
printf '{"data":{"label":"test","limit":null,"usage":4.999}}\n'
SHIM
chmod +x "$T/bin/curl"
KEYSHAPE_OUT="$(bash "$S/detect_reviewers.sh" 2>/dev/null)"
assert_eq "an /api/v1/key-shaped response cannot be parsed as a balance — fails safe, no downgrade" \
  "$(jq -r '.glm' <<<"$KEYSHAPE_OUT")" "true"

# Case C: fail-safe on a broken probe (curl errors / empty output) — every
# seat stays at its presence-checked value, no crash, exit 0.
cat >"$T/bin/curl" <<'SHIM'
#!/bin/sh
exit 7
SHIM
chmod +x "$T/bin/curl"
BROKEN_OUT="$(bash "$S/detect_reviewers.sh" 2>/dev/null)"; broken_rc=$?
assert_eq "a failed balance probe does not crash detection" "$broken_rc" "0"
assert_eq "…and does not downgrade the seat it could not check" "$(jq -r '.glm' <<<"$BROKEN_OUT")" "true"

echo "── baseline hang-streak (#3587 case 2) ──"

FIXLOG="$T/runlog.jsonl"
{
  echo '{"reviewers":{"kimi":{"status":"timed_out"}}}'
  echo '{"reviewers":{"kimi":{"status":"timed_out"}}}'
  echo '{"reviewers":{"kimi":{"status":"timed_out"}}}'
} >"$FIXLOG"
export CROSS_REVIEW_RUNLOG="$FIXLOG"

STREAK_OUT="$(bash "$S/analyze_runlog.sh" --mode streak --reviewer kimi --streak-n 3)"
assert_eq "analyze_runlog streak mode counts 3 consecutive timeouts" "$STREAK_OUT" "3"

STREAK_ZERO="$(bash "$S/analyze_runlog.sh" --mode streak --reviewer codex --streak-n 3)"
assert_eq "a reviewer with no runlog rows streaks 0, not an error" "$STREAK_ZERO" "0"

{
  echo '{"reviewers":{"kimi":{"status":"timed_out"}}}'
  echo '{"reviewers":{"kimi":{"status":"timed_out"}}}'
  echo '{"reviewers":{"kimi":{"status":"ok"}}}'
} >"$FIXLOG"
STREAK_BROKEN="$(bash "$S/analyze_runlog.sh" --mode streak --reviewer kimi --streak-n 3)"
assert_eq "a streak broken by a recent success reads 0" "$STREAK_BROKEN" "0"

# Now feed detect_reviewers.sh the 3-timeouts-in-a-row fixture with
# CROSS_REVIEW_KIMI_BASELINE=1 so kimi is an active baseline — it must be
# reported unavailable and the fail-closed exit must fire, exactly as if
# the CLI were simply missing (the issue's core ask: broken-and-present
# must read the same as absent).
{
  echo '{"reviewers":{"kimi":{"status":"timed_out"}}}'
  echo '{"reviewers":{"kimi":{"status":"timed_out"}}}'
  echo '{"reviewers":{"kimi":{"status":"timed_out"}}}'
} >"$FIXLOG"
cat >"$T/bin/curl" <<'SHIM'
#!/bin/sh
printf '{"data":{"total_credits": 500.0, "total_usage": 1.0}}\n'
SHIM
chmod +x "$T/bin/curl"

HANG_ERR="$(CROSS_REVIEW_KIMI_BASELINE=1 bash "$S/detect_reviewers.sh" 2>&1 >"$T/hang.out")"
HANG_RC=0; CROSS_REVIEW_KIMI_BASELINE=1 bash "$S/detect_reviewers.sh" >/dev/null 2>&1 || HANG_RC=$?
assert_eq "a baseline hung 3/3 recent attempts fails detection closed" "$([[ "$HANG_RC" -ne 0 ]] && echo yes || echo no)" "yes"
assert_eq "…and the JSON reports it unavailable, not present" "$(jq -r '.kimi' <<<"$(cat "$T/hang.out")")" "false"
assert_contains "…and the warning explains why (present but not completing)" "$HANG_ERR" "timed out on its last"
assert_contains "…and names the escape hatch" "$HANG_ERR" "CROSS_REVIEW_ALLOW_MISSING_BASELINE=1"

ALLOW_RC=0
CROSS_REVIEW_KIMI_BASELINE=1 CROSS_REVIEW_ALLOW_MISSING_BASELINE=1 \
  bash "$S/detect_reviewers.sh" >/dev/null 2>&1 || ALLOW_RC=$?
assert_eq "the escape hatch still lets a degraded round proceed" "$ALLOW_RC" "0"

# CONTROL: a healthy runlog (no consecutive-timeout streak) must not trip
# this check — proves the hang case tested the streak logic, not some
# unconditional kimi-baseline failure.
{
  echo '{"reviewers":{"kimi":{"status":"ok"}}}'
  echo '{"reviewers":{"kimi":{"status":"ok"}}}'
  echo '{"reviewers":{"kimi":{"status":"ok"}}}'
} >"$FIXLOG"
HEALTHY_RC=0
CROSS_REVIEW_KIMI_BASELINE=1 bash "$S/detect_reviewers.sh" >/dev/null 2>&1 || HEALTHY_RC=$?
assert_eq "control: a healthy kimi history passes detection" "$HEALTHY_RC" "0"

echo
echo "══ $PASS passed, $FAIL failed ══"
[[ "$FAIL" -eq 0 ]]
