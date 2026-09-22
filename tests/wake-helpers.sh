#!/usr/bin/env bash
# tests/wake-helpers.sh - shared fixtures and mocks for the wake-queue,
# watcher/lock, and supervise-daemon suites. The fake tmux surfaces here encode
# watcher/daemon/composer behavior, so they live here rather than in the generic
# tests/lib.sh. Generic reporters/assertions come from lib.sh, pulled in below.

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# fm-wake-drain.sh now calls fm-guard.sh to assert watcher liveness on every
# drain. fm-guard.sh's first check warns when the firstmate PRIMARY checkout
# (FM_ROOT) sits on a feature branch; with no override FM_ROOT resolves to the
# test runner's own checkout, which during validation is on a feature branch, so
# each drain would emit a spurious worktree-tangle banner. Point the tangle check
# at a fresh non-git dir to keep it inert across these suites - the same trick the
# direct fm-guard.sh tests use. A per-call FM_ROOT_OVERRIDE still wins where a
# suite sets its own (e.g. the watcher-lock guard-banner cases).
if [ -z "${FM_ROOT_OVERRIDE:-}" ]; then
  FM_ROOT_OVERRIDE="$(fm_test_tmproot fm-wake-tangle-root)"
  export FM_ROOT_OVERRIDE
fi

# Wedge-alarm notifier recorder (safety seam). The away-mode wedge alarm fires a
# real OS-level desktop notification by default. Point its FM_WEDGE_ALARM_EXEC
# seam at a recorder for every
# daemon/wake suite, so no test - present or future - can post a real macOS,
# herdr, or command: notification: it is impossible to forget, because sourcing this harness
# installs it. The recorder is an on-disk script (a real daemon a test spawns
# inherits the path and records too). It logs "<channel>\t<summary>" to
# $FM_WEDGE_ALARM_LOG, which a test sets to its own file to assert on; unset means
# /dev/null. FM_WEDGE_ALARM_FAIL=<channel> makes the recorder exit non-zero for
# that channel, to exercise graceful degradation. Suites that do not source this
# harness still cannot fire a real notification: the daemon defaults the seam to
# "discard" whenever it is sourced (its library-mode guard).
_fm_wedge_rec_dir=$(fm_test_tmproot fm-wedge-rec)
cat > "$_fm_wedge_rec_dir/rec" <<'REC'
#!/usr/bin/env bash
printf '%s\t%s\n' "${1:-}" "${2:-}" >> "${FM_WEDGE_ALARM_LOG:-/dev/null}"
case " ${FM_WEDGE_ALARM_FAIL:-} " in *" ${1:-} "*) exit 1 ;; esac
exit 0
REC
chmod +x "$_fm_wedge_rec_dir/rec"
export FM_WEDGE_ALARM_EXEC="$_fm_wedge_rec_dir/rec"

# append_wake <state> <kind> <key> <payload>: append a wake record to the durable
# queue in a subshell scoped to <state>, using the production wake library.
append_wake() {
  local state=$1 kind=$2 key=$3 payload=$4 lib="$ROOT/bin/fm-wake-lib.sh"
  FM_STATE_OVERRIDE="$state" bash -c '
    # shellcheck disable=SC1090,SC1091
    . "$1"
    fm_wake_append "$2" "$3" "$4"
  ' _ "$lib" "$kind" "$key" "$payload"
}

