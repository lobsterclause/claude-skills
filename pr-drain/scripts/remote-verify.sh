#!/bin/bash
# remote-verify.sh <local-worktree> <name> <firebird|thunderbird>
#
# Run `pnpm verify` for a COMMITTED worktree inside a Docker container on a
# homelab box, so a loaded laptop cannot manufacture "Timeout waiting for
# worker" reds. Ships the TRACKED files (`git ls-files --cached`) as a tar, read
# from the working copy, so uncommitted edits to tracked files are included but
# the reported head is the worktree's HEAD: commit first, or the result
# describes a SHA you are not pushing. Untracked files are NOT shipped: the box
# runs `git add -A`, so a stray local file (a test report, a scratch script)
# would become a tracked file there and fail checks CI never sees (#204: a
# functions-core/.vitest/ report failed `format (tracked)` twice). The log
# prints a WARN naming every untracked path left out. RV_INCLUDE_UNTRACKED=1
# restores the old behaviour (ship untracked-not-ignored files too).
#
# Exit status is the remote verify's exit code (same N as the .out file), 93
# if the log could not be opened, or 94 if the .out file could not be written.
# Before #204 the script always exited 0, so a background caller saw success
# on a failed verify.
#
# Outputs (override the dir with RV_OUT_DIR):
#   $RV_OUT_DIR/rverify-<name>.log   full log (ANSI colour included)
#   $RV_OUT_DIR/rv-<name>.out        "verify exit=N" -- written LAST; poll for it
#   RV_CMD overrides the command (default `pnpm verify`) to run one test file.
#   RV_SSH overrides the ssh command for the chosen host (test seam; see
#   pr-drain/tests/remote-verify.test.sh).
#
# Prove a result by the log: it must contain `host=... head=<sha>` for the SHA
# you are about to push and `verify passed`. Exit 125 = docker failed to start
# (thunderbird's docker0 bridge has dropped veth endpoints; just rerun on
# firebird). Exit 255 = the ssh session died (rerun).
#
# Traps this script already handles, learned 2026-10-28 (do not "simplify" them):
#  * Container must run as the HOST user (--user), else it leaves root-owned
#    files that the admin user cannot delete; cleanup runs through docker.
#  * Repo and TMPDIR must sit under ONE bind mount (/m/w and /m/tmp). With the
#    default /tmp the split-nem-core test's `git clone` hardlinks across
#    filesystems and fails "Invalid cross-device link". TMPDIR inside the repo
#    pollutes the *.test.mjs glob instead.
#  * The image needs jq, shellcheck, ripgrep, zsh (the scripts/hooks suites use
#    them); plain node:22 fails `test: scripts` and `test: claude hooks`.
#    Build once per host: see IMAGE_DOCKERFILE below.
#  * `git config safe.directory` is required (bind-mounted dir owner differs).
#  * macOS tar adds xattr headers; COPYFILE_DISABLE=1 keeps the noise down.
#  * firebird: /srv/ci/work/.admin-home is root-owned; use /srv/ci/work/rverify.
#  * Run at most two at once per host; firebird shares its cores with CI.
set -u
WT="$1"; N="$2"; HOSTK="$3"
OUTD="${RV_OUT_DIR:-$HOME/.pr-drain/wt}"; mkdir -p "$OUTD"
# kma-verify:22-java = kma-verify:22 + JRE + pre-baked Firestore/PubSub emulator jars (FIREBASE_EMULATORS_PATH).
# Rollback: RV_IMAGE=kma-verify:22. Dockerfile: ~/.pr-drain/img/Dockerfile.kma-verify-22-java (on boxes: ~/rv-img/).
IMAGE="${RV_IMAGE:-kma-verify:22-java}"
IMAGE_DOCKERFILE='FROM node:22-bookworm
RUN apt-get update && apt-get install -y --no-install-recommends jq shellcheck ripgrep zsh bsdmainutils && rm -rf /var/lib/apt/lists/*'
case "$HOSTK" in
  firebird)    SSH=(ssh -i "$HOME/firebird-handoff/id_ed25519" -o BatchMode=yes -o ConnectTimeout=15 -o ServerAliveInterval=30 admin@100.119.118.118); BASE=/srv/ci/work/rverify; LIM="--cpus=14 --memory=16g";;
  thunderbird) SSH=(ssh -o BatchMode=yes -o ConnectTimeout=15 -o ServerAliveInterval=30 thunderbird); BASE=/home/admin/rverify; LIM="--cpus=14 --memory=12g";;
  *) echo "unknown host '$HOSTK'" >&2; exit 2;;
esac
# RV_SSH is one executable path (may contain spaces), never word-split.
# A relative path is resolved now, before the `cd "$WT"` below; a bare name
# still goes through PATH.
if [ -n "${RV_SSH:-}" ]; then
  case "$RV_SSH" in /*) ;; */*) RV_SSH="$PWD/$RV_SSH";; esac
  SSH=("$RV_SSH")
