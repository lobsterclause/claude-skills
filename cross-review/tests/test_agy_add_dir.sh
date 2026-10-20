#!/usr/bin/env bash
# test_agy_add_dir.sh — an agy lap in a LINKED worktree can read its own git
# metadata. Offline: agy is a PATH shim that records its argv.
#
# Why this exists: every review runs in a linked worktree, whose `.git` is a
# one-line pointer to <repo>/.git/worktrees/<name>/. With the shell gated to
# `echo`, a model that wants to know what HEAD is reads that pointer and then
# follows it — out of the --add-dir workspace — and headless agy auto-denies
# the read_file and kills the whole lap at 0 bytes (failure_kind
# headless_permission_denied; #185 pass 1, reproduced against agy 1.4.2).
# Adding the worktree's private gitdir to the workspace is the narrow fix: a
# global read_file rule would have to cover every repo's .git, i.e. the whole
# projects tree.
#
# Run:  bash tests/test_agy_add_dir.sh   ·   Exit: 0 all green, 1 any failure.
set -uo pipefail
S="$(cd "$(dirname "${BASH_SOURCE[0]}")/../scripts" && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
PASS=0; FAIL=0
ok()  { echo "  ok   $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL $1"; FAIL=$((FAIL + 1)); }
assert_eq() { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 (got: '$2' want: '$3')"; fi; }

command -v jq >/dev/null 2>&1 || { echo "jq required" >&2; exit 1; }
mkdir -p "$T/bin" "$T/home"; export HOME="$T/home"
cat >"$T/bin/agy" <<'SHIM'
#!/bin/sh
if [ "$1" = "models" ]; then printf "Gemini 3.8 Flash (High)\nGemini 3.1 Pro (High)\n"; exit 0; fi
for a in "$@"; do printf '%s\n' "$a"; done >"$AGY_ARGV"
printf "shim review: no findings\n"
SHIM
chmod +x "$T/bin/agy"
export PATH="$T/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
export CROSS_REVIEW_TOOL_MODE=off
unset OPENROUTER_API_KEY; export XDG_CONFIG_HOME="$T/xdg"

REPO="$T/repo"; mkdir -p "$REPO"
( cd "$REPO" && { git init -q -b master 2>/dev/null || git init -q; } && git config user.email t@t && git config user.name t
  printf 'a\n' >f.txt && git add -A && git commit -qm init && git checkout -qb feat
  printf 'a\nb\n' >f.txt && git commit -qam change
  git worktree add -q --detach "$T/wt" feat ) >/dev/null 2>&1

# The --add-dir values agy was given, one per line, physical paths.
add_dirs() {
  awk 'p { print; p=0 } $0 == "--add-dir" { p=1 }' "$1" | while IFS= read -r d; do
    (cd "$d" 2>/dev/null && pwd -P) || printf 'MISSING:%s\n' "$d"
  done
}
run() {  # run <dir> <argv-file>
  ( cd "$1" && AGY_ARGV="$2" bash "$S/run_reviewers.sh" --base master --out "$2.out" \
      --reviewers antigravity >"$2.log" 2>&1 )
}

echo "── agy add-dir in a linked worktree ──"
run "$T/wt" "$T/argv-wt"
[[ -s "$T/argv-wt" ]] && ok "the agy shim was invoked" || bad "agy never ran: $(tail -3 "$T/argv-wt.log")"
WT_P="$(cd "$T/wt" && pwd -P)"
GD_P="$(cd "$(git -C "$T/wt" rev-parse --absolute-git-dir)" && pwd -P)"
dirs="$(add_dirs "$T/argv-wt")"
grep -qxF "$WT_P" <<<"$dirs" && ok "the worktree root is in the workspace" || bad "worktree root missing: $dirs"
grep -qxF "$GD_P" <<<"$dirs" && ok "the worktree's own gitdir is in the workspace" || bad "gitdir missing: $dirs"
# Narrow, not the whole repository: the common .git (objects, every other
# worktree's metadata) and the main checkout stay outside.
REPO_P="$(cd "$REPO" && pwd -P)"
! grep -qxF "$REPO_P/.git" <<<"$dirs" && ! grep -qxF "$REPO_P" <<<"$dirs" \
  && ok "the main checkout and its common .git are not added" || bad "added too much: $dirs"

echo "── agy add-dir in an ordinary checkout ──"
run "$REPO" "$T/argv-main"
assert_eq "an ordinary checkout gets only its root (its .git is already inside)" \
  "$(add_dirs "$T/argv-main")" "$REPO_P"

echo
echo "══ $PASS passed, $FAIL failed ══"
[[ "$FAIL" -eq 0 ]]
