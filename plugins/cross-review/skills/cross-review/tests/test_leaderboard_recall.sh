#!/usr/bin/env bash
# test_leaderboard_recall.sh — standalone fixture tests for #116: leaderboard
# recall column, synthetic rounds failing closed out of production scoring,
# and the weekly planted-round CI script (cross-review/ci/planted_round.sh).
#
# STANDALONE: no network, no reviewer CLIs (PATH + curl shims only). Follows
# the preamble conventions of tests/test_leaderboard_epochs.sh (PASS/FAIL
# counters, assert_eq/assert_contains, CROSS_REVIEW_RUNLOG/
# CROSS_REVIEW_FINDING_EVENTS overrides).
#
# Run:  bash tests/test_leaderboard_recall.sh
# Exit: 0 all green, 1 any failure.

set -uo pipefail

SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
S="$SKILL_DIR/scripts"
CI_DIR="$SKILL_DIR/ci"
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
# assert_num_eq <desc> <actual> <expected> [tolerance] — floating-point
# comparison, since --include-recall folds a float into an integer score.
assert_num_eq() {
  local tol="${4:-0.01}"
  if awk -v a="$2" -v b="$3" -v t="$tol" 'BEGIN{d=a-b; if (d<0) d=-d; exit !(d<=t)}' 2>/dev/null; then
    ok "$1"
  else
    bad "$1 (got: '$2' want: '$3')"
  fi
}
command -v jq >/dev/null 2>&1 || { echo "test_leaderboard_recall: jq required" >&2; exit 1; }

# ═══════════════════════════════════════════════════════════════════════════
# Fixtures: a production window (codex/kimi/glm/deepseek) + two synthetic
# planted rounds (syn-1 correctly flagged `synthetic: true`, syn-2 NOT
# flagged on the row but carrying a `planted` event — the fail-closed path).
# Both synthetic rounds: codex caught, kimi+glm missed, class "logic".
# ═══════════════════════════════════════════════════════════════════════════
PROD_RUNLOG="$T/prod-runlog.jsonl"
cat >"$PROD_RUNLOG" <<'EOF'
{"ts":"2026-08-01T00:00:00Z","run_id":"p1","reviewers":{"codex":{"status":"ok","exit_code":0,"duration_s":10,"output_bytes":10,"timeout_budget_s":300}}}
{"ts":"2026-08-01T01:00:00Z","run_id":"p2","reviewers":{"codex":{"status":"ok","exit_code":0,"duration_s":10,"output_bytes":10,"timeout_budget_s":300}}}
{"ts":"2026-08-01T02:00:00Z","run_id":"p3","reviewers":{"kimi":{"status":"ok","exit_code":0,"duration_s":10,"output_bytes":10,"timeout_budget_s":300}}}
{"ts":"2026-08-01T03:00:00Z","run_id":"p4","reviewers":{"glm":{"status":"ok","exit_code":0,"duration_s":10,"output_bytes":10,"timeout_budget_s":300}}}
{"ts":"2026-08-01T04:00:00Z","run_id":"p5","reviewers":{"glm":{"status":"ok","exit_code":0,"duration_s":10,"output_bytes":10,"timeout_budget_s":300}}}
{"ts":"2026-08-01T05:00:00Z","run_id":"p6","reviewers":{"deepseek":{"status":"ok","exit_code":0,"duration_s":10,"output_bytes":10,"timeout_budget_s":300}}}
EOF

PROD_EVENTS="$T/prod-events.jsonl"
cat >"$PROD_EVENTS" <<'EOF'
{"event":"proposed","finding_id":"f-p1","run_id":"p1","reviewer":"codex","severity":"High","all_sources":["codex"],"ts":"2026-08-01T00:10:00Z"}
{"event":"factcheck_kept","finding_id":"f-p1","run_id":"p1","ts":"2026-08-01T00:12:00Z"}
{"event":"proposed","finding_id":"f-p4","run_id":"p4","reviewer":"glm","severity":"Low","all_sources":["glm"],"ts":"2026-08-01T03:10:00Z"}
{"event":"factcheck_dropped","finding_id":"f-p4","run_id":"p4","ts":"2026-08-01T03:12:00Z"}
EOF

