#!/usr/bin/env bash
# run_tests.sh — offline fixture tests for the repomix-handoff scripts.
#
# NO network, NO real repomix: `repomix` is a PATH shim that reads the
# generated --config JSON and concatenates the include list (proving the
# config-file handoff carries the scope — the shim never looks at --include
# argv). `ttok` is shimmed to tokens==bytes so budget math is exact. Every
# case pins an issue #12 finding (or its falsification) — see [pin: ...] tags.
#
# Run:  bash tests/run_tests.sh          (from the skill root or anywhere)
# Exit: 0 all green, 1 any failure.
#
# Portability: macOS bash 3.2 + ubuntu bash 5; needs git, python3.

set -uo pipefail

SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
S="$SKILL_DIR/scripts"
T="$(mktemp -d "${TMPDIR:-/tmp}/repomix-handoff-tests.XXXXXXXX")"
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

# ── PATH shims ────────────────────────────────────────────────────────────────
mkdir -p "$T/bin"
# Fake repomix: honors --version, and packs by reading the --config JSON's
# include array — if handoff.sh regressed to CSV argv the shim would emit an
# empty snapshot and the content assertions below would fail.
cat >"$T/bin/repomix" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = "--version" ]; then echo "9.9.9-shim"; exit 0; fi
config=""; output=""
while [ $# -gt 0 ]; do
  case "$1" in
    --config) config="$2"; shift 2 ;;
    --output) output="$2"; shift 2 ;;
    --style)  shift 2 ;;
    *) shift ;;
  esac
done
[ -n "$config" ] && [ -n "$output" ] || { echo "shim repomix: missing --config/--output" >&2; exit 1; }
if [ "${REPOMIX_SHIM_FAIL:-0}" = "1" ]; then echo "SHIMBOOM: pack exploded" >&2; exit 1; fi
python3 - "$config" "$output" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as f:
    cfg = json.load(f)
with open(sys.argv[2], "w", encoding="utf-8") as out:
    for p in cfg.get("include", []):
        try:
            with open(p, encoding="utf-8") as fh:
                data = fh.read()
        except OSError:
            continue
        out.write("## File: %s\n%s\n" % (p, data))
PY
SH
# Fake ttok: tokens == bytes (deterministic budget math).
printf '#!/bin/sh\nwc -c | tr -d " "\n' >"$T/bin/ttok"
chmod +x "$T/bin/"*
export PATH="$T/bin:$PATH"

echo "── bash -n (syntax) ──"
for f in handoff.sh compute_scope.sh count_tokens.sh detect_repomix.sh; do
  if bash -n "$S/$f" 2>/dev/null; then ok "bash -n $f"; else bad "bash -n $f"; fi
done

echo "── arg parsing (shift bounds + usage) ──"
# [pin: issue #12 high — value-taking flag as last arg crashed via bare `shift 2`]
set +e
out="$(bash "$S/handoff.sh" --reviewer 2>&1)"; rc=$?
set -e
assert_eq "handoff.sh --reviewer w/o value exits 2" "$rc" "2"
assert_contains "handoff.sh says why" "$out" "requires"
set +e
out="$(bash "$S/compute_scope.sh" --base 2>&1)"; rc=$?
set -e
assert_eq "compute_scope.sh --base w/o value exits 2" "$rc" "2"
set +e
bash "$S/handoff.sh" --reviewer nonsense >/dev/null 2>&1; rc=$?
set -e
assert_eq "unknown reviewer exits 2" "$rc" "2"
# [pin: issue #12 medium — --exclude patterns with .. rejected]
set +e
out="$(bash "$S/compute_scope.sh" --paths src --exclude '../secrets/**' 2>&1)"; rc=$?
set -e
assert_eq "--exclude with .. exits 2" "$rc" "2"
assert_contains "traversal rejection says why" "$out" ".."

