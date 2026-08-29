#!/usr/bin/env bash
# range_coverage.sh — does a set of review records cover a PR's commits?
#
# Point-equality gating ("was the head reviewed?") has a structural flaw: every
# fix that answers a finding moves the head, so the record containing the
# finding stops covering the code. Three rounds on PR #66 hit this in one
# session -- each round found real defects, each fix restaled the record that
# found them, and the only escapes were a fourth round or an override. Neither
# is a check; one is a treadmill and the other is a bypass.
#
# Coverage is the right question. Round 1 covers base..A, round 2 covers A..B,
# round 3 covers B..head; no single record covers base..head but together they
# cover every commit in it, and that is what "reviewed" honestly means.
#
# Usage:
#   range_coverage.sh --base <sha> --head <sha> --records <json-array>
#
# records: [{"sha":"<head>","base":"<base>","digest":"<64>"} ...]
# Emits: {"covered":bool,"reason":"...","uncovered":["<sha> <subject>"...],
#         "covered_by":n,"method":"digest|commits|none"}
set -uo pipefail

base="" head="" records="[]"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --base)    base="${2:?}";    shift 2 ;;
    --head)    head="${2:?}";    shift 2 ;;
    --records) records="${2:?}"; shift 2 ;;
    *) echo "range_coverage: unknown arg $1" >&2; exit 2 ;;
  esac
done
[[ -n "$base" && -n "$head" ]] || { echo "usage: --base <sha> --head <sha> [--records <json>]" >&2; exit 2; }

emit() { jq -cn --argjson c "$1" --arg r "$2" --argjson u "${3:-[]}" \
                --argjson n "${4:-0}" --arg m "${5:-none}" \
  '{covered:$c, reason:$r, uncovered:$u, covered_by:$n, method:$m}'; exit 0; }

resolves() { git rev-parse --verify -q "$1^{commit}" >/dev/null 2>&1; }
# sha256 of stdin, portable: GNU coreutils sha256sum or perl shasum (macOS).
sha256() { if command -v sha256sum >/dev/null 2>&1; then sha256sum; else shasum -a 256; fi; }

# --- 1. Digest equality: the rebase-proof path -------------------------------
# A rebase rewrites every sha while changing nothing a reviewer read, so
# commit-id coverage collapses to zero on a PR that was merely rebased. If a
# record digested the SAME CONTENT this PR now presents, it covers the PR
# whatever the ids say. Checked FIRST: it is both cheaper and strictly more
# truthful than id matching.
if resolves "$base" && resolves "$head"; then
  cur_digest="$(git diff "$base" "$head" 2>/dev/null | sha256 2>/dev/null | cut -d' ' -f1)"
  if [[ "$cur_digest" =~ ^[0-9a-f]{64}$ ]]; then
    if jq -e --arg d "$cur_digest" 'any(.[]; .digest == $d)' <<<"$records" >/dev/null 2>&1; then
      emit true "a record digests the identical diff (survives a rebase)" '[]' 1 "digest"
    fi
  fi
fi

# --- 2. Commit-set coverage --------------------------------------------------
# Exact, not heuristic: enumerate the commits the PR actually introduces, then
# subtract what each record's range covers. What remains is precisely the code
# no reviewer has seen -- which is the sentence a human needs, rather than a
# yes/no.
if ! resolves "$base" || ! resolves "$head"; then
  emit false "cannot resolve $base..$head locally (fetch the branch, or the history was rewritten)" '[]' 0 "none"
fi

# bash 3.2 (stock macOS /bin/bash) has no mapfile and no associative arrays;
# merge_preflight.sh swallows a parse error as "coverage unavailable", so the
# whole union path was silently dead there (kimi High + codex, PR #67 review).
# Commit sets are newline-delimited strings; membership is grep -qxF.
pr_commits=()
while IFS= read -r c; do [[ -n "$c" ]] && pr_commits+=("$c"); done < <(git rev-list "$base..$head" 2>/dev/null)
if [[ ${#pr_commits[@]} -eq 0 ]]; then
  emit true "no commits between base and head — nothing to cover" '[]' 0 "commits"
fi

covered=$'\n'
used=0
while IFS= read -r rec; do
  [[ -z "$rec" ]] && continue
  r_head="$(jq -r '.sha // ""'  <<<"$rec")"
  r_base="$(jq -r '.base // ""' <<<"$rec")"
  # A record with no base covers exactly ONE commit: its own head. That is the
  # honest reading of a head-only stamp -- it asserts "this commit was
  # reviewed" and says nothing whatever about the commit before it. Treating a
  # legacy stamp as covering everything behind it would silently bless the
  # entire history on the strength of a single point.
  if [[ -z "$r_base" ]]; then
    [[ -n "$r_head" ]] && resolves "$r_head" && { covered+="$(git rev-parse "$r_head")"$'\n'; used=$((used+1)); }
    continue
  fi
  resolves "$r_base" && resolves "$r_head" || continue
  any=0
  while IFS= read -r c; do [[ -n "$c" ]] && covered+="$c"$'\n' && any=1; done \
    < <(git rev-list "$r_base..$r_head" 2>/dev/null)
  [[ "$any" -eq 1 ]] && used=$((used+1))
done < <(jq -c '.[]' <<<"$records" 2>/dev/null)

uncovered=()
for c in "${pr_commits[@]}"; do
  printf '%s' "$covered" | grep -qxF -- "$c" || uncovered+=("$c $(git log -1 --format=%s "$c" 2>/dev/null | cut -c1-60)")
done

if [[ ${#uncovered[@]} -eq 0 ]]; then
  emit true "all ${#pr_commits[@]} commit(s) covered by $used record(s)" '[]' "$used" "commits"
fi

u_json="$(printf '%s\n' ${uncovered[@]+"${uncovered[@]}"} | jq -R . | jq -s .)"
emit false "${#uncovered[@]} of ${#pr_commits[@]} commit(s) not covered by any review record" \
  "$u_json" "$used" "commits"
