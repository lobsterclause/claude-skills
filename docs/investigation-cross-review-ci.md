# cross-review → CI: roster diff and de-fork plan

Date: 2026-08-16
Scope: `lobsterclause/claude-skills:cross-review/` (the skill) vs
`Not-Every-Mom/kindred-mama-ai:scripts/agent-cross-review.sh` +
`scripts/cross-review-currency.sh` (the CI translation).
Status: investigation only. No code changed.

---

## 0. Correction to the working assumption

The premise going in was "the GHA translation forked the roster and the slugs
have drifted." **The slugs have not drifted.** All eleven OpenRouter seats are
byte-identical between `reviewer_profiles.json` and the `REVIEWER_MODEL` table
in `agent-cross-review.sh`:

```
match  deepseek   deepseek/deepseek-v4-flash
match  devstral   mistralai/mistral-large-2512
match  glm        z-ai/glm-5.2
match  kat        kwaipilot/kat-coder-pro-v2
match  laguna     poolside/laguna-s-2.1
match  mimo       xiaomi/mimo-v2.5
match  minimax    minimax/minimax-m3
match  nemotron   nvidia/nemotron-3-ultra-550b-a55b:free
match  north      cohere/north-mini-code:free
match  qwen       qwen/qwen3-coder-next
match  spark      meta/muse-spark-1.1
```

So the de-fork case rests on *structural* duplication and on one stale
invariant (§2), not on an active slug bug. That makes it lower-urgency than
stated in conversation, and worth doing on its merits rather than as a fire.

## 1. Roster: what CI deliberately drops

Six skill seats are absent from CI, and all six absences are justified in the
script's own header:

| Seat | Transport | In CI? | Reason |
|---|---|---|---|
| `codex` | OpenAI CLI | no | needs its own auth; no headless credential path |
| `kimi` / `kimi27` / `kimi3` | Moonshot direct | no | second API key; "three distinct providers" rule already satisfied |
| `antigravity` / `gemini-pro` | `agy` CLI | no | needs interactive `agy login`; shares one exhaustible quota that **fails by returning rc=0 with empty stdout** |

That last failure mode is the same class as the bug fixed on the current
branch (`b58535b`, codex quota exhaustion reported as rc=1). Both are
"reviewer died but the transport says fine." The CI script sidesteps it by
admitting only one transport (curl → OpenRouter) and one secret.

**The real roster difference is selection, not membership.** The skill draws a
leaderboard-weighted random roster via `select_roster.sh` and feeds outcomes
back through `leaderboard.sh` / `finding_events.jsonl`. CI uses a hardcoded
`REVIEWERS="glm,deepseek,qwen"` — a fixed 3-of-11, chosen once. Consequences:

1. CI runs generate zero leaderboard signal. `grep -ci leaderboard` on
   `agent-cross-review.sh` → **0**. Same for `runlog`, `finding_event`,
   `fingerprint`, `digest`.
2. The eight unused seats never accumulate CI evidence, so the leaderboard can
   never learn whether they are better *in the headless setting* — which is a
   different question from how they score interactively (no repo access, no
   tool use, diff-only).
