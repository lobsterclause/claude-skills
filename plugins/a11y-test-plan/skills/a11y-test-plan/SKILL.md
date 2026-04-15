---
name: a11y-test-plan
description: Generate comprehensive accessibility test plans with manual and automated test cases tied to WCAG criteria, organized by component, flow, or release phase. Includes effort estimation, regression test guidance, CI/CD integration, and test documentation templates. Use this skill whenever the user needs to plan, structure, or document accessibility testing — including QA test plans, sprint acceptance criteria, regression suites, release checklists, or testing documentation for audits. Trigger on phrases like "accessibility test plan", "a11y test cases", "QA accessibility", "how to test accessibility", "test for screen readers", "accessibility acceptance criteria", "regression testing accessibility", "testing checklist", "what to test", or any request to define or structure accessibility testing. Output is ready for QA teams, GitHub issues, Jira tickets, or test management tools.
category: test
related-skills: screen-reader-scripting, wcag-checklist, accessibility-code, keyboard-focus-auditor
---

# Accessibility Test Plan Generator

You create actionable, structured test plans that QA teams and developers can actually execute — not theoretical checklists. Every test case specifies exactly what to do, what tool to use, and what the pass condition is. You estimate effort per category, define regression triggers, and integrate with CI/CD pipelines.

---

## Step 1: Scope the Test Plan

Ask if not provided:
1. What is being tested? (component, user flow, full product, specific page)
2. What standards? (WCAG 2.2 AA, AAA, Section 508)
3. Who will execute? (QA engineers, developers, accessibility specialist, mixed)
4. What is the timeline/phase? (sprint, release, audit, regression)
5. What browsers/AT combinations are in scope?
6. What is your CI/CD pipeline? (GitHub Actions, Jenkins, GitLab CI, etc.)
7. Do you have existing automated test infrastructure? (jest-axe, axe-core, pa11y, etc.)

---

## Effort Estimation by Test Category

Use this guide to scope QA capacity and sprint planning. Effort varies by product complexity.

| Test Category | Effort per Feature | Notes |
|---------------|-------------------|-------|
| **Automated Scan** | 0.5–1 hour | Setup + tuning axe-core/pa11y; some false positives to review |
| **Keyboard Navigation** | 2–4 hours | Manual tabbing + arrow keys; full flow testing; more complex for forms/tables |
| **Screen Reader — Single AT** | 3–6 hours | NVDA or VoiceOver; one component or short flow; scripting time included |
| **Screen Reader — Full Matrix** | 8–12 hours | All 3 ATs (NVDA, JAWS, VoiceOver); multiple components |
| **Visual/Contrast** | 1–2 hours | Automated + spot-checks; mostly fast |
| **Motion/Animation** | 1–2 hours | Reduced motion testing; auto-play controls |
| **Images/Alt Text** | 1–3 hours | Depends on image count; review alt for accuracy |
| **Forms Validation** | 2–4 hours | Error states, error announcements, recovery paths |
| **Focus Management** | 1–2 hours | Dialog/modal focus; restoration; skip links |
| **Mobile/Touch** | 2–4 hours | Screen reader on iOS/Android; gesture alternatives; zoom |

**Full feature release (medium complexity):** ~15–20 hours of QA effort  
**Sprint acceptance criteria (3–4 components):** ~8–12 hours  
**Regression suite (quarterly):** ~20–30 hours

---

## Prioritized AT + Browser Test Matrix

Include the most impactful combinations. **Bold = minimum viable for most products**.

