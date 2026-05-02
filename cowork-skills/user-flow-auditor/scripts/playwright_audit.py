#!/usr/bin/env python3
"""
Playwright Audit — systematic per-route audit with axe-core, console/network capture,
keyboard navigation check, responsive screenshots, and video recording.

Usage:
    python playwright_audit.py --url <url> --output-dir <dir> --slug <slug> [options]

Options:
    --url URL               Full URL of the route to audit (required)
    --output-dir DIR        Root audit directory (required)
    --slug SLUG             Short identifier for this route, e.g. "dashboard" (required)
    --cookie-file PATH      JSON file with auth cookies exported from Stagehand session
    --viewport-widths W,W   Comma-separated viewport widths (default: 375,768,1440)
    --no-axe                Skip axe-core injection
    --no-video              Skip video recording
    --no-keyboard           Skip keyboard navigation check
    --timeout MS            Per-action timeout in ms (default: 10000)
    --help                  Show this help

Output (all relative to --output-dir):
    recordings/<slug>.webm              Video of the full audit
    screenshots/<slug>-375px.png        Responsive screenshots
    screenshots/<slug>-768px.png
    screenshots/<slug>-1440px.png
    screenshots/<slug>-keyboard-<n>.png Focus state screenshots
    logs/<slug>-axe.json                axe-core violations
    logs/<slug>-playwright.json         Summary: console errors, network failures, timing
"""

import argparse
import json
import sys
import time
from pathlib import Path


AXE_CORE_CDN = "https://cdnjs.cloudflare.com/ajax/libs/axe-core/4.9.1/axe.min.js"

AXE_RUNNER = """
async function runAxe() {
    return new Promise((resolve) => {
        axe.run(document, {
            runOnly: { type: 'tag', values: ['wcag2a', 'wcag2aa', 'wcag21aa', 'best-practice'] }
        }, (err, results) => {
            if (err) resolve({ error: err.toString(), violations: [] });
            else resolve({
                violations: results.violations.map(v => ({
                    id: v.id,
                    impact: v.impact,
                    description: v.description,
                    help: v.help,
                    helpUrl: v.helpUrl,
                    nodes: v.nodes.slice(0, 3).map(n => ({
                        html: n.html.slice(0, 200),
                        target: n.target,
                        failureSummary: n.failureSummary
                    }))
                })),
                passes: results.passes.length,
                incomplete: results.incomplete.length,
            });
        });
    });
}
runAxe();
"""


def parse_args():
    parser = argparse.ArgumentParser(description="Systematic Playwright audit for a single route.")
    parser.add_argument("--url", required=True)
    parser.add_argument("--output-dir", required=True)
    parser.add_argument("--slug", required=True)
    parser.add_argument("--cookie-file")
    parser.add_argument("--viewport-widths", default="375,768,1440")
    parser.add_argument("--no-axe", action="store_true")
    parser.add_argument("--no-video", action="store_true")
    parser.add_argument("--no-keyboard", action="store_true")
    parser.add_argument("--timeout", type=int, default=10000)
    return parser.parse_args()


def load_cookies(cookie_file: str) -> list:
    if not cookie_file:
        return []
    path = Path(cookie_file)
    if not path.exists():
        print(f"WARNING: Cookie file not found: {cookie_file}", file=sys.stderr)
        return []
    with open(path) as f:
        return json.load(f)


