#!/usr/bin/env bash
# analyze_runlog.sh — read runlog.jsonl and emit a per-reviewer reliability
# report plus tuning suggestions. Read by:
#   - SKILL.md step 1.5 (pre-run check, --recent <n>) — surfaces warnings
#     when a reviewer's recent timeout rate or empty-output rate is high.
#   - /cross-review --self-check (--mode report) — full health snapshot,
#     written for humans to scan and humans/Claude to use as input to
#     editing reviewer_profiles.json.
#
# Never edits reviewer_profiles.json itself — surfaces suggestions only.
# The intentional manual-confirm step is the same pattern splitstream uses
# for its pre-flight table.
#
# Usage:
#   analyze_runlog.sh [--recent <n>] [--mode warn|report] [--quiet]
#
#   --recent <n>      window (default 20). Older entries ignored.
#   --mode warn       emit one-line warnings when a reviewer is degraded
#                     (timeout rate >30% OR empty-output rate >40% OR
#                     reliability <60% over the window). Default.
#   --mode report     emit the full report (reliability %, p50/p95 duration,
#                     timeout rate, empty rate, suggested timeout edits).
#   --quiet           silence informational lines; warnings/report still print.
#
# Reads only the structured Phase-2 entries (those with a `reviewers` field).
# Hand-curated legacy entries are silently skipped — they don't have the
# fields needed for telemetry math.

set -uo pipefail

recent=20
mode="warn"
quiet=0

need_val() {
  # set -u + missing flag value crashes with raw "$2: unbound variable" instead
  # of a usage hint. Check argc before consuming the next positional.
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
    --mode)   need_val --mode   "$#"; mode="$2";   shift 2 ;;
    --quiet)  quiet=1;     shift ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

if ! command -v jq >/dev/null 2>&1; then
  echo "analyze_runlog: jq required (brew install jq)" >&2
  exit 1
fi

skill_dir="$(cd "$(dirname "$0")/.." && pwd)"
runlog="${CROSS_REVIEW_RUNLOG:-$skill_dir/runlog.jsonl}"
profile_file="$skill_dir/references/reviewer_profiles.json"

if [[ ! -f "$runlog" ]]; then
  [[ "$quiet" -eq 0 ]] && echo "no runlog at $runlog" >&2
  exit 0
fi

# Filter to structured entries (have .reviewers), keep last $recent.
# Legacy hand-curated entries don't have .reviewers and are skipped.
structured=$(jq -c 'select(.reviewers != null)' "$runlog" 2>/dev/null | tail -n "$recent")
n_entries=$(printf '%s\n' "$structured" | grep -c '^.' || true)

if [[ "$n_entries" -eq 0 ]]; then
  [[ "$quiet" -eq 0 ]] && echo "analyze_runlog: no structured entries yet (need at least 1 Phase-2 run)" >&2
  exit 0
fi

