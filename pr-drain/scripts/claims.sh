#!/bin/bash
# claims.sh — per-reviewer claim-accuracy ledger.
#
# Every P0/P1-severity reviewer claim gets a verdict logged at triage time:
#   APPLIED   — claim was real; a fix landed
#   REFUTED   — claim was testably false (evidence required)
#   OUT_OF_DIFF — real but pre-existing; routed to a follow-up issue
#   NOTED     — accepted as real, below the apply threshold
# Over time the ledger becomes a prior: a reviewer whose Criticals rarely
# survive verification deserves cheaper first-pass checks, not more trust.
#
# Usage:
#   claims.sh log <reviewer> <severity> <verdict> <pr> "<claim summary>" ["<evidence>"]
#   claims.sh stats [reviewer]     # survival rate per reviewer (P0/P1 focus)
#   claims.sh prior <reviewer>     # one-line prior for triage prompts
# Env: PR_DRAIN_WORKDIR (default .pr-drain) for per-drain ledger;
#      PR_DRAIN_CLAIMS_GLOBAL=~/.pr-drain/claims.jsonl accumulates across drains.
set -euo pipefail

WORKDIR="${PR_DRAIN_WORKDIR:-.pr-drain}"
LOCAL="$WORKDIR/claims.jsonl"
GLOBAL="${PR_DRAIN_CLAIMS_GLOBAL:-$HOME/.pr-drain/claims.jsonl}"
VALID_VERDICTS="APPLIED REFUTED OUT_OF_DIFF NOTED"

stats_of() { # $1 = file, $2 = optional reviewer filter
  [ -f "$1" ] || { echo "no claims recorded yet ($1 missing)"; return 0; }
  jq -rs --arg rev "${2:-}" '
    map(select($rev == "" or .reviewer == $rev))
    | group_by(.reviewer)
    | .[]
    | . as $c
    | ($c | map(select(.severity == "Critical" or .severity == "High"))) as $p01
    | ($p01 | map(select(.verdict == "APPLIED" or .verdict == "OUT_OF_DIFF")) | length) as $real
    | ($p01 | map(select(.verdict == "REFUTED")) | length) as $false
    | "\($c[0].reviewer): P0/P1 \($real) real / \($false) refuted of \($p01|length) (all-severity claims: \($c|length))"
  ' "$1"
}

cmd="${1:-}"
case "$cmd" in
  log)
    reviewer="${2:?reviewer}"; severity="${3:?severity}"; verdict="${4:?verdict}"
    pr="${5:?pr}"; claim="${6:?claim summary}"; evidence="${7:-}"
    if ! grep -qw "$verdict" <<<"$VALID_VERDICTS"; then
      echo "claims.sh: invalid verdict '$verdict' (valid: $VALID_VERDICTS)" >&2; exit 1
    fi
    if [ "$verdict" = "REFUTED" ] && [ -z "$evidence" ]; then
      echo "claims.sh: REFUTED requires evidence — the one-liner that disproved it" >&2; exit 1
    fi
    line=$(jq -cn --arg r "$reviewer" --arg s "$severity" --arg v "$verdict" \
      --arg pr "$pr" --arg c "$claim" --arg e "$evidence" \
      --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      '{reviewer:$r, severity:$s, verdict:$v, pr:($pr|tonumber), claim:$c, evidence:$e, ts:$ts}')
    # Local ledger always writes (it is a dry-run deliverable); the GLOBAL
    # cross-drain ledger is a long-lived prior and must not collect rehearsal
    # verdicts, so only it is gated on dry-run.
    mkdir -p "$WORKDIR"
    printf '%s\n' "$line" >> "$LOCAL"
    if [ "${PR_DRAIN_DRY_RUN:-0}" = "1" ]; then
      echo "DRY-RUN: local only; would also append to $GLOBAL"
    else
      mkdir -p "$(dirname "$GLOBAL")"
      printf '%s\n' "$line" >> "$GLOBAL"
    fi
    echo "$line"
    ;;
  stats)
    echo "— this drain —"; stats_of "$LOCAL" "${2:-}"
    echo "— all drains —"; stats_of "$GLOBAL" "${2:-}"
    ;;
  prior)
    reviewer="${2:?reviewer}"
    [ -f "$GLOBAL" ] || { echo "$reviewer: no history"; exit 0; }
    jq -rs --arg rev "$reviewer" '
      map(select(.reviewer == $rev and (.severity == "Critical" or .severity == "High")))
      | if length == 0 then "\($rev): no P0/P1 history" else
          (map(select(.verdict == "REFUTED")) | length) as $f
          | "\($rev): \(length - $f) of \(length) past P0/P1 claims survived verification"
        end
    ' "$GLOBAL"
    ;;
  *)
    echo "usage: claims.sh log <reviewer> <severity> <verdict> <pr> \"<claim>\" [\"<evidence>\"] | stats [reviewer] | prior <reviewer>" >&2
    exit 1
    ;;
esac
