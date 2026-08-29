#!/usr/bin/env bash
# merge_preflight.sh — answer one question: is this PR's newest cross-review
# record bound to the commit that is about to be merged?
#
# post_comment.sh --head-sha stamps every review comment with the SHA it
# actually reviewed, and warns when the head moved mid-review. That stamp is a
# sensor with nothing wired to it: an agent merging the PR never reads it. This
# script is the reader. Pair it with hooks/merge_gate.sh to make it binding.
#
#   merge_preflight.sh --pr 123 [--repo owner/name] [--json]
#
# Exit codes:
#   0  clear to merge — reviewed at the current head, OR no review record to
#      contradict it (see "green when absent" below), OR the check could not run
#   1  STALE — a review record exists and is bound to a DIFFERENT commit
#   2  usage error
#
# Green when absent, by design. A PR with no cross-review comment exits 0. This
# is a safety net over the reviews you already run, not a mandate that every PR
# be reviewed — making it a mandate is a policy decision, and a gate that
# silently becomes one would be the wrong kind of surprise.
#
# Fails OPEN everywhere else too: no gh, no jq, no auth, API error, malformed
# JSON all exit 0 with a note on stderr. A gate that blocks merges whenever
# GitHub hiccups gets disabled within a day, and then it protects nothing.

set -uo pipefail

pr=""
repo=""
as_json=0

need_val() {
  # $1 flag name, $2 remaining arg count
  if [[ "$2" -lt 2 ]]; then
    echo "$1 requires a value" >&2
    exit 2
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --pr) need_val --pr "$#"; pr="$2"; shift 2 ;;
    --repo) need_val --repo "$#"; repo="$2"; shift 2 ;;
    --json) as_json=1; shift ;;
    -h|--help)
      sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) echo "unknown flag: $1" >&2; exit 2 ;;
  esac
done

if [[ -z "$pr" ]]; then
  echo "--pr is required" >&2
  exit 2
fi

# `gh pr view` accepts a number, URL, or branch. Anything is fine here except
# an empty string, which it would interpret as "the current branch's PR" and
# silently answer a question nobody asked.
gh_args=("$pr" --json comments,headRefOid,baseRefName,state,number,url)
[[ -n "$repo" ]] && gh_args+=(--repo "$repo")

emit() {
  # emit <status> <exit_code> <reason>
  local status="$1" code="$2" reason="$3"
  if [[ "$as_json" -eq 1 ]]; then
    if command -v jq >/dev/null 2>&1; then
      jq -nc --arg s "$status" --arg p "$pr" --arg h "${cur_sha:-}" \
             --arg r "${reviewed_sha:-}" --arg m "$reason" \
        '{status:$s, pr:$p, head:$h, reviewed:$r, reason:$m}'
    else
      # jq is how we got here in the first place on the indeterminate path;
      # keep --json honest rather than emitting nothing.
      printf '{"status":"%s","pr":"%s","reason":"%s"}\n' "$status" "$pr" "$reason"
    fi
  else
    printf '%s: %s\n' "$status" "$reason"
  fi
  exit "$code"
}

cur_sha=""
reviewed_sha=""

if ! command -v gh >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
  emit indeterminate 0 "gh or jq unavailable — cannot check review binding; not blocking."
fi

pr_json="$(gh pr view "${gh_args[@]}" 2>/dev/null || true)"
if [[ -z "$pr_json" ]]; then
  emit indeterminate 0 "could not read PR #$pr (auth? network? wrong repo?) — not blocking."
fi

cur_sha="$(printf '%s' "$pr_json" | jq -r '.headRefOid // ""' 2>/dev/null || true)"
pr_state="$(printf '%s' "$pr_json" | jq -r '.state // ""' 2>/dev/null || true)"

if [[ -z "$cur_sha" ]]; then
  emit indeterminate 0 "PR #$pr returned no headRefOid — not blocking."
fi

if [[ "$pr_state" == "MERGED" || "$pr_state" == "CLOSED" ]]; then
  emit closed 0 "PR #$pr is $pr_state — nothing left to gate."
fi

