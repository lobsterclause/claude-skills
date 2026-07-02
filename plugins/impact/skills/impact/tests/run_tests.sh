#!/usr/bin/env bash
# run_tests.sh — offline fixture tests for the impact scripts.
#
# NO network, NO real graph tools: `depcruise` is a PATH shim that replays a
# fixture depcruise JSON (and can be told to fail), git repos are created in a
# temp dir. Every case pins an issue #12 finding (or its falsification) —
# see the [pin: ...] tags.
#
# Run:  bash tests/run_tests.sh          (from the skill root or anywhere)
# Exit: 0 all green, 1 any failure.
#
# Portability: macOS bash 3.2 + ubuntu bash 5; needs git, node, python3.

set -uo pipefail

SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
S="$SKILL_DIR/scripts"
T="$(mktemp -d "${TMPDIR:-/tmp}/impact-tests.XXXXXXXX")"
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
  if [[ "$2" != *"$3"* ]]; then ok "$1"; else bad "$1 ('$3' unexpectedly present)"; fi
}

# ── PATH shim: fake depcruise replaying a fixture graph. detect_tools.sh will
# always prefer it (depcruiser > madge), making the suite hermetic even on
# hosts with real madge/depcruise installed.
mkdir -p "$T/bin"
cat >"$T/bin/depcruise" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = "--version" ]; then echo "99.9.9"; exit 0; fi
echo x >> "${DEPCRUISE_CALLS:-/dev/null}"
if [ "${DEPCRUISE_FAIL:-0}" = "1" ]; then
  echo "BOOM: fake tool explosion" >&2
  exit 1
fi
cat "${DEPCRUISE_FIXTURE:?DEPCRUISE_FIXTURE not set}"
SH
chmod +x "$T/bin/depcruise"
export PATH="$T/bin:$PATH"

echo "── bash -n (syntax) ──"
for f in impact.sh build_graph.sh find_tests.sh detect_tools.sh; do
  if bash -n "$S/$f" 2>/dev/null; then ok "bash -n $f"; else bad "bash -n $f"; fi
done

echo "── arg parsing (shift bounds + unknown flags) ──"
# [pin: issue #12 high — --base without a value crashed via bare `shift 2`]
set +e
out="$(bash "$S/impact.sh" --base 2>&1)"; rc=$?
set -e
assert_eq "impact.sh --base w/o value exits 2" "$rc" "2"
assert_contains "impact.sh --base w/o value says why" "$out" "requires"
set +e
bash "$S/impact.sh" --bogus-flag >/dev/null 2>&1; rc=$?
set -e
assert_eq "impact.sh unknown flag exits 2" "$rc" "2"

