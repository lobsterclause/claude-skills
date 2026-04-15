---
name: pdf-document-accessibility
description: Audit, remediate, and create accessible PDFs and documents — including tagged PDFs, reading order, headings, alt text for figures, form fields, tables, language declaration, and Section 508 document compliance. Use this skill whenever the user is working with PDFs, Word documents, PowerPoint files, or any downloadable document and needs to make it accessible. Trigger on phrases like "accessible PDF", "tagged PDF", "PDF accessibility", "document accessibility", "Word accessibility", "PowerPoint accessibility", "PDF remediation", "Section 508 document", "PDF/UA", "Acrobat accessibility", "PDF/UA-2", "document audit", or any request involving accessible documents.
category: audit
related-skills: alt-text-generator, accessible-tables, accessible-forms
---

# PDF & Document Accessibility

Documents are a massive accessibility gap in most organizations. PDFs generated from design tools, exported from Word, or scanned from paper are often completely inaccessible. Section 508 covers documents explicitly. A product that passes web accessibility can still expose users to inaccessible content through its downloadable files.

## Standards Framework

### PDF/UA Standards

**PDF/UA-1 (ISO 14289-1, 2014)**
- Current baseline standard for accessible PDFs
- Covers tagged structure, reading order, fonts, metadata, forms, alt text
- Most common compliance target for government and enterprise

**PDF/UA-2 (ISO 14289-2, 2024)**
- Updated standard addressing modern PDF requirements
- Enhanced support for complex content and media
- Stricter requirements for mathematical notation and complex tables
- Better metadata and semantic structure requirements
- More rigorous alt text and description standards
- Recommended for new PDFs; replaces PDF/UA-1 for new work

### WCAG 2.2 Applied to Documents

Documents must meet the same WCAG criteria as web content:
- 1.1 Text Alternatives (images require alt text)
- 1.3 Adaptability (structure, reading order, semantic meaning preserved)
- 1.4 Distinguishable (contrast, color not sole differentiator)
- 2.1 Keyboard Accessible (form fields, links, navigation)
- 2.4 Navigable (headings, bookmarks, skip navigation)
- 3.1 Readable (plain language, defined terms, language declared)
- 3.3 Input Assistance (form labels, error messages, validation)
- 4.1 Compatible (proper tagging, ARIA roles where applicable)

### Section 508 Document Requirements

Section 508 explicitly requires:
- Electronic documents must be accessible to users with disabilities
- All content must be available in alternative formats when requested
- Both the document and its downloadable format must be accessible

---

## The Tagged PDF Foundation

A tagged PDF has a logical structure tree that screen readers use to navigate. An untagged PDF is a flat image of content — a screen reader sees nothing meaningful.

### Tag Types

| Tag | Meaning | Usage |
|-----|---------|-------|
| `<H1>` – `<H6>` | Heading levels | Page title, section headers, subsections |
| `<P>` | Paragraph | Body text blocks |
| `<L>`, `<LI>`, `<Lbl>`, `<LBody>` | List, item, label, body | Bulleted and numbered lists |
| `<Table>`, `<TR>`, `<TH>`, `<TD>` | Table structure | Data tables (not layout tables) |
| `<Figure>` | Image or graphic | Photos, charts, diagrams |
| `<Caption>` | Caption for figure or table | Descriptive text below figures |
| `<Form>` | Form element container | Interactive form sections |
| `<Link>` | Hyperlink | URLs and cross-references |
| `<Artifact>` | Decorative content | Headers, footers, page numbers, borders |
| `<Span>` | Inline text | For applying specific styling to inline content |
| `<Sect>` | Section grouping | Logical document divisions |
| `<Art>` | Article | Self-contained article blocks |
| `<Note>` | Footnote or endnote | Reference notes at page or document end |
| `<TOC>`, `<TOCI>` | Table of contents, TOC item | Navigational table of contents |
| `<BibEntry>` | Bibliography entry | Reference citations |
| `<Quote>` | Block quotation | Extended quoted text |
| `<Code>` | Code block or inline code | Programming code, technical syntax |

