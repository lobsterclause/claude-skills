#!/usr/bin/env python3
"""
Flow Replay Analyzer — analyzes a screen recording for UX/animation violations.

Usage:
    python analyze_recording.py --video <path> --expectation "<text>" [options]

Options:
    --video PATH            Path to .webm or .mp4 recording (required)
    --expectation TEXT      What should happen in this flow (required)
    --flow-name NAME        Short identifier (default: derived from video filename)
    --output-dir DIR        Where to save frames and results (default: video directory)
    --no-kimi               Skip Kimi VL second-pass review
    --gemini-model MODEL    Gemini model ID (default: gemini-3-flash-preview)
    --help                  Show this help

Environment:
    GEMINI_API_KEY          Required for Gemini analysis
    KIMI_API_KEY            Required for Kimi VL analysis (optional)
"""

import argparse
import json
import os
import subprocess
import sys
import time
from pathlib import Path


def parse_args():
    parser = argparse.ArgumentParser(
        description="Analyze a screen recording for UX/animation violations using multimodal AI."
    )
    parser.add_argument("--video", required=True, help="Path to .webm or .mp4 recording")
    parser.add_argument("--expectation", required=True, help="Natural language description of expected behavior")
    parser.add_argument("--flow-name", help="Short identifier for this flow")
    parser.add_argument("--output-dir", help="Output directory for frames and results")
    parser.add_argument("--no-kimi", action="store_true", help="Skip Kimi VL review")
    parser.add_argument("--gemini-model", default="gemini-3-flash-preview", help="Gemini model ID")
    return parser.parse_args()


def check_dependencies():
    missing = []
    try:
        subprocess.run(["ffmpeg", "-version"], capture_output=True, check=True)
    except (subprocess.CalledProcessError, FileNotFoundError):
        missing.append("ffmpeg (brew install ffmpeg)")
    try:
        import google.generativeai  # noqa: F401
    except ImportError:
        missing.append("google-generativeai (pip install google-generativeai)")
    if missing:
        print(f"ERROR: Missing dependencies:\n" + "\n".join(f"  - {m}" for m in missing), file=sys.stderr)
        sys.exit(1)


def get_video_duration(video_path: Path) -> float:
    result = subprocess.run(
        ["ffprobe", "-v", "quiet", "-print_format", "json", "-show_format", str(video_path)],
        capture_output=True, text=True
    )
    try:
        info = json.loads(result.stdout)
        return float(info["format"]["duration"])
    except Exception:
        return 0.0


def extract_frames(video_path: Path, frames_dir: Path) -> list[Path]:
    """Extract key frames using scene-change detection + fixed interval fallback."""
    frames_dir.mkdir(parents=True, exist_ok=True)

    # Scene-change detection: extract frames where the scene changes significantly
    scene_output = frames_dir / "scene_%04d.png"
    subprocess.run(
        [
            "ffmpeg", "-i", str(video_path),
            "-vf", "select='gt(scene,0.15)',scale=1280:-1",
            "-vsync", "vfr",
            "-q:v", "2",
            str(scene_output),
            "-y",
        ],
        capture_output=True,
    )

    scene_frames = sorted(frames_dir.glob("scene_*.png"))

    # If scene detection yields too few frames (< 5), fall back to 1fps
    if len(scene_frames) < 5:
        fps_output = frames_dir / "fps_%04d.png"
        subprocess.run(
            [
                "ffmpeg", "-i", str(video_path),
                "-vf", "fps=1,scale=1280:-1",
                "-q:v", "2",
                str(fps_output),
                "-y",
            ],
            capture_output=True,
        )
        fps_frames = sorted(frames_dir.glob("fps_*.png"))
        all_frames = sorted(scene_frames + fps_frames, key=lambda p: p.name)
    else:
        all_frames = scene_frames

    # Cap at 20 frames to stay within API limits
    if len(all_frames) > 20:
        step = len(all_frames) // 20
        all_frames = all_frames[::step][:20]

    print(f"Extracted {len(all_frames)} frames from {video_path.name}")
    return all_frames


