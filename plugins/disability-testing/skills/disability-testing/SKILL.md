---
name: disability-testing
description: "Test digital products through disability-specific profiles — including simulation techniques, AT testing patterns, and per-disability findings templates. Use this skill for disability-specific UX testing, simulation guidance, or when recruiting disabled testers for usability studies. Trigger on phrases like disability testing, test with screen reader users, simulate low vision, motor impairment testing, deaf user testing, cognitive disability testing, or any request to evaluate a product through specific disability experiences."
category: audit
related-skills: full-accessibility-audit, a11y-test-plan, screen-reader-scripting, cognitive-accessibility
---

# Disability Testing Skill

## Overview
Disability testing is the practice of evaluating digital products and services through the lived experiences of disabled users. This skill focuses on systematic approaches to testing with disabled testers, simulation techniques, and generating actionable accessibility findings.

## Core Testing Principles

**Real Users vs. Simulations**
- Real disabled users provide authentic feedback that simulations cannot replicate
- Automated tools catch technical issues; user testing uncovers usability barriers
- Simulations are valuable for building empathy and understanding impact, but should not replace real user testing
- Simulation tools are best used in iterative design and training contexts

**Testing Priority Order**
Conduct testing in this evidence-based sequence:
1. **Automated Scanning (Lowest Cost)**: Run accessibility tools to catch technical violations
2. **Simulation Testing (Team Building)**: Screen reader simulation, low vision simulation, motor control challenges with team
3. **Usability Testing with Disabled Users (Highest Value)**: Recruit real users with relevant disabilities
4. **Post-Launch Monitoring (Ongoing)**: Gather user feedback after release

## Simulation Tools & Techniques

### Screen Reader Simulation
**NVDA (Free, Windows/Linux)**
- Install: https://www.nvaccess.org/download/
- Practice: Browse your product with screen reader only (no mouse)
- Key shortcuts: Tab navigation, NVDA key+F7 for elements list, NVDA key+H for help
- Test: Form labels, heading structure, link text, ARIA landmarks
- Limitation: Simulates basic screen reader behavior; real users have years of experience with shortcuts and efficiency tricks

**JAWS (Paid, Windows)**
- Industry standard screen reader; used by 70% of blind professionals
- Install 40-minute trial mode at https://www.freedomscientific.com/products/software/jaws/
- Advanced features: Virtual cursor, forms mode, reading text
- Test: Complex interactive components, dynamic content updates

**VoiceOver (Free, macOS/iOS)**
- Built-in to Apple devices
- Activate: Cmd+F5 on Mac
- Key shortcuts: VO key (Ctrl+Option), VO+U for rotor (headings, links, etc.)
- Test: Mobile responsiveness, touch gestures, VoiceOver-specific ARIA attributes

**TalkBack (Free, Android)**
- Built-in to Android devices
- Activate: Volume keys + Accessibility button, or Settings > Accessibility > TalkBack
- Key gestures: Swipe right (next), swipe left (previous), double-tap (activate)
- Test: Mobile form inputs, keyboard navigation, touch alternatives

### Low Vision & Color Blindness Simulation
**Axe DevTools Color Contrast Analyzer**
- Install: https://www.deque.com/axe/devtools/
- Features: Real-time WCAG AA/AAA checking, simulation mode
- Test: Text/background contrast, color-dependent information
- Note: Does not simulate actual visual acuity loss; use browser zoom for that

**Stark (Figma Plugin)**
- Simulate: Protanopia, deuteranopia, tritanopia, achromatopsia
- Test: Design mockups before development
- Use case: Ensure information isn't conveyed by color alone

**Visual Acuity Simulation**
- Browser zoom: Zoom to 200% and test readability
- Windows Magnifier: Windows+Plus to test magnified browsing
- macOS Zoom: System Preferences > Accessibility > Zoom
- Test: Readability, layout at 200-400% zoom, pinch-to-zoom on mobile

