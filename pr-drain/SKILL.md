---
name: pr-drain
description: >
  Drain a backlog of open PRs through a review → fix → verify → CI → merge pipeline with
  durable state in a GitHub checklist issue. Use this whenever the user asks to "drain the
  PR pool/backlog", "merge the open PRs", "work through the PR queue", "babysit these PRs
  to merge", or points at a checklist issue of PRs to land — even if they don't say
  "drain". Also use it when the user asks to resume or check on a previous drain. Supports
  a dry-run mode (report intended actions without pushing, merging, or editing issues) —
  use dry-run when the user asks "what would it take to merge these" or wants a plan.
---

# pr-drain — pipelined PR-backlog merge orchestrator

Drains a list of PRs to merged, one merge at a time, with reviews and fixes pipelined into
the CI dead-time. Built from a 25-PR overnight drain (2026-08-15, kindred-mama-ai) that hit
zero incidents; every rule below earns its place by a specific failure it prevents.

## Inputs

- **Checklist issue number** (required): a GitHub issue whose body is `- [ ] #<pr> — <title>`
  lines. This issue is the ONLY durable position state. If the user has no issue yet, offer
  to create one from `gh pr list`.
- **Dry-run** (optional): if the user asks for a plan, a simulation, or says dry-run, set
  `PR_DRAIN_DRY_RUN=1` for every script call and NEVER run push / merge / issue-edit /
  comment commands — print what each would be instead.

## Architecture: stations, not per-PR owners

Three roles. Context stays hot across PRs because the same agents keep working:

- **Orchestrator (you)**: rehydrate position, dispatch work, watch CI, merge, write back
  state, enforce stop conditions. Merging and checklist edits are NEVER delegated —
  a single writer is what makes the state trustworthy.
- **Reviewer** (named subagent `drain-reviewer`, spawned once, continued via SendMessage):
  runs cross-review rounds, splits findings into apply-P0/P1 vs refute-with-evidence. It
  accumulates a refutation library across PRs — by the fifth PR it already knows which
  reviewer claims are provably false.
- **Fixer** (named subagent `drain-fixer`): applies findings in the PR's worktree, runs
  the single allowed verify, pushes with `--force-with-lease`.

Spawn prompts for both stations are in `references/station-agents.md` — read it before the
first dispatch. Inline handling (orchestrator doing all three roles) proved out to at
least a 10-PR backlog in the live shakedown, so stations are an option for scale or
parallel drains, not a requirement — when in doubt, run inline; the protocol is
identical. (Honest status: the station prompts are designed but have not yet run live.)

## Durable state: three layers

1. **The checklist issue** — position of record. Re-read it at the start of EVERY
   iteration (`gh issue view <n> --json body`); never trust conversation memory for
   position. Chat context gets compacted mid-drain; the issue doesn't.
2. **Event log** — `scripts/queue.sh append <pr> <state> <sha> [note]` writes one JSON
   line to `<workdir>/events.jsonl`. States: `QUEUED REVIEWING FIXING VERIFYING CI
   MERGED BLOCKED`. `queue.sh status` prints each PR's latest state. After a compaction,
   `queue.sh status` + the issue fully reconstruct the pipeline; log every transition.
3. **GitHub artifacts** — stamped review comments and PR comments hold the working notes.
   The checklist issue stays a bare checklist; notes go on the PR, never the issue.

## Locks (one mutating thing at a time)

`scripts/lock.sh acquire|release <name>` — flock-free lockfile with stale-PID reaping.
Two locks exist and both matter:

- `verify` — never two verify/vitest runs at once. Concurrent worker pools from two
  worktrees have caused false 5-minute timeouts that read as real failures.
- `review` — one cross-review round at a time. Reviewer fleets share provider quotas;
  two concurrent rounds double the burn and can kill the remaining seats for days.

## Per-PR sequence (stop at the first failing step)

1. **Mergeability**: `gh pr view <n> --json mergeable,mergeStateStatus`. UNKNOWN → re-poll
   once after 5s. CONFLICTING → rebase onto the base branch in a dedicated worktree
   (a CONFLICTING PR runs ZERO checks, so an empty check list is not green). Do not
   rebase merely to be current unless base-branch protection requires it.
