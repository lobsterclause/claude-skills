#!/usr/bin/env bash
# test_diff_findings.sh — standalone offline fixture test for
# scripts/diff_findings.sh. NO network, no reviewer CLIs, no tokens.
#
# Mirrors test_fingerprint_namespace.sh / test_score_findings.sh's
# fixture/assertion conventions (assert_eq/assert_contains, mktemp -d + trap
# cleanup) but is intentionally NOT wired into run_tests.sh — the parent
# orchestrating session wires it in later (collision avoidance).
#
# Run:  bash tests/test_diff_findings.sh
# Exit: 0 all green, 1 any failure.

set -uo pipefail

SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
D="$SKILL_DIR/scripts/diff_findings.sh"
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

if [[ ! -f "$D" ]]; then
  echo "FATAL: $D not found — implement scripts/diff_findings.sh" >&2
  exit 1
fi

# ── Fixture verified-findings files ───────────────────────────────────────
# Round 1 (prev1): f-aaaaaaaa (High), f-bbbbbbbb (Critical), f-cccccccc (Low, dropped by factcheck)
# Round 2 (curr1 == prev2): f-aaaaaaaa fixed; f-bbbbbbbb still open; f-dddddddd newly introduced
# Round 3 (curr2): f-bbbbbbbb still open (3rd round survivor); f-dddddddd fixed; f-eeeeeeee newly introduced
ROUND1="$T/round1.verified.json"
cat >"$ROUND1" <<'EOF'
{
  "findings": [
    { "id": "f-aaaaaaaa", "severity": "High", "file": "src/api.ts", "line": 12,
      "claim": "Missing null check on user input", "sources": ["codex"] },
    { "id": "f-bbbbbbbb", "severity": "Critical", "file": "src/auth.ts", "line": 40,
      "claim": "SQL injection via string concat", "sources": ["codex", "kimi"] },
    { "id": "f-cccccccc", "severity": "Low", "file": "src/style.ts", "line": 1,
      "claim": "trailing whitespace", "sources": ["codex"],
      "factcheck": {"verdict": "drop", "reason": "line not present in diff"} }
  ]
}
EOF

ROUND2="$T/round2.verified.json"
cat >"$ROUND2" <<'EOF'
{
  "findings": [
    { "id": "f-bbbbbbbb", "severity": "Critical", "file": "src/auth.ts", "line": 41,
      "claim": "SQL injection via string concat", "sources": ["codex", "kimi"] },
    { "id": "f-dddddddd", "severity": "Medium", "file": "src/db.ts", "line": 8,
      "claim": "New helper drops the transaction on error", "sources": ["kimi27"] }
  ]
}
EOF

ROUND3="$T/round3.verified.json"
cat >"$ROUND3" <<'EOF'
{
  "findings": [
    { "id": "f-bbbbbbbb", "severity": "Critical", "file": "src/auth.ts", "line": 41,
      "claim": "SQL injection via string concat", "sources": ["codex", "kimi"] },
    { "id": "f-eeeeeeee", "severity": "High", "file": "src/queue.ts", "line": 3,
      "claim": "Retry loop has no backoff", "sources": ["glm"] }
  ]
}
EOF

echo "── two fixture files bucket correctly (fixed / still_open / newly_introduced) ──"
OUT1="$T/diff1.json"
"$D" --prev "$ROUND1" --curr "$ROUND2" --format json --out "$OUT1"
fixed_ids="$(jq -r '.fixed[].id' "$OUT1" | sort | tr '\n' ',')"
still_ids="$(jq -r '.still_open[].id' "$OUT1" | sort | tr '\n' ',')"
new_ids="$(jq -r '.newly_introduced[].id' "$OUT1" | sort | tr '\n' ',')"
assert_eq "fixed bucket contains f-aaaaaaaa only" "$fixed_ids" "f-aaaaaaaa,"
assert_eq "still_open bucket contains f-bbbbbbbb only" "$still_ids" "f-bbbbbbbb,"
assert_eq "newly_introduced bucket contains f-dddddddd only" "$new_ids" "f-dddddddd,"
assert_eq "factcheck-dropped f-cccccccc never appears in any bucket" \
  "$(jq -r '[.fixed,.still_open,.newly_introduced] | flatten | map(.id) | index("f-cccccccc") // "absent"' "$OUT1")" "absent"

