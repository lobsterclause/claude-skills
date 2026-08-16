#!/usr/bin/env bash
# fingerprint_findings.sh — give each synthesized finding a stable,
# content-derived id instead of the per-pass local sequence number ("f1",
# "f2"...) that SKILL.md's synthesis step mints fresh every pass. No LLM, no
# tokens — same "deterministic, no fuzzy matching" philosophy as
# anchor_findings.sh.
#
# WHY: nothing today ties "f1 in pass 1" to "f1 in pass 2" of the same PR, or
# to the same finding independently reported across different runs — each
# pass gets a fresh run-dir and fresh findings.json, re-synthesized from
# scratch. Without a stable id, per-finding lifecycle tracking
# (finding_events.jsonl: proposed -> anchored -> factcheck_kept/dropped ->
# eventually accepted/fixed) has nothing to key on.
#
# The fingerprint hashes `project|file|claim` (normalized: lowercased,
# whitespace-collapsed, trimmed) — deliberately NOT `line`/`snippet`/
# `severity`, so anchoring drift or re-triage doesn't fragment the id.
# KNOWN LIMITATION: hashing exact claim text still fragments across reworded
# phrasing pass-to-pass (e.g. a reviewer restating the same bug in different
# words mints a different id). Not solved here — no semantic dedup in this
# pass; that's future work, not this script's job.
#
# The old per-pass id is preserved as `local_id`; the new id REPLACES `id` in
# place (not added alongside) so this script's output is a drop-in
# replacement for findings.json as anchor_findings.sh's --findings input —
# anchor and factcheck both already treat `.id` as an opaque passthrough, so
# neither needs any code change for this.
#
# Usage:
#   fingerprint_findings.sh --findings <findings.json> --out <out.json>
#                            (--repo-root <path> | --project <name>)
#                            [--emit-events <run_id>]
#
# --repo-root derives the fingerprint namespace from repo identity rather than
# directory name (see derive_project() below) — prefer this over --project.
# --project is kept as a raw override: tests want an exact literal namespace,
# and it's an escape hatch if repo-identity derivation ever needs bypassing.
# Exactly one of --repo-root / --project must be given.
#
# NAMESPACE EPOCH (issue #39): before this flag, --project was always
# "$(basename "$(git rev-parse --show-toplevel)")" per SKILL.md — two
# different repos checked out under the same directory name (e.g. two clones
# both named "api") minted identical f-<hash> ids for the same-looking
# finding, and both fed the one global finding_events.jsonl, merging their
# lifecycles silently. --repo-root fixes this going forward by namespacing on
# repo identity (remote URL, or absolute path with no remote) instead of the
# directory basename. This is a deliberate epoch, NOT a ledger migration:
# ids already written to a user's finding_events.jsonl under the old
# basename-derived --project keep whatever id they have — nothing in this
# repo rewrites that file (it's real production data, out of scope for a
# repo-level fix). Only NEW findings fingerprinted after adopting
# --repo-root get the new, collision-resistant id. See
# scripts/migrate_finding_namespace.sh for an opt-in (never auto-run) remap
# of an existing ledger, if a user wants continuity for currently-open
# findings badly enough to run it by hand.
#
# findings.json shape (unchanged from SKILL.md's synthesis step):
#   { "findings": [ {id, severity, file, line, snippet, claim, sources, ...} ] }
# Output: same object, each finding gains "local_id" (the old id, or null)
# and has "id" replaced with "f-<8 hex chars>".
#
# --emit-events <run_id>: after writing --out, for each finding, append one
# "proposed" event per contributing reviewer (finding.sources[]) — or exactly
# one event with reviewer=null if sources is empty — to finding_events.jsonl
# via append_finding_event.sh. One event per (finding x source) rather than
# one per finding: a future per-reviewer unique-discovery calculation needs
# to filter the ledger by reviewer directly (events where reviewer==X and
# len(all_sources)==1) without re-joining back to findings.json.
#
# Exit: 0 ok, 2 usage, 1 io error (missing jq/sha1 tool). Never fails on a
# per-finding basis — every finding gets some id.

set -uo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib_project_namespace.sh
source "$script_dir/lib_project_namespace.sh"

findings="" ; out="" ; project="" ; repo_root="" ; emit_events_run_id=""

need_val() { [[ "$2" -lt 2 ]] && { echo "missing value for $1" >&2; exit 2; }; }
while [[ $# -gt 0 ]]; do
  case "$1" in
    --findings)     need_val "$1" "$#"; findings="$2";            shift 2 ;;
    --out)          need_val "$1" "$#"; out="$2";                 shift 2 ;;
    --project)      need_val "$1" "$#"; project="$2";             shift 2 ;;
    --repo-root)    need_val "$1" "$#"; repo_root="$2";           shift 2 ;;
    --emit-events)  need_val "$1" "$#"; emit_events_run_id="$2";  shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