---

## Accessibility Scoring System

Use this 0–10 framework to quantify document accessibility:

### Tagging & Structure (0–2 points)
- 2: Fully tagged with proper hierarchy; all headings, lists, tables correctly tagged
- 1: Partially tagged; some structure missing or incorrect
- 0: No tagging or completely incorrect structure

### Reading Order (0–2 points)
- 2: Reading order matches logical/visual sequence; multi-column layouts handled correctly
- 1: Reading order mostly correct but some issues with sidebars or complex layouts
- 0: Reading order nonsensical; makes document unusable for screen reader users

### Alt Text & Descriptions (0–1 point)
- 1: All informative images have descriptive alt text; complex images have extended descriptions
- 0: Missing, vague, or generic alt text; complex images lack descriptions

### Forms (0–1 point)
- 1: Form fields have visible labels, tooltips describe purpose and requirements, tab order is logical, validation messages are accessible
- 0: Form fields lack labels, tab order is chaotic, validation fails accessibly

### Language & Metadata (0–1 point)
- 1: Document language declared; passages in other languages marked with xml:lang; document title set
- 0: No language declaration; metadata missing or incorrect

### Tables (0–1 point)
- 1: Header rows marked as TH; column/row scope set; captions present; complex tables use ID/Headers attributes
- 0: Table headers marked as TD; scope missing; no captions; complex tables ambiguous

### Contrast (0–1 point)
- 1: Text meets 4.5:1 (AA) or 7:1 (AAA) contrast; color not sole conveyor of information
- 0: Low contrast text; color-dependent information

### Links (0–1 point)
- 1: All links are active; link text is descriptive and meaningful in isolation
- 0: "Click here" links; URL-only links; duplicate ambiguous link text

**Scoring Example:**
```
Document: Q3 Earnings Report PDF
- Tagging & Structure: 1/2 (headings present, but tables not properly tagged)
- Reading Order: 2/2 ✓
- Alt Text: 0/1 (charts have no descriptions)
- Forms: N/A
- Language & Metadata: 1/1 ✓
- Tables: 0/1 (headers not marked)
- Contrast: 1/1 ✓
- Links: 1/1 ✓
TOTAL: 6/10 — MAJOR issues with table accessibility and chart descriptions
```

---

## Audit Checklist

### Structure and Tags

- [ ] Document is tagged (File → Properties → Description → Tagged PDF: Yes)
- [ ] Tags panel shows logical structure tree matching visual content
- [ ] All headings tagged as H1–H6, not as bold paragraphs
- [ ] Heading hierarchy is logical — no skipped levels
- [ ] Lists tagged as L/LI, not as paragraphs with bullets
- [ ] Tables tagged with proper TR/TH/TD structure
- [ ] Decorative elements (rules, borders, background images) tagged as Artifact
- [ ] Page numbers and running headers tagged as Artifact
- [ ] Footnotes tagged as Note; endnotes at document end

### Reading Order

- [ ] Reading order in Order panel matches visual/logical reading order
- [ ] Multi-column layouts read column by column, not row by row
- [ ] Sidebars read after main content, not interspersed
- [ ] Captions immediately follow their figure in reading order
- [ ] Footnotes appear after the paragraph they reference

To check reading order in Acrobat: View → Show/Hide → Navigation Panels → Order

### Language

- [ ] Document language declared (File → Properties → Advanced → Language)
- [ ] Passages in other languages tagged with `xml:lang` attribute
- [ ] Language declaration matches actual content language
- [ ] Abbreviations defined on first use

### Title and Metadata

- [ ] Document title set (File → Properties → Description → Title)
- [ ] "Display document title" enabled in Initial View settings (not filename)
- [ ] Title is descriptive ("2024 Annual Report" not "Document1")
- [ ] Author, subject, and keywords populated in metadata if applicable

### Images and Figures

