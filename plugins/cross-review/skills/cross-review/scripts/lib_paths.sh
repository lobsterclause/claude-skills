#!/usr/bin/env bash
# lib_paths.sh — the ONE place `--paths` pathspec lists are parsed, normalised
# and hashed. Sourced by worktree.sh, run_reviewers.sh and plan_rounds.sh so the
# three cannot disagree about what "the same set of paths" means (the repeat-
# pass key and the context.json record both depend on that).
#
# A round can be restricted to a set of git pathspecs (`--paths a/,b/*.ts`,
# repeatable `--path`, or CROSS_REVIEW_PATHS). Normalisation is deliberately
# boring and deterministic:
#   - split on commas and newlines, trim surrounding whitespace
#   - strip a leading "./", drop empties
#   - REFUSE an absolute path or any ".." component (a pathspec must stay inside
#     the repo; git would reject it later with a far less useful message)
#   - sort + dedupe, so "b,a" and "a,b,a" are the same round
# A comma cannot appear inside one pathspec when passed as a single --paths
# value; use repeated --path for a name that contains one.
#
# bash 3.2 compatible (no mapfile, no associative arrays).

# cr_paths_normalise <raw>... — prints the normalised pathspecs, one per line.
# Returns 2 (message on stderr) on an invalid entry or when nothing is left.
cr_paths_normalise() {
  local raw item out="" rc=0
  for raw in "$@"; do
    # newline -> comma so one loop handles both separators
    raw="$(printf '%s' "$raw" | tr '\n' ',')"
    local IFS=','
    for item in $raw; do
      # trim whitespace
      item="${item#"${item%%[![:space:]]*}"}"
      item="${item%"${item##*[![:space:]]}"}"
      while [[ "$item" == ./* ]]; do item="${item#./}"; done
      [[ -n "$item" && "$item" != "." ]] || continue
      case "$item" in
        /*) echo "paths: absolute pathspec refused: $item (use a repo-relative path)" >&2; rc=2; continue ;;
      esac
      case "/$item/" in
        */../*) echo "paths: pathspec with a '..' component refused: $item" >&2; rc=2; continue ;;
      esac
      out+="$item"$'\n'
    done
  done
  [[ "$rc" -eq 0 ]] || return 2
  if [[ -z "$out" ]]; then
    echo "paths: no usable pathspec in the given --paths value" >&2
    return 2
  fi
  printf '%s' "$out" | LC_ALL=C sort -u
}

# cr_paths_hash — reads normalised pathspecs on stdin, prints a 12-hex digest.
# Same input -> same digest on every machine; only used when paths are set.
cr_paths_hash() {
  (shasum -a 256 2>/dev/null || sha256sum) | cut -c1-12
}

# cr_paths_json — reads normalised pathspecs on stdin, prints a JSON array.
cr_paths_json() {
  jq -R . | jq -sc .
}
