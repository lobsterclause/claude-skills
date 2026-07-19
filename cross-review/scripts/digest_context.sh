#!/usr/bin/env bash
# digest_context.sh — deterministic markdown digest of ast-grep's sgscan.jsonl
# and/or an impact.json blast-radius report, for the reviewer prompt preamble
# (cross-review/SKILL.md step 2.6). Replaces the ad hoc "LLM, please
# summarize this JSON" instruction with a fixed script: same inputs always
# produce the same bytes out.
#
# Usage:
#   digest_context.sh [--sgscan <sgscan.jsonl>] [--impact <impact.json>] [--top <N>]
# At least one of --sgscan / --impact is required. --top defaults to 5 and
# caps both the number of ast-grep rule rows shown and the number of files /
# tests listed inline per row; anything past the cap collapses to
# "+K more".
#
# Input tolerance:
#   sgscan.jsonl — one JSON object per line (ast-grep `scan --json=stream`
#     shape: ruleId, file, message, severity, ...). Missing ruleId/file
#     default to "unknown". Lines that aren't a JSON object (invalid JSON,
#     or valid JSON that isn't an object) are skipped and counted — never
#     fatal — and the count is reported on stderr.
#   impact.json — tolerant of the simple {affected_files, recommended_tests}
#     shape (array of strings, or array of objects with a file/path key) AND
#     the real `impact/scripts/impact.sh --json` shape
#     ({entries, reverseDeps, tests}), where affected files = entries plus
#     every file named in reverseDeps, flattened and deduped. A whole-file
#     JSON parse failure degrades to skipping the impact section entirely
#     (noted on stderr) rather than failing the run.
#
# Output: markdown on stdout, no raw JSON. Absent-but-valid inputs (0
# findings / empty arrays) print an explicit "no findings" / "no impact
# data" line rather than silence. Deterministic: stable sorts throughout,
# ties broken alphabetically.
#
# Exit: 0 ok (including all-malformed / empty-but-valid inputs), 1 io error
# (named file missing or jq unavailable), 2 usage error (no inputs given).

set -uo pipefail

sgscan=""; impact=""; top=5

need_val() { [[ "$2" -lt 2 ]] && { echo "digest: missing value for $1" >&2; exit 2; }; }
while [[ $# -gt 0 ]]; do
  case "$1" in
    --sgscan) need_val "$1" "$#"; sgscan="$2"; shift 2 ;;
    --impact) need_val "$1" "$#"; impact="$2"; shift 2 ;;
    --top)    need_val "$1" "$#"; top="$2";    shift 2 ;;
    *) echo "digest: unknown arg: $1" >&2; exit 2 ;;
  esac
done

usage="usage: $(basename "$0") [--sgscan <sgscan.jsonl>] [--impact <impact.json>] [--top <N>]"
if [[ -z "$sgscan" && -z "$impact" ]]; then
  echo "digest: at least one of --sgscan or --impact is required" >&2
  echo "$usage" >&2
  exit 2
fi

command -v jq >/dev/null 2>&1 || { echo "digest: jq required" >&2; exit 1; }

if ! [[ "$top" =~ ^[1-9][0-9]*$ ]]; then
  echo "digest: --top must be a positive integer, got '$top' — defaulting to 5" >&2
  top=5
fi

tmp_dir="$(mktemp -d)"; trap 'rm -rf "$tmp_dir"' EXIT

sections_rendered=0

