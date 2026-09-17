#!/usr/bin/env bash
# fm-supervisor-target-lib.sh - the single owner of supervisor-pane discovery.
#
# The away-mode daemon (bin/fm-supervise-daemon.sh) must know which pane runs
# firstmate itself, both to inject escalations into it and, for the daemon, to
# validate that target at startup. The script-owned away launcher
# (bin/fm-afk-launch.sh) must resolve the SAME captain pane BEFORE it creates a
# separate, non-visible terminal for the daemon, so it can pass that pane in as
# FM_SUPERVISOR_TARGET (otherwise the daemon, running in its own terminal, would
# auto-discover its OWN pane and inject there instead of into the captain's).
#
# Because both callers need the identical resolution, it lives here once. The
# function names and precedence are unchanged from when this logic lived inline
# in bin/fm-supervise-daemon.sh, so its unit tests (tests/fm-daemon.test.sh)
# keep exercising the same names after the daemon sources this file.

# Default supervisor pane BACKEND when a target is configured but the backend is
# not. This fallback is safe because it only ever applies to a target a caller
# supplied explicitly (FM_SUPERVISOR_TARGET), where tmux is the documented
# default transport. There is deliberately no matching TARGET default: a guessed
# pane is the failure mode this library exists to prevent (see
# discover_supervisor_target).
FM_SUPERVISOR_BACKEND_DEFAULT="tmux"

# The env markers discover_supervisor_target consults, in precedence order, for
# a refusal diagnostic that names what was looked for.
# shellcheck disable=SC2034 # Read by callers (fm-supervise-daemon.sh, fm-afk-launch.sh) after sourcing.
FM_SUPERVISOR_TARGET_SOURCES="FM_SUPERVISOR_TARGET, \$TMUX_PANE (tmux), \$HERDR_ENV=1 with \$HERDR_PANE_ID (herdr)"

# discover_supervisor_target: resolve the pane running firstmate. Priority:
#   1. FM_SUPERVISOR_TARGET env (explicit override) - may be a tmux target or a
#      herdr "<session>:<pane-id>" target (paired with discover_supervisor_backend
#      to know which).
#   2. $TMUX_PANE - tmux sets this in every pane's environment; inherited by a
#      process launched from firstmate's own pane.
#   3. $HERDR_ENV=1 + $HERDR_PANE_ID - herdr injects both into every process it
#      manages a pane for; compose the "<session>:<pane-id>" target from
#      $HERDR_SESSION (defaulting to "default", mirroring bin/backends/herdr.sh's
#      fm_backend_herdr_session) and $HERDR_PANE_ID. Checked after $TMUX_PANE so a
#      tmux pane nested inside herdr still resolves to tmux, matching
#      fm_backend_detect's innermost-first rule.
#   Nothing else. When none of those resolve, this prints nothing and returns 1,
#   and every caller must REFUSE rather than substitute a guess. It used to fall
#   back to a hardcoded "firstmate:0" tmux target, which reproduced live on
#   2026-09-17: that name resolved to a real but unrelated bare shell, so target
#   validation passed, the daemon logged a healthy startup, and every escalation
#   was deferred forever against a pane that was never firstmate. A pane that
#   merely exists is not evidence it runs firstmate, so there is no safe guess to
#   make here - only an explicit override or an inherited marker is evidence.
discover_supervisor_target() {
  if [ -n "${FM_SUPERVISOR_TARGET:-}" ]; then
    printf '%s' "$FM_SUPERVISOR_TARGET"
    return 0
  fi
  if [ -n "${TMUX_PANE:-}" ]; then
    printf '%s' "$TMUX_PANE"
    return 0
  fi
  if [ "${HERDR_ENV:-}" = "1" ] && [ -n "${HERDR_PANE_ID:-}" ]; then
    printf '%s:%s' "${HERDR_SESSION:-default}" "$HERDR_PANE_ID"
    return 0
  fi
  return 1
}

# supervisor_target_source: name the marker discover_supervisor_target resolves
# from, without restating its precedence at each call site. Prints
# FM_SUPERVISOR_TARGET, TMUX_PANE, or HERDR_ENV(HERDR_PANE_ID); prints NONE and
# returns 1 when nothing resolves, mirroring discover_supervisor_target.
supervisor_target_source() {
  if [ -n "${FM_SUPERVISOR_TARGET:-}" ]; then
    printf 'FM_SUPERVISOR_TARGET'
    return 0
  fi
  if [ -n "${TMUX_PANE:-}" ]; then
    printf 'TMUX_PANE'
    return 0
  fi
  if [ "${HERDR_ENV:-}" = "1" ] && [ -n "${HERDR_PANE_ID:-}" ]; then
    printf 'HERDR_ENV(HERDR_PANE_ID)'
    return 0
  fi
  printf 'NONE'
  return 1
}

# discover_supervisor_backend: resolve the supervisor pane's BACKEND, independent
# of the target string so an explicit FM_SUPERVISOR_TARGET override still knows
# which primitives (tmux vs herdr) to dispatch through. Priority mirrors
# discover_supervisor_target and bin/fm-backend.sh's fm_backend_detect:
#   1. FM_SUPERVISOR_BACKEND env (explicit override).
#   2. $TMUX_PANE set - tmux.
#   3. $HERDR_ENV=1 (with $HERDR_PANE_ID present) - herdr.
#   4. FM_SUPERVISOR_BACKEND_DEFAULT (tmux). Returns 1 so a caller that needs a
#      DETECTED backend can refuse; a caller holding an explicit
#      FM_SUPERVISOR_TARGET may accept the tmux default instead.
discover_supervisor_backend() {
  if [ -n "${FM_SUPERVISOR_BACKEND:-}" ]; then
    printf '%s' "$FM_SUPERVISOR_BACKEND"
    return 0
  fi
  if [ -n "${TMUX_PANE:-}" ]; then
    printf 'tmux'
    return 0
  fi
  if [ "${HERDR_ENV:-}" = "1" ] && [ -n "${HERDR_PANE_ID:-}" ]; then
    printf 'herdr'
    return 0
  fi
  printf '%s' "$FM_SUPERVISOR_BACKEND_DEFAULT"
  return 1
}
