#!/usr/bin/env bash
# codemap.sh — generate docs/architecture/codemap.md (or --json to stdout).
#
# Flags:
#   --output PATH      target path (default docs/architecture/codemap.md)
#   --json             emit JSON model to stdout, do not write markdown
#   --root PATH        treat PATH as repo root
#   --refresh          force-rebuild dep graph cache
#   --no-external      skip external-dep section
#   --max-external N   top-N external deps per package (default 10)
#
# Hard constraints satisfied:
#   - Atomic write (.tmp -> mv).
#   - Body deterministic (no timestamps inside content blocks).
#   - bash 3.2 safe (no mapfile / no associative arrays / array guards).

set -eu

# --- arg parse ------------------------------------------------------------

output=""
emit_json=0
root=""
refresh=""
no_external=0
max_external=10

while [ $# -gt 0 ]; do
  case "$1" in
    --output)
      # Same last-arg guard as --max-external: a valueless flag should be a
      # usage error, not a silent fall-through to the default.
      if [ $# -lt 2 ]; then
        echo "codemap.sh: --output requires a path" >&2
        exit 2
      fi
      shift; output="$1";;
    --json) emit_json=1;;
    --root)
      if [ $# -lt 2 ]; then
        echo "codemap.sh: --root requires a path" >&2
        exit 2
      fi
      shift; root="$1";;
    --refresh) refresh="--refresh";;
    --no-external) no_external=1;;
    --max-external)
      # Guard `shift` so it doesn't abort under `set -e` when --max-external
      # is the last arg with no value.
      if [ $# -lt 2 ]; then
        echo "codemap.sh: --max-external requires a non-negative integer (none given)" >&2
        exit 2
      fi
      shift
      _v="${1:-10}"
      case "$_v" in
        ''|*[!0-9]*)
          echo "codemap.sh: --max-external requires a non-negative integer (got: $_v)" >&2
          exit 2
          ;;
      esac
      max_external="$_v"
      ;;
    -h|--help)
      sed -n '2,12p' "$0"
      exit 0
      ;;
    *)
      echo "unknown flag: $1" >&2
      exit 2
      ;;
  esac
  shift || true
done

# --- resolve repo root ----------------------------------------------------

if [ -z "$root" ]; then
  if command -v git >/dev/null 2>&1 && git -C "$(pwd)" rev-parse --show-toplevel >/dev/null 2>&1; then
    root=$(git -C "$(pwd)" rev-parse --show-toplevel)
  else
    root=$(pwd)
  fi
fi

if [ ! -d "$root" ]; then
  echo "repo root not found: $root" >&2
  exit 1
fi

if [ -z "$output" ]; then
  output="$root/docs/architecture/codemap.md"
fi

script_dir=$(cd "$(dirname "$0")" && pwd)

have_py() { command -v python3 >/dev/null 2>&1; }
have_jq() { command -v jq >/dev/null 2>&1; }

if ! have_py; then
  # Exit-code convention: 0 ok, 1 runtime/environment failure, 2 usage error.
  # A missing interpreter is an environment failure, not bad usage.
  echo "codemap.sh requires python3 (used for JSON assembly and rendering)" >&2
  exit 1
fi

# --- temp files (PID-suffixed) --------------------------------------------

# mktemp already produces a unique path; the .$$ suffix is redundant.
tmp_ws="$(mktemp -t codemap_ws.XXXXXX)"
tmp_edges="$(mktemp -t codemap_edges.XXXXXX)"
tmp_model="$(mktemp -t codemap_model.XXXXXX)"
tmp_md="$(mktemp -t codemap_md.XXXXXX)"
cleanup() { rm -f "$tmp_ws" "$tmp_edges" "$tmp_model" "$tmp_md"; }
trap cleanup EXIT INT TERM

# --- step 1: workspace detection ------------------------------------------

bash "$script_dir/detect_workspaces.sh" "$root" > "$tmp_ws"

# --- step 2: edges (jsonl) -------------------------------------------------

bash "$script_dir/build_pkg_graph.sh" "$root" "$tmp_ws" $refresh > "$tmp_edges" || true

# --- step 3: assemble model -----------------------------------------------

# Repo name = git remote basename, else basename of root.
repo_name=""
if command -v git >/dev/null 2>&1; then
  url=$(git -C "$root" config --get remote.origin.url 2>/dev/null || true)
  if [ -n "$url" ]; then
    repo_name=$(printf '%s' "$url" | sed -E 's#.*[/:]([^/]+)/([^/]+)(\.git)?$#\1/\2#' | sed -E 's#\.git$##')
  fi
fi
[ -z "$repo_name" ] && repo_name=$(basename "$root")

# Generated_at — deterministic-when-overridden via CODEMAP_FAKE_TIME (for tests).
gen_at="${CODEMAP_FAKE_TIME:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"

regen_cmd="${CODEMAP_REGEN_CMD:-./scripts/codemap.sh}"

NO_EXT=$no_external MAX_EXT=$max_external \
REPO="$root" REPO_NAME="$repo_name" GEN_AT="$gen_at" REGEN="$regen_cmd" \
python3 - "$tmp_ws" "$tmp_edges" > "$tmp_model" <<'PY'
import json,os,sys,subprocess,re

