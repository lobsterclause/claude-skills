---
name: full-accessibility-audit
description: "Perform a complete, multi-dimensional accessibility audit by orchestrating all audit-category skills into a single unified report. Use this skill whenever the user asks for a full audit, complete accessibility review, end-to-end assessment, or wants to audit an entire product, page, or component suite from every angle. Trigger on phrases like 'full accessibility audit', 'complete audit', 'audit everything', 'comprehensive accessibility review', 'full a11y audit', 'audit this product', 'audit this page', or any audit request that does not specify a single narrow dimension. Covers design, code, contrast, copy, keyboard, motion, forms, tables, alt text, cognitive, mobile/touch, PDF/document, video/media, and design handoff annotations. Produces a prioritized remediation roadmap, business impact narrative, and test plan. Do not use narrow single-dimension skills when the user wants the full picture — use this."
category: audit
related-skills: accessibility-audit, accessibility-code, contrast-checker, keyboard-focus-auditor, accessibility-copy, alt-text-generator, accessible-forms, accessible-tables, motion-auditor, cognitive-accessibility, mobile-touch-auditor, a11y-test-plan, wcag-compliance-auditor
---

# Full Accessibility Audit

You are the audit director. Your job is to run a complete accessibility assessment by systematically applying every relevant audit dimension to the input provided, then synthesizing findings into a single prioritized report with a clear path to remediation, grounded in business impact.

This skill orchestrates the audit-dimension skills: accessibility-audit (design), accessibility-code (code layer), contrast-checker, keyboard-focus-auditor, accessibility-copy, alt-text-generator, accessible-forms, accessible-tables, motion-auditor, cognitive-accessibility, mobile-touch-auditor, and wcag-compliance-auditor. It also coordinates handoff documentation (accessibility-annotations) and testing (a11y-test-plan, screen-reader-scripting).

---

## Step 1: Triage the Input with Decision Tree

Classify what you've been given — this determines module execution order and emphasis.

### Decision Tree

**1. What medium/artifact?**
- Design (screenshot, Figma, mockup) → design-heavy audit
- Code (HTML, CSS, JS, React, Vue, Svelte) → code-heavy audit
- Full product (design + code visible) → balanced audit
- Copy / content only → content audit
- URL (live site) → comprehensive audit (all modules)
- Description (text only) → limited scope, note gaps upfront

**2. What type of product?**
- Web app (SaaS, dashboard, tool) → keyboard, form, motion critical
- Marketing/content site → visual, copy, link structure critical
- E-commerce → forms, mobile, touch targets critical
- Mobile app (native iOS/Android) → touch, gesture, voice control critical
- Internal tool / document → keyboard, cognitive clarity critical
- PDF / downloadable document → PDF-specific audit

**3. Are there users with known disabilities?**
- Yes → emphasize their needs in findings; consider that sub-group for severity
- Unknown → default to WCAG AAA as the standard
- Specific disability type identified → tailor checklist accordingly

**4. What is the compliance target?**
- AA (legal baseline, most common)
- AAA (enhanced, best practice)
- Section 508 (US federal requirement)
- All three (safest approach, provide all findings)

**5. What is the deadline?**
- Pre-launch → full audit; no shortcuts
- Post-launch / remediation → prioritize by impact and legal exposure
- Long-term improvement → phase remediation across roadmap

### Input Classification Table

| Input | Design Emphasis | Code Emphasis | Cognitive Emphasis | Mobile Emphasis | Notes |
|-------|-----------------|---------------|-------------------|-----------------|-------|
| Figma/Screenshot | HIGH | — | MEDIUM | — | Design audit + cognitive + annotations |
| HTML/JSX code | — | HIGH | MEDIUM | MEDIUM | Code audit + keyboard + cognitive + forms/tables if present |
| Live URL | HIGH | HIGH | HIGH | HIGH | Full audit with real AT testing |
| Codebase description | — | HIGH | — | — | Code-only; note inability to assess design/visual |
| Copy/content only | — | — | HIGH | — | Content + copy audits; note missing design/code |
| Mobile app screenshot | MEDIUM | — | MEDIUM | HIGH | Design + mobile/touch + cognitive |
| Form (design) | HIGH | — | HIGH | — | Design + forms + cognitive + copy |
| Data table (design) | HIGH | — | — | — | Design + tables + keyboard |
| PDF | — | — | MEDIUM | — | PDF-specific; limited other dimensions |