# `gh pr view --json comments` issues `comments(first: 100)` — verified with
# GH_DEBUG=api on gh 2.96.0. That is the OLDEST hundred, so past that mark the
# newest review is simply absent and this script would reason about an obsolete
# stamp. At exactly the cap, re-fetch the full list through the paginating REST
# endpoint. Fails open like everything else: if the refetch cannot run, we keep
# whatever the capped query returned.
comments_json="$(printf '%s' "$pr_json" | jq -c '[.comments[]? | {body: (.body // "")}]' 2>/dev/null || printf '[]')"
if [[ "$(printf '%s' "$comments_json" | jq 'length' 2>/dev/null || echo 0)" -ge 100 ]]; then
  owner_repo="${repo:-}"
  [[ -z "$owner_repo" ]] && owner_repo="$(printf '%s' "$pr_json" | jq -r '.url // ""' 2>/dev/null | sed -nE 's#^https?://[^/]+/([^/]+/[^/]+)/pull/.*#\1#p')"
  pr_number="$(printf '%s' "$pr_json" | jq -r '.number // ""' 2>/dev/null || true)"
  if [[ -n "$owner_repo" && -n "$pr_number" ]]; then
    # `--slurp` is NOT compatible with `--jq`: gh exits with "the `--slurp`
    # option is not supported with `--jq` or `--template`". Combining them made
    # this branch a no-op — it always fell back to the capped list, so the
    # pagination fix shipped in #50 never actually paginated. The test only
    # asserted that `api --paginate` appeared in the recorded arguments, which
    # is a statement about the call being ATTEMPTED, not about it working.
    # Shape the JSON in a separate jq, never in gh's --jq.
    full="$(gh api --paginate --slurp "repos/$owner_repo/issues/$pr_number/comments" 2>/dev/null \
              | jq -c '[.[][] | {body: (.body // "")}]' 2>/dev/null || true)"
    [[ -n "$full" && "$full" != "[]" ]] && comments_json="$full"
  fi
fi

# The newest **stamped** record wins. Earlier passes are superseded by later
# ones by construction: pass 2 exists precisely because pass 1's findings were
# addressed. Selecting the newest is what lets a re-review clear a stale gate.
#
# Unstamped cross-review comments are skipped rather than selected. Taking the
# newest comment of any kind meant one unstamped record — which post_comment.sh
# still produces when `--head-sha` is omitted — reported `unbound` and switched
# the gate off while a stale stamped record sat right behind it. A comment that
# carries no SHA carries no information about coverage; it must not outvote one
# that does.
#
# `## Cross-review` is post_comment.sh's own header (see its summary mode),
# matched at the start of the body so a human quoting the header in a
# discussion comment does not register as a review record.
STAMP_RE='Reviewed `[0-9a-f]{7,40}`'
review_body="$(printf '%s' "$comments_json" \
  | jq -r --arg re "$STAMP_RE" \
      '[.[] | .body | select(startswith("## Cross-review")) | select(test($re))] | last // ""' \
  2>/dev/null || true)"

if [[ -z "$review_body" ]]; then
  # Distinguish "nobody reviewed this" from "a review exists but predates the
  # stamp" — same exit code, materially different things to tell a human.
  any_review="$(printf '%s' "$comments_json" \
    | jq -r '[.[] | .body | select(startswith("## Cross-review"))] | length' 2>/dev/null || echo 0)"
  if [[ "${any_review:-0}" -gt 0 ]]; then
    emit unbound 0 "PR #$pr has cross-review records but none carries a SHA stamp (posted before --head-sha existed) — cannot verify; not blocking."
  fi
  emit unreviewed 0 "no cross-review record on PR #$pr — nothing to contradict the merge."
fi

# ONE parser for the stamp (read_stamp.sh): the marker is authoritative and the
# prose is the fallback. Reading the prose here while currency/coverage read
# the marker let a record corrected in the marker alone clear on a superseded
# prose sha (codex High + spark, PR #67 review).
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
reviewed_sha=""
if [[ -x "$here/read_stamp.sh" ]]; then
  reviewed_sha="$(printf '%s' "$review_body" | bash "$here/read_stamp.sh" --body-stdin 2>/dev/null | jq -r '.sha // ""' 2>/dev/null || true)"
