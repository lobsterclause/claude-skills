#!/usr/bin/env bash
# crash_logs.sh — list and optionally dump recent simulator crash reports.
#
# Usage:
#   crash_logs.sh [--bundle BUNDLE_ID] [--since MINUTES] [--dump N]
#
# Without --dump, returns a JSON list of recent crash files (path, app,
# timestamp). With --dump N, prints the Nth most recent crash report's
# full text to stdout.
#
# Simulator crash logs live at:
#   ~/Library/Logs/DiagnosticReports/*.ips
# Plus legacy .crash files. We scan both.

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${HERE}/lib/common.sh"

bundle=""; since_min=60; dump_idx=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --bundle) bundle="$2"; shift 2 ;;
    --since) since_min="$2"; shift 2 ;;
    --dump) dump_idx="$2"; shift 2 ;;
    *) die "unknown flag: $1" ;;
  esac
done

python3 - "${bundle}" "${since_min}" "${dump_idx}" <<'PY'
import json, os, subprocess, sys, time
from pathlib import Path

bundle, since_min, dump_idx = sys.argv[1], int(sys.argv[2]), sys.argv[3]
root = Path.home() / "Library/Logs/DiagnosticReports"
now = time.time()
cutoff = now - since_min * 60

reports = []
if root.exists():
    for p in root.iterdir():
        if p.suffix not in (".ips", ".crash"):
            continue
        try:
            mt = p.stat().st_mtime
        except OSError:
            continue
        if mt < cutoff:
            continue
        # .ips files have a 1-line JSON header followed by the report body.
        app = ""
        try:
            with p.open() as f:
                first = f.readline()
                header = json.loads(first)
                app = header.get("app_name") or header.get("process", "")
        except Exception:
            app = p.stem.split("-")[0]
        if bundle and bundle not in app and bundle not in p.stem:
            continue
        reports.append({
            "path": str(p),
            "app": app,
            "mtime": mt,
            "mtime_iso": time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(mt)),
        })

reports.sort(key=lambda r: r["mtime"], reverse=True)

if dump_idx:
    idx = int(dump_idx)
    if idx < 0 or idx >= len(reports):
        print(json.dumps({"ok": False, "error": f"no crash at index {idx}"}))
        sys.exit(1)
    print(open(reports[idx]["path"]).read())
    sys.exit(0)

print(json.dumps({
    "ok": True,
    "count": len(reports),
    "since_minutes": since_min,
    "crashes": reports,
    "hint": "Pass --dump N to print the Nth crash's full report." if reports else "No recent crashes.",
}, indent=2))
PY