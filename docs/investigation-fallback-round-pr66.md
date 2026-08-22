# PR #66 cross-review — findings and dispositions

Round: codex (via fallback), kimi (fallback failed), nemotron, inkling, glm.
Head reviewed: `f246beb` vs `b7e00f1`. 12 files, 674 lines.

## Convergent (codex + glm — OpenAI and Zhipu, two independent providers)

1. **[P1] fallback_eligible substring matching false-positives.**
   Bare `429`/`401`/`403`/`authentication` anywhere in the first 4KB of
   stdout+stderr classifies a lap as an account wall. Review prose about auth
   code, byte counts, or a timing like `4290ms` contains these routinely — and
   this repo's own files contain them. Consequence: an ordinary crash triggers a
   *paid* OpenRouter re-run, a false "PRIMARY PROVIDER NEEDS ATTENTION" warning,
   and a runlog `fallback` status with a wrong reason — corrupting the exact
   reliability record the feature exists to keep honest.

2. **[P1] rc==3 is mapped to agy quota for every seat.**
   Exit 3 is documented only as agy's quota signal, but maybe_or_fallback applies
   it to codex/kimi/kimi3 too. Any of them exiting 3 for an unrelated reason gets
   a paid re-run mislabelled `quota_exhausted`.

## codex solo

3. **[P1] `fallback.used: true` is stamped regardless of the fallback's own rc.**
   A failed fallback records as a successful one. **Live instance in this round:**
   kimi's fallback returned rc=5 with 0 bytes and still wrote `used: true`, so
   append_runlog classifies it `fallback` instead of `failed`. This is the same
   record-dishonesty the feature was written to prevent, one layer down.

## glm solo

4. **[P1] Primary artifacts are renamed before the fallback is known runnable.**
   If the OpenRouter key is missing, run_openrouter_reviewer returns early
   without writing meta — the primary's meta.json has already been moved, so
   failure_kind telemetry is lost and a quota/panic lane degrades to a generic
   `failed` with no reason.

5. **[P2] The shipped config contradicts its own prose.** antigravity and
   gemini-pro notes still say `NO FALLBACK (policy 2026-07-01)` while those same
   objects now set `or_fallback.enabled: true`; run_reviewers.sh keeps
   "No fallback by policy" directly above the new maybe_or_fallback call.
   SKILL.md was updated; the per-seat notes and inline comments were not.

6. **[P2] The new tests grep source text, not behaviour.** The 124/137 guard
   pattern still matches if the guard is negated; `grep maybe_or_fallback` passes
   even if the call is unreachable. An inverted implementation passes all three.
   (Third instance this session of a check that cannot fail properly.)

7. **[P2] The "leaderboard does not count a fallback as ok" test never runs
   leaderboard.sh** — it re-queries the runlog, re-testing the append_runlog
   branch asserted two lines above. The documented claim (reliability drops) is
   untested.

8. **[P2] codex's primary model is not pinned**, so SKILL.md's "same model"
   guarantee is an unverified guess that breaks silently whenever the codex CLI
   default moves — the precise blind spot `cli_model_alias` was introduced to fix
   for kimi, left open on the other baseline.

9. **[P2] The kimi alias is a silent recurring cost.** On a machine without
   `[models.kimi-k27-code]`, the lane fails and or_fallback converts it into a
   recurring *paid* OpenRouter run at `status: fallback`, rather than a loud
   config error.

## Reviewer notes

- **codex ran only because of the feature under review** — its OpenAI account is
  capped until 2026-08-27. First codex review of the day; 2,163 completion
  tokens, $0.07. It found the `used: true` bug that the round itself then
  demonstrated live.
- **kimi's fallback was itself a no-op**: moonshotai/kimi-k2.7-code returned 6
  completion tokens and 0 bytes. Not a vote.
- **nemotron** (14,697 reasoning tokens, free) and **inkling** (11,076 reasoning)
  both did real work and returned clean.
- **glm 5.3** again the highest-yield reviewer: 25,839 reasoning tokens, $0.149,
  8 findings, all verified real.

## 2026-08-22 — the health analyzer did not know the status the feature emits

