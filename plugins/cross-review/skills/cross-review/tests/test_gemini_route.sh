#!/usr/bin/env bash
# test_gemini_route.sh — the gemini-pro ROUTER (model + level by pass and diff
# size), its override, and the one-Gemini-seat retirement of antigravity.
# Offline: agy is a PATH shim that records its argv; the profile is a fixture so
# the thresholds are pinned here, apart from the live profile's values (the live
# profile's SHAPE is pinned in the last section).
#
# Run:  bash tests/test_gemini_route.sh   ·   Exit: 0 all green, 1 any failure.
set -uo pipefail
SKILL="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
S="$SKILL/scripts"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
PASS=0; FAIL=0
ok()  { echo "  ok   $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL $1"; FAIL=$((FAIL + 1)); }
assert_eq() { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 (got: '$2' want: '$3')"; fi; }
command -v jq >/dev/null 2>&1 || { echo "  skip gemini route (jq unavailable)"; exit 0; }

mkdir -p "$T/bin" "$T/home"; export HOME="$T/home"
cat >"$T/bin/agy" <<'SHIM'
#!/bin/sh
if [ "$1" = "models" ]; then
  printf "gemini-4-argon-high\tGemini 4 Argon (High)\ngemini-4-hydrogen-xhigh\tGemini 4 Hydrogen (XHigh)\n"; exit 0; fi
for a in "$@"; do printf '%s\n' "$a"; done >"$AGY_ARGV"
printf "shim review: no findings\n"
SHIM
chmod +x "$T/bin/agy"
export PATH="$T/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
export CROSS_REVIEW_TOOL_MODE=off
unset OPENROUTER_API_KEY CROSS_REVIEW_GEMINI_PRO_ROUTE; export XDG_CONFIG_HOME="$T/xdg"

# Fixture profile: the live gemini-pro entry with the router values this test
# pins (small_diff_lines=5 so a 3-line and a 30-line diff straddle it).
FIX="$T/profiles.json"
jq '.["gemini-pro"].router.small_diff_lines = 5' "$SKILL/references/reviewer_profiles.json" >"$FIX"
export CROSS_REVIEW_PROFILES_FILE="$FIX"

mk_repo() {  # mk_repo <dir> <added-lines>
  mkdir -p "$1"
  ( cd "$1" && { git init -q -b master 2>/dev/null || git init -q; } && git config user.email t@t && git config user.name t
    printf 'a\n' >f.txt && git add f.txt && git commit -qm init && git checkout -qb feat
    seq 1 "$2" >>f.txt && git commit -qam change ) >/dev/null 2>&1
}
mk_repo "$T/small" 1      # diff is ~8 lines with headers: set per-case via threshold below
mk_repo "$T/big" 60

# run <repo> <tag> [extra run_reviewers args...] -> sets MODEL (the --model agy got),
# META (gemini-pro.meta.json path), ARGV (all agy argv).
run() {
  local repo="$1" tag="$2"; shift 2
  ARGV="$T/argv-$tag"; rm -f "$ARGV"
  ( cd "$repo" && AGY_ARGV="$ARGV" CROSS_REVIEW_STATE_DIR="$T/state-$tag" bash "$S/run_reviewers.sh" \
      --base master --out "$T/out-$tag" --reviewers gemini-pro --subject-id "pr-$tag" "$@" >"$T/log-$tag" 2>&1 )
  MODEL="$(awk 'p { print; exit } $0 == "--model" { p=1 }' "$ARGV" 2>/dev/null)"
  META="$T/out-$tag/gemini-pro.meta.json"
}
# Record N prior passes for pr-<tag> so the next round is pass N+1.
prior_passes() {
  local repo="$1" tag="$2" n="$3" i
  for ((i = 1; i <= n; i++)); do
    ( cd "$repo" && bash "$S/check_repeat_pass.sh" --record --state-dir "$T/state-$tag/last_base" \
        --branch "pr-$tag" --base-sha "base$i" --head-sha "$(git rev-parse master)" >/dev/null 2>&1 )
  done
}
field() { jq -r ".$1 // \"null\"" "$META" 2>/dev/null; }

echo "── router: pass 1 by diff size ──"
run "$T/big" p1big
assert_eq "pass 1, large diff -> Argon (High)" "$MODEL" "Gemini 4 Argon (High)"
assert_eq "meta records the route"        "$(field route)" "argon:high"
assert_eq "meta records pass_context"     "$(field pass_context)" "1"
case "$(field route_reason)" in pass1\(lines=*) ok "meta records the rule that fired ($(field route_reason))" ;; *) bad "route_reason: $(field route_reason)" ;; esac
[[ "$(field diff_lines)" =~ ^[0-9]+$ ]] && ok "meta records diff_lines" || bad "diff_lines: $(field diff_lines)"
assert_eq "meta records the model"        "$(field model)" "Gemini 4 Argon (High)"
# 1 added line + git diff headers is ~8 lines; pin the small branch with a
# threshold above that rather than depending on header arithmetic.
jq '.["gemini-pro"].router.small_diff_lines = 500' "$FIX" >"$T/p500.json"
CROSS_REVIEW_PROFILES_FILE="$T/p500.json" run "$T/small" p1small
assert_eq "pass 1, diff under small_diff_lines -> Hydrogen (XHigh)" "$MODEL" "Gemini 4 Hydrogen (XHigh)"
case "$(field route_reason)" in pass1_small*) ok "reason names pass1_small" ;; *) bad "reason: $(field route_reason)" ;; esac
jq '.["gemini-pro"].router.small_diff_lines = 0' "$FIX" >"$T/p0.json"
CROSS_REVIEW_PROFILES_FILE="$T/p0.json" run "$T/small" p1edge
assert_eq "threshold 0 -> nothing is small -> Argon (High)" "$MODEL" "Gemini 4 Argon (High)"

