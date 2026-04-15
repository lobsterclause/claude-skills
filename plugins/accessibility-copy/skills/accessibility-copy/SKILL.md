---
name: accessibility-copy
description: Write or audit accessible content — alt text, ARIA labels, error messages, button labels, link text, form instructions, tooltips, notifications, empty states, and plain language copy. Use this skill whenever the user asks to write or review any UI copy, microcopy, or content strings with accessibility in mind. Trigger on phrases like "alt text", "accessible label", "screen reader", "plain language", "error message", "ARIA label", "empty state copy", "notification text", "link text", reading level, Flesch-Kincaid, SMOG, Gunning Fog, localization, cognitive accessibility, or any request to make copy more inclusive or understandable.
category: audit
related-skills: cognitive-accessibility, alt-text-generator, accessible-forms
---

# Accessibility Copy Skill

You write and audit content that works for everyone — screen reader users, people with cognitive disabilities, non-native speakers, users with dyslexia, and anyone skimming under pressure.

## Core Philosophy

1. **Meaning survives modality** — Content must work without color, without images, without audio, without fine motor precision.
2. **Context is everything** — The same image needs different alt text depending on its purpose and surrounding content.
3. **Plain language is not dumbing down** — It is respect for the reader's time and cognitive load.
4. **Labels are user interfaces** — Every label, button, and error message is a UX decision.
5. **Copy is inclusive by default** — Write for the widest possible audience from the first draft.

---

## Core Framework

### Reading Level Audit Methodology

Plain language means Grade 8–9 reading level per WCAG AAA 3.1.5. Measure readability using multiple formulas:

| Formula | What it measures | Target | Tool |
|---------|------------------|--------|------|
| **Flesch Reading Ease** | General readability (0–100 scale) | 60–70 (Easy) | Hemingway App, Microsoft Word |
| **Flesch-Kincaid Grade** | US school grade level | Grade 8–9 | Hemingway App, Word |
| **SMOG (Simple Measure of Gobbledygook)** | Estimated grade level from polysyllabic words | Grade 8–9 | Free SMOG calculator online |
| **Gunning Fog Index** | Grade level based on complex words and sentence length | Grade 8–9 | readability-score.com |
| **Automated Readability Index (ARI)** | Grade level (accounts for sentence and word length) | Grade 8–9 | Free ARI calculators |
| **Dale-Chall Readability Score** | Appropriate for checking against common word lists | Grade 8–9 | Free Dale-Chall tools online |

**How to audit:**
1. Copy the copy text into Hemingway App (hemingwayapp.com) — instant Flesch-Kincaid and Flesch Reading Ease
2. Run a SMOG calculator on the same text
3. Compare results — if scores diverge (one says Grade 4, another says Grade 12), rewrite for consistency
4. **Target: All formulas point to Grade 8–9 or below**
5. For critical content (error messages, security warnings): aim for Grade 6–7

**Common culprits:**
- Polysyllabic technical terms (utilize vs. use, facilitate vs. help, implement vs. do)
- Sentence length over 20 words (break into 2 sentences)
- Passive voice (is being prevented → is prevented → was prevented)
- Nested clauses and subordinate sentences

**Example audit:**
- Original: "Users are prohibited from utilizing non-conforming authentication mechanisms and may be prevented from accessing protected resources if credentials fail validation."
- Readability: Flesch-Kincaid Grade 12+, Flesch 25 (Very Difficult)
- Rewrite: "Use the correct password. You won't be able to sign in if your password is wrong."
- Readability: Flesch-Kincaid Grade 5, Flesch 85 (Very Easy)

---

### Internationalization & Localization Copy Considerations

Content designed for a single language often breaks in translation. Consider:

**Length expansion:**
- English often compresses significantly — German, Spanish, French may be 15–30% longer
- Design layouts with 40% text expansion buffer
- Avoid hard-coded text widths or character limits without translation padding

**Cultural idioms and metaphors:**
- "It's raining cats and dogs" is meaningless in languages without this idiom
- Avoid sports metaphors, regional references, cultural assumptions
- Replace with universal concepts or literal descriptions

**Number and date formatting:**
- US: 12/31/2024 vs. European: 31/12/2024
- Use ISO 8601 format (YYYY-MM-DD) in tech contexts for clarity
- Show example format in form labels: "Date (MM/DD/YYYY)" or better yet, "Date (e.g., 12/31/2024)"

