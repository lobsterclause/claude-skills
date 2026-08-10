#!/usr/bin/env bash
# merge_gate.sh — PreToolUse hook: refuse `gh pr merge` when the PR's newest
# cross-review record is bound to a commit other than the one being merged.
#
# Why a hook and not a note in the skill: prose is advisory, and an agent that
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
#
# KNOWN LIMITS, stated rather than papered over:
#  * It decides from the command text. `gh api -X PUT .../merge`, a merge
#    inside a shell script, or the GitHub web UI all bypass it. The status
#    check is what covers those.
#  * A push landing between preflight's read and GitHub handling the merge
#    still merges unreviewed code (TOCTOU). Closing it means adding
#    `--match-head-commit <sha>` to the merge itself; this hook deliberately
#    does not rewrite the command, because another PreToolUse hook may already
#    be returning `updatedInput` and two rewriters would fight.

set -uo pipefail

payload="$(cat)"

pass() { echo '{}'; exit 0; }

# Cheap bail-out first — this hook sits on the Bash matcher, so it runs in
# front of every shell command in the session. `merge` is the cheapest
# whitespace-insensitive prefilter. It must NOT be the literal "gh pr merge":
# that let `gh  pr merge 123` (two spaces) through untouched, because the
# careful whitespace-flexible regex lives further down and never ran.
case "$payload" in
  *merge*) ;;
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
# values before matching, the same treatment kindred-mama-ai's promotion-gate
# hook needed for exactly this reason.
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
  ' | sed -E "s/--?(body|body-file|subject|title|message|m|b|t|F)[[:space:]]*=?[[:space:]]*'[^']*'//g; s/--?(body|body-file|subject|title|message|m|b|t|F)[[:space:]]*=?[[:space:]]*\"[^\"]*\"//g"
}

# Flatten to one line so a `gh pr merge` on line 3 cannot inherit a stray
# number from line 1 — that is how `timeout 300 pnpm test\ngh pr merge 3242`
# ended up asking about PR 300.
#
# Newlines become `;`, not spaces. A newline separates commands exactly as `;`
# does, and mapping it to a space instead fused the lines into one nonsense
# command (`... pnpm test gh pr merge 3242`) that the separator-anchored regex
# then declined to match at all — turning a wrong-PR bug into a total bypass.
cmd_only="$(scrub "$cmd" | tr '\n' ';')"

MERGE_RE='(^|[;&|(])[[:space:]]*gh[[:space:]]+pr[[:space:]]+merge([[:space:]]|$)'
printf '%s' "$cmd_only" | grep -qE "$MERGE_RE" || pass

# An explicit, auditable escape hatch. This is NOT a security boundary — the
# agent could write it unprompted — it is a way for the agent to carry out an
# instruction the user actually gave ("the delta is a rebase, merge it") while
# leaving the bypass visible in the command the user approves. Without one, the
# refusal below told the agent to do something no command could express.
case "$cmd_only" in
  *CROSS_REVIEW_MERGE_OVERRIDE=1*) pass ;;
esac

dequote() {
  local s="$1"
  case "$s" in
    '"'*'"') s="${s#\"}"; s="${s%\"}" ;;
    "'"*"'") s="${s#\'}"; s="${s%\'}" ;;
  esac
  printf '%s' "$s"
}

