#!/usr/bin/env bash
# plant_mutation.sh — plant a synthetic, deterministic mutation inside a
# diff hunk, so reviewer seats (including diff-only ones) can see it, as a
# recall drill for cross-review runs.
#
# Reuses select_roster.sh's seeding approach: awk's srand(seed)/rand() for a
# deterministic weighted-free pick over candidate (file, line, operator)
# sites. Same portability contract: bash 3.2 + jq, no bashisms beyond that.
#
# Candidate sites = every (file, line, operator) where:
#   - the line is an ADDED line in `git -C REPO diff BASE..HEAD` (parsed from
#     `+++ b/<file>` and `@@ ... @@` hunk headers to get head-side line
#     numbers — removed lines never count, context lines never count)
#   - the file's extension is in the operator's `languages`
#   - the operator's `match` (POSIX ERE) matches that line's text
#
# Selection: sort candidates into a stable order (file, then line, then
# operator id) so the same diff always enumerates identically, then draw one
# via the same awk srand(seed)/rand() technique select_roster.sh uses.
# --operator filters the candidate pool to that operator id before drawing
# (with exactly one candidate surviving the filter in the common case, the
# "draw" degenerates to picking it — still goes through the same code path).
#
# Usage:
#   plant_mutation.sh --repo DIR --base REF --head REF --seed N
#                      [--operator ID] [--operators PATH]
#                      [--run-id ID] [--out planted.json] [--dry-run]
#
#   --repo DIR        git repo containing BASE and HEAD (required)
#   --base REF        base ref, the "clean" side of the diff (required)
#   --head REF        head ref, the side whose added lines are candidates
#                      (required)
#   --seed N          deterministic draw seed (required)
#   --operator ID     force this operator id; candidates are filtered to it
#   --operators PATH  operators table (default: references/mutation_operators.json
#                      next to this script)
#   --run-id ID       run id embedded in planted.json (default: mutation-<seed>)
#   --out PATH        where to write planted.json (default: ./planted.json —
#                      NEVER inside the target repo)
#   --dry-run         list candidate sites and exit 0; plants nothing
#
# Exit codes: 0 success (or successful --dry-run); 2 no candidate sites (or
# --operator forced to an id with none); 1 usage/other error.
#
# stdout: on success, the mutated branch name. On --dry-run, one line per
# candidate site.

set -uo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"

repo=""
base=""
head=""
seed=""
operator_filter=""
operators_path="$script_dir/../references/mutation_operators.json"
run_id=""
out=""
dry_run=0

need_val() {
  if [[ "$2" -lt 2 ]]; then
    echo "missing value for $1" >&2
    exit 1
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo)      need_val "$1" "$#"; repo="$2";            shift 2 ;;
    --base)      need_val "$1" "$#"; base="$2";             shift 2 ;;
    --head)      need_val "$1" "$#"; head="$2";             shift 2 ;;
    --seed)      need_val "$1" "$#"; seed="$2";             shift 2 ;;
    --operator)  need_val "$1" "$#"; operator_filter="$2";  shift 2 ;;
    --operators) need_val "$1" "$#"; operators_path="$2";   shift 2 ;;
    --run-id)    need_val "$1" "$#"; run_id="$2";           shift 2 ;;
    --out)       need_val "$1" "$#"; out="$2";              shift 2 ;;
    --dry-run)   dry_run=1;                                  shift ;;
    *) echo "unknown arg: $1" >&2; exit 1 ;;
  esac
done

command -v jq >/dev/null 2>&1 || { echo "plant_mutation: jq required" >&2; exit 1; }
[[ -n "$repo"     ]] || { echo "plant_mutation: --repo required" >&2; exit 1; }
[[ -n "$base"     ]] || { echo "plant_mutation: --base required" >&2; exit 1; }
[[ -n "$head"     ]] || { echo "plant_mutation: --head required" >&2; exit 1; }
[[ -n "$seed"     ]] || { echo "plant_mutation: --seed required" >&2; exit 1; }
[[ -d "$repo"     ]] || { echo "plant_mutation: --repo '$repo' is not a directory" >&2; exit 1; }
[[ -f "$operators_path" ]] || { echo "plant_mutation: operators table not found: $operators_path" >&2; exit 1; }
# --seed feeds awk srand() and jq --argjson: anything but a non-negative
# integer would be silently read as 0 by awk and then break the manifest
# AFTER the mutation was committed (codex, PR #107 review).
[[ "$seed" =~ ^[0-9]+$ ]] || { echo "plant_mutation: --seed must be a non-negative integer (got '$seed')" >&2; exit 1; }

# The operators table is data, but its `replace` strings are executed by
# sed. Accept only a plain single substitution -- `s/<pat>/<repl>/` with an
# optional g flag -- so a tampered table cannot smuggle in a sed command
# (GNU sed's `e` flag runs a shell; kimi, PR #107 review). Duplicate ids
# would make the pick ambiguous (kimi).
if ! jq -e '[.[].id] | length == (unique | length)' "$operators_path" >/dev/null; then
  echo "plant_mutation: duplicate operator ids in $operators_path" >&2; exit 1
