#!/usr/bin/env bash
# test_repeat_pass_guard.sh — offline fixture test for scripts/check_repeat_pass.sh.
# NO network, no reviewer CLIs, no git repo required: the guard takes the base
# and head SHAs as arguments so its logic can be exercised deterministically.
#
# What it pins: a pass >= 2 that reuses the SAME base as the previous pass is a
# full re-review of code already reviewed. SKILL.md's re-review loop mandates
# passing the previous pass's HEAD as --base; measured 2026-08-29, 29% of
# August's multi-pass rounds ignored it (43 PRs; 162,929 diff lines re-read).
# That rule was prose, so it was advisory. This guard makes it binding.
#
# Run:  bash tests/test_repeat_pass_guard.sh
# Exit: 0 all green, 1 any failure.

set -uo pipefail

SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
GUARD="$SKILL_DIR/scripts/check_repeat_pass.sh"

PASS=0
FAIL=0
ok()  { echo "  ok   $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL $1"; FAIL=$((FAIL + 1)); }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
STATE="$TMP/state"

[[ -x "$GUARD" || -f "$GUARD" ]] || { echo "FATAL: $GUARD missing"; exit 1; }

# run_guard <expected_rc> <label> [extra args...]
run_guard() {
  local want="$1" label="$2"; shift 2
  local out rc
  out="$(bash "$GUARD" --state-dir "$STATE" "$@" 2>&1)"; rc=$?
  if [[ "$rc" == "$want" ]]; then ok "$label"; else
    bad "$label (rc=$rc want=$want)"; echo "      out: ${out//$'\n'/ | }"
  fi
}

BASE1=1111111111111111111111111111111111111111
BASE2=2222222222222222222222222222222222222222
HEAD1=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
HEAD2=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb

echo "── first pass on a fresh branch is always allowed ──"
run_guard 0 "no prior state -> proceed" \
  --project demo --branch feat/x --base-sha "$BASE1" --head-sha "$HEAD1"

echo "── recording a pass ──"
run_guard 0 "--record writes state" \
  --record --project demo --branch feat/x --base-sha "$BASE1" --head-sha "$HEAD1"
if [[ -n "$(find "$STATE" -type f 2>/dev/null)" ]]; then ok "state file created"
else bad "state file created"; fi

echo "── the defect: pass 2 reusing pass 1's base ──"
run_guard 3 "same base + moved HEAD -> BLOCKED (full re-review)" \
  --project demo --branch feat/x --base-sha "$BASE1" --head-sha "$HEAD2"

echo "── the guard must not fire on legitimate shapes ──"
run_guard 0 "base advanced to prior HEAD -> allowed (incremental)" \
  --project demo --branch feat/x --base-sha "$HEAD1" --head-sha "$HEAD2"
run_guard 0 "same base + UNMOVED HEAD -> allowed (retry after a failed round)" \
  --project demo --branch feat/x --base-sha "$BASE1" --head-sha "$HEAD1"
run_guard 0 "different branch, same base -> allowed (every PR shares origin/develop)" \
  --project demo --branch feat/other --base-sha "$BASE1" --head-sha "$HEAD2"
run_guard 0 "different project, same branch+base -> allowed" \
  --project other --branch feat/x --base-sha "$BASE1" --head-sha "$HEAD2"
run_guard 0 "unrelated base -> allowed" \
  --project demo --branch feat/x --base-sha "$BASE2" --head-sha "$HEAD2"

echo "── the escape hatch (SKILL.md: fixes structural enough to invalidate context) ──"
out="$(CROSS_REVIEW_ALLOW_FULL_REREVIEW=1 bash "$GUARD" --state-dir "$STATE" \
  --project demo --branch feat/x --base-sha "$BASE1" --head-sha "$HEAD2" 2>&1)"; rc=$?
if [[ "$rc" == 0 ]]; then ok "CROSS_REVIEW_ALLOW_FULL_REREVIEW=1 overrides the block"
else bad "override (rc=$rc want=0)"; fi
run_guard 0 "--allow-full-rereview flag overrides the block" \
  --allow-full-rereview --project demo --branch feat/x --base-sha "$BASE1" --head-sha "$HEAD2"

