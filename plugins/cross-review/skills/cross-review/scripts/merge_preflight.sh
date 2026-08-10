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
gh_args=("$pr" --json comments,headRefOid,state)
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

# The newest cross-review comment wins. Earlier passes are superseded by later
# ones by construction: pass 2 exists precisely because pass 1's findings were
# addressed. Selecting the newest, rather than requiring all of them to match,
# is what lets a re-review clear a stale gate.
#
# `## Cross-review` is post_comment.sh's own header (see its summary mode). It
# is matched at the start of the body so that a human quoting the header inside
# a discussion comment does not register as a review record.
review_body="$(printf '%s' "$pr_json" \
  | jq -r '[.comments[]? | select((.body // "") | startswith("## Cross-review"))] | last | .body // ""' \
  2>/dev/null || true)"

if [[ -z "$review_body" ]]; then
  emit unreviewed 0 "no cross-review record on PR #$pr — nothing to contradict the merge."
fi

# post_comment.sh prints the SHA abbreviated to 9 chars: Reviewed `abc123def`.
reviewed_sha="$(printf '%s' "$review_body" \
  | sed -nE 's/.*Reviewed `([0-9a-f]{7,40})`.*/\1/p' | head -1)"

if [[ -z "$reviewed_sha" ]]; then
  emit unbound 0 "PR #$pr has a cross-review record with no SHA stamp (posted before --head-sha existed) — cannot verify; not blocking."
fi

# Compare on the stamp's own width. The stamp is abbreviated; headRefOid is not.
n="${#reviewed_sha}"
if [[ "${cur_sha:0:$n}" == "$reviewed_sha" ]]; then
  emit clear 0 "PR #$pr was reviewed at its current head ${cur_sha:0:9}."
fi

emit stale 1 "PR #$pr was reviewed at $reviewed_sha but its head is now ${cur_sha:0:9}. The review record does not cover the code you are about to merge. Re-run cross-review, or merge deliberately knowing the delta is unreviewed."