SYN_RUNLOG_ROWS="$T/syn-runlog-rows.jsonl"
cat >"$SYN_RUNLOG_ROWS" <<'EOF'
{"ts":"2026-08-02T00:00:00Z","run_id":"syn-1","synthetic":true,"reviewers":{"codex":{"status":"ok","exit_code":0,"duration_s":10,"output_bytes":10,"timeout_budget_s":300},"kimi":{"status":"ok","exit_code":0,"duration_s":10,"output_bytes":10,"timeout_budget_s":300},"glm":{"status":"ok","exit_code":0,"duration_s":10,"output_bytes":10,"timeout_budget_s":300}}}
{"ts":"2026-08-03T00:00:00Z","run_id":"syn-2","reviewers":{"codex":{"status":"ok","exit_code":0,"duration_s":10,"output_bytes":10,"timeout_budget_s":300},"kimi":{"status":"ok","exit_code":0,"duration_s":10,"output_bytes":10,"timeout_budget_s":300},"glm":{"status":"ok","exit_code":0,"duration_s":10,"output_bytes":10,"timeout_budget_s":300}}}
EOF

SYN_EVENTS="$T/syn-events.jsonl"
cat >"$SYN_EVENTS" <<'EOF'
{"event":"planted","finding_id":"f-planted-syn1","run_id":"syn-1","file":"src/foo.ts","line_range":[2,2],"operator":"logic_and_or","class":"logic","expected_severity":"High","ts":"2026-08-02T00:05:00Z"}
{"event":"caught","finding_id":"f-planted-syn1","run_id":"syn-1","reviewer":"codex","matched_finding_id":"f-x1","severity_called":"High","expected_severity":"High","severity_accuracy":1,"ts":"2026-08-02T00:06:00Z"}
{"event":"missed","finding_id":"f-planted-syn1","run_id":"syn-1","reviewer":"kimi","expected_severity":"High","ts":"2026-08-02T00:06:01Z"}
{"event":"missed","finding_id":"f-planted-syn1","run_id":"syn-1","reviewer":"glm","expected_severity":"High","ts":"2026-08-02T00:06:02Z"}
{"event":"planted","finding_id":"f-planted-syn2","run_id":"syn-2","file":"src/foo.ts","line_range":[2,2],"operator":"logic_and_or","class":"logic","expected_severity":"High","ts":"2026-08-03T00:05:00Z"}
{"event":"caught","finding_id":"f-planted-syn2","run_id":"syn-2","reviewer":"codex","matched_finding_id":"f-x2","severity_called":"High","expected_severity":"High","severity_accuracy":1,"ts":"2026-08-03T00:06:00Z"}
{"event":"missed","finding_id":"f-planted-syn2","run_id":"syn-2","reviewer":"kimi","expected_severity":"High","ts":"2026-08-03T00:06:01Z"}
{"event":"missed","finding_id":"f-planted-syn2","run_id":"syn-2","reviewer":"glm","expected_severity":"High","ts":"2026-08-03T00:06:02Z"}
EOF

RUNLOG_WITH="$T/runlog-with.jsonl"
cat "$PROD_RUNLOG" "$SYN_RUNLOG_ROWS" >"$RUNLOG_WITH"
EVENTS_WITH="$T/events-with.jsonl"
cat "$PROD_EVENTS" "$SYN_EVENTS" >"$EVENTS_WITH"

# "without" fixtures: the SAME files, filtered to drop the synthetic run_ids
# — not hand-authored separately, per the spec.
RUNLOG_WITHOUT="$T/runlog-without.jsonl"
jq -c 'select(.run_id != "syn-1" and .run_id != "syn-2")' "$RUNLOG_WITH" >"$RUNLOG_WITHOUT"
EVENTS_WITHOUT="$T/events-without.jsonl"
jq -c 'select(.run_id != "syn-1" and .run_id != "syn-2")' "$EVENTS_WITH" >"$EVENTS_WITHOUT"

echo "── (a) synthetic rounds fail closed: default output is byte-identical with/without ──"
TABLE_WITH="$(CROSS_REVIEW_RUNLOG="$RUNLOG_WITH" CROSS_REVIEW_FINDING_EVENTS="$EVENTS_WITH" bash "$S/leaderboard.sh" --recent 200 --mode table 2>/dev/null)"
TABLE_WITHOUT="$(CROSS_REVIEW_RUNLOG="$RUNLOG_WITHOUT" CROSS_REVIEW_FINDING_EVENTS="$EVENTS_WITHOUT" bash "$S/leaderboard.sh" --recent 200 --mode table 2>/dev/null)"
assert_eq "--mode table byte-identical with vs without synthetic rows" "$TABLE_WITH" "$TABLE_WITHOUT"

