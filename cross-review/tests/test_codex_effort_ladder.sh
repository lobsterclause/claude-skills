#!/usr/bin/env bash
# test_codex_effort_ladder.sh — the codex reasoning-effort ladder ESCALATES ON
# FINDINGS (owner decision 2026-11-22): pass 1 inherits the configured level;
# pass 2+ runs at max(high, config) when the previous pass found a Critical or
# High issue, and inherits the config otherwise. It never runs below the config.
#
# History: until 2026-11-22 it stepped DOWN by pass number (pass 2 min(high,
# config), pass 3+ min(medium, config)). 2026-11-14 the owner set
# model_reasoning_effort = "medium" and that ladder inverted (medium / high /
# medium). The measurement then showed pass 3+ finding as much as pass 1
# (0.73 vs 0.75 findings/run), so stepping down had no basis.
#
# Also pins what is recorded in codex.meta.json (effort, effort_source,
# pass_context, prior_severity) — measure_codex_effort.sh reads them.
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
# PRIOR=<Critical|High|Medium|Low|none|-> seeds the previous pass's run dir with
# a findings.json holding one finding of that severity ("none" = empty list,
# "-" or unset = no findings file at all, i.e. unknown).
run() {
  local tag="$1" pass="$2"; shift 2
  CODEX_ARGV="$T/argv-$tag"; export CODEX_ARGV; rm -f "$CODEX_ARGV"
  local i prev="$T/prev-$tag/raw"
  rm -rf "$T/prev-$tag"; mkdir -p "$prev"
  case "${PRIOR:--}" in
    -) ;;
    none) printf '{"findings":[]}\n' >"$T/prev-$tag/findings.json" ;;
    drop) printf '{"findings":[{"severity":"High","disposition":"drop"},{"severity":"Critical","factcheck":{"verdict":"drop"}},{"severity":"Low"}]}\n' >"$T/prev-$tag/findings.scored.json"
          printf '{"findings":[{"severity":"Critical"}]}\n' >"$T/prev-$tag/findings.json" ;;
    *) printf '{"findings":[{"severity":"%s","file":"f.txt","line":1,"claim":"x"}]}\n' "$PRIOR" >"$T/prev-$tag/findings.json" ;;
  esac
  for ((i = 1; i < pass; i++)); do
    ( cd "$REPO" && bash "$S/check_repeat_pass.sh" --record --state-dir "$T/state-$tag/last_base" \
        --branch "pr-$tag" --base-sha "b$i" --head-sha "$(git rev-parse master)" --run-dir "$prev" >/dev/null 2>&1 )
  done
  ( cd "$REPO" && CROSS_REVIEW_STATE_DIR="$T/state-$tag" bash "$S/run_reviewers.sh" --base master \
      --out "$T/out-$tag" --reviewers codex --subject-id "pr-$tag" --allow-full-rereview "$@" >"$T/log-$tag" 2>&1 )
  EFF="$(grep -o 'model_reasoning_effort="[a-z]*"' "$CODEX_ARGV" 2>/dev/null | sed 's/.*="//; s/"//')"
  META="$T/out-$tag/codex.meta.json"
}
ladder() {  # ladder <config> -> "p1/p2/p3" of what codex was explicitly given ("inherit" when nothing)
  local c="$1" out="" p
  cfg "$c"
  for p in 1 2 3; do run "L${c}${PRIOR:-u}$p" "$p"; out="$out${out:+/}${EFF:-inherit}"; done
  echo "$out"
}

echo "── no step-down: a clean or unknown previous pass inherits the config ──"
for c in xhigh high medium low minimal; do
  assert_eq "$c, prior unknown -> inherit/inherit/inherit" "$(PRIOR=- ladder "$c")" "inherit/inherit/inherit"
done
assert_eq "medium, prior none -> inherit x3"   "$(PRIOR=none ladder medium)"   "inherit/inherit/inherit"
assert_eq "medium, prior Medium -> inherit x3" "$(PRIOR=Medium ladder medium)" "inherit/inherit/inherit"
assert_eq "medium, prior Low -> inherit x3"    "$(PRIOR=Low ladder medium)"    "inherit/inherit/inherit"

echo "── escalation: a Critical/High previous pass raises later passes to high ──"
assert_eq "medium, prior High -> inherit/high/high"     "$(PRIOR=High ladder medium)"     "inherit/high/high"
assert_eq "medium, prior Critical -> inherit/high/high" "$(PRIOR=Critical ladder medium)" "inherit/high/high"
assert_eq "low, prior High -> inherit/high/high"        "$(PRIOR=High ladder low)"        "inherit/high/high"
assert_eq "high config, prior High -> inherit (already high)"  "$(PRIOR=High ladder high)"  "inherit/inherit/inherit"
assert_eq "xhigh config, prior High -> inherit (never lowers)" "$(PRIOR=High ladder xhigh)" "inherit/inherit/inherit"
assert_eq "no config file, prior High -> inherit/high/high"    "$(PRIOR=High ladder -)"     "inherit/high/high"

echo "── dropped findings do not escalate ──"
cfg medium
PRIOR=drop run drp 2
assert_eq "dropped High/Critical in findings.scored.json are ignored (and it beats findings.json)" "$EFF" ""
assert_eq "…prior recorded as low" "$(jq -r .prior_severity "$META")" "low"

