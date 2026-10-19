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
# Two rules it keeps, because a ledger write sits at the end of a round:
#   - a crashed holder's lock is reclaimed once it is a minute old (an append
#     takes milliseconds, so nothing live holds it that long);
#   - past the wait cap the row is written anyway, with a WARN. Losing the row
#     outright, or stalling the round, is worse than the small risk of a tear.
#
# CROSS_REVIEW_LOCK_WAIT_S overrides the cap (default 75s, longer than the
# one-minute stale age so a dead holder is reclaimed inside the wait). It
# exists for the fixture tests.
#
# STALE MEANS THE OWNER IS DEAD, NOT THAT THE LOCK IS OLD
#
# Every acquire records its pid in <lockdir>/owner, and a waiter reclaims the
# lock only when that process no longer exists. An age rule alone reclaims a
# holder that is merely slow, and any fixed age is a guess about how long the
# slowest legitimate holder takes. Age is only the fallback for a lock with no
# owner record (its holder died between mkdir and writing it, or it predates
# this file). Release likewise removes only a lock whose owner is the caller,
# so a holder whose lock was taken over cannot delete the next holder's.
#
# Known limit: a holder that is alive but wedged forever is never reclaimed;
# waiters reach the cap instead. And between a waiter's stale check and its
# rename, another waiter can reclaim and re-take the lock. The rename is then
# checked against the owner that was judged dead and undone on a mismatch,
# which narrows that window to the undo itself.

# Age in whole seconds, or empty if it cannot be read. The age is measured,
# not asked of `find -mmin`, which compares rounded MINUTES and so is only an
# approximation of "older than 60 seconds". GNU stat first: BSD stat rejects
# -c, while GNU `stat -f` means something else.
_append_lock_age_s() {
  local mtime
  mtime="$(stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null)" || return 0
  [[ "$mtime" =~ ^[0-9]+$ ]] && echo $(( $(date +%s) - mtime ))
}

# _append_lock_is_stale <lockdir> — 0 if reclaimable. Leaves the owner it
# judged in _append_lock_seen_owner, so the reclaim can check it renamed the
# same lock.
_append_lock_is_stale() {
  local age
  _append_lock_seen_owner="$(cat "$1/owner" 2>/dev/null || true)"
  if [[ "$_append_lock_seen_owner" =~ ^[0-9]+$ ]]; then
    kill -0 "$_append_lock_seen_owner" 2>/dev/null && return 1
    # kill -0 also fails for a live process we may not signal (EPERM), and
    # its message is localized, so ask ps whether the pid exists at all.
    # Without ps the two cannot be told apart: treat the owner as alive.
    command -v ps >/dev/null 2>&1 || return 1
    ! ps -p "$_append_lock_seen_owner" >/dev/null 2>&1
    return
  fi
  age="$(_append_lock_age_s "$1")"
  [[ -n "$age" && "$age" -ge 60 ]]
}

# append_lock_acquire <ledger> — 0 locked, 1 gave up at the cap,
# 2 the ledger's directory is missing or not writable.
append_lock_acquire() {
  local lockdir="$1.lock.d" n=0 cap="${CROSS_REVIEW_LOCK_WAIT_S:-75}" staledir age
  [[ "$cap" =~ ^[0-9]+$ ]] || cap=75
  # A directory the lock cannot be made in would otherwise read as a lock
  # that never comes free: a 75-second wait for an error the write will hit
  # anyway.
  [[ -d "$(dirname "$1")" && -w "$(dirname "$1")" ]] || return 2
  until mkdir "$lockdir" 2>/dev/null; do
    if _append_lock_is_stale "$lockdir"; then
      # Rename, then delete: of two runs that see the same stale lock exactly
      # one wins the rename, so neither deletes a lock the other just re-took.
      staledir="$lockdir.stale.${BASHPID:-$$}.$RANDOM"
      if mv "$lockdir" "$staledir" 2>/dev/null; then
        age="$(_append_lock_age_s "$staledir")"
        if [[ "$(cat "$staledir/owner" 2>/dev/null || true)" == "$_append_lock_seen_owner" ]] &&
           { [[ -n "$_append_lock_seen_owner" ]] || [[ -n "$age" && "$age" -ge 60 ]]; }; then
          rm -rf "$staledir" 2>/dev/null || true
          continue
        fi
        # Re-taken since the check: this is a live lock. Put it back — but
        # never onto a lockdir that exists again, where mv would nest it
        # inside and wedge both.
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
  printf '%s\n' "$line" >>"$ledger"
  rc=$?
  if [[ $locked -eq 1 ]]; then append_lock_release "$ledger"; fi
  return $rc
}
