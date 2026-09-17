#!/usr/bin/env bash
# tests/fm-idle-fleet.test.sh - the idle-fleet alarm: a home with a free task slot
# and dispatchable queued work must not be able to go quiet.
#
# Four layers, because they fail for different reasons:
#   - bin/fm-task-kind-lib.sh's vocabulary: which kinds a spawn records, and
#     which of them is work that occupies a task slot. Pinned here because the
#     counter below is its main reader, and because a counter tested only against
#     kinds no spawn writes is the defect that made every assertion in this file
#     pass while the detector read zero work in progress forever.
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

# Record one task the way a real spawn does, and optionally its latest status
# line. <kind> defaults to `ship`, which is what bin/fm-spawn.sh records with
# neither --scout nor --secondmate.
#
# THE FIELD SET AND THE KIND BOTH MATTER, and getting the kind wrong here is why
# this file's assertions all passed while the detector was structurally broken.
# The fixture used to write `kind=task`, a value no spawn has ever produced, so
# every case below described a fleet that does not exist: the counter skipped
# every record, read zero work in progress forever, and the alarm fired on a
# fleet with two workers actively working. A fixture is only evidence if it looks
# like what the writer writes.
record_task() {  # <state> <id> [status-line] [kind]
  local state=$1 id=$2 line=${3-} kind=${4-ship}
  {
    printf 'window=firstmate:fm-%s\n' "$id"
    printf 'endpoint_task_id=%s\n' "$id"
    printf 'worktree=%s/worktrees/%s\n' "$state" "$id"
    if [ "$kind" = secondmate ]; then
      printf 'home=%s/homes/%s\n' "$state" "$id"
    else
      printf 'project=%s/projects/demo\n' "$state"
    fi
    printf 'harness=claude\n'
    printf 'kind=%s\n' "$kind"
    [ "$kind" = secondmate ] || printf 'mode=no-mistakes\nyolo=off\n'
    printf 'tasktmp=%s/tmp/%s\n' "$state" "$id"
    printf 'model=default\neffort=default\n'
    printf 'spawn_gen=g1.%s\n' "$id"
  } > "$state/$id.meta"
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
  # $1 below is the bash -c child shell's positional param, not this parent shell's
  # shellcheck disable=SC2016
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
  local dir status
  dir=$(make_home capacity-default)
  # AGENTS.md section 7 sets no fleet-wide concurrency cap, so an unconfigured
  # home must not have one invented for it. Capacity 1 is the narrowest true
  # reading of "a slot is free": only a completely idle fleet qualifies, and
  # every home stays covered without stating anything.
  [ "$(fm_idle_fleet_capacity "$dir/config")" = 1 ] \
    || fail "an unconfigured home did not fall back to detecting a completely idle fleet"
  fm_idle_fleet_capacity_configured "$dir/config" \
    && fail "an absent config/fleet-capacity was reported as configured"
  # An absent file is USABLE; only a malformed one refuses. Keeping those apart
  # matters: making absence refuse would switch this detector off by default in
  # every home that has never written the file, which is every home today.
  printf 'five\n' > "$dir/config/fleet-capacity"
  fm_idle_fleet_capacity "$dir/config" >/dev/null 2>&1 && status=0 || status=$?
  [ "$status" = 2 ] \
    || fail "a malformed capacity was not refused separately from an absent one (status $status)"
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
  record_task "$state" mate 'working: supervising' secondmate
  [ "$(fm_idle_fleet_in_progress "$state")" = 6 ] \
    || fail "a persistent secondmate was counted against task capacity"

  # A scout is work under way just as much as a ship: it occupies a slot until it
  # reports, and it was skipped along with everything else by the broken counter.
  record_task "$state" open-scout 'working: investigating' scout
  [ "$(fm_idle_fleet_in_progress "$state")" = 7 ] \
    || fail "a scout under way was not counted against task capacity"
  rm -f "$state/open-scout.meta" "$state/open-scout.status"

  # A later append decides, so a worker that resumes after reporting done
  # reclaims its slot rather than staying counted as free forever.
  printf 'working: follow-up fix\n' >> "$state/done-unlanded.status"
  [ "$(fm_idle_fleet_in_progress "$state")" = 7 ] \
    || fail "a concluded worker that resumed did not reclaim its slot"
  pass "in-progress counts open work only, never concluded agents or secondmates"
}

