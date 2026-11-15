#!/usr/bin/env bash
# test_paths.sh — fixture tests for path-scoped rounds (--paths).
#
# Offline, no network, no real reviewer CLIs: kimi / agy / codex / curl are PATH
# shims that capture what they were sent; git repos live in a temp dir.
#
# WHAT THIS PINS
# --------------
# 1. The descendant-base trap. A hand-built "synthetic base" that DESCENDS from
#    the ref made worktree.sh's three-dot diff empty -- size_files 0,
#    size_lines 0 -- with exit 0, so reviewers would have run on nothing. The
#    first case reproduces that silence WITHOUT --paths (documenting it), then
#    shows --paths fails loudly instead.
# 2. Every place a diff or file set is built honours the filter: the inlined
#    <diff>, the whole-file block, --stat, doc_narrative_risk, the agy prompt,
#    codex (explicit prompt, not --base) and the tool loop's scope note.
# 3. meta.json / context.json / runlog carry paths + paths_mode.
# 4. A path-scoped round has its OWN repeat-pass key; full-diff keys unchanged.
# 5. plan_rounds.sh is deterministic.
#
# Run:  bash tests/test_paths.sh        Exit: 0 all green, 1 any failure.

set -uo pipefail

SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
S="$SKILL_DIR/scripts"
T="$(mktemp -d)"
[[ -n "$T" && -d "$T" ]] || { echo "FATAL: mktemp failed" >&2; exit 1; }
trap 'rm -rf "$T"' EXIT

PASS=0
FAIL=0
ok()  { echo "  ok   $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL $1"; FAIL=$((FAIL + 1)); }
assert_eq() {
  if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 (got: '$2' want: '$3')"; fi
}
assert_contains() {
  if [[ "$2" == *"$3"* ]]; then ok "$1"; else bad "$1 (no '$3' in: ${2:0:200})"; fi
}
assert_not_contains() {
  if [[ "$2" != *"$3"* ]]; then ok "$1"; else bad "$1 (unexpectedly found '$3')"; fi
}

command -v jq >/dev/null 2>&1 || { echo "jq required to run these tests" >&2; exit 1; }

mkdir -p "$T/bin" "$T/home"
export HOME="$T/home"
export PATH="$T/bin:$PATH"
export OPENROUTER_API_KEY="sk-or-test-shim"
export CROSS_REVIEW_OPENROUTER=1
export CROSS_REVIEW_TOOL_MODE=off
export CROSS_REVIEW_WORKTREE_ROOT="$T/wt"
export CROSS_REVIEW_RUN_ROOT="$T/runs"
export CROSS_REVIEW_STATE_DIR="$T/state"
unset CROSS_REVIEW_PATHS CROSS_REVIEW_CODEX_FORCE_BASE CROSS_REVIEW_ALLOW_EMPTY_PATHS CROSS_REVIEW_ALLOW_NON_ANCESTOR_BASE

# ── shims ───────────────────────────────────────────────────────────────────
cat >"$T/bin/kimi" <<SHIM
#!/bin/sh
cat > "$T/kimi.prompt"
printf '## Critical\nNone.\n\n## High\nNone. Clean - no findings.\n'
SHIM
cat >"$T/bin/agy" <<SHIM
#!/bin/sh
if [ "\$1" = "models" ]; then printf 'Gemini 3.5 Flash (High)\nGemini 3.1 Pro (High)\n'; exit 0; fi
prev=""
for a in "\$@"; do
  if [ "\$prev" = "-p" ]; then printf '%s' "\$a" > "$T/agy.prompt"; fi
  prev="\$a"
done
printf '## Critical\nNone.\n\n## High\nNone. Clean - no findings.\n'
SHIM
# codex: records argv and stdin, answers with a clean P3.
cat >"$T/bin/codex" <<SHIM
#!/bin/sh
printf '%s\n' "\$@" > "$T/codex.argv"
cat > "$T/codex.stdin" 2>/dev/null || true
printf '\ncodex\n[P3] nothing to report\n'
SHIM
printf '%s' '{"choices":[{"message":{"content":"## Critical\nNone.\n\n## High\nNone. Clean - no findings."}}],"usage":{"prompt_tokens":10,"completion_tokens":5,"cost":0.001}}' >"$T/canned.json"
cat >"$T/bin/curl" <<SHIM
#!/bin/sh
cat "$T/canned.json"
SHIM
chmod +x "$T/bin/kimi" "$T/bin/agy" "$T/bin/codex" "$T/bin/curl"

