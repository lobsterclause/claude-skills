#!/usr/bin/env bash
# emit_sarif.sh — convert a verified findings.json (the output of SKILL.md
# step 4.5: anchor_findings.sh -> factcheck_findings.sh -> fingerprint_findings.sh
# -> score_findings.sh) into a SARIF 2.1.0 log, so findings can be uploaded via
# github/codeql-action/upload-sarif and land as GitHub code-scanning
# annotations on the line they're about. Pure bash + jq. No LLM, no network.
#
# Usage:
#   emit_sarif.sh --findings <findings.verified.json> --out <file.sarif>
#
# findings.json shape (see anchor_findings.sh, factcheck_findings.sh,
# fingerprint_findings.sh, score_findings.sh for the authoritative field
# definitions):
#   { "findings": [
#       { "id": "f-<hash>", "local_id", "severity": "Critical|High|Medium|Low",
#         "file", "line", "claim", "snippet", "sources": [...],
#         "providers": [...], "provider_votes", "convergent",
#         "disposition", "anchor": {resolved, start_line, end_line, side},
#         "factcheck": {verdict: "keep"|"drop", reason}, ... }
#   ] }
#
# Mapping:
#   - anchor.resolved == true  -> physicalLocation.region from
#     anchor.start_line/anchor.end_line.
#   - anchor.resolved == true but anchor.side == "old" (a deleted line) ->
#     file-level result too: the line number belongs to the base, not the head.
#   - anchor.resolved != true, or the "anchor" key is absent entirely -> a
#     file-level result: an artifactLocation with NO region key. Never a
#     guessed line.
#   - severity -> SARIF level: Critical/High -> error, Medium -> warning,
#     Low -> note. An unrecognised severity falls back to "warning" rather
#     than erroring the whole run (tolerant-input contract, same spirit as
#     the anchor/factcheck/score scripts).
#   - factcheck.verdict == "drop" -> the finding is excluded from the SARIF
#     entirely (a finding with no factcheck key, or verdict != "drop", is
#     kept — fail-safe, mirrors factcheck_findings.sh's own keep-by-default
#     posture).
#   - .id (the fingerprint_findings.sh "f-<hash>" id) -> partialFingerprints
#     under the "crFingerprint" key, so a re-run dedupes against a prior scan
#     instead of re-annotating the same line.
#   - sources / providers / provider_votes / convergent / disposition ->
#     result.properties, for anything consuming the SARIF that wants the
#     synthesis context without re-parsing findings.json.
#
# Determinism: the same input file MUST produce byte-identical output no
# matter how many times or where it's run. No timestamps, no random ids, no
# host-dependent data. Results are sorted by id (ascending) as a stable,
# content-derived order; jq -S sorts all object keys.
#
# Tolerant input handling, matching the sibling scripts' style: a finding
# missing "anchor" entirely is treated as unresolved (file-level result). A
# finding missing "factcheck" is kept (not dropped) — same fail-safe posture
# as factcheck_findings.sh. A whole-file JSON parse failure is a clean
# error and a nonzero exit, not a partial write: the SARIF is built in a
# temp file and moved into place, so --out is never left half-written.
#
# Exit: 0 ok, 2 usage, 1 io/parse error.

set -uo pipefail

findings="" ; out=""

need_val() { [[ "$2" -lt 2 ]] && { echo "missing value for $1" >&2; exit 2; }; }
while [[ $# -gt 0 ]]; do
  case "$1" in
    --findings) need_val "$1" "$#"; findings="$2"; shift 2 ;;
    --out)      need_val "$1" "$#"; out="$2";      shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

[[ -z "$findings" || -z "$out" ]] && { echo "usage: $0 --findings <findings.verified.json> --out <file.sarif>" >&2; exit 2; }
[[ -f "$findings" ]] || { echo "emit_sarif: findings file not found: $findings" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "emit_sarif: jq required" >&2; exit 1; }

jq -e . "$findings" >/dev/null 2>&1 || { echo "emit_sarif: findings file is not valid JSON: $findings" >&2; exit 1; }

tmp_dir="$(mktemp -d)"; trap 'rm -rf "$tmp_dir"' EXIT
tmp_out="$tmp_dir/out.sarif"

jq -S '
  def levelOf($sev):
    if $sev == "Critical" or $sev == "High" then "error"
    elif $sev == "Medium" then "warning"
    elif $sev == "Low" then "note"
    else "warning"
    end;

  [ .findings[]
    | select((.factcheck.verdict // "keep") != "drop")
  ]
  | sort_by(.id)
  | map(
      . as $f
      # Only a NEW-side anchor names a line that exists in the reviewed tree;
      # an old-side anchor (a deleted line) would annotate whatever now sits
      # at that number (codex, PR #80 review). Old-side → file-level result.
      # side must be an explicit "new": a resolved anchor with no side is
      # legacy/malformed input and must not annotate a head line (codex, #80 p2).
      | (($f.anchor.resolved // false) and ($f.anchor.side == "new")) as $resolved
      | {
          ruleId: "cross-review-finding",
          level: levelOf($f.severity // ""),
          message: { text: ($f.claim // "") },
          locations: [
            {
              physicalLocation: (
                { artifactLocation: { uri: ($f.file // "") } }
                + (
                    if $resolved and (($f.anchor.start_line // 0) > 0)
                    then { region: { startLine: $f.anchor.start_line, endLine: $f.anchor.end_line } }
                    else {}
                    end
                  )
              )
            }
          ],
          partialFingerprints: { crFingerprint: ($f.id // "") },
          properties: (
            {
              sources: ($f.sources // []),
              severity: ($f.severity // null)
            }
            + (if $f.providers != null then { providers: $f.providers } else {} end)
            + (if $f.provider_votes != null then { provider_votes: $f.provider_votes } else {} end)
            + (if $f.convergent != null then { convergent: $f.convergent } else {} end)
            + (if $f.disposition != null then { disposition: $f.disposition } else {} end)
          )
        }
    ) as $results
  | {
      "$schema": "https://raw.githubusercontent.com/oasis-tcs/sarif-spec/master/Schemata/sarif-schema-2.1.0.json",
      version: "2.1.0",
      runs: [
        {
          tool: {
            driver: {
              name: "cross-review",
              informationUri: "https://github.com/lobsterclause/claude-skills",
              rules: [
                {
                  id: "cross-review-finding",
                  name: "CrossReviewFinding",
                  shortDescription: { text: "A finding synthesized by the cross-review skill from external AI code reviewers." }
                }
              ]
            }
          },
          results: $results
        }
      ]
    }
' "$findings" > "$tmp_out" || { echo "emit_sarif: failed to build SARIF from $findings" >&2; exit 1; }

mv "$tmp_out" "$out"
