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
  sleep 1
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

# import_runlog publishes by rename rather than appending, but it replaces the
# same file append_runlog appends to, so it has to queue on the same lock.
SRC="$T/other-machine.jsonl"
printf '{"ts":"2026-10-01T00:00:00Z","schema_version":1,"project":"imp","pass":1,"verdict":"CLEAN","reviewers":{}}\n' >"$SRC"
IMP="$T/import-into.jsonl"; : >"$IMP"
echo "── import_runlog.sh ──"
held_lock "import_runlog" "$IMP" bash "$S/import_runlog.sh" --from "$SRC" --into "$IMP" --quiet

# A writer copied somewhere without its lib (a partial sync, a fixture that
# copies only the scripts it names) used to drop the row and still print
# "appended runlog entry". It must fail, and say so.
echo "── a writer without lib_append_lock.sh ──"
LONE="$T/lone"; mkdir -p "$LONE"
cp "$S/append_runlog.sh" "$S/append_finding_event.sh" "$S/import_runlog.sh" "$LONE/"
missing_lib() {
  local label="$1" ledger="$2"; shift 2
  "$@" >"$T/lone.out" 2>&1
  local rc=$?
  if [[ $rc -ne 0 ]] && ! grep -qE '^appended |wrote [0-9]+ entries' "$T/lone.out"; then
    ok "$label fails loudly when its lib is missing (rc=$rc)"
  else bad "$label without its lib (rc=$rc): $(tail -1 "$T/lone.out")"; fi
}
missing_lib "append_runlog" "$T/lone-rl.jsonl" \
  env CROSS_REVIEW_RUNLOG="$T/lone-rl.jsonl" bash "$LONE/append_runlog.sh" \
    --run-dir "$RUN" --project test --base main --pr - --pass 1 --verdict CLEAN --convergent 0 --top "-"
missing_lib "append_finding_event" "$T/lone-fe.jsonl" \
  env CROSS_REVIEW_FINDING_EVENTS="$T/lone-fe.jsonl" bash "$LONE/append_finding_event.sh" \
    --event proposed --finding-id f-abc --run-id r1
: >"$T/lone-imp.jsonl"
missing_lib "import_runlog" "$T/lone-imp.jsonl" \
  bash "$LONE/import_runlog.sh" --from "$SRC" --into "$T/lone-imp.jsonl"

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