- [ ] All informative images have Alt Text in the Figure tag
- [ ] Decorative images tagged as Artifact or have empty Alt Text ("")
- [ ] Complex images (charts, diagrams, infographics) have extended description
- [ ] Alt text does not begin with "Image of" or "Picture of"
- [ ] Charts include the key data finding in alt text or caption
- [ ] Sufficient contrast in image content (if readable text)

To set alt text in Acrobat: Right-click figure in Tags panel → Properties → Alt Text

### Links and Navigation

- [ ] All hyperlinks are active (not just underlined text)
- [ ] Link text is descriptive (not "click here" or "more info")
- [ ] URL-only links have a readable URL that conveys destination
- [ ] Bookmarks panel populated for documents over 10 pages
- [ ] Bookmarks mirror heading structure and are navigable
- [ ] Internal cross-references are linked, not just text references

### Color and Contrast

- [ ] Text contrast meets 4.5:1 (AA) or 7:1 (AAA) at normal viewing size
- [ ] Color not used as sole means of conveying information
- [ ] Charts and diagrams use patterns or labels, not color alone
- [ ] Sufficient contrast in images and graphics

### Tables

- [ ] Header row tagged as TH, not TD
- [ ] Column headers have `Scope` attribute set to "Column"
- [ ] Row headers have `Scope` attribute set to "Row"
- [ ] Complex tables (colspan/rowspan) use ID/Headers attributes
- [ ] Table has a Caption or accessible name
- [ ] No layout tables — use actual paragraph/column structure instead

### Forms (PDF Forms)

- [ ] All form fields have tooltip/description set (visible label equivalent)
- [ ] Required fields indicated in tooltip
- [ ] Tab order matches visual order (Tab Order panel in Acrobat)
- [ ] Error validation messages are accessible and linked to fields
- [ ] Submit button present and keyboard accessible
- [ ] Form can be completed with keyboard only
- [ ] Text inputs accept plain text; avoid fields requiring special formatting

To check form tab order in Acrobat: Prepare Form → right-click field → Properties → General

### Fonts and Text

- [ ] All fonts are embedded (File → Properties → Fonts — all should show "Embedded Subset")
- [ ] Text is actual text, not bitmap/rasterized text (not an image of text)
- [ ] Scanned documents have been OCR'd with accurate text recognition
- [ ] Text can be selected and copied
- [ ] Special characters and symbols are correctly represented (not missing or corrupted)

---

## Creating Accessible PDFs from Source

### From Microsoft Word

**Before exporting:**
- [ ] Use built-in Heading styles (H1–H6), not manual bold/size formatting
- [ ] Use built-in List styles (Bulleted List, Numbered List)
- [ ] Add Alt Text to all images (right-click → Alt Text → provide descriptive text)
- [ ] Set document language (Review → Language → Set Proofing Language)
- [ ] Set document title (File → Properties → Summary → Title field)
- [ ] Use proper table structure with header rows marked (Table Design → Header Row checkbox)
- [ ] Check with Word Accessibility Checker (Review → Check Accessibility)
- [ ] Use actual hyperlinks, not underlined text
- [ ] Avoid color-only formatting; always add labels or patterns

**Exporting:**
1. File → Save As → PDF
2. Click Options
3. Check "Document structure tags for accessibility"
4. Check "Create bookmarks from headings"
5. Save

CRITICAL: Do NOT print to PDF — this strips all structure and makes PDFs inaccessible.

### From Adobe InDesign

**Before exporting:**
- [ ] Use Paragraph Styles with proper Export Tags (map styles to H1, H2, P, etc.)
- [ ] In Paragraph Style dialog: Edit → Export Tagging → set to appropriate heading level
- [ ] Add Alt Text to all placed images (Object → Object Export Options → Alt Text tab)
- [ ] Mark decorative elements as Artifact (Object → Object Export Options → Tagged PDF → Artifact)
- [ ] Set document language (File → Document Setup → Language dropdown)
- [ ] Use Articles panel to define reading order (Window → Articles)
- [ ] Create bookmarks from TOC if document has table of contents (File → Create PDF Bookmarks)

