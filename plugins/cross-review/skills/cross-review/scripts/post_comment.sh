#!/usr/bin/env bash
# post_comment.sh — post the synthesized findings to a PR, or save locally.
#
# Usage:
#   post_comment.sh --pr <n> --mode <summary|file|none> --findings <path> [--pass <n>]
#                   [--head-sha <sha>]
#
# --head-sha stamps the record with the commit that was actually reviewed, and
# compares it against the PR's live head at post time. Without it a review
# comment reads as authoritative about whatever the PR contains *now*, which is
# how a confirmed finding got silently discarded: on kindred-mama-ai#3207 the
# head moved four times in one session, one push reverted a two-provider P1 fix
# and deleted its regression test, and the posted record never said which
# commit it covered. The same PR was merged 19 minutes BEFORE its review
# posted, so this also flags an already-merged PR.
#
# - summary:  one consolidated `gh pr comment` on the PR conversation
# - file:     write only; no GitHub call (findings already on disk at --findings path)
# - none:     no-op
#
# If no PR number is given or `gh` can't reach it, falls back to `file` mode.

set -uo pipefail

pr=""
mode="summary"
findings=""
pass="1"
head_sha=""

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
    --pr)       need_val --pr       "$#"; pr="$2";       shift 2 ;;
    --mode)     need_val --mode     "$#"; mode="$2";     shift 2 ;;
    --findings) need_val --findings "$#"; findings="$2"; shift 2 ;;
    --pass)     need_val --pass     "$#"; pass="$2";     shift 2 ;;
    --head-sha) need_val --head-sha "$#"; head_sha="$2"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

if [[ -z "$findings" ]]; then
  echo "usage: $0 --pr <n> --mode <summary|file|none> --findings <path> [--pass <n>] [--head-sha <sha>]" >&2
  exit 2
fi

if [[ ! -f "$findings" ]]; then
  echo "findings file not found: $findings" >&2
  exit 2
fi

if [[ "$mode" == "none" ]]; then
  exit 0
fi

# Fall back to file mode when there's no PR or no gh auth.
if [[ "$mode" == "summary" ]]; then
  if [[ -z "$pr" ]] || ! command -v gh >/dev/null 2>&1 || ! gh auth status >/dev/null 2>&1; then
    echo "gh unavailable or no PR number — falling back to file mode" >&2
    mode="file"
  fi
fi

case "$mode" in
  summary)
    # Template + rc check (issue #7 nit): BSD/GNU mktemp default templates
    # differ, and an unchecked failure would send an empty --body-file.
    body_file="$(mktemp -t cr-comment.XXXXXX)" || { echo "mktemp failed" >&2; exit 1; }
    # Ensure the body file is always cleaned up, even if gh call fails or the
    # script is interrupted. Previous version only rm'd on the happy path.
    trap 'rm -f "$body_file"' EXIT
    # Derive the roster from the run dir's meta files — under rotation the
    # fleet varies per round, so a hardcoded list is frequently wrong (fugu
    # finding, PR #18 pass 1). findings.md lives at $run_dir/findings.md and
    # the wrapper writes $run_dir/raw/<reviewer>.meta.json per reviewer ran.
    roster_line=""
    raw_dir="$(dirname "$findings")/raw"
    if [[ -d "$raw_dir" ]]; then
      for m in "$raw_dir"/*.meta.json; do
        [[ -f "$m" ]] || continue
        n="$(basename "$m" .meta.json)"
        [[ "$n" == *.agy-failed ]] && continue
        roster_line="${roster_line:+$roster_line + }$n"
      done
    fi
    [[ -z "$roster_line" ]] && roster_line="external reviewers"

    # Provenance + staleness. A review record is read long after it is posted,
    # so it must say what it covered. Every query below fails OPEN: if `gh` or
    # `jq` is unavailable the comment still posts, just without the banner.
    provenance=""
    [[ -n "$head_sha" ]] && provenance="Reviewed \`${head_sha:0:9}\`."
    staleness=""
    if command -v jq >/dev/null 2>&1; then
      pr_meta="$(gh pr view "$pr" --json headRefOid,state 2>/dev/null || true)"
      if [[ -n "$pr_meta" ]]; then
        cur_sha="$(printf '%s' "$pr_meta" | jq -r '.headRefOid // ""' 2>/dev/null || true)"
        pr_state="$(printf '%s' "$pr_meta" | jq -r '.state // ""' 2>/dev/null || true)"
        if [[ "$pr_state" == "MERGED" ]]; then
          staleness+="> [!WARNING]"$'\n'"> **This PR was already merged before the review finished.** Any finding below is describing code that is already on the base branch — it needs a follow-up PR, not a change here."$'\n\n'
        elif [[ "$pr_state" == "CLOSED" ]]; then
          staleness+="> [!WARNING]"$'\n'"> **This PR was closed before the review finished.**"$'\n\n'
        fi
        if [[ -n "$head_sha" && -n "$cur_sha" && "$cur_sha" != "$head_sha" ]]; then
          staleness+="> [!WARNING]"$'\n'"> **Stale: the head moved during this review.** Reviewed \`${head_sha:0:9}\`, current head is \`${cur_sha:0:9}\`. Findings below may describe code that no longer exists, and fixes confirmed here may have been overwritten. Re-review before trusting this record."$'\n\n'
        fi
      fi
    fi

    {
      printf '## Cross-review — pass %s\n\n' "$pass"
      [[ -n "$staleness" ]] && printf '%s' "$staleness"
      printf '_Automated review by %s.%s See the "Findings" collapsible for specifics._\n\n' "$roster_line" "${provenance:+ $provenance}"
      printf '<details><summary>Findings</summary>\n\n'
      cat "$findings"
      printf '\n</details>\n'
    } >"$body_file"
    # If `gh pr comment` itself fails (network blip, rate limit, PR closed
    # mid-run, transient GitHub outage), degrade gracefully to file mode
    # rather than failing the whole review run. The findings.md is already
    # on disk at $findings — the user still has the record.
    if gh pr comment "$pr" --body-file "$body_file"; then
      exit 0   # posted OK
    else
      # Non-zero exit (issue #7 nit): a silent 0 here masked real auth/rate
      # problems. The findings file is the fallback record either way.
      echo "ACTION REQUIRED: gh pr comment failed (auth? rate limit? closed PR?) — findings preserved at: $findings" >&2
      exit 1
    fi
    ;;
  inline)
    # Removed in favor of summary: 5–10× API calls for little extra signal.
    # If reintroduced, post via `gh api repos/{owner}/{repo}/pulls/{pr}/comments`
    # per finding, keyed off <!-- file:... line:... --> sentinels in findings.md.
    echo "'inline' mode was removed — use 'summary' instead. File:line refs already live in the summary body." >&2
    exit 2
    ;;
  file)
    # Findings file already exists at $findings — nothing to do.
    echo "findings saved to: $findings" >&2
    exit 0
    ;;
  *)
    echo "unknown mode: $mode" >&2
    exit 2
    ;;
esac