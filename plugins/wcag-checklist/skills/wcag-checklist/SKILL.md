---
name: wcag-checklist
description: Generate a custom WCAG 2.2 checklist scoped to a specific product type, component, user flow, or compliance level. Use this skill whenever the user needs a WCAG checklist, compliance checklist, audit checklist, or accessibility review checklist for any specific context. Generates scoped, actionable checklists—not a dump of all 78 criteria regardless of relevance. Includes effort estimation, severity/impact ratings, plain-language test instructions, and identifies most commonly failed criteria.
category: strategy
related-skills: wcag-compliance-auditor, a11y-test-plan
---

# WCAG Checklist Generator

You generate targeted, useful checklists—not a wall of every WCAG criterion. The value is knowing which criteria apply to a given context, what "pass" actually looks like in practice, and how much effort each criterion requires.

---

## Step 1: Scope the Checklist

Before generating, identify:

1. **Product Type** — web app, marketing site, mobile app, email, PDF, kiosk, intranet, SaaS
2. **Component or Flow** — entire product, specific page type, specific component (form, table, navigation, media player), specific user flow (checkout, onboarding, login)
3. **Compliance Level** — AA (legal baseline), AAA (enhanced), or both
4. **Standards** — WCAG 2.2 only, Section 508, EN 301 549, or combined
5. **Audience** — internal audit, developer handoff, design review, QA testing, client deliverable

If the user hasn't specified, ask. A checklist for a "login form" is more useful than one for a "web app."

---

## Filtering by Product Type

### Static Marketing Site (no forms, no media)
**Exclude:** 1.2.x (audio/video), 2.2.1 (timing), 3.3.x (form errors)
**Elevated Priority:** 1.4.3 (contrast), 1.4.10 (reflow), 2.4.1 (skip links), 3.2.3 (consistent navigation)

### Video/Media Platform
**Include All:** 1.2.x (captions, audio descriptions, transcripts)
**Elevated Priority:** 1.2.1, 1.2.2, 1.2.4, 1.2.5 (prerecorded + live media)

### Form-Heavy App (e-commerce, SaaS, survey)
**Include All:** 3.3.x (form errors, labels, suggestions)
**Elevated Priority:** 1.3.5 (input purpose), 2.5.7 (drag alternatives), 2.5.8 (target size), 3.3.7 (redundant entry), 3.3.8–3.3.9 (accessible auth)

### Data Dashboard / Business Intelligence
**Include:** 1.4.1 (color), 1.4.3 (contrast), 1.4.11 (non-text contrast), tables/charts criteria
**Elevated Priority:** All tabular data and charts need alt text or accessible equivalent

### Mobile App
**Include All:** 2.5.x (pointer, gesture, target size criteria)
**Elevated Priority:** 1.3.4 (orientation), 2.5.1 (pointer gestures), 2.5.4 (motion), 2.5.8 (target size)

### Authentication Flow
**Include All:** 3.3.x (form criteria)
**Elevated Priority:** 3.3.7 (redundant entry), 3.3.8 (accessible auth—no cognitive function tests), 3.3.9 (enhanced auth)

### Email
**Exclude:** 2.1.x (keyboard) where not applicable; 2.2.x (timing) rarely apply
**Elevated Priority:** 1.1.1 (alt text), 1.4.1 (color), 1.4.3 (contrast), semantic HTML (limited)

### PDF Document
**Include:** 1.1.1 (alt text), 1.4.3 (contrast), 2.4.2 (page titles), 3.1.1 (language), 4.1.2 (name/role/value for form fields)
**Exclude:** Most Operable criteria (PDFs have limited keyboard support)

---

## WCAG 2.2 Criteria Reference

### Principle 1: Perceivable

