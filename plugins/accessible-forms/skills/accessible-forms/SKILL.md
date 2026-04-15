---
name: accessible-forms
description: Design, code, and audit accessible forms — including input labels, validation, error recovery, multi-step flows, autofill, input modes, date pickers, payment forms, and assistive technology compatibility. Use this skill whenever the user is building or reviewing any form, input, field, data entry UI, checkout, or form-based interaction. Trigger on phrases like "accessible form", "form validation", "error message", "required field", "input label", "multi-step form", "form accessibility", "autofill", "date picker", "address form", "payment form", "form UX for screen readers", "checkout flow", or any request involving checkboxes, radio buttons, selects, date pickers, file uploads, or password fields. Covers WCAG 2.2 AAA, Section 508, ARIA APG form patterns, real assistive technology behavior, and form maturity scoring.
---

# Accessible Forms Specialist

Forms are where accessibility failures cause the most direct harm — blocked registrations, failed checkouts, inaccessible medical intake, lost job applications. Every field is a decision with accessibility consequences.

## Foundational Rules

1. Every input has a persistent visible label — not a placeholder, not a tooltip, not an aria-label alone.
2. Labels are positioned above inputs, not beside them (supports zoom, reflow, and screen magnification).
3. Required fields are marked with text or a symbol with a legend — never color alone.
4. Error messages name the field, describe the problem, and tell the user how to fix it.
5. Instructions appear before the fields they describe, not after.
6. Form section structure is clear via fieldset/legend for grouped inputs.
7. Multi-step forms announce current step and allow back navigation without data loss.

---

## Form Accessibility Maturity Scoring (0–10)

### 1. Label & Association (0–10)
- **10:** All inputs have visible, persistent labels; labels properly associated (for/id); above input; clear and concise
- **8:** All inputs labeled; 1–2 labels use aria-label instead of visible text; labels in correct position
- **6:** Most inputs labeled; some labels missing or implicitly associated (inside label wrapper); positioning inconsistent
- **4:** Many unlabeled inputs; placeholder used as label; labels associated inconsistently
- **2:** Few labels; most relying on placeholder or tooltip
- **0:** No visible labels; inputs unlabeled

### 2. Required Field Indication (0–10)
- **10:** Required fields marked with text legend and asterisk (or other symbol) explained at form top; aria-required set
- **8:** Required fields marked; symbol explained or text clearly states "required"
- **6:** Some required fields marked; marking inconsistent or not explained
- **4:** Required fields not marked; user discovers via validation error
- **2:** Partial marking; legend missing or unclear
- **0:** No indication; user has no way to know field is required until error

### 3. Validation & Error Handling (0–10)
- **10:** Real-time feedback on blur (not on input); comprehensive error messages with fix suggestions; focus moved to first error on submit
- **8:** Validation on blur; error messages identify field and problem; error summary present
- **6:** Validation timing mixed; some error messages lack fix suggestions; error focus management incomplete
- **4:** Validation only on submit; error messages generic or unclear
- **2:** Error messages present but not associated with fields
- **0:** Errors not communicated; silent validation failure

### 4. Input Type & Autofill Optimization (0–10)
- **10:** Correct input types (email, tel, url, number) and autocomplete tokens (email, tel, postal-code, cc-number) for all applicable fields; password managers fully supported
- **8:** Most inputs have correct types; some missing autocomplete tokens
- **6:** Mixed: some correct, some defaulting to text; autocomplete tokens inconsistent
- **4:** Many inputs type="text"; autocomplete tokens missing or incorrect
- **2:** Incorrect input types; no autocomplete tokens
- **0:** All inputs type="text" or generic; no autofill support

### 5. Special Input Accessibility (Date/Address/Payment) (0–10)
- **10:** Native date pickers (or fully accessible custom picker) used; date formats validated flexibly; address form has country/regional support and autocomplete; payment form accessible and PCI-compliant
- **8:** Native or accessible custom date picker; basic address form; payment form labeled and validated
- **6:** Custom date picker partially accessible; address form minimal; payment form labels may be missing
- **4:** Date picker requires specific format; address form broken; payment form not validated
- **2:** Custom date picker not keyboard accessible; address form single field; payment lacks guidance
- **0:** Date entry confusing; address unstructured; payment form inaccessible

