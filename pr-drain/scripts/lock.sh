#!/bin/bash
# lock.sh — simple named lockfiles with stale-PID reaping (macOS-safe, no flock).
# Usage:
#   lock.sh acquire <name> [timeout_s]   # exit 0 on acquire, 1 on timeout
#   lock.sh release <name>
#   lock.sh status
# Env: PR_DRAIN_WORKDIR (default: .pr-drain in cwd)
set -euo pipefail

WORKDIR="${PR_DRAIN_WORKDIR:-.pr-drain}"
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
        echo $$ > "$lock/pid"
        echo "acquired $name (pid $$)"
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
