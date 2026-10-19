#!/usr/bin/env bash
# test_append_lock.sh — every JSONL ledger writer takes the same portable lock.
#
# The writers used to take `flock` when it existed and fall back to a bare
# `>>` when it did not, on the theory that write() below PIPE_BUF is atomic.
# macOS ships no flock, its PIPE_BUF is 512 bytes, and runlog rows grew to
# ~7KB — so on the machine that actually runs the rounds, every append was
# unlocked and large enough to be split across write() calls. On 2026-10-08
# two rounds of the same PR appended in the same second and one row was spliced
# into the middle of the other, which took measure_codex_effort.sh down with it.
#
# The lock is now an atomic mkdir at "<ledger>.lock.d" on every platform, so
# the path these tests exercise is the path every machine runs. Each writer is
# checked against a HELD lock — a writer that ignores the lock writes at once,
# which is exactly the old behaviour, so these fail against it.
#
# Run:  bash tests/test_append_lock.sh   ·   Exit: 0 all green, 1 any failure.

set -uo pipefail

SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
S="$SKILL_DIR/scripts"
LIB_PATH="$S/lib_append_lock.sh"

PASS=0; FAIL=0
ok()  { echo "  ok   $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL $1"; FAIL=$((FAIL + 1)); }

if ! command -v jq >/dev/null 2>&1; then
  echo "  skip append lock (jq unavailable)"; exit 0
fi

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT

lines() { [[ -f "$1" ]] && wc -l <"$1" | tr -d ' ' || echo 0; }

# held_lock <label> <ledger> <cmd...>
# Takes the ledger's lock, starts the writer, and requires that it has written
# NOTHING a second later; then releases and requires exactly one new row.
held_lock() {
  local label="$1" ledger="$2"; shift 2
  local before; before="$(lines "$ledger")"
  mkdir "$ledger.lock.d"
  "$@" >/dev/null 2>"$T/held.err" &
  local pid=$!
  # Long enough for the slowest writer (append_runlog runs ~25 jq calls first)
  # to reach the lock; a writer still short of it would pass vacuously.
  sleep 2
  local during; during="$(lines "$ledger")"
  rmdir "$ledger.lock.d"
  wait "$pid"
  local rc=$? after; after="$(lines "$ledger")"
  if [[ "$during" == "$before" ]]; then ok "$label waits while the lock is held"
  else bad "$label wrote through a held lock ($before -> $during)"; fi
  if [[ $rc -eq 0 && "$after" -eq $((before + 1)) ]]; then ok "$label writes once the lock is released"
  else bad "$label after release (rc=$rc rows $before -> $after)"; cat "$T/held.err"; fi
  [[ ! -e "$ledger.lock.d" ]] && ok "$label leaves no lock behind" || bad "$label left its lock"
}

# ── the three writers ────────────────────────────────────────────────────────
RUN="$T/run1"; mkdir -p "$RUN/raw"
printf '{"exit_code":0,"duration_s":30,"timed_out":false,"output_bytes":500,"attempt":1,"timeout_budget_s":300,"cli":"codex","context_access":"agent"}\n' >"$RUN/raw/codex.meta.json"
RL="$T/runlog.jsonl"
append_runlog() {
  CROSS_REVIEW_RUNLOG="$RL" bash "$S/append_runlog.sh" \
    --run-dir "$RUN" --project test --base main --pr - --pass 1 \
    --verdict CLEAN --convergent 0 --top "-"
}
echo "── append_runlog.sh ──"
held_lock "append_runlog" "$RL" append_runlog

FE="$T/finding_events.jsonl"
append_event() {
  CROSS_REVIEW_FINDING_EVENTS="$FE" bash "$S/append_finding_event.sh" \
    --event proposed --finding-id f-abc --run-id r1
}
echo "── append_finding_event.sh ──"
held_lock "append_finding_event" "$FE" append_event

