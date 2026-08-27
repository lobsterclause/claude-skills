#!/usr/bin/env bash
# test_lifecycle_emitters.sh — standalone TDD fixture for the finding-lifecycle
# event emitters added to verify_fix_safety.sh and merge_raw_findings.sh, plus
# the SKILL.md wiring for parent_verified_*/deferred/human_rejected/--phases
# (#88, #119).
#
# NO network, NO reviewer CLIs. Run:
#   bash tests/test_lifecycle_emitters.sh
# Exit: 0 all green, 1 any failure.
#
# Portability: macOS bash 3.2 + ubuntu bash 5; needs jq.

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

echo "── (a) verify_fix_safety.sh --emit-events --applied: safe diff -> fix_applied then fix_verified ──"
export CROSS_REVIEW_FINDING_EVENTS="$T/ev_a.jsonl"
cat >"$T/safe.diff" <<'EOF'
--- a/foo.js
+++ b/foo.js
@@ -1,3 +1,3 @@
-console.log("old");
+console.log("new");
EOF
OUT_A="$(bash "$S/verify_fix_safety.sh" --diff "$T/safe.diff" --finding-id f-1 --applied --emit-events r1)"
RC_A=$?
assert_eq "(a) exit code 0" "$RC_A" "0"
assert_eq "(a) verdict safe:true" "$(jq -r '.safe' <<<"$OUT_A")" "true"
assert_eq "(a) exactly 2 events written" "$(wc -l <"$T/ev_a.jsonl" | tr -d ' ')" "2"
assert_eq "(a) event 1 is fix_applied for f-1/r1" \
  "$(sed -n '1p' "$T/ev_a.jsonl" | jq -c '{event, finding_id, run_id}')" \
  '{"event":"fix_applied","finding_id":"f-1","run_id":"r1"}'
assert_eq "(a) event 2 is fix_verified for f-1/r1" \
  "$(sed -n '2p' "$T/ev_a.jsonl" | jq -c '{event, finding_id, run_id}')" \
  '{"event":"fix_verified","finding_id":"f-1","run_id":"r1"}'
assert_eq "(a) exactly one fix_applied total" \
  "$(jq -r 'select(.event=="fix_applied")' "$T/ev_a.jsonl" | jq -s 'length')" "1"
assert_eq "(a) exactly one fix_verified total" \
  "$(jq -r 'select(.event=="fix_verified")' "$T/ev_a.jsonl" | jq -s 'length')" "1"
unset CROSS_REVIEW_FINDING_EVENTS

echo "── (b) verify_fix_safety.sh: fix that deletes an auth guard -> fix_failed with matched fields, verdict/exit unchanged ──"
cat >"$T/unsafe.diff" <<'EOF'
--- a/auth.js
+++ b/auth.js
@@ -1,5 +1,3 @@
-if (!isAuthorized(user)) {
-  throw new UnauthorizedError();
-}
 doTheThing();
EOF
# Baseline: verdict/exit without --emit-events.
OUT_B_BASE="$(bash "$S/verify_fix_safety.sh" --diff "$T/unsafe.diff" --finding-id f-2)"
RC_B_BASE=$?
export CROSS_REVIEW_FINDING_EVENTS="$T/ev_b.jsonl"
OUT_B="$(bash "$S/verify_fix_safety.sh" --diff "$T/unsafe.diff" --finding-id f-2 --emit-events r2)"
RC_B=$?
unset CROSS_REVIEW_FINDING_EVENTS
assert_eq "(b) verdict unchanged by --emit-events" "$(jq -c '{safe,reason,matched}' <<<"$OUT_B")" "$(jq -c '{safe,reason,matched}' <<<"$OUT_B_BASE")"
assert_eq "(b) exit code unchanged by --emit-events" "$RC_B" "$RC_B_BASE"
assert_eq "(b) verdict safe:false" "$(jq -r '.safe' <<<"$OUT_B")" "false"
assert_eq "(b) exactly one fix_failed event" \
  "$(jq -r 'select(.event=="fix_failed")' "$T/ev_b.jsonl" | jq -s 'length')" "1"
assert_eq "(b) fix_failed matched is non-empty" \
  "$(jq -r 'select(.event=="fix_failed") | (.matched | length > 0)' "$T/ev_b.jsonl")" "true"
assert_not_contains "(b) no fix_applied event (--applied not passed)" "$(cat "$T/ev_b.jsonl")" "fix_applied"

