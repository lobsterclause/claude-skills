# Splitstream

`/splitstream` turns a list of repository tasks into isolated, auditable branches that Claude Code can work on in parallel. You still type one simple command; Splitstream handles the preflight, frozen base SHA, worktree isolation, proof contracts, independent verification, and draft pull requests.

```text
/splitstream fix #41, add the missing cache regression test, and update the migration notes
```

Splitstream never auto-invokes. Before agents edit anything, it shows the complete plan and waits for approval. Add `--yes` to that same invocation only when you want to approve the displayed valid plan without a second prompt.

## Install with the exact `/splitstream` command

Install the standalone skill into your personal Claude Code skills directory:

```bash
mkdir -p "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills"
gh repo clone lobsterclause/splitstream-skill \
  "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills/splitstream"
```

Restart Claude Code. Then run `/splitstream`.

To update it later:

```bash
git -C "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills/splitstream" pull --ff-only
```

The repository is private, so `gh auth login` must already grant your GitHub account access.

## Install from the marketplace

Inside Claude Code:

```text
/plugin marketplace add lobsterclause/claude-skills
/plugin install splitstream@claude-skills
```

Claude Code namespaces plugin skills, so the marketplace form is invoked as:

```text
/splitstream:splitstream
```

That namespace is a Claude Code plugin rule, not a Splitstream design choice. Install the standalone package above if preserving the shorter `/splitstream` spelling is the priority. You can keep both installed.

## What happens in a round

1. Splitstream resolves the tasks and proposes bounded shards.
2. A standard-library helper validates paths, commands, collisions, dirty-file overlap, and the base ref.
3. You approve one readable table.
4. Worker agents implement conflict-free shards in isolated worktrees, one wave at a time.
5. The helper audits every branch; a fresh agent independently verifies each diff.
6. The parent pushes approved branches and opens draft pull requests.

Workers never publish, mutate issues, bypass hooks, rewrite history, or clean your worktree. Legitimate outcomes such as “already fixed,” “not reproducible,” and “blocked” remain first-class results instead of being forced into empty pull requests.

## Requirements

- Claude Code with Agent/worktree support
- Python 3.9 or newer
- Git
- GitHub CLI authenticated for publication (`gh auth login`)

The helper has no third-party Python dependencies.

## Development

Run the test suite from the repository containing this package:

```bash
python3 -m unittest discover -s splitstream/tests -v
python3 splitstream/scripts/splitstream.py doctor --repo .
```

The source package is intentionally portable: the same files live at the root of `lobsterclause/splitstream-skill` and under `splitstream/` in the marketplace repository.
