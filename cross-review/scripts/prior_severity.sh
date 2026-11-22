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
#   findings.verified.json — factcheck_findings.sh output (step 4.5) and
#   findings.scored.json     the scoring pass are siblings: when both exist, a
#                           finding counts only if it survives both (matched
#                           on the findings.json id; the lower of the two
#                           maxima when ids are missing).
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
# First parseable copy of a JSON source across both directories, as a rank.
first_rank() {
  local d r
  for d in "$dir" "$parent"; do
    [[ -f "$d/$1" ]] || continue
    r="$(json_max "$d/$1")"
    [[ "$r" =~ ^[0-4]$ ]] && { echo "$r"; return; }
  done
}
# The fact-check and the scoring pass both start from findings.json, so each
# can drop a finding the other kept. When both exist a finding must survive
# both to count. Match them on the findings.json id (verified carries it as
# `local_id`, scored as `id`) and count only findings kept by both files.
# Findings without a matchable id fall back to the lower of the two maxima.
# (codex, cross-review of claude-skills PR #228, passes 2 and 3.)
first_file() {
  local d
  for d in "$dir" "$parent"; do
    [[ -f "$d/$1" && -n "$(json_max "$d/$1")" ]] && { echo "$d/$1"; return; }
  done
}
rv="$(first_rank findings.verified.json)"
rs="$(first_rank findings.scored.json)"
if [[ -n "$rv" && -n "$rs" ]]; then
  r="$(jq -rs '
    def rank: (tostring | ascii_downcase) as $s
      | if $s == "critical" then 4 elif $s == "high" then 3
        elif $s == "medium" then 2 elif $s == "low" then 1 else 0 end;
    def dropped: (.disposition // "") == "drop" or (.factcheck.verdict // "") == "drop";
    (.[0].findings | map(. + {k: (.local_id // .id)})) as $v
    | (.[1].findings | map(. + {k: .id})) as $s
    | if ([$v[], $s[]] | any(.k == null)) then empty else
      ($s | map(select(dropped | not) | .k)) as $ks
      # Intersection: a finding counts only if BOTH files kept it. One absent
      # from either file did not survive that check. Its rank is the lower of
      # the two severities.
      | [ $v[] | select((dropped | not) and (.k as $k | $ks | index($k)) != null)
          | . as $f | ($s | map(select(.k == $f.k and (dropped | not))) | first) as $m
          | [($f.severity // "" | rank), ($m.severity // "" | rank)] | min ]
      | (max // 0) end' \
    "$(first_file findings.verified.json)" "$(first_file findings.scored.json)" 2>/dev/null)"
  [[ "$r" =~ ^[0-4]$ ]] || r=$(( rv < rs ? rv : rs ))
  rank_to_word "$r"; exit 0
fi
if [[ -n "$rv$rs" ]]; then rank_to_word "$rv$rs"; exit 0; fi
rj="$(first_rank findings.json)"
if [[ -n "$rj" ]]; then rank_to_word "$rj"; exit 0; fi
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
