#!/usr/bin/env bash
# run_reviewers.sh — run codex, antigravity, gemini-pro, kimi, and/or glm in parallel against the current diff.
#
# Gemini-family reviewers (both via Google's `agy` Antigravity CLI as of the
# 2026-06-18 Gemini-CLI consumer sunset):
#   antigravity — `agy --model "Gemini 3.5 Flash (High)"`. Fast lap. Replaces the
#                 retired `gemini` (Gemini CLI Flash) reviewer slot.
#   gemini-pro  — `agy --model "Gemini 3.1 Pro (High)"`. Deep lap, slower. Was
#                 previously the standalone `gemini` CLI on gemini-3.1-pro-preview;
#                 migrated to agy because the gemini CLI stopped serving consumer
#                 requests on 2026-06-18 and agy now hosts Gemini 3.1 Pro + --model.
#   Install agy: `curl -fsSL https://antigravity.google/cli/install.sh | bash`
#                (lands at ~/.local/bin/agy). Auth: `agy login` once interactively.
#
# OpenRouter lane (rotating single-turn reviewers — NO fallbacks):
#   glm      — z-ai/glm-5.2                        (Zhipu)
#   deepseek — deepseek/deepseek-v4-flash          (DeepSeek)
#   mimo     — xiaomi/mimo-v2.5                    (Xiaomi)
#   minimax  — minimax/minimax-m3                  (MiniMax)
#   qwen     — qwen/qwen3-coder-next               (Alibaba)
#   devstral — mistralai/devstral-2512             (Mistral)
#   laguna   — poolside/laguna-m.1                 (Poolside)
#   kat      — kwaipilot/kat-coder-pro-v2          (Kuaishou)
#   north    — cohere/north-mini-code:free         (Cohere — free tier)
#   nemotron — nvidia/nemotron-3-ultra-550b-a55b:free (NVIDIA — free tier)
#   All are single-turn diff-inline reviews (same niche as kimi), each an
#   independent provider vote. Key resolution: $OPENROUTER_API_KEY env var,
#   else ~/.config/openrouter/key. No key → all ten are skipped.
#
#   POLICY (2026-07-01, per Gabriel): first-party reviewers (codex, the agy
#   Gemini laps, kimi) do NOT fall back to OpenRouter — when agy hits its
#   shared "Individual quota" (observed: exits 0 with empty stdout in ~5s and
#   only the .agy.log says RESOURCE_EXHAUSTED), the lap fails HONESTLY with
#   failure_kind=quota_exhausted and drops out of the round. Roster rotation
#   (select_roster.sh) compensates by drawing other providers.
#
#   Typical rounds run codex + kimi (fixed baselines) plus 2 rotation picks —
#   see select_roster.sh, which weights picks by the leaderboard.sh score.
#
# GOTCHA: `agy --model` takes the EXACT display-name string `agy models` prints
# (e.g. "Gemini 3.1 Pro (High)"). On an unrecognized string agy does NOT error —
# it silently falls back to its default (Gemini 3.5 Flash). So a typo here turns
# the "deep lap" into a second Flash run with no warning. Keep the model strings
# below in sync with `agy models`.
#
# Usage:
#   run_reviewers.sh --base <branch> --out <dir>
#                    [--reviewers codex,antigravity,gemini-pro,kimi,glm,deepseek,mimo,minimax,qwen,devstral,laguna,kat,north,nemotron]
#                    [--timeout <sec>]
#                    [--timeout-codex <sec>] [--timeout-antigravity <sec>]
#                    [--timeout-gemini-pro <sec>] [--timeout-kimi <sec>]
#                    [--timeout-glm <sec>]
#
# No --reviewers → select_roster.sh chooses the round's roster (codex + kimi
# baselines, ≥3 total, leaderboard-weighted rotation picks). Explicit
# --reviewers bypasses rotation entirely.
#
# Per-reviewer timeouts override the global --timeout. Codex tends to either
# return fast or fail fast; antigravity/gemini-pro/kimi do deep reasoning and
# need more headroom. Default policy: codex=300, antigravity=600, gemini-pro=900,
# kimi=600. The previous 300s blanket cap truncated dense-logic diffs
# (see PR #1985 postmortem).
#
# Writes:
#   <out>/codex.stdout         — codex review (stderr merged)
#   <out>/codex.meta.json      — {exit_code, duration_s}
#   <out>/antigravity.stdout   — antigravity (agy / Flash) review output
#   <out>/antigravity.stderr
#   <out>/antigravity.meta.json
#   <out>/gemini-pro.stdout    — gemini-pro (agy / Pro) review output
#   <out>/gemini-pro.stderr
#   <out>/gemini-pro.meta.json
#   <out>/kimi.stdout          — kimi review text (final assistant message)
#   <out>/kimi.stderr
#   <out>/kimi.meta.json
#   <out>/<or>.stdout          — each OpenRouter reviewer (glm, deepseek, mimo,
#   <out>/<or>.stderr            minimax, qwen, devstral, laguna, kat,
#   <out>/<or>.meta.json         north, nemotron) writes
#                                stdout/stderr/meta plus request.json and
#                                response.json for audit
#   <out>/agy.quota_exhausted  — sentinel: agy hit the shared Individual quota
#                                this run (contains the reset ETA). Spares
#                                retries and any lap that starts AFTER detection
#                                (~5s in); the concurrent sibling usually burns
#                                its own doomed call first (2s stagger). No
#                                fallback — the lap drops out of the round.
#   <out>/run.meta.json        — overall run metadata (skipped reason, etc.)
#
# meta.json extras: agy laps carry `failure_kind` (quota_exhausted | agy_panic |
# empty_output | null) and `quota_resets_in`; OpenRouter runs carry
# `cli: "openrouter"` and the exact `model` slug.
#
# Exit codes:
#   0 — at least one reviewer succeeded, OR run was skipped intentionally (empty diff)
#   1 — all requested reviewers failed, or none were available
#   2 — usage / argument error

set -uo pipefail

# Background/cron shells often run with a PATH that lacks the user-level bin
# dirs where reviewer CLIs live (kimi → ~/.local/bin; codex/agy → homebrew).
# rc=127 "command not found" then masquerades as reviewer unreliability —
# kimi logged failed=6 of 10 runs before this was caught (2026-07-03; a
# background-dispatched round hit `timeout: failed to run command 'kimi'`).
# Same failure class as the TIMEOUT_BIN homebrew probe further down.
# Iterate in REVERSE precedence order — each dir is prepended, so the last
# one wins the front of PATH. Forward order left ~/.local/bin THIRD when all
# three were missing, letting a stale homebrew kimi/agy shadow the intended
# user-level install (codex P2, PR #27 pass 2; smoke-tested both orders).
for _d in /usr/local/bin /opt/homebrew/bin "$HOME/.local/bin"; do
  [[ -d "$_d" && ":$PATH:" != *":$_d:"* ]] && PATH="$_d:$PATH"
done
export PATH

base=""
out=""
# Empty default: resolved after arg parsing. If --reviewers is not passed,
# select_roster.sh picks the round's roster (codex+kimi baselines + weighted
# rotation picks); if the selector is missing, fall back to the fixed classic
# fleet. Passing --reviewers explicitly always wins.
reviewers=""
# Global timeout default: 600s. Codex tightens to 300s below since it returns
# fast or fails fast. Antigravity/kimi keep 600s, gemini-pro gets 900s — the
# dense-logic diff in PR #1985 (postmortem in plans/the-miss-on-pr-eager-pond.md)
# blew through 300s on the prior gemini Flash reviewer, so we keep the bumped
# budget on its agy replacements.
# Track explicitness so CLI flags can override profile values: a user passing
# `--timeout 30` for a smoke run must beat the profile's 600s default.
timeout_s_default=600
timeout_s=""               # set when --timeout is explicitly passed
timeout_codex=""
timeout_antigravity=""
timeout_gemini_pro=""
timeout_kimi=""
timeout_glm=""

# Model IDs — passed verbatim to `agy --model`. These MUST match an `agy models`
# display name exactly; agy silently falls back to its default (Flash) on an
# unrecognized string rather than erroring (verified on agy 1.0.9, 2026-06-18).
# Overridable per-reviewer via reviewer_profiles.json `.model` (resolved below).
antigravity_model="Gemini 3.5 Flash (High)"
gemini_pro_model="Gemini 3.1 Pro (High)"

