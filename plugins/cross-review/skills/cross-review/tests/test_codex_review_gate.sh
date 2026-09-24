#!/usr/bin/env bash
# test_codex_review_gate.sh — fixture tests for codex_review_preflight.sh and
# the Codex half of hooks/merge_gate.sh: uncleared Codex review threads and
# in-flight Codex reviews block a merge; a thread clears when it is resolved
# AND someone other than Codex replied on it (or Codex resolved it itself).
#
# Pure bash+jq, no network: `gh` is a PATH shim that answers per PR number
# from fixture files, so a compound merge can be tested PR by PR. Every
# blocking assertion is paired with a control that proves the same fixture
# shape can also clear — both scripts fail open, so a check that always says
# "pass" would otherwise look green.
#
# Run:  bash tests/test_codex_review_gate.sh
# Exit: 0 all green, 1 any failure.
#
# Portability: macOS bash 3.2 + ubuntu bash 5; needs jq.

set -uo pipefail

SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PF="$SKILL_DIR/scripts/codex_review_preflight.sh"
MG_HOOK="$SKILL_DIR/hooks/merge_gate.sh"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

PASS=0
FAIL=0
ok()  { echo "  ok   $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL $1"; FAIL=$((FAIL + 1)); }
assert_eq() {
  if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 (got: '$2' want: '$3')"; fi
}
assert_contains() {
  if [[ "$2" == *"$3"* ]]; then ok "$1"; else bad "$1 (no '$3' in output)"; fi
}
assert_not_contains() {
  if [[ "$2" != *"$3"* ]]; then ok "$1"; else bad "$1 (unexpectedly found '$3')"; fi
}

# ── gh shim ──────────────────────────────────────────────────────────────────
# pr view <n>              → $FIX/<n>.pr.json
# api graphql … number=<n> → $FIX/<n>.threads.json
# api … issues/<n>/comments→ $FIX/<n>.comments.json
# A missing fixture prints nothing, which is how "gh failed" looks.
FIX="$T/fix"
ARGS="$T/gh-args"
mkdir -p "$T/bin" "$FIX"
cat >"$T/bin/gh" <<SH
#!/bin/sh
printf ' %s' "\$@" >>"$ARGS"; printf '\n' >>"$ARGS"
case "\$1 \$2" in
  "pr view") cat "$FIX/\$3.pr.json" 2>/dev/null; exit 0 ;;
esac
all=" \$* "
case "\$all" in
  *" graphql "*)
    n="\$(printf '%s' "\$all" | sed -nE 's/.* number=([0-9]+) .*/\1/p')"
    cat "$FIX/\$n.threads.json" 2>/dev/null ;;
  *"/comments"*)
    n="\$(printf '%s' "\$all" | sed -nE 's#.*/issues/([0-9]+)/comments.*#\1#p')"
    cat "$FIX/\$n.comments.json" 2>/dev/null ;;
esac
exit 0
SH
chmod +x "$T/bin/gh"
export PATH="$T/bin:$PATH"

# A fixed clock: 2026-09-24T06:00:00Z.
export CODEX_GATE_NOW=1790229600
[[ "$(jq -n '"2026-09-24T06:00:00Z" | fromdateiso8601')" == "$CODEX_GATE_NOW" ]] \
  || { echo "FATAL: fixed clock constant is wrong"; exit 1; }

HEAD40='585f205aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
BADGE='**<sub><sub>![P2 Badge](https://img.shields.io/badge/P2-yellow?style=flat)</sub></sub>  Steer advancing specialists back toward the lane**\n\nDetails here.'

