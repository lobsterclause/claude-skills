---
name: mobile-touch-auditor
description: Audit mobile and touch interfaces for accessibility — including gesture alternatives, touch target sizing, orientation, virtual keyboards, iOS VoiceOver, Android TalkBack, wearables, and mobile-specific WCAG criteria. Use this skill whenever the user is building or reviewing a mobile app, responsive web app, touch interface, wearable, or tablet UI and needs mobile-specific accessibility guidance. Trigger on phrases like "mobile accessibility", "touch accessibility", "iOS accessibility", "Android accessibility", "VoiceOver iOS", "TalkBack", "touch target", "gesture alternative", "swipe gesture", "mobile audit", "responsive accessibility", "accessible app", "orientation lock", "tablet accessibility", "wearable accessibility", or any request involving mobile or tablet UI. Covers WCAG 2.2 AA/AAA mobile criteria, iOS 17+ VoiceOver, Android 14+ TalkBack, and platform-specific accessibility APIs.
---

# Mobile & Touch Accessibility Auditor

Mobile accessibility is not a subset of web accessibility. Touch interfaces, platform-specific AT, gesture models, mobile context (one hand, moving, bright sunlight, no mouse), wearables, and tablets create distinct sets of requirements that desktop-focused audits miss entirely.

## Mobile Context Model

Before auditing, understand the use context:
- **One-handed use** — thumb reach zones limit interaction targets
- **Variable environment** — sunlight (contrast), noise (no audio cues), motion (stability)
- **Divided attention** — walking, commuting, multitasking
- **Fat finger problem** — touch imprecision is universal, not a disability
- **No hover state** — hover-dependent content is inaccessible on touch
- **Virtual keyboard** — reduces visible viewport by 40–60%
- **Wearable constraints** — smaller screens (1.4"–2"), limited interaction surface, brief engagement windows
- **Tablet dual-purpose** — sometimes one-handed, sometimes landscape, keyboard attachment scenarios

Disability-specific considerations on mobile:
- Motor: tremor, limited grip, prosthetic use, switch access, reduced dexterity
- Visual: VoiceOver/TalkBack, screen magnification, inverted colors, high contrast modes
- Cognitive: small screen, information density, navigation complexity, working memory load
- Hearing: no audio feedback without visual alternatives, caption needs on video

---

## WCAG Criteria — Mobile Priority

### Touch and Pointer
| Criterion | Level | Mobile Relevance |
|-----------|-------|-----------------|
| 2.5.1 Pointer Gestures | A | All swipe/pinch/multi-touch must have single-tap alternative |
| 2.5.2 Pointer Cancellation | A | Actions on up-event, not down-event; drag-cancel supported |
| 2.5.4 Motion Actuation | A | Shake/tilt must have UI alternative; can be disabled |
| 2.5.5 Target Size (Enhanced) | AAA | 44×44px minimum |
| 2.5.7 Dragging Movements | AA | Single-pointer alternative for all drag operations |
| 2.5.8 Target Size (Minimum) | AA | 24×24px or adequate spacing |
| 1.3.4 Orientation | AA | Content not locked to portrait or landscape |
| 1.3.5 Identify Input Purpose | AA | Autocomplete tokens for personal data |

### Visual
| Criterion | Level | Mobile Relevance |
|-----------|-------|-----------------|
| 1.4.3 Contrast (Minimum) | AA | Test in simulated sunlight conditions |
| 1.4.4 Resize Text | AA | System font size settings must be respected |
| 1.4.10 Reflow | AA | 320px equivalent viewport without horizontal scroll |
| 1.4.11 Non-text Contrast | AA | UI component boundaries — especially on white backgrounds |
| 1.4.13 Content on Hover or Focus | AA | Hover tooltips inaccessible on touch — must have tap alternative |

---

## Core Framework

### Touch Target Accessibility Scoring (0–10)

Score each dimension independently; average for overall mobile touch score.

#### 1. Touch Target Size (0–10)
- **10:** All interactive elements 44×44px minimum (CSS px), with 8px+ spacing
- **8:** Most targets 44×44px; some smaller with adequate spacing; no critical controls undersized
- **6:** Mix of 24–44px targets; spacing inconsistent; some grouped controls awkwardly close
- **4:** Several targets 20–24px; unclear spacing model; difficult to tap without missing
- **2:** Many targets <20px or tightly grouped; requires high precision
- **0:** No consistent sizing; tap targets unclear or overlapping

