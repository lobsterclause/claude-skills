#!/usr/bin/env bash
# Regenerate this repo's marketplace scaffolding using claude-skill-marketplace.
#
# Prereq: pip install claude-skill-marketplace
# (https://github.com/lobsterclause/claude-skill-marketplace)
#
# SAFETY: this rmtree's plugins/ and rewrites it ONLY from discovered root-level
# sources (a `<name>/SKILL.md` or `.skill` archive) — a SKILL.md living at
# `.../skills/<name>/SKILL.md` (i.e. already inside plugins/) is explicitly
# ignored by the walk, on the assumption it's prior output. So: every plugin
# MUST have a real root-level source (see cross-review/, ios-remote-control/,
# seldon-protocol/, impact/, codemap/, where-is/, repomix-handoff/ for the
# pattern) or it gets silently deleted on the next run. Before adding a new
# plugin or editing an existing one, edit/add its ROOT-level source, not (only)
# the plugins/ copy — the two must stay in sync, or the next regen deletes or
# regresses it. (Discovered 2026-07-15 after this exact thing happened: impact,
# codemap, where-is, repomix-handoff had no root source and were deleted
# outright; cross-review had a stale one and got regressed ~3 commits.)
#
# ALSO NOTE: --plugin-version and --author-name/--author-url below are applied
# GLOBALLY to every plugin — there's no per-plugin override. Re-running this
# resets every plugin.json's version to 0.1.0 and author to matthewlarn, even
# for locally-authored plugins that currently correctly say "lobsterclause"
# (impact, codemap, where-is, repomix-handoff) or have a bumped version
# (cross-review, impact are at 0.2.0). If you run this for real, check
# `git diff plugins/*/.claude-plugin/plugin.json` afterward and restore any
# version/author fields that regressed.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Runtime-visible echo of the comment block above — a comment only warns
# whoever reads the file before running it; this warns whoever runs it,
# every time, whether or not they've read the source.
cat >&2 <<'EOF'
build-marketplace.sh: this deletes plugins/ and rewrites it ONLY from
root-level sources (a `<name>/SKILL.md` or `.skill` archive) — every plugin
needs one, kept in sync, or it gets deleted or regressed to a stale copy.
Also resets every plugin.json's version to 0.1.0 and author to matthewlarn,
globally, with no per-plugin override. Check `git diff plugins/*/.claude-plugin/plugin.json`
after this runs. See the header comment in this file for the full story.
EOF

claude-skill-marketplace \
  --source "$HERE" \
  --output "$HERE" \
  --name claude-skills \
  --description "Marketplace wrapper for matthewlarn/claude-skills — accessibility, design, and prototype-review skills packaged as Claude Code plugins so each can be toggled on demand." \
  --owner-name lobsterclause \
  --owner-url https://github.com/lobsterclause/claude-skills \
  --author-name matthewlarn \
  --author-url https://github.com/matthewlarn/claude-skills
