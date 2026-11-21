#!/bin/bash
# setup.sh <dir> — lay out the triage fixture: the tidepool repo and a run
# folder with the twelve fixture issues taken in. Used by the triage eval.
#
#   <dir>/repo   the fixture git repo, branch develop (build-repo.sh)
#   <dir>/run    the run folder: issues/<n>.json, issues/<n>.md, intake.json
#
# Prints the env lines the other subcommands need. Writes nothing outside <dir>.
set -euo pipefail
dir="${1:?usage: setup.sh <dir>}"
case "$dir" in /*) ;; *) echo "setup.sh: <dir> must be an absolute path" >&2; exit 2 ;; esac
here="$(cd "$(dirname "$0")" && pwd)"

mkdir -p "$dir"
"$BASH" "$here/fixtures/build-repo.sh" "$dir/repo"

export ISSUE_DRAIN_WORKDIR="$dir/run"
export ISSUE_DRAIN_REPO="example/tidepool"
export ISSUE_DRAIN_REPO_DIR="$dir/repo"
export ISSUE_DRAIN_PROFILE="$here/fixtures/tidepool.toml"
"$here/../bin/issue-drain" intake --from-file "$here/fixtures/issues.json" >/dev/null

cat <<EOF
export ISSUE_DRAIN_WORKDIR="$dir/run"
export ISSUE_DRAIN_REPO="example/tidepool"
export ISSUE_DRAIN_REPO_DIR="$dir/repo"
export ISSUE_DRAIN_PROFILE="$here/fixtures/tidepool.toml"
EOF
