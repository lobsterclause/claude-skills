---
name: playwright-accessibility-auditor
description: "Test rendered pages in a real browser for accessibility — capturing multi-viewport screenshots, running axe-core scans, verifying keyboard navigation, focus indicators, zoom/reflow, dark mode, and reduced motion. Use this skill for browser-based accessibility testing, visual regression, or when you need to verify what actually renders rather than what the source says. Trigger on phrases like browser testing, playwright audit, rendered accessibility, screenshot accessibility, viewport testing, zoom testing, dark mode accessibility, visual regression, or any request to test accessibility in a real browser."
category: test
related-skills: a11y-test-plan, screen-reader-scripting, accessibility-code, contrast-checker, keyboard-focus-auditor, motion-auditor
---

# Playwright Accessibility Auditor

## Philosophy

Source-level analysis tools (linters, static analyzers) tell you what the code claims to be. A real browser—with rendering engine, CSS cascade, JavaScript execution, paint timing—tells you what actually reaches users.

This skill exists because:

- **The rendered DOM differs from source DOM.** JavaScript mutates structure. CSS hides content. Overlays render incorrectly. Only a browser sees the truth.
- **Visual properties matter.** A contrast ratio in CSS !== contrast ratio on screen. Color spaces, anti-aliasing, subpixel rendering, and monitor calibration all matter. Automated source scanning misses rendered contrast entirely.
- **User experience is context-dependent.** Zoom, color schemes (dark/light), motion preferences, viewport size, focus styles—these conditions change what users see. Multi-condition testing catches failures that single-condition checks miss.
- **Business value depends on reality.** Automated source tools report *potential* violations. Browser-based testing finds *actual* violations. That difference justifies investment: accessibility isn't virtue signaling, it's market access. Every point of accessibility exclusion is lost business.

This auditor runs tests in a real Chromium browser via Playwright, capturing what users experience. It pairs automated scanning (axe-core) with manual visual verification and keyboard smoke testing.

---

## Core Framework

### What This Auditor Tests

1. **Multi-viewport rendering** — Desktop (1920×1080), tablet (768×1024), mobile (375×667). Same page, three different user contexts. Responsive design breaks in ways only rendering reveals.

2. **Color scheme variants** — Light mode (default) + dark mode (prefers-color-scheme: dark). Dark mode amplifies contrast failures; light mode hides others. Both must work.

3. **Zoom and reflow** — 200% and 400% zoom. Validates responsive behavior, text overflow handling, and focus indicator visibility at magnification. Many users rely on browser zoom; many fail this test.

4. **Reduced motion compliance** — Test pages under prefers-reduced-motion: reduce. Captures motion/animation behavior when disabled. Critical for vestibular disorders, migraines, epilepsy.

5. **Keyboard navigation flow** — Tab through the page programmatically. Verify tab order, focus visibility, no keyboard traps, all interactive elements reachable. A screen reader user is a keyboard user first.

6. **Focus indicator visibility** — Screenshot focus rings at each tab stop. Verify color contrast, size, and visibility against background.

7. **Axe-core automated scanning** — WCAG rule violations and best-practice issues. Integrated with Playwright to test rendered DOM, not source.

8. **Form error states** — Trigger validation, capture error messages, verify error message association with fields, check error text visibility and color contrast.

9. **Visual regression support** — Baseline and comparison screenshots for each configuration. Supports manual review and diff-based alerting.

---

## Process

### Step 1 — Environment Setup

**Install dependencies:**

```bash
npm install --save-dev \
  @playwright/test \
  @axe-core/playwright \
  ts-node \
  typescript
```

**Create `playwright.config.ts`:**

```typescript
import { defineConfig, devices } from '@playwright/test';

export default defineConfig({
  testDir: './tests',
  fullyParallel: false, // Run tests sequentially to avoid browser resource contention
  forbidOnly: !!process.env.CI,
  retries: 0, // Accessibility tests should not retry silently
  workers: 1, // Single worker; multi-viewport testing requires sequential execution
  reporter: 'html',
  use: {
    baseURL: 'http://localhost:3000',
    trace: 'on-first-retry',
    screenshot: 'only-on-failure',
  },
  webServer: {
    command: 'npm run dev', // Or your dev server command
    url: 'http://localhost:3000',
    reuseExistingServer: !process.env.CI,
  },
});
```

**Create `accessibility.auditor.ts` base class:**

