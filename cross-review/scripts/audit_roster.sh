#!/usr/bin/env bash
# audit_roster.sh — audit the reviewer roster DRAW against what select_roster.sh
# actually recorded (`roster_decision`, attached to every runlog entry by
# append_runlog.sh's --roster-decision flag).
#
# Why: roster_decision carries baselines/candidates/weights/seed/selected for
# every round, but nothing reads it back. The nemotron `draw_boost 0 → weight
# 1` bug (a seat effectively excluded from the draw while still burning a
# candidate slot) was only found by hand-counting draws across 40 rounds — see
# docs/investigation-reviewer-seat-audit.md. This script automates that count.
#
# For each candidate seat over the window:
#   draws            times roster_decision.selected included the seat
#   expected         Sigma over entries of the seat's INCLUSION PROBABILITY in
#                     that entry's draw -- select_roster.sh draws without
#                     replacement and renormalises after each pick, so this
#                     is exact for 1..3 picks per entry (the default is 2)
#                     and reported as n/a when an entry drew 4+ seats
#   ratio            draws / expected (n/a when expected is unavailable)
#   WARN over-drawn  ratio > 2   (only when the seat appeared as a candidate
#   WARN under-drawn ratio < 0.5  in >= 10 entries; below that: "n/a (n<10)")
#   last_drawn / days_since_drawn / rounds_since_drawn
#   WARN starved     weight > 0 in >= 10 entries and never drawn
#
# days_since_drawn is computed relative to the WINDOW'S newest entry ts (not
# wall-clock), so output is deterministic and testable offline.
#
# Entries without roster_decision (older runs, before this field existed) are
# skipped and counted separately -- never treated as a zero-weight draw for
# every seat, which would manufacture false starvation.
#
# Usage:
#   audit_roster.sh [--recent N] [--json] [--runlog PATH]
#     --recent N     last N raw runlog entries (default: all; 0 also means all)
#     --json         machine-readable output instead of the text report
#     --runlog PATH  override the runlog path (else $CROSS_REVIEW_RUNLOG, else
#                     the skill's own runlog.jsonl)
#
# Read-only. Exit 0 on a report (WARN lines start with "WARN "; this is a
# report, not a gate), 2 on invalid arguments, 1 on jq/runtime errors.
#
# NOT yet wired into analyze_runlog.sh --mode report or /cross-review
# --self-check -- deliberate for this change to avoid file collisions with
# concurrent work on analyze_runlog.sh; see the follow-up issue.

set -uo pipefail

recent=0
emit_json=0
runlog_override=""

need_val() {
  local flag="$1"
  local argc="$2"
  if [[ "$argc" -lt 2 ]]; then
    echo "missing value for $flag" >&2
    exit 2
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --recent) need_val --recent "$#"; recent="$2"; shift 2 ;;
    --json)   emit_json=1; shift ;;
    --runlog) need_val --runlog "$#"; runlog_override="$2"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

if [[ "$recent" != "0" && ! "$recent" =~ ^[1-9][0-9]*$ ]]; then
  echo "audit_roster: invalid --recent value: $recent (want a non-negative integer)" >&2
  exit 2
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "audit_roster: jq required (brew install jq)" >&2
  exit 1
fi

skill_dir="$(cd "$(dirname "$0")/.." && pwd)"
if [[ -n "$runlog_override" ]]; then
  runlog="$runlog_override"
else
  runlog="${CROSS_REVIEW_RUNLOG:-$skill_dir/runlog.jsonl}"
fi

if [[ ! -f "$runlog" ]]; then
  echo "no runlog at $runlog" >&2
  exit 0
fi

if [[ "$recent" -gt 0 ]]; then
  window="$(tail -n "$recent" "$runlog")"
else
  window="$(cat "$runlog")"
fi

n_window="$(printf '%s\n' "$window" | grep -c '^.' || true)"
if [[ "$n_window" -eq 0 ]]; then
  echo "audit_roster: empty runlog window" >&2
  exit 0
fi

