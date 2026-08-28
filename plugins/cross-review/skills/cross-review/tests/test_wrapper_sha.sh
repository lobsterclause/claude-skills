#!/usr/bin/env bash
# test_wrapper_sha.sh — offline fixture tests for #144: stamping the
# REVIEWING INSTALL's own HEAD (wrapper_sha/wrapper_dirty/wrapper_branch)
# into context.json, the runlog, and the posted PR comment marker.
#
# Why this exists: a round launched from the shared symlinked install
# (~/.claude/skills/cross-review -> this repo's cross-review/) reviews with
# whatever branch the shared checkout happens to be on. On 2026-08-27 a PR
# review ran on an unpushed branch and hit a bug master does not have, and
# nothing recorded which wrapper did the reviewing.
#
# Standalone: run directly, or from run_tests.sh (auto-discovered via
# tests/test_*.sh). NO network, NO reviewer CLIs, NO tokens — everything is
# a fixture git repo and fixture JSON under a temp dir. `gh` is a PATH shim.
#
# Run:  bash tests/test_wrapper_sha.sh
# Exit: 0 all green, 1 any failure.
#
# Portability: macOS bash 3.2 + ubuntu bash 5; needs jq, git.

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
  if [[ "$2" != *"$3"* ]]; then ok "$1"; else bad "$1 (unexpectedly found '$3')"; fi
}

# ── fixture skill dir: a real git repo, standing in for the reviewing
# install's own checkout. Scripts are COPIED in (not symlinked) so
# "$(dirname "$0")/.." inside worktree.sh resolves to THIS fixture repo when
# invoked as "$SKILL/scripts/worktree.sh", independent of where the real
# checkout lives. ──────────────────────────────────────────────────────────
SKILL="$T/skill"
mkdir -p "$SKILL/scripts" "$SKILL/references"
cp "$S/worktree.sh" "$S/append_runlog.sh" "$S/analyze_runlog.sh" "$S/post_comment.sh" "$SKILL/scripts/"
cp "$SKILL_DIR/references/reviewer_profiles.json" "$SKILL/references/reviewer_profiles.json" 2>/dev/null || echo '{}' >"$SKILL/references/reviewer_profiles.json"
chmod +x "$SKILL/scripts/"*.sh

(
  cd "$SKILL" || exit 1
  git init -q
  git config user.email test@test.com
  git config user.name test
  echo skill >f.txt
  git add f.txt scripts references
  git commit -q -m "skill init"
  git branch -q -m master 2>/dev/null || true
)
SKILL_ANCESTOR_SHA="$(git -C "$SKILL" rev-parse HEAD)"
# Fake a remote-tracking origin/master pointed at the same commit, so ancestry
# checks against "origin/master" have something real to compare to, with no
# actual remote or network involved.
git -C "$SKILL" update-ref refs/remotes/origin/master "$SKILL_ANCESTOR_SHA"

# A second commit NOT reachable from origin/master — simulates an unpushed
# wrapper branch (the exact 2026-08-27 incident shape).
(
  cd "$SKILL" || exit 1
  git checkout -q -b feature-unpushed
  echo change >f.txt
  git add f.txt
  git commit -q -m "unpushed wrapper commit"
)
SKILL_NONANCESTOR_SHA="$(git -C "$SKILL" rev-parse HEAD)"
git -C "$SKILL" checkout -q master   # back to the ancestor commit for the first round of assertions

# ── fixture TARGET repo: what worktree.sh start reviews (separate from the
# skill dir above — worktree.sh must record ITS OWN repo's HEAD as
# wrapper_sha, not the target's). ──────────────────────────────────────────
TARGET="$T/target"
mkdir -p "$TARGET"
(
  cd "$TARGET" || exit 1
  git init -q
  git config user.email test@test.com
  git config user.name test
  echo hi >f.txt
  git add f.txt
  git commit -q -m init
  git branch -q -m master 2>/dev/null || true
)

WT_ROOT="$T/worktrees"
RUN_ROOT="$T/runs"