#### 2. Gesture Accessibility (0–10)
- **10:** All path-based and multi-touch gestures have single-pointer alternatives; documented
- **8:** Primary gestures have tap alternatives; secondary gestures may require multitouch
- **6:** Most gestures have alternatives; some complex interactions only gesture-available
- **4:** Gesture available; alternative possible but not discoverable
- **2:** Alternative exists but requires multiple steps or navigation to find
- **0:** Gesture is the only way to perform critical action

#### 3. Orientation & Responsive (0–10)
- **10:** Works equally in portrait and landscape; all content visible; no reflow breaks
- **8:** Both orientations supported; minor layout shifts but no content loss
- **6:** Primarily portrait; landscape works but cramped or requires scroll
- **4:** Landscape difficult or requires excessive scrolling; some features orientation-locked
- **2:** One orientation barely functional; significant content loss when switching
- **0:** Content locked to single orientation; other orientation fails

#### 4. AT Compatibility (0–10)
- **10:** VoiceOver/TalkBack fully functional; all controls properly labeled; modal state managed; dynamic updates announced
- **8:** VoiceOver/TalkBack mostly functional; minor missing labels; some complex interactions require manual testing
- **6:** Partially compatible; missing labels on some controls; modal/dynamic content sometimes silent
- **4:** Significant gaps; custom controls not fully accessible; AT users hit dead ends
- **2:** Minimal AT support; many controls unlabeled or nonfunctional with AT
- **0:** AT unusable; custom controls with no accessibility API integration

#### 5. Virtual Keyboard & Input (0–10)
- **10:** Appropriate input types; keyboard doesn't obscure critical controls; active field scrolls into view; submit button always accessible
- **8:** Correct input types; keyboard mostly doesn't block content; minor scrolling needed
- **6:** Some input type mismatches; keyboard obscures content in some cases; workaround available
- **4:** Wrong input types common; keyboard often blocks critical fields; submit requires dismissing keyboard
- **2:** Keyboard blocks major UI; inputs not optimized; confusing input type mismatch
- **0:** Keyboard breaks layout; content becomes unreachable

---

## Process

### Phase 1: Context & Device Setup
1. Identify target platforms (iOS 17+, Android 14+, responsive web, PWA)
2. Identify key user flows (signup, checkout, primary action, settings)
3. Test on actual devices (not emulators for VoiceOver/TalkBack) when possible
4. Record baseline: screen size, OS version, AT version

### Phase 2: Touch Target Audit
1. **Inventory** all interactive elements in primary flows
2. **Measure** tappable areas (not visible size; account for padding)
3. **Analyze spacing** between adjacent targets
4. **Test** at 320px breakpoint (WCAG 1.4.10)
5. **Identify** high-risk patterns (tab bars, pagination, inline links)
6. **Score** across the Touch Target dimension

### Phase 3: Gesture Inventory
1. **List** all swipe, pinch, long-press, drag, and motion gestures
2. **Determine** if each gesture is primary (user relies on it) or alternative
3. **Verify** each primary gesture has a single-pointer alternative
4. **Test** drag-to-cancel on pointer-down actions
5. **Check** motion gestures can be disabled via system settings
6. **Score** Gesture Accessibility dimension

### Phase 4: Orientation & Responsive Testing
1. Test at 320px width (portrait and landscape)
2. Verify 1.3.4: content not locked; orientation can be changed without loss
3. Test content reflow at 1.4.10 standards
4. Check fixed/sticky elements don't obscure critical content
5. Test landscape use cases (video, maps, games)
6. Score Orientation & Responsive dimension

### Phase 5: AT Testing (VoiceOver & TalkBack)
1. **iOS VoiceOver:**
   - Activate triple-click Home or Settings > Accessibility > VoiceOver
   - Test primary flows: navigation, form entry, action completion
   - Verify custom elements have labels (accessibilityLabel set)
   - Check modal state trap (accessibilityViewIsModal = true)
   - Announce dynamic updates (post announcement notification)