fi
# post_comment.sh prints the SHA abbreviated to 9 chars: Reviewed `abc123def`.
[[ -n "$reviewed_sha" ]] || reviewed_sha="$(printf '%s' "$review_body" \
  | sed -nE 's/.*Reviewed `([0-9a-f]{7,40})`.*/\1/p' | head -1)"

# Compare on the stamp's own width. The stamp is abbreviated; headRefOid is not.
n="${#reviewed_sha}"
if [[ "${cur_sha:0:$n}" == "$reviewed_sha" ]]; then
  emit clear 0 "PR #$pr was reviewed at its current head ${cur_sha:0:9}."
fi

# ---------------------------------------------------------------------------
# The head moved. That is NOT the same as "unreviewed", and treating it as such
# is what made this gate a treadmill: every fix answering a finding moves the
# head, so the record containing the finding stops covering the code, and the
# only exits are another full round or an override. Three rounds on PR #66 hit
# this in one session.
#
# So before declaring staleness, ask the question that actually matters -- is
# every commit in this PR covered by SOME record? Round 1 covers base..A,
# round 2 covers A..B, round 3 covers B..head: no single record covers the PR,
# together they cover all of it.
#
# Strictly additive. Point equality above still clears exactly what it always
# cleared; this runs only where the gate previously said `stale` outright, and
# falls through to that same verdict when coverage is genuinely incomplete.
if [[ -x "$here/read_stamp.sh" && -x "$here/range_coverage.sh" ]] && command -v git >/dev/null 2>&1; then
  # EVERY stamped record, not just the newest -- the union is the whole point.
  records="[]"
  while IFS= read -r b64; do
    [[ -z "$b64" ]] && continue
    body="$(printf '%s' "$b64" | base64 --decode 2>/dev/null || true)"
    [[ -z "$body" ]] && continue
    st="$(printf '%s' "$body" | bash "$here/read_stamp.sh" --body-stdin 2>/dev/null || true)"
    [[ -z "$st" ]] && continue
    if [[ "$(jq -r '.stamped' <<<"$st" 2>/dev/null)" == "true" ]]; then
      records="$(jq -c --argjson r "$st" '. + [{sha:$r.sha, base:$r.base, digest:$r.digest}]' <<<"$records")"
    fi
  done < <(printf '%s' "$comments_json" \
             | jq -r '.[] | .body | select(startswith("## Cross-review")) | @base64' 2>/dev/null || true)

  base_ref="$(printf '%s' "$pr_json" | jq -r '.baseRefName // ""' 2>/dev/null || true)"
  pr_base=""
  for cand in "origin/$base_ref" "$base_ref"; do
    [[ -n "$base_ref" ]] || break
    if git rev-parse --verify -q "$cand^{commit}" >/dev/null 2>&1; then
      pr_base="$(git merge-base "$cand" "$cur_sha" 2>/dev/null || true)"
      [[ -n "$pr_base" ]] && break
    fi
  done

  if [[ -n "$pr_base" ]] && [[ "$(jq 'length' <<<"$records")" -gt 0 ]]; then
    cov="$(bash "$here/range_coverage.sh" --base "$pr_base" --head "$cur_sha" --records "$records" 2>/dev/null || true)"
    if [[ "$(jq -r '.covered // false' <<<"$cov" 2>/dev/null)" == "true" ]]; then
      emit clear 0 "PR #$pr: head moved to ${cur_sha:0:9}, but $(jq -r '.reason' <<<"$cov") — the union of review records covers every commit being merged."
    fi
    ncov="$(jq -r '.uncovered | length' <<<"$cov" 2>/dev/null || echo 0)"
    if [[ "${ncov:-0}" -gt 0 ]]; then
      first_un="$(jq -r '.uncovered[0]' <<<"$cov" 2>/dev/null)"
      emit stale 1 "PR #$pr: $(jq -r '.reason' <<<"$cov"). Unreviewed, starting at: ${first_un}. Re-run cross-review on the uncovered range, or merge deliberately knowing it is unreviewed."
    fi
  fi
fi

emit stale 1 "PR #$pr was reviewed at $reviewed_sha but its head is now ${cur_sha:0:9}. The review record does not cover the code you are about to merge. Re-run cross-review, or merge deliberately knowing the delta is unreviewed."
