#!/usr/bin/env bash
# compute_scope.sh — compute include/exclude file lists for a snapshot.
#
# Flags:
#   --paths "<glob1>,<glob2>"      Explicit include globs (overrides PR-scoped default).
#   --lang "ts,tsx,py"             Restrict to these extensions.
#   --exclude "<glob1>,<glob2>"    Extra exclude globs (appended to defaults).
#   --include-tests                Don't auto-exclude *.test.* / *.spec.*.
#   --base <ref>                   Base ref for PR-scoped diff (default: origin/main).
#   --expand-imports               Expand seed set 1 hop via static imports (best-effort).
#
# Output (stdout): JSON {"include": [...], "exclude": [...], "seed_count": N, "mode": "pr|paths"}
#
# Exit codes: 0 ok, 1 runtime failure (e.g. not a git repo), 2 usage.
set -eu

PATHS=""
LANGS=""
EXTRA_EXCLUDE=""
INCLUDE_TESTS=0
BASE_REF="origin/main"
EXPAND_IMPORTS=0

# Bounds-check before `shift 2`: a value-taking flag as the last arg would make
# `shift 2` fail silently under `set -e` with no diagnostic (issue #12).
need_val() {
  [ "$2" -ge 2 ] || { echo "compute_scope.sh: $1 requires a value" >&2; exit 2; }
}

while [ $# -gt 0 ]; do
  case "$1" in
    --paths) need_val "$1" $#; PATHS="$2"; shift 2 ;;
    --lang) need_val "$1" $#; LANGS="$2"; shift 2 ;;
    --exclude) need_val "$1" $#; EXTRA_EXCLUDE="$2"; shift 2 ;;
    --include-tests) INCLUDE_TESTS=1; shift ;;
    --base) need_val "$1" $#; BASE_REF="$2"; shift 2 ;;
    --expand-imports) EXPAND_IMPORTS=1; shift ;;
    *) echo "compute_scope.sh: unknown flag $1" >&2; exit 2 ;;
  esac
done

DEFAULT_EXCLUDES=(
  "node_modules/**" "**/node_modules/**"
  "dist/**" "**/dist/**"
  ".next/**" "coverage/**" "**/coverage/**"
  "build/**" "**/build/**"
  ".turbo/**" ".cache/**"
  "**/*.lock" "**/pnpm-lock.yaml" "**/package-lock.json" "**/yarn.lock"
  "**/*.min.js" "**/*.map"
  ".git/**" "**/.DS_Store"
  "**/__snapshots__/**"
  "**/*.png" "**/*.jpg" "**/*.jpeg" "**/*.gif" "**/*.webp"
  "**/*.pdf" "**/*.mp4" "**/*.webm"
)

if [ "$INCLUDE_TESTS" -eq 0 ]; then
  DEFAULT_EXCLUDES+=("**/*.test.*" "**/*.spec.*" "**/__tests__/**" "**/e2e/**")
fi

if [ -n "$EXTRA_EXCLUDE" ]; then
  IFS=',' read -r -a _user_ex <<< "$EXTRA_EXCLUDE"
  for g in "${_user_ex[@]}"; do
    [ -n "$g" ] || continue
    # Defense-in-depth: reject traversal patterns — an exclude glob should
    # describe paths inside the repo, never climb out of it (issue #12 medium).
    case "$g" in
      *..*) echo "compute_scope.sh: --exclude pattern must not contain '..' (got: $g)" >&2; exit 2 ;;
    esac
    DEFAULT_EXCLUDES+=("$g")
  done
fi

INCLUDES=()
MODE="pr"
SEED_COUNT=0

