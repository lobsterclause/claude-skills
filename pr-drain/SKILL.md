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

## Architecture: run inline

You do all three jobs — orchestrate, review, fix. Context stays hot across PRs
and the refutation library accumulates in your head, which is where it is most
useful.

Station subagents (`references/station-agents.md`) were designed for scale and
have now sat unused across **four consecutive drains** (2026-08-15, 08-16,
08-24, 08-29). Adjudication is the expensive part of this work and it does not
split: handing a claim to another agent costs more context than it returns.
Treat the stations file as an archived idea, not an option to weigh each time.

## Durable state: three layers

1. **The checklist issue** — position of record. Re-read it at the start of EVERY
   iteration (`gh issue view <n> --json body`); never trust conversation memory for
   position. Chat context gets compacted mid-drain; the issue doesn't.
2. **Event log** — `scripts/queue.sh append <pr> <state> <sha> [note]` writes one JSON
   line to `<workdir>/events.jsonl`. States: `QUEUED REVIEWING FIXING VERIFYING CI
   MERGED BLOCKED`. `queue.sh status` prints each PR's latest state. After a compaction,
   `queue.sh status` + the issue fully reconstruct the pipeline; log every transition.
   **Every script needs `PR_DRAIN_WORKDIR` set to an absolute path** — use
   `$HOME/.pr-drain/<repo>-<checklist-issue>` and pass it on every call. The scripts
   refuse (exit 2) without it. They used to default to a cwd-relative `.pr-drain`, and
   since each tool call starts in whatever directory it starts in, that gave every call
   site its own log. The 2026-09-17 drain wrote 1 event to its named workdir and 44 to
   the repo checkout's `.pr-drain`, so the resume and the retro both read the
   near-empty one. An 08-19 retro-done stamp ended up in the skill's own directory.
   Two lock callers in different directories never saw each other's locks.
   (`pr-drain/tests/workdir-required.test.sh` pins this.)
3. **GitHub artifacts** — stamped review comments and PR comments hold the working notes.
   The checklist issue stays a bare checklist; notes go on the PR, never the issue.

## Locks (one mutating thing at a time)

`scripts/lock.sh acquire|release <name>` — flock-free lockfile with stale-PID reaping.
Two locks exist and both matter:

- `verify` — never two verify/vitest runs at once. Concurrent worker pools from two
  worktrees have caused false 5-minute timeouts that read as real failures.
- `review` — one cross-review round at a time. Reviewer fleets share provider quotas;
  two concurrent rounds double the burn and can kill the remaining seats for days.

