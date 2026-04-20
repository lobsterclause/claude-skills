---
name: cross-review
description: Run external AI code reviewers (codex CLI, gemini CLI, and kimi CLI) in parallel against the current branch's diff, synthesize deduped findings, auto-apply fixes, and iterate until clean. Use this skill whenever the user wants a second opinion on code, cross-review, swarm review, peer review, external review, or wants codex/gemini/kimi to look at changes before shipping — even if they don't explicitly name the CLIs. Also trigger on "have codex check this", "get a second pair of eyes", "cross-check my changes", "review before merge", "swarm review", "review this PR", or right after Claude creates a PR. Do NOT trigger for routine lint/test runs, style-only checks, or when the user wants Claude itself (not external CLIs) to review.
---

# cross-review

Orchestrates external AI CLIs (currently `codex`, `gemini`, and `kimi`) to review the current branch's changes, consolidates their findings, applies fixes, and re-runs until the diff is clean or an iteration budget is exhausted. The goal is to catch things a single model would miss — different reviewers have different blind spots, so their overlap is signal and their disagreements are worth reading.

## When to use this

- A PR has just been created by Claude and the user wants a second opinion before merge.
- The user asks to "cross-review", "swarm review", "get codex/gemini/kimi to look at this".
- The user wants an agentic review loop that applies fixes rather than just listing them.

When in doubt, ask whether they want just findings or the full fix-and-iterate loop.

## Core workflow

The skill runs in this order. Do not skip steps — each produces state the next depends on.

### 1. Detect available reviewers

```bash
bash ~/.claude/skills/cross-review/scripts/detect_reviewers.sh
```

Prints JSON like `{"codex": true, "gemini": true, "kimi": true}`. If none are available, stop and tell the user how to install them (`brew install codex-cli`, `npm i -g @google/gemini-cli`, `curl -L code.kimi.com/install.sh | bash`). Do not proceed with zero reviewers.

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

**Before proceeding, check both warnings:**

- **On `warn_large_diff: true`**, stop and confirm with the user. Reviewers scale linearly with diff size; a big PR can easily cost 100k+ tokens per reviewer. Offer options: proceed anyway, narrow the scope to specific files via a custom prompt, or skip the run.
- **On `warn_secrets: true`**, show the flagged paths to the user and get explicit consent before sending the diff. Both reviewers ingest the full diff — even rotated-and-removed secrets would leave the machine. Path-based detection is a conservative first line; false positives (a file legitimately named `secret-sauce.md`) are fine, the user will wave them through.

If either warning fires, do **not** proceed silently. A skill that quietly sends sensitive content or bleeds tokens is worse than one that asks.

Save the JSON to `$run_dir/context.json` and `cd` into `$worktree`. Future steps use `$run_dir` for outputs and `$worktree` as cwd.

### 3. Run reviewers in parallel

```bash
bash ~/.claude/skills/cross-review/scripts/run_reviewers.sh \
  --base <base-branch> \
  --out "$run_dir/raw" \
  --reviewers codex,gemini,kimi
```

Runs every requested reviewer concurrently and writes raw outputs to the `out` directory. The wrapper handles the flag dialects (`codex exec review --base <branch> --full-auto` vs. `gemini -p '<prompt>' --approval-mode plan --output-format json` vs. `kimi --plan --print --quiet` with the prompt piped via stdin) and returns when all are done.

**Modes:**
- **swarm** (default): run every reviewer the detect step found. More coverage, more tokens.
- **solo**: run just one (the fastest available). Useful when the user wants a quick sniff test.

The wrapper logs timing and exit codes per reviewer. If one fails, continue with the rest — a partial review is still useful. If all fail, stop and surface the errors.

### 4. Synthesize findings

Read every file under the `raw/` directory. Do **not** shell out to a parser — the reviewer outputs are free-form prose plus structured fragments, and you (the model) are better at extracting the real findings than a regex would be. For each raw file:

- Pull out concrete issues tied to specific files/lines when possible.
- Drop pure praise, filler, and anything not actionable.
- Note the reviewer (codex / gemini / kimi) so the user can see agreement vs. disagreement.

Produce a merged list at `$run_dir/findings.md` with this structure:

```markdown
# Cross-review findings — <branch> vs <base>

## Critical
- **[file:line]** <one-line title> (sources: codex, gemini, kimi)
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

When multiple reviewers flag the same issue at different severities, take the highest one and note the disagreement. Convergence across all three reviewers is a very strong signal; a finding flagged by only one deserves more skepticism.

### 5. Triage and apply fixes (opt-in only)

**Default is report-only.** The skill does **not** modify files or create commits unless the caller has explicitly opted in — either by passing `--apply-fixes` to the invoking skill command, or because the user said "apply the fixes" / "fix these and re-review" / equivalent in prose. If neither signal is present, skip this section and jump to step 7 (post the record).

This default exists because (a) the fix loop has far less production exposure than the detection phase, (b) a wrong auto-fix commit on the user's branch is hard to undo cleanly, and (c) reviewers sometimes flag things that are not actually bugs (see the RewardCard PR where `hardcoded Colors.dark` was intentional). When in doubt, the cheaper path is to report and let the user decide.

**When auto-fix is opted in:**

Triage policy: fix Critical and High findings where the reviewer's suggested fix is unambiguous; surface Medium for the user; ignore Low/nits unless asked.

For each fix:
1. Read the relevant files to understand the real context — don't trust the reviewer's line numbers blindly; the diff may have shifted them.
2. If the suggested fix depends on a design decision (e.g., "should this be null-coalesced or throw?", "should this be a union type or an enum?"), stop and ask the user. Don't guess on semantics — the point of opt-in auto-fix is to handle the mechanical cases, not make product decisions.
3. Apply the change.
4. Run local checks if cheap: `pnpm lint` on touched packages, relevant unit tests. Don't run the full suite between every fix — batch and run once at the end of the pass.

When all Critical/High fixes for the pass are in, commit:

```bash
git add -p  # or specific paths
git commit -m "$(cat <<'EOF'
fix: address cross-review findings (pass <N>)

