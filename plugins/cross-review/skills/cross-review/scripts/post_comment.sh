#!/usr/bin/env bash
# post_comment.sh — post the synthesized findings to a PR, or save locally.
#
# Usage:
#   post_comment.sh --pr <n> --mode <summary|file|none> --findings <path> [--pass <n>]
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
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

if [[ -z "$findings" ]]; then
  echo "usage: $0 --pr <n> --mode <summary|file|none> --findings <path> [--pass <n>]" >&2
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
    body_file="$(mktemp)"
    # Ensure the body file is always cleaned up, even if gh call fails or the
    # script is interrupted. Previous version only rm'd on the happy path.
    trap 'rm -f "$body_file"' EXIT
    {
      printf '## Cross-review — pass %s\n\n' "$pass"
      printf '_Automated review by codex + gemini. See the "Findings" collapsible for specifics._\n\n'
      printf '<details><summary>Findings</summary>\n\n'
      cat "$findings"
      printf '\n</details>\n'
    } >"$body_file"
    # If `gh pr comment` itself fails (network blip, rate limit, PR closed
    # mid-run, transient GitHub outage), degrade gracefully to file mode
    # rather than failing the whole review run. The findings.md is already
    # on disk at $findings — the user still has the record.
    if gh pr comment "$pr" --body-file "$body_file"; then
      exit 0
    else
      echo "gh pr comment failed — findings preserved at: $findings" >&2
      exit 0
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