### Motor Control & Dexterity Simulation
**Mouse-Free Navigation**
- Disable mouse: Unplug mouse or System Preferences > Accessibility > Mouse & Trackpad
- Practice: Use Tab, Enter, Space, Arrow keys exclusively
- Test: All interactive elements reachable via keyboard, no mouse-hover-only features
- Limitation: Does not simulate tremor, limited reach, or slow response times

**Switch Control Simulation**
- Windows Switch Control: Settings > Accessibility > Switch Control
- iOS Switch Control: Settings > Accessibility > Switch Control
- Single key: Assign one keyboard key as "switch"
- Test: Can users navigate and activate all functions with single-key input?

**Voice Control Testing (macOS/Windows/iOS)**
- macOS: System Preferences > Accessibility > Voice Control
- iOS: Settings > Accessibility > Voice Control
- Test: Voice command structure, visual labels (must be readable for voice users)
- Limitation: Does not test speech recognition accuracy issues or background noise challenges

## Intersectionality in Accessibility Testing

Testing must account for overlapping and intersecting disabilities:

**Common Intersections**
- Deaf-blind users: Require both Braille and captions, tactile sign language
- Deaf users with cognitive disabilities: Complex captions may not suffice; need plain language video content
- Blind users with arthritis: Screen reader + voice control may work better than keyboard-only
- Aging users: Often have multiple disabilities (vision, hearing, motor, cognitive)

**Testing Implications**
- Don't assume single-disability profiles represent real experience
- Test combinations: screen reader + keyboard, screen reader + voice control, magnification + captions
- Ask testers about their actual assistive technology stack, not just primary disability
- Account for adaptive strategies: Some users may use non-standard workflows

**Cognitive Accessibility in Testing**
- Test with neurodivergent users (ADHD, autism, dyslexia)
- Assess: Can users understand instructions? Is content scannable? Are distractions minimized?
- Red flags: Dense text, jargon, flashing animations, unclear error messages, overwhelming form fields

## Recruiting Disabled Testers

