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
#   --output PATH              Output file (default: under a private mktemp -d dir).
#   --base REF                 Base ref for PR-scoped diff (default: origin/main).
#   --expand-imports           Expand seed set 1 hop via static imports.
#   --dry-run                  Print the computed scope and command, don't run.
#
# Side effects: writes snapshot to --output. Prints a JSON summary on stdout.
#
# The include/exclude lists are handed to repomix via a generated --config file
# (JSON arrays), never via --include/--ignore CSV argv — thousands of paths in
# one argv string hit the ~128KB per-arg OS limit (E2BIG), and `,`/`|` are
# legal filename characters (issue #12).
#
# Exit codes:
#   0  ok, snapshot within budget
#   1  runtime failure (repomix missing/failed, mktemp failed, empty output)
#   2  usage error
#   3  snapshot still exceeds --max-tokens after trim exhaustion
#      (the summary JSON is still emitted on stdout with within_budget:false)
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

# Bounds-check before `shift 2`: a value-taking flag as the last arg would make
# `shift 2` fail silently under `set -e` with no diagnostic (issue #12).
need_val() {
  [ "$2" -ge 2 ] || { echo "handoff.sh: $1 requires a value" >&2; exit 2; }
}

while [ $# -gt 0 ]; do
  case "$1" in
    --paths) need_val "$1" $#; PATHS="$2"; shift 2 ;;
    --lang) need_val "$1" $#; LANGS="$2"; shift 2 ;;
    --exclude) need_val "$1" $#; EXTRA_EXCLUDE="$2"; shift 2 ;;
    --include-tests) INCLUDE_TESTS=1; shift ;;
    --style) need_val "$1" $#; STYLE="$2"; shift 2 ;;
    --max-tokens) need_val "$1" $#; MAX_TOKENS="$2"; shift 2 ;;
    --reviewer) need_val "$1" $#; REVIEWER="$2"; shift 2 ;;
    --output) need_val "$1" $#; OUTPUT="$2"; shift 2 ;;
    --base) need_val "$1" $#; BASE_REF="$2"; shift 2 ;;
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

# Usage-error on a non-positive-integer budget (kimi, PR #24 pass 1): a
# negative or non-numeric value would silently corrupt the trim-loop math.
case "$MAX_TOKENS" in
  ''|0|*[!0-9]*) echo "handoff.sh: --max-tokens must be a positive integer (got: '$MAX_TOKENS')" >&2; exit 2 ;;
esac

# Validate style.
case "$STYLE" in
  markdown|xml|plain|json) ;;
  *) echo "handoff.sh: unknown --style '$STYLE'" >&2; exit 2 ;;
esac

# Default output path.
ext="md"
case "$STYLE" in
  xml) ext="xml" ;;
  json) ext="json" ;;
  plain) ext="txt" ;;
  markdown) ext="md" ;;
esac
if [ -z "${OUTPUT:-}" ]; then
  # A private mktemp -d directory (0700) closes the CWE-377 TOCTOU window the
  # old mktemp+mv two-step left open: nothing can pre-place a symlink at a
  # path inside a directory only we can write (issue #12 medium). NOTE: the
  # once-suggested `mktemp -t "name.XXXXXXXX.md"` was smoke-tested and
  # falsified on macOS — BSD mktemp does not substitute embedded X runs.
  _outdir="$(mktemp -d "${TMPDIR:-/tmp}/repomix-handoff.XXXXXXXX")" \
    || { echo "handoff.sh: mktemp failed" >&2; exit 1; }
  OUTPUT="$_outdir/handoff.${ext}"
fi

# Private scratch dir for all inter-process lists (newline-delimited) and the
# generated repomix config. Kept on --dry-run so the printed command remains
# runnable; removed otherwise.
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/repomix-handoff-work.XXXXXXXX")" \
  || { echo "handoff.sh: mktemp failed" >&2; exit 1; }
KEEP_WORK=0
cleanup() { [ "$KEEP_WORK" -eq 1 ] || rm -rf "$WORK_DIR"; }
trap cleanup EXIT

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
  exit 1
fi

# 2. Compute scope.
SCOPE_ARGS=()
[ -n "$PATHS" ] && SCOPE_ARGS+=(--paths "$PATHS")
[ -n "$LANGS" ] && SCOPE_ARGS+=(--lang "$LANGS")
[ -n "$EXTRA_EXCLUDE" ] && SCOPE_ARGS+=(--exclude "$EXTRA_EXCLUDE")
[ "$INCLUDE_TESTS" -eq 1 ] && SCOPE_ARGS+=(--include-tests)
[ "$EXPAND_IMPORTS" -eq 1 ] && SCOPE_ARGS+=(--expand-imports)
SCOPE_ARGS+=(--base "$BASE_REF")

"$SCRIPT_DIR/compute_scope.sh" "${SCOPE_ARGS[@]}" > "$WORK_DIR/scope.json"

