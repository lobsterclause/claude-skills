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
export MOONSHOT_API_KEY="sk-ms-test-shim"     # lights the kimi27 seat; never called
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
# nemotron: absent → rookie prior 50
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
  "$(jq -r '.[] | select(.reviewer=="nemotron") | .score' <<<"$LB")" "50"
assert_eq "rookie flag set" \
  "$(jq -r '.[] | select(.reviewer=="nemotron") | .rookie' <<<"$LB")" "true"

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

echo "── append_runlog.sh (reasonless-drop evidence gate) ──"
# [pin: falsification evidence is binding — a drop without factcheck.reason
# must reject the append, not silently starve the leaderboard]
cat >"$T/bad-findings.json" <<'EOF'
{"findings":[
 {"id":"g1","file":"a.sh","line":1,"claim":"x","sources":["codex"],"factcheck":{"verdict":"drop","reason":""}},
 {"id":"g2","file":"a.sh","line":2,"claim":"y","sources":["kimi"],"factcheck":{"verdict":"drop"}}
]}
EOF
GATELOG="$T/gate-runlog.jsonl"
CROSS_REVIEW_RUNLOG="$GATELOG" bash "$S/append_runlog.sh" \
  --run-dir "$RUN" --project test --base main --pr - --pass 1 \
  --verdict CLEAN --convergent 0 --top "-" --findings "$T/bad-findings.json" >/dev/null 2>"$T/gate.err"
rc=$?
assert_eq "reasonless drops reject with exit 2" "$rc" "2"
assert_contains "gate names the offending findings" "$(cat "$T/gate.err")" "g1, g2"
[ ! -s "$GATELOG" ] && ok "nothing appended on gate rejection" || bad "runlog written despite gate rejection"
cat >"$T/nonstring-findings.json" <<'EOF'
{"findings":[
 {"id":"g4","file":"a.sh","line":4,"claim":"w","sources":["glm"],"factcheck":{"verdict":"drop","reason":{"oops":"object"}}}
]}
EOF
CROSS_REVIEW_RUNLOG="$GATELOG" bash "$S/append_runlog.sh" \
  --run-dir "$RUN" --project test --base main --pr - --pass 1 \
  --verdict CLEAN --convergent 0 --top "-" --findings "$T/nonstring-findings.json" >/dev/null 2>&1
assert_eq "non-string reason counts as reasonless (exit 2)" "$?" "2"
printf 'not json\n' >"$T/garbage-findings.json"
CROSS_REVIEW_RUNLOG="$GATELOG" bash "$S/append_runlog.sh" \
  --run-dir "$RUN" --project test --base main --pr - --pass 1 \
  --verdict CLEAN --convergent 0 --top "-" --findings "$T/garbage-findings.json" >/dev/null 2>&1
assert_eq "malformed findings JSON rejects (exit 2)" "$?" "2"
cat >"$T/good-findings.json" <<'EOF'
{"findings":[
 {"id":"g3","file":"a.sh","line":3,"claim":"z","sources":["codex"],"factcheck":{"verdict":"drop","reason":"falsified: coreutils timeout -k exits 137; call sites treat 124||137 as timed_out"}}
]}
EOF
CROSS_REVIEW_RUNLOG="$GATELOG" bash "$S/append_runlog.sh" \
  --run-dir "$RUN" --project test --base main --pr - --pass 1 \
  --verdict CLEAN --convergent 0 --top "-" --findings "$T/good-findings.json" >/dev/null 2>&1
assert_eq "evidenced drop appends fine" "$?" "0"
assert_eq "gated entry landed in runlog" "$(wc -l <"$GATELOG" | tr -d ' ')" "1"

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
  ["antigravity","gemini-pro","glm","deepseek","mimo","minimax","qwen","devstral","laguna","kat","north","nemotron","kimi27"]
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

echo "── degenerate-output detection (glm 'wait'-loop class) ──"
# [pin: PR #25 pass 3 — glm exited 0 with 145KB of repetition; the leaderboard
# counted it as a reliable run. gzip-ratio detector: degenerate ≈69:1 vs
# healthy 2-3:1 (calibrated on 2026-07-02 real outputs); threshold 15:1]
cat >"$T/bin/kimi" <<'SHIM'
#!/bin/sh
cat >/dev/null 2>&1 || true
i=0; while [ $i -lt 3000 ]; do printf 'wait wait wait wait wait wait wait wait '; i=$((i+1)); done
SHIM
chmod +x "$T/bin/kimi"
# NOTE: this suite deliberately runs WITHOUT set -e (naked expected-fail
# calls throughout) — do not flip it on here; a stray `set -e` mid-file
# aborted the suite at the next nonzero exit (caught pre-merge, PR #26).
bash "$S/run_reviewers.sh" --base main --out "$T/o5" --reviewers kimi --timeout-kimi 60 >/dev/null 2>&1 || true
assert_eq "degenerate output stamps failure_kind" \
  "$(jq -r '.failure_kind' "$T/o5/kimi.meta.json")" "degenerate_output"
