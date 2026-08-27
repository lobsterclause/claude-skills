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
{"schema_version":1,"run_id":"r4","reviewers":{"codex":{"status":"ok"}}}
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
assert_contains "reports missing ts" "$OUT" "runlog:5 missing ts"
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

echo "── strict line shape, paths, allowlist, json escaping (PR #109 review) ──"
SHAPE_RUNLOG="$T/shape-runlog.jsonl"
SHAPE_EVENTS="$T/shape-events.jsonl"
cat >"$SHAPE_RUNLOG" <<'EOF'
{"ts":"2026-08-01T00:00:00Z","run_id":"s1","schema_version":"a\"b c"}
42
{"ts":"2026-08-01T00:00:00Z","run_id":"s2"} {"ts":"2026-08-01T00:00:00Z","run_id":"s3"}
["ts"]
EOF
cat >"$SHAPE_EVENTS" <<'EOF'
{"finding_id":"f1","run_id":"s1","event":"unresolved","ts":"2026-08-01T00:00:00Z"}
{"finding_id":"f2","run_id":"s1","event":"it's odd","ts":"2026-08-01T00:00:00Z"}
EOF
SOUT="$(bash "$S/validate_ledgers.sh" --runlog "$SHAPE_RUNLOG" --events "$SHAPE_EVENTS" 2>&1)"; src=$?
assert_eq "scalar / multi-doc / array lines are errors (exit 1)" "$src" "1"
assert_contains "a bare scalar line is malformed" "$SOUT" "runlog:2 malformed"
assert_contains "two documents on one line are malformed" "$SOUT" "runlog:3 malformed"
assert_contains "an array line is malformed" "$SOUT" "runlog:4 malformed"
assert_contains "exactly 3 malformed" "$SOUT" "3 malformed"
if printf '%s' "$SOUT" | grep -q "unknown event 'unresolved'"; then
  bad "unresolved is an allowlisted event"
else
  ok "unresolved is an allowlisted event"
fi
SJ="$(bash "$S/validate_ledgers.sh" --runlog "$SHAPE_RUNLOG" --events "$SHAPE_EVENTS" --json 2>/dev/null)"
if printf '%s' "$SJ" | jq -e . >/dev/null 2>&1; then
  ok "--json stays valid with a quoted/spaced schema_version"
else
  bad "--json stays valid with a quoted/spaced schema_version (got: $SJ)"
fi
assert_eq "--json schema_version bucket keeps the odd value verbatim" \
  "$(printf '%s' "$SJ" | jq -r '.runlog.schema_version | to_entries[0].key')" 'a"b c'
assert_eq "--json unknown_event_examples keeps a quoted name whole" \
  "$(printf '%s' "$SJ" | jq -r '.events.unknown_event_examples[0]')" "it's odd"
bash "$S/validate_ledgers.sh" --runlog "$T/does-not-exist.jsonl" --events "$SHAPE_EVENTS" >/dev/null 2>&1; prc=$?
assert_eq "an explicit --runlog path that does not exist exits 2" "$prc" "2"
bash "$S/validate_ledgers.sh" --runlog "$T" --events "$SHAPE_EVENTS" >/dev/null 2>&1; prc=$?
assert_eq "an explicit --runlog path that is a directory exits 2" "$prc" "2"
bash "$S/validate_ledgers.sh" --runlog "" --events "$SHAPE_EVENTS" >/dev/null 2>&1; prc=$?
assert_eq "an explicit empty --runlog path exits 2" "$prc" "2"
assert_contains "text mode keeps a spaced schema_version value whole" "$SOUT" 'a"b c=1'
TABLOG="$T/tab-runlog.jsonl"
printf '{"ts":"2026-08-01T00:00:00Z","schema_version":"x\\ty"}\n' >"$TABLOG"
TJ="$(bash "$S/validate_ledgers.sh" --runlog "$TABLOG" --events "$SHAPE_EVENTS" --json 2>/dev/null)"
assert_eq "a schema_version with a tab still yields valid --json" "$(printf '%s' "$TJ" | jq -r '.runlog.schema_version | to_entries[0].value')" "1"

echo "── future schema_version WARN (#122) ──"
FUTLOG="$T/future-runlog.jsonl"
cat >"$FUTLOG" <<'EOF'
{"schema_version": 7, "ts": "2026-08-01T00:00:00Z", "run_id": "fut1"}
EOF
FUTOUT="$(bash "$S/validate_ledgers.sh" --runlog "$FUTLOG" --events "$EVENTS" 2>&1)"; futrc=$?
assert_eq "future schema_version does not fail the run (exit 0)" "$futrc" "0"
assert_contains "future schema_version WARN names it" "$FUTOUT" "above the writer's current"
FUTJ="$(bash "$S/validate_ledgers.sh" --runlog "$FUTLOG" --events "$EVENTS" --json 2>/dev/null)"
assert_eq "--json runlog.future_version == 1" "$(printf '%s' "$FUTJ" | jq -r '.runlog.future_version')" "1"