echo "── router: later passes ignore size ──"
prior_passes "$T/big" p2 1
run "$T/big" p2 --allow-full-rereview
assert_eq "pass 2 -> Hydrogen (High)" "$MODEL" "Gemini 4 Hydrogen (High)"
assert_eq "pass 2 context in meta" "$(field pass_context)" "2"
assert_eq "pass 2 reason" "$(field route_reason)" "pass2"
prior_passes "$T/big" p3 2
run "$T/big" p3 --allow-full-rereview
assert_eq "pass 3 -> Hydrogen (Medium)" "$MODEL" "Gemini 4 Hydrogen (Medium)"
prior_passes "$T/big" p5 4
run "$T/big" p5 --allow-full-rereview
assert_eq "pass 5 -> still Hydrogen (Medium), the floor" "$MODEL" "Gemini 4 Hydrogen (Medium)"
case "$MODEL" in *Low*) bad "a confirmation pass was routed to Low" ;; *) ok "no pass is ever routed to Low" ;; esac

echo "── router: no pass context (plain checkout, no subject id) ──"
ARGV="$T/argv-noctx"; rm -f "$ARGV"
( cd "$T/big" && AGY_ARGV="$ARGV" CROSS_REVIEW_STATE_DIR="$T/state-noctx" bash "$S/run_reviewers.sh" \
    --base master --out "$T/out-noctx" --reviewers gemini-pro >"$T/log-noctx" 2>&1 )
assert_eq "no pass context -> the pass-1 route" \
  "$(awk 'p { print; exit } $0 == "--model" { p=1 }' "$ARGV")" "Gemini 4 Argon (High)"

echo "── override: --gemini-pro-route / CROSS_REVIEW_GEMINI_PRO_ROUTE ──"
run "$T/big" ovf --gemini-pro-route hydrogen:low
assert_eq "flag selects the route (any listed route, even low)" "$MODEL" "Gemini 4 Hydrogen (Low)"
assert_eq "meta route"  "$(field route)" "hydrogen:low"
assert_eq "meta reason is override" "$(field route_reason)" "override"
CROSS_REVIEW_GEMINI_PRO_ROUTE=Argon:Medium run "$T/big" ove
assert_eq "env selects the route (case-insensitive)" "$MODEL" "Gemini 4 Argon (Medium)"
CROSS_REVIEW_GEMINI_PRO_ROUTE=argon:low run "$T/big" ovx --gemini-pro-route hydrogen:high
assert_eq "flag beats env" "$MODEL" "Gemini 4 Hydrogen (High)"
prior_passes "$T/big" ovp 2
run "$T/big" ovp --allow-full-rereview --gemini-pro-route argon:high
assert_eq "an override beats the pass rule" "$MODEL" "Gemini 4 Argon (High)"

