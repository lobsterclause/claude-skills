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
