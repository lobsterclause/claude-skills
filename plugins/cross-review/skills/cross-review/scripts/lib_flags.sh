#!/usr/bin/env bash
# lib_flags.sh — the fleet's feature flags, resolved in ONE place.
#
# WHY A SHARED LIB AND NOT AN `if` IN EACH SCRIPT.
#
# Three scripts have to agree about which reviewers exist: detect_reviewers.sh
# (reports availability), select_roster.sh (draws the round), run_reviewers.sh
# (spends the money). Every time that agreement lived in three places it
# drifted -- lib_path.sh exists because the PATH half drifted and detection
# reported codex available while the selector dropped it from every roster.
# A flag that switches a BASELINE on and off is the same shape of decision, so
# it gets the same treatment: one file, sourced by all three.
#
# Flags are read from the environment, never from a config file. They are meant
# to be set at a call site for a deliberate choice, and to be visible in the
# process that made it.
#
# ---------------------------------------------------------------------------
# CROSS_REVIEW_GLM_BASELINE   (default 1 -- ON)
#   The GLM Coding Plan seat (`glm-coding`, GLM 5.3 on Z.ai's coding endpoint)
#   is a FIXED BASELINE: every round includes it. Added 2026-09-07 when Gabriel
#   subscribed to the GLM Coding Lite quarterly plan; it replaces the kimi
#   baseline, whose CLI lane was burning ~$20/day of metered Moonshot spend
#   (see docs/investigation-cr-model-cost-2026-08-29.md). The Coding Plan is
#   flat-rate, so this seat costs the same whether it reviews once a day or
#   thirty times.
#
# CROSS_REVIEW_KIMI_BASELINE  (default 1 -- ON since 2026-11-18)
#   The kimi CLI baseline. It was OFF from 2026-09-07 to 2026-11-18 because the
#   lane ran on the metered Moonshot platform key. On 2026-11-18 the seat moved
#   to the Kimi Code subscription (cli_model_alias kimi-code/k3.1-pro, the
#   kimi CLI's managed provider), which is flat-rate like the GLM Coding Plan,
#   so it is a fixed baseline again alongside glm-coding.
#   `CROSS_REVIEW_KIMI_BASELINE=0` takes it back out.
#
# CROSS_REVIEW_OPENROUTER     (default 0 -- OFF)
#   The whole OpenRouter implementation: the 15-seat rotation pool (glm,
#   deepseek, mimo, minimax, qwen, devstral, laguna, kat, north, nemotron,
#   spark, seed, grok, longcat, inkling) AND the per-seat `or_fallback` rescue
#   lane for first-party reviewers. Disabled 2026-09-07 per Gabriel ("let's
#   disable the OR implementation for now"). Gating it HERE rather than
#   deleting the pool keeps one switch for both halves: a flag that turned off
#   the draw but left or_fallback live would still spend on OpenRouter, which
#   is the opposite of what "disabled" means. `CROSS_REVIEW_OPENROUTER=1`
#   restores every OpenRouter behaviour unchanged.
#
# Restoring the pre-2026-09-07 fleet (kimi then ran on the metered key; the
# seat's model pin lives in reviewer_profiles.json, not in a flag):
#   CROSS_REVIEW_KIMI_BASELINE=1 CROSS_REVIEW_GLM_BASELINE=0 \
#   CROSS_REVIEW_OPENROUTER=1 <command>
# ---------------------------------------------------------------------------

# cr_flag <ENV_NAME> <default 0|1> -> prints 0 or 1
#
# Unset means the default. A set-but-unparseable value is a HARD ERROR, not a
# silent fall back to the default: `CROSS_REVIEW_OPENROUTER=ture` must not read
# as "off, as it happens" in one script and "on" in another, and a typo'd flag
# that quietly does nothing is exactly the failure mode a flag is supposed to
# prevent.
cr_flag() {
  local name="$1" dflt="$2" raw="${!1:-}"
  if [[ -z "$raw" ]]; then printf '%s' "$dflt"; return 0; fi
  case "$(printf '%s' "$raw" | tr '[:upper:]' '[:lower:]')" in
    1|true|yes|on)   printf '1' ;;
    0|false|no|off)  printf '0' ;;
    *)
      echo "cross-review: $name must be 1|0 (also accepts true/false, yes/no, on/off) — got '$raw'" >&2
      return 2 ;;
  esac
}

# Predicates. Each returns 0 (shell true) when the feature is ON, and exits the
# calling script on a malformed flag -- the same fail-loud contract as
# cr_flag, hoisted so call sites read as plain conditionals.
cr_glm_baseline_on() {
  local v; v="$(cr_flag CROSS_REVIEW_GLM_BASELINE 1)" || exit 2
  [[ "$v" == 1 ]]
}
cr_kimi_baseline_on() {
  local v; v="$(cr_flag CROSS_REVIEW_KIMI_BASELINE 1)" || exit 2
  [[ "$v" == 1 ]]
}
cr_openrouter_on() {
  local v; v="$(cr_flag CROSS_REVIEW_OPENROUTER 0)" || exit 2
  [[ "$v" == 1 ]]
}

# cr_kimi_alias_ready: is the kimi seat's pinned model alias actually configured
# on this machine? The seat pins `kimi.cli_model_alias` (kimi-code/k3.1-pro, an
# alias `kimi login` writes for the Kimi Code subscription). A `kimi` binary on
# PATH says nothing about that: an install set up only for the Moonshot platform
# key, or one never logged in, passes a PATH check and then dies at dispatch
# with "LLM not set" -- a fixed baseline that contributes no review while
# preflight said it was fine (codex P2 + kimi Low, PR #202). So availability is
# "binary AND alias in the config". No pinned alias -> nothing to check.
# CROSS_REVIEW_KIMI_CONFIG overrides the config path (tests; non-default homes).
cr_kimi_alias_ready() {
  local profiles alias cfg
  profiles="${CROSS_REVIEW_PROFILES_FILE:-$(dirname "${BASH_SOURCE[0]}")/../references/reviewer_profiles.json}"
  alias="$(jq -r '.kimi.cli_model_alias // empty' "$profiles" 2>/dev/null)"
  [[ -z "$alias" ]] && return 0
  cfg="${CROSS_REVIEW_KIMI_CONFIG:-$HOME/.kimi/config.toml}"
  [[ -r "$cfg" ]] && grep -qF "[models.\"$alias\"]" "$cfg"
}

# cr_baseline_names: the round's fixed baselines, in dispatch order, space
# separated. codex is unconditional; the other seat is whichever baseline flags
# are on. Callers that enforce baselines (detect_reviewers.sh, select_roster.sh)
# read this so there is exactly one answer to "what is a baseline right now".
cr_baseline_names() {
  local names="codex"
  cr_glm_baseline_on  && names="$names glm-coding"
  cr_kimi_baseline_on && names="$names kimi"
  printf '%s' "$names"
}

# cr_flags_json: the resolved flag state, for meta.json / runlog stamping. A
# round's roster is only interpretable next to the flags that produced it --
# "no OpenRouter seats" means something different in a round where the pool was
# off than in one where the key was missing.
cr_flags_json() {
  printf '{"glm_baseline": %s, "kimi_baseline": %s, "openrouter": %s}' \
    "$(cr_glm_baseline_on  && echo true || echo false)" \
    "$(cr_kimi_baseline_on && echo true || echo false)" \
    "$(cr_openrouter_on    && echo true || echo false)"
}
