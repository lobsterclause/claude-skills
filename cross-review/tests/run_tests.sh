#!/usr/bin/env bash
# run_tests.sh — offline fixture tests for the cross-review scripts.
#
# NO network, NO reviewer CLIs, NO tokens: reviewer binaries are PATH shims,
# the runlog is a fixture via $CROSS_REVIEW_RUNLOG, and git repos are created
# in a temp dir. Every case pins a behavior a real review round flagged (or
# falsified) on PR #18 — see the [pin: ...] tags.
#
# Run:  bash tests/run_tests.sh          (from the skill root or anywhere)
# Exit: 0 all green, 1 any failure.
#
# Portability: macOS bash 3.2 + ubuntu bash 5; needs jq, git, and a coreutils
# timeout (gtimeout on macOS via brew).

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

# ── PATH shims: fake reviewer binaries so availability checks pass and the
# kimi tests run hermetically. Fake agy prints a models list instantly.
mkdir -p "$T/bin"
printf '#!/bin/sh\ncat >/dev/null 2>&1 || true\nprintf "shim review: no findings\\n"\n' >"$T/bin/kimi"
printf '#!/bin/sh\nprintf "shim\\n"\n' >"$T/bin/codex"
printf '#!/bin/sh\nif [ "$1" = "models" ]; then printf "Gemini 3.5 Flash (High)\\nGemini 3.1 Pro (High)\\n"; fi\n' >"$T/bin/agy"
chmod +x "$T/bin/"*
export PATH="$T/bin:$PATH"
export OPENROUTER_API_KEY="sk-or-test-shim"   # lights the OR pool; never called
# Sandbox HOME: the selector caches `agy models` output under
# $HOME/.cross-review/cache with a 6h TTL — running tests against the real
# HOME would poison real roster draws with the shim's list (codex P2, PR #19).
export HOME="$T/home"
mkdir -p "$HOME"

# ── Fixture runlog ────────────────────────────────────────────────────────────
# codex: 2 ok runs, findings 3+1=4, convergent 1, dropped 0 → score 74
#   (0.45*1.0 + 0.35*0.25 + 0.20*1.0 = 0.7375 → 74); p50 of [100,200] → 200
# kimi: 1 ok, no findings data → telemetry-only: 100*1.0*0.75 = 75
# gemini-pro: ok,failed,failed,quota → reliability 1/4 → 18.75 → 19; quota=1
# fugu: absent → rookie prior 50
FIXLOG="$T/runlog.jsonl"
cat >"$FIXLOG" <<'EOF'
{"ts":"2026-07-01T01:00:00Z","reviewers":{"codex":{"status":"ok","exit_code":0,"duration_s":100,"output_bytes":10,"timeout_budget_s":300,"findings_total":3,"findings_convergent":1,"findings_dropped":0},"kimi":{"status":"ok","exit_code":0,"duration_s":40,"output_bytes":10,"timeout_budget_s":600},"gemini-pro":{"status":"ok","exit_code":0,"duration_s":50,"output_bytes":10,"timeout_budget_s":900}}}
{"ts":"2026-07-01T02:00:00Z","reviewers":{"codex":{"status":"ok","exit_code":0,"duration_s":200,"output_bytes":10,"timeout_budget_s":300,"findings_total":1,"findings_convergent":0,"findings_dropped":0},"gemini-pro":{"status":"failed","exit_code":2,"duration_s":20,"output_bytes":0,"timeout_budget_s":900}}}
{"ts":"2026-07-01T03:00:00Z","reviewers":{"gemini-pro":{"status":"failed","exit_code":1,"duration_s":30,"output_bytes":0,"timeout_budget_s":900}}}
{"ts":"2026-07-01T04:00:00Z","reviewers":{"gemini-pro":{"status":"quota","exit_code":3,"duration_s":6,"output_bytes":0,"timeout_budget_s":900,"failure_kind":"quota_exhausted"}}}
EOF