# ── fixture repo ────────────────────────────────────────────────────────────
# src/ is IN scope. other/ is OUT of scope. docs/notes.md is OUT of scope and a
# markdown file (doc_narrative_risk would fire on the unfiltered diff).
# config/.env.production is OUT of scope and trips the secret-path check.
REPO="$T/repo"; mkdir -p "$REPO"
(
  cd "$REPO" || exit 1
  git init -q -b main 2>/dev/null || git init -q
  git config user.email t@t; git config user.name t
  mkdir -p src other docs config
  printf 'in v1\n' >src/app.ts
  { echo 'FAR_IN_SCOPE_MARKER_a1'; for i in $(seq 1 15); do echo "pad $i"; done; echo 'tail v1'; } >src/far.ts
  printf 'out v1\n' >other/out.ts
  printf 'notes v1\n' >docs/notes.md
  printf 'K=1\n' >config/.env.production
  git add -A; git commit -qm init
  git checkout -qb feat
  printf 'in v2 IN_SCOPE_MARKER_b2\n' >src/app.ts
  sed -i.bak 's/tail v1/tail v2 IN_SCOPE_TAIL_c3/' src/far.ts && rm -f src/far.ts.bak
  printf 'out v2 OUT_SCOPE_MARKER_d4\n' >other/out.ts
  printf 'notes v2 OUT_SCOPE_DOC_e5\n' >docs/notes.md
  printf 'K=2\n' >config/.env.production
  git add -A; git commit -qm change
  # a base that DESCENDS from feat: the "synthetic base" shape that bit us
  git checkout -qb synth; echo more >src/app.ts.more; git add -A; git commit -qm synth
  git checkout -q feat
)
cr() { # cr <outdir> <args...>
  local o="$1"; shift
  ( cd "$REPO" && bash "$S/run_reviewers.sh" "$@" --out "$o" >"$o.log" 2>&1 ); echo $? >"$o.rc"
}

echo "── lib_paths: normalisation ──"
. "$S/lib_paths.sh"
assert_eq "split, trim, strip ./, sort, dedupe" "$(cr_paths_normalise ' ./b/ , a/*.ts,a/*.ts' | tr '\n' '|')" "a/*.ts|b/|"
assert_eq "same set -> same hash regardless of order" \
  "$(cr_paths_normalise 'a,b' | cr_paths_hash)" "$(cr_paths_normalise 'b,a,a' | cr_paths_hash)"
cr_paths_normalise '/etc' >/dev/null 2>&1; assert_eq "absolute pathspec refused" "$?" "2"
cr_paths_normalise 'a/../b' >/dev/null 2>&1; assert_eq "'..' pathspec refused" "$?" "2"
cr_paths_normalise ' , ' >/dev/null 2>&1; assert_eq "empty pathspec list refused" "$?" "2"

echo "── worktree.sh start: the descendant-base trap ──"
WTS() { ( cd "$REPO" && bash "$S/worktree.sh" start "$@" ); }
# Reproduction of the original silent failure: WITHOUT --paths nothing complains.
OUT_TRAP="$(WTS --ref feat --base synth --id trap-nopaths 2>"$T/trap0.err")"; RC=$?
assert_eq "no --paths: a descendant base still exits 0 (the old silent behaviour)" "$RC" "0"
assert_eq "…with size_files 0" "$(jq -r .size_files <<<"$OUT_TRAP")" "0"
assert_eq "…and size_lines 0 (a round that would review NOTHING)" "$(jq -r .size_lines <<<"$OUT_TRAP")" "0"
assert_eq "…and no paths keys in context.json (full-diff record unchanged)" "$(jq -r 'has("paths")' <<<"$OUT_TRAP")" "false"
WTS --ref feat --base synth --paths src/ --id trap-paths >"$T/trap1.out" 2>"$T/trap1.err"; RC=$?
assert_eq "--paths + descendant base: FAILS (exit 3)" "$RC" "3"
assert_contains "…with a message naming the cause" "$(cat "$T/trap1.err")" "descendant"
assert_contains "…and the empty diff" "$(cat "$T/trap1.err")" "EMPTY"
assert_eq "…and creates no run dir" "$(ls "$T/runs" 2>/dev/null | grep -c 'trap-paths')" "0"
WTS --ref feat --base synth --paths src/ --id trap-allow --allow-non-ancestor-base >"$T/trap2.out" 2>"$T/trap2.err"; RC=$?
assert_eq "--allow-non-ancestor-base lets it through (the empty filter then trips instead)" "$RC" "3"
assert_contains "…and says so" "$(cat "$T/trap2.err")" "no changed files match --paths"
WTS --ref feat --base synth --paths src/ --id trap-allow2 --allow-non-ancestor-base --allow-empty-paths >"$T/trap3.out" 2>"$T/trap3.err"; RC=$?
assert_eq "both escapes together proceed (exit 0)" "$RC" "0"
assert_eq "…recording base_is_ancestor=false" "$(jq -r .base_is_ancestor "$T/trap3.out")" "false"

