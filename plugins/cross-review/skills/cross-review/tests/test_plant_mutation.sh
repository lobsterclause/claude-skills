#!/usr/bin/env bash
# test_plant_mutation.sh — standalone offline fixture test for
# scripts/plant_mutation.sh and references/mutation_operators.json.
# NO network, no reviewer CLIs, no tokens.
#
# Mirrors run_tests.sh's fixture/assertion conventions (assert_eq/assert_contains,
# mktemp -d + trap cleanup) but is intentionally NOT wired into run_tests.sh —
# the parent orchestrating session wires it in later (collision avoidance; see
# tests/test_digest.sh / tests/test_profiles.sh for the same pattern).
#
# Run:  bash tests/test_plant_mutation.sh
# Exit: 0 all green, 1 any failure.
#
# Portability: macOS bash 3.2 + ubuntu bash 5; needs jq, git, and a coreutils
# timeout (gtimeout on macOS via brew).

set -uo pipefail

SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
S="$SKILL_DIR/scripts"
OPERATORS="$SKILL_DIR/references/mutation_operators.json"
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
  if [[ "$2" != *"$3"* ]]; then ok "$1"; else bad "$1 (found '$3' in output)"; fi
}

# ── build a fixture git repo under $T ───────────────────────────────────────
# base commit: src/a.ts with a few unrelated lines, including one line with
# `??` that is NOT touched by the head commit's diff (must stay untouched).
mk_fixture_repo() {
  local dir="$1"
  rm -rf "$dir"
  mkdir -p "$dir/src"
  git init -q "$dir"
  git -C "$dir" config user.name "Test"
  git -C "$dir" config user.email "test@example.com"
  cat >"$dir/src/a.ts" <<'EOF'
export function existing(opts) {
  const unrelatedFallback = opts.legacy ?? "default";
  return unrelatedFallback;
}
EOF
  git -C "$dir" add src/a.ts
  git -C "$dir" commit -q -m "base"

  cat >"$dir/src/a.ts" <<'EOF'
export function existing(opts) {
  const unrelatedFallback = opts.legacy ?? "default";
  return unrelatedFallback;
}

export function updated(opts, items) {
  const timeout = opts.timeout ?? 5000;
  if (i < items.length) {
    return timeout;
  }
}
EOF
  git -C "$dir" add src/a.ts
  git -C "$dir" commit -q -m "head"
}

REPO="$T/repo"
mk_fixture_repo "$REPO"

BASE_SHA="$(git -C "$REPO" rev-parse HEAD~1)"
HEAD_SHA="$(git -C "$REPO" rev-parse HEAD)"

echo "── operators table ──"
jq -e 'length >= 8' "$OPERATORS" >/dev/null 2>&1 && ok "operators table has >= 8 entries" || bad "operators table has >= 8 entries"
missing_keys="$(jq -r '[.[] | select((has("id") and has("class") and has("description") and has("match") and has("replace") and has("expected_severity") and has("languages")) | not) | .id // "?"] | length' "$OPERATORS" 2>/dev/null || echo "err")"
assert_eq "every operator has all required keys" "$missing_keys" "0"

echo "── plant_mutation.sh (RED before implementation exists) ──"

# (a) --operator nullish --seed 1 exits 0; mutation branch diff vs head is
#     exactly one changed line, inside the added hunk; planted.json checks.
OUT_A="$T/planted-a.json"
if bash "$S/plant_mutation.sh" --repo "$REPO" --base "$BASE_SHA" --head "$HEAD_SHA" \
    --seed 1 --operator nullish --run-id mutation-test-a --out "$OUT_A" >"$T/stdout-a.log" 2>"$T/stderr-a.log"; then
  ok "plant_mutation.sh --operator nullish exits 0"
else
  bad "plant_mutation.sh --operator nullish exits 0 (exit $?, stderr: $(cat "$T/stderr-a.log" 2>/dev/null))"
fi

MUT_BRANCH_A="$(git -C "$REPO" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")"
assert_eq "left repo checked out on mutation branch" "$MUT_BRANCH_A" "mutation/mutation-test-a"

