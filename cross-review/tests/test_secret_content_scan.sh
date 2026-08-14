#!/usr/bin/env bash
# test_secret_content_scan.sh — standalone offline fixture test for
# scripts/worktree.sh's content-based secret scan. NO network, no reviewer
# CLIs, no tokens.
#
# Mirrors run_tests.sh's fixture/assertion conventions (assert_eq/assert_contains,
# mktemp -d + trap cleanup, real git repos under $T) but is intentionally NOT
# wired into run_tests.sh — the parent orchestrating session wires it in later
# (collision avoidance; see tests/test_digest.sh / tests/test_profiles.sh for
# the same pattern).
#
# Why this exists: worktree.sh's secret_pattern only matched CHANGED FILE
# PATHS (.env, .pem, credentials, id_rsa, ...). A hardcoded API key literal
# embedded in an innocuously-named file (e.g. config.ts) sailed through
# undetected, and the full diff then shipped unredacted to 15+ third-party
# reviewer APIs before anyone got a consent prompt. This asserts the new
# content-based scan catches secret-shaped literals regardless of filename.
#
# Run:  bash tests/test_secret_content_scan.sh
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
[[ -f "$S/worktree.sh" ]] || { echo "FATAL: $S/worktree.sh missing"; exit 1; }

WTROOT="$T/wtroot"; RUNROOT="$T/runroot"; mkdir -p "$WTROOT" "$RUNROOT"

# ── fixture repo: an innocuously-named file (config.ts) whose CONTENT carries
# a secret-shaped literal. The old filename-only secret_pattern would never
# flag config.ts — this is exactly the gap this shard closes.
REPO="$T/repo"; mkdir -p "$REPO"
( cd "$REPO"
  git init -q -b main 2>/dev/null || git init -q
  printf 'export const APP_NAME = "demo";\n' >config.ts
  git add .
  git -c user.email=t@t -c user.name=t commit -qm init
  git checkout -qb feat
  printf 'export const APP_NAME = "demo";\nconst apiKey = "sk-abcdEFGH12345678901234";\n' >config.ts
  git add .
  git -c user.email=t@t -c user.name=t commit -qm 'add key' )

echo "── content scan flags a secret-shaped literal in an innocuous filename (config.ts) ──"
OUT="$( cd "$REPO" && CROSS_REVIEW_WORKTREE_ROOT="$WTROOT" CROSS_REVIEW_RUN_ROOT="$RUNROOT" \
  bash "$S/worktree.sh" start --ref HEAD --id content-secret --base main 2>/dev/null )"
assert_eq "warn_secrets=true for sk-... literal in config.ts content" \
  "$(jq -r '.warn_secrets' <<<"$OUT")" "true"
assert_contains "risky_files names config.ts even though its filename doesn't match secret_pattern" \
  "$(jq -r '.risky_files' <<<"$OUT")" "config.ts"
CROSS_REVIEW_WORKTREE_ROOT="$WTROOT" bash "$S/worktree.sh" end \
  --worktree "$(jq -r '.worktree' <<<"$OUT")" >/dev/null 2>&1 || true

# ── control: an AWS-style AKIA literal in an innocuous filename also trips it.
REPO2="$T/repo2"; mkdir -p "$REPO2"
( cd "$REPO2"
  git init -q -b main 2>/dev/null || git init -q
  printf 'export const APP_NAME = "demo";\n' >constants.ts
  git add .
  git -c user.email=t@t -c user.name=t commit -qm init
  git checkout -qb feat
  printf 'export const APP_NAME = "demo";\nconst awsKey = "AKIAABCDEFGHIJKLMNOP";\n' >constants.ts
  git add .
  git -c user.email=t@t -c user.name=t commit -qm 'add aws key' )

echo "── content scan flags an AKIA-shaped literal in constants.ts ──"
OUT2="$( cd "$REPO2" && CROSS_REVIEW_WORKTREE_ROOT="$WTROOT" CROSS_REVIEW_RUN_ROOT="$RUNROOT" \
  bash "$S/worktree.sh" start --ref HEAD --id content-aws --base main 2>/dev/null )"
assert_eq "warn_secrets=true for AKIA... literal in constants.ts content" \
  "$(jq -r '.warn_secrets' <<<"$OUT2")" "true"
assert_contains "risky_files names constants.ts" \
  "$(jq -r '.risky_files' <<<"$OUT2")" "constants.ts"
CROSS_REVIEW_WORKTREE_ROOT="$WTROOT" bash "$S/worktree.sh" end \
  --worktree "$(jq -r '.worktree' <<<"$OUT2")" >/dev/null 2>&1 || true

# ── negative control: ordinary content changes in an ordinary file must NOT
# trip warn_secrets — the existing false-positive-tolerant design still needs
# to not cry wolf on every diff.
REPO3="$T/repo3"; mkdir -p "$REPO3"
( cd "$REPO3"
  git init -q -b main 2>/dev/null || git init -q
  printf 'export function add(a, b) { return a + b; }\n' >math.ts
  git add .
  git -c user.email=t@t -c user.name=t commit -qm init
  git checkout -qb feat
  printf 'export function add(a, b) { return a + b + 0; }\n' >math.ts
  git add .
  git -c user.email=t@t -c user.name=t commit -qm 'tweak' )

echo "── ordinary content change does not trip warn_secrets ──"
OUT3="$( cd "$REPO3" && CROSS_REVIEW_WORKTREE_ROOT="$WTROOT" CROSS_REVIEW_RUN_ROOT="$RUNROOT" \
  bash "$S/worktree.sh" start --ref HEAD --id content-clean --base main 2>/dev/null )"
assert_eq "warn_secrets=false for an ordinary diff" \
  "$(jq -r '.warn_secrets' <<<"$OUT3")" "false"
CROSS_REVIEW_WORKTREE_ROOT="$WTROOT" bash "$S/worktree.sh" end \
  --worktree "$(jq -r '.worktree' <<<"$OUT3")" >/dev/null 2>&1 || true

echo
echo "══ $PASS passed, $FAIL failed ══"
[[ "$FAIL" -eq 0 ]]
