#!/usr/bin/env bash
# detect_layout.sh — detect monorepo layout. Emits JSON:
#   {"workspace_kind": "pnpm|npm|nx|none", "packages": [{"name":"...","dir":"..."}]}
#
# Usage: detect_layout.sh [repo_root]
#
# pnpm-workspace.yaml parsing is deliberately NAIVE (documented limitation,
# shared with codemap's detect_workspaces.sh): only a top-level `packages:`
# block of `- glob` list items is read. Inline `# comments` are stripped and
# single/double quotes unwrapped, but there is NO support for flow-style
# lists (`packages: [a, b]`), block scalars, YAML anchors, or escape
# sequences inside quoted strings. Exclusion patterns (`- '!...'`) are
# skipped. Repos with exotic YAML should rely on package.json workspaces.

set -eu

root="${1:-$(pwd)}"

kind="none"
if [ -f "$root/pnpm-workspace.yaml" ]; then
  kind="pnpm"
elif [ -f "$root/nx.json" ]; then
  kind="nx"
elif [ -f "$root/package.json" ] && grep -q '"workspaces"' "$root/package.json" 2>/dev/null; then
  kind="npm"
fi

# Use node if available — fast and robust JSON.
if command -v node >/dev/null 2>&1; then
  node -e '
    const fs = require("fs"), path = require("path");
    const root = process.argv[1];
    const kind = process.argv[2];

    function readJson(p) { try { return JSON.parse(fs.readFileSync(p,"utf8")); } catch { return null; } }
    function readText(p) { try { return fs.readFileSync(p,"utf8"); } catch { return ""; } }

    const globs = [];
    const txt = readText(path.join(root, "pnpm-workspace.yaml"));
    if (txt) {
      // Only extract list items under the "packages:" block so we do not
      // accidentally pick up other YAML keys list entries (gemini M).
      let inPackages = false;
      for (const rawLine of txt.split("\n")) {
        if (/^packages:/.test(rawLine)) { inPackages = true; continue; }
        if (/^[A-Za-z]/.test(rawLine)) { inPackages = false; continue; }
        if (!inPackages) continue;
        // Strip inline `# comments` (codex P3) before parsing the glob.
        const line = rawLine.replace(/\s+#.*$/, "");
        const m = line.match(/^[\s]*-\s+["\x27]?([^"\x27\n]+?)["\x27]?\s*$/);
        // Skip exclusion patterns (`- "!**/test/**"`) — treating them as
        // positive globs would try to enumerate a literal `!...` directory.
        if (m && !m[1].trim().startsWith("!")) globs.push(m[1].trim());
      }
    }
    const rootPj = readJson(path.join(root, "package.json"));
    if (rootPj) {
      if (Array.isArray(rootPj.workspaces)) globs.push(...rootPj.workspaces);
      else if (rootPj.workspaces && Array.isArray(rootPj.workspaces.packages)) globs.push(...rootPj.workspaces.packages);
    }

    const pkgs = [];
    function addPkg(dir) {
      const pj = readJson(path.join(root, dir, "package.json"));
      if (pj && pj.name) pkgs.push({ name: pj.name, dir: dir.replace(/\\/g,"/") });
    }
    for (const g of globs) {
      const clean = g.replace(/\/\*$/,"");
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

    if (kind === "nx") {
      // Nx projects are not listed in pnpm/npm workspace globs, so without
      // this the packages list stayed empty and Nx repos reported an empty
      // workspace (codex P2). Two sources:
      //   1. legacy workspace.json / angular.json "projects" maps
      //      (value = dir string, or { root: dir })
      //   2. modern Nx: per-project project.json files discovered by a
      //      bounded walk (heavy dirs skipped, depth-capped)
      const seenDirs = new Set(pkgs.map(p => p.dir));
      function addNxPkg(name, dir) {
        dir = String(dir).replace(/\\/g, "/").replace(/\/+$/, "");
        if (!name || !dir || dir === "." || seenDirs.has(dir)) return;
        seenDirs.add(dir);
        pkgs.push({ name, dir });
      }
      for (const wsFile of ["workspace.json", "angular.json"]) {
        const w = readJson(path.join(root, wsFile));
        if (w && w.projects && typeof w.projects === "object") {
          for (const [name, v] of Object.entries(w.projects)) {
            const dir = typeof v === "string" ? v : (v && typeof v.root === "string" ? v.root : "");
            if (dir) addNxPkg(name, dir);
          }
        }
      }
      const SKIP = new Set(["node_modules", "dist", "build", ".git", ".next", "coverage", "tmp", ".nx"]);
      (function walk(rel, depth) {
        if (depth > 6) return;
        let ents;
        try { ents = fs.readdirSync(path.join(root, rel), { withFileTypes: true }); } catch { return; }
        for (const ent of ents) {
          const sub = rel ? rel + "/" + ent.name : ent.name;
          if (ent.isDirectory()) {
            if (!SKIP.has(ent.name)) walk(sub, depth + 1);
          } else if (ent.name === "project.json" && rel) {
            const proj = readJson(path.join(root, sub));
            const pj = readJson(path.join(root, rel, "package.json"));
            const name = (proj && proj.name) || (pj && pj.name) || path.basename(rel);
            addNxPkg(name, rel);
          }
        }
      })("", 0);
    }

    if (rootPj && rootPj.name) pkgs.push({ name: rootPj.name, dir: "." });

    process.stdout.write(JSON.stringify({ workspace_kind: kind, packages: pkgs }));
  ' "$root" "$kind"
  echo
else
  # No node — emit minimal layout.
  printf '{"workspace_kind":"%s","packages":[]}\n' "$kind"
fi
