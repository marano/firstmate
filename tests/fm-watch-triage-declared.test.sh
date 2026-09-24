#!/usr/bin/env bash
# tests/fm-watch-triage-declared.test.sh - declared pauses, wedge escalation, awaiting-landing, and declared-wait survival.
# One part of the always-on wake triage tests for bin/fm-watch.sh and the shared
# classifier (bin/fm-classify-lib.sh); shared fixtures live in
# tests/fm-watch-triage-lib.sh. Daemon-side classification/injection lives in
# fm-daemon.test.sh; watcher/lock liveness in fm-watcher-lock.test.sh; the
# durable-queue safety matrix in fm-wake-queue.test.sh.
set -u

# shellcheck source=tests/fm-watch-triage-lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/fm-watch-triage-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-watch-triage-declared-tests)
# --- declared pause CONFIRMED by an active no-mistakes run (source: run-step) -
# The 2026-09-16 fix-round incident: a crew's own no-mistakes round (`no-mistakes
# axi respond`, a live probe) is exactly one of the bounded waits `paused:` names
# (bin/fm-brief.sh's own worker-facing examples list it), yet crew_absorb_class's
# `working` verdict for that same active run used to override the declaration
# outright and resume the short wedge cadence on an idle-by-design pane - a
# worker in the middle of validating its own fix got wedge-escalated every
# ~4 minutes. pause_state_class now treats `working` as CONFIRMING the declared
# wait, not contradicting it, as long as the declaration is still the crew's last
# status line and its agent is not confirmed dead; the two tests below replace
# the old ones that pinned the opposite (buggy) behavior.
test_nonterminal_paused_confirmed_by_active_run_holds_pause_cadence() {
  local dir state fakebin out capture_file window key pane_hash sig pid
  dir=$(make_case nonterminal-paused-run-confirm); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"; window="test:fm-pause-recheck"
  printf 'idle awaiting external\n' > "$capture_file"
  printf 'window=%s\nkind=ship\nharness=grok\n' "$window" > "$state/pause-recheck.meta"
  printf 'paused: waiting on the next gate\n' > "$state/pause-recheck.status"
  sig=$(seen_sig "$state/pause-recheck.status"); printf '%s' "$sig" > "$state/.seen-pause-recheck_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "idle awaiting external")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '%s' "$pane_hash" > "$state/.stale-$key"
  printf '1\n' > "$state/.count-$key"
  : > "$state/.paused-$key"
  export FM_FAKE_CREW_STATE='state: working · source: run-step · validating (running)'

  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_FAKE_TMUX_CURRENT_COMMAND=grok \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_STALE_ESCALATE_SECS=999 FM_PAUSE_RESURFACE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  if ! wait_poll_cycle "$state" "$pid"; then
    reap "$pid"; fail "an active run confirming a declared pause was wedge-escalated: $(cat "$out")"
  fi
  reap "$pid"
  [ ! -s "$out" ] || fail "an active run confirming a declared pause printed a wake reason during absorb"
  [ -e "$state/.paused-$key" ] || fail "an active run confirming a declared pause dropped the pause marker"
  [ ! -e "$state/.stale-since-$key" ] || fail "an active run confirming a declared pause started the wedge timer"
  [ "$(cat "$state/.paused-rechecked-$key" 2>/dev/null || true)" = working ] \
    || fail "the run-step confirmation was not cached for the fast recheck path"
  unset FM_FAKE_CREW_STATE
  pass "a declared pause an active no-mistakes run confirms holds the long pause cadence instead of resuming wedge tracking"
}

test_paused_authoritative_working_holds_cadence_and_recheck_ceiling() {
  local dir state fakebin out capture_file window key pane_hash sig pid back
  dir=$(make_case paused-working-holds-cadence); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"; window="test:fm-paused-working"
  printf 'idle awaiting external\n' > "$capture_file"
  printf 'window=%s\nkind=ship\nharness=grok\n' "$window" > "$state/paused-working.meta"
  printf 'paused: waiting on the next gate\n' > "$state/paused-working.status"
  sig=$(seen_sig "$state/paused-working.status"); printf '%s' "$sig" > "$state/.seen-paused-working_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "idle awaiting external")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '%s' "$pane_hash" > "$state/.stale-$key"
  printf '1\n' > "$state/.count-$key"
  export FM_FAKE_CREW_STATE='state: working · source: run-step · validating (running)'

  # Phase A: first classification confirms the declared wait against the active
  # run and absorbs quietly - no wedge timer, no wake, repeat rechecks agree.
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_FAKE_TMUX_CURRENT_COMMAND=grok \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_STALE_ESCALATE_SECS=999 FM_PAUSE_RESURFACE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  if ! wait_poll_cycle "$state" "$pid"; then
    reap "$pid"; fail "an active run confirming a declared pause was wedge-escalated on first sight: $(cat "$out")"
  fi
  reap "$pid"
  [ ! -s "$out" ] || fail "an active run confirming a declared pause printed a wake reason"
  [ ! -e "$state/.stale-since-$key" ] || fail "the first confirmed-working round started a wedge timer"
  ack_stopped_cycle "$state" || fail "could not acknowledge the intentional phase-A stop"

  # Phase B: age the declared pause past the resurface cadence while the run is
  # STILL reported working - the ceiling on this absorb is the declared-pause
  # cadence, not the wedge threshold: it must re-surface as a recheck once, never
  # as a wedge, and must never touch the wedge timer to get there.
  back=$(( $(date +%s) - 500 ))
  if [ "$(uname)" = Darwin ]; then touch -mt "$(date -r "$back" '+%Y%m%d%H%M.%S')" "$state/paused-working.status"
  else touch -m -d "@$back" "$state/paused-working.status"; fi
  sig=$(seen_sig "$state/paused-working.status"); printf '%s' "$sig" > "$state/.seen-paused-working_status"
  : > "$out"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_FAKE_TMUX_CURRENT_COMMAND=grok \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_STALE_ESCALATE_SECS=240 FM_PAUSE_RESURFACE_SECS=240 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 100 || { reap "$pid"; fail "an active run confirming a declared pause was never rechecked past the cadence"; }
  grep -F "awaiting external" "$out" >/dev/null || fail "the recheck was not labeled a declared-pause recheck: $(cat "$out")"
  grep -F "possible wedge" "$out" >/dev/null && fail "an active run confirming a declared pause was mislabeled a possible wedge: $(cat "$out")"
  [ ! -e "$state/.stale-since-$key" ] || fail "the declared-pause recheck used the wedge timer"
  unset FM_FAKE_CREW_STATE
  pass "a declared pause an active run confirms holds the pause cadence and re-arms past PAUSE_RESURFACE_SECS as a recheck, never a wedge"
}

# The safety property a confirming run must not weaken: if the crew's own AGENT
# is confirmed dead, an active run RECORD (the daemon's own bookkeeping,
# independent of the worker's harness process) must not be trusted as evidence
# the declared wait still holds - it still wedge-escalates on the ordinary short
# cadence, exactly as an undeclared provably-working stale does.
test_paused_run_step_working_dead_agent_still_wedge_escalates() {
  local dir state fakebin out capture_file window key pane_hash sig pid
  dir=$(make_case paused-run-step-dead-agent); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"; window="test:fm-paused-dead"
  printf 'idle after agent exit\n' > "$capture_file"
  printf 'window=%s\nkind=ship\nharness=grok\n' "$window" > "$state/paused-dead.meta"
  printf 'paused: waiting on the next gate\n' > "$state/paused-dead.status"
  sig=$(seen_sig "$state/paused-dead.status"); printf '%s' "$sig" > "$state/.seen-paused-dead_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "idle after agent exit")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '%s' "$pane_hash" > "$state/.stale-$key"
  printf '1\n' > "$state/.count-$key"
  export FM_FAKE_CREW_STATE='state: working · source: run-step · validating (running)'

  # Priming round: first classification, agent confirmed dead despite the "still
  # validating" run record, so the ordinary working/wedge path is taken.
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_FAKE_TMUX_CURRENT_COMMAND=zsh \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_STALE_ESCALATE_SECS=999 FM_PAUSE_RESURFACE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  if ! wait_poll_cycle "$state" "$pid"; then
    reap "$pid"; fail "priming round for a dead agent behind a declared pause failed: $(cat "$out")"
  fi
  reap "$pid"
  [ ! -e "$state/.paused-$key" ] || fail "a dead agent behind a run-step-working pause was given the pause cadence"
  [ -s "$state/.stale-since-$key" ] || fail "a dead agent behind a run-step-working pause did not start wedge tracking"
  ack_stopped_cycle "$state" || fail "could not acknowledge the priming stop"

  echo $(( $(date +%s) - 500 )) > "$state/.stale-since-$key"
  : > "$out"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_FAKE_TMUX_CURRENT_COMMAND=zsh \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_STALE_ESCALATE_SECS=240 FM_PAUSE_RESURFACE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 100 || fail "a dead agent behind a declared pause with an active run record did not eventually wake firstmate"
  grep -F "possible wedge" "$out" >/dev/null || fail "a dead agent behind a run-step-working pause did not wedge-escalate: $(cat "$out")"
  unset FM_FAKE_CREW_STATE
  pass "a dead agent behind a declared pause still wedge-escalates even while the run record reads working"
}

