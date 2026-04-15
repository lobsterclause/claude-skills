---
name: contrast-checker
description: Calculate and evaluate color contrast ratios for accessibility compliance. Use this skill whenever the user provides color values (hex, RGB, HSL, CSS named colors) and wants to check contrast, find accessible color alternatives, audit a palette, or understand WCAG contrast requirements. Trigger on phrases like "contrast ratio", "color contrast", "check these colors", "does this pass WCAG", "accessible color", "contrast checker", "what's the contrast between", "fix my contrast", "find a color that passes", "dark mode contrast", "color blind", "deuteranopia", "protanopia", or any mention of 1.4.3, 1.4.6, 1.4.11, or APCA. Also trigger when the user shares a color palette and asks if it's accessible, or when reviewing design tokens for accessibility. Always show the math, not just pass/fail.
category: audit
related-skills: accessibility-audit, accessibility-code
---

# Contrast Checker

You calculate WCAG contrast ratios precisely and help find compliant color alternatives. You understand that contrast is not a single number — it varies across color blindness types, dynamic states, and light modes. Always show your work — designers need to understand the numbers and their limitations, not just the verdict.

## Philosophy

Contrast is foundational to accessibility but deeply incomplete. A pair of colors may pass WCAG yet fail for users with color blindness, fail in hover or focus states, or fail in dark mode variants. This skill goes beyond mechanical ratio calculation to audit contrast holistically: across user perception models, interactive states, and light/dark implementations.

---

## Core Framework

### WCAG 2.2 Contrast (Primary Requirement)
WCAG defines relative luminance contrast ratios. This is the legal baseline and the most widely adopted standard. But it has known limitations for certain color blindness types.

### APCA (Advanced Perceptual Contrast Algorithm)
APCA is a perceptual contrast algorithm being standardized for WCAG 3.0. It is not yet required for WCAG 2.x compliance, but it provides more accurate perceptual modeling, especially for large type and very light/very dark colors. When relevant (e.g., large headlines or very light colors), include APCA analysis alongside WCAG.

### Color Blindness Simulation
Red-green color blindness (deuteranopia, protanopia) affects ~8% of men and ~0.5% of women. Tritanopia (blue-yellow) is rarer (~0.001%). Always validate that contrast remains sufficient when color information is removed or shifted.

---

## Process

### Step 1: Calculate WCAG 2.2 Contrast Ratio

**Parse the Color**
Accept any format and normalize to 0–1 linear RGB:
- Hex: `#1a2b3c` → R=0x1a/255, G=0x2b/255, B=0x3c/255
- RGB: `rgb(26, 43, 60)` → divide each by 255
- HSL: convert to RGB first
- CSS named colors: look up hex value
- Color functions: `color(display-p3 ...)` → convert to sRGB

**Linearize (Gamma Correction)**
For each channel value `c` (0–1):
```
if c <= 0.04045:
    linear = c / 12.92
else:
    linear = ((c + 0.055) / 1.055) ^ 2.4
```

**Calculate Relative Luminance (L)**
```
L = 0.2126 * R_linear + 0.7152 * G_linear + 0.0722 * B_linear
```

**Calculate Contrast Ratio**
Given luminances L1 (lighter) and L2 (darker):
```
ratio = (L1 + 0.05) / (L2 + 0.05)
```
Always put the lighter color in the numerator. Result is expressed as X:1.

**Worked Example:**
`#ffffff` (white) vs `#767676` (gray):
- White: L = 1.0
- #767676 → R=G=B = 118/255 = 0.4627
  - linearized: ((0.4627 + 0.055) / 1.055)^2.4 = 0.2158
  - L = 0.2126(0.2158) + 0.7152(0.2158) + 0.0722(0.2158) = 0.2158
- Ratio: (1.0 + 0.05) / (0.2158 + 0.05) = 1.05 / 0.2658 = **3.95:1**
- Result: Passes AA Large Text (3:1), fails AA Normal Text (4.5:1)

### Step 2: Evaluate Dynamic States

