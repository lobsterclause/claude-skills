#!/usr/bin/env bash
# impact.sh — main entrypoint. Resolves entry files, builds/loads the dep graph,
# inverts it to find reverse-deps, groups by workspace package, finds matching
# test files, and prints a structured report.
#
# Usage:
#   impact.sh                       # auto: `git diff HEAD`
#   impact.sh --staged              # `git diff --cached`
#   impact.sh --base <ref>          # `git diff <ref>...HEAD`
#   impact.sh path1 [path2 ...]     # explicit
#   impact.sh --refresh             # force-rebuild graph cache
#   impact.sh --json                # JSON output
#
# Exit codes: 0 ok, 1 runtime failure, 2 usage.

set -euo pipefail

repo_root="${IMPACT_REPO_ROOT:-$(pwd)}"
export IMPACT_REPO_ROOT="$repo_root"
script_dir="$(cd "$(dirname "$0")" && pwd)"

mode="diff"          # diff | staged | base | explicit
base_ref=""
json="false"
refresh="false"
explicit=()

while [ $# -gt 0 ]; do
  case "$1" in
    --staged) mode="staged"; shift ;;
    --base)
      # Bounds-check before `shift 2`: `--base` as the last arg would make
      # `shift 2` fail (silently, under set -e) with no diagnostic (issue #12).
      [ $# -ge 2 ] || { echo "ERROR: --base requires a ref argument" >&2; exit 2; }
      mode="base"; base_ref="$2"; shift 2 ;;
    --refresh) refresh="true"; shift ;;
    --json)   json="true"; shift ;;
    -h|--help)
      sed -n '2,14p' "$0"; exit 0 ;;
    --) shift; while [ $# -gt 0 ]; do explicit+=("$1"); shift; done ;;
    -*)
      echo "unknown flag: $1" >&2; exit 2 ;;
    *) explicit+=("$1"); mode="explicit"; shift ;;
  esac
done

# --- resolve entry files ---------------------------------------------------

entries=()
if [ "$mode" = "explicit" ]; then
  for p in "${explicit[@]}"; do
    entries+=("$p")
  done
else
  if ! git -C "$repo_root" rev-parse --git-dir >/dev/null 2>&1; then
    echo "ERROR: not a git repo and no explicit paths given" >&2
    exit 2
  fi
  case "$mode" in
    diff)   diff_cmd=(git -C "$repo_root" diff --name-only HEAD) ;;
    staged) diff_cmd=(git -C "$repo_root" diff --name-only --cached) ;;
    base)
      [ -z "$base_ref" ] && { echo "ERROR: --base requires a ref" >&2; exit 2; }
      diff_cmd=(git -C "$repo_root" diff --name-only "${base_ref}...HEAD") ;;
  esac
  while IFS= read -r f; do
    case "$f" in
      *.ts|*.tsx|*.js|*.jsx|*.mjs|*.cjs) entries+=("$f") ;;
    esac
  done < <("${diff_cmd[@]}")
fi

if [ "${#entries[@]}" -eq 0 ]; then
  if [ "$json" = "true" ]; then
    echo '{"entries":[],"reverseDeps":{},"tests":[],"note":"no code changes"}'
  else
    echo "no code changes detected (mode=$mode)"
  fi
  exit 0
fi

# --- build / load graph ----------------------------------------------------

graph_args=()
[ "$refresh" = "true" ] && graph_args+=(--refresh)
graph_file=$("$script_dir/build_graph.sh" "${graph_args[@]}")

# --- invert graph and compute reverse deps ---------------------------------
# Use node for speed; the graph can be 100k+ nodes on a big monorepo.

# Entries are handed to node via a newline-delimited temp file, not argv:
#   - `|` (the old join delimiter) is legal in filenames (issue #12 high);
#   - thousands of changed paths in one argv string hits ARG_MAX/E2BIG
#     (~128KB per-arg OS limit) on huge PRs (issue #12 design high).
entries_file=$(mktemp "${TMPDIR:-/tmp}/impact-entries.XXXXXXXX")
tests_file=$(mktemp "${TMPDIR:-/tmp}/impact-tests.XXXXXXXX")
trap 'rm -f "$entries_file" "$tests_file"' EXIT
printf '%s\n' "${entries[@]}" | awk 'NF' > "$entries_file"

