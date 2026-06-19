#!/usr/bin/env bash
# anchor_findings.sh — deterministically re-derive each finding's line number by
# matching its quoted code snippet against the actual diff hunks. Ported from
# open-code-review's internal/diff/resolver.go (exact consecutive match, new
# side then old side; no fuzzy/nearest snap). No LLM, no tokens.
#
# A finding whose snippet matches gets `anchor.resolved=true` and its `line`
# corrected to the real hunk line. A finding whose snippet appears NOWHERE in the
# diff gets `anchor.resolved=false` — a strong signal of a hallucinated location.
# We FLAG (never auto-drop) unresolved findings: a reviewer may legitimately cite
# an unchanged neighbouring line it read with tools.
#
# Usage:
#   anchor_findings.sh --findings <findings.json> --out <findings.anchored.json>
#                      (--base <ref> [--repo <dir>] | --diff <unified-diff-file>)
#
# findings.json shape: { "findings": [ {id, file, line, snippet, ...}, ... ] }
# Output: same object, each finding gains:
#   "anchor": { "resolved": bool, "start_line": int, "end_line": int, "side": "new|old|none" }
# and on resolved, "line" is overwritten with start_line (original kept as "line_claimed").
#
# Exit: 0 ok, 2 usage, 1 io error. Never fails the pass on a per-finding miss.

set -uo pipefail

findings="" ; out="" ; base="" ; repo="." ; diff_file=""

need_val() { [[ "$2" -lt 2 ]] && { echo "missing value for $1" >&2; exit 2; }; }
while [[ $# -gt 0 ]]; do
  case "$1" in
    --findings) need_val "$1" "$#"; findings="$2"; shift 2 ;;
    --out)      need_val "$1" "$#"; out="$2";      shift 2 ;;
    --base)     need_val "$1" "$#"; base="$2";     shift 2 ;;
    --repo)     need_val "$1" "$#"; repo="$2";     shift 2 ;;
    --diff)     need_val "$1" "$#"; diff_file="$2"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

[[ -z "$findings" || -z "$out" ]] && { echo "usage: $0 --findings <json> --out <json> (--base <ref> [--repo <dir>] | --diff <file>)" >&2; exit 2; }
[[ -f "$findings" ]] || { echo "anchor: findings file not found: $findings" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "anchor: jq required" >&2; exit 1; }

tmp_dir="$(mktemp -d)"; trap 'rm -rf "$tmp_dir"' EXIT
diff_path="$tmp_dir/diff.txt"
if [[ -n "$diff_file" ]]; then
  [[ -f "$diff_file" ]] || { echo "anchor: --diff file not found: $diff_file" >&2; exit 1; }
  cat "$diff_file" > "$diff_path"
elif [[ -n "$base" ]]; then
  ( cd "$repo" && git diff "$base"...HEAD ) > "$diff_path" 2>/dev/null \
    || { echo "anchor: git diff against '$base' failed in $repo" >&2; exit 1; }
else
  echo "anchor: provide --base <ref> or --diff <file>" >&2; exit 2
fi