# --- consecutive wedge escalations on the same pane demand deep inspection ----
# Root cause of the PR #252 incident's ~20 minutes of unnoticed green: each
# wedge escalation fires, gets classified as "still validating" one poll later
# (the timer restarts, see wedge_timer_check), and repeats forever on a pane
# that never changes. A single escalation reason looks identical every round,
# so nothing in the payload itself signals "this has now happened N times in a
# row" - that judgment call was left entirely to the supervisor noticing the
# repetition on its own. This is the safety-net fix: past
# FM_WEDGE_DEMAND_INSPECT_COUNT consecutive escalations on the SAME pane, the
# wake reason itself carries a "demand-deep-inspection" marker.

test_wedge_escalation_marks_demand_deep_inspection_after_threshold() {
  local dir state fakebin out capture_file window key pane_hash sig pid n
  dir=$(make_case wedge-escalation); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"
  window="test:fm-wedged"
  printf 'idle building output' > "$capture_file"
  printf 'window=%s\nkind=ship\n' "$window" > "$state/wedged.meta"
  printf 'working: still monitoring ci\n' > "$state/wedged.status"
  sig=$(seen_sig "$state/wedged.status"); printf '%s' "$sig" > "$state/.seen-wedged_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "idle building output")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  # The crew's pipeline is actively running: a static pane is normal (waiting on CI).
  export FM_FAKE_CREW_STATE='state: working · source: run-step · validating (running)'

  # Priming round: first sighting of this stale hash classifies and absorbs it
  # (establishing .stale-$key and starting the wedge timer) without going
  # through wedge_timer_check at all - mirrors the existing wedge tests' Phase A.
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  if ! wait_poll_cycle "$state" "$pid"; then
    reap "$pid"; fail "watcher exited on the priming round (should absorb): $(cat "$out")"
  fi
  reap "$pid"
  ack_stopped_cycle "$state" || fail "could not acknowledge the intentional wedge priming stop"

  n=1
  while [ "$n" -le 3 ]; do
    # Backdate the wedge timer past the threshold before each round, mirroring
    # the existing wedge-escalation tests' Phase B (the subsequent-sight timer
    # path does not re-read the crew state).
    echo $(( $(date +%s) - 500 )) > "$state/.stale-since-$key"
    : > "$out"
    PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
      FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=240 FM_POLL=1 FM_SIGNAL_GRACE=1 \
      FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
    pid=$!
    wait_for_exit "$pid" 100 || fail "watcher did not escalate on consecutive wedge round $n: $(cat "$out")"
    grep -F "escalation $n" "$out" >/dev/null || fail "round $n did not report escalation count $n: $(cat "$out")"
    if [ "$n" -lt 3 ]; then
      grep -F "demand-deep-inspection" "$out" >/dev/null && fail "round $n escalated to demand-deep-inspection before the threshold: $(cat "$out")"
    else
      grep -F "demand-deep-inspection" "$out" >/dev/null || fail "round $n (threshold) did not demand deep inspection: $(cat "$out")"
    fi
    ack_stopped_cycle "$state" || fail "could not acknowledge wedge escalation round $n"
    n=$((n + 1))
  done
  [ "$(cat "$state/.wedge-escalations-$key" 2>/dev/null || echo 0)" = 3 ] || fail "escalation counter did not persist across consecutive rounds"
  unset FM_FAKE_CREW_STATE
  pass "consecutive wedge escalations on the same pane accumulate and demand deep inspection at the threshold"
}

test_wedge_escalation_resets_when_pane_becomes_active() {
  local dir state fakebin out capture_file window key pane_hash sig pid
  dir=$(make_case wedge-escalation-reset); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"
  window="test:fm-wedged-reset"
  printf 'idle building output' > "$capture_file"
  printf 'window=%s\nkind=ship\n' "$window" > "$state/wedged-reset.meta"
  printf 'working: still monitoring ci\n' > "$state/wedged-reset.status"
  sig=$(seen_sig "$state/wedged-reset.status"); printf '%s' "$sig" > "$state/.seen-wedged-reset_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "idle building output")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  # Pre-seed one escalation as if a prior wedge round already fired.
  printf '1\n' > "$state/.wedge-escalations-$key"
  export FM_FAKE_CREW_STATE='state: working · source: run-step · validating (running)'

  # The pane content changes (the crew is active again): the hash no longer
  # matches, so the watcher resets escalation bookkeeping instead of escalating.
  printf 'new output, crew active again' > "$capture_file"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=240 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  if ! wait_poll_cycle "$state" "$pid"; then
    reap "$pid"; fail "watcher exited on a fresh (changed) pane hash: $(cat "$out")"
  fi
  [ ! -e "$state/.wedge-escalations-$key" ] || fail "a changed pane hash did not reset the wedge-escalation counter"
  reap "$pid"
  unset FM_FAKE_CREW_STATE
  pass "a pane becoming active again resets the consecutive wedge-escalation counter"
}

# --- awaiting landing: the stale path reads bin/fm-awaiting-landing-lib.sh ---
# Finished work firstmate is holding for landing sits on a quiet pane by design.
# 2026-09-17 measured two false alarms on exactly that state: an agent firstmate
# stopped deliberately to free its slot was stale-alarmed and then climbed the
# wedge ladder ("possible wedge, escalation 1"), and a done task with its PR
# recorded was stale-alarmed while its agent sat alive and idle. The watcher now
# asks the one owner of that state instead of inferring it. The three tests below
# pin what that buys and what it must never cost: no alarm, no place on the wedge
# ladder, and a real wedge that is NOT awaiting landing still alarming and
# escalating. The state is decided by the real owner over real records - the
# status log, the metadata, the stop record, and a real git worktree wherever a
# landing target is verified - never by a stub.

# A stale-ready task: its pane already seen once, so the first poll enters stale
# triage, and its status log already marked surfaced, so the signal path cannot
# pre-empt the stale path under test. Prints the window's marker key.
landing_stale_task() {  # <state> <id> <window> <capture-file> <pane-text> <status-line> [meta key=value ...]
  local state=$1 id=$2 window=$3 capture=$4 pane=$5 line=$6 key
  shift 6
  printf '%s' "$pane" > "$capture"
  fm_write_meta "$state/$id.meta" "window=$window" "kind=ship" "$@"
  printf '%s\n' "$line" > "$state/$id.status"
  printf '%s' "$(seen_sig "$state/$id.status")" > "$state/.seen-${id}_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  printf '%s' "$(hash_text "$pane")" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  printf '%s' "$key"
}

# The record bin/fm-control.sh `exit` writes when firstmate stops an agent on purpose.
landing_stop_agent() {  # <state> <id>
  printf 'stopped_at=2026-09-17T02:00:00Z\nverb=exit\nresult=stopped\n' > "$1/$2.agent-stopped"
}

