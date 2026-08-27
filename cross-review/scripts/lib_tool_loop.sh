#!/usr/bin/env bash
# lib_tool_loop.sh — the wrapper-owned tool harness for the chat-completions
# lanes (the OpenRouter pool, the direct-Moonshot seats, and every first-party
# lane that lands on OpenRouter as a fallback).
#
# Sourced by run_reviewers.sh (and by tool_policy.sh for tl_resolve_check_cmd).
# Not executable on its own. bash 3.2-clean (macOS default): no associative
# arrays, no ${var,,}.
#
# WHY THIS EXISTS. Until 2026-08-27 `codex` was the only seat that could read
# a file or run anything during a review; the other 17 were single-shot
# completions with the diff (+ whole changed files) pasted in. That was a
# choice, not a constraint: every pinned OpenRouter model advertises `tools`
# in supported_parameters, and Moonshot's endpoint is OpenAI-compatible.
# Rather than teach each vendor CLI a permission dialect (the agy soft-deny
# saga, kimi's adapter quirks), the WRAPPER is the harness: one bounded loop,
# one fixed toolset, executed here in the parent's sandbox, identical for
# every seat that speaks chat-completions.
#
# SECURITY MODEL — the model never chooses a command.
#   read_file   tracked, non-symlink, text files inside the repo root only;
#               per-call line cap, per-seat cumulative byte budget; the
#               worktree.sh secret PATH pattern refuses the read outright and
#               the secret CONTENT pattern is redacted from what is returned.
#   search      `git grep -n -I -E` with the pattern passed as an ARGUMENT
#               (never eval'd); pattern length + result line caps.
#   list_files  `git ls-files`, line cap.
#   run_check   the repository's OWN declared verify entrypoint
#               (CROSS_REVIEW_CHECK_CMD → .claude/verify.sh → package.json
#               "verify" script → Makefile verify/check target). Mode `check`
#               only. Run once per round and cached across seats. The model
#               can ask for it; it cannot say what it is.
#
# ARMS (tool modes): off | read | check. `off` is the pre-2026-08-27 single
# shot. tool_policy.sh picks the arm per seat from the ledgers (self-learning,
# see that file); CROSS_REVIEW_TOOL_MODE / --tool-mode overrides globally;
# a seat's profile `tools.mode` pins it.
#
# The loop writes, next to the lane's usual files:
#   <out>/<slug>.turn.<n>.request.json / .response.json   — every turn, audit
#   <out>/<slug>.tools.jsonl        — one line per tool call {step,name,args,bytes,rc}
#   <out>/check.result.json         — the cached run_check result (round-wide)
#   <out>/check.output.txt          — its raw combined output
# and leaves the lane's <slug>.request.json / <slug>.response.json pointing at
# the LAST turn so existing consumers keep working.
#
# Results are handed back in TL_* shell variables (documented at tool_loop_run).

# ── tunables (env; defaults mirror _synthesis_rules.tool_policy in
#    reviewer_profiles.json — run_reviewers.sh resolves profile→env before
#    sourcing, so the profile is the single source of truth for defaults) ──
TL_MAX_STEPS="${CROSS_REVIEW_TOOL_MAX_STEPS:-8}"
TL_MAX_CALLS_PER_TURN="${CROSS_REVIEW_TOOL_MAX_CALLS_PER_TURN:-6}"
TL_READ_BUDGET_BYTES="${CROSS_REVIEW_TOOL_READ_BUDGET_BYTES:-400000}"
TL_CALL_CAP_BYTES="${CROSS_REVIEW_TOOL_CALL_CAP_BYTES:-40000}"
TL_READ_MAX_LINES="${CROSS_REVIEW_TOOL_READ_MAX_LINES:-400}"
TL_SEARCH_MAX_LINES="${CROSS_REVIEW_TOOL_SEARCH_MAX_LINES:-200}"
TL_LIST_MAX_LINES="${CROSS_REVIEW_TOOL_LIST_MAX_LINES:-500}"
TL_CHECK_TIMEOUT_S="${CROSS_REVIEW_CHECK_TIMEOUT_S:-300}"
TL_CHECK_TAIL_BYTES="${CROSS_REVIEW_CHECK_TAIL_BYTES:-20000}"

