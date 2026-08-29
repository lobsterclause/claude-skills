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

# ── integration: the guard must stop run_reviewers.sh BEFORE it dispatches ──
#
# Regression pin. The first wiring used `if ! bash "$guard"; then _grc=$?`,
# where $? is the NEGATED status (0), not the guard's exit code — so a blocked
# round printed "REFUSING", then reported "guard returned 0 — continuing", and
# dispatched every reviewer anyway. The unit tests above all passed while the
# integration was inert: the guard was correct and the caller ignored it.
#
# Offline by construction: if the guard works, no reviewer is ever reached.
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
else
  echo "  skip run_reviewers.sh integration (script or git unavailable)"
fi

echo
echo "══ $PASS passed, $FAIL failed ══"
[[ "$FAIL" -eq 0 ]]
