---
name: design-handoff
description: Generate a comprehensive design handoff document from a vibe-coded prototype. Use this skill whenever the user has finished building or iterating on a prototype (HTML, React, or any front-end code) and is ready to hand it off to developers, stakeholders, or both. Trigger whenever the user says things like "handoff", "hand off", "ready to ship", "prepare for dev", "document this prototype", "wrap this up for the team", "create handoff docs", or indicates they're done building and need to communicate what they built and why. Also trigger when the user wants to demonstrate the business value of their design work, or needs to package a prototype with specs, accessibility notes, and effort metrics.
category: handoff
related-skills: accessibility-annotations, accessibility-code, design-system-drift, design-review-cowork
---

# Design Handoff Skill

Generate a professional, comprehensive handoff document that bridges the gap between a vibe-coded prototype and the people who need to understand it — both the developers who'll build it and the stakeholders who need to see the value.

## Why This Skill Exists

Vibe coding produces working prototypes fast, but the knowledge of *why* things were designed the way they were lives in the builder's head and the git history. This skill extracts that knowledge, combines it with code analysis, and packages it into a single document that demonstrates business value up top and provides implementation specs below. It's designed to make a fractional design leader's work legible, defensible, and actionable.

The handoff demonstrates that design is not decoration — it's a strategic, measurable practice grounded in user insight, accessibility standards, and business outcomes.

---

## The Audit-Fix-Handoff Workflow

This skill doesn't just document — it actively improves the prototype before generating the handoff. The workflow is:

1. **Audit** — run a comprehensive design review (accessibility, UX, code quality)
2. **Fix** — apply all fixable issues directly to the prototype code
3. **Handoff** — generate the document, which now presents the *cleaned-up* prototype

The handoff is not a bug report. It's a certificate of completeness. Stakeholders should read it and think "this was built with care." Developers should read it and think "this is ready to implement."

**This skill always ensures an audit + fix pass happens before generating the handoff.** Here's the decision tree:

1. Check if a design review has already been run (look for review files, conversation history)
2. If a review exists → read its findings, apply any outstanding fixes to the prototype, then proceed
3. If no review exists → **run the `design-review-cowork` skill first**, then apply fixes from its findings, then proceed with the handoff

After the review, iterate through the findings and fix everything that can be fixed in the code: contrast issues (update colors), missing ARIA labels (add them), semantic HTML gaps (fix the markup), missing focus styles (add CSS), missing prefers-reduced-motion (add the media query). Tell the user what you're fixing as you go. The handoff document then reflects the *fixed* state — all those checks show as Passed because they actually are.

---

## What It Produces

A single, visually polished **HTML document** saved next to the prototype. This is not a plain text report — it's a designed artifact that reflects the same care as the prototype itself. It includes:

1. **Executive Summary** — what was built, for whom, and the key design thesis
2. **Business Value & Effort Metrics** — commits, files changed, timeline, iteration story — with a **Chart.js bar/line chart** visualizing commit activity over time
3. **Quality Assurance & Compliance** — WCAG audit results, performance scores, responsive testing, browser compatibility, color vision simulation, i18n readiness, design system readiness score — with **visual gauges, progress rings, and status badges**
4. **Accessibility & Inclusive Design** — comprehensive accessibility annotation extracted from the prototype, cross-referenced with `accessibility-annotations` skill
5. **Component API Documentation** — for each component: props, variants, states, accessibility requirements, keyboard interaction
6. **Responsive Behavior Documentation** — breakpoints, layout changes, content priority shifts, touch target validation
7. **Performance Budget Documentation** — target metrics, critical rendering path, bundle size, asset optimization
8. **Design Tokens & System** — extracted colors, typography, spacing, with **rendered color swatches**
9. **Storybook & Chromatic Inventory** — catalog of existing stories and visual testing config in the repo
10. **Strategic Recommendations** — what's next, future opportunities, product vision alignment

### Visual Design Principles for the Handoff

The HTML document should look like it came from a design consultancy, not a code linter. Follow these principles:

- **Clean, modern typography** — Use Inter (from Google Fonts) as the primary font. Large section headers, generous line-height, readable body text.
- **Professional color palette** — Use a neutral base (slate/gray) with a single accent color (extracted from the prototype's primary color if possible, otherwise a refined blue). Avoid rainbow colors.
- **Visual data representation** — Never just show a number when you can show a gauge, progress bar, or chart. Scores get donut charts. Pass/fail gets styled badges. Timelines get bar charts.
- **Color swatches** — Design tokens should show actual rendered color squares next to hex values and contrast ratios.
- **White space** — Generous padding, clear section separation with subtle dividers, card-based layout for component inventory.
- **Responsive** — The handoff document itself should be responsive (it's a web page, after all).
- **Print-friendly** — Include a `@media print` stylesheet so it looks great when exported to PDF.
- **Self-contained** — Everything in a single HTML file. CSS is embedded in `<style>` tags. Charts use Chart.js loaded from CDN. No other external dependencies except Google Fonts.

---

## Core Framework

### Step 1: Find the Prototype

Auto-detect prototype files in the working directory. Look for `.html` and `.jsx` files, prioritizing the most recently modified. If multiple candidates exist, pick the one that looks like the main prototype (largest file, most recently touched, or in a likely location like `src/`, `components/`, or the root).

If no prototype files are found, check the outputs directory as well. If still nothing, ask the user to point you to it.

### Step 2: Run Audit & Apply Fixes

**Check if a review already exists:**
- Look for review files (e.g., `review.md`, `audit.json`)
- Check conversation history for prior review

**If a review exists:**
- Read and parse the findings
- Apply all fixable issues to the prototype code

**If no review exists:**
- Run the `design-review-cowork` skill on the prototype
- Parse the output findings
- Apply all fixable issues to the prototype code

**Fixable issues include:**
- Color contrast failures → update color values in CSS/styles
- Missing ARIA labels → add aria-label, aria-describedby, role attributes
- Missing landmark roles → wrap content in semantic elements (nav, main, aside, footer)
- No skip-to-content link → add one
- Missing focus indicators → add :focus-visible styles
- No prefers-reduced-motion → add media query to disable/reduce animations
- Missing form labels → add label elements or aria-label
- Touch targets too small → increase padding/size
- Missing alt text → add descriptive alt attributes
- Semantic HTML gaps → fix markup
- Missing heading hierarchy → ensure proper h1 → h2 → h3 progression

Tell the user what you're fixing as you go: "Fixing 7 issues from the design review: updating contrast on secondary text, adding ARIA labels to nav links, adding skip-to-content link..."

After fixes are applied, the prototype is in its best state. The handoff documents *this* version.

### Step 3: Generate Accessibility Annotations

Use the `accessibility-annotations` skill to generate comprehensive accessibility annotation content for the handoff. This should include:

- Screen reader annotations (aria-labels, roles, descriptions)
- Keyboard interaction patterns (tab order, focus management, keyboard shortcuts)
- Motion and animation annotations (prefers-reduced-motion handling)
- Color contrast requirements
- Touch target sizes
- Status and alert announcements
- Form label strategies
- Complex widget patterns (modals, dropdowns, carousels, tables)

Cross-reference this with the `accessibility-code` skill for code-specific implementation guidance.

### Step 4: Extract Component API Documentation

For each distinct UI component or pattern in the prototype, document:

**Component Name & Description**
What is this component? What is its purpose?

**Props / Configuration Options**
For each prop:
- Name (camelCase)
- Type (string, number, boolean, enum, object, JSX.Element, function)
- Default value
- Description
- Example usage

**Variants & States**
- List every distinct visual variant (primary, secondary, outline, ghost, etc.)
- List every state (default, hover, active, focused, disabled, loading, error, success)
- For each state, note any changes to colors, opacity, cursor, feedback, etc.

**Accessibility Requirements**
- Required ARIA attributes (aria-label, aria-describedby, role, etc.)
- Keyboard interaction (Tab, Enter, Space, Arrow keys, Escape)
- Required focus indicator styling
- Alert/status updates that need aria-live
- Form association requirements (label id matching input for, etc.)

**Usage Examples**
Provide 2–3 code snippets showing common usage patterns:
```jsx
<Button variant="primary" onClick={handleClick}>
  Click me
</Button>

<Button variant="secondary" disabled>
  Disabled state
</Button>

<Button isLoading aria-busy="true">
  Loading...
</Button>
```

### Step 5: Document Responsive Behavior

For each breakpoint in the design (mobile, tablet, desktop, large desktop):

**Breakpoint Definition**
- Exact pixel ranges (e.g., 375px–767px for mobile)
- Common device names (iPhone 14, iPad Air, MacBook Pro)

**Layout Changes**
- How does the layout shift? (single-column → multi-column, sidebar collapse, etc.)
- Which elements stack, hide, or reorder?
- Grid/flex changes?

**Content Priority Shifts**
- What content is hidden or de-emphasized at smaller viewports?
- Are images substituted with lower-res versions for mobile?
- Does text abbreviate?

**Touch vs. Mouse Behavior**
- Are hover states replaced with tap/long-press on mobile?
- Do touch targets expand to 44×44px minimum?
- Are interactive elements repositioned for thumb access?

**Navigation & Interaction Changes**
- Does navigation shift to hamburger menu?
- Are buttons reorganized?
- Are modals replaced with full-screen overlays?

**Example Structure:**
```
## Mobile (375px—767px)
- Single-column layout
- Sidebar collapses to off-canvas drawer
- Touch targets expand to 48×48px
- Hero image scales down, text remains readable
- Form fields stack vertically
```

### Step 6: Document Performance Budget

Define target metrics for the prototype and assess current performance:

**Target Metrics**
- **Largest Contentful Paint (LCP)**: [target] ms (aim for <2.5s)
- **Cumulative Layout Shift (CLS)**: [target] (aim for <0.1)
- **First Input Delay (FID)** or **Interaction to Next Paint (INP)**: [target] ms (aim for <100ms)
- **Total Page Weight**: [target] KB (aim for <150KB for landing pages)
- **Critical Rendering Path**: [description of render-blocking resources]
- **Bundle Size**: [total JS, CSS, fonts, images]

**Assessment**
- Estimated LCP based on asset sizes and render-blocking resources
- CLS risk assessment based on layout shift potential
- Bundle size breakdown by category
- Render-blocking resources (critical CSS, defer JS opportunities)
- Image optimization opportunities (lazy loading, modern formats like WebP)
- Font optimization (font-display strategy, variable fonts, subsetting)

**Recommendations**
- Specific optimizations to meet performance targets
- Asset optimization opportunities
- Caching and CDN strategies
- Code splitting opportunities

### Step 7: Gather Context from the User

Ask a few quick questions to fill in what can't be inferred from code alone:

- **Project name** — what should this handoff be titled?
- **Key design decisions** — any major trade-offs or design thesis (or "I'll let you infer from the code")
- **Target audience context** — who are the end users of the product being prototyped?
- **Success metrics** — what does success look like for this design? (conversions, retention, engagement, accessibility compliance, etc.)

Keep it lightweight. Do NOT ask about hours spent or time invested — this can conflict with the designer's invoicing.

### Step 8: Analyze the Prototype Code

Read the (now fixed) prototype file(s) and extract:

**Design Tokens**
- Colors (hex values, RGB, CSS custom properties) — group by semantic role (primary, secondary, background, text, accent, error, success, warning)
- Typography (font families, sizes, weights, line heights, letter-spacing)
- Spacing values (margins, padding, gaps — identify the spacing scale if one exists)
- Border radii, shadows, transitions, and other visual properties
- Breakpoints / responsive behavior

**Component Inventory**
- List every distinct UI component or pattern (buttons, cards, forms, modals, navigation, etc.)
- Note props/variants for each
- Flag any repeated patterns that could be consolidated
- Note any third-party libraries or frameworks used

**Interaction Patterns**
- Hover/focus/active states
- Animations and transitions
- Form validation behavior
- Loading/error/empty states
- Navigation patterns
- Gesture interactions (swipe, long-press, pinch)

**Storybook & Chromatic Inventory**
- Check if the project has a `.storybook/` directory, `storybook` in package.json, or existing `*.stories.*` files
- If stories exist, catalog them: which components have stories, how many variants, what states are covered
- Check for Chromatic config (`.chromatic` dir, `chromatic` in package.json, CI workflows)
- If no Storybook/Chromatic exists, note that and recommend setup

### Step 9: Pull Git Metrics

Run git commands to extract effort data from the repository history.

```bash
# Total commits
git log --oneline | wc -l

# Commit timeline
git log --format="%ai" --reverse | head -1
git log --format="%ai" -1

# Files changed
git diff --stat $(git rev-list --max-parents=0 HEAD)..HEAD

# Lines added/removed
git log --numstat --pretty="" | awk '{add+=$1; del+=$2} END {print "Added:", add, "Removed:", del}'

# Commit frequency
git log --format="%ad" --date=short | sort | uniq -c | sort -rn
```

If there's no git history, note this and move on.

### Step 10: Run Performance & Compatibility Checks

**Lighthouse / Core Web Vitals:**
If the prototype is HTML and can be served locally, try to run Lighthouse or estimate performance characteristics from the code:
- Estimated LCP based on asset sizes and render-blocking resources
- CLS risk assessment based on layout shift potential
- Total page weight
- Render-blocking resources

If you can't run Lighthouse directly, do a static analysis of the code.

**Browser Compatibility:**
Analyze CSS and JS features used and map to browser support:
- Check for use of CSS Grid, Flexbox, custom properties, :has(), :is(), container queries
- Check for JS features that may need polyfills
- Produce a compatibility matrix for major browsers

**Color Vision Simulation:**
Analyze the color palette for accessibility under color vision deficiencies:
- Protanopia (red-blind)
- Deuteranopia (green-blind)
- Tritanopia (blue-blind)
- Achromatopsia (full color blindness)
- Report whether UI remains usable and distinguishable under each condition

**Internationalization Readiness:**
Assess how well the prototype would handle:
- Long text / translations (German, Finnish words are ~30% longer)
- RTL text direction (Arabic, Hebrew)
- CJK characters (different line-height needs)
- Hardcoded widths or truncation risks

### Step 11: Take Screenshots

Use available screenshot/rendering tools to capture the prototype visually at multiple breakpoints:
- Desktop (1024px or larger)
- Tablet (768px)
- Mobile (375px)
- Zoomed view (200%) for accessibility testing
- Dark mode (if supported)

Don't let screenshot generation block the handoff.

### Step 12: Assemble the Handoff Document

Write a **single, self-contained HTML file** with embedded CSS and JavaScript. The document must be visually polished — it represents the designer's brand.

**External resources (loaded from CDN):**
- Google Fonts: Inter (weights 400, 500, 600, 700)
- Chart.js 4.4.1: `https://cdnjs.cloudflare.com/ajax/libs/Chart.js/4.4.1/chart.umd.min.js`

**No other external dependencies.**

[HTML Template Structure — same as original, enhanced with new sections for Component API, Responsive Behavior, Performance Budget, and Accessibility Annotations]

Key visual elements that MUST be present:

1. **Metric cards** — Large numbers for business metrics (commits, files, lines, timeline)
2. **Commit activity bar chart** — Chart.js showing commits per day from git log
3. **Pass/fail badges** — Green pills with checkmarks for WCAG, responsive, browser compatibility
4. **Inclusive design checklist** — Styled checkmark list for accessibility measures
5. **Performance metric cards** — Page weight, LCP, CLS, etc.
6. **Design system readiness gauge** — SVG donut/ring chart showing X/10 score
7. **Color swatches** — Rendered colored squares with hex, contrast ratios, usage
8. **Typography preview** — Render "Aa" at each font size/weight
9. **Spacing scale bars** — Horizontal bars visualizing spacing system
10. **Component cards** — Card-based grid with variants and accessibility info
11. **Component API tables** — Props, states, accessibility requirements, code examples
12. **Responsive breakpoint tables** — Layout and content changes per viewport
13. **Performance budget tracker** — Target metrics vs. current state

**Adapting the accent color:** Extract the prototype's primary/brand color and use as `--color-accent`.

### Step 13: Save the Document

Save the handoff as `[project-name]-handoff.html` in the same directory as the prototype. Also copy to outputs directory.

Tell the user where the file is and provide a link.

---

## Important Notes

- **Output format is HTML, not markdown.** The handoff is a single `.html` file with embedded CSS and JS. It must be visually polished.
- The document should stand on its own — someone reading it without context should understand what was built, why, and how to proceed.
- Business value comes first because that's what justifies the work. Specs are essential but secondary.
- The Quality Assurance section is proof of completeness, not a bug report. Every check should read as Passed because you *fixed the issues first*.
- When extracting design tokens, be practical — if code uses one-off values, note that and suggest a token system.
- Git metrics tell a story about process and rigor. A prototype with 47 commits over 3 days shows iteration and care. Narrate that visually with a Chart.js bar chart.
- The Storybook section inventories what exists, not generates new stories.
- Do NOT ask about or include hours spent or time invested. This can conflict with invoicing.
- Always output a **single HTML file**. All CSS in `<style>` tags. All JS in `<script>` tags.
- The Strategic Recommendations section positions the designer as strategic thinker, not just executor.
- **Color swatches must actually render** — use inline `background` styles.
- **The gauge must actually render** — calculate SVG `stroke-dasharray` from score.
- **The chart must actually work** — populate Chart.js with real git data.
- Cross-reference `accessibility-annotations` for comprehensive annotation content.
- Cross-reference `accessibility-code` for code-specific implementation guidance.
- Use `design-system-drift` to identify and document tokens and components ready for systemization.

---

## Cross-References

This skill pairs with:

- **accessibility-annotations**: Extract comprehensive annotation content for handoff accessibility section
- **accessibility-code**: Code-specific accessibility implementation guidance; validate fixes
- **design-system-drift**: Identify which tokens/components are ready to be systemized
- **design-review-cowork**: Run comprehensive review before handoff (audit step)

---

## Grounded In

The design handoff is built for fractional design leaders who value:

- **Business value first**: Metrics and effort visualization demonstrate the value of design work
- **Strategic thinking**: Recommendations section positions design as driver of product direction
- **Accessibility & equity**: Comprehensive accessibility audit built into the workflow
- **Sustainable practice**: Emphasis on design systems, token extraction, and pattern reusability
- **Professional presentation**: Handoff document itself demonstrates design craftsmanship
- **Developer respect**: Clear specs, component API docs, responsive behavior guidelines make implementation straightforward

The handoff demonstrates that design is not decoration — it's a strategic, measurable practice grounded in user insight, accessibility standards, and business outcomes.
