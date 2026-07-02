#!/usr/bin/env bash
# build_graph.sh — build (or reuse cache of) the forward import graph as JSON.
#
# Output: writes graph JSON to $CACHE_DIR/graph.json
# Cache key combines lockfile hash + root tsconfig hash + a signature over
# every source file's (path, mtime, size) — so editing imports inside an
# existing file invalidates the cache without hashing file contents.
# Use --refresh to force rebuild.
#
# Exit codes: 0 ok, 1 runtime failure (graph tool failed), 2 usage.
#
# The graph schema is a normalized adjacency list:
#   { "files": { "src/a.ts": ["src/b.ts", "src/c.ts"], ... } }
# Both madge and depcruise output formats are converted to this shape.

set -euo pipefail

repo_root="${IMPACT_REPO_ROOT:-$(pwd)}"
cache_dir="$repo_root/.impact-cache"
mkdir -p "$cache_dir"

refresh="false"
for arg in "$@"; do
  case "$arg" in
    --refresh) refresh="true" ;;
  esac
done

# --- cache key -------------------------------------------------------------

hash_file() {
  if [ -f "$1" ]; then
    if command -v shasum >/dev/null 2>&1; then
      shasum -a 256 "$1" | awk '{print $1}'
    else
      sha256sum "$1" | awk '{print $1}'
    fi
  else
    echo "missing"
  fi
}

lock_hash="none"
for lock in pnpm-lock.yaml package-lock.json yarn.lock; do
  if [ -f "$repo_root/$lock" ]; then
    lock_hash=$(hash_file "$repo_root/$lock")
    break
  fi
done

tsconfig_hash=$(hash_file "$repo_root/tsconfig.json")

