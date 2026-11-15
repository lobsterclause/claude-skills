#!/usr/bin/env bash
# plan_rounds.sh — split a huge change into focused cross-review rounds.
#
# Reads the three-dot diff (--base...--ref), groups the changed files by
# directory, packs the groups into balanced rounds that each stay under a line
# budget, and prints the `--paths` set to give each round. Replaces the old
# workaround of hand-building a synthetic base commit and a synthetic ref.
#
# usage:
#   plan_rounds.sh --base <b> --ref <r> [--max-lines 3000] [--group-by dir|top]
#                  [--format both|json|table]
#
#   --max-lines N   line budget per round (insertions + deletions, the same
#                   number worktree.sh reports as size_lines). Default 3000.
#   --group-by top  one group per top-level directory (root-level files are
#                   one group each); a group over budget stays one oversize
#                   round, flagged over_budget.
#   --group-by dir  (default) start from top-level directories and keep
#                   splitting a group over budget by its next path component,
#                   down to single files, so a monorepo's `packages/` does not
#                   become one round.
#   --format        both (default): a human table on stderr and the JSON on
#                   stdout; json: JSON only; table: the table on stdout.
#
# OFFLINE and DETERMINISTIC: git plumbing + jq only; the same diff always
# yields the same rounds (units sorted by size then path, ties broken by path,
# assignment to the least-loaded round with the lowest index). No network.
#
# Each round's `flags` string is ready to paste into worktree.sh start /
# run_reviewers.sh. A pathspec containing a comma cannot ride in one --paths
# value: use the round's `path_flags` (repeated --path) instead -- `flags`
# already falls back to that form when it must. File names containing a tab or
# newline are not supported.
#
# Exit: 0 ok · 1 empty diff · 2 usage · 3 base is a descendant of ref (the
# three-dot diff would be empty: the "synthetic base" trap).

set -uo pipefail

base=""; ref=""; max_lines=3000; group_by="dir"; format="both"
need_val() { [[ "$2" -ge 2 ]] || { echo "$1 requires a value" >&2; exit 2; }; }
while [[ $# -gt 0 ]]; do
  case "$1" in
    --base)      need_val "$1" "$#"; base="$2";      shift 2 ;;
    --ref)       need_val "$1" "$#"; ref="$2";       shift 2 ;;
    --max-lines) need_val "$1" "$#"; max_lines="$2"; shift 2 ;;
    --group-by)  need_val "$1" "$#"; group_by="$2";  shift 2 ;;
    --format)    need_val "$1" "$#"; format="$2";    shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done
if [[ -z "$base" || -z "$ref" ]]; then
  echo "usage: $0 --base <b> --ref <r> [--max-lines 3000] [--group-by dir|top] [--format both|json|table]" >&2
  exit 2
fi
case "$max_lines" in ''|*[!0-9]*|0) echo "--max-lines must be a positive integer (got '$max_lines')" >&2; exit 2 ;; esac
case "$group_by" in dir|top) ;; *) echo "--group-by must be dir or top (got '$group_by')" >&2; exit 2 ;; esac
case "$format" in both|json|table) ;; *) echo "--format must be both, json or table (got '$format')" >&2; exit 2 ;; esac
command -v jq >/dev/null 2>&1 || { echo "plan_rounds: jq required" >&2; exit 1; }

base_sha="$(git rev-parse --verify --quiet "$base^{commit}")" || { echo "invalid or unknown base ref: $base" >&2; exit 2; }
ref_sha="$(git rev-parse --verify --quiet "$ref^{commit}")"   || { echo "invalid or unknown ref: $ref" >&2; exit 2; }

# The descendant-base trap (same check as worktree.sh start): a base that
# descends from the ref makes the three-dot diff empty.
if ! git merge-base --is-ancestor "$base_sha" "$ref_sha" 2>/dev/null; then
  mb="$(git merge-base "$base_sha" "$ref_sha" 2>/dev/null || true)"
  if [[ -z "$mb" || "$mb" == "$ref_sha" ]]; then
    echo "ERROR: --base ($base) is a descendant of (or unrelated to) --ref ($ref): the three-dot diff is empty. Pass a --base that is an ancestor of --ref." >&2
    exit 3
  fi
fi