if [ -n "$PATHS" ]; then
  MODE="paths"
  IFS=',' read -r -a _p <<< "$PATHS"
  for g in "${_p[@]}"; do
    [ -n "$g" ] && INCLUDES+=("$g")
  done
  SEED_COUNT=${#INCLUDES[@]}
else
  if ! git rev-parse --git-dir >/dev/null 2>&1; then
    echo "compute_scope.sh: not inside a git repo and no --paths provided" >&2
    exit 1
  fi
  merge_base="$(git merge-base HEAD "$BASE_REF" 2>/dev/null || true)"
  if [ -z "$merge_base" ]; then
    merge_base="$(git rev-parse HEAD~1 2>/dev/null || git rev-parse HEAD)"
  fi
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    [ ! -f "$line" ] && continue
    INCLUDES+=("$line")
  done < <(git diff --name-only "${merge_base}...HEAD" 2>/dev/null || true)
  SEED_COUNT=${#INCLUDES[@]}

  if [ "$EXPAND_IMPORTS" -eq 1 ] && [ "$SEED_COUNT" -gt 0 ]; then
    EXPANDED=()
    for src in "${INCLUDES[@]}"; do
      [ -f "$src" ] || continue
      base="$(dirname "$src")"
      while IFS= read -r imp; do
        [ -z "$imp" ] && continue
        case "$imp" in
          .*|/*) ;;
          *) continue ;;
        esac
        for ext in "" ".ts" ".tsx" ".js" ".jsx" ".py" "/index.ts" "/index.tsx" "/index.js"; do
          # `[ -f ... ]` resolves unnormalized paths like `a/../b/c.ts` natively;
          # no need to shell out to python per import. The final EXPANDED list is
          # deduped + normalized in one pass below.
          cand="$base/${imp}${ext}"
          if [ -f "$cand" ]; then
            EXPANDED+=("$cand")
            break
          fi
        done
      done < <(grep -hoE "(from|require\()[[:space:]]*['\"][^'\"]+['\"]" "$src" 2>/dev/null \
                 | sed -E "s/.*['\"]([^'\"]+)['\"].*/\1/")
    done
    if [ "${#EXPANDED[@]}" -gt 0 ]; then
      # Normalize once (collapse a/../b → b) on the final list — much cheaper than
      # forking python per import. Read line-by-line into a bash 3.2-safe array;
      # never use unquoted $(...) inside an array assignment — paths with spaces
      # would fragment (cross-review pass 2, gemini).
      # Containment (issue #12 medium): drop any expanded import whose realpath
      # escapes the repo root — `import "../../outside"` must not pull files
      # from outside the repo into the snapshot (symlinks included).
      if command -v python3 >/dev/null 2>&1; then
        NORMALIZED=()
        while IFS= read -r line; do
          [ -n "$line" ] && NORMALIZED+=("$line")
        done < <(printf '%s\n' "${EXPANDED[@]}" | python3 -c 'import os,sys
root=os.path.realpath(os.getcwd())
seen=set()
for p in (l.rstrip("\n") for l in sys.stdin):
    if not p: continue
    n=os.path.normpath(p)
    r=os.path.realpath(n)
    if r != root and not r.startswith(root + os.sep):
        continue
    if n not in seen:
        seen.add(n); print(n)')
        EXPANDED=("${NORMALIZED[@]+"${NORMALIZED[@]}"}")
      fi
      if [ "${#EXPANDED[@]}" -gt 0 ]; then
        INCLUDES+=("${EXPANDED[@]}")
      fi
    fi
  fi
fi

# Apply --lang filter in BOTH modes (pr + paths). Previously gated to pr-only,
# which silently ignored the user's filter when they passed --paths.
if [ -n "$LANGS" ] && [ "${#INCLUDES[@]}" -gt 0 ]; then
  IFS=',' read -r -a _exts <<< "$LANGS"
  FILTERED=()
  for f in "${INCLUDES[@]}"; do
    for e in "${_exts[@]}"; do
      case "$f" in
        *.${e}) FILTERED+=("$f"); break ;;
      esac
    done
  done
  INCLUDES=("${FILTERED[@]}")
fi

if [ "${#INCLUDES[@]}" -gt 0 ]; then
  DEDUPED=()
  while IFS= read -r _line; do
    [ -n "$_line" ] && DEDUPED+=("$_line")
  done < <(printf '%s\n' "${INCLUDES[@]}" | awk 'NF && !seen[$0]++')
  INCLUDES=("${DEDUPED[@]}")
fi

# Build JSON safely via python. The include/exclude lists travel through temp
# files, NOT env vars — a huge PR's file list in a single env var counts
# against the same ~128KB/ARG_MAX exec limits as argv (issue #12 design high).
_inc_tmp="$(mktemp "${TMPDIR:-/tmp}/compute-scope-inc.XXXXXXXX")"
_exc_tmp="$(mktemp "${TMPDIR:-/tmp}/compute-scope-exc.XXXXXXXX")"
trap 'rm -f "$_inc_tmp" "$_exc_tmp"' EXIT

if [ "${#INCLUDES[@]}" -gt 0 ]; then
  printf '%s\n' "${INCLUDES[@]}" > "$_inc_tmp"
fi
printf '%s\n' "${DEFAULT_EXCLUDES[@]}" > "$_exc_tmp"

MODE="$MODE" SEED_COUNT="$SEED_COUNT" \
python3 - "$_inc_tmp" "$_exc_tmp" <<'PY'
import json, os, sys
with open(sys.argv[1], encoding="utf-8") as f:
    inc = [l for l in f.read().splitlines() if l]
with open(sys.argv[2], encoding="utf-8") as f:
    exc = [l for l in f.read().splitlines() if l]
print(json.dumps({
  "mode": os.environ["MODE"],
  "seed_count": int(os.environ["SEED_COUNT"]),
  "include": inc,
  "exclude": exc,
}))
PY
