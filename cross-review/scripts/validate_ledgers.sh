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
#   (b) runlog entries missing ts  -> ERROR  "runlog:<n> missing ts", UNLESS
#       the entry is a legacy row (no ts AND no schema_version -- version 0,
#       the pre-#109 era): that shape was valid when written, so it is
#       instead a WARN (see (f) below). A row that DOES carry a
#       schema_version (>= 1) and has no ts stays an ERROR -- a writer that
#       already stamps schema_version has no excuse to drop ts (#111).
#   (c) events with an unknown     -> WARN   "events:<n> unknown event
#       `event` name (not in the             '<name>'"
#       allowlist below)
#   (d) events whose run_id has no -> WARN   summary + up to 5 examples,
#       matching runlog entry               "orphan run_id '<id>' (events:<n>)"
#   (e) schema_version distribution -> info line per file; entries/events
#       with no schema_version key land in the "missing" bucket (readers
#       treat absence as 0 -- the bucket is named "missing", not "0", so
#       pre-#96 rows stay distinguishable from an explicit 0)
#   (f) legacy no-ts rows (#111)   -> WARN   "legacy: runlog:<n> has no ts
#       (schema_version absent, i.e.        (pre-schema entry)"; counted
#       version 0, and no ts)               under runlog.legacy_no_ts.
#       Accepted by decision, not backfilled -- see #111 and
#       docs/decisions/2026-08-27-cross-review-ledger-rotation.md.
#   (g) schema_version above the   -> WARN   "runlog:<n> schema_version <v>
#       writer's current constant           is above the writer's current
#       (#122)                              <c>" / same for events; up to 5
#       examples + a count, under runlog.future_version /
#       events.future_version. The writer's current constant is read live
#       from append_runlog.sh / append_finding_event.sh (SCHEMA_VERSION=N);
#       if that can't be read, current_schema_version falls back to 1 with
#       a WARN rather than silently skipping the check.
#
# A line is malformed unless it is exactly ONE JSON object: a bare scalar,
# an array, or two documents on one physical line all count as malformed
# (codex, PR #109 review). Paths: an explicitly supplied --runlog/--events
# that does not exist is an error (exit 2); an absent DEFAULT ledger is
# treated as empty, since a fresh install has none yet.
#
# Exit: 0 if no ERROR-level findings, 1 if any malformed line or missing-ts
# (non-legacy) entry exists. WARN-level findings (unknown event, orphan
# run_id, legacy no-ts, future schema_version) do not affect the exit code.
#
# Portability: macOS bash 3.2 + ubuntu bash 5; needs jq. set -uo pipefail
# (no -e: we want to keep scanning after a bad line, not abort).

set -uo pipefail

# Allowlisted event names (#96 spec). Anything else is a WARN, not an ERROR —
# new event types are expected to show up before this list is updated.
ALLOWED_EVENTS="proposed anchored factcheck_kept factcheck_dropped parent_verified_kept parent_verified_dropped fix_applied fix_verified fix_failed deferred unresolved human_accepted human_rejected regression_detected duplicate_merged planted caught missed"

