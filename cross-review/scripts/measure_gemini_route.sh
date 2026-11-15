#!/usr/bin/env bash
# measure_gemini_route.sh — is the gemini-pro ROUTER (Argon vs Hydrogen, and the
# level) picking sensibly? Compares routes from the runlog.
#
# WHY THIS EXISTS
#
# The routing table in references/reviewer_profiles.json (`gemini-pro.router`)
# shipped 2026-11-14 as a STARTING GUESS: Argon takes the deep first look and
# Hydrogen the cheaper confirmation passes, on nothing firmer than OpenRouter's
# catalog calling Argon the "flagship reasoning model" and Hydrogen the
# "high-efficiency workhorse". Whether that is right is empirical, and "check
# back in two weeks" kept in someone's head is not a mechanism. Same idea as
# measure_codex_effort.sh: re-runnable, reads the rows rounds already write, and
# prints the same comparison every time.
#
# WHAT IT READS
#
# `reviewers.gemini-pro` in each runlog row, which carries the route the router
# picked (`route`, e.g. argon:high), the rule that fired (`route_reason`), the
# `pass_context`, and the usual status / duration_s / findings_total. Rows with
# no `route` (pre-router runs, or a fallback lap) are not evidence about a
# route and are counted separately.
#
# WHAT IT WILL NOT TELL YOU
#
# Observational, not an experiment: the router assigns by pass and diff size, so
# routes are NOT comparable like-for-like — argon:high sees big first looks and
# hydrogen:medium sees pass-3 confirmations. Compare a route to itself over time,
# or hold pass fixed. findings/run and CLEAN% are proxies for quality, not
# quality. The numbers that are close to direct: timed-out runs and median
# latency (can the route finish inside its timeout budget at all?).
#
# Usage:
#   measure_gemini_route.sh [--since <YYYY-MM-DD>] [--runlog <path>] [--if-due]
#
#   --since   only rows on/after this date. Default: the router's go-live date.
#   --runlog  defaults to ~/.claude/skills/cross-review/runlog.jsonl
#   --if-due  silent before the review date (router.review_due in the profile,
#             else REVIEW_DUE below); banner + report after. SKILL.md step 1.5
#             calls it every round so the check arrives on its own.
#
# Exit: 0 report printed · 2 runlog or jq unavailable. Never gates on a result.

set -uo pipefail

ROUTER_LIVE="2026-11-14"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROFILE="${CROSS_REVIEW_PROFILES_FILE:-$SCRIPT_DIR/../references/reviewer_profiles.json}"

# Written out, not computed: `date -d` and `date -v` disagree across BSD/GNU.
# The profile's router.review_due wins when readable so the date lives next to
# the table it audits; this is the fallback. Overridable so tests can exercise
# the due path. Reviewed: (not yet).
REVIEW_DUE="${CROSS_REVIEW_ROUTE_REVIEW_DUE:-}"
if [[ -z "$REVIEW_DUE" ]] && command -v jq >/dev/null 2>&1 && [[ -f "$PROFILE" ]]; then
  REVIEW_DUE="$(jq -r '.["gemini-pro"].router.review_due // empty' "$PROFILE" 2>/dev/null)"
fi
REVIEW_DUE="${REVIEW_DUE:-2026-11-28}"

since="$ROUTER_LIVE"
if_due=0
runlog="${CROSS_REVIEW_RUNLOG:-$HOME/.claude/skills/cross-review/runlog.jsonl}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --since)  [[ $# -ge 2 ]] || { echo "--since needs a date" >&2; exit 2; }; since="$2"; shift 2 ;;
    --runlog) [[ $# -ge 2 ]] || { echo "--runlog needs a path" >&2; exit 2; }; runlog="$2"; shift 2 ;;
    --if-due) if_due=1; shift ;;
    -h|--help) sed -n '2,38p' "$0"; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

# ISO dates compare lexicographically.
if [[ "$if_due" == 1 && "$(date +%F)" < "$REVIEW_DUE" ]]; then exit 0; fi

if [[ ! -s "$runlog" ]] || ! command -v jq >/dev/null 2>&1; then
  [[ "$if_due" == 1 ]] && exit 0
  if ! command -v jq >/dev/null 2>&1
    then echo "measure_gemini_route: jq required (brew install jq)" >&2
    else echo "measure_gemini_route: no runlog at $runlog" >&2
  fi
  exit 2
