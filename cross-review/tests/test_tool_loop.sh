#!/usr/bin/env bash
# test_tool_loop.sh — offline fixture tests for the wrapper-owned tool loop
# (scripts/lib_tool_loop.sh, wired into run_reviewers.sh's OpenRouter lane).
#
# curl is a PATH shim that plays the provider: a request whose messages hold
# no `tool` role yet answers with tool_calls; a request that already carries
# tool results answers with the final findings JSON. So the shim is
# stateless and the loop's own bookkeeping is what is under test.
#
# Run:  bash tests/test_tool_loop.sh
# Exit: 0 all green, 1 any failure.

set -uo pipefail
# run_tests.sh pins CROSS_REVIEW_TOOL_MODE=off for the single-shot suites; this
# suite exercises the learner, so the inherited pin must not leak in.
unset CROSS_REVIEW_TOOL_MODE

SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
S="$SKILL_DIR/scripts"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

PASS=0; FAIL=0
ok()  { echo "  ok   $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL $1"; FAIL=$((FAIL + 1)); }
assert_eq() { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 (got: '$2' want: '$3')"; fi; }
assert_contains() { if [[ "$2" == *"$3"* ]]; then ok "$1"; else bad "$1 (no '$3' in output)"; fi; }
assert_not_contains() { if [[ "$2" != *"$3"* ]]; then ok "$1"; else bad "$1 (unexpectedly found '$3')"; fi; }

command -v jq >/dev/null 2>&1 || { echo "jq required" >&2; exit 1; }
export OPENROUTER_API_KEY="sk-or-test-shim"
export HOME="$T/home"; mkdir -p "$HOME/.local/bin"; export PATH="$HOME/.local/bin:$PATH"
export CROSS_REVIEW_CONTEXT_MODE=files
# The learner must read a FIXTURE ledger, never the live one next to the scripts.
export CROSS_REVIEW_RUNLOG="$T/runlog.jsonl"; : >"$CROSS_REVIEW_RUNLOG"
export CROSS_REVIEW_FINDING_EVENTS="$T/events.jsonl"; : >"$CROSS_REVIEW_FINDING_EVENTS"

# ── the provider shim ────────────────────────────────────────────────────────
# SHIM_MODE (env, inherited by curl):
#   default  — turn 1: a batch of tool calls; turn 2+: final answer
#   always   — every turn asks for a tool call (exercises the step budget)
#   rf400    — first request WITH response_format 400s; retried request without it succeeds
#   bill402  — every request 402s (OpenRouter "Insufficient credits" shape)
#   err400   — every request 400s with a tools complaint (survives the rf-drop retry)
#   nocache  — normal flow, but usage carries NO prompt_tokens_details (the
#              Moonshot-direct shape: a host that reports no cache counters)
cat >"$HOME/.local/bin/curl" <<'SHIM'
#!/bin/sh
cat >/dev/null   # the --config stdin (bearer header)
body=""
prev=""
for a in "$@"; do
  case "$prev" in -d) body="${a#@}" ;; esac
  prev="$a"
done
have_tool_msgs="$(jq -r '[.messages[] | select(.role == "tool")] | length' "$body" 2>/dev/null || echo 0)"
has_rf="$(jq -r 'has("response_format")' "$body" 2>/dev/null || echo false)"
tool_choice="$(jq -r '.tool_choice // ""' "$body" 2>/dev/null)"
n_tools="$(jq -r '.tools | length' "$body" 2>/dev/null || echo 0)"
mkdir -p "$SHIM_LOG_DIR" 2>/dev/null
echo "turn tool_msgs=$have_tool_msgs rf=$has_rf tool_choice=$tool_choice tools=$n_tools" >>"$SHIM_LOG_DIR/shim.log"
if [ "${SHIM_MODE:-default}" = "bill402" ]; then
  printf '%s' '{"error":{"message":"Insufficient credits. Add more using https://openrouter.ai/settings/credits","code":402}}'
  exit 0
fi
if [ "${SHIM_MODE:-default}" = "err400" ]; then
  printf '%s' '{"error":{"message":"This endpoint does not support tools","code":400}}'
  exit 0
fi
if [ "${SHIM_MODE:-default}" = "rf400" ] && [ "$has_rf" = "true" ]; then
  printf '%s' '{"error":{"message":"response_format json_object is not supported with tools","code":400}}'
  exit 0
