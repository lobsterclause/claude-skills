#!/usr/bin/env bash
# test_codex_quota.sh — codex usage-limit exhaustion is stamped, not a bare rc=1.
# Offline: codex is a PATH shim. Pins PR #61: failure_kind "quota_exhausted",
# a codex.quota_exhausted sentinel carrying the reset ETA, and rc=0-with-wall
# still classified as failed (rc 3).
set -uo pipefail
S="$(cd "$(dirname "${BASH_SOURCE[0]}")/../scripts" && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
PASS=0; FAIL=0
ok()  { echo "  ok   $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL $1"; FAIL=$((FAIL + 1)); }
assert_eq() { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 (got: '$2' want: '$3')"; fi; }
assert_contains() { if [[ "$2" == *"$3"* ]]; then ok "$1"; else bad "$1 (no '$3' in output)"; fi; }

mkdir -p "$T/bin" "$T/home"; export HOME="$T/home"
printf '#!/bin/sh\nprintf "shim\\n"\n' >"$T/bin/kimi"
cat >"$T/bin/agy" <<'SHIM'
#!/bin/sh
if [ "$1" = "models" ]; then printf "Gemini 3.7 Flash (High)\nGemini 3.1 Pro (High)\n"; exit 0; fi
printf "shim review: no findings\n"
SHIM
chmod +x "$T/bin/"*
export PATH="$T/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
export CROSS_REVIEW_TOOL_MODE=off
# No OpenRouter key: the fallback lane cannot run, so the primary's classification is what lands.
unset OPENROUTER_API_KEY; export XDG_CONFIG_HOME="$T/xdg"

REPO="$T/repo"; mkdir -p "$REPO"
( cd "$REPO" && git init -q && git config user.email t@t && git config user.name t
  printf 'a\n' >f.txt && git add -A && git commit -qm init && git checkout -qb feat
  printf 'a\nb\n' >f.txt && git commit -qam change ) >/dev/null 2>&1

codex_shim() {  # codex_shim <rc> <stdout text>
  printf '#!/bin/sh\ncat >/dev/null 2>&1 || true\nprintf "%%s\\n" %q\nexit %s\n' "$2" "$1" >"$T/bin/codex"; chmod +x "$T/bin/codex"
}
run() { ( cd "$REPO" && bash "$S/run_reviewers.sh" --base master --out "$1" --reviewers codex >"$1.log" 2>&1 ); }

echo "── usage-limit wall with rc=1 ──"
codex_shim 1 "ERROR: You've hit your usage limit. Upgrade to Pro or try again at Aug 19th, 2026 10:51 PM."
run "$T/o1"
assert_eq "failure_kind quota_exhausted"     "$(jq -r .failure_kind "$T/o1/codex.meta.json")" "quota_exhausted"
assert_eq "exit_code stays non-zero"          "$(jq -r '.exit_code != 0' "$T/o1/codex.meta.json")" "true"
[[ -f "$T/o1/codex.quota_exhausted" ]] && ok "sentinel written" || bad "sentinel missing"
assert_contains "sentinel carries the reset ETA" "$(cat "$T/o1/codex.quota_exhausted" 2>/dev/null)" "try again at Aug 19th, 2026 10:51 PM"
assert_contains "stderr says the baseline dropped out" "$(cat "$T/o1.log")" "usage limit reached — baseline drops out of this round"

echo "── wall printed with rc=0 is still a failure ──"
codex_shim 0 "Please purchase more credits to continue."
run "$T/o2"
# With rc=0 the vacuous-success path (#113) owns the classification: no
# OpenRouter key here, so the lane is dropped as a failure, never "ok".
assert_eq "rc=0 wall is not an ok lane"        "$(jq -r '.exit_code != 0' "$T/o2/codex.meta.json")" "true"
assert_eq "…failure_kind is set"               "$(jq -r '.failure_kind != null' "$T/o2/codex.meta.json")" "true"
[[ -f "$T/o2/codex.quota_exhausted" ]] && ok "sentinel still written for an rc=0 wall" || bad "sentinel missing for an rc=0 wall"
assert_contains "ETA absent → 'not reported'" "$(cat "$T/o2/codex.quota_exhausted")" "reset time not reported"

echo "── an ordinary rc=1 is NOT a quota wall ──"
codex_shim 1 "error: something unrelated broke"
run "$T/o3"
assert_eq "failure_kind not quota"           "$(jq -r '.failure_kind == "quota_exhausted"' "$T/o3/codex.meta.json")" "false"
[[ ! -f "$T/o3/codex.quota_exhausted" ]] && ok "no sentinel" || bad "sentinel written for a non-quota failure"

echo; echo "══ $PASS passed, $FAIL failed ══"
[[ "$FAIL" -eq 0 ]] || exit 1
