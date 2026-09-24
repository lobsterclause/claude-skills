#!/bin/bash
# lock.sh — simple named lockfiles with stale-PID reaping (macOS-safe, no flock).
# Usage:
#   lock.sh acquire <name> [timeout_s]   # exit 0 on acquire, 1 on timeout
#   lock.sh release <name>
#   lock.sh status
# Env: PR_DRAIN_WORKDIR (REQUIRED, absolute — e.g. $HOME/.pr-drain/<repo>-<issue>)
#      PR_DRAIN_LOCK_PID — the pid to record as holder (default: $PPID, the
#      shell that called us). NOT $$: this script exits the moment it acquires,
#      so recording its own pid made every lock look stale to the next caller,
#      who reaped it — two verifies overlapped and one failed on timeouts
#      (2026-09-03 drain).
set -euo pipefail
HOLDER_PID="${PR_DRAIN_LOCK_PID:-$PPID}"

# No default. With a cwd-relative `.pr-drain`, two callers in different
# directories each got a private lock directory, so neither ever saw the
# other's lock — the lock excluded nothing across exactly the boundary it
# exists for.
WORKDIR="${PR_DRAIN_WORKDIR:-}"
case "$WORKDIR" in
  /*) ;;
  *) echo "lock.sh: set PR_DRAIN_WORKDIR to an absolute path, e.g. \$HOME/.pr-drain/<repo>-<issue> (got '$WORKDIR')" >&2; exit 2 ;;
esac
LOCKDIR="$WORKDIR/locks"
mkdir -p "$LOCKDIR"

cmd="${1:-}"; name="${2:-}"
case "$cmd" in
  acquire)
    [ -n "$name" ] || { echo "lock name required" >&2; exit 1; }
    timeout="${3:-600}"
    lock="$LOCKDIR/$name.lock"
    deadline=$(( $(date +%s) + timeout ))
    while :; do
      # mkdir is atomic — the canonical portable lock primitive.
      if mkdir "$lock" 2>/dev/null; then
        echo "$HOLDER_PID" > "$lock/pid"
        echo "acquired $name (pid $HOLDER_PID)"
        exit 0
      fi
      holder=$(cat "$lock/pid" 2>/dev/null || echo "")
      if [ -n "$holder" ] && ! kill -0 "$holder" 2>/dev/null; then
        echo "reaping stale lock $name (dead pid $holder)" >&2
        rm -rf "$lock"
        continue
      fi
      [ "$(date +%s)" -ge "$deadline" ] && { echo "timeout acquiring $name (held by pid ${holder:-?})" >&2; exit 1; }
      sleep 5
    done
    ;;
  release)
    [ -n "$name" ] || { echo "lock name required" >&2; exit 1; }
    rm -rf "$LOCKDIR/$name.lock"
    echo "released $name"
    ;;
  status)
    found=0
    for l in "$LOCKDIR"/*.lock; do
      [ -d "$l" ] || continue
      found=1
      echo "$(basename "$l" .lock): held by pid $(cat "$l/pid" 2>/dev/null || echo '?')"
    done
    [ "$found" = "0" ] && echo "no locks held"
    exit 0
    ;;
  *)
    echo "usage: lock.sh acquire <name> [timeout_s] | release <name> | status" >&2
    exit 1
    ;;
esac
