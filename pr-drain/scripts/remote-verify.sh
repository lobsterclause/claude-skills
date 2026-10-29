#!/bin/bash
# remote-verify.sh <local-worktree> <name> <firebird|thunderbird>
#
# Run `pnpm verify` for a COMMITTED worktree inside a Docker container on a
# homelab box, so a loaded laptop cannot manufacture "Timeout waiting for
# worker" reds. Ships `git ls-files` (tracked + untracked-not-ignored) as a tar,
# so uncommitted edits are included but the reported head is the worktree's HEAD:
# commit first, or the result describes a SHA you are not pushing.
#
# Outputs (override the dir with RV_OUT_DIR):
#   $RV_OUT_DIR/rverify-<name>.log   full log (ANSI colour included)
#   $RV_OUT_DIR/rv-<name>.out        "verify exit=N" -- written LAST; poll for it
#   RV_CMD overrides the command (default `pnpm verify`) to run one test file.
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
IMAGE="kma-verify:22"
IMAGE_DOCKERFILE='FROM node:22-bookworm
RUN apt-get update && apt-get install -y --no-install-recommends jq shellcheck ripgrep zsh bsdmainutils && rm -rf /var/lib/apt/lists/*'
case "$HOSTK" in
  firebird)    SSH="ssh -i $HOME/firebird-handoff/id_ed25519 -o BatchMode=yes -o ConnectTimeout=15 -o ServerAliveInterval=30 admin@100.119.118.118"; BASE=/srv/ci/work/rverify; LIM="--cpus=14 --memory=16g";;
  thunderbird) SSH="ssh -o BatchMode=yes -o ConnectTimeout=15 -o ServerAliveInterval=30 thunderbird"; BASE=/home/admin/rverify; LIM="--cpus=14 --memory=12g";;
  *) echo "unknown host '$HOSTK'" >&2; exit 2;;
esac
D=$BASE/$N; LOG=$OUTD/rverify-$N.log; OUT=$OUTD/rv-$N.out; rm -f "$OUT"
if [ "${RV_BUILD_IMAGE:-0}" = 1 ]; then printf '%s\n' "$IMAGE_DOCKERFILE" | $SSH "docker build -q -t $IMAGE -"; exit $?; fi
{
  cd "$WT" || { echo "verify exit=97" > "$OUT"; exit 97; }
  echo "host=$HOSTK head=$(/usr/bin/git rev-parse HEAD) dirty=$(/usr/bin/git status --porcelain | wc -l | tr -d ' ')"
  $SSH "docker run --rm -v $BASE:/b $IMAGE rm -rf /b/$N; mkdir -p $D/w $D/tmp" || { echo "verify exit=98" > "$OUT"; exit 98; }
  /usr/bin/git ls-files -z --cached --others --exclude-standard | COPYFILE_DISABLE=1 tar --null -T - -czf - 2>/dev/null | $SSH "tar -xzf - -C $D/w" || { echo "verify exit=99" > "$OUT"; exit 99; }
  $SSH "cd $D/w && docker run --rm $LIM --user \$(id -u):\$(id -g) --name rv-$N -v $D:/m -w /m/w -e HOME=/tmp -e TMPDIR=/m/tmp -e CI=1 -e COREPACK_HOME=/tmp/.corepack $IMAGE bash -c 'set -e; git config --global --add safe.directory /m/w; git init -q; git -c user.email=v@v -c user.name=v add -A; git -c user.email=v@v -c user.name=v commit -q -m snap; mkdir -p /tmp/bin; corepack enable --install-directory /tmp/bin; export PATH=/tmp/bin:\$PATH; pnpm install --frozen-lockfile 2>&1 | tail -3; ${RV_CMD:-pnpm verify} 2>&1'"
  rc=$?
  echo "remote rc=$rc"
  $SSH "docker run --rm -v $BASE:/b $IMAGE rm -rf /b/$N"
  echo "verify exit=$rc" > "$OUT"
} > "$LOG" 2>&1
