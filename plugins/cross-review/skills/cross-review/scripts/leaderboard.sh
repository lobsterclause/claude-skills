#!/usr/bin/env bash
# leaderboard.sh — score every reviewer from runlog.jsonl telemetry and emit a
# ranked leaderboard. The score is what select_roster.sh uses to weight the
# rotation draw, and what humans read to decide who earns a permanent seat.
#
# Scoring (documented here, implemented once below — keep in sync):
#   reliability = ok / attempts                     (delivered a review at all)
#
#   EVENTS PATH (v2, preferred): when finding_events.jsonl has `proposed`
#   events for this reviewer joined (by run_id) to the runlog window, score
#   per-finding instead of per-aggregate-count:
#     sev_w    = Critical 5 / High 3 / Medium 2 / Low 1 (unknown 1)
#     credit   = 0 if factcheck_dropped, else tier * (0.5 if anchored
#                resolved=false else 1), where tier is:
#                  1.0  provider-solo (no OTHER provider in all_sources —
#                       same-provider corroboration, e.g. kimi+kimi3, is
#                       still one Moonshot vote → solo)
#                  0.85 multi-provider but no baseline (codex/kimi) aboard
#                  0.7  corroborated by a baseline
#     value    = sum(sev_w * credit) / sum(sev_w)
#     survival = 1 - sum(sev_w over dropped) / sum(sev_w)
#     score    = 100*(0.45*reliability + 0.35*value + 0.20*survival)
#   This is the unique-discovery credit + severity weighting the old formula
#   couldn't express: a solo-but-real Critical now outscores a pile of
#   corroborated Lows, and a disproven Critical hurts 5x more than a
#   disproven Low. Known trade-off: solo findings that fact-check can't
#   actively disprove keep full solo credit — watch ev_dropped/ev_solo per
#   reviewer before trusting a solo-heavy score. Partial mitigation
#   (2026-08-14): a reviewer whose OWN drop rate over this window exceeds
#   solo_discount_drop_rate_threshold (15%, min sample solo_discount_min_n)
#   has its 1.0 solo tier discounted to solo_discount_factor (0.7) for this
#   pass — see the constants and comment above score_reviewer().
#
#   COUNTS FALLBACK (v1): reviewers with no window events keep the old
#   aggregate-count formula:
#   signal      = convergent / findings             (cross-PROVIDER convergence
#                                                    is our best precision proxy
#                                                    absent ground truth)
#   noise       = dropped / findings                (findings the fact-check
#                                                    pass disproved from the diff)
#   with findings data:  score = 100*(0.45*reliability + 0.35*signal + 0.20*(1-noise))
#   telemetry-only:      score = 100*reliability*multiplier   (quality unknown →
#                                                    discount; multiplier starts
#                                                    at 0.75 for <=3 ok runs and
#                                                    decays 0.06/ok-run beyond
#                                                    that, floor 0.15 — a soft
#                                                    prior for UNDER-OBSERVED
#                                                    reviewers, not a permanent
#                                                    haven for reviewers that
#                                                    reliably return nothing;
#                                                    see 2026-08-03 kat pin below)
#   never attempted:     score = 50                        (rookie prior — optimistic
#                                                    init so new reviewers get drawn
#                                                    and earn real data)
#
# [pin: 2026-08-03 — kat had 9/9 ok runs, p50 4s, ZERO findings data ever and
# scored a flat 75 (reliability×0.75), ranking ABOVE kimi (score 65, 39 runs,
# 22 real findings). A reviewer that reliably returns nothing in 4 seconds
# must not outrank one that actually finds bugs — the flat discount only
# decays a reviewer once it's had a real chance to accumulate findings data
# and hasn't (see "telemetry-only" branch in score_reviewer below). Reviewers
# that WERE enriched (findings_total present, even 0) are not decayed by this
# path — they were actually reviewed and legitimately found nothing.]
#
# KNOWN LIMITATION (v1 counts fallback only): signal rewards agreeing with
# the crowd — a reviewer that uniquely finds real bugs scores low on signal
# until others corroborate. The events path above fixes this (provider-solo
# findings earn MORE credit, not less), but entries older than the events
# ledger — and any round run without --emit-events — still score on the
# counts fallback, where the caveat stands: don't tune a reviewer out of the
# fleet on signal alone, look at its actual findings first.
#
# The per-reviewer findings counts come from append_runlog.sh --findings
# (entries older than that feature have telemetry only — they score on the
# telemetry-only branch).
#
# Usage:
#   leaderboard.sh [--recent <n>] [--mode table|json|report] [--profiles PATH]
#     --recent <n>   window of structured runlog entries (default 40)
#     --mode table   human-ranked leaderboard (default)
#     --mode json    one JSON array, consumed by select_roster.sh
#     --mode report  table output plus a per-round fleet cost line (p50/p95
#                    $/round over the window) and a "severity calibration"
#                    section shelled out to severity_calibration.sh (#105)
#     --profiles PATH  override reviewer_profiles.json (fixture tests only,
#                    same contract as CROSS_REVIEW_RUNLOG)
#
# JSON fields per reviewer: reviewer, provider, attempts, ok, quota,
# reliability_pct, findings, convergent, dropped, latest_status, rookie, score,
# sleep_excluded (timed_out samples whose wall clock overran the enforced
# budget — machine slept mid-run; dropped from the attempt set, see below),
# plus the events-path fields: score_basis ("events" | "counts" | "telemetry"
# | "rookie"), ev_findings, ev_solo, ev_dropped, ev_unanchored (all 0 when
# the reviewer scored on a non-events basis).
#
# COST (#92): cost_usd is billed on OpenRouter seats only — first-party CLI
# lanes (codex, antigravity, gemini-pro, kimi) never report it. Each seat's
# reviewer_profiles.json entry may carry a `pricing: {prompt_per_m,
# completion_per_m}` (USD per million tokens). When an attempt has no billed
# cost_usd but does have tokens_prompt/tokens_completion and its seat has
# pricing, cost is ESTIMATED at scoring time as tokens x pricing; avg_cost_usd
# then blends billed and estimated dollars, and cost_estimated is true when
# ANY dollar figure in the window was estimated rather than billed. Seats
# with pricing: null, or attempts missing token counts, contribute nothing to
# the estimate (an unbilled, unestimable attempt is simply excluded from the
# average, same as today).
#
# cost_per_kept / cost_per_kept_ch: total window $ (billed + estimated) over
# this reviewer's KEPT findings (any/Critical-or-High) from
# finding_events.jsonl's terminal events (factcheck_kept/parent_verified_kept/
# fix_verified/human_accepted = kept; the *_dropped/human_rejected/
# duplicate_merged family = dropped; no terminal event = unresolved, excluded
# from the denominator the same way severity_calibration.sh excludes it).
# Formatted as a fixed 2-decimal string ("0.10"); a seat with zero kept
# findings in the window reports "—", not a divide-by-zero.
#
# tokens_per_diff_line: average (tokens_prompt + tokens_completion) / diff
# lines over structured runlog entries that stamped BOTH this seat's tokens
# and diff_size.lines for that round (append_runlog.sh --diff-lines); null
# when no entry in the window has both.
#
# The events ledger path defaults to finding_events.jsonl next to the runlog;
# CROSS_REVIEW_FINDING_EVENTS overrides it (fixture tests only, same contract
# as CROSS_REVIEW_RUNLOG).

