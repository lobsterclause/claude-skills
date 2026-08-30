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

echo "── --pass-context: the query the effort dial reads ──"
# pc <label> <want> [args...] — asserts the printed answer AND that a query
# never gates: --pass-context must exit 0 even where the gate would exit 3.
pc() {
  local label="$1" want="$2"; shift 2
  local got rc
  got="$(bash "$GUARD" --pass-context --state-dir "$STATE" "$@" 2>/dev/null)"; rc=$?
  if [[ "$got" == "$want" && "$rc" -eq 0 ]]; then ok "$label"
  else bad "$label (got='$got' rc=$rc want='$want' rc=0)"; fi
}

pc "unreviewed branch -> first"        first  --project demo --branch feat/never
pc "recorded branch -> repeat"         repeat --project demo --branch feat/x
pc "a sibling branch is still first"   first  --project demo --branch feat/other
pc "a different project is first"      first  --project other --branch feat/x
# Staleness is the gate's own rule, reused: a record past the window is not
# evidence of a prior pass, so a revisit days later pays full effort again.
pc "a stale record -> first"           first  --project demo --branch feat/x --window-hours 0
# The query must answer even for a branch the gate would BLOCK — the caller
# reads it on exactly that path, and an exit 3 here would abort the round.
pc "queries the blocked shape, does not block" repeat --project demo --branch feat/x

# A missing state dir must not make the query fail; effort just stays default.
pc "absent state dir -> first, not an error" first --project demo --branch feat/x --state-dir "$TMP/nonexistent"

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

  # Pass 2: the round above recorded this branch, so the repeat pass steps down.
  (cd "$REPO" && echo four >> f.txt && git commit -qam fix3) >/dev/null 2>&1
  effort_run "$TMP/eff_state1" "$TMP/argv2" --base "$H1"
  if grep -q 'model_reasoning_effort="high"' "$TMP/argv2" 2>/dev/null; then
    ok "a repeat pass steps codex down to high"
  else
    bad "repeat pass effort"; echo "      argv: $(tr '\n' ' ' < "$TMP/argv2" 2>/dev/null)"
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
else
  echo "  skip run_reviewers.sh integration (script or git unavailable)"
fi

echo
echo "══ $PASS passed, $FAIL failed ══"
[[ "$FAIL" -eq 0 ]]
