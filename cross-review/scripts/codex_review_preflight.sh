#!/usr/bin/env bash
# codex_review_preflight.sh — answer one question: does Codex (the
# chatgpt-codex-connector GitHub app) still have something to say about this
# PR that nobody has answered?
#
#   codex_review_preflight.sh --pr 123 [--repo owner/name] [--json]
#
# Two things block:
#   * A review thread opened by Codex that is not CLEARED — any severity,
#     outdated or not. "Outdated" only means the lines under it moved; it says
#     nothing about whether the finding was fixed. A thread clears when it is
#     resolved AND someone other than Codex has replied on it (the fix commit,
#     or why it does not apply) — or when Codex resolved it itself. Resolution
#     alone is one click an agent can make without reading the finding; the
#     reply is what turns that click into a record someone can audit. On
#     2026-09-24 all 91 Codex threads on the last 94 merged gothicpixie PRs had
#     been merged open with no reply (24 of them P1); that is the failure this
#     exists for.
#   * A Codex review still RUNNING, per Codex's own summary comment, that began
#     less than CODEX_GATE_RUNNING_TTL seconds ago (default 1800). Merging
#     mid-review lands the code before its findings exist. Past the TTL the run
#     is treated as hung and does not block: gothicpixie/toss-core #20 has sat
#     at "Running" for two days, and a gate that waits on a dead review forever
#     gets switched off.
#
# Exit codes:
#   0  clear to merge — every Codex thread cleared and nothing running, OR Codex never
#      touched this PR (absent), OR the check could not run (indeterminate),
#      OR the PR is already merged/closed
#   1  BLOCKED
#   2  usage error
#
# Green when absent, like merge_preflight.sh: a repo without the Codex app
# installed has no threads and no summary comment, and must not be blocked.
#
# Fails OPEN on everything else — no gh, no jq, no auth, API error, malformed
# JSON — for the reason merge_preflight.sh gives: a gate that blocks merges
# whenever GitHub hiccups gets disabled within a day. Each sensor fails open on
# its own, so an unreadable summary comment does not hide an open thread.
#
# Environment:
#   CODEX_GATE_BOT_RE          author-login regex for Codex (default: the app)
#   CODEX_GATE_RUNNING_TTL     seconds a "Running" review blocks (default 1800)
#   CODEX_GATE_NOW             epoch seconds to use as "now" (test seam)

set -uo pipefail

pr=""
repo=""
as_json=0

need_val() {
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
      sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) echo "unknown flag: $1" >&2; exit 2 ;;
  esac
done

if [[ -z "$pr" ]]; then
  echo "--pr is required" >&2
  exit 2
fi

# GraphQL returns bot logins bare; REST appends [bot]. Match both.
BOT_RE="${CODEX_GATE_BOT_RE:-^chatgpt-codex-connector(\\[bot\\])?\$}"
TTL="${CODEX_GATE_RUNNING_TTL:-1800}"
case "$TTL" in ''|*[!0-9]*) TTL=1800 ;; esac
NOW="${CODEX_GATE_NOW:-}"
case "$NOW" in *[!0-9]*) NOW="" ;; esac

owner_repo=""
cur_sha=""
uncleared_json="[]"
running_json="[]"

emit() {
  # emit <status> <exit_code> <reason>
  local status="$1" code="$2" reason="$3"
  if [[ "$as_json" -eq 1 ]]; then
    if command -v jq >/dev/null 2>&1; then
      jq -nc --arg s "$status" --arg p "$pr" --arg repo "$owner_repo" \
             --arg h "$cur_sha" --arg m "$reason" \
             --argjson u "$uncleared_json" --argjson r "$running_json" \
        '{status:$s, pr:$p, repo:$repo, head:$h, reason:$m, uncleared:$u, running:$r}'
    else
      printf '{"status":"%s","pr":"%s","reason":"%s"}\n' "$status" "$pr" "$reason"
    fi
  else
    printf '%s: %s\n' "$status" "$reason"
  fi
  exit "$code"
}

if ! command -v gh >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
  emit indeterminate 0 "gh or jq unavailable — cannot read Codex review state; not blocking."
fi

# Resolve whatever the caller passed (number, URL, branch) to a concrete PR.
# An empty ref would mean "the current branch's PR" — guarded above.
gh_args=("$pr" --json number,url,state,headRefOid)
[[ -n "$repo" ]] && gh_args+=(--repo "$repo")
pr_json="$(gh pr view "${gh_args[@]}" 2>/dev/null || true)"
[[ -n "$pr_json" ]] || emit indeterminate 0 "could not read PR #$pr (auth? network? wrong repo?) — not blocking."

cur_sha="$(printf '%s' "$pr_json" | jq -r '.headRefOid // ""' 2>/dev/null || true)"
pr_state="$(printf '%s' "$pr_json" | jq -r '.state // ""' 2>/dev/null || true)"
number="$(printf '%s' "$pr_json" | jq -r '.number // ""' 2>/dev/null || true)"
[[ -z "$number" && "$pr" =~ ^[0-9]+$ ]] && number="$pr"