Found by *using* the pre-run check rather than reading it. `analyze_runlog.sh
--mode warn` answered "all reviewers nominal" on a window in which codex's
OpenAI account was dead and every codex review had been served by the
OpenRouter rescue.

Two separate causes, both real:

1. **The installed skill lags the repo.** `~/.claude/skills/cross-review/`
   has no `fallback` branch in `append_runlog.sh` — that is #66's unmerged
   work — so the 21:02 round recorded codex as `status: "ok"` with a
   `fallback` object hanging off it. Nothing downstream looked at the object.

2. **The analyzer buckets a closed set.** `ok / timed_out / empty / failed /
   quota`. `status: "fallback"` matches none of them, yet still counts toward
   `$attempts`. A seat rescued on every run therefore reports
   `total: N, ok: 0, failed: 0` — it inflates every rate denominator with no
   numerator, and renders as `reliability 0% (ok=0, timeout=0, empty=0,
   failed=0, quota=0)`: a warning that names no cause and no remedy.

This is the fourth instance this round of the same class — a producer invents
a value and a consumer enumerating the old set drops it silently
(`.attempt<N>`, `.agy-failed`, `.primary-failed`, now `status:"fallback"`).

**Fix.** A `fallback` bucket; the count surfaced next to `ok` in both report
and reliability-WARN lines; and a dedicated WARN placed *above* the
`.total < 3` sample guard. The placement is the point: every other warning is
a statistical claim and deserves a minimum sample, but this one reports a
provider account that is dead right now, and the user asked to be warned each
time. Sample-gating it would rebuild the hole — the dispatch-time warning goes
to stderr nobody re-reads, and the pre-run check is the only surface consulted
before spending the next round.

Reliability counts a rescue as **served** (a usable review did come back), so a
billing outage does not drag the leaderboard draw or timeout tuning. The
degradation rides on the WARN, where it names something a human can fix.

### A remedy I nearly shipped, falsified before it landed

The first draft of that WARN advised: *"verify the fallback model is a
DIFFERENT provider — routing the dead provider's own model through OpenRouter
buys nothing."* Plausible, and wrong. Probed live:

- `moonshotai/kimi-k2.7-code` over OpenRouter answers normally
  (`finish: "stop"`, `content: " ALIVE"`). OpenRouter bills Moonshot through
  its own account, so a suspended personal Moonshot key does not disable it.
- The seat's real failure is budget: it is a reasoning model, and at
  `max_tokens: 20` the reasoning consumes the completion allowance and
  `content` comes back `null` (`completion: 20`, no text). At 64 it answers.

The advice would have sent the next reader to change a provider that is fine.
Removed. The WARN now claims only what was checked.

### Checked and *not* a bug

`tokens_completion: 15489` against `output_bytes: 17` (nemotron) looked like
the wrapper dropping a `reasoning`-only response. It is not: extraction is
`.choices[0].message.content // empty`, and 17 bytes is a real
`{"findings":[]}` after genuine reasoning. The no-op signal remains completion
count — `minimax` at 6 tokens and `qwen` at 9 did no thinking; `nemotron`
(15,489) and `inkling` (11,943) thought hard and found nothing. Only the first
kind is fake corroboration.

### Correction: the budget theory does not explain the real round either

The `max_tokens` finding above is true of my probe but **not** the cause of
kimi's failed rescue on 2026-08-22, because `run_reviewers.sh` sends no
`max_tokens` at all. Probed both request shapes against the live endpoint:

| request | finish | content bytes | completion tokens |
|---|---|---|---|
| with `response_format: json_object` | stop | 16 | 37 |
| without `response_format`           | stop | 16 | 67 |

Both healthy, so it is not the `seed`-class `response_format` rejection
either. What remains established is only the negative: **the seat is alive on
OpenRouter and the provider is not the problem.** Why the real round returned
rc=5 / 0 bytes / 6 completion tokens on a 19,448-token prompt is not yet
known, and is left named rather than guessed at.

Not a blocker for #66: `append_runlog.sh` already classifies a rescue that
itself failed as `failed`, not `fallback`, so this seat is not being counted
as a successful rescue. The open question is why the lane is flaky, not
whether the record lies about it.
