#!/usr/bin/env bash
# test_agy_model_pin.sh — the antigravity model pin lives in ONE place
# (references/reviewer_profiles.json); every other copy must agree with it.
#
# Why this exists: agy stopped listing Gemini 3.7 Flash while the profile
# still pinned it, and every antigravity lap failed with "model ... is not
# recognized". The shared install was fixed by hand in the profile alone, which
# left the fallback literals in factcheck_findings.sh / grade_planted.sh and
# the seat's OpenRouter fallback slug on the old model. A literal fallback that
# disagrees with the profile is only exercised when the profile cannot be read
# — exactly when nobody is looking — so it is pinned here instead.
#
# Run:  bash tests/test_agy_model_pin.sh   ·   Exit: 0 all green, 1 any failure.

set -uo pipefail

SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
S="$SKILL_DIR/scripts"
PROFILE="$SKILL_DIR/references/reviewer_profiles.json"

PASS=0
FAIL=0
ok()  { echo "  ok   $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL $1"; FAIL=$((FAIL + 1)); }
assert_eq() {
  if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 (got: '$2' want: '$3')"; fi
}

if ! command -v jq >/dev/null 2>&1; then
  echo "  skip agy model pin (jq unavailable)"; exit 0
fi

echo "── antigravity model pin ──"

pin="$(jq -r '.antigravity.model' "$PROFILE")"
[[ "$pin" =~ ^Gemini\ [0-9.]+\ Flash\ \(High\)$ ]] \
  && ok "profile pins a Gemini Flash (High) display name ($pin)" \
  || bad "profile pin has an unexpected shape: '$pin'"

# The literal each script falls back to when the profile is unreadable.
fallback_literal() {
  sed -n "s/^ *: \"\\\${$2:=\\(.*\\)}\"$/\\1/p" "$S/$1" | head -1
}
assert_eq "factcheck_findings.sh fallback literal matches the profile" \
  "$(fallback_literal factcheck_findings.sh agy_default_model)" "$pin"
assert_eq "grade_planted.sh fallback literal matches the profile" \
  "$(fallback_literal grade_planted.sh agy_judge_model)" "$pin"

# The fallback re-runs the SAME model over OpenRouter (SKILL.md, fallback
# policy), so its slug must name the same Gemini version.
ver="$(sed -E 's/^Gemini ([0-9.]+) Flash.*/\1/' <<<"$pin")"
assert_eq "the OpenRouter fallback runs the same Gemini version" \
  "$(jq -r '.antigravity.or_fallback.model' "$PROFILE")" "google/gemini-${ver}-flash"

# The seat's own prose says which --model it passes; it must not name another.
notes="$(jq -r '.antigravity.notes' "$PROFILE")"
[[ "$notes" == *"--model \\\"$pin\\\""* || "$notes" == *"--model \"$pin\""* ]] \
  && ok "the seat's notes name the pinned --model" \
  || bad "the seat's notes name a different --model than '$pin'"

echo
echo "══ $PASS passed, $FAIL failed ══"
[[ "$FAIL" -eq 0 ]]
