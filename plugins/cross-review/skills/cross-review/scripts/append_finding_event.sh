#!/usr/bin/env bash
# append_finding_event.sh — append one event to the append-only finding
# lifecycle ledger, finding_events.jsonl (sibling to runlog.jsonl).
#
# Part of the Phase 1 finding-lifecycle telemetry (see the cross-review
# reviewer-selection design discussion, 2026-07): a finding_id (minted by
# fingerprint_findings.sh) accumulates events over its life. anchor_findings.sh
# and factcheck_findings.sh emit `anchored`/`factcheck_kept`/`factcheck_dropped`
# today via their own --emit-events flag; fingerprint_findings.sh emits
# `proposed`. Later stages (human_accepted/human_rejected, fix_applied/
# fix_verified/fix_failed, regression_detected) have no automated emitter yet
# — append them by hand or from a future step. This script only appends;
# leaderboard.sh reads the ledger (joined to runlog entries by run_id) to
# score reviewers per-finding — see its events-path scoring docs.
#
# Usage:
#   append_finding_event.sh --event <name> --finding-id <id> --run-id <id>
#                            [--fields '<json-object-string>']
#
#   --event <name>        event type, e.g. proposed|anchored|factcheck_kept|
#                          factcheck_dropped|human_accepted|human_rejected|
#                          fix_applied|fix_verified|fix_failed|
#                          regression_detected|duplicate_merged|unresolved.
#                          Free-form, not validated against a fixed enum —
#                          new event types don't need a script change.
#   --finding-id <id>      the stable f-<hash> id from fingerprint_findings.sh
#   --run-id <id>          joins this event to a runlog.jsonl entry
#                          (run_id = basename of the run-dir; see worktree.sh)
#   --fields <json-obj>    optional event-specific payload (JSON object
#                          string), merged into the entry. Identity fields
#                          (event/ts/finding_id/run_id) always win if
#                          --fields tries to set them too — a caller can't
#                          clobber the join keys.
#
# Exit: 0 ok, 2 usage / bad --fields, 1 io error (jq missing).
#
# CROSS_REVIEW_FINDING_EVENTS overrides the ledger path (mirrors
# CROSS_REVIEW_RUNLOG in append_runlog.sh) — fixture tests only, production
# callers never set it.

set -uo pipefail

event=""
finding_id=""
run_id=""
fields="{}"

need_val() {
  if [[ "$2" -lt 2 ]]; then
    echo "missing value for $1" >&2
    exit 2
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --event)      need_val "$1" "$#"; event="$2";      shift 2 ;;
    --finding-id) need_val "$1" "$#"; finding_id="$2"; shift 2 ;;
    --run-id)     need_val "$1" "$#"; run_id="$2";     shift 2 ;;
    --fields)     need_val "$1" "$#"; fields="$2";     shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

for required in event finding_id run_id; do
  if [[ -z "${!required}" ]]; then
    echo "usage: $0 --event <name> --finding-id <id> --run-id <id> [--fields '<json-object>']" >&2
    exit 2
  fi
done

command -v jq >/dev/null 2>&1 || { echo "append_finding_event: jq required" >&2; exit 1; }

if ! printf '%s' "$fields" | jq -e 'type == "object"' >/dev/null 2>&1; then
  echo "append_finding_event: --fields must be a JSON object, got: $fields" >&2
  exit 2
fi

# CROSS_REVIEW_FINDING_EVENTS override exists for the fixture tests —
# production callers never set it (mirrors CROSS_REVIEW_RUNLOG).
ledger="${CROSS_REVIEW_FINDING_EVENTS:-$(cd "$(dirname "$0")/.." && pwd)/finding_events.jsonl}"

ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

entry=$(jq -nc \
  --argjson fields "$fields" \
  --arg event "$event" \
  --arg ts "$ts" \
  --arg finding_id "$finding_id" \
  --arg run_id "$run_id" \
  '$fields + {event: $event, ts: $ts, finding_id: $finding_id, run_id: $run_id}')

# Same flock-with-fallback append pattern as append_runlog.sh (mirrored, not
# reimplemented): POSIX write() atomicity below PIPE_BUF makes concurrent
# appends safe without a lock on most platforms; flock removes the risk
# entirely where available. Falls back to bare append when missing.
if command -v flock >/dev/null 2>&1; then
  (
    flock -x 200
    printf '%s\n' "$entry" >>"$ledger"
  ) 200>"$ledger.lock"
else
  printf '%s\n' "$entry" >>"$ledger"
fi
echo "appended finding event: event=$event finding_id=$finding_id run_id=$run_id" >&2
