#!/usr/bin/env bash
# test_snapshot.sh — standalone fixture tests for `--snapshot-dir` on
# run_reviewers.sh (closes SKILL.md step 2.5's tracked future-work: a flag
# that auto-injects per-reviewer repomix-handoff snapshots instead of the
# raw diff).
#
# NOT wired into run_tests.sh directly — invoked via a minimal one-line hook
# appended to run_tests.sh (a sibling shard edits that file this round too;
# keeping this file standalone avoids a merge collision, same pattern as
# test_digest.sh).
#
# Offline, no network, no real reviewer CLIs: kimi/agy/curl are PATH shims,
# git repos are created in a temp dir.
#
# Run:  bash tests/test_snapshot.sh          (from the skill root or anywhere)
# Exit: 0 all green, 1 any failure.
#
# Portability: macOS bash 3.2 + ubuntu bash 5; needs jq, git, and a coreutils
# timeout (gtimeout on macOS via brew).

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

[[ -x "$S/run_reviewers.sh" ]] || { echo "FATAL: $S/run_reviewers.sh missing or not executable"; exit 1; }

# ── PATH shims: fake reviewer binaries so this runs hermetically. ───────────
mkdir -p "$T/bin"
export PATH="$T/bin:$PATH"
export OPENROUTER_API_KEY="sk-or-test-shim"   # lights the OR pool (glm); never called for real
# Sandbox HOME: run_reviewers.sh writes the agy shell-gate config under
# $HOME/.gemini and reads key files under $HOME/.config — never touch the
# real HOME from a test (same isolation run_tests.sh uses).
export HOME="$T/home"
mkdir -p "$HOME"

# kimi shim: capture the piped prompt (stdin) verbatim to $1, then answer
# with a short, unambiguous clean verdict so run_reviewers.sh's no_verdict/
# degenerate classifiers leave it alone.
write_kimi_shim() {
  local capture="$1"
  cat >"$T/bin/kimi" <<SHIM
#!/bin/sh
cat > "$capture"
printf '## Critical\nNone.\n\n## High\nNone. Clean - no findings.\n'
SHIM
  chmod +x "$T/bin/kimi"
}

# agy shim: capture the argv value that follows -p (the full prompt) to $1.
# Also answers `agy models` so any incidental probe doesn't hang the test.
write_agy_shim() {
  local capture="$1"
  cat >"$T/bin/agy" <<SHIM
#!/bin/sh
if [ "\$1" = "models" ]; then
  printf 'Gemini 3.5 Flash (High)\nGemini 3.1 Pro (High)\n'
  exit 0
fi
prev=""
for a in "\$@"; do
  if [ "\$prev" = "-p" ]; then printf '%s' "\$a" > "$capture"; fi
  prev="\$a"
done
printf '## Critical\nNone.\n\n## High\nNone. Clean - no findings.\n'
SHIM
  chmod +x "$T/bin/agy"
}

# curl shim: always returns a canned successful chat-completion so
# run_openrouter_reviewer (glm) parses a response without error. What we
# actually assert on is the REQUEST body run_reviewers.sh writes to
# $out/glm.request.json *before* invoking curl — no need to capture curl's
# own invocation.
cat >"$T/canned_or_response.json" <<'EOF'
{"choices":[{"message":{"content":"## Critical\nNone.\n\n## High\nNone. Clean - no findings."}}],"usage":{"prompt_tokens":10,"completion_tokens":5,"cost":0.001}}
EOF
cat >"$T/bin/curl" <<SHIM
#!/bin/sh
cat "$T/canned_or_response.json"
SHIM
chmod +x "$T/bin/curl"

# ── Fixture repo: base "main" -> feature branch "feat" with a unique diff ───
REPO="$T/repo"; mkdir -p "$REPO"
(
  cd "$REPO" || exit 1
  git init -q -b main 2>/dev/null || git init -q
  printf 'line one\nline two\n' >f.txt
  git add .
  git -c user.email=t@t -c user.name=t commit -qm init
  git checkout -qb feat
  printf 'line one\nRAW_DIFF_ONLY_MARKER_7f3a91\nline two\n' >f.txt
  git add .
  git -c user.email=t@t -c user.name=t commit -qm change
)

SNAP="$T/snap"; mkdir -p "$SNAP"
printf 'SNAPSHOT_ONLY_MARKER_kimi_c9e21\nPre-built code context snapshot standing in for the diff.\n' \
  >"$SNAP/snapshot-kimi.md"