# events ledger: the same future-version rule; and the writer-fallback WARN
# must survive (it is counted in this shell, not a subshell)
FUTEV="$T/future-events.jsonl"
printf '{"schema_version":7,"finding_id":"f1","run_id":"s1","event":"proposed","ts":"2026-08-01T00:00:00Z"}\n' >"$FUTEV"
FUTEJ="$(bash "$S/validate_ledgers.sh" --runlog "$FUTLOG" --events "$FUTEV" --json 2>/dev/null)"
assert_eq "--json events.future_version == 1" "$(printf '%s' "$FUTEJ" | jq -r '.events.future_version')" "1"
assert_contains "events future schema_version WARN names the line" "$(bash "$S/validate_ledgers.sh" --runlog "$FUTLOG" --events "$FUTEV" 2>&1)" "events:1 schema_version 7 is above the writer's current"
mkdir -p "$T/no-writers"
FBOUT="$(CROSS_REVIEW_WRITERS_DIR="$T/no-writers" bash "$S/validate_ledgers.sh" --runlog "$FUTLOG" --events "$FUTEV" 2>&1)"
assert_contains "unreadable writers fall back to 1 with a WARN that is actually printed" "$FBOUT" "unable to read a writer's current schema_version"
assert_eq "fallback still flags version 7 as future" "$(CROSS_REVIEW_WRITERS_DIR="$T/no-writers" bash "$S/validate_ledgers.sh" --runlog "$FUTLOG" --events "$FUTEV" --json 2>/dev/null | jq -r '.runlog.current_schema_version')" "1"

mkdir -p "$T/crlf-writers"
printf 'SCHEMA_VERSION=3\r\n' >"$T/crlf-writers/append_runlog.sh"; printf 'SCHEMA_VERSION=2 \n' >"$T/crlf-writers/append_finding_event.sh"
CRLFJ="$(CROSS_REVIEW_WRITERS_DIR="$T/crlf-writers" bash "$S/validate_ledgers.sh" --runlog "$FUTLOG" --events "$FUTEV" --json 2>/dev/null)"
assert_eq "a CRLF writer constant still parses (runlog current 3)" "$(printf '%s' "$CRLFJ" | jq -r '.runlog.current_schema_version')" "3"
assert_eq "a trailing-space writer constant still parses (events current 2)" "$(printf '%s' "$CRLFJ" | jq -r '.events.current_schema_version')" "2"
mkdir -p "$T/octal-writers"
printf 'SCHEMA_VERSION=08\n' >"$T/octal-writers/append_runlog.sh"; printf 'SCHEMA_VERSION=1\t\n' >"$T/octal-writers/append_finding_event.sh"
OCTJ="$(CROSS_REVIEW_WRITERS_DIR="$T/octal-writers" bash "$S/validate_ledgers.sh" --runlog "$FUTLOG" --events "$FUTEV" --json 2>/dev/null)"
assert_eq "a leading-zero constant falls back to 1 instead of an octal crash" "$(printf '%s' "$OCTJ" | jq -r '.runlog.current_schema_version')" "1"
assert_eq "a tab-trailed constant still parses" "$(printf '%s' "$OCTJ" | jq -r '.events.current_schema_version')" "1"

echo "── legacy no-ts rows (#111) ──"
LEGLOG="$T/legacy-runlog.jsonl"
cat >"$LEGLOG" <<'EOF'
{"run_id":"legacy1"}
EOF
LEGOUT="$(bash "$S/validate_ledgers.sh" --runlog "$LEGLOG" --events "$EVENTS" 2>&1)"; legrc=$?
assert_eq "a legacy no-ts/no-schema_version row is a WARN, not an ERROR (exit 0)" "$legrc" "0"
assert_contains "legacy no-ts row is reported as WARN legacy" "$LEGOUT" "WARN  legacy: runlog:1 has no ts (pre-schema entry)"
LEGJ="$(bash "$S/validate_ledgers.sh" --runlog "$LEGLOG" --events "$EVENTS" --json 2>/dev/null)"
assert_eq "--json runlog.legacy_no_ts == 1" "$(printf '%s' "$LEGJ" | jq -r '.runlog.legacy_no_ts')" "1"

VERLOG="$T/versioned-noTS-runlog.jsonl"
cat >"$VERLOG" <<'EOF'
{"schema_version":1,"run_id":"x"}
EOF
VEROUT="$(bash "$S/validate_ledgers.sh" --runlog "$VERLOG" --events "$EVENTS" 2>&1)"; verrc=$?
assert_eq "a versioned row with no ts is still an ERROR (exit 1)" "$verrc" "1"
assert_contains "versioned no-ts row reports missing ts" "$VEROUT" "missing ts"