# The matcher: given the diff (stdin), a target file, and a snippet file, print
#   "<resolved|unresolved> <start> <end> <new|old|none>"
# Reconstructs per-hunk old/new line counters, stores non-blank normalised lines
# for each side, then searches for a consecutive match of the snippet lines.
awk_prog="$tmp_dir/match.awk"
cat > "$awk_prog" <<'AWK'
function normDiff(s){ s=substr(s,2); gsub(/^[ \t]+|[ \t]+$/,"",s); gsub(/[ \t]+/," ",s); return s }
# normSnip must NOT strip a leading +/-/space: the snippet is raw code, so a line
# whose body legitimately starts with + or - (e.g. `++i`, `-x`) must compare equal
# to normDiff's output, which only strips the single diff-column char. Stripping
# here broke that alignment (anchor bug b3).
function normSnip(s){ gsub(/^[ \t]+|[ \t]+$/,"",s); gsub(/[ \t]+/," ",s); return s }
BEGIN{
  target = ENVIRON["TARGET"]   # via env, not -v, so backslashes in paths survive
  # load snippet (non-blank normalised lines)
  sn=0
  while ((getline line < snipfile) > 0){ c=normSnip(line); if(c!="") sp[++sn]=c }
  nn=0; on=0; intarget=0; old_path=""; new_path=""
}
# File headers are anchored to ` a/`, ` b/`, or ` /dev/null` so that diff CONTENT
# lines whose code starts with `+++`/`---` (after git's column marker) cannot be
# mistaken for headers (anchor bug b1). We track BOTH old and new paths so a
# deleted file (new path `/dev/null`) still matches on its old path (bug b2).
/^--- ([ab]\/|\/dev\/null)/{
  p=$0; sub(/^--- /,"",p); sub(/\t.*$/,"",p)
  if(p=="/dev/null"){ old_path="" } else { sub(/^[ab]\//,"",p); old_path=p }
  next
}
/^\+\+\+ ([ab]\/|\/dev\/null)/{
  p=$0; sub(/^\+\+\+ /,"",p); sub(/\t.*$/,"",p)
  if(p=="/dev/null"){ new_path="" } else { sub(/^[ab]\//,"",p); new_path=p }
  intarget = ((new_path!="" && new_path==target) || (old_path!="" && old_path==target))
  next
}
/^diff --git /{ intarget=0; old_path=""; new_path=""; next }
/^@@ /{
  if(intarget){
    # @@ -oldStart[,oldCount] +newStart[,newCount] @@
    h=$0
    match(h,/-[0-9]+/); oldno=substr(h,RSTART+1,RLENGTH-1)+0
    match(h,/\+[0-9]+/); newno=substr(h,RSTART+1,RLENGTH-1)+0
  }
  next
}
{
  if(!intarget) next
  c=substr($0,1,1); rest=normDiff($0)
  if(c==" "){ if(rest!=""){ ns[++nn]=newno; nc[nn]=rest; os[++on]=oldno; oc[on]=rest } oldno++; newno++ }
  else if(c=="+"){ if(rest!=""){ ns[++nn]=newno; nc[nn]=rest } newno++ }
  else if(c=="-"){ if(rest!=""){ os[++on]=oldno; oc[on]=rest } oldno++ }
  # '\' (no newline at EOF) and anything else: ignore
}
function search(cnt, contentArr, lineArr,   i,j,ok){
  if(sn==0 || cnt<sn) return 0
  for(i=1;i<=cnt-sn+1;i++){
    ok=1
    for(j=0;j<sn;j++){ if(contentArr[i+j]!=sp[j+1]){ ok=0; break } }
    if(ok){ mstart=lineArr[i]; mend=lineArr[i+sn-1]; return 1 }
  }
  return 0
}
END{
  if(search(nn,nc,ns)){ print "resolved", mstart, mend, "new"; exit }
  if(search(on,oc,os)){ print "resolved", mstart, mend, "old"; exit }
  print "unresolved", 0, 0, "none"
}
AWK

# Walk findings, anchor each, reassemble preserving order + non-findings keys.
findings_jsonl="$tmp_dir/anchored.jsonl"
: > "$findings_jsonl"
while IFS= read -r f; do
  file="$(jq -r '.file // ""' <<<"$f")"
  printf '%s' "$(jq -r '.snippet // ""' <<<"$f")" > "$tmp_dir/snip.txt"
  res="unresolved"; start=0; end=0; side="none"
  if [[ -n "$file" && -s "$tmp_dir/snip.txt" ]]; then
    read -r res start end side < <(TARGET="$file" awk -v snipfile="$tmp_dir/snip.txt" -f "$awk_prog" "$diff_path")
  fi
  resolved=false; [[ "$res" == "resolved" ]] && resolved=true
  jq -c \
    --argjson resolved "$resolved" \
    --argjson start "${start:-0}" \
    --argjson end "${end:-0}" \
    --arg side "${side:-none}" \
    '
    .anchor = {resolved: $resolved, start_line: $start, end_line: $end, side: $side}
    | if $resolved and $start > 0
      then (.line_claimed = (.line // null)) | (.line = $start)
      else . end
    ' <<<"$f" >> "$findings_jsonl"
done < <(jq -c '.findings[]' "$findings")

# Rebuild the top-level object: keep original keys, replace findings array.
jq -s \
  --slurpfile orig "$findings" \
  '{findings: .} as $new | ($orig[0] + $new)' \
  "$findings_jsonl" > "$out"

resolved_n="$(jq '[.findings[] | select(.anchor.resolved)] | length' "$out")"
total_n="$(jq '.findings | length' "$out")"
echo "anchor: $resolved_n/$total_n findings anchored to the diff ($(( total_n - resolved_n )) unresolved/flagged)" >&2
