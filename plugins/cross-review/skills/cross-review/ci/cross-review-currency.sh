#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# cross-review-currency.sh — is this PR's newest cross-review record bound to
# the commit that is about to be merged?
#
# WHY THIS EXISTS
#
# The /cross-review skill stamps every review comment with the SHA it actually
# reviewed. For a while nothing read that stamp, which made it a sensor with
# nothing wired to it: on #3207 the head moved four times during a review, one
# push reverted a P1 that two independent providers had confirmed, and the PR
# was merged 19 minutes before its own review finished. The posted record still
# read as definitive. See #3243.
#
# A PreToolUse hook in the cross-review skill now reads the stamp before
# `gh pr merge`, but a hook only binds the agent that runs it. It cannot see a
# merge inside a shell script, a GraphQL mergePullRequest mutation, the web UI,
# or automerge. This check covers all four, because it is computed from PR
# state rather than from a command line.
#
# IT IS NOW A MANDATE, NOT ONLY A CURRENCY CHECK
#
# This file used to say: "It does not require that a PR be cross-reviewed. A PR
# with no record is GREEN." That held while the status was advisory. It stopped
# holding the day `cross-review/current` became one of four REQUIRED contexts on
# `develop`, because a required check that says success when nothing ran does
# not report "unknown" — it reports "fine". Audited across all 40 open PRs:
#
#   30 success — "no cross-review record on this PR"
#    7 success — "record carries no SHA stamp — cannot verify currency"
#    2 success — "reviewed at <sha>"   (genuinely reviewed and current)
#    1 failure — stale stamp           (the check working as designed)
#
# So 37 of 40 rendered at the merge button exactly like the 2 that had really
# been reviewed. Six PRs merged in one night carrying "no cross-review record";
# #3388 shipped a user-trapping dead end in mobile signup through that gap. On
# #3300 a force-push truncated the branch from 5 commits to 2 and dropped two
# cross-review feedback commits — CI re-ran green on the truncated head because
# CI grades what is present, not what used to be there. The SHA stamp was the
# only thing that noticed, and the PR was merged past it anyway.
#
# Both fail-open states are therefore FAILURES now. What that costs is real:
# ~37 open PRs go from mergeable to blocked at once. The escape hatch below is
# what keeps that a policy change rather than a trap.
#
# THE ESCAPE HATCH
#
# A PR is exempt when ALL FOUR hold:
#
#   1. it carries the `cross-review-exempt` label, applied by a human account
#      (the `labeled` timeline event's actor must not be a bot or an app),
#   2. a justification comment beginning `Cross-review exemption:` followed by
#      at least 15 characters of actual reason,
#   3. that justification NAMES THE HEAD COMMIT it is exempting, and
#   4. it was WRITTEN BY THAT SAME HUMAN — the account the label came from.
#
# (3) stops the hatch re-opening the hole across a push. GitHub keeps both the
# label and the comment, so without it a human exempts a docs-only PR, the
# contributor pushes executable code, and the `synchronize` run returns success
# out of the exemption path before the head is looked at.
#
# (4) stops it being self-serve. With (3) alone the exemption was bound to a
# COMMIT but not to a PERSON: attribution came from the `labeled` event while
# the re-affirmation was any comment body at all, so the PR author — or
# automation running as the author — could push new code, post the new sha, and
# have this report "exempt by @human" for a commit that human never saw.
#
# Re-affirming is still one comment on the new head, posted by the person who
# granted it, and the refusal message quotes both the sha to paste and the
# account that has to paste it.
#
# Intended users are the PRs the project's standing rule already lets skip
# cross-review: docs-only, dependency bumps, rename-only. All three parts are
# required precisely so an agent cannot clear its own PR: a bot-applied label
# is refused outright, and the granting actor plus the reason are written into
# the status description, so every exemption is attributable in the timeline.
#
# WHAT IT STILL DOES NOT DO
#
#   - It does not block merge by itself. It reports a commit status; whether
#     that status is required is a branch-protection setting.
#   - It still never guesses about OPERATIONAL failure. "We read the comments
#     and there were none" is red. "We could not read the comments" is green.
#     Those are different facts and conflating them would let one GitHub
#     hiccup red-flag every open PR, which is how a gate gets switched off.
#     fetch_comments signals the second case with a non-array, and
#     fetch_exemption signals it with `null` — an exemption record it could not
#     read is UNCLAIMED, so the ordinary currency verdict decides rather than
#     the label read failing the PR out from under a valid review.
#
# The decision logic lives in currency_verdict() so the harness can call it
# with fixtures and assert on BEHAVIOUR. agent-plan-gate.yml kept its logic in
# a workflow `run:` block, so its harness could only assert that certain lines
# appeared in the YAML — and it missed two real bypasses as a result.
#
# Usage:
#   cross-review-currency.sh --pr <n> [--repo owner/name] [--post] [--sha <sha>]
#
# Exit: 0 current (or nothing to contradict it), 1 stale. Never exits non-zero
# for an operational failure — those are green with an explanatory description.
# ---------------------------------------------------------------------------

