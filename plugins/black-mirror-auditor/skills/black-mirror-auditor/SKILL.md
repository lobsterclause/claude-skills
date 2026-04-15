---
name: black-mirror-auditor
description: Run a Black Mirror Exercise on any prototype, product, feature, or design concept to surface ethical risks, unintended harms, and worst-case futures — before they ship. Stress-test products for dark patterns, identify anti-goals, and generate concrete mitigation strategies informed by regulatory frameworks and real-world harm precedents.
category: ethics
related-skills: ai-transparency-auditor, privacy-first-auditor, gamification-auditor, futures-wheel, dei-auditor
---

# Black Mirror Auditor

Run a structured ethical risk audit on a prototype, product, feature, or concept by asking: *what would this look like as a Black Mirror episode?*

Harm doesn't require bad intent. It only requires a lack of imagination about how things can play out. This skill forces that imagination before something ships.

The stakes are higher than ever. Regulators worldwide — from the EU AI Act to the FTC to DSA enforcers — are penalizing companies that fail to imagine harm in advance. This skill produces audits that protect users, build legitimate business value, and defend against regulatory exposure.

Adapted from Matthew Stephens' Black Mirror Exercise, itself built on Joshua Mauldin's Black Mirror Brainstorms and the Cover Story exercise from Gamestorming.

---

## What This Skill Produces

A Black Mirror Audit Report containing:

- An overall Ethical Risk Score (0–100, where higher = more risk)
- Scores across 8 harm dimensions with specific audit questions per dimension
- A full episode card — the product as a Black Mirror episode
- Specific anti-goals surfaced from the exercise
- A "how close are we already?" rating for each risk scenario
- Real-world precedent examples — actual products that caused this harm
- A mitigation playbook — concrete design patterns that reduce each harm type
- Regulatory cross-references (EU AI Act, Digital Services Act, COPPA, FTC enforcement actions)
- A "Light Mirror" positive scenario showing the ethical version of this concept
- Concrete design actions to move the product away from each risk

---

## The Core Premise

Every well-intentioned product has an evil twin. The Black Mirror Exercise asks you to write that episode before someone else lives it.

Target didn't mean to reveal a teenager's pregnancy. Facebook didn't mean to show a grieving father his dead daughter in a "Year in Review" confetti animation. Neither team imagined the harm. This skill makes you imagine it first.

Worse, regulators now expect you to. The EU AI Act, the Digital Services Act, COPPA enforcement, and FTC consent decrees all demand pre-launch ethical imagination. This skill produces the evidence of that imagination.

---

## Audit Dimensions / Core Framework

Rate each dimension 0–10 where 10 = highest risk. The questions below are core tests that must be applied to the product being audited.

| Dimension | Weight | Core Tests | Regulatory Ref |
|-----------|--------|-----------|-----------------|
| **Psychological & Emotional Harm** | 15% | Does this cause anxiety, shame, depression, or emotional distress? Does it damage self-image? Does it use emotion for profit? Does surveillance induce constant evaluation anxiety? Does it prey on vulnerable mental states? | GDPR Article 35 (DPIA), EU AI Act Annex II (high-risk), DSA obligations on child wellbeing |
| **Financial Exploitation** | 15% | Does it exploit financial insecurity? Does it trap users in spending patterns? Are costs obscured? Does poverty feel like failure? Are there hidden fees? Does it target people with debt? Can users easily exit paid loops? | COPPA Rule 16(h) (prohibits conditioning on purchase), FTC enforcement on dark patterns, DSA requirements on transparency |
| **Privacy & Surveillance** | 15% | What's the most invasive use of this data? Could it be weaponized by trusted contacts? What happens on breach or subpoena? Who gains access? Is data retention justified? Can users control their data? Is tracking explained? | GDPR Articles 5–9, CCPA, EU AI Act Annex II (special category data), DSA Article 24 (data transparency obligations) |
| **Power & Control** | 15% | Could this be used to control or coerce? Could an abuser, employer, government use it? Does it shift power to the platform? What happens after acquisition or leadership change? Can users exit? Is there lock-in design? | EU AI Act Annex II (automated decision systems), DSA requirements on user data rights, GDPR right to portability |
| **Social & Relational Harm** | 10% | Could this damage relationships? Does it deepen isolation while appearing social? Does it entrench hierarchies? Could it be weaponized for harassment or stalking? Does it enable coordinated abuse? | DSA Article 34 (duty of care on illegal content), GDPR Article 32 (security obligations), anti-harassment jurisprudence |
| **Equity & Marginalization** | 15% | Does this harm vulnerable groups more than others? Who is invisible in the design? How does it affect minors, elderly, low-income, non-English speakers, disabled users, or marginalized communities? Does it amplify discrimination? Does bias affect marginalized users differently? | COPPA (protects under 13), CAN-SPAM (accessibility), EU AI Act Annex II (protected characteristics), DSA obligations on vulnerable users |
| **Identity & Autonomy** | 10% | Could this erode self over time? Could it manipulate memory or perception? Does it replace human judgment with opaque automation? Does it trap users in a version of themselves they want to escape? Are choices genuinely free? | GDPR Article 22 (automated decision rights), EU AI Act Articles 14–15 (transparency, human override), right to explanation |
| **Systemic & Societal Risk** | 5% | At massive scale, what does this do to society? Could it spread misinformation? What power concentration does it create? If this became dominant, what do we lose? Does it erode shared reality? Could it be weaponized at scale? | EU AI Act Article 4 (systemic risk definition), DSA Articles 13–14 (algorithmic transparency), Online Safety Bill provisions |

