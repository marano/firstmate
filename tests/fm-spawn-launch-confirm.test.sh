#!/usr/bin/env bash
# tests/fm-spawn-launch-confirm.test.sh - a typed launch is never its own proof.
#
# Portable regression for bin/fm-spawn.sh's launch confirmation. It runs the
# REAL fm-spawn.sh and fm-control.sh against a REAL tmux server on a private
# socket (`-L`) whose panes run a REAL interactive shell with no configuration,
# so it needs no harness and no credentials. The stand-in agent is a symlink to
# a long-running system binary named `claude`, which is exactly the process
# identity the tmux agent-state classifier reads.
#
# The defect: a launch command typed into a fresh pane arrived cut short in the
# middle of its `"$(...fm-operational-in` substitution, the shell sat at a
# `dquote cmdsubst>` continuation prompt, and the spawn still reported success.
# The next relaunch typed its own command into that open quote. A tmux shim
# reproduces the cut on the launch literal only, exactly where the incident's
# fell, and lets every other byte through to the real server.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v tmux >/dev/null 2>&1 || { echo "skip: tmux not found"; exit 0; }
SLEEP_BIN=$(command -v sleep) || { echo "skip: sleep not found"; exit 0; }
if PANE_SHELL=$(command -v zsh); then
  PANE_SHELL_ARGS='-f'
elif PANE_SHELL=$(command -v bash); then
  PANE_SHELL_ARGS='--norc --noprofile'
else
  echo "skip: neither zsh nor bash found"
  exit 0
fi

LAB=$(fm_test_tmproot fm-spawn-launch-confirm)
SOCKET="fm-launch-$$"
REAL_TMUX=$(command -v tmux)
TASK_IDS=()

cleanup() {
  local id
  "$REAL_TMUX" -L "$SOCKET" kill-server >/dev/null 2>&1 || true
  for id in "${TASK_IDS[@]:-}"; do
    [ -n "$id" ] && rm -rf "/tmp/fm-$id"
  done
  fm_test_cleanup
}
trap cleanup EXIT

mkdir -p "$LAB/bin" "$LAB/agent" "$LAB/home"
ln -s "$SLEEP_BIN" "$LAB/agent/claude"