| Screen Reader | Browser | Platform | Priority | Use Case |
|---------------|---------|----------|----------|----------|
| **NVDA** | **Chrome** | **Windows** | High — 45% of SR users | Most common combo; free and open-source |
| **JAWS** | **Chrome** | **Windows** | High — 30% of SR users | Enterprise standard; B2B products |
| **VoiceOver** | **Safari** | **macOS** | High — 15% of SR users | Mac professionals; design/creative roles |
| **VoiceOver** | **Safari** | **iOS** | High — 5% of SR users; growing | Mobile-first; younger users |
| TalkBack | Chrome | Android | Medium — 4% of SR users | Mobile Android users; growing |
| Narrator | Edge | Windows | Low — 1% of SR users | Growing; newer users; Windows 11 adoption |
| NVDA | Firefox | Windows | Medium — 2% of SR users | Accessibility advocates; testers |

**Recommended minimum:** NVDA+Chrome, VoiceOver+Safari (macOS), VoiceOver+Safari (iOS)  
**Recommended medium:** Add JAWS+Chrome for enterprise products  
**Recommended full:** Add TalkBack+Chrome for mobile-first products

---

## Test Case Structure

Every test case includes:
- **ID** — unique reference (e.g., TC-A11Y-001)
- **WCAG Criterion** — number and name
- **Level** — A / AA / AAA
- **Component / Area** — what's being tested
- **Test Type** — Automated / Manual / AT (assistive technology)
- **Tool** — specific tool or method
- **Steps** — numbered, executable instructions
- **Pass Condition** — exact, observable outcome
- **Fail Examples** — what failure looks like
- **Effort** — estimated time (e.g., 30 min, 1 hour)

---

## Regression Testing Guide

### When to Re-Test (Triggers)

Run the full accessibility test suite when:
1. Any component code changes (HTML/ARIA attributes)
2. CSS or styling changes affecting focus indicators, contrast, or layout
3. JavaScript logic changes affecting keyboard, form validation, or dynamic content
4. Design system updates (colors, fonts, spacing, components)
5. Browser or AT versions update (quarterly check minimum)
6. New content added to the product (alt text, headings, etc.)
7. Mobile or responsive layout changes
8. Before major releases or quarterly audits

### What NOT to Re-Test (No regression needed)

- Text content changes only (e.g., copy edits, marketing text)
- Changes to non-interactive elements without structural changes
- Cosmetic updates not affecting focus, contrast, or layout
- Comment-only code changes

### Regression Test Subset (Smoke Test)

When time is tight, run this 2-3 hour smoke test to catch most regressions:

| Test Case | Effort | Why It Matters |
|-----------|--------|----------------|
| TC-A11Y-001: Axe scan — zero violations | 30 min | Catches most automated issues fast |
| TC-A11Y-010: Full keyboard navigation (primary flow only) | 45 min | Catches focus and keyboard issues |
| TC-A11Y-020: Screen reader announcement (NVDA only, top 3 components) | 60 min | Catches name/role/value issues |
| TC-A11Y-031: Non-text contrast (spot-check 5 elements) | 15 min | Catches focus indicator regressions |

---

## CI/CD Integration

### Automated Testing in Pipelines

#### GitHub Actions Example
```yaml
name: Accessibility Tests
on: [push, pull_request]

jobs:
  a11y:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v3
      - uses: actions/setup-node@v3
        with:
          node-version: 18
      
      - run: npm ci
      
      # Run axe-core in jest
      - run: npm run test:a11y
      
      # Run pa11y-ci for multi-page scanning
      - run: npx pa11y-ci
      
      # Upload results as artifact
      - uses: actions/upload-artifact@v3
        if: always()
        with:
          name: a11y-report
          path: ./a11y-results/
```

#### jest-axe Example (Unit Tests)
```javascript
import { render } from '@testing-library/react';
import { axe, toHaveNoViolations } from 'jest-axe';
import MyButton from './MyButton';

expect.extend(toHaveNoViolations);

test('button has no accessibility violations', async () => {
  const { container } = render(<MyButton>Click me</MyButton>);
  const results = await axe(container);
  expect(results).toHaveNoViolations();
});
```

