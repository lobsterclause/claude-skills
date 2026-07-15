---
name: cross-review
description: Run external AI code reviewers (codex CLI, Antigravity `agy` CLI on Gemini 3.5 Flash, the same `agy` CLI on Gemini 3.1 Pro, and kimi CLI) in parallel against the current branch's diff, synthesize deduped findings, auto-apply fixes, and iterate until clean. Use this skill whenever the user wants a second opinion on code, cross-review, swarm review, peer review, external review, or wants codex/antigravity/gemini/kimi to look at changes before shipping — even if they don't explicitly name the CLIs. Also trigger on "have codex check this", "get a second pair of eyes", "cross-check my changes", "review before merge", "swarm review", "review this PR", or right after Claude creates a PR. Do NOT trigger for routine lint/test runs, style-only checks, or when the user wants Claude itself (not external CLIs) to review.
---

# cross-review

Orchestrates four external AI reviewers — `codex`, `antigravity` (Antigravity `agy` CLI on Gemini 3.5 Flash, the fast lap), `gemini-pro` (the same `agy` CLI on Gemini 3.1 Pro, the deep lap), and `kimi` — to review the current branch's changes, consolidates their findings, applies fixes, and re-runs until the diff is clean or an iteration budget is exhausted. The goal is to catch things a single model would miss — different reviewers have different blind spots, so their overlap is signal and their disagreements are worth reading.

**On the Gemini fleet:** `antigravity` and `gemini-pro` are both Google-Gemini reviewers running through the **same** `agy` (Antigravity) CLI, differing only by `--model` (Flash High vs. Pro High). The `agy` CLI replaced the standalone `gemini` CLI, which stopped serving consumer requests on **2026-06-18**. Because they share a provider, treat Flash↔Pro agreement as **one** provider's vote, not two independent ones — real cross-provider convergence means agreement across codex (OpenAI), the Gemini fleet (Google), and kimi (Moonshot).

## When to use this

- A PR has just been created by Claude and the user wants a second opinion before merge.
- The user asks to "cross-review", "swarm review", "get codex/antigravity/gemini/kimi to look at this".
- The user wants an agentic review loop that applies fixes rather than just listing them.

When in doubt, ask whether they want just findings or the full fix-and-iterate loop.

## Core workflow

The skill runs in this order. Do not skip steps — each produces state the next depends on.

### 1. Detect available reviewers

```bash
bash ~/.claude/skills/cross-review/scripts/detect_reviewers.sh
```

Prints JSON like `{"codex": true, "antigravity": true, "gemini-pro": true, "kimi": true}`. Note that `antigravity` and `gemini-pro` both track the **single `agy` binary** — if `agy` is installed, both report `true`. If none are available, stop and tell the user how to install them:

- codex: `brew install codex-cli`
- antigravity + gemini-pro (both via `agy`): `curl -fsSL https://antigravity.google/cli/install.sh | bash`, then `agy login` once
- kimi: `curl -L code.kimi.com/install.sh | bash`

Do not proceed with zero reviewers. (The standalone `gemini` CLI is no longer used — it was retired in the 2026-06-18 Gemini-CLI consumer sunset; both Gemini reviewers now run on `agy`.)

### 1.5 Pre-run health check (recent runlog)

Before spending tokens on a fresh round, glance at the last 10 runs to see if any reviewer is currently degraded. The analyzer surfaces only what's actionable — silent in the common case.

```bash
bash ~/.claude/skills/cross-review/scripts/analyze_runlog.sh --recent 10 --mode warn
```

If a warning prints (e.g. *"WARN: gemini-pro timed out 35% of last 10 runs — consider --timeout-gemini-pro 1100"*), surface it to the user and ask whether to apply the suggested override for this run. Do not auto-apply — surface-and-confirm only. If no warning, proceed silently.

The analyzer has a separate `--mode report` that prints a full health snapshot; that's surfaced via `/cross-review --self-check`, not on every run.

### 2. Determine review scope and prepare an isolated worktree

Figure out what to review:

- **PR number given** (`/cross-review 123`): `gh pr view 123 --json baseRefName,headRefName,number,url` to get base branch, confirm current checkout matches head.
- **No PR number**: review current branch vs. its merge-base with `main` (or `origin/HEAD`). If there's no diff, stop and say so — nothing to review.

