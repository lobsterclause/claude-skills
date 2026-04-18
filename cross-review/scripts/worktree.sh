#!/usr/bin/env bash
# worktree.sh — manage ephemeral git worktrees for cross-review runs.
#
# Subcommands:
#   start --ref <branch-or-sha> --id <slug> [--base <branch>]
#     Creates $HOME/.cross-review/worktrees/cr-<slug>-<ts>-<pid>/ (detached worktree at <ref>)
#     Creates $HOME/.cross-review/runs/<repo>-<slug>-<ts>-<pid>/ (stable output dir)
#     Runs size + secret-path checks and emits a single JSON line.
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

set -euo pipefail

WORKTREE_ROOT="$HOME/.cross-review/worktrees"
RUN_ROOT="$HOME/.cross-review/runs"

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

    ts="$(date +%Y%m%dT%H%M%S)"
    pid="$$"
    # Slugify id so it's filesystem-safe.
    slug="$(echo -n "$id" | tr -c 'A-Za-z0-9._-' '-' | sed 's/-\{2,\}/-/g; s/^-//; s/-$//')"
    run_name="${repo_name}-${slug}-${ts}-${pid}"
    wt_name="cr-${slug}-${ts}-${pid}"
    worktree="$WORKTREE_ROOT/$wt_name"
    run_dir="$RUN_ROOT/$run_name"

    mkdir -p "$WORKTREE_ROOT" "$run_dir/raw"

    # Detached worktree so we don't take over the branch in the main checkout.
    # --force because in rare cases the ref may be "in use" elsewhere.
    if ! git worktree add -d --force "$worktree" "$ref" >/dev/null 2>&1; then
      echo "git worktree add failed for ref: $ref" >&2
      exit 1
    fi

    # Size check — run inside the worktree.
    size_files=$(git -C "$worktree" diff --name-only "$base"...HEAD 2>/dev/null | wc -l | tr -d ' ' || true)
    # grep can return non-zero on empty/rename-only diffs; tolerate under pipefail.
    size_lines=$(git -C "$worktree" diff --shortstat "$base"...HEAD 2>/dev/null \
      | { grep -oE '[0-9]+ insertion|[0-9]+ deletion' || true; } \
      | awk '{s+=$1} END{print s+0}' || true)
    [[ "$size_files" =~ ^[0-9]+$ ]] || size_files=0
    [[ "$size_lines" =~ ^[0-9]+$ ]] || size_lines=0

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
        --worktree) need_val --worktree "$#"; worktree="$2"; shift 2 ;;
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

    # BSD find (macOS) uses -mmin; that covers Linux too.
    # Use -print0 + null-separated read to survive paths containing spaces.
    # `rm -rf "$dir"` on a word-split token is a known data-loss footgun.
    minutes=$(( hours * 60 ))
    removed=0
    # Check both the canonical location and legacy /tmp — users upgrading from
    # the earlier skill version may still have /tmp/cr-* leftovers.
    for root in "$WORKTREE_ROOT" "/tmp"; do
      [[ -d "$root" ]] || continue
      while IFS= read -r -d '' dir; do
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