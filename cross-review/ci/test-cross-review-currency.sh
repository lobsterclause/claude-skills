#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# test-cross-review-currency.sh — offline unit tests for
# cross-review-currency.sh. No network, no gh, no tokens: the harness sources
# the script and calls currency_verdict() with fixtures.
#
# This is the shape agent-cross-review.sh established, and for its reason: the
# gate before it (agent-plan-gate.yml) kept its decision logic inside a
# workflow `run:` block, so its harness could only assert that certain LINES
# appeared in the YAML. That is a fidelity check, not a behaviour check, and it
# missed two real bypasses.
#
# Every assertion here is paired with a control that would fail if the check
# stopped discriminating. A green suite on a check that says "success" to
# everything is the exact failure this gate exists to prevent, and it would be
# invisible without the controls.
#
# Run: bash scripts/test-cross-review-currency.sh
# ---------------------------------------------------------------------------

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
source "$HERE/cross-review-currency.sh"

# The workflow under test sits beside the script here, because this directory
# IS the distributable unit. In a consuming repo the same three files land in
# scripts/ and .github/workflows/, so accept either layout rather than forcing
# adopters to patch the harness they were given.
if [[ -f "$HERE/cross-review-currency.yml" ]]; then
  CR_WF_PATH="$HERE/cross-review-currency.yml"
else
  CR_WF_PATH="$HERE/../.github/workflows/cross-review-currency.yml"
fi

# The skill half of the contract. Prefer the SIBLING copy — in this repo the
# gate and post_comment.sh ship together, so the contract test binds the two
# files that are actually released as a pair. Fall back to an installed skill
# so the harness still means something when these files have been copied into
# a consuming repo, where no sibling exists.
if [[ -f "$HERE/../scripts/post_comment.sh" ]]; then
  CR_PCS_PATH="$HERE/../scripts/post_comment.sh"
else
  CR_PCS_PATH="$HOME/.claude/skills/cross-review/scripts/post_comment.sh"
fi

PASS=0
FAIL=0
ok()  { echo "  ok   $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL $1"; FAIL=$((FAIL + 1)); }
assert_eq() {
  if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 (got '$2' want '$3')"; fi
}
assert_contains() {
  if [[ "$2" == *"$3"* ]]; then ok "$1"; else bad "$1 (no '$3' in '$2')"; fi
}
assert_not_contains() {
  if [[ "$2" != *"$3"* ]]; then ok "$1"; else bad "$1 (found '$3' in output)"; fi
}

HEAD40='4b03c063d540de4d62498da2d28cd20e798d7b02'
OTHER40='37f0839938e45517b4e7007298f916ca412219c3'

# The account that grants exemptions in these fixtures. An exemption is now
# bound to the granting human as well as to the head commit, so the default
# author below has to match EXEMPT_HUMAN's actor or every hatch test would be
# asserting the refusal path by accident.
GRANTER='gjalmaraz'

# comments_as <author> <assoc> <body>... → the JSON array shape fetch_comments
# returns. fetch_comments carries the comment AUTHOR (the second half of the
# exemption binding) and the author's repository STANDING (what the stamp path
# requires), so the fixture has to carry both.
comments_as() {
  local author="$1" assoc="$2"; shift 2
  local out="[]" b
  for b in "$@"; do
    out="$(printf '%s' "$out" | jq -c --arg b "$b" --arg u "$author" --arg a "$assoc" \
      '. + [{body: $b, user: $u, assoc: $a}]')"
  done
  printf '%s' "$out"
}
# comments_perm <author> <assoc> <perm> <body>... — the full shape
# fetch_comments returns once it has resolved the author's REPOSITORY
# PERMISSION, which is a different fact from the association.
comments_perm() {
  local author="$1" assoc="$2" perm="$3"; shift 3
  local out="[]" b
  for b in "$@"; do
    out="$(printf '%s' "$out" | jq -c --arg b "$b" --arg u "$author" --arg a "$assoc" --arg p "$perm" \
      '. + [{body: $b, user: $u, assoc: $a, perm: $p}]')"
  done
  printf '%s' "$out"
}
# comments_by <author> <body>... — a trusted author. MEMBER rather than OWNER
# so the tests exercise the middle of the trusted set rather than only its
# most privileged element.
comments_by() { local a="$1"; shift; comments_as "$a" MEMBER "$@"; }
# comments <body>... — authored by the granting human, who has write access.
# Convenience for the hatch tests, and for stamp tests whose subject is the
# stamp rather than the poster.
comments() { comments_by "$GRANTER" "$@"; }
# The pre-author shape: a body with no author and no standing attached at all,
# which is what a comment record we could not attribute looks like.
comments_anon() {
  local out="[]" b
  for b in "$@"; do
    out="$(printf '%s' "$out" | jq -c --arg b "$b" '. + [{body: $b}]')"
  done
  printf '%s' "$out"
}
state_of() { currency_verdict "$1" "$2" "${3:-}" | cut -f1; }
desc_of()  { currency_verdict "$1" "$2" "${3:-}" | cut -f2; }

# exemption <labeled-true|false> <actor> <actor_type> → the shape
# fetch_exemption returns. NOTE: `$1` is spliced with --argjson so it must be a
# JSON literal, not the STRING "false" — in bash `[[ false ]]` is true, and an
# exemption gate that treats the string "false" as truthy is exactly the
# fail-open this file exists to close.
exemption() {
  jq -nc --argjson l "$1" --arg a "${2:-}" --arg t "${3:-}" \
    '{labeled: $l, actor: $a, actor_type: $t}'
}
# An exemption is bound to the commit it was granted for: the justification
# comment has to name that commit. UNBOUND is the old shape, which GitHub
# preserves across pushes and which therefore authorised commits nobody looked
# at. BOUND names this head; STALE_BOUND names the commit before it.
JUSTIFIED="Cross-review exemption: docs-only change, no executable code touched. ${HEAD40:0:9}"
JUSTIFIED_UNBOUND='Cross-review exemption: docs-only change, no executable code touched.'
JUSTIFIED_STALE="Cross-review exemption: docs-only change, no executable code touched. ${OTHER40:0:9}"
NOT_EXEMPT="$(exemption false '' '')"
EXEMPT_HUMAN="$(exemption true "$GRANTER" User)"
EXEMPT_BOT="$(exemption true 'github-actions[bot]' Bot)"
# The shape fetch_exemption produces when it could not read the timeline: the
# label is there, but who applied it and when is unknown. Same precedent as
# fetch_comments returning `null` rather than `[]`.
EXEMPT_UNKNOWN="$(exemption true '' '')"

STAMPED_CURRENT="## Cross-review — pass 1