fi
final='{"choices":[{"finish_reason":"stop","message":{"role":"assistant","content":"{\"findings\":[{\"severity\":\"Low\",\"file\":\"src/a.txt\",\"line\":2,\"snippet\":\"beta\",\"claim\":\"verified via tools\",\"suggested_fix\":\"\"}]}"}}],"usage":{"prompt_tokens":100,"completion_tokens":20,"cost":0.002,"prompt_tokens_details":{"cached_tokens":40,"cache_write_tokens":0}},"provider":"Shimco"}'
calls='{"choices":[{"finish_reason":"tool_calls","message":{"role":"assistant","content":null,"tool_calls":[
  {"id":"c1","type":"function","function":{"name":"read_file","arguments":"{\"path\":\"src/a.txt\"}"}},
  {"id":"c2","type":"function","function":{"name":"read_file","arguments":"{\"path\":\"../outside.txt\"}"}},
  {"id":"c3","type":"function","function":{"name":"read_file","arguments":"{\"path\":\".env\"}"}},
  {"id":"c4","type":"function","function":{"name":"search","arguments":"{\"pattern\":\"HUNK_NEIGHBOUR\",\"path_glob\":\"src/**/*.txt\"}"}},
  {"id":"c5","type":"function","function":{"name":"run_check","arguments":"{}"}},
  {"id":"c6","type":"function","function":{"name":"list_files","arguments":"{\"dir\":\"src\"}"}}
]}}],"usage":{"prompt_tokens":50,"completion_tokens":30,"cost":0.001,"prompt_tokens_details":{"cached_tokens":0,"cache_write_tokens":50}},"provider":"Shimco"}'
one='{"choices":[{"finish_reason":"tool_calls","message":{"role":"assistant","content":null,"tool_calls":[{"id":"cx","type":"function","function":{"name":"read_file","arguments":"{\"path\":\"src/a.txt\",\"start_line\":1,\"end_line\":2}"}}]}}],"usage":{"prompt_tokens":10,"completion_tokens":5,"cost":0.0005}}'
case "${SHIM_MODE:-default}" in
  always) if [ "$tool_choice" = "none" ]; then printf '%s' "$final"; else printf '%s' "$one"; fi ;;
  nocache) if [ "$have_tool_msgs" = "0" ]; then printf '%s' "$calls" | jq -c 'del(.usage.prompt_tokens_details)'; else printf '%s' "$final" | jq -c 'del(.usage.prompt_tokens_details)'; fi ;;
  *)      if [ "$have_tool_msgs" = "0" ]; then printf '%s' "$calls"; else printf '%s' "$final"; fi ;;
esac
exit 0
SHIM
chmod +x "$HOME/.local/bin/curl"
export SHIM_LOG_DIR="$T/shim"
# Provider display-name → slug table the pin resolves against (never the live
# /api/v1/providers here — curl is the shim). "Nameless Host" has no slug on
# purpose: the loop must then decline to pin rather than send a bad order.
printf '{"data":[{"name":"Shimco","slug":"shimco"},{"name":"Nameless Host","slug":""}]}' >"$T/or_providers.json"
export CROSS_REVIEW_OR_PROVIDERS_FILE="$T/or_providers.json"

# ── fixture repo ─────────────────────────────────────────────────────────────
REPO="$T/repo"; mkdir -p "$REPO/src"
( cd "$REPO" && { git init -q -b main 2>/dev/null || { git init -q && git symbolic-ref HEAD refs/heads/main; }; }
  git config user.email t@t; git config user.name t
  printf 'alpha\nbeta\nHUNK_NEIGHBOUR line\nAPI_KEY = "abcdefghijklmnopqrstuvwxyz0123"\n' >src/a.txt
  printf 'SECRET=should-never-be-read\n' >.env
  printf 'readme\n' >README.md
  git add -A && git commit -qm init
  git checkout -qb feat && printf 'alpha\nbeta2\nHUNK_NEIGHBOUR line\nAPI_KEY = "abcdefghijklmnopqrstuvwxyz0123"\n' >src/a.txt && git commit -qam change )
printf 'outside\n' >"$T/outside.txt"