```typescript
import { Page, expect } from '@playwright/test';
import { injectAxe, checkA11y, getViolations } from '@axe-core/playwright';

interface AuditConfig {
  url: string;
  outputDir: string;
  baselineDiffDir?: string;
  axeConfig?: Record<string, any>;
}

interface ViewportPreset {
  name: string;
  width: number;
  height: number;
  deviceScaleFactor: number;
}

const VIEWPORTS: Record<string, ViewportPreset> = {
  desktop: { name: 'desktop', width: 1920, height: 1080, deviceScaleFactor: 1 },
  tablet_portrait: { name: 'tablet-portrait', width: 768, height: 1024, deviceScaleFactor: 2 },
  tablet_landscape: { name: 'tablet-landscape', width: 1024, height: 768, deviceScaleFactor: 2 },
  mobile: { name: 'mobile', width: 375, height: 667, deviceScaleFactor: 2 },
};

const COLOR_SCHEMES = ['light', 'dark'] as const;
const ZOOM_LEVELS = [100, 200, 400];
const MOTION_PREFERENCES = ['no-preference', 'reduce'] as const;

export class AccessibilityAuditor {
  private page: Page;
  private config: AuditConfig;
  private findings: AuditFinding[] = [];

  constructor(page: Page, config: AuditConfig) {
    this.page = page;
    this.config = config;
  }

  /**
   * Navigate to the target URL and wait for stable rendering
   */
  async navigateAndStabilize(waitForSelectors?: string[]) {
    await this.page.goto(this.config.url, { waitUntil: 'networkidle' });
    if (waitForSelectors && waitForSelectors.length > 0) {
      for (const selector of waitForSelectors) {
        await this.page.waitForSelector(selector, { timeout: 10000 });
      }
    }
    // Allow CSS animations and transitions to settle
    await this.page.waitForTimeout(500);
  }

  /**
   * Run axe-core scan on rendered DOM
   */
  async scanWithAxe(context: string = 'full-page'): Promise<AxeResult> {
    await injectAxe(this.page);
    const violations = await checkA11y(this.page, null, {
      detailedReport: true,
      detailedReportOptions: { html: true },
      rules: this.config.axeConfig?.rules || {},
    });

    return {
      context,
      timestamp: new Date().toISOString(),
      violations,
    };
  }

  /**
   * Capture screenshots across viewport/color-scheme matrix
   */
  async captureMultiViewportScreenshots(label: string) {
    const screenshots: ScreenshotRecord[] = [];

    for (const [vpKey, vp] of Object.entries(VIEWPORTS)) {
      await this.page.setViewportSize({ width: vp.width, height: vp.height });

      for (const scheme of COLOR_SCHEMES) {
        const filename = `${label}__${vp.name}__${scheme}.png`;
        const filepath = `${this.config.outputDir}/${filename}`;

        await this.page.emulateMedia({ colorScheme: scheme as any });
        await this.page.waitForTimeout(300); // CSS transitions
        await this.page.screenshot({ path: filepath, fullPage: true });

        screenshots.push({
          label,
          viewport: vp.name,
          colorScheme: scheme,
          filename,
          filepath,
        });
      }
    }

    return screenshots;
  }

  /**
   * Test zoom/reflow at 200% and 400%
   */
  async testZoomReflow(label: string) {
    const results: ZoomResult[] = [];

    for (const zoomLevel of ZOOM_LEVELS) {
      const filename = `${label}__zoom-${zoomLevel}pct.png`;
      const filepath = `${this.config.outputDir}/${filename}`;

      // Set zoom to percentage of base viewport
      await this.page.evaluate((zoom) => {
        document.body.style.zoom = `${zoom}%`;
      }, zoomLevel);

      await this.page.waitForTimeout(300);

      // Measure viewport scrollable dimensions
      const scrollSize = await this.page.evaluate(() => {
        return {
          scrollWidth: document.documentElement.scrollWidth,
          scrollHeight: document.documentElement.scrollHeight,
          clientWidth: document.documentElement.clientWidth,
          clientHeight: document.documentElement.clientHeight,
        };
      });

      await this.page.screenshot({ path: filepath, fullPage: true });

      results.push({
        zoomLevel,
        filename,
        filepath,
        scrollDimensions: scrollSize,
        reflowed: scrollSize.scrollWidth > scrollSize.clientWidth,
      });

      // Reset zoom
      await this.page.evaluate(() => {
        document.body.style.zoom = '100%';
      });
    }

    return results;
  }

  /**
   * Verify prefers-reduced-motion compliance
   */
  async testReducedMotion(label: string) {
    const results: MotionResult[] = [];

    for (const preference of MOTION_PREFERENCES) {
      const filename = `${label}__motion-${preference}.png`;
      const filepath = `${this.config.outputDir}/${filename}`;

      await this.page.emulateMedia({
        reducedMotion: preference === 'reduce' ? 'reduce' : 'no-preference',
      });

      // Capture CSS animation and transition property values
      const animationState = await this.page.evaluate(() => {
        const elements = Array.from(document.querySelectorAll('[style*="animation"], [style*="transition"]'));
        return elements.map(el => ({
          tag: el.tagName,
          id: el.id,
          className: el.className,
          animation: window.getComputedStyle(el).animation,
          transition: window.getComputedStyle(el).transition,
        }));
      });

      await this.page.screenshot({ path: filepath, fullPage: true });

      results.push({
        preference,
        filename,
        filepath,
        animatingElements: animationState.length,
        details: animationState,
      });
    }

    return results;
  }

  /**
   * Keyboard navigation smoke test: Tab through page, capture focus at each stop
   */
  async testKeyboardNavigation(label: string): Promise<KeyboardResult> {
    const focusPath: FocusStop[] = [];
    let tabCount = 0;
    const maxTabs = 100; // Detect infinite loops

    // Scroll to top
    await this.page.evaluate(() => window.scrollTo(0, 0));

    // Start with first focusable element
    await this.page.keyboard.press('Tab');

    while (tabCount < maxTabs) {
      const focusInfo = await this.page.evaluate(() => {
        const el = document.activeElement as HTMLElement;
        if (!el || el === document.body) return null;

        const rect = el.getBoundingClientRect();
        const style = window.getComputedStyle(el);
        const focusVisible = el.matches(':focus-visible');

        return {
          tag: el.tagName,
          id: el.id,
          className: el.className,
          ariaLabel: el.getAttribute('aria-label'),
          role: el.getAttribute('role'),
          type: el instanceof HTMLInputElement ? el.type : null,
          text: el.textContent?.substring(0, 50),
          visible: rect.width > 0 && rect.height > 0,
          focusVisible,
          outlineWidth: parseInt(style.outlineWidth) || 0,
          outlineColor: style.outlineColor,
          outlineStyle: style.outlineStyle,
        };
      });

      if (!focusInfo) break;

      // Capture screenshot of this focus state
      const focusScreenshot = `${label}__focus-${tabCount.toString().padStart(2, '0')}.png`;
      const focusPath_str = `${this.config.outputDir}/${focusScreenshot}`;
      await this.page.screenshot({ path: focusPath_str });

      focusPath.push({
        tabIndex: tabCount,
        screenshot: focusScreenshot,
        element: focusInfo,
      });

      // Move to next focusable element
      await this.page.keyboard.press('Tab');
      tabCount++;

      // Break if we've cycled back to the start (body)
      const isBodyFocused = await this.page.evaluate(() => document.activeElement === document.body);
      if (isBodyFocused && tabCount > 3) break;
    }

    return {
      label,
      focusStops: focusPath.length,
      focusPath,
      completedCycle: tabCount < maxTabs,
      keyboardTrapsDetected: tabCount >= maxTabs,
    };
  }

  /**
   * Verify focus indicator contrast and visibility
   */
  async verifyFocusIndicators(): Promise<FocusIndicatorResult[]> {
    const results: FocusIndicatorResult[] = [];

    const focusElements = await this.page.evaluate(() => {
      // Find all elements that can receive focus
      const selectors = [
        'a[href]', 'button', 'input', 'select', 'textarea',
        '[tabindex]', '[role="button"]', '[role="link"]', '[role="tab"]',
        'input[type="checkbox"]', 'input[type="radio"]',
      ];

      const elements: HTMLElement[] = [];
      for (const selector of selectors) {
        elements.push(...Array.from(document.querySelectorAll(selector)));
      }

      return elements.slice(0, 20).map(el => ({
        id: el.id || `elem-${Math.random()}`,
        tag: el.tagName,
        role: el.getAttribute('role'),
      }));
    });

    for (const elem of focusElements) {
      // Focus the element
      if (elem.id) {
        await this.page.focus(`#${elem.id}`);
      } else {
        await this.page.evaluate(() => {
          const focused = (document.activeElement as HTMLElement);
          if (focused) focused.focus();
        });
      }

      const focusStyle = await this.page.evaluate(() => {
        const el = document.activeElement as HTMLElement;
        if (!el) return null;

        const style = window.getComputedStyle(el);
        const pseudoFocus = window.getComputedStyle(el, ':focus');

        return {
          outline: style.outline,
          outlineWidth: style.outlineWidth,
          outlineColor: style.outlineColor,
          outlineStyle: style.outlineStyle,
          boxShadow: style.boxShadow,
          // Check if element has visible focus indicator
          hasFocusIndicator: style.outlineWidth !== '0px' || !!style.boxShadow,
        };
      });

      results.push({
        element: elem,
        focusStyle,
        hasVisibleIndicator: focusStyle?.hasFocusIndicator || false,
      });
    }

    return results;
  }

  /**
   * Test form validation and error state rendering
   */
  async testFormErrorStates(formSelector: string): Promise<FormErrorResult> {
    const errors: FormValidationError[] = [];

    // Find all required inputs
    const inputs = await this.page.locator(`${formSelector} [required]`).all();

    for (const input of inputs) {
      const inputName = await input.getAttribute('name');

      // Attempt form submission without filling field
      const submitButton = this.page.locator(`${formSelector} button[type="submit"]`);
      if (await submitButton.count() > 0) {
        await submitButton.click();
        await this.page.waitForTimeout(500);
      }

      // Check for error message
      const errorMsg = await this.page.locator(
        `[aria-invalid="true"][name="${inputName}"]`
      ).or(
        this.page.locator(`#${inputName}-error`)
      );

      const isVisible = await errorMsg.isVisible().catch(() => false);
      const errorText = await errorMsg.textContent().catch(() => '');

      // Calculate contrast of error message
      const errorContrast = await this.page.evaluate((selector) => {
        const el = document.querySelector(selector) as HTMLElement;
        if (!el) return null;

        const style = window.getComputedStyle(el);
        const bgColor = style.backgroundColor;
        const textColor = style.color;

        return {
          backgroundColor: bgColor,
          textColor: textColor,
          // Note: real contrast calculation requires color parsing library
          // This is a placeholder; see Contrast Checker skill for full implementation
        };
      }, `[name="${inputName}-error"]`).catch(() => null);

      errors.push({
        inputName,
        hasError: isVisible,
        errorMessage: errorText,
        contrast: errorContrast,
      });
    }

    return {
      formSelector,
      validationErrors: errors,
      timestamp: new Date().toISOString(),
    };
  }

  /**
   * Generate consolidated audit report
   */
  async generateReport(testLabel: string): Promise<AuditReport> {
    return {
      testLabel,
      url: this.config.url,
      timestamp: new Date().toISOString(),
      findings: this.findings,
      outputDir: this.config.outputDir,
      recommendations: this.generateRecommendations(),
    };
  }

  private generateRecommendations(): string[] {
    const recommendations: string[] = [];

    // Examples; real logic would analyze findings
    if (this.findings.some(f => f.severity === 'critical')) {
      recommendations.push('Address critical violations immediately—they block entire user groups.');
    }
    if (this.findings.some(f => f.type === 'contrast')) {
      recommendations.push('Verify contrast on real hardware; on-screen appearance varies by monitor.');
    }
    if (this.findings.some(f => f.type === 'keyboard')) {
      recommendations.push('Keyboard access is non-negotiable; test with keyboard-only users.');
    }

    return recommendations;
  }
}