echo "── worktree.sh start: empty filtered diff fails loudly ──"
WTS --ref feat --base main --paths nothing/here --id empty-f >"$T/e1.out" 2>"$T/e1.err"; RC=$?
assert_eq "no changed file matches the pathspec: exit 3" "$RC" "3"
assert_contains "…message says the filtered diff is empty" "$(cat "$T/e1.err")" "filtered diff is empty"
assert_eq "…no run dir created" "$(ls "$T/runs" 2>/dev/null | grep -c 'empty-f')" "0"
CROSS_REVIEW_ALLOW_EMPTY_PATHS=1 WTS --ref feat --base main --paths nothing/here --id empty-ok >"$T/e2.out" 2>/dev/null; RC=$?
assert_eq "CROSS_REVIEW_ALLOW_EMPTY_PATHS=1 downgrades it" "$RC" "0"
assert_eq "…size_files 0" "$(jq -r .size_files "$T/e2.out")" "0"

echo "── worktree.sh start: size/warn/risky computed over the FILTERED diff ──"
FULL="$(WTS --ref feat --base main --id sz-full 2>/dev/null)"
FILT="$(WTS --ref feat --base main --paths src/ --id sz-filt 2>/dev/null)"
assert_eq "full diff: 5 files" "$(jq -r .size_files <<<"$FULL")" "5"
assert_eq "filtered (src/): 2 files" "$(jq -r .size_files <<<"$FILT")" "2"
assert_eq "filtered lines are only src/'s (2 insertions + 2 deletions = 4)" "$(jq -r .size_lines <<<"$FILT")" "4"
assert_eq "full diff trips warn_secrets (config/.env.production)" "$(jq -r .warn_secrets <<<"$FULL")" "true"
assert_eq "filtered diff does NOT (the .env file is out of scope)" "$(jq -r .warn_secrets <<<"$FILT")" "false"
assert_eq "…risky_files empty" "$(jq -r .risky_files <<<"$FILT")" ""
FILT2="$(WTS --ref feat --base main --paths config/ --id sz-filt2 2>/dev/null)"
assert_eq "filtering TO the secret path still warns" "$(jq -r .warn_secrets <<<"$FILT2")" "true"
assert_eq "context.json records the normalised list" "$(jq -c .paths <<<"$FILT")" '["src/"]'
assert_eq "…paths_mode=filtered" "$(jq -r .paths_mode <<<"$FILT")" "filtered"
assert_eq "…base_is_ancestor=true" "$(jq -r .base_is_ancestor <<<"$FILT")" "true"
assert_eq "…and the on-disk context.json matches stdout" "$(jq -c .paths "$(jq -r .run_dir <<<"$FILT")/context.json")" '["src/"]'
REP="$(WTS --ref feat --base main --path src/ --path other/ --id sz-rep 2>/dev/null)"
assert_eq "repeatable --path accumulates (sorted)" "$(jq -c .paths <<<"$REP")" '["other/","src/"]'
ENVR="$(CROSS_REVIEW_PATHS='src/' WTS --ref feat --base main --id sz-env 2>/dev/null)"
assert_eq "CROSS_REVIEW_PATHS is honoured" "$(jq -c .paths <<<"$ENVR")" '["src/"]'
assert_eq "…and the hash is stable across the spellings" \
  "$(jq -r .paths_hash <<<"$ENVR")" "$(jq -r .paths_hash <<<"$FILT")"

echo "── run_reviewers: the filter reaches every diff and file set ──"
cr "$T/o1" --base main --reviewers kimi,glm --paths src/ --timeout-kimi 30 --timeout-glm 30
KIMI="$(cat "$T/kimi.prompt" 2>/dev/null || echo MISSING)"
GLM="$(jq -r '.messages[0].content // "MISSING"' "$T/o1/glm.request.json" 2>/dev/null || echo MISSING)"
assert_eq "round ran (rc 0)" "$(cat "$T/o1.rc")" "0"
for L in KIMI GLM; do
  P="${!L}"
  assert_contains "$L: in-scope hunk present" "$P" "IN_SCOPE_MARKER_b2"
  assert_contains "$L: second in-scope hunk present" "$P" "IN_SCOPE_TAIL_c3"
  assert_not_contains "$L: out-of-scope code hunk absent" "$P" "OUT_SCOPE_MARKER_d4"
  assert_not_contains "$L: out-of-scope doc hunk absent" "$P" "OUT_SCOPE_DOC_e5"
  assert_not_contains "$L: out-of-scope file not named in --stat" "$P" "other/out.ts"
  assert_not_contains "$L: no doc-narrative NOTE (the only .md is out of scope)" "$P" "this diff touches documentation"
  assert_contains "$L: whole-file block has the in-scope file (line far from the hunk)" "$P" "FAR_IN_SCOPE_MARKER_a1"
  assert_not_contains "$L: whole-file block has no out-of-scope file" "$P" '<file path="other/out.ts">'
  assert_contains "$L: prompt states the scope rule" "$P" "Review ONLY changes in these paths; other files are context"
  assert_contains "$L: prompt lists the pathspec" "$P" "  - src/"
  assert_contains "$L: prompt lists an in-scope file by name" "$P" "  - src/app.ts"
