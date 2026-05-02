---
name: user-flow-auditor
description: >
  Complete remote-control user flow audit for web apps at staging URLs. Crawls the entire app, discovers every route and interactive element via AI-powered Stagehand, clicks every interaction with inline visual analysis, records flows for animation review via flow-replay-analyzer, and produces a prioritized report with coding-agent-ready action items. Trigger for: audit a web app, test every click, find broken flows, QA the staging site, pre-launch check, smoke test the URL, full QA pass, test every button, interaction audit, "what's broken on staging", "click through the whole app", "find all the broken things". Do NOT use for: unit tests, backend API testing, performance load testing.
---

# User Flow Auditor

A dual-engine audit that maps every route, observes every interactive element, exercises every interaction with real-time visual analysis, and captures video for post-flow animation review. Produces a prioritized report with coding-agent-ready action items.

**Two engines, complementary coverage:**
- **Stagehand** (MCP) — AI-driven observation and interaction against the live staging URL; no local server required
- **Playwright** (`scripts/playwright_audit.py`) — systematic axe-core a11y injection, console/network error capture, keyboard navigation, responsive checks, and automatic video recording per flow

**Two analysis layers:**
- **Inline (me)** — I read every screenshot I take, compare to what I expected, and log violations immediately
- **Replay (sub-agent)** — after each flow, I spawn a `flow-replay-analyzer` sub-agent with the recorded `.webm` and an expectation description; it sends the video to Gemini 3 Flash and returns animation/transition violations I couldn't see in screenshots

---

## Inputs

Collect before starting — ask if not provided:

| Input | Required | Default | Notes |
|---|---|---|---|
| `STAGING_URL` | ✅ | — | Base URL to audit |
| `AUTH` | optional | none | `{ email, password }` — if omitted, public flows only |
| `DEPTH` | optional | 3 | Crawl depth from root |
| `SKIP_PATTERNS` | optional | see below | URL fragments to never navigate to |
| `REPORT_PATH` | optional | `/tmp/flow-audit-<ts>/report.md` | Where to save the report |

**Default skip patterns** (never navigate to or interact with):
`/logout`, `/delete`, `/destroy`, `/stripe`, `/paypal`, `/admin/reset`, any URL containing `confirm=delete`, `action=destroy`, or `__force`.

Create the audit directory at the start:

```bash
AUDIT_DIR="/tmp/flow-audit-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$AUDIT_DIR/screenshots" "$AUDIT_DIR/recordings" "$AUDIT_DIR/logs" "$AUDIT_DIR/replay-analysis"
```

Tell the user this path immediately so they can monitor artifacts as they appear.

---

## Phase 1: Route Discovery

**Goal:** Build a complete map of every URL in the app.

Using Stagehand:

1. Navigate to `STAGING_URL` with `browserbase_stagehand_navigate`
2. Screenshot → `screenshots/00-root.png` — read it, note the page type
3. Extract all navigation links via `browserbase_stagehand_extract`:
   > "Extract all href values from nav links, sidebar links, footer links, tab bars, and breadcrumbs. Return as a JSON array of { label, href } objects."
4. Recursively crawl same-origin links up to `DEPTH` hops, skipping `SKIP_PATTERNS` and already-visited URLs
5. After crawling, check for auth wall: if most routes redirect to `/login` or similar, flag and proceed to Phase 2 before continuing

Produce and save `$AUDIT_DIR/logs/route-map.json`:

```json
{
  "discovered_at": "<ISO>",
  "base_url": "<STAGING_URL>",
  "routes": [
    { "path": "/", "title": "Home", "depth": 0, "auth_required": false },
    { "path": "/dashboard", "title": "Dashboard", "depth": 1, "auth_required": true }
  ]
}
```

Print the route tree to the user as you build it so they can spot gaps.

---

## Phase 2: Authentication

Run this phase only if `AUTH` was provided or an auth wall was detected.

1. Navigate to the login page
2. `browserbase_stagehand_observe`: "Find the email/username and password input fields and the sign in button"
3. `browserbase_stagehand_act`: "Fill in the email field with `<email>`, the password field with `<password>`, then click Sign In"
4. Wait for navigation, screenshot → `screenshots/01-post-login.png` — read it
5. **If still on login page:** log `AUTH_FAILURE`, continue auditing public routes only, note clearly in report
6. **If authenticated:** re-run Phase 1 to discover protected routes now visible

---

## Phase 3: Element Observation

For each route, build a definitive element inventory using AI observation — catching custom components and conditional UI that CSS selectors miss.

For each page:

1. `browserbase_stagehand_navigate` to the route
2. Wait 1.5s for JS to settle
3. Screenshot → `screenshots/<slug>-before.png` — read it, note the page layout and primary affordances
4. `browserbase_stagehand_observe`:
   > "Find every interactive element on this page: buttons, links, form inputs, dropdowns, toggles, switches, tabs, accordions, carousels, date pickers, color pickers, file uploads, modal triggers, tooltip triggers, pagination controls, and any other clickable or focusable element. Include elements that would appear on hover or scroll."
