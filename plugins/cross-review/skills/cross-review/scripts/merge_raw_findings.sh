#!/usr/bin/env bash
# merge_raw_findings.sh — deterministic, offline merge of JSON findings from the
# curl-lane reviewers (OpenRouter pool + direct-Moonshot seats like kimi27/
# kimi3) into a single findings.json.
#
# Only the curl lane (run_openrouter_reviewer in run_reviewers.sh) is asked to
# emit machine-parseable JSON (response_format:{type:"json_object"} plus the
# schema-mandate suffix in references/json_findings_suffix.txt). The CLI
# reviewers (codex, the two agy laps, kimi CLI) still answer in free prose and
# are NOT expected to parse here — their stdouts are reported as `unparsed`
# and left for the existing LLM-driven synthesis step (SKILL.md step 4).
#
# For each <reviewer>.stdout under --raw <dir>:
#   - strip markdown code fences (models sometimes wrap JSON in ```/```json
#     despite being told not to)
#   - attempt to parse the result as JSON with a top-level `.findings` array
#   - on success: tag every finding with `"sources": ["<reviewer>"]`
#     (overwriting anything the model put there) and fold it into the merged
#     findings list
#   - on failure (not JSON, or JSON without a `.findings` array): skip
#     silently and report `unparsed: <reviewer>` on stderr
#
# Pure bash + jq. No network, no LLM calls. Exit is ALWAYS 0 (even when every
# input is prose) — partial extraction from whichever reviewers cooperated is
# the whole point; a fully-prose round should not look like a script failure.
#
# Usage: merge_raw_findings.sh --raw <dir> --out <findings.json> [--emit-events <run_id>]
#
# --emit-events <run_id>: optional, additive (#88). This script never merges
# same-file/same-claim findings from different reviewers into one output row
# — each reviewer's findings are tagged with sources:[<its own name>] and
# concatenated (that merge, if any, happens later — SKILL.md step 4's
# synthesis, or fingerprint_findings.sh). What --emit-events adds is
# DETECTION: across all reviewers processed in this run, a (file, normalized
# claim) pair seen from more than one reviewer is a duplicate — the same bug
# independently reported (or echoed) by multiple seats. For every 2nd+
# reviewer to report a given (file, claim) pair, one "duplicate_merged" event
# is appended, naming that reviewer plus the first (originating) reviewer —
# so a seat that only echoes others is visible in the ledger. This never
# changes --out or the exit code; a missing sha1 tool or an event-append
# failure only WARNs on stderr (fail-open, same contract as the other
# --emit-events passes).
#
# Findings at this stage predate fingerprint_findings.sh, so there is no
# stable f-<hash> id yet. The event's finding_id reuses fingerprint's own
# hashing rule (sha1, first 8 hex chars, same claim normalization: lowercase,
# whitespace-collapsed, trimmed) but over `file|claim` only (no project
# namespace — that isn't known at this stage) so the event can still be
# recognized later, prefixed "f-dup-" to keep it visually distinct from a
# real fingerprinted id and to avoid ever colliding with one.

set -uo pipefail

raw=""
out=""
emit_events_run_id=""
project=""
repo_root=""

need_val() { [[ "$2" -lt 2 ]] && { echo "missing value for $1" >&2; exit 2; }; }
while [[ $# -gt 0 ]]; do
  case "$1" in
    --raw)         need_val "$1" "$#"; raw="$2";                shift 2 ;;
    --out)         need_val "$1" "$#"; out="$2";                shift 2 ;;
    --emit-events) need_val "$1" "$#"; emit_events_run_id="$2"; shift 2 ;;
    --project)     need_val "$1" "$#"; project="$2";            shift 2 ;;
    --repo-root)   need_val "$1" "$#"; repo_root="$2";          shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

# duplicate_merged must join the ledger by the SAME id fingerprint_findings.sh
# will mint later (sha1 of project\x1ffile\x1fclaim_norm), or leaderboard.sh /
# severity_calibration.sh never resolve it (antigravity, PR #131 review). The
# project namespace comes from --project or --repo-root exactly as in
# fingerprint_findings.sh; without either, ids fall back to f-dup-<hash> and a
# WARN says they will not join.
if [[ -n "$project" && -n "$repo_root" ]]; then
  echo "merge_raw_findings: --project and --repo-root are mutually exclusive" >&2; exit 2