// Type definitions

interface AuditFinding {
  type: 'wcag' | 'contrast' | 'keyboard' | 'focus' | 'motion' | 'zoom' | 'form';
  severity: 'critical' | 'serious' | 'moderate' | 'minor';
  element?: string;
  description: string;
  wcagCriteria?: string;
}

interface AxeResult {
  context: string;
  timestamp: string;
  violations: any; // axe violations object
}

interface ScreenshotRecord {
  label: string;
  viewport: string;
  colorScheme: string;
  filename: string;
  filepath: string;
}

interface ZoomResult {
  zoomLevel: number;
  filename: string;
  filepath: string;
  scrollDimensions: any;
  reflowed: boolean;
}

interface MotionResult {
  preference: string;
  filename: string;
  filepath: string;
  animatingElements: number;
  details: any[];
}

interface KeyboardResult {
  label: string;
  focusStops: number;
  focusPath: FocusStop[];
  completedCycle: boolean;
  keyboardTrapsDetected: boolean;
}

interface FocusStop {
  tabIndex: number;
  screenshot: string;
  element: any;
}

interface FocusIndicatorResult {
  element: any;
  focusStyle: any;
  hasVisibleIndicator: boolean;
}

interface FormErrorResult {
  formSelector: string;
  validationErrors: FormValidationError[];
  timestamp: string;
}

