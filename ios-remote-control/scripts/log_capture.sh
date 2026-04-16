#!/usr/bin/env bash
# log_capture.sh — capture simulator logs to a file. Alias for log_tail --save.
#
# Usage: log_capture.sh [--duration SECONDS] [--bundle BUNDLE_ID] [--udid UDID]

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "${HERE}/log_tail.sh" --save "$@"