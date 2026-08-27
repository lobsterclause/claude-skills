#!/usr/bin/env bash
# planted_round.sh — run one end-to-end planted-mutation recall drill against
# a target repo: pick a fixture file, manufacture a tiny synthetic diff on
# it, plant a mutation (plant_mutation.sh), run the given roster against the
# resulting diff, grade the catch (grade_planted.sh --emit-events), record a
# synthetic runlog row (append_runlog.sh --synthetic), then revert every
# change so the repo is exactly as it started (#116).
#
# WHY a synthetic diff first: plant_mutation.sh needs an ADDED line in an
# actual base..head diff to mutate — there is no live PR to plant into on a
# scheduled drill, so this script makes one: it re-touches a single line of
# the chosen fixture file on a throwaway commit, then plants the mutation on
# top of THAT commit. The reviewers then see (synthetic touch + planted
# mutation) as one diff, same shape as a real round.
#
# Usage:
#   planted_round.sh --repo-root <dir> --operators-file <path>
#                     --fixture <path|auto> --roster a,b,c --out <dir>
#                     [--seed <n>] [--run-id <id>] [--window <n>]
#
#   --repo-root DIR      target repo to drill against (must be clean —
#                        `git status --porcelain` empty at the start)
#   --operators-file PATH  mutation_operators.json table (passed through to
#                        plant_mutation.sh)
#   --fixture PATH|auto  the file to touch for the synthetic diff. "auto":
#                        `evals/evals.json` under --repo-root if present,
#                        else the newest file under cross-review/scripts/
#                        (mtime order) containing >=1 line that matches an
#                        operator's `match` regex for its own extension —
#                        the same match test plant_mutation.sh applies to
#                        candidate sites.
#   --roster a,b,c       every seat to run this round (required)
#   --out DIR            where run artifacts land (raw/, findings*.json,
#                        grade.json) — required, created if missing
#   --seed N             deterministic draw seed for plant_mutation.sh
#                        (default: ISO week number, `date -u +%G%V` — a
#                        given calendar week always reproduces the same
#                        plant)
#   --run-id ID          default: ci-planted-<seed>
#   --window N           grade_planted.sh --window (default 3)
#
# Exit: 0 on a successful drill (a caught OR a missed defect is still a
# successful drill); non-zero on setup failure, no candidate fixture/site,
# or a dirty tree at the end.
#
# Cleanup is unconditional (trap on EXIT): the synthetic touch commit and
# the mutation commit are both reverted and their throwaway branches
# deleted, and the repo is switched back to whatever ref it started on. A
# failure partway through still leaves --repo-root exactly as it was.

set -uo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
skill_dir="$(cd "$script_dir/.." && pwd)"
scripts_dir="$skill_dir/scripts"

repo_root="" ; operators_file="" ; fixture="auto" ; roster="" ; out=""
seed="" ; run_id="" ; window=3

need_val() { [[ "$2" -lt 2 ]] && { echo "missing value for $1" >&2; exit 2; }; }
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo-root)      need_val "$1" "$#"; repo_root="$2";      shift 2 ;;
    --operators-file) need_val "$1" "$#"; operators_file="$2"; shift 2 ;;
    --fixture)        need_val "$1" "$#"; fixture="$2";        shift 2 ;;
    --roster)         need_val "$1" "$#"; roster="$2";         shift 2 ;;
    --out)            need_val "$1" "$#"; out="$2";            shift 2 ;;
    --seed)           need_val "$1" "$#"; seed="$2";           shift 2 ;;
    --run-id)         need_val "$1" "$#"; run_id="$2";         shift 2 ;;
    --window)         need_val "$1" "$#"; window="$2";         shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

usage="usage: $0 --repo-root <dir> --operators-file <path> --fixture <path|auto> --roster a,b,c --out <dir> [--seed <n>] [--run-id <id>] [--window <n>]"
[[ -n "$repo_root" && -n "$operators_file" && -n "$roster" && -n "$out" ]] || { echo "$usage" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "planted_round: jq required" >&2; exit 1; }
[[ -d "$repo_root" ]] || { echo "planted_round: --repo-root '$repo_root' is not a directory" >&2; exit 1; }
[[ -f "$operators_file" ]] || { echo "planted_round: operators file not found: $operators_file" >&2; exit 1; }
repo_root="$(cd "$repo_root" && pwd)"

if [[ -n "$(git -C "$repo_root" status --porcelain 2>/dev/null)" ]]; then
  echo "planted_round: $repo_root is not clean at start; refusing to drill" >&2
  exit 1
fi

[[ -z "$seed" ]] && seed="$(date -u +%G%V | sed 's/^0*//')"
[[ -n "$seed" ]] || seed=0
[[ -z "$run_id" ]] && run_id="ci-planted-$seed"

mkdir -p "$out" || { echo "planted_round: cannot create --out $out" >&2; exit 1; }
# Absolute: several steps below run inside `( cd "$repo_root" && ... )`
# subshells, where a relative --out would resolve against the target repo
# instead of the caller's cwd (cross-review of #143).
out="$(cd "$out" && pwd)"
run_dir="$out/run"

