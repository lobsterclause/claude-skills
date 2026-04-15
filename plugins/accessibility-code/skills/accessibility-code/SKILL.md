---
name: accessibility-code
description: Review, audit, or write accessible frontend code — HTML, CSS, JavaScript, React, Vue, Svelte, or other UI frameworks. Use this skill whenever the user shares code and asks about accessibility, semantic HTML, ARIA, keyboard navigation, focus management, screen reader compatibility, or WCAG conformance. Also trigger for requests like "make this component accessible", "add ARIA to this", "fix the keyboard navigation", "is this semantic?", "accessible React component", "fix focus trap", "accessible modal", "accessible dropdown", or any code-related accessibility question. Covers WCAG 2.2 AAA, Section 508, and ARIA APG patterns. Goes deeper than Lighthouse or axe-core—catches logic, interaction, dynamic state, and framework-specific issues automated tools miss.
category: audit
related-skills: keyboard-focus-auditor, accessible-forms, accessible-tables, contrast-checker, a11y-test-plan, wcag-compliance-auditor, full-accessibility-audit
---

# Accessibility Code Audit & Review

You are a senior accessibility engineer. Your reviews go beyond what Lighthouse, axe-core, or eslint-plugin-jsx-a11y catch — you assess semantic structure, keyboard interaction logic, focus management, dynamic state communication, and ARIA correctness. You understand how screen readers announce DOM content and how keyboard users navigate complex interactions.

## Review Philosophy

- **Prefer native HTML over ARIA.** A `<button>` is infinitely better than `<div role="button">`.
- **ARIA is additive, not corrective.** ARIA cannot fix bad semantic structure; it only supplements it.
- **Screen readers announce what the DOM says, not what it looks like.** Visual fixes don't guarantee accessible names or roles.
- **Keyboard users are not an edge case.** They include power users, motor-impaired users, voice control users, and anyone with a broken trackpad.
- **Test with real AT.** Automated tools catch 30% of issues; the other 70% require manual testing with NVDA, JAWS, VoiceOver, TalkBack.

---

## Part 1: Semantic HTML Foundations

### Element Selection Rules

Always use the most semantically appropriate element. This is the foundation of accessibility:

| Purpose | Use | Never Use | Why |
|---------|-----|-----------|-----|
| Trigger an action in the app | `<button>` | `<div onclick>`, `<a href="#">` | Buttons have keyboard semantics by default |
| Navigate to a URL | `<a href="/page">` | `<button>` with JS router | Links are announced differently by AT |
| Group form fields | `<fieldset>` + `<legend>` | `<div class="form-group">` | Fieldset creates programmatic grouping |
| Data table with meaning | `<table>`, `<th scope>` | CSS Grid with divs | Table headers provide relationship semantics |
| Page region (navigation) | `<nav>` | `<div class="nav">` | Landmark provides navigation skip target |
| Main page content | `<main>` | `<div id="main">` | One `<main>` per page; skip destination |
| Page section with title | `<section aria-labelledby="h2-id">` | `<div class="section">` | Sections are content landmarks |
| Sidebar / supplementary | `<aside>` | `<div class="sidebar">` | Aside is a landmark for supporting content |
| Blog post / article | `<article>` | `<div class="post">` | Article marks independent content |

### Heading Hierarchy

Headings define the document outline for screen reader users:

```html
<!-- CORRECT: logical outline -->
<h1>Page Title</h1>

<h2>Section 1</h2>
<h3>Subsection 1.1</h3>
<h3>Subsection 1.2</h3>

<h2>Section 2</h2>
<h3>Subsection 2.1</h3>
```

```html
<!-- WRONG: skipping levels breaks outline -->
<h1>Page Title</h1>
<h3>Section 1</h3>  <!-- jumped h2! outline is broken -->
<h4>Subsection</h4>
```

**Rules:**
- **One H1 per page/view.** The page or main content title.
- **Never skip levels.** H1 → H2 → H3 → H4. No H1 → H4.
- **Don't choose heading level for visual size.** Use CSS to style; use heading for semantic meaning.
- **Single-page applications:** Update the `<title>` and H1 on navigation.

### Landmark Regions

Every page should have these landmarks:

```html
<header aria-label="Site header">
  <!-- Logo, tagline -->
</header>

<nav aria-label="Main navigation">
  <!-- Primary navigation links -->
</nav>

<main id="main-content">
  <!-- Primary content — ONLY ONE per page -->
</main>

<footer>
  <!-- Site footer: links, copyright -->
</footer>
```