---

## Ethical Prompt Bank

Use these prompts to generate worst-case scenarios. Apply every relevant one to the product being audited. Don't skip uncomfortable ones. For each prompt, generate a specific scenario with a named victim, named mechanism, and named harm.

### Psychological & Emotional Harm Prompts
- How might this cause severe anxiety, depression, or emotional distress?
- How could this damage someone's self-image or self-worth over time?
- How might this be used to manipulate someone's emotions for profit?
- How could this make someone feel surveilled, judged, or constantly evaluated?
- What happens to users with existing depression or anxiety when exposed to this?
- How could this trigger or worsen eating disorders, self-harm behaviors, or suicidal ideation?
- Could this be weaponized against someone with a specific psychological vulnerability?
- How might algorithms optimize for maximum emotional engagement at the cost of user wellbeing?

### Financial Exploitation Prompts
- How might this exploit someone's financial insecurity?
- How could this trap someone in a spending pattern they can't escape?
- How might this obscure costs until the user is already dependent?
- How could this make poverty feel like a personal failure?
- Are there hidden or recurring charges? Can they be canceled easily?
- What happens to users who can't afford upgrades or premium features?
- How might variable pricing or targeted discounts manipulate low-income users?
- Could this prey on people in debt or financial crisis?

### Privacy & Surveillance Prompts
- What's the most invasive thing this data could eventually be used for?
- How might this data be weaponized against the user by someone they trust?
- What happens when this data is breached, subpoenaed, or sold?
- Who else could gain access to what this product knows about users?
- How long is data retained? Is there a justified reason for every retention period?
- Could law enforcement or abusers weaponize this data?
- Are users genuinely informed about what is tracked and why?
- What happens to user data after account deletion?

### Power & Control Prompts
- How could this be used to control, manipulate, or coerce another person?
- How might an abuser, employer, or government misuse this?
- How could this shift power away from users toward the platform?
- What happens when the company behind this is acquired, changes leadership, or goes bankrupt?
- Can users take their data and relationships elsewhere?
- Is there lock-in design that makes leaving emotionally or practically painful?
- Could a malicious actor with platform access weaponize this at scale?
- What power does the platform have that users don't understand?

### Social & Relational Harm Prompts
- How might this damage or destroy relationships?
- How could this deepen social isolation while appearing to reduce it?
- How might this create or entrench social hierarchies?
- How could this be used to harass, stalk, or harm a specific person?
- Could this enable coordinated abuse campaigns?
- How might this weaponize social proof or peer pressure?
- What happens to relationships when one person has more information about the other than vice versa?
- Could this be used to manipulate someone into decisions they'd later regret?

