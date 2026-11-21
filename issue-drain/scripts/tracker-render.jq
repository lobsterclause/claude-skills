# tracker-render.jq — the session's decisions, held against the checked
# verdicts, become the queue and the tracker body. Run by tracker.sh render.
#
# Input: decisions.json
# --slurpfile intake, checked    intake.json, verdicts.checked.json
# --arg run repo base base_sha perms prot models efforts; --argjson max_issues
# Output: { errors: [string], title, queue: {...}, md }
# If errors is not empty, tracker.sh writes nothing.

# Text that came from an issue (a title, a reader's reason) is shown, never
# trusted: one line, no control or invisible characters, nothing that opens an
# HTML comment, a code span or a link, and no "@name" that would notify someone.
def clean($max):
  tostring
  | gsub("[\\p{Cc}\\p{Cf}]+"; " ") | gsub("\\s+"; " ") | sub("^ "; "") | sub(" $"; "")
  | gsub("<"; "&lt;") | gsub("`"; "'") | gsub("\\["; "\\[") | gsub("@"; "@​")
  | if length > $max then .[0:$max] + "..." else . end;
def code($max):
  tostring | gsub("[\\p{Cc}\\p{Cf}]+"; " ") | gsub("`"; "'")
  | (if length > $max then .[0:$max] + "..." else . end) | "`" + . + "`";
