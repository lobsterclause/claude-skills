#!/usr/bin/env bash
# append_runlog.sh — emit a single structured JSONL entry summarizing a
# cross-review pass to ~/.claude/skills/cross-review/runlog.jsonl.
#
# Called from SKILL.md step 9.5 (after the report-back block, before worktree
# teardown). The SKILL flow already knows the verdict, top finding, and pass
# number — the wrapper-produced meta.json files supply per-reviewer telemetry.
#
# Usage:
#   append_runlog.sh \
#     --run-dir <path>             # produced by worktree.sh start; contains
#                                  # codex.meta.json, antigravity.meta.json,
#                                  # gemini-pro.meta.json, kimi.meta.json, etc.
#     --project <name>
#     --base <branch>
#     --pr <number|->              # use - for no PR (branch-only run)
#     --pass <n>
#     --verdict <CLEAN|FIXES_APPLIED|NEEDS_DECISION|BLOCKED>
#     --convergent <n>
#     --top "<file:line — title [severity][sources]>"
#     [--diff-files <n>]
#     [--diff-lines <n>]
#     [--notes "<one-liner>"]
#     [--findings <findings.verified.json>]
#       When given, each reviewer entry is enriched with findings_total /
#       findings_convergent / findings_dropped, computed from the findings'
#       `sources` arrays and `factcheck` verdicts. "Convergent" = the finding's
#       sources span MORE THAN ONE provider (per the provider map below) — the
#       cross-provider precision proxy leaderboard.sh scores on. Pass the most
#       verified findings file you have (post-anchor, post-factcheck).
#     [--run-id <id>]
#       Joins this runlog entry to any finding_events.jsonl events from the
#       same pass (run_id = basename of the run-dir; see worktree.sh). Omit
#       and the entry has no `run_id` key at all — not even null — so old
#       tooling reading past entries sees nothing new.
#     [--roster-decision <json-file>]
#       select_roster.sh --json output for this pass's draw, attached
#       verbatim as `roster_decision`. Never blocks the append: a
#       missing/unreadable file just warns to stderr and omits the key.
#     [--phases <json-file>]
#       Object of `<name>_s` phase-duration numbers (e.g. worktree_s,
#       dispatch_s, anchor_s, factcheck_s, synthesis_s, fix_s, post_s),
#       attached verbatim as `phases`. Any phase the flow skipped is simply
#       absent from the object — this script never fills in a 0. Fail-open
#       like --roster-decision: a missing/unreadable file warns to stderr
#       and omits the key.
#     [--synthetic]
#       Stamps `"synthetic": true` on this runlog entry (#116) — a planted-
#       mutation drill (plant_mutation.sh / grade_planted.sh), not a real
#       review round. leaderboard.sh excludes synthetic rows entirely from
#       production scoring (score, reliability, value, draw weight, epochs/
#       context-mode tables) and scores their recall separately. Independent
#       of this flag: if --run-id names a run_id that has a `planted` event
#       in finding_events.jsonl, this script auto-stamps synthetic: true
#       anyway and WARNs on stderr — a forgotten --synthetic flag can never
#       leak a planted round into production scoring.
#
# round_wall_s and trailing_reviewer need no flag — they are derived:
#   round_wall_s      now minus `$run_dir/context.json`'s `started_at`, both
#                     on the UTC clock (#118 — the LOCAL-clock pairing this
#                     replaces skewed the delta by the runner's TZ offset
#                     whenever "now" and `started_at` were computed on
#                     different clocks; UTC at the source removes the class
#                     rather than trying to keep two clocks in lockstep).
#                     It measures from THIS run_dir's worktree start: per pass
#                     when each pass starts its own worktree (the documented
#                     flow), or cumulative if a caller reuses one run_dir
#                     across passes. Omitted unless it parses to 0..604800
#                     seconds, and only computed when context.json and its
#                     `started_at` field both exist (worktree.sh start's own
#                     UTC "%Y%m%dT%H%M%S" stamp).
#   trailing_reviewer {reviewer, duration_s} of whichever reviewer meta
#                     carried the largest `duration_s` this pass — the seat
#                     that gated dispatch. Omitted when no reviewer meta has
#                     a duration_s.
#
# --run-id, --findings, and --roster-decision are never required — omitting
# any of them warns to stderr (telemetry gap) but never blocks the append.
#
# All of --run-id / --roster-decision / --phases / round_wall_s /
# trailing_reviewer are purely additive telemetry — leave them all off (and
# skip context.json / reviewer durations) and this entry is byte-identical to
# what today's callers already produce. Neither is read by leaderboard.sh or
# select_roster.sh yet.
# Schema is documented in plans/the-miss-on-pr-eager-pond.md (Phase 2).
# Additive — old hand-curated entries in the runlog remain valid.

