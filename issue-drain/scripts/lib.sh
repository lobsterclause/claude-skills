#!/bin/bash
# lib.sh — helpers shared by the issue-drain scripts. Sourced, never run.
#
# Portability: macOS /bin/bash 3.2 and ubuntu bash 5. No associative arrays,
# no mapfile, no ${var,,}. JSON work is done in jq.

IDRAIN_SELF="$(basename "$0")"
IDRAIN_SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

die() { echo "$IDRAIN_SELF: $1" >&2; exit "${2:-1}"; }

# No default workdir. pr-drain's scripts once defaulted to a cwd-relative
# folder, and since every tool call starts wherever it starts, each call site
# got its own log: the 2026-09-17 drain wrote 1 event to its named workdir and
# 44 to the repo checkout. Same rule here, same reason.
need_workdir() {
  WORKDIR="${ISSUE_DRAIN_WORKDIR:-}"
  case "$WORKDIR" in
    /*) ;;
    *) die "set ISSUE_DRAIN_WORKDIR to an absolute path, e.g. \$HOME/.issue-drain/<owner>__<repo>/<run> (got '$WORKDIR')" 2 ;;
  esac
}

# REPO is used in file names and gh arguments, so its shape is checked.
need_repo() {
  REPO="${ISSUE_DRAIN_REPO:-}"
  printf '%s' "$REPO" | grep -Eq '^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$' ||
    die "set ISSUE_DRAIN_REPO to <owner>/<repo> (got '$REPO')" 2
}

# A local checkout of REPO (any worktree). Only read from: git show, git blame.
need_repo_dir() {
  REPO_DIR="${ISSUE_DRAIN_REPO_DIR:-}"
  case "$REPO_DIR" in
    /*) ;;
    *) die "set ISSUE_DRAIN_REPO_DIR to the absolute path of a local checkout (got '$REPO_DIR')" 2 ;;
  esac
  git -C "$REPO_DIR" rev-parse --git-dir >/dev/null 2>&1 ||
    die "ISSUE_DRAIN_REPO_DIR is not a git checkout: $REPO_DIR" 2
}

# Profile: per-repo settings. Defaults first, then the profile file overrides.
# A repo with no profile is an error, not a silent run on defaults: the hold
# labels and protected paths are the profile, and guessing them is how an
# agent ends up editing a workflow file.
load_profile() {
  BASE_BRANCH="main"
  HOLD_LABELS="needs-human blocked"
  CLAIM_LABEL="agent-in-progress"
  BLOCKED_LABEL="needs-human"
  TRACKER_LABEL="issue-drain"
  PRIORITY_LABELS=""
  PROTECTED_PATH_RE='^(\.github/workflows/|\.husky/|\.claude/)'
  RISK_PATH_RE=""
  TRUSTED_ASSOCIATIONS="OWNER MEMBER COLLABORATOR"
  INTAKE_CAP=40
  STALE_CLAIM_DAYS=3
  ISSUE_CLASSIFIER=""
  CLUSTER_MAX_ISSUES=4
  CLUSTER_MAX_LINES=400
  EVIDENCE_LINE_SLACK=3
  EVIDENCE_MIN_QUOTE=8
  ALLOWED_MODELS="haiku sonnet opus"
  ALLOWED_EFFORTS="low medium high"
  UNIT_PERMISSIONS="not set in the profile"

  local f="${ISSUE_DRAIN_PROFILE:-}"
  if [ -z "$f" ]; then
    need_repo
    f="$IDRAIN_SKILL_DIR/profiles/$(printf '%s' "$REPO" | sed 's|/|__|').env"
  fi
  [ -f "$f" ] || die "no profile at $f. Copy one from $IDRAIN_SKILL_DIR/profiles and edit it (see references/profile.md)" 2
  # shellcheck disable=SC1090
  . "$f"
  PROFILE_FILE="$f"
}

now_utc() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# log_event <event> [json-object]   append one line to <workdir>/events.jsonl
# Local state, so it is written in dry-run too: the log is a dry run's output.
log_event() {
  local event="$1" extra="${2:-}"
  [ -n "$extra" ] || extra='{}'
  mkdir -p "$WORKDIR"
  jq -cn --arg ts "$(now_utc)" --arg event "$event" --argjson extra "$extra" \
    '{ts: $ts, event: $event} + $extra' >> "$WORKDIR/events.jsonl"
}

is_dry_run() { [ "${ISSUE_DRAIN_DRY_RUN:-0}" = "1" ]; }

# A positive integer, nothing else. Issue numbers reach file names and gh.
is_number() { printf '%s' "${1:-}" | grep -Eq '^[1-9][0-9]*$'; }
