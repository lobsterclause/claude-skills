#!/usr/bin/env bash
# check_repeat_pass.sh — refuse a re-review pass that re-reads a diff already
# reviewed, and tell the caller which base it should have used instead.
#
# THE RULE THIS ENFORCES (SKILL.md, "Re-review loop"):
#
#   pass the *previous pass's HEAD* as --base so reviewers see only the fix
#   commits ... A re-pass is answering a narrow question, not re-finding
#   everything.
#
# That rule was prose, and prose is advisory. Measured on runlog.jsonl
# 2026-08-29: 43 multi-pass PRs in August (29% of the month's multi-pass
# rounds) re-ran pass 2+ against the SAME base as pass 1. Because fixes ADD
# lines, the re-read diff grows every pass — PR #2168 went 7,777 -> 7,866 ->
# 7,976 lines, so codex read ~23,600 lines to review ~200 new ones. Total
# across the sample: 162,929 diff lines re-read for nothing.
#
# WHY ITS OWN STATE, NOT runlog.jsonl:
#
#   - runlog's `wrapper_branch` is the SKILL's branch (always "master"), not
#     the subject repo's — it cannot identify which branch was reviewed.
#   - Keying on project+base alone would false-positive on every PR in a repo,
#     because they all share one base (`origin/develop`). The subject branch is
#     the only thing that separates them, and the runlog does not record it.
#
#   So the guard keeps a small record per (project, subject branch). It is
#   advisory state: losing it fails OPEN (a missing record allows the round).
#
# WHAT COUNTS AS A VIOLATION: a recorded round exists for this project+branch,
# its base is the SAME as the one now requested, AND HEAD has moved since. The
# moved-HEAD condition is what separates a genuine repeat pass (new fix
# commits, same base = full re-review) from re-running an identical round after
# a crash or a timeout, which must stay allowed.
#
# usage:
#   check_repeat_pass.sh --project <p> --branch <b> --base-sha <sha> --head-sha <sha>
#                        [--state-dir <d>] [--window-hours <n>] [--allow-full-rereview]
#   check_repeat_pass.sh --record --project <p> --branch <b> --base-sha <sha> --head-sha <sha>
#
# exit 0 — proceed (no prior round, incremental base, retry, stale, or override)
# exit 3 — blocked: this is a full re-review of an already-reviewed diff
# exit 2 — usage error
#
# Overrides (SKILL.md allows a deliberate full re-review "when the fixes were
# structural enough to invalidate the original review's context"):
#   --allow-full-rereview   or   CROSS_REVIEW_ALLOW_FULL_REREVIEW=1

set -uo pipefail

project=""; branch=""; base_sha=""; head_sha=""
state_dir=""; window_hours="${CROSS_REVIEW_REPEAT_WINDOW_HOURS:-24}"
record=0; allow="${CROSS_REVIEW_ALLOW_FULL_REREVIEW:-0}"

need_val() { [[ "$2" -ge 2 ]] || { echo "$1 requires a value" >&2; exit 2; }; }
while [[ $# -gt 0 ]]; do
  case "$1" in
    --project)             need_val "$1" "$#"; project="$2";      shift 2 ;;
    --branch)              need_val "$1" "$#"; branch="$2";       shift 2 ;;
    --base-sha)            need_val "$1" "$#"; base_sha="$2";     shift 2 ;;
    --head-sha)            need_val "$1" "$#"; head_sha="$2";     shift 2 ;;
    --state-dir)           need_val "$1" "$#"; state_dir="$2";    shift 2 ;;
    --window-hours)        need_val "$1" "$#"; window_hours="$2"; shift 2 ;;
    --record)              record=1; shift ;;
    --allow-full-rereview) allow=1;  shift ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

