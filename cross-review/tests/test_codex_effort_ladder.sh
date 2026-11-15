#!/usr/bin/env bash
# test_codex_effort_ladder.sh — the codex reasoning-effort ladder is RELATIVE to
# the configured level: pass 2 = min(high, config), pass 3+ = min(medium,
# config), pass 1 inherits. It must never escalate above what the owner's
# ${CODEX_HOME:-~/.codex}/config.toml chose.
#
# Why: 2026-11-14 the owner set model_reasoning_effort = "medium" and the
# ladder, written against "xhigh" with a hardcoded pass-2 "high", inverted — the
# narrow fix-check pass ran ABOVE the first full review (banners: medium / high
# / medium / medium). Also pins that the effort actually run, and the pass, are
# recorded in codex.meta.json (measure_codex_effort.sh reads them).
#
# Offline: codex is a PATH shim that records its argv.
# Run:  bash tests/test_codex_effort_ladder.sh   ·   Exit: 0 all green, 1 any failure.
set -uo pipefail
SKILL="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
S="$SKILL/scripts"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
PASS=0; FAIL=0
ok()  { echo "  ok   $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL $1"; FAIL=$((FAIL + 1)); }
assert_eq() { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 (got: '$2' want: '$3')"; fi; }
command -v jq >/dev/null 2>&1 || { echo "  skip codex effort ladder (jq unavailable)"; exit 0; }

mkdir -p "$T/bin" "$T/home"; export HOME="$T/home"
cat >"$T/bin/codex" <<'SHIM'
#!/bin/sh
cat >/dev/null 2>&1 || true
for a in "$@"; do printf '%s\n' "$a"; done >"$CODEX_ARGV"
printf 'shim review: no findings\n'
SHIM
chmod +x "$T/bin/codex"
export PATH="$T/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
export CROSS_REVIEW_TOOL_MODE=off
unset OPENROUTER_API_KEY CROSS_REVIEW_CODEX_EFFORT; export XDG_CONFIG_HOME="$T/xdg"

REPO="$T/repo"; mkdir -p "$REPO"
( cd "$REPO" && { git init -q -b master 2>/dev/null || git init -q; } && git config user.email t@t && git config user.name t
  printf 'a\n' >f.txt && git add -A && git commit -qm init && git checkout -qb feat
  printf 'a\nb\n' >f.txt && git commit -qam change ) >/dev/null 2>&1

# cfg <level|-> writes a CODEX_HOME whose config sets the level ("-" = no file).
cfg() {
  rm -rf "$T/codexhome"; mkdir -p "$T/codexhome"; export CODEX_HOME="$T/codexhome"
  [[ "$1" == "-" ]] || printf 'model = "x"\nmodel_reasoning_effort = "%s"  # owner\n\n[profiles.deep]\nmodel_reasoning_effort = "xhigh"\n' "$1" >"$T/codexhome/config.toml"
}
# run <tag> <pass> [extra args] -> EFF (the -c model_reasoning_effort codex was given, "" if none), META
run() {
  local tag="$1" pass="$2"; shift 2
  CODEX_ARGV="$T/argv-$tag"; export CODEX_ARGV; rm -f "$CODEX_ARGV"
  local i
  for ((i = 1; i < pass; i++)); do
    ( cd "$REPO" && bash "$S/check_repeat_pass.sh" --record --state-dir "$T/state-$tag/last_base" \
        --branch "pr-$tag" --base-sha "b$i" --head-sha "h$i" >/dev/null 2>&1 )
  done
  ( cd "$REPO" && CROSS_REVIEW_STATE_DIR="$T/state-$tag" bash "$S/run_reviewers.sh" --base master \
      --out "$T/out-$tag" --reviewers codex --subject-id "pr-$tag" --allow-full-rereview "$@" >"$T/log-$tag" 2>&1 )
  EFF="$(grep -o 'model_reasoning_effort="[a-z]*"' "$CODEX_ARGV" 2>/dev/null | sed 's/.*="//; s/"//')"
  META="$T/out-$tag/codex.meta.json"
}
ladder() {  # ladder <config> -> "p1/p2/p3" of what codex was explicitly given ("inherit" when nothing)
  local c="$1" out="" p
  cfg "$c"
  for p in 1 2 3; do run "L${c}$p" "$p"; out="$out${out:+/}${EFF:-inherit}"; done
  echo "$out"
}

echo "── config xhigh: the original ladder ──"
assert_eq "xhigh -> inherit/high/medium" "$(ladder xhigh)" "inherit/high/medium"
echo "── config high ──"
assert_eq "high -> inherit/high/medium" "$(ladder high)" "inherit/high/medium"
echo "── config medium (the 2026-11-14 incident): never above pass 1 ──"
assert_eq "medium -> inherit/medium/medium" "$(ladder medium)" "inherit/medium/medium"
echo "── config low ──"
assert_eq "low -> inherit/low/low" "$(ladder low)" "inherit/low/low"
echo "── config minimal ──"
assert_eq "minimal -> inherit/minimal/minimal" "$(ladder minimal)" "inherit/minimal/minimal"

echo "── override wins absolutely, no clamping ──"
cfg medium
run ov 2 --codex-effort xhigh
assert_eq "flag xhigh on pass 2 under a medium config" "$EFF" "xhigh"
assert_eq "meta source=override" "$(jq -r .effort_source "$META")" "override"
CROSS_REVIEW_CODEX_EFFORT=low run ove 3
assert_eq "env low on pass 3" "$EFF" "low"
run ovp 1 --codex-effort high
assert_eq "override on pass 1 is passed through" "$EFF" "high"
run ovb 2 --codex-effort bogus
assert_eq "unknown override is dropped (config inherited, no ladder either)" "$EFF" ""
assert_eq "…and recorded as config" "$(jq -r .effort_source "$META")" "config"

echo "── unreadable / absent config -> the original fixed rungs ──"
assert_eq "no config file -> inherit/high/medium" "$(ladder -)" "inherit/high/medium"
cfg -; printf 'this is = not [valid toml\n' >"$T/codexhome/config.toml"
run bad1 2; assert_eq "garbage config, pass 2 -> high" "$EFF" "high"
cfg -; printf 'model_reasoning_effort = "ludicrous"\n' >"$T/codexhome/config.toml"
run bad2 3; assert_eq "unrecognised level, pass 3 -> medium" "$EFF" "medium"
cfg -; printf '[profiles.x]\nmodel_reasoning_effort = "low"\n' >"$T/codexhome/config.toml"
run bad3 2; assert_eq "a level inside a [table] is not the top-level config -> high" "$EFF" "high"

echo "── what ran is recorded ──"
cfg medium
run m1 1
assert_eq "pass 1 records the inherited config level" "$(jq -r .effort "$META")" "medium"
assert_eq "pass 1 records its pass"                   "$(jq -r .pass_context "$META")" "1"
assert_eq "pass 1 source=config"                      "$(jq -r .effort_source "$META")" "config"
cfg xhigh
run m2 2
assert_eq "pass 2 records high"   "$(jq -r .effort "$META")" "high"
assert_eq "pass 2 records pass 2" "$(jq -r .pass_context "$META")" "2"
assert_eq "pass 2 source=ladder"  "$(jq -r .effort_source "$META")" "ladder"
cfg medium
run m3 2
assert_eq "clamped rung records the clamped level" "$(jq -r .effort "$META")" "medium"
assert_eq "clamped rung source"                    "$(jq -r .effort_source "$META")" "ladder_clamped_to_config"
cfg -
run m4 1
assert_eq "unknown config on pass 1 -> effort null" "$(jq -r .effort "$META")" "null"

echo "── the measurement script reads the new field ──"
RL="$T/rl.jsonl"
printf '%s\n' '{"ts":"2026-11-20T00:00:00Z","pass":2,"verdict":"CLEAN","reviewers":{"codex":{"duration_s":5,"findings_total":0,"effort":"medium"}}}' \
              '{"ts":"2026-11-20T00:00:01Z","pass":2,"verdict":"CLEAN","reviewers":{"codex":{"duration_s":5,"findings_total":0}}}' >"$RL"
OUT="$(bash "$S/measure_codex_effort.sh" --runlog "$RL" --since 2026-11-01 2>&1)"
grep -q "pass 2: medium x1, unrecorded x1" <<<"$OUT" && ok "per-pass effort distribution, unrecorded counted apart" || bad "no effort line: $OUT"

echo; echo "══ $PASS passed, $FAIL failed ══"
[[ "$FAIL" -eq 0 ]]