echo "── worktree.sh start: wrapper_sha/branch/dirty on a clean wrapper (#144) ──"
(
  cd "$TARGET" || exit 1
  git checkout -q feature-unpushed 2>/dev/null || true
) >/dev/null 2>&1
OUT_A="$(cd "$TARGET" && CROSS_REVIEW_WORKTREE_ROOT="$WT_ROOT" CROSS_REVIEW_RUN_ROOT="$RUN_ROOT" \
  bash "$SKILL/scripts/worktree.sh" start --ref HEAD --id wrap-a --base HEAD 2>"$T/wt-a.err")"
RUN_DIR_A="$(jq -r '.run_dir' <<<"$OUT_A")"
assert_eq "worktree.sh start: wrapper_sha (ancestor case) is the SKILL dir's HEAD, not the target's" \
  "$(jq -r '.wrapper_sha' <<<"$OUT_A")" "$SKILL_ANCESTOR_SHA"
assert_eq "worktree.sh start: wrapper_sha is 40 hex" \
  "$(jq -r '.wrapper_sha | test("^[0-9a-f]{40}$")' <<<"$OUT_A")" "true"
assert_eq "worktree.sh start: wrapper_branch is master (skill dir was left on master)" \
  "$(jq -r '.wrapper_branch' <<<"$OUT_A")" "master"
assert_eq "worktree.sh start: wrapper_dirty is false on a clean skill checkout" \
  "$(jq -r '.wrapper_dirty' <<<"$OUT_A")" "false"
assert_eq "worktree.sh start: context.json on disk matches stdout for wrapper_sha" \
  "$(jq -r '.wrapper_sha' "$RUN_DIR_A/context.json")" "$SKILL_ANCESTOR_SHA"

echo "── worktree.sh start: dirty wrapper flips wrapper_dirty (#144) ──"
echo dirty >>"$SKILL/f.txt"
OUT_B="$(cd "$TARGET" && CROSS_REVIEW_WORKTREE_ROOT="$WT_ROOT" CROSS_REVIEW_RUN_ROOT="$RUN_ROOT" \
  bash "$SKILL/scripts/worktree.sh" start --ref HEAD --id wrap-b --base HEAD 2>"$T/wt-b.err")"
RUN_DIR_B="$(jq -r '.run_dir' <<<"$OUT_B")"
assert_eq "worktree.sh start: touching a file under the skill dir -> wrapper_dirty=true" \
  "$(jq -r '.wrapper_dirty' <<<"$OUT_B")" "true"
assert_eq "worktree.sh start: wrapper_sha is unchanged by an uncommitted edit" \
  "$(jq -r '.wrapper_sha' <<<"$OUT_B")" "$SKILL_ANCESTOR_SHA"
git -C "$SKILL" checkout -q -- f.txt   # clean up for the rest of the fixture

echo "── worktree.sh start: skill dir on the unpushed (non-ancestor) commit (#144) ──"
git -C "$SKILL" checkout -q feature-unpushed
OUT_C="$(cd "$TARGET" && CROSS_REVIEW_WORKTREE_ROOT="$WT_ROOT" CROSS_REVIEW_RUN_ROOT="$RUN_ROOT" \
  bash "$SKILL/scripts/worktree.sh" start --ref HEAD --id wrap-c --base HEAD 2>"$T/wt-c.err")"
RUN_DIR_C="$(jq -r '.run_dir' <<<"$OUT_C")"
assert_eq "worktree.sh start: wrapper_sha follows the skill dir onto the unpushed commit" \
  "$(jq -r '.wrapper_sha' <<<"$OUT_C")" "$SKILL_NONANCESTOR_SHA"
assert_eq "worktree.sh start: wrapper_branch reflects the unpushed branch" \
  "$(jq -r '.wrapper_branch' <<<"$OUT_C")" "feature-unpushed"
assert_eq "worktree.sh start: wrapper_dirty is false again (clean checkout of feature-unpushed)" \
  "$(jq -r '.wrapper_dirty' <<<"$OUT_C")" "false"