echo "── markdown output covers all three buckets ──"
OUT1_MD="$T/diff1.md"
"$D" --prev "$ROUND1" --curr "$ROUND2" --format md --out "$OUT1_MD"
md1="$(cat "$OUT1_MD")"
assert_contains "markdown mentions the fixed finding's claim" "$md1" "Missing null check on user input"
assert_contains "markdown lists the fixed finding under its heading" "$(printf '%s' "$md1" | sed -n '/### Fixed/,/### /p')" "src/api.ts"
assert_contains "markdown mentions the newly introduced finding's claim" "$md1" "drops the transaction on error"
assert_contains "markdown mentions the fixed finding's file" "$md1" "src/api.ts"

echo "── round count increments across three successive comparisons (not just two) ──"
still_rounds_1="$(jq -r '.still_open[] | select(.id=="f-bbbbbbbb") | .rounds' "$OUT1")"
assert_eq "round 1->2 survivor rounds == 2" "$still_rounds_1" "2"

OUT2="$T/diff2.json"
"$D" --prev "$ROUND2" --curr "$ROUND3" --format json --out "$OUT2" --prev-diff "$OUT1"
still_rounds_2="$(jq -r '.still_open[] | select(.id=="f-bbbbbbbb") | .rounds' "$OUT2")"
assert_eq "round 2->3 survivor rounds == 3 (chained via --prev-diff)" "$still_rounds_2" "3"

fixed_ids_2="$(jq -r '.fixed[].id' "$OUT2" | sort | tr '\n' ',')"
new_ids_2="$(jq -r '.newly_introduced[].id' "$OUT2" | sort | tr '\n' ',')"
assert_eq "round 2->3 fixed bucket contains f-dddddddd" "$fixed_ids_2" "f-dddddddd,"
assert_eq "round 2->3 newly_introduced bucket contains f-eeeeeeee" "$new_ids_2" "f-eeeeeeee,"

echo "── without --prev-diff chaining, a fresh comparison starts a survivor back at rounds=2 ──"
OUT2_NOCHAIN="$T/diff2-nochain.json"
"$D" --prev "$ROUND2" --curr "$ROUND3" --format json --out "$OUT2_NOCHAIN"
still_rounds_nochain="$(jq -r '.still_open[] | select(.id=="f-bbbbbbbb") | .rounds' "$OUT2_NOCHAIN")"
assert_eq "no chaining -> rounds resets to 2 (baseline), proving chaining is what drives the increment" \
  "$still_rounds_nochain" "2"

echo "── determinism: two runs on identical input produce identical bytes ──"
OUT_DET_A="$T/det_a.json"
OUT_DET_B="$T/det_b.json"
"$D" --prev "$ROUND1" --curr "$ROUND2" --format json --out "$OUT_DET_A"
"$D" --prev "$ROUND1" --curr "$ROUND2" --format json --out "$OUT_DET_B"
if diff -q "$OUT_DET_A" "$OUT_DET_B" >/dev/null 2>&1; then
  ok "json output byte-identical across repeated runs"
else
  bad "json output differs across repeated runs on identical input"
fi
OUT_DET_MD_A="$T/det_a.md"
OUT_DET_MD_B="$T/det_b.md"
"$D" --prev "$ROUND1" --curr "$ROUND2" --format md --out "$OUT_DET_MD_A"
"$D" --prev "$ROUND1" --curr "$ROUND2" --format md --out "$OUT_DET_MD_B"
if diff -q "$OUT_DET_MD_A" "$OUT_DET_MD_B" >/dev/null 2>&1; then
  ok "markdown output byte-identical across repeated runs"
else
  bad "markdown output differs across repeated runs on identical input"
fi

echo "── malformed --curr file is a clean nonzero error, not a partial write ──"
BAD_CURR="$T/bad.json"
printf 'not valid json{{{' > "$BAD_CURR"
if "$D" --prev "$ROUND1" --curr "$BAD_CURR" --format json --out "$T/bad-out.json" 2>"$T/bad-err.txt"; then
  bad "malformed --curr should exit non-zero"
else
  ok "malformed --curr exits non-zero"
fi
if [[ -s "$T/bad-out.json" ]]; then
  bad "malformed --curr should not produce a partial output file"
else
  ok "malformed --curr produces no partial output file"
fi

# ── Ledger reconstruction fixtures ────────────────────────────────────────
# Simulate a repo checked out with a real origin remote so --repo-root
# derives a stable namespace (mirrors test_fingerprint_namespace.sh's mk_repo).
mk_repo() {
  local dir="$1" remote="$2"
  mkdir -p "$dir"
  git -C "$dir" init -q
  [[ -n "$remote" ]] && git -C "$dir" remote add origin "$remote"
}
REPO_A="$T/repo-a"
mk_repo "$REPO_A" "https://github.com/acme/widget.git"