run_lane() {  # run_lane <outdir> [env assignments...] -- extra run_reviewers args
  local outd="$1"; shift
  local -a envs=()
  while [[ $# -gt 0 && "$1" != "--" ]]; do envs+=("$1"); shift; done
  [[ "${1:-}" == "--" ]] && shift
  ( cd "$REPO" && env "${envs[@]}" bash "$S/run_reviewers.sh" --base main --out "$outd" --reviewers glm --timeout-glm 60 "$@" >"$outd.log" 2>&1 )
}

echo "── read arm: tools executed, guarded, recorded ──"
run_lane "$T/o1" CROSS_REVIEW_TOOL_MODE=read --
META="$T/o1/glm.meta.json"
jq -e . "$META" >/dev/null 2>&1 && ok "meta.json is valid JSON" || bad "meta.json invalid: $(head -c 300 "$META")"
assert_eq "exit_code 0"                        "$(jq -r .exit_code "$META")" "0"
assert_eq "context_access=tool_read"           "$(jq -r .context_access "$META")" "tool_read"
assert_eq "tool_policy.mode=read"              "$(jq -r .tool_policy.mode "$META")" "read"
assert_eq "tool_policy.basis=override"         "$(jq -r .tool_policy.basis "$META")" "override"
assert_eq "tool_stats.mode=read"               "$(jq -r .tool_stats.mode "$META")" "read"
assert_eq "one tool step"                      "$(jq -r .tool_stats.steps "$META")" "1"
assert_eq "two API turns"                      "$(jq -r .tool_stats.turns "$META")" "2"
assert_eq "read_file called 3x (incl. refused)" "$(jq -r .tool_stats.calls.read_file "$META")" "3"
assert_eq "search called once"                 "$(jq -r .tool_stats.calls.search "$META")" "1"
assert_eq "list_files called once"             "$(jq -r .tool_stats.calls.list_files "$META")" "1"
assert_eq "run_check counted but not run in read mode" "$(jq -r .tool_stats.calls.run_check "$META")" "1"
assert_eq "check_ran=false in read mode"       "$(jq -r .tool_stats.check_ran "$META")" "false"
assert_eq "cost summed over both turns"        "$(jq -r .cost_usd "$META")" "0.003"
assert_eq "prompt tokens summed"               "$(jq -r .tokens_prompt "$META")" "150"
assert_eq "completion tokens summed"           "$(jq -r .tokens_completion "$META")" "50"
assert_eq "cached tokens summed over both turns" "$(jq -r .tokens_cached "$META")" "40"
assert_eq "cache-write tokens summed"           "$(jq -r .tokens_cache_write "$META")" "50"
assert_eq "upstream provider recorded"          "$(jq -r .upstream_provider "$META")" "Shimco"
assert_eq "turn 1 carries no provider pin"      "$(jq -r '.provider // "none"' "$T/o1/glm.turn.1.request.json")" "none"
assert_eq "turn 2 pins turn 1's upstream"       "$(jq -c '.provider' "$T/o1/glm.turn.2.request.json")" '{"order":["shimco"],"allow_fallbacks":true}'
assert_contains "pin is logged"                 "$(cat "$T/o1/glm.stderr")" "pinning later turns to upstream 'Shimco'"
# Prompt order: the per-round --stat summary must sit AFTER the diff so the
# cacheable prefix is header + diff, not header alone.
P1="$(jq -r '.messages[0].content' "$T/o1/glm.turn.1.request.json")"
[[ "${P1%%Changed files (diff --stat*}" == *"</diff>"* ]] && ok "diff --stat summary comes after the diff" || bad "diff --stat summary precedes the diff"
L_STAT="$(printf '%s\n' "$P1" | grep -n 'Changed files (diff --stat' | head -1 | cut -d: -f1)"
L_JSON="$(printf '%s\n' "$P1" | grep -n 'Output nothing but the single JSON object' | head -1 | cut -d: -f1)"
[[ -n "$L_STAT" && -n "$L_JSON" && "$L_JSON" -gt "$L_STAT" ]] && ok "JSON suffix stays last (line $L_JSON > stat line $L_STAT)" || bad "JSON suffix not after the summary (stat=$L_STAT json=$L_JSON)"
assert_contains "final content lands in stdout" "$(cat "$T/o1/glm.stdout")" "verified via tools"
[[ -f "$T/o1/glm.turn.1.request.json" && -f "$T/o1/glm.turn.2.request.json" ]] && ok "per-turn request files kept for audit" || bad "per-turn request files missing"
assert_eq "request.json points at the LAST turn" "$(jq -r '[.messages[] | select(.role == "tool")] | length' "$T/o1/glm.request.json")" "6"
MSGS2="$T/o1/glm.turn.2.request.json"
tool_result() { jq -r --arg id "$1" '.messages[] | select(.role == "tool" and .tool_call_id == $id) | .content' "$MSGS2"; }
assert_contains "read_file returns numbered lines"            "$(tool_result c1)" $'2\tbeta2'
assert_contains "read_file header names the range"            "$(tool_result c1)" "src/a.txt (lines 1-4 of 4)"
assert_contains "secret-shaped content is redacted"           "$(tool_result c1)" "[REDACTED]"
assert_not_contains "…and the literal key never reaches the model" "$(tool_result c1)" "abcdefghijklmnopqrstuvwxyz0123"
assert_contains "path traversal refused"                      "$(tool_result c2)" "error: invalid path"
assert_contains ".env refused by the secret-path policy"      "$(tool_result c3)" "error:"
assert_not_contains "…and its content is not leaked"          "$(tool_result c3)" "should-never-be-read"
assert_contains "search finds the neighbour line (with a ** glob — git needs :(glob) for that)" "$(tool_result c4)" "src/a.txt:3:HUNK_NEIGHBOUR"
assert_contains "run_check refused outside check mode"        "$(tool_result c5)" "not available"
assert_contains "list_files lists tracked files under src"    "$(tool_result c6)" "src/a.txt"
assert_eq "tools.jsonl has one line per call" "$(wc -l <"$T/o1/glm.tools.jsonl" | tr -d ' ')" "6"
assert_eq "tools.jsonl marks the refused call"  "$(jq -r 'select(.args.path == "../outside.txt") | .rc' "$T/o1/glm.tools.jsonl")" "error"
assert_contains "prompt announces the tools instead of 'no tools'" "$(jq -r '.messages[0].content' "$T/o1/glm.turn.1.request.json")" "You have tools: read_file"
assert_contains "whole-file paste is still present by default (tool_context=files)" "$(jq -r '.messages[0].content' "$T/o1/glm.turn.1.request.json")" "<files>"
assert_eq "turn-1 request carries 3 tool defs (no run_check in read mode)" "$(jq -r '.tools | length' "$T/o1/glm.turn.1.request.json")" "3"
assert_eq "context_files still counted when the paste happened" "$(jq -r .context_files "$META")" "1"

echo "── check arm: run_check runs the repo's entrypoint once, cached ──"
run_lane "$T/o2" CROSS_REVIEW_TOOL_MODE=check CROSS_REVIEW_CHECK_CMD='echo CHECK_RAN_MARKER; exit 3' --
META="$T/o2/glm.meta.json"
assert_eq "context_access=tool_check"      "$(jq -r .context_access "$META")" "tool_check"
assert_eq "check_ran=true"                 "$(jq -r .tool_stats.check_ran "$META")" "true"
assert_eq "check_rc recorded (3)"          "$(jq -r .tool_stats.check_rc "$META")" "3"
assert_eq "turn-1 request carries 4 tool defs" "$(jq -r '.tools | length' "$T/o2/glm.turn.1.request.json")" "4"
MSGS2="$T/o2/glm.turn.2.request.json"
assert_contains "run_check result names the command"  "$(tool_result c5)" "verify command: echo CHECK_RAN_MARKER"
assert_contains "run_check result carries the exit code" "$(tool_result c5)" "exit code: 3 (FAIL)"
assert_contains "run_check result carries the output"  "$(tool_result c5)" "CHECK_RAN_MARKER"
[[ -f "$T/o2/check.result.json" ]] && ok "check.result.json cached for the round" || bad "check.result.json missing"
assert_eq "cached result rc=3" "$(jq -r .rc "$T/o2/check.result.json")" "3"

echo "── check requested but the repo declares no entrypoint → read ──"
run_lane "$T/o3" CROSS_REVIEW_TOOL_MODE=check --
META="$T/o3/glm.meta.json"
assert_eq "degrades to read"                "$(jq -r .tool_policy.mode "$META")" "read"
assert_eq "basis says why"                  "$(jq -r .tool_policy.basis "$META")" "override:no_check_entrypoint"
assert_eq "context_access=tool_read"        "$(jq -r .context_access "$META")" "tool_read"

echo "── off arm: byte-for-byte the single shot ──"
run_lane "$T/o4" CROSS_REVIEW_TOOL_MODE=off --
META="$T/o4/glm.meta.json"
assert_eq "context_access=file_context"     "$(jq -r .context_access "$META")" "file_context"
assert_eq "tool_stats.mode=off"             "$(jq -r .tool_stats.mode "$META")" "off"
assert_eq "tool_policy.basis=override"      "$(jq -r .tool_policy.basis "$META")" "override"
assert_eq "no tools in the request"         "$(jq -r 'has("tools")' "$T/o4/glm.request.json")" "false"
assert_contains "prompt says no tools"      "$(jq -r '.messages[0].content' "$T/o4/glm.request.json")" "You have no file-reading or shell tools."
[[ ! -f "$T/o4/glm.tools.jsonl" ]] && ok "no tools.jsonl written" || bad "tools.jsonl written in off mode"

echo "── step budget: forced final turn with tool_choice:none ──"
run_lane "$T/o5" CROSS_REVIEW_TOOL_MODE=read CROSS_REVIEW_TOOL_MAX_STEPS=2 SHIM_MODE=always --
META="$T/o5/glm.meta.json"
assert_eq "exit_code 0 after forced final" "$(jq -r .exit_code "$META")" "0"
assert_eq "steps capped at 2"              "$(jq -r .tool_stats.steps "$META")" "2"
assert_eq "three turns (2 tool turns + forced final)" "$(jq -r .tool_stats.turns "$META")" "3"
assert_eq "final request sets tool_choice=none" "$(jq -r '.tool_choice // ""' "$T/o5/glm.turn.3.request.json")" "none"
assert_contains "budget message injected" "$(jq -r '.messages[-1].content' "$T/o5/glm.turn.3.request.json")" "Tool budget exhausted"
assert_contains "final content still captured" "$(cat "$T/o5/glm.stdout")" "verified via tools"

echo "── read budget: exhausted reads are refused, not served ──"
run_lane "$T/o6" CROSS_REVIEW_TOOL_MODE=read CROSS_REVIEW_TOOL_READ_BUDGET_BYTES=10 --
MSGS2="$T/o6/glm.turn.2.request.json"
assert_eq "budget_exhausted=true"            "$(jq -r .tool_stats.budget_exhausted "$T/o6/glm.meta.json")" "true"
assert_contains "first read is served and flagged" "$(tool_result c1)" "read budget exhausted"

echo "── a host that reports no cache counters stays null, not a measured 0% ──"
# Moonshot-direct omits usage.prompt_tokens_details entirely. Summing it as 0
# would enter the run in analyze_runlog's hit-rate denominator as a real 0%
# sample, dragging every seat's average toward zero (codex P2, this PR).
run_lane "$T/o6c" CROSS_REVIEW_TOOL_MODE=read SHIM_MODE=nocache --
assert_eq "no cache counters reported → tokens_cached null" "$(jq -r .tokens_cached "$T/o6c/glm.meta.json")" "null"
assert_eq "…and tokens_cache_write null too"                "$(jq -r .tokens_cache_write "$T/o6c/glm.meta.json")" "null"
assert_eq "cost/tokens still recorded"                      "$(jq -r .tokens_prompt "$T/o6c/glm.meta.json")" "150"
assert_eq "provider still recorded"                         "$(jq -r .upstream_provider "$T/o6c/glm.meta.json")" "Shimco"

echo "── response_format rejected alongside tools → dropped and retried ──"
run_lane "$T/o7" CROSS_REVIEW_TOOL_MODE=read SHIM_MODE=rf400 --
META="$T/o7/glm.meta.json"
assert_eq "exit_code 0"                      "$(jq -r .exit_code "$META")" "0"
assert_eq "rf_dropped=true"                  "$(jq -r .tool_stats.rf_dropped "$META")" "true"
assert_eq "rejected turn 1 kept its request (had response_format)" "$(jq -r 'has("response_format")' "$T/o7/glm.turn.1.request.json")" "true"
assert_eq "retried request (turn 2) has no response_format" "$(jq -r 'has("response_format")' "$T/o7/glm.turn.2.request.json")" "false"
assert_eq "turns counts the rejected call too" "$(jq -r '.tool_stats.turns >= 2' "$META")" "true"
assert_contains "stderr explains"            "$(cat "$T/o7/glm.stderr")" "retrying this turn without it"

echo "── profile opt-out (supports_json_object=false) reaches the tool loop ──"
# seed's profile opts out of response_format. The tool-loop branch used to read
# rf_args[1] ("rf") instead of rf_args[2] ("null"), so the opt-out was logged
# and then ignored, and seed 400'd on every tool-loop draw (PR #99 round).
( cd "$REPO" && env CROSS_REVIEW_TOOL_MODE=read bash "$S/run_reviewers.sh" --base main --out "$T/o7b" --reviewers seed --timeout 60 >"$T/o7b.log" 2>&1 )
assert_eq "seed turn-1 request has no response_format" "$(jq -r 'has("response_format")' "$T/o7b/seed.turn.1.request.json")" "false"
assert_eq "seed lane succeeded"                 "$(jq -r .exit_code "$T/o7b/seed.meta.json")" "0"
assert_eq "not a runtime drop — the profile did it" "$(jq -r .tool_stats.rf_dropped "$T/o7b/seed.meta.json")" "false"
assert_contains "stderr says omitted by profile" "$(cat "$T/o7b.log" "$T/o7b/seed.stderr" 2>/dev/null)" "response_format omitted"

echo "── tool_context=diff drops the whole-file paste when tools are on ──"
run_lane "$T/o8" CROSS_REVIEW_TOOL_MODE=read CROSS_REVIEW_TOOL_CONTEXT=diff --
assert_not_contains "no <files> block" "$(jq -r '.messages[0].content' "$T/o8/glm.turn.1.request.json")" "<files>"
assert_eq "context_files=0 when the paste was dropped" "$(jq -r .context_files "$T/o8/glm.meta.json")" "0"
assert_not_contains "intro no longer promises whole files" "$(jq -r '.messages[0].content' "$T/o8/glm.turn.1.request.json")" "whole-file contents that follow"
assert_contains "intro says the files are not pasted"      "$(jq -r '.messages[0].content' "$T/o8/glm.turn.1.request.json")" "NOT pasted"

echo "── search honours the secret-path policy (codex P1, PR #154) ──"
SRCH="$( . "$S/lib_tool_loop.sh"; tl_search "$REPO" "." )"
assert_contains     "search still returns ordinary files" "$SRCH" "src/a.txt:"
assert_not_contains "search drops hits inside .env"        "$SRCH" ".env:"
assert_not_contains "…so the secret never leaves"          "$SRCH" "should-never-be-read"
assert_contains     "search refuses a secret path_glob"    "$( . "$S/lib_tool_loop.sh"; tl_search "$REPO" "." ".env" )" "secret-path policy"
# Pass 2 (codex P1/P2): a ':' in the filename defeated the output filter,
# and 200+ protected hits ate the result cap before the filter ran.
SREPO="$T/srepo"; mkdir -p "$SREPO/src"
( cd "$SREPO" && git init -q && git config user.email t@t && git config user.name t
  printf 'SECRETCOLON=1\n' >'foo:.env'
  for i in $(seq 1 250); do echo "xsecret line $i"; done >.env
  printf 'alpha x\n' >src/a.txt
  git add -A && git commit -qm s )
SRCH2="$( . "$S/lib_tool_loop.sh"; tl_search "$SREPO" "SECRETCOLON|alpha" )"
assert_contains     "colon-path repo: ordinary hit returned"      "$SRCH2" "src/a.txt:"
assert_not_contains "colon-path repo: foo:.env never returned"    "$SRCH2" "SECRETCOLON"
SRCH3="$( . "$S/lib_tool_loop.sh"; tl_search "$SREPO" "x" )"
assert_contains     "250 protected hits no longer starve the cap" "$SRCH3" "src/a.txt:"
assert_not_contains "…and none of them leak"                      "$SRCH3" "xsecret"
assert_eq "search over only protected files → no matches" "$( . "$S/lib_tool_loop.sh"; tl_search "$SREPO" "SECRETCOLON" "foo*" )" "no matches"

echo "── read_file caps in bytes, not characters (codex P2, PR #154) ──"
UREPO="$T/urepo"; mkdir -p "$UREPO"
( cd "$UREPO" && git init -q && git config user.email t@t && git config user.name t
  python3 -c "print('é' * 40)" >u.txt && git add -A && git commit -qm u )
UOUT="$( CROSS_REVIEW_TOOL_CALL_CAP_BYTES=50 bash -c '. "$1/lib_tool_loop.sh"; tl_read_file "$2" u.txt 1 1; printf "\nREAD_BYTES=%s" "$TL_READ_BYTES"' _ "$S" "$UREPO" )"
assert_contains "82-byte body is cut at the 50-byte cap" "$UOUT" "[truncated at 50 bytes]"
assert_contains "read_bytes counts the capped bytes"     "$UOUT" "READ_BYTES=50"
if printf '%s' "$UOUT" | iconv -f UTF-8 -t UTF-8 >/dev/null 2>&1; then ok "cut body is still valid UTF-8"; else bad "cut body is still valid UTF-8 (invalid UTF-8)"; fi
# Pass 2: an odd cap splits a 2-byte char; the budget pays for what was kept (kimi).
UOUT2="$( CROSS_REVIEW_TOOL_CALL_CAP_BYTES=51 bash -c '. "$1/lib_tool_loop.sh"; tl_read_file "$2" u.txt 1 1; printf "\nREAD_BYTES=%s" "$TL_READ_BYTES"' _ "$S" "$UREPO" )"
assert_contains "odd cap: marker says 51"                   "$UOUT2" "[truncated at 51 bytes]"
assert_contains "odd cap: split byte dropped → 50 charged"  "$UOUT2" "READ_BYTES=50"
# Pass 3 (codex P2): bash 3.2's printf %d signs high bytes (0xC3 → -61).
if [[ -x /bin/bash ]]; then
  UOUT3="$( CROSS_REVIEW_TOOL_CALL_CAP_BYTES=51 /bin/bash -c '. "$1/lib_tool_loop.sh"; tl_read_file "$2" u.txt 1 1; printf "\nREAD_BYTES=%s" "$TL_READ_BYTES"' _ "$S" "$UREPO" )"
  assert_contains "odd cap under /bin/bash ($(/bin/bash -c 'echo $BASH_VERSION')): 50 charged" "$UOUT3" "READ_BYTES=50"
  if printf '%s' "$UOUT3" | iconv -f UTF-8 -t UTF-8 >/dev/null 2>&1; then ok "…and the body is valid UTF-8"; else bad "…body invalid UTF-8 under /bin/bash"; fi
fi
# Pass 2 (codex P2): a body past the pipe buffer used to be emitted TWICE
# under pipefail (printf's SIGPIPE tripped the old || fallback).
( cd "$UREPO" && python3 -c "print('\n'.join('L%04d ' % i + 'y' * 400 for i in range(400)))" >big.txt && git add -A && git commit -qm big )
BOUT="$( bash -c 'set -o pipefail; . "$1/lib_tool_loop.sh"; tl_read_file "$2" big.txt 1 400; printf "\nREAD_BYTES=%s" "$TL_READ_BYTES"' _ "$S" "$UREPO" )"
assert_eq "160 KB body: exactly one truncation marker" "$(printf '%s' "$BOUT" | grep -c '\[truncated at 40000 bytes\]')" "1"
assert_eq "160 KB body: output stays near the cap"      "$(( $(printf '%s' "$BOUT" | wc -c) < 40200 ))" "1"
assert_contains "160 KB body: budget charged the cap"   "$BOUT" "READ_BYTES=40000"

echo "── run_check is bounded by the lane's remaining budget (codex P2, PR #154) ──"
CK="$T/ck"; mkdir -p "$CK"
_t0=$(date +%s)
CKT="$( CROSS_REVIEW_CHECK_CMD='sleep 40' bash -c '. "$1/lib_tool_loop.sh"; TIMEOUT_BIN="$(command -v gtimeout || command -v timeout)"; TL_DEADLINE=$3; tl_run_check "$2" "$4"' _ "$S" "$REPO" "$(( _t0 + 12 ))" "$CK" )"
_t1=$(date +%s)
CKR="$(cat "$CK"/check.result.partial.* 2>/dev/null)"
assert_eq "check timed out under the lane budget" "$(jq -r .timed_out <<<"$CKR")" "true"
assert_eq "timeout_s clamped to the 5 s floor (12 s left - 10 s margin)" "$(jq -r .timeout_s <<<"$CKR")" "5"
if (( _t1 - _t0 < 30 )); then ok "returned well before the 40 s command would have"; else bad "returned well before the 40 s command (took $((_t1 - _t0))s)"; fi
# Pass 2 (codex P2): a budget-forced timeout is lane-private, never the round's verdict.
assert_eq "clamped timeout is marked partial"            "$(jq -r .partial <<<"$CKR")" "true"
assert_contains "…and the model is told so"               "$CKT" "not a verdict on the suite"
[[ ! -f "$CK/check.result.json" ]] && ok "no round-wide check.result.json was written" || bad "round-wide result cached from a clamped timeout"
[[ ! -d "$CK/check.lock" ]] && ok "lock released for the next seat" || bad "lock still held after a partial run"
CKR2="$( CROSS_REVIEW_CHECK_CMD='echo FULL_RUN' bash -c '. "$1/lib_tool_loop.sh"; TIMEOUT_BIN="$(command -v gtimeout || command -v timeout)"; tl_run_check "$2" "$3" >/dev/null; cat "$3/check.result.json"' _ "$S" "$REPO" "$CK" )"
assert_eq "next seat with budget runs the real check"    "$(jq -r .rc <<<"$CKR2")" "0"
assert_eq "…and that one is cached round-wide"           "$(jq -r .partial <<<"$CKR2")" "false"
# Pass 3 (codex P2): partial files are unique per lane ($$ is shared by background lanes).
CKP="$T/ckp"; mkdir -p "$CKP"
for i in 1 2; do ( CROSS_REVIEW_CHECK_CMD='sleep 40' bash -c '. "$1/lib_tool_loop.sh"; TIMEOUT_BIN="$(command -v gtimeout || command -v timeout)"; TL_DEADLINE=$(( $(date +%s) + 12 )); tl_run_check "$2" "$3" >/dev/null' _ "$S" "$REPO" "$CKP" ); done
assert_eq "two sequential partial runs keep two files" "$(ls "$CKP"/check.result.partial.* | wc -l | tr -d ' ')" "2"
# Pass 3 (codex P2): a waiter whose holder went partial becomes the holder and runs the real check.
CKA="$T/cka"; mkdir -p "$CKA"
( CROSS_REVIEW_CHECK_CMD='sleep 7; echo REAL_DONE' bash -c '. "$1/lib_tool_loop.sh"; TIMEOUT_BIN="$(command -v gtimeout || command -v timeout)"; TL_DEADLINE=$(( $(date +%s) + 12 )); tl_run_check "$2" "$3" >/dev/null' _ "$S" "$REPO" "$CKA" ) &
sleep 1
AOUT="$( CROSS_REVIEW_CHECK_CMD='sleep 7; echo REAL_DONE' bash -c '. "$1/lib_tool_loop.sh"; TIMEOUT_BIN="$(command -v gtimeout || command -v timeout)"; TL_DEADLINE=$(( $(date +%s) + 90 )); tl_run_check "$2" "$3"' _ "$S" "$REPO" "$CKA" )"
wait
assert_contains "waiter took over after the holder's partial and ran the real check" "$AOUT" "REAL_DONE"
assert_contains "…with a full pass"                                                    "$AOUT" "exit code: 0"
[[ -f "$CKA/check.result.json" ]] && ok "…cached round-wide by the waiter-turned-holder" || bad "no round-wide result after takeover"
# Pass 2 (kimi High): a waiter with a small budget still waits for the holder's run.
CKW="$T/ckw"; mkdir -p "$CKW"
( CROSS_REVIEW_CHECK_CMD='sleep 4; echo HOLDER_DONE' bash -c '. "$1/lib_tool_loop.sh"; TIMEOUT_BIN="$(command -v gtimeout || command -v timeout)"; tl_run_check "$2" "$3" >/dev/null' _ "$S" "$REPO" "$CKW" ) &
sleep 1
_w0=$(date +%s)
WOUT="$( CROSS_REVIEW_CHECK_CMD='sleep 4; echo HOLDER_DONE' bash -c '. "$1/lib_tool_loop.sh"; TIMEOUT_BIN="$(command -v gtimeout || command -v timeout)"; TL_DEADLINE=$(( $(date +%s) + 30 )); tl_run_check "$2" "$3"' _ "$S" "$REPO" "$CKW" )"
wait
assert_contains "waiter received the holder's cached result" "$WOUT" "HOLDER_DONE"
assert_contains "…with the holder's exit code"                "$WOUT" "exit code: 0"
if (( $(date +%s) - _w0 < 20 )); then ok "waiter returned as soon as the holder finished"; else bad "waiter overwaited"; fi

echo "── a snapshot seat stays single-shot ──"
mkdir -p "$T/snap"; printf 'SNAPSHOT_BODY\n' >"$T/snap/snapshot-glm.md"
run_lane "$T/o9" CROSS_REVIEW_TOOL_MODE=read -- --snapshot-dir "$T/snap"
assert_eq "context_access=snapshot"          "$(jq -r .context_access "$T/o9/glm.meta.json")" "snapshot"
assert_eq "tool_policy.basis=snapshot"       "$(jq -r .tool_policy.basis "$T/o9/glm.meta.json")" "snapshot"

echo "── --tool-mode flag validation ──"
( cd "$REPO" && bash "$S/run_reviewers.sh" --base main --out "$T/o10" --reviewers glm --tool-mode bogus >"$T/o10.log" 2>&1 ); rc=$?
assert_eq "bogus --tool-mode exits 2" "$rc" "2"
assert_contains "…with a usage message" "$(cat "$T/o10.log")" "--tool-mode must be"

echo "── secret patterns stay in sync with worktree.sh ──"
wt_path="$(grep -m1 -oE "secret_pattern='[^']*'" "$S/worktree.sh" | sed "s/^secret_pattern=//")"
tl_path="$(grep -m1 -oE "TL_SECRET_PATH_PATTERN='[^']*'" "$S/lib_tool_loop.sh" | sed "s/^TL_SECRET_PATH_PATTERN=//")"
assert_eq "path pattern identical" "$tl_path" "$wt_path"
wt_content="$(grep -m1 "content_secret_pattern='" "$S/worktree.sh" | sed "s/^[[:space:]]*content_secret_pattern=//")"
tl_content="$(grep -m1 "TL_SECRET_CONTENT_PATTERN='" "$S/lib_tool_loop.sh" | sed "s/^TL_SECRET_CONTENT_PATTERN=//")"
assert_eq "content pattern identical" "$tl_content" "$wt_content"

