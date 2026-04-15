---
name: older-audiences-auditor
description: Audit prototypes, apps, and digital products for how well they serve users aged 50 and older — scoring across vision, cognition, motor control, hearing, trust, and content clarity, with specific age-band guidance (50-65, 65-80, 80+), concrete measurement thresholds, and technology comfort assessment. Use this skill whenever someone needs to evaluate a product for older user audiences, check if a design accommodates age-related physical or cognitive changes, audit typography and touch targets for older adults, or ensure a product isn't inadvertently excluding users over 50. Trigger on phrases like older audiences audit, designing for seniors, older adults UX, age-inclusive design, 50+ users, elder UX, senior-friendly design, aging population design, older user accessibility, is this usable for older adults, or any request to evaluate how well a product serves users experiencing age-related changes. Always use this skill — do not attempt an older audiences audit without it.
---

# Older Audiences Auditor

Evaluate products and prototypes for how well they serve users aged 50 and older. By 2030, 1 in 6 people worldwide will be over 60. Designing for age-related challenges almost always improves usability for everyone — reduced vision, hearing changes, and limited dexterity mirror what any user experiences in suboptimal conditions. This is not niche design. It is good design.

Grounded in Matthew Stephens' UX Collective article "Designing for Older Audiences: Checklist + Best Practices" and the Loud + Clear Parkinson's fitness app. Cross-references cognitive-accessibility, accessible-forms, and contrast-checker skills.

---

## The 6 Audit Dimensions

| # | Dimension | Age-Related Change | Measurement Threshold |
|---|-----------|-------------------|----------------------|
| 1 | Vision & Typography | Lens hardening (presbyopia), reduced contrast sensitivity, slower dark adaptation, narrowing field of view, increased glare sensitivity | Min 16px body text; contrast 4.5:1 AA; 200% zoom without breaking layout |
| 2 | Cognition & Clarity | Slower processing speed, shorter working memory, reduced fluid reasoning, higher cognitive load sensitivity | Max 20 words/sentence; progressive disclosure for complex info; visible progress indicators |
| 3 | Motor Control & Touch | Reduced dexterity, tremors, arthritis, less precise finger control, slower reaction time | Touch targets 44-72px; 8px spacing between targets; alt-text for icon-only controls |
| 4 | Hearing & Audio | Presbycusis (age-related hearing loss), difficulty distinguishing speech from background noise, reduced high-frequency hearing | All video has captions; audio-only alerts paired with visual equivalents |
| 5 | Trust & Error Recovery | Higher anxiety around irreversible actions, greater concern about fraud and data security, more reliance on help and confirmations | Confirmation dialogs for destructive actions; visible security signals; accessible help content |
| 6 | Content & Language | Preference for plain language, lower tolerance for jargon, different digital literacy baseline, greater reliance on familiar patterns | Grade 8 reading level or below; no unexplained acronyms; familiar UI patterns |

---

## Age-Band Guidance

Products serving 50+ users should adjust for these distinct cohorts:

**Ages 50-65 (Early Older Adulthood)**
- Tech comfort: Generally higher — many have used computers for work. May have variable experience with mobile-first design.
- Vision: Early presbyopia setting in. Font size 14-16px acceptable, but 16px+ preferred. Contrast ratio 4.5:1 minimum.
- Motor: Generally fine motor control still intact. Touch targets 44px acceptable for frequent actions, 56px preferred.
- Hearing: Beginning high-frequency loss. Audio matters less than for 65+. Captions still needed for video.
- Trust: Actively engaged online. Social security and financial fraud concerns. Clear security indicators matter.
- Technology comfort level: Video calling, email, smartphone apps are normal. May struggle with novel navigation patterns.

**Ages 65-80 (Established Older Adulthood)**
- Tech comfort: Highly variable. Many active online, some with limited digital experience. Mobile-first design may be frustrating.
- Vision: Significant presbyopia. Font size must be 16-18px minimum. Contrast ratio 4.5:1 non-negotiable, AAA (7:1) preferred.
- Motor: Arthritis and tremors increasingly common. Touch targets should be 56-72px. Spacing critical.
- Hearing: High-frequency loss noticeable. Audio-dependent feedback should have visual pairs. Captions essential.
- Trust: Higher anxiety around online transactions. Confirmation dialogs and plain-language privacy explanations expected.
- Technology comfort level: Desktop browser may be primary interface. Mobile app conventions may be unfamiliar. Need very clear call-to-action paths.

