---
name: ai-transparency-auditor
description: Audit AI-powered features and products for transparency, explainability, consent, bias risk, human oversight, and regulatory compliance (EU AI Act) — producing a scored report with specific fixes, bias testing methodology, model card template, and consent pattern examples. Use this skill whenever someone needs to evaluate an AI feature before shipping, check if an AI product is honest with users about what it is and how it works, audit for model bias or fairness concerns, review consent flows for AI data use, ensure human override paths exist for high-stakes AI decisions, or assess regulatory risk. Trigger on phrases like AI transparency audit, AI ethics review, is this AI feature ethical, explainability audit, AI bias check, AI consent review, does this disclose AI use, AI fairness audit, human oversight review, AI accountability, labeling AI content, EU AI Act compliance, or any request to evaluate whether an AI-powered product is honest, fair, safe, and compliant. Always use this skill — do not attempt an AI transparency audit without it.
---

# AI Transparency Auditor

Evaluate AI-powered features and products against a framework of transparency, fairness, consent, and human control. AI amplifies everything — including harm. A bias in a recommendation system at scale is not a bug. It is a policy. This skill surfaces the gaps before they ship.

Judgment — not prompting — is the critical skill in the AI era. This audit applies that judgment to AI product decisions and hardening them against emerging regulation.

---

## The 6 Dimensions of AI Transparency

| # | Dimension | Core Test | Regulatory Angle |
|---|-----------|-----------|------------------|
| 1 | Disclosure | Do users know when they are interacting with AI-generated or AI-influenced content, decisions, or responses? | EU AI Act: High-risk systems must disclose AI use |
| 2 | Explainability | Can the system explain its outputs in terms users can understand and act on? | EU AI Act: High-risk systems must provide explanations |
| 3 | Consent & Data Use | Have users meaningfully consented to their data being used for AI training, personalization, or inference? | GDPR Article 13: Consent must be specific and informed |
| 4 | Bias & Fairness | Does the AI system perform equitably across demographic groups? Who was underrepresented in training? | EU AI Act: Prohibited systems and high-risk systems must audit for bias |
| 5 | Human Oversight | Are there meaningful human override paths for high-stakes AI decisions? Can users contest outputs? | EU AI Act: High-risk systems require human review |
| 6 | Failure Transparency | Does the system communicate clearly when it is uncertain, wrong, or operating outside its competence? | Trust & accountability |

---

## EU AI Act Risk Classification

The EU AI Act (2024) classifies AI systems into risk tiers. This framework helps map your audit findings to regulatory exposure.

**Prohibited (Cannot Deploy):**
- Social credit scoring without exceptional transparency
- Subliminal manipulation
- Exploiting vulnerabilities to significantly harm autonomy, dignity, safety
- Real-time biometric identification in public spaces (with limited exceptions)

**High-Risk (Requires Technical File, Documentation, Testing):**
- Credit/employment/housing decisions
- Educational/vocational placement
- Law enforcement/border control
- Hiring/promotion/termination
- Content moderation in critical contexts
- Biometric identification (enrollment, categorization)

**Limited Risk (Transparency Required):**
- Generative AI (ChatGPT-like systems)
- AI that creates deepfakes
- Systems that make recommendations

**Minimal Risk (General AI Use):**
- Most other applications

Map your findings to risk tier during audit.

---

## Scoring

Score each dimension 0–10. Weighted as shown.

| Dimension | Weight |
|-----------|--------|
| Disclosure | 20% |
| Explainability | 15% |
| Consent & Data Use | 20% |
| Bias & Fairness | 20% |
| Human Oversight | 15% |
| Failure Transparency | 10% |

Overall Score = sum of (score × weight) × 10

| Score | Grade | Meaning |
|-------|-------|---------|
| 85–100 | A | Accountable AI — honest, fair, user-controlled |
| 70–84 | B | Responsible foundation with gaps to close |
| 55–69 | C | Technically functional but ethically underbuilt |
| 40–54 | D | Significant trust and accountability failures |
| 0–39 | F | Deploying AI in ways that will cause harm |

---

## Audit Process

### Step 1 — Map the AI Surface

Before scoring, identify:
- Every place AI is used in the product (generation, classification, ranking, recommendation, personalization, moderation, synthesis)
- What data trains or informs each AI component
- What decisions the AI makes, and what the stakes of those decisions are
- Whether users know AI is involved at each touchpoint
- What happens when the AI is wrong
- Classify the system under EU AI Act framework (Prohibited / High-Risk / Limited-Risk / Minimal-Risk)

### Step 2 — Score Each Dimension

For each dimension, assign 0–10, list findings with severity, and write specific action items.

**Severity Tags:**
- CRITICAL — Active harm risk, regulatory exposure (EU AI Act, GDPR, emerging US regulation), or fundamental breach of user trust
- MAJOR — Meaningfully undermines fairness, honesty, or user agency
- MINOR — Improvement opportunity that would strengthen trust and accountability

### Step 3 — Bias Testing Methodology