echo "── stale state must not block forever ──"
run_guard 0 "record older than the window -> allowed" \
  --window-hours 0 --project demo --branch feat/x --base-sha "$BASE1" --head-sha "$HEAD2"

echo "── the block must name the base the caller should have used ──"
out="$(bash "$GUARD" --state-dir "$STATE" --project demo --branch feat/x \
  --base-sha "$BASE1" --head-sha "$HEAD2" 2>&1)"
if grep -q "$HEAD1" <<< "$out"; then ok "message names the previous HEAD as the correct --base"
else bad "message names the previous HEAD (got: ${out//$'\n'/ | })"; fi

echo "── a branch name with slashes must not escape the state dir ──"
run_guard 0 "--record with a slashed branch name" \
  --record --project demo --branch "feat/a/b/c" --base-sha "$BASE1" --head-sha "$HEAD1"
run_guard 3 "slashed branch key round-trips" \
  --project demo --branch "feat/a/b/c" --base-sha "$BASE1" --head-sha "$HEAD2"
if [[ -z "$(find "$STATE" -mindepth 2 -type d 2>/dev/null)" ]]; then
  ok "no nested directories created from the branch name"
else bad "branch name created nested directories"; fi

echo "── --pass-context: the pass number the effort ladder reads ──"
# pc <label> <want> [args...] — asserts the printed answer AND that a query
# never gates: --pass-context must exit 0 even where the gate would exit 3.
pc() {
  local label="$1" want="$2"; shift 2
  local got rc
  got="$(bash "$GUARD" --pass-context --state-dir "$STATE" "$@" 2>/dev/null)"; rc=$?
  if [[ "$got" == "$want" && "$rc" -eq 0 ]]; then ok "$label"
  else bad "$label (got='$got' rc=$rc want='$want' rc=0)"; fi
}

# It reports the round ABOUT TO RUN, not the one last recorded: feat/x has one
# recorded pass above, so the next round is pass 2.
pc "unreviewed branch -> 1"            1 --project demo --branch feat/never
pc "one recorded pass -> next is 2"    2 --project demo --branch feat/x
pc "a sibling branch is still 1"       1 --project demo --branch feat/other
pc "a different project is 1"          1 --project other --branch feat/x
# Staleness is the gate's own rule, reused: a record past the window is not
# evidence of a prior pass, so a revisit days later pays full effort again.
pc "a stale record -> 1"               1 --project demo --branch feat/x --window-hours 0
# The query must answer even for a branch the gate would BLOCK — the caller
# reads it on exactly that path, and an exit 3 here would abort the round.
pc "queries the blocked shape, does not block" 2 --project demo --branch feat/x
# A missing state dir must not make the query fail; effort just stays default.
pc "absent state dir -> 1, not an error" 1 --project demo --branch feat/x --state-dir "$TMP/nonexistent"

# The counter has to keep climbing across rounds — a dial that reads "2"
# forever would never reach the pass-3+ step where the measured waste is.
COUNT_STATE="$TMP/count_state"
pc_at() { bash "$GUARD" --pass-context --state-dir "$COUNT_STATE" --project c --branch feat/c 2>/dev/null; }
rec_at() { bash "$GUARD" --record --state-dir "$COUNT_STATE" --project c --branch feat/c \
             --base-sha "$1" --head-sha "$2" >/dev/null 2>&1; }
seq_got=""
for i in 1 2 3 4; do
  seq_got="$seq_got$(pc_at)"
  rec_at "base$i" "head$i"
done
if [[ "$seq_got" == "1234" ]]; then ok "the counter climbs across rounds (1,2,3,4)"
else bad "counter sequence (got='$seq_got' want='1234')"; fi

# A record written before the counter existed is still evidence of one pass.
# --state-dir is used verbatim (the /last_base suffix is only appended to the
# DEFAULT), so the record files sit directly in it.
LEGACY="$TMP/legacy_state"
mkdir -p "$LEGACY"
LK="$(ls "$COUNT_STATE" | head -1)"
printf '{"project":"c","branch":"feat/c","base_sha":"b","head_sha":"h","epoch":%s}\n' \
  "$(date +%s)" > "$LEGACY/$LK"