LEDGER="$T/finding_events.jsonl"
cat >"$LEDGER" <<'EOF'
{"event":"proposed","ts":"2026-08-01T00:00:00Z","finding_id":"f-aaaaaaaa","run_id":"run-1","reviewer":"codex","all_sources":["codex"],"severity":"High","file":"src/api.ts","claim":"Missing null check on user input"}
{"event":"proposed","ts":"2026-08-01T00:00:01Z","finding_id":"f-bbbbbbbb","run_id":"run-1","reviewer":"codex","all_sources":["codex","kimi"],"severity":"Critical","file":"src/auth.ts","claim":"SQL injection via string concat"}
{"event":"proposed","ts":"2026-08-01T00:00:02Z","finding_id":"f-cccccccc","run_id":"run-1","reviewer":"codex","all_sources":["codex"],"severity":"Low","file":"src/style.ts","claim":"trailing whitespace"}
this line is not json at all
{"event":"factcheck_dropped","ts":"2026-08-01T00:00:03Z","finding_id":"f-cccccccc","run_id":"run-1","reason":"line not present in diff"}
{"event":"proposed","ts":"2026-08-02T00:00:00Z","finding_id":"f-bbbbbbbb","run_id":"run-2","reviewer":"codex","all_sources":["codex","kimi"],"severity":"Critical","file":"src/auth.ts","claim":"SQL injection via string concat"}
{"event":"proposed","ts":"2026-08-02T00:00:01Z","finding_id":"f-dddddddd","run_id":"run-2","reviewer":"kimi27","all_sources":["kimi27"],"severity":"Medium","file":"src/db.ts","claim":"New helper drops the transaction on error"}
{"event":"proposed","ts":"2026-08-02T00:00:02Z","finding_id":"f-bbbbbbbb","run_id":"run-2","project":"remote:github.com/other-org/other-repo","reviewer":"codex","all_sources":["codex"],"severity":"Critical","file":"src/auth.ts","claim":"unrelated finding from a different project sharing the same hash"}
EOF

echo "── error paths (PR #85 review: kimi, codex, spark) ──"
printf '{"findings": "not-an-array"}' >"$T/bad-shape.json"
"$D" --prev "$T/bad-shape.json" --curr "$ROUND2" --format json --out "$T/should-not-exist.json" >/dev/null 2>"$T/bad-shape.err"; rc=$?
assert_eq "a findings file with the wrong shape exits 1" "$rc" "1"
[[ ! -f "$T/should-not-exist.json" ]] && ok "…and writes no partial --out" || bad "partial --out written on error"
printf '{not json' >"$T/bad.json"
"$D" --prev "$T/bad.json" --curr "$ROUND2" --format json >/dev/null 2>&1; rc=$?
assert_eq "invalid --prev JSON exits non-zero" "$(( rc != 0 ))" "1"
"$D" --prev "$ROUND1" --curr "$ROUND2" --prev-diff "$T/bad.json" --format json >/dev/null 2>&1; rc=$?
assert_eq "invalid --prev-diff JSON exits non-zero" "$(( rc != 0 ))" "1"
CROSS_REVIEW_FINDING_EVENTS="$T/no-such-ledger.jsonl" "$D" --curr "$ROUND2" --run-id run-2 --project p --format json >/dev/null 2>"$T/noledger.err"; rc=$?
assert_eq "missing ledger exits 1 when --prev is omitted" "$rc" "1"
assert_contains "…and names the path" "$(cat "$T/noledger.err")" "ledger not found or empty"
CROSS_REVIEW_FINDING_EVENTS="$T/no-such-ledger.jsonl" "$D" --curr "$ROUND2" --run-id run-2 --project p --format json --allow-empty-prev >"$T/empty-prev.json" 2>/dev/null; rc=$?
assert_eq "--allow-empty-prev permits a first round" "$rc" "0"
assert_eq "…everything is newly_introduced" "$(jq -r '.counts.newly_introduced' "$T/empty-prev.json")" "2"
assert_eq "…and prev provenance says so" "$(jq -r '.prev.source' "$T/empty-prev.json")" "empty_ledger"
CROSS_REVIEW_FINDING_EVENTS="$LEDGER" "$D" --curr "$ROUND3" --run-id "no-such-run" --repo-root "$REPO_A" --format json --out "$T/lastrun.json" 2>"$T/lastrun.err" >/dev/null
assert_eq "unknown --run-id falls back to the newest run and says which" "$(jq -r '.prev.source' "$T/lastrun.json")" "ledger_last_run"
assert_contains "…with a WARN on stderr" "$(cat "$T/lastrun.err")" "not in the ledger"
printf '{"findings":[{"id":null,"severity":"Low","file":"x","claim":"no id"},{"id":"","severity":"Low","file":"y","claim":"empty id"},{"id":"f-eeeeeeee","severity":"Low","file":"z","claim":"ok"}]}' >"$T/nullid.json"
"$D" --prev "$ROUND1" --curr "$T/nullid.json" --format json --out "$T/nullid.out.json" >/dev/null 2>&1
assert_eq "null/empty ids are dropped from the buckets" "$(jq -r '[.newly_introduced[].id] | join(",")' "$T/nullid.out.json")" "f-eeeeeeee"
assert_eq "explicit --prev provenance is recorded" "$(jq -r '.prev.source' "$T/nullid.out.json")" "file"
# A missing parent directory is unwritable for root too (spark): mktemp in
# the destination directory fails before anything is written.
"$D" --prev "$ROUND1" --curr "$ROUND2" --format json --out "$T/no-such-dir/sub/out.json" >/dev/null 2>&1; rc=$?
assert_eq "unwritable --out exits 1" "$rc" "1"
for shape in '{}' '{"findings":null}' '{"findings":{"a":1}}'; do
  printf '%s' "$shape" >"$T/shape.json"
  "$D" --prev "$T/shape.json" --curr "$ROUND2" --format json >/dev/null 2>&1; rc=$?
  assert_eq "shape $shape is rejected, not an empty snapshot" "$rc" "1"
