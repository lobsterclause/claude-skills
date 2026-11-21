#!/bin/bash
# evidence-check.sh — hold every triage verdict to the code on the base branch.
#
# Usage: evidence-check.sh <verdicts.json>... [--ref <ref>] [--out <file>]
#   <verdicts.json>  an array of reader verdicts (see references/triage.md)
#   --ref            default origin/<BASE_BRANCH>
#   --out            default <workdir>/verdicts.checked.json
# Env: ISSUE_DRAIN_WORKDIR (absolute, holding intake.json and issues/),
#      ISSUE_DRAIN_REPO_DIR (absolute, a local checkout), ISSUE_DRAIN_REPO or
#      ISSUE_DRAIN_PROFILE
# Reads git. Writes one local file. Exit 0 when it ran, 2 on bad input.
#
# A reader is a cheap model reading an issue someone else wrote. Its verdict is
# a claim, and this script is where the claim meets the repo:
#   - every quoted line must be on <ref>, in that file, within
#     EVIDENCE_LINE_SLACK lines of where the reader said (the line is corrected
#     to where it was found). A quote that is not there downgrades the verdict
#     to "unclear";
#   - "already_fixed" needs a quoted line that was last changed AFTER the issue
#     was opened. `git blame` names that commit; the reader does not get to.
#     Code that predates the issue cannot be its fix: the reporter filed the
#     issue with that code in place. (Three of eight "obsolete" calls were
#     wrong on kma, and five of six dispatched issues were already fixed on
#     2026-11-07: both directions are expensive, so neither is taken on trust.)
#   - a fix that lives on a protected path becomes "needs_human";
#   - an eligible issue with no verdict gets an "unclear" one, so every issue
#     intake let in appears somewhere on the tracker;
#   - a verdict about an issue this run did not take in is dropped, loudly.
# What it cannot see: a line that a formatter touched after the issue was
# opened looks like a fix to blame. The session re-reads each closure before
# it is offered, and you tick it; those two checks cover that case.
set -euo pipefail
. "$(dirname "$0")/lib.sh"
need_workdir
need_repo_dir
load_profile

ref=""
out=""
inputs=()
while [ $# -gt 0 ]; do
  case "$1" in
    --ref) ref="${2:-}"; shift 2 ;;
    --out) out="${2:-}"; shift 2 ;;
    --*) die "unknown option $1" 2 ;;
    *) inputs+=("$1"); shift ;;
  esac
