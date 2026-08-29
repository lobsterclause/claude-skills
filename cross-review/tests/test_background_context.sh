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
# Build a PATH with gh genuinely absent. Dropping every gh-bearing DIRECTORY
# (what this used to do) is wrong on Linux: GitHub runners ship gh in
# /usr/bin, so the strip took git/jq/sed with it and run_reviewers.sh died
# with rc=127 before it could prove anything. It passed on macOS only because
# Homebrew gives gh its own bin dir. Mirror each gh-bearing dir into a symlink
# farm that omits gh alone, and leave every other dir untouched.
NOGH="$T/nogh"; mkdir -p "$NOGH"
STRIPPED_PATH=""
while IFS= read -r d; do
  [[ -n "$d" ]] || continue
  if [[ -x "$d/gh" ]]; then
    for f in "$d"/*; do
      [[ -e "$f" ]] || continue
      b="$(basename "$f")"
      [[ "$b" == "gh" ]] && continue
      [[ -e "$NOGH/$b" ]] || ln -s "$f" "$NOGH/$b" 2>/dev/null || true
    done
  else
    STRIPPED_PATH="${STRIPPED_PATH:+$STRIPPED_PATH:}$d"
  fi
done < <(printf '%s' "$PATH" | tr ':' '\n')
STRIPPED_PATH="${STRIPPED_PATH:+$STRIPPED_PATH:}$NOGH"
# The point of the fixture, asserted rather than assumed: gh is unreachable
# and the tools run_reviewers.sh needs are not.
if PATH="$STRIPPED_PATH" command -v gh >/dev/null 2>&1; then
  bad "fixture: gh is still reachable on the stripped PATH"
else
  ok "fixture: gh is unreachable on the stripped PATH"
fi
for _tool in git jq sed awk; do
  PATH="$STRIPPED_PATH" command -v "$_tool" >/dev/null 2>&1 \
    || bad "fixture: stripped PATH lost $_tool — the rc assertion below would be meaningless"
done
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

echo "── an '&' in the PR title/body survives substitution (bash 5.2 patsub_replacement) ──"
# Regression: `${x//pat/rep}` treats a bare `&` in the replacement as the
# MATCHED TEXT when patsub_replacement is on (bash >= 5.2, the ubuntu CI
# runner). A PR called "R&D support" then substituted {{BACKGROUND}} back
# into itself, shipping the literal placeholder to every reviewer while
# passing on macOS bash 3.2. Caught by the cross-review round on #87.
cat >"$T/bin/gh" <<'SHIM'
#!/bin/sh
if [ "$1" = "pr" ] && [ "$2" = "view" ]; then
  printf '{"title":"R&D support for widgets","body":"Adds Q&A plumbing so the widget path can answer & log."}\n'
  exit 0
fi
exit 1
SHIM
chmod +x "$T/bin/gh"
# Both context modes, deliberately: the whole-file block (--context-mode
# files, the default) happens to turn patsub_replacement off for its own
# attribute escaping, which MASKS this bug on the default path. Only the
# diff path is exposed — so a single-mode test would go green against the
# unfixed script.
for _amp_mode in files diff; do
  rm -f "$CAPTURE"
  CROSS_REVIEW_CONTEXT_MODE="$_amp_mode" \
    bash "$S/run_reviewers.sh" --base main --out "$T/o_amp_$_amp_mode" --reviewers kimi --timeout-kimi 60 >/dev/null 2>&1
  if [[ -f "$CAPTURE" ]]; then
    CAPTURED="$(cat "$CAPTURE")"
    assert_not_contains "[$_amp_mode] no literal {{BACKGROUND}} leaks when the title contains '&'" "$CAPTURED" "{{BACKGROUND}}"
    assert_contains "[$_amp_mode] the '&' in the title reaches the reviewer verbatim" "$CAPTURED" "R&D support for widgets"
    assert_contains "[$_amp_mode] the '&' in the body reaches the reviewer verbatim" "$CAPTURED" "answer & log"
  else
    bad "[$_amp_mode] kimi shim never captured a prompt for the '&' case"
  fi
done

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
