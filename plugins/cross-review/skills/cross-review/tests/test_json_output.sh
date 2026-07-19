#!/usr/bin/env bash
# test_json_output.sh — offline fixture tests for the curl-lane JSON-findings
# contract (response_format + schema-mandate suffix) and merge_raw_findings.sh.
#
# Standalone and NOT wired into run_tests.sh on purpose (collision avoidance
# across parallel shards — the parent integrates this later). Same
# conventions as run_tests.sh: PATH shims for reviewer binaries, a sandboxed
# HOME (agy caches `agy models` under $HOME/.cross-review/cache), a throwaway
# git repo for --base/--out, NO network, NO real reviewer CLIs, NO tokens.
#
# Run:  bash tests/test_json_output.sh
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
assert_not_contains() {
  if [[ "$2" == *"$3"* ]]; then bad "$1 (unexpectedly found '$3')"; else ok "$1"; fi
}

# ── PATH shims (same shape as run_tests.sh) ─────────────────────────────────
mkdir -p "$T/bin"
printf '#!/bin/sh\ncat >/dev/null 2>&1 || true\nprintf "shim review: no findings\\n"\n' >"$T/bin/kimi"
printf '#!/bin/sh\nprintf "shim\\n"\n' >"$T/bin/codex"
printf '#!/bin/sh\nif [ "$1" = "models" ]; then printf "Gemini 3.5 Flash (High)\\nGemini 3.1 Pro (High)\\n"; fi\n' >"$T/bin/agy"
cat >"$T/canned_or_response.json" <<'EOF'
{"choices":[{"message":{"content":"{\"findings\":[]}"}}],"usage":{"prompt_tokens":10,"completion_tokens":2,"cost":0.001}}
EOF
cat >"$T/bin/curl" <<SHIM
#!/bin/sh
cat "$T/canned_or_response.json"
SHIM
chmod +x "$T/bin/"*
export PATH="$T/bin:$PATH"
export OPENROUTER_API_KEY="sk-or-test-shim"
export MOONSHOT_API_KEY="sk-ms-test-shim"
export HOME="$T/home"
mkdir -p "$HOME"

# ── Fixture repo ─────────────────────────────────────────────────────────────
REPO="$T/repo"; mkdir -p "$REPO"; cd "$REPO"
git init -q -b main 2>/dev/null || git init -q
printf 'line one\n' >f.txt
git add .; git -c user.email=t@t -c user.name=t commit -qm init
git checkout -qb feat
printf 'line one\nline two\n' >f.txt
git add .; git -c user.email=t@t -c user.name=t commit -qm change

echo "── RED/GREEN: curl-lane request body carries response_format ──"
bash "$S/run_reviewers.sh" --base main --out "$T/o1" --reviewers glm --timeout 30 >/dev/null 2>&1 || true
if [[ -f "$T/o1/glm.request.json" ]]; then
  assert_eq "OpenRouter curl-lane body sets response_format.type=json_object" \
    "$(jq -r '.response_format.type // empty' "$T/o1/glm.request.json")" "json_object"
else
  bad "glm.request.json was never written"
fi

echo "── RED/GREEN: clean JSON reply {\"findings\":[]} is a verdict, not no_verdict_output ──"
# A compliant clean review under response_format:json_object is 16 bytes with
# none of output_no_verdict's marker words — it must classify as a successful
# run, not failure_kind=no_verdict_output.
if [[ -f "$T/o1/glm.meta.json" ]]; then
  assert_eq "clean {\"findings\":[]} keeps exit_code 0" \
    "$(jq -r '.exit_code' "$T/o1/glm.meta.json")" "0"
  assert_eq "clean {\"findings\":[]} not reclassified as no_verdict_output" \
    "$(jq -r '.failure_kind' "$T/o1/glm.meta.json")" "null"
else
  bad "glm.meta.json was never written"
fi

echo "── RED/GREEN: curl-lane prompt carries the schema-mandate suffix ──"
if [[ -f "$T/o1/glm.request.json" ]]; then
  assert_contains "OpenRouter curl-lane prompt mandates the findings JSON schema" \
    "$(jq -r '.messages[0].content // empty' "$T/o1/glm.request.json")" "single JSON object"
  assert_contains "OpenRouter curl-lane prompt names the findings array shape" \
    "$(jq -r '.messages[0].content // empty' "$T/o1/glm.request.json")" '"findings"'
fi

echo "── RED/GREEN: direct-Moonshot lane (kimi27) gets the same treatment ──"
bash "$S/run_reviewers.sh" --base main --out "$T/o1b" --reviewers kimi27 --timeout 30 >/dev/null 2>&1 || true
if [[ -f "$T/o1b/kimi27.request.json" ]]; then
  assert_eq "Moonshot curl-lane body sets response_format.type=json_object" \
    "$(jq -r '.response_format.type // empty' "$T/o1b/kimi27.request.json")" "json_object"
  assert_contains "Moonshot curl-lane prompt mandates the findings JSON schema" \
    "$(jq -r '.messages[0].content // empty' "$T/o1b/kimi27.request.json")" "single JSON object"
  assert_eq "Moonshot curl-lane body still omits the OpenRouter usage extension" \
    "$(jq 'has("usage")' "$T/o1b/kimi27.request.json")" "false"
else
  bad "kimi27.request.json was never written"
fi