**The lock was decorative until 2026-09-03.** `lock.sh` recorded its own pid, which is
dead the instant it exits, so the next caller's stale-pid reaper removed every live
lock. Two `pnpm verify` runs overlapped and one went red on a test that writes a fixed
`/tmp` path (kindred-mama-ai #3737) — exactly the false red the lock exists to
prevent. It now records `$PPID`; acquire and release in the SAME shell invocation so
that pid stays alive across the critical section, and `grep HOLDER_PID lock.sh` before
trusting a lock in a fresh session.

**In an agent harness where each tool call is its own shell, that instruction cannot
be followed** — `$PPID` dies the moment the acquiring call returns, so the next
caller's stale-pid reaper removes the lock and it protects nothing. Observed
2026-09-19: locks were acquired and released across separate calls all drain, i.e.
decoratively. Do not let a held lock substitute for the real guarantee, which is
sequencing your OWN calls: run one verify and one review round at a time because you
chose to, not because a file says you may. The lock earns its place only between
separate processes (a backgrounded chain, a peer session) — pass
`PR_DRAIN_LOCK_PID=$$` from inside the long-running script there, and treat a lock
acquired in a one-shot tool call as advisory at best.

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
   correctness in either direction. (A second drain: 8 of 16 P0/P1 claims refuted. The
   base rate is ~50%; budget for it.)

   **Named false-P0 patterns, cheapest check first.** Run down this list before spending
   real effort:
   - **Self-refuting** — the finding's own closing sentence says "no correctness bug
     here". Read to the end before acting. (Twice in one drain, same reviewer.)
   - **Reasoned about output never executed** — "this command prints `X: y (y)`" when
     running it prints a bare line. Convergent across two independent providers and still
     wrong; convergence is not evidence. The same family covers "flag A makes flag B
     silently ignored": run the command with a deliberately-bogus value for the flag in
     question — a control that returns 0 rows proves the flag is honored (probes need a
     PASSING control, or a broken probe is indistinguishable from a confirmed claim).
   - **Wrong library major** — four reviewers called a Terraform stack syntactically
     invalid using provider v4 syntax against a v5 pin; `tofu validate` → Success. Check
     the pinned version before believing a "this cannot even parse" claim.
   - **Premise absent from the build** — an argument from CSS Cascade Level 5 layer
     precedence, where `grep -c '@layer'` on the *compiled* output returns 0.
   - **Contradicted at the cited line** — "no try/catch around this read" when the cited
     lines are exactly that. Open the file at the line number given.
   - **"Import/module missing" on a refactor diff** — diff-only reviewers see new
     symbols without seeing the import hunk or the (pre-existing) module and file
     Criticals. 7 of 10 refuted claims on one reskin PR were this shape. One grep for
     the import plus one `ls` of the module kills the whole family — and a green
     type-checking CI run at that head already disproves it wholesale.
   - **CI-adjudicable claim** — "this mock crashes the test env", "this import order
     fails lint": the claim predicts a gate outcome, and the gate has already run.
     A green run at the reviewed head refutes the whole family in one lookup
     (2026-08-19b: a gemini-pro Critical fell to a 30-minute green mobile lane).
     Check the live check-run BEFORE reading the code the claim cites.
   - **Snippet-scoped reading** — "flag `--repo` is missing", where the flag sits on
     the continuation line the reviewer's own snippet stopped at. The tell is a
     finding whose quoted `snippet` ends in `\` or mid-expression. `sed -n '<line>,+3p'`
     settles it. Four of one reviewer's seven claims on one PR were this shape, and
     it is the dominant failure mode of the low-precision seats — see
     `claims.sh prior`.
   - **A panic predicted in a consumer that does not exist** — "this span is a
     char count, so slicing it panics on multi-byte UTF-8", where nothing in the
     repo slices by that span. Both of 2026-09-19's refutations had this shape
     (the other: a NaN panic in `f32::clamp`, which panics only when *min/max* is
     NaN). The claim is always about a downstream consumer, so **grep for the
     consumer before reasoning about the semantics** — if nothing calls it that
     way, the argument is moot however correct its language lawyering.
   - **Claim that would invalidate a passing suite** — "the quoted pattern makes this
     comparison literal, so staleness is NEVER detected". If true, a dozen existing
     tests would be lying. A finding that implies the whole suite is vacuous is
     almost always the reviewer misreading, not the suite being fake — but it is
     cheap to settle, so settle it with one probe rather than dismissing it.
   - **Refutable by a five-line probe** — a claim about language or API
     semantics ("this descriptor is non-configurable, so re-stubbing breaks").
     Two independent providers raised the same P1 on one PR and both were
     wrong: `writable: true` permits *assignment* even when
     `configurable: false`, and assignment is what the test framework actually
     does. Convergence is not correctness — and a claim of this shape is
     usually settled faster by running `node -e` than by reading the code it
     cites. Check whether the claim also predicts a gate outcome first: a green
     run at the reviewed head kills it for free.
   - **Right conclusion, wrong mechanism** — the finding's stated cause is
     false but a narrower true case exists ("a MISSING `githubRepo` errors" —
     it does not; jq returns null; only a SCALAR one errors, and the reviewer's
     suggested fix does not handle that either). Adjudicate the stated
     mechanism, not just the conclusion, and record WHICH you verified: log it
     APPLIED with the real cause, or REFUTED with the disproof, never a vague
     "partially right". The mirror case also happens — a reviewer asks you to
     justify something that a linked issue already mandates.
   - **Guard-purpose inversion** — a change that is more correct in isolation is
     wrong for what the guard is FOR. Resolving `export { type A as B }` to `B`
     is correct alias parsing and wrong for a runtime-reachability check, where
     recording a type as a value export lets a dormant module pass. Before
     judging a parser/matcher change, ask what the caller DOES with the result.
     (I made this error myself and a reviewer caught it — the direction of the
     catch is not the point; asking the question earlier is.)
   - **Design-intent inversion** — the reviewer reads a deliberate guard as the bug
     ("this equality fails when there are multiple failures" — yes: that inequality IS
     the only-failure condition). Check whether the "broken" case has a test pinning
     it as intended before applying.
   - **Claim about configuration that does not exist** — "the `${var-default}` is
     defeated if the workflow maps it from an undefined `vars.*`". One grep of the
     workflow for the variable name settles it: count 0 means nobody maps it, and the
     claim is about a future edit, not this diff. Log it NOTED for whoever adds the
     mapping; do not fix a hypothetical. (gemini-pro on #3650, 2026-09-03.)
   - **Mirror-image finding** — the reviewer's P1 is the inversion of a P1 you applied
     on the same PR two rounds ago: the `-y` adjective suffix admitted "toy chest"
     (removed), then its absence missed "dirty face" (flagged). Both are true. Neither
     is a bug in the fix; the class is open-ended and a regex list cannot bound it. This
     is not a triage verdict, it is a STOP signal — see stop conditions. (#3362, 2026-09-03,
     passes 6-8: 45 P0/P1 applied, 0 refuted, still oscillating.)
   - **A passing test's expected output read as the failure** — `--log-failed` on a
     red Dagger run printed `[audit] FAIL: 1 dead glob(s) … renamed-away.ts`, and I
     diagnosed a wiki-audit fixture bug for two turns. That line was subtest 62's
     EXPECTED output; the run was red for a `tsc` error 1,300 lines later. Read the
     job's `Error:` / non-zero exit line first, then grep backwards from it — never
     grep the whole log for `FAIL` and trust the first hit. (#3362, 2026-09-03.)

   **A green that was never computed is the most dangerous result in a drain.** It is not
   one bug, it is a family, and four distinct members showed up in a single night. Ask of
   every green: *what would have made this red, and did that path actually run?*
   - A review round that completes but writes no findings/record — reviewer output exists
     only as raw files on disk; the stamp is absent or says "no review record". A green
     status whose description says "no review record" is NOT a review.
   - A test file no runner invokes (`*.test.mjs` under a vitest project globbing only
     `*.test.ts`; a `node --test` file nothing calls). Confirm the runner's glob actually
     matches the file before believing its pass count.
   - A test that passes with the thing it tests DELETED — e.g. asserting `/500/` against a
     whole file where "500MB" also appears in a comment, or a whole-file `includes()`
     instead of an assertion about the specific key.
   - **A gate that passes because it cannot see.** #4013's secrets-binding gate was green
     on CI and on develop only because its declaration regex could not match the repo's
     prettier-wrapped `defineSecret(\n  "NAME",\n)` form. Once it could see those
     declarations it failed develop on a real unbound secret. When a review fixes a
     gate's blind spot, run the gate against the real tree before pushing. A newly red
     tree means the gate works, and it makes the PR a decision for its author rather
     than a merge. (2026-09-24.)
   - A mutation probe that silently matches nothing and reports a clean pass — which is
     indistinguishable from "the gate cannot fail". **Before trusting any mutation result,
     red or green, confirm the mutant landed via `git diff --numstat`.** This bit two
     independent agents in one drain.
   - **A wrapper that announces its own success.** A harness ending in
     `run X; echo "ROUND COMPLETE"` prints that banner even when X rejected its
     arguments and did nothing. Observed: a cross-review round launched with an
     unknown flag ran ZERO reviewers, printed COMPLETE, exited 0, and left a run
     dir containing only `context.json`. Stamping from that notification would have
     posted a clean review record for a review that never happened. **Prove a round
     by its artifacts — `ls "$run_dir" | grep -c stdout` — never by a banner or an
     exit code.** The banner is your own string; it knows nothing.
   - **An orphaned test double.** Delete the code that made a call and its stub arm
     survives, so reintroducing the call is silently satisfied by a stale fake.
     Remove fixtures in the same commit as the capability, or make the dead arm log
     and `exit 1` so reintroduction is loud.
   - **A comment-only fix.** The commit says "re-sampled per run", the assignment is
     still outside the loop, and the file now documents behaviour it does not have.
     Prose is not a check. If a fix is worth a comment claiming it, it is worth an
     assertion that fails when the comment stops being true.
   When a fix claims to make a gate binding, require a control: break it, watch it go red,
   restore it, watch it go green. "The tests pass" is not evidence that a gate works.

   **A rising pass count is not rising coverage.** Deleting four real cases and adding
   four duplicates moves the number in the reassuring direction. When the count changes
   for a structural reason, say so in the commit.

   **Fixing one bound moves the binding constraint to its neighbour.** Five consecutive
   rounds on one PR: per-call timeouts made their sum matter, the sum made the scan's
   share matter, the scan bound made its ordering matter. This is not the reviewer
   nitpicking and it is not the design failing — it is what bounding a system looks
   like. Fix it at the level that closes the class (clamp inside the shared helper, not
   at each call site), or the next round finds the next instance.

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
5. **Push and watch CI**: launch `scripts/poll-ci.sh <repo> <pr> <sha>` as a background
   task — it watches required checks and auto-merges on all-green with
   `--match-head-commit`. Before reading ANY check result, confirm its SHA equals the PR's
   current `headRefOid`. **Verify the poller is actually alive** (`pgrep -f poll-ci.sh`)
   after launching, and re-check each turn: a `nohup ... &` inside a backgrounded shell
   dies with its wrapper, and a poller you believe is armed but isn't leaves PRs sitting
   CLEAN and unmerged indefinitely. Polling by hand each turn beats a dead daemon.
   **A poller cannot outlive the session that launched it.** On 2026-09-17 the last
   events for #3924, #3949 and #3951 read "poller watching" at 22:32. The session then
   ended and all three sat CLEAN until someone found the dead pollers at 14:24 the next
   day: about 16 hours for three merges that needed nothing. Before a turn that may be
   the session's last, name the armed PRs and say plainly that they will NOT merge
   once the session closes, so the user can decide to keep it open or merge them by
   hand.

   **An empty OR SUSPICIOUSLY SHORT check list is a mergeability question, not a CI
   one.** A CONFLICTING PR cannot build `refs/pull/N/merge`, so every
   `pull_request`-triggered workflow silently never queues — while
   `pull_request_target` ones keep firing normally. With even one such workflow in the
   repo the PR shows exactly one check, which reads as an Actions hiccup rather than as
   zero. `gh pr view N --json mergeable` settles it in one call;
   `git merge-tree --write-tree origin/<base> HEAD` settles it with no network. The
   conflict can be trivial — two additive stanzas in `.gitignore` took a PR's required
   checks to zero while it still reported BLOCKED.

   **Read a failing check's DURATION before diagnosing it.** An infra death (missing
   runner externals, lost communication, container exec failure) fails in seconds at
   Checkout; a real scan or build takes minutes. Same check name, opposite response:
   rerun the fast one, read the findings of the slow one. Note WHICH runner it landed on —
   a single broken runner in a shared label pool fails jobs at random across every PR in
   the repo, and each casualty reads as a code failure to whoever sees the red X.

   **And read an IN_PROGRESS check's AGE.** A required check running far past its
   historical duration (~2× is the alarm line) is presumed wedged, not slow: a runner can
   accept a job and idle silently forever, and nothing turns red while it does. Compare
   the run's `createdAt` to now before assuming CI is merely busy; the remedy is
   cancel + rerun, which reschedules across runners. (2026-08-20: a Dagger run sat
   IN_PROGRESS 5 hours on a light runner while 20 heavy runners idled; the rerun landed
   on a heavy box and went green in 12 minutes.)

   **Your own re-pushes multiply CI load unless the repo cancels superseded runs.**
   Check once, early, for a `concurrency` group in the workflows
   (`grep -rn concurrency .github/workflows/`). Without one, every fix push leaves
   the previous SHA's entire job set running to completion on a commit nobody will
   merge — and a drain that pushes fixes is the worst case for this. On 2026-09-19
   a 3-runner pool had one runner burning a 13-minute `contracts` job on a SHA two
   pushes stale while the live SHA's jobs queued behind it. **After any second push
   to a PR, cancel the prior SHA's runs yourself** (`gh run cancel`), because the
   SHA-pinned merge rule already makes their results unusable to you. **`gh run
   cancel` is a GitHub mutation — never in dry-run**, where it is reported like any
   other. Recommending the `concurrency` group is a repo change and belongs in its
   own PR, not in the drain.

   **A short required job queues behind long ones in an undifferentiated pool.**
   Where every job carries the same labels, a 53-second check sits behind
   13-minute ones with no way to jump; a PR one trivial job from CLEAN can wait
   half an hour. That is saturation, not breakage — confirm by reading the job's
   `status` (`queued`, not `in_progress`) before suspecting a wedged runner, and
   do not "fix" it by re-running, which only adds load.

   **A security-scanner artifact's result COUNT is not its blocking count.** Semgrep SARIF
   keeps `nosemgrep`-suppressed findings in `runs[0].results`, annotated
   `"suppressions": [{"kind": "inSource"}]`, and excludes them from the `--error` exit
   code. Gate on the exit code, or filter out results carrying `suppressions`. (Counting
   raw results reported 3 blockers where there was 1, and produced a confident, wrong
   theory about why two working suppressions had "stopped working".)
   **And the scanner's upload error is not its failure.** A Semgrep job whose last error
   line is `Code Security must be enabled` failed EARLIER, in the scan step (exit 123 =
   blocking findings). The SARIF upload runs anyway and fails for an unrelated reason.
   On #3996 Jules read the upload error and called the red check infrastructure for four
   days while a real `unsafe-formatstring` finding sat in the report. Read the failing
   STEP's name first (`gh api .../actions/jobs/<id> --jq '.steps[] |
   select(.conclusion=="failure")'`), then the SARIF, before calling a scanner red
   "infra".
6. **Merge** happens via the poller (or manually: `gh pr merge <n> --squash
   --match-head-commit <sha>`). The SHA binding is non-negotiable: it is the only thing
   that prevents merging a head some concurrent process force-pushed under you.

## The fleet and the toolchain can fail mid-drain (each cost a round-trip)

**Never construct a SHA — read it.** A short SHA is not a prefix you can
complete. Passing a fabricated 40-char SHA to a pinned merge makes it report
`HEAD_MOVED`, which is a *lie*: the head never moved, and you will go hunting a
concurrent writer that does not exist. Read it at the moment of use —
`gh pr view <n> --json headRefOid -q .headRefOid`, or `git rev-parse HEAD` —
and pass the variable. `--oneline` output is for humans, never an input. When a
pinned tool reports HEAD_MOVED, diff the two values character by character
first: a shared prefix with a divergent tail is bad input, not a race.

**Provider billing dies without warning, and `detect_reviewers.sh` cannot see
it.** Detection probes for a key, not a balance. Mid-drain the Moonshot account
was suspended for insufficient balance (killing the `kimi` BASELINE plus
`kimi27`/`kimi3`) and the OpenRouter fallback then failed too on exhausted
credits — which takes the entire OpenRouter pool with it. Two providers left.
The tells are `<slug>.fallback.warning` and `<slug>.primary-failed.*` in the run
dir, and `failure_kind: "provider_billing"`. When it happens: keep going if the
surviving seats genuinely cover the diff, but **say the round was degraded in
the stamp** — never let a 2-of-4 round read as a full fleet — and surface the
billing failure to the user, because it blocks every future round, not just
this one.

**Flat-rate plans have usage windows, and a drain can burn through one.** On
2026-09-24, four review rounds of 200-300 KB each within about ninety minutes
exhausted the Z.ai GLM Coding plan's 5-hour window (`Usage limit reached for 5
hour`, `failure_kind: provider_error`). The shared agy quota was already gone, so
the last two rounds ran on codex alone. A single-reviewer round is still worth
posting, since it is the record, but say so in the stamp. Do not treat it as
clearance on a data-path PR. Hand those back for a full-fleet pass rather than
fixing on one opinion.

**A bare worktree has no `node_modules`, so the git hooks abort and you will
reach for `--no-verify`.** That removes the check, not the requirement. Both CI
round-trips in the 08-29 drain came from this: prettier flagged files the
pre-commit hook would have formatted, and a required interface field was missing
from web test mocks the pre-push suite would have caught. Before committing in a
worktree, run the repo's own formatter and the suites that actually cover your
edit — including the app you did NOT edit if it mocks what you changed.

**A CI red that fails in seconds at a POLICY step is not infra and not code.**
`Refuse hosted pipeline for benched agent PRs` fails in ~5s with every later
step skipped, and reads exactly like a checkout death. It means an agent PR
touches CI-privileged paths without the approval label. **Never apply that label
yourself** — the gate exists so a human reads a privileged diff, and an agent
self-approving to unblock itself defeats the control it encodes. Recovery needs
a NEW event after labeling (`git commit --allow-empty`); a plain re-run replays
the frozen payload and cannot see the label. Read the failing STEP NAME before
the duration, and the duration before the logs.

**A background chain must gate its push on the verify EXIT STATUS.** `pnpm verify |
tail | grep passed` keeps going when verify fails — one chain pushed an unverified
head on 2026-09-03 (the rerun was green, by luck). Capture `vrc=$?` from the verify
itself and `exit 1` before the push. In the same family: a wait loop of the shape
`until ! pgrep -f 'pnpm verify'` matches its OWN command line and never exits — the
chain sat wedged for 20 minutes. Wait on a lock or a file, not on a process-name grep.

**The merge-gate hook inspects your COMMAND TEXT before it runs.** A PreToolUse hook
rejects any Bash call containing `gh pr merge N` while the newest review record for N
is stale — and it evaluates the whole command string BEFORE any of it executes. So
"post the record, then merge" in ONE Bash call is refused every time: the record that
would have made it current has not been posted yet when the hook looks. Post in one
call, merge in the next. Same family: the shared main checkout blocks any command text
containing `git merge`, `git merge-tree` or `git merge-base` even behind a `cd` — run
those as `git -C <your-worktree> …`.

**The author can merge a PR out from under your fix.** #3687 merged (by Gabriel, at the
reviewed head) while its pass-2 fixes were being written on its branch. The push then
landed on a branch whose PR was closed, and a `cherry-pick` onto develop from that
branch produced NOTHING — silently, because the branch was behind develop and the
pick resolved to an empty commit. Before pushing a fix, re-read `gh pr view N --json
state`; if MERGED, branch from `origin/develop`, apply the change as a `git diff
<old> <new> -- <paths> | git apply` (not a cherry-pick of a commit whose parent is
stale), and open a follow-up PR that says `Refs #N` and why. Check the remote ref
after every push (`git ls-remote`) — a pre-push hook refusal prints in the same
place as success.

**`GOOGLE_APPLICATION_CREDENTIALS` pins a service account over the user's ADC.** A
`tofu init` 403 naming `claude-dev-automation@…` on a bucket the user can read is that
env var, not a missing login. `env -u GOOGLE_APPLICATION_CREDENTIALS tofu …` uses the
`authorized_user` ADC file; check `${GOOGLE_APPLICATION_CREDENTIALS:-unset}` before
asking anyone to log in. And when a plan is supposed to be "just one output", read
the `Plan: N to add` line before applying — the bootstrap plan carried a WIF provider
develop had declared but never applied, and that needed its own approval.

**`${var:-default}` is not "default when unset".** It also fires on an explicitly EMPTY
value, so a test that sets `AGENT_AUTHORS=""` to mean "no agent authors" silently got
the default back. `${var-default}` is the unset-only form. The pre-push suite caught
it; the first push did not reach the remote.

## Pipelining (depth 2, no deeper)

**Pass N of a review round reviews the delta since the last reviewed head — unless you
merged develop in between.** Then the merge-base of the old head and the new fix is the
old head, and the diff carries every develop commit: on 2026-09-03 a pass-4 round
shipped 7,688 lines to kimi (50-minute budget) and gemini-pro reviewed develop's
contrast test instead of the fix. Use the MERGE COMMIT as `--base`, and read
`size_lines` from `worktree.sh` before dispatching — a pass-N diff an order of
magnitude larger than the fix commit is a wrong base, and the round should be killed,
not read.

**Measured 2026-09-03:** review rounds were the drum-beat again — ~10 minutes each,
eight rounds on each of two PRs, while 33 heavy runners sat idle. OpenRouter credits
were exhausted from the first round, so every rotation seat failed with
`provider_billing` and rounds ran on codex, kimi and the Gemini laps (2-3 seats). Say
the seat count in every stamp; a two-seat round is not a fleet.

Whichever of CI and the review round is currently waiting is your dead time — fill it
with the other lane's work on the next PR. Mechanical work (a conflict rebase, a
stale-base develop merge) slots into review waits especially well — it needs neither
lock. Do NOT go depth 3: a third lane just queues behind the locks and burns quota.

