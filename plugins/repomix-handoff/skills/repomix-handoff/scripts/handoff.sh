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

# Default output path. Use mktemp instead of a predictable /tmp filename so a
# malicious symlink at the expected path can't redirect our write (CWE-377).
ext="md"
case "$STYLE" in
  xml) ext="xml" ;;
  json) ext="json" ;;
  plain) ext="txt" ;;
  markdown) ext="md" ;;
esac
if [ -z "${OUTPUT:-}" ]; then
  # macOS mktemp doesn't honor a suffix placed after the X template — it
  # treats "repomix-handoff.XXXXXXXX.md" as a literal prefix and appends its
  # own random suffix at the very end, so `mktemp -t "foo.XXXXXXXX.$ext"`
  # does NOT produce a "foo.<rand>.$ext"-shaped name on macOS (verified).
  # The old two-step mktemp-then-mv left a window where the final,
  # non-mktemp'd "$OUTPUT" path didn't exist yet — a pre-placed file or
  # symlink there would get silently clobbered by `mv` (CWE-377). Build the
  # random component ourselves and create the final path atomically with
  # noclobber (O_EXCL semantics): refuses if anything is already there,
  # instead of writing through it.
  rand="$(od -An -N8 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n')"
  [ -n "$rand" ] || rand="$$-$RANDOM"
  OUTPUT="${TMPDIR:-/tmp}/repomix-handoff.${rand}.${ext}"
  if ! ( set -C; : > "$OUTPUT" ) 2>/dev/null; then
    echo "handoff.sh: could not create $OUTPUT (unexpected collision)" >&2
    exit 9
  fi
fi

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

# Build a single priority-ordered drop list upfront. Each iteration drops a
# whole batch (all files at the next priority level) instead of one file,
# so we don't burn 10 re-packs to shed a few KB of markdown.
#
# Priority order (lowest priority first — drop these first):
#   1. *.md   2. *.json   3. *.d.ts   4. *.css   5. *.scss
#   6. *.yaml 7. *.yml    8. *.html
# After those exhaust, drop largest non-source files (never .ts/.tsx/.py/.js/.jsx).
work_csv="$include_csv"

# Emit batches of file paths in drop-priority order, one batch per line,
# comma-separated. Last batch is the size-sorted non-source fallback.
DROP_BATCHES="$(python3 - "$work_csv" <<'PY'
import os, sys, re
files = [f for f in sys.argv[1].split(",") if f]
patterns = [r'\.md$', r'\.json$', r'\.d\.ts$', r'\.css$', r'\.scss$',
            r'\.yaml$', r'\.yml$', r'\.html$']
batches = []
remaining = list(files)
for p in patterns:
    rx = re.compile(p)
    batch = [f for f in remaining if rx.search(f)]
    if batch:
        batches.append(batch)
        remaining = [f for f in remaining if f not in set(batch)]
# Fallback: largest non-source files, one per batch so we re-pack between drops.
src_exts = (".ts", ".tsx", ".mjs", ".cjs", ".py", ".js", ".jsx")
non_src = [f for f in remaining if os.path.isfile(f) and not f.endswith(src_exts)]
non_src.sort(key=lambda f: os.path.getsize(f), reverse=True)
for f in non_src:
    batches.append([f])
for b in batches:
    print(",".join(b))
PY
)"

# Convert the multi-line blob to a bash array, one batch per element.
batches=()
while IFS= read -r line; do
  [ -n "$line" ] && batches+=("$line")
done <<< "$DROP_BATCHES"

next_batch=0
while [ "$token_count" -gt "$MAX_TOKENS" ] && [ "$trim_iterations" -lt "$MAX_TRIM_ITERATIONS" ]; do
  if [ "$next_batch" -ge "${#batches[@]}" ]; then
    echo "handoff.sh: cannot trim further; ${token_count} tokens exceeds budget ${MAX_TOKENS} but no droppable files remain." >&2
    break
  fi
  trim_iterations=$((trim_iterations + 1))

  # Drop this batch from work_csv and record what we dropped.
  drop_csv="${batches[$next_batch]}"
  next_batch=$((next_batch + 1))

  result="$(python3 - "$work_csv" "$drop_csv" <<'PY'
import sys
work = [f for f in sys.argv[1].split(",") if f]
drop = set(f for f in sys.argv[2].split(",") if f)
kept = [f for f in work if f not in drop]
print(",".join(kept))
print("|".join(sorted(drop)))
PY
)"
  work_csv="$(printf '%s\n' "$result" | sed -n '1p')"
  dropped_blob="$(printf '%s\n' "$result" | sed -n '2p')"
  if [ -n "$dropped_blob" ]; then
    while IFS= read -r d; do
      [ -n "$d" ] && trimmed+=("$d")
    done < <(printf '%s\n' "$dropped_blob" | tr '|' '\n')
  fi

  # Re-pack with reduced include set. Surface repomix failures — don't silently
  # ship a stale snapshot with a wrong token count.
  if ! "${REPOMIX[@]}" --style "$STYLE" --output "$OUTPUT" \
        --include "$work_csv" --ignore "$exclude_csv" >/dev/null 2>&1; then
    echo "handoff.sh: repomix repack failed during trimming (iteration $trim_iterations, after dropping ${#trimmed[@]} files)" >&2
    echo "  retry without trimming: ${REPOMIX[*]} --style $STYLE --output $OUTPUT --include $work_csv" >&2
    exit 8
  fi
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

# Source files are deliberately never in the drop list, so a low enough
# --max-tokens on a source-heavy diff can genuinely exhaust every batch
# before reaching budget. The JSON above already says so (within_budget:
# false), but a caller that only checks the exit code — which is exactly how
# cross-review's step 2.5 invokes this (`>/dev/null`, JSON discarded) — would
# otherwise see success and silently hand reviewers an oversized snapshot.
if [ "$token_count" -gt "$MAX_TOKENS" ]; then
  echo "handoff.sh: exhausted every droppable batch; ${token_count} tokens still exceeds budget ${MAX_TOKENS}." >&2
  exit 10
fi
