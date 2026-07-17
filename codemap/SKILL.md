---
name: codemap
description: Materialize a single markdown architecture overview of a TS/JS monorepo to docs/architecture/codemap.md (or a custom path) — workspace packages, entry points, cross-package dependency graph, external-dep highlights, and ownership pointers. Use whenever the user asks to "generate a codemap", "create an architecture overview", "make a codemap", "refresh codemap", "what packages are in this repo", "show me the monorepo structure", "what depends on what", "package dependency graph", "give me a top-down view of the architecture", or when a new subagent is launching cold and needs orientation before crawling. Also use right after a workspace boundary change (new package added, package moved/renamed, deps reshuffled). Do NOT trigger for single-file impact analysis (use `/impact` — file-level, not package-level). Do NOT trigger for single-symbol lookups (use `/where-is` or Serena `find_symbol`). Do NOT trigger for non-code repos.
---

# codemap

Generate a single deterministic markdown file (`docs/architecture/codemap.md` by default) summarizing the architecture of a TS/JS monorepo. The point is to give cold-start subagents one ~few-KB read instead of N+M directory crawls.

## When to use this

- Onboarding a new subagent before it starts work on an unfamiliar package.
- Right after a workspace boundary change (added/renamed/moved a package, big dep reshuffle).
- The user asks for a "top-down view", "architecture overview", "monorepo structure", or "what packages depend on what".
- Pre-flight before a multi-shard dispatch — the codemap helps you target the right shards.

## When NOT to use this

- **Single-file change impact** — that's `/impact`. It operates on file-level edges; codemap is package-level.
- **Single-symbol lookups** — use `/where-is` or Serena `find_symbol` / `find_referencing_symbols`.
- **Non-code repos** — docs-only, asset-only, or non-TS/JS repos won't produce useful output.
- **After a routine source edit** — the codemap doesn't change when you tweak a function body. Only refresh on package boundary changes.

## Workflow

All scripts live in `scripts/` next to this file. Run from the repo root (or pass `--root`).

### Generate the codemap

```bash
bash ${CLAUDE_PLUGIN_ROOT}/skills/codemap/scripts/codemap.sh
```

Writes `docs/architecture/codemap.md`. Re-running on an unchanged tree produces a byte-identical body (only the top-of-file timestamp differs).

### CLI flags

```
--output PATH      Write to PATH instead of docs/architecture/codemap.md
--json             Emit the underlying JSON model to stdout; do not write
--root PATH        Treat PATH as repo root (default: git rev-parse --show-toplevel || pwd)
--refresh          Force-rebuild the dep graph cache
--no-external      Skip the "External-dep highlights" section
--max-external N   Top-N external deps per package (default 10)
```

### Commit policy

If the repo wants the codemap checked in (it's useful for cold-starting subagents), commit it on the same branch where the boundary change landed. Otherwise add to `.gitignore`.

## Output anatomy

The generated file has six sections — see `references/output-anatomy.md` for the full spec.

1. **Header** — repo name, generation timestamp, summary stats.
2. **Workspace overview** — table of packages: name, path, language, file count, description.
3. **Entry points** — resolved entry per package (`main` / `module` / `exports` / `src/index.{ts,tsx}`).
4. **Cross-package dependency graph** — directed adjacency between internal packages.
5. **External-dep highlights** — top-N third-party deps per package from `package.json#dependencies`.
6. **Conventions / ownership** — pointers to CODEOWNERS, OWNERS, and `docs/architecture/*.md`.

## Refresh policy

See `references/refresh-policy.md`. TL;DR:

- Refresh when: package added/removed/renamed, workspace globs changed, `package.json#dependencies` changed in a way that crosses internal boundaries.
- Don't refresh for: source edits inside a package, test-only changes, doc edits, lockfile updates that don't change package boundaries.
- A second run on an unchanged tree is byte-identical except for the header timestamp — safe to run in pre-commit if you want.

## Caveats

- **Workspace detection is single-trailing-glob only** (e.g. `packages/*`). Nested globs (`apps/**/web`) are not supported — kept simple deliberately. See `references/monorepo-detection.md`.
- **Dynamic imports, file-based routers, DI-by-name** won't appear in the dep graph. Static analysis only.
- **External-dep section uses `package.json#dependencies`, not derived from imports** — so unused declared deps still appear, and dev-only deps don't. This is intentional (faster, deterministic).
- **`impact` plugin reuse is best-effort** — if `~/.claude/skills/impact/scripts/build_graph.sh` exists, we use its file-level edges and roll them up to package-level. Otherwise we fall back to `git ls-files | grep` for one-hop import detection.

## Customization

See `references/customization.md` for adding custom sections (e.g. crisis-safety paths, ownership labels) via a post-render hook.
