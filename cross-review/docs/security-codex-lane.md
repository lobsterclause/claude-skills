# The codex lane's execution posture — accepted risk, 2026-09-21

An adjudicated cross-review finding (kindred-mama-ai, carried across several
sessions as an open P1) said: *"`codex exec` runs unsandboxed in the checked-out
repo with normal agent tools, while the shared prompt tells the reviewer it has
no file or shell access — a prompt-injected diff could act on that gap, on a
seat meant to review untrusted PRs on the self-hosted lane."*

Two of its three clauses are wrong. The posture it points at is real. This
records what is actually true, and that the residual risk is **accepted** rather
than mitigated.

## What was checked

`scripts/run_reviewers.sh`, the codex dispatch:

```bash
run_with_timeout "$codex_timeout" codex exec review \
  --base "$base" \
  -c 'approval_policy="never"' -c 'sandbox_mode="workspace-write"' \
  ...
```

**"Unsandboxed" is false.** `sandbox_mode="workspace-write"` is a sandbox: reads
and writes are confined to the workspace. What `approval_policy="never"` removes
is the confirmation prompt, not the boundary. A headless reviewer cannot answer
a prompt, so this is required for the lane to run at all.

**"The shared prompt tells it it has no file access" is false.** `codex exec
review --base` never receives `$review_prompt` — it runs codex's own built-in
review instructions, and the script says so at the call site. The only text this
skill injects into the codex lane is the no-deps note, carried via a temporary
`AGENTS.md`:

> ENVIRONMENT: dependencies are NOT installed in this checkout (package.json is
> present, node_modules is absent). Do not run tests, builds, linters or
> typecheckers: they fail on missing modules, and that failure tells you nothing
> about the diff. Review by reading the code.

That is an advisory about what is *useful*, not a claim about what is
*permitted*. There is no contradiction between what codex is told and what it
can do, because nothing tells it it cannot.

**The third clause is right, and is the real posture.** The lane runs an agent,
with shell access, without approval, over an attacker-controlled diff.

## The part worth naming: the worktree is not isolated from the repo

Reviews run in a `git worktree`, so the workspace root contains a `.git`
**pointer file**:

```
$ cat <worktree>/.git
gitdir: /Users/…/kindred-mama-ai/.git/worktrees/cr-pr-4011-p4-…
```

Raw file writes outside the workspace are blocked by `workspace-write`, and the
main repository's git directory is outside it. But `git` commands run *inside*
the worktree resolve that pointer and operate on the real repository — and
running commands is not what the file sandbox restricts.

So the honest boundary is: **the codex lane is sandboxed against stray file
writes and not against git operations on the host repository.** That is a
narrower and more specific statement than the original finding, and it is the
one to re-examine if the posture is ever revisited.

The consequences of a successful injection are bounded by that: the review
worktree is torn down after every round, so writes into it are discarded; the
seat's *output* is attacker-influenceable, but the pipeline already treats every
finding as an unverified claim requiring adjudication, which is the same
assumption applied to all seats.

## Why it is accepted rather than fixed

codex's file access is the reason it is the highest-precision seat in the fleet.
The measured gap is stark — adjudicated precision on 2026-08-24 was 25/26 for
codex with file access against 0/4 and 0/3 for hunk-only seats, and the whole
`--context-mode files` and tool-loop design exists because seats that cannot see
past the hunk produce confident, wrong findings. Constraining the lane would
trade a real, measured precision gain against a speculative injection path that
has not been observed.

Accepted on that basis, 2026-09-21. Not a claim that the risk is zero.

## What would change the decision

- Running the lane against diffs from outside the trust boundary (public forks,
  contributors without commit rights) rather than agent- and
  teammate-authored PRs.
- Any observed instance of reviewer output steering a downstream action, as
  opposed to being adjudicated first.
- A codex sandbox mode that separates "may run commands" from "may run commands
  that reach the host repository", which would make this cheap to close.

## Known adjacent behaviour, not a vulnerability

Because codex reads the whole worktree, it reviews this skill's own transient
scaffolding along with the PR. It has twice filed findings against the temporary
`AGENTS.md` and `.agents/hooks.json` that the wrapper injects and removes. Those
are false positives about the harness, not about the diff — discard them, and do
not "fix" a file the round created.