DIFF_STAT_A="$(git -C "$REPO" diff "$HEAD_SHA" --stat 2>/dev/null | tail -n 1)"
assert_contains "mutation diff touches exactly one file" "$DIFF_STAT_A" "1 file changed"
assert_contains "mutation diff changes exactly one line each way" "$DIFF_STAT_A" "1 insertion"

# The untouched `??` line (unrelatedFallback) must remain unchanged.
UNRELATED_LINE="$(git -C "$REPO" show HEAD:src/a.ts | sed -n '2p')"
assert_contains "untouched ?? line stays untouched" "$UNRELATED_LINE" "??"

if [[ -f "$OUT_A" ]]; then
  ok "planted.json written"
  assert_eq "planted.json .synthetic" "$(jq -r '.synthetic' "$OUT_A")" "true"
  assert_eq "planted.json .operator" "$(jq -r '.operator' "$OUT_A")" "nullish"
  assert_eq "planted.json .file" "$(jq -r '.file' "$OUT_A")" "src/a.ts"
  # head-side line number of the ?? line inside the diff hunk: line 7 of the
  # new file (`const timeout = opts.timeout ?? 5000;`)
  assert_eq "planted.json .line_range[0]" "$(jq -r '.line_range[0]' "$OUT_A")" "7"
  EXPECTED_SEV="$(jq -r '.[] | select(.id=="nullish") | .expected_severity' "$OPERATORS")"
  assert_eq "planted.json .expected_severity matches operators table" "$(jq -r '.expected_severity' "$OUT_A")" "$EXPECTED_SEV"
else
  bad "planted.json written"
fi

# (b) determinism: same seed into two fresh clones yields byte-identical
#     planted.json modulo mutation_sha (and any timestamp field).
REPO_B1="$T/repo-det-1"
REPO_B2="$T/repo-det-2"
mk_fixture_repo "$REPO_B1"
mk_fixture_repo "$REPO_B2"
# Commit SHAs depend on timestamps, so two freshly-built fixture repos never
# share a SHA even with identical content — derive base/head per repo.
B1_BASE="$(git -C "$REPO_B1" rev-parse HEAD~1)"
B1_HEAD="$(git -C "$REPO_B1" rev-parse HEAD)"
B2_BASE="$(git -C "$REPO_B2" rev-parse HEAD~1)"
B2_HEAD="$(git -C "$REPO_B2" rev-parse HEAD)"
OUT_B1="$T/planted-det-1.json"
OUT_B2="$T/planted-det-2.json"
bash "$S/plant_mutation.sh" --repo "$REPO_B1" --base "$B1_BASE" --head "$B1_HEAD" \
  --seed 42 --run-id mutation-det --out "$OUT_B1" >/dev/null 2>&1
assert_eq "determinism run 1 exits 0" "$?" "0"
bash "$S/plant_mutation.sh" --repo "$REPO_B2" --base "$B2_BASE" --head "$B2_HEAD" \
  --seed 42 --run-id mutation-det --out "$OUT_B2" >/dev/null 2>&1
assert_eq "determinism run 2 exits 0" "$?" "0"

if [[ -f "$OUT_B1" && -f "$OUT_B2" ]]; then
  # base/head SHAs differ across the two fixture repos (commit SHAs depend on
  # timestamps even with identical content) — compare everything else,
  # including which operator/file/line was picked.
  NORM_B1="$(jq -S 'del(.mutation_sha, .timestamp, .base, .head)' "$OUT_B1" 2>/dev/null)"
  NORM_B2="$(jq -S 'del(.mutation_sha, .timestamp, .base, .head)' "$OUT_B2" 2>/dev/null)"
  assert_eq "same seed -> byte-identical planted.json (modulo mutation_sha)" "$NORM_B1" "$NORM_B2"
else
  bad "same seed -> byte-identical planted.json (modulo mutation_sha)"
fi

# (c) a different / unforced seed can pick the bounds site; --dry-run lists
#     both candidates.
DRYRUN_OUT="$T/dryrun.log"
bash "$S/plant_mutation.sh" --repo "$REPO" --base "$BASE_SHA" --head "$HEAD_SHA" \
  --seed 7 --dry-run >"$DRYRUN_OUT" 2>&1
