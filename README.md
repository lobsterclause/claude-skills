# Claude Skills Repository

This repository collects reusable Claude skills for accessibility review, prototype critique, design analysis, and related workflows.

## Inventory

- Implemented skills/packages: 35 total (`33` `.skill` files and `2` `SKILL.md` packages)
- Accessibility skills: 33
- Cowork review skill packages: 2
- Planned skill directories already scaffolded in the repo: 11

## Collection Summary

| Collection | Status | Packaged skills | Notes |
|------------|--------|-----------------|-------|
| `accessibility-skills-complete/` | Active | 33 `.skill` archives | Accessibility-focused suite organized by workflow stage |
| `cowork-agent-audit/` | Active | 1 `SKILL.md` package | Standalone multi-reviewer prototype audit package |
| `cowork-skills/cowork-agent-audit/` | Active | 1 `SKILL.md` package | Namespaced copy of the cowork audit package |
| `design-skills/` | Scaffolded | 0 packaged skills | Concept directories only, no `.skill` or `SKILL.md` files yet |
| `other/` | Scaffolded | 0 packaged skills | Miscellaneous concept directories only |

## Implemented Collections

### `accessibility-skills-complete/`

Production-ready accessibility skill suite organized by workflow stage. See `accessibility-skills-complete/README.md` for the deeper guide.

#### `strategy/` (3 skills)
- `accessibility-advisor`
- `futures-wheel`
- `wcag-checklist`

#### `audit/` (18 skills)
- `full-accessibility-audit`
- `accessibility-audit`
- `accessibility-code`
- `accessibility-copy`
- `accessible-forms`
- `accessible-tables`
- `alt-text-generator`
- `cognitive-accessibility`
- `contrast-checker`
- `design-review-cowork`
- `design-system-drift`
- `disability-testing`
- `keyboard-focus-auditor`
- `mobile-touch-auditor`
- `motion-auditor`
- `pdf-document-accessibility`
- `video-media-accessibility`
- `wcag-compliance-auditor`

#### `audience/` (3 skills)
- `dei-auditor`
- `kids-ux-auditor`
- `older-audiences-auditor`

#### `ethics/` (4 skills)
- `ai-transparency-auditor`
- `black-mirror-auditor`
- `gamification-auditor`
- `privacy-first-auditor`

#### `test/` (3 skills)
- `a11y-test-plan`
- `playwright-accessibility-auditor`
- `screen-reader-scripting`

#### `handoff/` (2 skills)
- `accessibility-annotations`
- `design-handoff`

### `cowork-agent-audit/`

Installable multi-perspective review package for prototypes and UI implementation work.

- Skill package: `design-review-cowork`
- Core reviewer modules: `ux-designer`, `accessibility`, `frontend`, `design-critic`, `orchestrator`
- Additional specialist modules in this copy: `brand-consistency`, `business-strategy`, `performance`

### `cowork-skills/cowork-agent-audit/`

Namespaced copy of the cowork review package for teams that want it grouped under `cowork-skills/`.

- Skill package: `design-review-cowork`
- Included reviewer modules in this copy: `accessibility`, `brand-consistency`, `design-critic`, `frontend`, `orchestrator`

## Planned Skill Directories

These folders already exist in the repository, but they do not currently contain packaged `.skill` or `SKILL.md` files.

### `design-skills/`
- `black-mirror-auditor`
- `case-study-writer`
- `dark-pattern-detector`
- `design-critique`
- `design-system-auditor`
- `ethical-lean-design`
- `futures-wheel`
- `gamification-auditor`
- `research-synthesis`

### `other/`
- `linkedin-writer`
- `prompt-engineer`

## Usage

Use these collections when you want focused Claude expertise for:

- accessibility strategy, audits, testing, and handoff
- prototype and frontend design reviews
- future design-system and research-oriented skill expansion

## Where To Start

- Start with `accessibility-skills-complete/README.md` if you want the full accessibility suite with category-by-category detail.
- Start with `cowork-agent-audit/README.md` if you want a guided, multi-perspective prototype review workflow.
- Use the root README as the inventory view: what is packaged today, what is duplicated in namespaced form, and what is still only scaffolded.

## Contributing

Contributions are welcome. Please keep new skills grouped by collection, include clear documentation, and update this README whenever the repository inventory changes.
