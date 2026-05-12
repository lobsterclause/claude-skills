---
name: repomix-handoff
description: Produce a bounded, token-budgeted codebase snapshot for handing off to external AI reviewers (codex CLI, gemini CLI, kimi CLI). Wraps Repomix and adds PR-scoped slicing, path/language filtering, token-budget enforcement, and per-reviewer output presets. Use whenever the user wants to prepare a snapshot for codex, pack the repo for review, bundle this for kimi, handoff to gemini, context-budget the repo, share this with another AI, or whenever cross-review needs a scoped input bundle for a one-shot reviewer.
---

# Repomix Handoff

Wrap [Repomix](https://github.com/yamadashy/repomix) to produce a **bounded codebase snapshot** for an external AI reviewer. The snapshot is a single file (Markdown, XML, JSON, or plain) holding only the slice of the repo the reviewer needs, trimmed to fit the reviewer's context window.

## When to use

Trigger on any of these phrases or intents:

- "prepare a snapshot for codex / gemini / kimi"
- "pack the repo for review"
- "bundle this for [another AI]"
- "handoff to gemini"
- "context-budget the repo" / "fit this in 200k tokens"
- "share this with another AI"
- Right before invoking `cross-review` against a large diff, when the diff alone is insufficient (e.g. the reviewer needs surrounding context).
- After a `splitstream` run, to hand off a worktree's changes to an external CLI for a second opinion.

This is a **sibling** of `cross-review`, not a dependency. `cross-review` still works standalone with raw diffs. Use `repomix-handoff` when the reviewer needs **more than just the diff** — surrounding source, types, related callers.

## When NOT to use

- The reviewer is Claude itself. Claude reads files directly via tools; don't bother packing.
- A single file or a few files. Just paste them or let the reviewer use `Read`.
- The reviewer needs runtime/CI artifacts (logs, test output) — Repomix is source-only.
- The repo contains secrets you have not scrubbed (see `references/privacy.md`).

## Workflow

1. **Verify Repomix is installed.** Run `scripts/detect_repomix.sh`. If `available: false`, tell the user to install with `npm i -g repomix` (or accept the slower `npx --yes repomix` per-invocation fallback).
2. **Compute the slice.** Run `scripts/compute_scope.sh` with flags below, or let `handoff.sh` do it as part of one command.
3. **Pack + budget-enforce + emit.** Run `scripts/handoff.sh` with the appropriate `--reviewer` preset. The script auto-trims low-priority files when over budget and reports what was dropped.
4. **Hand the resulting file path to the next step** (the reviewer CLI, or `cross-review`, or paste).

### One-shot invocations

```bash
# PR-scoped (default), Markdown, 120k budget
./scripts/handoff.sh

# Path-scoped slice
./scripts/handoff.sh --paths apps/web/src/components/chat

# Language-filtered, smaller budget
./scripts/handoff.sh --lang ts,tsx --max-tokens 80000

# Reviewer preset (sets style + budget for you)
./scripts/handoff.sh --reviewer gemini
./scripts/handoff.sh --reviewer codex
./scripts/handoff.sh --reviewer kimi
./scripts/handoff.sh --reviewer claude

# Include tests, custom output path
./scripts/handoff.sh --include-tests --output /tmp/snapshot.md

# Expand seed set by 1 hop via static imports
./scripts/handoff.sh --expand-imports

# Inspect the plan without running repomix
./scripts/handoff.sh --reviewer codex --dry-run
```

The script prints a JSON summary on stdout:

```json
{
  "output": "/tmp/repomix-handoff-20260512-063906.md",
  "style": "markdown",
  "reviewer": "gemini",
  "max_tokens": 1000000,
  "token_count": 84321,
  "within_budget": true,
  "files_included": ["apps/web/src/...", "..."],
  "files_trimmed": [],
  "trim_iterations": 0
}
```

## Reviewer presets

| Reviewer | Default style | Default budget | Notes                                                       |
| -------- | ------------- | -------------- | ----------------------------------------------------------- |
| `codex`  | xml           | 160,000        | codex CLI prefers XML-fenced repo dumps; budget is conservative. |
| `gemini` | markdown      | 1,000,000      | Gemini 1.5/2.x handles up to ~1M tokens; rarely need to trim. |
| `kimi`   | markdown      | 200,000        | Moonshot Kimi K2 has 200k context; markdown reads cleanly.   |
| `claude` | xml           | 200,000        | XML-style file blocks parse cleanly in Claude prompts.       |
| _(default, no preset)_ | markdown | 120,000 | Safe default for unknown reviewers.       |

See `references/reviewer-presets.md` for full rationale per preset.

## Output formats

- **markdown** — Default. Each file appears as a fenced code block under a header. Best for human review and most LLMs.
- **xml** — `<file path="...">...</file>` blocks. Preferred for Claude and codex; lower ambiguity around code-fence collisions.
- **plain** — File-separator headers, no fencing. Best for `grep`-piping or programmatic post-processing.
- **json** — Repomix's structured JSON. Use only when feeding another tool that parses it.

## Integration with `cross-review`

`cross-review` runs codex/gemini/kimi against the current branch's raw diff. If the diff is large or lacks context, pipe it through `repomix-handoff` first:

```bash
# 1. Build a context-rich snapshot
SNAPSHOT="$(./scripts/handoff.sh --reviewer codex --expand-imports | jq -r .output)"

# 2. Hand it to codex/gemini/kimi via the cross-review skill,
#    using the snapshot as the prompt body instead of (or alongside)
#    `git diff`.
```

**Do not modify cross-review scripts.** This is an opt-in pipe; cross-review remains functional standalone.

## Trimming strategy

When the packed snapshot exceeds the token budget, `handoff.sh` drops files in this priority order (lowest first):

1. `*.md`
2. `*.json` (fixtures, configs)
3. `*.d.ts` (type-only declarations)
4. `*.css`, `*.scss`
5. `*.yaml`, `*.yml`
6. `*.html`
7. Largest non-source file remaining
8. (Never auto-drop `.ts/.tsx/.py/.js/.jsx` source unless that's all that's left.)

After each drop, Repomix is re-run and tokens are re-counted. Up to 10 trim iterations. See `references/trimming-strategy.md`.

## Token counting

`scripts/count_tokens.sh` tries, in order:

1. `ttok` if globally installed.
2. Python `tiktoken` (`cl100k_base` encoding) — closest match for OpenAI/Anthropic tokenizers.
3. `uvx ttok` if `uv` is installed.
4. Char-count divided by 4 as a last-resort estimate (clearly tagged as such on stderr).

**Caveat:** `cl100k_base` is not exact for Gemini or Kimi (different tokenizers), but is within ~10–20%. The default budgets bake in a safety margin. If you need exact Gemini tokens, run the snapshot through Gemini's `countTokens` API after packing.

## Privacy

Packed snapshots contain raw source code. See `references/privacy.md` before sending to a third-party CLI:

- Never paste a snapshot into a public pastebin or chat.
- Scrub `.env`, secrets, credentials, and customer PII fixtures before packing.
- Each reviewer CLI has its own ToS / data-handling policy — your snapshot becomes whatever that CLI does with it.
- Use `--exclude` to remove sensitive globs (default excludes already drop `.lock`, `node_modules`, binaries, etc., but not `.env*`).

## Common gotchas

- **Empty scope.** PR-scoped mode requires at least one changed file vs `origin/main`. If the branch has no diffs, the script exits with a hint to use `--paths` or `--base`.
- **Repomix not installed.** `detect_repomix.sh` checks both global install and `npx`. If neither works, the user gets an actionable install message.
- **Bash 3.2 (macOS default).** All scripts are tested to parse and run under bash 3.2 — no `mapfile`, no `[*]@Q` quoting.
- **Token counter accuracy.** Always report the counting method (set on stderr by `count_tokens.sh`). The char/4 estimate is rough; install `tiktoken` for accuracy.

## References

- [`references/repomix-flags.md`](references/repomix-flags.md) — Useful Repomix CLI flags.
- [`references/reviewer-presets.md`](references/reviewer-presets.md) — Preset rationale per CLI.
- [`references/trimming-strategy.md`](references/trimming-strategy.md) — How the budget enforcer drops files.
- [`references/privacy.md`](references/privacy.md) — What gets included by default and how to scrub secrets.
