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
#                         [--reviewer agy|kimi]     # default agy
#                         [--model "<agy models name>"]   # default Flash High
#                         [--timeout <sec>]         # default 300
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

[[ -z "$findings" || -z "$out" ]] && { echo "usage: $0 --findings <json> --out <json> (--base <ref> [--repo <dir>] | --diff <file>) [--reviewer agy|kimi] [--model <name>] [--timeout <sec>]" >&2; exit 2; }
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

# Resolve the diff.
diff_path="$tmp_dir/diff.txt"
if [[ -n "$diff_file" ]]; then
  [[ -f "$diff_file" ]] || keep_all "diff file not found (fail-safe)"
  cat "$diff_file" > "$diff_path"
elif [[ -n "$base" ]]; then
  ( cd "$repo" && git diff "$base"...HEAD ) > "$diff_path" 2>/dev/null || keep_all "git diff failed (fail-safe)"
else
  echo "factcheck: provide --base or --diff" >&2; exit 2
fi
[[ -s "$diff_path" ]] || keep_all "empty diff (fail-safe)"

# Build the findings block (one compact line per finding; snippet flattened).
findings_block="$(jq -r '
  .findings[] |
  "[\(.id)] \(.file):\(.line) — \(.claim)\n    snippet: \((.snippet // "") | gsub("\n";" / "))"
' "$findings")"

prompt_file="$(cd "$(dirname "$0")/.." && pwd)/references/factcheck_prompt.txt"
[[ -f "$prompt_file" ]] || keep_all "factcheck_prompt.txt missing (fail-safe)"
template="$(cat "$prompt_file")"

# Substitute placeholders. Use awk to splice large bodies (avoids bash ${//} blowups).
prompt="$tmp_dir/prompt.txt"
DIFF_BODY="$(cat "$diff_path")" FIND_BODY="$findings_block" awk '
  { line=$0
    if (line ~ /\{\{DIFF\}\}/)     { print ENVIRON["DIFF_BODY"]; next }
    if (line ~ /\{\{FINDINGS\}\}/) { print ENVIRON["FIND_BODY"]; next }
    print line }
' <<<"$template" > "$prompt"

# Timeout shim.
TIMEOUT_BIN=""
command -v timeout  >/dev/null 2>&1 && TIMEOUT_BIN="timeout"
[[ -z "$TIMEOUT_BIN" ]] && command -v gtimeout >/dev/null 2>&1 && TIMEOUT_BIN="gtimeout"
run_to() { if [[ -n "$TIMEOUT_BIN" ]]; then "$TIMEOUT_BIN" "$1" "${@:2}"; else "${@:2}"; fi; }

raw="$tmp_dir/raw.txt"
case "$reviewer" in
  agy)
    command -v agy >/dev/null 2>&1 || keep_all "agy not installed (fail-safe)"
    # Diff-only: the prompt embeds the diff and instructs no tools. --sandbox as backstop.
    run_to "$timeout_s" agy --model "$model" --sandbox --print-timeout "${timeout_s}s" \
      -p "$(cat "$prompt")" >"$raw" 2>"$tmp_dir/err.txt" </dev/null || keep_all "agy factcheck failed/timed out (fail-safe)"
    ;;
  kimi)
    command -v kimi >/dev/null 2>&1 || keep_all "kimi not installed (fail-safe)"
    model="kimi"
    run_to "$timeout_s" kimi --plan --print --quiet >"$raw" 2>"$tmp_dir/err.txt" <"$prompt" || keep_all "kimi factcheck failed/timed out (fail-safe)"
    ;;
  *) echo "factcheck: unknown --reviewer '$reviewer' (use agy|kimi)" >&2; exit 2 ;;
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
  | .factcheck_meta = {reviewer: $reviewer, model: $model, ran: true}
' "$findings" > "$out"

# Preserve the raw transcript next to the output for audit.
cp "$raw" "${out%.json}.factcheck-raw.txt" 2>/dev/null || true

dropped_n="$(jq '[.findings[] | select(.factcheck.verdict=="drop")] | length' "$out")"
echo "factcheck: dropped $dropped_n/$n_findings finding(s) as diff-disproven (reviewer=$reviewer)" >&2
