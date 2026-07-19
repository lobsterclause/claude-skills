#!/usr/bin/env bash
# merge_raw_findings.sh — deterministic, offline merge of JSON findings from the
# curl-lane reviewers (OpenRouter pool + direct-Moonshot seats like kimi27/
# kimi3) into a single findings.json.
#
# Only the curl lane (run_openrouter_reviewer in run_reviewers.sh) is asked to
# emit machine-parseable JSON (response_format:{type:"json_object"} plus the
# schema-mandate suffix in references/json_findings_suffix.txt). The CLI
# reviewers (codex, the two agy laps, kimi CLI) still answer in free prose and
# are NOT expected to parse here — their stdouts are reported as `unparsed`
# and left for the existing LLM-driven synthesis step (SKILL.md step 4).
#
# For each <reviewer>.stdout under --raw <dir>:
#   - strip markdown code fences (models sometimes wrap JSON in ```/```json
#     despite being told not to)
#   - attempt to parse the result as JSON with a top-level `.findings` array
#   - on success: tag every finding with `"sources": ["<reviewer>"]`
#     (overwriting anything the model put there) and fold it into the merged
#     findings list
#   - on failure (not JSON, or JSON without a `.findings` array): skip
#     silently and report `unparsed: <reviewer>` on stderr
#
# Pure bash + jq. No network, no LLM calls. Exit is ALWAYS 0 (even when every
# input is prose) — partial extraction from whichever reviewers cooperated is
# the whole point; a fully-prose round should not look like a script failure.
#
# Usage: merge_raw_findings.sh --raw <dir> --out <findings.json>

set -uo pipefail

raw=""
out=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --raw) raw="${2:-}"; shift 2 ;;
    --out) out="${2:-}"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

if [[ -z "$raw" || -z "$out" ]]; then
  echo "usage: $0 --raw <dir> --out <findings.json>" >&2
  exit 2
fi

if [[ ! -d "$raw" ]]; then
  echo "raw dir not found: $raw" >&2
  exit 2
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "jq is required" >&2
  exit 2
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

n=0
shopt -s nullglob
files=("$raw"/*.stdout)
shopt -u nullglob
# Sorted, deterministic iteration order (glob order is filesystem-dependent).
# Bash-3.2-compatible (macOS default /bin/bash lacks mapfile/readarray): split
# a sorted, newline-joined list back into an array on IFS=$'\n'.
sorted=()
if [[ ${#files[@]} -gt 0 ]]; then
  IFS=$'\n' sorted=($(printf '%s\n' "${files[@]}" | sort))
  unset IFS
fi

for f in "${sorted[@]}"; do
  base="$(basename "$f")"
  reviewer="${base%.stdout}"

  # Strip any line that opens/closes a markdown fence (```、```json, ```JSON, …)
  # — models sometimes wrap valid JSON in a fence despite being told not to.
  stripped="$(sed -E '/^[[:space:]]*```/d' "$f" 2>/dev/null)"

  parsed=""
  if parsed="$(printf '%s' "$stripped" | jq -c '.findings // empty' 2>/dev/null)" \
     && [[ -n "$parsed" ]] \
     && printf '%s' "$parsed" | jq -e 'type == "array" and all(type == "object")' >/dev/null 2>&1; then
    tagged="$(printf '%s' "$parsed" | jq -c --arg r "$reviewer" '[.[] | . + {sources: [$r]}]')"
    printf '%s' "$tagged" >"$work/$n.json"
    n=$((n + 1))
  else
    echo "unparsed: $reviewer" >&2
  fi
done

if [[ "$n" -eq 0 ]]; then
  printf '{"findings":[]}\n' >"$out"
else
  jq -s -c 'add' "$work"/*.json | jq -c '{findings: .}' >"$out"
fi

exit 0