echo "── (c) verify_fix_safety.sh: unwritable events path -> verdict/exit unchanged, WARN on stderr ──"
export CROSS_REVIEW_FINDING_EVENTS="/nonexistent_dir_xyz_$$/ev.jsonl"
OUT_C="$(bash "$S/verify_fix_safety.sh" --diff "$T/safe.diff" --finding-id f-3 --emit-events r3 2>"$T/c.err")"
RC_C=$?
unset CROSS_REVIEW_FINDING_EVENTS
assert_eq "(c) exit code still 0" "$RC_C" "0"
assert_eq "(c) verdict still safe:true" "$(jq -r '.safe' <<<"$OUT_C")" "true"
assert_contains "(c) WARN on stderr for the failed append" "$(cat "$T/c.err")" "WARN"

echo "── (d) merge_raw_findings.sh --emit-events: two seats echo the same file+claim, a third differs ──"
MRAW="$T/mraw"; mkdir -p "$MRAW"
cat >"$MRAW/alpha.stdout" <<'EOF'
{"findings":[{"severity":"High","file":"a.sh","line":3,"snippet":"rm -rf $x","claim":"unquoted var can expand to nothing and rm -rf /"}]}
EOF
cat >"$MRAW/beta.stdout" <<'EOF'
{"findings":[{"severity":"High","file":"a.sh","line":3,"snippet":"rm -rf $x","claim":"Unquoted var can expand to nothing and rm -rf /  "}]}
EOF
cat >"$MRAW/gamma.stdout" <<'EOF'
{"findings":[{"severity":"Low","file":"b.sh","line":10,"snippet":"echo $y","claim":"unquoted var, minor"}]}
EOF
export CROSS_REVIEW_FINDING_EVENTS="$T/ev_d.jsonl"
bash "$S/merge_raw_findings.sh" --raw "$MRAW" --out "$T/merged.json" --emit-events r4 >/dev/null 2>"$T/d.err"
RC_D=$?
unset CROSS_REVIEW_FINDING_EVENTS
assert_eq "(d) merge_raw_findings.sh still exits 0" "$RC_D" "0"
assert_eq "(d) exactly one duplicate_merged event" \
  "$(jq -r 'select(.event=="duplicate_merged")' "$T/ev_d.jsonl" | jq -s 'length')" "1"
assert_eq "(d) reviewer is the second seat (beta)" \
  "$(jq -r 'select(.event=="duplicate_merged") | .reviewer' "$T/ev_d.jsonl")" "beta"
assert_eq "(d) first_reviewer is the first seat (alpha)" \
  "$(jq -r 'select(.event=="duplicate_merged") | .first_reviewer' "$T/ev_d.jsonl")" "alpha"
assert_not_contains "(d) no duplicate_merged naming gamma" \
  "$(jq -c 'select(.event=="duplicate_merged")' "$T/ev_d.jsonl")" "gamma"
assert_contains "(d) without a project the ids are f-dup-* and a WARN says they will not join" "$(cat "$T/d.err")" "will not join"

# ── PR #131 review: ids must equal what fingerprint_findings.sh mints for the
#    same (project, file, claim); a seat repeating itself is not a duplicate;
#    an append failure is reported even when it is one line ──────────────────
export CROSS_REVIEW_FINDING_EVENTS="$T/ev_d2.jsonl"
bash "$S/merge_raw_findings.sh" --raw "$MRAW" --out "$T/merged2.json" --emit-events r5 --project test-project >/dev/null 2>&1
unset CROSS_REVIEW_FINDING_EVENTS
DUP_ID="$(jq -r 'select(.event=="duplicate_merged") | .finding_id' "$T/ev_d2.jsonl")"
printf '{"findings":[{"id":"f1","file":"a.sh","line":3,"snippet":"rm -rf $x","claim":"unquoted var can expand to nothing and rm -rf /","sources":["alpha"]}]}\n' >"$T/fp-in.json"
bash "$S/fingerprint_findings.sh" --findings "$T/fp-in.json" --project test-project --out "$T/fp-out.json" >/dev/null 2>&1
FP_ID="$(jq -r '.findings[0].id' "$T/fp-out.json")"
assert_eq "duplicate_merged id equals the fingerprinted id for the same project/file/claim" "$DUP_ID" "$FP_ID"
MRAW2="$T/mraw2"; mkdir -p "$MRAW2"
cat >"$MRAW2/alpha.stdout" <<'EOF'
{"findings":[{"severity":"High","file":"a.sh","line":3,"snippet":"x","claim":"same claim twice"},{"severity":"High","file":"a.sh","line":9,"snippet":"y","claim":"same claim twice"}]}
EOF
export CROSS_REVIEW_FINDING_EVENTS="$T/ev_d3.jsonl"; : >"$T/ev_d3.jsonl"
bash "$S/merge_raw_findings.sh" --raw "$MRAW2" --out "$T/merged3.json" --emit-events r6 --project test-project >/dev/null 2>&1
unset CROSS_REVIEW_FINDING_EVENTS
assert_eq "a seat repeating its own claim emits no duplicate_merged" "$(jq -r 'select(.event=="duplicate_merged")' "$T/ev_d3.jsonl" | jq -s 'length')" "0"
if [[ "$(id -u)" -ne 0 ]]; then
  mkdir -p "$T/ro-ev" && chmod 500 "$T/ro-ev"
  ERR7="$(CROSS_REVIEW_FINDING_EVENTS="$T/ro-ev/ev.jsonl" bash "$S/merge_raw_findings.sh" --raw "$MRAW" --out "$T/merged4.json" --emit-events r7 --project test-project 2>&1 >/dev/null)"; rc7=$?
  chmod 700 "$T/ro-ev"
  assert_eq "merge still exits 0 when the events path is unwritable" "$rc7" "0"
  assert_contains "merge reports the failed append" "$ERR7" "event append failed"