### Where to Find Testers
**Disability Communities & Organizations**
- National Federation of the Blind (NFB): https://nfb.org/
- American Foundation for the Blind (AFB): https://www.afb.org/
- Deaf organizations: NAD (https://www.nad.org/), RID (https://www.rid.org/)
- Disability advisory groups: Many tech companies have internal groups
- Accessibility consultancies: Often have tester networks

**Online Communities**
- Reddit: r/blind, r/Deaf, r/disability, r/autistic, r/ADHD
- Discord communities: Disability gaming, accessibility-focused servers
- LinkedIn: Search "accessibility consultant," "blind accessibility," etc.
- Twitter/X: Follow disability advocates, accessibility professionals

**Specialized Platforms**
- UserTesting.com: Disability filters available (requires budget)
- PlaytestCloud, TryMyUI: Some have accessibility-focused testers
- Direct outreach: Offer payment ($50-150/hour for professional testers)

### Compensation & Ethics
**Standard Rates**
- Professional disabled testers: $75-150/hour (NOT free)
- User research participants: $50-100 for 1-hour session
- Budget: Factor compensation into accessibility testing, not as "nice to have"

**Ethical Recruiting**
- Never assume someone wants to test because they have a disability
- Clear informed consent: Explain testing scope, duration, accessibility of testing itself
- Accessibility of the testing process:
  - Offer multiple modalities: Zoom, phone call, in-person, async feedback
  - Provide instructions in accessible formats (plain text, audio, large print, captions)
  - Allow breaks for chronic pain/fatigue
  - Record sessions only with explicit permission
  - Budget extra time if tester uses assistive technology

**Inclusive Screening Questions**
Instead of: "Do you use a screen reader?"
Ask: "What assistive technology or adaptive strategies help you use digital products?"

Instead of: "How severe is your disability?"
Ask: "What are the main barriers you encounter when using digital products like ours?"

This reveals actual usage patterns, not disability categories.

## Testing Priority Matrix

Use this matrix to prioritize which disabilities to test first based on your user base and product type:

| Product Type | Priority 1 | Priority 2 | Priority 3 |
|---|---|---|---|
| **Content Site** | Blind (screen reader) | Low vision | Dyslexia |
| **E-commerce** | Blind (screen reader) | Motor control | Low vision |
| **Video Platform** | Deaf (captions) | Hard of hearing | Blind (AD) |
| **Mobile App** | Motor control (one-handed) | Blind (VoiceOver) | Deaf (captions) |
| **SaaS Dashboard** | Low vision (zoom) | Blind (screen reader) | Motor (keyboard) |
| **Social Media** | Deaf (captions) | Blind (image alt text) | Neurodivergent (clarity) |

## Testing Methodology

### Pre-Testing Setup
1. **Define Tasks**: What should testers accomplish? (e.g., "Complete checkout," "Find privacy policy")
2. **Accessibility of Testing**: Provide tasks in accessible format, allow assistive technology, schedule breaks
3. **Assistive Technology Agreement**: Ask what tools testers use; ensure testing environment matches real usage
4. **Informed Consent**: Explain how findings will be used, privacy of feedback, compensation method

### During Testing
**Facilitator Role**
- Observe without intervening; let testers work through problems
- Ask: "Can you tell me what you're trying to do?" (not "Are you stuck?")
- Note barriers, workarounds, frustration points
- Do NOT explain how to use your product

**What to Document**
- Time to complete task (baseline for non-disabled testers for comparison)
- Barriers encountered: "Screen reader doesn't announce button state"
- Workarounds: "User tabbed past form field twice to find it"
- Emotional response: Frustration, confusion, confidence

### Post-Testing Debrief
- "What was most frustrating?"
- "What would make this easier?"
- "Have you encountered this barrier on other sites?"
- Ask about their typical workflows/assistive technology

## Per-Profile Testing Output Template

Use this template to structure findings from each disability profile tested:

```
## [DISABILITY PROFILE] Testing Results
**Testers**: [Name(s), primary assistive technology]
**Date**: [Date]
**Duration**: [Time spent in testing]
**Product Area Tested**: [Section/feature]

### Tasks Attempted
1. [Task]: [Result - Success/Partial/Failed]
   - Time to complete: [X minutes]
   - Barriers: [Specific issue]
   - Workaround used: [If any]
   - Severity: [Blocker/Major/Minor]

2. [Task]: [Result]
   - [Details as above]

### Key Findings
**Blockers** (Prevent task completion)
- [Issue 1]: [Impact]
- [Issue 2]: [Impact]

**Major Issues** (Significant friction)
- [Issue 1]: [Workaround needed]
- [Issue 2]: [Workaround needed]

**Minor Issues** (Nuisance, doesn't block)
- [Issue 1]: [Why it's a nuisance]
- [Issue 2]: [Why it's a nuisance]

### Assistive Technology Notes
**What Worked Well**
- [AT feature] + [Product feature] = [Positive outcome]
- Example: "VoiceOver rotor for headings allowed quick navigation"

**What Didn't Work**
- [AT feature] + [Missing product feature] = [Barrier]
- Example: "No ARIA labels; screen reader announced 'Button' without context"

### Disability-Specific Context
- Tester's typical usage patterns
- Comparison to other products they use
- Fatigue, pain, or other factors that affected testing
- Intersecting disabilities that affected experience

### Recommendations
| Finding | Recommendation | WCAG Reference | Priority |
|---|---|---|---|
| [Issue] | [Fix] | [2.1.1 Keyboard] | [P1/P2/P3] |

### Next Steps
- [ ] Share findings with engineering
- [ ] Schedule follow-up testing after fixes
- [ ] [Product-specific action]
```

## Simulation Limits: When NOT to Use Simulation

**Simulation Should NOT Replace User Testing When**
- Testing complex workflows (users develop efficient strategies)
- Testing error recovery (non-users don't know expected behaviors)
- Testing mental models (non-users have different conceptual understanding)
- Testing long-form content (fatigue, learning curves affect readability)
- Testing assistive technology edge cases (speech recognition noise, voice commands in loud spaces)

**What You LOSE in Simulation**
- Speed and efficiency: Users with years of experience navigate much faster
- Compensatory strategies: Users develop creative workarounds
- Frustration thresholds: Simulated users may tolerate barriers real users won't
- Cultural context: Disability culture knowledge shapes interpretation
- Intersectionality: Users often combine multiple AT tools

## Screen Reader Testing Best Practices

### Testing Checklist
- [ ] Headings form logical outline (h1, h2, h3 hierarchy)
- [ ] Landmark regions properly labeled (main, nav, sidebar, etc.)
- [ ] Links have descriptive text ("Learn more" vs "Click here")
- [ ] Form labels associated with inputs (<label for="id"> or aria-label)
- [ ] Form errors announced with field context
- [ ] Images have meaningful alt text (or alt="" if decorative)
- [ ] Dynamic content changes announced (aria-live, aria-relevant)
- [ ] Modal dialogs trap focus and announce purpose
- [ ] Skip links present and functional
- [ ] No keyboard traps (users can always Tab out)
- [ ] Tables have proper header markup (scope="col"/"row")
- [ ] Buttons vs links: Buttons for actions, links for navigation
- [ ] Status messages announced (success, error, loading)
- [ ] Autocomplete suggestions keyboard accessible

### Common Screen Reader Issues
**Issue**: "Button button button" repeated announcement
**Cause**: Unlabeled buttons with no aria-label
**Fix**: Add aria-label="Clear search" or descriptive button text

**Issue**: Screen reader announces all form fields at top, user can't associate labels
**Cause**: Labels not properly associated with inputs
**Fix**: `<label for="email">Email</label><input id="email">`

**Issue**: User can't find specific section after page updates
**Cause**: No aria-live announcement of dynamic content
**Fix**: Add `<div aria-live="polite" aria-atomic="true">Results updated</div>`

## Advanced Testing: Custom Simulation Scenarios

### Scenario 1: "Tremor + Motor Fatigue"
- Set all interactive elements to require double-click within 500ms
- User must succeed with increasingly difficult targets
- Measures: Can large buttons be reliably activated?

### Scenario 2: "Cognitive Load + Dyslexia"
- Add visual noise (background patterns, multiple fonts)
- Measure: Can users still extract key information?
- Test: Readability, information hierarchy, scanability

### Scenario 3: "Aging (Vision + Hearing + Motor)"
- Combine: Low vision (zoom 200%), silent video (captions required), mouse disabled (keyboard only)
- Realistic intersection for aging users
- Tests full stack of WCAG requirements

## Cross-References
- Related skill: **full-accessibility-audit** - comprehensive audit methodology
- Related skill: **a11y-test-plan** - creating detailed test plans
- Related skill: **screen-reader-scripting** - advanced ARIA and semantic HTML
- Related skill: **cognitive-accessibility** - testing with neurodivergent users
- Related skill: **accessibility-copy** - testing content clarity with diverse users

## Tools & Resources

**Simulation Tools Summary**
| Tool | Best For | Cost | Platform |
|---|---|---|---|
| NVDA | Screen reader simulation | Free | Windows/Linux |
| JAWS | Professional screen reader testing | $90/month | Windows |
| VoiceOver | iOS/macOS testing | Free | macOS/iOS |
| TalkBack | Android testing | Free | Android |
| Stark | Color blindness simulation | Free-$80/month | Figma |
| Axe DevTools | Contrast + color simulation | Free | Chrome/Edge |
| Switch Control | Single-switch input | Free | Windows/macOS/iOS |

**Recruitment Resources**
- NFB Tech Group: https://nfb.org/
- Disability visibility: https://disabilityvisibilityproject.com/
- Accessibility consultancies: AudioEye, Deque, Level Access (have tester networks)

## Summary
Disability testing effectiveness increases when you:
1. Use simulations for team empathy and quick iteration
2. Recruit real disabled users systematically (with compensation)
3. Test intersecting disability combinations, not isolated profiles
4. Document findings with severity and WCAG references
5. Follow ethical recruitment practices
6. Account for years of assistive technology expertise non-users don't have

The most valuable accessibility insights come from listening to disabled users' lived experiences, not assumptions from simulation.