done
assert_eq "context.files.meta.json counts only in-scope files" "$(jq -r .included "$T/o1/context.files.meta.json")" "2"
assert_eq "kimi.meta.json: paths" "$(jq -c .paths "$T/o1/kimi.meta.json")" '["src/"]'
assert_eq "kimi.meta.json: paths_mode" "$(jq -r .paths_mode "$T/o1/kimi.meta.json")" "filtered"
assert_eq "glm.meta.json: paths_mode" "$(jq -r .paths_mode "$T/o1/glm.meta.json")" "filtered"

echo "── control: no --paths leaves prompts and meta unchanged ──"
cr "$T/o0" --base main --reviewers kimi,glm --timeout-kimi 30 --timeout-glm 30
K0="$(cat "$T/kimi.prompt")"
assert_contains "full-diff kimi prompt still sees out-of-scope code" "$K0" "OUT_SCOPE_MARKER_d4"
assert_contains "…and the doc NOTE fires" "$K0" "this diff touches documentation"
assert_not_contains "…and carries no scope statement" "$K0" "PATH-SCOPED"
assert_eq "…and meta.json has no paths key" "$(jq -r 'has("paths")' "$T/o0/kimi.meta.json")" "false"

echo "── doc_narrative_risk fires when the .md IS in scope ──"
cr "$T/o2" --base main --reviewers kimi --paths docs/ --timeout-kimi 30
assert_contains "docs/ in scope -> the doc NOTE appears" "$(cat "$T/kimi.prompt")" "this diff touches documentation"

echo "── agy prompt ──"
cr "$T/o3" --base main --reviewers antigravity --paths src/ --timeout-antigravity 30
AGY="$(cat "$T/agy.prompt" 2>/dev/null || echo MISSING)"
assert_contains "agy: in-scope hunk" "$AGY" "IN_SCOPE_MARKER_b2"
assert_not_contains "agy: no out-of-scope hunk" "$AGY" "OUT_SCOPE_MARKER_d4"
assert_not_contains "agy: no out-of-scope file in --stat" "$AGY" "other/out.ts"
assert_contains "agy: scope statement" "$AGY" "Review ONLY changes in these paths; other files are context"

echo "── tool loop: scope note ──"
( cd "$REPO" && CROSS_REVIEW_TOOL_MODE=read bash "$S/run_reviewers.sh" --base main --out "$T/o4" --reviewers glm --paths src/ --timeout-glm 60 >"$T/o4.log" 2>&1 )
TL="$(jq -r '.messages[0].content // "MISSING"' "$T/o4/glm.request.json" 2>/dev/null || echo MISSING)"
assert_eq "tool arm is on (context_access=tool_read)" "$(jq -r .context_access "$T/o4/glm.meta.json" 2>/dev/null)" "tool_read"
assert_contains "tool lane: may read any tracked file but findings are scoped" "$TL" "can read ANY tracked file for surrounding context, but this round is path-scoped"
assert_contains "tool lane: scope rule present" "$TL" "Review ONLY changes in these paths; other files are context"
assert_not_contains "tool lane: out-of-scope hunk not inlined" "$TL" "OUT_SCOPE_MARKER_d4"

echo "── codex: explicit prompt instead of --base ──"
cr "$T/o5" --base main --reviewers codex --paths src/ --timeout-codex 30
ARGV="$(cat "$T/codex.argv" 2>/dev/null || echo MISSING)"; STDIN="$(cat "$T/codex.stdin" 2>/dev/null || echo MISSING)"
assert_not_contains "codex: --base is NOT passed (it cannot be path-filtered)" "$ARGV" "--base"
assert_contains "codex: reads its prompt from stdin ('-')" "$(printf '%s\n' "$ARGV" | grep -x -- '-')" "-"
assert_contains "codex: workspace-write sandbox kept (workspace access)" "$ARGV" 'sandbox_mode="workspace-write"'
assert_contains "codex: prompt embeds the filtered diff" "$STDIN" "IN_SCOPE_MARKER_b2"
assert_not_contains "codex: prompt has no out-of-scope hunk" "$STDIN" "OUT_SCOPE_MARKER_d4"
assert_contains "codex: prompt states the scope rule" "$STDIN" "Review ONLY changes in these paths; other files are context"
assert_eq "codex.meta.json: paths_mode=explicit_prompt" "$(jq -r .paths_mode "$T/o5/codex.meta.json")" "explicit_prompt"
rm -f "$T/codex.argv" "$T/codex.stdin"
CROSS_REVIEW_CODEX_FORCE_BASE=1 cr "$T/o6" --base main --reviewers codex --paths src/ --timeout-codex 30
ARGV6="$(cat "$T/codex.argv" 2>/dev/null || echo MISSING)"
assert_contains "env escape: codex is forced back onto --base" "$ARGV6" "--base"
assert_eq "…and meta records paths_mode=base_unfiltered" "$(jq -r .paths_mode "$T/o6/codex.meta.json")" "base_unfiltered"
assert_contains "…with a WARN that it reviews the unfiltered diff" "$(cat "$T/o6.log")" "UNFILTERED"
rm -f "$T/codex.argv"
cr "$T/o7" --base main --reviewers codex --paths src/ --codex-force-base --timeout-codex 30
assert_contains "--codex-force-base flag does the same" "$(cat "$T/codex.argv" 2>/dev/null)" "--base"
rm -f "$T/codex.argv"
cr "$T/o8" --base main --reviewers codex --timeout-codex 30
assert_contains "no --paths: codex still runs 'exec review --base' exactly as before" "$(cat "$T/codex.argv" 2>/dev/null)" "--base"

