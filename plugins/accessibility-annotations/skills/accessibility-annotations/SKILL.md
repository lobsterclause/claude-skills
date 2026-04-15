---
name: accessibility-annotations
description: Generate accessibility annotation content for design handoff — including focus order numbers, ARIA roles and labels, landmark regions, heading levels, alt text, interaction states, keyboard behavior specs, and completeness checklists. Use this skill whenever a designer needs to annotate Figma files or design specs for developer handoff, or when creating accessibility documentation that bridges design and engineering. Includes annotation completeness checklist, visual annotation examples, and developer Q&A. Trigger on phrases like "accessibility annotations", "annotate this design", "design handoff", "Figma annotations", "focus order annotations", "ARIA annotations", "accessibility specs", "handoff documentation", "annotate for developers", "design to dev accessibility", or any request to document accessibility intent in a design. Produces annotation content ready to place in Figma, Zeplin, Storybook, or any design handoff tool.
category: handoff
related-skills: accessibility-code, keyboard-focus-auditor, design-handoff, a11y-test-plan
---

# Accessibility Annotations

Accessibility annotations are the specification layer between design and code. They communicate accessibility intent that isn't visible in the design itself — the things a developer cannot infer from looking at a mockup.

Without annotations, developers guess. Guesses produce inaccessible implementations. Annotations prevent that.

You create annotations that are complete, specific, and developer-ready. You also verify nothing was missed and answer the questions developers ask most.

---

## What Annotations Document

| Annotation Type | What it specifies | Developer impact if missing |
|----------------|-------------------|----------------------------|
| Focus order | The sequence Tab moves through interactive elements | Keyboard users trapped or confused by tab order |
| Heading levels | H1–H6 hierarchy for each text element | Screen reader users can't navigate by heading structure |
| Landmark regions | header, main, nav, aside, footer, section labels | Screen reader users can't quickly jump to sections |
| ARIA roles | role for custom and non-semantic components | Screen reader announces generic "div" instead of "button" |
| Accessible names | aria-label, aria-labelledby, alt text for each element | Screen reader announces elements without labels ("button" with no name) |
| Interactive states | hover, focus, active, disabled, error, selected, expanded | Developers build visually but miss semantic state updates |
| Keyboard behavior | What keys do what for each component | Keyboard-only users can't use complex components (combobox, tabs, etc.) |
| Reading order | DOM order when it differs from visual order | Screen reader reads content in wrong sequence |
| Live regions | aria-live, role=alert, role=status placement | Dynamic content updates (errors, success messages) announced silently |
| Skip links | Presence and destination | Keyboard users must tab through entire navigation repeatedly |

---

## Annotation Completeness Checklist

Before handoff, verify you've annotated everything needed. Use this checklist:

**Structural Elements**
- [ ] All headings labeled with level (H1, H2, H3, etc.)
- [ ] One and only one H1 on page
- [ ] Heading hierarchy is logical (no H2 → H4 skips)
- [ ] All regions identified: nav, main, header, footer, aside, section
- [ ] All regions with multiple instances labeled distinctly (e.g., "Main navigation", "Footer navigation")
- [ ] Skip link present and destination annotated

**Interactive Elements**
- [ ] Every button labeled with accessible name
- [ ] Every link has descriptive accessible name (not "click here" or "read more")
- [ ] Icon-only buttons have aria-label
- [ ] All button states annotated: default, hover, focus, active, disabled, loading
- [ ] Toggle buttons have aria-pressed state
- [ ] Links that open new windows/tabs noted

**Forms**
- [ ] Every form field has visible label
- [ ] Every required field marked with required indicator AND legend explaining indicator
- [ ] Hint text linked via aria-describedby (if present)
- [ ] Error message format specified (when does it appear? How is it announced?)
- [ ] Error state colors + additional visual indicators (icon, text)
- [ ] Validation timing: real-time vs. on-blur vs. on-submit

**Complex Components**
- [ ] Focus order within component documented (e.g., arrow keys in tabs)
- [ ] Expanded/collapsed state (aria-expanded) for collapsibles
- [ ] Tab list: aria-selected and tabindex management
- [ ] Accordion: button with aria-expanded, panel with aria-labelledby
- [ ] Combobox: popup state (aria-expanded), list items (option role), selection behavior
- [ ] Modal/Dialog: focus trap, Escape closes, focus restoration
- [ ] Carousel: pause/play control, skip button, announcement when slides change

