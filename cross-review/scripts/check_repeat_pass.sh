#!/usr/bin/env bash
# check_repeat_pass.sh — refuse a re-review pass that re-reads a diff already
# reviewed, and tell the caller which base it should have used instead.
#
# THE RULE THIS ENFORCES (SKILL.md, "Re-review loop"):
#
#   pass the *previous pass's HEAD* as --base so reviewers see only the fix
#   commits ... A re-pass is answering a narrow question, not re-finding
#   everything.
#
# That rule was prose, and prose is advisory. Measured on runlog.jsonl
# 2026-08-29: 43 multi-pass PRs in August (29% of the month's multi-pass
# rounds) re-ran pass 2+ against the SAME base as pass 1. Because fixes ADD
# lines, the re-read diff grows every pass — PR #2168 went 7,777 -> 7,866 ->
# 7,976 lines, so codex read ~23,600 lines to review ~200 new ones. Total
# across the sample: 162,929 diff lines re-read for nothing.
#
# WHY ITS OWN STATE, NOT runlog.jsonl:
#
#   - runlog's `wrapper_branch` is the SKILL's branch (always "master"), not
#     the subject repo's — it cannot identify which branch was reviewed.
#   - Keying on project+base alone would false-positive on every PR in a repo,
#     because they all share one base (`origin/develop`). The subject branch is
#     the only thing that separates them, and the runlog does not record it.
#
#   So the guard keeps a small record per (project, subject branch). It is
#   advisory state: losing it fails OPEN (a missing record allows the round).
#
# WHAT COUNTS AS A VIOLATION: a recorded round exists for this project+branch,
# its base is the SAME as the one now requested, AND HEAD has moved since. The
# moved-HEAD condition is what separates a genuine repeat pass (new fix
# commits, same base = full re-review) from re-running an identical round after
# a crash or a timeout, which must stay allowed.
#
# usage:
#   check_repeat_pass.sh --project <p> --branch <b> --base-sha <sha> --head-sha <sha>
#                        [--state-dir <d>] [--window-hours <n>] [--allow-full-rereview]
#   check_repeat_pass.sh --record --project <p> --branch <b> --base-sha <sha> --head-sha <sha>
#   check_repeat_pass.sh --pass-context [--project <p>] [--branch <b>]
#
# --pass-context is a QUERY, not a gate: it prints the pass number of the round
# ABOUT TO RUN (1 for a first pass, 2 for the next, ...) and exits 0, derived
# from the SAME record and the SAME staleness rule the block above uses. It
# exists so callers can cheapen a later pass (run_reviewers.sh steps codex's
# reasoning effort down) without deriving the state key a second time — a
# duplicated derivation is how the two copies of a check drift apart.
#
# It answers about the round about to run, NOT the one last recorded, because
# that is the round whose cost the caller is deciding. Query it BEFORE
# --record. Anything unreadable, absent, or stale answers 1 — the same
# fail-open direction as the gate.
#
# exit 0 — proceed (no prior round, incremental base, retry, stale, override,
#          or no resolvable branch identity to key state on)
# exit 3 — blocked: this is a full re-review of an already-reviewed diff
# exit 2 — usage error
#
# Overrides (SKILL.md allows a deliberate full re-review "when the fixes were
# structural enough to invalidate the original review's context"):
#   --allow-full-rereview   or   CROSS_REVIEW_ALLOW_FULL_REREVIEW=1

set -uo pipefail

project=""; branch=""; base_sha=""; head_sha=""
state_dir=""; window_hours="${CROSS_REVIEW_REPEAT_WINDOW_HOURS:-24}"
record=0; allow="${CROSS_REVIEW_ALLOW_FULL_REREVIEW:-0}"; pass_context=0

need_val() { [[ "$2" -ge 2 ]] || { echo "$1 requires a value" >&2; exit 2; }; }
while [[ $# -gt 0 ]]; do
  case "$1" in
    --project)             need_val "$1" "$#"; project="$2";      shift 2 ;;
    --branch)              need_val "$1" "$#"; branch="$2";       shift 2 ;;
    --base-sha)            need_val "$1" "$#"; base_sha="$2";     shift 2 ;;
    --head-sha)            need_val "$1" "$#"; head_sha="$2";     shift 2 ;;
    --state-dir)           need_val "$1" "$#"; state_dir="$2";    shift 2 ;;
    --window-hours)        need_val "$1" "$#"; window_hours="$2"; shift 2 ;;
    --record)              record=1; shift ;;
    --pass-context)        pass_context=1; shift ;;
    --allow-full-rereview) allow=1;  shift ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

