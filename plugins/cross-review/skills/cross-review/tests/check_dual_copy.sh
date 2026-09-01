#!/usr/bin/env bash
# Root copy ≡ plugin copy. The single implementation of that check.
#
# The skill ships twice in this repo — cross-review/ and
# plugins/cross-review/skills/cross-review/ — and PR #18 had to untangle the
# three-way drift that results when they diverge. The check itself used to
# ship twice as well: once inside run_tests.sh and once as an inline step in
# .github/workflows/cross-review-tests.yml, each with its own hand-maintained
# --exclude list. They drifted (the workflow's list was missing
# finding_events.jsonl), and the guard against drift became the thing that
# drifted. Hence one file, two callers.
#
# Usage: check_dual_copy.sh [repo_root]
#   repo_root defaults to the git toplevel containing this script.
#
# Exit: 0 identical · 1 drifted · 2 not in the skills repo (caller decides
#       whether that is a skip or a failure — in CI it must be a failure,
#       because a check that quietly declines to run is a vacuous green).
set -uo pipefail

repo_root="${1:-}"
if [[ -z "$repo_root" ]]; then
  here="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)" || exit 2
  repo_root="$(cd "$here" && git rev-parse --show-toplevel 2>/dev/null || true)"
fi

copy_a="$repo_root/cross-review"
copy_b="$repo_root/plugins/cross-review/skills/cross-review"
[[ -n "$repo_root" && -d "$copy_a" && -d "$copy_b" ]] || exit 2

# Runtime state, not source. The installed skill is a symlink to copy_a, so
# its history and scratch land there and would otherwise read as drift on
# every run.
#
# THE EXCLUDE LIST IS DERIVED FROM .gitignore, NOT WRITTEN OUT HERE.
#
# It used to be a hand-kept list, which is the same defect this whole file
# exists to fix, one layer up: .gitignore already names every runtime artifact
# that lands in copy_a, and a second hand-maintained copy of that list drifts
# from it exactly the way the workflow's copy drifted from run_tests.sh's.
# It had already drifted twice by 2026-08-30 —
#
#   merge_override_audit.jsonl   gitignored, never excluded here
#   iteration-*                  gitignored as a glob, excluded as literal
#                                "iteration-1", so iteration-2 read as drift
#
# — and both failures are the bad direction: rc=1, a false report of drift,
# on a developer machine where the artifact exists, while CI stays green
# because `git archive` carries no gitignored files. A guard that cries wolf
# only locally is one people learn to run with `|| true`, which is how the
# previous version of this check rotted.
#
# diff --exclude matches BASENAMES, so a `cross-review/foo/` entry becomes the
# pattern `foo`. Anything in .gitignore that is not under cross-review/ is
# irrelevant here and skipped.
excludes=()
gitignore="$repo_root/.gitignore"
if [[ -r "$gitignore" ]]; then
  # `|| [[ -n "$line" ]]`: read returns non-zero on a final line with no
  # trailing newline, having already assigned it. Without this the last
  # .gitignore entry would be silently dropped.
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%%$'\r'}"
    [[ -z "$line" || "$line" == \#* ]] && continue
    case "$line" in
      cross-review/*) pat="${line#cross-review/}" ;;
      '**/'*)         pat="${line#**/}" ;;
      *)              continue ;;
    esac
    pat="${pat%/}"                      # state/ -> state
    [[ -z "$pat" || "$pat" == */* ]] && continue
    excludes+=(--exclude "$pat")
  done < "$gitignore"
fi

# Fail SAFE, not open: if .gitignore is missing or named nothing usable, fall
# back to the known-good list rather than diffing with no excludes at all,
# which would report drift on any checkout that has ever run a review.
if [[ "${#excludes[@]}" -eq 0 ]]; then
  excludes=(
    --exclude 'runlog.jsonl*' --exclude 'finding_events.jsonl'
    --exclude 'state' --exclude 'iteration-*'
    --exclude 'merge_override_audit.jsonl' --exclude '*.bak*'
  )
fi

# Artifacts that are NOT gitignored and so cannot be derived above. This tail
# runs on both paths -- derived and fallback -- so nothing here can be lost by
# .gitignore changing shape.
#
#   runlog.jsonl.*  rotated logs, the same artifact as runlog.jsonl
#   .DS_Store       Finder's, not ours
#   *.bak*          plant_mutation.sh:300 runs `sed -E -i.bak` and removes the
#                   backup on the NEXT line; a round interrupted between those
#                   two lines leaves <file>.bak in the root copy. .gitignore
#                   carries only `**/*.bak-*`, which does not match `foo.bak`,
#                   so deriving the list narrowed this exclusion and brought
#                   back a false LOCAL drift report -- the exact wolf-crying
#                   failure this file's header says teaches people to run the
#                   guard with `|| true`. Broad on purpose: a stray backup file
#                   is never the drift we are hunting.
excludes+=(--exclude 'runlog.jsonl.*' --exclude '.DS_Store' --exclude '*.bak*')

diff -r "${excludes[@]}" "$copy_a" "$copy_b" >/dev/null 2>&1 || exit 1
exit 0
