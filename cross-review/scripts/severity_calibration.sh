#!/usr/bin/env bash
# severity_calibration.sh — per-seat severity calibration report from
# finding_events.jsonl (#95). `proposed` events carry `severity`, but until
# now nothing measured whether a seat's severity labels are trustworthy — a
# seat that labels everything Critical was rewarded for it in leaderboard.sh's
# value axis and never penalised for inflation. This is a READ-ONLY report,
# standalone from leaderboard.sh by deliberate design (see PR body): sibling
# work (#90/#92) is mid-flight on leaderboard.sh, and the optional
# calibration multiplier into the value axis is explicitly deferred to a
# follow-up, gated behind a min-sample threshold of its own. Wiring this
# report's numbers into `leaderboard.sh --mode report` is also a follow-up.
#
# Per reviewer (grouped by the `reviewer` field of `proposed` events — one
# finding proposed by several seats gets a row per seat):
#   proposed          count of proposed findings (after --recent-days filter)
#   severity_share    share of proposed findings at each of
#                     Critical/High/Medium/Low/Other (case-insensitive;
#                     anything else normalizes to "Other")
#   survival          per severity: kept / (kept + dropped), using only
#                     TERMINAL events (factcheck_kept/parent_verified_kept/
#                     fix_verified/human_accepted count as kept;
#                     factcheck_dropped/parent_verified_dropped/
#                     human_rejected/duplicate_merged count as dropped).
#                     Findings with no terminal event are `unresolved` and
#                     EXCLUDED from every survival denominator.
#   resolved          kept + dropped (proposed findings with a terminal event)
#   inflation         (share of Critical+High among RESOLVED) minus (share
#                     of Critical+High among KEPT); unresolved rows are
#                     excluded from both terms — an unadjudicated Critical
#                     is not evidence of inflation. A seat whose Critical/
#                     High labels don't hold up scores high here.
#   warn              true when inflation > 0.25 (strict) AND resolved >=
#                     --min-sample (default 10) — printed as a `WARN
#                     inflation: ...` line in table mode. The sample gate
#                     counts RESOLVED rows, so a pile of unresolved
#                     proposals cannot turn one bad adjudication into a WARN.
#
# All decimal fields (severity_share, survival, inflation) are formatted as
# fixed 2-decimal strings ("0.33", "1.00") rather than raw JSON numbers, so
# neither mode drops trailing zeros.
#
# Usage:
#   severity_calibration.sh [--events PATH] [--recent-days N]
#                            [--min-sample N] [--json]
#     --events PATH     events ledger to read (else $CROSS_REVIEW_FINDING_EVENTS,
#                        else <skill_dir>/finding_events.jsonl — same contract
#                        as leaderboard.sh / append_finding_event.sh)
#     --recent-days N   only count `proposed` events with ts within the last
#                        N days (terminal events are still joined regardless
#                        of their own ts, so recency filtering never turns a
#                        real terminal outcome into `unresolved`)
#     --min-sample N    minimum RESOLVED count (kept + dropped) before
#                        inflation can WARN (default 10)
#     --json            emit one JSON array (no WARN lines mixed in — see
#                        each row's `warn` field instead); default is a
#                        human-readable table with WARN lines
#
# Read-only: never writes to the events ledger. Exit 0 when the ledger is
# missing or empty (empty report); exit 1 if jq is missing or the ledger is
# unparseable; exit 2 on bad usage.

set -uo pipefail

events_arg=""
recent_days=""
min_sample=10
json_mode=false

need_val() {
  if [[ "$2" -lt 2 ]]; then
    echo "missing value for $1" >&2
    exit 2
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --events)      need_val "$1" "$#"; events_arg="$2";  shift 2 ;;
    --recent-days) need_val "$1" "$#"; recent_days="$2"; shift 2 ;;
    --min-sample)  need_val "$1" "$#"; min_sample="$2";  shift 2 ;;
    --json)        json_mode=true; shift ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

# Numeric flags are validated up front: an invalid --recent-days used to
# silently disable the filter and an invalid --min-sample surfaced as a jq
# failure that pipefail-without-errexit then swallowed into an empty report
# (codex + kimi, PR #102 review). --recent-days 0 is rejected too: a cutoff of
# "now" excludes everything.
if [[ -n "$recent_days" && ! "$recent_days" =~ ^[1-9][0-9]*$ ]]; then
  echo "severity_calibration: --recent-days requires a positive integer (got '$recent_days')" >&2
  exit 2
