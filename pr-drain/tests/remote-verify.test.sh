#!/bin/bash
# remote-verify.test.sh — pins #204: remote-verify.sh exits with the remote
# verify's code (it used to always exit 0), and ships only tracked files unless
# RV_INCLUDE_UNTRACKED=1 (a stray untracked file used to become tracked on the
# box and fail `format (tracked)`).
#
# A fake ssh (RV_SSH) stands in for the box: it extracts the shipped tar into
# $SHIP and answers the verify step with $FAKE_RC. Nothing leaves the machine.
#
# Red control (run 2026-11-21 against the pre-#204 script with an RV_SSH seam
# added): 3 of 8 fail ("exit code = 1 on failed verify", "untracked file
# not shipped", "log WARNs about the untracked file"). Pass-1 review cases
# (ssh path with a space, inherited RV_INCLUDE_UNTRACKED, unwritable .out):
# 8 of 10 fail against the first #205 commit. Pass-2 cases (early failure
# with unwritable .out, unopenable log, relative RV_SSH): 4 fail against the
# pass-1 fix commit. Pass-4 cases (stale .out after an image build, tar
# recursion, masked tar failure, FIFO log): checked red against c6d811c.
# Pass-5: submodule contents (red against b2c919e's --no-recursion).
# Pass-6: a submodule's untracked file (red against 4b38fbc).
# Pass-7: submodule WARN/opt-in, git listing failure, relative RV_OUT_DIR
# (red against 5807820).
# Pass-8: inactive submodule, nested repository note (red against fdfd5b1).
# Pass-9: symlinked submodule, submodule without a checkout, locale-safe
# WARN count (red against d831fdb); 98/97 early-failure codes.
# Pass-10: a file replacing a submodule, box cleanup on a local failure
# (red against 1ddd75f).
# Pass-11: submodule list for the box (red against 14e5587).
# Pass-13: the `shipped head= dirty=` line written after the stream (for
# issue-drain's stamp-remote-pass); no such line before it existed.
# Pass-12: the box's own git setup, run locally on the shipped tree: an
# empty submodule and force-tracked ignored files (red against d04df8c).
#
# Usage: bash pr-drain/tests/remote-verify.test.sh   (exit 0 = all pass)
set -u
S=${PROBE_S:-"$(cd "$(dirname "$0")/../scripts" && pwd)"}
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
# Keep the caller's git config out (a global excludes file listing .vitest/
# would make the fixture's stray file ignored instead of untracked).
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 XDG_CONFIG_HOME="$T/xdg"
fail=0
REAL_TAR=$(command -v tar); export REAL_TAR
exists() { if [ -f "$1" ]; then echo 0; else echo 1; fi; }
check() { # name expected actual
  if [ "$2" = "$3" ]; then echo "ok   $1 ($3)"; else echo "FAIL $1 expected $2 got $3"; fail=1; fi
}

# A committed repo with one tracked file and one untracked stray.
R="$T/repo"; mkdir -p "$R"
git -C "$R" init -q
echo tracked > "$R/a.txt"
git -C "$R" add a.txt
git -C "$R" -c user.email=t@t -c user.name=t commit -q -m init
mkdir -p "$R/pkg/.vitest/json" && echo '{}' > "$R/pkg/.vitest/json/output.json"

