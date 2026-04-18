#!/usr/bin/env bash
# worktree.sh — manage ephemeral git worktrees for cross-review runs.
#
# Subcommands:
#   start --ref <branch-or-sha> --id <slug>
#     Creates /tmp/cr-<id>-<ts>/ (detached worktree at <ref>)
#     Creates ~/.cross-review/runs/<repo>-<id>-<ts>/ (stable output dir)
#     Runs a size-check and prints a warning JSON field if the diff is large.
#     Prints one JSON line with worktree, run_dir, size, and warn.
#
#   end --worktree <path>
#     Tears down the worktree. Idempotent. Run dir is NOT touched.
#
#   sweep [--older-than-hours N]
#     Removes stray /tmp/cr-*/ worktrees older than N hours (default 24).
#     Best-effort: rm -rf + git worktree prune in the containing repo.
#
# Run dirs (under ~/.cross-review/runs/) are NEVER auto-cleaned — they are
# the permanent record of each review. User deletes manually if desired.

set -euo pipefail

usage() {
  cat <<EOF >&2
usage:
  $0 start --ref <branch-or-sha> --id <slug> [--base <branch>]
  $0 end --worktree <path>
  $0 sweep [--older-than-hours N]
EOF
  exit 2
}

cmd="${1:-}"
shift || true

case "$cmd" in
  start)
    ref=""
    id=""
    base="origin/main"
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --ref) ref="$2"; shift 2 ;;
        --id) id="$2"; shift 2 ;;
        --base) base="$2"; shift 2 ;;
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

    ts="$(date +%Y%m%dT%H%M%S)"
    # Slugify id so it's filesystem-safe.
    slug="$(echo -n "$id" | tr -c 'A-Za-z0-9._-' '-' | sed 's/-\{2,\}/-/g; s/^-//; s/-$//')"
    worktree="/tmp/cr-${slug}-${ts}"
    run_dir="${HOME}/.cross-review/runs/${repo_name}-${slug}-${ts}"

    mkdir -p "$run_dir/raw"

    # Detached worktree so we don't take over the branch in the main checkout.
    # --force because in rare cases the ref may be "in use" elsewhere.
    if ! git worktree add -d --force "$worktree" "$ref" >/dev/null 2>&1; then
      echo "git worktree add failed for ref: $ref" >&2
      exit 1
    fi

    # Size check — run inside the worktree.
    size_files=$(git -C "$worktree" diff --name-only "$base"...HEAD 2>/dev/null | wc -l | tr -d ' ')
    size_lines=$(git -C "$worktree" diff --shortstat "$base"...HEAD 2>/dev/null \
      | grep -oE '[0-9]+ insertion|[0-9]+ deletion' | awk '{s+=$1} END{print s+0}')

    # Heuristic thresholds — tune based on experience, not precision.
    # Large PRs cost more reviewer tokens and time; warn so the caller can decide.
    warn_large=false
    if [[ "$size_files" -gt 30 ]] || [[ "$size_lines" -gt 2000 ]]; then
      warn_large=true
    fi

    # Secret-path detection. The diff is sent to two external APIs (codex, gemini);
    # even rotated secrets should not leave the user's machine without consent.
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

    printf '{"worktree": "%s", "run_dir": "%s", "size_files": %d, "size_lines": %d, "base": "%s", "warn_large_diff": %s, "warn_secrets": %s, "risky_files": "%s"}\n' \
      "$worktree" "$run_dir" "$size_files" "$size_lines" "$base" "$warn_large" "$warn_secrets" "$risky_files"
    ;;

  end)
    worktree=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --worktree) worktree="$2"; shift 2 ;;
        *) echo "unknown arg: $1" >&2; usage ;;
      esac
    done
    [[ -n "$worktree" ]] || usage

    if [[ ! -d "$worktree" ]]; then
      # Already gone — idempotent success.
      echo '{"removed": false, "reason": "not-found"}'
      exit 0
    fi

    # Best-effort: let git do its bookkeeping first, then scrub filesystem.
    git worktree remove --force "$worktree" 2>/dev/null || true
    rm -rf "$worktree"
    # Prune stale tracking in any repo we can locate from the worktree parent.
    # (Worktrees may already be detached from a repo if --force was used.)
    printf '{"removed": true, "path": "%s"}\n' "$worktree"
    ;;

  sweep)
    hours=24
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --older-than-hours) hours="$2"; shift 2 ;;
        *) echo "unknown arg: $1" >&2; usage ;;
      esac
    done

    # BSD find (macOS) uses -mmin; that covers Linux too.
    minutes=$(( hours * 60 ))
    removed=0
    # shellcheck disable=SC2044
    for dir in $(find /tmp -maxdepth 1 -type d -name 'cr-*' -mmin +"$minutes" 2>/dev/null || true); do
      git worktree remove --force "$dir" 2>/dev/null || true
      rm -rf "$dir"
      removed=$((removed + 1))
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