fi
while IFS= read -r r; do
  if [[ ! "$r" =~ ^s/[^/]+/[^/]*/g?$ ]]; then
    echo "plant_mutation: operator replace is not a plain s/pat/repl/[g] substitution: $r" >&2; exit 1
  fi
done < <(jq -r '.[].replace' "$operators_path")

[[ -z "$run_id" ]] && run_id="mutation-$seed"
[[ -z "$out"    ]] && out="./planted.json"

repo="$(cd "$repo" && pwd)"

base_sha="$(git -C "$repo" rev-parse "$base" 2>/dev/null)" || { echo "plant_mutation: bad --base ref: $base" >&2; exit 1; }
head_sha="$(git -C "$repo" rev-parse "$head" 2>/dev/null)" || { echo "plant_mutation: bad --head ref: $head" >&2; exit 1; }

# A dirty tree could carry a pre-existing edit at the chosen site straight
# into the "synthetic" commit (codex, PR #107 review). Untracked files are
# fine; tracked modifications are not.
if [[ "$dry_run" -eq 0 && -n "$(git -C "$repo" status --porcelain --untracked-files=no 2>/dev/null)" ]]; then
  echo "plant_mutation: $repo has uncommitted tracked changes; commit or stash them first" >&2
  exit 1
fi

# --- parse the diff into added (file, line_no, text) triples -----------------
# `git diff --unified=0` gives one hunk header per contiguous run of changes
# and only the changed lines, no context — exactly what we need to compute
# head-side line numbers for added lines without hand-rolling hunk math over
# a full-context diff.
diff_raw="$(git -C "$repo" diff --unified=0 --no-color "$base_sha" "$head_sha" -- 2>/dev/null)"

added_tmp="$(mktemp)"
trap 'rm -f "$added_tmp"' EXIT

cur_file=""
while IFS= read -r line; do
  case "$line" in
    "+++ b/"*)
      cur_file="${line#+++ b/}"
      ;;
    "+++ /dev/null")
      cur_file=""
      ;;
    "@@ "*)
      # @@ -a,b +c,d @@  — c is the head-side start line of this hunk.
      hunk_new="$(printf '%s\n' "$line" | sed -E 's/^@@ -[0-9,]+ \+([0-9]+)(,[0-9]+)? @@.*/\1/')"
      next_new_line="$hunk_new"
      ;;
    "+"*)
      if [[ -n "$cur_file" && -n "${next_new_line:-}" ]]; then
        text="${line#+}"
        # Tab-separated: line_no, file, text (text may contain anything but
        # embedded newlines, which git diff output never has per-line).
        printf '%s\t%s\t%s\n' "$next_new_line" "$cur_file" "$text" >>"$added_tmp"
        next_new_line=$((next_new_line + 1))
      fi
      ;;
    "-"*)
      : # removed line — never a candidate, does not advance next_new_line
      ;;
  esac
done <<<"$diff_raw"

if [[ ! -s "$added_tmp" ]]; then
  echo "plant_mutation: no added lines in diff $base_sha..$head_sha" >&2
  exit 2
fi

# --- build the candidate (file, line, operator) list --------------------------
# Stable order: file, then line, then operator id — so the same diff always
# enumerates identically regardless of filesystem/hash-map iteration order.
cand_tmp="$(mktemp)"
trap 'rm -f "$added_tmp" "$cand_tmp"' EXIT

n_ops="$(jq 'length' "$operators_path")"
while IFS=$'\t' read -r line_no file text; do
  [[ -z "$file" ]] && continue
  ext="${file##*.}"
  for ((oi = 0; oi < n_ops; oi++)); do
    op_id="$(jq -r ".[$oi].id" "$operators_path")"
    [[ -n "$operator_filter" && "$op_id" != "$operator_filter" ]] && continue
    langs="$(jq -r ".[$oi].languages | index(\"$ext\")" "$operators_path")"
    [[ "$langs" == "null" ]] && continue
    match_re="$(jq -r ".[$oi].match" "$operators_path")"
    if printf '%s' "$text" | grep -Eq -- "$match_re"; then
      printf '%s\t%s\t%s\n' "$file" "$line_no" "$op_id" >>"$cand_tmp"
    fi
  done
done <"$added_tmp"

sort -t $'\t' -k1,1 -k2,2n -k3,3 -o "$cand_tmp" "$cand_tmp"

n_cand="$(wc -l <"$cand_tmp" | tr -d ' ')"
if [[ "$n_cand" -eq 0 ]]; then
  if [[ -n "$operator_filter" ]]; then
    echo "plant_mutation: no candidate sites for operator '$operator_filter' in diff $base_sha..$head_sha" >&2
  else
    echo "plant_mutation: no candidate sites (no added line matched any operator) in diff $base_sha..$head_sha" >&2
  fi
  exit 2
fi

