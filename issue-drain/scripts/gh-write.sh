#!/bin/bash
# gh-write.sh — the one path by which issue-drain writes to GitHub.
#
# Usage:
#   gh-write.sh issue-create --title <t> --body-file <f>   # labelled TRACKER_LABEL; prints the URL
#   gh-write.sh comment <number> --body-file <f>
#   gh-write.sh ensure-label <label>
#   gh-write.sh add-label <number> <label>
#   gh-write.sh remove-label <number> <label>
#   gh-write.sh close-issue <number>
# Env: ISSUE_DRAIN_REPO, ISSUE_DRAIN_WORKDIR (absolute), ISSUE_DRAIN_DRY_RUN=1,
#      ISSUE_DRAIN_MODE=session|driver|unit (default session), ISSUE_DRAIN_PROFILE
# Exit: 0 done (or WOULD printed), 2 usage, 3 refused, other = gh's own failure.
#
# Why one script: pr-drain's poller once merged 12 PRs with 11 review threads
# still open, because the thread gate only watched Claude's own Bash calls. A
# rule that lives in the one write path cannot be skipped by a second path.
# Three rules live here:
#   - dry-run is one switch: with ISSUE_DRAIN_DRY_RUN=1 every verb prints
#     "WOULD: ..." and calls nothing;
#   - labels are limited to the three the drain owns (claim, blocked, tracker),
#     and only the claim label can be removed;
#   - a unit process (ISSUE_DRAIN_MODE=unit) can comment and nothing else.
#     Claims, hold labels and closures belong to the driver and the session.
# Bodies come from a file, never from an argument, so issue text never meets
# shell quoting.
set -euo pipefail
. "$(dirname "$0")/lib.sh"
need_workdir
need_repo
load_profile

MODE="${ISSUE_DRAIN_MODE:-session}"
case "$MODE" in session|driver|unit) ;; *) die "ISSUE_DRAIN_MODE must be session, driver or unit (got '$MODE')" 2 ;; esac

verb="${1:-}"
[ -n "$verb" ] || die "usage: gh-write.sh <issue-create|comment|ensure-label|add-label|remove-label|close-issue> ..." 2
shift

refuse() {
  log_event gh_write_refused "$(jq -cn --arg verb "$verb" --arg why "$1" --arg mode "$MODE" '{verb: $verb, why: $why, mode: $mode}')"
  die "refused: $1" 3
}

if [ "$MODE" = "unit" ] && [ "$verb" != "comment" ]; then
  refuse "a unit process may only comment (asked for '$verb')"
fi

body_file=""
title=""
args=()
while [ $# -gt 0 ]; do
  case "$1" in
    --body-file) body_file="${2:-}"; shift 2 ;;
    --title) title="${2:-}"; shift 2 ;;
    --*) die "unknown option $1" 2 ;;
    *) args+=("$1"); shift ;;
  esac
done

need_body() {
  [ -n "$body_file" ] || die "$verb needs --body-file <file>" 2
  [ -s "$body_file" ] || die "body file is missing or empty: $body_file" 2
}
need_number() { is_number "${args[0]:-}" || die "$verb needs an issue or PR number (got '${args[0]:-}')" 2; }
owned_label() {
  case "$1" in "$CLAIM_LABEL"|"$BLOCKED_LABEL"|"$TRACKER_LABEL") return 0 ;; *) return 1 ;; esac
}

# run <description for the event log> <gh argv...>
run() {
  local what="$1"; shift
  local printable
  printable="$(printf '%q ' "$@")"
  if is_dry_run; then
    echo "WOULD: $printable"
    log_event gh_write "$(jq -cn --arg verb "$verb" --arg what "$what" '{verb: $verb, what: $what, dry_run: true}')"
    return 0
  fi
  local rc=0
  "$@" || rc=$?
  log_event gh_write "$(jq -cn --arg verb "$verb" --arg what "$what" --argjson rc "$rc" '{verb: $verb, what: $what, dry_run: false, rc: $rc}')"
  return "$rc"
}

case "$verb" in
  issue-create)
    need_body
    [ -n "$title" ] || die "issue-create needs --title" 2
    run "tracker issue" gh issue create --repo "$REPO" --title "$title" --body-file "$body_file" --label "$TRACKER_LABEL"
    ;;
  comment)
    need_number; need_body
    run "comment on #${args[0]}" gh issue comment "${args[0]}" --repo "$REPO" --body-file "$body_file"
    ;;
  ensure-label)
    label="${args[0]:-}"
    owned_label "$label" || refuse "'$label' is not a label the drain owns ($CLAIM_LABEL, $BLOCKED_LABEL, $TRACKER_LABEL)"
    # No --force: an existing label keeps the colour and text its owner gave it.
    if is_dry_run; then
      run "label $label" gh label create "$label" --repo "$REPO"
    elif gh label list --repo "$REPO" --search "$label" --json name --jq '.[].name' | grep -Fxq "$label"; then
      :
    else
      run "label $label" gh label create "$label" --repo "$REPO"
    fi
    ;;
  add-label)
    need_number
    label="${args[1]:-}"
    case "$label" in "$CLAIM_LABEL"|"$BLOCKED_LABEL") ;; *) refuse "may only add '$CLAIM_LABEL' or '$BLOCKED_LABEL' (asked for '$label')" ;; esac
    run "add $label to #${args[0]}" gh issue edit "${args[0]}" --repo "$REPO" --add-label "$label"
    ;;
  remove-label)
    need_number
    label="${args[1]:-}"
    [ "$label" = "$CLAIM_LABEL" ] || refuse "may only remove '$CLAIM_LABEL' (asked for '$label')"
    run "remove $label from #${args[0]}" gh issue edit "${args[0]}" --repo "$REPO" --remove-label "$label"
    ;;
  close-issue)
    need_number
    run "close #${args[0]}" gh issue close "${args[0]}" --repo "$REPO" --reason completed
    ;;
  *)
    die "unknown verb '$verb'" 2
    ;;
esac