**Exporting:**
1. File → Export
2. Format: Adobe PDF
3. Click "Save"
4. In PDF Export dialog: go to Advanced tab
5. Check "Create Tagged PDF"
6. Check "Create Bookmarks"
7. Verify that "Acrobat 10 and later" is selected for compatibility
8. Export

### From PowerPoint

**Before exporting:**
- [ ] Use built-in slide layouts (not blank slides with manually positioned elements)
- [ ] Verify Outline view shows proper slide titles and reading order
- [ ] Add Alt Text to all images (right-click → Edit Alt Text)
- [ ] Mark decorative elements as decorative in Alt Text dialog (checkbox)
- [ ] For complex graphics, add longer descriptions in Notes section
- [ ] Check with PowerPoint Accessibility Checker (Review → Check Accessibility)
- [ ] Set presentation title and metadata (File → Properties → Title field)
- [ ] Use slide master for headers/footers (these become Artifacts)

**Exporting:**
1. File → Export → Create PDF
2. Click "Options"
3. Check "Document structure tags for accessibility"
4. Check "Create bookmarks from headings"
5. Click Save

---

## Remediating Existing PDFs in Acrobat Pro

### Workflow Order

1. Run automated accessibility check (All Tools → Prepare for Accessibility → Accessibility Check)
2. Review check results and note priorities
3. Fix tagging issues in Tags panel
4. Fix reading order in Order panel
5. Set document properties (title, language, author)
6. Add alt text to figures
7. Fix table structure and headers
8. Verify link text is descriptive
9. Check form tab order and validation
10. Run accessibility check again
11. Test with screen reader (NVDA or JAWS)

### Common Remediation Tasks

**Adding tags to untagged PDF:**
- All Tools → Prepare for Accessibility → Autotag Document
- Note: Autotag is a starting point, not a final fix. Always review and correct the output.
- Open Tags panel and manually fix any incorrectly tagged elements

**Fixing reading order:**
- All Tools → Prepare for Accessibility → Reading Order
- Open Reading Order panel
- Drag elements to correct sequence
- Test by navigating with arrow keys to verify order

**Setting alt text:**
- Tags panel → find `<Figure>` → right-click → Properties → Alternate Text
- Write descriptive alt text (see alt-text-generator skill for guidance)
- For complex images, use "Append Description as Contents" option

**Marking artifacts:**
- Tags panel → find decorative element → right-click → Change Tag to Artifact
- OR: Reading Order panel → click element → "Background/Artifact"
- Common artifacts: page numbers, headers, footers, decorative rules

**Fixing table headers:**
- Tags panel → expand `<Table>`
- Find cells that should be headers but are tagged as `<TD>`
- Right-click → Change Tag to TH
- Right-click → Properties
- Set Scope = Column (for column headers) or Row (for row headers)
- For complex tables: set ID on headers and Headers on data cells

**Removing incorrect links:**
- Tags panel → find `<Link>` → right-click → Delete
- OR: Content panel → find blue link box → right-click → Delete Link
- Re-create as actual PDF link using Link tool (Tools → Edit PDF → Link)

---

## Testing Tools Comparison

### Automated Testing Tools

| Tool | Cost | What it tests | Strengths | Limitations | Best for |
|------|------|---------------|-----------|------------|----------|
| **Acrobat Pro Accessibility Checker** | $180/year | WCAG, PDF/UA, Section 508 | Built into Acrobat; comprehensive | Requires Acrobat Pro | Initial audit; quick pass/fail |
| **PAC 2024** | Free | PDF/UA-1, PDF/UA-2 compliance | Most thorough PDF/UA validation; free; generates detailed reports | Slower; text-heavy interface | Gold standard for PDF/UA testing |
| **axesPDF** | Paid (~$500/year) | WCAG, PDF/UA, Section 508 | Fast; good remediation suggestions; batch processing | Expensive; enterprise-focused | Large-scale document auditing |
| **CommonLook PDF** | Paid (~$800+/year) | WCAG, PDF/UA, Section 508 | Enterprise-grade; batch remediation; VLT integration | High cost; learning curve | Enterprise document workflows |
| **PDFUA Online Checker** | Free | PDF/UA validation | Lightweight; cloud-based; no installation | Less detailed than PAC; limited free tier | Quick validation without download |

