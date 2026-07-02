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
    --kind)
      # Guard the value: with `set -e`, a bare `shift 2` on a valueless last
      # flag kills the script with a silent status-1 instead of a usage error.
      if [ $# -lt 2 ]; then
        echo "where-is.sh: --kind requires a value (symbol|pattern|path|concept)" >&2
        exit 2
      fi
      kind_override="$2"; shift 2 ;;
    --json) json="true"; shift ;;
    --include-tests) include_tests="true"; shift ;;
    --package)
      if [ $# -lt 2 ]; then
        echo "where-is.sh: --package requires a package name" >&2
        exit 2
      fi
      pkg_filter="$2"; shift 2 ;;
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
  # Parse via python3 when available — classify.sh now emits python-style
  # spaced JSON (`{"kind": "..."}`) which the old sed regex (`"kind":"..."` with
  # no space) missed entirely, dropping every classification back to "concept".
  if command -v python3 >/dev/null 2>&1; then
    parsed=$(printf '%s' "$classification" | CLS_FALLBACK_KIND="concept" python3 -c '
import json, os, sys
try:
  d = json.loads(sys.stdin.read())
except Exception:
  d = {}
print(d.get("kind", os.environ.get("CLS_FALLBACK_KIND", "concept")))
print(d.get("normalized", ""))
' 2>/dev/null || true)
    kind=$(printf '%s\n' "$parsed" | sed -n '1p')
    normalized=$(printf '%s\n' "$parsed" | sed -n '2p')
  else
    # Fall back to a tolerant sed that accepts optional whitespace around `:`.
    kind=$(printf '%s' "$classification" | sed -n 's/.*"kind"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
    normalized=$(printf '%s' "$classification" | sed -n 's/.*"normalized"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
  fi
fi
[ -z "$kind" ] && kind="concept"
[ -z "$normalized" ] && normalized="$query"

# --- layout ----------------------------------------------------------------

layout=$(bash "$script_dir/detect_layout.sh" "$root" 2>/dev/null || echo '{"workspace_kind":"none","packages":[]}')

# --- helpers ---------------------------------------------------------------

annotate_lines() {
  # Read result lines on stdin and emit each prefixed with `  [pkg] `, where
  # pkg is the workspace package the line's file belongs to. Single node
  # invocation for the whole batch — the old per-line classify_pkg spawned a
  # fresh `node -e` per result (30 hits ~= 1.5-2.5s of interpreter startup).
  # Mode "hits" parses `file:line:snippet` lines; mode "files" treats each
  # line as a bare path. Strips an absolute $root prefix off files before
  # comparing — ripgrep produces absolute paths against relative workspace
  # dirs, so every hit used to end up labeled "(root)".
  local mode="$1"
  if ! command -v node >/dev/null 2>&1; then
    # Match the old no-node classify_pkg fallback: label everything "(root)".
    sed 's/^/  [(root)] /'
    return
  fi
  node -e '
    const layout = JSON.parse(process.argv[1]);
    const root = process.argv[2] || "";
    const mode = process.argv[3] || "hits";
    function pkgOf(file) {
      if (root && file.startsWith(root + "/")) file = file.slice(root.length + 1);
      let best = null;
      for (const p of (layout.packages || [])) {
        if (p.dir === "." || !p.dir) continue;
        if (file === p.dir || file.startsWith(p.dir + "/")) {
          if (!best || p.dir.length > best.dir.length) best = p;
        }
      }
      return best ? best.name : "(root)";
    }
    process.stdin.setEncoding("utf8"); let s = ""; process.stdin.on("data", c => s += c);
    process.stdin.on("end", () => {
      const out = [];
      for (const line of s.split("\n")) {
        if (!line) continue;
        let file = line;
        if (mode === "hits") {
          const m = line.match(/^(.+?):\d+:/);
          file = m ? m[1] : line.split(":")[0];
        }
        out.push("  [" + pkgOf(file) + "] " + line);
      }
      process.stdout.write(out.length ? out.join("\n") + "\n" : "");
    });
  ' "$layout" "$root" "$mode"
}

# Safely JSON-encode a string. Uses python3 json.dumps so newlines, tabs,
# control chars, and backslashes round-trip correctly. Returns a quoted JSON
# string (including its surrounding quotes).
json_encode() {
  if command -v python3 >/dev/null 2>&1; then
    printf '%s' "$1" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))'
  else
    # Best-effort fallback for systems without python3: strip control chars
    # (lossy, but keeps the JSON valid — raw control chars inside a string
    # are invalid JSON), then escape backslashes and quotes.
    printf '"%s"' "$(printf '%s' "$1" | LC_ALL=C tr -d '\000-\037' | sed 's/\\/\\\\/g; s/"/\\"/g')"
  fi
}

emit_json_head() {
  printf '{"kind":%s,"query":%s,"normalized":%s,' \
    "$(json_encode "$kind")" \
    "$(json_encode "$query")" \
    "$(json_encode "$normalized")"
}

# --- dispatch --------------------------------------------------------------

case "$kind" in
  symbol)
    # Cannot call Serena from shell. Emit canonical name + ripgrep fallback.
    rg_hits=""
    if command -v rg >/dev/null 2>&1; then
      rg_args=(
        --line-number --no-heading --color=never
        --type-add 'tsj:*.ts,*.tsx,*.js,*.jsx,*.mjs,*.cjs' -t tsj
        --glob '!node_modules' --glob '!dist' --glob '!build'
        --glob '!.next' --glob '!coverage'
      )
      if [ "$include_tests" != "true" ]; then
        rg_args+=(--glob '!*.test.*' --glob '!*.spec.*' --glob '!__tests__/**')
      fi
      # Pre-escape ripgrep regex metacharacters in the symbol name so JS/TS
      # symbols like `useQuery$` or `Foo[Bar]` don't break the def_re.
      safe_sym=$(printf '%s' "$normalized" | sed 's/[].*+?^${}()|[\\]/\\&/g')
      # Word boundary that handles trailing `$` / non-word identifier chars.
      # `\b` after `$` fails because `$` is non-word; use an explicit
      # not-an-identifier-char-or-end-of-line guard instead.
      wb='([^A-Za-z0-9_$]|$)'
      # Prefer "class Foo" / "function Foo" / "const Foo" / "export ... Foo" definitions.
      def_re="(class|function|const|let|var|interface|type|enum)[[:space:]]+${safe_sym}${wb}|export[[:space:]]+(default[[:space:]]+)?(class|function|const|let|var|interface|type|enum)[[:space:]]+${safe_sym}${wb}"
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
          const root = process.argv[2] || "";
          function pkgOf(file) {
            // rg emits absolute paths when invoked with abs root; strip the
            // prefix so comparisons against relative workspace dirs work.
            if (root && file.startsWith(root + "/")) file = file.slice(root.length + 1);
            let best=null;
            for (const p of (layout.packages||[])) {
              if (p.dir==="."||!p.dir) continue;
              if (file===p.dir||file.startsWith(p.dir+"/")) {
                if (!best||p.dir.length>best.dir.length) best=p;
              }
            }
            return best?best.name:"(root)";
          }
          process.stdin.setEncoding("utf8"); let s=""; process.stdin.on("data",c=>s+=c);
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
        ' "$layout" "$root")
      fi
      emit_json_head
      # Safely JSON-encode $normalized for the next_actions payload (was raw).
      name_path_json=$(json_encode "$normalized")
      printf '"route":"serena-mcp","next_actions":[{"tool":"mcp__serena__find_symbol","args":{"name_path":%s,"include_body":false}},{"tool":"mcp__serena__find_referencing_symbols","args":{"name_path":%s}}],"fallback_hits":%s}\n' \
        "$name_path_json" "$name_path_json" "$hits_json"
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
        printf '%s\n' "$rg_hits" | annotate_lines hits
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
      # Build args as an array — unquoted $(...) / ${var:+...} word-splits and
      # glob-expands, which would let `--package "*"` enumerate files in cwd.
      cs_args=()
      [ "$include_tests" = "true" ] && cs_args+=(--include-tests)
      [ -n "$pkg_filter" ] && cs_args+=(--package "$pkg_filter")
      raw=$(bash "$script_dir/concept_search.sh" "$normalized" "${cs_args[@]+"${cs_args[@]}"}")
      if [ "$json" = "true" ]; then
        # Keep the same JSON envelope as the ast-grep path — the fallback used
        # to stream raw text regardless of --json, breaking JSON consumers.
        emit_json_head
        printf '"route":"ripgrep-fallback","matches":%s}\n' "$(json_encode "$raw")"
      else
        [ -n "$raw" ] && printf '%s\n' "$raw"
      fi
      exit 0
    fi

    ag_args=(--pattern "$normalized" --lang tsx)
    # ast-grep's native --globs flag (singular flag, list values, gitignore
    # semantics with leading `!` to exclude) is the canonical way to exclude
    # test files. Earlier attempt used --ignore which doesn't exist as a glob
    # flag in ast-grep.
    if [ "$include_tests" != "true" ]; then
      ag_args+=(--globs '!*.test.*' --globs '!*.spec.*' --globs '!**/__tests__/**')
    fi
    # Resolve --package to a workspace dir (same path as concept_search.sh).
    ag_search_root="$root"
    if [ -n "$pkg_filter" ] && command -v python3 >/dev/null 2>&1; then
      pkg_dir=$(printf '%s' "$layout" | WHEREIS_PKG="$pkg_filter" python3 -c '
import json, os, sys
try: d=json.loads(sys.stdin.read())
except Exception: sys.exit(0)
name=os.environ.get("WHEREIS_PKG","")
for p in (d.get("packages") or []):
  if p.get("name")==name and p.get("dir"):
    print(p["dir"]); break
' 2>/dev/null || true)
      if [ -n "$pkg_dir" ] && [ -d "$root/$pkg_dir" ]; then
        ag_search_root="$root/$pkg_dir"
      fi
    fi
    raw=$("$AG" "${ag_args[@]}" "$ag_search_root" 2>/dev/null || true)

    if [ "$json" = "true" ]; then
      emit_json_head
      # Use the json_encode helper so tabs/newlines/control chars round-trip
      # safely; previous sed|awk pipeline left control chars unescaped.
      matches_json=$(json_encode "$raw")
      printf '"route":"ast-grep","matches":%s}\n' "$matches_json"
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
    fw_args=()
    [ "$include_tests" = "true" ] && fw_args+=(--include-tests)
    files=$(bash "$script_dir/fs_walk.sh" "$normalized" "${fw_args[@]+"${fw_args[@]}"}")

    if [ "$json" = "true" ]; then
      files_json="[]"
      if [ -n "$files" ] && command -v node >/dev/null 2>&1; then
        files_json=$(printf '%s' "$files" | node -e '
          const layout=JSON.parse(process.argv[1]);
          function pkgOf(file){let best=null;for(const p of (layout.packages||[])){if(p.dir==="."||!p.dir)continue;if(file===p.dir||file.startsWith(p.dir+"/")){if(!best||p.dir.length>best.dir.length)best=p;}}return best?best.name:"(root)";}
          process.stdin.setEncoding("utf8");let s="";process.stdin.on("data",c=>s+=c);
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
        printf '%s\n' "$files" | annotate_lines files | sort
      fi
    fi
    ;;

  concept)
    # Build args as an array — see pattern-mode fix above for rationale.
    cs_args=()
    [ "$include_tests" = "true" ] && cs_args+=(--include-tests)
    [ -n "$pkg_filter" ] && cs_args+=(--package "$pkg_filter")
    hits=$(bash "$script_dir/concept_search.sh" "$normalized" "${cs_args[@]+"${cs_args[@]}"}")

    if [ "$json" = "true" ]; then
      hits_json="[]"
      if [ -n "$hits" ] && command -v node >/dev/null 2>&1; then
        hits_json=$(printf '%s' "$hits" | node -e '
          const layout=JSON.parse(process.argv[1]);
          const root=process.argv[2]||"";
          // rg result paths are absolute (search root was $root/$pkg or $root);
          // strip the prefix before classifying against relative workspace dirs.
          function pkgOf(file){if(root&&file.startsWith(root+"/"))file=file.slice(root.length+1);let best=null;for(const p of (layout.packages||[])){if(p.dir==="."||!p.dir)continue;if(file===p.dir||file.startsWith(p.dir+"/")){if(!best||p.dir.length>best.dir.length)best=p;}}return best?best.name:"(root)";}
          process.stdin.setEncoding("utf8");let s="";process.stdin.on("data",c=>s+=c);
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
        ' "$layout" "$root")
      fi
      emit_json_head
      printf '"route":"ripgrep","hits":%s}\n' "$hits_json"
    else
      echo "== Concept: $normalized =="
      echo "ROUTE: ripgrep (best-effort; re-phrase as symbol or path if noisy)"
      if [ -z "$hits" ]; then
        echo "  (no hits)"
      else
        printf '%s\n' "$hits" | annotate_lines hits
      fi
    fi
    ;;

  *)
    echo "ERROR: unknown kind '$kind' (expected symbol|pattern|path|concept)" >&2
    exit 2
    ;;
esac