JSON_WITH="$(CROSS_REVIEW_RUNLOG="$RUNLOG_WITH" CROSS_REVIEW_FINDING_EVENTS="$EVENTS_WITH" bash "$S/leaderboard.sh" --recent 200 --mode json 2>/dev/null)"
JSON_WITHOUT="$(CROSS_REVIEW_RUNLOG="$RUNLOG_WITHOUT" CROSS_REVIEW_FINDING_EVENTS="$EVENTS_WITHOUT" bash "$S/leaderboard.sh" --recent 200 --mode json 2>/dev/null)"
assert_eq "--mode json byte-identical with vs without synthetic rows" "$JSON_WITH" "$JSON_WITHOUT"

# Same check with the --recent window exactly full of production rows: a
# synthetic row must not occupy a window slot (with the window cut before the
# exclusion, syn-1/syn-2 displaced the two oldest real rounds).
PROD_N="$(jq -c 'select(.reviewers != null)' "$PROD_RUNLOG" | wc -l | tr -d ' ')"
JSON_WITH_FULL="$(CROSS_REVIEW_RUNLOG="$RUNLOG_WITH" CROSS_REVIEW_FINDING_EVENTS="$EVENTS_WITH" bash "$S/leaderboard.sh" --recent "$PROD_N" --mode json 2>/dev/null)"
JSON_WITHOUT_FULL="$(CROSS_REVIEW_RUNLOG="$RUNLOG_WITHOUT" CROSS_REVIEW_FINDING_EVENTS="$EVENTS_WITHOUT" bash "$S/leaderboard.sh" --recent "$PROD_N" --mode json 2>/dev/null)"
assert_eq "--mode json byte-identical with a --recent window exactly full of production rows ($PROD_N)" "$JSON_WITH_FULL" "$JSON_WITHOUT_FULL"
assert_eq "a window exactly full of production rows scores the same as the unbounded window" "$JSON_WITH_FULL" "$JSON_WITHOUT"

echo "── (e) the un-flagged synthetic run is excluded and WARNs by run_id ──"
STDERR_WITH="$(CROSS_REVIEW_RUNLOG="$RUNLOG_WITH" CROSS_REVIEW_FINDING_EVENTS="$EVENTS_WITH" bash "$S/leaderboard.sh" --recent 200 --mode table 2>&1 >/dev/null)"
assert_contains "WARN names syn-1 (explicitly flagged)" "$STDERR_WITH" "syn-1"
assert_contains "WARN names syn-2 (fail-closed, row unflagged)" "$STDERR_WITH" "syn-2"
assert_contains "WARN says synthetic / excluded" "$STDERR_WITH" "synthetic"

echo "── (b) --mode report: recall table broken down by class + all bucket ──"
REPORT="$(CROSS_REVIEW_RUNLOG="$RUNLOG_WITH" CROSS_REVIEW_FINDING_EVENTS="$EVENTS_WITH" bash "$S/leaderboard.sh" --recent 200 --mode report 2>/dev/null)"
assert_contains "report has a mutation recall heading" "$REPORT" "mutation recall"
assert_contains "codex: all recall 1.00 (caught 2/2)" "$REPORT" "codex: all recall=1.00 (caught 2/2)"
assert_contains "kimi: all recall 0.00 (caught 0/2)" "$REPORT" "kimi: all recall=0.00 (caught 0/2)"
assert_contains "glm: all recall 0.00 (caught 0/2)" "$REPORT" "glm: all recall=0.00 (caught 0/2)"
assert_contains "codex: logic class recall 1.00" "$REPORT" "logic: recall=1.00 (caught 2/2)"
assert_contains "a seat with zero planted rounds shows —" "$REPORT" "deepseek: all recall=—"

