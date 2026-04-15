---
name: design-review-cowork
description: Comprehensive prototype review from multiple expert perspectives with scoring, Ship/No Ship recommendation, accessibility depth, performance metrics, and business impact analysis. Use this skill whenever you have a prototype (HTML, React, screenshot, or code) and need critical feedback from Senior UX Designer, Accessibility Specialist, Frontend Engineer, Performance Reviewer, and Design Critic. Generates detailed report with Prototype Readiness Score and actionable fix instructions.
category: audit
related-skills: full-accessibility-audit, accessibility-code, design-handoff, design-system-drift
---

# Design Review Cowork Skill

A comprehensive multi-perspective prototype analysis system that coordinates six specialized expert reviewers to evaluate your work and produce a unified report with executable fix instructions, a readiness score, and clear Ship/No Ship recommendation.

---

## Philosophy

Expert design review is not one voice—it's a synthesis of disciplines. A prototype can be perfectly accessible but unmaintainable; it can perform well but miss the market opportunity; it can be beautifully designed but confuse users. This skill orchestrates six specialized reviewers (UX Designer, Accessibility Specialist, Frontend Engineer, Performance Reviewer, Design Critic, Business Strategist) to evaluate your work across all these dimensions simultaneously, then weights their findings into a single **Prototype Readiness Score** (0-100) with clear **Ship/No Ship guidance**.

Each reviewer scores their domain independently (0-10), then an overall readiness score synthesizes all domains with context-specific weighting:
- Accessibility carries a floor: a prototype cannot ship with WCAG failures regardless of other scores
- Performance carries escalating weight at scale
- Business impact is weighted against project stage (MVP vs. mature product)
- UX/Design alignment gates feature complexity

The goal is not perfection—it's informed decision-making. The report shows you exactly what's blocking launch, what's debt to plan for later, and what's a nice-to-have optimization.

---

## Core Framework

### Six Reviewer Perspectives

**1. Senior UX Designer (Weight: 20%)**
- Evaluates user flows, task completion paths, information architecture
- Assesses visual hierarchy, consistency, component patterns
- Identifies cognitive load, mental model alignment
- Scores 0-10 on usability, consistency, delight

**2. Accessibility Specialist (Weight: 30%)**
- Audits WCAG 2.1 Level AA compliance (WCAG 2.2 where applicable)
- Tests keyboard navigation, screen reader compatibility, focus management
- Checks color contrast, motion sensitivity, form accessibility
- Flags ARIA misuse, semantic HTML violations, landmark structure gaps
- Scores 0-10 with hard floor: any WCAG AA failure = score caps at 3
- References specific WCAG criteria by number (e.g., 1.4.3 Contrast, 2.1.1 Keyboard, 4.1.2 Name Role Value)

**3. Frontend Engineer (Weight: 25%)**
- Reviews code architecture, component reusability, state management
- Checks render performance, bundle size, browser compatibility
- Evaluates TypeScript safety, testing coverage, maintainability
- Identifies technical debt and refactoring opportunities
- Scores 0-10 on code quality, performance, maintainability

**4. Performance Reviewer (Weight: 15%)**
- Measures Core Web Vitals (LCP, INP, CLS)
- Analyzes bundle size, code splitting, rendering efficiency
- Evaluates image optimization, network waterfall, caching strategy
- Assesses user-perceived performance (loading states, optimistic updates)
- Scores 0-10 with context on scale (mobile vs. desktop, 3G vs. 5G)
- Provides baseline/target metrics (e.g., "LCP: 4.2s → target 2.5s")

**5. Design Critic (Weight: 5%)**
- Challenges design decisions, surfaces brand/market alignment
- Identifies missed opportunities for delight or differentiation
- Flags future-proofing concerns, scalability risks
- Questions patterns that may create maintenance debt
- Scores 0-10 on strategic alignment and future-readiness

**6. Business Strategist (Weight: 5%)**
- Assesses alignment with business model, revenue impact
- Evaluates user acquisition, conversion, retention implications
- Considers competitive positioning, platform strategy
- Flags risks (churn, support cost, scaling pain)
- Quantifies impact where possible ("This could improve completion 40% → 65%")