# numstat, rename-free so every path is a plain path. Binary files report
# "-\t-" and count as zero lines (but still as a file).
numstat="$(git -c core.quotePath=false diff --no-renames --numstat "$base_sha"..."$ref_sha" 2>/dev/null)"
if [[ -z "$numstat" ]]; then
  echo "plan_rounds: no diff between $base and $ref" >&2
  exit 1
fi

plan="$(printf '%s\n' "$numstat" | jq -R -s -c \
  --argjson max "$max_lines" --arg mode "$group_by" \
  --arg base "$base" --arg ref "$ref" --arg bsha "$base_sha" --arg hsha "$ref_sha" '
  def lit($p): if ($p | test("[*?\\[\\\\]")) then ":(literal)" + $p else $p end;
  # files: [{path, lines, parts}]
  (split("\n") | map(select(length > 0) | split("\t")
      | select(length >= 3)
      | {path: (.[2:] | join("\t")),
         lines: ((if .[0] == "-" then 0 else (.[0] | tonumber) end)
               + (if .[1] == "-" then 0 else (.[1] | tonumber) end))}
      | . + {parts: (.path | split("/"))})) as $files
  # units(files; depth) -> [{spec, lines, files}]
  | def units($fs; $d):
      ($fs | map(select((.parts | length) == $d + 1))
           | map({spec: lit(.path), lines: .lines, files: 1})) as $leaf
      | ($fs | map(select((.parts | length) > $d + 1)) | group_by(.parts[$d])
           | map(
               . as $g
               | ($g | map(.lines) | add) as $total
               | ($g[0].parts[0:$d+1] | join("/")) as $prefix
               | if $mode == "dir" and $total > $max
                 then units($g; $d + 1)
                 else [{spec: lit($prefix + "/"), lines: $total, files: ($g | length)}]
                 end)
           | add // []) as $dirs
      | $leaf + $dirs;
    (units($files; 0) | sort_by([-.lines, .spec])) as $units
  | ($units | map(.lines) | add // 0) as $total
  | ([1, (($total + $max - 1) / $max | floor)] | max) as $k
  # LPT packing into k rounds; open a new round when nothing has room.
  | (reduce $units[] as $u ({rounds: [range(0; $k) | {lines: 0, files: 0, specs: []}]};
      ( [.rounds | to_entries[] | select(.value.lines + $u.lines <= $max)]
        | sort_by([.value.lines, .key]) | .[0].key ) as $i
      | if $i == null
        then .rounds += [{lines: $u.lines, files: $u.files, specs: [$u.spec]}]
        else .rounds[$i] |= (.lines += $u.lines | .files += $u.files | .specs += [$u.spec])
        end)
    | .rounds
    | map(select(.specs | length > 0))
    | map(.specs |= sort)
    | sort_by([.specs[0]])
    | to_entries
    | map(.value + {round: (.key + 1)})) as $rounds
  | {
      base: $base, ref: $ref, base_sha: $bsha, head_sha: $hsha,
      max_lines: $max, group_by: $mode,
      total_files: ($files | length), total_lines: ($files | map(.lines) | add // 0),
      rounds: ($rounds | map({
        round: .round, lines: .lines, files: .files,
        over_budget: (.lines > $max),
        paths: .specs,
        paths_arg: (.specs | join(",")),
        path_flags: (.specs | map("--path " + @sh) | join(" ")),
        flags: (if (.specs | any(contains(","))) then (.specs | map("--path " + @sh) | join(" "))
                else ("--paths " + (.specs | join(",") | @sh)) end)
      }))
    }')" || { echo "plan_rounds: failed to build the plan" >&2; exit 1; }

table() {
  printf 'plan_rounds: %s..%s  %s files, %s lines, budget %s/round, group-by %s -> %s round(s)\n' \
    "$base" "$ref" "$(jq -r .total_files <<<"$plan")" "$(jq -r .total_lines <<<"$plan")" \
    "$max_lines" "$group_by" "$(jq -r '.rounds | length' <<<"$plan")"
  jq -r '.rounds[] | "round \(.round)\t\(.files) files\t\(.lines) lines\(if .over_budget then " (OVER BUDGET: one unsplittable unit)" else "" end)\n    \(.flags)"' <<<"$plan"
}

case "$format" in
  json)  printf '%s\n' "$plan" ;;
  table) table ;;
  both)  table >&2; printf '%s\n' "$plan" ;;
esac
