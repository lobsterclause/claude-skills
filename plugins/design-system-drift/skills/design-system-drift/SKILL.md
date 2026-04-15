---
name: design-system-drift
description: Scans a code repository and detects drift from the design system across token drift, component drift, pattern drift, accessibility drift, and Storybook drift. Produces a prioritized report with Drift Score (0-100), Drift Velocity trend analysis, severity-weighted findings, and applies fixes with human approval. Trigger on design system audits, hardcoded values, component drift, Storybook sync, or design consistency checks.
category: audit
related-skills: accessibility-code, design-handoff, design-review-cowork
---

# Design System Drift Detector

Scans a codebase for drift from the design system across five dimensions: token drift, component drift, design pattern drift, accessibility drift, and Storybook drift. Produces a prioritized report with Drift Score, Drift Velocity analysis, and applies fixes with human approval.

---

## Philosophy

A design system is a living contract between design and engineering. Drift happens organically as teams ship fast, take shortcuts, or haven't yet scaled to new use cases. The cost of drift is invisible at first—a few hardcoded colors, some components that diverge slightly—but compounds quickly:

- Maintenance cost (5+ different button implementations instead of one)
- Cognitive load on new team members (which button pattern do I use?)
- Accessibility regressions (components losing ARIA attributes)
- Performance degradation (design tokens not leveraged for optimization)
- Brand inconsistency (colors drift over time, spacing scales fragment)

This skill measures drift holistically: not just "how many hardcoded colors exist" but "is drift accelerating or decelerating?" (Drift Velocity), "which categories are most critical?" (severity weighting), and "how accessible is the drifted code?" (accessibility-specific checks).

Output: A Drift Score (0-100) where 0 = perfect system compliance and 100 = complete system abandonment. Findings are severity-weighted (CRITICAL token drift vs. MINOR documentation drift) and tied to business impact.

---

## Core Framework

### Drift Categories (Priority Order)

**1. Token Drift (CRITICAL severity)**
Hardcoded values that should reference design tokens.

Examples:
- `color: #2563eb` (should be `var(--color-primary-500)`)
- `padding: 16px` (should be `var(--spacing-md)`)
- `font-size: 24px` (should be `var(--font-size-lg)`)
- `border-radius: 8px` (should be `var(--radius-md)`)
- `box-shadow: 0 4px 6px rgba(0,0,0,0.1)` (should be `var(--shadow-md)`)

Detection patterns:
- CSS custom properties: Look for `var(--*)` usage in design tokens vs. hardcoded values
- Tailwind config: Compare `tailwind.config.js` tokens against hardcoded class values
- Style Dictionary: Scan against generated token files (JSON, CSS, JS)
- styled-components themes: Check theme object usage vs. hardcoded values
- SASS variables: Compare `$variable` usage vs. hardcoded values
- CSS-in-JS: Theme provider vs. hardcoded theme object literals

Scoring: Each hardcoded token value = 1 drift point. Widespread drift (100+ instances) = critical category.

**2. Component Drift (MAJOR severity)**
Components that have diverged from their design system spec (props, markup, behavior, styling).

Examples:
- Button component spec says "size: 'small' | 'medium' | 'large'" but implementation allows arbitrary padding
- Card component should use design tokens for spacing, but some instances use inline styles
- Form input missing ARIA labels or aria-invalid handling
- Modal component lost focus trap implementation
- Navigation bar diverged from design spec (wrong colors, spacing, hover states)

Detection patterns:
- Component API changes: Does component accept props matching design system spec?
- Storybook story args: Do stories document all available variants?
- Accessibility attributes: Check for ARIA labels, roles, aria-invalid, aria-describedby
- Styling: Are styles using design tokens or hardcoded values?
- Behavior: Does component implement required patterns (focus management, keyboard shortcuts)?

Scoring: Each component variant drift = 2 points. Critical behavior divergence (lost focus trap) = 5 points.

**3. Design Pattern Drift (MAJOR severity)**
UI patterns that violate design system conventions.

