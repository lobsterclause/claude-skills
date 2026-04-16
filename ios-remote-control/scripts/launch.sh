#!/usr/bin/env bash
# launch.sh — launch an installed app by bundle id.
#
# Usage: launch.sh BUNDLE_ID [--udid UDID] [--console] [--env KEY=VAL]... [-- ARG1 ARG2]
#
# --console streams the app's stdout/stderr inline (blocks until the app
# exits or you Ctrl-C). Without it, the script returns immediately once
# the app has launched.
#
# --env sets environment variables visible to the app process. Repeatable.
# Anything after `--` is passed as launch argv to the app.

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${HERE}/lib/common.sh"

[[ $# -lt 1 ]] && die "missing bundle id" "Usage: launch.sh com.example.app [--udid UDID]"
bundle="$1"; shift

udid=""; console=false; env_pairs=(); app_args=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --udid) udid="$2"; shift 2 ;;
    --console) console=true; shift ;;
    --env) env_pairs+=("$2"); shift 2 ;;
    --) shift; app_args=("$@"); break ;;
    *) die "unknown flag: $1" ;;
  esac
done

udid="$(resolve_udid "${udid:-booted}")"
ensure_booted "${udid}"

# simctl launch passes env vars via SIMCTL_CHILD_<NAME> exported into its
# own environment. We convert --env KEY=VAL pairs into that shape.
declare -a sim_env=()
for pair in "${env_pairs[@]+"${env_pairs[@]}"}"; do
  key="${pair%%=*}"
  val="${pair#*=}"
  sim_env+=("SIMCTL_CHILD_${key}=${val}")
done

launch_flags=()
[[ "${console}" == true ]] && launch_flags+=(--console-pty)

launch_cmd=(xcrun simctl launch "${launch_flags[@]+"${launch_flags[@]}"}" "${udid}" "${bundle}" "${app_args[@]+"${app_args[@]}"}")
if [[ ${#sim_env[@]} -gt 0 ]]; then
  launch_cmd=(env "${sim_env[@]}" "${launch_cmd[@]}")
fi

if ! pid="$("${launch_cmd[@]}" 2>&1)"; then
  die "launch failed for ${bundle}" "Ensure the app is installed: run install.sh first."
fi

# simctl launch prints "<bundle>: <pid>" on success. Parse the pid.
pid_num="${pid##*: }"

python3 -c '
import json, sys
print(json.dumps({
    "ok": True, "action": "launch",
    "bundle_id": sys.argv[1], "pid": sys.argv[2].strip(),
    "udid": sys.argv[3],
}))
' "${bundle}" "${pid_num}" "${udid}"