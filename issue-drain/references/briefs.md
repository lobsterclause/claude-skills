# Briefs

The prompts the session hands to subagents. Fill the angle-bracket parts; leave the rest as written.

## Triage reader

Agent type `issue-triage-reader` (Read, Grep and Glob only), model `haiku`, effort `low`. Set both on the call. Five issues per reader, two readers at a time.

```
Triage these issues for <owner>/<repo>.

Run folder: <absolute run folder>
Issues in your batch: <n1> <n2> <n3> <n4> <n5>
Each issue is in <run folder>/issues/<number>.md.
Read the code in: <absolute path of the base checkout>

Return one JSON array with a verdict for each of the <count> issues, as your instructions describe. Quote lines exactly, with their file and line number.
```

That is the whole brief. The reader's own instructions carry the schema and the rules, so a longer brief only gives it more to misread. Do not paste issue bodies into the brief: the reader opens the files, which carry the header that marks the body as material.

When the `issue-triage-reader` agent type is not installed, use `Explore` with the same brief, prefix it with the contents of `agents/issue-triage-reader.md` (below the frontmatter), and add one line: "Where the instructions say Grep and Glob and you lack those tools, search with read-only shell commands (grep, find, ls) inside the checkout. Run nothing else and write nothing." Explore may have no Grep or Glob of its own, and a reader that is forbidden the shell as well cannot search and returns `unclear` for everything. Tell the user that the read-only guarantee is weaker for that run.

Save each reader's array, unchanged, to `<run folder>/verdicts/<batch>.json`. If a reader wrapped it in prose or a code fence, save only the array. If it returned no array, do not write one for it: the evidence check gives every issue without a verdict an `unclear`, which is the honest result.

### Escalation

One retry, one tier up (`sonnet`, `low`), for a batch whose reader returned nothing usable. Do not retry to change a verdict you disagree with: re-read that issue yourself.

## Implementer

Launched by a unit (`unit.md`, step 2), never by triage. Agent type `general-purpose`, model and effort from `unit.json`; set both on the call. Give it the task statement, not the issue body.

```
You are implementing one change in <owner>/<repo>, in the git worktree that is your working directory. Stay in it. You are on branch <branch>; do not switch, rebase, push or open a pull request.

Task: <task statement from unit.json>

Issues and their acceptance checks (one check per issue):
- #<n>: <acceptance check>

Scope, the only paths you may change: <scope paths>
Existing code to reuse (quoted by the triage reader; check it still reads this way): <reuse pointers, or "none found">
Targeted test command: <test command, wrapped in a hard timeout>

How to work:
1. For each issue, write its acceptance check first and run it to see it fail. Then make it pass. If a check cannot be written first, say why and stop.
2. Follow the rules below under "Ponytail". Where they differ from this brief, this brief wins: the check comes before the code; never trim validation at a trust boundary, data-loss handling, security, accessibility, or <the profile's named fail-safes>; never add a dependency. If the right fix is a library this repo does not have, say so and stop.
3. To find code and callers use Grep and the LSP tool. If CodeGraph says it is not initialised, do not initialise it and do not ask.
4. Do not edit <protected paths> or <frozen paths>. If the fix needs one, say so and stop.
5. Run only the targeted tests here. The full verify runs elsewhere.
6. Commit early and small, staging files by name, never `git add -A`.
7. If an issue in this unit turns out to be a different change from the rest, leave it and say so.
8. Give any background command an explicit timeout.

End your report with: the commits you made; for each issue, the check and whether you saw it fail and then pass; anything handed back; and a last section "Skipped or not checked".

## Ponytail
<the text of references/ponytail-rules.md between its begin and end markers>
```

On a repair or a review fix, resume the same implementer with the evidence (the failing check's name and log, or the finding with its file and line) and nothing else. One tier up on its second failure, with the first attempt's evidence passed along.
