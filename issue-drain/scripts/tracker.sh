#!/bin/bash
# tracker.sh — write, publish and read the tracker issue: the one place a
# person approves the queue.
#
# Usage:
#   tracker.sh render [--decisions <file>]   decisions + checked verdicts -> queue.json, tracker.md
#   tracker.sh publish                       open the tracker issue (through gh-write.sh)
#   tracker.sh parse [--body-file <file>]    read the tracker body -> JSON on stdout
# Env: ISSUE_DRAIN_WORKDIR (absolute; its last path part is the run id),
#      ISSUE_DRAIN_REPO, ISSUE_DRAIN_PROFILE, ISSUE_DRAIN_DRY_RUN=1
# Exit: 0 ok; 1 parse found a line it cannot honour (see "unknown" in its
#       output); 2 usage or missing input; 3 refused.
#
# render refuses a queue that breaks a rule, and says which: an issue that is
# not live, an issue in two units, a unit over the cluster cap, a risk-path
# issue sharing a unit with anything but its own duplicates, a protected path,
# a model or effort outside the allowed set, a missing acceptance check, and a
# live issue that is in no unit and has no stated reason. Every issue intake
# let in is shown somewhere on the tracker; "30 closed" was once reported with
# none closed, and a list nobody can check is how that happens.
#
# parse reads by line prefix and nothing else:
#   "- U3 · ..."              a queue unit, in the order written
#   "- [x] U5 · ..."          a ticked unit; these run before the queue
#   "- [x] close #101 ..."    an approved closure
#   "- [x] release #9 ..."    a stale claim to release
#   "STOP"                    on a line of its own
# A ticked line whose id or number is not in queue.json is reported under
# "unknown" and makes parse exit 1: a box can approve only what render offered.
# The drain never edits the body, so it cannot overwrite an edit of yours.
set -euo pipefail
. "$(dirname "$0")/lib.sh"
need_workdir
need_repo
load_profile

HERE="$(cd "$(dirname "$0")" && pwd)"
run="$(basename "$WORKDIR")"
printf '%s' "$run" | grep -Eq '^[A-Za-z0-9._-]+$' || die "the run folder's name is the run id and must be letters, digits, dot, dash or underscore (got '$run')" 2

cmd="${1:-}"
[ -n "$cmd" ] || die "usage: tracker.sh <render|publish|parse> ..." 2
shift