# OpenRouter model ids (exact slugs verified against
# https://openrouter.ai/api/v1/models, 2026-07-01; qwen/devstral/laguna/kat
# verified 2026-07-02). Overridable via
# reviewer_profiles.json `.model` (resolved below).
glm_model="z-ai/glm-5.2"
deepseek_model="deepseek/deepseek-v4-flash"
mimo_model="xiaomi/mimo-v2.5"
minimax_model="minimax/minimax-m3"
qwen_model="qwen/qwen3-coder-next"
devstral_model="mistralai/devstral-2512"
laguna_model="poolside/laguna-m.1"
kat_model="kwaipilot/kat-coder-pro-v2"
north_model="cohere/north-mini-code:free"
nemotron_model="nvidia/nemotron-3-ultra-550b-a55b:free"
# kimi27 rides the DIRECT Moonshot platform API (OpenAI-compatible), not
# OpenRouter — a deliberate rotation seat (2026-07-03, per Gabriel) on the
# same billing rail as the kimi baseline. The first-party no-OR-fallback
# policy above is untouched: this is not a fallback lane for kimi.
kimi27_model="kimi-k2.7-code"

# Antigravity installs `agy` to $HOME/.local/bin. That directory isn't always
# on $PATH for non-interactive shells (notably bash invocations from other
# tools). Surface it ourselves so `command -v agy` and a bare `agy` both
# resolve without requiring the user to edit their shell rc.
if [[ -d "$HOME/.local/bin" && ":$PATH:" != *":$HOME/.local/bin:"* ]]; then
  PATH="$HOME/.local/bin:$PATH"
fi

need_val() {
  local flag="$1"
  local argc="$2"
  if [[ "$argc" -lt 2 ]]; then
    echo "missing value for $flag" >&2
    exit 2
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --base)               need_val --base               "$#"; base="$2";               shift 2 ;;
    --out)                need_val --out                "$#"; out="$2";                shift 2 ;;
    --reviewers)          need_val --reviewers          "$#"; reviewers="$2";          shift 2 ;;
    --timeout)            need_val --timeout            "$#"; timeout_s="$2";          shift 2 ;;
    --timeout-codex)      need_val --timeout-codex      "$#"; timeout_codex="$2";      shift 2 ;;
    --timeout-antigravity) need_val --timeout-antigravity "$#"; timeout_antigravity="$2"; shift 2 ;;
    --timeout-gemini-pro) need_val --timeout-gemini-pro "$#"; timeout_gemini_pro="$2"; shift 2 ;;
    --timeout-kimi)       need_val --timeout-kimi       "$#"; timeout_kimi="$2";       shift 2 ;;
    --timeout-glm)        need_val --timeout-glm        "$#"; timeout_glm="$2";        shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

if [[ -z "$base" || -z "$out" ]]; then
  echo "usage: $0 --base <branch> --out <dir> [--reviewers codex,antigravity,gemini-pro,kimi,glm,deepseek,mimo,minimax,qwen,devstral,laguna,kat,north,nemotron] [--timeout <sec>] [--timeout-codex <sec>] [--timeout-antigravity <sec>] [--timeout-gemini-pro <sec>] [--timeout-kimi <sec>] [--timeout-glm <sec>]" >&2
  exit 2
fi

# Roster resolution: no --reviewers → ask select_roster.sh (weighted rotation,
# codex+kimi baselines). The selector prints a comma list on stdout and its
# reasoning on stderr (passed through so the user sees why the roster is what
# it is). Missing/failed selector → classic fixed fleet.
if [[ -z "$reviewers" ]]; then
  selector="$(cd "$(dirname "$0")" && pwd)/select_roster.sh"
  if [[ -x "$selector" ]] && reviewers="$(bash "$selector")" && [[ -n "$reviewers" ]]; then
    echo "roster (select_roster.sh): $reviewers" >&2
  else
    reviewers="codex,antigravity,gemini-pro,kimi,glm"
    echo "roster: selector unavailable — using fixed fallback fleet: $reviewers" >&2
  fi
fi

# Per-reviewer timeout precedence (CLI > config > built-in default):
#   1. --timeout-<reviewer>      (per-reviewer CLI flag, explicit)
#   2. --timeout                 (global CLI flag, explicit)
#   3. references/reviewer_profiles.json `.timeout_s`
#   4. timeout_s_default (with codex tightened to 300s, gemini-pro to 900s)
# This matches standard Unix conventions — explicit CLI always wins. The
# previous order put profile above --timeout, which silently broke
# `--timeout 30` smoke runs (caught by codex review on PR #10).
profile_file="$(cd "$(dirname "$0")/.." && pwd)/references/reviewer_profiles.json"
profile_get() {
  # Usage: profile_get <reviewer> <key>; prints the string value from the
  # profile, or empty string if jq/file/key absent.
  local r="$1" k="$2"
  [[ -f "$profile_file" ]] || { echo ""; return; }
  command -v jq >/dev/null 2>&1 || { echo ""; return; }
  jq -r --arg r "$r" --arg k "$k" '.[$r][$k] // empty' "$profile_file" 2>/dev/null
}
profile_timeout() { profile_get "$1" timeout_s; }

# Let reviewer_profiles.json `.model` override the built-in model strings, so an
# agy model rename can be fixed without editing this script. Fall back to the
# built-in default if the profile lacks a (non-empty) model.
_am="$(profile_get antigravity model)"; [[ -n "$_am" ]] && antigravity_model="$_am"
_gm="$(profile_get gemini-pro model)";  [[ -n "$_gm" ]] && gemini_pro_model="$_gm"
_zm="$(profile_get glm model)";         [[ -n "$_zm" ]] && glm_model="$_zm"
_dm="$(profile_get deepseek model)";    [[ -n "$_dm" ]] && deepseek_model="$_dm"
_mm="$(profile_get mimo model)";        [[ -n "$_mm" ]] && mimo_model="$_mm"
_xm="$(profile_get minimax model)";     [[ -n "$_xm" ]] && minimax_model="$_xm"
_qw="$(profile_get qwen model)";        [[ -n "$_qw" ]] && qwen_model="$_qw"
_dv="$(profile_get devstral model)";    [[ -n "$_dv" ]] && devstral_model="$_dv"
_lg="$(profile_get laguna model)";      [[ -n "$_lg" ]] && laguna_model="$_lg"
_kt="$(profile_get kat model)";         [[ -n "$_kt" ]] && kat_model="$_kt"
_nm="$(profile_get north model)";       [[ -n "$_nm" ]] && north_model="$_nm"
_vm="$(profile_get nemotron model)";    [[ -n "$_vm" ]] && nemotron_model="$_vm"
_k7="$(profile_get kimi27 model)";      [[ -n "$_k7" ]] && kimi27_model="$_k7"

codex_profile="$(profile_timeout codex)"
antigravity_profile="$(profile_timeout antigravity)"
gemini_pro_profile="$(profile_timeout gemini-pro)"
kimi_profile="$(profile_timeout kimi)"
glm_profile="$(profile_timeout glm)"
deepseek_profile="$(profile_timeout deepseek)"
mimo_profile="$(profile_timeout mimo)"
minimax_profile="$(profile_timeout minimax)"
qwen_profile="$(profile_timeout qwen)"
devstral_profile="$(profile_timeout devstral)"
laguna_profile="$(profile_timeout laguna)"
kat_profile="$(profile_timeout kat)"
north_profile="$(profile_timeout north)"
nemotron_profile="$(profile_timeout nemotron)"
kimi27_profile="$(profile_timeout kimi27)"
codex_timeout="${timeout_codex:-${timeout_s:-${codex_profile:-$(( timeout_s_default < 300 ? timeout_s_default : 300 ))}}}"
antigravity_timeout="${timeout_antigravity:-${timeout_s:-${antigravity_profile:-$timeout_s_default}}}"
# gemini-pro defaults to a longer budget than Flash: Pro's deeper reasoning
# routinely runs 2-3x longer than Flash on the same diff.
gemini_pro_timeout="${timeout_gemini_pro:-${timeout_s:-${gemini_pro_profile:-900}}}"
kimi_timeout="${timeout_kimi:-${timeout_s:-${kimi_profile:-$timeout_s_default}}}"
glm_timeout="${timeout_glm:-${timeout_s:-${glm_profile:-$timeout_s_default}}}"
# The other OpenRouter reviewers share the glm flag-less pattern: global
# --timeout, else profile timeout_s, else the 600s default. Per-reviewer
# tuning belongs in reviewer_profiles.json, not new CLI flags.
deepseek_timeout="${timeout_s:-${deepseek_profile:-$timeout_s_default}}"
mimo_timeout="${timeout_s:-${mimo_profile:-$timeout_s_default}}"
minimax_timeout="${timeout_s:-${minimax_profile:-$timeout_s_default}}"
qwen_timeout="${timeout_s:-${qwen_profile:-$timeout_s_default}}"
devstral_timeout="${timeout_s:-${devstral_profile:-$timeout_s_default}}"
laguna_timeout="${timeout_s:-${laguna_profile:-$timeout_s_default}}"
kat_timeout="${timeout_s:-${kat_profile:-$timeout_s_default}}"
north_timeout="${timeout_s:-${north_profile:-$timeout_s_default}}"
nemotron_timeout="${timeout_s:-${nemotron_profile:-$timeout_s_default}}"
kimi27_timeout="${timeout_s:-${kimi27_profile:-$timeout_s_default}}"

