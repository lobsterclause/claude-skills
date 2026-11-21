#!/bin/bash
# close-verified.sh — close the issues a person ticked on the tracker as
# already fixed, each with a comment that shows the fix.
#
# Usage: close-verified.sh [<number>...] [--ref <ref>] [--no-fetch] [--body-file <file>]
#   no numbers    every closure ticked on the tracker
#   --ref         default origin/<BASE_BRANCH>
#   --no-fetch    do not fetch the base branch first
#   --body-file   read the tracker body from a file. Dry-run only: a live
#                 closure reads the published tracker, so the tick it acts on
#                 is one a person made on GitHub, not one written to a file.
# Env: ISSUE_DRAIN_WORKDIR (absolute), ISSUE_DRAIN_REPO, ISSUE_DRAIN_REPO_DIR,
#      ISSUE_DRAIN_PROFILE, ISSUE_DRAIN_DRY_RUN=1
# Exit: 0 every issue asked for is closed, or was closed already; 1 a GitHub
#       call failed or a close did not take; 2 usage or missing input;
#       3 at least one closure was refused (the rest were still done).
#
# "30 closed" was once reported with none closed, and three of eight "obsolete"
# calls were wrong. So an issue is closed only when all of this holds at the
# moment of closing, not at the moment of triage:
#   - tracker.sh render offered it as a closure and its box is ticked on the
#     tracker; the tracker has no STOP line, no ticked line the run never
#     offered, and is still open;
#   - evidence-check.sh, run again on the base branch as it is now, still calls
#     it already_fixed and closable, and names the same fixing commit the
#     tracker showed;
#   - the issue is open and carries no hold label and no claim label.
# The comment goes first and the close second, so no issue is closed without
# its reason. A closure killed between the two is finished by running this
# again: the comment is recognised by its first line and not posted twice.
# After the close call the issue is read back; "closed" means GitHub says so.
set -euo pipefail
. "$(dirname "$0")/lib.sh"
need_workdir
need_repo
need_repo_dir
load_profile

HERE="$(cd "$(dirname "$0")" && pwd)"
run="$(basename "$WORKDIR")"

ref=""
fetch=1
body_file=""
numbers=()
while [ $# -gt 0 ]; do
  case "$1" in
    --ref) ref="${2:-}"; shift 2 ;;
    --no-fetch) fetch=0; shift ;;
    --body-file) body_file="${2:-}"; shift 2 ;;
    --*) die "unknown option $1" 2 ;;
    *) is_number "$1" || die "not an issue number: '$1'" 2; numbers+=("$1"); shift ;;
  esac
done
[ -z "$body_file" ] || is_dry_run || die "--body-file is for dry runs; a live closure reads the published tracker" 2
[ -n "$ref" ] || ref="origin/$BASE_BRANCH"
for f in "$WORKDIR/queue.json" "$WORKDIR/verdicts.checked.json"; do
  [ -f "$f" ] || die "missing $f; this run has no rendered tracker" 2
done

refuse_all() {
  log_event closure_refused "$(jq -cn --arg why "$1" '{number: null, why: $why}')"
  die "refused: $1" 3
}

# What the tracker offers and what is ticked on it.
parse_args=()
[ -z "$body_file" ] || parse_args=(--body-file "$body_file")
rc=0
parsed="$("$HERE/tracker.sh" parse ${parse_args[@]+"${parse_args[@]}"})" || rc=$?
case "$rc" in
  0) ;;
  1) refuse_all "the tracker has a ticked line this run never offered; nothing is closed until that line is gone" ;;
  *) exit "$rc" ;;
esac
[ "$(printf '%s' "$parsed" | jq -r '.stop')" != "true" ] || refuse_all "the tracker says STOP"
[ "$(printf '%s' "$parsed" | jq -r '.tracker_state // "OPEN"')" = "OPEN" ] || refuse_all "the tracker issue is closed"
approved="$(printf '%s' "$parsed" | jq -c '.approved_closures')"

