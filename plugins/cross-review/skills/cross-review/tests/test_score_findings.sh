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


echo "null-source filtering"
cat >"$T/nullsrc.json" <<'EOF2'
{"findings":[{"id":"n1","severity":"Low","file":"x.sh","line":1,"snippet":"s","claim":"c","sources":["codex",null]}]}
EOF2
bash "$S" --findings "$T/nullsrc.json" --profiles "$PROFILES" --out "$T/nullsrc.out.json" 2>"$T/nullsrc.err"
assert_eq "null-source run exits 0" "$?" "0"
assert_eq "null source filtered, codex vote survives" \
  "$(jq -r '.findings[0].provider_votes' "$T/nullsrc.out.json")" "1"

echo
echo "── capability axis (issue #70): agreement between hunk-only seats is not independent ──"
# Profiles WITH prompt_style — the real roster shape. codex is an agent,
# gemini-pro has the workspace, everything else is a single completion with
# the diff pasted in (diff_only_no_tools).
CAP_PROFILES="$T/cap_profiles.json"
cat >"$CAP_PROFILES" <<'EOF'
{
  "codex":      { "provider": "openai",   "prompt_style": "builtin_review",     "synthesis_weight": 1.0,
                  "severity_priors": { "P1": "high_precision", "P2": "medium_precision", "P3": "skip_unless_convergent" } },
  "gemini-pro": { "provider": "google",   "prompt_style": "custom_with_tools",  "synthesis_weight": 1.0,
                  "severity_priors": { "Critical": "high_precision", "High": "trust_if_convergent", "Medium": "verify", "Low": "skip_unless_convergent" } },
  "kimi":       { "provider": "moonshot", "prompt_style": "diff_only_no_tools", "synthesis_weight": 0.85,
                  "severity_priors": { "Critical": "trust_if_convergent", "High": "verify", "Medium": "verify", "Low": "skip_unless_convergent" } },
  "kimi27":     { "provider": "moonshot", "prompt_style": "diff_only_no_tools", "synthesis_weight": 0.75,
                  "severity_priors": { "Critical": "trust_if_convergent", "High": "verify", "Medium": "verify", "Low": "skip_unless_convergent" } },
  "glm":        { "provider": "zhipu",    "prompt_style": "diff_only_no_tools", "synthesis_weight": 0.8,
                  "severity_priors": { "Critical": "trust_if_convergent", "High": "trust_if_convergent", "Medium": "verify", "Low": "skip_unless_convergent" } },
  "qwen":       { "provider": "alibaba",  "prompt_style": "diff_only_no_tools", "synthesis_weight": 0.7,
                  "severity_priors": { "Critical": "trust_if_convergent", "High": "trust_if_convergent", "Medium": "verify", "Low": "skip_unless_convergent" } },
  "mystery":    { "provider": "acme", "synthesis_weight": 0.5,
                  "severity_priors": { "High": "trust_if_convergent" } }
}
EOF
CAP_FINDINGS="$T/cap_findings.json"
cat >"$CAP_FINDINGS" <<'EOF'
{ "findings": [
  { "id": "two-hunk-only",    "severity": "High", "file": "a.sh", "line": 1, "snippet": "x", "claim": "mktemp -p is not portable", "sources": ["glm", "qwen"] },
  { "id": "capable-plus-hunk","severity": "High", "file": "b.sh", "line": 2, "snippet": "y", "claim": "real",                    "sources": ["codex", "glm"] },
  { "id": "three-hunk-only",  "severity": "High", "file": "c.sh", "line": 3, "snippet": "z", "claim": "three partial views",     "sources": ["kimi", "glm", "qwen"] },
  { "id": "same-provider-two","severity": "High", "file": "d.sh", "line": 4, "snippet": "w", "claim": "kimi twice",              "sources": ["kimi", "kimi27"] },
  { "id": "two-capable",      "severity": "High", "file": "e.sh", "line": 5, "snippet": "v", "claim": "codex+gemini",            "sources": ["codex", "gemini-pro"] },
  { "id": "low-two-hunk-only","severity": "Low",  "file": "f.sh", "line": 6, "snippet": "u", "claim": "nit from two hunk seats", "sources": ["glm", "qwen"] },
  { "id": "unknown-plus-hunk","severity": "High", "file": "g.sh", "line": 7, "snippet": "t", "claim": "unprofiled style",        "sources": ["mystery", "glm"] }
] }
EOF
CAP_OUT="$T/cap_out.json"
bash "$S" --findings "$CAP_FINDINGS" --profiles "$CAP_PROFILES" --out "$CAP_OUT" 2>"$T/cap_err.txt"
assert_eq "capability run exits 0" "$?" "0"
cap_field() { jq -r --arg id "$1" ".findings[] | select(.id==\$id) | .$2" "$CAP_OUT"; }

