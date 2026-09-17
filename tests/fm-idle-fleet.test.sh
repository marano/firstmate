#!/usr/bin/env bash
# tests/fm-idle-fleet.test.sh - the idle-fleet alarm: a home with a free task slot
# and dispatchable queued work must not be able to go quiet.
#
# Three layers, because they fail for different reasons:
#   - bin/fm-idle-fleet-lib.sh's condition as pure functions: what counts as an
#     in-progress task, how capacity is read and refused, and the whole
#     free-capacity-AND-ready-work matrix.
#   - bin/fm-watch.sh driven as a real subprocess: the scan cadence, the sustain
#     window that keeps an ordinary dispatch gap silent, the durable wake, its
#     queued-key deduplication, and the re-surface of a condition that persists.
#   - bin/fm-supervise-daemon.sh's classifier: the alarm must NOT be absorbed by
#     the away-mode self-handling path, which is exactly the path that swallowed
#     the periodic fleet review on the night this detector exists for.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-idle-fleet-lib.sh"

WATCH_CHECKPOINT="$ROOT/bin/fm-watch-checkpoint.sh"
DRAIN="$ROOT/bin/fm-wake-drain.sh"

TMP_ROOT=$(fm_test_tmproot fm-idle-fleet-tests)

# Source the daemon's pure functions for the away-mode layer. Its main loop is
# skipped under sourcing via a BASH_SOURCE guard.
if [ -z "${FM_TEST_DAEMON_SOURCED:-}" ]; then
  export FM_TEST_DAEMON_SOURCED=1
  # shellcheck source=/dev/null
  . "$ROOT/bin/fm-supervise-daemon.sh"
fi

# A home fixture: state/, config/, data/, and a fakebin whose `tasks-axi` reports
# whatever ready count the case wants. The count is read from a file rather than
# baked in so one home can change its queue between watcher runs.
make_home() {  # <name>
  local name=$1 dir
  dir=$(make_case "$name")
  mkdir -p "$dir/config" "$dir/data"
  printf '0\n' > "$dir/ready-count"
  cat > "$dir/fakebin/tasks-axi" <<'SH'
#!/usr/bin/env bash
set -u
[ "${1:-}" = ready ] || { printf 'unexpected tasks-axi invocation: %s\n' "$*" >&2; exit 2; }
count=$(cat "${FM_FAKE_READY_COUNT_FILE:?}" 2>/dev/null || echo 0)
case "$count" in
  fail) printf 'backlog unavailable\n' >&2; exit 1 ;;
esac
printf 'count: %s\n' "$count"
if [ "$count" -eq 0 ]; then
  printf 'ready: 0 unblocked queued tasks\n'
else
  printf 'ready[%s]{id,state,kind,repo,title}:\n' "$count"
  i=1
  while [ "$i" -le "$count" ]; do
    printf '  fm-q%s,queued,task,"-",Queued %s\n' "$i" "$i"
    i=$((i + 1))
  done
fi
printf 'ready_public_followups: 0 delivery-ready obligations\n'
SH
  chmod +x "$dir/fakebin/tasks-axi"
  # A fake clock, so the sustain and re-surface windows are driven exactly rather
  # than slept through. It delegates every other use of date, and stands aside
  # entirely when no case has pinned a now.
  cat > "$dir/fakebin/date" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = +%s ] && [ -n "\${FM_FAKE_NOW_FILE:-}" ] && [ -s "\${FM_FAKE_NOW_FILE}" ]; then
  cat "\${FM_FAKE_NOW_FILE}"
  exit 0
fi
exec $(command -v date) "\$@"
SH
  chmod +x "$dir/fakebin/date"
  printf '%s\n' "$dir"
}

# Record an ordinary crew task: a metadata record, and optionally a status line.
record_task() {  # <state> <id> [status-line]
  local state=$1 id=$2 line=${3-}
  printf 'window=firstmate:fm-%s\nkind=task\nharness=claude\n' "$id" > "$state/$id.meta"
  [ -z "$line" ] || printf '%s\n' "$line" > "$state/$id.status"
}