| # | Criterion | Level | Effort | Severity | Commonly Failed |
|---|-----------|-------|--------|----------|-----------------|
| 1.1.1 | Non-text Content | A | M | CRITICAL | YES |
| 1.2.1 | Audio-only / Video-only (Prerecorded) | A | L | CRITICAL | YES |
| 1.2.2 | Captions (Prerecorded) | A | M | CRITICAL | YES |
| 1.2.3 | Audio Description / Media Alternative (Prerecorded) | A | M | CRITICAL | NO |
| 1.2.4 | Captions (Live) | AA | L | MAJOR | YES |
| 1.2.5 | Audio Description (Prerecorded) | AA | M | MAJOR | YES |
| 1.2.6 | Sign Language (Prerecorded) | AAA | L | MINOR | NO |
| 1.2.7 | Extended Audio Description (Prerecorded) | AAA | M | MINOR | NO |
| 1.2.8 | Media Alternative (Prerecorded) | AAA | M | MINOR | NO |
| 1.2.9 | Audio-only (Live) | AAA | S | MINOR | NO |
| 1.3.1 | Info and Relationships | A | M | CRITICAL | YES |
| 1.3.2 | Meaningful Sequence | A | S | MAJOR | YES |
| 1.3.3 | Sensory Characteristics | A | S | MAJOR | NO |
| 1.3.4 | Orientation | AA | S | MAJOR | NO |
| 1.3.5 | Identify Input Purpose | AA | S | MAJOR | YES |
| 1.3.6 | Identify Purpose | AAA | M | MINOR | NO |
| 1.4.1 | Use of Color | A | S | MAJOR | NO |
| 1.4.2 | Audio Control | A | S | MAJOR | NO |
| 1.4.3 | Contrast (Minimum) | AA | S | CRITICAL | YES |
| 1.4.4 | Resize Text | AA | M | MAJOR | YES |
| 1.4.5 | Images of Text | AA | S | MAJOR | NO |
| 1.4.6 | Contrast (Enhanced) | AAA | S | MINOR | NO |
| 1.4.7 | Low or No Background Audio | AAA | S | MINOR | NO |
| 1.4.8 | Visual Presentation | AAA | M | MINOR | NO |
| 1.4.9 | Images of Text (No Exception) | AAA | S | MINOR | NO |
| 1.4.10 | Reflow | AA | M | MAJOR | YES |
| 1.4.11 | Non-text Contrast | AA | S | MAJOR | YES |
| 1.4.12 | Text Spacing | AA | S | MAJOR | NO |
| 1.4.13 | Content on Hover or Focus | AA | M | MAJOR | YES |

### Principle 2: Operable

| # | Criterion | Level | Effort | Severity | Commonly Failed |
|---|-----------|-------|--------|----------|-----------------|
| 2.1.1 | Keyboard | A | M | CRITICAL | YES |
| 2.1.2 | No Keyboard Trap | A | S | CRITICAL | YES |
| 2.1.3 | Keyboard (No Exception) | AAA | M | MINOR | NO |
| 2.1.4 | Character Key Shortcuts | A | S | MAJOR | NO |
| 2.2.1 | Timing Adjustable | A | M | MAJOR | YES |
| 2.2.2 | Pause, Stop, Hide | A | S | MAJOR | YES |
| 2.2.3 | No Timing | AAA | M | MINOR | NO |
| 2.2.4 | Interruptions | AAA | S | MINOR | NO |
| 2.2.5 | Re-authenticating | AAA | M | MINOR | NO |
| 2.2.6 | Timeouts | AAA | M | MINOR | NO |
| 2.3.1 | Three Flashes or Below Threshold | A | M | CRITICAL | NO |
| 2.3.2 | Three Flashes | AAA | M | CRITICAL | NO |
| 2.3.3 | Animation from Interactions | AAA | M | MAJOR | NO |
| 2.4.1 | Bypass Blocks | A | S | MAJOR | YES |
| 2.4.2 | Page Titled | A | S | MAJOR | YES |
| 2.4.3 | Focus Order | A | M | CRITICAL | YES |
| 2.4.4 | Link Purpose (In Context) | A | S | MAJOR | YES |
| 2.4.5 | Multiple Ways | AA | M | MAJOR | NO |
| 2.4.6 | Headings and Labels | AA | S | MAJOR | YES |
| 2.4.7 | Focus Visible | AA | S | CRITICAL | YES |
| 2.4.8 | Location | AAA | S | MINOR | NO |
| 2.4.9 | Link Purpose (Link Only) | AAA | S | MINOR | NO |
| 2.4.10 | Section Headings | AAA | S | MINOR | NO |
| 2.4.11 | Focus Not Obscured (Minimum) | AA | M | MAJOR | YES |
| 2.4.12 | Focus Not Obscured (Enhanced) | AAA | M | MINOR | NO |
| 2.4.13 | Focus Appearance | AAA | M | MINOR | NO |
| 2.5.1 | Pointer Gestures | A | M | MAJOR | YES |
| 2.5.2 | Pointer Cancellation | A | S | MAJOR | YES |
| 2.5.3 | Label in Name | A | S | MAJOR | YES |
| 2.5.4 | Motion Actuation | A | M | MAJOR | YES |
| 2.5.5 | Target Size (Enhanced) | AAA | M | MINOR | NO |
| 2.5.6 | Concurrent Input Mechanisms | AAA | M | MINOR | NO |
| 2.5.7 | Dragging Movements | AA | M | MAJOR | NO |
| 2.5.8 | Target Size (Minimum) | AA | M | MAJOR | YES |

