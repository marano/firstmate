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
# The defect: a launch command typed into a fresh pane arrived cut short, the
# shell sat at a continuation prompt, and the spawn still reported success.
# The next relaunch typed its own command into that open quote. A tmux shim
# reproduces a cut on the typed launch line only, leaving its quote open, and
# lets every other byte through to the real server.
#
# The cause: a pane shell running a pre-prompt hook (mise's, after each typed
# export) is not in its line editor, so typed text waits in the terminal's
# canonical input, which keeps only its first 1024 bytes on macOS and drops the
# rest with the Enter behind it. The slow-hook case types through a shell whose
# every prompt waits on such a hook, with no shim at all.
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
SLOW_HOOK_SECONDS=2
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
# file holds a positive count, the typed launch line loses its tail from inside
# the quoted launch-file path onward, leaving that quote open.
cat > "$LAB/bin/tmux" <<SH
#!/usr/bin/env bash
args=("\$@")
# Record the byte length of every literal the spawn types, so a case can bound
# the longest line the pane shell ever has to hold.
if [ "\${1:-}" = send-keys ]; then
  for a in "\${args[@]}"; do
    if [ "\${prev:-}" = -l ]; then printf '%s\n' "\${#a}" >> "$LAB/typed-lengths"; fi
    prev=\$a
  done
fi
if [ "\${1:-}" = send-keys ] && [ -s "$LAB/garble" ]; then
  last=\$((\${#args[@]} - 1))
  payload=\${args[\$last]}
  case "\$payload" in
    ". '"*"/launch."*".sh'")
      left=\$(cat "$LAB/garble")
      if [ "\$left" -gt 0 ]; then
        printf '%s\n' "\$((left - 1))" > "$LAB/garble"
        args[\$last]=\${payload%/launch.*}/lau
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
# The same shell, except that every prompt first waits on a slow pre-prompt
# hook, during which the shell is not reading typed input with its line editor.
mkdir -p "$LAB/slowzd"
printf 'precmd() { sleep %s; echo >> "%s"; }\n' "$SLOW_HOOK_SECONDS" "$LAB/hook-runs" > "$LAB/slowzd/.zshrc"
cat > "$LAB/bin/slowshell" <<SH
#!/bin/sh
case "$PANE_SHELL" in
  *zsh) ZDOTDIR="$LAB/slowzd" exec "$PANE_SHELL" -d -i ;;
  *) PROMPT_COMMAND="sleep $SLOW_HOOK_SECONDS; echo >> '$LAB/hook-runs'" exec "$PANE_SHELL" $PANE_SHELL_ARGS ;;
esac
SH
# treehouse get opens a subshell in the pool worktree the case names, slow when
# the case asks for it.
cat > "$LAB/bin/treehouse" <<SH
#!/bin/sh
cd "\$(cat "$LAB/next-wt")" || exit 1
[ -e "$LAB/slow-next" ] && exec "$LAB/bin/slowshell"
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
chmod +x "$LAB/bin/tmux" "$LAB/bin/labshell" "$LAB/bin/slowshell" "$LAB/bin/treehouse" "$LAB/bin/claude"

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
    FM_SPAWN_NO_GUARD=1 FM_SPAWN_LAUNCH_POLLS=${CASE_LAUNCH_POLLS:-20} FM_SPAWN_LAUNCH_POLL_INTERVAL=0.25 \
    FM_CONTROL_LAUNCH_WAIT=10 \
    "$ROOT/bin/$script" "$@" 2>&1
}

garble_next() {  # <count>
  printf '%s\n' "$1" > "$LAB/garble"
}

# Every launch file a task's spawns staged, one path per line.
launch_files() {  # <id>
  local f
  for f in "/tmp/fm-$1"/launch.*.sh; do
    [ -f "$f" ] && printf '%s\n' "$f"
  done
  return 0
}

path_mode() {  # <path>
  stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1" 2>/dev/null
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
  # zsh names the open construct (`dquote cmdsubst>`); bash shows a bare `>`.
  case "$(printf '%s\n' "$tail_before" | tail -1)" in
    *'>'|*'> ') ;;
    *) fail "the case must leave the shell at a continuation prompt"$'\n'"$tail_before" ;;
  esac
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

# The pane shell runs whatever the launch file holds, and the file sits under a
# predictable /tmp path, so a fresh root is created private and the file is
# readable by this user alone.
# Named mutant: create the task temp root without umask 077 (it lands 0755).
test_spawn_stages_its_launch_in_a_private_root() {
  local id=launch-private-z5 out rc files
  new_case private "$id"
  garble_next 0
  rm -rf "/tmp/fm-$id"
  out=$(run_fm fm-spawn.sh "$id" "$CASE_PROJ" --harness claude --mode no-mistakes --yolo off); rc=$?
  expect_code 0 "$rc" "a spawn into a fresh temp root should start its agent"$'\n'"$out"
  assert_equals 700 "$(path_mode "/tmp/fm-$id")" \
    "a fresh task temp root must be created 0700"
  files=$(launch_files "$id")
  [ "$(printf '%s\n' "$files" | grep -c .)" = 1 ] \
    || fail "one spawn must stage exactly one launch file, found: $files"
  assert_equals 600 "$(path_mode "$files")" "the staged launch file must be 0600"
  pass "a spawn stages its launch command 0600 in a 0700 task temp root"
}

