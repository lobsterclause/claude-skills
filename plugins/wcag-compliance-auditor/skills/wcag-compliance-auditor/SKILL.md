---
name: wcag-compliance-auditor
description: "Systematically audit against all WCAG 2.2 success criteria with severity ratings, effort estimates, and business impact narratives. Use this skill for criterion-level compliance audits, conformance declarations, or VPAT preparation. Trigger on phrases like WCAG compliance audit, WCAG 2.2 audit, criterion-by-criterion, conformance level, compliance report, Section 508 audit, or any request for detailed standards-based accessibility assessment."
category: audit
related-skills: wcag-checklist, full-accessibility-audit, a11y-test-plan, accessibility-advisor
---

# WCAG 2.2 Compliance Auditor

## Purpose
Systematically audit digital properties against WCAG 2.2 AA and AAA success criteria, providing detailed compliance mapping with severity ratings, effort estimates, and business impact narratives. This skill serves as the authoritative compliance reference, complementing the broader full-accessibility-audit with focused criterion-level analysis.

## Use Cases
- **Regulatory Compliance Assessment**: Determine Section 508 and ADA compliance status with legal exposure analysis
- **Criterion-Level Remediation Planning**: Prioritize work using severity × effort matrix
- **Detailed Audit Documentation**: Generate compliance statements required for contracts and legal proceedings
- **Standards-Based Testing**: Verify implementation against specific WCAG criteria
- **Accessibility Procurement**: Evaluate vendor solutions against WCAG requirements
- **Progress Tracking**: Monitor remediation across all 86 WCAG 2.2 success criteria

## Related Skills
- **full-accessibility-audit**: Use for holistic assessment; this skill provides criterion-level depth for audit findings
- **accessibility-audit**: Use for visual/interaction design layer; cross-reference component patterns here
- **accessibility-code**: Use for implementation verification; provides code-level testing procedures
- **wcag-checklist**: Use for quick reference during development; this skill provides thorough analysis
- **a11y-test-plan**: Use for systematic testing protocols matching WCAG criteria

---

## Input Requirements

### Specify Audit Scope
Provide one or more of:
- **URL or file path** to digital property (web app, document, mobile site)
- **Specific guideline(s)** to audit (e.g., "Guideline 2.4 Navigable" or "all visual criteria")
- **Compliance target** (AA or AAA)
- **Component list** if auditing design system elements

### Required Context
- **Platform**: Web (HTML/CSS/JS), PDF, mobile app, or document
- **Technologies used**: Frameworks, libraries, build tools (helps interpret WCAG applicability)
- **Known limitations**: Any constraints on remediation (technical debt, legacy systems, resource constraints)

---

## WCAG 2.2 Criterion Categories

### Perceivable (12 criteria)
Ensure information is available to all senses through multiple modalities.

#### 1.1 Text Alternatives
**Guideline**: Provide text alternatives for non-text content

| Criterion | Severity | Commonly Failed | Effort | Description |
|-----------|----------|-----------------|--------|-------------|
| 1.1.1 Non-text Content (A) | CRITICAL | Yes | S | All images, icons, charts need alt text or text equivalent. Decorative images use alt="" |
| 1.2.1 Audio-only and Video-only (A) | CRITICAL | Yes | M | Pre-recorded audio or video-only content needs transcript or description track |
| 1.2.2 Captions (Prerecorded) (A) | CRITICAL | Yes | M | Pre-recorded video must have captions synchronized with audio |
| 1.2.3 Audio Description (Prerecorded) (A) | CRITICAL | Yes | L | Pre-recorded video needs audio description for visual information |
| 1.2.4 Captions (Live) (AA) | MAJOR | Yes | L | Live video requires real-time captions |
| 1.2.5 Audio Description (Prerecorded) (AA) | MAJOR | Moderate | L | Pre-recorded video with visual information needs full audio description |

**Severity Basis**: CRITICAL: Users cannot access any media content without alternatives. MAJOR: Live events less frequent but high impact when occurred.

**Business Impact Narrative**:
- **Legal Exposure**: ADA lawsuits specifically target inadequate video captions (NCOD v. Netflix precedent)
- **User Exclusion**: ~80 million deaf/hard-of-hearing + 253 million blind/low-vision users excluded
- **Content Value**: Video captions also improve SEO (searchable content) and engagement (+80% watch time)
- **Opportunity**: Captions enable international reach (dubbing alternative, viewing in noisy environments)