- <terse summary of what changed>

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
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
Top:     <file:line> — <one-line title> [<severity>][codex+gemini+kimi|codex+gemini|codex+kimi|gemini+kimi|codex|gemini|kimi]
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

**Convergent** counts findings that two or more reviewers independently flagged on the same file/area. High convergence is a strong signal the issue is real; single-reviewer findings may be style-of-the-reviewer and deserve more skepticism. All-three convergence (codex + gemini + kimi) is the strongest signal of all — treat those findings as near-certain to be real.

**Top** is the single most important finding — Critical > all-three-convergent High > two-reviewer convergent High > single-reviewer High. Pick one; surface the rest via the Record link.

**Next** is what the skill intends to do (or wants the caller to do):

- `stop` — clean, done.
- `re-review` — fixes committed, skill will run another pass automatically.
- `ask-user` — NEEDS_DECISION pending; skill yields until the caller responds.
- `apply-fixes` — skill is about to fix; report is mid-pass, not final. (Use only if your flow splits fix & report into separate turns.)

Keep the block exactly this shape — parent agents key off the field names. Anything else (longer analysis, reviewer prose) goes in `findings.md`, not in the report block.

## Reviewer-specific notes

- **codex**: Uses `codex exec review --base <branch> --full-auto`. Writes review output to stderr (we merge streams with `2>&1`). `--json` mode emits reasoning/command events but does **not** flush the final review summary — use plain-text mode. `--base` and a positional `[PROMPT]` are mutually exclusive; with `--base`, codex uses its own built-in review instructions.
- **gemini**: Uses `gemini -p '<prompt>' --approval-mode plan --output-format json`. `plan` mode is read-only (won't try to edit files). Needs an explicit review prompt (see `references/review_prompt.txt`). Auth via `gemini` interactive once to do Google OAuth, then headless works.
- **kimi** (Moonshot's Kimi Code CLI): Uses `kimi --plan --print --quiet` with the review prompt piped via stdin (NOT `-p`). `--plan` is read-only; `--print` is non-interactive; `--quiet` trims to just the final assistant message. Prompt goes on stdin because argv has a 128KB-per-argument limit on Linux (`MAX_ARG_STRLEN`) and argv-based prompts also leak the diff via `ps` to other local users. Default model is `kimi-k2.5` (256K ctx, thinking mode on) — configured in `~/.kimi/config.toml`. Auth is either the Moonshot platform API key (`openai_legacy` provider against `api.moonshot.ai/v1`) or the native Kimi Coding subscription (`kimi login` OAuth). Note: kimi sends code to a China-origin provider — surface that to the user for security-sensitive repos.

More detail on flags and gotchas lives in [references/cli_flags.md](references/cli_flags.md). Read it if a reviewer is behaving unexpectedly.

## Integration with /pr

If the user's PR workflow invokes a `/pr` skill, this skill should run as a late step in that flow — after the PR is opened, before merge. The `/pr` skill can call cross-review and wait for it to return clean before proceeding to squash merge.

This is not auto-invoked by the harness. To make it fire automatically after every `gh pr create`, a settings.json hook would need to be added via the `update-config` skill.

## Common failure modes

- **"No diff to review"**: branch has no commits past the base. Check `git log base..HEAD` — likely on the wrong branch.
- **Reviewer hangs**: all three CLIs can hang on auth or on first-run config prompts. The wrapper has a timeout (5 min/reviewer); if it fires, surface stderr so the user can re-auth.
- **Reviewer flags a tokens-vs-hardcoded issue that's actually fine**: Vibrant Punk / NativeWind contexts use tokens that look like hex to the reviewer. Check `constants/theme.ts` before "fixing" a perceived hardcoded color.
- **Same finding keeps coming back**: either the fix is wrong, or the reviewer has a stale mental model (e.g., you moved logic to another file and it still complains about the old location). Don't loop — stop and investigate.
- **Iteration 3 still dirty**: structural issue. Don't push through — ask the user whether to merge with known findings or take a different approach.

## What this skill does not do

- It does not run lint/type/test suites as the reviewer. Those are Claude's own pre-PR checks — this skill layers on top.
- It does not replace human review. The goal is to raise the floor, not to auto-merge.
- It does not invent findings. If reviewers have nothing to say, report that honestly and stop.
