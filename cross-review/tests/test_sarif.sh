#!/usr/bin/env bash
# test_sarif.sh — standalone offline fixture test for scripts/emit_sarif.sh.
# NO network, no reviewer CLIs, no tokens.
#
# Mirrors test_score_findings.sh's conventions (assert_eq/assert_contains,
# mktemp -d + trap cleanup) but is intentionally NOT wired into run_tests.sh —
# the parent orchestrating session wires it in later (collision avoidance).
#
# Run:  bash tests/test_sarif.sh
# Exit: 0 all green, 1 any failure.

set -uo pipefail

SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
S="$SKILL_DIR/scripts/emit_sarif.sh"
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

# ── Fixture: findings.verified.json ─────────────────────────────────────────
# One finding of each interesting case:
#   f-anchored   — anchor.resolved=true, factcheck=keep, severity Critical
#   f-unresolved — anchor.resolved=false, factcheck=keep, severity Medium
#   f-dropped    — factcheck.verdict=drop (must be EXCLUDED entirely)
#   f-high       — severity High (-> error)
#   f-low        — severity Low (-> note)
#   f-noanchor   — anchor key missing entirely (treated as unresolved)
FINDINGS="$T/findings.verified.json"
cat >"$FINDINGS" <<'EOF'
{
  "findings": [
    {
      "id": "f-anchored01",
      "local_id": "f1",
      "severity": "Critical",
      "file": "src/a.ts",
      "line": 10,
      "claim": "SQL injection via string concat",
      "snippet": "query(sql)",
      "sources": ["codex", "kimi"],
      "providers": ["openai", "moonshot"],
      "provider_votes": 2,
      "convergent": true,
      "anchor": { "resolved": true, "start_line": 12, "end_line": 14, "side": "new" },
      "factcheck": { "verdict": "keep", "reason": "diff confirms" }
    },
    {
      "id": "f-unresolved1",
      "local_id": "f2",
      "severity": "Medium",
      "file": "src/b.ts",
      "line": 5,
      "claim": "possible off-by-one",
      "snippet": "for (i = 0; i <= len; i++)",
      "sources": ["kimi"],
      "anchor": { "resolved": false, "start_line": 0, "end_line": 0, "side": "none" },
      "factcheck": { "verdict": "keep", "reason": "cannot disprove" }
    },
    {
      "id": "f-dropped001",
      "local_id": "f3",
      "severity": "High",
      "file": "src/c.ts",
      "line": 1,
      "claim": "this was falsified by the diff",
      "snippet": "x",
      "sources": ["glm"],
      "anchor": { "resolved": true, "start_line": 1, "end_line": 1, "side": "new" },
      "factcheck": { "verdict": "drop", "reason": "diff shows this is guarded" }
    },
    {
      "id": "f-high000001",
      "local_id": "f4",
      "severity": "High",
      "file": "src/d.ts",
      "line": 20,
      "claim": "missing null check",
      "snippet": "x.foo()",
      "sources": ["codex"],
      "anchor": { "resolved": true, "start_line": 20, "end_line": 20, "side": "new" },
      "factcheck": { "verdict": "keep", "reason": "diff confirms" }
    },
    {
      "id": "f-low0000001",
      "local_id": "f5",
      "severity": "Low",
      "file": "src/e.ts",
      "line": 2,
      "claim": "nit: naming",
      "snippet": "let x",
      "sources": ["kimi27"],
      "anchor": { "resolved": true, "start_line": 2, "end_line": 2, "side": "new" },
      "factcheck": { "verdict": "keep", "reason": "diff confirms" }
    },
    {
      "id": "f-oldside0001",
      "local_id": "f7",
      "severity": "High",
      "file": "src/g.ts",
      "line": 30,
      "claim": "deleted guard",
      "snippet": "if (!ok) return",
      "sources": ["codex"],
      "anchor": { "resolved": true, "start_line": 30, "end_line": 31, "side": "old" },
      "factcheck": { "verdict": "keep", "reason": "diff confirms" }
    },
    {
      "id": "f-noanchor001",
      "local_id": "f6",
      "severity": "Medium",
      "file": "src/f.ts",
      "line": 3,
      "claim": "no anchor key at all",
      "snippet": "y",
      "sources": ["devstral"],
      "factcheck": { "verdict": "keep", "reason": "cannot disprove" }
    }
  ]
}
EOF

# ── RUN 1 ─────────────────────────────────────────────────────────────────
OUT1="$T/out1.sarif"
"$S" --findings "$FINDINGS" --out "$OUT1" 2>"$T/stderr1.txt"
rc=$?
assert_eq "exit code 0 on valid input" "$rc" "0"

if [[ ! -f "$OUT1" ]]; then
  bad "output file was written"
  echo "stderr: $(cat "$T/stderr1.txt" 2>/dev/null)"