# Run one bounded watcher checkpoint against <home>, with the idle-fleet windows
# the case wants and every other cadence parked. Echoes the checkpoint's stdout.
# The caller's extra assignments go through `env` rather than being spliced in as
# a prefix: bash recognises assignments before expansion, so an expanded
# `FM_IDLE_FLEET_SECS=1` would be run as a command name instead of set.
run_checkpoint() {  # <home> <seconds> [extra env assignments...]
  local home=$1 seconds=$2
  shift 2
  PATH="$home/fakebin:$PATH" \
    FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" \
    FM_CREW_STATE_BIN="$home/fakebin/fm-crew-state.sh" \
    FM_FAKE_READY_COUNT_FILE="$home/ready-count" \
    FM_POLL=1 FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    FM_IDLE_FLEET_SCAN_SECS=1 \
    env "$@" \
    "$WATCH_CHECKPOINT" --seconds "$seconds" 2>/dev/null || true
}

# Run bin/fm-watch.sh's idle_fleet_tick once against <home> at a pinned now,
# with the production wake() replaced by one that prints its reason instead of
# ending the cycle. Driving the tick directly is what makes the window tests
# deterministic: a whole watcher cycle also runs its own recovery
# re-announcement after any earlier wake, which would end the checkpoint before
# this tick ever ran and leave the assertion passing vacuously.
# A now of `-` leaves the clock real, for the cases that are about the scan
# cadence rather than the windows.
run_tick() {  # <home> <now|-> [extra env assignments...]
  local home=$1 now=$2
  shift 2
  if [ "$now" = - ]; then
    : > "$home/now"
  else
    printf '%s\n' "$now" > "$home/now"
  fi
  env PATH="$home/fakebin:$PATH" \
    FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" \
    FM_FAKE_NOW_FILE="$home/now" FM_FAKE_READY_COUNT_FILE="$home/ready-count" \
    FM_CREW_STATE_BIN="$home/fakebin/fm-crew-state.sh" \
    "$@" \
    bash -c '
      set -u
      # shellcheck source=/dev/null
      . "$1/bin/fm-watch.sh"
      wake() { printf "%s\n" "$1"; }
      idle_fleet_tick
    ' _ "$ROOT"
}

# Make the next run_tick due regardless of when the last one ran, for the cases
# that are about the windows rather than the scan cadence.
clear_scan_gate() {  # <home>
  rm -f "$1/state/.last-idle-fleet-scan"
}

ack_queue() {  # <state>
  local state=$1 err sequence generation
  err="$state/.test-drain.err"
  FM_STATE_OVERRIDE="$state" "$DRAIN" >/dev/null 2> "$err" || return 1
  sequence=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation [A-Za-z0-9._-][A-Za-z0-9._-]*$/\1/p' "$err")
  generation=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through [0-9][0-9]* --recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1/p' "$err")
  rm -f "$err"
  [ -n "$sequence" ] && [ -n "$generation" ] || return 1
  FM_STATE_OVERRIDE="$state" "$DRAIN" --ack-through "$sequence" --recovery-generation "$generation" >/dev/null
}

# --- the condition, as pure functions ---------------------------------------

test_capacity_defaults_to_one_when_unconfigured() {
  local dir
  dir=$(make_home capacity-default)
  # AGENTS.md section 7 sets no fleet-wide concurrency cap, so an unconfigured
  # home must not have one invented for it. Capacity 1 is the narrowest true
  # reading of "a slot is free": only a completely idle fleet qualifies.
  [ "$(fm_idle_fleet_capacity "$dir/config")" = 1 ] \
    || fail "an unconfigured home did not fall back to detecting a completely idle fleet"
  fm_idle_fleet_capacity_configured "$dir/config" \
    && fail "an absent config/fleet-capacity was reported as configured"
  pass "an unconfigured home detects only a completely idle fleet"
}

