#!/usr/bin/env bash
# migrate_finding_namespace.sh — OPT-IN, NEVER AUTO-RUN one-shot remap of a
# finding_events.jsonl ledger from the old basename-derived fingerprint
# namespace to the new repo-identity namespace (issue #39).
#
# WHY THIS EXISTS: fingerprint_findings.sh's --project namespace changed from
# "$(basename "$(git rev-parse --show-toplevel)")" (collides across
# different repos that share a directory basename, e.g. two clones both
# named "api") to derive_project()'s repo-identity string (remote URL, or
# absolute path with no remote — see lib_project_namespace.sh). That is a
# deliberate namespace EPOCH: nothing in the fix auto-rewrites a user's real
# ~/.claude/skills/cross-review/finding_events.jsonl (real production data,
# out of scope for a repo-level code fix), so ids minted before the epoch
# keep their old value and ids minted after get the new, collision-resistant
# value. Most users don't need this script — the old and new ids simply
# coexist, and old findings that are already closed (fixed/dropped/etc.)
# don't need continuity anyway.
#
# Run this BY HAND only if you have currently-OPEN findings under the old
# namespace whose lifecycle you want to keep tracking under the new id.
# It rewrites finding_id (and the identity fields anchor_findings.sh /
# factcheck_findings.sh also stamp) for exactly the events whose recomputed
# OLD-namespace id matches, leaving every other line byte-identical.
#
# Usage:
#   migrate_finding_namespace.sh --ledger <finding_events.jsonl>
#                                  --old-project <name>
#                                  (--repo-root <path> | --new-project <name>)
#                                  --out <path>
#
#   --ledger <path>        the finding_events.jsonl to read (never edited
#                           in place — always written to --out).
#   --old-project <name>   the literal --project value findings were minted
#                           under before the epoch (usually the old
#                           directory basename, e.g. "api").
#   --repo-root <path>     derive the new namespace the same way
#                           fingerprint_findings.sh's --repo-root does.
#   --new-project <name>   or supply the new namespace literally.
#   --out <path>           required — the remapped ledger is written here.
#                           Never overwrites --ledger; review --out and swap
#                           it in yourself once you're satisfied.
#
# Only events that carry both `file` and `claim` fields (fingerprint_findings.sh
# always sets these) are candidates for remapping — an event that recomputes
# to the OLD-project hash gets its finding_id rewritten to the NEW-project
# hash of the same (file, claim). Events for other projects, or with no
# (file, claim) to recompute from, pass through unchanged.
#
# Exit: 0 ok, 2 usage, 1 io error (missing jq/sha1 tool or ledger not found).

set -uo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib_project_namespace.sh
source "$script_dir/lib_project_namespace.sh"

ledger="" ; old_project="" ; new_project="" ; repo_root="" ; out=""

need_val() { [[ "$2" -lt 2 ]] && { echo "missing value for $1" >&2; exit 2; }; }
while [[ $# -gt 0 ]]; do
  case "$1" in
    --ledger)       need_val "$1" "$#"; ledger="$2";       shift 2 ;;
    --old-project)  need_val "$1" "$#"; old_project="$2";  shift 2 ;;
    --new-project)  need_val "$1" "$#"; new_project="$2";  shift 2 ;;
    --repo-root)    need_val "$1" "$#"; repo_root="$2";    shift 2 ;;
    --out)          need_val "$1" "$#"; out="$2";          shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

if [[ -n "$new_project" && -n "$repo_root" ]]; then
  echo "migrate: --new-project and --repo-root are mutually exclusive" >&2
  exit 2
fi
if [[ -n "$repo_root" ]]; then
  [[ -d "$repo_root" ]] || { echo "migrate: --repo-root not a directory: $repo_root" >&2; exit 1; }
  new_project="$(derive_project "$repo_root")"
fi

if [[ -z "$ledger" || -z "$old_project" || -z "$new_project" || -z "$out" ]]; then
  echo "usage: $0 --ledger <finding_events.jsonl> --old-project <name> (--repo-root <path> | --new-project <name>) --out <path>" >&2
  exit 2
fi
[[ -f "$ledger" ]] || { echo "migrate: ledger not found: $ledger" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "migrate: jq required" >&2; exit 1; }

if command -v shasum >/dev/null 2>&1; then
  sha1_of() { shasum -a 1 | awk '{print $1}'; }
elif command -v sha1sum >/dev/null 2>&1; then
  sha1_of() { sha1sum | awk '{print $1}'; }
elif command -v openssl >/dev/null 2>&1; then
  sha1_of() { openssl dgst -sha1 -r | awk '{print $1}'; }
else
  echo "migrate: no sha1 tool found (need shasum, sha1sum, or openssl)" >&2
  exit 1
fi

# Same fingerprint math as fingerprint_findings.sh: normalize only the claim
# (case/whitespace), keep project/file exact-case, join with \x1f.
fingerprint_id() {
  local proj="$1" file="$2" claim="$3" claim_norm norm hash
  claim_norm="$(printf '%s' "$claim" \
            | tr '[:upper:]' '[:lower:]' | tr -s '[:space:]' ' ' \
            | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
  norm="$(printf '%s\x1f%s\x1f%s' "$proj" "$file" "$claim_norm")"
  hash="$(printf '%s' "$norm" | sha1_of)"
  printf 'f-%s\n' "${hash:0:8}"
}

tmp_out="$(mktemp)"; trap 'rm -f "$tmp_out"' EXIT
remapped=0
total=0

while IFS= read -r line; do
  total=$((total + 1))
  fid="$(jq -r '.finding_id // ""' <<<"$line")"
  file="$(jq -r '.file // ""' <<<"$line")"
  claim="$(jq -r '.claim // ""' <<<"$line")"
  if [[ -n "$fid" && -n "$file" && -n "$claim" ]]; then
    old_id="$(fingerprint_id "$old_project" "$file" "$claim")"
    if [[ "$old_id" == "$fid" ]]; then
      new_id="$(fingerprint_id "$new_project" "$file" "$claim")"
      line="$(jq -c --arg new_id "$new_id" '.finding_id = $new_id' <<<"$line")"
      remapped=$((remapped + 1))
    fi
  fi
  printf '%s\n' "$line" >>"$tmp_out"
done < "$ledger"

mv "$tmp_out" "$out"
trap - EXIT
echo "migrate: $remapped/$total event(s) remapped from '$old_project' to '$new_project' -> $out" >&2
echo "migrate: review $out, then swap it in for your real ledger yourself — this script never edits --ledger in place" >&2
