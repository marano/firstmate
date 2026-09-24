#!/usr/bin/env bash
# tests/fm-watch-triage-lib.sh - shared fixtures for the fm-watch-triage-*.test.sh files.
# The watcher triage tests were one 7,000-line file; they are split by area so a change
# to one part of the watcher can run only the cases it touches. This file defines helpers
# and constants and runs no test. Every helper here is used by more than one part.
# shellcheck disable=SC2034

if [ -n "${FM_WATCH_TRIAGE_LIB_SOURCED:-}" ]; then
  return 0
fi
FM_WATCH_TRIAGE_LIB_SOURCED=1

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-classify-lib.sh"

WATCH="$ROOT/bin/fm-watch.sh"
DRAIN="$ROOT/bin/fm-wake-drain.sh"


ack_stopped_cycle() {  # <state>
  local state=$1 err sequence generation
  err="$state/.test-cycle-drain.err"
  FM_STATE_OVERRIDE="$state" "$DRAIN" >/dev/null 2> "$err" || return 1
  sequence=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation [A-Za-z0-9._-][A-Za-z0-9._-]*$/\1/p' "$err")
  generation=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through [0-9][0-9]* --recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1/p' "$err")
  rm -f "$err"
  [ -n "$sequence" ] && [ -n "$generation" ] || return 1
  FM_STATE_OVERRIDE="$state" "$DRAIN" --ack-through "$sequence" \
    --recovery-generation "$generation"
}

# Common watcher knobs: tight poll/grace, no check or heartbeat cadence unless a
# test overrides them, so a test only exercises the path it targets. FM_CREW_STATE_BIN
# points at the case's hermetic fake fm-crew-state.sh (installed by make_case) so the
# absorb-only-when-provably-working triage reads a canned verdict; a test fixes that
# verdict via FM_FAKE_CREW_STATE in its environment before calling watch_bg.
watch_bg() {  # <state> <fakebin> <out> [extra env assignments...]
  local state=$1 fakebin=$2 out=$3
  shift 3
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$@" "$WATCH" > "$out" &
}

# Wait up to <limit> 0.1s ticks while <pid> stays alive; 0 if still alive, 1 if it died.
wait_live() {
  local pid=$1 limit=${2:-30} i=0
  while [ "$i" -lt "$limit" ]; do
    kill -0 "$pid" 2>/dev/null || return 1
    sleep 0.1
    i=$((i + 1))
  done
  return 0
}

# Wait until <pid>'s watcher has completed a whole poll cycle, or exited first.
# A fixed wait_live budget only proves the process is still ALIVE: fm-watch.sh
# does bounded startup work (the recovery-marker snapshot, lock acquisition)
# before its first stale scan, so on a loaded
# machine a short fixed budget can reap a round before the cycle it asserts on
# ever ran - and then every "no wake, no marker" assertion passes vacuously
# while every "marker written" assertion fails spuriously.
# The liveness beacon is touched at the TOP of every poll, so this drops any
# beacon left by an earlier round, waits for THIS watcher to write a fresh one
# (some poll's top), then waits for that one to advance (the next poll's top) -
# and the whole cycle in between is what the caller's assertions describe.
# 0 if the watcher is still alive after a completed cycle, 1 if it exited.
wait_poll_cycle() {  # <state> <pid> [limit-ticks]
  local state=$1 pid=$2 limit=${3:-300} beat first now i=0
  beat="$state/.last-watcher-beat"
  rm -f "$beat"
  first=""
  while [ "$i" -lt "$limit" ]; do
    kill -0 "$pid" 2>/dev/null || return 1
    first=$(file_mtime "$beat")
    [ -n "$first" ] && break
    sleep 0.1
    i=$((i + 1))
  done
  while [ "$i" -lt "$limit" ]; do
    kill -0 "$pid" 2>/dev/null || return 1
    now=$(file_mtime "$beat")
    if [ -n "$now" ] && [ "$now" != "$first" ]; then
      return 0
    fi
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

# Every wait_for_exit budget in this file is 100 ticks (10s), not because any
# watcher takes that long to decide, but because fm-watch.sh does bounded
# startup work before its first poll: a tighter budget reaps the process while
# it is still starting and reports a spurious "did not surface" failure. A
# generous budget can only remove that false negative - a watcher that never
# exits still fails the assertion when the budget runs out.
wait_numeric_file() {
  local file=$1 limit=${2:-30} i=0 value
  while [ "$i" -lt "$limit" ]; do
    value=$(cat "$file" 2>/dev/null || true)
    case "$value" in
      ''|*[!0-9]*) ;;
      *) return 0 ;;
    esac
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

