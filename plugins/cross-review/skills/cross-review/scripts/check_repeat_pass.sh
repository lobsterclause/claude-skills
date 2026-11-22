#!/usr/bin/env bash
# check_repeat_pass.sh — refuse a re-review pass that re-reads a diff already
# reviewed, and tell the caller which base it should have used instead.
#
# THE RULE THIS ENFORCES (SKILL.md, "Re-review loop"):
#
#   use the *previous pass's HEAD* as --base while it remains an ancestor of
#   the current HEAD. After a rebase/history rewrite, use the merge-base with
#   the actual PR target supplied via --target-ref; never reuse the stale HEAD.
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
#   So the guard keeps a small record per (project, subject branch). A missing
#   record allows the round. If the record exists but its commit objects are
#   unavailable, require a verified merge-base against the explicit target.
#
# WHAT COUNTS AS A VIOLATION: a fresh record exists for this project+branch,
# HEAD moved, and the requested base is neither the previous HEAD nor a
# verified target merge-base after rebase. Re-running an identical round after
# a crash or timeout stays allowed.
#
# usage:
#   check_repeat_pass.sh --project <p> --branch <b> --base-sha <sha> --head-sha <sha>
#                        [--target-ref <fully-qualified-ref>] [--state-dir <d>]
#                        [--window-hours <n>] [--allow-full-rereview]
#   check_repeat_pass.sh --record --project <p> --branch <b> --base-sha <sha> --head-sha <sha>
#   check_repeat_pass.sh --pass-context [--project <p>] [--branch <b>]
#
# --paths-hash <h> (any mode above) scopes the state key to a --paths round: a
# round restricted to a set of pathspecs is a DIFFERENT review from the full
# diff of the same subject (and from a round over other paths), so it must not
# see -- or be refused by -- their records, and must not inherit their pass
# count (the codex effort ladder steps down on it). Without the flag the key is
# exactly what it always was.
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

project=""; branch=""; base_sha=""; head_sha=""; target_ref=""
paths_hash=""
state_dir=""; window_hours="${CROSS_REVIEW_REPEAT_WINDOW_HOURS:-24}"
record=0; allow="${CROSS_REVIEW_ALLOW_FULL_REREVIEW:-0}"; pass_context=0
run_dir=""; prev_run_dir=0

need_val() { [[ "$2" -ge 2 ]] || { echo "$1 requires a value" >&2; exit 2; }; }
while [[ $# -gt 0 ]]; do
  case "$1" in
    --project)             need_val "$1" "$#"; project="$2";      shift 2 ;;
    --branch)              need_val "$1" "$#"; branch="$2";       shift 2 ;;
    --base-sha)            need_val "$1" "$#"; base_sha="$2";     shift 2 ;;
    --head-sha)            need_val "$1" "$#"; head_sha="$2";     shift 2 ;;
    --target-ref)          need_val "$1" "$#"; target_ref="$2";   shift 2 ;;
    --paths-hash)          need_val "$1" "$#"; paths_hash="$2";   shift 2 ;;
    --state-dir)           need_val "$1" "$#"; state_dir="$2";    shift 2 ;;
    --window-hours)        need_val "$1" "$#"; window_hours="$2"; shift 2 ;;
    --record)              record=1; shift ;;
    --pass-context)        pass_context=1; shift ;;
    --run-dir)             need_val "$1" "$#"; run_dir="$2";      shift 2 ;;
    --prev-run-dir)        prev_run_dir=1; shift ;;
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
if [[ "$pass_context" != 1 && "$prev_run_dir" != 1 && -z "$base_sha" ]]; then
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
  [[ "$prev_run_dir" == 1 ]] && exit 0
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
# The pathspec digest joins the key ONLY when set, so every existing record
# (and every full-diff round) keeps the key it always had.
if [[ -n "$paths_hash" ]]; then
  key="$(key_of "${project}//${branch}//paths:${paths_hash}")"
else
  key="$(key_of "${project}//${branch}")"
fi
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

