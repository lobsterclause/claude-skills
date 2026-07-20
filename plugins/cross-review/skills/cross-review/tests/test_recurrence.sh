#!/usr/bin/env bash
# test_recurrence.sh — offline fixture tests for scripts/check_recurrence.sh.
#
# Standalone: does NOT hook into run_tests.sh (parent wires that up
# separately). NO network, NO reviewer CLIs, NO tokens — pure bash+jq against
# fixture findings.json files in a temp dir.
#
# Run:  bash tests/test_recurrence.sh
# Exit: 0 all green, 1 any failure.

set -uo pipefail

SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
S="$SKILL_DIR/scripts"
CR="$S/check_recurrence.sh"
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

if [[ ! -x "$CR" ]]; then
  echo "FATAL: $CR not found or not executable — implement scripts/check_recurrence.sh" >&2
  exit 1
fi

# ── Fixtures: two previous passes + one "current" pass ────────────────────
# pass 1 (oldest --previous): f-aaa1 kept, f-bbb2 dropped, f-ccc3 kept,
#                             f-eee5 dropped
# pass 2 (2nd --previous):    f-aaa1 kept, f-bbb2 dropped again, f-eee5 KEPT
#                             (f-ccc3 absent from pass 2, but still counts as
#                             "seen previously" via pass 1)
# current:                    f-aaa1 (recurring, seen both passes, never
#                             dropped), f-bbb2 (dropped in EVERY previous
#                             occurrence -> revenant, not recurring),
#                             f-ddd4 (never seen before -> fresh),
#                             f-eee5 (dropped in pass1 but kept in pass2 ->
#                             not all-dropped -> recurring)
#                             f-ccc3 is OMITTED from current -> resolved
PREV1="$T/prev1.json"
cat >"$PREV1" <<'EOF'
{"findings":[
 {"id":"f-aaa1","severity":"High","file":"a.ts","line":1,"claim":"claim A","sources":["codex"]},
 {"id":"f-bbb2","severity":"Low","file":"b.ts","line":2,"claim":"claim B","sources":["codex"],"factcheck":{"verdict":"drop","reason":"disproven pass1"}},
 {"id":"f-ccc3","severity":"Medium","file":"c.ts","line":3,"claim":"claim C","sources":["kimi"]},
 {"id":"f-eee5","severity":"Medium","file":"e.ts","line":5,"claim":"claim E","sources":["kimi"],"factcheck":{"verdict":"drop","reason":"disproven pass1"}}
]}
EOF

PREV2="$T/prev2.json"
cat >"$PREV2" <<'EOF'
{"findings":[
 {"id":"f-aaa1","severity":"High","file":"a.ts","line":1,"claim":"claim A","sources":["codex"]},
 {"id":"f-bbb2","severity":"Low","file":"b.ts","line":2,"claim":"claim B","sources":["codex"],"factcheck":{"verdict":"drop","reason":"disproven pass2"}},
 {"id":"f-eee5","severity":"Medium","file":"e.ts","line":5,"claim":"claim E","sources":["kimi"],"factcheck":{"verdict":"keep"}}
]}
EOF

CURRENT="$T/current.json"
cat >"$CURRENT" <<'EOF'
{"findings":[
 {"id":"f-aaa1","severity":"High","file":"a.ts","line":1,"claim":"claim A","sources":["codex"]},
 {"id":"f-bbb2","severity":"Low","file":"b.ts","line":2,"claim":"claim B","sources":["codex"]},
 {"id":"f-ddd4","severity":"Critical","file":"d.ts","line":4,"claim":"claim D","sources":["glm"]},
 {"id":"f-eee5","severity":"Medium","file":"e.ts","line":5,"claim":"claim E","sources":["kimi"]}
]}
EOF

echo "── main classification (recurring / fresh / resolved / revenant) ──"
OUT="$T/out.json"
bash "$CR" --current "$CURRENT" --previous "$PREV1" --previous "$PREV2" >"$OUT" 2>"$T/out.err"
RC=$?
assert_eq "exit 0 on well-formed input" "$RC" "0"

RECURRING_IDS="$(jq -r '.recurring[].id' "$OUT" | sort | tr '\n' ',')"
assert_eq "recurring = f-aaa1,f-eee5 (both seen previously, never all-dropped)" \
  "$RECURRING_IDS" "f-aaa1,f-eee5,"

assert_eq "f-aaa1 passes_seen=2" \
  "$(jq -r '.recurring[] | select(.id=="f-aaa1") | .passes_seen' "$OUT")" "2"
assert_eq "f-aaa1 first_seen_pass=1" \
  "$(jq -r '.recurring[] | select(.id=="f-aaa1") | .first_seen_pass' "$OUT")" "1"
assert_eq "f-eee5 passes_seen=2 (dropped pass1, kept pass2 -> still recurring)" \
  "$(jq -r '.recurring[] | select(.id=="f-eee5") | .passes_seen' "$OUT")" "2"
