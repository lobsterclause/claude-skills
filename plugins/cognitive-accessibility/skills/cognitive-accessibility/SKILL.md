---
name: cognitive-accessibility
description: Audit UI, content, and interactions for cognitive accessibility — including cognitive load, plain language, consistent patterns, error prevention, memory demands, distraction, and COGA (Cognitive and Learning Disabilities Accessibility) guidance. Use this skill whenever the user needs to evaluate or improve accessibility for users with cognitive, learning, or neurological disabilities — including ADHD, dyslexia, autism, memory impairment, anxiety, brain injury, or age-related cognitive decline. Trigger on phrases like "cognitive accessibility", "cognitive load", "plain language audit", "COGA", "accessible for ADHD", "accessible for dyslexia", "reading difficulty", "memory load", "distraction", "consistent UI", "error prevention", "timeout", "notifications", "session management", "cognitive disability", "neurodivergent", "learning disability", "scoring", "0-10 scale", or any request to make content or UI easier to understand and use. Covers WCAG 2.2 AAA cognitive criteria, COGA supplemental guidance, and plain language standards.
category: audit
related-skills: accessibility-copy, motion-auditor, older-audiences-auditor
---

# Cognitive Accessibility Auditor

Cognitive accessibility is the most underserved dimension of accessibility work. Automated tools don't touch it. Standard WCAG audits often skip the AAA cognitive criteria. Yet cognitive, learning, and neurological disabilities affect a larger share of the population than any other disability category.

This skill audits the full cognitive accessibility spectrum: reading and language, memory and attention, consistency and predictability, error handling, timeout and session management, notification overload, and anxiety-triggering dark patterns.

## Philosophy

Cognitive accessibility is not a checklist — it is a responsibility to recognize how product design affects users with ADHD, dyslexia, autism, memory impairment, anxiety, and age-related cognitive decline. Every complex form, every timeout, every dark pattern, and every wall of text causes real harm to real users.

This skill provides:
- A **0–10 cognitive load scoring system** to quantify burden
- **Weighted dimension assessment** across reading, memory, attention, and emotional load
- **Specific WCAG AAA and COGA patterns** to audit and improve
- **Dark pattern detection** that deliberately exploits cognitive vulnerabilities
- **Plain language frameworks** with reading level targets
- **Timeout and session management** audit criteria
- **Notification and interruption** overload assessment

---

## Who This Covers

- **Dyslexia** — ~5-10% of population; disrupted reading fluency, letter/word confusion, text formatting sensitivity
- **ADHD** — ~5% of population; distraction, attention management, time pressure, impulsivity traps, decision paralysis
- **Autism** — ~1% of population; literal language, predictability, sensory sensitivity, social communication patterns
- **Memory impairment** — ~30% of adults over 80; short-term memory load, session persistence, wayfinding
- **Anxiety disorders** — ~2-3% of population; irreversible actions, urgency language, dark patterns, social pressure
- **Acquired brain injury/stroke** — ~1% of population; processing speed, fatigue, simplified navigation
- **Age-related cognitive decline** — affects most adults by 70+; combination of all above
- **Low literacy** — ~20% of adult population; reading level, vocabulary, sentence complexity
- **Non-native language users** — ~26% of US population; idioms, cultural references, abbreviations

---

## WCAG 2.2 Cognitive & Related Criteria

### Level A
- **3.2.1 On Focus** — Focus does not trigger context change
- **3.2.2 On Input** — Input does not trigger unexpected context change
- **3.3.1 Error Identification** — Errors identified in text
- **3.3.2 Labels or Instructions** — Labels or instructions for inputs
- **2.2.1 Timing Adjustable** — Time limits adjustable or extendable
- **3.3.7 Redundant Entry** — Previously entered info auto-populated

### Level AA
- **3.3.3 Error Suggestion** — Correction suggestions provided
- **3.3.4 Error Prevention** — Submissions reversible, checkable, or confirmable
- **3.2.3 Consistent Navigation** — Navigation consistent across pages
- **3.2.4 Consistent Identification** — Same-function components identified consistently
- **3.3.8 Accessible Authentication (Minimum)** — No cognitive function test for auth