### Prototype Readiness Score (0-100)

Calculated as: `(UX × 0.20) + (A11y × 0.30) + (FE × 0.25) + (Perf × 0.15) + (Critic × 0.05) + (Strategy × 0.05)`

**Special rules:**
- If Accessibility score ≤ 3 (WCAG AA failure), Readiness Score caps at 45 (cannot ship)
- If Readiness Score < 50, recommendation is **No Ship** (fix critical issues first)
- If 50-75, recommendation is **Ship with caveats** (address critical items, plan debt)
- If 75-90, recommendation is **Ship** (monitor performance, plan optimizations)
- If 90+, recommendation is **Ship confidently** (address nice-to-haves in next sprint)

### Severity Model (Weighted to Business Impact)

Each finding has a severity tier AND an estimated business impact:

- **CRITICAL** (Red): Blocks launch OR causes user/revenue harm (accessibility failure, security issue, data loss, legal risk)
  - Example: "Missing alt text on product images → SEO ranking loss → 15-20% traffic decline"

- **MAJOR** (Orange): Significant UX, performance, or maintenance impact, but not a blocker
  - Example: "Inconsistent button styles → 4 hours/week support cost, poor brand perception"

- **MINOR** (Yellow): Optimization opportunity, nice-to-have improvement
  - Example: "Loading state could be animated → 5% perceived performance improvement"

---

## Process

### Step 1: Provide Prototype & Context

Share your prototype in one of these formats:
- React/Vue/Svelte component (full code)
- HTML + CSS + JS artifact
- Screenshot or Figma export
- Live URL (if publicly accessible)

Include context:
```
Prototype: [code/screenshot/URL]
Goal: [What problem does this solve?]
Audience: [Who uses this? (developers, non-technical users, etc.)]
Success criteria: [How will you measure success?]
Stage: [MVP/beta/mature product]
Constraints: [Browser support, accessibility target (A/AA/AAA), performance targets]
Timeline: [When does this need to ship?]
```

### Step 2: Spawn Parallel Review Agents

The skill initiates six concurrent reviewers:
1. Each independently reviews the prototype against their domain criteria
2. Each produces a domain-specific score (0-10) with detailed findings
3. Each flags critical issues requiring fixes with effort estimates

### Step 3: Synthesize into Unified Report

The Orchestrator agent:
1. De-duplicates findings (e.g., "button color" flagged by both UX and A11y)
2. Maps findings to specific code locations (file, line, component)
3. Assigns business impact assessment to each finding
4. Calculates Prototype Readiness Score
5. Generates Ship/No Ship recommendation with rationale

### Step 4: Present Report & Get Approval

Report layout:
- Executive summary (overall readiness, Ship/No Ship, key risks)
- Prototype Readiness Score breakdown by reviewer
- Detailed findings table (organized by file, then severity)
- Unified fix instructions (priority-ordered, with effort estimates)
- Testing checklist before/after validation

Ask explicitly: *"Ready to proceed with fixes? Which items would you like to skip, if any?"*

### Step 5: Execute Fixes (With Approval)

For each approved fix:
1. Show exact code location and current state
2. Show the corrected version with explanation
3. Apply the fix
4. Run validation step
5. Move to next fix

### Step 6: Re-validate & Re-score

After fixes:
1. Run abbreviated re-scan against critical/major findings
2. Recalculate Prototype Readiness Score
3. Confirm Ship/No Ship recommendation holds

---

## Reference Guide

### UX Designer Criteria

**Flow & Task Completion**
- Are the main user tasks discoverable and completable?
- Is the cognitive load reasonable (information chunking, step count)?
- Are there unexpected dead ends or missing states?
- Do error states provide recovery paths?

**Visual Hierarchy**
- Is the primary action obvious?
- Do secondary actions have appropriate visual weight?
- Is spacing/contrast used to create hierarchy?
- Does typography establish information importance?

**Consistency**
- Are component patterns used consistently (buttons, inputs, modals)?
- Do similar actions have similar interaction patterns?
- Is the design system applied consistently?
- Are brand values reflected in visual decisions?