#### 1.3 Adaptable
**Guideline**: Information is presentable in different formats without information loss

| Criterion | Severity | Commonly Failed | Effort | Description |
|-----------|----------|-----------------|--------|-------------|
| 1.3.1 Info and Relationships (A) | CRITICAL | Yes | S | Use semantic HTML (headings, lists, labels) not visual formatting alone for structure |
| 1.3.2 Meaningful Sequence (A) | CRITICAL | Yes | S | Tab order and reading order match logical flow (left-to-right, top-to-bottom, groups) |
| 1.3.3 Sensory Characteristics (A) | CRITICAL | Yes | S | Don't use sensory-only instructions ("click red button" without text label "Submit") |
| 1.3.4 Orientation (AA) | MAJOR | Yes | S | Don't lock screen orientation; respect device orientation preferences |
| 1.3.5 Identify Input Purpose (AA) | MAJOR | Moderate | S | Use autocomplete attributes on form fields for fields (email, name, address, phone, etc.) |
| 1.3.6 Identify Purpose (AAA) | MINOR | Moderate | S | Icons, buttons, and fields must have programmatically determinable purpose |

**Severity Basis**: CRITICAL affects screen reader users and zoom users. MAJOR affects mobile and autofill.

**Business Impact Narrative**:
- **Legal Exposure**: WCAG 1.3 violations are top-cited in lawsuits (structure/semantics foundational)
- **User Exclusion**: Screen reader users (blind/low-vision), magnification users (low-vision), voice control users, keyboard-only users
- **Operational Efficiency**: Semantic HTML reduces QA burden (natural accessibility); poor structure creates cascading maintenance debt
- **Opportunity**: Semantic HTML improves SEO (search engines parse structure), mobile performance (less CSS), and codebase maintainability

#### 1.4 Distinguishable
**Guideline**: Make foreground/background distinguishable; ensure adequate visual separation

| Criterion | Severity | Commonly Failed | Effort | Description |
|-----------|----------|-----------------|--------|-------------|
| 1.4.1 Use of Color (A) | CRITICAL | Yes | S | Don't convey information through color alone (forms, status, links). Add text, pattern, or icon. |
| 1.4.3 Contrast (Minimum) (A) | CRITICAL | Yes | S | 4.5:1 normal text, 3:1 large text (18pt+), 3:1 UI components and graphical objects. Measure all instances. |
| 1.4.4 Resize Text (A) | CRITICAL | Yes | S | Text must remain legible at 200% zoom without loss of function. Test reflow at 320px width. |
| 1.4.5 Images of Text (A) | MAJOR | Moderate | S | Don't use images for text unless decorative or user-controlled (charts with text labels okay if resizable) |
| 1.4.10 Reflow (AA) | MAJOR | Yes | S | Content reflows to single column at 400% zoom on 320px viewport without horizontal scroll |
| 1.4.11 Non-text Contrast (AA) | MAJOR | Yes | S | 3:1 contrast for graphical objects and UI components (buttons, icons, focus indicators) |
| 1.4.12 Text Spacing (AA) | MAJOR | Moderate | S | Content must remain usable when user overrides spacing (line-height: 1.5, letter-spacing: 0.12em, word-spacing: 0.16em) |
| 1.4.13 Content on Hover or Focus (AA) | MAJOR | Moderate | M | Popovers/tooltips triggered on hover/focus must be dismissable (Escape), not hide content, stay visible on hover |

**Severity Basis**: CRITICAL affects low-vision users and color-blind users (8% males, 0.5% females have color blindness). MAJOR affects zoom users and users with motor control issues.

**Business Impact Narrative**:
- **Legal Exposure**: 1.4.3 (contrast) is top WCAG violation category; 1.4.10 (reflow) increasingly targeted in mobile audits
- **User Exclusion**: ~253 million blind/low-vision users, ~8% of males color-blind, ~25% of population uses zoom/magnification at some point
- **Content Accessibility**: Images of text fail magnification and reflow; cost 4-8% time increase for low-vision users
- **Opportunity**: WCAG 1.4 compliance improves readability for all users (better contrast = better on mobile, better in bright sunlight, better for aging eyes)

---

### Operable (18 criteria)
Ensure all functionality is available via keyboard and without time-sensitive interactions.

#### 2.1 Keyboard Accessible
**Guideline**: All functionality must be available via keyboard