def audit_route(args):
    try:
        from playwright.sync_api import sync_playwright, TimeoutError as PlaywrightTimeout
    except ImportError:
        print("ERROR: playwright not installed. Run: pip install playwright && playwright install chromium", file=sys.stderr)
        sys.exit(1)

    output_dir = Path(args.output_dir)
    screenshots_dir = output_dir / "screenshots"
    recordings_dir = output_dir / "recordings"
    logs_dir = output_dir / "logs"

    for d in [screenshots_dir, recordings_dir, logs_dir]:
        d.mkdir(parents=True, exist_ok=True)

    console_errors = []
    network_errors = []
    summary = {
        "url": args.url,
        "slug": args.slug,
        "console_errors": console_errors,
        "network_errors": network_errors,
        "axe_violations": [],
        "keyboard_issues": [],
        "responsive_issues": [],
        "recording": None,
        "duration_ms": 0,
    }

    viewports = [int(w) for w in args.viewport_widths.split(",")]
    start_time = time.time()

    with sync_playwright() as p:
        # Video recording context
        context_options = {
            "viewport": {"width": 1440, "height": 900},
        }
        if not args.no_video:
            context_options["record_video_dir"] = str(recordings_dir)
            context_options["record_video_size"] = {"width": 1440, "height": 900}

        browser = p.chromium.launch(headless=True)
        context = browser.new_context(**context_options)

        # Inject auth cookies if provided
        cookies = load_cookies(args.cookie_file)
        if cookies:
            context.add_cookies(cookies)

        page = context.new_page()
        page.set_default_timeout(args.timeout)

        # Wire up console and network listeners
        page.on("console", lambda msg: (
            console_errors.append({
                "type": msg.type,
                "text": msg.text,
                "url": args.url,
            }) if msg.type in ("error", "warning") else None
        ))
        page.on("pageerror", lambda err: console_errors.append({
            "type": "pageerror",
            "text": str(err),
            "url": args.url,
        }))
        page.on("response", lambda resp: (
            network_errors.append({
                "url": resp.url,
                "status": resp.status,
                "route": args.url,
            }) if resp.status >= 400 else None
        ))

        # Navigate to the route
        try:
            page.goto(args.url, wait_until="networkidle", timeout=30000)
        except PlaywrightTimeout:
            page.goto(args.url, wait_until="domcontentloaded", timeout=15000)
            page.wait_for_timeout(2000)

        # axe-core injection
        if not args.no_axe:
            try:
                page.add_script_tag(url=AXE_CORE_CDN)
                page.wait_for_timeout(500)
                axe_results = page.evaluate(AXE_RUNNER)
                summary["axe_violations"] = axe_results.get("violations", [])
                axe_path = logs_dir / f"{args.slug}-axe.json"
                axe_path.write_text(json.dumps(axe_results, indent=2))
            except Exception as e:
                print(f"axe-core failed: {e}", file=sys.stderr)

        # Keyboard navigation check
        if not args.no_keyboard:
            keyboard_issues = []
            tab_count = 0
            max_tabs = 30

            page.keyboard.press("Tab")
            for i in range(max_tabs):
                focused = page.evaluate("""() => {
                    const el = document.activeElement;
                    if (!el || el === document.body) return null;
                    const rect = el.getBoundingClientRect();
                    const styles = window.getComputedStyle(el);
                    return {
                        tag: el.tagName,
                        text: el.textContent?.trim().slice(0, 50) || '',
                        ariaLabel: el.getAttribute('aria-label'),
                        role: el.getAttribute('role'),
                        outline: styles.outline,
                        outlineWidth: styles.outlineWidth,
                        boxShadow: styles.boxShadow,
                        visible: rect.width > 0 && rect.height > 0,
                    };
                }""")

                if focused:
                    tab_count += 1
                    # Check for missing focus indicator
                    outline_missing = (
                        focused.get("outlineWidth") in ("0px", "0", None, "") and
                        not focused.get("boxShadow") or focused.get("boxShadow") == "none"
                    )
                    if outline_missing and focused.get("visible"):
                        keyboard_issues.append({
                            "tab_index": i,
                            "element": focused,
                            "issue": "No visible focus indicator",
                        })
                        screenshot_path = screenshots_dir / f"{args.slug}-keyboard-{i:03d}.png"
                        page.screenshot(path=str(screenshot_path))

                page.keyboard.press("Tab")

            summary["keyboard_issues"] = keyboard_issues
            summary["focusable_elements"] = tab_count

        # Responsive screenshots
        responsive_issues = []
        for width in viewports:
            page.set_viewport_size({"width": width, "height": 900})
            page.wait_for_timeout(300)

            # Check for horizontal overflow
            has_overflow = page.evaluate("""() => {
                return document.documentElement.scrollWidth > document.documentElement.clientWidth;
            }""")

            screenshot_path = screenshots_dir / f"{args.slug}-{width}px.png"
            page.screenshot(path=str(screenshot_path), full_page=True)

            if has_overflow:
                responsive_issues.append({
                    "viewport_width": width,
                    "issue": "Horizontal overflow detected",
                    "screenshot": str(screenshot_path),
                })

        summary["responsive_issues"] = responsive_issues

        # Close context — this finalizes the video recording
        context.close()

        # Rename the recording to our slug
        if not args.no_video:
            recordings = list(recordings_dir.glob("*.webm"))
            if recordings:
                latest = max(recordings, key=lambda p: p.stat().st_mtime)
                target = recordings_dir / f"{args.slug}.webm"
                if latest != target:
                    latest.rename(target)
                summary["recording"] = str(target)

        browser.close()

    summary["duration_ms"] = int((time.time() - start_time) * 1000)

    # Save summary
    summary_path = logs_dir / f"{args.slug}-playwright.json"
    summary_path.write_text(json.dumps(summary, indent=2))

    print(json.dumps(summary, indent=2))
    return summary


def main():
    args = parse_args()
    audit_route(args)


if __name__ == "__main__":
    main()