printf 'SNAPSHOT_ONLY_MARKER_antigravity_ab114\nPre-built code context snapshot standing in for the diff.\n' \
  >"$SNAP/snapshot-antigravity.md"
# Deliberately NO snapshot-glm.* file — glm has no matching snapshot and must
# fall back to the raw diff.

echo "── --snapshot-dir: matching reviewer gets the snapshot INSTEAD of the raw diff ──"
write_kimi_shim "$T/kimi_stdin_with_flag.txt"
write_agy_shim  "$T/agy_prompt_with_flag.txt"
(
  cd "$REPO" || exit 1
  bash "$S/run_reviewers.sh" --base main --out "$T/o1" \
    --reviewers kimi,antigravity,glm --snapshot-dir "$SNAP" \
    --timeout-kimi 30 --timeout-antigravity 30 --timeout-glm 30 \
    >"$T/o1.log" 2>&1
)
KIMI_PROMPT="$(cat "$T/kimi_stdin_with_flag.txt" 2>/dev/null || echo MISSING_CAPTURE)"
AGY_PROMPT="$(cat "$T/agy_prompt_with_flag.txt" 2>/dev/null || echo MISSING_CAPTURE)"
GLM_REQUEST="$(jq -r '.messages[0].content // "MISSING_CAPTURE"' "$T/o1/glm.request.json" 2>/dev/null || echo MISSING_CAPTURE)"

assert_contains "kimi prompt carries its snapshot marker" \
  "$KIMI_PROMPT" "SNAPSHOT_ONLY_MARKER_kimi_c9e21"
assert_not_contains "kimi prompt drops the raw diff it replaced" \
  "$KIMI_PROMPT" "RAW_DIFF_ONLY_MARKER_7f3a91"
assert_contains "kimi snapshot uses the same <tag> fencing style as the raw diff (<snapshot> mirrors <diff>)" \
  "$KIMI_PROMPT" "<snapshot>"

assert_contains "antigravity (agy) prompt carries its snapshot marker" \
  "$AGY_PROMPT" "SNAPSHOT_ONLY_MARKER_antigravity_ab114"
assert_not_contains "antigravity prompt drops the raw diff it replaced" \
  "$AGY_PROMPT" "RAW_DIFF_ONLY_MARKER_7f3a91"

assert_contains "glm (no matching snapshot file) still receives the raw diff — fallback works" \
  "$GLM_REQUEST" "RAW_DIFF_ONLY_MARKER_7f3a91"
assert_not_contains "glm prompt picks up no stray snapshot marker" \
  "$GLM_REQUEST" "SNAPSHOT_ONLY_MARKER"

echo "── without --snapshot-dir: prompts are unchanged (raw diff everywhere, no snapshot content) ──"
write_kimi_shim "$T/kimi_stdin_no_flag.txt"
(
  cd "$REPO" || exit 1
  bash "$S/run_reviewers.sh" --base main --out "$T/o2" \
    --reviewers kimi,glm --timeout-kimi 30 --timeout-glm 30 \
    >"$T/o2.log" 2>&1
)
KIMI_PROMPT_NOFLAG="$(cat "$T/kimi_stdin_no_flag.txt" 2>/dev/null || echo MISSING_CAPTURE)"
GLM_REQUEST_NOFLAG="$(jq -r '.messages[0].content // "MISSING_CAPTURE"' "$T/o2/glm.request.json" 2>/dev/null || echo MISSING_CAPTURE)"

assert_contains "kimi (no flag) still gets the raw diff" \
  "$KIMI_PROMPT_NOFLAG" "RAW_DIFF_ONLY_MARKER_7f3a91"
assert_not_contains "kimi (no flag) never sees any snapshot marker" \
  "$KIMI_PROMPT_NOFLAG" "SNAPSHOT_ONLY_MARKER"
assert_contains "glm (no flag) still gets the raw diff" \
  "$GLM_REQUEST_NOFLAG" "RAW_DIFF_ONLY_MARKER_7f3a91"
assert_not_contains "glm (no flag) never sees any snapshot marker" \
  "$GLM_REQUEST_NOFLAG" "SNAPSHOT_ONLY_MARKER"

echo
echo "══ $PASS passed, $FAIL failed ══"
[[ "$FAIL" -eq 0 ]]