# Fall back to git only for what the caller omitted, so the guard is fully
# testable without a repo (and usable from inside one without plumbing).
[[ -z "$project"  ]] && project="$(basename "$(git rev-parse --show-toplevel 2>/dev/null || pwd)")"
[[ -z "$branch"   ]] && branch="$(git symbolic-ref --short -q HEAD 2>/dev/null || true)"
[[ -z "$head_sha" ]] && head_sha="$(git rev-parse HEAD 2>/dev/null || echo unknown)"

# --base-sha has no sane default: without it there is nothing to compare, and a
# caller that forgot it has a bug worth reporting. --pass-context is exempt: it
# is a query about the BRANCH, not about any particular round, so it needs no
# shas to answer.
if [[ "$pass_context" != 1 && -z "$base_sha" ]]; then
  echo "usage: $0 --project <p> --branch <b> --base-sha <sha> --head-sha <sha> [--record]" >&2
  exit 2
fi

# A detached HEAD has no branch name: `git branch --show-current` (and
# symbolic-ref) print NOTHING and exit 0/1, so the old `|| echo detached`
# fallback never fired and the guard exited 2 on every detached checkout --
# blocking nothing and, worse, recording nothing, so the next pass had no state
# to compare against either. Substituting a literal "detached" would be worse
# still: every detached review of a repo would share one key, and since they
# also share a base (origin/master) the guard would block unrelated PRs.
#
# With no branch identity there is no safe key, so honour the fail-open
# contract explicitly: skip the guard, do not invent one.
if [[ -z "$project" || -z "$branch" || -z "$head_sha" ]]; then
  # --pass-context's contract is "always prints a number", so it answers 1
  # rather than falling silent. Silence would leave the caller's `_pc` empty
  # and lean on its `case ''` sanitizer to invent the same 1 -- a contract held
  # up by the caller's error handling is not a contract. 1 is also the honest
  # answer: with no branch identity there is no prior pass to count.
  #
  # This is the SECOND way a detached HEAD disabled the effort ladder. Even
  # with the state record repaired, --pass-context took its own usage path and
  # exited 2 before reading any record, the caller swallowed it as `|| echo 1`,
  # and every pass got default effort from the first round onward.
  if [[ "$pass_context" == 1 ]]; then echo 1; exit 0; fi
  echo "check_repeat_pass: no branch identity (detached HEAD?) — guard skipped" >&2
  exit 0
fi

skill_dir="$(cd "$(dirname "$0")/.." && pwd)"
[[ -z "$state_dir" ]] && state_dir="${CROSS_REVIEW_STATE_DIR:-$skill_dir/state}/last_base"

# Flatten the key: a branch name legitimately contains '/', which would
# otherwise create nested directories (and `feat/a` + a file named `a` under
# `feat` can collide). Anything outside [A-Za-z0-9._-] becomes '_', and a
# short digest keeps distinct names that flatten alike from colliding.
key_of() {
  local raw="$1" flat digest
  flat="$(printf '%s' "$raw" | tr -c 'A-Za-z0-9._-' '_')"
  digest="$(printf '%s' "$raw" | (shasum -a 256 2>/dev/null || sha256sum) | cut -c1-8)"
  # Cap the readable half so a very long branch name cannot blow the filename
  # limit; the digest carries uniqueness regardless.
  printf '%s.%s' "${flat:0:80}" "$digest"
}
key="$(key_of "${project}//${branch}")"
rec="$state_dir/$key.json"

now_epoch="$(date +%s)"

# Staleness, in one place: a record older than the window is not evidence of a
# prior pass, for the block below and for --pass-context alike.
case "$window_hours" in ''|*[!0-9]*) window_hours=24 ;; esac
record_is_fresh() {
  local e="$1"
  [[ -n "$e" ]] || return 1
  (( now_epoch - e < window_hours * 3600 ))
}

# next_pass: the number of the round about to run. One shared derivation for
# --pass-context (which reports it) and --record (which stores it), so the
# number a caller acts on and the number that persists cannot disagree.
#
# A record with no "passes" field predates the counter; a fresh one still
# means exactly one prior pass, so it reads as 1.
next_pass() {
  local e="" n=""
  [[ -f "$rec" ]] || { echo 1; return; }
  e="$(sed -n 's/.*"epoch":\([0-9]*\).*/\1/p' "$rec" 2>/dev/null)"
  record_is_fresh "$e" || { echo 1; return; }
  n="$(sed -n 's/.*"passes":\([0-9]*\).*/\1/p' "$rec" 2>/dev/null)"
  case "$n" in ''|*[!0-9]*) n=1 ;; esac
  (( n < 1 )) && n=1
  echo $(( n + 1 ))
}

if [[ "$pass_context" == 1 ]]; then
  next_pass
  exit 0
fi