Contrast must be sufficient not only in default state but in all interactive states:
- **Hover:** foreground and background in :hover state
- **Focus:** focus indicator outline against background (WCAG 2.4.13: 3:1 minimum for non-text focus indicators)
- **Active:** :active state colors
- **Disabled:** some disabled states are exempt from contrast; others are not (note the exemption clearly)
- **Placeholder text:** in form inputs (often lower contrast; check your baseline)

Build a full state contrast matrix and flag any state that fails.

### Step 3: Simulate Color Blindness

For any pair that relies on color differentiation (not just luminance), simulate the pair under:
- **Deuteranopia** (red-green, most common type): Simulate by removing/reducing green channel contrast
- **Protanopia** (red-green, red weak): Simulate by reducing red channel
- **Tritanopia** (blue-yellow, rare): Simulate by desaturating blue-yellow axis

Use tools like ColorOracle (free desktop simulator) or Accessible Colors (web tool) to visualize. The contrast may remain sufficient numerically but become invisible or confusing when color is removed.

### Step 4: Evaluate Light & Dark Mode Variants

For products with dark mode:
- Test all contrast pairs in **light mode** (light background, dark foreground)
- Test all contrast pairs in **dark mode** (dark background, light foreground)
- Do not assume that inverting colors produces compliant results
- Some color pairs may pass light mode but fail dark mode, or vice versa

### Step 5: Consider APCA for Edge Cases

APCA is a perceptual model that is more accurate for very light, very dark, and large-type scenarios. When:
- Text is very large (36pt+): APCA may show colors as more or less accessible than WCAG suggests
- Colors are extreme (near white or near black): APCA provides more perceptually accurate assessment
- Using WCAG for a color pair that feels barely readable or overly contrasted: APCA can confirm the perception

APCA output format: `Lc = XX`. Thresholds vary by type size. Do not replace WCAG with APCA, but mention APCA as supplemental evidence when relevant.

---

## Reference Guide

### WCAG 2.2 Contrast Requirements

**Text Contrast (1.4.3 AA / 1.4.6 AAA)**

| Text Type | AA Minimum | AAA Enhanced |
|-----------|------------|--------------|
| Normal text (< 18pt / < 14pt bold) | 4.5:1 | 7:1 |
| Large text (≥ 18pt / ≥ 14pt bold) | 3:1 | 4.5:1 |
| Disabled UI components | Exempt | Exempt |
| Decorative text | Exempt | Exempt |
| Logotypes and brand names | Exempt | Exempt |

**Large Text Thresholds:**
- 18pt = 24px at 96dpi (standard web assumption)
- 14pt bold = 18.67px bold at 96dpi
- On high-DPI screens, use actual rendered size, not CSS size

**Non-Text Contrast (1.4.11 AA)**
- UI component boundaries, icons, and focus indicators: **3:1 minimum** against adjacent colors
- No AAA criterion for non-text contrast
- Applies to: input borders, checkbox outlines, radio buttons, button boundaries, border-only buttons, chart lines, icon graphics
- Two-color icons or shapes must maintain 3:1 between the two colors, not just against background

**Dynamic State Contrast**
- Focus indicators must meet 3:1 non-text contrast against adjacent colors (WCAG 2.4.13 AAA)
- Hover states must maintain their contrast ratios; hover cannot reduce contrast below baseline
- Disabled states: If presented as "reduced visual prominence," they are often exempt — document the exemption claim
- Pressed/selected states must maintain contrast with unselected states (3:1 for non-text, 4.5:1 for text labels in UI)

### Color Blindness Simulation Reference

**Deuteranopia (Red-Green, Green Weak)**
- Reds appear brownish or dark
- Greens appear brownish or dark
- Blues and yellows remain distinct
- Test: Red text on green background becomes invisible; use luminance contrast instead

**Protanopia (Red-Green, Red Weak)**
- Reds appear dark
- Greens appear bright
- Blues and yellows remain distinct
- Test: Red/green buttons must differ by luminance, not just hue

**Tritanopia (Blue-Yellow, Rare)**
- Blues appear reddish
- Yellows appear pink
- Reds and greens remain somewhat distinct
- Test: Blue/yellow navigation elements must differ by luminance or pattern, not just color

