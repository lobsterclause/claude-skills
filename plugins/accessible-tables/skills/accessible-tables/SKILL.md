---
name: accessible-tables
description: Design, code, and audit accessible data tables — including complex headers, scope, summaries, responsive patterns, responsive strategies, editable cells, filtering, and screen reader behavior. Use this skill whenever the user is building or reviewing any HTML table, data grid, comparison table, schedule, pricing table, data dashboard, spreadsheet-like UI, or tabular data presentation. Trigger on phrases like "accessible table", "data table", "table headers", "scope attribute", "colspan", "rowspan", "complex table", "responsive table", "comparison table", "pricing table", "schedule", "screen reader table", "virtual table", "infinite scroll", "editable cells", "inline editing", "filter table", or any request involving tabular data. Covers WCAG 2.2 AAA, Section 508, real screen reader behavior across NVDA, JAWS, and VoiceOver, data grids, virtualization, and modern responsive table patterns.
---

# Accessible Data Tables

Tables are one of the most misused HTML patterns. Inaccessible tables are nearly unusable with a screen reader. Done correctly, a table is a powerful navigational structure.

## Core Principle

Use tables for tabular data — information with a meaningful relationship between rows and columns. Never use tables for layout. A screen reader user navigates tables cell by cell; each cell must make sense with its headers as context.

---

## Data Grid vs Layout Table Decision Tree

```
Is this tabular data?
├─ YES: Is it primarily for visual layout/spacing (not semantic data)?
│  ├─ YES: Use CSS layout (grid, flexbox); do NOT use <table> with role="presentation"
│  └─ NO: Continue below
└─ NO: Use semantic HTML (divs, sections, lists); not a table

Is the table simple (one row of column headers, one column of row headers)?
├─ YES: Use <th scope="col"> and <th scope="row">; caption; thead/tbody/tfoot
└─ NO: Continue below

Do headers span multiple rows or columns (colspan/rowspan)?
├─ YES: Use <th> with id; <td> with headers="id1 id2 id3"
└─ NO: Use scope suffices

Is this a complex data grid with interactive cells (edit, drag, sort)?
├─ YES: Use <table role="grid">; implement keyboard arrow navigation
└─ NO: Use standard table semantics

Is this a virtualized table (infinite scroll, rendering only visible rows)?
├─ YES: Use role="grid"; implement aria-rowindex and aria-colindex; ensure keyboard nav works
└─ NO: Use standard table

Is this table responsive (mobile)?
├─ YES: Choose: horizontal scroll, stacked cards, priority columns, or hybrid
└─ NO: Standard table is fine
```

---

## Simple Tables

For tables with one row of headers and one column of headers:

```html
<table>
  <caption>Q2 2024 Sales by Region</caption>
  <thead>
    <tr>
      <th scope="col">Region</th>
      <th scope="col">Revenue</th>
      <th scope="col">Units Sold</th>
      <th scope="col">YoY Growth</th>
    </tr>
  </thead>
  <tbody>
    <tr>
      <th scope="row">North America</th>
      <td>$4.2M</td>
      <td>12,400</td>
      <td>+22%</td>
    </tr>
    <tr>
      <th scope="row">Europe</th>
      <td>$2.8M</td>
      <td>8,100</td>
      <td>+14%</td>
    </tr>
  </tbody>
  <tfoot>
    <tr>
      <th scope="row">Total</th>
      <td>$9.5M</td>
      <td>28,300</td>
      <td>+18%</td>
    </tr>
  </tfoot>
</table>
```

### Required Elements
- `<caption>` — the table's accessible name; always provide it
- `<thead>`, `<tbody>`, `<tfoot>` — structural grouping; required for screen reader table navigation
- `scope="col"` on column headers
- `scope="row"` on row headers
- `<th>` for all headers, `<td>` for all data cells

---

## Complex Tables (Colspan / Rowspan)

When headers span multiple columns or rows, use `id` and `headers` attributes:

```html
<table>
  <caption>Employee Schedule — Week of March 3</caption>
  <thead>
    <tr>
      <th id="emp" scope="col">Employee</th>
      <th id="mon" scope="col" colspan="2">Monday</th>
      <th id="tue" scope="col" colspan="2">Tuesday</th>
    </tr>
    <tr>
      <td></td>
      <th id="mon-in" headers="mon" scope="col">In</th>
      <th id="mon-out" headers="mon" scope="col">Out</th>
      <th id="tue-in" headers="tue" scope="col">In</th>
      <th id="tue-out" headers="tue" scope="col">Out</th>
    </tr>
  </thead>
  <tbody>
    <tr>
      <th id="alice" scope="row">Alice</th>
      <td headers="mon mon-in alice">9:00 AM</td>
      <td headers="mon mon-out alice">5:00 PM</td>
      <td headers="tue tue-in alice">9:00 AM</td>
      <td headers="tue tue-out alice">5:00 PM</td>
    </tr>
  </tbody>
</table>
```

