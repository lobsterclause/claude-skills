---
name: screen-reader-scripting
description: Write screen reader test scripts for NVDA, JAWS, and VoiceOver — documenting expected announcements, keyboard commands, navigation flows, and pass/fail criteria for assistive technology testing. Includes component-specific test scripts for common patterns (accordion, combobox, date picker, toast, notification), AT quirks documentation, and bug reporting templates. Use this skill whenever the user needs to test with a screen reader, document expected screen reader behavior, write AT test scripts, or verify what a screen reader should announce for a component or flow. Trigger on phrases like "screen reader test", "NVDA test", "JAWS test", "VoiceOver test", "what should screen reader say", "screen reader script", "AT testing", "assistive technology test", "test with NVDA", "test announcement", or any request to verify or document screen reader behavior. Covers NVDA, JAWS, VoiceOver (macOS + iOS), and TalkBack.
category: test
related-skills: a11y-test-plan, keyboard-focus-auditor, accessibility-code
---

# Screen Reader Scripting

You write precise, executable test scripts that tell a tester exactly what keys to press, what should be announced, and what constitutes a pass or fail. No vague instructions — every step is reproducible. You also document platform-specific AT quirks and provide templates for capturing expected vs. actual behavior when bugs occur.

---

## Screen Reader Command Reference

### NVDA (Windows — Free, Most Common)
Download: nvaccess.org

| Action | Command |
|--------|---------|
| Start/Stop NVDA | Ctrl+Alt+N / NVDA+Q |
| Toggle speech | NVDA+S |
| Read from cursor | NVDA+Down Arrow |
| Next/Previous heading | H / Shift+H |
| Headings list | NVDA+F7 → H |
| Next/Previous landmark | D / Shift+D |
| Landmarks list | NVDA+F7 → R |
| Next/Previous link | K / Shift+K |
| Links list | NVDA+F7 → K |
| Next/Previous button | B / Shift+B |
| Next/Previous form field | F / Shift+F |
| Next/Previous image | G / Shift+G |
| Next/Previous table | T / Shift+T |
| Navigate table cells | Ctrl+Alt+Arrow keys |
| Forms/Browse mode toggle | NVDA+Space |
| Item finder | NVDA+F7 |

NVDA modifier key: Insert (default) or Caps Lock

### JAWS (Windows — Enterprise Standard)
| Action | Command |
|--------|---------|
| Read current line | JAWS+Up Arrow |
| Next/Previous heading | H / Shift+H |
| Headings list | JAWS+F6 |
| Landmarks list | JAWS+F5 (Regions) |
| Next/Previous link | Tab / Shift+Tab (in browse mode) |
| Links list | JAWS+F7 |
| Next/Previous form field | F / Shift+F |
| Forms mode toggle | Enter (auto on field) |
| Virtual cursor | JAWS+Z |
| Navigate table cells | Ctrl+Alt+Arrow keys |

JAWS modifier key: Insert (default)

### VoiceOver — macOS (Built-in)
Activate: Command+F5 (or triple-press Touch ID)

| Action | Command |
|--------|---------|
| VO modifier key | Ctrl+Option (VO) |
| Read from here | VO+A |
| Next/Previous item | VO+Right / VO+Left |
| Next/Previous heading | VO+Command+H / +Shift+H |
| Rotor | VO+U (then arrow keys to change category, up/down to navigate) |
| Interact with item | VO+Shift+Down |
| Stop interacting | VO+Shift+Up |
| Activate item | VO+Space |
| Navigate table | VO+Arrow keys (when in table) |
| Next landmark | VO+Command+L |
| Web item rotor categories | Headings, Links, Form Controls, Landmarks, Tables, Images |

### VoiceOver — iOS (Built-in)
Activate: Triple-click Home/Side button, or Accessibility Shortcut

| Action | Gesture |
|--------|---------|
| Next/Previous item | Swipe right / left |
| Activate | Double-tap |
| Scroll | Three-finger swipe |
| Rotor | Two-finger twist |
| Next/Previous rotor item | Swipe up / down |
| Escape / Back | Two-finger Z |

### TalkBack — Android
Activate: Volume Up + Down (hold), or Accessibility settings

| Action | Gesture |
|--------|---------|
| Next/Previous item | Swipe right / left |
| Activate | Double-tap |
| Next rotor item | Swipe up then right |
| Reading controls | Swipe up + down |

---

## Script Format

Every script uses this structure:

```
## Screen Reader Test Script
**Component / Flow:** [name]
**AT:** [NVDA 2024.x + Chrome 120+ / VoiceOver + Safari / JAWS 2024]
**Platform:** [Windows 11 / macOS Sonoma / iOS 17]
**WCAG:** [criteria being tested]
**Author:** [name]
**Date:** [date]
**Priority for Testing:** [High / Medium / Low] — [rationale]

### Prerequisites
- [Setup instructions: page URL, user state, starting point]
- [Any special browser/AT settings needed]

### Test Steps

**Step 1: [Description]**
- Action: [Exact keys or gestures]
- Expected announcement: "[Verbatim or paraphrased expected output]"
- Pass: [Observable outcome]
- Fail: [What failure looks like]
```

---

## Component Test Scripts by Priority

### Priority 1: Forms, Buttons, Links
These are tested in nearly every product; script them first.

#### Form with Validation
```
## Screen Reader Test: Contact Form — Validation
AT: NVDA + Chrome (Windows)
WCAG: 1.3.1, 3.3.1, 3.3.2, 3.3.3, 4.1.2
Priority: High — core interaction

### Prerequisites
- Navigate to contact form at [URL]
- Do not fill in any fields

### Test Steps

**Step 1: Navigate to First Field**
- Action: Press Tab until focus reaches first input
- Expected: "Full name, edit, required"
- Pass: Label, role, and required status all announced
- Fail: Missing label; "required" not announced; just "edit" with no label

**Step 2: Submit Empty Form**
- Action: Tab to "Send message" button → Press Enter
- Expected: NVDA announces error summary — "3 errors found" or similar; focus moves to error summary
- Pass: Error count announced; focus lands on error summary or first error
- Fail: Silent submission; no announcement; focus stays on submit button

**Step 3: Read Error Summary**
- Action: Press NVDA+Down Arrow from error summary
- Expected: Each error reads as a link including field name and error description
- Pass: "Full name — This field is required, link"; link is functional and navigates to field
- Fail: Error text reads without field name; links don't work; errors not read in order

**Step 4: Navigate to Field with Error**
- Action: Press Enter on error link for "Email address"
- Expected: Focus moves to email input; NVDA announces "Email address, edit, invalid, required, [error text]"
- Pass: aria-invalid announced; error description announced via aria-describedby
- Fail: Error not associated; focus lands on wrong element; aria-invalid not announced

**Step 5: Correct the Error**
- Action: Type valid email → Tab away from field
- Expected: NVDA announces field without "invalid"; error message disappears
- Pass: aria-invalid removed on correction; no lingering error announcement
- Fail: Error persists after correction; "invalid" still announced
```

### Priority 2: Navigation & Structure
These affect every page; test early.

#### Navigation Menu
```
## Screen Reader Test: Main Navigation
AT: VoiceOver + Safari (macOS)
WCAG: 1.3.1, 2.4.1, 2.4.3, 4.1.2
Priority: High — core structure

### Prerequisites
- Load homepage
- Ensure VoiceOver is running (Command+F5)

### Test Steps

**Step 1: Skip Link**
- Action: Press Tab once immediately after page load
- Expected: "Skip to main content, link" announced
- Pass: Skip link announced; visible on focus
- Fail: Skip link not announced; skip link not visible; no skip link present

**Step 2: Navigate to Navigation Landmark**
- Action: Activate rotor (VO+U) → navigate to Landmarks → find "Main navigation"
- Expected: "Main navigation" listed as a landmark
- Pass: Navigation labeled and findable in rotor
- Fail: Not in landmarks list; listed as "navigation" without label (if multiple navs exist)

**Step 3: Enter Navigation**
- Action: VO+Right through nav items
- Expected: Each item announced as "[Name], link" for links, or "[Name], collapsed, button" for expandable items
- Pass: Correct roles; expanded/collapsed state announced for dropdowns
- Fail: Items announced without roles; dropdown state not communicated

**Step 4: Expand Dropdown**
- Action: VO+Space on a dropdown trigger
- Expected: "expanded" announced; child items become available
- Pass: aria-expanded state change announced; child links accessible
- Fail: No state change announced; children not accessible; focus lost

**Step 5: Close Dropdown with Escape**
- Action: Press Escape while dropdown is open
- Expected: "collapsed" announced; focus returns to trigger
- Pass: State change announced; focus on trigger
- Fail: Dropdown stays open; focus lost
```