else
  ok "merge reports the failed append (skipped as root)"
fi
bash "$S/merge_raw_findings.sh" --raw >/dev/null 2>&1; assert_eq "--raw without a value exits 2" "$?" "2"
bash "$S/merge_raw_findings.sh" --raw "$MRAW" --out "$T/m5.json" --emit-events r8 --repo-root "$T/does-not-exist" >/dev/null 2>&1; assert_eq "--repo-root that is not a directory exits 2" "$?" "2"

echo "── (f) merge_raw_findings.sh: no attempt-file fallback; one-jq-pass dup tracking is byte-identical (#135, #134) ──"

# (f1) [RED: fails on the fallback today] A raw dir with ONLY attempt-stamped
# forensic copies (no final <slug>.stdout at all) must yield ZERO findings and
# ZERO duplicate_merged events -- not a merge of every attempt file as if each
# were its own reviewer.
FRAW1="$T/fraw1"; mkdir -p "$FRAW1"
cat >"$FRAW1/alpha.attempt1.stdout" <<'EOF'
{"findings":[{"severity":"High","file":"a.sh","line":3,"snippet":"x","claim":"same finding"}]}
EOF
cp "$FRAW1/alpha.attempt1.stdout" "$FRAW1/alpha.attempt2.stdout"
export CROSS_REVIEW_FINDING_EVENTS="$T/ev_f1.jsonl"
bash "$S/merge_raw_findings.sh" --raw "$FRAW1" --out "$T/f1-merged.json" --emit-events rf1 >/dev/null 2>"$T/f1.err"
RC_F1=$?
unset CROSS_REVIEW_FINDING_EVENTS
assert_eq "(f1) exits 0 with only attempt copies present" "$RC_F1" "0"
assert_eq "(f1) zero-file fallback is gone: findings length is 0" \
  "$(jq '.findings | length' "$T/f1-merged.json" 2>/dev/null)" "0"
assert_eq "(f1) zero duplicate_merged events (nothing was ever a reviewer)" \
  "$([[ -f "$T/ev_f1.jsonl" ]] && jq -r 'select(.event=="duplicate_merged")' "$T/ev_f1.jsonl" | jq -s 'length' || echo 0)" "0"

# (f2) A raw dir with a final <slug>.stdout AND its attempt copy: the attempt
# copy is still ignored (pre-existing behaviour, pinned again post-refactor).
FRAW2="$T/fraw2"; mkdir -p "$FRAW2"
cat >"$FRAW2/alpha.stdout" <<'EOF'
{"findings":[{"severity":"High","file":"a.sh","line":3,"snippet":"x","claim":"finding one"},{"severity":"Low","file":"b.sh","line":9,"snippet":"y","claim":"finding two"}]}
EOF
cp "$FRAW2/alpha.stdout" "$FRAW2/alpha.attempt1.stdout"
bash "$S/merge_raw_findings.sh" --raw "$FRAW2" --out "$T/f2-merged.json" >/dev/null 2>&1
assert_eq "(f2) final stdout present -> attempt copy still ignored (count matches alpha.stdout alone)" \
  "$(jq '.findings | length' "$T/f2-merged.json" 2>/dev/null)" "2"

# (f3)/(f4) the one-jq-pass refactor of the dup_track loop emits byte-identical
# duplicate_merged events. The expected values are PINNED from the pre-refactor
# script (origin/master before #137, computed 2026-08-27) -- not re-derived
# from git at test time: `git show HEAD:` became a tautology the moment the
# refactor merged, and fails outright without history (cross-review of #137).
# (f3) reuses the (d) fixture (alpha/beta/gamma, one true duplicate) with a
# project namespace so ids are stable f-<hash> (not f-dup-*).
F3_PINNED='{"claim_hash":"903adffd","event":"duplicate_merged","file":"a.sh","finding_id":"f-903adffd","first_reviewer":"alpha","local_id":null,"reviewer":"beta","run_id":"rf3","schema_version":1,"sources":["alpha","beta"]}'
export CROSS_REVIEW_FINDING_EVENTS="$T/ev_f3_new.jsonl"
bash "$S/merge_raw_findings.sh" --raw "$MRAW" --out "$T/f3-new.json" \
  --emit-events rf3 --project test-project >/dev/null 2>&1
