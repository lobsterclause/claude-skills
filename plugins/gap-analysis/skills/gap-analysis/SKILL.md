---
name: gap-analysis
description: "Cross-reference design docs (specs, ADRs, plans), codebase, and PM state (ClickUp via MCP, GitHub issues) to find every gap — unbuilt features, ghost closures, untracked code, stale tickets, spec drift. Produces a dispatch manifest where each gap is a task block Opus hands to Haiku/Sonnet subagents to close, with files to read, numbered steps, and self-checkable acceptance criteria. Trigger on: gap analysis, implementation audit, ticket reconciliation, 'what's missing', 'where do we stand', 'what did we miss', compare planned vs built, reconcile tickets with code, detect ghost closures, generate roadmap from current state, find orphaned code, 'are our tickets accurate', 'what's left to build', drift between plan and implementation. Do NOT use for debugging, writing tests, PR reviews, refactoring, CI setup, or adding features."
---

# Gap Analysis

Triangulate **design intent**, **actual implementation**, and **project management state** to produce a **dispatch manifest** — a structured gap inventory where each gap is a self-contained task that an orchestrating agent (Opus) can assign to Haiku or Sonnet subagents to close.

The architecture is: this skill runs the analysis and produces the manifest. Then Opus reads the manifest, groups gaps into execution waves, and dispatches subagents — one per gap or one per cluster of related gaps. Each gap block contains everything the subagent needs: files to read, what to change, acceptance criteria, and whether human sign-off is needed before acting.

## Phase 1: Gather Sources

Collect from all three dimensions in parallel.

### 1A. Design Intent (Internal Docs)

Scan the repository for planning and design documents:

- `specs/` — active and draft specifications
- `plans/` — migration plans, audit reports, architecture plans
- `docs/` — ADRs, design system docs, UDL, wireframes, implementation plans
- `README.md` / `CLAUDE.md` — stated goals, roadmap sections

For each document, extract:
- Feature/capability described (one line)
- Stated status (if mentioned)
- Acceptance criteria (even informal)
- Dependencies

Use `Glob` to find markdown files, `Read` to scan headers and key sections first, then deep-read the relevant ones.

### 1B. Actual Implementation (Codebase)

Focus on what reveals feature completeness:

1. **Route/navigation files** — what screens/pages exist
2. **Index/barrel files** — what's exported and used
3. **Config/feature flags** — what's toggled on/off
4. **Test directories** — what's tested vs not
5. **TODO/FIXME/HACK comments** — known debt with context

### 1C. Project Management State

#### ClickUp (Required — via MCP connector)

Use the ClickUp MCP connector to pull live task data. Search your available tools for anything matching `clickup`. This is non-negotiable — do not fall back to CSV exports or cached data. If the ClickUp MCP connector is not available, stop and tell the user:

> "ClickUp MCP connector is not available in this session. Please connect ClickUp through Claude's MCP settings before running the gap analysis. I need live access to pull tasks by status, including closed ones."

When ClickUp MCP is available:
- Pull all tasks from relevant spaces/lists/folders
- **Include CLOSED and ARCHIVED tasks** — these are critical for ghost closure detection
- For each task capture: ID, title, status, assignee, dates, description, custom fields
- Group by status: Open, In Progress, Review, Closed, Archived

#### GitHub Issues

```bash
gh issue list --state all --limit 200 --json number,title,state,labels,assignees,createdAt,closedAt,body
```

Also check for GitHub Projects:
```bash
gh project list
```

## Phase 2: Cross-Reference and Identify Gaps

For each item from any source, verify it against the other two. Be mechanical about this:

**For every closed ClickUp task and closed GitHub issue:**
1. Grep the codebase for keywords from the ticket title/description
2. Check expected file paths mentioned in the ticket
3. If code exists, verify it's functional (not commented out, not behind a permanently-false flag)
4. If code is missing or gutted, classify as **Ghost closure**

**For every spec/plan document:**
1. Extract the key features/capabilities described
2. Search codebase for corresponding implementation
3. Search ClickUp + GitHub for tracking tickets
4. Classify: Unimplemented, Partial, Drift, or Done

**For every significant code module (route, component dir, lib):**
1. Check if a ClickUp task or GH issue tracks it
2. Check if a spec/doc describes it
3. If neither, classify as **Untracked**

### Gap Types

| Gap Type | Meaning |
|----------|---------|
| **Unimplemented** | Documented in specs/plans, no code exists |
| **Untracked** | Code exists, no ticket/issue tracks it |
| **Stale ticket** | Ticket open but feature is already built |
| **Ghost closure** | Ticket closed but implementation missing or reverted |
| **Partial** | Implementation started but incomplete |
| **Drift** | Implementation diverges from the spec |
| **Orphaned doc** | Planning doc describes abandoned work with no decision |
| **Test gap** | Feature implemented but no tests |

## Phase 3: Produce the Dispatch Manifest

Save as `gap-analysis-report.md` in the project root (or wherever the user specifies).

### Manifest Structure

