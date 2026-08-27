#!/usr/bin/env bash
# test_pricing_drift.sh — standalone TDD fixture for validate_or_models.sh's
# pricing-drift check (#124).
#
# WHY: reviewer_profiles.json pins a `pricing` snapshot per OpenRouter seat so
# the leaderboard can reason about cost. That snapshot silently rots when
# OpenRouter repriced a model upstream — #121 shipped several `pricing: null`
# seats with no way to backfill their numbers. This check compares the pinned
# `pricing.prompt_per_m`/`completion_per_m` against a cached OpenRouter
# catalog and WARNs when they drift, or INFOs when the profile has no pricing
# at all so the null seats get real numbers surfaced without anyone hand
# editing the profile.
#
# NO network, NO reviewer CLIs. Run:
#   bash tests/test_pricing_drift.sh
# Exit: 0 all green, 1 any failure.
#
# Portability: macOS bash 3.2 + ubuntu bash 5; needs jq.

set -uo pipefail

SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
S="$SKILL_DIR/scripts"
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
assert_not_contains() {
  if [[ "$2" == *"$3"* ]]; then bad "$1 (unexpectedly found '$3')"; else ok "$1"; fi
}

echo "── validate_or_models.sh --pricing drift against the OpenRouter catalog ──"

# Fixture profile: glm drifted, qwen exact, north free (0/0), deepseek null
# (the #121 case), plus a delisted slug for the pre-existing slug-check
# regression guard.
PROFILES="$T/profiles.json"
cat >"$PROFILES" <<'JSON'
{
  "glm":      { "cli": "openrouter", "model": "z-ai/glm-5.3",
                "pricing": { "prompt_per_m": 1.40, "completion_per_m": 4.40 } },
  "qwen":     { "cli": "openrouter", "model": "qwen/qwen3-coder-next",
                "pricing": { "prompt_per_m": 0.11, "completion_per_m": 0.80 } },
  "north":    { "cli": "openrouter", "model": "cohere/north-mini-code:free",
                "pricing": { "prompt_per_m": 0, "completion_per_m": 0 } },
  "deepseek": { "cli": "openrouter", "model": "deepseek/deepseek-v4-pro-0813",
                "pricing": null },
  "ghost":    { "cli": "openrouter", "model": "vendor/deleted-model-9" },
  "codex":    { "cli": "codex", "model": "n/a" }
}
JSON

# Fixture catalog: OpenRouter's /api/v1/models `data[]` shape — pricing is
# USD-per-token as strings. glm.prompt drifted to 1.60/M (0.0000016/token);
# glm.completion unchanged. qwen exact. north free (0). deepseek priced
# (0.30/1.20 per M -> 0.0000003/0.0000012 per token). No entry for
# vendor/deleted-model-9 (delisted).
CATALOG="$T/catalog.json"
cat >"$CATALOG" <<'JSON'
[
  { "id": "z-ai/glm-5.3", "pricing": { "prompt": "0.0000016", "completion": "0.0000044" } },
  { "id": "qwen/qwen3-coder-next", "pricing": { "prompt": "0.00000011", "completion": "0.0000008" } },
  { "id": "cohere/north-mini-code:free", "pricing": { "prompt": "0", "completion": "0" } },
  { "id": "deepseek/deepseek-v4-pro-0813", "pricing": { "prompt": "0.0000003", "completion": "0.0000012" } }
]
JSON

# Also stand up the plain-id cache the pre-existing slug check reads, so the
# regression guard exercises the real (unmodified) delisted-slug path.
CACHEHOME="$T/cachehome"
mkdir -p "$CACHEHOME/.cross-review/cache"
jq -r '.[].id' "$CATALOG" >"$CACHEHOME/.cross-review/cache/or_models.txt"

OUT="$(HOME="$CACHEHOME" OPENROUTER_API_KEY=test-key bash "$S/validate_or_models.sh" \
  --profiles "$PROFILES" --no-fetch --catalog "$CATALOG" 2>&1 >/dev/null)"

assert_contains "regression: the pre-existing delisted-slug WARN still fires" \
  "$OUT" "vendor/deleted-model-9"

assert_contains "glm pricing drift is WARNed with the prompt delta" \
  "$OUT" "prompt 1.40"
assert_contains "glm pricing drift shows the catalog value" "$OUT" "1.60"
GLM_LINE="$(printf '%s\n' "$OUT" | grep 'glm pricing drift')"
assert_not_contains "glm's unchanged completion is not named in the WARN" \
  "$GLM_LINE" "completion"

assert_eq "no drift WARN for an exact-match seat (qwen)" \
  "$(printf '%s' "$OUT" | grep -c 'qwen pricing drift')" "0"