test_capacity_reads_a_configured_value_and_refuses_a_malformed_one() {
  local dir file value status
  dir=$(make_home capacity-parse)
  file="$dir/config/fleet-capacity"

  printf '5\n' > "$file"
  [ "$(fm_idle_fleet_capacity "$dir/config")" = 5 ] \
    || fail "a configured capacity of 5 was not read back"
  fm_idle_fleet_capacity_configured "$dir/config" \
    || fail "a present config/fleet-capacity was not reported as configured"
  printf '  7  \n' > "$file"
  [ "$(fm_idle_fleet_capacity "$dir/config")" = 7 ] \
    || fail "surrounding whitespace defeated a valid capacity"

  # Every malformed form is refused rather than defaulted around: a typo that
  # silently narrowed the detector would restore the silence it exists to remove.
  for value in '0' '-3' 'five' '' '5 6'; do
    printf '%s\n' "$value" > "$file"
    value=$(fm_idle_fleet_capacity "$dir/config") && status=0 || status=$?
    [ "$status" = 2 ] || fail "capacity '$value' was accepted instead of refused (status $status)"
    [ -z "$value" ] || fail "a refused capacity still printed a value: $value"
  done

  printf '3\n4\n' > "$file"
  fm_idle_fleet_capacity "$dir/config" >/dev/null 2>&1 \
    && fail "a two-line capacity file was accepted instead of refused"

  rm -f "$file"
  printf '4\n' > "$dir/elsewhere"
  ln -s "$dir/elsewhere" "$file"
  fm_idle_fleet_capacity "$dir/config" >/dev/null 2>&1 \
    && fail "a symlinked capacity file was accepted instead of refused"
  rm -f "$file"
  pass "a configured capacity is read and every malformed form is refused"
}

test_in_progress_counts_open_work_and_not_concluded_agents() {
  local dir state
  dir=$(make_home in-progress)
  state="$dir/state"

  [ "$(fm_idle_fleet_in_progress "$state")" = 0 ] \
    || fail "a home with no task records did not count zero work in progress"

  # Open work, whatever it is waiting on, holds its slot.
  record_task "$state" open-working 'working: implementing'
  record_task "$state" open-blocked 'blocked: needs a credential'
  record_task "$state" open-decision 'needs-decision: two options'
  record_task "$state" open-paused 'paused: upstream release'
  record_task "$state" open-held 'captain-held: awaiting the captain'
  record_task "$state" open-fresh
  [ "$(fm_idle_fleet_in_progress "$state")" = 6 ] \
    || fail "open work was not counted as in progress: $(fm_idle_fleet_in_progress "$state")"

  # A crew that reported a concluded outcome is an idle agent, not in-progress
  # work. This is the whole distinction: on the night this detector exists for,
  # five workers sat exactly here while every backlog row still read In flight,
  # because nothing merged and so teardown never ran.
  record_task "$state" done-unlanded 'done: PR https://example.test/pr/1 checks green'
  record_task "$state" failed-out 'failed: pipeline gave up'
  [ "$(fm_idle_fleet_in_progress "$state")" = 6 ] \
    || fail "a concluded worker was counted as in-progress work"

  # A persistent secondmate is not a work item at all.
  printf 'window=firstmate:fm-mate\nkind=secondmate\nharness=claude\n' > "$state/mate.meta"
  printf 'working: supervising\n' > "$state/mate.status"
  [ "$(fm_idle_fleet_in_progress "$state")" = 6 ] \
    || fail "a persistent secondmate was counted against task capacity"

  # A later append decides, so a worker that resumes after reporting done
  # reclaims its slot rather than staying counted as free forever.
  printf 'working: follow-up fix\n' >> "$state/done-unlanded.status"
  [ "$(fm_idle_fleet_in_progress "$state")" = 7 ] \
    || fail "a concluded worker that resumed did not reclaim its slot"
  pass "in-progress counts open work only, never concluded agents or secondmates"
}