**Always run the review in an isolated worktree, never in the user's main checkout.** This avoids disturbing their uncommitted work and makes teardown trivial.

```bash
bash ~/.claude/skills/cross-review/scripts/worktree.sh start \
  --ref <pr-head-ref>      # e.g. origin/dq-22-empty-state-tab-bar or a SHA
  --id <slug>              # e.g. pr-213 or branch-dq-22
  --base <base-branch>     # defaults to origin/main
```

The script prints a single JSON line with:

- `worktree` — `/tmp/cr-<id>-<ts>/` — the detached checkout you `cd` into to run reviewers
- `run_dir` — `~/.cross-review/runs/<repo>-<id>-<ts>/` — **stable** output location that survives worktree teardown. All reviewer outputs, findings, and raw artifacts go here, not inside the worktree
- `size_files`, `size_lines` — diff size
- `warn_large_diff` — true if diff exceeds ~30 files or ~2000 lines
- `warn_secrets` — true if any changed path matches secret-like patterns (`.env`, `credentials`, `.pem`, `id_rsa`, keystores, etc.)
- `risky_files` — comma-separated list of the offenders (first 5)

**Pre-flight repo-state check.** Before dispatching reviewers, refuse to run on a dirty tree:

```bash
if git ls-files -u | grep -q . ; then
  echo "Working tree has unresolved merge conflicts. Resolve them or stash, then re-run." >&2
  exit 2
fi
if [ -n "$(git diff --check 2>/dev/null)" ]; then
  echo "Working tree has whitespace/conflict markers. Inspect with 'git diff --check' first." >&2
  exit 2
fi
```

Reviewers shown a half-resolved state will hallucinate confidently about the broken hunks.

**Before proceeding, check both warnings:**

- **On `warn_large_diff: true`**, stop and confirm with the user. Reviewers scale linearly with diff size; a big PR can easily cost 100k+ tokens per reviewer. Offer options: proceed anyway, narrow the scope to specific files via a custom prompt, or skip the run.
- **On `warn_secrets: true`**, show the flagged paths to the user and get explicit consent before sending the diff. All reviewers ingest the full diff (across three providers — OpenAI, Google, Moonshot) — even rotated-and-removed secrets would leave the machine. Path-based detection is a conservative first line; false positives (a file legitimately named `secret-sauce.md`) are fine, the user will wave them through.

If either warning fires, do **not** proceed silently. A skill that quietly sends sensitive content or bleeds tokens is worse than one that asks.

Save the JSON to `$run_dir/context.json` and `cd` into `$worktree`. Future steps use `$run_dir` for outputs and `$worktree` as cwd.

### 2.5. (Optional) Bound the input with `repomix-handoff`

For large diffs (`warn_large_diff: true`), or when a reviewer has a tighter context window than the diff allows, you may want to feed a token-budgeted snapshot to the CLIs instead of letting them ingest the full raw diff. This is **not** wired into `run_reviewers.sh` — the wrapper always reads the raw diff. To use a snapshot, you (the model) must produce it here and then **explicitly** include its contents in the reviewer prompt you build.

This is a sibling skill, not a hard dependency. If `repomix-handoff` is missing, skip this step and continue with the default raw-diff flow.

```bash
# Detect availability — exits 0 if the sibling skill + repomix are both installed
if [ -x ~/.claude/skills/repomix-handoff/scripts/detect_repomix.sh ] && \
   ~/.claude/skills/repomix-handoff/scripts/detect_repomix.sh | grep -q '"available": true'; then
  # Per-reviewer snapshot (picks style + token budget that each CLI handles best)
  for r in codex antigravity gemini-pro kimi; do
    bash ~/.claude/skills/repomix-handoff/scripts/handoff.sh \
      --reviewer "$r" \
      --output "$run_dir/snapshot-$r.${EXT:-md}" >/dev/null
  done
fi
```

If you produce snapshots, **you must explicitly include each snapshot's contents in the reviewer prompt you build** — `run_reviewers.sh` will not pick them up automatically. For codex/antigravity/gemini-pro/kimi today, that means reading `$run_dir/snapshot-<reviewer>.*` into the prompt body before invoking the wrapper (or feeding via the reviewer's native file-input flag where supported; see `references/cli_flags.md`).