#### pa11y-ci Example (.pa11yci.json)
```json
{
  "runners": ["axe"],
  "browsers": ["chrome"],
  "fail": true,
  "standard": "WCAG2AA",
  "timeout": 10000,
  "urls": [
    "http://localhost:3000",
    "http://localhost:3000/about",
    "http://localhost:3000/contact"
  ]
}
```

### Recommended Tools

| Tool | Type | Best For | Integrates With |
|------|------|----------|-----------------|
| **axe-core** | Library | Unit/component testing | jest-axe, pa11y, axe DevTools |
| **jest-axe** | Testing library | React/Vue component tests | Jest, GitHub Actions |
| **pa11y-ci** | CLI | Multi-page scanning, CI/CD | GitHub Actions, Jenkins |
| **axe DevTools** | Browser extension | Manual spot-checks; visual feedback | Chrome, Edge |
| **Lighthouse** | Browser extension | Quick audit + SEO/performance | DevTools, CI/CD |

---

## Test Categories and Cases

### 1. Automated Scan (Run First)

**TC-A11Y-001: Automated Axe Scan**
- WCAG: Multiple
- Level: A/AA
- Type: Automated
- Tool: axe DevTools browser extension, or jest-axe in CI
- Steps:
  1. Open target page in Chrome
  2. Open axe DevTools panel
  3. Run "Full Page Scan"
  4. Export results
- Pass: Zero violations (warnings acceptable; review for false positives)
- Fail: Any violation — triage by impact (critical > serious > moderate > minor)
- Effort: 30 min per page
- CI Integration: `npm run test:a11y` in GitHub Actions

**TC-A11Y-002: Lighthouse Accessibility Audit**
- WCAG: Multiple
- Level: A/AA
- Type: Automated
- Tool: Chrome DevTools Lighthouse
- Steps:
  1. Open DevTools → Lighthouse
  2. Check "Accessibility" only
  3. Run audit
- Pass: Score ≥ 90 (note: 100 does not mean full WCAG compliance)
- Fail: Score < 90 or any critical issue flagged
- Effort: 15 min per page
- CI Integration: Can be added to pa11y-ci or custom script

---

### 2. Keyboard Navigation

**TC-A11Y-010: Full Keyboard Navigation**
- WCAG: 2.1.1 Keyboard (A)
- Type: Manual
- Tool: Keyboard only (unplug/disable mouse)
- Steps:
  1. Place focus at the top of the page
  2. Tab through all interactive elements
  3. Activate each button, link, and control with Enter or Space
  4. Navigate dropdowns/menus with arrow keys
  5. Complete the primary user flow (e.g., submit a form) using only keyboard
- Pass: All functionality accessible; no steps require a mouse
- Fail: Any action unavailable via keyboard; any focus that gets stuck
- Effort: 1–2 hours per flow

**TC-A11Y-011: Tab Order Logic**
- WCAG: 2.4.3 Focus Order (A)
- Type: Manual
- Tool: Keyboard, browser DevTools
- Steps:
  1. Tab through the page from top to bottom
  2. Note the sequence in which elements receive focus
  3. Compare to visual/logical reading order
- Pass: Focus follows logical top-to-bottom, left-to-right order; reading order matches visual order
- Fail: Focus jumps unexpectedly; focus appears on invisible elements; order is confusing
- Effort: 45 min per page

**TC-A11Y-012: No Keyboard Trap**
- WCAG: 2.1.2 No Keyboard Trap (A)
- Type: Manual
- Tool: Keyboard
- Steps:
  1. Tab into every component: modal, dropdown, date picker, carousel, embedded widget
  2. Attempt to exit each using Tab, Shift+Tab, Escape, or documented method
- Pass: Can always exit every component using standard keys
- Fail: Focus gets stuck; Escape doesn't close modal; no way to exit a widget
- Effort: 1 hour per component set

