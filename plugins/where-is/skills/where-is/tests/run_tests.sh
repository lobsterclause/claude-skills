#!/usr/bin/env bash
# run_tests.sh — offline fixture tests for the where-is scripts.
#
# NO network, NO MCP, NO ast-grep required: fixture repos are created in a
# temp dir, and the "ast-grep missing" path is exercised via a restricted
# PATH built from `type -P` (so shell functions/aliases shadowing tools in
# a caller's environment can't leak in). Every case pins a behavior a
# cross-review pass flagged (or falsified) on issue #14 — see [pin: ...].
#
# Run:  bash tests/run_tests.sh          (from the skill root or anywhere)
# Exit: 0 all green, 1 any failure.
#
# Portability: macOS bash 3.2 + ubuntu bash 5; needs node, python3, jq.
# ripgrep is NOT required (concept search falls back to grep -r).

set -uo pipefail

SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
S="$SKILL_DIR/scripts"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

PASS=0
FAIL=0
ok()  { echo "  ok   $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL $1"; FAIL=$((FAIL + 1)); }
# assert <description> <actual> <expected>
assert_eq() {
  if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 (got: '$2' want: '$3')"; fi
}
assert_contains() {
  if [[ "$2" == *"$3"* ]]; then ok "$1"; else bad "$1 (no '$3' in output)"; fi
}
assert_not_contains() {
  if [[ "$2" != *"$3"* ]]; then ok "$1"; else bad "$1 (unexpected '$3' in output)"; fi
}

for req in node python3 jq; do
  if ! type -P "$req" >/dev/null 2>&1; then
    echo "SKIP-FAIL: required tool '$req' not on PATH" >&2
    exit 1
  fi
done

echo "── syntax (bash -n on every script) ──"
for f in "$S"/*.sh; do
  if bash -n "$f" 2>/dev/null; then ok "bash -n $(basename "$f")"; else bad "bash -n $(basename "$f")"; fi
done

echo "── classify.sh ──"
# [pin: issue #14 item 16 — Class/method slash form stays a symbol; a
# reviewer misread the routing as broken, smoke-verified working]
assert_eq "Class/method classifies as symbol" \
  "$(bash "$S/classify.sh" 'Foo/bar' | jq -r .kind)" "symbol"
assert_eq "path with extension classifies as path" \
  "$(bash "$S/classify.sh" 'src/utils/foo.ts' | jq -r .kind)" "path"
assert_eq "call-shaped query classifies as pattern" \
  "$(bash "$S/classify.sh" 'useQuery(' | jq -r .kind)" "pattern"
assert_eq "multi-word query classifies as concept" \
  "$(bash "$S/classify.sh" 'auth token refresh' | jq -r .kind)" "concept"
assert_eq "classify output is valid JSON" \
  "$(bash "$S/classify.sh" 'Foo/bar' | jq -r type)" "object"

echo "── fs_walk.sh (glob translation) ──"
# Root dir deliberately contains '#' — the old sed program interpolated the
# root path with '#' delimiters. [pin: issue #14 item 5]
F="$T/fix#ture"
mkdir -p "$F/src/a" "$F/node_modules/x"
touch "$F/src/index.ts" "$F/src/a/b.ts" "$F/src/notme.css" \
      "$F/src/skip.test.ts" "$F/node_modules/x/y.ts" "$F/a+b(c).ts"
# [pin: issue #14 item 2 — **/ used to compile to a regex demanding two
# slashes, so src/**/*.ts never matched src/index.ts]
out="$(WHEREIS_REPO_ROOT="$F" bash "$S/fs_walk.sh" 'src/**/*.ts')"
assert_contains "src/**/*.ts matches zero-depth src/index.ts" "$out" "src/index.ts"
assert_contains "src/**/*.ts matches nested src/a/b.ts" "$out" "src/a/b.ts"
assert_not_contains "src/**/*.ts excludes non-ts" "$out" "notme.css"
assert_not_contains "node_modules excluded" "$out" "node_modules"
assert_not_contains "tests excluded by default" "$out" "skip.test.ts"
out="$(WHEREIS_REPO_ROOT="$F" bash "$S/fs_walk.sh" 'src/**/*.ts' --include-tests)"
assert_contains "--include-tests includes tests" "$out" "skip.test.ts"
# [pin: issue #14 item 10 — ERE metachars +() in a glob match literally]
out="$(WHEREIS_REPO_ROOT="$F" bash "$S/fs_walk.sh" 'a+b(c).ts')"
assert_eq "metachar filename matches literally" "$out" "a+b(c).ts"
out="$(WHEREIS_REPO_ROOT="$F" bash "$S/fs_walk.sh" '**/*.ts')"
assert_contains "leading **/ matches root-level file" "$out" "a+b(c).ts"