set -uo pipefail

STATUS_CONTEXT="${CR_CURRENCY_CONTEXT:-cross-review/current}"

# A record must start with the skill's own header AND carry a stamp. Matching
# only the header let an UNSTAMPED comment — which post_comment.sh still emits
# when --head-sha is omitted — outrank a stale stamped one sitting behind it,
# reporting "cannot verify" and switching the gate off. A comment with no SHA
# carries no information about coverage and must not outvote one that does.
CR_HEADER='## Cross-review'

# TWO STAMP FORMS, AND WHY THE MACHINE-WRITTEN ONE IS PREFERRED.
#
# The stamp began as prose, and prose drifts. Census of the 10 most recent
# cross-review comments on open PRs, 2026-08-14:
#
#   3376 3374 3371 3362  "Reviewed at `<sha>`"  matched the head — REJECTED
#   3369 3367 3363 3073  no SHA anywhere
#   3407 3298            "Reviewed `<sha>`"     genuinely stale
#
# Four PRs were correctly and currently reviewed and read as unreviewed here,
# purely because a model composing the comment by hand wrote "Reviewed at"
# where post_comment.sh writes "Reviewed". One English word turned a working
# gate into a wrong answer on 40% of the sample.
#
# The fix is not a bigger regex, it is a stamp no one writes by hand.
# post_comment.sh now emits CR_MARKER_RE unconditionally whenever it knows a
# head sha, and refuses to post at all when it does not. The marker carries the
# FULL 40 characters, so it is also free of the abbreviation ambiguity the
# prose forms have.
#
# The prose forms remain accepted as a fallback, and both variants are. Every
# comment already on GitHub is prose-only, and those PRs' review records are
# not re-postable — dropping the fallback would red-flag genuinely reviewed
# work. Prose is what people read; the marker is what this gate reads.
CR_MARKER_RE='<!-- cross-review: sha=[0-9a-f]{40} '
CR_STAMP_RE='Reviewed (at )?`[0-9a-f]{7,40}`'

# The escape hatch. The label is only half of it; the justification comment
# must start with this marker and carry >= 15 further characters of reason, so
# that "exempt" alone does not clear a PR and the audit trail says why.
CR_EXEMPT_LABEL="${CR_EXEMPT_LABEL:-cross-review-exempt}"
CR_EXEMPT_RE='^Cross-review exemption:[[:space:]]*[^[:space:]].{14,}'