echo "── caller-supplied severity wins over files ──"
cfg medium
PRIOR=none run cs 2 --prev-severity High
assert_eq "--prev-severity High escalates" "$EFF" "high"
assert_eq "…source=caller" "$(jq -r .prior_severity_source "$META")" "caller"
PRIOR=High CROSS_REVIEW_PREV_SEVERITY=none run cse 2
assert_eq "env none beats a High file" "$EFF" ""

echo "── input validation runs before the ladder ──"
cfg medium
rc=0; ( cd "$REPO" && bash "$S/run_reviewers.sh" --base master --out "$T/out-badsev" --reviewers codex \
    --subject-id pr-badsev --allow-full-rereview --prev-severity bogus >"$T/log-badsev" 2>&1 ) || rc=$?
assert_eq "--prev-severity bogus exits 2" "$rc" "2"
PRIOR=High run badeff 2 --codex-effort turbo
grep -qi "turbo" "$T/log-badeff" && ok "unknown --codex-effort is warned about" || bad "no warning for turbo"
assert_eq "…and ignored, so the ladder still escalates" "$EFF" "high"

echo "── override wins absolutely, no clamping ──"
cfg medium
PRIOR=- run ov 2 --codex-effort xhigh
assert_eq "flag xhigh on pass 2 under a medium config" "$EFF" "xhigh"
assert_eq "meta source=override" "$(jq -r .effort_source "$META")" "override"
PRIOR=High CROSS_REVIEW_CODEX_EFFORT=low run ove 3
assert_eq "env low on pass 3 beats escalation" "$EFF" "low"
PRIOR=- run ovp 1 --codex-effort high
assert_eq "override on pass 1 is passed through" "$EFF" "high"
PRIOR=- run ovb 2 --codex-effort bogus
assert_eq "unknown override is dropped (config inherited)" "$EFF" ""
assert_eq "…and recorded as config" "$(jq -r .effort_source "$META")" "config"

echo "── pass 1 never escalates ──"
cfg medium
PRIOR=High run p1 1
assert_eq "pass 1 inherits even with a High findings file lying around" "$EFF" ""
assert_eq "pass 1 prior_severity is null" "$(jq -r .prior_severity "$META")" "null"

echo "── what ran is recorded ──"
cfg medium
PRIOR=- run m1 1
assert_eq "pass 1 records the inherited config level" "$(jq -r .effort "$META")" "medium"
assert_eq "pass 1 records its pass"                   "$(jq -r .pass_context "$META")" "1"
assert_eq "pass 1 source=config"                      "$(jq -r .effort_source "$META")" "config"
PRIOR=High run m2 2
assert_eq "escalated pass records high"       "$(jq -r .effort "$META")" "high"
assert_eq "escalated pass records pass 2"     "$(jq -r .pass_context "$META")" "2"
assert_eq "escalated source"                  "$(jq -r .effort_source "$META")" "escalated_on_findings"
assert_eq "escalated prior severity"          "$(jq -r .prior_severity "$META")" "high"
assert_eq "prior read from the recorded run dir" "$(jq -r .prior_severity_source "$META")" "run_dir"
PRIOR=- run m3 2
assert_eq "unknown prior recorded"            "$(jq -r .prior_severity "$META")" "unknown"
assert_eq "unknown prior keeps config level"  "$(jq -r .effort "$META")" "medium"
cfg -
PRIOR=- run m4 1
assert_eq "unknown config on pass 1 -> effort null" "$(jq -r .effort "$META")" "null"

echo "── a real round records its run dir for the next pass ──"
cfg medium
rm -rf "$T/state-chain"; CODEX_ARGV="$T/argv-chain"; export CODEX_ARGV
( cd "$REPO" && CROSS_REVIEW_STATE_DIR="$T/state-chain" bash "$S/run_reviewers.sh" --base master \
    --out "$T/chain/raw" --reviewers codex --subject-id pr-chain >/dev/null 2>&1 )
got="$(cd "$REPO" && bash "$S/check_repeat_pass.sh" --state-dir "$T/state-chain/last_base" --branch pr-chain --prev-run-dir)"
assert_eq "guard returns the previous --out" "$got" "$(cd "$T/chain/raw" && pwd)"

echo "── the measurement script reads the new field ──"
RL="$T/rl.jsonl"
printf '%s\n' '{"ts":"2026-11-20T00:00:00Z","pass":2,"verdict":"CLEAN","reviewers":{"codex":{"duration_s":5,"findings_total":0,"effort":"medium"}}}' \
              '{"ts":"2026-11-20T00:00:01Z","pass":2,"verdict":"CLEAN","reviewers":{"codex":{"duration_s":5,"findings_total":0}}}' >"$RL"
OUT="$(bash "$S/measure_codex_effort.sh" --runlog "$RL" --since 2026-11-01 2>&1)"
grep -q "pass 2: medium x1, unrecorded x1" <<<"$OUT" && ok "per-pass effort distribution, unrecorded counted apart" || bad "no effort line: $OUT"

echo; echo "══ $PASS passed, $FAIL failed ══"
[[ "$FAIL" -eq 0 ]]