echo "── single-pass line extraction: parity + performance on a large fixture (#132) ──"
# A fixture large enough to make the per-line-fork cost visible: mostly
# valid rows, plus 3 malformed, 2 legacy no-ts, and 1 future schema_version
# runlog row, scattered through it (near the start, the middle, and near
# the end) so line numbering at every offset gets exercised. 1,000 lines
# keeps the *pre-#132* comparison script's run (invoked twice below, once
# per output mode) well inside this test's time budget -- it forks
# several jq/awk/grep processes per line and takes roughly a minute per
# invocation at this size; the single-pass script finishes in a fraction
# of a second regardless.
PERF_N=1000
PERF_RUNLOG="$T/perf-runlog.jsonl"
PERF_EVENTS="$T/perf-events.jsonl"
: >"$PERF_RUNLOG"
: >"$PERF_EVENTS"
PERF_HALF=$((PERF_N / 2))
PERF_NEAR_END1=$((PERF_N - 10))
PERF_NEAR_END2=$((PERF_N - 20))
for ((pi = 1; pi <= PERF_N; pi++)); do
  if [[ "$pi" -eq 10 || "$pi" -eq "$PERF_HALF" || "$pi" -eq "$PERF_NEAR_END1" ]]; then
    echo "{not valid json $pi" >>"$PERF_RUNLOG"
  elif [[ "$pi" -eq 20 || "$pi" -eq "$PERF_NEAR_END2" ]]; then
    printf '{"run_id":"legacy-%d"}\n' "$pi" >>"$PERF_RUNLOG"
  elif [[ "$pi" -eq 30 ]]; then
    printf '{"ts":"2026-08-01T00:00:00Z","run_id":"future-%d","schema_version":99}\n' "$pi" >>"$PERF_RUNLOG"
  else
    printf '{"ts":"2026-08-01T00:00:%02dZ","run_id":"run-%d","schema_version":1,"reviewers":{"codex":{"status":"ok"}}}\n' "$((pi % 60))" "$pi" >>"$PERF_RUNLOG"
  fi
  printf '{"event":"proposed","ts":"2026-08-01T00:00:%02dZ","finding_id":"f-%d","run_id":"run-%d","schema_version":1}\n' "$((pi % 60))" "$pi" "$pi" >>"$PERF_EVENTS"
done

# The pre-#132 script, materialized from the last commit -- HEAD, not this
# working tree -- so this compares the new extraction against whatever
# shipped last, not against itself.
ORIG_SCRIPT="$T/orig_validate_ledgers.sh"
git -C "$SKILL_DIR" show HEAD:cross-review/scripts/validate_ledgers.sh >"$ORIG_SCRIPT" 2>/dev/null

if [[ -s "$ORIG_SCRIPT" ]]; then
  # $ORIG_SCRIPT lives under $T, with no sibling scripts/ dir next to it, so
  # left to its own device-relative default it can't find append_runlog.sh
  # / append_finding_event.sh and falls back with an extra WARN that the
  # real, in-place $S/validate_ledgers.sh never hits. Point both at the
  # same real writers dir so the comparison is apples-to-apples.
  ORIG_TEXT="$(CROSS_REVIEW_WRITERS_DIR="$S" bash "$ORIG_SCRIPT" --runlog "$PERF_RUNLOG" --events "$PERF_EVENTS" 2>&1)"
  NEW_TEXT="$(CROSS_REVIEW_WRITERS_DIR="$S" bash "$S/validate_ledgers.sh" --runlog "$PERF_RUNLOG" --events "$PERF_EVENTS" 2>&1)"
  assert_eq "single-pass text output matches the pre-#132 script byte-for-byte on a $PERF_N-line fixture" "$NEW_TEXT" "$ORIG_TEXT"

  ORIG_JSON="$(CROSS_REVIEW_WRITERS_DIR="$S" bash "$ORIG_SCRIPT" --runlog "$PERF_RUNLOG" --events "$PERF_EVENTS" --json 2>/dev/null)"
  NEW_JSON="$(CROSS_REVIEW_WRITERS_DIR="$S" bash "$S/validate_ledgers.sh" --runlog "$PERF_RUNLOG" --events "$PERF_EVENTS" --json 2>/dev/null)"
  assert_eq "single-pass --json output matches the pre-#132 script byte-for-byte on a $PERF_N-line fixture" "$NEW_JSON" "$ORIG_JSON"
else
  bad "could not materialize the pre-#132 script from git HEAD to compare against"
fi

PERF_START=$(date +%s)
bash "$S/validate_ledgers.sh" --runlog "$PERF_RUNLOG" --events "$PERF_EVENTS" >/dev/null 2>&1
PERF_END=$(date +%s)
PERF_ELAPSED=$((PERF_END - PERF_START))
if [[ "$PERF_ELAPSED" -lt 10 ]]; then
  ok "single-pass run finishes in under 10s on a $PERF_N-line fixture (${PERF_ELAPSED}s)"
else
  bad "single-pass run finishes in under 10s on a $PERF_N-line fixture (took ${PERF_ELAPSED}s)"
fi

echo
echo "PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]] || exit 1
exit 0
