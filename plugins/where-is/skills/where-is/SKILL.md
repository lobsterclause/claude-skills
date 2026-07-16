---
name: where-is
description: Locate code in a TypeScript/JavaScript monorepo by routing the query to the right tool — Serena MCP for symbols, ast-grep for structural patterns, git ls-files for path/glob lookups, ripgrep for broad concepts. Use whenever the user asks "where is X defined", "where does X live", "what file is X in", "who uses X", "who calls X", "who imports X", "find consumers of X", "what file handles auth / login / chat / memory / X", "show me X in the code", "find X", "what's in <path>", "what does this directory do". Also trigger on slash-command form `/where-is <query>`. Auto-classifies the query: PascalCase/camelCase identifier → symbol mode (Serena); strings like `useEffect(`, `useState<`, `as any` → pattern mode (ast-grep); paths with `/` or extensions or globs → path mode (git ls-files / fs walk); 3+-word natural-language phrases → concept mode (ripgrep). Returns results grouped by workspace package with file:line citations. Do NOT trigger for editing/refactoring requests, general programming questions ("how do I write a React hook"), or when the user has pasted code and is asking about its behavior (read the file directly instead). Do NOT trigger for "what does this change affect" — that's the impact skill's job.
---

# where-is

A thin classifier + router that picks the cheapest correct tool for "where does X live" questions on a TS/JS monorepo. The point is to avoid burning 5–10 Explore-subagent calls per cold-start lookup at 250K LOC.

The skill itself does very little work — it classifies the query, detects the monorepo layout, runs the matching tool, and formats the output. For symbol-mode it cannot call Serena from a shell (Serena is MCP-only), so it emits a canonical symbol path and tells the **caller** (Claude) to call `mcp__serena__find_symbol` / `mcp__serena__find_referencing_symbols` directly.

## When to use this

- "Where is `FirestoreMemoryClient` defined?"
- "Who uses `useResources`?" / "Who calls `signOut`?" / "Who imports `coreTools`?"
- "What file handles the login flow?" / "What file handles chat persistence?"
- "Find every `useEffect` with an empty dep array" (structural)
- "What's in `apps/web/src/pages/Resources`?" (path)
- Slash form: `/where-is <query>`

## When NOT to use this

- The user is asking you to **change** the code (use Edit / refactor flows).
- The user is asking a general programming question ("how do I write a React hook").
- The user has **pasted code** and is asking about its behavior — read the file directly, no search needed.
- The user is asking **"what does this change affect"** — that's the `impact` skill.
- The user wants a deep architectural explanation, not a lookup — use Explore-subagent or read docs.

## Classification rules

The query is normalized and routed via these heuristics (in order — first match wins). The CLI implements this; the model can also pre-classify when the shape is obvious.