set -uo pipefail

recent=40
mode="table"
profiles_arg=""

need_val() {
  if [[ "$2" -lt 2 ]]; then
    echo "missing value for $1" >&2
    exit 2
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --recent)   need_val "$1" "$#"; recent="$2";       shift 2 ;;
    --mode)     need_val "$1" "$#"; mode="$2";         shift 2 ;;
    --profiles) need_val "$1" "$#"; profiles_arg="$2"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

command -v jq >/dev/null 2>&1 || { echo "leaderboard: jq required" >&2; exit 1; }

skill_dir="$(cd "$(dirname "$0")/.." && pwd)"
# CROSS_REVIEW_RUNLOG override exists for the fixture tests (tests/run_tests.sh)
# — production callers never set it.
runlog="${CROSS_REVIEW_RUNLOG:-$skill_dir/runlog.jsonl}"
# --profiles override exists for the fixture tests (tests/test_leaderboard_cost.sh)
# — production callers never pass it.
profile_file="${profiles_arg:-$skill_dir/references/reviewer_profiles.json}"

# Full fleet — keep in sync with run_reviewers.sh dispatch and analyze_runlog.sh.
REVIEWERS=(codex antigravity gemini-pro kimi glm deepseek mimo minimax qwen devstral laguna kat north nemotron spark seed grok longcat inkling kimi27 kimi3)

