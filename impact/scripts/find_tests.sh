#!/usr/bin/env bash
# find_tests.sh — given a newline-separated list of file paths on stdin,
# emit the test files that exercise them.
#
# Two strategies, tried in order:
#   1. codegraph (`codegraph affected --stdin -j`) — when `.codegraph/` exists
#      for the repo and the CLI is on PATH. Real transitive BFS over the
#      indexed import graph, driven by IMPACT_ENTRY_FILES (the originally
#      changed files, not the whole reverse-dep closure).
#   2. Heuristic fallback (always available): a test file is matched if
#      a. its path matches *.test.ts(x) / *.spec.ts(x) / *.test.js(x) / *.spec.js(x), AND
#      b. it sits in __tests__/ adjacent to the subject, OR its filename basename
#         (minus .test/.spec) matches a subject basename, OR it appears in the
#         reverse-dep set itself (passed via stdin alongside non-test files).
#
# Usage:  IMPACT_ENTRY_FILES=$'a.ts\nb.ts' cat impacted_files.txt | find_tests.sh
# Output: newline-separated unique test file paths, relative to repo root.

set -euo pipefail

repo_root="${IMPACT_REPO_ROOT:-$(pwd)}"

# Slurp stdin. Use `while IFS= read -r` not `mapfile` — `mapfile` isn't in macOS
# default bash 3.2, and the rest of this skill keeps to bash 3.2-safe idioms.
impacted=()
while IFS= read -r line; do
  [ -n "$line" ] && impacted+=("$line")
done

if [ "${#impacted[@]}" -eq 0 ]; then
  exit 0
fi

# --- Prefer codegraph, when this repo has an index and the CLI is available.
# It runs a real transitive BFS over codegraph's import graph (no depth-1
# basename guessing) using only the originally-changed entry files
# (IMPACT_ENTRY_FILES) — codegraph does its own traversal from there, so
# feeding it the already-computed reverse-dep closure too would be redundant.
# See references/tools.md for why this isn't also used for the main
# reverse-dependency section.
if [ -n "${IMPACT_ENTRY_FILES:-}" ] && [ -d "$repo_root/.codegraph" ] && command -v codegraph >/dev/null 2>&1; then
  cg_out=$(printf '%s\n' "$IMPACT_ENTRY_FILES" | codegraph affected --stdin -j -p "$repo_root" -d 5 2>/dev/null || true)
  if [ -n "$cg_out" ]; then
    if cg_tests=$(printf '%s' "$cg_out" | node -e '
      let s = ""; process.stdin.on("data", c => s += c);
      process.stdin.on("end", () => {
        const o = JSON.parse(s); // throws -> nonzero exit -> caller falls back to the heuristic
        for (const t of (o.affectedTests || [])) process.stdout.write(t + "\n");
      });
    ' 2>/dev/null); then
      # A genuinely empty list is still a valid codegraph answer (no tests
      # depend on this change) — trust it over the heuristic below rather
      # than falling through.
      printf '%s' "$cg_tests"
      exit 0
    fi
  fi
  # Query failed or returned unparseable output (stale/corrupt index, CLI
  # error) — fall through to the heuristic below.
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