**Images & Media**
- [ ] All informative images have alt text (or planned alt text)
- [ ] All decorative images have alt="" (empty, not omitted)
- [ ] Functional images (logos, icons that are links) have purpose-based alt
- [ ] Complex images (charts, infographics) have long description or caption reference
- [ ] Videos have captions planned or noted

**Motion & Animation**
- [ ] Auto-playing content has visible pause control
- [ ] Pause control is keyboard accessible
- [ ] Reduced motion variant specified (CSS @media prefers-reduced-motion)
- [ ] Critical animations have keyboard alternatives or can be skipped

**Reading Order**
- [ ] DOM order matches visual reading order (left to right, top to bottom)
- [ ] If visual and logical order differ, documented with note for developer

**Colors & Contrast**
- [ ] All interactive focus indicators meet 3:1 contrast (AA) or 4:1 (AAA)
- [ ] Non-text UI components (borders, icons) meet 3:1 contrast vs. background
- [ ] No information conveyed by color alone (always add text, icon, or pattern)

**Mobile/Touch**
- [ ] Touch targets meet 44x44px minimum (WCAG 2.5.5)
- [ ] Gesture alternatives documented (e.g., swipe left = arrow key left)
- [ ] Screen reader testing planned for iOS/Android

---

## Annotation Content by Component Type

### Text Elements

**Heading with context:**
```
HEADING LEVEL: H2
Text: "Account Settings"
Note: Page H1 is in global header. This is first heading in main content.
Why: Users navigate by heading structure; multiple H2s are expected on this page.
```

**Decorative text:**
```
ROLE: Presentation (decorative only)
Alt: None required
Note: This is a divider or visual accent; no informational value
```

---

### Images

**Informative image (bar chart):**
```
CLASSIFICATION: Informative — data visualization
Alt text: "Bar chart showing monthly active users grew from 1.2M in January to 4.8M in June"
Long description: See data table below chart (ID=chart-data-table) OR embedded as caption
WCAG: 1.1.1 Non-text Content (A)
Why: Chart conveys important data; short alt insufficient; long description necessary.
```

**Decorative image:**
```
CLASSIFICATION: Decorative — visual accent
Alt: "" (empty, NOT omitted)
Note: Remove alt attribute or set to empty string. Do NOT use alt="image" or alt="photo"
```

**Functional image (logo as link):**
```
CLASSIFICATION: Functional — link to homepage
Alt: "Acme Corp homepage"
Note: Describes link destination, NOT the appearance of the logo. Do NOT say "Acme Corp logo"
Why: When users jump to images, they need to understand where the link goes.
```

---

### Interactive Elements

**Standard button:**
```
Role: button
Accessible name: "Delete account permanently"
State: Not a toggle (aria-pressed not applicable)
Keyboard: Enter or Space activates
Visual states:
  Default: background #1a1a1a, text #ffffff
  Hover: background #333333
  Focus: 3px solid #005fcc outline, 2px offset
  Active: background #000000
  Disabled: background #e0e0e0, text #9e9e9e, cursor not-allowed
Interaction: Triggers confirmation dialog before executing
Note: Icon (trash can) is purely visual; entire label is "Delete account permanently"
```

**Toggle button (Dark mode):**
```
Role: button
Accessible name: "Dark mode"
State: aria-pressed="false" (light mode active) / "true" (dark mode active)
Keyboard: Enter or Space toggles
Visual states:
  Off (aria-pressed="false"): background #f0f0f0, border #767676
  On (aria-pressed="true"): background #1a1a1a, border #ffffff
  Focus: 3px solid #005fcc outline
Interaction: Immediately toggles app theme; preference saved to localStorage
WCAG: 4.1.2 Name, Role, Value (A)
```

