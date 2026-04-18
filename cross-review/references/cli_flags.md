# Reviewer CLI flag reference

Consult this file when a reviewer is misbehaving or when deciding whether a new flag should be added to `scripts/run_reviewers.sh`.

## codex

Binary: `codex` (codex-cli, Homebrew). Verify with `codex --version`.

Invocation used by this skill:

```bash
codex exec review \
  --base <branch> \
  --full-auto \
  --json \
  "<prompt>"
```

Why these flags:

- `exec review` — dedicated non-interactive review subcommand. No TUI, no approvals.
- `--base <branch>` — tells codex which base to diff against. Without it, codex picks up whatever its own heuristic decides, which can be wrong in monorepos.
- `--full-auto` — equivalent to `-a on-request --sandbox workspace-write`. Required for headless runs: no approval prompts, writes confined to the workspace. We don't want codex editing files during review — its sandbox is a safety net, not a feature we use.
- `--json` — JSONL event stream. Every model utterance, tool call, and final result is a discrete JSON line. The useful review content is in the final few events. We don't parse the stream in-script — the skill's agent reads the raw output and synthesizes findings itself.

Flags we deliberately do not use:

- `--dangerously-bypass-approvals-and-sandbox` — skips all safety. Only for externally-sandboxed CI, which isn't our case.
- `-m/--model` — we let codex pick its default. Pin a model only if results become inconsistent across runs.
- `--commit <sha>` / `--uncommitted` — we always want branch-vs-base for cross-review, not commit-scoped.

**Important gotcha**: `codex exec review --base <branch>` and a positional `[PROMPT]` are **mutually exclusive** — passing both fails with `the argument '--base <BRANCH>' cannot be used with '[PROMPT]'`. When `--base` is supplied, codex uses its own built-in review instructions; any custom prompt is dropped. If you need custom review instructions for codex, you have to omit `--base` and describe the branch-vs-base setup inside the prompt itself.

Auth: codex uses its own login (`codex login`). If the first run hangs on auth, that's almost always it. Re-run `codex login` interactively once, then headless runs work.

## gemini

Binary: `gemini` (`@google/gemini-cli`, npm global). Verify with `gemini --version`.

Invocation used by this skill:

```bash
gemini \
  --approval-mode plan \
  --output-format json \
  -p "<prompt>" </dev/null
```

Why these flags:

- `--approval-mode plan` — read-only mode. Gemini can read files and run analysis but won't attempt edits. The alternatives are `default` (prompts on each action, breaks headless), `auto_edit` (auto-approves file edits — dangerous for a reviewer), and `yolo` (auto-approves everything — very dangerous).
- `--output-format json` — single structured JSON blob at the end. Easier to diff across runs than the default text mode.
- `-p <prompt>` — non-interactive mode. Without `-p`, gemini launches its TUI and blocks forever in a pipeline.
- `</dev/null` on stdin — **important**. Gemini concatenates stdin to the `-p` value when both are present, which silently duplicates the prompt and doubles token cost. Blocking stdin with `</dev/null` prevents that. (An earlier iteration of this doc recommended piping the prompt in via stdin; that turned out to be actively wrong — don't do it.)

Prompts in this skill are well under shell argv limits, so `-p` alone is fine. If you ever need to pass a prompt too large for argv, use a here-doc into stdin AND omit `-p`, not both.

Flags we deliberately do not use:

- `--yolo` / `--approval-mode yolo` — bypasses all confirmations. Not appropriate for an automated reviewer that might touch untrusted code.
- `-m/--model` — default model is fine; pin only if needed.
- `-s/--sandbox` — we're already scoped by `plan` mode, no extra sandboxing needed.
- `--raw-output` — disables sanitization of model output (can leak ANSI escape sequences). Security footgun, don't use.

Auth: gemini uses Google OAuth. First run will need an interactive browser login. After that, headless runs work.

## Known issues and gotchas

- **Both CLIs can cold-start slowly** on first run of the day (30–60s). Timeouts in the wrapper are set to 5 minutes per reviewer; if one hits that, it's usually auth or network, not actual work.
- **codex may emit warnings about rate limits** on the free tier; they show up in stderr and do not fail the run. The final JSONL event will still contain the review.
- **gemini JSON output is one blob, not JSONL.** If the output looks truncated, it's probably a write-to-pipe buffering issue — check `gemini.stderr` first.
- **Both reviewers will read files in the repo.** If the repo contains untrusted input (e.g., fixture data for a parser), be aware that this is being sent to external APIs. Not a problem for most codebases, but worth flagging for security-sensitive work.