test_the_recorded_kind_vocabulary_is_pinned_and_classified() {
  local kinds
  kinds=$(fm_task_kinds)
  # A TRIPWIRE, not a style assertion. bin/fm-spawn.sh now refuses to record a
  # kind bin/fm-task-kind-lib.sh does not know, so a new kind has to be
  # registered there - and this line then reds until someone states whether it is
  # work that occupies a task slot. Without it a new kind would silently inherit
  # the exclusion default and be counted with no decision taken.
  [ "$kinds" = "ship scout secondmate" ] \
    || fail "the recorded kind vocabulary changed to '$kinds'; classify the new kind below before repinning this"

  fm_task_kind_is_work ship || fail "a ship was not counted as work"
  fm_task_kind_is_work scout || fail "a scout was not counted as work"
  fm_task_kind_is_work secondmate \
    && fail "a persistent secondmate was counted as a work item"
  # An absent kind= is how a record written before the field existed spells ship.
  fm_task_kind_is_work "" || fail "a record with no kind= was not treated as a ship"

  fm_task_kind_known "" || fail "an absent kind was not accepted as a known record"
  fm_task_kind_known ship || fail "ship was not a known kind"
  # The exact regression: `task` reads like a sensible kind and no spawn writes
  # it. The broken counter accepted it and nothing else.
  fm_task_kind_known task \
    && fail "'task' was accepted as a recorded kind; no spawn has ever written it"
  fm_task_kind_known program && fail "an unregistered kind was accepted"
  pass "the kinds a spawn records are pinned, and each one is deliberately classified"
}

test_in_progress_counts_every_kind_a_spawn_records() {
  local dir state kind expected=0 total=0
  dir=$(make_home in-progress-kinds)
  state="$dir/state"

  # Driven from bin/fm-task-kind-lib.sh - the owner bin/fm-spawn.sh validates its
  # own kind against - rather than from a list written out here. A second list
  # written out here is exactly what shipped the bug: the counter carried its own
  # pair of kinds, '' and `task`, that no spawn writes, and so counted nothing at
  # all while the alarm reported a busy fleet as stopped.
  for kind in $(fm_task_kinds); do
    record_task "$state" "rec-$kind" 'working: implementing' "$kind"
    total=$((total + 1))
    if fm_task_kind_is_work "$kind"; then
      expected=$((expected + 1))
    fi
  done

  [ "$(fm_idle_fleet_in_progress "$state")" = "$expected" ] \
    || fail "a fleet of one record per recorded kind counted $(fm_idle_fleet_in_progress "$state") in progress, not $expected"
  # Neither half of that may go vacuous: some recorded kind must be work, and
  # some must not, or the assertion above holds for a reason nobody intended.
  [ "$expected" -gt 0 ] \
    || fail "no kind a spawn records counted as work; the counter is structurally zero again"
  [ "$expected" -lt "$total" ] \
    || fail "every recorded kind counted as work; the secondmate exclusion is gone"
  pass "every kind a spawn records is counted, or deliberately not, with none silently skipped"
}