Screen readers will announce: "Alice, Monday In, 9:00 AM" — every cell gets its full header context.

### When to Use id/headers vs scope
- Simple (one header row, one header column): `scope` is sufficient
- Any colspan or rowspan in headers: use `id` + `headers`
- Nested or irregular header structures: always use `id` + `headers`

---

## Caption vs Summary vs aria-describedby

| Element | Purpose | Visible? |
|---------|---------|---------|
| `<caption>` | Names the table; announced first by screen readers | Yes (style with CSS if needed) |
| `aria-describedby` | Points to supplementary description (trends, methodology) | Usually visible |
| `summary` attribute | Deprecated in HTML5; do not use | N/A |

For complex tables that need explanation:
```html
<table aria-describedby="table-note">
  <caption>2024 Accessibility Audit Results by Product</caption>
  ...
</table>
<p id="table-note">
  Results reflect manual audits conducted in Q1 2024 using NVDA + Chrome and VoiceOver + Safari.
  P0 issues block task completion. P1 issues significantly degrade experience.
</p>
```

---

## Sortable Tables

```html
<th scope="col" aria-sort="ascending">
  <button onclick="sortTable('name', 'asc')">
    Name
    <span aria-hidden="true">↑</span>
  </button>
</th>
<th scope="col" aria-sort="none">
  <button onclick="sortTable('date', 'asc')">
    Date
    <span aria-hidden="true">↕</span>
  </button>
</th>
```

`aria-sort` values: `ascending`, `descending`, `none`, `other`

After sort, announce the change:
```html
<div role="status" aria-live="polite">Table sorted by Name, ascending.</div>
```

---

## Pagination & Row Count

```html
<nav aria-label="Table pagination">
  <button onclick="previousPage()" [disabled if on page 1]>← Previous</button>
  <span aria-current="page">Page 2 of 8</span>
  <button onclick="nextPage()">Next →</button>
</nav>
<div role="status" aria-live="polite">
  Showing rows 11–20 of 80 total results.
</div>
```

---

## Row Selection (Checkbox Tables)

```html
<table>
  <thead>
    <tr>
      <th scope="col">
        <input
          type="checkbox"
          id="select-all"
          aria-label="Select all rows"
          onchange="toggleAllRows(this.checked)"
        >
      </th>
      <th scope="col">Name</th>
      <th scope="col">Status</th>
    </tr>
  </thead>
  <tbody>
    <tr aria-selected="true">
      <td>
        <input
          type="checkbox"
          aria-label="Select Alice Johnson"
          checked
          onchange="updateSelectionCount()"
        >
      </td>
      <td>Alice Johnson</td>
      <td>Active</td>
    </tr>
  </tbody>
</table>

<!-- Selection count announcement -->
<div role="status" aria-live="polite" aria-atomic="true" id="selection-count">
  2 rows selected
</div>
```

---

## Data Grids (Interactive Tables with Keyboard Navigation)

When cells contain interactive elements or the table supports keyboard navigation like a spreadsheet, use `role="grid"`:

```html
<table role="grid" aria-label="Project tasks">
  <thead>
    <tr>
      <th scope="col">Task</th>
      <th scope="col">Assignee</th>
      <th scope="col">Due date</th>
      <th scope="col">Actions</th>
    </tr>
  </thead>
  <tbody>
    <tr>
      <td tabindex="0">Accessibility audit</td>
      <td>
        <select aria-label="Assignee for Accessibility audit">
          <option>Matthew</option>
        </select>
      </td>
      <td>
        <input type="date" aria-label="Due date for Accessibility audit">
      </td>
      <td>
        <button aria-label="Delete Accessibility audit task">Delete</button>
      </td>
    </tr>
  </tbody>
</table>
```

**Keyboard behavior for grids:**
- Arrow keys (left/right) navigate between cells in a row
- Arrow keys (up/down) navigate between rows
- Tab moves to the next interactive element within a cell (or next cell if cell has no interactive elements)
- Escape closes any dropdowns opened within a cell
- Enter activates interactive elements in a cell

