#!/usr/bin/env bash
# test_meta_context_mode.sh — offline fixture tests for run_reviewers.sh
# stamping `context_mode` ("tools" | "files" | "diff") into EVERY meta.json it
# writes at dispatch (#130) — success, retry, fallback-via-curl-failure, and
# timeout/failure paths alike.
#
# `context_mode` is decided from what the lane was actually given: codex and
# the two agy laps get their own file-reading tools ("tools"); a text-only
# lane (kimi, the OpenRouter pool) that received the whole-file block or a
# --snapshot-dir file gets "files"; a text-only lane that received only the
# diff (--context-mode diff, or no snapshot/file-context) gets "diff". This
# must agree exactly with append_runlog.sh's context_access -> context_mode
# fallback derivation (#93, tests/test_runlog_row_stamps.sh) — that mapping is
# NOT changed here, only made explicit at the point of dispatch.
#
# Standalone: run directly, or from run_tests.sh. NO network, NO real reviewer
# CLIs — PATH shims under $T/bin stand in for codex/agy/kimi/curl, mirroring
# the technique tests/run_tests.sh uses.
#
# Run:  bash tests/test_meta_context_mode.sh
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

# ── PATH shims: fake reviewer binaries, same technique as run_tests.sh ─────
mkdir -p "$T/bin"
printf '#!/bin/sh\ncat >/dev/null 2>&1 || true\nprintf "shim review: no findings\\n"\n' >"$T/bin/kimi"
printf '#!/bin/sh\nprintf "shim\\n"\n' >"$T/bin/codex"
cat >"$T/bin/agy" <<'SHIM'
#!/bin/sh
if [ "$1" = "models" ]; then printf "Gemini 3.5 Flash (High)\nGemini 3.1 Pro (High)\n"; exit 0; fi
printf "shim review: no findings\n"
exit 0
SHIM
chmod +x "$T/bin/"*
export PATH="$T/bin:$PATH"
export OPENROUTER_API_KEY="sk-or-test-shim"
export MOONSHOT_API_KEY="sk-ms-test-shim"
# Sandbox HOME: agy's model-list cache and select_roster.sh's decision cache
# both live under $HOME/.cross-review — never touch the real one.
export HOME="$T/home"
mkdir -p "$HOME"
# The tool loop (feat/cross-review-tool-loop) arms text-only seats with
# read/check tools under its default "auto" policy, which makes their
# context_access tool_read/tool_check instead of file_context/diff_only.
# Cases (a)-(f) pin the PASTE contract, so the loop is held off here; case
# (g) below covers the armed shape on its own.
export CROSS_REVIEW_TOOL_MODE=off

# ── temp git repo with a one-file diff as the review target ────────────────
REPO="$T/repo"; mkdir -p "$REPO"; cd "$REPO"
git init -q -b main 2>/dev/null || git init -q
echo "hello" >f.txt
git add f.txt
git -c user.email=t@t -c user.name=t commit -qm init
git checkout -qb feat
echo "world" >>f.txt
git add f.txt
git -c user.email=t@t -c user.name=t commit -qm change

canned_or_response() {
  cat >"$T/canned_or_response.json" <<'EOF'
{"choices":[{"message":{"content":"## Critical\nNone.\n\n## High\nNone. Clean — no findings."}}],"usage":{"prompt_tokens":100,"completion_tokens":10,"cost":0.001}}
EOF
  cat >"$T/bin/curl" <<SHIM
#!/bin/sh
cat "$T/canned_or_response.json"
SHIM
  chmod +x "$T/bin/curl"
}

echo "── (a) --context-mode files: codex/antigravity -> tools, kimi/glm -> files ──"
canned_or_response
bash "$S/run_reviewers.sh" --base main --out "$T/o1" \
  --reviewers codex,antigravity,kimi,glm --context-mode files >/dev/null 2>&1
assert_eq "codex context_mode == tools" \
  "$(jq -r '.context_mode' "$T/o1/codex.meta.json")" "tools"
assert_eq "antigravity context_mode == tools" \
  "$(jq -r '.context_mode' "$T/o1/antigravity.meta.json")" "tools"