assert_contains "--dry-run lists nullish candidate" "$(cat "$DRYRUN_OUT")" "nullish"
assert_contains "--dry-run lists bounds candidate" "$(cat "$DRYRUN_OUT")" "bounds_lt_le"

REPO_C="$T/repo-c"
mk_fixture_repo "$REPO_C"
C_BASE="$(git -C "$REPO_C" rev-parse HEAD~1)"
C_HEAD="$(git -C "$REPO_C" rev-parse HEAD)"
OUT_C="$T/planted-c.json"
bash "$S/plant_mutation.sh" --repo "$REPO_C" --base "$C_BASE" --head "$C_HEAD" \
  --seed 7 --run-id mutation-c --out "$OUT_C" >/dev/null 2>&1
if [[ -f "$OUT_C" ]]; then
  PICKED_OP="$(jq -r '.operator' "$OUT_C")"
  case "$PICKED_OP" in
    nullish|bounds_lt_le) ok "unforced draw picks a real candidate op ($PICKED_OP)" ;;
    *) bad "unforced draw picks a real candidate op (got '$PICKED_OP')" ;;
  esac
else
  bad "unforced draw picks a real candidate op (no planted.json)"
fi

# (d) a repo whose diff has no applicable line exits 2.
NOOP_DIR="$T/repo-noop"
rm -rf "$NOOP_DIR"
mkdir -p "$NOOP_DIR/src"
git init -q "$NOOP_DIR"
git -C "$NOOP_DIR" config user.name "Test"
git -C "$NOOP_DIR" config user.email "test@example.com"
echo 'export const x = 1;' >"$NOOP_DIR/src/b.ts"
git -C "$NOOP_DIR" add src/b.ts
git -C "$NOOP_DIR" commit -q -m "base"
echo 'export const y = 2;' >>"$NOOP_DIR/src/b.ts"
git -C "$NOOP_DIR" add src/b.ts
git -C "$NOOP_DIR" commit -q -m "head"
NOOP_BASE="$(git -C "$NOOP_DIR" rev-parse HEAD~1)"
NOOP_HEAD="$(git -C "$NOOP_DIR" rev-parse HEAD)"
bash "$S/plant_mutation.sh" --repo "$NOOP_DIR" --base "$NOOP_BASE" --head "$NOOP_HEAD" \
  --seed 1 --out "$T/planted-noop.json" >/dev/null 2>"$T/stderr-noop.log"
NOOP_EXIT=$?
assert_eq "no-candidate diff exits 2" "$NOOP_EXIT" "2"

# (f) operator hygiene from the PR #107 review: block guards, generics and
#     nested-paren calls are never candidates; single-line guards, spaced
#     comparisons and flat calls are.
mk_repo_with() {
  local dir="$1"; shift
  rm -rf "$dir"; mkdir -p "$dir/src"; git init -q "$dir"
  git -C "$dir" config user.name "Test"; git -C "$dir" config user.email "test@example.com"
  printf '// base\n' >"$dir/src/b.ts"; git -C "$dir" add src/b.ts; git -C "$dir" commit -q -m base
  { printf '// base\n'; printf '%s\n' "$@"; } >"$dir/src/b.ts"
  git -C "$dir" add src/b.ts; git -C "$dir" commit -q -m head
}
REPO_F="$T/repo-f"
mk_repo_with "$REPO_F" \
  'if (!x) {' \
  'if (x == null) return null;' \
  'const a: Array<T> = [];' \
  'if (i < n) {' \
  'app.auth(getUser());' \
  'router.auth(token);' \
  'const p = path.join(root, compute());' \
  'const q = path.join(root, userPath);'
