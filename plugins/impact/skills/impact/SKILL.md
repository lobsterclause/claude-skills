---
name: impact
description: Compute the reverse-dependency closure of one or more changed TypeScript/JavaScript files — what other files transitively import them, plus the test files that should be re-run — using madge and/or dependency-cruiser. Use whenever the user asks "what does this change affect", "what files depend on X", "what tests should I run after editing Y", "impact of this change", "what breaks if I touch this", "blast radius of this edit", or right before committing/pushing a non-trivial TS/JS change so Claude can decide which files to read and which test files to run. Also triggers on "find consumers of this module", "who imports this", "what's downstream of this file". Works on monorepos (auto-detects pnpm/yarn workspaces) and respects tsconfig path aliases. Do NOT trigger for single-symbol lookups (use Serena `find_symbol` / `find_referencing_symbols` instead — those return symbol-level edges, this returns file-level edges). Do NOT trigger for non-code changes (docs-only, asset-only). Do NOT trigger to find a definition — that's also Serena's job.
---

# impact

Static reverse-dependency analysis for TypeScript / JavaScript codebases. Given the files a user (or a `git diff`) just changed, the skill builds — or reuses a cached — import graph and reports the files that transitively depend on them, plus the test files that exercise the affected modules. The output is a structured report Claude can use to decide which files to read in Explore-mode and which test files to actually execute.

The point is to save tokens on large repos. On a 250K-LOC monorepo, calling Explore-subagents to figure out "what depends on `useFooContext.ts`" is expensive and lossy. A static import graph answers that question deterministically for a fraction of the cost.

## When to use this

- Right after the user edits a TS/JS file and asks what else needs attention.
- Before `git commit` / `git push`, when deciding which tests to run locally vs in CI.
- "What does this PR affect?" — point the skill at `git diff origin/main...HEAD`.
- "Who imports X?" — explicit file path, reverse-deps mode.
- Refactor scoping — "if I rename this hook, what files need updating?"

## When NOT to use this

- **Single-symbol lookups** (e.g. "where is `loadConsent` defined", "find all call sites of `useAuth().signOut`"). Use Serena's `find_symbol` / `find_referencing_symbols` — those operate on the LSP symbol graph, which is finer-grained than file imports.
- **Non-code changes** — markdown, images, configs that aren't imported by code, lockfiles.
- **Runtime-only dependencies** — if the "edge" is a string-based dynamic `import()` or a route registered by filename convention (Next.js `app/`, Expo Router), static analysis will miss it. See `references/dynamic-imports.md`.

## Workflow

All scripts live in `scripts/` next to this file. Run them from the repo root. They handle empty diffs, missing tools, and monorepo layouts.

### 1. Detect which tools are available

```bash
bash ${CLAUDE_PLUGIN_ROOT}/skills/impact/scripts/detect_tools.sh
```

Emits JSON like `{"madge": true, "depcruiser": false, "preferred": "madge"}`. If neither is installed, the script tells the user how to add them (see `references/install.md`) and the main entrypoint falls back to a grep-based degraded mode that only catches direct (one-hop) consumers.

### 2. Run the main entrypoint

```bash
bash ${CLAUDE_PLUGIN_ROOT}/skills/impact/scripts/impact.sh            # auto-detect from `git diff HEAD`
bash ${CLAUDE_PLUGIN_ROOT}/skills/impact/scripts/impact.sh --staged   # `git diff --cached`
bash ${CLAUDE_PLUGIN_ROOT}/skills/impact/scripts/impact.sh --base main
bash ${CLAUDE_PLUGIN_ROOT}/skills/impact/scripts/impact.sh path/to/file.ts another/file.tsx
bash ${CLAUDE_PLUGIN_ROOT}/skills/impact/scripts/impact.sh --refresh  # rebuild cache
bash ${CLAUDE_PLUGIN_ROOT}/skills/impact/scripts/impact.sh --json     # machine-readable
```

What it does, in order:

