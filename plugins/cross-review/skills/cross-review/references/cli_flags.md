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

## antigravity & gemini-pro (both via `agy`)

Binary: `agy` (Google Antigravity CLI). Verify with `agy --version`. Install: `curl -fsSL https://antigravity.google/cli/install.sh | bash` (lands at `~/.local/bin/agy`). Auth: `agy login` once interactively (Google OAuth); state persists for headless runs.

> **Why two reviewers on one CLI.** As of the **2026-06-18 Gemini-CLI consumer sunset**, the standalone `gemini` CLI no longer serves free/Pro/Ultra requests. Google's replacement is Antigravity (`agy`), which now hosts the whole Gemini lineup *and* exposes `--model`. So both Gemini-family reviewers ride `agy`, differing only by `--model`:
>
> | Reviewer | `--model` | Role | Default timeout |
> |---|---|---|---|
> | `antigravity` | `Gemini 3.7 Flash (High)` | fast lap | 600s |
> | `gemini-pro`  | `Gemini 3.1 Pro (High)`   | deep lap | 900s |
>
> They are the **same provider (Google)** — count their agreement as a single provider's vote, not two independent ones (see `reviewer_profiles.json` `_synthesis_rules.provider_independence`).

Invocation used by this skill (identical bar `--model` and timeout — see `run_agy_reviewer()`):

```bash
agy \
  --model "Gemini 3.1 Pro (High)" \
  --sandbox \
  --print-timeout <budget>s \
  --log-file <out>/<slug>.agy.log \
  -p "<prompt>" </dev/null
```

Why these flags:

- `--model "<exact display name>"` — pins the model. **The value MUST match an `agy models` display name string exactly** (e.g. `Gemini 3.1 Pro (High)`, *with* the parenthesized reasoning tier). On an unrecognized string, `agy` does **NOT error** — it silently falls back to its default (`Gemini 3.5 Flash`). Verified on `agy 1.0.9` (2026-06-18). This silent fallback is the single biggest footgun: a typo turns the "deep lap" into a second Flash run with no warning. Run `agy models` to see the current valid strings; keep them in sync with `reviewer_profiles.json` `.model` and the defaults in `run_reviewers.sh`.
- `--sandbox` — enables terminal/shell sandbox restrictions (the closest thing `agy` has to a read-only mode). We also prompt-instruct "do not edit/write/commit" as a backstop.
- `--print-timeout <dur>` — `agy`'s own in-CLI timeout (Go duration syntax, e.g. `600s`). Set just under the wrapper's `timeout` budget so `agy` exits cleanly and flushes partial output rather than being hard-killed mid-write.
- `-p <prompt>` — non-interactive single-shot. Aliases: `--print`, `--prompt`. Without it, `agy` launches its agent TUI and blocks forever in a pipeline.
- `--log-file <path>` — pins `agy`'s own log next to our outputs for post-mortem.
- `</dev/null` on stdin — keep stdin closed so `agy` doesn't block waiting on it.

Flags we deliberately do not use:

- `--dangerously-skip-permissions` — auto-approves every tool call including writes. A reviewer that can auto-approve edits defeats the purpose.
- `-i / --prompt-interactive`, `-c / --continue`, `--conversation <id>` — interactive/session-resume modes; we want one clean single-shot per pass.

Auth/empty-output gotcha: if `agy` returns empty stdout, suspect expired auth (re-run `agy login`) — that is **not** a timeout to bump. The wrapper records `output_bytes` in `<slug>.meta.json` so the runlog can tell "ran but produced nothing" (auth) from "ran and produced findings".

Subcommands worth knowing: `agy models` (list valid `--model` strings), `agy update` (self-update), `agy changelog` (release notes — check it when a flag stops behaving).

## kimi

**No CLI since 2026-09-03.** The kimi baseline is a curl lane: the same
OpenAI-compatible chat-completions body the OpenRouter pool sends, posted to
`https://api.moonshot.ai/v1/chat/completions` with the Moonshot platform key
(`MOONSHOT_API_KEY` or `~/.config/moonshot/key`) and model `kimi-k2.7-code`
from `reviewer_profiles.json` (`.kimi.model`). kimi27 and kimi3 use the identical
lane. One request per review; `tokens_prompt`/`tokens_completion` come from the
response `usage`, cost is estimated from the profile `pricing`, and file access
is the wrapper-owned tool loop (`lib_tool_loop.sh`), budgeted per seat.

Why the Kimi Code CLI (`kimi --plan --print --quiet`) was dropped: it was
documented here as "single-turn, no-tools" with `--plan` as defense in depth.
Its own session logs (`~/.kimi/sessions/*/wire.jsonl`) showed plan mode turning
every review into ≥3 API steps — write plan file, `ExitPlanMode`, answer — and
up to 25 after context compaction, each step re-sending the whole 40K–200K-token
prompt at the cache-miss rate. On 2026-09-03 that was 88 reviews, 15.8M tokens
sent for 4.3M of actual prompt, and ~$20 drained from the shared Moonshot
balance, with nothing stamped in `runlog.jsonl` because the CLI reports no
usage. A `kimi` binary on `$PATH` is now irrelevant to the skill; a `--plan`
reappearing in `run_reviewers.sh` is the regression (guarded in `run_tests.sh`).

## Known issues and gotchas

- **All CLIs can cold-start slowly** on first run of the day (30–60s). Per-reviewer timeouts default to codex=300s, antigravity=600s, gemini-pro=900s, kimi=600s; if one hits its cap, it's usually auth or network, not actual work.
- **codex may emit warnings about rate limits** on the free tier; they show up in stderr and do not fail the run. The final JSONL event will still contain the review.
- **`agy --model` fails silently on a bad model string** — it falls back to Flash instead of erroring (see the antigravity/gemini-pro section above). If `gemini-pro` results look suspiciously fast/shallow, confirm the model string still matches an `agy models` entry.
- **antigravity + gemini-pro share one `agy` auth + rate limit.** Running both concurrently can trip Google rate limits; the wrapper staggers spawns by 2s to soften the simultaneous-handshake case. Empty stdout from either usually means the shared auth expired — `agy login` once.
- **kimi will print "To resume this session: kimi -r <uuid>" at the end** of every `--print` run (to stderr). Harmless, just noise in the log. Don't confuse it with an error.
- **codex and the two agy reviewers will read files in the repo** (kimi runs diff-only, no tools). If the repo contains untrusted input (e.g., fixture data for a parser), be aware that this is being sent to external providers — OpenAI (codex), Google (agy), and Moonshot (kimi, a China-origin provider). Worth flagging for security-sensitive or export-controlled work.