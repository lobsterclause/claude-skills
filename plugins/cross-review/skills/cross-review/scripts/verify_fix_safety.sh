#!/usr/bin/env bash
# verify_fix_safety.sh — deterministic gate between step 4.5 (anchor +
# factcheck) verification and "apply the change" in cross-review/SKILL.md
# step 5. Anchor checks WHERE a finding points; factcheck checks whether the
# diff CONTRADICTS the claim. Neither checks whether the reviewer's SUGGESTED
# FIX is itself safe to auto-apply. A crafted diff can get multiple reviewers
# to converge on a plausible-sounding but dangerous "fix" — e.g. "remove this
# redundant check", "this validation is now unnecessary", "this auth guard is
# dead code" — which then sails through anchor+factcheck (both are about the
# FINDING's honesty, not the FIX's safety) and gets auto-committed. That's a
# laundering path for supply-chain-style sabotage through the review process.
#
# This script inspects the proposed fix's own diff for patterns that are
# common vectors for exactly that: removed auth/permission guards, weakened
# input validation, disabled/deleted tests, and narrowed-then-broadened
# security-relevant regexes. No LLM, no network, no tokens — pure pattern
# matching over diff text, cheap enough to run on every proposed fix.
#
# FAIL-SAFE DIRECTION IS THE OPPOSITE OF factcheck_findings.sh: factcheck
# defaults to keep-everything (recall-safe) because silently dropping a real
# finding is the expensive mistake there. Here the expensive mistake is
# auto-committing a dangerous change, so ambiguity — an empty, missing, or
# unreadable diff — defaults to safe:false (hold for human confirmation).
# "No dangerous pattern matched" is NOT ambiguity; that is the normal
# safe:true path so this gate isn't trivially always-false.
#
# Usage:
#   verify_fix_safety.sh --diff <patch-file> [--out <json>] [--finding-id <id>]
#
# patch-file: a unified diff of ONLY the proposed fix (e.g. `git diff`/
# `git show` output for the change about to be committed, or a hand-built
# patch). Only lines beginning with a single '-' or '+' (not the '---'/'+++'
# file headers, not '@@' hunk headers) are inspected.
#
# Output (written to --out if given, always echoed to stdout):
#   { "safe": bool, "reason": "...", "matched": ["<category>", ...],
#     "finding_id": "<id-or-null>" }
#
# Exit: 0 always — the verdict lives in the JSON (`.safe`), same as callers
# branch on `.factcheck.verdict` rather than on exit code. 2 on usage error.

set -uo pipefail

diff_file="" ; out="" ; finding_id=""

need_val() { [[ "$2" -lt 2 ]] && { echo "missing value for $1" >&2; exit 2; }; }
while [[ $# -gt 0 ]]; do
  case "$1" in
    --diff)       need_val "$1" "$#"; diff_file="$2";  shift 2 ;;
    --out)        need_val "$1" "$#"; out="$2";         shift 2 ;;
    --finding-id) need_val "$1" "$#"; finding_id="$2";  shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

[[ -z "$diff_file" ]] && { echo "usage: $0 --diff <patch-file> [--out <json>] [--finding-id <id>]" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "verify_fix_safety: jq required" >&2; exit 1; }

tmp_dir="$(mktemp -d)"; trap 'rm -rf "$tmp_dir"' EXIT

# write_verdict <safe:true|false> <reason> [category...] — writes the JSON to
# --out (if given) and to stdout, then exits 0. Single exit path so every
# branch below (including the fail-safe ones) produces the same shape.
write_verdict() {
  local safe="$1" reason="$2"; shift 2
  local matched_json
  if [[ "$#" -eq 0 ]]; then
    matched_json="[]"
  else
    matched_json="$(printf '%s\n' "$@" | jq -R . | jq -s .)"
  fi
  local fid_json="null"
  [[ -n "$finding_id" ]] && fid_json="$(jq -Rn --arg v "$finding_id" '$v')"
  local doc
  doc="$(jq -n --argjson safe "$safe" --arg reason "$reason" --argjson matched "$matched_json" --argjson fid "$fid_json" \
    '{safe: $safe, reason: $reason, matched: $matched, finding_id: $fid}')"
  if [[ -n "$out" ]]; then printf '%s\n' "$doc" > "$out"; fi
  printf '%s\n' "$doc"
  exit 0
}

[[ -f "$diff_file" ]] || write_verdict false "diff file not found: $diff_file (fail-safe)"
[[ -s "$diff_file" ]] || write_verdict false "empty diff — nothing to verify (fail-safe)"