The reviewer presets in `repomix-handoff` already bake in safe defaults (if it lacks the `antigravity`/`gemini-pro` keys, fall back to its `gemini` preset — same Google-Gemini context budget):

| Reviewer | Style | Max tokens |
|---|---|---|
| codex       | XML      | 160k |
| antigravity | Markdown | 1M   |
| gemini-pro  | Markdown | 1M   |
| kimi        | Markdown | 200k |
| claude      | XML      | 200k |

**Skip this step** if `warn_secrets: true` is still unresolved — bound or unbound, packed snapshots still contain whatever you pack.

> **Future work:** a `--snapshot-dir` flag on `run_reviewers.sh` that auto-injects per-reviewer snapshots would close this manual gap. Tracked separately, not on this PR.

### 2.6. (Optional) Enrich the reviewer prompt with `/impact` and `ast-grep scan`

Reviewers do better when they know what's affected and which project-specific rules already exist. Both checks are sibling skills / tools — degrade gracefully if missing.

**`/impact` — blast radius:** runs reverse-dep analysis to list affected files + recommended test files. Append to `$run_dir/context.md` so reviewers see it.

```bash
if [ -x ~/.claude/skills/impact/scripts/impact.sh ]; then
  bash ~/.claude/skills/impact/scripts/impact.sh --base "$base_branch" --json \
    > "$run_dir/impact.json" 2>/dev/null || true
fi
```

**`ast-grep scan` — project rules:** if the target repo has `sgconfig.yml` at its root, run a scan over the diff and surface findings. Catches violations of repo-specific architectural rules (e.g. "do not write to `memory_items` outside `FirestoreMemoryClient`") that reviewers wouldn't know to look for.

```bash
if [ -f "$worktree/sgconfig.yml" ] && command -v ast-grep >/dev/null; then
  ( cd "$worktree" && ast-grep scan --json=stream 2>/dev/null ) \
    > "$run_dir/sgscan.jsonl" || true
fi
```

When either file exists, include a short summary in the reviewer prompt's preamble (e.g. "ast-grep flagged 3 violations of `no-direct-memory-items-write` in this diff — review whether they're justified"). Do **not** dump full JSON into the prompt; summarize.

### 3. Run reviewers in parallel

```bash
bash ~/.claude/skills/cross-review/scripts/run_reviewers.sh \
  --base <base-branch> \
  --out "$run_dir/raw" \
  --reviewers codex,antigravity,gemini-pro,kimi
```

Runs every requested reviewer concurrently and writes raw outputs to the `out` directory. The wrapper handles the flag dialects:

- `codex exec review --base <branch> --full-auto`
- `agy --model "Gemini 3.5 Flash (High)" --sandbox -p '<prompt>'` — the **antigravity** reviewer (fast lap)
- `agy --model "Gemini 3.1 Pro (High)" --sandbox -p '<prompt>'` — the **gemini-pro** reviewer (deep lap; same `agy` binary, different model)
- `kimi --plan --print --quiet` with the prompt piped via stdin

Outputs land at `antigravity.{stdout,stderr,meta.json}` and `gemini-pro.{stdout,stderr,meta.json}` respectively; each `meta.json` carries a `model` and `cli` field so synthesis and the runlog can tell the two Gemini laps apart. The wrapper returns when all are done.

**Modes:**
- **swarm** (default): run every reviewer the detect step found. More coverage, more tokens.
- **solo**: run just one (the fastest available). Useful when the user wants a quick sniff test.

The wrapper logs timing and exit codes per reviewer. If one fails, continue with the rest — a partial review is still useful. If all fail, stop and surface the errors.

### 4. Synthesize findings

Read every file under the `raw/` directory. Do **not** shell out to a parser — the reviewer outputs are free-form prose plus structured fragments, and you (the model) are better at extracting the real findings than a regex would be. For each raw file:

- Pull out concrete issues tied to specific files/lines when possible.
- Drop pure praise, filler, and anything not actionable.
- Note the reviewer (codex / antigravity / gemini-pro / kimi) so the user can see agreement vs. disagreement.