# A root that already exists is reused only when nobody else can write it; one
# this user owns but left open is tightened rather than trusted as found.
# Named mutants: drop the group/world-writable refusal (the first half then
# launches from an open root), or drop the chmod 700 on a reused root (the
# second half then leaves it 0755).
test_spawn_refuses_a_task_temp_root_others_can_write() {
  local id=launch-openroot-z6 out rc
  new_case openroot "$id"
  garble_next 0
  rm -rf "/tmp/fm-$id"
  mkdir "/tmp/fm-$id"
  chmod 777 "/tmp/fm-$id"
  out=$(run_fm fm-spawn.sh "$id" "$CASE_PROJ" --harness claude --mode no-mistakes --yolo off); rc=$?
  [ "$rc" -ne 0 ] || fail "a spawn must refuse a task temp root others can write, but it exited 0"$'\n'"$out"
  assert_contains "$out" "is not a private directory owned by this user" \
    "the refusal must name the unsafe temp root"
  [ -z "$(launch_files "$id")" ] || fail "a refused spawn must not stage a launch file in an open root"
  if [ -e "$LAB/agent-starts" ] && grep -q "task=$id" "$LAB/agent-starts"; then
    fail "a refused spawn must not start an agent"
  fi
  [ "$(window_state "$id")" = missing ] \
    || fail "a refused fresh spawn must close the endpoint it created (reads $(window_state "$id"))"
  rm -rf "/tmp/fm-$id"
  mkdir "/tmp/fm-$id"
  chmod 755 "/tmp/fm-$id"
  new_case openroot-owned "$id"
  out=$(run_fm fm-spawn.sh "$id" "$CASE_PROJ" --harness claude --mode no-mistakes --yolo off); rc=$?
  expect_code 0 "$rc" "a spawn should reuse a temp root this user owns and nobody else can write"$'\n'"$out"
  assert_equals 700 "$(path_mode "/tmp/fm-$id")" \
    "a reused task temp root must be tightened to 0700"
  pass "a spawn refuses a temp root others can write and tightens one it owns"
}

# A source line typed for one incarnation can still sit buffered in the pane
# when a relaunch stages the next, so a relaunch writes a new file and never
# rewrites the one an earlier line names.
# Named mutant: stage every launch at one fixed file name (the relaunch then
# overwrites it and a single file remains).
test_relaunch_never_reuses_a_launch_file() {
  local id=launch-fresh-z7 out rc first first_sum files f
  new_case freshfile "$id"
  garble_next 0
  rm -rf "/tmp/fm-$id"
  out=$(run_fm fm-spawn.sh "$id" "$CASE_PROJ" --harness claude --mode no-mistakes --yolo off); rc=$?
  expect_code 0 "$rc" "the first spawn should start its agent"$'\n'"$out"
  first=$(launch_files "$id")
  [ -n "$first" ] || fail "the first spawn staged no launch file"
  first_sum=$(cksum < "$first")
  # End the stand-in agent so the endpoint reads agent-free for the relaunch.
  "$REAL_TMUX" -L "$SOCKET" send-keys -t "firstmate:fm-$id" C-c
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    [ "$(window_state "$id")" = dead ] && break
    sleep 0.3
  done
  [ "$(window_state "$id")" = dead ] || fail "the stand-in agent did not stop before the relaunch"
  out=$(run_fm fm-control.sh "$id" relaunch --note "exercise a second incarnation"); rc=$?
  expect_code 0 "$rc" "the relaunch should start a replacement agent"$'\n'"$out"$'\n'"$(pane_tail "$id")"
  [ "$(window_state "$id")" = alive ] \
    || fail "the relaunched agent must be running (reads $(window_state "$id"))"
  files=$(launch_files "$id")
  [ "$(printf '%s\n' "$files" | grep -c .)" = 2 ] \
    || fail "a relaunch must stage its own launch file beside the first, found: $files"
  [ -f "$first" ] && [ "$(cksum < "$first")" = "$first_sum" ] \
    || fail "a relaunch must never rewrite an earlier incarnation's launch file"
  while IFS= read -r f; do
    assert_equals 600 "$(path_mode "$f")" "every staged launch file must be 0600: $f"
  done <<EOF
$files
EOF
  pass "a relaunch stages a new launch file and leaves the earlier one untouched"
}

