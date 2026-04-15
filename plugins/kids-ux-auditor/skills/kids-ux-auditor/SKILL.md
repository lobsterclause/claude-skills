---
name: kids-ux-auditor
description: Evaluate prototypes, apps, or digital experiences for how well they work for children, with rigorous COPPA compliance assessment, dark pattern detection, and age-band motor/cognitive capability matching (0-2, 3-5, 6-8, 9-12, 13-17) with caregiver co-testing methodology. Use this skill whenever the user wants to audit a product designed for kids or used by kids — including learning apps, games, entertainment tools, or any digital experience with a child audience. Trigger on phrases like "kids app audit", "children's UX", "is this good for kids", "child-safe design", "age-appropriate", "review this for children", "kids product review", "ethical kids design", "COPPA compliance check", or any request to evaluate a prototype or product against children's design standards. Always use this skill for kids-focused audits — do not attempt to evaluate child UX without it.
---

# Kids UX Auditor

Evaluate vibe-coded prototypes and digital products for how well they serve children ethically and accessibly. Produces a scored audit with specific, actionable improvement items organized by priority, explicit dark pattern detection, and age-band capability assessment.

---

## What This Skill Produces

A structured audit with:
- An overall Kids UX Score (0–100)
- Scores across 7 dimension categories
- Age-band motor and cognitive capability assessment
- Severity-tagged findings (Critical / Major / Minor)
- Explicit dark pattern detection (automatically CRITICAL)
- Caregiver testing methodology recommendations
- Specific, copy-paste-ready action items for each issue

---

## Audit Dimensions

Score each dimension 0–10. Weight them as shown to calculate the overall score.

| # | Dimension | Weight | What to Evaluate |
|---|-----------|--------|-----------------|
| 1 | Age-Appropriateness | 20% | Motor skill accommodation, reading level, cognitive load, vocabulary, age-banded design decisions |
| 2 | Safety & Ethics | 20% | No manipulative reward loops, no hidden costs, no data collection beyond necessity, no dark patterns, COPPA awareness |
| 3 | Accessibility & Inclusion | 15% | Screen reader support, color not sole communication channel, flexible pacing, sensory overload risk, diverse representation |
| 4 | Caregiver Integration | 15% | Parent/guardian dashboard clarity, co-play modes, positive limit framing, transparent controls, family safety features |
| 5 | Interaction Design | 15% | Touch target sizing, forgiving taps, error recovery, undo availability, no irreversible destructive actions |
| 6 | Feedback & Delight | 10% | Clear positive feedback loops, encouraging (not punishing) tone, celebration of effort over performance |
| 7 | Learning & Autonomy | 5% | Scaffolded challenge, child agency and choice, creativity support without blank-canvas paralysis |

Overall Score = sum of (dimension score × weight)

---

## Scoring Scale

| Score | Grade | Meaning |
|-------|-------|---------|
| 90–100 | A | Exceptional — safe, joyful, inclusive |
| 75–89 | B | Good — minor improvements needed |
| 60–74 | C | Adequate — several meaningful gaps |
| 45–59 | D | Problematic — significant issues present |
| 0–44 | F | Not suitable for child audiences without major rework |

---

## Audit Process

### Step 1 — Gather Context

Before scoring, identify or ask for:
- Target age range (0–2 / 3–5 / 6–8 / 9–12 / 13–17)
- Primary use context (solo play, classroom, co-play, unsupervised home)
- Expected caregiver involvement (required / optional / none)
- Is there monetization? Any in-app purchases? Any UGC or social features?
- COPPA compliance status (is the product making COPPA claims?)

If reviewing code: scan for touch targets, font sizes, ARIA labels, data collection calls, timer-based mechanics, reward loops, payment flows, and navigation patterns.

If reviewing a screenshot or description: evaluate visually observable patterns against the dimensions above.

### Step 2 — Score Each Dimension

For each of the 7 dimensions:
1. Assign a score 0–10
2. List specific findings with severity tags
3. Write action items in plain, implementable language

**Severity Definitions:**
- CRITICAL — Child safety, ethics, or legal risk (data collection, manipulative dark patterns, content inappropriate for age, COPPA violations)
- MAJOR — Meaningfully harms usability or wellbeing for child users
- MINOR — Polish and improvement opportunities

### Step 3 — Dark Pattern Check (Automatic CRITICAL)

Explicitly check for and call out the following if present. Each is automatically CRITICAL severity:

- Variable reward / slot machine mechanics
- Fake urgency or countdown timers to pressure purchases
- Social pressure mechanics ("your friends are waiting")
- Hidden or misleading subscription flows or in-app purchase paths
- Excessive data collection or third-party tracking
- Autoplay without parental opt-in
- Content or characters that prime brand loyalty or purchase intent
- Punishing or shaming failure states
- Sunk-cost mechanics ("you must complete this streak")
- Dark patterns targeting COPPA-covered children (under 13) with paid features disguised as free

### Step 4 — Caregiver Integration Assessment

