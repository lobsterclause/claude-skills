---
name: privacy-first-auditor
description: Audit prototypes, products, features, or design patterns against the 8 Principles of Privacy-First Design to surface trust failures, data overreach, and consent dark patterns — and produce a scored report with specific fixes. Use this skill whenever someone wants to evaluate a product for privacy compliance, data ethics, consent UX, or trust-building design. Trigger on phrases like "privacy audit", "privacy review", "data ethics", "GDPR check", "consent patterns", "is this privacy-first", "privacy by design", "trust audit", "data collection review", "privacy score", "are we collecting too much", "does this respect user privacy", or any request to evaluate how a product handles personal data. Always use this skill — do not attempt a privacy design audit without it.
---

# Privacy-First Design Auditor

Evaluate products and prototypes against the 8 Principles of Privacy-First Design. Produces a scored audit with specific, implementable fixes for each violation. Privacy is not a compliance checkbox — it is a trust contract with your users.

---

## The 8 Principles

These principles form the audit framework. Each maps to a scored dimension.

| # | Principle | Core Test |
|---|-----------|-----------|
| 1 | Data Minimization | Are you collecting only what is absolutely necessary? |
| 2 | Transparent Communication | Do users understand — in plain language — what's happening to their data? |
| 3 | User Control & Consent | Can users meaningfully opt in, opt out, and delete their data? |
| 4 | Security by Design | Is sensitive data protected architecturally, not bolted on? |
| 5 | Contextual Integrity | Is data being used in the context users expect, not repurposed? |
| 6 | Respect for Vulnerable Users | Are high-risk groups (children, people in crisis, marginalized communities) protected with extra care? |
| 7 | Privacy as a Value Proposition | Does the product treat privacy as a competitive asset, not a legal obligation? |
| 8 | Lean Data Lifecycle | Is there a clear, enforced policy for data retention, deletion, and expiration? |

---

## Audit Dimensions & Scoring

Score each principle 0–10. Weight as shown.

| Principle | Weight |
|-----------|--------|
| Data Minimization | 15% |
| Transparent Communication | 15% |
| User Control & Consent | 15% |
| Security by Design | 15% |
| Contextual Integrity | 15% |
| Respect for Vulnerable Users | 10% |
| Privacy as a Value Proposition | 10% |
| Lean Data Lifecycle | 5% |

Overall Score = sum of (score × weight) × 10

---

## Score Interpretation

| Score | Grade | Meaning |
|-------|-------|---------|
| 85–100 | A | Privacy-first — earns trust by design |
| 70–84 | B | Solid foundation with gaps to close |
| 55–69 | C | Compliance-minded but not user-centered |
| 40–54 | D | Significant trust liabilities present |
| 0–39 | F | Actively eroding user trust — stop and redesign |

---

## Regulatory Quick Reference

Use this section to assess compliance posture during the audit. Privacy regulations are hardening globally — building to them now is cheaper than retrofitting later.

### GDPR (EU, UK, EEA)
- **Applies when:** Processing personal data of EU residents
- **Key requirements:**
  - Lawful basis required for all processing (consent, contract, legal obligation, vital interests, public task, legitimate interests)
  - Consent must be explicit, granular, and freely given (not pre-checked, not bundled)
  - Right to data portability — users can request their data in machine-readable format
  - Right to be forgotten — users can request deletion under most circumstances
  - Data Protection Impact Assessment (DPIA) required for high-risk processing
  - Data Processing Agreement (DPA) required with all third-party vendors
  - Breach notification within 72 hours to authorities, without undue delay to users
- **Red flags:** Pre-checked consent, vague lawful basis, no data portability, long retention defaults, no DPIA documentation, lack of DPA with vendors
- **Fines:** Up to 20 million EUR or 4% of annual global revenue (whichever is higher) for critical violations

### CCPA (California)
- **Applies when:** Processing personal data of California residents
- **Key requirements:**
  - Right to know — users can request what data is collected and how it's used
  - Right to delete — users can request deletion (some exceptions apply)
  - Right to opt-out of sale/sharing of personal information
  - Opt-in required (not opt-out) for children under 13
  - Opt-in required for sale/sharing of personal data for children 13–16
  - Notice requirements at collection and in privacy policy
  - Non-discrimination for exercising privacy rights
