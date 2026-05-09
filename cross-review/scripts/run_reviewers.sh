#!/usr/bin/env bash
# run_reviewers.sh — run codex, gemini, and/or kimi in parallel against the current diff.
#
# Usage:
#   run_reviewers.sh --base <branch> --out <dir> [--reviewers codex,gemini,kimi]
#                    [--timeout <sec>]
#                    [--timeout-codex <sec>] [--timeout-gemini <sec>] [--timeout-kimi <sec>]
#
# Per-reviewer timeouts override the global --timeout. Codex tends to either
# return fast or fail fast; gemini/kimi do deep reasoning and need more headroom.
# Default policy: codex=300, gemini=600, kimi=600. The previous 300s blanket cap
# truncated dense-logic diffs (see PR #1985 postmortem).
#
# Writes:
#   <out>/codex.stdout     — codex review (stderr merged)
#   <out>/codex.meta.json  — {exit_code, duration_s}
#   <out>/gemini.stdout    — gemini JSON
#   <out>/gemini.stderr
#   <out>/gemini.meta.json
#   <out>/kimi.stdout      — kimi review text (final assistant message)
#   <out>/kimi.stderr
#   <out>/kimi.meta.json
#   <out>/run.meta.json    — overall run metadata (skipped reason, etc.)
#
# Exit codes:
#   0 — at least one reviewer succeeded, OR run was skipped intentionally (empty diff)
#   1 — all requested reviewers failed, or none were available
#   2 — usage / argument error

set -uo pipefail

base=""
out=""
reviewers="codex,gemini,kimi"
# Global default: 600s. Codex tightens to 300s below since it returns fast or
# fails fast. Gemini/kimi keep 600s — the dense-logic diff in PR #1985
# (postmortem in plans/the-miss-on-pr-eager-pond.md) blew through 300s on both.
timeout_s=600
timeout_codex=""
timeout_gemini=""
timeout_kimi=""

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
    --base)            need_val --base            "$#"; base="$2";            shift 2 ;;
    --out)             need_val --out             "$#"; out="$2";             shift 2 ;;
    --reviewers)       need_val --reviewers       "$#"; reviewers="$2";       shift 2 ;;
    --timeout)         need_val --timeout         "$#"; timeout_s="$2";       shift 2 ;;
    --timeout-codex)   need_val --timeout-codex   "$#"; timeout_codex="$2";   shift 2 ;;
    --timeout-gemini)  need_val --timeout-gemini  "$#"; timeout_gemini="$2";  shift 2 ;;
    --timeout-kimi)    need_val --timeout-kimi    "$#"; timeout_kimi="$2";    shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

if [[ -z "$base" || -z "$out" ]]; then
  echo "usage: $0 --base <branch> --out <dir> [--reviewers codex,gemini,kimi] [--timeout <sec>] [--timeout-codex <sec>] [--timeout-gemini <sec>] [--timeout-kimi <sec>]" >&2
  exit 2
fi

# Per-reviewer timeouts: source from references/reviewer_profiles.json when
# available (canonical config — see Phase 2.5 of the postmortem plan), fall
# back to sensible defaults otherwise. CLI --timeout-<reviewer> flags always
# win. The global --timeout flag is honored only when a profile timeout is
# absent AND no per-reviewer flag is set.
profile_file="$(cd "$(dirname "$0")/.." && pwd)/references/reviewer_profiles.json"
profile_timeout() {
  # Usage: profile_timeout <reviewer>; prints the timeout_s from the profile,
  # or empty string if jq/file/key absent.
  local r="$1"
  [[ -f "$profile_file" ]] || { echo ""; return; }
  command -v jq >/dev/null 2>&1 || { echo ""; return; }
  jq -r --arg r "$r" '.[$r].timeout_s // empty' "$profile_file" 2>/dev/null
}
codex_default="$(profile_timeout codex)"
gemini_default="$(profile_timeout gemini)"
kimi_default="$(profile_timeout kimi)"
codex_timeout="${timeout_codex:-${codex_default:-$(( timeout_s < 300 ? timeout_s : 300 ))}}"
gemini_timeout="${timeout_gemini:-${gemini_default:-$timeout_s}}"
kimi_timeout="${timeout_kimi:-${kimi_default:-$timeout_s}}"

