#!/usr/bin/env bash
# detect_workspaces.sh — emit JSON describing the monorepo workspace layout.
#
# Output shape (single line):
#   {"kind":"pnpm|npm|single","packages":[{"name":"...","dir":"...","lang":"ts|js|mixed","description":"..."}]}
#
# Workspace detection order:
#   1. pnpm-workspace.yaml ("packages:" list)
#   2. package.json "workspaces" (array or {packages: [...]})
#   3. single-package layout (root package.json only)
#
# Globs: only single-trailing-* is expanded (e.g. packages/*). Nested **/ globs
# are intentionally not supported — keeps the script bash-3.2 safe and predictable.
#
# pnpm-workspace.yaml parsing is deliberately NAIVE (documented limitation,
# shared with where-is's detect_layout.sh): only a top-level `packages:` block
# of `- glob` list items is read. Inline `# comments` are stripped and
# single/double quotes unwrapped, but there is NO support for flow-style lists
# (`packages: [a, b]`), block scalars, YAML anchors, or escape sequences
# inside quoted strings. Exclusion patterns (`- '!...'`) are skipped. Repos
# with exotic YAML should rely on package.json workspaces.

set -euo pipefail

repo_root="${1:-${CODEMAP_REPO_ROOT:-$(pwd)}}"

have_jq() { command -v jq >/dev/null 2>&1; }
have_py() { command -v python3 >/dev/null 2>&1; }

# --- helpers ---------------------------------------------------------------

# Read a JSON field from a package.json. Args: file, key. Falls back through
# jq -> python3 -> empty string.
read_json_field() {
  local file="$1"
  local key="$2"
  [ -f "$file" ] || { printf ''; return 0; }
  if have_jq; then
    jq -r --arg k "$key" '.[$k] // ""' "$file" 2>/dev/null || printf ''
  elif have_py; then
    python3 - "$file" "$key" <<'PY' 2>/dev/null || printf ''
import json,sys
try:
  d=json.load(open(sys.argv[1]))
  v=d.get(sys.argv[2],"")
  if not isinstance(v,(str,int,float,bool)): v=""
  print(v)
except Exception:
  print("")
PY
  else
    printf ''
  fi
}

# Detect language inside a directory by counting .ts(x) vs .js(x) source files.
# Single find pass — the old implementation walked the tree twice (one find
# for ts, one for js), doubling I/O per package on large repos. Extension
# counting happens in awk over the one file list. (codemap.sh still does its
# own os.walk for file counts; that lives in a different process/language and
# is not folded here.)
detect_lang() {
  local dir="$1"
  [ -d "$dir" ] || { printf 'unknown'; return 0; }
  find "$dir" -type d \( -name node_modules -o -name dist -o -name build -o -name .next -o -name coverage \) -prune \
    -o -type f \( -name '*.ts' -o -name '*.tsx' -o -name '*.js' -o -name '*.jsx' -o -name '*.mjs' -o -name '*.cjs' \) -print 2>/dev/null \
  | awk '
      /\.tsx?$/ { ts++; next }
      { js++ }
      END {
        if (ts > 0 && js > 0) printf "mixed"
        else if (ts > 0) printf "ts"
        else if (js > 0) printf "js"
        else printf "unknown"
      }'
}

# Escape a string for JSON embedding (handles quotes, backslashes, newlines).
json_escape() {
  if have_py; then
    python3 -c 'import json,sys; sys.stdout.write(json.dumps(sys.stdin.read())[1:-1])'
  else
    # Minimal fallback — strip control chars, escape quotes/backslashes.
    LC_ALL=C tr -d '\000-\037' | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
  fi
}

# --- workspace pattern collection ------------------------------------------

patterns_file="$(mktemp -t codemap_pat.XXXXXX)"
trap 'rm -f "$patterns_file"' EXIT

kind="single"

