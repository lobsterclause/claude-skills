#!/usr/bin/env bash
# test_path_guard.sh — the reviewer-CLI PATH guard must be shared, not copied.
#
# Standalone offline fixture test, same conventions as tests/test_profiles.sh
# (assert_eq/assert_contains, mktemp -d + trap) and deliberately NOT wired into
# run_tests.sh — see that file's header for the collision-avoidance reason.
#
# WHAT THIS PINS
# --------------
# detect_reviewers.sh resolved the nvm bin dir; select_roster.sh and
# run_reviewers.sh did not. So detection reported codex available while
# selection dropped it from the draw and execution could not have run it.
# Measured 2026-08-26 (kindred-mama-ai): five consecutive draws with no codex,
# while detect_reviewers.sh printed `"codex": true` and exited 0. Each round
# looked healthy -- the rotation count is silently raised to backfill a
# "missing" baseline, so you get a normal four-seat roster with no baseline in
# it.
#
# The structural case below is the one that matters long-term: it fails if a
# FOURTH copy of the guard appears, which is how this drifted in the first
# place.
#
# Run:  bash tests/test_path_guard.sh
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
assert_not_contains() { if [[ "$2" != *"$3"* ]]; then ok "$1"; else bad "$1 (must NOT contain: '$3')"; fi; }
assert_contains() {
  if [[ "$2" == *"$3"* ]]; then ok "$1"; else bad "$1 (got: '$2' want substring: '$3')"; fi
}

echo "── lib_path.sh exists and is sourced by all three entry points ──"

assert_eq "lib_path.sh exists" \
  "$([[ -f "$S/lib_path.sh" ]] && echo yes || echo no)" "yes"

# Structural: every script that decides or acts on reviewer availability must
# source the shared guard. A new inline copy is the regression.
for f in detect_reviewers.sh select_roster.sh run_reviewers.sh; do
  if grep -qE '^\s*\.\s+.*lib_path\.sh' "$S/$f"; then
    ok "$f sources lib_path.sh"
  else
    bad "$f does not source lib_path.sh"
  fi
  # No script may still carry its own nvm resolution: that is the drift.
  if grep -q 'versions/node' "$S/$f"; then
    bad "$f still has an inline nvm block (should use lib_path.sh)"
  else
    ok "$f has no inline nvm block"
  fi
done

echo "── lib_path.sh puts an nvm-installed baseline on PATH ──"

# A fake nvm tree: the binary exists, but ONLY in the nvm bin dir, exactly as a
# real `npm i -g codex` under nvm leaves it. A bare `command -v` misses it.
FAKE_NVM="$T/nvm"
mkdir -p "$FAKE_NVM/versions/node/v22.22.2/bin" "$FAKE_NVM/versions/node/v22.1.0/bin" "$FAKE_NVM/alias"
printf '22\n' >"$FAKE_NVM/alias/default"   # a bare major: must resolve to the HIGHEST v22, not the first glob hit
printf '#!/bin/sh\nprintf "shim\\n"\n' > "$FAKE_NVM/versions/node/v22.22.2/bin/faux-baseline"
chmod +x "$FAKE_NVM/versions/node/v22.22.2/bin/faux-baseline"

# Control: without the guard the binary is invisible.
BEFORE="$(env -i HOME="$T" NVM_DIR="$FAKE_NVM" PATH=/usr/bin:/bin \
  /bin/bash -c 'command -v faux-baseline >/dev/null 2>&1 && echo found || echo missing')"
assert_eq "control: nvm-only binary is invisible to a bare PATH" "$BEFORE" "missing"

AFTER="$(env -i HOME="$T" NVM_DIR="$FAKE_NVM" PATH=/usr/bin:/bin \
  /bin/bash -c '. "$1"/lib_path.sh; command -v faux-baseline >/dev/null 2>&1 && echo found || echo missing' \
  _ "$S")"
assert_eq "lib_path.sh puts the nvm bin dir on PATH" "$AFTER" "found"

# Idempotent: sourcing twice must not duplicate the entry.
DUPES="$(env -i HOME="$T" NVM_DIR="$FAKE_NVM" PATH=/usr/bin:/bin \
  /bin/bash -c '. "$1"/lib_path.sh; . "$1"/lib_path.sh; printf "%s" "$PATH" | tr ":" "\n" | grep -c "v22.22.2/bin"' \
  _ "$S")"
assert_eq "sourcing twice does not duplicate the PATH entry" "$DUPES" "1"

echo "── select_roster.sh fails closed on a missing baseline ──"

