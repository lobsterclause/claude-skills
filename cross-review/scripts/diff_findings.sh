#!/usr/bin/env bash
# diff_findings.sh — round-to-round finding diff (issue #78): bucket a PAIR
# of findings.verified.json snapshots (or one snapshot plus the reconstructed
# previous round from finding_events.jsonl) into fixed / still_open /
# newly_introduced, keyed on the stable f-<hash> id from
# fingerprint_findings.sh (NOT file+line, which moves round to round).
#
# WHY: the re-review loop (SKILL.md step 6) reports "what's left" by eye
# today. "newly_introduced" in particular — a fix round that broke something
# new — is currently invisible unless a reviewer happens to re-flag it.
#
# Usage:
#   diff_findings.sh --curr <findings.verified.json>
#                     (--prev <findings.verified.json> |
#                      --run-id <id> (--repo-root <path> | --project <name>))
#                     [--prev-diff <prior diff_findings.sh JSON output>]
#                     [--out <file>] [--format md|json] [--allow-empty-prev]
#
# --allow-empty-prev: a missing or empty ledger is otherwise an ERROR when
#   --prev is omitted — a typo in CROSS_REVIEW_FINDING_EVENTS would silently
#   report every current finding as newly_introduced (kimi, PR #85 review).
#   Pass this for a genuine first round.
#
# --prev <file>: explicit previous round's findings.verified.json (or any
#   object with a top-level "findings" array, or a bare array — same
#   tolerance as report_block.sh).
#
# --prev omitted: reconstruct the previous round from finding_events.jsonl
#   (the ledger fingerprint_findings.sh/anchor_findings.sh/
#   factcheck_findings.sh append to via --emit-events). Requires --run-id
#   (the CURRENT round's run_id, so the script can find the round recorded
#   immediately before it in the ledger) and a namespace source
#   (--repo-root | --project, same mutually-exclusive pair and derivation as
#   fingerprint_findings.sh's flags of the same name — see
#   lib_project_namespace.sh). The ledger path defaults to
#   "<skill root>/finding_events.jsonl" (sibling to runlog.jsonl); set
#   CROSS_REVIEW_FINDING_EVENTS to point at a fixture (mirrors
#   append_finding_event.sh's override, tests only — production callers
#   never set it).
#
#   A round's kept-finding set is reconstructed as: every finding_id with a
#   "proposed" event at that run_id, MINUS any finding_id with a
#   "factcheck_dropped" event at that same run_id (mirrors factcheck's
#   fail-safe: no factcheck event at all means keep, matching the real
#   fail-safe-keep-all behavior of factcheck_findings.sh).
#
#   KNOWN LIMITATION: finding_events.jsonl entries emitted by
#   fingerprint_findings.sh / anchor_findings.sh / factcheck_findings.sh do
#   NOT carry a "project" field today — cross-project separation in
#   production currently relies entirely on the project being baked into the
#   f-<hash> itself (see fingerprint_findings.sh's NAMESPACE EPOCH comment,
#   issue #39). This script honors an explicit "project" field on a ledger
#   line when one is present (any event lacking one is treated as belonging
#   to the caller's own namespace, for backward compatibility with today's
#   ledger) — see the FOLLOW_UP_ISSUE in the shipping PR for making this
#   airtight by having the emitters stamp "project" on every event.
#
# --prev-diff <file>: optional. The JSON this script produced for the PRIOR
#   comparison (e.g. diff(round1, round2)) — used only to carry the
#   "rounds" counter on still_open findings forward so it increments across
#   more than two rounds instead of resetting to a fixed baseline every time
#   diff_findings.sh runs. A still_open finding's rounds = 1 (its
#   presumed-baseline prior existence) + 1 (this round) if not found in
#   --prev-diff, else --prev-diff's rounds for that id + 1.
#
# --format md|json (default: json). --out <file> (default: stdout).
#
# Output shapes:
#   json: {"counts": {fixed, still_open, newly_introduced},
#          "fixed": [{id,file,line,claim,severity,sources}, ...],
#          "still_open": [{id,file,line,claim,severity,sources,rounds}, ...],
#          "newly_introduced": [{id,file,line,claim,severity,sources}, ...]}
#   md: one section per bucket (Newly introduced first — the highest-value
#       bucket, per the issue), each finding as one bullet, "_none_" when a
#       bucket is empty.
#
# Both inputs are filtered to `factcheck.verdict != "drop"` findings first
# (missing factcheck defaults to kept) — same "verified set" semantics as
# report_block.sh, so a finding factcheck vetoed never counts as fixed/
# newly_introduced/still_open.
#
# Deterministic: same inputs -> byte-identical output. Findings within each
# bucket are sorted by severity (Critical>High>Medium>Low>unknown) desc,
# then file asc, then id asc — no timestamps, no randomness.
#
# Tolerant input handling: a malformed ledger line (invalid JSON, or valid
# JSON that isn't an object) is skipped and counted on stderr, never fatal.
# A whole-file JSON parse failure of an explicitly-named --prev/--curr is a
# clean nonzero error (exit 1) with NO output file written.
#
# Exit: 0 ok, 2 usage error, 1 io error (missing jq, bad --prev/--curr JSON).

