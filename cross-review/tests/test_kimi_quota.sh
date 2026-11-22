#!/usr/bin/env bash
# test_kimi_quota.sh — kimi's 429 usage wall is stamped quota_exhausted, not failure_kind null.
# Offline: kimi is a PATH shim.
set -uo pipefail
S="$(cd "$(dirname "${BASH_SOURCE[0]}")/../scripts" && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
export CROSS_REVIEW_STATE_DIR="$T/state"
PASS=0; FAIL=0
ok()  { echo "  ok   $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL $1"; FAIL=$((FAIL + 1)); }
assert_eq() { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 (got: '$2' want: '$3')"; fi; }
command -v jq >/dev/null 2>&1 || { echo "jq required" >&2; exit 1; }
mkdir -p "$T/bin" "$T/home" "$T/nvm"; export HOME="$T/home"
export NVM_DIR="$T/nvm"  # an inherited NVM tree would put a real kimi ahead of the shim
export PATH="$T/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
export CROSS_REVIEW_TOOL_MODE=off
unset OPENROUTER_API_KEY; export XDG_CONFIG_HOME="$T/xdg"
REPO="$T/repo"; mkdir -p "$REPO"
( cd "$REPO" && { git init -q -b master 2>/dev/null || git init -q; } && git config user.email t@t && git config user.name t
  printf 'a\n' >f.txt && git add -A && git commit -qm init && git checkout -qb feat
  printf 'a\nb\n' >f.txt && git commit -qam change ) >/dev/null 2>&1
kimi_shim() {  # kimi_shim <rc> <stdout> <stderr>
  { printf '#!/bin/sh\ncat >/dev/null 2>&1 || true\n'
    [[ -n "$2" ]] && printf 'printf "%%s\\n" %q\n' "$2"
    [[ -n "$3" ]] && printf 'printf "%%s\\n" %q >&2\n' "$3"
    printf 'exit %s\n' "$1"; } >"$T/bin/kimi"; chmod +x "$T/bin/kimi"
}
run() { ( cd "$REPO" && bash "$S/run_reviewers.sh" --base master --out "$1" --reviewers kimi >"$1.log" 2>&1 ); }
fk() { jq -r '.failure_kind' "$1/kimi.meta.json"; }

kimi_shim 1 "" 'Error code: 429 - {"error": {"type": "exceeded_current_quota_error", "message": "usage limit"}}'
run "$T/o1"
assert_eq "error type on stderr -> quota_exhausted" "$(fk "$T/o1")" "quota_exhausted"
[[ -f "$T/o1/kimi.quota_exhausted" ]] && ok "sentinel written" || bad "sentinel missing"
if grep -q "attempt 1 failed" "$T/o1.log"; then bad "retried a quota wall"; else ok "no retry on quota wall"; fi

kimi_shim 1 "" 'HTTP 429 Too Many Requests'
run "$T/o2"
assert_eq "plain HTTP 429 is a transient throttle, not quota" "$(jq -r '.failure_kind == "quota_exhausted"' "$T/o2/kimi.meta.json")" "false"
[[ -f "$T/o2/kimi.quota_exhausted" ]] && bad "sentinel written for a plain 429" || ok "no sentinel for a plain 429"

# Marker first, then far more diagnostics than a pipe buffer holds.
cat >"$T/bin/kimi" <<'SHIM'
#!/bin/sh
cat >/dev/null 2>&1 || true
echo '{"type": "exceeded_current_quota_error"}' >&2
yes diagnostic-line-padding | head -n 200000 >&2
exit 1
SHIM
chmod +x "$T/bin/kimi"
run "$T/o5"
assert_eq "marker before large output -> quota_exhausted" "$(fk "$T/o5")" "quota_exhausted"

kimi_shim 1 '{"error": {"type": "exceeded_current_quota_error"}}' ""
run "$T/o3"
assert_eq "error type on stdout -> quota_exhausted" "$(fk "$T/o3")" "quota_exhausted"

# A partial review that merely mentions the token, then a transient 429.
kimi_shim 1 '- [P2] handle exceeded_current_quota_error in the retry loop' 'HTTP 429 Too Many Requests'
run "$T/o6"
assert_eq "token quoted in a review is not quota" "$(jq -r '.failure_kind == "quota_exhausted"' "$T/o6/kimi.meta.json")" "false"
if grep -q "attempt 1 failed" "$T/o6.log"; then ok "transient failure retried"; else bad "transient failure not retried"; fi

kimi_shim 1 "" 'some other crash'
run "$T/o4"
assert_eq "unrelated failure is not quota" "$(jq -r '.failure_kind == "quota_exhausted"' "$T/o4/kimi.meta.json")" "false"

echo "kimi quota: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