- **Red flags:** Sale/sharing default on, no privacy notice at collection, no opt-out mechanism, discrimination against users who exercise rights, vague categories ("personal information" not broken down)
- **Fines:** Up to $2,500 per violation, $7,500 per intentional violation
- **Related state laws:** Virginia (VCDPA), Colorado (CPA), Utah (UCPA), Connecticut (CTDPA), Montana (MCDPA) — broadly similar requirements, expanding rapidly

### PIPEDA (Canada)
- **Applies when:** Processing personal data of Canadian residents
- **Key requirements:**
  - Express or implied consent required before collection
  - Open and transparent about practices
  - Limited collection — collect only what you need
  - Use limitation — use data only for stated purposes without re-consent
  - Accuracy and retention — keep data accurate and only as long as needed
  - Safeguards — protect against theft, loss, unauthorized access
  - Access and correction — users can request and correct their data
  - Accountability — designate privacy officer, document practices
- **Red flags:** No privacy notice before collection, collection without consent, secondary uses without re-consent, no access/correction mechanism, retention longer than necessary
- **Enforcement:** Private right of action emerging; penalties up to $15 million or 3% of global revenue proposed in amendments

### LGPD (Brazil)
- **Applies when:** Processing personal data of Brazilian residents
- **Key requirements:**
  - Legal basis required (consent, contract, legal obligation, legitimate interests, vital interests, public interest, or special processing)
  - Consent must be explicit and easy to withdraw
  - Data subject rights: access, correction, deletion, portability, opposition to processing
  - Legitimate interest requires balancing test against user rights
  - Data Protection Impact Assessment for high-risk processing
  - Data Protection Officer (DPO) required for organizations processing large-scale data
  - Breach notification without undue delay
- **Red flags:** Processing without legal basis, bundled consent, no easy withdrawal mechanism, no DPIA for high-risk processing, no DPO designation where required
- **Enforcement:** Up to 2% of annual revenue or 50 million BRL (whichever is higher) per violation

---

## Audit Process

### Step 1 — Inventory the Data Surface

Before scoring, map out:
- Every data point the product collects (explicit and inferred)
- What each data point is used for
- Who else has access (third parties, analytics SDKs, ad networks)
- Where consent is asked for, and how
- What happens to data when a user deletes their account
- What the retention policy is (if any)

Use the **Data Flow Mapping Template** below to systematize this inventory.

### Step 2 — Score Each Principle

For each of the 8 principles:
1. Assign a score 0–10
2. List specific findings with severity tags (CRITICAL / MAJOR / MINOR)
3. Write a concrete, implementable action item for each finding

**Severity Definitions:**
- CRITICAL — Active legal or trust risk (GDPR/CCPA violation potential, data collection without consent, coercive design)
- MAJOR — Meaningfully undermines user trust or control
- MINOR — Improvement opportunity that would meaningfully increase trust

### Step 3 — Dark Pattern Check

Explicitly flag any of the following consent dark patterns if present:

- Pre-checked consent boxes
- "Accept all" prominent / "Manage settings" buried
- Consent bundled into Terms of Service acceptance
- Deceptive copy that frames privacy-protective options negatively ("degrade your experience")
- Withdrawal of consent made more difficult than granting it
- Repeated re-asking for consent that was previously denied
- Missing or broken "delete my account / data" flows
- Data collection that starts before consent is given

Each dark pattern is automatically CRITICAL severity.

### Step 4 — Third-Party SDK Audit

Scan for and document all third-party SDKs and integrations using the **Third-Party Audit Checklist** below.

### Step 5 — Cookie Consent Review

If the product uses cookies or local storage, audit using the **Cookie & Local Storage Audit Checklist** below.

---

## Principle Reference Guide

### 1. Data Minimization
Collect only what is absolutely necessary. Every data point you request increases risk — breach risk, regulatory risk, and trust risk. If a feature can work without personal information, don't ask for it.

Good test: Could we build this feature with less data? Could we use anonymized or aggregate data instead? Could we offer guest access?

Red flags: Email required for features that don't need it. Phone number collection without SMS use. Date of birth beyond age verification needs. Location data stored beyond the immediate request.

### 2. Transparent Communication
Users can't make informed decisions if they don't understand what's happening to their data. Transparency means plain language — not a 14-page privacy policy written for lawyers.

