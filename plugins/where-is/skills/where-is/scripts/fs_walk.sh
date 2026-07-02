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
      # Escape ERE metacharacters BEFORE glob substitutions so paths
      # containing `\`, `+`, `(`, `)`, `{`, `}`, `|`, `^`, `$` round-trip
      # safely. Backslash goes FIRST so it does not double-escape the
      # backslashes added by later substitutions.
      # (Brackets and dots stay; * and ? get rewritten below.)
      # Empirically verified: replacement "\\\\" emits TWO backslashes in the
      # output (the correct ERE escape for one literal backslash); the prior
      # 8-backslash form emitted FOUR (kat, PR #23 pass 1).
      gsub(/\\/, "\\\\", s)
      gsub(/[+(){}|^$]/, "\\\\&", s)
      gsub(/\./, "\\.", s)
      # `**/` means "zero or more directory levels" — translate to `(.*/)?`
      # so `src/**/*.ts` matches BOTH `src/index.ts` and `src/a/b/c.ts`.
      # The old direct `**` -> `.*` mapping forced two slashes around the
      # wildcard, so zero-depth paths never matched. Placeholders are plain
      # alphanumerics so the later `*` / `?` substitutions cannot touch the
      # regex text they expand to.
      gsub(/\*\*\//, "@@DSLASH@@", s)  # placeholder for **/
      gsub(/\*\*/, "@@DSTAR@@", s)     # placeholder for remaining **
      gsub(/\*/, "[^/]*", s)
      gsub(/\?/, ".", s)
      gsub(/@@DSLASH@@/, "(.*/)?", s)
      gsub(/@@DSTAR@@/, ".*", s)
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
    # Run find from inside $root and strip the constant `./` prefix — the old
    # `sed "s#^$root/##"` interpolated $root into a sed program, which broke
    # when the path contained `#` (delimiter clash) or regex metacharacters.
    (cd "$root" && find . \
      -type d \( -name node_modules -o -name .git -o -name dist -o -name build -o -name .next -o -name coverage \) -prune \
      -o -type f -print \
      | sed 's|^\./||')
  fi
}

# `--` ends-of-options on grep so paths starting with `-` aren't read as flags.
list_files \
  | grep -E -- "$re" 2>/dev/null \
  | grep -Ev '(^|/)(node_modules|dist|build|\.next|coverage)(/|$)' \
  | { if [ "$include_tests" = "true" ]; then cat; else grep -Ev '\.(test|spec)\.[tj]sx?$' | grep -Ev '(^|/)__tests__/'; fi; } \
  || true