got="$(bash "$GUARD" --pass-context --state-dir "$LEGACY" --project c --branch feat/c 2>/dev/null)"
if [[ "$got" == "2" ]]; then ok "a record with no counter reads as one prior pass"
else bad "legacy record (got='$got' want='2')"; fi

# Garbage in the counter must not produce a garbage pass number.
printf '{"project":"c","branch":"feat/c","base_sha":"b","head_sha":"h","epoch":%s,"passes":"nope"}\n' \
  "$(date +%s)" > "$LEGACY/$LK"
got="$(bash "$GUARD" --pass-context --state-dir "$LEGACY" --project c --branch feat/c 2>/dev/null)"
if [[ "$got" == "2" ]]; then ok "a non-numeric counter falls back, not crashes"
else bad "corrupt counter (got='$got' want='2')"; fi

# ── integration: the guard must stop run_reviewers.sh BEFORE it dispatches ──
#
# Regression pin. The first wiring used `if ! bash "$guard"; then _grc=$?`,
# where $? is the NEGATED status (0), not the guard's exit code — so a blocked
# round printed "REFUSING", then reported "guard returned 0 — continuing", and
# dispatched every reviewer anyway. The unit tests above all passed while the
# integration was inert: the guard was correct and the caller ignored it.
#
# Offline by construction: if the guard works, no reviewer is ever reached.
# ── the guard has to work where cross-review actually runs: DETACHED ──
#
# This is the pin the whole --subject-id flag exists for. Cross-review reviews
# inside a worktree, and a worktree is on a detached HEAD, where
# `git branch --show-current` prints NOTHING and exits 0. With no branch there
# is no state key: the gate could not fire, --record wrote nothing, and
# --pass-context answered 1 forever, so the codex effort ladder sat at default
# effort on every pass. #166 and #168 both shipped inert in production for this
# reason, and every test passed the whole time — because tests run on a branch.
#
# So these run on a real detached HEAD. A test for a detached-HEAD bug that
# checks out a branch first is testing the case that already worked.
echo "── detached HEAD: identity must come from --subject-id, not from git ──"
DET="$TMP/detached"; mkdir -p "$DET"
(
  cd "$DET" || exit 1
  git init -q . && git config user.email t@t && git config user.name t
  echo a > f.txt && git add f.txt && git commit -qm one
  git checkout -q --detach HEAD
) >/dev/null 2>&1

if [[ "$(cd "$DET" && git branch --show-current 2>/dev/null; echo "rc=$?")" == "rc=0" ]]; then
  ok "precondition: git names no branch on a detached HEAD (and exits 0)"
else bad "precondition: detached HEAD fixture"; fi

DST="$TMP/det_state"
det() { (cd "$DET" && bash "$GUARD" --state-dir "$DST" "$@" 2>/dev/null); }

# Without an identity the guard cannot key anything — that is the bug, pinned
# so a future change cannot quietly reintroduce it while looking fixed.
det --record --base-sha aaa --head-sha bbb >/dev/null 2>&1
if [[ -z "$(ls "$DST" 2>/dev/null)" ]]; then
  ok "detached + no identity: nothing is recorded (the defect, pinned)"
else bad "detached + no identity should record nothing"; fi

# With one, everything works — and the counter must CLIMB, or the ladder can
# never reach its pass-3 step.
seq_det=""
for i in 1 2 3; do
  seq_det="$seq_det$(det --pass-context --branch pr-42)"
  det --record --branch pr-42 --base-sha "b$i" --head-sha "h$i" >/dev/null 2>&1
done
if [[ "$seq_det" == "123" ]]; then ok "detached + --subject-id: pass counter climbs 1,2,3"
else bad "detached counter (got='$seq_det' want='123')"; fi

# Two PRs reviewed detached must not share a key. This is why a literal
# "detached" would have been the wrong fix: they also share a base, so the
# guard would start refusing unrelated PRs.
if [[ "$(det --pass-context --branch pr-99)" == "1" ]]; then
  ok "a second subject on a detached HEAD gets its own key"
else bad "detached subjects must not collide"; fi