For any product with expected caregiver involvement:
- Can caregivers easily view activity?
- Can caregivers set time limits / content restrictions?
- Are parental controls accessible without finding hidden menus?
- Can caregivers receive clear reports on usage, spending, and child interactions?
- Is there a simple opt-out path if a caregiver wants to end participation?

### Step 5 — Render the Report

Use the output format below. Do not skip sections. All action items must be specific enough to implement without further clarification.

---

## Output Format

```
# Kids UX Audit Report

**Product / Prototype:** [name or description]
**Target Age Range:** [age range: 0–2 / 3–5 / 6–8 / 9–12 / 13–17]
**Use Context:** [solo play / co-play with caregiver / classroom / unsupervised home]
**Monetization:** [none / ad-supported / in-app purchases / subscription / hybrid]
**COPPA Compliance Claim:** [yes / no / unclear]
**Audit Date:** [date]

---

## Overall Score: [X/100] — [Grade]

[1–2 sentence summary of the product's child-readiness]

---

## Dimension Scores

| Dimension | Score | Weight | Weighted |
|-----------|-------|--------|---------|
| Age-Appropriateness | X/10 | 20% | X.X |
| Safety & Ethics | X/10 | 20% | X.X |
| Accessibility & Inclusion | X/10 | 15% | X.X |
| Caregiver Integration | X/10 | 15% | X.X |
| Interaction Design | X/10 | 15% | X.X |
| Feedback & Delight | X/10 | 10% | X.X |
| Learning & Autonomy | X/10 | 5% | X.X |
| **Total** | | | **X.X / 10** |

---

## Dark Patterns Detected

[If none: "No dark patterns detected."]

[If present:]
**[PATTERN NAME]** — CRITICAL
[Description of the pattern found]
> Action: [How to remove or replace it]

---

## Findings & Action Items

### [Dimension Name] — [X/10]

**[CRITICAL / MAJOR / MINOR]** [Finding description]
> Action: [Specific, implementable fix]

[Repeat per finding]

---

## Top 5 Priority Fixes

1. [Most critical fix]
2.
3.
4.
5.

---

## What's Working

[Callout 2–4 things the prototype does well for child audiences. Balanced feedback matters.]

---

## Caregiver Testing Recommendations

[If product has caregiver involvement:]
- Have caregivers review parental controls accessibility
- Time caregiver setup flow (should be under 2 minutes)
- Verify caregivers can easily find and understand activity reports
- Test withdrawal/deletion flow as a caregiver
```

---

## Age-Band Motor & Cognitive Capability Reference

Use this when evaluating age-appropriateness. The prototype should match its stated age range across all of these dimensions.

### Ages 0–2 (Toddler)

**Motor Capabilities:**
- Large arm movements, not fine motor control
- Whole-hand grasping (not pincer grip)
- Can tap but not precisely; will tap repeatedly at random
- Cannot drag or pinch
- Frequent accidental taps outside intended target
- Enjoys repetition but with high variability

**Cognitive Capabilities:**
- Object permanence developing (surprised if things disappear)
- Cause-and-effect learning critical
- Very short attention span (30 seconds to 2 minutes)
- No concept of "winning" or "losing"
- No reading ability
- Sound and animation are primary engagement drivers

**Design Implications:**
- Large tap targets (72px+ minimum, 100px+ preferred)
- No text — icons, sound, and animation only
- Immediate, satisfying audio/visual feedback on every tap
- No timed pressure or countdowns
- Extremely forgiving input — no penalty for wrong taps
- Infinite undo (every action reversible)
- Simple, bold colors and high contrast
- No surprise transitions or scary sudden changes

### Ages 3–5 (Preschool)

**Motor Capabilities:**
- Developing pincer grip but still inconsistent
- Can tap with increasing accuracy, but still prone to overshooting
- Cannot reliably drag (will tap instead)
- Can perform multi-tap sequences (tap to advance)
- Finger control improving but still imprecise
- Enjoys tapping and touching

**Cognitive Capabilities:**
- Object permanence established
- Cause-and-effect fully understood
- Very short attention span (2-5 minutes per activity)
- Beginning to understand simple sequences (first/next/last)
- No reading, but can follow simple visual sequences
- Learns through exploration and repetition
- Cannot handle ambiguity or hidden information

**Design Implications:**
- Touch targets 48-60px minimum
- Simple, high-contrast visuals
- Voice instruction support preferred over text
- 1–2 tap interactions max per screen
- Friendly characters to guide navigation
- Celebration for any engagement, not just "correct" answers
- One primary action per screen
- No time limits or pressure
- Immediate, clear feedback for every action
- No irreversible actions or penalties

### Ages 6–8 (Early Elementary)

**Motor Capabilities:**
- Reliable pincer grip developing
- Can tap precisely (but not perfectly)
- Beginning to drag, but inconsistent
- Can perform multi-step sequences with increasing confidence
- Enjoys fine motor challenges (drawing, dragging)

**Cognitive Capabilities:**
- Reading developing but still fragile (vary 1st-3rd grade level)
- Understanding of simple rules and sequences
- Attention span increasing (5-10 minutes)
- Beginning to understand "winning" and "losing" but very sensitivity to failure
- Starting to care about performance vs. effort
- Learning to follow written instructions
- Social comparison emerging