landing_watch() {  # <state> <fakebin> <out> <window> <capture-file> [env assignment...]
  local state=$1 fakebin=$2 out=$3 window=$4 capture=$5
  shift 5
  : > "$out"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_POLL=1 \
    FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 env "$@" "$WATCH" > "$out" &
}

# Hold <pid>'s watcher to <cycles> whole poll cycles over an awaiting-landing task:
# it must wake nothing, and its escalation counter must read zero after every one.
# A watcher that exits early is reported by the counter first, because a climbed
# counter is exactly the ladder entry the task was never eligible for. Reaps <pid>.
landing_assert_quiet() {  # <state> <pid> <out> <key> <cycles> <label>
  local state=$1 pid=$2 out=$3 key=$4 cycles=$5 label=$6 i=0 count
  while [ "$i" -lt "$cycles" ]; do
    if ! wait_poll_cycle "$state" "$pid"; then
      reap "$pid"
      count=$(cat "$state/.wedge-escalations-$key" 2>/dev/null || echo 0)
      [ "$count" = 0 ] || fail "$label: the escalation counter climbed to $count - it entered the wedge ladder: $(cat "$out")"
      fail "$label: raised a stale alarm instead of staying quiet: $(cat "$out")"
    fi
    count=$(cat "$state/.wedge-escalations-$key" 2>/dev/null || echo 0)
    [ "$count" = 0 ] || { reap "$pid"; fail "$label: the escalation counter climbed to $count"; }
    i=$((i + 1))
  done
  reap "$pid"
  [ ! -s "$out" ] || fail "$label: printed a wake reason: $(cat "$out")"
  [ ! -s "$state/.wake-queue" ] || fail "$label: queued a wake"
}

test_awaiting_landing_raises_no_stale_alarm() {
  local dir state fakebin out capture window key pid head
  # The fake crew state reads unknown - not provably working - so any pane this
  # reaches stale triage with is surfaced at once. Each leg closes with its own
  # control: remove only the acknowledgement and the same pane must alarm, which
  # proves the quiet came from the owner's answer and not from an unreached path.

  # Leg 1: the agent stopped deliberately to free its slot, leaving only a shell.
  dir=$(make_case awaiting-landing-stopped); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture="$dir/pane.txt"; window="test:fm-landed-stopped"
  key=$(landing_stale_task "$state" landed-stopped "$window" "$capture" 'fm-landed-stopped $' \
    'done: work complete, ready to land' "worktree=$dir/wt")
  landing_stop_agent "$state" landed-stopped
  landing_watch "$state" "$fakebin" "$out" "$window" "$capture" FM_FAKE_TMUX_CURRENT_COMMAND=zsh
  pid=$!
  landing_assert_quiet "$state" "$pid" "$out" "$key" 3 "a deliberately stopped task awaiting landing"
  ack_stopped_cycle "$state" || fail "could not acknowledge the stopped leg's intentional watcher stop"
  rm -f "$state/landed-stopped.agent-stopped"
  landing_watch "$state" "$fakebin" "$out" "$window" "$capture" FM_FAKE_TMUX_CURRENT_COMMAND=zsh
  pid=$!
  wait_for_exit "$pid" 100 || { reap "$pid"; fail "control: the same stopped pane without its stop record did not alarm"; }
  grep -Fx "stale: $window" "$out" >/dev/null || fail "control: the unacknowledged stopped pane printed the wrong wake: $(cat "$out")"

  # Leg 2: the PR is recorded and holds this branch's real head, and the agent is
  # alive and idle at its prompt.
  dir=$(make_case awaiting-landing-alive); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture="$dir/pane.txt"; window="test:fm-landed-alive"
  fm_git_worktree "$dir/repo" "$dir/wt" fm/landed-alive >/dev/null 2>&1 || fail "could not build the alive leg's worktree"
  head=$(git -C "$dir/wt" rev-parse HEAD)
  key=$(landing_stale_task "$state" landed-alive "$window" "$capture" '> waiting for your next message' \
    'done: PR https://example.test/pr/23 checks green run=r23' "worktree=$dir/wt" \
    'pr=https://example.test/pr/23' "pr_head=$head")
  landing_watch "$state" "$fakebin" "$out" "$window" "$capture" FM_FAKE_TMUX_CURRENT_COMMAND=claude
  pid=$!
  landing_assert_quiet "$state" "$pid" "$out" "$key" 3 "an idle live task awaiting landing"
  ack_stopped_cycle "$state" || fail "could not acknowledge the alive leg's intentional watcher stop"
  fm_write_meta "$state/landed-alive.meta" "window=$window" "kind=ship" "worktree=$dir/wt"
  landing_watch "$state" "$fakebin" "$out" "$window" "$capture" FM_FAKE_TMUX_CURRENT_COMMAND=claude
  pid=$!
  wait_for_exit "$pid" 100 || { reap "$pid"; fail "control: the same idle pane with no PR recorded did not alarm"; }
  grep -Fx "stale: $window" "$out" >/dev/null || fail "control: the unacknowledged idle pane printed the wrong wake: $(cat "$out")"
  pass "a task awaiting landing raises no stale alarm, stopped or alive, while the same pane unacknowledged still does"
}

test_awaiting_landing_never_enters_the_wedge_ladder() {
  local dir state fakebin out capture window key pid since
  # The run step reads working - the orphaned CI monitor behind the measured
  # "possible wedge, escalation 1" - which is what lets a quiet pane be absorbed
  # as provably working and timed toward escalation. The threshold is 1s, so any
  # read that lets this task onto the ladder escalates within a poll or two.
  export FM_FAKE_CREW_STATE='state: working · source: run-step · ci running'

  # Leg 1, the idle entrance. The position is seeded as already held and long
  # overdue - classified and timed before the hold was recorded - so a task that
  # is merely left where it stood escalates on the very first poll.
  dir=$(make_case awaiting-landing-ladder-idle); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture="$dir/pane.txt"; window="test:fm-landed-idle"
  key=$(landing_stale_task "$state" landed-idle "$window" "$capture" 'fm-landed-idle $' \
    'done: PR https://example.test/pr/24 checks green run=r24' "worktree=$dir/wt" \
    'pr=https://example.test/pr/24')
  landing_stop_agent "$state" landed-idle
  cp "$state/.hash-$key" "$state/.stale-$key"
  echo $(( $(date +%s) - 500 )) > "$state/.stale-since-$key"
  landing_watch "$state" "$fakebin" "$out" "$window" "$capture" \
    FM_STALE_ESCALATE_SECS=1 FM_FAKE_TMUX_CURRENT_COMMAND=zsh
  pid=$!
  landing_assert_quiet "$state" "$pid" "$out" "$key" 3 "a stopped task awaiting landing"
  [ ! -e "$state/.stale-since-$key" ] || fail "a task awaiting landing still holds a wedge timer on the ladder"
  ack_stopped_cycle "$state" || fail "could not acknowledge the idle leg's intentional watcher stop"

  # Leaving the state starts afresh. Firstmate relaunches the agent for review
  # feedback, which drops the stop record, and it reports working: the next
  # classification must open a NEW wedge timer rather than resume the one that
  # measured legitimately quiet time.
  rm -f "$state/landed-idle.agent-stopped"
  printf 'working: addressing review feedback\n' >> "$state/landed-idle.status"
  printf '%s' "$(seen_sig "$state/landed-idle.status")" > "$state/.seen-landed-idle_status"
  landing_watch "$state" "$fakebin" "$out" "$window" "$capture" \
    FM_STALE_ESCALATE_SECS=240 FM_FAKE_TMUX_CURRENT_COMMAND=claude
  pid=$!
  landing_assert_quiet "$state" "$pid" "$out" "$key" 2 "a task that just left awaiting landing"
  since=$(cat "$state/.stale-since-$key" 2>/dev/null || true)
  case "$since" in ''|*[!0-9]*) fail "a task that left awaiting landing was not timed afresh: '$since'" ;; esac
  [ $(( $(date +%s) - since )) -lt 240 ] || fail "a task that left awaiting landing resumed its old wedge timer"
  ack_stopped_cycle "$state" || fail "could not acknowledge the exit leg's intentional watcher stop"

  # Leg 2, the busy entrance. A busy pane past the completed-turn bound is the
  # ladder's other door (busy_turn_bound_check).
  dir=$(make_case awaiting-landing-ladder-busy); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture="$dir/pane.txt"; window="test:fm-landed-busy"
  key=$(landing_stale_task "$state" landed-busy "$window" "$capture" 'Working... (3600.1s)' \
    'done: PR https://example.test/pr/25 checks green run=r25' "harness=pi" "worktree=$dir/wt" \
    'pr=https://example.test/pr/25')
  record_pi_busy "$state" landed-busy
  touch -t 200001010000 "$state/landed-busy.meta"
  landing_watch "$state" "$fakebin" "$out" "$window" "$capture" \
    FM_BUSY_TURN_MAX_SECS=1 FM_STALE_ESCALATE_SECS=1
  pid=$!
  landing_assert_quiet "$state" "$pid" "$out" "$key" 4 "a busy task awaiting landing past the turn bound"
  [ ! -e "$state/.stale-since-$key" ] || fail "a busy task awaiting landing was timed toward a wedge"
  unset FM_FAKE_CREW_STATE
  pass "a task awaiting landing never enters the wedge ladder: its escalation counter stays at zero through both entrances"
}

