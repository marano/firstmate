#!/usr/bin/env bash
# tests/worker-env-helpers.sh - the single owner of which task-worker session
# environment a suite must not inherit.
#
# A task worker's pane shell carries identity that bin/fm-spawn.sh exports for
# the agent: FM_TASK_ID and FM_TASK_STATUS mark the worker and name its REAL
# status file, and TMUX and TMUX_PANE name the tmux server and pane it lives in.
# Production code reads all four - the build lock appends ceiling lines to
# FM_TASK_STATUS, the runner refuses the primary checkout under FM_TASK_ID, and
# backend detection, the supervisor target, and spawn placement read TMUX and
# TMUX_PANE - so a suite run from inside a worker would otherwise take its
# verdict from the worker's surroundings instead of from its own fixtures. A case
# that verifies one of those reads sets the variable itself.
#
# Sourcing this file only defines names; nothing is unset until one is used:
#   - tests/lib.sh and tests/herdr-test-safety.sh call fm_test_scrub_worker_env
#     at load, so a direct invocation of any suite that sources them is hermetic;
#   - bin/fm-test-run.sh puts FM_TEST_SCRUB_ENV_CMD in front of every script it
#     launches, so every suite it runs is hermetic, including one that sources
#     no shared helper, while the runner's own build-lock reads of
#     FM_TASK_STATUS and its FM_TASK_ID placement refusal keep their values.
#     The prefix is an `env -u` word list on purpose: `local NAME` followed by
#     `unset NAME` does not hide an inherited export on the stock Bash 3.2.
# tests/fm-test-fixtures.test.sh is the regression: it plants hostile values
# and drives both entry points.
#
# Variables the runner passes on purpose (CI markers, the build-lock hold, the
# per-worker TMPDIR) are not in this list and stay untouched.
FM_TEST_WORKER_ENV_VARS="FM_TASK_ID FM_TASK_STATUS TMUX TMUX_PANE"

fm_test_scrub_worker_env() {
  # Word splitting of the list is the point.
  # shellcheck disable=SC2086
  unset $FM_TEST_WORKER_ENV_VARS
}

FM_TEST_SCRUB_ENV_CMD=(env)
for _fm_worker_env_var in $FM_TEST_WORKER_ENV_VARS; do
  FM_TEST_SCRUB_ENV_CMD+=(-u "$_fm_worker_env_var")
done
unset _fm_worker_env_var