assert_eq "degenerate output classifies exit 5" \
  "$(jq -r '.exit_code' "$T/o5/kimi.meta.json")" "5"
printf '{"exit_code": 5, "duration_s": 9, "timed_out": false, "output_bytes": 96000, "attempt": 1, "timeout_budget_s": 600, "failure_kind": "degenerate_output"}\n' >"$RUN/raw/glm.meta.json"
DEGLOG="$T/degen-runlog.jsonl"
CROSS_REVIEW_RUNLOG="$DEGLOG" bash "$S/append_runlog.sh" \
  --run-dir "$RUN" --project test --base main --pr - --pass 1 \
  --verdict CLEAN --convergent 0 --top "-" >/dev/null 2>&1
assert_eq "runlog status is degenerate, not ok" \
  "$(tail -1 "$DEGLOG" | jq -r '.reviewers.glm.status')" "degenerate"
rm -f "$RUN/raw/glm.meta.json"
printf '#!/bin/sh\ncat >/dev/null 2>&1 || true\nprintf "shim review: no findings\\n"\n' >"$T/bin/kimi"

echo "── OpenRouter cost accounting (fugu lesson) ──"
# [pin: PR #20 follow-up — usage:{include:true} cost lands in meta so the
# leaderboard can weight findings-per-dollar; fugu burned $4.74 in one call
# and only the billing dashboard knew]
cat >"$T/canned_or_response.json" <<'EOF'
{"choices":[{"message":{"content":"## Critical\nNone.\n\n## High\nNone. Clean — no findings."}}],"usage":{"prompt_tokens":1000,"completion_tokens":50,"cost":0.0123}}
EOF
cat >"$T/bin/curl" <<SHIM
#!/bin/sh
cat "$T/canned_or_response.json"
SHIM
chmod +x "$T/bin/curl"
bash "$S/run_reviewers.sh" --base main --out "$T/o6" --reviewers glm >/dev/null 2>&1 || true
assert_eq "OR meta carries cost_usd" "$(jq -r '.cost_usd' "$T/o6/glm.meta.json")" "0.0123"
assert_eq "OR meta carries tokens_prompt" "$(jq -r '.tokens_prompt' "$T/o6/glm.meta.json")" "1000"
assert_eq "OR request asks for usage accounting" \
  "$(jq -r '.usage.include' "$T/o6/glm.request.json")" "true"
rm -f "$T/bin/curl"

# retry accumulates spend: attempt 1 charged but preamble-only (rc=5, retried),
# attempt 2 charged and good — meta must carry the SUM, not the last attempt
# [pin: codex P2, PR #28 pass 1 — leaderboard undercounted flaky-expensive]
cat >"$T/canned_or_preamble.json" <<'EOF'
{"choices":[{"message":{"content":"I will now begin reviewing the changes."}}],"usage":{"prompt_tokens":900,"completion_tokens":9,"cost":0.01}}
EOF
cat >"$T/canned_or_good.json" <<'EOF'
{"choices":[{"message":{"content":"## Critical\nNone.\n\n## High\nNone. Clean — no findings."}}],"usage":{"prompt_tokens":900,"completion_tokens":40,"cost":0.02}}
EOF
rm -f "$T/curl_calls"
cat >"$T/bin/curl" <<SHIM
#!/bin/sh
echo x >> "$T/curl_calls"
if [ "\$(wc -l < "$T/curl_calls" | tr -d ' ')" -ge 2 ]; then
  cat "$T/canned_or_good.json"
else
  cat "$T/canned_or_preamble.json"
fi
SHIM
chmod +x "$T/bin/curl"
bash "$S/run_reviewers.sh" --base main --out "$T/o7" --reviewers glm >/dev/null 2>&1 || true
assert_eq "retried run reports summed cost" "$(jq -r '.cost_usd' "$T/o7/glm.meta.json")" "0.030000"
assert_eq "second attempt recorded" "$(jq -r '.attempt' "$T/o7/glm.meta.json")" "2"
rm -f "$T/bin/curl" "$T/curl_calls"

# leaderboard: avg_cost_usd aggregates; roster draw halves a $0.50 reviewer
COSTLOG="$T/cost-runlog.jsonl"
cat >"$COSTLOG" <<'EOF'
{"ts":"2026-07-03T01:00:00Z","reviewers":{"glm":{"status":"ok","exit_code":0,"duration_s":50,"output_bytes":10,"timeout_budget_s":600,"cost_usd":0.5},"deepseek":{"status":"ok","exit_code":0,"duration_s":50,"output_bytes":10,"timeout_budget_s":600,"cost_usd":0}}}
{"ts":"2026-07-03T02:00:00Z","reviewers":{"glm":{"status":"ok","exit_code":0,"duration_s":50,"output_bytes":10,"timeout_budget_s":600,"cost_usd":0.5},"deepseek":{"status":"ok","exit_code":0,"duration_s":50,"output_bytes":10,"timeout_budget_s":600,"cost_usd":0}}}
EOF
CLB="$(CROSS_REVIEW_RUNLOG="$COSTLOG" bash "$S/leaderboard.sh" --mode json)"
assert_eq "leaderboard aggregates avg_cost_usd" \
  "$(jq -r '.[] | select(.reviewer=="glm") | .avg_cost_usd' <<<"$CLB")" "0.5"
