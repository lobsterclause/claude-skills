# madge vs dependency-cruiser

Both tools build a static import graph for TS/JS. They overlap a lot. Prefer whichever is already installed; if you're choosing fresh, prefer `dependency-cruiser`.

## madge

- Lightweight, fast, minimal config.
- Output: `{ "src/a.ts": ["src/b.ts"], ... }` — already an adjacency list.
- Reads `tsconfig.json` paths via `--ts-config`.
- Misses some edge cases: re-exports through barrels can confuse it; `require()` with string concat is invisible.
- No custom rule engine.

Use when: small to medium repos, you want a quick graph, you don't need custom rules.

## dependency-cruiser

- Heavier, more configurable. Ships with a TypeScript-aware resolver.
- Output (with `--output-type json`): `{ modules: [{ source, dependencies: [{resolved, dynamic, ...}], ...}] }`.
- Reads `tsconfig.json` paths via `--ts-config`. Honors `.dependency-cruiser.cjs` config (you can encode forbidden-dep rules, e.g. "no UI code may import from `lib/server/*`").
- **Flags dynamic imports** (`dynamic: true` on the dependency record) so you can surface them in the report.
- Slower on first run (10–30s on a 250K-LOC monorepo without cache); fine with cache.

Use when: monorepo, you want to detect dynamic imports, you'll benefit from custom rules.

## Why this skill prefers dependency-cruiser

It exposes `dynamic: true` per edge, lets us filter type-only edges (`dependencyTypes`), and respects more tsconfig features (paths, baseUrl, project references). For a 250K-LOC monorepo, the richer signal is worth the extra setup.

If only madge is available, the skill still works — it just can't report which edges are dynamic.

## Fallback: grep one-hop

If neither tool is installed, the skill falls back to a Node script that regex-greps for `import ... from "..."` and resolves relative paths. This is **one hop only** and misses path aliases, dynamic imports, and CommonJS `require`. Acceptable for a quick sanity check; not acceptable for refactor planning.
