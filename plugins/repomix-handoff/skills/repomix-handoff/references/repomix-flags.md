# Repomix CLI flags

Reference for the subset of [Repomix](https://github.com/yamadashy/repomix) flags this skill uses or commonly needs. Run `npx repomix --help` for the full list.

## Flags used by `handoff.sh`

| Flag        | Example                          | Purpose                                    |
| ----------- | -------------------------------- | ------------------------------------------ |
| `--style`   | `--style markdown`               | Output format: `markdown`, `xml`, `plain`. |
| `--output`  | `--output /tmp/snapshot.md`      | Write packed result here.                  |
| `--include` | `--include "src/**,lib/foo.ts"`  | Comma-separated globs to include.          |
| `--ignore`  | `--ignore "**/*.test.*,dist/**"` | Comma-separated globs to exclude.          |

## Useful flags you can add via `--exclude` or env

| Flag                     | Purpose                                                                       |
| ------------------------ | ----------------------------------------------------------------------------- |
| `--top-files-len N`      | Show top-N largest files in the summary section.                              |
| `--no-file-summary`      | Drop the per-file LoC/size summary.                                           |
| `--no-directory-structure` | Drop the directory tree at the top.                                         |
| `--compress`             | Apply tree-sitter compression (drops function bodies, keeps signatures). Useful when you only need API shape. |
| `--remove-comments`      | Strip code comments from packed output.                                       |
| `--remove-empty-lines`   | Drop empty lines.                                                             |
| `--include-empty-directories` | Include empty dirs in the tree.                                          |
| `--token-count-encoding` | `o200k_base`, `cl100k_base`, etc. Repomix can self-report tokens.             |

## Output-format notes

### `markdown`
Human-readable. Each file under `## File: path/to/file.ts` plus a fenced code block. Pros: easy to scan, plays well with Gemini and Kimi. Cons: ambiguity around nested code fences inside the source (rare).

### `xml`
Each file in `<file path="...">...</file>`. Pros: lower ambiguity; Claude and codex CLI parse this cleanly. Cons: less human-readable.

### `plain`
File separators (`================================`) with paths above the content. Pros: best for `grep`/regex pipelines. Cons: not great for LLMs.

## Self-token-counting

Repomix has its own built-in token counter (`--token-count-encoding cl100k_base`). It writes the total to the summary section of the packed file. The skill's `count_tokens.sh` is a second, redundant counter so it can drive the trim loop without re-parsing Repomix output.

## Configuration file

Repomix reads `repomix.config.json` from the working directory if present. The skill does **not** rely on a config file — all options pass on the CLI so behavior is reproducible across repos.

If a project has a `repomix.config.json` with strict ignores you want to respect, `handoff.sh` will pick them up because Repomix honors the config file when no CLI override conflicts. To force the skill's defaults, pass `--no-default-patterns` (advanced; not auto-applied).
