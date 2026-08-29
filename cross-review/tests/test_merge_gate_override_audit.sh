#!/usr/bin/env bash
# test_merge_gate_override_audit.sh — standalone fixture tests proving that
# CROSS_REVIEW_MERGE_OVERRIDE=1 leaves a structured audit trail instead of
# vanishing into shell history.
#
# NOT wired into run_tests.sh (parent orchestrator owns that wiring separately
# to avoid a merge collision). Pure bash+jq+git, no network, no reviewer CLIs.
# The audit log is redirected to a scratch path via
# CROSS_REVIEW_MERGE_OVERRIDE_AUDIT_LOG — never the real
# ~/.claude/skills/cross-review/merge_override_audit.jsonl.
#
# Run:  bash tests/test_merge_gate_override_audit.sh
# Exit: 0 all green, 1 any failure.
#
# Portability: macOS bash 3.2 + ubuntu bash 5; needs jq and git.

set -uo pipefail

SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
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
assert_not_contains() { if [[ "$2" != *"$3"* ]]; then ok "$1"; else bad "$1 (unexpectedly found '$3')"; fi; }
assert_contains() {
  if [[ "$2" == *"$3"* ]]; then ok "$1"; else bad "$1 (no '$3' in output)"; fi
}

[[ -x "$MG_HOOK" ]] || { echo "FATAL: $MG_HOOK missing or not executable"; exit 1; }

# A throwaway git repo so `git rev-parse HEAD` / `git remote get-url origin`
# inside the hook resolve to something real, without touching the actual repo
# this test runs from.
REPO="$T/repo"
mkdir -p "$REPO"
(
  cd "$REPO" || exit 1
  git init -q
  git config user.email test@example.com
  git config user.name test
  git remote add origin https://github.com/acme/widgets.git
  printf 'hello\n' >README.md
  git add README.md
  git commit -qm init
)
REPO_HEAD="$(cd "$REPO" && git rev-parse HEAD)"

AUDIT_LOG="$T/merge_override_audit.jsonl"

# mg_hook <command> → the hook's permission decision, or PASS. Runs from
# inside REPO so HEAD/origin resolve; the audit log is redirected to scratch.
mg_hook() {
  ( cd "$REPO" && export CROSS_REVIEW_MERGE_OVERRIDE_AUDIT_LOG="$AUDIT_LOG" && \
    printf '{"tool_input":{"command":%s}}' "$(jq -Rn --arg c "$1" '$c')" \
    | bash "$MG_HOOK" 2>/dev/null ) \
    | jq -r '.hookSpecificOutput.permissionDecision // "PASS"' 2>/dev/null
}
# mg_rc <command> [env-prefix...] → the hook's EXIT CODE, so a crash is not
# read as PASS (kimi L, PR #55 review). Extra args are `env` arguments.
mg_rc() {
  local c="$1"; shift
  ( cd "$REPO" && printf '{"tool_input":{"command":%s}}' "$(jq -Rn --arg c "$c" '$c')" \
    | env "$@" bash "$MG_HOOK" >/dev/null 2>&1 ); echo $?
}

echo "── override still passes the merge through unchanged ──"
assert_eq "the override is honoured exactly as before" \
  "$(mg_hook 'CROSS_REVIEW_MERGE_OVERRIDE=1 gh pr merge 3207 --repo acme/widgets')" "PASS"

echo "── override writes a structured audit entry ──"
[[ -f "$AUDIT_LOG" ]] && LOG_LINES="$(wc -l <"$AUDIT_LOG" | tr -d ' ')" || LOG_LINES="0"
assert_eq "exactly one line was appended" "$LOG_LINES" "1"

LAST_LINE="$(tail -n1 "$AUDIT_LOG" 2>/dev/null || true)"
if jq -e . >/dev/null 2>&1 <<<"$LAST_LINE"; then
  ok "the appended line is valid JSON"
else
  bad "the appended line is not valid JSON: $LAST_LINE"
fi

