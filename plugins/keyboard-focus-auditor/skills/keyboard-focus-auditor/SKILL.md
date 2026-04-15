---
name: keyboard-focus-auditor
description: Audit, document, and fix keyboard navigation flows, tab order, focus indicators, focus traps, skip links, and focus management for dynamic content. Use this skill whenever the user needs to test or improve keyboard accessibility — including auditing tab order, documenting expected keyboard behavior, fixing focus management after state changes, implementing focus traps, or verifying WCAG 2.1 keyboard criteria. Trigger on phrases like "keyboard navigation", "tab order", "focus management", "focus trap", "skip link", "keyboard accessible", "focus indicator", "focus visible", "keyboard flow", "keyboard audit", "roving tabindex", "combobox", "nested dialog", "virtual scrolling", "Windows High Contrast", "keyboard shortcut", "can't use keyboard", or any request to make a UI operable without a mouse. Covers WCAG 2.2 AA/AAA keyboard criteria and real assistive technology keyboard patterns.
category: audit
related-skills: accessibility-code, screen-reader-scripting, accessible-forms
---

# Keyboard & Focus Auditor

Keyboard accessibility is the foundation of all assistive technology access — screen readers, switch access, voice control, and eye tracking all depend on a correct keyboard model. This skill audits, documents, and fixes it.

## Philosophy

Keyboard is the common denominator. Screen readers navigate by keyboard. Switch access cycles through focusable elements. Voice control clicks what it sees and speaks what it hears. Power users prefer keyboard for speed. Motor disabilities require keyboard alternatives. If it's not keyboard accessible, it's inaccessible to all of the above.

But keyboard accessibility is complex: simple tab order audits miss nested focus traps, roving tabindex patterns, and dynamic content that steals focus. This skill addresses tab order, focus indicators, focus management, and complex patterns like modals within modals, comboboxes, and virtualized lists.

---

## Core Framework

### WCAG 2.2 Keyboard Criteria

| Criterion | Level | Requirement |
|-----------|-------|-------------|
| 2.1.1 Keyboard | A | All functionality operable via keyboard |
| 2.1.2 No Keyboard Trap | A | No component traps focus permanently |
| 2.1.3 Keyboard (No Exception) | AAA | All functionality, including path-dependent gestures |
| 2.1.4 Character Key Shortcuts | A | Single-key shortcuts can be remapped or disabled |
| 2.4.1 Bypass Blocks | A | Skip link or landmark nav to bypass repeated content |
| 2.4.3 Focus Order | A | Focus sequence preserves meaning and operation |
| 2.4.7 Focus Visible | AA | Keyboard focus indicator is visible |
| 2.4.11 Focus Not Obscured (Minimum) | AA | Focused component not fully hidden by sticky elements |
| 2.4.12 Focus Not Obscured (Enhanced) | AAA | Focused component fully visible |
| 2.4.13 Focus Appearance | AAA | Focus indicator: ≥2px perimeter, 3:1 contrast, not offset into component |
| 2.5.3 Label in Name | A | Visible label included in accessible name |

---

## Process

### Step 1: Tab Order Audit

**Load the page with no mouse.** Press Tab repeatedly from the browser address bar. Document every element that receives focus, in order.

**Document for each focused element:**
- Element type (button, input, link, etc.)
- Visible label or accessible name
- Position on screen
- Any unexpected focus behavior

**What to Check:**
- Does focus follow visual/logical reading order (top-left to bottom-right for LTR)?
- Does focus visit all interactive elements?
- Does focus skip any interactive elements?
- Does focus land on non-interactive elements (static text, containers)?
- Are there any `tabindex` values greater than 0? (Almost always wrong; eliminate them)

**Finding Positive tabindex Values:**
```javascript
// Audit the page for positive tabindex values
document.querySelectorAll('[tabindex]').forEach(el => {
  const val = parseInt(el.getAttribute('tabindex'));
  if (val > 0) console.warn('Positive tabindex found:', el, val);
});
```

