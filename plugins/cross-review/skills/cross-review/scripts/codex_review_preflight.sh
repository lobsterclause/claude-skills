#!/usr/bin/env bash
# codex_review_preflight.sh — answer one question: does Codex (the
# chatgpt-codex-connector GitHub app) still have something to say about this
# PR that nobody has answered?
#
#   codex_review_preflight.sh --pr 123 [--repo owner/name] [--json]
#
# Two things block:
#   * An UNRESOLVED review thread opened by Codex — any severity, outdated or
#     not. "Outdated" only means the lines under it moved; it says nothing about
#     whether the finding was fixed. Resolving the thread on GitHub, after
#     fixing it or replying with why not, is what clears it — and it leaves a
#     record on the PR that someone did. gothicpixie/toss-battle #79 merged with
#     a P2 thread nobody had answered; that is the failure this exists for.
#   * A Codex review still RUNNING, per Codex's own summary comment, that began
#     less than CODEX_GATE_RUNNING_TTL seconds ago (default 1800). Merging
#     mid-review lands the code before its findings exist. Past the TTL the run
#     is treated as hung and does not block: gothicpixie/toss-core #20 has sat
#     at "Running" for two days, and a gate that waits on a dead review forever
#     gets switched off.
#
# Exit codes:
#   0  clear to merge — nothing unresolved and nothing running, OR Codex never
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
# its own, so an unreadable summary comment does not hide an unresolved thread.
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
unresolved_json="[]"
running_json="[]"