assert_eq "glm+qwen: two providers agree…" "$(cap_field two-hunk-only provider_votes)" "2"
assert_eq "…but both are diff_only → capability_votes=1" "$(cap_field two-hunk-only capability_votes)" "1"
assert_eq "…so NOT convergent" "$(cap_field two-hunk-only convergent)" "false"
assert_contains "…and the note says why" "$(cap_field two-hunk-only convergence_note)" "share an input truncation"
assert_contains "…naming each seat's access" "$(cap_field two-hunk-only convergence_note)" "glm=diff_only"
assert_eq "…which makes a trust_if_convergent High → verify, not keep" "$(cap_field two-hunk-only disposition)" "verify"
assert_eq "context_access map derived from prompt_style" "$(cap_field two-hunk-only 'context_access | to_entries | map(.key + ":" + .value) | join(",")')" "glm:diff_only,qwen:diff_only"

assert_eq "codex+glm: one agent + one hunk-only = 1.5" "$(cap_field capable-plus-hunk capability_votes)" "1.5"
assert_eq "…IS convergent (one capable seat with corroboration)" "$(cap_field capable-plus-hunk convergent)" "true"
assert_eq "…no note on a convergent finding" "$(cap_field capable-plus-hunk convergence_note)" "null"

assert_eq "kimi+glm+qwen: three hunk-only seats = 1.5" "$(cap_field three-hunk-only capability_votes)" "1.5"
assert_eq "…three independent partial views DO converge" "$(cap_field three-hunk-only convergent)" "true"

assert_eq "kimi+kimi27: one provider, best seat 0.5" "$(cap_field same-provider-two capability_votes)" "0.5"
assert_eq "…not convergent (provider rule still binds first)" "$(cap_field same-provider-two convergent)" "false"
assert_eq "…and no capability note — the PROVIDER rule blocked it, not the floor" "$(cap_field same-provider-two convergence_note)" "null"

assert_eq "codex+gemini-pro: 2.0" "$(cap_field two-capable capability_votes)" "2"
assert_eq "…convergent" "$(cap_field two-capable convergent)" "true"

assert_eq "Low from two hunk-only seats: skip_unless_convergent + not convergent → drop" "$(cap_field low-two-hunk-only disposition)" "drop"
assert_contains "…drop reason carries the capability arithmetic" "$(cap_field low-two-hunk-only disposition_reason)" "capability_votes=1"

assert_eq "unprofiled prompt_style counts as a full vote (never penalise the unseen)" "$(cap_field unknown-plus-hunk capability_votes)" "1.5"
assert_contains "…and the scorer says it is guessing" "$(cat "$T/cap_err.txt")" "no context_access known for 'mystery'"
# two-hunk-only (High) and low-two-hunk-only (Low) are both glm+qwen = 2
assert_eq "summary counts the capability-blocked agreements" "$(jq -r '.summary.convergence_blocked_by_capability' "$CAP_OUT")" "2"
assert_contains "no --meta-dir + a blocked finding → stderr hint to pass it" "$(cat "$T/cap_err.txt")" "pass --meta-dir"

echo "── ordering: capability_votes, not provider_votes, is the second key ──"
ord_two_hunk="$(jq -r '[.findings[] | .id] | index("two-hunk-only")' "$CAP_OUT")"
ord_cap_hunk="$(jq -r '[.findings[] | .id] | index("capable-plus-hunk")' "$CAP_OUT")"
[[ "$ord_cap_hunk" -lt "$ord_two_hunk" ]] \
  && ok "codex+glm (1.5) outranks glm+qwen (1.0) at equal severity and equal provider count" \
  || bad "codex+glm should outrank glm+qwen (idx $ord_cap_hunk vs $ord_two_hunk)"

