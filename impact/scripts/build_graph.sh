#!/usr/bin/env bash
# build_graph.sh — build (or reuse cache of) the forward import graph as JSON.
#
# Output: writes graph JSON to $CACHE_DIR/graph.json
# Cache key combines lockfile hash + root tsconfig hash + a coarse file count.
# Use --refresh to force rebuild.
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

# Coarse file count (cheap, no full scan)
file_count=$(find "$repo_root" \
  -type d \( -name node_modules -o -name .git -o -name dist -o -name build -o -name .next -o -name coverage -o -name .impact-cache \) -prune \
  -o -type f \( -name '*.ts' -o -name '*.tsx' -o -name '*.js' -o -name '*.jsx' -o -name '*.mjs' -o -name '*.cjs' \) -print 2>/dev/null | wc -l | tr -d ' ')

key="$lock_hash|$tsconfig_hash|$file_count"
key_file="$cache_dir/graph.key"
graph_file="$cache_dir/graph.json"

if [ "$refresh" != "true" ] && [ -f "$key_file" ] && [ -f "$graph_file" ]; then
  existing=$(cat "$key_file")
  if [ "$existing" = "$key" ]; then
    echo "$graph_file"
    exit 0
  fi
fi

# --- detect tool, auto-installing dependency-cruiser if this is a JS/TS repo
# with neither tool available (opt out with IMPACT_NO_AUTO_INSTALL=1) --------

script_dir="$(cd "$(dirname "$0")" && pwd)"
detect_json=$("$script_dir/detect_tools.sh")
preferred=$(printf '%s' "$detect_json" | sed -n 's/.*"preferred": *"\([^"]*\)".*/\1/p')

# Pick the package manager matching the repo's lockfile, mirroring the three
# variants documented in references/install.md. Sets the global
# RESOLVED_INSTALL_CMD; empty if no supported package manager is on PATH.
RESOLVED_INSTALL_CMD=()
resolve_install_cmd() {
  RESOLVED_INSTALL_CMD=()
  if [ -f "$repo_root/pnpm-lock.yaml" ] && command -v pnpm >/dev/null 2>&1; then
    RESOLVED_INSTALL_CMD=(pnpm add -D dependency-cruiser)
    # -w ("workspace root") is pnpm's flag for installing at a workspace root
    # from a subdirectory — it hard-errors ("may only be used inside a
    # workspace") on a plain single-package repo, which is the common case.
    # Only add it when pnpm-workspace.yaml proves this really is a workspace.
    [ -f "$repo_root/pnpm-workspace.yaml" ] && RESOLVED_INSTALL_CMD+=(-w)
  elif [ -f "$repo_root/yarn.lock" ] && command -v yarn >/dev/null 2>&1; then
    RESOLVED_INSTALL_CMD=(yarn add -D dependency-cruiser)
    # Same idea for yarn classic's -W ("this is intentionally the workspace root").
    if grep -q '"workspaces"' "$repo_root/package.json" 2>/dev/null; then
      RESOLVED_INSTALL_CMD+=(-W)
    fi
  elif command -v npm >/dev/null 2>&1; then
    RESOLVED_INSTALL_CMD=(npm install -D dependency-cruiser)
  fi
}

auto_install_depcruiser() {
  # Only a real Node project has a package.json to add a devDependency to;
  # skip silently for non-JS repos (e.g. this very repo, mostly bash/markdown).
  [ -f "$repo_root/package.json" ] || return 1

  resolve_install_cmd
  [ "${#RESOLVED_INSTALL_CMD[@]}" -eq 0 ] && return 1

  local install_log="$cache_dir/install.log"
  echo "impact: neither madge nor dependency-cruiser found — installing dependency-cruiser (${RESOLVED_INSTALL_CMD[*]})..." >&2
  if ( cd "$repo_root" && "${RESOLVED_INSTALL_CMD[@]}" ) >"$install_log" 2>&1; then
    echo "impact: installed dependency-cruiser as a devDependency." >&2
    return 0
  else
    echo "impact: auto-install failed (see $install_log); falling back to grep-based analysis. Install manually: pnpm add -D -w dependency-cruiser" >&2
    return 1
  fi
}

if [ "$preferred" = "none" ] && [ "${IMPACT_NO_AUTO_INSTALL:-}" != "1" ]; then
  if auto_install_depcruiser; then
    # The install just changed the lockfile — recompute the cache key so the
    # graph we're about to build (with the new tool) isn't shadowed by a
    # stale grep-built cache entry keyed off the pre-install lockfile hash.
    for lock in pnpm-lock.yaml package-lock.json yarn.lock; do
      if [ -f "$repo_root/$lock" ]; then
        lock_hash=$(hash_file "$repo_root/$lock")
        break
      fi
    done
    key="$lock_hash|$tsconfig_hash|$file_count"
    detect_json=$("$script_dir/detect_tools.sh")
    preferred=$(printf '%s' "$detect_json" | sed -n 's/.*"preferred": *"\([^"]*\)".*/\1/p')
  fi
