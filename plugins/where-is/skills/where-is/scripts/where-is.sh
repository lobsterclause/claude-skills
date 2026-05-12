#!/usr/bin/env bash
# where-is.sh — main entrypoint. Classifies a query and dispatches to the
# right tool: Serena MCP (symbol), ast-grep (pattern), fs walk (path), or
# ripgrep (concept). Outputs grouped-by-package results or JSON.
#
# Usage:
#   where-is.sh "<query>"
#   where-is.sh --kind symbol|pattern|path|concept <query>
#   where-is.sh --json <query>
#   where-is.sh --include-tests <query>
#   where-is.sh --package @scope/name <query>

set -eu

script_dir="$(cd "$(dirname "$0")" && pwd)"
root="${WHEREIS_REPO_ROOT:-$(pwd)}"
export WHEREIS_REPO_ROOT="$root"

kind_override=""
json="false"
include_tests="false"
pkg_filter=""
query=""

while [ $# -gt 0 ]; do
  case "$1" in
    --kind) kind_override="${2:-}"; shift 2 ;;
    --json) json="true"; shift ;;
    --include-tests) include_tests="true"; shift ;;
    --package) pkg_filter="${2:-}"; shift 2 ;;
    -h|--help)
      sed -n '2,12p' "$0"; exit 0 ;;
    --) shift; query="${1:-}"; shift || true ;;
    -*)
      echo "unknown flag: $1" >&2; exit 2 ;;
    *)
      if [ -z "$query" ]; then query="$1"; else query="$query $1"; fi
      shift ;;
  esac
done

if [ -z "$query" ]; then
  echo "usage: where-is.sh [--kind K] [--json] [--include-tests] [--package P] <query>" >&2
  exit 2
fi

# --- classify --------------------------------------------------------------

if [ -n "$kind_override" ]; then
  kind="$kind_override"
  normalized="$query"
else
  classification=$(bash "$script_dir/classify.sh" "$query")
  kind=$(printf '%s' "$classification" | sed -n 's/.*"kind":"\([^"]*\)".*/\1/p')
  normalized=$(printf '%s' "$classification" | sed -n 's/.*"normalized":"\([^"]*\)".*/\1/p')
fi
[ -z "$kind" ] && kind="concept"
[ -z "$normalized" ] && normalized="$query"

# --- layout ----------------------------------------------------------------

layout=$(bash "$script_dir/detect_layout.sh" "$root" 2>/dev/null || echo '{"workspace_kind":"none","packages":[]}')

# --- helpers ---------------------------------------------------------------

classify_pkg() {
  # Given a file path, print the workspace package name it belongs to.
  # Reads $layout from the enclosing scope.
  local file="$1"
  if ! command -v node >/dev/null 2>&1; then
    echo "(root)"
    return
  fi
  node -e '
    const layout = JSON.parse(process.argv[1]);
    const file = process.argv[2];
    let best = null;
    for (const p of (layout.packages || [])) {
      if (p.dir === ".") continue;
      if (file === p.dir || file.startsWith(p.dir + "/")) {
        if (!best || p.dir.length > best.dir.length) best = p;
      }
    }
    process.stdout.write(best ? best.name : "(root)");
  ' "$layout" "$file"
}

emit_json_head() {
  printf '{"kind":"%s","query":"%s","normalized":"%s",' \
    "$kind" \
    "$(printf '%s' "$query" | sed 's/\\/\\\\/g; s/"/\\"/g')" \
    "$(printf '%s' "$normalized" | sed 's/\\/\\\\/g; s/"/\\"/g')"
}

# --- dispatch --------------------------------------------------------------