mkdir -p "$out"

# Validate the base ref up front. Without this, `git diff --quiet` below
# would return 128 on a missing ref — which bash treats as non-zero (same as
# "has diff") and the script would spawn reviewers against a broken
# comparison, wasting tokens and inviting hallucinated findings. Fail loud
# so the caller can retry with a valid --base instead of silently wrong.
if ! git rev-parse --verify --quiet "$base^{commit}" >/dev/null; then
  echo "invalid or unknown base ref: $base" >&2
  echo "  hint: try 'git fetch origin' or pass --base <ref> explicitly" >&2
  exit 1
fi

# Empty-diff short-circuit: burning 5 min + tens of thousands of tokens on a
# no-op branch produces nothing real (and sometimes invites hallucinated
# findings). Reviewers also can't diff what they can't see.
# (Base is validated above, so `git diff --quiet` here returns 0 (no diff) or
# 1 (has diff) cleanly, never 128.)
if git diff --quiet "$base"...HEAD; then
  printf '{"skipped": true, "reason": "no_diff_against_base", "base": "%s"}\n' "$base" > "$out/run.meta.json"
  echo "no diff against $base — skipping reviewers" >&2
  exit 0
fi

# Timeout shim: macOS has no `timeout` by default. `gtimeout` ships with
# coreutils (brew install coreutils). Pick whichever is on PATH — and when
# PATH doesn't have it, probe the standard homebrew install locations before
# giving up: background/cron shells often run with a PATH that lacks
# /opt/homebrew/bin, and on 2026-07-01 that silently ran EVERY reviewer
# unbounded (kimi went 42min against a 600s budget; only the never-read
# warning below knew why).
TIMEOUT_BIN=""
if command -v timeout >/dev/null 2>&1; then
  TIMEOUT_BIN="timeout"
elif command -v gtimeout >/dev/null 2>&1; then
  TIMEOUT_BIN="gtimeout"
else
  for _tb in /opt/homebrew/bin/gtimeout /usr/local/bin/gtimeout /opt/homebrew/bin/timeout /usr/local/bin/timeout; do
    [[ -x "$_tb" ]] && { TIMEOUT_BIN="$_tb"; break; }
  done
fi
# Fixture-test override: force the bash-watchdog fallback path even on
# machines that have coreutils. Production callers never set it.
[[ "${CROSS_REVIEW_FORCE_NO_TIMEOUT_BIN:-}" == "1" ]] && TIMEOUT_BIN=""

if [[ -z "$TIMEOUT_BIN" ]]; then
  echo "warning: neither 'timeout' nor 'gtimeout' is available (checked PATH + homebrew paths) — falling back to a bash watchdog for the ${timeout_s_default}s cutoff. Install coreutils (brew install coreutils) for the real thing." >&2
fi

run_with_timeout() {
  # Usage: run_with_timeout <secs> <cmd...>
  # Runs cmd with timeout if available; otherwise just exec.
  # -k 10: several reviewer CLIs (agy observed; wedged node CLIs generally)
  # ignore SIGTERM — without KILL escalation a wedged reviewer hangs the
  # subshell forever and the round never closes.
  local secs="$1"; shift
  if [[ -n "$TIMEOUT_BIN" ]]; then
    "$TIMEOUT_BIN" -k 10 "$secs" "$@"
    return
  fi
  # No coreutils: bash-watchdog fallback so a reviewer can never run
  # unbounded (issue #7 — a stalled auth prompt in a headless environment
  # used to hang the round forever and burn API budget). TERM at the
  # deadline, KILL 10s later, exit codes mapped to coreutils semantics
  # (124 timeout, 137 KILL escalation) so meta.timed_out and the retry
  # policy behave identically on both paths.
  # Job control (set -m) puts each background job in its own process group so
  # the watchdog can signal the whole reviewer process TREE, not just the
  # top-level PID — GNU timeout signals the child's group the same way, and
  # without this a reviewer's child process would survive the "timeout" and
  # keep burning CPU/API budget (codex P2, PR #21 pass 1).
  local had_m=0; [[ $- == *m* ]] && had_m=1
  set -m
  "$@" &
  local cmd_pid=$!
  ( sleep "$secs" && kill -TERM -- "-$cmd_pid" 2>/dev/null
    sleep 10 && kill -KILL -- "-$cmd_pid" 2>/dev/null ) &
  local wd_pid=$!
  [[ $had_m -eq 0 ]] && set +m
  local rc=0
  wait "$cmd_pid" 2>/dev/null || rc=$?
  if kill -0 "$wd_pid" 2>/dev/null; then
    # Command beat the deadline — group-kill the watchdog so its in-flight
    # `sleep $secs` dies with it instead of lingering (kimi, PR #21 pass 1).
    kill -TERM -- "-$wd_pid" 2>/dev/null || true
    wait "$wd_pid" 2>/dev/null || true
  fi
  # 128+SIGTERM → coreutils timeout exit. 137 (KILL escalation) passes
  # through UNMAPPED on purpose: coreutils `timeout -k` also exits 137 in
  # that case and every meta call-site classifies `124 || 137` as timed_out —
  # a convergent laguna+qwen "map 137→124" finding on pass 1 was falsified
  # against the call sites (see feedback_convergent_not_correct).
  [[ $rc -eq 143 ]] && rc=124
  return "$rc"
}

# retry_reviewer: run a reviewer function once, retry once on nonzero exit
# with a jittered 5-15s backoff. Applied only to antigravity/gemini-pro/kimi,
# which get flaky under concurrent or quick-succession runs (rate limits,
# auth handshake races). Codex has been reliable — don't wrap it.
#
# Timeout (rc=124, the convention used by both `timeout` and `gtimeout`) is
# explicitly NOT retried. A reviewer that just used its full budget of
# reasoning tokens will use the same budget on attempt 2 and time out again,
# which only doubles the cost. PR #1985 postmortem caught this — the cure
# for "needs more time" is a longer per-reviewer timeout, not a retry. True
# transient failures (rc=1, network errors) still retry.
#
# Exports CROSS_REVIEW_ATTEMPT so the reviewer fn can include it in its
# meta output. An exported env var (vs. bash dynamic scoping on a `local`)
# survives callees that declare their own `local attempt`, which is a
# reasonable future refactor that would otherwise silently break the
# retry telemetry.
retry_reviewer() {
  local fn="$1"
  local name="$2"
  export CROSS_REVIEW_ATTEMPT=1
  "$fn"
  local rc=$?
  # rc=3 (agy quota exhausted) is also not retried: the shared Individual
  # quota resets on a ~2-day cadence, so attempt 2 is guaranteed to hit the
  # same wall. No fallback by policy — the lap just drops out of this round.
  if [[ $rc -eq 3 ]]; then
    echo "$name: agy quota exhausted — not retrying, lap drops out of this round (reset ETA: see $out/agy.quota_exhausted)" >&2
    unset CROSS_REVIEW_ATTEMPT
    return "$rc"
  fi
  if [[ $rc -ne 0 && $rc -ne 124 && $rc -ne 137 ]]; then
    local backoff=$((5 + RANDOM % 11))
    echo "$name: attempt 1 failed (rc=$rc), retrying in ${backoff}s" >&2
    sleep "$backoff"
    export CROSS_REVIEW_ATTEMPT=2
    "$fn"
    rc=$?
    if [[ $rc -eq 0 ]]; then
      echo "$name: attempt 2 succeeded" >&2
    elif [[ $rc -eq 124 || $rc -eq 137 ]]; then
      echo "$name: attempt 2 timed out (rc=$rc)" >&2
    else
      echo "$name: attempt 2 also failed (rc=$rc)" >&2
    fi
  elif [[ $rc -eq 124 || $rc -eq 137 ]]; then
    # 137 = timeout's -k SIGKILL after an ignored SIGTERM (codex P2, PR #18
    # pass 3) — same retry semantics as 124: the budget was consumed and a
    # retry would just consume it again.
    echo "$name: attempt 1 timed out (rc=$rc), not retrying — bump the timeout if this recurs" >&2
  fi
  unset CROSS_REVIEW_ATTEMPT
  return "$rc"
}