assert_eq "zero-cost reviewer stays 0" \
  "$(jq -r '.[] | select(.reviewer=="deepseek") | .avg_cost_usd' <<<"$CLB")" "0"
# identical twins except cost: expensive one draws at half weight
CAND="$(CROSS_REVIEW_RUNLOG="$COSTLOG" bash "$S/select_roster.sh" --seed 5 2>&1 >/dev/null | grep '^  candidate')"
W_GLM="$(printf '%s\n' "$CAND" | awk '$2=="glm" {sub(/weight=/,"",$NF); print $NF}')"
W_DS="$(printf '%s\n' "$CAND" | awk '$2=="deepseek" {sub(/weight=/,"",$NF); print $NF}')"
assert_contains "candidate line surfaces cost" "$CAND" 'cost=$'
if [ -n "$W_GLM" ] && [ -n "$W_DS" ] && awk -v g="$W_GLM" -v d="$W_DS" 'BEGIN{exit !(g*1.9 < d*1.1 && g*2.1 > d*0.9)}'; then
  ok "\$0.50/run reviewer draws at ~half weight ($W_GLM vs $W_DS)"
else
  bad "cost divisor not applied in draw weight (glm=$W_GLM deepseek=$W_DS)"
fi
# [pin: PR #28 pass 2 (codex) — a zero/garbage COST_PIVOT_USD must not
# divide-by-zero the draw or shrink the roster below the floor]
R_PIVOT0="$(COST_PIVOT_USD=0 CROSS_REVIEW_RUNLOG="$COSTLOG" bash "$S/select_roster.sh" --seed 5 2>/dev/null)"
N_PIVOT0="$(awk -F',' '{print NF}' <<<"$R_PIVOT0")"
if [ "$N_PIVOT0" -ge 3 ]; then ok "COST_PIVOT_USD=0 coerced to default (roster $N_PIVOT0)"; else bad "pivot=0 broke the draw ($R_PIVOT0)"; fi
R_PIVOTX="$(COST_PIVOT_USD=banana CROSS_REVIEW_RUNLOG="$COSTLOG" bash "$S/select_roster.sh" --seed 5 2>/dev/null)"
N_PIVOTX="$(awk -F',' '{print NF}' <<<"$R_PIVOTX")"
if [ "$N_PIVOTX" -ge 3 ]; then ok "non-numeric COST_PIVOT_USD coerced (roster $N_PIVOTX)"; else bad "pivot=banana broke the draw ($R_PIVOTX)"; fi
R_PIVOTD="$(COST_PIVOT_USD=0.0.1 CROSS_REVIEW_RUNLOG="$COSTLOG" bash "$S/select_roster.sh" --seed 5 2>/dev/null)"
N_PIVOTD="$(awk -F',' '{print NF}' <<<"$R_PIVOTD")"
if [ "$N_PIVOTD" -ge 3 ]; then ok "multi-dot COST_PIVOT_USD coerced (roster $N_PIVOTD)"; else bad "pivot=0.0.1 broke the draw ($R_PIVOTD)"; fi

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

echo "── worktree.sh sweep/end ownership (issue #6) ──"
# Sandboxed roots via the test-only env overrides; dirs backdated so -mmin matches.
WTROOT="$T/wtroot"; FAKETMP="$T/faketmp"; mkdir -p "$WTROOT" "$FAKETMP"
mkdir -p "$FAKETMP/cr-unrelated"          # someone else's dir — must survive
mkdir -p "$FAKETMP/cr-legacy-owned"       # our marker → swept
printf 'created-by=cross-review/worktree.sh\n' >"$FAKETMP/cr-legacy-owned/.cross-review-worktree"
mkdir -p "$FAKETMP/cr-legacy-gitptr"      # pre-marker legacy worktree pointer → swept
printf 'gitdir: /some/repo/.git/worktrees/cr-old-123\n' >"$FAKETMP/cr-legacy-gitptr/.git"
mkdir -p "$WTROOT/cr-stale-canonical"     # canonical root is ours by construction → swept
touch -t 202601010000 "$FAKETMP/cr-unrelated" "$FAKETMP/cr-legacy-owned" "$FAKETMP/cr-legacy-gitptr" "$WTROOT/cr-stale-canonical"
CROSS_REVIEW_WORKTREE_ROOT="$WTROOT" CROSS_REVIEW_LEGACY_TMP_ROOT="$FAKETMP" \
  bash "$S/worktree.sh" sweep --older-than-hours 1 >/dev/null 2>&1