echo "── integration: run_reviewers.sh honours the block ──"
RR="$SKILL_DIR/scripts/run_reviewers.sh"
if [[ -f "$RR" ]] && command -v git >/dev/null 2>&1; then
  REPO="$TMP/repo"
  mkdir -p "$REPO"
  (
    cd "$REPO" || exit 1
    git init -q . && git config user.email t@t && git config user.name t
    echo one > f.txt && git add f.txt && git commit -qm base
    git rev-parse HEAD > "$TMP/base_sha"
    git checkout -qb feat/guard && echo two >> f.txt && git commit -qam fix1
    git rev-parse HEAD > "$TMP/head1"
  ) >/dev/null 2>&1
  B="$(cat "$TMP/base_sha")"; H1="$(cat "$TMP/head1")"

  export CROSS_REVIEW_STATE_DIR="$TMP/integ_state"
  bash "$GUARD" --record --project repo --branch feat/guard     --base-sha "$B" --head-sha "$H1" >/dev/null 2>&1
  # a fix commit lands, then the caller wrongly re-uses the original base
  (cd "$REPO" && echo three >> f.txt && git commit -qam fix2) >/dev/null 2>&1

  out="$(cd "$REPO" && timeout 60 bash "$RR" --base "$B" --out "$TMP/integ_out" \
        --reviewers codex 2>&1)"; rc=$?
  if [[ "$rc" -eq 3 ]]; then ok "run_reviewers.sh exits 3 on a blocked repeat pass"
  else bad "run_reviewers.sh exit (rc=$rc want=3)"; echo "      out: ${out//$'"'"'\n'"'"'/ | }"; fi

  if grep -q "repeat_pass_same_base" "$TMP/integ_out/run.meta.json" 2>/dev/null; then
    ok "run.meta.json records reason=repeat_pass_same_base"
  else bad "run.meta.json reason"; fi

  # The whole point: nothing was spent.
  if [[ -z "$(find "$TMP/integ_out" -name '*.stdout' 2>/dev/null)" ]]; then
    ok "no reviewer was dispatched"
  else bad "a reviewer was dispatched despite the block"; fi
  unset CROSS_REVIEW_STATE_DIR

  # ── the effort dial reaches the codex argv (not just the variable) ──
  #
  # The dial is worth nothing if it stops at a shell variable, so assert on
  # what codex is actually invoked with. A stub named `codex` on PATH records
  # its argv and exits 0; no network, no real reviewer.
  BIN="$TMP/bin"; mkdir -p "$BIN"
  cat > "$BIN/codex" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$CODEX_ARGV_OUT"
