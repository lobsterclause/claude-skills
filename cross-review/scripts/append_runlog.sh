#!/usr/bin/env bash
# append_runlog.sh — emit a single structured JSONL entry summarizing a
# cross-review pass to ~/.claude/skills/cross-review/runlog.jsonl.
#
# Called from SKILL.md step 9.5 (after the report-back block, before worktree
# teardown). The SKILL flow already knows the verdict, top finding, and pass
# number — the wrapper-produced meta.json files supply per-reviewer telemetry.
#
# Usage:
#   append_runlog.sh \
#     --run-dir <path>             # produced by worktree.sh start; contains
#                                  # codex.meta.json, antigravity.meta.json,
#                                  # gemini-pro.meta.json, kimi.meta.json, etc.
#     --project <name>
#     --base <branch>
#     --pr <number|->              # use - for no PR (branch-only run)
#     --pass <n>
#     --verdict <CLEAN|FIXES_APPLIED|NEEDS_DECISION|BLOCKED>
#     --convergent <n>
#     --top "<file:line — title [severity][sources]>"
#     [--diff-files <n>]
#     [--diff-lines <n>]
#     [--notes "<one-liner>"]
#
# Schema is documented in plans/the-miss-on-pr-eager-pond.md (Phase 2).
# Additive — old hand-curated entries in the runlog remain valid.

set -uo pipefail

run_dir=""
project=""
base=""
pr=""
pass=""
verdict=""
convergent="0"
top=""
diff_files=""
diff_lines=""
notes=""

need_val() {
  if [[ "$2" -lt 2 ]]; then
    echo "missing value for $1" >&2
    exit 2
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --run-dir)    need_val "$1" "$#"; run_dir="$2";    shift 2 ;;
    --project)    need_val "$1" "$#"; project="$2";    shift 2 ;;
    --base)       need_val "$1" "$#"; base="$2";       shift 2 ;;
    --pr)         need_val "$1" "$#"; pr="$2";         shift 2 ;;
    --pass)       need_val "$1" "$#"; pass="$2";       shift 2 ;;
    --verdict)    need_val "$1" "$#"; verdict="$2";    shift 2 ;;
    --convergent) need_val "$1" "$#"; convergent="$2"; shift 2 ;;
    --top)        need_val "$1" "$#"; top="$2";        shift 2 ;;
    --diff-files) need_val "$1" "$#"; diff_files="$2"; shift 2 ;;
    --diff-lines) need_val "$1" "$#"; diff_lines="$2"; shift 2 ;;
    --notes)      need_val "$1" "$#"; notes="$2";      shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

for required in run_dir project base pr pass verdict; do
  if [[ -z "${!required}" ]]; then
    echo "usage: $0 --run-dir <p> --project <n> --base <b> --pr <num|-> --pass <n> --verdict <v> [--convergent <n>] [--top <s>] [--diff-files <n>] [--diff-lines <n>] [--notes <s>]" >&2
    exit 2
  fi
done

if ! command -v jq >/dev/null 2>&1; then
  echo "append_runlog: jq required (brew install jq)" >&2
  exit 1
fi

runlog="$(cd "$(dirname "$0")/.." && pwd)/runlog.jsonl"

# Build per-reviewer payload from each meta.json the wrapper wrote. Reviewers
# whose meta is absent are reported as "skipped" so the runlog entry is honest
# about coverage.
reviewer_obj() {
  local name="$1"
  # The wrapper writes meta to $run_dir/raw/<reviewer>.meta.json (step 3 of
  # SKILL.md passes --out "$run_dir/raw"), but earlier docs incorrectly
  # told callers to pass --run-dir "$run_dir" here, which silently
  # classified every reviewer as "skipped" and lost all telemetry.
  # Caught by codex on pass-3 self-review of PR #10. Try $run_dir/raw
  # first (the canonical location), fall back to $run_dir for callers
  # who already point directly at the raw dir.
  local meta=""
  if [[ -f "$run_dir/raw/$name.meta.json" ]]; then
    meta="$run_dir/raw/$name.meta.json"
  elif [[ -f "$run_dir/$name.meta.json" ]]; then
    meta="$run_dir/$name.meta.json"
  else
    echo '{"status":"skipped"}'
    return
  fi
  # Pass through the meta fields verbatim. The wrapper guarantees:
  # exit_code, duration_s, timed_out, output_bytes, attempt, timeout_budget_s
  # (and reviewer-specific extras like truncated for kimi).
  #
  # Status precedence: timed_out FIRST so that timeouts which exit 0 (some
  # `timeout` implementations do depending on signal handling) don't get
  # misclassified as "ok". || fallback handles malformed meta.json (OOM,
  # kill mid-write, garbage); we prefer "failed" telemetry over silently
  # dropping the entire pass when the final --argjson rejects empty input.
  jq -c '. + {status: (if .timed_out == true then "timed_out"
                       elif .exit_code == 0 and (.output_bytes // 0) > 0 then "ok"
                       elif .exit_code == 0 then "empty"
                       else "failed" end)}' "$meta" 2>/dev/null \
    || echo '{"status":"failed","reason":"meta_unparseable"}'
}

codex_json=$(reviewer_obj codex)
antigravity_json=$(reviewer_obj antigravity)
gemini_pro_json=$(reviewer_obj gemini-pro)
kimi_json=$(reviewer_obj kimi)

ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

entry=$(jq -nc \
  --arg ts "$ts" \
  --arg project "$project" \
  --arg base "$base" \
  --arg pr "$pr" \
  --argjson pass "$pass" \
  --arg verdict "$verdict" \
  --argjson convergent "$convergent" \
  --arg top "$top" \
  --arg notes "$notes" \
  --arg diff_files "${diff_files:-}" \
  --arg diff_lines "${diff_lines:-}" \
  --argjson codex "$codex_json" \
  --argjson antigravity "$antigravity_json" \
  --argjson gemini_pro "$gemini_pro_json" \
  --argjson kimi "$kimi_json" \
  '{
    ts: $ts,
    project: $project,
    base: $base,
    pr: (if $pr == "-" then null else ($pr | tonumber? // $pr) end),
    pass: $pass,
    diff_size: (if $diff_files == "" and $diff_lines == "" then null
                else {files: ($diff_files | tonumber? // null),
                      lines: ($diff_lines | tonumber? // null)} end),
    reviewers: {codex: $codex, antigravity: $antigravity, "gemini-pro": $gemini_pro, kimi: $kimi},
    convergent_count: $convergent,
    verdict: $verdict,
    top_finding: (if $top == "" then null else $top end),
    notes: (if $notes == "" then null else $notes end)
  }')

# JSONL — one line, append-only. Wrap in flock to make it splitstream-safe:
# POSIX guarantees write() atomicity below PIPE_BUF (4KB Linux, 512B macOS).
# Our entries are ~500-800B and growing; on macOS they're already at the
# atomicity boundary, and concurrent splitstream rounds writing simultaneously
# could interleave. flock costs ~5 lines and removes the risk.
# `flock` is GNU/Linux native; macOS Homebrew users get it via `brew install
# util-linux` (or use `shlock`/`lockfile`). Fall back to bare append if flock
# is missing — preserves correctness on platforms without it.
if command -v flock >/dev/null 2>&1; then
  (
    flock -x 200
    printf '%s\n' "$entry" >>"$runlog"
  ) 200>"$runlog.lock"
else
  printf '%s\n' "$entry" >>"$runlog"
fi
echo "appended runlog entry: ts=$ts pr=$pr pass=$pass verdict=$verdict" >&2