# Helper: compute output bytes for a reviewer's primary stdout file. Used in
# meta.json so the runlog can distinguish "ran but produced nothing" (silent
# fail) from "ran and produced findings".
output_bytes_of() {
  local f="$1"
  if [[ -f "$f" ]]; then
    wc -c <"$f" | tr -d ' '
  else
    echo 0
  fi
}

# output_degenerate <file> — detect pathological repetition (a model stuck in
# a token loop: glm produced 145KB of "wait wait wait…" with exit 0 on PR #25
# pass 3, and the leaderboard counted it as a reliable run). Detector: gzip
# compression ratio. Calibration against 2026-07-02's real outputs: the
# degenerate file compressed 69:1; every healthy output — including codex's
# 182KB structured session logs — sat at 2:1–3:1. Threshold 15:1 leaves ~5×
# margin on both sides. Only meaningful past 512 bytes (header amortization);
# no gzip on PATH → not degenerate (detector is best-effort, never a gate on
# healthy runs).
output_degenerate() {
  local f="$1" raw comp
  command -v gzip >/dev/null 2>&1 || return 1
  raw=$(output_bytes_of "$f")
  [[ "$raw" -ge 512 ]] || return 1
  comp=$(gzip -c "$f" 2>/dev/null | wc -c | tr -d ' ')
  [[ "${comp:-0}" -gt 0 ]] || return 1
  [[ $(( comp * 15 )) -lt "$raw" ]]
}

# output_no_verdict <file> — detect a preamble-only response: rc=0 with a tiny
# output carrying neither a severity rank nor an explicit clean verdict. kimi
# delivered a 161-byte "I will now review…" preamble on PR #2620 (2026-07-03)
# that logged status ok — synthesis silently lost the vote while the
# leaderboard counted a reliable run. The gzip gate can't catch short
# non-repetitive text, so this is its < 512-byte complement.
# A legitimate clean review is often SHORT but always SAYS so ("no findings",
# "looks correct", severity headings…) — require one marker below 512 bytes;
# at ≥512 bytes assume real prose and stay out of the way. False positives are
# cheap: rc=5 gets one retry_reviewer swing and an honest failure_kind — and
# synthesis reads the raw stdout regardless, so a real finding phrased without
# any marker still reaches triage. The review prompt mandates Critical/High/
# Medium/Low ranking, so compliant reviews always carry a marker; markers are
# English-only, same as the review prompt and the current pool.
output_no_verdict() {
  local f="$1" raw
  raw=$(output_bytes_of "$f")
  [[ "$raw" -gt 0 && "$raw" -lt 512 ]] || return 1
  # NOTE: no empty alternatives — `(a |b |)` is invalid POSIX ERE and BSD
  # grep silently fails the whole pattern; use `( … )?` optional groups.
  ! grep -qiE 'critical|high|medium|low|no (significant |material )?(issues?|findings?|problems?|concerns?)|looks (good|correct|fine)|lgtm|approved|no regressions|\[P[0-9]\]' "$f"
}

# wall_over_budget <duration_s> <budget_s> — "true" when the wall-clock
# duration overran the enforced budget by >60s. That cannot happen when
# enforcement works (TERM/KILL lag ≤10s; curl fires at --max-time exactly)
# UNLESS the machine slept mid-run: gtimeout/curl timers freeze during system
# sleep while date +%s keeps counting (observed 2026-07-03 — codex logged
# 1024s against a 300s budget with rc=0 during pmset Dark Wake churn).
# Stamped into meta.json so analyze_runlog/leaderboard can discount the sample.
wall_over_budget() {
  local dur="$1" budget="$2"
  if [[ "$dur" -gt $(( budget + 60 )) ]]; then echo "true"; else echo "false"; fi
}

script_dir="$(cd "$(dirname "$0")" && pwd)"
prompt_file="$script_dir/../references/review_prompt.txt"

# Note: review_prompt is used by antigravity, gemini-pro, AND kimi (all three
# consume the `$review_prompt` variable below — see run_antigravity,
# run_gemini_pro, run_kimi). codex exec review --base <ref> applies codex's
# own built-in review instructions (which already rank findings with
# [P1]/[P2]/[P3] labels — equivalent to High/Medium/Low — and cover
# correctness, security, and semantic drift). Forcing our prompt into codex
# would require dropping --base and reconstructing the diff setup in text,
# which is more complexity for negligible gain.
#
# IMPORTANT: keep references/review_prompt.txt GENERIC. It is read verbatim
# and passed to multiple reviewers; PR-specific text in this file will cause
# every review across every PR to hallucinate the wrong context (this
# happened in the 2026-05-19 round when a stale PR-#2181 Village-rules
# prompt was left in this file — all 6 PRs reviewed in that round saw
# the reviewers confabulate Village-rules findings).
default_prompt="Review the changes on the current branch against '$base'. \
Focus on correctness, security, and whether the change achieves its stated intent. \
Flag concrete issues tied to file paths and line numbers where possible. \
Rank findings as Critical / High / Medium / Low. Skip pure style nits."

if [[ -f "$prompt_file" ]]; then
  review_prompt="$(cat "$prompt_file")"
  review_prompt="${review_prompt//\{\{BASE\}\}/$base}"
else
  review_prompt="$default_prompt"
fi

run_codex() {
  local start end rc
  start=$(date +%s)
  # codex exec review runs the built-in review prompt against the branch diff.
  # --full-auto: low-friction sandbox, workspace-write, no approval prompts.
  # IMPORTANT: --base and a positional [PROMPT] are mutually exclusive — if you
  # want a custom prompt, you must drop --base and put the base reference inside
  # the prompt itself.
  # NO --json: the JSONL stream omits the final review summary for `exec review`.
  # Plain-text mode flushes the review after the "codex" marker; we merge
  # stderr→stdout (2>&1) because codex writes progress trace AND the final
  # review to stderr while stdout is empty in this mode.
  #
  # Godot projects: Godot 4.x segfaults at startup (RotatedFileLogger
  # null-deref) when it cannot create user://logs, and codex's workspace-write
  # seatbelt denies ~/Library/Application Support/Godot. Whitelist that root so
  # codex can run `godot --headless` to verify runtime claims instead of
  # guessing (it guessed wrong on chain-racing PR #42). Verified empirically
  # via `codex sandbox macos` 2026-06-10 on codex-cli 0.128.0.
  local -a codex_cfg=()
  if [[ -f project.godot ]]; then
    codex_cfg+=(-c "sandbox_workspace_write.writable_roots=[\"$HOME/Library/Application Support/Godot\"]")
  fi
  run_with_timeout "$codex_timeout" codex exec review \
    --base "$base" \
    --full-auto \
    ${codex_cfg[@]+"${codex_cfg[@]}"} \
    >"$out/codex.stdout" 2>&1
  rc=$?
  end=$(date +%s)
  local timed_out="false"
  [[ $rc -eq 124 || $rc -eq 137 ]] && timed_out="true"  # 137 = timeout -k SIGKILL escalation (codex P2, PR #18 pass 3)
  local bytes
  bytes=$(output_bytes_of "$out/codex.stdout")
  local fk_json="null"
  if [[ $rc -eq 0 && "$bytes" -gt 0 ]] && output_degenerate "$out/codex.stdout"; then
    echo "codex: output is a degenerate repetition loop (gzip ratio >15:1) — classifying as failed" >&2
    fk_json='"degenerate_output"'
    rc=5
  elif [[ $rc -eq 0 && "$bytes" -gt 0 ]] && output_no_verdict "$out/codex.stdout"; then
    echo "codex: output is preamble-only (<512B, no severity or clean-verdict marker) — classifying as failed" >&2
    fk_json='"no_verdict_output"'
    rc=5
  fi
  printf '{"exit_code": %d, "duration_s": %d, "timed_out": %s, "output_bytes": %s, "attempt": 1, "timeout_budget_s": %d, "failure_kind": %s, "wall_over_budget": %s}\n' \
    "$rc" "$((end - start))" "$timed_out" "$bytes" "$codex_timeout" "$fk_json" "$(wall_over_budget "$((end - start))" "$codex_timeout")" >"$out/codex.meta.json"
  # IMPORTANT: return $rc so the caller's `wait "$pid"` sees the real exit code.
  # Previous version ended with `printf` whose success (exit 0) masked every
  # upstream reviewer failure.
  return "$rc"
}