echo "Critical: stub finding at f.txt:1"
STUB
  chmod +x "$BIN/codex"

  effort_run() {  # effort_run <state_dir> <argv_out> [extra run_reviewers args]
    local sd="$1" argv_out="$2"; shift 2
    # run_reviewers diffs the CURRENT repo — it must run from inside $REPO,
    # not from the harness's cwd, or it short-circuits before dispatching.
    (cd "$REPO" && CROSS_REVIEW_STATE_DIR="$sd" CODEX_ARGV_OUT="$argv_out" PATH="$BIN:$PATH" \
      timeout 120 bash "$RR" --base "$B" --out "$(mktemp -d)" \
        --reviewers codex --timeout-codex 30 "$@") >/dev/null 2>&1
  }

  # Pass 1: no record for this branch, so nothing is pinned and codex inherits
  # ~/.codex/config.toml — the pre-existing behaviour, unchanged.
  effort_run "$TMP/eff_state1" "$TMP/argv1"
  if [[ -f "$TMP/argv1" ]] && ! grep -q model_reasoning_effort "$TMP/argv1"; then
    ok "pass 1 leaves reasoning effort to the config"
  else
    bad "pass 1 must not pin effort"; echo "      argv: $(tr '\n' ' ' < "$TMP/argv1" 2>/dev/null)"
  fi

  # Pass 2: the round above recorded this branch, so the fix check steps down
  # one notch — still productive work, so not further than `high`.
  (cd "$REPO" && echo four >> f.txt && git commit -qam fix3) >/dev/null 2>&1
  effort_run "$TMP/eff_state1" "$TMP/argv2" --base "$H1"
  if grep -q 'model_reasoning_effort="high"' "$TMP/argv2" 2>/dev/null; then
    ok "pass 2 steps codex down to high"
  else
    bad "pass 2 effort"; echo "      argv: $(tr '\n' ' ' < "$TMP/argv2" 2>/dev/null)"
  fi

  # Pass 3: where the measured waste is — 57% of pass 3+ was codex confirming
  # its own verdict. The ladder must actually REACH this step; a dial stuck at
  # "repeat" would sit on `high` forever and never save anything here.
  (cd "$REPO" && echo five >> f.txt && git commit -qam fix4) >/dev/null 2>&1
  H2="$(cd "$REPO" && git rev-parse HEAD~1)"
  effort_run "$TMP/eff_state1" "$TMP/argv5" --base "$H2"
  if grep -q 'model_reasoning_effort="medium"' "$TMP/argv5" 2>/dev/null; then
    ok "pass 3 steps codex down to medium"
  else
    bad "pass 3 effort"; echo "      argv: $(tr '\n' ' ' < "$TMP/argv5" 2>/dev/null)"
  fi

  # And it stops there: a long round must not walk down to low/minimal, which
  # nothing measured supports.
  (cd "$REPO" && echo six >> f.txt && git commit -qam fix5) >/dev/null 2>&1
  H3="$(cd "$REPO" && git rev-parse HEAD~1)"
  effort_run "$TMP/eff_state1" "$TMP/argv6" --base "$H3"
  if grep -q 'model_reasoning_effort="medium"' "$TMP/argv6" 2>/dev/null; then
    ok "pass 4 stays at medium — the ladder has a floor"
  else
    bad "pass 4 floor"; echo "      argv: $(tr '\n' ' ' < "$TMP/argv6" 2>/dev/null)"
  fi

  # ── end-to-end: does the ladder ENGAGE in a worktree-shaped run? ──
  #
  # The unit pins above prove the guard can key on --subject-id. This proves
  # run_reviewers.sh actually passes it, on a detached HEAD, all the way
  # through to codex's argv. Without the flag the ladder stays at default
  # effort forever no matter how many passes run; with it, pass 2 steps down.
  DREPO="$TMP/drepo"; mkdir -p "$DREPO"
  (
    cd "$DREPO" || exit 1
    git init -q . && git config user.email t@t && git config user.name t
    echo one > f.txt && git add f.txt && git commit -qm base
    git rev-parse HEAD > "$TMP/dbase"
    echo two >> f.txt && git commit -qam fix1
    git checkout -q --detach HEAD          # exactly how a cross-review worktree sits
  ) >/dev/null 2>&1
  DB="$(cat "$TMP/dbase")"

  det_run() {  # det_run <state_dir> <argv_out> [extra args...]
    local sd="$1" argv_out="$2"; shift 2
    (cd "$DREPO" && CROSS_REVIEW_STATE_DIR="$sd" CODEX_ARGV_OUT="$argv_out" PATH="$BIN:$PATH" \
      timeout 120 bash "$RR" --base "$DB" --out "$(mktemp -d)" \
        --reviewers codex --timeout-codex 30 "$@") >/dev/null 2>&1
  }

  # Two passes WITHOUT --subject-id: no identity, so no state, so pass 2 still
  # reads as pass 1 and effort is never stepped down. The regression this
  # whole change exists to end.
  det_run "$TMP/det_s1" "$TMP/dargv1"
  (cd "$DREPO" && echo three >> f.txt && git commit -qam fix2) >/dev/null 2>&1
  det_run "$TMP/det_s1" "$TMP/dargv2"
  if [[ -f "$TMP/dargv2" ]] && ! grep -q model_reasoning_effort "$TMP/dargv2"; then
    ok "detached without --subject-id: ladder never engages (the bug, pinned)"
  else
    bad "expected no effort pin"; echo "      argv: $(tr '\n' ' ' < "$TMP/dargv2" 2>/dev/null)"
  fi

  # The same two passes WITH it. Note pass 2 must use pass 1's HEAD as its
  # base: with an identity the guard is now live, and reusing pass 1's base
  # would be refused as a full re-review (exit 3, nothing dispatched). That
  # refusal is the guard working — it is also why the first draft of this test
  # failed, which is a better demonstration than the assertion below.
  det_run "$TMP/det_s2" "$TMP/dargv3" --subject-id pr-777
  DH1="$(cd "$DREPO" && git rev-parse HEAD)"
  (cd "$DREPO" && echo four >> f.txt && git commit -qam fix3) >/dev/null 2>&1
  det_run "$TMP/det_s2" "$TMP/dargv4" --subject-id pr-777 --base "$DH1"
  if grep -q 'model_reasoning_effort="high"' "$TMP/dargv4" 2>/dev/null; then
    ok "detached with --subject-id: pass 2 steps codex down to high"
  else
    bad "detached ladder engagement"; echo "      argv: $(tr '\n' ' ' < "$TMP/dargv4" 2>/dev/null)"
  fi

  # The env var is the same channel — the worktree flow may export rather than
  # pass a flag, and a channel that silently does nothing is worse than none.
  DH2="$(cd "$DREPO" && git rev-parse HEAD)"
  (cd "$DREPO" && echo five >> f.txt && git commit -qam fix4) >/dev/null 2>&1
  CROSS_REVIEW_SUBJECT_ID=pr-777 det_run "$TMP/det_s2" "$TMP/dargv5" --base "$DH2"
  if grep -q model_reasoning_effort "$TMP/dargv5" 2>/dev/null; then
    ok "CROSS_REVIEW_SUBJECT_ID works as the flag does"
  else
    bad "env channel"; echo "      argv: $(tr '\n' ' ' < "$TMP/dargv5" 2>/dev/null)"
  fi

  # An explicit flag outranks the derivation, in both directions.
  effort_run "$TMP/eff_state2" "$TMP/argv3" --codex-effort low
  if grep -q 'model_reasoning_effort="low"' "$TMP/argv3" 2>/dev/null; then
    ok "--codex-effort pins the level on a first pass"
  else
    bad "--codex-effort pin"; echo "      argv: $(tr '\n' ' ' < "$TMP/argv3" 2>/dev/null)"
  fi

  # A typo must not be handed to `-c`. Whether codex ignores an unknown level
  # or rejects it is unverified and beside the point — neither outcome is one
  # to discover in the middle of a round.
  effort_run "$TMP/eff_state3" "$TMP/argv4" --codex-effort xxhigh
  if [[ -f "$TMP/argv4" ]] && ! grep -q model_reasoning_effort "$TMP/argv4"; then
    ok "an unknown effort is dropped, not passed to codex"
  else
    bad "unknown effort must be dropped"; echo "      argv: $(tr '\n' ' ' < "$TMP/argv4" 2>/dev/null)"
  fi
  # The remaining integrations need the round to actually reach dispatch, so a
  # reviewer must LOOK installed. A stub `codex` keeps this offline and fast:
  # the real CLI is resolved through lib_path.sh (~/.local/bin + the nvm bin
  # dir), so $HOME and $NVM_DIR are redirected too, or the machine's own codex
  # would be found and a live review billed from a unit test.
  BIN_SBX="$TMP/bin_sandbox"; mkdir -p "$BIN_SBX" "$TMP/fakehome"
  cat > "$BIN_SBX/codex" <<'STUB'
