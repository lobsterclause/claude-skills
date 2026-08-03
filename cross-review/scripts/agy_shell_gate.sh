#!/usr/bin/env bash
# agy_shell_gate.sh — PreToolUse hook for the agy (Antigravity) reviewer laps.
#
# WHY THIS EXISTS
# agy ≥1.1.3 soft-denies any tool that needs a "command" permission when it
# runs headless (`-p`), because headless mode has no way to prompt. A single
# soft-denied command ends the whole conversation with rc=0 and ZERO bytes of
# output — the entire review is lost (see docs/investigation-agy-empty-output.md
# and the 2026-07-31 repro: the models reached for `git rev-parse`, `find`,
# `printf | jq`, `git diff > /tmp/x.patch`, and `bash tests/run_tests.sh` on
# successive attempts). A settings.json `permissions.allow` list cannot fix
# this: it is whack-a-mole, and the FIRST command outside the list is fatal.
#
# WHAT IT DOES
# It intercepts every `run_command` step and answers `allow` with an
# `overwrite` that replaces the command line with a harmless `echo`. The model
# therefore never triggers a permission request (so the run never dies), and
# no reviewer-authored shell command ever executes — which is exactly the
# read-only guarantee `--dangerously-skip-permissions` would have thrown away.
# The echoed text tells the model why it got nothing back and what to use
# instead, so it falls back to its file-reading tools and the embedded diff.
#
# CONTRACT (agy hooks): JSON on stdin, JSON on stdout.
#   in : {"toolCall":{"name":"run_command","args":{"CommandLine":"..."}}, ...}
#   out: {"decision":"allow","reason":"...","overwrite":{"CommandLine":"..."}}
#
# Wired up by run_reviewers.sh, which writes a temporary
# <repo>/.agents/hooks.json pointing here and removes it when the lap ends.
set -uo pipefail

cat >/dev/null 2>&1 || true  # drain stdin; the payload is not needed to decide

msg='SHELL DISABLED: this is a read-only code review running headless, so no shell command can execute. The full diff is already in your prompt and the repository is mounted in your workspace - use your file-reading tools instead, then answer in prose.'

# printf %s the message into a single-quoted echo, escaping any embedded quote.
# NOTE: the REWRITTEN command line is still permission-checked, and the hook's
# own `permissionOverrides` does NOT cover it (verified 2026-07-31: the run
# still died on `echo`). So `command(echo)` must be allow-listed in
# ~/.gemini/antigravity-cli/settings.json — run_reviewers.sh warns when it is
# not. That single rule is the entire global footprint of this fix.
printf '{"decision":"allow","reason":"read-only review sandbox: run_command is disabled","overwrite":{"CommandLine":"echo %s"}}\n' \
  "$(printf '%s' "'$msg'" | sed 's/\\/\\\\/g; s/"/\\"/g')"