# Run one watcher over a stale-ready task whose run step reads working, with a 1s
# wedge threshold, and require it to alarm with the ladder climbed to <n>.
landing_expect_escalation() {  # <state> <fakebin> <out> <window> <capture-file> <key> <n> <label>
  local state=$1 fakebin=$2 out=$3 window=$4 capture=$5 key=$6 n=$7 label=$8 pid
  landing_watch "$state" "$fakebin" "$out" "$window" "$capture" FM_STALE_ESCALATE_SECS=1
  pid=$!
  wait_for_exit "$pid" 100 || { reap "$pid"; fail "$label: never alarmed"; }
  grep -F "stale: $window (idle " "$out" | grep -F "possible wedge, escalation $n" >/dev/null \
    || fail "$label: did not alarm as a possible wedge at escalation $n: $(cat "$out")"
  [ "$(cat "$state/.wedge-escalations-$key" 2>/dev/null || echo 0)" = "$n" ] \
    || fail "$label: the escalation counter did not climb to $n"
  ack_stopped_cycle "$state" || fail "$label: could not acknowledge the escalation"
}

test_wedged_task_not_awaiting_landing_still_alarms_and_escalates() {
  local dir state fakebin out capture window key head
  # THE REFUSAL: quiet is licensed only by the owner's answer, so every task it
  # does not call awaiting landing keeps the whole ladder - including near misses
  # that carry some of the same records.
  export FM_FAKE_CREW_STATE='state: working · source: run-step · validating (running)'

  # A genuine wedge: work still open, pane frozen. It alarms, then climbs again.
  dir=$(make_case landing-refusal-wedged); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture="$dir/pane.txt"; window="test:fm-wedged-open"
  key=$(landing_stale_task "$state" wedged-open "$window" "$capture" 'idle building output' \
    'working: still monitoring ci')
  landing_expect_escalation "$state" "$fakebin" "$out" "$window" "$capture" "$key" 1 "a genuinely wedged task"
  landing_expect_escalation "$state" "$fakebin" "$out" "$window" "$capture" "$key" 2 "a genuinely wedged task, again"

  # Stopped deliberately with a PR recorded, but its work still open: neither the
  # stop record nor the PR licenses quiet on its own.
  dir=$(make_case landing-refusal-stopped-open); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture="$dir/pane.txt"; window="test:fm-stopped-open"
  key=$(landing_stale_task "$state" stopped-open "$window" "$capture" 'fm-stopped-open $' \
    'working: rebasing onto main' 'pr=https://example.test/pr/26')
  landing_stop_agent "$state" stopped-open
  landing_expect_escalation "$state" "$fakebin" "$out" "$window" "$capture" "$key" 1 "a task stopped with its work open"

  # Reported done, but nothing records that firstmate took it in hand.
  dir=$(make_case landing-refusal-unacknowledged); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture="$dir/pane.txt"; window="test:fm-done-unacked"
  key=$(landing_stale_task "$state" done-unacked "$window" "$capture" 'idle after the report' \
    'done: PR https://example.test/pr/27 checks green run=r27')
  landing_expect_escalation "$state" "$fakebin" "$out" "$window" "$capture" "$key" 1 "an unacknowledged done task"

  # Done and held, but the branch moved past the head its PR records: landing is
  # blocked, which the owner reports as not quiet.
  dir=$(make_case landing-refusal-blocked); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture="$dir/pane.txt"; window="test:fm-landing-blocked"
  fm_git_worktree "$dir/repo" "$dir/wt" fm/landing-blocked >/dev/null 2>&1 || fail "could not build the blocked leg's worktree"
  head=$(git -C "$dir/wt" rev-parse HEAD)
  git -C "$dir/wt" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' \
    commit -q --allow-empty -m 'never pushed' || fail "could not advance the blocked leg's branch"
  key=$(landing_stale_task "$state" landing-blocked "$window" "$capture" 'idle after the push' \
    'done: PR https://example.test/pr/28 checks green run=r28' "worktree=$dir/wt" \
    'pr=https://example.test/pr/28' "pr_head=$head")
  landing_expect_escalation "$state" "$fakebin" "$out" "$window" "$capture" "$key" 1 "a done task whose landing is blocked"
  unset FM_FAKE_CREW_STATE
  pass "a wedged task that is not awaiting landing still alarms and still escalates, near misses included"
}

# THE 2026-09-21 false alarms. A no-mistakes ship ends with its PR head AHEAD of
# the worker's local branch (the pipeline pushes its own fix commits), and firstmate
# stops the finished worker's agent. That task alarmed with a bare "stale: <window>"
# because the landing owner called the ahead head landing-blocked. Both directions
# are proven over a real worktree, a real stop record and a real validation
# receipt: a validated ahead head with a dead endpoint raises NO stale wake, while
# the same task with an unvouched ahead head, or a behind head, STILL does - and the
# alarm that fires leaves a triage-log line naming the landing class that decided it.
landing_ahead_task() {  # <dir> <id> <pr-number> <receipt: yes|no> <shape: ahead|behind|rebased|gate-rebased> -> key
  local case_dir=$1 task_id=$2 num=$3 receipt=$4 shape=$5 base pr_head
  local state_dir="$case_dir/state" win="test:fm-$task_id"
  fm_git_worktree "$case_dir/repo" "$case_dir/wt" "fm/$task_id" >/dev/null 2>&1 \
    || fail "could not build $task_id's worktree"
  base=$(git -C "$case_dir/wt" rev-parse HEAD)
  if [ "$shape" = rebased ]; then
    pr_head=$(landing_rebased_head "$case_dir/wt" "fm/$task_id") || fail "could not rebase $task_id's branch"
  elif [ "$shape" = gate-rebased ]; then
    pr_head=$(landing_gate_rebased_head "$case_dir" "fm/$task_id") || fail "could not rebase $task_id's branch in its gate"
  else
    git -C "$case_dir/wt" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' \
      commit -q --allow-empty -m 'no-mistakes(review): a pipeline fix commit' || fail "could not commit for $task_id"
    pr_head=$(git -C "$case_dir/wt" rev-parse HEAD)
  fi
  if [ "$shape" = ahead ]; then
    git -C "$case_dir/wt" reset --hard -q "$base"
  elif [ "$shape" = behind ]; then
    pr_head=$base
  fi
  if [ "$receipt" = yes ]; then
    ( . "$ROOT/bin/fm-validation-receipt-lib.sh"
      fm_validation_receipt_write "$state_dir" "$task_id" github github.com o/r "$num" "$pr_head" "fm/$task_id" 01RUNRUNRUNRUNRUNRUNRUNRUN ) \
      || fail "could not write $task_id's validation receipt"
  fi
  landing_stale_task "$state_dir" "$task_id" "$win" "$case_dir/pane.txt" "fm-$task_id \$" \
    "done: PR https://github.com/o/r/pull/$num checks green run=r$num" "worktree=$case_dir/wt" \
    "pr=https://github.com/o/r/pull/$num" "pr_head=$pr_head"
  landing_stop_agent "$state_dir" "$task_id"
}