echo "── --meta-dir: what the seat actually saw this run overrides the lane default ──"
META="$T/meta"; mkdir -p "$META"
printf '{"exit_code": 0, "context_access": "file_context"}\n' >"$META/glm.meta.json"
printf '{"exit_code": 0, "context_access": "file_context"}\n' >"$META/qwen.meta.json"
printf '{"exit_code": 0}\n' >"$META/kimi.meta.json"   # pre-2026-08-26 meta: no field → lane default
CAP_OUT2="$T/cap_out2.json"
bash "$S" --findings "$CAP_FINDINGS" --profiles "$CAP_PROFILES" --meta-dir "$META" --out "$CAP_OUT2" 2>"$T/cap_err2.txt"
assert_eq "meta-dir run exits 0" "$?" "0"
cap2_field() { jq -r --arg id "$1" ".findings[] | select(.id==\$id) | .$2" "$CAP_OUT2"; }
assert_eq "glm+qwen with whole files this run → 2.0" "$(cap2_field two-hunk-only capability_votes)" "2"
assert_eq "…now convergent" "$(cap2_field two-hunk-only convergent)" "true"
assert_eq "…context_access reflects the meta" "$(cap2_field two-hunk-only 'context_access.glm')" "file_context"
assert_eq "a meta file without the field keeps the lane default" "$(cap2_field three-hunk-only 'context_access.kimi')" "diff_only"
assert_eq "…so kimi(0.5)+glm(1)+qwen(1) = 2.5" "$(cap2_field three-hunk-only capability_votes)" "2.5"
[[ "$(cat "$T/cap_err2.txt")" != *"pass --meta-dir"* ]] \
  && ok "no --meta-dir hint when it was given" || bad "hint printed despite --meta-dir"
bash "$S" --findings "$CAP_FINDINGS" --profiles "$CAP_PROFILES" --meta-dir "$T/nope" --out "$T/x.json" 2>/dev/null
assert_eq "a --meta-dir that is not a directory is an error (rc=1)" "$?" "1"
# An unknown observed value must not become a silent full vote (codex, PR #72).
printf '{"exit_code": 0, "context_access": "fille_context"}\n' >"$META/glm.meta.json"
bash "$S" --findings "$CAP_FINDINGS" --profiles "$CAP_PROFILES" --meta-dir "$META" --out "$T/cap_out4.json" 2>"$T/cap_err4.txt"
assert_eq "a misspelled context_access in meta is ignored → glm back to its lane default" \
  "$(jq -r '.findings[] | select(.id=="two-hunk-only") | .context_access.glm' "$T/cap_out4.json")" "diff_only"
assert_eq "…so glm(0.5)+qwen(1.0 from meta) = 1.5" \
  "$(jq -r '.findings[] | select(.id=="two-hunk-only") | .capability_votes' "$T/cap_out4.json")" "1.5"
assert_contains "…and stderr names the bad value" "$(cat "$T/cap_err4.txt")" "unknown context_access 'fille_context'"
printf '{"exit_code": 0, "context_access": "file_context"}\n' >"$META/glm.meta.json"
# A source that is not a slug never becomes a path component (kimi, PR #72).
jq '.findings += [{"id":"evil","severity":"High","file":"z.sh","line":1,"snippet":"q","claim":"c","sources":["../../etc/passwd","codex"]}]' "$CAP_FINDINGS" >"$T/evil.json"
bash "$S" --findings "$T/evil.json" --profiles "$CAP_PROFILES" --meta-dir "$META" --out "$T/evil_out.json" 2>"$T/evil_err.txt"
assert_eq "a path-shaped source does not break the run" "$?" "0"
assert_contains "…and is refused as a slug" "$(cat "$T/evil_err.txt")" "not a reviewer slug"

echo "── weights and floor are data in the profiles, not constants in the script ──"
TUNED="$T/tuned_profiles.json"
jq '. + {"_synthesis_rules": {"context_access_weights": {"diff_only": 1.0}}}' "$CAP_PROFILES" >"$TUNED"
bash "$S" --findings "$CAP_FINDINGS" --profiles "$TUNED" --out "$T/tuned_out.json" 2>/dev/null
assert_eq "diff_only weight raised to 1.0 in profiles → glm+qwen converge again" \
  "$(jq -r '.findings[] | select(.id=="two-hunk-only") | .convergent' "$T/tuned_out.json")" "true"
jq '. + {"_synthesis_rules": {"convergence_min_capability": 2}}' "$CAP_PROFILES" >"$TUNED"
bash "$S" --findings "$CAP_FINDINGS" --profiles "$TUNED" --out "$T/tuned_out2.json" 2>/dev/null
assert_eq "floor raised to 2 → codex+glm (1.5) no longer converges" \
  "$(jq -r '.findings[] | select(.id=="capable-plus-hunk") | .convergent' "$T/tuned_out2.json")" "false"

echo "── determinism holds with the new fields ──"
bash "$S" --findings "$CAP_FINDINGS" --profiles "$CAP_PROFILES" --meta-dir "$META" --out "$T/cap_out3.json" 2>/dev/null
diff -q "$CAP_OUT2" "$T/cap_out3.json" >/dev/null 2>&1 && ok "meta-dir runs are byte-identical" || bad "meta-dir runs differ"

echo
echo "$PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