Good test: Could a 12-year-old read this and understand what they're agreeing to? Is there a plain-English summary? Are just-in-time disclosures shown at the moment data is collected?

Red flags: Privacy policy as the only disclosure. Vague language like "may share with trusted partners." No explanation of why specific data is needed.

### 3. User Control & Consent
Consent must be freely given, specific, informed, and revocable. Users should be able to withdraw consent as easily as they gave it, and have real control over their data.

Good test: Can users delete their account and all associated data? Can they export their data? Can they opt out of specific data uses without losing core functionality?

Red flags: No data deletion path. Consent bundled into ToS. No granular controls. Opting out removes access to core features unrelated to the data use.

### 4. Security by Design
Security is not a layer you add before launch. It is a design constraint from day one. Sensitive data should be encrypted, access should be role-limited, and breach plans should exist before any breach does.

Good test: Is sensitive data encrypted at rest and in transit? Is there a documented breach response plan? Are third-party dependencies audited for their own security posture?

Red flags: No HTTPS. Sensitive data in localStorage. Third-party SDKs with broad data access. No mention of encryption in technical documentation.

### 5. Contextual Integrity
Data should flow in ways that match user expectations. Sharing data in an unexpected context — even if technically permitted by the ToS — is a trust violation.

Good test: Would users be surprised to learn how their data is being used? Does the data use match the context in which it was collected?

Red flags: Behavioral data used for unrelated personalization. Health-adjacent data used for ad targeting. Data collected in one context reused in another without disclosure.

### 6. Respect for Vulnerable Users
Some users face higher risks from data exposure — children, people in mental health crisis, domestic abuse survivors, undocumented individuals, and other marginalized groups. Ethical design gives them extra protection, not just the same defaults.

Good test: Have you considered how this product could harm someone who is already vulnerable? Are there extra protections for minors? Does the product give users tools to protect themselves from others who might misuse their data?

Red flags: No age verification or age-appropriate data handling. No options to hide activity from household members. Mood or health data handled the same as behavioral data.

### 7. Privacy as a Value Proposition
Privacy-first design isn't just about compliance. It is a competitive differentiator and a brand promise. Companies that lead with privacy build deeper trust and long-term loyalty.

Good test: Does the product actively communicate its privacy stance as a feature? Does the business model require exploiting user data, or is there a path to sustainability without it?

Red flags: Privacy only mentioned in legal disclaimers. No privacy-positive copy in onboarding or marketing. Business model entirely dependent on selling behavioral data.

### 8. Lean Data Lifecycle
Data that isn't deleted is a liability. Clear retention policies, automated expiration, and verifiable deletion are the hygiene layer of privacy-first design.

Good test: Is there a documented retention policy? Does data expire automatically? When a user deletes their account, is deletion complete and permanent?

Red flags: No documented retention period. Deleted accounts still present in backups with no purge schedule. No confirmation mechanism for data deletion.

---

## Audit Tools & Methodologies

### Data Flow Mapping Template

Use this template to document all data flows in the product before scoring.

```
# Data Flow Audit — [Product Name]

## Data Inventory

| Data Point | Collection Method | Lawful Basis | Uses | Retention | Third Parties | Notes |
|------------|-------------------|--------------|------|-----------|---------------|-------|
| Email | Required at signup | Consent / Contract | Account recovery, transactional email | Until deletion | Mailgun (transactional) | Necessary |
| Browsing history | Implicit (page visits) | Legitimate interest / Consent? | Personalization | 90 days | Google Analytics | NEEDS EXPLICIT CONSENT |
| Payment method | Optional at checkout | Contract | Payment processing | Encrypted, PCI-compliant | Stripe | Only if user purchases |
| Location (IP-based) | Implicit (request metadata) | Legitimate interest | Fraud detection | Real-time only, not stored | MaxMind (GeoIP) | Check vendor DPA |

## Third-Party Access Audit

| Service | Data Shared | Purpose | DPA in Place? | User Awareness? |
|---------|-------------|---------|---------------|-----------------|
| Google Analytics | User ID, page views, events | Usage metrics | ☐ Check | ☐ Privacy policy mentions |
| Stripe | Payment info | Payments | ☐ YES (required) | ☐ YES (checkout page) |
| Mixpanel | User ID, event data | Analytics & funnels | ☐ Check | ☐ Check |

## Data Retention Schedule

| Data Type | Retention Period | Deletion Mechanism | Notes |
|-----------|------------------|-------------------|-------|
| User account data | Until deletion request | Manual deletion by user + automated purge after 30 days | Complies with GDPR right to be forgotten |
| Server logs | 30 days | Automated rotation | Necessary for security |
| Analytics data | 13 months | Automated expiration | Complies with Google Analytics consent |
| Backup copies | 90 days post-deletion | Automated backup expiration policy | CRITICAL: Must be documented |
```

