# Cross-review model performance vs cost — 2026-08-29

Follows [investigation-reviewer-seat-audit.md](investigation-reviewer-seat-audit.md)
(2026-08-27). That audit ranked seats on drop rate; this one ranks on **kept
findings per dollar and per minute of round wall-clock**, and separates the
since-bench window (the only one with a mature verification ledger) from the
full stamped era.

Sources: `cross-review/runlog.jsonl` (1,505 structured rounds; token/cost
stamping begins 2026-07-04 → 975 rounds in the "era"), `finding_events.jsonl`
(2,035 proposed findings), `references/reviewer_profiles.json` pricing
snapshot, live `GET /api/v1/credits` on the OpenRouter key.

Cost definition: billed `cost_usd` (OpenRouter rows) plus tokens × profile
pricing where a row has tokens but no bill. First-party CLI lanes (codex
primary, agy Gemini seats, kimi primary on Moonshot) stamp neither, so their
marginal $ is 0 here — their cost is **wall-clock** and **quota**, both
measured below.

## Headline

1. **Money is still small — $41.17 over 975 rounds, $0.011/PR median — but
   20% of it ($8.12) landed in the last three days** through 48 codex
   `account_limit` fallbacks onto metered `openai/gpt-5.6-sol`. Codex went
   from 75% ok / $0.012/run (era) to **61% ok / $0.061/run / 310s p50**
   since the bench. The global `model_reasoning_effort = "xhigh"` in
   `~/.codex/config.toml` is burning the CLI quota; the per-pass ladder
   shipped 2026-08-29 but has not had a chance to show up yet.
2. **The OpenRouter key is at −$0.09 live** (4,377.20 credited / 4,377.29
   used). Cross-review has stamped $41 lifetime on it — ~1% of the key's
   usage — so whatever else drains it collapses review rosters. Tonight:
   14 codex-only rounds and 12 two-seat rounds out of the last 30.
   A one-seat round is not a cross-review; some of them stamped `CLEAN`.
3. **The two free Google seats are the best value in the fleet, and it isn't
   close.** Since the bench, gemini-pro and antigravity each kept ~80
   findings, 35 Critical/High apiece, **29–33 provider-solo C/H each**, at
   5–7% drop, 100% ok, $0. Antigravity now has 75 seats on the 3.7 Flash
   pin — the 08-27 "under-observed" caveat is lifted.
4. **`draw_boost 2.5` is currently sitting on the five worst cost/value paid
   seats** (grok, deepseek, seed, longcat, inkling) while the three best paid
   seats (glm, spark, minimax) draw at 1.0. The boosts are the cost problem.
5. **Passes ≥5 have produced zero kept findings across 60 rounds era-wide.**
   Tonight's butlertron3 PRs ran 18, 15 and 14 passes for ~$5 and ~5 h of
   reviewer wall time. The repeat-pass guard on this branch is the right
   lever.

## Fleet since the 08-27 bench (183 rounds, ledger 1–24% unresolved)

`kept`/`drop` are terminal ledger events; `soloCH` = kept Critical/High with
no other *provider* aboard; `min/kept` = summed seat wall minutes ÷ kept.

