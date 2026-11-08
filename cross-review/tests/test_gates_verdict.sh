#!/usr/bin/env bash
# test_gates_verdict.sh — the bundled gates honour the marker's verdict= (#186).
#
# post_comment.sh --verdict stamps `verdict=<CLEAN|FIXES_APPLIED|NEEDS_DECISION|
# BLOCKED>` into the record marker (#185). Until #186 nothing in this repo read
# it: ci/cross-review-currency.sh reported `success` and merge_preflight.sh
# reported `clear` for a FIXES_APPLIED / NEEDS_DECISION / BLOCKED record at the
# head, because both only compared the sha. That is kindred-mama-ai#3362 pass
# 5: a head the reviewers had just flagged read as clean at the merge button.
#
# Rules pinned here:
#   - an EXPLICIT non-CLEAN verdict at the head is `pending`, never a clearance;
#   - a record with no verdict (every record before #185, and every prose-only
#     stamp) keeps its old meaning — absence is "predates the field", not "bad";
#   - the verdict is read from the SAME marker the sha came from, never from a
#     marker quoted further down the comment;
#   - range coverage still counts FIXES_APPLIED records (fixes land in later
#     commits that later records must cover) but not BLOCKED / NEEDS_DECISION
#     ones: a range whose only review ended unresolved is not reviewed-and-ok.
#
# Offline: gh is a PATH shim; git runs on a fixture repo.
# Run:  bash tests/test_gates_verdict.sh   ·   Exit: 0 all green, 1 any failure.
set -uo pipefail
SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
S="$SKILL_DIR/scripts"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
PASS=0; FAIL=0
ok()  { echo "  ok   $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL $1"; FAIL=$((FAIL + 1)); }
assert_eq() { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 (got: '$2' want: '$3')"; fi; }
assert_contains() { if [[ "$2" == *"$3"* ]]; then ok "$1"; else bad "$1 (no '$3' in: ${2:0:160})"; fi; }

command -v jq >/dev/null 2>&1 || { echo "  skip gates verdict (jq unavailable)"; exit 0; }

H='399df23d4d5945162d0c5ed623484d608337165d'
OLD='b813773500000000000000000000000000000000'
rec() {  # rec <sha> <verdict|-> [extra marker fields] — one record body
  local v=""; [[ "$2" != "-" ]] && v=" verdict=$2"
  printf '## Cross-review — pass 2\n<!-- cross-review: sha=%s pass=2%s%s -->\nFindings below.\n' "$1" "${3:-}" "$v"
}
stamp() { printf '%s' "$1" | bash "$S/read_stamp.sh" --body-stdin 2>/dev/null | jq -r "$2"; }

echo "── read_stamp.sh: verdict ──"
for v in CLEAN FIXES_APPLIED NEEDS_DECISION BLOCKED; do
  assert_eq "reads verdict=$v" "$(stamp "$(rec $H $v)" .verdict)" "$v"
done
assert_eq "no verdict field → empty (legacy)" "$(stamp "$(rec $H -)" .verdict)" ""
assert_eq "a value outside the vocabulary → empty" "$(stamp "$(rec $H CLEANISH)" .verdict)" ""
assert_eq "prose-only stamp → empty" \
  "$(stamp '## Cross-review — pass 1
_Reviewed `399df23d4`._' .verdict)" ""
# The record's own marker has no verdict; a quoted older marker below it does.
QUOTED="$(rec $H -)
> earlier pass: <!-- cross-review: sha=$OLD pass=1 verdict=BLOCKED -->"
assert_eq "a quoted marker's verdict does not leak into the record" "$(stamp "$QUOTED" .verdict)" ""
assert_eq "…and the sha still comes from the record's own marker" "$(stamp "$QUOTED" .sha)" "$H"

# ── merge_preflight.sh ──────────────────────────────────────────────────────
mkdir -p "$T/bin"
cat >"$T/bin/gh" <<SH
#!/bin/sh
cat "$T/fixture.json" 2>/dev/null || true
SH
chmod +x "$T/bin/gh"
export PATH="$T/bin:$PATH"

pr_json() {  # pr_json <head> <body>... → gh pr view fixture, oldest first
  local head="$1"; shift
  local c="[]" b
  for b in "$@"; do c="$(jq -c --arg b "$b" '. + [{body:$b}]' <<<"$c")"; done
  jq -nc --arg h "$head" --argjson c "$c" \
    '{headRefOid:$h, state:"OPEN", baseRefName:"master", number:7, url:"https://github.com/o/r/pull/7", comments:$c}'
}
pf() {  # pf <dir> <fixture> → "<status> <rc>"
  printf '%s' "$2" >"$T/fixture.json"
  local out rc
  out="$(cd "$1" && bash "$S/merge_preflight.sh" --pr 7 --json 2>/dev/null)"; rc=$?
  printf '%s %s' "$(jq -r '.status // ""' <<<"$out" 2>/dev/null)" "$rc"
}

echo "── merge_preflight.sh: point check ──"
for v in FIXES_APPLIED NEEDS_DECISION BLOCKED; do
  assert_eq "$v at the head is pending and blocks (rc 1)" "$(pf "$T" "$(pr_json $H "$(rec $H $v)")")" "pending 1"
done
assert_eq "control: CLEAN at the head clears" "$(pf "$T" "$(pr_json $H "$(rec $H CLEAN)")")" "clear 0"
assert_eq "control: no verdict at the head clears (legacy)" "$(pf "$T" "$(pr_json $H "$(rec $H -)")")" "clear 0"
printf '%s' "$(pr_json $H "$(rec $H FIXES_APPLIED)")" >"$T/fixture.json"
assert_contains "the pending reason names the verdict" \
  "$(cd "$T" && bash "$S/merge_preflight.sh" --pr 7 2>/dev/null)" "FIXES_APPLIED"

echo "── merge_preflight.sh: range coverage ──"
# master: B0.  PR: B0 → A → B (head).  r0A covers B0..A, rAB covers A..B.
# Ordering puts r0A NEWEST, so the point check sees A ≠ head and coverage —
# the union of every record — decides.
REPO="$T/repo"; mkdir -p "$REPO"
( cd "$REPO" && { git init -q -b master 2>/dev/null || git init -q; } && git config user.email t@t && git config user.name t
  printf '0\n' >f && git add f && git commit -qm base && git checkout -qb feat
  printf '1\n' >f && git commit -qam A && printf '2\n' >f && git commit -qam B ) >/dev/null 2>&1
B0="$(git -C "$REPO" rev-parse master)"; A="$(git -C "$REPO" rev-parse feat~1)"; B="$(git -C "$REPO" rev-parse feat)"
cov() {  # cov <verdict of rAB> <verdict of r0A>
  pf "$REPO" "$(pr_json "$B" "$(rec "$B" "$1" " base=$A")" "$(rec "$A" "$2" " base=$B0")")"
}
assert_eq "control: two CLEAN records covering every commit clear" "$(cov CLEAN CLEAN)" "clear 0"
assert_eq "FIXES_APPLIED records still count toward coverage" "$(cov FIXES_APPLIED FIXES_APPLIED)" "clear 0"
assert_eq "records with no verdict still count (legacy)" "$(cov - -)" "clear 0"
assert_eq "a BLOCKED record covers nothing (A..B left unreviewed)" "$(cov BLOCKED CLEAN)" "stale 1"
assert_eq "a NEEDS_DECISION record covers nothing (B0..A left unreviewed)" "$(cov CLEAN NEEDS_DECISION)" "stale 1"

# ── ci/cross-review-currency.sh ─────────────────────────────────────────────
echo "── currency CI: currency_verdict ──"
# shellcheck disable=SC1091
source "$SKILL_DIR/ci/cross-review-currency.sh"
cv() { currency_verdict "$(jq -nc --arg b "$1" '[{body:$b, user:"o", assoc:"OWNER"}]')" "$H" ""; }
for v in FIXES_APPLIED NEEDS_DECISION BLOCKED; do
  assert_eq "$v at the head is pending, not success" "$(cv "$(rec $H $v)" | cut -f1)" "pending"
done
assert_contains "…and says which verdict" "$(cv "$(rec $H BLOCKED)" | cut -f2)" "BLOCKED"
assert_eq "control: CLEAN at the head is success" "$(cv "$(rec $H CLEAN)" | cut -f1)" "success"
assert_eq "control: no verdict at the head is success (legacy)" "$(cv "$(rec $H -)" | cut -f1)" "success"
assert_eq "a quoted marker's BLOCKED does not downgrade a clean record" "$(cv "$QUOTED" | cut -f1)" "success"
assert_eq "a non-CLEAN record is not a clearance (non-zero return)" \
  "$(cv "$(rec $H FIXES_APPLIED)" >/dev/null; echo $?)" "1"

# A CI install can update this script while an OLDER read_stamp.sh — one with
# no verdict field — still sits beside it. Its sha must not stand in for a
# verdict it never read. (codex P1, #188 pass 1.)
OLD_TREE="$T/old-install"; mkdir -p "$OLD_TREE/ci" "$OLD_TREE/scripts"
cp "$SKILL_DIR/ci/cross-review-currency.sh" "$OLD_TREE/ci/"
cat >"$OLD_TREE/scripts/read_stamp.sh" <<'OLD'
#!/usr/bin/env bash
# read_stamp.sh as it was before #186: a marker sha, and no verdict key at all.
body="$(cat)"
sha="$(grep -oE '<!-- cross-review: sha=[0-9a-f]{40}' <<<"$body" | head -1 | sed 's/.*sha=//')"
jq -cn --arg s "$sha" '{stamped:true, sha:$s, base:"", pass:0, digest:"", source:"marker", abbrev:40, disagreement:null}'
OLD
chmod +x "$OLD_TREE/scripts/read_stamp.sh"
old_cv() {
  ( source "$OLD_TREE/ci/cross-review-currency.sh"
    currency_verdict "$(jq -nc --arg b "$1" '[{body:$b, user:"o", assoc:"OWNER"}]')" "$H" "" ) | cut -f1
}
assert_eq "beside a pre-verdict read_stamp.sh, BLOCKED at the head is still pending" \
  "$(old_cv "$(rec $H BLOCKED)")" "pending"
assert_eq "…and CLEAN beside it is still success" "$(old_cv "$(rec $H CLEAN)")" "success"

# ── hooks/merge_gate.sh ─────────────────────────────────────────────────────
echo "── merge_gate.sh: a pending preflight is refused ──"
hook() {  # hook <fixture> <command> → permission decision, or PASS; reason in $T/reason
  printf '%s' "$1" >"$T/fixture.json"
  printf '{"tool_input":{"command":%s}}' "$(jq -Rn --arg c "$2" '$c')" \
    | (cd "$T" && bash "$SKILL_DIR/hooks/merge_gate.sh" 2>/dev/null) >"$T/hook.out"
  jq -r '.hookSpecificOutput.permissionDecisionReason // ""' "$T/hook.out" >"$T/reason" 2>/dev/null
  jq -r '.hookSpecificOutput.permissionDecision // "PASS"' "$T/hook.out" 2>/dev/null
}
assert_eq "a FIXES_APPLIED record at the head is denied" \
  "$(hook "$(pr_json $H "$(rec $H FIXES_APPLIED)")" "gh pr merge 7 --match-head-commit $H")" "deny"
assert_contains "…with a reason naming the verdict, not 'stale'" "$(cat "$T/reason")" "FIXES_APPLIED"
assert_eq "…and so is the same merge through the REST endpoint" \
  "$(hook "$(pr_json $H "$(rec $H BLOCKED)")" "gh api -X PUT repos/o/r/pulls/7/merge")" "deny"
assert_eq "control: a CLEAN record at the head passes" \
  "$(hook "$(pr_json $H "$(rec $H CLEAN)")" "gh pr merge 7 --match-head-commit $H")" "PASS"

echo
echo "══ $PASS passed, $FAIL failed ══"
[[ "$FAIL" -eq 0 ]]
