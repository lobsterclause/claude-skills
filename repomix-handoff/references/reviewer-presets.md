# Reviewer presets

The `--reviewer` flag selects a `{style, max_tokens}` pair tuned for that CLI's context window and ingestion preferences. Pass it instead of `--style` + `--max-tokens` for sensible defaults.

| Reviewer | Style    | Max tokens  | Rationale                                                                                              |
| -------- | -------- | ----------- | ------------------------------------------------------------------------------------------------------ |
| `codex`  | xml      | 160,000     | OpenAI codex CLI consumes XML-fenced repo dumps with high fidelity; 160k leaves headroom under the GPT-4.1/o4 context for prompt + response. |
| `gemini` | markdown | 1,000,000   | Gemini, consumed via Antigravity's `agy` CLI (replaced the standalone `gemini` CLI, retired 2026-06-18) — supports ~1M-token context. Markdown is the recommended ingestion format per Google's prompting guide. Rarely triggers trimming. |
| `kimi`   | markdown | 200,000     | Moonshot Kimi K2 / K1.5 has 200k context. Markdown parses cleanly and matches Moonshot's own tooling. |
| `claude` | xml      | 200,000     | Claude 3.5/4.x parses `<file path="...">...</file>` blocks reliably; 200k matches the default Claude API context. |

## Overriding a preset

Any explicit `--style` or `--max-tokens` flag overrides the preset's value:

```bash
# Use gemini's huge budget but XML formatting:
./scripts/handoff.sh --reviewer gemini --style xml

# Force a smaller budget than the preset (e.g. local kimi server, smaller window):
./scripts/handoff.sh --reviewer kimi --max-tokens 100000
```

## When no preset is set

The default — `--style markdown --max-tokens 120000` — is a conservative middle ground that fits any modern reviewer and leaves room for a non-trivial prompt + response.

## Safety margin

All budgets above are for the **packed snapshot only**. Reserve additional headroom for:

- The system / instruction prompt you send to the reviewer.
- The reviewer's response (can be 4k–16k tokens for code review).
- Any prior conversation context.

A common heuristic: **target 70% of the reviewer's true context window for the snapshot**. The presets already apply this.

## Tokenizer mismatches

Snapshot token counts are estimated with `cl100k_base` (OpenAI). Real token counts on:

- **Claude:** very close to cl100k_base (~5% margin).
- **Gemini:** ~1.1–1.3× cl100k_base for code (Gemini tokenizes some symbols more aggressively). Budget includes ~20% buffer.
- **Kimi:** ~1.0–1.1× cl100k_base.

If you need exact counts before sending to a paying API, call that provider's token-count endpoint after packing.
