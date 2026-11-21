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
# not shipped", "log WARNs about the untracked file").
#
# Usage: bash pr-drain/tests/remote-verify.test.sh   (exit 0 = all pass)
set -u
S=${PROBE_S:-"$(cd "$(dirname "$0")/../scripts" && pwd)"}
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
fail=0
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

cat > "$T/fake-ssh" <<'FAKE'
#!/bin/bash
cmd="$*"
case "$cmd" in
  *"tar -xzf -"*) mkdir -p "$SHIP" && tar -xzf - -C "$SHIP" ;;
  *"git init -q"*) exit "$FAKE_RC" ;;
  *) exit 0 ;;
esac
FAKE
chmod +x "$T/fake-ssh"

run() { # rc ship-dir [env...]
  local rc=$1 ship=$2; shift 2
  env RV_SSH="$T/fake-ssh" RV_OUT_DIR="$T/out" SHIP="$ship" FAKE_RC="$rc" "$@" \
    bash "$S/remote-verify.sh" "$R" probe firebird
}

run 1 "$T/ship1"; check "exit code = 1 on failed verify" 1 $?
check ".out records the failure" "verify exit=1" "$(cat "$T/out/rv-probe.out")"
[ -f "$T/ship1/pkg/.vitest/json/output.json" ]; check "untracked file not shipped" 1 $?
[ -f "$T/ship1/a.txt" ]; check "tracked file shipped" 0 $?
grep -q "WARN: not shipping 1 untracked file" "$T/out/rverify-probe.log"; check "log WARNs about the untracked file" 0 $?

# Passing control: a script that always failed would pass the checks above.
run 0 "$T/ship2"; check "exit code = 0 on passed verify" 0 $?

run 0 "$T/ship3" RV_INCLUDE_UNTRACKED=1; check "opt-in run exits 0" 0 $?
[ -f "$T/ship3/pkg/.vitest/json/output.json" ]; check "RV_INCLUDE_UNTRACKED=1 ships untracked" 0 $?

exit $fail