# The pool is deliberately HEALTHY here (OpenRouter key + curl), so a roster
# could legitimately be drawn if the baselines were not required. Without that,
# a run with no baselines also has no pool, exits non-zero for that unrelated
# reason, and this assertion passes whether or not the fail-closed exists --
# measured: removing `exit 1` left the suite fully green. Isolate the behaviour
# or the test cannot see it.
JQ_DIR="$(dirname "$(command -v jq)")"   # select_roster.sh needs jq; brew puts it outside /usr/bin (glm)
CTRL="$(env -i HOME="$T" NVM_DIR="$T/empty" PATH="$JQ_DIR:/usr/bin:/bin" \
  OPENROUTER_API_KEY=sk-or-test-shim CROSS_REVIEW_ALLOW_MISSING_BASELINE=1 \
  /bin/bash "$S/select_roster.sh" --seed 1 2>/dev/null)"
CTRL_RC=$?
assert_eq "control: a roster IS drawable from the pool alone" \
  "$([[ $CTRL_RC -eq 0 && -n "$CTRL" ]] && echo yes || echo no)" "yes"

# Same inputs, minus the escape hatch: the ONLY difference is the fail-closed.
OUT="$(env -i HOME="$T" NVM_DIR="$T/empty" PATH="$JQ_DIR:/usr/bin:/bin" \
  OPENROUTER_API_KEY=sk-or-test-shim \
  /bin/bash "$S/select_roster.sh" --seed 1 2>&1)"
RC=$?
assert_eq "exits non-zero when a baseline is missing" "$([[ $RC -ne 0 ]] && echo yes || echo no)" "yes"
assert_eq "emits no roster on stdout when it fails closed" \
  "$(env -i HOME="$T" NVM_DIR="$T/empty" PATH=/usr/bin:/bin OPENROUTER_API_KEY=sk-or-test-shim \
     /bin/bash "$S/select_roster.sh" --seed 1 2>/dev/null)" ""
assert_contains "names the missing baselines" "$OUT" "baseline(s) not installed"
assert_contains "explains the usual PATH cause" "$OUT" "nvm"

# The escape hatch still works, and is explicit about being used.
OUT2="$(env -i HOME="$T" NVM_DIR="$T/empty" PATH=/usr/bin:/bin \
  CROSS_REVIEW_ALLOW_MISSING_BASELINE=1 \
  /bin/bash "$S/select_roster.sh" --seed 1 2>&1)"
assert_contains "escape hatch is announced on stderr" "$OUT2" "CROSS_REVIEW_ALLOW_MISSING_BASELINE"

echo "── lib_path.sh: a bare-major alias/default resolves to the HIGHEST matching version (gemini-pro, PR #68) ──"
RESOLVED="$(env -i HOME="$T" NVM_DIR="$FAKE_NVM" PATH=/usr/bin:/bin /bin/bash -c '. "$1"; printf "%s" "$CROSS_REVIEW_NVM_BIN"' _ "$S/lib_path.sh")"
assert_eq "alias 22 → v22.22.2, not v22.1.0" "$RESOLVED" "$FAKE_NVM/versions/node/v22.22.2/bin"

echo "── run_reviewers.sh propagates the selector's fail-closed instead of substituting a fleet (codex+glm, PR #68) ──"
RR_REPO="$T/rr-repo"; mkdir -p "$RR_REPO"
( cd "$RR_REPO" && git init -q && git config user.email t@t && git config user.name t && printf 'a\n' >f && git add f && git commit -qm i && git checkout -qb feat && printf 'b\n' >>f && git commit -qam c ) >/dev/null 2>&1
RR_ERR="$T/rr.err"
( cd "$RR_REPO" && env -i HOME="$T" NVM_DIR="$T/empty" PATH="$JQ_DIR:/usr/bin:/bin" OPENROUTER_API_KEY=sk-or-test-shim \
    /bin/bash "$S/run_reviewers.sh" --base master --out "$T/rr-out" >/dev/null 2>"$RR_ERR" ); rr_rc=$?
assert_eq "missing baselines + no --reviewers → run_reviewers exits non-zero" "$(( rr_rc != 0 ))" "1"
assert_contains "…and says the selector refused, not that it was unavailable" "$(cat "$RR_ERR")" "refused the round"
assert_not_contains "…and never substitutes the fixed fleet" "$(cat "$RR_ERR")" "using fixed fallback fleet"

echo
echo "══ $PASS passed, $FAIL failed ══"
[[ $FAIL -eq 0 ]]