### Level AAA
- **3.1.3 Unusual Words** — Mechanism to identify unusual words/jargon
- **3.1.4 Abbreviations** — Mechanism to identify abbreviations
- **3.1.5 Reading Level** — Supplemental content for Grade 8+ text
- **3.1.6 Pronunciation** — Mechanism for ambiguous pronunciation
- **3.2.5 Change on Request** — Context changes only on user request
- **3.3.5 Help** — Context-sensitive help available
- **3.3.6 Error Prevention (All)** — All submissions reversible or confirmable
- **3.3.9 Accessible Authentication (Enhanced)** — No cognitive function test at all
- **2.2.3 No Timing** — No time limits
- **2.2.4 Interruptions** — Interruptions can be postponed
- **2.2.6 Timeouts** — Users warned of data loss from inactivity

---

## Cognitive Load Scoring System (0–10 Scale)

Quantify cognitive burden on a 0–10 scale across five dimensions:

| Dimension | Score | Definition |
|-----------|-------|-----------|
| **Reading** | 0–10 | Grade 8 is 0; Grade 16+ is 10 |
| **Memory** | 0–10 | 0 items held = 0; 7+ items = 10 |
| **Attention** | 0–10 | No distractions = 0; multiple simultaneous interruptions = 10 |
| **Decision** | 0–10 | Single clear action = 0; 7+ complex choices = 10 |
| **Emotional** | 0–10 | Safe/clear = 0; urgent/dark patterns = 10 |

**Total Cognitive Load = (Reading + Memory + Attention + Decision + Emotional) / 5**

**Interpretation:**
- 0–2: Minimal cognitive load; accessible to most users
- 3–5: Moderate load; acceptable with clear guidance
- 6–7: High load; requires significant improvement for accessibility
- 8–10: Extreme load; likely inaccessible to users with cognitive disabilities

### Dimension Details

**Reading Load (0–10)**

| Grade | Score | Description |
|-------|-------|-------------|
| 6 or below | 0 | Plain language; accessible to most adults |
| 8 | 2 | WCAG AAA target |
| 10 | 4 | Corporate/standard writing |
| 12 | 6 | Formal/legal writing |
| 14 | 8 | Technical documentation |
| 16+ | 10 | Specialized academic text |

**Tool:** Use a readability tool (Flesch-Kincaid Grade Level, Automated Readability Index) to calculate actual grade level.

**Memory Load (0–10)**

Count working memory items the user must hold simultaneously:

```
Items in working memory = Choices presented + Information from previous step
  + Codes/passwords to remember + Progress indicators needed + Simultaneous
  form fields visible
```

Miller's Law: humans hold ~7±2 chunks. Score by total items:

- 0–3 items: Score 0–2
- 4–5 items: Score 3–4
- 6–7 items: Score 5–6
- 8+ items: Score 7–10

**Attention Load (0–10)**

Count simultaneous attention demands:

```
Attention load = Auto-playing media + Moving animations + Notifications
  + Simultaneous CTAs + Ads/distracting content near task area
```

- 0 distractions: Score 0
- 1 distraction: Score 2
- 2 distractions: Score 5
- 3+ distractions: Score 8–10

**Decision Load (0–10)**

Count required decisions or choices:

- Single clear action: Score 0
- 2–3 options: Score 2
- 4–5 choices: Score 4–5
- 6–7 choices: Score 6–7
- 8+ simultaneous choices: Score 8–10

Also assess complexity: Simple yes/no is lower than "choose from unclear options with no explanation."

**Emotional Load (0–10)**

Assess psychological burden:

- Clear, safe, predictable UI: Score 0
- Minor uncertainty (unclear labels): Score 2
- Dark patterns (confirmshaming, roach motel): Score 5–6
- High-pressure tactics (scarcity, urgency, social proof): Score 7–8
- Irreversible actions without confirmation: Score 8–10
- Combined dark patterns: Score 9–10

---

## Process

### Step 1: Audit Reading Level and Language

**Reading Level Analysis**

Target Grade 8 or below for primary content. Use a readability calculator (Flesch-Kincaid, Coleman-Liau, etc.) to measure actual grade level.

**Plain Language Checklist:**
- [ ] Active voice dominant (80%+ of sentences)
- [ ] One idea per sentence (avoid complex compound sentences)
- [ ] Common words preferred over formal equivalents ("use" not "utilize", "help" not "assist")
- [ ] Instructions front-loaded (action first, explanation second)
- [ ] Positive framing ("Enter your date" not "Don't leave date blank")
- [ ] No idioms without explanation ("touch base", "circle back", "bandwidth")
- [ ] No cultural references that don't translate
- [ ] Abbreviations defined on first use
- [ ] Consistent terminology (one word for one concept)
- [ ] Numbers written as digits not words (except at sentence start)