test_two_working_ships_are_counted_not_reported_as_a_stopped_fleet() {
  local dir state status
  dir=$(make_home false-positive-regression)
  state="$dir/state"

  # THE INCIDENT, as a regression test. The alarm's first live firing reported
  # `in-progress=0 capacity=1 ready=22` while two real ship tasks were under way
  # and both workers were demonstrably alive: one waiting out a CI lane, one
  # running a test family. The count carried its own kinds that no spawn writes,
  # so it could not leave zero, and `0 < 1` is permanently true - the line
  # described a stopped fleet that did not exist.
  record_task "$state" ci-waiter 'paused: waiting on the CI lane'
  record_task "$state" test-runner 'working: running the secondmate test family'
  printf '22\n' > "$dir/ready-count"

  # FIRST, the reported case EXACTLY: no config/fleet-capacity, so the effective
  # capacity is the default 1, which is the `capacity=1` the false alarm printed.
  # The counter is the whole defect and the whole fix - with it reading 2, the
  # comparison is 2 < 1, and this fleet is silent without the home configuring
  # anything. A capacity file cannot be part of the fix: no home has one, and
  # this is the state every home is in right now.
  FM_FAKE_READY_COUNT_FILE="$dir/ready-count" PATH="$dir/fakebin:$PATH" \
    fm_idle_fleet_condition "$state" "$dir/config" "$dir" && status=0 || status=$?
  [ "$status" = 1 ] \
    || fail "the reported false alarm still fires on an unconfigured home (status $status)"
  [ "$FM_IDLE_FLEET_IN_PROGRESS" = 2 ] \
    || fail "two live ship tasks were reported as $FM_IDLE_FLEET_IN_PROGRESS in progress, not 2"
  [ "$FM_IDLE_FLEET_CAPACITY" = 1 ] \
    || fail "an unconfigured home did not compare against the default capacity of 1"

  # THEN the same fleet against a stated cap, to show the count feeds a real
  # comparison rather than only ever losing it. With two of five slots busy and a
  # queue behind them the condition does hold, and firstmate dispatching into the
  # free slots is exactly what this alarm is for.
  printf '5\n' > "$dir/config/fleet-capacity"
  FM_FAKE_READY_COUNT_FILE="$dir/ready-count" PATH="$dir/fakebin:$PATH" \
    fm_idle_fleet_condition "$state" "$dir/config" "$dir" \
    || fail "two busy slots of five with 22 queued did not read as free capacity"
  [ "$FM_IDLE_FLEET_IN_PROGRESS" = 2 ] \
    || fail "two live ship tasks were reported as $FM_IDLE_FLEET_IN_PROGRESS in progress, not 2"
  [ "$FM_IDLE_FLEET_CAPACITY" = 5 ] \
    || fail "the home's stated capacity was reported as $FM_IDLE_FLEET_CAPACITY, not 5"
  [ "$FM_IDLE_FLEET_READY" = 22 ] \
    || fail "the ready queue was reported as $FM_IDLE_FLEET_READY, not 22"

  # A declared `paused:` wait is in progress, not idle. A worker waiting out a CI
  # lane or the build lock goes deliberately silent for the length of that wait,
  # so counting only actively-emitting workers would rebuild this same false
  # report by another route.
  [ "$(fm_idle_fleet_in_progress "$state")" = 2 ] \
    || fail "a declared wait was read as a free slot"

  # And that count really does feed the comparison: the same two workers against
  # a cap of two is a fleet at capacity, which must stay silent however long the
  # queue is. Without this the count above could be right and still ignored.
  printf '2\n' > "$dir/config/fleet-capacity"
  FM_FAKE_READY_COUNT_FILE="$dir/ready-count" PATH="$dir/fakebin:$PATH" \
    fm_idle_fleet_condition "$state" "$dir/config" "$dir" && status=0 || status=$?
  [ "$status" = 1 ] \
    || fail "a fleet with every slot working still raised the condition (status $status)"

  # The control on the other side: once both workers conclude, those slots are
  # free again even though nothing landed, and the condition holds.
  printf 'done: PR https://example.test/pr/1 checks green\n' >> "$state/ci-waiter.status"
  printf 'failed: pipeline gave up\n' >> "$state/test-runner.status"
  FM_FAKE_READY_COUNT_FILE="$dir/ready-count" PATH="$dir/fakebin:$PATH" \
    fm_idle_fleet_condition "$state" "$dir/config" "$dir" \
    || fail "a genuinely stopped fleet with 22 ready items did not raise the condition"
  [ "$FM_IDLE_FLEET_IN_PROGRESS" = 0 ] \
    || fail "two concluded workers still held their slots"
  pass "two workers under way are counted as two, against the capacity the home actually stated"
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
test_the_recorded_kind_vocabulary_is_pinned_and_classified
test_in_progress_counts_every_kind_a_spawn_records
test_two_working_ships_are_counted_not_reported_as_a_stopped_fleet
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