**tabindex Reference**
```html
<!-- In natural tab order (default for native interactive elements) -->
<button>Submit</button>

<!-- Explicitly added to tab order — use sparingly for custom components -->
<div tabindex="0" role="button">Custom control</div>

<!-- Focusable by script only — not in tab order -->
<div tabindex="-1" id="error-summary">Errors found</div>

<!-- NEVER USE — creates unpredictable tab order -->
<button tabindex="5">Don't do this</button>
```

### Step 2: Complex Focus Scenarios

Beyond linear tab order, audit these complex scenarios:

**Nested Dialogs or Modals**
When a modal opens another modal:
- Does focus trap work in the inner modal?
- Can you close the inner modal with Escape?
- Does focus return to the trigger of the inner modal, or to the outer modal trigger?
- Test: open modal A → open modal B (from within A) → close B → verify focus is in A, not on the page behind A

**Combobox Within Modal**
- Open modal with a combobox (autocomplete input)
- Focus the combobox
- Type to filter options (Down arrow opens listbox)
- Is focus trap still active? (Pressing Tab should stay within the modal, not the listbox)
- Can you Tab out of the modal listbox back to the modal trigger?

**Virtual Scrolling or Dynamic Lists**
When a list is virtualized (only visible items are in the DOM):
- Tab through the list — does focus jump correctly as you approach the end?
- When new items are added to the top/bottom, where does focus go?
- Does scrolling reveal focused items, or is the focused item scrolled out of view?

**Implementation:** Ensure `scroll-into-view` is called on focused elements when list changes or focus enters.

### Step 3: Focus Indicator Assessment

**WCAG 2.4.13 Focus Appearance (AAA)**
- Perimeter: Focus indicator area ≥ perimeter of component × 2px (minimum 2px visible outline)
- Contrast: 3:1 between focus indicator and adjacent colors (both focused and unfocused states)
- Positioning: Outline must be outside or on the boundary; not inset/offset into component

**Testing Focus Indicators**
1. Tab to each interactive element
2. Observe or screenshot the focus ring
3. Measure: Does it meet ≥2px perimeter?
4. Test contrast: Does focus outline have 3:1 against the background behind it?
5. Test against all backgrounds: What if the element is on a dark background? Light background? Image background?

**CSS Implementation Patterns**

```css
/* Minimum: always visible, high contrast */
:focus-visible {
  outline: 3px solid #005fcc;
  outline-offset: 2px;
}

/* High quality: works on any background color */
:focus-visible {
  outline: 3px solid #005fcc;
  outline-offset: 2px;
  box-shadow: 0 0 0 5px white; /* creates contrast buffer against dark backgrounds */
}

/* Dark background variant */
:focus-visible {
  outline: 3px solid #ffffff;
  outline-offset: 2px;
  box-shadow: 0 0 0 5px #000000;
}

/* NEVER */
:focus { outline: none; }  /* Removes focus indicator entirely */
*:focus { outline: 0; }    /* Global reset; breaks keyboard accessibility */
a:focus { outline: none; } /* Common in CSS resets but breaks everything */
```

Use `:focus-visible` (not `:focus`) to avoid showing outline on mouse click while preserving it for keyboard and assistive technology users.

**WCAG 2.4.13 Contrast Math**
For a 3px outline:
- Perimeter of a 40×40px button: (40 + 40) × 2 = 160px
- 3px outline covers: 160 × 3 = 480px of visual area (minimum requirement is just 160px, so 3px is safe)
- But the 3px outline itself must have 3:1 contrast against what's behind it

### Step 4: Focus Obscured by Sticky Elements

When sticky headers or footers exist, focused elements scrolled near them may be hidden.

**Fix with scroll-margin:**
```css
/* Give focused elements scroll margin equal to sticky header height */
:focus {
  scroll-margin-top: 80px; /* match your sticky header height */
  scroll-margin-bottom: 60px; /* match sticky footer if present */
}
```

This ensures that when an element is focused (either by click or keyboard), it scrolls into view with padding below the sticky element.

### Step 5: Windows High Contrast Mode

