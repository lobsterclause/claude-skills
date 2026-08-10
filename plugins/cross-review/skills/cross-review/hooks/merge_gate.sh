#!/usr/bin/env bash
# merge_gate.sh — PreToolUse hook: refuse `gh pr merge` when the PR's newest
# cross-review record is bound to a commit other than the one being merged.
#
# Why a hook and not a note in CLAUDE.md: prose is advisory, and an agent that
# can forget it will. The harness runs this regardless of what the agent
# believes, which is the difference between a rule and a habit.
#
# Wire it up in ~/.claude/settings.json:
#
#   { "hooks": { "PreToolUse": [
#       { "matcher": "Bash", "hooks": [
#           { "type": "command",
#             "command": "/Users/<you>/.claude/skills/cross-review/hooks/merge_gate.sh" } ] } ] } }
#
# Scope: this blocks the agent, not the human. A person running `gh pr merge`
# in their own terminal never touches this hook, and neither does automerge.
# Covering those means a GitHub status check computing the same comparison.

set -uo pipefail

payload="$(cat)"

pass() { echo '{}'; exit 0; }

# Cheap bail-out first — this hook is on the Bash matcher, so it runs in front
# of every shell command in the session. Everything below is conditional on the
# string already being present.
case "$payload" in
  *"gh pr merge"*) ;;
  *) pass ;;
esac

command -v jq >/dev/null 2>&1 || pass

cmd="$(printf '%s' "$payload" | jq -r '.tool_input.command // ""' 2>/dev/null || true)"
[[ -n "$cmd" ]] || pass

hook_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
preflight="$hook_dir/../scripts/merge_preflight.sh"
[[ -f "$preflight" ]] || pass

# Text that merely *quotes* the command must not trip the gate — a commit
# message explaining a merge, or a PR body describing this very hook, both
# contain the literal string. Strip heredoc bodies and message-carrying flag
# values before matching, same treatment kindred-mama-ai's promotion-gate hook
# needed for exactly this reason.
scrub() {
  printf '%s' "$1" | awk '
    BEGIN { in_doc = 0 }
    {
      if (in_doc) {
        if ($0 ~ tag_re) in_doc = 0
        next
      }
      if (match($0, /<<-?[\047"]?[A-Za-z_][A-Za-z0-9_]*[\047"]?/)) {
        tag = substr($0, RSTART, RLENGTH)
        gsub(/<<-?/, "", tag)
        gsub(/[\047"]/, "", tag)
        tag_re = "^[[:space:]]*" tag "[[:space:]]*$"
        in_doc = 1
      }
      print
    }
  ' | sed -E "s/--?(body|body-file|subject|title|message|m|b|t|F)[[:space:]]+'[^']*'//g; s/--?(body|body-file|subject|title|message|m|b|t|F)[[:space:]]+\"[^\"]*\"//g"
}

cmd_only="$(scrub "$cmd")"
printf '%s' "$cmd_only" | grep -qE '(^|[;&|(]|\s)gh\s+pr\s+merge(\s|$)' || pass

# Pull the PR reference out of the tail of the command: `gh pr merge 123`,
# `gh pr merge --squash 123`, or a pull URL. An absent reference means "the
# current branch's PR", which `gh pr view` resolves the same way `gh pr merge`
# would — so hand it the branch and let gh do the lookup.
tail_args="$(printf '%s' "$cmd_only" | sed -E 's/.*gh[[:space:]]+pr[[:space:]]+merge[[:space:]]*//')"
pr_ref=""
for tok in $tail_args; do
  case "$tok" in
    [0-9]*[0-9]|[0-9]) [[ "$tok" =~ ^[0-9]+$ ]] && { pr_ref="$tok"; break; } ;;
    *github.com/*/pull/*) pr_ref="$tok"; break ;;
    -*) continue ;;
  esac
done
if [[ -z "$pr_ref" ]]; then
  pr_ref="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
  # Detached HEAD, or not a repo at all: nothing to resolve, nothing to gate.
  [[ -n "$pr_ref" && "$pr_ref" != "HEAD" ]] || pass
fi

repo_flag=""
repo_val="$(printf '%s' "$cmd_only" | sed -nE 's/.*--repo[= ]+([^ ]+).*/\1/p' | head -1)"
[[ -n "$repo_val" ]] && repo_flag="$repo_val"

# The preflight fails open on every ambiguity; only exit 1 means "a review
# record exists and it does not cover this commit".
if [[ -n "$repo_flag" ]]; then
  result="$(bash "$preflight" --pr "$pr_ref" --repo "$repo_flag" --json 2>/dev/null || true)"
else
  result="$(bash "$preflight" --pr "$pr_ref" --json 2>/dev/null || true)"
fi
[[ -n "$result" ]] || pass

status="$(printf '%s' "$result" | jq -r '.status // ""' 2>/dev/null || true)"
[[ "$status" == "stale" ]] || pass

reviewed="$(printf '%s' "$result" | jq -r '.reviewed // ""' 2>/dev/null || true)"
head="$(printf '%s' "$result" | jq -r '.head // ""' 2>/dev/null || true)"

reason="Cross-review is stale for this PR.

The newest cross-review record covers ${reviewed}, but the head you are about to merge is ${head:0:9}. The commits in between were never reviewed — this is the exact failure mode that landed a High-severity navigation race on develop (kindred-mama-ai #3243).

Do one of:
  1. Re-run cross-review against the current head, then merge.
  2. If the delta is genuinely trivial (a rebase, a typo, a lockfile), say so to the user and ask them to authorize the merge anyway.

Do not re-issue this command unchanged."

jq -n --arg r "$reason" '{
  hookSpecificOutput: {
    hookEventName: "PreToolUse",
    permissionDecision: "deny",
    permissionDecisionReason: $r
  }
}'
