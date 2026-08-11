#!/usr/bin/env bash
# reconcile.sh — find cross-review runs whose findings never reached GitHub.
#
#   reconcile.sh [--runs-root DIR] [--repo owner/name] [--limit N] [--json] [--post]
#
# A review that ran but never posted is invisible: the PR looks unreviewed, the
# cross-review/current status check reports "no cross-review record", and the
# 68-676KB of reviewer output sits on disk where nothing reads it. On 2026-08-11
# six kindred-mama-ai PRs were in exactly that state (#3214, #3252, #3264,
# #3269, #3276, #3280) — all six real reviews, none of them visible.
#
# This walks the run dirs and says which ones are droppable. It is REPORT-ONLY
# by default. --post is opt-in because posting a comment is an outward-facing
# act against someone else's PR, and doing it as a side effect of a scan is the
# wrong default no matter how confident the classification is.
#
# States:
#   posted          posted.json says the comment went up — nothing to do
#   deliberate      caller asked for --mode file/none — not a drop, leave alone
#   droppable       meant to post, didn't, and we know the SHA → --post can fix
#   unattributable  meant to post, didn't, and the reviewed SHA was never
#                   recorded → CANNOT be posted truthfully, needs a re-review
#   unreviewed      no reviewer output — an aborted run, not a drop
#
# Exit codes: 0 nothing droppable, 1 droppable runs found, 2 usage error.

set -uo pipefail

runs_root="${CROSS_REVIEW_RUN_ROOT:-$HOME/.cross-review/runs}"
repo_filter=""
limit=0
as_json=0
do_post=0

need_val() { [[ "$2" -ge 2 ]] || { echo "$1 requires a value" >&2; exit 2; }; }

# Parsing lives in a function so `source`ing this file to test classify_run
# does not run the CLI against the sourcing script's own arguments.
parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --runs-root) need_val --runs-root "$#"; runs_root="$2"; shift 2 ;;
      --repo)      need_val --repo      "$#"; repo_filter="$2"; shift 2 ;;
      --limit)     need_val --limit     "$#"; limit="$2"; shift 2 ;;
      --json)      as_json=1; shift ;;
      --post)      do_post=1; shift ;;
      -h|--help)   sed -n '2,28p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
      *) echo "unknown flag: $1" >&2; exit 2 ;;
    esac
  done
  [[ "$limit" =~ ^[0-9]+$ ]] || { echo "--limit must be a non-negative integer" >&2; exit 2; }
}

# Tab is IFS *whitespace*, so bash collapses a run of them into one delimiter
# and an empty field vanishes: a run with no recorded SHA shifted `detail` into
# `sha` and printed the first 9 chars of the reason where the SHA belonged.
# \037 is not whitespace, so each occurrence delimits exactly one field.
US=$'\037'

jqr() {  # jqr <file> <filter> — "" when the file is missing or unparseable.
  [[ -f "$1" ]] || { printf ''; return 0; }
  jq -r "$2 // \"\"" "$1" 2>/dev/null || printf ''
}

