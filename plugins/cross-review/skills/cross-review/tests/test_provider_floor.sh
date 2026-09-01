#!/usr/bin/env bash
# test_provider_floor.sh — the round must be able to tell it was too thin to
# be a cross-review, and must not be able to report a healthy verdict when it was.
#
# SKILL.md has always said a round needs >=3 reviewers and >=3 providers.
# Nothing checked either until 2026-09-01, when a census of the previous 25
# rounds found PR #3677 graded CLEAN on two returning seats and PR #173
# reporting NEEDS_DECISION on ONE, after both billing rails went dry mid-day.
#
# Offline: no network, no reviewer CLIs. Fixtures only.
# Run:  bash tests/test_provider_floor.sh     Exit: 0 all green, 1 any failure.

set -uo pipefail

SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
S="$SKILL_DIR/scripts"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

PASS=0; FAIL=0
ok()  { echo "  ok   $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL $1"; FAIL=$((FAIL + 1)); }
assert_eq()       { if [[ "$2" == "$3" ]];   then ok "$1"; else bad "$1 (got: '$2' want: '$3')"; fi; }
assert_contains() { if [[ "$2" == *"$3"* ]]; then ok "$1"; else bad "$1 (no '$3' in output)"; fi; }

profiles="$SKILL_DIR/references/reviewer_profiles.json"

# meta <dir> <seat> <bytes>
meta() { mkdir -p "$1"; printf '{"output_bytes": %s, "exit_code": 0}\n' "$3" > "$1/$2.meta.json"; }

echo "── provider floor: counting ──"

# 3 distinct providers (openai, moonshot, zhipu) -> floor met
raw="$T/raw_ok"
meta "$raw" codex 1000; meta "$raw" kimi 900; meta "$raw" glm 800
out="$(bash "$S/check_provider_floor.sh" --meta-dir "$raw" --profiles "$profiles" --json 2>/dev/null)"; rc=$?
assert_eq "3 distinct providers meets the floor (rc)" "$rc" "0"
assert_eq "3 distinct providers counted" "$(printf '%s' "$out" | jq -r .providers_returned)" "3"

# 3 seats, ONE provider: kimi+kimi27+kimi3 are three seats and one brain.
raw="$T/raw_moonshot"
meta "$raw" kimi 900; meta "$raw" kimi27 900; meta "$raw" kimi3 900
out="$(bash "$S/check_provider_floor.sh" --meta-dir "$raw" --profiles "$profiles" --json 2>/dev/null)"; rc=$?
assert_eq "3 Moonshot seats are ONE provider (rc=3)" "$rc" "3"
assert_eq "3 Moonshot seats count as 1 provider" "$(printf '%s' "$out" | jq -r .providers_returned)" "1"

# A seat that produced no bytes did not return, however healthy it looks.
raw="$T/raw_empty"
meta "$raw" codex 1000; meta "$raw" kimi 0; meta "$raw" glm 0
out="$(bash "$S/check_provider_floor.sh" --meta-dir "$raw" --profiles "$profiles" --json 2>/dev/null)"
assert_eq "zero-byte seats are not counted" "$(printf '%s' "$out" | jq -r .providers_returned)" "1"

# Non-seat artifacts must never be counted. `<seat>.primary-failed.meta.json`
# is the PRESERVED first-party failure a fallback replaced; counting it turned
# a 1-provider round into a 2-provider one during development, which is an
# UNDER-strict floor — the only direction that matters.
raw="$T/raw_artifacts"
meta "$raw" codex 1000
printf '{"output_bytes": 340}\n' > "$raw/kimi.primary-failed.meta.json"
printf '{"output_bytes": 91}\n'  > "$raw/context.files.meta.json"
printf '{"output_bytes": 500}\n' > "$raw/gemini-pro.attempt1.meta.json"
out="$(bash "$S/check_provider_floor.sh" --meta-dir "$raw" --profiles "$profiles" --json 2>/dev/null)"
assert_eq "primary-failed / attempt / context artifacts are not seats" \
  "$(printf '%s' "$out" | jq -r .providers_returned)" "1"

# Fail open: no evidence is not a violation.
out="$(bash "$S/check_provider_floor.sh" --meta-dir "$T/does-not-exist" --json 2>/dev/null)"; rc=$?
assert_eq "missing meta dir fails OPEN (rc)" "$rc" "0"
assert_eq "missing meta dir reports meets_floor" "$(printf '%s' "$out" | jq -r .meets_floor)" "true"

