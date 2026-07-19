#!/usr/bin/env bash
# test_score_findings.sh — standalone offline fixture test for
# scripts/score_findings.sh. NO network, no reviewer CLIs, no tokens.
#
# Mirrors run_tests.sh's fixture/assertion conventions (assert_eq/assert_contains,
# mktemp -d + trap cleanup) but is intentionally NOT wired into run_tests.sh —
# the parent orchestrating session wires it in later (collision avoidance).
#
# Run:  bash tests/test_score_findings.sh
# Exit: 0 all green, 1 any failure.

set -uo pipefail

SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
S="$SKILL_DIR/scripts/score_findings.sh"
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

command -v jq >/dev/null 2>&1 || { echo "jq required to run these tests" >&2; exit 1; }

# ── Trimmed fixture reviewer profiles ────────────────────────────────────────
# codex: openai, P1/P2/P3-style priors (P1=high_precision, P2=medium_precision,
#   P3=skip_unless_convergent), synthesis_weight 1.0 — mirrors the real profile.
# kimi / kimi27: both moonshot (same provider — one vote together).
# antigravity / gemini-pro: both google (same provider — one vote together).
#   gemini-pro carries high_precision at Critical (mirrors the real profile).
# glm: zhipu, trust_if_convergent at High.
PROFILES="$T/reviewer_profiles.json"
cat >"$PROFILES" <<'EOF'
{
  "codex": {
    "provider": "openai",
    "synthesis_weight": 1.0,
    "severity_priors": { "P1": "high_precision", "P2": "medium_precision", "P3": "skip_unless_convergent" }
  },
  "kimi": {
    "provider": "moonshot",
    "synthesis_weight": 0.85,
    "severity_priors": { "Critical": "trust_if_convergent", "High": "verify", "Medium": "verify", "Low": "skip_unless_convergent" }
  },
  "kimi27": {
    "provider": "moonshot",
    "synthesis_weight": 0.75,
    "severity_priors": { "Critical": "trust_if_convergent", "High": "verify", "Medium": "verify", "Low": "skip_unless_convergent" }
  },
  "antigravity": {
    "provider": "google",
    "synthesis_weight": 0.85,
    "severity_priors": { "Critical": "trust_if_convergent", "High": "trust_if_convergent", "Medium": "verify", "Low": "skip_unless_convergent" }
  },
  "gemini-pro": {
    "provider": "google",
    "synthesis_weight": 1.0,
    "severity_priors": { "Critical": "high_precision", "High": "trust_if_convergent", "Medium": "verify", "Low": "skip_unless_convergent" }
  },
  "glm": {
    "provider": "zhipu",
    "synthesis_weight": 0.8,
    "severity_priors": { "Critical": "trust_if_convergent", "High": "trust_if_convergent", "Medium": "verify", "Low": "skip_unless_convergent" }
  }
}
EOF

# ── Fixture findings ─────────────────────────────────────────────────────────
FINDINGS="$T/findings.json"
cat >"$FINDINGS" <<'EOF'
{
  "base": "master",
  "findings": [
    { "id": "kimi-kimi27-low", "severity": "Low", "file": "a.ts", "line": 1,
      "snippet": "x", "claim": "nit", "sources": ["kimi", "kimi27"] },

    { "id": "codex-kimi-high", "severity": "High", "file": "b.ts", "line": 2,
      "snippet": "y", "claim": "real bug", "sources": ["codex", "kimi"] },

    { "id": "agy-pair-critical", "severity": "Critical", "file": "c.ts", "line": 3,
      "snippet": "z", "claim": "one google vote", "sources": ["antigravity", "gemini-pro"] },

    { "id": "solo-skip-low", "severity": "Low", "file": "d.ts", "line": 4,
      "snippet": "w", "claim": "solo kimi nit", "sources": ["kimi"] },

    { "id": "solo-skip-low-plus-provider", "severity": "Low", "file": "d.ts", "line": 5,
      "snippet": "w2", "claim": "solo kimi nit but glm also flagged it", "sources": ["kimi", "glm"] },

    { "id": "solo-high-precision", "severity": "High", "file": "e.ts", "line": 6,
      "snippet": "v", "claim": "solo codex P1", "sources": ["codex"] },

    { "id": "rank-critical-solo", "severity": "Critical", "file": "f.ts", "line": 7,
      "snippet": "u", "claim": "critical solo", "sources": ["codex"] },

    { "id": "rank-high-convergent", "severity": "High", "file": "g.ts", "line": 8,
      "snippet": "t", "claim": "high convergent", "sources": ["codex", "kimi"] },

    { "id": "rank-high-solo", "severity": "High", "file": "h.ts", "line": 9,
      "snippet": "s", "claim": "high solo", "sources": ["codex"] },

    { "id": "rank-high-convergent-2", "severity": "High", "file": "i.ts", "line": 10,
      "snippet": "r", "claim": "high convergent 2", "sources": ["codex", "kimi27"] }
  ]
}
EOF

