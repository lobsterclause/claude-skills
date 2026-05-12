#!/usr/bin/env bash
# find_tests.sh — given a newline-separated list of file paths on stdin,
# emit the test files that exercise them. A test file is matched if:
#   1. its path matches *.test.ts(x) / *.spec.ts(x) / *.test.js(x) / *.spec.js(x), AND
#   2. it sits in __tests__/ adjacent to the subject, OR its filename basename
#      (minus .test/.spec) matches a subject basename, OR it appears in the
#      reverse-dep set itself (passed via stdin alongside non-test files).
#
# Usage:  cat impacted_files.txt | find_tests.sh
# Output: newline-separated unique test file paths, relative to repo root.

set -euo pipefail

repo_root="${IMPACT_REPO_ROOT:-$(pwd)}"

# Slurp stdin
mapfile -t impacted < <(cat)

if [ "${#impacted[@]}" -eq 0 ]; then
  exit 0
fi

# 1. Test files already in the impacted set (they import the changed code transitively).
already_tests=()
others=()
for f in "${impacted[@]}"; do
  case "$f" in
    *.test.ts|*.test.tsx|*.test.js|*.test.jsx|*.spec.ts|*.spec.tsx|*.spec.js|*.spec.jsx)
      already_tests+=("$f") ;;
    */__tests__/*)
      already_tests+=("$f") ;;
    *)
      others+=("$f") ;;
  esac
done

# 2. For each non-test impacted file, look for sibling tests by basename.
sibling_tests=()
for f in "${others[@]:-}"; do
  [ -z "$f" ] && continue
  dir=$(dirname "$f")
  base=$(basename "$f")
  stem="${base%.*}"
  # __tests__ subdir adjacent to the file
  for ext in ts tsx js jsx; do
    for suffix in test spec; do
      for candidate in \
        "$dir/__tests__/$stem.$suffix.$ext" \
        "$dir/$stem.$suffix.$ext"; do
        if [ -f "$repo_root/$candidate" ]; then
          sibling_tests+=("$candidate")
        fi
      done
    done
  done
done

# Combine, dedupe, sort, print
{
  printf '%s\n' "${already_tests[@]:-}"
  printf '%s\n' "${sibling_tests[@]:-}"
} | awk 'NF' | sort -u