if [[ -d "$FAKETMP/cr-unrelated" ]]; then ok "unrelated tmp cr-* dir survives sweep"; else bad "unrelated tmp dir was deleted"; fi
if [[ ! -d "$FAKETMP/cr-legacy-owned" ]]; then ok "marker-owned legacy dir swept"; else bad "marker-owned legacy dir not swept"; fi
if [[ ! -d "$FAKETMP/cr-legacy-gitptr" ]]; then ok "git-pointer legacy dir swept"; else bad "git-pointer legacy dir not swept"; fi
if [[ ! -d "$WTROOT/cr-stale-canonical" ]]; then ok "stale canonical-root dir swept"; else bad "canonical stale dir not swept"; fi

# end: refuses an unowned legacy path, removes an owned one
mkdir -p "$FAKETMP/cr-end-unowned" "$FAKETMP/cr-end-owned"
printf 'created-by=cross-review/worktree.sh\n' >"$FAKETMP/cr-end-owned/.cross-review-worktree"
if CROSS_REVIEW_WORKTREE_ROOT="$WTROOT" CROSS_REVIEW_LEGACY_TMP_ROOT="$FAKETMP" \
  bash "$S/worktree.sh" end --worktree "$FAKETMP/cr-end-unowned" >/dev/null 2>&1; then
  bad "end removed an unowned legacy path (exit 0)"
else
  if [[ -d "$FAKETMP/cr-end-unowned" ]]; then ok "end refuses unowned legacy path"; else bad "end deleted unowned dir despite nonzero exit"; fi
fi
CROSS_REVIEW_WORKTREE_ROOT="$WTROOT" CROSS_REVIEW_LEGACY_TMP_ROOT="$FAKETMP" \
  bash "$S/worktree.sh" end --worktree "$FAKETMP/cr-end-owned" >/dev/null 2>&1
if [[ ! -d "$FAKETMP/cr-end-owned" ]]; then ok "end removes marker-owned legacy path"; else bad "end did not remove owned dir"; fi

# start drops the ownership marker in every new worktree
( cd "$REPO" && CROSS_REVIEW_WORKTREE_ROOT="$WTROOT" CROSS_REVIEW_RUN_ROOT="$T/runroot" \
    bash "$S/worktree.sh" start --ref HEAD --id marker-test --base main >"$T/wt-start.json" 2>/dev/null )
WT_PATH="$(jq -r '.worktree' "$T/wt-start.json")"
if [[ -n "$WT_PATH" && -f "$WT_PATH/.cross-review-worktree" ]]; then ok "start drops ownership marker"; else bad "no marker in fresh worktree ($WT_PATH)"; fi
CROSS_REVIEW_WORKTREE_ROOT="$WTROOT" bash "$S/worktree.sh" end --worktree "$WT_PATH" >/dev/null 2>&1 || true

echo "── run_with_timeout bash-watchdog fallback (issue #7) ──"
printf '#!/bin/sh\ncat >/dev/null 2>&1 || true\nsleep 30\n' >"$T/bin/kimi"
WD_START=$(date +%s)
CROSS_REVIEW_FORCE_NO_TIMEOUT_BIN=1 bash "$S/run_reviewers.sh" --base main --out "$T/o4" --reviewers kimi --timeout-kimi 3 >/dev/null 2>&1
WD_ELAPSED=$(( $(date +%s) - WD_START ))
assert_eq "watchdog classifies timeout (timed_out=true)" "$(jq -r '.timed_out' "$T/o4/kimi.meta.json")" "true"
if [[ "$WD_ELAPSED" -lt 25 ]]; then ok "watchdog bounded the run (${WD_ELAPSED}s, shim sleeps 30)"; else bad "watchdog did not bound the run (${WD_ELAPSED}s)"; fi
printf '#!/bin/sh\ncat >/dev/null 2>&1 || true\nprintf "shim review: no findings\\n"\n' >"$T/bin/kimi"

echo "── analyze_runlog.sh degraded-reviewer warnings (jq pipe-context crash) ──"
# [pin: 2026-07-03 — emit_warning's `["…"] | index(.reviewer)` re-bound `.` to
# the array literal, so jq crashed ("Cannot index array with string") for
# exactly the reviewers degraded enough to warn about, and warn mode reported
# "all reviewers nominal" while north sat at a 50% timeout rate.]
WARNLOG="$T/warn-runlog.jsonl"
cat >"$WARNLOG" <<'EOF'
{"ts":"2026-07-03T01:00:00Z","reviewers":{"north":{"status":"ok","exit_code":0,"duration_s":300,"output_bytes":10,"timeout_budget_s":600},"codex":{"status":"ok","exit_code":0,"duration_s":100,"output_bytes":10,"timeout_budget_s":300}}}
{"ts":"2026-07-03T02:00:00Z","reviewers":{"north":{"status":"timed_out","exit_code":124,"duration_s":600,"output_bytes":0,"timeout_budget_s":600},"codex":{"status":"timed_out","exit_code":124,"duration_s":300,"output_bytes":0,"timeout_budget_s":300}}}
{"ts":"2026-07-03T03:00:00Z","reviewers":{"north":{"status":"timed_out","exit_code":124,"duration_s":600,"output_bytes":0,"timeout_budget_s":600},"codex":{"status":"timed_out","exit_code":124,"duration_s":300,"output_bytes":0,"timeout_budget_s":300}}}
EOF
WARN_OUT="$(CROSS_REVIEW_RUNLOG="$WARNLOG" bash "$S/analyze_runlog.sh" --mode warn 2>&1)"
assert_contains "pool reviewer at 66% timeout rate warns" "$WARN_OUT" "north timed out"
assert_contains "flag reviewer warning suggests --timeout-codex" "$WARN_OUT" "--timeout-codex"

