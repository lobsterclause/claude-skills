# cross-review/ci — the merge gate that binds everyone

`hooks/merge_gate.sh` refuses `gh pr merge` when the review record is stale.
It binds **the agent that runs it**, and nothing else. It cannot see a merge
inside a shell script, a GraphQL `mergePullRequest` mutation, the GitHub web
UI, or automerge — and it never sees a human at all.

This directory is the other half: a commit status computed from PR state, so
it covers all five.

| | `hooks/merge_gate.sh` | `ci/cross-review-currency.*` |
|---|---|---|
| Claude running `gh pr merge` | ✅ | ✅ |
| A script or another agent merging | ❌ | ✅ |
| GraphQL mutation / automerge | ❌ | ✅ |
| Web UI merge button | ❌ | ✅ |
| A human | ❌ | ✅ |
| Blocks without branch protection | ✅ | ❌ |

Run both. The hook fails fast in the agent's own loop; the status is the one
that actually holds.

## What it checks

One question: **is the newest cross-review record on this PR bound to the head
commit that is about to merge?**

It reads PR comments for a record starting `## Cross-review` that carries a SHA
stamp, and compares that SHA to the head.

- bound to the head → `success`
- bound to an earlier commit → `failure`, naming both commits
- no record, or a record with no stamp → `failure`
- **could not read** (gh/jq missing, API failure) → `success`, with a
  description saying so

That last one is deliberate and is the line to keep straight: *"we read the
comments and there were none"* and *"we could not read the comments"* are
different facts. Conflating them lets one GitHub hiccup red-flag every open PR,
which is how a gate gets switched off for good.

## Install

Three files, into two places:

```sh
SKILL=~/.claude/skills/cross-review          # or wherever the skill lives
cp "$SKILL"/ci/cross-review-currency.sh       scripts/
cp "$SKILL"/ci/test-cross-review-currency.sh  scripts/
cp "$SKILL"/ci/cross-review-currency.yml      .github/workflows/
bash scripts/test-cross-review-currency.sh    # expect 115 passed, 0 failed
```

The harness finds the workflow beside itself (this directory) or at
`../.github/workflows/` (a consuming repo), so it works in both layouts with no
edits. It is offline — no network, no `gh`, no tokens; it sources the script and
calls `currency_verdict()` with fixtures.

Then make it required, or it is decoration:

```
Settings → Branches → <your branch> → Require status checks → cross-review/current
```

**Turning that on blocks every open PR that has no stamped record, at once.**
That is the intended behaviour, not a bug — but schedule it and announce it
rather than springing it, and use the escape hatch below instead of reverting.

## Knobs

| Env | Default | Meaning |
|---|---|---|
| `CR_CURRENCY_CONTEXT` | `cross-review/current` | commit-status context name |
| `CR_EXEMPT_LABEL` | `cross-review-exempt` | escape-hatch label |

Nothing else is repo-specific. There are no hardcoded branch names, org names,
or issue numbers.

## The escape hatch

For the PRs the standing rule already lets skip cross-review — docs-only,
dependency bumps, rename-only. A PR is exempt when **all four** hold:

1. it carries the `cross-review-exempt` label,
2. applied by a **human account** (the `labeled` event's actor is not a bot or
   an app),
3. a comment starts `Cross-review exemption:` followed by ≥15 characters of
   actual reason, and that reason **names the head commit**,
4. written **by that same human**.

(3) and (4) exist because GitHub preserves both the label and the comment
across a push. Without (3), a human exempts a docs-only PR, the contributor
pushes executable code, and the `synchronize` run returns success out of the
exemption path before the head is ever looked at. Without (4), the exemption is
bound to a commit but not to a person — the PR author, or automation running as
the author, pushes new code, posts the new SHA, and the gate reports "exempt by
@human" for a commit that human never saw.

So an agent cannot clear its own PR: a bot-applied label is refused outright,
and the granting actor plus the reason are written into the status description,
making every exemption attributable in the timeline.

Re-affirming after a push is one comment on the new head, by the person who
granted it. The refusal message quotes both the SHA to paste and the account
that has to paste it.

## The stamp contract

The gate reads two forms, and prefers the first:

```
<!-- cross-review: sha=<40 hex> pass=<n> -->     ← machine-written, preferred
Reviewed [at] `<7–40 hex>`                        ← prose fallback
```

`scripts/post_comment.sh` emits the marker whenever it knows a full-width head
SHA. **Keep that literal byte-for-byte** — the harness greps it out of
`post_comment.sh` and renders it against the gate's regex, so the two halves
cannot drift apart silently. That test is the only thing checking that the
skill writes what the gate reads.

Why a marker when the prose is right there: prose drifts. A census of the 10
most recent review comments found four written by hand as ``Reviewed at `<sha>` ``
instead of ``Reviewed `<sha>` ``. One English word, and a working gate read four
correctly-reviewed PRs as unreviewed — 40% of the sample. The marker is the form
nobody composes by hand, and it carries all 40 characters, so it also has none
of the prefix ambiguity an abbreviation has.

The prose forms stay accepted as a fallback because every comment already on
GitHub is prose-only and those records are not re-postable. Dropping the
fallback would red-flag genuinely reviewed work.

## What it does not do

- It does not block merge by itself. It reports a commit status; whether that
  status is required is a branch-protection setting.
- It does not review anything. It checks that a review record exists and is
  current — not that the review was good.
- It never guesses about operational failure. See the fail-open note above.