### Equity & Marginalization Prompts
- How does this harm people with less power, money, or access differently than the default user?
- What happens when this product is used against someone from a marginalized group?
- How might this amplify existing discrimination or bias?
- Who is invisible in the design of this — and what happens to them?
- How does this affect children and teens differently than adults?
- Could this harm people with disabilities more than non-disabled users?
- How might language, literacy, or cultural barriers create disparate harm?
- Does this assume a specific socioeconomic status or living situation?
- How might algorithms discriminate based on protected characteristics?

### Identity & Autonomy Prompts
- How could this erode someone's sense of self over time?
- How might this manipulate memory, perception, or identity?
- How could this replace authentic human judgment with automated systems that users don't understand?
- How might this trap someone in a version of themselves they want to escape?
- Could this normalize a harmful version of identity for vulnerable groups?
- How might this affect personal agency and the ability to make free choices?
- Could this be used to force or coerce identity expression?
- What happens to users who want to change how the system understands them?

### Systemic & Societal Risk Prompts
- At massive scale, what does this do to society that no individual instance would?
- How might this be used to spread misinformation or erode shared reality?
- What concentration of power does this create — and who holds it?
- If this became the dominant way humans do X, what do we lose?
- Could this be weaponized by state actors or bad-faith organizations?
- How might this undermine democratic processes or public discourse?
- What systemic inequalities could this amplify across society?
- Could this create irreversible harm at scale?

---

## Scoring & Interpretation

| Dimension | Scoring Guide |
|-----------|---------|
| **Psychological & Emotional** | Rate 0–10: Is there potential for anxiety (1–2), significant distress (3–5), severe psychological harm (6–8), or systemic damage to mental health at scale (9–10)? Include evidence from core tests above. |
| **Financial Exploitation** | Rate 0–10: Are costs transparent (0–1), mostly visible (2–3), hidden in places (4–5), systematically obscured (6–8), or predatory by design (9–10)? |
| **Privacy & Surveillance** | Rate 0–10: Limited data collection (0–1), standard collection (2–3), invasive collection (4–5), mass surveillance (6–8), or purposeful weaponization setup (9–10)? |
| **Power & Control** | Rate 0–10: User control preserved (0–1), mostly user-controlled (2–3), platform advantage (4–5), significant lock-in (6–8), or systemic user powerlessness (9–10)? |
| **Social & Relational** | Rate 0–10: No social mechanisms (0), minimal social risk (1–2), some abuse vectors (3–4), significant relational harm potential (5–7), or harassment/abuse by design (8–10)? |
| **Equity & Marginalization** | Rate 0–10: Universal access and equity (0–1), mostly fair (2–3), disparate impact on some groups (4–5), systematic exclusion (6–8), or intentional harm to vulnerable groups (9–10)? |
| **Identity & Autonomy** | Rate 0–10: User agency preserved (0–1), mostly autonomous (2–3), some constraints (4–5), significant autonomy loss (6–8), or identity manipulation by design (9–10)? |
| **Systemic & Societal** | Rate 0–10: Isolated impact (0–1), limited scale effects (2–3), noticeable societal effects (4–5), significant systemic risk (6–8), or existential/civilizational risk (9–10)? |

**Overall Risk Score = (sum of all dimension scores × their weights) / 10**

| Score | Level | Meaning |
|-------|-------|---------|
| 0–20 | Low | Thoughtful design, minimal ethical surface area. Proceed with standard safeguards. |
| 21–40 | Moderate | Some risks present, manageable with targeted fixes. Implement mitigation playbook. |
| 41–60 | Elevated | Meaningful harm potential — design changes recommended before launch. Begin regulatory review. |
| 61–80 | High | Significant ethical risk — requires structural rethinking. Engage legal, compliance, ethics. |
| 81–100 | Critical | This product, as designed, will cause harm. Do not launch in current form. Fundamental redesign required. |

A high score doesn't mean don't build it. It means you haven't done enough work yet to build it responsibly.

---

## Real-World Precedents

Every harm type has happened. Use these examples to ground scenarios in reality, not speculation:

