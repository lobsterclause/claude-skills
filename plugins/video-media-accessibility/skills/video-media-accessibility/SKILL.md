---
name: video-media-accessibility
description: Audit and improve accessibility of video, audio, and media content — including captions, audio descriptions, transcripts, accessible media players, and WCAG 1.2.x compliance. Use this skill whenever the user is working with video, audio, podcasts, webinars, live streaming, animations with narration, or any time-based media. Trigger on phrases like "video accessibility", "caption", "captions", "subtitle", "audio description", "transcript", "media player", "accessible video", "WCAG 1.2", "closed captions", "open captions", "CC", "video audit", "audio accessibility", "podcast accessibility", "webinar accessibility", "live caption", "CART", "sign language interpretation", or any request involving making video or audio content accessible.
category: audit
related-skills: cognitive-accessibility, older-audiences-auditor, accessibility-code
---

# Video & Media Accessibility

The 1.2.x criteria are the most commonly skipped section of WCAG. Video and audio content without captions, transcripts, or audio descriptions excludes deaf users, hard-of-hearing users, deafblind users, users with auditory processing disorders, users in sound-sensitive environments, and non-native speakers learning through text.

## WCAG 1.2.x — Time-Based Media Requirements

| Criterion | Level | Requirement |
|-----------|-------|-------------|
| 1.2.1 Audio-only and Video-only (Prerecorded) | A | Text transcript for audio-only; text/audio alternative for silent video |
| 1.2.2 Captions (Prerecorded) | A | Synchronized captions for all prerecorded video with audio |
| 1.2.3 Audio Description or Media Alternative (Prerecorded) | A | Audio description OR full text transcript for prerecorded video |
| 1.2.4 Captions (Live) | AA | Captions for live video with audio |
| 1.2.5 Audio Description (Prerecorded) | AA | Audio description for all prerecorded video |
| 1.2.6 Sign Language (Prerecorded) | AAA | Sign language interpretation for prerecorded audio |
| 1.2.7 Extended Audio Description (Prerecorded) | AAA | Extended audio description when pauses insufficient |
| 1.2.8 Media Alternative (Prerecorded) | AAA | Full text alternative for all prerecorded synchronized media |
| 1.2.9 Audio-only (Live) | AAA | Text alternative for live audio-only content |

### Compliance Checklist by Delivery Model

**Prerecorded video with audio (AA):**
- [ ] Captions (WCAG 1.2.2)
- [ ] Audio description (WCAG 1.2.5)
- [ ] Transcript available (WCAG 1.2.3 alternative to AD)

**Prerecorded audio only (A):**
- [ ] Full transcript (WCAG 1.2.1)
- [ ] Descriptive transcript recommended (goes beyond WCAG)

**Prerecorded video without audio (A):**
- [ ] Text description of visual information (WCAG 1.2.1)
- [ ] Audio description acceptable alternative

**Live video with audio (AA):**
- [ ] Live captions (WCAG 1.2.4)

**Live audio-only (AAA):**
- [ ] Real-time transcription (WCAG 1.2.9)

---

## Accessibility Scoring System (0–10)

Quantify media accessibility across five dimensions:

### Captions (0–2 points)
- 2: High-quality, synchronized captions on all video with audio; 99%+ accuracy
- 1: Captions present but with accuracy issues (85–98%); delayed or hard to read
- 0: No captions or auto-generated captions without review

### Transcripts (0–2 points)
- 2: Descriptive transcript available; includes speaker ID, sound effects, and visual descriptions
- 1: Basic transcript available but missing speaker ID or non-speech audio descriptions
- 0: No transcript or only a summary

### Audio Description (0–2 points)
- 2: Quality AD covering all visual information; natural pauses; concise and professional
- 1: AD present but incomplete; missing key visual details or unnatural narration
- 0: No audio description

### Player Controls (0–2 points)
- 2: Fully keyboard accessible; screen reader compatible; captions/AD toggle visible
- 1: Most controls keyboard accessible; some issues with focus management
- 0: Player not keyboard accessible; controls require mouse