# Until import_runlog.sh moves onto the shared lock (#184) it takes flock on
# "<ledger>.lock" around its rename. Where flock exists the appenders queue
# on that same flock too — master's behaviour, restored — so an append never
# lands between the importer's lock and its rename.
#
# Where flock is missing (macOS), a perl stand-in supplies the two forms the
# lib and these tests use, so the cases run — and can fail — on every host,
# not only in CI. perl's flock() locks the open file description like
# util-linux flock(1) does, so the fd form holds for the caller's subshell.
echo "── flock compatibility with import_runlog.sh ──"
FLOCK_PATH="$PATH"
if ! command -v flock >/dev/null 2>&1; then
  FSHIM="$T/flock-shim"; mkdir -p "$FSHIM"
  cat >"$FSHIM/flock" <<'PERL'
#!/usr/bin/env perl
# flock -x [-w secs] <fd> | flock -x [-w secs] <file> <cmd...>
use strict; use Fcntl qw(:flock); use Time::HiRes qw(sleep time);
my $w;
while (@ARGV && $ARGV[0] =~ /^-/) { my $o = shift; $w = shift if $o eq '-w'; }
my $t = shift; my $fh;
if ($t =~ /^\d+$/) { open($fh, ">&=", $t) or exit 1 } else { open($fh, ">>", $t) or exit 1 }
my $end = defined $w ? time + $w : undef;
until (flock($fh, LOCK_EX | LOCK_NB)) { exit 1 if defined $end && time >= $end; sleep 0.05 }
if (@ARGV) { system(@ARGV); exit($? >> 8) }
exit 0;
PERL
  chmod +x "$FSHIM/flock"
  FLOCK_PATH="$FSHIM:$PATH"
fi

# Driven through the lib directly: append_runlog.sh runs ~25 jq calls before
# it reaches the lock, and a writer still short of the lock when the check
# runs would pass vacuously.
FL="$T/flock-compat.jsonl"; : >"$FL"
PATH="$FLOCK_PATH" flock -x "$FL.lock" sleep 3 &
holder=$!
sleep 0.5
PATH="$FLOCK_PATH" bash -c '. "$1"; append_line_locked "$2" "{\"ok\":1}"' _ "$LIB_PATH" "$FL" 2>"$T/flock-compat.err" &
writer=$!
sleep 1.5
during="$(lines "$FL")"
wait "$holder"; wait "$writer"
if [[ "$during" -eq 0 && "$(lines "$FL")" -eq 1 ]] && ! grep -q WARN "$T/flock-compat.err"; then
  ok "appends queue on import's flock while it is held"
else bad "append wrote through import's flock (during=$during after=$(lines "$FL")) $(cat "$T/flock-compat.err")"; fi

# The flock wait is bounded like the mkdir lock's, and well under the 60s
# stale age: waiting on it while holding the mkdir lock must never age that
# lock into looking dead. Past the bound the row is still written, with a
# WARN — never dropped, never a stall.
FL2="$T/flock-wedged.jsonl"; : >"$FL2"
PATH="$FLOCK_PATH" flock -x "$FL2.lock" sleep 12 &
holder=$!
sleep 0.5
start=$SECONDS
PATH="$FLOCK_PATH" CROSS_REVIEW_LOCK_WAIT_S=1 \
  bash -c '. "$1"; append_line_locked "$2" "{\"ok\":1}"' _ "$LIB_PATH" "$FL2" 2>"$T/flock-wedged.err"
rc=$?; took=$((SECONDS - start))
kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null
if [[ $rc -eq 0 && $took -lt 6 && "$(lines "$FL2")" -eq 1 ]] && grep -q WARN "$T/flock-wedged.err"; then
  ok "a wedged flock holder costs a bounded wait and a WARN, not the row"
else bad "wedged flock (rc=$rc took=${took}s rows=$(lines "$FL2")): $(cat "$T/flock-wedged.err")"; fi

# A shim mv that always fails, for the unrenameable-stale-lock case below.
SHIM="$T/failing-mv"; mkdir -p "$SHIM"
printf '#!/bin/sh\nexit 1\n' >"$SHIM/mv"; chmod +x "$SHIM/mv"

# A write that fails must not be reported as written.
echo "── a failed append is not reported as success ──"
RO="$T/readonly.jsonl"; : >"$RO"; chmod 444 "$RO"
if [[ -w "$RO" ]]; then
  echo "  skip read-only ledger cases (running as root)"