### Screen Reader Testing

| AT | Cost | Platform | Best for |
|----|------|----------|----------|
| **NVDA** | Free | Windows, Linux | Most common; free screen reader testing |
| **JAWS** | $1200+/license | Windows | Enterprise standard; most comprehensive |
| **VoiceOver** | Included | macOS, iOS, watchOS | Apple ecosystem; built-in to all Apple devices |
| **TalkBack** | Included | Android | Mobile PDF testing; free with Android |
| **Narrator** | Included | Windows | Basic Windows testing; limited PDF support |

### Recommended Testing Sequence

1. **Fast check:** Acrobat Pro Accessibility Checker (5 minutes)
2. **Thorough validation:** PAC 2024 (10–15 minutes) — free, most comprehensive
3. **Screen reader verification:** NVDA on Windows or VoiceOver on Mac (15–20 minutes)
4. **User testing:** Have someone using actual AT navigate and complete tasks (30–60 minutes)

---

## Scanned Documents

Scanned PDFs (image-only PDFs) are completely inaccessible without remediation. A screen reader sees a blank page.

### OCR & Remediation Path

1. **Run OCR in Acrobat Pro:**
   - All Tools → Scan & OCR → Recognize Text
   - Select "All Pages" or range
   - Acrobat will extract text from the scanned image
   - This may take several minutes for large documents

2. **Verify OCR accuracy:**
   - Spot-check a few pages by selecting text and reviewing recognition
   - Look for character recognition errors (especially in tables, narrow columns)
   - If accuracy is poor (under 85%), consider document recreation instead

3. **Add tags:**
   - All Tools → Prepare for Accessibility → Autotag Document
   - This creates initial structure from OCR text
   - Tags will be imperfect; plan to hand-correct

4. **Fix reading order:**
   - Review Order panel and adjust element sequence

5. **Add alt text:**
   - For any actual images/charts in the original scanned document

6. **Fix table structure:**
   - Re-examine tables for correct header/data cell mapping

7. **Run accessibility check again:**
   - Verify improvements; address remaining issues

### When to Recreate Instead of Remediate

Consider recreating the document from source if:
- OCR accuracy is below 85% (unusual fonts, handwriting, very low quality scans)
- Document is highly formatted with complex tables or charts
- Original source document is available and accessible
- Cost of remediation exceeds cost of recreation

---

## Word-to-PDF and InDesign-to-PDF Accessibility Pipelines

### Word → PDF Best Practices

**Quality assurance before export:**
```
Accessibility Check (Review → Check Accessibility) 
→ Fix all errors and warnings 
→ Preview as PDF (File → Export → Preview) 
→ Save As PDF with structure tags enabled
```

**Common Word-to-PDF issues:**
- Page breaks from manual line breaks (use Format → Page Break instead)
- Headings applied with styling only (use actual Heading styles from Home tab)
- Tables with merged cells (keep tables simple; avoid merges where possible)
- List formatting applied manually (use List styles from Home tab)

### InDesign → PDF Best Practices

**Quality assurance before export:**
```
Preflight check (File → Preflight) 
→ Verify all fonts embedded 
→ Export with "Create Tagged PDF" enabled 
→ Run PAC 2024 on export
```

**Common InDesign-to-PDF issues:**
- Text frames not set to "Paragraph style exports tag"
- Images not having alt text set (Object → Object Export Options)
- Tables with grouped cells or complex headers
- Master page elements not marked as Artifact

---

## Audit Output Format

