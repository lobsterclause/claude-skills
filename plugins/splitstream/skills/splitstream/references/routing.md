# Routing and wave planning

## Model selection

Use the least expensive model that can safely complete the bounded shard, but default to Sonnet when uncertain.

| Model | Use when | Avoid when |
|---|---|---|
| Haiku | Exact, low-risk, mechanical, usually single-file; the desired edit and proof are already obvious | Debugging, ambiguous requirements, multi-file behavior, migrations, security, concurrency |
| Sonnet | Normal implementation, debugging, tests, refactors, and bounded multi-file work | The shard depends on unresolved architecture or unusually high-stakes judgment |
| Opus | Rare, judgment-heavy or high-risk work after scope is understood; architectural investigation that cannot be made mechanical | Routine changes or “just in case” escalation |

Do not route by file count alone. Risk, ambiguity, reversibility, and proof quality matter more.

## Risk levels

- `low`: local and reversible, no sensitive boundary, strong deterministic proof.
- `normal`: standard application change with bounded blast radius.
- `high`: auth, permissions, money, destructive migrations, production infrastructure, cryptography, privacy, or broad public API behavior. High-risk shards need an especially narrow scope and independent human attention even after verification.

## Waves

Two shards conflict when their declared scopes can address the same path. Conflicting shards must be placed in different waves. Also separate shards when one semantically depends on another even if paths do not overlap.

Prefer a small directed acyclic plan:

1. foundational/schema changes;
2. independent implementations;
3. integration/docs generated from earlier work.

The helper calculates conservative path-conflict waves. The planner remains responsible for semantic dependencies and may move a shard to a later wave, never an earlier conflicting one.

Split a task only when each shard has an independently reviewable result. Do not split one tightly coupled change merely to increase agent count.