# Portable mtime in epoch seconds. Platform-detected, never the `stat -f || stat -c`
# fallback (which writes a partial filesystem dump on Linux; see fm-watch.sh).
file_mtime() {
  if [ "$(uname)" = Darwin ]; then stat -f %m "$1" 2>/dev/null; else stat -c %Y "$1" 2>/dev/null; fi
}

# Set <file>'s mtime to exactly <epoch> seconds, for aging a busy-turn marker by
# a precise amount (touch -t takes a local-time stamp, not an epoch, on both
# platforms, so convert via BSD `date -r` or GNU `date -d @`).
set_mtime() {  # <epoch> <file>
  local epoch=$1 f=$2 stamp
  if stamp=$(date -r "$epoch" +%Y%m%d%H%M.%S 2>/dev/null); then
    touch -t "$stamp" "$f"
  else
    stamp=$(date -d "@$epoch" +%Y%m%d%H%M.%S)
    touch -t "$stamp" "$f"
  fi
}

# Signature a primed .seen-* marker must hold so the per-poll signal scan does not
# fire on a pre-existing status (mirrors fm-watch.sh's stat_sig exactly).
seen_sig() {
  local reported size ident
  case "$1" in
    *.status)
      reported=$(status_observed_signature "$1")
      size=$(size_of "$1")
      ident=$(_fm_open_decisions_file_ident "$1")
      printf 'v2\t%s\t%s@%s' "$reported" "$size" "$ident"
      ;;
    *)
      if [ "$(uname)" = Darwin ]; then stat -f '%z:%Fm' "$1" 2>/dev/null; else stat -c '%s:%Y' "$1" 2>/dev/null; fi
      ;;
  esac
}

# Prime <file>'s .seen-* suppressor to its CURRENT signature, so the per-poll
# no-verb signal scan (which watches every *.turn-ended for a size:mtime change)
# treats a just-created or just-backdated turn-ended marker as already seen.
# Busy-turn-age fixtures create/backdate turn-ended directly (there is no real
# harness touching it), so without this the marker's own first sighting would
# fire an unrelated "signal:" wake and mask the busy-turn-age assertion under
# test. Call again after any further touch/set_mtime on the same file.
prime_turnend_seen() {  # <file>
  local f=$1 base
  base=$(basename "$f" | tr '.' '_')
  printf '%s' "$(seen_sig "$f")" > "$(dirname "$f")/.seen-$base"
}

record_pi_busy() {  # <state-dir> <id>
  local state=$1 id=$2 gen
  gen=$("$ROOT/bin/fm-busy-event.sh" arm "$state" "$id")
  "$ROOT/bin/fm-busy-event.sh" apply "$state" "$id" busy --gen "$gen" \
    --source pi-ext --event agent-start
}

# Stop and reap a watcher this suite started. A bare `kill; wait` hung CI for
# 27 minutes when bash 5.2 lost the TERM; tests/wake-helpers.sh's
# term_and_reap owns why and how the stop stays bounded.
reap() { term_and_reap "$1"; }


size_of() { LC_ALL=C wc -c < "$1" | tr -d '[:space:]'; }

# bin/fm-captain-hold.sh against a hold fixture's own home.
run_hold() {  # <dir> <args...>
  local dir=$1
  shift
  FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" FM_DATA_OVERRIDE="$dir/data" \
    FM_CONFIG_OVERRIDE="$dir/config" "$ROOT/bin/fm-captain-hold.sh" "$@" >/dev/null 2>&1
}