**Multiple navigation regions require distinct labels:**

```html
<nav aria-label="Main navigation">
  <!-- Site navigation -->
</nav>

<nav aria-label="Breadcrumb">
  <!-- Breadcrumb trail -->
</nav>

<nav aria-label="Table of contents">
  <!-- In-page TOC -->
</nav>
```

---

## Part 2: ARIA Fundamentals

### The Five Rules of ARIA

1. **Use native HTML first.** If semantic HTML element exists, use it. Never use ARIA to replace native semantics.
2. **Don't change native semantics unless absolutely necessary.** Never do `<h1 role="button">Click me</h1>`.
3. **All interactive ARIA controls must be keyboard operable.** If you use `role="button"`, you must handle keyboard: Enter and Space must activate it.
4. **Don't hide focusable elements.** Never use `role="presentation"` or `aria-hidden="true"` on an element that receives focus (`tabindex="0"`, form input, etc.).
5. **All interactive elements must have an accessible name.** Users must know what a button does or what a field is for.

### Accessible Names: Resolution Order

The browser resolves accessible names in this priority:

1. **aria-labelledby** — Reference another element's text (`<button aria-labelledby="label-id">`)
2. **aria-label** — String value (`<button aria-label="Close dialog">×</button>`)
3. **Native label** — `<label>`, `<legend>`, `<caption>`, `<figcaption>`, `alt` (on images)
4. **title** attribute — Last resort; not reliably exposed to screen readers

**Example: Accessible name resolution**

```html
<!-- Option 1: aria-labelledby (preferred for complex labels) -->
<h2 id="modal-title">Delete Account</h2>
<p id="modal-desc">This action cannot be undone.</p>
<button aria-labelledby="modal-title">Delete</button>
<!-- Screen reader: "Delete" (from aria-labelledby) -->

<!-- Option 2: aria-label (for icon buttons, brief labels) -->
<button aria-label="Close dialog">×</button>
<!-- Screen reader: "Close dialog" -->

<!-- Option 3: visible text (preferred) -->
<button>Save Changes</button>
<!-- Screen reader: "Save Changes" -->

<!-- Option 4: <label> (for form inputs) -->
<label for="email">Email address:</label>
<input id="email" type="email" />
<!-- Screen reader: "Email address" (from label) -->
```

### Common ARIA Patterns (from APG)

#### Modal Dialog

```jsx
<div
  role="dialog"
  aria-modal="true"
  aria-labelledby="dialog-title"
  aria-describedby="dialog-description"
>
  <h2 id="dialog-title">Confirm Deletion</h2>
  <p id="dialog-description">
    This action cannot be undone. Are you sure?
  </p>
  <button onclick="closeDialog()">Cancel</button>
  <button onclick="deleteItem()">Delete Permanently</button>
</div>
```

**Keyboard requirements:**
- Escape key closes dialog (trap focus until then)
- Tab cycles through focusable elements within dialog
- Focus returns to trigger element on close

#### Disclosure / Accordion

```jsx
<button
  aria-expanded="false"
  aria-controls="section-content"
  onclick="toggleSection()"
>
  Section Title
</button>
<div id="section-content" hidden>
  <!-- Content -->
</div>
```

**Keyboard:** Enter or Space to toggle.

#### Tab Panel

```jsx
<div role="tablist" aria-label="Preferences">
  <button
    role="tab"
    aria-selected="true"
    aria-controls="panel-profile"
    id="tab-profile"
  >
    Profile
  </button>
  <button
    role="tab"
    aria-selected="false"
    aria-controls="panel-security"
    id="tab-security"
    tabindex="-1"
  >
    Security
  </button>
</div>

<div role="tabpanel" id="panel-profile" aria-labelledby="tab-profile">
  <!-- Profile content -->
</div>
<div role="tabpanel" id="panel-security" aria-labelledby="tab-security" hidden>
  <!-- Security content -->
</div>
```

**Keyboard:**
- Left/Right Arrow keys move between tabs
- Home/End move to first/last tab
- Tab into tabpanel; Arrow keys switch active tab

#### Combobox / Autocomplete

Follow ARIA APG combobox pattern. Key requirements:

```jsx
<input
  role="combobox"
  aria-expanded={isOpen}
  aria-controls="suggestions-list"
  aria-autocomplete="list"
  onKeyDown={handleKeyDown}
/>
<ul id="suggestions-list" hidden={!isOpen}>
  {suggestions.map((item, idx) => (
    <li
      role="option"
      aria-selected={activeIdx === idx}
      key={item.id}
    >
      {item.label}
    </li>
  ))}
</ul>
```

**Keyboard:**
- Down Arrow expands list, moves to first option
- Up/Down Arrow navigate options
- Enter/Space select active option
- Escape close list

#### Menu Button

```jsx
<button aria-haspopup="menu" aria-expanded={isOpen}>
  Actions
</button>
<ul role="menu" hidden={!isOpen}>
  <li role="menuitem">Edit</li>
  <li role="menuitem">Duplicate</li>
  <li role="menuitem" aria-disabled="true">Archive</li>
</ul>
```

**Keyboard:**
- Space/Enter opens menu
- Down/Up Arrow navigate items
- Enter/Space activate item
- Escape closes menu

#### Alert and Status

```jsx
<!-- Urgent: interrupts screen reader immediately -->
<div role="alert">
  Payment failed. Check your card number.
</div>

<!-- Polite: announces at next pause -->
<div role="status" aria-live="polite">
  Saved successfully.
</div>

<!-- Assertive: high priority but not interrupt -->
<div role="log" aria-live="assertive">
  5 files uploaded.
</div>
```

---

## Part 3: Keyboard Interaction

### Tab Order Rules

```html
<!-- Good: Natural DOM order -->
<button>First</button>
<button>Second</button>
<input />

<!-- Also good: tabindex="0" adds to tab order in DOM sequence -->
<button tabindex="0">Focusable</button>
<button>Also focusable</button>

<!-- BAD: tabindex="1+" creates unpredictable tab order -->
<button tabindex="2">This is confusing</button>
<button tabindex="1">User tabbed here first? No!</button>
<!-- NEVER use positive tabindex values -->

<!-- OK for temporarily removing from tab order -->
<button tabindex="-1">Not in tab order, but focusable by script</button>
```

**Rule:** Logical tab order matches visual reading order (left-to-right, top-to-bottom). Never use `tabindex > 0`.

### Required Keyboard Behaviors by Component

| Component | Required Keys |
|-----------|---------------|
| Button | Enter, Space |
| Link | Enter |
| Text Input | Standard editing keys (Backspace, Delete, Arrow keys) |
| Checkbox | Space (toggle) |
| Radio Group | Arrow keys within group, Tab to move between groups |
| Select / Listbox | Arrow keys navigate, Enter/Space select |
| Dialog / Modal | Escape closes, Tab cycles within |
| Tabs | Left/Right Arrow move between tabs, Tab into panel |
| Menu | Arrow keys navigate, Enter/Space select, Escape close |
| Slider | Left/Right or Up/Down Arrow adjust value, Home/End for min/max |
| Dropdown | Space/Enter opens, Arrow keys navigate, Escape closes |

### Focus Management

#### Opening a Modal

```javascript
// Store the trigger element
const triggerButton = event.target;

// Show modal and move focus into it
const modal = document.getElementById('modal');
modal.removeAttribute('hidden');

// Find first focusable element in modal
const firstFocusable = modal.querySelector(
  'button, [href], input, select, textarea, [tabindex="0"]'
);
firstFocusable?.focus();
```

#### Closing a Modal & Returning Focus

```javascript
function closeModal() {
  const modal = document.getElementById('modal');
  modal.setAttribute('hidden', '');

  // Return focus to trigger element
  triggerButton.focus();
}
```

#### Focus Trap for Modals (Prevent Tab from Escaping)

```javascript
function setupFocusTrap(modalElement, onClose) {
  const focusable = Array.from(
    modalElement.querySelectorAll(
      'a[href], button:not([disabled]), textarea, input, select, [tabindex="0"]'
    )
  );

  const firstFocusable = focusable[0];
  const lastFocusable = focusable[focusable.length - 1];

  modalElement.addEventListener('keydown', (e) => {
    if (e.key === 'Escape') {
      onClose();
      return;
    }

    if (e.key !== 'Tab') return;

    // Shift+Tab: move backwards
    if (e.shiftKey) {
      if (document.activeElement === firstFocusable) {
        e.preventDefault();
        lastFocusable.focus();
      }
    } else {
      // Tab: move forwards
      if (document.activeElement === lastFocusable) {
        e.preventDefault();
        firstFocusable.focus();
      }
    }
  });
}
```

#### Skip Links (Required on Every Page)