```javascript
// Simplified grid keyboard navigation
const gridCells = document.querySelectorAll('[role="grid"] td, [role="grid"] th');
let currentIndex = 0;

gridCells.forEach((cell, index) => {
  cell.addEventListener('keydown', (e) => {
    if (e.key === 'ArrowRight') {
      currentIndex = (currentIndex + 1) % gridCells.length;
      gridCells[currentIndex].focus();
    }
    if (e.key === 'ArrowLeft') {
      currentIndex = (currentIndex - 1 + gridCells.length) % gridCells.length;
      gridCells[currentIndex].focus();
    }
    // up/down navigation by row
  });
});
```

---

## Virtualized Tables (Infinite Scroll)

When the table renders only visible rows (for performance with large datasets):

```html
<table role="grid" aria-label="Large dataset">
  <thead>
    <tr>
      <th scope="col">ID</th>
      <th scope="col">Name</th>
      <th scope="col">Email</th>
    </tr>
  </thead>
  <tbody id="table-body">
    <!-- Only visible rows rendered -->
    <tr aria-rowindex="1">
      <td>1</td>
      <td>Alice</td>
      <td>alice@example.com</td>
    </tr>
    <tr aria-rowindex="2">
      <td>2</td>
      <td>Bob</td>
      <td>bob@example.com</td>
    </tr>
    <!-- ... -->
  </tbody>
</table>
```

**Key requirements:**
- Use `aria-rowindex` and `aria-colindex` on each rendered cell
- Use aria-rowcount on table to indicate total rows
- As user scrolls and new rows render, update aria-rowindex
- Keyboard navigation must work even as rows appear/disappear
- Screen reader users must be able to "jump" to specific rows (aria-rowindex helps)

```javascript
// On scroll, re-render visible rows and update aria-rowindex
window.addEventListener('scroll', () => {
  const visibleStart = Math.floor(scrollPosition / rowHeight);
  const visibleEnd = visibleStart + visibleRowCount;

  // Re-render rows visibleStart to visibleEnd
  const rows = data.slice(visibleStart, visibleEnd);
  tbody.innerHTML = rows.map((row, i) => `
    <tr aria-rowindex="${visibleStart + i + 1}">
      <td aria-colindex="1">${row.id}</td>
      <td aria-colindex="2">${row.name}</td>
      <td aria-colindex="3">${row.email}</td>
    </tr>
  `).join('');

  // Update table's total row count
  table.setAttribute('aria-rowcount', totalRows);
});
```

---

## Editable Table Cells (Inline Editing)

When cells are editable or contain inputs:

```html
<table role="grid" aria-label="Editable task list">
  <thead>
    <tr>
      <th scope="col">Task</th>
      <th scope="col">Status</th>
      <th scope="col">Edit</th>
    </tr>
  </thead>
  <tbody>
    <tr>
      <td>
        <span id="task-1-name">Accessibility audit</span>
        <input type="text" id="task-1-input" style="display: none;" value="Accessibility audit">
      </td>
      <td>
        <select aria-label="Status for Accessibility audit">
          <option selected>In Progress</option>
          <option>Done</option>
        </select>
      </td>
      <td>
        <button onclick="editTask(1)">Edit</button>
        <button onclick="saveTask(1)" style="display: none;">Save</button>
        <button onclick="cancelTask(1)" style="display: none;">Cancel</button>
      </td>
    </tr>
  </tbody>
</table>

<script>
function editTask(id) {
  // Show input, hide display text; move focus to input
  document.getElementById(`task-${id}-input`).style.display = 'inline';
  document.getElementById(`task-${id}-name`).style.display = 'none';
  document.getElementById(`task-${id}-input`).focus();
  // Show save/cancel, hide edit
}

function saveTask(id) {
  // Validate input; save to backend
  const newValue = document.getElementById(`task-${id}-input`).value;
  // POST request to save
  // Update display text
  document.getElementById(`task-${id}-name`).textContent = newValue;
  // Toggle visibility
  document.getElementById(`task-${id}-input`).style.display = 'none';
  document.getElementById(`task-${id}-name`).style.display = 'inline';
  // Announce: "Task saved"
  announceToScreenReader('Task saved');
}
</script>
```

---

## Table Filtering & Search

```html
<!-- Search input above table -->
<label for="table-search">Filter by name</label>
<input
  type="search"
  id="table-search"
  placeholder="Enter name to filter"
  onkeyup="filterTable(this.value)"
  aria-controls="data-table"
>

<!-- Result count announcement -->
<div role="status" aria-live="polite" aria-atomic="true" id="filter-status">
  Showing 15 of 120 results
</div>

<!-- Table with aria-label indicating it's filtered -->
<table id="data-table" aria-label="Users (filtered)">
  <!-- rows that match filter -->
</table>

<script>
function filterTable(query) {
  const rows = document.querySelectorAll('#data-table tbody tr');
  let visibleCount = 0;

  rows.forEach(row => {
    const name = row.querySelector('td:first-child').textContent;
    if (name.toLowerCase().includes(query.toLowerCase())) {
      row.style.display = '';
      visibleCount++;
    } else {
      row.style.display = 'none';
    }
  });

  // Announce result count
  const total = rows.length;
  const message = query ? `Showing ${visibleCount} of ${total} results` : `Showing all ${total} results`;
  document.getElementById('filter-status').textContent = message;
}
</script>
```