**Micro-interactions**
- Do loading states provide feedback?
- Are success/error states clear?
- Do transitions aid comprehension or just distract?
- Are state changes obvious?

**Issues found → Effort estimates:**
- Flow redesign: L (1-2 days)
- Hierarchy refinement: M (2-4 hours)
- Component consolidation: M (4-8 hours)
- Micro-interaction additions: S-M (1-4 hours)

---

### Accessibility Specialist Criteria (WCAG 2.1 / 2.2 AA)

**Critical Failures (WCAG 2.1 AA)**

1. **1.4.3 Contrast (Minimum)** — Text/graphics must have 4.5:1 ratio (3:1 for large text)
   - Check: foreground color, background color, computed contrast
   - Tool: WebAIM Contrast Checker
   - Fix example: Change `color: #777` to `color: #333`

2. **1.3.1 Info and Relationships** — Semantic structure is conveyed
   - Check: Heading hierarchy (h1 → h2 → h3, no skips), form label associations, list markup
   - Fix example: Add `<label for="email">Email</label>` instead of placeholder-only input

3. **2.1.1 Keyboard** — All functionality accessible via keyboard
   - Check: Tab order, enter to submit, escape to close, arrow keys in autocomplete, skip links
   - Fix example: Add `onKeyDown={(e) => e.key === 'Enter' && handleSubmit()}`

4. **4.1.2 Name, Role, Value** — Form controls have accessible name, role, and state
   - Check: Input labels, button text, ARIA labels, aria-invalid for errors
   - Fix example: Add `aria-label="Close modal"` to icon buttons

5. **1.3.5 Identify Input Purpose (WCAG 2.1 AA new)** — Form inputs convey purpose (autocomplete attribute)
   - Check: `<input type="email" autocomplete="email">` for email, password for password, etc.
   - Fix example: Add `autocomplete="current-password"` to password inputs

6. **2.4.3 Focus Order** — Focus order is logical and visible
   - Check: Tab through page, focus indicator visible on all interactive elements, order matches visual flow
   - Fix example: Add `outline: 3px solid #4A90E2` for focus indicator

7. **2.4.4 Link Purpose** — Link purpose is clear from text alone
   - Check: No "click here" links; every link has descriptive text or aria-label
   - Fix example: Change `<a href="/about">Click here</a>` to `<a href="/about">About us</a>`

8. **1.4.1 Use of Color** — Color is not the only means of conveying information
   - Check: Error states show icon + text (not red border alone), status indicators use shape + color
   - Fix example: Add checkmark icon alongside green border for valid input

9. **2.5.1 Pointer Gestures (WCAG 2.1 AA)** — Multi-touch gestures have single-pointer alternative
   - Check: Pinch-to-zoom has + button, swipe has arrows, long-press has right-click menu
   - Fix example: Add chevron buttons alongside carousel for keyboard/mouse users

10. **2.4.7 Focus Visible** — Focus indicator is visible
    - Check: `:focus { outline: 3px solid }` exists for all interactive elements
    - Fix example: Add `:focus-visible { outline: 3px solid #0066cc }` to all buttons, links, inputs

**Major Issues (WCAG 2.1 AA)**

11. **3.3.1 Error Identification** — Errors are identified and described in text
    - Check: Form errors announce to screen readers, error messages are specific (not "Invalid")
    - Fix example: Add `<span id="email-error" role="alert">Email must be valid</span>`

12. **3.3.3 Error Suggestion** — Suggestions are provided for errors
    - Check: Invalid date shows correct format, typos offer corrections
    - Fix example: Add `aria-describedby="format-hint"` to field

13. **2.4.2 Page Titled** — Page has a descriptive title
    - Check: `<title>` is present and descriptive (not just "Home")
    - Fix example: Change `<title>Home</title>` to `<title>Dashboard - Project Management App</title>`

14. **2.4.1 Bypass Blocks** — Skip links are present and functional
    - Check: Skip to main content link is visible on focus, working links exist
    - Fix example: Add `<a href="#main" style="position: absolute; top: -9999px;">Skip to main</a>`

