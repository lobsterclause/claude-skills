# Triage

From a set of issues to a tracker issue the user approves. Seven steps, in order. Each command reads the run folder's files and writes the next one, so a step can be re-run without redoing the ones before it. The exception is `intake`: once `evidence-check` has written `verdicts.checked.json` it is refused (exit 3), because the verdicts and the tracker are about the reports already saved. Start a new run to take issues in again.

`$ID` below is the launcher, `<skill folder>/bin/issue-drain`, called with the run's environment (SKILL.md, "Setting up a run").

## 1. Intake

```
$ID intake <number>...            # the issues the user named
$ID intake --label <label>        # or every open issue with a label (repeatable)
$ID intake --search '<query>'     # or a GitHub search
```

Writes `issues/<n>.json`, `issues/<n>.md` and `intake.json`, and prints a one-line summary. An issue is left out, with the reason recorded under `skipped`, when it is closed, carries a hold label or the claim label, has an open PR, belongs to another repo by the profile's classifier, or falls over the cap. Report the skipped ones to the user with their reasons; issues with an open PR belong to `pr-drain`.

An issue is also skipped when GitHub returned only part of it: more labels, linked PRs or timeline events than one page holds. The reason names what was cut. Intake does not judge an issue it could not read whole, so a person looks at those.

`--label` and `--search` list up to three times the cap, because held and claimed issues do not count against it, and intake stops reading once the cap is full. A label or search that matches nothing writes an empty `intake.json` and exits 0; tell the user there was nothing to triage.

`stale_claims` lists issues whose claim label is older than the profile allows and which have no open PR. They are not taken in. They appear on the tracker for the user to tick for release.

If intake takes in nothing, say so and stop.

## 2. Read

Split the eligible numbers (`jq '[.eligible[].number]' intake.json`) into batches of five. Launch readers two at a time with the brief in `briefs.md`, wait for both, then launch the next two. Save each returned array to `verdicts/<batch>.json`.

Two at a time keeps this under the user's pre-flight threshold for parallel agents and keeps a 40-issue intake to about four rounds.

A reader sees only its own batch, so it can call two issues duplicates only when they share one. Duplicates split across batches come back as two `live` verdicts with the same file and symbol, and `overlap` in step 5 proposes them as a pair. Sorting the numbers so that issues with the same label or area sit together helps, but do not rely on it.

Readers read the base checkout, so it must be at the base branch's tip (SKILL.md, "Setting up a run"). A reader that read a stale tree quotes lines the check will not find.

## 3. Check the evidence

```
$ID evidence-check "$ISSUE_DRAIN_WORKDIR"/verdicts/*.json
```

Name the run folder: a bare `verdicts/*.json` is read from wherever the shell happens to be.

Writes `verdicts.checked.json` and prints what it downgraded and why. This step is not optional and its output replaces the readers' verdicts everywhere after it. It:

- finds every quoted line on `origin/<base>` (the remote branch, even if a tag or a local branch has that name) and corrects the line number, or downgrades the verdict to `unclear`
- dates each `already_fixed` quote with `git blame`: a line older than the issue is not its fix, so the verdict becomes `unclear`
- fails a quote that blame credits to the commit a shallow clone was cut at, since that commit may not be the one that wrote the line
- sets `closable` on an `already_fixed` verdict only when the bug is not behavioural
- turns a fix on a protected path into `needs_human`, and marks `risk` on a risk path
- gives an eligible issue with no verdict an `unclear` one, and drops a verdict for an issue this run did not take in
- makes a verdict `unclear` when one of its `likely_files` is not a path inside the repo (absolute, starting with `-`, or with an empty, `.` or `..` part), and does not keep that path

Do not edit `verdicts.checked.json` by hand. If you think a downgrade is wrong, read the code; if the reader misquoted a line that is there, fix the quote in the `verdicts/` file and run the check again.

## 4. Confirm each closure yourself

For every verdict with `status: already_fixed` and `closable: true`, open the quoted file and read the function around the line. You are answering one question: does the code on the base branch now do what the issue asked, on every path, or did a formatter or an unrelated edit touch that line?