| Criterion | Severity | Commonly Failed | Effort | Description |
|-----------|----------|-----------------|--------|-------------|
| 2.1.1 Keyboard (A) | CRITICAL | Yes | M | All functionality must be operable via keyboard (Tab, Enter, Space, arrow keys, Esc). No keyboard trap. |
| 2.1.2 No Keyboard Trap (A) | CRITICAL | Yes | M | If focus can be moved to element via keyboard, focus can be moved away via keyboard. Modals must implement focus trap properly. |
| 2.1.3 Keyboard (No Exception) (AAA) | CRITICAL | Rare | L | Even drawing applications and real-time games must support keyboard (AAA requirement, rarely applicable) |
| 2.1.4 Character Key Shortcuts (A) | MAJOR | Moderate | S | Single character shortcuts must be toggleable, have escape mechanism, or not conflict with browser shortcuts |

**Severity Basis**: CRITICAL affects keyboard-only users, motor control users, voice control users. MAJOR affects users with custom keyboard mappings.

**Business Impact Narrative**:
- **Legal Exposure**: Keyboard inaccessibility is immediate litigation trigger (completely excludes users)
- **User Exclusion**: ~18 million users with motor disabilities, ~2 million speech/voice disability users, power users who prefer keyboard
- **Operational Efficiency**: Keyboard support catches interaction bugs (focus management, event listeners, form submission) during development
- **Opportunity**: Keyboard shortcuts increase productivity for expert users; accessible keyboard UX improves app stability

#### 2.2 Enough Time
**Guideline**: Users have sufficient time to read, understand, and interact

| Criterion | Severity | Commonly Failed | Effort | Description |
|-----------|----------|-----------------|--------|-------------|
| 2.2.1 Timing Adjustable (A) | CRITICAL | Yes | M | No time limits unless user can adjust (extend minimum 10×), or exemption applies (real-time event, emergency) |
| 2.2.2 Pause, Stop, Hide (A) | CRITICAL | Yes | M | Automatically moving/flashing content (carousels, animations) must be pausable by user |
| 2.2.3 No Timing (AAA) | CRITICAL | Rare | L | No timing-dependent interactions (AAA only, rare in practice) |
| 2.2.4 Interruptions (AAA) | MAJOR | Moderate | L | No interruptions (notifications, pop-ups) unless user-requested or emergency |
| 2.2.5 Re-authenticating (AAA) | MAJOR | Yes | L | Session timeout doesn't lose data; user can resume after re-authentication |
| 2.2.6 Timeouts (AAA) | MAJOR | Yes | L | Users warned of inactivity with >20 second notice before timeout |

**Severity Basis**: CRITICAL affects users with reading disabilities, processing delays, and motor control issues. MAJOR affects users with cognitive disabilities.

**Business Impact Narrative**:
- **Legal Exposure**: Banking/health/financial sites face WCAG 2.2 scrutiny for session timeouts
- **User Exclusion**: ~40 million cognitive disability users, users with reading disabilities, users with processing delays
- **Data Protection**: Timing requirements protect user data (re-authentication, data loss prevention)
- **Opportunity**: Accessible timing reduces user frustration, abandonment; improves completion rates for multi-step processes

#### 2.3 Seizures and Physical Reactions
**Guideline**: Avoid flashing content that could trigger seizures

| Criterion | Severity | Commonly Failed | Effort | Description |
|-----------|----------|-----------------|--------|-------------|
| 2.3.1 Three Flashes or Below Threshold (A) | CRITICAL | Rare | M | No more than 3 flashes/second or below general flash threshold (area <25% of viewport or >10,000 pixels) |
| 2.3.2 Three Flashes (AAA) | CRITICAL | Rare | L | No more than 3 flashes/second anywhere on page (AAA stricter than A) |
| 2.3.3 Animation from Interactions (AAA) | MINOR | Moderate | S | Animations triggered by user interaction can be motion-triggered only if there's a control to disable or prefers-reduced-motion is respected |

**Severity Basis**: CRITICAL even if rare because impact is severe (seizure risk). MINOR for 2.3.3 because it's less common trigger.

**Business Impact Narrative**:
- **Legal Exposure**: Seizure-causing content is illegal in many jurisdictions; opens liability to severe damages
- **User Exclusion**: ~1-2% of population at seizure risk from photosensitivity (more common in children)
- **Duty of Care**: Organizations have legal obligation to prevent known hazards
- **Opportunity**: Animation guidelines improve UX for all users (less dizziness, better performance, accessible VFX)