if [[ "$pr_state" == "MERGED" || "$pr_state" == "CLOSED" ]]; then
  emit closed 0 "PR #$pr is $pr_state — nothing left to gate."
fi

# The PR's own URL names its repository authoritatively; --repo may carry a
# host prefix gh accepts but GraphQL does not.
owner_repo="$(printf '%s' "$pr_json" | jq -r '.url // ""' 2>/dev/null \
  | sed -nE 's#^https?://[^/]+/([^/]+/[^/]+)/pull/.*#\1#p')"
[[ -z "$owner_repo" ]] && owner_repo="$(printf '%s' "$repo" | sed -E 's#^https?://##; s#\.git$##' | awk -F/ 'NF>=2 {print $(NF-1) "/" $NF}')"

if [[ ! "$owner_repo" =~ ^[^/]+/[^/]+$ || ! "$number" =~ ^[0-9]+$ ]]; then
  emit indeterminate 0 "could not resolve PR #$pr to owner/repo and number — not blocking."
fi
owner="${owner_repo%%/*}"
name="${owner_repo#*/}"

# `gh pr view` honours a HOST/OWNER/REPO --repo; `gh api` needs the host said
# again or it asks the default host about someone else's PR (codex P2, pass 5).
host="$(printf '%s' "$pr_json" | jq -r '.url // ""' 2>/dev/null | sed -nE 's#^https?://([^/]+)/.*#\1#p')"
host_args=()
[[ -n "$host" && "$host" != "github.com" ]] && host_args=(--hostname "$host")