mkdir -p "$out"

# Validate the base ref up front. Without this, `git diff --quiet` below
# would return 128 on a missing ref — which bash treats as non-zero (same as
# "has diff") and the script would spawn reviewers against a broken
# comparison, wasting tokens and inviting hallucinated findings. Fail loud
# so the caller can retry with a valid --base instead of silently wrong.
if ! git rev-parse --verify --quiet "$base^{commit}" >/dev/null; then
  echo "invalid or unknown base ref: $base" >&2
  echo "  hint: try 'git fetch origin' or pass --base <ref> explicitly" >&2
  exit 1
fi

# Empty-diff short-circuit: burning 5 min + tens of thousands of tokens on a
# no-op branch produces nothing real (and sometimes invites hallucinated
# findings). Reviewers also can't diff what they can't see.
# (Base is validated above, so `git diff --quiet` here returns 0 (no diff) or
# 1 (has diff) cleanly, never 128.)
if git diff --quiet "$base"...HEAD; then
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

# retry_reviewer: run a reviewer function once, retry once on nonzero exit
# with a jittered 5-15s backoff. Applied only to gemini/kimi, which get
# flaky under concurrent or quick-succession runs (rate limits, auth
# handshake races). Codex has been reliable — don't wrap it.
#
# Timeout (rc=124, the convention used by both `timeout` and `gtimeout`) is
# explicitly NOT retried. A reviewer that just used its full budget of
# reasoning tokens will use the same budget on attempt 2 and time out again,
# which only doubles the cost. PR #1985 postmortem caught this — the cure
# for "needs more time" is a longer per-reviewer timeout, not a retry. True
# transient failures (rc=1, network errors) still retry.
#
# Exports CROSS_REVIEW_ATTEMPT so run_gemini / run_kimi can include it in
# their meta output. An exported env var (vs. bash dynamic scoping on a
# `local`) survives callees that declare their own `local attempt`, which
# is a reasonable future refactor that would otherwise silently break the
# retry telemetry.
retry_reviewer() {
  local fn="$1"
  local name="$2"
  export CROSS_REVIEW_ATTEMPT=1
  "$fn"
  local rc=$?
  if [[ $rc -ne 0 && $rc -ne 124 ]]; then
    local backoff=$((5 + RANDOM % 11))
    echo "$name: attempt 1 failed (rc=$rc), retrying in ${backoff}s" >&2
    sleep "$backoff"
    export CROSS_REVIEW_ATTEMPT=2
    "$fn"
    rc=$?
    if [[ $rc -eq 0 ]]; then
      echo "$name: attempt 2 succeeded" >&2
    else
      echo "$name: attempt 2 also failed (rc=$rc)" >&2
    fi
  elif [[ $rc -eq 124 ]]; then
    echo "$name: attempt 1 timed out (rc=124), not retrying — bump --timeout-$name if this recurs" >&2
  fi
  unset CROSS_REVIEW_ATTEMPT
  return "$rc"
}

# Helper: compute output bytes for a reviewer's primary stdout file. Used in
# meta.json so the runlog can distinguish "ran but produced nothing" (silent
# fail) from "ran and produced findings".
output_bytes_of() {
  local f="$1"
  if [[ -f "$f" ]]; then
    wc -c <"$f" | tr -d ' '
  else
    echo 0
  fi
}

script_dir="$(cd "$(dirname "$0")" && pwd)"
prompt_file="$script_dir/../references/review_prompt.txt"

