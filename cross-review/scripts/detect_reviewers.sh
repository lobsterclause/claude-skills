#!/usr/bin/env bash
# detect_reviewers.sh — report which review CLIs are available.
# Prints JSON to stdout:
#   {"codex": bool, "antigravity": bool, "gemini-pro": bool, "kimi": bool,
#    "glm-coding": bool, "glm": bool, "deepseek": bool, "mimo": bool, "minimax": bool, "qwen": bool,
#    "devstral": bool, "laguna": bool, "kat": bool,
#    "north": bool, "nemotron": bool, "spark": bool,
#    "seed": bool, "grok": bool, "longcat": bool, "inkling": bool,
#    "kimi27": bool,
#    "kimi3": bool, "openrouter": bool}
#
# As of the 2026-06-18 Gemini-CLI consumer sunset, BOTH Gemini-family reviewers
# run on Google's `agy` (Antigravity) CLI:
#   - antigravity → agy --model "Gemini 3.8 Flash (High)"   (fast lap)
#   - gemini-pro  → agy --model "Gemini 3.1 Pro (High)"     (deep lap)
# So their availability both track the single `agy` binary. The standalone
# `gemini` CLI is no longer used (it stopped serving consumer requests on
# 2026-06-18). codex and kimi are unchanged.
#
# The OpenRouter pool (glm, deepseek, mimo, minimax, qwen, devstral, laguna,
# kat, north, nemotron, spark, seed, grok, longcat, inkling)
# runs via the OpenRouter API — no CLI; all fifteen track the same condition:
# an OpenRouter key ($OPENROUTER_API_KEY or ~/.config/openrouter/key) + curl.
# `openrouter` reports that shared condition. NOTE: as of 2026-08-22 the
# first-party reviewers MAY fall back to OpenRouter on an account wall
# (per-seat `or_fallback` in reviewer_profiles.json), superseding the
# 2026-07-01 no-fallback rule. Detection is unaffected: this script reports
# the PRIMARY lane's availability, which is what a fallback is a fallback
# from. A lap with no or_fallback still just drops out of the round.

set -euo pipefail

# PATH fixups for ~/.local/bin (agy) and the nvm bin dir (codex, kimi) live in
# lib_path.sh so detection, selection and execution cannot drift apart. They
# did drift: this script resolved nvm and the other two did not, so it reported
# codex available while select_roster.sh dropped it from every roster. See
# lib_path.sh for the incident.
# shellcheck source=lib_path.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib_path.sh"
nvm_bin="$CROSS_REVIEW_NVM_BIN"

# Feature flags (which baseline is fixed, whether OpenRouter exists at all)
# live in lib_flags.sh for the same reason the PATH fixups live in lib_path.sh:
# detection, selection and execution have to answer identically or the fleet
# reports one roster and runs another. See lib_flags.sh for each flag.
# shellcheck source=lib_flags.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib_flags.sh"

has() {
  command -v "$1" >/dev/null 2>&1 && return 0
  # Antigravity's installer drops `agy` in $HOME/.local/bin, which is often not
  # on $PATH for non-interactive shells. Fall back to a direct check so we don't
  # false-negative when the user installed via the official script and just
  # hasn't restarted their shell.
  [[ -x "$HOME/.local/bin/$1" ]] && return 0
  # Same fallback for nvm-installed npm globals (codex, kimi).
  [[ -n "$nvm_bin" && -x "$nvm_bin/$1" ]]
}

codex=false
antigravity=false
gemini_pro=false
kimi=false
glm_coding=false
openrouter=false
kimi27=false
kimi3=false