| seat | att | ok% | fb | p50s | $total | $/run | kept | drop% | keptCH | soloCH | $/kept | $/keptCH | min/kept | boost |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| gemini-pro | 63 | 100 | 0 | 242 | 0 | 0 | 82 | 7 | 35 | 33 | 0 | 0 | 3.3 | 2.5 |
| antigravity | 75 | 100 | 0 | 80 | 0 | 0 | 79 | 5 | 35 | 29 | 0 | 0 | 1.3 | 1.0 |
| codex | 137 | 61 | 48 | 310 | 8.41 | 0.061 | 116 | 3 | 25 | 8 | 0.07 | 0.34 | 6.2 | baseline |
| kimi | 123 | 84 | 11 | 258 | 0.72 | 0.006 | 111 | 8 | 13 | 3 | 0.01 | 0.06 | 5.6 | baseline |
| glm | 7 | 86 | 0 | 262 | 1.21 | 0.173 | 13 | 0 | 4 | 1 | 0.09 | 0.30 | 1.8 | 1.0 |
| spark | 10 | 90 | 0 | 51 | 0.75 | 0.075 | 14 | 26 | 6 | 1 | 0.05 | 0.13 | 0.5 | 1.0 |
| minimax | 10 | 80 | 0 | 134 | 0.46 | 0.046 | 13 | 24 | 3 | 1 | 0.04 | 0.15 | 1.5 | 1.0 |
| seed | 48 | 92 | 0 | 70 | 2.18 | 0.045 | 7 | 0 | 1 | 0 | 0.31 | 2.18 | 9.1 | 2.5 |
| grok | 15 | 93 | 0 | 203 | 4.74 | 0.316 | 5 | 0 | 0 | 0 | 0.95 | — | 14.2 | 2.5 |
| deepseek | 18 | 56 | 0 | 286 | 1.96 | 0.109 | 6 | 40 | 0 | 0 | 0.33 | — | 15.3 | 2.5 |
| kat | 11 | 82 | 0 | 150 | 1.05 | 0.095 | 3 | 25 | 0 | 0 | 0.35 | — | 11.9 | 1.0 |
| inkling | 19 | 47 | 0 | 13 | 0.99 | 0.052 | 2 | 50 | 1 | 0 | 0.49 | 0.99 | 11.1 | 2.5 |
| longcat | 12 | 58 | 0 | 516 | 0.33 | 0.028 | 1 | 0 | 0 | 0 | 0.33 | — | 81.1 | 2.5 |
| laguna | 4 | 100 | 0 | 92 | 0.05 | 0.012 | 1 | 0 | 0 | 0 | 0.05 | — | 8.1 | 0.2 |
| mimo | 5 | 100 | 0 | 7 | 0.04 | 0.008 | 0 | — | 0 | 0 | — | — | — | 0.2 |
| kimi3 | 4 | 50 | 2 | 156 | 0.36 | 0.089 | 0 | 100 | 0 | 0 | — | — | — | 1.0 |
| nemotron | 4 | 50 | 0 | 246 | 0 | 0 | 0 | — | 0 | 0 | — | — | — | 0 |
| qwen / devstral / north / kimi27 | ≤2 | — | | | | | 0 | | | | | | | 0.2 |

Read across the paid rows: **glm, spark, minimax** are the only paid seats
that returned Critical/High findings since the bench, and they did it at
$0.13–0.30 per C/H and ≤1.8 min per kept finding. **grok** cost $4.74 for
5 kept and no C/H — 12× the fleet's median per-run cost. **seed** was drawn
48 times (boost 2.5) for 7 kept and 1 C/H. **deepseek** and **inkling** are
below 60% ok *and* above 40% drop — the round waits on them, then discards
what they say.

## Fleet over the stamped era (975 rounds) — for drop% and reliability only