#### 2.4 Navigable
**Guideline**: Navigation and finding content must be intuitive and unambiguous

| Criterion | Severity | Commonly Failed | Effort | Description |
|-----------|----------|-----------------|--------|-------------|
| 2.4.1 Bypass Blocks (A) | CRITICAL | Yes | S | "Skip to main content" or equivalent bypass for repeated blocks (navigation, headers). Needs visible on focus. |
| 2.4.2 Page Titled (A) | CRITICAL | Yes | S | Each page has descriptive title (different from heading; appears in browser tab/history/screen reader) |
| 2.4.3 Focus Order (A) | CRITICAL | Yes | M | Tab order is logical and meaningful; matches visual layout (left-to-right, top-to-bottom) |
| 2.4.4 Link Purpose (A) | CRITICAL | Yes | S | Link text or title describes purpose; avoid "click here", "read more", "link" as sole text |
| 2.4.5 Multiple Ways (AA) | MAJOR | Moderate | M | Multiple ways to find content (search, sitemap, breadcrumb, navigation menu) except home page |
| 2.4.6 Headings and Labels (A) | CRITICAL | Yes | S | Headings and labels describe purpose; headings follow hierarchy (H1-H6 in order, no skips) |
| 2.4.7 Focus Visible (AA) | CRITICAL | Yes | S | Keyboard focus indicator visible (2px minimum, 3:1 contrast, area ≥ perimeter × 2px); :focus-visible not :focus |
| 2.4.8 Location (AAA) | MINOR | Moderate | S | Users know location in site (breadcrumb, site map, current section highlighted in navigation) |
| 2.4.9 Link Purpose (Link Text Only) (AAA) | MAJOR | Yes | S | Link text alone describes purpose (no "read more" without context); improve from AA requirement |
| 2.4.10 Section Headings (AAA) | MINOR | Moderate | S | Content organized with headings; text not orphaned between sections |
| 2.4.11 Focus Appearance (Minimum) (AA) | CRITICAL | Yes | S | Focus indicator: 2px minimum, 3:1 minimum contrast, not hidden by content, area ≥ perimeter × 2px |
| 2.4.12 Focus Appearance (Enhanced) (AAA) | MAJOR | Yes | S | Focus indicator stricter: 4px minimum, part of control perimeter, no background color obscuring it |
| 2.4.13 Focus Appearance (AAA) | MINOR | Moderate | S | Focus appearance customization via CSS custom properties (--focus-width, --focus-color) |

**Severity Basis**: CRITICAL affects screen reader users and keyboard users. MAJOR affects discoverability.

**Business Impact Narrative**:
- **Legal Exposure**: 2.4.3 (focus order) and 2.4.7 (focus visible) are top-cited violations
- **User Exclusion**: ~2 million keyboard-only users, ~253 million screen reader users, ~18 million motor disability users
- **Operational Efficiency**: Clear focus indicators reduce QA burden (visible in testing); poor focus = navigation bugs
- **Opportunity**: Good focus management improves UX for all users (clearer navigation, faster task completion)

#### 2.5 Input Modalities
**Guideline**: Support multiple input methods (keyboard, pointer, voice, gesture)