F_BASE="$(git -C "$REPO_F" rev-parse HEAD~1)"; F_HEAD="$(git -C "$REPO_F" rev-parse HEAD)"
FDRY="$(bash "$S/plant_mutation.sh" --repo "$REPO_F" --base "$F_BASE" --head "$F_HEAD" --seed 1 --dry-run 2>&1)"
assert_not_contains "block guard 'if (!x) {' is not a guard_false candidate" "$FDRY" "src/b.ts:2  operator=guard_false"
assert_contains "single-line guard is a guard_false candidate" "$FDRY" "src/b.ts:3  operator=guard_false"
assert_not_contains "Array<T> is not a bounds candidate" "$FDRY" "src/b.ts:4  operator=bounds_lt_le"
assert_contains "'i < n' is a bounds candidate" "$FDRY" "src/b.ts:5  operator=bounds_lt_le"
assert_not_contains "nested-paren .auth(getUser()) is not a candidate" "$FDRY" "src/b.ts:6  operator=security_strip_auth_guard"
assert_contains "flat .auth(token) is a candidate" "$FDRY" "src/b.ts:7  operator=security_strip_auth_guard"
assert_not_contains "nested-paren path.join is not a candidate" "$FDRY" "src/b.ts:8  operator=security_widen_path_join"
assert_contains "flat path.join is a candidate" "$FDRY" "src/b.ts:9  operator=security_widen_path_join"
assert_contains "--dry-run header and candidates share one stream" "$FDRY" "candidate site(s)"

OUT_F="$T/planted-f.json"
bash "$S/plant_mutation.sh" --repo "$REPO_F" --base "$F_BASE" --head "$F_HEAD" --seed 1 --operator security_widen_path_join --run-id mutation-f --out "$OUT_F" >/dev/null 2>&1
assert_eq "widen_path_join plants (exit 0)" "$?" "0"
assert_eq "widen_path_join keeps the joined argument (\\1 is the argument group)" "$(jq -r '.mutated_line' "$OUT_F")" "const q = userPath;"

# (g) guards: dirty tree, bad seed, tampered operator table
REPO_G="$T/repo-g"; mk_fixture_repo "$REPO_G"
G_BASE="$(git -C "$REPO_G" rev-parse HEAD~1)"; G_HEAD="$(git -C "$REPO_G" rev-parse HEAD)"
printf '// dirty\n' >>"$REPO_G/src/a.ts"
bash "$S/plant_mutation.sh" --repo "$REPO_G" --base "$G_BASE" --head "$G_HEAD" --seed 1 --out "$T/planted-g.json" >/dev/null 2>"$T/stderr-g.log"
assert_eq "dirty tracked tree exits 1" "$?" "1"
assert_contains "dirty tree names the cause" "$(cat "$T/stderr-g.log")" "uncommitted tracked changes"
git -C "$REPO_G" checkout -q -- src/a.ts
bash "$S/plant_mutation.sh" --repo "$REPO_G" --base "$G_BASE" --head "$G_HEAD" --seed abc --out "$T/planted-g.json" >/dev/null 2>&1
assert_eq "non-integer --seed exits 1 before any mutation" "$?" "1"
assert_eq "no mutation branch was created for the bad seed" "$(git -C "$REPO_G" branch --list 'mutation/*' | wc -l | tr -d ' ')" "0"
BAD_OPS="$T/bad-ops.json"
jq '.[0].replace = "s/x/y/e"' "$OPERATORS" >"$BAD_OPS"
bash "$S/plant_mutation.sh" --repo "$REPO_G" --base "$G_BASE" --head "$G_HEAD" --seed 1 --operators "$BAD_OPS" --out "$T/planted-g.json" >/dev/null 2>"$T/stderr-ops.log"
assert_eq "a replace with a sed command flag is rejected (exit 1)" "$?" "1"
assert_contains "tampered replace is named" "$(cat "$T/stderr-ops.log")" "not a plain s/pat/repl"
jq '. + [.[0]]' "$OPERATORS" >"$BAD_OPS"
bash "$S/plant_mutation.sh" --repo "$REPO_G" --base "$G_BASE" --head "$G_HEAD" --seed 1 --operators "$BAD_OPS" --out "$T/planted-g.json" >/dev/null 2>&1
assert_eq "duplicate operator ids are rejected (exit 1)" "$?" "1"

echo
echo "── summary ──"
echo "  PASS=$PASS FAIL=$FAIL"
if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
exit 0
