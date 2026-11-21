# The repo profile

One TOML file per repo, `profiles/<owner>__<repo>.toml`. The name is matched without regard to case. `ISSUE_DRAIN_PROFILE` points at a different file when set.

A repo with no profile stops every command. The hold labels and protected paths are the profile, and running on guesses is how an agent ends up editing a workflow file. An unknown key also stops the command, so a misspelt `protected_path_re` cannot quietly fall back to the default.

To add a repo, copy an existing profile, then check each label against `gh label list --repo <owner>/<repo>` and each path pattern against the repo's layout.

## Keys

| Key | Default | Meaning |
|---|---|---|
| `base_branch` | `main` | The branch issues are read against and PRs target |
| `hold_labels` | `needs-human`, `blocked` | An open issue carrying any of these is left out at intake, and is not closed by `close-verified` |
| `claim_label` | `agent-in-progress` | Marks an issue some agent is working on. Left out at intake; listed as a stale claim when older than `stale_claim_days`. A unit process may not add it with `gh-write`; only `claim take` does, with its marker comment |
| `blocked_label` | `needs-human` | Added to a draft PR the drain could not finish (used by units) |
| `tracker_label` | `issue-drain` | Put on the tracker issue. Created if the repo lacks it |
| `priority_labels` | none | Highest priority first. An issue with none of these sorts last |
| `protected_path_re` | workflows, `.husky`, `.claude` | A fix on a matching path becomes `needs_human`; no unit touches it |
| `frozen_paths` | none | Files or folders (trailing slash optional) a unit's diff may not touch; `deliver-check` fails with `frozen_path` |
| `risk_path_re` | none | A unit touching a matching path is never clustered with another live issue, must name its reviewer in `waits_for`, and waits for that person after opening its PR. `merge-gate` never merges such a unit; that person does. `deliver-check` also matches every path of the delivered diff against it and records the matches as `risk_paths_touched`; `merge-gate` refuses (`risk_path`) a unit with any, even one planned without risk paths |
| `trusted_associations` | `OWNER`, `MEMBER`, `COLLABORATOR` | Author associations whose issue text may be shown to agents with write tools. `merge-gate` also uses it for the review record: every stamped `## Cross-review` comment on the PR (the newest, and any older one the review script could count toward coverage) counts only when its author's association is in this list (case-insensitive), so an empty list means no PR is ever merged by the gate (`review_author`) |
| `intake_cap` | 40 | The most issues one run takes in |
| `stale_claim_days` | 3 | Age at which a claim is listed for release |
| `issue_classifier` | none | A command run in the checkout with `ISSUE_TITLE` and `ISSUE_BODY` set. It prints JSON with `verdict` and `appPaths`; a verdict of `app` leaves the issue out |
| `cluster_max_issues` | 4 | The most issues in one unit |
| `cluster_max_lines` | 400 | The changed-line estimate above which `overlap` flags a group |
| `evidence_line_slack` | 3 | How many lines off a reader's line number may be before the quote counts as missing |
| `evidence_min_quote` | 8 | The shortest quote, in characters, that counts as evidence |
| `allowed_models` | `haiku`, `sonnet`, `opus` | The models a unit line may name |
| `allowed_efforts` | `low`, `medium`, `high` | The effort levels a unit line may name |
| `unit_permissions` | "not set in the profile" | One line shown in the tracker header: what tools each kind of agent has |
| `guard_protected_paths` | `.github/workflows`, `.husky`, `.claude` | Files and folders (path prefixes, not a pattern) the guards mod keeps a unit from editing. Written to `guards-unit.json` by `unit-prepare`. Keep it in step with `protected_path_re` |
| `bootstrap_command` | none | Run in the new worktree by `unit-prepare`. `{worktree}` is its path; a relative program path is relative to the worktree. No shell runs it. It must be safe to run twice. A nonzero exit fails the step |
| `bootstrap_requires` | none | Paths that must exist in the main checkout before the worktree is made (for example `node_modules`). A missing one refuses with exit 3. Relative, no `..` |
| `bootstrap_timeout_secs` | 900 | The bootstrap is killed, with what it started, after this long |
| `codegraph_init` | `false` | When true and a `codegraph` program is on PATH, `unit-prepare` runs `codegraph init -i` in the worktree. A failure or a missing program is recorded in `unit.json`, never an error |
| `codegraph_timeout_secs` | 300 | The same limit for `codegraph init` |
| `full_verify_command` | none | The command a homelab verify must have run for `stamp-remote-pass` to stamp (`pnpm verify`). Empty means nothing is ever stamped |
| `stamp_command` | none | Run in the unit worktree to record the repo's verify stamp (a relative path with a `/` is relative to the worktree, as for `bootstrap_command`). `{tree}` is `HEAD^{tree}` and `{head}` is HEAD. Empty means `stamp-remote-pass` records `stamped: false` and does nothing else |

Both path patterns are regular expressions matched against repo-relative paths, ignoring case. Labels are compared ignoring case, as GitHub does. The base branch and the three single labels are checked for shape, because they become `git` and `gh` arguments.