make_case() {
  local name=$1 dir fakebin
  dir="$TMP_ROOT/$name"
  fakebin="$dir/fakebin"
  mkdir -p "$dir/state" "$fakebin"
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
if [ "${1:-}" = "list-windows" ]; then
  if [ -n "${FM_FAKE_TMUX_WINDOWS:-}" ]; then
    printf '%s\n' "$FM_FAKE_TMUX_WINDOWS"
  elif [ -n "${FM_FAKE_TMUX_WINDOW:-}" ]; then
    printf '%s\n' "${FM_FAKE_TMUX_WINDOW#*:}"
  fi
  exit 0
fi
if [ "${1:-}" = "capture-pane" ]; then
  if [ -n "${FM_FAKE_TMUX_CAPTURE_COUNT_FILE:-}" ]; then
    _capture_count=$(cat "$FM_FAKE_TMUX_CAPTURE_COUNT_FILE" 2>/dev/null || echo 0)
    printf '%s\n' "$((_capture_count + 1))" > "$FM_FAKE_TMUX_CAPTURE_COUNT_FILE"
    if [ -n "${FM_FAKE_TMUX_CAPTURE_FAIL_AFTER:-}" ] \
      && [ "$_capture_count" -ge "$FM_FAKE_TMUX_CAPTURE_FAIL_AFTER" ]; then
      exit 1
    fi
  fi
  if [ -n "${FM_FAKE_TMUX_FORBIDDEN_TARGET:-}" ]; then
    _prev=
    for _arg in "$@"; do
      if [ "$_prev" = -t ] && [ "$_arg" = "$FM_FAKE_TMUX_FORBIDDEN_TARGET" ]; then
        exit 1
      fi
      _prev=$_arg
    done
  fi
  if [ -n "${FM_FAKE_TMUX_CAPTURE:-}" ]; then
    cat "$FM_FAKE_TMUX_CAPTURE"
  fi
  exit 0
fi
if [ "${1:-}" = "display-message" ]; then
  case "$*" in
    *pane_current_command*) printf '%s\n' "${FM_FAKE_TMUX_CURRENT_COMMAND:-}"; exit 0 ;;
  esac
fi
exit 1
SH
  chmod +x "$fakebin/tmux"
  make_fake_crew_state "$fakebin" >/dev/null
  printf '%s\n' "$dir"
}

# Install a hermetic fake fm-crew-state.sh into <fakebin> and echo its path. The
# watcher's absorb-only-when-provably-working triage calls this (via
# FM_CREW_STATE_BIN) to read a crew's current state on no-verb signal and stale
# paths; the fake returns a canned "state: <s> · source: <src> · <detail>"
# verdict line so a test can fix the provably-working decision without a real
# worktree or no-mistakes.
# A per-id override FM_FAKE_CREW_STATE_<sanitized-id> wins; otherwise the shared
# FM_FAKE_CREW_STATE; otherwise an unknown verdict (NOT provably working), the
# safe default so a test that forgets to set one surfaces rather than absorbs.
make_fake_crew_state() {  # <fakebin>
  local fakebin=$1
  cat > "$fakebin/fm-crew-state.sh" <<'SH'
#!/usr/bin/env bash
set -u
id=${1:-}
key=$(printf '%s' "$id" | tr -c 'A-Za-z0-9' '_')
var="FM_FAKE_CREW_STATE_$key"
val=${!var:-${FM_FAKE_CREW_STATE:-}}
printf '%s\n' "${val:-state: unknown · source: none · fake default}"
exit 0
SH
  chmod +x "$fakebin/fm-crew-state.sh"
  printf '%s\n' "$fakebin/fm-crew-state.sh"
}

# Prime <file>'s .seen-* marker to its CURRENT signature through the production
# signature owner (bin/fm-wake-lib.sh), so a test can declare "everything in
# this file was already surfaced or deliberately absorbed" before exercising
# the next wake, self-announced append, or annotation decision.
prime_status_seen() {  # <state> <file>
  FM_STATE_OVERRIDE="$1" bash -c '
    . "$1"
    fm_wake_status_mark_current "$2" "$3"
  ' _ "$ROOT/bin/fm-wake-lib.sh" "$1" "$2"
}

# Print the generation from a recovery marker token of any status/kind.
recovery_marker_generation() {  # <marker-file>
  sed -n 's/^[^:]*:[^:]*:\(.*\)$/\1/p' "$1"
}

# Acknowledge a drain from its captured stderr (the WAKE_ACK_REQUIRED line).
ack_drain_err() {  # <state> <stderr-file>
  local state=$1 err=$2 sequence generation
  sequence=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation [A-Za-z0-9._-][A-Za-z0-9._-]*$/\1/p' "$err")
  generation=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through [0-9][0-9]* --recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1/p' "$err")
  [ -n "$sequence" ] && [ -n "$generation" ] || return 1
  FM_STATE_OVERRIDE="$state" "$ROOT/bin/fm-wake-drain.sh" \
    --ack-through "$sequence" --recovery-generation "$generation"
}