test_condition_needs_both_free_capacity_and_ready_work() {
  local dir state status
  dir=$(make_home condition-matrix)
  state="$dir/state"
  printf '2\n' > "$dir/config/fleet-capacity"
  record_task "$state" busy-one 'working: implementing'
  printf '3\n' > "$dir/ready-count"

  # Free capacity plus ready work: the condition holds, and it names its numbers.
  FM_FAKE_READY_COUNT_FILE="$dir/ready-count" PATH="$dir/fakebin:$PATH" \
    fm_idle_fleet_condition "$state" "$dir/config" "$dir" \
    || fail "free capacity with ready work did not detect the condition"
  [ "$FM_IDLE_FLEET_IN_PROGRESS" = 1 ] || fail "the condition misreported work in progress"
  [ "$FM_IDLE_FLEET_CAPACITY" = 2 ] || fail "the condition misreported capacity"
  [ "$FM_IDLE_FLEET_READY" = 3 ] || fail "the condition misreported the ready queue"

  # At capacity: a working fleet is not a fault, whatever the queue holds.
  record_task "$state" busy-two 'working: implementing'
  FM_FAKE_READY_COUNT_FILE="$dir/ready-count" PATH="$dir/fakebin:$PATH" \
    fm_idle_fleet_condition "$state" "$dir/config" "$dir" && status=0 || status=$?
  [ "$status" = 1 ] || fail "a fleet at its cap raised the condition (status $status)"

  # An empty ready queue: a quiet fleet with nothing to do is not a fault either.
  rm -f "$state/busy-two.meta"
  printf '0\n' > "$dir/ready-count"
  FM_FAKE_READY_COUNT_FILE="$dir/ready-count" PATH="$dir/fakebin:$PATH" \
    fm_idle_fleet_condition "$state" "$dir/config" "$dir" && status=0 || status=$?
  [ "$status" = 1 ] || fail "an empty ready queue raised the condition (status $status)"
  pass "the condition needs free capacity AND ready work, and reports its numbers"
}

test_condition_separates_a_bad_capacity_from_an_unreadable_queue() {
  local dir state status
  dir=$(make_home condition-refusals)
  state="$dir/state"
  printf '4\n' > "$dir/ready-count"

  printf 'lots\n' > "$dir/config/fleet-capacity"
  FM_FAKE_READY_COUNT_FILE="$dir/ready-count" PATH="$dir/fakebin:$PATH" \
    fm_idle_fleet_condition "$state" "$dir/config" "$dir" && status=0 || status=$?
  [ "$status" = 2 ] || fail "a malformed capacity did not refuse to evaluate (status $status)"
  [ -z "$FM_IDLE_FLEET_READY" ] \
    || fail "a refused evaluation still read the backlog"

  rm -f "$dir/config/fleet-capacity"
  printf 'fail\n' > "$dir/ready-count"
  FM_FAKE_READY_COUNT_FILE="$dir/ready-count" PATH="$dir/fakebin:$PATH" \
    fm_idle_fleet_condition "$state" "$dir/config" "$dir" && status=0 || status=$?
  [ "$status" = 3 ] || fail "an unreadable ready queue was not reported separately (status $status)"
  pass "a malformed capacity and an unreadable queue are separate, named refusals"
}

# --- the watcher, driven as a real subprocess -------------------------------

test_watcher_raises_a_sustained_idle_fleet() {
  local dir state out
  dir=$(make_home watch-raise)
  state="$dir/state"
  printf '5\n' > "$dir/config/fleet-capacity"
  record_task "$state" solo
  printf '15\n' > "$dir/ready-count"

  out=$(run_checkpoint "$dir" 12 FM_IDLE_FLEET_SECS=1)
  grep -F 'check: fleet idle with ready work: in-progress=1 capacity=5 ready=15 idle=' \
    <<<"$out" >/dev/null \
    || fail "a sustained idle fleet with ready work did not raise the alarm: $out"
  grep -F 'idle-fleet' "$state/.wake-queue" >/dev/null \
    || fail "the alarm did not reach the durable wake queue"
  [ "$(grep -c 'idle-fleet' "$state/.wake-queue")" = 1 ] \
    || fail "the alarm published more than one durable record"
  [ -s "$state/.idle-fleet-alerted" ] || fail "the alarm left no episode record"
  pass "a sustained idle fleet with ready work raises one durable alarm"
}

