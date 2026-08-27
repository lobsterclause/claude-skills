#!/usr/bin/env bash
# test_grade_planted.sh — standalone offline fixture test for
# scripts/grade_planted.sh. NO network, no reviewer CLIs, no tokens.
#
# Mirrors run_tests.sh's fixture/assertion conventions (assert_eq/assert_contains,
# mktemp -d + trap cleanup) but is intentionally NOT wired into run_tests.sh —
# the parent orchestrating session wires it in later (collision avoidance; see
# tests/test_digest.sh / tests/test_plant_mutation.sh for the same pattern).
#
# Run:  bash tests/test_grade_planted.sh
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

# ── fixtures ─────────────────────────────────────────────────────────────────
PLANTED="$T/planted.json"
cat >"$PLANTED" <<'EOF'
{
  "schema_version": 1,
  "synthetic": true,
  "run_id": "mutation-42",
  "operator": "nullish",
  "class": "logic",
  "file": "src/a.ts",
  "line_range": [7, 7],
  "expected_severity": "High",
  "seed": 42,
  "base": "deadbeef",
  "head": "cafebabe",
  "mutation_branch": "mutation/mutation-42",
  "mutation_sha": "cafebabe",
  "original_line": "  const timeout = opts.timeout ?? 5000;",
  "mutated_line": "  const timeout = opts.timeout || 5000;"
}
EOF

# findings.anchored.json:
#   (i)   src/a.ts line 8 (anchor resolved -> start_line 8), sources [codex, kimi], High
#   (ii)  src/a.ts line 40, sources [kat] -- outside the +/-3 window
#   (iii) src/b.ts line 7, sources [kat] -- different file entirely
mk_findings() {
  local severity_i="$1"
  cat >"$T/findings.anchored.json" <<EOF
{
  "findings": [
    {
      "id": "f-aaaa1111",
      "file": "src/a.ts",
      "line": 8,
      "severity": "$severity_i",
      "snippet": "const timeout = opts.timeout || 5000;",
      "claim": "nullish coalescing weakened to logical OR",
      "sources": ["codex", "kimi"],
      "anchor": {"resolved": true, "start_line": 8, "end_line": 8, "side": "new"}
    },
    {
      "id": "f-bbbb2222",
      "file": "src/a.ts",
      "line": 40,
      "severity": "Low",
      "snippet": "unrelated line",
      "claim": "unrelated finding far from the planted site",
      "sources": ["kat"],
      "anchor": {"resolved": false, "start_line": 0, "end_line": 0, "side": "none"}
    },
    {
      "id": "f-cccc3333",
      "file": "src/b.ts",
      "line": 7,
      "severity": "High",
      "snippet": "different file",
      "claim": "finding in a different file entirely",
      "sources": ["kat"],
      "anchor": {"resolved": true, "start_line": 7, "end_line": 7, "side": "new"}
    }
  ]
}
EOF
}
mk_findings "High"

ROSTER="codex,kimi,kat"
PROJECT="test-project"

# ── 1. base case: window=3 (default), High severity call ──────────────────
OUT1="$T/grade1.json"
bash "$S/grade_planted.sh" --planted "$PLANTED" --findings "$T/findings.anchored.json" \
  --roster "$ROSTER" --project "$PROJECT" --out "$OUT1" >/dev/null 2>"$T/err1.txt"
RC1=$?
assert_eq "base case exits 0" "$RC1" "0"

CAUGHT_REVIEWERS="$(jq -r '.caught[].reviewer' "$OUT1" | sort | tr '\n' ',' )"
assert_eq "caught = codex,kimi" "$CAUGHT_REVIEWERS" "codex,kimi,"
MISSED_REVIEWERS="$(jq -r '.missed[]' "$OUT1" | sort | tr '\n' ',')"
assert_eq "missed = kat" "$MISSED_REVIEWERS" "kat,"

CODEX_ACC="$(jq -r '.caught[] | select(.reviewer=="codex") | .severity_accuracy' "$OUT1")"
assert_eq "codex severity_accuracy 1.00" "$CODEX_ACC" "1.00"
KIMI_ACC="$(jq -r '.caught[] | select(.reviewer=="kimi") | .severity_accuracy' "$OUT1")"
assert_eq "kimi severity_accuracy 1.00" "$KIMI_ACC" "1.00"