2. **Android TalkBack:**
   - Activate Volume Up + Down or Settings > Accessibility > TalkBack
   - Test same flows
   - Verify custom View elements have contentDescription
   - Check importantForAccessibility flags
   - Verify announceForAccessibility for status changes
3. **Web (Responsive):**
   - VoiceOver on iOS Safari
   - TalkBack on Android Chrome
   - Verify semantic HTML (landmarks, headings, form structure)
   - Check ARIA labels and live regions
4. Score AT Compatibility dimension

### Phase 6: Virtual Keyboard & Input Optimization
1. Test each input type (email, tel, url, search, password, number)
2. Verify appropriate virtual keyboard appears
3. Check active input scrolls into view
4. Verify submit button visible or accessible without dismissing keyboard
5. Test autocomplete tokens (WCAG 1.3.5)
6. Test password managers (1Password, Bitwarden) can autofill
7. Score Virtual Keyboard dimension

### Phase 7: PWA-Specific Considerations (if applicable)
1. Verify offline mode announcement (app is offline, data syncing in progress)
2. Check installation prompt has alt pathway (not gesture-only)
3. Test splash screen text contrast and size
4. Verify app shortcuts are labeled
5. Check notification accessibility (text alternatives, not icon-only)

### Phase 8: Cross-Device Testing Matrix (if applicable)
Run core flows on:
- iPhone SE (small: 375px), iPhone Pro (medium: 393px), iPhone Pro Max (large: 430px)
- iPad (landscape: 1024px)
- Android small phone (360px), standard phone (412px), large phone (480px)
- Android tablet (landscape: 800px+)
- Smartwatch (240px) if applicable

---

## Reference Guide

### iOS VoiceOver Accessibility API (Native Apps — Swift)

```swift
// Set accessible label
imageView.accessibilityLabel = "Profile photo of Sarah Johnson"

// Set hint (additional context announced after a delay)
button.accessibilityHint = "Double-tap to edit your profile picture"

// Mark as modal (VoiceOver focus trapped within modal)
modalView.accessibilityViewIsModal = true

// Group elements (announced as single element)
containerView.isAccessibilityElement = false
containerView.shouldGroupAccessibilityChildren = true

// Announce dynamic content change
UIAccessibility.post(
  notification: .announcement,
  argument: "3 items added to cart, total is $45.99"
)

// Move focus after navigation
UIAccessibility.post(
  notification: .screenChanged,
  argument: viewController.navigationController?.navigationBar
)

// Set trait (button, link, header, etc.)
button.accessibilityTraits = .button

// Mark decorative element as not accessible
decorativeView.isAccessibilityElement = false
```

#### iOS 17+ Enhancements
- **Live Activities:** Announce on update via AccessibilityFocusOnUpdate
- **Dynamic Type:** Always respect UIFont.preferredFont(forTextStyle:) — never set font sizes to fixed px
- **Haptics:** Use haptic feedback to reinforce important actions (UIImpactFeedbackGenerator)
- **DynamicIsland:** Ensure focus can reach all interactive elements in the island on iPhone 14 Pro+

### Android TalkBack Accessibility API (Native Apps — Kotlin)

```kotlin
// Content description for View
imageView.contentDescription = "Profile photo of Sarah Johnson"

// Mark decorative element (not important)
decorativeView.importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO

// Announce dynamic change
view.announceForAccessibility("3 items added to cart, total is $45.99")

// Live region (announces updates; polite = doesn't interrupt)
statusView.accessibilityLiveRegion = View.ACCESSIBILITY_LIVE_REGION_POLITE

// Set accessibility delegate (for complex views)
view.setAccessibilityDelegate(object : AccessibilityDelegate() {
  override fun onInitializeAccessibilityNodeInfo(
    host: View,
    info: AccessibilityNodeInfo
  ) {
    super.onInitializeAccessibilityNodeInfo(host, info)
    info.text = "Custom accessible description"
    info.isClickable = true
  }
})
```

#### Android 14+ Enhancements
- **Predictive Back Gesture:** Ensure back navigation works with system gesture and back button; set OnBackPressedCallback
- **Per-App Language:** If app supports multiple languages, respect system language override via AppCompatDelegate
- **Partial Screen Gesture Navigation:** Don't use edge-swipe for app functionality (conflicts with system back gesture)