def build_gemini_prompt(expectation: str, flow_name: str) -> str:
    return f"""You are a QA engineer analyzing a screen recording of a user flow called "{flow_name}".

EXPECTED BEHAVIOR:
{expectation}

Watch the recording carefully and identify any violations — places where what actually happens differs from the expected behavior. Focus especially on:
- Animations and transitions (do they appear? timing? smoothness?)
- Loading states (spinners, skeletons — do they appear and resolve correctly?)
- Success/error feedback (toasts, banners, inline messages — do they appear at the right moment?)
- State changes (does UI update correctly after an action?)
- Timing issues (does anything happen too fast, too slow, or not at all?)
- Visual glitches (flickers, blank frames, elements appearing in wrong positions)

For each violation found, provide:
1. The approximate timestamp in seconds when it occurs
2. What was expected
3. What was actually observed
4. Severity: P0 (completely missing critical feedback), P1 (wrong behavior), P2 (present but poor quality), P3 (minor polish issue)

Also note anything that IS working correctly as "passing" items.

Respond ONLY with valid JSON in this exact structure:
{{
  "verdict": "FAIL | PASS | PARTIAL",
  "confidence": "high | medium | low",
  "violations": [
    {{
      "timestamp_s": 3.2,
      "expected": "success toast slides in",
      "observed": "no toast appeared",
      "severity": "P0"
    }}
  ],
  "passing": ["Loading spinner appeared at 1.1s", "Form disabled during submission"],
  "animation_notes": "Brief note on overall animation quality and timing"
}}"""


def analyze_with_gemini(video_path: Path, frames: list[Path], expectation: str, flow_name: str, model: str) -> dict:
    import google.generativeai as genai

    api_key = os.environ.get("GEMINI_API_KEY")
    if not api_key:
        print("WARNING: GEMINI_API_KEY not set — skipping Gemini analysis", file=sys.stderr)
        return {}

    genai.configure(api_key=api_key)
    client = genai.GenerativeModel(model)

    prompt = build_gemini_prompt(expectation, flow_name)

    # Try video upload first (best for temporal analysis)
    try:
        print(f"Uploading video to Gemini ({video_path.stat().st_size // 1024}KB)...")
        video_file = genai.upload_file(str(video_path))

        # Wait for processing
        for _ in range(30):
            video_file = genai.get_file(video_file.name)
            if video_file.state.name == "ACTIVE":
                break
            time.sleep(2)

        response = client.generate_content([video_file, prompt])
        genai.delete_file(video_file.name)

        raw = response.text.strip()
        if raw.startswith("```"):
            raw = raw.split("```")[1]
            if raw.startswith("json"):
                raw = raw[4:]
        result = json.loads(raw)
        result["reviewer"] = model
        result["method"] = "video"
        return result

    except Exception as e:
        print(f"Video upload failed ({e}), falling back to frames...", file=sys.stderr)

    # Fallback: send frames as images
    try:
        import PIL.Image
        parts = [prompt]
        for frame in frames[:16]:  # Gemini image limit
            parts.append(PIL.Image.open(frame))

        response = client.generate_content(parts)
        raw = response.text.strip()
        if raw.startswith("```"):
            raw = raw.split("```")[1]
            if raw.startswith("json"):
                raw = raw[4:]
        result = json.loads(raw)
        result["reviewer"] = model
        result["method"] = "frames"
        return result
    except Exception as e:
        print(f"Frame-based Gemini analysis failed: {e}", file=sys.stderr)
        return {}


def analyze_with_kimi(frames: list[Path], expectation: str, flow_name: str) -> dict:
    """Send extracted frames to Kimi VL for a second structural opinion."""
    api_key = os.environ.get("KIMI_API_KEY")
    if not api_key:
        return {}

    try:
        import base64
        import urllib.request
        import urllib.error

        prompt = build_gemini_prompt(expectation, flow_name)

        # Build multimodal message with frames
        content = [{"type": "text", "text": prompt}]
        for frame in frames[:10]:  # Kimi VL image limit
            with open(frame, "rb") as f:
                b64 = base64.b64encode(f.read()).decode()
            content.append({
                "type": "image_url",
                "image_url": {"url": f"data:image/png;base64,{b64}"}
            })

        payload = json.dumps({
            "model": "kimi-vl-a3b-thinking",
            "messages": [{"role": "user", "content": content}],
            "max_tokens": 2048,
        }).encode()

        req = urllib.request.Request(
            "https://api.moonshot.cn/v1/chat/completions",
            data=payload,
            headers={
                "Authorization": f"Bearer {api_key}",
                "Content-Type": "application/json",
            },
        )
        with urllib.request.urlopen(req, timeout=60) as resp:
            data = json.loads(resp.read())

        raw = data["choices"][0]["message"]["content"].strip()
        if raw.startswith("```"):
            raw = raw.split("```")[1]
            if raw.startswith("json"):
                raw = raw[4:]
        result = json.loads(raw)
        result["reviewer"] = "kimi-vl-a3b-thinking"
        result["method"] = "frames"
        return result

    except Exception as e:
        print(f"Kimi VL analysis failed: {e}", file=sys.stderr)
        return {}