**MEASURE the drum-beat before assuming it.** Which lane gates throughput is a property
of the fleet that night, not a constant, and guessing wrong wastes the whole drain's
pipelining. Two commands settle it:

    gh api orgs/<org>/actions/runners --jq '.runners[] | "\(.name) busy=\(.busy) [\([.labels[].name]|join(","))]"'
    gh run list --limit 30 --json status,name -q '[.[]|select(.status=="queued" or .status=="in_progress")]|length'

If the heavy/required-check label resolves to ONE non-busy-capable runner, CI is the
drum-beat and no amount of review pipelining helps — run reviews far ahead instead, so a
freed CI slot always meets an already-stamped PR. (2026-08-16: a 12-PR drain assumed
reviews were the constraint because "PRs that sat open arrive green". All 12 arrived with
`cross-review/current` RED, and once stamped, throughput was ~1 PR/hour behind a single
`heavy`-labeled runner doing 56-minute Dagger runs — one PR waited 76 min for a slot.)

**The drum-beat can become YOU.** Measured on 2026-08-29: review currency
gated the first half exactly as the dry-run predicted, with 30+ runners idle
and CI hidden inside review waits. The second half was gated by self-inflicted
CI round-trips — two full ~8-minute Dagger cycles burned on a prettier failure
and a stale test mock, both of which the git hooks I bypassed would have
caught. A round-trip you cause costs the same wall-clock as one you wait for,
and unlike a queued runner it does not clear on its own. Budget the formatter
and the covering suites into the fix step, not into CI.

