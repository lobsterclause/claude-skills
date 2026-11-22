#!/usr/bin/env bash
# test_prior_severity.sh — scripts/prior_severity.sh reads the worst severity a
# previous cross-review pass found. The codex effort ladder escalates on
# critical/high, so a wrong "high" spends money and a wrong "none" skips a
# deeper look. "unknown" (no evidence) must never be confused with "none".
# Run: bash tests/test_prior_severity.sh   ·   Exit: 0 all green, 1 any failure.
set -uo pipefail
S="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/scripts/prior_severity.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
PASS=0; FAIL=0
assert_eq() { if [[ "$2" == "$3" ]]; then echo "  ok   $1"; PASS=$((PASS+1)); else echo "  FAIL $1 (got: '$2' want: '$3')"; FAIL=$((FAIL+1)); fi; }
command -v jq >/dev/null 2>&1 || { echo "  skip prior_severity (jq unavailable)"; exit 0; }
case_dir() { rm -rf "$T/c"; mkdir -p "$T/c/raw"; }

case_dir; assert_eq "missing dir -> unknown" "$(bash "$S" "$T/nope")" "unknown"
assert_eq "no arg -> unknown" "$(bash "$S")" "unknown"
case_dir; assert_eq "empty run dir -> unknown" "$(bash "$S" "$T/c/raw")" "unknown"

case_dir; printf '{"findings":[]}\n' >"$T/c/findings.json"
assert_eq "empty findings.json in the parent -> none" "$(bash "$S" "$T/c/raw")" "none"
case_dir; printf '{"findings":[{"severity":"Low"},{"severity":"HIGH"}]}\n' >"$T/c/findings.json"
assert_eq "case-insensitive max -> high" "$(bash "$S" "$T/c/raw")" "high"
case_dir; printf '{"findings":[{"severity":"Critical"}]}\n' >"$T/c/raw/findings.json"
assert_eq "file in the out dir itself" "$(bash "$S" "$T/c/raw")" "critical"

case_dir
printf '{"findings":[{"severity":"High","disposition":"drop"},{"severity":"Critical","factcheck":{"verdict":"drop"}},{"severity":"Medium"}]}\n' >"$T/c/findings.scored.json"
printf '{"findings":[{"severity":"Critical"}]}\n' >"$T/c/findings.json"
assert_eq "scored wins; dropped findings ignored" "$(bash "$S" "$T/c/raw")" "medium"

case_dir; printf 'not json\n' >"$T/c/findings.json"
printf '# x\n\n## Critical\n\n## High\n- **[a.ts:1]** thing (sources: codex)\n\n## Medium\n- y\n' >"$T/c/findings.md"
assert_eq "unparseable json falls through to findings.md" "$(bash "$S" "$T/c/raw")" "high"
case_dir; printf '# x\n\n## Critical\n- none\n\n## High\n_None._\n\n## Low\n- tiny\n' >"$T/c/findings.md"
assert_eq "md: 'none' bullets and empty sections do not count" "$(bash "$S" "$T/c/raw")" "low"
case_dir; printf '# x\n\nNo findings.\n' >"$T/c/findings.md"
assert_eq "md with no sections -> none" "$(bash "$S" "$T/c/raw")" "none"

case_dir; printf '{"findings":[{"severity":"High"}]}\n' >"$T/c/findings.premerged.json"
assert_eq "premerged High counts (positive evidence)" "$(bash "$S" "$T/c/raw")" "high"
case_dir; printf '{"findings":[{"severity":"Low"}]}\n' >"$T/c/findings.premerged.json"
assert_eq "premerged without High -> unknown (codex not in it)" "$(bash "$S" "$T/c/raw")" "unknown"

echo; echo "══ $PASS passed, $FAIL failed ══"
[[ "$FAIL" -eq 0 ]]
