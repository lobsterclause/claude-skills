---
name: dei-auditor
description: Audit prototypes, products, and digital experiences for DEI and inclusive design — evaluating representation patterns, language bias, user model assumptions, cultural localization, socioeconomic barriers, and systemic exclusion with concrete testing methodology and representation checklist. Use this skill whenever someone wants to evaluate how inclusive a product is, check for representation gaps, audit content or imagery for bias, review personas or user models for default assumptions, assess whether a product serves users across race, gender, age, ability, culture, socioeconomic background, or geography. Trigger on phrases like DEI audit, inclusive design review, representation audit, bias in design, is this product inclusive, diversity check, cultural sensitivity review, who are we excluding, default user assumptions, inclusive UX, gender-inclusive design, intersectionality, or any request to evaluate whether a product truly serves a diverse user base. Always use this skill — do not attempt a DEI or inclusive design audit without it.
---

# DEI / Inclusive Design Auditor

Evaluate products and prototypes for who they serve — and who they don't. Inclusive design is not a feature or a checklist. It is the practice of questioning every assumption your team baked in about who the "default user" is, and then designing for the full range of human experience.

A product that works for your team but not for people different from your team is not a good product. It is a product that reflects the unchecked assumptions of the people who built it.

---

## The 7 Dimensions of Inclusive Design

| # | Dimension | Core Test | Testing Method |
|---|-----------|-----------|--------|
| 1 | Representation | Do the people in your product — images, characters, names, examples — reflect the actual diversity of humanity? | Imagery audit; name diversity scan; scenario representativeness |
| 2 | Language & Tone | Is your copy free of gendered defaults, ableist language, culturally Western assumptions, and exclusionary idiom? | Readability audit; bias language search; colloquialism check |
| 3 | User Model Assumptions | Who did you assume your user was when making design decisions? Whose context, literacy, device, and bandwidth did you optimize for? | Device testing matrix; connectivity testing; literacy-level audit |
| 4 | Socioeconomic Inclusion | Does the product require a high-end device, fast internet, credit card, formal address, or financial buffer to use? | Device access audit; payment barrier check; regional requirement scan |
| 5 | Cultural & Regional Sensitivity | Does the product handle names, dates, addresses, currencies, colors, and idioms in ways that work globally, not just for Western markets? | Internationalization audit; color meaning check; date/currency format review |
| 6 | Gender & Identity | Does the product handle gender respectfully, avoid binary-only assumptions, and allow for self-identification? | Form field audit; pronoun support check; identity option audit |
| 7 | Systemic Exclusion Patterns | Are there features, flows, or mechanics that structurally disadvantage specific groups — even unintentionally? | Intersectionality mapping; workflow barrier audit; cumulative friction analysis |

---

## Scoring

Score each dimension 0–10. All dimensions weighted equally (approx 14.3% each).

Overall Inclusive Design Score = average of all 7 × 10

| Score | Grade | Meaning |
|-------|-------|---------|
| 85–100 | A | Genuinely inclusive — designed for the full range of users |
| 70–84 | B | Strong foundation with specific gaps |
| 55–69 | C | Default assumptions present but addressable |
| 40–54 | D | Significant exclusion patterns — meaningful redesign needed |
| 0–39 | F | Actively excludes large segments of the population |

---

## Audit Process

### Step 1 — Identify the Assumed Default User

Before scoring, answer:
- Who was imagined as the primary user during design?
- What device, internet speed, literacy level, and language did the team design for by default?
- What body, gender, age, ethnicity, and socioeconomic situation did the team assume?
- Were any of these assumptions ever explicitly questioned?
- Who was NOT in the room when decisions were made?

Write these out. They are the root cause of most inclusive design failures.

### Step 2 — Score Each Dimension

For each dimension, assign 0–10, list findings with severity, and write specific action items.

**Severity Tags:**
- CRITICAL — Actively harmful or exclusionary to a specific group; potential legal exposure
- MAJOR — Significantly limits usability or belonging for a meaningful user segment
- MINOR — Improvement opportunity that would meaningfully expand inclusion

### Step 3 — Representation Audit

Conduct a systematic inventory:

**Imagery Audit:**
- Count representation by ethnicity, age, ability, body type, gender presentation in all images
- Do all gender-neutral products show people of multiple ethnicities, body types, ages, and abilities?
- Are people with disabilities shown in non-disability contexts (just living, not "overcoming")?
- Are older adults shown in contemporary (not stereotypical/infantilizing) contexts?

**Name Diversity Scan:**
- In examples, placeholders, personas, and sample data: are names culturally diverse?
- Do they signal a single cultural/geographic context, or do they reflect global diversity?
- Are names in form fields flexible enough to accept non-Western formats?