if [ -f "$repo_root/pnpm-workspace.yaml" ]; then
  kind="pnpm"
  # Naive YAML parse: lines starting with "- " under a "packages:" key.
  # Strip `# ...` inline comments first — common in pnpm-workspace.yaml,
  # otherwise the comment text gets folded into the glob pattern and no
  # workspace dirs match (codex pass-3 finding).
  awk '
    /^packages:/ {flag=1; next}
    /^[a-zA-Z]/ {flag=0}
    flag && /^[[:space:]]*-[[:space:]]*/ {
      gsub(/^[[:space:]]*-[[:space:]]*/, "")
      gsub(/[[:space:]]+#.*$/, "")
      gsub(/^["'\'']|["'\'']$/, "")
      gsub(/[[:space:]]+$/, "")
      if (length($0)) print
    }
  ' "$repo_root/pnpm-workspace.yaml" > "$patterns_file"
elif [ -f "$repo_root/package.json" ]; then
  ws_check=""
  if have_jq; then
    ws_check=$(jq -r '
      if (.workspaces|type)=="array" then .workspaces[]
      elif (.workspaces|type)=="object" then .workspaces.packages[]?
      else empty end
    ' "$repo_root/package.json" 2>/dev/null || true)
  elif have_py; then
    ws_check=$(python3 - "$repo_root/package.json" <<'PY' 2>/dev/null || true
import json,sys
try:
  d=json.load(open(sys.argv[1]))
  w=d.get("workspaces")
  if isinstance(w,list):
    for x in w: print(x)
  elif isinstance(w,dict):
    for x in w.get("packages",[]) or []: print(x)
except Exception:
  pass
PY
    )
  fi
  if [ -n "$ws_check" ]; then
    kind="npm"
    printf '%s\n' "$ws_check" > "$patterns_file"
  fi
fi

# --- expand patterns to package directories --------------------------------

pkg_dirs_file="$(mktemp -t codemap_dirs.XXXXXX)"
trap 'rm -f "$patterns_file" "$pkg_dirs_file"' EXIT

if [ "$kind" = "single" ]; then
  # Single-package layout: the root is the only package (if it has package.json).
  if [ -f "$repo_root/package.json" ]; then
    printf '%s\n' "$repo_root" > "$pkg_dirs_file"
  fi
else
  while IFS= read -r pat; do
    [ -z "$pat" ] && continue
    case "$pat" in
      \!*)
        # Exclusion pattern (pnpm/yarn `!...`) — skip rather than treating it
        # as a positive glob for a literal `!...` directory.
        ;;
      */\*)
        base="${pat%/\*}"
        if [ -d "$repo_root/$base" ]; then
          for d in "$repo_root/$base"/*/; do
            [ -d "$d" ] || continue
            d="${d%/}"
            [ -f "$d/package.json" ] && printf '%s\n' "$d"
          done
        fi
        ;;
      *\**)
        # Nested glob — skip (documented limitation).
        ;;
      *)
        if [ -d "$repo_root/$pat" ] && [ -f "$repo_root/$pat/package.json" ]; then
          printf '%s\n' "$repo_root/$pat"
        fi
        ;;
    esac
  done < "$patterns_file" | sort -u > "$pkg_dirs_file"
fi

# --- emit JSON -------------------------------------------------------------

printf '{"kind":"%s","root":"' "$kind"
printf '%s' "$repo_root" | json_escape
printf '","packages":['

first=1
while IFS= read -r dir; do
  [ -z "$dir" ] && continue
  rel="${dir#$repo_root/}"
  [ "$rel" = "$dir" ] && rel="."
  name=$(read_json_field "$dir/package.json" name)
  [ -z "$name" ] && name="$rel"
  desc=$(read_json_field "$dir/package.json" description)
  lang=$(detect_lang "$dir")
  if [ $first -eq 0 ]; then printf ','; fi
  first=0
  printf '{"name":"'
  printf '%s' "$name" | json_escape
  printf '","dir":"'
  printf '%s' "$rel" | json_escape
  printf '","lang":"%s","description":"' "$lang"
  printf '%s' "$desc" | json_escape
  printf '"}'
done < "$pkg_dirs_file"

printf ']}\n'