assert_eq "kimi context_mode == files" \
  "$(jq -r '.context_mode' "$T/o1/kimi.meta.json")" "files"
assert_eq "glm context_mode == files" \
  "$(jq -r '.context_mode' "$T/o1/glm.meta.json")" "files"
rm -f "$T/bin/curl"

echo "── (b) --context-mode diff: kimi/glm -> diff ──"
canned_or_response
bash "$S/run_reviewers.sh" --base main --out "$T/o2" \
  --reviewers kimi,glm --context-mode diff >/dev/null 2>&1
assert_eq "kimi context_mode == diff" \
  "$(jq -r '.context_mode' "$T/o2/kimi.meta.json")" "diff"
assert_eq "glm context_mode == diff" \
  "$(jq -r '.context_mode' "$T/o2/glm.meta.json")" "diff"
rm -f "$T/bin/curl"

echo "── (c) curl-lane failure (exits 1 twice) still writes context_mode ──"
cat >"$T/bin/curl" <<SHIM
#!/bin/sh
exit 1
SHIM
chmod +x "$T/bin/curl"
bash "$S/run_reviewers.sh" --base main --out "$T/o3" \
  --reviewers glm --context-mode files >/dev/null 2>&1 || true
assert_eq "glm meta.json exists after a total curl failure" \
  "$([[ -f "$T/o3/glm.meta.json" ]] && echo yes || echo no)" "yes"
assert_eq "failed glm run still carries context_mode == files" \
  "$(jq -r '.context_mode' "$T/o3/glm.meta.json")" "files"
assert_eq "failed glm run retried once (attempt 2)" \
  "$(jq -r '.attempt' "$T/o3/glm.meta.json")" "2"
rm -f "$T/bin/curl"

echo "── (d) --snapshot-dir with snapshot-glm.md -> glm gets files ──"
canned_or_response
SNAP="$T/snap"; mkdir -p "$SNAP"
printf 'pre-built snapshot content\n' >"$SNAP/snapshot-glm.md"
bash "$S/run_reviewers.sh" --base main --out "$T/o4" \
  --reviewers glm --context-mode diff --snapshot-dir "$SNAP" >/dev/null 2>&1
assert_eq "glm with a matching snapshot file -> context_mode files (snapshot beats --context-mode diff)" \
  "$(jq -r '.context_mode' "$T/o4/glm.meta.json")" "files"
assert_eq "glm context_access is snapshot" \
  "$(jq -r '.context_access' "$T/o4/glm.meta.json")" "snapshot"
rm -f "$T/bin/curl"

echo "── (e) additive only: every pre-existing meta key survives, plus context_mode ──"
# Pinned from the meta.json shape run_reviewers.sh wrote BEFORE this change
# (verbatim from the printf format strings in scripts/run_reviewers.sh on the
# feat/cr-meta-context-mode base commit). Any key missing here is a
# regression; context_mode must be the only addition.
CODEX_KEYS_BEFORE='["attempt","context_access","duration_s","exit_code","failure_kind","output_bytes","timed_out","timeout_budget_s","wall_over_budget"]'
# OR rows also carry tokens_cached/tokens_cache_write/upstream_provider and
# tool_policy/tool_stats since feat/cross-review-tool-loop (prompt-caching
# telemetry + the learned tool arms); those pre-date context_mode on that
# branch, so they belong in the "before" set.
OR_KEYS_BEFORE='["attempt","cli","context_access","context_files","context_files_omitted","cost_usd","duration_s","exit_code","failure_kind","model","output_bytes","timed_out","timeout_budget_s","tokens_cache_write","tokens_cached","tokens_completion","tokens_prompt","tool_policy","tool_stats","total_diff_lines","truncated","upstream_provider","wall_over_budget"]'
KIMI_KEYS_BEFORE='["attempt","context_access","context_files","context_files_omitted","diff_line_cap","duration_s","exit_code","failure_kind","output_bytes","timed_out","timeout_budget_s","total_diff_lines","truncated","wall_over_budget"]'
AGY_KEYS_BEFORE='["attempt","cli","context_access","duration_s","exit_code","failure_kind","model","model_resolved","output_bytes","quota_resets_in","timed_out","timeout_budget_s","wall_over_budget"]'