case "$kind" in
  symbol)
    # Cannot call Serena from shell. Emit canonical name + ripgrep fallback.
    rg_hits=""
    if command -v rg >/dev/null 2>&1; then
      rg_args=(
        --line-number --no-heading --color=never
        --type-add 'tsj:*.{ts,tsx,js,jsx,mjs,cjs}' -t tsj
        --glob '!node_modules' --glob '!dist' --glob '!build'
        --glob '!.next' --glob '!coverage'
      )
      if [ "$include_tests" != "true" ]; then
        rg_args+=(--glob '!*.test.*' --glob '!*.spec.*' --glob '!__tests__/**')
      fi
      # Prefer "class Foo" / "function Foo" / "const Foo" / "export ... Foo" definitions.
      def_re="(class|function|const|let|var|interface|type|enum)[[:space:]]+${normalized}\\b|export[[:space:]]+(default[[:space:]]+)?(class|function|const|let|var|interface|type|enum)[[:space:]]+${normalized}\\b"
      rg_hits=$(rg "${rg_args[@]+"${rg_args[@]}"}" -e "$def_re" "$root" 2>/dev/null | head -n 20 || true)
      if [ -z "$rg_hits" ]; then
        rg_hits=$(rg "${rg_args[@]+"${rg_args[@]}"}" --fixed-strings -e "$normalized" "$root" 2>/dev/null | head -n 20 || true)
      fi
    fi

    if [ "$json" = "true" ]; then
      hits_json="[]"
      if [ -n "$rg_hits" ] && command -v node >/dev/null 2>&1; then
        hits_json=$(printf '%s' "$rg_hits" | node -e '
          const layout = JSON.parse(process.argv[1]);
          function pkgOf(file) {
            let best=null;
            for (const p of (layout.packages||[])) {
              if (p.dir==="."||!p.dir) continue;
              if (file===p.dir||file.startsWith(p.dir+"/")) {
                if (!best||p.dir.length>best.dir.length) best=p;
              }
            }
            return best?best.name:"(root)";
          }
          let s=""; process.stdin.on("data",c=>s+=c);
          process.stdin.on("end",()=>{
            const out=[];
            for (const line of s.split("\n")) {
              if (!line) continue;
              const m=line.match(/^(.+?):(\d+):(.*)$/);
              if (!m) continue;
              out.push({ file:m[1], line:Number(m[2]), snippet:m[3].trim(), package:pkgOf(m[1]) });
            }
            process.stdout.write(JSON.stringify(out));
          });
        ' "$layout")
      fi
      emit_json_head
      printf '"route":"serena-mcp","next_actions":[{"tool":"mcp__serena__find_symbol","args":{"name_path":"%s","include_body":false}},{"tool":"mcp__serena__find_referencing_symbols","args":{"name_path":"%s"}}],"fallback_hits":%s}\n' \
        "$normalized" "$normalized" "$hits_json"
    else
      echo "== Symbol: $normalized =="
      echo "ROUTE: Serena MCP (call from this conversation)"
      echo "  1. mcp__serena__find_symbol            name_path=\"$normalized\"  include_body=false"
      echo "  2. mcp__serena__find_referencing_symbols  name_path=\"$normalized\""
      echo
      echo "== Fallback (ripgrep, definition-shaped matches) =="
      if [ -z "$rg_hits" ]; then
        echo "  (no fallback hits — call Serena MCP tools above)"
      else
        printf '%s\n' "$rg_hits" | while IFS= read -r line; do
          file=$(printf '%s' "$line" | sed -n 's/^\([^:]*\):.*/\1/p')
          pkg=$(classify_pkg "$file")
          echo "  [$pkg] $line"
        done
      fi
    fi
    ;;

  pattern)
    if command -v ast-grep >/dev/null 2>&1; then
      AG=ast-grep
    elif command -v sg >/dev/null 2>&1; then
      AG=sg
    else
      AG=""
    fi

    if [ -z "$AG" ]; then
      echo "WARN: ast-grep not installed; falling back to ripgrep (pattern matching will be approximate)" >&2
      bash "$script_dir/concept_search.sh" "$normalized" \
        ${include_tests:+$([ "$include_tests" = "true" ] && echo --include-tests)} \
        ${pkg_filter:+--package "$pkg_filter"}
      exit 0
    fi

    ag_args=(--pattern "$normalized" --lang tsx)
    raw=$("$AG" "${ag_args[@]}" "$root" 2>/dev/null || true)

    if [ "$json" = "true" ]; then
      emit_json_head
      esc=$(printf '%s' "$raw" | sed 's/\\/\\\\/g; s/"/\\"/g' | awk 'BEGIN{ORS="\\n"}{print}')
      printf '"route":"ast-grep","matches":"%s"}\n' "$esc"
    else
      echo "== Pattern: $normalized =="
      echo "ROUTE: ast-grep"
      if [ -z "$raw" ]; then
        echo "  (no matches)"
      else
        printf '%s\n' "$raw" | head -n 60
      fi
    fi
    ;;

  path)
    files=$(bash "$script_dir/fs_walk.sh" "$normalized" \
      $([ "$include_tests" = "true" ] && echo --include-tests))

    if [ "$json" = "true" ]; then
      files_json="[]"
      if [ -n "$files" ] && command -v node >/dev/null 2>&1; then
        files_json=$(printf '%s' "$files" | node -e '
          const layout=JSON.parse(process.argv[1]);
          function pkgOf(file){let best=null;for(const p of (layout.packages||[])){if(p.dir==="."||!p.dir)continue;if(file===p.dir||file.startsWith(p.dir+"/")){if(!best||p.dir.length>best.dir.length)best=p;}}return best?best.name:"(root)";}
          let s="";process.stdin.on("data",c=>s+=c);
          process.stdin.on("end",()=>{
            const out=s.split("\n").filter(Boolean).map(f=>({file:f,package:pkgOf(f)}));
            process.stdout.write(JSON.stringify(out));
          });
        ' "$layout")
      fi
      emit_json_head
      printf '"route":"fs-walk","files":%s}\n' "$files_json"
    else
      echo "== Path: $normalized =="
      echo "ROUTE: git ls-files / fs walk"
      if [ -z "$files" ]; then
        echo "  (no files match)"
      else
        # Group by package.
        printf '%s\n' "$files" | while IFS= read -r f; do
          [ -z "$f" ] && continue
          pkg=$(classify_pkg "$f")
          echo "  [$pkg] $f"
        done | sort
      fi
    fi
    ;;

  concept)
    hits=$(bash "$script_dir/concept_search.sh" "$normalized" \
      $([ "$include_tests" = "true" ] && echo --include-tests) \
      $([ -n "$pkg_filter" ] && printf -- '--package %s' "$pkg_filter"))

    if [ "$json" = "true" ]; then
      hits_json="[]"
      if [ -n "$hits" ] && command -v node >/dev/null 2>&1; then
        hits_json=$(printf '%s' "$hits" | node -e '
          const layout=JSON.parse(process.argv[1]);
          function pkgOf(file){let best=null;for(const p of (layout.packages||[])){if(p.dir==="."||!p.dir)continue;if(file===p.dir||file.startsWith(p.dir+"/")){if(!best||p.dir.length>best.dir.length)best=p;}}return best?best.name:"(root)";}
          let s="";process.stdin.on("data",c=>s+=c);
          process.stdin.on("end",()=>{
            const out=[];
            for (const line of s.split("\n")) {
              if(!line) continue;
              const m=line.match(/^(.+?):(\d+):(.*)$/);
              if(!m) continue;
              out.push({file:m[1],line:Number(m[2]),snippet:m[3].trim(),package:pkgOf(m[1])});
            }
            process.stdout.write(JSON.stringify(out));
          });
        ' "$layout")
      fi
      emit_json_head
      printf '"route":"ripgrep","hits":%s}\n' "$hits_json"
    else
      echo "== Concept: $normalized =="
      echo "ROUTE: ripgrep (best-effort; re-phrase as symbol or path if noisy)"
      if [ -z "$hits" ]; then
        echo "  (no hits)"
      else
        printf '%s\n' "$hits" | while IFS= read -r line; do
          file=$(printf '%s' "$line" | sed -n 's/^\([^:]*\):.*/\1/p')
          [ -z "$file" ] && continue
          pkg=$(classify_pkg "$file")
          echo "  [$pkg] $line"
        done
      fi
    fi
    ;;

  *)
    echo "ERROR: unknown kind '$kind' (expected symbol|pattern|path|concept)" >&2
    exit 2
    ;;
esac