- Confirmed: it goes in `confirmed_closures` with a one-sentence `note` saying what you read. The note is shown on the tracker and in the closing comment, so write it for the issue's author.
- Not confirmed: leave it out of `confirmed_closures`. It is then listed under "Needs verification" and nothing closes it.

Do not delegate this. Three of eight "obsolete" calls were wrong the last time a cheap reader's word was taken for it.

An `already_fixed` verdict that is not closable is behavioural: the code looks like the fix, and only the running app can say. It is listed under "Needs verification" automatically.

## 5. Cluster

```
$ID overlap
```

Writes `overlap.json` and prints the proposal: pairs (`duplicate`, `cluster_candidate`, `adjacent`) and groups, each with an estimated size and the flags `over_cap`, `over_lines` and `risk`. It proposes; you decide.

Put two issues in one unit only when they are one logical change:

- the same root cause, so one edit fixes both
- interleaved edits in one function
- one mechanical pattern at several sites
- a duplicate and its original

Otherwise keep them apart. Small single-purpose PRs review and revert cleanly, and a unit that grows past the caps gets split by the implementer anyway. Issues that only share a file are `adjacent`: separate units, which the renderer places back to back so the second starts from the first's merged result.

A unit never has more issues than `cluster_max_issues`. A group flagged `over_lines` should be split. An issue on a risk path shares a unit only with its own duplicates.

## 6. Write decisions.json and render

`decisions.json` in the run folder is your half of the queue:

```json
{
  "units": [
    {
      "issues": [103, 106],
      "title": "Zero-pad the countdown seconds with formatDuration",
      "model": "haiku",
      "effort": "low",
      "est_minutes": 30,
      "test_command": "pnpm vitest run src/timer"
    },
    {
      "issues": [108],
      "title": "Match crisis phrases typed with a curly apostrophe",
      "model": "sonnet",
      "effort": "medium",
      "est_minutes": 60,
      "test_command": "pnpm vitest run src/crisis",
      "waits_for": "clinical review"
    }
  ],
  "confirmed_closures": [
    { "number": 101, "note": "Re-read logout(): the reset is unconditional and nothing else caches the count." }
  ],
  "left_out": [
    { "number": 104, "reason": "Depends on the pagination rewrite in #98." }
  ]
}
```

For each unit:

- `title`: what the PR does, as an imperative phrase.
- `model` and `effort`: the cheapest that can do it well. `haiku`/`low` only for an exact-target mechanical change where the file and line are known and nothing has to be found. `sonnet`/`medium` for ordinary coding with a clear brief; this is the default. `opus`/`medium` for a hard or high-stakes change.
- `est_minutes`: implementation through review, not counting CI. Above about 90, split the unit.
- `test_command`: the targeted test run that proves the acceptance checks, as the repo runs tests. One line.
- `waits_for`: required on a risk-path unit. Name the role or person who reviews its PR.
- Optional overrides: `files`, `size`, `kind`, and `acceptance` (an object keyed by issue number) when the reader's check is vague. Every issue needs an acceptance check that fails before the fix and passes after it. `files` are repo-relative paths, and a risk path among them makes the unit a risk unit even when no verdict named one.

`left_out` is for a `live` or `duplicate_of` issue you are deliberately not queueing, with the reason.

Then:

```
$ID tracker render
```

It writes `queue.json` and `tracker.md`, or prints every rule the decisions break and writes nothing (exit 3). The rules: every live issue is in exactly one unit or in `left_out` with a reason; a unit holds only live issues and duplicates of its own members; the caps; the risk and protected path rules; a title, an allowed model and effort, a whole positive number of minutes and a one-line test command per unit; `kind`, `test_command` and `waits_for` are strings; a unit has at least one live issue, and every duplicate in it leads to one (two that name each other lead nowhere, whatever else is in the unit); a closure must be `already_fixed` and closable. Fix `decisions.json` and render again until it exits 0.

