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

"Could not read" is fail-open; **"could not run" and "could not publish" are
not.** A runner without `gh`/`jq`, and a status POST that fails, both exit 2 and
fail the job — because in those two cases nothing was written, so whatever
status a previous run left on the commit is still what the merge button sees.
A warning in a log is not a check.

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
cp "$SKILL"/scripts/emit_sarif.sh              scripts/   # only if you enable the sarif job (CR_EMIT_SARIF)
bash scripts/test-cross-review-currency.sh    # expect 176 passed, 0 failed
```

The harness finds the workflow beside itself (this directory) or at
`../.github/workflows/` (a consuming repo), so it works in both layouts with no
edits. It is offline — no network, no `gh`, no tokens; it sources the script and
calls `currency_verdict()` with fixtures.

## Who is allowed to sign off

A record only counts from an account with standing in this repository. Without
that, anyone who can comment can post `## Cross-review` with a stamp naming the
head and turn a required check green — the record is the whole evidence, so its
provenance is the whole gate.

Two checks, because one is not enough:

1. `author_association` must be in `CR_TRUSTED_ASSOC`. Cheap, already on the
   comment, no extra call.
2. and the account's **repository permission** must be in
   `CR_TRUSTED_PERMISSION`. Association is not permission: on an org repo
   `MEMBER` means "member of the owning org" — possibly with no access to this
   repo at all — and `COLLABORATOR` includes read-only and triage-only
   invitations. `OWNER` short-circuits, so the single-maintainer repo pays no
   extra API call.

### Read this before believing step 2 is on

