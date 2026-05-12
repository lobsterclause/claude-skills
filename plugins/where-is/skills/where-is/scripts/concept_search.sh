#!/usr/bin/env bash
# concept_search.sh — ripgrep with sensible defaults for broad-concept lookups.
# Output: file:line:snippet, ranked, capped at 30 hits.
#
# Usage: concept_search.sh "<phrase>" [--include-tests] [--package <name>]

set -eu

if [ $# -lt 1 ]; then
  echo "usage: concept_search.sh <phrase> [--include-tests] [--package <name>]" >&2
  exit 2
fi

phrase="$1"
shift || true
include_tests="false"
pkg_filter=""
while [ $# -gt 0 ]; do
  case "$1" in
    --include-tests) include_tests="true"; shift ;;
    --package) pkg_filter="${2:-}"; shift 2 ;;
    *) shift ;;
  esac
done

root="${WHEREIS_REPO_ROOT:-$(pwd)}"

if ! command -v rg >/dev/null 2>&1; then
  # Fall back to grep -r.
  echo "WARN: ripgrep (rg) not found; falling back to grep -r" >&2
  grep -rn --include='*.ts' --include='*.tsx' --include='*.js' --include='*.jsx' \
    --exclude-dir=node_modules --exclude-dir=dist --exclude-dir=.git \
    --exclude-dir=coverage --exclude-dir=.next --exclude-dir=build \
    -- "$phrase" "$root" 2>/dev/null | head -n 30 || true
  exit 0
fi

rg_args=(
  --line-number
  --no-heading
  --color=never
  --type-add 'tsj:*.{ts,tsx,js,jsx,mjs,cjs}'
  -t tsj
  --max-count 5
  --glob '!node_modules'
  --glob '!dist'
  --glob '!build'
  --glob '!.next'
  --glob '!coverage'
)
if [ "$include_tests" != "true" ]; then
  rg_args+=(--glob '!*.test.*' --glob '!*.spec.*' --glob '!__tests__/**')
fi

# Smart-case literal-ish search; let the user pass regex if they really want.
rg_args+=(--smart-case --fixed-strings)

if [ -n "$pkg_filter" ]; then
  # Best-effort: limit to common workspace dirs containing the package name.
  rg "${rg_args[@]+"${rg_args[@]}"}" -- "$phrase" "$root" 2>/dev/null \
    | grep -F "$pkg_filter" \
    | head -n 30 \
    || true
else
  rg "${rg_args[@]+"${rg_args[@]}"}" -- "$phrase" "$root" 2>/dev/null \
    | head -n 30 \
    || true
fi