5. Save to `$AUDIT_DIR/logs/<slug>-elements.json`

Element schema:
```json
{
  "id": "btn-save-1",
  "type": "button",
  "label": "Save Changes",
  "selector": "button[data-testid='save-changes']",
  "state": "visible",
  "expected_action": "submits the settings form and shows a success toast"
}
```

---

## Phase 4: Interaction Testing

For each route, run the Playwright systematic pass first (it records video), then do the Stagehand interaction loop.

### 4A. Playwright Pass (per route)

```bash
python scripts/playwright_audit.py \
  --url "<route-full-url>" \
  --output-dir "$AUDIT_DIR" \
  --slug "<route-slug>" \
  [--cookie-file "$AUDIT_DIR/logs/auth-cookies.json"]
```

Run `python scripts/playwright_audit.py --help` first. This script:
- Records a `.webm` to `$AUDIT_DIR/recordings/<slug>.webm`
- Injects and runs axe-core — saves violations to `$AUDIT_DIR/logs/<slug>-axe.json`
- Captures all console errors and network failures
- Tabs through every focusable element — screenshots focus state
- Tests at 375px, 768px, 1440px — saves breakpoint screenshots
- Returns a JSON summary to stdout

Save the Playwright JSON summary to `$AUDIT_DIR/logs/<slug>-playwright.json`.

### 4B. Stagehand Interaction Loop (per element)

For each element in the inventory:

1. Navigate back to the route (elements may be stale after previous interactions)
2. `browserbase_stagehand_act`: "Click/interact with [element label]"
3. Wait 1s for any animations to complete
4. Screenshot → `screenshots/<slug>-<element-id>-after.png`
5. **Read the screenshot** — compare to what I expected:
   - Did the expected change happen? (form submitted, modal opened, route changed, toast appeared)
   - Is there an error message visible that shouldn't be?
   - Is the UI in an unexpected state?
6. `browserbase_stagehand_observe`: "Is there an error message, loading indicator stuck, or unexpected blank state visible?"
7. `browserbase_stagehand_get_url` — did the URL change? Was that expected?
8. Log the interaction result (schema below)

**On timeout (>15s) or Stagehand error:** retry once with a rephrased instruction. If it fails again, log as `timeout` or `error`, take a screenshot, move to the next element.

**On auth expiry** (redirect to login mid-audit): re-authenticate and resume from the last successful route.

Interaction result schema:
```json
{
  "route": "/dashboard",
  "element_id": "btn-save-1",
  "element_label": "Save Changes",
  "result": "success | error | broken | unexpected | timeout",
  "error_message": null,
  "url_before": "/dashboard",
  "url_after": "/dashboard",
  "expected_url_change": false,
  "console_errors": [],
  "screenshot_before": "screenshots/dashboard-before.png",
  "screenshot_after": "screenshots/dashboard-btn-save-1-after.png",
  "my_assessment": "Success toast appeared as expected. Profile name updated in the header.",
  "severity": null
}
```

Save all results to `$AUDIT_DIR/logs/interactions.json`.

### 4C. Deep Interaction Checks (per route)

After the main element loop, run these targeted checks:

**Forms:**
- Submit empty → verify validation messages appear and describe errors clearly
- Submit with invalid data (wrong email format, short password) → verify appropriate inline errors
- Verify no data loss if user navigates away mid-fill and returns

**Modals and drawers:**
- Open each → verify background is inert (click behind it, should not interact)
- Close via X button, Escape key, and backdrop click — verify all three work or that blocking behavior is intentional
- Tab order inside modal should be trapped

**Navigation:**
- Every nav link resolves without 404 or crash
- Active/selected state is correct for current route
- Browser back button doesn't crash or show blank page

**Loading and empty states:**
- Find any empty state UI (no messages yet, no results, new account) — screenshot each
- Note if empty states have helpful CTAs or are just blank

---

## Phase 5: Replay Analysis

After completing all interactions for a route, spawn a `flow-replay-analyzer` sub-agent for each recorded flow where animation or transition behavior was expected or observed.

For each recording in `$AUDIT_DIR/recordings/`:

```
Spawn flow-replay-analyzer sub-agent:
- VIDEO_PATH: $AUDIT_DIR/recordings/<slug>.webm
- EXPECTATION: "<natural language description of what should happen in this flow>"
- OUTPUT_DIR: $AUDIT_DIR/replay-analysis/
- FLOW_NAME: <slug>
```

Build the expectation description from what I observed during Phase 4 — describe the expected happy path for that route's primary interaction.

The sub-agent returns a JSON analysis. Save it and incorporate violations into the main report's action items with source tagged as `"source": "replay-analyzer"`.

---

## Phase 6: Report Generation

Synthesize all findings. Save to `$AUDIT_DIR/report.md` (also symlink to `REPORT_PATH` if specified).