# The cause, with no shim: every line typed into the pane lands while its shell
# waits on a slow pre-prompt hook, outside its line editor. The launch must still
# arrive whole, with every line typed ahead of it in place.
# Named mutant: type the whole launch command in place of the short line that
# sources its launch file. The command is cut at the canonical-input limit and
# its Enter lost, so no agent ever starts and the spawn fails.
test_spawn_launch_survives_a_slow_prompt_hook() {
  local id=launch-slowhook-z4 out rc runs launch_bytes
  new_case slowhook "$id"
  garble_next 0
  : > "$LAB/hook-runs"
  : > "$LAB/slow-next"
  # Long enough for the hook each typed line triggers to run in turn.
  out=$(CASE_LAUNCH_POLLS=$((SLOW_HOOK_SECONDS * 4 * 8)) run_fm fm-spawn.sh "$id" "$CASE_PROJ" \
    --harness claude --mode no-mistakes --yolo off); rc=$?
  rm -f "$LAB/slow-next"
  expect_code 0 "$rc" "a spawn into a shell with a slow prompt hook should start its agent"$'\n'"$out"$'\n'"$(pane_tail "$id")"
  assert_contains "$out" "spawned $id" "the spawn should report success"
  [ "$(window_state "$id")" = alive ] \
    || fail "a reported spawn must have a running agent (reads $(window_state "$id"))"$'\n'"$(pane_tail "$id")"
  assert_grep "task=$id" "$LAB/agent-starts" "the lines typed ahead of the launch must land too"
  # The case must really exercise the cause: the hook ran for the typed lines,
  # and the launch command the pane ran, which its launch file holds, is longer
  # than the platform keeps for one line of canonical input. That holds for
  # macOS's 1024 bytes; Linux keeps 4096, more than this launch, so there the
  # case proves only that a launch through a slow hook still starts.
  runs=$(wc -l < "$LAB/hook-runs" | tr -d ' ')
  [ "$runs" -ge 3 ] || fail "the pane shell's prompt hook must run for the typed lines (ran $runs times)"
  launch_bytes=$(wc -c < "$(launch_files "$id")" | tr -d ' ')
  if [ "$(uname -s)" = Darwin ]; then
    [ "${launch_bytes:-0}" -gt 1024 ] \
      || fail "the launch must exceed macOS's 1024-byte canonical-input limit for the case to prove anything (it is ${launch_bytes:-0} bytes)"
  fi
  pass "a launch typed while the pane shell runs a slow prompt hook starts the agent"
}

# The longest launch this home really builds - the longest task id in use, an
# effort flag, and an enabled launch-environment allowlist that prepends about
# thirty names - is well past 1024 bytes as a command. The typed line must stay
# far under the platform's canonical-input limit with real margin, not a few
# dozen bytes.
# Named mutant: type the whole launch command in place of the short line.
test_spawn_typed_line_keeps_margin_on_the_longest_launch() {
  local id=blu-orgunit-lock-live-tenant-walkthrough out rc launch_bytes longest n
  new_case margin "$id"
  garble_next 0
  : > "$LAB/typed-lengths"
  : > "$CASE_HOME/config/launch-env-allowlist"
  for n in $(seq 1 30); do printf 'FM_MARGIN_EXTRA_ENV_%s\n' "$n" >> "$CASE_HOME/config/launch-env-allowlist"; done
  out=$(run_fm fm-spawn.sh "$id" "$CASE_PROJ" \
    --harness claude --mode no-mistakes --yolo off --effort xhigh); rc=$?
  expect_code 0 "$rc" "the longest launch should start its agent"$'\n'"$out"$'\n'"$(pane_tail "$id")"
  launch_bytes=$(wc -c < "$(launch_files "$id")" | tr -d ' ')
  [ "${launch_bytes:-0}" -gt 1024 ] \
    || fail "the longest launch must exceed 1024 bytes for the margin to mean anything (it is ${launch_bytes:-0} bytes)"
  longest=$(sort -n "$LAB/typed-lengths" | tail -1)
  [ -n "$longest" ] || fail "the spawn typed no literal line"
  [ "$longest" -le 256 ] \
    || fail "the longest typed line is $longest bytes; it must stay well under the 1024-byte canonical-input limit"
  pass "the longest launch types no line over $longest bytes while the command itself is $launch_bytes"
}

test_spawn_refuses_to_report_a_launch_that_never_started
test_spawn_stages_its_launch_in_a_private_root
test_spawn_refuses_a_task_temp_root_others_can_write
test_relaunch_never_reuses_a_launch_file
test_spawn_recovers_a_launch_cut_once
test_relaunch_clears_a_poisoned_prompt
test_spawn_launch_survives_a_slow_prompt_hook
test_spawn_typed_line_keeps_margin_on_the_longest_launch