**Ages 80+ (Advanced Older Adulthood)**
- Tech comfort: Varied experience, often newer to digital tools. May require more context and onboarding. Desktop-first interfaces often preferred.
- Vision: Significant presbyopia; possible cataracts. Font size 18-20px minimum. Contrast ratio AAA (7:1) strongly preferred. Dark mode beneficial for glare reduction.
- Motor: High likelihood of tremors, arthritis affecting fine control. Touch targets should be 64-72px minimum. Ghost/borderless buttons unusable.
- Hearing: Hearing aids common. Audio feedback alone insufficient. Clear, high-contrast visual feedback essential.
- Trust: Highest anxiety about financial and data security. Irreversible actions require explicit confirmation with backup undo paths.
- Technology comfort level: Fewer years of digital habituation. May prefer familiar, Web 1.0-style interfaces. Novel UI patterns require explanation.

---

## Scoring

Score each dimension 0–10. All dimensions weighted equally (~16.7% each).

Overall Score = average of all 6 × 10

| Score | Grade | Meaning |
|-------|-------|---------|
| 85–100 | A | Genuinely age-inclusive — serves older adults without compromising younger users |
| 70–84 | B | Mostly there with specific gaps |
| 55–69 | C | Passes casual use but creates real friction for older users |
| 40–54 | D | Significant barriers present — meaningful redesign needed |
| 0–39 | F | Actively exclusionary for users with age-related changes |

---

## Dimension Reference Guide

### 1. Vision & Typography

**What's happening physiologically:** The lens of the eye hardens, making it harder to focus on close objects. Contrast sensitivity decreases. Eyes become more sensitive to glare. The visual field may narrow slightly. Color differentiation becomes harder, especially blues and greens.

**Measurement Thresholds:**
- Body text: 16px minimum (18-20px preferred for products targeting 65+)
- Line height: 1.5x minimum (1.6x preferred)
- Letter spacing: 0.01-0.02em tighter than default
- Contrast ratio: 4.5:1 WCAG AA minimum; 7:1 AAA preferred for products targeting 70+
- Font weight: 400 (regular) minimum; avoid 100-300 weights
- Zoom support: Content must remain readable at 200% zoom without horizontal scrolling

**Audit checklist:**
- [ ] Body text minimum 16px — 18–20px preferred for primary content
- [ ] Line height minimum 1.5× font size (1.6x preferred for 70+)
- [ ] Letter spacing slightly looser than default (0.01–0.02em improvement for legibility)
- [ ] Typeface is a legible sans-serif — Atkinson Hyperlegible or Hyperlegible Sans preferred for products serving older audiences or low-vision users. Avoid decorative, condensed, or light-weight fonts
- [ ] Color contrast meets WCAG AA (4.5:1 normal text, 3:1 large text) — aim for AAA (7:1) for critical content, especially in products targeting 70+
- [ ] Information is never conveyed by color alone
- [ ] No white text on light backgrounds or dark text on dark backgrounds
- [ ] Avoid light-weight type (100, 200 weight) for body content — minimum 400 weight
- [ ] Zoom to 200% does not break layout or hide content
- [ ] Dark mode available and well-implemented (reduced glare benefit for older users)
- [ ] No auto-playing video or animations with high contrast flicker
- [ ] Links visually differentiated from body text (not by color alone)
- [ ] Focus indicators clear and visible (minimum 2px width, 2:1 contrast with background)