FIELDS="$(jq -r '[.ts,.repo,.pr,.head_sha,.command,.user] | @tsv' <<<"$LAST_LINE" 2>/dev/null)"
IFS=$'\t' read -r F_TS F_REPO F_PR F_HEAD F_CMD F_USER <<<"$FIELDS"

assert_contains "ts looks like a UTC timestamp" "$F_TS" "T"
assert_contains "ts ends in Z" "$F_TS" "Z"
assert_eq "repo is resolved from --repo" "$F_REPO" "acme/widgets"
assert_eq "pr is resolved from the command" "$F_PR" "3207"
assert_eq "head_sha is the current HEAD" "$F_HEAD" "$REPO_HEAD"
assert_contains "command records what was actually run" "$F_CMD" "gh pr merge 3207"
assert_contains "command records the override prefix too" "$F_CMD" "CROSS_REVIEW_MERGE_OVERRIDE=1"
[[ -n "$F_USER" ]] && ok "user is populated" || bad "user is empty"

echo "── repo falls back to git remote when --repo is absent ──"
: >"$AUDIT_LOG"
mg_hook 'CROSS_REVIEW_MERGE_OVERRIDE=1 gh pr merge 3207' >/dev/null
FALLBACK_REPO="$(tail -n1 "$AUDIT_LOG" 2>/dev/null | jq -r '.repo // ""' 2>/dev/null)"
assert_eq "repo falls back to the origin remote" "$FALLBACK_REPO" "acme/widgets"

echo "── every override invocation appends, none are skipped ──"
: >"$AUDIT_LOG"
mg_hook 'CROSS_REVIEW_MERGE_OVERRIDE=1 gh pr merge 1001 --repo acme/widgets' >/dev/null
mg_hook 'CROSS_REVIEW_MERGE_OVERRIDE=1 gh pr merge 1002 --repo acme/widgets' >/dev/null
assert_eq "two overrides append two lines" "$(wc -l <"$AUDIT_LOG" | tr -d ' ')" "2"

echo "── a command that never overrides anything logs nothing ──"
: >"$AUDIT_LOG"
mg_hook 'gh pr view 3207' >/dev/null
assert_eq "a non-override command writes no audit entry" \
  "$([[ -s "$AUDIT_LOG" ]] && echo present || echo absent)" "absent"

echo "── a merge-free command logs nothing either ──"
: >"$AUDIT_LOG"
mg_hook 'ls -la' >/dev/null
assert_eq "an unrelated command writes no audit entry" \
  "$([[ -s "$AUDIT_LOG" ]] && echo present || echo absent)" "absent"

echo "── a write failure to the audit log must not block the override ──"
: >"$AUDIT_LOG"
BAD_LOG="$T/not-a-directory/nested/merge_override_audit.jsonl"
printf 'not a directory\n' >"$T/not-a-directory"
BAD_DECISION="$(
  ( cd "$REPO" && export CROSS_REVIEW_MERGE_OVERRIDE_AUDIT_LOG="$BAD_LOG" && \
    printf '{"tool_input":{"command":%s}}' "$(jq -Rn --arg c 'CROSS_REVIEW_MERGE_OVERRIDE=1 gh pr merge 3207 --repo acme/widgets' '$c')" \
    | bash "$MG_HOOK" 2>/dev/null ) \
  | jq -r '.hookSpecificOutput.permissionDecision // "PASS"' 2>/dev/null
)"
assert_eq "override still passes even when the log write fails" "$BAD_DECISION" "PASS"