# The throwaway commits (the synthetic touch here, the mutation in
# plant_mutation.sh) need an author. A pristine CI runner has none configured
# and `git commit` would die with "Please tell me who you are"; supply one
# via the environment ONLY when the repo has no identity of its own, so a
# developer's local config is untouched (cross-review of #143).
if [[ -z "$(git -C "$repo_root" config user.email 2>/dev/null)" ]]; then
  export GIT_AUTHOR_NAME="${GIT_AUTHOR_NAME:-planted-round}"
  export GIT_AUTHOR_EMAIL="${GIT_AUTHOR_EMAIL:-planted-round@localhost}"
  export GIT_COMMITTER_NAME="${GIT_COMMITTER_NAME:-planted-round}"
  export GIT_COMMITTER_EMAIL="${GIT_COMMITTER_EMAIL:-planted-round@localhost}"
fi
mkdir -p "$run_dir/raw"

orig_ref="$(git -C "$repo_root" symbolic-ref --short -q HEAD || git -C "$repo_root" rev-parse HEAD)"
touch_branch="planted-round-tmp/$run_id"
mutation_branch="mutation/$run_id"
cleanup_done=0
cleanup() {
  [[ "$cleanup_done" -eq 1 ]] && return
  cleanup_done=1
  git -C "$repo_root" reset -q --hard HEAD >/dev/null 2>&1 || true
  git -C "$repo_root" switch -q "$orig_ref" >/dev/null 2>&1 \
    || git -C "$repo_root" switch -q --detach "$orig_ref" >/dev/null 2>&1 || true
  git -C "$repo_root" branch -D "$mutation_branch" -q >/dev/null 2>&1 || true
  git -C "$repo_root" branch -D "$touch_branch" -q >/dev/null 2>&1 || true
}
trap cleanup EXIT

# ── fixture selection ────────────────────────────────────────────────────
pick_fixture() {
  if [[ "$fixture" != "auto" ]]; then
    [[ -f "$repo_root/$fixture" || -f "$fixture" ]] || { echo "planted_round: --fixture '$fixture' not found" >&2; return 1; }
    if [[ -f "$repo_root/$fixture" ]]; then printf '%s' "$fixture"; else
      printf '%s' "${fixture#$repo_root/}"
    fi
    return 0
  fi
  # auto: the newest TRACKED file anywhere under --repo-root whose extension
  # has at least one operator and which contains a line matching one of
  # them — the same match test plant_mutation.sh applies to candidate sites.
  # (An earlier draft looked at evals/evals.json and cross-review/scripts/:
  # .json and .sh have no operators, so auto could never succeed — flagged
  # by cross-review of #143.) Falls back to the committed drill target
  # cross-review/ci/fixtures/planted_target.ts for repos, like this one, with
  # no tracked TypeScript/JavaScript of their own.
  local n_ops
  n_ops="$(jq 'length' "$operators_file")"
  local ext_re
  ext_re="$(jq -r '[.[].languages[]] | unique | join("|")' "$operators_file")"
  [[ -n "$ext_re" ]] || { echo "planted_round: operators file lists no languages" >&2; return 1; }
  local candidates
  candidates="$(git -C "$repo_root" ls-files -z 2>/dev/null \
    | tr '\0' '\n' | grep -E "\.(${ext_re})$" | grep -vE '(^|/)(node_modules|dist|build|vendor)/' \
    | grep -vE '\.d\.ts$|/fixtures/planted_target\.' || true)"
  local f
  while IFS= read -r f; do
    [[ -n "$f" && -f "$repo_root/$f" ]] || continue
    if fixture_line_for "$repo_root/$f" "${f##*.}" >/dev/null; then
      printf '%s' "$f"
      return 0
    fi
  done < <(printf '%s\n' "$candidates" | while IFS= read -r c; do [[ -n "$c" ]] && printf '%s\t%s\n' "$(stat -f %m "$repo_root/$c" 2>/dev/null || stat -c %Y "$repo_root/$c" 2>/dev/null || echo 0)" "$c"; done | sort -rn | cut -f2-)
  local fallback="cross-review/ci/fixtures/planted_target.ts"
  if [[ -f "$repo_root/$fallback" ]] && fixture_line_for "$repo_root/$fallback" ts >/dev/null; then
    printf '%s' "$fallback"
    return 0
  fi
  echo "planted_round: no tracked file under $repo_root has an applicable operator (and no $fallback)" >&2
  return 1
}

# fixture_line_for <path> <ext> — prints the first line number in <path>
# matching any operator defined for <ext>; returns 1 if none.
fixture_line_for() {
  local path="$1" fext="$2" n_ops oi langs match_re ln
  n_ops="$(jq 'length' "$operators_file")"
  for ((oi = 0; oi < n_ops; oi++)); do
    langs="$(jq -r ".[$oi].languages | index(\"$fext\")" "$operators_file")"
    [[ "$langs" == "null" ]] && continue
    match_re="$(jq -r ".[$oi].match" "$operators_file")"
    ln="$(grep -nE -- "$match_re" "$path" 2>/dev/null | head -n 1 | cut -d: -f1)"
    if [[ -n "$ln" ]]; then printf '%s' "$ln"; return 0; fi
  done
  return 1
}