done
[ ${#inputs[@]} -gt 0 ] || die "usage: evidence-check.sh <verdicts.json>... [--ref <ref>] [--out <file>]" 2
[ -n "$ref" ] || ref="origin/$BASE_BRANCH"
[ -n "$out" ] || out="$WORKDIR/verdicts.checked.json"
[ -f "$WORKDIR/intake.json" ] || die "no intake.json in $WORKDIR; run intake.sh first" 2
for f in "${inputs[@]}"; do
  jq -e 'type == "array"' "$f" >/dev/null 2>&1 || die "not a JSON array of verdicts: $f" 2
done

ref_sha="$(git -C "$REPO_DIR" rev-parse --verify -q "$ref^{commit}")" || die "cannot resolve $ref in $REPO_DIR" 2

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
jq -s 'add' "${inputs[@]}" > "$tmp/all.json"
known="$(jq -c '[.eligible[].number]' "$WORKDIR/intake.json")"

# check_quote <file> <line> <quote>  ->  one JSON object on stdout
check_quote() {
  local file="$1" line="$2" quote="$3" fail="" found=0 nq blame sha="" ctime="null" subject=""
  nq="$(printf '%s' "$quote" | tr '\t' ' ' | sed -e 's/  */ /g' -e 's/^ //' -e 's/ $//')"
  case "$file" in ""|/*|-*|*..*) fail="is not a repo-relative path" ;; esac
  if [ -z "$fail" ] && ! is_number "$line"; then fail="has no line number"; fi
  if [ -z "$fail" ] && [ "$(printf '%s\n' "$quote" | wc -l)" -gt 1 ]; then fail="quote spans more than one line"; fi
  if [ -z "$fail" ] && [ "${#nq}" -lt "$EVIDENCE_MIN_QUOTE" ]; then fail="quote is shorter than $EVIDENCE_MIN_QUOTE characters"; fi
  if [ -z "$fail" ] && ! git -C "$REPO_DIR" cat-file -e "$ref_sha:$file" 2>/dev/null; then fail="file is not on $ref"; fi
  if [ -z "$fail" ]; then
    # The quote reaches awk through the environment: -v would read its backslashes as escapes.
    found="$(git -C "$REPO_DIR" show "$ref_sha:$file" | QUOTE="$nq" awk -v want="$line" -v slack="$EVIDENCE_LINE_SLACK" '
      { l = $0; gsub(/\t/, " ", l); gsub(/  +/, " ", l); sub(/^ /, "", l); sub(/ $/, "", l)
        if (NR >= want - slack && NR <= want + slack && index(l, ENVIRON["QUOTE"]) > 0) {
          d = NR - want; if (d < 0) d = -d
          if (best == 0 || d < bestd) { best = NR; bestd = d } } }
      END { print best + 0 }')"
    [ "$found" -gt 0 ] || fail="quote is not within $EVIDENCE_LINE_SLACK lines of that line on $ref"
  fi
  if [ -z "$fail" ]; then
    blame="$(git -C "$REPO_DIR" blame -L "$found,$found" --porcelain "$ref_sha" -- "$file" 2>/dev/null || true)"
    sha="$(printf '%s\n' "$blame" | awk 'NR == 1 { print $1 }')"
    ctime="$(printf '%s\n' "$blame" | awk '$1 == "committer-time" { print $2; exit }')"
    subject="$(printf '%s\n' "$blame" | sed -n '/^summary /{s///p;q;}')"
    printf '%s' "$ctime" | grep -Eq '^[0-9]+$' || { fail="git blame gave no commit for that line"; ctime="null"; }
  fi
  jq -cn --arg file "$file" --arg line "$line" --arg quote "$quote" --arg fail "$fail" \
        --argjson found "$found" --arg sha "$sha" --argjson ctime "$ctime" --arg subject "$subject" '
    { file: $file, line: (if $found > 0 then $found else ($line | tonumber? // $line) end), quote: $quote,
      ok: ($fail == ""), reason: (if $fail == "" then null else $fail end) }
    + (if $fail == "" then {commit: $sha, commit_time: $ctime, subject: $subject} else {} end)'
}

# check_items <verdict json> <key>  ->  JSON array of check_quote results
check_items() {
  local v="$1" key="$2" n j
  n="$(printf '%s' "$v" | jq --arg k "$key" '(.[$k] // []) | if type == "array" then length else 0 end')"
  j=0
  while [ "$j" -lt "$n" ]; do
    check_quote "$(printf '%s' "$v" | jq -r --arg k "$key" --argjson j "$j" '.[$k][$j].file // "" | tostring')" \
                "$(printf '%s' "$v" | jq -r --arg k "$key" --argjson j "$j" '.[$k][$j].line // "" | tostring')" \
                "$(printf '%s' "$v" | jq -r --arg k "$key" --argjson j "$j" '.[$k][$j].quote // "" | tostring')"
    j=$((j + 1))
  done | jq -sc '.'
}

# shellcheck disable=SC2016
JUDGE='
  def hits($re): if $re == "" then [] else map(select(test($re; "i"))) end;
  . as $v
  | ($v.status // "" | tostring) as $orig
  | ( (($v.likely_files // []) + [ $ev[] | .file ]) | map(select(type == "string" and . != "")) | unique ) as $files
  | [ $ev[] | select(.ok | not) ] as $bad
  | ( [ $ev[] | select(.ok and $created != null and .commit_time > $created) ] | sort_by(.commit_time) | last ) as $fix
  | ($files | hits($prot) | first) as $prot_hit
  | ($files | hits($risk)) as $risk_hits
  | ( if ([ "live", "already_fixed", "duplicate_of", "needs_human", "unclear" ] | index($orig)) == null
        then [ "unclear", "\"\($orig)\" is not a status a reader may return" ]
      elif $orig == "needs_human" or $orig == "unclear" then [ $orig, null ]
      elif ($ev | length) == 0 then [ "unclear", "no evidence was quoted" ]
      elif ($bad | length) > 0 then [ "unclear", "evidence failed the check: \($bad[0].file):\($bad[0].line) \($bad[0].reason)" ]
      elif $orig == "already_fixed" and $created == null then [ "unclear", "no local record of the issue, so the fix cannot be dated" ]
      elif $orig == "already_fixed" and $fix == null then [ "unclear", "every quoted line is older than the issue, so none of them is its fix" ]
      elif $orig == "already_fixed" and $fixing.given and ($fixing.ok | not) then [ "unclear", "the fixing commit the reader named \($fixing.reason)" ]
      elif $orig == "already_fixed" then [ $orig, null ]
      elif $orig == "duplicate_of" and ((($v.duplicate_of | type) != "number") or $v.duplicate_of == $v.number or (($known | index($v.duplicate_of)) == null))
        then [ "unclear", "duplicate_of does not name another issue in this run" ]
      elif $prot_hit then [ "needs_human", "protected path: \($prot_hit)" ]
      elif (($v.task // "") == "") or (($v.acceptance // "") == "") then [ "unclear", "no task statement or acceptance check" ]
      else [ $orig, null ] end ) as $r
  | $v + { status: $r[0], original_status: $orig, downgrade_reason: $r[1],
           evidence: $ev,
           files: $files,
           reuse: [ $reuse[] | select(.ok) ],
           reuse_dropped: ([ $reuse[] | select(.ok | not) ] | length),
           fix_commit: ( if $r[0] == "already_fixed" then { sha: $fix.commit, date: ($fix.commit_time | todate), subject: $fix.subject, file: $fix.file, line: $fix.line } else null end ),
           closable: ($r[0] == "already_fixed" and $v.behavioural == false),
           risk: (($risk_hits | length) > 0), risk_paths: $risk_hits,
           checked_ref: $ref, checked_sha: $ref_sha }'

rows="$tmp/rows.jsonl"
: > "$rows"
seen=" "
dropped=0
count="$(jq 'length' "$tmp/all.json")"
i=0
while [ "$i" -lt "$count" ]; do
  v="$(jq -c --argjson i "$i" '.[$i]' "$tmp/all.json")"
  i=$((i + 1))
  n="$(printf '%s' "$v" | jq -r 'if type == "object" then (.number // "" | tostring) else "" end')"
  if ! is_number "$n" || [ "$(printf '%s' "$known" | jq --argjson n "$n" 'index($n) != null')" != "true" ]; then
    echo "evidence-check.sh: dropped a verdict for '#$n': this run did not take that issue in" >&2
    dropped=$((dropped + 1))
    continue
  fi
  case "$seen" in
    *" $n "*)
      echo "evidence-check.sh: dropped a second verdict for #$n: the first one stands" >&2
      dropped=$((dropped + 1))
      continue ;;
  esac
  seen="$seen$n "

  ev="$(check_items "$v" evidence)"
  reuse="$(check_items "$v" reuse)"

  created="null"
  if [ -f "$WORKDIR/issues/$n.json" ]; then
    created="$(jq '.createdAt | fromdateiso8601? // null' "$WORKDIR/issues/$n.json")"
  fi

  fixing='{"given": false, "ok": true, "reason": ""}'
  named="$(printf '%s' "$v" | jq -r '.fixing_commit // "" | tostring')"
  if [ -n "$named" ]; then
    if ! printf '%s' "$named" | grep -Eq '^[0-9a-f]{7,40}$'; then
      fixing='{"given": true, "ok": false, "reason": "is not a commit id"}'
    elif ! git -C "$REPO_DIR" cat-file -e "$named^{commit}" 2>/dev/null; then
      fixing='{"given": true, "ok": false, "reason": "does not exist in the repo"}'
    elif ! git -C "$REPO_DIR" merge-base --is-ancestor "$named" "$ref_sha" 2>/dev/null; then
      fixing="$(jq -cn --arg ref "$ref" '{given: true, ok: false, reason: "is not on \($ref)"}')"
    else
      fixing='{"given": true, "ok": true, "reason": ""}'
    fi
  fi

  printf '%s' "$v" | jq -c --argjson ev "$ev" --argjson reuse "$reuse" --argjson created "$created" \
      --argjson fixing "$fixing" --argjson known "$known" --arg prot "$PROTECTED_PATH_RE" \
      --arg risk "$RISK_PATH_RE" --arg ref "$ref" --arg ref_sha "$ref_sha" "$JUDGE" >> "$rows"
done

# Every eligible issue ends with a verdict, even if no reader returned one.
jq -s --argjson known "$known" --arg ref "$ref" --arg ref_sha "$ref_sha" '
  . as $rows
  | $rows + [ $known[] | select(. as $n | [ $rows[].number ] | index($n) | not)
              | { number: ., status: "unclear", original_status: null,
                  downgrade_reason: "no reader returned a verdict for this issue",
                  evidence: [], files: [], reuse: [], reuse_dropped: 0, fix_commit: null, closable: false,
                  risk: false, risk_paths: [], checked_ref: $ref, checked_sha: $ref_sha } ]
  | sort_by(.number)' "$rows" > "$out.tmp"
mv "$out.tmp" "$out"

summary="$(jq -c --argjson dropped "$dropped" '
  { verdicts: length, dropped: $dropped,
    downgraded: ([ .[] | select(.downgrade_reason != null) ] | length),
    by_status: (group_by(.status) | map({key: .[0].status, value: length}) | from_entries) }' "$out")"
log_event evidence_check "$(printf '%s' "$summary" | jq -c --arg ref "$ref" --arg sha "$ref_sha" '. + {ref: $ref, sha: $sha}')"
echo "evidence-check: $summary -> $out"
jq -r '.[] | select(.downgrade_reason != null) | "  #\(.number): \(.original_status // "none") -> \(.status) (\(.downgrade_reason))"' "$out"