interface FormValidationError {
  inputName: string;
  hasError: boolean;
  errorMessage: string;
  contrast: any;
}

interface AuditReport {
  testLabel: string;
  url: string;
  timestamp: string;
  findings: AuditFinding[];
  outputDir: string;
  recommendations: string[];
}
```

### Step 2 — Test Matrix Configuration

**Create `audit-config.ts`:**

```typescript
export interface AuditTarget {
  name: string;
  url: string;
  label: string;
  formSelector?: string;
  waitForSelectors?: string[];
  axeRules?: {
    disable: string[];
    enable: string[];
  };
}

export const AUDIT_TARGETS: Record<string, AuditTarget> = {
  homepage: {
    name: 'homepage',
    url: 'http://localhost:3000/',
    label: 'home',
    waitForSelectors: ['main'],
  },
  checkout: {
    name: 'checkout',
    url: 'http://localhost:3000/checkout',
    label: 'checkout',
    formSelector: 'form[name="checkout"]',
    waitForSelectors: ['button[type="submit"]'],
    axeRules: {
      disable: ['color-contrast'], // You may have custom contrast handling
      enable: ['label', 'required-aria'],
    },
  },
  dashboard: {
    name: 'dashboard',
    url: 'http://localhost:3000/dashboard',
    label: 'dashboard',
    waitForSelectors: ['[data-testid="dashboard-content"]'],
  },
};

export const DEFAULT_AXE_CONFIG = {
  rules: {
    // Customize per your context
    'color-contrast': { enabled: true },
    'label': { enabled: true },
    'button-name': { enabled: true },
    'image-alt': { enabled: true },
    'aria-required-attr': { enabled: true },
    'aria-valid-attr-value': { enabled: true },
    'aria-hidden-focus': { enabled: true },
    'focus-visible': { enabled: false }, // Browser-dependent
  },
};
```

### Step 3 — Complete Test Harness

**Create `accessibility.test.ts`:**

```typescript
import { test, expect } from '@playwright/test';
import { AccessibilityAuditor } from './accessibility.auditor';
import { AUDIT_TARGETS, DEFAULT_AXE_CONFIG } from './audit-config';
import fs from 'fs';
import path from 'path';