---

## Step 2: Intake Questions (Triage Only If Ambiguous)

Ask only if answers aren't clear from the input. Batch all into a single message.

1. **Artifact type:** "Are you sharing a design, code, working product, or all three?"
2. **Product type:** "What is this? (web app, website, mobile app, document, etc.)"
3. **Audience:** "Who uses this? Any known disabilities or accessibility requirements?"
4. **Compliance target:** "Are you aiming for WCAG AA, AAA, Section 508, or all three?"
5. **Scope:** "Is this a specific page/component, or a full product audit?"
6. **Deadline:** "When do you need the report? (shapes prioritization)"

If user says "just run it" — default to: **WCAG 2.2 AA + AAA findings, Section 508 flagging, public-facing web app assumption, comprehensive report with business impact.**

---

## Step 3: Run All Applicable Modules (Systematic Execution)

Work through modules in this order. Do not skip modules because input seems incomplete — note gaps explicitly.

### Module 1: Design / Visual Audit
**Trigger:** Figma file, screenshot, wireframe, mockup, or design description present

*Apply: accessibility-audit skill*

Audit all visual and layout elements:
- Color contrast — every text instance, every interactive state (default, hover, focus, disabled, error)
- Color as sole information carrier — errors, status, required fields, charts
- Focus indicator design — visible, sufficient contrast, not clipped, ≥ 2px perimeter
- Touch targets — minimum 44×44px (AAA), 24×24px (AA minimum)
- Heading hierarchy — implied by visual design; one H1 per view
- Reading and focus order — especially multi-column layouts, card grids, floating elements
- Zoom and reflow — layout stability at 400% zoom and 320px viewport
- Sensory-only instructions — "click the green button" or "see the box on the right"
- Whitespace and cognitive density — readability and visual breathing room
- Typography — line length, line height (≥1.5x body), font sizes, justified text

### Module 2: Color Contrast Deep Audit
**Trigger:** Any design or visual input

*Apply: contrast-checker skill*

Run contrast math on every color pair in the design:
- Body text vs background — check all text instances
- Heading text vs background — each level
- Link text vs background — default, visited, hover, focus, active
- Placeholder text vs input background (commonly fails)
- Disabled state text vs background
- Error/success text vs background
- Button text vs button background (including hover/focus states)
- Icon fill vs adjacent background
- Input border vs page background
- Focus ring vs adjacent colors (3:1 minimum per WCAG 2.2)
- Graphical elements (charts, icons, UI components) vs background (3:1 minimum)

**Output:** Luminance values and ratio for each pair; flag all failures with WCAG criterion.

### Module 3: Code Audit
**Trigger:** HTML, CSS, JavaScript, React, Vue, Svelte, or code snippet provided

*Apply: accessibility-code skill*

Review semantic structure, ARIA usage, interaction logic:
- Semantic element choices — button vs div, nav vs div, header, main, footer
- Landmark regions and labels — at least one `<main>`, proper `<nav>` labels
- Heading hierarchy in DOM — logical H1–H6, one H1 per page
- ARIA roles, states, properties — correctness and necessity; never misuse ARIA to fix bad semantics
- Accessible name resolution — how each interactive element is named (labelledby → label → native → title)
- Live regions for dynamic content — role=alert, role=status, aria-live placement
- Focus management — what happens after state change (modal open/close, form submit, navigation)
- tabindex usage — flag any positive values (0 and -1 only)
- Framework-specific patterns — React focus management, Vue accessibility, Svelte reactivity + keyboard

### Module 4: Keyboard Navigation & Focus Audit
**Trigger:** Any interactive component or full product

*Apply: keyboard-focus-auditor skill*

Document the complete keyboard model:
- Tab order — map every focusable element in sequence; match logical flow
- Skip links — present, visible on keyboard focus, functional
- Focus indicators — visible on every interactive element; never remove without replacement
- Focus traps — required for modals/overlays; absent elsewhere
- Keyboard operability — every action achievable without mouse (buttons, dropdowns, date pickers, custom controls)
- Focus management — auto-focus on modal open, return on close; maintain after dynamic updates
- Focus obscured — sticky headers, floating cookie notices, banners hiding focused elements
- Keyboard shortcuts — if single-character shortcuts exist, flag ability to disable/remap

### Module 5: Copy & Content Audit
**Trigger:** Any text content, form labels, error messages, CTA copy