### Responsive Web on Mobile

```html
<!-- Viewport (no user-scalable=no) -->
<meta name="viewport" content="width=device-width, initial-scale=1">

<!-- Input types for correct keyboards -->
<input type="email" autocomplete="email">
<input type="tel" autocomplete="tel">
<input type="url" autocomplete="url">
<input type="search">
<input type="tel" inputmode="numeric" autocomplete="tel"> <!-- numeric keyboard -->

<!-- Ensure form submit accessible without keyboard dismissal -->
<button type="submit" style="position: sticky; bottom: 0; width: 100%;">Submit</button>

<!-- Remove tap delay, enable pinch-zoom -->
html { touch-action: manipulation; }

<!-- Adequate touch targets -->
button, a, input[type="checkbox"], input[type="radio"] {
  min-height: 44px;
  min-width: 44px;
  padding: 8px;
}

<!-- No hover-only interactions -->
@media (hover: hover) {
  /* Hover effects only on devices that support hover */
  button:hover { background: blue; }
}
/* Touch devices automatically get :focus and :focus-visible styles */
```

### Wearable & Tablet Considerations

#### Wearable (Smartwatch, ~240px)
- Minimum touch target: 40×40px (smaller screens, less space)
- Avoid complex gestures (harder to perform reliably)
- Information scent critical (single-glance readability)
- No virtual keyboard entry; use voice input or pre-set choices
- Text: ≥16px for 40-inch viewing distance
- Color contrast: even stricter in outdoor light

#### Tablet (iPad, Android Tablet)
- Landscape use common; test both orientations equally
- Keyboard attachment scenario (on-screen keyboard may not always be present)
- Split view multitasking (web app may share half the screen; test at 50vw)
- External keyboard common; ensure full keyboard navigation (Tab, arrow keys, Enter)
- Touch targets can be slightly smaller (better fine motor on larger screen) but default to 44×44px
- Audio output may be through speakers; always provide captions

---

## Output Format