echo "── analyze_runlog.sh sleep-suspect samples (wall clock past enforced budget) ──"
# [pin: 2026-07-03 — the Mac slept mid-round (pmset: Dark Wake Thermal
# Emergency); gtimeout/curl timers freeze during system sleep while date +%s
# keeps counting, so codex logged 1024s against a 300s budget with rc=0 and
# the analyzer suggested bumping every timeout. Sleep-inflated samples must
# be excluded from tuning math, not learned from.]
SLEEPLOG="$T/sleep-runlog.jsonl"
cat >"$SLEEPLOG" <<'EOF'
{"ts":"2026-07-03T01:00:00Z","reviewers":{"codex":{"status":"ok","exit_code":0,"duration_s":100,"output_bytes":10,"timeout_budget_s":300}}}
{"ts":"2026-07-03T02:00:00Z","reviewers":{"codex":{"status":"ok","exit_code":0,"duration_s":110,"output_bytes":10,"timeout_budget_s":300}}}
{"ts":"2026-07-03T03:00:00Z","reviewers":{"codex":{"status":"ok","exit_code":0,"duration_s":1024,"output_bytes":10,"timeout_budget_s":300}}}
{"ts":"2026-07-03T04:00:00Z","reviewers":{"codex":{"status":"ok","exit_code":0,"duration_s":120,"output_bytes":10,"timeout_budget_s":300}}}
EOF
SLEEP_OUT="$(CROSS_REVIEW_RUNLOG="$SLEEPLOG" bash "$S/analyze_runlog.sh" --mode report 2>&1)"
assert_contains "report surfaces sleep-suspect count" "$SLEEP_OUT" "sleep_suspect=1"
case "$SLEEP_OUT" in
  *"SUGGEST: bump codex"*) bad "sleep-inflated p95 still drives a timeout bump" ;;
  *) ok "no timeout bump from sleep-inflated p95" ;;
esac

echo "── leaderboard.sh sleep-killed timeout exclusion ──"
# [pin: 2026-07-03 — north's 4 same-day timeouts all overran the enforced
# curl --max-time on wall clock (machine asleep mid-transfer); they say
# nothing about the provider and must not ding reliability.]
SLPLB="$T/sleeplb-runlog.jsonl"
cat >"$SLPLB" <<'EOF'
{"ts":"2026-07-03T01:00:00Z","reviewers":{"north":{"status":"ok","exit_code":0,"duration_s":400,"output_bytes":10,"timeout_budget_s":600}}}
{"ts":"2026-07-03T02:00:00Z","reviewers":{"north":{"status":"timed_out","exit_code":124,"duration_s":926,"output_bytes":0,"timeout_budget_s":600}}}
EOF
LB2="$(CROSS_REVIEW_RUNLOG="$SLPLB" bash "$S/leaderboard.sh" --mode json)"
assert_eq "sleep-killed timeout excluded from attempts" \
  "$(jq -r '.[] | select(.reviewer=="north") | .attempts' <<<"$LB2")" "1"
assert_eq "reliability unpunished by sleep-killed timeout" \
  "$(jq -r '.[] | select(.reviewer=="north") | .score' <<<"$LB2")" "75"
# a genuine timeout (duration ≈ budget) still counts against reliability
GENLB="$T/genlb-runlog.jsonl"
cat >"$GENLB" <<'EOF'
{"ts":"2026-07-03T01:00:00Z","reviewers":{"north":{"status":"ok","exit_code":0,"duration_s":400,"output_bytes":10,"timeout_budget_s":600}}}
{"ts":"2026-07-03T02:00:00Z","reviewers":{"north":{"status":"timed_out","exit_code":124,"duration_s":610,"output_bytes":0,"timeout_budget_s":600}}}
EOF
LB3="$(CROSS_REVIEW_RUNLOG="$GENLB" bash "$S/leaderboard.sh" --mode json)"
assert_eq "genuine timeout still counts as an attempt" \
  "$(jq -r '.[] | select(.reviewer=="north") | .attempts' <<<"$LB3")" "2"

echo "── no-verdict (preamble-only) output detection ──"
# [pin: PR #2620 2026-07-03 — kimi delivered a 161-byte preamble with no
# findings and no clean verdict; it logged status ok, silently starving
# synthesis of the vote while the leaderboard counted a reliable run. The
# gzip-ratio gate can't catch short non-repetitive text.]
cat >"$T/bin/kimi" <<'SHIM'
#!/bin/sh
cat >/dev/null 2>&1 || true
printf "I will now examine the changes on the current branch against the base and report back with a thorough assessment of the code.\n"
SHIM
chmod +x "$T/bin/kimi"
bash "$S/run_reviewers.sh" --base main --out "$T/o6" --reviewers kimi --timeout-kimi 60 >/dev/null 2>&1 || true
assert_eq "preamble-only output stamps no_verdict_output" \
  "$(jq -r '.failure_kind' "$T/o6/kimi.meta.json")" "no_verdict_output"