**Scenario Representativeness:**
- In onboarding, help content, and examples: whose lives are depicted?
- Do example scenarios include diverse family structures, relationship types, living situations?
- Are scenarios showing people different from your team in authentic (not tokenized) contexts?

### Step 4 — Socioeconomic Barrier Audit

Test against real-world constraints:

**Device Access Testing:**
- Does the product work on mid-range Android phones (not just flagship devices)?
- Are interactions possible on smaller screens without complex gestures?
- Does the product degrade gracefully or fail completely on older devices?

**Connectivity Testing:**
- Test on 3G or slower connection speeds
- Does the product require fast streaming, large downloads, or real-time uploads?
- Are there offline or low-bandwidth modes?

**Payment Barrier Check:**
- Can users access core functionality without a credit card?
- Is a residential address required for features that don't need it?
- Are there paywalls or premium tiers that lock out essential functionality from lower-income users?
- Is the cost transparent upfront or hidden in subscription/IAP flows?

**Regional Requirement Scan:**
- Does the product require a US phone number, ZIP code, or mailing address?
- Are there country restrictions that exclude certain regions?
- Can users access the product from all countries their audience lives in?

### Step 5 — Intersectionality Mapping

Identify how dimensions compound for specific groups:

- A woman from a non-English-speaking country faces barriers on both Language and Gender dimensions
- A low-income person with a disability faces barriers on Socioeconomic and Accessibility dimensions
- An undocumented person in a non-Western country may face barriers on Address, Privacy, Legal Status, and Regional dimensions

Map these compounding barriers and flag as CRITICAL.

### Step 6 — Render the Report

Use the output format below. Do not skip sections.

---

## Output Format

```
# DEI / Inclusive Design Audit Report

**Product / Feature:** [name]
**Assumed Default User (identified):** [description of who the team designed for]
**Team Composition (if known):** [note diversity of design/decision-making team]
**Audit Date:** [date]

---

## Overall Inclusive Design Score: [X/100] — [Grade]

[1–2 sentence summary]

---

## Dimension Scores

| Dimension | Score | Finding Summary |
|-----------|-------|----------------|
| Representation | X/10 | |
| Language & Tone | X/10 | |
| User Model Assumptions | X/10 | |
| Socioeconomic Inclusion | X/10 | |
| Cultural & Regional Sensitivity | X/10 | |
| Gender & Identity | X/10 | |
| Systemic Exclusion Patterns | X/10 | |

---

## Exclusion Patterns Detected

[If none: "No systemic exclusion patterns detected."]
[If present: name each with severity and action item]

---

## Representation Audit Results

### Imagery
- Ethnicities represented: [list]
- Age range: [describe]
- Abilities represented: [describe]
- Body types: [describe]
- Gender presentation: [describe]
- Notable gaps: [list]

### Names in Examples
- Cultural diversity: [assessment]
- Geographic bias: [note]
- Format flexibility: [note]

### Scenarios
- Family structures depicted: [list]
- Living situations: [describe]
- Geographic/cultural contexts: [list]
- Gaps: [note]

---

## Socioeconomic Barrier Assessment

**Device Access:** [mid-range devices? older devices? screen size handling?]
**Connectivity:** [low-bandwidth capable? offline mode?]
**Payment Barriers:** [credit card required? premium locks? transparent pricing?]
**Regional Access:** [country restrictions? address requirements?]

---

## Findings & Action Items

### [Dimension] — [X/10]

**[CRITICAL/MAJOR/MINOR]** [Finding]
> Action: [Specific fix]

---

## Intersectionality Map

[For groups experiencing barriers across multiple dimensions, note the compounding effect]

---

## Who This Product Is Currently Built For

[Honest characterization of the implicit user this product serves well]

## Who This Product Is Currently Missing

[Honest characterization of the users this product fails or excludes]

---

## Top 5 Priority Fixes

1.
2.
3.
4.
5.

---

## Design Team Recommendation

[Note: If the design team does not reflect the diversity of the user base, that is a root cause. Recommend specific steps to diversify the team or bring in advisory groups from underrepresented communities.]
```

---

## Dimension Reference Guide

### 1. Representation

Representation in digital products communicates who belongs and who is an afterthought. This is true in images, illustrations, names used in examples, characters, and whose stories get told.

**Audit questions:**
- Do images and illustrations show people of multiple ethnicities, body types, ages, and abilities?
- Are characters in examples named with diverse names, not just Western defaults (John, Sarah)?
- Are the scenarios depicted in onboarding and marketing ones that multiple types of users can see themselves in?
- Is diversity shown incidentally (just people being people) or only in explicitly diversity-themed content?
- Are older adults shown in contemporary, autonomous contexts (not needing help)?
- Are people with disabilities shown in non-disability-specific contexts?
- Are there family structures beyond nuclear (single parents, multigenerational, chosen family)?

### 2. Language & Tone

