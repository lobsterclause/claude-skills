#!/usr/bin/env bash
# factcheck_findings.sh — falsify-only fact-check gate. Ported from
# open-code-review's REVIEW_FILTER_TASK (Apache-2.0): a cheap, DIFF-ONLY LLM pass
# whose only job is to remove findings the diff itself PROVES wrong. It can only
# ever drop a finding the diff actively contradicts; it never invents findings
# and never drops one it merely can't confirm.
#
# Reads a findings.json (ideally already run through anchor_findings.sh) and
# writes the same object with `.factcheck = {verdict:"keep"|"drop", reason}` on
# each finding. The orchestrator excludes verdict="drop" from the auto-fix triage.
#
# FAIL-SAFE: any error/timeout/unparseable response => drop NOTHING (every
# finding kept, reason notes why). A broken veto must never cost recall.
#
# Usage:
#   factcheck_findings.sh --findings <json> --out <json>
#                         (--base <ref> [--repo <dir>] | --diff <file>)
#                         [--reviewer agy|kimi|openrouter]  # default agy
#                         [--model "<agy models name>"]   # default Flash High
#                         [--timeout <sec>]         # default 300
#
# When the agy pass fails or produces empty output (quota exhaustion, panic,
# expired auth — see run_reviewers.sh for the taxonomy) and an OpenRouter key
# is available ($OPENROUTER_API_KEY or ~/.config/openrouter/key), the check
# retries once via deepseek/deepseek-v4-flash on OpenRouter before falling
# back to keep-all. (Policy 2026-07-01: first-party models — Gemini, codex,
# claude — are never routed through OpenRouter; DeepSeek Flash is the
# designated cheap fact-check substitute. The falsify-only contract is
# model-agnostic, so the swap is safe.)
#
# Exit: 0 ok (incl. fail-safe keep-all), 2 usage, 1 io error.

set -uo pipefail

findings="" ; out="" ; base="" ; repo="." ; diff_file=""
reviewer="agy" ; model="Gemini 3.5 Flash (High)" ; timeout_s=300

need_val() { [[ "$2" -lt 2 ]] && { echo "missing value for $1" >&2; exit 2; }; }
while [[ $# -gt 0 ]]; do
  case "$1" in
    --findings) need_val "$1" "$#"; findings="$2"; shift 2 ;;
    --out)      need_val "$1" "$#"; out="$2";      shift 2 ;;
    --base)     need_val "$1" "$#"; base="$2";     shift 2 ;;
    --repo)     need_val "$1" "$#"; repo="$2";     shift 2 ;;
    --diff)     need_val "$1" "$#"; diff_file="$2"; shift 2 ;;
    --reviewer) need_val "$1" "$#"; reviewer="$2"; shift 2 ;;
    --model)    need_val "$1" "$#"; model="$2";    shift 2 ;;
    --timeout)  need_val "$1" "$#"; timeout_s="$2"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

[[ -z "$findings" || -z "$out" ]] && { echo "usage: $0 --findings <json> --out <json> (--base <ref> [--repo <dir>] | --diff <file>) [--reviewer agy|kimi|openrouter] [--model <name>] [--timeout <sec>]" >&2; exit 2; }
[[ -f "$findings" ]] || { echo "factcheck: findings file not found: $findings" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "factcheck: jq required" >&2; exit 1; }

if [[ -d "$HOME/.local/bin" && ":$PATH:" != *":$HOME/.local/bin:"* ]]; then PATH="$HOME/.local/bin:$PATH"; fi

tmp_dir="$(mktemp -d)"; trap 'rm -rf "$tmp_dir"' EXIT

# keep_all <reason> — write out with every finding kept; the fail-safe path.
keep_all() {
  jq --arg why "$1" '.findings |= map(.factcheck = {verdict:"keep", reason:$why})' \
    "$findings" > "$out"
  echo "factcheck: kept all $(jq '.findings|length' "$findings") findings — $1" >&2
  exit 0
}