echo "── (c)/(d) --include-recall folds recall into the score ──"
CODEX_BASE="$(jq -r '.[] | select(.reviewer=="codex") | .score' <<<"$JSON_WITH")"
DEEPSEEK_BASE="$(jq -r '.[] | select(.reviewer=="deepseek") | .score' <<<"$JSON_WITH")"
JSON_FOLDED="$(CROSS_REVIEW_RUNLOG="$RUNLOG_WITH" CROSS_REVIEW_FINDING_EVENTS="$EVENTS_WITH" bash "$S/leaderboard.sh" --recent 200 --mode json --include-recall 0.5 2>/dev/null)"
CODEX_FOLDED="$(jq -r '.[] | select(.reviewer=="codex") | .score' <<<"$JSON_FOLDED")"
DEEPSEEK_FOLDED="$(jq -r '.[] | select(.reviewer=="deepseek") | .score' <<<"$JSON_FOLDED")"
CODEX_EXPECTED="$(awk -v s="$CODEX_BASE" 'BEGIN{printf "%.4f", s*0.5 + 1.00*100*0.5}')"
assert_num_eq "codex score folds exactly per the formula (score*(1-w)+recall*100*w)" "$CODEX_FOLDED" "$CODEX_EXPECTED"
assert_num_eq "deepseek (no planted data) is left unchanged" "$DEEPSEEK_FOLDED" "$DEEPSEEK_BASE"

CROSS_REVIEW_RUNLOG="$RUNLOG_WITH" bash "$S/leaderboard.sh" --mode json --include-recall 1.5 >/dev/null 2>&1
RC1=$?
assert_eq "--include-recall 1.5 exits exactly 2" "$RC1" "2"
CROSS_REVIEW_RUNLOG="$RUNLOG_WITH" bash "$S/leaderboard.sh" --mode json --include-recall 0 >/dev/null 2>&1
RC0=$?
assert_eq "--include-recall 0 exits exactly 2" "$RC0" "2"

echo "── (f) append_runlog.sh --synthetic stamps synthetic: true ──"
RUN1="$T/run1"; mkdir -p "$RUN1/raw"
FLAGLOG="$T/flag-runlog.jsonl"
: >"$FLAGLOG"
CROSS_REVIEW_RUNLOG="$FLAGLOG" bash "$S/append_runlog.sh" \
  --run-dir "$RUN1" --project test --base main --pr - --pass 1 \
  --verdict CLEAN --run-id "flagged-1" --synthetic >/dev/null 2>&1
assert_eq "--synthetic stamps synthetic:true" "$(tail -1 "$FLAGLOG" | jq -r '.synthetic')" "true"

echo "── (g) append_runlog.sh auto-stamps + WARNs when a planted event exists but --synthetic was forgotten ──"
RUN2="$T/run2"; mkdir -p "$RUN2/raw"
AUTOLOG="$T/auto-runlog.jsonl"
: >"$AUTOLOG"
AUTOEVENTS="$T/auto-events.jsonl"
printf '{"event":"planted","finding_id":"f-auto","run_id":"auto-syn","file":"x.ts","line_range":[1,1],"operator":"logic_and_or","class":"logic","expected_severity":"High","ts":"2026-08-05T00:00:00Z"}\n' >"$AUTOEVENTS"
AUTO_STDERR="$(CROSS_REVIEW_RUNLOG="$AUTOLOG" CROSS_REVIEW_FINDING_EVENTS="$AUTOEVENTS" bash "$S/append_runlog.sh" \
  --run-dir "$RUN2" --project test --base main --pr - --pass 1 \
  --verdict CLEAN --run-id "auto-syn" 2>&1 >/dev/null)"
assert_eq "forgotten --synthetic still stamps synthetic:true (planted event present)" \
  "$(tail -1 "$AUTOLOG" | jq -r '.synthetic')" "true"
assert_contains "stderr WARNs naming the run_id" "$AUTO_STDERR" "auto-syn"
assert_contains "stderr WARN says planted" "$AUTO_STDERR" "planted"

# ═══════════════════════════════════════════════════════════════════════════
# (h) ci/planted_round.sh end-to-end, fully offline (curl-shimmed OpenRouter
# lane, no codex/agy CLIs needed for a single OpenRouter seat).
# ═══════════════════════════════════════════════════════════════════════════
echo "── (h) ci/planted_round.sh end-to-end (offline, shimmed) ──"

mkdir -p "$T/bin"
printf '#!/bin/sh\ncat >/dev/null 2>&1 || true\nprintf "shim\\n"\n' >"$T/bin/codex"
printf '#!/bin/sh\nif [ "$1" = "models" ]; then printf "Gemini 3.5 Flash (High)\\nGemini 3.1 Pro (High)\\n"; fi\n' >"$T/bin/agy"
printf '#!/bin/sh\ncat >/dev/null 2>&1 || true\nprintf "shim review: no findings\\n"\n' >"$T/bin/kimi"
chmod +x "$T/bin/"*

