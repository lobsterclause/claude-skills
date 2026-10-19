#!/usr/bin/env bash
# lib_append_lock.sh — the one lock every JSONL ledger writer takes.
#
# Sourced by append_runlog.sh, append_finding_event.sh and import_runlog.sh.
#
# WHY NOT flock, AND WHY NOT A BARE >>
#
# The writers used to take `flock` where it existed and fall back to a bare
# append where it did not, trusting write() atomicity below PIPE_BUF. macOS has
# no flock, PIPE_BUF there is 512 bytes, and a runlog row is now ~7KB — so on
# the machine that runs the rounds every append was unlocked and big enough to
# be split across write() calls. On 2026-10-08 two rounds of one PR appended in
# the same second and one row landed spliced into the middle of the other.
# A bare append is not a fallback; it is the bug.
#
# So the lock is an atomic mkdir of "<ledger>.lock.d" on every platform — the
# same primitive run_reviewers.sh uses for the agy gate — which also means the
# path the tests exercise is the path every machine runs.
#
# Two rules it keeps, because a ledger write sits at the end of a round:
#   - a crashed holder's lock is reclaimed once it is a minute old (an append
#     takes milliseconds, so nothing live holds it that long);
#   - past the wait cap the row is written anyway, with a WARN. Losing the row
#     outright, or stalling the round, is worse than the small risk of a tear.
#
# CROSS_REVIEW_LOCK_WAIT_S overrides the cap (default 75s, longer than the
# one-minute stale age so a dead holder is reclaimed inside the wait). It
# exists for the fixture tests.

# append_lock_acquire <ledger> — 0 locked, 1 gave up at the cap.
append_lock_acquire() {
  local lockdir="$1.lock.d" n=0 cap="${CROSS_REVIEW_LOCK_WAIT_S:-75}"
  [[ "$cap" =~ ^[0-9]+$ ]] || cap=75
  # No directory to lock in means the write itself is about to fail with a
  # clearer error than a 75-second wait would give.
  [[ -d "$(dirname "$1")" ]] || return 1
  until mkdir "$lockdir" 2>/dev/null; do
    if [[ -n "$(find "$lockdir" -maxdepth 0 -mmin +1 2>/dev/null)" ]]; then
      # Rename, then delete: of two runs that see the same stale lock exactly
      # one wins the rename, so neither deletes a lock the other just re-took.
      if mv "$lockdir" "$lockdir.stale.$$" 2>/dev/null; then
        rm -rf "$lockdir.stale.$$" 2>/dev/null || true
      fi
      continue
    fi
    if [[ $n -ge $((cap * 5)) ]]; then return 1; fi
    sleep 0.2
    n=$((n + 1))
  done
  return 0
}

append_lock_release() { rmdir "$1.lock.d" 2>/dev/null || true; }

# append_line_locked <ledger> <line> — appends <line> plus a newline.
# Returns the append's own status.
append_line_locked() {
  local ledger="$1" line="$2" locked=1 rc
  if ! append_lock_acquire "$ledger"; then
    locked=0
    echo "WARN: could not lock $ledger within the wait cap; appending unlocked" >&2
  fi
  printf '%s\n' "$line" >>"$ledger"
  rc=$?
  if [[ $locked -eq 1 ]]; then append_lock_release "$ledger"; fi
  return $rc
}
