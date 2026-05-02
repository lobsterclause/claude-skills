# Severity Classification Guide

Use this guide when assigning P0–P3 severity to findings in the audit report and action items.

The core question for any finding is: **what is the worst realistic outcome for a real user?**

---

## P0 — Blocking

> The user cannot complete a core task. This is a ship blocker.

A finding is P0 if it meets **any** of these:

- A primary user flow (sign up, log in, submit a form, complete a purchase, send a message) is completely broken or unreachable
- The app crashes, shows a blank screen, or throws an unhandled exception during a user-initiated action
- Data a user entered is silently lost (form submits but nothing saves, no error shown)
- Authentication fails and the user has no recovery path
- A 4xx/5xx response causes the UI to freeze or show nothing — no error message, no retry option
- A modal or overlay traps focus with no close mechanism (keyboard user fully blocked)
- A route required for the core flow returns 404 or redirects to an error state

**Examples:**
- Clicking "Sign Up" does nothing (no navigation, no error, no feedback)
- Profile save silently fails — form resets, no toast, no console output the user can see
- Navigating to /checkout shows a blank white screen
- Log out button calls `/logout` which returns 500 and leaves the user in a broken auth state

---

## P1 — Major

> Significant UX impairment. Users can often work around it but shouldn't have to, and many won't bother.

A finding is P1 if it meets **any** of these:

- An action completes but gives the user no feedback (success, error, or progress) — they have no idea if it worked
- Validation errors are missing or generic ("Something went wrong") with no actionable guidance
- A secondary user flow (edit profile, upload a file, change a setting) is broken
- Navigation is broken in a way that forces the user to manually type URLs
- A loading state never resolves (spinner spins forever, skeleton never fills)
- An animation that's critical to understanding state change is completely absent (modal appears instantly with no transition — user may not realize it opened)
- Keyboard navigation skips interactive elements, making a flow unreachable by keyboard
- A page is not accessible at all at a common viewport (375px) — horizontal overflow that hides primary actions
- Console errors that correlate with broken functionality (even if user doesn't see them directly)
- Empty states with no CTA, leaving the user stranded with no next action

**Examples:**
- Clicking "Add to cart" works but shows no confirmation — user clicks 5 times and adds 5 items
- File upload input accepts a file, shows a progress bar, then silently disappears with no confirmation
- Settings page is unreachable by keyboard (Tab order skips the Settings link entirely)
- Mobile viewport (375px) shows the main CTA button cut off under the fold

---

## P2 — Moderate

> Noticeable quality issues that degrade experience but don't block. Should be in the next sprint.

A finding is P2 if it meets **any** of these:

- An animation or transition is present but visually wrong (wrong easing, wrong direction, flickers briefly)
- Loading state exists but resolves too quickly to provide reassurance (< 200ms)
- Error messages are technically present but poorly worded or placed where users miss them
- An accessible alternative exists but the primary path has an a11y issue (missing alt text on decorative image, incorrect heading hierarchy)
- A secondary viewport (768px, 1440px) has layout issues that don't block access to content
- Hover states are missing on interactive elements (user can't tell something is clickable until they click it)
- Focus order is unexpected but navigable (Tab moves to footer before main content)
- Console warnings (not errors) that indicate potential data issues
- Empty states exist but are confusing or provide incorrect next steps

**Examples:**
- Success toast appears but is positioned behind a modal (user technically succeeds but can't confirm it)
- The loading skeleton has a mismatched layout — placeholder has 3 columns, content has 2
- Password field shows "Invalid input" instead of "Password must be at least 8 characters"
- The Settings page has a heading order of H1 → H3 → H2 (confusing for screen readers but navigable)

---

## P3 — Polish

> A discerning user or accessibility power user would notice. Important for a polished product but low urgency.

A finding is P3 if it meets **all** of these:
- No user can be fully blocked by it
- A workaround requires at most one extra step
- It would not cause a negative review or support ticket from a typical user

**Examples:**
- Focus ring uses `outline: auto` which renders inconsistently across browsers
- Animation easing curve is linear instead of ease-out — feels slightly robotic
- Modal backdrop uses `rgba(0,0,0,0.4)` but spec says `rgba(0,0,0,0.5)` — barely perceptible
- A button's active state (`:active`) has no visual change — the pressed state is missing
- WCAG AA: color contrast ratio is 4.3:1 on non-critical secondary text (minimum is 4.5:1)
- An icon button has `aria-label` but it's a past-tense description ("Saved") instead of an action ("Save")
- Scroll position resets to top when navigating back — minor UX regression but not blocking

---

## Escalation rules

When in doubt, **escalate**. It's easier for a developer to downgrade a P0 than to discover a P1 was mislabeled.

Escalate a P2 → P1 when:
- It affects the primary conversion or activation flow
- It would cause a notable percentage of users to give up (especially mobile users)

Escalate a P1 → P0 when:
- Any data could be permanently lost
- Any user could be permanently locked out
- The issue reproduces on 100% of attempts with a fresh account