# Source-file signature: sha256 over every source file's (path, mtime_ns, size).
# Cheap — stat only, no content reads — but catches import edits inside existing
# files, which the old coarse file-count key missed (issue #12, flagged in all
# 4 review passes). `|| true` guards pipefail against find permission errors.
files_sig=$({ find "$repo_root" \
  -type d \( -name node_modules -o -name .git -o -name dist -o -name build -o -name .next -o -name coverage -o -name .impact-cache \) -prune \
  -o -type f \( -name '*.ts' -o -name '*.tsx' -o -name '*.js' -o -name '*.jsx' -o -name '*.mjs' -o -name '*.cjs' \) -print 2>/dev/null || true; } \
  | LC_ALL=C sort | python3 -c '
import hashlib, os, sys
h = hashlib.sha256()
n = 0
for line in sys.stdin:
    p = line.rstrip("\n")
    try:
        st = os.stat(p)
    except OSError:
        continue
    n += 1
    h.update(("%s|%d|%d\n" % (p, st.st_mtime_ns, st.st_size)).encode())
print("%d-%s" % (n, h.hexdigest()))
')

key="$lock_hash|$tsconfig_hash|$files_sig"
key_file="$cache_dir/graph.key"
graph_file="$cache_dir/graph.json"

if [ "$refresh" != "true" ] && [ -f "$key_file" ] && [ -f "$graph_file" ]; then
  existing=$(cat "$key_file")
  if [ "$existing" = "$key" ]; then
    echo "$graph_file"
    exit 0
  fi
fi

# --- detect tool -----------------------------------------------------------

script_dir="$(cd "$(dirname "$0")" && pwd)"
detect_json=$("$script_dir/detect_tools.sh")
preferred=$(printf '%s' "$detect_json" | sed -n 's/.*"preferred": *"\([^"]*\)".*/\1/p')

# Resolve binary command as an array. Sets the global RESOLVED_BIN_CMD; callers
# should copy it before the next resolve_bin call.
#
# Why a global out var instead of `eval`-by-name: an eval like
# `eval "$outvar=(\"$x\")"` evaluates command substitution inside the
# double-quoted string at eval time, so a $repo_root containing $(...) would
# actually execute. Caught by cross-review pass 2 (gemini).
RESOLVED_BIN_CMD=()
resolve_bin() {
  local name="$1"
  RESOLVED_BIN_CMD=()
  if [ -x "$repo_root/node_modules/.bin/$name" ]; then
    RESOLVED_BIN_CMD=("$repo_root/node_modules/.bin/$name")
  elif command -v "$name" >/dev/null 2>&1; then
    RESOLVED_BIN_CMD=("$name")
  else
    RESOLVED_BIN_CMD=(npx --no-install "$name")
  fi
}

ts_flag=()
if [ -f "$repo_root/tsconfig.json" ]; then
  ts_flag=(--ts-config "$repo_root/tsconfig.json")
fi

# PID-suffix the intermediates so concurrent invocations don't clobber each other.
tmp_raw="$cache_dir/graph.raw.$$.json"
tool_err="$cache_dir/graph.stderr.$$.log"
graph_tmp="$graph_file.tmp.$$"
trap 'rm -f "$tmp_raw" "$tool_err" "$graph_tmp"' EXIT

# Shared node converter epilogue: write to a PID-suffixed tmp in the same dir,
# then rename — a concurrent reader never sees a half-written graph.json.
# (issue #12 high: atomic write)

build_with_depcruise() {
  resolve_bin depcruise
  local bin_cmd=("${RESOLVED_BIN_CMD[@]}")
  # depcruise emits {modules: [{source, dependencies: [{resolved, ...}], ...}]}
  # We restrict to source extensions and skip node_modules.
  # `${arr[@]+...}` guards against `set -u` crashing on an empty `ts_flag` (bash 3.2 / macOS default).
  # stderr goes to $tool_err and is surfaced on failure — `2>/dev/null` used to
  # hide syntax/OOM/missing-tsconfig errors (issue #12 high).
  if ! ( cd "$repo_root" && \
    "${bin_cmd[@]}" --output-type json \
      --exclude '(^|/)(node_modules|dist|build|\.next|coverage|\.impact-cache)(/|$)' \
      --include-only '\.(m?j|t)sx?$' \
      ${ts_flag[@]+"${ts_flag[@]}"} \
      . > "$tmp_raw" 2>"$tool_err" ); then
    echo "ERROR: depcruise failed while building the import graph:" >&2
    cat "$tool_err" >&2
    exit 1
  fi

  # Convert to normalized adjacency via node one-liner (node always available if depcruise is)
  node -e '
    const fs = require("fs");
    const raw = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
    const out = { files: {} };
    for (const m of (raw.modules || [])) {
      const deps = (m.dependencies || [])
        .map(d => d.resolved)
        .filter(Boolean);
      out.files[m.source] = deps;
    }
    fs.writeFileSync(process.argv[3], JSON.stringify(out));
    fs.renameSync(process.argv[3], process.argv[2]);
  ' "$tmp_raw" "$graph_file" "$graph_tmp"
}

build_with_madge() {
  resolve_bin madge
  local bin_cmd=("${RESOLVED_BIN_CMD[@]}")
  if ! ( cd "$repo_root" && \
    "${bin_cmd[@]}" --json \
      --extensions ts,tsx,js,jsx,mjs,cjs \
      --exclude '(^|/)(node_modules|dist|build|\.next|coverage|\.impact-cache)(/|$)' \
      ${ts_flag[@]+"${ts_flag[@]}"} \
      . > "$tmp_raw" 2>"$tool_err" ); then
    echo "ERROR: madge failed while building the import graph:" >&2
    cat "$tool_err" >&2
    exit 1
  fi

  # madge output is already an adjacency map of relative paths -> [deps]
  node -e '
    const fs = require("fs");
    const raw = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
    const out = { files: {} };
    for (const k of Object.keys(raw)) out.files[k] = raw[k];
    fs.writeFileSync(process.argv[3], JSON.stringify(out));
    fs.renameSync(process.argv[3], process.argv[2]);
  ' "$tmp_raw" "$graph_file" "$graph_tmp"
}

build_with_grep() {
  # Degraded fallback: a sparse graph from `grep -RE "from ['\"]"`.
  # Only one-hop edges; resolution is heuristic. Used only when no tool is installed.
  node -e '
    const fs = require("fs"), path = require("path");
    const root = process.argv[1];
    const ignore = /(?:^|\/)(?:node_modules|dist|build|\.next|coverage|\.impact-cache|\.git)(?:\/|$)/;
    const exts = [".ts",".tsx",".js",".jsx",".mjs",".cjs"];
    function walk(dir, acc) {
      for (const ent of fs.readdirSync(dir, { withFileTypes: true })) {
        const p = path.join(dir, ent.name);
        if (ignore.test(p)) continue;
        if (ent.isDirectory()) walk(p, acc);
        else if (exts.includes(path.extname(ent.name))) acc.push(p);
      }
      return acc;
    }
    const files = walk(root, []);
    const importRe = /(?:^|\s)(?:import|export)\s[^;]*?from\s+["\x27]([^"\x27]+)["\x27]/g;
    const out = { files: {} };
    for (const f of files) {
      const rel = path.relative(root, f);
      const src = fs.readFileSync(f, "utf8");
      const deps = new Set();
      let m;
      while ((m = importRe.exec(src))) {
        const spec = m[1];
        if (!spec.startsWith(".")) continue;
        const base = path.resolve(path.dirname(f), spec);
        // try extensions
        for (const e of ["", ...exts, "/index.ts", "/index.tsx", "/index.js"]) {
          const cand = base + e;
          if (fs.existsSync(cand) && fs.statSync(cand).isFile()) {
            deps.add(path.relative(root, cand));
            break;
          }
        }
      }
      out.files[rel] = [...deps];
    }
    fs.writeFileSync(process.argv[3], JSON.stringify(out));
    fs.renameSync(process.argv[3], process.argv[2]);
  ' "$repo_root" "$graph_file" "$graph_tmp"
}

case "$preferred" in
  depcruiser) build_with_depcruise ;;
  madge)      build_with_madge ;;
  none)
    echo "WARN: neither madge nor dependency-cruiser found; using grep fallback (one-hop only)." >&2
    build_with_grep
    ;;
esac

echo "$key" > "$key_file"
echo "$graph_file"
