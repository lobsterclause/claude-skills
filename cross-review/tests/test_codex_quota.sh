#!/usr/bin/env bash
# test_codex_quota.sh — codex usage-limit exhaustion is stamped, not a bare rc=1.
# Offline: codex is a PATH shim. Pins PR #61: failure_kind "quota_exhausted",
# a codex.quota_exhausted sentinel carrying the reset ETA, and rc=0-with-wall
# still classified as failed (rc 5 — never 3, which is agy's quota signal).
set -uo pipefail
S="$(cd "$(dirname "${BASH_SOURCE[0]}")/../scripts" && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
PASS=0; FAIL=0
ok()  { echo "  ok   $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL $1"; FAIL=$((FAIL + 1)); }
assert_eq() { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 (got: '$2' want: '$3')"; fi; }
assert_contains() { if [[ "$2" == *"$3"* ]]; then ok "$1"; else bad "$1 (no '$3' in output)"; fi; }

command -v jq >/dev/null 2>&1 || { echo "jq required" >&2; exit 1; }
[[ -f "$S/run_reviewers.sh" ]] || { echo "run_reviewers.sh not found at $S" >&2; exit 1; }
mkdir -p "$T/bin" "$T/home"; export HOME="$T/home"
# Pin the profile so the rc=0-wall guarantee is tested against fixed config,
# not whatever the live reviewer_profiles.json happens to say (glm).
jq '{codex: (.codex + {or_fallback: {enabled: true, model: "openai/gpt-5.6-sol"}}), _synthesis_rules: ._synthesis_rules}' "$S/../references/reviewer_profiles.json" >"$T/profiles.json"
export CROSS_REVIEW_PROFILES_FILE="$T/profiles.json"
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
( cd "$REPO" && { git init -q -b master 2>/dev/null || git init -q; } && git config user.email t@t && git config user.name t
  printf 'a\n' >f.txt && git add -A && git commit -qm init && git checkout -qb feat
  printf 'a\nb\n' >f.txt && git commit -qam change ) >/dev/null 2>&1

codex_shim() {  # codex_shim <rc> <stdout text> — plain sh, no bash-isms (kimi)
  { printf '#!/bin/sh\ncat >/dev/null 2>&1 || true\ncat <<'"'"'MSG'"'"'\n'; printf '%s\n' "$2"; printf 'MSG\nexit %s\n' "$1"; } >"$T/bin/codex"; chmod +x "$T/bin/codex"
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
# rc=0 + a short wall → rc 5 in the lane itself (never 3), and the specific
# failure_kind survives the "fallback could not run" stamp.
assert_eq "rc=0 wall is not an ok lane"        "$(jq -r '.exit_code != 0' "$T/o2/codex.meta.json")" "true"
assert_eq "…failure_kind quota_exhausted survives" "$(jq -r .failure_kind "$T/o2/codex.meta.json")" "quota_exhausted"
assert_eq "…exit_code is never agy's 3"        "$(jq -r '.exit_code != 3' "$T/o2/codex.meta.json")" "true"
[[ -f "$T/o2/codex.quota_exhausted" ]] && ok "sentinel still written for an rc=0 wall" || bad "sentinel missing for an rc=0 wall"
assert_contains "ETA absent → 'not reported'" "$(cat "$T/o2/codex.quota_exhausted")" "reset time not reported"

echo "── a healthy rc=0 review that QUOTES the wall phrases is NOT a wall (glm High) ──"
codex_shim 0 "$(printf 'Review of the diff.\n\n[P2] The grep for "purchase more credits" and "hit your usage limit" at run_reviewers.sh:1137 has no rc guard.\n%s\n\nNo other findings.\n' "$(printf 'x%.0s' {1..600})")"
run "$T/o4"
assert_eq "real review quoting the phrases stays rc 0"   "$(jq -r .exit_code "$T/o4/codex.meta.json")" "0"
assert_eq "…and is not stamped quota_exhausted"          "$(jq -r '.failure_kind == "quota_exhausted"' "$T/o4/codex.meta.json")" "false"
[[ ! -f "$T/o4/codex.quota_exhausted" ]] && ok "…no sentinel for a real review" || bad "sentinel written for a real review"

echo "── an ordinary rc=1 is NOT a quota wall ──"
codex_shim 1 "error: something unrelated broke"
run "$T/o3"
assert_eq "failure_kind not quota"           "$(jq -r '.failure_kind == "quota_exhausted"' "$T/o3/codex.meta.json")" "false"
[[ ! -f "$T/o3/codex.quota_exhausted" ]] && ok "no sentinel" || bad "sentinel written for a non-quota failure"

echo; echo "══ $PASS passed, $FAIL failed ══"
[[ "$FAIL" -eq 0 ]] || exit 1