def merge_results(gemini: dict, kimi: dict, flow_name: str, video_path: Path, duration: float, frame_count: int, expectation: str) -> dict:
    """Merge Gemini and Kimi findings, flagging agreement and disagreements."""
    reviewers_used = []
    if gemini:
        reviewers_used.append(gemini.get("reviewer", "gemini"))
    if kimi:
        reviewers_used.append(kimi.get("reviewer", "kimi"))

    all_violations = []
    gemini_violations = gemini.get("violations", [])
    kimi_violations = kimi.get("violations", [])

    # Tag each violation with its source
    for v in gemini_violations:
        v["reviewer"] = "gemini"
        all_violations.append(v)

    # Kimi violations: mark as "both" if similar to a Gemini finding, else "kimi-only"
    for kv in kimi_violations:
        matched = False
        for v in all_violations:
            if abs(v.get("timestamp_s", -99) - kv.get("timestamp_s", -100)) < 1.5:
                v["reviewer"] = "both"
                matched = True
                break
        if not matched:
            kv["reviewer"] = "kimi"
            all_violations.append(kv)

    # Sort by severity then timestamp
    severity_order = {"P0": 0, "P1": 1, "P2": 2, "P3": 3}
    all_violations.sort(key=lambda v: (severity_order.get(v.get("severity", "P3"), 3), v.get("timestamp_s", 0)))

    # Determine overall verdict
    has_p0 = any(v.get("severity") == "P0" for v in all_violations)
    has_p1 = any(v.get("severity") == "P1" for v in all_violations)
    gemini_verdict = gemini.get("verdict", "PASS")
    kimi_verdict = kimi.get("verdict", "PASS")

    if has_p0 or gemini_verdict == "FAIL" or kimi_verdict == "FAIL":
        verdict = "FAIL"
    elif has_p1 or gemini_verdict == "PARTIAL" or kimi_verdict == "PARTIAL":
        verdict = "PARTIAL"
    else:
        verdict = "PASS"

    # Agreement assessment
    if gemini and kimi:
        agreement = "both" if gemini_verdict == kimi_verdict else "disagree"
    elif gemini:
        agreement = "gemini-only"
    elif kimi:
        agreement = "kimi-only"
    else:
        agreement = "neither"

    # Combine passing notes
    passing = list(set(gemini.get("passing", []) + kimi.get("passing", [])))

    # Confidence: high if both agree, medium if one reviewer, low if disagreement
    if agreement == "both":
        confidence = "high"
    elif agreement in ("gemini-only", "kimi-only"):
        confidence = "medium"
    elif agreement == "disagree":
        confidence = "low"
    else:
        confidence = "low"

    return {
        "flow": flow_name,
        "video": str(video_path),
        "duration_seconds": round(duration, 1),
        "frames_extracted": frame_count,
        "verdict": verdict,
        "confidence": confidence,
        "agreement": agreement,
        "expectation": expectation,
        "violations": all_violations,
        "passing": passing,
        "animation_notes": gemini.get("animation_notes", kimi.get("animation_notes", "")),
        "reviewers_used": reviewers_used,
    }


def main():
    args = parse_args()
    check_dependencies()

    video_path = Path(args.video).resolve()
    if not video_path.exists():
        print(f"ERROR: Video not found: {video_path}", file=sys.stderr)
        sys.exit(1)

    flow_name = args.flow_name or video_path.stem
    output_dir = Path(args.output_dir) if args.output_dir else video_path.parent
    output_dir.mkdir(parents=True, exist_ok=True)
    frames_dir = output_dir / f"{flow_name}-frames"

    print(f"Analyzing flow: {flow_name}")
    print(f"Video: {video_path}")
    print(f"Output: {output_dir}")

    duration = get_video_duration(video_path)
    frames = extract_frames(video_path, frames_dir)

    use_kimi = not args.no_kimi and bool(os.environ.get("KIMI_API_KEY"))

    print("Running Gemini analysis...")
    gemini_result = analyze_with_gemini(video_path, frames, args.expectation, flow_name, args.gemini_model)

    kimi_result = {}
    if use_kimi:
        print("Running Kimi VL analysis...")
        kimi_result = analyze_with_kimi(frames, args.expectation, flow_name)

    result = merge_results(
        gemini_result, kimi_result,
        flow_name, video_path, duration, len(frames), args.expectation
    )

    output_path = output_dir / f"{flow_name}-analysis.json"
    output_path.write_text(json.dumps(result, indent=2))
    print(f"\nAnalysis complete: {output_path}")
    print(f"Verdict: {result['verdict']} ({result['confidence']} confidence)")
    print(f"Violations: {len(result['violations'])} | Passing: {len(result['passing'])}")

    # Print JSON for sub-agent consumption
    print("\n--- RESULT JSON ---")
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()