# exemption_verdict <exemption-json> <comments-json-array> <head-sha>
# Prints "<state>\t<description>" when the hatch applies or is being claimed
# and refused, and prints NOTHING when no exemption is in play. Callers must
# distinguish empty output from a verdict.
#
# BASH TRAP: `[[ false ]]` is TRUE — any non-empty string is truthy. Every test
# below compares a value to an expected string; none of them test emptiness.
#
# AN EXEMPTION IS BOUND TO ONE COMMIT.
#
# GitHub preserves both the label and the justification comment across a push.
# So a human exempts a genuinely trivial PR, the contributor then pushes
# executable changes, and the `synchronize` run returned success out of this
# path before head_sha was ever consulted — re-entering, through the gate's own
# escape hatch, the exact stale-head bypass the gate exists to close. Same
# defect class as #3300, which merged at a truncated head after a force-push
# dropped two of its cross-review commits.
#
# The binding is the justification naming the commit it was granted for. That
# is the cheapest thing that can be re-affirmed by hand: the refusal below
# quotes the current short sha, so re-affirming on a new head is a copy-paste
# of the line the status just handed you. A hatch that is painful to re-open is
# a hatch nobody uses, and then the pressure goes on the gate instead.
exemption_verdict() {
  local exemption="$1" comments="$2" head_sha="${3:-}"
  local labeled actor actor_type reason claimed

  labeled="$(printf '%s' "$exemption" | jq -r '.labeled // false' 2>/dev/null || printf 'false')"
  [[ "$labeled" == "true" ]] || return 0

  actor="$(printf '%s' "$exemption" | jq -r '.actor // ""' 2>/dev/null || printf '')"
  actor_type="$(printf '%s' "$exemption" | jq -r '.actor_type // ""' 2>/dev/null || printf '')"

  # An exemption record we could not fully read is UNKNOWN, not refused. When
  # the timeline request is rate-limited the actor comes back empty, and
  # refusing on that basis reported failure before an otherwise-current review
  # was even checked — blocking a properly reviewed PR because GitHub hiccupped
  # while reading a label it did not need. Fall through and let the normal
  # currency verdict decide. Same shape as fetch_comments returning `null`
  # rather than `[]`: "no exemption" and "cannot tell" are different facts.
  [[ -n "$actor" && -n "$actor_type" ]] || return 0

  # A hatch a bot can open on its own PR is the fail-open we just closed,
  # wearing a label. Refuse anything that is not a plain human account.
  if [[ "$actor_type" != "User" || "$actor" == *"[bot]" ]]; then
    printf 'failure\t%s\n' \
      "${CR_EXEMPT_LABEL} must be applied by a human, not ${actor} — run /cross-review instead"
    return 0
  fi

  # Newest justification that names THIS head AND was written by the human who
  # applied the label. Any hex run of 7-40 characters in the body counts as the
  # commit reference, provided it is a prefix of the head sha — so both
  # `git rev-parse --short HEAD` and a full sha work, and a hex-looking word
  # that is not this commit does not.
  #
  # AN EXEMPTION IS ALSO BOUND TO THE HUMAN WHO GRANTED IT.
  #
  # Binding it to a commit alone left the hatch self-serve. Attribution comes
  # from the `labeled` timeline event, but the re-affirmation was any comment
  # body at all: so a human labels an earlier head, the PR author (or
  # automation running as the author) pushes new code and posts
  # `Cross-review exemption: ... <new sha>`, and this printed
  # "exempt by @human" for a commit that human never looked at. Anyone who
  # could comment could re-affirm someone else's exemption onto arbitrary code,
  # and the status still named the wrong person as having approved it.
  #
  # Why the comment author rather than "re-apply the label for each head": the
  # label carries neither a commit nor a reason. Re-applying is a removal plus
  # an add, it records nothing about WHICH head it now covers, and pinning it
  # to one would mean comparing the timeline event's timestamp against push
  # times — fragile, and it throws away the written reason that makes the
  # exemption auditable. One comment from the granting human keeps
  # re-affirmation a single obvious action, which is what stops the hatch from
  # becoming a contortion people route around by attacking the gate instead.
  #
  # A comment we cannot attribute (`.user` absent) is not a re-affirmation. The
  # fail-open-on-operational-failure rule covers READING a record, never
  # GRANTING one — same line fetch_exemption draws with `null`.
  reason="$(printf '%s' "$comments" \
    | jq -r --arg re "$CR_EXEMPT_RE" --arg h "$head_sha" --arg a "$actor" \
        '[ .[]? | select((.user // "") == $a) | (.body // "")
           | select(test($re))
           | select([match("[0-9a-f]{7,40}"; "g").string]
                    | map(. as $t | $h | startswith($t)) | any)
         ] | last // ""' 2>/dev/null \
    | sed -nE 's/^Cross-review exemption:[[:space:]]*//p' | head -1)"

  if [[ -n "$reason" ]]; then
    printf 'success\t%s\n' "exempt by @${actor}: ${reason:0:80}"
    return 0
  fi

  # Three refusals, and they are different remedies. Someone else already bound
  # a justification to this head, so the fix is for the granting human to say so
  # themselves. Or the granter bound one to an older commit, so the fix is one
  # more comment. Or nobody justified anything at all.
  local bound_by_other
  bound_by_other="$(printf '%s' "$comments" \
    | jq -r --arg re "$CR_EXEMPT_RE" --arg h "$head_sha" \
        '[ .[]? | (.body // "")
           | select(test($re))
           | select([match("[0-9a-f]{7,40}"; "g").string]
                    | map(. as $t | $h | startswith($t)) | any)
         ] | length' 2>/dev/null || echo 0)"

  if [[ "${bound_by_other:-0}" -gt 0 ]]; then
    printf 'failure\t%s\n' \
      "exemption for ${head_sha:0:9} must be re-affirmed by @${actor}, who applied ${CR_EXEMPT_LABEL}"
    return 0
  fi

  # Distinguish "never justified" from "justified for a commit that is no
  # longer the head" — the second is the one a human has to re-affirm, and
  # saying so is what keeps the hatch usable.
  claimed="$(printf '%s' "$comments" \
    | jq -r --arg re "$CR_EXEMPT_RE" \
        '[.[]? | (.body // "") | select(test($re))] | length' 2>/dev/null || echo 0)"

  if [[ "${claimed:-0}" -gt 0 ]]; then
    printf 'failure\t%s\n' \
      "@${actor} must re-affirm on ${head_sha:0:9}: 'Cross-review exemption: <reason> ${head_sha:0:9}'"
  else
    printf 'failure\t%s\n' \
      "${CR_EXEMPT_LABEL} needs a justification from @${actor}: 'Cross-review exemption: <reason> ${head_sha:0:9}'"
  fi
  return 0
}