# --prev-run-dir: where the previous pass wrote its output, so the codex effort
# ladder can read what that pass found (scripts/prior_severity.sh). Prints the
# path from a FRESH record only — a stale record is not a previous pass — and
# nothing otherwise. Records written before this field existed print nothing.
if [[ "$prev_run_dir" == 1 ]]; then
  [[ -f "$rec" ]] || exit 0
  _e="$(sed -n 's/.*"epoch":\([0-9]*\).*/\1/p' "$rec" 2>/dev/null)"
  record_is_fresh "$_e" || exit 0
  sed -n 's/.*"run_dir":"\([^"]*\)".*/\1/p' "$rec" 2>/dev/null
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
  # A LATE WRITER FROM AN OLDER PASS. A trailing seat dispatched for pass N can
  # finish after pass N+1 has recorded. Its head is then an ancestor of the
  # head on disk, and writing would both bump the count and point --prev-run-dir
  # back at pass N's findings, so the escalation would read the wrong pass. Keep
  # the newer record. (Found by codex on claude-skills PR #228.)
  if [[ -f "$rec" ]]; then
    _pe2="$(sed -n 's/.*"epoch":\([0-9]*\).*/\1/p' "$rec" 2>/dev/null)"
    _ph2="$(sed -n 's/.*"head_sha":"\([^"]*\)".*/\1/p' "$rec" 2>/dev/null)"
    if record_is_fresh "$_pe2" && [[ -n "$_ph2" && "$_ph2" != "$head_sha" ]] \
       && git merge-base --is-ancestor "$head_sha" "$_ph2" 2>/dev/null; then
      exit 0
    fi
  fi
  # Write via temp-and-rename so a reader never sees a half-written record, and
  # so two lanes finishing together produce one whole record rather than an
  # interleaved one. This does not order the writers -- last rename still wins
  # -- but with the same-pair case above collapsed, the surviving race is two
  # DIFFERENT rounds, which the epoch check below already treats as stale.
  _tmp="$rec.$$.tmp"
  # run_dir is kept only when it needs no JSON escaping; the record is read with
  # sed, and a path with a quote or backslash is simply not recorded (the next
  # pass then sees "unknown" and does not escalate).
  _rd_field=""
  case "$run_dir" in
    ''|*'"'*|*'\'*) ;;
    *) _rd_field=",\"run_dir\":\"$run_dir\"" ;;
  esac
  if printf '{"project":%s,"branch":%s,"base_sha":%s,"head_sha":%s,"epoch":%s,"passes":%s%s}\n' \
    "\"$project\"" "\"$branch\"" "\"$base_sha\"" "\"$head_sha\"" "$now_epoch" "$_rec_passes" "$_rd_field" \
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

[[ "$head_sha" != "$prev_head" ]] || exit 0    # HEAD unmoved -> retry, allow

# A rebase can move HEAD off the previous review's history. In that case the
# old HEAD is not a valid incremental base: three-dot diff against it can
# include unrelated history or hide the current PR's real changes. Require the
# actual PR target as a fully-qualified branch ref and insist that --base is
# the merge-base of the current HEAD and that target. If the previous review's
# HEAD is still an ancestor, the only safe incremental base is that HEAD.
if git cat-file -e "$prev_head^{commit}" 2>/dev/null &&
   git cat-file -e "$head_sha^{commit}" 2>/dev/null; then
  if git merge-base --is-ancestor "$prev_head" "$head_sha" 2>/dev/null; then
    if [[ "$base_sha" == "$prev_head" ]]; then exit 0; fi
    if [[ "$base_sha" != "$prev_base" && "$allow" != 1 ]]; then
      printf 'check_repeat_pass: incremental review must use previous HEAD as --base: %s (supplied %s)\n' \
        "$prev_head" "$base_sha" >&2
      exit 3
    fi
  else
    ancestor_rc=$?
    if [[ "$ancestor_rc" -ne 1 ]]; then
      echo "check_repeat_pass: cannot verify previous HEAD ancestry" >&2
      exit 3
    fi
    case "$target_ref" in
      refs/heads/*|refs/remotes/*) ;;
      *)
        echo "check_repeat_pass: rebased HEAD is not descended from the prior review; pass the fully-qualified PR target ref with --target-ref" >&2
        exit 3
        ;;
    esac
    if ! git rev-parse --verify --quiet "$target_ref^{commit}" >/dev/null 2>&1; then
      echo "check_repeat_pass: target ref is missing or does not resolve to a commit: $target_ref" >&2
      exit 3
    fi
    expected_base="$(git merge-base "$head_sha" "$target_ref" 2>/dev/null || true)"
    if [[ ! "$expected_base" =~ ^[0-9a-fA-F]{40}$ ]]; then
      echo "check_repeat_pass: no merge-base between current HEAD and target ref $target_ref" >&2
      exit 3
    fi
    if [[ "$base_sha" != "$expected_base" ]]; then
      cat >&2 <<MSG
check_repeat_pass: rebased review base is not the PR target merge-base.

  current HEAD : $head_sha
  target ref   : $target_ref
  required base: $expected_base
  supplied base: $base_sha

Re-run using --base $expected_base --target-ref $target_ref.
MSG
      exit 3
    fi
    echo "check_repeat_pass: rebase detected; using PR target merge-base $expected_base" >&2
    exit 0
  fi
else
  # Missing/pruned history cannot establish that the prior HEAD is an
  # ancestor. Fail closed unless the caller supplies the actual PR target and
  # an exact, verifiable merge-base. This also prevents --allow-full-rereview
  # from authorizing a stale previous-HEAD baseline.
  case "$target_ref" in
    refs/heads/*|refs/remotes/*) ;;
    *)
      echo "check_repeat_pass: cannot verify prior HEAD ancestry; pass the fully-qualified PR target ref with --target-ref" >&2
      exit 3
      ;;
  esac
  if ! git rev-parse --verify --quiet "$target_ref^{commit}" >/dev/null 2>&1; then
    echo "check_repeat_pass: target ref is missing or does not resolve to a commit: $target_ref" >&2
    exit 3
  fi
  expected_base="$(git merge-base "$head_sha" "$target_ref" 2>/dev/null || true)"
  if [[ ! "$expected_base" =~ ^[0-9a-fA-F]{40}$ || "$base_sha" != "$expected_base" ]]; then
    echo "check_repeat_pass: cannot verify supplied base as the target merge-base for $target_ref" >&2
    exit 3
  fi
  echo "check_repeat_pass: prior history unavailable; using verified PR target merge-base $expected_base" >&2
  exit 0
fi

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