**Gender and grammar:**
- English is gender-neutral for pronouns; many languages are not
- Avoid assuming user pronouns in copy
- Use "your" instead of gendered pronouns in UI copy
- For help text: use second person ("You can change this") instead of "The user can"

**Abbreviations and acronyms:**
- Define every acronym on first use: "PDF (Portable Document Format)"
- Avoid acronyms in microcopy — users forget them quickly
- For repeated terms, use full form in first instance, then acronym: "PDF files (PDF)"

**Tone across cultures:**
- Direct communication tone (common in English/German) reads as rude in high-context cultures (Japanese, Arabic)
- Conversational English may not translate well — consider formal-but-warm for translation
- Exclamation points signal enthusiasm in English; alarm in other languages

**Copy writing for localization:**
- Write in simple English as the source — shorter sentences, common words
- Avoid phrasal verbs (set up, get back to, look into) — use single root verbs (configure, return, investigate)
- Avoid gerunds where possible (Instead of "Enabling notifications" → "Turn on notifications")
- Use parallel structure in lists — all gerunds, all nouns, all imperative verbs

---

## Process

---

### Alt Text Decision Tree

```
Is the image decorative (purely aesthetic, no information)?
  → alt=""  (empty alt, not missing alt)

Is the image informative (conveys content not in surrounding text)?
  → Write descriptive alt text

Is the image functional (a button, link, or control)?
  → Describe the action, not the image ("Search", not "magnifying glass icon")

Is the image complex (chart, graph, diagram, infographic)?
  → Short alt + long description (figcaption or aria-describedby)
```

### Alt Text Rules

- Do not start with "Image of" or "Photo of" — screen readers already announce it's an image.
- Do start with the most important information.
- For people: describe what's relevant to context. Mention race, gender, disability only if it adds meaning.
- For charts: state the key finding, not a description of visual encoding ("Sales increased 40% YoY" not "Bar chart with blue bars").
- For logos used as links: describe destination ("Acme Corp homepage").
- Keep it under 150 characters when possible. Use long description for complex images.
- Match the tone and voice of surrounding content.

### Alt Text Examples

| Context | Bad | Good |
|---------|-----|------|
| Decorative divider | alt="decorative line" | alt="" |
| Error icon next to form | alt="red X" | alt="Error:" (error text follows) |
| Product photo | alt="shoe" | alt="White leather Nike Air Force 1, low-top, size label on tongue" |
| Bar chart | alt="chart showing data" | alt="Monthly active users grew from 1.2M to 2.1M between January and June 2024" |
| Team photo | alt="group of people smiling" | alt="The Acme design team at their 2024 offsite in Austin" |

---

### ARIA Labels

**When to use aria-label:**
Use when the visible text is insufficient, absent, or redundant with nearby content.

```html
<!-- Icon-only button -->
<button aria-label="Close dialog">✕</button>

<!-- Repeated "Read more" links -->
<a href="/article-1" aria-label="Read more about our accessibility audit process">Read more</a>

<!-- Search input with no visible label -->
<input type="search" aria-label="Search articles">
```

**When NOT to use aria-label:**
- When a visible label already exists — use `<label>` and `for` attribute instead
- To hide or override meaningful visible text (creates confusion for speech input users)
- On non-interactive elements without a specific need

**aria-describedby vs aria-label:**
- `aria-label` replaces the accessible name entirely
- `aria-describedby` adds supplemental description after the name

```html
<!-- Label names it; description adds context -->
<input
  id="email"
  aria-label="Email address"
  aria-describedby="email-hint"
>
<span id="email-hint">We'll only use this to send your receipt.</span>
```

---

### Error Messages: The Four Requirements

Every error message must answer:
1. **What field?** Name the input explicitly.
2. **What's wrong?** Describe the problem precisely.
3. **How to fix it?** Give a specific, actionable instruction.
4. **Where is it?** Programmatically associated with the input (not just near it visually).

### Error Message Patterns

| Situation | Bad | Good |
|-----------|-----|------|
| Required field | "Required" | "Email address is required." |
| Wrong format | "Invalid input" | "Phone number must be 10 digits. Example: 5125551234" |
| Out of range | "Value too high" | "Quantity must be between 1 and 99." |
| Password rules | "Password doesn't meet requirements" | "Password must be at least 8 characters and include one number." |
| System error | "Error occurred" | "We couldn't save your changes. Try again, or contact support at help@example.com." |

### Error Message Writing Rules

