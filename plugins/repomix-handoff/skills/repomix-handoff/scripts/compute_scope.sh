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
set -eu

PATHS=""
LANGS=""
EXTRA_EXCLUDE=""
INCLUDE_TESTS=0
BASE_REF="origin/main"
EXPAND_IMPORTS=0

while [ $# -gt 0 ]; do
  case "$1" in
    --paths) PATHS="$2"; shift 2 ;;
    --lang) LANGS="$2"; shift 2 ;;
    --exclude) EXTRA_EXCLUDE="$2"; shift 2 ;;
    --include-tests) INCLUDE_TESTS=1; shift ;;
    --base) BASE_REF="$2"; shift 2 ;;
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
    [ -n "$g" ] && DEFAULT_EXCLUDES+=("$g")
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
    exit 3
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
          cand="$base/${imp}${ext}"
          if command -v python3 >/dev/null 2>&1; then
            cand="$(python3 -c 'import os,sys; print(os.path.normpath(sys.argv[1]))' "$cand" 2>/dev/null || echo "$cand")"
          fi
          if [ -f "$cand" ]; then
            EXPANDED+=("$cand")
            break
          fi
        done
      done < <(grep -hoE "(from|require\()[[:space:]]*['\"][^'\"]+['\"]" "$src" 2>/dev/null \
                 | sed -E "s/.*['\"]([^'\"]+)['\"].*/\1/")
    done
    if [ "${#EXPANDED[@]}" -gt 0 ]; then
      INCLUDES+=("${EXPANDED[@]}")
    fi
  fi
fi

if [ -n "$LANGS" ] && [ "$MODE" = "pr" ] && [ "${#INCLUDES[@]}" -gt 0 ]; then
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

# Build JSON safely via python.
inc_lines=""
exc_lines=""
if [ "${#INCLUDES[@]}" -gt 0 ]; then
  inc_lines="$(printf '%s\n' "${INCLUDES[@]}")"
fi
exc_lines="$(printf '%s\n' "${DEFAULT_EXCLUDES[@]}")"

INC_BLOB="$inc_lines" EXC_BLOB="$exc_lines" MODE="$MODE" SEED_COUNT="$SEED_COUNT" \
python3 - <<'PY'
import json, os
inc = [l for l in os.environ.get("INC_BLOB","").splitlines() if l]
exc = [l for l in os.environ.get("EXC_BLOB","").splitlines() if l]
print(json.dumps({
  "mode": os.environ["MODE"],
  "seed_count": int(os.environ["SEED_COUNT"]),
  "include": inc,
  "exclude": exc,
}))
PY