```markdown
# Gap Analysis — Dispatch Manifest
**Generated**: [date]
**Scope**: [what was analyzed]
**Sources**: [doc dirs, ClickUp spaces/lists, GH repo]

## Executive Summary
[2-3 sentences: gap count by severity, biggest risks, overall health assessment]

## Dispatch Table

| GAP | Type | Severity | Effort | Agent | Depends On |
|-----|------|----------|--------|-------|------------|
| GAP-01 | Ghost closure | High | XS | haiku | — |
| GAP-02 | Unimplemented | Critical | M | sonnet | — |
| GAP-03 | Partial | High | L | sonnet | GAP-02 |

The "Agent" column recommends which model to dispatch:
- **haiku** — XS/S effort: ticket cleanup, doc fixes, one-line code changes, testID additions
- **sonnet** — M/L/XL effort: feature implementation, multi-file refactors, complex wiring

---

## Gap Tasks

Each block below is a complete task specification. Opus reads this manifest
and dispatches each block as a subagent prompt — the block IS the prompt.

---

### GAP-01: [Short title]

**Context for the agent**: [1-2 sentences explaining the situation — what exists,
what's wrong, why it matters. This is the briefing.]

**Type**: [Unimplemented | Ghost closure | Stale ticket | Partial | Drift | Untracked | Orphaned doc | Test gap]
**Severity**: [Critical | High | Medium | Low]
**Effort**: [XS | S | M | L | XL]

**Read these files first** (build context before acting):
- `path/to/file1.ts` — [why: contains the current implementation]
- `path/to/file2.md` — [why: the spec that describes intended behavior]

**What to do**:
1. [Concrete step 1 — e.g., "Add `testID='btn-view-reward'` prop to the ProsperButton at line 84"]
2. [Concrete step 2 — e.g., "Run `pnpm test` to verify no regressions"]
3. [Concrete step 3 — e.g., "Close GitHub issue #137 with a comment linking the commit"]

**Acceptance criteria** (how the agent verifies it's done):
- [ ] [Checkable condition — e.g., "grep for testID='btn-view-reward' returns exactly 1 match in PortalMoment.tsx"]
- [ ] [Checkable condition — e.g., "pnpm test passes with 0 failures"]
- [ ] [Checkable condition — e.g., "gh issue view 137 shows state:closed"]

**Depends on**: [GAP-XX, GAP-YY] or "none"
**Requires human approval**: [Yes — reason] or "No"
**ClickUp**: [Task ID] or "CREATE — [suggested title and description]"
**GitHub**: [#issue-number] or "CREATE — [suggested title and description]"

---
```

Repeat the `### GAP-XX` block for every gap found.

### Dispatch principles

The gap blocks are designed to be handed to subagents nearly verbatim. When writing them:

- **"Context for the agent"** replaces a lengthy description — it's the 2-sentence briefing a smart colleague needs to understand the situation. Write it as if you're handing off to someone who hasn't seen the codebase.
- **"Read these files first"** is the agent's research phase. Include the WHY so the agent knows what to look for in each file, not just where to look.
- **"What to do"** is imperative, numbered steps. Be specific enough that Haiku can execute XS/S tasks without improvising. For M+ tasks aimed at Sonnet, you can describe the goal and let Sonnet figure out the approach.
- **"Acceptance criteria"** are self-checkable. The agent runs these after completing the task to verify its own work. Grep matches, test passes, file existence checks — things that can be verified programmatically.
- **Haiku tasks should be near-mechanical** — the steps are so explicit that there's minimal judgment needed. If a task requires judgment calls about architecture or tradeoffs, recommend Sonnet.
- **Sonnet tasks can be higher-level** — describe the goal, the constraints, and what done looks like. Trust Sonnet to figure out the implementation path.

### Execution Waves

Group gaps into waves that respect dependencies:

```markdown
## Execution Order

### Wave 1 — Parallel, no dependencies
[Table of GAP-IDs that can all be dispatched simultaneously]
[These are typically: ticket cleanup, doc fixes, one-liner code changes]

### Wave 2 — Depends on Wave 1
[Table of GAP-IDs, with which Wave 1 gaps they depend on]

### Wave 3 — Heavy lifts
[L/XL effort items, or items that depend on Wave 2]

### Human Queue
[Gaps where the right action is ambiguous — needs a human decision before an agent can act.
For each: state clearly what decision is needed and what the options are.]
```

### Source Coverage Matrix

```markdown
## Source Coverage
[What was analyzed, what was skipped, blind spots that may hide additional gaps]
```

### Quality Checklist

Before saving the manifest, verify:
- Every gap has concrete "Read these files first" with real paths (not placeholders)
- "What to do" steps are specific enough for the recommended agent tier
- Acceptance criteria are self-checkable (grep, test run, file exists)
- Ticket IDs are real (pulled from ClickUp/GitHub, not invented)
- Dependencies form a DAG (no cycles)
- Human-approval items are in the Human Queue, not in the execution waves
- Agent recommendations match effort: haiku for XS/S, sonnet for M+

## Adapting to Project Context

- **Monorepo**: Check each app/package independently, cross-reference shared deps
- **Single app**: Focus on route/feature mapping against specs
- **No specs directory**: Look in README, CLAUDE.md, PR descriptions, or ask the user
- **Minimal docs**: Weight toward ticket-vs-code comparison; flag the documentation gap itself