### Autoplay & Motion (0–2 points)
- 2: No autoplay; respects prefers-reduced-motion; all motion controllable
- 1: Autoplay muted; partial motion control
- 0: Autoplays with audio; motion cannot be stopped

**Scoring example:**
```
Webinar video: "Q4 Strategy Discussion"
- Captions: 2/2 (professional captions, synced, 99% accurate)
- Transcripts: 1/2 (basic transcript but no speaker IDs)
- Audio Description: 0/2 (slides and visuals not described)
- Player Controls: 1/2 (captions toggle present, but seek bar accessibility issues)
- Autoplay & Motion: 2/2 (no autoplay, simple slide transitions)
TOTAL: 6/10 — Missing audio description and transcript speaker identification
```

---

## Captions

### Caption vs Subtitle vs Closed Caption vs Open Caption

- **Captions (CC)** — include all audio: speech, speaker identification, sound effects, music descriptions. For deaf and hard-of-hearing users. Can be closed (toggleable) or open (burned in).
- **Subtitles** — translate spoken dialogue into another language. Do NOT include non-speech audio.
- **Closed captions (CC)** — separate text track; user can toggle on/off; preferred (gives user control).
- **Open captions** — burned into the video; always visible; cannot be turned off; useful when caption tech is unavailable.

### Caption Quality Standards

**Accuracy (CRITICAL)**
- Professional captions: 99% accuracy minimum (FCC standard)
- Web/educational: 98% minimum for user-facing content
- Auto-generated (YouTube, Zoom, Teams): typically 80–90% accuracy — insufficient without human review
- Speaker-specific errors particularly harmful: mispronounced names, missed technical terms, proper nouns

**Timing**
- Captions appear within 1–2 seconds of corresponding audio (ideally within 1 second)
- Do not display captions before audio they represent
- Remove captions no more than 2 seconds after audio ends
- Maximum reading speed: 180 words per minute (3 words per second)
- Maximum line length: 32 characters (for readability at standard viewing distances)

**Formatting & Conventions**
- **Speaker identification:** `[SARAH]`, `[Interviewer]`, `[Narrator]` when speaker not visually clear
  - Not needed if speaker is clearly visible on screen
  - Use consistent format throughout
- **Sound effects:** `[door slams]`, `[applause]`, `[notification chime]`
  - Include if sound is informative to understanding; skip ambient background
  - Use square brackets to distinguish from speech
- **Music descriptions:** `[♪ tense orchestral music ♪]` or `[upbeat pop music]`
  - Describe mood/genre rather than lyrics
  - Include if music conveys emotional information
- **Emphasis:** Capitalize sparingly (reserved for strong emphasis only)
  - `"You CANNOT do that"` — acceptable
  - All caps text blocks — avoid
- **Sentence case preferred** over all-caps text; improves readability for dyslexia

**Quality Checklist**
- [ ] No speaker identification errors
- [ ] Technical terms and proper nouns spelled correctly
- [ ] Timing within 1–2 seconds of audio
- [ ] Maximum 180 words per minute reading speed
- [ ] All informative sounds described
- [ ] No captions for purely ambient background sound
- [ ] Consistent speaker ID format throughout
- [ ] Music descriptions convey emotional significance
- [ ] Line breaks occur at natural thought boundaries

**What Never to Do**
- Never use auto-generated captions without human review
- Never caption only partial audio (skipping filler words creates inaccuracy)
- Never use captions with font size below 32px at standard viewing distance
- Never overlap captions with critical on-screen text
- Never ignore music or sound effects that convey information

### Evaluating Existing Captions

**Watch-with-audio-off test:**
1. Mute all audio
2. Watch video with captions only
3. Does it make complete sense?
4. Are speakers identified when they should be?
5. Are meaningful sounds described?
6. Does timing feel natural?
7. Are there accuracy errors?

---

## Transcripts