mkdir -p "$T/sp ace"
FSSH="$T/sp ace/fake-ssh" # a space in the path: RV_SSH must not be word-split
cat > "$FSSH" <<'FAKE'
#!/bin/bash
cmd="$*"
case "$cmd" in
  *"tar -xzf -"*) mkdir -p "$SHIP" && "$REAL_TAR" -xzf - -C "$SHIP"; rc=$?
    # EDIT_FILE: an edit made while the working copy streams.
    [ -n "${EDIT_FILE:-}" ] && echo edit >> "$EDIT_FILE"; exit $rc ;;
  *"git init -q"*) [ -n "${CMDLOG:-}" ] && printf '%s' "$cmd" > "$CMDLOG"; exit "$FAKE_RC" ;;
  *"mkdir -p $"*|*"mkdir -p /"*) [ -n "${FAKE_SETUP_FAIL:-}" ] && exit 1; exit 0 ;;
  *"rm -rf /b/"*) [ -n "${RMLOG:-}" ] && echo cleanup >> "$RMLOG"; exit 0 ;;
  *"cat > "*"/gitlinks") if [ -n "${GITLINKS:-}" ]; then cat > "$GITLINKS"; else cat >/dev/null; fi; exit 0 ;;
  *"docker build -q"*|*"tok.env"*) cat >/dev/null; exit 0 ;;
  # Anything else is a remote command the tests don't know: fail loudly.
  *) echo "fake-ssh: unexpected command: $cmd" >&2; exit 60 ;;
esac
FAKE
chmod +x "$FSSH"

run() { # rc ship-dir [env...]
  local rc=$1 ship=$2; shift 2
  # Pin the knobs a caller's shell may have exported; cases override after.
  env RV_INCLUDE_UNTRACKED=0 RV_BUILD_IMAGE=0 RV_GH_TOKEN=0 RV_SSH="$FSSH" RV_OUT_DIR="${OUTDIR:-$T/out}" SHIP="$ship" FAKE_RC="$rc" "$@" \
    bash "$S/remote-verify.sh" "${REPO:-$R}" probe firebird
}

run 1 "$T/ship1"; check "exit code = 1 on failed verify" 1 $?
check ".out records the failure" "verify exit=1" "$(cat "$T/out/rv-probe.out")"
check "untracked file not shipped" 1 "$(exists "$T/ship1/pkg/.vitest/json/output.json")"
check "tracked file shipped" 0 "$(exists "$T/ship1/a.txt")"
grep -q "WARN: not shipping 1 untracked path" "$T/out/rverify-probe.log"; check "log WARNs about the untracked file" 0 $?

# Passing control: a script that always failed would pass the checks above.
run 0 "$T/ship2"; check "exit code = 0 on passed verify" 0 $?

run 0 "$T/ship3" RV_INCLUDE_UNTRACKED=1; check "opt-in run exits 0" 0 $?
check "RV_INCLUDE_UNTRACKED=1 ships untracked" 0 "$(exists "$T/ship3/pkg/.vitest/json/output.json")"

# Inherited knobs are pinned: an exported RV_INCLUDE_UNTRACKED=1 must not leak in.
RV_INCLUDE_UNTRACKED=1 run 0 "$T/ship4" >/dev/null
check "inherited RV_INCLUDE_UNTRACKED ignored" 1 "$(exists "$T/ship4/pkg/.vitest/json/output.json")"

# A passed verify whose .out cannot be written is not reported as success.
mkdir -p "$T/out5/rv-probe.out"
OUTDIR="$T/out5" run 0 "$T/ship5"; check "unwritable .out exits 94" 94 $?

# Same for an early failure: setup fails (98) and .out can't be written.
mkdir -p "$T/out6/rv-probe.out"
OUTDIR="$T/out6" FAKE_SETUP_FAIL=1 run 0 "$T/ship6" 2>/dev/null; check "early failure with unwritable .out exits 94" 94 $?

# The log can't be opened: fail with 93, not a stale status.
mkdir -p "$T/out7/rverify-probe.log"
OUTDIR="$T/out7" run 0 "$T/ship7" 2>/dev/null; check "unopenable log exits 93" 93 $?
check "unopenable log still writes .out" "verify exit=93" "$(cat "$T/out7/rv-probe.out")"

# A relative RV_SSH resolves from the caller's directory, not the worktree.
( cd "$T/sp ace" && env GIT_CONFIG_GLOBAL=/dev/null RV_INCLUDE_UNTRACKED=0 RV_BUILD_IMAGE=0 RV_GH_TOKEN=0 RV_SSH=./fake-ssh RV_OUT_DIR="$T/out8" SHIP="$T/ship8" FAKE_RC=0 bash "$S/remote-verify.sh" "$R" probe firebird ); check "relative RV_SSH resolves from caller dir" 0 $?