# pr_fixture <n> [state]
pr_fixture() {
  printf '{"number":%s,"url":"https://github.com/acme/widgets/pull/%s","state":"%s","headRefOid":"%s"}' \
    "$1" "$1" "${2:-OPEN}" "$HEAD40" >"$FIX/$1.pr.json"
}
# thread <id> <resolved> <outdated> <author> [body] [reply-nodes] [resolved-by]
#   → one reviewThreads node. `replies` (the last 50 comments) starts with the
#   finding itself, as GitHub returns it, so the opener never counts as a reply.
thread() {
  local first
  first="$(printf '{"author":{"login":"%s"},"body":"%s","url":"https://github.com/acme/widgets/pull/7#discussion_r1"}' "$4" "${5:-$BADGE}")"
  printf '{"id":"%s","isResolved":%s,"isOutdated":%s,"path":"game/units/ranged_specialist.gd","line":356,"originalLine":356,"resolvedBy":%s,"comments":{"nodes":[%s]},"replies":{"nodes":[%s%s]}}' \
    "$1" "$2" "$3" "$( [[ -n "${7:-}" ]] && printf '{"login":"%s"}' "$7" || printf 'null')" \
    "$first" "$first" "${6:+,$6}"
}
reply() { printf '{"author":{"login":"%s"},"body":"%s"}' "$1" "$2"; }
DONE="$(reply lobsterclause 'Fixed in 1234abc: specialists now steer back to the lane.')"
# threads_fixture <n> <page-nodes>... → one slurped page per argument
threads_fixture() {
  local n="$1"; shift
  local pages="" p
  for p in "$@"; do
    pages="${pages:+$pages,}{\"data\":{\"repository\":{\"pullRequest\":{\"reviewThreads\":{\"pageInfo\":{\"hasNextPage\":false,\"endCursor\":null},\"nodes\":[$p]}}}}}"
  done
  printf '[%s]' "$pages" >"$FIX/$n.threads.json"
}
# summary_row <status-cell> → one row of Codex's summary table
summary() {
  printf '<!-- codex-pull-request-review-summary -->\\n\\n## Codex Review Summary\\n\\n| Review | Status | Commit | Review trigger |\\n| --- | --- | --- | --- |\\n| 📝 **Code Review** | %s | `585f205` | PR opened |\\n' "$1"
}
# comments_fixture <n> <comment-objects...> (single REST page)
comments_fixture() {
  local n="$1"; shift
  local IFS=,
  printf '[[%s]]' "$*" >"$FIX/$n.comments.json"
}
bot_comment() {  # bot_comment <updated_at> <body>
  printf '{"user":{"login":"chatgpt-codex-connector[bot]"},"updated_at":"%s","body":"%s"}' "$1" "$2"
}
RUNNING_FRESH="🔄 **Running** since <relative-time datetime=\\\"2026-09-24T05:50:00.123456Z\\\">2026-09-24T05:50:00.123456Z</relative-time>"
RUNNING_HUNG="🔄 **Running** since <relative-time datetime=\\\"2026-09-22T03:09:36.093509Z\\\">2026-09-22T03:09:36.093509Z</relative-time>"
RUNNING_GARBLED="🔄 **Running** since <relative-time datetime=\\\"yesterday-ish\\\">?</relative-time>"
COMPLETED="✅ **Completed** <relative-time datetime=\\\"2026-09-24T05:40:00Z\\\">x</relative-time>"

# pf <pr> [args...] → PF_OUT / PF_RC
pf() {
  local n="$1"; shift
  PF_OUT="$(bash "$PF" --pr "$n" --json "$@" 2>/dev/null)"; PF_RC=$?
}
pf_status() { printf '%s' "$PF_OUT" | jq -r '.status // ""' 2>/dev/null; }

echo "── preflight: Codex threads that are not cleared ──"

pr_fixture 7
threads_fixture 7 "$(thread PRRT_open false false chatgpt-codex-connector)"
comments_fixture 7 "$(bot_comment 2026-09-24T05:45:00Z "$(summary "$COMPLETED")")"
pf 7
assert_eq "an unresolved Codex thread blocks (rc 1)" "$PF_RC" "1"
assert_eq "…and reports status=blocked" "$(pf_status)" "blocked"
assert_eq "…with the thread id" "$(printf '%s' "$PF_OUT" | jq -r '.uncleared[0].id')" "PRRT_open"
assert_eq "…its severity parsed from the badge" "$(printf '%s' "$PF_OUT" | jq -r '.uncleared[0].severity')" "P2"
assert_eq "…and its title parsed from the bold line" \
  "$(printf '%s' "$PF_OUT" | jq -r '.uncleared[0].title')" "Steer advancing specialists back toward the lane"