### When Required
- Audio-only content (podcasts, audio guides): transcript required at WCAG A (1.2.1)
- Video with audio: transcript is alternative to audio description at Level A (1.2.3); not sufficient alone at AA (1.2.5 requires AD)
- Live content: transcription required at AAA (1.2.9)

### Transcript Types

**Basic transcript** — speech only, possibly edited for readability. Insufficient for WCAG at AA level.

**Descriptive transcript** — everything: speakers, speech, sound effects, music descriptions, visual information, emotional context. Required for WCAG and for deafblind users.

### Descriptive Transcript Format & Best Practices

```
[00:00] [Upbeat music with energy and movement]

[00:08] HOST (MARCUS): Welcome to the Design Systems podcast. I'm your host, Marcus Chen.

[00:14] [Sound of keyboard clicking as Marcus types on his laptop]

[00:17] HOST (MARCUS): Today we're talking about accessibility in design systems with our guest,
Priya Sharma, Head of Product at Acme Corp.

[00:24] GUEST (PRIYA): Thanks for having me, Marcus. Great to be here.

[00:26] [Slide appears on screen with white text on dark blue background:
"The Business Case for Accessibility"]

[00:28] GUEST (PRIYA): The first thing I tell clients is — accessibility is not a feature.
It's the baseline expectation for professional software.

[00:38] [Marcus nods while listening intently]
```

**Format guidelines:**
- Use timestamps at natural breaks (every 15–30 seconds)
- Format: `[HH:MM:SS]` or `[MM:SS]` for shorter content
- Speaker name in CAPS followed by colon
- Non-speech sounds in brackets: `[door opens]`, `[silence for 3 seconds]`
- Visual descriptions in brackets for context: `[woman gestures to graph]`
- Music/ambient in brackets with descriptive language: `[soft piano music, melancholic]`
- Preserve speaker personality and tone where possible

### Placement

**For web:**
- Same page as the media — not on a separate linked page
- OR: clearly labeled link immediately adjacent to the media player
- Never buried in an FAQ, footer, or generic "Accessibility" page
- Prefer same-page placement for visibility and discoverability

**For podcasts:**
- Full transcript with timestamps in show notes
- Link prominently from episode page
- Upload to podcast host (Podpage, Transistor, etc.) if platform supports transcripts

---

## Audio Description

Audio description narrates the visual content of a video during natural pauses in dialogue and sound. It communicates actions, scene changes, text, facial expressions, and anything visually significant.

### What to Describe

**Always describe:**
- Actions and events not conveyed by speech
- Text displayed on screen (charts, titles, data, code)
- Scene changes and locations
- Character appearances and clothing when relevant
- Facial expressions and body language when conveying emotion or intent
- Data visualization (how information is presented visually)
- On-screen graphics and diagrams

**Do not describe:**
- What's already clearly stated in dialogue
- Visual aesthetics that don't affect understanding
- Race, ethnicity, or disability unless directly relevant to understanding
- Obvious visual information (e.g., "she's sad" if dialogue makes it clear)

### Writing Audio Description

- Use present tense: "Sarah opens the door" not "Sarah opened the door"
- Be concise — description must fit in natural pauses (typically 2–5 seconds)
- Prioritize what's most important if time is limited
- Match the tone of the content (documentary AD sounds different from comedy)
- Describe, don't interpret ("he waves" not "he's saying goodbye")
- Use clear, precise language

**Example AD for product demo:**
```
AD: "Sarah clicks the blue 'Create' button in the top right corner. A form appears on the screen with fields for 'Project Name' and 'Team Members'. She types 'Q4 Campaign' in the Project Name field."
```

**Example AD for interview:**
```
AD: "The speaker gestures to emphasize a point. The camera pans to show the audience reaction — heads nodding, people taking notes."
```

### Podcast Audio Description

Podcasts with significant visual content (slides, videos, diagrams mentioned) benefit from descriptive transcripts that include visual descriptions:

```
[MINUTE 15:32] [Sound of pages turning]

GUEST: "As you can see in this chart..."

[VISUAL DESCRIPTION: A bar graph appears showing quarterly growth.
Green bars represent 2024 performance, gray bars represent 2023.
The green bars are notably taller, showing approximately 40% growth.]

GUEST: "...we saw forty percent growth year-over-year."
```

### Extended Audio Description (WCAG 1.2.7 AAA)

When natural pauses are too short for adequate description:
- Pause the video automatically to insert longer description
- Resume after description completes
- Label as "with extended audio description" in player controls
- OR: Provide separate AD version of video alongside main version

### AD Track Implementation

```html
<video controls>
  <source src="video.mp4" type="video/mp4">
  
  <!-- Standard captions -->
  <track kind="captions" src="captions-en.vtt" srclang="en" label="English">
  
  <!-- Audio description track (video format) -->
  <track kind="descriptions" src="descriptions-en.vtt" srclang="en" label="Audio Description">
  
  <!-- Or as separate audio file -->
  <audio kind="descriptions">
    <source src="audio-description-en.mp3" type="audio/mpeg">
  </audio>
</video>
```

---

## Live Captions & Streaming Accessibility

### CART (Communication Access Realtime Translation)

**What it is:**
- Human stenographer types captions in real-time
- Accuracy: 99%+ (best-in-class)
- Used for high-stakes events, presentations, conferences

**Cost & Logistics:**
- $150–$300 per hour
- Requires advance booking (2–4 weeks)
- Stenographer connects remotely and delivers captions to display
- Industry standard for government and enterprise events

### AI Live Captions

**Platforms with built-in live captions:**
- Google Meet: automatic live captions (80–90% accuracy)
- Zoom: live captions (80–85% accuracy)
- Microsoft Teams: live captions (80–85% accuracy)
- YouTube: live streaming with auto-captions (80–85% accuracy)

**Characteristics:**
- Adequate for internal meetings and informal events
- Struggling with technical terms and proper nouns
- Users should be notified that captions are auto-generated and may contain errors
- No speaker identification in most platforms

### Hybrid: AI with Human Editing

**Best-in-class approach:**
- AI generates draft captions in real-time
- Human editor watches live and makes corrections
- Final captions 95%+ accurate
- Cost: $200–$400 per hour
- Platforms: White Coat Captioning, CaptionSafe, VITAC

**WCAG requirement for live:**
- WCAG 1.2.4 (AA): Live captions required
- WCAG 1.2.9 (AAA): Full transcription required for audio-only live

**Requirements in practice:**
- Captions appear within 2–3 seconds of speech
- Speaker identification included ("Host:", "Panelist 1:")
- Captions visible and readable on screen (not too small, not overlapping critical content)
- Captions saved after event for on-demand viewing

---

## Sign Language Interpretation

Sign language interpretation is a WCAG AAA requirement (1.2.6) and a critical accessibility feature for Deaf users whose primary language is signed language.

**When to include:**
- High-stakes content (graduation ceremonies, critical announcements, town halls)
- Educational content where clarity is essential
- Marketing/public-facing video (best practice; goes beyond WCAG)

**What to do:**
1. Hire Deaf or CODA (Child of Deaf Adults) interpreters
2. Interpret for at least the primary speaker or all speakers if possible
3. Position interpreter in visible location (typically lower right corner of video)
4. Provide in addition to captions (sign language + captions for different access needs)
5. Use professional interpreters with specialized knowledge if needed (medical, legal, technical)

**Cost:** $75–$200 per hour depending on region and specialization

---

## Accessible Media Player

The media player itself must be accessible — not just the content.

### Required Controls

- [ ] Play/Pause (keyboard: Space or Enter when focused)
- [ ] Volume (keyboard: Up/Down arrows or +/- keys)
- [ ] Mute toggle (keyboard: M key or dedicated button)
- [ ] Captions toggle (CC button with visible label)
- [ ] Audio description toggle (if AD available)
- [ ] Full screen toggle
- [ ] Seek/scrub bar (keyboard: Left/Right arrows; screen reader: time input)
- [ ] Playback speed control (0.5x, 1x, 1.5x, 2x)
- [ ] Forward/rewind buttons (5–10 second increments; keyboard accessible)