- Use plain language. Avoid "invalid", "illegal", "forbidden", "malformed."
- Do not blame the user ("You entered the wrong password" → "That password doesn't match our records.").
- Include examples when format is ambiguous.
- For inline validation, wait until the user leaves the field (not on every keystroke).
- Success messages should confirm the specific action ("Password updated" not just "Success").

---

### Button and Link Labels

**Buttons:**
- Describe the action and its result: "Save changes", "Delete account", "Send message"
- For destructive actions: "Delete account permanently" — make consequences clear
- Avoid: "Submit", "OK", "Yes", "Click here", "Go"
- For icon buttons: always provide aria-label or visually hidden text

**Links:**
- Describe the destination or outcome in context
- Avoid: "Click here", "Read more", "Learn more" (as standalone)
- Good: "Read more about WCAG 2.2 changes", "Download the 2024 accessibility report (PDF, 2.4MB)"
- Note file type and size in link text when linking to non-HTML documents

---

### Form Instructions and Labels

**Visible Labels:**
- Every input must have a persistent visible label — not just placeholder text
- Placeholder text disappears on input and has low contrast; it is not a label
- Labels should be positioned above the input (not beside, for zoom and reflow support)

**Instructions:**
- Put critical instructions before the form, not after
- Put field-level instructions between the label and the input
- Specify format requirements upfront: "MM/DD/YYYY", "10-digit phone number"
- Mark required fields clearly — do not rely on color alone ("Required" text or asterisk with legend)

---

### Plain Language Fundamentals

**Reading level target:**
WCAG AAA 3.1.5 targets lower secondary education level (US Grade 8). Use readability formulas to verify.

**Plain language rules:**
- Use active voice: "You can update your settings" not "Settings can be updated by you"
- Prefer short sentences: aim for 15–20 words average
- Use common words: "use" not "utilize", "help" not "facilitate", "start" not "initiate"
- Define jargon or replace it
- Front-load key information — lead with the action or conclusion
- Use parallel structure in lists
- One idea per sentence

**Audit checklist for copy:**
- [ ] Reading level at or below Grade 8 (use Hemingway App to check)
- [ ] Flesch Reading Ease 60–70 (Easy)
- [ ] No idioms or cultural references that don't translate
- [ ] Abbreviations defined on first use
- [ ] No directional instructions ("see above", "click the box on the right")
- [ ] No sensory-only references ("the red button", "when you hear the chime")
- [ ] Consistent terminology — don't alternate between "save" and "submit" for the same action
- [ ] Notifications tell users what happened and what to do next

---

### Notification and Status Message Patterns

WCAG 4.1.3 requires status messages to be announced without receiving focus.

```html
<!-- Success announcement -->
<div role="status" aria-live="polite">
  Your message was sent successfully.
</div>

<!-- Error announcement -->
<div role="alert" aria-live="assertive">
  Unable to process payment. Please check your card number.
</div>
```

**Notification Message Guidelines:**

| Type | ARIA Role | aria-live | When to use | Example |
|------|-----------|-----------|------------|---------|
| Success | status | polite | Confirmation of successful action | "Your email was sent." |
| Error | alert | assertive | User action failed; needs correction | "Your password doesn't match." |
| Warning | alert | assertive | User should be aware before continuing | "This action cannot be undone." |
| Info | status | polite | Contextual information, not urgent | "3 items added to cart." |
| Loading | status | polite | Process in progress | "Uploading your file..." |

**Write status messages that make sense without visual context:**
- Good: "3 results found"
- Bad: "Results updated" (updated from what? to what?)
- Good: "Payment failed: card expired. Please use a different card."
- Bad: "Failed" (failed at what? what do I do?)

**Empty State Copy Patterns:**

Empty states should not apologize or assume fault.

```
Bad: "No results found. You didn't search correctly."
Good: "No matching articles. Try a different search term."

Bad: "Your cart is empty. You must add items."
Good: "Nothing added yet. Browse our collection or search for a product."

Bad: "No notifications. You're unlucky."
Good: "All caught up! You'll see notifications here when something new happens."
```

---

### Content Hierarchy and Heading Structure Audit

Headings are how screen reader users navigate. Poor heading structure breaks usability.

**Heading Audit Checklist:**
- [ ] Page has exactly one `<h1>` — this is the page title
- [ ] Heading hierarchy is logical — no skipped levels (`<h1>` → `<h2>` → `<h3>`, not `<h1>` → `<h3>`)
- [ ] Headings accurately describe their section
- [ ] No headings used for styling purposes — use CSS classes instead
- [ ] Heading text is unique and meaningful (not "Learn More", "Click Here")
- [ ] Subheadings break content into scannable chunks (one heading every 75–100 words max)

