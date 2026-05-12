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

# Resolve --package <name> to the package's actual directory so we can scope
# the rg search root instead of grepping the path string (which silently
# returned 0 results for scoped packages like @scope/core whose dir is just
# `packages/core`).
search_root="$root"
if [ -n "$pkg_filter" ]; then
  script_dir="$(cd "$(dirname "$0")" && pwd)"
  layout="$(WHEREIS_REPO_ROOT="$root" bash "$script_dir/detect_layout.sh" 2>/dev/null || echo '{"packages":[]}')"
  pkg_dir=""
  if command -v python3 >/dev/null 2>&1; then
    pkg_dir=$(printf '%s' "$layout" | WHEREIS_PKG="$pkg_filter" python3 -c '
import json, sys, os
try:
  d = json.loads(sys.stdin.read())
except Exception:
  sys.exit(0)
name = os.environ.get("WHEREIS_PKG", "")
for p in (d.get("packages") or []):
  if p.get("name") == name and p.get("dir"):
    print(p["dir"]); break
' 2>/dev/null || true)
  fi
  if [ -n "$pkg_dir" ] && [ -d "$root/$pkg_dir" ]; then
    search_root="$root/$pkg_dir"
  else
    # Couldn't resolve; warn and fall back to the old path-string filter (lossy).
    echo "WARN: --package '$pkg_filter' didn't resolve to a workspace dir; falling back to path-string filter" >&2
    rg "${rg_args[@]+"${rg_args[@]}"}" -- "$phrase" "$root" 2>/dev/null \
      | grep -F -- "$pkg_filter" \
      | head -n 30 \
      || true
    exit 0
  fi
fi

rg "${rg_args[@]+"${rg_args[@]}"}" -- "$phrase" "$search_root" 2>/dev/null \
  | head -n 30 \
  || true
