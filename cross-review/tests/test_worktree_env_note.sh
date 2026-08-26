#!/usr/bin/env bash
# test_worktree_env_note.sh — reviewers must be told when deps are not installed.
#
# Standalone offline fixture test (same conventions as tests/test_profiles.sh,
# deliberately not wired into run_tests.sh). No network: `curl` is a shim that
# returns a canned OpenRouter response, and the prompt is read back out of the
# request payload run_reviewers.sh writes.
#
# WHAT THIS PINS
# --------------
# A review worktree is a `git worktree add` checkout with no install step, so a
# JS repo in it has no node_modules. Agentic reviewers don't know that and try
# to run the suite — a reasonable instinct that cannot be satisfied here.
#
# Measured 2026-08-26 (kindred-mama-ai #3582, a two-file test diff): codex spent
# its whole 600s budget chasing an unresolvable module, produced 194KB of
# transcript and ZERO verdict markers, and that round lost both baselines. The
# retry at 1500s answered in 694s, most of it the same dead end.
#
# The control case matters as much as the positive one: the note must NOT be
# emitted when node_modules is present, or the skill starts telling reviewers
# something false about their environment.
#
# Run:  bash tests/test_worktree_env_note.sh
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
assert_contains() {
  if [[ "$2" == *"$3"* ]]; then ok "$1"; else bad "$1 (want substring: '$3')"; fi
}
# The "a prompt was captured" guards are load-bearing: assert_not_contains on an
# empty or null string passes vacuously, so a broken fixture would read as
# "the note is correctly absent". Anchor on text from the real prompt file.
assert_not_contains() {
  if [[ "$2" != *"$3"* ]]; then ok "$1"; else bad "$1 (must NOT contain: '$3')"; fi
}

mkdir -p "$T/bin" "$T/home"
export HOME="$T/home"
export OPENROUTER_API_KEY="sk-or-test-shim"
cat >"$T/canned.json" <<'JSON'
{"choices":[{"message":{"content":"No findings."}}],"usage":{"prompt_tokens":1,"completion_tokens":1,"cost":0}}
JSON
cat >"$T/bin/curl" <<SHIM
#!/bin/sh
cat "$T/canned.json"
SHIM
chmod +x "$T/bin/curl"
export PATH="$T/bin:$PATH"

# ── fixture repo: a JS project with a real diff ──────────────────────────────
REPO="$T/repo"; mkdir -p "$REPO"; cd "$REPO" || exit 1
git init -q -b main 2>/dev/null || git init -q
printf '{"name":"fixture","version":"1.0.0"}\n' >package.json
printf 'one\n' >f.txt
git add .; git -c user.email=t@t -c user.name=t commit -qm init
git checkout -qb feat
printf 'one\ntwo\n' >f.txt
git add .; git -c user.email=t@t -c user.name=t commit -qm change

NOTE="ENVIRONMENT: this is a bare git worktree"

echo "── deps absent: reviewers are told not to run the suite ──"
bash "$S/run_reviewers.sh" --base main --out "$T/no_deps" --reviewers glm >/dev/null 2>&1 || true
PROMPT_NO="$(jq -r '.messages[0].content' "$T/no_deps/glm.request.json" 2>/dev/null)"
assert_contains "a prompt was actually captured" "$PROMPT_NO" "code review of the changes"
assert_contains "prompt carries the no-deps environment note" "$PROMPT_NO" "$NOTE"
assert_contains "prompt says not to run tests" "$PROMPT_NO" "Do not run tests"

echo "── deps present: the note must be absent (no false claims) ──"
mkdir -p "$REPO/node_modules"
bash "$S/run_reviewers.sh" --base main --out "$T/with_deps" --reviewers glm >/dev/null 2>&1 || true
PROMPT_YES="$(jq -r '.messages[0].content' "$T/with_deps/glm.request.json" 2>/dev/null)"
assert_contains "control: a prompt was captured here too" "$PROMPT_YES" "code review of the changes"
assert_not_contains "no environment note when node_modules exists" "$PROMPT_YES" "$NOTE"
rmdir "$REPO/node_modules"

echo "── a non-JS repo never gets the note ──"
REPO2="$T/repo2"; mkdir -p "$REPO2"; cd "$REPO2" || exit 1
git init -q -b main 2>/dev/null || git init -q
printf 'one\n' >f.txt
git add .; git -c user.email=t@t -c user.name=t commit -qm init
git checkout -qb feat
printf 'one\ntwo\n' >f.txt
git add .; git -c user.email=t@t -c user.name=t commit -qm change
bash "$S/run_reviewers.sh" --base main --out "$T/no_pkg" --reviewers glm >/dev/null 2>&1 || true
PROMPT_NP="$(jq -r '.messages[0].content' "$T/no_pkg/glm.request.json" 2>/dev/null)"
assert_contains "control: prompt captured for the non-JS repo" "$PROMPT_NP" "code review of the changes"
assert_not_contains "no environment note without package.json" "$PROMPT_NP" "$NOTE"

echo
echo "══ $PASS passed, $FAIL failed ══"
[[ $FAIL -eq 0 ]]