assert_contains "the reason names file:line" "$(printf '%s' "$PF_OUT" | jq -r '.reason')" "ranged_specialist.gd:356"

# CONTROL: the same thread, replied to and resolved.
threads_fixture 7 "$(thread PRRT_open true false chatgpt-codex-connector "$BADGE" "$DONE")"
pf 7
assert_eq "control: a resolved Codex thread with a reply clears (rc 0)" "$PF_RC" "0"
assert_eq "control: …status=clear" "$(pf_status)" "clear"

# Resolution alone is one click; the reply is the record. Each of these would
# pass a resolved-only gate.
threads_fixture 7 "$(thread PRRT_click true false chatgpt-codex-connector)"
pf 7
assert_eq "resolved with no reply still blocks" "$(pf_status)" "blocked"
assert_eq "…and is reported as resolved_no_reply" "$(printf '%s' "$PF_OUT" | jq -r '.uncleared[0].state')" "resolved_no_reply"
assert_contains "…in words" "$(printf '%s' "$PF_OUT" | jq -r '.reason')" "resolved, but nobody replied"
threads_fixture 7 "$(thread PRRT_self true false chatgpt-codex-connector "$BADGE" "$(reply chatgpt-codex-connector 'Thanks!')")"
pf 7
assert_eq "a reply from Codex itself does not count" "$(pf_status)" "blocked"
threads_fixture 7 "$(thread PRRT_blank true false chatgpt-codex-connector "$BADGE" "$(reply lobsterclause '  ')")"
pf 7
assert_eq "a blank reply does not count" "$(pf_status)" "blocked"
threads_fixture 7 "$(thread PRRT_talk false false chatgpt-codex-connector "$BADGE" "$DONE")"
pf 7
assert_eq "a reply without resolving still blocks" "$(pf_status)" "blocked"
assert_eq "…as an open thread" "$(printf '%s' "$PF_OUT" | jq -r '.uncleared[0].state')" "open"
# CONTROL: Codex resolving its own thread is Codex confirming the fix.
threads_fixture 7 "$(thread PRRT_codexdone true false chatgpt-codex-connector "$BADGE" "" chatgpt-codex-connector)"
pf 7
assert_eq "control: a thread Codex resolved itself clears without a reply" "$(pf_status)" "clear"

# Outdated is not addressed: the lines moved, the finding may still stand.
threads_fixture 7 "$(thread PRRT_old false true chatgpt-codex-connector)"
pf 7
assert_eq "an outdated but unresolved Codex thread still blocks" "$(pf_status)" "blocked"
assert_contains "…and is labelled outdated" "$(printf '%s' "$PF_OUT" | jq -r '.reason')" "(outdated)"

# Only Codex's threads gate; a human's open thread is not this gate's business.
threads_fixture 7 "$(thread PRRT_human false false some-human 'nit: rename this')"
pf 7
assert_eq "an unresolved thread opened by a human does not block" "$(pf_status)" "clear"

# A human reply at the end of a Codex thread does not change who opened it.
threads_fixture 7 "$(thread PRRT_a true false chatgpt-codex-connector "$BADGE" "$DONE"),$(thread PRRT_b false false chatgpt-codex-connector)"
pf 7
assert_eq "one open thread among resolved ones blocks" "$(printf '%s' "$PF_OUT" | jq -r '.uncleared | map(.id) | join(",")')" "PRRT_b"

# Pagination: the open thread sits on the second page.
threads_fixture 7 "$(thread PRRT_p1 true false chatgpt-codex-connector "$BADGE" "$DONE")" "$(thread PRRT_p2 false false chatgpt-codex-connector)"
pf 7
assert_eq "a thread on the second GraphQL page is still seen" "$(printf '%s' "$PF_OUT" | jq -r '.uncleared[0].id // ""')" "PRRT_p2"

# Unparseable badge/title must not hide the thread.
threads_fixture 7 "$(thread PRRT_plain false false chatgpt-codex-connector 'Plain finding with no badge')"
pf 7
assert_eq "a thread without Codex's badge markup still blocks" "$(pf_status)" "blocked"
assert_eq "…falling back to the first body line as its title" "$(printf '%s' "$PF_OUT" | jq -r '.uncleared[0].title')" "Plain finding with no badge"

