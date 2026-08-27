#!/usr/bin/env bash
# validate_ledgers.sh — read-only validator for runlog.jsonl and
# finding_events.jsonl (#96). Reports malformed lines, unknown event types,
# events whose run_id has no runlog entry, entries missing ts, and the
# schema_version distribution per file. Never modifies either ledger.
#
# Usage:
#   validate_ledgers.sh [--runlog PATH] [--events PATH] [--json]
#
#   --runlog PATH   Defaults to $CROSS_REVIEW_RUNLOG, else this skill's
#                    runlog.jsonl (~/.claude/skills/cross-review/runlog.jsonl
#                    when installed there).
#   --events PATH   Defaults to $CROSS_REVIEW_FINDING_EVENTS, else this
#                    skill's finding_events.jsonl.
#   --json          Emit a JSON summary instead of human-readable lines.
#
# Checks:
#   (a) malformed lines            -> ERROR  "runlog:<n> malformed" /
#                                              "events:<n> malformed"
#   (b) runlog entries missing ts  -> ERROR  "runlog:<n> missing ts"
#   (c) events with an unknown     -> WARN   "events:<n> unknown event
#       `event` name (not in the             '<name>'"
#       allowlist below)
#   (d) events whose run_id has no -> WARN   summary + up to 5 examples,
#       matching runlog entry               "orphan run_id '<id>' (events:<n>)"
#   (e) schema_version distribution -> info line per file; entries/events
#       with no schema_version key land in the "missing" bucket (readers
#       treat absence as 0 -- the bucket is named "missing", not "0", so
#       pre-#96 rows stay distinguishable from an explicit 0)
#
# A line is malformed unless it is exactly ONE JSON object: a bare scalar,
# an array, or two documents on one physical line all count as malformed
# (codex, PR #109 review). Paths: an explicitly supplied --runlog/--events
# that does not exist is an error (exit 2); an absent DEFAULT ledger is
# treated as empty, since a fresh install has none yet.
#
# Exit: 0 if no ERROR-level findings, 1 if any malformed line or missing-ts
# entry exists. WARN-level findings (unknown event, orphan run_id) do not
# affect the exit code.
#
# Portability: macOS bash 3.2 + ubuntu bash 5; needs jq. set -uo pipefail
# (no -e: we want to keep scanning after a bad line, not abort).

set -uo pipefail

# Allowlisted event names (#96 spec). Anything else is a WARN, not an ERROR —
# new event types are expected to show up before this list is updated.
ALLOWED_EVENTS="proposed anchored factcheck_kept factcheck_dropped parent_verified_kept parent_verified_dropped fix_applied fix_verified fix_failed deferred unresolved human_accepted human_rejected regression_detected duplicate_merged planted caught missed"

# Parse one physical line as exactly one JSON object; prints it compacted,
# or nothing (malformed).
parse_line() {
  printf '%s' "$1" | jq -cs 'if length == 1 and (.[0] | type) == "object" then .[0] else empty end' 2>/dev/null
}

runlog=""
events=""
json_out=0

need_val() {
  if [[ "$2" -lt 2 ]]; then
    echo "missing value for $1" >&2
    exit 2
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --runlog) need_val "$1" "$#"; runlog="$2"; [[ -n "$runlog" ]] || { echo "validate_ledgers: --runlog needs a non-empty path" >&2; exit 2; }; shift 2 ;;
    --events) need_val "$1" "$#"; events="$2"; [[ -n "$events" ]] || { echo "validate_ledgers: --events needs a non-empty path" >&2; exit 2; }; shift 2 ;;
    --json)   json_out=1; shift ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

command -v jq >/dev/null 2>&1 || { echo "validate_ledgers: jq required" >&2; exit 1; }

skill_dir="$(cd "$(dirname "$0")/.." && pwd)"
# An explicitly supplied path that does not exist is a usage error, not a
# clean empty ledger -- a typo in --runlog must not validate as healthy
# (codex, PR #109 review). Absent defaults stay equivalent to empty.
for pair in "--runlog:$runlog" "--events:$events"; do
  flag="${pair%%:*}"; path="${pair#*:}"
  if [[ -n "$path" && ( ! -f "$path" || ! -r "$path" ) ]]; then
    echo "validate_ledgers: $flag '$path' is not a readable regular file" >&2
    exit 2
  fi