has codex && codex=true
# Both Gemini reviewers ride the same agy binary — but `agy --model` silently
# falls back to Flash on an unrecognized model string. So only report gemini-pro
# (the Pro lap) available if `agy models` actually lists a Gemini 3.1 Pro entry.
# The probe MUST be bounded and cached: an unhealthy agy (quota/auth) can hang
# `agy models` for minutes and it ignores SIGTERM (codex P2, PR #18 pass 2).
# Shares select_roster.sh's 6h cache; with no timeout binary available the
# probe is skipped and Pro is assumed available (matches execution — the
# wrapper pins the exact model string either way).
if has agy; then
  antigravity=true
  models_cache="$HOME/.cross-review/cache/agy_models.txt"
  if [[ ! -s "$models_cache" || -n "$(find "$models_cache" -mmin +360 2>/dev/null)" ]]; then
    TIMEOUT_BIN=""
    command -v timeout  >/dev/null 2>&1 && TIMEOUT_BIN="timeout"
    if [[ -z "$TIMEOUT_BIN" ]] && command -v gtimeout >/dev/null 2>&1; then TIMEOUT_BIN="gtimeout"; fi
    if [[ -z "$TIMEOUT_BIN" ]]; then
      for _tb in /opt/homebrew/bin/gtimeout /usr/local/bin/gtimeout; do
        if [[ -x "$_tb" ]]; then TIMEOUT_BIN="$_tb"; break; fi
      done
    fi
    if [[ -n "$TIMEOUT_BIN" ]]; then
      mkdir -p "$(dirname "$models_cache")"
      models_tmp="$models_cache.tmp.$$"
      if "$TIMEOUT_BIN" -k 5 15 agy models >"$models_tmp" 2>/dev/null; then
        mv "$models_tmp" "$models_cache"
      else
        rm -f "$models_tmp"
      fi
    fi
  fi
  if [[ -s "$models_cache" ]]; then
    # agy 1.1.10 changed `agy models` output from display names
    # ("Gemini 3.1 Pro (High)") to slugs ("gemini-3.1-pro-high"), which
    # false-negatived gemini-pro out of every roster. Match either shape.
    if grep -Eqi 'gemini[ ._-]?3\.1[ ._-]?pro' "$models_cache"; then gemini_pro=true; fi
  else
    gemini_pro=true
  fi
fi
has kimi && kimi=true

# glm-coding: the GLM Coding Plan baseline. No CLI — it is a curl lane against
# Z.ai's coding endpoint — so availability is "curl + a key", exactly like the
# OpenRouter seats, and NOT gated on $OPENROUTER_API_KEY: this lane bypasses
# OpenRouter entirely, which is why the OpenRouter kill switch leaves it up.
# Reported false when CROSS_REVIEW_GLM_BASELINE=0, so the flag and the
# availability report agree (a seat that will not be dispatched must not be
# advertised as available).
if command -v curl >/dev/null 2>&1 && cr_glm_baseline_on; then
  if [[ -n "${ZAI_API_KEY:-}" || -n "${Z_AI_API_KEY:-}" || -s "$HOME/.config/zai/key" ]]; then
    glm_coding=true
  fi
fi

# OpenRouter key + curl → the whole OpenRouter reviewer pool lights up.
# ...unless CROSS_REVIEW_OPENROUTER is off (the default since 2026-09-07), in
# which case the pool does not exist for this run no matter what key is on
# disk. Reported here rather than only at dispatch so `detect_reviewers.sh`
# stays the honest answer to "who can review right now".
openrouter_key_value=""
if command -v curl >/dev/null 2>&1 && cr_openrouter_on; then
  if [[ -n "${OPENROUTER_API_KEY:-}" ]]; then
    openrouter=true
    openrouter_key_value="$OPENROUTER_API_KEY"
  elif [[ -s "$HOME/.config/openrouter/key" ]]; then
    openrouter=true
    openrouter_key_value="$(cat "$HOME/.config/openrouter/key" 2>/dev/null || true)"
  fi
fi

# Per-seat OpenRouter availability (#3587). The block above answers "is
# there a valid key" — it does NOT answer "can that key actually afford a
# review right now". OpenRouter reserves against a request's DECLARED
# max_tokens, not against what the reviewer will actually use, so an
# account with a few cents left passes any naive reachability probe and
# then hard-402s the instant a reviewer with a real max_tokens draws: a
# seat asking for 65536 tokens was refused ("You requested up to 65536
# tokens, but can only afford 62058") while a 16-token probe on the same
# key returned 200. The pool then degrades progressively and silently as
# the balance falls — reading as intermittent reviewer flakiness rather
# than one account running dry. GET /api/v1/credits (total_credits minus
# total_usage) is the fix; GET /api/v1/key is NOT usable here — it reports
# "limit": null with no derivable balance on an exhausted account, so a
# probe built on it would read this exact broke account as healthy.
#
# Seat-level, not pool-level: different seats declare different
# max_tokens (reviewer_profiles.json `.max_tokens_reserve`, paired with
# `.pricing.completion_per_m`), so only the seats a thin balance can't
# cover are downgraded — the rest of the pool still runs.
#
# FAILS SAFE: any problem with this probe (no jq, no key, curl error,
# timeout, unparseable response, a seat with no pricing/max_tokens_reserve
# on file) leaves every seat's availability exactly as computed above.
# This block can only turn a seat FALSE that presence checks called TRUE;
# it never invents availability presence checks did not already grant.
or_pool_seats="glm deepseek mimo minimax qwen devstral laguna kat north nemotron spark seed grok longcat inkling"
# shellcheck disable=SC2034  # each is read via the case in downgrade_or_seat below
glm=$openrouter; deepseek=$openrouter; mimo=$openrouter; minimax=$openrouter; qwen=$openrouter
devstral=$openrouter; laguna=$openrouter; kat=$openrouter; north=$openrouter; nemotron=$openrouter
spark=$openrouter; seed=$openrouter; grok=$openrouter; longcat=$openrouter; inkling=$openrouter