2. **Review currency**: read the repo's review-currency status (e.g. `cross-review/current`).
   A green status whose description says "no review record" is NOT a review. No record or
   an older SHA → run the review station. Description matches current `headRefOid` → step 4.
3. **Triage findings — verify the claim against reality FIRST.** In a 35-PR live drain,
   five of eight Critical/High claims were false, and every false one was a misread of
   *existing* code: a green CI run already disproved the "test can never pass" claim, the
   "missing permissions block" existed at the cited line, the "broken" expression did the
   opposite of the description. So before applying or rejecting anything, check the claim
   against the file and the live CI state — one grep or one check-run lookup kills most
   false P0s. Then the fixer station applies what survives; reviewer consensus is not
   correctness in either direction.

   **Log every P0/P1 verdict**: `scripts/claims.sh log <reviewer> <severity>
   APPLIED|REFUTED|OUT_OF_DIFF|NOTED <pr> "<claim>" ["<evidence>"]` (REFUTED requires the
   disproving one-liner). Before spending real verification effort on a claim, check
   `claims.sh prior <reviewer>` — a reviewer whose past Criticals rarely survive earns a
   cheap first-pass check, not deep investigation. The ledger accumulates across drains
   (`~/.pr-drain/claims.jsonl`); it is how the skill's triage gets smarter without anyone
   editing it. Re-run review only for non-trivial fixes; for a trivial
   delta (develop merge + small mechanical fix), post an updated stamp on the new SHA
   explaining exactly what changed since the reviewed SHA.
4. **Verify**: repo's verify entrypoint green in the PR's worktree (under the `verify`
   lock) before any push. Fresh-worktree runs are cold-cache — budget 3-4× the warm time.
5. **Push and watch CI**: launch `scripts/poll-ci.sh <pr> <sha>` as a background task —
   it watches required checks and auto-merges on all-green with `--match-head-commit`.
   Before reading ANY check result, confirm its SHA equals the PR's current `headRefOid`.
6. **Merge** happens via the poller (or manually: `gh pr merge <n> --squash
   --match-head-commit <sha>`). The SHA binding is non-negotiable: it is the only thing
   that prevents merging a head some concurrent process force-pushed under you.

## Pipelining (depth 2, no deeper)

Whichever of CI (~10-15 min) and the review round (~10-15 min) is currently waiting is
your dead time — fill it with the other lane's work on the next PR. In practice reviews
are often the drum-beat, not CI: PRs that have sat open usually arrive with green checks,
so the serial constraint is the review lock. Mechanical work (a conflict rebase, a
stale-base develop merge) slots into review waits especially well — it needs neither
lock. Do NOT go depth 3: a third lane just queues behind the locks and burns quota.

- Merges stay strictly serial and in checklist order.
- **Overlapping-surface PRs stay serial relative to each other**: before pipelining N+1,
  check `gh pr view --json files` overlap with N. If they touch the same files, hold N+1
  until N merges (its review would be against a base about to move).
- When N merges, the base advances under N+1. Don't auto-rebase; re-check before
  finalizing: if a reviewer flags a "deletion you didn't make", suspect stale base, not
  your diff.

## Safety invariants (each one paid for by a real incident)

1. **No git mutation in the user's main checkout, ever.** All branch work happens in
   dedicated worktrees. Shared checkouts get their HEAD moved by concurrent sessions;
   commits land on the wrong branch and force-pushes can drop other people's work.
2. **Force-pushes use `--force-with-lease=<branch>:<expected-sha>`**, and before any
   force-push, diff the old and new commit lists (`git log --oneline old..new` + patch-id
   compare). A replay that emits fewer commits than it consumed dropped work — the lease
   will NOT catch that. If a force-push would drop commits: STOP, tag the old head
   (`git tag salvage/...`), and hand it to the user.
3. **Never claim green against a stale SHA.** Every check result, every merge, every
   "done" is verified against the current `headRefOid` at that moment.
4. **No bare `git stash`** — the stash stack is repo-global across worktrees; concurrent
   bare pops swap contents between tasks. Use a WIP commit, or `stash push -m <tag>` and
   apply by SHA.