On Windows, users can enable High Contrast Mode, which:
- Overrides all colors with system theme colors (black text on white, white text on black, etc.)
- Can break CSS `outline` and `box-shadow` focus indicators if they rely on specific colors
- Requires testing with `forced-colors: active` media query

**Fix:**
```css
:focus-visible {
  outline: 3px solid; /* No color specified; uses system focus color */
}

/* For more explicit control in High Contrast: */
@media (forced-colors: active) {
  :focus-visible {
    outline: 3px solid CanvasText; /* System color keyword */
  }
}
```

### Step 6: Roving Tabindex Pattern

For components with multiple focusable items (menu, toolbar, listbox), use roving tabindex:
- Only one item in the group is in the tab order (tabindex="0")
- All other items have tabindex="-1"
- JavaScript moves focus with arrow keys and updates tabindex dynamically

**Complete Roving Tabindex Implementation**

```javascript
class RovingTabindex {
  constructor(containerSelector, itemSelector, keyBindings = {}) {
    this.container = document.querySelector(containerSelector);
    this.itemSelector = itemSelector;
    this.keyBindings = {
      ArrowRight: (items, current) => this.move(items, current, 1),
      ArrowLeft: (items, current) => this.move(items, current, -1),
      Home: (items) => items[0],
      End: (items) => items[items.length - 1],
      ...keyBindings
    };
    this.init();
  }

  init() {
    const items = this.getItems();
    items.forEach((item, index) => {
      item.tabIndex = index === 0 ? 0 : -1;
      item.addEventListener('keydown', (e) => this.handleKeydown(e, item));
    });
  }

  getItems() {
    return [...this.container.querySelectorAll(this.itemSelector)];
  }

  move(items, current, direction) {
    const currentIndex = items.indexOf(current);
    const newIndex = (currentIndex + direction + items.length) % items.length;
    return items[newIndex];
  }

  handleKeydown(e, currentItem) {
    const handler = this.keyBindings[e.key];
    if (!handler) return;

    const items = this.getItems();
    const nextItem = handler(items, currentItem);

    if (nextItem && nextItem !== currentItem) {
      e.preventDefault();
      this.setActive(items, nextItem);
      nextItem.focus();
    }
  }

  setActive(items, activeItem) {
    items.forEach(item => {
      item.tabIndex = item === activeItem ? 0 : -1;
    });
  }
}

// Usage
new RovingTabindex('.toolbar', '[role="button"]');
```

### Step 7: Keyboard Shortcut Conflict Avoidance

When implementing keyboard shortcuts, check for conflicts:
- Don't override browser shortcuts (Ctrl+S, Ctrl+F, Ctrl+P, Alt+F4, etc.)
- Don't override OS shortcuts (Cmd+Q on macOS, Win+X on Windows, etc.)
- Don't override common application patterns (Escape to cancel, Enter to submit)
- Don't use single-character shortcuts (WCAG 2.1.4 requires them to be remappable or disabled in forms/content editing)

**Shortcut Strategy:**
- Use Ctrl/Cmd + Shift + key combinations for custom commands
- Avoid any single-key shortcuts in text input contexts
- Provide a visible help menu (Shift+? or /? pattern) listing all shortcuts
- Allow users to disable custom shortcuts in settings

---

## Reference Guide

### Focus Management for Dynamic Content

**Route Change (Single-Page Application)**
```javascript
function onRouteChange(newTitle) {
  document.title = newTitle + ' — Site Name';
  const heading = document.querySelector('h1');
  heading.setAttribute('tabindex', '-1'); // Make it focusable
  heading.focus();
  // Optional: announce to screen readers
  announceToScreenReader('Navigated to ' + newTitle);
}
```

**After Form Submission Success**
```javascript
function onFormSuccess(message) {
  const successMessage = document.getElementById('success-msg');
  successMessage.setAttribute('tabindex', '-1');
  successMessage.focus();
  successMessage.textContent = message;
}
```