echo "── where-is.sh (usage guards) ──"
# [pin: issue #14 item 14 — valueless flags used to die silently via set -e]
msg="$(bash "$S/where-is.sh" --kind 2>&1)"; rc=$?
assert_eq "--kind without value exits 2" "$rc" "2"
assert_contains "--kind without value prints usage" "$msg" "--kind requires a value"
msg="$(bash "$S/where-is.sh" --package 2>&1)"; rc=$?
assert_eq "--package without value exits 2" "$rc" "2"
bash "$S/where-is.sh" >/dev/null 2>&1; assert_eq "missing query exits 2" "$?" "2"
bash "$S/where-is.sh" --bogus q >/dev/null 2>&1; assert_eq "unknown flag exits 2" "$?" "2"

# ── workspace fixture shared by the routing tests ──
WS="$T/wsfix"
mkdir -p "$WS/packages/a/src" "$WS/packages/b/src"
printf '{"name":"fix-root","workspaces":["packages/*"]}\n' > "$WS/package.json"
printf '{"name":"@fix/a"}\n' > "$WS/packages/a/package.json"
printf '{"name":"@fix/b"}\n' > "$WS/packages/b/package.json"
printf 'export const alphaThing = 1;\n' > "$WS/packages/a/src/alpha.ts"
printf 'export function alphaThing() {}\n' > "$WS/packages/b/src/beta.ts"
printf 'export const other = 2; // alphaThing usage\n' > "$WS/packages/b/src/gamma.ts"

echo "── where-is.sh --json --kind pattern without ast-grep ──"
# Restricted PATH: real binaries only (type -P dodges caller shell functions),
# ast-grep/sg deliberately absent. [pin: issue #14 item 3 — fallback used to
# stream raw text at JSON consumers regardless of --json]
XBIN="$T/xbin"
mkdir -p "$XBIN"
for t in bash sh dirname basename sed awk grep head sort cat find tr paste wc mktemp node python3 git jq; do
  p="$(type -P "$t" 2>/dev/null || true)"
  [ -n "$p" ] && ln -s "$p" "$XBIN/$t"
done
out="$(PATH="$XBIN" WHEREIS_REPO_ROOT="$WS" bash "$S/where-is.sh" --json --kind pattern 'alphaThing(' 2>/dev/null)"
if printf '%s' "$out" | jq -e . >/dev/null 2>&1; then
  ok "fallback --json output parses as JSON"
else
  bad "fallback --json output parses as JSON (raw: ${out:0:120})"
fi
assert_eq "fallback envelope route" \
  "$(printf '%s' "$out" | jq -r .route 2>/dev/null)" "ripgrep-fallback"
assert_eq "fallback envelope keeps kind" \
  "$(printf '%s' "$out" | jq -r .kind 2>/dev/null)" "pattern"
assert_eq "fallback envelope matches is a string" \
  "$(printf '%s' "$out" | jq -r '.matches|type' 2>/dev/null)" "string"