5. **A failure in a file your PR doesn't touch = stale base. Merge the base branch in;
   do not debug the file.** This is the single most valuable diagnostic in the skill: in
   the live drain it appeared three times (two racing merge-ref type errors, one phantom
   prettier failure that stalled two automated takeover attempts for 90 minutes and fell
   in 10 once recognized). Two PRs that each passed CI can break the base once both land.
   Fix in-branch with a base-branch merge and a clearly-labeled commit. Track
   same-check-twice fairly: the first failure was the base's, so a second, different
   failure is attempt one for the PR itself — say so explicitly in the log.

## Wake discipline (event-driven, not polling)

- `poll-ci.sh` background tasks are the primary wake signal for CI.
- Station agents message the orchestrator on completion (SendMessage) — no polling them.
- Keep a long fallback heartbeat (20-30 min) armed via ScheduleWakeup if running inside a
  /loop; its only job is surviving a hung poller. Re-arm it EVERY turn, and never claim a
  heartbeat is armed without checking its scheduled time is actually in the future — a
  lapsed wakeup that you believe is armed leaves the loop with no fallback at all (this
  happened once in the live drain; the user caught it, not the process).
- A poller that exits on "runner lost communication with the server" is an infra death,
  not a code failure — Dagger Check may have already passed. Rerun the failed job once,
  relaunch the poller on the same SHA, and note which step the runner died in (a new
  resource-heavy step can be what killed the box).

## Write-back (mandatory per iteration — an untracked iteration is a lost one)

- **Merged**: tick the PR's line in the checklist issue (`- [ ]` → `- [x]`), append a
  `MERGED` event. Nothing else changes in the issue.
- **Blocked**: create a `pr-drain`-labeled issue (what was tried, exact failing check +
  SHA, smallest next action), append ` — blocked by #<new>` to the PR's line, label the
  PR `needs-human`, append a `BLOCKED` event.
- Working notes → PR comments.

## Stop conditions (comment the reason on the checklist issue, then stop)

- 3 consecutive iterations with no merge.
- Any force-push that would drop commits.
- CI red on 3+ different PRs → infra problem, not code.
- Same PR fails the same check twice (honoring invariant 5's attribution rule).
- All lines ticked or blocker-linked → run the retrospective (below), THEN close the
  issue with a summary and notify the user.

## Retrospective (mandatory close-gate — this is how the skill self-improves)

A drain is not finished when the last PR merges; it is finished when its lessons are
extracted. Before closing the checklist issue:

1. Run `scripts/retro.sh` — it computes the drain's numbers (per-PR wall time, merged vs
   blocked, P0/P1 applied/refuted with the refutation evidence) and prints five
   questions: bottleneck reality-check, new failure classes, false-P0 patterns,
   distillation (which rule did NO work — three idle drains → cut it), and a regression
   re-run of the dry-run evals after any SKILL.md edit.
2. Answer them by DOING: edit SKILL.md where reality diverged from it, write one memory
   file per new failure class, file issues for anything bigger. An unanswered retro
   question is a lesson the next drain pays for again.
3. `scripts/retro.sh --mark-done` — only after the edits are made or queued. Closing the
   checklist issue without the `retro-done` stamp is a protocol violation; if you notice
   it missing at close time, the retro was skipped — go back.

The retro exists because the improvement loop ran exactly once by luck (a user asked
"reflect on the results") before it was made structural. Data the drain already writes
(events.jsonl, claims.jsonl) makes it nearly free; the only real cost is honesty.

## Dry-run mode

With `PR_DRAIN_DRY_RUN=1`: all reads run normally (issue body, PR state, check runs,
diffs); every GITHUB mutation (push, merge, issue edit, comment, label, review dispatch)
is printed as `DRY-RUN: would <command>` instead of executed. Local state still writes:
the event log and claims ledger are the dry-run's own deliverables, not mutations. The deliverable is a per-PR
plan: current state, what step it's at, what would happen next, and expected wall time.
`poll-ci.sh` honors the same variable (reports instead of merging).