echo "── count_tokens.sh size guard ──"
# [pin: issue #12 medium — exact tokenizers must not slurp huge files]
printf '%0100d' 0 > "$T/hundred.txt"   # exactly 100 bytes
out="$(COUNT_TOKENS_MAX_BYTES=10 bash "$S/count_tokens.sh" "$T/hundred.txt" 2>"$T/ct.err")"; rc=$?
assert_eq "size-guarded count exits 0" "$rc" "0"
assert_eq "char/4 estimate returned" "$out" "25"
assert_contains "guard method reported on stderr" "$(cat "$T/ct.err")" "size guard"
out="$(bash "$S/count_tokens.sh" "$T/hundred.txt" 2>/dev/null)"
assert_eq "under guard: exact (shim ttok = bytes)" "$out" "100"

# ── Fixture repo ─────────────────────────────────────────────────────────────
REPO="$T/repo"
mkdir -p "$REPO/src"
cd "$REPO"
git init -q .
git config user.email "t@t"; git config user.name "t"
echo 'export const base = 1;' > src/base.ts
git add -A && git commit -q -m base
BASE_BRANCH="$(git rev-parse --abbrev-ref HEAD)"
git checkout -q -b feature
printf 'export const app = "APP_MARKER";\n' > src/app.ts
printf 'export const weird = "COMMA_MARKER";\n' > 'src/we,ird.ts'
{ printf '# notes MD_MARKER\n'; i=0; while [ "$i" -lt 200 ]; do printf 'filler line %04d of markdown content\n' "$i"; i=$((i+1)); done; } > notes.md
git add -A && git commit -q -m feature

echo "── handoff end-to-end (config-file scope, within budget) ──"
set +e
SUMMARY="$(bash "$S/handoff.sh" --base "$BASE_BRANCH" --max-tokens 100000 --output "$T/out1.md" 2>"$T/h1.err")"; rc=$?
set -e
assert_eq "within-budget run exits 0" "$rc" "0"
assert_contains "within_budget true" "$SUMMARY" '"within_budget": true'
# [pin: issue #12 high + low — `,` legal in filenames; no CSV splitting anywhere]
assert_contains "comma-in-filename included intact" "$SUMMARY" '"src/we,ird.ts"'
assert_contains "snapshot has comma-file content" "$(cat "$T/out1.md")" "COMMA_MARKER"
assert_contains "snapshot has app content" "$(cat "$T/out1.md")" "APP_MARKER"

echo "── trim priority + budget-exceeded exit ──"
# tokens == bytes; md is ~7KB, sources ~70B. Budget 2000: md batch dropped, fits.
set +e
SUMMARY="$(bash "$S/handoff.sh" --base "$BASE_BRANCH" --max-tokens 2000 --output "$T/out2.md" 2>/dev/null)"; rc=$?
set -e
assert_eq "trimmed run exits 0" "$rc" "0"
assert_contains "md dropped first" "$SUMMARY" '"notes.md"'
assert_contains "trim recorded in files_trimmed" "$SUMMARY" '"files_trimmed"'
assert_not_contains "snapshot no longer has md content" "$(cat "$T/out2.md")" "MD_MARKER"
assert_contains "still within budget after trim" "$SUMMARY" '"within_budget": true'
# [pin: issue #12 high — over budget after trim exhaustion must exit non-zero,
#  while still emitting the summary JSON]
set +e
SUMMARY="$(bash "$S/handoff.sh" --base "$BASE_BRANCH" --max-tokens 10 --output "$T/out3.md" 2>"$T/h3.err")"; rc=$?
set -e
assert_eq "budget-exhausted run exits 3" "$rc" "3"
assert_contains "summary JSON still emitted" "$SUMMARY" '"within_budget": false'
assert_contains "exhaustion explained on stderr" "$(cat "$T/h3.err")" "exceeds"