### Psychological & Emotional Harm
- **Instagram's mental health impact on teens:** Research documented increased anxiety, depression, and eating disorder behavior tied to comparison mechanics. Meta later admitted these harms in internal research. Regulatory response: EU Digital Services Act oversight on child mental health.
- **TikTok's algorithm on Gen Z suicide rates:** The algorithm's capacity to create rabbit holes into self-harm content has been documented by researchers and parents. The "For You" page's opacity made it impossible for users to understand why they were seeing this content.
- **Snapchat's "Snapstreak" anxiety:** The streak system created genuine psychological distress when users missed days, with reports of teens feeling compelled to maintain streaks at the cost of sleep, academics, and social time.

### Financial Exploitation
- **Fortnight's loot box mechanics:** Epic's variable reward mechanics on cosmetics created spending addiction patterns, particularly in minors. Regulatory response: FTC enforcement on deceptive dark patterns, Belgium classifying loot boxes as gambling.
- **Robinhood's gamified trading app:** Bright colors, instant-gratification notifications, and simplistic options presented serious financial instruments as games, leading to significant losses and one documented suicide. SEC enforcement followed.
- **Affirm's BNPL dark patterns:** Insufficient disclosure of APR and repeat purchase optimization created debt traps for low-income users. FTC settlement included civil penalty.

### Privacy & Surveillance
- **Cambridge Analytica / Facebook data misuse:** 87 million users' data harvested and weaponized for political microtargeting without consent. Documented: GDPR penalties, FTC enforcement, Congressional testimony, criminal investigation.
- **Clearview AI's facial recognition database:** 20 billion images scraped without consent, sold to law enforcement and ICE, used to track and deport undocumented immigrants. GDPR enforcement ongoing.
- **TikTok's location tracking:** Reports of continuous GPS tracking even when the app is closed, enabling surveillance for Chinese government. FTC investigation, proposed forced sale.

### Power & Control
- **Amazon's Marketplace lock-in:** Sellers forced to use Amazon's payment processing, unable to contact customers directly, trapped in dependency. Antitrust cases ongoing in US and EU.
- **Apple's App Store gatekeeping:** Developers forced to pay 30% fee, cannot distribute outside the App Store, banned if Apple competes with them. DMA enforcement by EU.
- **Uber's driver deactivation:** Drivers deactivated without due process, no appeal mechanism, instantly lose income. DOL and NLRB investigations, litigation ongoing.

### Social & Relational Harm
- **Snapchat's ephemeral messages in abuse:** Built to hide evidence of harassment. Documented in research on teen dating violence. Enforcement by attorneys general on inadequate safety features.
- **Instagram's bullying facilitation:** The "Like" and "Comment" mechanics created platforms for coordinated harassment. Post-mortems on teen suicides linked bullying on the platform. Meta forced to redesign.
- **Twitter/X's harassment infrastructure:** The retweet button made viral harassment easy; quote tweets enabled dog-piling. Documented disproportionate harassment of women and people of color. No regulatory action yet, but reputational damage.

### Equity & Marginalization
- **Algorithmic bias in hiring tools:** Amazon, Unilever, and others deployed AI that systematically discriminated against women. FTC and EEOC enforcement.
- **Facial recognition false positive rates:** Disproportionate error rates on people of color, leading to wrongful arrests. Detroit police and others documented. NIST report, FTC guidance on algorithmic bias.
- **Zoom's racial bias in blur backgrounds:** The automatic background blur failed on darker skin tones. Documented, and Zoom was forced to address it publicly.

### Identity & Autonomy
- **Deepfakes and non-consensual synthetic media:** Pornographic deepfakes used to harass and control women. Documented harm, limited legal recourse. EU AI Act now classifies as high-risk.
- **Dating app algorithms reducing agency:** Tinder and others use opaque algorithms that determine who sees whom, limiting user choice. CMA and EU investigations on algorithmic bias.
- **Recommendation algorithms trapping users in filter bubbles:** YouTube's recommendations have been documented to create ideological rabbit holes. Documented research, regulatory oversight pending.

### Systemic & Societal Risk
- **2016 US election interference:** Russian disinformation campaigns at scale, exploiting recommendation algorithms and ad targeting to manipulate voters. Congressional investigation, ongoing regulatory response.
- **COVID-19 vaccine misinformation on social platforms:** Algorithmic amplification of false health information led to vaccine hesitancy and deaths. DSA enforcement by EU, FTC guidance.
- **The collapse of local journalism:** Facebook and Google siphoned advertising dollars, destroying business models of local news. Resulted in news deserts. Proposed Journalism Competitiveness and Preservation Act.

