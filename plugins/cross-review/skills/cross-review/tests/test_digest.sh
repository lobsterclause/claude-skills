#!/usr/bin/env bash
# test_digest.sh — standalone fixture tests for digest_context.sh.
#
# NOT wired into run_tests.sh (parent orchestrator owns that wiring separately
# to avoid a merge collision). Pure bash+jq, no network, no reviewer CLIs.
#
# Run:  bash tests/test_digest.sh          (from the skill root or anywhere)
# Exit: 0 all green, 1 any failure.
#
# Portability: macOS bash 3.2 + ubuntu bash 5; needs jq.

set -uo pipefail

SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
S="$SKILL_DIR/scripts"
DIGEST="$S/digest_context.sh"
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

[[ -x "$DIGEST" ]] || { echo "FATAL: $DIGEST missing or not executable"; exit 1; }

echo "── usage / arg validation ──"
OUT_NOARGS="$(bash "$DIGEST" 2>&1)"; RC_NOARGS=$?
assert_eq "no inputs at all exits 2" "$RC_NOARGS" "2"
assert_contains "no-inputs error names the requirement" "$OUT_NOARGS" "--sgscan or --impact"

echo "── ast-grep section: grouping, sort, file cap, malformed skip ──"
# no-direct-memory-items-write: 3 findings (a.ts x2, b.ts x1) — highest count.
# other-rule: 1 finding (c.ts) — lower count, must sort after.
# one line is not valid JSON at all — must be skipped and counted, not fatal.
cat >"$T/sgscan.jsonl" <<'EOF'
{"ruleId":"no-direct-memory-items-write","file":"src/a.ts","message":"m1","severity":"error"}
{"ruleId":"no-direct-memory-items-write","file":"src/b.ts","message":"m2","severity":"error"}
{"ruleId":"no-direct-memory-items-write","file":"src/a.ts","message":"m3","severity":"error"}
{"ruleId":"other-rule","file":"src/c.ts","message":"m4","severity":"warning"}
not valid json at all
EOF

SG_OUT="$(bash "$DIGEST" --sgscan "$T/sgscan.jsonl" 2>"$T/sg.err")"
RC_SG=$?
assert_eq "sgscan-only invocation exits 0" "$RC_SG" "0"
assert_contains "malformed line counted on stderr" "$(cat "$T/sg.err")" "skipped: 1 malformed lines"
assert_contains "total findings reported" "$SG_OUT" "4 finding(s) across 2 rule(s)"
# no-direct-memory-items-write (3) must sort before other-rule (1). Both rules
# fit under the default --top 5, so this checks rule ORDER, not the file cap.
RANK_A="$(printf '%s\n' "$SG_OUT" | grep -n 'no-direct-memory-items-write' | cut -d: -f1)"
RANK_B="$(printf '%s\n' "$SG_OUT" | grep -n 'other-rule' | cut -d: -f1)"
if [[ -n "$RANK_A" && -n "$RANK_B" && "$RANK_A" -lt "$RANK_B" ]]; then
  ok "higher-count rule (3) sorts before lower-count rule (1)"
else
  bad "rule sort-by-count-desc violated (a=$RANK_A b=$RANK_B)"
fi

# Separate invocation with --top 1: forces BOTH the per-rule file cap AND the
# rule-row cap, so only the highest-count rule's row is shown at all.
SG_TOP1_OUT="$(bash "$DIGEST" --sgscan "$T/sgscan.jsonl" --top 1 2>/dev/null)"
assert_contains "top-files cap (top=1) keeps only the highest-count file" "$SG_TOP1_OUT" "src/a.ts"
assert_contains "top-files cap overflow marker present" "$SG_TOP1_OUT" "+1 more"
assert_not_contains "capped file list excludes the 2nd file inline" \
  "$(printf '%s\n' "$SG_TOP1_OUT" | grep 'no-direct-memory-items-write')" "src/b.ts"
assert_contains "rule-row cap (top=1) notes the omitted 2nd rule" "$SG_TOP1_OUT" "+1 more rule(s) not shown"

echo "── ast-grep section: empty (valid, zero findings) ──"
: >"$T/sgscan_empty.jsonl"
EMPTY_SG_OUT="$(bash "$DIGEST" --sgscan "$T/sgscan_empty.jsonl" 2>/dev/null)"
assert_contains "empty sgscan fixture states no findings explicitly" "$EMPTY_SG_OUT" "no findings"

