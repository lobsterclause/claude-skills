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
# It covers both `gh pr merge` and `gh api ... repos/O/R/pulls/N/merge`, and
# on a `clear` verdict it requires the merge to carry `--match-head-commit`
# so GitHub itself refuses if the head moved after the check (TOCTOU).
#
# KNOWN LIMITS, stated rather than papered over:
#  * It decides from the command text. A merge inside a shell script it cannot
#    read, a GraphQL `mergePullRequest` mutation (the PR is a node ID there,
#    with nothing to resolve), or the GitHub web UI all bypass it. A status
#    check is what covers those.
#  * It never rewrites the command, because another PreToolUse hook may return
#    `updatedInput` and two rewriters would fight — verified live: rtk rewrites
#    `gh pr merge` to `rtk gh pr merge` and returns permissionDecision "allow".
#    Deny still wins over that allow (verified with an always-stale stub), and
#    the whitespace leading anchor is what keeps `rtk gh …` matching at all.

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
#
# Separators are then padded with spaces. `merge` had to be followed by
# whitespace or end-of-string to match, so `gh pr merge` with nothing after it
# — the plainest and most common form there is — became `gh pr merge;` after
# the newline mapping and matched nothing at all. Padding turns that into
# `gh pr merge ; ` so the existing anchor fires, and argument truncation at the
# separator still works because the separator survives as its own token.
cmd_only="$(scrub "$cmd" | tr '\n' ';' | sed -E 's/([;&|()])/ \1 /g')"

# Leading anchor accepts whitespace as well as a shell separator. Requiring a
# separator meant an environment prefix or a shell keyword — `GH_REPO=o/r gh pr
# merge 3207`, `if gh pr merge 3207; then` — put a space before `gh` and
# sailed through. The cost is that a bare `echo gh pr merge 1` is also matched;
# a false denial on a command that merges nothing is much cheaper than a false
# allow on one that does.
MERGE_RE='(^|[;&|(]|[[:space:]])[[:space:]]*gh[[:space:]]+pr[[:space:]]+merge([[:space:]]|$)'
# `gh api ... repos/O/R/pulls/N/merge` merges a PR without ever saying
# "gh pr merge". It was listed as a known limit rather than handled; an agent
# that hits the deny below can reach for it in one step, which makes it the
# most likely bypass in practice rather than the least.
API_MERGE_RE='repos/[^/ ]+/[^/ ]+/pulls/[0-9]+/merge'
if ! printf '%s' "$cmd_only" | grep -qE "$MERGE_RE" \
   && ! printf '%s' "$cmd_only" | grep -qE "$API_MERGE_RE"; then
  pass
fi

# An explicit, auditable escape hatch. This is NOT a security boundary — the
# agent could write it unprompted — it is a way for the agent to carry out an
# instruction the user actually gave ("the delta is a rebase, merge it") while
# leaving the bypass visible in the command the user approves. Without one, the
# refusal below told the agent to do something no command could express.
#
# It must sit immediately before the merge, as a real environment assignment.
# A substring match anywhere accepted `echo CROSS_REVIEW_MERGE_OVERRIDE=1; gh
# pr merge 3207`, a trailing `# CROSS_REVIEW_MERGE_OVERRIDE=1` comment that the
# shell never evaluates, and the value `=10` — three ways to disarm the gate
# without ever authorizing anything.
OVERRIDE_RE='(^|[;&|(]|[[:space:]])[[:space:]]*CROSS_REVIEW_MERGE_OVERRIDE=1[[:space:]]+(gh[[:space:]]+pr[[:space:]]+merge([[:space:]]|$)|gh[[:space:]]+api[[:space:]])'