assert_eq "preamble-only output classifies exit 5" \
  "$(jq -r '.exit_code' "$T/o6/kimi.meta.json")" "5"
# a short but explicit clean verdict must stay ok — brevity alone is not failure
printf '#!/bin/sh\ncat >/dev/null 2>&1 || true\nprintf "No findings - the change looks correct.\\n"\n' >"$T/bin/kimi"
bash "$S/run_reviewers.sh" --base main --out "$T/o7" --reviewers kimi --timeout-kimi 60 >/dev/null 2>&1
assert_eq "short explicit clean verdict stays ok" \
  "$(jq -r '.exit_code' "$T/o7/kimi.meta.json")" "0"
printf '{"exit_code": 5, "duration_s": 9, "timed_out": false, "output_bytes": 161, "attempt": 2, "timeout_budget_s": 600, "failure_kind": "no_verdict_output"}\n' >"$RUN/raw/kimi.meta.json"
NVLOG="$T/nv-runlog.jsonl"
CROSS_REVIEW_RUNLOG="$NVLOG" bash "$S/append_runlog.sh" \
  --run-dir "$RUN" --project test --base main --pr - --pass 1 \
  --verdict CLEAN --convergent 0 --top "-" >/dev/null 2>&1
assert_eq "runlog status is no_verdict, not ok" \
  "$(tail -1 "$NVLOG" | jq -r '.reviewers.kimi.status')" "no_verdict"
rm -f "$RUN/raw/kimi.meta.json"
printf '#!/bin/sh\ncat >/dev/null 2>&1 || true\nprintf "shim review: no findings\\n"\n' >"$T/bin/kimi"

echo "── reviewer-binary PATH guard (background-shell 127) ──"
# [pin: 2026-07-03 — background-dispatched rounds ran with a PATH lacking
# ~/.local/bin, so `timeout … kimi` exited 127 ("No such file or directory")
# and kimi logged failed=6 of 10 runs. detect_reviewers.sh had the ~/.local/bin
# guard; run_reviewers.sh (the dispatcher) did not — detection said available,
# dispatch said command-not-found.]
mkdir -p "$HOME/.local/bin"
printf '#!/bin/sh\ncat >/dev/null 2>&1 || true\nprintf "shim review: no findings\\n"\n' >"$HOME/.local/bin/kimi"
chmod +x "$HOME/.local/bin/kimi"
STRIPPED_PATH="$(printf '%s' "$PATH" | tr ':' '\n' | grep -vx "$T/bin" | paste -s -d: -)"
PATH="$STRIPPED_PATH" bash "$S/run_reviewers.sh" --base main --out "$T/o8" --reviewers kimi --timeout-kimi 60 >/dev/null 2>&1
assert_eq "reviewer binary resolved via ~/.local/bin PATH guard" \
  "$(jq -r '.exit_code' "$T/o8/kimi.meta.json" 2>/dev/null)" "0"
rm -f "$HOME/.local/bin/kimi"

echo "── agy no-verdict gate: guarded by the rc/bytes if-elif chain ──"
# [pin: PR #27 pass 1 — mimo+minimax convergent claim that the agy runner's
# `elif output_no_verdict` lacks the rc==0 guard and would mask real failures
# as no_verdict_output. FALSIFIED: the chain's opening
# `if [[ $rc -eq 0 && "$bytes" -eq 0 || $rc -ne 0 ]]` catches every non-zero
# rc first, so the elif is only reachable when rc==0 && bytes>0 — diff-only
# reviewers couldn't see the enclosing if outside the hunk. Both directions
# verified live before pinning (see feedback_convergent_not_correct).]
cat >"$T/bin/agy" <<'SHIM'
#!/bin/sh
if [ "$1" = "models" ]; then printf "Gemini 3.5 Flash (High)\nGemini 3.1 Pro (High)\n"; exit 0; fi
printf "Error: something went wrong during startup\n"
exit 1
SHIM
chmod +x "$T/bin/agy"
bash "$S/run_reviewers.sh" --base main --out "$T/o9" --reviewers antigravity --timeout 60 >/dev/null 2>&1 || true
assert_eq "agy rc=1 + short no-marker stdout keeps real exit code" \
  "$(jq -r '.exit_code' "$T/o9/antigravity.meta.json")" "1"
assert_eq "agy rc=1 not reclassified as no_verdict_output" \
  "$(jq -r '.failure_kind' "$T/o9/antigravity.meta.json")" "null"