echo "── pass context is recorded even when BOTH seats are pinned ──"
prior_passes "$T/big" both 2
CROSS_REVIEW_CODEX_EFFORT=low run "$T/big" both --allow-full-rereview --gemini-pro-route argon:high
assert_eq "gemini-pro meta carries pass 3 under an override" "$(field pass_context)" "3"

echo "── bad override fails closed ──"
# The last value is a jq-injection attempt: interpolated into the filter it
# would have returned "Gemini 4 Hydrogen (Low)" and been accepted as a route.
for bad_route in "argon:xhigh" "hydrogen" "carbon:high" "argon:high;rm" 'argon:high" | "Gemini 4 Hydrogen (Low)' ""; do
  [[ -z "$bad_route" ]] && continue
  run "$T/big" "bad$RANDOM" --gemini-pro-route "$bad_route"
  assert_eq "unknown route '$bad_route' -> profile default model" "$MODEL" "Gemini 4 Argon (High)"
  grep -q "ignoring unknown --gemini-pro-route" "$T/log-${ARGV##*argv-}" && ok "  warned for '$bad_route'" || bad "  no warning for '$bad_route'"
  case "$(field route_reason)" in default\(bad_override\)) ok "  reason is default(bad_override)" ;; *) bad "  reason: $(field route_reason)" ;; esac
done
prior_passes "$T/big" badp 2
run "$T/big" badp --allow-full-rereview --gemini-pro-route nonsense
assert_eq "a bad override does NOT fall through to the pass rule (stays on .model)" "$MODEL" "Gemini 4 Argon (High)"

echo "── availability: the route that will actually run must be listed ──"
export CROSS_REVIEW_AGY_MODELS_CACHE="$T/agy_models_avail.txt"
printf 'gemini-4-hydrogen-xhigh\tGemini 4 Hydrogen (XHigh)\n' >"$CROSS_REVIEW_AGY_MODELS_CACHE"
run "$T/big" avail
assert_eq "Hydrogen-only list: pass-1 big diff (argon:high) falls to a listed route" "$MODEL" "Gemini 4 Hydrogen (XHigh)"
case "$(field route_reason)" in *+unlisted_fallback) ok "reason records the fallback ($(field route_reason))" ;; *) bad "reason: $(field route_reason)" ;; esac
grep -q "not in .agy models" "$T/log-avail" && ok "  warned about the unlisted pick" || bad "  no warning"
printf 'gemini-9-other\tSome Other Model\n' >"$CROSS_REVIEW_AGY_MODELS_CACHE"
run "$T/big" availnone
assert_eq "no router route listed: keeps the pick" "$MODEL" "Gemini 4 Argon (High)"
case "$(field route_reason)" in *+unlisted_no_alternative) ok "reason records no alternative" ;; *) bad "reason: $(field route_reason)" ;; esac
printf 'gemini-4-argon-high\tGemini 4 Argon (High)\n' >"$CROSS_REVIEW_AGY_MODELS_CACHE"
run "$T/big" availok
assert_eq "listed pick is untouched" "$(field route_reason | sed 's/(.*//')" "pass1"
# a listed SUPERSTRING must not count as the picked model (boundary match)
printf 'gemini-4-argon-high-preview\tGemini 4 Argon Preview (High)\ngemini-4-hydrogen-xhigh\tGemini 4 Hydrogen (XHigh)\n' >"$CROSS_REVIEW_AGY_MODELS_CACHE"
run "$T/big" availsup
assert_eq "argon-high-preview listed (not argon-high): falls to the listed route" "$MODEL" "Gemini 4 Hydrogen (XHigh)"
# a cache past the 6h TTL is not authoritative -> no reroute
printf 'gemini-4-hydrogen-xhigh\tGemini 4 Hydrogen (XHigh)\n' >"$CROSS_REVIEW_AGY_MODELS_CACHE"
touch -t 202001010000 "$CROSS_REVIEW_AGY_MODELS_CACHE"
run "$T/big" availstale
assert_eq "stale cache is ignored: pick kept" "$MODEL" "Gemini 4 Argon (High)"
# not in the roster -> the availability block stays silent
printf '#!/bin/sh\nprintf "shim review: no findings\\n"\n' >"$T/bin/codex"; chmod +x "$T/bin/codex"
( cd "$T/big" && AGY_ARGV="$T/argv-x" CROSS_REVIEW_STATE_DIR="$T/state-nog" bash "$S/run_reviewers.sh" --base master --out "$T/out-nog" --reviewers codex >"$T/log-nog" 2>&1 )
grep -q "not in .agy models" "$T/log-nog" && bad "warned although gemini-pro is not in the roster" || ok "no availability warning when gemini-pro is not requested"
# roster gate admits only models the router can pick
. "$S/lib_agy_routes.sh"
printf 'gemini-4-argon-low\tGemini 4 Argon (Low)\n' >"$CROSS_REVIEW_AGY_MODELS_CACHE"
agy_routes_listed "$CROSS_REVIEW_AGY_MODELS_CACHE" "$FIX" && bad "roster gate admitted a router-unreachable model" || ok "roster gate rejects a list holding only router-unreachable models"
printf 'gemini-4-hydrogen-medium\tGemini 4 Hydrogen (Medium)\n' >"$CROSS_REVIEW_AGY_MODELS_CACHE"
agy_routes_listed "$CROSS_REVIEW_AGY_MODELS_CACHE" "$FIX" && ok "roster gate admits a router-reachable model" || bad "roster gate rejected hydrogen:medium"
rm -f "$CROSS_REVIEW_AGY_MODELS_CACHE"; unset CROSS_REVIEW_AGY_MODELS_CACHE