**Common Failure Pattern:**
A pair like #ff0000 (red) and #00ff00 (green) might have adequate WCAG ratio (around 2.74:1, which fails AA), but even worse: under deuteranopia, both appear nearly identical brown. Never use color alone to convey meaning; pair with luminance contrast or pattern.

### Gradient and Image Overlay Contrast

**Gradients:**
- Test contrast at the darkest and lightest points of the gradient
- For text over gradient: if the gradient changes color, test contrast at the point where text will be placed
- Flag gradients that create high-variance contrast across the component

**Image Overlays:**
- When text is placed over an image, test contrast in multiple areas of the image (highlights, shadows, details)
- If consistent contrast cannot be achieved, use a semi-transparent overlay behind the text
- Overlay color must itself have contrast against both the image and the text

**Worked Example:**
Text over a photo of a sunset. The sky is light (high luminance), the foreground is dark. Black text works on the sky; white text works on the foreground. Solution: use a dark semi-transparent overlay (e.g., `rgba(0, 0, 0, 0.4)`) behind white text, ensuring 4.5:1 contrast between white text and the darkened overlay.

### Dark Mode Contrast Considerations

- **Inverted palettes:** Simply inverting RGB values (#ffffff → #000000) does not guarantee WCAG compliance in the opposite mode. Test each pair independently.
- **Neutral grays:** Grays (e.g., #808080) that work well on white backgrounds may fail on black backgrounds due to gamma/perception. Use different gray values for light and dark modes.
- **Color meaning preservation:** A color that conveys "error" in light mode (e.g., red) must remain visually distinct and have adequate contrast in dark mode. Sometimes this requires using a different red variant per mode.
- **Approach:** Treat light mode and dark mode as two separate color systems. Test all user-facing colors in both modes independently.

### Palette Audit Structure

When auditing a design token palette:

```
## Palette Contrast Audit

| Component | Token | Light BG (L mode) | Dark BG (D mode) | AA Text | AA Non-Text | AAA Text | Status |
|-----------|-------|-------------------|------------------|---------|-------------|----------|--------|
| Body text | text-primary | #1a1a1a on #fff | #f5f5f5 on #121212 | 19.1:1 ✓ | — | 19.1:1 ✓ | ✓ |
| Placeholder | text-secondary | #9e9e9e on #fff | #757575 on #121212 | 2.85:1 ✗ | — | — | ✗ FAIL |
| Error text | text-error | #d32f2f on #fff | #ff5252 on #121212 | 5.12:1 ✓ | — | 4.02:1 ✗ | ✓ AA |
| Button border | btn-primary-outline | — | — | — | 5:1 ✓ | 3:1 ✓ | ✓ |
| Icon (primary) | icon-primary | #1a1a1a / #f5f5f5 | #f5f5f5 / #1a1a1a | — | 19.1:1 ✓ | — | ✓ |
| Link (visited) | link-visited | #6a0dad on #fff | #bb86fc on #121212 | 4.02:1 ✓ | — | 3.61:1 ✗ | ✓ AA |
| Focus ring | focus-indicator | 3px solid #005fcc | 3px solid #90caf9 | — | 6.5:1 ✓ | — | ✓ |
```

---

## Output Format

### Single Pair Contrast Check

```
## Contrast Check: [Color A] on [Color B]

**Foreground:** #XXXXXX (R=XX, G=XX, B=XX)
**Background:** #XXXXXX (R=XX, G=XX, B=XX)

### Luminance Values
- Foreground luminance: X.XXXX
- Background luminance: X.XXXX

### Contrast Ratio: X.XX:1

### WCAG 2.2 Results
| Criterion | Threshold | Result |
|-----------|-----------|--------|
| AA Normal Text (1.4.3) | 4.5:1 | ✓ Pass / ✗ Fail |
| AA Large Text (1.4.3) | 3:1 | ✓ Pass / ✗ Fail |
| AAA Normal Text (1.4.6) | 7:1 | ✓ Pass / ✗ Fail |
| AAA Large Text (1.4.6) | 4.5:1 | ✓ Pass / ✗ Fail |
| Non-Text (1.4.11) | 3:1 | ✓ Pass / ✗ Fail |

### APCA Analysis (Supplemental)
- Lc value: XX (large text: 75+, normal text: 60+)
- Assessment: [Perceptually accessible / Borderline / Inaccessible]

### Color Blindness Simulation
- Deuteranopia: [Color A description] / [Color B description] → Contrast remains X.XX:1 (Visible / Indistinguishable)
- Protanopia: [Analysis]
- Tritanopia: [Analysis]

### Dynamic State Contrast
| State | Foreground | Background | Ratio | Status |
|-------|-----------|-----------|-------|--------|
| Default | #XXXXXX | #XXXXXX | X.XX:1 | ✓ Pass |
| Hover | #XXXXXX | #XXXXXX | X.XX:1 | ✓ Pass |
| Focus | outline: 3px | adjacent color | X:1 | ✓ Pass |
| Active | #XXXXXX | #XXXXXX | X.XX:1 | ✗ Fail |
| Disabled | — | — | Exempt | N/A |

### Dark Mode Assessment
- Light mode ratio: X.XX:1 ✓
- Dark mode ratio: X.XX:1 ✓
- Verdict: Both modes compliant / One mode fails

### Verdict
[Plain-language summary: what this color pair can and cannot be used for, limitations, recommendations]
```

### Palette Audit (Multiple Pairs)

Include the table structure above, plus a fixes section:

```
## Palette Contrast Audit: [Design System / Component Library]

[Full audit table with all token pairs and modes]

### Failures Requiring Attention

#### 1. Placeholder text (#9e9e9e on #ffffff)
- Current ratio: 2.85:1 (fails AA)
- Recommendation: Darken to #666666
- New ratio: 7.15:1 (passes AAA)
- Test in dark mode: #777777 on #121212 = 5.2:1 ✓

#### 2. Error state hover (#e53935 on #fff, hover state)
- Current ratio: 4.8:1 (passes AA)
- Hover state (#c62828): 6.2:1 ✓
- Assessment: Hover increases contrast, which is good

[Continue for each failure]
```

---

## Finding Compliant Alternatives

**Darken the Foreground (on light backgrounds)**
- Adjust L* in HSL/OKLCH downward in steps until ratio passes
- Show the hex of the compliant color and how far it shifted visually
- Verify the darkened color still meets color-blind contrast requirements

**Lighten the Background**
- Often less desirable — can wash out the UI
- Show the option but flag the tradeoff
- Verify dark mode implications before recommending

**Target Ratio Approach**
When asked "find me a [color] that passes AA on [background]":
1. Calculate current ratio
2. Determine required luminance for target ratio
3. Solve for L* value, keeping H and S constant (HSL adjustment)
4. Return the closest hex that achieves the target
5. Verify against color blindness simulation and dark mode variant

---

## Important Notes

- **Contrast is necessary but insufficient.** Font weight, size, letter spacing, and typeface legibility all affect real-world readability. A pair that passes WCAG may still be hard to read for users with low vision.
- **APCA is not yet required.** Mention it when relevant for large text, extreme luminances, or when WCAG feels off, but do not substitute it for WCAG 2.x compliance calculations.
- **Dark mode requires separate audit.** Inverting colors does not guarantee compliance. Test all pairs in both modes independently.
- **Color alone is not enough.** If color is used to convey meaning (error, success, warning, link visited), ensure that meaning is also conveyed by text label, icon, underline, or other non-color cue.
- **Test in the actual rendering environment.** Monitor calibration, ambient lighting, and display technology affect perceived contrast. WCAG ratios are mathematical; perception is visual.
- **Relative luminance values are based on sRGB.** For wide-gamut colors (Display P3, Rec2020), convert to sRGB before calculating.

---

## Cross-References

- **accessibility-audit:** Reference this skill when auditing contrast across entire designs
- **accessibility-code:** Implement focus indicators (non-text 3:1 contrast) and state-dependent colors using this skill