# Extract include/exclude as newline-delimited list files, with explicit
# validation of the extraction itself (issue #12 low: include_csv validation).
python3 - "$WORK_DIR/scope.json" "$WORK_DIR/include.txt" "$WORK_DIR/exclude.txt" <<'PY' \
  || { echo "handoff.sh: failed to parse compute_scope.sh output" >&2; exit 1; }
import json, sys
with open(sys.argv[1], encoding="utf-8") as f:
    scope = json.load(f)
inc = scope["include"]
exc = scope["exclude"]
if not isinstance(inc, list) or not isinstance(exc, list):
    raise SystemExit("scope include/exclude are not lists")
with open(sys.argv[2], "w", encoding="utf-8") as f:
    f.write("".join(p + "\n" for p in inc if p))
with open(sys.argv[3], "w", encoding="utf-8") as f:
    f.write("".join(p + "\n" for p in exc if p))
PY

include_count="$(awk 'NF' "$WORK_DIR/include.txt" | wc -l | tr -d ' ')"
if [ "$include_count" -eq 0 ]; then
  echo "handoff.sh: computed scope is empty (no changed files vs ${BASE_REF}, and no --paths)." >&2
  echo "Try: --paths <dir> or --base <ref> with a different base." >&2
  exit 1
fi

# 3. Build repomix invocation. Include/ignore go through a generated config
# file — JSON arrays have no delimiter or argv-length problems.
if [ "$via" = "global" ]; then
  REPOMIX=(repomix)
else
  REPOMIX=(npx --yes repomix)
fi

CONFIG_FILE="$WORK_DIR/repomix.config.json"

# write_repomix_config <include-list-file> — regenerates $CONFIG_FILE.
write_repomix_config() {
  # Passing --config makes repomix IGNORE any repo-level repomix.config.json —
  # including a project's deliberate ignore patterns (privacy-relevant). Merge
  # the repo config's ignores into the generated one so a project's "never
  # pack this" survives the handoff (codex P2, PR #24 pass 2). include stays
  # ours: the computed scope IS the point of the generated config.
  python3 - "$1" "$WORK_DIR/exclude.txt" "$CONFIG_FILE" "repomix.config.json" <<'PY'
import json, sys, os
def lines(p):
    with open(p, encoding="utf-8") as f:
        return [l for l in f.read().splitlines() if l]
ignore = lines(sys.argv[2])
repo_cfg_path = sys.argv[4]
if os.path.isfile(repo_cfg_path):
    try:
        with open(repo_cfg_path, encoding="utf-8") as f:
            repo_cfg = json.load(f)
        for pat in (repo_cfg.get("ignore", {}) or {}).get("customPatterns", []) or []:
            if isinstance(pat, str) and pat and pat not in ignore:
                ignore.append(pat)
    except Exception as e:
        print(f"handoff.sh: could not merge {repo_cfg_path}: {e}", file=sys.stderr)
cfg = {"include": lines(sys.argv[1]), "ignore": {"customPatterns": ignore}}
with open(sys.argv[3], "w", encoding="utf-8") as f:
    json.dump(cfg, f)
PY
}

# The working include set for trimming, newline-delimited.
cp "$WORK_DIR/include.txt" "$WORK_DIR/work.txt"
: > "$WORK_DIR/trimmed.txt"
write_repomix_config "$WORK_DIR/work.txt"

if [ "$DRY_RUN" -eq 1 ]; then
  KEEP_WORK=1
  CMD_STR="${REPOMIX[*]} --config $CONFIG_FILE --style $STYLE --output $OUTPUT"
  OUTPUT="$OUTPUT" STYLE="$STYLE" MAX_TOKENS="$MAX_TOKENS" \
    REVIEWER="${REVIEWER:-default}" CMD_STR="$CMD_STR" CONFIG_FILE="$CONFIG_FILE" \
    python3 - "$WORK_DIR/scope.json" <<'PY'
import json, os, sys
with open(sys.argv[1], encoding="utf-8") as f:
    scope = json.load(f)
print(json.dumps({
  "dry_run": True,
  "output": os.environ["OUTPUT"],
  "style": os.environ["STYLE"],
  "max_tokens": int(os.environ["MAX_TOKENS"]),
  "reviewer": os.environ["REVIEWER"],
  "scope": scope,
  "config": os.environ["CONFIG_FILE"],
  "command": os.environ["CMD_STR"],
}, indent=2))
PY
  exit 0
fi

# run_repomix — pack the current work set into $OUTPUT.
run_repomix() {
  "${REPOMIX[@]}" --config "$CONFIG_FILE" --style "$STYLE" --output "$OUTPUT" \
    >/dev/null 2>"$WORK_DIR/repomix.stderr"
}

# 4. Run repomix.
if ! run_repomix; then
  echo "handoff.sh: repomix invocation failed:" >&2
  cat "$WORK_DIR/repomix.stderr" >&2
  echo "  re-run manually: ${REPOMIX[*]} --config $CONFIG_FILE --style $STYLE --output $OUTPUT" >&2
  exit 1
fi

if [ ! -s "$OUTPUT" ]; then
  echo "handoff.sh: repomix produced no output at $OUTPUT" >&2
  exit 1