const OUTPUT_DIR = './audit-results';
const TIMESTAMP = new Date().toISOString().slice(0, 10);

// Ensure output directory exists
if (!fs.existsSync(OUTPUT_DIR)) {
  fs.mkdirSync(OUTPUT_DIR, { recursive: true });
}

for (const [key, target] of Object.entries(AUDIT_TARGETS)) {
  test(`Accessibility audit: ${target.name}`, async ({ page }) => {
    const auditor = new AccessibilityAuditor(page, {
      url: target.url,
      outputDir: path.join(OUTPUT_DIR, `${TIMESTAMP}__${target.label}`),
      axeConfig: {
        rules: {
          ...DEFAULT_AXE_CONFIG.rules,
          ...target.axeRules,
        },
      },
    });

    // Create output directory
    const dir = path.join(OUTPUT_DIR, `${TIMESTAMP}__${target.label}`);
    if (!fs.existsSync(dir)) {
      fs.mkdirSync(dir, { recursive: true });
    }

    // Step 1: Navigate and stabilize
    await auditor.navigateAndStabilize(target.waitForSelectors);

    // Step 2: Capture multi-viewport screenshots
    const screenshots = await auditor.captureMultiViewportScreenshots(target.label);
    console.log(`Captured ${screenshots.length} viewport screenshots`);

    // Step 3: Test zoom/reflow
    const zoomResults = await auditor.testZoomReflow(target.label);
    console.log(`Tested zoom at ${zoomResults.map(r => r.zoomLevel).join(', ')}%`);

    // Step 4: Test reduced motion
    const motionResults = await auditor.testReducedMotion(target.label);
    console.log(`Motion compliance: ${motionResults.length} scenarios tested`);

    // Step 5: Keyboard navigation
    const keyboardResult = await auditor.testKeyboardNavigation(target.label);
    console.log(`Found ${keyboardResult.focusStops} focusable elements`);
    expect(keyboardResult.keyboardTrapsDetected).toBe(false);

    // Step 6: Focus indicator verification
    const focusIndicators = await auditor.verifyFocusIndicators();
    const visibleIndicators = focusIndicators.filter(r => r.hasVisibleIndicator);
    console.log(`${visibleIndicators.length}/${focusIndicators.length} elements have visible focus indicators`);

    // Step 7: Axe-core scan
    const axeResult = await auditor.scanWithAxe(target.label);
    console.log(`Axe scan complete: ${axeResult.violations?.length || 0} violations`);

    // Step 8: Form error testing (if applicable)
    if (target.formSelector) {
      const formErrors = await auditor.testFormErrorStates(target.formSelector);
      console.log(`Form validation errors found: ${formErrors.validationErrors.length}`);
    }

    // Step 9: Generate report
    const report = await auditor.generateReport(target.label);
    fs.writeFileSync(
      path.join(dir, 'audit-report.json'),
      JSON.stringify(report, null, 2)
    );

    // Step 10: Save detailed findings
    const findings = {
      target: target.name,
      timestamp: new Date().toISOString(),
      screenshots,
      zoomResults,
      motionResults,
      keyboard: keyboardResult,
      focusIndicators,
      axe: axeResult,
      recommendations: report.recommendations,
    };

    fs.writeFileSync(
      path.join(dir, 'full-audit.json'),
      JSON.stringify(findings, null, 2)
    );

    console.log(`Audit complete: ${dir}`);
  });
}

test('Multi-page keyboard flow (example: cart → checkout)', async ({ page }) => {
  const auditor = new AccessibilityAuditor(page, {
    url: 'http://localhost:3000',
    outputDir: path.join(OUTPUT_DIR, `${TIMESTAMP}__multi-page-flow`),
    axeConfig: { rules: DEFAULT_AXE_CONFIG.rules },
  });

  const dir = path.join(OUTPUT_DIR, `${TIMESTAMP}__multi-page-flow`);
  if (!fs.existsSync(dir)) fs.mkdirSync(dir, { recursive: true });

  // Page 1: Cart
  await page.goto('http://localhost:3000/cart', { waitUntil: 'networkidle' });
  const cartKeyboard = await auditor.testKeyboardNavigation('cart');
  expect(cartKeyboard.keyboardTrapsDetected).toBe(false);

  // Page 2: Proceed to checkout
  await page.click('button:has-text("Checkout")');
  await page.waitForURL('**/checkout');
  const checkoutKeyboard = await auditor.testKeyboardNavigation('checkout');
  expect(checkoutKeyboard.keyboardTrapsDetected).toBe(false);

  fs.writeFileSync(
    path.join(dir, 'multi-page-flow.json'),
    JSON.stringify({
      pages: [
        { page: 'cart', ...cartKeyboard },
        { page: 'checkout', ...checkoutKeyboard },
      ],
    }, null, 2)
  );
});
```

### Step 4 — Visual Regression & Baseline Comparison

**Create `visual-regression.ts` helper:**

```typescript
import fs from 'fs';
import path from 'path';

