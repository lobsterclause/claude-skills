#!/bin/bash
# queue.sh — durable per-PR state machine over a JSONL event log.
# Usage:
#   queue.sh append <pr> <state> <sha> [note]   # record a transition
#   queue.sh status                             # latest state per PR
#   queue.sh log <pr>                           # full history for one PR
# Env: PR_DRAIN_WORKDIR (default: .pr-drain in cwd), PR_DRAIN_DRY_RUN (append prints only)
set -euo pipefail

WORKDIR="${PR_DRAIN_WORKDIR:-.pr-drain}"
LOG="$WORKDIR/events.jsonl"
VALID_STATES="QUEUED REVIEWING FIXING VERIFYING CI MERGED BLOCKED"

cmd="${1:-}"
case "$cmd" in
  append)
    pr="${2:?pr number required}"; state="${3:?state required}"; sha="${4:?sha required}"; note="${5:-}"
    if ! grep -qw "$state" <<<"$VALID_STATES"; then
      echo "queue.sh: invalid state '$state' (valid: $VALID_STATES)" >&2; exit 1
    fi
    line=$(jq -cn --arg pr "$pr" --arg state "$state" --arg sha "$sha" --arg note "$note" \
      --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      '{pr: ($pr|tonumber), state: $state, sha: $sha, note: $note, ts: $ts}')
    # Deliberately NOT gated on PR_DRAIN_DRY_RUN: dry-run means no GitHub
    # mutations. The event log is local state and is the dry-run's own
    # deliverable — gating it produced empty logs from flagged rehearsals.
    mkdir -p "$WORKDIR"
    printf '%s\n' "$line" >> "$LOG"
    echo "$line"
    ;;
  status)
    [ -f "$LOG" ] || { echo "no events yet ($LOG missing)"; exit 0; }
    jq -rs 'group_by(.pr) | map(max_by(.ts)) | sort_by(.pr)
            | .[] | "#\(.pr)  \(.state)  \(.sha[0:9])  \(.ts)  \(.note)"' "$LOG"
    ;;
  log)
    pr="${2:?pr number required}"
    [ -f "$LOG" ] || { echo "no events yet"; exit 0; }
    jq -rc --arg pr "$pr" 'select(.pr == ($pr|tonumber))' "$LOG"
    ;;
  *)
    echo "usage: queue.sh append <pr> <state> <sha> [note] | status | log <pr>" >&2
    exit 1
    ;;
esac