def both($a; $b): $a - ($a - $b);
def rank: {"S": 0, "M": 1, "L": 2, "XL": 3}[(.size // "") | tostring] // 3;
def hashes: map("#\(.)") | join(" ");
def count($n; $word): "\($n) \($word)" + (if $n == 1 then "" else "s" end);
def section($title; $intro; $lines):
  if ($lines | length) == 0 then []
  else [ "", "## " + $title, "" ] + (if $intro == "" then [] else [ $intro, "" ] end) + $lines end;
# Units that share a file run back to back: place a unit, then pull the later
# units that touch one of its files up behind it.
def adjacent_order:
  { out: [], rem: . }
  | until((.rem | length) == 0;
      .rem[0] as $x
      | [ .rem[1:][] | select((both(.files; $x.files) | length) > 0) ] as $friends
      | .out += [ $x ] + $friends
      | .rem = (.rem[1:] - $friends))
  | .out;

. as $d
| $intake[0] as $in
| ($in.eligible | map({ key: (.number | tostring), value: . }) | from_entries) as $el
| ($checked[0] | map({ key: (.number | tostring), value: . }) | from_entries) as $ck
| ($models | split(" ")) as $models_ok
| ($efforts | split(" ")) as $efforts_ok
| [ ($d.confirmed_closures // [])[] | if type == "number" then { number: ., note: "" } else . end | select(type == "object") ] as $conf
| [ ($d.left_out // [])[] | select(type == "object") ] as $left

| [ ($d.units // [])[] | select(type == "object") | . as $u
    | ([ ($u.issues // [])[] | select(type == "number") ] | unique) as $is
    | [ $is[] | $ck[tostring] | select(. != null) ] as $vs
    | (if ($u.acceptance | type) == "object" then $u.acceptance else {} end) as $acc
    | $u + {
        issues: $is,
        title: ($u.title // "" | tostring),
        files: ( (if ($u.files | type) == "array" then [ $u.files[] | select(type == "string") ] else [ $vs[] | .files[]? ] end) | unique ),
        size: ($u.size // ([ $vs[] | select(.status == "live") ] | max_by(rank) | .size) // "M"),
        kind: ($u.kind // ([ $vs[] | select(.status == "live") | .change_kind ] | first) // "bugfix"),
        acceptance: ([ $is[] | tostring as $k | { key: $k, value: ($acc[$k] // $ck[$k].acceptance // "" | tostring) } ] | from_entries),
        reuse: ([ $vs[] | .reuse[]? | "\(.file):\(.line)" ] | unique),
        risk: ([ $vs[] | .risk ] | any),
        risk_paths: ([ $vs[] | .risk_paths[]? ] | unique),
        priority: ([ $is[] | $el[tostring].priority // 99 ] | min // 99),
        live: [ $vs[] | select(.status == "live") | .number ] } ] as $units

| ( [ $units | to_entries[] | .value as $u | "unit \(.key + 1) (\($u.title | clean(60)))" as $name
      | ( if ($u.issues | length) == 0 then "\($name): names no issue" else empty end ),
        ( if ($u.issues | length) > $max_issues then "\($name): \($u.issues | length) issues in one unit; the cap is \($max_issues)" else empty end ),
        ( $u.issues[] | . as $n | $ck[tostring] as $v
          | if $v == null then "\($name): #\($n) was not taken in by this run"
            elif $v.status == "live" then empty
            elif $v.status == "duplicate_of" and (($u.issues | index($v.duplicate_of)) != null) then empty
            elif $v.status == "duplicate_of" then "\($name): #\($n) duplicates #\($v.duplicate_of), which is not in this unit"
            else "\($name): #\($n) is \($v.status), not live" end ),
        ( if $u.risk and ($u.live | length) > 1 then "\($name): touches a risk path (\($u.risk_paths | join(", "))) and has more than one live issue; a risk-path issue shares a unit only with its own duplicates" else empty end ),
        ( if $u.risk and (($u.waits_for // "" | tostring) == "") then "\($name): touches a risk path (\($u.risk_paths | join(", "))); name who reviews its PR in waits_for" else empty end ),
        ( $u.files[] | select($prot != "" and test($prot; "i")) | "\($name): names a protected path (\(.)); that work needs a person" ),
        ( if $u.title == "" then "\($name): no title" else empty end ),
        ( if ($models_ok | index($u.model // "")) == null then "\($name): model must be one of \($models) (got \($u.model // "none"))" else empty end ),
        ( if ($efforts_ok | index($u.effort // "")) == null then "\($name): effort must be one of \($efforts) (got \($u.effort // "none"))" else empty end ),
        ( if (($u.est_minutes | type) != "number") or $u.est_minutes <= 0 then "\($name): est_minutes must be a number above 0" else empty end ),
        ( if ([ "S", "M", "L", "XL" ] | index($u.size)) == null then "\($name): size must be S, M, L or XL" else empty end ),
        ( if (($u.test_command // "" | tostring) | test("^[^\\n\\r]+$") | not) then "\($name): test_command must be one non-empty line" else empty end ),
        ( $u.issues[] | tostring as $k | select($ck[$k] != null and $u.acceptance[$k] == "") | "\($name): no acceptance check for #\($k)" ) ]
    + [ [ $units | to_entries[] | .key as $i | .value.issues[] | { n: ., i: $i } ] | group_by(.n)[] | select(length > 1) | "#\(.[0].n) is in more than one unit" ]
    + [ $conf[] | .number as $n | $ck[$n | tostring] as $v
        | if $v == null then "closure #\($n): not taken in by this run"
          elif $v.status != "already_fixed" then "closure #\($n): it is \($v.status), not already_fixed"
          elif ($v.closable | not) then "closure #\($n): the bug is behavioural, so a code reading cannot close it"
          else empty end ]
    + ( [ $units[].issues[] ] as $queued
        | [ $checked[0][] | select(.status == "live" or .status == "duplicate_of") | .number as $n
            | ( [ $left[] | select(.number == $n and ((.reason // "" | tostring) != "")) ] | length > 0 ) as $excused
            | if (($queued | index($n)) != null) and $excused then "#\($n) is both in a unit and in left_out"
              elif (($queued | index($n)) == null) and ($excused | not) then "#\($n) is \(.status) but in no unit; queue it, or give the reason in left_out"
              else empty end ] )
    + [ $left[] | select(((.number | type) != "number") or ($ck[.number | tostring] == null))
        | "left_out names #\(.number // "nothing"), which this run did not take in" ]
  ) as $errors

| ($units | sort_by([ .priority, rank, (.issues | min // 0) ])) as $sorted
| ( [ ([ $sorted[] | select(.risk | not) ] | adjacent_order)[], ($sorted[] | select(.risk)) ]
    | to_entries | map(.value + { id: "U\(.key + 1)", waits: .value.risk }) ) as $all
| [ $conf[] | .number as $n | $ck[$n | tostring] as $v
    | select($v != null and $v.status == "already_fixed" and $v.closable)
    | { number: $n, title: ($el[$n | tostring].title // ""), fix_commit: $v.fix_commit,
        pr: ( [ $v.fix_commit.subject | capture("\\(#(?<pr>[0-9]+)\\)\\s*$").pr | tonumber ] | first ),
        evidence: [ $v.evidence[] | { file, line, quote } ], note: (.note // "" | tostring) } ] as $closures
| [ $in.stale_claims[]? ] as $stale

| def title_of($n): ($el[$n | tostring].title // "") | clean(100);
  def unit_line: "\(.id) · \(.issues | hashes) · \(.title | clean(100)) · \(.model)/\(.effort) · ~\(.est_minutes) min";
  def info($n; $why): "- #\($n) · \(title_of($n)) · \($why | clean(240))";
  ( [ "<!-- issue-drain:tracker v1 run=\($run) -->",
      "This is the queue for an issue drain of `\($repo)` into `\($base)`. Nothing has been changed yet: no issue is claimed, labelled or closed until you say go.",
      "",
      "To change what runs, edit this body:",
      "",
      "- Delete a line under **Queue** to drop that unit. Move lines to reorder them.",
      "- Tick a box to approve that item. An unticked box means no.",
      "- Put the word `STOP` on a line of its own, anywhere in this body, to stop the drain once the unit in progress has finished.",
      "",
      "The drain reads this body at the start of each unit and never edits it. Progress is posted as comments.",
      "",
      "Base `\($base)` at `\($base_sha[0:7])` · \($in.eligible | length) issues taken in · \($all | length) units · permissions: \($perms | clean(200))",
      "",
      "## Queue",
      "" ]
    + ( [ $all[] | select(.waits | not) | "- " + unit_line + " · " + (.test_command | code(160)) ]
        | if length == 0 then [ "No units." ] else . end )
    + section("Close as already fixed (tick to approve)";
        "Each was read twice against the base branch. The closing comment quotes the lines and names the fixing commit.";
        [ $closures[] | "- [ ] close #\(.number) · \(.title | clean(100)) · fixed by `\(.fix_commit.sha[0:7])`"
            + (if .pr then " (#\(.pr))" else "" end)
            + " · " + ("\(.fix_commit.file):\(.fix_commit.line)" | code(160))
            + (if .note == "" then "" else " · " + (.note | clean(200)) end) ])
    + section("Units that open a PR and then wait for a person (tick to include)";
        "Each touches a path that needs a named reviewer. A ticked unit runs before the queue, opens its PR and waits there, so the review can start while the rest drains.";
        [ $all[] | select(.waits) | "- [ ] " + unit_line + " · waits for: " + (.waits_for | clean(80)) + " · " + (.test_command | code(160)) ])
    + section("Stale claims (tick to release)";
        "These carry the claim label and have no open PR. Releasing one removes the label and nothing else.";
        [ $stale[] | "- [ ] release #\(.number) · \(.title // "" | clean(100)) · "
            + (if .days == null then "claim age unknown" else "claimed \(.days) days ago" end) + ", no open PR" ])
    + section("Needs a person"; "";
        [ $checked[0][] | select(.status == "needs_human") | info(.number; .downgrade_reason // .reason // "no reason given") ])
    + section("Needs verification"; "Code that looks like the fix is on the base branch, but nothing here closes these.";
        [ $checked[0][] | select(.status == "already_fixed") | .number as $n | select(([ $closures[].number ] | index($n)) == null)
          | info($n; "looks fixed by " + (.fix_commit.sha[0:7]) + " (" + .fix_commit.subject + "). "
              + (if .closable then "Not confirmed on a second read." else "The bug is behavioural, so it needs a look in the running app." end)) ])
    + section("Unclear"; "";
        [ $checked[0][] | select(.status == "unclear") | info(.number; .downgrade_reason // .reason // "no reason given") ])
    + section("Not queued"; "";
        [ $left[] | select((.number | type) == "number") | info(.number; .reason // "no reason given") ])
    + section("Skipped at intake"; "";
        [ $in.skipped[]? | "- #\(.number) · \(.title // "" | clean(100)) · \(.reason | clean(240))" ])
    + ( if ($all | length) == 0 then [] else
          [ "", "<details><summary>Acceptance checks, files and reuse for each unit</summary>", "" ]
          + [ $all[] | . as $u
              | "**\(.id)** · \(.issues | hashes) · \(.kind | clean(20)) · size \(.size)",
                "",
                ( .issues[] | "- #\(.): \($u.acceptance[tostring] | clean(300))" ),
                ( if (.files | length) > 0 then "- files: " + (.files | map(code(160)) | join(", ")) else empty end ),
                ( if (.reuse | length) > 0 then "- reuse: " + (.reuse | map(code(160)) | join(", ")) else empty end ),
                "" ]
          + [ "</details>" ] end )
    | join("\n") + "\n" ) as $md

| { errors: ( $errors + (if ($md | length) > 65000 then [ "the tracker body is \($md | length) characters; GitHub allows 65536. Take fewer issues in one run" ] else [] end) ),
    title: "issue-drain: \(count($all | length; "unit")) and \(count($closures | length; "closure")) from \(count($in.eligible | length; "issue")) (\($run))",
    queue: { version: 1, run: $run, repo: $repo, base: $base, base_sha: $base_sha,
             units: [ $all[] | { id, issues, live, title, kind, size, model, effort, est_minutes, test_command, files,
                                 acceptance, reuse, risk, risk_paths, waits, waits_for: (.waits_for // null), priority } ],
             closures: $closures,
             stale_claims: $stale },
    md: $md }
