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
assert_eq "codex severity_accuracy 1" "$CODEX_ACC" "1"
KIMI_ACC="$(jq -r '.caught[] | select(.reviewer=="kimi") | .severity_accuracy' "$OUT1")"
assert_eq "kimi severity_accuracy 1" "$KIMI_ACC" "1"

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
assert_eq "medium call: severity_accuracy 0.5" "$CODEX_ACC3" "0.5"
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
if [[ "$(id -u)" -ne 0 ]]; then
  mkdir -p "$T/ro" && chmod 500 "$T/ro"
  bash "$S/grade_planted.sh" --planted "$PLANTED" --findings "$T/findings.anchored.json" --roster "$ROSTER" --project "$PROJECT" --out "$T/ro/g.json" >/dev/null 2>&1
  RC7=$?; chmod 700 "$T/ro"
  assert_eq "unwritable output directory exits 2" "$RC7" "2"
else
  ok "unwritable output directory exits 2 (skipped as root)"
fi
mkdir -p "$T/outdir"
bash "$S/grade_planted.sh" --planted "$PLANTED" --findings "$T/findings.anchored.json" --roster "$ROSTER" --project "$PROJECT" --out "$T/outdir" >/dev/null 2>&1
assert_eq "--out naming a directory exits 2" "$?" "2"
jq '.line_range = [7, 7, 9]' "$PLANTED" >"$T/planted-3.json"
bash "$S/grade_planted.sh" --planted "$T/planted-3.json" --findings "$T/findings.anchored.json" --roster "$ROSTER" --project "$PROJECT" --out "$T/g7f.json" >/dev/null 2>&1
assert_eq "line_range with 3 elements exits 2" "$?" "2"
jq '.line_range = ["7", "7"]' "$PLANTED" >"$T/planted-s.json"
bash "$S/grade_planted.sh" --planted "$T/planted-s.json" --findings "$T/findings.anchored.json" --roster "$ROSTER" --project "$PROJECT" --out "$T/g7g.json" >/dev/null 2>&1
assert_eq "line_range of numeric strings exits 2" "$?" "2"

# ── 8. --judge agy: a per-candidate factcheck-lane verdict gates credit ─────
# Fake agy on PATH ($T/bin, prepended only for these invocations — mirrors
# run_tests.sh's PATH-shim convention). FAKE_JUDGE_ANSWER selects the canned
# verdict so we can drive yes/no/garbage/fail without a real model.
mkdir -p "$T/bin"
cat >"$T/bin/agy" <<'SHIM'
#!/bin/sh
if [ "$1" = "models" ]; then printf "Gemini 3.7 Flash (High)\n"; exit 0; fi
case "$FAKE_JUDGE_ANSWER" in
  yes) printf "Yes. This matches the planted nullish-coalescing weakening exactly.\n" ;;
  no)  printf "No. This does not describe the planted defect.\n" ;;
  garbage) printf "Unclear, cannot determine either way.\n" ;;
  multiline) printf "\nNo.\nThis finding is about a different line entirely.\n" ;;
  utf8) printf "Yes. r\303\251sum\303\251 \360\237\230\200\360\237\230\200\360\237\230\200\360\237\230\200\360\237\230\200\360\237\230\200\360\237\230\200\360\237\230\200\360\237\230\200\360\237\230\200\360\237\230\200\360\237\230\200\360\237\230\200\360\237\230\200\360\237\230\200\360\237\230\200\360\237\230\200\360\237\230\200\360\237\230\200\360\237\230\200\360\237\230\200\360\237\230\200\360\237\230\200\360\237\230\200\360\237\230\200\360\237\230\200\360\237\230\200\360\237\230\200\360\237\230\200\360\237\230\200\360\237\230\200\360\237\230\200\360\237\230\200\360\237\230\200\360\237\230\200\360\237\230\200\360\237\230\200\360\237\230\200\360\237\230\200\360\237\230\200\360\237\230\200\360\237\230\200\360\237\230\200\360\237\230\200\360\237\230\200\360\237\230\200\360\237\230\200\360\237\230\200\360\237\230\200\360\237\230\200\360\237\230\200\360\237\230\200\360\237\230\200\360\237\230\200\360\237\230\200\360\237\230\200\360\237\230\200\360\237\230\200\360\237\230\200\360\237\230\200\n" ;;
  failout) printf "No route to model\n"; exit 1 ;;
  seq) n=0; [ -f "$FAKE_JUDGE_COUNTER" ] && n=$(cat "$FAKE_JUDGE_COUNTER"); n=$((n + 1)); printf '%s' "$n" >"$FAKE_JUDGE_COUNTER"; if [ "$n" -eq 1 ]; then printf "No. Wrong site.\n"; else printf "Yes. This is it.\n"; fi ;;
  fail) exit 1 ;;
  *) printf "Yes.\n" ;;
esac
SHIM
chmod +x "$T/bin/agy"