OUT1="$T/out1.json"
OUT2="$T/out2.json"

echo "── score_findings.sh: RED check (script must not yet exist for the very first run) ──"
if [[ ! -x "$S" ]]; then
  echo "  (expected pre-implementation) score_findings.sh not found/executable at $S" >&2
fi

echo "── score_findings.sh (fixture scoring) ──"
bash "$S" --findings "$FINDINGS" --profiles "$PROFILES" --out "$OUT1" 2>"$T/stderr1.txt"
rc=$?
assert_eq "script exits 0 on valid input" "$rc" "0"

find_field() { # <id> <field>
  jq -r --arg id "$1" ".findings[] | select(.id==\$id) | .$2" "$OUT1"
}

assert_eq "kimi+kimi27 -> provider_votes==1" "$(find_field kimi-kimi27-low provider_votes)" "1"
assert_eq "kimi+kimi27 -> not convergent" "$(find_field kimi-kimi27-low convergent)" "false"
# Same-provider repetition doesn't rescue a skip_unless_convergent finding:
# kimi+kimi27 are both moonshot, so this Low finding is still solo at the
# provider level and should drop, same as a true single-reviewer solo.
assert_eq "kimi+kimi27 (same provider) -> still drops at Low" "$(find_field kimi-kimi27-low disposition)" "drop"

assert_eq "codex+kimi -> provider_votes==2" "$(find_field codex-kimi-high provider_votes)" "2"
assert_eq "codex+kimi -> convergent" "$(find_field codex-kimi-high convergent)" "true"

assert_eq "antigravity+gemini-pro -> 1 vote" "$(find_field agy-pair-critical provider_votes)" "1"

assert_eq "solo skip_unless_convergent -> drop" "$(find_field solo-skip-low disposition)" "drop"
assert_contains "drop reason recorded" "$(find_field solo-skip-low disposition_reason)" "skip_unless_convergent"

assert_eq "same finding + 2nd distinct provider -> keep" "$(find_field solo-skip-low-plus-provider disposition)" "keep"

assert_eq "solo high_precision -> keep" "$(find_field solo-high-precision disposition)" "keep"

echo "── ordering ──"
rank_of() { jq -r --arg id "$1" '[.findings[] | .id] | index($id)' "$OUT1"; }
crit_solo_idx="$(rank_of rank-critical-solo)"
high_conv_idx="$(rank_of rank-high-convergent)"
high_solo_idx="$(rank_of rank-high-solo)"
high_conv2_idx="$(rank_of rank-high-convergent-2)"

if [[ "$crit_solo_idx" -lt "$high_conv_idx" ]]; then
  ok "Critical solo ranks above convergent High"
else
  bad "Critical solo ranks above convergent High (idx $crit_solo_idx vs $high_conv_idx)"
fi

if [[ "$high_conv_idx" -lt "$high_solo_idx" ]]; then
  ok "among equal severity, more provider_votes ranks higher"
else
  bad "among equal severity, more provider_votes ranks higher (idx $high_conv_idx vs $high_solo_idx)"
fi

# rank-high-convergent and rank-high-convergent-2 are both High, provider_votes==2,
# same max synthesis_weight (codex 1.0 wins both) -> tie-break must still be
# deterministic (checked by the determinism test below), not necessarily any
# particular relative order between the two.
assert_eq "high-convergent-2 also outranks high-solo" "true" "$([[ "$high_conv2_idx" -lt "$high_solo_idx" ]] && echo true || echo false)"

echo "── summary object ──"
assert_eq "summary.total" "$(jq -r '.summary.total' "$OUT1")" "10"
# convergent: codex-kimi-high, solo-skip-low-plus-provider, rank-high-convergent,
# rank-high-convergent-2 = 4 (kimi+kimi27 and antigravity+gemini-pro are each
# ONE provider, so those two findings do NOT count as convergent).
assert_eq "summary.convergent count" "$(jq -r '.summary.convergent' "$OUT1")" "4"
# dropped: solo-skip-low, and kimi-kimi27-low (same-provider repetition, see above) = 2
assert_eq "summary.dropped count" "$(jq -r '.summary.dropped' "$OUT1")" "2"
# Low-severity findings: kimi-kimi27-low, solo-skip-low, solo-skip-low-plus-provider = 3
assert_eq "summary.by_severity.Low" "$(jq -r '.summary.by_severity.Low' "$OUT1")" "3"

echo "── determinism ──"
bash "$S" --findings "$FINDINGS" --profiles "$PROFILES" --out "$OUT2" 2>/dev/null
if diff -q "$OUT1" "$OUT2" >/dev/null 2>&1; then
  ok "two runs produce byte-identical output"
else
  bad "two runs produce byte-identical output (diff detected)"
fi

echo
echo "$PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