### Third-Party SDK Audit Checklist

```
## Third-Party Audit Checklist — [Product Name]

For each SDK, plugin, or service integration, check:

### [SDK Name: Google Analytics]
- [ ] Is the purpose documented (what problem does this solve)?
- [ ] Is a Data Processing Agreement (DPA) in place?
- [ ] Does the vendor process data in the user's country/region of residence, or transfer it?
- [ ] What data does this SDK access? (check SDK documentation and network requests)
- [ ] Is this data use disclosed to users before collection?
- [ ] Is user consent obtained before loading this SDK?
- [ ] Can users opt out of this specific SDK without breaking core functionality?
- [ ] Are there documented retention/deletion policies for data held by this vendor?
- [ ] Has the vendor had data breaches or security incidents? (check public records)
- [ ] Is this SDK necessary, or could the functionality be built in-house or with a privacy-first alternative?

### [SDK Name: Mixpanel]
- [ ] Purpose: Product analytics and funnels
- [ ] DPA: ☐ Check status
- [ ] Data transfer: Check if data transfers out of EU
- [ ] Data access: User ID, event data, IP address (inferred location)
- [ ] User disclosure: ☐ Privacy policy mentions Mixpanel
- [ ] Consent: ☐ Consent obtained before SDK loads
- [ ] Opt-out: ☐ Users can opt out (check analytics settings)
- [ ] Retention: Check Mixpanel's retention policy (default 60 days events, 24 months profile)
- [ ] Breach history: ☐ No known breaches
- [ ] Necessity: Could use open-source alternative (Plausible, Fathom) to avoid third-party processing

### [SDK Name: Sentry (error tracking)]
- [ ] Purpose: Error logging and debugging
- [ ] DPA: ☐ Check status
- [ ] Data transfer: EU → Sentry US servers (requires privacy shield or binding agreement)
- [ ] Data access: Stack traces, user ID (if included in errors)
- [ ] User disclosure: ☐ Privacy policy mentions Sentry
- [ ] Consent: ☐ Should disclose that errors are sent to third party
- [ ] Opt-out: ☐ No opt-out available; this is development-facing
- [ ] Retention: Check Sentry's retention policy (default 90 days)
- [ ] Breach history: ☐ No known breaches
- [ ] Necessity: Consider stripping PII from error reports before sending
```

### Cookie & Local Storage Audit Checklist

```
## Cookie & Local Storage Consent Audit — [Product Name]

### Inventory All Cookies & Storage

| Name | Type | Purpose | Duration | Consent Required? | Status |
|------|------|---------|----------|-------------------|--------|
| session_id | Session cookie | User authentication | Session | NO (Necessary) | ✓ OK |
| utm_source | First-party analytics | Campaign tracking | 90 days | ☐ NEEDS CONSENT (non-essential) |
| _ga | Third-party analytics | Google Analytics | 24 months | ☐ NEEDS CONSENT |
| localStorage:theme | Local storage | Dark mode preference | Permanent | NO (Necessary) | ✓ OK |
| localStorage:fbq | Local storage | Facebook pixel | Permanent | ☐ NEEDS CONSENT |

### Consent Banner Audit

- [ ] Consent banner shown before ANY non-essential cookies are set?
- [ ] "Accept all" button same size/prominence as "Manage settings"?
- [ ] "Manage settings" option available and leads to granular controls?
- [ ] "Accept all" is NOT the default action (no pre-checked boxes)?
- [ ] Consent choices are easy to withdraw (same number of clicks as giving consent)?
- [ ] Banner includes brief explanation of each cookie category (necessary, analytics, marketing)?
- [ ] Refusal path ("Reject all") available and equally prominent?
- [ ] Cookie banner does NOT disappear after inactivity (users don't accidentally consent by scrolling)?

### Specific Dark Patterns to Flag

- [ ] "Accept all" button visually larger/bolder than "Reject all"
- [ ] "Reject all" button requires clicking through a modal or additional steps
- [ ] Consent bundled into "Continue using" or "Accept terms" without allowing granular choice
- [ ] Cookie banner re-appears frequently asking for re-consent
- [ ] Declining consent disables website functionality unrelated to declined cookies
- [ ] Vague language like "personalized experience" without explaining which cookies enable this
- [ ] No option to withdraw consent after initial choice
- [ ] "Privacy preferences" buried in footer instead of easily accessible in settings
```

