#!/usr/bin/env bash
# test_or_timeout_meta.sh — an OpenRouter lane that times out after receiving
# only whitespace keepalives must still write VALID meta.json (issue #74).
#
# Reproduces the observed shape: curl exits 28 after writing ~15KB of blank
# lines to response.json. jq on whitespace-only input prints nothing with
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
mkdir -p "$T/bin"; export PATH="$T/bin:$PATH"
export OPENROUTER_API_KEY="sk-or-test-shim"
export HOME="$T/home"; mkdir -p "$HOME"

# curl shim: stream whitespace keepalives to stdout, then fail like a timeout.
cat >"$T/bin/curl" <<'SHIM'
#!/bin/sh
i=0; while [ $i -lt 40 ]; do printf '         \n\n'; i=$((i+1)); done
exit 28
SHIM
chmod +x "$T/bin/curl"

REPO="$T/repo"; mkdir -p "$REPO"
( cd "$REPO" && git init -q -b main 2>/dev/null || git init -q
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
