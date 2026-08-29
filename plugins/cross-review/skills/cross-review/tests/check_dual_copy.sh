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
# every run: runlog/finding_events (2026-08-03), state/ (2026-08-29, where
# check_repeat_pass.sh records last-base).
diff -r \
  --exclude 'runlog.jsonl*' \
  --exclude 'finding_events.jsonl' \
  --exclude 'state' \
  --exclude 'iteration-1' \
  --exclude '*.bak*' \
  --exclude '.DS_Store' \
  "$copy_a" "$copy_b" >/dev/null 2>&1 || exit 1
exit 0