echo "── preflight: Codex review in flight ──"

threads_fixture 7 ""
comments_fixture 7 "$(bot_comment 2026-09-24T05:50:00Z "$(summary "$RUNNING_FRESH")")"
pf 7
assert_eq "a review running for 10 min blocks" "$(pf_status)" "blocked"
assert_eq "…and reports its commit" "$(printf '%s' "$PF_OUT" | jq -r '.running[0].commit')" "585f205"
assert_eq "…and its age" "$(printf '%s' "$PF_OUT" | jq -r '.running[0].age')" "600"

# CONTROLS for the TTL: hung, finished, garbled.
comments_fixture 7 "$(bot_comment 2026-09-22T03:09:36Z "$(summary "$RUNNING_HUNG")")"
pf 7
assert_eq "control: a review 'running' for two days is treated as hung" "$(pf_status)" "clear"
comments_fixture 7 "$(bot_comment 2026-09-24T05:45:00Z "$(summary "$COMPLETED")")"
pf 7
assert_eq "control: a completed review does not block" "$(pf_status)" "clear"
comments_fixture 7 "$(bot_comment 2026-09-24T05:45:00Z "$(summary "$RUNNING_GARBLED")")"
pf 7
assert_eq "an unparseable start time fails open" "$(pf_status)" "clear"
comments_fixture 7 "$(bot_comment 2026-09-24T05:50:00Z "$(summary "$RUNNING_FRESH")")"
PF_OUT="$(CODEX_GATE_RUNNING_TTL=300 bash "$PF" --pr 7 --json 2>/dev/null)"
assert_eq "CODEX_GATE_RUNNING_TTL shortens the window" "$(pf_status)" "clear"

# The NEWEST summary comment decides, by updated_at, not list order.
comments_fixture 7 \
  "$(bot_comment 2026-09-24T05:55:00Z "$(summary "$COMPLETED")")" \
  "$(bot_comment 2026-09-24T05:50:00Z "$(summary "$RUNNING_FRESH")")"
pf 7
assert_eq "an older 'Running' summary is superseded by a newer 'Completed' one" "$(pf_status)" "clear"

# Someone quoting the marker is not Codex.
comments_fixture 7 "{\"user\":{\"login\":\"some-human\"},\"updated_at\":\"2026-09-24T05:59:00Z\",\"body\":\"$(summary "$RUNNING_FRESH")\"}"
pf 7
assert_eq "a human pasting the summary table does not block" "$(pf_status)" "absent"

echo "── preflight: absent, closed, fail-open ──"

threads_fixture 7 ""
comments_fixture 7 '{"user":{"login":"some-human"},"updated_at":"2026-09-24T05:00:00Z","body":"lgtm"}'
pf 7
assert_eq "no Codex activity at all → absent" "$(pf_status)" "absent"
assert_eq "…exits 0" "$PF_RC" "0"

pr_fixture 7 MERGED
threads_fixture 7 "$(thread PRRT_open false false chatgpt-codex-connector)"
pf 7
assert_eq "a merged PR is not gated" "$(pf_status)" "closed"
pr_fixture 7

rm -f "$FIX/404.pr.json"
pf 404
assert_eq "unreadable PR metadata → indeterminate" "$(pf_status)" "indeterminate"
assert_eq "…exits 0" "$PF_RC" "0"

# Sensors fail open independently: unreadable threads do not hide a running
# review, and an unreadable summary does not hide an open thread.
pr_fixture 8
comments_fixture 8 "$(bot_comment 2026-09-24T05:50:00Z "$(summary "$RUNNING_FRESH")")"
pf 8
assert_eq "threads unreadable, review running → still blocked" "$(pf_status)" "blocked"
rm -f "$FIX/8.comments.json"
threads_fixture 8 "$(thread PRRT_8 false false chatgpt-codex-connector)"
pf 8
assert_eq "summary unreadable, thread open → still blocked" "$(pf_status)" "blocked"
threads_fixture 8 ""
pf 8
assert_eq "summary unreadable, nothing open → indeterminate" "$(pf_status)" "indeterminate"