make_supercase() {
  local name=$1 dir fakebin
  dir="$TMP_ROOT/$name"
  fakebin="$dir/fakebin"
  mkdir -p "$dir/state" "$fakebin"
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  display-message)
    [ "${FM_FAKE_TMUX_PANE_ALIVE:-1}" = "1" ] || exit 1
    _print=0
    # Return cursor_y when the format asks for it (pane_input_pending).
    for _a in "$@"; do
      case "$_a" in *cursor_y*) printf '%s\n' "${FM_FAKE_TMUX_CURSOR_Y:-0}"; exit 0 ;; esac
      [ "$_a" = "-p" ] && _print=1
    done
    [ "$_print" = 1 ] && printf 'fakepane\n'
    exit 0 ;;
  list-windows)
    [ -n "${FM_FAKE_TMUX_WINDOW:-}" ] && printf '%s\n' "$FM_FAKE_TMUX_WINDOW"
    exit 0 ;;
  capture-pane)
    # Honor a single-line band capture (-S N -E M, both non-negative) for the
    # composer reader's non-bordered compatibility fallback; otherwise (e.g. its
    # structural full-pane scan or fm_pane_is_busy's "-S -40" tail) return the whole capture. -e is accepted and
    # ignored: this fake emits plain text, which the dim-stripper passes through.
    _S=""; _E=""; shift
    while [ "$#" -gt 0 ]; do
      case "$1" in
        -S) _S="${2:-}"; shift 2; continue ;;
        -E) _E="${2:-}"; shift 2; continue ;;
        *) shift ;;
      esac
    done
    [ -n "${FM_FAKE_TMUX_CAPTURE:-}" ] || exit 0
    if [ -n "$_S" ] && [ -n "$_E" ]; then
      case "$_S$_E" in
        *[!0-9]*) cat "$FM_FAKE_TMUX_CAPTURE" 2>/dev/null ;;
        *) sed -n "$((_S + 1)),$((_E + 1))p" "$FM_FAKE_TMUX_CAPTURE" 2>/dev/null ;;
      esac
    else
      cat "$FM_FAKE_TMUX_CAPTURE" 2>/dev/null
    fi
    exit 0 ;;
  send-keys)
    while [ "$#" -gt 0 ]; do
      case "$1" in
        -l) shift; [ "$#" -gt 0 ] && {
          printf '%s\n' "$1" >> "${FM_FAKE_TMUX_SENT:-/dev/null}"
          # Reflect sent text into capture so pane_input_pending sees it as
          # pending input (text in the composer).
          [ -n "${FM_FAKE_TMUX_CAPTURE:-}" ] && printf '%s\n' "$1" >> "$FM_FAKE_TMUX_CAPTURE"
        } ;;
        Enter)
          # Optionally swallow Enter (file-based flag) to test the retry path.
          if [ -n "${FM_FAKE_TMUX_SWALLOW_FILE:-}" ] && [ -f "$FM_FAKE_TMUX_SWALLOW_FILE" ]; then
            rm -f "$FM_FAKE_TMUX_SWALLOW_FILE"
          else
            printf '[ENTER]\n' >> "${FM_FAKE_TMUX_SENT:-/dev/null}"
            # Enter submits: clear the last line (the typed text) from the
            # capture, simulating the composer being cleared on submit.
            if [ -n "${FM_FAKE_TMUX_CAPTURE:-}" ] && [ -s "$FM_FAKE_TMUX_CAPTURE" ]; then
              _tmp=$(mktemp 2>/dev/null) || _tmp="${FM_FAKE_TMUX_CAPTURE}.tmp"
              sed '$d' "$FM_FAKE_TMUX_CAPTURE" > "$_tmp" 2>/dev/null && mv -f "$_tmp" "$FM_FAKE_TMUX_CAPTURE"
              rm -f "$_tmp" 2>/dev/null
            fi
          fi
          ;;
      esac
      shift
    done
    exit 0 ;;
esac
exit 1
SH
  chmod +x "$fakebin/tmux"
  printf '%s\n' "$dir"
}

