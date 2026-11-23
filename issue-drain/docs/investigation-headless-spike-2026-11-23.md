# Headless unit spike, 2026-11-23

PR3b step 0 from the plan: one `claude -p` in a scratch kindred-mama-ai worktree, to settle the risks the driver depends on before any of it is written. Nothing in the spike wrote to GitHub.

## Setup

- Worktree: detached checkout of `origin/develop` (7d22ba0) on a local branch `spike/issue-drain-headless`, bootstrapped with kma's `.claude/scripts/worktree-bootstrap.sh`.
- Claude Code 2.1.322, sonnet at medium effort, 45-minute wall clock (`timeout 2700`). Runs are on the subscription, so no `--max-budget-usd`.
- Flags: `--permission-mode acceptEdits --permission-prompts none`, `--allowedTools Bash Read Edit Write Grep Glob Agent ToolSearch mcp__codegraph__codegraph_explore`, `--plugin-dir issue-drain/guards`, `--output-format stream-json --verbose`.
- Environment: `VERIFY_GATE_SKIP=1`, `CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS=0`, `ISSUE_DRAIN_MODE=unit`, `ISSUE_DRAIN_UNIT_FILE=<unit.json>`.

The run took 10 minutes and exited 0. The reported API-equivalent cost was $0.39.

## Results by risk

| Risk | Result | What the driver does with it |
|---|---|---|
| 1. Background waits in a headless run | Settled, with one limit. The run stayed open through two background commands and read both results. A background Bash command is still killed at the tool's own 600 s default: `sleep 660` died at 10 minutes. The codex review (`run_reviewers.sh --reviewers codex`) finished in 21 s with 16 KB of output | The unit brief tells the model to pass an explicit `timeout` (up to 7,200,000 ms) on any background command that can run past 10 minutes, the CI wait and a full review round included |
| 2. Permission flags | Settled. `acceptEdits` with an allow list and `--permission-prompts none` lost no tool calls. The only refusals were the two the spike asked for | Use these flags for units. Auto mode was not needed |
| 3. Global Stop hook | Settled. `~/.claude/hooks/verify-gate.sh` now exits at once when `VERIFY_GATE_SKIP=1` (added 2026-11-23 with the owner's go). The child's Stop at the end of the run left no line in the gate log | The driver sets `VERIFY_GATE_SKIP=1` on every unit process. The orchestrating session must not use a unit worktree as its working directory: its own Stop hook fired twice there (both aborted on a stray bootstrap link before running anything) |
| 4. `--resume` with a different `--model` | Settled. `--resume <id> --model haiku --effort low` kept the session id, ran as `claude-haiku-5-5` and edited the result file | Repair rounds resume the unit session and step the model up or down as planned |
| 5. Guards from `--plugin-dir` in a headless run | Settled. The marker was written at session start. An Agent call without model and effort was refused, and so was `gh pr merge 999999` | As designed. A unit with no marker is not merged |
| 6. A separate unit token | Not tested | Waits for the owner's choice of identity before the first unattended run |
| 7. CodeGraph in a fresh worktree | Settled: it does not answer. The tool loaded and returned "isn't indexed (no .codegraph/ directory)" | The implementer brief names Grep and LSP for finding callers and reusable code, and says not to ask about indexing |

## Other things seen

- kma's pre-commit hook (lint-staged, secrets scan) ran and passed in the bootstrapped worktree. The bootstrap is required: without `node_modules` the commit would fail, and the guards refuse `--no-verify`.
- The bootstrap left `functions/node_modules/node_modules` pointing at the main checkout. kma's `verify.sh` refuses that link, so a homelab verify of a unit worktree must run `pnpm install` first (`remote-verify.sh` already does) and a local verify would abort.
- The Explore subagent ran asynchronously and the parent waited for it without being told to.
- A PostToolUse formatter hook from the user's settings rewrote a JSON file the child edited. User-level hooks other than the Stop gate do run in unit processes.