Examples:
- Spacing: Some sections use 16px gaps, others use 20px, design system specifies 16px
- Color: Form errors use both `#EF4444` and `#DC2626` (two shades of red)
- Typography: Headings use mix of font weights; design system specifies weight 600
- Buttons: Some have rounded corners (radius: 8px), others are sharp (radius: 0px)
- Forms: Validation patterns vary (some show inline errors, others show tooltips)

Detection patterns:
- CSS property values: Scan for color, font-size, font-weight, padding, margin, border-radius, gap consistency
- Class naming: Do classes follow design system naming conventions?
- Component usage: Are semantically correct components being used (h1 vs. h2, button vs. div)?

Scoring: Each pattern violation = 1 point. Pervasive inconsistency (50+ violations) = major category.

**4. Accessibility Drift (CRITICAL severity)**
Components losing accessibility features or semantic structure.

Examples:
- Button component lost `aria-label` support
- Form validation errors no longer announce to screen readers (missing `role="alert"`)
- Focus management broken in modal (focus doesn't move to dialog, doesn't return to trigger)
- Keyboard shortcuts removed (Enter to submit, Escape to close)
- Heading hierarchy broken (h1 → h3, skipping h2)
- Color-only status indicators (red = error, no icon or text fallback)
- Reduced motion support removed (animations still trigger even if `prefers-reduced-motion: reduce`)

Detection patterns:
- ARIA attributes: Check for missing aria-label, aria-labelledby, aria-describedby, aria-invalid, aria-live, aria-expanded
- Focus management: Test tab order, focus visible indicator, focus trap in modals/dialogs
- Semantic HTML: Verify heading hierarchy (no skips), form label associations, landmark roles
- Keyboard support: Test Enter, Escape, Arrow keys, Tab behavior
- Motion: Check for `prefers-reduced-motion` media query support

Scoring: Each accessibility regression = 3 points. Any WCAG AA failure = 10 points. Total accessibility drift caps readiness.

**5. Storybook Drift (MINOR severity)**
Storybook stories that don't match current component API or are missing variants.

Examples:
- Story still uses deprecated prop `onClick` but component now uses `onPress`
- Story examples show "large" size variant but component removed it
- Accessibility story missing (no a11y tab, no keyboard demo)
- Props documentation out of sync (story says "type: 'button'" but prop is "variant: 'primary'")
- Missing stories for new component features (e.g., disabled state added, story not updated)

Detection patterns:
- Story metadata: Compare story prop args against component propTypes or TypeScript interface
- Visual regression: Compare story screenshots against rendered component (if available)
- Coverage: Are all component variants documented in stories?
- A11y documentation: Are accessibility patterns documented in Storybook?

Scoring: Each missing/broken story = 0.5 points. Widespread API mismatch = 2 points per category.

---

### Drift Score (0-100)

Overall drift assessment combining all categories with severity weighting.

Calculation:
```
Drift Score = min(100, 
  (Token Drift Count × 2) +       // CRITICAL weight
  (Component Drift Count × 1.5) + // MAJOR weight
  (Pattern Drift Count × 1) +     // MAJOR weight
  (A11y Drift Count × 3) +        // CRITICAL weight
  (Storybook Drift Count × 0.5)   // MINOR weight
)
```

**Scoring ranges:**
- 0-15: Strong system compliance (excellent)
- 16-30: Minor drift, easily corrected (good)
- 31-50: Moderate drift, needs planning (fair)
- 51-75: Significant drift, immediate action needed (poor)
- 76-100: Severe drift, system breakdown (critical)

**Special rules:**
- Any WCAG AA accessibility failure: Drift Score floor of 50 (cannot ignore)
- Token drift > 200 hardcoded values: Drift Score floor of 60 (massive technical debt)
- Storybook completely out of sync (>20 stories mismatched): Add 15 points

---

### Drift Velocity (Trend Analysis)

Measures whether drift is accelerating or decelerating over time.