**Icon-only button (Close dialog):**
```
Role: button
Visible label: None (X icon only)
Accessible name: aria-label="Close dialog"
Note: Icon alone is insufficient — aria-label REQUIRED.
      Do NOT omit aria-label; do NOT use aria-label="X"
Size: 32x32px (touch target meets 44x44px with padding)
Keyboard: Enter, Space, or Escape closes dialog
```

**Link with context:**
```
Role: link
Accessible name: "Read the full 2024 Accessibility Report (PDF, 2.4MB)"
Note: Includes file type and size. Not "read more" (vague) or "link" (redundant).
Why: Screen reader users jumping to links need to know destination and file type.
Visual: Underlined, colored #005fcc, focus outline 3px solid #005fcc
```

---

### Form Fields

**Text input with label and hint:**
```
Label: "Email address" (persistent visible label, NOT placeholder)
Label position: Above input (left-aligned, same x-position as input)
Input type: email
Autocomplete: email
Required: Yes — marked with red asterisk (*) + legend "* indicates required field"
Hint text: "We'll only use this to send your receipt"
Hint connection: aria-describedby="email-hint" linking input to hint text
Placeholder: None (or if present, supplemental only — "name@example.com")
WCAG: 1.3.1, 3.3.2 Labels or Instructions (A)
Why: Persistent labels stay visible when user focuses; placeholders disappear.
```

**Error state:**
```
Error condition: Invalid email (no @ symbol)
Error visibility: Input border changes to 2px solid #d32f2f (red)
Error icon: Red X or ! icon appears to right of input
Error message: "Email address must include an @ symbol. Example: name@example.com"
Error connection: aria-invalid="true" + aria-describedby="email-error"
Error announcement: When user focuses field or submits: aria-invalid + error message both announced
WCAG: 3.3.3 Error Suggestion (AA), 4.1.3 Status Messages (AA)
```

**Radio button group:**
```
Group label: "Preferred contact method" (legend for fieldset)
Required: Yes — specified in legend and on individual radios
Options: 
  - Email
  - Phone (with phone number format hint below)
  - Text message
Keyboard: Tab to group, then arrow keys select within group
ARIA: fieldset > legend for group label; name attribute same for all radios in group
Visual: Selected radio background #1a1a1a, unselected #ffffff with 1px border
WCAG: 1.3.1 Info and Relationships (A)
```

**Checkbox:**
```
Label: "I agree to the terms" (tappable label, not just checkbox itself)
Required: No (optional feature)
Default: Unchecked
Checked state: Background #1a1a1a, checkmark white
Focus state: 3px solid #005fcc outline
ARIA: aria-checked="false" / "true" (if JavaScript-managed) or native checked attribute
WCAG: 1.3.1 (A), 2.5.5 Target Size (AAA) — 44x44px including label
```

**Select dropdown:**
```
Label: "State" (above select, left-aligned)
Autocomplete: address-level1
Default option: "Select a state" (not blank; blank is confusing for screen readers)
Options: Alphabetical or by region (documented)
Visual: 1px border #767676, background white, text #1a1a1a
Focus: 3px solid #005fcc outline
WCAG: 1.3.1 (A), 2.4.3 Focus Order (A)
Why: Meaningful default option (not blank) helps screen reader users understand what to do.
```

---

### Navigation

**Primary navigation:**
```
Landmark: <nav>
Label: aria-label="Main navigation"
Position: Typically top of page, in header
Contents: Links to main sections
Visual: Horizontal list at 1024px+, hamburger menu at mobile
Dropdown menus: Button role (not menu role) with aria-expanded, arrow keys to open/close
WCAG: 1.3.1 (A), 2.4.1 Bypass Blocks (A)
Note: If secondary nav exists (e.g., user account menu), label it distinctly.
```

**Footer navigation:**
```
Landmark: <nav>
Label: aria-label="Footer navigation"
Note: Multiple navs on same page MUST have unique labels.
Contents: Links to legal, company info, social media
```

**Breadcrumb:**
```
Landmark: <nav>
Label: aria-label="Breadcrumb"
Current page: aria-current="page" on last item (semantic marker, not just visual)
Structure: Home > Products > Wireless Headphones (last = current page)
WCAG: 2.4.8 Location (AAA)
Why: Helps users understand where they are in site hierarchy.
```

