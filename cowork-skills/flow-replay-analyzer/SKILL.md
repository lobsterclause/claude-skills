---
name: flow-replay-analyzer
description: >
  Sub-skill for analyzing screen recordings of web app user flows using multimodal AI. Takes a .webm or .mp4 recording and a natural-language expectation description, sends the video to Gemini 3 Flash (for temporal/animation analysis) and optionally Kimi VL (for frame-level second opinion), and returns a structured JSON report of violations. Use this skill when you have a screen recording of a user flow and want to find animation glitches, broken transitions, loading state bugs, timing issues, or any visual behavior that only appears between frames. Also trigger for: "analyze this recording", "check this video for bugs", "did the transition work", "watch this flow and tell me what's wrong", "replay analysis", "video QA". Primarily invoked as a sub-agent by user-flow-auditor, but can be run standalone on any recording.
---

# flow-replay-analyzer

Analyzes screen recordings of user flows to catch bugs that screenshots cannot see: broken transitions, animation glitches, spinners that never resolve, modals that flash wrong content, focus rings that jump erratically, loading states that skip to completion without feedback.

This skill fills the gap between static screenshot audits and what a human QA engineer sees when they actually watch the app move. It uses Gemini 3 Flash for native video understanding (temporal flow, timing, animations) and optionally Kimi VL on extracted frames for a second structural opinion.

## Inputs

Collect these before starting:

- **`VIDEO_PATH`** — path to `.webm` or `.mp4` recording (required)
- **`EXPECTATION`** — natural language description of what *should* happen in this flow, e.g. "User clicks Save, a loading spinner appears briefly, then a green success toast slides in from the top right and the profile data updates in place" (required)
- **`FLOW_NAME`** — short identifier for this flow, used in output filenames (default: derived from VIDEO_PATH basename)
- **`OUTPUT_DIR`** — where to save frames and results (default: same directory as VIDEO_PATH)
- **`KIMI_REVIEW`** — whether to run Kimi VL as a parallel second reviewer (default: true if `KIMI_API_KEY` is set)

## Execution

Run the analyzer script:

```bash
python scripts/analyze_recording.py \
  --video "$VIDEO_PATH" \
  --expectation "$EXPECTATION" \
  --flow-name "$FLOW_NAME" \
  --output-dir "$OUTPUT_DIR" \
  [--no-kimi]
```

Run `python scripts/analyze_recording.py --help` first to confirm flags. The script handles everything: frame extraction, Gemini API call, optional Kimi call, result merging, and JSON output.

## Output

The script writes:

- `$OUTPUT_DIR/$FLOW_NAME-frames/` — extracted PNG frames (scene-change-aware, typically 8–20 frames per flow)
- `$OUTPUT_DIR/$FLOW_NAME-analysis.json` — merged analysis result

**Analysis JSON schema:**
```json
{
  "flow": "save-profile",
  "video": "/tmp/audit/recordings/save-profile.webm",
  "duration_seconds": 8.4,
  "frames_extracted": 12,
  "verdict": "FAIL | PASS | PARTIAL",
  "confidence": "high | medium | low",
  "agreement": "both | gemini-only | kimi-only | neither",
  "expectation": "User clicks Save, spinner appears, success toast slides in",
  "violations": [
    {
      "timestamp_s": 3.2,
      "frame": "frames/frame_0032.png",
      "expected": "success toast slides in from top right",
      "observed": "no toast visible; form remains in submitted state indefinitely",
      "severity": "P0",
      "reviewer": "gemini | kimi | both"
    }
  ],
  "passing": [
    "Loading spinner appeared correctly at 1.1s",
    "Form inputs were disabled during submission"
  ],
  "animation_notes": "Transition timing looks correct; no jank detected",
  "reviewers_used": ["gemini-3-flash-preview", "kimi-vl-a3b-thinking"]
}
```

When used as a sub-agent (called by user-flow-auditor), return this JSON as your final output so the orchestrator can incorporate it into the main report.

## Standalone usage

You can also run this on any recording without the main auditor:

> "analyze this recording at /tmp/recordings/checkout.webm — the user should be able to add an item to cart and see the cart badge animate up"

In that case, collect `VIDEO_PATH` and `EXPECTATION` from the user, run the script, and present the violations in a readable summary alongside the JSON.

## Severity classification

Apply these when classifying violations found in the recording:

- **P0** — animation/transition is completely absent when it's critical to UX feedback (missing success toast, no loading indicator on slow action, blank flash between routes)
- **P1** — animation present but wrong (success toast appears but immediately disappears, spinner skips without completing, wrong element animates)
- **P2** — animation works but poorly (jank/stutter, wrong timing, transition feels abrupt)
- **P3** — polish issue (easing curve looks off, animation is slightly too fast/slow, hover state flicker barely noticeable)