Mechanism:
- First scan establishes baseline Drift Score
- Subsequent scans (weekly, monthly) compare against baseline
- Velocity = (Current Score - Previous Score) / time elapsed

**Interpretation:**
- Velocity < -5 points/month: System improving (good, keep going)
- Velocity -5 to +5 points/month: Stable (acceptable if low absolute score)
- Velocity > +5 points/month: Drift accelerating (warning, increase compliance focus)

Example:
- Jan 1: Drift Score 30
- Feb 1: Drift Score 32
- Mar 1: Drift Score 35
- Velocity: +2.5 points/month (slow acceleration)
- Action: Slow acceleration is acceptable; if hits 50+, escalate enforcement

---

## Process

### Phase 1: Discover

**Goal:** Map the design system and understand the codebase structure.

Steps:
1. Locate the design token source:
   - CSS custom properties (`src/tokens/tokens.css`, `src/styles/variables.css`)
   - Tailwind config (`tailwind.config.js`)
   - Style Dictionary (`tokens.json`, `design-tokens/`)
   - Styled-components theme (`src/theme.ts`, `theme.js`)
   - SASS variables (`src/variables.scss`, `_variables.scss`)
   - Token file patterns (`src/styles/tokens/`, `packages/tokens/`)

2. Locate the component library:
   - Component directory (`src/components`, `packages/components`)
   - Component index/barrel exports
   - Storybook stories directory (`src/stories`, `.storybook`)
   - Component documentation

3. Identify the framework and styling approach:
   - React, Vue, Svelte, Angular, etc.
   - CSS Modules, styled-components, Emotion, Tailwind, SASS, plain CSS
   - CSS-in-JS library if applicable
   - Build system (Vite, Webpack, Rollup)

4. Confirm scope:
   - Which directories to scan? (usually `src/`, exclude `node_modules/`, `.next/`, `dist/`)
   - Which files to check? (`.tsx`, `.jsx`, `.ts`, `.js`, `.css`, `.scss`)
   - Are there monorepo packages to scan separately?

**Do not begin scanning until you have confirmed:**
- Token source location and format
- Component library location
- Framework and styling approach
- Scope boundaries (which directories, file types)

---

### Phase 2: Scan

**Goal:** Systematically detect drift across all five categories.

Scan in this order (build full findings before presenting):

**Step 2a: Token Drift**
- Parse token definitions from source (CSS vars, Tailwind config, tokens.json, etc.)
- Search codebase for hardcoded values matching token values
- Flag instances using hardcoded values instead of token references
- Count total hardcoded tokens by type (color, spacing, font-size, radius, shadow)

Example patterns to search:
- CSS: `color: #2563eb;` (should be `var(--color-primary-500)`)
- Tailwind: `className="p-4"` where design system uses different spacing scale
- Styled-components: `color: '#2563eb'` instead of `${theme.colors.primary[500]}`

**Step 2b: Component Drift**
- Parse component prop types/TypeScript interfaces
- Scan component implementations for hardcoded values, missing props, behavior divergence
- Check component stories for API alignment
- Flag components where implementation doesn't match spec

Example: Button component spec says `size: 'sm' | 'md' | 'lg'` but implementation uses `fontSize` prop instead.

**Step 2c: Design Pattern Drift**
- Scan CSS rules for consistent spacing, color, typography, radius values
- Build frequency map: which colors are most common? which spacings?
- Flag outliers and inconsistencies
- Identify patterns that violate design system conventions

Example: If design system spacing is [8, 12, 16, 24, 32, 48], flag any usage of [10, 14, 18, 20, 28].

**Step 2d: Accessibility Drift**
- Scan components for ARIA attributes (aria-label, aria-invalid, aria-live, etc.)
- Check for semantic HTML usage (proper heading hierarchy, form labels)
- Test keyboard support (Tab, Enter, Escape handlers)
- Scan for reduced-motion support (`@media (prefers-reduced-motion: reduce)`)
- Identify components that have lost accessibility features