echo "── run_reviewers: loud failures ──"
cr "$T/f1" --base main --reviewers kimi --paths nothing/ --timeout-kimi 30
assert_eq "empty filtered diff: exit 4 (not a silent skip)" "$(cat "$T/f1.rc")" "4"
assert_eq "…run.meta.json says why" "$(jq -r .reason "$T/f1/run.meta.json")" "no_diff_in_paths"
cr "$T/f2" --base synth --reviewers kimi --paths src/ --timeout-kimi 30
assert_eq "descendant base + --paths: exit 4" "$(cat "$T/f2.rc")" "4"
assert_eq "…reason base_not_ancestor" "$(jq -r .reason "$T/f2/run.meta.json")" "base_not_ancestor"
cr "$T/f3" --base main --reviewers kimi --paths src/ --paths /abs --timeout-kimi 30
assert_eq "an absolute pathspec is refused (exit 2)" "$(cat "$T/f3.rc")" "2"

echo "── run_reviewers: --paths read from context.json in the run dir ──"
RUNDIR="$(jq -r .run_dir <<<"$FILT")"
rm -f "$T/kimi.prompt"
( cd "$REPO" && bash "$S/run_reviewers.sh" --base main --out "$RUNDIR/raw" --reviewers kimi --timeout-kimi 30 >"$T/ctx.log" 2>&1 )
assert_contains "context.json paths picked up with no flag" "$(cat "$T/kimi.prompt" 2>/dev/null)" "Review ONLY changes in these paths"
assert_not_contains "…and applied" "$(cat "$T/kimi.prompt" 2>/dev/null)" "OUT_SCOPE_MARKER_d4"
rm -f "$T/kimi.prompt"
mkdir -p "$RUNDIR/raw3"
( cd "$REPO" && bash "$S/run_reviewers.sh" --base main --out "$RUNDIR/raw3" --reviewers kimi --no-paths --timeout-kimi 30 >"$T/ctx3.log" 2>&1 )
assert_contains "--no-paths ignores context.json" "$(cat "$T/kimi.prompt" 2>/dev/null)" "OUT_SCOPE_MARKER_d4"

echo "── repeat-pass guard: a path-scoped round has its own key ──"
G="$S/check_repeat_pass.sh"; SD="$T/guard"; mkdir -p "$SD"
common=(--project proj --branch pr-1 --state-dir "$SD")
bash "$G" "${common[@]}" --record --base-sha B --head-sha H1
ls "$SD" >"$T/keys.full"
assert_eq "full-diff record written (one file)" "$(wc -l <"$T/keys.full" | tr -d ' ')" "1"
flat="$(printf '%s' 'proj//pr-1' | tr -c 'A-Za-z0-9._-' '_')"
dig="$(printf '%s' 'proj//pr-1' | (shasum -a 256 2>/dev/null || sha256sum) | cut -c1-8)"
assert_eq "…and its key is byte-for-byte the old derivation" "$(cat "$T/keys.full")" "${flat}.${dig}.json"
bash "$G" "${common[@]}" --base-sha B --head-sha H2 >/dev/null 2>&1; assert_eq "full-diff repeat at same base is still blocked" "$?" "3"
bash "$G" "${common[@]}" --paths-hash aaa111 --base-sha B --head-sha H2 >/dev/null 2>&1
assert_eq "a path-scoped round of the same subject is NOT blocked by it" "$?" "0"
assert_eq "…and starts at pass 1 (codex keeps full effort)" "$(bash "$G" "${common[@]}" --paths-hash aaa111 --pass-context)" "1"
assert_eq "…while the full-diff round is on pass 2" "$(bash "$G" "${common[@]}" --pass-context)" "2"
bash "$G" "${common[@]}" --paths-hash aaa111 --record --base-sha B --head-sha H1
assert_eq "recording the scoped round makes a second file" "$(ls "$SD" | wc -l | tr -d ' ')" "2"
assert_eq "scoped pass-context now 2" "$(bash "$G" "${common[@]}" --paths-hash aaa111 --pass-context)" "2"
assert_eq "a DIFFERENT path set is isolated from it (pass 1)" "$(bash "$G" "${common[@]}" --paths-hash bbb222 --pass-context)" "1"
assert_eq "the full-diff count is untouched by the scoped record" "$(bash "$G" "${common[@]}" --pass-context)" "2"
bash "$G" "${common[@]}" --paths-hash aaa111 --base-sha B --head-sha H3 >/dev/null 2>&1
assert_eq "a scoped repeat at the same base IS blocked within its own key" "$?" "3"