- Merges stay strictly serial and in checklist order.
- **Overlapping-surface PRs stay serial relative to each other**: before pipelining N+1,
  check `gh pr view --json files` overlap with N. If they touch the same files, hold N+1
  until N merges (its review would be against a base about to move).
- When N merges, the base advances under N+1. Don't auto-rebase; re-check before
  finalizing: if a reviewer flags a "deletion you didn't make", suspect stale base, not
  your diff — and check overlap with the PR you just merged before trusting any finding
  about a file both touch.
- **Diff against the MERGE-BASE, never two-dot `git diff origin/<base>`.** A branch a few
  commits behind shows the base's own advances as deletions in your PR. Observed at 84
  files / 5028 deletions where the true diff was 19 files / 1979 insertions / 0
  deletions. Confirm with `git merge-tree --write-tree` before believing a revert
  finding, and dispatch reviewers against the merge-base so the fleet can't repeat it.

## Safety invariants (each one paid for by a real incident)

1. **No git mutation in the user's main checkout, ever.** All branch work happens in
   dedicated worktrees. Shared checkouts get their HEAD moved by concurrent sessions;
   commits land on the wrong branch and force-pushes can drop other people's work.
   **A worktree you did not create is presumed CONTESTED.** Finding one already checked
   out at the PR's head SHA is not luck — it usually means another session is mid-task in
   it. Before adopting any worktree, probe it: `git status --porcelain` (dirty?), mtime of
   the dirty files (written in the last minutes?), `git rev-list --count origin/<br>..HEAD`
   (unpushed commits?). Every fixer's step 0 must re-assert HEAD == expected SHA and a
   clean tree, and ABORT rather than edit. Re-verify each PR's `headRefOid` against GitHub
   every iteration; never trust a local SHA you read earlier.
   (2026-08-16: 8 concurrent sessions in one repo; 11 of 12 worktrees were already
   checked out at the right SHAs, one was being written 6 seconds before the fixer looked,
   and 3 PR heads moved mid-drain. The step-0 check is the only thing that prevented a
   race.)