# The worker commits its work, the base branch moves on, and the pipeline's rebase
# step replays the work onto the new base and adds a fix commit, leaving the
# worker's branch where it was. Prints the rebased PR head, which neither
# contains nor is contained by the branch head.
landing_rebased_head() {  # <worktree> <branch>
  local wt=$1 branch=$2 base work pr_head
  local -a rebase_git_id=(-c user.name='Firstmate Tests' -c user.email='tests@example.invalid')
  base=$(git -C "$wt" rev-parse HEAD)
  printf 'the work\n' > "$wt/work.txt"
  git -C "$wt" add work.txt && git -C "$wt" "${rebase_git_id[@]}" commit -qm "the worker's commit" || return 1
  work=$(git -C "$wt" rev-parse HEAD)
  git -C "$wt" checkout -q --detach "$base" || return 1
  printf 'the base moved on\n' > "$wt/base.txt"
  git -C "$wt" add base.txt && git -C "$wt" "${rebase_git_id[@]}" commit -qm 'the base branch moved on' || return 1
  git -C "$wt" "${rebase_git_id[@]}" cherry-pick "$work" > /dev/null || return 1
  git -C "$wt" "${rebase_git_id[@]}" commit -q --allow-empty -m 'no-mistakes(review): a pipeline fix commit' || return 1
  pr_head=$(git -C "$wt" rev-parse HEAD)
  git -C "$wt" checkout -q "$branch" || return 1
  if git -C "$wt" merge-base --is-ancestor "$work" "$pr_head" || git -C "$wt" merge-base --is-ancestor "$pr_head" "$work"; then
    return 1
  fi
  printf '%s' "$pr_head"
}

# The same rebase, made where the pipeline makes it: in a worktree of its gate, a
# bare repository on this machine that the worker's copy names as its
# `no-mistakes` remote. The copy is left without the rebased head, which is the
# measured shape, and a fixture that leaked the head into the copy fails rather
# than proving the same-repository case over again. Prints the rebased PR head.
landing_gate_rebased_head() {  # <case-dir> <branch>
  local case_dir=$1 branch=$2 wt=$1/wt gate=$1/gate.git gate_wt=$1/gate-wt base work pr_head
  local -a gate_git_id=(-c user.name='Firstmate Tests' -c user.email='tests@example.invalid')
  base=$(git -C "$wt" rev-parse HEAD)
  printf 'the work\n' > "$wt/work.txt"
  git -C "$wt" add work.txt && git -C "$wt" "${gate_git_id[@]}" commit -qm "the worker's commit" || return 1
  work=$(git -C "$wt" rev-parse HEAD)
  git clone --quiet --bare "$case_dir/repo" "$gate" || return 1
  git -C "$case_dir/repo" remote add no-mistakes "$gate" || return 1
  git -C "$gate" worktree add -q --detach "$gate_wt" "$base" 2>/dev/null || return 1
  printf 'the base moved on\n' > "$gate_wt/base.txt"
  git -C "$gate_wt" add base.txt && git -C "$gate_wt" "${gate_git_id[@]}" commit -qm 'the base branch moved on' || return 1
  git -C "$gate_wt" "${gate_git_id[@]}" cherry-pick "$work" > /dev/null || return 1
  git -C "$gate_wt" "${gate_git_id[@]}" commit -q --allow-empty -m 'no-mistakes(review): a pipeline fix commit' || return 1
  pr_head=$(git -C "$gate_wt" rev-parse HEAD)
  [ "$(git -C "$wt" symbolic-ref --short HEAD)" = "$branch" ] || return 1
  if git -C "$wt" cat-file -e "$pr_head^{commit}" 2>/dev/null; then
    return 1
  fi
  printf '%s' "$pr_head"
}

test_validated_ahead_pr_head_on_a_stopped_worker_is_quiet_and_others_alarm() {
  local dir state fakebin out capture window key pid
  # QUIET: validated ahead head, agent stopped, dead endpoint (a bare shell).
  dir=$(make_case landing-ahead-quiet); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture="$dir/pane.txt"; window="test:fm-ahead-ok"
  key=$(landing_ahead_task "$dir" ahead-ok 41 yes ahead)
  landing_watch "$state" "$fakebin" "$out" "$window" "$capture" FM_FAKE_TMUX_CURRENT_COMMAND=zsh
  pid=$!
  landing_assert_quiet "$state" "$pid" "$out" "$key" 3 "a stopped worker whose PR head is validated and ahead of its branch"

  # LOUD 1: the same task with no receipt vouching for the ahead head.
  dir=$(make_case landing-ahead-unvouched); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture="$dir/pane.txt"; window="test:fm-ahead-unvouched"
  key=$(landing_ahead_task "$dir" ahead-unvouched 42 no ahead)
  landing_watch "$state" "$fakebin" "$out" "$window" "$capture" FM_FAKE_TMUX_CURRENT_COMMAND=zsh
  pid=$!
  wait_for_exit "$pid" 100 || { reap "$pid"; fail "an unvouched ahead head on a stopped worker never alarmed"; }
  grep -Fx "stale: $window" "$out" >/dev/null || fail "the unvouched ahead head printed the wrong wake: $(cat "$out")"
  grep -F "surfaced stale" "$state/.watch-triage.log" | grep -F "landing=landing-blocked" | grep -F "$window" >/dev/null \
    || fail "the alarm that fired left no triage-log line naming the landing class: $(cat "$state/.watch-triage.log" 2>/dev/null)"
  ack_stopped_cycle "$state" || fail "could not acknowledge the unvouched leg's watcher stop"

  # LOUD 2: a validated head the branch has advanced PAST (unpushed local work).
  dir=$(make_case landing-behind-validated); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture="$dir/pane.txt"; window="test:fm-behind-validated"
  key=$(landing_ahead_task "$dir" behind-validated 43 yes behind)
  git -C "$dir/wt" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' \
    commit -q --allow-empty -m 'never pushed' || fail "could not advance the behind leg's branch"
  landing_watch "$state" "$fakebin" "$out" "$window" "$capture" FM_FAKE_TMUX_CURRENT_COMMAND=zsh
  pid=$!
  wait_for_exit "$pid" 100 || { reap "$pid"; fail "a validated head the branch advanced past never alarmed"; }
  grep -Fx "stale: $window" "$out" >/dev/null || fail "the behind head printed the wrong wake: $(cat "$out")"
  ack_stopped_cycle "$state" || fail "could not acknowledge the behind leg's watcher stop"
  pass "a validated ahead head on a stopped worker raises no stale wake; an unvouched or behind head still does, with a log line"
}