test_watcher_stays_silent_at_capacity_and_with_an_empty_queue() {
  local dir state out
  dir=$(make_home tick-quiet)
  state="$dir/state"
  printf '2\n' > "$dir/config/fleet-capacity"
  record_task "$state" busy-one
  record_task "$state" busy-two
  printf '15\n' > "$dir/ready-count"

  # A matured window, so only the condition itself decides whether anything is
  # raised; without it a silent result would prove nothing but an unripe window.
  printf '1\n' > "$state/.idle-fleet-since"
  out=$(run_tick "$dir" 100000 FM_IDLE_FLEET_SECS=1)
  [ -z "$out" ] || fail "a fleet at its cap alarmed: $out"
  [ ! -s "$state/.wake-queue" ] || fail "a fleet at its cap queued an alarm"
  [ ! -e "$state/.idle-fleet-since" ] \
    || fail "a fleet at its cap left an episode window open"

  rm -f "$state/busy-two.meta"
  printf '0\n' > "$dir/ready-count"
  printf '1\n' > "$state/.idle-fleet-since"
  clear_scan_gate "$dir"
  out=$(run_tick "$dir" 100000 FM_IDLE_FLEET_SECS=1)
  [ -z "$out" ] || fail "a free slot with nothing dispatchable alarmed: $out"
  [ ! -s "$state/.wake-queue" ] || fail "an empty ready queue queued an alarm"

  # The control that keeps both silences from being vacuous: the same home, with
  # the queue restocked, must alarm on the very next scan.
  printf '15\n' > "$dir/ready-count"
  printf '1\n' > "$state/.idle-fleet-since"
  clear_scan_gate "$dir"
  out=$(run_tick "$dir" 100000 FM_IDLE_FLEET_SECS=1)
  grep -F 'check: fleet idle with ready work:' <<<"$out" >/dev/null \
    || fail "the same home did not alarm once the queue held dispatchable work: $out"
  pass "a fleet at its cap, or with nothing to start, raises nothing"
}

test_watcher_clears_the_episode_when_the_condition_clears() {
  local dir state out
  dir=$(make_home tick-clears)
  state="$dir/state"
  printf '5\n' > "$dir/config/fleet-capacity"
  record_task "$state" solo
  printf '15\n' > "$dir/ready-count"

  out=$(run_tick "$dir" 1000 FM_IDLE_FLEET_SECS=900)
  [ -z "$out" ] || fail "the first scan of a holding condition alarmed immediately: $out"
  [ "$(cat "$state/.idle-fleet-since")" = 1000 ] \
    || fail "the first scan did not open an episode window at the observed time"

  clear_scan_gate "$dir"
  out=$(run_tick "$dir" 1899 FM_IDLE_FLEET_SECS=900)
  [ -z "$out" ] || fail "the condition alarmed one second inside its sustain window: $out"

  clear_scan_gate "$dir"
  out=$(run_tick "$dir" 1900 FM_IDLE_FLEET_SECS=900)
  grep -F 'check: fleet idle with ready work: in-progress=1 capacity=5 ready=15 idle=900s' \
    <<<"$out" >/dev/null \
    || fail "the condition did not alarm the moment its sustain window matured: $out"
  [ "$(cat "$state/.idle-fleet-alerted")" = 1900 ] \
    || fail "the alarm did not record when it fired"

  # Dispatching is what clears this condition, and clearing it must retire the
  # episode: the next quiet stretch serves its own sustain window rather than
  # inheriting a matured one.
  record_task "$state" second
  record_task "$state" third
  record_task "$state" fourth
  record_task "$state" fifth
  clear_scan_gate "$dir"
  out=$(run_tick "$dir" 1901 FM_IDLE_FLEET_SECS=900)
  [ -z "$out" ] || fail "a cleared condition still alarmed: $out"
  [ ! -e "$state/.idle-fleet-since" ] \
    || fail "a cleared condition left its episode window open"
  [ ! -e "$state/.idle-fleet-alerted" ] \
    || fail "a cleared condition left its alarm record behind"

  rm -f "$state/second.meta" "$state/third.meta" "$state/fourth.meta" "$state/fifth.meta"
  clear_scan_gate "$dir"
  out=$(run_tick "$dir" 1902 FM_IDLE_FLEET_SECS=900)
  [ -z "$out" ] || fail "a fresh episode alarmed without serving its own sustain window: $out"
  [ "$(cat "$state/.idle-fleet-since")" = 1902 ] \
    || fail "a fresh episode did not start its window from scratch"
  pass "the sustain window is served exactly, and clearing the condition retires the episode"
}

