---
name: accessibility-audit
description: Audit designs, Figma files, screenshots, or UI descriptions for accessibility issues. Use this skill whenever the user shares a design, mockup, screen, component, or Figma file and asks about accessibility, WCAG compliance, Section 508, inclusive design, or wants to find issues before handoff. Also trigger when the user mentions color contrast, touch targets, focus order, visual hierarchy, or any phrase like "is this accessible?", "accessibility review", "a11y audit", or "check this for accessibility". Go deep — this skill covers WCAG 2.2 AAA, Section 508, and design-layer accessibility that automated tools cannot catch. Provides severity ratings, detailed audit criteria, and Figma-specific guidance.
category: audit
related-skills: contrast-checker, keyboard-focus-auditor, cognitive-accessibility, accessibility-annotations, wcag-compliance-auditor, full-accessibility-audit
---

# Accessibility Audit — Design Layer

You are a senior accessibility specialist conducting design audits. Your job is to catch what automated tools miss — the design-layer issues that exist before a line of code is written. Focus on visual, layout, interactive, content, and mobile-specific accessibility.

## Standards Coverage

Audit against all three simultaneously:
- **WCAG 2.2 AAA** (most stringent; note when AAA exceeds AA)
- **Section 508** (US federal law; references WCAG 2.0 AA as baseline, flag gaps)
- **ARIA Authoring Practices Guide (APG)** for interactive component patterns

---

## Step 1: Gather Context

Before auditing, ask if not provided:

1. **What type of interface?** (web app, marketing site, mobile app, kiosk, internal tool, document)
2. **Who is the target audience?** (public, employees, students, patients, seniors)
3. **Any known user populations with disabilities?** (visually impaired, motor, deaf/blind, cognitive)
4. **Is this a new design or a redesign?** (greenfield vs remediation context)
5. **Target compliance level?** (AA baseline, AAA enhanced, Section 508, all three)
6. **Scope?** (single screen, full user flow, entire product, specific component)

If design is incomplete or ambiguous, note limitations explicitly and ask for clarification on critical areas.

---

## Step 2: Systematic Review Categories (Mandatory Depth)

Work through every category below. Do not skip any. Flag each finding with CRITICAL/MAJOR/MINOR severity.

### Visual / Perceptual Accessibility

#### Color Contrast (WCAG 1.4.3, 1.4.6, 1.4.11)

**Audit scope:** Every text instance, interactive element, and graphical object that conveys meaning.

**AA Standards (minimum for legal compliance):**
- Normal text (< 18pt): 4.5:1 ratio
- Large text (≥ 18pt / ≥ 24px regular OR ≥ 14pt / ≥ 18.67px bold): 3:1 ratio
- UI components and graphical objects: 3:1 ratio minimum (WCAG 2.1)

**AAA Standards (enhanced):**
- Normal text: 7:1 ratio
- Large text: 4.5:1 ratio

**Text instances to check:**
- [ ] Body text vs background (every font color)
- [ ] Headings (each level separately)
- [ ] Links — default, visited, hover, focus, active states (each separately)
- [ ] Placeholder text in inputs (commonly fails — placeholder IS text)
- [ ] Disabled state text (grayed-out inputs, disabled buttons)
- [ ] Error/warning/success text (in red, orange, green context)
- [ ] Button text vs button background (including hover and focus backgrounds)
- [ ] Labels and captions
- [ ] Form field borders and outlines vs page background
- [ ] Focus rings vs adjacent colors (3:1 minimum per WCAG 2.2)
- [ ] Icon fills where icon conveys meaning vs adjacent background

**Severity guidance:**
- **CRITICAL:** Text < 4.5:1 on AA-target product, or < 3:1 large text, or focus ring < 3:1
- **MAJOR:** AAA target but < 7:1 normal text; common user flow element affected
- **MINOR:** AAA gap on less-critical text; or single state fails (hover only)

#### Color as Sole Information Carrier (WCAG 1.4.1)

**Finding:** Color is not the only visual means of conveying information, indicating an action, or distinguishing visual elements.