**WCAG 2.4.10 (AAA) example:**
```html
<!-- Good hierarchy -->
<h1>Product Guide</h1>
<h2>Getting Started</h2>
<h3>Installation</h3>
<h3>Configuration</h3>
<h2>Advanced Topics</h2>
<h3>Performance Tuning</h3>

<!-- Bad hierarchy (skip from H1 to H3) -->
<h1>Product Guide</h1>
<h3>Installation</h3>  <!-- Missing H2! -->
```

---

## Reference Guide

---

### Reading Level Tools & Resources

| Tool | Cost | What it measures | Best for |
|------|------|------------------|----------|
| Hemingway App | Free | Flesch Reading Ease, Flesch-Kincaid Grade | Quick, in-browser testing |
| Microsoft Word | Included | Flesch Reading Ease, Flesch-Kincaid Grade | Built into Word (Review → Readability Statistics) |
| SMOG Calculator | Free (online) | SMOG Index (grade level) | Cross-checking grade prediction |
| Gunning Fog Index | Free (online) | Gunning Fog Index (grade level) | Validates across multiple formulas |
| readability-score.com | Free | Multiple formulas (SMOG, Flesch, ARI, Dale-Chall) | Comprehensive readability analysis |
| Grammarly | Free/Premium | Readability, tone, clarity | Integrated checking with tone adjustments |
| CommonLook for Word | Paid | Accessibility + readability | Enterprise document auditing |

### Localization Checklist

When writing copy that will be translated:
- [ ] No abbreviations or acronyms without full form on first use
- [ ] No idioms or metaphors
- [ ] No phrasal verbs (set up, get back to) — use single root verbs
- [ ] Sentences under 20 words
- [ ] Consistent terminology across entire product
- [ ] Avoid humor or cultural references
- [ ] Use numerals (2) not spelled-out words (two)
- [ ] Dates in ISO 8601 format (YYYY-MM-DD) or with spelled-out month
- [ ] No assumptions about user gender or pronouns
- [ ] Allow 40% text expansion in layout designs

---

## Output Format

### When Auditing Existing Copy

```
## Copy Accessibility Review

**Product / Feature:** [name]
**Date:** [date]
**Reviewer:** [name]

### Issues Found

**[ISSUE SEVERITY: CRITICAL / MAJOR / MINOR]** [Issue category]
> Current text: "[quote]"
> Problem: [specific reason this fails accessibility]
> Suggestion: "[improved text]"
> WCAG criterion: [if applicable]
> Reading level impact: [Flesch-Kincaid grade if applicable]

### Approved Copy

- [List of items that pass]

### Notes

[Any context-specific considerations, cultural or regional factors, localization implications]

### Reading Level Summary

| Metric | Target | Actual | Pass/Fail |
|--------|--------|--------|-----------|
| Flesch-Kincaid Grade | ≤ 8 | [x] | ✓/✗ |
| Flesch Reading Ease | 60–70 | [x] | ✓/✗ |
| SMOG Index | ≤ 8 | [x] | ✓/✗ |
| Avg Sentence Length | ≤ 20 words | [x] | ✓/✗ |
```

### When Writing New Copy

Provide:
1. The copy string
2. Its context (ARIA label, alt text, error message, etc.)
3. Reading level metrics (optional but recommended)
4. Reasoning if the choice is non-obvious

---

## Cross-References

- **cognitive-accessibility** — Use when designing for users with ADHD, dyslexia, autism, or cognitive disabilities
- **alt-text-generator** — Use for bulk alt text generation from image descriptions
- **accessible-forms** — Use for form label and validation message patterns

---

## Additional Resources

- WCAG 2.2 Guideline 1.1 (Text Alternatives): https://www.w3.org/WAI/WCAG22/Understanding/text-alternatives.html
- WCAG 2.2 Guideline 3.1 (Readable): https://www.w3.org/WAI/WCAG22/Understanding/readable.html
- WCAG 2.2 Guideline 3.3 (Input Assistance): https://www.w3.org/WAI/WCAG22/Understanding/input-assistance.html
- W3C Plain Language Techniques: https://www.w3.org/WAI/test-evaluate/evaluating-web-accessibility/
- Hemingway App: https://www.hemingwayapp.com/ (readability checking)
- WebAIM Contrast Checker: https://webaim.org/resources/contrastchecker/ (for reading visibility)
