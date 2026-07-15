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
- **Requires `--no-config` unless the repo has a `.dependency-cruiser.(c|m)js` config file** (dependency-cruiser >=17 hard-errors otherwise: "Can't open a config file"). `build_graph.sh` checks for one and adds the flag automatically — see the `depcruise_config_flag` logic there.
- **Needs `typescript` resolvable within dependency-cruiser's supported peer range to parse `.ts`/`.tsx` at all — and fails silently, not loudly, outside it.** Confirmed live: dependency-cruiser 18.1.0 + `typescript` 7.0.2 (current npm latest at the time) → `.ts`/`.tsx` both show as disabled in `depcruise -i`, and a real run over real `.ts` files returns `{"modules": []}` with exit 0 and no warning anywhere — not in stdout, not in stderr. Both real repos this skill was built against pin `typescript` ^5.x, well inside the supported range, so this shouldn't bite in practice — but because the failure is silent, `build_graph.sh` treats an empty graph as a build failure (`graph_is_suspiciously_empty`, keyed off the coarse `$file_count` from the cache-key computation) and falls back to grep rather than rendering a confidently wrong "(none)" report. If you see the "produced an empty graph" warning, run `node_modules/.bin/depcruise -i` in the target repo to see which extensions/transpilers it actually has enabled.

Use when: monorepo, you want to detect dynamic imports, you'll benefit from custom rules.

## Why this skill prefers dependency-cruiser

It exposes `dynamic: true` per edge, lets us filter type-only edges (`dependencyTypes`), and respects more tsconfig features (paths, baseUrl, project references). For a 250K-LOC monorepo, the richer signal is worth the extra setup.

If only madge is available, the skill still works — it just can't report which edges are dynamic.

## Fallback: grep one-hop

If neither tool is installed (and auto-install — see `../SKILL.md#install` — didn't run or failed), the skill falls back to a Node script that regex-greps for `import ... from "..."` and resolves relative paths. This is **one hop only** and misses path aliases, dynamic imports, and CommonJS `require`. Acceptable for a quick sanity check; not acceptable for refactor planning.

## codegraph — used for test-file detection only, not the main graph

If this repo has a codegraph index (`.codegraph/` present, `codegraph` CLI on PATH), `find_tests.sh` prefers `codegraph affected --stdin -j` over the filename-convention heuristic for the "Affected test files" section. It's a real transitive BFS over an already-built, tree-sitter-derived import graph — no rebuild, no install, and it works on any language codegraph indexes, not just TS/JS. Verified against `codegraph`'s own CLI source: `affected`'s traversal (`cg.getFileDependents()` in a BFS loop, bounded by `--depth`, default 5) has no hidden truncation, unlike the human-readable renderer described below.

**Why codegraph isn't used for the "reverse dependencies by package" section too:** that section needs a full, file-level reverse-dependency closure, and codegraph's CLI doesn't expose one as structured data. The closest thing — `codegraph node -f <file> --symbols-only`, "read a file... with dependents" — is text-only (no `-j`) and its dependents line is capped: `mcp/tools.js`'s `handleFileView` renders `used by ${dependents.length} file(s): ${dependents.slice(0, 8).join(', ')}${dependents.length > 8 ? ', +N more' : ''}` — the count is accurate but only the first 8 names are listed. For a widely-imported shared file (exactly the highest-stakes case for a blast-radius tool), text-parsing that output would silently under-report the closure. `codegraph impact <symbol>` avoids the cap but is symbol-scoped, not file-scoped, and there's no bulk per-file-symbols JSON export to drive it from a changed file list without extra `callers`/`impact` calls per exported symbol. Given `dependency-cruiser` already solves this correctly and completely (see above, and it's now auto-installed when missing), it wasn't worth building a parser tied to another tool's undocumented text-rendering format for the same result. If codegraph's CLI ever grows a JSON, uncapped, file-level reverse-deps command, revisit this.