done
runlog="${runlog:-${CROSS_REVIEW_RUNLOG:-$skill_dir/runlog.jsonl}}"
events="${events:-${CROSS_REVIEW_FINDING_EVENTS:-$skill_dir/finding_events.jsonl}}"

errors=0
warns=0

# ── runlog pass ──────────────────────────────────────────────────────────
runlog_malformed=0
runlog_missing_ts=0
runlog_lines=0
declare -a runlog_errlines=()
run_ids_file="$(mktemp)"
: >"$run_ids_file"
sv_runlog_file="$(mktemp)"
: >"$sv_runlog_file"
orphan_run_ids_file="$(mktemp)"
: >"$orphan_run_ids_file"
sv_events_file="$(mktemp)"
: >"$sv_events_file"
trap 'rm -f "$run_ids_file" "$orphan_run_ids_file" "$sv_runlog_file" "$sv_events_file"' EXIT

if [[ -f "$runlog" ]]; then
  lineno=0
  while IFS= read -r line || [[ -n "$line" ]]; do
    lineno=$((lineno + 1))
    [[ -z "$line" ]] && continue
    runlog_lines=$((runlog_lines + 1))
    parsed="$(parse_line "$line")"
    if [[ -z "$parsed" ]]; then
      runlog_malformed=$((runlog_malformed + 1))
      runlog_errlines+=("runlog:$lineno malformed")
      continue
    fi
    if [[ "$(printf '%s' "$parsed" | jq -r 'has("ts")')" != "true" ]]; then
      runlog_missing_ts=$((runlog_missing_ts + 1))
      runlog_errlines+=("runlog:$lineno missing ts")
    fi
    rid="$(printf '%s' "$parsed" | jq -r '.run_id // empty')"
    [[ -n "$rid" ]] && printf '%s\n' "$rid" >>"$run_ids_file"
    sv="$(printf '%s' "$parsed" | jq -r 'if has("schema_version") then (.schema_version|tostring|gsub("[\\t\\n\\r]"; " ")) else "missing" end')"
    printf '%s\n' "$sv" >>"$sv_runlog_file"
  done <"$runlog"
fi

# ── events pass ──────────────────────────────────────────────────────────
events_malformed=0
events_unknown=0
declare -a events_errlines=()
declare -a events_warnlines=()
declare -a unknown_event_names=()
events_lines=0

if [[ -f "$events" ]]; then
  lineno=0
  while IFS= read -r line || [[ -n "$line" ]]; do
    lineno=$((lineno + 1))
    [[ -z "$line" ]] && continue
    events_lines=$((events_lines + 1))
    parsed="$(parse_line "$line")"
    if [[ -z "$parsed" ]]; then
      events_malformed=$((events_malformed + 1))
      events_errlines+=("events:$lineno malformed")
      continue
    fi
    ev="$(printf '%s' "$parsed" | jq -r '.event // empty')"
    if [[ -n "$ev" ]]; then
      allowed=0
      for a in $ALLOWED_EVENTS; do
        [[ "$a" == "$ev" ]] && { allowed=1; break; }
      done
      if [[ "$allowed" -eq 0 ]]; then
        events_unknown=$((events_unknown + 1))
        events_warnlines+=("events:$lineno unknown event '$ev'")
        unknown_event_names+=("$ev")
      fi
    fi
    erid="$(printf '%s' "$parsed" | jq -r '.run_id // empty')"
    if [[ -n "$erid" ]]; then
      if ! grep -qxF "$erid" "$run_ids_file" 2>/dev/null; then
        printf '%s\t%s\n' "$erid" "$lineno" >>"$orphan_run_ids_file"
      fi
    fi
    sv="$(printf '%s' "$parsed" | jq -r 'if has("schema_version") then (.schema_version|tostring|gsub("[\\t\\n\\r]"; " ")) else "missing" end')"
    printf '%s\n' "$sv" >>"$sv_events_file"
  done <"$events"
fi

orphan_count=$(wc -l <"$orphan_run_ids_file" | tr -d ' ')

errors=$((runlog_malformed + runlog_missing_ts + events_malformed))
warns=$((events_unknown + orphan_count))