# currency_verdict <comments-json-array> <head-sha> [<exemption-json>]
# Prints "<state>\t<description>". State is success|failure. Description is
# kept under 140 chars because that is the GitHub commit-status limit.
currency_verdict() {
  local comments="$1" head_sha="$2" exemption="${3:-}"
  local reviewed any_count exempt

  # An unreadable comment list is an operational failure, not a policy one.
  # Green — see the header. A well-formed empty array is a real answer and
  # falls through to the mandate below.
  if ! printf '%s' "$comments" | jq -e 'type == "array"' >/dev/null 2>&1; then
    printf 'success\t%s\n' "could not read the PR comments — not blocking"
    return 0
  fi

  # Head first, because an exemption is now bound to the head and cannot be
  # evaluated without one. An unknown head is an operational failure and stays
  # green, exactly as it was.
  if [[ -z "$head_sha" ]]; then
    printf 'success\t%s\n' "could not determine the head commit — not blocking"
    return 0
  fi

  # Then the hatch, before the stamp, so it can clear any state including a
  # stale stamp; otherwise it is not an escape hatch.
  exempt="$(exemption_verdict "$exemption" "$comments" "$head_sha")"
  if [[ -n "$exempt" ]]; then
    printf '%s\n' "$exempt"
    [[ "${exempt%%$'\t'*}" == "success" ]]
    return
  fi

  any_count="$(printf '%s' "$comments" \
    | jq -r --arg h "$CR_HEADER" \
        '[.[]? | (.body // "") | select(startswith($h))] | length' 2>/dev/null || echo 0)"
  # Pick the newest record carrying a stamp of EITHER kind, then read the
  # marker out of it if it has one. Selecting on both forms together is what
  # keeps "newest wins" meaningful across the transition: a fresh prose
  # re-review must still be able to clear an older stale marker, and an older
  # prose record must not outrank a newer marker.
  local record
  record="$(printf '%s' "$comments" \
    | jq -r --arg h "$CR_HEADER" --arg m "$CR_MARKER_RE" --arg re "$CR_STAMP_RE" \
        '[.[]? | (.body // "") | select(startswith($h)) | select(test($m) or test($re))] | last // ""' \
        2>/dev/null || printf '')"

  # Marker first. Within one comment the two can disagree — a model may edit
  # the human-readable line, or paste an old one — and the machine-written
  # value is the one with a provenance worth trusting.
  reviewed="$(printf '%s' "$record" \
    | sed -nE 's/.*<!-- cross-review: sha=([0-9a-f]{40}) .*/\1/p' | head -1)"
  # Fall back to prose. `(at )?` is the whole of the widening: the abbreviation
  # is captured in group 2 because group 1 is the optional word.
  [[ -n "$reviewed" ]] || reviewed="$(printf '%s' "$record" \
    | sed -nE 's/.*Reviewed (at )?`([0-9a-f]{7,40})`.*/\2/p' | head -1)"

  if [[ -z "$reviewed" ]]; then
    if [[ "${any_count:-0}" -gt 0 ]]; then
      printf 'failure\t%s\n' \
        "cross-review record carries no SHA stamp — re-run /cross-review, or label ${CR_EXEMPT_LABEL}"
    else
      printf 'failure\t%s\n' \
        "no cross-review record — run /cross-review, or label ${CR_EXEMPT_LABEL} with a justification"
    fi
    return 1
  fi

  # Compare on the stamp's own width: the record abbreviates, the head does not.
  local n="${#reviewed}"
  if [[ "${head_sha:0:$n}" == "$reviewed" ]]; then
    printf 'success\t%s\n' "reviewed at ${head_sha:0:9}"
    return 0
  fi

  printf 'failure\t%s\n' "reviewed ${reviewed:0:9}, head is ${head_sha:0:9} — re-run cross-review"
  return 1
}