echo "── tl_resolve_check_cmd ladder ──"
# shellcheck source=../scripts/lib_tool_loop.sh
source "$S/lib_tool_loop.sh"
R="$T/ladder"; mkdir -p "$R"
if tl_resolve_check_cmd "$R" >/dev/null; then bad "empty repo resolves a command"; else ok "empty repo → no entrypoint"; fi
printf '{"scripts":{"verify":"true"}}' >"$R/package.json"
assert_eq "package.json verify script" "$(tl_resolve_check_cmd "$R")" "npm run -s verify"
printf 'check:\n\ttrue\n' >"$R/Makefile"
assert_eq "package.json wins over Makefile" "$(tl_resolve_check_cmd "$R")" "npm run -s verify"
rm "$R/package.json"
assert_eq "Makefile check target" "$(tl_resolve_check_cmd "$R")" "make check"
printf 'verify:\n\ttrue\ncheck:\n\ttrue\n' >"$R/Makefile"
assert_eq "Makefile verify beats check" "$(tl_resolve_check_cmd "$R")" "make verify"
mkdir -p "$R/.claude"; printf 'true\n' >"$R/.claude/verify.sh"
assert_eq ".claude/verify.sh wins" "$(tl_resolve_check_cmd "$R")" "bash .claude/verify.sh"
assert_eq "CROSS_REVIEW_CHECK_CMD wins over everything" "$(CROSS_REVIEW_CHECK_CMD='my check' tl_resolve_check_cmd "$R")" "my check"