# uniq -c output is "<count> <value>"; the value may contain spaces, so
# split on the first run of spaces only (awk sub), never on every field
# (kimi, PR #109 pass 2). Tabs/newlines were flattened at extraction.
sv_counts_tsv() {
  sort "$1" | uniq -c | awk '{ c = $1; sub(/^ *[0-9]+ /, ""); printf "%s\t%s\n", $0, c }'
}

sv_dist() {
  # <file> -> "1=3, missing=1" style distribution string
  local f="$1"
  [[ -s "$f" ]] || { echo "(none)"; return; }
  sv_counts_tsv "$f" | awk -F'\t' '{printf "%s=%s, ", $1, $2}' | sed 's/, $//'
}

sv_dist_json() {
  # Built through jq -R so an odd schema_version value (a string with a quote
  # or a space) cannot break the JSON (codex, PR #109 review).
  local f="$1"
  [[ -s "$f" ]] || { echo '{}'; return; }
  sv_counts_tsv "$f" \
    | jq -Rsc 'split("\n") | map(select(length > 0) | split("\t") | {(.[0]): (.[1] | tonumber)}) | add // {}'
}

if [[ "$json_out" -eq 1 ]]; then
  runlog_sv_json="$(sv_dist_json "$sv_runlog_file")"
  events_sv_json="$(sv_dist_json "$sv_events_file")"
  orphan_examples_json="[]"
  if [[ -s "$orphan_run_ids_file" ]]; then
    orphan_examples_json="$(cut -f1 "$orphan_run_ids_file" | sort -u | head -5 | jq -R . | jq -sc .)"
  fi
  unknown_examples_json="$(printf '%s\n' "${unknown_event_names[@]:-}" | sort -u | head -5 | jq -R 'select(length>0)' | jq -sc . 2>/dev/null || echo '[]')"
  jq -nc \
    --argjson runlog_lines "$runlog_lines" \
    --argjson runlog_malformed "$runlog_malformed" \
    --argjson runlog_missing_ts "$runlog_missing_ts" \
    --argjson runlog_sv "$runlog_sv_json" \
    --argjson events_lines "$events_lines" \
    --argjson events_malformed "$events_malformed" \
    --argjson events_unknown "$events_unknown" \
    --argjson events_sv "$events_sv_json" \
    --argjson orphan_count "$orphan_count" \
    --argjson orphan_examples "$orphan_examples_json" \
    --argjson unknown_examples "$unknown_examples_json" \
    --argjson errors "$errors" \
    --argjson warns "$warns" \
    '{
      runlog: {lines: $runlog_lines, malformed: $runlog_malformed, missing_ts: $runlog_missing_ts, schema_version: $runlog_sv},
      events: {lines: $events_lines, malformed: $events_malformed, unknown_event: $events_unknown, unknown_event_examples: $unknown_examples, orphan_run_id: $orphan_count, orphan_run_id_examples: $orphan_examples, schema_version: $events_sv},
      errors: $errors,
      warns: $warns
    }'
else
  for l in "${runlog_errlines[@]:-}"; do
    [[ -n "$l" ]] && echo "ERROR $l"
  done
  for l in "${events_errlines[@]:-}"; do
    [[ -n "$l" ]] && echo "ERROR $l"
  done
  for l in "${events_warnlines[@]:-}"; do
    [[ -n "$l" ]] && echo "WARN  $l"
  done
  if [[ "$orphan_count" -gt 0 ]]; then
    echo "WARN  events: $orphan_count event(s) with a run_id absent from runlog (orphan run_id):"
    cut -f1 "$orphan_run_ids_file" | sort -u | head -5 | while IFS= read -r rid; do
      echo "  orphan run_id '$rid'"
    done
  fi
  echo "runlog: $runlog_lines lines, $runlog_malformed malformed, $runlog_missing_ts missing ts, schema_version: $(sv_dist "$sv_runlog_file")"
  echo "events: $events_lines lines, $events_malformed malformed, $events_unknown unknown event(s), $orphan_count orphan run_id(s), schema_version: $(sv_dist "$sv_events_file")"
fi

if [[ "$errors" -gt 0 ]]; then
  exit 1
fi
exit 0