# Single-pass line extraction (#132): one jq process per ledger file, not
# per line. jq's `-R` raw-input mode runs the filter once per physical
# line inside ONE process; `foreach inputs` keeps our own line counter so a
# final line with no trailing newline still numbers correctly (jq's builtin
# input_line_number undercounts that case). Each line becomes exactly one
# row: a blank physical line produces no row (matching the old
# `[[ -z "$line" ]] && continue`); a line is malformed unless
# `$raw | fromjson` succeeds AND the result is a JSON object -- a bare
# scalar, an array, or two documents on one physical line (trailing
# non-whitespace after the parsed value is a `fromjson` parse error) all
# land in the "malformed" branch, same as the old `jq -cs` slurp check
# (codex, PR #109 review). Fields that feed the schema_version distribution
# buckets keep the existing tab/newline/CR flatten so the bucket stays a
# single field. run_id and event get the same `tostring | gsub` treatment:
# `join` aborts the whole jq process on an object/array element (every row
# after it silently vanished — "runlog: 0 lines"), and a newline inside a
# value split one row into two for the bash reader while a tab broke the
# tab-keyed orphan join below (cross-review of #139).
#
# Rows join fields with \x1F (ASCII unit separator, spelled "\u001f" in the
# jq program so no raw control byte sits in this file), not a real tab: bash's
# `read` treats tab as "IFS whitespace" and collapses runs of it regardless
# of what IFS is set to, silently dropping empty middle fields (e.g. a
# non-numeric schema_version leaves sv_num empty) and shifting every field
# after it. \x1F is not IFS whitespace, so `read` with IFS=$'\x1f' keeps
# empty fields intact.
runlog_extract_jq='
foreach inputs as $raw (0; . + 1;
  if $raw == "" then empty
  else
    (try ($raw | fromjson) catch " ERR") as $p
    | if ($p == " ERR") or (($p|type) != "object") then
        [., "malformed", "", "", "", "", ""] | join("\u001f")
      else
        ($p) as $o
        | [., "ok",
           ($o|has("ts")|if . then "1" else "0" end),
           ($o|has("schema_version")|if . then "1" else "0" end),
           ($o.schema_version | if type == "number" then tostring else "" end),
           (($o.run_id // "") | tostring | gsub("[\t\n\r]"; " ")),
           ($o|if has("schema_version") then (.schema_version|tostring|gsub("[\t\n\r]"; " ")) else "missing" end)
          ] | join("\u001f")
      end
  end
)
'
events_extract_jq='
foreach inputs as $raw (0; . + 1;
  if $raw == "" then empty
  else
    (try ($raw | fromjson) catch " ERR") as $p
    | if ($p == " ERR") or (($p|type) != "object") then
        [., "malformed", "", "", "", "", ""] | join("\u001f")
      else
        ($p) as $o
        | [., "ok",
           (($o.event // "") | tostring | gsub("[\t\n\r]"; " ")),
           (($o.run_id // "") | tostring | gsub("[\t\n\r]"; " ")),
           ($o|has("schema_version")|if . then "1" else "0" end),
           ($o.schema_version | if type == "number" then tostring else "" end),
           ($o|if has("schema_version") then (.schema_version|tostring|gsub("[\t\n\r]"; " ")) else "missing" end)
          ] | join("\u001f")
      end
  end
)
'

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

# Current writer schema_version constants (#122). Read live from the writer
# scripts rather than duplicating the number here, so a bump in the writer
# is picked up automatically. Falls back to 1 (the version both writers
# stamp as of #109) with a WARN if the constant can't be read.
current_ver_warns=0
# Sets the named variable in THIS shell (printf -v): a $(...) call would run
# in a subshell and lose the warning counter increment (antigravity +
# gemini-pro, PR #127 review). Writers can be pointed elsewhere for tests via
# $CROSS_REVIEW_WRITERS_DIR.
writers_dir="${CROSS_REVIEW_WRITERS_DIR:-$skill_dir/scripts}"
read_current_schema_version() {
  local writer="$1" target="$2" v
  # -f as well as -r: a FIFO or device would block grep forever; trailing
  # CR/spaces (a CRLF checkout) must not read as "unparseable" (gemini-pro)
  if [[ -f "$writer" && -r "$writer" ]]; then
    v="$(grep -m 1 -E '^SCHEMA_VERSION=' -- "$writer" 2>/dev/null | cut -d= -f2 | tr -d ' \t\r')"
    # no leading zeros: bash arithmetic would read 08 as octal (gemini-pro)
    if [[ "$v" =~ ^(0|[1-9][0-9]*)$ ]]; then
      printf -v "$target" '%s' "$v"
      return 0
    fi
  fi
  current_ver_warns=$((current_ver_warns + 1))
  printf -v "$target" '1'
}
read_current_schema_version "$writers_dir/append_runlog.sh" runlog_current_sv
read_current_schema_version "$writers_dir/append_finding_event.sh" events_current_sv

# True if $1 (a schema_version already known to be a JSON number, per jq's
# `tostring`) is above the writer's current constant $2. $2 is always a
# clean non-negative integer (validated above). $1 is almost always one
# too -- forking `awk` for every single line to compare, once the per-line
# jq calls were folded into one pass, became the new dominant cost on a
# multi-thousand-line ledger (#132 perf follow-up). Bash integer compare
# handles that common case with no fork; `awk` is still used, but only for
# the rare non-integer schema_version (e.g. "1.5"), to keep that case
# "handled exactly as today" (float precision, scientific notation, etc).
sv_is_future() {
  local v="$1" cur="$2"
  if [[ "$v" =~ ^(0|-?[1-9][0-9]*)$ ]]; then
    [[ "$v" -gt "$cur" ]]
  else
    awk -v a="$v" -v b="$cur" 'BEGIN{exit !(a > b)}'
  fi
}

errors=0
warns=0

# ── runlog pass ──────────────────────────────────────────────────────────
runlog_malformed=0
runlog_missing_ts=0
runlog_legacy_no_ts=0
runlog_future_version=0
runlog_lines=0
declare -a runlog_errlines=()
declare -a runlog_warnlines=()
declare -a runlog_future_examples=()
run_ids_file="$(mktemp)"
: >"$run_ids_file"
sv_runlog_file="$(mktemp)"
: >"$sv_runlog_file"
orphan_run_ids_file="$(mktemp)"
: >"$orphan_run_ids_file"
erid_candidates_file="$(mktemp)"
: >"$erid_candidates_file"
sv_events_file="$(mktemp)"
: >"$sv_events_file"
trap 'rm -f "$run_ids_file" "$orphan_run_ids_file" "$erid_candidates_file" "$sv_runlog_file" "$sv_events_file"' EXIT

if [[ -f "$runlog" ]]; then
  while IFS=$'\x1f' read -r lineno status has_ts has_sv sv_num rid sv; do
    runlog_lines=$((runlog_lines + 1))
    if [[ "$status" == "malformed" ]]; then
      runlog_malformed=$((runlog_malformed + 1))
      runlog_errlines+=("runlog:$lineno malformed")
      continue
    fi
    if [[ "$has_ts" != "1" ]]; then
      if [[ "$has_sv" != "1" ]]; then
        # Legacy row: no ts, no schema_version (version 0, the pre-#109
        # era). Valid when written -- WARN, not ERROR (#111, accepted by
        # decision, not backfilled).
        runlog_legacy_no_ts=$((runlog_legacy_no_ts + 1))
        runlog_warnlines+=("legacy: runlog:$lineno has no ts (pre-schema entry)")
      else
        runlog_missing_ts=$((runlog_missing_ts + 1))
        runlog_errlines+=("runlog:$lineno missing ts")
      fi
    fi
    if [[ "$has_sv" == "1" ]]; then
      if [[ -n "$sv_num" ]] && sv_is_future "$sv_num" "$runlog_current_sv"; then
        runlog_future_version=$((runlog_future_version + 1))
        runlog_warnlines+=("runlog:$lineno schema_version $sv_num is above the writer's current $runlog_current_sv")
        runlog_future_examples+=("$sv_num")
      fi
    fi
    [[ -n "$rid" ]] && printf '%s\n' "$rid" >>"$run_ids_file"
    printf '%s\n' "$sv" >>"$sv_runlog_file"
  done < <(jq -nR -r "$runlog_extract_jq" "$runlog")
fi

# ── events pass ──────────────────────────────────────────────────────────
events_malformed=0
events_unknown=0
events_future_version=0
declare -a events_errlines=()
declare -a events_warnlines=()
declare -a unknown_event_names=()
declare -a events_future_examples=()
events_lines=0

if [[ -f "$events" ]]; then
  while IFS=$'\x1f' read -r lineno status ev erid has_sv esv_num sv; do
    events_lines=$((events_lines + 1))
    if [[ "$status" == "malformed" ]]; then
      events_malformed=$((events_malformed + 1))
      events_errlines+=("events:$lineno malformed")
      continue
    fi
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
    # Candidate (run_id, lineno) pairs, not yet filtered against run_ids_file
    # -- forking `grep -qxF` once per event line was the dominant cost once
    # the per-line jq calls above were folded away (#132 perf follow-up).
    # The membership test itself becomes a single `awk` pass after this
    # loop instead.
    [[ -n "$erid" ]] && printf '%s\t%s\n' "$erid" "$lineno" >>"$erid_candidates_file"
    if [[ "$has_sv" == "1" ]]; then
      if [[ -n "$esv_num" ]] && sv_is_future "$esv_num" "$events_current_sv"; then
        events_future_version=$((events_future_version + 1))
        events_warnlines+=("events:$lineno schema_version $esv_num is above the writer's current $events_current_sv")
        events_future_examples+=("$esv_num")
      fi
    fi
    printf '%s\n' "$sv" >>"$sv_events_file"
  done < <(jq -nR -r "$events_extract_jq" "$events")
  # One awk pass, not one grep fork per event line: load every runlog
  # run_id into an in-memory set (NR==FNR), then keep only the candidate
  # (run_id, lineno) pairs whose run_id is absent from that set -- the same
  # exact-match semantics as the old `grep -qxF`, without re-forking per
  # candidate.
  # Membership is keyed on FILENAME, not the NR==FNR idiom: with an EMPTY
  # run_ids_file (no runlog rows carried a run_id) NR==FNR stays true for
  # the whole candidates file, every candidate lands in `seen`, and every
  # real orphan is silently swallowed (found in parent verification of #139).
  if [[ -s "$erid_candidates_file" ]]; then
    awk -F'\t' -v rf="$run_ids_file" 'FILENAME==rf{seen[$0]=1; next} !($1 in seen)' "$run_ids_file" "$erid_candidates_file" >"$orphan_run_ids_file"
  fi
fi

orphan_count=$(wc -l <"$orphan_run_ids_file" | tr -d ' ')

errors=$((runlog_malformed + runlog_missing_ts + events_malformed))
warns=$((events_unknown + orphan_count + runlog_legacy_no_ts + runlog_future_version + events_future_version + current_ver_warns))

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
  runlog_future_examples_json="$(printf '%s\n' "${runlog_future_examples[@]:-}" | sort -u | head -5 | jq -R 'select(length>0) | tonumber' | jq -sc . 2>/dev/null || echo '[]')"
  events_future_examples_json="$(printf '%s\n' "${events_future_examples[@]:-}" | sort -u | head -5 | jq -R 'select(length>0) | tonumber' | jq -sc . 2>/dev/null || echo '[]')"
  jq -nc \
    --argjson runlog_lines "$runlog_lines" \
    --argjson runlog_malformed "$runlog_malformed" \
    --argjson runlog_missing_ts "$runlog_missing_ts" \
    --argjson runlog_legacy_no_ts "$runlog_legacy_no_ts" \
    --argjson runlog_future_version "$runlog_future_version" \
    --argjson runlog_future_examples "$runlog_future_examples_json" \
    --argjson runlog_current_sv "$runlog_current_sv" \
    --argjson runlog_sv "$runlog_sv_json" \
    --argjson events_lines "$events_lines" \
    --argjson events_malformed "$events_malformed" \
    --argjson events_unknown "$events_unknown" \
    --argjson events_future_version "$events_future_version" \
    --argjson events_future_examples "$events_future_examples_json" \
    --argjson events_current_sv "$events_current_sv" \
    --argjson events_sv "$events_sv_json" \
    --argjson orphan_count "$orphan_count" \
    --argjson orphan_examples "$orphan_examples_json" \
    --argjson unknown_examples "$unknown_examples_json" \
    --argjson errors "$errors" \
    --argjson warns "$warns" \
    '{
      runlog: {lines: $runlog_lines, malformed: $runlog_malformed, missing_ts: $runlog_missing_ts, legacy_no_ts: $runlog_legacy_no_ts, future_version: $runlog_future_version, future_version_examples: $runlog_future_examples, current_schema_version: $runlog_current_sv, schema_version: $runlog_sv},
      events: {lines: $events_lines, malformed: $events_malformed, unknown_event: $events_unknown, unknown_event_examples: $unknown_examples, orphan_run_id: $orphan_count, orphan_run_id_examples: $orphan_examples, future_version: $events_future_version, future_version_examples: $events_future_examples, current_schema_version: $events_current_sv, schema_version: $events_sv},
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
  for l in "${runlog_warnlines[@]:-}"; do
    [[ -n "$l" ]] && echo "WARN  $l"
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
  if [[ "$current_ver_warns" -gt 0 ]]; then
    echo "WARN  unable to read a writer's current schema_version constant; falling back to 1 ($current_ver_warns writer(s))"
  fi
  echo "runlog: $runlog_lines lines, $runlog_malformed malformed, $runlog_missing_ts missing ts, $runlog_legacy_no_ts legacy no-ts, $runlog_future_version above-current schema_version, schema_version: $(sv_dist "$sv_runlog_file")"
  echo "events: $events_lines lines, $events_malformed malformed, $events_unknown unknown event(s), $orphan_count orphan run_id(s), $events_future_version above-current schema_version, schema_version: $(sv_dist "$sv_events_file")"
fi

if [[ "$errors" -gt 0 ]]; then
  exit 1
fi
exit 0
