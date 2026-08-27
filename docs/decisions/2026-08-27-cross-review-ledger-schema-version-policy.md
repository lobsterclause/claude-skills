# Decision: cross-review ledger `schema_version` bump policy

**Date:** 2026-08-27 · **Status:** accepted · **Tracks:** #112, #109

## Context

`runlog.jsonl` and `finding_events.jsonl` stay append-only JSONL (see
[2026-08-26-cross-review-ledgers-stay-jsonl.md](2026-08-26-cross-review-ledgers-stay-jsonl.md)).
Both writers (`append_runlog.sh`, `append_finding_event.sh`) now stamp every
new entry with an integer `schema_version` (#109). `validate_ledgers.sh`
already reports the version distribution per ledger (#96). What was missing
was a rule for *when* the number moves, so a future contributor doesn't have
to guess whether adding a field warrants a bump, and so readers know what
"version 2" is allowed to assume.

## Decision

1. `schema_version` is an integer field on every entry in both ledgers.
   **Absence means version 0** — every entry written before #109 shipped.
2. The version bumps **only for a breaking change**: a renamed or removed
   field, a changed meaning or unit for an existing field (e.g. seconds →
   milliseconds), or a changed key structure (e.g. a field that was a scalar
   becoming an object). Anything a reader can safely ignore if absent is not
   breaking. The one deliberate exception is version 1 itself: stamping the
   field for the first time is what creates the baseline that later bumps are
   measured from, so it increments from 0 to 1 without being a breaking change.
3. **Additive fields never bump the version.** A new optional field — another
   lifecycle event type, another meta.json passthrough, another cost
   breakdown — ships at the current version. This is the common case and is
   deliberately cheap.
4. **Readers must accept every version ≤ the current constant**, and must
   treat a missing `schema_version` as version 0, not as an error. The
   current readers of these ledgers, all of which this rule binds:
   - `analyze_runlog.sh`
   - `leaderboard.sh`
   - `select_roster.sh`
   - `audit_roster.sh`
   - `severity_calibration.sh`
   - `validate_ledgers.sh`
   - `import_runlog.sh`
5. **Old entries are never migrated in place.** The ledgers are event-sourced
   and append-only (see the linked decision) — a migration script that
   rewrites history would defeat that property and break the idempotent-merge
   guarantee `import_runlog.sh` relies on. A version bump instead requires a
   **reader-side shim**: the reader branches on `schema_version` (treating
   absence as 0) and interprets old and new shapes side by side, for as long
   as any reader might still see old-shaped entries. Versions coexist; they
   are not converted.
6. `validate_ledgers.sh` reports the version distribution per ledger (already
   shipped) and WARNs when it sees a version **above** the writer's current
   `SCHEMA_VERSION` constant — that shape means an entry was written by a
   newer writer than the one validating, which is worth a human's attention
   even though it isn't an ERROR.
7. The constant lives in each **writer**, named `SCHEMA_VERSION`, not in a
   shared config file — each ledger has its own version line, since a bump to
   one (say, a runlog field) has no reason to force a bump to the other. This
   policy doc is the log of what justified each bump:

   | version | date       | change                                    |
   |---------|------------|--------------------------------------------|
   | 1       | 2026-08-27 | First stamped version (#109) — both writers begin emitting `schema_version` on every new entry. Not a breaking change in itself; entries with no `schema_version` (version 0) remain valid and keep being written by any not-yet-updated writer. |

## Consequences

- Every future PR that changes a ledger field's *meaning* (not just adds one)
  must (a) bump the relevant writer's `SCHEMA_VERSION`, (b) add a row to the
  table above naming the PR/issue, and (c) add or update the reader-side shim
  in every reader listed above that touches the changed field — not just the
  one the author happened to be looking at.
- A reviewer of such a PR should treat a `SCHEMA_VERSION` bump with no shim
  update in the listed readers as incomplete, the same way a migration
  without a corresponding backfill would be.
- `validate_ledgers.sh`'s WARN-on-future-version check (point 6) is not yet
  implemented as of this doc — today it reports the distribution only. Filed
  as a follow-up rather than added here, since `scripts/validate_ledgers.sh`
  is owned by a sibling change in flight.
- Trigger for revisiting: a second ledger field needing a genuinely breaking
  change before the first reader-side shim has ever been exercised in
  practice — at that point, reconsider whether per-field versioning (instead
  of one counter per ledger) is warranted.
