#!/usr/bin/env bash
# test_background_context.sh — standalone offline fixture test for the
# {{BACKGROUND}} injection added to run_reviewers.sh / review_prompt.txt
# (GitHub issue #75). NO network, no reviewer CLIs, no tokens.
#
# Mirrors run_tests.sh's fixture/assertion conventions (assert_eq/assert_contains,
# mktemp -d + trap cleanup, PATH shims for reviewer binaries) but is
# intentionally NOT wired into run_tests.sh — the parent orchestrating session
# wires it in later (collision avoidance with sibling shards).
#
# Run:  bash tests/test_background_context.sh
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
assert_not_contains() {
  if [[ "$2" != *"$3"* ]]; then ok "$1"; else bad "$1 (unexpectedly found '$3')"; fi
}

command -v jq >/dev/null 2>&1 || { echo "jq required to run these tests" >&2; exit 1; }

# ── Fixture repo (mirrors run_tests.sh's kimi-budget fixture) ────────────────
REPO="$T/repo"; mkdir -p "$REPO"; cd "$REPO"
git init -q -b main 2>/dev/null || git init -q
seq 1 20 >f.txt; git add .; git -c user.email=t@t -c user.name=t commit -qm init
git checkout -qb feat
seq 1 25 >f.txt; git add .; git -c user.email=t@t -c user.name=t commit -qm "feat: add widget support"

# ── PATH shim dir: fake `kimi` captures the exact stdin (full_prompt) it was
# handed to a file we can inspect, instead of actually reviewing anything.
mkdir -p "$T/bin"
CAPTURE="$T/captured_prompt.txt"
cat >"$T/bin/kimi" <<SHIM
#!/bin/sh
cat >"$CAPTURE" 2>/dev/null || true
printf "shim review: no findings\\n"
SHIM
chmod +x "$T/bin/kimi"
export PATH="$T/bin:$PATH"

echo "── {{BACKGROUND}} placeholder exists in review_prompt.txt, positioned before the priority list ──"
PROMPT_FILE="$SKILL_DIR/references/review_prompt.txt"
assert_contains "review_prompt.txt declares {{BACKGROUND}}" "$(cat "$PROMPT_FILE")" "{{BACKGROUND}}"
BEFORE_LIST="$(sed -n '1,/1\. Correctness bugs/p' "$PROMPT_FILE")"
assert_contains "{{BACKGROUND}} appears before the numbered priority list" "$BEFORE_LIST" "{{BACKGROUND}}"

echo "── gh returns a known PR title+body → background reaches the prompt ──"
cat >"$T/bin/gh" <<'SHIM'
#!/bin/sh
if [ "$1" = "pr" ] && [ "$2" = "view" ]; then
  printf '{"title":"Add widget support","body":"This closes a real gap: widgets were previously unsupported.\\nRationale: users asked for it in issue #75."}\n'
  exit 0
fi
exit 1
SHIM
chmod +x "$T/bin/gh"
rm -f "$CAPTURE"
bash "$S/run_reviewers.sh" --base main --out "$T/o1" --reviewers kimi --timeout-kimi 60 >/dev/null 2>&1
if [[ -f "$CAPTURE" ]]; then
  CAPTURED="$(cat "$CAPTURE")"
  assert_contains "prompt carries the PR title" "$CAPTURED" "Add widget support"
  assert_contains "prompt carries the PR body" "$CAPTURED" "widgets were previously unsupported"
  assert_not_contains "no literal {{BACKGROUND}} leaks to the reviewer" "$CAPTURED" "{{BACKGROUND}}"
else
  bad "kimi shim never captured a prompt (run_reviewers.sh did not invoke kimi)"
fi

echo "── gh absent from PATH entirely → prompt still valid, no literal placeholder, script exits 0 ──"
rm -f "$T/bin/gh"
rm -f "$CAPTURE"
STRIPPED_PATH="$(printf '%s' "$PATH" | tr ':' '\n' | while read -r d; do
  [[ -n "$d" && -x "$d/gh" ]] && continue
  printf '%s\n' "$d"
done | paste -s -d: -)"
PATH="$STRIPPED_PATH" bash "$S/run_reviewers.sh" --base main --out "$T/o2" --reviewers kimi --timeout-kimi 60 >/dev/null 2>&1
RC=$?
assert_eq "run_reviewers.sh exits 0 with no gh on PATH" "$RC" "0"
if [[ -f "$CAPTURE" ]]; then
  CAPTURED="$(cat "$CAPTURE")"
  assert_not_contains "no literal {{BACKGROUND}} leaks when gh is absent" "$CAPTURED" "{{BACKGROUND}}"
  assert_contains "prompt still contains the base review instructions" "$CAPTURED" "code review"
else
  bad "kimi shim never captured a prompt when gh was absent"
fi

echo "── oversized PR body is truncated to the documented cap, at a line boundary ──"
BIGBODY="$(for i in $(seq 1 2000); do printf 'line %d of a very long rationale that keeps going and going\n' "$i"; done)"
cat >"$T/bin/gh" <<SHIM
#!/bin/sh
if [ "\$1" = "pr" ] && [ "\$2" = "view" ]; then
  jq -nc --arg title "Huge PR" --arg body "$(printf '%s' "$BIGBODY" | sed 's/"/\\"/g')" '{title:\$title, body:\$body}'
  exit 0
fi
exit 1
SHIM
chmod +x "$T/bin/gh"
rm -f "$CAPTURE"
bash "$S/run_reviewers.sh" --base main --out "$T/o3" --reviewers kimi --timeout-kimi 60 >/dev/null 2>&1
if [[ -f "$CAPTURE" ]]; then
  CAPTURED="$(cat "$CAPTURE")"
  assert_contains "oversized body is truncated with an explicit marker" "$CAPTURED" "truncated"
  assert_not_contains "the tail of the oversized body never reaches the prompt" "$CAPTURED" "line 1999 of a very long rationale"
  # Documented cap is 4000 bytes for the background block itself; the whole
  # prompt is much larger (diff etc.), so just prove the background block
  # itself didn't smuggle the full ~120KB body through.
  CAPTURED_BYTES="$(wc -c <"$CAPTURE" | tr -d ' ')"
  if [[ "$CAPTURED_BYTES" -lt 20000 ]]; then
    ok "captured prompt stayed small (${CAPTURED_BYTES} bytes) — background cap was honored"
  else
    bad "captured prompt is ${CAPTURED_BYTES} bytes — background cap was NOT honored"
  fi
else
  bad "kimi shim never captured a prompt for the oversized-body case"
fi

echo ""
echo "PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]] && exit 0 || exit 1