1b. **Create every worktree with `--detach <sha>`, never by branch name.** A local
   branch sharing the PR's name can be stale — `git worktree add <wt> <branch>`
   then checks out that stale ref, and step 0's SHA assertion reports a MISMATCH
   that reads exactly like "the head moved under me". On 2026-09-19 a local
   `worktree-worktree-issue-212-pdf-inspector` sat 3 commits behind the PR head
   and nearly sent the drain hunting a concurrent writer that did not exist. The
   PR's `headRefOid` is the only ref that means anything; `git fetch` then
   `git worktree add --detach <that sha>`. When a SHA assertion fails, check
   whether the LOCAL ref is stale before concluding anything about the remote.

2. **Force-pushes use `--force-with-lease=<branch>:<expected-sha>`**, and before any
   force-push, diff the old and new commit lists (`git log --oneline old..new` + patch-id
   compare). A replay that emits fewer commits than it consumed dropped work — the lease
   will NOT catch that. If a force-push would drop commits: STOP, tag the old head
   (`git tag salvage/...`), and hand it to the user.
3. **Never claim green against a stale SHA.** Every check result, every merge, every
   "done" is verified against the current `headRefOid` at that moment.
   **And never hand-type a SHA.** Twice in one drain (2026-08-19) a stamp was posted
   against a 40-char SHA whose tail the orchestrator had confabulated from a 9-char
   display prefix — the currency gate caught both as impossible self-mismatches
   ("reviewed X, head is X"). A SHA in a command must be pasted from a tool result in
   the same turn (`headRefOid`, `context.json`, `git rev-parse`), never recalled.
