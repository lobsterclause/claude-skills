#!/usr/bin/env bash
# test_fallback_vacuous.sh — the vacuous-success fallback path (#113) is
# REACHABLE from run_reviewers.sh, not just from fallback_eligible.sh in
# isolation. A codex lap that exits 0 with only its banner plus a wall message
# must be rescued over OpenRouter; a codex lap that exits 0 with a short real
# review that merely mentions a status code must NOT be (cross-review of #113).
# Offline: PATH shims for codex/agy/kimi/curl, a throwaway git repo as target.
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

mkdir -p "$T/bin"
printf '#!/bin/sh\nprintf "shim review: no findings\\n"\n' >"$T/bin/kimi"
cat >"$T/bin/agy" <<'SHIM'
#!/bin/sh
if [ "$1" = "models" ]; then printf "Gemini 3.5 Flash (High)\nGemini 3.1 Pro (High)\n"; exit 0; fi
printf "shim review: no findings\n"
SHIM
cat >"$T/canned.json" <<'EOF'
{"choices":[{"message":{"content":"## High\nNone. Clean — no findings (fallback lane)."}}],"usage":{"prompt_tokens":100,"completion_tokens":10,"cost":0.001}}
EOF
cat >"$T/bin/curl" <<SHIM
#!/bin/sh
cat "$T/canned.json"
SHIM
chmod +x "$T/bin/"*
export PATH="$T/bin:$PATH"
export OPENROUTER_API_KEY="sk-or-test-shim"
export HOME="$T/home"; mkdir -p "$HOME"

REPO="$T/repo"; mkdir -p "$REPO"; cd "$REPO"
git init -q -b main 2>/dev/null || git init -q
echo "hello" >f.txt; git add f.txt
git -c user.email=t@t -c user.name=t commit -qm init
git checkout -qb feat; echo "world" >>f.txt; git add f.txt
git -c user.email=t@t -c user.name=t commit -qm change

echo "── (a) codex exits 0 with a banner + wall: the OpenRouter fallback runs ──"
cat >"$T/bin/codex" <<'SHIM'
#!/bin/sh
cat >/dev/null 2>&1 || true
# ~600 bytes: the banner carries the prompt line, and the measured vacuous runs
# were 485-564 bytes — ABOVE output_no_verdict's 512-byte cut, so nothing else
# turns this rc=0 into a failure; only an unconditional maybe_or_fallback
# reaches it.
pad=$(printf '%0480d' 0 | tr 0 p)
printf 'OpenAI Codex v0.144.4\nworkdir: /tmp/w\nmodel: gpt-5.6-sol\nprompt: %s\nERROR: You have hit your usage limit. Try again at 6:10 PM.\n' "$pad"
exit 0
SHIM
chmod +x "$T/bin/codex"
bash "$S/run_reviewers.sh" --base main --out "$T/o1" --reviewers codex --timeout 60 >/dev/null 2>"$T/o1.err" || true
assert_eq "codex.meta.json records the fallback as used" \
  "$(jq -r '.fallback.used // false' "$T/o1/codex.meta.json" 2>/dev/null)" "true"
assert_eq "the fallback reason is the wall pattern" \
  "$(jq -r '.fallback.reason // ""' "$T/o1/codex.meta.json" 2>/dev/null)" "account_limit"
assert_eq "the primary's vacuous output is preserved as primary-failed" \
  "$([[ -f "$T/o1/codex.primary-failed.stdout" ]] && echo yes || echo no)" "yes"
assert_eq "the vacuous primary output was above output_no_verdict's 512-byte cut" \
  "$(( $(wc -c <"$T/o1/codex.primary-failed.stdout" 2>/dev/null || echo 0) > 512 ))" "1"
assert_eq "the WARN names the provider" \
  "$(grep -c 'PRIMARY PROVIDER NEEDS ATTENTION' "$T/o1.err")" "1"

echo "── (b) codex exits 0 with a short real review mentioning a status code: NO fallback ──"
cat >"$T/bin/codex" <<'SHIM'
#!/bin/sh
cat >/dev/null 2>&1 || true
printf 'LGTM. Handles HTTP 429 correctly.\n'
exit 0
SHIM
chmod +x "$T/bin/codex"
bash "$S/run_reviewers.sh" --base main --out "$T/o2" --reviewers codex --timeout 60 >/dev/null 2>"$T/o2.err" || true
assert_eq "no fallback for a short real review" \
  "$(jq -r '.fallback.used // false' "$T/o2/codex.meta.json" 2>/dev/null)" "false"
assert_eq "no primary-failed artefact" \
  "$([[ -f "$T/o2/codex.primary-failed.stdout" ]] && echo yes || echo no)" "no"
assert_eq "the review text is kept as the lane's output" \
  "$(grep -c 'LGTM' "$T/o2/codex.stdout")" "1"

echo
echo "══ $PASS passed, $FAIL failed ══"
[[ "$FAIL" -eq 0 ]] || exit 1