echo "── single-pass package annotation (text modes) ──"
# Counting node shim: every node invocation appends a byte to a counter file.
# [pin: issue #14 item 1 — text mode used to spawn node once PER RESULT LINE;
# now: 1x detect_layout + 1x annotate_lines regardless of result count]
NBIN="$T/nbin"
mkdir -p "$NBIN"
REAL_NODE="$(type -P node)"
NODE_COUNT_FILE="$T/node_count"
export REAL_NODE NODE_COUNT_FILE
cat > "$NBIN/node" <<'SH'
#!/bin/sh
printf x >> "$NODE_COUNT_FILE"
exec "$REAL_NODE" "$@"
SH
chmod +x "$NBIN/node"
: > "$NODE_COUNT_FILE"
out="$(PATH="$NBIN:$PATH" WHEREIS_REPO_ROOT="$WS" bash "$S/where-is.sh" --kind path 'packages/**/*.ts' 2>/dev/null)"
spawns="$(wc -c < "$NODE_COUNT_FILE" | tr -d ' ')"
assert_contains "path mode labels package a" "$out" "[@fix/a] packages/a/src/alpha.ts"
assert_contains "path mode labels package b" "$out" "[@fix/b] packages/b/src/beta.ts"
if [ "$spawns" -le 3 ]; then
  ok "3 result lines cost <=3 node spawns (got $spawns; N+1 would be >=4)"
else
  bad "3 result lines cost <=3 node spawns (got $spawns)"
fi
out="$(WHEREIS_REPO_ROOT="$WS" bash "$S/where-is.sh" --kind concept 'alphaThing' 2>/dev/null)"
assert_contains "concept mode labels package a hit" "$out" "[@fix/a]"
assert_contains "concept mode labels package b hit" "$out" "[@fix/b]"

echo "── detect_layout.sh (Nx enumeration) ──"
# [pin: issue #14 item 4 — kind=nx used to report an empty packages list]
NX="$T/nxfix"
mkdir -p "$NX/apps/web" "$NX/libs/core" "$NX/node_modules/evil"
printf '{}\n' > "$NX/nx.json"
printf '{"name":"nx-root"}\n' > "$NX/package.json"
printf '{"name":"web"}\n' > "$NX/apps/web/project.json"
printf '{"name":"core"}\n' > "$NX/libs/core/project.json"
printf '{"name":"evil"}\n' > "$NX/node_modules/evil/project.json"
out="$(bash "$S/detect_layout.sh" "$NX")"
assert_eq "nx repo detected as kind nx" "$(printf '%s' "$out" | jq -r .workspace_kind)" "nx"
assert_eq "nx project.json enumerated (web)" \
  "$(printf '%s' "$out" | jq -r '.packages[]|select(.name=="web")|.dir')" "apps/web"
assert_eq "nx project.json enumerated (core)" \
  "$(printf '%s' "$out" | jq -r '.packages[]|select(.name=="core")|.dir')" "libs/core"
assert_eq "node_modules project.json ignored" \
  "$(printf '%s' "$out" | jq -r '[.packages[]|select(.name=="evil")]|length')" "0"
# legacy workspace.json projects map
NXL="$T/nxleg"
mkdir -p "$NXL/apps/legacy"
printf '{}\n' > "$NXL/nx.json"
printf '{"projects":{"legacy-app":"apps/legacy"}}\n' > "$NXL/workspace.json"
assert_eq "legacy workspace.json projects map enumerated" \
  "$(bash "$S/detect_layout.sh" "$NXL" | jq -r '.packages[]|select(.name=="legacy-app")|.dir')" "apps/legacy"

echo "── detect_layout.sh (pnpm yaml hardening) ──"
# [pin: issue #14 item 11 — inline comments stripped, quoted globs unwrapped,
# exclusion patterns skipped; naive-YAML limits documented in the header]
PN="$T/pnfix"
mkdir -p "$PN/packages/a"
printf 'packages:\n  - "packages/*"  # inline comment\n  - "!**/fixtures/**"\n' > "$PN/pnpm-workspace.yaml"
printf '{"name":"@p/a"}\n' > "$PN/packages/a/package.json"
out="$(bash "$S/detect_layout.sh" "$PN")"
assert_eq "pnpm glob with inline comment parsed" \
  "$(printf '%s' "$out" | jq -r '.packages[]|select(.name=="@p/a")|.dir')" "packages/a"
assert_not_contains "exclusion pattern not treated as a package" "$out" '"!'

echo
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