set -uo pipefail

# Ledger schema version stamped on every entry this script writes (#96).
# Readers that don't know about this field treat its absence as 0 — bump this
# only alongside a documented, additive schema change.
SCHEMA_VERSION=1

run_dir=""
project=""
base=""
pr=""
pass=""
verdict=""
convergent="0"
top=""
diff_files=""
diff_lines=""
notes=""
findings_file=""
run_id=""
roster_decision_file=""
phases_file=""
profiles_arg=""
synthetic=0

need_val() {
  if [[ "$2" -lt 2 ]]; then
    echo "missing value for $1" >&2
    exit 2
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --run-dir)    need_val "$1" "$#"; run_dir="$2";    shift 2 ;;
    --project)    need_val "$1" "$#"; project="$2";    shift 2 ;;
    --base)       need_val "$1" "$#"; base="$2";       shift 2 ;;
    --pr)         need_val "$1" "$#"; pr="$2";         shift 2 ;;
    --pass)       need_val "$1" "$#"; pass="$2";       shift 2 ;;
    --verdict)    need_val "$1" "$#"; verdict="$2";    shift 2 ;;
    --convergent) need_val "$1" "$#"; convergent="$2"; shift 2 ;;
    --top)        need_val "$1" "$#"; top="$2";        shift 2 ;;
    --diff-files) need_val "$1" "$#"; diff_files="$2"; shift 2 ;;
    --diff-lines) need_val "$1" "$#"; diff_lines="$2"; shift 2 ;;
    --notes)      need_val "$1" "$#"; notes="$2";      shift 2 ;;
    --findings)   need_val "$1" "$#"; findings_file="$2"; shift 2 ;;
    --run-id)     need_val "$1" "$#"; run_id="$2";     shift 2 ;;
    --roster-decision) need_val "$1" "$#"; roster_decision_file="$2"; shift 2 ;;
    --phases)     need_val "$1" "$#"; phases_file="$2";     shift 2 ;;
    --profiles)   need_val "$1" "$#"; profiles_arg="$2";    shift 2 ;;
    --synthetic)  synthetic=1;                               shift ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

for required in run_dir project base pr pass verdict; do
  if [[ -z "${!required}" ]]; then
    echo "usage: $0 --run-dir <p> --project <n> --base <b> --pr <num|-> --pass <n> --verdict <v> [--convergent <n>] [--top <s>] [--diff-files <n>] [--diff-lines <n>] [--notes <s>] [--findings <json>] [--run-id <id>] [--roster-decision <json>] [--phases <json>] [--profiles <path>] [--synthetic]" >&2
    exit 2
  fi
done

if ! command -v jq >/dev/null 2>&1; then
  echo "append_runlog: jq required (brew install jq)" >&2
  exit 1
fi

# --profiles override exists for the fixture tests (same contract as
# leaderboard.sh --profiles / CROSS_REVIEW_RUNLOG) — production callers never
# pass it. Default is this skill's own reviewer_profiles.json, read through
# the same path leaderboard.sh --profiles uses.
skill_dir="$(cd "$(dirname "$0")/.." && pwd)"
profiles_file="${profiles_arg:-$skill_dir/references/reviewer_profiles.json}"

# Portable SHA-1 for profile_hash (#90) — same fallback chain as
# fingerprint_findings.sh: shasum (macOS stock), sha1sum (most Linux),
# openssl (either). No sha1 tool -> profile_hash is simply omitted from
# every row rather than blocking the append (fail-open, like the other
# additive telemetry in this script).
if command -v shasum >/dev/null 2>&1; then
  sha1_of() { shasum -a 1 | awk '{print $1}'; }
elif command -v sha1sum >/dev/null 2>&1; then
  sha1_of() { sha1sum | awk '{print $1}'; }
elif command -v openssl >/dev/null 2>&1; then
  sha1_of() { openssl dgst -sha1 -r | awk '{print $1}'; }
fi