echo "── PR #55 review: per-invocation records, redaction, forms, no-HOME ──"
: >"$AUDIT_LOG"
mg_hook 'CROSS_REVIEW_MERGE_OVERRIDE=1 gh pr merge 11 --repo acme/a && CROSS_REVIEW_MERGE_OVERRIDE=1 gh pr merge 22 -R acme/b' >/dev/null
assert_eq "a compound command logs one entry per overridden merge" "$(wc -l <"$AUDIT_LOG" | tr -d ' ')" "2"
assert_eq "…first entry has its own pr/repo"  "$(jq -r 'select(.pr=="11") | .repo' "$AUDIT_LOG")" "acme/a"
assert_eq "…second entry has its own pr/repo" "$(jq -r 'select(.pr=="22") | .repo' "$AUDIT_LOG")" "acme/b"
: >"$AUDIT_LOG"
mg_hook 'export DEPLOY_SECRET=hunter2; GH_TOKEN=ghp_abc123 CROSS_REVIEW_MERGE_OVERRIDE=1 gh pr merge 33 --token=ghp_xyz789' >/dev/null
line="$(cat "$AUDIT_LOG")"
assert_not_contains "unrelated segment never reaches the log" "$line" "hunter2"
assert_not_contains "GH_TOKEN value redacted"                  "$line" "ghp_abc123"
assert_not_contains "--token value redacted"                   "$line" "ghp_xyz789"
assert_contains     "…the invocation itself is kept"           "$(jq -r .command "$AUDIT_LOG")" "gh pr merge 33"
assert_contains     "…with the redaction marker"               "$(jq -r .command "$AUDIT_LOG")" "<redacted>"
: >"$AUDIT_LOG"
mg_hook 'CROSS_REVIEW_MERGE_OVERRIDE=1 gh pr merge --repo "acme/other" 123 --squash' >/dev/null
assert_eq "PR number after flags is found"      "$(jq -r .pr "$AUDIT_LOG")" "123"
assert_eq "quoted --repo value is unquoted"     "$(jq -r .repo "$AUDIT_LOG")" "acme/other"
assert_eq "head_sha is empty when the merge targets another repo" "$(jq -r .head_sha "$AUDIT_LOG")" ""
: >"$AUDIT_LOG"
mg_hook 'GH_REPO=acme/env CROSS_REVIEW_MERGE_OVERRIDE=1 gh pr merge 55' >/dev/null
assert_eq "GH_REPO assignment is honoured as the repo" "$(jq -r .repo "$AUDIT_LOG")" "acme/env"
: >"$AUDIT_LOG"
mg_hook 'CROSS_REVIEW_MERGE_OVERRIDE=1 gh api -X PUT -H "Authorization: token ghp_hdr999" repos/acme/w/pulls/77/merge' >/dev/null
assert_eq "gh api merge form: pr"   "$(jq -r .pr "$AUDIT_LOG")" "77"
assert_eq "gh api merge form: repo" "$(jq -r .repo "$AUDIT_LOG")" "acme/w"
assert_not_contains "Authorization header value redacted" "$(cat "$AUDIT_LOG")" "ghp_hdr999"
rm -f "$AUDIT_LOG"
mg_hook 'CROSS_REVIEW_MERGE_OVERRIDE=1 gh pr merge 66' >/dev/null
assert_eq "merge in the cwd repo records the cwd HEAD" "$(jq -r .head_sha "$AUDIT_LOG")" "$(git -C "$REPO" rev-parse HEAD)"
perm="$(stat -f %Lp "$AUDIT_LOG" 2>/dev/null || stat -c %a "$AUDIT_LOG" 2>/dev/null)"
assert_eq "audit log is created 0600 (umask 077)" "$perm" "600"
assert_eq "unset HOME + no audit path: the hook still runs (rc 0)" "$(mg_rc 'CROSS_REVIEW_MERGE_OVERRIDE=1 gh pr merge 88' -u HOME -u CROSS_REVIEW_MERGE_OVERRIDE_AUDIT_LOG)" "0"
assert_eq "unset HOME: a plain merge is still checked, not crashed (rc 0)" "$(mg_rc 'gh pr merge 89' -u HOME -u CROSS_REVIEW_MERGE_OVERRIDE_AUDIT_LOG)" "0"

