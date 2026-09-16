#!/usr/bin/env bash
# Machine-wide build/test mutex: run the wrapped command while holding one lock
# that every local build and test invocation on this machine shares.
#
# Usage:
#   fm-build-lock.sh [--] <command> [args...]   acquire, run, release
#   fm-build-lock.sh --status                   print the current holder
#   fm-build-lock.sh --lock-path                print the resolved lock path
#   fm-build-lock.sh --install-mutex <dir>      link <dir>/mutex at this script
#   fm-build-lock.sh --help
#
# Prefix it in front of any local build or test command; no repository is
# modified to make this work:
#
#   fm-build-lock.sh ./gradlew :bluejam-core-ai:test
#   mutex pnpm run ci
#
# The wrapped command's stdout, stderr, stdin and exit status pass through
# unchanged. Everything this script says about the lock goes to stderr prefixed
# `fm-build-lock:`, so stdout stays exactly the wrapped command's output.
#
# ONE LOCK, NOT ONE PER REPOSITORY. A per-repository lock would still let a JVM
# build and a browser suite run together, which is the pairing that exhausted a
# 16 GB / 10-core machine and produced false test failures on unmodified code.
# The lock therefore lives outside every firstmate home so secondmate homes
# share it.
#
# LOCK PATH. `FM_BUILD_LOCK_DIR` overrides it. Otherwise this resolves the
# stable per-user temporary directory (`getconf DARWIN_USER_TEMP_DIR` on macOS)
# and falls back to /tmp. It deliberately ignores `$TMPDIR`: an agent harness
# can hand a process a session-private `$TMPDIR`, and two workers that resolved
# different roots would take different locks and silently stop excluding each
# other. Every fleet agent on this machine runs as one user, so a per-user root
# is machine-wide for the fleet and cannot be hijacked in shared /tmp.
#
# NEVER ON CI. Detected CI environments exec the command straight through
# without touching the lock: the commands in a project's `.no-mistakes.yaml`
# also reach GitHub's runners through the generated workflow, where a lock on
# this machine is meaningless. `FM_BUILD_LOCK_CI=0` forces local locking and
# `FM_BUILD_LOCK_CI=1` forces stand-down.
#
# HOLD CEILINGS REPORT, THEY NEVER KILL. A wrongly killed build is worse than a
# slow one, so passing a ceiling only prints a warning. A holder past its
# ceiling warns from its own pane even with nobody waiting; a waiter past its
# ceiling warns too, and every waiting line names the holder so an inspected
# quiet pane reads as waiting rather than wedged.
#
# Environment:
#   FM_BUILD_LOCK_DIR              directory holding the lock (see LOCK PATH)
#   FM_BUILD_LOCK_CI               1/true force stand-down, 0/false force lock
#   FM_BUILD_LOCK_NOTICE_INTERVAL  seconds between waiting notices (default 60)
#   FM_BUILD_LOCK_WAIT_WARN        waiter ceiling in seconds, 0 off (default 600)
#   FM_BUILD_LOCK_HOLD_WARN        holder ceiling in seconds, 0 off (default 1200)
#   FM_BUILD_LOCK_POLL             acquire poll interval in seconds (default 0.5)
#
# The lock itself is bin/fm-wake-lib.sh's lockdir mutex, the same primitive the
# wake queue, merges, captain holds and remote handoffs run on; this script adds
# no second locking scheme. macOS ships no flock(1), which is why that lockdir
# implementation exists in the first place.
set -u