| Criterion | Severity | Commonly Failed | Effort | Description |
|-----------|----------|-----------------|--------|-------------|
| 2.5.1 Pointer Gestures (A) | MAJOR | Yes | M | Multi-touch gestures must have keyboard alternative (pinch-zoom → button zoom, swipe → arrow keys) |
| 2.5.2 Pointer Cancellation (A) | CRITICAL | Yes | S | No "down-event activation" (mousedown); only "up-event" (mouseup, click); must be reversible |
| 2.5.3 Label in Name (A) | CRITICAL | Yes | S | Accessible name includes visible label text (voice control users call out visible text) |
| 2.5.4 Motion Actuation (A) | MAJOR | Moderate | M | Motion-triggered controls (device tilt, shake) must have button alternative; respect prefers-reduced-motion |
| 2.5.5 Target Size (Enhanced) (AAA) | MAJOR | Yes | S | Touch targets 44×44 CSS pixels (AAA); 24×24 CSS pixels (AA if spacing maintained) |
| 2.5.6 Concurrent Input Mechanisms (AAA) | MINOR | Rare | S | Support all input types simultaneously (don't disable mouse because keyboard is used) |
| 2.5.7 Dragging Movements (AAA) | MAJOR | Moderate | M | Drag-and-drop must have keyboard alternative (arrow keys, form input) |
| 2.5.8 Target Size (Minimum) (AAA) | MAJOR | Yes | S | Touch targets minimum 24×24 CSS pixels (level A requirement pushes to 44×44 recommended) |

**Severity Basis**: CRITICAL affects voice control users and motor control users. MAJOR affects touch users.

**Business Impact Narrative**:
- **Legal Exposure**: Mobile apps with inadequate touch targets face specific Section 508 liability
- **User Exclusion**: ~18 million motor disability users, ~82 million older adults with reduced precision, voice control users
- **Mobile Optimization**: 44×44px targets improve mobile UX for all users (larger targets = fewer mis-taps)
- **Opportunity**: Alternative input methods increase market reach (voice-activated apps, hands-free accessibility)

---

### Understandable (16 criteria)
Information and operations must be clear and predictable.

#### 3.1 Readable
**Guideline**: Make text readable and understandable

| Criterion | Severity | Commonly Failed | Effort | Description |
|-----------|----------|-----------------|--------|-------------|
| 3.1.1 Language of Page (A) | CRITICAL | Yes | S | Specify page language in html lang attribute (affects screen reader pronunciation, automatic translation) |
| 3.1.2 Language of Parts (AA) | MAJOR | Moderate | S | Specify language for phrases/words in other language (lang="es" in span for Spanish phrase in English page) |
| 3.1.3 Unusual Words (AAA) | MINOR | Rare | M | Unusual words, jargon, abbreviations have definition or expand on first use |
| 3.1.4 Abbreviations (AAA) | MINOR | Moderate | S | Abbreviations (CEO, HTML) expanded on first use or via <abbr> element |
| 3.1.5 Reading Level (AAA) | MINOR | Moderate | M | Text written for Grade 8 reading level or provide simplified version (Flesch-Kincaid, Gunning fog) |
| 3.1.6 Pronunciation (AAA) | MINOR | Rare | M | Pronunciation defined for words where reading differs from pronunciation (e.g., "read" rhyming with "lead" vs. "bread") |

**Severity Basis**: CRITICAL affects non-native speakers and screen reader users. MINOR for 3.1.3+ because they affect smaller user groups.

**Business Impact Narrative**:
- **Legal Exposure**: Language specification is easy fix; overlooking it penalizes non-native speakers and assistive tech users
- **User Exclusion**: ~25% of page readers are non-native English speakers; affects dyslexic users
- **Global Reach**: Proper language markup enables automatic translation, localization
- **Opportunity**: Writing for Grade 8 level improves comprehension for all users (clearer instructions, less jargon)

#### 3.2 Predictable
**Guideline**: Behavior must be predictable and consistent

| Criterion | Severity | Commonly Failed | Effort | Description |
|-----------|----------|-----------------|--------|-------------|
| 3.2.1 On Focus (A) | CRITICAL | Yes | S | Focus doesn't cause unexpected change (don't submit form on focus, launch popup, move focus elsewhere). |
| 3.2.2 On Input (A) | CRITICAL | Yes | S | Changing input doesn't cause unexpected change (autocomplete filters okay; submission requires explicit action). |
| 3.2.3 Consistent Navigation (AA) | MAJOR | Yes | S | Navigation menu location and structure consistent across pages (header nav, footer nav must not move) |
| 3.2.4 Consistent Identification (AA) | MAJOR | Moderate | S | Components with same function identified consistently across pages (search icon always in top-right, button always says "Submit" not "Go" or "Send") |
| 3.2.5 Change on Request (AAA) | MINOR | Moderate | S | Significant changes require explicit user action (button click, confirmation) not automatic on focus/input |
| 3.2.6 Consistent Help (AAA) | MINOR | Moderate | M | Help/support available consistently across site (location, format, contact method consistent) |

**Severity Basis**: CRITICAL affects users with cognitive disabilities and screen reader users. MAJOR affects discoverability.

**Business Impact Narrative**:
- **Legal Exposure**: 3.2.1 and 3.2.2 are common violations in form-heavy sites
- **User Exclusion**: ~40 million cognitive disability users, users with attention/processing delays
- **User Experience**: Predictable behavior reduces support load (fewer "how do I" questions), increases completion rates
- **Opportunity**: Consistent patterns reduce code complexity (reusable components), improve maintainability