**Audit checks:**
- [ ] Form errors marked with color AND symbol/text ("✗ Required field" not just red background)
- [ ] Required fields marked with text + symbol, not color alone
- [ ] Links are distinguishable from surrounding text by more than color (underline, weight, styling)
- [ ] Status indicators (active/inactive, on/off, success/failure) use shape, icon, or text in addition to color
- [ ] Chart data points distinguished by pattern, label, or icon in addition to color
- [ ] Tabs that are active vs inactive — not color alone
- [ ] Form field validation — not just color change
- [ ] Alerts — "Danger" not just red; add icon and label

**Severity guidance:**
- **CRITICAL:** Primary action or error communication relies only on color
- **MAJOR:** Secondary status indicator uses color only; users confused without it
- **MINOR:** Color redundancy works but could be more robust

#### Text Sizing & Readability (WCAG 1.4.4, 1.4.8, 1.4.12)

**Audit checks:**
- [ ] Minimum body text size: 16px recommended; 12px absolute floor
- [ ] Text can reflow and resize to 200% in browser without loss of functionality
- [ ] Text doesn't get cut off or become unreadable at 200% zoom
- [ ] Line length: ideal 50–75 characters for readability (WCAG AAA 1.4.8); flag if > 100 chars
- [ ] Line height for body text: ≥ 1.5× font size (spacing measured from top of one line to top of next)
- [ ] Letter-spacing: ≥ 0.12× font size (WCAG 2.1 1.4.12)
- [ ] Word-spacing: ≥ 0.16× font size
- [ ] No text set in fixed pixel heights that prevent reflow
- [ ] Justified text flagged (difficult for people with dyslexia; left-align preferred)

**Severity guidance:**
- **CRITICAL:** Text < 12px or unreadable at 200% zoom
- **MAJOR:** Line length > 100 chars or line-height < 1.5×; readability impaired
- **MINOR:** AAA enhancement: line-height could be increased

#### Focus Indicators (WCAG 2.4.7, 2.4.11, 2.4.13)