downgrade_or_seat() {
  # Bash 3.2 (macOS default) has no namerefs — a case statement over a
  # fixed, reviewed seat list is the portable way to assign-by-name.
  case "$1" in
    glm) glm=false ;;
    deepseek) deepseek=false ;;
    mimo) mimo=false ;;
    minimax) minimax=false ;;
    qwen) qwen=false ;;
    devstral) devstral=false ;;
    laguna) laguna=false ;;
    kat) kat=false ;;
    north) north=false ;;
    nemotron) nemotron=false ;;
    spark) spark=false ;;
    seed) seed=false ;;
    grok) grok=false ;;
    longcat) longcat=false ;;
    inkling) inkling=false ;;
  esac
}

if [[ "$openrouter" == true && -n "$openrouter_key_value" ]] && command -v jq >/dev/null 2>&1; then
  or_profiles_file="${CROSS_REVIEW_PROFILES_FILE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/references/reviewer_profiles.json}"
  OR_TIMEOUT_BIN=""
  command -v timeout  >/dev/null 2>&1 && OR_TIMEOUT_BIN="timeout"
  if [[ -z "$OR_TIMEOUT_BIN" ]] && command -v gtimeout >/dev/null 2>&1; then OR_TIMEOUT_BIN="gtimeout"; fi
  if [[ -z "$OR_TIMEOUT_BIN" ]]; then
    for _otb in /opt/homebrew/bin/gtimeout /usr/local/bin/gtimeout; do
      if [[ -x "$_otb" ]]; then OR_TIMEOUT_BIN="$_otb"; break; fi
    done
  fi
  or_credits_json=""
  if [[ -n "$OR_TIMEOUT_BIN" ]]; then
    or_credits_json="$("$OR_TIMEOUT_BIN" -k 3 10 curl -sS -m 8 \
      -H "Authorization: Bearer $openrouter_key_value" \
      "https://openrouter.ai/api/v1/credits" 2>/dev/null || true)"
  else
    # No bounded-timeout binary available at all — same posture as the agy
    # models probe above: skip rather than risk an unbounded hang on a sick
    # network, and leave every seat at its presence-checked value.
    or_credits_json=""
  fi
  or_balance_usd=""
  if [[ -n "$or_credits_json" ]] && jq -e '(.data // .) | (.total_credits != null and .total_usage != null)' \
       <<<"$or_credits_json" >/dev/null 2>&1; then
    or_balance_usd="$(jq -r '(.data // .) | ((.total_credits // 0) - (.total_usage // 0))' \
      <<<"$or_credits_json" 2>/dev/null || true)"
    # Guard against a malformed-but-truthy parse (e.g. a string field) —
    # only trust a bare number.
    [[ "$or_balance_usd" =~ ^-?[0-9]+(\.[0-9]+)?$ ]] || or_balance_usd=""
  fi
  if [[ -n "$or_balance_usd" ]]; then
    for _seat in $or_pool_seats; do
      _needed="$(jq -r --arg s "$_seat" '
        (.[$s].max_tokens_reserve // empty) as $mt
        | (.[$s].pricing.completion_per_m // empty) as $cpm
        | if ($mt == null or $cpm == null) then empty else ($mt * $cpm / 1000000) end
      ' "$or_profiles_file" 2>/dev/null || true)"
      if [[ -n "$_needed" ]] && awk -v a="$or_balance_usd" -v b="$_needed" 'BEGIN{exit !(a<b)}' 2>/dev/null; then
        downgrade_or_seat "$_seat"
        printf 'WARNING: OpenRouter seat "%s" reported unavailable — remaining balance $%s cannot cover its configured max_tokens reserve (needs ~$%s at %s'\''s completion rate). Top up the account or wait for balance to be checked again.\n' \
          "$_seat" "$or_balance_usd" "$_needed" "$_seat" >&2
      fi
    done
  fi
fi

# The direct-Moonshot seats are deliberately OUTSIDE the OpenRouter gate above:
# they ride Moonshot's own platform API on their own key and their own bill, so
# turning OpenRouter off must not silently take them with it. (Both are benched
# in select_roster.sh regardless — this reports availability, not the draw.)
if command -v curl >/dev/null 2>&1; then
  # kimi27 (k2.7-code rotation seat) rides the DIRECT Moonshot API — its own
  # key, independent of both the kimi CLI baseline and the OpenRouter pool.
  if [[ -n "${MOONSHOT_API_KEY:-}" || -s "$HOME/.config/moonshot/key" ]]; then
    kimi27=true
    # kimi3 (K3 rotation seat, added 2026-07-18) shares the exact same
    # direct-Moonshot key — same billing rail as kimi27 and the kimi baseline.
    kimi3=true
  fi
fi

# Baseline-CLI hang detection (#3587, case 2). A baseline CLI can be
# present, executable, and authenticated and STILL not be capable of
# serving a round: kimi's CLI was observed hanging 600-900s wall three
# times running, present-and-installed the whole time, which no install/
# PATH/key probe above can see. A live probe here is not worth it (the
# whole failure mode IS "does not return in reasonable time" — a bounded
# probe just reproduces the hang inside detection instead of inside the
# round). Reuse the signal the fleet already has instead: runlog.jsonl,
# via analyze_runlog.sh's --mode streak. A baseline-eligible reviewer
# (codex, kimi, glm-coding — the only three cr_baseline_names ever names)
# that timed out on each of its last BASELINE_HANG_STREAK_N attempts is
# downgraded to unavailable HERE, before the printf, so both the JSON this
# script reports and the fail-closed enforcement below see the honest
# state — CROSS_REVIEW_ALLOW_MISSING_BASELINE=1 becomes the deliberate way
# to run on a known-flaky baseline instead of it silently looking healthy.
#
# FAILS SAFE: no runlog, no jq, an unreadable analyze_runlog.sh, or any
# non-numeric output leaves the reviewer's presence-checked value
# untouched (see recent_consecutive_timeouts below) — this can only
# downgrade a seat presence checks already called available, never
# fabricate availability they did not grant.
BASELINE_HANG_STREAK_N=3
recent_consecutive_timeouts() {
  local r="$1" n="$2" script_dir out
  script_dir="$(dirname "${BASH_SOURCE[0]}")"
  [[ -f "$script_dir/analyze_runlog.sh" ]] || { echo 0; return; }
  command -v jq >/dev/null 2>&1 || { echo 0; return; }
  out="$(bash "$script_dir/analyze_runlog.sh" --mode streak --reviewer "$r" --streak-n "$n" 2>/dev/null)"
  [[ "$out" =~ ^[0-9]+$ ]] && echo "$out" || echo 0
}
for _bl in codex kimi glm-coding; do
  _streak="$(recent_consecutive_timeouts "$_bl" "$BASELINE_HANG_STREAK_N")"
  if [[ "$_streak" -ge "$BASELINE_HANG_STREAK_N" ]]; then
    case "$_bl" in
      codex)
        if [[ "$codex" == true ]]; then
          codex=false
          printf 'WARNING: codex reported unavailable — timed out on its last %s consecutive attempts per runlog.jsonl (present on PATH, but not currently completing reviews). Set CROSS_REVIEW_ALLOW_MISSING_BASELINE=1 to proceed on the degraded baseline anyway.\n' "$_streak" >&2
        fi
        ;;
      kimi)
        if [[ "$kimi" == true ]]; then
          kimi=false
          printf 'WARNING: kimi reported unavailable — timed out on its last %s consecutive attempts per runlog.jsonl (present on PATH, but not currently completing reviews). Set CROSS_REVIEW_ALLOW_MISSING_BASELINE=1 to proceed on the degraded baseline anyway.\n' "$_streak" >&2
        fi
        ;;
      glm-coding)
        if [[ "$glm_coding" == true ]]; then
          glm_coding=false
          printf 'WARNING: glm-coding reported unavailable — timed out on its last %s consecutive attempts per runlog.jsonl (key present, but not currently completing reviews). Set CROSS_REVIEW_ALLOW_MISSING_BASELINE=1 to proceed on the degraded baseline anyway.\n' "$_streak" >&2
        fi
        ;;
    esac
  fi