# --floor is honourable both ways.
raw="$T/raw_one"; meta "$raw" codex 1000
out="$(bash "$S/check_provider_floor.sh" --meta-dir "$raw" --profiles "$profiles" --floor 1 --json 2>/dev/null)"; rc=$?
assert_eq "--floor 1 accepts a solo round" "$rc" "0"

echo "── provider floor: it BINDS the verdict ──"

echo '{"findings":[]}' > "$T/f.json"
raw="$T/raw_thin"; meta "$raw" codex 1000

blk="$(bash "$S/report_block.sh" --findings "$T/f.json" --pass 1 --verdict CLEAN \
        --record /tmp/r.md --next stop --meta-dir "$raw" --profiles "$profiles" 2>/dev/null)"
assert_contains "a CLEAN verdict on a thin round is overridden" "$blk" "Verdict: BLOCKED"
assert_contains "the override says why"                         "$blk" "INVALID ROUND"
assert_contains "and redirects Next to the human"               "$blk" "Next:    ask-user"

blk="$(bash "$S/report_block.sh" --findings "$T/f.json" --pass 1 --verdict CLEAN \
        --record /tmp/r.md --next stop --profiles "$profiles" 2>/dev/null)"
assert_contains "WITHOUT --meta-dir the verdict is untouched (back-compat)" "$blk" "Verdict: CLEAN"

raw="$T/raw_fat"
meta "$raw" codex 1000; meta "$raw" kimi 900; meta "$raw" glm 800
blk="$(bash "$S/report_block.sh" --findings "$T/f.json" --pass 1 --verdict CLEAN \
        --record /tmp/r.md --next stop --meta-dir "$raw" --profiles "$profiles" 2>/dev/null)"
assert_contains "a healthy round keeps its verdict" "$blk" "Verdict: CLEAN"

echo "── OpenRouter balance probe (offline, seeded cache) ──"

# run_tests.sh exports CROSS_REVIEW_SKIP_BALANCE_PROBE=1 to keep the suite
# offline, and that export reaches standalone test files too. These cases are
# the probe's own tests, so they must opt back IN explicitly — they stay
# offline via the seeded cache below, never the network. Without this the file
# passes standalone and fails inside the harness, which is the worst shape a
# test can have.
export CROSS_REVIEW_SKIP_BALANCE_PROBE=0

# The probe reads a cached /api/v1/credits body. Seeding the cache exercises
# the decision without any network, and pins the arithmetic that matters:
# exhausted means usage >= credits.
export HOME="$T/home"; mkdir -p "$HOME/.cross-review/cache" "$HOME/.config/openrouter"
echo "sk-or-test" > "$HOME/.config/openrouter/key"
cache="$HOME/.cross-review/cache/openrouter_credits.json"

printf '{"data":{"total_credits":4377.1984,"total_usage":4377.3073}}\n' > "$cache"
out="$(CROSS_REVIEW_ALLOW_MISSING_BASELINE=1 bash "$S/detect_reviewers.sh" 2>"$T/err.txt")"
assert_eq "exhausted balance benches the OpenRouter pool" "$(printf '%s' "$out" | jq -r .openrouter)" "false"
assert_eq "…and every pool seat with it"                  "$(printf '%s' "$out" | jq -r .qwen)"       "false"
assert_contains "…loudly, with the remedy" "$(cat "$T/err.txt")" "openrouter.ai/settings/credits"

printf '{"data":{"total_credits":100.0,"total_usage":12.5}}\n' > "$cache"
out="$(CROSS_REVIEW_ALLOW_MISSING_BASELINE=1 bash "$S/detect_reviewers.sh" 2>/dev/null)"
assert_eq "a funded balance leaves the pool available" "$(printf '%s' "$out" | jq -r .openrouter)" "true"

# Fail open: a garbage/partial cache must never bench fifteen reviewers.
printf '{"data":{}}\n' > "$cache"
out="$(CROSS_REVIEW_ALLOW_MISSING_BASELINE=1 bash "$S/detect_reviewers.sh" 2>/dev/null)"
assert_eq "unparseable balance fails OPEN" "$(printf '%s' "$out" | jq -r .openrouter)" "true"

printf '{"data":{"total_credits":4377.1984,"total_usage":4377.3073}}\n' > "$cache"
out="$(CROSS_REVIEW_SKIP_BALANCE_PROBE=1 CROSS_REVIEW_ALLOW_MISSING_BASELINE=1 bash "$S/detect_reviewers.sh" 2>/dev/null)"
assert_eq "CROSS_REVIEW_SKIP_BALANCE_PROBE=1 disables the probe" "$(printf '%s' "$out" | jq -r .openrouter)" "true"

echo
echo "══ $PASS passed, $FAIL failed ══"
[[ "$FAIL" -eq 0 ]]