# Image-build mode leaves an earlier verify's log alone.
echo keep > "$T/out8/rverify-probe.log"
env RV_GH_TOKEN=0 RV_BUILD_IMAGE=1 RV_SSH="$FSSH" RV_OUT_DIR="$T/out8" bash "$S/remote-verify.sh" "$R" probe firebird >/dev/null
check "image build keeps the verify log" keep "$(cat "$T/out8/rverify-probe.log")"
check "image build removes a stale .out" 1 "$(exists "$T/out8/rv-probe.out")"

# Pass-4 cases. A repo whose working copy has drifted from git's list:
# b.txt deleted, and tracked file d replaced by a directory of untracked files.
R2="$T/repo2"; mkdir -p "$R2"
git -C "$R2" init -q
echo a > "$R2/a.txt"; echo b > "$R2/b.txt"; echo d > "$R2/d"; echo u > "$R2/u.txt"
git -C "$R2" add a.txt b.txt d u.txt
git -C "$R2" -c user.email=t@t -c user.name=t commit -q -m init
rm "$R2/b.txt" "$R2/d"; mkdir "$R2/d"; echo secret > "$R2/d/secret.txt"
REPO="$R2" run 0 "$T/ship10"; check "locally deleted tracked file doesn't fail the ship" 0 $?
check "untracked file under a dir that replaced a tracked file not shipped" 1 "$(exists "$T/ship10/d/secret.txt")"
check "other tracked files still shipped" 0 "$(exists "$T/ship10/a.txt")"

# A submodule checkout is still shipped whole.
S3="$T/sub"; mkdir -p "$S3"; git -C "$S3" init -q; echo s > "$S3/s.txt"
git -C "$S3" add s.txt; git -C "$S3" -c user.email=t@t -c user.name=t commit -q -m s
git -C "$R2" -c protocol.file.allow=always submodule -q add "$S3" vendor 2>/dev/null
git -C "$R2" -c user.email=t@t -c user.name=t commit -q -m sub
echo stray > "$R2/vendor/stray.txt"
REPO="$R2" run 0 "$T/ship13" >/dev/null
check "submodule contents shipped" 0 "$(exists "$T/ship13/vendor/s.txt")"
check "untracked file inside a submodule not shipped" 1 "$(exists "$T/ship13/vendor/stray.txt")"
# Pass-7: a submodule's untracked file is named in the WARN, and the opt-in
# ships it (both red against 5807820).
grep -qx "  vendor/stray.txt" "$T/out/rverify-probe.log"; check "WARN names an untracked file inside a submodule" 0 $?
REPO="$R2" run 0 "$T/ship14" RV_INCLUDE_UNTRACKED=1 >/dev/null
check "RV_INCLUDE_UNTRACKED=1 ships a submodule's untracked file" 0 "$(exists "$T/ship14/vendor/stray.txt")"

# Pass-7: a git listing failure is 99, in both modes (a corrupt submodule
# index makes the recursive listing fail; red against 5807820).
R3="$T/repo3"; cp -R "$R2" "$R3"; echo garbage > "$R3/.git/modules/vendor/index"
REPO="$R3" OUTDIR="$T/out15" run 0 "$T/ship15" >/dev/null; check "git listing failure exits 99" 99 $?
REPO="$R3" OUTDIR="$T/out16" run 0 "$T/ship16" RV_INCLUDE_UNTRACKED=1 >/dev/null; check "git listing failure exits 99 with the opt-in" 99 $?

# Pass-7: a relative RV_OUT_DIR puts the .out and the log beside each other
# under the caller's cwd, not inside the worktree.
mkdir -p "$T/cwd/rel"
(cd "$T/cwd" && OUTDIR=rel run 0 "$T/ship17" >/dev/null); check "relative RV_OUT_DIR run exits 0" 0 $?
check "relative RV_OUT_DIR .out under the caller's cwd" "verify exit=0" "$(cat "$T/cwd/rel/rv-probe.out" 2>/dev/null)"
check "relative RV_OUT_DIR log under the caller's cwd" 0 "$(exists "$T/cwd/rel/rverify-probe.log")"

