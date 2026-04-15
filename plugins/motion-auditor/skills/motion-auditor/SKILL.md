---
name: motion-auditor
description: Audit animations, transitions, and motion in UI for accessibility — including prefers-reduced-motion implementation, vestibular disorder risk, seizure thresholds, and WCAG 2.3 and 2.2 compliance. Use this skill whenever the user is building or reviewing any animation, transition, scroll effect, parallax, auto-playing content, loading spinner, skeleton screen, toast, carousel, video, or any moving UI element. Trigger on phrases like "animation accessibility", "reduced motion", "prefers-reduced-motion", "vestibular", "motion sensitivity", "seizure risk", "flashing content", "parallax accessibility", "scroll animation", "view transitions", "skeleton screen motion", "animated loading", "WCAG 2.3", "motion intensity", or any request to make motion accessible. Goes beyond compliance — addresses real harm caused by inaccessible motion.
category: audit
related-skills: cognitive-accessibility, accessibility-code
---

# Motion & Animation Auditor

Motion is one of the most physically harmful accessibility failures. Animations can trigger vestibular disorders, migraines, seizures, and dissociation. This is not a subjective preference — it is a medical and legal issue.

## Philosophy

This skill audits for seizure risk, vestibular disorder risk, cognitive distraction, and overall animation accessibility. It provides quantitative motion intensity scoring, alternatives for every motion type, and complete reduced-motion implementation guidance. The goal is not to eliminate motion (motion has real UX value) but to make it safe for everyone.

---

## The Harm Model

### Vestibular Disorders
Affect ~35% of adults over 40. Symptoms triggered by screen motion: vertigo, nausea, dizziness, headaches, vomiting, dissociation. Conditions: BPPV, labyrinthitis, Meniere's disease, post-concussion syndrome, and spontaneous vertigo.

**High-Risk Motion Types:**
- Parallax scrolling (background moves at different speed than foreground)
- Large-scale movement across the viewport (>50% of screen)
- Zooming or scaling effects with velocity
- Background video with movement
- Spinning, rotating, or orbiting elements
- Page transition animations that slide/push content across the screen
- Scroll-linked animations (animation duration tied to scroll position)

### Seizure Disorders
Photosensitive epilepsy affects ~3% of people with epilepsy. General population risk: ~1 in 4,000. Broader photo-convulsive sensitivity also exists.

**Seizure Triggers:**
- Content flashing 3–50 times per second (the danger zone is 3–50 Hz)
- Red flashing is higher risk than other colors (includes color flash patterns with red)
- Large flashing areas (>25% of screen)
- Sudden luminance changes (light to dark and back, ≥10% luminance shift)

### Cognitive and Attention Disorders
Animated content can cause:
- Inability to concentrate on static content (ADHD, distraction)
- Anxiety and panic responses (PTSD, anxiety disorders)
- Cognitive overload and decision paralysis (autism, processing disorders)
- Migraine and headache (sensitivity to motion)

---

## WCAG Criteria

### 2.3.1 Three Flashes or Below Threshold (Level A)
Pages do not contain content that flashes more than 3 times per second, OR flashing is below the general and red flash thresholds.

**What counts as a flash:** A pair of opposing changes in relative luminance (light to dark and back) where the luminance difference is ≥10%.

**How to test:**
- Slow animations down to identify cycles per second
- Use the Photosensitive Epilepsy Analysis Tool (PEAT) for video content
- Any animation faster than 3 cycles/sec requires threshold analysis

### 2.3.2 Three Flashes (Level AAA)
No flashing content at all — the AAA standard eliminates the threshold exception.

### 2.3.3 Animation from Interactions (Level AAA)
Motion animation triggered by interaction can be disabled, unless the animation is essential to functionality. This criterion is the formal basis for `prefers-reduced-motion` support.

### 2.2.2 Pause, Stop, Hide (Level A)
Moving, blinking, or scrolling content that starts automatically, lasts more than 5 seconds, and is presented alongside other content must have a mechanism to pause, stop, or hide it.

**Applies to:**
- Carousels and auto-advancing slideshows
- Animated banners
- Background video
- Ticker/marquee text
- Loading animations that persist >5 seconds

### 1.4.2 Audio Control (Level A)
Any audio that plays automatically for more than 3 seconds must have a control to pause or stop it — or control the volume independently from the system volume.