# The planted mutation swaps `&&` for `||` on the touched line (operator
# logic_and_or, expected_severity High) — the canned OpenRouter reply reports
# exactly one finding at that file/line so grade_planted.sh scores a CATCH.
cat >"$T/canned_or_planted.json" <<'EOF'
{"choices":[{"message":{"content":"{\"findings\":[{\"id\":\"local1\",\"file\":\"src/foo.ts\",\"line\":2,\"severity\":\"High\",\"claim\":\"logical operator was weakened from && to ||\",\"snippet\":\"a || b\",\"sources\":[\"glm\"]}]}"}}],"usage":{"prompt_tokens":500,"completion_tokens":40,"cost":0.001}}
EOF
cat >"$T/bin/curl" <<SHIM
#!/bin/sh
cat "$T/canned_or_planted.json"
SHIM
chmod +x "$T/bin/curl"

REPO="$T/target-repo"
mkdir -p "$REPO/src"
cat >"$REPO/src/foo.ts" <<'EOF'
export function check(a: boolean, b: boolean): boolean {
  return a && b;
}
EOF
(
  cd "$REPO" \
    && git init -q -b main \
    && git config user.email "t@t.example" \
    && git config user.name "test" \
    && git add -A \
    && git commit -q -m "init"
)

PLANTED_RUNLOG="$T/planted-runlog.jsonl"
PLANTED_EVENTS="$T/planted-events.jsonl"
: >"$PLANTED_RUNLOG"; : >"$PLANTED_EVENTS"
OUT_DIR="$T/planted-out"

PATH="$T/bin:$PATH" \
  OPENROUTER_API_KEY="sk-or-test-shim" \
  CROSS_REVIEW_RUNLOG="$PLANTED_RUNLOG" \
  CROSS_REVIEW_FINDING_EVENTS="$PLANTED_EVENTS" \
  HOME="$T/home" \
  bash "$CI_DIR/planted_round.sh" \
    --repo-root "$REPO" \
    --operators-file "$SKILL_DIR/references/mutation_operators.json" \
    --fixture "src/foo.ts" \
    --roster glm \
    --seed 42 \
    --run-id "ci-test-1" \
    --out "$OUT_DIR" >"$T/planted-round.stdout" 2>"$T/planted-round.stderr"
PLANTED_RC=$?
assert_eq "planted_round.sh exits 0" "$PLANTED_RC" "0"

assert_eq "grade.json is synthetic" "$(jq -r '.synthetic' "$OUT_DIR/grade.json" 2>/dev/null)" "true"
assert_eq "grade.json planted operator matches" "$(jq -r '.planted.operator' "$OUT_DIR/grade.json" 2>/dev/null)" "logic_and_or"

assert_eq "planted event appended" "$(grep -c '"event":"planted"' "$PLANTED_EVENTS" 2>/dev/null || echo 0)" "1"
GLM_EVENT="$(jq -r 'select((.event=="caught" or .event=="missed") and .reviewer=="glm") | .event' "$PLANTED_EVENTS" 2>/dev/null | head -1)"
if [[ "$GLM_EVENT" == "caught" || "$GLM_EVENT" == "missed" ]]; then
  ok "caught or missed event appended for glm ($GLM_EVENT)"
else
  bad "caught or missed event appended for glm (got: '$GLM_EVENT')"
fi

assert_eq "a synthetic runlog row was appended" \
  "$(tail -1 "$PLANTED_RUNLOG" | jq -r '.synthetic' 2>/dev/null)" "true"
assert_eq "the synthetic runlog row carries the run_id" \
  "$(tail -1 "$PLANTED_RUNLOG" | jq -r '.run_id' 2>/dev/null)" "ci-test-1"

REPO_STATUS="$(git -C "$REPO" status --porcelain 2>/dev/null)"
assert_eq "the fixture repo is clean after the drill" "$REPO_STATUS" ""

# (h2) --fixture auto picks a tracked .ts file (not the .sh/.json noise), with
# NO git identity configured anywhere (a pristine CI runner) and a RELATIVE
# --out given from a cwd that is not the repo root.
echo "── (h2) planted_round.sh --fixture auto, no git identity, relative --out ──"
REPO2="$T/target-repo-auto"
mkdir -p "$REPO2/src" "$REPO2/scripts" "$REPO2/evals"
printf 'echo "x && y"\n' >"$REPO2/scripts/noise.sh"
printf '{"a":1}\n' >"$REPO2/evals/evals.json"
cat >"$REPO2/src/foo.ts" <<'EOF'
export function check(a: boolean, b: boolean): boolean {
  return a && b;
}
EOF
( cd "$REPO2" && git init -q -b main && git add -A \
    && GIT_AUTHOR_NAME=seed GIT_AUTHOR_EMAIL=seed@x GIT_COMMITTER_NAME=seed GIT_COMMITTER_EMAIL=seed@x git commit -q -m init )