echo "── worktree.sh start: skill dir is NOT a git checkout -> wrapper fields are null, start still succeeds (#144) ──"
NOGIT_SKILL="$T/skill-nogit"
mkdir -p "$NOGIT_SKILL/scripts"
cp "$SKILL/scripts/worktree.sh" "$NOGIT_SKILL/scripts/"
OUT_D="$(cd "$TARGET" && CROSS_REVIEW_WORKTREE_ROOT="$WT_ROOT" CROSS_REVIEW_RUN_ROOT="$RUN_ROOT" \
  bash "$NOGIT_SKILL/scripts/worktree.sh" start --ref HEAD --id wrap-d --base HEAD 2>"$T/wt-d.err")"
assert_eq "worktree.sh start: non-git skill dir -> wrapper_sha is JSON null" \
  "$(jq -r '.wrapper_sha' <<<"$OUT_D")" "null"
# A skill dir that merely sits UNTRACKED inside someone else's repo is not a
# wrapper checkout either (#148 pass 1: a zip-extracted skill under a tracked
# ~/.dotfiles must not report the dotfiles' HEAD, nor read as dirty).
NEST="$T/nest"; mkdir -p "$NEST"; git -C "$NEST" init -q -b main
git -C "$NEST" -c user.email=t@t -c user.name=t commit -q --allow-empty -m outer
mkdir -p "$NEST/skill/scripts"; cp "$S/worktree.sh" "$NEST/skill/scripts/"
OUT_E="$(cd "$TARGET" && CROSS_REVIEW_WORKTREE_ROOT="$WT_ROOT" CROSS_REVIEW_RUN_ROOT="$RUN_ROOT" \
  bash "$NEST/skill/scripts/worktree.sh" start --ref HEAD --id wrap-e --base HEAD 2>"$T/wt-e.err")"
assert_eq "worktree.sh start: untracked skill dir inside another repo -> wrapper_sha is JSON null" \
  "$(jq -r '.wrapper_sha' <<<"$OUT_E")" "null"
assert_eq "worktree.sh start: untracked skill dir inside another repo -> wrapper_dirty is JSON null" \
  "$(jq -r '.wrapper_dirty' <<<"$OUT_E")" "null"
assert_eq "worktree.sh start: non-git skill dir -> wrapper_dirty is JSON null" \
  "$(jq -r '.wrapper_dirty' <<<"$OUT_D")" "null"
assert_eq "worktree.sh start: non-git skill dir -> wrapper_branch is JSON null" \
  "$(jq -r '.wrapper_branch' <<<"$OUT_D")" "null"
assert_eq "worktree.sh start: still records a real head_sha for the TARGET repo despite no wrapper" \
  "$(jq -r '.head_sha | test("^[0-9a-f]{40}$")' <<<"$OUT_D")" "true"

echo "── append_runlog.sh: copies wrapper_sha/dirty/branch from context.json (#144) ──"
mkdir -p "$RUN_DIR_A/raw"
printf '{"exit_code":0,"duration_s":10,"timed_out":false,"output_bytes":50,"attempt":1,"timeout_budget_s":300}\n' >"$RUN_DIR_A/raw/codex.meta.json"
LOG_A="$T/log-a.jsonl"
CROSS_REVIEW_RUNLOG="$LOG_A" bash "$SKILL/scripts/append_runlog.sh" \
  --run-dir "$RUN_DIR_A" --project test --base main --pr - --pass 1 \
  --verdict CLEAN --convergent 0 --top "-" \
  --profiles "$SKILL/references/reviewer_profiles.json" >/dev/null 2>"$T/append-a.err"
ENTRY_A="$(tail -1 "$LOG_A")"
assert_eq "append_runlog.sh: wrapper_sha copied verbatim from context.json" \
  "$(jq -r '.wrapper_sha' <<<"$ENTRY_A")" "$SKILL_ANCESTOR_SHA"
assert_eq "append_runlog.sh: wrapper_branch copied verbatim" \
  "$(jq -r '.wrapper_branch' <<<"$ENTRY_A")" "master"
assert_eq "append_runlog.sh: wrapper_dirty copied as a real JSON boolean, not a string" \
  "$(jq -r '.wrapper_dirty | type' <<<"$ENTRY_A")" "boolean"