make_bordered_case() {
  local name=$1 dir fakebin
  dir="$TMP_ROOT/$name"; fakebin="$dir/fakebin"
  mkdir -p "$dir/state" "$fakebin"
  printf '╭─────╮\n│ >   │\n╰─────╯\n' > "$dir/composer"
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
COMPOSER="${FM_FAKE_COMPOSER:?FM_FAKE_COMPOSER unset}"
write_composer() {
  text=$1
  width=$((${#text} + 4))
  border=
  i=0
  while [ "$i" -lt "$width" ]; do
    border="${border}─"
    i=$((i + 1))
  done
  printf '╭%s╮\n│ > %s │\n╰%s╯\n' "$border" "$text" "$border" > "$COMPOSER"
}
case "${1:-}" in
  display-message)
    print=0
    for a in "$@"; do case "$a" in *cursor_y*) printf '1\n'; exit 0 ;; esac; done
    for a in "$@"; do [ "$a" = "-p" ] && print=1; done
    [ "$print" = 1 ] && printf 'fakepane\n'
    exit 0 ;;
  capture-pane) cat "$COMPOSER" 2>/dev/null; exit 0 ;;
  list-windows) exit 0 ;;
  send-keys)
    shift
    text=""; is_enter=0; lit=0
    while [ "$#" -gt 0 ]; do
      case "$1" in
        -t) shift ;;
        -l) lit=1 ;;
        Enter) is_enter=1 ;;
        *) [ "$lit" = 1 ] && text="$1" ;;
      esac
      shift
    done
    if [ "$is_enter" = 1 ]; then
      if [ -n "${FM_FAKE_SWALLOW:-}" ] && [ -f "$FM_FAKE_SWALLOW" ]; then
        [ "${FM_FAKE_PERSIST_SWALLOW:-0}" = 1 ] || rm -f "$FM_FAKE_SWALLOW"
      else
        [ -n "${FM_FAKE_SENT:-}" ] && printf '[ENTER]\n' >> "$FM_FAKE_SENT"
        write_composer ""
      fi
    elif [ "$lit" = 1 ]; then
      [ "${FM_FAKE_SEND_FAIL:-0}" = 1 ] && exit 1
      [ -n "${FM_FAKE_SENT:-}" ] && printf '%s\n' "$text" >> "$FM_FAKE_SENT"
      write_composer "$text"
    fi
    exit 0 ;;
esac
exit 1
SH
  chmod +x "$fakebin/tmux"
  printf '%s\n' "$dir"
}

# wait_for_exit <pid> [limit-ticks]: wait up to <limit> 0.1s ticks for <pid> to
# exit and return its exit status, or terminate it and return 124 when the
# budget runs out. It also records HOW the wait ended, for watcher_exit_detail:
# WAIT_FOR_EXIT_TIMED_OUT (1 only when the budget ran out), WAIT_FOR_EXIT_STATUS
# (the process's own exit status) and WAIT_FOR_EXIT_SECS (wall-clock seconds the
# wait took), since 124 alone cannot say which of the two happened.
WAIT_FOR_EXIT_TIMED_OUT=0
WAIT_FOR_EXIT_STATUS=
WAIT_FOR_EXIT_SECS=
wait_for_exit() {
  local pid=$1 limit=${2:-50} i=0 started=$SECONDS
  WAIT_FOR_EXIT_TIMED_OUT=0
  WAIT_FOR_EXIT_STATUS=
  WAIT_FOR_EXIT_SECS=
  while [ "$i" -lt "$limit" ]; do
    if ! is_live_non_zombie "$pid"; then
      wait "$pid"
      WAIT_FOR_EXIT_STATUS=$?
      WAIT_FOR_EXIT_SECS=$((SECONDS - started))
      return "$WAIT_FOR_EXIT_STATUS"
    fi
    sleep 0.1
    i=$((i + 1))
  done
  WAIT_FOR_EXIT_TIMED_OUT=1
  WAIT_FOR_EXIT_SECS=$((SECONDS - started))
  term_and_reap "$pid"
  return 124
}

# watcher_exit_detail <stderr-file>: why the last wait_for_exit did not end in a
# clean exit - its budget ran out, or the process exited non-zero or on a signal -
# with the process's own stderr, so a red names its cause instead of leaving a
# timeout and a crash indistinguishable.
watcher_exit_detail() {
  local err=$1 detail
  if [ "$WAIT_FOR_EXIT_TIMED_OUT" -eq 1 ]; then
    detail="timed out: still running when its wait budget ran out after ${WAIT_FOR_EXIT_SECS}s, then terminated"
  elif [ -n "$WAIT_FOR_EXIT_STATUS" ] && [ "$WAIT_FOR_EXIT_STATUS" -gt 128 ]; then
    detail="killed by signal $((WAIT_FOR_EXIT_STATUS - 128)) (exit status $WAIT_FOR_EXIT_STATUS) after ${WAIT_FOR_EXIT_SECS}s"
  else
    detail="exited with status ${WAIT_FOR_EXIT_STATUS:-unknown} after ${WAIT_FOR_EXIT_SECS:-?}s"
  fi
  if [ -s "$err" ]; then
    detail="$detail; watcher stderr: $(tr '\n' ' ' < "$err")"
  else
    detail="$detail; watcher stderr was empty"
  fi
  printf '%s' "$detail"
}