# Parse ONE `gh pr merge` invocation's arguments. Sets INV_PR / INV_REPO /
# INV_SKIP. Flag-value aware, because a positional scan that does not know
# which flags consume the next word mistakes that word for the PR reference.
INV_PR=""; INV_REPO=""; INV_SKIP=0
parse_invocation() {
  INV_PR=""; INV_REPO=""; INV_SKIP=0
  local expect="" tok
  set -f    # a token containing * or ? is data, not a glob
  for tok in $1; do
    tok="$(dequote "$tok")"
    if [[ -n "$expect" ]]; then
      [[ "$expect" == "repo" ]] && INV_REPO="$tok"
      expect=""
      continue
    fi
    case "$tok" in
      # Cancelling a queued auto-merge does not merge anything. Gating it meant
      # the one command that STOPS a stale merge was itself refused.
      --disable-auto) INV_SKIP=1 ;;
      -R|--repo)      expect=repo ;;
      --repo=*)       INV_REPO="$(dequote "${tok#--repo=}")" ;;
      -R=*)           INV_REPO="$(dequote "${tok#-R=}")" ;;
      -R?*)           INV_REPO="$(dequote "${tok#-R}")" ;;
      -b|--body|-F|--body-file|-t|--subject|--author-email|--match-head-commit)
                      expect=skipval ;;
      -*)             : ;;   # boolean flag
      # First positional is the PR reference: a number, a URL, or a branch
      # name — `gh pr view` resolves all three the same way `gh pr merge` does.
      *)              [[ -z "$INV_PR" ]] && INV_PR="$tok" ;;
    esac
  done
  set +f
}

# Every merge in a compound command gets checked, not just the last one.
# `gh pr merge 1 && gh pr merge 2` runs PR 1 first; checking only PR 2 let the
# stale one through.
#
# awk, not sed+split: BSD sed cannot emit a newline from a replacement, and
# splitting on a control-character IFS silently produced a single field (so
# every invocation was skipped and the gate passed everything — caught only
# because the baseline control went green too). Each line printed here is the
# command tail starting just after one `gh pr merge`; the leading `@` keeps an
# argument-less invocation from reading as a blank line.
invocations="$(printf '%s' "$cmd_only" | awk '
  {
    s = $0
    while (match(s, /(^|[;&|(])[[:space:]]*gh[[:space:]]+pr[[:space:]]+merge([[:space:]]|$)/)) {
      s = substr(s, RSTART + RLENGTH)
      print "@" s
    }
  }')"

verdict_json=""
while IFS= read -r args; do
  [[ -n "$args" ]] || continue
  args="${args#@}"
  # Arguments end at the next shell separator.
  args="${args%%;*}"; args="${args%%&*}"; args="${args%%|*}"; args="${args%%)*}"

  parse_invocation "$args"
  [[ "$INV_SKIP" -eq 1 ]] && continue

  pr_ref="$INV_PR"
  if [[ -z "$pr_ref" ]]; then
    pr_ref="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
    [[ -n "$pr_ref" && "$pr_ref" != "HEAD" ]] || continue
  fi

  if [[ -n "$INV_REPO" ]]; then
    result="$(bash "$preflight" --pr "$pr_ref" --repo "$INV_REPO" --json 2>/dev/null || true)"
  else
    result="$(bash "$preflight" --pr "$pr_ref" --json 2>/dev/null || true)"
  fi
  [[ -n "$result" ]] || continue

  if [[ "$(printf '%s' "$result" | jq -r '.status // ""' 2>/dev/null || true)" == "stale" ]]; then
    verdict_json="$result"
    break
  fi
done <<EOF
$invocations
EOF

[[ -n "$verdict_json" ]] || pass

reviewed="$(printf '%s' "$verdict_json" | jq -r '.reviewed // ""' 2>/dev/null || true)"
head="$(printf '%s' "$verdict_json" | jq -r '.head // ""' 2>/dev/null || true)"
which_pr="$(printf '%s' "$verdict_json" | jq -r '.pr // ""' 2>/dev/null || true)"

reason="Cross-review is stale for PR ${which_pr}.

The newest cross-review record covers ${reviewed}, but the head you are about to merge is ${head:0:9}. The commits in between were never reviewed — this is the exact failure mode that landed a High-severity navigation race on develop (kindred-mama-ai #3243).

Do one of:
  1. Re-run cross-review against the current head, then merge.
  2. If the delta is genuinely trivial (a rebase, a typo, a lockfile), say so to the user, and merge only once they agree by prefixing the command with CROSS_REVIEW_MERGE_OVERRIDE=1 — which leaves the bypass visible in what they approve.

Do not re-issue this command unchanged."

jq -n --arg r "$reason" '{
  hookSpecificOutput: {
    hookEventName: "PreToolUse",
    permissionDecision: "deny",
    permissionDecisionReason: $r
  }
}'