set -uo pipefail
allow_empty_prev=0

script_dir="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib_project_namespace.sh
source "$script_dir/lib_project_namespace.sh"

prev="" ; curr="" ; prev_diff="" ; run_id="" ; project="" ; repo_root=""
out="" ; format="json"

need_val() { [[ "$2" -lt 2 ]] && { echo "diff_findings: missing value for $1" >&2; exit 2; }; }
while [[ $# -gt 0 ]]; do
  case "$1" in
    --prev)       need_val "$1" "$#"; prev="$2";       shift 2 ;;
    --curr)       need_val "$1" "$#"; curr="$2";       shift 2 ;;
    --prev-diff)  need_val "$1" "$#"; prev_diff="$2";  shift 2 ;;
    --run-id)     need_val "$1" "$#"; run_id="$2";     shift 2 ;;
    --project)    need_val "$1" "$#"; project="$2";    shift 2 ;;
    --repo-root)  need_val "$1" "$#"; repo_root="$2";  shift 2 ;;
    --out)        need_val "$1" "$#"; out="$2";        shift 2 ;;
    --format)     need_val "$1" "$#"; format="$2";     shift 2 ;;
    --allow-empty-prev) allow_empty_prev=1;             shift ;;
    *) echo "diff_findings: unknown arg: $1" >&2; exit 2 ;;
  esac
done

usage="usage: $0 --curr <findings.verified.json> (--prev <findings.verified.json> | --run-id <id> (--repo-root <path> | --project <name>)) [--prev-diff <json>] [--out <file>] [--format md|json]"

[[ -z "$curr" ]] && { echo "$usage" >&2; exit 2; }
case "$format" in
  md|json) ;;
  *) echo "diff_findings: --format must be md or json, got '$format'" >&2; exit 2 ;;
esac
[[ -f "$curr" ]] || { echo "diff_findings: --curr file not found: $curr" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "diff_findings: jq required" >&2; exit 1; }

if [[ -n "$prev" && ( -n "$run_id" || -n "$project" || -n "$repo_root" ) ]]; then
  echo "diff_findings: --prev is mutually exclusive with --run-id/--project/--repo-root (ledger reconstruction)" >&2
  exit 2
fi
if [[ -z "$prev" ]]; then
  [[ -z "$run_id" ]] && { echo "diff_findings: --prev omitted — --run-id is required to reconstruct from the ledger" >&2; echo "$usage" >&2; exit 2; }
  if [[ -n "$project" && -n "$repo_root" ]]; then
    echo "diff_findings: --project and --repo-root are mutually exclusive (pick one namespace source)" >&2
    exit 2
  fi
  if [[ -z "$project" && -z "$repo_root" ]]; then
    echo "diff_findings: --prev omitted — --repo-root or --project is required to scope the ledger reconstruction" >&2
    exit 2
  fi
  if [[ -n "$repo_root" ]]; then
    [[ -d "$repo_root" ]] || { echo "diff_findings: --repo-root not a directory: $repo_root" >&2; exit 1; }
    project="$(derive_project "$repo_root")"
  fi
else
  [[ -f "$prev" ]] || { echo "diff_findings: --prev file not found: $prev" >&2; exit 1; }
fi
if [[ -n "$prev_diff" ]]; then
  [[ -f "$prev_diff" ]] || { echo "diff_findings: --prev-diff file not found: $prev_diff" >&2; exit 1; }
fi