fi

if [[ "$if_due" == 1 ]]; then
  cat <<BANNER
─────────────────────────────────────────────────────────────────────────────
 REVIEW DUE: the gemini-pro model/effort router (Argon vs Hydrogen, level by
 pass and diff size) went live $ROUTER_LIVE on a guess, and is now past
 $REVIEW_DUE. The table below is the check. Decide one of: keep the table,
 change a route in reviewer_profiles.json (gemini-pro.router), or add a
 route_timeout_s — then move router.review_due so this stops asking.
─────────────────────────────────────────────────────────────────────────────
BANNER
fi

# Row by row, so one torn row is counted and reported, never a parse error that
# takes the report (and under --if-due, the round in front of it) down.
jq -cR 'select(test("^\\s*$") | not)
        | ((fromjson? // null) as $r
           | if ($r | type) == "object" then $r else {__unparseable: true} end)' "$runlog" |
jq -rs --arg since "$since" '
  (map(select(.__unparseable == true)) | length) as $unparseable
  | map(select(.__unparseable != true))
  |
  def med($xs): ($xs | sort) as $s
    | if ($s | length) == 0 then null else $s[(($s | length) / 2 | floor)] end;

  map(select(.reviewers["gemini-pro"] != null and .ts != null and .ts >= $since)
      | {ts, verdict, g: .reviewers["gemini-pro"]})                      as $all
  | ($all | map(select(.g.route != null)))                               as $routed
  | ($all | length - ($routed | length))                                 as $unrouted
  | ($routed | map(.g.route) | unique)                                   as $routes
  | "gemini-pro router — runs since \($since)",
    "",
    "  routed runs: \($routed | length)      without a route (pre-router, skipped, fallback): \($unrouted)",
    (if $unparseable > 0
     then "  skipped \($unparseable) unparseable runlog row(s) — torn or partial appends."
     else empty end),
    "",
    "  route            |    n  | timed_out | median_s | findings/run | CLEAN%",
    "  -----------------+-------+-----------+----------+--------------+-------",
    ($routes[] as $r
      | ($routed | map(select(.g.route == $r))) as $rows
      | ($rows | length) as $n
      | ($rows | map(select(.g.status == "timed_out" or .g.timed_out == true)) | length) as $to
      | "  \($r | . + "                 " | .[0:16]) | \($n | tostring | "    \(.)" | .[-4:])\(if $n < 20 then "*" else " " end)| \($to * 100 / $n | floor | tostring | "         \(.)%" | .[-10:]) | \(med($rows | map(.g.duration_s // 0)) | tostring | "        \(.)" | .[-8:]) | \((($rows | map(.g.findings_total // 0) | add) * 100 / $n | floor) / 100 | tostring | "            \(.)" | .[-12:]) | \((($rows | map(select(.verdict == "CLEAN")) | length) * 100 / $n | floor) | tostring | "     \(.)%" | .[-6:])"),
    "",
    "  by rule that fired (route_reason, pass number stripped):",
    ($routed | group_by(.g.route_reason // "?" | sub("\\(.*$"; "")) | .[]
      | "    \(.[0].g.route_reason // "?" | sub("\\(.*$"; "") | . + "                    " | .[0:20]) \(length) run(s)"),
    "",
    "  timed_out    runs that hit their timeout budget. If argon:high or hydrogen:xhigh",
    "               times out on big diffs, add a route_timeout_s entry or demote it.",
    "  median_s     wall time; also moves with diff size, so hold pass fixed.",
    "  findings/run PROXY for review quality. Routes see different work (pass, diff",
    "               size), so do not rank them head to head; look at each over time.",
    "  CLEAN%       share of rounds whose verdict was CLEAN.",
    "  *            fewer than 20 runs — noise, not a signal.",
    "",
    (if ($routed | length) < 20
     then "  NOT ENOUGH DATA YET — fewer than 20 routed runs in total. Re-run later."
     else "  Observational, not an experiment: the router assigns routes by pass and\n  diff size, so the groups differ in more than the model."
     end)
'
rc=$?
if [[ $rc -ne 0 && "$if_due" == 1 ]]; then
  echo "measure_gemini_route: report failed (jq exit $rc); run it without --if-due to see why" >&2
  exit 0
fi
exit "$rc"
