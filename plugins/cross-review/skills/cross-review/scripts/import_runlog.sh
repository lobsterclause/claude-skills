#!/usr/bin/env bash
# import_runlog.sh — merge one or more external runlog.jsonl files into this
# skill's runlog, deduped and chronologically sorted.
#
# Why this exists: the runlog lives at a path relative to wherever the skill is
# installed ($skill_dir/runlog.jsonl). Every copy of the skill — the repo, the
# ~/.claude/skills install, the plugin cache — therefore keeps its OWN history,
# and a reinstall/sync starts from an empty log. This script consolidates them:
# point it at an old or sibling runlog and its entries are folded into the
# current one without clobbering what's already there.
#
# Safe to run repeatedly: import is idempotent. Identical JSON entries collapse
# (exact-object dedup), so re-importing the same source adds nothing. Legacy
# hand-curated entries (no `ts`) are preserved and sorted to the front.
#
# Usage:
#   import_runlog.sh --from <file|dir> [--from <file|dir> ...]
#                    [--into <runlog.jsonl>]   # default: this skill's runlog
#                    [--dry-run]               # report counts, write nothing
#                    [--quiet]
#
#   --from <path>   A runlog.jsonl file, OR a directory (searched one level deep
#                   for `runlog.jsonl` and `*/runlog.jsonl`). Repeatable.
#   --into <path>   Destination runlog. Defaults to $skill_dir/runlog.jsonl.
#   --dry-run       Compute and print the merge summary but do not write.
#
# Exit codes: 0 ok (incl. dry-run), 1 nothing to import / no valid entries,
#             2 usage error.
#
# NOTE: reads use file-args/pipes (never `cmd < file`) and the atomic write goes
# through a temp IN THE DESTINATION DIRECTORY, so the rename is same-filesystem
# atomic and survives hosts where stdin-redirect reads of the runlog misbehave.

set -uo pipefail

froms=()
into=""
dry_run=0
quiet=0

need_val() {
  if [[ "$2" -lt 2 ]]; then
    echo "missing value for $1" >&2
    exit 2
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --from)    need_val "$1" "$#"; froms+=("$2"); shift 2 ;;
    --into)    need_val "$1" "$#"; into="$2";     shift 2 ;;
    --dry-run) dry_run=1; shift ;;
    --quiet)   quiet=1;   shift ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

if [[ ${#froms[@]} -eq 0 ]]; then
  echo "usage: $0 --from <file|dir> [--from ...] [--into <runlog>] [--dry-run] [--quiet]" >&2
  exit 2
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "import_runlog: jq required (brew install jq)" >&2
  exit 1
fi

skill_dir="$(cd "$(dirname "$0")/.." && pwd)"
[[ -z "$into" ]] && into="$skill_dir/runlog.jsonl"

log() { [[ "$quiet" -eq 0 ]] && echo "$@" >&2; return 0; }

# Resolve each --from to one or more concrete runlog files.
sources=()
for f in "${froms[@]}"; do
  if [[ -f "$f" ]]; then
    sources+=("$f")
  elif [[ -d "$f" ]]; then
    # One level deep: <dir>/runlog.jsonl and <dir>/*/runlog.jsonl
    found=0
    for cand in "$f/runlog.jsonl" "$f"/*/runlog.jsonl; do
      [[ -f "$cand" ]] && { sources+=("$cand"); found=1; }
    done
    [[ "$found" -eq 0 ]] && echo "import_runlog: no runlog.jsonl under directory: $f" >&2
  else
    echo "import_runlog: --from path not found: $f" >&2
  fi
done

# Drop a source that is literally the destination — it's already folded in and
# re-reading it just doubles work (unique() collapses it anyway).
into_real="$(cd "$(dirname "$into")" 2>/dev/null && printf '%s/%s' "$(pwd)" "$(basename "$into")")"
filtered=()
for s in "${sources[@]}"; do
  s_real="$(cd "$(dirname "$s")" 2>/dev/null && printf '%s/%s' "$(pwd)" "$(basename "$s")")"
  [[ "$s_real" == "$into_real" ]] && { log "skip: --from is the destination ($s)"; continue; }
  filtered+=("$s")
done
sources=("${filtered[@]}")

if [[ ${#sources[@]} -eq 0 ]]; then
  echo "import_runlog: no source runlog files to import" >&2
  exit 1
fi

# Helpers — all read via file-args/pipe, never stdin redirect.
count_valid() { # count_valid <file...> -> number of parseable JSON entries
  [[ $# -eq 0 ]] && { echo 0; return; }
  cat -- "$@" 2>/dev/null | jq -c -R 'fromjson? // empty' | jq -s 'length'
}
count_raw() { # count_raw <file...> -> number of non-blank lines
  [[ $# -eq 0 ]] && { echo 0; return; }
  cat -- "$@" 2>/dev/null | grep -c '[^[:space:]]' || true
}

existing_valid=0
[[ -f "$into" ]] && existing_valid="$(count_valid "$into")"
incoming_valid="$(count_valid "${sources[@]}")"
incoming_raw="$(count_raw "${sources[@]}")"
incoming_invalid=$(( incoming_raw - incoming_valid ))
[[ "$incoming_invalid" -lt 0 ]] && incoming_invalid=0

if [[ "$incoming_valid" -eq 0 ]]; then
  echo "import_runlog: sources contained no valid JSON entries (skipped $incoming_invalid non-JSON line(s))" >&2
  exit 1
fi

# Build the merged result: existing + all sources, parse-filtered, exact-object
# deduped, sorted by ts (entries without ts sort first as oldest).
dest_dir="$(dirname "$into")"
mkdir -p "$dest_dir"
merged_tmp="$(mktemp "$dest_dir/.runlog.import.XXXXXX")"
# shellcheck disable=SC2064
trap "rm -f '$merged_tmp'" EXIT

merge_inputs=()
[[ -f "$into" ]] && merge_inputs+=("$into")
merge_inputs+=("${sources[@]}")

cat -- "${merge_inputs[@]}" 2>/dev/null \
  | jq -c -R 'fromjson? // empty' \
  | jq -s -c 'unique | sort_by(.ts // "") | .[]' > "$merged_tmp"

final_count="$(count_valid "$merged_tmp")"
added=$(( final_count - existing_valid ))
[[ "$added" -lt 0 ]] && added=0
deduped=$(( existing_valid + incoming_valid - final_count ))
[[ "$deduped" -lt 0 ]] && deduped=0

log "── import_runlog summary ──"
log "  destination:     $into"
log "  sources:         ${#sources[@]} file(s)"
log "  existing entries: $existing_valid"
log "  incoming valid:   $incoming_valid  (skipped $incoming_invalid non-JSON line(s))"
log "  duplicates dropped: $deduped"
log "  added:            $added"
log "  total after:      $final_count"

if [[ "$dry_run" -eq 1 ]]; then
  log "  (dry-run — destination not modified)"
  exit 0
fi

# Atomic publish: temp lives in dest_dir, so mv is a same-filesystem rename.
# flock guards against a concurrent append_runlog/splitstream writer.
if command -v flock >/dev/null 2>&1; then
  (
    flock -x 200
    mv -f "$merged_tmp" "$into"
  ) 200>"$into.lock"
else
  mv -f "$merged_tmp" "$into"
fi
trap - EXIT
log "  wrote $final_count entries to $into"