if [[ -n "$project" && -n "$repo_root" ]]; then
  echo "fingerprint: --project and --repo-root are mutually exclusive (pick one namespace source)" >&2
  exit 2
fi
if [[ -n "$repo_root" ]]; then
  [[ -d "$repo_root" ]] || { echo "fingerprint: --repo-root not a directory: $repo_root" >&2; exit 1; }
  project="$(derive_project "$repo_root")"
fi

if [[ -z "$findings" || -z "$out" || -z "$project" ]]; then
  echo "usage: $0 --findings <json> --out <json> (--repo-root <path> | --project <name>) [--emit-events <run_id>]" >&2
  exit 2
fi
[[ -f "$findings" ]] || { echo "fingerprint: findings file not found: $findings" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "fingerprint: jq required" >&2; exit 1; }

# Portable SHA-1: shasum (macOS stock), sha1sum (most Linux), openssl (either).
if command -v shasum >/dev/null 2>&1; then
  sha1_of() { shasum -a 1 | awk '{print $1}'; }
elif command -v sha1sum >/dev/null 2>&1; then
  sha1_of() { sha1sum | awk '{print $1}'; }
elif command -v openssl >/dev/null 2>&1; then
  sha1_of() { openssl dgst -sha1 -r | awk '{print $1}'; }
else
  echo "fingerprint: no sha1 tool found (need shasum, sha1sum, or openssl)" >&2
  exit 1
fi

tmp_dir="$(mktemp -d)"; trap 'rm -rf "$tmp_dir"' EXIT
findings_jsonl="$tmp_dir/fingerprinted.jsonl"
: > "$findings_jsonl"

# \x1f (unit separator) joins the three fields so a stray literal "|" inside
# a filename or claim can't be confused with the field delimiter.
while IFS= read -r f; do
  file="$(jq -r '.file // ""' <<<"$f")"
  claim="$(jq -r '.claim // ""' <<<"$f")"
  old_id="$(jq -r '.id // ""' <<<"$f")"
  # Only the CLAIM is case/whitespace-normalized — project and file keep exact
  # case, so Foo.ts and foo.ts on a case-sensitive fs never share an id
  # (codex P2, PR #38).
  claim_norm="$(printf '%s' "$claim" \
            | tr '[:upper:]' '[:lower:]' | tr -s '[:space:]' ' ' \
            | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
  norm="$(printf '%s\x1f%s\x1f%s' "$project" "$file" "$claim_norm")"
  hash="$(printf '%s' "$norm" | sha1_of)"
  fid="f-${hash:0:8}"
  jq -c --arg fid "$fid" --arg local_id "$old_id" \
    '.local_id = ($local_id | if . == "" then null else . end) | .id = $fid' \
    <<<"$f" >> "$findings_jsonl"
done < <(jq -c '.findings[]' "$findings")

# Rebuild the top-level object: keep original keys, replace findings array.
jq -s \
  --slurpfile orig "$findings" \
  '{findings: .} as $new | ($orig[0] + $new)' \
  "$findings_jsonl" > "$out"

total_n="$(jq '.findings | length' "$out")"
echo "fingerprint: $total_n finding(s) assigned stable ids" >&2

if [[ -n "$emit_events_run_id" ]]; then
  script_dir="$(cd "$(dirname "$0")" && pwd)"
  while IFS= read -r f; do
    fid="$(jq -r '.id' <<<"$f")"
    severity="$(jq -r '.severity // ""' <<<"$f")"
    file="$(jq -r '.file // ""' <<<"$f")"
    claim="$(jq -r '.claim // ""' <<<"$f")"
    sources_json="$(jq -c '.sources // []' <<<"$f")"
    n_sources="$(jq 'length' <<<"$sources_json")"
    if [[ "$n_sources" -eq 0 ]]; then
      fields="$(jq -nc --arg severity "$severity" --arg file "$file" --arg claim "$claim" \
        --argjson all_sources "$sources_json" \
        '{reviewer: null, all_sources: $all_sources, severity: $severity, file: $file, claim: $claim}')"
      bash "$script_dir/append_finding_event.sh" --event proposed --finding-id "$fid" \
        --run-id "$emit_events_run_id" --fields "$fields"
    else
      while IFS= read -r reviewer; do
        fields="$(jq -nc --arg reviewer "$reviewer" --arg severity "$severity" --arg file "$file" --arg claim "$claim" \
          --argjson all_sources "$sources_json" \
          '{reviewer: $reviewer, all_sources: $all_sources, severity: $severity, file: $file, claim: $claim}')"
        bash "$script_dir/append_finding_event.sh" --event proposed --finding-id "$fid" \
          --run-id "$emit_events_run_id" --fields "$fields"
      done < <(jq -r '.[]' <<<"$sources_json")
    fi
  done < <(jq -c '.findings[]' "$out")
fi