echo "── leaderboard.sh (fixture scoring) ──"
LB="$(CROSS_REVIEW_RUNLOG="$FIXLOG" bash "$S/leaderboard.sh" --mode json)"
assert_eq "codex blended score (reliability+signal+survival)" \
  "$(jq -r '.[] | select(.reviewer=="codex") | .score' <<<"$LB")" "74"
assert_eq "codex p50 from sorted durations" \
  "$(jq -r '.[] | select(.reviewer=="codex") | .p50_duration_s' <<<"$LB")" "200"
assert_eq "kimi telemetry-only discount (rel×0.75)" \
  "$(jq -r '.[] | select(.reviewer=="kimi") | .score' <<<"$LB")" "75"
assert_eq "gemini-pro reliability with quota+failed runs" \
  "$(jq -r '.[] | select(.reviewer=="gemini-pro") | .score' <<<"$LB")" "19"
assert_eq "gemini-pro quota count" \
  "$(jq -r '.[] | select(.reviewer=="gemini-pro") | .quota' <<<"$LB")" "1"
assert_eq "never-run reviewer gets rookie prior" \
  "$(jq -r '.[] | select(.reviewer=="fugu") | .score' <<<"$LB")" "50"
assert_eq "rookie flag set" \
  "$(jq -r '.[] | select(.reviewer=="fugu") | .rookie' <<<"$LB")" "true"

echo "── append_runlog.sh (status classification + enrichment) ──"
# [pin: fugu pass-1 High FALSIFIED — missing meta must be skipped, not failed]
RUN="$T/run1"; mkdir -p "$RUN/raw"
printf '{"exit_code": 0, "duration_s": 60, "timed_out": false, "output_bytes": 500, "attempt": 1, "timeout_budget_s": 300}\n' >"$RUN/raw/codex.meta.json"
printf '{"exit_code": 3, "duration_s": 6, "timed_out": false, "output_bytes": 0, "attempt": 1, "timeout_budget_s": 600, "model": "Gemini 3.5 Flash (High)", "cli": "agy", "failure_kind": "quota_exhausted", "quota_resets_in": "41h"}\n' >"$RUN/raw/antigravity.meta.json"
cat >"$RUN/findings.json" <<'EOF'
{"findings":[
 {"id":"f1","file":"a.sh","line":1,"claim":"x","sources":["codex","glm"],"factcheck":{"verdict":"keep"}},
 {"id":"f2","file":"a.sh","line":2,"claim":"y","sources":["codex"],"factcheck":{"verdict":"drop","reason":"r"}},
 {"id":"f3","file":"a.sh","line":3,"claim":"z","sources":["antigravity","gemini-pro"],"factcheck":{"verdict":"keep"}}
]}
EOF
TESTLOG="$T/out-runlog.jsonl"
CROSS_REVIEW_RUNLOG="$TESTLOG" bash "$S/append_runlog.sh" \
  --run-dir "$RUN" --project test --base main --pr - --pass 1 \
  --verdict CLEAN --convergent 1 --top "-" --findings "$RUN/findings.json" >/dev/null 2>&1
ENTRY="$(tail -1 "$TESTLOG")"
assert_eq "missing meta → skipped (fugu falsification pinned)" \
  "$(jq -r '.reviewers.kimi.status' <<<"$ENTRY")" "skipped"
assert_eq "quota failure_kind → status quota" \
  "$(jq -r '.reviewers.antigravity.status' <<<"$ENTRY")" "quota"
assert_eq "enrichment: codex findings_total" \
  "$(jq -r '.reviewers.codex.findings_total' <<<"$ENTRY")" "2"
assert_eq "enrichment: cross-provider convergence (codex+glm)" \
  "$(jq -r '.reviewers.codex.findings_convergent' <<<"$ENTRY")" "1"
assert_eq "enrichment: factcheck drop counted" \
  "$(jq -r '.reviewers.codex.findings_dropped' <<<"$ENTRY")" "1"
