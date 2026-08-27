#!/usr/bin/env bash
# test_or_timeout_meta.sh — an OpenRouter lane that times out after receiving
# only whitespace keepalives must still write VALID meta.json (issue #74).
#
# Reproduces the observed shape: curl exits 28 after writing only blank
# lines to response.json (the real lanes wrote ~15KB; ~480B is enough — jq
# prints nothing on whitespace-only input whatever its size). jq on whitespace-only input prints nothing with
# rc 0, so a naive `jq ... || echo null` leaves the usage fields empty and
# the meta printf splices `"cost_usd": ,` — unparseable by every consumer.
#
# Offline: curl is a PATH shim. Run:  bash tests/test_or_timeout_meta.sh
# Exit: 0 all green, 1 any failure.

set -uo pipefail

SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
S="$SKILL_DIR/scripts"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

PASS=0; FAIL=0
ok()  { echo "  ok   $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL $1"; FAIL=$((FAIL + 1)); }
assert_eq() { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 (got: '$2' want: '$3')"; fi; }

command -v jq >/dev/null 2>&1 || { echo "jq required" >&2; exit 1; }
export OPENROUTER_API_KEY="sk-or-test-shim"
export HOME="$T/home"; mkdir -p "$HOME"
# The shim lives in the SANDBOXED $HOME/.local/bin: run_reviewers.sh prepends
# /usr/local/bin, /opt/homebrew/bin and $HOME/.local/bin (last one wins the
# front), so a shim merely at the head of the inherited PATH would be
# shadowed by a real curl in a homebrew prefix (codex, PR #79).
mkdir -p "$HOME/.local/bin"; export PATH="$HOME/.local/bin:$PATH"
# The lane's context mode is read from the environment; pin it so a caller's
# CROSS_REVIEW_CONTEXT_MODE=diff cannot fail the context_access assertion
# for an unrelated reason (kimi, PR #79).
export CROSS_REVIEW_CONTEXT_MODE=files
# This suite asserts the SINGLE-SHOT lane contract. The tool loop (default
# --tool-mode auto, 2026-08-27) is covered by tests/test_tool_loop.sh; pin it
# off here so a learned `read` arm cannot change the meta/prompt shape under
# these assertions.
export CROSS_REVIEW_TOOL_MODE=off

# curl shim: stream whitespace keepalives to stdout, then fail like a timeout.
cat >"$HOME/.local/bin/curl" <<'SHIM'
#!/bin/sh
i=0; while [ $i -lt 40 ]; do printf '         \n\n'; i=$((i+1)); done
exit 28
SHIM
chmod +x "$HOME/.local/bin/curl"

REPO="$T/repo"; mkdir -p "$REPO"
( cd "$REPO" && { git init -q -b main 2>/dev/null || { git init -q && git symbolic-ref HEAD refs/heads/main; }; }
  printf 'a\n' >f.txt && git add . && git -c user.email=t@t -c user.name=t commit -qm init
  git checkout -qb feat && printf 'a\nb\n' >f.txt && git add . && git -c user.email=t@t -c user.name=t commit -qm change )

echo "── OpenRouter lane: whitespace-only response + curl rc 28 ──"
( cd "$REPO" && bash "$S/run_reviewers.sh" --base main --out "$T/o" --reviewers glm --timeout-glm 30 >"$T/o.log" 2>&1 )
[[ -s "$T/o/glm.response.json" ]] && ok "fixture: response.json is non-empty" || bad "fixture: response.json missing/empty — shim did not run"
[[ -z "$(jq -c . "$T/o/glm.response.json" 2>/dev/null)" ]] && ok "fixture: response.json holds no JSON value (jq prints nothing)" || bad "fixture: response.json unexpectedly parses"
if jq -e . "$T/o/glm.meta.json" >/dev/null 2>&1; then ok "glm.meta.json is valid JSON"; else bad "glm.meta.json is NOT valid JSON: $(head -c 400 "$T/o/glm.meta.json")"; fi
assert_eq "cost_usd is null, not empty"          "$(jq -r '.cost_usd' "$T/o/glm.meta.json" 2>/dev/null)" "null"
assert_eq "tokens_prompt is null"                "$(jq -r '.tokens_prompt' "$T/o/glm.meta.json" 2>/dev/null)" "null"
assert_eq "tokens_completion is null"            "$(jq -r '.tokens_completion' "$T/o/glm.meta.json" 2>/dev/null)" "null"
assert_eq "the failure is still recorded (exit_code != 0)" "$(jq -r '.exit_code != 0' "$T/o/glm.meta.json" 2>/dev/null)" "true"
assert_eq "context_access still stamped"        "$(jq -r '.context_access' "$T/o/glm.meta.json" 2>/dev/null)" "file_context"

echo
echo "══ $PASS passed, $FAIL failed ══"
[[ "$FAIL" -eq 0 ]]