done

# WARNING: the format-string keys and the positional args below are coupled
# by POSITION ONLY — inserting a reviewer in one without the other silently
# shifts every later value (kimi+kat convergent nit, PR #29 pass 1). Keep the
# order: 4 named CLIs, $glm_coding, then each OR-pool seat by its OWN
# (possibly balance-downgraded, #3587) variable, $kimi27, $kimi3, $openrouter.
printf '{"codex": %s, "antigravity": %s, "gemini-pro": %s, "kimi": %s, "glm-coding": %s, "glm": %s, "deepseek": %s, "mimo": %s, "minimax": %s, "qwen": %s, "devstral": %s, "laguna": %s, "kat": %s, "north": %s, "nemotron": %s, "spark": %s, "seed": %s, "grok": %s, "longcat": %s, "inkling": %s, "kimi27": %s, "kimi3": %s, "openrouter": %s}\n' \
  "$codex" "$antigravity" "$gemini_pro" "$kimi" "$glm_coding" \
  "$glm" "$deepseek" "$mimo" "$minimax" "$qwen" "$devstral" "$laguna" "$kat" "$north" "$nemotron" "$spark" "$seed" "$grok" "$longcat" "$inkling" \
  "$kimi27" "$kimi3" "$openrouter"

# --- baseline enforcement ---------------------------------------------------
# WHICH seats are baselines is now flag-driven (lib_flags.sh): codex always,
# plus glm-coding (default) and/or kimi. The enforcement below is unchanged in
# kind -- a missing baseline still fails CLOSED -- it just asks
# cr_baseline_names what the baselines are instead of hardcoding the pair. The
# hazard the flags introduce is a fleet that reports "healthy" while reviewing
# with one seat, and that is precisely what this block exists to stop.
#
# codex and the flagged baseline are FIXED BASELINES, not rotating reviewers: every round is
# supposed to include both. Before 2026-08-14 a missing baseline simply reported
# `false` and the round proceeded a reviewer short while looking healthy — a
# missing verifier was indistinguishable from a passing verification. Nine
# rounds ran that way before anyone noticed.  Baselines now fail CLOSED.
#
# The JSON above is still printed first, so a caller that captures stdout gets
# its data either way; the EXIT CODE is the binding signal.
#
# Deliberately degraded runs are still allowed, but they have to be explicit:
#   CROSS_REVIEW_ALLOW_MISSING_BASELINE=1
# which makes it a visible choice at the call site instead of a silent default.
missing_baselines=""
for _b in $(cr_baseline_names); do
  case "$_b" in
    codex)      [[ "$codex" == true ]]      || missing_baselines="$missing_baselines codex" ;;
    glm-coding) [[ "$glm_coding" == true ]] || missing_baselines="$missing_baselines glm-coding" ;;
    kimi)       [[ "$kimi" == true ]]       || missing_baselines="$missing_baselines kimi" ;;
  esac
