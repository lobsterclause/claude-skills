# Monorepo / workspace detection

`detect_workspaces.sh` checks (in order):

1. **pnpm** — `pnpm-workspace.yaml` with a `packages:` list.
2. **npm / yarn** — `package.json#workspaces` (array form or `{packages: [...]}` form).
3. **single-package** — root `package.json` only.

## Supported glob shapes

- Literal: `apps/web`
- Single trailing star: `packages/*` (one level)

## Not supported (deliberately)

- Nested globs: `apps/**/web`, `packages/*/internal/*`
- Negations: `!packages/legacy`
- Brace expansion: `packages/{a,b}`

These would make the script dependent on a real glob library (or an `eval` of
patterns), which conflicts with the bash-3.2 + no-eval-by-name constraint. If
your repo uses any of these, either flatten the workspace globs or add the
package directly to a single-trailing-glob parent.

## What counts as a "package"

Any directory that:

- Matches an expanded workspace pattern, **and**
- Contains a `package.json` file.

If the root `package.json` exists and has no `workspaces`, the repo is treated
as a single-package layout and only the root counts.

## Name resolution

The display name is `package.json#name` if present, otherwise the relative
path to the package directory.

## Language detection

Per-package: counts `.ts`/`.tsx` vs `.js`/`.jsx`/`.mjs`/`.cjs` source files
(excluding `node_modules`, `dist`, `build`, `.next`, `coverage`).

- Only TS → `ts`
- Only JS → `js`
- Both present → `mixed`
- Neither → `unknown`
