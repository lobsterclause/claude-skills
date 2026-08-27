#!/usr/bin/env bash
# worktree.sh — manage ephemeral git worktrees for cross-review runs.
#
# Subcommands:
#   start --ref <branch-or-sha> --id <slug> [--base <branch>]
#     Creates $HOME/.cross-review/worktrees/cr-<slug>-<ts>-<pid>/ (detached worktree at <ref>)
#     Creates $HOME/.cross-review/runs/<repo>-<slug>-<ts>-<pid>/ (stable output dir)
#     Runs size + secret-path checks, emits a single JSON line, and writes that
#     same line to $run_dir/context.json.
#
#   end --worktree <path>
#     Tears down the worktree. Idempotent. Run dir is NOT touched.
#
#   sweep [--older-than-hours N]
#     Removes stray cr-*/ worktrees older than N hours (default 24) from both
#     the canonical location and /tmp (legacy). Safe on paths with spaces.
#
# Run dirs (under $HOME/.cross-review/runs/) are NEVER auto-cleaned — they are
# the permanent record of each review. User deletes manually if desired.
#
# Design notes:
# - Worktrees live under $HOME (not /tmp) to avoid predictable-path tampering in
#   world-writable /tmp. The skill runs as the user and has no multi-tenant need
#   for /tmp. Legacy /tmp/cr-* are still swept for backwards compatibility.
# - Paths include the PID ($$) so two passes started in the same second with
#   the same --id cannot collide.
# - Sweep uses -print0 + null-separated read; it must not word-split on paths
#   containing spaces, since it calls `rm -rf "$dir"`.
# - `start` records head_sha and writes context.json ITSELF. Both used to be the
#   caller's job ("Save the JSON to $run_dir/context.json", SKILL.md) — prose an
#   agent could skip, and did: on 2026-08-11 six kindred-mama-ai PRs (#3214,
#   #3252, #3264, #3269, #3276, #3280) had 68-676KB of real reviewer output on
#   disk, no context.json, and no posted review comment. Nothing downstream
#   could tell those from PRs that were never reviewed, because the SHA under
#   review was never written down anywhere. A run that cannot say which commit
#   it covered cannot be reconciled later, so recording it is the script's job.

set -euo pipefail

# Env overrides exist for the fixture tests (tests/run_tests.sh) — production
# callers never set them.
WORKTREE_ROOT="${CROSS_REVIEW_WORKTREE_ROOT:-$HOME/.cross-review/worktrees}"
RUN_ROOT="${CROSS_REVIEW_RUN_ROOT:-$HOME/.cross-review/runs}"
LEGACY_TMP_ROOT="${CROSS_REVIEW_LEGACY_TMP_ROOT:-/tmp}"