### Priority 3: Complex Components
Test these when you need comprehensive coverage.

#### Accordion
```
## Screen Reader Test: Accordion Panels
AT: NVDA + Chrome (Windows)
WCAG: 1.3.1, 2.4.3, 4.1.2
Priority: Medium — component-specific

### Prerequisites
- Navigate to accordion section at [URL]
- All panels start collapsed

### Test Steps

**Step 1: Tab to First Trigger**
- Action: Press Tab from previous content
- Expected: First accordion trigger announced — "[Title], button, collapsed"
- Pass: Button role and collapsed state announced
- Fail: No role; no state; just text announced

**Step 2: Activate with Enter**
- Action: Press Enter on first trigger
- Expected: "expanded" announced immediately; panel content becomes accessible
- Pass: State change announced; next Tab moves into panel content
- Fail: No state announcement; focus doesn't move into content

**Step 3: Navigate Within Expanded Panel**
- Action: Press Tab to move through panel content
- Expected: Focus moves through all focusable items inside panel
- Pass: All content reachable; nothing skipped
- Fail: Focus exits panel prematurely; content unreachable

**Step 4: Close Panel**
- Action: Tab back to trigger (or use Shift+Tab) → Press Enter
- Expected: "collapsed" announced
- Pass: State change announced; panel content hidden from reading order
- Fail: Content still reachable; no state announcement

**Step 5: Activate Different Trigger**
- Action: Tab to second trigger → Press Enter
- Expected: First panel closes, second opens; announcements reflect both state changes
- Pass: Only one panel expanded at a time; state changes announced
- Fail: Both panels open simultaneously; state not announced
```

#### Combobox (Autocomplete)
```
## Screen Reader Test: Autocomplete Search
AT: NVDA + Chrome (Windows)
WCAG: 1.3.1, 2.1.1, 4.1.2
Priority: Medium — complex interaction

### Prerequisites
- Navigate to autocomplete search at [URL]
- Component is empty

### Test Steps

**Step 1: Focus on Input**
- Action: Tab to search input
- Expected: "Search products, edit, combobox, has popup"
- Pass: Role (combobox) and popup state announced
- Fail: No mention of popup; generic "edit" only

**Step 2: Type to Filter**
- Action: Type "wireless"
- Expected: NVDA announces "5 results available" (or similar); popup opens
- Pass: Result count announced without moving focus; list becomes accessible
- Fail: Silent filtering; results not announced

**Step 3: Navigate Results**
- Action: Press Down Arrow
- Expected: First result highlighted and announced — "[Product name], 1 of 5"
- Pass: Current selection announced with position in list
- Fail: No announcement; focus doesn't move to list

**Step 4: Select Result**
- Action: Press Down Arrow twice → Press Enter
- Expected: Third result selected; input value updates; popup closes
- Pass: Selection announced; field value reflects selection; combobox closes
- Fail: Popup stays open; field value doesn't update; no state change

**Step 5: Clear and Re-open**
- Action: Select all input (Ctrl+A) → Delete → Type new text
- Expected: New results announced; list re-opens
- Pass: Fresh results announced; previous selection cleared
- Fail: Old results still announced; list doesn't reopen
```

#### Date Picker
```
## Screen Reader Test: Date Picker Widget
AT: VoiceOver + Safari (macOS)
WCAG: 1.3.1, 2.1.1, 2.4.3, 4.1.2
Priority: Medium — complex interaction

### Prerequisites
- Navigate to date input at [URL]
- Input is focused
- Picker is closed

### Test Steps

**Step 1: Open Picker**
- Action: Press Enter or Space on input
- Expected: "Date picker, button, expanded" or "Calendar widget, dialog"
- Pass: Widget type and state announced
- Fail: No announcement; focus lost; widget doesn't open

**Step 2: Navigate Calendar**
- Action: Press Right Arrow key
- Expected: "[Date, day of week]" — e.g., "15, Wednesday"
- Pass: Date and day announced for each navigation; current date highlighted
- Fail: Numbers only; day not announced; no indication of current selection

**Step 3: Navigate Months**
- Action: Press Up Arrow (or documented month-change key)
- Expected: Calendar changes to previous month; "December 2023, calendar" announced
- Pass: Month and year announced when changing months
- Fail: Silent month change; no feedback; calendar doesn't update visually

**Step 4: Select Date**
- Action: Find and activate (VO+Space) a date (e.g., the 15th)
- Expected: Input value updates to selected date; picker closes; focus returns to input
- Pass: Date selected and confirmed; input displays new value
- Fail: Picker doesn't close; input not updated; focus lost

**Step 5: Re-open and Verify**
- Action: Tab back to input → Open picker again
- Expected: Calendar opens to previously selected month; selected date highlighted
- Pass: Picker remembers context; selected date still highlighted
- Fail: Resets to today; selected date not highlighted
```