# classify_run <dir> → "<state>\037<pr>\037<head_sha>\037<detail>"
# Sourceable and side-effect free, so the tests exercise the real decision
# rather than a paraphrase of it.
classify_run() {
  local d="$1"
  local ctx="$d/context.json" posted="$d/posted.json"
  local head_sha pr repo id reason was_posted

  head_sha="$(jqr "$ctx" '.head_sha')"
  repo="$(jqr "$ctx" '.repo')"
  id="$(jqr "$ctx" '.id')"

  # PR number from context.json's id ("pr-3280"), else from the run dir name.
  pr=""
  [[ "$id" =~ pr-([0-9]+) ]] && pr="${BASH_REMATCH[1]}"
  [[ -z "$pr" && "$(basename "$d")" =~ -pr-([0-9]+) ]] && pr="${BASH_REMATCH[1]}"

  if [[ -n "$repo_filter" && "$repo" != "$repo_filter" ]]; then
    printf "filtered${US}%s${US}%s${US}%s\n" "$pr" "$head_sha" "repo=$repo"; return 0
  fi

  was_posted="$(jqr "$posted" '.posted')"
  reason="$(jqr "$posted" '.reason')"

  if [[ "$was_posted" == "true" ]]; then
    printf "posted${US}%s${US}%s${US}%s\n" "$pr" "$head_sha" "$(jqr "$posted" '.comment_url')"; return 0
  fi
  if [[ "$reason" == "file-mode" || "$reason" == "mode-none" ]]; then
    printf "deliberate${US}%s${US}%s${US}%s\n" "$pr" "$head_sha" "$reason"; return 0
  fi

  # No reviewer output means the run died before reviewing — there is nothing to
  # post, and calling that a drop would bury the real ones in noise.
  local n_out=0
  if [[ -d "$d/raw" ]]; then
    n_out="$(find "$d/raw" -maxdepth 1 -name '*.stdout' -size +0 2>/dev/null | wc -l | tr -d ' ')"
  fi
  if [[ "${n_out:-0}" -eq 0 ]]; then
    printf "unreviewed${US}%s${US}%s${US}%s\n" "$pr" "$head_sha" "no reviewer output"; return 0
  fi

  # A post needs a PR, a body, and a SHA to stamp. Missing the SHA is the
  # interesting case: the review is real but can never be attributed to a
  # commit, so re-posting it would be a guess wearing a stamp's authority.
  local detail="${reason:-never reached post_comment.sh}"
  if [[ -z "$head_sha" || -z "$pr" || ! -f "$d/findings.md" ]]; then
    local why=""
    [[ -z "$head_sha" ]] && why="no reviewed SHA recorded"
    [[ -z "$pr" ]] && why="${why:+$why; }no PR number"
    [[ ! -f "$d/findings.md" ]] && why="${why:+$why; }no findings.md"
    printf "unattributable${US}%s${US}%s${US}%s\n" "$pr" "$head_sha" "$why ($detail)"; return 0
  fi

  printf "droppable${US}%s${US}%s${US}%s\n" "$pr" "$head_sha" "$detail"
}

main() {
  local droppable=0 rows=() n=0
  while IFS= read -r d; do
    [[ -d "$d" ]] || continue
    [[ "$limit" -gt 0 && "$n" -ge "$limit" ]] && break
    local line state pr sha detail
    line="$(classify_run "$d")"
    IFS="$US" read -r state pr sha detail <<<"$line"
    [[ "$state" == "filtered" ]] && continue
    n=$((n + 1))
    [[ "$state" == "droppable" ]] && droppable=$((droppable + 1))
    rows+=("$state$US$pr$US$sha$US$detail$US$d")
  done < <(find "$runs_root" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | sort -r)

  if [[ "$as_json" -eq 1 ]]; then
    printf '['
    local first=1 r
    for r in ${rows[@]+"${rows[@]}"}; do
      IFS="$US" read -r state pr sha detail dir <<<"$r"
      [[ "$first" -eq 1 ]] || printf ','
      first=0
      jq -nc --arg s "$state" --arg p "$pr" --arg h "$sha" --arg d "$detail" --arg dir "$dir" \
        '{state:$s, pr:$p, head_sha:$h, detail:$d, run_dir:$dir}'
    done
    printf ']\n'
  else
    local r
    for r in ${rows[@]+"${rows[@]}"}; do
      IFS="$US" read -r state pr sha detail dir <<<"$r"
      # Only the states worth a human's attention; posted/unreviewed are noise.
      case "$state" in
        droppable|unattributable)
          printf '%-15s PR %-6s %-10s %s\n    %s\n' "$state" "${pr:--}" "${sha:0:9}" "$detail" "$dir" ;;
      esac
    done
    printf '\n%d droppable, %d scanned under %s\n' "$droppable" "$n" "$runs_root"
  fi

  if [[ "$do_post" -eq 1 && "$droppable" -gt 0 ]]; then
    local r
    for r in ${rows[@]+"${rows[@]}"}; do
      IFS="$US" read -r state pr sha detail dir <<<"$r"
      [[ "$state" == "droppable" ]] || continue
      echo "posting reconciled review for PR #$pr from $dir" >&2
      # The stamp carries the SHA actually reviewed, so a late post is still a
      # truthful one — and if the head has moved since, post_comment.sh's own
      # staleness banner says so and the currency check goes red. That red is
      # the correct outcome, not a regression.
      bash "$(dirname "${BASH_SOURCE[0]}")/post_comment.sh" \
        --pr "$pr" --mode summary --findings "$dir/findings.md" --head-sha "$sha" >&2
    done
  fi

  [[ "$droppable" -gt 0 ]] && return 1
  return 0
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  parse_args "$@"
  if [[ ! -d "$runs_root" ]]; then
    echo "no runs directory at $runs_root — nothing to reconcile" >&2
    exit 0
  fi
  main
fi