assert_eq "same-provider agreement NOT convergent (agy laps)" \
  "$(jq -r '.reviewers.antigravity.findings_convergent' <<<"$ENTRY")" "0"

echo "── select_roster.sh (determinism, floor, --fast fallback) ──"
# select_roster.sh doesn't read CROSS_REVIEW_RUNLOG itself — it shells out to
# leaderboard.sh, which inherits the exported var and reads the fixture. The
# --fast test below proves the plumbing: its filter only triggers on the
# fixture's p50 values. (minimax flagged this as broken on PR #19; it isn't.)
R1="$(CROSS_REVIEW_RUNLOG="$FIXLOG" bash "$S/select_roster.sh" --seed 99 2>/dev/null)"
R2="$(CROSS_REVIEW_RUNLOG="$FIXLOG" bash "$S/select_roster.sh" --seed 99 2>/dev/null)"
assert_eq "seeded draw is deterministic" "$R1" "$R2"
assert_contains "baseline codex always on" "$R1" "codex"
assert_contains "baseline kimi always on" "$R1" "kimi"
N_R1="$(awk -F',' '{print NF}' <<<"$R1")"
if [[ "$N_R1" -ge 3 ]]; then ok "roster ≥3 ($N_R1)"; else bad "roster <3 ($R1)"; fi
# [pin: kimi+deepseek pass-3 convergent + codex pass-4 P2 — --fast over-filter
# must redraw unfiltered and keep the floor]
SLOWLOG="$T/slow-runlog.jsonl"
jq -nc '{ts:"2026-07-01T05:00:00Z", reviewers: (
  ["antigravity","gemini-pro","glm","deepseek","mimo","minimax","fugu","north","nemotron"]
  | map({key: ., value: {status:"ok", exit_code:0, duration_s:5000, output_bytes:10, timeout_budget_s:600}}) | from_entries)}' >"$SLOWLOG"
FAST_ERR="$T/fast.err"
RF="$(CROSS_REVIEW_RUNLOG="$SLOWLOG" bash "$S/select_roster.sh" --seed 7 --fast 2>"$FAST_ERR")"
N_RF="$(awk -F',' '{print NF}' <<<"$RF")"
if [[ "$N_RF" -ge 3 ]]; then ok "--fast over-filter keeps ≥3 roster via fallback ($RF)"; else bad "--fast shipped sub-floor roster ($RF)"; fi
assert_contains "--fast fallback announces the redraw" "$(cat "$FAST_ERR")" "redrawing without the speed filter"

echo "── run_reviewers.sh kimi budget + rc137 (shim kimi, fixture repo) ──"
REPO="$T/repo"; mkdir -p "$REPO"; cd "$REPO"
git init -q -b main 2>/dev/null || git init -q
seq 1 20 >f.txt; git add .; git -c user.email=t@t -c user.name=t commit -qm init
git checkout -qb feat
seq 1 2600 | sed 's/^/line /' >f.txt; git add .; git -c user.email=t@t -c user.name=t commit -qm big
TOTAL_LINES="$(git diff main...HEAD | wc -l | tr -d ' ')"
# (a) explicit cap honored verbatim [pin: codex pass-3 P2]
bash "$S/run_reviewers.sh" --base main --out "$T/o1" --reviewers kimi --timeout-kimi 60 >/dev/null 2>&1
assert_eq "explicit --timeout-kimi wins over size scaling" \
  "$(jq -r '.timeout_budget_s' "$T/o1/kimi.meta.json")" "60"
# (b) no explicit cap → ceiling-scaled budget [pin: north pass-3 ceil nit]
bash "$S/run_reviewers.sh" --base main --out "$T/o2" --reviewers kimi >/dev/null 2>&1
EXPECT=$(( 600 + 500 * ( (TOTAL_LINES - 1000 + 999) / 1000 ) )); [[ "$EXPECT" -gt 3000 ]] && EXPECT=3000
assert_eq "size-scaled kimi budget (ceil, ${TOTAL_LINES}-line diff)" \
  "$(jq -r '.timeout_budget_s' "$T/o2/kimi.meta.json")" "$EXPECT"