echo "── provider failures are classified, in both lanes ──"
run_lane "$T/ob1" CROSS_REVIEW_TOOL_MODE=read SHIM_MODE=bill402 --
META="$T/ob1/glm.meta.json"
assert_eq "read arm 402 → failure_kind provider_billing" "$(jq -r .failure_kind "$META")" "provider_billing"
assert_eq "…exit_code 1"                                  "$(jq -r .exit_code "$META")" "1"
assert_eq "…no tool steps"                                "$(jq -r .tool_stats.steps "$META")" "0"
assert_eq "…timed_out false"                              "$(jq -r .timed_out "$META")" "false"
run_lane "$T/ob2" CROSS_REVIEW_TOOL_MODE=off SHIM_MODE=bill402 --
assert_eq "off arm 402 → failure_kind provider_billing"   "$(jq -r .failure_kind "$T/ob2/glm.meta.json")" "provider_billing"
run_lane "$T/ob3" CROSS_REVIEW_TOOL_MODE=read SHIM_MODE=err400 --
META="$T/ob3/glm.meta.json"
assert_eq "read arm generic 400 → provider_error"         "$(jq -r .failure_kind "$META")" "provider_error"
assert_eq "…rf was dropped and retried first"             "$(jq -r .tool_stats.rf_dropped "$META")" "true"
run_lane "$T/ob4" CROSS_REVIEW_TOOL_MODE=read SHIM_MODE=bill402 --
# The learner must now ignore these: feed ob1's meta shape into the fixture ledger.
printf '{"run_id":"x","reviewers":{"glm":%s}}\n' "$(jq -c '. + {status:"failed"}' "$T/ob1/glm.meta.json")" >>"$CROSS_REVIEW_RUNLOG"
D="$(bash "$S/tool_policy.sh" --reviewer glm --repo-root "$REPO" 2>/dev/null)"
assert_eq "tool_policy excludes the classified 402 row"    "$(jq -r '[.excluded_runs, .window_runs] | join("/")' <<<"$D")" "1/0"
: >"$CROSS_REVIEW_RUNLOG"
# tl_classify_api_error on the shapes we know
printf '{"error":{"code":429,"message":"Rate limit exceeded"}}' >"$T/e1.json"
printf '{"error":{"message":"Your account has an insufficient balance"}}' >"$T/e2.json"
printf '{"error":{"code":401,"message":"No auth credentials found"}}' >"$T/e3.json"
printf '{"error":{"message":"Provider returned error"}}' >"$T/e4.json"
assert_eq "429 → provider_rate_limited"       "$(tl_classify_api_error "$T/e1.json")" "provider_rate_limited"
assert_eq "balance message → provider_billing" "$(tl_classify_api_error "$T/e2.json")" "provider_billing"
assert_eq "401 → provider_auth"                "$(tl_classify_api_error "$T/e3.json")" "provider_auth"
assert_eq "anything else → provider_error"     "$(tl_classify_api_error "$T/e4.json")" "provider_error"

