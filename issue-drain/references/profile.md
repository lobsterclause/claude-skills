# The repo profile

One TOML file per repo, `profiles/<owner>__<repo>.toml`. The name is matched without regard to case. `ISSUE_DRAIN_PROFILE` points at a different file when set.

A repo with no profile stops every command. The hold labels and protected paths are the profile, and running on guesses is how an agent ends up editing a workflow file. An unknown key also stops the command, so a misspelt `protected_path_re` cannot quietly fall back to the default.

To add a repo, copy an existing profile, then check each label against `gh label list --repo <owner>/<repo>` and each path pattern against the repo's layout.

## Keys

| Key | Default | Meaning |
|---|---|---|
| `base_branch` | `main` | The branch issues are read against and PRs target |
| `hold_labels` | `needs-human`, `blocked` | An open issue carrying any of these is left out at intake, and is not closed by `close-verified` |
| `claim_label` | `agent-in-progress` | Marks an issue some agent is working on. Left out at intake; listed as a stale claim when older than `stale_claim_days` |
| `blocked_label` | `needs-human` | Added to a draft PR the drain could not finish (used by units) |
| `tracker_label` | `issue-drain` | Put on the tracker issue. Created if the repo lacks it |
| `priority_labels` | none | Highest priority first. An issue with none of these sorts last |
| `protected_path_re` | workflows, `.husky`, `.claude` | A fix on a matching path becomes `needs_human`; no unit touches it |
| `risk_path_re` | none | A unit touching a matching path is never clustered with another live issue, must name its reviewer in `waits_for`, and waits for that person after opening its PR |
| `trusted_associations` | `OWNER`, `MEMBER`, `COLLABORATOR` | Author associations whose issue text may be shown to agents with write tools |
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

Both path patterns are regular expressions matched against repo-relative paths, ignoring case. Labels are compared ignoring case, as GitHub does. The base branch and the three single labels are checked for shape, because they become `git` and `gh` arguments.