*Apply: accessibility-copy skill*

Audit all text content for accessibility and plain language:
- Button and link labels — descriptive, unique in context, no "click here" or "read more"
- Error messages — identify the field by name, describe the problem, provide the fix (not just "Error")
- Form instructions — placed before fields, not after; linked to input via aria-describedby
- Status and notification messages — programmatically determinable; appear in correct landmark
- Reading level — estimate grade level; flag if above Grade 8 (WCAG AAA 3.1.5)
- Plain language — avoid passive voice, reduce sentence length, remove jargon and idioms
- Sensory references — no "red error message" or "see the box below"
- Abbreviations and acronyms — expanded form on first use or in glossary

### Module 6: Image & Alt Text Audit
**Trigger:** Any images, icons, graphics, diagrams, charts in design or code

*Apply: alt-text-generator skill*

Classify and evaluate every image:
- Decorative images — confirm `alt=""` present (intentional empty alt)
- Informative images — evaluate alt text quality; should describe purpose/content in 125 chars
- Functional images (buttons, links) — alt describes action, not appearance
- Complex images (charts, infographics) — short alt + long description (aria-describedby, `<figcaption>`, adjacent text)
- Text in images — alt includes verbatim text or image is converted to real text
- Background images carrying meaning — confirm also represented in text content

### Module 7: Forms Audit (if forms/inputs present)
**Trigger:** Any form, input field, data entry component in design or code

*Apply: accessible-forms skill*

Run only if interactive input elements are present:
- Label association — explicit `<label for="id">`, no placeholder-only labels, visible labels
- Input types and autocomplete — email, tel, password, etc.; autocomplete tokens for personal data
- Required field marking — programmatic HTML `required` + visible indicator; not color-only
- Inline hints and instructions — placed between label and input; linked via aria-describedby
- Validation timing — on blur or form submit, not on keystroke (too aggressive)
- Error state implementation — aria-invalid="true", aria-describedby, role=alert for error message
- Error summary — present and keyboard-focused on multi-field form submit failure
- Fieldset + legend — used for grouped inputs (radio groups, checkbox groups, date/time sets)
- Multi-step form — focus management on page transitions; progress indicator; ability to navigate backward
- Password and confirmation fields — security patterns without accessibility sacrifice

### Module 8: Tables Audit (if data tables present)
**Trigger:** Any table in design or code; flag layout tables as anti-pattern

*Apply: accessible-tables skill*

Run only if semantic data tables are present:
- `<caption>` — present and descriptive (not "Table 1")
- thead/tbody/tfoot — semantic structure; not CSS-only row grouping
- `<th>` with scope — all header cells marked; scope="col" or scope="row" applied
- Complex tables — id/headers attributes when header structure is complex
- Sortable columns — aria-sort attribute on current/sortable columns
- Responsive strategy — maintains semantic structure when reflowed; no horizontal scroll at mobile
- Row or column selection — aria-selected state for selected rows/cells in multi-select tables
- Merged cells — avoided where possible; if used, properly scoped

### Module 9: Motion & Animation Audit (if animations present)
**Trigger:** Any moving, animated, or transitioning elements

*Apply: motion-auditor skill*

Run only if animations, transitions, auto-playing content, or parallax present:
- Flashing content — flagged if ≥ 3Hz (WCAG 2.3.1); general and red flash thresholds checked
- prefers-reduced-motion support — CSS media query respected; motion disabled for users who prefer reduced motion
- Auto-playing content — carousel, video, slideshow; has pause/stop control if auto-plays > 5 seconds
- Vestibular risk — parallax, large viewport motion, zoom effects that trigger vertigo/migraine
- Third-party motion libraries — Framer Motion, GSAP, Lottie, AOS library configuration and prefers-reduced-motion handling
- Scroll-triggered animations — respect reduced motion; don't cause layout shift
- Hover and focus animations — brief, purposeful; don't hide content

### Module 10: Cognitive Accessibility Audit
**Trigger:** Run for all input types — cognitive accessibility applies everywhere

*Apply: cognitive-accessibility skill*