# THE 2026-09-23 false alarms. The base branch moved while each ship validated,
# so the pipeline's rebase step replayed the worker's commits onto the new base
# before pushing, and the PR head was neither ahead nor behind the local branch.
# Two workers stopped with their PRs green and open alarmed with a bare
# "stale: <window>" as landing-blocked, within minutes of the stop. A validated
# rebased head on a stopped worker raises NO stale wake, while the same records
# without the receipt, and a genuinely wedged worker - no stop record, work still
# open - behind those very records, STILL do.
test_validated_rebased_pr_head_on_a_stopped_worker_is_quiet_and_a_wedge_alarms() {
  local dir state fakebin out capture window key pid
  # QUIET: validated rebased head, agent stopped, dead endpoint (a bare shell).
  dir=$(make_case landing-rebased-quiet); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture="$dir/pane.txt"; window="test:fm-rebased-ok"
  key=$(landing_ahead_task "$dir" rebased-ok 44 yes rebased)
  landing_watch "$state" "$fakebin" "$out" "$window" "$capture" FM_FAKE_TMUX_CURRENT_COMMAND=zsh
  pid=$!
  landing_assert_quiet "$state" "$pid" "$out" "$key" 3 "a stopped worker whose PR head the pipeline validated after rebasing it"

  # LOUD 1: the same task with no receipt vouching for the rebased head.
  dir=$(make_case landing-rebased-unvouched); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture="$dir/pane.txt"; window="test:fm-rebased-unvouched"
  key=$(landing_ahead_task "$dir" rebased-unvouched 45 no rebased)
  landing_watch "$state" "$fakebin" "$out" "$window" "$capture" FM_FAKE_TMUX_CURRENT_COMMAND=zsh
  pid=$!
  wait_for_exit "$pid" 100 || { reap "$pid"; fail "an unvouched rebased head on a stopped worker never alarmed"; }
  grep -Fx "stale: $window" "$out" >/dev/null || fail "the unvouched rebased head printed the wrong wake: $(cat "$out")"
  grep -F "surfaced stale" "$state/.watch-triage.log" | grep -F "landing=landing-blocked" | grep -F "$window" >/dev/null \
    || fail "the unvouched rebased alarm left no triage-log line naming the landing class: $(cat "$state/.watch-triage.log" 2>/dev/null)"
  ack_stopped_cycle "$state" || fail "could not acknowledge the unvouched rebased leg's watcher stop"

  # LOUD 2: a genuine wedge behind the same validated records - no stop record,
  # and the worker's last word is open work, not done.
  dir=$(make_case landing-rebased-wedged); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture="$dir/pane.txt"; window="test:fm-rebased-wedged"
  key=$(landing_ahead_task "$dir" rebased-wedged 46 yes rebased)
  rm -f "$state/rebased-wedged.agent-stopped"
  printf 'working: still addressing review feedback\n' > "$state/rebased-wedged.status"
  printf '%s' "$(seen_sig "$state/rebased-wedged.status")" > "$state/.seen-rebased-wedged_status"
  landing_watch "$state" "$fakebin" "$out" "$window" "$capture" FM_FAKE_TMUX_CURRENT_COMMAND=zsh
  pid=$!
  wait_for_exit "$pid" 100 || { reap "$pid"; fail "a wedged worker behind a validated rebased head never alarmed"; }
  grep -Fx "stale: $window" "$out" >/dev/null || fail "the wedged worker printed the wrong wake: $(cat "$out")"
  ack_stopped_cycle "$state" || fail "could not acknowledge the wedged leg's watcher stop"
  pass "a validated rebased head on a stopped worker raises no stale wake; an unvouched one and a real wedge still do"
}

# THE 2026-09-23 10:37 false alarm, in the shape it was measured. After the fix
# above had merged, a stopped worker whose PR head was a validated pipeline
# rebase of its branch still alarmed "stale (terminal status;
# landing=landing-blocked - ... the commits were rewritten ...)": the pipeline
# made that head in its own gate repository and pushed it to the forge from
# there, and the worker's copy fetched it only later. The same records over a
# head only the gate holds raise NO stale wake, while the same records without
# the receipt STILL do.
test_validated_pr_head_only_the_gate_holds_on_a_stopped_worker_is_quiet() {
  local dir state fakebin out capture window key pid
  dir=$(make_case landing-gate-quiet); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture="$dir/pane.txt"; window="test:fm-gate-ok"
  key=$(landing_ahead_task "$dir" gate-ok 47 yes gate-rebased)
  landing_watch "$state" "$fakebin" "$out" "$window" "$capture" FM_FAKE_TMUX_CURRENT_COMMAND=zsh
  pid=$!
  landing_assert_quiet "$state" "$pid" "$out" "$key" 3 "a stopped worker whose validated PR head only the pipeline's gate holds"

  dir=$(make_case landing-gate-unvouched); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture="$dir/pane.txt"; window="test:fm-gate-unvouched"
  key=$(landing_ahead_task "$dir" gate-unvouched 48 no gate-rebased)
  landing_watch "$state" "$fakebin" "$out" "$window" "$capture" FM_FAKE_TMUX_CURRENT_COMMAND=zsh
  pid=$!
  wait_for_exit "$pid" 100 || { reap "$pid"; fail "an unvouched head only the gate holds never alarmed"; }
  grep -Fx "stale: $window" "$out" >/dev/null || fail "the unvouched gate-held head printed the wrong wake: $(cat "$out")"
  grep -F "surfaced stale" "$state/.watch-triage.log" | grep -F "landing=landing-blocked" | grep -F "$window" >/dev/null \
    || fail "the unvouched gate-held alarm left no triage-log line naming the landing class: $(cat "$state/.watch-triage.log" 2>/dev/null)"
  ack_stopped_cycle "$state" || fail "could not acknowledge the unvouched gate-held leg's watcher stop"
  pass "a validated PR head only the pipeline's gate holds raises no stale wake on a stopped worker; an unvouched one still does"
}

# --- a declared wait survives the resolutions logged after it ----------------
# The stale path asks whether a quiet worker declared a wait, and it read the
# LAST status line to answer. A `resolved [key=k]` line firstmate appends when it
# answers a call is never the worker's word: on 2026-09-22 a worker firstmate
# had stopped, whose log ended `paused:` -> `needs-decision [key=k]` ->
# `resolved [key=k]`, was stale-alarmed and wedge-escalated five times in a row,
# while the same stop behind a log ending in `paused:` stayed quiet. The stop
# record licenses nothing on its own here (bin/fm-awaiting-landing-lib.sh owns
# why a stopped worker with open work stays watched); the stale path reads the
# worker's declaration through status_declared_line instead.

