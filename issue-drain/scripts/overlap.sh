#!/bin/bash
# overlap.sh — propose which issues overlap, from the checked verdicts.
#
# Usage: overlap.sh [--in <verdicts.checked.json>] [--out <overlap.json>]
# Env: ISSUE_DRAIN_WORKDIR (absolute), ISSUE_DRAIN_REPO or ISSUE_DRAIN_PROFILE
# Reads one local file, writes one local file. Exit 0, or 2 on bad input.
#
# It proposes; the session decides. Three relations between two issues that
# are both still to be worked (status live or duplicate_of):
#   duplicate          one names the other as its duplicate
#   cluster_candidate  they share a file AND a symbol, or both are mechanical
#                      changes with the same named pattern
#   adjacent           they share a file and nothing else
# Sharing a file is not a reason to share a PR. Small single-purpose PRs review
# and revert cleanly, so "adjacent" only means "run these one after the other".
# Two rules a proposal never breaks:
#   - an issue on a risk path (crisis, billing, ...) is not offered for a
#     cluster. Only its own duplicates ride with it;
#   - an issue sized XL, or with no size, is not offered for a cluster.
# Groups are the connected components over duplicate and cluster edges, so a
# group can be a chain (A with B, B with C). over_cap and over_lines say when
# a group is past CLUSTER_MAX_ISSUES or CLUSTER_MAX_LINES; the line estimate
# is S=50, M=150, L=400 per live issue (a duplicate adds none).
set -euo pipefail
. "$(dirname "$0")/lib.sh"
need_workdir
load_profile

in="$WORKDIR/verdicts.checked.json"
out="$WORKDIR/overlap.json"
while [ $# -gt 0 ]; do
  case "$1" in
    --in) in="${2:-}"; shift 2 ;;
    --out) out="${2:-}"; shift 2 ;;
    *) die "unknown argument $1" 2 ;;
  esac
done
jq -e 'type == "array"' "$in" >/dev/null 2>&1 || die "no checked verdicts at $in; run evidence-check.sh first" 2

# shellcheck disable=SC2016
jq --argjson max_issues "$CLUSTER_MAX_ISSUES" --argjson max_lines "$CLUSTER_MAX_LINES" '
  def lines: {"S": 50, "M": 150, "L": 400}[(. // "") | tostring];
  def both($a; $b): $a - ($a - $b);
  def strs: [ (. // [])[] | select(type == "string" and . != "") ] | unique;
  def dup($a; $b): $a.status == "duplicate_of" and $a.duplicate_of == $b.number;

  [ .[] | select(.status == "live" or .status == "duplicate_of") ] as $c
  | [ range(0; $c | length) as $i | range($i + 1; $c | length) as $j
      | $c[$i] as $a | $c[$j] as $b
      | both($a.files | strs; $b.files | strs) as $files
      | both($a.symbols | strs; $b.symbols | strs) as $syms
      | ( $a.change_kind == "mechanical" and $b.change_kind == "mechanical"
          and (($a.pattern // "") != "") and $a.pattern == $b.pattern ) as $same_pattern
      | ( if dup($a; $b) or dup($b; $a) then [ "duplicate", null ]
          elif (($files | length) > 0 and ($syms | length) > 0) or $same_pattern then
            ( if $a.risk or $b.risk then [ "adjacent", "on a risk path, so not offered for a cluster" ]
              elif (($a.size | lines) == null) or (($b.size | lines) == null) then [ "adjacent", "sized XL or unsized, so not offered for a cluster" ]
              else [ "cluster_candidate", (if $same_pattern then "same mechanical pattern: \($a.pattern)" else null end) ] end )
          elif ($files | length) > 0 then [ "adjacent", null ]
          else null end ) as $rel
      | select($rel != null)
      | { a: $a.number, b: $b.number, relation: $rel[0], shared_files: $files, shared_symbols: $syms, note: $rel[1] } ] as $pairs
  | [ $pairs[] | select(.relation != "adjacent") ] as $edges
  # Label propagation: every node starts as its own group and takes the lower
  # label across each edge. N passes are enough for any chain of N nodes.
  | ( reduce range(0; $c | length) as $pass (
        ( $c | map({ key: (.number | tostring), value: .number }) | from_entries );
        reduce $edges[] as $e ( .;
          ( [ .[$e.a | tostring], .[$e.b | tostring] ] | min ) as $m
          | .[$e.a | tostring] = $m | .[$e.b | tostring] = $m ) )
      | to_entries | group_by(.value) | map(map(.key | tonumber) | sort) ) as $comps
  | ( $c | map({ key: (.number | tostring), value: . }) | from_entries ) as $by
  | { pairs: $pairs,
      groups: [ $comps[] | select(length > 1) | . as $g
                | [ $g[] | $by[tostring] ] as $m
                | ( [ $m[] | select(.status == "live") | (.size | lines) // 0 ] | add // 0 ) as $est
                | { issues: $g,
                    live: [ $m[] | select(.status == "live") | .number ],
                    files: ( [ $m[] | .files | strs | .[] ] | unique ),
                    est_lines: $est,
                    over_cap: (($g | length) > $max_issues),
                    over_lines: ($est > $max_lines),
                    risk: ( [ $m[] | .risk ] | any ) } ],
      singles: [ $comps[] | select(length == 1) | .[0] ] }' "$in" > "$out.tmp"
mv "$out.tmp" "$out"

summary="$(jq -c '{pairs: (.pairs | length), groups: (.groups | length), singles: (.singles | length)}' "$out")"
log_event overlap "$summary"
echo "overlap: $summary -> $out"
jq -r '.groups[] | "  group \(.issues | map("#\(.)") | join(" ")): ~\(.est_lines) lines\(if .over_cap then ", over the issue cap" else "" end)\(if .over_lines then ", over the line cap" else "" end)\(if .risk then ", has a risk-path issue" else "" end)"' "$out"
jq -r '.pairs[] | select(.relation == "adjacent") | "  adjacent #\(.a) #\(.b): \(.shared_files | join(", "))\(if .note then " (\(.note))" else "" end)"' "$out"