# term_until_exit <pid>: stop a process this shell started with SIGTERM and
# return ITS exit status, for a caller that asserts on HOW it ended rather than
# only that it is gone. Same lost-signal problem as term_and_reap below: one
# SIGTERM is not enough on bash 5.2, where a trap action can fail to parse when
# the signal lands mid command substitution. A process that survives every
# resend inside the bound is killed and the caller FAILS by name, because
# "killed after ignoring SIGTERM" is not evidence that an interruption worked.
term_until_exit() {  # <pid>
  local pid=$1 started=$SECONDS resend=${FM_TEST_REAP_RESEND_SECS:-10}
  local bound=${FM_TEST_REAP_BOUND_SECS:-30} next elapsed status state
  next=$resend
  kill -TERM "$pid" 2>/dev/null || true
  while is_live_non_zombie "$pid"; do
    elapsed=$((SECONDS - started))
    if [ "$elapsed" -ge "$bound" ]; then
      state=$(ps -o pid=,stat=,etime=,command= -p "$pid" 2>/dev/null || true)
      kill -KILL "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
      fail "process $pid ignored SIGTERM for ${bound}s and had to be killed, so it was never interrupted: ${state:-gone}"
    fi
    if [ "$elapsed" -ge "$next" ]; then
      kill -TERM "$pid" 2>/dev/null || true
      next=$((next + resend))
    fi
    sleep 0.1
  done
  status=0
  wait "$pid" 2>/dev/null || status=$?
  return "$status"
}

# term_and_reap <pid>: stop a watcher (or any child) this shell started and reap
# it, without ever waiting on it unboundedly.
# One SIGTERM is not enough. Bash 5.2 - 5.2.21 is what CI's Ubuntu image ships -
# can fail to run a trap action when the signal lands while the shell is
# expanding a command substitution: it prints a spurious
# "trap: line 2: unexpected EOF while looking for matching `)'" and carries on,
# so bin/fm-watch.sh's `exit 1` TERM trap never runs and the watcher keeps
# polling. A bare `kill; wait` then blocks until that watcher exits on its own,
# which was forever in one CI shard and about 1000s in others. Bash 3.2 and 5.3
# honor the signal, which is why no local run reproduced it.
# So TERM is re-sent every FM_TEST_REAP_RESEND_SECS (default 10) while the
# process lives - far past the one poll plus cleanup a watcher needs to act on
# it, so a second TERM never interrupts a cleanup already under way - and past
# FM_TEST_REAP_BOUND_SECS (default 30) the process is killed and the caller
# fails naming it and what it was running, instead of going silent.
term_and_reap() {  # <pid>
  local pid=$1 started=$SECONDS resend=${FM_TEST_REAP_RESEND_SECS:-10}
  local bound=${FM_TEST_REAP_BOUND_SECS:-30} next elapsed state
  next=$resend
  kill "$pid" 2>/dev/null || true
  while is_live_non_zombie "$pid"; do
    elapsed=$((SECONDS - started))
    if [ "$elapsed" -ge "$bound" ]; then
      state=$(ps -o pid=,stat=,etime=,command= -p "$pid" 2>/dev/null || true)
      kill -KILL "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
      fail "process $pid did not exit within ${bound}s of repeated SIGTERM and was killed: ${state:-gone}"
    fi
    if [ "$elapsed" -ge "$next" ]; then
      kill "$pid" 2>/dev/null || true
      next=$((next + resend))
    fi
    sleep 0.1
  done
  wait "$pid" 2>/dev/null || true
}

is_live_non_zombie() {
  local pid=$1 stat
  kill -0 "$pid" 2>/dev/null || return 1
  stat=$(ps -p "$pid" -o stat= 2>/dev/null || true)
  case "$stat" in
    Z*) return 1 ;;
  esac
  return 0
}

hash_text() {
  if command -v md5 >/dev/null 2>&1; then
    printf '%s' "$1" | md5 -q
  else
    printf '%s' "$1" | md5sum | cut -d' ' -f1
  fi
}

dead_pid() {
  local p=999999
  while kill -0 "$p" 2>/dev/null; do
    p=$((p + 1))
  done
  printf '%s\n' "$p"
}