- Reading level — estimate grade level; flag if above Grade 8
- Plain language — passive voice, sentence length, complex words, jargon, idioms, foreign phrases
- Typography — line length (50–75 chars ideal), line height (≥1.5x), font-size consistency, justified text (avoid)
- Memory and attention load — simultaneous choices, steps without reference, distractions, CAPTCHAs
- Consistency and predictability — navigation order consistent, component names consistent, no unexpected behavior on focus
- Error prevention — confirmation for destructive actions, undo availability, constraints on sensitive fields
- Dark patterns — urgency manipulation, confirmshaming, hidden cancellation, deceptive defaults
- Accessible authentication — no complex CAPTCHA; alternatives (math, image selection) provided; paste enabled for passwords
- Context-sensitive help — available at decision points without leaving flow; tooltips and instructions present
- Session and timeout handling — warnings 20+ seconds before timeout, ability to extend data

### Module 11: Mobile & Touch Audit
**Trigger:** Mobile app screenshot, responsive web design, or mobile-specific features

*Apply: mobile-touch-auditor skill*

Run when input is mobile app, responsive web, or touch-first UI:
- Touch target sizing — 44×44px (AAA), 24×24px (AA minimum); spacing between targets
- Gesture alternatives — every swipe, pinch, long-press has single-tap or button alternative
- Pointer cancellation — actions fire on pointer-up, not pointer-down; drag operations cancellable
- Motion actuation — shake/tilt/rotation alternatives; motion triggers can be disabled
- Orientation — not locked to portrait/landscape without essential justification (e.g., video requires landscape)
- Virtual keyboard — inputs specify correct type (email, tel, url, number); viewport not obscured when keyboard opens
- Thumb zone — critical actions within comfortable thumb reach (lower 50% of screen optimal)
- iOS VoiceOver — accessibilityLabel, accessibilityHint, accessibilityViewIsModal, focus notifications
- Android TalkBack — contentDescription, announceForAccessibility, live regions, reading order
- Responsive breakpoints — 320px minimum viewport; reflow tested at all breakpoints; no horizontal scroll at 400% zoom

### Module 12: PDF & Document Audit (if PDFs / downloadable documents referenced)
**Trigger:** PDF files, Word docs, PowerPoint, downloadable materials

*Apply: pdf-document-accessibility skill*

Run when input includes or references PDFs, DOCX, PPTX, or other downloadable files:
- Tagged PDF — structure tree present and logical; reading order correct
- Heading tags — H1–H6 used semantically; not bold paragraphs pretending to be headings
- Image alt text — all figures have Alt Text; decorative images marked as Artifact
- Table structure — thead, tbody, tfoot; TH with scope; caption present
- Language declaration — document language set in metadata; language changes marked in content
- Document title — descriptive title set; "Display document title" enabled in PDF viewer
- Links — all active and descriptive; no bare URLs; no "click here"
- Bookmarks — present for documents > 10 pages; structure matches content outline
- Forms (if present) — field tooltips, tab order, keyboard operability, proper labels
- Fonts — embedded for portability; actual text (not bitmap); subsetted or fallbacks provided

### Module 13: Video & Media Audit (if video, audio, podcasts referenced)
**Trigger:** Video, audio, webinar, podcast, animation with narration

*Apply: video-media-accessibility skill*

Run when input includes or references video, audio, or media content:
- Captions — present for all prerecorded video with audio (AA requirement); accurate and complete
- Caption quality — timing correct, speaker ID included, sound effects noted ([door slams], [laugh]), formatting clear
- Audio description — present for all prerecorded video with visual-only information (AA requirement)
- Transcripts — present for audio-only content; full descriptive transcript for video
- Live captions — present for live video/streaming events (AA requirement)
- Media player — keyboard accessible (all controls laberable via Tab), ARIA labels correct, no hover-only UI
- Autoplay behavior — no auto-playing with audio; if animation auto-plays without audio, pause/stop control present

### Module 14: Design Handoff & Annotations
**Trigger:** Design file provided or developer handoff documentation needed

*Apply: accessibility-annotations skill*

Generate annotation content for developer handoff:
- Focus order — numbered tab stop sequence for all interactive elements; visual numbering in Figma/design
- Landmark map — all semantic regions labeled; ARIA labels provided for multiple nav/aside elements
- Heading levels — H1–H6 assignment for every text element; visual hierarchy matches logical structure
- ARIA roles and names — per interactive component; correct role usage and name resolution method
- Interactive states — hover, focus, active, disabled, error, selected, expanded; visual design for each
- Keyboard behavior — key mappings per component (Tab, Enter, Space, Escape, Arrow keys, etc.)
- Reading order — DOM order where it differs from visual; note CSS reordering
- Live regions — role=alert, role=status placement; aria-live="polite" vs "assertive" intent
- Skip link — presence and destination; visual treatment when focused
- Alt text placeholders — for all images; decorative vs informative classification

