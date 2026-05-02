# Gap Analysis Skill

Cross-reference design docs, codebase, and project management state to find every gap — then produce a **dispatch manifest** that an Opus orchestrator can hand to Haiku/Sonnet subagents to close each gap autonomously.

## What it does

Triangulates three sources:
1. **Design intent** — specs, ADRs, plans, design docs in the repo
2. **Actual implementation** — routes, components, feature flags, test coverage, TODOs
3. **Project management** — ClickUp (via MCP connector) + GitHub Issues (via `gh` CLI)

Finds:
- **Unimplemented features** — specced but no code exists
- **Ghost closures** — tickets closed but code is missing or reverted
- **Untracked code** — code exists with no ticket or spec
- **Stale tickets** — open tickets for already-built features
- **Spec drift** — implementation diverges from the plan
- **Test gaps** — features with no test coverage

## Output format

Each gap is a self-contained **dispatch block** that includes:
- Context briefing for the subagent
- Files to read first (with WHY)
- Numbered action steps
- Self-checkable acceptance criteria (grep, test pass, file exists)
- Agent recommendation (haiku for XS/S effort, sonnet for M+)
- Dependencies on other gaps
- Whether human approval is needed

Gaps are organized into **execution waves** — Wave 1 (parallel, no deps), Wave 2 (depends on Wave 1), Wave 3 (heavy lifts), Human Queue.

## Requirements

- **ClickUp**: MCP connector (required for full analysis; skill stops and asks user to connect if unavailable)
- **GitHub**: `gh` CLI authenticated
- **Codebase**: Any project with planning docs (specs/, plans/, docs/) and code

## Trigger phrases

- "gap analysis", "implementation audit", "ticket reconciliation"
- "what's missing", "where do we stand", "what did we miss"
- "compare planned vs built", "reconcile tickets with code"
- "are our tickets accurate", "what's left to build"

## Benchmark

Tested across 3 eval scenarios (broad audit, spec-vs-code, ticket reconciliation):
- **With skill**: 100% pass rate on dispatch-format assertions
- **Without skill**: 29.6% pass rate
- **Delta**: +70.4 percentage points

The skill's value is structural — it transforms a narrative audit into machine-actionable task specifications that an Opus orchestrator can dispatch to subagents.