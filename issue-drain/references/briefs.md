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

When the `issue-triage-reader` agent type is not installed, use `Explore` with the same brief, prefix it with the contents of `agents/issue-triage-reader.md` (below the frontmatter), and tell the user: Explore can run shell commands, so the read-only guarantee is weaker for that run.

Save each reader's array, unchanged, to `<run folder>/verdicts/<batch>.json`. If a reader wrapped it in prose or a code fence, save only the array. If it returned no array, do not write one for it: the evidence check gives every issue without a verdict an `unclear`, which is the honest result.

### Escalation

One retry, one tier up (`sonnet`, `low`), for a batch whose reader returned nothing usable. Do not retry to change a verdict you disagree with: re-read that issue yourself.

## Implementer

Arrives with the unit-and-gate build. Triage does not launch an implementer.
