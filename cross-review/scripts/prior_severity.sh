#!/usr/bin/env bash
# prior_severity.sh — the worst severity the PREVIOUS cross-review pass found,
# read from that pass's run dir. The codex effort ladder escalates on it.
#
# Usage: prior_severity.sh <dir>
#   <dir> is the `--out` the previous run_reviewers.sh call wrote to. The
#   synthesized files usually sit one level up (run_dir/raw -> run_dir), so both
#   <dir> and its parent are searched.
#
# Prints exactly one of: critical | high | medium | low | none | unknown
#
# Sources, most trusted first; the first one that exists (in either directory)
# decides. Source rank beats directory: a scored file in the parent wins over a
# raw findings.json in <dir>.
#   findings.verified.json — factcheck_findings.sh output (step 4.5); same drop
#                           rules as the scored file.
#   findings.scored.json  — score_findings.sh output; findings with
#                           disposition "drop" or factcheck verdict "drop" do
#                           not count (they were judged not real).
#   findings.json         — the synthesized set (curl lanes + hand-extracted).
#   findings.md           — the step-4 report: a "## Critical" or "## High"
#                           section holding at least one "- " bullet that is
#                           not struck through (~~...~~ marks a vetoed finding).
# A JSON file without a "findings" array ({} or a placeholder) is not evidence
# of a clean pass; the lookup moves on to the next source.
#   findings.premerged.json — curl lanes only, so it misses codex and the agy
#                           laps. It counts as POSITIVE evidence only: a
#                           Critical/High there is real, an absence is "unknown".
#
# "unknown" means no evidence either way. The ladder treats it as "do not
# escalate" — the owner's configured level stands — so a missing file can only
# cost a deeper look, never spend more.
#
# Exit: always 0 (it is advisory input to a cost decision, never a gate).
set -uo pipefail

dir="${1:-}"
[[ -n "$dir" && -d "$dir" ]] || { echo unknown; exit 0; }
command -v jq >/dev/null 2>&1 || { echo unknown; exit 0; }

rank_to_word() {
  case "$1" in 4) echo critical ;; 3) echo high ;; 2) echo medium ;; 1) echo low ;; *) echo none ;; esac
}

# max severity rank over the kept findings of a findings JSON file; empty on
# parse failure or when there is no findings array.
json_max() {
  jq -r '
    if (.findings | type) != "array" then empty else
    def rank: (ascii_downcase) as $s
      | if $s == "critical" then 4 elif $s == "high" then 3
        elif $s == "medium" then 2 elif $s == "low" then 1 else 0 end;
    [ (.findings // [])[]
      | select((.disposition // "") != "drop")
      | select((.factcheck.verdict // "") != "drop")
      | ((.severity // "") | tostring | rank) ]
    | (max // 0) end' "$1" 2>/dev/null
}

md_max() {
  awk '
    /^##[[:space:]]+/ { s = tolower($0); sec = 0
      if (s ~ /^##[[:space:]]+critical/) sec = 4
      else if (s ~ /^##[[:space:]]+high/) sec = 3
      else if (s ~ /^##[[:space:]]+medium/) sec = 2
      else if (s ~ /^##[[:space:]]+low/) sec = 1
      next }
    sec > 0 && /^[[:space:]]*[-*][[:space:]]+[^[:space:]]/ {
      if (tolower($0) !~ /^[[:space:]]*[-*][[:space:]]+(none|_none|n\/a|~~)/ && sec > m) m = sec }
    END { print m + 0 }' "$1" 2>/dev/null
}

parent="$(dirname "$dir")"
for f in findings.verified.json findings.scored.json findings.json; do
  for d in "$dir" "$parent"; do
    if [[ -f "$d/$f" ]]; then
      r="$(json_max "$d/$f")"
      if [[ "$r" =~ ^[0-4]$ ]]; then rank_to_word "$r"; exit 0; fi
    fi
  done
done
for d in "$dir" "$parent"; do
  if [[ -f "$d/findings.md" ]]; then
    rank_to_word "$(md_max "$d/findings.md")"; exit 0
  fi
done

for d in "$dir" "$(dirname "$dir")"; do
  if [[ -f "$d/findings.premerged.json" ]]; then
    r="$(json_max "$d/findings.premerged.json")"
    if [[ "$r" =~ ^[34]$ ]]; then rank_to_word "$r"; exit 0; fi
  fi
done

echo unknown
