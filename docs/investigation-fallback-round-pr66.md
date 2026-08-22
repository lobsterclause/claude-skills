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