3b. **A live-agent PR is contested until its authoring session is dead — and maybe
   after.** Jules' CI Fixer blind-reverted a review fix ("trigger CI") when its PR
   went red, and pushed the same re-add AGAIN after its session was archived. Rule:
   archive the session BEFORE the first fix push; if the head still moves under you
   after that, do not loop — either accept the bot's head when the delta is trivial
   and fully read (re-stamp it, let the SHA-pinned merge race the bot), or block the
   PR for a human. Two pushes by you against the same bot = you are the loop.
3c. **cwd does not survive between orchestrator tool calls.** A `cd <worktree>` in
   one Bash call is gone in the next; one drain contaminated the main checkout with
   a `git checkout -- <file>` and verified claims against the wrong tree because of
   this. Every git/test command in worktree work carries `git -C <wt>` or an
   absolute path — a bare command that "should" run in the worktree is a bug.
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
- **A station agent that stalls twice on the same task gets taken over inline.** On the
  first stall (stream watchdog, no progress), snapshot the worktree state (`git status
  --porcelain`, HEAD SHA, held locks) and resume the agent WITH that snapshot so it
  can't re-do or double-apply work. On the second stall, stop resuming: do the task
  inline — the third resume costs more wall-clock than the fix itself, and the recorded
  worktree state makes an inline takeover safe. (2026-08-20: fixer stalled 3× on one
  PR; the inline takeover shipped in ~25 min while three resume cycles had burned ~35.)