### 6. Multi-Step Form Structure (0–10)
- **10:** Clear step indicator (page title, nav, progress bar); step announced on each page; data persists; back navigation works; review/confirm step before submit
- **8:** Steps indicated; data persists; back navigation works; review step present
- **6:** Steps indicated but unclear; back navigation works; data may be lost; review optional
- **4:** Steps not clearly indicated; data may be lost on back; no review step
- **2:** Multi-step confusing; frequent data loss; no review
- **0:** Multi-step not structured; data loss common

### 7. Keyboard Navigation (0–10)
- **10:** Full keyboard navigation via Tab; focus visible and logical; all buttons/links reachable; form submittable via Enter; no keyboard traps
- **8:** Tab navigation works; focus mostly visible; 1–2 elements hard to reach; can submit with Enter
- **6:** Tab navigation works but order is illogical; focus visibility inconsistent; some elements unreachable without mouse
- **4:** Tab navigation jumps around; focus invisible in some areas; many elements inaccessible via keyboard
- **2:** Tab navigation works but highly disruptive; focus not visible
- **0:** Not keyboard navigable; keyboard traps present

---

## Process

### Phase 1: Analyze Form Structure
1. Identify form type: simple (single page), multi-step, modal, embedded
2. List all input groups: contact, billing, payment, preferences, etc.
3. Note required vs optional fields
4. Identify special input types: date, address, phone, payment, file upload

### Phase 2: Label & Association Audit
1. Verify each input has a visible `<label>` or accessible name
2. Check label text is clear and descriptive
3. Verify explicit association (for/id) for all labels
4. Score Label & Association dimension
5. Document any implicitly labeled or missing labels

### Phase 3: Validation & Error Audit
1. Test each field with invalid input
2. Record when validation fires (on input, blur, submit)
3. Document error message clarity and association to field
4. Test error recovery flow (can user fix and resubmit?)
5. Score Validation & Error Handling dimension

### Phase 4: Input Type & Autofill Audit
1. Test each input type against appropriate device keyboard
2. Verify correct input type (email, tel, url, number)
3. Check autocomplete token presence and correctness
4. Test password manager autofill on password field
5. Score Input Type & Autofill dimension

### Phase 5: Special Input Testing
1. **Date picker:** Test native vs custom; test keyboard (if custom); test date format flexibility
2. **Address form:** Test country/region support; test address autocomplete if present
3. **Payment:** Check PCI compliance; verify card type detection; test card validation messaging
4. Score Special Input Accessibility dimension

### Phase 6: Multi-Step Form Testing (if applicable)
1. Verify step indicator visible and updated on each step
2. Navigate backward; verify data persists
3. Verify page title or heading reflects current step
4. Check for review/confirm step before final submission
5. Score Multi-Step Form Structure dimension

### Phase 7: Keyboard & AT Testing
1. Tab through entire form; note order and focus visibility
2. Test form submission with Enter key
3. Test with screen reader (NVDA, JAWS, or VoiceOver)
4. Score Keyboard Navigation dimension

### Phase 8: Scoring & Output
1. Average all dimension scores for overall maturity rating
2. Identify priority fixes (P0, P1, P2)
3. Provide code examples for each issue

---

## Reference Guide

### Labels & Required Fields

```html
<!-- CORRECT: Persistent visible label above input -->
<label for="email">Email address</label>
<input type="email" id="email" name="email" required aria-required="true">

<!-- CORRECT: Required field indicator with legend -->
<p style="margin-bottom: 1rem;">
  Fields marked with <span aria-hidden="true">*</span> are required.
</p>

<label for="name">
  Full name
  <span aria-hidden="true">*</span>
  <span class="sr-only">(required)</span>
</label>
<input type="text" id="name" name="name" required aria-required="true">

<!-- WRONG: Placeholder as label -->
<input type="email" placeholder="Email address"> <!-- fails: placeholder disappears on input -->

<!-- WRONG: aria-label only, no visible label -->
<input type="email" aria-label="Email address"> <!-- fails: sighted users see no label -->
```

### Input Types & Autocomplete (WCAG 1.3.5)