# Same patterns as scripts/worktree.sh (the consent gate). Kept literal here
# rather than sourced so this library has no dependency on worktree.sh's
# argument parsing; tests/test_tool_loop.sh pins that they stay in sync.
TL_SECRET_PATH_PATTERN='\.env($|\.|/)|\.envrc|credentials|[Ss]ecret|\.pem$|\.key$|\.p12$|\.pfx$|id_rsa|id_ed25519|\.keystore|\.jks'
TL_SECRET_CONTENT_PATTERN='AKIA[0-9A-Z]{16}|[Ss][Kk]-[A-Za-z0-9_-]{20,}|[Aa][Pp][Ii][_-]?[Kk][Ee][Yy][[:space:]]*[:=][[:space:]]*['"'"'"][A-Za-z0-9/+=_-]{16,}['"'"'"]'

# tl_resolve_check_cmd <repo_root> — prints the repo's declared verify
# command, or returns 1 when the repo declares none. Order matches the
# global CLAUDE.md verify ladder. Only the REPO (or the operator, via env)
# gets a say here.
tl_resolve_check_cmd() {
  local root="$1"
  if [[ -n "${CROSS_REVIEW_CHECK_CMD:-}" ]]; then
    printf '%s' "$CROSS_REVIEW_CHECK_CMD"; return 0
  fi
  if [[ -f "$root/.claude/verify.sh" ]]; then
    printf 'bash .claude/verify.sh'; return 0
  fi
  if [[ -f "$root/package.json" ]] && command -v jq >/dev/null 2>&1 \
     && [[ "$(jq -r '.scripts.verify // empty' "$root/package.json" 2>/dev/null)" != "" ]]; then
    printf 'npm run -s verify'; return 0
  fi
  if [[ -f "$root/Makefile" ]]; then
    if grep -qE '^verify[[:space:]]*:' "$root/Makefile"; then printf 'make verify'; return 0; fi
    if grep -qE '^check[[:space:]]*:' "$root/Makefile";  then printf 'make check';  return 0; fi
  fi
  return 1
}

# tl_tool_defs <mode> <check_available true|false> — the `tools` array.
tl_tool_defs() {
  local mode="$1" check_avail="$2"
  local defs
  defs='[
    {"type":"function","function":{"name":"read_file",
      "description":"Read a tracked file from the post-change checkout, as numbered lines. Read a RANGE (start_line/end_line) around the hunk you are checking rather than whole large files; at most '"$TL_READ_MAX_LINES"' lines are returned per call and you have a total read budget for the whole review.",
      "parameters":{"type":"object","properties":{
        "path":{"type":"string","description":"Path relative to the repository root, exactly as it appears in the diff"},
        "start_line":{"type":"integer","description":"First line (1-based, inclusive)"},
        "end_line":{"type":"integer","description":"Last line (inclusive)"}},
        "required":["path"]}}},
    {"type":"function","function":{"name":"search",
      "description":"Search all tracked files with an extended regular expression (git grep -n -E). Returns up to '"$TL_SEARCH_MAX_LINES"' lines as path:line:text. Use it to find callers, other definitions, or whether a case is already handled elsewhere.",
      "parameters":{"type":"object","properties":{
        "pattern":{"type":"string","description":"POSIX extended regex"},
        "path_glob":{"type":"string","description":"Optional pathspec to narrow the search, e.g. src/ or *.ts"}},
        "required":["pattern"]}}},
    {"type":"function","function":{"name":"list_files",
      "description":"List tracked files under a directory (repo root when omitted).",
      "parameters":{"type":"object","properties":{
        "dir":{"type":"string","description":"Directory relative to the repository root"}}}}}
  ]'
  if [[ "$mode" == "check" && "$check_avail" == "true" ]]; then
    defs="$(jq -c '. + [{"type":"function","function":{"name":"run_check",
      "description":"Run the repository'"'"'s OWN declared verification entrypoint (its tests / typecheck / lint, exactly as the repo defines them). You cannot choose or change the command. The result is shared for the whole round, so call it at most once, and only when a finding of yours depends on runtime behaviour (\"this breaks the tests\", \"this does not compile\"). Returns the exit code and the tail of the output.",
      "parameters":{"type":"object","properties":{}}}}]' <<<"$defs")"
  else
    defs="$(jq -c . <<<"$defs")"
  fi
  printf '%s' "$defs"
}

