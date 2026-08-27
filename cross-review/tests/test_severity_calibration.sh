#!/usr/bin/env bash
# test_severity_calibration.sh — standalone fixture tests for
# severity_calibration.sh (#95). NOT part of run_tests.sh — run directly:
#   bash tests/test_severity_calibration.sh
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
  if [[ "$2" != *"$3"* ]]; then ok "$1"; else bad "$1 (unexpectedly found '$3' in output)"; fi
}

# ── Fixture 1: alpha proposes 3 Critical (f1,f2,f3) + 1 Low (f4);
#    f1 kept, f2+f3 dropped, f4 kept. beta proposes 2 Medium (f5,f6);
#    f5 kept, f6 has no terminal event (unresolved).
FIX1="$T/events1.jsonl"
cat >"$FIX1" <<'EOF'
{"reviewer":"alpha","all_sources":["alpha"],"severity":"Critical","finding_id":"f1","run_id":"run1","event":"proposed","ts":"2026-08-01T00:00:00Z"}
{"reviewer":"alpha","all_sources":["alpha"],"severity":"Critical","finding_id":"f2","run_id":"run1","event":"proposed","ts":"2026-08-01T00:00:00Z"}
{"reviewer":"alpha","all_sources":["alpha"],"severity":"Critical","finding_id":"f3","run_id":"run1","event":"proposed","ts":"2026-08-01T00:00:00Z"}
{"reviewer":"alpha","all_sources":["alpha"],"severity":"Low","finding_id":"f4","run_id":"run1","event":"proposed","ts":"2026-08-01T00:00:00Z"}
{"reviewer":"beta","all_sources":["beta"],"severity":"Medium","finding_id":"f5","run_id":"run1","event":"proposed","ts":"2026-08-01T00:00:00Z"}
{"reviewer":"beta","all_sources":["beta"],"severity":"Medium","finding_id":"f6","run_id":"run1","event":"proposed","ts":"2026-08-01T00:00:00Z"}
{"finding_id":"f1","run_id":"run1","event":"factcheck_kept","ts":"2026-08-01T01:00:00Z"}
{"finding_id":"f2","run_id":"run1","event":"factcheck_dropped","ts":"2026-08-01T01:00:00Z"}
{"finding_id":"f3","run_id":"run1","event":"factcheck_dropped","ts":"2026-08-01T01:00:00Z"}
{"finding_id":"f4","run_id":"run1","event":"factcheck_kept","ts":"2026-08-01T01:00:00Z"}
{"finding_id":"f5","run_id":"run1","event":"factcheck_kept","ts":"2026-08-01T01:00:00Z"}
EOF

echo "── severity_calibration.sh (fixture 1: alpha/beta) ──"
J1="$(bash "$S/severity_calibration.sh" --events "$FIX1" --min-sample 2 --json)"

echo "$J1" | jq -e . >/dev/null 2>&1
if [[ $? -eq 0 ]]; then ok "--json output parses with jq"; else bad "--json output parses with jq"; fi

assert_eq "alpha Critical survival is 0.33" \
  "$(jq -r '.[] | select(.reviewer=="alpha") | .survival.Critical' <<<"$J1")" "0.33"
assert_eq "alpha C+H share among resolved is 0.75" \
  "$(jq -r '.[] | select(.reviewer=="alpha") | .ch_resolved_share' <<<"$J1")" "0.75"
assert_eq "alpha C+H share among kept is 0.5" \
  "$(jq -r '.[] | select(.reviewer=="alpha") | .ch_kept_share' <<<"$J1")" "0.5"
assert_eq "alpha inflation is 0.25" \
  "$(jq -r '.[] | select(.reviewer=="alpha") | .inflation' <<<"$J1")" "0.25"
assert_eq "alpha inflation is NOT a WARN at exactly 0.25 (strict >)" \
  "$(jq -r '.[] | select(.reviewer=="alpha") | .warn' <<<"$J1")" "false"