```html
<!-- Contact info -->
<label for="fname">First name</label>
<input type="text" id="fname" autocomplete="given-name">

<label for="lname">Last name</label>
<input type="text" id="lname" autocomplete="family-name">

<label for="email">Email</label>
<input type="email" id="email" autocomplete="email">

<label for="phone">Phone</label>
<input type="tel" id="phone" autocomplete="tel">

<!-- Address -->
<label for="street">Street address</label>
<input type="text" id="street" autocomplete="street-address">

<label for="city">City</label>
<input type="text" id="city" autocomplete="address-level2">

<label for="state">State</label>
<input type="text" id="state" autocomplete="address-level1">

<label for="zip">Zip code</label>
<input type="text" id="zip" autocomplete="postal-code">

<!-- Payment -->
<label for="card">Card number</label>
<input type="text" id="card" inputmode="numeric" autocomplete="cc-number" maxlength="19">

<label for="expiry">Expiration date</label>
<input type="text" id="expiry" placeholder="MM/YY" autocomplete="cc-exp">

<label for="cvc">Security code</label>
<input type="text" id="cvc" inputmode="numeric" autocomplete="cc-csc" maxlength="4">

<!-- Other -->
<label for="dob">Date of birth</label>
<input type="date" id="dob" autocomplete="bday">

<label for="username">Username</label>
<input type="text" id="username" autocomplete="username">

<label for="password">Password</label>
<input type="password" id="password" autocomplete="current-password">

<label for="new-password">New password</label>
<input type="password" id="new-password" autocomplete="new-password">
```

### Validation & Error Messages

```html
<!-- Validation on blur (not on input) -->
<label for="email">Email address</label>
<input
  type="email"
  id="email"
  name="email"
  required
  aria-required="true"
  aria-describedby="email-error"
  aria-invalid="false"
>
<p id="email-error" role="alert" style="color: red; display: none;">
  Email address must include an @ symbol. Example: name@domain.com
</p>

<script>
document.getElementById('email').addEventListener('blur', function() {
  const isValid = this.value.includes('@');
  this.setAttribute('aria-invalid', isValid ? 'false' : 'true');
  document.getElementById('email-error').style.display = isValid ? 'none' : 'block';
});
</script>

<!-- Error summary for multi-field forms -->
<div id="error-summary" role="alert" aria-labelledby="error-heading" tabindex="-1" style="display: none; border: 2px solid red; padding: 1rem; margin-bottom: 1rem;">
  <h2 id="error-heading">Errors in your form</h2>
  <ul>
    <li><a href="#email">Email address — must include an @ symbol</a></li>
    <li><a href="#phone">Phone number — must be 10 digits</a></li>
  </ul>
</div>

<script>
// Move focus to error summary on submit
form.addEventListener('submit', function(e) {
  const hasErrors = /* check for validation errors */;
  if (hasErrors) {
    e.preventDefault();
    const summary = document.getElementById('error-summary');
    summary.style.display = 'block';
    summary.focus();
  }
});
</script>
```

### Grouped Inputs (Fieldset & Legend)

```html
<!-- Radio buttons -->
<fieldset>
  <legend>
    Preferred contact method
    <span aria-hidden="true">*</span>
    <span class="sr-only">(required)</span>
  </legend>
  <label>
    <input type="radio" name="contact" value="email" required>
    Email
  </label>
  <label>
    <input type="radio" name="contact" value="phone" required>
    Phone
  </label>
  <label>
    <input type="radio" name="contact" value="text" required>
    Text message
  </label>
</fieldset>

<!-- Checkboxes -->
<fieldset>
  <legend>
    What devices do you use?
    <span aria-hidden="true">*</span>
    <span class="sr-only">(required)</span>
  </legend>
  <label>
    <input type="checkbox" name="devices" value="phone" required>
    Phone
  </label>
  <label>
    <input type="checkbox" name="devices" value="tablet" required>
    Tablet
  </label>
  <label>
    <input type="checkbox" name="devices" value="desktop" required>
    Desktop
  </label>
</fieldset>

<!-- Billing vs Shipping -->
<fieldset>
  <legend>Billing address</legend>
  <label for="bill-street">Street</label>
  <input type="text" id="bill-street" autocomplete="billing street-address">
  <!-- more billing fields -->
</fieldset>

<fieldset>
  <legend>Shipping address</legend>
  <label>
    <input type="checkbox" name="same-shipping"> Same as billing
  </label>
  <label for="ship-street">Street</label>
  <input type="text" id="ship-street" autocomplete="shipping street-address">
  <!-- more shipping fields -->
</fieldset>
```

### Date Picker Patterns

**Native HTML5 date input (preferred):**
```html
<label for="dob">Date of birth</label>
<input type="date" id="dob" autocomplete="bday">
```

