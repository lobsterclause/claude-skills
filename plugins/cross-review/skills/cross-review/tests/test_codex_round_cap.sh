#!/usr/bin/env bash
# shellcheck disable=SC2015  # `check && ok || bad`: ok only echoes, so bad never runs after a pass
# test_codex_round_cap.sh — fixture tests for hooks/codex_round_cap.sh: a
# request for another Codex review is refused once the PR has had the cap (3)
# of them, and everything else passes.
#
# Pure bash+jq, no network: `gh` is a PATH shim answering from fixture files
# (reviews per PR, branch → number). Each refusal is paired with a control
# under the cap, because the hook fails open and an always-pass hook would
# otherwise look green.
#
# Run:  bash tests/test_codex_round_cap.sh
# Exit: 0 all green, 1 any failure.

set -uo pipefail
SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$SKILL_DIR/hooks/codex_round_cap.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
PASS=0; FAIL=0
ok()  { echo "  ok   $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL $1"; FAIL=$((FAIL + 1)); }

mkdir -p "$T/bin" "$T/fx"
cat > "$T/bin/gh" <<'GH'
#!/usr/bin/env bash
# api --paginate repos/O/R/pulls/N/reviews -q FILTER  |  pr view REF --repo R --json number -q .number
#  | repo view --json nameWithOwner -q .nameWithOwner
[[ -f "$FX/fail" ]] && exit 1
case "$1 $2" in
  "api --paginate")
    n=$(sed -n 's#.*/pulls/\([0-9]*\)/reviews#\1#p' <<<"$3")
    f="$FX/reviews-$n.json"; [[ -f "$f" ]] || f=/dev/null
    jq "$5" "$f" 2>/dev/null || echo 0 ;;
  "pr view") cat "$FX/branch-$3" 2>/dev/null || exit 1 ;;
  "repo view") echo "o/r" ;;
  *) exit 1 ;;
esac
GH
chmod +x "$T/bin/gh"
export PATH="$T/bin:$PATH" FX="$T/fx"
reviews() { # PR codex-count other-count
  jq -n --argjson c "$2" --argjson o "$3" \
    '[range($c) | {user: {login: "chatgpt-codex-connector[bot]"}}] + [range($o) | {user: {login: "someone"}}]' \
    > "$T/fx/reviews-$1.json"
}
reviews 7 3 2      # at the cap
reviews 8 2 5      # under it (other reviewers never count)
reviews 9 19 0     # far over
mkdir -p "$T/fx/branch-feat"; echo 7 > "$T/fx/branch-feat/x"   # gh pr view feat/x

decide() { # command [cwd] -> deny | pass
  local out
  out=$(jq -n --arg c "$1" --arg d "${2:-$T}" '{tool_input: {command: $c}, cwd: $d}' | bash "$HOOK")
  if [[ "$(jq -r '.hookSpecificOutput.permissionDecision // "pass"' <<<"$out")" == deny ]]; then echo deny; else echo pass; fi
}
check() { local got; got=$(decide "$2"); [[ "$got" == "$3" ]] && ok "$1" || bad "$1 (got $got, want $3)"; }

echo "── codex round cap ──"
check "3 Codex reviews: another request is refused"        'gh pr comment 7 --repo o/r --body "@codex review"' deny
check "control: 2 Codex reviews (5 others) passes"          'gh pr comment 8 --repo o/r --body "@codex review"' pass
check "19 Codex reviews: refused"                           'gh pr comment 9 -R o/r --body "@codex review please"' deny
check "branch name resolves to the PR"                      'gh pr comment feat/x --repo o/r --body "@codex review"' deny
check "repo from the checkout when --repo is absent"        'gh pr comment 7 --body "@codex review"' deny
check "gh api issue comment counts too"                     "gh api repos/o/r/issues/7/comments -f body='@codex review'" deny
check "control: gh api comment under the cap passes"        "gh api repos/o/r/issues/8/comments -f body='@codex review'" pass
check "case-insensitive @Codex Review"                      'gh pr comment 7 --repo o/r --body "@Codex Review"' deny
check "a comment without @codex review passes"              'gh pr comment 7 --repo o/r --body "thanks, fixed in abc"' pass
check "mentioning @codex without asking for review passes"  'gh pr comment 7 --repo o/r --body "@codex thanks"' pass
check "unrelated command passes"                            'git log --oneline -3' pass
CODEX_ROUND_CAP=5 check "CODEX_ROUND_CAP=5 lets the 4th round through" 'gh pr comment 7 --repo o/r --body "@codex review"' pass
reason=$(jq -n --arg c 'gh pr comment 7 --repo o/r --body "@codex review"' --arg d "$T" '{tool_input:{command:$c},cwd:$d}' \
  | bash "$HOOK" | jq -r '.hookSpecificOutput.permissionDecisionReason // ""')
[[ "$reason" == *"o/r#7 has had 3 Codex review"* && "$reason" == *"--match-head-commit"* ]] \
  && ok "denial names the PR, the count, and what to do instead" || bad "denial message ($reason)"
touch "$T/fx/fail"
check "gh failing: fails open"                              'gh pr comment 7 --repo o/r --body "@codex review"' pass
rm -f "$T/fx/fail"

echo "$PASS passed, $FAIL failed"
(( FAIL == 0 ))
