#!/usr/bin/env bash
# Fleet flags for tests written against the pre-2026-09-07 fleet: kimi as the
# second fixed baseline, the OpenRouter pool as the rotation draw and the
# fallback lane. That fleet is still supported; it is no longer the default
# (see scripts/lib_flags.sh).
#
# Sourced, never executed. run_tests.sh sources it for the whole suite, and so
# does every standalone test whose fixtures use those seats, so that
# `bash tests/test_<name>.sh` passes on its own and not only under the runner.
# A test that covers the new defaults (tests/test_flags.sh) sets its own flags
# per case and must not source this.
export CROSS_REVIEW_KIMI_BASELINE=1
export CROSS_REVIEW_GLM_BASELINE=0
export CROSS_REVIEW_OPENROUTER=1
# The kimi seat is "binary AND pinned alias in the kimi config"
# (cr_kimi_alias_ready). These fixtures shim the binary; this is the config.
export CROSS_REVIEW_KIMI_CONFIG="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fixtures/kimi_config.toml"