structured=""
if [[ -f "$runlog" ]]; then
  structured=$(jq -c 'select(.reviewers != null)' "$runlog" 2>/dev/null | tail -n "$recent")
fi

# Events ledger, joined to the window by run_id. Entries older than the
# run_id field (or rounds run without --emit-events) simply contribute no
# events — their reviewers score on the counts fallback.
events_file="${CROSS_REVIEW_FINDING_EVENTS:-$skill_dir/finding_events.jsonl}"
window_run_ids="$(printf '%s\n' "$structured" | jq -c -s '[.[] | .run_id // empty] | unique' 2>/dev/null)"
window_events="[]"
if [[ -f "$events_file" && -n "$window_run_ids" && "$window_run_ids" != "[]" ]]; then
  window_events="$(jq -c -s --argjson rids "$window_run_ids" \
    '[.[] | select(.run_id as $x | $rids | index($x) != null)]' \
    "$events_file" 2>/dev/null)"
  [[ -n "$window_events" ]] || window_events="[]"
fi

# Baseline seats (codex/kimi unless the profile file says otherwise) — a
# finding corroborated by a baseline is the 0.7 credit tier.
baselines='["codex","kimi"]'
if [[ -f "$profile_file" ]]; then
  b="$(jq -c '[to_entries[] | select(.value | type == "object")
               | select(.value.baseline == true) | .key]' "$profile_file" 2>/dev/null)"
  [[ -n "$b" && "$b" != "[]" ]] && baselines="$b"
fi

# Precision discount (Goodhart's-law guard, 2026-08-14): factcheck_findings.sh
# is deliberately recall-safe — it can only DROP a finding the diff actively
# CONTRADICTS, and keeps anything it merely can't confirm. That lets a
# reviewer that over-reports speculative/low-confidence findings keep full
# 1.0 solo credit on most of them, while a careful reviewer reporting fewer,
# higher-confidence findings earns no precision reward. To close that gap,
# a reviewer whose OWN factcheck-drop rate over this same window exceeds the
# threshold below has its solo-credit tier discounted for this scoring pass
# (a low or zero drop rate leaves the discount at 1.0 — a no-op). Gated on a
# minimum sample size so a single unlucky drop on a thin sample can't trip
# the discount by chance; simple constants, not a curve, by design.
solo_discount_min_n=5
solo_discount_drop_rate_threshold=0.15
solo_discount_factor=0.7

# provider_of <reviewer> — profile `.provider` wins, else the built-in map.
provider_of() {
  local r="$1" p=""
  if [[ -f "$profile_file" ]]; then
    p="$(jq -r --arg r "$r" '.[$r].provider // empty' "$profile_file" 2>/dev/null)"
  fi
  if [[ -z "$p" ]]; then
    case "$r" in
      codex) p="openai" ;;
      antigravity|gemini-pro) p="google" ;;
      kimi) p="moonshot" ;;
      glm) p="zhipu" ;;
      deepseek) p="deepseek" ;;
      mimo) p="xiaomi" ;;
      minimax) p="minimax" ;;
      qwen) p="alibaba" ;;
      devstral) p="mistral" ;;
      laguna) p="poolside" ;;
      kat) p="kuaishou" ;;
      north) p="cohere" ;;
      nemotron) p="nvidia" ;;
      spark) p="meta" ;;
      seed) p="bytedance" ;;
      grok) p="xai" ;;
      longcat) p="meituan" ;;
      inkling) p="thinkingmachines" ;;
      kimi27) p="moonshot" ;;
      kimi3) p="moonshot" ;;
      *) p="unknown" ;;
    esac
  fi
  printf '%s' "$p"
}