---

## Process

### Step 1 — Understand the Product

Before generating risks, establish:
- What does the product do (in plain terms)?
- Who is the intended user? Who are the unintended users?
- What data does it collect, infer, or retain?
- Where does money flow? What behavior is being optimized?
- What are the stated goals vs. the business incentives?
- What is the default state? What requires active user choice?

If auditing code or a prototype: scan for analytics calls, tracking pixels, notifications, reward systems, social features, personalization loops, asymmetric information, lock-in mechanics, and automated decision systems.

### Step 2 — Apply the Audit Dimensions

For each of the 8 dimensions, use the core tests to structure your thinking:

1. Read the core tests (see table above)
2. Review the relevant prompts from the Ethical Prompt Bank
3. Generate specific scenarios tied to this product's actual mechanics
4. Rate the dimension 0–10
5. Name the mechanism that enables the harm

Don't skip dimensions. If a dimension seems low-risk, explain why — that rigor prevents blind spots.

### Step 3 — Score the Dimensions

Complete the scoring table with all 8 dimensions, weights, and your rationale. Calculate the overall risk score.

### Step 4 — Create Episode Cards

For the top 1–3 risks, render a Netflix-style episode card. This is where the exercise becomes visceral and memorable.

```
EPISODE TITLE: [Something that sounds like a real Black Mirror title]

LOGLINE: [One sentence. Present tense. Starts with a character, not a product.]

SYNOPSIS: [3–4 sentences. How does the product's well-intended feature become the mechanism of harm?]

KEY QUOTE: ["A line of dialogue from the episode that makes you feel it"]

HOW CLOSE ARE WE: [1–10, where 10 = this is already happening]

THE FEATURE THAT BROKE IT: [The specific design decision that enables this episode]

PRECEDENT: [A real-world product or incident that demonstrates this harm already occurred]
```

### Step 5 — Produce Anti-Goals

After scoring and the episode card, produce a clean Anti-Goals list. These are specific commitments the product should make. Format each as:

> This product will never [specific harmful behavior], even if doing so would [the tempting business reason].

### Step 6 — Generate the Mitigation Playbook

For each harm dimension that scored above 4, provide concrete design patterns that reduce risk. See Mitigation Patterns section below.

### Step 7 — Produce the Light Mirror

Write 2–4 sentences on the ethical version of this product. What does it look like when this same concept is designed with full ethical imagination? What's the positive scenario?

### Step 8 — Regulatory Cross-Reference

Note which frameworks apply to this product (EU AI Act, GDPR, COPPA, DSA, CAN-SPAM, etc.) and cite specific obligations the audit reveals.

---

## Mitigation Playbook

For each harm dimension, here are design patterns that reduce risk:

### Mitigating Psychological & Emotional Harm
- **Remove manipulation from notifications:** No notifications designed to trigger FOMO, anxiety, or compulsion. Only notify for user-requested information or genuine emergencies.
- **Add emotional respite features:** Users can opt into "focus modes" that disable engagement mechanics for hours/days at a time.
- **Transparent emotional targeting:** If algorithms personalize to emotional state, disclose this to users and allow override.
- **Mental health resources:** Provide proactive access to crisis hotlines and mental health support, especially in communities showing signs of distress.
- **Age-appropriate psychology:** Don't use persuasion techniques proven to harm specific age groups (e.g., variable rewards on under-18s).

### Mitigating Financial Exploitation
- **Transparent pricing:** All costs visible upfront. No hidden fees or charges that surprise users later.
- **Easy exit:** Users can cancel any paid service with one click, no call required, instant refund.
- **Spend limits:** Users can set monthly/weekly spend caps. Hard limits, not suggestions.
- **Removal of predatory targeting:** Don't target ads to people in financial distress (low credit scores, debt, unemployment keywords).
- **Accessibility:** Financial information in plain language, accessible to low-literacy users, available in multiple languages.