cat >"$T/bin/agy" <<'SHIM'
#!/bin/sh
if [ "$1" = "models" ]; then printf "Gemini 3.5 Flash (High)\nGemini 3.1 Pro (High)\n"; exit 0; fi
printf "I will now examine the changes on the current branch and report back with an assessment.\n"
exit 0
SHIM
chmod +x "$T/bin/agy"
bash "$S/run_reviewers.sh" --base main --out "$T/o10" --reviewers antigravity --timeout 60 >/dev/null 2>&1 || true
assert_eq "agy rc=0 preamble-only stamps no_verdict_output" \
  "$(jq -r '.failure_kind' "$T/o10/antigravity.meta.json")" "no_verdict_output"
printf '#!/bin/sh\nif [ "$1" = "models" ]; then printf "Gemini 3.5 Flash (High)\\nGemini 3.1 Pro (High)\\n"; fi\n' >"$T/bin/agy"
chmod +x "$T/bin/agy"

echo "── analyze_runlog.sh contaminated-window NOTE (raw vs clean timeout rate) ──"
# [pin: PR #27 pass 1, minimax M2 — a window whose timeouts are all
# sleep-killed must emit an informational NOTE, not a WARN demanding tuning.]
CONTAMLOG="$T/contam-runlog.jsonl"
cat >"$CONTAMLOG" <<'EOF'
{"ts":"2026-07-03T01:00:00Z","reviewers":{"north":{"status":"ok","exit_code":0,"duration_s":300,"output_bytes":10,"timeout_budget_s":600}}}
{"ts":"2026-07-03T02:00:00Z","reviewers":{"north":{"status":"timed_out","exit_code":124,"duration_s":926,"output_bytes":0,"timeout_budget_s":600}}}
{"ts":"2026-07-03T03:00:00Z","reviewers":{"north":{"status":"timed_out","exit_code":124,"duration_s":930,"output_bytes":0,"timeout_budget_s":600}}}
EOF
CONTAM_OUT="$(CROSS_REVIEW_RUNLOG="$CONTAMLOG" bash "$S/analyze_runlog.sh" --mode warn 2>&1)"
assert_contains "sleep-contaminated timeout window notes, not warns" "$CONTAM_OUT" "NOTE: north raw timeout rate 66"
case "$CONTAM_OUT" in
  *"WARN: north timed out"*) bad "contaminated window still fires a tuning WARN" ;;
  *) ok "no tuning WARN from contaminated window" ;;
esac

echo "── kimi27 rotation seat (direct-Moonshot, draw_boost) ──"
# [pin: 2026-07-03, per Gabriel — kimi-k2.7-code joins the rotation pool as a
# direct-Moonshot seat (NOT an OpenRouter fallback; the no-OR-for-first-party
# policy is untouched) with a draw_boost so it is selected frequently while it
# earns leaderboard data.]
DETECT_OUT="$(bash "$S/detect_reviewers.sh")"
assert_eq "detect reports kimi27 available with Moonshot key" \
  "$(jq -r '.kimi27' <<<"$DETECT_OUT")" "true"
BOOST_ERR="$T/boost.err"
CROSS_REVIEW_RUNLOG="$FIXLOG" bash "$S/select_roster.sh" --seed 42 >/dev/null 2>"$BOOST_ERR"
assert_contains "selector draws kimi27 as a candidate" "$(cat "$BOOST_ERR")" "kimi27"
# rookie base weight = max(50,15) * (1 + 0.5/sqrt(1)) / (1 + 0/240) = 75.0;
# draw_boost 2.5 → 187.5. nemotron (same rookie stats, no boost) stays 75.0.
assert_contains "kimi27 weight carries the profile draw_boost" \
  "$(grep 'kimi27' "$BOOST_ERR")" "weight=187.5"
assert_contains "unboosted rookie weight unchanged" \
  "$(grep 'nemotron' "$BOOST_ERR")" "weight=75.0"
# no Moonshot key (env cleared, sandbox HOME has no key file) → honest skip
MOONSHOT_API_KEY= bash "$S/run_reviewers.sh" --base main --out "$T/o11" --reviewers kimi27 >/dev/null 2>"$T/k27skip.err"
assert_eq "kimi27 without a key exits 1 (all requested reviewers failed)" "$?" "1"
assert_contains "kimi27 skip names the missing key" "$(cat "$T/k27skip.err")" "Moonshot"
# same-provider convergence: kimi (baseline) + kimi27 agreeing is ONE provider vote
printf '{"exit_code": 0, "duration_s": 30, "timed_out": false, "output_bytes": 900, "attempt": 1, "timeout_budget_s": 600, "model": "kimi-k2.7-code", "cli": "moonshot", "failure_kind": null}\n' >"$RUN/raw/kimi27.meta.json"
cat >"$T/k27-findings.json" <<'EOF'
{"findings":[
 {"id":"m1","file":"a.sh","line":1,"claim":"x","sources":["kimi","kimi27"],"factcheck":{"verdict":"keep"}},
 {"id":"m2","file":"a.sh","line":2,"claim":"y","sources":["kimi27","codex"],"factcheck":{"verdict":"keep"}}
]}
EOF
K27LOG="$T/k27-runlog.jsonl"
CROSS_REVIEW_RUNLOG="$K27LOG" bash "$S/append_runlog.sh" \
  --run-dir "$RUN" --project test --base main --pr - --pass 1 \
  --verdict CLEAN --convergent 1 --top "-" --findings "$T/k27-findings.json" >/dev/null 2>&1