make_hold_home() {  # <name> <status-line> <hold|nohold>
  local name=$1 line=$2 hold=$3 dir state
  dir=$(make_case "$name"); state="$dir/state"
  mkdir -p "$dir/data" "$dir/config"
  cp "$ROOT/.tasks.toml" "$dir/.tasks.toml" || return 1
  printf '## In flight\n\n## Queued\n\n## Done\n' > "$dir/data/backlog.md"
  (cd "$dir" && tasks-axi add held-merge 'delivered work' --file data/backlog.md) >/dev/null 2>&1 \
    || return 1
  if [ "$hold" = hold ]; then
    run_hold "$dir" hold held-merge --reason 'awaiting the captain on the merge' || return 1
  fi
  printf 'window=test:fm-held-merge\nkind=ship\nharness=grok\nbackend=tmux\n' \
    > "$state/held-merge.meta"
  printf '%s\n' "$line" > "$state/held-merge.status"
  printf '%s' "$(seen_sig "$state/held-merge.status")" > "$state/.seen-held-merge_status"
  printf '%s\n' "$dir"
}

hold_watch_launch() {  # <dir> <out> <capture>
  local dir=$1 out=$2 capture=$3
  PATH="$dir/fakebin:$PATH" FM_FAKE_TMUX_WINDOW=test:fm-held-merge \
    FM_FAKE_TMUX_CAPTURE="$capture" FM_FAKE_TMUX_CURRENT_COMMAND=zsh \
    FM_FAKE_CREW_STATE='state: stopped · source: pane · bare shell' \
    FM_WATCH_HANDLING_SUCCESSOR=1 \
    FM_HOME="$dir" FM_DATA_OVERRIDE="$dir/data" FM_CONFIG_OVERRIDE="$dir/config" \
    FM_STATE_OVERRIDE="$dir/state" FM_CREW_STATE_BIN="$dir/fakebin/fm-crew-state.sh" \
    FM_PAUSE_RESURFACE_SECS="${FM_HOLD_PAUSE_RESURFACE_SECS:-999}" FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" >> "$out" 2>&1 &
  HOLD_WATCH_PID=$!
}

# One sighting that must surface and exit the cycle.
hold_watch_surface() {  # <dir> <out> <capture> <pane-text>
  local dir=$1 out=$2 capture=$3 text=$4
  printf '%s\n' "$text" > "$capture"
  hold_watch_launch "$dir" "$out" "$capture"
  wait_for_exit "$HOLD_WATCH_PID" 100 || { reap "$HOLD_WATCH_PID"; return 1; }
  return 0
}

# <count> successive pane changes driven through ONE watcher, each given three
# poll cycles: one to see the new hash, one to count it stable and classify, one
# to prove the classification held. The watcher must stay in the loop throughout.
hold_watch_churn() {  # <dir> <out> <capture> <label> <count>
  local dir=$1 out=$2 capture=$3 label=$4 count=$5 i=1 c
  local state="$dir/state"
  printf '%s 0\n' "$label" > "$capture"
  hold_watch_launch "$dir" "$out" "$capture"
  while [ "$i" -le "$count" ]; do
    printf '%s %s\n' "$label" "$i" > "$capture"
    c=0
    while [ "$c" -lt 3 ]; do
      wait_poll_cycle "$state" "$HOLD_WATCH_PID" 300 \
        || { reap "$HOLD_WATCH_PID"; return 1; }
      c=$((c + 1))
    done
    i=$((i + 1))
  done
  reap "$HOLD_WATCH_PID"
  return 0
}

hold_stale_wakes() {  # <state>
  awk -F '\t' '$3 == "stale" && $4 == "test:fm-held-merge" { n++ } END { print n + 0 }' \
    "$1/.wake-queue" 2>/dev/null || echo 0
}

# A UTC ISO 8601 stamp for an epoch, on either date flavor.
iso_utc_at() {  # <epoch>
  date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ
}

REAP_DOG=
TASK_HOLD_PID=
TASK_RUNNER_PID=
WHOLE_MACHINE_PID=
BUILD_LOCK_WAIT_LINE='paused [key=build-lock-4242-1700000000]: waiting 10m00s for the machine-wide build lock to run bin/fm-test-run.sh [in /wt] - held by pid 999 for 12m00s running: x'
BUILD_LOCK_RESOLVED_LINE='resolved [key=build-lock-4242-1700000000]: acquired the machine-wide build lock after 10m28s'
BUILD_LOCK_NOTE_LINE='note: holding the machine-wide build lock for 20m00s with 1 waiting, past the 1200s ceiling; not being killed: bin/fm-test-run.sh [in /wt]'
HOLD_WATCH_PID=
