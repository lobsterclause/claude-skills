# Station agent prompts

Spawn each station ONCE with a name (`drain-reviewer`, `drain-fixer`), then continue it
via `SendMessage({to: "<name>", message: ...})` for each subsequent PR. Continuation
preserves the station's accumulated context — the reviewer's refutation library and the
fixer's knowledge of the repo's verify quirks are most of the value.

Both prompts open with the worktree-isolation block. It exists because worktree agents
have repeatedly cd'd into the shared main checkout "for convenience" and contaminated
sibling branches. Never include the main checkout's absolute path anywhere in a station
prompt — even naming it as forbidden invites visiting it.

## Shared preamble (paste at the top of both spawn prompts)

```
CRITICAL — WORKTREE ISOLATION RULES
- You work ONLY inside the worktree path given per task. NEVER cd outside it.
- All git, package-manager, and test commands run from inside that worktree.
- Before any push: run `pwd` and confirm you are inside the worktree; run
  `git diff <base> --stat` and confirm the diff touches only files relevant to
  the assigned PR. If either check fails: STOP and report, do not push.
- Never run bare `git stash`/`git stash pop` (shared stash stack across worktrees).
- If files you did not edit change under you, or your intended fix is already at
  HEAD: STOP, snapshot (`git diff > <scratch>/race-<pr>.diff`), report back.
When you finish a task, SendMessage the orchestrator with a structured result;
your final text is data for the orchestrator, not prose for a human.
```

## drain-reviewer spawn prompt

```
<shared preamble>

You are the review station of a PR-drain pipeline. Per task you receive:
{pr, worktree, base_sha, head_sha, repo}.

Job per task:
1. Run the repo's cross-review flow against the PR's diff from the given worktree
   (acquire the `review` lock first: scripts/lock.sh acquire review; release when done).
2. Triage every finding into:
   - APPLY (P0/P1, concrete, in-diff)
   - REFUTE (claim is testable and false — include the one-liner you ran that disproves
     it; reviewer consensus is not correctness in either direction)
   - OUT-OF-DIFF (real but pre-existing → orchestrator files a follow-up issue)
3. Post the stamped review record on the PR bound to head_sha.
4. Reply: {pr, verdict: CLEAN|FINDINGS, apply: [...], refuted: [...], out_of_diff: [...],
   stamped_sha}.

Keep a running refutation library across tasks: when a reviewer repeats a claim you have
already disproven, cite the prior disproof instead of re-testing.
```

## drain-fixer spawn prompt

```
<shared preamble>

You are the fix/verify station of a PR-drain pipeline. Per task you receive:
{pr, worktree, branch, findings: [...], expected_head_sha, repo}.

Job per task:
1. Confirm the worktree HEAD equals expected_head_sha; abort and report if not.
2. Apply each finding as a minimal, test-backed change. For behavior fixes, write the
   failing test FIRST and watch it fail (a fix without a red test proves nothing).
3. Acquire the `verify` lock, run the repo's verify entrypoint green, release the lock.
   Fresh worktrees are cold-cache: budget 3-4x warm time, and rebuild shared packages
   first if the repo's docs say typecheck lies against a stale build.
4. Push with `--force-with-lease=<branch>:<expected_head_sha>` if history was rewritten,
   plain push otherwise. Never push on a red verify.
5. Reply: {pr, pushed_sha, verify: green|red, commits: [...], notes}.
```

## Dispatch pattern (orchestrator side)

```
Agent(name: "drain-reviewer", prompt: <spawn prompt>, run_in_background: true)
...later, per PR:
SendMessage(to: "drain-reviewer", message: '{"pr": 3400, "worktree": "...", ...}')
```

After any compaction, run ListAgents to rediscover live stations before spawning
duplicates. If a station died, respawn it with the same name; the refutation library is
lost but the protocol is unchanged.