test_watcher_resurfaces_a_condition_that_keeps_holding() {
  local dir state out
  dir=$(make_home tick-resurface)
  state="$dir/state"
  printf '5\n' > "$dir/config/fleet-capacity"
  record_task "$state" solo
  printf '15\n' > "$dir/ready-count"

  run_tick "$dir" 1000 FM_IDLE_FLEET_SECS=1 >/dev/null
  clear_scan_gate "$dir"
  out=$(run_tick "$dir" 1001 FM_IDLE_FLEET_SECS=1)
  grep -F 'fleet idle with ready work' <<<"$out" >/dev/null \
    || fail "the first alarm did not fire: $out"
  ack_queue "$state" || fail "the first alarm could not be acknowledged"

  # Inside the re-surface window the same condition must not re-alarm, or a
  # persisting idle fleet would wake firstmate on every scan.
  clear_scan_gate "$dir"
  out=$(run_tick "$dir" 4600 FM_IDLE_FLEET_SECS=1 FM_IDLE_FLEET_RESURFACE_SECS=3600)
  [ -z "$out" ] \
    || fail "a still-holding condition re-alarmed inside its re-surface window: $out"
  [ "$(grep -c 'idle-fleet' "$state/.wake-queue" 2>/dev/null || true)" = 0 ] \
    || fail "a re-surface window was ignored by the durable queue: $(cat "$state/.wake-queue")"

  # Past it, the condition must alarm again: the incident this detector exists
  # for was eight hours of silence, so one missed alarm cannot buy another.
  clear_scan_gate "$dir"
  out=$(run_tick "$dir" 4601 FM_IDLE_FLEET_SECS=1 FM_IDLE_FLEET_RESURFACE_SECS=3600)
  grep -F 'check: fleet idle with ready work:' <<<"$out" >/dev/null \
    || fail "a condition still holding past its re-surface window went silent: $out"
  grep -F 'idle=3601s' <<<"$out" >/dev/null \
    || fail "the re-surfaced alarm did not report how long the fleet had been idle: $out"
  pass "a condition that keeps holding re-surfaces on its own cadence, not on every scan"
}

test_watcher_does_not_duplicate_an_unhandled_alarm() {
  local dir state out
  dir=$(make_home tick-dedupe)
  state="$dir/state"
  printf '5\n' > "$dir/config/fleet-capacity"
  record_task "$state" solo
  printf '15\n' > "$dir/ready-count"

  run_tick "$dir" 1000 FM_IDLE_FLEET_SECS=1 >/dev/null
  clear_scan_gate "$dir"
  out=$(run_tick "$dir" 1001 FM_IDLE_FLEET_SECS=1)
  grep -F 'fleet idle with ready work' <<<"$out" >/dev/null \
    || fail "the first alarm did not fire: $out"

  # Deliberately NOT acknowledged: an alarm still queued is still in front of
  # firstmate, so a second record says nothing the first does not - even well
  # past the re-surface window that would otherwise re-raise it.
  clear_scan_gate "$dir"
  out=$(run_tick "$dir" 9000 FM_IDLE_FLEET_SECS=1 FM_IDLE_FLEET_RESURFACE_SECS=1)
  [ -z "$out" ] \
    || fail "an alarm still queued was raised a second time: $out"
  [ "$(grep -c 'idle-fleet' "$state/.wake-queue")" = 1 ] \
    || fail "an unhandled alarm was duplicated: $(cat "$state/.wake-queue")"
  pass "an alarm still queued is not duplicated by a later scan"
}