#### Toast/Notification
```
## Screen Reader Test: Success Toast Notification
AT: NVDA + Chrome (Windows)
WCAG: 4.1.3 Status Messages (AA)
Priority: Medium — user feedback

### Prerequisites
- Navigate to form with submit button at [URL]
- Fill out form with valid data

### Test Steps

**Step 1: Submit Form**
- Action: Press Enter on "Submit" button
- Expected: NVDA immediately announces "Form submitted successfully" (or similar)
- Pass: Toast announcement interrupts immediately; text is clear and complete
- Fail: Silent submission; toast announced after significant delay; text cut off

**Step 2: Verify No Focus Move**
- Action: After toast, press Tab
- Expected: Focus moves to next element in normal tab order (not to toast)
- Pass: Focus stays at submit button or next element; toast is announced but focus doesn't jump
- Fail: Focus moves to toast; focus lost; normal tab order disrupted

**Step 3: Close Toast (if applicable)**
- Action: If toast has close button, Tab to it → Press Enter
- Expected: "Dismiss notification, button" announced; toast closes and is removed from reading order
- Pass: Close button reachable and functional; toast disappears
- Fail: No close button; button not announced; toast stays visible

**Step 4: Error Toast**
- Action: Clear form, fill with invalid data, Submit
- Expected: NVDA immediately announces "Error: Email is required" (with aria-role="alert")
- Pass: Error toast uses role="alert" (assertive) and interrupts speech immediately
- Fail: Uses aria-live="polite"; error announced late or not at all
```

---

## AT Quirks and Platform-Specific Differences

Understanding these quirks helps you write accurate expected announcements.

### NVDA Quirks

| Quirk | Impact | Workaround |
|-------|--------|-----------|
| Doesn't announce aria-describedby by default on inputs in browse mode | Users miss error descriptions | Use aria-invalid + aria-describedby + test to confirm announcement |
| "Forms mode" requires Enter key to activate; arrow keys don't work in browse mode | Users confused by combobox arrow keys in wrong mode | Document arrow-key requirement; test both modes |
| Doesn't announce aria-current on navigation links | Current page not identified | Use aria-current + visible indicator (underline, background) |
| Announces "menu" and "menuitem" confusingly; prefer button+aria-expanded | Users confused about navigation dropdowns | Use button role for dropdowns, not menu role |

### JAWS Quirks

| Quirk | Impact | Workaround |
|-------|--------|-----------|
| Announces all aria-labels even if text is visible | Redundant announcements ("Delete, button, Delete") | Use aria-label only when text is not visible; prefer visible text |
| Forms mode more persistent; must explicitly exit with Escape | Tab doesn't work in arrow-key-heavy components | Document that Escape exits forms mode; test both modes |
| Slower to announce dynamic content updates | Users miss status messages | Test with NVDA too; ensure live regions have role=alert for critical messages |

### VoiceOver (macOS) Quirks

| Quirk | Impact | Workaround |
|-------|--------|-----------|
| Rotor (VO+U) doesn't show all landmarks if labels missing | Users can't find sections | Label all nav, section, aside, etc. with aria-label |
| VO+Space activates items inconsistently (depends on role) | Users confused about interaction model | Test both Enter and Space; document which works |
| Doesn't announce aria-invalid by default | Users don't know field is invalid | Announce "invalid" in aria-label or aria-description |

### VoiceOver (iOS) Quirks

| Quirk | Impact | Workaround |
|-------|--------|-----------|
| Gesture learning curve; users often try different gestures | Form abandonment if gesture not obvious | Provide alternative input methods (voice, traditional form inputs) |
| No keyboard mode; all interaction via gesture | Tab order irrelevant on iOS | Design touch-friendly alternatives; ensure buttons large enough |
| Rotor doesn't work well on mobile websites | Navigation difficult | Use semantic HTML; ensure landmarks are clear |

---

## Announcement Cheat Sheet

Use this to predict and verify expected announcements across ATs:

| Element | Expected NVDA Announcement | Expected VoiceOver Announcement |
|---------|---------------------------|--------------------------------|
| `<a href>Link text</a>` | "Link text, link" | "Link text, link" |
| `<button>Submit</button>` | "Submit, button" | "Submit, button" |
| `<button disabled>Submit</button>` | "Submit, button, dimmed" | "Submit, button, dimmed" |
| `<input type="text" id="x"><label for="x">Name</label>` | "Name, edit" | "Name, edit" |
| `<input required aria-required="true">` | "[label], edit, required" | "[label], edit, required" |
| `<input aria-invalid="true">` | "[label], edit, invalid entry" | "[label], edit" (no auto-announce; use aria-label) |
| `<input aria-describedby="hint">` | "[label], edit, [hint text]" | "[label], edit" (requires VO+rotor or interaction) |
| `<select>` | "[label], combo box, [selected option]" | "[label], combo box, [selected option]" |
| `<input type="checkbox" checked>` | "[label], checkbox, checked" | "[label], checkbox, checked" |
| `<button aria-expanded="false">Menu</button>` | "Menu, button, collapsed" | "Menu, button, collapsed" |
| `<button aria-expanded="true">Menu</button>` | "Menu, button, expanded" | "Menu, button, expanded" |
| `<div role="dialog" aria-labelledby="title">` | "[title text], dialog" | "[title text], dialog" |
| `<nav aria-label="Main">` | "Main navigation, landmark" | "Main navigation, main" |
| `<img alt="Product photo">` | "Product photo, graphic" | "Product photo, image" |
| `<img alt="">` | (skipped) | (skipped) |
| `role="alert"` with text | Immediately interrupts: "[text]" | Immediately interrupts: "[text]" |
| `aria-live="polite"` with text | At next pause: "[text]" | At next pause: "[text]" |
| `<table><caption>Sales</caption>` | "Sales, table, 5 rows, 3 columns" | "Sales, table, 5 rows, 3 columns" |

---

## Bug Reporting Template: Expected vs. Actual

Use this format to document screen reader bugs clearly for developers:

```
## Screen Reader Bug Report

**Component:** [e.g., Contact Form, Search Autocomplete]
**AT:** [NVDA 2024.1 + Chrome 123 / VoiceOver + Safari 17.2]
**Platform:** [Windows 11 / macOS Sonoma / iOS 17]
**URL:** [link]
**Date:** [date]
**Severity:** [CRITICAL / MAJOR / MINOR]
**WCAG Criterion:** [e.g., 4.1.2 Name, Role, Value]

---

### Expected Behavior
What the screen reader SHOULD announce (per WCAG and ARIA specs):

**Step:** Click "Submit" button with empty form
**Expected announcement:** "Submit, button" → Enter → "3 errors found, status" → focus to error summary

---

### Actual Behavior
What the screen reader ACTUALLY announces:

**Step:** Click "Submit" button with empty form
**Actual announcement:** "Submit, button" → Enter → (silent; no error announcement)

---

### Impact
Users don't know the form has errors. They may try clicking Submit multiple times or abandon the form.

---

### Developer Notes
- Add `role="alert"` or `role="status"` to error summary
- Or use `aria-live="assertive"` on error container
- Ensure error list is focused or announced automatically

---

### How to Reproduce
1. Go to [URL]
2. Click Submit without filling in any fields
3. Use NVDA (Insert+Down to read) — no error announcement occurs
4. Expected: "3 errors found" or similar should be announced
```

---

## Component Test Priority Ordering

Test components in this order for maximum regression coverage in minimum time:

1. **Forms & validation** (1–2 hours) — used in every product
2. **Navigation & landmarks** (30–45 min) — used on every page
3. **Modals/dialogs** (45 min–1 hour) — common interaction pattern
4. **Links & buttons** (30 min) — foundational elements
5. **Dropdowns/comboboxes** (1 hour) — common pattern
6. **Accordions** (45 min) — common pattern
7. **Tables** (1–2 hours) — complex but less common
8. **Carousels** (1 hour) — problematic for SR users
9. **Custom components** (1–3 hours) — product-specific

---

## Cross-References

- **a11y-test-plan:** Plan systematic accessibility testing; integrate screen reader scripts into test cases
- **keyboard-focus-auditor:** Audit focus order and keyboard navigation to complement AT testing
- **accessibility-code:** Review code and suggest fixes based on script results