# openrouter_key: resolve the OpenRouter API key. Env var wins; the key file
# (~/.config/openrouter/key, single line, chmod 600) is the persistent home.
# Prints the key and returns 0, or returns 1 when neither source exists —
# callers use it both as a getter and as an availability probe.
openrouter_key() {
  if [[ -n "${OPENROUTER_API_KEY:-}" ]]; then
    printf '%s' "$OPENROUTER_API_KEY"
    return 0
  fi
  local f="$HOME/.config/openrouter/key"
  if [[ -s "$f" ]]; then
    tr -d '[:space:]' <"$f"
    return 0
  fi
  return 1
}

# moonshot_key: same getter/probe contract as openrouter_key, for the direct
# Moonshot platform API (the kimi27 rotation seat and the kimi baseline share
# this billing rail). Env var wins; ~/.config/moonshot/key (single line,
# chmod 600) is the persistent home.
moonshot_key() {
  if [[ -n "${MOONSHOT_API_KEY:-}" ]]; then
    printf '%s' "$MOONSHOT_API_KEY"
    return 0
  fi
  local f="$HOME/.config/moonshot/key"
  if [[ -s "$f" ]]; then
    tr -d '[:space:]' <"$f"
    return 0
  fi
  return 1
}

# run_openrouter_reviewer: single-turn, diff-inline review via the OpenRouter
# chat-completions API. No agentic tools — the diff IS the input (same niche
# and prompt shape as run_kimi, and the same stdin/argv reasoning: the prompt
# body goes through a temp file + jq --rawfile, never argv). This is the shared
# runner for the whole OpenRouter rotation pool (glm, deepseek, mimo, minimax,
# qwen, devstral, laguna, kat, north, nemotron) — each an independent provider
# vote. It is NOT a fallback lane for the
# first-party reviewers (policy: no OR fallbacks for codex/gemini/kimi).
# Args:
#   $1 slug           (glm | deepseek | mimo | minimax | qwen | devstral |
#                      laguna | kat | north | nemotron | kimi27)
#   $2 model          (model id, e.g. z-ai/glm-5.2 or kimi-k2.7-code)
#   $3 timeout_budget (seconds)
#   $4 endpoint       (optional; default OpenRouter chat-completions. kimi27
#                      passes the direct Moonshot endpoint — the API is
#                      OpenAI-compatible, so the whole body is shared)
#   $5 cli label      (optional; default "openrouter" — selects the key
#                      source and is recorded verbatim in meta.json)
run_openrouter_reviewer() {
  local slug="$1" model="$2" timeout_budget="$3"
  local endpoint="${4:-https://openrouter.ai/api/v1/chat/completions}"
  local cli="${5:-openrouter}"
  local key
  if [[ "$cli" == "moonshot" ]]; then
    if ! key="$(moonshot_key)"; then
      echo "$slug: no Moonshot key (set MOONSHOT_API_KEY or ~/.config/moonshot/key)" >&2
      return 5
    fi
  elif ! key="$(openrouter_key)"; then
    echo "$slug: no OpenRouter key (set OPENROUTER_API_KEY or ~/.config/openrouter/key)" >&2
    return 5
  fi
  local start end rc
  start=$(date +%s)
  local diff_summary diff_full total_lines truncation_note truncated
  diff_summary="$(git diff --stat "$base"...HEAD 2>/dev/null | head -50 || true)"
  # Same line-based cap as run_kimi, for the same reasons (UTF-8 safety,
  # context budget). GLM 5.2 and the OpenRouter Gemini models all take 200k+
  # tokens; 8000 diff lines stays well inside that.
  local diff_line_cap=8000
  diff_full="$(git diff "$base"...HEAD 2>/dev/null | head -n "$diff_line_cap" || true)"
  total_lines="$(git diff "$base"...HEAD 2>/dev/null | wc -l | tr -d ' ')"
  if [[ "${total_lines:-0}" -gt "$diff_line_cap" ]]; then
    truncated=true
    truncation_note="

[WARNING: diff truncated to first $diff_line_cap of $total_lines lines. Your review will be INCOMPLETE — the tail of the patch is not shown. Note this limitation in your findings.]"
  else
    truncated=false
    truncation_note=""
  fi
  # Defuse a literal </diff> inside untrusted patch content (same
  # prompt-injection guard as run_kimi).
  diff_full="${diff_full//<\/diff>/< \/diff>}"
  local full_prompt
  full_prompt="$review_prompt

You have no file-reading or shell tools. Base your review ONLY on the diff below.${truncation_note}

Changed files (diff --stat against $base):
$diff_summary

Full diff:
<diff>
$diff_full
</diff>

Return your findings as prose, organized by severity (Critical / High / Medium / Low). Reference files and line numbers from the diff headers."

  local body_file="$out/${slug}.request.json" prompt_tmp
  prompt_tmp="$(mktemp)"
  printf '%s' "$full_prompt" >"$prompt_tmp"
  jq -n --rawfile p "$prompt_tmp" --arg m "$model" \
    '{model: $m, messages: [{role: "user", content: $p}], stream: false}' >"$body_file"
  rm -f "$prompt_tmp"

  local resp_file="$out/${slug}.response.json"
  # The Authorization header goes through a 0600 curl --config file, NOT argv:
  # argv is world-visible via `ps` for the duration of the call (same rationale
  # as the kimi stdin-prompt rule). Kimi cross-review finding, PR #18 pass 1.
  local auth_file="$out/.${slug}.curl-auth.$$"
  ( umask 077; printf 'header = "Authorization: Bearer %s"\n' "$key" >"$auth_file" )
  curl -sS --max-time "$timeout_budget" \
    --config "$auth_file" \
    -H "Content-Type: application/json" \
    -H "X-Title: cross-review" \
    -d @"$body_file" \
    "$endpoint" \
    >"$resp_file" 2>"$out/${slug}.stderr"
  rc=$?
  rm -f "$auth_file"
  # curl exits 28 on --max-time; normalize to 124 so meta.timed_out and the
  # retry policy treat it exactly like a coreutils timeout.
  [[ $rc -eq 28 ]] && rc=124
  if [[ $rc -eq 0 ]]; then
    local api_error
    api_error="$(jq -r '.error.message // empty' "$resp_file" 2>/dev/null)"
    if [[ -n "$api_error" ]]; then
      echo "$slug: $cli API error: $api_error" >>"$out/${slug}.stderr"
      rc=1
    else
      jq -r '.choices[0].message.content // empty' "$resp_file" >"$out/${slug}.stdout" 2>>"$out/${slug}.stderr" || rc=1
    fi
  fi
  end=$(date +%s)
  local timed_out="false"
  [[ $rc -eq 124 || $rc -eq 137 ]] && timed_out="true"  # 137 = timeout -k SIGKILL escalation (codex P2, PR #18 pass 3)
  local bytes
  bytes=$(output_bytes_of "$out/${slug}.stdout")
  # rc=0 with empty content is still a failure (filtered/refused/odd response)
  # — rc=5 keeps it out of any_ok and lets retry_reviewer take one more swing.
  [[ $rc -eq 0 && "$bytes" -eq 0 ]] && rc=5
  local fk_json="null"
  if [[ $rc -eq 0 && "$bytes" -gt 0 ]] && output_degenerate "$out/${slug}.stdout"; then
    echo "$slug: output is a degenerate repetition loop (gzip ratio >15:1) — classifying as failed" >&2
    fk_json='"degenerate_output"'
    rc=5
  elif [[ $rc -eq 0 && "$bytes" -gt 0 ]] && output_no_verdict "$out/${slug}.stdout"; then
    echo "$slug: output is preamble-only (<512B, no severity or clean-verdict marker) — classifying as failed" >&2
    fk_json='"no_verdict_output"'
    rc=5
  fi
  printf '{"exit_code": %d, "duration_s": %d, "timed_out": %s, "output_bytes": %s, "truncated": %s, "total_diff_lines": %d, "attempt": %d, "timeout_budget_s": %d, "model": "%s", "cli": "%s", "failure_kind": %s, "wall_over_budget": %s}\n' \
    "$rc" "$((end - start))" "$timed_out" "$bytes" "$truncated" "${total_lines:-0}" "${CROSS_REVIEW_ATTEMPT:-1}" "$timeout_budget" "$model" "$cli" "$fk_json" "$(wall_over_budget "$((end - start))" "$timeout_budget")" >"$out/${slug}.meta.json"
  return "$rc"
}