else
  for w in append_runlog append_event; do
    if [[ $w == append_runlog ]]; then
      CROSS_REVIEW_RUNLOG="$RO" bash "$S/append_runlog.sh" --run-dir "$RUN" --project test --base main \
        --pr - --pass 1 --verdict CLEAN --convergent 0 --top "-" >"$T/ro.out" 2>&1
    else
      CROSS_REVIEW_FINDING_EVENTS="$RO" bash "$S/append_finding_event.sh" \
        --event proposed --finding-id f-abc --run-id r1 >"$T/ro.out" 2>&1
    fi
    rc=$?
    if [[ $rc -ne 0 ]] && ! grep -q '^appended ' "$T/ro.out"; then ok "$w: a failed write exits non-zero (rc=$rc)"
    else bad "$w reported a failed write as success (rc=$rc): $(tail -1 "$T/ro.out")"; fi
  done
fi
chmod 644 "$RO"

# A writer copied somewhere without its lib (a partial sync, a fixture that
# copies only the scripts it names) used to drop the row and still print
# "appended runlog entry". It must fail, and say so.
echo "── a writer without lib_append_lock.sh ──"
LONE="$T/lone"; mkdir -p "$LONE"
cp "$S/append_runlog.sh" "$S/append_finding_event.sh" "$LONE/"
missing_lib() {
  local label="$1" ledger="$2"; shift 2
  "$@" >"$T/lone.out" 2>&1
  local rc=$?
  if [[ $rc -ne 0 ]] && ! grep -q '^appended ' "$T/lone.out"; then
    ok "$label fails loudly when its lib is missing (rc=$rc)"
  else bad "$label without its lib (rc=$rc): $(tail -1 "$T/lone.out")"; fi
}
missing_lib "append_runlog" "$T/lone-rl.jsonl" \
  env CROSS_REVIEW_RUNLOG="$T/lone-rl.jsonl" bash "$LONE/append_runlog.sh" \
    --run-dir "$RUN" --project test --base main --pr - --pass 1 --verdict CLEAN --convergent 0 --top "-"
missing_lib "append_finding_event" "$T/lone-fe.jsonl" \
  env CROSS_REVIEW_FINDING_EVENTS="$T/lone-fe.jsonl" bash "$LONE/append_finding_event.sh" \
    --event proposed --finding-id f-abc --run-id r1

# ── the lock itself ──────────────────────────────────────────────────────────
echo "── lib_append_lock.sh ──"
LIB="$S/lib_append_lock.sh"
if [[ ! -f "$LIB" ]]; then
  bad "lib_append_lock.sh exists"