### Principle 3: Understandable

| # | Criterion | Level | Effort | Severity | Commonly Failed |
|---|-----------|-------|--------|----------|-----------------|
| 3.1.1 | Language of Page | A | S | MAJOR | YES |
| 3.1.2 | Language of Parts | AA | S | MAJOR | NO |
| 3.1.3 | Unusual Words | AAA | M | MINOR | NO |
| 3.1.4 | Abbreviations | AAA | M | MINOR | NO |
| 3.1.5 | Reading Level | AAA | M | MINOR | NO |
| 3.1.6 | Pronunciation | AAA | M | MINOR | NO |
| 3.2.1 | On Focus | A | M | MAJOR | YES |
| 3.2.2 | On Input | A | M | MAJOR | YES |
| 3.2.3 | Consistent Navigation | AA | S | MAJOR | YES |
| 3.2.4 | Consistent Identification | AA | S | MAJOR | YES |
| 3.2.5 | Change on Request | AAA | S | MINOR | NO |
| 3.2.6 | Consistent Help | A | S | MINOR | YES |
| 3.3.1 | Error Identification | A | S | MAJOR | YES |
| 3.3.2 | Labels or Instructions | A | S | MAJOR | YES |
| 3.3.3 | Error Suggestion | AA | S | MAJOR | YES |
| 3.3.4 | Error Prevention (Legal, Financial, Data) | AA | M | CRITICAL | YES |
| 3.3.5 | Help | AAA | M | MINOR | NO |
| 3.3.6 | Error Prevention (All) | AAA | M | MINOR | NO |
| 3.3.7 | Redundant Entry | A | S | MAJOR | YES |
| 3.3.8 | Accessible Authentication (Minimum) | AA | M | CRITICAL | YES |
| 3.3.9 | Accessible Authentication (Enhanced) | AAA | M | MINOR | NO |

### Principle 4: Robust

| # | Criterion | Level | Effort | Severity | Commonly Failed |
|---|-----------|-------|--------|----------|-----------------|
| 4.1.1 | Parsing | A | M | MAJOR | NO |
| 4.1.2 | Name, Role, Value | A | M | CRITICAL | YES |
| 4.1.3 | Status Messages | AA | S | MAJOR | YES |

---

## Effort Estimation Scale

- **S (Small)** — Can be fixed in < 1 hour; usually configuration or content change
- **M (Medium)** — 1–4 hours; requires design or code change; moderate complexity
- **L (Large)** — 4+ hours or multiple components; significant refactoring; architectural implications

---

## Severity/Impact Rating Scale

- **CRITICAL** — Complete task blockers; fundamental barrier to access; legal exposure
- **MAJOR** — Meaningfully limits access; affects significant user segment; high legal risk
- **MINOR** — Improvement opportunity; enhances experience; lower legal priority

---

## Most Commonly Failed Criteria (Top 15 by Real-World Failure Rate)

Priority remediation order for most product types:

1. **1.1.1 Non-text Content** (Alt text missing/generic)
2. **1.4.3 Contrast (Minimum)** (Insufficient color contrast)
3. **2.4.3 Focus Order** (Tab order illogical or traps keyboard)
4. **2.4.7 Focus Visible** (Focus indicator missing or obscured)
5. **2.1.1 Keyboard** (Component not keyboard accessible)
6. **2.1.2 No Keyboard Trap** (Focus trapped in component)
7. **1.3.1 Info and Relationships** (Heading structure broken; markup semantics)
8. **3.3.2 Labels or Instructions** (Form inputs lack associated labels)
9. **4.1.2 Name, Role, Value** (Custom components missing accessible name/role/state)
10. **2.4.4 Link Purpose** (Link text unclear or generic)
11. **1.3.5 Identify Input Purpose** (No autocomplete tokens on personal data inputs)
12. **3.3.1 Error Identification** (Error messages lack clear identification)
13. **1.4.11 Non-text Contrast** (UI component borders/icons have poor contrast)
14. **2.4.6 Headings and Labels** (Headings/labels not descriptive)
15. **2.4.1 Bypass Blocks** (No skip navigation mechanism)

---

## Checklist Output Template

```markdown
## Accessibility Checklist
**Product/Component:** [name]
**Standards:** WCAG 2.2 [AA/AAA], Section 508
**Scope:** [what was included/excluded and why]
**Audience:** [internal audit / developer handoff / design review / QA / client deliverable]
**Generated:** [date]

---

### Perceivable — Images, Media, and Content Structure

#### 1.1.1 Non-text Content (A) — SMALL EFFORT, CRITICAL SEVERITY, COMMONLY FAILED

**Description:**
All non-text content (images, icons, charts) has a text alternative that serves the same purpose. Alt text must be accurate, concise (≤125 characters), and context-aware.

**Test Instructions:**
1. Inspect all images in the page/component
2. For each image: Does it have alt text? (Inspect via accessibility inspector or right-click)
3. Is alt text descriptive and context-appropriate? (Not "image", not redundant with adjacent text)
4. For decorative images: Is alt text empty (alt="")? (Not alt="decoration")
5. For images containing text (screenshots, logos with text): Does alt include the text?
6. For charts/graphs/data visualizations: Is there a table, transcript, or accessible equivalent?

**Failure Examples:**
- Image with alt="image" or alt="pic"
- Decorative flourish with alt="decorative line"
- Chart with no alt or table equivalent
- Icon in button with no alt or label

**Pass Example:**
- Product image: alt="Red water bottle with stainless steel cap"
- Screenshot of code: alt="JavaScript function showing const counter = useState(0)"
- Chart: <table> provided as accessible alternative

---

#### 1.3.1 Info and Relationships (A) — MEDIUM EFFORT, CRITICAL SEVERITY, COMMONLY FAILED

**Description:**
All information, structure, and relationships conveyed visually are also conveyed through markup and semantics. This includes heading hierarchy, list structure, form grouping, and emphasis.

**Test Instructions:**
1. Open page in screen reader (NVDA, JAWS, VoiceOver)
2. Listen to page being read aloud. Does the structure make sense without looking at the page?
3. Check heading hierarchy: Are headings nested correctly? (No skipping levels: h1 → h2, not h1 → h3)
4. Check lists: Are list items marked as <ul>/<ol>/<li>? (Not simulated with divs)
5. Check form grouping: Are related form inputs grouped with <fieldset>/<legend>?
6. Check tables: Do <table> tags with <tr>, <th>, <td> exist? (Not layout tables)
7. Check emphasis: Bold/italic done with <strong>/<em>, not <b>/<i>? (Minor point)

**Failure Examples:**
- "## H2 Heading" followed immediately by "#### H4 Heading" (skipped H3)
- Bullet-like visual list simulated with divs and no <ul>
- Form group with no <fieldset> or visual grouping unclear
- Table coded as nested divs for layout

**Pass Example:**
- Heading hierarchy: H1 (page title) → H2 (section) → H3 (subsection)
- List: <ul> <li>Item 1</li> <li>Item 2</li> </ul>
- Form group: <fieldset> <legend>Billing Address</legend> [inputs] </fieldset>

---

[Continue for all applicable criteria...]

---

### How to Use This Checklist

1. **Check each item** — Mark ✓ (Pass), ✗ (Fail), or N/A
2. **Document evidence** — Screenshot, tool output, or description
3. **Log failures** — Assign severity rating (CRITICAL/MAJOR/MINOR) and effort estimate
4. **Group by effort** — Address quick wins first; sequence larger work
5. **Escalate CRITICAL failures** — These block legal/compliance defense

---

### Test Tools Recommended

- **Automated:** axe DevTools, WAVE, Lighthouse, Accessibility Inspector (browser dev tools)
- **Manual (Screen Reader):** NVDA (Windows, free), JAWS (Windows, paid), VoiceOver (Mac, free)
- **Manual (Keyboard):** Test all interactive elements with Tab, Enter, Space, Arrow Keys
- **Manual (Cognitive):** Read page aloud; check for clarity, jargon, complexity

---

### Formats Available

This checklist is available in:
- Markdown (for Notion, GitHub, documentation)
- Plain text (for email or Confluence)
- Spreadsheet (for tracking, team assignment, remediation planning)
- Structured by phase (Design Review / Development / QA Testing)
```