# fetch_comments <repo> <pr> — every issue comment, paginated.
# `gh pr view --json comments` issues comments(first: 100) and would hide the
# newest review on a long thread; the REST endpoint paginates properly.
fetch_comments() {
  # `--slurp` is NOT compatible with `--jq` — gh exits with "the `--slurp`
  # option is not supported with `--jq` or `--template`". Combining them made
  # this return [] for every PR, i.e. a permanently green check, and the error
  # went to /dev/null. Shape the JSON in a separate jq, never in gh's --jq.
  #
  # On failure this prints `null`, NOT `[]`. Now that an empty comment list is
  # a red verdict, the two must stay distinguishable: `[]` means "this PR has
  # no cross-review record" and `null` means "we could not find out". Returning
  # `[]` here would turn a rate-limit into 40 simultaneous red PRs.
  # `user` is carried because an exemption is bound to the human who granted
  # it, not only to a commit: exemption_verdict has to know who wrote the
  # justification. currency_verdict's stamp path reads `.body` only and is
  # unaffected. A comment whose author cannot be read comes back with `user`
  # absent, which exemption_verdict treats as "not the granter" — unattributed
  # is never a re-affirmation.
  gh api --paginate --slurp "repos/$1/issues/$2/comments" 2>/dev/null \
    | jq -c '[.[][] | {body: (.body // ""), user: (.user.login // "")}]' 2>/dev/null \
    || printf 'null'
}

# fetch_exemption <repo> <pr> — is the hatch open, and who opened it?
#
# The label itself comes from the PR; the ACTOR comes from the timeline, because
# the label alone does not say who applied it and "a human applied this" is the
# half of the rule that an agent cannot satisfy for itself. Operational failure
# degrades to "not exempt" or to "unknown", never to "exempt".
#
# On a timeline it cannot read this prints `null`, NOT a labeled record with an
# empty actor. That distinction is the same one fetch_comments draws by
# returning `null` rather than `[]`, and for the same reason: the empty-actor
# record made exemption_verdict report failure ahead of the currency check, so
# a rate-limited timeline read blocked PRs that carried a perfectly good review
# stamp and did not need the label at all. `null` falls through to the normal
# verdict, which is fail-closed on its own terms — degrading to "unclaimed"
# never degrades to "exempt".
fetch_exemption() {
  local repo="$1" pr="$2" labeled actor actor_type timeline
  labeled="$(gh api "repos/$repo/pulls/$pr" \
    --jq "[.labels[]?.name] | index(\"$CR_EXEMPT_LABEL\") != null" 2>/dev/null || printf 'false')"
  [[ "$labeled" == "true" ]] || { printf '{"labeled":false}'; return 0; }

  # Captured separately from the jq below so a failed REQUEST is distinguishable
  # from a request that legitimately contains no `labeled` event. Piping gh
  # straight into jq collapses both into `{}`, which is how the empty actor got
  # dressed up as a refusable exemption in the first place.
  timeline="$(gh api --paginate --slurp "repos/$repo/issues/$pr/timeline" \
    -H "Accept: application/vnd.github+json" 2>/dev/null)" || timeline=""
  [[ -n "$timeline" ]] || { printf 'null'; return 0; }

  # Last `labeled` event for this label wins: re-applying after a removal is a
  # fresh grant by whoever re-applied it.
  local ev
  ev="$(printf '%s' "$timeline" \
    | jq -c --arg l "$CR_EXEMPT_LABEL" \
        '[.[][] | select(.event == "labeled") | select(.label.name == $l)] | last // {}' 2>/dev/null \
    || printf '{}')"
  actor="$(printf '%s' "$ev" | jq -r '.actor.login // ""' 2>/dev/null || printf '')"
  actor_type="$(printf '%s' "$ev" | jq -r '.actor.type // ""' 2>/dev/null || printf '')"

  # Label present but nobody attached to it: unknown, not refused.
  [[ -n "$actor" && -n "$actor_type" ]] || { printf 'null'; return 0; }

  jq -nc --arg a "$actor" --arg t "$actor_type" \
    '{labeled: true, actor: $a, actor_type: $t}'
}