else
  # A crashed writer's lock is reclaimed, not waited on forever. The append
  # itself takes milliseconds, so a lock a minute old has no live holder.
  L="$T/stale.jsonl"
  mkdir "$L.lock.d"; touch -t 202001010000 "$L.lock.d"
  start=$SECONDS
  bash -c '. "$1"; append_line_locked "$2" "{\"ok\":1}"' _ "$LIB" "$L" 2>"$T/stale.err"
  if [[ "$(lines "$L")" -eq 1 && $((SECONDS - start)) -lt 10 ]]; then ok "a stale lock is reclaimed promptly"
  else bad "stale lock (rows=$(lines "$L") took=$((SECONDS - start))s)"; cat "$T/stale.err"; fi
  [[ ! -e "$L.lock.d" ]] && ok "the reclaimed lock is released afterwards" || bad "stale lock left behind"

  # The stale age must be the documented minute, measured in seconds. `find
  # -mmin +1` only matches past ~120s on BSD AND GNU (it compares rounded
  # minutes), which is longer than the 75s wait cap — so a crashed writer's
  # lock was never reclaimed in time and every waiter appended unlocked. A
  # 2020 timestamp cannot see that; 90 seconds can.
  set_age() { python3 -c 'import os,sys,time; t=time.time()-int(sys.argv[2]); os.utime(sys.argv[1],(t,t))' "$1" "$2"; }
  if command -v python3 >/dev/null 2>&1; then
    L="$T/stale90.jsonl"; mkdir "$L.lock.d"; set_age "$L.lock.d" 90
    start=$SECONDS
    CROSS_REVIEW_LOCK_WAIT_S=5 bash -c '. "$1"; append_line_locked "$2" "{\"ok\":1}"' _ "$LIB" "$L" 2>"$T/stale90.err"
    if [[ "$(lines "$L")" -eq 1 ]] && ! grep -q WARN "$T/stale90.err" && [[ $((SECONDS - start)) -lt 4 ]]; then
      ok "a 90-second-old lock is stale (age measured in seconds, not rounded minutes)"
    else bad "90s-old lock not reclaimed: took=$((SECONDS - start))s $(cat "$T/stale90.err")"; fi

    # A 30-second-old lock is live: it must be waited on, not stolen.
    L="$T/live30.jsonl"; mkdir "$L.lock.d"; set_age "$L.lock.d" 30
    CROSS_REVIEW_LOCK_WAIT_S=1 bash -c '. "$1"; append_line_locked "$2" "{\"ok\":1}"' _ "$LIB" "$L" 2>"$T/live30.err"
    grep -q WARN "$T/live30.err" && [[ -d "$L.lock.d" ]] && ok "a 30-second-old lock is still treated as live" \
                                                     || bad "a live 30s lock was reclaimed"
    rmdir "$L.lock.d" 2>/dev/null
  else
    bad "python3 needed to age a lock precisely"
  fi

  # Staleness is AGE, never the recorded owner's liveness. Owner-liveness
  # was tried and races in ordinary use: a waiter reads owner H0, H0 releases
  # and exits, a new holder takes the lock, and the waiter finds H0 dead and
  # reclaims the NEW holder's live lock. So a fresh lock whose recorded owner
  # is dead must still be waited on — this is that race, made deterministic.
  bash -c 'exit 0' & dead=$!; wait "$dead"
  L="$T/fresh-dead-owner.jsonl"; mkdir "$L.lock.d"; echo "$dead" >"$L.lock.d/owner"
  CROSS_REVIEW_LOCK_WAIT_S=1 bash -c '. "$1"; append_line_locked "$2" "{\"ok\":1}"' _ "$LIB" "$L" 2>"$T/fresh-dead.err"
  if grep -q WARN "$T/fresh-dead.err" && [[ "$(cat "$L.lock.d/owner" 2>/dev/null)" == "$dead" ]]; then
    ok "a fresh lock is never reclaimed, even when its recorded owner has exited"
  else bad "a fresh lock was reclaimed because its owner had exited"; fi
  rm -rf "$L.lock.d"

  # Release removes only the caller's own lock — a holder whose lock was taken
  # over must not delete the new holder's.
  L="$T/not-mine.jsonl"; mkdir "$L.lock.d"; echo "$$" >"$L.lock.d/owner"
  bash -c '. "$1"; append_lock_release "$2"' _ "$LIB" "$L"
  [[ -d "$L.lock.d" ]] && ok "release leaves a lock owned by another process alone" \
                       || bad "release removed someone else's lock"

  # Every successful acquire records its owner.
  L="$T/records.jsonl"
  bash -c '. "$1"; append_lock_acquire "$2" && cat "$2.lock.d/owner" && echo "self=$$"' _ "$LIB" "$L" >"$T/records.out"
  if [[ "$(sed -n 1p "$T/records.out")" == "$(sed -n 2p "$T/records.out" | sed 's/self=//')" ]]; then
    ok "acquire records the holder's pid as owner"
  else bad "owner record: $(tr '\n' ' ' <"$T/records.out")"; fi

  # A stale lock that cannot be renamed away (here: mv itself fails) must
  # count toward the cap, not spin at 100% CPU forever.
  D="$T/unrenameable"; mkdir -p "$D/x.jsonl.lock.d"; : >"$D/x.jsonl"; touch -t 202001010000 "$D/x.jsonl.lock.d"
  PATH="$SHIM:$PATH" CROSS_REVIEW_LOCK_WAIT_S=1 \
    bash -c '. "$1"; append_line_locked "$2" "{\"ok\":1}"' _ "$LIB" "$D/x.jsonl" 2>/dev/null &
  pid=$!; waited=0
  while kill -0 "$pid" 2>/dev/null && [[ $waited -lt 20 ]]; do sleep 0.5; waited=$((waited + 1)); done
  if kill -0 "$pid" 2>/dev/null; then kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
    bad "an unrenameable stale lock spins past the wait cap"
  else wait "$pid"; ok "an unrenameable stale lock still ends at the wait cap"; fi

  # An unwritable directory is reported at once, not waited on for the cap.
  RD="$T/rodir"; mkdir -p "$RD"; : >"$RD/x.jsonl"; chmod 555 "$RD"
  if [[ -w "$RD" ]]; then echo "  skip unwritable-dir case (running as root)"
  else
    start=$SECONDS
    bash -c '. "$1"; append_line_locked "$2" "{\"ok\":1}"' _ "$LIB" "$RD/x.jsonl" 2>"$T/rodir.err"
    if [[ $((SECONDS - start)) -lt 3 ]] && grep -q "not writable" "$T/rodir.err"; then
      ok "an unwritable ledger directory is reported at once"
    else bad "unwritable dir (took=$((SECONDS - start))s): $(cat "$T/rodir.err")"; fi
  fi
  chmod 755 "$RD"

  # A missing directory is not a lock that was waited on.
  bash -c '. "$1"; append_line_locked "$2" "{\"ok\":1}"' _ "$LIB" "$T/no/such/dir/x.jsonl" 2>"$T/nodir.err"
  rc=$?
  if [[ $rc -ne 0 ]] && grep -q "does not exist" "$T/nodir.err" && ! grep -q "wait cap" "$T/nodir.err"; then
    ok "a missing ledger directory is reported as missing, not as a lock timeout"
  else bad "missing-dir diagnostic (rc=$rc): $(cat "$T/nodir.err")"; fi

  # A live-looking lock that never clears must not stall the round forever or
  # cost it the row: wait out the cap, then write anyway and say so.
  L="$T/stuck.jsonl"; mkdir "$L.lock.d"
  CROSS_REVIEW_LOCK_WAIT_S=1 bash -c '. "$1"; append_line_locked "$2" "{\"ok\":1}"' _ "$LIB" "$L" 2>"$T/stuck.err"
  rc=$?
  if [[ $rc -eq 0 && "$(lines "$L")" -eq 1 ]]; then ok "past the wait cap the row is still written"
  else bad "wait cap (rc=$rc rows=$(lines "$L"))"; fi
  grep -q "WARN" "$T/stuck.err" && ok "writing past the cap warns" || bad "no warning past the cap"
  [[ -d "$L.lock.d" ]] && ok "writing past the cap does not delete someone else's lock" \
                       || bad "past-cap write removed a lock it never held"

  # The failure this file exists for: many concurrent rows far over PIPE_BUF.
  # Three rounds: a lock race that tears rows only some of the time passed a
  # single round by luck four times running.
  pad="$(printf 'x%.0s' $(seq 1 8000))"
  torn=""
  for round in 1 2 3; do
    L="$T/concurrent$round.jsonl"
    for i in $(seq 1 25); do
      bash -c '. "$1"; append_line_locked "$2" "$3"' _ "$LIB" "$L" "{\"id\":$i,\"pad\":\"$pad\"}" 2>>"$T/concurrent.err" &
    done
    wait
    parsed="$(jq -R 'fromjson? | .id' "$L" 2>/dev/null | sort -un | wc -l | tr -d ' ')"
    [[ "$(lines "$L")" -eq 25 && "$parsed" -eq 25 ]] || torn="$torn round$round:lines=$(lines "$L"),whole=$parsed"
  done
  if [[ -z "$torn" && ! -s "$T/concurrent.err" ]]; then ok "3 rounds of 25 concurrent 8KB appends land whole, with no lock warnings"
  else bad "concurrent appends:$torn $(head -2 "$T/concurrent.err")"; fi
fi

echo
echo "══ $PASS passed, $FAIL failed ══"
[[ "$FAIL" -eq 0 ]]
