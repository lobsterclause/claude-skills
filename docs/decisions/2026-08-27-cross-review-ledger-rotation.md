# Decision: cross-review ledger rotation policy

**Date:** 2026-08-27 · **Status:** accepted · **Tracks:** #96, #109, #120

## Context

`runlog.jsonl` and `finding_events.jsonl` remain append-only JSONL (see
[2026-08-26-cross-review-ledgers-stay-jsonl.md](2026-08-26-cross-review-ledgers-stay-jsonl.md)).
That decision noted the ledgers are ~4.4 MB total and every reader folds the
whole file with `jq` in well under a second. #96 item 4 asked for a written
rotation policy so growth doesn't silently degrade `import_runlog.sh`'s merge
or every reader's fold, and so a future contributor isn't left guessing at
what "too big" means or how an archive would be laid out. As of this doc the
ledgers are still ~4-5 MB combined — this is a policy for the future, not a
response to a present problem.

## Decision

1. **No rotation until a size or latency trigger fires.** Specifically:
   - a ledger file (`runlog.jsonl` or `finding_events.jsonl`) exceeds
     **50 MB**, or
   - `import_runlog.sh`'s merge step exceeds **5 seconds** wall-clock on a
     normal contributor machine (not CI-constrained hardware).

   Either trigger, independently, is sufficient to start rotation work. Until
   one fires, the ledgers keep growing untouched — no scheduled rotation, no
   pre-emptive archiving "just in case."

2. **When a trigger fires, archive by year, not by size.** Entries older than
   **12 months** (relative to the newest entry's `ts` at archive time) move
   out of the live file into a sibling archive file named
   `runlog.YYYY.jsonl` / `finding_events.YYYY.jsonl`, placed beside the live
   file, one file per calendar year of entries. A future
   `scripts/rotate_ledgers.sh` performs this split; **it is not built by this
   decision** — this doc only fixes the trigger and the shape it must
   produce, so the eventual implementation isn't designed twice.

3. **Readers default to the live file only.** Every current reader
   (`analyze_runlog.sh`, `leaderboard.sh`, `select_roster.sh`,
   `audit_roster.sh`, `severity_calibration.sh`, `validate_ledgers.sh`) keeps
   reading only `runlog.jsonl` / `finding_events.jsonl` by default once
   rotation exists — no reader silently starts folding archive years into its
   normal run. A reader that wants archived history opts in explicitly via an
   `--include-archives` flag, which globs in the sibling `*.YYYY.jsonl` files
   alongside the live one.

4. **`import_runlog.sh` must accept both shapes.** Its idempotent merge
   (keyed on `run_id` / `finding_id`+`run_id`, per the append-only decision)
   has to work whether the target skill install has already rotated (live +
   archive files present) or hasn't (one flat file) — a source repo on one
   side of a rotation and an installed copy on the other must still merge
   cleanly. This is a correctness requirement on the future
   `rotate_ledgers.sh` and on `import_runlog.sh`'s own logic, not just a nice
   property.

5. **Archived years are never rewritten.** Once entries move into
   `runlog.2026.jsonl`, that file is closed history — same append-only,
   never-edit-in-place property the live ledger already has (see the linked
   decision). A correction is appended to the *live* file as a new event,
   never patched into an archive year.

## Consequences

- Nothing changes today. This doc exists so that when the 50 MB / 5s trigger
  does fire, the shape of the fix is already agreed and the work is "build
  `rotate_ledgers.sh` to spec" rather than "design a rotation scheme under
  time pressure while the merge is already slow."
- Building `rotate_ledgers.sh` and wiring `--include-archives` into each
  reader is out of scope for this decision and is tracked as a follow-up
  (filed separately) rather than spun up speculatively here.
- A reader that is added after this doc lands inherits the same "live file
  only by default" contract — a PR adding a new ledger reader should link
  back here rather than re-deciding default scope.
- Trigger for revisiting: either size trigger firing before
  `rotate_ledgers.sh` exists, or a contributor finding a case where
  `import_runlog.sh` can't cleanly merge across a rotated/unrotated split —
  at that point the 12-month window or the per-year granularity should be
  reconsidered against real data instead of the estimate above.