echo "── repack failure surfaced ──"
set +e
out="$(REPOMIX_SHIM_FAIL=1 bash "$S/handoff.sh" --base "$BASE_BRANCH" --max-tokens 100000 --output "$T/out4.md" 2>&1)"; rc=$?
set -e
assert_eq "repomix failure exits 1" "$rc" "1"
assert_contains "repomix stderr surfaced" "$out" "SHIMBOOM"

echo "── default output path (TOCTOU-free private dir) ──"
# [pin: issue #12 medium — default output now lives in a fresh mktemp -d dir]
set +e
SUMMARY="$(bash "$S/handoff.sh" --base "$BASE_BRANCH" --max-tokens 100000 2>/dev/null)"; rc=$?
set -e
assert_eq "default-output run exits 0" "$rc" "0"
outpath="$(printf '%s' "$SUMMARY" | python3 -c 'import json,sys; print(json.load(sys.stdin)["output"])')"
if [ -s "$outpath" ]; then ok "default output file exists"; else bad "default output missing ($outpath)"; fi
case "$outpath" in
  */repomix-handoff.*/handoff.md) ok "default output inside private mktemp dir" ;;
  *) bad "unexpected default output path shape: $outpath" ;;
esac
rm -rf "$(dirname "$outpath")"

echo "── dry-run ──"
set +e
DR="$(bash "$S/handoff.sh" --base "$BASE_BRANCH" --dry-run 2>/dev/null)"; rc=$?
set -e
assert_eq "dry-run exits 0" "$rc" "0"
assert_contains "dry-run flagged" "$DR" '"dry_run": true'
cfgpath="$(printf '%s' "$DR" | python3 -c 'import json,sys; print(json.load(sys.stdin)["config"])')"
if python3 -m json.tool "$cfgpath" >/dev/null 2>&1; then
  ok "dry-run config file is valid JSON (kept for reuse)"
else
  bad "dry-run config missing/invalid ($cfgpath)"
fi
rm -rf "$(dirname "$cfgpath")"

echo "── import expansion containment ──"
# [pin: issue #12 medium — expanded imports must not escape the repo root]
echo 'export const outside = "OUTSIDE";' > "$T/outside.ts"
git checkout -q -b expand
printf 'import { base } from "./base";\nimport { outside } from "../../outside";\n' > src/importer.ts
git add -A && git commit -q -m expand
SCOPE="$(bash "$S/compute_scope.sh" --base "$BASE_BRANCH" --expand-imports)"
assert_contains "in-repo import expanded" "$SCOPE" '"src/base.ts"'
assert_not_contains "out-of-repo import dropped" "$SCOPE" "outside.ts"
git checkout -q feature

echo "── ARG_MAX path (hundreds of files through the config handoff) ──"
# [pin: issue #12 design high — scope travels via config JSON + temp files]
REPO2="$T/repo2"
mkdir -p "$REPO2/gen"
cd "$REPO2"
git init -q . && git config user.email "t@t" && git config user.name "t"
echo 'export const seed = 0;' > seed.ts
git add -A && git commit -q -m base
BASE2="$(git rev-parse --abbrev-ref HEAD)"
git checkout -q -b feature
i=0
while [ "$i" -lt 300 ]; do
  printf 'export const v%03d = "FILE_%03d_MARKER";\n' "$i" "$i" > "$(printf 'gen/f%03d.ts' "$i")"
  i=$((i + 1))
done
git add -A && git commit -q -m big
set +e
SUMMARY="$(bash "$S/handoff.sh" --base "$BASE2" --max-tokens 1000000 --output "$T/big.md" 2>"$T/big.err")"; rc=$?
set -e
assert_eq "300-file handoff exits 0" "$rc" "0"
n_inc="$(printf '%s' "$SUMMARY" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["files_included"]))')"
assert_eq "all 300 files in scope" "$n_inc" "300"
assert_contains "last file's content packed" "$(cat "$T/big.md")" "FILE_299_MARKER"

echo
echo "repomix-handoff tests: $PASS ok, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
