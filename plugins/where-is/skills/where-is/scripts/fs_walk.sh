#!/usr/bin/env bash
# fs_walk.sh — list files matching a path/glob, honoring .gitignore via
# `git ls-files` when available. Excludes node_modules/dist/.git/coverage/.next/build.
#
# Usage: fs_walk.sh "<glob-or-path>" [--include-tests]

set -eu

if [ $# -lt 1 ]; then
  echo "usage: fs_walk.sh <glob> [--include-tests]" >&2
  exit 2
fi

pat="$1"
shift || true
include_tests="false"
while [ $# -gt 0 ]; do
  case "$1" in
    --include-tests) include_tests="true"; shift ;;
    *) shift ;;
  esac
done

root="${WHEREIS_REPO_ROOT:-$(pwd)}"

# Convert simple glob to grep regex (escape dots, ** -> .*, * -> [^/]*, ? -> .)
# Uses awk to avoid macOS sed's bracket-class parsing quirks.
# Note: `\1` in awk strings is the literal character `1`, not a control char,
# so we use an unambiguous text sentinel that can't appear in normal globs.
glob_to_regex() {
  printf '%s' "$1" | awk '
    {
      s=$0
      gsub(/\./, "\\.", s)
      gsub(/\*\*/, "@@DSTAR@@", s)   # placeholder for **
      gsub(/\*/, "[^/]*", s)
      gsub(/@@DSTAR@@/, ".*", s)
      gsub(/\?/, ".", s)
      print s
    }
  '
}

re=$(glob_to_regex "$pat")
# If pattern looks like a plain prefix path (no glob chars), match files under it.
case "$pat" in
  *\**|*\?*|*\[*) : ;;
  *) re="^${re}(/.*)?$" ;;
esac

list_files() {
  if git -C "$root" rev-parse --git-dir >/dev/null 2>&1; then
    git -C "$root" ls-files
  else
    # -prune skips traversing matched dirs entirely; -not -path only filters
    # output, so find still walks node_modules contents (huge I/O on big repos).
    find "$root" \
      -type d \( -name node_modules -o -name .git -o -name dist -o -name build -o -name .next -o -name coverage \) -prune \
      -o -type f -print \
      | sed "s|^$root/||"
  fi
}

# `--` ends-of-options on grep so paths starting with `-` aren't read as flags.
list_files \
  | grep -E -- "$re" 2>/dev/null \
  | grep -Ev '(^|/)(node_modules|dist|build|\.next|coverage)(/|$)' \
  | { if [ "$include_tests" = "true" ]; then cat; else grep -Ev '\.(test|spec)\.[tj]sx?$' | grep -Ev '(^|/)__tests__/'; fi; } \
  || true