echo "── impact section: affected files + recommended tests, capped ──"
cat >"$T/impact.json" <<'EOF'
{"affected_files":["b.ts","a.ts","c.ts","d.ts","e.ts","f.ts"],"recommended_tests":["t2.test.ts","t1.test.ts"]}
EOF
IMP_OUT="$(bash "$DIGEST" --impact "$T/impact.json" --top 3 2>"$T/imp.err")"
RC_IMP=$?
assert_eq "impact-only invocation exits 0" "$RC_IMP" "0"
assert_contains "affected files count reported" "$IMP_OUT" "affected files: 6"
assert_contains "affected files overflow marker (6 items, top 3)" "$IMP_OUT" "+3 more"
assert_contains "recommended tests count reported" "$IMP_OUT" "recommended tests: 2"
assert_contains "sorted affected files shown (a.ts before f.ts alphabetically)" "$IMP_OUT" "a.ts"

echo "── impact section: empty (valid, zero affected/tests) ──"
printf '{}' >"$T/impact_empty.json"
EMPTY_IMP_OUT="$(bash "$DIGEST" --impact "$T/impact_empty.json" 2>/dev/null)"
assert_contains "empty impact fixture states no impact data explicitly" "$EMPTY_IMP_OUT" "no impact data"

echo "── impact section: reasonable variant shapes ──"
# object-with-file-key variant + the real impact.sh shape (entries/reverseDeps/tests)
cat >"$T/impact_variant.json" <<'EOF'
{"entries":["src/x.ts"],"reverseDeps":{"pkgA":["src/y.ts","src/z.ts"]},"tests":["y.test.ts"]}
EOF
VARIANT_OUT="$(bash "$DIGEST" --impact "$T/impact_variant.json" 2>/dev/null)"
assert_contains "entries+reverseDeps variant surfaces affected files" "$VARIANT_OUT" "affected files: 3"
assert_contains "tests-key variant surfaces recommended tests" "$VARIANT_OUT" "recommended tests: 1"

cat >"$T/impact_objfile.json" <<'EOF'
{"affected_files":[{"file":"src/obj1.ts"},{"path":"src/obj2.ts"}],"recommended_tests":[{"file":"obj1.test.ts"}]}
EOF
OBJ_OUT="$(bash "$DIGEST" --impact "$T/impact_objfile.json" 2>/dev/null)"
assert_contains "object-with-file-key entries extracted" "$OBJ_OUT" "src/obj1.ts"
assert_contains "object-with-path-key entries extracted" "$OBJ_OUT" "src/obj2.ts"

echo "── impact section: malformed whole-file JSON degrades, not fatal ──"
printf 'not json at all {{{' >"$T/impact_garbage.json"
GARBAGE_OUT="$(bash "$DIGEST" --impact "$T/impact_garbage.json" 2>"$T/garbage.err")"
RC_GARBAGE=$?
assert_eq "malformed impact JSON is non-fatal (exit 0)" "$RC_GARBAGE" "0"
assert_contains "malformed impact JSON noted on stderr" "$(cat "$T/garbage.err")" "not valid JSON"
assert_not_contains "malformed impact JSON produces no impact header" "$GARBAGE_OUT" "## impact"

echo "── combined invocation + final marker + no raw JSON dump ──"
COMBINED_OUT="$(bash "$DIGEST" --sgscan "$T/sgscan.jsonl" --impact "$T/impact.json" 2>/dev/null)"
assert_contains "final line names the script deterministically" "$COMBINED_OUT" \
  "Digest generated deterministically by digest_context.sh"
LINE_COUNT="$(printf '%s\n' "$COMBINED_OUT" | wc -l | tr -d ' ')"
if [[ "$LINE_COUNT" -le 25 ]]; then
  ok "combined output stays within the ~20-line budget ($LINE_COUNT lines)"
else
  bad "combined output exceeds 25 lines ($LINE_COUNT lines)"
fi
case "$COMBINED_OUT" in
  *"{"*|*"}"*) bad "output leaks raw JSON braces from the input dump" ;;
  *) ok "no raw JSON braces in the digest output" ;;
esac

echo "── determinism: identical inputs → byte-identical output ──"
RUN1="$(bash "$DIGEST" --sgscan "$T/sgscan.jsonl" --impact "$T/impact.json" --top 2 2>/dev/null)"
RUN2="$(bash "$DIGEST" --sgscan "$T/sgscan.jsonl" --impact "$T/impact.json" --top 2 2>/dev/null)"
assert_eq "two runs over identical inputs are byte-identical" "$RUN1" "$RUN2"

echo
echo "══ $PASS passed, $FAIL failed ══"
[[ "$FAIL" -eq 0 ]]