assert_eq "append_runlog.sh: wrapper_dirty value is false" \
  "$(jq -r '.wrapper_dirty' <<<"$ENTRY_A")" "false"

echo "── append_runlog.sh: no context.json wrapper fields -> entry has none of the three keys (never fabricated) ──"
NOWRAP_RUN="$T/nowrap-run"; mkdir -p "$NOWRAP_RUN/raw"
printf '{"exit_code":0,"duration_s":10,"timed_out":false,"output_bytes":50,"attempt":1,"timeout_budget_s":300}\n' >"$NOWRAP_RUN/raw/codex.meta.json"
printf '{"head_sha":"%s","base_sha":"%s","started_at":"%s"}\n' \
  "$SKILL_ANCESTOR_SHA" "$SKILL_ANCESTOR_SHA" "$(date -u +%Y%m%dT%H%M%S)" >"$NOWRAP_RUN/context.json"
LOG_NOWRAP="$T/log-nowrap.jsonl"
CROSS_REVIEW_RUNLOG="$LOG_NOWRAP" bash "$SKILL/scripts/append_runlog.sh" \
  --run-dir "$NOWRAP_RUN" --project test --base main --pr - --pass 1 \
  --verdict CLEAN --convergent 0 --top "-" \
  --profiles "$SKILL/references/reviewer_profiles.json" >/dev/null 2>"$T/append-nowrap.err"
ENTRY_NOWRAP="$(tail -1 "$LOG_NOWRAP")"
assert_eq "append_runlog.sh: context.json without wrapper keys -> no wrapper_sha key at all" \
  "$(jq -r 'has("wrapper_sha")' <<<"$ENTRY_NOWRAP")" "false"
assert_eq "append_runlog.sh: context.json without wrapper keys -> no wrapper_dirty key at all" \
  "$(jq -r 'has("wrapper_dirty")' <<<"$ENTRY_NOWRAP")" "false"
assert_eq "append_runlog.sh: context.json without wrapper keys -> no wrapper_branch key at all" \
  "$(jq -r 'has("wrapper_branch")' <<<"$ENTRY_NOWRAP")" "false"

echo "── analyze_runlog.sh --mode warn: non-ancestor wrapper WARN (#144) ──"
# Build a runlog with 3 entries carrying wrapper_sha: 2 on the unpushed
# (non-ancestor) commit, 1 on the ancestor commit — all clean.
WARN_LOG="$T/warn-log.jsonl"
mk_entry() {  # <wrapper_sha> <wrapper_branch> <wrapper_dirty>
  jq -nc --arg ts "2026-08-27T00:00:0${4:-0}Z" --arg wsha "$1" --arg wbranch "$2" --argjson wdirty "$3" \
    '{ts: $ts, schema_version: 1, project: "p", base: "main", pr: null, pass: 1,
      reviewers: {codex: {status:"ok"}}, convergent_count: 0, verdict: "CLEAN",
      wrapper_sha: $wsha, wrapper_branch: $wbranch, wrapper_dirty: $wdirty}'
}
{
  mk_entry "$SKILL_NONANCESTOR_SHA" "feature-unpushed" false 1
  mk_entry "$SKILL_NONANCESTOR_SHA" "feature-unpushed" true 2
  mk_entry "$SKILL_ANCESTOR_SHA" "master" false 3
} >"$WARN_LOG"
WARN_OUT="$(CROSS_REVIEW_RUNLOG="$WARN_LOG" bash "$SKILL/scripts/analyze_runlog.sh" --recent 10 --mode warn 2>&1)"
assert_contains "analyze_runlog warn: non-ancestor WARN names the count and window" \
  "$WARN_OUT" "wrapper: 2 of last 3 rounds ran on a wrapper that is not an ancestor of origin/master"
assert_contains "analyze_runlog warn: non-ancestor WARN names the sha7" \
  "$WARN_OUT" "${SKILL_NONANCESTOR_SHA:0:7}"
assert_contains "analyze_runlog warn: non-ancestor WARN names the branch" \
  "$WARN_OUT" "branch feature-unpushed"