# ── per-seat state (reset by tool_loop_run) ─────────────────────────────────
TL_READ_BYTES=0
TL_BUDGET_EXHAUSTED=false
TL_CHECK_RAN=false
TL_CHECK_RC="null"
TL_C_READ=0; TL_C_SEARCH=0; TL_C_LIST=0; TL_C_CHECK=0; TL_C_UNKNOWN=0

tl_bad_path() {
  # 0 (true) when the path may NOT be used. Relative, no NUL/newline, no
  # `..` segment, not the repo itself.
  local p="$1"
  [[ -z "$p" || "$p" == /* || "$p" == *$'\n'* || "$p" == "." || "$p" == "./" ]] && return 0
  local seg IFS='/'
  for seg in $p; do [[ "$seg" == ".." ]] && return 0; done
  return 1
}

# tl_read_file <repo_root> <path> <start> <end> — prints the tool result text.
tl_read_file() {
  local root="$1" p="$2" s="${3:-}" e="${4:-}"
  p="${p#./}"
  if tl_bad_path "$p"; then printf 'error: invalid path %s (must be relative to the repo root, no "..")' "$p"; return; fi
  if ! git -C "$root" ls-files --error-unmatch -- "$p" >/dev/null 2>&1; then
    printf 'error: %s is not a tracked file in this repository' "$p"; return
  fi
  if [[ -L "$root/$p" ]]; then printf 'error: %s is a symlink — refused' "$p"; return; fi
  if [[ ! -f "$root/$p" ]]; then printf 'error: %s does not exist in the checkout' "$p"; return; fi
  if printf '%s' "$p" | grep -qE "$TL_SECRET_PATH_PATTERN"; then
    printf 'error: %s matches the secret-path policy — refused' "$p"; return
  fi
  local size
  size="$(wc -c <"$root/$p" | tr -d ' ')"
  if [[ "$size" != "$(LC_ALL=C tr -d '\000' <"$root/$p" | wc -c | tr -d ' ')" ]]; then
    printf 'error: %s is binary' "$p"; return
  fi
  if [[ "$TL_BUDGET_EXHAUSTED" == true ]]; then
    printf 'error: read budget (%s bytes) exhausted — answer with what you have' "$TL_READ_BUDGET_BYTES"; return
  fi
  local total
  total="$(wc -l <"$root/$p" | tr -d ' ')"
  [[ "$s" =~ ^[0-9]+$ && "$s" -ge 1 ]] || s=1
  [[ "$e" =~ ^[0-9]+$ && "$e" -ge "$s" ]] || e=$((s + TL_READ_MAX_LINES - 1))
  local capped=false
  if (( e - s + 1 > TL_READ_MAX_LINES )); then e=$((s + TL_READ_MAX_LINES - 1)); capped=true; fi
  local body
  body="$(awk -v s="$s" -v e="$e" 'NR>=s && NR<=e { printf "%d\t%s\n", NR, substr($0, 1, 500) } NR>e { exit }' "$root/$p" \
          | sed -E "s/$TL_SECRET_CONTENT_PATTERN/[REDACTED]/g")"
  local bytes=${#body}
  if (( bytes > TL_CALL_CAP_BYTES )); then body="${body:0:$TL_CALL_CAP_BYTES}"$'\n'"[truncated at $TL_CALL_CAP_BYTES bytes]"; bytes=$TL_CALL_CAP_BYTES; fi
  TL_READ_BYTES=$((TL_READ_BYTES + bytes))
  (( TL_READ_BYTES >= TL_READ_BUDGET_BYTES )) && TL_BUDGET_EXHAUSTED=true
  printf '%s (lines %d-%d of %d)%s\n%s' "$p" "$s" "$(( e < total ? e : total ))" "$total" \
    "$([[ "$capped" == true ]] && printf ' [range capped at %d lines; call again with start_line=%d for more]' "$TL_READ_MAX_LINES" "$((e + 1))")" "$body"
  [[ "$TL_BUDGET_EXHAUSTED" == true ]] && printf '\n[read budget exhausted — no further reads will be served]'
}

tl_search() {
  local root="$1" pat="$2" glob="${3:-}"
  [[ -n "$pat" ]] || { printf 'error: empty pattern'; return; }
  (( ${#pat} > 200 )) && { printf 'error: pattern longer than 200 characters'; return; }
  [[ "$pat" == *$'\n'* ]] && { printf 'error: pattern must be a single line'; return; }
  local -a spec=()
  if [[ -n "$glob" ]]; then
    glob="${glob#./}"
    if tl_bad_path "$glob" && [[ "$glob" != "." ]]; then printf 'error: invalid path_glob %s' "$glob"; return; fi
    [[ "$glob" == :* ]] && { printf 'error: pathspec magic is not allowed in path_glob'; return; }
    # Models write `src/**/*.py`; git's default pathspec has no `**`, so that
    # silently matched nothing on the first live probe (2026-08-27). The
    # :(glob) magic gives `**` its usual meaning; a plain directory/file
    # pathspec is left as is.
    # Under :(glob) a bare `*.py` matches top-level files only; a model that
    # writes it means "every .py file", so prefix `**/` when there is no `/`.
    if [[ "$glob" == *"*"* ]]; then
      [[ "$glob" != */* ]] && glob="**/$glob"
      spec=(-- ":(glob)$glob")
    else
      spec=(-- "$glob")
    fi
  fi
  local outp rc
  outp="$(git -C "$root" grep -n -I -E --no-color -e "$pat" ${spec[@]+"${spec[@]}"} 2>&1 | head -n "$TL_SEARCH_MAX_LINES" | cut -c1-400 \
          | sed -E "s/$TL_SECRET_CONTENT_PATTERN/[REDACTED]/g")"; rc=$?
  if [[ -z "$outp" ]]; then printf 'no matches'; return; fi
  local n; n="$(printf '%s\n' "$outp" | wc -l | tr -d ' ')"
  printf '%s' "$outp"
  (( n >= TL_SEARCH_MAX_LINES )) && printf '\n[capped at %d lines — narrow the pattern or path_glob]' "$TL_SEARCH_MAX_LINES"
  return 0
}

tl_list_files() {
  local root="$1" d="${2:-}"
  d="${d#./}"
  local -a spec=()
  if [[ -n "$d" && "$d" != "." ]]; then
    if tl_bad_path "$d"; then printf 'error: invalid dir %s' "$d"; return; fi
    spec=(-- "$d")
  fi
  local outp
  outp="$(git -C "$root" ls-files ${spec[@]+"${spec[@]}"} 2>/dev/null | head -n "$TL_LIST_MAX_LINES")"
  [[ -n "$outp" ]] || { printf 'no tracked files under %s' "${d:-.}"; return; }
  printf '%s' "$outp"
}

# tl_run_check <repo_root> <out_dir> — runs (or reuses) the round's single
# verify run. Concurrency: lanes are parallel background jobs; the first one
# to mkdir the lock runs it, the others wait for the result file.
tl_run_check() {
  local root="$1" outd="$2"
  local result="$outd/check.result.json" lock="$outd/check.lock" raw="$outd/check.output.txt"
  local cmd
  if ! cmd="$(tl_resolve_check_cmd "$root")"; then
    printf 'error: this repository declares no verify entrypoint (no .claude/verify.sh, package.json verify script, or Makefile verify/check target) — nothing can be run'; return
  fi
  if [[ ! -f "$result" ]]; then
    if mkdir "$lock" 2>/dev/null; then
      local t0 t1 rc=0 timed_out=false
      t0=$(date +%s)
      if [[ -n "${TIMEOUT_BIN:-}" ]]; then
        ( cd "$root" && "$TIMEOUT_BIN" -k 10 "$TL_CHECK_TIMEOUT_S" bash -c "$cmd" ) >"$raw" 2>&1 || rc=$?
      elif declare -F run_with_timeout >/dev/null; then
        ( cd "$root" && run_with_timeout "$TL_CHECK_TIMEOUT_S" bash -c "$cmd" ) >"$raw" 2>&1 || rc=$?
      else
        ( cd "$root" && bash -c "$cmd" ) >"$raw" 2>&1 || rc=$?
      fi
      t1=$(date +%s)
      [[ $rc -eq 124 || $rc -eq 137 ]] && timed_out=true
      local tail_txt
      tail_txt="$(tail -c "$TL_CHECK_TAIL_BYTES" "$raw" 2>/dev/null | LC_ALL=C tr -d '\000' | sed -E "s/$TL_SECRET_CONTENT_PATTERN/[REDACTED]/g")"
      jq -n --arg cmd "$cmd" --argjson rc "$rc" --argjson dur "$((t1 - t0))" --argjson to "$timed_out" --arg tail "$tail_txt" \
        '{cmd:$cmd, rc:$rc, duration_s:$dur, timed_out:$to, output_tail:$tail}' >"$result.tmp" && mv "$result.tmp" "$result"
    else
      local waited=0
      while [[ ! -f "$result" ]] && (( waited < TL_CHECK_TIMEOUT_S + 30 )); do sleep 2; waited=$((waited + 2)); done
      [[ -f "$result" ]] || { printf 'error: the verify run started by another reviewer has not finished — treat runtime claims as unverified'; return; }
    fi
  fi
  TL_CHECK_RAN=true
  TL_CHECK_RC="$(jq -r '.rc' "$result")"
  jq -r '"verify command: \(.cmd)\nexit code: \(.rc) (\(if .rc == 0 then "PASS" else "FAIL" end))\(if .timed_out then " — TIMED OUT" else "" end)\nduration: \(.duration_s)s\n--- output (tail) ---\n\(.output_tail)"' "$result"
}

# tl_exec <name> <args_json> <repo_root> <out_dir> — dispatch one tool call.
tl_exec() {
  local name="$1" args="$2" root="$3" outd="$4"
  local a
  case "$name" in
    read_file)
      TL_C_READ=$((TL_C_READ + 1))
      tl_read_file "$root" "$(jq -r '.path // ""' <<<"$args")" "$(jq -r '.start_line // ""' <<<"$args")" "$(jq -r '.end_line // ""' <<<"$args")" ;;
    search)
      TL_C_SEARCH=$((TL_C_SEARCH + 1))
      tl_search "$root" "$(jq -r '.pattern // ""' <<<"$args")" "$(jq -r '.path_glob // ""' <<<"$args")" ;;
    list_files)
      TL_C_LIST=$((TL_C_LIST + 1))
      tl_list_files "$root" "$(jq -r '.dir // ""' <<<"$args")" ;;
    run_check)
      TL_C_CHECK=$((TL_C_CHECK + 1))
      if [[ "$TL_MODE" != "check" ]]; then printf 'error: run_check is not available in this review'; else tl_run_check "$root" "$outd"; fi ;;
    *)
      TL_C_UNKNOWN=$((TL_C_UNKNOWN + 1))
      printf 'error: unknown tool %s' "$name" ;;
  esac
}

tl_calls_json() {
  jq -n --argjson r "$TL_C_READ" --argjson s "$TL_C_SEARCH" --argjson l "$TL_C_LIST" \
        --argjson c "$TL_C_CHECK" --argjson u "$TL_C_UNKNOWN" \
        -c '{read_file:$r, search:$s, list_files:$l, run_check:$c, unknown:$u}'
}

# tl_post <cli> <key> <body_file> <resp_file> <stderr_file> <max_time> —
# one chat-completions call. Same secret hygiene as the single-shot lane:
# the bearer token reaches curl on stdin (never argv, never disk).
tl_post() {
  local cli="$1" key="$2" body="$3" resp="$4" err="$5" max_time="$6" endpoint="$7"
  local -a title_header=()
  [[ "$cli" == "openrouter" ]] && title_header=(-H "X-Title: cross-review")
  printf 'header = "Authorization: Bearer %s"\n' "$key" \
  | curl -sS --max-time "$max_time" --config - -H "Content-Type: application/json" \
      ${title_header[@]+"${title_header[@]}"} -d @"$body" "$endpoint" >"$resp" 2>>"$err"
  local rc=$?
  [[ $rc -eq 28 ]] && rc=124
  return $rc
}

# tl_classify_api_error <response_file> — name the provider-level failure so
# the learner can tell "the provider never judged this request" (billing,
# rate limit, auth, transport) from "the model broke on this arm" (a generic
# provider_error: bad tool schema for the route, refused response_format,
# malformed output). Only the second kind is evidence about the arm; the
# first would otherwise demote whichever arm happened to be drawn during an
# outage — three 402s on one seat looked exactly like read breaking the model
# (OpenRouter balance −$0.06, 2026-08-27). Matches OpenRouter/OpenAI-style
# bodies: {"error":{"code":402,"message":"Insufficient credits..."}}.
tl_classify_api_error() {
  local resp="$1" code msg
  code="$(jq -r '.error.code // .error.status // empty' "$resp" 2>/dev/null)"
  msg="$(jq -r '.error.message // empty' "$resp" 2>/dev/null)"
  case "$code" in
    402) echo provider_billing; return ;;
    429) echo provider_rate_limited; return ;;
    401|403) echo provider_auth; return ;;
  esac
  if printf '%s' "$msg" | grep -qiE 'insufficient (credits|balance|funds)|credits? (are|is) (exhausted|depleted)|negative balance|top up|payment required|billing'; then
    echo provider_billing
  elif printf '%s' "$msg" | grep -qiE 'rate.?limit|too many requests|quota exceeded|exceeded_current_quota'; then
    echo provider_rate_limited
  elif printf '%s' "$msg" | grep -qiE 'invalid api key|unauthori[sz]ed|authentication|forbidden'; then
    echo provider_auth
  else
    echo provider_error
  fi
}

tl_num() { jq -r "$1 | if type==\"number\" then tostring else \"0\" end" "$2" 2>/dev/null || echo 0; }

# tool_loop_run <slug> <model> <cli> <endpoint> <key> <timeout_budget>
#               <prompt_file> <rf_json|null> <mode> <out_dir> <repo_root>
#
# Drives the conversation until the model answers without tool calls, the
# step budget runs out (then one forced final turn with tool_choice:none),
# the wall budget runs out, or the API errors. Sets:
#   TL_RC          0 ok | 1 api error | 124 timeout | 5 empty final content
#   TL_COST TL_TOKP TL_TOKC   summed over every turn (null when nothing returned)
#   TL_STEPS       assistant turns that carried tool calls
#   TL_TURNS       total API calls made
#   TL_BUDGET_EXHAUSTED TL_READ_BYTES TL_CHECK_RAN TL_CHECK_RC (see above)
#   TL_RF_DROPPED  true when response_format had to be dropped for this model
#   TL_API_ERROR   the provider's error message, if any
#   TL_FAILURE_KIND  provider_billing | provider_rate_limited | provider_auth |
#                  provider_error | transport_error | "" (tl_classify_api_error)
# Writes <out>/<slug>.stdout with the final content.
tool_loop_run() {
  local slug="$1" model="$2" cli="$3" endpoint="$4" key="$5" budget="$6"
  local prompt_file="$7" rf="$8" mode="$9" outd="${10}" root="${11}"
  TL_MODE="$mode"
  TL_READ_BYTES=0; TL_BUDGET_EXHAUSTED=false; TL_CHECK_RAN=false; TL_CHECK_RC="null"
  TL_C_READ=0; TL_C_SEARCH=0; TL_C_LIST=0; TL_C_CHECK=0; TL_C_UNKNOWN=0
  TL_RC=0; TL_COST="null"; TL_TOKP="null"; TL_TOKC="null"; TL_STEPS=0; TL_TURNS=0
  TL_RF_DROPPED=false; TL_API_ERROR=""; TL_FAILURE_KIND=""
  local check_avail=false
  [[ "$mode" == "check" ]] && tl_resolve_check_cmd "$root" >/dev/null 2>&1 && check_avail=true
  local tools; tools="$(tl_tool_defs "$mode" "$check_avail")"
  local msgs="$outd/${slug}.messages.json" trace="$outd/${slug}.tools.jsonl"
  local err="$outd/${slug}.stderr"
  : >"$trace"
  jq -n --rawfile p "$prompt_file" '[{role:"user", content:$p}]' >"$msgs"
  local start now elapsed remaining
  start=$(date +%s)
  local cost_sum=0 tokp_sum=0 tokc_sum=0 any_usage=false
  local turn=0 final_content="" force_final=false
  while :; do
    turn=$((turn + 1)); TL_TURNS=$turn
    now=$(date +%s); elapsed=$((now - start)); remaining=$((budget - elapsed))
    if (( remaining < 10 )); then TL_RC=124; break; fi
    local body="$outd/${slug}.turn.${turn}.request.json" resp="$outd/${slug}.turn.${turn}.response.json"
    local rf_arg="$rf"
    [[ "$TL_RF_DROPPED" == true ]] && rf_arg="null"
    local extra='{}'
    [[ "$force_final" == true ]] && extra='{"tool_choice":"none"}'
    jq -n --arg m "$model" --slurpfile msgs "$msgs" --argjson tools "$tools" --argjson rf "$rf_arg" \
          --argjson extra "$extra" --arg cli "$cli" \
      '{model:$m, messages:$msgs[0], tools:$tools, stream:false}
       + (if $cli == "openrouter" then {usage:{include:true}} else {} end)
       + (if $rf == null then {} else {response_format:$rf} end)
       + $extra' >"$body"
    cp "$body" "$outd/${slug}.request.json"
    tl_post "$cli" "$key" "$body" "$resp" "$err" "$remaining" "$endpoint"
    local rc=$?
    cp "$resp" "$outd/${slug}.response.json" 2>/dev/null || true
    if [[ $rc -ne 0 ]]; then
      # curl itself failed: timeout stays a timeout; anything else never
      # reached a model and is not evidence about the arm.
      [[ $rc -eq 124 ]] || TL_FAILURE_KIND="transport_error"
      TL_RC=$rc; break
    fi
    local api_error
    api_error="$(jq -r '.error.message // empty' "$resp" 2>/dev/null)"
    if [[ -n "$api_error" ]]; then
      # Some providers reject response_format alongside tools. Drop it once
      # and retry the same turn; the JSON suffix in the prompt still asks for
      # findings.json shape, and merge_raw_findings.sh lists anything
      # unparseable rather than losing it.
      if [[ "$rf_arg" != "null" ]] && printf '%s' "$api_error" | grep -qiE 'response_format|json_object|json mode|tool'; then
        echo "$slug: provider rejected response_format with tools ($api_error) — retrying this turn without it" >>"$err"
        TL_RF_DROPPED=true; turn=$((turn - 1)); continue
      fi
      echo "$slug: $cli API error: $api_error" >>"$err"
      TL_API_ERROR="$api_error"; TL_FAILURE_KIND="$(tl_classify_api_error "$resp")"; TL_RC=1; break
    fi
    if [[ -s "$resp" ]] && jq -e '.usage' "$resp" >/dev/null 2>&1; then
      any_usage=true
      # jq, not awk's %.6f: the single-shot lane records the provider's own
      # number (0.0123), and a padded 0.012300 here would make the same run
      # look different across arms in the runlog.
      cost_sum="$(jq -n --argjson a "$cost_sum" --argjson b "$(tl_num .usage.cost "$resp")" '$a + $b')"
      tokp_sum=$((tokp_sum + $(tl_num .usage.prompt_tokens "$resp" | cut -d. -f1)))
      tokc_sum=$((tokc_sum + $(tl_num .usage.completion_tokens "$resp" | cut -d. -f1)))
    fi
    local ncalls
    ncalls="$(jq -r '.choices[0].message.tool_calls | if type=="array" then length else 0 end' "$resp" 2>/dev/null || echo 0)"
    if [[ "$ncalls" == "0" || "$force_final" == true ]]; then
      final_content="$(jq -r '.choices[0].message.content // empty' "$resp" 2>/dev/null)"
      break
    fi
    TL_STEPS=$((TL_STEPS + 1))
    # Append the assistant message verbatim (keeps reasoning_content for the
    # providers that need it threaded back), then one tool message per call.
    jq -c '.choices[0].message' "$resp" >"$msgs.assistant"
    jq -c --slurpfile a "$msgs.assistant" '. + $a' "$msgs" >"$msgs.tmp" && mv "$msgs.tmp" "$msgs"
    local i=0
    while (( i < ncalls )); do
      local call id name args result
      call="$(jq -c ".choices[0].message.tool_calls[$i]" "$resp")"
      id="$(jq -r '.id // "call_'"$turn"'_'"$i"'"' <<<"$call")"
      name="$(jq -r '.function.name // ""' <<<"$call")"
      args="$(jq -r '.function.arguments // "{}"' <<<"$call")"
      args="$(jq -c 'if type=="string" then (fromjson? // {}) else . end' <<<"$args" 2>/dev/null || echo '{}')"
      if (( i >= TL_MAX_CALLS_PER_TURN )); then
        result="error: more than $TL_MAX_CALLS_PER_TURN tool calls in one turn — this call was not executed"
      else
        # Redirect, don't $(...): a command substitution forks, and the
        # executor's bookkeeping (call counters, read budget, check_ran)
        # would be lost with the subshell. A redirected function call runs
        # in THIS shell.
        tl_exec "$name" "$args" "$root" "$outd" >"$outd/${slug}.tool.result.txt"
        result="$(cat "$outd/${slug}.tool.result.txt")"
      fi
      jq -n -c --argjson step "$TL_STEPS" --arg name "$name" --argjson args "$args" --argjson bytes "${#result}" \
            --arg rc "$([[ "$result" == error:* ]] && echo error || echo ok)" \
            '{step:$step, name:$name, args:$args, bytes:$bytes, rc:$rc}' >>"$trace"
      jq -c --arg id "$id" --arg name "$name" --arg c "$result" '. + [{role:"tool", tool_call_id:$id, name:$name, content:$c}]' "$msgs" >"$msgs.tmp" && mv "$msgs.tmp" "$msgs"
      i=$((i + 1))
    done
    if (( TL_STEPS >= TL_MAX_STEPS )); then
      force_final=true
      jq -c '. + [{role:"user", content:"Tool budget exhausted. Do not call any more tools. Answer now with your findings in the required JSON shape, based on what you have already seen; mark anything you could not verify as unverified."}]' "$msgs" >"$msgs.tmp" && mv "$msgs.tmp" "$msgs"
    fi
  done
  rm -f "$msgs.assistant" "$msgs.tmp" "$outd/${slug}.tool.result.txt"
  if [[ "$any_usage" == true ]]; then TL_COST="$cost_sum"; TL_TOKP="$tokp_sum"; TL_TOKC="$tokc_sum"; fi
  if [[ $TL_RC -eq 0 ]]; then
    printf '%s' "$final_content" >"$outd/${slug}.stdout"
    [[ -n "$final_content" ]] || TL_RC=5
  else
    : >"$outd/${slug}.stdout"
  fi
  return $TL_RC
}
