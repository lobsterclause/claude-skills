#!/usr/bin/env bash
# handoff.sh — produce a bounded codebase snapshot for an external AI reviewer.
#
# Usage: handoff.sh [flags]
#   --paths "a,b"              Path-scoped slice.
#   --lang "ts,tsx"            Language filter.
#   --exclude "g1,g2"          Extra excludes.
#   --include-tests            Include test files.
#   --style markdown|xml|plain|json  Output format (default: markdown).
#   --max-tokens N             Token budget (default: 120000).
#   --reviewer codex|gemini|kimi|claude   Preset (overrides --style + --max-tokens).
#   --output PATH              Output file (default: /tmp/repomix-handoff-<ts>.<ext>).
#   --base REF                 Base ref for PR-scoped diff (default: origin/main).
#   --expand-imports           Expand seed set 1 hop via static imports.
#   --dry-run                  Print the computed scope and command, don't run.
#
# Side effects: writes snapshot to --output. Prints a JSON summary on stdout.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PATHS=""
LANGS=""
EXTRA_EXCLUDE=""
INCLUDE_TESTS=0
STYLE=""
MAX_TOKENS=""
REVIEWER=""
OUTPUT=""
BASE_REF="origin/main"
EXPAND_IMPORTS=0
DRY_RUN=0

while [ $# -gt 0 ]; do
  case "$1" in
    --paths) PATHS="$2"; shift 2 ;;
    --lang) LANGS="$2"; shift 2 ;;
    --exclude) EXTRA_EXCLUDE="$2"; shift 2 ;;
    --include-tests) INCLUDE_TESTS=1; shift ;;
    --style) STYLE="$2"; shift 2 ;;
    --max-tokens) MAX_TOKENS="$2"; shift 2 ;;
    --reviewer) REVIEWER="$2"; shift 2 ;;
    --output) OUTPUT="$2"; shift 2 ;;
    --base) BASE_REF="$2"; shift 2 ;;
    --expand-imports) EXPAND_IMPORTS=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
    *) echo "handoff.sh: unknown flag $1" >&2; exit 2 ;;
  esac
done

# Reviewer presets.
case "${REVIEWER}" in
  codex)  STYLE="${STYLE:-xml}";      MAX_TOKENS="${MAX_TOKENS:-160000}" ;;
  gemini) STYLE="${STYLE:-markdown}"; MAX_TOKENS="${MAX_TOKENS:-1000000}" ;;
  kimi)   STYLE="${STYLE:-markdown}"; MAX_TOKENS="${MAX_TOKENS:-200000}" ;;
  claude) STYLE="${STYLE:-xml}";      MAX_TOKENS="${MAX_TOKENS:-200000}" ;;
  "")     STYLE="${STYLE:-markdown}"; MAX_TOKENS="${MAX_TOKENS:-120000}" ;;
  *) echo "handoff.sh: unknown --reviewer '${REVIEWER}' (codex|gemini|kimi|claude)" >&2; exit 2 ;;
esac

# Validate style.
case "$STYLE" in
  markdown|xml|plain|json) ;;
  *) echo "handoff.sh: unknown --style '$STYLE'" >&2; exit 2 ;;
esac

# Default output path.
ts="$(date +%Y%m%d-%H%M%S)"
ext="md"
case "$STYLE" in
  xml) ext="xml" ;;
  json) ext="json" ;;
  plain) ext="txt" ;;
  markdown) ext="md" ;;
esac
OUTPUT="${OUTPUT:-/tmp/repomix-handoff-${ts}.${ext}}"

# 1. Detect repomix.
detect_json="$("$SCRIPT_DIR/detect_repomix.sh")"
available="$(printf '%s' "$detect_json" | python3 -c 'import json,sys; print(json.load(sys.stdin)["available"])')"
via="$(printf '%s' "$detect_json" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("via") or "")')"
if [ "$available" != "True" ] && [ "$available" != "true" ]; then
  cat >&2 <<MSG