assert_eq "no drift WARN for a free route pinned at 0 (north)" \
  "$(printf '%s' "$OUT" | grep -c 'north pricing drift')" "0"

assert_contains "deepseek (null pricing) gets an INFO with the catalog numbers" \
  "$OUT" "INFO: deepseek has no pricing in the profile"
assert_contains "deepseek INFO names the catalog prompt price" "$OUT" "0.30"
assert_contains "deepseek INFO names the catalog completion price" "$OUT" "1.20"

echo "── --pricing-json ──"
PJ="$(HOME="$CACHEHOME" OPENROUTER_API_KEY=test-key bash "$S/validate_or_models.sh" \
  --profiles "$PROFILES" --no-fetch --catalog "$CATALOG" --pricing-json 2>/dev/null)"
if printf '%s' "$PJ" | jq -e . >/dev/null 2>&1; then
  ok "--pricing-json emits parseable JSON"
else
  bad "--pricing-json emits parseable JSON (got: $PJ)"
fi
assert_eq "--pricing-json marks glm as drifted" \
  "$(printf '%s' "$PJ" | jq -r '.[] | select(.seat=="glm") | .drift')" "true"
assert_eq "--pricing-json marks qwen as not drifted" \
  "$(printf '%s' "$PJ" | jq -r '.[] | select(.seat=="qwen") | .drift')" "false"

echo "── exit codes ──"
HOME="$CACHEHOME" OPENROUTER_API_KEY=test-key bash "$S/validate_or_models.sh" \
  --profiles "$PROFILES" --no-fetch --catalog "$CATALOG" >/dev/null 2>&1
assert_eq "pricing drift alone does not change the exit code" "$?" "0"

HOME="$CACHEHOME" OPENROUTER_API_KEY=test-key bash "$S/validate_or_models.sh" \
  --profiles "$PROFILES" --no-fetch --catalog "$CATALOG" --strict-pricing >/dev/null 2>&1
assert_eq "--strict-pricing exits 1 when any seat drifted" "$?" "1"

# ── PR #125 review: both components drift → ", " join; comma-decimal locale;
#    a live fetch never overwrites --catalog; flags need values ──────────────
CAT2="$T/catalog2.json"
jq 'map(if .id == "z-ai/glm-5.3" then .pricing.completion = "0.0000050" else . end)' "$CATALOG" >"$CAT2"
OUT2="$(bash "$S/validate_or_models.sh" --profiles "$PROFILES" --catalog "$CAT2" --no-fetch 2>&1 >/dev/null)"
assert_contains "two drifted components are joined with a comma and a space" "$OUT2" "/M (catalog), completion 4.40"
if locale -a 2>/dev/null | grep -qiE '^de_DE\.utf-?8$'; then
  OUT3="$(LC_ALL=de_DE.UTF-8 bash "$S/validate_or_models.sh" --profiles "$PROFILES" --catalog "$CATALOG" --no-fetch 2>&1 >/dev/null)"
  assert_contains "comma-decimal locale still formats prices with a period" "$OUT3" "prompt 1.40"
  assert_not_contains "comma-decimal locale never prints a comma price" "$OUT3" "0,00"
else
  ok "comma-decimal locale still formats prices with a period (skipped: de_DE.UTF-8 not installed)"
fi
CAT_FIX="$T/catalog-fixture.json"; cp "$CATALOG" "$CAT_FIX"; before="$(cksum <"$CAT_FIX")"
FAKEBIN="$T/bin"; mkdir -p "$FAKEBIN"
printf '#!/bin/sh\nprintf %%s '"'"'{"data":[{"id":"z-ai/glm-5.3","pricing":{"prompt":"0.0000099","completion":"0.0000099"}}]}'"'"'\n' >"$FAKEBIN/curl"; chmod +x "$FAKEBIN/curl"
HOME="$T/home" PATH="$FAKEBIN:$PATH" OPENROUTER_API_KEY=sk-or-test bash "$S/validate_or_models.sh" --profiles "$PROFILES" --catalog "$CAT_FIX" --refresh >/dev/null 2>&1
assert_eq "a live fetch never overwrites the --catalog file" "$(cksum <"$CAT_FIX")" "$before"
assert_eq "a live fetch writes the cache catalog instead" "$(jq -r '.[0].id' "$T/home/.cross-review/cache/or_catalog.json" 2>/dev/null)" "z-ai/glm-5.3"
bash "$S/validate_or_models.sh" --profiles >/dev/null 2>&1; assert_eq "--profiles without a value exits 2" "$?" "2"
assert_contains "--help lists the pricing flags" "$(bash "$S/validate_or_models.sh" --help 2>&1)" "--strict-pricing"

echo
echo "PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]] || exit 1
exit 0
