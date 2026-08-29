#!/usr/bin/env bash
# read_stamp.sh — THE parser for cross-review record stamps.
#
# A review record carries its provenance twice: a machine-readable HTML marker
#   <!-- cross-review: sha=<40> base=<40> pass=<n> digest=<64> -->
# and a human-readable prose line
#   Reviewed `abc123def`.
#
# Until 2026-08-22 each consumer parsed its own: merge_preflight.sh (the hook
# that actually blocks merges) read the PROSE, while ci/cross-review-currency.sh
# read the MARKER. Two stamps, two readers, nothing tying them together -- and
# it bit for real: a record corrected in the marker alone left the merge gate
# clearing on a prose stamp that had been superseded. A guarantee that lives in
# two parsers is not a guarantee. This file is the one parser; both consumers
# call it, and the format is described in exactly one place.
#
# Usage:
#   read_stamp.sh --body-file <f>     parse one comment body
#   read_stamp.sh --body-stdin        parse one comment body from stdin
#
# Emits one JSON object on stdout:
#   {"stamped":bool,"sha":"","base":"","pass":n,"digest":"","source":"marker|prose|none","abbrev":n}
#
# `source` matters to callers: a marker gives a full 40-char sha plus the base
# and digest that range coverage needs; prose gives an abbreviated sha and
# nothing else. Prose is a COMPATIBILITY path for records written before the
# marker existed (and for the handful written by hand) -- never the preferred
# one. When both are present and disagree, the marker wins and the
# disagreement is reported, because a record whose two halves contradict each
# other is exactly the corruption this file exists to surface.
set -uo pipefail

body=""
case "${1:-}" in
  --body-file)  body="$(cat "${2:?--body-file needs a path}" 2>/dev/null || true)" ;;
  --body-stdin) body="$(cat)" ;;
  *) echo "usage: read_stamp.sh --body-file <f> | --body-stdin" >&2; exit 2 ;;
esac

# The marker is authoritative. Anchored on the full 40-char form: an abbreviated
# sha in a marker is not a marker this repo wrote.
# Exactly ONE marker is extracted first, then its fields are read from that
# marker alone: reading each field from the whole body let the sha of the
# record's own marker combine with the base= or digest= of a marker quoted
# inside its findings (codex, PR #67 review).
marker="$(grep -oE '<!-- cross-review: sha=[0-9a-f]{40}[^>]*-->' <<<"$body" 2>/dev/null | head -1)"
m_sha="$(sed -nE 's/.*sha=([0-9a-f]{40}).*/\1/p' <<<"$marker" | head -1)"
m_base="$(sed -nE 's/.*[[:space:]]base=([0-9a-f]{40}).*/\1/p' <<<"$marker" | head -1)"
m_pass="$(sed -nE 's/.*[[:space:]]pass=([0-9]+).*/\1/p' <<<"$marker" | head -1)"
m_dig="$(sed -nE 's/.*[[:space:]]digest=([0-9a-f]{64}).*/\1/p' <<<"$marker" | head -1)"

# Prose fallback. Deliberately NOT `Reviewed at` -- see post_comment.sh: four
# hand-written records used that phrasing and a working gate read them as
# unstamped. One English word decided whether a merge was gated.
p_sha="$(sed -nE 's/.*Reviewed `([0-9a-f]{7,40})`.*/\1/p' <<<"$body" | head -1)"

warn=""
if [[ -n "$m_sha" && -n "$p_sha" ]]; then
  n="${#p_sha}"
  if [[ "${m_sha:0:$n}" != "$p_sha" ]]; then
    warn="marker sha=${m_sha:0:9} disagrees with prose sha=${p_sha} in the same record"
    echo "read_stamp: WARNING: $warn" >&2
  fi
fi

if [[ -n "$m_sha" ]]; then
  jq -cn --arg s "$m_sha" --arg b "$m_base" --arg d "$m_dig" \
         --argjson p "${m_pass:-0}" --arg w "$warn" \
    '{stamped:true, sha:$s, base:$b, pass:$p, digest:$d, source:"marker", abbrev:40,
      disagreement:(if $w == "" then null else $w end)}'
elif [[ -n "$p_sha" ]]; then
  jq -cn --arg s "$p_sha" --argjson n "${#p_sha}" \
    '{stamped:true, sha:$s, base:"", pass:0, digest:"", source:"prose", abbrev:$n,
      disagreement:null}'
else
  jq -cn '{stamped:false, sha:"", base:"", pass:0, digest:"", source:"none", abbrev:0,
           disagreement:null}'
fi