# The override is "an auditability mechanism, not a security boundary" (per
# SKILL.md) — but until now it left no record anywhere except the shell
# history of whoever ran it. Append a best-effort JSONL line before letting
# the bypass through, so there is a trail of who overrode a stale-or-missing
# review, when, and for what. This is pure logging: it must never change the
# allow/deny decision, and a failure to write must never block the merge —
# same fail-open philosophy as the rest of this hook.
#
# CROSS_REVIEW_MERGE_OVERRIDE_AUDIT_LOG mirrors CROSS_REVIEW_RUNLOG elsewhere
# in this skill: production never sets it, fixture tests point it at a scratch
# path instead of the user's real home directory.
# split_segments <command> — one shell segment per line, splitting on
# ; & | ( ) OUTSIDE quotes. scrub() has already removed quoted strings from
# cmd_only, so this is belt-and-braces for anything that survives it; `tr`
# would have split inside a quoted argument (codex+kimi, #55 pass 2).
split_segments() {
  printf '%s\n' "$1" | awk '
    { s = $0; out = ""; q = ""; prev = ""
      for (i = 1; i <= length(s); i++) {
        c = substr(s, i, 1)
        if (q != "") { if (c == q && prev != "\\") q = ""; out = out c; prev = c; continue }
        prev = c
        if (c == "\"" || c == "\047") { q = c; out = out c; continue }
        if (c ~ /[;&|()]/) { print out; out = ""; continue }
        out = out c
      }
      print out }'
}
MERGE_SEG_RE='gh[[:space:]]+pr[[:space:]]+merge([[:space:]]|$)|gh[[:space:]]+api[[:space:]].*pulls/[0-9]+/merge'
OVERRIDE_SEG_RE='(^|[[:space:]])CROSS_REVIEW_MERGE_OVERRIDE=1[[:space:]]+gh[[:space:]]+(pr[[:space:]]+merge|api)([[:space:]]|$)'

# Redaction, as a sed -E program. Case-insensitive via bracket classes (BSD
# sed has no I flag); a quoted value is consumed whole, so `GH_TOKEN="two
# words"` and `authorization: bearer …` no longer leak (#55 pass 2: codex,
# kimi, antigravity convergent).
read -r -d '' REDACT_SED <<'SEDEOF' || true
s/(^|[^A-Za-z0-9_])([A-Za-z_]*([Tt][Oo][Kk][Ee][Nn]|[Ss][Ee][Cc][Rr][Ee][Tt]|[Pp][Aa][Ss][Ss][Ww][Oo][Rr][Dd]|[Pp][Aa][Ss][Ss][Ww][Dd]|_[Kk][Ee][Yy]|[Aa][Pp][Ii][Kk][Ee][Yy]))=("[^"]*"|'[^']*'|[^[:space:]]+)/\1\2=<redacted>/g
s/(--token)[=[:space:]]("[^"]*"|'[^']*'|[^[:space:]]+)/\1 <redacted>/g
s/([Aa][Uu][Tt][Hh][Oo][Rr][Ii][Zz][Aa][Tt][Ii][Oo][Nn]:[[:space:]]*)(\\"[^"]*\\"|[^"']+)/\1<redacted>/g
SEDEOF