PLANTED_RUNLOG2="$T/planted-runlog2.jsonl"; PLANTED_EVENTS2="$T/planted-events2.jsonl"
: >"$PLANTED_RUNLOG2"; : >"$PLANTED_EVENTS2"
mkdir -p "$T/cwd2"
( cd "$T/cwd2" && PATH="$T/bin:$PATH" OPENROUTER_API_KEY="sk-or-test-shim" \
    CROSS_REVIEW_RUNLOG="$PLANTED_RUNLOG2" CROSS_REVIEW_FINDING_EVENTS="$PLANTED_EVENTS2" \
    HOME="$T/home-empty" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
    bash "$CI_DIR/planted_round.sh" --repo-root "$REPO2" \
      --operators-file "$SKILL_DIR/references/mutation_operators.json" \
      --fixture auto --roster glm --seed 42 --run-id "ci-test-auto" \
      --out "rel-out" >"$T/planted-round2.stdout" 2>"$T/planted-round2.stderr" )
assert_eq "auto drill exits 0 with no git identity and a relative --out" "$?" "0"
assert_eq "auto picked the tracked .ts file" "$(jq -r '.planted.file' "$T/cwd2/rel-out/grade.json" 2>/dev/null)" "src/foo.ts"
assert_eq "relative --out resolved against the caller's cwd" "$([[ -f "$T/cwd2/rel-out/grade.json" ]] && echo yes || echo no)" "yes"
assert_eq "auto drill left the repo clean" "$(git -C "$REPO2" status --porcelain 2>/dev/null)" ""

# (h3) a repo with no tracked TS/JS falls back to the committed drill target.
echo "── (h3) --fixture auto falls back to ci/fixtures/planted_target.ts ──"
REPO3="$T/target-repo-fallback"
mkdir -p "$REPO3/cross-review/ci/fixtures" "$REPO3/scripts"
printf 'echo "only shell here"\n' >"$REPO3/scripts/a.sh"
cp "$CI_DIR/fixtures/planted_target.ts" "$REPO3/cross-review/ci/fixtures/planted_target.ts"
( cd "$REPO3" && git init -q -b main && git add -A \
    && GIT_AUTHOR_NAME=seed GIT_AUTHOR_EMAIL=seed@x GIT_COMMITTER_NAME=seed GIT_COMMITTER_EMAIL=seed@x git commit -q -m init )
PLANTED_RUNLOG3="$T/planted-runlog3.jsonl"; PLANTED_EVENTS3="$T/planted-events3.jsonl"
: >"$PLANTED_RUNLOG3"; : >"$PLANTED_EVENTS3"
PATH="$T/bin:$PATH" OPENROUTER_API_KEY="sk-or-test-shim" \
  CROSS_REVIEW_RUNLOG="$PLANTED_RUNLOG3" CROSS_REVIEW_FINDING_EVENTS="$PLANTED_EVENTS3" \
  HOME="$T/home-empty" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
  bash "$CI_DIR/planted_round.sh" --repo-root "$REPO3" \
    --operators-file "$SKILL_DIR/references/mutation_operators.json" \
    --fixture auto --roster glm --seed 7 --run-id "ci-test-fallback" \
    --out "$T/out3" >"$T/planted-round3.stdout" 2>"$T/planted-round3.stderr"