### Keyboard & Focus Management

- [ ] All controls focusable and operable by keyboard
- [ ] Tab order is logical: play → seek → volume → captions → fullscreen
- [ ] Tab trap: focus moves out of player with Tab; returns when tabbing back
- [ ] Enter/Space activates buttons and toggles
- [ ] Seek bar arrow keys move in 5–10 second increments
- [ ] Focus indicator visible and sufficient (min 3px, good contrast)
- [ ] Player controls visible when video is focused (not only on hover)

### ARIA for Custom Players

```html
<!-- Play/Pause Button -->
<button
  aria-label="Play"
  aria-pressed="false"
  id="play-btn"
>
  <!-- SVG icon -->
</button>

<!-- Seek Bar (Range Input) -->
<input
  type="range"
  aria-label="Seek"
  aria-valuemin="0"
  aria-valuemax="3600"
  aria-valuenow="0"
  aria-valuetext="0:00 of 1:00:00"
  id="seek-slider"
>

<!-- Captions Toggle -->
<button
  aria-label="Captions off"
  aria-pressed="false"
  id="captions-btn"
>
  CC
</button>

<!-- Volume Control -->
<input
  type="range"
  aria-label="Volume"
  aria-valuemin="0"
  aria-valuemax="100"
  aria-valuenow="70"
  id="volume-slider"
>
```

Update `aria-pressed`, `aria-valuenow`, and `aria-valuetext` dynamically via JavaScript as state changes.

### Autoplay Policy

- Never autoplay video with audio — violates WCAG 2.2.2 and user expectations
- If autoplay is required: `autoplay muted` only; must provide pause control within 3 seconds
- Autoplay for silent video (background/decorative): acceptable if paused by default
- Never autoplay any content with flashing (seizure risk per WCAG 2.3.1)

### Accessible Media Player Libraries & Frameworks

| Player | Cost | WCAG Compliance | Best for |
|--------|------|-----------------|----------|
| **Able Player** | Free, open source | AAA compliant | High accessibility requirements; AD support |
| **Plyr** | Free, open source | AA compliant out-of-box | Lightweight; good keyboard support |
| **Video.js** | Free, open source | AA with plugins | Flexible customization; large ecosystem |
| **JW Player** | Paid | AA compliant | Commercial licensing; broadcast quality |
| **Vimeo** | Freemium | AA compliant | Hosting + player; captions included |
| **YouTube** | Free | AA compliant | Hosting + live captions (auto-generated) |

### Players to Avoid

