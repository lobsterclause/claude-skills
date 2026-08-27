#!/usr/bin/env bash
# test_validate_ledgers.sh — standalone TDD fixture for validate_ledgers.sh
# and the schema_version stamping in append_runlog.sh / append_finding_event.sh
# (#96).
#
# NO network, NO reviewer CLIs. Run:
#   bash tests/test_validate_ledgers.sh
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
# assert <description> <actual> <expected>
assert_eq() {
  if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 (got: '$2' want: '$3')"; fi
}
assert_contains() {
  if [[ "$2" == *"$3"* ]]; then ok "$1"; else bad "$1 (no '$3' in output)"; fi
}

echo "── validate_ledgers.sh (malformed lines, missing ts, orphan run_id, unknown event) ──"

# Fixture runlog: 3 good entries (r1,r2,r3 with ts), line 3 is malformed JSON,
# line 5 lacks ts.
RUNLOG="$T/runlog.jsonl"
cat >"$RUNLOG" <<'EOF'
{"ts":"2026-08-01T00:00:00Z","run_id":"r1","reviewers":{"codex":{"status":"ok"}}}
{"ts":"2026-08-01T01:00:00Z","run_id":"r2","reviewers":{"codex":{"status":"ok"}}}
{not json
{"ts":"2026-08-01T02:00:00Z","run_id":"r3","reviewers":{"codex":{"status":"ok"}}}
{"run_id":"r4","reviewers":{"codex":{"status":"ok"}}}
EOF

# Fixture events: 2 events for r1, 1 event for orphan r9, 1 event with an
# unknown event type.
EVENTS="$T/finding_events.jsonl"
cat >"$EVENTS" <<'EOF'
{"event":"proposed","ts":"2026-08-01T00:00:01Z","finding_id":"f-1","run_id":"r1"}
{"event":"anchored","ts":"2026-08-01T00:00:02Z","finding_id":"f-1","run_id":"r1"}
{"event":"proposed","ts":"2026-08-01T00:00:03Z","finding_id":"f-9","run_id":"r9"}
{"event":"bogus","ts":"2026-08-01T00:00:04Z","finding_id":"f-2","run_id":"r2"}
EOF

OUT="$(bash "$S/validate_ledgers.sh" --runlog "$RUNLOG" --events "$EVENTS" 2>&1)"
rc=$?
assert_eq "exit code 1 on malformed/missing-ts errors" "$rc" "1"
assert_contains "reports malformed runlog line" "$OUT" "runlog:3 malformed"
assert_contains "reports missing ts" "$OUT" "missing ts"
assert_contains "reports orphan run_id" "$OUT" "r9"
assert_contains "reports unknown event" "$OUT" "bogus"

JOUT="$(bash "$S/validate_ledgers.sh" --runlog "$RUNLOG" --events "$EVENTS" --json 2>/dev/null)"
assert_eq "--json output parses" "$(jq -e . <<<"$JOUT" >/dev/null 2>&1; echo $?)" "0"
assert_eq "--json runlog.malformed == 1" "$(jq -r '.runlog.malformed' <<<"$JOUT")" "1"

echo "── validate_ledgers.sh (clean ledgers from append_runlog.sh / append_finding_event.sh) ──"

FRESH_RUNLOG="$T/fresh-runlog.jsonl"
FRESH_EVENTS="$T/fresh-events.jsonl"
: >"$FRESH_RUNLOG"
: >"$FRESH_EVENTS"

RUN="$T/run1"; mkdir -p "$RUN/raw"
printf '{"exit_code": 0, "duration_s": 10, "timed_out": false, "output_bytes": 50, "attempt": 1, "timeout_budget_s": 300}\n' >"$RUN/raw/codex.meta.json"

CROSS_REVIEW_RUNLOG="$FRESH_RUNLOG" bash "$S/append_runlog.sh" \
  --run-dir "$RUN" --project test --base main --pr - --pass 1 \
  --verdict CLEAN --convergent 0 --top "-" --run-id run-fresh-1 >/dev/null 2>&1

CROSS_REVIEW_FINDING_EVENTS="$FRESH_EVENTS" bash "$S/append_finding_event.sh" \
  --event proposed --finding-id f-fresh-1 --run-id run-fresh-1 --fields '{"reviewer":"codex"}' >/dev/null 2>&1

assert_eq "append_runlog.sh stamps schema_version == 1" \
  "$(jq -r '.schema_version' "$FRESH_RUNLOG")" "1"
assert_eq "append_finding_event.sh stamps schema_version == 1" \
  "$(jq -r '.schema_version' "$FRESH_EVENTS")" "1"

FRESH_OUT="$(bash "$S/validate_ledgers.sh" --runlog "$FRESH_RUNLOG" --events "$FRESH_EVENTS" 2>&1)"
frc=$?
assert_eq "fresh ledgers validate clean (exit 0)" "$frc" "0"
assert_contains "fresh ledgers show schema_version distribution 1=..." "$FRESH_OUT" "1="

echo
echo "PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]] || exit 1
exit 0