n_findings="$(jq '.findings | length' "$findings")"
[[ "${n_findings:-0}" -eq 0 ]] && keep_all "no findings to check"

# Resolve the diff. In --base mode, SCOPE it to just the files the findings
# reference: this keeps the prompt small (avoids the ARG_MAX/E2BIG class, bug b4)
# and stops the model drifting onto unrelated diff content / inventing its own
# findings (the no-op contract failure, G1). A finding pointing at a file that
# isn't in the scoped diff simply can't be disproven → kept (recall-safe).
diff_path="$tmp_dir/diff.txt"
if [[ -n "$diff_file" ]]; then
  [[ -f "$diff_file" ]] || keep_all "diff file not found (fail-safe)"
  cat -- "$diff_file" > "$diff_path"
elif [[ -n "$base" ]]; then
  # Resolve the repo TOPLEVEL: finding `file` paths are repo-root-relative, but a
  # git pathspec is relative to CWD — running the diff anywhere but the root made
  # the scoped diff silently empty (→ fail-safe keep). Anchor against the root.
  repo_root="$(cd "$repo" 2>/dev/null && git rev-parse --show-toplevel 2>/dev/null)"
  [[ -z "$repo_root" ]] && repo_root="$repo"
  # unique, non-empty file paths from the findings. while-read (not mapfile,
  # which is bash 4+; macOS /bin/bash is 3.2) to stay portable.
  fc_files=()
  while IFS= read -r _f; do [[ -n "$_f" ]] && fc_files+=("$_f"); done \
    < <(jq -r '.findings[].file // empty' "$findings" | sort -u)
  if [[ ${#fc_files[@]} -gt 0 ]]; then
    ( cd "$repo_root" && git diff "$base"...HEAD -- "${fc_files[@]}" ) > "$diff_path" 2>/dev/null || keep_all "git diff failed (fail-safe)"
  else
    ( cd "$repo_root" && git diff "$base"...HEAD ) > "$diff_path" 2>/dev/null || keep_all "git diff failed (fail-safe)"
  fi
else
  echo "factcheck: provide --base or --diff" >&2; exit 2
fi
[[ -s "$diff_path" ]] || keep_all "empty diff (fail-safe)"

# Defuse prompt-injection: an untrusted patch can embed a literal </diff> to
# escape the fence and inject instructions (gemini-pro finding "inj"). Break the
# closing tag so it can't terminate the <diff>…</diff> wrapper in the prompt.
sed 's#</diff>#<\/ diff>#g' "$diff_path" > "$diff_path.safe" && mv "$diff_path.safe" "$diff_path"

# Build the findings block (one compact line per finding; snippet flattened) and
# write it to a file. Both the block and the diff are spliced into the prompt by
# awk reading them as FILES (getline), never as env vars or argv — env/argv are
# capped by ARG_MAX and blow up on large diffs (bug b4).
find_path="$tmp_dir/findings_block.txt"
jq -r '
  .findings[] |
  "[\(.id)] \(.file):\(.line) — \(.claim)\n    snippet: \((.snippet // "") | gsub("\n";" / "))"
' "$findings" > "$find_path"

prompt_file="$(cd "$(dirname "$0")/.." && pwd)/references/factcheck_prompt.txt"
[[ -f "$prompt_file" ]] || keep_all "factcheck_prompt.txt missing (fail-safe)"

prompt="$tmp_dir/prompt.txt"
awk -v diff_file="$diff_path" -v find_file="$find_path" '
  /\{\{DIFF\}\}/     { while ((getline l < diff_file) > 0) print l; close(diff_file); next }
  /\{\{FINDINGS\}\}/ { while ((getline l < find_file) > 0) print l; close(find_file); next }
  { print }
' "$prompt_file" > "$prompt"

# Timeout shim.
TIMEOUT_BIN=""
command -v timeout  >/dev/null 2>&1 && TIMEOUT_BIN="timeout"
[[ -z "$TIMEOUT_BIN" ]] && command -v gtimeout >/dev/null 2>&1 && TIMEOUT_BIN="gtimeout"
run_to() { if [[ -n "$TIMEOUT_BIN" ]]; then "$TIMEOUT_BIN" "$1" "${@:2}"; else "${@:2}"; fi; }

# OpenRouter helpers (mirrors run_reviewers.sh key resolution).
openrouter_key() {
  if [[ -n "${OPENROUTER_API_KEY:-}" ]]; then printf '%s' "$OPENROUTER_API_KEY"; return 0; fi
  [[ -s "$HOME/.config/openrouter/key" ]] && { tr -d '[:space:]' <"$HOME/.config/openrouter/key"; return 0; }
  return 1
}
# openrouter_factcheck <model> — send the full prompt file (instructions + diff
# + findings, via jq --rawfile so it never touches argv) to the OpenRouter
# chat-completions API; writes the model text to $raw. Returns nonzero on any
# transport/API failure — caller decides between fallback and keep_all.
openrouter_factcheck() {
  local or_model="$1" key
  key="$(openrouter_key)" || return 1
  command -v curl >/dev/null 2>&1 || return 1
  local body="$tmp_dir/or_body.json" resp="$tmp_dir/or_resp.json" auth="$tmp_dir/curl-auth"
  jq -n --rawfile p "$prompt" --arg m "$or_model" \
    '{model: $m, messages: [{role: "user", content: $p}], stream: false}' >"$body" || return 1
  # Key via 0600 --config file, never argv (ps-visible). tmp_dir is trap-cleaned.
  ( umask 077; printf 'header = "Authorization: Bearer %s"\n' "$key" >"$auth" )
  curl -sS --max-time "$timeout_s" \
    --config "$auth" \
    -H "Content-Type: application/json" \
    -H "X-Title: cross-review-factcheck" \
    -d @"$body" \
    https://openrouter.ai/api/v1/chat/completions >"$resp" 2>"$tmp_dir/err.txt" || return 1
  [[ -n "$(jq -r '.error.message // empty' "$resp" 2>/dev/null)" ]] && return 1
  jq -r '.choices[0].message.content // empty' "$resp" >"$raw" 2>/dev/null || return 1
  [[ -s "$raw" ]]
}
or_fallback_model="deepseek/deepseek-v4-flash"

raw="$tmp_dir/raw.txt"
case "$reviewer" in
  agy)
    command -v agy >/dev/null 2>&1 || keep_all "agy not installed (fail-safe)"
    # Pass the prompt by FILE PATH, not argv: `-p "$(cat prompt)"` puts the whole
    # diff on the command line and hits MAX_ARG_STRLEN (~128KB) on large diffs
    # (bug b4). agy can read the file itself (--sandbox still permits reads).
    # --print-timeout runs 15s under the wrapper cap so agy flushes instead of
    # being hard-killed mid-write — mirrors run_agy_reviewer (fugu, PR #18 p1).
    agy_pt="${timeout_s}s"; [[ "$timeout_s" -gt 30 ]] && agy_pt="$((timeout_s - 15))s"
    run_to "$timeout_s" agy --model "$model" --sandbox --print-timeout "$agy_pt" \
      -p "Read the file at $prompt and follow its instructions EXACTLY. It contains your full fact-check instructions, a code diff, and a list of findings. Output ONLY the JSON block it specifies — nothing else." \
      >"$raw" 2>"$tmp_dir/err.txt" </dev/null || true
    # agy fails empty on quota exhaustion / panics / expired auth (empty stdout,
    # rc often 0 — see run_reviewers.sh classification). One OpenRouter swing —
    # on DeepSeek Flash, NOT OR-hosted Gemini (policy) — before the keep-all
    # fail-safe keeps the veto alive through agy outages.
    if [[ ! -s "$raw" ]]; then
      if openrouter_factcheck "$or_fallback_model"; then
        model="$or_fallback_model (openrouter fallback)"
        echo "factcheck: agy failed/empty — used OpenRouter fallback ($or_fallback_model)" >&2
      else
        keep_all "agy factcheck failed and OpenRouter fallback unavailable/failed (fail-safe)"
      fi
    fi
    ;;
  kimi)
    command -v kimi >/dev/null 2>&1 || keep_all "kimi not installed (fail-safe)"
    model="kimi"
    run_to "$timeout_s" kimi --plan --print --quiet >"$raw" 2>"$tmp_dir/err.txt" <"$prompt" || keep_all "kimi factcheck failed/timed out (fail-safe)"
    ;;
  openrouter)
    # Direct OpenRouter lane (no agy involved). --model here means an
    # OpenRouter model id; the agy default display-name is not valid — swap it.
    [[ "$model" == "Gemini 3.5 Flash (High)" ]] && model="$or_fallback_model"
    openrouter_factcheck "$model" || keep_all "openrouter factcheck failed (fail-safe)"
    ;;
  *) echo "factcheck: unknown --reviewer '$reviewer' (use agy|kimi|openrouter)" >&2; exit 2 ;;
