#!/bin/bash
# poll-ci-newest-run.test.sh — pins that poll-ci.sh judges each required check
# by its NEWEST run, whatever order the API returns rows in.
#
# A mock `gh` on PATH serves canned check-runs / status JSON and applies the
# caller's --jq filter with real jq, so the filter under test is poll-ci.sh's
# own. Dry-run mode: a pass prints WOULD_MERGE and never calls merge.
#
# Red control (run 2026-09-24): against the pre-fix poll-ci.sh (PROBE_S), 3 of
# 7 checks fail. It declares TERMINAL_FAIL on a stale cancelled run listed
# first (the #3982 stall). It prints WOULD_MERGE when an older success is
# listed before a newer failure. And its default list omitted
# "CI definition matches base", so it called that check's failure green. The
# last two relied on branch protection to refuse the merge.
#
# Usage: bash pr-drain/tests/poll-ci-newest-run.test.sh   (exit 0 = all pass)
set -u
S=${PROBE_S:-"$(cd "$(dirname "$0")/../scripts" && pwd)"}
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
SHA=0123456789abcdef0123456789abcdef01234567
mkdir -p "$T/bin"
cat > "$T/bin/gh" <<'MOCK'
#!/bin/bash
# Minimal gh stand-in for poll-ci.sh: pr view, api (check-runs|status), pr merge.
filter=""; prev=""
for a in "$@"; do [ "$prev" = "--jq" ] && filter="$a"; prev="$a"; done
case "$1 $2" in
  "pr view") echo "$MOCK_SHA" ;;
  "pr merge") echo "MERGE_CALLED" >> "$MOCK_DIR/merge.log"; exit 0 ;;
  api*)
    case "$2" in
      *check-runs*) jq -r "$filter" "$MOCK_DIR/runs.json" ;;
      *status*) jq -r "$filter" "$MOCK_DIR/status.json" ;;
    esac ;;
esac
MOCK
chmod +x "$T/bin/gh"
export PATH="$T/bin:$PATH" MOCK_SHA="$SHA" MOCK_DIR="$T" PR_DRAIN_DRY_RUN=1
echo '{"statuses":[{"context":"cross-review/current","state":"success","description":"reviewed at 0123456"}]}' > "$T/status.json"

fail=0
run_case() { # name expected_rc runs_json
  printf '%s' "$3" > "$T/runs.json"
  out=$(bash "$S/poll-ci.sh" o/r 1 "$SHA" 0 1 2>&1); rc=$?
  if [ "$rc" = "$2" ]; then echo "ok   $1 (rc=$rc)"; else echo "FAIL $1 expected rc=$2 got rc=$rc :: $out"; fail=1; fi
}
ok() { printf '{"id":%s,"name":"%s","status":"completed","conclusion":"%s"}' "$1" "$2" "$3"; }

base="$(ok 10 'Dagger Pipeline' success),$(ok 11 'Semgrep Scan' success),$(ok 12 'PR Guards' success)"
CI='CI definition matches base'

# Ordering cases: the check list is explicit so they test run selection alone.
export PR_DRAIN_CHECKS="Dagger Pipeline,Semgrep Scan,PR Guards,$CI"
# The #3982 shape: a stale cancelled attempt listed BEFORE the newer success.
run_case "stale cancelled listed first, newest success" 0 \
  "{\"check_runs\":[$base,$(ok 20 "$CI" cancelled),$(ok 21 "$CI" success)]}"
# Same runs, API order reversed.
run_case "newest success listed first" 0 \
  "{\"check_runs\":[$(ok 21 "$CI" success),$(ok 20 "$CI" cancelled),$base]}"
# The dangerous direction: an older success listed before a NEWER failure.
run_case "older success listed first, newest failure" 2 \
  "{\"check_runs\":[$base,$(ok 20 "$CI" success),$(ok 21 "$CI" failure)]}"
run_case "newest failure listed first" 2 \
  "{\"check_runs\":[$base,$(ok 21 "$CI" failure),$(ok 20 "$CI" success)]}"
# A required check that has not reported yet keeps polling (times out here, rc=5).
run_case "required check absent" 5 "{\"check_runs\":[$base]}"

# Defaults: kindred-mama-ai requires "CI definition matches base", so the
# default list must include it or the poller calls a red head green.
unset PR_DRAIN_CHECKS
run_case "default checks include '$CI'" 2 \
  "{\"check_runs\":[$base,$(ok 21 "$CI" failure)]}"

[ ! -e "$T/merge.log" ]; if [ $? = 0 ]; then echo "ok   dry-run never called merge"; else echo "FAIL dry-run called merge"; fail=1; fi
exit $fail