assert_eq "fallback drill exits 0" "$?" "0"
assert_eq "fallback picked the committed drill target" "$(jq -r '.planted.file' "$T/out3/grade.json" 2>/dev/null)" "cross-review/ci/fixtures/planted_target.ts"
assert_eq "fallback drill left the repo clean" "$(git -C "$REPO3" status --porcelain 2>/dev/null)" ""
# The synthetic touch must expose EVERY operator-matching line, so the seeded
# draw rotates across operators (a one-line touch pinned every drill to
# operator 0). Four seeds on the same target must not all pick the same one.
SEEN_OPS=""
for sd in 1 2 3 4; do
  : >"$T/planted-runlog-s$sd.jsonl"; : >"$T/planted-events-s$sd.jsonl"
  PATH="$T/bin:$PATH" OPENROUTER_API_KEY="sk-or-test-shim" \
    CROSS_REVIEW_RUNLOG="$T/planted-runlog-s$sd.jsonl" CROSS_REVIEW_FINDING_EVENTS="$T/planted-events-s$sd.jsonl" \
    HOME="$T/home-empty" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
    bash "$CI_DIR/planted_round.sh" --repo-root "$REPO3" \
      --operators-file "$SKILL_DIR/references/mutation_operators.json" \
      --fixture auto --roster glm --seed "$sd" --run-id "ci-test-seed-$sd" \
      --out "$T/out-seed-$sd" >/dev/null 2>&1
  SEEN_OPS="$SEEN_OPS $(jq -r '.planted.operator' "$T/out-seed-$sd/grade.json" 2>/dev/null)"
done
N_DISTINCT="$(tr ' ' '\n' <<<"$SEEN_OPS" | sed '/^$/d' | sort -u | wc -l | tr -d ' ')"
if [[ "$N_DISTINCT" -ge 2 ]]; then
  ok "seeds 1-4 draw at least two distinct operators from the drill target ($SEEN_OPS )"
else
  bad "seeds 1-4 draw at least two distinct operators from the drill target (got:$SEEN_OPS )"
fi

# A CRLF fixture goes through the synthetic touch (the space lands before the
# \r) and the whole drill without error, and the repo is restored.
REPO4="$T/target-repo-crlf"; mkdir -p "$REPO4/src"
printf 'export function check(a: boolean, b: boolean): boolean {\r\n  return a && b;\r\n}\r\n' >"$REPO4/src/win.ts"
( cd "$REPO4" && git init -q -b main && git add -A \
    && GIT_AUTHOR_NAME=seed GIT_AUTHOR_EMAIL=seed@x GIT_COMMITTER_NAME=seed GIT_COMMITTER_EMAIL=seed@x git commit -q -m init )
: >"$T/planted-runlog4.jsonl"; : >"$T/planted-events4.jsonl"
PATH="$T/bin:$PATH" OPENROUTER_API_KEY="sk-or-test-shim" \
  CROSS_REVIEW_RUNLOG="$T/planted-runlog4.jsonl" CROSS_REVIEW_FINDING_EVENTS="$T/planted-events4.jsonl" \
  HOME="$T/home-empty" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
  bash "$CI_DIR/planted_round.sh" --repo-root "$REPO4" \
    --operators-file "$SKILL_DIR/references/mutation_operators.json" \
    --fixture auto --roster glm --seed 3 --run-id "ci-test-crlf" \
    --out "$T/out4" >/dev/null 2>"$T/planted-round4.stderr"
assert_eq "CRLF drill exits 0" "$?" "0"
assert_eq "CRLF drill left the repo clean" "$(git -C "$REPO4" status --porcelain 2>/dev/null)" ""

# The committed drill target must offer every operator a site, so the seeded
# draw can land on any class.
N_OPS="$(jq 'length' "$SKILL_DIR/references/mutation_operators.json")"
MATCHED=0
for ((oi = 0; oi < N_OPS; oi++)); do
  re="$(jq -r ".[$oi].match" "$SKILL_DIR/references/mutation_operators.json")"
  grep -Eq -- "$re" "$CI_DIR/fixtures/planted_target.ts" && MATCHED=$((MATCHED + 1))
done
assert_eq "planted_target.ts matches every operator ($N_OPS)" "$MATCHED" "$N_OPS"

# (i) --mode report with no planted rounds prints the empty-window line, not
# 21 rows of "recall=—".
echo "── (i) recall report on a window with no planted rounds ──"
REPORT_EMPTY="$(CROSS_REVIEW_RUNLOG="$RUNLOG_WITHOUT" CROSS_REVIEW_FINDING_EVENTS="$EVENTS_WITHOUT" bash "$S/leaderboard.sh" --recent 200 --mode report 2>/dev/null)"
assert_contains "empty window prints the no-planted-rounds line" "$REPORT_EMPTY" "(no planted rounds in this window)"
assert_eq "empty window prints no per-seat recall rows" "$(grep -c 'all recall=' <<<"$REPORT_EMPTY")" "0"

echo
echo "══ $PASS passed, $FAIL failed ══"
[[ "$FAIL" -eq 0 ]] || exit 1
exit 0