**TC-A11Y-013: Focus Visibility**
- WCAG: 2.4.7 Focus Visible (AA), 2.4.13 Focus Appearance (AAA)
- Type: Manual
- Tool: Keyboard, color contrast analyzer
- Steps:
  1. Tab to each interactive element
  2. Observe focus indicator visibility
  3. Check focus ring contrast against adjacent background
- Pass: All focused elements show visible indicator; indicator meets 3:1 contrast ratio; not obscured by sticky headers or overflow
- Fail: No visible focus indicator; `outline: none` with no replacement; focus ring hidden behind sticky elements
- Effort: 1 hour per page

**TC-A11Y-014: Skip Navigation**
- WCAG: 2.4.1 Bypass Blocks (A)
- Type: Manual
- Tool: Keyboard
- Steps:
  1. Load the page
  2. Press Tab once
  3. Observe if a skip link appears
  4. Press Enter to activate it
  5. Verify focus moves to main content
- Pass: Skip link appears on first Tab press; activating it moves focus past navigation to main content
- Fail: No skip link; skip link exists but doesn't work; focus doesn't land on main content
- Effort: 15 min per page

---

### 3. Screen Reader Testing

**TC-A11Y-020: Page Title and Landmark Announcement**
- WCAG: 2.4.2 Page Titled (A), 1.3.1 Info and Relationships (A)
- Type: AT
- AT: NVDA+Chrome, VoiceOver+Safari
- Steps:
  1. Load the page
  2. Note what the screen reader announces first
  3. Use screen reader landmark navigation (NVDA: R key; VoiceOver: VO+U for rotor)
  4. List all landmarks found
- Pass: Page title is descriptive and unique; landmarks include main, nav, header, footer; all regions are labeled if multiple of same type
- Fail: Title says "Untitled" or is generic; no landmarks; duplicate unlabeled navs
- Effort: 30 min per page

**TC-A11Y-021: Heading Structure**
- WCAG: 1.3.1 Info and Relationships (A), 2.4.6 Headings and Labels (AA)
- Type: AT
- AT: NVDA, JAWS, or VoiceOver heading navigation
- Steps:
  1. Use heading navigation shortcut (NVDA/JAWS: H key; VoiceOver: VO+Command+H)
  2. List all headings in order
  3. Verify hierarchy makes logical sense
- Pass: One H1; logical H1→H2→H3 nesting; no skipped levels; headings match visible text
- Fail: Multiple H1s; H3 following H1; headings used for visual styling only
- Effort: 30 min per page

**TC-A11Y-022: Form Field Announcement**
- WCAG: 1.3.1 (A), 3.3.2 Labels or Instructions (A), 4.1.2 Name, Role, Value (A)
- Type: AT
- AT: NVDA+Chrome
- Steps:
  1. Navigate to each form field using Tab
  2. Note the full announcement: label, role, required status, description/hint
  3. Enter invalid data and submit
  4. Note error announcement
- Pass: Each field announces: "[Label], [role], [required if applicable], [hint if present]"; errors are announced and reference the field by name
- Fail: Field announced without label; required not communicated; errors not announced
- Effort: 1–2 hours per form

**TC-A11Y-023: Button and Link Distinction**
- WCAG: 4.1.2 Name, Role, Value (A)
- Type: AT
- AT: NVDA+Chrome
- Steps:
  1. Navigate all interactive elements
  2. Verify buttons announce as "button" and links as "link"
  3. Verify all have descriptive names (not "click here", "button", "link")
- Pass: Correct roles announced; all names are descriptive and unique in context
- Fail: `<div>` announces no role; "button, button, button" repeated; link says "read more" without context
- Effort: 45 min per page

**TC-A11Y-024: Dynamic Content Announcement**
- WCAG: 4.1.3 Status Messages (AA), 1.3.1 (A)
- Type: AT
- AT: NVDA+Chrome, VoiceOver+Safari
- Steps:
  1. Trigger dynamic content updates: form submission, filter, sort, load more, toast notifications
  2. Do NOT move focus to the new content manually
  3. Observe whether the screen reader announces the update
