#!/usr/bin/env bash
# classify.sh — classify a query string into one of:
#   symbol | pattern | path | concept
# Emits JSON: {"kind": "...", "normalized": "..."}
#
# Usage: classify.sh "<query>"

set -eu

if [ $# -lt 1 ]; then
  echo '{"error":"missing query"}' >&2
  exit 2
fi

q="$1"
# Trim leading/trailing whitespace.
q="${q#"${q%%[![:space:]]*}"}"
q="${q%"${q##*[![:space:]]}"}"

kind=""
normalized="$q"

# --- 1. path ---------------------------------------------------------------
# Slash, glob char, or known code extension.
case "$q" in
  */*|*\**|*\?*|*\[*)
    kind="path" ;;
  *.ts|*.tsx|*.js|*.jsx|*.mjs|*.cjs|*.json|*.md|*.yml|*.yaml|*.css|*.scss|*.html)
    kind="path" ;;
esac

# --- 2. pattern ------------------------------------------------------------
# ast-grep style markers: parens, angle-brackets in code-ish form, $$$, =>.
if [ -z "$kind" ]; then
  case "$q" in
    *'$$$'*|*'$'*'<'*|*'=>'*|*'as any'*|*'('*')'*|*'<'*'>'*)
      kind="pattern" ;;
  esac
  # Bare "name(" or "Name<" (no closing) is also a pattern shape.
  if [ -z "$kind" ]; then
    case "$q" in
      *'('*|*'<'*) kind="pattern" ;;
    esac
  fi
fi

# --- 3. symbol -------------------------------------------------------------
# Single identifier, optionally Class/method form. No spaces.
if [ -z "$kind" ]; then
  case "$q" in
    *' '*) : ;;  # spaces -> not a symbol
    *)
      # Must start with letter/_/$, may contain alnum/_/$, optional /Name suffix.
      if printf '%s' "$q" | grep -Eq '^[A-Za-z_$][A-Za-z0-9_$]*(/[A-Za-z_$][A-Za-z0-9_$]*)*$'; then
        kind="symbol"
      fi
      ;;
  esac
fi

# --- 4. concept (fallback) -------------------------------------------------
if [ -z "$kind" ]; then
  kind="concept"
fi

# Serialize via python3 so control chars (newlines, tabs) and quoted content
# round-trip safely. Sed-only escaping produces invalid JSON for those.
if command -v python3 >/dev/null 2>&1; then
  KIND="$kind" NORM="$normalized" python3 -c '
import json, os
print(json.dumps({"kind": os.environ["KIND"], "normalized": os.environ["NORM"]}))
'
else
  esc=$(printf '%s' "$normalized" | sed 's/\\/\\\\/g; s/"/\\"/g')
  printf '{"kind":"%s","normalized":"%s"}\n' "$kind" "$esc"
fi