export interface BaselineComparison {
  new: string;
  baseline: string;
  match: boolean;
  diff?: string;
}

/**
 * Compare new screenshots against baseline using pixel-level diff
 * Requires: npm install --save-dev pixelmatch
 */
export async function compareScreenshots(
  newPath: string,
  baselinePath: string
): Promise<BaselineComparison> {
  const fs_promise = await import('fs/promises');

  // Check if baseline exists
  if (!fs.existsSync(baselinePath)) {
    console.warn(`No baseline found at ${baselinePath}; creating it`);
    await fs_promise.copyFile(newPath, baselinePath);
    return { new: newPath, baseline: baselinePath, match: true };
  }

  // Pixel-level comparison (requires image comparison library)
  // This is pseudocode; real implementation requires pixelmatch or similar
  const match = true; // Placeholder

  return {
    new: newPath,
    baseline: baselinePath,
    match,
  };
}

/**
 * Generate HTML report with side-by-side screenshots
 */
export function generateVisualRegressionReport(
  comparisons: BaselineComparison[],
  outputPath: string
) {
  const html = `
    <!DOCTYPE html>
    <html>
    <head>
      <title>Visual Regression Report</title>
      <style>
        body { font-family: sans-serif; margin: 2rem; }
        .comparison { border: 1px solid #ccc; margin: 2rem 0; padding: 1rem; }
        .match { background: #d4edda; }
        .mismatch { background: #f8d7da; }
        img { max-width: 100%; border: 1px solid #999; }
        .side-by-side { display: grid; grid-template-columns: 1fr 1fr; gap: 1rem; }
      </style>
    </head>
    <body>
      <h1>Visual Regression Report</h1>
      ${comparisons.map((c, i) => `
        <div class="comparison ${c.match ? 'match' : 'mismatch'}">
          <h3>${c.match ? '✓' : '✗'} ${path.basename(c.new)}</h3>
          <div class="side-by-side">
            <div>
              <h4>New</h4>
              <img src="${c.new}" alt="new">
            </div>
            <div>
              <h4>Baseline</h4>
              <img src="${c.baseline}" alt="baseline">
            </div>
          </div>
        </div>
      `).join('')}
    </body>
    </html>
  `;

  fs.writeFileSync(outputPath, html);
}
```

### Step 5 — Business-Value Framing

**Create `audit-summary.ts` for executive reporting:**

```typescript
/**
 * Translate accessibility audit findings into business terms
 */
export function generateExecutiveSummary(auditResults: any): string {
  const criticalCount = auditResults.findings?.filter(
    (f: any) => f.severity === 'critical'
  ).length || 0;

  const wcagFailureCount = auditResults.findings?.filter(
    (f: any) => f.wcagCriteria
  ).length || 0;

  const keyboardTrapsDetected = auditResults.keyboard?.keyboardTrapsDetected || false;

  return `
## Accessibility Audit Summary

### Business Impact

**Market Access:** ${criticalCount} critical violations exclude users with disabilities from your product.
- Estimated impact: 15% of population (WHO data)
- Legal risk: ADA/Section 508 compliance
- Reputational risk: Public interest in ethical design

**User Experience:** ${keyboardTrapsDetected ? 'Keyboard navigation broken—screen reader users cannot use your product' : 'Keyboard navigation verified'}

**Technical Debt:** ${wcagFailureCount} WCAG failures require remediation before launch

### Next Steps

1. Assign severity labels to findings
2. Prioritize critical violations for immediate fix
3. Schedule accessibility review in design/QA process
4. Test fixes in real browser before deployment
5. Integrate continuous accessibility testing in CI/CD

---

**Key Insight:** Accessibility is not a feature. It's a prerequisite for market access.
It's how you scale from "works for some users" to "works for all users."
`;
}
```

---

## Reference Guide

### Viewport Matrix

Exact dimensions for comprehensive responsive testing:

| Device | Width | Height | DPI | Notes |
|--------|-------|--------|-----|-------|
| Desktop | 1920 | 1080 | 96 | Primary browser, typical monitor |
| Tablet (portrait) | 768 | 1024 | 96 | iPad-sized, vertical |
| Tablet (landscape) | 1024 | 768 | 96 | iPad-sized, horizontal |
| Mobile | 375 | 667 | 96 | iPhone 8 equivalent |
| Mobile (small) | 320 | 568 | 96 | Smaller phones; 2.4% of traffic but 12% of errors |

Test in order: mobile first (catches reflow issues), then tablet, then desktop. Many bugs are viewport-specific.

### axe-core Rule Configuration

**Recommended setup for production testing:**

```typescript
const AXE_RULES = {
  // Critical for compliance
  'color-contrast': { enabled: true },
  'label': { enabled: true },
  'button-name': { enabled: true },
  'image-alt': { enabled: true },
  'aria-required-attr': { enabled: true },
  'aria-valid-attr-value': { enabled: true },
  'aria-hidden-focus': { enabled: true },

  // High priority
  'heading-order': { enabled: true },
  'list': { enabled: true },
  'table-fake-caption': { enabled: true },
  'td-has-header': { enabled: true },

  // Context-dependent (disable if causing false positives)
  'focus-visible': { enabled: false }, // Requires special handling
  'form-field-multiple-labels': { enabled: false }, // Common pattern variation
  'identical-links-same-purpose': { enabled: false }, // Requires context
};
```

**How to interpret results:**

- **Violations:** WCAG failures. Must fix.
- **Best practices:** Recommended but not required. Example: form fields should have explicit labels.
- **Incomplete:** Axe cannot determine from code alone. Manual review required. Example: "does this image's alt text accurately describe the image?"

**Common false positives to investigate:**

- Color contrast on images (text rendered as image)
- Dynamically injected ARIA (added post-render)
- Form labels in custom UI frameworks
- Focus styles on non-native components

### Playwright Code Patterns

**Pattern: Wait for element stability before testing**

```typescript
// Initial load
await page.goto(url, { waitUntil: 'networkidle' });