done
missing_baselines="${missing_baselines# }"

if [[ -n "$missing_baselines" ]]; then
  if [[ "${CROSS_REVIEW_ALLOW_MISSING_BASELINE:-0}" == "1" ]]; then
    printf 'WARNING: baseline reviewer(s) unavailable: %s — proceeding because CROSS_REVIEW_ALLOW_MISSING_BASELINE=1\n' \
      "$missing_baselines" >&2
  else
    printf 'FATAL: baseline reviewer(s) unavailable: %s\n' "$missing_baselines" >&2
    printf '  These are fixed baselines. A round without them is not a cross-review.\n' >&2
    printf '  Searched $PATH plus %s and %s\n' \
      "$HOME/.local/bin" "${nvm_bin:-<no nvm bin found>}" >&2
    case " $missing_baselines " in
      *" glm-coding "*)
        # glm-coding is a curl lane, not a binary: PATH is never its problem.
        printf '  glm-coding is a KEY, not an install: put the GLM Coding Plan key in\n' >&2
        printf '  ~/.config/zai/key (chmod 600) or export ZAI_API_KEY.\n' >&2
        printf '  To go back to the kimi baseline instead:\n' >&2
        printf '    CROSS_REVIEW_GLM_BASELINE=0 CROSS_REVIEW_KIMI_BASELINE=1\n' >&2 ;;
    esac
    printf '  Fix the install or PATH, or set CROSS_REVIEW_ALLOW_MISSING_BASELINE=1\n' >&2
    printf '  to run degraded on purpose.\n' >&2
    exit 1
  fi
fi
