#!/usr/bin/env bash
# lib_paths.sh — the ONE place `--paths` pathspec lists are parsed, normalised
# and hashed. Sourced by worktree.sh, run_reviewers.sh and post_comment.sh so
# they cannot disagree about what "the same set of paths" means (the repeat-
# pass key, the context.json record and the posted marker all depend on that).
#
# A round can be restricted to a set of git pathspecs (`--paths a/,b/*.ts`,
# repeatable `--path`, or CROSS_REVIEW_PATHS). Normalisation is deliberately
# boring and deterministic:
#   - one pathspec per line, surrounding whitespace trimmed
#   - strip a leading "./", drop empties
#   - REFUSE an absolute path or any ".." component (a pathspec must stay inside
#     the repo; git would reject it later with a far less useful message)
#   - REFUSE pathspec magic other than ":(literal)<path>" (see below)
#   - sort + dedupe, so "b,a" and "a,b,a" are the same round
#
# PATHSPEC MAGIC. git reads a leading ":" as magic: ":!x", ":^x" and
# ":(exclude)x" SUBTRACT files, ":(top)x" and ":/x" re-anchor the path, and
# ":(literal)/abs" or ":(top).." walk past the two refusals above, which only
# looked at the first characters. A scope list says what a round reviewed, and
# every record prints it that way ("only changes in `a`, `b` were reviewed"),
# so an exclude in it was listed as a reviewed path. The only magic accepted is
# ":(literal)<path>", which plan_rounds.sh emits for a filename that starts
# with ":" or contains a glob character; the absolute and ".." refusals are
# applied to the path after it.
#
# WHERE A COMMA SEPARATES, AND WHERE IT DOES NOT. `--paths` and
# CROSS_REVIEW_PATHS are comma lists: callers pass their value through
# cr_paths_csv, which turns each comma into a newline. A `--path` value and a
# pathspec read back from context.json are ONE pathspec each and go to
# cr_paths_normalise_lines untouched, so a name that contains a comma survives.
# Both callers used to push the two flags into one array that was comma-split
# as a whole, and `--path 'dir/a,b.ts'` became `dir/a` plus `b.ts`.
#
# A newline always separates: the normalised list is line-oriented everywhere
# it is stored or hashed, so a pathspec cannot contain one.
#
# NOTHING HERE MAY WORD-SPLIT A PATHSPEC. The splitter used to be an unquoted
# `for item in $raw`, which also ran pathname expansion: `src/*.ts` became the
# files that happened to exist in the caller's working directory. A file the
# change deleted then dropped out of the round without a message, and the paths
# hash followed the checkout. Lines are read with `read -r`, which expands
# nothing.
#
# bash 3.2 compatible (no mapfile, no associative arrays).

# cr_paths_csv <value> — a comma-list value (`--paths`, CROSS_REVIEW_PATHS) as
# newline-separated pathspecs, ready for cr_paths_normalise_lines.
cr_paths_csv() {
  local nl=$'\n'
  printf '%s' "${1//,/$nl}"
}

# cr_paths_normalise_lines <raw>... — each argument is one pathspec, or several
# separated by newlines. Commas are NOT separators here. Prints the normalised
# pathspecs, one per line. Returns 2 (message on stderr) on an invalid entry or
# when nothing is left.
cr_paths_normalise_lines() {
  local raw item path out="" rc=0 lit=':(literal)'
  for raw in "$@"; do
    while IFS= read -r item || [[ -n "$item" ]]; do
      # trim whitespace
      item="${item#"${item%%[![:space:]]*}"}"
      item="${item%"${item##*[![:space:]]}"}"
      while [[ "$item" == ./* ]]; do item="${item#./}"; done
      [[ -n "$item" && "$item" != "." ]] || continue
      # `path` is what git will match: the item itself, or what follows the one
      # accepted magic prefix. The refusals below look at `path`, so they cannot
      # be stepped over with a prefix.
      path="$item"
      case "$item" in
        "$lit"*) path="${item#"$lit"}" ;;
        :*) echo "paths: pathspec magic refused: $item (a scope lists the paths a round reviews, so excludes and other magic are not accepted; for a name that starts with ':' write ':(literal)<path>')" >&2; rc=2; continue ;;
      esac
      if [[ -z "$path" ]]; then
        echo "paths: ':(literal)' with no path after it refused" >&2; rc=2; continue
      fi
      case "$path" in
        /*) echo "paths: absolute pathspec refused: $item (use a repo-relative path)" >&2; rc=2; continue ;;
      esac
      case "/$path/" in
        */../*) echo "paths: pathspec with a '..' component refused: $item" >&2; rc=2; continue ;;
      esac
      out+="$item"$'\n'
    done <<<"$raw"
  done
  [[ "$rc" -eq 0 ]] || return 2
  if [[ -z "$out" ]]; then
    echo "paths: no usable pathspec in the given --paths value" >&2
    return 2
  fi
  printf '%s' "$out" | LC_ALL=C sort -u
}

# cr_paths_normalise <raw>... — every argument is a comma list (commas and
# newlines both separate). Same output and return codes as
# cr_paths_normalise_lines.
cr_paths_normalise() {
  local raw args=()
  for raw in "$@"; do args+=("$(cr_paths_csv "$raw")"); done
  cr_paths_normalise_lines ${args[@]+"${args[@]}"}
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