if [[ "$dry_run" -eq 1 ]]; then
  echo "plant_mutation: $n_cand candidate site(s) for $base_sha..$head_sha:"
  i=0
  while IFS=$'\t' read -r file line_no op_id; do
    i=$((i + 1))
    printf '  [%d] %s:%s  operator=%s\n' "$i" "$file" "$line_no" "$op_id"
  done <"$cand_tmp"
  exit 0
fi

# --- deterministic pick via awk srand(seed)/rand() (same technique as
#     select_roster.sh's draw_picks) -------------------------------------------
# Same contract as the roster draw: deterministic for a given seed on a given
# awk. Different awk implementations (gawk/mawk/BSD) seed differently, so a
# seed reproduces on one machine, not across them -- acceptable for a drill,
# recorded in planted.json via seed + operator + site.
pick_idx="$(awk -v seed="$seed" -v n="$n_cand" 'BEGIN { srand(seed); print int(rand() * n) + 1 }')"
picked_line="$(sed -n "${pick_idx}p" "$cand_tmp")"
IFS=$'\t' read -r p_file p_line p_op <<<"$picked_line"

op_idx="$(jq -r --arg id "$p_op" 'to_entries[] | select(.value.id == $id) | .key' "$operators_path")"
op_match="$(jq -r ".[$op_idx].match" "$operators_path")"
op_replace="$(jq -r ".[$op_idx].replace" "$operators_path")"
op_class="$(jq -r ".[$op_idx].class" "$operators_path")"
op_severity="$(jq -r ".[$op_idx].expected_severity" "$operators_path")"

original_line="$(git -C "$repo" show "${head_sha}:${p_file}" | sed -n "${p_line}p")"

# --- plant on a throwaway branch off HEAD -------------------------------------
mutation_branch="mutation/$run_id"
if git -C "$repo" rev-parse --verify --quiet "refs/heads/$mutation_branch" >/dev/null; then
  echo "plant_mutation: branch '$mutation_branch' already exists in $repo" >&2
  exit 1
fi
git -C "$repo" switch -c "$mutation_branch" "$head_sha" -q || { echo "plant_mutation: failed to create branch $mutation_branch" >&2; exit 1; }

# Undo a half-planted mutation: restore the file first (a dirty tree would
# block the switch), then drop the branch (kimi, PR #107 review).
abort_plant() {
  echo "plant_mutation: $1" >&2
  git -C "$repo" checkout -q -- "$p_file" 2>/dev/null || true
  git -C "$repo" switch - -q 2>/dev/null || true
  git -C "$repo" branch -D "$mutation_branch" -q 2>/dev/null || true
  exit 1
}

sed -E -i.bak "${p_line}${op_replace}" "$repo/$p_file"
rm -f "$repo/${p_file}.bak"

mutated_line="$(sed -n "${p_line}p" "$repo/$p_file")"

diff_stat="$(git -C "$repo" diff HEAD --stat -- 2>/dev/null)"
files_changed="$(git -C "$repo" diff HEAD --name-only -- 2>/dev/null | wc -l | tr -d ' ')"
lines_changed="$(git -C "$repo" diff HEAD -U0 -- "$p_file" 2>/dev/null | grep -Ec '^[+-][^+-]')"
if [[ "$files_changed" -ne 1 || "$lines_changed" -ne 2 ]]; then
  echo "$diff_stat" >&2
  abort_plant "mutation did not produce exactly one changed line in one file (files_changed=$files_changed, diff_lines=$lines_changed)"
fi

# --no-verify: a pre-commit hook could reformat the file and break the
# one-line invariant (kimi); commit failures roll back instead of reporting
# the original head as the mutation (codex).
git -C "$repo" add -- "$p_file" || abort_plant "git add failed"
git -C "$repo" commit -q --no-verify -m "chore(mutation): synthetic planted defect (do not merge)" || abort_plant "git commit failed"
mutation_sha="$(git -C "$repo" rev-parse HEAD)"
[[ "$mutation_sha" != "$head_sha" ]] || abort_plant "commit did not advance HEAD"

out_dir="$(dirname "$out")"
mkdir -p "$out_dir"
jq -n \
  --arg run_id "$run_id" \
  --arg operator "$p_op" \
  --arg class "$op_class" \
  --arg file "$p_file" \
  --argjson line "$p_line" \
  --arg severity "$op_severity" \
  --argjson seed "$seed" \
  --arg base "$base_sha" \
  --arg head "$head_sha" \
  --arg mutation_branch "$mutation_branch" \
  --arg mutation_sha "$mutation_sha" \
  --arg original_line "$original_line" \
  --arg mutated_line "$mutated_line" \
  '{
    schema_version: 1,
    synthetic: true,
    run_id: $run_id,
    operator: $operator,
    class: $class,
    file: $file,
    line_range: [$line, $line],
    expected_severity: $severity,
    seed: $seed,
    base: $base,
    head: $head,
    mutation_branch: $mutation_branch,
    mutation_sha: $mutation_sha,
    original_line: $original_line,
    mutated_line: $mutated_line
  }' >"$out"

echo "$mutation_branch"