else
  ok "output file was written"

  # ── Structural invariants (hand-rolled; no offline SARIF 2.1.0 validator) ──
  schema="$(jq -r '."$schema" // empty' "$OUT1")"
  assert_contains "\$schema points at the SARIF 2.1.0 schema" "$schema" "sarif-schema-2.1.0"

  version="$(jq -r '.version // empty' "$OUT1")"
  assert_eq "version is 2.1.0" "$version" "2.1.0"

  driver_name="$(jq -r '.runs[0].tool.driver.name // empty' "$OUT1")"
  assert_eq "tool.driver.name is set" "$driver_name" "cross-review"

  n_results="$(jq '.runs[0].results | length' "$OUT1")"
  assert_eq "dropped finding excluded -> 6 results remain" "$n_results" "6"

  # anchor.resolved=true -> region present with right lines
  anchored_region="$(jq -c '.runs[0].results[] | select(.partialFingerprints.crFingerprint == "f-anchored01") | .locations[0].physicalLocation.region' "$OUT1")"
  assert_eq "anchored finding has a region" "$anchored_region" '{"endLine":14,"startLine":12}'

  # anchor.resolved=false -> file-level result, no region key
  unresolved_has_region="$(jq -r '.runs[0].results[] | select(.partialFingerprints.crFingerprint == "f-unresolved1") | (.locations[0].physicalLocation | has("region"))' "$OUT1")"
  assert_eq "unresolved finding has NO region key" "$unresolved_has_region" "false"
  unresolved_uri="$(jq -r '.runs[0].results[] | select(.partialFingerprints.crFingerprint == "f-unresolved1") | .locations[0].physicalLocation.artifactLocation.uri' "$OUT1")"
  assert_eq "unresolved finding still carries the file" "$unresolved_uri" "src/b.ts"

  # missing anchor key entirely -> also treated as unresolved (no region)
  noanchor_has_region="$(jq -r '.runs[0].results[] | select(.partialFingerprints.crFingerprint == "f-noanchor001") | (.locations[0].physicalLocation | has("region"))' "$OUT1")"
  assert_eq "finding with no anchor key at all has NO region key" "$noanchor_has_region" "false"
  # anchor.side=old (a deleted line) -> file-level result, no region (codex, PR #80 review)
  oldside_has_region="$(jq -r '.runs[0].results[] | select(.partialFingerprints.crFingerprint == "f-oldside0001") | .locations[0].physicalLocation | has("region")' "$OUT1")"
  assert_eq "old-side anchored finding has NO region key" "$oldside_has_region" "false"

  # dropped finding is absent entirely
  dropped_present="$(jq '[.runs[0].results[] | select(.partialFingerprints.crFingerprint == "f-dropped001")] | length' "$OUT1")"
  assert_eq "factcheck.verdict=drop finding is absent" "$dropped_present" "0"

  # severity -> level mapping
  lvl_critical="$(jq -r '.runs[0].results[] | select(.partialFingerprints.crFingerprint == "f-anchored01") | .level' "$OUT1")"
  assert_eq "Critical -> error" "$lvl_critical" "error"
  lvl_high="$(jq -r '.runs[0].results[] | select(.partialFingerprints.crFingerprint == "f-high000001") | .level' "$OUT1")"
  assert_eq "High -> error" "$lvl_high" "error"
  lvl_medium="$(jq -r '.runs[0].results[] | select(.partialFingerprints.crFingerprint == "f-unresolved1") | .level' "$OUT1")"
  assert_eq "Medium -> warning" "$lvl_medium" "warning"
  lvl_low="$(jq -r '.runs[0].results[] | select(.partialFingerprints.crFingerprint == "f-low0000001") | .level' "$OUT1")"
  assert_eq "Low -> note" "$lvl_low" "note"

  # stable id appears in partialFingerprints
  fp="$(jq -r '.runs[0].results[] | select(.partialFingerprints.crFingerprint == "f-high000001") | .partialFingerprints.crFingerprint' "$OUT1")"
  assert_eq "stable f-<hash> id lands in partialFingerprints" "$fp" "f-high000001"

  # sources / convergent / provider votes surfaced as properties
  props_sources="$(jq -c '.runs[0].results[] | select(.partialFingerprints.crFingerprint == "f-anchored01") | .properties.sources' "$OUT1")"
  assert_eq "sources surfaced in properties" "$props_sources" '["codex","kimi"]'
  props_convergent="$(jq -r '.runs[0].results[] | select(.partialFingerprints.crFingerprint == "f-anchored01") | .properties.convergent' "$OUT1")"
  assert_eq "convergent surfaced in properties" "$props_convergent" "true"
fi

# ── Determinism: running twice on the same input yields identical bytes ────
OUT2="$T/out2.sarif"
"$S" --findings "$FINDINGS" --out "$OUT2" >/dev/null 2>&1
sum1="$(shasum "$OUT1" 2>/dev/null | awk '{print $1}')"
sum2="$(shasum "$OUT2" 2>/dev/null | awk '{print $1}')"
assert_eq "determinism: identical bytes across two runs" "$sum1" "$sum2"

# ── Error handling: bad JSON input -> clean nonzero exit, no partial write ──
BADJSON="$T/bad.json"
printf '{ not valid json' > "$BADJSON"
OUT_BAD="$T/out_bad.sarif"
"$S" --findings "$BADJSON" --out "$OUT_BAD" >/dev/null 2>"$T/stderr_bad.txt"
rc_bad=$?
assert_eq "invalid JSON input -> nonzero exit" "$([[ $rc_bad -ne 0 ]] && echo nonzero || echo zero)" "nonzero"
assert_eq "invalid JSON input -> no output file written" "$([[ -f "$OUT_BAD" ]] && echo exists || echo absent)" "absent"

# ── Usage / missing args ────────────────────────────────────────────────────
"$S" >/dev/null 2>/dev/null
rc_usage=$?
assert_eq "no args -> usage exit code 2" "$rc_usage" "2"

echo
echo "── $PASS passed, $FAIL failed ──"
[[ "$FAIL" -eq 0 ]]