```html
<a href="#main-content" class="skip-link">
  Skip to main content
</a>

<main id="main-content">
  <!-- Primary content -->
</main>
```

```css
.skip-link {
  position: absolute;
  left: -9999px;
  z-index: 999;
}

.skip-link:focus {
  left: 0;
  top: 0;
  background: #000;
  color: #fff;
  padding: 10px;
}
```

### Focus Indicator CSS

WCAG 2.2 requires: 3:1 contrast ratio between focus indicator and adjacent colors, minimum 2px solid outline, area ≥ perimeter of component × 2px.

```css
/* NEVER REMOVE FOCUS INDICATORS */
*:focus { outline: none; }  /* ❌ DON'T DO THIS */
button:focus { outline: 0; }  /* ❌ DON'T DO THIS */

/* MINIMUM COMPLIANT: visible focus indicator */
:focus-visible {
  outline: 3px solid #0066cc;
  outline-offset: 2px;
}

/* HIGH-QUALITY: works on any background */
:focus-visible {
  outline: 3px solid #0066cc;
  outline-offset: 2px;
  box-shadow: 0 0 0 5px rgba(0, 102, 204, 0.25);
}
```

**Use `:focus-visible`, not `:focus`.** This shows outline on keyboard focus but not mouse click (better UX).

---

## Part 4: Framework-Specific Patterns

### React

#### Managing Focus After State Changes

```jsx
import { useEffect, useRef } from 'react';

function Modal({ isOpen, onClose, children }) {
  const firstButtonRef = useRef(null);
  const triggerRef = useRef(null);

  useEffect(() => {
    if (isOpen && firstButtonRef.current) {
      firstButtonRef.current.focus();
    }
  }, [isOpen]);

  function handleClose() {
    onClose();
    // Parent component should: triggerRef.current?.focus()
  }

  return isOpen ? (
    <div role="dialog" aria-modal="true">
      <button ref={firstButtonRef}>Close</button>
      {children}
    </div>
  ) : null;
}
```

#### Announcing Dynamic Content (Live Regions)

```jsx
import { useRef, useEffect } from 'react';

function LiveRegion({ message, type = 'polite' }) {
  return (
    <div
      role={type === 'alert' ? 'alert' : 'status'}
      aria-live={type}
      aria-atomic="true"
      className="sr-only"
    >
      {message}
    </div>
  );
}

// Usage
<LiveRegion message="5 items added to cart" type="polite" />
<LiveRegion message="Payment failed" type="alert" />
```

#### Visually Hidden Utility Class

```css
.sr-only {
  position: absolute;
  width: 1px;
  height: 1px;
  padding: 0;
  margin: -1px;
  overflow: hidden;
  clip: rect(0, 0, 0, 0);
  white-space: nowrap;
  border-width: 0;
}
```

#### useId for Label Association (React 18+)

```jsx
import { useId } from 'react';

function TextInput({ label, ...props }) {
  const id = useId();

  return (
    <>
      <label htmlFor={id}>{label}</label>
      <input id={id} {...props} />
    </>
  );
}
```

### Vue 3

#### Focus Management

```vue
<template>
  <div v-if="isOpen" role="dialog" aria-modal="true">
    <button ref="closeButtonRef">Close</button>
  </div>
</template>

<script setup>
import { ref, watch } from 'vue';

const isOpen = ref(false);
const closeButtonRef = ref(null);

watch(isOpen, (newValue) => {
  if (newValue) {
    nextTick(() => closeButtonRef.value?.focus());
  }
});
</script>
```

#### Live Regions in Vue

```vue
<template>
  <div
    :role="type === 'alert' ? 'alert' : 'status'"
    :aria-live="type"
    aria-atomic="true"
    class="sr-only"
  >
    {{ message }}
  </div>
</template>

<script setup>
defineProps({
  message: String,
  type: { type: String, default: 'polite' }
});
</script>
```

### Svelte

#### Focus Management

```svelte
<script>
  let isOpen = false;
  let firstButton;

  $: if (isOpen) {
    setTimeout(() => firstButton?.focus());
  }
</script>

<dialog open={isOpen}>
  <button bind:this={firstButton}>Close</button>
</dialog>
```

#### Live Regions in Svelte

```svelte
<script>
  export let message = '';
  export let type = 'polite';
</script>

<div
  role={type === 'alert' ? 'alert' : 'status'}
  aria-live={type}
  aria-atomic="true"
  class="sr-only"
>
  {message}
</div>
```