# Resolve through symlinks: the `mutex` entry point is a symlink to this script,
# and --install-mutex puts one in a directory of the operator's choosing, so the
# invoked path's directory is not where this script's siblings live.
fm_build_lock_self_dir() {
  local src=${BASH_SOURCE[0]} dir
  while [ -L "$src" ]; do
    dir=$(cd -P "$(dirname "$src")" >/dev/null 2>&1 && pwd) || return 1
    src=$(readlink "$src") || return 1
    case "$src" in
      /*) ;;
      *) src="$dir/$src" ;;
    esac
  done
  cd -P "$(dirname "$src")" >/dev/null 2>&1 && pwd
}

SCRIPT_DIR=$(fm_build_lock_self_dir) || {
  printf 'fm-build-lock: cannot resolve this script directory\n' >&2
  exit 2
}
SELF="$SCRIPT_DIR/fm-build-lock.sh"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$SELF"
}

note() {
  printf 'fm-build-lock: %s\n' "$*" >&2
}

die() {
  printf 'fm-build-lock: %s\n' "$*" >&2
  exit 2
}

# --- lock location ----------------------------------------------------------

fm_build_lock_root() {
  local root=
  if [ -n "${FM_BUILD_LOCK_DIR:-}" ]; then
    root=${FM_BUILD_LOCK_DIR%/}
    [ -n "$root" ] || root=/
    printf '%s\n' "$root"
    return 0
  fi
  root=$(getconf DARWIN_USER_TEMP_DIR 2>/dev/null) || root=
  case "$root" in
    /*) ;;
    *) root= ;;
  esac
  if [ -z "$root" ] || [ ! -d "$root" ] || [ ! -w "$root" ]; then
    root=/tmp
  fi
  printf '%s\n' "${root%/}"
}

# --- CI stand-down ----------------------------------------------------------

# True when this process is running on a continuous integration runner. The
# explicit override is checked first so firstmate's own suite can exercise both
# branches from inside CI, where the ambient markers are always set.
fm_build_lock_is_ci() {
  local marker
  case "${FM_BUILD_LOCK_CI:-}" in
    1|true|TRUE|True|yes|YES) return 0 ;;
    0|false|FALSE|False|no|NO) return 1 ;;
    '') : ;;
    *) die "FM_BUILD_LOCK_CI must be 1/true/yes or 0/false/no, got '$FM_BUILD_LOCK_CI'" ;;
  esac
  for marker in \
    "${CI:-}" "${CONTINUOUS_INTEGRATION:-}" "${BUILD_NUMBER:-}" \
    "${GITHUB_ACTIONS:-}" "${GITLAB_CI:-}" "${BUILDKITE:-}" "${CIRCLECI:-}" \
    "${TRAVIS:-}" "${APPVEYOR:-}" "${TF_BUILD:-}" "${TEAMCITY_VERSION:-}" \
    "${JENKINS_URL:-}" "${BITBUCKET_BUILD_NUMBER:-}" "${DRONE:-}" \
    "${CODEBUILD_BUILD_ID:-}"; do
    case "$marker" in
      ''|0|false|FALSE|False|no|NO) : ;;
      *) return 0 ;;
    esac
  done
  return 1
}

# --- formatting -------------------------------------------------------------

fm_build_lock_positive_int() {  # <name> <value>
  case "$2" in
    ''|*[!0-9]*) die "$1 must be a whole number of seconds, got '$2'" ;;
  esac
  [ "$2" -gt 0 ] || die "$1 must be greater than zero, got '$2'"
}

fm_build_lock_nonneg_int() {  # <name> <value>
  case "$2" in
    ''|*[!0-9]*) die "$1 must be a whole number of seconds, got '$2'" ;;
  esac
}

fm_build_lock_elapsed() {  # <seconds>
  local s=$1
  case "$s" in ''|*[!0-9]*) s=0 ;; esac
  if [ "$s" -lt 60 ]; then
    printf '%ds\n' "$s"
  elif [ "$s" -lt 3600 ]; then
    printf '%dm%02ds\n' "$((s / 60))" "$((s % 60))"
  else
    printf '%dh%02dm\n' "$((s / 3600))" "$(((s % 3600) / 60))"
  fi
}

# One display line for a command line, with every argument shell-quoted so a
# newline or a space inside an argument can never break the single-line holder
# record that waiters read back.
fm_build_lock_render_command() {
  local arg out=''
  for arg in "$@"; do
    if [ -z "$out" ]; then
      out=$(printf '%q' "$arg")
    else
      out="$out $(printf '%q' "$arg")"
    fi
  done
  printf '%s\n' "$out"
}

# --- holder record ----------------------------------------------------------
#
# Only the process holding the lock ever writes this file, and every reader
# validates its first line against the lock's own authoritative pid record, so a
# record left behind by a killed holder is reported as unavailable rather than
# as a live holder.

fm_build_lock_write_info() {  # <info-path> <pid> <started> <display>
  local info=$1 pid=$2 started=$3 display=$4 tmp
  tmp="$info.$pid.tmp"
  { printf '%s\n%s\n%s\n' "$pid" "$started" "$display" > "$tmp"; } 2>/dev/null || return 1
  mv -f -- "$tmp" "$info" 2>/dev/null || { rm -f -- "$tmp" 2>/dev/null; return 1; }
}

# Read the current holder into FM_BUILD_LOCK_HOLDER_TEXT (a human sentence, or
# empty when the lock is free) and FM_BUILD_LOCK_HOLDER_SECS (its age, or
# empty). It sets globals instead of echoing because a caller that needs the
# age cannot capture it through a command substitution's subshell.
FM_BUILD_LOCK_HOLDER_TEXT=
FM_BUILD_LOCK_HOLDER_SECS=

fm_build_lock_read_holder() {  # <lockdir> <info-path>
  local lockdir=$1 info=$2 pid info_pid started display now age
  FM_BUILD_LOCK_HOLDER_TEXT=
  FM_BUILD_LOCK_HOLDER_SECS=
  pid=$(cat "$lockdir/pid" 2>/dev/null || true)
  case "$pid" in
    ''|*[!0-9]*) return 0 ;;
  esac
  info_pid=
  started=
  display=
  if [ -f "$info" ] && [ ! -L "$info" ]; then
    { read -r info_pid; read -r started; IFS= read -r display; } < "$info" 2>/dev/null || true
  fi
  if [ "$info_pid" != "$pid" ]; then
    FM_BUILD_LOCK_HOLDER_TEXT="held by pid $pid (no command record)"
    return 0
  fi
  case "$started" in
    ''|*[!0-9]*)
      FM_BUILD_LOCK_HOLDER_TEXT="held by pid $pid running: $display"
      return 0
      ;;
  esac
  now=$(date +%s)
  age=$((now - started))
  [ "$age" -ge 0 ] || age=0
  FM_BUILD_LOCK_HOLDER_SECS=$age
  FM_BUILD_LOCK_HOLDER_TEXT="held by pid $pid for $(fm_build_lock_elapsed "$age") running: $display"
}

# A waiter can look between another process taking the lock and publishing its
# command, which would report a live holder as having no command record - the
# least useful thing to print at exactly the moment observability matters. Give
# the new holder a bounded chance to publish before settling on that answer.
fm_build_lock_read_holder_settled() {  # <lockdir> <info-path>
  local attempt=1
  while [ "$attempt" -le 3 ]; do
    fm_build_lock_read_holder "$1" "$2"
    case "$FM_BUILD_LOCK_HOLDER_TEXT" in
      *'(no command record)') : ;;
      *) return 0 ;;
    esac
    attempt=$((attempt + 1))
    [ "$attempt" -le 3 ] || break
    sleep "$POLL"
  done
  return 0
}

# --- hold ceiling ------------------------------------------------------------
#
# The ceiling is watched from this process, in the same loop that waits for the
# wrapped command, so nothing is forked to watch it. A background watcher was
# tried first and is the wrong shape: an asynchronous subshell and the `sleep`
# it forks both inherit the caller's stderr, so `mutex build 2>&1 | tee log`
# stalled for a whole tick after the build finished, waiting on a process that
# had nothing left to say. Polling here instead means the only child this script
# ever leaves behind is one short `sleep`, which holds the caller's pipe for at
# most one poll interval and only if this process is SIGKILLed.
#
# It reports and never signals the wrapped command: a wrongly killed build is
# worse than a slow one.

fm_build_lock_report_ceiling() {  # <held-secs> <display>
  printf 'fm-build-lock: WARNING: this command has held the machine-wide build lock for %s and is blocking every other local build: %s\n' \
    "$(fm_build_lock_elapsed "$1")" "$2" >&2
}

# --- observable acquire -----------------------------------------------------

fm_build_lock_acquire() {  # <lockdir> <info-path>
  local lockdir=$1 info=$2 start waited=0 next_notice holder now
  if fm_lock_try_acquire "$lockdir"; then
    return 0
  fi
  start=$(date +%s)
  next_notice=$NOTICE_INTERVAL
  fm_build_lock_read_holder_settled "$lockdir" "$info"
  holder=$FM_BUILD_LOCK_HOLDER_TEXT
  note "waiting for the machine-wide build lock - this process is WAITING, not wedged${holder:+ (}${holder}${holder:+)}"
  while ! fm_lock_try_acquire "$lockdir"; do
    sleep "$POLL"
    now=$(date +%s)
    waited=$((now - start))
    [ "$waited" -ge "$next_notice" ] || continue
    next_notice=$((waited + NOTICE_INTERVAL))
    fm_build_lock_read_holder_settled "$lockdir" "$info"
    holder=$FM_BUILD_LOCK_HOLDER_TEXT
    if [ "$WAIT_WARN" -gt 0 ] && [ "$waited" -ge "$WAIT_WARN" ]; then
      note "WARNING: still WAITING $(fm_build_lock_elapsed "$waited") for the machine-wide build lock, past the ${WAIT_WARN}s ceiling${holder:+ - }${holder}"
    else
      note "still waiting $(fm_build_lock_elapsed "$waited") for the machine-wide build lock${holder:+ - }${holder}"
    fi
    if [ -n "$FM_BUILD_LOCK_HOLDER_SECS" ] && [ "$HOLD_WARN" -gt 0 ] \
      && [ "$FM_BUILD_LOCK_HOLDER_SECS" -ge "$HOLD_WARN" ]; then
      note "WARNING: the holder has held the build lock $(fm_build_lock_elapsed "$FM_BUILD_LOCK_HOLDER_SECS"), past the ${HOLD_WARN}s ceiling; it is not being killed"
    fi
  done
  note "acquired the machine-wide build lock after $(fm_build_lock_elapsed "$waited")"
}

# --- release ----------------------------------------------------------------

FM_BUILD_LOCK_HELD=0
FM_BUILD_LOCK_CHILD=

# shellcheck disable=SC2329 # Reached only through the EXIT trap below.
fm_build_lock_release_now() {
  [ "$FM_BUILD_LOCK_HELD" = 1 ] || return 0
  FM_BUILD_LOCK_HELD=0
  rm -f -- "$INFO" 2>/dev/null || true
  fm_lock_release "$LOCK" || true
}

# Release runs from a trap rather than after the wrapped command, so a wrapper
# killed at any point still gives the lock back.
# shellcheck disable=SC2329 # Installed as the EXIT trap handler.
fm_build_lock_on_exit() {
  local status=$?
  fm_build_lock_release_now
  exit "$status"
}

# shellcheck disable=SC2329 # Installed as the INT/TERM/HUP trap handler.
fm_build_lock_on_signal() {  # <signal-name> <signal-number>
  local sig=$1 num=$2
  if [ -n "$FM_BUILD_LOCK_CHILD" ] && kill -0 "$FM_BUILD_LOCK_CHILD" 2>/dev/null; then
    kill -"$sig" "$FM_BUILD_LOCK_CHILD" 2>/dev/null || true
    return 0
  fi
  exit $((128 + num))
}

# --- argument handling ------------------------------------------------------

MODE=run
INSTALL_DIR=

while [ "$#" -gt 0 ]; do
  case "$1" in
    --)
      shift
      break
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --status)
      MODE=status
      shift
      [ "$#" -eq 0 ] || die "--status takes no further arguments"
      ;;
    --lock-path)
      MODE='lock-path'
      shift
      [ "$#" -eq 0 ] || die "--lock-path takes no further arguments"
      ;;
    --install-mutex)
      MODE=install
      shift
      [ "$#" -eq 1 ] || die "--install-mutex takes exactly one directory"
      INSTALL_DIR=$1
      shift
      ;;
    -*)
      die "unknown option '$1'; put '--' before a command that starts with a dash"
      ;;
    *)
      break
      ;;
  esac
done

if [ "$MODE" = run ] && [ "$#" -eq 0 ]; then
  usage >&2
  exit 2
fi

NOTICE_INTERVAL=${FM_BUILD_LOCK_NOTICE_INTERVAL:-60}
WAIT_WARN=${FM_BUILD_LOCK_WAIT_WARN:-600}
HOLD_WARN=${FM_BUILD_LOCK_HOLD_WARN:-1200}
POLL=${FM_BUILD_LOCK_POLL:-0.5}
fm_build_lock_positive_int FM_BUILD_LOCK_NOTICE_INTERVAL "$NOTICE_INTERVAL"
fm_build_lock_nonneg_int FM_BUILD_LOCK_WAIT_WARN "$WAIT_WARN"
fm_build_lock_nonneg_int FM_BUILD_LOCK_HOLD_WARN "$HOLD_WARN"
case "$POLL" in
  ''|*[!0-9.]*|.|*.*.*) die "FM_BUILD_LOCK_POLL must be a number of seconds, got '$POLL'" ;;
esac

# --- CI stand-down, before the lock root is even resolved -------------------

if [ "$MODE" = run ] && fm_build_lock_is_ci; then
  exec "$@"
fi

LOCK_ROOT=$(fm_build_lock_root)
[ -d "$LOCK_ROOT" ] || mkdir -p "$LOCK_ROOT" 2>/dev/null || die "lock directory is unavailable: $LOCK_ROOT"
[ -d "$LOCK_ROOT" ] && [ -w "$LOCK_ROOT" ] || die "lock directory is not writable: $LOCK_ROOT"
LOCK="$LOCK_ROOT/fm-build-lock"
INFO="$LOCK_ROOT/fm-build-lock.info"

case "$MODE" in
  lock-path)
    printf '%s\n' "$LOCK"
    exit 0
    ;;
  install)
    [ -d "$INSTALL_DIR" ] || die "not a directory: $INSTALL_DIR"
    [ -w "$INSTALL_DIR" ] || die "not writable: $INSTALL_DIR"
    TARGET="$INSTALL_DIR/mutex"
    if [ -e "$TARGET" ] && [ ! -L "$TARGET" ]; then
      die "refusing to replace the existing non-symlink $TARGET"
    fi
    ln -sfn "$SELF" "$TARGET" || die "could not link $TARGET"
    printf '%s -> %s\n' "$TARGET" "$SELF"
    exit 0
    ;;
esac

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

if [ "$MODE" = status ]; then
  fm_build_lock_read_holder "$LOCK" "$INFO"
  if [ -n "$FM_BUILD_LOCK_HOLDER_TEXT" ]; then
    printf '%s\n' "$FM_BUILD_LOCK_HOLDER_TEXT"
  else
    printf 'free\n'
  fi
  exit 0
fi

# --- acquire, run, release --------------------------------------------------

trap fm_build_lock_on_exit EXIT
trap 'fm_build_lock_on_signal TERM 15' TERM
trap 'fm_build_lock_on_signal INT 2' INT
trap 'fm_build_lock_on_signal HUP 1' HUP

# Rendered before the acquire so publishing the holder record costs one write
# and nothing else: every fork left inside that window is time a waiter can
# spend looking at a lock whose command is not published yet.
DISPLAY_LINE="$(fm_build_lock_render_command "$@") [in $(pwd -P)]"

fm_build_lock_acquire "$LOCK" "$INFO"
FM_BUILD_LOCK_HELD=1

STARTED=$(date +%s)
HELD_SINCE=$SECONDS
fm_build_lock_write_info "$INFO" "$$" "$STARTED" "$DISPLAY_LINE" || true

# An explicit stdin redirection is required: bash sends an asynchronous
# command's stdin to /dev/null when job control is off, which would silently
# starve any wrapped command that reads input. Job control being off is also why
# the child stays in this process group, so a terminal interrupt still reaches
# it directly.
"$@" <&0 &
FM_BUILD_LOCK_CHILD=$!

# SECONDS is bash's own wall clock, so the ceiling costs no fork per tick.
NEXT_HOLD_WARN=$HOLD_WARN
while kill -0 "$FM_BUILD_LOCK_CHILD" 2>/dev/null; do
  sleep "$POLL"
  [ "$HOLD_WARN" -gt 0 ] || continue
  HELD=$((SECONDS - HELD_SINCE))
  [ "$HELD" -ge "$NEXT_HOLD_WARN" ] || continue
  NEXT_HOLD_WARN=$((HELD + HOLD_WARN))
  fm_build_lock_report_ceiling "$HELD" "$DISPLAY_LINE"
done

# The loop leaves only after the child is gone; wait then reports the status
# bash recorded for it, including 128+signal when it was killed.
wait "$FM_BUILD_LOCK_CHILD"
STATUS=$?
FM_BUILD_LOCK_CHILD=

exit "$STATUS"
