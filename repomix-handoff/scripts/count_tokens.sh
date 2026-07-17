#!/usr/bin/env bash
# count_tokens.sh — count tokens in a file using ttok (preferred), python tiktoken
# (fallback), or a char/4 estimate (last resort).
#
# Usage: count_tokens.sh <file>
# Output: a single integer on stdout. On stderr, the method used.
#
# Exit codes: 0 ok, 2 usage.
set -eu

file="${1:-}"
if [ -z "$file" ] || [ ! -f "$file" ]; then
  echo "usage: count_tokens.sh <file>" >&2
  exit 2
fi

# Size guard (issue #12 medium): every exact method below loads the whole file
# into memory (ttok stdin slurp, tiktoken f.read()). A multi-GB snapshot would
# OOM — and is over any realistic token budget anyway, so a cheap estimate is
# fine. Tunable via COUNT_TOKENS_MAX_BYTES; default 50 MB.
max_bytes="${COUNT_TOKENS_MAX_BYTES:-52428800}"
bytes="$(wc -c < "$file" | tr -d ' ')"
if [ "$bytes" -gt "$max_bytes" ]; then
  echo "method=char-div-4-estimate (size guard: ${bytes}B > ${max_bytes}B, skipping exact tokenization)" >&2
  echo $(( bytes / 4 ))
  exit 0
fi

# 1. ttok via npx (https://github.com/simonw/ttok is python; there is a node port).
if command -v ttok >/dev/null 2>&1; then
  echo "method=ttok-global" >&2
  ttok < "$file" | tail -n1 | tr -dc '0-9'
  echo ""
  exit 0
fi

# 2. python + tiktoken
if command -v python3 >/dev/null 2>&1; then
  out="$(python3 - "$file" <<'PY' 2>/dev/null || true
import sys
try:
    import tiktoken
except Exception:
    sys.exit(3)
enc = tiktoken.get_encoding("cl100k_base")
with open(sys.argv[1], "r", encoding="utf-8", errors="ignore") as f:
    data = f.read()
print(len(enc.encode(data)))
PY
)"
  if [ -n "${out:-}" ]; then
    echo "method=python-tiktoken" >&2
    echo "$out"
    exit 0
  fi
fi

# 3. npx ttok (simonw/ttok python pkg) — only attempt if pipx/uvx absent.
if command -v uvx >/dev/null 2>&1; then
  out="$(uvx --quiet ttok < "$file" 2>/dev/null | tail -n1 | tr -dc '0-9' || true)"
  if [ -n "${out:-}" ]; then
    echo "method=uvx-ttok" >&2
    echo "$out"
    exit 0
  fi
fi

# 4. char/4 estimate (English-text heuristic, very rough).
bytes="$(wc -c < "$file" | tr -d ' ')"
est=$(( bytes / 4 ))
echo "method=char-div-4-estimate" >&2
echo "$est"
exit 0
