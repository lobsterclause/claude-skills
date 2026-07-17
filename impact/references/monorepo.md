# Monorepo handling

The skill auto-detects workspace layout from these sources, in order:

1. `pnpm-workspace.yaml` — parses `packages:` globs (single-trailing-`*` only; nested globs not supported).
2. Root `package.json#workspaces` (array form) or `package.json#workspaces.packages` (object form, npm/yarn classic).
3. `lerna.json#packages` — read if present alongside the above.
4. `nx.json` — Nx repos typically also have a workspaces entry; if not, the skill falls back to scanning two levels deep for any directory containing a `package.json`.

Each detected package's name (`package.json#name`) is used as the group key in the report.

## How files are classified

For each impacted file, the skill picks the longest matching package directory. So a file at `apps/web/src/foo.ts` will be classified under the package whose directory is `apps/web/` (not the root). If no workspace matches, it falls under the root package name (or `(root)`).

## Non-standard layouts

If your repo doesn't follow `apps/*` / `packages/*` conventions:

- The skill still works — it just groups everything under one package.
- To get per-package grouping, add the directories to `pnpm-workspace.yaml` or `package.json#workspaces`.
- If you intentionally want flat output, pass `--json` and re-group downstream.

## Path aliases

`tsconfig.json#paths` is honored when:

- `dependency-cruiser` is in use **and** your config sets `tsConfig: { fileName: "tsconfig.json" }` (see `install.md`).
- `madge` is in use **and** the skill passes `--ts-config <repo-root>/tsconfig.json` (done automatically when `tsconfig.json` exists at the root).

If aliases resolve to inter-package imports (e.g. `@kindred-mama/shared` → `packages/shared/lib/...`), the resulting edges are real cross-package edges in the graph and will surface in the per-package grouping. This is exactly what you want for cross-package blast-radius analysis.

If aliases point at a single re-export barrel and your changes are deep inside the package, you may see fewer consumers than expected. Re-check by passing the deeper file as an explicit entry.

## Project references

TypeScript project references (`references` in `tsconfig.json`) are honored by both tools as long as the root `tsconfig.json` lists them. If you have a multi-tsconfig setup with no aggregating root, pass each leaf tsconfig in a separate invocation and merge the reports manually — the skill currently uses one root tsconfig.