Language encodes assumptions. Ableist idioms normalize exclusion. Gendered defaults exclude. Formal language requirements exclude users for whom English is a second language or whose literacy is lower.

**Audit questions:**
- Does the product use gender-neutral language by default? ("you" not "he," "they" not "she or he")
- Are there ableist idioms or metaphors in the copy? ("tone-deaf," "blind spot," "falls on deaf ears," "crazy fast")
- What reading level is the copy written at? Is that appropriate for the user base? (Grade 8 or below for general audiences)
- Does the language assume a shared cultural context (American holidays, Western idioms, colloquialisms)?
- Are there words or phrases that would not translate across cultures?
- Is passive voice used (harder to understand) or active voice?
- Are error messages jargon-heavy or user-friendly?

### 3. User Model Assumptions

Every product embeds a theory of who the user is. When that theory is never questioned, it reflects whoever was in the room when decisions were made.

**Audit questions:**
- What device is assumed? Is the experience degraded on mid-range Android phones?
- What connectivity is assumed? Does the product fail or slow dramatically on 3G or in low-bandwidth regions?
- What digital literacy is assumed? Are there interactions that require prior experience with specific UI patterns?
- What language proficiency is assumed?
- What physical environment is assumed (quiet home, stable electricity, privacy)?
- Is the product designed for always-online, or does it work offline or with intermittent connectivity?

### 4. Socioeconomic Inclusion

Many products create invisible barriers that exclude users who don't have the same financial resources as the team that built them.

**Audit questions:**
- Can users access core functionality without a credit card? Is a debit card required?
- Is a formal residential address required for features that don't need it?
- Does the product require purchasing a device that a significant portion of the target population can't afford?
- Are there paywalls that disproportionately affect lower-income users?
- Are costs transparent or hidden in fine print?
- Does the product work on free/low-cost data plans (does it require huge downloads)?
- Are there in-app purchase dark patterns targeting lower-income users?

### 5. Cultural & Regional Sensitivity

Designing for a global audience means questioning every default format, color association, and assumed context.

**Audit questions:**
- Are date and time formats localized or configurable (not just MM/DD/YYYY)?
- Does the address form work for international addresses (no mandatory state/ZIP for non-US)?
- Are phone number fields E.164-compatible (accept international formats)?
- Do color choices carry unintended meaning in other cultures (red = danger in US; red = luck in China)?
- Are idioms in the copy translatable or culture-specific?
- Is currency handling appropriate for the regions you serve?
- Are holidays/seasonal references global or US/Western-centric?
- Do names of people/companies in examples represent global diversity?

### 6. Gender & Identity

Binary gender assumptions in product design erase non-binary, transgender, and gender-nonconforming users. This affects a meaningful and growing portion of every user base.

**Audit questions:**
- Does the product require gender selection? If so, does it offer options beyond male/female?
- Are there open-text fields for gender identity, or is it a closed list?
- Are titles (Mr./Ms./Mrs.) required, or can they be omitted or customized?
- Does the product use gendered language when referring to the user ("Welcome back, sir")?
- Are names stored and displayed flexibly (chosen name vs. legal name)?
- If the product uses pronouns (profiles, introductions), are options beyond she/he/they available?
- Does the product make assumptions about family or relationship structure based on gender?

### 7. Systemic Exclusion Patterns

Some exclusions aren't in any single design decision — they emerge from the combination of many reasonable-seeming choices that together create a barrier for specific groups.

**Audit questions:**
- Is there a flow that requires a feature unavailable in certain countries?
- Does the verification or trust system disadvantage people without formal IDs, established credit, or stable addresses?
- Do recommendation algorithms or personalization systems risk encoding bias (favoring certain ethnicities, genders, ages)?
- Are there flows that assume family structures, relationship types, or living situations that not all users share?
- Does the product require a phone number that assumes cellular access available in that region?
- Are there workflows where someone's primary language, immigration status, or lack of formal ID creates cascading barriers?
- Does the product penalize people without certain privileges (e.g., ability to receive mail, access banking, pass verification)?

---

## Reference Framework

Grounded in Matthew Stephens' practice of ethical, inclusive design, which holds that:

- Accessible design and inclusive design are complements, not the same thing — accessibility addresses barriers for disabled users; inclusive design addresses the full range of human diversity
- Representation matters because products communicate who belongs
- The default user is always a design choice — and usually an unchecked one
- Harm doesn't require bad intent — it only requires a failure to question assumptions
- Designing for the margins makes the product better for everyone
- Intersectionality is not a buzzword — it is the reality that people experience barriers on multiple dimensions at once
- The most important inclusion work is not in the product — it is in the team making the product. A homogeneous team will always miss exclusions a diverse team would catch.

---

## Cross-References

Related skills: accessibility-audit, cognitive-accessibility, older-audiences-auditor