---

## Motion Intensity Scoring (0–10 Scale)

Quantify motion risk on a 0–10 scale. This helps prioritize audit and remediation efforts.

| Score | Category | Risk Level | Examples | Action |
|-------|----------|------------|----------|--------|
| 0–1 | Micro-motion | Negligible | Subtle opacity fade (< 200ms) | No action needed |
| 2–3 | Gentle motion | Low | Color transition (300ms), subtle slide (250ms) | Implement prefers-reduced-motion |
| 4–5 | Moderate motion | Moderate | Slide-in panel (400ms), scale effect on hover | Implement prefers-reduced-motion + reduced alternative |
| 6–7 | Strong motion | High | Large parallax, page slide transition, spin animation | Implement prefers-reduced-motion + strong alternative |
| 8–9 | Intense motion | Very High | Full-viewport parallax, rapid 3D rotation, auto-advancing carousel | Provide disable/pause control + strong alternative |
| 10 | Extreme motion | Critical | Flashing content, rapid high-amplitude motion | Prohibited unless essential; PEAT analysis required |

**Scoring Factors:**
- **Amplitude:** How far does the element move? (5% viewport = lower score; 50%+ viewport = higher score)
- **Duration:** Shorter duration = higher perception of motion per unit time = higher score
- **Frequency:** How often does the motion occur? (One-time = lower; looping = higher; scroll-linked = variable)
- **Velocity:** How fast is the motion? (Slow sustained motion lower; sudden/fast = higher)
- **Extent:** Does motion involve the whole viewport or just a small element? (Small = lower; full viewport = higher)

**Formula (Approximate):**
```
intensity = (amplitude × velocity × frequency) / duration
(scale 0–10)
```

---

## Process

### Step 1: Identify All Motion Elements

Audit the entire page/component for:
- CSS animations and transitions
- JavaScript animations (jQuery animate, GSAP, Web Animations API)
- scroll-linked animations (position:sticky, scroll-snap, Intersection Observer trigger animations)
- Auto-playing video or animated GIFs
- Loading spinners and progress indicators
- Skeleton screens with animated placeholders
- Page transitions or route changes
- Parallax or depth effects
- Animated typography (text reveal, typewriter effect)
- Lottie or SVG animations

**Audit Table Template:**
| Animation | Element | CSS/JS? | Type | Duration | Amplitude | Intensity (0–10) | Reduced-Motion Support | Issues |
|-----------|---------|---------|------|----------|-----------|------------------|----------------------|--------|

### Step 2: Assess Seizure Risk (Flashing Content)

For any animation that creates luminance oscillation:
1. **Identify flashing:** Does the animation create opposing luminance changes (light-dark-light)?
2. **Count cycles:** How many times per second does the flash occur?
3. **Luminance shift:** What is the luminance difference between light and dark states?
4. **Area:** What percentage of the viewport does the flashing element cover?

**Safe thresholds:**
- ✓ Safe: Flashing < 3 Hz (< 3 times per second) regardless of luminance or area
- ✓ Safe: Flashing 3–50 Hz with luminance shift < 10%
- ✓ Safe: Flashing 3–50 Hz with area < 10% of viewport
- ✗ Danger: Red flashing at any rate (inherently higher seizure risk)
- ✗ Danger: Flashing 3–50 Hz with luminance shift ≥ 10% on > 10% of viewport

**For video or animated GIFs:** Use the Photosensitive Epilepsy Analysis Tool (PEAT) to verify safety.

**Common safe patterns:**
- Pulsing opacity (fade in/fade out) at < 3 Hz: ✓ Safe
- Color transitions without luminance oscillation: ✓ Safe
- Loading spinner: Depends on speed; test with PEAT if in doubt

### Step 3: Assess Vestibular Risk

For any motion that could trigger dizziness or nausea:
1. **Motion type:** Is this parallax, full-screen transition, rotation, scaling, or scroll-linked?
2. **Amplitude:** Does it move >30% of the viewport?
3. **Velocity:** Is the motion sudden or gradual?
4. **Frequency:** Is it a one-time effect or looping/repeating?