emit() {
  # emit <status> <exit_code> <reason>
  local status="$1" code="$2" reason="$3"
  if [[ "$as_json" -eq 1 ]]; then
    if command -v jq >/dev/null 2>&1; then
      jq -nc --arg s "$status" --arg p "$pr" --arg repo "$owner_repo" \
             --arg h "$cur_sha" --arg m "$reason" \
             --argjson u "$unresolved_json" --argjson r "$running_json" \
        '{status:$s, pr:$p, repo:$repo, head:$h, reason:$m, unresolved:$u, running:$r}'
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

# ── Sensor 1: unresolved Codex review threads ────────────────────────────────
# `gh api graphql --paginate` walks the one connection that carries pageInfo.
# `--slurp` returns every page as one array; it must not be combined with
# `--jq` (see merge_preflight.sh), so the shaping happens in a separate jq.
# owner/name go in with -f (raw string): -F would turn a numeric-looking repo
# name into an Int and fail the query.
THREADS_Q='query($owner:String!,$name:String!,$number:Int!,$endCursor:String){repository(owner:$owner,name:$name){pullRequest(number:$number){reviewThreads(first:100,after:$endCursor){pageInfo{hasNextPage endCursor} nodes{id isResolved isOutdated path line originalLine comments(first:1){nodes{author{login} body url}}}}}}}'
threads_raw="$(gh api graphql --paginate --slurp -f owner="$owner" -f name="$name" -F number="$number" -f query="$THREADS_Q" 2>/dev/null || true)"

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
  unresolved_json="$(printf '%s' "$threads_raw" | jq -c --arg re "$BOT_RE" \
    '[.[] | .data.repository.pullRequest.reviewThreads.nodes[]?
      | select((.comments.nodes[0].author.login // "") | test($re))
      | select(.isResolved | not)
      | (.comments.nodes[0].body // "") as $b
      | { id: .id,
          path: (.path // ""),
          line: (.line // .originalLine),
          outdated: (.isOutdated // false),
          url: (.comments.nodes[0].url // ""),
          severity: (($b | capture("!\\[(?<p>P[0-9])[^\\]]*\\]") | .p) // ""),
          title: ((($b | capture("</sub></sub>\\s*(?<t>[^*\\n]+)\\*\\*") | .t)
                   // ($b | split("\n")[0])) | .[0:140]) }]' 2>/dev/null || echo '[]')"
  [[ -n "$unresolved_json" ]] || unresolved_json="[]"
fi

# ── Sensor 2: a Codex review still running ───────────────────────────────────
# Codex keeps ONE summary comment per PR, marked with an HTML comment, and
# rewrites its table as reviews start and finish:
#   | 📝 **Code Review** | 🔄 **Running** since <relative-time datetime="…"> | `585f205` | PR opened |
# Statuses seen in the wild: Completed, Failed, Running. Only in-flight ones
# block; Queued/Pending/In progress are matched in case Codex adds them.
summary_ok=0
summary_seen=0
comments_raw="$(gh api --paginate --slurp "repos/$owner/$name/issues/$number/comments" 2>/dev/null || true)"
if [[ "$(printf '%s' "$comments_raw" | jq -r 'type == "array"' 2>/dev/null)" == "true" ]]; then
  summary_ok=1
  summary_body="$(printf '%s' "$comments_raw" | jq -r --arg re "$BOT_RE" \
    '[.[][]? | objects
      | select((.user.login // "") | test($re))
      | select((.body // "") | contains("<!-- codex-pull-request-review-summary -->"))]
     | sort_by(.updated_at // "") | last | .body // ""' 2>/dev/null || true)"
  if [[ -n "$summary_body" ]]; then
    summary_seen=1
    now_arg="${NOW:-null}"
    running_json="$(printf '%s' "$summary_body" | jq -Rsc --argjson ttl "$TTL" --argjson now "$now_arg" '
      ($now // now) as $t
      | [ split("\n")[]
          | select(test("\\*\\*(Running|Queued|Pending|In progress)\\*\\*"; "i"))
          | { since: ((capture("datetime=\"(?<d>[^\"]+)\"") | .d) // ""),
              commit: ((capture("`(?<c>[0-9a-f]{7,40})`") | .c) // "") }
          | .age = (try (.since | sub("\\.[0-9]+"; "") | fromdateiso8601 | ($t - .) | floor) catch null)
          # An unparseable start time fails open, like every other sensor.
          | select(.age != null and .age < $ttl) ]' 2>/dev/null || echo '[]')"
    [[ -n "$running_json" ]] || running_json="[]"
  fi
fi

n_unresolved="$(printf '%s' "$unresolved_json" | jq 'length' 2>/dev/null || echo 0)"
n_running="$(printf '%s' "$running_json" | jq 'length' 2>/dev/null || echo 0)"

if [[ "${n_unresolved:-0}" -gt 0 || "${n_running:-0}" -gt 0 ]]; then
  lines=""
  if [[ "${n_running:-0}" -gt 0 ]]; then
    lines+="$(printf '%s' "$running_json" | jq -r '.[] | "  • Codex review RUNNING on `\(.commit)` — started \((.age / 60) | floor) min ago"')"$'\n'
  fi
  if [[ "${n_unresolved:-0}" -gt 0 ]]; then
    lines+="$(printf '%s' "$unresolved_json" | jq -r '.[] |
      "  • [\(if .severity == "" then "?" else .severity end)] \(.path):\(.line // "?")\(if .outdated then " (outdated)" else "" end) — \(.title)\n      thread \(.id)  \(.url)"')"$'\n'
  fi
  emit blocked 1 "PR #$number ($owner_repo): ${n_unresolved:-0} unresolved Codex thread(s), ${n_running:-0} Codex review(s) in progress.
${lines%$'\n'}"
fi

if [[ "$threads_ok" -eq 0 || "$summary_ok" -eq 0 ]]; then
  emit indeterminate 0 "PR #$number ($owner_repo): part of the Codex review state was unreadable and nothing readable blocks — not blocking."
fi

if [[ "${codex_threads:-0}" -eq 0 && "$summary_seen" -eq 0 ]]; then
  emit absent 0 "no Codex review activity on PR #$number — nothing to gate."
fi

emit clear 0 "PR #$number ($owner_repo): every Codex thread is resolved and no Codex review is in progress."