# ── ast-grep section ─────────────────────────────────────────────────────────
if [[ -n "$sgscan" ]]; then
  [[ -f "$sgscan" ]] || { echo "digest: --sgscan file not found: $sgscan" >&2; exit 1; }

  valid="$tmp_dir/sgscan.valid.jsonl"
  : > "$valid"
  malformed=0
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -z "$line" ]] && continue
    if jq -e 'type == "object"' >/dev/null 2>&1 <<<"$line"; then
      printf '%s\n' "$line" >> "$valid"
    else
      malformed=$((malformed + 1))
    fi
  done < "$sgscan"
  echo "digest: skipped: $malformed malformed lines" >&2

  total="$(wc -l < "$valid" | tr -d ' ')"

  echo "## ast-grep"
  if [[ "$total" -eq 0 ]]; then
    echo "no findings"
  else
    rules_json="$(jq -s --argjson top "$top" '
      map({ruleId: (.ruleId // "unknown"), file: (.file // "unknown")})
      | group_by(.ruleId)
      | map({
          ruleId: .[0].ruleId,
          count: length,
          files: ( [.[].file]
                   | group_by(.)
                   | map({file: .[0], n: length})
                   | sort_by(-.n, .file) )
        })
      | sort_by(-.count, .ruleId)
      | { total_rules: length, rules: .[0:$top] }
    ' "$valid")"

    total_rules="$(jq -r '.total_rules' <<<"$rules_json")"
    echo "- total: $total finding(s) across $total_rules rule(s)"

    while IFS= read -r row; do
      ruleId="$(jq -r '.ruleId' <<<"$row")"
      count="$(jq -r '.count' <<<"$row")"
      fileline="$(jq -r --argjson top "$top" '
        (.files[0:$top] | map(.file)) as $shown
        | (.files | length) as $nf
        | ($nf - ($shown | length)) as $extra
        | ($shown + (if $extra > 0 then ["+\($extra) more"] else [] end))
        | join(", ")
      ' <<<"$row")"
      echo "- $ruleId: $count ($fileline)"
    done < <(jq -c '.rules[]' <<<"$rules_json")

    if [[ "$total_rules" -gt "$top" ]]; then
      remaining_rules=$((total_rules - top))
      echo "- (+$remaining_rules more rule(s) not shown)"
    fi
  fi
  sections_rendered=$((sections_rendered + 1))
fi

# ── impact section ───────────────────────────────────────────────────────────
if [[ -n "$impact" ]]; then
  [[ -f "$impact" ]] || { echo "digest: --impact file not found: $impact" >&2; exit 1; }

  if ! jq -e . >/dev/null 2>&1 <"$impact"; then
    echo "digest: --impact file is not valid JSON, skipping impact section" >&2
  else
    itype="$(jq -r 'type' <"$impact" 2>/dev/null)"
    [[ "$itype" != "object" ]] && \
      echo "digest: --impact top-level is $itype, expected object — no impact data extracted" >&2
    [[ "$sections_rendered" -gt 0 ]] && echo
    echo "## impact"

    extracted="$(jq -c --argjson top "$top" '
      def extract(x):
        if x == null then {list: [], dropped: 0}
        else
          ( x | map(
              if type == "string" then {v: ., ok: true}
              elif type == "object" then ( (.file // .path // null) as $f
                | if $f == null then {v: null, ok: false} else {v: $f, ok: true} end )
              else {v: null, ok: false}
              end
            ) ) as $mapped
          | { list: [ $mapped[] | select(.ok) | .v ],
              dropped: ( [ $mapped[] | select(.ok | not) ] | length ) }
        end;

      ( if type != "object" then {list: [], dropped: 0}
        elif has("affected_files") then extract(.affected_files)
        elif (has("entries") or has("reverseDeps")) then
          { list: (
              ( (.entries // []) | (if type == "array" then map(select(type == "string")) else [] end) )
              +
              ( (.reverseDeps // {}) | (if type == "object"
                  then ([.[]] | map(select(type == "array")) | add // [])
                  else [] end) )
            ),
            dropped: 0 }
        else {list: [], dropped: 0}
        end
      ) as $araw
      | ( $araw.list | map(select(type == "string" and . != "")) | unique | sort ) as $affected
      |
      ( if type != "object" then {list: [], dropped: 0}
        elif has("recommended_tests") then extract(.recommended_tests)
        elif has("tests") then extract(.tests)
        else {list: [], dropped: 0}
        end
      ) as $traw
      | ( $traw.list | map(select(type == "string" and . != "")) | unique | sort ) as $tests
      | ($affected | length) as $ac
      | ($tests | length) as $tc
      | ($affected[0:$top]) as $ashown
      | ($tests[0:$top]) as $tshown
      | ($ac - ($ashown | length)) as $aextra
      | ($tc - ($tshown | length)) as $textra
      | {
          ac: $ac, tc: $tc,
          dropped: ($araw.dropped + $traw.dropped),
          affected_line: ( if $ac == 0 then "none"
            else ( ($ashown + (if $aextra > 0 then ["+\($aextra) more"] else [] end)) | join(", ") )
            end ),
          tests_line: ( if $tc == 0 then "none"
            else ( ($tshown + (if $textra > 0 then ["+\($textra) more"] else [] end)) | join(", ") )
            end )
        }
    ' "$impact")"

    ac="$(jq -r '.ac' <<<"$extracted")"
    tc="$(jq -r '.tc' <<<"$extracted")"
    dropped="$(jq -r '.dropped' <<<"$extracted")"
    [[ "$dropped" -gt 0 ]] && echo "digest: skipped $dropped unrecognized impact entries" >&2

    if [[ "$ac" -eq 0 && "$tc" -eq 0 ]]; then
      echo "no impact data"
    else
      aline="$(jq -r '.affected_line' <<<"$extracted")"
      tline="$(jq -r '.tests_line' <<<"$extracted")"
      echo "- affected files: $ac ($aline)"
      echo "- recommended tests: $tc ($tline)"
    fi
    sections_rendered=$((sections_rendered + 1))
  fi
fi

[[ "$sections_rendered" -gt 0 ]] && echo
echo "> Digest generated deterministically by digest_context.sh — full JSON in the run dir."
