#!/usr/bin/env bash
# test_post_comment_paths.sh — a path-scoped record never clears a merge.
#
# Why this exists: `--paths` reviews part of a diff. post_comment.sh marked such
# a record with a visible Scope line and a `paths=<hash>` marker token, and
# neither gate reads either one. Both gates pick a record by the
# `<!-- cross-review: sha=<40> ` marker or the prose "Reviewed `<sha>`" and
# clear the merge when that sha is the head — so a CLEAN round over two
# directories read as a review of the whole PR.
#
# The rule pinned here is enforced where the record is WRITTEN, so it also
# holds for gates that predate `--paths` (other repos carry their own copy of
# ci/cross-review-currency.sh):
#   - a scoped record that could clear something (CLEAN, FIXES_APPLIED, or no
#     verdict) carries neither stamp form, so no gate sees it as a record;
#   - it therefore neither clears a merge nor hides the full-diff records;
#   - a scoped record that can only withhold a merge (BLOCKED, NEEDS_DECISION)
#     keeps the ordinary stamps and still reads as `pending` at the head;
#   - full-diff records are byte-for-byte what they were;
#   - scoped records still count when the next pass number is derived.
#
# The assertions run the REAL gates (read_stamp.sh, merge_preflight.sh,
# currency_verdict) over bodies the REAL post_comment.sh produced.
#
# Offline: gh is a PATH shim. Standalone, or auto-discovered by run_tests.sh.
# Run:  bash tests/test_post_comment_paths.sh   ·   Exit: 0 all green, 1 any failure.
set -uo pipefail
SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
S="$SKILL_DIR/scripts"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
PASS=0; FAIL=0
ok()  { echo "  ok   $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL $1"; FAIL=$((FAIL + 1)); }
assert_eq() { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 (got: '$2' want: '$3')"; fi; }
assert_contains() { if [[ "$2" == *"$3"* ]]; then ok "$1"; else bad "$1 (no '$3' in: ${2:0:200})"; fi; }
assert_not_contains() { if [[ "$2" != *"$3"* ]]; then ok "$1"; else bad "$1 (unexpectedly found '$3')"; fi; }

command -v jq >/dev/null 2>&1 || { echo "  skip post_comment paths (jq unavailable)"; exit 0; }

# gh shim. `auth status` succeeds, `pr comment` captures the body, and every
# other call answers from the PR fixture — through --jq when the caller passed
# one, as the real gh does (post_comment.sh derives the pass number that way).
mkdir -p "$T/bin"
cat >"$T/bin/gh" <<'SH'
#!/bin/bash
case "$1 $2" in
  "auth status") exit 0 ;;
  "pr comment")
    while [ $# -gt 0 ]; do
      if [ "$1" = "--body-file" ]; then cp "$2" "$CR_TEST_CAPTURE"; fi
      shift
    done
    exit 0 ;;
esac
jqx=""
while [ $# -gt 0 ]; do
  if [ "$1" = "--jq" ]; then jqx="${2:-}"; fi
  shift
done
if [ -n "$jqx" ]; then jq -r "$jqx" "$CR_TEST_FIXTURE"; else cat "$CR_TEST_FIXTURE"; fi
SH
chmod +x "$T/bin/gh"
export PATH="$T/bin:$PATH"
export CR_TEST_CAPTURE="$T/capture.md"
export CR_TEST_FIXTURE="$T/fixture.json"

H='399df23d4d5945162d0c5ed623484d608337165d'
OLD='b813773500000000000000000000000000000000'
PH='0123456789ab'

# What a gate selects a record on: the union of merge_preflight.sh's STAMP_RE
# and ci/cross-review-currency.sh's CR_MARKER_RE / CR_STAMP_RE.
GATE_RE='(<!-- cross-review: sha=[0-9a-f]{40}|Reviewed (at )?`[0-9a-f]{7,40}`)'
gate_stamps() { grep -cE "$GATE_RE" <<<"$1" || true; }

pr_json() {  # pr_json <head> <body>... → the gh pr view fixture, oldest first
  local head="$1"; shift
  local c="[]" b
  for b in "$@"; do c="$(jq -c --arg b "$b" '. + [{body:$b}]' <<<"$c")"; done
  jq -nc --arg h "$head" --argjson c "$c" \
    '{headRefOid:$h, state:"OPEN", baseRefName:"master", number:7, url:"https://github.com/o/r/pull/7", comments:$c}'
}
full() {  # full <sha> <verdict> → a full-diff record body, as the gate tests write one
  printf '## Cross-review — pass 1\n<!-- cross-review: sha=%s pass=1 verdict=%s -->\nFindings below.\n' "$1" "$2"
}
mkrun() {  # mkrun <name> <scoped|full> → a run dir; scoped ones carry the --paths context
  local d="$T/runs/$1"; mkdir -p "$d"
  printf '# findings\n\nnothing to report\n' >"$d/findings.md"
  if [[ "$2" == "scoped" ]]; then
    printf '{"paths":["apps/web/","docs/"],"paths_hash":"%s","paths_mode":"filtered"}\n' "$PH" >"$d/context.json"
  fi
  printf '%s' "$d"
}
post() {  # post <run-dir> [post_comment args…] → the posted body on stdout
  local d="$1"; shift
  : >"$CR_TEST_CAPTURE"
  bash "$S/post_comment.sh" --pr 7 --mode summary --findings "$d/findings.md" --head-sha "$H" "$@" >/dev/null 2>"$T/err"
  cat "$CR_TEST_CAPTURE"
}
stamped() { printf '%s' "$1" | bash "$S/read_stamp.sh" --body-stdin 2>/dev/null | jq -r '.stamped'; }
pf() {  # pf <head> <body>... → merge_preflight's "<status> <rc>" for that PR
  pr_json "$@" >"$CR_TEST_FIXTURE"
  local out rc
  out="$(cd "$T" && bash "$S/merge_preflight.sh" --pr 7 --json 2>/dev/null)"; rc=$?
  printf '%s %s' "$(jq -r '.status // ""' <<<"$out" 2>/dev/null)" "$rc"
}
cv() {  # cv <body>... → the currency CI state for a PR at head $H with those comments
  local c="[]" b
  for b in "$@"; do c="$(jq -c --arg b "$b" '. + [{body:$b, user:"o", assoc:"OWNER"}]' <<<"$c")"; done
  # shellcheck disable=SC1091
  ( source "$SKILL_DIR/ci/cross-review-currency.sh"; currency_verdict "$c" "$H" "" ) | cut -f1
}

SCOPED="$(mkrun scoped scoped)"
FULL="$(mkrun full full)"
pr_json "$H" >"$CR_TEST_FIXTURE"

echo "── a scoped record that could clear something is off the gate ──"
for v in CLEAN FIXES_APPLIED none; do
  pr_json "$H" >"$CR_TEST_FIXTURE"
  if [[ "$v" == "none" ]]; then body="$(post "$SCOPED")"; else body="$(post "$SCOPED" --verdict "$v")"; fi
  assert_contains "[$v] the record is posted under the usual header" "$body" "## Cross-review — pass "
  assert_eq "[$v] it carries no stamp a gate selects on" "$(gate_stamps "$body")" "0"
  m="$(grep -o '<!-- cross-review-scoped: [^>]*-->' <<<"$body" | head -1)"
  assert_contains "[$v] its marker is the scoped one, same fields" "$m" "<!-- cross-review-scoped: sha=$H pass="
  assert_contains "[$v] …ending in the paths hash" "$m" " paths=$PH -->"
  [[ "$v" != "none" ]] && assert_contains "[$v] …and keeping the verdict" "$m" " verdict=$v "
  assert_contains "[$v] the prose names the sha without the gate's phrasing" "$body" "Path-scoped review of \`${H:0:9}\`"
  assert_contains "[$v] the Scope line says what was reviewed" "$body" "only changes in \`apps/web/\`, \`docs/\` were reviewed"
  assert_contains "[$v] …and that it does not count toward the gate" "$body" "does not count toward the merge gate"
  assert_eq "[$v] read_stamp.sh sees no stamp" "$(stamped "$body")" "false"
  assert_not_contains "[$v] merge_preflight does not clear on it alone" "$(pf "$H" "$body")" "clear"
  assert_eq "[$v] the currency CI does not pass on it alone" "$(cv "$body")" "failure"
  [[ "$v" == "CLEAN" ]] && SC_CLEAN="$body"
done

echo "── …so it neither hides nor outvotes the full-diff records ──"
assert_eq "a stale full-diff record stays stale behind a scoped CLEAN at the head (preflight)" \
  "$(pf "$H" "$(full "$OLD" CLEAN)" "$SC_CLEAN")" "stale 1"
assert_eq "…and the currency CI still fails" "$(cv "$(full "$OLD" CLEAN)" "$SC_CLEAN")" "failure"
assert_eq "a full-diff BLOCKED at the head stays pending behind a scoped CLEAN (preflight)" \
  "$(pf "$H" "$(full "$H" BLOCKED)" "$SC_CLEAN")" "pending 1"
assert_eq "…and in the currency CI" "$(cv "$(full "$H" BLOCKED)" "$SC_CLEAN")" "pending"
assert_eq "control: a full-diff CLEAN at the head still clears with a scoped record after it (preflight)" \
  "$(pf "$H" "$(full "$H" CLEAN)" "$SC_CLEAN")" "clear 0"
assert_eq "…and in the currency CI" "$(cv "$(full "$H" CLEAN)" "$SC_CLEAN")" "success"

echo "── a scoped round that found something still withholds the merge ──"
for v in BLOCKED NEEDS_DECISION; do
  pr_json "$H" >"$CR_TEST_FIXTURE"
  body="$(post "$SCOPED" --verdict "$v")"
  m="$(grep -o '<!-- cross-review: [^>]*-->' <<<"$body" | head -1)"
  assert_contains "[$v] the ordinary marker, with verdict and paths" "$m" " verdict=$v paths=$PH -->"
  assert_contains "[$v] …on the byte-stable sha/pass prefix" "$m" "<!-- cross-review: sha=$H pass="
  assert_contains "[$v] the ordinary prose stamp" "$body" "Reviewed \`${H:0:9}\`"
  assert_contains "[$v] the Scope line is still there" "$body" "NOT a review of the whole diff"
  assert_not_contains "[$v] …without the off-the-gate sentence" "$body" "does not count toward the merge gate"
  assert_eq "[$v] alone at the head it is pending (preflight)" "$(pf "$H" "$body")" "pending 1"
  assert_eq "[$v] after a full-diff CLEAN at the same head it is pending (preflight)" \
    "$(pf "$H" "$(full "$H" CLEAN)" "$body")" "pending 1"
  assert_eq "[$v] …and in the currency CI" "$(cv "$(full "$H" CLEAN)" "$body")" "pending"
done

echo "── full-diff records are unchanged ──"
pr_json "$H" >"$CR_TEST_FIXTURE"
body="$(post "$FULL" --verdict CLEAN)"
assert_contains "the ordinary marker" "$(grep -o '<!-- cross-review: [^>]*-->' <<<"$body" | head -1)" "<!-- cross-review: sha=$H pass=1 verdict=CLEAN -->"
assert_contains "the ordinary prose stamp" "$body" "Reviewed \`${H:0:9}\`."
assert_not_contains "no Scope line" "$body" "Scope:"
assert_not_contains "no scoped marker" "$body" "cross-review-scoped"
assert_eq "it clears at the head (preflight)" "$(pf "$H" "$body")" "clear 0"

echo "── the stale-head banner does not smuggle the gate's phrasing back in ──"
pr_json "$OLD" >"$CR_TEST_FIXTURE"   # the PR head moved while the scoped round ran
body="$(post "$SCOPED" --verdict CLEAN)"
assert_contains "the banner is there" "$body" "Stale: the head moved during this review."
assert_eq "…and the record still carries no stamp a gate selects on" "$(gate_stamps "$body")" "0"
pr_json "$OLD" >"$CR_TEST_FIXTURE"
body="$(post "$FULL" --verdict CLEAN)"
assert_contains "control: a full-diff record's banner keeps its wording" "$body" "Reviewed \`${H:0:9}\`, current head is \`${OLD:0:9}\`"

echo "── scoped records still count toward the next pass number ──"
prior_scoped="$(printf '## Cross-review — pass 3\n\n<!-- cross-review-scoped: sha=%s pass=3 verdict=CLEAN paths=%s -->\n' "$OLD" "$PH")"
pr_json "$H" "$(full "$OLD" CLEAN)" "$prior_scoped" >"$CR_TEST_FIXTURE"
body="$(post "$FULL" --verdict CLEAN)"
assert_contains "the pass after a scoped pass 3 is pass 4" "$body" "## Cross-review — pass 4"
assert_contains "…in the marker too" "$body" "<!-- cross-review: sha=$H pass=4 "

echo
echo "══ $PASS passed, $FAIL failed ══"
[[ "$FAIL" -eq 0 ]]