case "$cmd" in
  render)
    decisions="$WORKDIR/decisions.json"
    while [ $# -gt 0 ]; do
      case "$1" in
        --decisions) decisions="${2:-}"; shift 2 ;;
        *) die "unknown argument $1" 2 ;;
      esac
    done
    [ ! -f "$WORKDIR/tracker.json" ] || die "this run is already published as $(jq -r '.url' "$WORKDIR/tracker.json"); start a new run to triage again" 3
    for f in "$WORKDIR/intake.json" "$WORKDIR/verdicts.checked.json"; do
      [ -f "$f" ] || die "missing $f; run intake.sh and evidence-check.sh first" 2
    done
    jq -e 'type == "object"' "$decisions" >/dev/null 2>&1 || die "no decisions object at $decisions (see references/triage.md)" 2

    base_sha="$(jq -r '[.[].checked_sha // empty] | first // ""' "$WORKDIR/verdicts.checked.json")"
    result="$(jq --slurpfile intake "$WORKDIR/intake.json" --slurpfile checked "$WORKDIR/verdicts.checked.json" \
        --arg run "$run" --arg repo "$REPO" --arg base "$BASE_BRANCH" --arg base_sha "$base_sha" \
        --arg perms "$UNIT_PERMISSIONS" --arg prot "$PROTECTED_PATH_RE" \
        --arg models "$ALLOWED_MODELS" --arg efforts "$ALLOWED_EFFORTS" \
        --argjson max_issues "$CLUSTER_MAX_ISSUES" -f "$HERE/tracker-render.jq" "$decisions")" ||
      die "could not render $decisions" 2

    if [ "$(printf '%s' "$result" | jq '.errors | length')" != "0" ]; then
      printf '%s' "$result" | jq -r '.errors[] | "  " + .' >&2
      log_event tracker_render_refused "$(printf '%s' "$result" | jq -c '{errors: .errors}')"
      die "refused: the queue breaks the rules above; fix decisions.json and render again" 3
    fi
    printf '%s' "$result" | jq '.queue + {title: .title}' > "$WORKDIR/queue.json.tmp"
    mv "$WORKDIR/queue.json.tmp" "$WORKDIR/queue.json"
    printf '%s' "$result" | jq -j '.md' > "$WORKDIR/tracker.md.tmp"
    mv "$WORKDIR/tracker.md.tmp" "$WORKDIR/tracker.md"
    summary="$(jq -c '{units: (.units | length), waits: ([.units[] | select(.waits)] | length), closures: (.closures | length), stale_claims: (.stale_claims | length)}' "$WORKDIR/queue.json")"
    log_event tracker_render "$summary"
    echo "tracker: $summary -> $WORKDIR/tracker.md"
    ;;

  publish)
    [ $# -eq 0 ] || die "publish takes no arguments" 2
    [ -f "$WORKDIR/tracker.md" ] && [ -f "$WORKDIR/queue.json" ] || die "nothing to publish; run tracker.sh render first" 2
    [ ! -f "$WORKDIR/tracker.json" ] || die "already published: $(jq -r '.url' "$WORKDIR/tracker.json")" 3
    title="$(jq -r '.title' "$WORKDIR/queue.json")"
    "$HERE/gh-write.sh" ensure-label "$TRACKER_LABEL"
    out="$("$HERE/gh-write.sh" issue-create --title "$title" --body-file "$WORKDIR/tracker.md")"
    if is_dry_run; then
      printf '%s\n' "$out"
      exit 0
    fi
    url="$(printf '%s\n' "$out" | grep -E '^https://' | tail -n 1 || true)"
    num="${url##*/}"
    is_number "$num" || die "the issue was created but its number could not be read from gh's output: $out" 1
    jq -n --argjson number "$num" --arg url "$url" --arg run "$run" --arg ts "$(now_utc)" \
      '{number: $number, url: $url, run: $run, published_at: $ts}' > "$WORKDIR/tracker.json.tmp"
    mv "$WORKDIR/tracker.json.tmp" "$WORKDIR/tracker.json"
    # Find the run by its tracker number later: <repo folder>/tracker-<n> -> this run.
    ln -sfn "$WORKDIR" "$(dirname "$WORKDIR")/tracker-$num" 2>/dev/null || true
    log_event tracker_published "$(jq -c '.' "$WORKDIR/tracker.json")"
    echo "$url"
    ;;

  parse)
    body_file=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --body-file) body_file="${2:-}"; shift 2 ;;
        *) die "unknown argument $1" 2 ;;
      esac
    done
    [ -f "$WORKDIR/queue.json" ] || die "no queue.json in $WORKDIR; this run has no rendered tracker" 2
    state="null"
    tmp=""
    if [ -z "$body_file" ]; then
      [ -f "$WORKDIR/tracker.json" ] || die "this run is not published; pass --body-file or run tracker.sh publish" 2
      num="$(jq -r '.number' "$WORKDIR/tracker.json")"
      tmp="$(mktemp)"
      trap 'rm -f "$tmp"' EXIT
      raw="$(gh issue view "$num" --repo "$REPO" --json body,state)" || die "could not read tracker #$num" 1
      printf '%s' "$raw" | jq -j '.body' > "$tmp"
      state="$(printf '%s' "$raw" | jq '.state')"
      body_file="$tmp"
    fi
    [ -f "$body_file" ] || die "no body file at $body_file" 2

    # shellcheck disable=SC2016
    parsed="$(jq -Rs --slurpfile q "$WORKDIR/queue.json" --argjson state "$state" '
      [ split("\n")[] | sub("\r$"; "") ] as $lines
      | $q[0] as $q
      | ( [ $lines[] | capture("^<!-- issue-drain:tracker v1 run=(?<r>[A-Za-z0-9._-]+) -->\\s*$").r ] | first ) as $marker
      | [ $lines[] | capture("^- \\[[xX]\\] (?<id>U[0-9]+) · ").id ] as $ticked
      | [ $lines[] | capture("^- (?<id>U[0-9]+) · ").id ] as $plain
      | [ $lines[] | capture("^- \\[[xX]\\] close #(?<n>[0-9]+)( |$)").n | tonumber ] as $close
      | [ $lines[] | capture("^- \\[[xX]\\] release #(?<n>[0-9]+)( |$)").n | tonumber ] as $release
      | [ $q.units[].id ] as $known
      | ( reduce ($ticked + $plain)[] as $id ([]; if index($id) != null then . else . + [ $id ] end) ) as $order
      | { run: $q.run, marker_run: $marker,
          stop: ( [ $lines[] | select(test("^\\s*STOP\\s*$")) ] | length > 0 ),
          units: [ $order[] | select(. as $id | $known | index($id) != null) ],
          approved_closures: [ $close[] | select(. as $n | [ $q.closures[].number ] | index($n) != null) ] | unique,
          release_claims: [ $release[] | select(. as $n | [ $q.stale_claims[].number ] | index($n) != null) ] | unique,
          tracker_state: $state,
          unknown: ( [ $order[] | select(. as $id | $known | index($id) == null) | "unit \(.)" ]
                   + [ $close[] | select(. as $n | [ $q.closures[].number ] | index($n) == null) | "close #\(.)" ]
                   + [ $release[] | select(. as $n | [ $q.stale_claims[].number ] | index($n) == null) | "release #\(.)" ] ) }' "$body_file")"

    marker_run="$(printf '%s' "$parsed" | jq -r '.marker_run // ""')"
    [ "$marker_run" = "$run" ] || die "that body is not the tracker for run $run (its marker line says '${marker_run:-nothing}'); refusing to read a queue from it" 2
    printf '%s\n' "$parsed" | jq -c 'del(.marker_run)'
    log_event tracker_parsed "$(printf '%s' "$parsed" | jq -c '{stop, units: (.units | length), approved_closures, release_claims, tracker_state, unknown}')"
    if [ "$(printf '%s' "$parsed" | jq '.unknown | length')" != "0" ]; then
      printf '%s' "$parsed" | jq -r '.unknown[] | "tracker.sh: the tracker asks for something this run never offered: " + .' >&2
      exit 1
    fi
    ;;

  *)
    die "unknown command '$cmd'" 2
    ;;
esac