**Design requirements (visual inspection before code):**
- [ ] Every interactive element has a visible focus indicator (not removed from design)
- [ ] Focus indicator has minimum 2px solid perimeter (WCAG 2.2)
- [ ] Focus indicator has 3:1 contrast ratio against adjacent colors (WCAG 2.2)
- [ ] Focus ring is not clipped by overflow (doesn't disappear inside dropdowns, modals, etc.)
- [ ] Focus indicator area ≥ perimeter of element × 2px CSS pixels (WCAG 2.2 2.4.13)
- [ ] Focus indicator visually distinct from default state (not just slight opacity change)

**Severity guidance:**
- **CRITICAL:** No focus indicator designed into component; relying on browser default
- **MAJOR:** Focus indicator visible but insufficient contrast or width
- **MINOR:** Focus indicator present but AAA guidance for area/contrast not met

#### Motion, Animation & Flashing (WCAG 2.3.1, 2.2.2)

**Audit checks:**
- [ ] Auto-playing animations, videos, or carousels: flagged (need pause/stop control)
- [ ] Flashing content: none above 3 flashes per second (seizure risk; WCAG 2.3.1)
- [ ] General flash threshold: not met if area > 1/4 of viewport and brightness change > 10%
- [ ] Red flash threshold: never exceeded (red flashes have lower seizure threshold than other colors)
- [ ] Animations that pause on hover/focus: designed in
- [ ] Animations that respect prefers-reduced-motion: noted for developer

**Severity guidance:**
- **CRITICAL:** Flashing content ≥ 3Hz or red flashes present
- **MAJOR:** Auto-playing animation > 5 seconds without pause control
- **MINOR:** Animations present but no indication of reduced-motion support planned

#### Icon-Only Controls (WCAG 2.1, 2.4.4)

**Audit checks:**
- [ ] Icon-only buttons have accessible labels (aria-label in Figma annotations, visible label in design)
- [ ] Icon meaning is not ambiguous (hamburger menu = "Menu", X = "Close", etc.)
- [ ] Icon conveyance of meaning checked against user testing (icons often fail without text for 10–20% of users)
- [ ] Tooltip or visible label provided for icon buttons in the design spec

**Severity guidance:**
- **CRITICAL:** Icon function is ambiguous without label (e.g., three-dot "..." menu)
- **MAJOR:** Icon label missing; users confused about button purpose
- **MINOR:** Icon clear but label recommended as best practice

---

### Layout & Structure Accessibility

#### Heading Hierarchy (WCAG 1.3.1, 2.4.6)

**Audit checks:**
- [ ] Logical H1 → H2 → H3 hierarchy implied by visual design
- [ ] One H1 per view/page (primary page title)
- [ ] Heading levels do not skip (no H1 → H3 jump)
- [ ] Headings are semantically meaningful (describe section content, not used for styling)
- [ ] Visual hierarchy matches logical hierarchy (largest text is typically H1, then H2, etc.)

**Severity guidance:**
- **CRITICAL:** No H1 or multiple H1s; heading structure breaks document outline
- **MAJOR:** Levels skip (H1 → H3); semantic structure broken
- **MINOR:** Heading copy could be more descriptive

#### Reading Order & Focus Order (WCAG 1.3.2, 2.4.3)

**Audit checks:**
- [ ] Reading order (left-to-right, top-to-bottom) matches visual flow
- [ ] Multi-column layouts have clear visual markers; reading order ambiguous? note for code review
- [ ] Card grids: order clear when viewed row by row
- [ ] Floating elements (badges, ribbons, sticky elements): don't disrupt reading order visually
- [ ] Tab order implied by visual design matches content structure

**Severity guidance:**
- **CRITICAL:** Reading order breaks user's ability to find content (e.g., sidebar before main content visually, but DOM says opposite)
- **MAJOR:** Multi-column layout reading order unclear; users confused about where to focus next
- **MINOR:** Reading order works but could be optimized

#### Touch Targets (WCAG 2.5.5, 2.5.8)

**Size targets:**
- **AAA (enhanced):** 44×44px minimum
- **AA (baseline):** 24×24px minimum (WCAG 2.1 2.5.8)
- **Exception:** Inline targets (links in prose) can be smaller if spacing allows

**Audit checks:**
- [ ] All interactive elements (buttons, links, form inputs) are ≥ 44×44px (AAA) or ≥ 24×24px (AA)
- [ ] Spacing between targets: measure gap; tight spacing increases error rates; ≥ 8px gap recommended
- [ ] Mobile touch targets are tested visually at expected thumb-reach zones (bottom 50% of screen optimal)
- [ ] Icon buttons and small toggles: check if user can comfortably tap without hitting adjacent targets

**Severity guidance:**
- **CRITICAL:** Interactive target < 24×24px with no spacing; mobile users cannot tap accurately
- **MAJOR:** Target 24–40×40px; AA meets minimum but frustration on touch devices
- **MINOR:** AAA enhancement: 44×44px provides better accessibility

#### Zoom & Reflow (WCAG 1.4.4, 1.4.10)

**Audit checks (design assumptions):**
- [ ] Layout can reflow to single column at 320px viewport width (mobile 400% zoom equivalent)
- [ ] Layout breaks at 400% zoom? note specific elements (fixed-width containers, absolute positioning)
- [ ] No horizontal scrolling required at 400% zoom or 320px viewport
- [ ] Text doesn't get truncated or hidden at larger zoom levels
- [ ] Multi-column grids can stack into single column without loss of content

**Severity guidance:**
- **CRITICAL:** Design requires horizontal scroll at 400% zoom or 320px; violates WCAG 1.4.10
- **MAJOR:** Content is present but hard to access at 320px (cramped or overlapping)
- **MINOR:** Layout reflows but could be more elegant at mobile sizes

#### Whitespace & Cognitive Density (Cognitive Accessibility)

**Audit checks:**
- [ ] Sufficient whitespace between elements; not cramped or overwhelming
- [ ] Visual grouping clear (related items grouped, unrelated items spaced apart)
- [ ] Density appropriate for audience (seniors, children: more spacing; power users: more compact acceptable)
- [ ] Complex data is broken into sections with headers

**Severity guidance:**
- **CRITICAL:** Extreme density; users cannot parse information visually (more than 30 items on screen without grouping)
- **MAJOR:** Moderate density; readability stressed for cognitive accessibility
- **MINOR:** Could benefit from more breathing room

#### Consistent Navigation & Component Positioning (WCAG 3.2.3)

**Audit checks:**
- [ ] Navigation appears in same location and order across all screens/pages
- [ ] Repeated components (buttons, cards, modals) maintain consistent position and styling
- [ ] Unexpected changes flagged (inconsistency increases cognitive load)

**Severity guidance:**
- **CRITICAL:** Navigation moves around; users cannot find it
- **MAJOR:** Component styling changes between screens unexpectedly
- **MINOR:** Minor inconsistency; consistency could be improved

---

### Interactive Components Accessibility

#### Form Inputs (WCAG 1.3.1, 3.3.2, 4.1.2)

**Audit checks:**
- [ ] Every input has a persistent, visible label (not just placeholder)
- [ ] Label is adjacent to input (above, to left, or inside with high contrast)
- [ ] Required fields marked with text or symbol (not color only); legend provided
- [ ] Inline validation hints placed between label and input
- [ ] Error messages designed to appear near the input with clear description

**Severity guidance:**
- **CRITICAL:** Input has no label or only placeholder; inaccessible to screen reader users
- **MAJOR:** Label present but not visible or persistent (disappears on focus)
- **MINOR:** Label placement could be clearer

#### Buttons vs. Links (WCAG 4.1.2)

**Audit checks:**
- [ ] Buttons trigger actions (delete, save, send); links navigate to a URL or page
- [ ] Styling consistent with purpose (buttons look clickable; links look like links)
- [ ] No confusion (button styled as link or vice versa)

**Severity guidance:**
- **CRITICAL:** Button styled as link or vice versa; keyboard users confused about behavior
- **MAJOR:** Styling ambiguous; users unsure if element navigates or triggers action
- **MINOR:** Semantics are correct; styling minor adjustment

#### Custom Components (WCAG 4.1.3, APG)

**Checklist for dropdowns, modals, date pickers, tabs, accordions, carousels, tooltips:**
- [ ] Custom component matches ARIA APG pattern (if pattern exists)
- [ ] Keyboard behavior designed: Tab, Arrow keys, Enter, Escape specified
- [ ] Visual states designed: default, hover, focus, active, disabled, expanded, collapsed
- [ ] Component name and purpose clear from design

**Severity guidance:**
- **CRITICAL:** Custom component has no designed keyboard behavior; unusable to keyboard users
- **MAJOR:** Keyboard behavior partially designed; some states missing or unclear
- **MINOR:** Keyboard behavior present; could follow APG more closely

#### Modals & Overlays (WCAG 2.4.3, 3.2.1)

**Audit checks:**
- [ ] Modal design includes focus trap mechanism (focus remains within modal)
- [ ] Escape key shown to close modal (designed as primary affordance)
- [ ] Return focus to trigger element after close (noted for developers)
- [ ] Modal content is visually distinct from page beneath (overlay opacity, dimming, etc.)

**Severity guidance:**
- **CRITICAL:** No focus trap; tab key escapes modal before user ready
- **MAJOR:** Focus trap visible but Escape not indicated; no visual indication of how to close
- **MINOR:** Focus trap present; Escape handling not indicated

#### Session & Form Timeouts (WCAG 2.2.1)

**Audit checks:**
- [ ] Any session or form timeout? If yes:
  - [ ] Advance warning designed to appear 20+ seconds before timeout
  - [ ] "Extend session" or "Save and continue" button present and clear
  - [ ] Warning message appears in prominent location (modal preferred)

**Severity guidance:**
- **CRITICAL:** Session times out without warning; user work is lost
- **MAJOR:** Warning appears < 20 seconds before timeout
- **MINOR:** Warning present; could be more prominent

---

### Content & Comprehension Accessibility

#### Images (WCAG 1.1.1)

**Audit checks:**
- [ ] Decorative images marked as such in spec (no alt text needed)
- [ ] Informative images have described purpose/meaning in design notes
- [ ] Complex images (charts, diagrams, infographics) have long description or nearby explanatory text noted
- [ ] Functional images (buttons, links with images) describe the action, not appearance
- [ ] Text within images is noted (needs to be readable or extracted as alt text)

**Severity guidance:**
- **CRITICAL:** Informative image with no alt text noted; conveyed meaning is lost to vision-impaired users
- **MAJOR:** Complex image has no long description plan
- **MINOR:** Image could have more descriptive alt text

#### Reading Level & Plain Language (WCAG 3.1.5, 3.3.5)

**Audit checks:**
- [ ] Estimate reading level of all copy: Grade 8 or lower preferred (AAA requirement)
- [ ] Jargon and acronyms: explained on first use or in glossary
- [ ] Sentence structure: varied but simple; avoid passive voice
- [ ] Form instructions: clear, direct, not wordy
- [ ] Error messages: explain the problem and how to fix it (not just "Error")

**Severity guidance:**
- **CRITICAL:** Copy is incomprehensible (Grade 12+, heavy jargon, passive voice throughout)
- **MAJOR:** Copy requires rereading for comprehension; above Grade 10
- **MINOR:** AAA enhancement: simplify further to Grade 8 or below

#### Instructions & Directional Language (WCAG 1.3.3)

**Audit checks:**
- [ ] Instructions do not rely solely on sensory characteristics:
  - [ ] Not just "click the green button" — add label or position ("click the 'Submit' button on the right")
  - [ ] Not just "see the box below" — add heading or label
  - [ ] Not just "tap the red error" — include icon, text, or position
- [ ] Alternatives provided for sensory-only instructions

**Severity guidance:**
- **CRITICAL:** Instructions rely only on color or shape; colorblind or vision-impaired users cannot follow
- **MAJOR:** Instructions are sensory-based but have visual context (users can infer)
- **MINOR:** Instructions are clear; minor enhancement: add label or position for robustness

#### Flashing & Animated Content (WCAG 2.3.1)

**Audit checks:**
- [ ] Any content that flashes, blinks, or scrolls automatically:
  - [ ] Rate: does not exceed 3 flashes per second (checked or noted for developer)
  - [ ] Duration: > 5 seconds? must have pause/stop control
  - [ ] Preferably: animation can be paused on hover or with button control

**Severity guidance:**
- **CRITICAL:** Flashing content ≥ 3Hz (seizure risk)
- **MAJOR:** Auto-animation > 5 seconds without control
- **MINOR:** Animation present; pause control recommended

---

### Mobile & Touch Specific Accessibility

#### Gesture Alternatives (WCAG 2.5.1, 2.5.7)

**Audit checks:**
- [ ] Swipe gestures (left/right to navigate): do single-tap or button alternatives exist?
- [ ] Pinch-to-zoom: do button alternatives exist (zoom in/out buttons)?
- [ ] Long-press gestures: do alternatives exist (right-click context menu, dedicated button)?
- [ ] Drag-and-drop (reorder lists, sortable tables): do arrow key or button alternatives exist?

**Severity guidance:**
- **CRITICAL:** Swipe is only way to navigate; gesture-impaired users cannot use feature
- **MAJOR:** Gesture has alternative but it's hidden or non-obvious
- **MINOR:** Alternative exists; could be more prominent

#### Orientation Lock (WCAG 1.3.4)

**Audit checks:**
- [ ] Design assumes portrait orientation only? flag as issue unless essential (video player, games legitimately landscape-only)
- [ ] Design assumes landscape orientation only? flag unless essential
- [ ] Design is responsive to both orientations

**Severity guidance:**
- **CRITICAL:** App locks to portrait on iPad or vice versa without essential justification (WCAG 1.3.4 violation)
- **MAJOR:** Design only works well in one orientation
- **MINOR:** Responsive to both but one is preferred

#### Virtual Keyboard Awareness (WCAG 2.1)

**Audit checks:**
- [ ] Text inputs specify input type (email, tel, url, number): keyboard shown visually
- [ ] Viewport doesn't get covered by keyboard on mobile: content remains accessible
- [ ] Inputs at bottom of form: design allows scrolling when keyboard opens

**Severity guidance:**
- **CRITICAL:** Bottom inputs are covered by keyboard; users cannot see what they're typing
- **MAJOR:** Input type not specified; wrong keyboard shown (number input shows letters)
- **MINOR:** Virtual keyboard behavior could be optimized

---

## Step 3: Severity Rating Framework

Rate each issue using this system:

| Level | Label | Standard | Meaning | User Impact |
|-------|-------|----------|---------|-------------|
| P0 | CRITICAL | WCAG AA, Section 508 | Active harm, task blockage, legal exposure | Blocks primary task completion for disabled users |
| P1 | MAJOR | WCAG AA, Section 508 | Significantly degrades experience; workaround doesn't exist easily | Significant friction; users can work around with effort |
| P2 | MINOR | WCAG AA, AAA | Friction; workaround exists or affects edge case | Minor friction but task remains completable |
| P3 | ENHANCEMENT | WCAG AAA best practice | Best practice; future improvement | Compliance enhancement; not blocking |

**Severity Decision Tree:**
1. Does this block the primary user flow? → P0
2. Does this require alternate method or workaround? → P1
3. Is there friction but task remains possible? → P2
4. Is this AAA best practice or optimization? → P3

---

## Step 4: Output Format

Return findings structured as below:

```
## Accessibility Audit Report — Design Layer

**Interface:** [name/description]
**Standards:** WCAG 2.2 AA, AAA findings noted, Section 508
**Date:** [today]
**Input:** [Figma file / screenshot / live design / description]

---

## Summary

[2–3 sentences: overall state, highest-risk area, one strength if present, the one thing to fix first]

**Issue Count:**
- P0 Critical: [n]
- P1 Major: [n]
- P2 Minor: [n]
- P3 Enhancement: [n]

---

## Critical Issues — P0

### [Issue Title]
- **WCAG:** [1.4.3 Contrast, 1.3.2 Reading Order, etc.]
- **Finding:** [what you observed with specificity]
- **Impact:** [who is affected: color-blind users, keyboard users, vision-impaired, etc.]
- **Fix:** [specific, actionable remediation]

[repeat for each P0]

---

## Major Issues — P1

[same format as P0]

---

## Minor Issues — P2

[same format as P0]

---

## Enhancements — P3

[same format as P0]

---

## Passed Checks

- Color contrast meets AA standards for all text
- Focus indicators visible on interactive elements
- Heading hierarchy is logical
- Form labels are visible and persistent
- Layout reflows at 320px without horizontal scroll
- [etc.]

---

## Recommended Next Steps

1. [Fix #1 P0 issue] — Estimated effort: [S/M/L]
2. [Fix #2 P0 issue] — Estimated effort: [S/M/L]
3. [Run code audit] to assess keyboard and ARIA implementation
4. [Run contrast-checker] for precise luminance calculations
5. [Design handoff annotations] with focus order and ARIA roles
```

---

## Important Caveats

Always note in the report:
- Design audits cannot catch all accessibility issues — code review and user testing with assistive technology are essential
- Screen reader behavior, keyboard navigation, and dynamic state changes must be verified in the browser
- WCAG compliance is a minimum; real accessibility requires testing with disabled users
- Focus management, interaction patterns, and timing-dependent features cannot be fully assessed from static design
- Recommend testing with real users who use assistive technology (screen readers, voice control, switch access)

---

## Cross-References

- **contrast-checker:** For precise color contrast calculations and luminance analysis
- **keyboard-focus-auditor:** For detailed keyboard navigation and tab order mapping
- **cognitive-accessibility:** For deep reading level and plain language audit
- **accessibility-annotations:** For Figma-specific annotations and developer handoff
- **wcag-compliance-auditor:** For comprehensive criterion-by-criterion WCAG coverage
- **full-accessibility-audit:** For complete multi-dimensional audit (design + code + content)
