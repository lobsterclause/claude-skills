#!/usr/bin/env bash
# test_fix_safety.sh — standalone offline fixture test for
# scripts/verify_fix_safety.sh. NO network, no reviewer CLIs, no tokens.
#
# Mirrors run_tests.sh's fixture/assertion conventions (assert_eq/assert_contains,
# mktemp -d + trap cleanup) but is intentionally NOT wired into run_tests.sh by
# hand — see the "standalone suites" loop, which folds this file in by name.
#
# Run:  bash tests/test_fix_safety.sh
# Exit: 0 all green, 1 any failure.

set -uo pipefail

SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
S="$SKILL_DIR/scripts/verify_fix_safety.sh"
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

command -v jq >/dev/null 2>&1 || { echo "jq required to run these tests" >&2; exit 1; }

if [[ ! -x "$S" ]]; then
  echo "  (expected pre-implementation) verify_fix_safety.sh not found/executable at $S" >&2
fi

# ── Case 1: a suggested "fix" removes an auth guard ─────────────────────────
# This is the exact laundering shape the gate exists to catch: a plausible
# "this check is redundant" cleanup that actually deletes an authorization
# guard. Must come back safe:false.
UNSAFE_DIFF="$T/unsafe.diff"
cat >"$UNSAFE_DIFF" <<'EOF'
diff --git a/src/handler.ts b/src/handler.ts
index 1111111..2222222 100644
--- a/src/handler.ts
+++ b/src/handler.ts
@@ -10,9 +10,7 @@ export function handleRequest(req: Request, user: User) {
   const payload = parseBody(req);

-  if (!authorized(user, payload.resourceId)) {
-    throw new Error('Unauthorized');
-  }
-
   return process(payload);
 }
EOF

UNSAFE_OUT="$T/unsafe.out.json"
bash "$S" --diff "$UNSAFE_DIFF" --out "$UNSAFE_OUT" --finding-id "f-unsafe-1" >/dev/null 2>"$T/unsafe.stderr.txt"
rc=$?
assert_eq "unsafe-fix run exits 0 (verdict lives in JSON, not exit code)" "$rc" "0"
assert_eq "auth guard removal -> safe:false" "$(jq -r '.safe' "$UNSAFE_OUT")" "false"
assert_contains "matched categories include auth_guard_removed" "$(jq -r '.matched | join(",")' "$UNSAFE_OUT")" "auth_guard_removed"
assert_contains "reason mentions authorization" "$(jq -r '.reason' "$UNSAFE_OUT")" "authorization"
assert_eq "finding_id round-trips" "$(jq -r '.finding_id' "$UNSAFE_OUT")" "f-unsafe-1"

# ── Case 2: an innocuous fix (variable rename + typo fix) ───────────────────
# The gate must not be trivially always-false: a harmless cleanup with no
# dangerous shape must come back safe:true.
SAFE_DIFF="$T/safe.diff"
cat >"$SAFE_DIFF" <<'EOF'
diff --git a/src/format.ts b/src/format.ts
index 3333333..4444444 100644
--- a/src/format.ts
+++ b/src/format.ts
@@ -4,7 +4,7 @@ export function formatName(rawName: string): string {
-  const nm = rawName.trim();
-  // fomrat the display name
-  return nm.toUpperCase();
+  const trimmedName = rawName.trim();
+  // format the display name
+  return trimmedName.toUpperCase();
 }
EOF

SAFE_OUT="$T/safe.out.json"
bash "$S" --diff "$SAFE_DIFF" --out "$SAFE_OUT" >/dev/null 2>"$T/safe.stderr.txt"
rc=$?
assert_eq "safe-fix run exits 0" "$rc" "0"
assert_eq "variable rename + typo fix -> safe:true" "$(jq -r '.safe' "$SAFE_OUT")" "true"
assert_eq "no matched categories on innocuous fix" "$(jq -r '.matched | length' "$SAFE_OUT")" "0"
assert_eq "finding_id is null when not passed" "$(jq -r '.finding_id' "$SAFE_OUT")" "null"

# ── Case 3: validation weakened without replacement ─────────────────────────
VALID_DIFF="$T/valid.diff"
cat >"$VALID_DIFF" <<'EOF'
diff --git a/src/input.ts b/src/input.ts
index 5555555..6666666 100644
--- a/src/input.ts
+++ b/src/input.ts
@@ -2,8 +2,6 @@ export function acceptInput(raw: string): string {
-  if (!/^[a-zA-Z0-9_-]+$/.test(raw)) {
-    throw new Error('invalid input');
-  }
   return raw;
 }
EOF

VALID_OUT="$T/valid.out.json"
bash "$S" --diff "$VALID_DIFF" --out "$VALID_OUT" >/dev/null 2>"$T/valid.stderr.txt"
assert_eq "validation removed without replacement -> safe:false" "$(jq -r '.safe' "$VALID_OUT")" "false"
assert_contains "matched categories include validation_weakened" "$(jq -r '.matched | join(",")' "$VALID_OUT")" "validation_weakened"

# ── Case 4: a test is silenced with .skip() ──────────────────────────────────
SKIP_DIFF="$T/skip.diff"
cat >"$SKIP_DIFF" <<'EOF'
diff --git a/src/handler.test.ts b/src/handler.test.ts
index 7777777..8888888 100644
--- a/src/handler.test.ts
+++ b/src/handler.test.ts
@@ -1,5 +1,5 @@
-it('rejects unauthorized requests', () => {
+it.skip('rejects unauthorized requests', () => {
   expect(handle(badReq)).toThrow();
 });
EOF

SKIP_OUT="$T/skip.out.json"
bash "$S" --diff "$SKIP_DIFF" --out "$SKIP_OUT" >/dev/null 2>"$T/skip.stderr.txt"
assert_eq "test silenced with .skip() -> safe:false" "$(jq -r '.safe' "$SKIP_OUT")" "false"
assert_contains "matched categories include test_disabled" "$(jq -r '.matched | join(",")' "$SKIP_OUT")" "test_disabled"

# ── Case 5: fail-safe on ambiguity (missing diff file) ───────────────────────
MISSING_OUT="$T/missing.out.json"
bash "$S" --diff "$T/does-not-exist.diff" --out "$MISSING_OUT" >/dev/null 2>"$T/missing.stderr.txt"
assert_eq "missing diff file -> safe:false (fail-safe)" "$(jq -r '.safe' "$MISSING_OUT")" "false"

# ── Case 6: fail-safe on empty diff ──────────────────────────────────────────
EMPTY_DIFF="$T/empty.diff"
: > "$EMPTY_DIFF"
EMPTY_OUT="$T/empty.out.json"
bash "$S" --diff "$EMPTY_DIFF" --out "$EMPTY_OUT" >/dev/null 2>"$T/empty.stderr.txt"
assert_eq "empty diff -> safe:false (fail-safe)" "$(jq -r '.safe' "$EMPTY_OUT")" "false"

echo
echo "$PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