# Refuse to operate with a degenerate root: an empty or "/" WORKTREE_ROOT
# would make the "$WORKTREE_ROOT"/cr-* prefix checks below match /cr-* at the
# filesystem root, and sweep would scan / (issue #7).
if [[ -z "$WORKTREE_ROOT" || "$WORKTREE_ROOT" == "/" || "$WORKTREE_ROOT" != /* ]]; then
  echo "worktree.sh: WORKTREE_ROOT must be a non-root absolute path (got: '$WORKTREE_ROOT') — refusing to run" >&2
  exit 2
fi

# owns_worktree <dir> — true only for directories this tool provably created
# (issue #6: sweep/end must never rm -rf a cr-* path someone else made).
# Evidence, either of:
#   - the marker file `start` drops in every worktree (v1.2+)
#   - a git worktree pointer (.git FILE, not dir) whose gitdir references a
#     cr-* worktree — covers pre-marker legacy dirs still on disk
owns_worktree() {
  [[ -f "$1/.cross-review-worktree" ]] && return 0
  # Anchored to the gitdir pointer line so a stray substring elsewhere in an
  # unrelated file can't count as ownership (laguna, PR #21 pass 1).
  [[ -f "$1/.git" ]] && grep -q '^gitdir: .*/worktrees/cr-' "$1/.git" 2>/dev/null
}

usage() {
  cat <<EOF >&2
usage:
  $0 start --ref <branch-or-sha> --id <slug> [--base <branch>]
  $0 end --worktree <path>
  $0 sweep [--older-than-hours N]
EOF
  exit 2
}

# Guard against --flag passed without a value (last-arg crash under set -u).
need_val() {
  local flag="$1"
  local argc="$2"
  if [[ "$argc" -lt 2 ]]; then
    echo "missing value for $flag" >&2
    usage
  fi
}

cmd="${1:-}"
shift || true

case "$cmd" in
  start)
    ref=""
    id=""
    base=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --ref)  need_val --ref  "$#"; ref="$2";  shift 2 ;;
        --id)   need_val --id   "$#"; id="$2";   shift 2 ;;
        --base) need_val --base "$#"; base="$2"; shift 2 ;;
        *) echo "unknown arg: $1" >&2; usage ;;
      esac
    done
    [[ -n "$ref" && -n "$id" ]] || usage

    # Must be inside a git repo — we anchor the worktree and size check against it.
    if ! git rev-parse --show-toplevel >/dev/null 2>&1; then
      echo "not in a git repository" >&2
      exit 1
    fi
    repo_root="$(git rev-parse --show-toplevel)"
    repo_name="$(basename "$repo_root")"

    # Derive the default base from origin/HEAD rather than hardcoding origin/main.
    # Repos whose default is `master` or anything non-`main` would previously
    # silently fail (git diff returns 128, errors suppressed, warn_* collapse to
    # false) — exactly the opposite of fail-safe. Fall through to `origin/main`
    # only if origin/HEAD can't be resolved.
    if [[ -z "$base" ]]; then
      default_branch="$(git -C "$repo_root" rev-parse --abbrev-ref origin/HEAD 2>/dev/null | sed 's|^origin/||' || true)"
      base="origin/${default_branch:-main}"
    fi

    # Validate the base ref exists BEFORE we create the worktree and run diff
    # checks. Silent `|| true` pipelines below would otherwise mask a bad ref
    # as zeros (size 0, warn_secrets false) — the skill would sail past and
    # feed reviewers a wrong-target diff. Fail loud, fail early.
    if ! git -C "$repo_root" rev-parse --verify --quiet "$base^{commit}" >/dev/null; then
      echo "invalid or unknown base ref: $base" >&2
      echo "  hint: try 'git fetch origin' or pass --base <ref> explicitly" >&2
      exit 1
    fi

    # UTC, not local (#118): append_runlog.sh's round_wall_s takes "now" on
    # the UTC clock too, so pairing this started_at with that "now" can't
    # drift onto two different clocks again (the class of bug #117/#118 both
    # existed to close).
    ts="$(date -u +%Y%m%dT%H%M%S)"
    pid="$$"
    # Slugify id so it's filesystem-safe.
    slug="$(printf '%s' "$id" | tr -c 'A-Za-z0-9._-' '-' | sed 's/-\{2,\}/-/g; s/^-//; s/-$//')"
    run_name="${repo_name}-${slug}-${ts}-${pid}"
    wt_name="cr-${slug}-${ts}-${pid}"
    worktree="$WORKTREE_ROOT/$wt_name"
    run_dir="$RUN_ROOT/$run_name"

    mkdir -p "$WORKTREE_ROOT" "$run_dir/raw"

    # Detached worktree so we don't take over the branch in the main checkout.
    # No blanket --force (issue #7): if add fails, prune stale worktree
    # bookkeeping (the one recoverable cause we've seen) and retry once.
    if ! git worktree add -d "$worktree" "$ref" >/dev/null 2>&1; then
      git worktree prune 2>/dev/null || true
      if ! git worktree add -d "$worktree" "$ref" >/dev/null 2>&1; then
        echo "git worktree add failed for ref: $ref" >&2
        exit 1
      fi
    fi

    # Ownership marker — sweep/end only ever delete marked dirs (issue #6).
    printf 'created-by=cross-review/worktree.sh\nrun=%s\n' "$run_name" \
      >"$worktree/.cross-review-worktree"

    # Size check — run inside the worktree.
    size_files=$(git -C "$worktree" diff --name-only "$base"...HEAD | wc -l | tr -d ' ')
    # grep can return non-zero on empty/rename-only diffs; tolerate under pipefail.
    size_lines=$(git -C "$worktree" diff --shortstat "$base"...HEAD \
      | { grep -oE '[0-9]+ insertion|[0-9]+ deletion' || true; } \
      | awk '{s+=$1} END{print s+0}')
    [[ "$size_files" =~ ^[0-9]+$ ]] || size_files=0
    [[ "$size_lines" =~ ^[0-9]+$ ]] || size_lines=0

    # Heuristic thresholds — tune based on experience, not precision.
    # Large PRs cost more reviewer tokens and time; warn so the caller can decide.
    warn_large=false
    if [[ "$size_files" -gt 30 ]] || [[ "$size_lines" -gt 2000 ]]; then
      warn_large=true
    fi

    # Secret-path detection. The diff is sent to multiple external providers
    # (OpenAI/codex, Google/agy, Moonshot/kimi); even rotated secrets should not
    # leave the user's machine without consent.
    # Pattern match on changed filenames, not diff content — path-based is cheap,
    # false-positive-tolerant, and catches the cases that matter most.
    secret_pattern='\.env($|\.|/)|\.envrc|credentials|[Ss]ecret|\.pem$|\.key$|\.p12$|\.pfx$|id_rsa|id_ed25519|\.keystore|\.jks'
    # grep returns 1 when no matches — explicitly tolerate that under `set -e`.
    risky_files=$({ git -C "$worktree" diff --name-only "$base"...HEAD 2>/dev/null \
      | grep -E "$secret_pattern" || true; } | head -5 | tr '\n' ',' | sed 's/,$//')
    warn_secrets=false
    if [[ -n "$risky_files" ]]; then
      warn_secrets=true
    fi

    # Content-based secret scan. Filename matching alone misses a hardcoded
    # API key or credential literal sitting inside an innocuously-named file
    # (config.ts, constants.ts, ...) — the diff still ships unredacted to 15+
    # third-party reviewer APIs. This scans added/changed line CONTENT for
    # common secret-literal shapes, independent of filename.
    #
    # Reuse the same size bound `size_lines` already computed above (it's the
    # same diff we'd otherwise re-walk) rather than inventing a second cap:
    # skip the content scan entirely on diffs so large the size warning has
    # already fired, so a pathological diff can't make this scan slow.
    if [[ "$size_lines" -le 20000 ]]; then
      content_secret_pattern='AKIA[0-9A-Z]{16}|[Ss][Kk]-[A-Za-z0-9_-]{20,}|[Aa][Pp][Ii][_-]?[Kk][Ee][Yy][[:space:]]*[:=][[:space:]]*['"'"'"][A-Za-z0-9/+=_-]{16,}['"'"'"]'
      # --diff-filter=ACMRD: A/C/M/R already covered added/copied/modified/
      # renamed content; D (deleted) is needed too — a whole file removed via
      # `git rm` (the common way to rotate a secret out) was previously
      # invisible to this scan entirely, since ACMR omits D and `git diff`
      # emits nothing for a deleted file under that filter. --no-color and
      # -U0 keep the grep below cheap and free of ANSI noise. Binary files
      # are skipped by git diff itself (it emits "Binary files ... differ",
      # not content).
      #
      # Both added (`+`) AND removed (`-`) line content are scanned: a secret
      # being *rotated out* (e.g. deleting a hardcoded key, whether inside a
      # modified file or a wholly deleted one) exists only on the `-` side of
      # the diff and would otherwise ship unredacted to third-party reviewer
      # APIs. The `---`/`+++` file-header lines are excluded so they aren't
      # mistaken for content; a deleted file's `+++ /dev/null` header falls
      # back to the `---` line for the real filename instead of leaving the
      # literal header text as the filename.
      content_hits=$(git -C "$worktree" diff --no-color -U0 --diff-filter=ACMRD "$base"...HEAD 2>/dev/null \
        | awk '
            /^diff --git / { file=""; next }
            /^--- / {
              f=$0; sub(/^--- [ab]\//, "", f); if (f != "/dev/null") file=f; next
            }
            /^\+\+\+ / {
              f=$0; sub(/^\+\+\+ [ab]\//, "", f); if (f != "/dev/null") file=f; next
            }
            /^\+/ && !/^\+\+\+/ { print file "\t" $0 }
            /^-/ && !/^--- / { print file "\t" $0 }
          ' \
        | grep -E "$content_secret_pattern" \
        | cut -f1 \
        | sort -u | head -5 || true)
      if [[ -n "$content_hits" ]]; then
        warn_secrets=true
        # Union with any filename-based hits already in risky_files, deduped.
        risky_files="$(printf '%s\n%s\n' "$risky_files" "$content_hits" \
          | tr ',' '\n' | sed '/^$/d' | sort -u | head -5 | tr '\n' ',' | sed 's/,$//')"
      fi
    fi

    # The exact commit the reviewers will read. Ask the worktree, not the ref:
    # `--ref origin/foo` resolves at `worktree add` time, and re-resolving it
    # afterwards can pick up a fetch that landed in between. This is the SHA the
    # review actually covers, which is the only one worth stamping.
    head_sha="$(git -C "$worktree" rev-parse HEAD 2>/dev/null || true)"
    # 40 hex for sha1, 64 for a repo created with --object-format=sha256.
    # Hard-coding 40 would abort a review in a perfectly valid sha256 repo.
    # (codex P2, PR #53.)
    if [[ ! "$head_sha" =~ ^([0-9a-f]{40}|[0-9a-f]{64})$ ]]; then
      # Can't-happen in practice — but a context.json with an empty head_sha is
      # precisely the silent hole this field exists to close, so fail loud
      # rather than record a run that can never be reconciled.
      echo "could not resolve worktree HEAD (got: '$head_sha') — refusing to start an unattributable review" >&2
      git worktree remove --force "$worktree" 2>/dev/null || true
      rm -rf "$worktree"
      exit 1
    fi
    base_sha="$(git -C "$repo_root" rev-parse "$base^{commit}" 2>/dev/null || true)"

    # owner/repo only. The remote URL may embed a credential
    # (https://x-access-token:TOKEN@github.com/...), and this string is written
    # to a file that outlives the run, so it must never carry one. awk keeps
    # only the last two path components, and the regex then rejects anything
    # that isn't a plain owner/repo — a one-component remote would otherwise
    # put the userinfo field in $(NF-1). Fails closed to "".
    origin_slug="$(git -C "$repo_root" remote get-url origin 2>/dev/null \
      | sed -e 's#/$##' -e 's#\.git$##' \
      | awk -F'[/:]' 'NF>=2 {printf "%s/%s", $(NF-1), $NF}' || true)"
    # The owner half forbids dots; the repo half allows them. Without that
    # asymmetry `https://github.com/justrepo` reduces to "github.com/justrepo",
    # which passes a symmetric regex and records a hostname as the owner.
    # (minimax L, PR #53.)
    [[ "$origin_slug" =~ ^[A-Za-z0-9-]+/[A-Za-z0-9._-]+$ ]] || origin_slug=""

    # Escape rather than interpolate raw: context.json is machine-read by
    # reconciliation, and a filename containing a quote must not be able to
    # truncate the record into malformed JSON that parses as "no run".
    jsonesc() { printf '%s' "${1:-}" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | tr -d '\000-\037'; }

    json="$(printf '{"worktree": "%s", "run_dir": "%s", "size_files": %d, "size_lines": %d, "base": "%s", "base_sha": "%s", "head_sha": "%s", "ref": "%s", "id": "%s", "repo": "%s", "started_at": "%s", "warn_large_diff": %s, "warn_secrets": %s, "risky_files": "%s"}' \
      "$(jsonesc "$worktree")" "$(jsonesc "$run_dir")" "$size_files" "$size_lines" \
      "$(jsonesc "$base")" "$base_sha" "$head_sha" "$(jsonesc "$ref")" "$(jsonesc "$id")" \
      "$origin_slug" "$ts" "$warn_large" "$warn_secrets" "$(jsonesc "$risky_files")")"

    # Same bytes to both, so the caller's copy and the on-disk record can never
    # disagree about what was reviewed.
    printf '%s\n' "$json" >"$run_dir/context.json"
    printf '%s\n' "$json"
    ;;

  end)
    worktree=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --worktree) need_val --worktree "$#"; worktree="$2"; shift 2 ;;
        *) echo "unknown arg: $1" >&2; usage ;;
      esac
    done
    [[ -n "$worktree" ]] || usage

    # Bounds check: refuse to rm -rf anything outside the managed roots.
    # Without this, `end --worktree /` or `end --worktree "$HOME"` would
    # destroy the user's filesystem. Accept only:
    #   - the canonical root ($WORKTREE_ROOT/cr-*)
    #   - legacy /tmp/cr-* (for pre-v1.1 worktrees still on disk)
    #   - /private/tmp/cr-* (how git worktree list reports paths on macOS
    #     since /tmp is a symlink)
    case "$worktree" in
      "$WORKTREE_ROOT"/cr-*|"$LEGACY_TMP_ROOT"/cr-*|/tmp/cr-*|/private/tmp/cr-*) ;;
      *)
        echo "refusing to remove path outside managed worktree roots: $worktree" >&2
        echo "  expected prefix: $WORKTREE_ROOT/cr-* (or /tmp/cr-*)" >&2
        exit 1
        ;;
    esac

    if [[ ! -d "$worktree" ]]; then
      # Already gone — idempotent success.
      echo '{"removed": false, "reason": "not-found"}'
      exit 0
    fi

    # Legacy tmp paths need positive ownership evidence before rm -rf — the
    # prefix alone doesn't prove this tool created the dir (issue #6).
    case "$worktree" in
      "$WORKTREE_ROOT"/cr-*) ;;
      *)
        if ! owns_worktree "$worktree"; then
          echo "refusing to remove unowned legacy path (no cross-review marker or worktree pointer): $worktree" >&2
          exit 1
        fi
        ;;
    esac

    # Best-effort: let git do its bookkeeping first, then scrub filesystem.
    git worktree remove --force "$worktree" 2>/dev/null || true
    rm -rf "$worktree"
    printf '{"removed": true, "path": "%s"}\n' "$worktree"
    ;;

  sweep)
    hours=24
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --older-than-hours) need_val --older-than-hours "$#"; hours="$2"; shift 2 ;;
        *) echo "unknown arg: $1" >&2; usage ;;
      esac
    done

    # Validate before feeding into `$(( hours * 60 ))`. Bash arithmetic context
    # evaluates variable contents as expressions, which supports array indices
    # with command substitution — e.g. `--older-than-hours 'a[$(rm -rf ~)]'`
    # would execute arbitrary code. Integer-only regex blocks the class.
    if ! [[ "$hours" =~ ^[0-9]+$ ]]; then
      echo "--older-than-hours must be a non-negative integer: $hours" >&2
      exit 2
    fi

    # BSD find (macOS) uses -mmin; that covers Linux too.
    # Use -print0 + null-separated read to survive paths containing spaces.
    # `rm -rf "$dir"` on a word-split token is a known data-loss footgun.
    minutes=$(( hours * 60 ))
    removed=0
    # Check both the canonical location and legacy /tmp — users upgrading from
    # the earlier skill version may still have /tmp/cr-* leftovers.
    for root in "$WORKTREE_ROOT" "$LEGACY_TMP_ROOT"; do
      [[ -d "$root" ]] || continue
      while IFS= read -r -d '' dir; do
        # The canonical root is ours by construction; anything under the
        # legacy tmp root must carry ownership evidence (issue #6 — an
        # unrelated /tmp/cr-foo must survive the sweep).
        if [[ "$root" != "$WORKTREE_ROOT" ]] && ! owns_worktree "$dir"; then
          echo "  sweep: skipping unowned $dir" >&2
          continue
        fi
        git worktree remove --force "$dir" 2>/dev/null || true
        # `|| true` so a single rm failure (permissions, mount issue, race
        # with another sweep) doesn't abort the loop and leave the rest
        # uncleaned. `git worktree prune` below still runs.
        rm -rf "$dir" || true
        removed=$((removed + 1))
      done < <(find "$root" -maxdepth 1 -type d -name 'cr-*' -mmin +"$minutes" -print0 2>/dev/null)
    done

    # Prune tracking if we're inside a repo; otherwise skip.
    if git rev-parse --show-toplevel >/dev/null 2>&1; then
      git worktree prune 2>/dev/null || true
    fi

    printf '{"removed_count": %d, "older_than_hours": %d}\n' "$removed" "$hours"
    ;;

  ''|-h|--help|help)
    usage
    ;;

  *)
    echo "unknown subcommand: $cmd" >&2
    usage
    ;;
esac