# One jq program does the whole aggregation: newest ts, entries with/without
# roster_decision, per-seat draws/expected/last_drawn, and the
# policy_version distribution. fromdateiso8601 is jq-native (jq >=1.5) --
# no dependence on OS `date` flavor (macOS `date -j` vs GNU `date -d`).
result="$(printf '%s\n' "$window" | jq -c 'select(length > 0)' | jq -s '
  . as $all
  | (map(select(.roster_decision != null))) as $used
  | (map(select(.roster_decision == null)) | length) as $skipped
  # newest ts over the USED entries only: a trailing legacy row without
  # roster_decision must not inflate days_since_drawn (kat, PR #101 review).
  | ($used | map(.ts // empty)) as $used_ts
  | (if ($used_ts | length) == 0 then null else ($used_ts | map(fromdateiso8601) | max) end) as $newest_epoch

  # policy_version distribution over used entries.
  | ($used | reduce .[] as $e ({}; .[($e.roster_decision.policy_version // "missing")] += 1)) as $pv_dist

  # Flatten every candidate row across every used entry, annotated with the
  # entry index (file order == chronological order; second-resolution ts can
  # collide, so ordering never keys on ts) and that seat inclusion probability
  # for the entry, then grouped by reviewer.
  #
  # select_roster.sh draws WITHOUT replacement, renormalising after each pick,
  # so a seat expectation per entry is its inclusion probability, not
  # nsel * weight / total (which exceeds 1 for a dominant seat and over-warns
  # -- codex, PR #101 review). Exact sequential recursion over the remaining
  # candidates:  incl(i, R, k) = p_i(R) + sum_{j != i} p_j(R) * incl(i, R - j, k-1)
  # with p_i(R) = w_i / sum(w over R). O(n^k), so it is computed for k <= 3
  # (the default --extras is 2; large diffs use 3) and reported as null for
  # an entry that drew 4+ seats -- never a bound that can understate or
  # overstate (codex, pass 2: min(1, k*p) is not a bound either way).
  | ($used | to_entries | map(
      .key as $idx
      | .value as $e
      | ($e.roster_decision.candidates // []) as $cands
      | ($cands | map(.weight // 0)) as $w
      | ($cands | map(select(.selected == true)) | length) as $nsel
      | (if $nsel == 0 then ($w | map(0))
         elif $nsel > 3 then ($w | map(null))
         else
           # incl(target, remaining index list, k)
           def incl($t; $r; $k):
             ([ $r[] | $w[.] ] | add) as $sum
             | if $sum <= 0 then 0
               else ($w[$t] / $sum) as $pt
               | if $k <= 1 then $pt
                 else $pt + ([ $r[] | select(. != $t) | . as $j
                                | ($w[$j] / $sum) * incl($t; [ $r[] | select(. != $j) ]; $k - 1) ] | add // 0)
                 end
               end;
           ([range(0; $w | length)]) as $all_idx
           | ($all_idx | map(select($w[.] > 0))) as $live
           | $all_idx | map(. as $t | if $w[$t] > 0 then incl($t; $live; $nsel) else 0 end)
         end) as $incl
      | ($e.ts | fromdateiso8601) as $ets
      | range(0; $cands | length) as $i
      | $cands[$i] | {
          reviewer: .reviewer,
          weight: (.weight // 0),
          selected: (.selected // false),
          draw_boost: .draw_boost,
          ts: $e.ts,
          epoch: $ets,
          idx: $idx,
          share: $incl[$i]
        }
    )) as $rows

  | ($rows | group_by(.reviewer) | map({
      reviewer: .[0].reviewer,
      candidate_count: length,
      draws: (map(select(.selected == true)) | length),
      expected: (if (map(.share) | any(. == null)) then null else (map(.share) | add) end),
      last_drawn_epoch: (
        (map(select(.selected == true) | .epoch)) as $de
        | if ($de | length) == 0 then null else ($de | max) end
      ),
      last_drawn_ts: (
        (map(select(.selected == true))) as $ds
        | if ($ds | length) == 0 then null
          else ($ds | max_by(.idx) | .ts) end
      ),
      last_drawn_idx: (
        (map(select(.selected == true) | .idx)) as $di
        | if ($di | length) == 0 then null else ($di | max) end
      ),
      last_draw_boost: (max_by(.idx) | .draw_boost),
      any_weight_positive_count: (map(select(.weight > 0)) | length)
    })) as $seats

  | {
      entries_used: ($used | length),
      entries_skipped: $skipped,
      policy_version: $pv_dist,
      newest_ts: ($used | map(.ts) | if length == 0 then null else max end),
      seats: ($seats | map(
        . as $s
        | (if $s.expected != null and $s.expected > 0 then ($s.draws / $s.expected) else null end) as $ratio
        | (if $s.last_drawn_epoch == null or $newest_epoch == null then null
           else (($newest_epoch - $s.last_drawn_epoch) / 86400 | floor) end) as $days_since
        | (
            # rounds_since_drawn: entries-with-roster_decision strictly after
            # the seats last draw, by entry index (not ts -- same-second rows
            # were dropped); for a never-drawn seat, its total candidate
            # appearances in the window.
            if $s.last_drawn_idx == null then $s.candidate_count
            else (($used | length) - $s.last_drawn_idx - 1)
            end
          ) as $rounds_since
        | {
            reviewer: $s.reviewer,
            candidate_count: $s.candidate_count,
            draws: $s.draws,
            expected: (if $s.expected == null then null else (($s.expected * 10000 | round) / 10000) end),
            ratio: (if $ratio == null then null else (($ratio * 100 | round) / 100) end),
            last_drawn: $s.last_drawn_ts,
            days_since_drawn: $days_since,
            rounds_since_drawn: $rounds_since,
            any_weight_positive_count: $s.any_weight_positive_count,
            eligible_for_ratio_warn: ($s.candidate_count >= 10),
            starved: ($s.any_weight_positive_count >= 10 and $s.draws == 0),
            last_draw_boost: $s.last_draw_boost
          }
      ) | sort_by(.reviewer))
    }
')" || { echo "audit_roster: failed to aggregate runlog $runlog" >&2; exit 1; }

if [[ "$emit_json" -eq 1 ]]; then
  printf '%s\n' "$result"
  exit 0
fi

entries_used="$(printf '%s' "$result" | jq -r '.entries_used')"
entries_skipped="$(printf '%s' "$result" | jq -r '.entries_skipped')"

echo "── cross-review roster draw audit (window: $n_window raw entries) ──"
echo "entries: $entries_used (skipped $entries_skipped without roster_decision)"

pv_line="$(printf '%s' "$result" | jq -r '.policy_version | to_entries | map("\(.key)=\(.value)") | join(" ")')"
echo "policy_version: ${pv_line:-none}"
echo ""

printf '%-14s %6s %9s %8s %11s %-22s %-17s %-19s\n' \
  "seat" "draws" "expected" "ratio" "candidates" "last_drawn" "days_since_drawn" "rounds_since_drawn"

printf '%s' "$result" | jq -r '.seats[] |
  [
    .reviewer,
    (.draws | tostring),
    (.expected // "n/a" | tostring),
    (if .eligible_for_ratio_warn then (if .ratio == null then "n/a" else (.ratio | tostring) end) else "n/a (n<10)" end),
    (.candidate_count | tostring),
    (.last_drawn // "never"),
    (.days_since_drawn // "-" | tostring),
    (.rounds_since_drawn | tostring)
  ] | @tsv' | while IFS=$'\t' read -r reviewer draws expected ratio_disp cands last_drawn days rounds; do
    printf '%-14s %6s %9s %8s %11s %-22s %-17s %-19s\n' \
      "$reviewer" "$draws" "$expected" "$ratio_disp" "$cands" "$last_drawn" "$days" "$rounds"
  done

echo ""
# check_draw_boost (#104): annotate an over-drawn/under-drawn/starved WARN
# with the seat's most recently RECORDED draw_boost (from
# roster_decision.candidates -- the value actually used for the draw, not
# the profile file) when that value is < 0.25, so a nemotron-style
# draw_boost-stuck-at-0 bug is root-caused in one glance instead of
# hand-counting draws across dozens of rounds.
warn_lines="$(printf '%s' "$result" | jq -r '
  def boost_suffix: if .last_draw_boost != null and .last_draw_boost < 0.25
    then " — check draw_boost (last recorded \(.last_draw_boost))" else "" end;
  .seats[] |
  if .eligible_for_ratio_warn and .ratio != null and .ratio > 2 then
    "WARN \(.reviewer) over-drawn (ratio \(.ratio) > 2.0; drawn \(.draws)/\(.candidate_count) candidate rounds)\(boost_suffix)"
  elif .eligible_for_ratio_warn and .ratio != null and .ratio < 0.5 then
    "WARN \(.reviewer) under-drawn (ratio \(.ratio) < 0.5; drawn \(.draws)/\(.candidate_count) candidate rounds)\(boost_suffix)"
  else empty end
')"
starved_lines="$(printf '%s' "$result" | jq -r '
  def boost_suffix: if .last_draw_boost != null and .last_draw_boost < 0.25
    then " — check draw_boost (last recorded \(.last_draw_boost))" else "" end;
  .seats[] | select(.starved == true) |
  "WARN \(.reviewer) starved (weight > 0 in \(.any_weight_positive_count) of \(.candidate_count) candidate rounds, never drawn)\(boost_suffix)"
')"

all_warn="$(printf '%s\n%s\n' "$warn_lines" "$starved_lines" | sed '/^$/d')"
if [[ -n "$all_warn" ]]; then
  echo "$all_warn"
else
  echo "  none — all seats within tolerance"
fi
echo "──"

exit 0