# Telemetry-completeness warnings (#89): never block the append, just say
# what this pass is missing so a human scanning stderr — or
# analyze_runlog.sh's completeness block — sees the gap immediately rather
# than discovering it later as a silently-empty column in the report.
[[ -z "$run_id" ]] && echo "append_runlog: --run-id not provided; this entry will have no run_id (can't be joined to finding_events.jsonl)" >&2
[[ -z "$findings_file" ]] && echo "append_runlog: --findings not provided; reviewer entries will have no findings enrichment this pass" >&2
[[ -z "$roster_decision_file" ]] && echo "append_runlog: --roster-decision not provided; this entry will have no roster_decision" >&2

# Synthetic-round fail-closed check (#116): independent of --synthetic, if
# this run_id already has a `planted` event in finding_events.jsonl, this
# entry is a planted-mutation drill whether or not the caller remembered the
# flag. Auto-stamp and WARN rather than silently letting a forgotten flag
# leak a synthetic round into production scoring (leaderboard.sh also
# checks this independently, as a second line of defense).
events_ledger="${CROSS_REVIEW_FINDING_EVENTS:-$skill_dir/finding_events.jsonl}"
if [[ "$synthetic" -eq 0 && -n "$run_id" && -f "$events_ledger" ]]; then
  if has_planted="$(jq -r --arg rid "$run_id" 'select(.event == "planted" and .run_id == $rid)' "$events_ledger" 2>/dev/null | head -n 1)" \
     && [[ -n "$has_planted" ]]; then
    synthetic=1
    echo "WARN: run_id $run_id has planted events — recorded as synthetic" >&2
  fi
fi