# status_declared_line, as a pure function over a status log.
#
# Mutants that must turn this red:
#   - print the last line: every case that ends in a resolution.
#   - fold resolutions alone (status_outcome_line): the answered decision.
#   - fold a decision whatever key the resolution names: the other-key case.
#   - fold back to the last paused line: the other-key and superseded cases.
#   - never fold a captain-held line: both answered-hold cases.
#   - never fold a note: both note cases.
#   - never fold a keyed wait: the closed keyed-wait and build-lock cases.
#   - never end an unkeyed wait on a bare resolution: the ended-wait cases.
#   - end a wait on a bare resolution an unkeyed decision took: the answered
#     unkeyed blocker.
#   - end a wait on a stated [key=default]: the stated-default case.
#   - end only the latest unkeyed wait: the superseded-wait case.
test_status_declared_line_classifier() {
  local dir f got
  dir="$TMP_ROOT/status-declared-line"; mkdir -p "$dir"; f="$dir/task.status"
  declared_is() {  # <expected> <label> <status-line>...
    local want=$1 label=$2
    shift 2
    printf '%s\n' "$@" > "$f"
    got=$(status_declared_line "$f")
    [ "$got" = "$want" ] || fail "status_declared_line, $label: got '$got', want '$want'"
  }
  [ -z "$(status_declared_line "$dir/missing.status")" ] || fail "a missing log declared something"
  declared_is '' 'blank log' '' '   '
  declared_is '' 'resolutions only' 'resolved: answered'
  declared_is 'paused: waiting on CI' 'a plain wait' 'paused: waiting on CI'
  declared_is 'paused: waiting on CI' 'an answered decision after the wait' \
    'paused: waiting on CI' 'needs-decision [key=nm-r1-ci]: findings=ci-1' \
    'resolved [key=nm-r1-ci]: answered: stay parked'
  declared_is 'paused: waiting on CI' 'an answered decision keyed at the head of its note' \
    'paused: waiting on CI' 'needs-decision: [key=shape] which way' 'resolved [key=shape]: this way'
  declared_is 'paused: waiting on CI' 'an answered unkeyed blocker' \
    'paused: waiting on CI' 'blocked: implementation committed abc123' 'resolved: answered: run it'
  declared_is 'paused: waiting on a release' 'a resolution that closed nothing' \
    'paused: waiting on a release' 'resolved [key=relay]: answered: noted'
  declared_is 'needs-decision [key=review-shape]: which way' 'a resolution naming another key' \
    'paused: waiting on CI' 'needs-decision [key=review-shape]: which way' 'resolved [key=other-call]: done'
  declared_is 'working: CI came back, fixing it' 'a later word superseding the wait' \
    'paused: waiting on CI' 'working: CI came back, fixing it' 'resolved [key=relay]: noted'
  declared_is 'needs-decision [key=shape]: asked again' 'a decision reopened after its answer' \
    'needs-decision [key=shape]: which way' 'resolved [key=shape]: this way' \
    'needs-decision [key=shape]: asked again'
  declared_is 'captain-held [key=shape]: held for the captain' 'a captain-held transfer' \
    'needs-decision [key=shape]: which way' 'captain-held [key=shape]: held for the captain'
  declared_is 'working: dispatched the audit' 'a captain hold the captain answered' \
    'working: dispatched the audit' 'captain-held [key=route]: tracked by task-decision-route' \
    'resolved [key=route]: captain chose the direct path'
  declared_is 'paused: waiting on CI' 'a held decision the captain answered after the wait' \
    'paused: waiting on CI' 'needs-decision [key=shape]: which way' \
    'captain-held [key=shape]: held for the captain' 'resolved [key=shape]: this way'
  declared_is 'captain-held [key=shape]: held for the captain' 'a captain hold answered under another key' \
    'captain-held [key=shape]: held for the captain' 'resolved [key=other-call]: done'
  declared_is 'paused: waiting on CI' 'a note after the wait' \
    'paused: waiting on CI' 'note: the flaky case went green on a re-run'
  declared_is '' 'notes only' 'note: holding the machine-wide build lock for 20m00s'
  declared_is 'working: rebasing' 'a keyed wait its resolution closed' \
    'working: rebasing' 'paused [key=build-lock-7-1700000000]: waiting 10m00s for the lock' \
    'resolved [key=build-lock-7-1700000000]: acquired the machine-wide build lock after 10m28s'
  declared_is 'paused [key=build-lock-7-1700000000]: waiting 10m00s for the lock' 'a keyed wait still open' \
    'working: rebasing' 'paused [key=build-lock-7-1700000000]: waiting 10m00s for the lock'
  declared_is 'paused: [key=ci] waiting on CI' 'a keyed wait closed under another key' \
    'paused: [key=ci] waiting on CI' 'resolved [key=other-call]: done'
  declared_is 'paused: suite under way, until 2026-09-21T01:00Z' 'the build lock queueing inside a declared wait' \
    'paused: suite under way, until 2026-09-21T01:00Z' \
    'paused [key=build-lock-7-1700000000]: waiting 10m00s for the lock' \
    'resolved [key=build-lock-7-1700000000]: acquired the machine-wide build lock after 10m28s' \
    'note: holding the machine-wide build lock for 20m00s with 0 waiting'
  # A bare resolution is how the worker contract ends an unkeyed wait.
  declared_is 'working: rebasing' 'an unkeyed wait a bare resolution ended' \
    'working: rebasing' 'paused: waiting on CI' 'resolved: CI came back green'
  declared_is '' 'an ended wait with nothing before it' \
    'paused: waiting on CI' 'note: holding the machine-wide build lock for 20m00s' 'resolved: CI came back green'
  declared_is 'working: rebasing' 'an ended wait behind the build lock lines' \
    'working: rebasing' 'paused: waiting on CI' \
    'paused [key=build-lock-7-1700000000]: waiting 10m00s for the lock' \
    'resolved [key=build-lock-7-1700000000]: acquired the machine-wide build lock after 10m28s' \
    'resolved: CI came back green'
  declared_is 'working: rebasing' 'a superseded wait ends with the one that replaced it' \
    'working: rebasing' 'paused: waiting on CI' 'paused: waiting on the re-run' 'resolved: the re-run passed'
  declared_is 'paused: waiting on CI' 'a stated default resolution answers a decision, not the wait' \
    'working: rebasing' 'paused: waiting on CI' 'resolved [key=default]: answered: run it'
  declared_is 'working: rebasing' 'a wait ended after an answered unkeyed blocker' \
    'working: rebasing' 'paused: waiting on CI' 'blocked: implementation committed abc123' \
    'resolved: answered: run it' 'resolved: CI came back green'
  unset -f declared_is
  pass "status_declared_line folds notes, resolutions, the decisions and keyed waits they closed, and the unkeyed waits a bare resolution ended, and nothing else"
}

# status_declared_identity, as a pure function over a status log: the identity a
# declared wait's re-surface window is bound to.
#
# Mutants that must turn this red:
#   - the whole log's signature, or any identity that reads past the declared
#     line: the build lock's lines change it.
#   - the declared line's text alone: an identical replacement wait keeps it.
#   - drop the skip of the build lock's open queue wait: the queued lock
#     changes it (the build lock's keyed wait case).
#   - widen the skip back to any open keyed wait: a worker's own replacement
#     keyed wait, and a keyed pause after a blocked or needs-decision, keep the
#     earlier identity (the worker's keyed wait cases).
test_status_declared_identity_classifier() {
  local dir f base got
  dir="$TMP_ROOT/status-declared-identity"; mkdir -p "$dir"; f="$dir/task.status"
  identity_of() {  # <status-line>...
    printf '%s\n' "$@" > "$f"
    status_declared_identity "$f"
  }
  [ -z "$(status_declared_identity "$dir/missing.status")" ] || fail "a missing log had a declaration identity"
  [ -z "$(identity_of 'note: a report' 'resolved: nothing open')" ] || fail "a log declaring nothing had an identity"
  base=$(identity_of 'working: rebasing' 'paused: waiting on CI')
  [ -n "$base" ] || fail "a declared wait had no identity"
  got=$(identity_of 'working: rebasing' 'paused: waiting on CI' \
    'paused [key=build-lock-7-1700000000]: waiting 10m00s for the lock')
  [ "$got" = "$base" ] || fail "the build lock's open queue wait changed the wait's identity: $got, not $base"
  got=$(identity_of 'working: rebasing' 'paused: waiting on CI' \
    'paused [key=build-lock-7-1700000000]: waiting 10m00s for the lock' \
    'resolved [key=build-lock-7-1700000000]: acquired the machine-wide build lock after 10m28s' \
    'note: holding the machine-wide build lock for 20m00s with 0 waiting')
  [ "$got" = "$base" ] || fail "the build lock's resolved wait and note changed the wait's identity: $got, not $base"
  got=$(identity_of 'working: rebasing' 'paused: waiting on CI' 'working: rebasing' 'paused: waiting on CI')
  [ "$got" != "$base" ] || fail "an identical replacement wait kept the old wait's identity"
  got=$(identity_of 'working: rebasing' 'paused: waiting on the re-run')
  [ "$got" != "$base" ] || fail "a different wait in the same position kept the old wait's identity"
  got=$(identity_of 'paused [key=build-lock-7-1700000000]: waiting 10m00s for the lock')
  [ -n "$got" ] || fail "a keyed wait with nothing declared beneath it had no identity"
  got=$(identity_of 'working: rebasing' 'paused: waiting on CI' 'paused [key=ci]: waiting on CI')
  [ "$got" != "$base" ] || fail "a worker's own replacement keyed wait kept the old wait's identity"
  base=$(identity_of 'blocked: need the schema')
  got=$(identity_of 'blocked: need the schema' 'paused [key=ci]: waiting on CI')
  [ "$got" != "$base" ] || fail "a keyed pause after a blocked line kept the blocker's identity"
  base=$(identity_of 'needs-decision: which schema')
  got=$(identity_of 'needs-decision: which schema' 'paused [key=ci]: waiting on CI')
  [ "$got" != "$base" ] || fail "a keyed pause after a needs-decision line kept the decision's identity"
  unset -f identity_of
  pass "status_declared_identity names the declaration, not the lines logged after it"
}