unset CROSS_REVIEW_FINDING_EVENTS
F3_NEW="$(jq -cS 'select(.event=="duplicate_merged") | del(.ts)' "$T/ev_f3_new.jsonl" 2>/dev/null | sort)"
assert_eq "(f3) duplicate_merged event (minus ts) is byte-identical to the pre-refactor script's" "$F3_NEW" "$F3_PINNED"

# (f4) a claim containing a literal tab and a "|" still dedupes correctly,
# and its claim_hash matches what the ORIGINAL script computed (pinned) --
# proving the one-jq-pass extraction normalizes/hashes identically to the
# 3-4-call version it replaces.
FRAW4="$T/fraw4"; mkdir -p "$FRAW4"
# \\t in the printf format is a literal backslash+t two-char sequence in the
# OUTPUT -- i.e. the JSON escape for a tab -- so the fixture file is valid
# JSON (an unescaped raw tab byte inside a JSON string is NOT valid JSON and
# jq would reject the whole file as unparsed).
printf '{"findings":[{"severity":"High","file":"a|b.sh","line":1,"snippet":"x","claim":"weird\\tclaim | with a pipe"}]}\n' >"$FRAW4/alpha.stdout"
printf '{"findings":[{"severity":"High","file":"a|b.sh","line":1,"snippet":"x","claim":"WEIRD\\tCLAIM | WITH A PIPE"}]}\n' >"$FRAW4/beta.stdout"
export CROSS_REVIEW_FINDING_EVENTS="$T/ev_f4_new.jsonl"
bash "$S/merge_raw_findings.sh" --raw "$FRAW4" --out "$T/f4-new.json" \
  --emit-events rf4 --project test-project >/dev/null 2>&1
unset CROSS_REVIEW_FINDING_EVENTS
F4_HASH_NEW="$(jq -r 'select(.event=="duplicate_merged") | .claim_hash' "$T/ev_f4_new.jsonl" 2>/dev/null)"
assert_eq "(f4) claim_hash for a tab+pipe claim matches the pre-refactor script's pinned hash" "$F4_HASH_NEW" "9fd6d1b1"

# (f5) an attempt-only raw dir (zero surviving final files) must yield an empty
# findings array under macOS /bin/bash 3.2 too: with the raw-glob fallback gone
# (#135) the sorted array is really empty, and "${sorted[@]}" on an empty array
# is an unbound-variable crash under set -u on bash < 4.4.
if [[ -x /bin/bash ]]; then
  FRAW5="$T/fraw5"; mkdir -p "$FRAW5"
  printf '{"findings":[{"severity":"High","file":"z.sh","line":1,"snippet":"x","claim":"forensic retry only"}]}\n' >"$FRAW5/glm.attempt1.stdout"
  F5_RC=0
  /bin/bash "$S/merge_raw_findings.sh" --raw "$FRAW5" --out "$T/f5.json" >/dev/null 2>"$T/f5.err" || F5_RC=$?
  assert_eq "(f5) attempt-only raw dir exits 0 under /bin/bash ($(/bin/bash -c 'echo $BASH_VERSION'))" "$F5_RC" "0"
  assert_eq "(f5) attempt-only raw dir yields zero findings under /bin/bash" \
    "$(jq -c '.findings' "$T/f5.json" 2>/dev/null)" "[]"
  assert_eq "(f5) no unbound-variable error under /bin/bash" \
    "$(grep -c 'unbound variable' "$T/f5.err")" "0"
fi

echo "── (e) SKILL.md carries the lifecycle wiring literally (grep test) ──"
SKILL_MD="$SKILL_DIR/SKILL.md"
assert_contains "(e) SKILL.md has parent_verified_dropped" "$(cat "$SKILL_MD")" "parent_verified_dropped"
assert_contains "(e) SKILL.md has --applied" "$(cat "$SKILL_MD")" "--applied"
assert_contains "(e) SKILL.md has deferred" "$(cat "$SKILL_MD")" "deferred"
assert_contains "(e) SKILL.md has human_rejected" "$(cat "$SKILL_MD")" "human_rejected"
assert_contains '(e) SKILL.md has --phases "$run_dir/phases.json"' "$(cat "$SKILL_MD")" '--phases "$run_dir/phases.json"'

echo
echo "══ $PASS passed, $FAIL failed ══"
[[ "$FAIL" -eq 0 ]]