**After Filtering or Sorting a List**
```javascript
function onFilterApplied(resultCount) {
  // Use live region, don't move focus
  const status = document.getElementById('results-status');
  status.setAttribute('aria-live', 'polite');
  status.setAttribute('aria-atomic', 'true');
  status.textContent = `${resultCount} results found`;
}
```

**After Deleting a Focused Item**
When a focused element is removed from the DOM, focus is lost. Return it intelligently:
```javascript
function deleteItem(item, index, allItems) {
  const itemButton = item.querySelector('button');
  item.remove();

  // Move focus to adjacent item
  const nextItem = allItems[index] || allItems[index - 1];
  if (nextItem) {
    const nextButton = nextItem.querySelector('button');
    nextButton.focus();
  } else {
    // List is now empty
    document.getElementById('empty-state-heading').focus();
  }
}
```

### Skip Links

```html
<!-- In the <head> or first element in <body> -->
<a href="#main-content" class="skip-link">Skip to main content</a>

<!-- Later in the page -->
<main id="main-content" tabindex="-1">
  ...
</main>
```

```css
.skip-link {
  position: absolute;
  top: -100%;
  left: 0;
  background: #000;
  color: #fff;
  padding: 8px 16px;
  z-index: 9999;
  text-decoration: none;
}

.skip-link:focus {
  top: 0;
}
```

`tabindex="-1"` on the target (`<main>`) is required so focus can land on it programmatically without it being in the tab order permanently.

**Multiple Skip Links for Complex Pages**
```html
<a href="#main-content">Skip to main content</a>
<a href="#main-nav">Skip to navigation</a>
<a href="#search">Skip to search</a>
```

### Focus Traps

**Required for:**
- Modals and dialogs that overlay content
- Sidebars or off-canvas menus
- Mobile navigation drawers

**Never appropriate for:**
- Inline components that don't overlay
- Tooltips or popovers
- Dropdown menus

**Complete Focus Trap Implementation**

```javascript
function createFocusTrap(containerElement) {
  const focusableSelectors = [
    'a[href]',
    'button:not([disabled])',
    'input:not([disabled])',
    'select:not([disabled])',
    'textarea:not([disabled])',
    '[tabindex="0"]',
    '[role="button"]:not([aria-disabled="true"])'
  ].join(', ');

  function getFocusableElements() {
    return [...containerElement.querySelectorAll(focusableSelectors)]
      .filter(el => {
        // Exclude hidden or aria-hidden elements
        if (el.closest('[hidden]')) return false;
        if (el.closest('[aria-hidden="true"]')) return false;
        // Check visibility
        return el.offsetParent !== null;
      });
  }

  function handleKeydown(e) {
    if (e.key !== 'Tab') return;

    const focusable = getFocusableElements();
    if (focusable.length === 0) return;

    const first = focusable[0];
    const last = focusable[focusable.length - 1];

    if (e.shiftKey) {
      if (document.activeElement === first) {
        e.preventDefault();
        last.focus();
      }
    } else {
      if (document.activeElement === last) {
        e.preventDefault();
        first.focus();
      }
    }
  }

  containerElement.addEventListener('keydown', handleKeydown);

  return {
    activate() {
      const focusable = getFocusableElements();
      focusable[0]?.focus();
    },
    deactivate() {
      containerElement.removeEventListener('keydown', handleKeydown);
    }
  };
}
```

**Modal Open/Close Focus Flow**

```javascript
let triggerElement = null;

function openModal(trigger) {
  triggerElement = trigger;
  const modal = document.getElementById('modal');
  modal.removeAttribute('hidden');
  modal.removeAttribute('aria-hidden');

  const trap = createFocusTrap(modal);
  trap.activate(); // Focus first focusable inside

  // Close on Escape
  const escapeHandler = (e) => {
    if (e.key === 'Escape') {
      closeModal();
      document.removeEventListener('keydown', escapeHandler);
    }
  };
  document.addEventListener('keydown', escapeHandler);
}

function closeModal() {
  const modal = document.getElementById('modal');
  modal.setAttribute('hidden', '');
  modal.setAttribute('aria-hidden', 'true');
  triggerElement?.focus(); // Return focus to trigger
}
```