report_json=$(node -e '
  const fs = require("fs"), path = require("path");
  const graph = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
  const entries = fs.readFileSync(process.argv[2], "utf8").split("\n").filter(Boolean);
  const root = process.argv[3];

  // Normalize: graph keys may be relative; entries from git diff are relative.
  const nodes = Object.keys(graph.files || {});
  const norm = s => s.replace(/^\.\//, "");
  const known = new Set(nodes.map(norm));

  // Build reverse index.
  const rev = new Map();
  for (const src of nodes) {
    const s = norm(src);
    for (const dep of (graph.files[src] || [])) {
      const d = norm(dep);
      if (!rev.has(d)) rev.set(d, []);
      rev.get(d).push(s);
    }
  }

  // BFS reverse closure for each entry.
  // `seen` is hoisted OUTSIDE the entries loop (issue #12 medium): shared
  // ancestors are walked once, not once per entry. Skipping an entry already
  // in `seen` is sound — its reverse closure was fully explored when it was
  // first enqueued as another entry\x27s ancestor.
  const closure = new Set();
  const missing = [];
  const seen = new Set();
  for (const e of entries) {
    const n = norm(e);
    if (!known.has(n)) missing.push(e);
    if (seen.has(n)) continue;
    seen.add(n);
    // BFS with an index pointer instead of Array.shift() — shift() is O(N) and
    // makes the whole traversal O(N²) on wide graphs.
    const q = [n];
    for (let head = 0; head < q.length; head++) {
      const cur = q[head];
      for (const parent of (rev.get(cur) || [])) {
        if (!seen.has(parent)) {
          seen.add(parent);
          closure.add(parent);
          q.push(parent);
        }
      }
    }
  }

  // Workspace detection.
  function readJson(p) { try { return JSON.parse(fs.readFileSync(p, "utf8")); } catch { return null; } }
  const wsPkgs = [];  // [{name, dir}]
  function addPkg(dir) {
    const pj = readJson(path.join(root, dir, "package.json"));
    if (pj && pj.name) wsPkgs.push({ name: pj.name, dir: dir.replace(/\\/g, "/") });
  }
  // pnpm-workspace.yaml — naive parse
  const pnpmWs = path.join(root, "pnpm-workspace.yaml");
  const globs = [];
  if (fs.existsSync(pnpmWs)) {
    const txt = fs.readFileSync(pnpmWs, "utf8");
    // Anchored to line start so commented-out entries (`# - path/`) are not
    // parsed as workspace globs (issue #12 medium, convergent gemini+kimi).
    for (const m of txt.matchAll(/^[ \t]*-\s+["\x27]?([^"\x27\n#]+)["\x27]?/gm)) globs.push(m[1].trim());
  }
  const rootPj = readJson(path.join(root, "package.json"));
  if (rootPj && Array.isArray(rootPj.workspaces)) globs.push(...rootPj.workspaces);
  else if (rootPj && rootPj.workspaces && Array.isArray(rootPj.workspaces.packages)) globs.push(...rootPj.workspaces.packages);

  // Expand globs (only single trailing /* supported — good enough for typical layouts).
  for (const g of globs) {
    if (typeof g !== "string") continue; // package.json workspaces may hold non-strings
    const clean = g.replace(/\/\*$/, "");
    const full = path.join(root, clean);
    if (g.endsWith("/*") && fs.existsSync(full) && fs.statSync(full).isDirectory()) {
      for (const ent of fs.readdirSync(full)) {
        const sub = path.join(clean, ent);
        if (fs.existsSync(path.join(root, sub, "package.json"))) addPkg(sub);
      }
    } else if (fs.existsSync(path.join(full, "package.json"))) {
      addPkg(clean);
    }
  }
  // Always include root package itself.
  if (rootPj && rootPj.name) wsPkgs.push({ name: rootPj.name, dir: "." });

  function classify(file) {
    let best = null;
    for (const p of wsPkgs) {
      if (p.dir === ".") continue;
      if (file === p.dir || file.startsWith(p.dir + "/")) {
        if (!best || p.dir.length > best.dir.length) best = p;
      }
    }
    if (best) return best.name;
    return (rootPj && rootPj.name) || "(root)";
  }

  const groups = {};
  for (const f of closure) {
    const pkg = classify(f);
    (groups[pkg] = groups[pkg] || []).push(f);
  }
  for (const k of Object.keys(groups)) groups[k].sort();

  // Dynamic-import sniff: count occurrences of `import(` in entry files.
  // Heuristic; not authoritative.
  let dynamicHits = 0;
  for (const e of entries) {
    const p = path.join(root, e);
    if (!fs.existsSync(p)) continue;
    const src = fs.readFileSync(p, "utf8");
    dynamicHits += (src.match(/\bimport\s*\(/g) || []).length;
  }

  const out = {
    entries,
    missing,
    reverseDeps: groups,
    closure: [...closure].sort(),
    dynamicImportHits: dynamicHits,
  };
  process.stdout.write(JSON.stringify(out));
' "$graph_file" "$entries_file" "$repo_root")

# --- find tests ------------------------------------------------------------

# Pipe closure + entries to find_tests.sh
tests=$(printf '%s\n' "$report_json" | node -e '
  let s = ""; process.stdin.on("data", c => s += c);
  process.stdin.on("end", () => {
    const o = JSON.parse(s);
    for (const e of o.entries) process.stdout.write(e + "\n");
    for (const f of o.closure) process.stdout.write(f + "\n");
  });
' | bash "$script_dir/find_tests.sh" || true)

# --- render ----------------------------------------------------------------

cache_dir="$repo_root/.impact-cache"
mkdir -p "$cache_dir"
report_file="$cache_dir/last-report.txt"

if [ "$json" = "true" ]; then
  # Merge tests into JSON. Tests are passed via a temp file, not argv — a big
  # monorepo can surface enough test paths to hit the per-arg OS limit.
  printf '%s\n' "$tests" > "$tests_file"
  printf '%s' "$report_json" | node -e '
    let s=""; process.stdin.on("data",c=>s+=c);
    process.stdin.on("end",()=>{
      const o = JSON.parse(s);
      const fs = require("fs");
      const t = fs.readFileSync(process.argv[1], "utf8").split("\n").filter(Boolean);
      o.tests = t;
      process.stdout.write(JSON.stringify(o, null, 2));
    });
  ' "$tests_file"
  exit 0
fi

{
  echo "== Changed entry files =="
  printf '  %s\n' "${entries[@]}"
  echo
  echo "== Reverse dependencies (by package) =="
  printf '%s' "$report_json" | node -e '
    let s=""; process.stdin.on("data",c=>s+=c);
    process.stdin.on("end",()=>{
      const o = JSON.parse(s);
      const pkgs = Object.keys(o.reverseDeps).sort();
      if (pkgs.length === 0) { console.log("  (none)"); return; }
      for (const p of pkgs) {
        const files = o.reverseDeps[p];
        console.log(`  ${p} (${files.length} files)`);
        for (const f of files.slice(0, 50)) console.log(`    ${f}`);
        if (files.length > 50) console.log(`    ... and ${files.length - 50} more`);
      }
    });
  '
  echo
  echo "== Affected test files (run these) =="
  if [ -z "$tests" ]; then
    echo "  (none found — possible coverage gap)"
  else
    # Quote $tests so paths with spaces don't word-split; use sed to indent.
    printf '%s\n' "$tests" | sed 's/^/  /'
  fi
  echo
  echo "== Caveats =="
  dyn=$(printf '%s' "$report_json" | sed -n 's/.*"dynamicImportHits":\([0-9]*\).*/\1/p')
  if [ "${dyn:-0}" != "0" ]; then
    echo "  - $dyn dynamic import() call(s) detected in entry files; some edges may be missing."
  fi
  missing=$(printf '%s' "$report_json" | node -e '
    let s=""; process.stdin.on("data",c=>s+=c);
    process.stdin.on("end",()=>{
      const o = JSON.parse(s);
      if (o.missing && o.missing.length) console.log("  - entry not present in dep graph: " + o.missing.join(", "));
    });
  ')
  [ -n "$missing" ] && echo "$missing"
  echo "  - Static analysis only. File-based routing, DI containers, and string-based config refs are invisible."
} | tee "$report_file"