1. **path** — query contains `/`, ends in a known code extension (`.ts .tsx .js .jsx .mjs .cjs .json .md .yml .yaml`), or contains glob chars (`* ? [`). → `scripts/fs_walk.sh`
2. **pattern** — query contains parens, angle-brackets, or one of the ast-grep marker tokens (`=>`, `as any`, `useEffect(`, `useState<`, `<$`, `$$$`). → `scripts/where-is.sh --kind pattern`
3. **symbol** — single token matching `^[A-Za-z_$][A-Za-z0-9_$]*$`, PascalCase/camelCase with no spaces, no dots, no extension. Note rule 1 (path) is checked first: a slash-separated `Class/method` query (Serena's `name_path` format) matches the path rule and needs an explicit `--kind symbol` override to route to Serena instead — see `references/classification.md`. → emit canonical name and ask the model to call Serena MCP tools.
4. **concept** — anything else (3+ words, natural language, lowercase phrases). → `scripts/concept_search.sh`

See `references/classification.md` for the flowchart and edge cases.

## Workflow

All scripts live in `scripts/` next to this file. Run them from the repo root.

```bash
bash ${CLAUDE_PLUGIN_ROOT}/skills/where-is/scripts/where-is.sh "<query>"
bash ${CLAUDE_PLUGIN_ROOT}/skills/where-is/scripts/where-is.sh --kind symbol "FirestoreMemoryClient"
bash ${CLAUDE_PLUGIN_ROOT}/skills/where-is/scripts/where-is.sh --kind pattern 'useEffect($$$)'
bash ${CLAUDE_PLUGIN_ROOT}/skills/where-is/scripts/where-is.sh --kind path  'apps/web/src/pages/**'
bash ${CLAUDE_PLUGIN_ROOT}/skills/where-is/scripts/where-is.sh --kind concept "login flow"
bash ${CLAUDE_PLUGIN_ROOT}/skills/where-is/scripts/where-is.sh --json "useResources"
bash ${CLAUDE_PLUGIN_ROOT}/skills/where-is/scripts/where-is.sh --include-tests "useResources"
bash ${CLAUDE_PLUGIN_ROOT}/skills/where-is/scripts/where-is.sh --package @kindred-mama/shared "FirestoreMemoryClient"
```

What it does:

1. **Classify** the query (or accept `--kind` override).
2. **Detect** the workspace layout (`scripts/detect_layout.sh`) — pnpm / npm-workspaces / nx / none. Used to group output and to support `--package`.
3. **Dispatch** to the routed strategy.
4. **Format** output — pretty groups by package by default, JSON with `--json`.

### Symbol-mode handoff (important)

Serena is an MCP server; it cannot be invoked from a shell. When `where-is.sh --kind symbol Foo` runs, the script:

1. Normalizes the symbol path (`Class/method` form).
2. Prints a "next-action" block telling the model **what MCP tools to call**:

   ```
   == Symbol: FirestoreMemoryClient ==
   ROUTE: Serena MCP (call from this conversation)
     1. mcp__serena__find_symbol            name_path="FirestoreMemoryClient"  include_body=false
     2. mcp__serena__find_referencing_symbols  name_path="FirestoreMemoryClient"
   ```

3. Also emits a **ripgrep fallback** ranked file list so the model has something even without Serena.

The model **must** then make the MCP calls and merge their results into the final answer. See `references/mcp-routing.md`.

### Pattern-mode

Runs `ast-grep --pattern '<pat>' --lang tsx <packages>`. If ast-grep is missing, falls back to ripgrep with a documented degradation warning.

### Path-mode

Uses `git ls-files | grep` when in a git repo (respects `.gitignore`), `find` otherwise. Excludes `node_modules`, `dist`, `.git`, `coverage`, `.next`, `build`. Excludes `*.test.*` and `*.spec.*` unless `--include-tests`.

### Concept-mode

Runs ripgrep with sensible defaults and ranks hits by package. Returns top 30. Best-effort; suggest the user re-phrase as a symbol or path if results are noisy.

## Output format

Default (pretty):

```
== Symbol: FirestoreMemoryClient ==
Defined: packages/shared/lib/memory/FirestoreMemoryClient.ts:42
Referenced (3 files in 2 packages):
  @kindred-mama/shared:
    packages/shared/lib/agent/coreTools.ts:118
  @kindred-mama/web:
    apps/web/src/hooks/useCloudMemory.ts:7
    apps/web/src/pages/Chat.tsx:23
```

JSON (`--json`):

```json
{
  "kind": "symbol",
  "query": "FirestoreMemoryClient",
  "normalized": "FirestoreMemoryClient",
  "route": "serena-mcp",
  "next_actions": [
    {"tool": "mcp__serena__find_symbol", "args": {"name_path": "FirestoreMemoryClient", "include_body": false}},
    {"tool": "mcp__serena__find_referencing_symbols", "args": {"name_path": "FirestoreMemoryClient"}}
  ],
  "fallback_hits": [{"file": "...", "line": 42, "package": "..."}]
}
```

See `references/output-format.md` for every kind's shape.

## Caveats

- **Dynamic dispatch** (route handlers registered by string name, DI containers, file-based routing like Next `app/`, Expo Router): symbolic search will miss these. If symbol-mode returns nothing, fall through to concept-mode automatically.
- **String-based config** (Firebase function names, env-driven feature flags): only concept-mode finds these.
- **Generated code** (`*.gen.ts`, `dist/`) is excluded by default. Re-run with `--include-generated` if needed.
- **Cross-package re-exports**: symbol-mode follows Serena's LSP graph, which usually handles barrel files correctly — but watch for false negatives at workspace boundaries.

The result is a **strong starting point, not exhaustive**. Mention this when handing results to the user for broad-concept queries.

## Related references

- [references/classification.md](references/classification.md) — exact heuristics and edge cases
- [references/mcp-routing.md](references/mcp-routing.md) — Serena MCP tool args and when to use each
- [references/monorepo-detection.md](references/monorepo-detection.md) — pnpm / npm / nx / none
- [references/output-format.md](references/output-format.md) — example outputs per kind