esac
[[ -s "$raw" ]] || keep_all "empty factcheck output (fail-safe)"

# Extract the {"drop":[...]} object. Prefer a ```json fence, then any ``` fence,
# then the raw body. jq tolerates failure -> empty drop set (fail-safe).
extract_drop() {
  local body
  body="$(sed -n '/```json/,/```/p' "$raw" | sed '1d;$d')"
  [[ -z "$body" ]] && body="$(sed -n '/```/,/```/p' "$raw" | sed '1d;$d')"
  [[ -z "$body" ]] && body="$(cat "$raw")"
  printf '%s' "$body" | jq -ce '{drop: ((.drop // []) | map(select(.id != null)))}' 2>/dev/null
}
drop_json="$(extract_drop)"
[[ -z "$drop_json" ]] && drop_json='{"drop":[]}'

# Contract check (G1): the model must drop only ids we supplied. Count how many
# returned ids actually exist in the finding set. If it returned ids but NONE
# match, it ignored the contract (e.g. invented its own f1.. ids) — surface that
# loudly instead of silently keeping everything and looking like a clean pass.
valid_ids="$(jq -c '[.findings[].id]' "$findings")"
returned_n="$(printf '%s' "$drop_json" | jq '.drop | length')"
matched_n="$(printf '%s' "$drop_json" | jq --argjson ids "$valid_ids" '[.drop[] | select(.id as $i | $ids | index($i))] | length')"
if [[ "${returned_n:-0}" -gt 0 && "${matched_n:-0}" -eq 0 ]]; then
  echo "factcheck: WARNING — model returned $returned_n drop id(s), 0 of which match the supplied findings; it ignored the contract. Keeping all findings (no reliable veto this pass)." >&2