#!/bin/sh
case " $* " in *--version*) echo "codex 0.0.0-stub"; exit 0 ;; esac
echo "no findings"
exit "${STUB_RC:-0}"
STUB
  chmod +x "$BIN_SBX/codex"
  # sandbox_rr <state_dir> <out_dir> <stub_rc> [extra run_reviewers args...]
  sandbox_rr() {
    local sd="$1" od="$2" src="$3"; shift 3
    (cd "$REPO" && timeout 90 env "PATH=$BIN_SBX:/usr/bin:/bin" "HOME=$TMP/fakehome" \
       "NVM_DIR=$TMP/no-nvm" "STUB_RC=$src" "CROSS_REVIEW_STATE_DIR=$sd" \
       bash "$RR" --base "$B" --out "$od" --reviewers codex "$@") >/dev/null 2>&1
  }

  # --allow-full-rereview is documented in SKILL.md as THE escape hatch, but
  # run_reviewers.sh never parsed it: the documented flag fell through to the
  # arg parser's `unknown arg` branch and killed the round (exit 2) instead of
  # allowing it. Same blocked state as above; only the flag differs.
  sandbox_rr "$TMP/integ_state" "$TMP/ovr_out" 0 --allow-full-rereview; rc=$?
  if [[ "$rc" -ne 2 && "$rc" -ne 3 ]]; then
    ok "run_reviewers.sh --allow-full-rereview is parsed and overrides the block"
  else bad "--allow-full-rereview (rc=$rc, want neither 2 nor 3)"; fi

  # A round where every lane failed reviewed NOTHING, so it must not be
  # recorded. Recording at dispatch time made the retry after a dead round
  # (quota exhaustion, timeout) look like a repeat pass, and the refusal then
  # pointed the caller at a base whose diff nobody had reviewed — turning a
  # cost guard into silent coverage loss.
  sandbox_rr "$TMP/fail_state" "$TMP/fail_out" 1
  if [[ -z "$(find "$TMP/fail_state" -type f 2>/dev/null)" ]]; then
    ok "a round with no successful reviewer records no state"
  else bad "a failed round poisoned the guard state"; fi
  (cd "$REPO" && echo four >> f.txt && git commit -qam fix3) >/dev/null 2>&1
  sandbox_rr "$TMP/fail_state" "$TMP/fail_out2" 1; rc=$?
  if [[ "$rc" -ne 3 ]]; then ok "retry after a failed round is not blocked"
  else bad "retry after a failed round was blocked (rc=3)"; fi

  # ...but a round that DID review must still be recorded, or the guard has
  # nothing to compare the next pass against and never fires again.
  sandbox_rr "$TMP/ok_state" "$TMP/ok_out" 0
  if [[ -n "$(find "$TMP/ok_state" -type f 2>/dev/null)" ]]; then
    ok "a round with a successful reviewer is recorded"
  else bad "a successful round was not recorded"; fi

  # Detached HEAD: `git branch --show-current` prints NOTHING and exits 0, so
  # the old `|| echo detached` fallback never fired and the guard exited 2 — a
  # usage error on every detached checkout, recording nothing and blocking
  # nothing. A literal "detached" key would be worse (every detached review of
  # a repo shares one key AND one base), so it must fail OPEN instead.
  echo "── detached HEAD has no branch identity: fail open, never exit 2 ──"
  (cd "$REPO" && git checkout -q --detach) >/dev/null 2>&1
  run_det() {
    local want="$1" label="$2"; shift 2
    local o r
    o="$(cd "$REPO" && bash "$GUARD" --state-dir "$TMP/det_state" "$@" 2>&1)"; r=$?
    if [[ "$r" == "$want" ]]; then ok "$label"
    else bad "$label (rc=$r want=$want)"; echo "      out: ${o//$'\n'/ | }"; fi
  }
  run_det 0 "detached check -> guard skipped, round allowed" --base-sha "$B" --head-sha "$H1"
  run_det 0 "detached --record -> no-op, not a usage error"   --record --base-sha "$B" --head-sha "$H1"
  run_det 2 "a missing --base-sha is still a usage error"     --project demo --branch feat/x

  # --pass-context is the SECOND way a detached HEAD disabled #168's effort
  # ladder: it has its own usage path (project+branch, no shas), so it exited 2
  # before reading any record, run_reviewers swallowed that as `|| echo 1`, and
  # every pass got default effort from round 1 onward -- independent of whether
  # the state record itself was repaired. Its contract is "always prints a
  # number"; a caller's `case ''` sanitizer inventing the same 1 is not the
  # script honouring a contract.
  pc="$(cd "$REPO" && bash "$GUARD" --state-dir "$TMP/det_state" --pass-context 2>/dev/null)"; rc=$?
  if [[ "$rc" -eq 0 && "$pc" == 1 ]]; then
    ok "detached --pass-context prints 1, does not fall silent or exit 2"
  else bad "detached --pass-context (rc=$rc out='$pc' want rc=0 out=1)"; fi
  (cd "$REPO" && git checkout -q feat/guard) >/dev/null 2>&1
else
  echo "  skip run_reviewers.sh integration (script or git unavailable)"
fi

echo
echo "══ $PASS passed, $FAIL failed ══"
[[ "$FAIL" -eq 0 ]]