echo "── repeat-pass guard via run_reviewers: end to end ──"
rm -rf "$T/state"
( cd "$REPO" && bash "$S/run_reviewers.sh" --base main --out "$T/g1" --reviewers kimi --subject-id pr-9 --timeout-kimi 30 >"$T/g1.log" 2>&1 )
( cd "$REPO" && bash "$S/run_reviewers.sh" --base main --out "$T/g2" --reviewers kimi --subject-id pr-9 --paths src/ --timeout-kimi 30 >"$T/g2.log" 2>&1 ); RC=$?
assert_eq "a scoped round after a full round of the same subject-id runs" "$RC" "0"
assert_eq "state dir holds two keys (full + scoped)" "$(ls "$T/state/last_base" | wc -l | tr -d ' ')" "2"

echo "── append_runlog / report_block carry the scope ──"
RUN_R="$T/run-r"; mkdir -p "$RUN_R/raw"
printf '{"started_at":"20260101T000000","paths":["src/"],"paths_hash":"%s","paths_mode":"filtered"}\n' \
  "$(jq -r .paths_hash <<<"$FILT")" >"$RUN_R/context.json"
cp "$T/o1/kimi.meta.json" "$RUN_R/raw/kimi.meta.json"
cp "$T/o6/codex.meta.json" "$RUN_R/raw/codex.meta.json"
LOGR="$T/runlog.jsonl"
CROSS_REVIEW_RUNLOG="$LOGR" bash "$S/append_runlog.sh" --run-dir "$RUN_R" --project p --base main --pr - --pass 1 \
  --verdict CLEAN --convergent 0 --top "-" >/dev/null 2>&1
E="$(tail -1 "$LOGR")"
assert_eq "runlog entry: paths" "$(jq -c .paths <<<"$E")" '["src/"]'
assert_eq "runlog entry: paths_hash" "$(jq -r .paths_hash <<<"$E")" "$(jq -r .paths_hash <<<"$FILT")"
assert_eq "runlog entry: a lane forced onto --base makes the round 'mixed'" "$(jq -r .paths_mode <<<"$E")" "mixed"
assert_eq "runlog entry: per-lane row keeps paths_mode" "$(jq -r .reviewers.kimi.paths_mode <<<"$E")" "filtered"
assert_eq "runlog entry: per-lane row does NOT repeat the paths array" "$(jq -r '.reviewers.kimi | has("paths")' <<<"$E")" "false"
assert_eq "runlog entry: schema_version unchanged (additive field)" "$(jq -r .schema_version <<<"$E")" "1"
RUN_N="$T/run-n"; mkdir -p "$RUN_N/raw"; cp "$T/o0/kimi.meta.json" "$RUN_N/raw/kimi.meta.json"
CROSS_REVIEW_RUNLOG="$T/runlog2.jsonl" bash "$S/append_runlog.sh" --run-dir "$RUN_N" --project p --base main --pr - --pass 1 --verdict CLEAN --convergent 0 --top "-" >/dev/null 2>&1
assert_eq "a full-diff entry has no paths keys" "$(tail -1 "$T/runlog2.jsonl" | jq -r 'has("paths") or has("paths_mode")')" "false"
echo '{"findings":[]}' >"$T/f.json"
RB="$(bash "$S/report_block.sh" --findings "$T/f.json" --pass 1 --verdict CLEAN --record r --next stop --paths 'src/')"
assert_contains "report_block --paths adds a Paths line" "$RB" "Paths:   src/"
RB0="$(bash "$S/report_block.sh" --findings "$T/f.json" --pass 1 --verdict CLEAN --record r --next stop)"
assert_not_contains "…and without it the block is unchanged" "$RB0" "Paths:"