# Per-reviewer aggregation.
# For each reviewer in {codex, antigravity, gemini-pro, kimi}, compute:
#   total: number of times the reviewer was attempted (status != "skipped")
#   ok: status == "ok"
#   timed_out: status == "timed_out"
#   empty: status == "empty" (ran rc=0 but produced 0 bytes)
#   failed: status == "failed"
#   fallback: status == "fallback" (primary lane died, OpenRouter rescue served
#     the review). Counted as SERVED for reliability -- a usable review came
#     back -- but warned on unconditionally, because the primary provider is
#     down and only this bucket says so.
#   p50_duration, p95_duration, current_timeout
analyze_reviewer() {
  local r="$1"
  printf '%s\n' "$structured" | jq -s --arg r "$r" '
    map(.reviewers[$r] // {status:"skipped"}) as $rs
    | ($rs | map(select(.status != "skipped"))) as $attempts
    | ($attempts | length) as $total
    | ($attempts | map(select(.status == "ok"))        | length) as $ok
    | ($attempts | map(select(.status == "timed_out")) | length) as $to
    | ($attempts | map(select(.status == "empty"))     | length) as $empty
    | ($attempts | map(select(.status == "failed"))    | length) as $failed
    | ($attempts | map(select(.status == "quota"))     | length) as $quota
    # `fallback` is a status this analyzer MUST know about explicitly. It is
    # emitted by append_runlog.sh when a first-party lane died and its
    # or_fallback rescue succeeded. Before this bucket existed the value
    # matched none of the arms above, so a rescued attempt landed in $total
    # and in no outcome bucket -- inflating every rate denominator with no
    # numerator, and reporting "nominal" for a reviewer whose own provider was
    # 100% dead. Fourth instance of producer-invents-a-value /
    # consumer-enumerates-the-old-set in this skill; see post_comment.sh.
    | ($attempts | map(select(.status == "fallback"))  | length) as $fallback
    # Sleep-suspect filter (2026-07-03): when the machine sleeps mid-run,
    # gtimeout/curl timers freeze but the wall-clock duration_s keeps counting,
    # so a sample can log far past its ENFORCED budget (codex: 1024s vs 300s,
    # rc=0). Such samples carry no signal about the reviewer — learning from
    # them made the analyzer suggest bumping every timeout. Anything >60s over
    # budget is suspect (TERM/KILL lag is ≤10s; curl fires at max-time exactly).
    # Budget 0/missing = legacy entry, kept.
    | ($attempts | map(select(((.timeout_budget_s // 0) == 0)
                              or ((.duration_s // 0) <= ((.timeout_budget_s // 0) + 60))))) as $clean
    | (($attempts | length) - ($clean | length)) as $suspect
    | ($clean | length) as $cn
    | ($clean | map(select(.status == "timed_out")) | length) as $clean_to
    | ($clean | map(.duration_s // 0) | sort) as $durs
    | ($durs | length) as $dn
    | (if $dn == 0 then 0 else $durs[($dn / 2 | floor)] end) as $p50
    | (if $dn == 0 then 0 else $durs[($dn * 0.95 | floor) | (if . >= $dn then $dn - 1 else . end)] end) as $p95
    | ($attempts | map(.timeout_budget_s // 0) | max // 0) as $cur_to
    | {
        reviewer: $r,
        total: $total,
        ok: $ok,
        timed_out: $to,
        empty: $empty,
        failed: $failed,
        quota: $quota,
        fallback: $fallback,
        sleep_suspect: $suspect,
        to_suspect: ($to - $clean_to),
        # Fallback counts as SERVED here: a usable review did come back, and
        # reliability drives timeout tuning and the leaderboard draw, neither of
        # which should punish a seat for the provider billing state. The
        # degradation is carried by the unconditional WARN below instead, where
        # it names the thing a human can actually fix.
        reliability: (if $total == 0 then null else ((($ok + $fallback) * 100) / $total | floor) end),
        timeout_rate: (if $total == 0 then null else (($to * 100) / $total | floor) end),
        clean_timeout_rate: (if $cn == 0 then null else (($clean_to * 100) / $cn | floor) end),
        empty_rate:   (if $total == 0 then null else (($empty * 100) / $total | floor) end),
        p50_duration_s: $p50,
        p95_duration_s: $p95,
        current_timeout_budget_s: $cur_to
      }
  '
}

# Reviewer fleet. antigravity + gemini-pro both ride the agy CLI (Gemini Flash
# and Pro laps respectively); codex, kimi, and the OpenRouter pool (glm,
# deepseek, mimo, minimax, qwen, devstral, laguna, kat, north, nemotron,
# spark, seed, grok) are independent providers.
# Keep in sync with run_reviewers.sh's dispatch and leaderboard.sh. Bash 3.2
# (macOS /bin/bash) has no associative arrays — use a parallel indexed array.
REVIEWERS=(codex antigravity gemini-pro kimi glm deepseek mimo minimax qwen devstral laguna kat north nemotron spark seed grok longcat inkling kimi27 kimi3)
reviewer_stats=()
for _r in "${REVIEWERS[@]}"; do
  reviewer_stats+=("$(analyze_reviewer "$_r")")
done

# ── round wall-clock, trailer, critical path (#91) ──────────────────────────
# round_wall_s / trailing_reviewer are additive fields append_runlog.sh may or
# may not have stamped (they depend on context.json / reviewer meta being
# present that pass). Entries missing either are simply excluded from these
# stats, same as legacy pre-Phase-2 entries are excluded from everything else
# in this script. Sleep-suspect rounds (`wall_over_budget: true` on the
# entry) are excluded from wall-clock stats, matching the existing
# sleep_suspect handling for per-reviewer duration stats above.
# A round is sleep-suspect when any reviewer row carries wall_over_budget --
# append_runlog.sh never stamps it at the entry top level (antigravity +
# codex, PR #117 review); a top-level flag is honoured too if one ever lands.
round_wall_stats=$(printf '%s\n' "$structured" | jq -s '
  def sleep_suspect: ((.wall_over_budget // false) == true)
    or ((.reviewers // {}) | to_entries | any(.value.wall_over_budget == true));
  map(select(.round_wall_s != null and (sleep_suspect | not))) as $clean
  | (map(select(.round_wall_s != null and sleep_suspect)) | length) as $suspect
  | ($clean | map(.round_wall_s) | sort) as $durs
  | ($durs | length) as $dn
  # percentiles need a sample: below 3 they are just the min/max in disguise
  | (if $dn < 3 then null else $durs[($dn / 2 | floor)] end) as $p50
  | (if $dn < 3 then null else $durs[($dn * 0.95 | floor) | (if . >= $dn then $dn - 1 else . end)] end) as $p95
  | ($clean | map(select(.trailing_reviewer.reviewer != null and .trailing_reviewer.duration_s != null))) as $trailed
  | (($trailed | map(.trailing_reviewer.duration_s) | add) // 0) as $trail_sum
  # same denominator population as the numerator (antigravity)
  | (($trailed | map(.round_wall_s) | add) // 0) as $wall_sum
  | (if $wall_sum == 0 then null else (($trail_sum * 100) / $wall_sum | floor) end) as $trail_share
  | ($trailed | reduce .[] as $e ({}; .[$e.trailing_reviewer.reviewer] += 1)) as $crit_path
  | { n_clean: $dn, sleep_suspect: $suspect,
      p50_round_wall_s: $p50, p95_round_wall_s: $p95,
      trailer_share_pct: $trail_share,
      critical_path: $crit_path }
')

# ── telemetry completeness (#89) ─────────────────────────────────────────────
# Computed as a jq filter (not a bash function) so the same program can be run
# against either the --recent window (report) or a fixed last-10 window
# (warn's threshold check) without duplicating the logic.
completeness_filter='
  length as $n
  | (map(select(.run_id != null and .run_id != "")) | length) as $run_id_n
  | (map(select(.roster_decision != null)) | length) as $rd_n
  | (map(select(((.reviewers // {}) | to_entries | any(.value.findings_total != null))))
     | length) as $find_n
  | ([.[] | (.reviewers // {}) | to_entries[] | .value | select(.status != "skipped")]) as $rows
  | ($rows | length) as $row_n
  | ($rows | map(select(.model != null)) | length) as $model_n
  | ($rows | map(select(.cost_usd != null)) | length) as $cost_n
  | ($rows | map(select(.context_access != null)) | length) as $ctx_n
  | { n_entries: $n,
      pct_run_id: (if $n == 0 then null else (($run_id_n * 100) / $n | floor) end),
      pct_findings: (if $n == 0 then null else (($find_n * 100) / $n | floor) end),
      pct_roster_decision: (if $n == 0 then null else (($rd_n * 100) / $n | floor) end),
      n_reviewer_rows: $row_n,
      pct_model: (if $row_n == 0 then null else (($model_n * 100) / $row_n | floor) end),
      pct_cost_usd: (if $row_n == 0 then null else (($cost_n * 100) / $row_n | floor) end),
      pct_context_access: (if $row_n == 0 then null else (($ctx_n * 100) / $row_n | floor) end)
    }
'
completeness=$(printf '%s\n' "$structured" | jq -s "$completeness_filter")

# Fixed last-10 window for the warn threshold, independent of --recent (the
# issue text pins the threshold to "the last 10", not the report window).
last10_structured=$(jq -c 'select(.reviewers != null)' "$runlog" 2>/dev/null | tail -n 10)
completeness10=$(printf '%s\n' "$last10_structured" | jq -s "$completeness_filter")

# roster draw audit (#103, analyze half): shell out to audit_roster.sh with
# the SAME window and the SAME resolved runlog path this script is already
# using, rather than letting it re-resolve $CROSS_REVIEW_RUNLOG independently
# (which would agree today but silently diverge if the two scripts' default
# precedence ever changes).
roster_audit_out() {
  local a="$(dirname "$0")/audit_roster.sh"
  if [[ -x "$a" ]]; then
    "$a" --recent "$recent" --runlog "$runlog" 2>&1
  else
    # stdout with the WARN prefix so warn mode captures and formats it
    echo "WARN roster audit unavailable: $a missing or not executable"
  fi
}

# Suggest timeout bump if p95 is within 10% of current budget OR timeout rate >20%.
# Both signals use the sleep-clean sample set: p50/p95 are already clean-only,
# and clean_timeout_rate excludes sleep-killed timeouts — a round the machine
# slept through must not drive tuning (see the sleep-suspect filter above).
suggest_timeout_bump() {
  local stats="$1"
  echo "$stats" | jq -r '
    if .total == 0 or .current_timeout_budget_s == 0 then empty
    elif .clean_timeout_rate == null then
      (if .sleep_suspect > 0 then
        "  NOTE: \(.reviewer): all \(.sleep_suspect) sample(s) in the window are sleep-suspect (wall clock overran the enforced budget) — no tuning signal; re-evaluate after clean rounds"
      else empty end)
    elif .clean_timeout_rate >= 20 then
      "  SUGGEST: bump \(.reviewer).timeout_s from \(.current_timeout_budget_s) → \(.current_timeout_budget_s + 200) (timeout rate \(.clean_timeout_rate)% over window, sleep-suspect samples excluded)"
    elif (.p95_duration_s * 10) >= (.current_timeout_budget_s * 9) then
      "  SUGGEST: bump \(.reviewer).timeout_s from \(.current_timeout_budget_s) → \(.current_timeout_budget_s + 100) (p95 \(.p95_duration_s)s within 10% of budget)"
    else empty end
  '
}

# Warning thresholds. Quota outranks the generic warnings: it has a specific
# remedy (wait for the reset / rely on the OpenRouter fallback), and its
# failures would otherwise masquerade as a reliability problem worth "tuning".
emit_warning() {
  local stats="$1"
  # NOTE: `.reviewer as $rv` is load-bearing. The old code wrote
  # `["codex",…] | index(.reviewer)` — after the pipe `.` is the array
  # literal, so jq crashed ("Cannot index array with string") for exactly the
  # reviewers degraded enough to reach that branch, and warn mode reported
  # "all reviewers nominal" over a 50%-timeout window (caught 2026-07-03).
  echo "$stats" | jq -r '
    .reviewer as $rv
    | (if (.to_suspect // 0) > 0 then
         " [\(.to_suspect) of \(.timed_out) timeouts are sleep-suspect — wall clock overran the enforced budget, machine likely slept mid-run; discount before tuning]"
       else "" end) as $sleep_note
    # The fallback WARN is deliberately placed ABOVE the `.total < 3` sample
    # guard and above every rate-based branch. It is not a statistical signal
    # to be confident about -- it is a report that a provider account is dead
    # RIGHT NOW, and the user asked to be warned every time, not once a rate
    # clears a threshold. Sample-gating it would reproduce the exact failure it
    # exists to prevent: run_reviewers.sh writes "THE PRIMARY PROVIDER NEEDS
    # ATTENTION" into the record at dispatch, and the pre-run health check --
    # the only surface anyone consults BEFORE spending the next round -- would
    # still answer "all reviewers nominal".
    | if (.fallback // 0) > 0 then
      "  WARN: \($rv) served \(.fallback) of last \(.total) runs through its OpenRouter FALLBACK — its own provider lane failed. THE PRIMARY PROVIDER NEEDS ATTENTION (billing/quota/auth); the rescue is a stopgap, not a healthy seat."
    elif .total < 3 then empty   # not enough data
    elif (.quota // 0) > 0 then
      "  WARN: \($rv) hit the shared Gemini Individual quota in \(.quota) of last \(.total) runs — not a timeout/auth issue; the lap drops out until the quota resets (ETA in the latest run agy.quota_exhausted / .agy.log). If the seat has or_fallback configured it is re-run over OpenRouter and recorded as status \"fallback\" (never \"ok\"); otherwise rotation covers the gap"
    # Gate the timeout WARN on the sleep-CLEAN rate, matching
    # suggest_timeout_bump: a window whose timeouts are all sleep-killed must
    # not demand action (minimax finding, PR #27 pass 1). When the raw rate is
    # high but the clean rate is not, emit an informational NOTE instead so
    # the degradation is visible without pretending it needs tuning.
    # (No apostrophes in these comments — they live inside a bash single-quoted
    # jq program and would terminate it.)
    elif (.clean_timeout_rate // 0) > 30 then
      (if (["codex","antigravity","gemini-pro","kimi","glm"] | index($rv)) != null
       then "  WARN: \($rv) timed out \(.clean_timeout_rate)% of last \(.total) runs (p95 \(.p95_duration_s)s, budget \(.current_timeout_budget_s)s) — consider --timeout-\($rv) \(.current_timeout_budget_s + 200)\($sleep_note)"
       # Only 5 reviewers have per-reviewer CLI flags; suggesting a nonexistent
       # --timeout-<r> made the next run exit 2 (fugu finding, PR #18 pass 1).
       else "  WARN: \($rv) timed out \(.clean_timeout_rate)% of last \(.total) runs (p95 \(.p95_duration_s)s, budget \(.current_timeout_budget_s)s) — bump its timeout_s in reviewer_profiles.json (or pass global --timeout for a one-off)\($sleep_note)"
       end)
    elif .timeout_rate > 30 and (.to_suspect // 0) > 0 then
      "  NOTE: \($rv) raw timeout rate \(.timeout_rate)% over last \(.total) runs is sleep-contaminated (clean rate \(.clean_timeout_rate // 0)%) — no tuning action; re-evaluate after clean rounds"
    elif .empty_rate > 40 then
      "  WARN: \($rv) empty-output rate \(.empty_rate)% over last \(.total) runs — not a timeout fix. Read failure_kind in meta.json before acting: quota_exhausted → wait for reset; headless_permission_denied → prompt-shape bug in this repo, the seat is healthy, do NOT retire it; empty_output → re-run `agy login`"
    elif .reliability != null and .reliability < 60 then
      "  WARN: \($rv) reliability \(.reliability)% over last \(.total) runs (ok=\(.ok), fallback=\(.fallback // 0), timeout=\(.timed_out), empty=\(.empty), failed=\(.failed), quota=\(.quota // 0))\($sleep_note)"
    else empty end
  '
}

# ── wrapper audit (#144) ─────────────────────────────────────────────────────
# Which wrapper checkout -- this SKILL's own repo, as worktree.sh start
# stamps it and append_runlog.sh copies it onto the entry -- did the
# reviewing over the window, and was it safe to trust: reachable from
# origin/master, and clean. A round launched from the shared symlinked
# install can be sitting on an unpushed branch with a bug master doesn't
# have; this is the surface that would have caught the 2026-08-27 incident
# that motivated #144.
#
# Never fetches: ancestry is checked against whatever origin/master this
# skill checkout already has on disk, same discipline the rest of this
# script follows for git state.
wrapper_entries=$(printf '%s\n' "$structured" | jq -c 'select((.wrapper_sha | type) == "string" and (.wrapper_sha | test("^[0-9a-f]{40}$|^[0-9a-f]{64}$")))')
wrapper_n=$(printf '%s\n' "$wrapper_entries" | grep -c '^.' || true)

wrapper_origin_master_known=0
if git -C "$skill_dir" rev-parse --verify --quiet 'origin/master^{commit}' >/dev/null 2>&1; then
  wrapper_origin_master_known=1
fi

wrapper_nonancestor_count=0
wrapper_nonancestor_last_sha7=""
wrapper_nonancestor_last_branch=""
wrapper_dirty_count=0
wrapper_dist_lines=""
if [[ "$wrapper_n" -gt 0 ]]; then
  # One jq pass for the whole window (not three forks per entry), and the sha
  # is validated before it reaches git: a malformed row ({"wrapper_sha":
  # "--all"}) must not become a git option or a phantom non-ancestor
  # (cross-review of #148).
  while IFS=$'\t' read -r w_sha w_branch w_dirty; do
    [[ "$w_sha" =~ ^[0-9a-f]{40}$|^[0-9a-f]{64}$ ]] || continue
    w_sha7="${w_sha:0:7}"
    wrapper_dist_lines="${wrapper_dist_lines}${wrapper_dist_lines:+$'\n'}${w_sha7} ${w_branch} ${w_dirty}"
    [[ "$w_dirty" == "true" ]] && wrapper_dirty_count=$((wrapper_dirty_count + 1))
    if [[ "$wrapper_origin_master_known" -eq 1 ]]; then
      if ! git -C "$skill_dir" merge-base --is-ancestor "$w_sha" origin/master 2>/dev/null; then
        wrapper_nonancestor_count=$((wrapper_nonancestor_count + 1))
        wrapper_nonancestor_last_sha7="$w_sha7"
        wrapper_nonancestor_last_branch="$w_branch"
      fi
    fi
  done < <(printf '%s\n' "$wrapper_entries" | jq -r '[(.wrapper_sha // ""), (.wrapper_branch // "?"), ((.wrapper_dirty // false) | tostring)] | @tsv')
fi

case "$mode" in
  warn)
    out=$(for stats in "${reviewer_stats[@]}"; do emit_warning "$stats"; done)
    # Telemetry completeness (#89): fires only below the 80% run_id threshold,
    # over the fixed last-10 window regardless of --recent.
    comp10_n=$(jq -r '.n_entries' <<<"$completeness10")
    comp10_run_id=$(jq -r '.pct_run_id' <<<"$completeness10")
    if [[ "$comp10_n" -gt 0 && "$comp10_run_id" != "null" && "$comp10_run_id" -lt 80 ]]; then
      out="${out}${out:+$'\n'}  WARN: telemetry completeness low — run_id present in only ${comp10_run_id}% of last $comp10_n runs (threshold 80%)"
    fi
    # Roster draw audit (#103): surface only its WARN lines here — the full
    # table belongs to --mode report.
    roster_warn=$(roster_audit_out | grep '^WARN ' || true)
    if [[ -n "$roster_warn" ]]; then
      out="${out}${out:+$'\n'}$(printf '%s\n' "$roster_warn" | sed 's/^/  /')"
    fi
    # Wrapper audit (#144): only fires when the window actually has
    # wrapper_sha data (older entries, or a caller not going through
    # worktree.sh, simply have none).
    if [[ "$wrapper_n" -gt 0 ]]; then
      if [[ "$wrapper_origin_master_known" -eq 1 && "$wrapper_nonancestor_count" -gt 0 ]]; then
        out="${out}${out:+$'\n'}  WARN: wrapper: $wrapper_nonancestor_count of last $wrapper_n rounds ran on a wrapper that is not an ancestor of origin/master ($wrapper_nonancestor_last_sha7, branch $wrapper_nonancestor_last_branch)"
      elif [[ "$wrapper_origin_master_known" -eq 0 && "$quiet" -eq 0 ]]; then
        echo "analyze_runlog: wrapper ancestry check skipped -- skill dir has no origin/master to compare against (never fetched)" >&2
      fi
      if [[ "$wrapper_dirty_count" -gt 0 ]]; then
        out="${out}${out:+$'\n'}  WARN: wrapper: $wrapper_dirty_count of last $wrapper_n rounds ran on a DIRTY wrapper"
      fi
    fi
    if [[ -n "$out" ]]; then
      echo "── cross-review pre-run check (last $n_entries runs) ──"
      echo "$out"
      echo "──"
    elif [[ "$quiet" -eq 0 ]]; then
      echo "cross-review pre-run check: all reviewers nominal over last $n_entries runs" >&2
    fi
    ;;
  report)
    echo "── cross-review reviewer health (last $n_entries runs) ──"
    for stats in "${reviewer_stats[@]}"; do
      echo "$stats" | jq -r '
        if .total == 0 then "  \(.reviewer): no data in window"
        else
          "  \(.reviewer): reliability=\(.reliability // "—")%  ok=\(.ok)/\(.total)  fallback=\(.fallback // 0)  timed_out=\(.timed_out)  empty=\(.empty)  failed=\(.failed)  quota=\(.quota // 0)  p50=\(.p50_duration_s)s  p95=\(.p95_duration_s)s  budget=\(.current_timeout_budget_s)s\(if (.sleep_suspect // 0) > 0 then "  sleep_suspect=\(.sleep_suspect)" else "" end)"
        end'
    done
    echo ""
    echo "── tuning suggestions ──"
    suggestions=$({
      for stats in "${reviewer_stats[@]}"; do suggest_timeout_bump "$stats"; done
      for stats in "${reviewer_stats[@]}"; do emit_warning "$stats"; done
    } | sort -u)
    if [[ -n "$suggestions" ]]; then
      echo "$suggestions"
      echo ""
      echo "Edit $profile_file to apply (or pass per-run flags via --timeout-<reviewer>)."
    else
      echo "  none — all reviewers within tolerance"
    fi
    echo "──"

    echo ""
    echo "── round wall-clock (last $n_entries runs) ──"
    jq -r '
      if .n_clean == 0 then
        "  no clean round_wall_s samples in window" + (if .sleep_suspect > 0 then " (\(.sleep_suspect) sleep-suspect excluded)" else "" end)
      elif .n_clean < 3 then
        "  n=\(.n_clean) clean sample(s) -- too few for percentiles  trailer_share=\(.trailer_share_pct // "—")%" +
        (if .sleep_suspect > 0 then "  (\(.sleep_suspect) sleep-suspect excluded)" else "" end)
      else
        "  n=\(.n_clean)  p50=\(.p50_round_wall_s)s  p95=\(.p95_round_wall_s)s  trailer_share=\(.trailer_share_pct // "—")%" +
        (if .sleep_suspect > 0 then "  (\(.sleep_suspect) sleep-suspect excluded)" else "" end)
      end' <<<"$round_wall_stats"
    echo "  critical path (times each seat was the trailer):"
    crit_lines=$(jq -r '.critical_path | to_entries | sort_by(-.value) | .[] | "    \(.key): \(.value)"' <<<"$round_wall_stats")
    if [[ -n "$crit_lines" ]]; then
      echo "$crit_lines"
    else
      echo "    none — no trailing_reviewer data in window"
    fi
    echo "──"

    echo ""
    echo "── telemetry completeness (last $n_entries runs) ──"
    jq -r '
      "  run_id=\(.pct_run_id // "—")%  findings=\(.pct_findings // "—")%  roster_decision=\(.pct_roster_decision // "—")%",
      "  reviewer rows (\(.n_reviewer_rows)): model=\(.pct_model // "—")%  cost_usd=\(.pct_cost_usd // "—")%  context_access=\(.pct_context_access // "—")%"
    ' <<<"$completeness"
    echo "──"

    echo ""
    echo "── wrapper audit (last $n_entries runs) ──"
    if [[ "$wrapper_n" -eq 0 ]]; then
      echo "  no wrapper_sha data in window"
    else
      echo "  distribution (sha7 → count):"
      printf '%s\n' "$wrapper_dist_lines" | awk '{print $1}' | sort | uniq -c | sort -rn \
        | awk '{printf "    %s → %s\n", $2, $1}'
      echo "  dirty: $wrapper_dirty_count of $wrapper_n"
      if [[ "$wrapper_origin_master_known" -eq 1 ]]; then
        echo "  non-ancestor-of-origin/master: $wrapper_nonancestor_count of $wrapper_n"
      else
        echo "  NOTE: ancestry check skipped -- skill dir has no origin/master to compare against (never fetched)"
      fi
    fi
    echo "──"

    echo ""
    roster_audit_out
    ;;
  *)
    echo "unknown mode: $mode (use warn|report)" >&2
    exit 2
    ;;
esac