assert_eq "f-eee5 first_seen_pass=1" \
  "$(jq -r '.recurring[] | select(.id=="f-eee5") | .first_seen_pass' "$OUT")" "1"
assert_eq "recurring entries carry original finding fields (claim)" \
  "$(jq -r '.recurring[] | select(.id=="f-aaa1") | .claim' "$OUT")" "claim A"

assert_eq "fresh = f-ddd4 (never seen before)" \
  "$(jq -r '.fresh | sort | join(",")' "$OUT")" "f-ddd4"

assert_eq "resolved = f-ccc3 (seen previously, absent from current)" \
  "$(jq -r '.resolved | sort | join(",")' "$OUT")" "f-ccc3"

assert_eq "revenant = f-bbb2 (dropped in EVERY previous occurrence)" \
  "$(jq -r '.revenant | sort | join(",")' "$OUT")" "f-bbb2"

assert_eq "revenant id excluded from recurring" \
  "$(jq -r '[.recurring[].id] | index("f-bbb2") // "absent"' "$OUT")" "absent"

echo "── summary block ──"
assert_eq "summary.recurring count" "$(jq -r '.summary.recurring' "$OUT")" "2"
assert_eq "summary.fresh count" "$(jq -r '.summary.fresh' "$OUT")" "1"
assert_eq "summary.resolved count" "$(jq -r '.summary.resolved' "$OUT")" "1"
assert_eq "summary.revenant count" "$(jq -r '.summary.revenant' "$OUT")" "1"
assert_eq "summary.verdict = recurrence_detected (recurring non-empty)" \
  "$(jq -r '.summary.verdict' "$OUT")" "recurrence_detected"

echo "── revenant does NOT trip the stop-and-ask verdict when nothing else recurs ──"
CURRENT2="$T/current2.json"
cat >"$CURRENT2" <<'EOF'
{"findings":[
 {"id":"f-bbb2","severity":"Low","file":"b.ts","line":2,"claim":"claim B","sources":["codex"]},
 {"id":"f-ddd4","severity":"Critical","file":"d.ts","line":4,"claim":"claim D","sources":["glm"]}
]}
EOF
OUT2="$T/out2.json"
bash "$CR" --current "$CURRENT2" --previous "$PREV1" --previous "$PREV2" >"$OUT2" 2>"$T/out2.err"
assert_eq "revenant-only pass -> summary.recurring = 0" "$(jq -r '.summary.recurring' "$OUT2")" "0"
assert_eq "revenant-only pass -> verdict stays ok" "$(jq -r '.summary.verdict' "$OUT2")" "ok"
assert_eq "revenant still reported" "$(jq -r '.revenant | sort | join(",")' "$OUT2")" "f-bbb2"
assert_eq "fresh still reported" "$(jq -r '.fresh | sort | join(",")' "$OUT2")" "f-ddd4"
assert_eq "resolved = everything previously seen minus current (aaa1,ccc3,eee5)" \
  "$(jq -r '.resolved | sort | join(",")' "$OUT2")" "f-aaa1,f-ccc3,f-eee5"

echo "── invalid input -> exit 2 ──"
BADJSON="$T/bad.json"
printf '{ not valid json' >"$BADJSON"
bash "$CR" --current "$BADJSON" --previous "$PREV1" >/dev/null 2>"$T/bad.err"
assert_eq "invalid current JSON -> exit 2" "$?" "2"
assert_contains "invalid JSON error message is non-empty" "$(cat "$T/bad.err")" ""

bash "$CR" --current "$CURRENT" --previous "$BADJSON" >/dev/null 2>"$T/bad2.err"
assert_eq "invalid previous JSON -> exit 2" "$?" "2"

bash "$CR" --current "$T/does-not-exist.json" --previous "$PREV1" >/dev/null 2>"$T/bad3.err"
assert_eq "missing current file -> exit 2" "$?" "2"

bash "$CR" --current "$CURRENT" >/dev/null 2>"$T/bad4.err"
assert_eq "no --previous given -> exit 2" "$?" "2"

echo "── determinism: identical inputs -> byte-identical output ──"
RUN1="$T/run1.json"; RUN2="$T/run2.json"
bash "$CR" --current "$CURRENT" --previous "$PREV1" --previous "$PREV2" >"$RUN1" 2>/dev/null
bash "$CR" --current "$CURRENT" --previous "$PREV1" --previous "$PREV2" >"$RUN2" 2>/dev/null
if diff -q "$RUN1" "$RUN2" >/dev/null 2>&1; then
  ok "two runs with identical inputs are byte-identical"
else
  bad "two runs differ"
fi

echo
echo "── summary ──"
echo "pass=$PASS fail=$FAIL"
[[ "$FAIL" -eq 0 ]] || exit 1
exit 0