main() {
  local pr="" repo="" post=0 sha=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --pr)   pr="${2:-}"; shift 2 ;;
      --repo) repo="${2:-}"; shift 2 ;;
      --sha)  sha="${2:-}"; shift 2 ;;
      --post) post=1; shift ;;
      *) echo "unknown flag: $1" >&2; exit 2 ;;
    esac
  done
  [[ -n "$pr" ]] || { echo "--pr is required" >&2; exit 2; }
  [[ -n "$repo" ]] || repo="${GITHUB_REPOSITORY:-}"
  [[ -n "$repo" ]] || { echo "--repo is required outside Actions" >&2; exit 2; }

  # FAIL CLOSED. This used to `exit 0` — reporting success without having
  # evaluated anything — which silently undid the fail-closed behaviour #3406
  # had just shipped. #3407 then routed this job to the `smalljobs` lane,
  # whose containers carry neither tool, so from that commit on every
  # comment-triggered run took this branch: green job, no status posted, and a
  # stale red status left standing that no amount of re-reviewing could clear.
  # An unverifiable gate must never read as a passing one.
  if ! command -v gh >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
    echo "cross-review currency: cannot verify — gh and/or jq unavailable on this runner" >&2
    echo "  gh: $(command -v gh || echo MISSING)" >&2
    echo "  jq: $(command -v jq || echo MISSING)" >&2
    echo "  Install both on the runner, or route this job to ubuntu-latest." >&2
    # Exit 2, not 1, and the distinction is load-bearing. The workflow wraps
    # this call in `|| true` so that a legitimately stale record (exit 1) is a
    # red STATUS rather than a red job. That wrapper would have swallowed an
    # `exit 1` here too, leaving the broken-environment case as a green job
    # with nothing posted — the exact silent shape this guard exists to kill.
    # 2 means "could not run", which the workflow re-raises; 1 stays "ran, and
    # the answer is no". Flagged by gemini-pro in cross-review of #3433.
    exit 2
  fi

  [[ -n "$sha" ]] || sha="$(gh api "repos/$repo/pulls/$pr" --jq '.head.sha' 2>/dev/null || true)"

  local verdict state description
  verdict="$(currency_verdict \
    "$(fetch_comments "$repo" "$pr")" "$sha" "$(fetch_exemption "$repo" "$pr")")"
  state="${verdict%%$'\t'*}"
  description="${verdict#*$'\t'}"

  printf '%s: %s\n' "$state" "$description"

  if [[ "$post" -eq 1 && -n "$sha" ]]; then
    # A commit status, not a check run: the same context can be updated from
    # both the pull_request and issue_comment triggers, which is what lets a
    # freshly posted review turn this green without a new push.
    gh api -X POST "repos/$repo/statuses/$sha" \
      -f state="$state" \
      -f context="$STATUS_CONTEXT" \
      -f description="${description:0:140}" \
      -f target_url="https://github.com/$repo/pull/$pr" \
      >/dev/null 2>&1 \
      || echo "warning: could not post the commit status" >&2
  fi

  [[ "$state" == "success" ]]
}

# Sourced by the harness → definitions only. Executed → run.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