#### 3.3 Input Assistance
**Guideline**: Provide clear labels, errors, and confirmation for input

| Criterion | Severity | Commonly Failed | Effort | Description |
|-----------|----------|-----------------|--------|-------------|
| 3.3.1 Error Identification (A) | CRITICAL | Yes | M | Errors identified to user (text message identifying which field, not just red border). Error must be programmatically associated. |
| 3.3.2 Labels or Instructions (A) | CRITICAL | Yes | S | Input fields have visible label or instruction (not placeholder-only; labels must be <label for="id"> or aria-labelledby). |
| 3.3.3 Error Suggestion (AA) | MAJOR | Yes | M | If error detected, suggestion provided (email validation suggests "did you mean example@example.com?") if possible. |
| 3.3.4 Error Prevention (Legal, Financial, Data) (AA) | CRITICAL | Yes | M | For submissions with legal/financial consequences or data modification, changes must be reversible, confirmation required, or reviewed. |
| 3.3.5 Help (AAA) | MINOR | Moderate | M | Context-sensitive help available for form fields (tooltips, inline help, help icon) |
| 3.3.6 Error Prevention (All) (AAA) | MAJOR | Moderate | M | All form submissions have confirmation or error prevention; not just legal/financial |
| 3.3.7 Redundant Entry (AAA) | MINOR | Rare | S | Info previously provided not re-requested unless security-critical or explicitly re-entered (forms should pre-fill) |
| 3.3.8 Accessible Authentication (AAA) | MAJOR | Yes | M | Authentication not dependent on cognitive function alone (recognize image or pattern); allow alternative (username/password, passkey) |

**Severity Basis**: CRITICAL affects users with cognitive disabilities and dyslexic users. MAJOR affects all users in error recovery.

**Business Impact Narrative**:
- **Legal Exposure**: 3.3.4 is mandatory for financial/health sites; violations can trigger fraud liability
- **User Exclusion**: ~40 million cognitive disability users, dyslexic users, users with processing delays
- **Operational Efficiency**: Clear error messages reduce support burden; error prevention reduces data quality issues
- **Opportunity**: Good error handling improves completion rates for all users (better form UX, fewer abandonments)

---

### Robust (9 criteria)
Content must be compatible with assistive technologies via valid, semantic markup.

#### 4.1 Compatible
**Guideline**: Ensure maximum compatibility with assistive technologies