15. **1.3.2 Meaningful Sequence** — Content sequence is meaningful when linearized
    - Check: CSS order (flexbox order, position: absolute) doesn't break reading order
    - Fix example: Ensure DOM order matches visual order, avoid CSS reordering

16. **3.2.3 Consistent Navigation** — Navigation mechanisms are consistent
    - Check: Menu location, button styles, link underlines consistent across pages
    - Fix example: Standardize button styles across all pages

17. **3.2.4 Consistent Identification** — Components with same function are identified consistently
    - Check: Search button has same label/icon everywhere, back button looks same across app
    - Fix example: Use single Button component library with consistent styling

18. **3.3.4 Error Prevention** — Steps taken to prevent errors (confirm before submit, undo, review)
    - Check: High-risk actions (delete, payment) require confirmation
    - Fix example: Add confirmation modal before delete

19. **2.1.3 Keyboard (No Exception)** — All keyboard-trap prevention
    - Check: Modal can be closed with Escape, focus doesn't get stuck
    - Fix example: Add `onKeyDown={(e) => e.key === 'Escape' && handleClose()}`

**Accessibility Scoring Rules:**
- Any Level AA failure (1-10 above) → score ≤ 3 (cannot ship)
- 5+ issues → score 4-5 (major work needed)
- 3-4 issues → score 6-7 (fixable before launch)
- 1-2 issues → score 8-9 (minor issues)
- 0 issues → score 10 (full compliance)

**Issues found → Effort estimates:**
- Contrast fix (single instance): S (15 min)
- Contrast fix (widespread): M (1-2 hours)
- Add ARIA labels: S (15-30 min per component)
- Keyboard navigation implementation: M-L (2-8 hours depending on complexity)
- Focus management in modal: M (2-4 hours)
- Screen reader testing & fixes: M-L (4-8 hours)

---

### Frontend Engineer Criteria

**Architecture & Reusability**
- Is state management clear (props vs. local state vs. global)?
- Are components at the right size (not too large/small)?
- Is there prop drilling suggesting a refactor (useContext, state machine)?
- Are components reusable or one-off?

**Performance**
- Are there unnecessary re-renders (missing memoization, dependency issues)?
- Is bundle size tracked (should be < 100kb gzip for app shell)?
- Are images optimized (next/image, srcset, lazy loading)?
- Are async operations debounced/throttled?