1. Resolves the **entry files** (explicit args > `--staged` > `--base <ref>` > `git diff HEAD`). Filters to `.ts|.tsx|.js|.jsx|.mjs|.cjs`. If nothing matches, prints "no code changes" and exits 0.
2. **Builds or reuses the cache** at `.impact-cache/graph.json`. Cache is invalidated when the lockfile hash changes, when the file count moves >5%, or on `--refresh`. The cache key is hashed from `package.json` + `pnpm-lock.yaml` (or `package-lock.json` / `yarn.lock`) + the root `tsconfig.json`.
3. **Inverts the graph** to find transitive reverse-dependencies of each entry file.
4. **Groups by package** if it detects `pnpm-workspace.yaml`, `package.json#workspaces`, `lerna.json`, or `nx.json`.
5. **Pulls in test files** via `find_tests.sh` — picks up `*.test.ts(x)`, `*.spec.ts(x)`, anything under `__tests__/` whose subject is in the impacted set.
6. **Prints the report** — human-readable by default, JSON with `--json`.

### 3. Interpret the output

The report has four sections:

```
== Changed entry files ==
  apps/web/src/lib/useFoo.ts

== Reverse dependencies (by package) ==
  @kindred-mama/web (12 files)
    apps/web/src/components/FooPanel.tsx
    apps/web/src/hooks/useBar.ts
    ...
  @kindred-mama/shared (3 files)
    packages/shared/lib/agent/coreTools.ts
    ...

== Affected test files (run these) ==
  apps/web/src/components/__tests__/FooPanel.test.tsx
  packages/shared/lib/agent/__tests__/coreTools.test.ts

== Caveats ==
  - 2 dynamic import() call(s) detected in the graph; some edges may be missing.
  - tsconfig path alias `@kindred-mama/shared` resolved.
```

**How to read it:**

- **Changed entry files** — what you fed in. Sanity-check the list before trusting downstream sections.
- **Reverse dependencies by package** — start reading here when answering "what does this affect". Per-package grouping makes it easy to spot a cross-package blast (web → shared → functions) which usually means the change is riskier than it looks.
- **Affected test files** — these are the tests to run. If the list is empty but the rev-dep list is large, that's a coverage gap signal, mention it.
- **Caveats** — read them before claiming the report is exhaustive.

### 4. Hand off

For Claude callers: paste the `Affected test files` list directly into the test runner (`pnpm vitest run <paths...>`). Paste the `Reverse dependencies` list into Explore-subagent prompts as a focused file set instead of letting the subagent search the whole repo.

For users: surface the top 1–3 cross-package consumers and the test-file count in chat; link to the full report file (`.impact-cache/last-report.txt`) for the rest. Do not paste the entire report into chat for large reports — it's long and rarely worth the tokens.

## Caveats

Static analysis catches **import-graph edges only**. The following are invisible to it:

- **Dynamic imports** with non-literal arguments: `import(someVariable)`. Files imported this way are reachable at runtime but won't appear as edges. `dependency-cruiser` will flag the call sites; see `references/dynamic-imports.md` for a rule to surface them.
- **File-based routing** (Next.js `app/page.tsx`, Expo Router): a route handler is not "imported" by anything; it's discovered by the framework at build time. The skill won't surface route changes as affecting the rest of the app even though they may break navigation.
- **String-based config references** (Firebase functions registered via name, dependency-injection containers, JSON config that names a file): no static edge.
- **CSS / asset imports** are tracked as edges by both tools but the rev-dep list will mostly be irrelevant. Use the `--json` mode and filter if needed.
- **Type-only imports** are edges in TypeScript. A pure type change won't break runtime but the report still lists consumers — fine, since they may need re-type-checking.

The report is a **strong starting point, not an exhaustive list**. Mention this in the chat summary when handing the report to the user, especially for changes touching framework-route directories or DI containers.

## Install

See [references/install.md](references/install.md). Short version:

```bash
pnpm add -D -w madge dependency-cruiser
```

The skill works without these installed but degrades to one-hop grep — usable but noisy. Prefer the real tools for any non-trivial repo.

## Related references

- [references/tools.md](references/tools.md) — madge vs dependency-cruiser tradeoffs.
- [references/install.md](references/install.md) — install commands and minimum config.
- [references/monorepo.md](references/monorepo.md) — workspace detection and edge cases.
- [references/dynamic-imports.md](references/dynamic-imports.md) — limitations and mitigations.