# (a) shim answers "no" for the sole matched candidate -> codex+kimi demoted,
# nobody credited by it (kat was already missed — different file/out of window).
OUT8A="$T/grade8a.json"
FAKE_JUDGE_ANSWER=no PATH="$T/bin:$PATH" bash "$S/grade_planted.sh" --planted "$PLANTED" \
  --findings "$T/findings.anchored.json" --roster "$ROSTER" --project "$PROJECT" \
  --judge agy --out "$OUT8A" >/dev/null 2>"$T/err8a.txt"
assert_eq "judge agy no: exits 0" "$?" "0"
assert_eq "judge agy no: codex+kimi demoted to missed alongside kat" \
  "$(jq -r '.missed[]' "$OUT8A" | sort | tr '\n' ',')" "codex,kat,kimi,"
assert_eq "judge agy no: nobody caught" "$(jq -r '.caught | length' "$OUT8A")" "0"
assert_eq "judge agy no: candidates[0].judge.verdict == no" \
  "$(jq -r '.candidates[0].judge.verdict' "$OUT8A")" "no"

# (b) shim answers "yes" -> caught, judged: true
OUT8B="$T/grade8b.json"
FAKE_JUDGE_ANSWER=yes PATH="$T/bin:$PATH" bash "$S/grade_planted.sh" --planted "$PLANTED" \
  --findings "$T/findings.anchored.json" --roster "$ROSTER" --project "$PROJECT" \
  --judge agy --out "$OUT8B" >/dev/null 2>"$T/err8b.txt"
assert_eq "judge agy yes: codex+kimi caught" \
  "$(jq -r '.caught[].reviewer' "$OUT8B" | sort | tr '\n' ',')" "codex,kimi,"
assert_eq "judge agy yes: codex judged true" \
  "$(jq -r '.caught[] | select(.reviewer=="codex") | .judged' "$OUT8B")" "true"
assert_eq "judge agy yes: candidates[0].judge.verdict == yes" \
  "$(jq -r '.candidates[0].judge.verdict' "$OUT8B")" "yes"

# (c) shim exits 1 -> fail-open: still caught, judge.verdict == unavailable
OUT8C="$T/grade8c.json"
FAKE_JUDGE_ANSWER=fail PATH="$T/bin:$PATH" bash "$S/grade_planted.sh" --planted "$PLANTED" \
  --findings "$T/findings.anchored.json" --roster "$ROSTER" --project "$PROJECT" \
  --judge agy --out "$OUT8C" >/dev/null 2>"$T/err8c.txt"
assert_eq "judge agy unavailable (agy exits 1): codex+kimi still caught (fail-open)" \
  "$(jq -r '.caught[].reviewer' "$OUT8C" | sort | tr '\n' ',')" "codex,kimi,"
assert_eq "judge agy unavailable: candidates[0].judge.verdict == unavailable" \
  "$(jq -r '.candidates[0].judge.verdict' "$OUT8C")" "unavailable"
assert_eq "judge agy unavailable: codex judged false" \
  "$(jq -r '.caught[] | select(.reviewer=="codex") | .judged' "$OUT8C")" "false"

# ── 9. --judge openrouter: request carries the planted mutation + candidate
#      claim, and the API key never leaks to stdout/stderr ─────────────────
cat >"$T/bin/curl" <<SHIM
#!/bin/sh
prev=""
for a in "\$@"; do
  case "\$prev" in
    -d) case "\$a" in @*) cat "\${a#@}" > "$T/req.json" ;; esac ;;
  esac
  prev="\$a"
done
if [ "\$FAKE_JUDGE_ANSWER" = "no" ]; then
  printf '{"choices":[{"message":{"content":"No. Does not match the planted mutation."}}]}\n'
else
  printf '{"choices":[{"message":{"content":"Yes. Matches the planted mutation exactly."}}]}\n'
fi
SHIM
chmod +x "$T/bin/curl"

OUT9="$T/grade9.json"
FAKE_JUDGE_ANSWER=no OPENROUTER_API_KEY="sk-or-SECRET" PATH="$T/bin:$PATH" \
  bash "$S/grade_planted.sh" --planted "$PLANTED" --findings "$T/findings.anchored.json" \
  --roster "$ROSTER" --project "$PROJECT" --judge openrouter --out "$OUT9" \
  >"$T/out9.txt" 2>"$T/err9.txt"
assert_eq "judge openrouter no: exits 0" "$?" "0"
assert_eq "judge openrouter no: codex+kimi missed alongside kat" \
  "$(jq -r '.missed[]' "$OUT9" | sort | tr '\n' ',')" "codex,kat,kimi,"
assert_contains "openrouter judge request body carries the planted mutated_line" \
  "$(cat "$T/req.json" 2>/dev/null)" "opts.timeout || 5000"
assert_contains "openrouter judge request body carries the candidate claim" \
  "$(cat "$T/req.json" 2>/dev/null)" "nullish coalescing weakened to logical OR"
if grep -q 'SECRET' "$T/out9.txt" "$T/err9.txt" 2>/dev/null; then
  bad "OpenRouter API key is never echoed to stdout/stderr"
