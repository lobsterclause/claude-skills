# Investigation: antigravity / gemini-pro reviewers failing with empty output

## Symptom
Both `antigravity` and `gemini-pro` cross-review reviewers (score 0 on the
leaderboard, `runs 0/6`) fail every attempt since 2026-07-16T16:25:49Z:
`exit_code=5`, `output_bytes=0`, `failure_kind=empty_output`, 3-18s duration.
(`exit_code=5` here is `run_reviewers.sh`'s own classification code for
`empty_output` — the `agy` process itself always exits 0; see Reproduction.)
Both reviewers share the same underlying `agy` (Antigravity) CLI, and both
broke in the same run at the same timestamp.

## Root cause
`agy` auto-updated to 1.1.4 (currently installed: `agy --version` → 1.1.4).
Its 1.1.3 changelog entry:

> Fixed headless (`-p`) runs hanging or silently auto-approving tools that
> require a permission confirmation, so the CLI now soft-denies such tools
> and prints a stderr notice naming the allow-rule needed to permit them.

Before 1.1.3, headless print-mode (`-p`) runs silently auto-approved any
tool confirmation (including Bash/RunCommand). `run_reviewers.sh`'s review
prompt tells the model to "use your file-reading tools to inspect the
actual changes" — the model calls Bash (`git diff`, `cat`, etc.), and as of
1.1.3+ that call is now soft-denied in headless mode instead of
auto-approved. The conversation ends without ever emitting final text —
rc=0, 0 bytes stdout — which `run_reviewers.sh` correctly classifies as
`empty_output`, but the real cause is a permission deadlock, not expired
auth or exhausted quota (the doc comment's existing guess).

## Reproduction
Built the exact `full_prompt` (`review_prompt.txt` + `git diff --stat`) that
`run_agy_reviewer()` constructs and ran both models concurrently via `agy
--sandbox --print-timeout ... -p "$full_prompt"` from this repo. Got the
identical signature: `rc=0`, `0` bytes stdout, and:

```
stderr: jetski: no output produced — a tool required the "command"
permission that headless mode cannot prompt for, so it was auto-denied.
Add an allow-rule under permissions.allow in settings.json (e.g.
command(<target>)). Alternatively, re-run with
--dangerously-skip-permissions to auto-approve all tools.
```

The `.agy.log` (agy's own per-run log, pinned via `--log-file`) confirms:
`tool_confirmation_manager.go:183] Print mode: soft-denying tool
confirmation "Bash" at step N`.

Sanity checks that ruled out the alternatives:
- `agy models` lists both `Gemini 3.5 Flash (High)` and `Gemini 3.1 Pro
  (High)` correctly — model names in the script are still valid.
- A trivial `-p` prompt with no tool use succeeds fine, alone and run
  concurrently (rules out auth expiry and agy-instance lock contention).
- Only reproduces once the prompt instructs real file-reading/tool use.

## RESOLVED 2026-07-31 (verified live, both laps rc=0)

The `permissions.allow` route below does NOT work as a fix and was abandoned:
it is whack-a-mole, and the FIRST command outside the list is fatal. With a
14-rule read-only allow-list in place the laps still died in sequence on
`printf '%s' "" | jq ...`, then `find /Users/... -name cross-review`, then
`git diff HEAD~1 > /tmp/cr_diff.patch`, then `bash cross-review/tests/run_tests.sh`.
Two of those (`find`, `git rev-parse`) had a second cause: agy's sandbox starts
the model in `~/.gemini/antigravity-cli/scratch`, not the repo, so the model
went hunting for the repository it had been asked to review.

What actually fixes it, all three parts required:

1. **`scripts/agy_shell_gate.sh` + a temporary `<repo>/.agents/hooks.json`** —
   a `PreToolUse` hook on `run_command` that answers every command with
   `{"decision":"allow","overwrite":{"CommandLine":"echo <explanation>"}}`.
   The model never triggers a permission request (so the run never dies) and no
   reviewer-authored command ever runs (so the read-only guarantee is stronger
   than `--dangerously-skip-permissions`, which was never needed). The echoed
   text tells the model to use its file-reading tools instead, and it does.
   `run_reviewers.sh` installs the hook once before dispatch (both laps share
   it) and removes it in the same trap that reaps reviewer pids; a pre-existing
   `hooks.json` is merged with `jq` and restored afterwards.
   agy discovers hooks at `<workspace-root>/.agents/hooks.json` **only** — a
   temp cwd is not scanned ("loaded 0 named hooks", even after `git init`), so
   the file has to live in the repo under review for the duration of the laps.
2. **`--add-dir "$repo_root"` on the agy invocation** — mounts the repo in the
   workspace so the model can read files without shelling out to find them.
3. **`"permissions": {"allow": ["command(echo)"]}` in
   `~/.gemini/antigravity-cli/settings.json`** — the *rewritten* command line is
   still permission-checked, and the hook's own `permissionOverrides` does not
   cover it (tested: the run still died on `echo`). This one rule is the entire
   global footprint; `run_reviewers.sh` warns when it is missing.

Verified on agy 1.1.8 against `--base HEAD~1` in this repo: antigravity rc=0 /
4886 bytes, gemini-pro rc=0 / 3712 bytes, `.agents/` removed afterwards.
Regression tests live in `cross-review/tests/run_tests.sh` under
"agy shell gate" (151 passed, 0 failed).

The section below is kept as the record of the abandoned approach.

## Fix (proposed, NOT verified live)
Add a scoped `permissions.allow` rule to `~/.gemini/antigravity-cli/settings.json`
(the CLI's global config — currently only has `enableTelemetry` and
`trustedWorkspaces`) for the specific read-only commands reviewers need:

```json
{
  "permissions": {
    "allow": [
      "command(cat)", "command(ls)", "command(grep)", "command(rg)",
      "command(head)", "command(tail)", "command(wc)"
    ]
  }
}
```

**Correction (caught by cross-review, 5/14 reviewers convergent):** the
original draft of this list also included `command(git)`, `command(find)`,
and `command(sed)` — dropped here because `command(<name>)` matches the
*whole* binary, not a read-only subset: `git` can `reset --hard`/`checkout
--`/`push`, `sed -i` edits files in place, and `find -delete`/`-exec rm`
deletes. Adding those verbatim would silently reintroduce the exact
write-approval risk this doc argues against. If `git` inspection is needed,
prefer scoped subcommand rules if agy's matcher supports them —
`command(git diff)`, `command(git log)`, `command(git show)`, `command(git
status)` — over the bare binary. Also note this is `agy`'s *global* config:
whatever gets allow-listed here applies to every `agy` session on the
machine, not just sandboxed reviewer runs — a repo-local/`--settings`-scoped
file would be safer if the CLI supports one.

This mirrors the exact fix the CLI's own stderr names, and matches
`run_reviewers.sh`'s existing policy of NOT using
`--dangerously-skip-permissions` (that flag also auto-approves file writes,
defeating the read-only review guarantee — see run_reviewers.sh:886-887).

I applied this change temporarily to verify it, but a follow-up live test
(re-running `agy` with the fix in place) was blocked by Claude Code's own
auto-mode classifier (flagged as "instructing an AI agent to run shell
commands" after the first repro). I reverted the settings.json edit back to
its original state rather than leave an unverified change in place.

**Next step**: apply the `permissions.allow` block above and re-run
cross-review once (or test `agy -p "..."` with a tool-using prompt
interactively) to confirm reviews complete. If `command(<name>)` isn't the
right match granularity, the CLI's `/permissions` TUI panel (interactive
mode) can show the exact rule it's waiting for.

## Non-causes ruled out
- Not quota exhaustion (`agy.log` has no `Individual quota reached` line).
- Not expired OAuth (`agy models` and trivial `-p` calls succeed).
- Not concurrency/lock contention between the two parallel agy processes
  (reproduces identically running gemini-pro alone).