**Quality & Maintainability**
- Is TypeScript used effectively (strict mode, no `any`)?
- Is the code DRY (don't repeat yourself)?
- Are edge cases handled?
- Are error boundaries present?

**Testing**
- Is component logic tested?
- Are happy-path and error cases covered?
- Are accessibility patterns tested?

**Issues found → Effort estimates:**
- Variable naming/formatting: S (30 min)
- Extract component: M (2-4 hours)
- Add memoization: S-M (30 min - 1 hour)
- Refactor state management: L (1-2 days)
- Add error boundary: M (2-4 hours)
- Add tests: M-L (4-8 hours)

---

### Performance Reviewer Criteria

**Core Web Vitals (CWV)**

1. **LCP (Largest Contentful Paint)** — Time to render largest visible element
   - Target: < 2.5s (good), 2.5-4s (needs work), > 4s (poor)
   - Check: Image optimization, server response time, render-blocking resources
   - Fix: Prioritize critical images, defer non-critical scripts, enable compression

2. **INP (Interaction to Next Paint)** — Delay from user interaction to next visual update
   - Target: < 200ms (good), 200-500ms (needs work), > 500ms (poor)
   - Check: Event handler performance, useCallback usage, batch state updates
   - Fix: Debounce handlers, move heavy work off main thread (Web Worker), optimize event listeners

3. **CLS (Cumulative Layout Shift)** — Visual stability; how much does layout shift during load?
   - Target: < 0.1 (good), 0.1-0.25 (needs work), > 0.25 (poor)
   - Check: Image/video dimensions, ad/embed reserved space, font loading strategy
   - Fix: Add dimensions to images/videos, use font-display: swap, reserve space for dynamic content

**Bundle Size**
- App shell (HTML + JS + CSS): target < 100kb gzip
- Per-route chunk: target < 50kb gzip
- Check: Are dependencies necessary? Can code be split?

**Images**
- Are responsive images used (srcset, sizes)?
- Are modern formats used (WebP with JPEG fallback)?
- Is lazy loading enabled for below-fold images?
- Are images appropriately sized (not 4000px served as 200px)?

**Rendering**
- Are long tasks breaking the 50ms frame budget?
- Is JavaScript responsible for layout thrashing?
- Are animations GPU-accelerated?

**Issues found → Effort estimates:**
- Image optimization: S-M (30 min - 2 hours)
- Code splitting: M-L (4-8 hours)
- Debounce/throttle handlers: S-M (1-2 hours)
- Font loading strategy: S (30 min)
- Web Vitals monitoring setup: M (2-4 hours)

---

### Design Critic Criteria

**Strategic Alignment**
- Does the design reflect brand values?
- Is it differentiated from competitors or just another "standard" design?
- Does it position the product correctly in the market?

**Opportunity Areas**
- Where could design delight users without adding complexity?
- Are there missed moments for brand reinforcement?
- Could micro-interactions improve perceived performance?

**Risk Areas**
- Does this design scale to 10x users without rework?
- Are there maintenance pain points (brittle CSS, hard to modify)?
- Will this be hard to extend next quarter?

**Future-Proofing**
- Is the design system leveraged or working around it?
- Are decisions self-documenting or will future developers struggle?
- Are accessibility concerns built-in or bolted-on?

**Issues found → Effort estimates:**
- Strategic repositioning: L (2+ days research + design)
- Delight micro-interactions: M-L (4-16 hours)
- Maintenance refactor: L (1-2 days)
- Documentation/future-proofing: M (4-8 hours)

---

## Output Format

```
# Prototype Review Report: [Project Name]

## Executive Summary

**Prototype Readiness Score: [X/100]**

**Recommendation: [SHIP / SHIP WITH CAVEATS / NO SHIP]**

**Rationale:** [2-3 sentence summary of the recommendation and key decision drivers]

---

## Reviewer Scores Breakdown

| Reviewer | Score | Status |
|----------|-------|--------|
| UX Designer | [X]/10 | [✅ Green / ⚠️ Amber / 🔴 Red] |
| Accessibility Specialist | [X]/10 | [✅ Green / ⚠️ Amber / 🔴 Red] |
| Frontend Engineer | [X]/10 | [✅ Green / ⚠️ Amber / 🔴 Red] |
| Performance Reviewer | [X]/10 | [✅ Green / ⚠️ Amber / 🔴 Red] |
| Design Critic | [X]/10 | [✅ Green / ⚠️ Amber / 🔴 Red] |
| Business Strategist | [X]/10 | [✅ Green / ⚠️ Amber / 🔴 Red] |
| **Overall Readiness** | **[X]/100** | **[✅ SHIP / ⚠️ CAUTION / 🔴 HOLD]** |

---

## Critical Issues (MUST FIX BEFORE SHIPPING)

| File | Issue | Severity | Impact | Effort | Status |
|------|-------|----------|--------|--------|--------|
| [file] | [issue description] | CRITICAL | [Business impact] | [S/M/L] | [ ] Fix |

---

## Major Issues (PLAN FOR NEXT SPRINT)

| File | Issue | Severity | Impact | Effort | Status |
|------|-------|----------|--------|--------|--------|
| [file] | [issue description] | MAJOR | [Business impact] | [S/M/L] | [ ] Fix |

---

## Minor Issues (NICE-TO-HAVE)

| File | Issue | Severity | Impact | Effort | Status |
|------|-------|----------|--------|--------|--------|
| [file] | [issue description] | MINOR | [Optimization] | [S/M/L] | [ ] Fix |
```

---

## Cross-References

- full-accessibility-audit
- accessibility-code
- design-handoff
- design-system-drift
- keyboard-focus-auditor
- screen-reader-scripting
- motion-auditor
- wcag-checklist
