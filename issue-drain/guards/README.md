# drain-guards

A Claude Code mod that `issue-drain` loads into each unit's `claude -p` process with `--plugin-dir`. It is never installed in ordinary sessions. It stops a unit from doing the shell driver's job (merging, closing, writing to GitHub) or wandering outside its worktree.

It is a guard against drift and simple prompt injection, not a sandbox. A determined command (an obfuscated string, a script that runs `gh` for it, a symlink out of the worktree) gets past it.

## How it finds the unit

The driver writes one JSON file per unit and sets `ISSUE_DRAIN_UNIT_FILE` to its path:

```json
{ "unit": 3, "worktree": "/abs/path", "branch": "fix/...", "state_dir": "/abs/path/units/3",
  "protected_paths": [".github/workflows", ".husky", ".claude", "firestore.rules", "storage.rules", "infra", "ci"] }
```

At `session.start` the mod validates it and writes `<state_dir>/guards-marker` (ISO timestamp and mod version). The driver refuses to merge a unit with no marker. If the file is missing, unreadable or invalid, every Bash, Edit, Write, NotebookEdit and Agent call is denied. Each guard also denies if it throws.

## What it denies

Bash (matched anywhere in the command, after `rtk`, `cd x &&`, `env A=b`, `;`, `|`, newlines, `$( )`, backticks and `bash -c`):

- merges: `gh pr merge`, `gh api` to a `/merge` or `/merges` endpoint
- closing, reopening, editing issues and PRs; `gh label`
- `git push` to anything but the unit branch on `origin`, and a push that does not name both (`git push`, `git push origin`, `git push origin HEAD`); any force flag
- bypass flags: `--admin`, `--auto` (with `gh`), `--no-verify`, `SKIP_PREPUSH`, `CROSS_REVIEW_MERGE_OVERRIDE`, `HUSKY=0`
- raw GitHub writes: `gh api` writes or bodies, GraphQL mutations and GraphQL query text read from a file (`--input`, `@file`), `gh pr|issue create|comment`, `gh release`, `gh workflow run`, `gh run rerun|cancel|delete`, `gh secret`, `gh variable`, `gh auth` but `status`
- `git worktree`, `git checkout|switch` to another branch, `git branch -d|-D|-m`, `git remote add|set-url|remove`, `git config --global|--system`, bare `git stash`, `stash pop|drop|clear`, `git --git-dir|--work-tree` (run git inside the unit worktree)

Allowed on purpose: read-only `gh`, `issue-drain gh-write ...`, cross-review's `post_comment.sh`, `git checkout -- <path>`, `git reset --hard origin/...`.

Edit, Write, NotebookEdit: denied outside the worktree or on a protected path. `state_dir` and `/tmp`, `/private/tmp`, `/var/folders` are allowed.

Agent: denied unless both `model` and `effort` are set. Each allowed call is appended to `<state_dir>/delegations.jsonl`.

## Files

- `hooks/rules.ts`: pure decision functions
- `hooks/register.ts`: loads the unit file, registers the guards
- `hooks/rules.test.ts`, `hooks/register.test.ts`: `claude plugin test .`

Known limits are marked `// shortcut:` in `rules.ts`.