# ── a dead provider catalog is fetched once, not once per turn ──
# The production caller is pin_slug="$(tl_provider_slug …)" — a command
# substitution — so the "already tried" state must survive a subshell. Every
# call below uses that exact shape; a shell-variable guard passes a direct
# call and still re-fetches here.
mkdir -p "$T/curlshim"
cat >"$T/curlshim/curl" <<'SH'
#!/bin/bash
echo call >>"$CURL_CALLS"
[[ -n "${CURL_BODY:-}" ]] || exit 7
cat "$CURL_BODY"
SH
chmod +x "$T/curlshim/curl"

mkdir -p "$T/home_dead"
(
  export CURL_CALLS="$T/curl.dead"; : >"$CURL_CALLS"
  export HOME="$T/home_dead"; export PATH="$T/curlshim:$PATH"
  unset CROSS_REVIEW_OR_PROVIDERS_FILE
  a="$(tl_provider_slug "Ambient")"; b="$(tl_provider_slug "Ambient")"
  c="$(tl_provider_slug "Inceptron")"
)
assert_eq "a dead provider catalog is fetched once, not once per turn" \
  "$(wc -l <"$T/curl.dead" | tr -d ' ')" "1"

# …and the success path still caches, resolves, and is not re-fetched.
mkdir -p "$T/home_ok"
printf '{"data":[{"name":"Ambient","slug":"ambient"}]}' >"$T/providers_body.json"
(
  export CURL_CALLS="$T/curl.ok"; : >"$CURL_CALLS"
  export CURL_BODY="$T/providers_body.json"
  export HOME="$T/home_ok"; export PATH="$T/curlshim:$PATH"
  unset CROSS_REVIEW_OR_PROVIDERS_FILE
  printf '%s\n' "$(tl_provider_slug "Ambient")" >"$T/slug1"
  printf '%s\n' "$(tl_provider_slug "Ambient")" >"$T/slug2"
)
assert_eq "a live catalog resolves the display name to its slug" "$(cat "$T/slug1")" "ambient"
assert_eq "a fresh cache is reused, not re-fetched"              "$(wc -l <"$T/curl.ok" | tr -d ' ')" "1"
assert_eq "the second call still resolves off the cache"         "$(cat "$T/slug2")" "ambient"
assert_eq "a successful refresh leaves no failure marker" \
  "$([[ -e "$T/home_ok/.cross-review/cache/or_providers.json.fetch-failed" ]] && echo yes || echo no)" "no"

echo
echo "══ $PASS passed, $FAIL failed ══"
[[ $FAIL -eq 0 ]]