fi
if [[ ! "$min_sample" =~ ^[0-9]+$ ]]; then
  echo "severity_calibration: --min-sample requires a non-negative integer (got '$min_sample')" >&2
  exit 2
fi

command -v jq >/dev/null 2>&1 || { echo "severity_calibration: jq required" >&2; exit 1; }

skill_dir="$(cd "$(dirname "$0")/.." && pwd)"
# Same override contract as leaderboard.sh / append_finding_event.sh:
# CROSS_REVIEW_FINDING_EVENTS overrides the default ledger path; --events
# overrides both (used by the fixture tests).
events_file="${events_arg:-${CROSS_REVIEW_FINDING_EVENTS:-$skill_dir/finding_events.jsonl}}"

if [[ ! -f "$events_file" ]]; then
  echo "severity_calibration: no events file at $events_file" >&2
  if $json_mode; then printf '[]\n'; fi
  exit 0
fi

cutoff=""
if [[ -n "$recent_days" ]]; then
  if date -u -v-1d +%Y-%m-%dT%H:%M:%SZ >/dev/null 2>&1; then
    cutoff="$(date -u -v-"${recent_days}"d +%Y-%m-%dT%H:%M:%SZ)"
  else
    cutoff="$(date -u -d "-${recent_days} days" +%Y-%m-%dT%H:%M:%SZ)"
  fi
  if [[ -z "$cutoff" ]]; then
    echo "severity_calibration: could not compute the --recent-days cutoff" >&2
    exit 1
  fi
fi