tmp_dir="$(mktemp -d)"; trap 'rm -rf "$tmp_dir"' EXIT

# ── Validate whole-file JSON up front: a parse failure here is a clean
# nonzero error, never a partial write of --out. ─────────────────────────
if ! jq -e . "$curr" >/dev/null 2>"$tmp_dir/curr.err"; then
  echo "diff_findings: --curr is not valid JSON: $curr ($(cat "$tmp_dir/curr.err"))" >&2
  exit 1
fi
if [[ -n "$prev" ]] && ! jq -e . "$prev" >/dev/null 2>"$tmp_dir/prev.err"; then
  echo "diff_findings: --prev is not valid JSON: $prev ($(cat "$tmp_dir/prev.err"))" >&2
  exit 1
fi
if [[ -n "$prev_diff" ]] && ! jq -e . "$prev_diff" >/dev/null 2>"$tmp_dir/prev_diff.err"; then
  echo "diff_findings: --prev-diff is not valid JSON: $prev_diff ($(cat "$tmp_dir/prev_diff.err"))" >&2
  exit 1
fi

# normalize_kept <file> -> writes one JSON object per line (id,file,line,
# claim,severity,sources) to stdout for every kept (non-factcheck-dropped)
# finding, tolerating either {findings:[...]} or a bare array.
normalize_kept() {
  local f="$1"
  jq -c '
    (if type=="array" then .
     elif type=="object" and (.findings|type)=="array" then .findings
     else error("not a findings JSON: expected an array or {findings:[...]}") end)
    | .[]
    | select((.factcheck.verdict // "keep") != "drop")
    | select((.id | type) == "string" and .id != "")
    | {id: .id, file: (.file // ""), line: (.line // null),
       claim: (.claim // ""), severity: (.severity // ""),
       sources: (.sources // [])}
  ' "$f"
}

curr_kept="$tmp_dir/curr.kept.jsonl"
# A findings file that parses as JSON but is not a findings shape must not
# become an empty current set and a plausible, wrong diff (codex, PR #85).
normalize_kept "$curr" > "$curr_kept" || { echo "diff_findings: --curr is not a findings JSON (array or {findings:[...]}): $curr" >&2; exit 1; }

prev_kept="$tmp_dir/prev.kept.jsonl"
malformed_ledger_lines=0

if [[ -n "$prev" ]]; then
  normalize_kept "$prev" > "$prev_kept" || { echo "diff_findings: --prev is not a findings JSON (array or {findings:[...]}): $prev" >&2; exit 1; }
else
  # ── Ledger reconstruction ────────────────────────────────────────────
  ledger="${CROSS_REVIEW_FINDING_EVENTS:-$(cd "$(dirname "$0")/.." && pwd)/finding_events.jsonl}"
  : > "$prev_kept"
  events_ok="$tmp_dir/events.ok.jsonl"
  : > "$events_ok"
  untagged_events=0
  if [[ ! -s "$ledger" && "$allow_empty_prev" != 1 ]]; then
    echo "diff_findings: ledger not found or empty: $ledger — pass --prev, or --allow-empty-prev for a genuine first round" >&2
    exit 1
  fi
  if [[ -f "$ledger" ]]; then
    while IFS= read -r line || [[ -n "$line" ]]; do
      [[ -z "$line" ]] && continue
      if ! parsed="$(jq -c -e '. as $x | if ($x|type)=="object" then $x else error("not an object") end' <<<"$line" 2>/dev/null)"; then
        malformed_ledger_lines=$((malformed_ledger_lines + 1))
        continue
      fi
      # Project scoping: an event tagged with an explicit "project" that
      # doesn't match ours never counts toward our reconstruction (issue
      # #39-style cross-repo isolation). An event with no "project" field
      # at all is treated as ours (today's real ledger never stamps one).
      ev_project="$(jq -r '.project // empty' <<<"$parsed")"
      if [[ -n "$ev_project" && "$ev_project" != "$project" ]]; then
        continue
      fi
      [[ -z "$ev_project" ]] && untagged_events=$((untagged_events + 1))
      printf '%s\n' "$parsed" >> "$events_ok"
    done < "$ledger"
  fi

  # Distinct run_ids in first-appearance (== chronological, ledger is
  # append-only) order, restricted to our namespace.
  run_ids_ordered="$tmp_dir/run_ids.txt"
  jq -r '.run_id // empty' "$events_ok" | awk '!seen[$0]++' > "$run_ids_ordered"

  # A ledger with bytes but no usable run in OUR namespace (all malformed,
  # all another project's, or run_id-less) is as empty as a missing one and
  # gets the same treatment (codex, #85 pass 2).
  if [[ ! -s "$run_ids_ordered" && "$allow_empty_prev" != 1 ]]; then
    echo "diff_findings: ledger has no usable run for project '$project': $ledger — pass --prev, or --allow-empty-prev for a genuine first round" >&2
    exit 1
  fi
  prev_run_id=""; prev_source="ledger"
  if grep -qxF -- "$run_id" "$run_ids_ordered" 2>/dev/null; then
    prev_run_id="$(awk -v cur="$run_id" '
      $0==cur { print prev; found=1; exit }
      { prev=$0 }
      END { if (!found) exit 0 }
    ' "$run_ids_ordered")"
  else
    # The current run is not in the ledger yet (fingerprint not run, or a
    # mistyped --run-id): the newest run is the previous one. Say so — a typo
    # here would otherwise produce a plausible diff against the wrong round.
    prev_run_id="$(tail -n 1 "$run_ids_ordered" 2>/dev/null || true)"
    if [[ -z "$prev_run_id" ]]; then
      prev_source="empty_ledger"   # --allow-empty-prev: a genuine first round
    else
      prev_source="ledger_last_run"
      echo "diff_findings: WARN run_id '$run_id' not in the ledger — using the newest run ($prev_run_id) as the previous round" >&2
    fi
  fi
  # Untagged events are treated as ours (issue #86: the emitters do not stamp
  # a project yet), which on a ledger shared across repos can pick another
  # project's run as the previous round (codex, PR #85). Count them and say
  # so; the JSON carries the number so a consumer can refuse to trust it.
  if (( untagged_events > 0 )); then
    echo "diff_findings: WARN $untagged_events ledger event(s) carry no project tag and were assumed to be ours (see issue #86)" >&2
  fi

  if [[ -n "$prev_run_id" ]]; then
    dropped_ids="$tmp_dir/dropped_ids.txt"
    jq -r --arg rid "$prev_run_id" \
      'select(.event=="factcheck_dropped" and .run_id==$rid) | .finding_id' \
      "$events_ok" | sort -u > "$dropped_ids"
    [[ -f "$dropped_ids" ]] || : > "$dropped_ids"

    jq -c --arg rid "$prev_run_id" \
      'select(.event=="proposed" and .run_id==$rid)' "$events_ok" \
      | jq -s -c 'group_by(.finding_id) | map(.[0])' \
      | jq -c '.[]' \
      | while IFS= read -r pf; do
          fid="$(jq -r '.finding_id' <<<"$pf")"
          if grep -qxF -- "$fid" "$dropped_ids" 2>/dev/null; then
            continue
          fi
          jq -c '{id: .finding_id, file: (.file // ""), line: null,
                   claim: (.claim // ""), severity: (.severity // ""),
                   sources: (.all_sources // (if .reviewer then [.reviewer] else [] end))}' \
            <<<"$pf"
        done > "$prev_kept"
  fi

  echo "diff_findings: ledger reconstruction — $malformed_ledger_lines malformed line(s) skipped" >&2
fi

# ── Bucket by id ──────────────────────────────────────────────────────────
prev_ids_json="$(jq -s -c '[.[].id]' "$prev_kept" 2>/dev/null || echo '[]')"
curr_ids_json="$(jq -s -c '[.[].id]' "$curr_kept" 2>/dev/null || echo '[]')"

prev_map="$(jq -s -c 'map({(.id): .}) | add // {}' "$prev_kept" 2>/dev/null || echo '{}')"
curr_map="$(jq -s -c 'map({(.id): .}) | add // {}' "$curr_kept" 2>/dev/null || echo '{}')"

# rounds lookup from --prev-diff: still_open entries only. A newly_introduced
# entry carries no rounds field and defaults to 2 when it becomes still_open;
# a "fixed" entry has nothing still open to carry forward.
rounds_map="{}"
if [[ -n "$prev_diff" ]]; then
  rounds_map="$(jq -c '
    (.still_open // []) as $so
    | ($so | map({(.id): .rounds}) | add // {})
  ' "$prev_diff")"
fi

result="$(jq -n -c \
  --argjson prev_ids "$prev_ids_json" \
  --argjson curr_ids "$curr_ids_json" \
  --argjson prev_map "$prev_map" \
  --argjson curr_map "$curr_map" \
  --argjson rounds_map "$rounds_map" \
  "
  def sevrank: {\"Critical\":4,\"High\":3,\"Medium\":2,\"Low\":1}[.severity] // 0;
  (\$prev_ids | unique) as \$p
  | (\$curr_ids | unique) as \$c
  | (\$p - \$c) as \$fixed_ids
  | (\$c - \$p) as \$new_ids
  | (\$p - (\$p - \$c)) as \$still_ids
  | {
      fixed: (\$fixed_ids | map(\$prev_map[.]) | sort_by([-sevrank, .file, .id])),
      still_open: (\$still_ids | map(\$curr_map[.] + {rounds: ((\$rounds_map[.] // 1) + 1)}) | sort_by([-sevrank, .file, .id])),
      newly_introduced: (\$new_ids | map(\$curr_map[.]) | sort_by([-sevrank, .file, .id]))
    }
  | . + {counts: {fixed: (.fixed|length), still_open: (.still_open|length), newly_introduced: (.newly_introduced|length)}}
  | {counts, fixed, still_open, newly_introduced}
  ")"
# Provenance of the previous round: explicit file, or which ledger run and how
# many untagged events were assumed local (0 unless reconstructed).
if [[ -n "$prev" ]]; then
  result="$(jq -c --arg p "$prev" '. + {prev: {source: "file", path: $p}}' <<<"$result")"
else
  result="$(jq -c --arg s "${prev_source:-ledger}" --arg r "${prev_run_id:-}" --argjson u "${untagged_events:-0}" \
    '. + {prev: {source: $s, run_id: $r, untagged_events: $u}}' <<<"$result")"
fi

render_md() {
  local json="$1"
  printf '## Cross-review round diff\n\n'
  local n_new n_open n_fixed
  n_new="$(jq '.counts.newly_introduced' <<<"$json")"
  n_open="$(jq '.counts.still_open' <<<"$json")"
  n_fixed="$(jq '.counts.fixed' <<<"$json")"

  printf '### Newly introduced (%s)\n\n' "$n_new"
  if [[ "$n_new" -eq 0 ]]; then
    printf '_none_\n\n'
  else
    jq -r '.newly_introduced[] | "- `\(.file):\(.line // "?")` — \(.claim) [\(.severity)] (\(.id))"' <<<"$json"
    printf '\n'
  fi

  printf '### Still open (%s)\n\n' "$n_open"
  if [[ "$n_open" -eq 0 ]]; then
    printf '_none_\n\n'
  else
    jq -r '.still_open[] | "- `\(.file):\(.line // "?")` — \(.claim) [\(.severity)] (\(.id), round \(.rounds))"' <<<"$json"
    printf '\n'
  fi

  printf '### Fixed (%s)\n\n' "$n_fixed"
  if [[ "$n_fixed" -eq 0 ]]; then
    printf '_none_\n\n'
  else
    jq -r '.fixed[] | "- `\(.file):\(.line // "?")` — \(.claim) [\(.severity)] (\(.id))"' <<<"$json"
    printf '\n'
  fi
}

if [[ "$format" == "json" ]]; then
  rendered="$(jq -c '.' <<<"$result")"
else
  rendered="$(render_md "$result")"
fi

if [[ -n "$out" ]]; then
  # Atomic, and a failed write is a failure — not a success with no file.
  out_tmp="$(mktemp "$(dirname "$out")/.diff_findings.XXXXXX" 2>/dev/null)" \
    && printf '%s\n' "$rendered" > "$out_tmp" && mv "$out_tmp" "$out" \
    || { echo "diff_findings: cannot write --out $out" >&2; [[ -n "${out_tmp:-}" ]] && rm -f -- "$out_tmp"; exit 1; }
else
  printf '%s\n' "$rendered"
fi

n_fixed="$(jq '.counts.fixed' <<<"$result")"
n_open="$(jq '.counts.still_open' <<<"$result")"
n_new="$(jq '.counts.newly_introduced' <<<"$result")"
echo "diff_findings: fixed=$n_fixed still_open=$n_open newly_introduced=$n_new" >&2
