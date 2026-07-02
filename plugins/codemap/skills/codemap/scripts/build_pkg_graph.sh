#!/usr/bin/env bash
# build_pkg_graph.sh — emit inter-package import edges as JSONL on stdout.
#
# Usage: build_pkg_graph.sh <repo_root> <workspace_json_file> [--refresh]
#
# Each line: {"from":"@scope/a","to":"@scope/b","count":N}
#
# Strategy:
#   1. If the impact plugin's build_graph.sh is installed locally, use it for
#      file-level edges then roll up to package-level.
#   2. Otherwise fall back to `git ls-files` + grep for `from '<internal-pkg>'`
#      style imports in TS/JS files (one-hop).

set -euo pipefail

if [ $# -lt 2 ]; then
  echo "usage: build_pkg_graph.sh <repo_root> <workspace_json_file> [--refresh]" >&2
  exit 2
fi
repo_root="$1"
workspace_json="$2"
refresh_args=()
if [ "${3:-}" = "--refresh" ]; then
  refresh_args=(--refresh)
fi

have_jq() { command -v jq >/dev/null 2>&1; }
have_py() { command -v python3 >/dev/null 2>&1; }

# Extract array of package names and their dirs from the workspace JSON.
# Emits "name<TAB>dir" lines.
extract_pkgs() {
  if have_jq; then
    jq -r '.packages[] | "\(.name)\t\(.dir)"' "$workspace_json"
  elif have_py; then
    python3 - "$workspace_json" <<'PY'
import json,sys
d=json.load(open(sys.argv[1]))
for p in d.get("packages",[]):
  print(f"{p['name']}\t{p['dir']}")
PY
  else
    return 1
  fi
}

# Temp files cleaned up by a single trap — multiple `trap '...' EXIT` lines
# overwrite each other rather than chaining, so set one cleanup function up
# front and add file vars as they're created.
pkgs_file=""
edges_file=""
names_pattern_file=""
files_list=""
cleanup() {
  [ -n "$pkgs_file" ] && rm -f "$pkgs_file"
  [ -n "$edges_file" ] && rm -f "$edges_file"
  [ -n "$names_pattern_file" ] && rm -f "$names_pattern_file"
  [ -n "$files_list" ] && rm -f "$files_list"
}
trap cleanup EXIT INT TERM

pkgs_file="$(mktemp -t codemap_pkgs.XXXXXX)"
edges_file="$(mktemp -t codemap_edges.XXXXXX)"

extract_pkgs > "$pkgs_file" || true
if [ ! -s "$pkgs_file" ]; then
  exit 0
fi

# Build a name list for grep filtering. Only scoped (@) or non-relative names
# matter — relative imports never cross package boundaries on the npm side.
names_pattern_file="$(mktemp -t codemap_pat.XXXXXX)"
awk -F'\t' '{print $1}' "$pkgs_file" > "$names_pattern_file"

# --- option 1: impact plugin -----------------------------------------------

impact_script="$HOME/.claude/skills/impact/scripts/build_graph.sh"
graph_json=""
if [ -x "$impact_script" ]; then
  if graph_json=$(IMPACT_REPO_ROOT="$repo_root" "$impact_script" "${refresh_args[@]+"${refresh_args[@]}"}" 2>/dev/null); then
    if [ -f "$graph_json" ]; then
      # Roll file-level edges up to package-level using python or jq.
      if have_py; then
        # No `|| true` here: surface a rollup crash instead of masking it
        # (kimi, PR #23 pass 1). Python's stderr is NOT suppressed, and on
        # failure we degrade to an explicitly-empty edges file rather than
        # leaving a half-written one behind.
        if ! python3 - "$graph_json" "$pkgs_file" > "$edges_file" <<'PY' 
import json,sys,os
g=json.load(open(sys.argv[1]))
pkgs=[]
for line in open(sys.argv[2]):
  line=line.rstrip("\n")
  if not line: continue
  name,d=line.split("\t",1)
  pkgs.append((name,d.rstrip("/")+"/"))
def pkg_of(path):
  best=None; bestlen=-1
  for name,d in pkgs:
    if d=="./": continue
    if path.startswith(d) and len(d)>bestlen:
      best=name; bestlen=len(d)
  return best
counts={}
for src, deps in (g.get("files") or {}).items():
  ps=pkg_of(src)
  if not ps: continue
  for dep in (deps or []):
    pd=pkg_of(dep)
    if not pd or pd==ps: continue
    counts[(ps,pd)] = counts.get((ps,pd),0)+1
for (a,b),c in sorted(counts.items()):
  print(json.dumps({"from":a,"to":b,"count":c}))
PY
        then
          echo "build_pkg_graph: package-edge rollup failed — continuing without dependency edges" >&2
          : > "$edges_file"
        fi
        if [ -s "$edges_file" ]; then
          cat "$edges_file"
          exit 0
        fi
      fi
    fi
  fi
fi

# --- option 2: git ls-files + grep fallback --------------------------------

# For each package name, grep all source files for `from '<name>'` or
# `require('<name>')` and attribute the importing file to its owning package.

cd "$repo_root" 2>/dev/null || exit 0
if ! command -v git >/dev/null 2>&1; then
  exit 0
fi

files_list="$(mktemp -t codemap_files.XXXXXX)"

git ls-files -- '*.ts' '*.tsx' '*.js' '*.jsx' '*.mjs' '*.cjs' 2>/dev/null \
  | grep -v -E '(^|/)(node_modules|dist|build|\.next|coverage)(/|$)' \
  > "$files_list" || true

if [ ! -s "$files_list" ]; then
  exit 0
fi

# Roll up file -> package and count edges with python (portable, deterministic).
# The alternation regex of package names is built INSIDE python via re.escape —
# assembling it in shell and passing it as argv risked ARG_MAX on repos with
# hundreds of packages, and awk-level escaping was best-effort.
if have_py; then
  python3 - "$repo_root" "$pkgs_file" "$files_list" "$names_pattern_file" > "$edges_file" <<'PY' || true
import sys,re,os,json
repo=sys.argv[1]; pkgs_path=sys.argv[2]; files_path=sys.argv[3]; names_path=sys.argv[4]
pkgs=[]
for line in open(pkgs_path):
  line=line.rstrip("\n")
  if not line: continue
  name,d=line.split("\t",1)
  pkgs.append((name,d.rstrip("/")+"/"))
def pkg_of(path):
  best=None; bestlen=-1
  for name,d in pkgs:
    if d=="./": continue
    if path.startswith(d) and len(d)>bestlen:
      best=name; bestlen=len(d)
  return best
names=[l.strip() for l in open(names_path) if l.strip()]
if not names: sys.exit(0)
pat="|".join(re.escape(n) for n in names)
# Import shapes matched (gemini pass-3: dynamic + side-effect were missed):
#   import x from 'pkg' / export ... from 'pkg'   -> from-branch
#   require('pkg')                                -> require-branch
#   import('pkg')  (dynamic)                      -> import( branch
#   import 'pkg'   (bare side-effect)             -> import<space> branch
rx=re.compile(r"""(?:\bfrom\s*|\brequire\s*\(\s*|\bimport\s*\(\s*|\bimport\s+)['"]("""+pat+r""")(?:/[^'"]*)?['"]""")
counts={}
for rel in (l.strip() for l in open(files_path)):
  if not rel: continue
  src=os.path.join(repo,rel)
  try:
    with open(src, "r", errors="ignore") as f:
      text=f.read()
  except Exception:
    continue
  ps=pkg_of(rel)
  if not ps: continue
  for m in rx.finditer(text):
    dep=m.group(1)
    if dep==ps: continue
    counts[(ps,dep)] = counts.get((ps,dep),0)+1
for (a,b),c in sorted(counts.items()):
  print(json.dumps({"from":a,"to":b,"count":c}))
PY
  cat "$edges_file"
fi
