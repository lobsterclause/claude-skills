# Investigation: a wrapper-owned tool loop for the text-only seats

Date: 2026-08-27. Branch: `feat/cross-review-tool-loop` (off `fix/cross-review-seat-audit-draw-boost`).

## Why

`codex` is the only seat that can execute anything during a review. The other
17 seats are single-shot chat completions with the diff + whole changed files
pasted in. Checked live 2026-08-27, the reasons in the wrapper are choices or
stale, not constraints:

- All 15 OpenRouter pool models list `tools` in `supported_parameters`
  (`/api/v1/models`, checked against the exact pinned slugs).
- Kimi CLI is 1.48, a full agent; the `reasoning_content` blocker in
  `run_kimi` only applies with thinking on, and `~/.kimi/config.toml` has
  `default_thinking = false`.
- The agy read-only `permissions.allow` list is still "proposed, NOT verified
  live"; the settings file still allows only `echo`.

And the OpenRouter lane is also where `codex` lands when its first-party lane
fails (`status: fallback`, seen on the skoolie run 2026-08-27T19:07Z) — so a
tool-capable OR lane also restores codex's agent-ness in fallback.

## Design

**The wrapper is the harness.** `run_openrouter_reviewer` gains a bounded
multi-turn loop with a fixed toolset the wrapper executes itself, in the
parent's sandbox. One implementation covers 17 seats plus every fallback.

Tools (OpenAI function-calling schema, `lib_tool_loop.sh`):

| tool | what | guards |
|---|---|---|
| `read_file(path, start_line?, end_line?)` | post-change file in the checkout | realpath inside repo root, no `.git/`, per-call cap, per-seat cumulative read budget, secret-content scan |
| `search(pattern, path_glob?)` | `git grep -n -I -E` over tracked files | args not eval; pattern length cap; line cap |
| `list_files(dir?)` | `git ls-files` | line cap |
| `run_check()` | the repo's **declared** verify entrypoint | mode `check` only; command is the repo's, never the model's; run once per round and cached across seats; timeout; output tail cap |

The model never chooses a command. `run_check` resolves, in order,
`CROSS_REVIEW_CHECK_CMD` → `.claude/verify.sh` → `package.json` `verify`
script → `Makefile` `verify`/`check` target. No entrypoint → the `check` arm
is unavailable for that repo (the model is told so).

Arms: `off` (today's behaviour), `read` (file tools), `check` (file tools +
`run_check`). Whole-file paste (`--context-mode files`) stays independent —
tools add on top by default; `CROSS_REVIEW_TOOL_CONTEXT=diff` drops the paste
when tools are on.

### Tunable

Global (env / flag): `--tool-mode off|read|check|auto` /
`CROSS_REVIEW_TOOL_MODE` (default `auto` = learned), `CROSS_REVIEW_TOOL_MAX_STEPS`,
`CROSS_REVIEW_TOOL_READ_BUDGET_BYTES`, `CROSS_REVIEW_TOOL_CALL_CAP_BYTES`,
`CROSS_REVIEW_CHECK_CMD`, `CROSS_REVIEW_CHECK_TIMEOUT_S`, `CROSS_REVIEW_TOOL_CONTEXT`.

Profile (`reviewer_profiles.json`): `_synthesis_rules.tool_policy` holds the
defaults and the learner's constants; a seat's `tools: {mode, max_steps}`
pins that seat (pinned seats are not learned).

### Self-learning

`tool_policy.sh --reviewer <slug>` decides the arm for a seat from the
ledgers already kept (`runlog.jsonl` + `finding_events.jsonl`), stateless,
the same way `leaderboard.sh` scores. Per (seat, arm) over the window:

    reward(run) = 0.6 * r_q + 0.4 * r_ok - cost_lambda * cost_usd
    r_ok = 1 if status ok else 0
    r_q  = 0.5 if no findings (uninformative)
         = (findings - dropped - 0.5*unanchored) / findings otherwise

    ucb(arm) = mean_reward + ucb_c * sqrt(ln(N+1) / (n_arm+1))
    untried arm → optimistic prior (0.75), so every arm gets sampled

