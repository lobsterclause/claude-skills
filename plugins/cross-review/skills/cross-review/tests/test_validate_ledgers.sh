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

echo "── orphan run_id detection with an EMPTY runlog (every event is an orphan) ──"
# Regression guard for the single-pass orphan check: an awk NR==FNR set-load
# over an empty run_ids file treats the candidates file as the first file,
# so every orphan was swallowed. The pre-#132 grep -qxF path reported them.
EMPTY_RL="$T/empty-runlog.jsonl"; : >"$EMPTY_RL"
ORPH_EV="$T/orphan-events.jsonl"
printf '{"event":"proposed","ts":"2026-08-01T00:00:00Z","finding_id":"f-1","run_id":"run-only-in-events","schema_version":1}\n' >"$ORPH_EV"
printf '{"event":"proposed","ts":"2026-08-01T00:00:01Z","finding_id":"f-2","run_id":"run-only-in-events-2","schema_version":1}\n' >>"$ORPH_EV"
ORPH_OUT="$(CROSS_REVIEW_WRITERS_DIR="$S" bash "$S/validate_ledgers.sh" --runlog "$EMPTY_RL" --events "$ORPH_EV" 2>&1)"
assert_contains "empty runlog: both events are reported as orphan run_ids" "$ORPH_OUT" "2 event(s) with a run_id absent from runlog"
assert_contains "empty runlog: the orphan run_id is named" "$ORPH_OUT" "orphan run_id 'run-only-in-events'"
ORPH_JSON="$(CROSS_REVIEW_WRITERS_DIR="$S" bash "$S/validate_ledgers.sh" --runlog "$EMPTY_RL" --events "$ORPH_EV" --json 2>/dev/null)"
assert_eq "empty runlog: --json orphan_run_id count is 2" "$(jq -r '.events.orphan_run_id' <<<"$ORPH_JSON")" "2"

echo "── single-pass line extraction: parity + performance on a large fixture (#132) ──"
# A fixture large enough to make the per-line-fork cost visible: mostly
# valid rows, plus 3 malformed, 2 legacy no-ts, and 1 future schema_version
# runlog row, scattered through it (near the start, the middle, and near
# the end) so line numbering at every offset gets exercised. 1,000 lines
# is the size the pinned baseline below was generated at (the pre-#132
# script forked several jq/awk/grep processes per line and took about a
# minute at this size; the single-pass script finishes in well under a
# second).
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

# Expected output PINNED from the pre-#132 script (origin/master before
# #139, generated 2026-08-27 on this exact fixture) -- not re-derived from
# `git show HEAD:` at test time, which becomes a tautology the moment the
# refactor merges and fails outright without history (cross-review of #137).
# It also spares the ~60s-per-invocation run of the old per-line-fork script.
# Paths never appear in the output, so no normalization is needed.
PIN_TEXT=$(cat <<'PINNED'
ERROR runlog:10 malformed
ERROR runlog:500 malformed
ERROR runlog:990 malformed
WARN  legacy: runlog:20 has no ts (pre-schema entry)
WARN  runlog:30 schema_version 99 is above the writer's current 1
WARN  legacy: runlog:980 has no ts (pre-schema entry)
WARN  events: 6 event(s) with a run_id absent from runlog (orphan run_id):
  orphan run_id 'run-10'
  orphan run_id 'run-20'
  orphan run_id 'run-30'
  orphan run_id 'run-500'
  orphan run_id 'run-980'
runlog: 1000 lines, 3 malformed, 0 missing ts, 2 legacy no-ts, 1 above-current schema_version, schema_version: 1=994, 99=1, missing=2
events: 1000 lines, 0 malformed, 0 unknown event(s), 6 orphan run_id(s), 0 above-current schema_version, schema_version: 1=1000
PINNED
)
PIN_JSON='{"runlog":{"lines":1000,"malformed":3,"missing_ts":0,"legacy_no_ts":2,"future_version":1,"future_version_examples":[99],"current_schema_version":1,"schema_version":{"1":994,"99":1,"missing":2}},"events":{"lines":1000,"malformed":0,"unknown_event":0,"unknown_event_examples":[],"orphan_run_id":6,"orphan_run_id_examples":["run-10","run-20","run-30","run-500","run-980"],"future_version":0,"future_version_examples":[],"current_schema_version":1,"schema_version":{"1":1000}},"errors":3,"warns":9}'
NEW_TEXT="$(CROSS_REVIEW_WRITERS_DIR="$S" bash "$S/validate_ledgers.sh" --runlog "$PERF_RUNLOG" --events "$PERF_EVENTS" 2>&1)"
assert_eq "single-pass text output matches the pre-#132 script byte-for-byte on a $PERF_N-line fixture" "$NEW_TEXT" "$PIN_TEXT"
NEW_JSON="$(CROSS_REVIEW_WRITERS_DIR="$S" bash "$S/validate_ledgers.sh" --runlog "$PERF_RUNLOG" --events "$PERF_EVENTS" --json 2>/dev/null)"
assert_eq "single-pass --json output matches the pre-#132 script byte-for-byte on a $PERF_N-line fixture" "$NEW_JSON" "$PIN_JSON"

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
