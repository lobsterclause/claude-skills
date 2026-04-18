#!/usr/bin/env bash
# run_reviewers.sh — run codex and/or gemini in parallel against the current diff.
#
# Usage:
#   run_reviewers.sh --base <branch> --out <dir> [--reviewers codex,gemini] [--timeout <sec>]
#
# Writes:
#   <out>/codex.stdout     — codex review (stderr merged)
#   <out>/codex.meta.json  — {exit_code, duration_s}
#   <out>/gemini.stdout    — gemini JSON
#   <out>/gemini.stderr
#   <out>/gemini.meta.json
#   <out>/run.meta.json    — overall run metadata (skipped reason, etc.)
#
# Exit codes:
#   0 — at least one reviewer succeeded, OR run was skipped intentionally (empty diff)
#   1 — all requested reviewers failed, or none were available
#   2 — usage / argument error

set -uo pipefail

base=""
out=""
reviewers="codex,gemini"
timeout_s=300

need_val() {
  local flag="$1"
  local argc="$2"
  if [[ "$argc" -lt 2 ]]; then
    echo "missing value for $flag" >&2
    exit 2
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --base)      need_val --base      "$#"; base="$2";      shift 2 ;;
    --out)       need_val --out       "$#"; out="$2";       shift 2 ;;
    --reviewers) need_val --reviewers "$#"; reviewers="$2"; shift 2 ;;
    --timeout)   need_val --timeout   "$#"; timeout_s="$2"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

if [[ -z "$base" || -z "$out" ]]; then
  echo "usage: $0 --base <branch> --out <dir> [--reviewers codex,gemini] [--timeout <sec>]" >&2
  exit 2
fi

mkdir -p "$out"

# Empty-diff short-circuit: burning 5 min + tens of thousands of tokens on a
# no-op branch produces nothing real (and sometimes invites hallucinated
# findings). Reviewers also can't diff what they can't see.
if git diff --quiet "$base"...HEAD 2>/dev/null; then
  printf '{"skipped": true, "reason": "no_diff_against_base", "base": "%s"}\n' "$base" > "$out/run.meta.json"
  echo "no diff against $base — skipping reviewers" >&2
  exit 0
fi

# Timeout shim: macOS has no `timeout` by default. `gtimeout` ships with
# coreutils (brew install coreutils). Pick whichever is present; otherwise
# warn loudly — a stalled auth flow can hang the whole review forever.
TIMEOUT_BIN=""
if command -v timeout >/dev/null 2>&1; then
  TIMEOUT_BIN="timeout"
elif command -v gtimeout >/dev/null 2>&1; then
  TIMEOUT_BIN="gtimeout"
else
  echo "warning: neither 'timeout' nor 'gtimeout' is available — reviewers will run unbounded. Install coreutils (brew install coreutils) to enable the ${timeout_s}s cutoff." >&2
fi

run_with_timeout() {
  # Usage: run_with_timeout <secs> <cmd...>
  # Runs cmd with timeout if available; otherwise just exec.
  local secs="$1"; shift
  if [[ -n "$TIMEOUT_BIN" ]]; then
    "$TIMEOUT_BIN" "$secs" "$@"
  else
    "$@"
  fi
}

script_dir="$(cd "$(dirname "$0")" && pwd)"
prompt_file="$script_dir/../references/review_prompt.txt"

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
  # codex exec review runs the built-in review prompt against the branch diff.
  # --full-auto: low-friction sandbox, workspace-write, no approval prompts.
  # IMPORTANT: --base and a positional [PROMPT] are mutually exclusive — if you
  # want a custom prompt, you must drop --base and put the base reference inside
  # the prompt itself.
  # NO --json: the JSONL stream omits the final review summary for `exec review`.
  # Plain-text mode flushes the review after the "codex" marker; we merge
  # stderr→stdout (2>&1) because codex writes progress trace AND the final
  # review to stderr while stdout is empty in this mode.
  run_with_timeout "$timeout_s" codex exec review \
    --base "$base" \
    --full-auto \
    >"$out/codex.stdout" 2>&1
  rc=$?
  end=$(date +%s)
  printf '{"exit_code": %d, "duration_s": %d}\n' "$rc" "$((end - start))" >"$out/codex.meta.json"
  # IMPORTANT: return $rc so the caller's `wait "$pid"` sees the real exit code.
  # Previous version ended with `printf` whose success (exit 0) masked every
  # upstream reviewer failure.
  return "$rc"
}

run_gemini() {
  local start end rc
  start=$(date +%s)
  # gemini has no built-in review mode — we pass a prompt and let it use its
  # file-reading tools inside the repo.
  # --approval-mode plan: read-only, won't attempt edits.
  # --output-format json: one structured JSON blob on stdout.
  # -p carries the prompt. Do NOT also pipe stdin (`< /dev/null` avoids it);
  # gemini appends stdin to -p, which would duplicate and waste tokens.
  local diff_summary
  diff_summary="$(git diff --stat "$base"...HEAD 2>/dev/null | head -50 || true)"
  local full_prompt
  full_prompt="$review_prompt

Changed files (diff --stat against $base):
$diff_summary

Use your file-reading tools to inspect the actual changes. Return your findings as prose, organized by severity."

  run_with_timeout "$timeout_s" gemini \
    --approval-mode plan \
    --output-format json \
    -p "$full_prompt" \
    >"$out/gemini.stdout" 2>"$out/gemini.stderr" </dev/null
  rc=$?
  end=$(date +%s)
  printf '{"exit_code": %d, "duration_s": %d}\n' "$rc" "$((end - start))" >"$out/gemini.meta.json"
  return "$rc"
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

# Wait for each; track individual status. Since run_codex/run_gemini now
# `return "$rc"`, wait sees the real reviewer exit code.
any_ok=0
for i in "${!pids[@]}"; do
  pid="${pids[$i]}"
  name="${ran[$i]}"
  if wait "$pid"; then
    any_ok=1
    echo "$name: ok" >&2
  else
    # stderr for gemini is separate; codex merges stderr into stdout. Point the
    # user at the right file.
    case "$name" in
      codex)  echo "$name: failed (see $out/codex.stdout and $out/codex.meta.json)" >&2 ;;
      gemini) echo "$name: failed (see $out/gemini.stderr and $out/gemini.meta.json)" >&2 ;;
      *)      echo "$name: failed (see $out/$name.* )" >&2 ;;
    esac
  fi
done

[[ "$any_ok" -eq 1 ]] || exit 1
exit 0