# ── Fixture repo ─────────────────────────────────────────────────────────────
REPO="$T/repo"
mkdir -p "$REPO/src" "$REPO/packages/foo/src" "$REPO/disabled-pkgs/x" "$REPO/glob"
cd "$REPO"
git init -q .
git config user.email "t@t"; git config user.name "t"
cat > package.json <<'EOF'
{"name": "fixture-root", "workspaces": ["packages/*", 123]}
EOF
cat > pnpm-workspace.yaml <<'EOF'
packages:
  # - disabled-pkgs/*
  - packages/*
EOF
echo '{"name": "@fix/foo"}' > packages/foo/package.json
echo '{"name": "should-not-appear"}' > disabled-pkgs/x/package.json
echo 'export const b = 1;' > src/b.ts
echo 'import { b } from "./b"; export const a = b;' > src/a.ts
echo 'import { a } from "./a"; export const c = a;' > src/c.ts
echo 'export const d = 1;' > src/d.ts
echo 'import { a } from "../src/a"; test("a", () => {});' > src/a.test.ts
echo 'import { b } from "../../src/b";' > disabled-pkgs/x/file.ts
echo 'import { b } from "../../../src/b";' > packages/foo/src/pa.ts
echo 'export const g = 1;' > 'glob/x[1].ts'
echo 'test("g", () => {});' > 'glob/x[1].test.ts'
echo 'export const w = 1;' > 'src/weird|name.ts'
git add -A && git commit -q -m fixture

# depcruise fixture graph (relative paths, depcruise raw shape).
cat > "$T/graph.json" <<'EOF'
{"modules": [
  {"source": "src/a.ts",  "dependencies": [{"resolved": "src/b.ts"}]},
  {"source": "src/c.ts",  "dependencies": [{"resolved": "src/a.ts"}]},
  {"source": "src/b.ts",  "dependencies": []},
  {"source": "src/d.ts",  "dependencies": []},
  {"source": "disabled-pkgs/x/file.ts", "dependencies": [{"resolved": "src/b.ts"}]},
  {"source": "packages/foo/src/pa.ts",  "dependencies": [{"resolved": "src/b.ts"}]}
]}
EOF
export DEPCRUISE_FIXTURE="$T/graph.json"
export DEPCRUISE_CALLS="$T/depcruise.calls"
: > "$DEPCRUISE_CALLS"

echo "── end-to-end report (closure, grouping, tests) ──"
echo '// touch' >> src/b.ts
REPORT="$(bash "$S/impact.sh" --json)"; rc=$?
assert_eq "impact.sh --json exits 0" "$rc" "0"
assert_contains "entry detected" "$REPORT" '"src/b.ts"'
assert_contains "1-hop reverse dep in closure" "$REPORT" '"src/a.ts"'
assert_contains "2-hop reverse dep in closure" "$REPORT" '"src/c.ts"'
assert_contains "sibling test discovered" "$REPORT" '"src/a.test.ts"'
# [pin: issue #12 medium — anchored pnpm regex: commented `# - disabled-pkgs/*`
#  must NOT become a workspace package]
assert_not_contains "commented workspace glob ignored" "$REPORT" "should-not-appear"
assert_contains "disabled-pkgs file classified under root pkg" "$REPORT" '"fixture-root"'
assert_contains "real workspace pkg classified" "$REPORT" '"@fix/foo"'
# [pin: issue #12 low — non-string package.json workspaces entry (123) must not crash]
ok "non-string workspaces entry did not crash the run"

echo "── graph cache (atomicity + import-edit invalidation) ──"
# [pin: issue #12 high — atomic write: graph.json must be valid JSON, no tmp left]
if python3 -m json.tool "$REPO/.impact-cache/graph.json" >/dev/null 2>&1; then
  ok "graph.json is complete valid JSON"
else
  bad "graph.json is not valid JSON"
fi
leftovers="$(find "$REPO/.impact-cache" -name 'graph.json.tmp.*' | wc -l | tr -d ' ')"
assert_eq "no orphaned graph tmp files" "$leftovers" "0"
calls="$(wc -l < "$DEPCRUISE_CALLS" | tr -d ' ')"
assert_eq "first run built the graph once" "$calls" "1"
bash "$S/impact.sh" --json >/dev/null 2>&1
calls="$(wc -l < "$DEPCRUISE_CALLS" | tr -d ' ')"
assert_eq "unchanged sources → cache hit (no rebuild)" "$calls" "1"
# [pin: issue #12 medium, flagged all 4 passes — editing imports inside an
#  existing file must invalidate the cache (old key was a coarse file count)]
echo 'import { b } from "./b";' >> src/d.ts
bash "$S/impact.sh" --json >/dev/null 2>&1
calls="$(wc -l < "$DEPCRUISE_CALLS" | tr -d ' ')"
assert_eq "import edit in existing file → rebuild" "$calls" "2"

echo "── delimiter safety ──"
# [pin: issue #12 high — `|` is legal in filenames; old |-joined entries_csv
#  split one path into two bogus entries]
git checkout -q -- src/b.ts src/d.ts
bash "$S/impact.sh" --refresh --json >/dev/null 2>&1  # resync cache after checkout
echo '// touch' >> 'src/weird|name.ts'
REPORT="$(bash "$S/impact.sh" --json)"
assert_contains "pipe-in-filename survives as one entry" "$REPORT" '"src/weird|name.ts"'
n_entries="$(printf '%s' "$REPORT" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["entries"]))')"
assert_eq "exactly one entry (not split on |)" "$n_entries" "1"
git checkout -q -- 'src/weird|name.ts'

echo "── hoisted BFS seen (multi-entry correctness) ──"
# [pin: issue #12 medium — seen hoisted outside entries loop must not change results]
REPORT="$(bash "$S/impact.sh" --json src/b.ts src/a.ts)"
assert_contains "shared ancestor still in closure" "$REPORT" '"src/c.ts"'
assert_contains "direct parent still in closure" "$REPORT" '"src/a.ts"'

echo "── find_tests glob-char paths ──"
# [pin: issue #12 high find_tests quoting — verified already quoted in shipped
#  code; this pins it against regression]
FT="$(printf 'glob/x[1].ts\n' | IMPACT_REPO_ROOT="$REPO" bash "$S/find_tests.sh")"
assert_eq "glob-char sibling test found, no expansion" "$FT" "glob/x[1].test.ts"

echo "── build tool stderr surfacing ──"
# [pin: issue #12 high — 2>/dev/null used to hide tool errors]
set +e
err="$(DEPCRUISE_FAIL=1 IMPACT_REPO_ROOT="$REPO" bash "$S/build_graph.sh" --refresh 2>&1 >/dev/null)"; rc=$?
set -e
assert_eq "build_graph exits nonzero on tool failure" "$rc" "1"
assert_contains "tool stderr surfaced" "$err" "BOOM: fake tool explosion"

echo "── ARG_MAX path (hundreds of entries via temp file) ──"
# [pin: issue #12 design high — entries flow via newline temp file, not argv]
REPO2="$T/repo2"
mkdir -p "$REPO2/gen"
cd "$REPO2"
git init -q . && git config user.email "t@t" && git config user.name "t"
echo '{"name": "big-fixture"}' > package.json
i=0
while [ "$i" -lt 300 ]; do
  printf 'export const v%03d = %d;\n' "$i" "$i" > "$(printf 'gen/f%03d.ts' "$i")"
  i=$((i + 1))
done
git add -A && git commit -q -m big
i=0
while [ "$i" -lt 300 ]; do
  echo '// touch' >> "$(printf 'gen/f%03d.ts' "$i")"
  i=$((i + 1))
done
echo '{"modules": []}' > "$T/graph-empty.json"
set +e
REPORT="$(DEPCRUISE_FIXTURE="$T/graph-empty.json" bash "$S/impact.sh" --json)"; rc=$?
set -e
assert_eq "300-entry run exits 0" "$rc" "0"
n_entries="$(printf '%s' "$REPORT" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["entries"]))')"
assert_eq "all 300 entries arrived intact" "$n_entries" "300"

echo
echo "impact tests: $PASS ok, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