assert_contains "analyze_runlog warn: dirty-wrapper WARN names the count and window" \
  "$WARN_OUT" "wrapper: 1 of last 3 rounds ran on a DIRTY wrapper"
# A malformed wrapper_sha never reaches git and never counts (#148 pass 1).
BAD_LOG="$T/bad-log.jsonl"
{ cat "$WARN_LOG"; mk_entry "--all" "evil" false 4; } >"$BAD_LOG"
BAD_OUT="$(CROSS_REVIEW_RUNLOG="$BAD_LOG" bash "$SKILL/scripts/analyze_runlog.sh" --recent 10 --mode warn 2>&1)"
assert_contains "analyze_runlog warn: a malformed wrapper_sha is skipped, counts unchanged" \
  "$BAD_OUT" "wrapper: 2 of last 3 rounds ran on a wrapper that is not an ancestor of origin/master"

echo "── analyze_runlog.sh --mode warn: all-ancestor, all-clean wrapper window is silent (#144) ──"
CLEAN_LOG="$T/clean-log.jsonl"
{
  mk_entry "$SKILL_ANCESTOR_SHA" "master" false 1
  mk_entry "$SKILL_ANCESTOR_SHA" "master" false 2
} >"$CLEAN_LOG"
CLEAN_OUT="$(CROSS_REVIEW_RUNLOG="$CLEAN_LOG" bash "$SKILL/scripts/analyze_runlog.sh" --recent 10 --mode warn --quiet 2>&1)"
assert_not_contains "analyze_runlog warn: clean ancestor window emits no wrapper WARN" \
  "$CLEAN_OUT" "wrapper:"

echo "── analyze_runlog.sh --mode report: wrapper distribution (#144) ──"
REPORT_OUT="$(CROSS_REVIEW_RUNLOG="$WARN_LOG" bash "$SKILL/scripts/analyze_runlog.sh" --recent 10 --mode report 2>&1)"
assert_contains "analyze_runlog report: wrapper audit section present" \
  "$REPORT_OUT" "wrapper audit"
assert_contains "analyze_runlog report: distribution names the non-ancestor sha7 with count 2" \
  "$REPORT_OUT" "${SKILL_NONANCESTOR_SHA:0:7} → 2"
assert_contains "analyze_runlog report: dirty count line" \
  "$REPORT_OUT" "dirty: 1 of 3"

