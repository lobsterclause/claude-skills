#!/usr/bin/env bash
# run_tests.sh — offline fixture tests for the codemap scripts.
#
# NO network, NO impact plugin: HOME is sandboxed so the impact-plugin
# integration path in build_pkg_graph.sh can't pick up a real installed
# skill — every case runs against fixture repos in a temp dir. Each case
# pins a behavior a cross-review pass flagged on issue #14 — see [pin: ...].
#
# Run:  bash tests/run_tests.sh          (from the skill root or anywhere)
# Exit: 0 all green, 1 any failure.
#
# Portability: macOS bash 3.2 + ubuntu bash 5; needs python3, jq, git.

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
  if [[ "$2" != *"$3"* ]]; then ok "$1"; else bad "$1 (unexpected '$3' in output)"; fi
}

for req in python3 jq git; do
  if ! type -P "$req" >/dev/null 2>&1; then
    echo "SKIP-FAIL: required tool '$req' not on PATH" >&2
    exit 1
  fi
done

# Sandbox HOME so build_pkg_graph.sh's "$HOME/.claude/skills/impact/..."
# integration branch never fires against a real install.
export HOME="$T/home"
mkdir -p "$HOME"

echo "── syntax (bash -n on every script) ──"
for f in "$S"/*.sh; do
  if bash -n "$f" 2>/dev/null; then ok "bash -n $(basename "$f")"; else bad "bash -n $(basename "$f")"; fi
done

echo "── detect_workspaces.sh ──"
# npm-workspaces fixture with one ts, one js, one mixed package.
# [pin: issue #14 item 7 — detect_lang refactored to a single find pass;
# these assert the classification survived the refactor]
NW="$T/npmfix"
mkdir -p "$NW/packages/a/src" "$NW/packages/b" "$NW/packages/c"
printf '{"name":"fix-root","workspaces":["packages/*"]}\n' > "$NW/package.json"
printf '{"name":"@fix/a","description":"pkg a"}\n' > "$NW/packages/a/package.json"
printf '{"name":"@fix/b"}\n' > "$NW/packages/b/package.json"
printf '{"name":"@fix/c"}\n' > "$NW/packages/c/package.json"
printf 'export const x = 1;\n' > "$NW/packages/a/src/x.ts"
printf 'module.exports = 1;\n' > "$NW/packages/b/y.js"
printf 'export const z = 1;\n' > "$NW/packages/c/z.ts"
printf 'module.exports = 2;\n' > "$NW/packages/c/w.cjs"
out="$(bash "$S/detect_workspaces.sh" "$NW")"
if printf '%s' "$out" | jq -e . >/dev/null 2>&1; then ok "output is valid JSON"; else bad "output is valid JSON"; fi
assert_eq "kind is npm" "$(printf '%s' "$out" | jq -r .kind)" "npm"
assert_eq "ts-only package lang" \
  "$(printf '%s' "$out" | jq -r '.packages[]|select(.name=="@fix/a")|.lang')" "ts"
assert_eq "js-only package lang" \
  "$(printf '%s' "$out" | jq -r '.packages[]|select(.name=="@fix/b")|.lang')" "js"
assert_eq "ts+js package lang is mixed" \
  "$(printf '%s' "$out" | jq -r '.packages[]|select(.name=="@fix/c")|.lang')" "mixed"
assert_eq "description carried through" \
  "$(printf '%s' "$out" | jq -r '.packages[]|select(.name=="@fix/a")|.description')" "pkg a"

# [pin: issue #14 item 11 — pnpm inline comments stripped, quotes unwrapped,
# exclusion patterns skipped; naive-YAML limits documented in the header]
PN="$T/pnfix"
mkdir -p "$PN/packages/a"
printf 'packages:\n  - "packages/*"  # inline comment\n  - "!**/fixtures/**"\n' > "$PN/pnpm-workspace.yaml"
printf '{"name":"@p/a"}\n' > "$PN/packages/a/package.json"
out="$(bash "$S/detect_workspaces.sh" "$PN")"
assert_eq "pnpm kind" "$(printf '%s' "$out" | jq -r .kind)" "pnpm"
assert_eq "pnpm glob with inline comment parsed" \
  "$(printf '%s' "$out" | jq -r '.packages|length')" "1"
assert_not_contains "exclusion pattern not treated as a package" "$out" '"!'

echo "── build_pkg_graph.sh ──"
# git fixture: package a imports b three ways, plus a dotted package name to
# prove in-python re.escape matching.
G="$T/graphfix"
mkdir -p "$G/packages/a/src" "$G/packages/b/src" "$G/packages/cd/src"
printf '{"name":"@fix/a"}\n' > "$G/packages/a/package.json"
printf '{"name":"@fix/b"}\n' > "$G/packages/b/package.json"
printf '{"name":"@fix/c.d"}\n' > "$G/packages/cd/package.json"
cat > "$G/packages/a/src/main.ts" <<'EOF'
import stat from '@fix/b';
const dyn = import('@fix/b/sub');
import '@fix/b';
import dotted from '@fix/c.d';
import notdot from '@fix/cXd';
EOF
printf 'export default 1;\n' > "$G/packages/b/src/index.ts"
printf 'export default 2;\n' > "$G/packages/cd/src/index.ts"
git -C "$G" init -q
git -C "$G" add -A
git -C "$G" -c user.email=t@t -c user.name=t commit -qm fixture
WSJ="$T/ws.json"
cat > "$WSJ" <<'EOF'
{"kind":"npm","packages":[{"name":"@fix/a","dir":"packages/a"},{"name":"@fix/b","dir":"packages/b"},{"name":"@fix/c.d","dir":"packages/cd"}]}
EOF
out="$(bash "$S/build_pkg_graph.sh" "$G" "$WSJ")"
# [pin: issue #14 item 9 — dynamic import('pkg') and bare side-effect
# import 'pkg' used to be invisible; static-only would give count 1]
assert_eq "static+dynamic+bare imports all counted" \
  "$(printf '%s' "$out" | jq -r 'select(.to=="@fix/b")|.count')" "3"
# [pin: issue #14 item 6 — package regex built in python via re.escape; the
# dot in @fix/c.d must match literally, so @fix/cXd must NOT count]
assert_eq "dotted package name matches literally (re.escape)" \
  "$(printf '%s' "$out" | jq -r 'select(.to=="@fix/c.d")|.count')" "1"
assert_not_contains "escaped dot does not match cXd" "$out" "cXd"
# [pin: issue #14 item 12 — usage errors exit 2]
bash "$S/build_pkg_graph.sh" >/dev/null 2>&1; assert_eq "no args exits 2 (usage)" "$?" "2"

echo "── codemap.sh ──"
out="$(bash "$S/codemap.sh" --root "$NW" --json 2>/dev/null)"
if printf '%s' "$out" | jq -e . >/dev/null 2>&1; then ok "--json output parses"; else bad "--json output parses"; fi
assert_eq "package_count matches fixture" \
  "$(printf '%s' "$out" | jq -r .stats.package_count)" "3"
# Deterministic markdown: same fake time -> byte-identical output files.
O1="$T/map1.md"; O2="$T/map2.md"
CODEMAP_FAKE_TIME="2026-01-01T00:00:00Z" bash "$S/codemap.sh" --root "$NW" --output "$O1" >/dev/null 2>&1
CODEMAP_FAKE_TIME="2026-01-01T00:00:00Z" bash "$S/codemap.sh" --root "$NW" --output "$O2" >/dev/null 2>&1
if [ -s "$O1" ] && cmp -s "$O1" "$O2"; then
  ok "markdown output written and deterministic under CODEMAP_FAKE_TIME"
else
  bad "markdown output written and deterministic under CODEMAP_FAKE_TIME"
fi
# [pin: issue #14 items 12+14 — valueless flags are usage errors (exit 2)]
bash "$S/codemap.sh" --output >/dev/null 2>&1;       assert_eq "--output without value exits 2" "$?" "2"
bash "$S/codemap.sh" --root >/dev/null 2>&1;         assert_eq "--root without value exits 2" "$?" "2"
bash "$S/codemap.sh" --max-external >/dev/null 2>&1; assert_eq "--max-external without value exits 2" "$?" "2"
bash "$S/codemap.sh" --max-external abc >/dev/null 2>&1; assert_eq "--max-external non-integer exits 2" "$?" "2"
bash "$S/codemap.sh" --bogus >/dev/null 2>&1;        assert_eq "unknown flag exits 2" "$?" "2"

echo
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