**High-risk patterns:**
- Parallax scroll: Almost always high risk unless very subtle
- Page slide transitions: High risk; use fade as reduced alternative
- Rotation or spinning elements: High risk; use color/opacity as reduced alternative
- Zoom/scale animations: Moderate to high depending on velocity
- Scroll-linked animations: High risk; animation should stop when prefers-reduced-motion is enabled

### Step 4: Assess Cognitive Load

For animations alongside task-critical content:
- Does auto-playing animation distract from reading?
- Is the animation necessary or purely decorative?
- Does it loop indefinitely (cognitive overload)?

### Step 5: Check prefers-reduced-motion Implementation

Test with `prefers-reduced-motion: reduce` enabled in the browser or OS:

**Test Checklist:**
- [ ] All CSS transitions respond to prefers-reduced-motion
- [ ] All CSS animations respond to prefers-reduced-motion
- [ ] JS-triggered animations check the media query
- [ ] Third-party animation libraries (GSAP, Framer Motion, Lottie, AOS) are configured with reduced motion support
- [ ] Scroll animation libraries have reduced motion paths
- [ ] Page transitions don't animate when reduced motion is preferred
- [ ] Loading spinners don't spin when reduced motion is preferred (or are replaced with progress bars)
- [ ] Auto-playing carousels don't auto-advance when reduced motion is preferred

**Enable prefers-reduced-motion:**
- macOS: System Settings → Accessibility → Display → Reduce Motion
- iOS: Settings → Accessibility → Motion → Reduce Motion
- Windows: Settings → Ease of Access → Display → Show animations
- Android: Settings → Accessibility → Remove animations
- Browser DevTools: Chrome Rendering panel → Emulate CSS media feature `prefers-reduced-motion: reduce`

---

## Reference Guide

### prefers-reduced-motion Implementation

**CSS — Safe Default Pattern**
Start from no motion; add motion only for users who haven't opted out:

```css
/* Base: no animation */
.card {
  transition: none;
}

/* Motion-safe: add animation only if not reduced */
@media (prefers-reduced-motion: no-preference) {
  .card {
    transition: transform 0.3s ease, box-shadow 0.3s ease;
  }
}
```

This is safer than the inverse approach.

**CSS — Remove Specific Motion**
```css
@media (prefers-reduced-motion: reduce) {
  *,
  *::before,
  *::after {
    animation-duration: 0.01ms !important;
    animation-iteration-count: 1 !important;
    transition-duration: 0.01ms !important;
    scroll-behavior: auto !important;
  }
}
```

Use as a catch-all safety net, but do not rely on it as the only implementation.

**JavaScript — Conditional Animation**
```javascript
const prefersReduced = window.matchMedia('(prefers-reduced-motion: reduce)').matches;

if (!prefersReduced) {
  // Run full animation
  element.animate([...], { duration: 600, easing: 'ease-out' });
} else {
  // Skip or use instant state change
  element.style.opacity = '1';
}
```

**React — Custom Hook**
```jsx
import { useEffect, useState } from 'react';

function usePrefersReducedMotion() {
  const [prefersReduced, setPrefersReduced] = useState(
    () => window.matchMedia('(prefers-reduced-motion: reduce)').matches
  );

  useEffect(() => {
    const mq = window.matchMedia('(prefers-reduced-motion: reduce)');
    const handler = (e) => setPrefersReduced(e.matches);
    mq.addEventListener('change', handler);
    return () => mq.removeEventListener('change', handler);
  }, []);

  return prefersReduced;
}

// Usage
function AnimatedCard() {
  const reduced = usePrefersReducedMotion();
  return (
    <div style={{ transition: reduced ? 'none' : 'transform 0.3s ease' }}>
      ...
    </div>
  );
}
```

### Animation Alternatives Table

Every motion can be replaced with a safe alternative:

| Full Motion | Reduced Alternative | Why It Works | Intensity Drop |
|-------------|---------------------|--------------|----------------|
| Slide-in panel | Fade-in panel | Opacity change has no spatial velocity | 6+ → 2 |
| Parallax scroll | Static layered background | Removes amplitude/velocity entirely | 8+ → 0 |
| Page slide transition | Instant swap or crossfade | Crossfade is fast enough to avoid vestibular trigger | 7 → 2 |
| Spinning loader | Static progress bar or pulsing dot | Pulsing is safe at < 3 Hz; removes rotation | 7 → 2 |
| Bouncing animation | Simple opacity pulse | Opacity pulse at < 3 Hz is safe; removes bounce vector | 6 → 2 |
| Scale-up hover | Color change or border change | Non-spatial change; instant perception | 4 → 1 |
| Scroll-triggered fly-in | Instant appear on scroll | Eliminates motion entirely; element appears when in view | 7 → 0 |
| Rotating 3D element | Static 2D version with color variant | Removes rotation risk; color variant provides visual distinction | 8 → 1 |
| Typing animation | Static text reveal line-by-line | Removes character-by-character motion; maintains reveal structure | 3 → 1 |
| Auto-advancing carousel | Manual navigation only | Eliminates autonomous motion; user controls pace | 5 → 0 |

### Third-Party Library Reduced Motion Support

**Framer Motion**
```jsx
import { MotionConfig } from 'framer-motion';

function App() {
  const reduceMotion = usePrefersReducedMotion();
  return (
    <MotionConfig reducedMotion={reduceMotion ? 'always' : 'user'}>
      {/* All motion inside respects user preference */}
    </MotionConfig>
  );
}
```

**GSAP (GreenSock Animation Platform)**
```javascript
const prefersReduced = window.matchMedia('(prefers-reduced-motion: reduce)').matches;

if (prefersReduced) {
  // Create instant state change instead of timeline
  gsap.set('.element', { opacity: 1 });
} else {
  // Create timeline
  gsap.timeline().to('.element', { opacity: 1, duration: 1 });
}
```

**Lottie**
```jsx
import Lottie from 'lottie-react';
import animationData from './animation.json';

function LottieAnimation() {
  const reducedMotion = usePrefersReducedMotion();

  if (reducedMotion) {
    // Show static fallback image
    return <img src="animation-first-frame.png" alt="Loading" />;
  }

  return <Lottie animationData={animationData} loop={true} />;
}
```

**AOS (Animate On Scroll)**
```javascript
AOS.init({
  disable: window.matchMedia('(prefers-reduced-motion: reduce)').matches
});
```

**CSS Frameworks (Tailwind)**
Tailwind v3+ includes `motion-reduce:` variant:
```html
<div class="transition-all motion-reduce:transition-none">
  This element doesn't animate when reduced motion is preferred.
</div>
```

### Scroll-Driven Animations

Scroll-driven animations are inherently problematic for vestibular disorders because motion is tied to user scroll speed, creating unpredictable acceleration.

**Audit Pattern:**
```javascript
// Check if any animations are bound to scroll position
const animations = document.getAnimations();
animations.forEach(animation => {
  if (animation.timeline && animation.timeline instanceof ScrollTimeline) {
    console.warn('Scroll-driven animation found:', animation);
  }
});
```

**Safe Implementation (if required):**
```css
@media (prefers-reduced-motion: reduce) {
  /* Disable scroll-driven animations entirely */
  * {
    animation: none !important;
    transition: none !important;
  }
}
```

### Skeleton Screen and Loading State Motion

**Animation:**
Animated skeleton screens (pulsing, shimmer effects) can be distracting and vestibular-triggering.

**Safe Alternative:**
```css
/* Animated shimmer: 1-second duration, subtle effect */
@keyframes shimmer {
  0% { background-position: -1000px 0; }
  100% { background-position: calc(1000px + 100%) 0; }
}

.skeleton {
  background: linear-gradient(90deg, #f0f0f0 25%, #e0e0e0 50%, #f0f0f0 75%);
  background-size: 1000px 100%;
  animation: shimmer 2s infinite;
}

/* Reduced motion: static skeleton */
@media (prefers-reduced-motion: reduce) {
  .skeleton {
    animation: none;
    background: #f0f0f0;
  }
}
```

### View Transitions API

The View Transitions API provides cross-document page transitions. By default, it creates animated transitions which can be problematic for vestibular users.

**Safe Implementation:**
```javascript
// Check prefers-reduced-motion before using View Transitions
if (!window.matchMedia('(prefers-reduced-motion: reduce)').matches) {
  document.startViewTransition(() => {
    // Navigate or update DOM
  });
} else {
  // Direct navigation without transition
  window.location.href = '/new-page';
}
```

---

## Output Format

### Motion & Animation Accessibility Audit