```
## Mobile & Touch Accessibility Audit

**Product:** [name]
**Platform:** [iOS 17+ / Android 14+ / Responsive Web / PWA / Wearable / Tablet / All]
**Standards:** WCAG 2.2 AA/AAA, iOS Human Interface Guidelines, Material Design for Accessibility
**Test Date:** [date]
**Tested By:** [name]

### Accessibility Score Summary
| Dimension | Score (0–10) | Status | Notes |
|-----------|-------------|--------|-------|
| Touch Target Size | 8 | Good | Most targets 44×44px; 2 buttons need spacing |
| Gesture Accessibility | 9 | Excellent | All swipes have tap alternatives |
| Orientation & Responsive | 7 | Good | Landscape works but map crops; 320px reflows correctly |
| AT Compatibility | 6 | Fair | VoiceOver labels complete; TalkBack missing on 3 custom elements |
| Virtual Keyboard & Input | 9 | Excellent | Input types correct; submit always visible |
| **Overall** | **7.8** | **Good** | Ready for release; schedule fix for AT labels in next sprint |

### Touch Target Audit
| Element | Measured Size | Requirement | Status | Issue |
|---------|--------------|-------------|--------|-------|
| Navigation tabs (5) | 44×44px | 44×44px | ✓ | — |
| Close button | 32×32px + 6px padding | 44×44px | ✓ | Adequate spacing to next element |
| Inline delete link | 28×20px | 44×44px | ✗ | Too small; no spacing buffer |
| Pagination | 36×36px | 44×44px | ⚠ | Acceptable with 6px gap; could be larger |

**High-Risk Patterns Identified:**
- Inline text links in article body (28px tall, no tap zone)
- Tab bar with 5 items (each 44px; 4-item bar recommended)
- Floating action button over form input (may obscure on small screens)

### Gesture Inventory
| Gesture | Type | Primary? | Alternative Provided | Status | Notes |
|---------|------|----------|----------------------|--------|-------|
| Swipe delete (table rows) | Multi-touch | No | Delete context menu | ✓ | — |
| Pinch to zoom (map) | Multi-touch | No | Zoom ±buttons | ✓ | — |
| Shake to undo | Motion | No | Undo button in menu | ✓ | Disableable in settings |
| Long-press for context menu | Path | Yes | No alternative | ✗ | **P0: Add button or right-click (web) alternative** |
| Pull to refresh | Multi-touch | Yes | Refresh button available | ✓ | Button not discoverable; add to header |

### AT Testing Results

#### iOS VoiceOver
| Flow | Elements Tested | Findings |
|------|-----------------|----------|
| Signup | Email field, password field, submit button, error state | ✓ All labels announced; password field correctly masked; error message announced with alert role |
| Cart | Item count badge, quantity selector, delete button | ⚠ Badge announces "3 new items" (aria-live=polite on wrong element); delete button says "delete" instead of "delete red backpack" |
| Checkout | Address form fields, state select, payment method, submit | ✓ Form structure clear; legend and fieldset work; custom select behaves like native |

#### Android TalkBack
| Flow | Elements Tested | Findings |
|------|-----------------|----------|
| Signup | Email field, password field, submit button, error state | ✓ Labels correct; password masked; error announced as alert |
| Cart | Item count badge, quantity selector, delete button | ✗ Custom quantity control (up/down buttons) not grouped; announces separately instead of "quantity 3" |
| Checkout | Address form, state select, payment, submit | ⚠ State select contentDescription missing; announces as unlabeled clickable; workaround: select is accessible but not obvious |

### Orientation & Responsive Testing

**Portrait (375px, 667px):**
- ✓ All content visible; no horizontal scroll
- ✓ Form fields stack vertically
- ✓ Navigation: hamburger menu expands to full-width list
- ⚠ Map in article crops to 320px width; less useful at that size

**Landscape (667px, 375px):**
- ⚠ Map view crops left/right; controls remain accessible
- ✗ Payment form has fixed-height inputs; keyboard obscures submit button
- ✓ Video player switches to full-width; controls visible

**320px Reflow (WCAG 1.4.10):**
- ✓ No horizontal scroll
- ✓ Text readable at 100% zoom
- ✓ All buttons tappable

### Virtual Keyboard Impact

| Input | Type | Keyboard Appears | Submit Button Visible | Form Scrolls | Status |
|-------|------|------------------|-----------------------|--------------|--------|
| Email | email | Email keyboard | ✓ Sticky bottom | ✓ Input scrolls above | ✓ Good |
| Phone | tel | Numeric pad | ✗ Hidden | ✓ Input scrolls | ✗ P1: Sticky position for submit |
| Password | password | Standard + suggestions | ✓ Visible (sticky) | ✓ | ✓ Good |
| Address | text | Standard | ✗ Hidden | ✓ Input scrolls | ✗ P1: Make submit sticky or full-width button |

### PWA Considerations (if applicable)
- ✓ Offline mode displays banner with text: "You are offline"
- ✓ Sync status announced via live region: "Syncing 3 items…" / "Synced"
- ✓ Installation prompt offers modal dialog (not gesture-only)
- ⚠ App shortcuts not labeled (only in manifest, not announced)

### Issues by Severity

#### P0 (Blocks Task Completion)
1. **Long-press context menu has no alternative** (Gesture Accessibility)
   - Impact: Users unable to delete, edit, or perform actions without knowing to long-press
   - Fix: Add action button to card or implement right-click menu (web) / context menu (native)
   - Criterion: WCAG 2.5.1 (Pointer Gestures)

2. **Custom quantity selector not grouped in TalkBack**
   - Impact: TalkBack user hears "increase quantity button, decrease quantity button" instead of "quantity, 3, can be adjusted"
   - Fix: Set importantForAccessibility = false on container; create custom AccessibilityDelegate that treats +/− buttons as single control
   - Criterion: WCAG 4.1.3 (Name, Role, Value)

#### P1 (Significantly Degrades Experience)
1. **Submit button hidden by virtual keyboard**
   - Impact: User must dismiss keyboard to see/tap submit; workflow friction
   - Fix: position: sticky; bottom: 0; or full-width button that remains visible
   - Criterion: WCAG 2.5.8 (Target Size) + general UX

2. **Delete button label lacks context**
   - Impact: VoiceOver user knows action is "delete" but not what's being deleted
   - Fix: aria-label="Delete red backpack from cart" or accessibilityLabel in native code
   - Criterion: WCAG 4.1.3 (Name, Role, Value)

3. **Map crops at landscape; less usable**
   - Impact: Landscape users see partial map; orientation-specific workaround
   - Fix: Reflow layout or implement pinch-zoom alternative (buttons) at landscape breakpoint
   - Criterion: WCAG 1.3.4 (Orientation)

#### P2 (Minor Degradation)
1. **App shortcut names not accessible**
   - Impact: Only icon visible; no text label for shortcuts
   - Fix: Ensure manifest shortcut labels are provided and used

2. **Badge announces "new items" but not total quantity**
   - Impact: User doesn't get full context of cart size on-demand
   - Fix: Badge text should say "3 items in cart"

### Platform-Specific Code Fixes

**iOS VoiceOver — Cart Delete Button:**
```swift
deleteButton.accessibilityLabel = "Delete red backpack"
deleteButton.accessibilityHint = "Double-tap to remove item from cart"
```

**Android TalkBack — Quantity Selector (Kotlin):**
```kotlin
// Container holds + button, number, − button
quantityContainer.apply {
  isAccessibilityElement = false
  shouldGroupAccessibilityChildren = true
}

