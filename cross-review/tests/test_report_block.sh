#!/usr/bin/env bash
# test_report_block.sh — offline fixture tests for scripts/report_block.sh.
#
# Standalone: does NOT hook into run_tests.sh (parent wires that up
# separately). NO network, NO reviewer CLIs, NO tokens — pure bash+jq against
# fixture findings.json files in a temp dir.
#
# Run:  bash tests/test_report_block.sh
# Exit: 0 all green, 1 any failure.

set -uo pipefail

SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
S="$SKILL_DIR/scripts"
RB="$S/report_block.sh"
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

if [[ ! -x "$RB" ]]; then
  echo "FATAL: $RB not found or not executable — implement scripts/report_block.sh" >&2
  exit 1
fi

PROFILES="$SKILL_DIR/references/reviewer_profiles.json"

# ── Fixture A: mixed severities, one dropped finding ──────────────────────
# f1 Critical/codex(openai)               -> kept, provider_count=1
# f2 High/codex+kimi(openai+moonshot)     -> kept, provider_count=2 (convergent)
# f3 High/kimi27(moonshot)                -> kept, provider_count=1
# f4 Medium/glm(zhipu)                    -> kept, provider_count=1
# f5 Low/kimi(moonshot)                   -> kept, provider_count=1
# f6 Low/codex, factcheck drop            -> EXCLUDED from all counts
FIX_A="$T/findings.mixed.json"
cat >"$FIX_A" <<'EOF'
{
  "findings": [
    { "id": "f1", "severity": "Critical", "file": "src/auth.ts", "line": 10,
      "claim": "SQL injection via string concat", "sources": ["codex"] },
    { "id": "f2", "severity": "High", "file": "src/api.ts", "line": 20,
      "claim": "Missing null check on user input", "sources": ["codex", "kimi"],
      "factcheck": {"verdict": "keep"} },
    { "id": "f3", "severity": "High", "file": "src/util.ts", "line": 5,
      "claim": "Off-by-one in pagination", "sources": ["kimi27"] },
    { "id": "f4", "severity": "Medium", "file": "src/config.ts", "line": 30,
      "claim": "Hardcoded timeout value", "sources": ["glm"] },
    { "id": "f5", "severity": "Low", "file": "src/style.ts", "line": 1,
      "claim": "Inconsistent quote style", "sources": ["kimi"] },
    { "id": "f6", "severity": "Low", "file": "src/style.ts", "line": 2,
      "claim": "trailing whitespace", "sources": ["codex"],
      "factcheck": {"verdict": "drop", "reason": "line not present in diff"} }
  ]
}
EOF