**Typography & Readability:**
- Line length: 50–75 characters (WCAG AAA 1.4.8)
- Line height: minimum 1.5× font size
- Paragraph spacing: minimum 2× font size
- Letter spacing: user can override to 0.12em without loss
- Justified text: avoid — creates irregular word spacing that disrupts reading for dyslexia
- ALL CAPS: avoid for body text — harder to read
- Italics: use sparingly — disrupts reading for dyslexia
- Font choice: avoid decorative fonts; prefer fonts with distinct letterforms (b/d/p/q clearly different)

### Step 2: Assess Memory and Working Memory Load

**Cognitive Load Measurement Framework**

Count items the user must hold in working memory at any point:

1. **Simultaneous Choices:** How many UI options visible at once?
2. **Information from Previous Screens:** What info from step 1 is needed at step 2? (Is it shown or must user remember?)
3. **Codes/Passwords:** Any memorization required?
4. **Progress Indicators:** Is current progress shown?
5. **Form Fields Visible:** How many inputs on one screen?

**Safe Thresholds:**
- ✓ 0–3 simultaneous items: Low memory load
- ✓ 4–5 items: Moderate; acceptable with clear labels
- ✗ 6–7 items: High; requires improvement
- ✗ 8+ items: Critical; redesign needed

**Wayfinding and Orientation (WCAG 2.4.8 AAA)**
- Does the user always know where they are? (Page title, breadcrumbs, section headers)
- Are landmark regions labeled for navigation?
- Is progress indicated in multi-step flows?

### Step 3: Assess Distraction and Attention Demands

**Attention Load Audit**

For each page or screen, count simultaneous attention demands:
- Auto-playing video or audio: Each one is an attention hijack (count: 1 per element)
- Animated banners or GIFs: Moving content near reading area (count: 1)
- Notification toasts: Interruptions during task (count: 1 per notification)
- Multiple CTAs: More than 1 primary action per screen (count: extras beyond 1)
- Ads or promotional content: Especially near task-critical content (count: 1)
- Blinking or flashing elements: (count: 1)

**Safe Threshold:**
- 0 distractions: Safe for all users
- 1 distraction: Acceptable with adequate spacing from primary task
- 2+ distractions: High cognitive load; likely inaccessible for ADHD, anxiety

### Step 4: Assess Consistency and Predictability

**Navigation and Component Consistency (WCAG 3.2.3, 3.2.4 AA)**

Audit across the entire product:
- [ ] Navigation appears in the same location every page
- [ ] Navigation items in the same order every page
- [ ] Same-function components have identical labels ("Search" not "Search" then "Find")
- [ ] Icons mean the same thing everywhere
- [ ] Button styles consistent — primary actions always look primary
- [ ] Error states look the same across all forms
- [ ] Form patterns consistent (required field indicators, error styling, help text)

**Unexpected Changes (WCAG 3.2.1, 3.2.2, 3.2.5)**
- [ ] Focusing a control does not change page context
- [ ] Changing a select/checkbox does not auto-submit or navigate
- [ ] New windows/tabs only open on explicit user request (with warning)
- [ ] Page does not auto-refresh or redirect without user action
- [ ] Form does not auto-advance to next screen on selecting an option

### Step 5: Assess Error Handling and Recovery

**Error Prevention (WCAG 3.3.4 AA, 3.3.6 AAA)**

For destructive, financial, legal, or irreversible actions:
- [ ] Confirmation step before execution
- [ ] Undo or reversal available after execution (AAA)
- [ ] Clear description of consequences
- [ ] Not triggered by single accidental click/tap
- [ ] No confirmshaming (shame-based negative buttons like "No, I don't want to save money")

**Error Quality (WCAG 3.3.1 A, 3.3.3 AA)**

Each error message must:
1. Name the specific field (not "Error")
2. Describe what went wrong (plain language)
3. Provide specific fix or example
4. Avoid blame ("you entered" → "this field requires")
5. Avoid technical language ("invalid", "null", "403")

**Accessible Authentication (WCAG 3.3.8 AA, 3.3.9 AAA)**
- [ ] No CAPTCHA requiring visual puzzle solving
- [ ] No knowledge-based challenge questions requiring memory
- [ ] Copy/paste allowed for passwords and codes
- [ ] Authentication codes auto-fillable by password managers
- [ ] Alternative authentication paths (magic link, biometric, SSO)

### Step 6: Assess Timeout and Session Management

**Timing and Timeout Audit (WCAG 2.2.1 A, 2.2.3 AAA, 2.2.6 AAA)**