## Write-back (mandatory per iteration — an untracked iteration is a lost one)

- **Merged**: tick the PR's line in the checklist issue (`- [ ]` → `- [x]`), append a
  `MERGED` event. Nothing else changes in the issue.
- **Blocked**: create a `pr-drain`-labeled issue (what was tried, exact failing check +
  SHA, smallest next action), append ` — blocked by #<new>` to the PR's line, label the
  PR `needs-human`, append a `BLOCKED` event. When the blocker is an already-open PR or
  issue, reference that instead of filing a redundant one.
- Working notes → PR comments.

**A blocked line has no wake signal, so a resume starts by re-probing every blocker.**
#3983 was blocked on a human applying `agent-ci-approved`. The human applied it and
Dagger went green on 2026-09-20 at 14:12, then the PR sat mergeable for 3.6 days
because nothing watches for a label. On resume, before touching any unticked
unblocked line, re-read each BLOCKED line's PR (`labels`, `mergeStateStatus`, required
checks and review currency at the current head). The human may have acted days ago.
When you block a PR on a human action, the PR comment should also say that the drain
will not notice the action by itself.

**Editing the checklist body is a read-modify-write on a document another session may
be editing too, and the race's failure mode is a blank issue, not a conflict.** On
2026-09-04 a tick script asserted its line was still unticked (a peer had ticked it 13
seconds earlier), the `$(...)` assignment came back empty, `set -e` did not fire, and
`gh issue edit --body "$new"` replaced an 11 KB body with nothing. Write the new body
to a file, `test -s` it and check its line count against the original, then pass
`--body-file`. Never tick a line another session owns; tell them and wait. If a body
is ever blank, GraphQL `userContentEdits(first:N).nodes[].diff` holds the last good
version (`first` is newest; `last` is the OLDEST edits).