# Resolved inside the function, under set +e: with `set -u` an unset HOME
# at top level aborted the WHOLE hook — every merge check, override or not
# (codex, PR #55 review). No explicit path and no HOME → no log, no crash.
log_override_audit() {
  (
    set +e
    umask 077   # the log carries command lines; never world-readable
    local_log="${CROSS_REVIEW_MERGE_OVERRIDE_AUDIT_LOG:-}"
    if [[ -z "$local_log" ]]; then
      [[ -n "${HOME:-}" ]] || exit 0
      local_log="$HOME/.claude/skills/cross-review/merge_override_audit.jsonl"
    fi
    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)"
    who="${USER:-$(whoami 2>/dev/null)}"
    cwd_repo="$(git remote get-url origin 2>/dev/null | sed -E 's#^git@github\.com:##; s#^https://github\.com/##; s#\.git$##')"
    cwd_sha="$(git rev-parse HEAD 2>/dev/null)"
    # One entry PER overridden merge invocation, parsed from its own segment:
    # a compound command used to yield one record with the first -R/--repo
    # and first PR number found anywhere in the line (codex, kimi, PR #55).
    split_segments "$cmd_only" | while IFS= read -r seg; do
      printf '%s' "$seg" | grep -qE "$OVERRIDE_SEG_RE" || continue
      printf '%s' "$seg" | grep -qE "$MERGE_SEG_RE" || continue   # a non-merge gh api call is not an override to record
      inv="$(printf '%s' "$seg" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
      red="$(printf '%s' "$inv" | sed -E "$REDACT_SED")"
      repo="$(printf '%s' "$inv" | grep -oE -- '(-R|--repo)[= ]["'"'"']?[^ "'"'"']+' 2>/dev/null | head -n1 | sed -E 's/^(-R|--repo)[= ]["'"'"']?//')"
      [[ -z "$repo" ]] && repo="$(printf '%s' "$inv" | grep -oE 'repos/[^/ ]+/[^/ ]+/pulls/[0-9]+/merge' 2>/dev/null | head -n1 | sed -E 's#repos/([^/ ]+/[^/ ]+)/pulls/.*#\1#')"
      [[ -z "$repo" ]] && repo="$(printf '%s' "$inv" | grep -oE '(^|[[:space:]])GH_REPO=["'"'"']?[^ "'"'"']+' 2>/dev/null | head -n1 | sed -E 's/^[[:space:]]*GH_REPO=["'"'"']?//')"
      [[ -z "$repo" ]] && repo="${GH_REPO:-}"
      [[ -z "$repo" ]] && repo="$cwd_repo"
      pr="$(printf '%s' "$inv" | grep -oE 'pulls/[0-9]+/merge' 2>/dev/null | head -n1 | grep -oE '[0-9]+')"
      # `gh pr merge [flags] <number> [flags]`: the first bare numeric token
      # after `merge` that is not the VALUE of a value-taking flag — `--body
      # 2025 123` is PR 123 (codex+kimi, #55 pass 2). Flags with values match
      # parse_invocation below; `--flag=value` carries its value inline.
      [[ -z "$pr" ]] && pr="$(printf '%s' "$inv" | awk '
        BEGIN { v["-b"]=1; v["--body"]=1; v["-F"]=1; v["--body-file"]=1; v["-t"]=1; v["--subject"]=1
                v["-A"]=1; v["--author-email"]=1; v["-R"]=1; v["--repo"]=1; v["--match-head-commit"]=1 }
        { for (i = 1; i <= NF; i++) if ($i == "merge") {
            for (j = i + 1; j <= NF; j++) {
              if ($j in v) { j++; continue }
              if ($j ~ /^-/) continue
              tok = $j; gsub(/^["\047]|["\047]$/, "", tok)
              if (tok ~ /^[0-9]+$/) { print tok; exit } } } }' 2>/dev/null)"
      # HEAD of the cwd is only the merged head when the merge targets the
      # cwd repo; for -R/GH_REPO elsewhere it would be a wrong sha (kimi).
      head_sha=""; [[ "$repo" == "$cwd_repo" ]] && head_sha="$cwd_sha"
      entry="$(jq -nc \
        --arg ts "$ts" --arg repo "$repo" --arg pr "$pr" \
        --arg head_sha "$head_sha" --arg command "$red" --arg user "$who" \
        '{ts:$ts, repo:$repo, pr:$pr, head_sha:$head_sha, command:$command, user:$user}' 2>/dev/null)"
      [[ -n "$entry" ]] || continue
      mkdir -p "$(dirname "$local_log")" 2>/dev/null
      # umask only shapes NEW files: a log created 0644 by an older hook must
      # be tightened BEFORE the line lands in it, not after (codex+kimi pass
      # 2, ordering per kimi pass 3). A symlink or someone else's file is
      # never written.
      if [[ -e "$local_log" ]]; then
        [[ -f "$local_log" && ! -L "$local_log" && -O "$local_log" ]] || continue
        chmod 600 "$local_log" 2>/dev/null || continue
      fi
      printf '%s\n' "$entry" >>"$local_log" 2>/dev/null
    done
  ) || true
}

# The override is honoured per SEGMENT, and only when EVERY merge in the
# command carries it. A top-level match used to `pass` the whole line, so
# `CROSS_REVIEW_MERGE_OVERRIDE=1 gh pr merge 1 && gh pr merge 2` skipped the
# gate for PR 2 (antigravity High, #55 pass 2). A mixed line is logged for
# its overridden merges and then falls through to the normal per-invocation
# gate, which checks all of them — the safe direction.
n_merge=0; n_override=0
while IFS= read -r seg; do
  printf '%s' "$seg" | grep -qE "$MERGE_SEG_RE" && n_merge=$((n_merge + 1))
  # An override counts only on a segment that IS a merge: `OVERRIDE=1 gh api
  # user && gh pr merge 3207` used to score 1 == 1 and pass (codex +
  # antigravity, #55 pass 3).
  printf '%s' "$seg" | grep -qE "$OVERRIDE_SEG_RE" && printf '%s' "$seg" | grep -qE "$MERGE_SEG_RE" && n_override=$((n_override + 1))
done < <(split_segments "$cmd_only")
if (( n_override > 0 )); then
  log_override_audit
  (( n_override == n_merge )) && pass