# run_agy_reviewer: shared body for the two Gemini-family laps. Both run on the
# `agy` (Antigravity) CLI; they differ only in slug, --model, and timeout.
# POLICY: no OpenRouter fallback for first-party laps — on quota/panic the lap
# fails honestly and roster rotation covers the gap on subsequent runs. Args:
#   $1 slug   (antigravity | gemini-pro)
#   $2 model  (exact `agy models` display name)
#   $3 timeout_budget (seconds)
run_agy_reviewer() {
  local slug="$1" model="$2" timeout_budget="$3"

  # Quota sentinel: the two laps share one Google "Individual quota" (resets on
  # a ~2-day cadence — it will NOT recover within this run). If the sibling lap
  # or an earlier attempt already hit the wall, don't burn another agy call.
  if [[ -f "$out/agy.quota_exhausted" ]]; then
    echo "$slug: agy quota already exhausted this run ($(cat "$out/agy.quota_exhausted" 2>/dev/null)) — skipping agy" >&2
    printf '{"exit_code": 3, "duration_s": 0, "timed_out": false, "output_bytes": 0, "attempt": %d, "timeout_budget_s": %d, "model": "%s", "cli": "agy", "failure_kind": "quota_exhausted", "agy_call_skipped": true}\n' \
      "${CROSS_REVIEW_ATTEMPT:-1}" "$timeout_budget" "$model" >"$out/${slug}.meta.json"
    return 3
  fi
  # Real flag surface (from `agy --help`, agy 1.0.9):
  #   -p / --print / --prompt        : non-interactive single-shot mode.
  #   --model <name>                 : exact display name from `agy models`.
  #                                    Unknown name => SILENT fallback to default
  #                                    (Flash). agy can't be made to error, so the
  #                                    profile/script strings must stay correct.
  #   --print-timeout <dur>          : in-CLI timeout (default 5m), Go duration
  #                                    syntax. Set just under the wrapper timeout
  #                                    so agy exits cleanly rather than being
  #                                    hard-killed mid-write (losing partial out).
  #   --sandbox                      : terminal restrictions enabled (closest
  #                                    thing to read-only; restricts the shell
  #                                    tool sandbox). We also prompt-instruct
  #                                    "no edits" as a backstop.
  #   --dangerously-skip-permissions : NOT used — a reviewer that auto-approves
  #                                    writes defeats the point.
  #   --log-file <path>              : pin agy's own log next to our outputs.
  # Auth: one-time `agy login` (or any interactive `agy -p`) in a TTY; OAuth
  # state persists. Empty stdout usually means auth expired — re-auth, don't
  # bump the timeout.
  local start end rc
  start=$(date +%s)
  local diff_summary
  diff_summary="$(git diff --stat "$base"...HEAD 2>/dev/null | head -50 || true)"
  local full_prompt
  full_prompt="$review_prompt

Changed files (diff --stat against $base):
$diff_summary

Use your file-reading tools to inspect the actual changes. Do NOT edit, write, or commit any files — this is a read-only review. Return your findings as prose, organized by severity."

  # argv guard (issue #7): Linux caps a single argv element at ~128KB
  # (MAX_ARG_STRLEN). The agy prompt is review_prompt + a 50-line diff-stat —
  # small by construction — but a large custom review_prompt.txt would E2BIG
  # the exec. agy has no documented stdin-prompt mode, so truncate loudly
  # instead of dying opaquely.
  if [[ ${#full_prompt} -gt 100000 ]]; then
    echo "$slug: prompt is ${#full_prompt} bytes — truncating to 100KB to stay under the argv limit (trim references/review_prompt.txt)" >&2
    full_prompt="${full_prompt:0:100000}

[NOTE: prompt truncated at 100KB by the argv-size guard — the tail of the instructions above may be missing.]"
  fi

  # In-CLI timeout runs 15s UNDER the wrapper budget so agy exits cleanly and
  # flushes partial output instead of being hard-killed by coreutils `timeout`
  # at the same instant. (The old code set them EQUAL — a race the comment
  # above claimed was already avoided.)
  local agy_internal_timeout
  if [[ "$timeout_budget" -gt 30 ]]; then
    agy_internal_timeout="$((timeout_budget - 15))s"
  else
    agy_internal_timeout="${timeout_budget}s"
  fi

  run_with_timeout "$timeout_budget" agy \
    --model "$model" \
    --sandbox \
    --print-timeout "$agy_internal_timeout" \
    --log-file "$out/${slug}.agy.log" \
    -p "$full_prompt" \
    >"$out/${slug}.stdout" 2>"$out/${slug}.stderr" </dev/null
  rc=$?
  end=$(date +%s)
  local timed_out="false"
  [[ $rc -eq 124 || $rc -eq 137 ]] && timed_out="true"  # 137 = timeout -k SIGKILL escalation (codex P2, PR #18 pass 3)
  local bytes
  bytes=$(output_bytes_of "$out/${slug}.stdout")

  # Classify the failure from agy's own log. On the observed failure modes
  # (2026-07-01) stdout AND stderr are both empty — the .agy.log is the only
  # place agy says what actually happened:
  #   quota_exhausted — "RESOURCE_EXHAUSTED (code 429): Individual quota
  #                     reached ... Resets in Nh" AND agy exits 0 with empty
  #                     stdout in ~5s. Without this check the run counted as
  #                     "ok" and synthesis silently lost the Gemini vote.
  #                     (Quota lines can also appear in the log of a run that
  #                     still produced output — intermittent 429s — so quota
  #                     only classifies when the run produced nothing.)
  #   agy_panic       — Go SIGSEGV in agy's RunCommandHandler (upstream bug,
  #                     seen on agy ≤1.0.15); exit 2, ~20-45s, empty output.
  #                     Flaky, so the agy retry is still worth one attempt.
  #   empty_output    — rc=0, 0 bytes, no quota line: most often expired
  #                     `agy login` auth.
  local failure_kind="" quota_resets_in=""
  local agy_log="$out/${slug}.agy.log"
  if [[ $rc -eq 0 && "$bytes" -eq 0 || $rc -ne 0 ]]; then
    # Quota is checked on ANY failure, not just empty output: a nonzero-exit
    # run with partial output whose real cause is quota must still classify
    # and write the sentinel (nemotron finding, PR #18 pass 1). Successful
    # runs (rc=0, bytes>0) never reach this block, so stray intermittent 429
    # lines in a good run's log can't misclassify it.
    if [[ -f "$agy_log" ]] && grep -q 'Individual quota reached' "$agy_log" 2>/dev/null; then
      failure_kind="quota_exhausted"
      quota_resets_in="$(grep -o 'Resets in [0-9hms]*' "$agy_log" 2>/dev/null | tail -1 | sed 's/Resets in //')"
      printf 'resets in %s (observed by %s at %s)\n' "${quota_resets_in:-unknown}" "$slug" "$(date '+%Y-%m-%dT%H:%M:%S')" >"$out/agy.quota_exhausted"
      rc=3
    elif [[ $rc -ne 0 && -f "$agy_log" ]] && grep -q 'panic: runtime error' "$agy_log" 2>/dev/null; then
      failure_kind="agy_panic"
    elif [[ $rc -eq 0 && "$bytes" -eq 0 ]]; then
      failure_kind="empty_output"
      rc=5
    fi
  elif output_degenerate "$out/${slug}.stdout"; then
    # rc=0 with content that is a repetition loop — same class as glm's
    # PR #25 pass-3 output; do not let it count as a reliable run.
    echo "$slug: output is a degenerate repetition loop (gzip ratio >15:1) — classifying as failed" >&2
    failure_kind="degenerate_output"
    rc=5
  elif output_no_verdict "$out/${slug}.stdout"; then
    # rc=0 with a tiny preamble and no verdict — kimi's PR #2620 class.
    echo "$slug: output is preamble-only (<512B, no severity or clean-verdict marker) — classifying as failed" >&2
    failure_kind="no_verdict_output"
    rc=5
  fi
  local fk_json="null" qr_json="null"
  [[ -n "$failure_kind" ]] && fk_json="\"$failure_kind\""
  [[ -n "$quota_resets_in" ]] && qr_json="\"$quota_resets_in\""
  printf '{"exit_code": %d, "duration_s": %d, "timed_out": %s, "output_bytes": %s, "attempt": %d, "timeout_budget_s": %d, "model": "%s", "cli": "agy", "failure_kind": %s, "quota_resets_in": %s, "wall_over_budget": %s}\n' \
    "$rc" "$((end - start))" "$timed_out" "$bytes" "${CROSS_REVIEW_ATTEMPT:-1}" "$timeout_budget" "$model" "$fk_json" "$qr_json" "$(wall_over_budget "$((end - start))" "$timeout_budget")" >"$out/${slug}.meta.json"
  # No fallback: a failed agy lap stays failed (failure_kind says why). Roster
  # rotation compensates across runs; the leaderboard's reliability signal
  # naturally down-weights a quota-dead lap until it recovers.
  return "$rc"
}

run_antigravity() {
  # Fast lap: agy on Gemini 3.5 Flash. Replaces the retired `gemini` CLI slot.
  run_agy_reviewer antigravity "$antigravity_model" "$antigravity_timeout"
}

run_gemini_pro() {
  # Deep lap: agy on Gemini 3.1 Pro. Migrated off the standalone `gemini` CLI in
  # the 2026-06-18 sunset; now shares the agy binary with antigravity.
  run_agy_reviewer gemini-pro "$gemini_pro_model" "$gemini_pro_timeout"
}

# The OpenRouter rotation pool — one thin wrapper per slug so retry_reviewer
# (which takes a function name) can drive each identically.
run_glm()      { run_openrouter_reviewer glm      "$glm_model"      "$glm_timeout"; }
run_deepseek() { run_openrouter_reviewer deepseek "$deepseek_model" "$deepseek_timeout"; }
run_mimo()     { run_openrouter_reviewer mimo     "$mimo_model"     "$mimo_timeout"; }
run_minimax()  { run_openrouter_reviewer minimax  "$minimax_model"  "$minimax_timeout"; }
run_qwen()     { run_openrouter_reviewer qwen     "$qwen_model"     "$qwen_timeout"; }
run_devstral() { run_openrouter_reviewer devstral "$devstral_model" "$devstral_timeout"; }
run_laguna()   { run_openrouter_reviewer laguna   "$laguna_model"   "$laguna_timeout"; }
run_kat()      { run_openrouter_reviewer kat      "$kat_model"      "$kat_timeout"; }
run_north()    { run_openrouter_reviewer north    "$north_model"    "$north_timeout"; }
run_nemotron() { run_openrouter_reviewer nemotron "$nemotron_model" "$nemotron_timeout"; }
# kimi27: same OpenAI-compatible single-turn body, direct Moonshot endpoint +
# key. cli label "moonshot" selects the key source and lands in meta.json.
run_kimi27()   { run_openrouter_reviewer kimi27   "$kimi27_model"   "$kimi27_timeout" \
                   "https://api.moonshot.ai/v1/chat/completions" moonshot; }

run_kimi() {
  local start end rc
  start=$(date +%s)
  # kimi (Moonshot's Kimi Code CLI) against Moonshot's OpenAI-compatible endpoint.
  #
  # We deliberately run kimi in single-turn, no-tools mode: pipe the full diff
  # inline and instruct the model not to call any tools. Why:
  #   (a) kimi-k2.5's thinking mode + multi-turn tool calls requires threading
  #       `reasoning_content` between turns, and the `openai_legacy` adapter
  #       doesn't preserve it — the second turn fails with "thinking is enabled
  #       but reasoning_content is missing".
  #   (b) Single-turn with thinking-on gives better review quality than
  #       multi-turn with thinking-off.
  #   (c) Code review is fundamentally a single-turn task: the diff IS the
  #       input. codex and antigravity already do the agentic file-roaming;
  #       kimi fills a different niche — deep reasoning on the diff as given.
  #
  # --plan: defense in depth (can't edit files even if it tried).
  # --print: non-interactive. Implies --yolo.
  # --quiet: final assistant message only (drops tool-trace noise).
  # Prompt is piped via stdin, NOT argv. Reasons:
  #   - Linux MAX_ARG_STRLEN is 128KB per argument; argv-based prompts would
  #     crash with E2BIG on any diff larger than that (macOS tolerates ~1MB,
  #     which hid the bug in smoke tests).
  #   - Putting the full diff in argv also exposes it via `ps` to other local
  #     users for the duration of the kimi run — a privacy regression vs.
  #     codex/antigravity which don't have this issue.
  # kimi reads stdin as the prompt when --print is set and no -p is given
  # (confirmed: `echo "..." | kimi --print --quiet` works).
  local diff_summary diff_full diff_line_cap truncation_note truncated
  diff_summary="$(git diff --stat "$base"...HEAD 2>/dev/null | head -50 || true)"
  # Line-based cap (not byte-based). head -c can split mid-codepoint and
  # produce invalid UTF-8; head -n respects line boundaries. 8000 lines keeps
  # us well under k2.5's 256K-token context even for verbose diffs.
  diff_line_cap=8000
  diff_full="$(git diff "$base"...HEAD 2>/dev/null | head -n "$diff_line_cap" || true)"
  local total_lines
  total_lines="$(git diff "$base"...HEAD 2>/dev/null | wc -l | tr -d ' ')"
  if [[ "${total_lines:-0}" -gt "$diff_line_cap" ]]; then
    truncated=true
    truncation_note="

[WARNING: diff truncated to first $diff_line_cap of $total_lines lines. Your review will be INCOMPLETE — the tail of the patch is not shown. Note this limitation in your findings.]"
  else
    truncated=false
    truncation_note=""
  fi
  # Wrap the diff in an XML-ish tag rather than a markdown fence. Diffs can
  # legitimately contain triple-backtick lines (e.g. doc changes that add a
  # fenced code block), which close the fence prematurely and corrupt the
  # prompt. <diff>...</diff> has no such collision surface.
  # Defuse a literal </diff> inside untrusted patch content so a malicious diff
  # can't close the fence early and inject instructions (prompt-injection "inj").
  diff_full="${diff_full//<\/diff>/< \/diff>}"
  local full_prompt
  full_prompt="$review_prompt

Do NOT use any file-reading or shell tools. Base your review ONLY on the diff below.${truncation_note}

Changed files (diff --stat against $base):
$diff_summary

Full diff:
<diff>
$diff_full
</diff>

Return your findings as prose, organized by severity (Critical / High / Medium / Low). Reference files and line numbers from the diff headers."

  # kimi-k2.5 thinking mode scales hard with diff size: ~84s p50 on small
  # diffs, but 32-43 min OBSERVED on ~4k-line diffs (2026-07-01, PR #18).
  # Scale the budget rather than truncate the input — quality first; the
  # speed-aware roster draw and incremental re-reviews keep big-diff rounds
  # rare. Empirical rate ≈500s per 1000 diff lines beyond the first 1000.
  local kimi_budget="$kimi_timeout"
  # Scale ONLY when the caller didn't set an explicit cap: --timeout-kimi or
  # --timeout means a smoke run / CI hard cap and must be honored verbatim
  # (codex P2, PR #18 pass 3). Ceiling division per north's pass-3 nit.
  if [[ -z "$timeout_kimi" && -z "$timeout_s" && "${total_lines:-0}" -gt 1000 ]]; then
    kimi_budget=$(( kimi_timeout + 500 * ( (total_lines - 1000 + 999) / 1000 ) ))
    [[ "$kimi_budget" -gt 3000 ]] && kimi_budget=3000
    echo "kimi: ${total_lines}-line diff — budget scaled ${kimi_timeout}s → ${kimi_budget}s" >&2
  fi
  run_with_timeout "$kimi_budget" kimi \
    --plan \
    --print \
    --quiet \
    >"$out/kimi.stdout" 2>"$out/kimi.stderr" <<<"$full_prompt"
  rc=$?
  end=$(date +%s)
  # truncated is reported in metadata so downstream synthesizers don't treat a
  # partial review as complete. Convergent finding from both codex and kimi
  # itself in pass 2 of cross-reviewing this skill.
  local timed_out="false"
  [[ $rc -eq 124 || $rc -eq 137 ]] && timed_out="true"  # 137 = timeout -k SIGKILL escalation (codex P2, PR #18 pass 3)
  local bytes
  bytes=$(output_bytes_of "$out/kimi.stdout")
  local fk_json="null"
  if [[ $rc -eq 0 && "$bytes" -gt 0 ]] && output_degenerate "$out/kimi.stdout"; then
    echo "kimi: output is a degenerate repetition loop (gzip ratio >15:1) — classifying as failed" >&2
    fk_json='"degenerate_output"'
    rc=5
  elif [[ $rc -eq 0 && "$bytes" -gt 0 ]] && output_no_verdict "$out/kimi.stdout"; then
    echo "kimi: output is preamble-only (<512B, no severity or clean-verdict marker) — classifying as failed" >&2
    fk_json='"no_verdict_output"'
    rc=5
  fi
  printf '{"exit_code": %d, "duration_s": %d, "timed_out": %s, "output_bytes": %s, "truncated": %s, "total_diff_lines": %d, "diff_line_cap": %d, "attempt": %d, "timeout_budget_s": %d, "failure_kind": %s, "wall_over_budget": %s}\n' \
    "$rc" "$((end - start))" "$timed_out" "$bytes" "$truncated" "${total_lines:-0}" "$diff_line_cap" "${CROSS_REVIEW_ATTEMPT:-1}" "$kimi_budget" "$fk_json" "$(wall_over_budget "$((end - start))" "$kimi_budget")" \
    >"$out/kimi.meta.json"
  return "$rc"
}

pids=()
ran=()

# Clean up background reviewers on interrupt. Without this, Ctrl+C on the
# orchestrator exits the parent shell but leaves codex/agy/kimi orphaned,
# burning tokens against APIs nobody is reading any more.
cleanup_pids() {
  [[ ${#pids[@]} -gt 0 ]] || return 0
  local p
  for p in "${pids[@]}"; do
    # Kill the subshell's children first (the `timeout`/CLI process); coreutils
    # `timeout` then signals the actual reviewer binary. Killing only the
    # subshell (as before) left codex/agy/kimi reparented and burning tokens on
    # a programmatic SIGTERM (Ctrl+C happened to work via the tty process group).
    pkill -P "$p" 2>/dev/null || true
    kill "$p" 2>/dev/null || true
  done
}
trap cleanup_pids EXIT INT TERM

IFS=',' read -ra raw_requested <<<"$reviewers"
# Dedup. Without this, `--reviewers codex,codex` spawns two processes writing
# to the same $out/codex.* files concurrently, producing interleaved garbage.
# Bash 3.2 (macOS default /bin/bash) lacks associative arrays — use a
# delimited string instead.
requested=()
seen=","
for r in "${raw_requested[@]}"; do
  # Strip surrounding whitespace — `--reviewers "codex, antigravity"` with a
  # space after the comma used to produce " antigravity" which failed to
  # match any case.
  r="${r#"${r%%[![:space:]]*}"}"
  r="${r%"${r##*[![:space:]]}"}"
  [[ -z "$r" ]] && continue
  [[ "$seen" == *",$r,"* ]] && continue
  seen="$seen$r,"
  requested+=("$r")
done

# Stagger spawns by 2s. Launching all reviewers at t=0 means concurrent
# auth handshakes and simultaneous first requests against shared upstream
# endpoints, which reliably flakes the Gemini-family and kimi clients.
# A small offset lets each initial handshake settle before the next starts.
# NOTE: antigravity + gemini-pro both hit Google via agy — the stagger matters
# more now that two reviewers share one provider, auth state, and rate limit.
stagger_s=2

for r in "${requested[@]}"; do
  case "$r" in
    codex)
      if command -v codex >/dev/null 2>&1; then
        [[ ${#pids[@]} -gt 0 ]] && sleep "$stagger_s"
        run_codex &
        pids+=($!)
        ran+=("codex")
      else
        echo "codex not installed — skipping" >&2
      fi
      ;;
    antigravity)
      if command -v agy >/dev/null 2>&1; then
        [[ ${#pids[@]} -gt 0 ]] && sleep "$stagger_s"
        retry_reviewer run_antigravity antigravity &
        pids+=($!)
        ran+=("antigravity")
      else
        echo "antigravity (agy CLI) not installed — skipping. Install: curl -fsSL https://antigravity.google/cli/install.sh | bash" >&2
      fi
      ;;
    gemini-pro)
      if command -v agy >/dev/null 2>&1; then
        [[ ${#pids[@]} -gt 0 ]] && sleep "$stagger_s"
        retry_reviewer run_gemini_pro gemini-pro &
        pids+=($!)
        ran+=("gemini-pro")
      else
        echo "gemini-pro (agy CLI on Gemini 3.1 Pro) not installed — skipping. Install: curl -fsSL https://antigravity.google/cli/install.sh | bash" >&2
      fi
      ;;
    kimi)
      if command -v kimi >/dev/null 2>&1; then
        [[ ${#pids[@]} -gt 0 ]] && sleep "$stagger_s"
        retry_reviewer run_kimi kimi &
        pids+=($!)
        ran+=("kimi")
      else
        echo "kimi not installed — skipping" >&2
      fi
      ;;
    glm|deepseek|mimo|minimax|qwen|devstral|laguna|kat|north|nemotron)
      if ! command -v curl >/dev/null 2>&1; then
        echo "$r: curl not available — skipping" >&2
      elif openrouter_key >/dev/null 2>&1; then
        [[ ${#pids[@]} -gt 0 ]] && sleep "$stagger_s"
        retry_reviewer "run_$r" "$r" &
        pids+=($!)
        ran+=("$r")
      else
        echo "$r (OpenRouter reviewer) unavailable — set OPENROUTER_API_KEY or put the key in ~/.config/openrouter/key. Skipping." >&2
      fi
      ;;
    kimi27)
      if ! command -v curl >/dev/null 2>&1; then
        echo "$r: curl not available — skipping" >&2
      elif moonshot_key >/dev/null 2>&1; then
        [[ ${#pids[@]} -gt 0 ]] && sleep "$stagger_s"
        retry_reviewer run_kimi27 kimi27 &
        pids+=($!)
        ran+=("kimi27")
      else
        echo "kimi27 (direct-Moonshot reviewer) unavailable — set MOONSHOT_API_KEY or put the key in ~/.config/moonshot/key. Skipping." >&2
      fi
      ;;
    *)
      echo "unknown reviewer: $r" >&2
      ;;
  esac
done

if [[ ${#pids[@]} -eq 0 ]]; then
  echo "no reviewers available or requested" >&2
  exit 1
fi

# Wait for each; track individual status. Since run_codex/run_antigravity/
# run_gemini_pro/run_kimi all `return "$rc"`, wait sees the real reviewer
# exit code.
any_ok=0
for i in "${!pids[@]}"; do
  pid="${pids[$i]}"
  name="${ran[$i]}"
  if wait "$pid"; then
    any_ok=1
    echo "$name: ok" >&2
  else
    # stderr file location varies per reviewer; codex merges stderr into
    # stdout. Point the user at the right file.
    case "$name" in
      codex)       echo "$name: failed (see $out/codex.stdout and $out/codex.meta.json)" >&2 ;;
      antigravity|gemini-pro)
        # stdout/stderr are usually EMPTY on agy failures — meta.json's
        # failure_kind and the .agy.log tail are where the answer lives.
        echo "$name: failed (check failure_kind in $out/$name.meta.json; agy's own log: $out/$name.agy.log)" >&2 ;;
      kimi)        echo "$name: failed (see $out/kimi.stderr and $out/kimi.meta.json)" >&2 ;;
      glm|deepseek|mimo|minimax|qwen|devstral|laguna|kat|north|nemotron|kimi27)
        echo "$name: failed (see $out/$name.stderr, $out/$name.response.json, $out/$name.meta.json)" >&2 ;;
      *)           echo "$name: failed (see $out/$name.* )" >&2 ;;
    esac
  fi
done

[[ "$any_ok" -eq 1 ]] || exit 1
exit 0