done
printf '{"run_id":"other-1","event":"proposed","finding_id":"f-x","project":"remote:github.com/other/repo"}\n{not json\n' >"$T/foreign.jsonl"
CROSS_REVIEW_FINDING_EVENTS="$T/foreign.jsonl" "$D" --curr "$ROUND2" --run-id run-2 --project p --format json >/dev/null 2>"$T/foreign.err"; rc=$?
assert_eq "a ledger with no usable run for our project exits 1" "$rc" "1"
assert_contains "…and says so" "$(cat "$T/foreign.err")" "no usable run"

echo "── malformed ledger line is skipped, counted on stderr, never fatal ──"
STDERR_FILE="$T/ledger-stderr.txt"
CROSS_REVIEW_FINDING_EVENTS="$LEDGER" "$D" --curr "$ROUND2" --run-id "run-2" \
  --repo-root "$REPO_A" --format json --out "$T/ledger-recon.json" 2>"$STDERR_FILE"
recon_rc=$?
assert_eq "ledger reconstruction with a malformed line still exits 0" "$recon_rc" "0"
malformed_count="$(grep -c "malformed" "$STDERR_FILE" || true)"
if [[ "$malformed_count" -ge 1 ]]; then
  ok "malformed ledger line reported on stderr"
else
  bad "expected a 'malformed' notice on stderr, got: $(cat "$STDERR_FILE")"
fi

echo "── --prev omitted: ledger reconstruction produces the same buckets as the explicit-file path ──"
recon_fixed="$(jq -r '.fixed[].id' "$T/ledger-recon.json" | sort | tr '\n' ',')"
recon_still="$(jq -r '.still_open[].id' "$T/ledger-recon.json" | sort | tr '\n' ',')"
recon_new="$(jq -r '.newly_introduced[].id' "$T/ledger-recon.json" | sort | tr '\n' ',')"
assert_eq "ledger-reconstructed fixed bucket matches explicit-file path" "$recon_fixed" "$fixed_ids"
assert_eq "ledger-reconstructed still_open bucket matches explicit-file path" "$recon_still" "$still_ids"
assert_eq "ledger-reconstructed newly_introduced bucket matches explicit-file path" "$recon_new" "$new_ids"

echo "── cross-project isolation: an identical-shaped id tagged with a different project never bleeds in ──"
# The ledger above also contains a THIRD f-bbbbbbbb "proposed" event at run-2
# explicitly tagged project=remote:github.com/other-org/other-repo (a
# different namespace than repo-a/widget). It must not change f-bbbbbbbb's
# reconstructed fields/membership for repo-a's namespace, and must not
# spuriously introduce any new id.
all_recon_ids="$(jq -r '[.fixed,.still_open,.newly_introduced] | flatten | map(.id) | unique | sort | join(",")' "$T/ledger-recon.json")"
assert_eq "no id bleeds in from the other project's namespace" "$all_recon_ids" "f-aaaaaaaa,f-bbbbbbbb,f-dddddddd"

echo
echo "══ $PASS passed, $FAIL failed ══"
[[ "$FAIL" -eq 0 ]]