handoff.sh: repomix is not installed.

Install one of:
  npm install -g repomix
  # or run ad-hoc via npx (slower):
  npx --yes repomix --version

Then rerun this command.
MSG
  exit 4
fi

# 2. Compute scope.
SCOPE_ARGS=()
[ -n "$PATHS" ] && SCOPE_ARGS+=(--paths "$PATHS")
[ -n "$LANGS" ] && SCOPE_ARGS+=(--lang "$LANGS")
[ -n "$EXTRA_EXCLUDE" ] && SCOPE_ARGS+=(--exclude "$EXTRA_EXCLUDE")
[ "$INCLUDE_TESTS" -eq 1 ] && SCOPE_ARGS+=(--include-tests)
[ "$EXPAND_IMPORTS" -eq 1 ] && SCOPE_ARGS+=(--expand-imports)
SCOPE_ARGS+=(--base "$BASE_REF")

scope_json="$("$SCRIPT_DIR/compute_scope.sh" "${SCOPE_ARGS[@]}")"

include_count="$(printf '%s' "$scope_json" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["include"]))')"
if [ "$include_count" -eq 0 ]; then
  echo "handoff.sh: computed scope is empty (no changed files vs ${BASE_REF}, and no --paths)." >&2
  echo "Try: --paths <dir> or --base <ref> with a different base." >&2
  exit 5
fi

include_csv="$(printf '%s' "$scope_json" | python3 -c 'import json,sys; print(",".join(json.load(sys.stdin)["include"]))')"
exclude_csv="$(printf '%s' "$scope_json" | python3 -c 'import json,sys; print(",".join(json.load(sys.stdin)["exclude"]))')"

# 3. Build repomix invocation.
if [ "$via" = "global" ]; then
  REPOMIX=(repomix)
else
  REPOMIX=(npx --yes repomix)
fi

REPOMIX_ARGS=(
  --style "$STYLE"
  --output "$OUTPUT"
  --include "$include_csv"
  --ignore "$exclude_csv"
)

if [ "$DRY_RUN" -eq 1 ]; then
  CMD_STR="${REPOMIX[*]} ${REPOMIX_ARGS[*]}"
  OUTPUT="$OUTPUT" STYLE="$STYLE" MAX_TOKENS="$MAX_TOKENS" \
    REVIEWER="${REVIEWER:-default}" CMD_STR="$CMD_STR" SCOPE_JSON="$scope_json" \
    python3 - <<'PY'
import json, os
print(json.dumps({
  "dry_run": True,
  "output": os.environ["OUTPUT"],
  "style": os.environ["STYLE"],
  "max_tokens": int(os.environ["MAX_TOKENS"]),
  "reviewer": os.environ["REVIEWER"],
  "scope": json.loads(os.environ["SCOPE_JSON"]),
  "command": os.environ["CMD_STR"],
}, indent=2))
PY
  exit 0
fi

# 4. Run repomix.
"${REPOMIX[@]}" "${REPOMIX_ARGS[@]}" >/dev/null 2>&1 || {
  echo "handoff.sh: repomix invocation failed. Re-run with verbose flags to debug:" >&2
  echo "  ${REPOMIX[*]} ${REPOMIX_ARGS[*]}" >&2
  exit 6
}

if [ ! -s "$OUTPUT" ]; then
  echo "handoff.sh: repomix produced no output at $OUTPUT" >&2
  exit 7
fi

# 5. Token-budget enforcement.
token_count="$("$SCRIPT_DIR/count_tokens.sh" "$OUTPUT" 2>/dev/null | tr -dc '0-9')"
token_count="${token_count:-0}"

trimmed=()
trim_iterations=0
MAX_TRIM_ITERATIONS=10

# Priority order for trimming (lowest priority first — drop these first).
# We approximate by pattern-matching paths.
TRIM_PATTERNS_ORDER=(
  '\.md$'
  '\.json$'
  '\.d\.ts$'
  '\.css$'
  '\.scss$'
  '\.yaml$'
  '\.yml$'
  '\.html$'
)