assert_eq "kimi27 telemetry lands in the runlog" \
  "$(tail -1 "$K27LOG" | jq -r '.reviewers.kimi27.status')" "ok"
assert_eq "kimi+kimi27 agreement is NOT cross-provider convergent" \
  "$(tail -1 "$K27LOG" | jq -r '.reviewers.kimi27.findings_convergent')" "1"
rm -f "$RUN/raw/kimi27.meta.json"
# request body: usage:{include:true} is an OpenRouter extension — the moonshot
# cli path must omit it (codex P2 falsified-as-worded but accepted as hygiene,
# PR #29 pass 1). The shim key makes curl fail fast; the body file is written
# BEFORE curl runs, so this asserts offline on the file, not the network.
bash "$S/run_reviewers.sh" --base main --out "$T/o12" --reviewers kimi27 --timeout 15 >/dev/null 2>&1 || true
if [[ -f "$T/o12/kimi27.request.json" ]]; then
  assert_eq "moonshot request body omits OpenRouter usage extension" \
    "$(jq 'has("usage")' "$T/o12/kimi27.request.json")" "false"
else
  bad "kimi27 request body was never written"
fi
# detect positional coupling: clearing ONLY the moonshot key must flip kimi27
# to false while the OR pool stays true (kimi+kat convergent nit — pins the
# printf arg mapping empirically, not just by comment)
DETECT2="$(MOONSHOT_API_KEY= bash "$S/detect_reviewers.sh")"
assert_eq "no moonshot key → kimi27 false" "$(jq -r '.kimi27' <<<"$DETECT2")" "false"
assert_eq "no moonshot key → OR pool unaffected" "$(jq -r '.glm' <<<"$DETECT2")" "true"

echo "── doc-narrative caution note (text-only reviewers, PR #350 class) ──"
# [pin: PR #350 (2026-07-05) — devstral replayed 9 of 12 findings, and
# deepseek 4 of 5, from an in-diff investigation doc's PROSE description of
# PRE-FIX bugs, reporting them as live findings. codex+kimi (agentic, with
# file-reading tools) were not fooled — they could check whether the
# described bugs were actually still present. Text-only reviewers (kimi +
# the OpenRouter pool, including kimi27) get an explicit caution injected
# into the prompt whenever the diff touches a doc/markdown file. Detection is
# by FILE EXTENSION, not prose content — content-sniffing for "bug language"
# needs unbounded phrasing coverage and is the same fragile-heuristic trap
# output_no_verdict already warns against.]
git checkout -qb docbranch main
printf 'bug: X used to crash before the fix was applied\n' >investigation.md
git add investigation.md
git -c user.email=t@t -c user.name=t commit -qm "add investigation doc"

# kimi: prompt goes over stdin, not a file — capture it via a shim variant
# that tees stdin before answering, so the assertion reads real prompt text
# rather than trusting the wiring by inspection.
cat >"$T/bin/kimi" <<'SHIM'
#!/bin/sh
cat >"${KIMI_STDIN_CAPTURE:-/dev/null}"
printf "shim review: no findings\n"
SHIM
chmod +x "$T/bin/kimi"

KIMI_STDIN_CAPTURE="$T/kimi-stdin-doc.txt" bash "$S/run_reviewers.sh" --base main --out "$T/o16" --reviewers kimi --timeout-kimi 30 >/dev/null 2>&1
assert_contains "kimi prompt warns on doc-narrative risk (.md in diff)" \
  "$(cat "$T/kimi-stdin-doc.txt" 2>/dev/null)" "documentation/markdown"

# negative case: feat's diff (thousands of numbered lines in f.txt) has no
# doc/markdown file — the caution must NOT fire on an ordinary code diff.
git checkout -q feat
KIMI_STDIN_CAPTURE="$T/kimi-stdin-nodoc.txt" bash "$S/run_reviewers.sh" --base main --out "$T/o17" --reviewers kimi --timeout-kimi 30 >/dev/null 2>&1
case "$(cat "$T/kimi-stdin-nodoc.txt" 2>/dev/null)" in
  *"documentation/markdown"*) bad "kimi prompt warns even without doc files in the diff" ;;
  *) ok "no doc-narrative note when diff has no doc files" ;;
esac

# openrouter-pool path shares the same prompt-building function — one probe
# (glm) confirms the wiring reaches it too, not just kimi's separate runner.
git checkout -q docbranch
bash "$S/run_reviewers.sh" --base main --out "$T/o18" --reviewers glm --timeout 15 >/dev/null 2>&1 || true
assert_contains "openrouter-pool prompt (glm) warns on doc-narrative risk" \
  "$(jq -r '.messages[0].content' "$T/o18/glm.request.json" 2>/dev/null)" "documentation/markdown"

printf '#!/bin/sh\ncat >/dev/null 2>&1 || true\nprintf "shim review: no findings\\n"\n' >"$T/bin/kimi"
git checkout -q feat

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