```
## Motion & Animation Accessibility Audit

**Product / Page:** [name]
**Date:** [date]
**Auditor:** [name]

### Summary
[1–2 sentences: overall motion accessibility state, primary risk areas]

### Seizure Risk Assessment (WCAG 2.3)
| Animation | Flash Rate (Hz) | Luminance Shift | Area | Status | Action |
|-----------|-----------------|-----------------|------|--------|--------|
| Loading spinner | 2 cycles/sec | 0% | 5% | ✓ Safe | Monitor |
| Page transition flash | 4 cycles/sec | 15% | 100% | ✗ FAIL | Remove/replace |

**Verdict:** [Safe / At risk / Critical]

### Vestibular Risk Assessment
| Animation | Type | Amplitude | Velocity | Intensity | Reduced Alternative | Status |
|-----------|------|-----------|----------|-----------|--------------------| --------|
| Hero parallax | Parallax scroll | 80% viewport | Fast | 9/10 | Static background | ✗ High risk |
| Card hover scale | Scale | 10% | Moderate | 3/10 | Color change | ✓ Acceptable |
| Page transition | Slide | 100% | Moderate | 7/10 | Fade to black | ✗ Needs fix |

### Cognitive Load Assessment
- Auto-playing carousel: ✓ Has pause control
- Animated banner: ✓ Duration < 5 seconds
- Loading spinner: ✓ Not persistent
- Toast notifications: ✗ No dismiss option on some toasts

### prefers-reduced-motion Coverage
| Animation | CSS/JS/Library | Responds to PRM? | Alternative | Status |
|-----------|----------------|------------------|-------------|--------|
| Button hover transition | CSS | ✓ Yes | Color change | ✓ |
| Page route transition | JS/Next.js | ✗ No | Needs implementation | ✗ |
| Lottie loader | Lottie | ✓ Custom fallback | Static image | ✓ |
| AOS scroll reveal | AOS library | ✗ Partial | Needs configuration | ✗ |

### Critical Issues (P0)
[Seizure risk, extreme vestibular risk, animations affecting critical functionality]

**Example:**
- Page transition flash occurs at 4 Hz with 15% luminance shift on 100% of viewport — exceeds WCAG 2.3.1 threshold
- Parallax effect creates strong vestibular risk (intensity 9/10) with no reduced motion alternative

### Major Issues (P1)
[High vestibular risk, missing prefers-reduced-motion, auto-playing content without pause]

### Minor Issues (P2)
[Moderate vestibular risk, cognitive distractions, suboptimal reduced motion alternatives]

### Code Fixes
[Corrected CSS/JS for each animation requiring remediation]

**Example (Parallax):**
```css
/* Before: Parallax causes vestibular risk */
.background {
  position: fixed;
  transform: translateY(calc(var(--scroll) * 0.5px));
}

/* After: Removed parallax; static background */
.background {
  position: fixed;
  transform: none;
}

/* Reduced motion support across all animations */
@media (prefers-reduced-motion: reduce) {
  * {
    animation-duration: 0.01ms !important;
    transition-duration: 0.01ms !important;
  }
}
```

### Testing Notes
How to manually verify:
1. Enable Reduce Motion in your OS
2. Test each animation: verify it stops, is replaced, or becomes instant
3. Verify functionality is unaffected
4. Test page transitions, carousel auto-advance, loading states

Browser testing: Chrome → Rendering panel → Emulate CSS media feature `prefers-reduced-motion: reduce`
```

---

## Testing Instructions

1. **macOS:** System Settings → Accessibility → Display → Reduce Motion
2. **iOS:** Settings → Accessibility → Motion → Reduce Motion
3. **Windows:** Settings → Ease of Access → Display → Show animations
4. **Android:** Settings → Accessibility → Remove animations
5. **Browser DevTools (Chrome):** Rendering panel → Emulate CSS media feature `prefers-reduced-motion: reduce`

When testing with Reduce Motion enabled, every animation should either:
- Stop completely (no motion)
- Be replaced with a fade or instant state change
- Break into discrete steps rather than smooth motion

**Nothing should break functionally. If an animation is essential, provide a safe alternative, not the removal of motion.**

---

## Cross-References

- **cognitive-accessibility:** Assess how animations contribute to cognitive load and attention management
- **accessibility-code:** Implement prefers-reduced-motion in production CSS and JavaScript