report="$(jq -c -s --arg cutoff "$cutoff" --argjson min_sample "$min_sample" '
  def norm_sev:
    (.severity // "") | ascii_downcase |
    if   . == "critical" then "Critical"
    elif . == "high"     then "High"
    elif . == "medium"   then "Medium"
    elif . == "low"      then "Low"
    else "Other" end;

  # Fixed 2-decimal string formatter (jq numbers drop trailing zeros, so
  # 1.0 would otherwise render as "1" instead of "1.00"). null in, "n/a" out.
  def fmt2($x):
    if $x == null then "n/a"
    else
      (($x * 100) | round) as $ip
      | (if $ip < 0 then -$ip else $ip end) as $a
      | (if $ip < 0 then "-" else "" end) as $sign
      | ($sign + (($a / 100) | floor | tostring) + "." +
         (($a % 100) | tostring | if length == 1 then "0" + . else . end))
    end;

  (["factcheck_kept","parent_verified_kept","fix_verified","human_accepted"]) as $kept_names
  | (["factcheck_dropped","parent_verified_dropped","human_rejected","duplicate_merged"]) as $dropped_names
  | . as $all
  # One proposed row per (finding, run, reviewer): fingerprint_findings.sh
  # emits one proposed event per contributing reviewer, and a re-emitted
  # --emit-events pass must not double-count (grok, PR #102 review).
  | ($all
     | map(select(.event == "proposed"))
     | (if $cutoff != "" then map(select((.ts // "") >= $cutoff)) else . end)
     # keep the LAST duplicate in ledger order (unique_by sorts and keeps
     # the first, which would pick by key order rather than recency)
     # key is the JSON-encoded tuple, so a "::" inside any field cannot
     # collide two distinct tuples (codex, pass 3)
     | (reduce .[] as $e ({}; .[([$e.finding_id, $e.run_id, $e.reviewer] | tojson)] = $e) | [.[]])
     | map(. + {sev: norm_sev})) as $proposed
  # Terminal status: the LATEST terminal event in ledger order wins, so a
  # human_accepted appended after a factcheck_dropped reads as kept (codex +
  # deepseek, PR #102 review). The ledger is append-only, so file order is
  # event order.
  | (reduce ($all[] | select(.event as $e | ($kept_names + $dropped_names | index($e)) != null)) as $e
      ({}; .[([$e.finding_id, $e.run_id] | tojson)] =
             (if ($kept_names | index($e.event)) != null then "kept" else "dropped" end))) as $tmap
  | ($proposed
     | map(. + {status: ($tmap[([.finding_id, .run_id] | tojson)] // "unresolved")})) as $rows
  | (["Critical","High","Medium","Low","Other"]) as $sevs
  | ($rows
     | group_by(.reviewer)
     | map(
        .[0].reviewer as $reviewer
        | . as $items
        | ($items | length) as $proposed_n
        | ($sevs | reduce .[] as $s ({};
            . + {($s): ($items | map(select(.sev == $s)) | length)})) as $sev_counts
        | ($sevs | reduce .[] as $s ({};
            ($items | map(select(.sev == $s and .status == "kept")) | length) as $k
            | ($items | map(select(.sev == $s and .status == "dropped")) | length) as $d
            | . + {($s): {kept: $k, dropped: $d,
                          survival: (if ($k + $d) == 0 then null else ($k / ($k + $d)) end)}}
          )) as $sev_stats
        | ($items | map(select(.status == "unresolved")) | length) as $unresolved
        | ($items | map(select(.status == "kept")) | length) as $kept_total
        | ($items | map(select(.status == "dropped")) | length) as $dropped_total
        # Inflation is measured over RESOLVED rows only: an unresolved
        # Critical is not evidence of inflation, it is a finding nobody has
        # adjudicated yet, and ~86% of proposed findings on the live ledger
        # have no terminal event (grok, PR #102 review).
        | ($kept_total + $dropped_total) as $resolved_n
        | ($items | map(select(.status != "unresolved" and (.sev == "Critical" or .sev == "High")))
                   | length) as $ch_resolved
        | (if $resolved_n == 0 then 0 else ($ch_resolved / $resolved_n) end) as $ch_proposed_share
        | ($items | map(select(.status == "kept" and (.sev == "Critical" or .sev == "High")))
                   | length) as $ch_kept
        | (if $kept_total == 0 then 0 else ($ch_kept / $kept_total) end) as $ch_kept_share
        | (if $resolved_n == 0 then 0 else ($ch_proposed_share - $ch_kept_share) end) as $inflation
        | (($resolved_n > 0) and ($inflation > 0.25) and ($resolved_n >= $min_sample)) as $warn
        | { reviewer: $reviewer,
            proposed: $proposed_n,
            severity_share: ($sevs | reduce .[] as $s ({};
              . + {($s): (fmt2(if $proposed_n == 0 then null
                                else ($sev_counts[$s] / $proposed_n) end))})),
            survival: ($sevs | reduce .[] as $s ({};
              . + {($s): (fmt2($sev_stats[$s].survival))})),
            kept: $kept_total,
            dropped: $dropped_total,
            unresolved: $unresolved,
            resolved: $resolved_n,
            ch_resolved_share: $ch_proposed_share,
            ch_kept_share: $ch_kept_share,
            inflation: fmt2($inflation),
            inflation_raw: $inflation,
            warn: $warn }
      )
     | sort_by(-.proposed))
' "$events_file")" || { echo "severity_calibration: failed to build the report from $events_file" >&2; exit 1; }

if $json_mode; then
  printf '%s' "$report" | jq '.'
  exit 0
fi

echo "── severity calibration (per-seat) ──"
printf '%s' "$report" | jq -r '
  .[] |
  "  \(.reviewer)  proposed=\(.proposed)" +
  "  share: C=\(.severity_share.Critical) H=\(.severity_share.High) M=\(.severity_share.Medium) L=\(.severity_share.Low) O=\(.severity_share.Other)" +
  "  survival: C=\(.survival.Critical) H=\(.survival.High) M=\(.survival.Medium) L=\(.survival.Low) O=\(.survival.Other)" +
  "  kept=\(.kept) dropped=\(.dropped) unresolved=\(.unresolved)  inflation=\(.inflation)" +
  (if .warn then
    "\nWARN inflation: reviewer=\(.reviewer) inflation=\(.inflation) resolved=\(.resolved) proposed=\(.proposed) (threshold 0.25, min-sample \($min_sample) resolved)"
   else "" end)
' --argjson min_sample "$min_sample"
echo "──"
echo "  inflation = (share of Critical+High among resolved) - (share of Critical+High among kept); unresolved rows excluded"
echo "  survival excludes unresolved findings (no terminal event yet) from the denominator"