For any session timeout or time limit:
- [ ] Timeout warning provided at least 20 seconds before expiration
- [ ] User can extend timeout with a single action (large button, not hidden link)
- [ ] Timeout does not lose user data without warning (WCAG 2.2.6 AAA)
- [ ] Multi-step forms save progress or allow resumption
- [ ] No unexpected data loss on navigation or inactivity

**Safe Timeout Thresholds:**
- 30+ minutes: Generally safe for most workflows
- 10–30 minutes: Acceptable for sensitive forms with clear warning
- < 10 minutes: High risk; requires 20-second warning + easy extension
- No timeout: AAA gold standard for non-critical content

### Step 7: Assess Notification and Interruption Overload

**Notification and Interruption Audit (WCAG 2.2.4 AAA)**

During a critical task (checkout, form completion, data entry):
- How many notifications or interruptions occur?
- Can they be postponed or dismissed?
- Are they auto-dismissing? (Can be problematic for users with reading delays)
- What is the total interruption count over a task?

**Safe Thresholds:**
- 0 interruptions during critical tasks: Safe
- 1 optional, dismissible notification: Acceptable
- 2+ interruptions: Unacceptable; redesign to postpone until task completion

### Step 8: Detect Dark Patterns and Anxiety-Inducing Design

**Dark Pattern Detection**

Flag explicitly harmful patterns:

| Dark Pattern | Description | Accessibility Harm | Score |
|--------------|-------------|-------------------|-------|
| Confirmshaming | Shame-based negative buttons ("No thanks, I hate savings") | Emotional manipulation; anxiety | 8–10 |
| Roach motel | Easy to enter, hard to exit (subscriptions, memberships) | Trap; anxiety; sense of powerlessness | 7–9 |
| Hidden unsubscribe | Cancellation buried in settings or account page | Cognitive load finding exit; anxiety | 6–8 |
| Pre-checked opt-ins | Consent boxes pre-checked for opt-in | Easy to miss; exploits inattention (ADHD) | 6–7 |
| Misleading button hierarchy | Cancel button styled as primary (dark color, large) | Decision confusion; impulsivity trap | 5–7 |
| Roach motel refunds | Returns process intentionally confusing | Cognitive overload; learned helplessness | 8–10 |
| Bait and switch | Ad promises product, landing page shows different product | Cognitive confusion; trust violation | 6–8 |
| Disguised ads | Sponsored content disguised as editorial | Cognitive confusion; trust violation | 5–7 |
| Trick questions | Confusingly worded questions ("Uncheck if you DON'T want...") | Literal language confuses neurodivergent users | 7–9 |
| Fake urgency | Countdowns on non-time-critical actions | Pressure; anxiety trigger | 7–8 |
| Fake scarcity | "Only 3 left!" when stock is unlimited | Pressure; FOMO exploitation | 6–7 |
| Social proof abuse | "1,000 people bought this hour" to pressure | Anxiety; social pressure; FOMO | 6–8 |

**These are not just UX problems — they are accessibility barriers that cause measurable harm.**

---

## COGA Supplemental Guidance

Beyond WCAG, the W3C Cognitive and Learning Disabilities task force publishes supplemental patterns:

**Support Memory**
- Reminders and notifications for time-sensitive tasks
- Save and resume for long flows
- Autocomplete and autofill throughout
- Visual cues alongside text (icons, color coding — never color alone)
- Explicit numbering for steps ("Step 1 of 5")

**Support Focus and Attention**
- One primary action per screen (one CTA, not three)
- Minimize decorative elements near critical content
- No animation near reading content
- Progressive disclosure — show advanced options only when needed
- Chunked content — short paragraphs, clear headings

**Provide Clear Structure**
- Section headings that describe content accurately
- Step-by-step instructions with numbers, not bullets
- Summary statements at the start of complex content
- Table of contents for long documents

**Use Familiar Patterns**
- Standard UI patterns over novel interactions
- Common icons with text labels (icon + label, not icon alone)
- Conventional navigation placement (top/left)
- Familiar language — avoid brand-specific jargon

---

## Output Format

### Cognitive Load Assessment Report