fi
if [[ -n "$repo_root" ]]; then
  # shellcheck source=lib_project_namespace.sh
  source "$(cd "$(dirname "$0")" && pwd)/lib_project_namespace.sh"
  project="$(derive_project "$repo_root")"
fi

if [[ -z "$raw" || -z "$out" ]]; then
  echo "usage: $0 --raw <dir> --out <findings.json>" >&2
  exit 2
fi

if [[ ! -d "$raw" ]]; then
  echo "raw dir not found: $raw" >&2
  exit 2
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "jq is required" >&2
  exit 2
fi

# Portable SHA-1: shasum (macOS stock), sha1sum (most Linux), openssl (either)
# — same detection chain as fingerprint_findings.sh, duplicated rather than
# sourced since each script must stay runnable standalone. Only needed for
# --emit-events's duplicate_merged detection; a missing tool degrades that to
# a WARN, never a hard failure (this script's exit is always 0).
sha1_available="false"
if command -v shasum >/dev/null 2>&1; then
  sha1_of() { shasum -a 1 | awk '{print $1}'; }
  sha1_available="true"
elif command -v sha1sum >/dev/null 2>&1; then
  sha1_of() { sha1sum | awk '{print $1}'; }
  sha1_available="true"
elif command -v openssl >/dev/null 2>&1; then
  sha1_of() { openssl dgst -sha1 -r | awk '{print $1}'; }
  sha1_available="true"
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
dup_track="$work/dup_track.jsonl"
: > "$dup_track"