fi

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
INV_PR=""; INV_REPO=""; INV_SKIP=0; INV_MATCH=0
parse_invocation() {
  INV_PR=""; INV_REPO=""; INV_SKIP=0; INV_MATCH=0
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
      # Every gh-pr-merge option that consumes the NEXT token. `-A` is the
      # documented alias for --author-email; omitting it made
      # `gh pr merge -A user@example.com 3207` resolve the email as the PR.
      # Binding the merge to a SHA is what closes the TOCTOU window, so note
      # when the caller already did it.
      --match-head-commit) INV_MATCH=1; expect=skipval ;;
      --match-head-commit=*) INV_MATCH=1 ;;
      -b|--body|-F|--body-file|-t|--subject|-A|--author-email)
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
    while (match(s, /(^|[;&|(]|[[:space:]])[[:space:]]*gh[[:space:]]+pr[[:space:]]+merge([[:space:]]|$)/)) {
      s = substr(s, RSTART + RLENGTH)
      print "@" s
    }
  }')"

verdict_json=""
unbound_json=""

# REST merges first: one preflight per repos/O/R/pulls/N/merge in the command.
while IFS= read -r spec; do
  [[ -n "$spec" ]] || continue
  api_repo="${spec%% *}"; api_pr="${spec##* }"
  result="$(bash "$preflight" --pr "$api_pr" --repo "$api_repo" --json 2>/dev/null || true)"
  [[ -n "$result" ]] || continue
  if [[ "$(printf '%s' "$result" | jq -r '.status // ""' 2>/dev/null || true)" == "stale" ]]; then
    verdict_json="$result"
    break
  fi
done <<API
$(printf '%s' "$cmd_only" | grep -oE "$API_MERGE_RE" \
   | sed -E 's#repos/([^/ ]+/[^/ ]+)/pulls/([0-9]+)/merge#\1 \2#')
API

[[ -n "$verdict_json" ]] || while IFS= read -r args; do
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

  inv_status="$(printf '%s' "$result" | jq -r '.status // ""' 2>/dev/null || true)"
  if [[ "$inv_status" == "stale" ]]; then
    verdict_json="$result"
    break
  fi
  # A `clear` verdict says THIS commit was reviewed. Between that read and
  # GitHub handling the merge, a push can land — and the merge would take the
  # new head. `--match-head-commit` makes GitHub itself refuse in that case,
  # which turns the check from "was true a moment ago" into a guarantee.
  # Only enforced on `clear`: with no reviewed SHA there is nothing to bind to,
  # and blocking there would break green-when-absent.
  if [[ "$inv_status" == "clear" && "$INV_MATCH" -eq 0 && -z "$unbound_json" ]]; then
    unbound_json="$result"
  fi
done <<EOF
$invocations
EOF

deny() {
  jq -n --arg r "$1" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: $r
    }
  }'
  exit 0
}

if [[ -z "$verdict_json" ]]; then
  [[ -n "$unbound_json" ]] || pass
  u_head="$(printf '%s' "$unbound_json" | jq -r '.head // ""' 2>/dev/null || true)"
  u_pr="$(printf '%s' "$unbound_json" | jq -r '.pr // ""' 2>/dev/null || true)"
  [[ -n "$u_head" ]] || pass
  deny "PR ${u_pr} is reviewed at its current head, but this merge is not bound to it.

The review covers ${u_head:0:9}. Nothing stops a push from landing between this check and GitHub handling the merge, and the merge would take the new head — unreviewed. \`--match-head-commit\` makes GitHub refuse in exactly that case, which is the difference between 'was true a moment ago' and a guarantee.

Re-run it as:

  gh pr merge ${u_pr} --match-head-commit ${u_head} <your other flags>

If GitHub then rejects it, the head moved and the review no longer covers what you were about to merge — which is the check working."
fi

reviewed="$(printf '%s' "$verdict_json" | jq -r '.reviewed // ""' 2>/dev/null || true)"
head="$(printf '%s' "$verdict_json" | jq -r '.head // ""' 2>/dev/null || true)"
which_pr="$(printf '%s' "$verdict_json" | jq -r '.pr // ""' 2>/dev/null || true)"

reason="Cross-review is stale for PR ${which_pr}.

The newest cross-review record covers ${reviewed}, but the head you are about to merge is ${head:0:9}. The commits in between were never reviewed — this is the exact failure mode that landed a High-severity navigation race on develop (kindred-mama-ai #3243).

Do one of:
  1. Re-run cross-review against the current head, then merge.
  2. If the delta is genuinely trivial (a rebase, a typo, a lockfile), say so to the user, and merge only once they agree by prefixing the command with CROSS_REVIEW_MERGE_OVERRIDE=1 — which leaves the bypass visible in what they approve.

Do not re-issue this command unchanged."

deny "$reason"