---

## Output Format

### Keyboard Flow Documentation Template

Use this to document expected keyboard behavior for a component or flow:

```
## Keyboard Flow: [Component / Flow Name]

### Entry
- How focus enters: [Tab from previous element / programmatic focus / page load]
- First focused element: [element description]
- Focus indicator visible: ✓ Yes / ✗ No

### Navigation Within
| Key | Action | Result | Works? |
|-----|--------|--------|--------|
| Tab | Move forward | Next interactive element | ✓ |
| Shift+Tab | Move backward | Previous interactive element | ✓ |
| Enter | Activate | [specific action] | ✓ |
| Space | Activate / Toggle | [specific action] | ✓ |
| Escape | Close / Cancel | [specific result + where focus goes] | ✓ |
| Arrow keys | [if applicable] | [navigation behavior] | [✓/✗] |
| Home | Jump to first | [specific element] | ✓ |
| End | Jump to last | [specific element] | ✓ |

### Exit & Edge Cases
| Scenario | Behavior | Correct? |
|----------|----------|----------|
| Normal exit | Focus returns to trigger | ✓ |
| Empty state | Focus goes to [element] | ✓ |
| Error state | Focus goes to [error summary / first invalid field] | ✓ |
| Loading state | Focus remains on trigger / loading indicator | ✓ |
| Nested modal open | Inner modal focus trap activates | ✓ |
| Nested modal close | Focus returns to outer modal | ✓ |
```

### Full Keyboard Audit Report

```
## Keyboard & Focus Audit Report

**Page / Component:** [name]
**Date:** [date]
**Auditor:** [name]

### Tab Order Audit
[Table of focus sequence with issues flagged]

| Step | Element | Role | Label | Visible | Expected? | Issue |
|------|---------|------|-------|---------|-----------|-------|
| 1 | Skip link | link | "Skip to main content" | ✓ | ✓ | — |
| 2 | Logo | link | "Company homepage" | ✓ | ✓ | — |
| 3 | Search button | button | "Open search" | ✓ | ✓ | — |
| 4 | .hero-section | — | — | ✓ | ✗ | Non-interactive element receiving focus |
| 5 | First name input | input | "First name (required)" | ✓ | ✓ | — |

### Focus Indicator Assessment
| Element Type | Indicator Visible | Contrast | Size | Windows HC | Issues |
|--------------|------------------|----------|------|-----------|--------|
| Button | ✓ | 4.2:1 | 3px | ✓ | — |
| Text input | ✓ | 3.8:1 | 2px | ✗ | Fails HC Mode |
| Link | ✓ | 5.1:1 | 2px | ✓ | — |

### Complex Focus Scenarios
- [ ] Nested modals: [Description of test and result]
- [ ] Combobox in modal: [Test result]
- [ ] Virtual scrolling: [Test result]
- [ ] Sticky header obscuring focus: [Test result, scroll-margin implemented?]

### Critical Issues (P0)
[Keyboard traps, missing skip links, non-functional controls, broken tab order affecting core functionality]

### Major Issues (P1)
[Missing focus indicators, illogical tab order, poor focus management, lack of Escape key support]

### Minor Issues (P2)
[Suboptimal but functional issues, contrast-borderline focus indicators, non-standard keyboard shortcuts]

### Code Fixes Required
[Specific corrected implementations for each issue]

### Tested Keyboard Flows
[Documented expected behavior for each interactive component]

### Compliance Summary
- WCAG 2.1.1 Keyboard: [Compliant / Non-compliant with X issues]
- WCAG 2.4.3 Focus Order: [Compliant / Non-compliant]
- WCAG 2.4.7 Focus Visible: [Compliant / Non-compliant]
- WCAG 2.4.13 Focus Appearance (AAA): [Compliant / Non-compliant]
```

---

## Cross-References

- **accessibility-code:** Implement focus management and :focus-visible styles
- **screen-reader-scripting:** Combine keyboard flows with ARIA and screen reader testing
- **accessible-forms:** Apply focus management and error prevention to form components
