<!-- issue-drain:tracker v1 run=run -->
This is the queue for an issue drain of `example/tidepool` into `develop`. Nothing has been changed yet: no issue is claimed, labelled or closed until you say go.

To change what runs, edit this body:

- Delete a line under **Queue** to drop that unit. Move lines to reorder them.
- Tick a box to approve that item. An unticked box means no.
- Put the word `STOP` on a line of its own, anywhere in this body, to stop the drain once the unit in progress has finished.

The drain reads this body at the start of each unit and never edits it. Progress is posted as comments.

Base `develop` at `1dc973b` · 12 issues taken in · 4 units · permissions: triage readers: Read, Grep, Glob only

## Queue

- U1 · #103 #106 · Zero-pad the countdown seconds with formatDuration · haiku/low · ~30 min · `pnpm vitest run src/timer`
- U2 · #104 #105 · Fix pageCount for totals that divide evenly · sonnet/medium · ~45 min · `pnpm vitest run src/list`
- U3 · #111 · Keep focus in the search box while typing · sonnet/medium · ~45 min · `pnpm vitest run src/search`

## Close as already fixed (tick to approve)

Each was read twice against the base branch. The closing comment quotes the lines and names the fixing commit.

- [ ] close #101 · Badge count stays after logout · fixed by `4b960d3` (#12) · `src/auth/session.ts:16` · Re-read logout(): the reset is unconditional and nothing else caches the count.

## Units that open a PR and then wait for a person (tick to include)

Each touches a path that needs a named reviewer. A ticked unit runs before the queue, opens its PR and waits there, so the review can start while the rest drains.

- [ ] U4 · #108 · Match crisis phrases typed with a curly apostrophe · sonnet/medium · ~60 min · waits for: clinical review · `pnpm vitest run src/crisis`

## Needs a person

- #107 · CI caches the wrong directory · protected path: .github/workflows/ci.yml
- #109 · Add a dark theme option · The issue asks open product questions: follow the system, add a toggle, or both, and whether brand colours change.

## Needs verification

Code that looks like the fix is on the base branch, but nothing here closes these.

- #102 · Toasts overlap when two fire together · looks fixed by 1dc973b (fix(ui): stack toasts instead of overlapping (#14)). The bug is behavioural, so it needs a look in the running app.

## Unclear

- #110 · App feels slow sometimes · No steps, no screen and no time: nothing in the report points at code.
- #112 · clamp returns NaN for empty input · every quoted line is older than the issue, so none of them is its fix

<details><summary>Acceptance checks, files and reuse for each unit</summary>

**U1** · #103 #106 · bugfix · size S

- #103: countdownLabel(65000) returns "1:05".
- #106: countdownLabel(127000) returns "2:07".
- files: `src/timer/countdown.ts`
- reuse: `src/lib/format.ts:2`

**U2** · #104 #105 · bugfix · size S

- #104: pageCount(20, 10) returns 2 and renderLastPage of 20 items at size 10 returns 10 items.
- #105: renderPager(30, 10) returns "\[1] \[2] \[3]".
- files: `src/list/paginate.ts`, `src/list/render.ts`

**U3** · #111 · bugfix · size S

- #111: After an input event on the search box, the input is still the focused element.
- files: `src/search/box.ts`

**U4** · #108 · bugfix · size S

- #108: matchesCrisisPhrase("i can’t go on") returns true.
- files: `src/crisis/keywords.ts`

</details>