fi

# 5. Token-budget enforcement.
token_count="$("$SCRIPT_DIR/count_tokens.sh" "$OUTPUT" 2>/dev/null | tr -dc '0-9')"
token_count="${token_count:-0}"

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
# Batches land as newline-delimited files under $WORK_DIR/batches/ — never
# comma/pipe-joined strings (issue #12: `,` and `|` are legal in filenames).
mkdir -p "$WORK_DIR/batches"
python3 - "$WORK_DIR/work.txt" "$WORK_DIR/batches" <<'PY'
import os, re, sys
with open(sys.argv[1], encoding="utf-8") as f:
    files = [l for l in f.read().splitlines() if l]
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
for i, b in enumerate(batches):
    with open(os.path.join(sys.argv[2], "batch_%04d" % i), "w", encoding="utf-8") as out:
        out.write("".join(f + "\n" for f in b))
PY

batch_files=()
while IFS= read -r bf; do
  [ -n "$bf" ] && batch_files+=("$bf")
done < <(find "$WORK_DIR/batches" -type f -name 'batch_*' 2>/dev/null | LC_ALL=C sort)

next_batch=0
while [ "$token_count" -gt "$MAX_TOKENS" ] && [ "$trim_iterations" -lt "$MAX_TRIM_ITERATIONS" ]; do
  if [ "$next_batch" -ge "${#batch_files[@]}" ]; then
    echo "handoff.sh: cannot trim further; ${token_count} tokens exceeds budget ${MAX_TOKENS} but no droppable files remain." >&2
    break
  fi
  trim_iterations=$((trim_iterations + 1))

  # Drop this batch from work.txt and record what we dropped.
  drop_file="${batch_files[$next_batch]}"
  next_batch=$((next_batch + 1))

  python3 - "$WORK_DIR/work.txt" "$drop_file" "$WORK_DIR/trimmed.txt" <<'PY'
import sys
def lines(p):
    with open(p, encoding="utf-8") as f:
        return [l for l in f.read().splitlines() if l]
work = lines(sys.argv[1])
drop = set(lines(sys.argv[2]))
kept = [f for f in work if f not in drop]
with open(sys.argv[1] + ".new", "w", encoding="utf-8") as f:
    f.write("".join(x + "\n" for x in kept))
with open(sys.argv[3], "a", encoding="utf-8") as f:
    f.write("".join(x + "\n" for x in sorted(drop)))
PY
  mv "$WORK_DIR/work.txt.new" "$WORK_DIR/work.txt"

  # Re-pack with reduced include set. Surface repomix failures — don't silently
  # ship a stale snapshot with a wrong token count.
  write_repomix_config "$WORK_DIR/work.txt"
  if ! run_repomix; then
    dropped_count="$(awk 'NF' "$WORK_DIR/trimmed.txt" | wc -l | tr -d ' ')"
    echo "handoff.sh: repomix repack failed during trimming (iteration $trim_iterations, after dropping ${dropped_count} files):" >&2
    cat "$WORK_DIR/repomix.stderr" >&2
    exit 1
  fi
  token_count="$("$SCRIPT_DIR/count_tokens.sh" "$OUTPUT" 2>/dev/null | tr -dc '0-9')"
  token_count="${token_count:-0}"
done

# 6. Emit summary JSON on stdout.
OUTPUT="$OUTPUT" STYLE="$STYLE" REVIEWER="${REVIEWER:-default}" \
  MAX_TOKENS="$MAX_TOKENS" TOKEN_COUNT="$token_count" TRIM_ITER="$trim_iterations" \
  python3 - "$WORK_DIR/work.txt" "$WORK_DIR/trimmed.txt" <<'PY'
import json, os, sys
def lines(p):
    with open(p, encoding="utf-8") as f:
        return [l for l in f.read().splitlines() if l]
mt = int(os.environ["MAX_TOKENS"])
tc = int(os.environ.get("TOKEN_COUNT") or 0)
print(json.dumps({
  "output": os.environ["OUTPUT"],
  "style": os.environ["STYLE"],
  "reviewer": os.environ["REVIEWER"],
  "max_tokens": mt,
  "token_count": tc,
  "within_budget": tc <= mt,
  "files_included": lines(sys.argv[1]),
  "files_trimmed": lines(sys.argv[2]),
  "trim_iterations": int(os.environ["TRIM_ITER"]),
}, indent=2))
PY

# Source files are deliberately never in the drop list, so a low enough
# --max-tokens on a source-heavy diff can genuinely exhaust every batch
# before reaching budget. Callers checking only the exit code — which is
# exactly how cross-review's step 2.5 invokes this (`>/dev/null`, JSON
# discarded) — must not mistake that for success (issue #12 high). The JSON
# above still carries the details (within_budget: false).
if [ "$token_count" -gt "$MAX_TOKENS" ]; then
  echo "handoff.sh: snapshot exceeds token budget (${token_count} > ${MAX_TOKENS}) after trim exhaustion" >&2
  exit 3
fi