echo "── plan_rounds.sh: deterministic grouping ──"
PR="$T/planrepo"; mkdir -p "$PR"
(
  cd "$PR" || exit 1
  git init -q -b main 2>/dev/null || git init -q
  git config user.email t@t; git config user.name t
  echo a >a.txt; git add -A; git commit -qm i; git checkout -qb feat
  mkdir -p apps/web apps/api libs/core docs
  seq 1 30 >apps/web/w.ts; seq 1 20 >apps/api/x.ts; seq 1 40 >apps/api/y.ts
  seq 1 10 >libs/core/c.ts; echo d >docs/README.md; echo r >root.txt
  git add -A; git commit -qm c
)
P1="$(cd "$PR" && bash "$S/plan_rounds.sh" --base main --ref feat --max-lines 45 --format json)"
P2="$(cd "$PR" && bash "$S/plan_rounds.sh" --base main --ref feat --max-lines 45 --format json)"
assert_eq "same diff -> byte-identical plan" "$P1" "$P2"
assert_eq "dir mode: 3 rounds under a 45-line budget" "$(jq '.rounds | length' <<<"$P1")" "3"
assert_eq "no round is over budget" "$(jq '[.rounds[] | select(.over_budget)] | length' <<<"$P1")" "0"
assert_eq "every changed file is in exactly one round (6)" "$(jq '[.rounds[].files] | add' <<<"$P1")" "6"
assert_eq "totals" "$(jq -c '[.total_files, .total_lines]' <<<"$P1")" "[6,102]"
assert_eq "a directory over budget is split by its next component (apps/api -> files)" \
  "$(jq -c '[.rounds[].paths[] | select(startswith("apps/api"))] | sort' <<<"$P1")" '["apps/api/x.ts","apps/api/y.ts"]'
PT="$(cd "$PR" && bash "$S/plan_rounds.sh" --base main --ref feat --max-lines 45 --group-by top --format json)"
assert_eq "top mode keeps apps/ whole and flags it over budget" \
  "$(jq -c '[.rounds[] | select(.over_budget) | .paths]' <<<"$PT")" '[["apps/"]]'
FLAGS="$(jq -r '.rounds[0].flags' <<<"$P1")"
assert_contains "each round carries a pasteable --paths string" "$FLAGS" "--paths '"
# a suggested set round-trips through worktree.sh
ONE="$(jq -r '.rounds[0].paths_arg' <<<"$P1")"
( cd "$PR" && bash "$S/worktree.sh" start --ref feat --base main --paths "$ONE" --id plan-rt >"$T/rt.out" 2>/dev/null ); RC=$?
assert_eq "a suggested --paths set is accepted by worktree.sh" "$RC" "0"
BOTH="$(cd "$PR" && bash "$S/plan_rounds.sh" --base main --ref feat 2>"$T/plan.err")"
assert_contains "default format: human table on stderr" "$(cat "$T/plan.err")" "round 1"
assert_eq "…and JSON on stdout" "$(jq -r .group_by <<<"$BOTH")" "dir"
( cd "$PR" && bash "$S/plan_rounds.sh" --base feat --ref main >/dev/null 2>"$T/plan2.err" ); RC=$?
assert_eq "plan_rounds refuses the descendant-base trap (exit 3)" "$RC" "3"
( cd "$PR" && bash "$S/plan_rounds.sh" --base main --ref main >/dev/null 2>&1 ); assert_eq "empty diff: exit 1" "$?" "1"

# ── pathspecs the shell or git would otherwise reinterpret (PR #199 pass 1) ──
# One fixture for three defects that all turned a pathspec into a different set
# of files without saying so: a wildcard expanded against the checkout, a comma
# inside a `--path` value split in two, and a filename starting with ":" read by
# git as pathspec magic.
ODD="$T/oddrepo"; mkdir -p "$ODD"
(
  cd "$ODD" || exit 1
  git init -q -b main 2>/dev/null || git init -q
  git config user.email t@t; git config user.name t
  mkdir -p src
  printf 'kept v1\n' >src/kept.ts
  printf 'gone 1\ngone 2\ngone 3\ngone 4\ngone 5\n' >src/gone.ts
  git add -A; git commit -qm init
  git checkout -qb feat
  mkdir -p dir ':odddir'
  printf 'kept v2\n' >src/kept.ts
  git rm -q src/gone.ts
  printf 'c1\nc2\nc3\n' >'dir/a,b.ts'
  printf 'odd\n' >':odd.txt'
  printf 'excl\n' >':(exclude)keep.txt'
  printf 'keep\n' >keep.txt
  printf 'inner\n' >':odddir/f.txt'
  printf 'q\n' >'q?.txt'
  git add -A; git commit -qm change
)
OWTS() { ( cd "$ODD" && bash "$S/worktree.sh" start --ref feat --base main "$@" ); }

echo "── a wildcard pathspec reaches git unexpanded ──"
assert_eq "cr_paths_normalise keeps src/*.ts when files in cwd match it" \
  "$(cd "$ODD" && cr_paths_normalise 'src/*.ts' | tr '\n' '|')" "src/*.ts|"
assert_eq "…so the paths hash does not depend on the checkout" \
  "$(cd "$ODD" && cr_paths_normalise 'src/*.ts' | cr_paths_hash)" "$(cd "$T" && cr_paths_normalise 'src/*.ts' | cr_paths_hash)"