test_scan_cadence_keeps_the_backlog_read_off_the_poll_path() {
  local dir state out now
  dir=$(make_home tick-cadence)
  state="$dir/state"
  printf '5\n' > "$dir/config/fleet-capacity"
  record_task "$state" solo
  printf '15\n' > "$dir/ready-count"

  # A matured window on the real clock, so only the scan cadence decides whether
  # this tick evaluates anything at all.
  now=$(date +%s)
  printf '%s\n' "$((now - 100000))" > "$state/.idle-fleet-since"
  touch "$state/.last-idle-fleet-scan"

  out=$(run_tick "$dir" - FM_IDLE_FLEET_SECS=1 FM_IDLE_FLEET_SCAN_SECS=999999)
  [ -z "$out" ] \
    || fail "a scan ran inside its own cadence, putting a backlog read on the poll path: $out"

  # The control that keeps that silence from being vacuous: the same state, one
  # cadence later, must alarm.
  clear_scan_gate "$dir"
  out=$(run_tick "$dir" - FM_IDLE_FLEET_SECS=1 FM_IDLE_FLEET_SCAN_SECS=999999)
  grep -F 'check: fleet idle with ready work:' <<<"$out" >/dev/null \
    || fail "a due scan did not evaluate the condition: $out"
  pass "the scan cadence bounds how often the backlog is read at all"
}

test_watcher_reports_a_capacity_it_cannot_read() {
  local dir state out
  dir=$(make_home tick-bad-capacity)
  state="$dir/state"
  printf '5\n' > "$dir/config/fleet-capacity"
  record_task "$state" solo
  printf '15\n' > "$dir/ready-count"

  run_tick "$dir" 1000 FM_IDLE_FLEET_SECS=900 >/dev/null
  [ -s "$state/.idle-fleet-since" ] || fail "the episode window did not open"

  printf 'plenty\n' > "$dir/config/fleet-capacity"
  clear_scan_gate "$dir"
  out=$(run_tick "$dir" 1100 FM_IDLE_FLEET_SECS=900)
  grep -F 'check: fleet idle detector disabled:' <<<"$out" >/dev/null \
    || fail "a capacity the detector cannot read was silently defaulted around: $out"
  grep -F 'idle-fleet-config' "$state/.wake-queue" >/dev/null \
    || fail "the disabled-detector report did not reach the durable wake queue"
  # Nothing was evaluated, so the episode goes with it: a repaired detector must
  # serve a fresh window rather than mature one nobody verified.
  [ ! -e "$state/.idle-fleet-since" ] \
    || fail "a refused evaluation left its episode window open"

  # Reported once, not on every scan.
  clear_scan_gate "$dir"
  out=$(run_tick "$dir" 1200 FM_IDLE_FLEET_SECS=900)
  [ -z "$out" ] || fail "the disabled-detector report repeated while still queued: $out"
  [ "$(grep -c 'idle-fleet-config' "$state/.wake-queue")" = 1 ] \
    || fail "the disabled-detector report was duplicated"
  pass "a capacity the detector cannot read is reported once and retires its episode"
}

test_watcher_stays_quiet_when_the_ready_queue_cannot_be_read() {
  local dir state out since
  dir=$(make_home tick-unreadable-queue)
  state="$dir/state"
  record_task "$state" solo 'done: PR https://example.test/pr/1 checks green'
  printf '15\n' > "$dir/ready-count"

  run_tick "$dir" 1000 FM_IDLE_FLEET_SECS=900 >/dev/null
  since=$(cat "$state/.idle-fleet-since")
  [ "$since" = 1000 ] || fail "the episode window did not open"

  # bin/fm-bootstrap.sh's MISSING diagnostic already owns telling the operator the
  # backlog tool is unavailable; a second wake would report it on two cadences.
  printf 'fail\n' > "$dir/ready-count"
  clear_scan_gate "$dir"
  out=$(run_tick "$dir" 1100 FM_IDLE_FLEET_SECS=900)
  [ -z "$out" ] \
    || fail "an unreadable ready queue produced a second owner for a bootstrap diagnostic: $out"
  [ ! -s "$state/.wake-queue" ] \
    || fail "an unreadable ready queue queued a wake: $(cat "$state/.wake-queue")"
  grep -F 'idle-fleet detection skipped' "$state/.watch-triage.log" >/dev/null \
    || fail "an unreadable ready queue was not recorded in the triage log"
  # The free-slot half WAS verified before the read failed, so the window is left
  # exactly as it was; an intermittent backlog must not be able to reset it
  # forever and suppress the alarm.
  [ "$(cat "$state/.idle-fleet-since")" = "$since" ] \
    || fail "an unreadable ready queue restarted the episode window"
  pass "an unreadable ready queue is logged, and neither re-reported nor allowed to reset the window"
}