**Flexible date format input (when native picker not acceptable):**
```html
<label for="dob">Date of birth</label>
<input
  type="text"
  id="dob"
  name="dob"
  placeholder="MM/DD/YYYY"
  aria-describedby="dob-format"
  maxlength="10"
  inputmode="numeric"
>
<p id="dob-format" class="hint">Format: MM/DD/YYYY. You can also type just digits.</p>

<script>
// Allow flexible input: user types "1234567" and convert to "12/34/567" as they type
// Validate format on blur
document.getElementById('dob').addEventListener('blur', function() {
  const val = this.value.replace(/\D/g, '');
  if (val.length === 8) {
    const formatted = val.slice(0, 2) + '/' + val.slice(2, 4) + '/' + val.slice(4);
    this.value = formatted;
  }
  // Validate date range
  const date = new Date(val.slice(4) + '-' + val.slice(0, 2) + '-' + val.slice(2, 4));
  // age validation...
});
</script>
```

**Custom accessible date picker (following ARIA APG pattern):**
```html
<label for="dob-button">Date of birth</label>
<div class="date-picker">
  <input
    type="text"
    id="dob-button"
    readonly
    value="03/15/1990"
    aria-haspopup="dialog"
    aria-label="Date of birth, 03/15/1990"
  >
  <button aria-label="Open date picker">🗓</button>
</div>

<!-- Dialog opened on button click; includes month/year navigation, calendar grid with keyboard support -->
<dialog role="dialog" aria-labelledby="dialog-title">
  <h2 id="dialog-title">Select your date of birth</h2>
  <!-- calendar implementation with arrow key navigation -->
</dialog>
```

### Address Form Internationalization

```html
<!-- US/Canada -->
<label for="country">Country</label>
<select id="country" onchange="updateAddressFields()">
  <option value="US">United States</option>
  <option value="CA">Canada</option>
  <option value="GB">United Kingdom</option>
  <option value="Other">Other</option>
</select>

<!-- US-specific fields -->
<label for="state">State</label>
<select id="state" autocomplete="address-level1">
  <option>Select a state</option>
  <option value="AL">Alabama</option>
  <!-- ... -->
</select>

<label for="zip">ZIP code</label>
<input type="text" id="zip" autocomplete="postal-code" pattern="[0-9]{5}(-[0-9]{4})?">

<!-- Canada-specific fields -->
<label for="province">Province</label>
<select id="province" autocomplete="address-level1" style="display: none;">
  <option>Select a province</option>
  <option value="AB">Alberta</option>
  <!-- ... -->
</select>

<label for="postal">Postal code</label>
<input type="text" id="postal" autocomplete="postal-code" pattern="[A-Z][0-9][A-Z] ?[0-9][A-Z][0-9]" style="display: none;">
```

### Payment Form (PCI + Accessibility)

```html
<!-- Never store card data; use Stripe, PayPal, etc. -->
<!-- Form labeled clearly -->
<fieldset>
  <legend>Payment information</legend>

  <label for="cardholder">Cardholder name</label>
  <input
    type="text"
    id="cardholder"
    autocomplete="cc-name"
    aria-describedby="cardholder-format"
  >
  <p id="cardholder-format" class="hint">As shown on card</p>

  <label for="card">Card number</label>
  <input
    type="text"
    id="card"
    inputmode="numeric"
    autocomplete="cc-number"
    placeholder="1234 5678 9012 3456"
    maxlength="19"
    aria-describedby="card-format"
  >
  <p id="card-format" class="hint">Visa, Mastercard, American Express accepted</p>

  <label for="expiry">Expiration date</label>
  <input
    type="text"
    id="expiry"
    placeholder="MM/YY"
    maxlength="5"
    autocomplete="cc-exp"
    aria-describedby="expiry-format"
  >
  <p id="expiry-format" class="hint">MM/YY format</p>

  <label for="cvc">Security code (CVV)</label>
  <input
    type="text"
    id="cvc"
    inputmode="numeric"
    placeholder="123"
    maxlength="4"
    autocomplete="cc-csc"
    aria-describedby="cvc-format"
  >
  <p id="cvc-format" class="hint">3 or 4 digits on back of card</p>
</fieldset>

<!-- Format hints above inputs, visible to all users -->
<!-- No error on incomplete format; only validate on blur -->
<!-- Real-time card type detection announced -->
<div role="status" aria-live="polite" aria-atomic="true" id="card-type"></div>

<script>
// Detect card type and announce
document.getElementById('card').addEventListener('input', function() {
  const cardType = detectCardType(this.value);
  document.getElementById('card-type').textContent = cardType; // e.g., "Visa"
});

function detectCardType(num) {
  if (/^4/.test(num)) return 'Visa';
  if (/^5[1-5]/.test(num)) return 'Mastercard';
  if (/^3[47]/.test(num)) return 'American Express';
  return '';
}
</script>
```

