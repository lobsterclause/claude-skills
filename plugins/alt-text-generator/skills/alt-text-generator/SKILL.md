---
name: alt-text-generator
description: Generate accurate, context-aware alt text for images. Use this skill whenever the user shares an image or describes one and asks for alt text, image descriptions, figure captions, or accessible image annotations. Also trigger when the user asks about whether an image is decorative, needs a long description, or how to describe a chart, graph, infographic, diagram, screenshot, product photo, portrait, illustration, icon, social media image, or e-commerce image. Trigger on phrases like "write alt text", "describe this image", "what should the alt be", "is this decorative", "long description", "accessible image", "figure caption", "alt for chart", "product image alt", "social media accessibility", or "screen reader description". Goes beyond generic descriptions — alt text is context-dependent and purposeful.
---

# Alt Text Generator Skill

You write alt text that serves its purpose — not alt text that simply describes what's visibly present. The same image can require completely different alt text depending on context, audience, and intent.

## The Core Principle

Alt text is a functional substitute, not a caption. Ask: *what information would a sighted user get from this image that a screen reader user would miss?* That gap is what alt text fills.

---

## Step 1: Classify the Image

Before writing anything, determine the image type and purpose.

### Decorative
No information is conveyed. Alt text = "" (empty string — NOT omitted entirely).

Decorative examples:
- Background textures, dividers, flourishes
- Purely aesthetic photos that duplicate surrounding text
- Stock photos used as visual filler with no informational value
- Icons that are paired with visible text labels
- Spacer images

```html
<img src="divider.svg" alt="">
```

### Informative
Conveys content not available in surrounding text. Needs descriptive alt text.

### Functional
The image is a link, button, or control. Alt text describes the action, not the image.

```html
<a href="/search"><img src="search-icon.svg" alt="Search"></a>
<!-- NOT alt="magnifying glass icon" -->
```

### Complex
Charts, graphs, diagrams, infographics, maps, schematics. Requires both a short alt and a long description.

### Text in Images
If the image contains text that isn't available elsewhere, the alt must include that text verbatim.

---

## Step 2: Gather Context

Ask these questions if not already clear from the user's message:

1. Where does this image appear? (article, product page, dashboard, marketing email, form, documentation, social media)
2. What is the surrounding text? (alt text should not repeat what's already written nearby)
3. Who is the audience? (general public, professionals, children, etc.)
4. What is the purpose of the image in this context — informational, emotional, functional, proof of concept?
5. Is the image a link or button?
6. Is this image meant for social sharing?

---

## Step 3: Write to Context

### General Informative Images

**Structure:** Lead with the most important information. Include what's relevant; omit what's not.

**Rules:**
- Do not start with "Image of", "Picture of", "Photo of" — screen readers already say "image"
- Do not end with "image" or "photo"
- Match the reading level and tone of the surrounding content
- Keep under 150 characters when possible; go longer only when necessary
- Do not duplicate text that already appears in a nearby heading, caption, or body copy
- Be specific; avoid generic descriptions

**Good examples:**

| Image | Context | Alt Text |
|-------|---------|----------|
| Photo of a smiling woman at a desk | Team page bio | "Priya Sharma, Head of Product, seated at her desk" |
| Same photo | Article about remote work | "A person working from a home office" |
| Company headquarters building | About page | "ZAG headquarters in Austin, Texas" |
| Man using a white cane on a crosswalk | Accessibility article | "A blind pedestrian navigating a crosswalk using a white cane" |
| Red error icon next to a form field | UI component | "Error:" (error description follows in adjacent text) |
| Product shot: white sneaker | E-commerce listing | "Nike Air Force 1 Low in white leather, right shoe, side view" |
| Team photo with diverse members | Recruitment page | "Team of engineers and designers at company headquarters, representing diverse backgrounds" |

### Charts and Data Visualizations

For simple charts: state the key finding or trend, not the chart structure.

```
alt="Monthly signups increased from 1,200 in January to 4,800 in June 2024"
```

For more complex charts, use a two-part approach:

```html
<figure>
  <img
    src="q2-revenue-chart.png"
    alt="Q2 revenue by region — North America led with 4.2 million dollars"
    aria-describedby="chart-desc"
  >
  <figcaption id="chart-desc">
    Bar chart showing Q2 2024 revenue by region. North America: $4.2M (22% YoY growth).
    Europe: $2.8M (14% YoY growth). Asia-Pacific: $1.9M (8% YoY growth).
    Latin America: $0.6M (3% YoY growth). Total: $9.5M (18% growth overall).
  </figcaption>
</figure>
```

**Chart-specific patterns:**

| Chart Type | Alt Text Approach | Example |
|-----------|-------------------|---------|
| Line chart | State the trend over time | "Website traffic increased 45% quarter-over-quarter from Q1 to Q2 2024" |
| Bar chart | State highest/lowest and comparison | "Product A revenue (2.5M) exceeded Product B (1.8M) in Q2" |
| Pie chart | State largest segment and key breakdown | "Q2 spending: 45% engineering, 30% marketing, 15% operations, 10% admin" |
| Scatter plot | State correlation or pattern | "Customer age and lifetime value show positive correlation; older customers spend more" |
| Heatmap | State what's most/least intense | "Support ticket density highest in East region (red), lowest in West (green)" |
| Map | State geographic pattern or data focus | "Sales growth concentrated in urban areas (dark blue) vs rural (light blue)" |

### Infographics

Infographics require both short alt text (the key insight) and a long description (structured walkthrough).

```html
<img
  src="design-process-infographic.png"
  alt="Five-stage design process from research to launch"
  aria-describedby="infographic-desc"
>
<div id="infographic-desc" class="sr-only">
  <h3>Design Process Stages</h3>
  <ol>
    <li><strong>Discover:</strong> User interviews, competitive analysis, stakeholder alignment</li>
    <li><strong>Define:</strong> Problem statement, personas, success metrics</li>
    <li><strong>Ideate:</strong> Sketching, wireframing, design sprints</li>
    <li><strong>Build:</strong> Prototyping, design system, handoff to development</li>
    <li><strong>Launch:</strong> QA, accessibility review, deployment, analytics setup</li>
  </ol>
  <p>Flow arrows between stages indicate feedback loops from testing and validation.</p>
</div>
```

### Screenshots & UI

Describe what's visible and what's notable about the state shown.

```
alt="Claude.ai chat interface showing a conversation about accessibility audit, with the Assistant explaining WCAG criteria in a code block"

alt="Login form with error state: email field has red border, error message reads 'Invalid email format. Did you mean @gmail.com?'"

alt="Empty state: inbox showing 'No messages yet. Create a new conversation to get started' with a blue 'New conversation' button"

alt="Mobile navigation menu open, showing links: Home, Profile, Settings, Logout. Menu overlays main content area"
```

### Portraits and People

**Default approach:** Name and role if known and relevant. Physical description only when it adds information.

```
"Marcus Johnson, Senior Engineer, speaking at the 2024 team offsite"
"Sarah Chen, UX researcher, sitting in a cafe"
"Diverse group of developers laughing during a team brainstorm session"
```

When to include physical description:
- Disability is relevant to the context (accessibility article, representation in healthcare)
- Audience context makes it meaningful (casting agency, ID verification, diversity report)
- The image is illustrative of a characteristic being discussed in the text

When in doubt, describe role/action over appearance.

### Icons

**Paired with visible text:** `alt=""`
**Standalone (functional):** alt = the action
**Standalone (informative):** alt = what it communicates

```html
<!-- Paired with visible "Download report" label -->
<img src="download.svg" alt="">

<!-- Standalone download button -->
<button><img src="download.svg" alt="Download report"></button>

<!-- Status icon -->
<img src="check-green.svg" alt="Confirmed">

<!-- Warning icon -->
<img src="exclamation.svg" alt="Warning:">
```

### Logos

Used as image only: company name
Used as link: destination

```html
<img src="acme-logo.svg" alt="Acme Corp">
<a href="/"><img src="acme-logo.svg" alt="Acme Corp homepage"></a>
```

### E-Commerce Product Images

Include sufficient detail for the user to understand what they're looking at:

```
alt="Blue Adidas Ultraboost 22 running shoe, right shoe, three-quarter view showing Boost sole"

alt="Ceramic dinner plate, white, 10-inch diameter, flat rim, dishwasher safe"

alt="Wool blend blazer in charcoal gray, size medium, showing front buttons and lapels"

alt="Apple AirPods Pro charging case, white, open position showing both earbuds seated in charging slots"
```

### Social Media Images (Twitter/X, Instagram, LinkedIn)

Keep within platform character limits and be explicit about what viewers will see:

**Twitter/X (280 characters):**
```
alt="Screenshot of GitHub PR showing 'Improve form accessibility' with 200 lines added, 50 removed"

alt="Chart showing web accessibility adoption: 2018 (32%), 2020 (45%), 2022 (58%), 2024 (71%)"
```

**Instagram (no native alt text):**
Use caption to describe image, or use Instagram's "Alt Text" feature (Settings > Accessibility > Alt Text):
```
alt="Team of five engineers at office standing in front of a whiteboard covered with accessibility audit notes"
```

**LinkedIn (character limit generous):**
```
alt="Infographic: 'The ROI of Accessibility' showing 5 key statistics and business benefits of accessible design"
```

### Diagrams, Wireframes, and Architectural Drawings

```
alt="System architecture diagram showing user interface layer connecting to API gateway, which routes to microservices: auth, users, products, orders"

alt="Mobile app wireframe showing header with logo and menu icon, main content area with product grid (6 items per row), and bottom navigation bar with 5 tabs"

alt="Flowchart of checkout process: cart review → shipping address → payment info → order summary → confirmation page, with back navigation arrows"
```

### Data-Rich Images

For images containing tables, statistics, or other quantitative data:

**Short alt:**
```
alt="2024 accessibility maturity matrix showing adoption rates by organization size"
```

**Long description:**
```html
<figure>
  <img src="matrix.png" alt="2024 accessibility maturity matrix showing adoption rates by organization size" aria-describedby="matrix-desc">
  <figcaption id="matrix-desc">
    <table>
      <tr>
        <th>Organization Size</th>
        <th>WCAG AA Compliance</th>
        <th>Automated Testing</th>
        <th>AT Testing (Manual)</th>
      </tr>
      <tr>
        <td>Startup (&lt;50)</td>
        <td>28%</td>
        <td>35%</td>
        <td>12%</td>
      </tr>
      <!-- ... more rows ... -->
    </table>
  </figcaption>
</figure>
```

---

## Long Description Authoring Guidance

When an image requires more than 150 characters of description, use one of these methods:

### 1. Adjacent Text (Visible to All)
```html
<img src="complex-diagram.png" alt="System architecture diagram with five layers" />
<p>
  The architecture consists of: Frontend layer (React SPA), API Gateway (routing and authentication),
  Microservices layer (auth service, user service, product service, order service), Data layer
  (PostgreSQL, Redis cache), and monitoring (logs and metrics).
</p>
```

### 2. Figcaption (Within Figure)
```html
<figure>
  <img src="chart.png" alt="Q2 2024 sales by region" />
  <figcaption>
    Regional sales breakdown: North America $4.2M (47%), Europe $2.8M (31%), APAC $1.9M (21%), LATAM $0.6M (1%).
    North America shows strongest YoY growth at 22%.
  </figcaption>
</figure>
```

### 3. aria-describedby (Visible or Hidden)
```html
<img src="infographic.png" alt="Five-stage design process" aria-describedby="process-desc" />
<div id="process-desc" class="sr-only">
  <!-- Long description here; hidden from sighted users but read by screen readers -->
</div>
```

### 4. Details/Summary (Progressive Disclosure)
```html
<figure>
  <img src="detailed-chart.png" alt="Market analysis 2024" />
  <details>
    <summary>Detailed breakdown</summary>
    <p>Market segment A grew 15% due to...</p>
    <!-- More details -->
  </details>
</figure>
```

---

## AI-Generated Alt Text Quality Audit Criteria

If using AI to generate alt text, verify the output against these criteria:

| Criterion | Good | Bad | Score |
|-----------|------|-----|-------|
| **Accuracy** | Describes what's actually in image | Hallucinates details not present | ✓/✗ |
| **Relevance** | Focuses on relevant elements for context | Describes decorative background equally | ✓/✗ |
| **Specificity** | Includes identifying details | Generic ("a person", "a chart") | ✓/✗ |
| **Brevity** | Under 150 characters where possible | Overly long; includes caption | ✓/✗ |
| **No Redundancy** | Doesn't repeat adjacent text | Repeats nearby heading or caption | ✓/✗ |
| **Appropriate Tone** | Matches document context | Too formal/casual for context | ✓/✗ |
| **Accessibility Focus** | Explains what sighted users see | Describes obvious visual properties | ✓/✗ |

---

## Common Mistakes to Avoid

| Mistake | Example | Fix |
|---------|---------|-----|
| Restating visible text | Image next to "Download our guide" has alt="Download our guide" | alt="" (decorative in this context) |
| Starting with "Image of" | alt="Image of a dog" | alt="Golden retriever puppy sitting in grass" |
| Over-describing | 200-word alt for a simple icon | Keep it to the relevant information; use long description for complex images |
| Under-describing | alt="chart" for a complex data visualization | State the key finding; add long description for details |
| Describing appearance instead of meaning | alt="red circle" for an error indicator | alt="Error" |
| Forgetting state | Screenshot alt doesn't mention error state shown | Include visible UI state in alt text |
| Omitting alt entirely | `<img src="photo.jpg">` | Always include alt attribute, even if empty |
| Misusing alt for SEO | alt="brown leather shoes men's loafers brown leather shoes cheap shoes online" | Write for accessibility, not keyword stuffing |
| AI hallucination | AI generates details not in image (faces, text, logos that aren't there) | Always review AI-generated alt text against the actual image |

---

## Output Format

When generating alt text for a single image:

```
## Alt Text

**Classification:** [Decorative / Informative / Functional / Complex]
**Context:** [Where this image appears, surrounding content]

**Short alt (for alt attribute):**
"[text here]"

**Long description (if needed):**
[Full structured description for aria-describedby, figcaption, or adjacent text]

**HTML:**
```html
[ready-to-use code snippet]
```

**Notes:**
[Context-specific reasoning — why this was written this way, what assumptions were made, what to change if context differs]
```

When generating alt text for multiple images (batch):

```
## Alt Text Batch

| # | Image | Classification | Alt Text |
|---|-------|----------------|----------|
| 1 | [description] | Informative | "..." |
| 2 | [description] | Decorative | "" |
| 3 | [description] | Complex | "..." (long description below) |

### Images Requiring Long Descriptions

**Image 3:** [Chart / Infographic / Diagram name]
[Full structured long description]

### Social Media Alt Text

| Platform | Image | Alt Text (with character limit) |
|----------|-------|--------------------------------|
| Twitter | [description] | "..." (280 char max) |
| Instagram | [description] | "..." (via alt text feature) |
| LinkedIn | [description] | "..." |
```

---

## Cross-References

- **accessibility-copy:** Write error messages, labels, and other microcopy accessibly
- **accessibility-audit:** Conduct comprehensive accessibility audits including alt text review
- **pdf-document-accessibility:** Alt text for images within PDF documents
- **mobile-touch-auditor:** Alt text for images in mobile apps and responsive designs
- **screen-reader-scripting:** Test alt text with NVDA, JAWS, VoiceOver to ensure proper announcements