```
## Cognitive Accessibility Audit

**Product / Component:** [name]
**Standards:** WCAG 2.2 AAA, COGA Supplemental Guidance
**Date:** [date]
**Auditor:** [name]

### Cognitive Load Summary

**Overall Score:** X/10 [Minimal / Moderate / High / Extreme]

| Dimension | Score | Target | Status | Issues |
|-----------|-------|--------|--------|--------|
| Reading | X | 2 (Grade 8) | ✓/✗ | [Grade level found; flagged sections] |
| Memory | X | 3 (4–5 items) | ✓/✗ | [Working memory items identified] |
| Attention | X | 1 (≤1 distraction) | ✓/✗ | [Distracting elements listed] |
| Decision | X | 2 (2–3 choices) | ✓/✗ | [Choice overload on screens] |
| Emotional | X | 1 (Safe, clear) | ✓/✗ | [Dark patterns flagged] |

**Aggregate Score:** (X + X + X + X + X) / 5 = **X.X/10** [Interpretation]

### Reading Level Assessment
- Estimated grade level: Grade X
- Target: Grade 8 or below
- Status: ✓ Pass / ✗ Fail
- Flagged passages: [List with suggested rewrites]

**Example:**
> Original: "To optimize the utilization of your resources, we recommend implementing a comprehensive synergy strategy."
> Rewritten: "To get the most from your account, try these tips."
> Grade improvement: 12 → 6

### Memory and Working Memory Load
- Simultaneous choices/decisions: X
- Information from previous step required: [What items user must remember?]
- Codes/passwords to remember: [Yes/No]
- Form fields on one screen: X
- Assessment: ✓ Acceptable / ✗ Cognitive overload

### Attention and Distraction Assessment
- Auto-playing media: [Count]
- Animated elements: [Count]
- Simultaneous notifications: [Count]
- Multiple primary CTAs: [Count]
- Total distractions: X
- Assessment: ✓ Safe / ✗ High distraction load

### Consistency and Predictability
| Pattern | Consistent? | Issue |
|---------|-------------|-------|
| Navigation placement | ✓/✗ | [Description] |
| Component labels | ✓/✗ | [Example of inconsistency] |
| Button styles | ✓/✗ | [Primary vs. secondary confusion] |
| Error messaging | ✓/✗ | [Varies across forms] |
| Form patterns | ✓/✗ | [Required field indicators differ] |

### Error Handling and Recovery
- Error prevention (confirmation steps): ✓/✗
- Error messages (specific, actionable): ✓/✗
- Reversible actions: ✓/✗
- Accessible authentication: ✓/✗

### Timeout and Session Management
- Session timeout: [Duration] minutes
- Timeout warning provided: ✓/✗ [If yes, how many seconds before expiration?]
- User can extend timeout: ✓/✗ [If yes, how easily?]
- Data loss on timeout: ✓/✗ [If yes, warning provided?]

### Notification and Interruption Overload
| Scenario | Interruption Count | Dismissible? | Auto-Dismiss? | Assessment |
|----------|-------------------|-------------|---------------|-----------|
| Checkout flow | X | ✓/✗ | ✓/✗ | ✓/✗ |
| Form completion | X | ✓/✗ | ✓/✗ | ✓/✗ |
| Reading article | X | ✓/✗ | ✓/✗ | ✓/✗ |

### Dark Patterns Detected
[List with severity score 0–10 and recommendation]

**Critical Issues (P0)**
[Dark patterns, irreversible actions without confirmation, catastrophic error states, extreme cognitive load]

**Major Issues (P1)**
[Consistency failures, memory demands, missing error recovery, reading level >Grade 12]

**Minor Issues (P2)**
[Typography, minor inconsistencies, COGA supplemental improvements]

### Enhancements (P3)
[AAA criteria, COGA patterns, optional improvements for exceeding compliance]

### Plain Language Rewrites
| Original | Suggested Rewrite | Issue | Grade ↓ |
|----------|------------------|-------|---------|
| [Sentence] | [Rewrite] | [Reading level, clarity] | [12 → 8] |

### Passed Checks
[What's working well — acknowledge positive patterns]

**Example:**
- Clear error messages with specific fix suggestions
- Consistent form patterns across checkout flow
- One primary CTA per screen
- Session timeout warning with easy extension

### Recommendations Summary

1. **Immediate fixes (P0):**
   - [Dark pattern to remove]
   - [Cognitive load > 7 on critical path]

2. **Short-term improvements (P1):**
   - Reduce reading level from Grade 12 to Grade 8
   - Decrease simultaneous choices from 8 to 3–5
   - Add confirmation for destructive actions

3. **Long-term enhancements (P2–P3):**
   - Implement save/resume for multi-step forms
   - Add context-sensitive help (WCAG 3.3.5 AAA)
   - Provide supplemental plain language versions for complex flows
```

---

## Cross-References

- **accessibility-copy:** Write plain language alt text, error messages, and microcopy
- **motion-auditor:** Assess how animations contribute to cognitive distraction
- **older-audiences-auditor:** Extended testing for users with age-related cognitive decline
