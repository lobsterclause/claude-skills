#!/usr/bin/env bash
# detect_layout.sh — detect monorepo layout. Emits JSON:
#   {"workspace_kind": "pnpm|npm|nx|none", "packages": [{"name":"...","dir":"..."}]}
#
# Usage: detect_layout.sh [repo_root]

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
        if (m) globs.push(m[1].trim());
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
    if (rootPj && rootPj.name) pkgs.push({ name: rootPj.name, dir: "." });

    process.stdout.write(JSON.stringify({ workspace_kind: kind, packages: pkgs }));
  ' "$root" "$kind"
  echo
else
  # No node — emit minimal layout.
  printf '{"workspace_kind":"%s","packages":[]}\n' "$kind"
fi