RECALL1="$(jq -r '.recall' "$OUT1")"
assert_eq "recall pinned format 0.67" "$RECALL1" "0.67"

CANDIDATES1="$(jq -r '.candidates | length' "$OUT1")"
assert_eq "candidates = 1 id" "$CANDIDATES1" "1"
CAND_ID1="$(jq -r '.candidates[0]' "$OUT1")"
assert_eq "candidate id is f-aaaa1111" "$CAND_ID1" "f-aaaa1111"

MATCHED_ID_CODEX="$(jq -r '.caught[] | select(.reviewer=="codex") | .matched_finding_id' "$OUT1")"
assert_eq "codex matched_finding_id" "$MATCHED_ID_CODEX" "f-aaaa1111"

PLANTED_ID1="$(jq -r '.planted_id' "$OUT1")"
assert_contains "planted_id has f-planted- prefix" "$PLANTED_ID1" "f-planted-"

# ── 2. --window 0 → nobody catches ─────────────────────────────────────────
OUT2="$T/grade2.json"
bash "$S/grade_planted.sh" --planted "$PLANTED" --findings "$T/findings.anchored.json" \
  --roster "$ROSTER" --project "$PROJECT" --window 0 --out "$OUT2" >/dev/null 2>"$T/err2.txt"
CAUGHT2="$(jq -r '.caught | length' "$OUT2")"
assert_eq "window 0: nobody caught" "$CAUGHT2" "0"
MISSED2="$(jq -r '.missed | length' "$OUT2")"
assert_eq "window 0: everyone missed" "$MISSED2" "3"
RECALL2="$(jq -r '.recall' "$OUT2")"
assert_eq "window 0: recall 0.00" "$RECALL2" "0.00"

# ── 3. Medium call on the same site → accuracy 0.5 ─────────────────────────
mk_findings "Medium"
OUT3="$T/grade3.json"
bash "$S/grade_planted.sh" --planted "$PLANTED" --findings "$T/findings.anchored.json" \
  --roster "$ROSTER" --project "$PROJECT" --out "$OUT3" >/dev/null 2>"$T/err3.txt"
CODEX_ACC3="$(jq -r '.caught[] | select(.reviewer=="codex") | .severity_accuracy' "$OUT3")"
assert_eq "medium call: severity_accuracy 0.50" "$CODEX_ACC3" "0.50"
mk_findings "High"

# ── 4. --emit-events ────────────────────────────────────────────────────────
EV="$T/ev.jsonl"
rm -f "$EV"
OUT4="$T/grade4.json"
CROSS_REVIEW_FINDING_EVENTS="$EV" bash "$S/grade_planted.sh" --planted "$PLANTED" \
  --findings "$T/findings.anchored.json" --roster "$ROSTER" --project "$PROJECT" \
  --out "$OUT4" --emit-events >/dev/null 2>"$T/err4.txt"

N_PLANTED_EV="$(jq -r 'select(.event=="planted")' "$EV" | jq -s 'length')"
assert_eq "emit-events: 1 planted event" "$N_PLANTED_EV" "1"
N_CAUGHT_EV="$(jq -r 'select(.event=="caught")' "$EV" | jq -s 'length')"
assert_eq "emit-events: 2 caught events" "$N_CAUGHT_EV" "2"
N_MISSED_EV="$(jq -r 'select(.event=="missed")' "$EV" | jq -s 'length')"
assert_eq "emit-events: 1 missed event" "$N_MISSED_EV" "1"

PLANTED_ID4="$(jq -r '.planted_id' "$OUT4")"
EV_RUN_IDS="$(jq -r 'select(.finding_id=="'"$PLANTED_ID4"'") | .run_id' "$EV" | sort -u)"
assert_eq "emit-events: all events tagged with run_id mutation-42" "$EV_RUN_IDS" "mutation-42"
N_EV_WITH_SYNTH_ID="$(jq -s --arg id "$PLANTED_ID4" '[.[] | select(.finding_id == $id)] | length' "$EV")"
assert_eq "emit-events: all 4 events carry the synthetic id" "$N_EV_WITH_SYNTH_ID" "4"