if [ ${#numbers[@]} -eq 0 ]; then
  for n in $(printf '%s' "$approved" | jq -r '.[]'); do numbers+=("$n"); done
fi
if [ ${#numbers[@]} -eq 0 ]; then
  echo "close-verified: no closure is ticked on the tracker; nothing to do"
  exit 0
fi
for n in "${numbers[@]}"; do
  [ "$(printf '%s' "$approved" | jq --argjson n "$n" 'index($n) != null')" = "true" ] ||
    refuse_all "#$n is not a ticked closure on the tracker"
done

if [ "$fetch" = 1 ]; then
  git -C "$REPO_DIR" fetch --quiet origin "$BASE_BRANCH" ||
    die "could not fetch $BASE_BRANCH in $REPO_DIR; a closure is checked against the base as it is now" 1
fi

tracker_num=""
[ ! -f "$WORKDIR/tracker.json" ] || tracker_num="$(jq -r '.number // ""' "$WORKDIR/tracker.json")"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$WORKDIR/closures"
marker="<!-- issue-drain:closure run=$run -->"
refused=0
refuse_one() {
  echo "refused #$1: $2"
  log_event closure_refused "$(jq -cn --argjson n "$1" --arg why "$2" '{number: $n, why: $why}')"
  refused=1
}

# shellcheck disable=SC2016
COMMENT='
  def safe: tostring | gsub("[\\p{Cc}\\p{Cf}]+"; " ") | gsub("<"; "&lt;") | gsub("@"; "@​");
  def span: . as $s
    | ([ $s | match("`+"; "g") | .length ] | max // 0) as $m
    | ("`" * ($m + 1)) as $d
    | $d + (if ($s | test("^`|`$")) then " " + $s + " " else $s end) + $d;
  def path: split("/") | map(@uri) | join("/");
  [ $marker,
    "Closing as already fixed on `\($base)`.",
    "",
    "The fix is [`\(.fix_commit.sha[0:7])`](https://github.com/\($repo)/commit/\(.fix_commit.sha)), \"\(.fix_commit.subject | safe)\", committed \(.fix_commit.date[0:10]). On `\($base)` at `\(.checked_sha[0:7])` the code reads:",
    "",
    ( .evidence[] | "- [\("\(.file):\(.line)" | span)](https://github.com/\($repo)/blob/\($sha)/\(.file | path)#L\(.line)): \(.quote | span)" ),
    "",
    ( if $note == "" then empty else ($note | safe), "" end ),
    "Checked by issue-drain run `\($run)`" + (if $tracker == "" then "" else " and approved on #\($tracker)" end) + ". Reopen this if it still reproduces."
  ] | join("\n")'

for n in "${numbers[@]}"; do
  offered="$(jq -c --argjson n "$n" '.closures[] | select(.number == $n)' "$WORKDIR/queue.json")"

  # The code, read again on the base as it is now.
  jq -c --argjson n "$n" '[ .[] | select(.number == $n) ]' "$WORKDIR/verdicts.checked.json" > "$tmp/verdict.json"
  if ! "$HERE/evidence-check.sh" "$tmp/verdict.json" --ref "$ref" --out "$tmp/checked.json" >/dev/null 2>"$tmp/err"; then
    refuse_one "$n" "the evidence check did not run ($(tail -n 1 "$tmp/err"))"
    continue
  fi
  fresh="$(jq -c --argjson n "$n" '.[] | select(.number == $n)' "$tmp/checked.json")"
  if [ "$(printf '%s' "$fresh" | jq -r '.status == "already_fixed" and .closable')" != "true" ]; then
    refuse_one "$n" "on $ref it no longer checks out as fixed ($(printf '%s' "$fresh" | jq -r '.downgrade_reason // .status'))"
    continue
  fi
  fix_now="$(printf '%s' "$fresh" | jq -r '.fix_commit.sha')"
  fix_then="$(printf '%s' "$offered" | jq -r '.fix_commit.sha')"
  if [ "$fix_now" != "$fix_then" ]; then
    refuse_one "$n" "the tracker showed ${fix_then:0:7} as the fix, and the quoted line now comes from ${fix_now:0:7}; triage it again"
    continue
  fi

  # The issue, as it is now.
  live="$(gh issue view "$n" --repo "$REPO" --json state,labels,comments)" || die "could not read #$n" 1
  state="$(printf '%s' "$live" | jq -r '.state')"
  if [ "$state" = "CLOSED" ]; then
    echo "skipped #$n: already closed"
    log_event closure_skipped "$(jq -cn --argjson n "$n" '{number: $n, why: "already closed"}')"
    continue
  fi
  if [ "$state" != "OPEN" ]; then
    refuse_one "$n" "its state is '$state'"
    continue
  fi
  held="$(printf '%s' "$live" | jq -r --arg hold "$HOLD_LABELS $CLAIM_LABEL" '
    ($hold | split(" ") | map(select(. != ""))) as $h
    | [ .labels[].name | select(. as $l | $h | index($l)) ] | first // ""')"
  if [ -n "$held" ]; then
    refuse_one "$n" "it now carries the label '$held'"
    continue
  fi

  printf '%s' "$fresh" | jq -r --arg marker "$marker" --arg base "$BASE_BRANCH" --arg repo "$REPO" \
      --arg sha "$(printf '%s' "$fresh" | jq -r '.checked_sha')" --arg run "$run" --arg tracker "$tracker_num" \
      --arg note "$(printf '%s' "$offered" | jq -r '.note // ""')" "$COMMENT" > "$WORKDIR/closures/$n.md"
  if [ "$(printf '%s' "$live" | jq --arg m "$marker" '[ .comments[].body | select(startswith($m)) ] | length')" = "0" ]; then
    "$HERE/gh-write.sh" comment "$n" --body-file "$WORKDIR/closures/$n.md"
  fi
  "$HERE/gh-write.sh" close-issue "$n"
  if is_dry_run; then
    echo "would close #$n (fixed by ${fix_now:0:7}); the comment is in $WORKDIR/closures/$n.md"
    continue
  fi

  after="$(gh issue view "$n" --repo "$REPO" --json state | jq -r '.state')" || die "closed #$n but could not read it back" 1
  if [ "$after" != "CLOSED" ]; then
    log_event closure_failed "$(jq -cn --argjson n "$n" --arg state "$after" '{number: $n, state: $state}')"
    die "#$n is still $after after the close call" 1
  fi
  log_event closure "$(jq -cn --argjson n "$n" --arg sha "$fix_now" --arg tracker "$tracker_num" '{number: $n, fix_commit: $sha, tracker: $tracker}')"
  echo "closed #$n (fixed by ${fix_now:0:7})"
done

[ "$refused" = 0 ] || exit 3
