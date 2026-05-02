# Reviewer CLI flag reference

Consult this file when a reviewer is misbehaving or when deciding whether a new flag should be added to `scripts/run_reviewers.sh`.

## codex

Binary: `codex` (codex-cli, Homebrew). Verify with `codex --version`.

Invocation used by this skill:

```bash
codex exec review \
  --base <branch> \
  --full-auto 2>&1
```

Why these flags:

- `exec review` — dedicated non-interactive review subcommand. No TUI, no approvals.
- `--base <branch>` — tells codex which base to diff against. Without it, codex picks up whatever its own heuristic decides, which can be wrong in monorepos. When `--base` is set, codex uses its own built-in review instructions; a positional `[PROMPT]` is mutually exclusive with `--base` and is not passed.
- `--full-auto` — equivalent to `-a on-request --sandbox workspace-write`. Required for headless runs: no approval prompts, writes confined to the workspace. We don't want codex editing files during review — its sandbox is a safety net, not a feature we use.
- `2>&1` — codex writes both its progress trace and the final review summary to stderr in plain-text mode; we merge streams so everything lands in `codex.stdout`.

Flags we deliberately do not use:

- `--dangerously-bypass-approvals-and-sandbox` — skips all safety. Only for externally-sandboxed CI, which isn't our case.
- `-m/--model` — we let codex pick its default. Pin a model only if results become inconsistent across runs.
- `--commit <sha>` / `--uncommitted` — we always want branch-vs-base for cross-review, not commit-scoped.
- `--json` — JSONL event stream; omits the final review summary in `exec review` mode (only emits reasoning/command events). Plain-text + stream-merge is the only reliable way to capture the review.

**Important gotcha**: `codex exec review --base <branch>` and a positional `[PROMPT]` are **mutually exclusive** — passing both fails with `the argument '--base <BRANCH>' cannot be used with '[PROMPT]'`. If you need custom review instructions for codex, you have to omit `--base` and describe the branch-vs-base setup inside the prompt itself.

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

## kimi

Binary: `kimi` (Moonshot's Kimi Code CLI, installed via `curl -L code.kimi.com/install.sh | bash`, which `uv tool install`s `kimi-cli`). Verify with `kimi --version`.

Invocation used by this skill:

```bash
kimi \
  --plan \
  --print \
  --quiet \
  <<<"<prompt-with-full-diff-inline>"
```

**Invocation mode: single-turn, no-tools.** Unlike codex and gemini, we do *not* let kimi roam the repo with file-reading tools. Instead, the full `git diff <base>...HEAD` is embedded in the prompt and we instruct the model "do not use any tools." This is a deliberate design choice — see the rationale below.

Why these flags:

- `--plan` — read-only plan mode. Defense in depth; even if kimi decides to call a write tool despite the prompt instruction, it can't edit anything.
- `--print` — non-interactive mode; exits after the single turn. Without it, kimi launches its TUI and blocks forever in a pipeline. `--print` implicitly sets `--yolo`, harmless under `--plan`.
- `--quiet` — alias for `--print --output-format text --final-message-only`. Prints only the final assistant message.
- **stdin** (via here-string) carries the prompt. **Do not** use `-p` — argv has a hard 128KB-per-argument limit on Linux (`MAX_ARG_STRLEN`), which the inlined diff can easily exceed; argv-based prompts also expose the full diff via `ps` to other users on the machine. kimi reads stdin as the prompt when `--print` is set and no `-p` is given. The wrapper caps the diff at 8000 lines (well under k2.5's 256K-token context) and injects a truncation warning into the prompt when exceeded.

Why single-turn no-tools (the real story):

- **The adapter bug.** `kimi-k2.5` + thinking mode + multi-turn tool calls require the `openai_legacy` provider to thread `reasoning_content` between turns. It doesn't — the second tool-call turn fails with `400 — thinking is enabled but reasoning_content is missing in assistant tool call message at index 2`. This is documented in Moonshot's K2.5 tool-use compatibility notes.
- **Why we don't just disable thinking.** We tried `--no-thinking` to sidestep the bug. It works, but you lose the reasoning quality that's the whole reason to use K2.5 as a reviewer — at that point you may as well run K2-turbo.
- **Why single-turn is actually fine for review.** Code review is fundamentally a single-turn task: the diff IS the input. codex and gemini already handle the agentic file-roaming niche; kimi's job here is deep reasoning on the diff as given. That's complementary, not duplicative.
- **If you ever switch to the native `api.kimi.com` provider** (via `kimi login` OAuth + Kimi Coding subscription), kimi-cli's native `type = "kimi"` adapter preserves `reasoning_content` correctly and you can drop the "no tools" instruction and enable agent-style review.

Flags we deliberately do not use:

- `--thinking` / `--no-thinking` — we let the config default win (thinking enabled for k2.5). The inline-diff approach avoids the tool-call bug that would otherwise force `--no-thinking`.
- `-m/--model` — we set the default model in `~/.kimi/config.toml` once and let every invocation use it. Pin per-call only if you need to A/B between models.
- `--yolo` (explicitly) — already implied by `--print`; no reason to add it.
- `--agent okabe` — a specialized "okabe" built-in agent exists; we use the default because reviewer tasks don't benefit from the okabe specialization.

Auth: kimi uses a TOML config file at `~/.kimi/config.toml`. For the Moonshot platform key (from [platform.moonshot.ai](https://platform.moonshot.ai)), configure an `openai_legacy` provider pointing at `https://api.moonshot.ai/v1`:

```toml
default_model = "kimi-moonshot"

[models.kimi-moonshot]
provider = "kimi-moonshot"
model = "kimi-k2.5"
max_context_size = 262144

[providers.kimi-moonshot]
type = "openai_legacy"
base_url = "https://api.moonshot.ai/v1"
api_key = "sk-..."
```

Valid model IDs on the Moonshot endpoint (as of 2026-04): `kimi-k2.5`, `kimi-k2-thinking`, `kimi-k2-thinking-turbo`, `kimi-k2-0905-preview`, `kimi-k2-turbo-preview`, `kimi-k2-0711-preview`, `moonshot-v1-{8k,32k,128k}`, `moonshot-v1-auto`, plus `-vision-preview` variants. `kimi-k2.5` (256K ctx, thinking mode default) is the best reviewer.

If the user has a `code.kimi.com/coding/v1` subscription key instead of a Moonshot platform key, run `kimi login` interactively once — kimi-cli handles that provider natively (`type = "kimi"`, no manual config needed).

## Known issues and gotchas

- **All three CLIs can cold-start slowly** on first run of the day (30–60s). Timeouts in the wrapper are set to 5 minutes per reviewer; if one hits that, it's usually auth or network, not actual work.
- **codex may emit warnings about rate limits** on the free tier; they show up in stderr and do not fail the run. The final JSONL event will still contain the review.
- **gemini JSON output is one blob, not JSONL.** If the output looks truncated, it's probably a write-to-pipe buffering issue — check `gemini.stderr` first.
- **kimi will print "To resume this session: kimi -r <uuid>" at the end** of every `--print` run (to stderr). Harmless, just noise in the log. Don't confuse it with an error.
- **All three reviewers will read files in the repo.** If the repo contains untrusted input (e.g., fixture data for a parser), be aware that this is being sent to external APIs — including Moonshot for kimi, which is a China-origin provider. Worth flagging for security-sensitive or export-controlled work.