echo "── RED/GREEN: codex CLI lane is untouched (no response_format concept, no suffix) ──"
bash "$S/run_reviewers.sh" --base main --out "$T/o2" --reviewers codex --timeout 30 >/dev/null 2>&1 || true
assert_not_contains "codex stdout carries no JSON-schema mandate" \
  "$(cat "$T/o2/codex.stdout" 2>/dev/null)" "single JSON object"

echo "── RED/GREEN: agy lanes (antigravity/gemini-pro) are untouched — prompt has no suffix ──"
cat >"$T/bin/agy" <<SHIM
#!/bin/sh
if [ "\$1" = "models" ]; then printf "Gemini 3.5 Flash (High)\\nGemini 3.1 Pro (High)\\n"; exit 0; fi
printf '%s\n' "\$*" > "\${AGY_ARGV_CAPTURE:-/dev/null}"
printf "shim review: no findings\\n"
SHIM
chmod +x "$T/bin/agy"
AGY_ARGV_CAPTURE="$T/agy-argv.txt" bash "$S/run_reviewers.sh" --base main --out "$T/o3" --reviewers antigravity --timeout 30 >/dev/null 2>&1 || true
if [[ -f "$T/agy-argv.txt" ]]; then
  assert_not_contains "antigravity (agy) prompt carries no JSON-schema mandate" \
    "$(cat "$T/agy-argv.txt")" "single JSON object"
else
  bad "agy argv was never captured"
fi
printf '#!/bin/sh\nif [ "$1" = "models" ]; then printf "Gemini 3.5 Flash (High)\\nGemini 3.1 Pro (High)\\n"; fi\n' >"$T/bin/agy"
chmod +x "$T/bin/agy"

echo "── RED/GREEN: kimi CLI lane is untouched — stdin prompt has no suffix ──"
cat >"$T/bin/kimi" <<'SHIM'
#!/bin/sh
cat >"${KIMI_STDIN_CAPTURE:-/dev/null}"
printf "shim review: no findings\n"
SHIM
chmod +x "$T/bin/kimi"
KIMI_STDIN_CAPTURE="$T/kimi-stdin.txt" bash "$S/run_reviewers.sh" --base main --out "$T/o4" --reviewers kimi --timeout-kimi 30 >/dev/null 2>&1 || true
assert_not_contains "kimi CLI prompt carries no JSON-schema mandate" \
  "$(cat "$T/kimi-stdin.txt" 2>/dev/null)" "single JSON object"
printf '#!/bin/sh\ncat >/dev/null 2>&1 || true\nprintf "shim review: no findings\\n"\n' >"$T/bin/kimi"
chmod +x "$T/bin/kimi"

echo "── merge_raw_findings.sh: mixed JSON + fenced JSON + prose ──"
MRAW="$T/mraw"; mkdir -p "$MRAW"
cat >"$MRAW/glm.stdout" <<'EOF'
{"findings":[{"severity":"High","file":"a.sh","line":3,"snippet":"rm -rf $x","claim":"unquoted var can expand to nothing and rm -rf /"}]}
EOF
cat >"$MRAW/deepseek.stdout" <<'EOF'
```json
{"findings":[{"severity":"Low","file":"b.sh","line":10,"snippet":"echo $y","claim":"unquoted var, minor"}]}
```
EOF
cat >"$MRAW/kimi.stdout" <<'EOF'
No significant issues found. The change looks correct and handles edge cases well.
EOF
MERGE_ERR="$T/merge.err"
bash "$S/merge_raw_findings.sh" --raw "$MRAW" --out "$T/merged.json" 2>"$MERGE_ERR"
MERGE_RC=$?
assert_eq "merge_raw_findings.sh exits 0 even with a prose input present" "$MERGE_RC" "0"
assert_eq "merged findings count (glm=1 + deepseek=1, kimi prose excluded)" \
  "$(jq '.findings | length' "$T/merged.json")" "2"
assert_eq "glm finding tagged with its own source" \
  "$(jq -r '.findings[] | select(.file=="a.sh") | .sources[0]' "$T/merged.json")" "glm"
assert_eq "fence-wrapped deepseek finding still parses and tags correctly" \
  "$(jq -r '.findings[] | select(.file=="b.sh") | .sources[0]' "$T/merged.json")" "deepseek"
assert_contains "prose reviewer reported as unparsed on stderr" "$(cat "$MERGE_ERR")" "unparsed: kimi"
assert_not_contains "cooperative reviewers are NOT reported as unparsed" "$(cat "$MERGE_ERR")" "unparsed: glm"

echo "── merge_raw_findings.sh: all-prose input still exits 0 with empty findings ──"
ARAW="$T/araw"; mkdir -p "$ARAW"
printf 'Looks fine to me, no issues.\n' >"$ARAW/kimi.stdout"
printf 'LGTM, nothing to flag.\n' >"$ARAW/antigravity.stdout"
bash "$S/merge_raw_findings.sh" --raw "$ARAW" --out "$T/all-prose.json" 2>"$T/all-prose.err"
assert_eq "all-prose run still exits 0" "$?" "0"
assert_eq "all-prose run yields an empty findings array" \
  "$(jq '.findings | length' "$T/all-prose.json")" "0"
assert_contains "both prose reviewers reported unparsed" "$(cat "$T/all-prose.err")" "unparsed: kimi"
assert_contains "both prose reviewers reported unparsed (2)" "$(cat "$T/all-prose.err")" "unparsed: antigravity"

echo
echo "══ $PASS passed, $FAIL failed ══"
[[ "$FAIL" -eq 0 ]]