Example: Modal component should have focus trap, but code shows no focus management.

**Step 2e: Storybook Drift**
- Parse Storybook stories and component APIs
- Compare story args against component props
- Identify missing stories (new component variants without docs)
- Flag stories with deprecated prop names

Example: Story uses `onClick` prop but component expects `onPress`.

---

### Phase 3: Report

**Goal:** Present a clear, prioritized drift report and get explicit human approval before touching files.

Report structure:

```
# Design System Drift Report: [Project]

## Executive Summary

**Drift Score: [X/100]**
**Severity: [Excellent / Good / Fair / Poor / Critical]**
**Drift Velocity: [+X points/month] [↑ Accelerating / → Stable / ↓ Improving]**

---

## Drift by Category

| Category | Count | Severity | Impact | Trend |
|----------|-------|----------|--------|-------|
| Token Drift | X | CRITICAL | $X/month maintenance | ↑ |
| Component Drift | X | MAJOR | Y developer hours/sprint | ↓ |
| Pattern Drift | X | MAJOR | Brand inconsistency risk | → |
| A11y Drift | X | CRITICAL | WCAG AA failures | ↑ |
| Storybook Drift | X | MINOR | Documentation debt | → |

---

## Critical Findings (WCAG AA Failures, Token Debt)

| File | Location | Issue | Type | Impact | Status |
|------|----------|-------|------|--------|--------|
| src/Button.tsx | Line 45 | Missing aria-label on icon button | A11y | WCAG 4.1.2 | [ ] Fix |
| src/styles/form.css | Line 12 | Error color hardcoded #EF4444 | Token | Replace with var(--color-error) | [ ] Fix |

---

## Major Findings (Component/Pattern Drift)

| File | Location | Issue | Type | Impact | Status |
|------|----------|-------|------|--------|--------|
| src/Card.tsx | Line 8 | Padding hardcoded 16px | Token | Replace with var(--spacing-md) | [ ] Fix |
| src/Button.tsx | Various | 4 different implementations | Component | Consolidate to 1 | [ ] Fix |

---

## Minor Findings (Storybook/Documentation)

| File | Location | Issue | Type | Impact | Status |
|------|----------|-------|------|--------|--------|
| src/Button.stories.tsx | Line 23 | Story uses deprecated onClick prop | Storybook | Update to onPress | [ ] Fix |

---

## Recommendations

1. Address all CRITICAL findings (A11y failures, token debt)
2. Plan component consolidation in next sprint
3. Update Storybook stories to match current API
4. Set up automated checks to prevent future drift (linting rules)

---

**Shall I fix all of these, or would you like to select specific items or files?**
```

**Do not modify any files until the human explicitly approves.** Wait for clear approval (e.g., "yes, fix them all" or "fix only the accessibility issues").

---

### Phase 4: Fix

**Goal:** Apply approved fixes with precision, file by file, with a summary after each file.

Fix rules:
- Fix one file at a time
- Show a before/after diff-style summary
- Only replace drift values with correct token/component references
- Never change logic, layout, or behavior
- If a fix requires a judgment call, pause and ask

Example fix output:

```
## Fixing src/Button.css

BEFORE:
.btn { padding: 16px 24px; }
.btn.error { color: #EF4444; }

AFTER:
.btn { padding: var(--spacing-md) var(--spacing-lg); }
.btn.error { color: var(--color-error); }

Status: ✓ Fixed (2 token replacements)
```

After all fixes, run a quick re-scan to confirm no new drift was introduced.

---

## Reference Guide

### Token Detection Patterns

**CSS Custom Properties**
```css
/* GOOD - Using token */
color: var(--color-primary-500);
padding: var(--spacing-md);

/* DRIFT - Hardcoded value */
color: #2563eb;
padding: 16px;
```