# --- away mode --------------------------------------------------------------

test_away_mode_escalates_the_idle_fleet_alarm() {
  local dir state reason out
  dir=$(make_supercase away-escalates)
  state="$dir/state"
  reason='check: fleet idle with ready work: in-progress=0 capacity=5 ready=15 idle=932s'

  # The control that keeps this test from going vacuous: the away-mode daemon
  # really does force-self-handle the periodic fleet review, which is how the
  # second queue-re-evaluation trigger disappeared on the night this detector
  # exists for. The alarm must not travel that path.
  should_force_self heartbeat \
    || fail "the daemon no longer self-handles heartbeat wakes; this test's contrast is gone"
  should_force_self "$reason" \
    && fail "the idle-fleet alarm was absorbed by the away-mode self-handling path"

  FM_ESCALATE_BATCH_SECS=999 LOG="$dir/daemon.log" FM_STATE_OVERRIDE="$state" \
    handle_wake "$reason" "$state" \
    || fail "the daemon failed to classify the idle-fleet alarm"
  out=$(cat "$state/.subsuper-escalations" 2>/dev/null || true)
  case "$out" in
    *"fleet idle with ready work"*) ;;
    *) fail "the away-mode daemon did not escalate the idle-fleet alarm: $out" ;;
  esac
  pass "away mode escalates the idle-fleet alarm instead of self-handling it"
}

test_away_mode_escalates_the_disabled_detector_report() {
  local dir state reason out
  dir=$(make_supercase away-escalates-disabled)
  state="$dir/state"
  reason='check: fleet idle detector disabled: /home/config/fleet-capacity is not one positive integer'

  should_force_self "$reason" \
    && fail "the disabled-detector report was absorbed by the away-mode self-handling path"
  FM_ESCALATE_BATCH_SECS=999 LOG="$dir/daemon.log" FM_STATE_OVERRIDE="$state" \
    handle_wake "$reason" "$state" \
    || fail "the daemon failed to classify the disabled-detector report"
  out=$(cat "$state/.subsuper-escalations" 2>/dev/null || true)
  case "$out" in
    *"fleet idle detector disabled"*) ;;
    *) fail "the away-mode daemon did not escalate the disabled-detector report: $out" ;;
  esac
  pass "away mode escalates a detector it can no longer run"
}

test_capacity_defaults_to_one_when_unconfigured
test_capacity_reads_a_configured_value_and_refuses_a_malformed_one
test_in_progress_counts_open_work_and_not_concluded_agents
test_condition_needs_both_free_capacity_and_ready_work
test_condition_separates_a_bad_capacity_from_an_unreadable_queue
test_watcher_raises_a_sustained_idle_fleet
test_watcher_stays_silent_at_capacity_and_with_an_empty_queue
test_watcher_clears_the_episode_when_the_condition_clears
test_watcher_resurfaces_a_condition_that_keeps_holding
test_watcher_does_not_duplicate_an_unhandled_alarm
test_scan_cadence_keeps_the_backlog_read_off_the_poll_path
test_watcher_reports_a_capacity_it_cannot_read
test_watcher_stays_quiet_when_the_ready_queue_cannot_be_read
test_away_mode_escalates_the_idle_fleet_alarm
test_away_mode_escalates_the_disabled_detector_report
