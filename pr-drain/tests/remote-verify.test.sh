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
# pass-1 fix commit.
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
  *"tar -xzf -"*) mkdir -p "$SHIP" && tar -xzf - -C "$SHIP" ;;
  *"git init -q"*) exit "$FAKE_RC" ;;
  *"mkdir -p $"*|*"mkdir -p /"*) [ -n "${FAKE_SETUP_FAIL:-}" ] && exit 1; exit 0 ;;
  *) exit 0 ;;
esac
FAKE
chmod +x "$FSSH"

run() { # rc ship-dir [env...]
  local rc=$1 ship=$2; shift 2
  # Pin the knobs a caller's shell may have exported; cases override after.
  env RV_INCLUDE_UNTRACKED=0 RV_BUILD_IMAGE=0 RV_GH_TOKEN=0 RV_SSH="$FSSH" RV_OUT_DIR="${OUTDIR:-$T/out}" SHIP="$ship" FAKE_RC="$rc" "$@" \
    bash "$S/remote-verify.sh" "$R" probe firebird
}

run 1 "$T/ship1"; check "exit code = 1 on failed verify" 1 $?
check ".out records the failure" "verify exit=1" "$(cat "$T/out/rv-probe.out")"
check "untracked file not shipped" 1 "$(exists "$T/ship1/pkg/.vitest/json/output.json")"
check "tracked file shipped" 0 "$(exists "$T/ship1/a.txt")"
grep -q "WARN: not shipping 1 untracked file" "$T/out/rverify-probe.log"; check "log WARNs about the untracked file" 0 $?

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

exit $fail