For any system making decisions or personalizing content across demographic groups:

**1. Data Representation Audit**
- What percent of training data is each demographic group?
- Are any groups < 5% represented? (Likely to have degraded performance)
- Document: training data composition, data sources, sampling methods

**2. Performance Parity Testing**
- Run inference on test sets for each demographic group
- Calculate: accuracy, precision, recall, F1 score per group
- Flag: any group with >5% performance difference from average
- Document: baseline group assumption (usually defaults to majority group)

**3. Fairness Metric Definition**
- Choose fairness metric appropriate to use case:
  - Demographic parity: Equal acceptance rates across groups
  - Equal opportunity: Equal true positive rates across groups
  - Equalized odds: Equal true positive AND false positive rates
  - Calibration: Same confidence level = same outcome probability across groups
- Audit which metric was chosen and why

**4. Bias Mitigation & Monitoring**
- What techniques are used to reduce bias? (Rebalancing, fairness constraints, post-processing?)
- Is bias monitored post-launch?
- Is there a process to detect and respond to emerging bias?

### Step 4 — Consent Patterns Audit

For products that use AI on personal data:

**Good Pattern:**
- Specific, plain-language consent at point of data collection ("We'll use your search history to personalize recommendations")
- Granular opt-out options (can opt out of training data use without losing recommendations)
- One-click revocation (easy to withdraw consent)
- Clear explanation of what "training data use" means

**Bad Pattern:**
- Consent bundled in Terms of Service
- Vague language ("we use AI to improve your experience")
- Opt-out requires contacting support
- Opting out removes core functionality

### Step 5 — Model Card / AI Factsheet Template

For high-risk systems, create a model card documenting:

```
# Model Card: [System Name]

## Model Details
- Model architecture: [describe]
- Training data size: [N examples]
- Training data sources: [list]
- Model version / date: [date]
- Known limitations: [list]

## Intended Use
- Primary use case: [describe]
- Intended users: [describe]
- Out-of-scope uses: [list what it should NOT be used for]

## Factors Affecting Performance
- Input factors: [describe]
- Environmental factors: [describe]
- Demographic factors: [describe]

## Performance & Fairness
- Overall accuracy: [metric]
- Accuracy by demographic group:
  - [Group A]: [accuracy]
  - [Group B]: [accuracy]
  - [Group C]: [accuracy]
- Fairness metric used: [metric and definition]
- Known performance gaps: [describe]

## Ethical Considerations
- Known harms: [list]
- Bias/fairness risks: [list]
- Stakeholder impacts: [analyze for each group affected]

## Caveats & Recommendations
- This model performs poorly on: [list]
- This model should NOT be used for: [list]
- Recommended monitoring: [what should be tracked post-launch?]
```

### Step 6 — Render the Report

Use the output format below.

---

## Output Format

```
# AI Transparency Audit Report

**Product / Feature:** [name]
**AI Components Identified:** [list of AI touchpoints]
**Highest-Stakes AI Decision:** [what AI decision has the most impact on users/fairness/safety?]
**EU AI Act Risk Classification:** [Prohibited / High-Risk / Limited-Risk / Minimal-Risk]
**Audit Date:** [date]

---

## Overall AI Transparency Score: [X/100] — [Grade]

[1–2 sentence summary]

---

## Dimension Scores

| Dimension | Score | Weight | Weighted |
|-----------|-------|--------|---------|
| Disclosure | X/10 | 20% | X.X |
| Explainability | X/10 | 15% | X.X |
| Consent & Data Use | X/10 | 20% | X.X |
| Bias & Fairness | X/10 | 20% | X.X |
| Human Oversight | X/10 | 15% | X.X |
| Failure Transparency | X/10 | 10% | X.X |
| **Total** | | | **X.X / 10** |

---

## Regulatory Exposure Assessment

**EU AI Act Risk Tier:** [Prohibited / High-Risk / Limited-Risk / Minimal-Risk]

**High-Risk Findings:** [If applicable, list any findings that trigger EU AI Act high-risk requirements]

**Required Actions for Compliance:**
- [ ] Create technical file documenting system design, training data, testing
- [ ] Conduct bias impact assessment
- [ ] Document human oversight process
- [ ] Create post-market monitoring plan
- [ ] Prepare transparency documentation

---

## AI Risk Flags Detected

[If none: "No AI-specific risk flags detected."]
[If present: name each with severity and action item]

---

## Bias & Fairness Assessment

[If system makes decisions or personalizes across demographic groups:]

### Training Data Representation
- Total training samples: [N]
- Data by demographic group: [breakdown]
- Representation gaps: [note]

### Performance Parity Testing
| Group | Accuracy | Precision | Recall | Notes |
|-------|----------|-----------|--------|-------|
| [Group A] | [X]% | [X]% | [X]% | |
| [Group B] | [X]% | [X]% | [X]% | |
| Overall | [X]% | [X]% | [X]% | |

### Fairness Gaps
[Note any group with >5% performance difference]

### Mitigation Techniques
[What is done to reduce bias?]

---

## Findings & Action Items

### [Dimension] — [X/10]

**[CRITICAL/MAJOR/MINOR]** [Finding]
> Action: [Specific fix]

---

## Model Card / AI Factsheet

[Attach completed model card using template above]

---

## Top 5 Priority Fixes

1. [Most critical fix]
2.
3.
4.
5.

---

## The Accountability Question

[One paragraph answering: If this AI system causes harm, who is accountable and what is the path to redress? This question surfaces whether accountability has been designed in or assumed away.]

---

## Recommended Monitoring Post-Launch

[For high-risk systems:]
- Performance metrics to track: [list]
- Bias monitoring cadence: [monthly / quarterly / annually]
- Alert thresholds: [when to escalate?]
- Escalation process: [human review / system pause / user notification?]
```