fi
D=$BASE/$N; LOG=$OUTD/rverify-$N.log; OUT=$OUTD/rv-$N.out; rm -f "$OUT"
# Image-build mode keeps the last verify's log but not its .out (removed
# above), so a poller can't read an old result as this run's.
if [ "${RV_BUILD_IMAGE:-0}" = 1 ]; then printf '%s\n' "$IMAGE_DOCKERFILE" | "${SSH[@]}" "docker build -q -t kma-verify:22 -"; exit $?; fi
# Every exit after this point writes the result a caller polls for. If that
# write fails, exit 94: never report a result nobody can read.
finish() { echo "verify exit=$1" > "$OUT" || { echo "cannot write $OUT"; exit 94; }; exit "$1"; }
# The block's output goes to $LOG, opened once on fd 3 (a second open of a
# FIFO log can block forever). If it can't be opened, fail here with 93.
exec 3> "$LOG" || { echo "cannot write $LOG" >&2; finish 93; }
{
  cd "$WT" || finish 97
  echo "host=$HOSTK head=$(/usr/bin/git rev-parse HEAD) dirty=$(/usr/bin/git status --porcelain | wc -l | tr -d ' ')"
  "${SSH[@]}" "docker run --rm -v $BASE:/b $IMAGE rm -rf /b/$N; mkdir -p $D/w $D/tmp" || finish 98
  LSF="--cached"
  if [ "${RV_INCLUDE_UNTRACKED:-0}" = 1 ]; then LSF="--cached --others --exclude-standard"
  else
    UNTR=$(/usr/bin/git ls-files --others --exclude-standard)
    [ -n "$UNTR" ] && { echo "WARN: not shipping $(printf '%s\n' "$UNTR" | wc -l | tr -d ' ') untracked file(s) (RV_INCLUDE_UNTRACKED=1 to ship them):"; printf '%s\n' "$UNTR" | sed 's/^/  /'; }
  fi
  # Ship exactly git's list as it stands in the working copy: tracked files
  # deleted locally are skipped (the box sees what you see), and
  # --no-recursion keeps a directory that replaced a tracked file from
  # dragging its untracked contents along. pipefail: a local git or tar
  # failure is not masked by ssh's status.
  # shellcheck disable=SC2086 # LSF is a deliberate flag list
  ( set -o pipefail
    /usr/bin/git ls-files -z $LSF \
      | while IFS= read -r -d '' f; do if [ -e "$f" ] || [ -L "$f" ]; then printf '%s\0' "$f"; fi; done \
      | COPYFILE_DISABLE=1 tar --null --no-recursion -T - -czf - \
      | "${SSH[@]}" "tar -xzf - -C $D/w"
  ) || { echo "shipping the tree failed (git ls-files, tar or ssh)"; finish 99; }
  # RV_GH_TOKEN=1: ship `gh auth token` as NODE_AUTH_TOKEN for GitHub Packages installs, via a
  # mode-600 env file outside the repo dir (never on a command line, never logged; removed with $D).
  ENVF=""
  if [ "${RV_GH_TOKEN:-0}" = 1 ]; then
    { printf 'NODE_AUTH_TOKEN='; gh auth token; } | "${SSH[@]}" "umask 077; cat > $D/tok.env" || finish 96
    ENVF="--env-file $D/tok.env"
  fi
  # RV_INSTALL overrides the install step (default: pnpm frozen install at the repo root).
  "${SSH[@]}" "cd $D/w && docker run --rm $LIM $ENVF --user \$(id -u):\$(id -g) --name rv-$N -v $D:/m -w /m/w -e HOME=/tmp -e TMPDIR=/m/tmp -e CI=1 -e COREPACK_HOME=/tmp/.corepack $IMAGE bash -c 'set -e; git config --global --add safe.directory /m/w; git init -q; git -c user.email=v@v -c user.name=v add -A; git -c user.email=v@v -c user.name=v commit -q -m snap; mkdir -p /tmp/bin; corepack enable --install-directory /tmp/bin; export PATH=/tmp/bin:\$PATH; ${RV_INSTALL:-pnpm install --frozen-lockfile} 2>&1 | tail -3; ${RV_CMD:-pnpm verify} 2>&1'"
  rc=$?
  echo "remote rc=$rc"
  "${SSH[@]}" "docker run --rm -v $BASE:/b $IMAGE rm -rf /b/$N"
  finish "$rc"
} >&3 2>&1
