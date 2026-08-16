#!/usr/bin/env bash
# test_fingerprint_namespace.sh — standalone offline fixture test for
# derive_project() (lib_project_namespace.sh) and fingerprint_findings.sh's
# --repo-root flag. NO network, no reviewer CLIs, no tokens.
#
# Mirrors test_profiles.sh's fixture/assertion conventions but is
# intentionally NOT wired into run_tests.sh (same collision-avoidance
# pattern as test_digest.sh / test_profiles.sh).
#
# Covers issue #39: two repos checked out under the same directory basename
# used to mint identical f-<hash> ids and merge their lifecycle events in
# the one global finding_events.jsonl. --repo-root fixes this by namespacing
# on repo identity (remote URL, or absolute path with no remote) instead of
# the checkout directory's basename.
#
# Run:  bash tests/test_fingerprint_namespace.sh
# Exit: 0 all green, 1 any failure.

set -uo pipefail

SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
LIB="$SKILL_DIR/scripts/lib_project_namespace.sh"
FINGERPRINT="$SKILL_DIR/scripts/fingerprint_findings.sh"

PASS=0
FAIL=0
ok()  { echo "  ok   $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL $1"; FAIL=$((FAIL + 1)); }
assert_eq() {
  if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 (got: '$2' want: '$3')"; fi
}
assert_ne() {
  if [[ "$2" != "$3" ]]; then ok "$1"; else bad "$1 (both were: '$2')"; fi
}

command -v jq >/dev/null 2>&1 || { echo "jq required to run these tests" >&2; exit 1; }
[[ -f "$LIB" ]] || { echo "FATAL: $LIB missing"; exit 1; }
[[ -f "$FINGERPRINT" ]] || { echo "FATAL: $FINGERPRINT missing"; exit 1; }

# shellcheck source=../scripts/lib_project_namespace.sh
source "$LIB"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mk_repo() {
  # mk_repo <dir> <remote-or-empty>
  local dir="$1" remote="$2"
  mkdir -p "$dir"
  git -C "$dir" init -q
  if [[ -n "$remote" ]]; then
    git -C "$dir" remote add origin "$remote"
  fi
}

echo "── two repos sharing a directory basename but different remotes get different namespaces (issue #39) ──"
mk_repo "$TMP/repo-a/api" "https://github.com/org-one/api.git"
mk_repo "$TMP/repo-b/api" "https://github.com/org-two/api.git"
ns_a="$(derive_project "$TMP/repo-a/api")"
ns_b="$(derive_project "$TMP/repo-b/api")"
assert_ne "same-basename different-remote repos get different namespaces" "$ns_a" "$ns_b"
assert_eq "namespace derived from remote is remote-prefixed" "${ns_a%%:*}" "remote"

echo "── remote URL normalization: protocol, credentials, .git suffix stripped; host lowercased; owner/repo case preserved ──"
mk_repo "$TMP/repo-https" "https://GitHub.com/Org-One/API.git"
mk_repo "$TMP/repo-ssh" "git@GitHub.com:Org-One/API.git"
mk_repo "$TMP/repo-cred" "https://x-access-token:secret123@github.com/Org-One/API.git"
ns_https="$(derive_project "$TMP/repo-https")"
ns_ssh="$(derive_project "$TMP/repo-ssh")"
ns_cred="$(derive_project "$TMP/repo-cred")"
assert_eq "https and ssh remotes for the same repo normalize to the same namespace" "$ns_https" "$ns_ssh"
assert_eq "credentials embedded in the remote URL never leak into the namespace" "$ns_cred" "$ns_https"
assert_eq "owner/repo path segment keeps exact case (only host is lowercased)" "$ns_https" "remote:github.com/Org-One/API"

echo "── two remote-less repos with the same basename in different directories don't collide ──"
mk_repo "$TMP/no-remote-x/widget" ""
mk_repo "$TMP/no-remote-y/widget" ""
ns_x="$(derive_project "$TMP/no-remote-x/widget")"
ns_y="$(derive_project "$TMP/no-remote-y/widget")"
assert_ne "path-based fallback differs for different absolute paths" "$ns_x" "$ns_y"
assert_eq "path-based namespace is path-prefixed" "${ns_x%%:*}" "path"

echo "── remote-based and path-based namespaces can never collide with each other ──"
# A hypothetical remote whose normalized form equals a real path string
# would be a spoofing vector if the two kinds of namespace shared a prefix.
assert_ne "remote: prefix differs from path: prefix" "remote:x" "path:x"

echo "── fingerprint_findings.sh --repo-root end-to-end: same finding, two same-basename repos, different ids ──"
mk_repo "$TMP/checkout-1/svc" "https://github.com/acme/svc.git"
mk_repo "$TMP/checkout-2/svc" "https://github.com/beta-corp/svc.git"
findings_json="$TMP/findings.json"
cat > "$findings_json" <<'EOF'
{"findings":[{"id":"f1","severity":"P1","file":"src/app.ts","line":10,"snippet":"x","claim":"Null check missing before dereference"}]}
EOF
out_1="$TMP/out-1.json"
out_2="$TMP/out-2.json"
"$FINGERPRINT" --findings "$findings_json" --out "$out_1" --repo-root "$TMP/checkout-1/svc"
"$FINGERPRINT" --findings "$findings_json" --out "$out_2" --repo-root "$TMP/checkout-2/svc"
id_1="$(jq -r '.findings[0].id' "$out_1")"
id_2="$(jq -r '.findings[0].id' "$out_2")"
assert_ne "same finding in two same-basename repos gets different f-<hash> ids via --repo-root" "$id_1" "$id_2"

echo "── fingerprint_findings.sh: --project and --repo-root are mutually exclusive ──"
if "$FINGERPRINT" --findings "$findings_json" --out "$TMP/out-bad.json" \
     --project literal --repo-root "$TMP/checkout-1/svc" 2>"$TMP/err.txt"; then
  bad "--project + --repo-root together should exit non-zero"
else
  ok "--project + --repo-root together exits non-zero"
fi
assert_eq "rejection message names the conflict" \
  "$(grep -c "mutually exclusive" "$TMP/err.txt")" "1"

echo "── fingerprint_findings.sh: --repo-root pointing at a non-directory fails cleanly ──"
if "$FINGERPRINT" --findings "$findings_json" --out "$TMP/out-bad2.json" \
     --repo-root "$TMP/does-not-exist" 2>"$TMP/err2.txt"; then
  bad "--repo-root on a missing directory should exit non-zero"
else
  ok "--repo-root on a missing directory exits non-zero"
fi

echo "── fingerprint_findings.sh: --project literal override still works unchanged ──"
out_lit="$TMP/out-lit.json"
"$FINGERPRINT" --findings "$findings_json" --out "$out_lit" --project "my-literal-project"
assert_eq "--project produces an f-<hash> id" "$(jq -r '.findings[0].id' "$out_lit" | cut -c1-2)" "f-"

echo
echo "══ $PASS passed, $FAIL failed ══"
[[ "$FAIL" -eq 0 ]]