---

## Output Format

```
# Privacy-First Design Audit Report

**Product / Feature:** [name or description]
**Audit Date:** [date]
**Data Surface Summary:** [brief inventory of what's collected]
**Regulatory Context:** [GDPR / CCPA / PIPEDA / LGPD / Other]

---

## Overall Privacy Score: [X/100] — [Grade]

[1–2 sentence summary of the product's privacy posture]

---

## Dimension Scores

| Principle | Score | Weight | Weighted |
|-----------|-------|--------|---------|
| Data Minimization | X/10 | 15% | X.X |
| Transparent Communication | X/10 | 15% | X.X |
| User Control & Consent | X/10 | 15% | X.X |
| Security by Design | X/10 | 15% | X.X |
| Contextual Integrity | X/10 | 15% | X.X |
| Respect for Vulnerable Users | X/10 | 10% | X.X |
| Privacy as a Value Proposition | X/10 | 10% | X.X |
| Lean Data Lifecycle | X/10 | 5% | X.X |
| **Total** | | | **X.X / 10** |

---

## Regulatory Risk Assessment

**Primary Regulations:** [GDPR / CCPA / PIPEDA / LGPD]
**Current Compliance Posture:** [Compliant / At Risk / Violations Detected]

| Regulation | Status | Key Gaps | Priority |
|-----------|--------|----------|----------|
| GDPR | ☐ Compliant / ☐ At Risk | [List gaps] | [High / Medium / Low] |
| CCPA | ☐ Not applicable / ☐ Compliant / ☐ At Risk | [List gaps if applicable] | |
| PIPEDA | ☐ Not applicable / ☐ Compliant / ☐ At Risk | [List gaps if applicable] | |

---

## Consent Dark Patterns Detected

[If none: "No consent dark patterns detected."]
[If present: list each with CRITICAL tag and action item]

---

## Third-Party Risk Assessment

| Service | Data Access | DPA Status | User Awareness | Risk Level |
|---------|-------------|-----------|-----------------|-----------|
| [SDK name] | [Data shared] | ☐ Yes / ☐ No / ☐ Check | ☐ Disclosed / ☐ NOT disclosed | ☐ Low / ☐ Medium / ☐ High |

---

## Findings & Action Items

### [Principle Name] — [X/10]

**[CRITICAL / MAJOR / MINOR]** [Finding]
> Action: [Specific, implementable fix]

---

## Top 5 Priority Fixes

1.
2.
3.
4.
5.

---

## Trust-Building Opportunities

[2–3 specific things the product could do that would actively communicate trust to users — not just avoid harm, but earn confidence]
```

---

## Cross-References

Related skills in this audit suite:
- **AI Transparency Auditor**: Use alongside this audit when AI systems process personal data. AI can amplify privacy violations at scale (e.g., using personal data for model training without explicit consent).
- **Older Audiences Auditor**: Users 50+ are often more privacy-sensitive and trusting. Apply both audits when product targets or serves older adults.
- **Kids UX Auditor**: Children and teens require heightened privacy protection under COPPA (US) and GDPR Article 8 (EU). Always use alongside this audit for products with minor users.

---

## Reference Framework

Grounded in Matthew Stephens' 8 Principles of Privacy-First Design, which holds that:

- Privacy is a trust contract, not a compliance checkbox
- Users can't make informed decisions if they don't understand what's happening to their data
- Privacy used as a value proposition aligns the entire company with an ethical promise
- Research consistently shows users value privacy more each year and are willing to pay for it
- The goal is not just to avoid harm — it is to earn trust
- Privacy regulations are hardening globally. Building to GDPR, CCPA, and emerging standards now is cheaper than retrofitting later
- Third-party vendor management is a core privacy practice, not an afterthought
- Data minimization is not a limitation — it is a strategic advantage