Produce a merged list at `$run_dir/findings.md` with this structure:

```markdown
# Cross-review findings — <branch> vs <base>

## Critical
- **[file:line]** <one-line title> (sources: codex, antigravity, gemini-pro, kimi)
  <why it matters, concrete fix sketch if offered>

## High
- ...

## Medium
- ...

## Low / nits
- ... (can be batched; don't need individual treatment)
```

**Severity rubric** (borrow the reviewers' judgment when they offer one, otherwise apply yours):

- **Critical**: breaks correctness, leaks secrets, opens security hole, crashes in normal use.
- **High**: violates a project constraint from CLAUDE.md (e.g., hardcoded colors vs. design tokens, mocks in integration tests), wrong semantics that tests wouldn't catch, bad defaults.
- **Medium**: risky edge case, poor error handling at a boundary, unclear naming that will trip future readers.
- **Low / nit**: style, minor phrasing, minor optimization.

When multiple reviewers flag the same issue at different severities, take the highest one and note the disagreement. Convergence across providers is a very strong signal; a finding flagged by only one deserves more skepticism.

**Provider independence matters more than reviewer count.** `antigravity` and `gemini-pro` are the same provider (Google/Gemini, both via `agy`) — if only those two agree, that's effectively *one* independent vote, not two. Genuine cross-provider convergence means agreement spanning codex (OpenAI), the Gemini fleet (Google), and kimi (Moonshot). Weight a codex+gemini-pro+kimi agreement far above a antigravity+gemini-pro agreement even though both are "two reviewers." See `reviewer_profiles.json` `_synthesis_rules.provider_independence`.

**Apply per-reviewer priors from `references/reviewer_profiles.json` when triaging:**

- A finding tagged `skip_unless_convergent` for that reviewer's severity should be dropped if no other reviewer flagged the same area. Codex P3 nits and kimi Low/nit findings are the typical examples. (For "convergent" here, prefer a *different-provider* corroboration — antigravity backing gemini-pro doesn't lift a `skip_unless_convergent` finding much, since they're one provider.)
- A finding tagged `high_precision` (codex P1 today) should rank as near-certain real even if solo.
- `trust_if_convergent` means: keep when 2+ reviewers agree on it; downgrade or move to "verify" when solo.
- When two reviewers disagree on severity, break the tie with `synthesis_weight` (higher weight wins).

These priors live in `reviewer_profiles.json` — read once at synthesis time, edit there (not inline) when tuning. The analyzer's `--mode report` will eventually suggest edits to these values based on observed convergence and precision rates.

**Also emit a structured `findings.json` sidecar** next to `findings.md` — this is what the step 4.5 verification gate consumes. One object per finding:

```json
{
  "base": "<base-ref>", "head": "HEAD",
  "findings": [
    { "id": "f1", "severity": "Critical|High|Medium|Low",
      "file": "path/relative/to/repo", "line": 42,
      "snippet": "the exact offending line(s) the reviewer quoted, verbatim",
      "claim": "one-line statement of what is wrong",
      "sources": ["codex", "gemini-pro"], "suggested_fix": "optional" }
  ]
}
```

The `snippet` field is load-bearing: it is what the anchor pass matches against the diff and what the fact-check pass falsifies. When a reviewer didn't quote the offending code, pull the line from the diff yourself; if you genuinely can't, leave `snippet` empty (that finding simply won't be anchorable).

### 4.5 Verify findings — anchor + fact-check (recommended; required before auto-fix)

Two cheap passes that raise precision before any fix touches the tree. Lifted from open-code-review (see `docs/investigation-cr-ocr-ideas.md`). Run them in order on the `findings.json` from step 4:

**(a) Anchor — deterministic, no tokens.** Re-derive each finding's line by matching its `snippet` against the actual diff hunks:

```bash
bash ~/.claude/skills/cross-review/scripts/anchor_findings.sh \
  --findings "$run_dir/findings.json" --base <base-branch> --repo "$worktree" \
  --out "$run_dir/findings.anchored.json"
```

Each finding gains `anchor: {resolved, start_line, end_line, side}`; resolved findings get their `line` corrected. A finding with `anchor.resolved=false` (snippet found nowhere in the diff) is a strong **hallucinated-location** signal — mark it "⚠ unanchored" in `findings.md` and **do not auto-fix it without human confirmation**. Don't auto-drop it: a reviewer may legitimately cite an unchanged neighbouring line.

**(b) Fact-check — falsify-only LLM pass.** A cheap, diff-only reviewer removes findings the diff itself *disproves*:

```bash
bash ~/.claude/skills/cross-review/scripts/factcheck_findings.sh \
  --findings "$run_dir/findings.anchored.json" --base <base-branch> --repo "$worktree" \
  --reviewer agy --out "$run_dir/findings.verified.json"
```

Each finding gains `factcheck: {verdict: "keep"|"drop", reason}`. The pass can **only drop a finding the diff actively contradicts** — it never invents findings and keeps anything it merely can't confirm (recall-safe by design; `references/factcheck_prompt.txt`). It is **fail-safe**: any error/timeout/unparseable response keeps every finding. Exclude `verdict:"drop"` findings from the auto-fix triage and note them (struck through, with the veto reason) in `findings.md` and the record.

This gate is **cheap** (anchor is free; fact-check is one Flash-tier call) and most valuable exactly when auto-fix is opted in. Skip it only for a quick report-only sniff test. The `convergent` count and `Top` in the report block (step 9) should reflect the post-verification set.

### 5. Triage and apply fixes (opt-in only)

**Default is report-only.** The skill does **not** modify files or create commits unless the caller has explicitly opted in — either by passing `--apply-fixes` to the invoking skill command, or because the user said "apply the fixes" / "fix these and re-review" / equivalent in prose. If neither signal is present, skip this section and jump to step 7 (post the record).

This default exists because (a) the fix loop has far less production exposure than the detection phase, (b) a wrong auto-fix commit on the user's branch is hard to undo cleanly, and (c) reviewers sometimes flag things that are not actually bugs (see the RewardCard PR where `hardcoded Colors.dark` was intentional). When in doubt, the cheaper path is to report and let the user decide.

**When auto-fix is opted in:** first run the step 4.5 verification gate if you haven't. Triage operates on the **verified** set — `factcheck.verdict:"drop"` findings are excluded outright, and `anchor.resolved:false` findings are held for human confirmation rather than auto-fixed.

Triage policy: fix Critical and High findings where the reviewer's suggested fix is unambiguous; surface Medium for the user; ignore Low/nits unless asked.

For each fix:
1. Read the relevant files to understand the real context. The anchor pass already corrected `line` to the real hunk line (`anchor.start_line`) — trust that over the reviewer's original claim, and treat any still-unanchored finding as suspect.
2. If the suggested fix depends on a design decision (e.g., "should this be null-coalesced or throw?", "should this be a union type or an enum?"), stop and ask the user. Don't guess on semantics — the point of opt-in auto-fix is to handle the mechanical cases, not make product decisions.
3. Apply the change.
4. Run local checks if cheap: `pnpm lint` on touched packages, relevant unit tests. Don't run the full suite between every fix — batch and run once at the end of the pass.

When all Critical/High fixes for the pass are in, commit:

```bash
git add -p  # or specific paths
git commit -m "$(cat <<'EOF'
fix: address cross-review findings (pass <N>)

- <terse summary of what changed>

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

### 6. Re-review loop

After committing, re-run steps 3–5 against the new HEAD. Keep iterating until any of:

- No Critical or High findings remain.
- **Iteration cap: 3 passes.** If the reviewers are still finding Critical/High on pass 3, stop and hand to the user — something structural is wrong and more passes won't fix it.
- The same finding recurs across passes (reviewer doesn't accept the fix). Stop and ask the user.

Each pass's artifacts go in a new `run-<timestamp>/` so the record is preserved.

### 7. Post the record

Write a PR-level record so future Claude runs (or human reviewers) can see what happened. The record mode is configurable — the cheapest default is `summary`.

```bash
bash ~/.claude/skills/cross-review/scripts/post_comment.sh \
  --pr <pr-number> \
  --mode <summary|file|none> \
  --findings "$run_dir/findings.md"
```

**Modes:**

- **summary** (default): one consolidated PR comment per pass via `gh pr comment`. Cheap (one API call), easy to scan in the PR timeline, good record for future Claude runs.
- **file**: no PR post; rely on the already-written `$run_dir/findings.md`. Zero GitHub cost, only useful locally.
- **none**: nothing posted, nothing saved beyond the in-memory turn. Don't use unless the user explicitly asks.

Inline-per-finding mode was considered and dropped: 5–10× the API calls, harder to scan at a glance, and the information is already in `summary` with file:line references. If you ever want inline, it's a conversation starter, not a default.

If no PR exists yet, `summary` falls back to `file` automatically — don't fail the run.

### 8. Tear down the worktree

After the record is posted (or the fix loop has exited one way or the other), remove the worktree. Run dirs under `~/.cross-review/runs/` are the permanent record and are **not** touched.

```bash
bash ~/.claude/skills/cross-review/scripts/worktree.sh end --worktree "$worktree"
```

Idempotent — safe to call even if something earlier already removed it. If teardown fails, surface the error but don't treat the run as failed; the user can manually `rm -rf /tmp/cr-*` or run the sweeper.

On any subsequent invocation of this skill (new or same session), start by running a sweep to garbage-collect orphaned worktrees from crashed or interrupted earlier runs:

```bash
bash ~/.claude/skills/cross-review/scripts/worktree.sh sweep
# removes /tmp/cr-*/ older than 24h; safe to run any time
```

This keeps `git worktree list` and `/tmp` clean without the user needing to remember cleanup.

### 9. Report back to the caller

Whoever invoked this skill — the user directly, or a parent agent (e.g., a `/pr` wrapper) — needs a decision-ready summary without reading the full `findings.md`. At the end of **every pass**, emit exactly this block as the last thing you say before yielding control:

```
── cross-review pass <N>/3 ──
Verdict: CLEAN | FIXES_APPLIED | NEEDS_DECISION | BLOCKED
Counts:  C:<n> H:<n> M:<n> L:<n>  (convergent: <n>)
Top:     <file:line> — <one-line title> [<severity>][sources, e.g. codex+gemini-pro+kimi | codex+antigravity | gemini-pro | kimi]
Record:  ~/.cross-review/runs/<repo>-<id>-<ts>/findings.md  (posted to PR: <url|—>)
Next:    stop | re-review | ask-user | apply-fixes
Notes:   <≤1 sentence if something non-obvious happened — reviewer disagreement, rate-limit retries, partial failure>
──────────────────────────────
```

**Verdict semantics:**

- **CLEAN** — No Critical/High after this pass. The skill is done; caller can merge.
- **FIXES_APPLIED** — Critical/High found *and auto-fixed* in this pass. Another pass will run to verify; caller should not intervene yet.
- **NEEDS_DECISION** — Critical/High found but requires human judgment (design decision, scope question, semantic ambiguity). Caller must respond before the skill can continue.
- **BLOCKED** — Cannot proceed: all reviewers failed, auth missing, iteration cap hit with findings still outstanding, same finding recurs across passes. Caller needs to investigate.

**Convergent** counts findings that two or more reviewers independently flagged on the same file/area — but weight by *provider*, not raw reviewer count. Agreement across providers (codex=OpenAI, gemini-fleet=Google, kimi=Moonshot) is the strong signal; agreement between `antigravity` and `gemini-pro` alone is one provider agreeing with itself, so discount it toward single-reviewer skepticism. All-provider convergence (codex + a Gemini lap + kimi) is the strongest signal of all — treat those findings as near-certain to be real.

**Top** is the single most important finding — Critical > all-provider-convergent High > two-provider convergent High > single-reviewer High. Pick one; surface the rest via the Record link.

**Next** is what the skill intends to do (or wants the caller to do):

- `stop` — clean, done.
- `re-review` — fixes committed, skill will run another pass automatically.
- `ask-user` — NEEDS_DECISION pending; skill yields until the caller responds.
- `apply-fixes` — skill is about to fix; report is mid-pass, not final. (Use only if your flow splits fix & report into separate turns.)

Keep the block exactly this shape — parent agents key off the field names. Anything else (longer analysis, reviewer prose) goes in `findings.md`, not in the report block.

### 9.5 Append runlog entry

After the report block — and before worktree teardown — append a structured JSONL entry to `~/.claude/skills/cross-review/runlog.jsonl`. This is what the Phase 1.5 pre-run check and `/cross-review --self-check` read; without it, the self-improvement loop has no data.

```bash
bash ~/.claude/skills/cross-review/scripts/append_runlog.sh \
  --run-dir "$run_dir" \
  # ↑ The script auto-resolves $run_dir/raw/<reviewer>.meta.json (canonical
  # location, written by run_reviewers.sh step 3) and falls back to
  # $run_dir/<reviewer>.meta.json. Either path works.
  --project "$(basename "$(git -C "$worktree" rev-parse --show-toplevel)")" \
  --base "$base" \
  --pr "${pr:-"-"}" \
  --pass "$N" \
  --verdict "<CLEAN|FIXES_APPLIED|NEEDS_DECISION|BLOCKED>" \
  --convergent "<n>" \
  --top "<file:line — title [severity][sources]>" \
  --diff-files "<n>" --diff-lines "<n>" \
  --notes "<≤1 sentence on anything non-obvious>"
```

The script reads each `$run_dir/<reviewer>.meta.json` to fill in per-reviewer telemetry — duration, exit code, timed_out, output_bytes, attempt — so you only pass the high-level verdict and one-line summary. Pass `-` for `--pr` on branch-only runs (no GitHub PR).

Append once per pass (not once per multi-pass run). The runlog is JSONL: one line per pass, append-only, safe under concurrent splitstream rounds.

## Reviewer-specific notes

- **codex**: Uses `codex exec review --base <branch> --full-auto`. Writes review output to stderr (we merge streams with `2>&1`). `--json` mode emits reasoning/command events but does **not** flush the final review summary — use plain-text mode. `--base` and a positional `[PROMPT]` are mutually exclusive; with `--base`, codex uses its own built-in review instructions.
- **antigravity** (Gemini 3.5 Flash, fast lap): Uses `agy --model "Gemini 3.5 Flash (High)" --sandbox -p '<prompt>'`. `--sandbox` plus a "do not edit" prompt instruction keeps it read-only. Needs an explicit review prompt (see `references/review_prompt.txt`). Replaces the retired standalone `gemini` CLI. **Gotcha:** `agy --model` accepts only the exact `agy models` display string and **silently falls back to Flash** on a typo — never errors. Auth: `agy login` once (Google OAuth); empty output later means auth expired, not a timeout.
- **gemini-pro** (Gemini 3.1 Pro, deep lap): Same `agy` binary, just `--model "Gemini 3.1 Pro (High)"` and a longer default timeout (900s). Pro reasons deeper and slower; for tiny diffs the Flash lap alone is often enough. Migrated off the standalone `gemini` CLI in the 2026-06-18 sunset.
- **kimi** (Moonshot's Kimi Code CLI): Uses `kimi --plan --print --quiet` with the review prompt piped via stdin (NOT `-p`). `--plan` is read-only; `--print` is non-interactive; `--quiet` trims to just the final assistant message. Prompt goes on stdin because argv has a 128KB-per-argument limit on Linux (`MAX_ARG_STRLEN`) and argv-based prompts also leak the diff via `ps` to other local users. Default model is `kimi-k2.5` (256K ctx, thinking mode on) — configured in `~/.kimi/config.toml`. Auth is either the Moonshot platform API key (`openai_legacy` provider against `api.moonshot.ai/v1`) or the native Kimi Coding subscription (`kimi login` OAuth). Note: kimi sends code to a China-origin provider — surface that to the user for security-sensitive repos.

More detail on flags and gotchas lives in [references/cli_flags.md](references/cli_flags.md). Read it if a reviewer is behaving unexpectedly.

## Integration with /pr

If the user's PR workflow invokes a `/pr` skill, this skill should run as a late step in that flow — after the PR is opened, before merge. The `/pr` skill can call cross-review and wait for it to return clean before proceeding to squash merge.

This is not auto-invoked by the harness. To make it fire automatically after every `gh pr create`, a settings.json hook would need to be added via the `update-config` skill.

## Common failure modes

- **"No diff to review"**: branch has no commits past the base. Check `git log base..HEAD` — likely on the wrong branch.
- **Reviewer hangs**: any CLI can hang on auth or on first-run config prompts. The wrapper has a per-reviewer timeout (codex 300s, antigravity/kimi 600s, gemini-pro 900s by default — see `references/reviewer_profiles.json`); if it fires, surface stderr so the user can re-auth. For the two `agy` reviewers, a hang is most often the shared `agy` auth — `agy login` once fixes both. Timeouts are no longer retried (a reviewer that used its budget will use it again on retry — that's a tuning signal, not a transient failure). If the same reviewer keeps timing out, the analyzer's `--mode warn` will surface a suggested bump on the next run.
- **Reviewer flags a tokens-vs-hardcoded issue that's actually fine**: Vibrant Punk / NativeWind contexts use tokens that look like hex to the reviewer. Check `constants/theme.ts` before "fixing" a perceived hardcoded color.
- **Same finding keeps coming back**: either the fix is wrong, or the reviewer has a stale mental model (e.g., you moved logic to another file and it still complains about the old location). Don't loop — stop and investigate.
- **Iteration 3 still dirty**: structural issue. Don't push through — ask the user whether to merge with known findings or take a different approach.

## Self-check mode

When invoked as `/cross-review --self-check`, skip the review pipeline and emit a health snapshot of the reviewer fleet:

```bash
bash ~/.claude/skills/cross-review/scripts/analyze_runlog.sh --recent 20 --mode report
```

The report shows per-reviewer reliability %, ok/timeout/empty/failed counts, p50/p95 duration, current timeout budget, and a list of suggested edits to `references/reviewer_profiles.json` (e.g. "bump gemini-pro.timeout_s from 900 → 1100 because timeout rate 25% over window"). Suggestions never apply themselves — the user (or Claude) edits the profile file with eyes on, the same way splitstream's pre-flight table needs explicit approval.

Use it: weekly, after a noticeably degraded round, before changing reviewer profiles, or when investigating "why did cross-review miss X?"

## Importing / consolidating runlogs

The runlog lives at `$skill_dir/runlog.jsonl` — a path relative to wherever the skill is installed. So the repo copy, the `~/.claude/skills` install, and the plugin cache each keep their **own** history, and a reinstall or sync starts from an empty log. To fold an old or sibling runlog into the current one without losing telemetry:

```bash
bash ~/.claude/skills/cross-review/scripts/import_runlog.sh \
  --from <old-runlog.jsonl | dir-containing-one> \
  [--from <another> ...] \
  [--into <dest runlog.jsonl>]   # defaults to this skill's runlog
  [--dry-run]
```

The merge is **idempotent** (exact-object dedup — re-importing the same source adds nothing), JSON-validated (non-JSON lines are counted and skipped, not written), chronologically sorted by `ts` (legacy entries without `ts` sort to the front), and written atomically under `flock`. Always safe to run before `--self-check` after a reinstall: `import_runlog.sh --from ~/.claude/skills/cross-review/runlog.jsonl --dry-run` shows what would be pulled in. This is the supported way to preserve history when syncing the skill between the repo and an install.

## Per-reviewer behavioral profiles

`references/reviewer_profiles.json` is the canonical source for per-reviewer config: timeout, retry policy, severity priors, synthesis weight, specialization. Three places read it:

- The wrapper (`run_reviewers.sh`) sources `timeout_s` and `retry_policy` from it. CLI flags override.
- The synthesis step (4) consults `severity_priors` and `synthesis_weight` when ranking findings. See "Apply per-reviewer priors..." in step 4.
- The analyzer (`analyze_runlog.sh`) reads the current `timeout_s` to suggest tuning bumps.

When tuning a reviewer's behavior — e.g. "kimi nits are wasting time, downweight them" — edit `reviewer_profiles.json`, not the wrapper or SKILL.md prose. Centralizing the config keeps the self-improvement loop honest: the analyzer's suggestions land in the same file humans edit by hand.

## What this skill does not do

- It does not run lint/type/test suites as the reviewer. Those are Claude's own pre-PR checks — this skill layers on top.
- It does not replace human review. The goal is to raise the floor, not to auto-merge.
- It does not invent findings. If reviewers have nothing to say, report that honestly and stop.
