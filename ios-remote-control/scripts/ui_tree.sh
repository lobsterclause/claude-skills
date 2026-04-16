#!/usr/bin/env bash
# ui_tree.sh — dump the simulator's accessibility tree as JSON.
#
# Usage: ui_tree.sh [--udid UDID] [--filter SUBSTRING] [--raw]
#
# The tree is the text-only counterpart to a screenshot: every UI element
# with its label, value, frame ({x,y,width,height}), and type. Use this
# instead of a screenshot when:
#   - You know the label/accessibility-id of the element you want
#   - You need exact coordinates for tap.sh (use the frame's center)
#   - Token budget matters more than pixel-perfect vision
#
# --filter substring-matches against the element's label + accessibility id.
# --raw prints idb's verbose output without simplification.

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${HERE}/lib/common.sh"

udid=""; filter=""; raw=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --udid) udid="$2"; shift 2 ;;
    --filter) filter="$2"; shift 2 ;;
    --raw) raw=true; shift ;;
    *) die "unknown flag: $1" ;;
  esac
done

udid="$(resolve_udid "${udid:-booted}")"
idb="$(idb_path)" || die "idb not installed"
ensure_idb_connected "${udid}"

raw_json="$("${idb}" ui describe-all --udid "${udid}" --json 2>/dev/null)" \
  || die "ui describe-all failed" "Try: ${idb} connect ${udid}"

if [[ "${raw}" == true ]]; then
  printf '%s\n' "${raw_json}"
  exit 0
fi

# Simplify: keep the fields an agent actually needs to decide where to tap.
python3 - "${raw_json}" "${filter}" <<'PY'
import json, sys

raw, filt = sys.argv[1], sys.argv[2].lower()
try:
    nodes = json.loads(raw) if raw.strip() else []
except json.JSONDecodeError:
    nodes = []

def simplify(n):
    frame = n.get("frame", {}) or {}
    return {
        "type": n.get("type", ""),
        "label": n.get("AXLabel") or n.get("label") or "",
        "value": n.get("AXValue") or n.get("value") or "",
        "accessibility_id": n.get("AXUniqueId") or n.get("accessibility_id") or "",
        "enabled": n.get("enabled", True),
        "frame": {
            "x": frame.get("x", 0), "y": frame.get("y", 0),
            "width": frame.get("width", 0), "height": frame.get("height", 0),
        },
        "center": {
            "x": round(frame.get("x", 0) + frame.get("width", 0) / 2, 1),
            "y": round(frame.get("y", 0) + frame.get("height", 0) / 2, 1),
        },
    }

items = [simplify(n) for n in nodes if isinstance(n, dict)]

if filt:
    items = [
        i for i in items
        if filt in i["label"].lower()
        or filt in i["accessibility_id"].lower()
        or filt in i["value"].lower()
    ]

print(json.dumps({
    "ok": True,
    "count": len(items),
    "elements": items,
    "hint": "Use element.center.x/y as coordinates for tap.sh.",
}, indent=2))
PY