fixture_rel="$(pick_fixture)" || exit 2
fixture_path="$repo_root/$fixture_rel"
[[ -f "$fixture_path" ]] || { echo "planted_round: resolved fixture '$fixture_rel' does not exist" >&2; exit 2; }

# ── synthetic touch: re-affirm an operator-matching line as an ADDED line
#    on a throwaway commit, so plant_mutation.sh has a diff to work with ──
ext="${fixture_rel##*.}"
touch_line_no="$(fixture_line_for "$fixture_path" "$ext")" || touch_line_no=""
if [[ -z "$touch_line_no" ]]; then
  echo "planted_round: fixture '$fixture_rel' has no line matching any operator for its extension" >&2
  exit 2
fi

git -C "$repo_root" switch -c "$touch_branch" -q "$orig_ref" || { echo "planted_round: failed to create $touch_branch" >&2; exit 1; }
# Append one trailing space to the matched line: git records it as a
# removed+added pair, so it appears as an ADDED line to plant_mutation.sh's
# diff parser while the operator match on the line is preserved. (A prior
# awk -v rewrite of the line to itself was both a no-op for git and unsafe —
# awk -v interprets backslash escapes inside the line text; cross-review of
# #143.)
sed -i.bak -e "${touch_line_no}s/\$/ /" "$fixture_path"
rm -f "$fixture_path.bak"
git -C "$repo_root" add -- "$fixture_rel" || { echo "planted_round: git add failed" >&2; exit 1; }
if git -C "$repo_root" diff --cached --quiet -- "$fixture_rel"; then
  echo "planted_round: synthetic touch produced no diff on $fixture_rel" >&2
  exit 2
fi
git -C "$repo_root" commit -q --no-verify -m "chore(planted-round): synthetic touch for mutation drill (do not merge)" \
  || { echo "planted_round: synthetic touch commit failed" >&2; exit 1; }
touch_sha="$(git -C "$repo_root" rev-parse HEAD)"

base_sha="$orig_ref"
[[ "$base_sha" == "$orig_ref" ]] && base_sha="$(git -C "$repo_root" rev-parse "$orig_ref")"

# ── plant the mutation on top of the synthetic touch ────────────────────
planted_json="$out/planted.json"
mutation_out="$(bash "$scripts_dir/plant_mutation.sh" --repo "$repo_root" \
  --base "$base_sha" --head "$touch_sha" --seed "$seed" \
  --operators "$operators_file" --run-id "$run_id" --out "$planted_json")" \
  || { echo "planted_round: plant_mutation.sh failed" >&2; exit 1; }
echo "planted_round: mutation branch $mutation_out" >&2

# ── run the roster against base_sha..HEAD (the mutation branch) ─────────
timeout_s="${CROSS_REVIEW_PLANTED_TIMEOUT_S:-120}"
( cd "$repo_root" && bash "$scripts_dir/run_reviewers.sh" \
    --base "$base_sha" --out "$run_dir/raw" --reviewers "$roster" --timeout "$timeout_s" ) \
  || { echo "planted_round: run_reviewers.sh failed" >&2; exit 1; }

# ── merge / fingerprint / anchor ─────────────────────────────────────────
bash "$scripts_dir/merge_raw_findings.sh" --raw "$run_dir/raw" --out "$run_dir/findings.raw.json" \
  || { echo "planted_round: merge_raw_findings.sh failed" >&2; exit 1; }
bash "$scripts_dir/fingerprint_findings.sh" --findings "$run_dir/findings.raw.json" \
  --out "$run_dir/findings.fp.json" --repo-root "$repo_root" \
  || { echo "planted_round: fingerprint_findings.sh failed" >&2; exit 1; }
( cd "$repo_root" && bash "$scripts_dir/anchor_findings.sh" \
    --findings "$run_dir/findings.fp.json" --out "$run_dir/findings.anchored.json" \
    --base "$base_sha" --repo "$repo_root" ) \
  || { echo "planted_round: anchor_findings.sh failed" >&2; exit 1; }

# ── grade the catch ───────────────────────────────────────────────────────
grade_json="$out/grade.json"
bash "$scripts_dir/grade_planted.sh" --planted "$planted_json" \
  --findings "$run_dir/findings.anchored.json" --roster "$roster" \
  --run-id "$run_id" --repo-root "$repo_root" --window "$window" \
  --out "$grade_json" --emit-events \
  || { echo "planted_round: grade_planted.sh failed" >&2; exit 1; }

# ── record a synthetic runlog row ────────────────────────────────────────
recall_str="$(jq -r '.recall // "0.00"' "$grade_json")"
bash "$scripts_dir/append_runlog.sh" --run-dir "$run_dir" \
  --project "ci-planted-round" --base "$base_sha" --pr - --pass 1 \
  --verdict CLEAN --run-id "$run_id" \
  --notes "planted-round drill, recall=$recall_str" --synthetic \
  || { echo "planted_round: append_runlog.sh failed" >&2; exit 1; }

echo "planted_round: drill complete — grade.json: $grade_json  recall=$recall_str" >&2
exit 0