# Split into removed/added line bodies (marker char stripped), excluding the
# '--- a/file' / '+++ b/file' path headers so those don't pollute the match.
removed="$tmp_dir/removed.txt"
added="$tmp_dir/added.txt"
awk '/^--- / { next } /^-/ { print substr($0, 2) }' "$diff_file" > "$removed"
awk '/^\+\+\+ / { next } /^\+/ { print substr($0, 2) }' "$diff_file" > "$added"

[[ -s "$removed" || -s "$added" ]] || write_verdict false "no +/- diff lines found — not a unified diff (fail-safe)"

# count_matches <regex> <file> — case-insensitive match count, 0 on no match
# (grep -c exits 1 with no matches; -Ei keeps this portable to macOS grep).
count_matches() {
  local n
  n="$(grep -Eic -- "$1" "$2" 2>/dev/null)" || n=0
  printf '%s' "${n:-0}"
}

matched=()
reasons=()

# ── 1. Authorization / permission guard removed ─────────────────────────────
# Net removal (removed count > added count) of an auth-guard-shaped line: a
# negated-condition auth/permission check, or a thrown Unauthorized/Forbidden.
# A guard that's merely reformatted (same shape re-added elsewhere in the
# hunk) is not penalized — only a net decrease counts.
auth_re='(if[^;{]*![^;{]*\bauth)|(if[^;{]*![^;{]*\bpermit)|(if[^;{]*![^;{]*\bauthoriz)|(throw[^;]*\bunauthoriz)|(throw[^;]*\bforbidden)'
auth_removed="$(count_matches "$auth_re" "$removed")"
auth_added="$(count_matches "$auth_re" "$added")"
if [[ "$auth_removed" -gt "$auth_added" ]]; then
  matched+=("auth_guard_removed")
  reasons+=("an authorization/permission check or Unauthorized/Forbidden throw was removed without an equivalent replacement")
fi

# ── 2. Input validation weakened ─────────────────────────────────────────────
# Net removal of a validation-shaped line (regex test/match, length/type
# check, validate/sanitize/isValid call) without a replacement of the same
# shape landing elsewhere in the diff.
valid_re='(\.test\()|(\.match\()|(new RegExp)|(length[[:space:]]*[<>]=?)|(typeof[[:space:]])|(instanceof[[:space:]])|(isValid)|(\bvalidate)|(\bsanitize)'
valid_removed="$(count_matches "$valid_re" "$removed")"
valid_added="$(count_matches "$valid_re" "$added")"
if [[ "$valid_removed" -gt "$valid_added" ]]; then
  matched+=("validation_weakened")
  reasons+=("an input validation check (regex/length/type) was removed without an equivalent or stronger replacement")
fi

# ── 3. Test disabled or deleted ─────────────────────────────────────────────
# (a) a skip marker was newly introduced by the fix.
skip_re='(\.skip\()|(\bxit\()|(\bxdescribe\()'
skip_added="$(count_matches "$skip_re" "$added")"
if [[ "$skip_added" -gt 0 ]]; then
  matched+=("test_disabled")
  reasons+=("the fix introduces a .skip()/xit()/xdescribe() marker, disabling a test")
fi
# (b) a net removal of it(/test(/describe( blocks — a test being deleted
# outright rather than reworked in place.
test_block_re='\b(it|test|describe)\('
test_removed="$(count_matches "$test_block_re" "$removed")"
test_added="$(count_matches "$test_block_re" "$added")"
if [[ "$test_removed" -gt "$test_added" ]]; then
  matched+=("test_deleted")
  reasons+=("the fix has a net removal of it()/test()/describe() blocks — a test is being deleted, not reworked")
fi

# ── 4. Security-relevant regex weakened ──────────────────────────────────────
# A regex literal anchored at both ends (^...$ — the shape of an allowlist or
# a strict format check) is removed without an equally-anchored replacement.
# Losing the anchors, or losing the regex line entirely, broadens what the
# pattern will accept.
anchored_regex_re='/\^[^/]*\$/'
anchored_removed="$(count_matches "$anchored_regex_re" "$removed")"
anchored_added="$(count_matches "$anchored_regex_re" "$added")"
if [[ "$anchored_removed" -gt "$anchored_added" ]]; then
  matched+=("regex_weakened")
  reasons+=("an anchored allowlist/format regex (^...\$) was removed or had its anchors dropped, broadening what it accepts")
fi

if [[ "${#matched[@]}" -eq 0 ]]; then
  write_verdict true "no dangerous patterns detected in the proposed fix"
else
  joined_reason="$(printf '%s; ' "${reasons[@]}")"
  joined_reason="${joined_reason%; }"
  write_verdict false "$joined_reason" "${matched[@]}"
fi