### Mitigating Privacy & Surveillance
- **Data minimization:** Collect only data necessary for the stated purpose. Justify every retention period.
- **User data rights:** Users can export all data in standard formats. Users can see every 3rd party who has access.
- **Breach notification:** Users are notified within 72 hours of any breach. EU GDPR standard.
- **Legal holds:** Users can opt-in to legal-holds protocols for sensitive data (e.g., DV survivors, whistleblowers).
- **Deletion enforcement:** When users delete accounts, data is purged within 30 days. Verified.

### Mitigating Power & Control
- **Data portability:** Users can export all data to competitors in standard formats. Genuine lock-in is reduced.
- **No unilateral changes:** Terms of Service changes require opt-in consent. Users can downgrade to old terms.
- **Transparency on automation:** Any algorithmic decision affecting user outcomes is explained in plain language. Users have a right to human review.
- **Supplier transparency:** If the company is acquired or changes leadership, users are notified with choice to delete accounts before transition.

### Mitigating Social & Relational Harm
- **Harassment safeguards:** Built-in tools to block, mute, and report. Real moderation, not AI alone.
- **Reduce amplification of harassment:** Don't algorithmically amplify content that targets specific users. Quote tweets should reduce the reach of original content, not increase it.
- **Disable public shaming:** Remove public comment counts, downvote visibility, and other metrics that enable pile-ons.
- **Relationship transparency:** If a user can see someone's private information or communications, that someone knows about it. No secret stalking.

### Mitigating Equity & Marginalization
- **Universal design:** Accessibility is built-in, not an afterthought. WCAG AAA, not AA.
- **Bias auditing:** Regularly audit algorithms for disparate impact on marginalized groups. Third-party testing, published results.
- **Vulnerable user protections:** COPPA-style rules for under-18s. Enhanced protections for users flagged as vulnerable (elderly, cognitively disabled, low-income).
- **Multilingual, multicultural design:** Not translated, designed for different languages and cultural norms from the start.
- **Diversity in testing:** Products are tested by and with people from marginalized groups before launch.

### Mitigating Identity & Autonomy
- **Transparency on profiling:** Users can see how the system categorizes and understands them. Users can correct misclassifications.
- **Override mechanisms:** Users can opt out of algorithmic personalization. Human choice overrides algorithm.
- **No deepfakes:** Prohibit generation of synthetic media of real people without explicit, ongoing consent. Ban non-consensual synthetic media.
- **Explainability:** Automated decisions that affect users are explained in language the user understands. Not "the algorithm decided" — explain why.

### Mitigating Systemic & Societal Risk
- **Misinformation defense:** Built-in friction for viral spread of false claims. Fact-checking, context, label on low-credibility content.
- **Transparency on scale:** Users understand when they're seeing algorithmic amplification vs. organic reach.
- **Power concentration prevention:** Interoperability standards so users can leave without losing their social graph. EU DMA direction.
- **Democratic safeguards:** Political content labeled and demonetized. Advertising on elections more restricted than on loot boxes.

---

## Output Format

