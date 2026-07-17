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

# --- 1. symbol -------------------------------------------------------------
# Single identifier, optionally Class/method form (Serena name_path style).
# Run this BEFORE the path check so `Class/method` is classified as symbol,
# not path. The pattern is restrictive (no spaces, no globs, no dots) so it
# only matches identifier-shaped strings.
#
# [pin: issue #14 item 16] A prior review pass questioned this ordering —
# ordinary extension-less directory paths like `apps/mobile/hooks` also
# match the shape-only regex below and would misclassify as symbol. Smoke-
# verified this is intentional and working as designed: Serena's
# `find_symbol` on a bogus name is a cheap, self-correcting miss (the model
# notices and retries), while path-first would make the documented Serena
# `Class/method` name_path form (SKILL.md rule 3) permanently unreachable
# without `--kind symbol` on every call. Do not reorder without discussing —
# see git history on plugins/where-is for the fuller writeup.
case "$q" in
  *' '*) : ;;  # spaces -> not a symbol
  *)
    if printf '%s' "$q" | grep -Eq '^[A-Za-z_$][A-Za-z0-9_$]*(/[A-Za-z_$][A-Za-z0-9_$]*)*$'; then
      kind="symbol"
    fi
    ;;
esac

# --- 2. path ---------------------------------------------------------------
# Slash, glob char, or known code extension. Only fires if the string didn't
# already qualify as a symbol — so `Class/method` stays a symbol.
if [ -z "$kind" ]; then
  case "$q" in
    */*|*\**|*\?*|*\[*)
      kind="path" ;;
    *.ts|*.tsx|*.js|*.jsx|*.mjs|*.cjs|*.json|*.md|*.yml|*.yaml|*.css|*.scss|*.html)
      kind="path" ;;
  esac
fi

# --- 3. pattern ------------------------------------------------------------
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
  # Strip control chars first (lossy, but raw control chars inside a JSON
  # string are invalid JSON — the sed-only fallback used to emit them as-is),
  # then escape backslashes and quotes.
  esc=$(printf '%s' "$normalized" | LC_ALL=C tr -d '\000-\037' | sed 's/\\/\\\\/g; s/"/\\"/g')
  printf '{"kind":"%s","normalized":"%s"}\n' "$kind" "$esc"
fi