**On the stock `GITHUB_TOKEN`, step 2 does not fire.** That endpoint is gated on
the *caller* having push access; the workflow token here holds `contents: read`,
so the call 403s, `perm` comes back empty for everyone, and the gate falls back
to the association — the very thing step 2 exists to replace. A warning naming
the reason goes to the job log, the status carries `(standing unverified)`, and
under Actions the run gets a **`::warning` annotation** (run summary and the
PR's Checks tab) plus a step-summary paragraph — once per run — so the
degradation is visible without opening a green job's log. It degrades loudly
rather than silently. But it degrades.

To actually get step 2, give the `Report cross-review currency` step a token
that can read repository permissions and make an unreadable one a refusal:

```yaml
env:
  GH_TOKEN: ${{ steps.app.outputs.token }}     # or secrets.CROSS_REVIEW_TOKEN
  CR_PERMISSION_UNREADABLE: refuse
```

**Prefer a GitHub App token over a PAT.** A PAT couples the gate to one
person's account: it expires with them, it carries every repo they can see,
and it walks out the door when they do. An App is installed on exactly the
repos that need it, its token lives ~1 hour, and it has no human attached:

```yaml
      - name: Mint a token that can read repository permissions
        id: app
        uses: actions/create-github-app-token@v2
        with:
          app-id: ${{ vars.CROSS_REVIEW_APP_ID }}
          private-key: ${{ secrets.CROSS_REVIEW_APP_KEY }}
          # Scope the token to this repo only; grant the App the narrowest
          # permission set that makes the call below succeed and no more.
          repositories: ${{ github.event.repository.name }}
```

Verify the token actually works before setting `refuse`, in a one-off step,
against an account that is a non-owner collaborator:

```bash
gh api "repos/$GITHUB_REPOSITORY/collaborators/<login>/permission" --jq .permission
```

If that prints `write`/`admin`/`maintain`, the check is on. If it 403s, the
token still cannot make the call — `refuse` would turn the gate permanently
red, which is the failure mode this design exists to avoid.

**Is there a read-scope endpoint that resolves write access?** Not that we
have found. Every collaborator endpoint (`/collaborators`,
`/collaborators/{login}`, `/collaborators/{login}/permission`) is documented
as requiring the caller to have write, maintain, or admin on the repository,
and the workflow token's `permissions:` block cannot grant that to a job
that must stay `contents: read`. The PR's own `reviewDecision` (GraphQL)
reflects branch-protection evaluation, which only counts approvals from
write-access accounts — but it is a PR-level verdict, not a per-record one,
and it says nothing about who posted a `## Cross-review` comment. If you find
one, replace the lookup in `fetch_comments`; the tests already cover both
policies.

`refuse` is not the default, and deliberately so: on the stock token it would
turn every repo permanently red, and a permanently red gate gets switched off
for good — which is the failure mode this whole design is written against.

So on a personal repo, `OWNER` is doing the real work and is unambiguous. On an
org repo without that token, narrow `CR_TRUSTED_ASSOC` to `OWNER` rather than
trusting `MEMBER`/`COLLABORATOR` to mean write access, because they do not.

The permission lookup is bounded: only the authors of comments that already look
like a review record, distinct, `OWNER` never, and at most
`CR_PERMISSION_LOOKUP_CAP` (10) per run, with anything beyond the cap named in
the log. A PR with no record makes no lookups at all.

The trust filter runs **before** "newest wins". Selecting the newest record and
then checking its author would let an untrusted comment posted after a real
review suppress it — a denial of service that turns a green PR red by
commenting on it.

### Install the workflow before you make the check required

The `currency` job holds `statuses: write`, so it runs on **`pull_request_target`
and checks out the base branch** — never the PR's code, and never under a
trigger whose workflow definition the PR supplies.

Both halves are needed. Pinning `actions/checkout` to the base stops a PR
supplying the *script* that grades it. It does not stop a PR editing *this
workflow file*, because on `pull_request` GitHub runs the PR's version of it:
the same PR can delete the pin, or skip the script and POST
`cross-review/current=success` straight to the API with the token the job
holds. `pull_request_target` is the only PR trigger resolved from the base
branch. It also gives fork and Dependabot PRs a token that can write a status
at all — `pull_request` downgrades theirs to read-only whatever `permissions:`
asks for.

This is the agent case, not an attacker's: an agent with push access, told to
get CI green, edits the file in front of it.

**`pull_request_target` is a footgun, and it is safe here for one narrow reason
that must stay true: this workflow never checks out or executes PR code.** The
PR's own tests run in the `self-test` job, under plain `pull_request`, with
`contents: read` and nothing else. The harness asserts that split — the trigger
of each job, the checkout ref, that there is exactly one checkout, and that the
privileged job names no build step — so it cannot silently invert. If you add a
PR-ref checkout or an install step to `currency`, you have re-opened all of it.

The consequence at install time: on the PR that *adds* the gate, the base has
no script yet, so the job exits 2 and goes red with a message saying so. Merge
that PR first (the context is not required yet), then turn on branch
protection. Reversing the order needs an admin merge.

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
| `CR_TRUSTED_ASSOC` | `OWNER MEMBER COLLABORATOR` | associations eligible to post a record |
| `CR_TRUSTED_PERMISSION` | `admin write maintain` | repository permissions that count as sign-off |
| `CR_PERMISSION_UNREADABLE` | `trust` | `trust` or `refuse`, when the permission cannot be read |
| `CR_PERMISSION_LOOKUP_CAP` | `10` | max distinct record authors resolved per run |

Nothing else is repo-specific. There are no hardcoded branch names, org names,
or issue numbers.

## The escape hatch

For the PRs the standing rule already lets skip cross-review — docs-only,
dependency bumps, rename-only. A PR is exempt when **all four** hold:

1. it carries the `cross-review-exempt` label,
2. applied by a **human account** (the `labeled` event's actor is not a bot or
   an app),
3. a comment starts `Cross-review exemption:` followed by ≥15 characters of
   actual reason, and that reason **names the head commit** — the commit
   reference itself does not count toward the 15, or the sha would satisfy the
   minimum on its own and the hatch would open with no reason at all,
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
