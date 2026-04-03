# Accessibility Skills Suite

33 production-grade accessibility skills organized by workflow stage.

## Folder Structure

```
strategy/     → Scoping, business case, maturity assessment, consequence mapping
audit/        → Core accessibility audit skills (design, code, content, standards, design system health)
audience/     → Audience-specific lenses (older adults, children, DEI)
ethics/       → Responsible product design (AI transparency, privacy, speculative harm, gamification)
test/         → Testing artifacts and QA planning
handoff/      → Design-to-dev documentation and implementation packaging
```

## Skills by Category

### strategy/ (3 skills)
| Skill | Purpose |
|-------|---------|
| accessibility-advisor | Business case, maturity assessment, stakeholder communication, remediation roadmaps |
| futures-wheel | First-, second-, and third-order consequence mapping for product and feature decisions |
| wcag-checklist | Scoped WCAG 2.2 checklists by product type with effort/severity ratings |

### audit/ (18 skills)
| Skill | Purpose |
|-------|---------|
| full-accessibility-audit | **Orchestrator** — coordinates all audit skills into unified report |
| accessibility-audit | Design layer — visual, layout, interactive, content review |
| accessibility-code | Code layer — semantic HTML, ARIA, keyboard, React/Vue/Svelte |
| accessibility-copy | Microcopy, ARIA labels, error messages, plain language |
| accessible-forms | Labels, validation, error handling, multi-step, date pickers |
| accessible-tables | Simple/complex tables, responsive strategies, data grids |
| alt-text-generator | Context-aware alt text, classification, long descriptions |
| cognitive-accessibility | Cognitive load, plain language, consistency, COGA guidance |
| contrast-checker | Color contrast ratios (WCAG 2.x + APCA), palette audits |
| design-review-cowork | Multi-perspective prototype review with readiness score, Ship/No Ship guidance, and actionable fixes |
| design-system-drift | Detects design-token, component, and accessibility drift from the design system across a codebase |
| disability-testing | 11 disability profiles, simulation tools, tester recruitment |
| keyboard-focus-auditor | Tab order, focus indicators, focus traps, skip links |
| mobile-touch-auditor | Touch targets, gestures, VoiceOver/TalkBack, responsive |
| motion-auditor | Animation harm (seizure, vestibular, cognitive), prefers-reduced-motion |
| pdf-document-accessibility | PDF/UA, tagged PDF, remediation workflows |
| video-media-accessibility | Captions, transcripts, audio description, media players |
| wcag-compliance-auditor | Criterion-by-criterion WCAG 2.2 compliance audit |

### audience/ (3 skills)
| Skill | Purpose |
|-------|---------|
| older-audiences-auditor | Vision, cognition, motor, hearing, trust for 50+ users (3 age bands) |
| kids-ux-auditor | Age-appropriateness, safety, COPPA, caregiver integration |
| dei-auditor | Representation, language, user model assumptions, systemic exclusion |

### ethics/ (4 skills)
| Skill | Purpose |
|-------|---------|
| ai-transparency-auditor | Disclosure, explainability, consent, bias, human oversight |
| black-mirror-auditor | Worst-case future and unintended-harm exercise with mitigation and regulatory cross-references |
| gamification-auditor | Evaluates engagement mechanics for manipulation, addiction patterns, and dark-pattern risk |
| privacy-first-auditor | Data minimization, consent, GDPR/CCPA, cookie audit, SDK audit |

### test/ (3 skills)
| Skill | Purpose |
|-------|---------|
| a11y-test-plan | QA test plans, AT+browser matrix, CI/CD integration, effort estimates |
| screen-reader-scripting | NVDA/JAWS/VoiceOver/TalkBack test scripts with expected announcements |
| playwright-accessibility-auditor | Browser-level testing — axe-core scans, multi-viewport screenshots, keyboard smoke tests, zoom/reflow, dark mode |

### handoff/ (2 skills)
| Skill | Purpose |
|-------|---------|
| accessibility-annotations | Focus order, ARIA roles, landmark regions, keyboard behavior specs |
| design-handoff | Generates polished design handoff documentation after audit-and-fix passes on the prototype |

## Recommended Workflow

1. **Strategy** → Run accessibility-advisor to assess maturity and build the business case. Use wcag-checklist to scope what applies, and futures-wheel to think through downstream impact before launch.
2. **Audit** → Run full-accessibility-audit to orchestrate a comprehensive review, or use targeted skills like design-review-cowork and design-system-drift for prototype and system-level assessment.
3. **Audience** → Layer on audience-specific lenses based on your user base.
4. **Ethics** → Apply ai-transparency-auditor, privacy-first-auditor, black-mirror-auditor, and gamification-auditor for AI-powered, data-intensive, or engagement-heavy products.
5. **Test** → Generate test plans and screen reader scripts for QA teams.
6. **Handoff** → Produce accessibility annotations and full design handoff documentation for design-to-dev delivery.

## Conventions

All skills use consistent severity tags: **CRITICAL** (active harm/legal exposure), **MAJOR** (meaningfully undermines accessibility), **MINOR** (improvement opportunity). Scoring skills use 0-10 per dimension with weighted A-F grades.