---

## Part 5: Common Anti-Patterns & Fixes

| Anti-Pattern | Problem | Fix |
|--------------|---------|-----|
| `<div onclick="">Click me</div>` | No keyboard support, announced as generic group | Use `<button>Click me</button>` |
| `<a href="#" onclick="...">Do something</a>` | Link announced as "link #", button behavior expected | Use `<button>` for actions |
| `<input />` (no label) | No accessible name | Add `<label for="id">` |
| `<button aria-label="×">×</button>` | Visual text conflicts with aria-label | Use aria-label only if no visual text |
| `tabindex="5"` | Tab order is unpredictable | Use natural DOM order or `tabindex="0"` / `"-1"` only |
| `<h1 style="font-size: 12px;">` | Semantics don't match visual | Use heading size appropriate to content level |
| `<img alt="image">` or `<img>` (no alt) | Unclear or missing meaning | Descriptive alt: `<img alt="Screenshot of login form">` |
| `<table><tr><td>Header</td>` (no TH) | No row/column relationship | Use `<th scope="col">Header</th>` |
| `<button style="pointer-events: none;">` | Disabled but still focusable | Use `<button disabled>` or `aria-disabled="true"` |
| Event listeners on wrong elements | Keyboard users excluded from interaction | Attach listeners to focusable elements (button, input, etc.) |

---

## Part 6: Code Review Output Format

```
## Accessibility Code Review

**File / Component:** [name/path]
**Language / Framework:** [HTML / React / Vue / etc.]
**Standards:** WCAG 2.2 AAA, Section 508, ARIA APG

---

## Critical Issues — P0

### [Issue Title]
- **Line(s):** [N/A or specific line numbers]
- **Problem:** [What's wrong and why it matters]
- **Standard:** [WCAG criterion, e.g., 2.1.1 Keyboard]
- **Current Code:**
  ```html
  [the problematic code]
  ```
- **Fixed Code:**
  ```html
  [corrected version with explanation]
  ```

[repeat for each P0]

---

## Major Issues — P1

[same format]

---

## Minor Issues — P2

[same format]

---

## Enhancements — P3

[same format]

---

## Passed Checks

- [ ] Semantic HTML used correctly (button, nav, main, landmark regions)
- [ ] ARIA used only when necessary; never to fix bad semantics
- [ ] All interactive elements keyboard operable
- [ ] Form inputs have labels
- [ ] Heading hierarchy is logical (one H1, no skipped levels)
- [ ] Focus management implemented (modals, dynamic content)
- [ ] Focus indicators visible (never removed)
- [ ] Tab order matches visual flow
- [ ] Live regions properly configured for dynamic updates
- [ ] Accessible names present for all interactive elements

---

## Manual Testing Recommendations

### Keyboard Navigation Test
**Browser:** Chrome/Firefox
**Tools:** None (just Tab and Escape keys)
**Steps:**
1. Open page
2. Tab through all interactive elements
3. Verify focus order matches visual left-to-right, top-to-bottom flow
4. Test Escape key in modals/dropdowns
5. Test Enter/Space on buttons and links

### Screen Reader Test (NVDA + Chrome)
**Tools:** NVDA (free, Windows)
**Steps:**
1. Enable NVDA
2. Navigate page using H (headings), N (navigation), M (main), etc.
3. Verify all content is announced
4. Test form submission error messages
5. Test dynamic content updates (live regions)

**Expected:** All content accessible; no content hidden; interactions announced correctly.

---

## Severity Legend

- **P0 (CRITICAL):** Blocks keyboard or screen reader users from completing task; legal/ADA exposure.
- **P1 (MAJOR):** Significantly degrades experience; keyboard or screen reader user hits workaround.
- **P2 (MINOR):** Friction but task remains completable; less-critical code path affected.
- **P3 (ENHANCEMENT):** Best practice improvement; AAA enhancement; optimization opportunity.

---

## Cross-References

- **keyboard-focus-auditor:** For detailed keyboard flow mapping and tab order verification
- **accessible-forms:** For form-specific patterns (labels, validation, error messages)
- **accessible-tables:** For table semantics and header scope
- **contrast-checker:** For color contrast in CSS/design
- **a11y-test-plan:** For comprehensive AT test cases
- **wcag-compliance-auditor:** For full WCAG 2.2 criterion coverage
- **full-accessibility-audit:** For multi-dimensional audit (design + code + content)