# A stopped worker whose status log is <status-line>..., stale-ready as
# landing_stale_task leaves it. Prints the window's marker key.
stopped_declared_task() {  # <dir> <id> <window> <capture-file> <status-line>...
  local dir=$1 id=$2 window=$3 capture=$4 state key
  shift 4
  state="$dir/state"
  key=$(landing_stale_task "$state" "$id" "$window" "$capture" "fm-$id \$" "$1" "worktree=$dir/wt")
  shift
  [ "$#" -eq 0 ] || printf '%s\n' "$@" >> "$state/$id.status"
  printf '%s' "$(seen_sig "$state/$id.status")" > "$state/.seen-${id}_status"
  landing_stop_agent "$state" "$id"
  printf '%s' "$key"
}

# The watcher over the live shape and its controls. Every worker is stopped and
# its pane is a bare shell, so the stop record is constant across the legs and
# only the status log decides.
#
# Mutants that must turn this red:
#   - read the last line on the stale path (current main): both quiet legs alarm.
#   - fold resolutions alone (status_outcome_line): the answered leg alarms.
#   - fold a decision whatever key the resolution names: the other-key leg goes
#     quiet.
#   - fold back to the last paused line: the other-key and superseded legs go
#     quiet.
test_a_declared_wait_survives_the_resolutions_logged_after_it() {
  local dir state fakebin out capture window key pid leg
  export FM_FAKE_CREW_STATE='state: stopped · source: pane · bare shell'
  for leg in answered orphan; do
    dir=$(make_case "declared-wait-quiet-$leg"); state="$dir/state"; fakebin="$dir/fakebin"
    out="$dir/watch.out"; capture="$dir/pane.txt"; window="test:fm-wait-$leg"
    case "$leg" in
      answered)
        key=$(stopped_declared_task "$dir" "wait-$leg" "$window" "$capture" \
          'paused: validation run r1 waiting on CI checks for PR https://example.test/pr/74' \
          'needs-decision [key=nm-r1-ci]: ask-user findings=ci-1,ci-2 file=/tmp/findings.txt' \
          'resolved [key=nm-r1-ci]: answered: do not approve, fix or skip; stay parked at the ci gate') ;;
      orphan)
        key=$(stopped_declared_task "$dir" "wait-$leg" "$window" "$capture" \
          'paused: waiting on an upstream release' 'resolved [key=relay]: answered: noted') ;;
    esac
    landing_watch "$state" "$fakebin" "$out" "$window" "$capture" FM_FAKE_TMUX_CURRENT_COMMAND=zsh
    pid=$!
    landing_assert_quiet "$state" "$pid" "$out" "$key" 2 \
      "a stopped worker whose declared wait was followed by a resolution ($leg)"
  done
  for leg in other-key superseded open-work; do
    dir=$(make_case "declared-wait-alarm-$leg"); state="$dir/state"; fakebin="$dir/fakebin"
    out="$dir/watch.out"; capture="$dir/pane.txt"; window="test:fm-wait-$leg"
    case "$leg" in
      other-key)
        stopped_declared_task "$dir" "wait-$leg" "$window" "$capture" 'paused: waiting on CI' \
          'needs-decision [key=review-shape]: which way' 'resolved [key=other-call]: answered: done' >/dev/null ;;
      superseded)
        stopped_declared_task "$dir" "wait-$leg" "$window" "$capture" 'paused: waiting on CI' \
          'working: CI came back, fixing the failure' 'resolved [key=relay]: answered: noted' >/dev/null ;;
      open-work)
        stopped_declared_task "$dir" "wait-$leg" "$window" "$capture" 'working: implementing the fix' >/dev/null ;;
    esac
    landing_watch "$state" "$fakebin" "$out" "$window" "$capture" FM_FAKE_TMUX_CURRENT_COMMAND=zsh
    pid=$!
    wait_for_exit "$pid" 100 \
      || { reap "$pid"; fail "a stopped worker with open work and no standing declared wait did not alarm ($leg): $(cat "$out")"; }
    grep -Fx "stale: $window" "$out" >/dev/null \
      || fail "a stopped worker with open work printed the wrong wake ($leg): $(cat "$out")"
  done
  unset FM_FAKE_CREW_STATE
  pass "a stopped worker's declared wait survives a later resolution, while open work with no standing wait still alarms"
}

# An unkeyed wait the worker itself ended. The worker contract's line for a wait
# that clears with no reply is a bare `resolved:`, and until 2026-09-23 that line
# never ended the wait: the stale path went on reading the worker as parked on
# something it had said was over, absorbing its quiet pane on the long cadence
# and then rechecking it as that wait. A stopped worker whose log ends in the
# ended wait is watched as the open work it went back to; the same wait answered
# by a stated [key=default] resolution, or with an unkeyed blocker between it and
# the bare resolution, still stands.
#
# Mutants that must turn this red:
#   - never end an unkeyed wait on a bare resolution (current main): the ended
#     leg stays quiet.
#   - end a wait on any resolution: both standing legs alarm.
test_a_bare_resolution_ends_an_unkeyed_wait() {
  local dir state fakebin out capture window key pid leg
  export FM_FAKE_CREW_STATE='state: stopped · source: pane · bare shell'
  for leg in stated-default answered-blocker; do
    dir=$(make_case "bare-resolution-quiet-$leg"); state="$dir/state"; fakebin="$dir/fakebin"
    out="$dir/watch.out"; capture="$dir/pane.txt"; window="test:fm-bare-$leg"
    case "$leg" in
      stated-default)
        key=$(stopped_declared_task "$dir" "bare-$leg" "$window" "$capture" 'working: rebasing onto main' \
          'paused: waiting on CI for PR https://example.test/pr/75' 'resolved [key=default]: answered: run it') ;;
      answered-blocker)
        key=$(stopped_declared_task "$dir" "bare-$leg" "$window" "$capture" 'working: rebasing onto main' \
          'paused: waiting on CI for PR https://example.test/pr/76' 'blocked: implementation committed abc123' \
          'resolved: answered: run it') ;;
    esac
    landing_watch "$state" "$fakebin" "$out" "$window" "$capture" FM_FAKE_TMUX_CURRENT_COMMAND=zsh
    pid=$!
    landing_assert_quiet "$state" "$pid" "$out" "$key" 2 \
      "a stopped worker whose unkeyed wait still stands ($leg)"
  done
  dir=$(make_case bare-resolution-ended); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture="$dir/pane.txt"; window="test:fm-bare-ended"
  stopped_declared_task "$dir" bare-ended "$window" "$capture" 'working: rebasing onto main' \
    'paused: waiting on CI for PR https://example.test/pr/77' 'resolved: CI came back green, back to the fix' >/dev/null
  landing_watch "$state" "$fakebin" "$out" "$window" "$capture" FM_FAKE_TMUX_CURRENT_COMMAND=zsh
  pid=$!
  wait_for_exit "$pid" 100 \
    || { reap "$pid"; fail "a stopped worker whose wait it had ended itself was still read as waiting: $(cat "$out")"; }
  grep -Fx "stale: $window" "$out" >/dev/null \
    || fail "a stopped worker whose wait had ended printed the wrong wake: $(cat "$out")"
  unset FM_FAKE_CREW_STATE
  pass "a bare resolution ends an unkeyed wait, while a stated default answer or an answered blocker between them leaves it standing"
}


test_wedge_escalation_marks_demand_deep_inspection_after_threshold
test_wedge_escalation_resets_when_pane_becomes_active
test_awaiting_landing_raises_no_stale_alarm
test_awaiting_landing_never_enters_the_wedge_ladder
test_status_declared_line_classifier
test_status_declared_identity_classifier
test_a_declared_wait_survives_the_resolutions_logged_after_it
test_a_bare_resolution_ends_an_unkeyed_wait
test_wedged_task_not_awaiting_landing_still_alarms_and_escalates
test_validated_ahead_pr_head_on_a_stopped_worker_is_quiet_and_others_alarm
test_validated_rebased_pr_head_on_a_stopped_worker_is_quiet_and_a_wedge_alarms
test_validated_pr_head_only_the_gate_holds_on_a_stopped_worker_is_quiet
test_nonterminal_paused_confirmed_by_active_run_holds_pause_cadence
test_paused_authoritative_working_holds_cadence_and_recheck_ceiling
test_paused_run_step_working_dead_agent_still_wedge_escalates