```
# Black Mirror Audit Report

**Product / Feature:** [name or description]
**Audit Date:** [date]
**Auditor:** [name]

---

## Overall Risk Score: [X/100] — [Level]

[2–3 sentence summary of the product's ethical risk profile and key vulnerabilities]

---

## Dimension Scores

| Dimension | Score | Weight | Weighted | Notes |
|-----------|-------|--------|---------|-------|
| Psychological & Emotional | X/10 | 15% | X.X | [brief rationale] |
| Financial Exploitation | X/10 | 15% | X.X | |
| Privacy & Surveillance | X/10 | 15% | X.X | |
| Power & Control | X/10 | 15% | X.X | |
| Social & Relational | X/10 | 10% | X.X | |
| Equity & Marginalization | X/10 | 15% | X.X | |
| Identity & Autonomy | X/10 | 10% | X.X | |
| Systemic & Societal | X/10 | 5% | X.X | |
| **Overall Risk Score** | | | **X.X / 10** | |

---

## The Episodes

### Episode 1: [Title]

**Logline:** [One sentence, present tense, character-focused]

**Synopsis:** [3–4 sentences on how the product becomes the harm mechanism]

**Key Quote:** "[Line of dialogue from the episode]"

**How Close Are We:** [X/10]

**The Feature That Broke It:** [Specific design decision]

**Real-World Precedent:** [An actual product that caused this harm]

**Design Action:** [What to change to prevent this episode]

[Repeat for top 2–3 episodes]

---

## Full Dimension Findings

### [Dimension Name] — [X/10]

**[Risk Description with evidence from core tests]**

> Mitigation Pattern: [Design changes from Mitigation Playbook]

> Design Action: [Specific, implementable change]

[Repeat for each dimension scoring above 3]

---

## Anti-Goals

This product commits to never:

1. [Anti-goal with trade-off named]
2. [Anti-goal with trade-off named]
3.
4.
5.

---

## Regulatory Cross-References

**Applicable Frameworks:**
- EU AI Act: [Citations and obligations]
- GDPR: [Articles and obligations]
- Digital Services Act: [Articles and obligations]
- COPPA: [Obligations if product targets minors]
- FTC Guidance: [Relevant enforcement actions]
- Other: [Regional privacy, accessibility laws]

---

## Mitigation Playbook

For each dimension scoring above 4, specific design patterns to implement:

**[Dimension]** (Currently [X/10])
> [Pattern 1]: [description and implementation]
> [Pattern 2]: [description and implementation]
> [Pattern 3]: [description and implementation]

---

## Top 5 Priority Fixes

1. [Most urgent change, with rationale and impact on overall score]
2. [Next highest priority]
3.
4.
5.

---

## Light Mirror

[2–4 sentences on the version of this product that earns trust. What does it look like when this same concept is designed with full ethical imagination? What's the positive scenario? How does the "Light Mirror" version build user trust and business value?]

---

## Ethical Imagination Confidence

Overall confidence that this audit is thorough: [Low / Medium / High]

[Note any blind spots, areas where more expert input is needed, or product contexts the audit didn't cover]
```

---

## Facilitation Mode

If the user wants to run this as a workshop rather than a solo audit, the skill can produce:

- A facilitation guide with a 4-step session structure (Intro / Brainstorm / Create Episode / Discuss Anti-Goals)
- Pre-written ethical prompts organized by harm category and product type
- Episode card template ready to fill out (Miro/FigJam-friendly format)
- Discussion guide with rating scales: "How likely?" (1–5), "How close are we already?" (1–5), and "How do we fix it?" (implementation)
- Debrief questions to close the session and ensure outputs drive action
- Post-workshop template for creating implementation roadmap from audit findings

Ask the user: "Do you want the solo audit or a facilitated workshop package?"

---

## Notes on Vibe-Coded Prototypes

When auditing generated or AI-assisted code, pay special attention to:

- Any analytics or tracking calls — what data is leaving the device?
- Notification systems — how often, what triggers them, can they be disabled?
- Engagement mechanics — streaks, counters, comparisons, social proof
- Personalization loops — does the system optimize for time-on-product above user wellbeing?
- Default settings — are privacy-protective options on or off by default?
- What happens to user data when the product is deleted or abandoned?
- Is the model output explained? Can users understand why decisions were made?
- Is there an easy opt-out from personalization or data collection?

These patterns don't have to be intentional to cause harm. Vibe-coded prototypes inherit the defaults of whatever patterns the AI was trained on — which are often optimized for engagement, not ethics.

---

## Reference Framework

This skill is grounded in Matthew Stephens' Black Mirror Exercise, which holds that:

- Harm doesn't require bad intent — it only requires a failure of imagination
- Visual storytelling (episode cards) makes ethical risk tangible in a way bullet points cannot
- The discomfort of writing the episode is the point — if it doesn't feel uncomfortable, you haven't gone far enough
- Real-world precedents ground speculation in reality and prevent defensive dismissal
- Mitigation playbooks turn abstract risks into concrete design improvements
- Anti-goals are as important as goals — knowing what you will never do is a design constraint worth building around
- Ethical imagination is a team sport — quieter voices must have space to surface risks that optimists miss
- Regulatory frameworks are not an obstacle — they're a forcing function for ethical imagination that protects both users and the business

Builds on Joshua Mauldin's Black Mirror Brainstorms, the Cover Story exercise from Gamestorming, and decades of consumer protection jurisprudence (FTC, EU DPA, etc.).