canned_or_response
bash "$S/run_reviewers.sh" --base main --out "$T/o5" \
  --reviewers codex,antigravity,kimi,glm --context-mode files >/dev/null 2>&1
rm -f "$T/bin/curl"

check_keys() {
  local desc="$1" file="$2" before="$3"
  local after_no_cm after_has_cm
  after_no_cm="$(jq -Sc '(keys) - ["context_mode"] | sort' "$file")"
  after_has_cm="$(jq -r '(keys | index("context_mode")) != null' "$file")"
  assert_eq "$desc: pre-existing keys unchanged" "$after_no_cm" "$(jq -Sc 'sort' <<<"$before")"
  assert_eq "$desc: context_mode key present" "$after_has_cm" "true"
}
check_keys "codex.meta.json" "$T/o5/codex.meta.json" "$CODEX_KEYS_BEFORE"
check_keys "glm.meta.json" "$T/o5/glm.meta.json" "$OR_KEYS_BEFORE"
check_keys "kimi.meta.json" "$T/o5/kimi.meta.json" "$KIMI_KEYS_BEFORE"
check_keys "antigravity.meta.json" "$T/o5/antigravity.meta.json" "$AGY_KEYS_BEFORE"

echo "── (f) no_model_configured early exit stamps the INTENDED mode, not a constant ──"
# The early exit fires before the prompt (and context_access) exists, so the
# lane never received anything; the row must still say what the round asked
# for. The live profile is never touched: a copy without .glm.model goes to
# $T and run_reviewers.sh reads it via CROSS_REVIEW_PROFILES_FILE.
jq 'del(.glm.model)' "$S/../references/reviewer_profiles.json" >"$T/profiles_nomodel.json"
export CROSS_REVIEW_PROFILES_FILE="$T/profiles_nomodel.json"
bash "$S/run_reviewers.sh" --base main --out "$T/o6" \
  --reviewers glm --context-mode files >/dev/null 2>&1 || true
assert_eq "no_model_configured row exists" \
  "$(jq -r '.failure_kind' "$T/o6/glm.meta.json" 2>/dev/null)" "no_model_configured"
assert_eq "no_model_configured + --context-mode files -> context_mode files" \
  "$(jq -r '.context_mode' "$T/o6/glm.meta.json")" "files"
bash "$S/run_reviewers.sh" --base main --out "$T/o7" \
  --reviewers glm --context-mode diff >/dev/null 2>&1 || true
assert_eq "no_model_configured + --context-mode diff -> context_mode diff" \
  "$(jq -r '.context_mode' "$T/o7/glm.meta.json")" "diff"
bash "$S/run_reviewers.sh" --base main --out "$T/o8" \
  --reviewers glm --context-mode diff --snapshot-dir "$SNAP" >/dev/null 2>&1 || true
assert_eq "no_model_configured + snapshot present -> context_mode files" \
  "$(jq -r '.context_mode' "$T/o8/glm.meta.json")" "files"
unset CROSS_REVIEW_PROFILES_FILE
assert_eq "live reviewer_profiles.json still has glm.model" \
  "$(jq -r '.glm.model != null' "$S/../references/reviewer_profiles.json")" "true"

echo "── (g) tool loop armed (read): glm context_access tool_read -> context_mode tools ──"
# Same table as append_runlog.sh / leaderboard.sh: a seat that could read
# files through the loop is a "tools" row, whatever was pasted.
canned_or_response
CROSS_REVIEW_TOOL_MODE=read bash "$S/run_reviewers.sh" --base main --out "$T/o9" \
  --reviewers glm --context-mode files >/dev/null 2>&1 || true
assert_eq "armed glm context_access == tool_read" \
  "$(jq -r '.context_access' "$T/o9/glm.meta.json")" "tool_read"
assert_eq "armed glm context_mode == tools" \
  "$(jq -r '.context_mode' "$T/o9/glm.meta.json")" "tools"
rm -f "$T/bin/curl"

echo ""
echo "══ $PASS passed, $FAIL failed ══"
[[ "$FAIL" -eq 0 ]] || exit 1