---

## Delivery Formats

Ask which format the user needs:

1. **Markdown** — For Notion, GitHub issues, documentation wikis
2. **Plain Text** — For email, Confluence, or other text-based platforms
3. **Spreadsheet (CSV/Excel)** — For tracking, team assignment, remediation planning, prioritization
4. **Structured by Phase** — Separate checklists for Design Review, Development, QA Testing
5. **Narrative Report** — Paragraph form with explanations and remediation guidance per criterion

---

## Quick-Reference: Scope Decisions

**Question:** "Which criteria apply to my product?"

- **Static marketing site** → Exclude 1.2.x, 2.2.1, 3.3.x (forms). Focus: layout, contrast, navigation, headings.
- **Video platform** → Include all 1.2.x. Elevated priority: captions (1.2.2, 1.2.4), transcripts (1.2.3).
- **Login form** → Include all 3.3.x, 1.3.5, 2.5.7–2.5.8. Exclude media criteria.
- **Data dashboard** → Include color (1.4.1), contrast (1.4.3, 1.4.11), tables. Elevated: charts/data vis need alt.
- **Mobile app** → Include all 2.5.x (gestures, target size, pointer), 1.3.4 (orientation). Focus: touch target size (24×24px minimum).
- **Email** → Exclude 2.1.x (keyboard), 2.2.x (timing). Include: alt text, color contrast, semantic HTML (limited).
- **PDF** → Focus: alt text (1.1.1), contrast (1.4.3), headings (2.4.2), language (3.1.1). Exclude most Operable.

---

## Common Mistakes When Creating Checklists

1. **Omitting effort estimation** — Users don't know if a fix takes 30 minutes or 30 hours.
2. **Generic test instructions** — "Test for accessibility" isn't actionable. Provide specific steps.
3. **Including irrelevant criteria** — A static marketing site doesn't need media player criteria.
4. **Not highlighting commonly failed items** — Use visual emphasis (color, icons) to flag the top 15.
5. **No severity rating** — Users don't know whether to fix a missing caption or skip navigation first.
6. **Missing examples** — "Pass" and "Fail" examples make criteria concrete.
7. **No tool recommendations** — Users need to know how to test (automated tool, keyboard, screen reader).

---

## Cross-References

These skills complement the wcag-checklist:

- **wcag-compliance-auditor** — Execute the full audit that this checklist helps plan
- **a11y-test-plan** — Develop a detailed manual testing plan from this checklist
- **accessibility-advisor** — Frame accessibility checklist results for business stakeholders
- **accessibility-code** — Support engineering team on implementation of failed criteria

---

## Important Notes

- Always ask for scope and audience before generating a checklist. A generic "WCAG 2.2 checklist" is less useful than one scoped to "login form for a mobile banking app, AA compliance, internal QA testing."
- Emphasize that automated tools (Lighthouse, axe) catch ~30% of issues. Manual testing (keyboard, screen reader, cognitive walkthrough) is essential for the other 70%.
- Highlight the "Most Commonly Failed" section—these are the priority remediation items for most products.
- Include effort estimates and severity ratings to help teams prioritize work.
- Provide concrete test instructions, not abstract criteria descriptions.
