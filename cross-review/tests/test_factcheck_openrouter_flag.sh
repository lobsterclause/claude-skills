#!/usr/bin/env bash
# Offline regression: the default-off OpenRouter flag gates every fact-check route.
set -uo pipefail

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$SKILL_DIR/scripts/factcheck_findings.sh"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin"

cat >"$T/bin/agy" <<'SH'
#!/bin/sh
# Simulate agy being installed but returning empty output.
exit 0
SH
cat >"$T/bin/curl" <<'SH'
#!/bin/sh
# Network stub: record dispatch without reading or transmitting the request body.
printf 'called\n' >>"$CURL_CALLS"
printf '%s\n' '{"choices":[{"message":{"content":"{\"drop\":[]}"}}]}'
SH
chmod +x "$T/bin/agy" "$T/bin/curl"
printf '%s\n' 'diff --git a/example.ts b/example.ts' '+const example = true;' >"$T/diff.txt"
printf '%s\n' '{"findings":[{"id":"f1","file":"example.ts","line":1,"claim":"fixture finding","snippet":"const example = true;"}]}' >"$T/findings.json"

PASS=0; FAIL=0
ok() { echo "  ok   $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL $1"; FAIL=$((FAIL + 1)); }

# run_case <reviewer> <flag-state> <expected-rc> <expected-curl-count>
run_case() {
  local reviewer="$1" flag_state="$2" want_rc="$3" want_calls="$4"
  local label="${reviewer}-${flag_state}" out="$T/$reviewer-$flag_state.json" log="$T/$reviewer-$flag_state.log" calls="$T/$reviewer-$flag_state.calls"
  rm -f "$calls" "$out" "$log"
  local rc=0
  (
    unset CROSS_REVIEW_OPENROUTER
    export PATH="$T/bin:$HOME/.local/bin:$PATH" OPENROUTER_API_KEY="offline-stub-key" CURL_CALLS="$calls"
    if [[ "$(command -v agy)" != "$T/bin/agy" || "$(command -v curl)" != "$T/bin/curl" ]]; then
      echo "factcheck test requires agy/curl PATH shims to resolve first" >&2
      exit 99
    fi
    if [[ "$flag_state" != unset ]]; then export CROSS_REVIEW_OPENROUTER="$flag_state"; fi
    bash "$SCRIPT" --findings "$T/findings.json" --out "$out" --diff "$T/diff.txt" --reviewer "$reviewer" --timeout 2
  ) >"$log" 2>&1 || rc=$?
  local calls_n=0
  [[ -f "$calls" ]] && calls_n="$(wc -l <"$calls" | tr -d '[:space:]')"
  if [[ "$rc" == "$want_rc" ]]; then ok "$label exit=$want_rc"; else bad "$label exit=$rc (wanted $want_rc)"; fi
  if [[ "$calls_n" == "$want_calls" ]]; then ok "$label curl_calls=$want_calls"; else bad "$label curl_calls=$calls_n (wanted $want_calls)"; fi
  if [[ "$want_rc" == 2 ]]; then
    if grep -q 'CROSS_REVIEW_OPENROUTER' "$log"; then ok "$label reports invalid flag"; else bad "$label missing invalid-flag diagnostic"; fi
    if [[ ! -f "$out" ]]; then ok "$label exits before producing output"; else bad "$label wrote output despite invalid flag"; fi
  fi
  if [[ "$want_calls" == 0 && -f "$out" ]]; then
    if [[ "$(jq -r '.findings[0].factcheck.verdict // empty' "$out")" == keep ]]; then ok "$label fail-safe keeps finding"; else bad "$label did not write fail-safe keep result"; fi
  fi
}

# Both the automatic agy rescue route and the explicit OpenRouter route must
# obey the same flag. The stub key is always available so the count proves the
# gate, not key absence, prevented a request.
for reviewer in agy openrouter; do
  run_case "$reviewer" unset 0 0
  run_case "$reviewer" 0 0 0
  run_case "$reviewer" 1 0 1
  run_case "$reviewer" malformed 2 0
 done
# Preserve the shared parser's documented aliases: false/off disable; true/on enable.
run_case agy off 0 0
run_case openrouter true 0 1

echo "══ $PASS passed, $FAIL failed ══"
[[ "$FAIL" -eq 0 ]]