# Fall back to git only for what the caller omitted, so the guard is fully
# testable without a repo (and usable from inside one without plumbing).
[[ -z "$project"  ]] && project="$(basename "$(git rev-parse --show-toplevel 2>/dev/null || pwd)")"
[[ -z "$branch"   ]] && branch="$(git branch --show-current 2>/dev/null || echo detached)"
[[ -z "$head_sha" ]] && head_sha="$(git rev-parse HEAD 2>/dev/null || echo unknown)"
if [[ -z "$project" || -z "$branch" || -z "$base_sha" || -z "$head_sha" ]]; then
  echo "usage: $0 --project <p> --branch <b> --base-sha <sha> --head-sha <sha> [--record]" >&2
  exit 2
fi

skill_dir="$(cd "$(dirname "$0")/.." && pwd)"
[[ -z "$state_dir" ]] && state_dir="${CROSS_REVIEW_STATE_DIR:-$skill_dir/state}/last_base"

# Flatten the key: a branch name legitimately contains '/', which would
# otherwise create nested directories (and `feat/a` + a file named `a` under
# `feat` can collide). Anything outside [A-Za-z0-9._-] becomes '_', and a
# short digest keeps distinct names that flatten alike from colliding.
key_of() {
  local raw="$1" flat digest
  flat="$(printf '%s' "$raw" | tr -c 'A-Za-z0-9._-' '_')"
  digest="$(printf '%s' "$raw" | (shasum -a 256 2>/dev/null || sha256sum) | cut -c1-8)"
  # Cap the readable half so a very long branch name cannot blow the filename
  # limit; the digest carries uniqueness regardless.
  printf '%s.%s' "${flat:0:80}" "$digest"
}
key="$(key_of "${project}//${branch}")"
rec="$state_dir/$key.json"

now_epoch="$(date +%s)"

if [[ "$record" == 1 ]]; then
  mkdir -p "$state_dir" || exit 0   # advisory state: never fail the round
  printf '{"project":%s,"branch":%s,"base_sha":%s,"head_sha":%s,"epoch":%s}\n' \
    "\"$project\"" "\"$branch\"" "\"$base_sha\"" "\"$head_sha\"" "$now_epoch" \
    > "$rec" 2>/dev/null || true
  exit 0
fi

[[ -f "$rec" ]] || exit 0                      # no prior round -> first pass

prev_base="$(sed -n 's/.*"base_sha":"\([^"]*\)".*/\1/p' "$rec" 2>/dev/null)"
prev_head="$(sed -n 's/.*"head_sha":"\([^"]*\)".*/\1/p' "$rec" 2>/dev/null)"
prev_epoch="$(sed -n 's/.*"epoch":\([0-9]*\).*/\1/p' "$rec" 2>/dev/null)"
[[ -n "$prev_base" && -n "$prev_head" && -n "$prev_epoch" ]] || exit 0

# Stale records must not block forever — a branch legitimately revisited days
# later is a new review, not a repeat pass.
case "$window_hours" in ''|*[!0-9]*) window_hours=24 ;; esac
if (( now_epoch - prev_epoch >= window_hours * 3600 )); then exit 0; fi

[[ "$base_sha" == "$prev_base" ]] || exit 0    # base advanced -> incremental
[[ "$head_sha" != "$prev_head" ]] || exit 0    # HEAD unmoved -> retry, allow

if [[ "$allow" == 1 ]]; then
  echo "check_repeat_pass: full re-review of the same base — allowed by override" >&2
  exit 0
fi

cat >&2 <<MSG
check_repeat_pass: REFUSING a full re-review.

  project/branch : $project / $branch
  requested base : $base_sha
  already reviewed at this base, HEAD was: $prev_head
  HEAD is now    : $head_sha

This round would re-read every line the previous pass already reviewed, plus
the fix commits. SKILL.md's re-review loop asks for the previous pass's HEAD
as the base so reviewers see only what changed.

  Re-run with:  --base $prev_head

If the fixes were structural enough to invalidate the previous review's
context, a full re-review is the right call — say so explicitly:

  --allow-full-rereview     (or CROSS_REVIEW_ALLOW_FULL_REREVIEW=1)
MSG
exit 3
