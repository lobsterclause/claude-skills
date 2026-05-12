# Trimming strategy

When the packed snapshot exceeds the requested `--max-tokens` budget, `handoff.sh` enters a trim loop. Files are dropped one at a time, then Repomix is re-run and tokens are re-counted, until the snapshot fits or no further drops are safe.

## Priority order (lowest priority first — dropped first)

1. **`*.md`** — Markdown docs. Reviewers can usually re-derive intent from code; long-form docs eat budget fast.
2. **`*.json`** — Config files, fixtures, generated schemas. Useful for context but rarely load-bearing for code review.
3. **`*.d.ts`** — Type-only declaration files. The `.ts` source already encodes the same types.
4. **`*.css`, `*.scss`** — Style files. Almost never relevant to logic review.
5. **`*.yaml`, `*.yml`** — CI / config. Drop unless the review is about CI itself.
6. **`*.html`** — Static templates. Drop unless the review is about markup/a11y.
7. **Largest non-source file remaining.** When the priority extensions are exhausted, drop whichever non-source file is biggest on disk.
8. **Never auto-drop `.ts/.tsx/.py/.js/.jsx` source.** Only happens if literally nothing else is left, and you'll see a stderr warning.

## Drop selection within a priority class

Within each extension class, the **last file in the current include list** matching that pattern is dropped first. This is deliberately deterministic but not file-aware; if you care about which markdown survives, pass it via `--paths` explicitly.

## Stop conditions

The loop terminates when any of:

- `token_count <= max_tokens` — success.
- 10 trim iterations completed.
- No more droppable files in any class.

In the last two cases, the script still emits the (over-budget) snapshot with `within_budget: false` in the JSON summary, so the caller can decide whether to:

- Send anyway (some reviewers truncate gracefully).
- Re-run with a narrower `--paths`.
- Use `--compress` (Repomix tree-sitter compression — see `repomix-flags.md`).

## Tuning

If the default priority order isn't right for your repo (e.g. you have huge generated `.ts` files that should be dropped first), pre-exclude them via `--exclude "src/generated/**"` rather than reordering priorities. The skill keeps the order stable for predictability.

## Cost of trimming

Each trim iteration re-runs Repomix and re-counts tokens. On a 5k-file monorepo this is ~3–5 seconds per iteration. The 10-iteration ceiling caps worst-case latency at ~30–60 seconds. If you hit the ceiling often, you're likely under-budgeted — pick a larger `--reviewer` preset or narrow `--paths` upfront.