```
## PDF/Document Accessibility Audit

**Document:** [filename and version]
**Type:** [PDF / Word / PowerPoint / other]
**Pages:** [n]
**File Size:** [size MB]
**Standards:** PDF/UA-2, WCAG 2.2 AA, Section 508
**Date:** [audit date]
**Auditor:** [name]

### Accessibility Score: [0–10]

**Breakdown:**
- Tagging & Structure: [0–2]
- Reading Order: [0–2]
- Alt Text & Descriptions: [0–1]
- Forms: [0–1]
- Language & Metadata: [0–1]
- Tables: [0–1]
- Contrast: [0–1]
- Links: [0–1]

### Quick Assessment
- Tagged: [Yes / No / Partial]
- Reading Order: [Correct / Issues Found / Not Verifiable]
- Language Declared: [Yes / No]
- Title Set: [Yes / No]
- OCR Accuracy (if scanned): [N/A / Accurate / Issues]

### Critical Issues (0–5 priority)
[P0–P2 findings that block accessibility; must fix before distribution]

### Major Issues (5–7 priority)
[P2–P3 findings; significant usability impact]

### Minor Issues (8–10 priority)
[P4+ findings; technical compliance items]

### Image Inventory
| Page | Description | Alt Text Present | Quality | Notes |
|------|-------------|-----------------|---------|-------|
| 1 | Product chart | Yes | Good | Key data in alt text |
| 2 | Team photo | Yes | Poor | Generic description |

### Table Inventory
| Page | Table Description | Headers Tagged | Complexity | Status |
|------|-------------------|-----------------|-----------|--------|
| 5 | Q3 Financial Summary | Yes | Simple | Pass |
| 8 | Complex Budget Matrix | Partial | Complex (rowspan/colspan) | Requires remediation |

### Form Assessment (if applicable)
- [ ] Form fields labeled
- [ ] Required fields marked
- [ ] Tab order logical
- [ ] Validation messages accessible
- [ ] Submit button present

### Remediation Priority & Effort

| Priority | Issue | Location | Fix | Effort | WCAG Criterion |
|----------|-------|----------|-----|--------|----------------|
| P0 | Missing alt text on critical chart | Page 3 | Add descriptive alt text | 15 min | 1.1.1 |
| P1 | Table headers not marked | Page 8 | Tag headers as TH, set Scope | 30 min | 1.3.1 |
| P2 | Reading order incorrect | Pages 2–4 | Drag elements in Order panel | 20 min | 1.3.2 |
| P3 | Low contrast in footer | All pages | Increase contrast ratio to 4.5:1 | 10 min | 1.4.3 |

### Tools Used

| Tool | Version | Results |
|------|---------|---------|
| Acrobat Pro Accessibility Checker | 2024.x | [n] errors, [n] warnings |
| PAC 2024 | 2024.x | PDF/UA-2 compliance: [Pass / Fail] |
| NVDA | 2024.x | Screen reader testing: [Pass / Fail] |

### Recommendations

1. [Specific, actionable next step with estimated time]
2. [Next priority item]
3. [Nice-to-have improvement]

### Testing Notes

[Which tools were used; screen reader behavior observations; any unexpected issues]

### Export Certification

- [ ] Document meets PDF/UA-2 standard
- [ ] Document meets WCAG 2.2 AA level
- [ ] Document is compliant with Section 508
- [ ] Document tested with screen reader
- [ ] Ready for distribution
```

---

## Reference Resources

- **PDF/UA Standard:** https://www.iso.org/standard/79143.html (PDF/UA-2) / https://www.iso.org/standard/54564.html (PDF/UA-1)
- **PAC 2024 (free):** https://www.pdfua.foundation/ — download the free PDF/UA compliance checker
- **Adobe Acrobat Accessibility:** https://www.adobe.com/accessibility/products/acrobat.html
- **WCAG 2.2:** https://www.w3.org/WAI/WCAG22/Understanding/
- **Section 508:** https://www.access-board.gov/ict/
- **WebAIM PDF Accessibility:** https://webaim.org/articles/pdf/