fi

# Annotate findings: matched id -> drop with reason; otherwise keep.
jq --argjson fc "$drop_json" --arg reviewer "$reviewer" --arg model "$model" '
  ($fc.drop // []) as $d
  | .findings |= map(
      . as $f
      | (($d | map(select(.id == $f.id)) | first)) as $hit
      | .factcheck = (if $hit
          then {verdict:"drop", reason: ($hit.reason // "disproven by diff")}
          else {verdict:"keep", reason: null} end)
    )
  | .factcheck_meta = {reviewer: $reviewer, model: $model, ran: true,
                       returned_ids: ($fc.drop | length), matched_ids: ([.findings[] | select(.factcheck.verdict=="drop")] | length)}
' "$findings" > "$out"

# Preserve the raw transcript next to the output for audit. Build the name
# robustly (a non-.json --out would otherwise drop a hidden .factcheck-raw.txt).
raw_sidecar="$(dirname "$out")/$(basename "$out" .json).factcheck-raw.txt"
cp "$raw" "$raw_sidecar" 2>/dev/null || true

dropped_n="$(jq '[.findings[] | select(.factcheck.verdict=="drop")] | length' "$out")"
echo "factcheck: dropped $dropped_n/$n_findings finding(s) as diff-disproven (reviewer=$reviewer)" >&2