assert_eq "beta unresolved count is 1" \
  "$(jq -r '.[] | select(.reviewer=="beta") | .unresolved' <<<"$J1")" "1"
assert_eq "beta Medium survival is 1.00" \
  "$(jq -r '.[] | select(.reviewer=="beta") | .survival.Medium' <<<"$J1")" "1.00"

TBL1="$(bash "$S/severity_calibration.sh" --events "$FIX1" --min-sample 2)"
assert_not_contains "table mode has no WARN line for alpha at inflation 0.25" \
  "$TBL1" "WARN inflation: reviewer=alpha"

# ── Fixture 2: alpha proposes 4 Critical, all dropped → inflation 1.00,
#    which with --min-sample 2 (4 >= 2) DOES cross the strict >0.25 bar.
FIX2="$T/events2.jsonl"
cat >"$FIX2" <<'EOF'
{"reviewer":"alpha","all_sources":["alpha"],"severity":"Critical","finding_id":"g1","run_id":"run2","event":"proposed","ts":"2026-08-02T00:00:00Z"}
{"reviewer":"alpha","all_sources":["alpha"],"severity":"Critical","finding_id":"g2","run_id":"run2","event":"proposed","ts":"2026-08-02T00:00:00Z"}
{"reviewer":"alpha","all_sources":["alpha"],"severity":"Critical","finding_id":"g3","run_id":"run2","event":"proposed","ts":"2026-08-02T00:00:00Z"}
{"reviewer":"alpha","all_sources":["alpha"],"severity":"Critical","finding_id":"g4","run_id":"run2","event":"proposed","ts":"2026-08-02T00:00:00Z"}
{"finding_id":"g1","run_id":"run2","event":"factcheck_dropped","ts":"2026-08-02T01:00:00Z"}
{"finding_id":"g2","run_id":"run2","event":"factcheck_dropped","ts":"2026-08-02T01:00:00Z"}
{"finding_id":"g3","run_id":"run2","event":"factcheck_dropped","ts":"2026-08-02T01:00:00Z"}
{"finding_id":"g4","run_id":"run2","event":"factcheck_dropped","ts":"2026-08-02T01:00:00Z"}
EOF

echo "── severity_calibration.sh (fixture 2: alpha all-dropped Critical) ──"
J2="$(bash "$S/severity_calibration.sh" --events "$FIX2" --min-sample 2 --json)"
assert_eq "alpha (fixture 2) inflation is 1.00" \
  "$(jq -r '.[] | select(.reviewer=="alpha") | .inflation' <<<"$J2")" "1.00"
assert_eq "alpha (fixture 2) inflation IS a WARN" \
  "$(jq -r '.[] | select(.reviewer=="alpha") | .warn' <<<"$J2")" "true"

TBL2="$(bash "$S/severity_calibration.sh" --events "$FIX2" --min-sample 2)"
assert_contains "table mode emits a WARN inflation line for alpha (fixture 2)" \
  "$TBL2" "WARN inflation: reviewer=alpha"