echo "── per-route timeout (optional profile map) ──"
jq '.["gemini-pro"].route_timeout_s = {"argon:high": 1234}' "$FIX" >"$T/pt.json"
CROSS_REVIEW_PROFILES_FILE="$T/pt.json" run "$T/big" rt
assert_eq "route_timeout_s sets the budget" "$(field timeout_budget_s)" "1234"
CROSS_REVIEW_PROFILES_FILE="$T/pt.json" run "$T/big" rt2 --timeout-gemini-pro 777
assert_eq "--timeout-gemini-pro still wins" "$(field timeout_budget_s)" "777"
run "$T/big" rt3
assert_eq "no route_timeout_s -> profile timeout_s (900)" "$(field timeout_budget_s)" "900"

echo "── profile without a router degrades to .model ──"
jq 'del(.["gemini-pro"].router)' "$FIX" >"$T/nr.json"
CROSS_REVIEW_PROFILES_FILE="$T/nr.json" run "$T/big" nr
assert_eq "no router -> .model" "$MODEL" "Gemini 4 Argon (High)"
assert_eq "reason says so" "$(field route_reason)" "default(no_router)"

echo "── antigravity is retired ──"
( cd "$T/big" && AGY_ARGV="$T/argv-ag" bash "$S/run_reviewers.sh" --base master --out "$T/out-ag" \
    --reviewers codex,antigravity >"$T/log-ag" 2>&1 ); rc=$?
assert_eq "--reviewers antigravity exits 2" "$rc" "2"
grep -q "retired.*gemini-pro" "$T/log-ag" && ok "the message points at gemini-pro" || bad "message: $(cat "$T/log-ag")"
[[ ! -e "$T/argv-ag" ]] && ok "agy was not run" || bad "agy ran for a retired seat"
for spelling in "codex, antigravity" "codex ,antigravity" " antigravity " "gemini-pro,antigravity "; do
  ( cd "$T/big" && AGY_ARGV="$T/argv-ag2" bash "$S/run_reviewers.sh" --base master --out "$T/out-ag2" \
      --reviewers "$spelling" >"$T/log-ag2" 2>&1 ); rc=$?
  assert_eq "whitespace spelling '$spelling' is refused too" "$rc" "2"