_Automated review by codex + kimi. Reviewed \`${HEAD40:0:9}\`._"
STAMPED_OLD="## Cross-review — pass 1

_Automated review by codex + kimi. Reviewed \`${OTHER40:0:9}\`._"
UNSTAMPED="## Cross-review — pass 2

_Automated review by codex. No stamp on this one._"

# The prose variant four PRs were actually carrying. `Reviewed at` was rejected
# by the old regex purely over the word "at", so #3376, #3374, #3371 and #3362
# read as unreviewed while being reviewed at their exact current head.
PROSE_AT_CURRENT="## Cross-review — pass 1

_Automated review by codex + kimi. Reviewed at \`${HEAD40:0:7}\`._"
PROSE_AT_OLD="## Cross-review — pass 1

_Automated review by codex + kimi. Reviewed at \`${OTHER40:0:7}\`._"

# The machine-written stamp. post_comment.sh emits this unconditionally
# whenever a head sha is known; it carries the FULL 40 characters, so it is not
# subject to the abbreviation ambiguity the prose forms have.
marker() { printf '<!-- cross-review: sha=%s pass=%s -->' "$1" "${2:-1}"; }
MARKER_CURRENT="## Cross-review — pass 1

$(marker "$HEAD40" 1)

_Automated review by codex + kimi. Reviewed \`${HEAD40:0:9}\`._"
MARKER_STALE="## Cross-review — pass 1

$(marker "$OTHER40" 1)

_Automated review by codex + kimi. Reviewed \`${OTHER40:0:9}\`._"
# Disagreement fixtures. The marker is the contract; the prose is decoration a
# model may hand-edit, so when they conflict the marker decides.
MARKER_CURRENT_PROSE_STALE="## Cross-review — pass 1

$(marker "$HEAD40" 1)

_Automated review by codex. Reviewed \`${OTHER40:0:9}\`._"
MARKER_STALE_PROSE_CURRENT="## Cross-review — pass 1

$(marker "$OTHER40" 1)

_Automated review by codex. Reviewed \`${HEAD40:0:9}\`._"

echo "── cross-review currency verdict ──"

# The whole point.
assert_eq "a record bound to another commit fails" \
  "$(state_of "$(comments "$STAMPED_OLD")" "$HEAD40")" "failure"
assert_contains "and the description names both commits" \
  "$(desc_of "$(comments "$STAMPED_OLD")" "$HEAD40")" "reviewed ${OTHER40:0:9}, head is ${HEAD40:0:9}"

# CONTROL — without this, every assertion in this file would also pass on a
# check that reports failure unconditionally.
assert_eq "control: a record bound to this commit succeeds" \
  "$(state_of "$(comments "$STAMPED_CURRENT")" "$HEAD40")" "success"

# RED when absent. This is the policy line, and it MOVED: the check used to
# report success for a PR nobody had reviewed, which made "never reviewed" and
# "reviewed at this exact commit" render identically at the merge button. Six
# PRs merged in one night carrying "no cross-review record on this PR"; #3388
# shipped a user-trapping dead end in mobile signup through that gap.
assert_eq "a PR with no cross-review record is RED" \
  "$(state_of "$(comments)" "$HEAD40")" "failure"
assert_contains "and tells the developer what to do about it" \
  "$(desc_of "$(comments)" "$HEAD40")" "run /cross-review"

# An unstamped record cannot mask a stale one behind it. post_comment.sh still
# emits unstamped records when --head-sha is omitted, so selecting the newest
# comment of ANY kind let the tool this gate serves switch the gate off.
assert_eq "an unstamped later record cannot mask a stale one" \
  "$(state_of "$(comments "$STAMPED_OLD" "$UNSTAMPED")" "$HEAD40")" "failure"

# An unverifiable record is RED too. A record with no stamp proves nothing
# about which commit was read, and "cannot verify" reported as success is the
# same fail-open wearing a different description — 7 of the 40 open PRs sat in
# exactly this state.
assert_eq "records with no stamp at all are RED" \
  "$(state_of "$(comments "$UNSTAMPED")" "$HEAD40")" "failure"
assert_contains "and say why, actionably" \
  "$(desc_of "$(comments "$UNSTAMPED")" "$HEAD40")" "no SHA stamp"
assert_contains "and point at the remedy" \
  "$(desc_of "$(comments "$UNSTAMPED")" "$HEAD40")" "re-run /cross-review"

# Newest stamped wins — this is what lets a re-review clear a red check without
# a new push. Ordered oldest-first, as the REST endpoint returns them.
assert_eq "a newer passing review clears an older stale one" \
  "$(state_of "$(comments "$STAMPED_OLD" "$STAMPED_CURRENT")" "$HEAD40")" "success"

# CONTROL for the ordering: reversed, the stale one is newest and must fail.
# Without this, "newest wins" is indistinguishable from "any match wins".
assert_eq "control: a newer stale review re-reds a previously clear PR" \
  "$(state_of "$(comments "$STAMPED_CURRENT" "$STAMPED_OLD")" "$HEAD40")" "failure"

# A human quoting the header in discussion is not a review record — and now
# that "no record" is red, chatter cannot accidentally satisfy the gate either.
assert_eq "a comment merely mentioning the header is ignored" \
  "$(state_of "$(comments "did the ## Cross-review pass? Reviewed \`${OTHER40:0:9}\` I think")" "$HEAD40")" \
  "failure"

# Operational failures are still green, never red. The distinction that makes
# this survivable alongside a fail-CLOSED default: "we read the comments and
# there were none" (red) is a different fact from "we could not read the
# comments" (green). fetch_comments now signals the latter with a non-array,
# so a GitHub hiccup cannot red-flag all 40 open PRs at once.
assert_eq "an unknown head commit is green" \
  "$(state_of "$(comments "$STAMPED_OLD")" "")" "success"
assert_eq "unreadable comment data is green, not red" \
  "$(state_of "not json at all" "$HEAD40")" "success"
assert_contains "and says it could not read them" \
  "$(desc_of "not json at all" "$HEAD40")" "could not read"
# CONTROL: a well-formed EMPTY array is a real answer, and it is red. Without
# this, "unreadable is green" would be indistinguishable from "empty is green"
# — the exact conflation that kept 30 unreviewed PRs mergeable.
assert_eq "control: a readable but empty comment list is red" \
  "$(state_of "[]" "$HEAD40")" "failure"

# The description is a commit-status field with a hard 140-char limit.
for fixture in "$STAMPED_OLD" "$STAMPED_CURRENT" "$UNSTAMPED"; do
  d="$(desc_of "$(comments "$fixture")" "$HEAD40")"
  if [[ "${#d}" -le 140 ]]; then
    ok "description fits the commit-status limit (${#d} chars)"
  else
    bad "description exceeds 140 chars (${#d})"
  fi
done

echo
echo "── the machine-written marker, and the prose it falls back to ──"
#
# The stamp used to be prose only, and prose drifts. Census of the 10 most
# recent cross-review comments on open PRs, 2026-08-14:
#
#   3376 3374 3371 3362  "Reviewed at `<sha>`"  — matched the head, REJECTED
#   3369 3367 3363 3073  no SHA anywhere
#   3407 3298            "Reviewed `<sha>`"     — genuinely stale
#
# Four PRs were correctly and currently reviewed and read as unreviewed because
# of one English word. Two fixes, in order of preference: post_comment.sh now
# emits a machine-written marker carrying the full 40-char sha, and the gate
# reads that first; the prose forms stay readable so every comment already on
# GitHub keeps working.

assert_eq "the marker, bound to this commit, succeeds" \
  "$(state_of "$(comments "$MARKER_CURRENT")" "$HEAD40")" "success"
# CONTROL — without it, "marker succeeds" would also pass on a gate that says
# success to any comment carrying a marker at all.
assert_eq "control: the marker, bound to another commit, fails" \
  "$(state_of "$(comments "$MARKER_STALE")" "$HEAD40")" "failure"
assert_contains "and the stale marker names both commits" \
  "$(desc_of "$(comments "$MARKER_STALE")" "$HEAD40")" "head is ${HEAD40:0:9}"

# THE ACTUAL BUG. One English word, four PRs.
assert_eq "prose 'Reviewed at \`sha\`' is accepted" \
  "$(state_of "$(comments "$PROSE_AT_CURRENT")" "$HEAD40")" "success"
# CONTROL — the widened regex must still discriminate, not just match more.
assert_eq "control: 'Reviewed at' bound to another commit still fails" \
  "$(state_of "$(comments "$PROSE_AT_OLD")" "$HEAD40")" "failure"

# The original prose form has to keep working — comments posted before this
# change are still the only record those PRs have.
assert_eq "prose 'Reviewed \`sha\`' still succeeds" \
  "$(state_of "$(comments "$STAMPED_CURRENT")" "$HEAD40")" "success"
assert_eq "control: and still fails when bound elsewhere" \
  "$(state_of "$(comments "$STAMPED_OLD")" "$HEAD40")" "failure"

# No stamp of either kind is still red.
assert_eq "a record with neither marker nor prose sha is red" \
  "$(state_of "$(comments "$UNSTAMPED")" "$HEAD40")" "failure"

# PRECEDENCE. The marker is machine-written and the prose is not, so when they
# disagree the marker decides — in both directions, or "marker wins" is
# indistinguishable from "whichever one happens to be current wins".
assert_eq "marker current beats prose stale" \
  "$(state_of "$(comments "$MARKER_CURRENT_PROSE_STALE")" "$HEAD40")" "success"
assert_eq "control: marker stale beats prose current" \
  "$(state_of "$(comments "$MARKER_STALE_PROSE_CURRENT")" "$HEAD40")" "failure"

# The marker is an HTML comment, so it must not be visible in rendered markdown
# and must not leak into the 140-char commit-status description.
d="$(desc_of "$(comments "$MARKER_CURRENT")" "$HEAD40")"
if [[ "$d" != *"<!--"* ]]; then ok "the marker does not leak into the status description"
else bad "the marker leaked into the status description: $d"; fi

# Ordering still holds across the two stamp kinds: newest record wins whichever
# form it uses, so a prose re-review can clear a stale marker and vice versa.
assert_eq "a newer prose review clears an older stale marker" \
  "$(state_of "$(comments "$MARKER_STALE" "$PROSE_AT_CURRENT")" "$HEAD40")" "success"
assert_eq "control: a newer stale marker re-reds a clear prose review" \
  "$(state_of "$(comments "$PROSE_AT_CURRENT" "$MARKER_STALE")" "$HEAD40")" "failure"

# Prose chatter must not become a stamp just because the regex widened. A body
# that starts with the header but only mentions a hex string in passing carries
# no claim about coverage.
assert_eq "a hex string in passing prose is not a stamp" \
  "$(state_of "$(comments "## Cross-review discussion

I looked at ${HEAD40:0:9} and it seemed fine to me.")" "$HEAD40")" "failure"

echo
echo "── against the live comment bodies that motivated this ──"
# Verbatim shapes read from the four rejected PRs and the two genuinely stale
# ones on 2026-08-14. Abbreviations are 7 chars, which is what those comments
# actually carry — the fixtures above use 7 and 9 to cover both widths.
LIVE_3376_HEAD='15329998d815153c669c2df2dd147a5a193432ab'
LIVE_3407_HEAD='0313f28b9ee3088e275ba6b7fbb4882bb3e0ac48'
assert_eq "#3376's real comment now reads as current" \
  "$(state_of "$(comments "## Cross-review — pass 1

_Automated review by codex + glm + kimi. Reviewed at \`1532999\`._")" "$LIVE_3376_HEAD")" "success"
# CONTROL — #3407's head genuinely moved, and its comment even carries the
# staleness banner naming the newer sha. The gate must read the REVIEWED sha
# out of that line, not the current-head sha sitting beside it.
assert_eq "control: #3407's real comment still reads as stale" \
  "$(state_of "$(comments "## Cross-review — pass 3

> [!WARNING]
> **Stale: the head moved during this review.** Reviewed \`1e3013326\`, current head is \`0313f28b9\`.

_Automated review by codex + kimi. Reviewed \`1e3013326\`._")" "$LIVE_3407_HEAD")" "failure"

echo
echo "── a record only counts from an account with repository standing ──"
# THE FINDING (cross-review of PR #63, gemini-pro, Critical). The stamp path
# selected the newest record on its BODY alone and never asked who wrote it,
# so anyone who could comment on a pull request could turn a REQUIRED check
# green by pasting the header and a marker naming the head sha. On a fork PR
# that is the contributor themselves — precisely the person the gate exists to
# bind. The data was already being fetched; the stamp path just never looked.
#
# The rule is repository STANDING, not authorship. See CR_TRUSTED_ASSOC.

# The attack, in one line: a correct, current, perfectly-formatted stamp, from
# somebody with no write access.
assert_eq "an outside contributor cannot self-certify with a forged marker" \
  "$(state_of "$(comments_as 'drive-by' CONTRIBUTOR "$MARKER_CURRENT")" "$HEAD40")" "failure"
assert_eq "nor with the prose form" \
  "$(state_of "$(comments_as 'drive-by' CONTRIBUTOR "$STAMPED_CURRENT")" "$HEAD40")" "failure"
assert_eq "nor can a first-time contributor" \
  "$(state_of "$(comments_as 'newcomer' FIRST_TIME_CONTRIBUTOR "$MARKER_CURRENT")" "$HEAD40")" "failure"
assert_eq "nor a passer-by with no association at all" \
  "$(state_of "$(comments_as 'nobody' NONE "$MARKER_CURRENT")" "$HEAD40")" "failure"

# CONTROLS — every account that SHOULD be able to post a record still can.
# Without these the trust filter could be "reject everything" and the four
# assertions above would all still pass.
for assoc in OWNER MEMBER COLLABORATOR; do
  assert_eq "control: a record from $assoc is honoured" \
    "$(state_of "$(comments_as 'maintainer' "$assoc" "$MARKER_CURRENT")" "$HEAD40")" "success"
done

# The refusal has to name the actual problem. Reporting an untrusted record as
# "no cross-review record" reads as an oversight — someone forgot to review —
# when what happened is that something tried to sign off and could not.
assert_contains "and says the record lacked standing, not that none existed" \
  "$(desc_of "$(comments_as 'drive-by' CONTRIBUTOR "$MARKER_CURRENT")" "$HEAD40")" "not from an account with write access"

# An unattributable record is refused, fail-CLOSED, and this is the one place
# the gate deliberately does NOT fail open. The distinction it turns on:
# fetch_comments returning `null` is "we could not read" and stays green (the
# case just below); a comment we DID read that carries no standing is not an
# outage, it is an unsigned record.
assert_eq "a record we cannot attribute is refused" \
  "$(state_of "$(comments_anon "$MARKER_CURRENT")" "$HEAD40")" "failure"
assert_eq "control: an unreadable comment FETCH is still green" \
  "$(state_of "null" "$HEAD40")" "success"

# ORDERING. The author filter has to run before "newest wins", not after.
# Filtering afterwards would let anyone red-flag a properly reviewed PR just by
# commenting on it — the forged record would be selected as newest and then
# rejected, suppressing the genuine one behind it. That is a denial of service
# on the gate, and it is the failure mode a naive fix walks straight into.
assert_eq "a forged record posted AFTER a real one does not suppress it" \
  "$(state_of "$(printf '%s' "$(comments_by 'maintainer' "$MARKER_CURRENT")$(comments_as 'drive-by' CONTRIBUTOR "$MARKER_CURRENT")" | jq -sc 'add')" "$HEAD40")" \
  "success"

# ...and the mirror image: standing does not excuse staleness. A trusted
# account's stale record is still stale, so the filter cannot have been
# implemented as "trusted author ⇒ pass".
assert_eq "control: a trusted account's stale record is still stale" \
  "$(state_of "$(comments_by 'maintainer' "$STAMPED_OLD")" "$HEAD40")" "failure"

# The trusted set is configurable, because a repo that posts every review from
# one bot account wants to gate on that account's standing and nothing else.
assert_eq "CR_TRUSTED_ASSOC narrows the set" \
  "$(CR_TRUSTED_ASSOC=OWNER state_of "$(comments_as 'maintainer' MEMBER "$MARKER_CURRENT")" "$HEAD40")" \
  "failure"
assert_eq "control: and still admits what it does list" \
  "$(CR_TRUSTED_ASSOC=OWNER state_of "$(comments_as 'maintainer' OWNER "$MARKER_CURRENT")" "$HEAD40")" \
  "success"

# The hatch was already bound to a human; it must not become reachable through
# the weaker of the two paths now that both exist.
assert_eq "an untrusted account cannot post a stamp to dodge the hatch either" \
  "$(state_of "$(comments_as 'drive-by' CONTRIBUTOR "$MARKER_CURRENT")" "$HEAD40" "$(exemption false '' '')")" \
  "failure"

echo
echo "── association is not permission ──"
#
# FINDING (codex, P1, cross-review of PR #63 pass 2). The association filter
# shipped in pass 1 called OWNER/MEMBER/COLLABORATOR "repository standing", and
# on an organisation repo that is not what those values mean. `MEMBER` is
# membership of the owning ORG — on a public repo, possibly with no access to
# this repo at all. `COLLABORATOR` covers read-only and triage-only invitations.
# So the fix that opened pass 1 still admitted accounts that cannot push. The
# authority is the repository permission, resolved per author by fetch_comments
# and carried as `perm`.

# THE ATTACK. An org member, or a read-only invited collaborator, posts a record
# stamped to the current head. The association says MEMBER; the permission says
# read; the gate must not go green.
assert_eq "an org MEMBER without write access cannot sign off" \
  "$(state_of "$(comments_perm someone MEMBER read "$MARKER_CURRENT")" "$HEAD40")" "failure"
assert_contains "and the refusal names write access, not membership" \
  "$(desc_of "$(comments_perm someone MEMBER read "$MARKER_CURRENT")" "$HEAD40")" "write access"
assert_eq "nor can a triage-only collaborator" \
  "$(state_of "$(comments_perm someone COLLABORATOR triage "$MARKER_CURRENT")" "$HEAD40")" "failure"

# CONTROLS. The three permissions that DO mean "can push" must all still pass,
# or this has simply broken the gate for everyone.
for perm in admin write maintain; do
  assert_eq "control: a COLLABORATOR with $perm access still signs off" \
    "$(state_of "$(comments_perm someone COLLABORATOR "$perm" "$MARKER_CURRENT")" "$HEAD40")" "success"
done
# OWNER short-circuits: it is unambiguous, and looking it up would cost an API
# call per run on the single-maintainer repo that is the common case.
assert_eq "control: OWNER needs no permission lookup" \
  "$(state_of "$(comments_perm boss OWNER "" "$MARKER_CURRENT")" "$HEAD40")" "success"

# ORDERING, again. The permission filter runs before "newest wins" for the same
# reason the association filter does: a read-only account commenting after a
# real review must not be able to turn a green PR red.
NOWRITE_THEN_REAL="$(jq -c --arg m "$MARKER_CURRENT" \
  '[{body: $m, user: "boss", assoc: "OWNER", perm: "admin"},
    {body: $m, user: "drive-by", assoc: "MEMBER", perm: "read"}]' <<< 'null')"
assert_eq "a read-only comment posted AFTER a real review does not suppress it" \
  "$(state_of "$NOWRITE_THEN_REAL" "$HEAD40")" "success"

echo
echo "── an unverifiable permission is allowed, but never silently ──"
#
# That endpoint is itself gated on the caller having push access, and a workflow
# token's scope for it varies by repository type — so an empty `perm` may be an
# outage OR may be permanent for this repo. Refusing on empty would make the
# gate permanently red wherever the token cannot read it, which is how a gate
# gets switched off for good. It is waved through, and it SAYS so.
assert_eq "an unreadable permission falls back to the association" \
  "$(state_of "$(comments_perm someone MEMBER "" "$MARKER_CURRENT")" "$HEAD40")" "success"
assert_contains "and the status admits the standing was never verified" \
  "$(desc_of "$(comments_perm someone MEMBER "" "$MARKER_CURRENT")" "$HEAD40")" "standing unverified"
# CONTROL: a VERIFIED record must not carry that caveat, or it is noise on every
# status and stops meaning anything.
[[ "$(desc_of "$(comments_perm someone MEMBER write "$MARKER_CURRENT")" "$HEAD40")" != *"unverified"* ]] \
  && ok "control: a verified record is not labelled unverified" \
  || bad "every success is labelled unverified — the caveat is noise"

# The strict policy, for repos that know their token can read permissions.
# NOT in a subshell: ok/bad increment PASS/FAIL, and a subshell's copies are
# discarded on exit — these three would print their results and then fail to
# fail the suite, which is the advisory-test shape this whole harness exists to
# avoid. Set, assert, restore.
CR_PERMISSION_UNREADABLE=refuse
assert_eq "CR_PERMISSION_UNREADABLE=refuse turns the same record down" \
  "$(state_of "$(comments_perm someone MEMBER "" "$MARKER_CURRENT")" "$HEAD40")" "failure"
assert_eq "control: and still admits one whose permission WAS read" \
  "$(state_of "$(comments_perm someone MEMBER write "$MARKER_CURRENT")" "$HEAD40")" "success"
assert_eq "control: and OWNER survives it, having needed no lookup" \
  "$(state_of "$(comments_perm boss OWNER "" "$MARKER_CURRENT")" "$HEAD40")" "success"
CR_PERMISSION_UNREADABLE=trust
# CONTROL: the restore actually took, or every case after this one is running
# under the strict policy by accident.
assert_eq "control: the default policy is restored for the rest of the run" \
  "$(state_of "$(comments_perm someone MEMBER "" "$MARKER_CURRENT")" "$HEAD40")" "success"

echo
echo "── the skill emits what the gate reads ──"
# Half 1 and Half 2 have to agree on one marker format, and nothing else checks
# that they do. This asserts against post_comment.sh itself when it is present
# on this machine — the gate's regex must match the string the skill writes.
PCS="$CR_PCS_PATH"
if [[ -f "$PCS" ]]; then
  emitted="$(grep -o '<!-- cross-review: sha=[^>]*-->' "$PCS" | head -1)"
  assert_contains "post_comment.sh emits a marker" "$emitted" "cross-review: sha="
  # Substitute the shell expansions out and check the literal shape matches.
  rendered="$(printf '%s' "$emitted" | sed -e "s/\${head_sha}/$HEAD40/" -e 's/\${pass}/1/')"
  if [[ "$rendered" =~ $CR_MARKER_RE ]]; then
    ok "and the gate's marker regex matches what it emits"
  else
    bad "the gate's regex does not match the skill's marker: $rendered"
  fi
  # CONTROL: the regex must reject a marker carrying an abbreviated sha, or it
  # is not enforcing the full-width contract the marker exists to provide.
  if [[ "$(marker "${HEAD40:0:9}" 1)" =~ $CR_MARKER_RE ]]; then
    bad "control: the marker regex accepted an abbreviated sha"
  else
    ok "control: the marker regex requires the full 40-char sha"
  fi
else
  echo "  skip post_comment.sh not on this machine"
fi

echo
echo "── the escape hatch ──"
#
# Flipping the default to red blocks ~37 of the 40 open PRs at once. That is
# intended, but it must not be a trap: genuinely trivial PRs (docs-only,
# dependency bumps, rename-only) may skip cross-review under the project's
# standing rule, and they need a way through that is deliberate and auditable
# rather than silent. The hatch is a `cross-review-exempt` label applied by a
# human, plus a justification comment. Both halves are required.

assert_eq "label plus justification lets a trivial PR through" \
  "$(state_of "$(comments "$JUSTIFIED")" "$HEAD40" "$EXEMPT_HUMAN")" "success"
assert_contains "and the status names who granted it" \
  "$(desc_of "$(comments "$JUSTIFIED")" "$HEAD40" "$EXEMPT_HUMAN")" "exempt by @gjalmaraz"
assert_contains "and quotes the justification" \
  "$(desc_of "$(comments "$JUSTIFIED")" "$HEAD40" "$EXEMPT_HUMAN")" "docs-only"

# CONTROL — without this, the three assertions above would also pass on a
# hatch that opens for anyone who merely says the word "exempt".
assert_eq "control: the label alone, unjustified, does NOT open the hatch" \
  "$(state_of "$(comments)" "$HEAD40" "$EXEMPT_HUMAN")" "failure"
assert_contains "control: and it says what is missing" \
  "$(desc_of "$(comments)" "$HEAD40" "$EXEMPT_HUMAN")" "justification"

# CONTROL — the other half. A justification with no label is just a comment.
assert_eq "control: justification alone, unlabelled, does NOT open the hatch" \
  "$(state_of "$(comments "$JUSTIFIED")" "$HEAD40" "$NOT_EXEMPT")" "failure"

# THE HUMAN-IN-THE-LOOP RULE. An agent runs as a bot identity on CI, and a
# hatch a bot can open on its own PR is not a hatch, it is the fail-open we
# just closed with extra steps.
assert_eq "a bot-applied label does NOT open the hatch" \
  "$(state_of "$(comments "$JUSTIFIED")" "$HEAD40" "$EXEMPT_BOT")" "failure"
assert_contains "and says a human must apply it" \
  "$(desc_of "$(comments "$JUSTIFIED")" "$HEAD40" "$EXEMPT_BOT")" "human"

# A one-word "trivial" is not a justification. The reason has to be readable by
# whoever audits the exemption later.
assert_eq "a too-short justification does not count" \
  "$(state_of "$(comments 'Cross-review exemption: trivial')" "$HEAD40" "$EXEMPT_HUMAN")" "failure"

# The hatch overrides a stale stamp too, otherwise it is not an escape hatch —
# but only on the same human-plus-justification terms.
assert_eq "the hatch clears a stale stamp as well" \
  "$(state_of "$(comments "$STAMPED_OLD" "$JUSTIFIED")" "$HEAD40" "$EXEMPT_HUMAN")" "success"

# BASH TRAP GUARD. `[[ false ]]` is TRUE — any non-empty string is truthy — so
# a gate that reads .labeled with [[ "$x" ]] opens for labeled:false. This
# asserts the implementation compares values rather than testing emptiness.
assert_eq "the literal false is not treated as truthy" \
  "$(state_of "$(comments "$JUSTIFIED")" "$HEAD40" "$(exemption false gjalmaraz User)")" "failure"

# Malformed exemption data must not open the hatch. Fail-open on operational
# failure applies to READING the record, never to granting an exemption.
assert_eq "unparseable exemption data does not open the hatch" \
  "$(state_of "$(comments "$JUSTIFIED")" "$HEAD40" "garbage not json")" "failure"

echo
echo "── the commit reference is not a reason ──"
#
# FINDING (codex, P2, cross-review of PR #63). CR_EXEMPT_RE counts every
# character after the marker, and the exemption is separately required to name
# the head commit — so the sha satisfied the 15-character minimum by itself.
# `Cross-review exemption:` plus a bare 40-character sha opened the hatch with
# the reason field empty, which is the exact state the minimum exists to
# refuse. The label says a human waved it through; the comment says nothing
# about why; the audit trail is a commit id that was already in the status.
SHA_ONLY="Cross-review exemption: ${HEAD40}"
# Long enough to clear CR_EXEMPT_RE on raw length, so this case can only be
# refused by the substance check itself.
SHA_ONLY_SHORT="Cross-review exemption: ${HEAD40} ok"

assert_eq "a bare sha is not 15 characters of reason" \
  "$(state_of "$(comments "$SHA_ONLY")" "$HEAD40" "$EXEMPT_HUMAN")" "failure"
assert_contains "and the refusal says a reason is what is missing" \
  "$(desc_of "$(comments "$SHA_ONLY")" "$HEAD40" "$EXEMPT_HUMAN")" "no reason"
assert_eq "nor does a token of prose alongside it" \
  "$(state_of "$(comments "$SHA_ONLY_SHORT")" "$HEAD40" "$EXEMPT_HUMAN")" "failure"

# CONTROL — the two above must not be passing because the SHA stopped binding.
# A real reason plus the same sha still opens the hatch, or the fix has simply
# broken the escape hatch instead of tightening it.
assert_eq "control: a real reason with the same sha still opens the hatch" \
  "$(state_of "$(comments "$JUSTIFIED")" "$HEAD40" "$EXEMPT_HUMAN")" "success"

# CONTROL — the stripping must remove THIS COMMIT'S reference and nothing else.
# The first cut deleted every \b[0-9a-f]{7,40}\b run, which eats ordinary
# English written entirely in hex letters: `defaced`, `effaced` and `acceded`
# are each seven characters of [0-9a-f], and each one vanished. A real
# justification then falls under the minimum and is refused with a message
# about not having given a reason. (gemini-pro, pass 3.)
assert_eq "control: prose that happens to be hex-ish is still a reason" \
  "$(state_of "$(comments "Cross-review exemption: decade-old facade, dead code ${HEAD40:0:9}")" \
      "$HEAD40" "$EXEMPT_HUMAN")" "success"
# Sized so it ONLY passes if `defaced` survives: 17 characters with it, 10
# without, against a minimum of 15.
assert_eq "control: a seven-letter hex word is prose, not a commit reference" \
  "$(state_of "$(comments "Cross-review exemption: the notes defaced ${HEAD40:0:9}")" \
      "$HEAD40" "$EXEMPT_HUMAN")" "success"
# ...and the converse: a hex run that is NOT this commit is left in place, so it
# cannot be used to pad a reason down to nothing either way.
assert_eq "an unrelated hash is not mistaken for this commit's reference" \
  "$(state_of "$(comments "Cross-review exemption: see ${OTHER40:0:12} nothing else ${HEAD40:0:9}")" \
      "$HEAD40" "$EXEMPT_HUMAN")" "success"

# The refusal must not be reachable when nothing was justified at all — that
# path has its own, different remedy ("needs a justification from @x"), and
# collapsing the two would tell a human to lengthen a comment they never wrote.
assert_contains "control: an unjustified PR still gets the unjustified remedy" \
  "$(desc_of "$(comments)" "$HEAD40" "$EXEMPT_HUMAN")" "needs a justification"

echo
echo "── an exemption is bound to the commit it was granted for ──"
#
# FINDING 1 (codex, P1). GitHub preserves BOTH the label and the justification
# comment across a push. So a human exempts a genuinely trivial PR — docs-only,
# a dependency bump — the contributor then pushes executable changes, and the
# `synchronize` run returns success out of the exemption path before head_sha
# is ever consulted. That is the same stale-head bypass this whole gate exists
# to close, re-entered through its own escape hatch: the identical defect class
# that let #3300 merge at a truncated head after a force-push dropped two of
# its cross-review commits.
#
# The binding is the justification naming the commit. It is deliberately the
# cheapest thing a human can re-affirm: the refusal message quotes the current
# short sha, so re-affirming on a new head is a copy-paste of the line the
# status just handed you, not a workflow.

assert_eq "an exemption naming this head opens the hatch" \
  "$(state_of "$(comments "$JUSTIFIED")" "$HEAD40" "$EXEMPT_HUMAN")" "success"

# THE FINDING. Same label, same comment, new commit.
assert_eq "an exemption granted for an older commit does NOT open the hatch" \
  "$(state_of "$(comments "$JUSTIFIED_STALE")" "$HEAD40" "$EXEMPT_HUMAN")" "failure"
assert_contains "and it names the head that needs re-affirming" \
  "$(desc_of "$(comments "$JUSTIFIED_STALE")" "$HEAD40" "$EXEMPT_HUMAN")" "${HEAD40:0:9}"

# A justification that names no commit at all binds nothing, so it cannot
# survive a push either.
assert_eq "an unbound justification does NOT open the hatch" \
  "$(state_of "$(comments "$JUSTIFIED_UNBOUND")" "$HEAD40" "$EXEMPT_HUMAN")" "failure"
assert_contains "and asks for the head commit by name" \
  "$(desc_of "$(comments "$JUSTIFIED_UNBOUND")" "$HEAD40" "$EXEMPT_HUMAN")" "${HEAD40:0:9}"

# RE-AFFIRMATION. The hatch has to stay usable or people stop using it and
# start arguing for the gate's removal instead. Posting one more comment on the
# new head is the whole ceremony; the stale one stays in the timeline as audit.
assert_eq "re-affirming on the new head opens it again" \
  "$(state_of "$(comments "$JUSTIFIED_STALE" "$JUSTIFIED")" "$HEAD40" "$EXEMPT_HUMAN")" "success"
# CONTROL — order must not be what decides it. A stale re-post after a bound
# one does not close a hatch that a bound comment legitimately opened.
assert_eq "control: a later stale re-post does not un-bind an already bound hatch" \
  "$(state_of "$(comments "$JUSTIFIED" "$JUSTIFIED_STALE")" "$HEAD40" "$EXEMPT_HUMAN")" "success"

# CONTROL — binding is an ADDITIONAL requirement, not a replacement. A bound
# justification from a bot is still refused, and a bound justification with no
# label is still not an exemption.
assert_eq "control: a bound justification from a bot is still refused" \
  "$(state_of "$(comments "$JUSTIFIED")" "$HEAD40" "$EXEMPT_BOT")" "failure"
assert_eq "control: a bound justification with no label is still not an exemption" \
  "$(state_of "$(comments "$JUSTIFIED")" "$HEAD40" "$NOT_EXEMPT")" "failure"

# CONTROL — the sha has to be the HEAD's, not just any hex-looking token. A
# reason that happens to contain a hex word must not bind.
assert_eq "control: an unrelated hex word in the reason does not bind" \
  "$(state_of "$(comments 'Cross-review exemption: dependency bump, deadbeef1 lockfile only')" \
     "$HEAD40" "$EXEMPT_HUMAN")" "failure"

echo
echo "── an exemption is bound to the human who granted it ──"
#
# PASS-2 FINDING 1 (codex, P1), and a consequence of the pass-1 fix rather than
# a pre-existing defect. Pass 1 bound the exemption to a COMMIT but not to a
# PERSON. Attribution still came from the `labeled` timeline event, while the
# re-affirmation was any comment body at all: so a human labels an earlier
# head, the PR author (or automation running as the author) pushes new code and
# posts `Cross-review exemption: ... <new sha>`, and the gate reports
# "exempt by @human" for a commit that human never saw. The hatch was
# self-serve — anyone who could comment could re-affirm someone else's
# exemption onto arbitrary new code.
#
# The binding is the comment AUTHOR. Chosen over "re-apply the label per head"
# because the label carries no head and no reason: re-applying is a remove plus
# an add, it records nothing about WHICH commit it now covers, and it would
# have to be pinned to a head by comparing timeline timestamps to push times.
# One comment from the granting human stays the whole ceremony, which is what
# keeps the hatch cheap enough that people use it instead of arguing the gate
# away.

assert_eq "the granting human re-affirming on the new head is valid" \
  "$(state_of "$(comments_by "$GRANTER" "$JUSTIFIED_STALE" "$JUSTIFIED")" "$HEAD40" "$EXEMPT_HUMAN")" \
  "success"

# THE FINDING. Same label, same head-naming comment, different author.
assert_eq "a re-affirmation by someone OTHER than the granting human is refused" \
  "$(state_of "$(comments_by 'drive-by' "$JUSTIFIED")" "$HEAD40" "$EXEMPT_HUMAN")" "failure"
assert_contains "and it names the human who has to re-affirm" \
  "$(desc_of "$(comments_by 'drive-by' "$JUSTIFIED")" "$HEAD40" "$EXEMPT_HUMAN")" "@${GRANTER}"

# The concrete attack: the label is on an older head, the author pushes and
# self-serves the re-affirmation. Refused even though the comment names the
# exact current head and the label was applied by a genuine human.
assert_eq "the PR author cannot self-serve another human's exemption onto new code" \
  "$(state_of "$(comments_by 'pr-author' "$JUSTIFIED_STALE" "$JUSTIFIED")" "$HEAD40" "$EXEMPT_HUMAN")" \
  "failure"

# CONTROL — selection must be "newest by the GRANTER", not "newest overall,
# then check its author". Otherwise a third party posting after the granter
# would knock out a legitimately re-affirmed hatch.
assert_eq "control: a third party's later comment does not mask the granter's own" \
  "$(state_of "$(jq -cn --argjson a "$(comments_by "$GRANTER" "$JUSTIFIED")" \
       --argjson b "$(comments_by 'drive-by' "$JUSTIFIED")" '$a + $b')" \
     "$HEAD40" "$EXEMPT_HUMAN")" "success"

# CONTROL — and the reverse: the granter's own comment must still be the thing
# that opens it, not merely the presence of any bound comment.
assert_eq "control: granter stale plus third-party bound is still refused" \
  "$(state_of "$(jq -cn --argjson a "$(comments_by "$GRANTER" "$JUSTIFIED_STALE")" \
       --argjson b "$(comments_by 'drive-by' "$JUSTIFIED")" '$a + $b')" \
     "$HEAD40" "$EXEMPT_HUMAN")" "failure"

# A comment we could not attribute is not a re-affirmation. Fail-open on
# operational failure applies to READING a record, never to GRANTING one — the
# same rule that keeps an unreadable exemption from opening the hatch.
assert_eq "an unattributed comment does not re-affirm" \
  "$(state_of "$(comments_anon "$JUSTIFIED")" "$HEAD40" "$EXEMPT_HUMAN")" "failure"

# The bot rule survives the author binding: even when the bot both applied the
# label AND posted the bound justification, so author and actor agree, it is
# still refused. Without this, "author must equal actor" could quietly become
# the only test and let an app identity clear its own PR.
assert_eq "a bot that labels AND justifies its own PR is still refused" \
  "$(state_of "$(comments_by 'github-actions[bot]' "$JUSTIFIED")" "$HEAD40" "$EXEMPT_BOT")" "failure"
assert_contains "and still says a human must apply it" \
  "$(desc_of "$(comments_by 'github-actions[bot]' "$JUSTIFIED")" "$HEAD40" "$EXEMPT_BOT")" "human"

# CONTROL — the author binding is ADDITIONAL. The granter posting an unbound or
# a too-short justification is still refused on the pass-1 grounds.
assert_eq "control: the granter's unbound justification is still refused" \
  "$(state_of "$(comments_by "$GRANTER" "$JUSTIFIED_UNBOUND")" "$HEAD40" "$EXEMPT_HUMAN")" "failure"
assert_eq "control: the granter's too-short justification is still refused" \
  "$(state_of "$(comments_by "$GRANTER" 'Cross-review exemption: trivial')" "$HEAD40" "$EXEMPT_HUMAN")" \
  "failure"

# The wrong-author refusal is a commit-status description like any other.
d="$(desc_of "$(comments_by 'drive-by' "$JUSTIFIED")" "$HEAD40" "$EXEMPT_HUMAN")"
if [[ "${#d}" -le 140 ]]; then
  ok "wrong-author description fits the commit-status limit (${#d} chars)"
else
  bad "wrong-author description exceeds 140 chars (${#d})"
fi

echo
echo "── a failed timeline read must not block a reviewed PR ──"
#
# FINDING 3 (codex, P2). When a labeled PR's timeline request is rate-limited,
# the fallback produced an empty event and fetch_exemption still claimed
# labeled:true with an empty actor — so exemption_verdict reported failure
# BEFORE an otherwise-current review was even looked at. A PR carrying a
# perfectly good stamp went red because GitHub hiccupped while reading a label
# it did not need. That contradicts this file's own degradation policy, and it
# is the same conflation fetch_comments avoids by returning `null` rather than
# `[]`: "there is no exemption" and "we could not tell" are different facts.

assert_eq "an unreadable exemption record lets a current stamp through" \
  "$(state_of "$(comments "$MARKER_CURRENT")" "$HEAD40" "$EXEMPT_UNKNOWN")" "success"
assert_eq "and a null exemption record does the same" \
  "$(state_of "$(comments "$MARKER_CURRENT")" "$HEAD40" "null")" "success"

# CONTROL — degrading to "unclaimed" must not degrade to "exempt". An
# unreadable exemption on an UNREVIEWED PR is still red; the currency verdict
# decides, which is the whole point.
assert_eq "control: an unreadable exemption does not clear an unreviewed PR" \
  "$(state_of "$(comments)" "$HEAD40" "$EXEMPT_UNKNOWN")" "failure"
assert_eq "control: nor does it clear a stale stamp" \
  "$(state_of "$(comments "$STAMPED_OLD")" "$HEAD40" "$EXEMPT_UNKNOWN")" "failure"
# CONTROL — a KNOWN bad actor is still a refusal, not a fall-through. Without
# this, "empty actor falls through" would be indistinguishable from "actor
# checks were dropped".
assert_eq "control: a known bot actor still fails rather than falling through" \
  "$(state_of "$(comments "$MARKER_CURRENT")" "$HEAD40" "$EXEMPT_BOT")" "failure"

# The fetch side of the same finding is asserted below, once the `gh` shim
# exists — see "fetching the comments at all".

# Still under the commit-status limit with a long reason spliced in.
LONGJ="Cross-review exemption: $(printf 'x%.0s' {1..300}) ${HEAD40:0:9}"
d="$(desc_of "$(comments "$LONGJ")" "$HEAD40" "$EXEMPT_HUMAN")"
if [[ "${#d}" -le 140 ]]; then
  ok "exempt description fits the commit-status limit (${#d} chars)"
else
  bad "exempt description exceeds 140 chars (${#d})"
fi

echo
echo "── fetching the comments at all ──"
#
# currency_verdict() is fed fixtures, so every test above passes even when the
# FETCH is broken and hands it an empty array — which is exactly what shipped:
# `gh api --paginate --slurp --jq` is rejected by gh ("the `--slurp` option is
# not supported with `--jq` or `--template`"), the error went to /dev/null, and
# the fallback returned []. Result: a permanently green check that had never
# once read a review record. Caught by a live dry-run, not by this suite.
#
# So the shim below reproduces gh's ACTUAL constraint rather than pretending
# every invocation succeeds. A stub that always returns data cannot fail here.
SB="$(mktemp -d)"
trap 'rm -rf "$SB"' EXIT
mkdir -p "$SB/bin"
cat >"$SB/pages.json" <<'JSON'
[[{"body":"## Cross-review — pass 1\n\n_Reviewed `abc123def`._","user":{"login":"gjalmaraz"}},{"body":"unrelated chatter","user":{"login":"drive-by"}}]]
JSON
cat >"$SB/bin/gh" <<SH
#!/bin/sh
slurp=0; usedjq=0
for a in "\$@"; do
  [ "\$a" = "--slurp" ] && slurp=1
  [ "\$a" = "--jq" ] && usedjq=1
done
if [ "\$slurp" = 1 ] && [ "\$usedjq" = 1 ]; then
  echo 'the \`--slurp\` option is not supported with \`--jq\` or \`--template\`' >&2
  exit 1
fi
cat "$SB/pages.json"
SH
chmod +x "$SB/bin/gh"

FETCHED="$(PATH="$SB/bin:$PATH" fetch_comments o/r 1)"
assert_eq "the fetch returns one body per comment" \
  "$(printf '%s' "$FETCHED" | jq 'length' 2>/dev/null)" "2"
assert_contains "and the review record survives the fetch" "$FETCHED" "Reviewed"
# PASS-2 FINDING 1, at the fetch. The author is half the exemption binding, so
# it has to come back from the API shaping — currency_verdict can be fed a
# perfect fixture and still be wired to a fetch that discards the login, which
# is precisely how the `--slurp --jq` bug shipped a permanently green check.
assert_eq "the fetch carries each comment's author" \
  "$(printf '%s' "$FETCHED" | jq -r '.[0].user' 2>/dev/null)" "gjalmaraz"
# CONTROL: not a constant — the second comment has a different author.
assert_eq "control: and it is per-comment, not one value for all of them" \
  "$(printf '%s' "$FETCHED" | jq -r '.[1].user' 2>/dev/null)" "drive-by"

# End-to-end through the real fetch path: a stale record read from `gh` must
# still produce a failure. This is the assertion the shipped bug would fail.
assert_eq "a stale record fetched through gh still fails" \
  "$(state_of "$FETCHED" "$HEAD40")" "failure"

# CONTROL: when gh genuinely cannot answer, the fetch degrades to [] and the
# verdict is green — fail-open, not fail-blind.
cat >"$SB/bin/gh" <<'SH'
#!/bin/sh
echo "API rate limit exceeded" >&2
exit 1
SH
chmod +x "$SB/bin/gh"
assert_eq "control: an unusable gh degrades to green, not red" \
  "$(state_of "$(PATH="$SB/bin:$PATH" fetch_comments o/r 1)" "$HEAD40")" "success"

# FINDING 3, at the fetch. A timeline that cannot be read must yield an
# UNCLAIMED exemption record, not a labeled one with nobody attached — the
# latter is what made exemption_verdict report failure ahead of an otherwise
# current review.
cat >"$SB/bin/gh" <<'SH'
#!/bin/sh
for a in "$@"; do
  case "$a" in *timeline*) echo "API rate limit exceeded" >&2; exit 1 ;; esac
done
echo true
SH
chmod +x "$SB/bin/gh"
assert_eq "a timeline fetch failure yields an unclaimed exemption" \
  "$(PATH="$SB/bin:$PATH" fetch_exemption o/r 1)" "null"

# CONTROL: when the timeline IS readable the actor still comes through, or the
# assertion above is satisfied by a fetch that gave up on exemptions entirely.
cat >"$SB/bin/gh" <<'SH'
#!/bin/sh
for a in "$@"; do
  case "$a" in
    *timeline*)
      echo '[[{"event":"labeled","label":{"name":"cross-review-exempt"},"actor":{"login":"gjalmaraz","type":"User"}}]]'
      exit 0 ;;
  esac
done
echo true
SH
chmod +x "$SB/bin/gh"
FE="$(PATH="$SB/bin:$PATH" fetch_exemption o/r 1)"
assert_contains "control: a readable timeline still names the actor" "$FE" "gjalmaraz"
assert_eq "control: and that actor opens the hatch when justified" \
  "$(state_of "$(comments "$JUSTIFIED")" "$HEAD40" "$FE")" "success"

echo
echo "── workflow: a comment must not cancel a push's run ──"
# Both triggers shared one concurrency group with cancel-in-progress, and a
# re-review comment lands seconds after the push it reports on — so the
# `synchronize` run was routinely cancelled by the `issue_comment` run
# chasing it. The status stayed correct, so nothing looked broken; what was
# left behind was a cancelled CHECK RUN, which `gh pr checks` renders as
# **fail**. A PR with every required status green read as failing, on #3290,
# #3291 and #3292 in one session. Anything reading `gh pr checks` rather
# than the commit status then refuses to merge a green PR.
CWF="$CR_WF_PATH"
group="$(awk '/^concurrency:/{c=1} c && /^  group:/{sub(/^  group: /,""); print; exit}' "$CWF")"
assert_contains "the group is keyed on the PR"    "$group" "pull_request.number"
assert_contains "and on the event name"           "$group" "github.event_name"
# Both triggers must still exist, or this key is keeping nothing apart.
assert_contains "pull_request is still a trigger" "$(cat "$CWF")" "pull_request:"
assert_contains "issue_comment is still a trigger" "$(cat "$CWF")" "issue_comment:"
# Collapsing a burst of comments is the behaviour the group exists for.
cancel="$(awk '/^concurrency:/{c=1} c && /cancel-in-progress:/{print $2; exit}' "$CWF")"
assert_eq "bursts still collapse" "$cancel" "true"

echo
echo "── workflow: an IGNORED deletion must not cancel a real recomputation ──"
#
# PASS-2 FINDING 2 (codex, P1), and, like finding 1, a consequence of the
# pass-1 fix rather than a pre-existing defect. Pass 1 added `deleted` to
# issue_comment and, for cost, filtered the deleted path in the JOB-level `if`
# on the comment body. But cancel-in-progress is resolved at the WORKFLOW
# level, before any job `if` is evaluated. So:
#
#   1. someone deletes a cross-review record → a run starts that will
#      correctly re-red the PR,
#   2. someone deletes an ordinary "lgtm" seconds later → same
#      `cr-currency-<n>-issue_comment` group → it CANCELS run 1,
#   3. run 2's job `if` skips it, so it posts no status at all.
#
# Net effect: the qualifying comment is gone and the previous success survives
# on the head. The filter that was supposed to save money silently disarmed the
# trigger it was filtering.
#
# The fix narrows the concurrency group rather than making every deletion
# recompute, because recomputing would add a billable minute to every chatter
# deletion on a top-three workflow in a repo already over its Actions
# allowance. Ignored deletions now get their own group, so they cancel each
# other (harmless — every one of them skips) and never a live run.
#
# This is a property of the YAML, not of a shell path, so it is asserted by
# evaluating the ACTUAL group expression read out of the workflow under real
# event payloads. A substring check would pass on an expression that mentions
# the right words and computes the wrong group.

if ! command -v python3 >/dev/null 2>&1; then
  bad "python3 is required to evaluate the concurrency expression"
else
cat >"$SB/ghaexpr.py" <<'PY'
# A small evaluator for the GitHub Actions expression subset used by
# concurrency.group: ${{ }} interpolation, || && ! == !=, parentheses, string
# literals, contains(), and dotted context lookups. Deliberately NOT a
# re-statement of the workflow's logic — it reads the workflow's own text.
import json, re, sys

TOK = re.compile(r"\s*(\(|\)|,|\|\||&&|==|!=|!|'(?:[^']|'')*'|[A-Za-z_][A-Za-z0-9_.\-]*|[0-9]+)")

def lex(s):
    out, i = [], 0
    while i < len(s):
        m = TOK.match(s, i)
        if not m:
            if s[i].isspace():
                i += 1; continue
            raise SyntaxError("bad token at %r" % s[i:i+20])
        out.append(m.group(1)); i = m.end()
    return out

def falsy(v):
    return v is None or v is False or v == '' or v == 0

class P:
    def __init__(self, toks, ctx): self.t, self.i, self.ctx = toks, 0, ctx
    def peek(self): return self.t[self.i] if self.i < len(self.t) else None
    def take(self): v = self.peek(); self.i += 1; return v
    def expect(self, x):
        if self.take() != x: raise SyntaxError("expected " + x)

    def expr(self):  # ||  — returns the left operand if truthy, else the right
        v = self.and_()
        while self.peek() == '||':
            self.take(); r = self.and_()
            v = v if not falsy(v) else r
        return v

    def and_(self):  # &&  — returns the right operand if left is truthy
        v = self.eq()
        while self.peek() == '&&':
            self.take(); r = self.eq()
            v = r if not falsy(v) else v
        return v

    def eq(self):
        v = self.unary()
        while self.peek() in ('==', '!='):
            op = self.take(); r = self.unary()
            v = (v == r) if op == '==' else (v != r)
        return v

    def unary(self):
        if self.peek() == '!':
            self.take(); return falsy(self.unary())
        return self.primary()

    def primary(self):
        t = self.take()
        if t == '(':
            v = self.expr(); self.expect(')'); return v
        if t.startswith("'"):
            return t[1:-1].replace("''", "'")
        if t == 'true':  return True
        if t == 'false': return False
        if t.isdigit():  return int(t)
        if t == 'contains':
            self.expect('('); a = self.expr(); self.expect(','); b = self.expr(); self.expect(')')
            if a is None: return False
            if isinstance(a, list): return b in a
            return str(b) in str(a)
        cur = self.ctx
        for part in t.split('.'):
            if isinstance(cur, dict): cur = cur.get(part)
            else: return None
        return cur

def render(tmpl, ctx):
    def sub(m):
        v = P(lex(m.group(1)), ctx).expr()
        if v is True: return 'true'
        if v is False: return 'false'
        if v is None: return ''
        return str(v)
    return re.sub(r'\$\{\{(.*?)\}\}', sub, tmpl, flags=re.S)

if __name__ == '__main__':
    print(render(sys.argv[1], json.loads(sys.argv[2])))
PY

# ev <group-expression> <event-json> → the concurrency group it resolves to
ev() { python3 "$SB/ghaexpr.py" "$1" "$2"; }

# Real payload shapes. `github.event.action` is the comment action on
# issue_comment; `github.event.comment.body` is what the job `if` filters on.
ic_del() {
  jq -nc --arg b "$1" \
    '{github:{event_name:"issue_comment", event:{action:"deleted", issue:{number:3406, pull_request:{}}, comment:{body:$b}}}}'
}
ic_new() {
  jq -nc --arg b "$1" \
    '{github:{event_name:"issue_comment", event:{action:"created", issue:{number:3406, pull_request:{}}, comment:{body:$b}}}}'
}
# A push run is a pull_request_target run now — the privileged job moved there,
# and the property this section pins (a comment run never cancels a push run)
# is only worth anything for the job that writes the status.
PR_SYNC='{"github":{"event_name":"pull_request_target","event":{"action":"synchronize","pull_request":{"number":3406}}}}'

DEL_RECORD="$(ev "$group" "$(ic_del "## Cross-review — pass 1

_Reviewed \`${HEAD40:0:9}\`._")")"
DEL_EXEMPT="$(ev "$group" "$(ic_del "Cross-review exemption: docs-only, ${HEAD40:0:9}")")"
DEL_CHATTER="$(ev "$group" "$(ic_del 'lgtm, shipping this')")"
DEL_CHATTER2="$(ev "$group" "$(ic_del 'nice catch, thanks')")"
NEW_CHATTER="$(ev "$group" "$(ic_new 'lgtm, shipping this')")"
SYNC="$(ev "$group" "$PR_SYNC")"

# Sanity: the evaluator produced a group at all, so the assertions below are
# comparing real strings rather than two empty ones.
if [[ -n "$DEL_RECORD" && "$DEL_RECORD" == *3406* ]]; then
  ok "the group expression evaluates (${DEL_RECORD})"
else
  bad "the group expression did not evaluate to a usable group: '$DEL_RECORD'"
fi

# THE FINDING. A chatter deletion must not share a cancelling group with the
# deletion of a record or of an exemption justification.
if [[ "$DEL_RECORD" != "$DEL_CHATTER" ]]; then
  ok "deleting a cross-review record does not share a group with chatter deletion"
else
  bad "an ignored deletion cancels a record deletion (both '$DEL_RECORD')"
fi
if [[ "$DEL_EXEMPT" != "$DEL_CHATTER" ]]; then
  ok "deleting an exemption justification does not share a group with chatter deletion"
else
  bad "an ignored deletion cancels an exemption deletion (both '$DEL_EXEMPT')"
fi

# The two RELEVANT deletions still collapse together — narrowing the group must
# not become "one group per comment", which would defeat cancel-in-progress.
assert_eq "relevant deletions still collapse into one group" "$DEL_RECORD" "$DEL_EXEMPT"
# And the ignored ones still collapse with each other, so the skip-only runs
# keep costing nothing rather than piling up.
assert_eq "ignored deletions still collapse with each other" "$DEL_CHATTER" "$DEL_CHATTER2"

# CONTROL — the pass-1 grouping, evaluated by the same evaluator. If this does
# NOT show the collision, the evaluator is not discriminating and the three
# assertions above prove nothing.
OLD_GROUP='cr-currency-${{ github.event.pull_request.number || github.event.issue.number }}-${{ github.event_name }}'
OLD_RECORD="$(ev "$OLD_GROUP" "$(ic_del '## Cross-review — pass 1')")"
OLD_CHATTER="$(ev "$OLD_GROUP" "$(ic_del 'lgtm')")"
if [[ "$OLD_RECORD" == "$OLD_CHATTER" ]]; then
  ok "control: the pass-1 group DOES collide, so the evaluator discriminates"
else
  bad "control: the evaluator failed to reproduce the pass-1 collision"
fi

# CONTROL — the pass-1 property this must not regress: a comment run and a push
# run still land in different groups, so a re-review comment cannot cancel the
# synchronize run it is chasing (#3290, #3291, #3292).
if [[ "$SYNC" != "$NEW_CHATTER" && "$SYNC" != "$DEL_RECORD" ]]; then
  ok "control: pull_request_target and issue_comment still occupy separate groups"
else
  bad "control: a comment run shares a group with a push run ('$SYNC')"
fi

# CONTROL — created/edited are not filtered by the job `if`, so every one of
# them recomputes; they must stay in the live group rather than being sorted
# into the ignored one by their body.
assert_eq "an ordinary CREATED comment is still a live run, not an ignored one" \
  "$NEW_CHATTER" "$(ev "$group" "$(ic_new "## Cross-review — pass 1")")"
if [[ "$NEW_CHATTER" != "$DEL_CHATTER" ]]; then
  ok "control: and it is not lumped in with the ignored deletions"
else
  bad "control: a created comment shares the ignored-deletion group"
fi
fi

# The hatch is worthless if applying the label never recomputes the status.
# The workflow only fired on opened/synchronize/reopened, so a human could
# label a PR and watch the check stay red forever, with the only way out being
# an empty commit. Flagged in docs/investigation-pipeline-throughput-levers.
prtypes="$(awk '/^  pull_request_target:/{p=1; next} p && /types:/{print; exit}' "$CWF")"
assert_contains "labeling a PR re-runs the check"   "$prtypes" "labeled"
assert_contains "unlabeling a PR re-runs it too"    "$prtypes" "unlabeled"
# CONTROL: the pre-existing triggers must survive, or this assertion is
# satisfied by a workflow that no longer runs on pushes at all.
assert_contains "control: synchronize is still a trigger" "$prtypes" "synchronize"
# FINDING 2 (codex + deepseek, P2). issue_comment fired on [created, edited]
# but not [deleted], so: a PR goes green because a cross-review record exists
# or because an exemption justification exists, someone deletes that comment,
# no run fires, and the previously posted success status stays on the head. The
# PR merges with neither a review nor a valid exemption.
#
# This assertion USED to read `types: [created, edited]` and existed precisely
# so the list could not widen by accident. Widening it is the fix, so the
# assertion moves with it — deliberately, and with the cost bounded below.
ictypes="$(awk '/^  issue_comment:/{p=1; next} p && /types:/{print; exit}' "$CWF")"
assert_eq "deleting a comment re-runs the check" \
  "$ictypes" "    types: [created, edited, deleted]"

# THE COST BOUND, which is the reason that assertion was there. This repo is
# over its Actions allowance and Cross-Review Currency is a top-three workflow
# by run count (214 runs in a fortnight) on ubuntu-latest, which bills a
# one-minute minimum per JOB on jobs that take seconds. A skipped job bills
# nothing, so the deleted path is filtered by comment body in the job `if`:
# deleting ordinary chatter starts a run whose only job is skipped, and just
# the deletions that can actually change the verdict cost a minute.
jobif="$(cat "$CWF")"
assert_contains "deletions are filtered rather than run unconditionally" \
  "$jobif" "github.event.action != 'deleted'"
assert_contains "and the filter recognises a cross-review record" \
  "$jobif" "contains(github.event.comment.body, '## Cross-review')"
assert_contains "and an exemption justification" \
  "$jobif" "contains(github.event.comment.body, 'Cross-review exemption:')"
# CONTROL: created/edited must NOT be filtered by that body check, or a comment
# edited INTO a review record would never turn the check green.
assert_contains "control: created and edited still run unconditionally" \
  "$jobif" "github.event.action != 'deleted' ||"


# ── Unverifiable must not read as verified ──────────────────────────────────
# The regression this pins: the tool guard used to `exit 0`, so a runner
# without gh/jq produced a green job, posted no status, and left any stale red
# status standing. #3406 made the gate fail closed; #3407 routed the job to the
# `smalljobs` lane, whose containers have neither tool, silently undoing it.
# A gate that cannot evaluate must fail, not pass.
# An empty PATH would hide `bash` itself, not just gh/jq, and the probe would
# "pass" on a shell-not-found error instead of the guard. Point PATH at a dir
# holding everything the script needs BUT those two tools.
guard_bin="$(mktemp -d)"
for t in env cat sed awk grep printf; do
  src="$(command -v "$t" 2>/dev/null)" && ln -sf "$src" "$guard_bin/$t"
done
guard_out="$(PATH="$guard_bin" "$(command -v bash)" "$HERE/cross-review-currency.sh" \
  --pr 1 --repo o/r 2>&1)"; guard_rc=$?
rm -rf "$guard_bin"
assert_eq "missing gh/jq exits 2 (could-not-run, fail closed)" "$guard_rc" "2"
assert_contains "and says it could not verify, not that it succeeded" \
  "$guard_out" "cannot verify"
[[ "$guard_out" != *"reporting success"* ]] \
  && ok "and never claims success without a verdict" \
  || bad "and never claims success without a verdict (got '$guard_out')"

# CONTROL: the workflow must keep this job on a runner that HAS both tools, or
# the guard above turns every run red instead of every run green.
wf="$(cat "$CR_WF_PATH")"
currency_runson="$(printf '%s' "$wf" | awk '/^  currency:/{f=1} f&&/^    runs-on:/{print;exit}')"
assert_contains "control: currency job runs on a runner with gh+jq" \
  "$currency_runson" "ubuntu-latest"

# The guard above is only worth having if the workflow lets its exit code out.
# A bare `|| true` on the invocation swallows exit 2 and restores the silent
# green this whole PR exists to remove, so assert the discriminating wrapper is
# present and the bare form is gone.
assert_contains "workflow re-raises a could-not-run exit instead of swallowing it" \
  "$wf" '[[ $rc -eq 1 ]] || exit "$rc"'
[[ "$wf" != *'cross-review-currency.sh "${args[@]}" || true'* ]] \
  && ok "and does not swallow every exit code with a bare || true" \
  || bad "and does not swallow every exit code with a bare || true"


# ── The gate must not be graded by the code it is grading ───────────────────
# FINDING (codex, P0, cross-review of PR #63). The currency job held
# `statuses: write` and ran scripts/cross-review-currency.sh out of a bare
# `actions/checkout@v4` — which, with no `ref:`, is the PR's merge commit. The
# PR under review therefore supplied the program deciding whether the PR was
# reviewed: edit one line to print `success` and the required check goes green.
# That is the agent case, not a hypothetical attacker — an agent with push
# access told to get CI green edits the file in front of it.
currency_job="$(printf '%s' "$wf" | awk '/^  currency:/{f=1} f{print} f&&/^  [a-z]/&&!/^  currency:/{exit}')"
assert_contains "the privileged job checks out the base, not the PR" \
  "$currency_job" "ref: \${{ steps.base.outputs.sha }}"
# The base is RESOLVED, never guessed. An earlier cut fell back to the
# repository default branch on issue_comment, which is the wrong branch for any
# PR targeting a release line — and fatal if the gate is installed there and not
# on the default. (gemini-pro, PR #63.)
assert_contains "and resolves the base commit rather than guessing a branch" \
  "$currency_job" "gh api \"repos/\$GITHUB_REPOSITORY/pulls/\$PR\" --jq .base.sha"
[[ "$currency_job" != *"github.event.repository.default_branch"* ]] \
  && ok "and no longer falls back to the default branch" \
  || bad "the default-branch guess is still there"
assert_contains "and fails closed when the base does not resolve to a commit" \
  "$currency_job" 'if [[ ! "$sha" =~ ^[0-9a-f]{40}$ ]]; then'
assert_contains "and refuses to run when the gate is absent from the base" \
  "$currency_job" "scripts/cross-review-currency.sh is not on the base branch"
# CONTROL — the sibling self-test job must KEEP checking out the PR: its whole
# job is to run the PR's tests. Pinning it to the base would make it assert
# that the base still passes its own suite, which is not a check on anything.
# It is safe there precisely because it carries `permissions: contents: read`.
selftest_job="$(printf '%s' "$wf" | awk '/^  self-test:/{f=1} f{print} f&&/^  currency:/{exit}')"
[[ "$selftest_job" != *"ref:"* ]] \
  && ok "control: the unprivileged self-test still runs the PR's own code" \
  || bad "control: self-test was pinned to the base, so it tests nothing"

# ── The privileged/unprivileged split must not silently invert ─────────────
# FINDING (codex, P1, cross-review of PR #63 pass 2). Pinning `checkout` to the
# base was not enough: on `pull_request`, GitHub runs THE PR'S VERSION OF THE
# WORKFLOW FILE, so the same PR could delete the pin, or skip the script and
# POST `cross-review/current=success` directly with the `statuses: write` token.
# `pull_request_target` is the only PR trigger whose definition is resolved from
# the base branch. It is also what gives fork PRs a token that can write a
# status at all — `pull_request` downgrades theirs to read-only regardless of
# the `permissions:` block, so with a failed POST now exiting 2, forks went red
# on every push (codex and gemini-pro, convergently).
#
# pull_request_target is safe here for one narrow reason: THIS WORKFLOW NEVER
# CHECKS OUT OR EXECUTES PR CODE. These assertions are that reason, written
# down where CI enforces it — the split is worth nothing if a later edit can
# quietly put PR code inside the privileged job.
assert_contains "the privileged job runs from base-branch workflow code" \
  "$currency_job" "github.event_name == 'pull_request_target'"
[[ "$currency_job" != *"github.event_name == 'pull_request'"* ]] \
  && ok "and never under plain pull_request, where the PR supplies the YAML" \
  || bad "the privileged job still runs under pull_request"
assert_contains "control: the unprivileged self-test DOES run the PR's code" \
  "$selftest_job" "github.event_name == 'pull_request'"
[[ "$selftest_job" != *"pull_request_target"* ]] \
  && ok "and must never be reached under pull_request_target" \
  || bad "self-test can run under pull_request_target — PR code with a base-context token"
# These two look at DIRECTIVES, not prose. Both jobs argue about `statuses` and
# about PR code in their comments — a substring test over the raw YAML matches
# the argument rather than the configuration.
selftest_code="$(printf '%s' "$selftest_job" | sed 's/[[:space:]]*#.*$//')"
currency_code="$(printf '%s' "$currency_job" | sed 's/[[:space:]]*#.*$//')"

assert_contains "control: and it narrows its own permissions" \
  "$selftest_code" "permissions:"
[[ "$selftest_code" != *"statuses:"* ]] \
  && ok "control: self-test cannot write statuses" \
  || bad "self-test was granted statuses — it runs PR code"

# THE LOAD-BEARING ONE. Every way PR code could enter the privileged job. Note
# what is NOT forbidden: `HEAD_SHA: ${{ github.event.pull_request.head.sha }}`
# is the commit the status is BOUND to, passed as data to a script that only
# ever compares it. Checking that same sha OUT is the thing that would execute
# the PR.
for forbidden in "ref: \${{ github.event.pull_request.head" "head.ref" "npm " "yarn " "pip install" "make -" "docker "; do
  case "$currency_code" in
    *"$forbidden"*) bad "the privileged job references '$forbidden' — that is PR code in a base-context job" ;;
    *)              ok  "the privileged job does not reach for '$forbidden'" ;;
  esac
done
# ...and exactly one checkout, so a second unpinned one cannot slip in beside
# the pinned one.
assert_eq "the privileged job checks out exactly once" \
  "$(printf '%s' "$currency_code" | grep -c 'uses: actions/checkout')" "1"

# ── A status that was never published is not a verdict ──────────────────────
# FINDING (codex, P1, cross-review of PR #63). A failed POST only warned, then
# fell through to `[[ "$state" == "success" ]]`. So a run that computed
# `failure` and could not publish it exited 0: green job, and whatever an
# earlier run left on the commit stays authoritative at the merge button. On a
# re-review that turned red, the obsolete `success` survives and nothing
# anywhere is red. Exit 2 ("could not run, posted nothing"), not 1 ("ran, and
# the answer is no") — the workflow swallows 1 and re-raises 2.
post_bin="$(mktemp -d)"
for t in env cat sed awk grep printf jq; do
  src="$(command -v "$t" 2>/dev/null)" && ln -sf "$src" "$post_bin/$t"
done
# `gh` that reads fine and cannot write. The read failing is harmless here: an
# unreadable comment list is the documented fail-OPEN case, so the verdict is
# `success` and the POST is still attempted — which is what this exercises.
printf '#!/bin/sh\nexit 1\n' > "$post_bin/gh"; chmod +x "$post_bin/gh"
post_out="$(PATH="$post_bin" "$(command -v bash)" "$HERE/cross-review-currency.sh" \
  --pr 1 --repo o/r --sha "$HEAD40" --post 2>&1)"; post_rc=$?
assert_eq "a failed status POST exits 2, not 0" "$post_rc" "2"
assert_contains "and says the verdict was never published" \
  "$post_out" "NOT published"

# CONTROL — the same invocation with a `gh` that CAN write must exit 0, or the
# assertion above is satisfied by a script that fails on every run.
printf '#!/bin/sh\nexit 0\n' > "$post_bin/gh"
PATH="$post_bin" "$(command -v bash)" "$HERE/cross-review-currency.sh" \
  --pr 1 --repo o/r --sha "$HEAD40" --post >/dev/null 2>&1
assert_eq "control: a successful POST still exits 0" "$?" "0"
rm -rf "$post_bin"

echo
echo "── an unverified standing is ANNOTATED under Actions, not only logged ──"
#
# The stderr warning and the status suffix both shipped in #63 and both went
# unread: a green job's log is never opened. Under GITHUB_ACTIONS the degraded
# check must surface as a workflow ::warning (run summary + Checks tab) and a
# step-summary paragraph. Outside Actions, nothing — the terminal already has
# stderr. Issue #65.
ann_summary="$(mktemp)"
ANN_OUT="$(GITHUB_ACTIONS=true GITHUB_STEP_SUMMARY="$ann_summary" \
  annotate_unverified success "current for ${HEAD40:0:9} (standing unverified)")"
assert_contains "under Actions, an unverified grant emits a ::warning annotation" \
  "$ANN_OUT" "::warning title=cross-review currency"
assert_contains "the annotation names the cause (the stock token cannot read permissions)" \
  "$ANN_OUT" "GITHUB_TOKEN"
assert_contains "and the fix" "$ANN_OUT" "CR_PERMISSION_UNREADABLE=refuse"
assert_contains "the step summary gets a paragraph too" \
  "$(cat "$ann_summary")" "standing unverified"
# Workflow-command properties: ':' and ',' must be %-encoded or the parser
# may mis-split the title. The raw title contains neither; the message part
# may contain ':' freely (only % CR LF are encoded there).
ANN_TITLE="${ANN_OUT#::warning title=}"; ANN_TITLE="${ANN_TITLE%%::*}"
[[ "$ANN_TITLE" != *:* && "$ANN_TITLE" != *,* ]] \
  && ok "the annotation title carries no raw ':' or ',' (kimi, PR #73)" \
  || bad "annotation title has an unencoded ':' or ',': '$ANN_TITLE'"
# The "granted" wording lived in the STEP SUMMARY, so that is what must be
# checked — asserting on the ::warning line passed vacuously (kimi, PR #73
# pass 2), and assert_not_contains was not even defined in this harness, so
# the line was skipped uncounted (antigravity, PR #73 pass 2).
ann_fail_summary="$(mktemp)"
ANN_FAIL="$(GITHUB_ACTIONS=true GITHUB_STEP_SUMMARY="$ann_fail_summary" \
  annotate_unverified failure "stale for ${OTHER40:0:9} (standing unverified)")"
assert_contains "a failure verdict from an unverified author is annotated too" "$ANN_FAIL" "::warning"
assert_not_contains "…and neither the warning nor the summary claims anything was granted" \
  "$ANN_FAIL$(cat "$ann_fail_summary")" "granted"
assert_contains "…the summary uses the state-neutral wording" \
  "$(cat "$ann_fail_summary")" "computed from a record whose author was trusted"
rm -f "$ann_fail_summary"
# CONTROL: the helper really fails when the needle IS present.
_nc_before=$FAIL; assert_not_contains "control-probe" "haystack" "hay" >/dev/null; \
  [[ $FAIL -eq $((_nc_before + 1)) ]] && { FAIL=$_nc_before; ok "control: assert_not_contains can fail"; } \
  || bad "assert_not_contains never fails"
rm -f "$ann_summary"
ANN_OFF="$(GITHUB_ACTIONS= annotate_unverified success "current for ${HEAD40:0:9} (standing unverified)")"
assert_eq "outside Actions it prints nothing (stderr already covers a terminal)" "$ANN_OFF" ""
ANN_VERIFIED="$(GITHUB_ACTIONS=true annotate_unverified success "current for ${HEAD40:0:9}")"
assert_eq "control: a VERIFIED standing is not annotated — or the warning is noise on every run" "$ANN_VERIFIED" ""
# END TO END: main() must actually call it. Same gh shim as the --post cases —
# the comment is from a MEMBER with no readable permission.
ann_bin="$(mktemp -d)"
# --paginate --slurp yields an ARRAY OF PAGES; fetch_comments reads .[][].
jq -nc --arg b "$MARKER_CURRENT" \
  '[[{body: $b, user: {login: "someone"}, author_association: "MEMBER"}]]' >"$ann_bin/comments.json"
cat >"$ann_bin/gh" <<GH
#!/bin/sh
case "\$*" in
  *"/comments"*) cat "$ann_bin/comments.json" ;;
  *"/timeline"*) printf '[]' ;;
  *"/issues/"*) printf '{"labels": []}' ;;
  *) exit 1 ;;   # the permission lookup 403s, as the stock token's does
esac
GH
chmod +x "$ann_bin/gh"
E2E="$(GITHUB_ACTIONS=true PATH="$ann_bin:$PATH" "$(command -v bash)" "$HERE/cross-review-currency.sh" \
  --pr 1 --repo o/r --sha "$HEAD40" 2>/dev/null)"
assert_contains "main() annotates when the run degrades" "$E2E" "::warning title=cross-review currency"
assert_contains "control: the verdict line is still printed first" "$E2E" "standing unverified"
rm -rf "$ann_bin"

echo
echo "══ $PASS passed, $FAIL failed ══"
[[ "$FAIL" -eq 0 ]]