# (c) rc 137 = timed_out, never retried [pin: codex pass-3 P2]
printf '#!/bin/sh\ncat >/dev/null 2>&1 || true\nexit 137\n' >"$T/bin/kimi"
bash "$S/run_reviewers.sh" --base main --out "$T/o3" --reviewers kimi --timeout-kimi 60 >/dev/null 2>&1
assert_eq "rc 137 classified timed_out" "$(jq -r '.timed_out' "$T/o3/kimi.meta.json")" "true"
assert_eq "rc 137 not retried" "$(jq -r '.attempt' "$T/o3/kimi.meta.json")" "1"
printf '#!/bin/sh\ncat >/dev/null 2>&1 || true\nprintf "shim review: no findings\\n"\n' >"$T/bin/kimi"

echo "── anchor_findings.sh (resolve vs hallucinated location) ──"
cat >"$T/anchor.json" <<EOF
{"base":"main","head":"HEAD","findings":[
 {"id":"a1","severity":"High","file":"f.txt","line":5,"snippet":"line 42","claim":"real line","sources":["codex"]},
 {"id":"a2","severity":"Low","file":"f.txt","line":9,"snippet":"this text exists nowhere in the diff","claim":"hallucinated","sources":["glm"]}
]}
EOF
bash "$S/anchor_findings.sh" --findings "$T/anchor.json" --base main --repo "$REPO" --out "$T/anchored.json" >/dev/null 2>&1
assert_eq "real snippet anchors" \
  "$(jq -r '.findings[] | select(.id=="a1") | .anchor.resolved' "$T/anchored.json")" "true"
assert_eq "hallucinated snippet stays unanchored" \
  "$(jq -r '.findings[] | select(.id=="a2") | .anchor.resolved' "$T/anchored.json")" "false"

echo "── import_runlog.sh (idempotent merge) ──"
SRC="$T/src.jsonl"; DST="$T/dst.jsonl"; : >"$DST"
printf '{"ts":"2026-06-01T00:00:00Z","reviewers":{"codex":{"status":"ok"}}}\nnot json garbage\n{"ts":"2026-06-02T00:00:00Z","reviewers":{"kimi":{"status":"ok"}}}\n' >"$SRC"
bash "$S/import_runlog.sh" --from "$SRC" --into "$DST" >/dev/null 2>&1
assert_eq "import: valid lines merged, garbage skipped" "$(wc -l <"$DST" | tr -d ' ')" "2"
bash "$S/import_runlog.sh" --from "$SRC" --into "$DST" >/dev/null 2>&1
assert_eq "import: re-import adds nothing (idempotent)" "$(wc -l <"$DST" | tr -d ' ')" "2"

echo "── dual-copy identity (repo context only) ──"
# [pin: mimo pass-4 — the two in-repo copies must never drift again]
REPO_ROOT="$(cd "$SKILL_DIR/.." 2>/dev/null && git rev-parse --show-toplevel 2>/dev/null || true)"
COPY_A="$REPO_ROOT/cross-review"
COPY_B="$REPO_ROOT/plugins/cross-review/skills/cross-review"
if [[ -n "$REPO_ROOT" && -d "$COPY_A" && -d "$COPY_B" ]]; then
  if diff -r --exclude 'runlog.jsonl*' --exclude 'iteration-1' --exclude '*.bak*' --exclude '.DS_Store' "$COPY_A" "$COPY_B" >/dev/null 2>&1; then
    ok "root copy ≡ plugin copy"
  else
    bad "root copy and plugin copy have drifted — sync before merging"
  fi
else
  echo "  skip dual-copy identity (not in the skills repo)"
fi

echo
echo "══ $PASS passed, $FAIL failed ══"
[[ "$FAIL" -eq 0 ]]