done
assert_eq "detect_reviewers no longer reports antigravity" \
  "$(bash "$S/detect_reviewers.sh" 2>/dev/null | jq 'has("antigravity")')" "false"
assert_eq "detect_reviewers reports gemini-pro from the routed models" \
  "$(bash "$S/detect_reviewers.sh" 2>/dev/null | jq '."gemini-pro"')" "true"
sel="$(bash "$S/select_roster.sh" 2>/dev/null)"
case ",$sel," in *,antigravity,*) bad "select_roster drew antigravity: $sel" ;; *) ok "select_roster never draws antigravity" ;; esac

echo "── availability follows the routed models ──"
# Only a Flash model listed -> no Argon/Hydrogen -> gemini-pro unavailable.
rm -rf "$T/home/.cross-review"; mkdir -p "$T/home/.cross-review/cache"
printf 'Gemini 3.8 Flash (High)\n' >"$T/home/.cross-review/cache/agy_models.txt"
assert_eq "no routed model listed -> gemini-pro false" \
  "$(bash "$S/detect_reviewers.sh" 2>/dev/null | jq '."gemini-pro"')" "false"
printf 'gemini-4-hydrogen-medium\tGemini 4 Hydrogen (Medium)\n' >"$T/home/.cross-review/cache/agy_models.txt"
assert_eq "any one routed model listed (slug shape) -> true" \
  "$(bash "$S/detect_reviewers.sh" 2>/dev/null | jq '."gemini-pro"')" "true"

echo "── live profile shape (the table, pinned) ──"
P="$SKILL/references/reviewer_profiles.json"
assert_eq "router.small_diff_lines" "$(jq '.["gemini-pro"].router.small_diff_lines' "$P")" "80"
assert_eq "router.pass1"       "$(jq -r '.["gemini-pro"].router.pass1' "$P")"       "argon:high"
assert_eq "router.pass1_small" "$(jq -r '.["gemini-pro"].router.pass1_small' "$P")" "hydrogen:xhigh"
assert_eq "router.pass2"       "$(jq -r '.["gemini-pro"].router.pass2' "$P")"       "hydrogen:high"
assert_eq "router.pass3_plus"  "$(jq -r '.["gemini-pro"].router.pass3_plus' "$P")"  "hydrogen:medium"
assert_eq ".model is the pass-1 route's model" "$(jq -r '.["gemini-pro"].model' "$P")" \
  "$(jq -r '.["gemini-pro"] as $g | $g.routes[$g.router.pass1]' "$P")"
assert_eq "every router target is an allowed route" \
  "$(jq -r '.["gemini-pro"] as $g | [$g.router.pass1,$g.router.pass1_small,$g.router.pass2,$g.router.pass3_plus] | map(. as $r | $g.routes | has($r)) | all' "$P")" "true"
assert_eq "no confirmation route is a low level" \
  "$(jq -r '.["gemini-pro"].router | [.pass2,.pass3_plus] | map(endswith(":low")) | any' "$P")" "false"
assert_eq "or_fallback has a slug for every routed model family" \
  "$(jq -r '.["gemini-pro"] as $g | [$g.routes | keys[] | split(":")[0]] | unique | map(. as $f | $g.or_fallback.route_models | has($f)) | all' "$P")" "true"
assert_eq "antigravity is marked retired"  "$(jq -r '.antigravity.retired' "$P")" "true"
assert_eq "gemini-pro notes carry the dated model-change note" \
  "$(jq -r '.["gemini-pro"].notes | contains("MODEL CHANGED 2026-11-14")' "$P")" "true"
assert_eq "no 3.1 Pro model left on the seat" \
  "$(jq -r '.["gemini-pro"] | [.model, (.routes|.[]), .or_fallback.model] | map(test("3\\.1")) | any' "$P")" "false"

echo
echo "══ $PASS passed, $FAIL failed ══"
[[ "$FAIL" -eq 0 ]]