### Multi-Step Form Example

```html
<!-- Step indicator (visible and announced) -->
<nav aria-label="Checkout progress">
  <ol>
    <li aria-current="step">Cart</li>
    <li>Shipping</li>
    <li>Payment</li>
    <li>Confirm</li>
  </ol>
</nav>

<h1>Step 1 of 4: Cart</h1>

<!-- Form continues; on submit, advance to next step -->
<button type="submit">Continue to shipping</button>

<!-- JavaScript on submit -->
<script>
form.addEventListener('submit', function(e) {
  e.preventDefault();
  // Validate current step
  if (currentStepIsValid()) {
    // Save data
    saveStepData();
    // Move to next step
    currentStep++;
    updatePageTitle(); // "Step 2 of 4: Shipping"
    updateStepIndicator();
    loadStepContent();
    // Move focus to next step's heading
    document.querySelector('h1').focus(); // h1 has tabindex="-1"
  } else {
    // Show errors
  }
});

// Allow back navigation
backButton.addEventListener('click', function() {
  currentStep--;
  updatePageTitle();
  updateStepIndicator();
  loadStepContent();
  document.querySelector('h1').focus();
  // Data persists
});
</script>

<!-- Final step: Review before submit -->
<h1>Step 4 of 4: Confirm order</h1>
<h2>Order summary</h2>
<dl>
  <dt>Items:</dt>
  <dd><!-- list items --></dd>
  <dt>Shipping address:</dt>
  <dd><!-- address --></dd>
  <dt>Shipping method:</dt>
  <dd><!-- method --></dd>
  <dt>Total:</dt>
  <dd>$XX.XX</dd>
</dl>
<button type="submit">Place order</button>
<button type="button" onclick="currentStep--; goBack();">Edit information</button>
```

---

## Output Format

```
## Form Accessibility Audit

**Form:** [name]
**Type:** [Simple / Multi-step / Modal / Embedded]
**Testing Date:** [date]
**Tested By:** [name]

### Maturity Score Summary
| Dimension | Score (0–10) | Status | Notes |
|-----------|-------------|--------|-------|
| Label & Association | 8 | Good | All inputs labeled; 1 missing required marker explanation |
| Required Field Indication | 7 | Good | Most marked; legend could be more prominent |
| Validation & Error Handling | 6 | Fair | Validation on blur; error messages need improvement |
| Input Type & Autofill | 9 | Excellent | All correct types; autocomplete tokens complete |
| Special Inputs (Date/Address/Payment) | 8 | Good | Native date picker used; address form complete; payment clear |
| Multi-Step Structure | N/A | — | Single-page form |
| Keyboard Navigation | 9 | Excellent | Full keyboard access; logical tab order; focus visible |
| **Overall** | **7.9** | **Good** | Release ready; improve error messaging in next iteration |

### Field-by-Field Summary
| Field | Type | Label | Required | Validation | Error Message | Status |
|-------|------|-------|----------|------------|---------------|--------|
| Email | email | ✓ | ✓ | on blur | "must include @" | ✓ |
| Phone | tel | ✓ | ✓ | on blur | "10 digits" | ✓ |
| Address | text | ✓ | ✓ | on blur | generic | ⚠ |
| State | select | ✓ | ✗ | — | — | ✗ |

### Issues by Severity

#### P0 (Blocks Submission)
[High-priority accessibility blocker issues]

#### P1 (Significantly Degrades Experience)
[Important issues that harm usability]

#### P2 (Minor Issues)
[Small refinements that would improve experience]

### Recommended Code Fixes
[Specific HTML, CSS, JavaScript examples for each issue]
```

---

## Cross-References

- **accessibility-code:** Implement native HTML and ARIA patterns
- **keyboard-focus-auditor:** Audit and document form tab order and focus management
- **cognitive-accessibility:** Simplify form language and reduce cognitive load
- **accessible-copy:** Write clear labels, error messages, and instructions
- **mobile-touch-auditor:** Test form on touch devices; ensure input types trigger correct keyboards
- **screen-reader-scripting:** Write form test scripts for NVDA, JAWS, VoiceOver