**Tailwind Config**
```js
// tailwind.config.js
module.exports = {
  theme: {
    spacing: { sm: '8px', md: '16px', lg: '24px' },
    colors: { primary: { 500: '#2563eb' } }
  }
}

// GOOD - Using Tailwind tokens
className="p-4 text-blue-600"

// DRIFT - Hardcoded values
className="p-[16px] text-[#2563eb]"
```

**Styled-components Theme**
```js
// GOOD - Using theme
const Button = styled.button`
  padding: ${props => props.theme.spacing.md};
  color: ${props => props.theme.colors.primary};
`;

// DRIFT - Hardcoded values
const Button = styled.button`
  padding: 16px;
  color: #2563eb;
`;
```

**CSS-in-JS (Emotion)**
```js
// GOOD - Using tokens
const buttonStyles = css`
  padding: var(--spacing-md);
  color: var(--color-primary);
`;

// DRIFT - Hardcoded values
const buttonStyles = css`
  padding: 16px;
  color: #2563eb;
`;
```

---

### Accessibility Drift Patterns to Check

**Missing ARIA Labels**
```jsx
// DRIFT - Icon button without label
<button>
  <Icon name="close" />
</button>

// GOOD - Icon button with aria-label
<button aria-label="Close dialog">
  <Icon name="close" />
</button>
```

**Missing Form Label Association**
```jsx
// DRIFT - Input without label
<input type="email" placeholder="Email" />

// GOOD - Input with label
<label htmlFor="email">Email</label>
<input id="email" type="email" />
```

**Form Validation Not Announced**
```jsx
// DRIFT - Visual error only
<input style={{ borderColor: isError ? 'red' : 'gray' }} />

// GOOD - Error announced to screen readers
<input aria-invalid={isError} aria-describedby={isError ? "error-msg" : undefined} />
<span id="error-msg" role="alert">{errorMessage}</span>
```

**Modal Focus Trap Lost**
```js
// DRIFT - Modal doesn't manage focus
<dialog open>
  <button>Close</button>
  <p>Content</p>
</dialog>

// GOOD - Modal manages focus
useEffect(() => {
  const focusableElements = dialog.querySelectorAll('[tabindex], button, [href]');
  const firstElement = focusableElements[0];
  const lastElement = focusableElements[focusableElements.length - 1];
  
  dialog.addEventListener('keydown', (e) => {
    if (e.key !== 'Tab') return;
    if (e.shiftKey && document.activeElement === firstElement) {
      lastElement.focus();
      e.preventDefault();
    } else if (!e.shiftKey && document.activeElement === lastElement) {
      firstElement.focus();
      e.preventDefault();
    }
  });
}, []);
```

**Motion Not Respecting User Preference**
```jsx
// DRIFT - Animation ignores prefers-reduced-motion
const animation = keyframes`
  from { opacity: 0; }
  to { opacity: 1; }
`;

// GOOD - Animation respects prefers-reduced-motion
const animation = keyframes`
  @media (prefers-reduced-motion: no-preference) {
    from { opacity: 0; }
    to { opacity: 1; }
  }
`;
```

---

## Output Format

Always produce output in this order:
1. **Discovery summary** (brief — what you found)
2. **Scan progress** (one line per category as you complete it)
3. **Full drift report** (Phase 3 formatted table)
4. **Await approval** (explicit ask for permission)
5. **Fix log** (Phase 4, one entry per file)
6. **Final re-scan summary** (confirmation of fixes)

---

## Important Constraints

- Never guess at token names — only reference tokens you confirmed exist
- Never modify test files, lock files, generated files, or build output
- Never fix drift in vendor/node_modules
- If the design system has no token for a value, flag it as a design system gap, not a code violation
- Respect `.gitignore` — do not scan ignored files
- If the codebase is very large (>500 files), ask the user to confirm scope or suggest scanning a specific directory first

---

## Cross-References

- **accessibility-code** — Detailed remediation code for accessibility fixes
- **design-handoff** — Generate handoff specs from design system tokens
- **design-review-cowork** — Multi-perspective prototype review including design system alignment