- Pass: Success/error messages announced without focus moving; "3 results found" announced after filter; toast text announced
- Fail: Dynamic updates occur silently; user must discover changes by exploring
- Effort: 1 hour per dynamic feature

---

### 4. Visual and Perceptual

**TC-A11Y-030: Text Contrast — Normal Text**
- WCAG: 1.4.3 Contrast Minimum (AA), 1.4.6 Contrast Enhanced (AAA)
- Type: Manual
- Tool: Browser color picker + contrast calculator, or axe
- Steps:
  1. Identify all text elements: body, labels, captions, placeholder, disabled states
  2. Sample foreground and background colors
  3. Calculate contrast ratio for each
- Pass: AA — 4.5:1 normal text, 3:1 large text; AAA — 7:1 normal, 4.5:1 large
- Fail: Any text below threshold; placeholder text often fails (typically 3:1)
- Effort: 1 hour per page
- Automation: axe-core catches most automatically

**TC-A11Y-031: Non-text Contrast**
- WCAG: 1.4.11 Non-text Contrast (AA)
- Type: Manual
- Tool: Contrast analyzer
- Steps:
  1. Identify all UI components: input borders, checkboxes, radio buttons, focus indicators, icons
  2. Test contrast of component boundary against adjacent background
- Pass: All component boundaries ≥ 3:1 against adjacent color
- Fail: Light gray input borders on white backgrounds (common failure)
- Effort: 1 hour per page

**TC-A11Y-032: Color Independence**
- WCAG: 1.4.1 Use of Color (A)
- Type: Manual
- Tool: Grayscale simulation (DevTools → Rendering → Emulate vision deficiency: Achromatopsia)
- Steps:
  1. Enable grayscale simulation in Chrome DevTools
  2. Review all status indicators, error states, required fields, charts, links
- Pass: All information conveyed by color is also conveyed by shape, text, pattern, or label
- Fail: Error state only shown by red color; required fields only shown by color; links indistinguishable from body text without color
- Effort: 45 min per page

**TC-A11Y-033: 200% Zoom**
- WCAG: 1.4.4 Resize Text (AA)
- Type: Manual
- Tool: Browser zoom (Ctrl/Cmd + four times at default)
- Steps:
  1. Set browser zoom to 200%
  2. Scroll through entire page/flow
  3. Check for text overlap, truncation, hidden content, or horizontal scroll
- Pass: All content readable; no text truncated; no loss of functionality; horizontal scroll only for data tables
- Fail: Text overlaps containers; nav items hidden; content disappears; page requires horizontal scroll
- Effort: 30 min per page

**TC-A11Y-034: 320px Reflow**
- WCAG: 1.4.10 Reflow (AA)
- Type: Manual
- Tool: DevTools responsive mode at 320px width
- Steps:
  1. Set viewport to 320px wide
  2. Scroll vertically through entire content
- Pass: All content accessible with vertical scroll only; no horizontal scroll required for content
- Fail: Horizontal scroll required; content hidden; two-column layouts that don't stack
- Effort: 45 min per page

---

### 5. Images and Media

**TC-A11Y-040: Image Alt Text**
- WCAG: 1.1.1 Non-text Content (A)
- Type: Manual + AT
- Tool: NVDA or VoiceOver + images-off mode
- Steps:
  1. Review all `<img>` tags in source
  2. Verify informative images have descriptive alt text
  3. Verify decorative images have `alt=""`
  4. With screen reader: navigate all images using image navigation shortcut
- Pass: Informative images announce meaningful descriptions; decorative images are skipped
- Fail: `alt` attribute missing; `alt="image"` or `alt="photo"`; decorative images announced unnecessarily
- Effort: 1–3 hours (depends on image count)

---

### 6. Motion and Time

