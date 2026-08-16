# lib_project_namespace.sh — shared `derive_project()` for the fingerprint
# namespace (issue #39: fixing this in two scripts independently is how they
# drift; this file is sourced by fingerprint_findings.sh and
# migrate_finding_namespace.sh so there is exactly one derivation).
#
# derive_project <repo_root>
#   Echoes a namespace string that is stable per repo IDENTITY rather than
#   per checkout directory name. Two clones of the same repo (different
#   directory names) get the SAME namespace; two unrelated repos that happen
#   to share a directory basename (the bug in #39 — "api" and "api") get
#   DIFFERENT namespaces.
#
#   - Has an `origin` remote: "remote:<lowercased host>/<owner>/<repo>",
#     protocol/credentials/.git-suffix/trailing-slash stripped. Only the
#     HOST is lowercased — owner/repo keep exact case, matching the
#     already-shipped rule that fingerprint inputs stay case-sensitive
#     except where explicitly normalized (d619a3b, codex P2 PR #38).
#   - No `origin` remote: "path:<absolute, symlink-resolved repo root>" —
#     still unique per checkout, so two no-remote repos with the same
#     basename in different directories don't collide either.
#
#   The "remote:"/"path:" prefix keeps the two kinds of namespace from ever
#   colliding with each other (a repo literally named "path:/foo" can't
#   spoof a no-remote fallback, and vice versa).
#
# Not sourced (no shebang, no set -e of its own) — inherits the caller's
# shell options. Callers must have already verified $1 is a real directory.

derive_project() {
  local repo_root="$1" remote_url host host_lc path_part

  remote_url="$(git -C "$repo_root" remote get-url origin 2>/dev/null || true)"

  if [[ -n "$remote_url" ]]; then
    # Strip protocol (https://, http://, ssh://, git://) and any userinfo
    # (user:pass@ or x-access-token:TOKEN@) so a credential embedded in the
    # remote URL never ends up baked into a fingerprint id.
    host="$remote_url"
    host="${host#*://}"
    host="${host#*@}"
    # scp-like syntax: git@host:owner/repo -> host/owner/repo
    if [[ "$remote_url" == *"://"* ]]; then
      : # already an authority-style URL, host/path split below
    else
      host="${host/:/\/}"
    fi
    host="${host%/}"
    host="${host%.git}"
    # Lowercase only the host (first path component); leave owner/repo as-is.
    path_part="${host#*/}"
    host="${host%%/*}"
    if [[ "$path_part" == "$host" ]]; then
      # No slash at all — malformed/local remote with no owner/repo; fall
      # through to the path-based namespace instead of trusting this.
      remote_url=""
    else
      host_lc="$(printf '%s' "$host" | tr '[:upper:]' '[:lower:]')"
      printf 'remote:%s/%s\n' "$host_lc" "$path_part"
      return 0
    fi
  fi

  # No usable remote — namespace on the absolute, symlink-resolved repo
  # root instead. `cd ... && pwd -P` resolves symlinks the same way
  # `git rev-parse --show-toplevel` already does for repo_root callers.
  printf 'path:%s\n' "$(cd "$repo_root" && pwd -P)"
}