# Pass-8: a checked-out submodule marked inactive is still shipped (git's
# --recurse-submodules skips it; red against fdfd5b1).
git -C "$R2" config submodule.vendor.active false
REPO="$R2" run 0 "$T/ship18" >/dev/null
check "inactive submodule contents shipped" 0 "$(exists "$T/ship18/vendor/s.txt")"
git -C "$R2" config --unset submodule.vendor.active

# Pass-8: a nested repository that isn't a submodule is named in the log
# when the opt-in can't ship it.
mkdir -p "$R2/local-repo"; git -C "$R2/local-repo" init -q; echo n > "$R2/local-repo/n.txt"
REPO="$R2" OUTDIR="$T/out19" run 0 "$T/ship19" RV_INCLUDE_UNTRACKED=1 >/dev/null
grep -q "not shipping local-repo/" "$T/out19/rverify-probe.log"; check "nested repository named in the log" 0 $?
rm -rf "$R2/local-repo"

# Pass-9: a symlink where a submodule belongs is refused (it used to ship the
# link target's checkout, here outside the worktree), and a submodule with no
# checkout is named in the log (red against d831fdb).
R4="$T/repo4"; cp -R "$R2" "$R4"; rm -rf "$R4/vendor"; ln -s "$S3" "$R4/vendor"
REPO="$R4" OUTDIR="$T/out20" run 0 "$T/ship20" >/dev/null; check "symlinked submodule exits 99" 99 $?
check "symlinked submodule's target not shipped" 1 "$(exists "$T/ship20/vendor/s.txt")"
grep -q "submodule vendor is a symlink" "$T/out20/rverify-probe.log"; check "symlinked submodule named in the log" 0 $?
R5="$T/repo5"; cp -R "$R2" "$R5"; rm -rf "$R5/vendor"; mkdir "$R5/vendor"
REPO="$R5" OUTDIR="$T/out21" run 0 "$T/ship21" >/dev/null; check "submodule without a checkout still exits 0" 0 $?
grep -q "note: submodule vendor has no checkout" "$T/out21/rverify-probe.log"; check "submodule without a checkout named in the log" 0 $?

# Pass-11: the box is told which checked-out submodules to keep as gitlinks,
# innermost first (red against 14e5587).
S4="$T/inner"; mkdir -p "$S4"; git -C "$S4" init -q; echo i > "$S4/i.txt"
git -C "$S4" add i.txt; git -C "$S4" -c user.email=t@t -c user.name=t commit -q -m i
R8="$T/repo8"; cp -R "$R2" "$R8"
git -C "$R8/vendor" -c protocol.file.allow=always submodule -q add "$S4" deep 2>/dev/null
git -C "$R8/vendor" -c user.email=t@t -c user.name=t commit -q -m deep
REPO="$R8" OUTDIR="$T/out26" GITLINKS="$T/gl26" run 0 "$T/ship26" >/dev/null; check "nested submodules run exits 0" 0 $?
check "gitlinks list, innermost first" "vendor/deep|vendor|" "$(tr '\0' '|' < "$T/gl26" 2>/dev/null)"

