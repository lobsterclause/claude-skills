#!/usr/bin/env bash
# test_post_comment_verdict.sh — offline fixture tests for post_comment.sh
# --verdict (kindred-mama-ai#3736).
#
# Why this exists: the record's marker used to carry only the reviewed sha, so
# a FIXES_APPLIED record — fixes written in response to findings, not yet
# themselves reviewed — read as a clean review to any consumer that only asked
# "is the sha current". kindred-mama-ai's currency gate reads `verdict=` to
# tell the two apart, so the field has to be emitted, and emitting it must not
# disturb the byte-stable `sha=<40> pass=<n>` prefix every parser matches.
#
# Standalone: run directly, or from run_tests.sh (auto-discovered via
# tests/test_*.sh). NO network — `gh` is a PATH shim that captures the body.
#
# Run:  bash tests/test_post_comment_verdict.sh
# Exit: 0 all green, 1 any failure.

set -uo pipefail

SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
S="$SKILL_DIR/scripts"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

PASS=0
FAIL=0
ok()  { echo "  ok   $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL $1"; FAIL=$((FAIL + 1)); }
assert_eq() {
  if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 (got: '$2' want: '$3')"; fi
}
assert_contains() {
  if [[ "$2" == *"$3"* ]]; then ok "$1"; else bad "$1 (no '$3' in output)"; fi
}
assert_not_contains() {
  if [[ "$2" != *"$3"* ]]; then ok "$1"; else bad "$1 (unexpectedly found '$3')"; fi
}

mkdir -p "$T/bin"
cat >"$T/bin/gh" <<'SH'
#!/bin/bash
case "$1 $2" in
  "auth status") exit 0 ;;
  "pr view") printf '%s\n' '{"headRefOid":"b6d36bd1ed33bd8162d1a03bd856ef32305c0933","state":"OPEN"}'; exit 0 ;;
  "pr comment")
      while [ $# -gt 0 ]; do
        if [ "$1" = "--body-file" ]; then cp "$2" "$CR_TEST_CAPTURE"; fi
        shift
      done
      exit 0 ;;
esac
exit 0
SH
chmod +x "$T/bin/gh"
export PATH="$T/bin:$PATH"
export CR_TEST_CAPTURE="$T/capture.md"

FIND="$T/findings.md"
printf '# findings\n\nnothing to report\n' >"$FIND"
SHA=b6d36bd1ed33bd8162d1a03bd856ef32305c0933

# pc <args...> — post a record; leaves the body in $CR_TEST_CAPTURE and the
# stderr in $T/err. Returns post_comment's exit status.
pc() {
  : >"$CR_TEST_CAPTURE"
  bash "$S/post_comment.sh" --pr 183 --mode summary --findings "$FIND" \
    --head-sha "$SHA" "$@" >/dev/null 2>"$T/err"
}
marker() { grep -o '<!-- cross-review: [^>]*-->' "$CR_TEST_CAPTURE" | head -1; }

echo "── post_comment --verdict ──"

for v in CLEAN FIXES_APPLIED NEEDS_DECISION BLOCKED; do
  pc --verdict "$v"
  assert_contains "verdict $v reaches the marker" "$(marker)" " verdict=$v -->"
done

# The prefix is what CR_MARKER_RE and read_stamp.sh match on; a verdict that
# displaced it would turn every new record into an unreadable one.
pc --verdict FIXES_APPLIED
if [[ "$(marker)" =~ ^\<\!--\ cross-review:\ sha=$SHA\ pass=[0-9]+\  ]]; then
  ok "the sha=/pass= prefix is unchanged with a verdict"
else
  bad "sha/pass prefix disturbed: $(marker)"
fi

# Additive and best-effort: an unknown value posts the record without the
# field, and says so, rather than failing the round it ends.
pc --verdict clean-ish; rc=$?
assert_eq "an unknown verdict still posts (exit 0)" "$rc" "0"
assert_contains "…the record is posted" "$(marker)" "sha=$SHA"
assert_not_contains "…without a verdict field" "$(marker)" "verdict="
assert_contains "…and warns about the dropped value" "$(cat "$T/err")" "--verdict 'clean-ish'"

# Existing callers pass no verdict and must get exactly the old marker.
pc
assert_contains "no --verdict still stamps the record" "$(marker)" "sha=$SHA"
assert_not_contains "…with no verdict field" "$(marker)" "verdict="

# A flag with no value is a usage error, like every other valued flag.
bash "$S/post_comment.sh" --pr 183 --mode summary --findings "$FIND" --verdict >/dev/null 2>&1
assert_eq "--verdict with no value is a usage error (exit 2)" "$?" "2"

echo
echo "══ $PASS passed, $FAIL failed ══"
[[ "$FAIL" -eq 0 ]]