# Build a working list from the current include set.
work_csv="$include_csv"

while [ "$token_count" -gt "$MAX_TOKENS" ] && [ "$trim_iterations" -lt "$MAX_TRIM_ITERATIONS" ]; do
  trim_iterations=$((trim_iterations + 1))
  dropped_one=0
  for pat in "${TRIM_PATTERNS_ORDER[@]}"; do
    # Pop the LAST file in work_csv matching pat.
    drop="$(python3 - "$work_csv" "$pat" <<'PY'
import sys, re
files = [f for f in sys.argv[1].split(",") if f]
pat = re.compile(sys.argv[2])
for f in reversed(files):
    if pat.search(f):
        print(f)
        break
PY
)"
    if [ -n "$drop" ]; then
      trimmed+=("$drop")
      work_csv="$(python3 - "$work_csv" "$drop" <<'PY'
import sys
files = [f for f in sys.argv[1].split(",") if f and f != sys.argv[2]]
print(",".join(files))
PY
)"
      dropped_one=1
      break
    fi
  done

  if [ "$dropped_one" -eq 0 ]; then
    # No more low-priority files; drop the largest non-source file.
    drop="$(python3 - "$work_csv" <<'PY'
import sys, os
files = [f for f in sys.argv[1].split(",") if f and os.path.isfile(f)]
files.sort(key=lambda f: os.path.getsize(f), reverse=True)
# Skip the source-code crown jewels: never auto-drop .ts/.tsx/.py/.js/.jsx source unless those are all that remain.
for f in files:
    if not f.endswith((".ts",".tsx",".py",".js",".jsx")):
        print(f); sys.exit(0)
if files:
    print(files[0])
PY
)"
    if [ -z "$drop" ]; then
      echo "handoff.sh: cannot trim further; ${token_count} tokens exceeds budget ${MAX_TOKENS} but no droppable files remain." >&2
      break
    fi
    trimmed+=("$drop")
    work_csv="$(python3 - "$work_csv" "$drop" <<'PY'
import sys
files = [f for f in sys.argv[1].split(",") if f and f != sys.argv[2]]
print(",".join(files))
PY
)"
  fi

  # Re-pack with reduced include set.
  "${REPOMIX[@]}" --style "$STYLE" --output "$OUTPUT" --include "$work_csv" --ignore "$exclude_csv" >/dev/null 2>&1 || {
    echo "handoff.sh: repomix repack failed during trimming" >&2
    break
  }
  token_count="$("$SCRIPT_DIR/count_tokens.sh" "$OUTPUT" 2>/dev/null | tr -dc '0-9')"
  token_count="${token_count:-0}"
done

# 6. Emit summary JSON on stdout.
TRIMMED_BLOB="$(printf '%s\n' "${trimmed[@]:-}")"

OUTPUT="$OUTPUT" STYLE="$STYLE" REVIEWER="${REVIEWER:-default}" \
  MAX_TOKENS="$MAX_TOKENS" TOKEN_COUNT="$token_count" \
  TRIM_ITER="$trim_iterations" WORK_CSV="$work_csv" TRIMMED_BLOB="$TRIMMED_BLOB" \
  python3 - <<'PY'
import json, os
mt = int(os.environ["MAX_TOKENS"])
tc = int(os.environ.get("TOKEN_COUNT") or 0)
inc = [f for f in os.environ["WORK_CSV"].split(",") if f]
trimmed = [l for l in os.environ.get("TRIMMED_BLOB","").splitlines() if l]
print(json.dumps({
  "output": os.environ["OUTPUT"],
  "style": os.environ["STYLE"],
  "reviewer": os.environ["REVIEWER"],
  "max_tokens": mt,
  "token_count": tc,
  "within_budget": tc <= mt,
  "files_included": inc,
  "files_trimmed": trimmed,
  "trim_iterations": int(os.environ["TRIM_ITER"]),
}, indent=2))
PY