# ── Sensor 2 (read BEFORE and AFTER the threads): a Codex review in flight ──
# The summary is read on both sides of the thread query, and a review running
# in EITHER read blocks. Before: Codex posts its findings, then marks the
# review Completed, so a Completed seen first means its findings are in the
# threads read next — reading threads first let a review finishing in between
# look clear (codex P1, pass 5). After: a review that STARTS between the reads
# has posted nothing yet, and only a second look sees it running (codex P1,
# pass 6).
# Codex keeps ONE summary comment per PR, marked with an HTML comment, and
# rewrites its table as reviews start and finish:
#   | 📝 **Code Review** | 🔄 **Running** since <relative-time datetime="…"> | `585f205` | PR opened |
# Statuses seen in the wild: Completed, Failed, Running. Only in-flight ones
# block; Queued/Pending/In progress are matched in case Codex adds them.
summary_ok=1
summary_seen=0
running_json="[]"
# read_summary — one read of the summary. Clears summary_ok if unreadable,
# sets summary_seen if Codex has a summary, and adds in-flight rows to
# running_json. Called directly (not in $( )) so it can set these.
read_summary() {
  local raw body rows
  # The summary is one of the OLDEST comments (Codex edits it in place), so a
  # tail query would miss it on a long PR; page through at 100 a page instead.
  raw="$(gh api ${host_args[@]+"${host_args[@]}"} --paginate --slurp "repos/$owner/$name/issues/$number/comments?per_page=100" 2>/dev/null || true)"
  if [[ "$(printf '%s' "$raw" | jq -r 'type == "array"' 2>/dev/null)" != "true" ]]; then
    summary_ok=0
    return
  fi
  body="$(printf '%s' "$raw" | jq -r --arg re "$BOT_RE" \
    '[.[][]? | objects
      | select((.user.login // "") | test($re))
      | select((.body // "") | contains("<!-- codex-pull-request-review-summary -->"))]
     | sort_by(.updated_at // "") | last | .body // ""' 2>/dev/null || true)"
  [[ -n "$body" ]] || return
  summary_seen=1
  rows="$(printf '%s' "$body" | jq -Rsc --argjson ttl "$TTL" --argjson now "${NOW:-null}" '
    ($now // now) as $t
    | [ split("\n")[]
        | select(test("\\*\\*(Running|Queued|Pending|In progress)\\*\\*"; "i"))
        | { since: ((capture("datetime=\"(?<d>[^\"]+)\"") | .d) // ""),
            commit: ((capture("`(?<c>[0-9a-f]{7,40})`") | .c) // "") }
        | .age = (try (.since | sub("\\.[0-9]+"; "") | fromdateiso8601 | ($t - .) | floor) catch null)
        # An unparseable start time fails open, like every other sensor.
        | select(.age != null and .age < $ttl) ]' 2>/dev/null || true)"
  [[ -n "$rows" ]] || return
  running_json="$(jq -nc --argjson a "$running_json" --argjson b "$rows" '$a + $b | unique_by(.since, .commit)' 2>/dev/null || printf '%s' "$running_json")"
}
read_summary

# ── Sensor 1: Codex review threads not yet cleared ───────────────────────────
# `gh api graphql --paginate` walks the one connection that carries pageInfo.
# `--slurp` returns every page as one array; it must not be combined with
# `--jq` (see merge_preflight.sh), so the shaping happens in a separate jq.
# owner/name go in with -f (raw string): -F would turn a numeric-looking repo
# name into an Int and fail the query. `comments` is aliased twice: the first
# comment is Codex's finding; the last 50 carry the replies.
THREADS_Q='query($owner:String!,$name:String!,$number:Int!,$endCursor:String){repository(owner:$owner,name:$name){pullRequest(number:$number){reviewThreads(first:100,after:$endCursor){pageInfo{hasNextPage endCursor} nodes{id isResolved isOutdated path line originalLine resolvedBy{login} comments:comments(first:1){nodes{author{login} body url}} replies:comments(last:50){nodes{author{login} body}}}}}}}'
threads_raw="$(gh api graphql ${host_args[@]+"${host_args[@]}"} --paginate --slurp -f owner="$owner" -f name="$name" -F number="$number" -f query="$THREADS_Q" 2>/dev/null || true)"

threads_ok=0
codex_threads=0
if [[ "$(printf '%s' "$threads_raw" | jq -r '[.[]? | .data.repository.pullRequest.reviewThreads | objects] | length > 0' 2>/dev/null)" == "true" ]]; then
  threads_ok=1
  codex_threads="$(printf '%s' "$threads_raw" | jq --arg re "$BOT_RE" \
    '[.[] | .data.repository.pullRequest.reviewThreads.nodes[]?
      | select((.comments.nodes[0].author.login // "") | test($re))] | length' 2>/dev/null || echo 0)"
  # Severity and title come from Codex's own markup:
  #   **<sub><sub>![P2 Badge](...)</sub></sub>  Title of the finding**
  # Neither is load-bearing — a thread blocks whether or not they parse.
  # A reply counts when a non-Codex author wrote something non-blank. A thread
  # Codex resolved itself needs no reply: that is Codex confirming the fix.
  uncleared_json="$(printf '%s' "$threads_raw" | jq -c --arg re "$BOT_RE" \
    '[.[] | .data.repository.pullRequest.reviewThreads.nodes[]?
      | select((.comments.nodes[0].author.login // "") | test($re))
      | ([.replies.nodes[]?
          | select(((.author.login // "") | test($re)) | not)
          | select((.body // "") | test("\\S"))] | length > 0) as $replied
      | ((.resolvedBy.login // "") | test($re)) as $by_codex
      | select((.isResolved | not) or (($replied or $by_codex) | not))
      | (.comments.nodes[0].body // "") as $b
      | { id: .id,
          state: (if .isResolved then "resolved_no_reply" else "open" end),
          path: (.path // ""),
          line: (.line // .originalLine),
          outdated: (.isOutdated // false),
          url: (.comments.nodes[0].url // ""),
          severity: (($b | capture("!\\[(?<p>P[0-9])[^\\]]*\\]") | .p) // ""),
          title: ((($b | capture("</sub></sub>\\s*(?<t>[^*\\n]+)\\*\\*") | .t)
                   // ($b | split("\n")[0])) | .[0:140]) }]' 2>/dev/null || echo '[]')"
  [[ -n "$uncleared_json" ]] || uncleared_json="[]"
fi

read_summary

n_uncleared="$(printf '%s' "$uncleared_json" | jq 'length' 2>/dev/null || echo 0)"
n_open="$(printf '%s' "$uncleared_json" | jq '[.[] | select(.state == "open")] | length' 2>/dev/null || echo 0)"
n_noreply=$(( ${n_uncleared:-0} - ${n_open:-0} ))
n_running="$(printf '%s' "$running_json" | jq 'length' 2>/dev/null || echo 0)"

if [[ "${n_uncleared:-0}" -gt 0 || "${n_running:-0}" -gt 0 ]]; then
  lines=""
  if [[ "${n_running:-0}" -gt 0 ]]; then
    lines+="$(printf '%s' "$running_json" | jq -r '.[] | "  • Codex review RUNNING on `\(.commit)` — started \(([.age, 0] | max) / 60 | floor) min ago"')"$'\n'
  fi
  if [[ "${n_uncleared:-0}" -gt 0 ]]; then
    lines+="$(printf '%s' "$uncleared_json" | jq -r '.[] |
      "  • [\(if .severity == "" then "?" else .severity end)] \(.path):\(.line // "?")\(if .outdated then " (outdated)" else "" end)\(if .state == "resolved_no_reply" then " (resolved, but nobody replied)" else "" end) — \(.title)\n      thread \(.id)  \(.url)"')"$'\n'
  fi
  emit blocked 1 "PR #$number ($owner_repo): ${n_open:-0} open Codex thread(s), ${n_noreply:-0} resolved without a reply, ${n_running:-0} Codex review(s) in progress.
${lines%$'\n'}"
fi

if [[ "$threads_ok" -eq 0 || "$summary_ok" -eq 0 ]]; then
  emit indeterminate 0 "PR #$number ($owner_repo): part of the Codex review state was unreadable and nothing readable blocks — not blocking."
fi

if [[ "${codex_threads:-0}" -eq 0 && "$summary_seen" -eq 0 ]]; then
  emit absent 0 "no Codex review activity on PR #$number — nothing to gate."
fi

emit clear 0 "PR #$number ($owner_repo): every Codex thread is resolved with a reply (or by Codex) and no Codex review is in progress."
