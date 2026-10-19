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

  # Staleness is the OWNER's liveness, not the lock's age: a slow holder can
  # keep the lock past a minute. A lock recorded as owned by a live process is
  # live however old; one owned by a dead process is stale however new.
  L="$T/owned-live.jsonl"; mkdir "$L.lock.d"; echo "$$" >"$L.lock.d/owner"
  touch -t 202001010000 "$L.lock.d"
  CROSS_REVIEW_LOCK_WAIT_S=1 bash -c '. "$1"; append_line_locked "$2" "{\"ok\":1}"' _ "$LIB" "$L" 2>"$T/owned-live.err"
  if grep -q WARN "$T/owned-live.err" && [[ "$(cat "$L.lock.d/owner" 2>/dev/null)" == "$$" ]]; then
    ok "an old lock owned by a live process is not reclaimed"
  else bad "a live owner's old lock was reclaimed"; fi

  bash -c 'exit 0' & dead=$!; wait "$dead"
  L="$T/owned-dead.jsonl"; mkdir "$L.lock.d"; echo "$dead" >"$L.lock.d/owner"
  start=$SECONDS
  CROSS_REVIEW_LOCK_WAIT_S=5 bash -c '. "$1"; append_line_locked "$2" "{\"ok\":1}"' _ "$LIB" "$L" 2>"$T/owned-dead.err"
  if [[ "$(lines "$L")" -eq 1 && $((SECONDS - start)) -lt 3 && ! -e "$L.lock.d" ]] && ! grep -q WARN "$T/owned-dead.err"; then
    ok "a fresh lock whose owner is dead is reclaimed at once"
  else bad "dead owner's lock (took=$((SECONDS - start))s): $(cat "$T/owned-dead.err")"; fi

  # Death must not be read from an error MESSAGE: strerror is localized, so a
  # check for "No such process" never fires under a German or French locale
  # and a dead holder's lock is never reclaimed. Override kill with one that
  # fails the way a dead pid does but answers in German.
  bash -c 'exit 0' & dead=$!; wait "$dead"
  L="$T/owned-dead-de.jsonl"; mkdir "$L.lock.d"; echo "$dead" >"$L.lock.d/owner"
  CROSS_REVIEW_LOCK_WAIT_S=3 bash -c '
    kill() { if [[ "$1" == -0 ]]; then echo "bash: kill: ($2) - Kein passender Prozess gefunden" >&2; return 1; fi; builtin kill "$@"; }
    . "$1"; append_line_locked "$2" "{\"ok\":1}"' _ "$LIB" "$L" 2>"$T/owned-dead-de.err"
  if [[ "$(lines "$L")" -eq 1 && ! -e "$L.lock.d" ]] && ! grep -q WARN "$T/owned-dead-de.err"; then
    ok "a dead owner is recognised without reading English error text"
  else bad "dead owner under a non-English kill message: $(cat "$T/owned-dead-de.err")"; fi

  # A live process we may not signal (EPERM — pid 1 for a non-root user) is
  # alive, not dead.
  if [[ "$(id -u)" -ne 0 ]]; then
    L="$T/owned-pid1.jsonl"; mkdir "$L.lock.d"; echo 1 >"$L.lock.d/owner"
    CROSS_REVIEW_LOCK_WAIT_S=1 bash -c '. "$1"; append_line_locked "$2" "{\"ok\":1}"' _ "$LIB" "$L" 2>"$T/pid1.err"
    if grep -q WARN "$T/pid1.err" && [[ "$(cat "$L.lock.d/owner" 2>/dev/null)" == 1 ]]; then
      ok "a live owner we cannot signal (EPERM) is not reclaimed"
    else bad "an EPERM owner's lock was reclaimed"; fi
  fi

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
  L="$T/concurrent.jsonl"
  pad="$(printf 'x%.0s' $(seq 1 8000))"
  for i in $(seq 1 25); do
    bash -c '. "$1"; append_line_locked "$2" "$3"' _ "$LIB" "$L" "{\"id\":$i,\"pad\":\"$pad\"}" &
  done
  wait
  parsed="$(jq -R 'fromjson? | .id' "$L" 2>/dev/null | sort -un | wc -l | tr -d ' ')"
  if [[ "$(lines "$L")" -eq 25 && "$parsed" -eq 25 ]]; then ok "25 concurrent 8KB appends land as 25 whole rows"
  else bad "concurrent appends (lines=$(lines "$L") whole=$parsed)"; fi
fi

echo
echo "══ $PASS passed, $FAIL failed ══"
[[ "$FAIL" -eq 0 ]]