if [[ "$record" == 1 ]]; then
  mkdir -p "$state_dir" || exit 0   # advisory state: never fail the round
  # The counter is what separates pass 2 (a fix check, still productive: 51%
  # FIXES_APPLIED in August) from pass 5 (mostly codex confirming its own
  # earlier verdict: pass 3+ was 57% CLEAN, 115/202). A stale record starts a
  # new review, so the count restarts with it.
  #
  # A ROUND, NOT A WRITE. next_pass() adds one to whatever is stored, so two
  # writes for the same (base, head) used to count one pass as two. That is not
  # a hypothetical: SKILL.md step 3 tells the caller to dispatch a slow seat as
  # a SEPARATE background run_reviewers.sh into the same run_dir, and step 6
  # lets the next pass start while it trails -- so both processes reach the
  # `any_ok` record with identical shas. The ladder then served `medium` on a
  # real pass 2, stepping down early and silently, on exactly the large rounds
  # that trail because they are large. Found by codex on PR #173 round 1;
  # reproduced by recording the same pair twice and watching --pass-context go
  # 2 -> 3.
  #
  # So: same pair as the fresh record on disk -> refresh the epoch, keep the
  # count. Different pair -> a genuinely new round, increment.
  _rec_passes="$(next_pass)"
  if [[ -f "$rec" ]]; then
    _pe="$(sed -n 's/.*"epoch":\([0-9]*\).*/\1/p' "$rec" 2>/dev/null)"
    if record_is_fresh "$_pe"; then
      _pb="$(sed -n 's/.*"base_sha":"\([^"]*\)".*/\1/p' "$rec" 2>/dev/null)"
      _ph="$(sed -n 's/.*"head_sha":"\([^"]*\)".*/\1/p' "$rec" 2>/dev/null)"
      if [[ "$_pb" == "$base_sha" && "$_ph" == "$head_sha" ]]; then
        _stored="$(sed -n 's/.*"passes":\([0-9]*\).*/\1/p' "$rec" 2>/dev/null)"
        case "$_stored" in ''|*[!0-9]*) _stored=1 ;; esac
        (( _stored < 1 )) && _stored=1
        _rec_passes="$_stored"
      fi
    fi
  fi
  # Write via temp-and-rename so a reader never sees a half-written record, and
  # so two lanes finishing together produce one whole record rather than an
  # interleaved one. This does not order the writers -- last rename still wins
  # -- but with the same-pair case above collapsed, the surviving race is two
  # DIFFERENT rounds, which the epoch check below already treats as stale.
  _tmp="$rec.$$.tmp"
  if printf '{"project":%s,"branch":%s,"base_sha":%s,"head_sha":%s,"epoch":%s,"passes":%s}\n' \
    "\"$project\"" "\"$branch\"" "\"$base_sha\"" "\"$head_sha\"" "$now_epoch" "$_rec_passes" \
    > "$_tmp" 2>/dev/null; then
    mv -f "$_tmp" "$rec" 2>/dev/null || rm -f "$_tmp" 2>/dev/null
  else
    rm -f "$_tmp" 2>/dev/null
  fi
  exit 0
fi

[[ -f "$rec" ]] || exit 0                      # no prior round -> first pass

prev_base="$(sed -n 's/.*"base_sha":"\([^"]*\)".*/\1/p' "$rec" 2>/dev/null)"
prev_head="$(sed -n 's/.*"head_sha":"\([^"]*\)".*/\1/p' "$rec" 2>/dev/null)"
prev_epoch="$(sed -n 's/.*"epoch":\([0-9]*\).*/\1/p' "$rec" 2>/dev/null)"
[[ -n "$prev_base" && -n "$prev_head" && -n "$prev_epoch" ]] || exit 0

# Stale records must not block forever — a branch legitimately revisited days
# later is a new review, not a repeat pass. Same predicate --pass-context uses.
record_is_fresh "$prev_epoch" || exit 0

[[ "$base_sha" == "$prev_base" ]] || exit 0    # base advanced -> incremental
[[ "$head_sha" != "$prev_head" ]] || exit 0    # HEAD unmoved -> retry, allow

if [[ "$allow" == 1 ]]; then
  echo "check_repeat_pass: full re-review of the same base — allowed by override" >&2
  exit 0
fi

cat >&2 <<MSG
check_repeat_pass: REFUSING a full re-review.

  project/branch : $project / $branch
  requested base : $base_sha
  already reviewed at this base, HEAD was: $prev_head
  HEAD is now    : $head_sha

This round would re-read every line the previous pass already reviewed, plus
the fix commits. SKILL.md's re-review loop asks for the previous pass's HEAD
as the base so reviewers see only what changed.

  Re-run with:  --base $prev_head

If the fixes were structural enough to invalidate the previous review's
context, a full re-review is the right call — say so explicitly:

  --allow-full-rereview     (or CROSS_REVIEW_ALLOW_FULL_REREVIEW=1)
MSG
exit 3
