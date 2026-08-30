#!/usr/bin/env bash
# measure_codex_effort.sh — did stepping codex's reasoning effort down on
# later passes actually buy anything, and did it cost anything?
#
# WHY THIS EXISTS AS A SCRIPT
#
# The effort ladder (SKILL.md, "Re-review loop") shipped 2026-08-29 on a
# projection, not a measurement: August's 1,426 review runs all inherited
# `model_reasoning_effort = "xhigh"` from ~/.codex/config.toml, 90 of them fell
# through to metered OpenRouter on `account_limit`, and repeat-pass cost is what
# took codex out of the fleet for five days on 2026-08-22. Whether `high` on
# pass 2 and `medium` on pass 3+ moves that is an empirical question, and
# "check back in a week" kept in someone's head is not a mechanism. This is the
# mechanism: re-runnable, reads the runlog the rounds already write, and prints
# the same comparison every time so two runs of it are comparable.
#
# WHAT IT WILL NOT TELL YOU
#
# This is observational, not an experiment — the before and after windows differ
# in more than the effort setting (different PRs, different diff sizes, a
# reviewer roster that rotates). Treat a difference as a prompt to look, not as
# an effect size. In particular:
#
#   - `findings/run` and the CLEAN rate are PROXIES for review quality, not
#     review quality. A drop in findings on pass 3+ is ambiguous on its own:
#     it is the intended outcome (less redundant re-confirmation) and the
#     feared one (the pass stopped looking) wearing the same clothes. If it
#     drops, read the actual pass-3 reports before concluding either way.
#   - `duration` is a proxy for effort spent, and it also moves with diff size.
#
# The one number here that is close to a direct measurement is the
# `account_limit` fallback rate: that is the quota wall the ladder exists to
# stop hitting.
#
# Usage:
#   measure_codex_effort.sh [--since <YYYY-MM-DD>] [--runlog <path>] [--if-due]
#
#   --since   the cutover — rows on/after it are "after", earlier ones
#             "before". Defaults to the ladder's ship date.
#   --runlog  defaults to ~/.claude/skills/cross-review/runlog.jsonl
#   --if-due  print nothing before the review date, the banner and the report
#             on or after it. This is the hook: SKILL.md step 1.5 calls it on
#             every round, so the week-later check arrives on its own instead
#             of depending on someone remembering. Silent in the common case,
#             like the rest of that step.
#
# Exit: 0 report printed · 2 the runlog or jq is unavailable.
#       It never exits non-zero on an unfavourable result — this reports, it
#       does not gate. Nothing here is an invariant that CI could hold.

set -uo pipefail

LADDER_SHIPPED="2026-08-29"
# A week of real rounds after the ship date. Written out rather than computed
# because `date -d` and `date -v` disagree across BSD and GNU, and a date this
# script gets wrong is a check that silently never fires.
# Overridable ONLY so the tests can exercise the due path — a check first
# exercised on the day it fires is a check nobody has ever seen work.
REVIEW_DUE="${CROSS_REVIEW_EFFORT_REVIEW_DUE:-2026-09-05}"

since="$LADDER_SHIPPED"
if_due=0
runlog="${CROSS_REVIEW_RUNLOG:-$HOME/.claude/skills/cross-review/runlog.jsonl}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --since)  [[ $# -ge 2 ]] || { echo "--since needs a date" >&2; exit 2; }; since="$2"; shift 2 ;;
    --runlog) [[ $# -ge 2 ]] || { echo "--runlog needs a path" >&2; exit 2; }; runlog="$2"; shift 2 ;;
    --if-due) if_due=1; shift ;;
    -h|--help) sed -n '2,55p' "$0"; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

# ISO dates compare lexicographically, so no date arithmetic is needed here
# either. Not yet due: say nothing and get out of the round's way.
if [[ "$if_due" == 1 && "$(date +%F)" < "$REVIEW_DUE" ]]; then exit 0; fi

# One precondition check, not two: an earlier `command -v jq || exit 2` here
# would fire before the --if-due escape below and turn a missing jq into a
# failure in front of every round.
if [[ ! -s "$runlog" ]] || ! command -v jq >/dev/null 2>&1; then
  # --if-due runs ahead of real rounds and must never be what stops one.
  [[ "$if_due" == 1 ]] && exit 0
  if ! command -v jq >/dev/null 2>&1
    then echo "measure_codex_effort: jq required (brew install jq)" >&2
    else echo "measure_codex_effort: no runlog at $runlog" >&2
  fi
  exit 2
fi

if [[ "$if_due" == 1 ]]; then
  cat <<BANNER
─────────────────────────────────────────────────────────────────────────────
 REVIEW DUE: the codex reasoning-effort ladder shipped $LADDER_SHIPPED on a
 projection, and it is now past $REVIEW_DUE. The numbers below are the check.
 Decide one of: keep it, move the pass-3+ floor, or revert — then update
 REVIEW_DUE in this script (or delete the --if-due call in SKILL.md step 1.5)
 so this stops asking.
