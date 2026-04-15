#!/usr/bin/env bash
# Regenerate this repo's marketplace scaffolding using claude-skill-marketplace.
#
# Prereq: pip install claude-skill-marketplace
# (https://github.com/lobsterclause/claude-skill-marketplace)

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

claude-skill-marketplace \
  --source "$HERE" \
  --output "$HERE" \
  --name claude-skills \
  --description "Marketplace wrapper for matthewlarn/claude-skills — accessibility, design, and prototype-review skills packaged as Claude Code plugins so each can be toggled on demand." \
  --owner-name lobsterclause \
  --owner-url https://github.com/lobsterclause/claude-skills \
  --author-name matthewlarn \
  --author-url https://github.com/matthewlarn/claude-skills