n=0
shopt -s nullglob
# Exclude the attempt-stamped forensic copies (<slug>.attempt<N>.stdout, written
# by run_agy_reviewer so a retry stops destroying the evidence of why attempt 1
# failed). They are the SAME reviewer's output under a different filename: merged
# as-is they would double-count that reviewer's findings and manufacture
# "convergence" between <slug> and <slug>.attempt1 (spotted in PR #41 pass 3,
# where the merge reported `unparsed: gemini-pro.attempt1` as its own reviewer).
files=()
for _f in "$raw"/*.stdout; do
  case "$(basename "$_f")" in
    *.attempt[0-9]*.stdout) continue ;;
  esac
  files+=("$_f")
done
[[ ${#files[@]} -eq 0 ]] && files=("$raw"/*.stdout)
shopt -u nullglob
# Sorted, deterministic iteration order (glob order is filesystem-dependent).
# Bash-3.2-compatible (macOS default /bin/bash lacks mapfile/readarray): split
# a sorted, newline-joined list back into an array on IFS=$'\n'.
sorted=()
if [[ ${#files[@]} -gt 0 ]]; then
  IFS=$'\n' sorted=($(printf '%s\n' "${files[@]}" | sort))
  unset IFS
fi

for f in "${sorted[@]}"; do
  base="$(basename "$f")"
  reviewer="${base%.stdout}"

  # Strip any line that opens/closes a markdown fence (```、```json, ```JSON, …)
  # — models sometimes wrap valid JSON in a fence despite being told not to.
  stripped="$(sed -E '/^[[:space:]]*```/d' "$f" 2>/dev/null)"

  parsed=""
  if parsed="$(printf '%s' "$stripped" | jq -c '.findings // empty' 2>/dev/null)" \
     && [[ -n "$parsed" ]] \
     && printf '%s' "$parsed" | jq -e 'type == "array" and all(type == "object")' >/dev/null 2>&1; then
    tagged="$(printf '%s' "$parsed" | jq -c --arg r "$reviewer" '[.[] | . + {sources: [$r]}]')"
    printf '%s' "$tagged" >"$work/$n.json"
    n=$((n + 1))

    if [[ -n "$emit_events_run_id" && "$sha1_available" == "true" ]]; then
      # Record one dup_track line per finding, in encounter order (sorted
      # reviewer order, then this reviewer's own array order) — the later
      # reduce over this file relies on that order to know which reviewer
      # was first for a given (file, claim) pair.
      while IFS= read -r finding; do
        file="$(jq -r '.file // ""' <<<"$finding")"
        claim="$(jq -r '.claim // ""' <<<"$finding")"
        local_id="$(jq -r '.id // ""' <<<"$finding")"
        claim_norm="$(printf '%s' "$claim" \
          | tr '[:upper:]' '[:lower:]' | tr -s '[:space:]' ' ' \
          | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
        # \x1f (unit separator) joins file/claim, same convention as
        # fingerprint_findings.sh, so a literal "|" in either can't collide.
        # identical input to fingerprint_findings.sh when a project is known
        if [[ -n "$project" ]]; then
          hash="$(printf '%s\x1f%s\x1f%s' "$project" "$file" "$claim_norm" | sha1_of)"
        else
          hash="$(printf '%s\x1f%s' "$file" "$claim_norm" | sha1_of)"
        fi
        jq -nc --arg hash "$hash" --arg reviewer "$reviewer" --arg file "$file" \
          --arg claim "$claim_norm" --arg local_id "$local_id" \
          '{hash: $hash, reviewer: $reviewer, file: $file, claim: $claim,
            local_id: ($local_id | if . == "" then null else . end)}' >>"$dup_track"
      done < <(printf '%s' "$parsed" | jq -c '.[]')
    fi
  else
    echo "unparsed: $reviewer" >&2
  fi
done

if [[ "$n" -eq 0 ]]; then
  printf '{"findings":[]}\n' >"$out"
else
  jq -s -c 'add' "$work"/*.json | jq -c '{findings: .}' >"$out"
fi

# ── --emit-events: duplicate_merged detection ────────────────────────────────
if [[ -n "$emit_events_run_id" ]]; then
  if [[ "$sha1_available" != "true" ]]; then
    echo "WARN: merge_raw_findings: no sha1 tool found (need shasum, sha1sum, or openssl) — skipping duplicate_merged event detection" >&2
  elif [[ -s "$dup_track" ]]; then
    script_dir="$(cd "$(dirname "$0")" && pwd)"
    dup_events="$(jq -c -s '
      reduce .[] as $e (
        {seen: {}, events: []};
        if (.seen[$e.hash] // null) == null
        then .seen[$e.hash] = {first: $e.reviewer, sources: [$e.reviewer]}
        elif (.seen[$e.hash].sources | index($e.reviewer)) != null
        then .   # the same seat repeating itself is not an echo of another seat
        else (
          .seen[$e.hash].sources += [$e.reviewer]
          | .events += [{
              reviewer: $e.reviewer,
              first_reviewer: .seen[$e.hash].first,
              sources: .seen[$e.hash].sources,
              file: $e.file,
              claim_hash: $e.hash[0:8],
              local_id: $e.local_id
            }]
        )
        end
      ) | .events[]
    ' "$dup_track")"
    if [[ -z "$project" && -n "$dup_events" ]]; then
      echo "WARN: merge_raw_findings: no --project/--repo-root, duplicate_merged ids are f-dup-* and will not join fingerprinted findings" >&2
    fi
    while IFS= read -r ev; do
      [[ -z "$ev" ]] && continue
      if [[ -n "$project" ]]; then
        finding_id="f-$(jq -r '.claim_hash' <<<"$ev")"
      else
        finding_id="f-dup-$(jq -r '.claim_hash' <<<"$ev")"
      fi
      fields="$(jq -c '{reviewer, first_reviewer, sources, local_id, file, claim_hash}' <<<"$ev")"
      rc=0
      stderr_out="$(bash "$script_dir/append_finding_event.sh" --event duplicate_merged \
        --finding-id "$finding_id" --run-id "$emit_events_run_id" --fields "$fields" 2>&1 >/dev/null)" || rc=$?
      # a failure is a non-zero exit OR anything but the single success line
      # (a one-line bash redirect error used to slip past a line count)
      if [[ "$rc" -ne 0 || "$stderr_out" != "appended finding event:"* || "$(printf '%s\n' "$stderr_out" | grep -c .)" -gt 1 ]]; then
        echo "WARN: merge_raw_findings: event append failed for duplicate_merged finding_id=$finding_id: $stderr_out" >&2
      fi
    done < <(printf '%s\n' "$dup_events")
  fi
fi

exit 0