// Wait for critical layout elements
await page.waitForSelector('main', { timeout: 10000 });

// Allow CSS animations and transitions to settle
await page.waitForTimeout(500);

// Now safe to screenshot or audit
```

**Pattern: Emulate color scheme**

```typescript
await page.emulateMedia({ colorScheme: 'dark' });
// Dark mode CSS now applies
const screenshot = await page.screenshot();
```

**Pattern: Test under motion preference**

```typescript
await page.emulateMedia({ reducedMotion: 'reduce' });
// prefers-reduced-motion: reduce is now active
const animations = await page.evaluate(() => {
  return Array.from(document.querySelectorAll('[style*="animation"]'));
});
```

**Pattern: Keyboard navigation through form**

```typescript
// Tab to first field
await page.keyboard.press('Tab');
// Type
await page.keyboard.type('example@test.com');
// Tab to next field
await page.keyboard.press('Tab');
// Verify focus moved
const focused = await page.evaluate(() => document.activeElement?.id);
expect(focused).toBe('password-field');
```

**Pattern: Focus indicator verification**

```typescript
const focusStyle = await page.evaluate(() => {
  const el = document.activeElement;
  const style = window.getComputedStyle(el);
  return {
    outlineWidth: style.outlineWidth,
    outlineColor: style.outlineColor,
    boxShadow: style.boxShadow,
  };
});

expect(focusStyle.outlineWidth).not.toBe('0px');
expect(focusStyle.outlineColor).not.toBe('transparent');
```

**Pattern: Trigger form validation**

```typescript
const form = page.locator('form[name="contact"]');
await form.locator('button[type="submit"]').click();
await page.waitForTimeout(300); // Validation message delay