─────────────────────────────────────────────────────────────────────────────
BANNER
fi

# ISO-8601 Z timestamps sort lexicographically, so a plain string compare is
# the whole date filter. Rows without a codex entry are not evidence either way.
jq -rs --arg since "$since" '
  def med($xs): ($xs | sort) as $s
    | if ($s | length) == 0 then null
      else $s[(($s | length) / 2 | floor)] end;

  def bucket($p): if $p >= 3 then "3+" else ($p | tostring) end;

  def stats($rows):
    ($rows | length) as $n
    | if $n == 0 then {n: 0} else
      ($rows | map(select(.c.fallback.reason == "account_limit")) | length) as $al
      | {
          n: $n,
          account_limit: $al,
          account_limit_pct: (($al * 100 / $n) | floor),
          median_duration_s: med($rows | map(.c.duration_s // 0)),
          findings_per_run: (($rows | map(.c.findings_total // 0) | add) * 100 / $n | floor / 100),
          clean_pct: ((($rows | map(select(.verdict == "CLEAN")) | length) * 100 / $n) | floor)
        }
      end;

  map(select(.reviewers.codex != null and .ts != null)
      | {ts, verdict, pass: (.pass // 1), c: .reviewers.codex}
      # A fallback row means the primary lane never ran, so its duration and
      # findings describe OpenRouter, not codex. Kept for the quota count,
      # excluded from the effort proxies below.
      | . + {fell_back: (.c.fallback.used == true)})                as $all
  | ($all | map(select(.ts < $since)))                              as $before
  | ($all | map(select(.ts >= $since)))                             as $after
  | {
      since: $since,
      before: {window: "runlog start .. \($since)", total: ($before | length)},
      after:  {window: "\($since) .. now",          total: ($after  | length)},
      by_pass: ( ["1","2","3+"] | map(. as $b | {
          key: $b,
          value: {
            before: stats($before | map(select(bucket(.pass) == $b))),
            after:  stats($after  | map(select(bucket(.pass) == $b)))
          }
        }) | from_entries )
    }
  |
  "codex reasoning-effort ladder — before/after \(.since)",
  "",
  "  before: \(.before.total) codex runs      after: \(.after.total) codex runs",
  "",
  (
  "  pass | window |    n  | acct_limit  | median_s | findings/run | CLEAN%",
  "  -----+--------+------+-------------+----------+--------------+-------",
    (.by_pass | to_entries[] | .key as $p | .value |
      ( ["before", .before], ["after", .after] )
      | . as [$w, $s]
      | if $s.n == 0
        then "  \($p | . + "    " | .[0:4]) | \($w | . + "      " | .[0:6]) |    0*|          — |        — |            — |      —"
        else "  \($p | . + "    " | .[0:4]) | \($w | . + "      " | .[0:6]) | \($s.n | tostring | "    \(.)" | .[-4:])\(if $s.n < 20 then "*" else " " end)| \($s.account_limit_pct | tostring | "          \(.)%" | .[-11:]) | \($s.median_duration_s | tostring | "        \(.)" | .[-8:]) | \($s.findings_per_run | tostring | "            \(.)" | .[-12:]) | \($s.clean_pct | tostring | "     \(.)%" | .[-6:])"
        end
    )
  ),
  "",
  "  acct_limit   % of codex runs that hit the quota wall and fell through to",
  "               metered OpenRouter. This is the number the ladder targets.",
  "  median_s     wall time per run. A PROXY for effort — also moves with diff size.",
  "  findings/run PROXY for review quality. On pass 3+ a drop is ambiguous: it is",
  "               both the intended effect (less redundant re-confirmation) and the",
  "               feared one (the pass stopped looking). Read the reports to tell.",
  "  CLEAN%       share of rounds that found nothing. Rising on pass 3+ alongside",
  "               falling findings/run is the shape to be suspicious of.",
  "",
  "  *            fewer than 20 runs in that cell — noise, not a signal. Read",
  "               nothing into a starred row; wait for it to fill.",
  "",
  (if ([.by_pass | to_entries[] | .value.after.n] | map(select(. >= 20)) | length) == 0
   then "  NO USABLE AFTER-DATA YET — every after cell is thin. Re-run this once a\n  week of real rounds has accumulated."
   else "  Observational, not an experiment: the windows differ in more than the\n  effort setting. Treat a difference as a reason to look, not as an effect size."
   end),
  "",
  "  CHECK THE CUTOVER BEFORE BELIEVING ANY OF THIS. --since must be the date",
  "  the ladder actually started running on the machine doing the reviews, not",
  "  the date the code was written. Any round that ran after the cutover but",
  "  before the change landed is a pre-ladder round wearing an after label, and",
  "  it will make the after rows look like whatever else was happening that day."
' "$runlog"