GLOB="$(OWTS --paths 'src/*.ts' --id odd-glob 2>/dev/null)"
assert_eq "worktree.sh records the wildcard itself" "$(jq -c .paths <<<"$GLOB")" '["src/*.ts"]'
assert_eq "…and a file the change DELETED is still in the round (2 files)" "$(jq -r .size_files <<<"$GLOB")" "2"

echo "── --path keeps a comma; --paths still splits on one ──"
assert_eq "cr_paths_normalise_lines does not split on a comma" \
  "$(cr_paths_normalise_lines 'dir/a,b.ts' | tr '\n' '|')" "dir/a,b.ts|"
assert_eq "…and mixes with a comma list" \
  "$(cr_paths_normalise_lines "$(cr_paths_csv 'y/, x/')" 'dir/a,b.ts' | tr '\n' '|')" "dir/a,b.ts|x/|y/|"
COMMA="$(OWTS --path 'dir/a,b.ts' --id odd-comma 2>/dev/null)"
assert_eq "worktree.sh --path: one pathspec, comma intact" "$(jq -c .paths <<<"$COMMA")" '["dir/a,b.ts"]'
assert_eq "…matching the one file" "$(jq -r .size_files <<<"$COMMA")" "1"
OWTS --paths 'dir/a,b.ts' --id odd-comma-list >/dev/null 2>"$T/oddc.err"; RC=$?
assert_eq "worktree.sh --paths: the same value is two pathspecs, which match nothing (exit 3)" "$RC" "3"
CROSS_REVIEW_PATHS='src/kept.ts,keep.txt' OWTS --id odd-env >"$T/odde.out" 2>/dev/null
assert_eq "CROSS_REVIEW_PATHS is a comma list" "$(jq -c .paths "$T/odde.out")" '["keep.txt","src/kept.ts"]'
mkdir -p "$T/oc1"
( cd "$ODD" && bash "$S/run_reviewers.sh" --base main --out "$T/oc1" --reviewers kimi --path 'dir/a,b.ts' --timeout-kimi 30 >"$T/oc1.log" 2>&1 ); RC=$?
assert_eq "run_reviewers --path with a comma runs" "$RC" "0"
assert_eq "…and the lane meta records one pathspec" "$(jq -c .paths "$T/oc1/kimi.meta.json" 2>/dev/null)" '["dir/a,b.ts"]'
ODD_RUN="$(jq -r .run_dir <<<"$COMMA")"
( cd "$ODD" && bash "$S/run_reviewers.sh" --base main --out "$ODD_RUN/raw" --reviewers kimi --timeout-kimi 30 >"$T/oc2.log" 2>&1 ); RC=$?
assert_eq "the pathspec read back from context.json is not re-split" "$RC" "0"
assert_eq "…same single pathspec in the lane meta" "$(jq -c .paths "$ODD_RUN/raw/kimi.meta.json" 2>/dev/null)" '["dir/a,b.ts"]'

echo "── plan_rounds.sh: every suggested pathspec selects exactly its own files ──"
ODD_ALL="$(cd "$ODD" && git -c core.quotePath=false diff --no-renames --name-only main...feat | LC_ALL=C sort)"
for mode in "dir 1" "top 1000"; do
  OP="$(cd "$ODD" && bash "$S/plan_rounds.sh" --base main --ref feat --group-by "${mode% *}" --max-lines "${mode#* }" --format json)"
  GOT="$(cd "$ODD" && jq -r '.rounds[].paths[]' <<<"$OP" | while IFS= read -r spec; do
      git -c core.quotePath=false diff --no-renames --name-only main...feat -- "$spec"
    done | LC_ALL=C sort)"
  assert_eq "[$mode] the specs cover each changed file once, through git" "$GOT" "$ODD_ALL"
  # …and through the pasteable flags, into worktree.sh
  SUM=0; NR="$(jq '.rounds | length' <<<"$OP")"; i=0
  while [[ "$i" -lt "$NR" ]]; do
    eval "ARGS=($(jq -r ".rounds[$i].flags" <<<"$OP"))"
    N="$(OWTS "${ARGS[@]}" --id "odd-plan-${mode% *}-$i" 2>/dev/null | jq -r '.size_files // 0')"
    SUM=$((SUM + ${N:-0})); i=$((i + 1))
  done
  assert_eq "[$mode] the pasted flags add up to every changed file" "$SUM" "$(jq -r .total_files <<<"$OP")"
done
assert_contains "a leading-colon filename is made literal" \
  "$(cd "$ODD" && bash "$S/plan_rounds.sh" --base main --ref feat --group-by dir --max-lines 1 --format json | jq -c '[.rounds[].paths[]]')" '":(literal):odd.txt"'

echo
echo "══ test_paths: $PASS passed, $FAIL failed ══"
[[ "$FAIL" -eq 0 ]]