- Players with hover-only controls (controls disappear on blur)
- Players requiring mouse for basic operations (seek bar can't be accessed with keyboard)
- Players without native caption support
- Flash-based players (deprecated; no screen reader support)

---

## Audit Output Format

```
## Video & Media Accessibility Audit

**Content:** [title and platform]
**Type:** [Video / Audio / Podcast / Webinar / Live Stream]
**Duration:** [length]
**Standards:** WCAG 2.2 AA/AAA (1.2.x)
**Date:** [audit date]
**Auditor:** [name]

### Accessibility Score: [0–10]

**Breakdown:**
- Captions: [0–2]
- Transcripts: [0–2]
- Audio Description: [0–2]
- Player Controls: [0–2]
- Autoplay & Motion: [0–2]

### Compliance Summary

| Requirement | WCAG Level | Status | Notes |
|-------------|------------|--------|-------|
| Captions | A | ✓ Pass / ✗ Fail / N/A | Accurate, synced, speaker ID |
| Transcript | A | ✓ Pass / ✗ Fail / N/A | Descriptive / basic |
| Audio Description | AA | ✓ Pass / ✗ Fail / N/A | Covers all visual information |
| Live Captions | AA | ✓ Pass / ✗ Fail / N/A | Latency: [n] seconds |
| Player Keyboard | — | ✓ Pass / ✗ Fail | Tab order, focus visible |
| Autoplay | WCAG 2.2.2 | ✓ Pass / ✗ Fail | Autoplay with audio = fail |

### Caption Quality Assessment (if captions exist)

- **Accuracy:** [%] Examples: [list any errors found]
- **Timing:** [Pass / Issues] Response: [latency range]
- **Speaker ID:** [Present / Missing] Examples: [format used]
- **Sound Effects:** [Described / Missing] Examples: [sounds not captured]
- **Format:** [Pass / Issues] Examples: [readability, line length, emphasis]

### Transcript Assessment (if transcript exists)

- **Type:** [Basic / Descriptive]
- **Speaker ID:** [Present / Missing]
- **Sound Effects:** [Described / Missing / N/A]
- **Visual Descriptions:** [Present / Missing / N/A]
- **Placement:** [Same page / Link adjacent / Buried]
- **Findability:** [Discoverable / Hidden]

### Player Accessibility (if embedded)

- **Keyboard accessible:** [✓ Yes / ✗ No] Issues: [list]
- **Focus visible:** [✓ Yes / ✗ No] Examples: [states with no indication]
- **Caption toggle:** [✓ Visible / ✗ Hidden]
- **AD toggle:** [N/A / ✓ Visible / ✗ Hidden]
- **Autoplay:** [✓ Muted or disabled / ✗ With audio]
- **Mobile accessible:** [✓ Yes / ✗ No] Issues: [list]

### Critical Issues (0–3)
[Blocking accessibility; must fix before distribution]

### Major Issues (4–6)
[Significant usability impact; should fix before release]

### Minor Issues (7–9)
[Technical compliance items; nice-to-have improvements]

### Recommendations

**Immediate (1–2 weeks):**
1. [Fix captions / Add captions]
2. [Fix transcript issues]

**Near-term (1 month):**
1. [Add audio description]
2. [Improve player keyboard access]

**Long-term (Nice-to-have):**
1. [Add sign language interpretation]
2. [Improve transcript placement and discoverability]

### Testing Notes

[Any unexpected player behavior, screen reader issues, platform-specific notes]

### Sign-Off

- [ ] Captions reviewed for accuracy and timing
- [ ] Transcript present and discoverable
- [ ] Audio description present (AA) or transcript satisfactory (A alternative)
- [ ] Player keyboard accessible
- [ ] Autoplay compliant
- [ ] Content ready for distribution

```

---

## Reference & Resources

**WCAG 1.2.x Criteria:**
- https://www.w3.org/WAI/WCAG22/Understanding/#time-based-media

**Captioning Standards:**
- FCC Captioning Quality Standards: https://www.fcc.gov/consumers/guides/captioning
- EBU-TT Subtitle Format: https://tech.ebu.ch/publications/ebu-tt-part-1

**Audio Description Resources:**
- American Foundation for the Blind AD Guidelines: https://www.afb.org/blindness-and-low-vision/using-technology/assistive-technology-products/audio-description
- Described and Captioned Media Program: https://dcmp.org/

**Live Captioning Services:**
- CART providers: captions.com, nfcc.org
- Hybrid AI+Human: White Coat Captioning, CaptionSafe
- Platform built-in: Google Meet, Zoom, Microsoft Teams

**Media Players:**
- Able Player: https://ableplayer.github.io/ableplayer/
- Plyr: https://plyr.io/
- Video.js: https://videojs.com/

---

## Podcast Accessibility Focus

Podcasts are audio-only, requiring transcripts per WCAG 1.2.1 (A). Descriptive transcripts particularly valuable for:
- Listeners in sound-sensitive environments
- Non-native speakers
- Learning reinforcement through reading

**Podcast transcript best practices:**
- Include timestamps at natural breaks (every 1–2 minutes)
- Name speakers clearly on first mention
- Describe significant sounds: "[background music], [notification ping]"
- Link prominently from show notes
- Make searchable (not behind a paywall)
- Consider AI transcription services (Riverside.fm, Podpage, Transistor) for automation with human review

