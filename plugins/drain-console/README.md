# drain-console

A Claude Code mod for watching an issue-drain run while it works (issue-drain itself now lives in a private repository). It reads the run folder (`~/.issue-drain/<owner>__<repo>/<run id>/`) on a timer and shows:

- **A pane** with the run's repo and id, the tracker link, and one row per unit: its state, how long since it last moved, its PR, the merge gate's last refusals, the note from a park or block, and its cost. Cost is summed from `units/<n>/session.json` and is an estimate, not a bill.
- **A status line entry**, e.g. `drain 4/12 · U5 #4711 ci_wait 3m`. It clears when the run has been quiet for six hours.
- **A toast and a desktop notification** when a unit merges, blocks or parks, and when the drain stops or finishes.
- **`/drain`**, which prints the same summary as text without starting a model turn.
- **A "Stop after this unit" button** (also `/drain stop`), which writes `STOP` into the run folder. The driver finishes the unit it is on and stops before it claims the next one.

The console never merges, never writes to GitHub and never changes `state.json`. The STOP file is the only thing it writes.

## Install

```
/plugin install drain-console --marketplace lobsterclause/claude-skills
```

## Which run it watches

1. The `run_dir` setting, if set.
2. Otherwise a folder picked with `/drain <run folder>`. It is remembered across sessions; `/drain auto` forgets it.
3. Otherwise the run under `~/.issue-drain` whose `state.json` changed last.

The pane opens on its own at session start when that run is active and unfinished. `/drain pane` opens it at any time.

## Settings

| Setting | Default | |
|---|---|---|
| `run_dir` | empty | Pin one run folder. `~` is expanded. |
| `poll_seconds` | 15 | How often to read the run. Values under 5 use 15. |
| `summarise_on_stop` | off | When a unit blocks or parks, or the drain stops or finishes, submit a prompt asking Claude to read the run and propose the next move. The prompt names units and states only, never a note or a stop reason (a unit can write those), and tells Claude to change nothing. It is off by default because it starts a model turn. |

## Where it stays quiet

It does nothing in a non-interactive session, or in a unit process (`ISSUE_DRAIN_MODE=unit`, or `ISSUE_DRAIN_UNIT_FILE` set), so the agents the driver starts never see it.

## Resuming after a stop

The driver records the stop in the state log and does not delete `STOP`. To resume, delete `<run folder>/STOP`, run `issue-drain state resume`, then `drive` again.

## Development

```
claude plugin validate plugins/drain-console
claude plugin test plugins/drain-console
```

`hooks/model.ts` holds the parsing and the text, with no engine calls, and `tests/model.test.ts` covers it. `hooks/register.tsx` holds the hooks, and `tests/register.test.tsx` drives them against an in-memory run folder.
