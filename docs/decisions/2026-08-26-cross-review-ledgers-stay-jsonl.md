# Decision: the cross-review ledgers stay append-only JSONL — no graph store

**Date:** 2026-08-26 · **Status:** accepted · **Tracks:** #98

## Context

While designing the telemetry follow-ups (#88–#97) the question came up: should
`runlog.jsonl` and `finding_events.jsonl` move into a graph store (Graphiti /
Neo4j) or a database?

Facts that decided it:

- The data is already **typed and keyed**. Runlog entries key on `run_id`;
  events key on `finding_id` + `run_id`; the join between them is one field.
- Both files are **append-only** and event-sourced. Corrections are made by
  appending a superseding event, never by editing a line. That property is what
  makes `import_runlog.sh` an idempotent merge and lets the installed copy and
  the repo copy reconcile.
- Size is ~4.4 MB total. Every current reader (`analyze_runlog.sh`,
  `leaderboard.sh`, `select_roster.sh`) folds the whole file with `jq` in well
  under a second.
- The skill's operating contract is **bash + jq, offline, runs in CI**
  (`tests/run_tests.sh` is a fixture suite with no network). A store with a
  daemon, or with an LLM in the write path, ends that.

## Decision

1. `runlog.jsonl` and `finding_events.jsonl` remain the source of truth, as
   append-only JSONL. New telemetry (lifecycle events, `schema_version`,
   `context_mode`, cost, timings) is added as **fields and event types**, not as
   a new store.
2. No graph database. A graph store would rediscover, via an extraction model,
   relationships we already wrote down explicitly.
3. If ad-hoc querying ever becomes painful — multi-way joins, window functions
   over time — the pre-agreed next step is a **derived** SQLite (or DuckDB) file
   built by a `scripts/build_ledger_db.sh` with `runs`, `reviewer_runs`, and
   `events` tables. Derived means: rebuilt from the JSONL on demand, never
   written to directly, safe to delete.
4. The one graph-shaped idea worth keeping is linking anchored findings to
   CodeGraph symbols for a structural severity signal ("this Low sits in a
   function with 40 callers"). That is a feature *on* the ledger, not a change
   *to* it, and is tracked separately if it becomes real.

## Consequences

- Readers must keep treating a missing field as "older era" (see
  `schema_version`, #96) rather than assuming a migration ran.
- Corrections to bad data are appended, never rewritten in place — including
  the one known malformed runlog line.
- Trigger for revisiting: a concrete query that jq makes painful, written down
  in #98 first.