PF_OUT="$(bash "$PF" --json 2>/dev/null)"; PF_RC=$?
assert_eq "missing --pr is a usage error (rc 2)" "$PF_RC" "2"

# owner/name must go in as raw strings (-f); -F would coerce a numeric repo name.
: >"$ARGS"
pf 7
assert_contains "owner is passed with -f" "$(cat "$ARGS")" " -f owner=acme "
assert_contains "number is passed with -F" "$(cat "$ARGS")" " -F number=7 "

echo "── preflight: read order, host, clock skew (pass 5) ──"

# The summary must be read BEFORE the threads: a review finishing between the
# two reads would otherwise look like "no threads, nothing running" (codex P1).
: >"$ARGS"
pf 7
L_SUMMARY="$(grep -n '/comments' "$ARGS" | head -1 | cut -d: -f1)"
L_THREADS="$(grep -n ' graphql ' "$ARGS" | head -1 | cut -d: -f1)"
assert_eq "the summary is read before the threads" \
  "$([[ -n "$L_SUMMARY" && -n "$L_THREADS" && "$L_SUMMARY" -lt "$L_THREADS" ]] && echo yes || echo "no ($L_SUMMARY vs $L_THREADS)")" "yes"
assert_contains "comments are paged 100 at a time" "$(cat "$ARGS")" "comments?per_page=100"

# A GitHub Enterprise PR keeps its host for the API calls (codex P2).
printf '{"number":11,"url":"https://ghe.example.com/acme/widgets/pull/11","state":"OPEN","headRefOid":"%s"}' "$HEAD40" >"$FIX/11.pr.json"
: >"$ARGS"
pf 11
assert_eq "an enterprise host is passed to both API calls" \
  "$(grep -c -- '--hostname ghe.example.com' "$ARGS")" "2"
: >"$ARGS"
pf 7
assert_not_contains "control: github.com needs no --hostname" "$(cat "$ARGS")" "--hostname"

# A review stamped a few seconds in our future must not read "-1 min ago".
threads_fixture 7 ""
comments_fixture 7 "$(bot_comment 2026-09-24T06:00:30Z "$(summary "🔄 **Running** since <relative-time datetime=\\\"2026-09-24T06:00:30Z\\\">x</relative-time>")")"
pf 7
assert_contains "clock skew reports 0 min, not a negative age" "$(printf '%s' "$PF_OUT" | jq -r '.reason')" "started 0 min ago"

echo "── hook: merge_gate.sh with the Codex check ──"

# mg <command> [env...] → the hook's decision (deny) or PASS; MG_REASON too.
mg() {
  local c="$1"; shift
  local out
  out="$(printf '{"tool_input":{"command":%s}}' "$(jq -Rn --arg c "$c" '$c')" \
    | env "$@" bash "$MG_HOOK" 2>/dev/null)"
  MG_REASON="$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecisionReason // ""' 2>/dev/null)"
  printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision // "PASS"' 2>/dev/null
}

pr_fixture 7
threads_fixture 7 "$(thread PRRT_open false false chatgpt-codex-connector)"
comments_fixture 7 "$(bot_comment 2026-09-24T05:45:00Z "$(summary "$COMPLETED")")"
pr_fixture 5
threads_fixture 5 "$(thread PRRT_done true false chatgpt-codex-connector "$BADGE" "$DONE")"
comments_fixture 5 "$(bot_comment 2026-09-24T05:45:00Z "$(summary "$COMPLETED")")"

assert_eq "an open Codex thread denies the merge" "$(mg 'gh pr merge 7 --squash --repo acme/widgets')" "deny"
mg 'gh pr merge 7 --squash --repo acme/widgets' >/dev/null
assert_contains "…the reason names the thread to resolve" "$MG_REASON" "PRRT_open"
assert_contains "…and says how to resolve it" "$MG_REASON" "resolveReviewThread"
assert_contains "…and how to reply first" "$MG_REASON" "addPullRequestReviewThreadReply"
assert_eq "control: all Codex threads resolved → the merge passes" \
  "$(mg 'gh pr merge 5 --squash --repo acme/widgets')" "PASS"