---

## Step 4: Conflict Resolution & Deduplication

When modules produce overlapping findings (e.g., contrast issue found by both design and code audits):
- Keep the finding once
- Note which modules detected it
- Use most specific severity (P0 if any module rates P0)
- Consolidate fixes into one action item

When modules disagree on severity:
- Design audit says P1, Code audit says P2 → investigate root cause
- If issue blocks task, it's P0; if workaround exists, it's P1/P2
- Document the conflict and reasoning in the report

---

## Step 5: Synthesize Into Unified Report with Business Impact

After running all applicable modules, compile findings into a single structured report. Do not produce separate module reports — merge, deduplicate, and present a unified view grounded in business impact.

### Report Structure

```
# Accessibility Audit Report

**Product / Component:** [name and version]
**Input Type:** [design / code / both / live product]
**Standards:** WCAG 2.2 AA, AAA findings noted separately, Section 508 compliance flagged
**Audit Date:** [date]
**Auditor:** Full Accessibility Audit (Claude)

---

## Executive Summary

[4–5 sentences: overall conformance state, total issue count by severity,
highest-risk area, one strength, the #1 thing to fix first, and business impact.]

**Issue Count:**
- P0 (CRITICAL): [n] — blocks access, legal exposure
- P1 (MAJOR): [n] — significant degradation
- P2 (MINOR): [n] — friction, workarounds exist
- P3 (ENHANCEMENT): [n] — best practice, future roadmap

**Overall Conformance Estimate:**
- Non-conformant / Partially Conformant / Substantially Conformant / Likely Conformant
- (Note: Full conformance determination requires manual AT testing with real disabled users)

**Effort to Remediate:**
- P0 fixes: [S/M/L] — [X hours]
- P1 fixes: [S/M/L] — [X hours]
- Full remediation: [S/M/L] — [X hours]

**Business Impact:**
- Legal exposure: [None / Low / Medium / High] — Section 508 / ADA alignment
- User exclusion: [% of users potentially unable to complete primary tasks]
- Reputational: [Risk level if accessibility failures publicized]
- Opportunity: [Market expansion if accessibility improved]

---

## Critical Issues — P0
*MUST FIX BEFORE LAUNCH. Active harm, legal exposure, task blockage.*

### [Issue Title]
- **WCAG Criterion:** [e.g., 1.4.3 Contrast]
- **Module Detection:** [which audit dimension found this]
- **Severity Justification:** [why this is P0, not P1]
- **Finding:** [what was observed, with specificity]
- **Affected Users:** [disability types, % of user base]
- **Impact Narrative:** [how this breaks their workflow]
- **Fix:** [specific, actionable remediation; code examples if applicable]
- **Effort:** [S/M/L]

[repeat for each P0]

---

## Major Issues — P1
*FIX IN CURRENT SPRINT. Significantly degrades experience.*

[same format as P0]

---

## Minor Issues — P2
*FIX IN NEXT SPRINT. Workarounds exist but friction significant.*

[same format]

---

## Enhancements — P3
*BEST PRACTICE. Consider for AAA compliance or future iteration.*

[same format]

---

## Passed Checks

**Visual/Design:**
- [ ] Color contrast meets AA standards for all text and UI components
- [ ] Focus indicators visible and sufficient contrast
- [ ] Touch targets meet 44×44px minimum (AAA) / 24×24px (AA)
- [ ] Heading hierarchy logical and complete
- [ ] Layout reflows at 400% zoom and 320px viewport without horizontal scroll
- [ ] Reading order matches visual order

**Code/Structure:**
- [ ] Semantic HTML used correctly (button, nav, main, landmark regions)
- [ ] ARIA used only when necessary; never to fix bad semantics
- [ ] Heading hierarchy in DOM matches design intent
- [ ] Form inputs have persistent visible labels
- [ ] All interactive elements keyboard operable

**Keyboard/Navigation:**
- [ ] Tab order is logical and matches visual flow
- [ ] Focus indicators present on all interactive elements
- [ ] Skip link present and functional
- [ ] No keyboard traps in non-modal contexts
- [ ] Modal focus trap and Escape-to-close working

**Copy/Content:**
- [ ] Form labels and error messages descriptive
- [ ] No sensory-only instructions ("click the green button")
- [ ] Reading level appropriate to audience
- [ ] Link text descriptive and unique in context

**Images/Alt Text:**
- [ ] All images classified (decorative / informative / functional)
- [ ] Informative images have meaningful alt text
- [ ] Complex images have extended descriptions
- [ ] Decorative images have empty alt="" or CSS background

**Forms (if present):**
- [ ] All inputs have associated labels
- [ ] Required fields marked programmatically
- [ ] Error messages identify field and problem
- [ ] Form flows are keyboard navigable

**Tables (if present):**
- [ ] Tables have captions
- [ ] Heading cells use <th> with scope
- [ ] Reading order matches visual order

**Motion (if present):**
- [ ] No flashing content above 3Hz threshold
- [ ] prefers-reduced-motion CSS media query respected
- [ ] Auto-playing content has pause/stop control

**Cognitive:**
- [ ] Reading level Grade 8 or below
- [ ] Plain language used throughout
- [ ] Consistency in navigation and naming
- [ ] Session timeouts have advance warnings

**Mobile (if responsive/app):**
- [ ] Touch targets 44×44px minimum
- [ ] Gesture alternatives available
- [ ] Orientation not locked without justification
- [ ] Virtual keyboard doesn't obscure input fields

---

## Contrast Audit Summary

| Element Type | Foreground Color | Background Color | Ratio | AA Pass | AAA Pass | Status |
|--------------|-----------------|------------------|-------|---------|----------|--------|
| Body text | [color] | [color] | [X:1] | [✓/✗] | [✓/✗] | [OK / FAIL] |
| Heading | [color] | [color] | [X:1] | [✓/✗] | [✓/✗] | [OK / FAIL] |
| Links (default) | [color] | [color] | [X:1] | [✓/✗] | [✓/✗] | [OK / FAIL] |
| Button | [color] | [color] | [X:1] | [✓/✗] | [✓/✗] | [OK / FAIL] |
| Focus ring | [color] | [color] | [X:1] | [✓/✗] | [✓/✗] | [OK / FAIL] |

---

## Keyboard Navigation Map

**Tab Order (expected sequence):**

| Stop # | Element | Expected Behavior | Current Behavior | Status |
|--------|---------|------------------|------------------|--------|
| 1 | Skip link | Focus visible, navigates to main | [actual] | [OK / BROKEN] |
| 2 | Navigation link 1 | Focus visible, keyboard operable | [actual] | [OK / BROKEN] |
| 3 | Primary CTA button | Focus visible, Enter/Space activate | [actual] | [OK / BROKEN] |

---

## Images & Alt Text Inventory

| Image | Location | Classification | Alt Text | Status |
|-------|----------|-----------------|----------|--------|
| Logo | Header | Functional | [alt text or "needs alt"] | [OK / FAIL] |
| Chart | Page 2 | Complex/Informative | [short alt] / [long description link] | [OK / FAIL] |
| Decorative divider | Sidebar | Decorative | [alt=""] or CSS | [OK / FAIL] |

---

## Remediation Roadmap

### Phase 1 — Immediate (This Sprint, Block Launch If Not Fixed)
[List P0 fixes only, prioritized by user impact and ease of fix]
1. [P0 issue] — Estimated [S/M/L] effort
2. [P0 issue] — Estimated [S/M/L] effort

### Phase 2 — Short Term (Next 2 Sprints)
[P1 fixes, grouped by component or area to minimize context switching and test cycles]
1. [P1 issue group] — Estimated [effort]
2. [P1 issue group] — Estimated [effort]

### Phase 3 — Planned (Next Quarter)
[P2 fixes and P3 enhancements, with suggested sequencing]
1. [P2 issue] — Estimated [effort]
2. [P3 enhancement] — Estimated [effort]

### Success Metrics (After Remediation)
- [ ] All P0 issues resolved
- [ ] Manual AT testing with NVDA + Chrome and VoiceOver + Safari passes
- [ ] WCAG 2.2 AA conformance achieved
- [ ] User testing with disabled participants confirms task completion

---

## Recommended AT Testing

**Highest-Value Test Cases (from a11y-test-plan & screen-reader-scripting):**

### Test Case 1: [Primary User Flow — e.g., "Complete a Purchase"]
- **AT Combination:** NVDA + Chrome (Windows)
- **Steps:**
  1. Enable NVDA
  2. Tab to product page
  3. Navigate to add-to-cart button
  4. Activate button (Enter/Space)
  5. [continue flow]
- **Expected Outcome:** All content announced, no content hidden, errors announced clearly
- **Priority:** P0 (blocks primary task)

### Test Case 2: [Form Submission]
- **AT Combination:** VoiceOver + Safari (macOS)
- **Steps:** [specific steps]
- **Expected Outcome:** [specific outcomes]
- **Priority:** P1

---

## Audit Coverage & Module Status

| Module | Status | Issues Found | Notes |
|--------|--------|--------------|-------|
| Design / Visual | Ran | [n P0, n P1, n P2] | [summary] |
| Contrast | Ran | [n failures] | [pairs checked] |
| Code | Ran | [n P0, n P1, n P2] | [summary] |
| Keyboard | Ran | [n issues] | [summary] |
| Copy | Ran | [n issues] | [summary] |
| Alt Text | Ran | [n images audited] | [summary] |
| Forms | Ran / N/A | [n issues] | [summary or "No forms present"] |
| Tables | Ran / N/A | [n issues] | [summary or "No tables present"] |
| Motion | Ran / N/A | [n issues] | [summary or "No animation present"] |
| Screen Reader Scripts | Ran | [n test cases] | NVDA + Chrome, VoiceOver + Safari |
| Cognitive | Ran | [n issues] | [reading level, plain language] |
| Mobile / Touch | Ran / N/A | [n issues] | [summary or "Desktop only"] |
| PDF / Document | Ran / N/A | [n documents] | [summary or "No documents"] |
| Video / Media | Ran / N/A | [n issues] | [summary or "No video present"] |
| Annotations | Ran | Generated | Focus order, landmark map, ARIA notes |

---

## Critical Caveats

- **This audit is based on [design / code / description / live product] provided.** Results reflect what can be assessed from that input. Gaps in input = gaps in audit.
- **AT testing requires real assistive technology.** Automated tools catch ~30% of WCAG issues; manual methodology here catches more, but cannot substitute for testing with real disabled users.
- **Contrast ratios calculated from sampled/provided color values.** Verify against final rendered output in all browsers and lighting conditions.
- **Focus management and dynamic state behavior must be verified in the browser.** Design audits cannot assess runtime keyboard traps or focus loss after state changes.
- **Screen reader announcements depend on HTML structure AND screen reader quirks.** NVDA, JAWS, and VoiceOver announce the same content differently; test with multiple readers.
- **Full conformance claims require testing with users who have disabilities.** WCAG compliance is binary (yes/no); real-world accessibility is continuous. Involve disabled users in QA.

---

## Next Steps & Deliverables

After review of this report, offer these follow-ups:

1. **Detailed fix guidance:** "Want me to write corrected code for the P0 issues? I can provide exact HTML/CSS/React patterns."
2. **Developer handoff pack:** "Want accessibility annotations + code snippets packaged for your engineering team?"
3. **Custom WCAG checklist:** "Want a scoped WCAG 2.2 checklist tailored to [product type]?"
4. **Stakeholder summary:** "Want a 1-page exec summary for leadership/client highlighting business impact?"
5. **Accessibility statement draft:** "Want a draft accessibility statement for your site, listing known issues and how to report problems?"
6. **QA test plan:** "Want detailed QA steps to verify each fix before deployment?"
7. **Remediation roadmap refinement:** "Want help breaking Phase 1–3 into detailed tickets and estimating engineering effort?"
8. **User testing coordination:** "Want guidance on recruiting disabled users for accessibility QA?"

---

## Audit Quality Standards

Every report produced by this skill must:

- [x] Reference specific WCAG criterion numbers for every finding
- [x] Include severity ratings (P0–P3) for every issue
- [x] Provide actionable fixes, not just observations
- [x] Show contrast math, not just pass/fail verdicts
- [x] Distinguish between AA failures and AAA best-practice gaps
- [x] Include business impact narrative (not just compliance checklist)
- [x] Be honest about what can and cannot be determined from input provided
- [x] Never claim full conformance — always note AT testing requirement
- [x] Offer clear next steps and follow-up deliverables

If input is too limited to run a meaningful audit (e.g., description only, no visual), say so specifically and ask for what's needed. A thin audit is worse than no audit — it creates false confidence.
```