**Skip link:**
```
Present: Yes, visible on Tab (first focusable element)
Text: "Skip to main content"
Destination: ID of <main> element (e.g., skip link href="#main-content")
Keyboard: Tab → Enter activates
Visual: Appear on focus only (or persistent, developer's choice)
WCAG: 2.4.1 Bypass Blocks (A)
Why: Keyboard users don't have to tab through entire navigation repeatedly.
```

---

### Modal / Dialog

```
Role: dialog
aria-modal: true (prevents pointer events outside; announces to SR)
Label: aria-labelledby="dialog-title" (points to dialog's H2 or other heading)
Description: aria-describedby="dialog-description" (optional; for longer explanations)
Focus on open: First interactive element inside dialog (usually first button)
Focus on close: Saved to element that opened dialog; focus restored there
Keyboard escape: Escape key closes dialog
Keyboard trap: Tab cycles within dialog only; Shift+Tab reverses
Visual: Semi-transparent overlay behind dialog, dialog centered on screen
Content: Title, description, at least one action (Close, Cancel, Confirm)
WCAG: 2.1.2 No Keyboard Trap (A), 2.4.3 Focus Order (A)
Developer note: Implement focus trap with JavaScript; restore focus on close.
```

---

### Dropdown / Disclosure / Collapsible

```
Trigger:
  Role: button
  aria-expanded: "false" (collapsed) / "true" (expanded)
  aria-controls: "panel-id" (points to panel being controlled)
  Keyboard: Enter/Space toggles; Escape closes (optional but helpful)

Panel:
  id: Matches aria-controls value on trigger
  hidden: Attribute or CSS display:none when collapsed
  Role: Not necessary; trigger's aria-expanded is sufficient
  ARIA: aria-labelledby="trigger-id" (if panel is unlabeled; optional)

Keyboard: 
  Tab to trigger, Enter/Space toggles, Escape closes
  Arrow keys NOT used (unlike tabs or combobox)

Visual:
  Trigger shows down chevron when collapsed (expanded="false")
  Trigger shows up chevron when expanded (expanded="true")
  Chevron rotation is visual indicator; not required for screen readers

WCAG: 4.1.2 Name, Role, Value (A)
```

---

### Tabs

```
Tab list:
  Role: tablist
  Label: aria-label="[section name]" (e.g., "Account settings tabs")
  Note: If unlabeled tabs, consider adding aria-label for clarity

Each tab:
  Role: tab
  aria-selected: "true" (active) / "false" (inactive)
  aria-controls: "[id of associated panel]"
  tabindex: "0" (active tab only) / "-1" (inactive tabs)
  Keyboard: Arrow Left/Right moves between tabs; Enter/Space activates focused tab
  Visual: Active tab has background color, underline, or border; inactive tabs are lighter

Each panel:
  Role: tabpanel
  aria-labelledby: "[id of associated tab]"
  hidden: Attribute when inactive; display:none or visibility:hidden via CSS
  Content: Any content (text, form, images, etc.)

WCAG: 1.3.1 (A), 2.4.3 Focus Order (A), 4.1.2 Name, Role, Value (A)
Example: "Account Settings" tab list with three tabs:
  1. Profile (aria-selected="true", aria-controls="panel-profile")
  2. Security (aria-selected="false", aria-controls="panel-security")
  3. Notifications (aria-selected="false", aria-controls="panel-notify")
```

---

### Accordion

```
Each trigger:
  Role: button
  aria-expanded: "false" / "true"
  aria-controls: "[id of panel]"
  Text: Descriptive heading (e.g., "Billing Address", "Shipping Address")
  Keyboard: Tab moves between triggers; Enter/Space toggles; Escape closes (optional)
  Visual: Chevron rotates or changes icon; text may bold/underline

Each panel:
  id: Matches aria-controls on trigger
  hidden: When trigger's aria-expanded="false"
  aria-labelledby: "[id of trigger button]" (optional; trigger already labels it)
  Content: Any content

WCAG: 4.1.2 Name, Role, Value (A)
Example pattern (common e-commerce FAQs):
  "How do I return an item?" (trigger) → panel with return policy
  "What's your warranty?" (trigger) → panel with warranty info
```

