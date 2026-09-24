#!/bin/bash
# retro.sh — end-of-drain retrospective. Computes the numbers, prints the
# template with them filled in, and stamps a marker file the close-gate checks.
#
# The skill REQUIRES this before closing a drain's checklist issue: a
# retrospective that depends on someone remembering to ask for it is not a
# retrospective. The stats come from data the drain already wrote (events.jsonl,
# claims.jsonl), so running this costs nothing but honesty.
#
# Usage: retro.sh [--mark-done]
#   (no flag)    compute + print the retro template
#   --mark-done  stamp $WORKDIR/retro-done after the orchestrator has ANSWERED
#                the questions and applied/queued the skill edits — not before.
# Env: PR_DRAIN_WORKDIR (REQUIRED, absolute — e.g. $HOME/.pr-drain/<repo>-<issue>)
set -euo pipefail

# No default. With a cwd-relative `.pr-drain`, an 08-19 retro-done stamp
# landed in the skill's own directory, where no close-gate would ever find it,
# and the 09-17 drain's events split across two logs (see queue.sh).
WORKDIR="${PR_DRAIN_WORKDIR:-}"
case "$WORKDIR" in
  /*) ;;
  *) echo "retro.sh: set PR_DRAIN_WORKDIR to an absolute path, e.g. \$HOME/.pr-drain/<repo>-<issue> (got '$WORKDIR')" >&2; exit 2 ;;
esac
EVENTS="$WORKDIR/events.jsonl"
# claims.sh writes the cross-drain ledger at ~/.pr-drain/claims.jsonl (see
# SKILL.md step 3); a per-workdir claims.jsonl only exists if someone copied
# one there. Prefer the workdir copy, fall back to the global ledger —
# discovered 2026-08-19b when a drain with 9 logged claims retro'd as
# "no claims logged".
# Read BOTH ledgers: claims.sh writes the cross-drain one, but a per-workdir
# file can appear when a concurrent session logs there, and "prefer the
# workdir copy" then hid 47 logged claims behind 2 (2026-09-03). Merge them;
# the since-filter below scopes to this drain either way.
CLAIMS="$(mktemp)"
# `|| true`: a MISSING per-workdir claims.jsonl is the normal case, but under
# `set -o pipefail` cat's non-zero status propagated and `set -e` killed the
# retro outright — so this script died precisely when nothing was wrong
# (2026-09-19). The 2>/dev/null hid the message, not the exit code.
{ cat "$HOME/.pr-drain/claims.jsonl" "$WORKDIR/claims.jsonl" 2>/dev/null || true; } | sort -u > "$CLAIMS"

if [ "${1:-}" = "--mark-done" ]; then
  mkdir -p "$WORKDIR"
  date -u +%Y-%m-%dT%H:%M:%SZ > "$WORKDIR/retro-done"
  echo "retro marked done ($WORKDIR/retro-done)"
  exit 0
fi

echo "==================== pr-drain retrospective ===================="
echo

if [ -f "$EVENTS" ]; then
  echo "## Pipeline stats (events.jsonl)"
  jq -rs '
    "PRs touched: \(map(.pr) | unique | length)",
    "  merged:  \(map(select(.state == "MERGED") | .pr) | unique | length)",
    "  blocked: \(map(select(.state == "BLOCKED") | .pr) | unique | length)",
    "Transitions logged: \(length)"
  ' "$EVENTS"
  echo
  echo "Per-PR wall time (first event -> MERGED/BLOCKED), minutes:"
  jq -rs '
    group_by(.pr) | .[]
    | (map(select(.state == "MERGED" or .state == "BLOCKED")) | last) as $end
    | select($end != null)
    | ((($end.ts | fromdateiso8601) - (min_by(.ts).ts | fromdateiso8601)) / 60 | floor) as $m
    | "  #\(.[0].pr): \($m) min -> \($end.state)"
  ' "$EVENTS"
else
  echo "## Pipeline stats: NO events.jsonl — the drain ran without logging"
  echo "   transitions. That is itself a finding: either log them or delete"
  echo "   the event-log layer from the skill (see distillation below)."
fi
echo

echo "## Claim accuracy (claims.jsonl)"
if [ -f "$CLAIMS" ]; then
  # When reading the cross-drain ledger, scope to this drain: keep only
  # claims stamped at/after the drain's first logged event.
  SINCE=""
  [ -f "$EVENTS" ] && SINCE="$(jq -rs 'map(.ts) | min // ""' "$EVENTS")"
  jq -rs --arg since "$SINCE" '
    map(select($since == "" or .ts >= $since))
    | map(select(.severity == "Critical" or .severity == "High" or .severity == "P0" or .severity == "P1")) as $p
    | "P0/P1 claims: \($p | length)  applied: \($p | map(select(.verdict=="APPLIED")) | length)  refuted: \($p | map(select(.verdict=="REFUTED")) | length)  out-of-diff: \($p | map(select(.verdict=="OUT_OF_DIFF")) | length)",
    ($p | map(select(.verdict=="REFUTED")) | .[] | "  REFUTED [\(.reviewer)] #\(.pr): \(.claim) — \(.evidence)")
  ' "$CLAIMS"
else
  echo "no claims logged this drain — if reviewers made P0/P1 claims, the"
  echo "ledger was skipped; log them retroactively or note why there were none."
fi
echo
echo "================ answer these, then edit the skill ================"
echo
echo "1. BOTTLENECK: which stage actually gated throughput (review round, CI,"
echo "   fixes)? Does SKILL.md's pipelining section still describe reality?"
echo "2. NEW FAILURE CLASS: anything that happened that the skill has no rule"
echo "   for? -> add the rule AND write one memory file for it."
echo "3. FALSE-P0 PATTERNS: read the REFUTED list above. Any new misread"
echo "   pattern worth naming in the triage step?"
echo "4. DISTILLATION: which skill rule did NO work this drain? Three drains"
echo "   idle -> fold it down or cut it. Improvement includes deletion."
echo "5. REGRESSION: after editing SKILL.md, re-run the dry-run evals"
echo "   (evals/evals.json) and confirm the safety assertions still hold."
echo
echo "When the answers are applied (edits made or queued as issues), run:"
echo "  retro.sh --mark-done"
echo "The close-gate refuses to close the checklist issue without that stamp."
