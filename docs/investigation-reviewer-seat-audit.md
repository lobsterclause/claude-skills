# Cross-review reviewer seat audit — 2026-08-27

Method: every seat scored over its **full history but scoped to the model it is
currently pinned to**. A seat that swapped models carries no credit or blame
from the model it replaced. Sources: `cross-review/runlog.jsonl` (1,318 runs),
`cross-review/finding_events.jsonl` (1,409 proposed findings), live
OpenRouter model catalogue.

This supersedes the earlier 120-run-window read, which was unrepresentative:
it sampled gemini-pro at 10 seats out of its real 157, and grok at 8 out of 36.

## Fleet table (current pin only)

| seat | seats | ok% | findings | f/run | disproven | p50 | cost | $/find | solo | C/H |
|---|---|---|---|---|---|---|---|---|---|---|
| longcat | 18 | 83 | 8 | 0.5 | 0% | 85s | $0.13 | 0.016 | 3 | 1 |
| codex | 1246 | 88 | 451 | 0.4 | **2%** | 102s | $1.34 | 0.003 | 163 | 149 |
| gemini-pro | 157 | 85 | 152 | 1.1 | **10%** | 201s | $0 | 0 | 59 | 36 |
| kimi3 | 126 | 91 | 142 | 1.2 | 18% | 232s | $0 | 0 | 43 | 20 |
| kimi27 | 65 | 82 | 86 | 1.6 | 20% | 235s | $0 | 0 | 18 | 15 |
| grok | 36 | 97 | 30 | 0.9 | 23% | 109s | $1.90 | 0.063 | 8 | 7 |
| glm | 13 | **31** | 12 | **3.0** | 25% | 411s | $0.65 | 0.055 | 4 | 1 |
| kat | 23 | 100 | 12 | 0.5 | 25% | 64s | $0.77 | 0.064 | 2 | 1 |
| spark | 5 | 100 | 4 | 0.8 | 25% | 33s | $0.11 | 0.027 | 2 | 1 |
| minimax | 151 | 96 | 131 | 0.9 | 31% | 25s | $1.37 | 0.010 | 40 | 15 |
| kimi | 1233 | 97 | 673 | 0.6 | 33% | 64s | $0.01 | 0 | 215 | 69 |
| antigravity | 7 | 100 | 3 | 0.4 | 33% | 60s | $0 | 0 | 1 | 0 |
| deepseek | 33 | 91 | 27 | 0.9 | 37% | 142s | $1.68 | 0.062 | 8 | 3 |
| mimo | 59 | 81 | 56 | 1.2 | 38% | 19s | $0.29 | 0.005 | 15 | 6 |
| seed | 26 | **69** | 8 | 0.4 | 38% | 109s | $0.48 | 0.060 | 5 | 4 |
| inkling | 14 | 100 | 7 | 0.5 | 43% | 86s | $0.93 | **0.133** | 2 | 3 |
| laguna | 15 | 100 | 20 | 1.3 | 50% | 4s | $0.01 | 0 | 3 | 3 |
| qwen | 117 | 97 | 181 | 1.6 | **52%** | 10s | $0.29 | 0.002 | 40 | 26 |
| north | 55 | 76 | 33 | 0.8 | **58%** | 189s | $0 | 0 | 5 | 6 |
| devstral | 16 | 94 | 16 | 1.1 | **69%** | 8s | $0.06 | 0.004 | 4 | 5 |
| nemotron | 24 | 79 | 10 | 0.5 | **80%** | 160s | $0 | 0 | 6 | 5 |

Total fleet spend across the whole logged history is **~$10**. Money is not the
constraint anywhere; the currencies that matter are fact-check adjudication
effort (drop rate) and round wall-clock (p50, since the round waits on its
slowest lane).

## Pin staleness (OpenRouter seats, live catalogue)

Current pins, and whether anything newer exists in the same vendor namespace:

- **qwen** — pinned `qwen/qwen3-coder-next` (**2026-02-04**, ~6 months stale).
  The entire Qwen 3.8 family shipped since: `qwen3.8-flash` (2026-08-26,
  $0.16/$0.47), `qwen3.8-27b`, `qwen3.8-2.4t-a95b`, `qwen3.8-max`. Its 52%
  drop rate is being measured on a model two generations behind.
- **devstral** — pinned `mistralai/mistral-large-2512` (**2025-12-01**, ~9
  months stale) — and note the seat is *named* devstral while pointing at
  mistral-large. `mistralai/devstral-2512` exists and matches the seat's
  identity. Also newer: `mistral-medium-3-5` (2026-04-30).
- **mimo** — `xiaomi/mimo-v2.5` (2026-04-22); a `mimo-v2.5-pro` sibling exists
  at the same date.
- **glm, deepseek, kat, spark, seed, inkling** — newer entries exist but they
  are *smaller* variants (flash / air / small / contributor), i.e. sidegrades
  down the capability ladder, not upgrades. Leave pinned.
- **minimax, laguna, north, longcat, grok** — pin is the newest in its
  namespace. Nothing to do.

`x-ai/grok-4.6` (2026-08-12) is confirmed the latest xAI model on OpenRouter.

## Verdicts

### Retire / bench
- **nemotron** — 80% drop rate on its current model (3.5-lightning, pinned
  2026-08-14). The swap was its second chance and it came back worse than the
  3-ultra seat it replaced (34%). *Benched 2026-08-27.*
- **north** — 58% drop, 76% ok, 189s p50, free. Slow, unreliable and noisy at
  once; free does not offset a lane the round waits on. Already at boost 0.2.

### Re-pin, don't bench
- **qwen** → `qwen/qwen3.8-flash`. Worst drop rate after nemotron, but the pin
  is 6 months stale, and the seat is the fleet's cheapest/fastest breadth lane
  ($0.29 lifetime, 10s p50). Re-pin first; bench on the new evidence if 3.8
  does not fix it.
- **devstral** → `mistralai/devstral-2512`. 69% drop on a 9-month-old pin that
  does not even match the seat's name.

### Promote
- **gemini-pro** → `draw_boost 2.5`. 152 findings from 157 seats at a 10% drop
  rate, free — best precision in the fleet outside codex, and ~3x antigravity's
  per-seat yield. The shared-Google-quota risk is not real in the data: one
  `quota_exhausted` event across 592 combined agy seats, plus an OpenRouter
  fallback since 2026-08-22. Heavy boost rather than true baseline, because a
  preview-tier model should not sit on the fail-closed baseline path.

### Keep, verdict reversed from the earlier window read
- **grok** — 30 findings over 36 seats at 23% disproven, cleaner than the kimi
  baseline (33%), on the newest xAI model. The earlier "1 finding in 8 seats"
  was sampling noise. Stays.

### Investigate, do not bench
- **glm** — highest yield in the fleet (3.0 findings/run) but only **31% ok**
  on the current `z-ai/glm-5.3` pin over 13 seats, at a 411s p50. That is a
  reliability bug worth diagnosing, not a bad reviewer.
- **seed** — 69% ok over 26 seats, 0.4 findings/run. Watch.

### Under-observed — no verdict available
- **antigravity** — its 434-seat history spans Gemini 3.5 / 3.6 / 3.7 Flash.
  On the *current* 3.7 Flash pin (bumped 2026-08-22) it has only 7 seats and 3
  findings. Nothing can be concluded yet; let it accumulate.
- **spark** (5 seats), **inkling** (14), **laguna** (15), **kat** (23) — thin
  samples; inkling is the priciest seat per finding ($0.133) and worth a cost
  check once its sample grows.

## Applied 2026-08-27

- `scripts/select_roster.sh` — **nemotron benched** (removed from the OpenRouter
  POOL, kimi27 comment pattern, one line and reversible).