# Pass-12: run the box's git setup itself on the shipped tree. An empty
# submodule ships no files, and a tracked file matching a .gitignore must
# stay tracked, in a submodule and at the top (red against d04df8c).
S5="$T/empty"; mkdir -p "$S5"; git -C "$S5" init -q
git -C "$S5" -c user.email=t@t -c user.name=t commit -q --allow-empty -m e
R9="$T/repo9"; cp -R "$R8" "$R9"
git -C "$R9" -c protocol.file.allow=always submodule -q add "$S5" empty 2>/dev/null
echo '*.log' > "$R9/vendor/.gitignore"; echo k > "$R9/vendor/keep.log"
git -C "$R9/vendor" add .gitignore; git -C "$R9/vendor" add -f keep.log
git -C "$R9/vendor" -c user.email=t@t -c user.name=t commit -q -m keep
echo '*.tmp' > "$R9/.gitignore"; echo t > "$R9/top.tmp"
git -C "$R9" add .gitignore vendor; git -C "$R9" add -f top.tmp
git -C "$R9" -c user.email=t@t -c user.name=t commit -q -m top
REPO="$R9" OUTDIR="$T/out27" GITLINKS="$T/gl27" CMDLOG="$T/cmd27" run 0 "$T/ship27" >/dev/null
check "box setup run exits 0" 0 $?
inner=$(sed -E "s/.*bash -c '//; s/ mkdir -p \/tmp\/bin.*//" "$T/cmd27" 2>/dev/null | sed "s|/m/gitlinks|$T/gl27|")
(cd "$T/ship27" && GIT_CONFIG_GLOBAL="$T/boxgitconfig" bash -c "$inner") >/dev/null 2>&1
check "box git setup succeeds with an empty submodule" 0 $?
check "empty submodule is a gitlink on the box" 160000 "$(git -C "$T/ship27" ls-files -s empty 2>/dev/null | cut -c1-6)"
check "nested submodule stays a gitlink" 160000 "$(git -C "$T/ship27/vendor" ls-files -s deep 2>/dev/null | cut -c1-6)"
check "ignored file tracked in a submodule stays tracked" keep.log "$(git -C "$T/ship27/vendor" ls-files keep.log 2>/dev/null)"
check "ignored file tracked at the top stays tracked" top.tmp "$(git -C "$T/ship27" ls-files top.tmp 2>/dev/null)"

# Pass-10: a file that replaced a submodule (unstaged) is shipped as itself
# (red against 1ddd75f).
R7="$T/repo7"; cp -R "$R2" "$R7"; rm -rf "$R7/vendor"; echo f > "$R7/vendor"
REPO="$R7" OUTDIR="$T/out25" run 0 "$T/ship25" >/dev/null; check "file replacing a submodule exits 0" 0 $?
check "file replacing a submodule shipped" 0 "$(exists "$T/ship25/vendor")"

# Pass-9: a filename that isn't valid in the caller's locale can't hide the
# untracked WARN (BSD tr stopped on it). Needs a non-UTF-8 locale installed.
if locale -a 2>/dev/null | grep -qx 'ja_JP.SJIS'; then
  R6="$T/repo6"; cp -R "$R" "$R6"; rm -rf "$R6/pkg"; touch "$R6/$(printf '\342\230\203')"
  REPO="$R6" OUTDIR="$T/out22" run 0 "$T/ship22" LC_ALL=ja_JP.SJIS >/dev/null
  grep -q "WARN: not shipping 1 untracked path" "$T/out22/rverify-probe.log"; check "WARN survives a filename invalid in the locale" 0 $?
else
  echo "skip WARN survives a filename invalid in the locale (no ja_JP.SJIS locale)"
fi

# Pass-9: early failures with a writable .out record their own code: 98 when
# the box setup fails, 97 when the worktree can't be entered.
OUTDIR="$T/out23" FAKE_SETUP_FAIL=1 run 0 "$T/ship23" >/dev/null; check "box setup failure exits 98" 98 $?
check "box setup failure .out" "verify exit=98" "$(cat "$T/out23/rv-probe.out" 2>/dev/null)"
REPO="$T/no-such-worktree" OUTDIR="$T/out24" run 0 "$T/ship24" >/dev/null 2>&1; check "missing worktree exits 97" 97 $?
check "missing worktree .out" "verify exit=97" "$(cat "$T/out24/rv-probe.out" 2>/dev/null)"