echo "── PR #55 pass 2: quoted/lowercase credentials, numeric flag values, quoted separators, existing perms, mixed compound ──"
: >"$AUDIT_LOG"
mg_hook 'CROSS_REVIEW_MERGE_OVERRIDE=1 gh api -X PUT -H "authorization: Bearer ghp_low111" repos/acme/w/pulls/78/merge' >/dev/null
assert_not_contains "lowercase authorization header redacted" "$(cat "$AUDIT_LOG")" "ghp_low111"
: >"$AUDIT_LOG"
mg_hook 'GH_TOKEN="two words here" gh_token=ghp_lc222 CROSS_REVIEW_MERGE_OVERRIDE=1 gh pr merge 34 --token "quoted tok 333"' >/dev/null
line="$(cat "$AUDIT_LOG")"
assert_not_contains "quoted assignment redacted whole"  "$line" "two words"
assert_not_contains "lowercase token= redacted"          "$line" "ghp_lc222"
assert_not_contains "quoted --token redacted whole"      "$line" "quoted tok"
: >"$AUDIT_LOG"
mg_hook 'CROSS_REVIEW_MERGE_OVERRIDE=1 gh pr merge --body 2025 --subject "fix; urgent (now)" 123 --repo acme/other' >/dev/null
assert_eq "numeric flag value is not the PR"             "$(jq -r .pr "$AUDIT_LOG")" "123"
assert_eq "one entry despite ';' and '(' inside quotes"  "$(wc -l <"$AUDIT_LOG" | tr -d ' ')" "1"
# scrub() drops quoted strings from cmd_only before anything else sees them,
# so the quoted subject is absent by design — what matters is that it did
# not split the invocation and the merge itself is recorded.
assert_contains "the invocation is recorded around the scrubbed flag" "$(jq -r .command "$AUDIT_LOG")" "--body 2025"
assert_not_contains "…and the quoted text itself never lands in the log" "$(jq -r .command "$AUDIT_LOG")" "urgent"
: >"$AUDIT_LOG"
mg_hook 'CROSS_REVIEW_MERGE_OVERRIDE=1 gh pr merge --repo 123 456' >/dev/null
assert_eq "--repo value consumed before the PR is chosen" "$(jq -r .pr "$AUDIT_LOG")" "456"
: >"$AUDIT_LOG"
mg_hook 'GH_REPO="acme/quoted" CROSS_REVIEW_MERGE_OVERRIDE=1 gh pr merge 57' >/dev/null
assert_eq "quoted GH_REPO is unquoted"                    "$(jq -r .repo "$AUDIT_LOG")" "acme/quoted"
rm -f "$AUDIT_LOG"; ( umask 022; : >"$AUDIT_LOG" ); chmod 644 "$AUDIT_LOG"
mg_hook 'CROSS_REVIEW_MERGE_OVERRIDE=1 gh pr merge 58' >/dev/null
perm2="$(stat -f %Lp "$AUDIT_LOG" 2>/dev/null || stat -c %a "$AUDIT_LOG" 2>/dev/null)"
assert_eq "a pre-existing 0644 log is tightened to 0600 on append" "$perm2" "600"
: >"$AUDIT_LOG"
mg_hook 'CROSS_REVIEW_MERGE_OVERRIDE=1 gh pr merge 61 && gh pr merge 62' >/dev/null
assert_eq "mixed compound: only the overridden merge is logged" "$(jq -r .pr "$AUDIT_LOG")" "61"
: >"$AUDIT_LOG"
mg_hook 'CROSS_REVIEW_MERGE_OVERRIDE=1 gh api user && gh pr merge 63' >/dev/null
assert_eq "a decoy overridden gh api call logs nothing (it is not a merge)" "$(wc -c <"$AUDIT_LOG" | tr -d ' ')" "0"
: >"$AUDIT_LOG"
mg_hook "CROSS_REVIEW_MERGE_OVERRIDE=1 gh pr merge --token$(printf '\t')ghp_tab777 64" >/dev/null
assert_not_contains "--token separated by a tab is redacted" "$(cat "$AUDIT_LOG")" "ghp_tab777"

echo
echo "══ $PASS passed, $FAIL failed ══"
[[ "$FAIL" -eq 0 ]]
