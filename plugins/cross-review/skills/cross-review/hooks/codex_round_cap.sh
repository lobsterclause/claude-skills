#!/usr/bin/env bash
# codex_round_cap.sh — PreToolUse hook (Bash): refuse to ask Codex (the
# chatgpt-codex-connector app) for another review of a PR that has already had
# CODEX_ROUND_CAP of them (default 3). SKILL.md, step 6: "Iteration cap".
#
# Why: the skill capped its own fleet at 3 passes, but the GitHub Codex loop
# (`@codex review` → fix → `@codex review` …) had no cap at all, and merge_gate
# blocks the merge until every Codex thread is cleared, so each round invites
# the next. On 2026-10-04 firebird-minecraft #44 ran 19 rounds (24 findings,
# ~9.5 h) and #78 ran 10, each finding one narrower real issue while the
# feature waited. The owner's rule is 3. After the third: fix or answer the
# open findings, resolve the threads, and merge on green CI pinned to the head.
#
# What it gates: a command that posts a comment containing "@codex review" on
# a PR — `gh pr comment <n|branch|url> … --body …` or `gh api …/issues/<n>/
# comments …`. It counts the PR's reviews by the Codex app and denies at or
# over the cap. Anything else passes untouched.
#
# CODEX_ROUND_CAP=N in the hook's environment changes the cap. There is no
# per-command bypass: going past the cap is the user's call, so the denial
# says to ask them.
#
# Fails OPEN: no jq, no gh, an unresolvable PR or repo, or an API error all
# pass. A cap that blocked work whenever GitHub hiccuped would get switched
# off; a missed count costs one extra round, which is the status quo.
# Like merge_gate.sh it decides from the command text, so a comment posted
# from inside a script it cannot read is not counted.
#
# Wire it up in ~/.claude/settings.json next to merge_gate.sh:
#   { "matcher": "Bash", "hooks": [ { "type": "command",
#       "command": "/Users/<you>/.claude/skills/cross-review/hooks/codex_round_cap.sh" } ] }

set -uo pipefail

payload="$(cat)"
pass() { echo '{}'; exit 0; }
deny() {
  jq -n --arg r "$1" '{hookSpecificOutput: {hookEventName: "PreToolUse",
    permissionDecision: "deny", permissionDecisionReason: $r}}'
  exit 0
}

# Cheap prefilter: this sits on every Bash command.
case "$payload" in
  *@codex*|*@Codex*|*@CODEX*) ;;
  *) pass ;;
esac
command -v jq >/dev/null 2>&1 || pass
command -v gh >/dev/null 2>&1 || pass

cmd="$(printf '%s' "$payload" | jq -r '.tool_input.command // "" | tostring' 2>/dev/null)"
cwd="$(printf '%s' "$payload" | jq -r '.cwd // empty' 2>/dev/null)"
[[ -n "$cmd" ]] || pass
shopt -s nocasematch
[[ "$cmd" =~ @codex[[:space:]]+review ]] || pass
shopt -u nocasematch

cap="${CODEX_ROUND_CAP:-3}"
[[ "$cap" =~ ^[0-9]+$ ]] || cap=3

repo="" pr=""
# --repo / -R names the repository; a repos/O/R path in a gh api call does too.
if [[ "$cmd" =~ (--repo[=[:space:]]+|-R[[:space:]]+)([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+) ]]; then
  repo="${BASH_REMATCH[2]}"
fi
if [[ "$cmd" =~ repos/([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)/issues/([0-9]+)/comments ]]; then
  repo="${BASH_REMATCH[1]}"; pr="${BASH_REMATCH[2]}"
elif [[ "$cmd" =~ gh[[:space:]]+pr[[:space:]]+comment[[:space:]]+([^-[:space:]][^[:space:]]*) ]]; then
  pr="${BASH_REMATCH[1]}"
  pr="${pr%\"}"; pr="${pr#\"}"; pr="${pr%\'}"; pr="${pr#\'}"
else
  pass
fi
[[ -n "$pr" ]] || pass

ghc() { if [[ -n "$cwd" ]]; then (cd "$cwd" 2>/dev/null && gh "$@"); else gh "$@"; fi; }
if [[ -z "$repo" ]]; then
  repo="$(ghc repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null)" || pass
  [[ -n "$repo" ]] || pass
fi
# A branch name or URL: let gh resolve it to a number.
if ! [[ "$pr" =~ ^[0-9]+$ ]]; then
  pr="$(ghc pr view "$pr" --repo "$repo" --json number -q .number 2>/dev/null)" || pass
  [[ "$pr" =~ ^[0-9]+$ ]] || pass
fi

rounds="$(gh api --paginate "repos/$repo/pulls/$pr/reviews" \
  -q '[.[] | select(.user.login | test("^chatgpt-codex-connector"))] | length' 2>/dev/null \
  | awk '{ s += $1 } END { print s + 0 }')" || pass
[[ "$rounds" =~ ^[0-9]+$ ]] || pass
(( rounds >= cap )) || pass

deny "Codex review cap reached: $repo#$pr has had $rounds Codex review(s); the cap is $cap (cross-review SKILL.md, \"Iteration cap\"). Do not request another. Fix or answer the open Codex findings, reply on and resolve each thread, then merge on green CI pinned to the head (--match-head-commit). If a finding needs a decision, or you think one more round is worth it, ask the user."