| Criterion | Severity | Commonly Failed | Effort | Description |
|-----------|----------|-----------------|--------|-------------|
| 4.1.1 Parsing (A) | CRITICAL | Yes | S | HTML is valid (no unclosed tags, no duplicate IDs, proper nesting) per HTML5 spec. Use W3C validator. |
| 4.1.2 Name, Role, Value (A) | CRITICAL | Yes | M | All UI components have accessible name (how it's called), role (what it is), and value (its state) programmatically determined. |
| 4.1.3 Status Messages (AA) | MAJOR | Yes | S | Status messages announced to screen readers (role="status" or role="alert"; aria-live="polite" or "assertive") |

**Severity Basis**: CRITICAL affects all assistive tech users. MAJOR affects screen reader users specifically.

**Business Impact Narrative**:
- **Legal Exposure**: 4.1.2 violations are foundational (component accessibility fails without proper semantics)
- **User Exclusion**: ~253 million screen reader users, all assistive tech users
- **Operational Efficiency**: Valid HTML catches bugs (parsing errors), reduces browser-specific bugs
- **Opportunity**: Valid, semantic HTML improves SEO, mobile performance, developer experience

---

## Severity and Effort Rating System

### Severity Ratings
**CRITICAL** (P0): Completely blocks user access or triggers hazard
- Examples: Missing alt text on images, keyboard inaccessible, insufficient contrast, no form labels
- Impact: User cannot use feature at all
- Business impact: High legal exposure, user exclusion, reputational damage

**MAJOR** (P1): Significantly impairs user experience but partial access possible
- Examples: Focus indicator barely visible, captions missing from video, no error message color contrast
- Impact: User struggles to complete task, requires workaround
- Business impact: Medium legal exposure, user frustration, support burden

**MINOR** (P2): Creates friction but users can work around
- Examples: Unusual abbreviation not expanded, page language not specified, reading level high but understandable
- Impact: User completes task with extra effort or confusion
- Business impact: Low legal exposure, reduced satisfaction

### Effort Estimation
**S (Small)**: 1-2 hours
- Markup fixes, attribute additions, color adjustments, text improvements

**M (Medium)**: 4-8 hours
- Keyboard interaction implementation, focus management, error handling flow changes

**L (Large)**: 16+ hours
- Architecture changes, framework-level refactoring, video captioning, full rewrite of complex component

---

## Audit Execution Workflow

### Phase 1: Triage and Scope
1. Identify digital property type (web app, document, mobile site, platform)
2. Confirm compliance target (AA or AAA)
3. Determine scope: full property or specific pages/components
4. Review known constraints (technical debt, resource limits)

### Phase 2: Criterion-by-Criterion Review
For each applicable WCAG criterion:
1. **Check if applicable** (some criteria exempted on certain content types)
2. **Test against requirement** using method from related skill (accessibility-code for code, accessibility-audit for design)
3. **Rate severity** using criteria above
4. **Flag if commonly failed** for this criterion
5. **Estimate effort** to remediate
6. **Document finding** with specific evidence (screenshot, code, interaction path)
7. **Calculate business impact** narrative

### Phase 3: Aggregate and Prioritize
1. Count failures by severity (CRITICAL/MAJOR/MINOR)
2. Create remediation matrix (severity × effort)
3. Identify quick wins (severity × effort = high priority)
4. Estimate total remediation effort across all criteria
5. Map remediation to phases based on business impact

### Phase 4: Output Documentation
Document findings in structured format (see template below)

---

## Audit Output Template

```
WCAG 2.2 Compliance Audit Report
Property: [URL/Product Name]
Compliance Target: AA / AAA
Audit Date: [Date]
Auditor: [Name]

=== EXECUTIVE SUMMARY ===

Compliance Rate: [X% of 86 applicable criteria]
Total Findings: [#] CRITICAL, [#] MAJOR, [#] MINOR
Estimated Remediation Effort: [#] days across [#] modules

Top Business Impact:
- [Highest risk impact area]
- [Highest user exclusion area]
- [Highest opportunity area]

=== CRITICAL FINDINGS (Immediate Attention) ===

1. [Guideline #.#.# Criterion Name]
   Severity: CRITICAL
   Commonly Failed: Yes/No
   Effort: S/M/L
   Affected Elements: [#] instances
   Finding: [Specific issue]
   Evidence: [Screenshot/code/interaction path]
   Business Impact: [Who excluded] → [Business consequence]
   Remediation: [What to fix]

[Additional CRITICAL findings...]

=== MAJOR FINDINGS (Short-term) ===

[Same format as above for MAJOR severity]

=== MINOR FINDINGS (Planned) ===

[Same format as above for MINOR severity]

=== REMEDIATION ROADMAP ===

Phase 1 (Immediate - 2-4 weeks): [CRITICAL findings, quick-win MAJOR findings]
- [Criterion]: [Brief remediation]
- [Estimated effort]: 3 days

Phase 2 (Short-term - 1-3 months): [Remaining MAJOR findings]
- [Estimated effort]: 12 days

Phase 3 (Planned - 3-6 months): [All MINOR findings]
- [Estimated effort]: 8 days

=== COMPLIANCE CHECKLIST ===

Perceivable
- [ ] 1.1 Text Alternatives
- [ ] 1.2 Time-based Media
- [ ] 1.3 Adaptable
- [ ] 1.4 Distinguishable

Operable
- [ ] 2.1 Keyboard Accessible
- [ ] 2.2 Enough Time
- [ ] 2.3 Seizures and Physical Reactions
- [ ] 2.4 Navigable
- [ ] 2.5 Input Modalities

Understandable
- [ ] 3.1 Readable
- [ ] 3.2 Predictable
- [ ] 3.3 Input Assistance

Robust
- [ ] 4.1 Compatible
```

---

## Testing Methods

### Keyboard Testing (2.1, 2.4, 2.5)
1. **Tab Navigation**: Press Tab repeatedly from page top to bottom
   - Focus moves logically left-to-right, top-to-bottom
   - No focus traps (pressing Tab repeatedly doesn't get stuck)
   - Focus indicator visible at every stop
   
2. **Keyboard Shortcuts**: 
   - Enter activates buttons/links
   - Space toggles checkboxes/radio buttons
   - Arrow keys navigate menus/tabs
   - Escape closes modals/menus
   
3. **Form Submission**:
   - All fields operable via keyboard
   - Form submits with Enter from any field or via dedicated button
   - No submission on focus/change alone

### Screen Reader Testing (1.1, 1.3, 3.2, 4.1)
**NVDA (Windows) + Chrome Testing**:
1. Open NVDA (free, open-source)
2. Navigate page with arrow keys and heading navigation (H key jumps to headings)
3. Verify:
   - Images have meaningful alt text (not redundant with caption)
   - Headings follow hierarchy, describe page sections
   - Form labels announced with inputs
   - List structure recognized (items announced as "1 of 5")
   - Buttons named correctly (not "button 1", but "Submit")
   - Status messages announced (role="status" captured)

**JAWS/VoiceOver for extended testing** (see accessibility-code skill for full testing protocol)

### Color Contrast Testing (1.4.3, 1.4.11)
1. Use WebAIM Contrast Checker or browser dev tools
2. For normal text: measure all instances, must be 4.5:1
3. For large text (18pt+ or 14pt bold+): measure all instances, must be 3:1
4. For UI components (buttons, focus indicators): measure, must be 3:1
5. Note: Background images reduce contrast; measure against actual background

### Visual Testing (1.3, 1.4)
1. **Zoom Test**: Set browser zoom to 200%, verify no horizontal scroll, all content readable
2. **Reflow Test**: Narrow viewport to 320px, verify single-column layout, no horizontal scroll at 400% zoom
3. **Focus Test**: All interactive elements have visible 2px+ focus indicator, 3:1 contrast
4. **Color Test**: Information not conveyed through color alone (e.g., form error uses icon + text, not red border only)

---

## Common Remediation Patterns

### Quick Wins (S effort, CRITICAL impact)
- Add alt text to images: `<img alt="description" src="...">` (decorative images: `alt=""`)
- Add page title: `<title>Page Title | Site Name</title>`
- Add lang attribute: `<html lang="en">`
- Add form labels: `<label for="input-id">Label</label>`
- Fix heading hierarchy: Ensure H1 exists, no skipped levels, semantic order matches visual
- Add skip link: Hidden visually, visible on :focus, links to #main
- Fix focus visible: `:focus-visible { outline: 3px solid color; }`
- Add form error text: `<span id="error-1">Email is invalid</span>` + `<input aria-describedby="error-1">`

### Medium Effort Patterns (M effort, CRITICAL/MAJOR impact)
- Implement keyboard navigation on custom component (tabs, menu, combobox) with arrow keys
- Add ARIA to custom component: role, aria-expanded, aria-selected, aria-controls
- Implement focus trap in modal (prevent Tab from escaping)
- Add status announcement: `<div role="status" aria-live="polite">Saved!</div>`
- Add captions to video: WebVTT file or platform-native captions
- Fix reflow: CSS media queries at 320px viewport, ensure single column, no horizontal scroll

### Large Effort Patterns (L effort, critical architecture changes)
- Refactor custom drag-and-drop for keyboard alternatives (arrow keys, form input)
- Add full video transcript and audio description track
- Restructure form flow for error prevention and recovery
- Implement authentication alternative to image recognition (passkey, password)

---

## Cross-References
- **full-accessibility-audit**: Use this criterion-level audit to deep-dive violations found in holistic audit
- **accessibility-audit**: Reference design patterns and visual measurements for 1.3, 1.4 criteria
- **accessibility-code**: Reference code implementation for 1.3.1 (semantic HTML), 2.1 (keyboard), 2.4.7 (focus), 4.1.2 (name/role/value)
- **wcag-checklist**: Use for development checklist; this skill provides detailed understanding
- **a11y-test-plan**: Use to develop comprehensive test plan for specific violations found

---

## Resources
- **WCAG 2.2 Specification**: https://www.w3.org/WAI/WCAG22/quickref/
- **ARIA Authoring Practices Guide**: https://www.w3.org/WAI/ARIA/apg/
- **WebAIM Articles**: Color contrast, forms, headings, etc.
- **Deque University**: Video training on WCAG criteria
- **Accessibility Insights**: Automated testing tools (some criteria)
- **Manual Testing Tools**: NVDA (free), JAWS (expensive), VoiceOver (macOS), TalkBack (Android)
