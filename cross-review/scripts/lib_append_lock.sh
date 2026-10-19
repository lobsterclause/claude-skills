#!/usr/bin/env bash
# lib_append_lock.sh — the one lock every JSONL ledger writer takes.
#
# Sourced by append_runlog.sh and append_finding_event.sh.
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
# Rules it keeps, because a ledger write sits at the end of a round:
#   - a lock is stale once it is a minute old. The critical section is one
#     printf, so nothing live holds it that long; age is measured in seconds
#     with stat, not asked of `find -mmin`, which compares rounded minutes.
#   - past the wait cap the row is written anyway, with a WARN. Losing the row
#     outright, or stalling the round, is worse than the small risk of a tear.
#   - release removes only the caller's own lock (its pid is recorded in
#     <lockdir>/owner), so a holder stalled past the minute, whose lock was
#     reclaimed, cannot then delete the next holder's.
#
# WHY STALENESS IS AGE, NOT THE OWNER'S LIVENESS
#
# Judging staleness by "is the recorded owner still running" was tried and
# is racy in ordinary use: a waiter reads owner H0, H0 releases and exits —
# which every writer does right after its append — a new holder takes the
# lock, and the waiter then finds H0 dead and reclaims the NEW holder's live
# lock. Twenty-five concurrent appends tore rows that way. Age has no such
# turnover race: a fresh lock is never a minute old.
#
# CROSS_REVIEW_LOCK_WAIT_S overrides the cap (default 75s, longer than the
# one-minute stale age so a dead holder is reclaimed inside the wait). It
# exists for the fixture tests.

# Age in whole seconds, or empty if it cannot be read. GNU stat first: BSD
# stat rejects -c, while GNU `stat -f` means something else.
_append_lock_age_s() {
  local mtime
  mtime="$(stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null)" || return 0
  [[ "$mtime" =~ ^[0-9]+$ ]] && echo $(( $(date +%s) - mtime ))
}

_append_lock_is_stale() {
  local age
  age="$(_append_lock_age_s "$1")"
  [[ -n "$age" && "$age" -ge 60 ]]
}

# append_lock_acquire <ledger> — 0 locked, 1 gave up at the cap,
# 2 the ledger's directory is missing or not writable.
append_lock_acquire() {
  local lockdir="$1.lock.d" n=0 cap="${CROSS_REVIEW_LOCK_WAIT_S:-75}" staledir
  [[ "$cap" =~ ^[0-9]+$ ]] || cap=75
  # A directory the lock cannot be made in would otherwise read as a lock
  # that never comes free: a 75-second wait for an error the write will hit
  # anyway.
  [[ -d "$(dirname "$1")" && -w "$(dirname "$1")" ]] || return 2
  until mkdir "$lockdir" 2>/dev/null; do
    if _append_lock_is_stale "$lockdir"; then
      # Rename, then delete: of two runs that see the same stale lock exactly
      # one wins the rename. The loser's rename can still land on the lock the
      # winner just re-took, so what was renamed is checked again: only a
      # still-stale lock is deleted; a fresh one is put back.
      staledir="$lockdir.stale.${BASHPID:-$$}.$RANDOM"
      if mv "$lockdir" "$staledir" 2>/dev/null; then
        if _append_lock_is_stale "$staledir"; then
          rm -rf "$staledir" 2>/dev/null || true
          continue
        fi
        # Never put it back onto a lockdir that exists again: mv would nest
        # it inside and wedge both. That narrow three-way case loses the
        # fresh lock instead — a known, documented limit shared with the
        # agy gate lock.
        if [[ -e "$lockdir" ]] || ! mv "$staledir" "$lockdir" 2>/dev/null; then
          rm -rf "$staledir" 2>/dev/null || true
        fi
      fi
      # A rename that fails falls through and counts toward the cap;
      # retrying it at once would spin.
    fi
    if [[ $n -ge $((cap * 5)) ]]; then return 1; fi
    sleep 0.2
    n=$((n + 1))
  done
  # Inline, never $(...): a command substitution is a subshell, where
  # BASHPID is the subshell's pid and would never match at release.
  echo "${BASHPID:-$$}" >"$lockdir/owner" 2>/dev/null || true
  return 0
}

append_lock_release() {
  local lockdir="$1.lock.d"
  [[ "$(cat "$lockdir/owner" 2>/dev/null || true)" == "${BASHPID:-$$}" ]] || return 0
  rm -f "$lockdir/owner"
  rmdir "$lockdir" 2>/dev/null || true
}

# append_line_locked <ledger> <line> — appends <line> plus a newline.
# Returns the append's own status; callers must check it.
append_line_locked() {
  local ledger="$1" line="$2" locked=1 rc
  append_lock_acquire "$ledger"
  case $? in
    0) ;;
    2) echo "ERROR: ledger directory $(dirname "$ledger") does not exist or is not writable" >&2
       return 1 ;;
    *) locked=0
       echo "WARN: could not lock $ledger within the wait cap; appending unlocked" >&2 ;;
  esac
  # Where flock exists, ALSO queue on master's "<ledger>.lock" flock:
  # import_runlog.sh still takes only that one (until #184) and replaces the
  # whole file, so an append it cannot see is deleted by its rename. The
  # importer never takes the mkdir lock, so the two cannot deadlock.
  if command -v flock >/dev/null 2>&1; then
    ( flock -x 200 && printf '%s\n' "$line" >>"$ledger" ) 200>"$ledger.lock"
  else
    printf '%s\n' "$line" >>"$ledger"
  fi
  rc=$?
  if [[ $locked -eq 1 ]]; then append_lock_release "$ledger"; fi
  return $rc
}