**Check every queued PR for an EMPTY diff before reviewing it, and defuse its auto-close
reference.** `gh pr view <n> --json changedFiles,additions,deletions` plus a tree
comparison (`git rev-parse <sha>^{tree}` vs `<sha>^^{tree}` — identical trees prove an
empty commit) settles it in one call. An agent-authored PR can claim implemented work,
green tests, and `Closes #N` while containing zero commits of content; its checks all pass
*vacuously* because every one is exercising the base branch. Merging it closes a live
requirement and delivers nothing, and the next person finds a closed issue and assumes the
work is done.

Do not merge it, and do not silently close it either — closing someone's PR is the user's
call. Instead: rewrite the body's closing keyword to a plain reference (`Closes #N` →
`Refs #N`), label `needs-human`, annotate the checklist line, and surface it. **Sweep the
whole queue for closing keywords once, up front** — one `gh pr view --json body` per PR.
And when you write the explanatory note, do not restate the literal keyword in it: writing
"the original `Closes #N` was changed" re-arms the parser you just disarmed. Grep the
final body to confirm zero closing keywords remain rather than trusting the edit.
**Check first whether the repo re-arms the keyword itself.** kindred-mama-ai's
`pr-issue-autoclose` workflow prepends `Closes #N` to any `agent/issue-<N>-*` PR, taking
N from the branch name, and your body edit is the event that triggers it. The keyword is
back seconds later, after your grep has passed. There, the defusal is not merging: label
`needs-human` and say in the PR comment that a merge closes #N (#3998, 2026-09-24).

**The same up-front sweep catches the opposite case: a NET-DESTRUCTIVE diff.** Jules'
#3984 (`+632/−9778`, 130 files) claimed to "extract" a primitive. Its branch deleted
tests, docs and 250 lines of `dagger.yml` that had landed on develop through the
stacked PR #3982 while #3984 was open. A PR whose deletions dwarf its additions, and
which does not say it removes anything, gets one check before any review:
`git ls-tree --name-only <merge-base> <paths>` against `<head>` and `origin/<base>`.
Files present at the merge-base and on the base but missing at the head mean merging
reverts landed work. Block it the same way as an empty diff (`needs-human`, a PR
comment with the evidence, never a silent close). Its red CI is a symptom here. Do
not start a fix loop on it.

**And a CLAIM/DIFF MISMATCH: the body describes work the diff does not contain.** On
2026-09-24 four of ten queued agent PRs did less than they said:
- #3998 described edits to `agentReason.ts`, `utils.ts` and `promptBuilder.ts` and
  contained only test-mock changes.
- #3997 was "calibrated rubric scores", which its issue defines as a Jev swap, and
  delivered prompt anchor text.
- #3989 and #3996 shipped features that could not run: flags that were never
  registered, and lookups by hashed ids.

All four had green CI, and two carried CLEAN review stamps. A diff can be fine on
its own terms and still not be the PR. Two cheap checks before any review:
1. Diff the file paths the body names against `gh pr view <n> --json files`. A named
   file missing from the diff is a stop.
2. Read the linked issue's acceptance criteria against the diff. On
   `agent/issue-<N>-*` branches a merge closes #N no matter what the body says,
   because the repo re-arms the keyword. So whether the PR delivers #N is a merge
   question, not a review nicety.

## Stop conditions (comment the reason on the checklist issue, then stop)

- 3 consecutive iterations with no merge.
- Any force-push that would drop commits.
- CI red on 3+ different PRs → infra problem, not code.
- Same PR fails the same check twice (honoring invariant 5's attribution rule).
- **A round's P1s are mirror images of P1s you applied earlier on the same PR** — the
  defect class is open-ended (regex over English noun phrases, idioms, speech frames)
  and another list will not close it. Post the residual list on the PR with a
  structural recommendation and hand off. Declare the hand-off pass number in advance
  and HOLD it: on 2026-09-03 the drain declared pass 6 for #3362 and ran to pass 8,
  each round's fixes seeding the next round's findings. Contrast #3734 the same day,
  where each of eight rounds closed a real structural gap in an AST walker and the
  eighth came back clean — same round count, opposite signal; the test is whether the
  fixes are inversions of each other, not how many rounds there were.
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
diffs); every GITHUB mutation (push, merge, issue edit, comment, label, review dispatch,
**run cancel**) is printed as `DRY-RUN: would <command>` instead of executed. Local state still writes:
the event log and claims ledger are the dry-run's own deliverables, not mutations. The deliverable is a per-PR
plan: current state, what step it's at, what would happen next, and expected wall time.
`poll-ci.sh` honors the same variable (reports instead of merging).