# ── Fixture 3: ordering, dedupe, unresolved, validation ──────────────────────
FIX3="$T/events3.jsonl"
cat >"$FIX3" <<'EOF'
{"reviewer":"gamma","severity":"Critical","finding_id":"h1","run_id":"run3","event":"proposed","ts":"2026-08-03T00:00:00Z"}
{"reviewer":"gamma","severity":"Critical","finding_id":"h1","run_id":"run3","event":"proposed","ts":"2026-08-03T00:00:00Z"}
{"reviewer":"gamma","severity":"High","finding_id":"h2","run_id":"run3","event":"proposed","ts":"2026-08-03T00:00:00Z"}
{"reviewer":"gamma","severity":"Low","finding_id":"h3","run_id":"run3","event":"proposed","ts":"2026-08-03T00:00:00Z"}
{"reviewer":"delta","severity":"Critical","finding_id":"h4","run_id":"run3","event":"proposed","ts":"2026-08-03T00:00:00Z"}
{"reviewer":"delta","severity":"Critical","finding_id":"h5","run_id":"run3","event":"proposed","ts":"2026-08-03T00:00:00Z"}
{"reviewer":"delta","severity":"Critical","finding_id":"h6","run_id":"run3","event":"proposed","ts":"2026-08-03T00:00:00Z"}
{"reviewer":"delta","severity":"Low","finding_id":"h7","run_id":"run3","event":"proposed","ts":"2026-08-03T00:00:00Z"}
{"finding_id":"h1","run_id":"run3","event":"factcheck_dropped","ts":"2026-08-03T01:00:00Z"}
{"finding_id":"h1","run_id":"run3","event":"human_accepted","ts":"2026-08-03T02:00:00Z"}
{"finding_id":"h2","run_id":"run3","event":"factcheck_kept","ts":"2026-08-03T01:00:00Z"}
{"finding_id":"h2","run_id":"run3","event":"human_rejected","ts":"2026-08-03T02:00:00Z"}
{"finding_id":"h3","run_id":"run3","event":"factcheck_kept","ts":"2026-08-03T01:00:00Z"}
{"finding_id":"h7","run_id":"run3","event":"factcheck_kept","ts":"2026-08-03T01:00:00Z"}
EOF

echo "── severity_calibration.sh (fixture 3: ordering / dedupe / unresolved) ──"
J3="$(bash "$S/severity_calibration.sh" --events "$FIX3" --min-sample 2 --json)"
assert_eq "duplicate proposed events count once (gamma proposed=3)" \
  "$(jq -r '.[] | select(.reviewer=="gamma") | .proposed' <<<"$J3")" "3"
assert_eq "later human_accepted overrides earlier factcheck_dropped (h1 kept)" \
  "$(jq -r '.[] | select(.reviewer=="gamma") | .survival.Critical' <<<"$J3")" "1.00"
assert_eq "later human_rejected overrides earlier factcheck_kept (h2 dropped)" \
  "$(jq -r '.[] | select(.reviewer=="gamma") | .survival.High' <<<"$J3")" "0.00"
assert_eq "unresolved Critical findings are not inflation (delta inflation 0.00)" \
  "$(jq -r '.[] | select(.reviewer=="delta") | .inflation' <<<"$J3")" "0.00"
assert_eq "delta is not a WARN on unresolved rows" \
  "$(jq -r '.[] | select(.reviewer=="delta") | .warn' <<<"$J3")" "false"
assert_eq "delta unresolved is 3" \
  "$(jq -r '.[] | select(.reviewer=="delta") | .unresolved' <<<"$J3")" "3"

echo "── argument validation ──"
bash "$S/severity_calibration.sh" --events "$FIX1" --min-sample foo >/dev/null 2>"$T/err"; rc=$?
assert_eq "--min-sample foo exits 2" "$rc" "2"
assert_contains "--min-sample foo names the flag" "$(cat "$T/err")" "--min-sample"
bash "$S/severity_calibration.sh" --events "$FIX1" --recent-days 0 >/dev/null 2>&1; rc=$?
assert_eq "--recent-days 0 exits 2" "$rc" "2"
bash "$S/severity_calibration.sh" --events "$FIX1" --recent-days abc >/dev/null 2>&1; rc=$?
assert_eq "--recent-days abc exits 2" "$rc" "2"
printf '{not json\n' >"$T/bad.jsonl"
bash "$S/severity_calibration.sh" --events "$T/bad.jsonl" --json >/dev/null 2>&1; rc=$?
assert_eq "unparseable ledger exits 1 instead of an empty report" "$rc" "1"

echo
echo "── summary ──"
echo "PASS: $PASS  FAIL: $FAIL"
[[ $FAIL -eq 0 ]] || exit 1
exit 0