// Or use custom delegate:
quantityContainer.setAccessibilityDelegate(object : AccessibilityDelegate() {
  override fun onInitializeAccessibilityNodeInfo(host: View, info: AccessibilityNodeInfo) {
    super.onInitializeAccessibilityNodeInfo(host, info)
    info.text = "Quantity: $currentQuantity"
    info.contentDescription = "Quantity: $currentQuantity. Double tap to adjust."
    // Add actions: increaseQuantity, decreaseQuantity
  }
})
```

**CSS — Sticky Submit Button + Keyboard:**
```css
form {
  display: flex;
  flex-direction: column;
}

input, textarea {
  flex: 1;
}

button[type="submit"] {
  position: sticky;
  bottom: 0;
  padding: 16px;
  width: 100%;
  margin-top: 8px;
  z-index: 10;
}

/* Ensure keyboard doesn't completely hide it */
@supports (padding: max(0px)) {
  button[type="submit"] {
    padding-bottom: max(16px, env(safe-area-inset-bottom));
  }
}
```

**Web Form — Input Type Optimization:**
```html
<input type="email" autocomplete="email" inputmode="email">
<input type="tel" autocomplete="tel" inputmode="tel">
<input type="text" inputmode="numeric" autocomplete="postal-code">
<input type="url" autocomplete="url" inputmode="url">
```

### Recommended Mobile AT Test Cases

#### VoiceOver on iOS Test Script
1. **Signup flow:**
   - Enable VoiceOver (Settings > Accessibility > VoiceOver > Toggle On)
   - Swipe right to navigate through email input, password input, submit button
   - Tap email field; swipe down to hear hint (if present)
   - Dismiss keyboard with two-finger Z scrub
   - Navigate to submit; double-tap to submit
   - Verify error message announced as alert

2. **Cart deletion:**
   - Navigate to item in cart
   - Long-press does not work; look for delete alternative
   - Find and use delete button/menu
   - Verify delete announcement (item name + removal confirmation)

#### TalkBack on Android Test Script
1. **Signup flow:**
   - Enable TalkBack (Volume Up + Down for 3 seconds)
   - Swipe right to navigate through form
   - Double-tap email field
   - Type with keyboard
   - Back gesture to close keyboard
   - Navigate to submit; double-tap to submit
   - Verify error announced and field focused

2. **Quantity adjustment:**
   - Find item with quantity selector (+ and − buttons)
   - Tap to focus
   - Verify announcement includes "quantity" and current number
   - Explore if buttons are grouped or separate
   - Adjust quantity; verify change announced

---

## Cross-References

- **keyboard-focus-auditor:** Test tab order and keyboard navigation on responsive web
- **cognitive-accessibility:** Audit information density and simplify navigation for users with cognitive disabilities on mobile
- **screen-reader-scripting:** Write detailed VoiceOver and TalkBack test scripts for QA handoff
- **accessible-forms:** Focus on mobile input types, virtual keyboard, and form label positioning
- **accessibility-code:** Native Swift/Kotlin implementation of accessibility APIs
- **motion-auditor:** Audit shake, tilt, and other motion-based interactions for alternatives