fi

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

# dependency-cruiser >=17 errors out ("Can't open a config file") instead of
# running config-free by default. Only pass --no-config when the repo truly
# has no config, so an existing one (with the forbidden-dep rules etc. from
# references/install.md) is still picked up and respected.
depcruise_config_flag=()
depcruise_has_config="false"
for cfg in .dependency-cruiser.cjs .dependency-cruiser.mjs .dependency-cruiser.js .dependency-cruiser.json; do
  [ -f "$repo_root/$cfg" ] && depcruise_has_config="true" && break
done
[ "$depcruise_has_config" = "false" ] && depcruise_config_flag=(--no-config)

# PID-suffix the intermediate so concurrent invocations don't clobber each other.
tmp_raw="$cache_dir/graph.raw.$$.json"
trap 'rm -f "$tmp_raw"' EXIT

build_with_depcruise() {
  resolve_bin depcruise
  local bin_cmd=("${RESOLVED_BIN_CMD[@]}")
  # depcruise emits {modules: [{source, dependencies: [{resolved, ...}], ...}]}
  # We restrict to source extensions and skip node_modules.
  # `${arr[@]+...}` guards against `set -u` crashing on an empty array (bash 3.2 / macOS default).
  ( cd "$repo_root" && \
    "${bin_cmd[@]}" --output-type json \
      --exclude '(^|/)(node_modules|dist|build|\.next|coverage|\.impact-cache)(/|$)' \
      --include-only '\.(m?j|t)sx?$' \
      ${depcruise_config_flag[@]+"${depcruise_config_flag[@]}"} \
      ${ts_flag[@]+"${ts_flag[@]}"} \
      . > "$tmp_raw" 2>"$cache_dir/depcruise.err.log" )

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
    fs.writeFileSync(process.argv[2], JSON.stringify(out));
  ' "$tmp_raw" "$graph_file"
}

build_with_madge() {
  resolve_bin madge
  local bin_cmd=("${RESOLVED_BIN_CMD[@]}")
  ( cd "$repo_root" && \
    "${bin_cmd[@]}" --json \
      --extensions ts,tsx,js,jsx,mjs,cjs \
      --exclude '(^|/)(node_modules|dist|build|\.next|coverage|\.impact-cache)(/|$)' \
      ${ts_flag[@]+"${ts_flag[@]}"} \
      . > "$tmp_raw" 2>"$cache_dir/madge.err.log" )

  # madge output is already an adjacency map of relative paths -> [deps]
  node -e '
    const fs = require("fs");
    const raw = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
    const out = { files: {} };
    for (const k of Object.keys(raw)) out.files[k] = raw[k];
    fs.writeFileSync(process.argv[2], JSON.stringify(out));
  ' "$tmp_raw" "$graph_file"
}

build_with_grep() {
  # Degraded fallback: a sparse graph from `grep -RE "from ['\"]"`.
  # Only one-hop edges; resolution is heuristic. Used only when no tool is installed.
  node -e '
    const fs = require("fs"), path = require("path"), cp = require("child_process");
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
    fs.writeFileSync(process.argv[2], JSON.stringify(out));
  ' "$repo_root" "$graph_file"
}

# True (exit 0) when graph.json has zero files even though the repo clearly
# has source to crawl ($file_count > 0). A tool can exit 0 and still produce
# nothing — e.g. dependency-cruiser silently disables .ts/.tsx parsing with
# no error when the installed `typescript` version falls outside its
# supported peer range (confirmed live: depcruise 18.1.0 + typescript 7.0.2
# → 0 modules, no warning, `depcruise -i` is the only way to see it happened).
# Trusting that blindly would render a confidently wrong "(none)" report.
graph_is_suspiciously_empty() {
  [ "$file_count" -eq 0 ] && return 1
  node -e '
    try {
      const g = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
      process.exit(Object.keys(g.files || {}).length === 0 ? 0 : 1);
    } catch { process.exit(0); }
  ' "$graph_file"
}

case "$preferred" in
  depcruiser)
    if ! build_with_depcruise || graph_is_suspiciously_empty; then
      echo "WARN: dependency-cruiser produced an empty graph despite $file_count source file(s) present (see $cache_dir/depcruise.err.log, or run \`node_modules/.bin/depcruise -i\` to check which extensions/transpilers it has enabled — a common cause is the installed \`typescript\` version falling outside depcruise's supported peer range); falling back to grep (one-hop only)." >&2
      build_with_grep
    fi
    ;;
  madge)
    if ! build_with_madge || graph_is_suspiciously_empty; then
      echo "WARN: madge produced an empty graph despite $file_count source file(s) present (see $cache_dir/madge.err.log); falling back to grep (one-hop only)." >&2
      build_with_grep
    fi
    ;;
  none)
    echo "WARN: neither madge nor dependency-cruiser found; using grep fallback (one-hop only)." >&2
    build_with_grep
    ;;
esac

echo "$key" > "$key_file"
echo "$graph_file"