echo "── exact block shape (golden, byte-for-byte) ──"
GOLDEN="$T/golden.txt"
cat >"$GOLDEN" <<'EOF'
── cross-review pass 2/3 ──
Verdict: NEEDS_DECISION
Counts:  C:1 H:2 M:1 L:1  (convergent: 1)
Top:     src/auth.ts:10 — SQL injection via string concat [Critical][codex]
Record:  ~/.cross-review/runs/testrepo-abc123-20260719/findings.md  (posted to PR: https://github.com/acme/testrepo/pull/42)
Next:    ask-user
Notes:   codex and kimi converged on the null-check bug.
──────────────────────────────
EOF

ACTUAL_A="$T/actual.txt"
bash "$RB" \
  --findings "$FIX_A" --pass 2 --verdict NEEDS_DECISION \
  --record "~/.cross-review/runs/testrepo-abc123-20260719/findings.md" \
  --next ask-user \
  --pr-url "https://github.com/acme/testrepo/pull/42" \
  --notes "codex and kimi converged on the null-check bug." \
  --profiles "$PROFILES" \
  >"$ACTUAL_A" 2>"$T/actual.err"

if diff -u "$GOLDEN" "$ACTUAL_A" >"$T/diff.txt" 2>&1; then
  ok "golden block matches byte-for-byte"
else
  bad "golden block mismatch"
  cat "$T/diff.txt"
fi

echo "── dropped findings excluded from counts ──"
assert_contains "L:1 (not L:2 — f6 dropped)" "$(cat "$ACTUAL_A")" "L:1"
assert_eq "Counts line has no trace of dropped f6 claim" \
  "$(grep -c 'trailing whitespace' "$ACTUAL_A" || true)" "0"

echo "── convergent counted by distinct provider ──"
FIX_CONV="$T/findings.conv.json"
cat >"$FIX_CONV" <<'EOF'
{
  "findings": [
    { "id": "c1", "severity": "Medium", "file": "a.ts", "line": 1,
      "claim": "same-provider pair (kimi+kimi27, both moonshot)",
      "sources": ["kimi", "kimi27"] },
    { "id": "c2", "severity": "Medium", "file": "b.ts", "line": 2,
      "claim": "cross-provider pair (codex+kimi, openai+moonshot)",
      "sources": ["codex", "kimi"] }
  ]
}
EOF
CONV_OUT="$(bash "$RB" --findings "$FIX_CONV" --pass 1 --verdict CLEAN \
  --record "/tmp/r.md" --next stop --profiles "$PROFILES")"
assert_contains "kimi+kimi27 NOT convergent, codex+kimi IS -> convergent:1" \
  "$CONV_OUT" "(convergent: 1)"

echo "── Top: Critical beats convergent High; among Highs, more providers wins ──"
FIX_TOP_HIGH="$T/findings.top_high.json"
cat >"$FIX_TOP_HIGH" <<'EOF'
{
  "findings": [
    { "id": "g1", "severity": "High", "file": "x.ts", "line": 1,
      "claim": "convergent high (codex+kimi27)", "sources": ["codex", "kimi27"] },
    { "id": "g2", "severity": "High", "file": "y.ts", "line": 2,
      "claim": "single-provider high (kimi+kimi27)", "sources": ["kimi", "kimi27"] }
  ]
}
EOF
TOP_HIGH_OUT="$(bash "$RB" --findings "$FIX_TOP_HIGH" --pass 1 --verdict NEEDS_DECISION \
  --record "/tmp/r.md" --next ask-user --profiles "$PROFILES")"
assert_contains "more-distinct-provider High wins Top" "$TOP_HIGH_OUT" "x.ts:1 — convergent high (codex+kimi27) [High][codex+kimi27]"

# Fixture A already asserts Critical beats a convergent High (f1 Critical wins
# over f2's codex+kimi convergent High).
assert_contains "Critical beats convergent High (fixture A)" "$(cat "$ACTUAL_A")" \
  "Top:     src/auth.ts:10 — SQL injection via string concat [Critical][codex]"

echo "── empty findings -> zeros and em-dash Top ──"
FIX_EMPTY="$T/findings.empty.json"
echo '{"findings": []}' >"$FIX_EMPTY"
EMPTY_OUT="$(bash "$RB" --findings "$FIX_EMPTY" --pass 1 --verdict CLEAN \
  --record "/tmp/r.md" --next stop --profiles "$PROFILES")"
assert_contains "empty findings -> C:0 H:0 M:0 L:0" "$EMPTY_OUT" "Counts:  C:0 H:0 M:0 L:0  (convergent: 0)"
assert_contains "empty findings -> Top: em-dash" "$EMPTY_OUT" "Top:     —"

echo "── no --pr-url -> em-dash; no --notes/--roster-decision -> em-dash ──"
assert_contains "no PR url -> posted to PR: —" "$EMPTY_OUT" "(posted to PR: —)"
assert_contains "no notes -> Notes: —" "$EMPTY_OUT" "Notes:   —"

echo "── --roster-decision fills Notes when --notes is empty ──"
ROSTER="$T/roster_decision.json"
cat >"$ROSTER" <<'EOF'
{
  "dropped": [{"reviewer": "glm", "reason": "quota_exhausted"}],
  "failed": [{"reviewer": "north", "reason": "timeout"}]
}
EOF
ROSTER_OUT="$(bash "$RB" --findings "$FIX_EMPTY" --pass 1 --verdict BLOCKED \
  --record "/tmp/r.md" --next stop --profiles "$PROFILES" --roster-decision "$ROSTER")"
assert_contains "roster-decision summarized into Notes" "$ROSTER_OUT" \
  "Notes:   glm dropped (quota_exhausted); north failed (timeout)"

echo "── determinism: identical inputs -> byte-identical output ──"
RUN1="$T/run1.txt"; RUN2="$T/run2.txt"
bash "$RB" --findings "$FIX_A" --pass 2 --verdict NEEDS_DECISION \
  --record "~/.cross-review/runs/testrepo-abc123-20260719/findings.md" \
  --next ask-user --pr-url "https://github.com/acme/testrepo/pull/42" \
  --notes "codex and kimi converged on the null-check bug." \
  --profiles "$PROFILES" >"$RUN1"
bash "$RB" --findings "$FIX_A" --pass 2 --verdict NEEDS_DECISION \
  --record "~/.cross-review/runs/testrepo-abc123-20260719/findings.md" \
  --next ask-user --pr-url "https://github.com/acme/testrepo/pull/42" \
  --notes "codex and kimi converged on the null-check bug." \
  --profiles "$PROFILES" >"$RUN2"
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
