#!/usr/bin/env bash
# fallback_eligible.sh — decide whether a failed reviewer lap may be re-run over
# OpenRouter. Prints the reason on stdout and exits 0 when eligible; exits 1
# otherwise (printing nothing).
#
# Standalone ON PURPOSE. It started life inline in run_reviewers.sh, where the
# only tests possible were greps for source text — and the PR #66 review pointed
# out those greps still pass if the guard is negated or the call is unreachable.
# A separate entrypoint can be driven with fixtures and asserted on BEHAVIOUR.
#
# Usage:
#   fallback_eligible.sh --name <reviewer> --rc <exit-code> --out <run-dir>
#
# Eligibility is deliberately NARROW. A false positive is not free: it spends
# real money on a paid re-run, prints "PRIMARY PROVIDER NEEDS ATTENTION" about a
# healthy provider, and writes a `fallback` row into the reliability record this
# whole feature exists to keep honest. When unsure, say no.
set -uo pipefail

name="" ; rc="" ; out="."
while [[ $# -gt 0 ]]; do
  case "$1" in
    --name) name="$2"; shift 2 ;;
    --rc)   rc="$2";   shift 2 ;;
    --out)  out="$2";  shift 2 ;;
    *) echo "fallback_eligible: unknown arg $1" >&2; exit 2 ;;
  esac
done
[[ -n "$name" && -n "$rc" ]] || { echo "usage: --name <r> --rc <n> [--out <dir>]" >&2; exit 2; }

# A success is never eligible.
[[ "$rc" == "0" ]] && exit 1

# A timeout is never eligible: the budget was spent, and re-spending it on
# another rail buys the same outcome twice. 137 is timeout's -k SIGKILL.
[[ "$rc" == "124" || "$rc" == "137" ]] && exit 1

# rc=3 is agy's quota signal and ONLY agy's. It used to be honoured for every
# seat, so a codex/kimi/kimi3 exit 3 for any unrelated reason bought a paid
# re-run mislabelled "quota_exhausted". (codex + glm convergent, PR #66.)
if [[ "$rc" == "3" ]]; then
  case "$name" in
    antigravity|gemini-pro) echo "quota_exhausted"; exit 0 ;;
    *) exit 1 ;;
  esac
fi

blob=""
for f in "$out/$name.stdout" "$out/$name.stderr"; do
  [[ -f "$f" ]] && blob+="$(head -c 4000 "$f" 2>/dev/null)"$'\n'
done

# ANCHORED patterns only. The first cut matched bare `429`, `401`, `403` and
# `authentication` anywhere in the first 4KB of reviewer output -- but reviewers
# emit prose ABOUT code, and a diff discussing HTTP status handling, a byte
# count, or a timing like "4290ms" contains those substrings innocently. This
# repo's own files match them. So every numeric code now requires an HTTP-error
# context, and bare "authentication"/"unauthorized" are gone.
# (glm High + codex Medium, convergent, PR #66.)
# TOKEN-ANCHORED. The first rewrite required only that an HTTP-ish prefix and
# the digits appear on the same line with optional separators -- which still
# matched "request status: 4290ms elapsed" (429 taken from inside 4290),
# "wrote http 4031 bytes", and "error code: 4295 items". All four were
# demonstrated live. So: at least one separator, and the code must not be
# followed by another digit. Likewise "account" needs a boundary on BOTH sides
# or "the accountability suspended clause" reads as a suspended account.
# (kimi High, PR #66 delta -- second defect of this class on this matcher.)
# THIRD defect of this class, same matcher (codex Medium + kimi3 Low, PR #66
# delta-2). Anchoring on [[:space:]:] was too tight in one direction and the
# optional post-"account" boundary too loose in the other. Verified live:
#   HTTP/2 429, HTTP/1.1 429, status=429, HTTP/2 401, status=403  -> all MISSED
#   accountsuspended                                              -> matched
#   accounts suspended / accounts were suspended                  -> MISSED
# So the separator is now any run of non-alphanumerics plus an optional HTTP
# version token (/2, /1.1), the plural is allowed, and the delimiter after
# "account" is MANDATORY. The trailing ([^0-9]|$) guard is what still rejects
# "4290ms elapsed" and "http 4031 bytes" -- keep it when touching this.
if grep -Eqi 'usage limit|insufficient balance|(^|[^[:alnum:]])accounts?[^[:alnum:]].{0,40}suspend|exceeded_current_quota|quota exceeded' <<<"$blob"; then
  echo "account_limit"; exit 0
fi
if grep -Eqi '(error code|http(/[0-9.]+)?|status( code)?)[^[:alnum:]]+429([^0-9]|$)|429 too many requests' <<<"$blob"; then
  echo "rate_limited"; exit 0
fi
if grep -Eqi '(error code|http(/[0-9.]+)?|status( code)?)[^[:alnum:]]+40[13]([^0-9]|$)|401 unauthorized|403 forbidden|authentication failed|invalid[[:space:]_-]*api[[:space:]_-]*key' <<<"$blob"; then
  echo "auth_failed"; exit 0
fi

# agy's SIGSEGV panic is a client-side bug, so a different rail genuinely fixes
# it. Structural signal, not text matching.
meta="$out/$name.meta.json"
if [[ -f "$meta" ]] && command -v jq >/dev/null 2>&1; then
  if [[ "$(jq -r '.failure_kind // empty' "$meta" 2>/dev/null)" == "agy_panic" ]]; then
    echo "agy_panic"; exit 0
  fi
fi

exit 1