# ── 5. running twice yields the same planted_id ─────────────────────────────
OUT5="$T/grade5.json"
bash "$S/grade_planted.sh" --planted "$PLANTED" --findings "$T/findings.anchored.json" \
  --roster "$ROSTER" --project "$PROJECT" --out "$OUT5" >/dev/null 2>"$T/err5.txt"
PLANTED_ID5="$(jq -r '.planted_id' "$OUT5")"
assert_eq "planted_id is deterministic across runs" "$PLANTED_ID5" "$PLANTED_ID1"

# ── 6. missing --roster exits 2 ─────────────────────────────────────────────
bash "$S/grade_planted.sh" --planted "$PLANTED" --findings "$T/findings.anchored.json" \
  --project "$PROJECT" --out "$T/grade6.json" >/dev/null 2>"$T/err6.txt"
RC6=$?
assert_eq "missing --roster exits 2" "$RC6" "2"

# ── 7. PR #114 review: validation, roster hygiene, line-0 edge, output write ──
mk_findings "High"
printf '{"findings": "nope"}\n' >"$T/bad-findings.json"
bash "$S/grade_planted.sh" --planted "$PLANTED" --findings "$T/bad-findings.json" --roster "$ROSTER" --project "$PROJECT" --out "$T/g7a.json" >/dev/null 2>&1
assert_eq "findings without a .findings array exits 2" "$?" "2"
jq '.line_range = ["seven", 7]' "$PLANTED" >"$T/bad-planted.json"
bash "$S/grade_planted.sh" --planted "$T/bad-planted.json" --findings "$T/findings.anchored.json" --roster "$ROSTER" --project "$PROJECT" --out "$T/g7b.json" >/dev/null 2>&1
assert_eq "non-integer line_range exits 2" "$?" "2"
OUT7="$T/g7c.json"
bash "$S/grade_planted.sh" --planted "$PLANTED" --findings "$T/findings.anchored.json" --roster " codex , kimi,codex,kat" --project "$PROJECT" --out "$OUT7" >/dev/null 2>&1
assert_eq "roster with spaces/duplicates: caught codex,kimi once each" "$(jq -r '.caught[].reviewer' "$OUT7" | sort | tr '\n' ',')" "codex,kimi,"
assert_eq "roster with spaces/duplicates: recall over 3 unique seats" "$(jq -r '.recall' "$OUT7")" "0.67"
assert_eq "recall_raw is numeric" "$(jq -r '.recall_raw * 100 | round' "$OUT7")" "67"
# mutation at line 2: an unanchored finding with line 0 must NOT fall inside [-1, 5]
jq '.line_range = [2, 2]' "$PLANTED" >"$T/planted-l2.json"
cat >"$T/findings-l0.json" <<'EOF'
{"findings": [{"id": "f-zero", "file": "src/a.ts", "line": 0, "severity": "High", "sources": ["codex"], "anchor": {"resolved": false, "start_line": 0, "end_line": 0, "side": "none"}}]}
EOF
bash "$S/grade_planted.sh" --planted "$T/planted-l2.json" --findings "$T/findings-l0.json" --roster "codex" --project "$PROJECT" --out "$T/g7d.json" >/dev/null 2>&1
assert_eq "line-0 finding never matches a mutation near line 1" "$(jq -r '.missed | length' "$T/g7d.json")" "1"
cat >"$T/findings-noid.json" <<'EOF'
{"findings": [{"file": "src/a.ts", "line": 8, "severity": "High", "sources": ["codex"]}]}
EOF
bash "$S/grade_planted.sh" --planted "$PLANTED" --findings "$T/findings-noid.json" --roster "codex" --project "$PROJECT" --out "$T/g7e.json" >/dev/null 2>"$T/err7e.txt"
assert_contains "id-less candidate is skipped with a WARN" "$(cat "$T/err7e.txt")" "no id"
assert_eq "id-less candidate does not count as caught" "$(jq -r '.caught | length' "$T/g7e.json")" "0"
mkdir -p "$T/ro" && chmod 500 "$T/ro"
bash "$S/grade_planted.sh" --planted "$PLANTED" --findings "$T/findings.anchored.json" --roster "$ROSTER" --project "$PROJECT" --out "$T/ro/g.json" >/dev/null 2>&1
RC7=$?; chmod 700 "$T/ro"
assert_eq "unwritable output directory exits 2" "$RC7" "2"

echo ""
echo "PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]] || exit 1