else
  ok "OpenRouter API key is never echoed to stdout/stderr"
fi
rm -f "$T/bin/curl" "$T/req.json"

# ── 10. --judge none: output unchanged for the base fixture ────────────────
OUT10="$T/grade10.json"
bash "$S/grade_planted.sh" --planted "$PLANTED" --findings "$T/findings.anchored.json" \
  --roster "$ROSTER" --project "$PROJECT" --judge none --out "$OUT10" >/dev/null 2>"$T/err10.txt"
assert_eq "judge none: candidates[0] stays a plain id string" \
  "$(jq -r '.candidates[0]' "$OUT10")" "f-aaaa1111"
assert_eq "judge none: caught codex has no judged key" \
  "$(jq -r '.caught[] | select(.reviewer=="codex") | has("judged")' "$OUT10")" "false"
assert_eq "judge none: recall unchanged" "$(jq -r '.recall' "$OUT10")" "0.67"
# ── PR #126 review: multi-line verdicts, unparseable output, crash-with-stdout,
#    UTF-8 note truncation, and a second candidate rescuing a seat ───────────
OUT11="$T/grade11.json"
FAKE_JUDGE_ANSWER=multiline PATH="$T/bin:$PATH" bash "$S/grade_planted.sh" --planted "$PLANTED" --findings "$T/findings.anchored.json" --roster "$ROSTER" --project "$PROJECT" --judge agy --out "$OUT11" >/dev/null 2>&1
assert_eq "multi-line 'No.' reply parses as no" "$(jq -r '.candidates[0].judge.verdict' "$OUT11")" "no"
assert_eq "multi-line 'No.' reply demotes the seats" "$(jq -r '.caught | length' "$OUT11")" "0"
OUT12="$T/grade12.json"
FAKE_JUDGE_ANSWER=garbage PATH="$T/bin:$PATH" bash "$S/grade_planted.sh" --planted "$PLANTED" --findings "$T/findings.anchored.json" --roster "$ROSTER" --project "$PROJECT" --judge agy --out "$OUT12" >/dev/null 2>&1
assert_eq "unparseable reply is unavailable" "$(jq -r '.candidates[0].judge.verdict' "$OUT12")" "unavailable"
assert_eq "unparseable reply fails open: caught but judged=false" "$(jq -r '[.caught[] | .judged] | unique | join(",")' "$OUT12")" "false"
OUT13="$T/grade13.json"
FAKE_JUDGE_ANSWER=failout PATH="$T/bin:$PATH" bash "$S/grade_planted.sh" --planted "$PLANTED" --findings "$T/findings.anchored.json" --roster "$ROSTER" --project "$PROJECT" --judge agy --out "$OUT13" >/dev/null 2>&1
assert_eq "a crashed agy that printed 'No route' is unavailable, not no" "$(jq -r '.candidates[0].judge.verdict' "$OUT13")" "unavailable"
OUT14="$T/grade14.json"
FAKE_JUDGE_ANSWER=utf8 PATH="$T/bin:$PATH" bash "$S/grade_planted.sh" --planted "$PLANTED" --findings "$T/findings.anchored.json" --roster "$ROSTER" --project "$PROJECT" --judge agy --out "$OUT14" >/dev/null 2>&1
assert_eq "a reply truncated inside a multibyte char still yields a grade" "$(jq -r '.candidates[0].judge.verdict' "$OUT14")" "yes"
# two candidates for codex: the judge rejects the first and accepts the second
cat >"$T/findings-two.json" <<'EOF'
{"findings": [
  {"id": "f-first", "file": "src/a.ts", "line": 8, "severity": "High", "sources": ["codex"], "claim": "wrong site", "snippet": "x", "anchor": {"resolved": true, "start_line": 8, "end_line": 8, "side": "new"}},
  {"id": "f-second", "file": "src/a.ts", "line": 9, "severity": "High", "sources": ["codex"], "claim": "nullish weakened", "snippet": "y", "anchor": {"resolved": true, "start_line": 9, "end_line": 9, "side": "new"}}
]}
EOF
OUT15="$T/grade15.json"; rm -f "$T/judge-counter"
FAKE_JUDGE_ANSWER=seq FAKE_JUDGE_COUNTER="$T/judge-counter" PATH="$T/bin:$PATH" bash "$S/grade_planted.sh" --planted "$PLANTED" --findings "$T/findings-two.json" --roster "codex" --project "$PROJECT" --judge agy --out "$OUT15" >/dev/null 2>&1
assert_eq "second candidate rescues the seat after the first is demoted" "$(jq -r '.caught[0].reviewer // "none"' "$OUT15")" "codex"
assert_eq "the crediting candidate is the second one" "$(jq -r '.caught[0].matched_finding_id' "$OUT15")" "f-second"
assert_eq "candidate verdicts are no,yes" "$(jq -r '[.candidates[].judge.verdict] | join(",")' "$OUT15")" "no,yes"
rm -f "$T/bin/agy"

echo ""
echo "PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]] || exit 1