---

### Data Table

```
Caption: "Q2 2024 Revenue by Region"
  (Appears above table; aria-labelledby on table can point to caption)

Column headers (TH elements):
  scope="col" on all TH in header row
  Text: "Product", "Q1", "Q2", "Q3", "Q4"

Row headers (optional; for tables with labeled rows):
  scope="row" on first TD in each row (if applicable)
  E.g., "North America", "Europe", "Asia Pacific"

Sortable columns (if applicable):
  aria-sort: "none" (default) / "ascending" / "descending"
  Applied to sortable TH elements
  JavaScript updates aria-sort when user clicks header

Announcement after sort:
  Use live region (aria-live="polite") to announce sort change:
  "Table sorted by Revenue, descending"

WCAG: 1.3.1 (A), 1.3.2 Meaningful Sequence (A)
```

---

## Focus Order Annotations

Number every interactive element in the sequence Tab should follow. Start from 1.

**Rules:**
- Numbers follow logical reading order (left to right, top to bottom in LTR layouts)
- Skip decorative and non-interactive elements
- Within a component (radio group, tab list), note that arrow keys handle internal navigation — only one Tab stop for the group
- Modal dialogs: start numbering from 1 within the dialog; focus trap prevents tabbing outside
- Number groups of related elements as a single stop when appropriate

**Annotation format on design:**

```
Tab stop 1: Skip link → Main content
Tab stop 2: Search input
Tab stop 3: Submit search button
Tab stop 4: Product filters (fieldset with checkboxes)
  Internal navigation: Tab focuses fieldset legend, arrow keys select checkboxes
Tab stop 5: Product grid
  Internal navigation: Arrow keys navigate products; Enter selects
Tab stop 6: Pagination — Previous page
Tab stop 7: Pagination — Next page
Tab stop 8: Footer newsletter signup
```

**Developer note:** "Arrow keys navigate within components (tab stop 5); Tab moves between Tab stops."

---

## Keyboard Behavior Specifications

For each component, specify exactly what keys do what:

### Common Patterns

**Button:**
```
Enter or Space activates (clicks)
```

**Link:**
```
Enter navigates; Space does nothing (native link behavior)
```

**Radio group:**
```
Tab: Moves focus to group (lands on selected radio or first radio)
Arrow Right/Down: Moves to next radio; wraps to first at end
Arrow Left/Up: Moves to previous radio; wraps to last at beginning
Space: Selects focused radio (if not already selected)
```

**Combobox (autocomplete):**
```
Tab: Moves to combobox input
Type: Filters list; opens if closed; does not move focus to list
Down Arrow: Opens list if closed; moves focus to first option
Up Arrow: Opens list if closed; moves focus to last option
Enter: Selects focused option; closes list
Escape: Closes list; clears input (or retain it, depending on design)
```

**Tabs:**
```
Tab: Moves focus to active tab, then into panel content
Arrow Right/Down: Moves focus to next tab (wraps at end)
Arrow Left/Up: Moves focus to previous tab (wraps at beginning)
Home: Moves focus to first tab
End: Moves focus to last tab
Enter/Space: Activates focused tab (if not already active) — optional; some tabs auto-activate on focus
```

**Modal dialog:**
```
Escape: Closes dialog
Tab: Cycles through focusable elements within dialog; wraps at end
Shift+Tab: Reverses through elements
(No focus escapes dialog while open)
```

---

## Annotation Completeness Checklist (Visual Example Description)

Use this to describe visual annotations when you can't show images:

**Focus Order Numbers**
Imagine small numbered circles (1, 2, 3...) placed at or near each interactive element. The number indicates the sequence Tab will move through.

**Color Coding**
- Blue outline: Focus indicator (what you see when you Tab to element)
- Green highlight: Mandatory annotations (must not miss)
- Yellow highlight: Recommended annotations (important for quality)

**State Indicators**
For components with multiple states (collapsed/expanded, selected/unselected), show each state separately or with callout boxes:
```
Accordion trigger — COLLAPSED STATE:
  Text: "Billing Address"
  Icon: Down chevron ↓
  Aria-expanded: false

Accordion trigger — EXPANDED STATE:
  Text: "Billing Address" (same text)
  Icon: Up chevron ↑
  Aria-expanded: true
```