# Note: review_prompt is only used by gemini. codex exec review --base <ref>
# applies codex's own built-in review instructions (which already rank findings
# with [P1]/[P2]/[P3] labels — equivalent to High/Medium/Low — and cover
# correctness, security, and semantic drift). Forcing our prompt into codex
# would require dropping --base and reconstructing the diff setup in text,
# which is more complexity for negligible gain.
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
  run_with_timeout "$codex_timeout" codex exec review \
    --base "$base" \
    --full-auto \
    >"$out/codex.stdout" 2>&1
  rc=$?
  end=$(date +%s)
  local timed_out="false"
  [[ $rc -eq 124 ]] && timed_out="true"
  local bytes
  bytes=$(output_bytes_of "$out/codex.stdout")
  printf '{"exit_code": %d, "duration_s": %d, "timed_out": %s, "output_bytes": %s, "attempt": 1, "timeout_budget_s": %d}\n' \
    "$rc" "$((end - start))" "$timed_out" "$bytes" "$codex_timeout" >"$out/codex.meta.json"
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

  run_with_timeout "$gemini_timeout" gemini \
    --approval-mode plan \
    --output-format json \
    -p "$full_prompt" \
    >"$out/gemini.stdout" 2>"$out/gemini.stderr" </dev/null
  rc=$?
  end=$(date +%s)
  local timed_out="false"
  [[ $rc -eq 124 ]] && timed_out="true"
  local bytes
  bytes=$(output_bytes_of "$out/gemini.stdout")
  printf '{"exit_code": %d, "duration_s": %d, "timed_out": %s, "output_bytes": %s, "attempt": %d, "timeout_budget_s": %d}\n' \
    "$rc" "$((end - start))" "$timed_out" "$bytes" "${CROSS_REVIEW_ATTEMPT:-1}" "$gemini_timeout" >"$out/gemini.meta.json"
  return "$rc"
}

run_kimi() {
  local start end rc
  start=$(date +%s)
  # kimi (Moonshot's Kimi Code CLI) against Moonshot's OpenAI-compatible endpoint.
  #
  # We deliberately run kimi in single-turn, no-tools mode: pipe the full diff
  # inline and instruct the model not to call any tools. Why:
  #   (a) kimi-k2.5's thinking mode + multi-turn tool calls requires threading
  #       `reasoning_content` between turns, and the `openai_legacy` adapter
  #       doesn't preserve it — the second turn fails with "thinking is enabled
  #       but reasoning_content is missing".
  #   (b) Single-turn with thinking-on gives better review quality than
  #       multi-turn with thinking-off.
  #   (c) Code review is fundamentally a single-turn task: the diff IS the
  #       input. codex and gemini already do the agentic file-roaming; kimi
  #       fills a different niche — deep reasoning on the diff as given.
  #
  # --plan: defense in depth (can't edit files even if it tried).
  # --print: non-interactive. Implies --yolo.
  # --quiet: final assistant message only (drops tool-trace noise).
  # Prompt is piped via stdin, NOT argv. Reasons:
  #   - Linux MAX_ARG_STRLEN is 128KB per argument; argv-based prompts would
  #     crash with E2BIG on any diff larger than that (macOS tolerates ~1MB,
  #     which hid the bug in smoke tests).
  #   - Putting the full diff in argv also exposes it via `ps` to other local
  #     users for the duration of the kimi run — a privacy regression vs.
  #     codex/gemini which don't have this issue.
  # kimi reads stdin as the prompt when --print is set and no -p is given
  # (confirmed: `echo "..." | kimi --print --quiet` works).
  local diff_summary diff_full diff_line_cap truncation_note truncated
  diff_summary="$(git diff --stat "$base"...HEAD 2>/dev/null | head -50 || true)"
  # Line-based cap (not byte-based). head -c can split mid-codepoint and
  # produce invalid UTF-8; head -n respects line boundaries. 8000 lines keeps
  # us well under k2.5's 256K-token context even for verbose diffs.
  diff_line_cap=8000
  diff_full="$(git diff "$base"...HEAD 2>/dev/null | head -n "$diff_line_cap" || true)"
  local total_lines
  total_lines="$(git diff "$base"...HEAD 2>/dev/null | wc -l | tr -d ' ')"
  if [[ "${total_lines:-0}" -gt "$diff_line_cap" ]]; then
    truncated=true
    truncation_note="

[WARNING: diff truncated to first $diff_line_cap of $total_lines lines. Your review will be INCOMPLETE — the tail of the patch is not shown. Note this limitation in your findings.]"
  else
    truncated=false
    truncation_note=""
  fi
  # Wrap the diff in an XML-ish tag rather than a markdown fence. Diffs can
  # legitimately contain triple-backtick lines (e.g. doc changes that add a
  # fenced code block), which close the fence prematurely and corrupt the
  # prompt. <diff>...</diff> has no such collision surface.
  local full_prompt
  full_prompt="$review_prompt

Do NOT use any file-reading or shell tools. Base your review ONLY on the diff below.${truncation_note}

Changed files (diff --stat against $base):
$diff_summary

Full diff:
<diff>
$diff_full
</diff>

Return your findings as prose, organized by severity (Critical / High / Medium / Low). Reference files and line numbers from the diff headers."

  run_with_timeout "$kimi_timeout" kimi \
    --plan \
    --print \
    --quiet \
    >"$out/kimi.stdout" 2>"$out/kimi.stderr" <<<"$full_prompt"
  rc=$?
  end=$(date +%s)
  # truncated is reported in metadata so downstream synthesizers don't treat a
  # partial review as complete. Convergent finding from both codex and kimi
  # itself in pass 2 of cross-reviewing this skill.
  local timed_out="false"
  [[ $rc -eq 124 ]] && timed_out="true"
  local bytes
  bytes=$(output_bytes_of "$out/kimi.stdout")
  printf '{"exit_code": %d, "duration_s": %d, "timed_out": %s, "output_bytes": %s, "truncated": %s, "total_diff_lines": %d, "diff_line_cap": %d, "attempt": %d, "timeout_budget_s": %d}\n' \
    "$rc" "$((end - start))" "$timed_out" "$bytes" "$truncated" "${total_lines:-0}" "$diff_line_cap" "${CROSS_REVIEW_ATTEMPT:-1}" "$kimi_timeout" \
    >"$out/kimi.meta.json"
  return "$rc"
}