Pick argmax; ties by fixed priority `read > check > off`. An arm with
≥ `min_samples` runs and reliability < 0.5 is demoted (the tool loop breaks
that model — malformed tool calls, loops). `check` is skipped when the repo
has no entrypoint. Every decision (`mode`, `basis`, per-arm stats) is stamped
into the seat's `meta.json` → runlog, so the next decision sees it and a human
can audit it with `tool_policy.sh --explain`.

Deterministic on purpose: no randomness in a shell tool, reproducible from
the ledgers, testable with fixtures.

### Telemetry

`meta.json` gains `tool_stats` `{mode, steps, calls{...}, read_bytes,
budget_exhausted, check_ran, check_rc}` and `tool_policy` `{mode, basis}`;
`context_access` becomes `tool_read` / `tool_check` (weight 1.0) so
`score_findings.sh` and the leaderboard can split precision by arm.

## Progress

- [x] Live checks (above)
- [x] `lib_tool_loop.sh` + loop in `run_openrouter_reviewer` (bash 3.2-clean; executor runs via redirect, not `$(…)`, so its counters survive)
- [x] `tool_policy.sh` (ledgers go to jq as `--slurpfile` — the 3.3 MB runlog blew argv on the first live run)
- [x] profiles `_synthesis_rules.tool_policy` + `tool_read`/`tool_check` context kinds in profiles and `score_findings.sh`
- [x] tests: `test_tool_loop.sh` (80 asserts, provider shim answers tool_calls then final) and `test_tool_policy.sh` (39 asserts, fixture ledgers) wired into `run_tests.sh`; legacy single-shot suites pinned `CROSS_REVIEW_TOOL_MODE=off`
- [x] SKILL.md step 2.5b + reviewer notes; `run_reviewers.sh` header

## Live check against the real ledgers (2026-08-27)

`tool_policy.sh --all --mode table` on the production runlog: every chat seat with
history sits on the `off` arm at mean ≈ 0.62–0.70 (codex's fallback rows: 0.70 at
$0.042/run); the untried `read` arm's optimistic prior (0.75 + exploration bonus)
wins, so the first rounds explore `read` everywhere, as intended. `kimi3` (one
perfect `off` run, mean 1.0) stays `off` until the bonus decays — also as intended.

## Not done / follow-ups

- `run_kimi` (the Kimi CLI baseline) and the agy laps are untouched. kimi could
  ride the same loop via Moonshot's endpoint (the `kimi27` lane already does);
  the CLI seat is left as the deliberate "deep single-turn reasoning" niche.
- No live round has run with tools on yet; the first ones are the learner's
  first `read` samples. Watch `tool_stats.steps`, `read_bytes`, `rf_dropped`
  per provider in the runlog — a provider that 400s on `response_format`+tools
  will show `rf_dropped: true` and should get `supports_json_object: false`.
- Two pre-existing `test_file_context.sh` failures (`< /file>` defuse rendering)
  reproduce on pristine HEAD `26f338e`; not introduced here.

## 2026-08-27 — outages are not arm evidence

claude-skills-31 flagged that OpenRouter's balance was at −$0.06 during the first live `read` rounds (PRs #107/#109/#121). Those rows landed as `status failed, failure_kind null, tokens null, output 0, steps 0` — byte-identical to "the read arm broke this model", and three of them on one seat would have demoted `read` for it.

Fix (same branch):
- `lib_tool_loop.sh tl_classify_api_error <resp>` names the failure from the error body: `provider_billing` (402 / credits / balance), `provider_rate_limited` (429), `provider_auth` (401/403), else `provider_error`; a non-timeout curl failure is `transport_error`. Both the loop (`TL_FAILURE_KIND`) and the single-shot lane write it to `meta.failure_kind`.
- `tool_policy.sh` excludes those kinds plus `quota_exhausted`, and — for rows written before the classifier — any `failed` row with no `failure_kind`, no `tokens_prompt`, and no output. Reported as `excluded_runs`, never scored. A generic `provider_error` stays a sample: "tools not supported on this route" is exactly what demotion is for.
- Tests: `test_tool_loop.sh` shim modes `bill402` / `err400` (both lanes classify; the learner ignores the 402 row), `test_tool_policy.sh` billing / legacy / provider_error / quota cases; the demotion fixture now models a model that answered then broke (`tokens_prompt` set).

