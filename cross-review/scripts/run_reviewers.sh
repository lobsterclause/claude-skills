#!/usr/bin/env bash
# run_reviewers.sh — run codex and/or gemini in parallel against the current diff.
#
# Usage:
#   run_reviewers.sh --base <branch> --out <dir> [--reviewers codex,gemini] [--timeout <sec>]
#
# Writes:
#   <out>/codex.stdout     — codex JSONL
#   <out>/codex.stderr
#   <out>/codex.meta.json  — {exit_code, duration_s}
#   <out>/gemini.stdout    — gemini JSON
#   <out>/gemini.stderr
#   <out>/gemini.meta.json
#
# Exits 0 if at least one reviewer succeeded; 1 if all failed or none were requested.

set -uo pipefail

base=""
out=""
reviewers="codex,gemini"
timeout_s=300

while [[ $# -gt 0 ]]; do
  case "$1" in
    --base) base="$2"; shift 2 ;;
    --out) out="$2"; shift 2 ;;
    --reviewers) reviewers="$2"; shift 2 ;;
    --timeout) timeout_s="$2"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

if [[ -z "$base" || -z "$out" ]]; then
  echo "usage: $0 --base <branch> --out <dir> [--reviewers codex,gemini] [--timeout <sec>]" >&2
  exit 2
fi

mkdir -p "$out"

script_dir="$(cd "$(dirname "$0")" && pwd)"
prompt_file="$script_dir/../references/review_prompt.txt"

# Fallback prompt if reference file is missing.
default_prompt="Review the changes on the current branch against '$base'. \
Focus on correctness, security, and whether the change achieves its stated intent. \
Flag concrete issues tied to file paths and line numbers where possible. \
Rank findings as Critical / High / Medium / Low. Skip pure style nits."

if [[ -f "$prompt_file" ]]; then
  review_prompt="$(cat "$prompt_file")"
  review_prompt="${review_prompt//\{\{BASE\}\}/$base}"
else
  review_prompt="$default_prompt"
fi

run_codex() {
  local start end rc
  start=$(date +%s)
  # codex has a native review subcommand; prefer it.
  # --full-auto: low-friction sandbox, workspace-write, no approval prompts — needed for non-interactive use.
  # IMPORTANT: codex exec review treats --base and a positional [PROMPT] as mutually exclusive
  # ("the argument '--base <BRANCH>' cannot be used with '[PROMPT]'"). When --base is given,
  # codex applies its own built-in review prompt — we drop our custom prompt in that case.
  # NO --json: the JSONL stream emits reasoning/command events but does NOT flush the final
  # review summary when used with `exec review`. Plain-text mode is what we actually want —
  # it prints the review after the "codex" marker line, which is what we synthesize from.
  if command -v timeout >/dev/null 2>&1; then
    timeout "$timeout_s" codex exec review \
      --base "$base" \
      --full-auto \
      >"$out/codex.stdout" 2>&1
    rc=$?
  else
    codex exec review \
      --base "$base" \
      --full-auto \
      >"$out/codex.stdout" 2>&1
    rc=$?
  fi
  end=$(date +%s)
  printf '{"exit_code": %d, "duration_s": %d}\n' "$rc" "$((end - start))" >"$out/codex.meta.json"
}

run_gemini() {
  local start end rc
  start=$(date +%s)
  # gemini doesn't have a built-in review mode; give it the diff via prompt + its own repo access.
  # --approval-mode plan: read-only, won't attempt edits.
  # --output-format json: structured output we can parse.
  # Pass the prompt via -p only. Do NOT also pipe stdin — gemini appends stdin to -p,
  # which would duplicate the prompt and waste tokens.
  local diff_summary
  diff_summary="$(git diff --stat "$base"...HEAD 2>/dev/null | head -50 || true)"
  local full_prompt
  full_prompt="$review_prompt

Changed files (diff --stat against $base):
$diff_summary

Use your file-reading tools to inspect the actual changes. Return your findings as prose, organized by severity."

  if command -v timeout >/dev/null 2>&1; then
    timeout "$timeout_s" gemini \
      --approval-mode plan \
      --output-format json \
      -p "$full_prompt" \
      >"$out/gemini.stdout" 2>"$out/gemini.stderr" < /dev/null
    rc=$?
  else
    gemini \
      --approval-mode plan \
      --output-format json \
      -p "$full_prompt" \
      >"$out/gemini.stdout" 2>"$out/gemini.stderr" < /dev/null
    rc=$?
  fi
  end=$(date +%s)
  printf '{"exit_code": %d, "duration_s": %d}\n' "$rc" "$((end - start))" >"$out/gemini.meta.json"
}

pids=()
ran=()

IFS=',' read -ra requested <<<"$reviewers"
for r in "${requested[@]}"; do
  case "$r" in
    codex)
      if command -v codex >/dev/null 2>&1; then
        run_codex &
        pids+=($!)
        ran+=("codex")
      else
        echo "codex not installed — skipping" >&2
      fi
      ;;
    gemini)
      if command -v gemini >/dev/null 2>&1; then
        run_gemini &
        pids+=($!)
        ran+=("gemini")
      else
        echo "gemini not installed — skipping" >&2
      fi
      ;;
    *)
      echo "unknown reviewer: $r" >&2
      ;;
  esac
done

if [[ ${#pids[@]} -eq 0 ]]; then
  echo "no reviewers available or requested" >&2
  exit 1
fi

# Wait for all; collect individual statuses. We don't let one failure kill the others.
any_ok=0
for i in "${!pids[@]}"; do
  pid="${pids[$i]}"
  name="${ran[$i]}"
  if wait "$pid"; then
    any_ok=1
    echo "$name: ok" >&2
  else
    echo "$name: failed (see $out/$name.stderr)" >&2
  fi
done

[[ "$any_ok" -eq 1 ]] || exit 1
exit 0