#!/bin/bash
# workdir-required.test.sh — pins that every drain script refuses to run
# without an ABSOLUTE PR_DRAIN_WORKDIR, and works with one.
#
# Why: a cwd-relative `.pr-drain` default gave each call site its own state.
# The 2026-09-17 drain split its events 1/44 across two logs, an 08-19 retro
# stamp landed in the skill directory, and two lock callers in different
# directories never saw each other's locks.
#
# The absolute-path cases are the passing control: a script that refused
# EVERYTHING would pass the refusal checks, and these catch that. Red control
# (run 2026-09-24): pointed at the pre-change scripts via PROBE_S, 9 of 17
# checks fail, including "no cwd-relative state created".
#
# Usage: bash pr-drain/tests/workdir-required.test.sh   (exit 0 = all pass)
set -u
S=${PROBE_S:-"$(cd "$(dirname "$0")/../scripts" && pwd)"}
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
cd "$T" || exit 1
# Never let a probe (or a guard that fails open) touch the real cross-drain ledger.
export PR_DRAIN_CLAIMS_GLOBAL="$T/global-claims.jsonl"
export PR_DRAIN_DRY_RUN=1
fail=0
check() { # name expected_rc actual_rc
  if [ "$2" = "$3" ]; then echo "ok   $1 (rc=$3)"; else echo "FAIL $1 expected rc=$2 got rc=$3"; fail=1; fi
}

for s in queue.sh lock.sh retro.sh; do
  env -u PR_DRAIN_WORKDIR bash "$S/$s" status >/dev/null 2>&1; check "$s unset" 2 $?
  PR_DRAIN_WORKDIR=.pr-drain bash "$S/$s" status >/dev/null 2>&1; check "$s relative" 2 $?
done
env -u PR_DRAIN_WORKDIR bash "$S/claims.sh" stats >/dev/null 2>&1; check "claims.sh stats unset" 2 $?
PR_DRAIN_WORKDIR=rel bash "$S/claims.sh" log r High NOTED 1 "c" >/dev/null 2>&1; check "claims.sh log relative" 2 $?
env -u PR_DRAIN_WORKDIR bash "$S/claims.sh" prior nobody >/dev/null 2>&1; check "claims.sh prior unset (exempt)" 0 $?

# Passing controls: an absolute workdir works end to end.
W="$T/abs"
PR_DRAIN_WORKDIR="$W" bash "$S/queue.sh" append 1 QUEUED deadbeef "probe" >/dev/null 2>&1; check "queue.sh append absolute" 0 $?
[ -s "$W/events.jsonl" ]; check "events.jsonl written under absolute workdir" 0 $?
PR_DRAIN_WORKDIR="$W" PR_DRAIN_LOCK_PID=$$ bash "$S/lock.sh" acquire probe 5 >/dev/null 2>&1; check "lock.sh acquire absolute" 0 $?
[ -d "$W/locks/probe.lock" ]; check "lock dir under absolute workdir" 0 $?
PR_DRAIN_WORKDIR="$W" bash "$S/lock.sh" release probe >/dev/null 2>&1; check "lock.sh release absolute" 0 $?
PR_DRAIN_WORKDIR="$W" bash "$S/claims.sh" log r High NOTED 1 "c" >/dev/null 2>&1; check "claims.sh log absolute (dry-run)" 0 $?
PR_DRAIN_WORKDIR="$W" bash "$S/retro.sh" >/dev/null 2>&1; check "retro.sh absolute" 0 $?

# No refused call may have written anything relative to cwd.
[ ! -e "$T/.pr-drain" ] && [ ! -e "$T/rel" ]; check "no cwd-relative state created" 0 $?
exit $fail