3. The Goodhart precision-discount work in `leaderboard.sh` (PR #58) is
   invisible to the highest-volume caller.

## 2. The header invariant is stale — a real finding

`agent-cross-review.sh`'s header states the design contract in strong terms:

> So this script fans out reviewers and stops. It does not post findings to the
> PR, does not request changes, and does not gate merge. Findings land in a
> build artifact marked UNVERIFIED. […] Automating the fan-out is cheap;
> automating the verdict would just industrialise false Criticals.

The script no longer only fans out. It now contains a full adjudication panel:

```
ADJUDICATE=false                                    # line 84
ADJUDICATORS="minimax,kat,mimo,devstral,laguna"     # line 100
run_adjudicator() adjudicate_one() adjudicate_findings()
tally_verdict() adjudication_panel_healthy()
```

Findings get `.adjudication.verdict ∈ {refuted, inconclusive, …}` and a dead
panel is a hard `failed / adjudicator-panel-dead` outcome rather than a silent
pass. This is *good* — it is the majority-refute pattern, and gating on panel
health is exactly right. But:

- It is opt-in (`--adjudicate`, default false), so which mode CI actually runs
  in is set at the call site, not visible from the contract.
- The header still reads as though the verdict step does not exist, which is
  the doc that a future reader (agent or human) will trust.

**Fix regardless of the de-fork decision:** rewrite the header to describe the
two modes and say which one the workflow invokes. ~20 min.

## 3. Capability matrix

| Concern | skill | CI script | Note |
|---|---|---|---|
| Model preflight vs live catalog | `validate_or_models.sh` | `preflight_models()` | duplicated |
| Fan-out + per-reviewer timeout | `run_reviewers.sh` | `run_reviewer()` | duplicated |
| Parse reviewer JSON | `merge_raw_findings.sh` | `parse_reviewer_response()` | duplicated |
| Dedupe / convergence | `fingerprint_findings.sh` | `merge_findings()` (8 convergence refs) | duplicated, different algorithms |
| Verdict pass | `factcheck_findings.sh` | `adjudicate_findings()` | duplicated, different voting rules |
| Human-readable summary | `report_block.sh` | `render_summary()` | duplicated |
| Line anchoring | `anchor_findings.sh` | 4 refs, no dedicated pass | partial |
| Secret-ish diff refusal | (asks the human) | `secret_paths()` — refuses | **CI-only, should be shared** |
| Ingest other bots' reviews | — | `ingest_bot_reviews()` (codex-app, coderabbit) | **CI-only, valuable** |
| Isolated worktree | `worktree.sh` (348 ln) | — | skill-only, correct |
| Leaderboard / runlog / events | 4 scripts | — | skill-only, **should be shared** |
| Repo digest for reviewer context | `digest_context.sh` | — | skill-only |
| Merge gate | `hooks/merge_gate.sh` (PreToolUse) | `cross-review-currency.sh` (490 ln) | **complementary, not duplicate** |

Line counts: skill `scripts/` ≈ 5,981 · `agent-cross-review.sh` 1,107 (+1,131
test) · `cross-review-currency.sh` 490 (+999 test).

Six duplicated concerns, two of them (dedupe, verdict) implemented with
*different* algorithms. That is the drift surface. Today it produces no visible
bug; it means a fix like PR #58's precision discount lands in one place and
silently does not apply to the other.

## 4. The currency gate is the best idea in the CI translation

`cross-review-currency.yml` asserts the newest review record is bound to the
head SHA about to merge. Its header argues its own necessity:

> The cross-review skill has a PreToolUse hook that refuses `gh pr merge` when
> the record is stale. A hook binds only the agent that runs it: it cannot see
> a merge inside a shell script, a GraphQL mergePullRequest mutation, the web
> UI, or automerge. This check is computed from PR state, so it covers all
> four — and it covers humans.

That is the verification-first ladder applied exactly: advisory prose → agent
hook → repo-side machine check that binds every actor. It also fires on
`issue_comment` so a re-review can clear a red check without an empty commit.

**This should be promoted out of kindred-mama-ai and shipped from this repo**
as an installable workflow, independent of anything else here. It is the single
highest-value piece and it has no dependency on the de-fork.

## 5. Proposed `crv` surface

One entrypoint, both callers behind it. Skill and workflow become thin.

```
crv preflight  --models <csv>            → validated slugs        (was validate_or_models.sh / preflight_models)
crv roster     [--headless] [--n 3]      → csv of seats           (was select_roster.sh / hardcoded REVIEWERS)
crv guard      --diff <file>             → ok | refuse:<reason>   (was secret_paths, generalized)
crv run        --roster <csv> --diff <f> → <dir>/<slug>.json      (was run_reviewers.sh / run_reviewer)
crv ingest     --pr <n>                  → <dir>/<slug>.json      (was ingest_bot_reviews — now available to the skill)
crv merge      <dir>                     → findings.json          (was merge_raw_findings + fingerprint_findings)
crv anchor     <findings> --repo <path>  → anchored findings      (was anchor_findings.sh)
crv verdict    <findings> --panel <csv>  → adjudicated findings   (was factcheck_findings / adjudicate_findings)
crv report     <findings>                → report block           (was report_block.sh / render_summary)
crv record     <findings> --outcome <o>  → runlog + finding_events (was append_runlog / append_finding_event)
crv currency   --pr <n>                  → pass | stale:<sha>     (was cross-review-currency.sh)
```

`--headless` on `roster` is the whole trick: it filters to curl-only transports
(drops codex, the three Moonshot seats, both agy seats) while still applying
leaderboard weighting and the distinct-provider rule. CI stops being a
hardcoded triple and starts feeding the leaderboard.

**Caller split after the change**

| Stays in the skill (`SKILL.md` prose) | Stays in the workflow YAML |
|---|---|
| worktree lifecycle, `digest_context`, agy shell gate | receipt comment carrying head SHA (idempotency) |
| the apply-fixes → re-review iteration loop | artifact upload, `UNVERIFIED` marking |
| asking the human about a `crv guard` refusal | refusing outright on a `crv guard` refusal |
| interactive roster/reviewer health reporting | concurrency group, permissions, self-test job |

Everything else is a `crv` call from both sides.

**Rough cost:** `crv` scaffold + `preflight`/`roster`/`guard` ≈ 3 h. `run`/
`merge`/`verdict` ≈ 4 h (two algorithms to reconcile — pick the skill's
fingerprinting, pick CI's panel-health gate). `report`/`record`/`currency`
≈ 2 h. Porting both callers ≈ 2 h. Call it **2 focused days**, and the
existing 1,131 + 999 + `cross-review/tests/` cases are the safety net.

## 6. Recommended order

1. **Fix the stale header** in `agent-cross-review.sh` (§2). 20 min, no
   dependencies, removes a misleading contract.
2. **Promote `cross-review-currency.*` into this repo** as an installable
   workflow + its 999-line harness. Highest value, zero coupling.
3. **`crv roster --headless`** alone, ported into both callers. Smallest change
   that ends the selection fork and starts CI leaderboard feedback.
4. **Reconcile dedupe + verdict** into `crv merge` / `crv verdict`. The real
   work; do it only after 3 proves the shared-binary shape holds.
5. **Enable the cron** (`agent-cross-review.yml:77-78`, `0 */4 * * *`) once CI
   runs are feeding the leaderboard — not before, or four hours of unattended
   runs a day produce no learning signal.

## 7. Open question

Should `crv` live in this repo (skill-adjacent, versioned with
`reviewer_profiles.json`) or as its own installable? Skill-adjacent is simpler
and keeps the profile JSON as the one roster source of truth; standalone is
what you need if a third caller (another repo's workflow) ever appears. Default
to skill-adjacent until a third caller exists.