# pricing_of <reviewer> — profile `.pricing` ({prompt_per_m, completion_per_m}
# in USD/million tokens) or `null` when the seat has none on file (#92).
pricing_of() {
  local r="$1"
  if [[ -f "$profile_file" ]]; then
    jq -c --arg r "$r" '.[$r].pricing // null' "$profile_file" 2>/dev/null || echo null
  else
    echo null
  fi
}

score_reviewer() {
  local r="$1" provider="$2" pricing="$3"
  printf '%s\n' "$structured" | jq -s --arg r "$r" --arg provider "$provider" \
    --argjson events "$window_events" --argjson provmap "$provmap" \
    --argjson baselines "$baselines" --argjson pricing "$pricing" \
    --argjson solo_discount_min_n "$solo_discount_min_n" \
    --argjson solo_discount_drop_rate_threshold "$solo_discount_drop_rate_threshold" \
    --argjson solo_discount_factor "$solo_discount_factor" '
    # Fixed 2-decimal string formatter for the cost-per-kept fields (jq
    # numbers drop trailing zeros, so 0.1 would otherwise render "0.1" not
    # "0.10"). null in ("no kept findings" / "no cost data") -> em dash out,
    # so a zero-kept seat reads as "not applicable", not a fake $0.00.
    def fmt2($x):
      if $x == null then "—"
      else
        (($x * 100) | round) as $ip
        | (if $ip < 0 then -$ip else $ip end) as $a
        | (if $ip < 0 then "-" else "" end) as $sign
        | ($sign + (($a / 100) | floor | tostring) + "." +
           (($a % 100) | tostring | if length == 1 then "0" + . else . end))
      end;
    map(.reviewers[$r] // {status:"skipped"}) as $rs
    # Sleep-killed timeouts (2026-07-03): a timed_out sample whose wall-clock
    # duration overran the ENFORCED budget by >60s means the machine slept
    # mid-run (gtimeout/curl timers freeze during system sleep) — it says
    # nothing about the provider and must not ding reliability. Excluded from
    # the attempt set entirely. ok-status over-budget runs are KEPT: they
    # delivered a review, and their durations feed the --fast speed signal.
    | ($rs | map(select((.status == "timed_out")
                        and ((.timeout_budget_s // 0) > 0)
                        and ((.duration_s // 0) > ((.timeout_budget_s // 0) + 60))))
           | length) as $sleep_excluded
    | ($rs | map(select(.status != "skipped"
                        and (((.status == "timed_out")
                              and ((.timeout_budget_s // 0) > 0)
                              and ((.duration_s // 0) > ((.timeout_budget_s // 0) + 60))) | not)))) as $attempts
    | ($attempts | length) as $n
    | ($attempts | map(select(.status == "ok"))    | length) as $ok
    | ($attempts | map(select(.status == "quota")) | length) as $quota
    | ($attempts | map(select(.findings_total != null))) as $scored
    | ($scored | map(.findings_total      // 0) | add // 0) as $findings
    | ($scored | map(.findings_convergent // 0) | add // 0) as $convergent
    | ($scored | map(.findings_dropped    // 0) | add // 0) as $dropped
    | (if $n == 0 then null else ($ok / $n) end) as $rel
    | (if $n == 0 then "never_run" else ($attempts | last | .status) end) as $latest
    # Cost (#92): billed cost_usd wins; absent that, ESTIMATE from
    # tokens_prompt/tokens_completion x this seats pricing (null pricing or
    # missing token counts contributes nothing — same as an unbilled attempt
    # today). cost_estimated is true when ANY dollar figure in the window
    # came from the estimate rather than a bill.
    | ($attempts | map(
        (if (.cost_usd | type) == "number" then .cost_usd else null end) as $billed
        | if $billed != null then {cost: $billed, estimated: false}
          elif ($pricing != null
                and (.tokens_prompt // null) != null
                and (.tokens_completion // null) != null) then
            { cost: ((.tokens_prompt / 1000000 * $pricing.prompt_per_m)
                     + (.tokens_completion / 1000000 * $pricing.completion_per_m)),
              estimated: true }
          else null end)
      | map(select(. != null))) as $cost_entries
    | ($cost_entries | map(.cost)) as $costs
    | (if ($costs | length) == 0 then 0
       else (($costs | add) / ($costs | length) * 1000000 | round) / 1000000 end) as $avg_cost
    | (($costs | add) // 0) as $total_cost
    | (($cost_entries | map(select(.estimated)) | length) > 0) as $cost_estimated
    | ($attempts | map(.duration_s // 0) | sort) as $durs
    | ($durs | length) as $dn
    | (if $dn == 0 then 0 else $durs[($dn / 2 | floor)] end) as $p50
    # tokens-per-diff-line (#92): average (tokens_prompt + tokens_completion)
    # / diff_size.lines over structured entries that stamped BOTH this seats
    # tokens and a diff line count for that round. `.` is still the full
    # runlog-entry array here (every binding above uses `as`, which never
    # reassigns the pipeline input).
    | (map(select((.reviewers[$r].tokens_prompt // null) != null
                  and (.reviewers[$r].tokens_completion // null) != null
                  and (.diff_size.lines // null) != null
                  and (.diff_size.lines // 0) > 0))
       | map((((.reviewers[$r].tokens_prompt // 0) + (.reviewers[$r].tokens_completion // 0))
              / .diff_size.lines))) as $tpl_samples
    | (if ($tpl_samples | length) == 0 then null
       else ((($tpl_samples | add) / ($tpl_samples | length) * 10 | round) / 10) end) as $tokens_per_diff_line
    # kept findings (#92): terminal status per (finding_id, run_id), same
    # kept/dropped event names severity_calibration.sh uses, joined onto this
    # reviewers proposed events. No terminal event = unresolved, excluded
    # from both the kept count and the kept-Critical-or-High count (an
    # unadjudicated finding is not yet "kept").
    | (["factcheck_kept","parent_verified_kept","fix_verified","human_accepted"]) as $kept_names
    | (["factcheck_dropped","parent_verified_dropped","human_rejected","duplicate_merged"]) as $term_dropped_names
    | ($events
       | map(select(.event as $e | ($kept_names + $term_dropped_names | index($e)) != null))
       | reduce .[] as $e ({}; .[([$e.finding_id, $e.run_id] | tojson)] =
           (if ($kept_names | index($e.event)) != null then "kept" else "dropped" end))) as $term_map
    | ($events | map(select(.event == "proposed" and .reviewer == $r))
               | unique_by([.finding_id, .run_id])
               | map(. + {kstatus: ($term_map[([.finding_id, .run_id] | tojson)] // "unresolved")})) as $props_terminal
    | ($props_terminal | map(select(.kstatus == "kept"))) as $kept_findings
    | ($kept_findings | length) as $kept_n
    | ($kept_findings | map(select(.severity == "Critical" or .severity == "High")) | length) as $kept_ch_n
    # no cost data at all (CLI lane, or unpriced seat with no billed cost) is
    # "—", never "$0.00" -- a free-looking seat is a lie (antigravity, #121)
    | (if ($costs | length) == 0 or $kept_n == 0 then fmt2(null) else fmt2($total_cost / $kept_n) end) as $cost_per_kept
    | (if ($costs | length) == 0 or $kept_ch_n == 0 then fmt2(null) else fmt2($total_cost / $kept_ch_n) end) as $cost_per_kept_ch
    # Telemetry-only multiplier: 0.75 is a soft prior for reviewers not yet
    # observed enough to score on findings quality. Left flat, it became a
    # permanent haven for reviewers that reliably return NOTHING — see the
    # 2026-08-03 kat pin at the top of this file. It decays 0.06 per ok run
    # beyond the first 3, floored at 0.15, so sustained findings-free
    # engagement (>=8 ok runs) drops the score below the rookie prior (50).
    # Only applies when NO attempt has ever been enriched ($scored empty) —
    # a reviewer that WAS enriched and genuinely found nothing
    # (findings_total: 0 recorded) was actually reviewed and is not decayed.
    | (if $ok > 3 then (0.75 - 0.06 * ($ok - 3)) else 0.75 end) as $telemetry_mult_raw
    | (if $telemetry_mult_raw < 0.15 then 0.15 else $telemetry_mult_raw end) as $telemetry_mult
    # ── events path (v2): per-finding severity + unique-discovery credit ──
    # unique_by guards against a re-emitted (finding_id, run_id) pair; distinct
    # passes of the same PR mint distinct run_ids and legitimately count twice.
    | ($events | map(select(.event == "proposed" and .reviewer == $r))
               | unique_by([.finding_id, .run_id])) as $props
    | ($events | map(select(.event == "factcheck_dropped")
                     | {fid: .finding_id, rid: .run_id})) as $drop_keys
    | ($events | map(select(.event == "anchored" and .resolved == false)
                     | {fid: .finding_id, rid: .run_id})) as $unanch_keys
    | ($provmap[$r] // "unknown") as $rprov
    # Own factcheck-drop rate for this reviewer over this window (same
    # $props / $drop_keys the events path already builds) — precision signal
    # for the solo-credit discount below. Below the minimum sample size,
    # treat as unproven (rate 0, no discount) rather than penalize a thin
    # sample.
    | ($props | length) as $own_n
    | ($props | map(select(.finding_id as $fid | .run_id as $rid
                            | ($drop_keys | any(.fid == $fid and .rid == $rid))))
              | length) as $own_dropped
    | (if $own_n < $solo_discount_min_n then 0
       else ($own_dropped / $own_n) end) as $own_drop_rate
    | (if $own_drop_rate > $solo_discount_drop_rate_threshold
       then $solo_discount_factor else 1.0 end) as $solo_discount
    | ($props | map(
        (if .severity == "Critical" then 5
         elif .severity == "High" then 3
         elif .severity == "Medium" then 2
         else 1 end) as $w
        | .finding_id as $fid | .run_id as $rid
        | ($drop_keys   | any(.fid == $fid and .rid == $rid)) as $is_dropped
        | ($unanch_keys | any(.fid == $fid and .rid == $rid)) as $is_unanch
        # null sources are legal upstream (score_findings.sh filters them the
        # same way; fingerprint may emit reviewer:null events) — filter before
        # indexing $provmap or jq dies with "Cannot index object with null".
        | ((.all_sources // []) | map(select(type == "string"))) as $srcs
        | ($srcs | map($provmap[.] // .) | unique) as $provs
        | (($provs - [$rprov]) | length == 0) as $is_solo
        | ($srcs | map(. as $s | $baselines | index($s) != null) | any) as $has_baseline
        | (if $is_solo then (1.0 * $solo_discount)
           elif $has_baseline then 0.7 else 0.85 end) as $tier
        | (if $is_dropped then 0
           else ($tier * (if $is_unanch then 0.5 else 1 end)) end) as $credit
        | {w: $w, credit: $credit, dropped: $is_dropped,
           solo: $is_solo, unanch: $is_unanch}
      )) as $evs
    | ($evs | length) as $ev_n
    | ($evs | map(.w) | add // 0) as $tw
    | ($evs | map(.w * .credit) | add // 0) as $cw
    | ($evs | map(select(.dropped) | .w) | add // 0) as $dw
    | ($evs | map(select(.solo))    | length) as $ev_solo
    | ($evs | map(select(.dropped)) | length) as $ev_dropped
    | ($evs | map(select(.unanch))  | length) as $ev_unanchored
    | (if $n == 0 then 50
       elif $ev_n > 0 then
         (100 * (0.45 * $rel
                 + 0.35 * ($cw / $tw)
                 + 0.20 * (1 - ($dw / $tw)))) | round
       elif $findings > 0 then
         (100 * (0.45 * $rel
                 + 0.35 * ($convergent / $findings)
                 + 0.20 * (1 - ($dropped / $findings)))) | round
       elif ($scored | length) == 0 then
         (100 * $rel * $telemetry_mult) | round
       else (100 * $rel * 0.75) | round
       end) as $score
    | (if $n == 0 then "rookie"
       elif $ev_n > 0 then "events"
       elif $findings > 0 then "counts"
       elif ($scored | length) == 0 then "telemetry"
       else "counts" end) as $basis
    | { reviewer: $r,
        provider: $provider,
        attempts: $n,
        ok: $ok,
        quota: $quota,
        reliability_pct: (if $rel == null then null else ($rel * 100 | round) end),
        findings: $findings,
        convergent: $convergent,
        dropped: $dropped,
        latest_status: $latest,
        p50_duration_s: $p50,
        avg_cost_usd: $avg_cost,
        sleep_excluded: $sleep_excluded,
        rookie: ($n == 0),
        score_basis: $basis,
        ev_findings: $ev_n,
        ev_solo: $ev_solo,
        ev_dropped: $ev_dropped,
        ev_unanchored: $ev_unanchored,
        cost_estimated: $cost_estimated,
        cost_per_kept: $cost_per_kept,
        cost_per_kept_ch: $cost_per_kept_ch,
        tokens_per_diff_line: $tokens_per_diff_line,
        score: $score }
  '
}

# reviewer -> provider map, passed into the jq scorer so all_sources can be
# collapsed to provider votes ("claude" is the parent session's own flag).
provmap='{"claude":"anthropic"}'
for r in "${REVIEWERS[@]}"; do
  provmap="$(jq -c --arg r "$r" --arg p "$(provider_of "$r")" '. + {($r): $p}' <<<"$provmap")"
done

rows=""
for r in "${REVIEWERS[@]}"; do
  row="$(score_reviewer "$r" "$(provider_of "$r")" "$(pricing_of "$r")")"
  rows="$rows$row"$'\n'
done

print_table() {
  echo "── cross-review leaderboard (window: last $recent structured runs) ──"
  printf '%s' "$rows" | jq -s -r '
    sort_by(-.score) | to_entries[] |
    "  #\(.key + 1)  \(.value.reviewer) [\(.value.provider)] — score \(.value.score)\(if .value.rookie then " (rookie prior)" else "" end)  ·  runs \(.value.ok)/\(.value.attempts)\(if .value.quota > 0 then " (quota ×\(.value.quota))" else "" end)\(if (.value.sleep_excluded // 0) > 0 then " (sleep-excl ×\(.value.sleep_excluded))" else "" end)\(if .value.score_basis == "events" then "  ·  ev: \(.value.ev_findings) findings, \(.value.ev_solo) solo, \(.value.ev_dropped) disproven\(if (.value.ev_unanchored // 0) > 0 then ", \(.value.ev_unanchored) unanchored" else "" end)" elif .value.findings > 0 then "  ·  findings \(.value.findings), convergent \(.value.convergent), disproven \(.value.dropped)" else "" end)  ·  p50 \(.value.p50_duration_s)s  ·  last: \(.value.latest_status)"
  '
  echo "──"
  echo "  score = 45% reliability + 35% finding value + 20% fact-check survival"
  echo "  (\"ev:\" rows score per-finding from finding_events.jsonl — severity-weighted,"
  echo "   solo discoveries 1.0 > no-baseline corroboration 0.85 > baseline-corroborated 0.7,"
  echo "   unanchored ×0.5, disproven 0 · rows without events use aggregate convergence counts"
  echo "   · telemetry-only, never enriched: reliability × decaying prior — 0.75 for <=3 ok"
  echo "   runs, -0.06/run beyond that, floor 0.15 · never-run reviewers: rookie prior 50)"
}

# print_cost_report — #92/#105: per-seat $/kept-finding, a fleet $/round line
# (p50/p95 over the window's structured runlog entries), and tokens-per-diff-
# line, then the severity-calibration section from severity_calibration.sh.
print_cost_report() {
  echo "── cost per kept finding (window: last $recent structured runs) ──"
  printf '%s' "$rows" | jq -s -r '
    sort_by(-.score) | .[] |
    "  \(.reviewer) [\(.provider)] — \(if .cost_estimated then "~" else "" end)avg $\(.avg_cost_usd)/run\(if .cost_estimated then " (estimated)" else "" end)  ·  $/kept \(.cost_per_kept)  ·  $/kept C-or-H \(.cost_per_kept_ch)  ·  tokens/diff-line \(.tokens_per_diff_line // "—")"
  '
  echo "──"

  # Fleet $/round: sum billed+estimated cost across every reviewer within
  # each structured runlog entry, then p50/p95 over those per-round totals.
  fleet_stats="$(printf '%s\n' "$structured" | jq -s --argjson pricing "$pricing_map" '
    map(
      (.reviewers // {}) as $revs
      | ($revs | to_entries | map(
          .value as $rv
          | ($pricing[.key] // null) as $pr
          | (if ($rv.cost_usd | type) == "number" then $rv.cost_usd else null end) as $billed
          | if $billed != null then $billed
            elif ($pr != null and ($rv.tokens_prompt // null) != null and ($rv.tokens_completion // null) != null) then
              (($rv.tokens_prompt / 1000000 * $pr.prompt_per_m) + ($rv.tokens_completion / 1000000 * $pr.completion_per_m))
            else 0 end
        ) | add // 0)
    ) as $round_totals
    | ($round_totals | sort) as $s
    | ($s | length) as $n
    | (if $n == 0 then 0 else $s[(($n - 1) * 0.5 | floor)] end) as $p50
    | (if $n == 0 then 0 else $s[(($n - 1) * 0.95 | floor)] end) as $p95
    | {rounds: $n, p50: (($p50 * 1000000 | round) / 1000000), p95: (($p95 * 1000000 | round) / 1000000)}
  ')"
  fleet_n="$(jq -r '.rounds' <<<"$fleet_stats")"
  fleet_p50="$(jq -r '.p50' <<<"$fleet_stats")"
  fleet_p95="$(jq -r '.p95' <<<"$fleet_stats")"
  echo "  fleet \$/round over $fleet_n round(s): p50 \$$fleet_p50  ·  p95 \$$fleet_p95"
  echo "──"
  echo

  sev_script="$skill_dir/scripts/severity_calibration.sh"
  if [[ -x "$sev_script" || -f "$sev_script" ]]; then
    bash "$sev_script" || true
  else
    echo "severity_calibration.sh not found next to leaderboard.sh — skipping severity calibration section" >&2
  fi
}

# reviewer -> pricing map, for the fleet $/round rollup in --mode report.
pricing_map='{}'
for r in "${REVIEWERS[@]}"; do
  pricing_map="$(jq -c --arg r "$r" --argjson p "$(pricing_of "$r")" '. + {($r): $p}' <<<"$pricing_map")"
done

case "$mode" in
  json)
    printf '%s' "$rows" | jq -s 'sort_by(-.score)'
    ;;
  table)
    print_table
    ;;
  report)
    print_table
    echo
    print_cost_report
    ;;
  *)
    echo "unknown mode: $mode (use table|json|report)" >&2
    exit 2
    ;;
esac