assert_eq "the Codex check runs under the default MERGE_GATE_CHECKS" \
  "$(mg 'gh pr merge 7 --repo acme/widgets' MERGE_GATE_CHECKS=)" "deny"
assert_eq "MERGE_GATE_CHECKS=codex runs it alone" \
  "$(mg 'gh pr merge 7 --repo acme/widgets' MERGE_GATE_CHECKS=codex)" "deny"
assert_eq "a misspelt MERGE_GATE_CHECKS runs both checks, not neither" \
  "$(mg 'gh pr merge 7 --repo acme/widgets' MERGE_GATE_CHECKS=codx)" "deny"
# argv-shaped tool input — a quote before `gh` used to defeat every anchor.
ARGV_OUT="$(printf '%s' '{"tool_input":{"command":["bash","-lc","gh pr merge 7 --repo acme/widgets"]}}' \
  | bash "$MG_HOOK" 2>/dev/null | jq -r '.hookSpecificOutput.permissionDecision // "PASS"')"
assert_eq "an argv-array command is gated like a string one" "$ARGV_OUT" "deny"
# An argv array is refused, never parsed: each attempt to rebuild a command
# line from argv opened a fail-open (codex P1s, cross-review passes 2 and 3).
# Every shape below used to reach a merge unchecked.
argv_hook() {
  printf '{"tool_input":{"command":%s}}' "$1" | bash "$MG_HOOK" 2>/dev/null \
    | jq -r '.hookSpecificOutput.permissionDecision // "PASS"'
}
assert_eq "argv with a multi-word --body is refused" \
  "$(argv_hook '["gh","pr","merge","--body","release notes","7"]')" "deny"
assert_eq "argv with a \$ in the branch ref is refused" \
  "$(argv_hook '["gh","pr","merge","feature$foo"]')" "deny"
assert_eq "a shell behind env is refused" \
  "$(argv_hook '["/usr/bin/env","bash","-lc","gh pr merge 7"]')" "deny"
assert_eq "a shell outside any whitelist is refused" \
  "$(argv_hook '["ash","-c","gh pr merge 7"]')" "deny"
assert_eq "an absolute gh path is refused" \
  "$(argv_hook '["/opt/homebrew/bin/gh","pr","merge","7"]')" "deny"
assert_eq "argv merges are refused even for a Codex-clean PR (fail closed)" \
  "$(argv_hook '["gh","pr","merge","5","--repo","acme/widgets"]')" "deny"
assert_eq "a --disable-auto element cannot smuggle a merge past the refusal" \
  "$(argv_hook '["sh","-c","gh pr merge 7","--disable-auto"]')" "deny"
assert_eq "control: an argv array that is not a PR merge passes" \
  "$(argv_hook '["git","merge","main"]')" "PASS"
: >"$ARGS"
assert_eq "MERGE_GATE_CHECKS=cross-review leaves Codex out" \
  "$(mg 'gh pr merge 7 --repo acme/widgets' MERGE_GATE_CHECKS=cross-review)" "PASS"
assert_not_contains "…and never queries review threads" "$(cat "$ARGS")" "graphql"

assert_eq "CROSS_REVIEW_MERGE_OVERRIDE does not waive an open Codex thread" \
  "$(mg 'CROSS_REVIEW_MERGE_OVERRIDE=1 gh pr merge 7 --repo acme/widgets' CROSS_REVIEW_MERGE_OVERRIDE_AUDIT_LOG="$T/audit.jsonl")" "deny"
assert_eq "control: …while it still passes a Codex-clean PR" \
  "$(mg 'CROSS_REVIEW_MERGE_OVERRIDE=1 gh pr merge 5 --repo acme/widgets' CROSS_REVIEW_MERGE_OVERRIDE_AUDIT_LOG="$T/audit.jsonl")" "PASS"

assert_eq "a compound merge is gated on its second PR too" \
  "$(mg 'gh pr merge 5 --repo acme/widgets && gh pr merge 7 --repo acme/widgets')" "deny"
assert_eq "the REST merge endpoint is gated" \
  "$(mg 'gh api -X PUT repos/acme/widgets/pulls/7/merge -f merge_method=squash')" "deny"