---

## Responsive Table Patterns

### Strategy 1: Horizontal Scroll (simplest, safest)
```html
<div role="region" aria-label="Sales by Region" tabindex="0" style="overflow-x: auto;">
  <table>
    <!-- standard table -->
  </table>
</div>
```
The `tabindex="0"` makes the scroll container keyboard-focusable.

### Strategy 2: Stacked Cards (mobile)
Transform rows into card-like blocks with CSS. Use `data-label` attributes to recreate header context:
```html
<td data-label="Revenue">$4.2M</td>
```
```css
@media (max-width: 600px) {
  table { border-collapse: separate; border-spacing: 0 1rem; }
  thead { display: none; }
  tr { display: block; border: 1px solid #ddd; padding: 1rem; margin-bottom: 1rem; }
  td { display: block; padding: 0.5rem 0; }
  td::before {
    content: attr(data-label) ": ";
    font-weight: bold;
    display: inline-block;
    min-width: 100px;
  }
}
```

### Strategy 3: Priority Columns
Hide less critical columns at small viewports. Add a "show more" control. Ensure hidden columns don't contain critical data without an alternative.
```css
@media (max-width: 600px) {
  .column-yoy-growth { display: none; }
  .column-units { display: none; }
  /* Keep region, revenue visible; secondary columns hidden */
}
```

### Strategy 4: Hybrid (Scroll + Show/Hide)
At breakpoint, convert table to scrollable container but hide certain columns; provide toggle to show more columns.

---

## Common Mistakes

| Mistake | Problem | Fix |
|---------|---------|-----|
| `<div>` grid instead of `<table>` | No table semantics; keyboard nav broken | Use `<table>` or full ARIA grid pattern |
| Missing `<caption>` | Table has no accessible name | Add caption; hide visually if design requires |
| `scope` missing from headers | Screen readers guess header relationships | Add `scope="col"` or `scope="row"` to every `<th>` |
| Empty header cell | Screen readers announce "blank" | Add explicit label via aria-label or use proper id/headers |
| Icon-only action buttons | No accessible name | `aria-label="Delete [row name]"` |
| Ambiguous action scope | "Delete" button — delete what? | Include row context in every action label |
| Responsive table breaks table semantics | Table unreadable on mobile | Use horizontal scroll, stacked cards, or priority columns |
| Virtualized table with no aria-rowindex | Screen reader can't navigate | Add aria-rowindex and aria-rowcount |
| Editable cells with no edit state announcement | User doesn't know cell is editable | Announce "Edit mode" when entering cell; announce "Saved" on update |

---

## Audit Output Format

```
## Table Accessibility Audit

**Table:** [caption or description]
**Type:** [Simple / Complex / Grid / Virtualized / Responsive]
**Testing Date:** [date]

### Structure Check
- Caption: ✓/✗
- thead/tbody/tfoot: ✓/✗
- Header scope or id/headers: ✓/✗
- th vs td correct usage: ✓/✗

### Responsive Strategy (if mobile)
- Strategy: [Horizontal scroll / Stacked cards / Priority columns]
- Mobile appearance: ✓/✗
- Header context preserved: ✓/✗

### Data Grid Features (if grid or virtualized)
- Keyboard navigation (arrow keys): ✓/✗
- aria-rowindex / aria-colindex: ✓/✗
- Focus management: ✓/✗
- Sortable: ✓/✗
- Selectable: ✓/✗
- Editable cells: ✓/✗

### Screen Reader Behavior (Expected)
[What NVDA/JAWS/VoiceOver should announce when navigating key cells]

### Issues by Severity
[P0–P3 findings with fixes]

### Corrected Code
[Full corrected table HTML]
```

---

## Cross-References

- **accessibility-code:** Implement table patterns in HTML and ARIA
- **keyboard-focus-auditor:** Ensure table keyboard navigation (Tab order, arrow keys)
- **screen-reader-scripting:** Write table test scripts for NVDA, JAWS, VoiceOver
- **mobile-touch-auditor:** Test responsive table on touch devices
- **cognitive-accessibility:** Simplify table content for cognitive accessibility

