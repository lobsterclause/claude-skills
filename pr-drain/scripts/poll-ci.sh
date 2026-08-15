#!/bin/bash
# poll-ci.sh — watch a PR's required checks on a pinned SHA; merge on all-green.
# Run as a BACKGROUND task; its exit is the orchestrator's wake signal.
#
# Usage: poll-ci.sh <repo> <pr> <sha> [interval_s] [max_polls]
#   repo         owner/name
#   sha          the exact head the checks must report against (pinned; HEAD moving = abort)
#   interval_s   default 180 (CI takes ~13 min; faster polling is waste)
#   max_polls    default 20
#
# Required checks + the commit-status context are read from env (comma-separated), with
# defaults matching kindred-mama-ai:
#   PR_DRAIN_CHECKS="Dagger Pipeline,Semgrep Scan,PR Guards"
#   PR_DRAIN_STATUS_CONTEXT="cross-review/current"   (set empty to skip)
#   PR_DRAIN_DRY_RUN=1  -> report WOULD_MERGE instead of merging
#
# Exit codes: 0 merged (or WOULD_MERGE) | 2 a check failed | 3 head moved | 5 timeout
set -uo pipefail

REPO="${1:?repo (owner/name) required}"
PR="${2:?pr number required}"
SHA="${3:?head sha required}"
INTERVAL="${4:-180}"
MAX_POLLS="${5:-20}"
CHECKS="${PR_DRAIN_CHECKS:-Dagger Pipeline,Semgrep Scan,PR Guards}"
STATUS_CTX="${PR_DRAIN_STATUS_CONTEXT-cross-review/current}"

IFS=',' read -r -a REQ <<< "$CHECKS"

for i in $(seq 1 "$MAX_POLLS"); do
  sleep "$INTERVAL"

  head=$(gh pr view "$PR" -R "$REPO" --json headRefOid --jq .headRefOid) || continue
  if [ "$head" != "$SHA" ]; then
    echo "HEAD_MOVED $head (expected $SHA)"; exit 3
  fi

  runs=$(gh api "repos/$REPO/commits/$SHA/check-runs" \
    --jq '.check_runs[] | "\(.name)|\(.status)|\(.conclusion)"') || continue

  all_green=1; line=""
  for name in "${REQ[@]}"; do
    row=$(grep -F "$name|" <<<"$runs" | head -1)
    st="${row#*|}"
    line="$line ${name}:${st:-absent}"
    case "$st" in
      completed\|success) ;;
      completed\|*) echo "POLL $i:$line"; echo "TERMINAL_FAIL ($name: $st)"; exit 2 ;;
      *) all_green=0 ;;
    esac
  done

  cr_ok=1
  if [ -n "$STATUS_CTX" ]; then
    cr=$(gh api "repos/$REPO/commits/$SHA/status" \
      --jq "[.statuses[] | select(.context==\"$STATUS_CTX\")][0] | \"\(.state):\(.description)\"") || cr="unknown"
    line="$line | $STATUS_CTX=$cr"
    # A vacuous pass ("no cross-review record on this PR") is green but is NOT a
    # review — auto-merging on it would land an unreviewed PR. Require a real stamp.
    if ! grep -q '^success' <<<"$cr" || grep -qi 'no cross-review record' <<<"$cr"; then
      cr_ok=0
    fi
    grep -q '^failure\|^error' <<<"$cr" && { echo "POLL $i:$line"; echo "TERMINAL_FAIL ($STATUS_CTX: $cr)"; exit 2; }
  fi

  echo "POLL $i:$line"

  if [ "$all_green" = "1" ] && [ "$cr_ok" = "1" ]; then
    if [ "${PR_DRAIN_DRY_RUN:-0}" = "1" ]; then
      echo "WOULD_MERGE: gh pr merge $PR -R $REPO --squash --match-head-commit $SHA"; exit 0
    fi
    if gh pr merge "$PR" -R "$REPO" --squash --match-head-commit "$SHA"; then
      echo "MERGED"; exit 0
    fi
    echo "MERGE_FAILED"; exit 4
  fi
done
echo "TIMEOUT after $MAX_POLLS polls"; exit 5