### Report Structure

```markdown
# User Flow Audit Report

| Field | Value |
|---|---|
| **URL** | <STAGING_URL> |
| **Date** | <ISO date> |
| **Auth tested** | yes / no |
| **Routes discovered** | N |
| **Elements tested** | N |
| **Interactions performed** | N |
| **Flows recorded** | N |
| **Replay analyses** | N |

---

## Executive Summary

[2–4 sentences covering overall health, count of P0/P1 issues, biggest risk areas, and whether the app is shippable in its current state.]

---

## Coverage Map

| Route | Title | Elements | Status | P0 | P1 | P2 | P3 |
|---|---|---|---|---|---|---|---|
| / | Home | 12 | ✅ clean | 0 | 0 | 1 | 2 |
| /dashboard | Dashboard | 28 | ❌ broken | 2 | 1 | 3 | 4 |

---

## Findings by Severity

### 🔴 P0 — Blocking
> These issues prevent a user from completing a core task. Ship blockers.

[Each finding as a section]

### 🟠 P1 — Major
> Significant UX impairment; user can work around but shouldn't have to.

### 🟡 P2 — Moderate
> Noticeable quality issues; won't block a launch but should be in the next sprint.

### 🟢 P3 — Polish
> Minor issues a discerning user would notice. Keyboard focus order, cosmetic glitches, a11y non-critical.

---

## Action Items for Coding Agent

Each action item is fully self-contained. A coding agent can pick any one and execute it without additional context.

### [AI-001] <Concise title>
- **Priority:** P0
- **Source:** stagehand-interaction | playwright-axe | replay-analyzer
- **Route:** /dashboard
- **Element:** "Save Changes" button (`button[data-testid="save-changes"]`)
- **Issue:** Clicking Save Changes causes a console error `TypeError: Cannot read properties of undefined (reading 'profile')` and the save silently fails with no feedback to the user.
- **Reproduction:**
  1. Log in and navigate to /dashboard
  2. Make any change to the profile form
  3. Click "Save Changes"
  4. Observe: no success toast, no error message, form resets. Console shows TypeError.
- **Suggested fix:** Null-check `user.profile` before accessing in the save handler. Likely in `src/components/Dashboard/ProfileForm.tsx` around the `handleSave` function.
- **Screenshot:** `screenshots/dashboard-btn-save-1-after.png`

[continue for all P0 and P1 findings, then P2 and P3]

---

## Accessibility Summary

[Grouped axe-core violations by WCAG criterion, with affected routes and element selectors. Include remediation hint for each.]

## Animation & Transition Summary

[Violations found by flow-replay-analyzer, grouped by severity. Include timestamp references and frame screenshots.]

## Responsive Summary

| Route | 375px | 768px | 1440px |
|---|---|---|---|
| / | ✅ | ✅ | ✅ |
| /dashboard | ⚠️ overflow | ✅ | ✅ |

## Console Error Log

| Error | Route | Frequency |
|---|---|---|
| `TypeError: Cannot read...` | /dashboard | 3× |

## Network Error Log

| URL | Status | Triggered by |
|---|---|---|
| `/api/profile/save` | 500 | Save Changes button |

## Raw Data

All JSON logs are at: `<AUDIT_DIR>/logs/`
All screenshots are at: `<AUDIT_DIR>/screenshots/`
All recordings are at: `<AUDIT_DIR>/recordings/`
All replay analyses are at: `<AUDIT_DIR>/replay-analysis/`
```

---

## Resilience Rules

- **Never hard-fail on one element.** Log it, screenshot it, move on.
- **Retry once with rephrased instruction** before marking anything `broken`.
- **Re-authenticate on mid-audit expiry** — resume from the last successful route.
- **Always check `SKIP_PATTERNS`** before navigating or interacting.
- **Cap per-element interaction time at 15s.** Abort and log `timeout` if exceeded.
- **De-duplicate modals** — if the same modal is reachable from N triggers, audit it once and note all trigger paths.
- **Preserve Playwright recordings** — even if analysis fails, the `.webm` files are valuable evidence.
- **If Stagehand session drops** — recreate the session with `browserbase_session_create`, re-authenticate if needed, and resume from the last successfully completed route.

---

## Output Checklist

Before presenting the final report, verify:

- [ ] `route-map.json` saved
- [ ] Every route has a before-screenshot and a Playwright JSON summary
- [ ] `interactions.json` has a result for every element
- [ ] Every recording in `recordings/` has a corresponding replay-analysis JSON
- [ ] Report has an action item for every P0 and P1 finding
- [ ] Every action item has: priority, route, element, issue, reproduction steps, suggested fix
- [ ] User told the audit directory path

---

## References

- `references/severity-guide.md` — detailed P0–P3 classification with examples
- `scripts/playwright_audit.py` — systematic Playwright pass (run `--help` for usage)
- `flow-replay-analyzer` skill — video analysis sub-skill; spawn as a sub-agent per flow