The ledger is 70–100% unresolved on most days before 2026-08-27 (terminal
events were only stamped consistently after the #88–#98 telemetry rounds),
so era-wide `kept` under-counts and era-wide `$/kept` over-states. Use this
table for `ok%`, `p50`, `drop%` and total spend; use the since-bench table
for value.

| seat | att | ok% | fb | p50s | $total | prop | kept | drop% | keptCH | soloCH |
|---|---|---|---|---|---|---|---|---|---|---|
| kimi | 864 | 95 | 11 | 75 | 0.73 | 495 | 177 | 9 | 22 | 4 |
| codex | 859 | 75 | 84 | 81 | 9.90 | 411 | 161 | 2 | 50 | 20 |
| antigravity | 200 | 94 | 0 | 71 | 0 | 180 | 96 | 7 | 42 | 30 |
| deepseek | 199 | 94 | 0 | 53 | 4.04 | 74 | 13 | 28 | 3 | 0 |
| kat | 187 | 98 | 0 | 4 | 2.32 | 54 | 9 | 10 | 2 | 0 |
| glm | 187 | 94 | 0 | 46 | 5.86 | 80 | 19 | 0 | 6 | 1 |
| gemini-pro | 176 | 94 | 0 | 206 | 0 | 193 | 91 | 6 | 38 | 33 |
| minimax | 158 | 96 | 0 | 26 | 1.85 | 84 | 25 | 31 | 8 | 1 |
| kimi3 | 130 | 90 | 2 | 237 | 0.36 | 79 | 4 | 33 | 0 | 0 |
| nemotron | 119 | 91 | 0 | 98 | 0 | 42 | 11 | 8 | 4 | 2 |
| spark | 117 | 98 | 0 | 13 | 2.94 | 30 | 18 | 22 | 7 | 1 |
| qwen | 106 | 99 | 0 | 8 | 0.38 | 57 | 5 | 17 | 2 | 0 |
| seed | 76 | 84 | 0 | 69 | 2.70 | 18 | 12 | 8 | 2 | 1 |
| laguna | 75 | 99 | 0 | 25 | 0.24 | 28 | 3 | 0 | 1 | 0 |
| kimi27 | 66 | 82 | 0 | 248 | 0 | 45 | 8 | 20 | 1 | 0 |
| devstral | 59 | 98 | 0 | 10 | 0.33 | 14 | 1 | 50 | 0 | 0 |
| mimo | 59 | 86 | 0 | 18 | 0.33 | 39 | 12 | 0 | 4 | 1 |
| grok | 51 | 96 | 0 | 150 | 6.64 | 32 | 7 | 0 | 2 | 0 |
| north | 46 | 83 | 0 | 192 | 0 | 11 | 4 | 20 | 3 | 0 |
| inkling | 35 | 71 | 0 | 66 | 2.09 | 14 | 2 | 60 | 1 | 0 |
| longcat | 30 | 73 | 0 | 144 | 0.46 | 7 | 5 | 0 | 1 | 0 |

Total era spend **$41.17**. grok alone is 16% of it for 7 kept findings.

## Wall-clock: who the round waits on

Computed slowest lane per round, and the minutes it added beyond the
second-slowest seat (era):

| seat | rounds slowest | extra minutes |
|---|---|---|
| codex | 338 | +819 |
| kimi | 197 | +374 |
| gemini-pro | 81 | +235 |
| kimi3 | 81 | +236 |
| kimi27 | 40 | +104 |
| nemotron | 35 | +75 |
| glm | 27 | +72 |
| north | 22 | +69 |
| deepseek | 34 | +65 |
| antigravity | 18 | +65 |

The round waits on the **baselines**, not the rotation. Codex's p50 moved
from 81s (era) to 310s (since bench) — tools-mode context (`tokens/diff-line`
828 vs 53 unstamped), xhigh effort, and the fallback retry all stack on the
critical path. Antigravity is the fastest high-yield seat at 80s p50.

## Per-pass returns (era, 975 rounds)

| pass | rounds | $/round | kept (ledgered rounds) | kept C/H | wall min/round | seats/round |
|---|---|---|---|---|---|---|
| 1 | 490 | 0.046 | 348 | 92 | 4.6 | 4.2 |
| 2 | 245 | 0.032 | 151 | 27 | 4.4 | 3.7 |
| 3 | 146 | 0.032 | 70 | 10 | 4.0 | 3.6 |
| 4 | 34 | 0.052 | 21 | 2 | 4.4 | 3.9 |
| 5 | 19 | 0.052 | 0 | 0 | 6.1 | 3.8 |
| 6–7 | 15 | 0.10 | 0 | 0 | 8.6 | 3.7 |
| 8+ | 26 | 0.052 | 0 | 0 | 10.3 | 2.4 |

Kept-per-round holds at ~1.7–2.6 through pass 4 and then goes to zero while
wall time per round doubles. PR-level: passes p50 2, p90 3, **max 18**;
$/PR p50 0.011, p90 0.21, max $2.66 (butlertron3 #212, 15 passes, 0 kept
findings ledgered, 175 reviewer-minutes). Tonight's three butlertron3 PRs
(#209 ×14, #212 ×15, #214 ×18) are the entire top of the cost table.

## Codex: the cost profile flipped

Since the bench, 137 codex attempts: 83 ok, **48 fallback (`account_limit`)**,
5 failed (`account_limit`), 1 timeout. Every fallback is billed on OpenRouter
at ~$0.17/run (median 167k tokens in tools mode) and ran at whatever effort
OpenRouter defaults to, not xhigh. $8.12 of the $9.90 codex has ever cost
is from these three days.

`measure_codex_effort.sh` (ladder shipped 2026-08-29) reports the after-window
at 47–50% `acct_limit` on passes 1–2 vs 3–4% before — but that is the quota
state of the machine, not the ladder's effect; the cells are starred (<20
runs) and the tool itself says not to read them yet. What the ladder cannot
fix: the runlog **does not stamp the effort a codex run used**, so the
measurement is a duration proxy. Add `reasoning_effort` to the codex attempt
stamp in `append_runlog.sh` and this becomes a direct read.

Related stamping gap: primary-lane codex/kimi rows stamp `model: null` (only
the fallback path sets it). `leaderboard.sh --recent 60` therefore shows
codex with `model: null` on 60/60 rows and treats the primary lane as a
"legacy" epoch. It doesn't change the ranking today, but it will the moment
the codex CLI model changes.

## What the ledger cannot see

- Fact-check / adjudication cost (Claude tokens spent disproving findings)
  is not recorded. `drop%` is the proxy: a seat at 40–60% drop costs an
  adjudication pass for every other finding it makes.
- `unresolved` findings (300 for kimi, 247 for codex era-wide) are excluded
  from the kept/drop denominators, matching `severity_calibration.sh`.
- Pricing is null for deepseek/mimo/minimax/kimi27/kimi3, but those seats
  are billed directly (`b191` etc.), so nothing is missing from their totals.

## Recommendations (not applied — assessment only)

1. **Fund a cross-review-only OpenRouter key.** The shared key's other
   consumers took the fleet to codex-only tonight. Until then, the
   `baselines-only-openrouter-billing` policy should refuse to stamp `CLEAN`
   on a round with fewer than two seats delivered.
2. **Stop paying for codex fallback at pass ≥3.** 48 fallbacks / $8.12 in
   three days is the single largest new cost. Either drop the global
   `xhigh` to `high` (the ladder already steps per pass) or make the
   fallback lane pass-1/2 only — on pass ≥3 a missing codex verdict is
   cheaper than a $0.17 metered one.
3. **Rebalance `draw_boost`** on the since-bench evidence:
   - grok 2.5 → 0.5 (most expensive seat, no C/H since bench, 2 C/H in 51 era seats)
   - inkling 2.5 → 0.2 + bench_note (47% ok, 50% drop, $0.49/kept)
   - deepseek 2.5 → 0.5 (56% ok, 40% drop, 0 C/H)
   - seed 2.5 → 1.0 (48 draws for 1 C/H)
   - longcat 2.5 → 1.0 (58% ok, 516s p50)
   - glm 1.0 → 2.5 (only paid seat with 0% drop and 4 C/H; 86% ok since bench — the 08-27 "31% ok" reliability bug looks resolved on this pin)
   - spark 1.0 → 1.5, minimax hold at 1.0 (good yield, 25% drop)
   - antigravity 1.0 → 2.5 to match gemini-pro: free, 100% ok, 80s, 29 solo C/H
4. **Cap re-passes at 4 unless pass N−1 kept a new finding** — that is the
   repeat-pass guard on this branch; the per-pass table is its justification.
5. **Telemetry:** stamp `reasoning_effort` and primary-lane `model` on
   codex/kimi rows so the next assessment reads effort directly.

## Method notes

- Scripts in the session scratchpad (`common.py`) recompute everything from
  the raw ledgers; numbers were cross-checked against
  `leaderboard.sh --recent 200 --mode report` and
  `measure_codex_effort.sh`. Where they differ (codex ok% 84/154 in the
  leaderboard's 200-window vs 61% since bench) the difference is the window.
- "Since bench" = rounds with `ts >= 2026-08-27T12:00Z`.
- Solo credit is by *provider*, matching `leaderboard.sh` (kimi+kimi3 is one
  Moonshot vote).

## Applied 2026-08-30 — deprecations

Convention from the 08-27 audit: OpenRouter seats stay wired (the seat-wiring
invariant needs them at every dispatch site); a bench is `bench_note` +
`draw_boost ≤ 0.3` (test-enforced), a retirement is `draw_boost 0` (never
drawn, enforced at the weight since #99).

| seat | draw_boost | action |
|---|---|---|
| inkling | 2.5 → **0** | retired — <60% ok and >40% drop at once, $0.49/kept |
| deepseek | 2.5 → **0.2** | throttled — 40% drop, 0 C/H since bench, $0.31/kept era |
| grok | 2.5 → **0.2** | throttled on cost — $0.32/run, $0.95/kept, 16% of all spend for 7 kept |
| seed | 2.5 → **1.0** | bring-up boost retired — 48 draws for 1 C/H |
| longcat | 2.5 → **1.0** | bring-up boost retired — 58% ok, 516s p50 |
| north | 0.2 (unchanged) | already benched 08-03; only 2 draws since 08-27 — test pins it at 0.2 |
| nemotron | 0 (unchanged) | already retired 08-27 |

Not touched, and why:

- **kimi3** — 33% drop, 4 kept of 79 proposed, slowest lane in 81 rounds.
  A throttle candidate, but `tests/test_profiles.sh` pins `kimi3.draw_boost
  == 1.0` (retired-bring-up assertion) — changing it means changing the test's
  intent, which belongs in its own PR.
- **glm / spark / minimax promotions** — the three best paid seats, but
  `run_tests.sh` uses glm+minimax as the no-boost cost-divisor control and
  spark as the rookie-weight control. Promoting any of them needs the
  control seats re-homed first.
- **antigravity → 2.5** — free, 100% ok, 80s, 29 solo C/H; promotion is a
  separate decision from deprecation, deferred.