**TC-A11Y-050: Reduced Motion**
- WCAG: 2.3.3 Animation from Interactions (AAA)
- Type: Manual
- Tool: OS Reduce Motion setting, Chrome DevTools media emulation
- Steps:
  1. Enable Reduce Motion at OS level (or via DevTools Rendering panel)
  2. Navigate through all pages
  3. Interact with all animated elements
- Pass: All animations are removed, replaced with fades, or replaced with instant state changes
- Fail: Animations still run at full intensity; parallax still active; page transitions still slide
- Effort: 1 hour per page

**TC-A11Y-051: Auto-playing Content Control**
- WCAG: 2.2.2 Pause Stop Hide (A)
- Type: Manual
- Steps:
  1. Identify all auto-playing content: carousels, video, animations, tickers
  2. Verify a pause/stop/hide control is visible and functional
- Pass: Control present; activating it stops the motion; control itself is keyboard accessible
- Fail: No control; control is not keyboard accessible; animation resumes after pause
- Effort: 45 min per feature

---

## Test Result Documentation Template

Use this template to record and share test results:

```
## Accessibility Test Results
**Product / Feature:** [name]
**Test Phase:** [Sprint / Release / Audit / Regression]
**Test Date:** [date range]
**Tested By:** [QA lead or accessibility specialist]
**Standard:** WCAG 2.2 AA
**Overall Status:** [PASS / FAIL with P0/P1 items]

---

### Summary
- Total tests run: [N]
- Passed: [N]
- Failed: [N]
- Blocked/Deferred: [N]

### Test Coverage
| Category | Tests Run | Passed | Failed | Status |
|----------|-----------|--------|--------|--------|
| Automated | 2 | 2 | 0 | PASS |
| Keyboard | 4 | 4 | 0 | PASS |
| Screen Reader (NVDA) | 5 | 4 | 1 | FAIL |
| Visual | 4 | 3 | 1 | FAIL |
| Motion | 2 | 2 | 0 | PASS |

### Issues Found

#### P0 (Critical — must fix before release)
1. **TC-A11Y-022: Form errors not announced**
   - Component: Contact form
   - Issue: Invalid email doesn't trigger error announcement
   - WCAG: 4.1.3 Status Messages (AA)
   - Developer note: Add aria-live="assertive" to error container
   - Ticket: [link to GitHub/Jira]

#### P1 (Major — fix in next sprint)
1. **TC-A11Y-031: Focus indicator contrast fails on dark background**
   - Component: Search input on dark header
   - Issue: Focus ring (blue #005fcc) on dark background (#1a1a1a) = 2.1:1, needs 3:1
   - WCAG: 1.4.11 Non-text Contrast (AA)
   - Developer note: Change focus ring to #4a90e2 or adjust background

### AT Testing Details
**NVDA + Chrome (Windows):** 100% coverage of critical flows, PASS
**VoiceOver + Safari (macOS):** 100% coverage of critical flows, PASS
**VoiceOver + Safari (iOS):** Touch interactions tested, PASS

### Regression Notes
Last full test: [date]
Changes since last test: [list of component/code changes]
Regression tests re-run: [date]
```

---

## Delivering for Different Audiences

- **For developers:** Focus on specific components, include code examples of pass conditions, link to WCAG techniques
- **For QA engineers:** Full step-by-step format with exact pass/fail criteria, effort estimates, automation guidance
- **For clients:** Summary table of test coverage with status indicators, high-level findings, remediation timeline
- **For GitHub/Jira:** One test case per issue with acceptance criteria format, links to screen reader scripts, severity tags

---

## Cross-References

- **screen-reader-scripting:** Write executable test scripts for NVDA, JAWS, VoiceOver
- **wcag-checklist:** Generate scoped WCAG criteria for your product
- **accessibility-code:** Review code and suggest fixes based on test failures
- **keyboard-focus-auditor:** Deep dive on focus order, focus management, keyboard behavior