# A local tar failure is 99, not masked by ssh's 0. A tar stub that writes a
# good stream and then exits 2 keeps this independent of file permissions.
mkdir -p "$T/badtar"
printf '#!/bin/bash\n"%s" "$@"; exit 2\n' "$REAL_TAR" > "$T/badtar/tar"; chmod +x "$T/badtar/tar"
REPO="$R2" OUTDIR="$T/out11" RMLOG="$T/rm11" run 0 "$T/ship11" PATH="$T/badtar:$PATH"; check "local tar failure exits 99" 99 $?
# Pass-10: and the box copy is still cleaned up (red against 1ddd75f).
check "local tar failure cleans the box" cleanup "$(cat "$T/rm11" 2>/dev/null)"

# A FIFO log is opened once: a reader that stops at the first EOF still gets
# the whole run, and the script finishes instead of blocking on a second open.
mkdir -p "$T/out12"; mkfifo "$T/out12/rverify-probe.log"
cat "$T/out12/rverify-probe.log" > "$T/fifo.txt" & rpid=$!
# env execs bash, so $pid is the verifier itself.
env RV_INCLUDE_UNTRACKED=0 RV_BUILD_IMAGE=0 RV_GH_TOKEN=0 RV_SSH="$FSSH" RV_OUT_DIR="$T/out12" SHIP="$T/ship12" FAKE_RC=0 \
  bash "$S/remote-verify.sh" "$R" probe firebird & pid=$!
for _ in $(seq 1 100); do kill -0 "$pid" 2>/dev/null || break; sleep 0.1; done
if kill -0 "$pid" 2>/dev/null; then kill "$pid" "$rpid" 2>/dev/null; wait "$pid" "$rpid" 2>/dev/null; check "FIFO log run finishes" finished hung
else wait "$pid"; check "FIFO log run finishes" 0 $?; fi
# Reap the reader before reading what it wrote (bounded: kill if it lingers).
for _ in $(seq 1 50); do kill -0 "$rpid" 2>/dev/null || break; sleep 0.1; done
kill "$rpid" 2>/dev/null; wait "$rpid" 2>/dev/null
grep -q "remote rc=0" "$T/fifo.txt"; check "FIFO reader saw the whole log" 0 $?

# Pass-13: after the stream the script records what was shipped, computed like
# the header, so a stamp cannot be written for a tree that changed meanwhile.
R13="$T/repo13"; mkdir -p "$R13"
git -C "$R13" init -q
echo tracked > "$R13/a.txt"
git -C "$R13" add a.txt
git -C "$R13" -c user.email=t@t -c user.name=t commit -q -m init
H13=$(git -C "$R13" rev-parse HEAD)
REPO="$R13" OUTDIR="$T/out13" run 0 "$T/ship13b"; check "clean run exits 0" 0 $?
check "log has the header first" "host=firebird head=$H13 dirty=0" "$(sed -n 1p "$T/out13/rverify-probe.log")"
check "log has one shipped line" 1 "$(grep -c '^shipped head=' "$T/out13/rverify-probe.log")"
check "shipped line says head and dirty=0" "shipped head=$H13 dirty=0" "$(grep '^shipped head=' "$T/out13/rverify-probe.log")"
# An edit made while the stream runs shows in the shipped line, not the header.
REPO="$R13" OUTDIR="$T/out14" run 0 "$T/ship14b" EDIT_FILE="$R13/a.txt"; check "edit during stream: run still exits 0" 0 $?
check "edit during stream: header dirty=0" "host=firebird head=$H13 dirty=0" "$(sed -n 1p "$T/out14/rverify-probe.log")"
check "edit during stream: shipped line dirty=1" "shipped head=$H13 dirty=1" "$(grep '^shipped head=' "$T/out14/rverify-probe.log")"
git -C "$R13" checkout -q a.txt
# A failed ship writes no shipped line.
REPO="$R2" OUTDIR="$T/out15" run 0 "$T/ship15" PATH="$T/badtar:$PATH" >/dev/null
check "failed ship has no shipped line" 0 "$(grep -c '^shipped head=' "$T/out15/rverify-probe.log")"

exit $fail