pids=()
ran=()

# Clean up background reviewers on interrupt. Without this, Ctrl+C on the
# orchestrator exits the parent shell but leaves codex/gemini/kimi orphaned,
# burning tokens against APIs nobody is reading any more.
cleanup_pids() {
  [[ ${#pids[@]} -gt 0 ]] || return 0
  kill "${pids[@]}" 2>/dev/null || true
}
trap cleanup_pids EXIT INT TERM

IFS=',' read -ra raw_requested <<<"$reviewers"
# Dedup. Without this, `--reviewers codex,codex` spawns two processes writing
# to the same $out/codex.* files concurrently, producing interleaved garbage.
# Bash 3.2 (macOS default /bin/bash) lacks associative arrays — use a
# delimited string instead.
requested=()
seen=","
for r in "${raw_requested[@]}"; do
  # Strip surrounding whitespace — `--reviewers "codex, gemini"` with a space
  # after the comma used to produce " gemini" which failed to match any case.
  r="${r#"${r%%[![:space:]]*}"}"
  r="${r%"${r##*[![:space:]]}"}"
  [[ -z "$r" ]] && continue
  [[ "$seen" == *",$r,"* ]] && continue
  seen="$seen$r,"
  requested+=("$r")
done

# Stagger spawns by 2s. Launching all three reviewers at t=0 means
# concurrent auth handshakes and simultaneous first requests against shared
# upstream endpoints, which reliably flakes gemini/kimi. A small offset
# lets each initial handshake settle before the next starts.
stagger_s=2

for r in "${requested[@]}"; do
  case "$r" in
    codex)
      if command -v codex >/dev/null 2>&1; then
        [[ ${#pids[@]} -gt 0 ]] && sleep "$stagger_s"
        run_codex &
        pids+=($!)
        ran+=("codex")
      else
        echo "codex not installed — skipping" >&2
      fi
      ;;
    gemini)
      if command -v gemini >/dev/null 2>&1; then
        [[ ${#pids[@]} -gt 0 ]] && sleep "$stagger_s"
        retry_reviewer run_gemini gemini &
        pids+=($!)
        ran+=("gemini")
      else
        echo "gemini not installed — skipping" >&2
      fi
      ;;
    kimi)
      if command -v kimi >/dev/null 2>&1; then
        [[ ${#pids[@]} -gt 0 ]] && sleep "$stagger_s"
        retry_reviewer run_kimi kimi &
        pids+=($!)
        ran+=("kimi")
      else
        echo "kimi not installed — skipping" >&2
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
      kimi)   echo "$name: failed (see $out/kimi.stderr and $out/kimi.meta.json)" >&2 ;;
      *)      echo "$name: failed (see $out/$name.* )" >&2 ;;
    esac
  fi
done

[[ "$any_ok" -eq 1 ]] || exit 1
exit 0