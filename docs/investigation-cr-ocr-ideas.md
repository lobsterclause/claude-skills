# Cross-review enhancements lifted from alibaba/open-code-review

**Status:** fact-check gate + snippet-anchor implemented (2026-06-18); rules.json + diff-filter specced, not built.
**Source:** [alibaba/open-code-review](https://github.com/alibaba/open-code-review) (Apache-2.0, Go), read at commit cloned 2026-06-18 into `/tmp/open-code-review`. Mechanics extracted from `internal/*.go` + `internal/config/template/task_template.json`, not the README.

## Why

`ocr` benchmarks ~85% precision at ~1/9 the tokens of a general agent. Reading the source, that number is earned by **two** real subsystems (a falsify-only fact-check pass and snippet-anchored line resolution) plus a layered rule corpus and an extension/test filter. Several other advertised subsystems (file "bundling," dedup, confidence scoring) **do not exist in the code** — it's per-file fan-out with a bare finding struct. CR is already ahead on the output side (severity, dedup, cross-provider convergence); the wins are on the *input discipline* and *false-positive suppression* side.

This doc specs the two highest-leverage lifts and sketches the two follow-ups.

---

## 1. Falsify-only fact-check gate — **IMPLEMENTED**

### What ocr does
After reviewing a file, `executeReviewFilter` (`internal/agent/agent.go:593`) makes a *separate* LLM call (`REVIEW_FILTER_TASK`) that sees **only the diff** and deletes review comments the diff itself disproves — then removes them by index from the collector. The prompt's governing principle, verbatim from `internal/config/template/task_template.json`:

> Your task is **NOT to verify** whether all review comments are correct, but to **filter out only those review comments that can be confirmed as incorrect based solely on the current diff**... **Core principle: you need to falsify, not verify.** Flag only when the diff contains *direct counter-evidence*. If a claim references context not in the diff, or you merely "cannot verify," **let it pass** — the Agent may have context you cannot see.

This is **recall-safe by construction**: it can only ever *remove* a finding the diff actively contradicts. It never invents findings and never drops a finding it merely can't confirm.

### Why CR needs it (and why convergence doesn't already cover it)
- Convergence dedups *across reviewers*; the fact-check disproves a *single* finding against the diff. Orthogonal mechanisms — a solo finding that survives convergence can still be diff-disproven.
- CR's **auto-fix loop (step 5)** is the riskiest surface in the skill: a hallucinated solo Critical/High drives a bad commit. The gate runs *before* auto-fix, so the most dangerous false positives are filtered before they touch the tree.
- It's the principled, generalized form of the existing [kimi-calibration memory](../.claude/.../memory) ("discount diff-only file-wide-invariant claims unless convergent"): instead of a per-reviewer prior, *every* candidate finding faces a diff-only veto.

### CR integration
New **step 4.5** in `SKILL.md`, between synthesis (4) and auto-fix (5):

1. Synthesis (step 4) now also emits a structured `findings.json` sidecar next to `findings.md` (schema below).
2. `scripts/factcheck_findings.sh` feeds `(diff + findings.json)` to a **cheap, diff-only** reviewer (default `agy` Flash; `kimi` is the philosophically purest since it's already diff-only-no-tools) using `references/factcheck_prompt.txt`.
3. The reviewer returns the ids it can *disprove from the diff alone*, with reasons. The script writes `verdicts.json`.
4. Orchestrator marks dropped findings in `findings.md` (struck through, with the veto reason) and **excludes them from the auto-fix triage**. Dropped findings are recorded, never silently deleted.

**Fail-safe contract:** if the fact-check call errors, times out, or returns unparseable output, **drop nothing** (keep all findings). A broken veto must never cost recall. This is enforced in the script (parse failure → empty drop set).

### findings.json schema (shared by both lifts)
```json
{
  "base": "origin/main",
  "head": "HEAD",
  "findings": [
    {
      "id": "f1",                       // stable within a pass
      "severity": "Critical|High|Medium|Low",
      "file": "path/relative/to/repo",
      "line": 42,                        // reviewer-cited; may be wrong (see lift 2)
      "snippet": "the exact offending line(s) the reviewer quoted, verbatim",
      "claim": "one-line statement of what is wrong",
      "sources": ["codex", "gemini-pro"],
      "suggested_fix": "optional short text"
    }
  ]
}
```
`snippet` is the load-bearing new field: it is what lift 2 anchors against and what gives the fact-check something concrete to falsify. Synthesis must instruct reviewers (already prose-instructed) to quote the offending code.

### Verification
- Deterministic: feed a `findings.json` with one finding whose `claim` is contradicted by the diff (e.g. claims "uses `==`" where the diff shows `===`) → fact-check must list its id in `drop`. A finding referencing unseen context → must be kept.
- Fail-safe: point `--reviewer` at a nonexistent CLI → script exits cleanly with an empty drop set, every finding kept.

---

## 2. Snippet-anchored line resolution — **IMPLEMENTED**

### What ocr does
`internal/diff/resolver.go` ignores the model's claimed line number and **re-derives** it: it normalizes the model's quoted snippet (`ExistingCode`) and the diff's hunk lines (trim, strip leading `+`/`-`, skip blanks), then looks for a consecutive exact match — new-side first, then old-side, then a full-file scan. The matcher (`resolver.go:147`):

```go
func matchConsecutive(sideLines []indexedLine, targetLines []string) (start, end int, found bool) {
    if len(targetLines) == 0 || len(sideLines) < len(targetLines) { return 0,0,false }
    for i := 0; i <= len(sideLines)-len(targetLines); i++ {
        matched := true
        for j, t := range targetLines { if sideLines[i+j].content != t { matched=false; break } }
        if matched { return sideLines[i].lineNum, sideLines[i+len(targetLines)-1].lineNum, true }
    }
    return 0,0,false
}
```
On no match, the line stays `0` (unresolved). No fuzzy/nearest-snap. Optional LLM re-location regenerates the snippet and retries.

### Why CR needs it
CR has only *advisory prose* today: "don't trust the reviewer's line numbers blindly; the diff may have shifted them." This converts that into a **binding, deterministic check** (CLAUDE.md verification ladder, level 1 → level 2). A finding whose quoted snippet does not appear anywhere in the changed hunks is, with high probability, a hallucinated location — exactly the failure the dirty-tree guard already worries about.

### CR integration
`scripts/anchor_findings.sh` runs **before** the fact-check (deterministic, no tokens):
- For each finding, normalize its `snippet` and match it against the diff's added/context lines (new side) then deleted/context lines (old side).
- Annotate each finding: `anchor: { resolved: bool, start_line, end_line, side }`.
- `resolved:false` findings are surfaced as **"⚠ unanchored — snippet not found in diff; probable hallucinated location"** in `findings.md`. They are *not* auto-dropped (a reviewer may legitimately reference an unchanged neighbouring line) but they are demoted and never auto-fixed without human confirmation.
- Resolved findings get their `line` corrected to the re-derived `start_line`, fixing the "diff shifted the numbers" problem before fixes are applied.

### Verification
- Deterministic, no LLM: a finding whose `snippet` is a verbatim added line → `resolved:true`, `line` corrected to the real hunk line. A finding with a `snippet` absent from the diff → `resolved:false`, flagged.

---

## 3. Layered `rules.json` corpus — **SPEC ONLY**

`ocr`'s rule system (`internal/config/rules/system_rules.go`) is a clean 4-layer precedence (`--rule` flag > project `.opencodereview/rule.json` > global `~/.opencodereview/rule.json` > embedded `system_rules.json`), first-match-wins, doublestar + brace-expansion path globs, resolved markdown injected into the prompt as `{{system_rule}}`. The embedded corpus is a `path→markdown` map; bodies are per-language checklists (`rule_docs/default.md` covers Correctness/Security/Performance/Maintainability/Test-Coverage; `java.md`, `ts_js_tsx_jsx.md`, etc. add language specifics).

**CR adoption:** replace the half-built `ast-grep` enrichment (SKILL step 2.6) with a `references/rules/` corpus + a `resolve_rules.sh` that walks the same 4 layers and injects the matched rule body into `run_reviewers.sh`'s `$review_prompt` preamble per changed path. The Apache-2.0 license permits seeding CR's corpus from `ocr`'s `rule_docs/*.md` with attribution. Bigger lift; do after 1+2 land and prove out.

## 4. Diff pre-filter — **SPEC ONLY (lift *and improve*)**

`ocr` filters changed files through (in order): binary check, user exclude globs, user include globs, an **extension whitelist** (`supported_file_types.json`, 69 entries), and **test-file excludes** (`default_exclude_patterns.json`, e.g. `**/*_test.go`, `**/*.{test,spec}.{js,jsx,ts,tsx}`, `**/__tests__/**`). All lowercased.

**Gap to improve on:** there is **no lockfile/generated exclude** — `package-lock.json` passes (it's `.json`). If CR ports this, add explicit excludes for lockfiles (`*-lock.json`, `pnpm-lock.yaml`, `yarn.lock`, `Cargo.lock`, `poetry.lock`, `go.sum`), minified/generated (`*.min.*`, `**/dist/**`, `**/vendor/**`, `**/generated/**`, `*.snap`). Applied once in the diff-prep, the savings multiply across all 4 reviewers and shrink the `warn_secrets` surface. Drive it from the same `rules.json` `exclude` block as lift 3.

---

## What NOT to lift
- **"File bundling / review units"** — does not exist in `ocr`; it's per-file fan-out + concurrency(8) + an 80%-context token cap (oversized files are dropped, not split). No stem/dir grouping. Nothing to port.
- **Finding dedup / severity / confidence on the struct** — `LlmComment` is bare (path/content/lines/snippet only); `CommentCollector` is a plain slice with no dedup. CR's synthesis already produces severity-ranked, deduped, convergence-tagged findings. CR is the reference here, not `ocr`.

## Rollout order
1. ✅ `findings.json` schema + `anchor_findings.sh` (deterministic; testable with zero tokens).
2. ✅ `factcheck_findings.sh` + `factcheck_prompt.txt` + SKILL step 4.5 (fail-safe keep).
3. ⬜ `rules.json` corpus + resolver (subsumes ast-grep step 2.6).
4. ⬜ diff pre-filter (driven by the rules.json `exclude` block).