echo "── post_comment.sh --mode summary: wrapper sha appears in the posted marker (#144) ──"
mkdir -p "$T/bin"
cat >"$T/bin/gh" <<'SH'
#!/bin/bash
case "$1 $2" in
  "auth status") exit 0 ;;
  "pr view")
      case "$*" in
        *comments*)
            jqexpr=""; prev=""
            for a in "$@"; do [ "$prev" = "--jq" ] && jqexpr="$a"; prev="$a"; done
            if [ -n "$jqexpr" ]; then printf '%s' "${CR_TEST_COMMENTS:-{\"comments\":[]\}}" | jq -r "$jqexpr"
            else printf '%s\n' "${CR_TEST_COMMENTS:-{\"comments\":[]\}}"; fi ;;
        *) printf '{"headRefOid":"%s","state":"OPEN"}\n' "${CR_TEST_HEAD_SHA:-}" ;;
      esac
      exit 0 ;;
  "pr comment")
      while [ $# -gt 0 ]; do
        if [ "$1" = "--body-file" ]; then cp "$2" "$CR_TEST_CAPTURE"; fi
        shift
      done
      exit 0 ;;
esac
exit 0
SH
chmod +x "$T/bin/gh"

PC_RUN="$T/pc-run"; mkdir -p "$PC_RUN"
PC_FIND="$PC_RUN/findings.md"
printf '# findings\n\nnothing to report\n' >"$PC_FIND"
cp "$RUN_DIR_A/context.json" "$PC_RUN/context.json"
HEAD_SHA_40="0123456789abcdef0123456789abcdef01234567"
CAPTURE="$T/pc-capture.md"
: >"$CAPTURE"
PATH="$T/bin:$PATH" CR_TEST_HEAD_SHA="$HEAD_SHA_40" CR_TEST_CAPTURE="$CAPTURE" \
  bash "$SKILL/scripts/post_comment.sh" --pr 1 --mode summary --findings "$PC_FIND" \
  --head-sha "$HEAD_SHA_40" >/dev/null 2>"$T/pc.err"
assert_contains "post_comment.sh: marker still carries sha=<40hex> pass=<n> (byte-stable prefix)" \
  "$(cat "$CAPTURE")" "<!-- cross-review: sha=${HEAD_SHA_40} pass=1"
assert_contains "post_comment.sh: marker line carries the wrapper sha" \
  "$(cat "$CAPTURE")" "wrapper=${SKILL_ANCESTOR_SHA}"

echo "── post_comment.sh: the next pass is derived from a wrapper-bearing marker (#148 pass 1) ──"
CAPTURE3="$T/pc-capture3.md"; : >"$CAPTURE3"
PRIOR_COMMENTS="$(jq -nc --arg m "<!-- cross-review: sha=${HEAD_SHA_40} pass=1 wrapper=${SKILL_ANCESTOR_SHA} -->" '{comments:[{body:("## Cross-review — pass 1\n" + $m)}]}')"
PATH="$T/bin:$PATH" CR_TEST_HEAD_SHA="$HEAD_SHA_40" CR_TEST_CAPTURE="$CAPTURE3" CR_TEST_COMMENTS="$PRIOR_COMMENTS" \
  bash "$SKILL/scripts/post_comment.sh" --pr 1 --mode summary --findings "$PC_FIND" \
  --head-sha "$HEAD_SHA_40" >/dev/null 2>"$T/pc3.err"
assert_contains "post_comment.sh: a prior wrapper-bearing pass=1 marker yields pass=2" \
  "$(cat "$CAPTURE3")" "<!-- cross-review: sha=${HEAD_SHA_40} pass=2 wrapper="

echo "── post_comment.sh --mode summary: no context.json wrapper_sha -> marker unchanged, no wrapper token ──"
PC_RUN2="$T/pc-run2"; mkdir -p "$PC_RUN2"
PC_FIND2="$PC_RUN2/findings.md"
printf '# findings\n\nnothing to report\n' >"$PC_FIND2"
CAPTURE2="$T/pc-capture2.md"
: >"$CAPTURE2"
PATH="$T/bin:$PATH" CR_TEST_HEAD_SHA="$HEAD_SHA_40" CR_TEST_CAPTURE="$CAPTURE2" \
  bash "$SKILL/scripts/post_comment.sh" --pr 1 --mode summary --findings "$PC_FIND2" \
  --head-sha "$HEAD_SHA_40" >/dev/null 2>"$T/pc2.err"
assert_contains "post_comment.sh: marker present even with no context.json" \
  "$(cat "$CAPTURE2")" "<!-- cross-review: sha=${HEAD_SHA_40} pass=1 -->"
assert_not_contains "post_comment.sh: no wrapper token when context.json has none" \
  "$(cat "$CAPTURE2")" "wrapper="

echo "── validate_ledgers.sh: accepts a runlog row carrying wrapper_sha/dirty/branch (#144) ──"
if [[ -x "$SKILL_DIR/scripts/validate_ledgers.sh" ]]; then
  VL_LOG="$T/vl-log.jsonl"
  mk_entry "$SKILL_ANCESTOR_SHA" "master" false 1 >"$VL_LOG"
  VL_EVENTS="$T/vl-events.jsonl"
  : >"$VL_EVENTS"
  VL_OUT="$(CROSS_REVIEW_RUNLOG="$VL_LOG" CROSS_REVIEW_FINDING_EVENTS="$VL_EVENTS" \
    bash "$SKILL_DIR/scripts/validate_ledgers.sh" 2>&1)"
  VL_RC=$?
  assert_eq "validate_ledgers.sh: exits 0 with wrapper_* keys present" "$VL_RC" "0"
else
  bad "validate_ledgers.sh not found or not executable at $SKILL_DIR/scripts/validate_ledgers.sh"
fi

echo
echo "── summary ──"
echo "pass=$PASS fail=$FAIL"
if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
exit 0
