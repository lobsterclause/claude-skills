# Monorepo detection

`scripts/detect_layout.sh` figures out the workspace shape and enumerates packages. The result is consumed by `where-is.sh` to group output by package and to support `--package <name>` filtering.

## Detection order

1. **pnpm** — `pnpm-workspace.yaml` at repo root. Parses the `packages:` block. Globs of the form `apps/*` and `packages/*` are expanded.
2. **nx** — `nx.json` at repo root. Currently only flags the workspace kind; package enumeration still relies on `package.json` files under standard `apps/` and `libs/` dirs.
3. **npm / yarn classic** — `package.json#workspaces` array (or `workspaces.packages`).
4. **none** — single-package repo. The root `package.json#name` is the only "package", labeled `(root)`.

## Glob expansion

Only the trailing `/*` form is expanded (e.g. `apps/*`, `packages/*`). Nested globs like `apps/**/internal-*` are **not** expanded — they're rare in real workspaces. If your repo uses them, the script will miss those sub-packages and group their files as `(root)`.

## How grouping works

For each result file, the script picks the **longest matching package dir** as the package label. So a file under `apps/web/src/...` is labeled `@scope/web` even if a parent `@scope/root` package also matches the root path. This is the same logic as the `impact` skill, kept consistent on purpose.

## Caveats

- **Symlinked workspaces** (`pnpm` linking `node_modules/@scope/foo` to `packages/foo`): the script reads from the source dir under `packages/`, not the symlink, so this works.
- **Aliased TS paths** (`@kindred-mama/shared` resolving to `packages/shared/src` via `tsconfig.json`): the script does **not** resolve these — it groups by file location, not by import path. The grouping is still useful; alias resolution belongs in the consumer's reasoning.
- **Renamed packages** (folder name ≠ package name): handled — the script reads each package's `package.json#name`.

## Edge case: no `package.json` at root

The script will still emit `workspace_kind: "none"` and `packages: []`. All results get labeled `(root)`. The output remains usable.