The renderer orders the queue: priority label, then smaller units first, with units that share a file back to back. It decides which sections each issue lands in. Do not edit `tracker.md`.

## 7. Publish and stop

Read `tracker.md` once as the user will see it. Then:

```
$ID tracker publish
```

It creates the tracker issue with the profile's tracker label, records it in `tracker.json`, and prints the URL. A run publishes once; a second call is refused. In a dry run it prints the call it would make and creates nothing, and `tracker.md` is the deliverable.

Before it creates anything it lists your own open issues with the tracker label. If one already carries this run's marker line (a publish that was cut off after GitHub created the issue), and its body is the `tracker.md` rendered now, it records that issue and creates no second one. If the body differs (the run was rendered again after the cut-off publish), it is refused (exit 3): close that issue and publish again. If the list cannot be read, it exits 1 and creates nothing.

`publish.lock` in the run folder exists while a render or a publish runs. A render or a publish that finds it is refused (exit 3). If neither is running (the process was killed), remove the file and run it again.

`tracker render` refuses an `intake.json` fetched from a repo other than `ISSUE_DRAIN_REPO`, and `tracker publish` and `tracker parse` refuse a `queue.json` rendered for one (exit 2). Render removes the old `tracker.md` before it writes the queue, so a render that was cut off leaves nothing to publish. For each closure it copies the title and body from `issues/<n>.json` into `queue.json`, and `close-verified` later holds the live issue against that copy; a closure whose saved report is missing is a usage error (exit 2).

Give the user the link and a short summary: how many units, how many closures offered, what needs a person, what was skipped at intake. Then stop. This is the one pause. The user edits the tracker body: deletes or reorders queue lines, ticks closures, ticks risk units, ticks claims to release, or writes `STOP`.

## After the user says go

```
$ID tracker parse          # what the body says now
$ID close-verified         # close every ticked closure
```

`tracker parse` prints JSON: the units still on the queue in the user's order, `approved_closures`, `release_claims`, `stop`, the tracker's state (`tracker_state`), and `unknown` (ticked lines the run never offered). It reads only lines GitHub shows as lines: a box inside a fenced code block or an HTML comment counts for nothing, except `STOP`, which counts wherever it stands. A risk unit runs only with its box ticked; its line with the box deleted is ignored. Anything in `unknown` means the body was edited in a way the drain does not understand: show it to the user and do nothing else until it is gone.

If `stop` is `true` or `tracker_state` is not `OPEN`, the user called the run off. Close nothing and release no claim.

`close-verified` re-checks each ticked closure against the base branch as it is now, then comments and closes. Its conditions and exit codes are in SKILL.md. Report each line it prints. A refused closure is not an error to work around: tell the user which issue and why.

For each number in `release_claims`, look at the issue as it is now before touching it. The claim was stale when the tracker was rendered, and the user may have ticked it days later:

```
gh issue view <number> --repo <owner>/<repo> --json state,labels,closedByPullRequestsReferences
gh pr list --repo <owner>/<repo> --state open --search "<number> in:title,body" --json number,title
gh api "repos/<owner>/<repo>/issues/<number>/timeline" --paginate \
  --jq '.[] | select(.event == "labeled" and .label.name == "<claim label>") | .created_at'
gh api "repos/<owner>/<repo>/issues/<number>/timeline" --paginate \
  --jq '.[] | select(.event == "cross-referenced" and .source.issue.pull_request != null and .source.issue.state == "open") | .source.issue.number'
```

The fourth command lists open PRs that mention the issue anywhere, including in a comment, which the search in the second does not find.

Release it only when the issue is open, still carries the claim label, has no open PR (the second and fourth commands print nothing), and the last date the third command prints is the `labeled_at` that `queue.json` holds for it under `stale_claims`. A later date means the label came off and someone claimed the issue again after the tracker was rendered: that claim is not stale. If someone picked it up again, leave the label and tell the user. Then remove the claim label and nothing else:

```
$ID gh-write remove-label <number> <claim label>
```

The units on the queue are run by the unit-and-gate build, which is not in this version. Until it lands, the queue is the plan the user works from.