- `references/reviewer_profiles.json`:
  - **qwen** `qwen/qwen3-coder-next` → **`qwen/qwen3.8-27b`**. 3.8-flash was the
    price-optimal pick but 429'd on 2 of 3 live probes (shipped 2026-08-26, thin
    Alibaba capacity); a 429 drops the seat out of the round, which is the exact
    failure this re-pin exists to avoid. 3.8-27b served clean via Chutes and has
    two weeks of soak. draw_boost held at 0.2 while it earns a fresh record.
  - **devstral** `mistralai/mistral-large-2512` → **`mistralai/devstral-2512`**
    (live-probed, HTTP 200 via Mistral). draw_boost held at 0.2.
  - **gemini-pro** `draw_boost` → **2.5**. Heavy boost, not a third baseline.

Verification: `validate_or_models.sh` clean after a forced cache refresh (its
24h cache was 9h stale and predated the Qwen 3.8 flash listing — worth knowing
when a re-pin looks like it points at a nonexistent model).

## Follow-ups not actioned

- **glm reliability** — 31% ok over 13 seats at a 411s p50, while carrying the
  fleet's highest yield (3.0 findings/run). Diagnose the failure mode; this is
  the single highest-value open item in the fleet.
- **north** — 58% drop, 76% ok, 189s p50. Bench candidate on the nemotron
  rationale; left alone this pass to avoid thinning the pool in one sitting.
- **antigravity** — needs ~30 more seats on the 3.7 Flash pin before its record
  means anything.
- **inkling** — $0.133/finding, priciest in the fleet; revisit once n > 30.

## Bug found while applying the bench — draw_boost 0 did nothing

Benching nemotron surfaced two defects worth recording.

**1. The bench pattern I first used was wrong for this seat.** I copied the
kimi27 bench (remove from `POOL` in `select_roster.sh`). That works for kimi27
because it is a *Moonshot* seat, and the `tests/run_tests.sh` seat-wiring
invariant only enumerates *OpenRouter* seats — it requires every OR seat in the
profile to be present at all 10 dispatch sites, `POOL` included. Removing an OR
seat from POOL fails that invariant. The repo's actual convention for OR seats
is `bench_note` + a low `draw_boost`, keeping the seat wired (see mimo, qwen,
devstral, laguna, north, all at 0.2).

**2. `draw_boost: 0` silently meant "full weight", not "never draw".** The awk
weighting carried:

```awk
boost = (NF >= 7 ? $7 + 0 : 1)
if (boost <= 0) boost = 1
```

The guard was defending against a malformed field, but it also caught the
legitimate value 0 and handed that seat the **default weight of 1** — the exact
opposite of the profile. Observed live: nemotron pinned at 0 was still drawn 5
times in 40 rounds. This was invisible except by counting draws across dozens of
rounds, which is why it survived.

Fixed by validating the field's *shape* before coercing, so a well-formed
non-negative decimal is taken at face value (0 included) while genuine garbage
still falls back to 1 — the latter matters because `$7 + 0` coerces a typo like
`"abc"` to 0, which would otherwise retire a seat by accident.

Pinned by three new regression tests (`draw_boost 0` ⇒ weight 0; a 0-weight seat
is never selected across 25 seeds; `"abc"` / `-1` / `""` all fall back to 75.0),
plus a `CROSS_REVIEW_PROFILES` fixture override on `select_roster.sh` matching
the existing `CROSS_REVIEW_RUNLOG` contract, so the semantics can be pinned
without mutating the real profile.

**Verified:** nemotron now reports `boost=0 weight=0.0` and drew 0 times in 60
rounds; gemini-pro at its new 2.5 boost drew 37 of 60.

Also note: `tests/run_tests.sh` **exits 0 even when tests fail** — the first run
of this change reported `426 passed, 2 failed` under exit code 0. Read the
summary line, never the exit status.