assert_eq "control: …and passes a clean PR" \
  "$(mg 'gh api -X PUT repos/acme/widgets/pulls/5/merge -f merge_method=squash')" "PASS"
assert_eq "cancelling an auto-merge is never gated" \
  "$(mg 'gh pr merge 7 --disable-auto --repo acme/widgets')" "PASS"
assert_eq "a command that is not a merge is ignored" "$(mg 'gh pr view 7 --repo acme/widgets')" "PASS"

# The argv refusal must print its message, not RUN it: unescaped backticks
# made it execute `gh pr merge <n> --disable-auto` (GLM High, pass 5).
ARGV_ERR="$T/argv.err"
ARGV_REASON="$(printf '%s' '{"tool_input":{"command":["gh","pr","merge","7"]}}' \
  | bash "$MG_HOOK" 2>"$ARGV_ERR" | jq -r '.hookSpecificOutput.permissionDecisionReason // ""')"
assert_contains "the argv refusal names the string form it allows" "$ARGV_REASON" "gh pr merge <n> --disable-auto"
assert_eq "…and runs nothing while saying so (no stderr)" "$(wc -c <"$ARGV_ERR" | tr -d ' ')" "0"

# A target the shell fills in cannot be looked up; failing open on it let the
# real PR merge unchecked (gemini-pro High, pass 5).
assert_eq "a PR number in a variable is refused" "$(mg 'gh pr merge "$PR" --repo acme/widgets')" "deny"
mg 'gh pr merge "$PR" --repo acme/widgets' >/dev/null
assert_contains "…saying why" "$MG_REASON" "filled in by the shell"
assert_eq "a repo in a variable is refused" "$(mg 'gh pr merge 5 --repo "$REPO"')" "deny"
assert_eq "a command substitution as the PR is refused" "$(mg 'gh pr merge `cat pr.txt`')" "deny"
assert_eq "a REST merge path built from variables is refused" \
  "$(mg 'gh api -X PUT "repos/$REPO/pulls/$N/merge"')" "deny"
assert_eq "a REST merge with a variable PR number is refused" \
  "$(mg 'gh api -X PUT repos/acme/widgets/pulls/$N/merge')" "deny"

# GH_REPO in front of the merge selects the repository, as --repo does.
: >"$ARGS"
assert_eq "GH_REPO=… gh pr merge is checked against that repo" \
  "$(mg 'GH_REPO=acme/widgets gh pr merge 7')" "deny"
assert_contains "…and the lookup carries it as --repo" "$(cat "$ARGS")" "--repo acme/widgets"
assert_eq "control: GH_REPO with a Codex-clean PR passes" "$(mg 'GH_REPO=acme/widgets gh pr merge 5')" "PASS"

# gh expands {owner}/{repo} from the checkout; the gate looks up the same PR.
# The shim ignores --repo, so assert on the lookup: real gh cannot resolve a
# literal "{owner}/{repo}" and the gate would fail open.
: >"$ARGS"
assert_eq "a {owner}/{repo} REST merge is gated" \
  "$(mg "gh api -X PUT 'repos/{owner}/{repo}/pulls/7/merge'")" "deny"
assert_not_contains "…looking the PR up in this checkout, not in '{owner}/{repo}'" "$(cat "$ARGS")" "{owner}"
assert_eq "control: …and passes a clean PR" \
  "$(mg "gh api -X PUT 'repos/{owner}/{repo}/pulls/5/merge'")" "PASS"

comments_fixture 5 "$(bot_comment 2026-09-24T05:50:00Z "$(summary "$RUNNING_FRESH")")"
assert_eq "a Codex review in flight denies the merge" "$(mg 'gh pr merge 5 --repo acme/widgets')" "deny"
mg 'gh pr merge 5 --repo acme/widgets' >/dev/null
assert_contains "…and says to wait for it" "$MG_REASON" "still reviewing"

rm -f "$FIX/9.pr.json"
assert_eq "an unreadable PR fails open in the hook too" "$(mg 'gh pr merge 9 --repo acme/widgets')" "PASS"

echo
echo "── $PASS passed, $FAIL failed ──"
[[ "$FAIL" -eq 0 ]]