**Red flags:**
- 12–14px body text (common in "clean" modern designs)
- Very thin typeface weights (<400)
- Light gray text on white (#999 or lighter on white fails contrast)
- Information conveyed by color in charts or status indicators
- Hyperlinks indistinguishable from body text
- 1.4x line height or tighter (causes skipping lines)

### 2. Cognition & Clarity

**What's happening physiologically:** Processing speed slows with age. Working memory capacity decreases — users can hold fewer items in mind at once. Multi-step tasks become harder without clear progress indicators. Novel interface patterns require more effort to decode.

**Measurement Thresholds:**
- Sentence length: Average 20 words or fewer
- Steps in flows: Max 3-5 steps without save/resume capability
- Visible progress: Progress indicator for any flow over 2 steps
- Response time: No time pressure for cognitive tasks; 10+ second timeout minimum for session persistence

**Audit checklist:**
- [ ] One primary action per screen — avoid competing CTAs
- [ ] Progressive disclosure used for complex information (don't show everything at once)
- [ ] Clear visual hierarchy guides the eye to the most important content first
- [ ] Navigation is consistent and predictable — no surprise redirections
- [ ] Breadcrumbs or persistent navigation cues show where the user is (especially for 65+)
- [ ] Multi-step flows have visible progress indicators
- [ ] Error messages are specific and tell users exactly what to fix (not "Error 403: Forbidden")
- [ ] Confirmation screens present before irreversible actions
- [ ] No timed interactions that expire without warning (minimum 10 second timeout for session critical interactions)
- [ ] No auto-advancing carousels or content that moves without user control
- [ ] Recognition over recall — labels on icons, not icons alone
- [ ] Familiar UI patterns used for familiar tasks (no novel navigation metaphors without explanation)
- [ ] Form fields labeled above or adjacent (not as placeholder-only)
- [ ] Required field indicators clear and visible
- [ ] Inline validation with corrective guidance (not just error highlighting)

**Red flags:**
- Hamburger menus as the only navigation pattern
- Icon-only buttons with no labels
- Auto-advancing sliders or timers
- Long multi-step forms without save/resume
- Jargon in error messages ("Error 403: Forbidden")
- Processing speed expectations (rapid interactions, quick-fire multi-choice)
- Time pressure ("limited time offer", "expires in 2 hours")

### 3. Motor Control & Touch

**What's happening physiologically:** Joint changes and reduced muscle control affect fine motor precision. Arthritis is common. Tremors may be present (as in Parkinson's, which affects ~1% of adults over 60). Touchscreens require pinpoint accuracy that becomes harder with age.

**Measurement Thresholds:**
- Touch targets: 44x44px minimum; 56-72px preferred for products targeting 65+
- Spacing: Minimum 8px between adjacent targets
- Button clarity: Must have visible button affordance (not ghost/borderless)
- Keyboard alternative: All functionality must be keyboard-accessible
- No drag-only: Drag interactions must have non-drag alternatives

**Audit checklist:**
- [ ] Touch targets minimum 44×44px — prefer 56–72px for primary actions, especially for products serving 65+
- [ ] Minimum 8px spacing between adjacent touch targets to prevent accidental activation
- [ ] Primary actions positioned in the lower third of the screen (thumb-reachable, lower effort)
- [ ] No interactions requiring precise drag, pinch, or multi-finger gestures as the only path
- [ ] Keyboard navigation fully supported as an alternative to touch/mouse
- [ ] Voice input supported where possible
- [ ] No double-tap or long-press as the only way to access important actions
- [ ] Swipe-to-delete or swipe-to-dismiss have a confirmation or easy undo
- [ ] Buttons are clearly shaped as buttons — not ghost/borderless styles that reduce the perceived tap area
- [ ] Sliders have numeric input alternatives
- [ ] Forms have large input fields — minimum 44px height (56px for 65+ audiences)
- [ ] Close buttons on modals are at least 44x44px (not small × in corner)
- [ ] Hover states not required to reveal functionality (all controls visible without hover)
- [ ] Numeric input fields allow keyboard entry (not touch-only spinners)

**Practical note from Loud + Clear:** Every tappable element was maximized in size, including buttons, inputs, and links. The motor simulator in Funkify ("Trembling Trevor" persona) was used during testing to validate that large elements were still usable with reduced dexterity.

**Red flags:**
- Small close buttons (×) on modals — especially in corners
- Tightly clustered navigation items (<8px apart)
- Drag-only interactions (sorting lists, sliders)
- Touch targets under 44px
- Icon-only buttons without text labels
- Hover-only tooltips or controls
- Swipe gestures without alternative controls

### 4. Hearing & Audio

**What's happening physiologically:** Presbycusis causes progressive high-frequency hearing loss. Background noise becomes harder to filter. Speech intelligibility decreases, especially at lower volumes. Many older adults use hearing aids that interact differently with device audio.

**Measurement Thresholds:**
- Captions: Must be present for 100% of video content
- Visual feedback: All audio alerts must have visual equivalent
- Volume controls: Accessible and visible (not buried in settings)

**Audit checklist:**
- [ ] All video content has accurate closed captions
- [ ] All audio-only content has a text transcript
- [ ] Captions are positioned to not obscure important visual content
- [ ] Captions can be styled/resized by the user
- [ ] No audio-only alerts or feedback — pair all audio cues with visual equivalents
- [ ] Audio controls are accessible and visible — not hidden or auto-playing
- [ ] Speech-based interfaces have a non-speech alternative
- [ ] Volume controls are accessible and prominently placed
- [ ] No sounds that autoplay on page load without warning
- [ ] Transcript provided for all podcasts or audio-heavy content
- [ ] Video player controls large and easily visible
- [ ] Captions provided in high contrast (white on dark background, not gray)

**Red flags:**
- Video with no captions
- Audio-only error alerts (beeps with no visual equivalent)
- Auto-playing audio on page load
- Very small captions or captions in light gray
- No transcript for audio content
- Audio required for essential functionality (e.g., voice-only password reset)

### 5. Trust & Error Recovery

**What's happening culturally and psychologically:** Older adults have lived through more technology failures and scams. They are appropriately more cautious. They may be less tolerant of ambiguity about what an action will do, and more anxious about making mistakes they can't undo. They are also more likely to read help text, tooltips, and confirmation dialogs — so these actually need to be well-written.

**Measurement Thresholds:**
- Confirmation dialogs: Required before any irreversible action (data deletion, payment, account closure)
- Help accessibility: Help content reachable in max 2 clicks
- Security signals: Present and understandable (not "badges" that look like ads)
- Session timeout: Minimum 10 minute timeout warning before session expires

**Audit checklist:**
- [ ] Confirmation dialogs before all destructive or irreversible actions
- [ ] Clear "undo" or "cancel" path wherever possible
- [ ] Security and trust signals present during sensitive flows (payments, data submission, account changes) — and not mistakable for ads
- [ ] Privacy practices explained in plain language at the point of data collection
- [ ] Help content is findable, up to date, and written in plain language
- [ ] Error messages are supportive, not alarming — no red all-caps ERRORS
- [ ] Session timeout warnings give users enough time to respond (minimum 10 seconds)
- [ ] No dark patterns that exploit caution (fake urgency, "your account will be deleted in 24 hours")
- [ ] Contact/support options are visible and reachable without deep navigation
- [ ] Password and login flows accommodate slower typing and likely use of password managers
- [ ] Payment flows show total amount before final confirmation
- [ ] Suspicious activity warnings differentiated from ads or promotional content
- [ ] Account deletion flows require 2-step confirmation with email backup
- [ ] Recovery options (password reset, account recovery) obvious and accessible

**Red flags:**
- Alarmist error messages ("CRITICAL ERROR — ACTION REQUIRED")
- No confirmation before account deletion or irreversible data changes
- Security badges that look like ads or pop-ups
- Trust signals buried in footer
- Session timeout with no warning
- Pressure language ("limited time offer", "expires soon")
- No contact/support link on error pages
- Password reset requiring obscure security questions

### 6. Content & Language

**What's happening:** Older adults are not less intelligent. They are less tolerant of digital jargon they've had less time to absorb — and they're right to be. Unclear language wastes time and erodes trust. They also benefit from content chunked into manageable pieces.

**Measurement Thresholds:**
- Reading level: Grade 8 or below (Flesch Reading Ease 60+)
- Sentence length: Average 20 words or fewer
- Paragraph length: Max 4 sentences before a break
- Instructions: Numbered steps, not narrative paragraphs

**Audit checklist:**
- [ ] Reading level targets Grade 8 or below for general audiences (use Hemingway App to verify)
- [ ] No unexplained acronyms or technical jargon
- [ ] Active voice used throughout
- [ ] Sentences are short (average under 20 words)
- [ ] Content chunked with clear headings — not long unbroken paragraphs
- [ ] Instructions are numbered steps, not narrative paragraphs
- [ ] Tooltips and contextual help available for any unfamiliar term or action
- [ ] Button labels describe actions, not states ("Download your report" not "Download")
- [ ] Avoid age-biased language in copy ("easy," "simple," "even a grandparent could use it")
- [ ] Culturally appropriate idioms — no slang or pop-culture references that may not land
- [ ] Emoji and icons accompanied by text labels
- [ ] Form labels clear and specific ("Email address" not "Contact info")
- [ ] Error messages constructive and corrective ("Phone number must include area code" not "Invalid input")
- [ ] Navigation link text descriptive (not "Click here" or "More")

**Red flags:**
- 12+ word sentences, on average
- Jargon or unexplained technical terms
- Passive voice ("an error has occurred" vs. "something went wrong")
- Very long paragraphs without breaks
- Ableist language ("tone-deaf," "blind spot," "crazy fast")
- Pop culture references or slang that date the product
- Button labels that are states, not actions

---

## Testing Recommendations

### Funkify Chrome Extension
Use Funkify to simulate age-related and disability-related experiences during design review:

- **Vision simulator:** Blurs and warps content — simulates low vision and presbyopia
- **Motor simulator ("Trembling Trevor"):** Makes the pointer harder to control — simulates tremors and reduced dexterity
- **Cognition simulator:** Slows and fragments interactions — simulates cognitive load and processing speed changes
- **Color blindness simulator:** Validates color-independent communication

### How Might We framing
When Funkify sessions surface issues, frame them as HMW opportunities:
- "HMW make the 'Next' button easier to tap with reduced dexterity?"
- "HMW communicate this status without relying on the color red?"
- "HMW reduce the number of steps needed to complete this task?"

### Test with real users
Simulations are a starting point, not a substitute. Include users 55+ in usability testing — not just as accommodation, but as standard practice. When recruiting, specifically recruit across age bands (50-65, 65-80, 80+) to surface age-band-specific issues. Older adults who struggle with a UI are often surfacing usability problems that affect all users.

### Technology comfort assessment
Ask testers about their digital experience:
- "How often do you use video calling?"
- "Do you shop online? What platforms?"
- "Do you use mobile apps, or mostly the web?"
- "Have you had negative experiences with online services?"

Use answers to calibrate support and help content depth.

---

## Output Format

```
# Older Audiences Audit Report

**Product / Feature:** [name]
**Primary target age range:** [stated or estimated]
**Age bands represented in this audit:** [50-65 / 65-80 / 80+ — mark which were tested]
**Technology comfort assessment:** [results from comfort questions if applicable]
**Audit Date:** [date]

---

## Overall Score: [X/100] — [Grade]

[1–2 sentence summary]

---

## Dimension Scores

| Dimension | Score | Key Finding |
|-----------|-------|-------------|
| Vision & Typography | X/10 | |
| Cognition & Clarity | X/10 | |
| Motor Control & Touch | X/10 | |
| Hearing & Audio | X/10 | |
| Trust & Error Recovery | X/10 | |
| Content & Language | X/10 | |

---

## Findings & Action Items

### [Dimension] — [X/10]

**[CRITICAL/MAJOR/MINOR]** [Finding]
> Action: [Specific, implementable fix]

---

## Top 5 Priority Fixes

1.
2.
3.
4.
5.

---

## What's Working

[2–4 things the product does well for older audiences]

---

## Recommended Testing Next Steps

[Specific Funkify tests, user recruitment notes for age bands, or prototype changes to validate]
```

---

## The Curb Cut Effect

Every improvement you make for older users improves the experience for everyone. Large touch targets help users on public transit. High contrast helps users in sunlight. Plain language helps users reading quickly. Captions help users in noisy environments. There is no version of this work that is "just for old people." It is just good design.

---

## Cross-References

Related skills: cognitive-accessibility, accessible-forms, contrast-checker, accessibility-audit

---

## Reference Framework

Grounded in Matthew Stephens' "Designing for Older Audiences: Checklist + Best Practices" (UX Collective, 2025) and the Loud + Clear Parkinson's fitness app, which holds that:

- Designing for people with age-related challenges almost always improves usability for everyone
- Older adults are not less capable — they are less tolerant of poor design, and correctly so
- Good accessibility is good design — the overlap between age-related needs and disability design is substantial
- Test with real older users across age bands (50-65, 65-80, 80+) — simulations are a start, not a finish
- Atkinson Hyperlegible (and Hyperlegible Sans) are the recommended typefaces for products where legibility is critical
- Technology comfort varies widely among older adults — assess and design accordingly