---

## Dimension Reference Guide

### 1. Disclosure

Users have a right to know when AI is shaping what they see, hear, or receive. This is not about labeling every spell-check suggestion. It is about meaningful touchpoints where AI materially affects the user's experience or outcomes.

**Audit questions:**
- Is AI-generated content clearly labeled at the point of consumption?
- Do users know when a recommendation, ranking, or decision is AI-driven?
- Is the disclosure specific ("this summary was generated by AI") or vague ("we use AI to improve your experience")?
- Does disclosure happen at the moment it's relevant, not just in a privacy policy?
- For generated text/images: is there a clear "AI-generated" label visible to end users?
- For recommendations: can users see why they're being recommended something?

### 2. Explainability

Users should be able to understand why AI made a decision that affected them, in terms they can act on. "Our algorithm decided" is not an explanation.

**Audit questions:**
- Can the system explain its outputs at the user level ("you were recommended this because...")?
- For high-stakes decisions, can users receive a human-readable rationale?
- Are explanations useful for contesting or improving outcomes, or just performative?
- Is explainability available to the user, or only to developers?
- Are explanations specific enough to understand what changed the outcome?

### 3. Consent & Data Use

AI consent must be specific, informed, and separate from general ToS agreement. "By using this product you agree to our AI training" buried in 40 pages of legal text is not consent.

**Audit questions:**
- Is there a specific, plain-language consent moment for AI data use?
- Can users opt out of AI personalization without losing core functionality?
- Can users opt out of their data being used for model training?
- If user data trains the model, is that disclosed at the point of data collection?
- Is consent revocable, and is the revocation path as easy as consent?
- Is it clear what "training data use" means in plain English?

### 4. Bias & Fairness

AI systems reflect the data they were trained on and the objectives they were optimized for. When training data underrepresents certain groups, or when optimization objectives proxy for demographic characteristics, the result is a system that treats people unequally.

**Audit questions:**
- Has the model been tested for performance differences across demographic groups?
- Was the training dataset audited for representation gaps?
- Does the system's optimization objective (engagement, clicks, conversions) correlate with demographic characteristics in ways that produce disparate outcomes?
- Is there ongoing monitoring for bias drift post-launch?
- For AI that generates images or text: does it reproduce harmful stereotypes or exhibit demographic skew?
- What is the ground truth baseline? (Usually assumes majority group performance = fairness baseline)

### 5. Human Oversight

The higher the stakes of an AI decision, the more important it is that a human can review, override, and correct it. This is not a temporary limitation — it is a permanent design principle.

**Audit questions:**
- For high-stakes AI decisions (content moderation, financial, medical, hiring-adjacent): is there a human review path?
- Can users flag or contest AI outputs?
- Is there a documented escalation path when AI behavior causes harm?
- Are there hard-coded human checkpoints for irreversible AI actions?
- Is the human review path real or performative (i.e., does it actually change outcomes)?
- What is the human reviewer's training and authority?

### 6. Failure Transparency

AI systems fail in ways that are often invisible to users. Confident-sounding wrong answers. Silent personalization failures. Model drift that degrades performance over time. Honest AI communicates uncertainty and failure.

**Audit questions:**
- Does the system communicate uncertainty when confidence is low?
- Are there graceful degradation paths when AI fails or is unavailable?
- Is there a mechanism to detect and communicate model performance degradation post-launch?
- Does the system avoid presenting hallucinated or low-confidence outputs as authoritative?
- When the AI doesn't know something, does it say so clearly?

---

## Reference Framework

Grounded in Matthew Stephens' ethical AI practice, which holds that:

- Judgment — not prompting — is the critical skill in the AI era
- AI without consent becomes manipulation
- A bias at scale is not a bug — it is a policy, and it needs to be treated as one
- Transparency is not a disclaimer — it is a design feature
- Human oversight is a permanent design principle, not a temporary limitation while AI matures
- The EU AI Act (2024) and emerging US AI regulation are hardening these principles into legal obligations — building to them now is cheaper than retrofitting later
- Model cards and explainability are not optional documentation — they are table stakes for responsible AI deployment

---

## Cross-References

Related skills: privacy-first-auditor, dei-auditor
