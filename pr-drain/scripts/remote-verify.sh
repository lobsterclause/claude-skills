#!/bin/bash
# remote-verify.sh <local-worktree> <name> <firebird|thunderbird>
#
# Run `pnpm verify` for a COMMITTED worktree inside a Docker container on a
# homelab box, so a loaded laptop cannot manufacture "Timeout waiting for
# worker" reds. Ships the TRACKED files (`git ls-files --cached`) as a tar, read
# from the working copy, so uncommitted edits to tracked files are included but
# the reported head is the worktree's HEAD: commit first, or the result
# describes a SHA you are not pushing. Untracked files are NOT shipped: the box
# runs `git add -A -f`, so a stray local file (a test report, a scratch script)
# would become a tracked file there and fail checks CI never sees (#204: a
# functions-core/.vitest/ report failed `format (tracked)` twice). The log
# prints a WARN naming every untracked path left out, inside submodules too.
# RV_INCLUDE_UNTRACKED=1 ships untracked-not-ignored files as well.
#
# Exit status is the remote verify's exit code (same N as the .out file), 93
# if the log could not be opened, or 94 if the .out file could not be written.
# (A verify that itself exits 93 or 94 reads the same; the log tells them
# apart.)
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
# A relative RV_OUT_DIR is resolved now, before the `cd "$WT"` below, so
# the .out and the log land in the same place on every exit path.
case "$OUTD" in /*) ;; *) OUTD="$PWD/$OUTD";; esac
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
  # Which command this run is for. issue-drain's stamp-remote-pass reads it: a
  # run of one test file must not count as the full verify.
  echo "cmd=${RV_CMD:-pnpm verify}"
  "${SSH[@]}" "docker run --rm -v $BASE:/b $IMAGE rm -rf /b/$N; mkdir -p $D/w $D/tmp" || finish 98
  # From here a local failure still removes what was set up on the box; the
  # cleanup's own status never replaces the failure code.
  fail_clean() { "${SSH[@]}" "docker run --rm -v $BASE:/b $IMAGE rm -rf /b/$N" || true; finish "$1"; }
  # list_tree <dir> <prefix> <cached|others>: NUL-separated paths under <dir>,
  # each with <prefix> in front. It walks into every gitlink that has a
  # checkout itself, whatever git's submodule.active says, because
  # --recurse-submodules and `submodule foreach` both skip inactive ones.
  # `others` lists untracked-not-ignored paths; a nested repository that
  # isn't a submodule shows up as "dir/" and is passed through as such.
  # Any git failure returns 1.
  list_tree() {
    local dir=$1 pre=$2 kind=$3 ent mode path idx rc=0
    if [ "$kind" = others ]; then
      /usr/bin/git -C "$dir" ls-files -z --others --exclude-standard \
        | while IFS= read -r -d '' path; do printf '%s%s\0' "$pre" "$path"; done
      [ "${PIPESTATUS[0]}" = 0 ] || return 1
    fi
    idx=$(mktemp) || return 1
    /usr/bin/git -C "$dir" ls-files -z -s > "$idx" || { rm -f "$idx"; return 1; }
    while IFS= read -r -d '' ent; do
      mode=${ent%% *}; path=${ent#*$'\t'}
      if [ "$mode" = 160000 ]; then
        # What's in the working copy decides, not the index:
        # - a symlink to a directory would ship another checkout (perhaps
        #   outside the worktree) under this path; git status refuses this
        #   layout too, so refuse it rather than verify a different tree;
        # - a file or other symlink that replaced the submodule (unstaged)
        #   is shipped as itself, like any tracked path;
        # - a directory without .git is a submodule with no checkout: named;
        # - nothing there: skipped, like any tracked file deleted locally.
        if [ -L "$dir/$path" ] && [ -d "$dir/$path" ]; then
          printf 'submodule %q is a symlink; refusing to ship through it\n' "$pre$path" >&2
          rc=1; break
        elif [ -L "$dir/$path" ] || [ -f "$dir/$path" ]; then
          [ "$kind" = cached ] && printf '%s%s\0' "$pre" "$path"
        elif [ -d "$dir/$path" ] && [ ! -e "$dir/$path/.git" ]; then
          [ "$kind" = cached ] && printf 'note: submodule %q has no checkout; not shipped\n' "$pre$path" >&2
        elif [ -d "$dir/$path" ]; then
          list_tree "$dir/$path" "$pre$path/" "$kind" || { rc=1; break; }
        fi
      elif [ "$kind" = cached ]; then
        printf '%s%s\0' "$pre" "$path"
      fi
    done < "$idx"
    rm -f "$idx"
    return "$rc"
  }
  # list_subs <dir> <prefix>: NUL-separated paths of the checked-out
  # submodules list_tree walks into, innermost first. The box makes each one
  # its own repository before `git add -A -f`, so the snapshot keeps them as
  # gitlinks (as CI sees them) instead of flattening their files. The box
# creates each directory first (an empty submodule ships no files), and
# stages with -f: only shipped paths exist there, and a tracked file that
# matches a .gitignore must stay tracked.
  list_subs() {
    local dir=$1 pre=$2 ent mode path idx rc=0
    idx=$(mktemp) || return 1
    /usr/bin/git -C "$dir" ls-files -z -s > "$idx" || { rm -f "$idx"; return 1; }
    while IFS= read -r -d '' ent; do
      mode=${ent%% *}; path=${ent#*$'\t'}
      [ "$mode" = 160000 ] && [ ! -L "$dir/$path" ] && [ -d "$dir/$path" ] && [ -e "$dir/$path/.git" ] || continue
      list_subs "$dir/$path" "$pre$path/" || { rc=1; break; }
      printf '%s%s\0' "$pre" "$path"
    done < "$idx"
    rm -f "$idx"
    return "$rc"
  }
  # count_unshipped <dir>: how many tracked gitlinks (submodules) never had
  # their contents shipped: a directory without a checkout, or nothing there.
  # A clean `git status` says nothing about these (an empty directory is
  # clean), so the shipped line counts them. Checked-out submodules are walked
  # into, as list_tree does; a file that replaced a gitlink ships as itself.
  count_unshipped() {
    local dir=$1 ent mode path n=0 sub
    while IFS= read -r -d '' ent; do
      mode=${ent%% *}; path=${ent#*$'\t'}
      [ "$mode" = 160000 ] || continue
      if [ -L "$dir/$path" ] || [ -f "$dir/$path" ]; then continue
      elif [ -d "$dir/$path" ] && [ -e "$dir/$path/.git" ]; then
        sub=$(count_unshipped "$dir/$path") || return 1
        n=$((n + sub))
      else n=$((n + 1))
      fi
    done < <(/usr/bin/git -C "$dir" ls-files -z -s)
    echo "$n"
  }
  INCL=0
  if [ "${RV_INCLUDE_UNTRACKED:-0}" = 1 ]; then INCL=1
  else
    UNTR=$(mktemp) || fail_clean 99
    list_tree . "" others > "$UNTR" || { rm -f "$UNTR"; echo "listing untracked files failed"; fail_clean 99; }
    # LC_ALL=C: count bytes, so a filename invalid in the caller's locale
    # can't stop tr early and hide the warning.
    n=$(LC_ALL=C tr -cd '\0' < "$UNTR" | wc -c | tr -d ' ')
    if [ "$n" != 0 ]; then
      echo "WARN: not shipping $n untracked path(s) (RV_INCLUDE_UNTRACKED=1 to ship them):"
      while IFS= read -r -d '' f; do printf '  %q\n' "$f"; done < "$UNTR"
    fi
    rm -f "$UNTR"
  fi
  # Ship git's file list as it stands in the working copy, and nothing else.
  # tar never recurses (--no-recursion), so a submodule's untracked files
  # stay home, and so does a directory that replaced a tracked file.
  # Tracked files deleted locally are skipped (the box sees what you see);
  # any other path that isn't a file or symlink is named in the log.
  # RV_INCLUDE_UNTRACKED=1 adds the untracked files, submodules' included;
  # a nested repository that isn't a submodule is named, not shipped.
  # pipefail: a local git or tar failure is not masked by ssh's status.
  ( set -o pipefail
    { list_tree . "" cached || exit 1
      if [ "$INCL" = 1 ]; then list_tree . "" others || exit 1; fi
    } \
      | while IFS= read -r -d '' f; do
          if [ -L "$f" ] || [ -f "$f" ]; then printf '%s\0' "$f"
          elif [ -e "$f" ]; then printf 'note: not shipping %q (not a file or symlink)\n' "$f" >&2
          fi
        done \
      | COPYFILE_DISABLE=1 tar --null --no-recursion -T - -czf - \
      | "${SSH[@]}" "tar -xzf - -C $D/w"
  ) || { echo "shipping the tree failed (git ls-files, tar or ssh)"; fail_clean 99; }
  ( set -o pipefail; list_subs . "" | "${SSH[@]}" "cat > $D/gitlinks" ) \
    || { echo "shipping the submodule list failed"; fail_clean 99; }
  # The working copy is on the box now. Record what it was at this moment,
  # computed like the header: a stamp must be for the tree that was shipped,
  # not the one the header saw before the stream ran.
  UNSHIPPED=$(count_unshipped .) || { echo "counting unshipped submodules failed"; fail_clean 99; }
  echo "shipped head=$(/usr/bin/git rev-parse HEAD) dirty=$(/usr/bin/git status --porcelain | wc -l | tr -d ' ') unshipped=$UNSHIPPED"
  # RV_GH_TOKEN=1: ship `gh auth token` as NODE_AUTH_TOKEN for GitHub Packages installs, via a
  # mode-600 env file outside the repo dir (never on a command line, never logged; removed with $D).
  ENVF=""
  if [ "${RV_GH_TOKEN:-0}" = 1 ]; then
    { printf 'NODE_AUTH_TOKEN='; gh auth token; } | "${SSH[@]}" "umask 077; cat > $D/tok.env" || fail_clean 96
    ENVF="--env-file $D/tok.env"
  fi
  # RV_INSTALL overrides the install step (default: pnpm frozen install at the repo root).
  "${SSH[@]}" "cd $D/w && docker run --rm $LIM $ENVF --user \$(id -u):\$(id -g) --name rv-$N -v $D:/m -w /m/w -e HOME=/tmp -e TMPDIR=/m/tmp -e CI=1 -e COREPACK_HOME=/tmp/.corepack $IMAGE bash -c 'set -e; git config --global --add safe.directory \"*\"; while IFS= read -r -d \"\" p; do (mkdir -p \"\$p\" && cd \"\$p\" && git init -q && git -c user.email=v@v -c user.name=v add -A -f && git -c user.email=v@v -c user.name=v commit -q --allow-empty -m snap) || exit 1; done < /m/gitlinks; git init -q; git -c user.email=v@v -c user.name=v add -A -f; git -c user.email=v@v -c user.name=v commit -q -m snap; mkdir -p /tmp/bin; corepack enable --install-directory /tmp/bin; export PATH=/tmp/bin:\$PATH; ${RV_INSTALL:-pnpm install --frozen-lockfile} 2>&1 | tail -3; ${RV_CMD:-pnpm verify} 2>&1'"
  rc=$?
  echo "remote rc=$rc"
  "${SSH[@]}" "docker run --rm -v $BASE:/b $IMAGE rm -rf /b/$N"
  finish "$rc"
} >&3 2>&1