ws_path=sys.argv[1]; edges_path=sys.argv[2]
ws=json.load(open(ws_path))
edges=[]
with open(edges_path) as f:
    for line in f:
        line=line.strip()
        if not line: continue
        try: edges.append(json.loads(line))
        except Exception: pass

repo=os.environ["REPO"]
repo_name=os.environ["REPO_NAME"]
gen_at=os.environ["GEN_AT"]
regen=os.environ["REGEN"]
no_ext=os.environ.get("NO_EXT","0")=="1"
max_ext=int(os.environ.get("MAX_EXT","10") or 10)

SKIP_DIRS={"node_modules","dist","build",".next","coverage",".git",".impact-cache"}
SRC_EXT={".ts",".tsx",".js",".jsx",".mjs",".cjs"}

def count_files(d):
    n=0; lb={"ts":0,"js":0}
    for dirpath, dirnames, filenames in os.walk(d):
        dirnames[:] = [x for x in dirnames if x not in SKIP_DIRS]
        for fn in filenames:
            ext=os.path.splitext(fn)[1].lower()
            if ext in SRC_EXT:
                n+=1
                if ext in (".ts",".tsx"): lb["ts"]+=1
                else: lb["js"]+=1
    return n, lb

def resolve_entry(pdir, pkg):
    # main / module / exports."."default / src/index.{ts,tsx,js}
    for k in ("module","main"):
        v=pkg.get(k)
        if isinstance(v,str) and v:
            return v
    exp=pkg.get("exports")
    # `"exports": "./dist/index.js"` is a valid (and common) shorthand for the
    # `.` subpath. Handle the string form before falling through to dict.
    if isinstance(exp,str) and exp:
        return exp
    if isinstance(exp,dict):
        dot=exp.get(".")
        if isinstance(dot,str): return dot
        if isinstance(dot,dict):
            for k in ("import","default","require"):
                v=dot.get(k)
                if isinstance(v,str): return v
                if isinstance(v,dict):
                    vv=v.get("default") or v.get("import") or v.get("require")
                    if isinstance(vv,str): return vv
    for cand in ("src/index.tsx","src/index.ts","src/index.js","index.tsx","index.ts","index.js"):
        if os.path.exists(os.path.join(pdir, cand)):
            return cand
    return ""

# Workspace package names — filtered out of the External-dep highlights so
# internal monorepo deps don't taint a section documented as third-party.
INTERNAL_PKG_NAMES = {p.get("name") for p in (ws.get("packages") or []) if p.get("name")}

def top_external(pkg, n):
    deps=pkg.get("dependencies") or {}
    if not isinstance(deps,dict): return []
    # Sorted alphabetically for determinism (no version-based ranking).
    # Exclude workspace packages — those are internal deps, not third-party.
    external = [d for d in deps.keys() if d not in INTERNAL_PKG_NAMES]
    return sorted(external)[:n]

pkgs_out=[]
total_files=0
total_lb={"ts":0,"js":0}
for p in ws.get("packages",[]):
    pdir = p["dir"] if p["dir"] != "." else repo
    abs_dir = pdir if os.path.isabs(pdir) else os.path.join(repo, pdir)
    pkg_json={}
    pj=os.path.join(abs_dir,"package.json")
    if os.path.isfile(pj):
        try: pkg_json=json.load(open(pj))
        except Exception: pkg_json={}
    n, lb = count_files(abs_dir)
    total_files += n
    total_lb["ts"] += lb["ts"]; total_lb["js"] += lb["js"]
    entry = resolve_entry(abs_dir, pkg_json)
    ext = [] if no_ext else top_external(pkg_json, max_ext)
    pkgs_out.append({
        "name": p["name"],
        "dir": p["dir"],
        "lang": p.get("lang","unknown"),
        "description": p.get("description","") or pkg_json.get("description","") or "",
        "file_count": n,
        "entry": entry,
        "external": ext,
    })

# Ownership pointers — scan for CODEOWNERS, OWNERS, docs/architecture/*.md
ownership=[]
for cand in ("CODEOWNERS",".github/CODEOWNERS","docs/CODEOWNERS","OWNERS"):
    if os.path.isfile(os.path.join(repo,cand)):
        ownership.append(cand)
arch_dir=os.path.join(repo,"docs","architecture")
if os.path.isdir(arch_dir):
    for fn in sorted(os.listdir(arch_dir)):
        if fn.endswith(".md") and fn != "codemap.md":
            ownership.append(os.path.join("docs","architecture",fn))

model={
    "repo_name": repo_name,
    "generated_at": gen_at,
    "stats": {
        "package_count": len(pkgs_out),
        "source_files": total_files,
        "lang_breakdown": total_lb,
    },
    "packages": pkgs_out,
    "edges": edges,
    "ownership": ownership,
    "include_external": (not no_ext),
    "regen_cmd": regen,
}
json.dump(model, sys.stdout, sort_keys=True)
PY

# --- step 4: emit ---------------------------------------------------------

if [ "$emit_json" -eq 1 ]; then
  cat "$tmp_model"
  exit 0
fi

bash "$script_dir/render_markdown.sh" "$tmp_model" > "$tmp_md"

mkdir -p "$(dirname "$output")"
# Atomic write: write to .tmp next to target, then mv.
final_tmp="${output}.tmp.$$"
mv "$tmp_md" "$final_tmp"
mv "$final_tmp" "$output"

echo "$output"
