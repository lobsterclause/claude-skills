# Refresh policy

The codemap is a **boundary-level** view. It changes only when package
boundaries shift. Most edits don't move boundaries.

## Refresh when

- A new package is added to the workspace.
- A package is renamed, moved, or removed.
- `pnpm-workspace.yaml` or `package.json#workspaces` changed.
- An internal `package.json#dependencies` edge between packages was added/removed.
- A package's entry point (`main`, `module`, `exports`) changed.
- A new `docs/architecture/*.md` or `CODEOWNERS` landed (so pointers appear).

## Don't refresh for

- Source edits *inside* a package (no boundary change).
- Test-only edits.
- Markdown / asset / config edits that aren't `package.json`.
- Lockfile updates that don't change which packages exist.
- Routine dependency version bumps (the codemap doesn't show versions).

## Determinism guarantee

A second run on an unchanged tree produces a byte-identical file **except**
for the top-of-file `Generated: <timestamp>` line. This makes it safe to:

- Run in pre-commit (no diff churn).
- Commit alongside boundary changes (clean diff).
- Use `CODEMAP_FAKE_TIME=...` to pin the timestamp in tests / reproducible builds.

## Cost target

On a 250K-LOC monorepo:

- With the `impact` plugin's cache warm: ~5–8s.
- Cold (full graph rebuild): ~10–15s.
- Without `impact` (grep fallback): ~5–10s.

If you exceed 20s, either the workspace globs are too broad or the
`impact` cache is missing/stale — try `--refresh`.