# Every bare `tmux` call reaches the private server. While the garble counter
# file holds a positive count, a launch literal loses everything from inside
# its operational-input substitution onward - the incident's exact cut.
cat > "$LAB/bin/tmux" <<SH
#!/usr/bin/env bash
args=("\$@")
if [ "\${1:-}" = send-keys ] && [ -s "$LAB/garble" ]; then
  last=\$((\${#args[@]} - 1))
  payload=\${args[\$last]}
  case "\$payload" in
    *'encode launch-brief'*)
      left=\$(cat "$LAB/garble")
      if [ "\$left" -gt 0 ]; then
        printf '%s\n' "\$((left - 1))" > "$LAB/garble"
        args[\$last]=\${payload%%operational-input*}operational-in
      fi
      ;;
  esac
fi
exec "$REAL_TMUX" -L "$SOCKET" "\${args[@]}"
SH
# The pane's shell, unconfigured so nothing but typed input reaches it.
cat > "$LAB/bin/labshell" <<SH
#!/bin/sh
exec "$PANE_SHELL" $PANE_SHELL_ARGS
SH
# treehouse get opens a subshell in the pool worktree the case names.
cat > "$LAB/bin/treehouse" <<SH
#!/bin/sh
cd "\$(cat "$LAB/next-wt")" || exit 1
exec "$LAB/bin/labshell"
SH
# The stand-in harness ignores its arguments and runs as a process named claude.
# It first records the task marker the pane exported before the launch, which
# is how a case proves those earlier typed lines landed too.
cat > "$LAB/bin/claude" <<SH
#!/bin/sh
printf 'task=%s\n' "\${FM_TASK_ID:-}" >> "$LAB/agent-starts"
exec "$LAB/agent/claude" 600
SH
chmod +x "$LAB/bin/tmux" "$LAB/bin/labshell" "$LAB/bin/treehouse" "$LAB/bin/claude"

PATH="$LAB/bin:$PATH"
export PATH
unset TMUX TMUX_PANE

HOME="$LAB/home" "$REAL_TMUX" -L "$SOCKET" -f /dev/null \
  new-session -d -s firstmate -x 200 -y 50 -- "$LAB/bin/labshell" \
  || fail "could not start the private tmux server"
"$REAL_TMUX" -L "$SOCKET" set-option -g default-shell "$LAB/bin/labshell" >/dev/null \
  || fail "could not pin the private server's pane shell"

# shellcheck source=/dev/null
. "$ROOT/bin/fm-backend.sh"
fm_backend_source tmux || fail "fm_backend_source tmux failed"

# new_case <name> <id> -> sets CASE_HOME, CASE_PROJ, CASE_WT
new_case() {
  local name=$1 id=$2 dir
  dir="$LAB/$name"
  CASE_HOME="$dir/home"
  CASE_PROJ="$dir/project"
  CASE_WT="$dir/wt"
  mkdir -p "$CASE_HOME/data/$id" "$CASE_HOME/projects" "$CASE_HOME/state" \
    "$CASE_HOME/config" "$CASE_HOME/user-home"
  touch "$CASE_HOME/state/.last-watcher-beat"
  fm_git_worktree "$CASE_PROJ" "$CASE_WT" "wt-$name"
  cat > "$CASE_HOME/data/$id/brief.md" <<EOF
# Task
## Captain's intent
Exercise launch confirmation for $id.

## Firstmate spec
Start one agent in the task's own pane.

Delivery contract: mode=no-mistakes
EOF
  printf '%s\n' "$CASE_WT" > "$LAB/next-wt"
  TASK_IDS+=("$id")
}

run_fm() {  # <script> <args...>
  local script=$1
  shift
  FM_ROOT_OVERRIDE='' FM_HOME="$CASE_HOME" HOME="$CASE_HOME/user-home" CLAUDE_CONFIG_DIR='' \
    FM_STATE_OVERRIDE="$CASE_HOME/state" FM_DATA_OVERRIDE="$CASE_HOME/data" \
    FM_PROJECTS_OVERRIDE="$CASE_HOME/projects" FM_CONFIG_OVERRIDE="$CASE_HOME/config" \
    FM_SPAWN_NO_GUARD=1 FM_SPAWN_LAUNCH_POLLS=20 FM_SPAWN_LAUNCH_POLL_INTERVAL=0.25 \
    FM_CONTROL_LAUNCH_WAIT=10 \
    "$ROOT/bin/$script" "$@" 2>&1
}

garble_next() {  # <count>
  printf '%s\n' "$1" > "$LAB/garble"
}

window_state() {  # <id>
  fm_backend_agent_state tmux "firstmate:fm-$1"
}

pane_tail() {  # <id>
  "$REAL_TMUX" -L "$SOCKET" capture-pane -p -t "firstmate:fm-$1" 2>/dev/null \
    | grep '[^[:space:]]' | tail -4
}

# The incident, unrepaired: every launch typed into the pane is cut short, so
# no agent can ever start there. The spawn must say so instead of reporting a
# worker that does not exist, and must not leave that pane behind to be retried.
test_spawn_refuses_to_report_a_launch_that_never_started() {
  local id=launch-never-z1 out rc
  new_case never "$id"
  garble_next 99
  out=$(run_fm fm-spawn.sh "$id" "$CASE_PROJ" --harness claude --mode no-mistakes --yolo off); rc=$?
  [ "$rc" -ne 0 ] || fail "a spawn whose launch never started must fail, but it exited 0"$'\n'"$out"
  assert_not_contains "$out" "spawned $id" "a spawn must never report a worker whose agent never started"
  assert_contains "$out" "no agent started" "the refusal must name the missing agent"
  assert_grep "failed: no agent started" "$CASE_HOME/state/$id.status" \
    "the failure must reach the task's status log"
  [ ! -e "$CASE_HOME/state/$id.meta" ] \
    || fail "a failed fresh spawn must not leave a record claiming a worker"
  [ "$(window_state "$id")" = missing ] \
    || fail "the failed launch's pane must be closed, not left behind to poison a retry (reads $(window_state "$id"))"
  pass "a spawn whose launch never started fails and closes its pane"
}

# One cut launch, then a clean one: the spawn must clear the continuation
# prompt the cut left and type the launch again, ending with a live agent.
test_spawn_recovers_a_launch_cut_once() {
  local id=launch-once-z2 out rc
  new_case once "$id"
  garble_next 1
  out=$(run_fm fm-spawn.sh "$id" "$CASE_PROJ" --harness claude --mode no-mistakes --yolo off); rc=$?
  expect_code 0 "$rc" "a spawn whose first launch was cut should recover"$'\n'"$out"
  assert_contains "$out" "spawned $id" "a recovered spawn should report success"
  [ "$(cat "$LAB/garble")" = 0 ] || fail "the case must actually cut the first launch"
  [ "$(window_state "$id")" = alive ] \
    || fail "a reported spawn must have a running agent (reads $(window_state "$id"))"$'\n'"$(pane_tail "$id")"
  pass "a spawn clears a cut launch's continuation prompt and starts the agent"
}

# The relaunch half: an endpoint whose shell sits at the continuation prompt a
# cut launch left must be cleared before the replacement launch is typed.
test_relaunch_clears_a_poisoned_prompt() {
  local id=launch-relaunch-z3 out rc tail_before
  new_case relaunch "$id"
  "$REAL_TMUX" -L "$SOCKET" new-window -d -t firstmate: -n "fm-$id" -c "$CASE_WT" \
    || fail "could not create the relaunch endpoint"
  fm_write_meta "$CASE_HOME/state/$id.meta" \
    "window=firstmate:fm-$id" "endpoint_task_id=$id" "worktree=$CASE_WT" \
    "project=$CASE_PROJ" harness=claude kind=ship mode=no-mistakes yolo=off \
    "tasktmp=/tmp/fm-$id" model=default effort=default
  sleep 0.5
  # The unexpanded `$(` is the point: it is the open substitution a cut launch
  # leaves behind in the pane.
  # shellcheck disable=SC2016
  "$REAL_TMUX" -L "$SOCKET" send-keys -t "firstmate:fm-$id" -l \
    'env -u CURSOR_AGENT claude --x "$(/firstmate/bin/fm-operational-in'
  "$REAL_TMUX" -L "$SOCKET" send-keys -t "firstmate:fm-$id" Enter
  sleep 0.5
  tail_before=$(pane_tail "$id")
  assert_contains "$tail_before" "cmdsubst>" "the case must leave the shell at a continuation prompt"
  [ "$(window_state "$id")" = dead ] || fail "the poisoned endpoint must read agent-free"
  garble_next 0
  out=$(run_fm fm-control.sh "$id" relaunch --note "the first launch was cut short"); rc=$?
  expect_code 0 "$rc" "a relaunch into a poisoned prompt should succeed"$'\n'"$out"$'\n'"$(pane_tail "$id")"
  assert_contains "$out" "relaunched $id" "the relaunch should report its outcome"
  [ "$(window_state "$id")" = alive ] \
    || fail "the relaunched agent must be running (reads $(window_state "$id"))"
  # The launch alone could still land after a late clear; the task marker
  # exported ahead of it lands only if the prompt was cleared first.
  assert_grep "task=$id" "$LAB/agent-starts" \
    "the lines typed ahead of the launch must land too, so the prompt must be cleared before any of them"
  pass "a relaunch clears a continuation prompt before typing its launch"
}

test_spawn_refuses_to_report_a_launch_that_never_started
test_spawn_recovers_a_launch_cut_once
test_relaunch_clears_a_poisoned_prompt