---

## Developer Q&A: Answers to Common Questions

**Q: Do I need to code aria-label if the button text is visible?**
A: No. Use visible text only. aria-label should only be used when text is NOT visible (icon-only buttons, invisible labels). Visible + aria-label = redundancy and confusion.

**Q: What's the difference between aria-label and aria-labelledby?**
A: aria-label = hidden text you provide. aria-labelledby = points to visible text elsewhere on page. Prefer aria-labelledby (uses existing text), but aria-label is fine for icon buttons.

**Q: Should I use role="menuitem" for navigation dropdowns?**
A: No. Use button + aria-expanded + arrow keys. The "menu" role implies a desktop application menu (File, Edit, etc.), not web navigation. This is an AT quirk difference; use button for web navs.

**Q: When do I use role="alert" vs. aria-live="assertive"?**
A: They're equivalent (role="alert" = aria-live="assertive" + aria-atomic="true"). Use role="alert" for brevity. Both interrupt screen reader immediately; use for errors and urgent messages only.

**Q: Do I need aria-current="page" if I'm using CSS to visually highlight current page?**
A: Yes. Visual styling doesn't communicate to screen readers. aria-current="page" is semantic and tells screen reader "you are here." Always add both.

**Q: How do I handle optional vs. required form fields?**
A: Use required attribute + visible indicator (red asterisk) + legend explaining the indicator. Avoid relying on color alone. In aria: aria-required="true" can supplement if needed, but required attribute is sufficient.

**Q: Should placeholder text be the label?**
A: Never. Placeholders disappear when user types; screen reader users lose context. Always use persistent visible label (above or beside input) + aria-label if you want aria-label. Placeholder can be supplemental hint.

**Q: When tabbing through a combobox, why are arrow keys needed?**
A: Tab moves focus between components. Arrow keys operate within the current component (the list). Users Tab to the combobox input, type to filter, then arrow keys navigate the list. After selecting, Tab moves to next component.

**Q: What's the minimum touch target size?**
A: 44x44px (WCAG 2.5.5, AAA). For interactive elements, include padding if the element itself is smaller. E.g., icon might be 24x24px, but with 10px padding around it = 44x44px total.

**Q: How do I announce dynamic updates (filter results, load more)?**
A: Use aria-live="polite" + aria-atomic="true" on container that updates. Screen reader will announce changes without moving focus. For errors: role="alert" (immediate interrupt). For counts: "5 results found" in live region.

**Q: Should I use fieldset+legend for ALL groups or just radio/checkbox groups?**
A: Best practice: use fieldset + legend for any grouped form elements (radios, checkboxes, related inputs). For single inputs, just label + input.

**Q: What about skip links on mobile?**
A: Include skip link (it's still useful for keyboard users), but make sure it doesn't cover content on small screens. Show on focus only is acceptable for mobile. Touch users (VoiceOver iOS) don't use Tab, but consider keyboard-only mobile users.

---

## Developer Handoff Tool Integrations

When placing annotations in design tools:

**A11y Annotation Kit** (Figma Community, by CVS Health)
- Pre-built annotation stickers for ARIA roles, landmarks, keyboard behaviors
- Compatible with this skill's content format
- Colors: Blue = focus, Green = mandatory, Yellow = recommended

**Accessibility Bluelines** (Figma Community)
- Text-based annotations; minimal visual clutter
- Good for presentations and handoffs

**Intopia Accessibility Annotation Kit** (Figma Community)
- Comprehensive; includes state indicators
- Color-coded by component type

**Manual Figma method:**
- Create sticky notes with annotation text
- Link to spec document (Google Doc, Notion) with full annotations
- Use frame names to indicate focus order: "1-Skip Link", "2-Search Input", etc.

---

## Cross-References

- **accessibility-code:** Implement annotations in code; review code against annotations
- **keyboard-focus-auditor:** Test focus order and keyboard behavior against annotations
- **design-handoff:** Create comprehensive design specs; accessibility annotations are part of complete handoff
- **a11y-test-plan:** Use annotations as test case reference; compare design intent to implementation