**Design Implications:**
- Touch targets 44-56px for standard actions, 56px+ for primary actions
- Short words, simple sentences if text is present
- Introduce mild challenge with strong scaffolding
- Audio support still valuable for new concepts
- Timed mechanics OK only if low-stakes and repeatable
- Clear undo / go-back path always available
- Mistakes should never be punishing or shaming
- Encouragement focused on effort, not performance
- Reading level: Grade 2-3 maximum
- Clear, specific error messages that explain what went wrong

### Ages 9–12 (Tween)

**Motor Capabilities:**
- Full motor control developed
- Can tap, drag, swipe, multi-touch with adult precision
- Enjoys fine motor challenges
- Can use complex input methods (keyboard, gamepad)

**Cognitive Capabilities:**
- Reading at grade 4-5+ level
- Can understand multi-step processes
- Beginning abstract reasoning
- Social comparison very important; peer influence strong
- Can set and track goals
- Enjoy challenge and competition, but still sensitive to unfair outcomes
- Privacy becomes important — aware of who can see activity
- Developing sense of identity and self-expression

**Design Implications:**
- Can handle more complex navigation (but keep it consistent)
- Peer and creative features become motivating
- Privacy becomes especially important — no social features without parental controls
- Avoid comparison mechanics that shame low performance
- Give opportunities for self-expression and customization
- Challenge should be calibrated to skill level (not frustrating, not boring)
- Reading level: Grade 4-5
- Explain why features matter (not just "try this")
- No dark patterns exploiting social pressure or fear of missing out
- Clear consequences for in-app purchases (show cost/value)

### Ages 13–17 (Teen)

**Motor Capabilities:**
- Adult-level motor control
- Full access to all input modalities
- Can use advanced UI patterns

**Cognitive Capabilities:**
- Adult-level reading and reasoning
- Abstract thinking and perspective-taking developed
- Can understand complex systems and long-term consequences
- Identity exploration is central; seeking autonomy and respect
- Peer influence at peak; social comparison intense
- Privacy and data autonomy become critical values
- Can become aware of manipulation tactics (and resent them intensely)

**Design Implications:**
- Abstract reasoning is developed — nuanced interfaces OK
- Identity exploration is central — respect autonomy
- Highest risk for manipulative engagement mechanics — flag aggressively
- Strong privacy and data transparency requirements
- Avoid treating teens as either children or adults (they're neither)
- Give meaningful choice and control
- Be transparent about algorithms and personalization
- No dark patterns targeting FOMO or social pressure
- Make privacy practices clear and easy to control

---

## Notes on Vibe-Coded Prototypes

Vibe-coded prototypes often have:
- Hardcoded placeholder interactions that don't reflect real child input patterns
- Missing ARIA / accessibility scaffolding
- Adult-default font sizes and tap targets
- No error states or recovery flows
- No caregiver control mechanisms

When auditing code, always check:
- Touch target sizes for age band (44x44px minimum, but 48-72px+ for under-8)
- Font sizes for reading level (minimum 16px body, 18–20px preferred for under-10)
- Color contrast ratios (4.5:1 minimum for text)
- Whether color is the only way information is communicated
- Whether any form of data collection, analytics, or third-party scripts are present
- Whether reward mechanics use variable/random reward schedules (CRITICAL dark pattern)
- Whether there are time-based or countdown mechanics that pressure action
- Whether there are in-app purchase flows and how visible the costs are
- Whether there are parental control mechanisms if monetization is present

---

## Caregiver Co-Testing Methodology

For any product with expected caregiver participation:

1. **Caregiver Setup Test (5-10 minutes):**
   - Have a parent/guardian set up the product from scratch
   - Time the setup flow
   - Measure clarity of onboarding
   - Check if controls/limits are easily accessible

2. **Activity Review (5 minutes):**
   - Have caregiver review activity reports
   - Can they understand what the child did?
   - Is data presented clearly?
   - Do they feel informed about engagement?

3. **Limit-Setting (5 minutes):**
   - Have caregiver set time limits, content restrictions, purchase limits
   - Are controls intuitive or buried?
   - Does the child interface clearly reflect these limits?
   - Is enforcement clear?

4. **Withdrawal Test (5 minutes):**
   - Have caregiver delete child account or disable child access
   - Is the process clear and simple?
   - Are there barriers or dark patterns discouraging deletion?

---

## Reference Framework

This skill is grounded in Matthew Stephens' ethical framework for children's digital design, which holds that:

- Children are not small adults — cognitive, motor, and emotional development must shape every decision
- Engagement metrics like "time in app" are the wrong success criteria for children's products
- Parents and caregivers are co-users, not obstacles
- Accessible design is the baseline, not a feature
- Ethical design puts learning, safety, and joy above revenue optimization
- Dark patterns targeting children are not creative — they are harmful and often illegal

These principles align with UNICEF's Child Rights by Design guidance, the RITEC-8 framework for children's digital play, COPPA requirements in the US, and emerging legislation like the Online Safety Bill in the UK.

---

## Cross-References

Related skills: cognitive-accessibility, gamification-auditor