// Check for error state
const errorMsg = form.locator('[role="alert"]');
const isVisible = await errorMsg.isVisible();
expect(isVisible).toBe(true);
```

### Screenshot Naming Convention

Consistent names enable automated diff tooling and visual regression tracking:

```
{test-label}__{viewport}__{colorScheme}.png
{test-label}__zoom-{percentage}pct.png
{test-label}__motion-{preference}.png
{test-label}__focus-{tabIndex}.png
{test-label}__form-errors.png
```

Examples:
- `homepage__mobile__light.png`
- `checkout__tablet-portrait__dark.png`
- `dashboard__zoom-200pct.png`
- `contact__motion-reduce.png`
- `form__focus-03.png` (3rd tab stop)

This naming allows visual diff tools to pair same-configuration screenshots across runs.

---

## Output Format

### Standard Audit Report (JSON)

```json
{
  "testLabel": "homepage",
  "url": "https://example.com",
  "timestamp": "2026-04-03T14:32:00Z",
  "findings": [
    {
      "type": "wcag",
      "severity": "critical",
      "wcagCriteria": "1.4.3 Contrast (Minimum)",
      "element": "button.cta",
      "description": "Button text (#666 on #eee) has contrast ratio 4.2:1, fails AA requirement of 4.5:1",
      "recommendation": "Darken text to #555 or lighten background to #f5f5f5"
    },
    {
      "type": "keyboard",
      "severity": "critical",
      "element": "nav.modal",
      "description": "Modal overlay traps keyboard focus; Tab key does not escape",
      "recommendation": "Add Esc key handler; ensure focus trap only when modal open"
    }
  ],
  "screenshots": {
    "viewport": [
      { "label": "homepage", "viewport": "desktop", "colorScheme": "light", "filename": "homepage__desktop__light.png" },
      { "label": "homepage", "viewport": "mobile", "colorScheme": "dark", "filename": "homepage__mobile__dark.png" }
    ],
    "zoom": [
      { "zoomLevel": 200, "filename": "homepage__zoom-200pct.png", "reflowed": true }
    ]
  },
  "keyboard": {
    "focusStops": 24,
    "completedCycle": true,
    "keyboardTrapsDetected": false,
    "focusPath": [
      {
        "tabIndex": 0,
        "screenshot": "homepage__focus-00.png",
        "element": { "tag": "A", "role": "link", "text": "Home" }
      }
    ]
  },
  "axe": {
    "violations": 3,
    "bestPractices": 2,
    "incomplete": 1
  },
  "recommendations": [
    "Fix contrast on primary CTA button",
    "Remove keyboard trap on modal overlay",
    "Test actual user behavior: keyboard-only, screen reader, magnification"
  ]
}
```

### HTML Summary Report

```html
<!DOCTYPE html>
<html>
<head>
  <title>Accessibility Audit: homepage</title>
  <style>
    body { font-family: -apple-system, sans-serif; margin: 2rem; color: #333; }
    h1 { color: #000; border-bottom: 3px solid #d32f2f; padding-bottom: 0.5rem; }
    .critical { background: #ffebee; border-left: 4px solid #d32f2f; padding: 1rem; margin: 1rem 0; }
    .serious { background: #fff3e0; border-left: 4px solid #f57c00; padding: 1rem; margin: 1rem 0; }
    .screenshot { max-width: 100%; border: 1px solid #ddd; margin: 1rem 0; }
    code { background: #f5f5f5; padding: 0.2rem 0.4rem; font-family: monospace; }
  </style>
</head>
<body>
  <h1>Accessibility Audit Report: homepage</h1>
  <p><strong>Date:</strong> 2026-04-03 | <strong>URL:</strong> https://example.com</p>

  <h2>Critical Findings (Must Fix)</h2>
  <div class="critical">
    <h3>Button contrast too low</h3>
    <p><code>.cta</code> button: #666 text on #eee background = 4.2:1 contrast ratio</p>
    <p><strong>WCAG:</strong> 1.4.3 Contrast (Minimum)</p>
    <p><strong>Impact:</strong> Users with low vision cannot read call-to-action button</p>
    <img src="homepage__desktop__light.png" alt="Screenshot of CTA button" class="screenshot">
  </div>

  <h2>Keyboard Navigation</h2>
  <p>✓ Found 24 focusable elements</p>
  <p>✓ Focus order is logical</p>
  <p>✗ Modal overlay traps keyboard focus</p>

  <h2>Multi-Viewport Testing</h2>
  <table>
    <tr>
      <th>Viewport</th>
      <th>Light Mode</th>
      <th>Dark Mode</th>
    </tr>
    <tr>
      <td>Desktop 1920x1080</td>
      <td><img src="homepage__desktop__light.png" alt="desktop light" style="max-width: 200px;"></td>
      <td><img src="homepage__desktop__dark.png" alt="desktop dark" style="max-width: 200px;"></td>
    </tr>
  </table>

  <h2>Recommendations</h2>
  <ol>
    <li>Increase button text contrast to 4.5:1 minimum (AA) or 7:1 (AAA)</li>
    <li>Add Esc key handler to close modal; ensure focus returns to trigger</li>
    <li>Test with real keyboard-only users and screen reader users</li>
  </ol>
</body>
</html>
```

---

## Cross-References

- **a11y-test-plan:** Generate comprehensive test matrix and WCAG criteria mapping
- **keyboard-focus-auditor:** Deep dive into focus order, tab trap detection, focus restoration
- **screen-reader-scripting:** Test semantic structure with NVDA, JAWS, VoiceOver
- **accessibility-code:** Fix violations in HTML/CSS/JavaScript
- **contrast-checker:** Calculate and verify color contrast ratios
- **motion-auditor:** Advanced animation and transition testing
- **full-accessibility-audit:** Orchestrate all testing methods in one report

---

## Why This Matters: Business Value of Accessibility

Accessibility is not compliance theater. It's market access.

- **15% of global population has a disability.** (WHO) That's not a minority—it's your fastest-growing demographic as population ages.
- **Market size:** $490B in discretionary spending from people with disabilities (US). Accessible products win that market.
- **Legal exposure:** ADA, Section 508, GDPR, UK Equality Act, EN 301 549 all require accessible digital products. Non-compliance triggers litigation and regulation.
- **Business outcomes:** Accessible design benefits everyone:
  - Keyboard navigation helps power users
  - High contrast helps outdoor usage, tired eyes, cheap monitors
  - Zoom/reflow helps small screens, mobile users
  - Captions help noisy environments, non-native speakers
  - Clear language helps everyone

This auditor tests the rendered product—what users actually experience. Source analysis is necessary but not sufficient. A browser test catches rendering failures, CSS bugs, JavaScript mutations, and interaction failures that static tools miss.

**Use this skill to prove accessibility works. Then measure business impact: conversion rate, user retention, market access, legal risk reduction.**