# Evidence gate (binding, not advisory): a finding dropped at triage MUST
# carry its falsification evidence in factcheck.reason — the smoke test run,
# the call-site citation, the man-page semantics. A reasonless drop is how a
# real finding dies silently and how the leaderboard's survival signal rots.
# This rejects the append outright rather than trusting the orchestrator to
# remember the discipline (see feedback_convergent_not_correct: claims get
# falsified AND confirmed by 5-second smoke tests — record which happened).
if [[ -n "$findings_file" && -f "$findings_file" ]]; then
  # Fail-closed on BOTH lanes (codex+deepseek convergent P2, PR #25 pass 1):
  # a non-string reason (malformed LLM output: object/array) counts as
  # reasonless rather than crashing gsub, and a jq failure (malformed JSON)
  # rejects the append instead of silently bypassing the gate.
  if ! reasonless="$(jq -r '[(.findings // [])[]
      | select((.factcheck.verdict // "") == "drop")
      | select(((.factcheck.reason // "")
          | if type == "string" then gsub("\\s"; "") else "" end) == "")
      | (.id // .file // "?")] | join(", ")' "$findings_file" 2>/dev/null)"; then
    # Diagnostic from a separate jq syntax check — mixing stderr into the
    # capture could false-trip the gate on benign warnings (deepseek,
    # PR #25 pass 2).
    echo "append_runlog: could not validate --findings file: $(jq -e . "$findings_file" 2>&1 >/dev/null | head -2)" >&2
    exit 2
  fi
  if [[ -n "$reasonless" ]]; then
    echo "append_runlog: dropped finding(s) without recorded evidence: $reasonless" >&2
    echo "  record WHY each was falsified in factcheck.reason (smoke test output, call-site citation), then re-run" >&2
    exit 2
  fi
fi

# --roster-decision is fail-open (unlike the evidence gate above): losing
# roster telemetry must never block a runlog append. Invalid/missing file ->
# warn and proceed with the key omitted entirely.
roster_decision_json="null"
if [[ -n "$roster_decision_file" ]]; then
  if [[ -f "$roster_decision_file" ]] && rd="$(jq -c . "$roster_decision_file" 2>/dev/null)"; then
    roster_decision_json="$rd"
  else
    echo "append_runlog: --roster-decision file unreadable or invalid JSON: $roster_decision_file (omitting roster_decision)" >&2
  fi
fi

# CROSS_REVIEW_RUNLOG override exists for the fixture tests — production
# callers never set it.
runlog="${CROSS_REVIEW_RUNLOG:-$(cd "$(dirname "$0")/.." && pwd)/runlog.jsonl}"

# Build per-reviewer payload from each meta.json the wrapper wrote. Reviewers
# whose meta is absent are reported as "skipped" so the runlog entry is honest
# about coverage.
reviewer_obj() {
  local name="$1"
  # The wrapper writes meta to $run_dir/raw/<reviewer>.meta.json (step 3 of
  # SKILL.md passes --out "$run_dir/raw"), but earlier docs incorrectly
  # told callers to pass --run-dir "$run_dir" here, which silently
  # classified every reviewer as "skipped" and lost all telemetry.
  # Caught by codex on pass-3 self-review of PR #10. Try $run_dir/raw
  # first (the canonical location), fall back to $run_dir for callers
  # who already point directly at the raw dir.
  local meta=""
  if [[ -f "$run_dir/raw/$name.meta.json" ]]; then
    meta="$run_dir/raw/$name.meta.json"
  elif [[ -f "$run_dir/$name.meta.json" ]]; then
    meta="$run_dir/$name.meta.json"
  else
    echo '{"status":"skipped"}'
    return
  fi
  # Pass through the meta fields verbatim. The wrapper guarantees:
  # exit_code, duration_s, timed_out, output_bytes, attempt, timeout_budget_s
  # (and reviewer-specific extras like truncated for kimi).
  #
  # Status precedence: timed_out FIRST so that timeouts which exit 0 (some
  # `timeout` implementations do depending on signal handling) don't get
  # misclassified as "ok". "quota" next: the agy laps stamp
  # failure_kind=quota_exhausted when the shared Gemini Individual quota is
  # the cause — that's a wait-for-reset condition, not a timeout/auth issue,
  # and the analyzer warns on it differently. "permission_denied" likewise
  # gets its own status: a headless soft-denied tool confirmation is a
  # prompt-shape bug in this repo, NOT a dead/ineligible seat, and must not
  # be read as a reason to retire the reviewer. || fallback handles malformed
  # meta.json (OOM, kill mid-write, garbage); we prefer "failed" telemetry
  # over silently dropping the entire pass when the final --argjson rejects
  # empty input.
  # `fallback` comes BEFORE the exit_code==0 branch on purpose, and requires
  # `succeeded` -- a fallback that itself failed must fall through to the
  # ordinary failure branches, not be recorded as a rescued round. Keying only
  # on `used` scored a lane whose rescue also died as "fallback"; seen live on
  # PR #66, where kimi's fallback returned rc=5 with 0 bytes. (codex, PR #66.)
  # `succeeded` falls back to (exit_code == 0) rather than to false: meta written
  # by the version before that field existed carries `used` alone, and defaulting
  # those to false would reclassify an old SUCCESSFUL rescue as a healthy "ok" --
  # the very misreading this branch exists to prevent, inflicted on the archive.
  # (codex, PR #66 delta.) A first-party
  # lane that failed and was rescued over OpenRouter writes the FALLBACK run's
  # meta -- exit_code 0, real output -- so it would otherwise classify as "ok"
  # and the dead primary would look perfectly healthy forever, which is exactly
  # the blindness the 2026-07-01 no-fallback policy existed to prevent. A
  # distinct status keeps reliability honest (leaderboard.sh counts only "ok"),
  # while the findings still earn their normal value credit.
  #
  # The `succeeded` read uses has(), NOT `//`. jq treats an explicit `false` as
  # absent, so `.fallback.succeeded // (.exit_code == 0)` would read a rescue
  # recorded as succeeded:false with exit_code 0 as a SUCCESSFUL rescue --
  # crediting a dead lane with a served review. Latent rather than live today
  # (run_reviewers.sh writes succeeded:false only when the fallback rc is
  # non-zero, and stamps that same rc as exit_code), but it is one change away
  # from being live and it is the third `//` false-collapse in this skill --
  # cf. profile_flag() in run_reviewers.sh, same root cause, fixed the same way.
  # (codex Medium + kimi3 Medium, convergent across two providers, PR #66
  # delta-2.) The legacy default stays `.exit_code == 0` alone: adding an
  # output_bytes clause here would silently RE-classify old rows, which is the
  # regression this branch was already fixed for once.
  jq -c '. + {status: (if .timed_out == true then "timed_out"
                       elif (.fallback.used // false) == true
                            and (if (.fallback | has("succeeded"))
                                 then .fallback.succeeded
                                 else (.exit_code == 0) end) == true then "fallback"
                       # used-but-not-succeeded is a FAILED lane, full stop. It
                       # must not fall through to the exit-code heuristics
                       # below, where a rescue that exited 0 with bytes on
                       # stdout would score "ok" -- crediting a dead lane with
                       # a healthy round, the exact blindness this status
                       # exists to remove.
                       elif (.fallback.used // false) == true then "failed"
                       elif .failure_kind == "quota_exhausted" then "quota"
                       elif .failure_kind == "headless_permission_denied" then "permission_denied"
                       elif .failure_kind == "degenerate_output" then "degenerate"
                       elif .failure_kind == "no_verdict_output" then "no_verdict"
                       elif .exit_code == 0 and (.output_bytes // 0) > 0 then "ok"
                       elif .exit_code == 0 then "empty"
                       else "failed" end)}' "$meta" 2>/dev/null \
    || echo '{"status":"failed","reason":"meta_unparseable"}'
}

# enrich_with_findings <reviewer> <reviewer_json> — add findings_total /
# findings_convergent / findings_dropped from the --findings file. Convergence
# is judged per PROVIDER (an antigravity+gemini-pro-only finding is one
# provider agreeing with itself — not convergent). No-op without --findings,
# for skipped reviewers, or on unreadable findings JSON.
enrich_with_findings() {
  local name="$1" rjson="$2"
  if [[ -z "$findings_file" || ! -f "$findings_file" ]]; then
    printf '%s' "$rjson"
    return
  fi
  if [[ "$(printf '%s' "$rjson" | jq -r '.status // empty')" == "skipped" ]]; then
    printf '%s' "$rjson"
    return
  fi
  local counts
  counts="$(jq -c --arg r "$name" '
    ({"codex":"openai","antigravity":"google","gemini-pro":"google",
      "kimi":"moonshot","glm":"zhipu","deepseek":"deepseek","mimo":"xiaomi",
      "minimax":"minimax","qwen":"alibaba","devstral":"mistral",
      "laguna":"poolside","kat":"kuaishou","north":"cohere","nemotron":"nvidia",
      "spark":"meta","seed":"bytedance","grok":"xai",
      "longcat":"meituan","inkling":"thinkingmachines",
      "kimi27":"moonshot","kimi3":"moonshot"}) as $prov
    | [(.findings // [])[] | select((.sources // []) | index($r))] as $mine
    | { findings_total: ($mine | length),
        findings_convergent: ($mine | map(select(
            ((.sources // []) | map($prov[.] // .) | unique | length) > 1)) | length),
        findings_dropped: ($mine | map(select(.factcheck.verdict == "drop")) | length) }
  ' "$findings_file" 2>/dev/null)"
  if [[ -n "$counts" ]]; then
    printf '%s' "$rjson" | jq -c --argjson c "$counts" '. + $c' 2>/dev/null || printf '%s' "$rjson"
  else
    printf '%s' "$rjson"
  fi
}

# enrich_with_context_mode_cost_and_profile <reviewer> <reviewer_json> —
# stamp context_mode (#93), cost_usd_estimated/cost_estimated (#123), and
# profile_hash (#90). No-op for skipped reviewers, so a reviewer with no
# meta this round gets no row change at all — status "skipped" stays the
# entire object.
# Every enrichment step is fail-open: if a jq step fails (e.g. tokens_prompt
# arrives as a string and the cost multiplication errors), the pre-enrichment
# row survives, so the entry still lands instead of --argjson crashing on an
# empty string and dropping the whole pass (gemini-pro, PR #128 review).
enrich_with_context_and_profile() {
  local name="$1" rjson="$2"
  if [[ -z "$rjson" || "$(jq -r '.status // empty' <<<"$rjson")" == "skipped" ]]; then
    printf '%s' "$rjson"
    return
  fi

  # context_mode (#93): context_access wins when present (the wrapper's own
  # classification of what this run actually saw); cli is the fallback for
  # older meta.json rows written before context_access existed. Neither
  # present -> "diff", the most conservative read (assume the seat only saw
  # the raw diff unless told otherwise).
  rjson="$(jq -c '
    (.context_access // "") as $ca
    | (.cli // "") as $cli
    | . + {context_mode: (
        if ($ca == "agent" or $ca == "workspace_read" or $ca == "tool_read") then "tools"
        elif ($ca == "file_context" or $ca == "snapshot") then "files"
        elif ($ca == "diff_only") then "diff"
        elif ($cli == "codex" or $cli == "agy") then "tools"
        else "diff" end
      )}' <<<"$rjson" 2>/dev/null || printf '%s' "$rjson")"

  # cost_usd_estimated / cost_estimated (#123): a billed row (cost_usd
  # present) is authoritative and gets cost_estimated:false, no estimate
  # key. An unbilled row with both token counts AND a priced seat gets an
  # estimate (tokens x $/M, rounded to 6 decimals) and cost_estimated:true.
  # Anything else (no tokens, or no pricing on file for this seat) gets
  # neither key -- there is nothing honest to stamp.
  local pricing_json
  pricing_json="$(jq -c --arg r "$name" '.[$r].pricing // null' "$profiles_file" 2>/dev/null)"
  [[ -n "$pricing_json" ]] || pricing_json="null"
  # tokens are coerced to numbers first (a wrapper that wrote "1000000" as a
  # string must not reach the runlog as a string, or leaderboard.sh's math
  # crashes on the whole ledger later -- gemini-pro, PR #128 pass 2); an
  # uncoercible value is dropped from the row rather than stamped.
  rjson="$(jq -c --argjson pricing "$pricing_json" '
    def num: if type == "number" then . elif type == "string" then (tonumber? // null) else null end;
    (.tokens_prompt | num) as $tp | (.tokens_completion | num) as $tc
    | (if has("tokens_prompt") then (if $tp == null then del(.tokens_prompt) else .tokens_prompt = $tp end) else . end)
    | (if has("tokens_completion") then (if $tc == null then del(.tokens_completion) else .tokens_completion = $tc end) else . end)
    | if (.cost_usd != null) then
      . + {cost_estimated: false}
    elif ($tp != null and $tc != null
          and $pricing != null
          and ($pricing.prompt_per_m // null) != null
          and ($pricing.completion_per_m // null) != null) then
      ((($tp * $pricing.prompt_per_m)
        + ($tc * $pricing.completion_per_m)) / 1000000) as $raw
      | (($raw * 1000000 | round) / 1000000) as $rounded
      | . + {cost_usd_estimated: $rounded, cost_estimated: true}
    else
      .
    end' <<<"$rjson" 2>/dev/null || printf '%s' "$rjson")"

  # profile_hash (#90): first 12 hex of sha1(jq -cS of the seat's canonical
  # profile entry). Absent when the seat has no profile entry, or when no
  # sha1 tool is on PATH (fail-open, not fail-closed).
  if [[ -n "$(type -t sha1_of 2>/dev/null)" ]]; then
    local profile_entry phash
    profile_entry="$(jq -cS --arg r "$name" '.[$r] // empty' "$profiles_file" 2>/dev/null)"
    if [[ -n "$profile_entry" ]]; then
      phash="$(printf '%s' "$profile_entry" | sha1_of | cut -c1-12)"
      if [[ "$phash" =~ ^[0-9a-f]{12}$ ]]; then
        rjson="$(jq -c --arg h "$phash" '. + {profile_hash: $h}' <<<"$rjson" 2>/dev/null || printf '%s' "$rjson")"
      fi
    fi
  fi

  printf '%s' "$rjson"
}

codex_json=$(enrich_with_findings codex "$(enrich_with_context_and_profile codex "$(reviewer_obj codex)")")
antigravity_json=$(enrich_with_findings antigravity "$(enrich_with_context_and_profile antigravity "$(reviewer_obj antigravity)")")
gemini_pro_json=$(enrich_with_findings gemini-pro "$(enrich_with_context_and_profile gemini-pro "$(reviewer_obj gemini-pro)")")
kimi_json=$(enrich_with_findings kimi "$(enrich_with_context_and_profile kimi "$(reviewer_obj kimi)")")
glm_json=$(enrich_with_findings glm "$(enrich_with_context_and_profile glm "$(reviewer_obj glm)")")
deepseek_json=$(enrich_with_findings deepseek "$(enrich_with_context_and_profile deepseek "$(reviewer_obj deepseek)")")
mimo_json=$(enrich_with_findings mimo "$(enrich_with_context_and_profile mimo "$(reviewer_obj mimo)")")
minimax_json=$(enrich_with_findings minimax "$(enrich_with_context_and_profile minimax "$(reviewer_obj minimax)")")
qwen_json=$(enrich_with_findings qwen "$(enrich_with_context_and_profile qwen "$(reviewer_obj qwen)")")
devstral_json=$(enrich_with_findings devstral "$(enrich_with_context_and_profile devstral "$(reviewer_obj devstral)")")
laguna_json=$(enrich_with_findings laguna "$(enrich_with_context_and_profile laguna "$(reviewer_obj laguna)")")
kat_json=$(enrich_with_findings kat "$(enrich_with_context_and_profile kat "$(reviewer_obj kat)")")
north_json=$(enrich_with_findings north "$(enrich_with_context_and_profile north "$(reviewer_obj north)")")
nemotron_json=$(enrich_with_findings nemotron "$(enrich_with_context_and_profile nemotron "$(reviewer_obj nemotron)")")
spark_json=$(enrich_with_findings spark "$(enrich_with_context_and_profile spark "$(reviewer_obj spark)")")
seed_json=$(enrich_with_findings seed "$(enrich_with_context_and_profile seed "$(reviewer_obj seed)")")
grok_json=$(enrich_with_findings grok "$(enrich_with_context_and_profile grok "$(reviewer_obj grok)")")
longcat_json=$(enrich_with_findings longcat "$(enrich_with_context_and_profile longcat "$(reviewer_obj longcat)")")
inkling_json=$(enrich_with_findings inkling "$(enrich_with_context_and_profile inkling "$(reviewer_obj inkling)")")
kimi27_json=$(enrich_with_findings kimi27 "$(enrich_with_context_and_profile kimi27 "$(reviewer_obj kimi27)")")
kimi3_json=$(enrich_with_findings kimi3 "$(enrich_with_context_and_profile kimi3 "$(reviewer_obj kimi3)")")

# round_wall_s (#91): derived, no flag. worktree.sh start's context.json
# stamps `started_at` as "%Y%m%dT%H%M%S" on the UTC clock (`date -u`) as of
# #118 -- so "now" is taken on the same UTC clock here, rather than pairing
# a UTC started_at with a local "now" (or vice versa), which is the skew
# class #117/#118 both existed to close: whichever single clock either side
# used alone was TZ-safe, but the two sides drifting onto DIFFERENT clocks
# was the actual bug, and it can recur in either direction. UTC on both ends
# is the fix that can't drift again. Fail-open like --roster-decision:
# missing file, missing field, malformed JSON, or a value outside 0..7 days
# just omits the key rather than blocking the append. jq's strptime/mktime
# are used (not OS `date` flavor) so this is portable between macOS and
# Linux runners.
round_wall_s_val=""
if [[ -f "$run_dir/context.json" ]]; then
  now_compact="$(date -u +%Y%m%dT%H%M%S)"
  round_wall_s_val="$(jq -e -r --arg now "$now_compact" '
      (.started_at // empty) as $sa
      | if ($sa | length) == 0 then empty
        else (($now | strptime("%Y%m%dT%H%M%S") | mktime)
              - ($sa  | strptime("%Y%m%dT%H%M%S") | mktime))
        end
    ' "$run_dir/context.json" 2>/dev/null)"
  if [[ -n "$round_wall_s_val" ]] && ! { [[ "$round_wall_s_val" =~ ^[0-9]+$ ]] && [[ "$round_wall_s_val" -le 604800 ]]; }; then
    echo "append_runlog: round_wall_s '$round_wall_s_val' is outside 0..604800s (bad started_at?) -- omitting" >&2
    round_wall_s_val=""
  fi
fi

# --phases (#91): additive, fail-open on a missing/unreadable file — losing
# phase telemetry must never block a runlog append.
phases_json="null"
if [[ -n "$phases_file" ]]; then
  # shape check: a flat object of non-negative numbers, nothing else, so the
  # readers' "iterate a flat numeric object" assumption holds (minimax)
  # -s: the file must hold exactly ONE object -- a JSON stream would make
  # jq print several lines and the entry's --argjson would then crash,
  # dropping the whole runlog entry (gemini-pro, PR #117 pass 2)
  if [[ -f "$phases_file" ]] && ph="$(jq -sce 'if length == 1 and (.[0] | type == "object" and (to_entries | all(.value | type == "number" and . >= 0))) then .[0] else empty end' "$phases_file" 2>/dev/null)"; then
    phases_json="$ph"
  else
    echo "append_runlog: --phases file unreadable, invalid JSON, or not a flat object of non-negative numbers: $phases_file (omitting phases)" >&2
  fi
fi

ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

entry=$(jq -nc \
  --arg ts "$ts" \
  --arg project "$project" \
  --arg base "$base" \
  --arg pr "$pr" \
  --argjson pass "$pass" \
  --arg verdict "$verdict" \
  --argjson convergent "$convergent" \
  --arg top "$top" \
  --arg notes "$notes" \
  --arg diff_files "${diff_files:-}" \
  --arg diff_lines "${diff_lines:-}" \
  --argjson codex "$codex_json" \
  --argjson antigravity "$antigravity_json" \
  --argjson gemini_pro "$gemini_pro_json" \
  --argjson kimi "$kimi_json" \
  --argjson glm "$glm_json" \
  --argjson deepseek "$deepseek_json" \
  --argjson mimo "$mimo_json" \
  --argjson minimax "$minimax_json" \
  --argjson qwen "$qwen_json" \
  --argjson devstral "$devstral_json" \
  --argjson laguna "$laguna_json" \
  --argjson kat "$kat_json" \
  --argjson north "$north_json" \
  --argjson nemotron "$nemotron_json" \
  --argjson spark "$spark_json" \
  --argjson seed "$seed_json" \
  --argjson grok "$grok_json" \
  --argjson longcat "$longcat_json" \
  --argjson inkling "$inkling_json" \
  --argjson kimi27 "$kimi27_json" \
  --argjson kimi3 "$kimi3_json" \
  --arg run_id "$run_id" \
  --argjson roster_decision "$roster_decision_json" \
  --argjson schema_version "$SCHEMA_VERSION" \
  --arg round_wall_s "$round_wall_s_val" \
  --argjson phases "$phases_json" \
  --argjson synthetic "$([[ "$synthetic" -eq 1 ]] && echo true || echo false)" \
  '{codex: $codex, antigravity: $antigravity, "gemini-pro": $gemini_pro, kimi: $kimi, glm: $glm,
    deepseek: $deepseek, mimo: $mimo, minimax: $minimax, qwen: $qwen,
    devstral: $devstral, laguna: $laguna, kat: $kat, north: $north, nemotron: $nemotron,
    spark: $spark, seed: $seed, grok: $grok,
    longcat: $longcat, inkling: $inkling,
    kimi27: $kimi27, kimi3: $kimi3} as $reviewers
  | ($reviewers | to_entries | map(select(.value.duration_s != null))) as $timed
  | (if ($timed | length) == 0 then null
     else ($timed | sort_by(.value.duration_s) | last
                   | {reviewer: .key, duration_s: .value.duration_s})
     end) as $trailing
  | {
    ts: $ts,
    schema_version: $schema_version,
    project: $project,
    base: $base,
    pr: (if $pr == "-" then null else ($pr | tonumber? // $pr) end),
    pass: $pass,
    diff_size: (if $diff_files == "" and $diff_lines == "" then null
                else {files: ($diff_files | tonumber? // null),
                      lines: ($diff_lines | tonumber? // null)} end),
    reviewers: $reviewers,
    convergent_count: $convergent,
    verdict: $verdict,
    top_finding: (if $top == "" then null else $top end),
    notes: (if $notes == "" then null else $notes end)
  }
  + (if $run_id == "" then {} else {run_id: $run_id} end)
  + (if $roster_decision == null then {} else {roster_decision: $roster_decision} end)
  + (if $round_wall_s == "" then {} else {round_wall_s: ($round_wall_s | tonumber)} end)
  + (if $trailing == null then {} else {trailing_reviewer: $trailing} end)
  + (if $phases == null then {} else {phases: $phases} end)
  + (if $synthetic then {synthetic: true} else {} end)')

# JSONL — one line, append-only. Wrap in flock to make it splitstream-safe:
# POSIX guarantees write() atomicity below PIPE_BUF (4KB Linux, 512B macOS).
# Our entries are ~500-800B and growing; on macOS they're already at the
# atomicity boundary, and concurrent splitstream rounds writing simultaneously
# could interleave. flock costs ~5 lines and removes the risk.
# `flock` is GNU/Linux native; macOS Homebrew users get it via `brew install
# util-linux` (or use `shlock`/`lockfile`). Fall back to bare append if flock
# is missing — preserves correctness on platforms without it.
if command -v flock >/dev/null 2>&1; then
  (
    flock -x 200
    printf '%s\n' "$entry" >>"$runlog"
  ) 200>"$runlog.lock"
else
  printf '%s\n' "$entry" >>"$runlog"
fi
echo "appended runlog entry: ts=$ts pr=$pr pass=$pass verdict=$verdict" >&2
