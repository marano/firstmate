#!/usr/bin/env bash
# tests/fm-send-inbox-doorbell-live-e2e.test.sh - the live doorbell guard
# (live-harness-optin family).
#
# The steering inbox's one behavioral assumption is that a real worker agent
# follows the constant self-describing doorbell line: list the inbox, read and
# act on its records in numeric order, then mv each into handled/. A stub can
# only confirm the assumption already
# written into the stub, so per .agents/skills/firstmate-coding-guidelines
# this is proven against every INSTALLED verified harness: each is launched
# idle in an isolated tmux server, steered through the REAL fm-send (durable
# record + doorbell), and must both ACT on the instruction (create a named
# file) and ACKNOWLEDGE it (the mv into handled/), failing loudly with the
# harness name and version.
#
# For claude it also proves the queued shape live: a doorbell rung while the
# worker is mid-turn waits in claude's queue above the composer, the shared
# classifier must read that composer `pending` (not `empty`) while it waits,
# and the queued doorbell must still be delivered and acknowledged when the
# turn ends - the busy case the watcher's stuck-composer alarm must never
# fire on (bin/fm-task-inbox-lib.sh).
#
# It also drives the REAL watcher (bin/fm-watch.sh) against a live claude
# worker whose busy hooks are wired exactly as bin/fm-spawn.sh wires them, for
# the doorbell recovery scenarios of task fm-doorbell-stuck-auto-recovery:
#   1. an idle composer holding exactly firstmate's own unsent doorbell is
#      recovered by one more Enter, and the message is delivered and acked;
#   2. a worker blocked in a long foreground call with a clean composer is
#      never interrupted or rung into, and picks the message up at its own
#      checkpoint;
#   3. composer text firstmate did not write is never submitted, typed over,
#      or cleared, and is reported as such.
# The stranded QUEUED doorbell on an idle worker, and an interrupt that fails
# to clear it, have only been observed in the wild and cannot be produced on
# demand, so they are not driven here (docs/verification/runtime-backends.md
# "Queued claude input" owns that evidence as observational).
# FM_SEND_INBOX_LIVE_CLAUDE_CHECKS selects among "doorbell queue recover busy
# foreign" (default: all).
#
# Run explicitly with FM_SEND_INBOX_LIVE_E2E=1. This test spends a small
# number of real model tokens per installed harness (one short turn each, two
# for claude) - authorized by the harness-dependent-checks rule. An absent harness is
# reported explicitly and skipped; a run that verified nothing fails rather
# than passing vacuously. Restrict with
# FM_SEND_INBOX_LIVE_HARNESSES="claude codex ..." when needed, and tune the
# per-harness wait with FM_SEND_INBOX_LIVE_TIMEOUT (seconds, default 240).
# Record the dated per-harness result in
# docs/verification/runtime-backends.md ("Steering-inbox doorbell").
#
# Folder trust: harnesses launch with the repo root as cwd, which the
# operator's machine has normally already trusted; a trust dialog is a real
# unready state and correctly fails that harness's check. The watcher
# scenarios launch from FM_SEND_INBOX_LIVE_CWD instead when it is set, for a
# checkout (a fresh worktree) the operator has not trusted.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fm_live_gate opt-in FM_SEND_INBOX_LIVE_E2E tmux

unset NO_MISTAKES_GATE

SOCKET="fm-inbox-live-$$"
SESSION="inboxlive"
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-inbox-live.XXXXXX")
LAB=$(cd "$LAB" && pwd)
TIMEOUT=${FM_SEND_INBOX_LIVE_TIMEOUT:-240}
CHECKED=0
FAILED=0

pass() { printf 'ok - %s\n' "$1"; }
note() { printf '# %s\n' "$1"; }

cleanup() {
  [ -z "${LW_PID:-}" ] || kill "$LW_PID" 2>/dev/null || true
  tmux -L "$SOCKET" kill-server 2>/dev/null || true
  rm -rf "$LAB"
}
trap cleanup EXIT

# fm-send and the composer readiness read both reach tmux through bare `tmux`
# calls, so a PATH shim pins them to the private socket.
SHIM_DIR="$LAB/shim"
mkdir -p "$SHIM_DIR"
REAL_TMUX=$(command -v tmux)
cat > "$SHIM_DIR/tmux" <<SH
#!/usr/bin/env bash
exec "$REAL_TMUX" -L "$SOCKET" "\$@"
SH
chmod +x "$SHIM_DIR/tmux"
PATH="$SHIM_DIR:$PATH"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-tmux-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-task-inbox-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-busy-lib.sh"

tmux -L "$SOCKET" new-session -d -s "$SESSION" -x 220 -y 50 -c "$ROOT"

harness_version() {  # <binary>
  "$1" --version 2>/dev/null | head -1 || printf 'version-unknown'
}

# Launch <name> idle with its unattended-autonomy flags (the same posture
# bin/fm-spawn.sh uses), so the doorbell-triggered shell actions need no
# interactive approval.
launch_cmd() {  # <name>
  case "$1" in
    claude) printf '%s' 'CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false CLAUDE_CODE_SEND_FEEDBACK=0 claude --dangerously-skip-permissions --settings '\''{"feedbackDrafts":"off"}'\''' ;;
    codex) printf '%s' 'codex --dangerously-bypass-approvals-and-sandbox' ;;
    opencode) printf '%s' "OPENCODE_CONFIG_CONTENT='{\"permission\":{\"*\":\"allow\"}}' opencode" ;;
    pi|pi-signed) printf '%s' "$1" ;;
    grok) printf '%s' 'grok --always-approve' ;;
    kimi) printf '%s' 'kimi --auto' ;;
    muse) printf '%s' 'MUSE_EXPERIMENTAL_FOREIGN_PERSONAL_CONTEXT_KILL=on muse --yolo' ;;
    *) return 1 ;;
  esac
}

# Wait for the harness to look steerable. 0 = the composer classified a
# proven empty; 2 = the readiness budget expired without an empty verdict but
# also without a pending one. The caller proceeds on 2 with a note, because
# that mirrors production exactly: the send path's composer check is ADVISORY
# and skips only on visibly pending text, so a harness whose idle screen the
# classifier cannot positively identify still gets its doorbell (the composer
# matrix guard, not this one, owns re-proving the classifier per release).
wait_ready() {  # <window>
  local win=$1 i=0 budget=60 verdict dismissed=0 screen
  while [ "$i" -lt "$budget" ]; do
    verdict=$(fm_tmux_composer_state "$SESSION:$win")
    [ "$verdict" = empty ] && return 0
    i=$((i + 1))
    # Dismiss one non-trust startup modal (update prompts), as the composer
    # matrix guard does; never Enter, which could accept an upgrade.
    if [ "$dismissed" -eq 0 ] && [ "$i" -ge $((budget / 3)) ]; then
      screen=$(tmux -L "$SOCKET" capture-pane -p -t "$SESSION:$win" 2>/dev/null || true)
      if ! printf '%s\n' "$screen" | grep -qi 'trust'; then
        tmux -L "$SOCKET" send-keys -t "$SESSION:$win" Escape 2>/dev/null || true
      fi
      dismissed=1
    fi
    sleep 1
  done
  case "$verdict" in
    pending) return 1 ;;
  esac
  return 2
}

check_harness_doorbell() {  # <name>
  local name=$1 version cmd win="hx-$1" home task acted rec handled i ready_rc
  version=$(harness_version "$name")
  cmd=$(launch_cmd "$name") || { note "no launch recipe for $name"; return 0; }
  home="$LAB/$name-home"
  mkdir -p "$home/state"
  task="live-$name"
  acted="$LAB/acted-$name"
  tmux -L "$SOCKET" new-window -d -t "$SESSION:" -n "$win" -c "$ROOT" \
    -- bash -lc "$cmd" \
    || { FAILED=1; printf 'not ok - %s (%s): could not launch in the isolated tmux server\n' "$name" "$version" >&2; return 0; }
  wait_ready "$win"; ready_rc=$?
  if [ "$ready_rc" -eq 1 ]; then
    FAILED=1
    printf 'not ok - %s (%s): composer stayed visibly pending; the pane is not steerable\n' "$name" "$version" >&2
    tmux -L "$SOCKET" capture-pane -p -t "$SESSION:$win" 2>/dev/null | grep '[^[:space:]]' | tail -6 | sed 's/^/#   /' >&2
    tmux -L "$SOCKET" kill-window -t "$SESSION:$win" 2>/dev/null || true
    return 0
  fi
  [ "$ready_rc" -eq 0 ] || note "$name ($version): idle composer never classified empty; proceeding as production does (advisory check skips only on pending)"
  printf 'window=%s:%s\nkind=ship\nharness=%s\n' "$SESSION" "$win" "$name" > "$home/state/$task.meta"
  if ! FM_HOME="$home" FM_ROOT_OVERRIDE="$home" "$ROOT/bin/fm-send.sh" "$task" \
    "Firstmate live check: run exactly this shell command now: touch $acted - then follow the mv instruction you were given for this message. Reply with one short line." \
    >/dev/null 2>&1; then
    FAILED=1
    printf 'not ok - %s (%s): fm-send refused the live steer\n' "$name" "$version" >&2
    tmux -L "$SOCKET" kill-window -t "$SESSION:$win" 2>/dev/null || true
    return 0
  fi
  rec="$home/state/$task.inbox/001.msg"
  handled="$home/state/$task.inbox/handled/001.msg"
  [ -f "$rec" ] || {
    FAILED=1
    printf 'not ok - %s (%s): fm-send left no durable inbox record\n' "$name" "$version" >&2
    tmux -L "$SOCKET" kill-window -t "$SESSION:$win" 2>/dev/null || true
    return 0
  }
  i=0
  while [ "$i" -lt "$TIMEOUT" ]; do
    [ -f "$handled" ] && [ -e "$acted" ] && break
    # Halfway through, play the watcher's role once: re-ring an unacknowledged
    # message so a doorbell swallowed by a startup or update modal recovers
    # exactly as the production re-ring ladder recovers it.
    if [ "$i" -eq $((TIMEOUT / 2)) ] && [ -f "$rec" ]; then
      fm_task_inbox_ring tmux "$SESSION:$win" "$rec" || true
      note "$name ($version): re-rang the doorbell once (watcher's role) at ${i}s"
    fi
    sleep 1
    i=$((i + 1))
  done
  if [ -f "$handled" ] && [ -e "$acted" ]; then
    CHECKED=$((CHECKED + 1))
    pass "$name ($version): the doorbell reached a real worker, which acted and acked with the mv"
  else
    FAILED=1
    printf 'not ok - %s (%s): doorbell not honored within %ss (acted=%s acked=%s)\n' \
      "$name" "$version" "$TIMEOUT" "$([ -e "$acted" ] && echo yes || echo no)" \
      "$([ -f "$handled" ] && echo yes || echo no)" >&2
    tmux -L "$SOCKET" capture-pane -p -t "$SESSION:$win" 2>/dev/null | grep '[^[:space:]]' | tail -10 | sed 's/^/#   /' >&2
  fi
  tmux -L "$SOCKET" kill-window -t "$SESSION:$win" 2>/dev/null || true
}

# claude's queued shape: busy the worker with a foreground command, ring the
# doorbell into it, and require the composer to read pending while the
# doorbell waits in the queue, then the ordinary act-and-acknowledge once the
# turn ends. The queue signals seen are printed so the dated record can say
# which of the classifier's two signals this version drew.
check_claude_queued_doorbell() {
  local version win=hx-claude-queue home task acted rec handled i ready_rc state screen
  version=$(harness_version claude)
  home="$LAB/claude-queue-home"
  mkdir -p "$home/state"
  task=live-claude-queue
  acted="$LAB/acted-claude-queue"
  tmux -L "$SOCKET" new-window -d -t "$SESSION:" -n "$win" -c "$ROOT" \
    -- bash -lc "$(launch_cmd claude)" \
    || { FAILED=1; printf 'not ok - claude queue (%s): could not launch in the isolated tmux server\n' "$version" >&2; return 0; }
  wait_ready "$win"; ready_rc=$?
  [ "$ready_rc" -ne 1 ] || { FAILED=1; printf 'not ok - claude queue (%s): composer stayed visibly pending before the busy turn\n' "$version" >&2; return 0; }
  tmux -L "$SOCKET" send-keys -t "$SESSION:$win" -l \
    "Run this exact shell command in the foreground, not in the background, and wait for it: python3 -c 'import time; time.sleep(40)' - then reply with one short line."
  sleep 0.5
  tmux -L "$SOCKET" send-keys -t "$SESSION:$win" Enter
  i=0
  until [ "$(fm_pane_busy_state "$SESSION:$win" claude)" = busy ]; do
    i=$((i + 1))
    [ "$i" -lt 60 ] || { FAILED=1; printf 'not ok - claude queue (%s): the worker never showed a busy turn\n' "$version" >&2; return 0; }
    sleep 1
  done
  sleep 5
  printf 'window=%s:%s\nkind=ship\nharness=claude\n' "$SESSION" "$win" > "$home/state/$task.meta"
  FM_HOME="$home" FM_ROOT_OVERRIDE="$home" "$ROOT/bin/fm-send.sh" "$task" \
    "Firstmate live check: run exactly this shell command now: touch $acted - then follow the mv instruction you were given for this message. Reply with one short line." \
    >/dev/null 2>&1 || { FAILED=1; printf 'not ok - claude queue (%s): fm-send refused the live steer\n' "$version" >&2; return 0; }
  sleep 2
  state=$(fm_tmux_composer_state "$SESSION:$win")
  screen=$(tmux -L "$SOCKET" capture-pane -p -t "$SESSION:$win" 2>/dev/null || true)
  note "claude ($version) queue signals: placeholder=$(printf '%s\n' "$screen" | grep -cF 'Press up to edit queued messages') hint=$(printf '%s\n' "$screen" | grep -cF 'ctrl+x ctrl+s to send now') busy=$(fm_pane_busy_state "$SESSION:$win" claude)"
  if [ "$state" != pending ]; then
    FAILED=1
    printf 'not ok - claude queue (%s): a doorbell queued behind a busy turn read %s, not pending\n' "$version" "$state" >&2
    printf '%s\n' "$screen" | grep '[^[:space:]]' | tail -10 | sed 's/^/#   /' >&2
    tmux -L "$SOCKET" kill-window -t "$SESSION:$win" 2>/dev/null || true
    return 0
  fi
  rec="$home/state/$task.inbox/001.msg"
  handled="$home/state/$task.inbox/handled/001.msg"
  i=0
  while [ "$i" -lt "$TIMEOUT" ]; do
    [ -f "$handled" ] && [ -e "$acted" ] && break
    sleep 1
    i=$((i + 1))
  done
  if [ -f "$handled" ] && [ -e "$acted" ]; then
    pass "claude ($version): a doorbell queued behind a busy turn reads pending, then submits and is acted on and acked"
  else
    FAILED=1
    printf 'not ok - claude queue (%s): the queued doorbell was not honored within %ss (acted=%s acked=%s)\n' \
      "$version" "$TIMEOUT" "$([ -e "$acted" ] && echo yes || echo no)" "$([ -f "$handled" ] && echo yes || echo no)" >&2
    tmux -L "$SOCKET" capture-pane -p -t "$SESSION:$win" 2>/dev/null | grep '[^[:space:]]' | tail -10 | sed 's/^/#   /' >&2
  fi
  tmux -L "$SOCKET" kill-window -t "$SESSION:$win" 2>/dev/null || true
}

# ---- Live watcher scenarios (real fm-watch.sh, real claude, real hooks) -----

# Launch claude idle with the four lifecycle hooks bin/fm-spawn.sh installs
# (UserPromptSubmit opens a busy turn; Stop, StopFailure, SessionEnd close it),
# so the watcher's semantic busy verdict is the production one. Sets LW_HOME,
# LW_STATE, LW_TASK, LW_WIN. Returns 1 when the pane is not steerable.
live_claude_launch() {  # <name>
  local name=$1 gen prefix suffix settings
  LW_HOME="$LAB/$name-home"; LW_STATE="$LW_HOME/state"
  LW_TASK="live-$name"; LW_WIN="hx-$name"
  mkdir -p "$LW_STATE"
  gen=$("$ROOT/bin/fm-busy-event.sh" arm "$LW_STATE" "$LW_TASK" --state idle --source fm-spawn --event launch-brief) \
    || { FAILED=1; printf 'not ok - claude %s: could not arm the busy-state contract\n' "$name" >&2; return 1; }
  prefix="$ROOT/bin/fm-busy-event.sh apply $LW_STATE $LW_TASK"
  suffix="--gen $gen --source claude-hook"
  settings="$LAB/$name-settings.json"
  cat > "$settings" <<JSON
{"feedbackDrafts":"off","hooks":{"UserPromptSubmit":[{"hooks":[{"type":"command","command":"$prefix busy $suffix --event user-prompt-submit 2>/dev/null || true"}]}],"Stop":[{"hooks":[{"type":"command","command":"$prefix idle $suffix --event stop 2>/dev/null || true"}]}],"StopFailure":[{"hooks":[{"type":"command","command":"$prefix idle $suffix --event stop-failure 2>/dev/null || true"}]}],"SessionEnd":[{"hooks":[{"type":"command","command":"$prefix idle $suffix --event session-end 2>/dev/null || true"}]}]}}
JSON
  printf 'window=%s:%s\nkind=ship\nharness=claude\n' "$SESSION" "$LW_WIN" > "$LW_STATE/$LW_TASK.meta"
  tmux -L "$SOCKET" new-window -d -t "$SESSION:" -n "$LW_WIN" -c "${FM_SEND_INBOX_LIVE_CWD:-$ROOT}" \
    -- bash -lc "CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false CLAUDE_CODE_SEND_FEEDBACK=0 claude --dangerously-skip-permissions --settings $settings" \
    || { FAILED=1; printf 'not ok - claude %s: could not launch in the isolated tmux server\n' "$name" >&2; return 1; }
  wait_ready "$LW_WIN"
  if [ $? -eq 1 ]; then
    FAILED=1
    printf 'not ok - claude %s: composer stayed visibly pending; the pane is not steerable\n' "$name" >&2
    tmux -L "$SOCKET" kill-window -t "$SESSION:$LW_WIN" 2>/dev/null || true
    return 1
  fi
  return 0
}

# The state the watcher reads for the live pane: the recorded semantic verdict.
lw_busy_verdict() {
  fm_busy_classify_meta "$LW_STATE/$LW_TASK.meta" "$LW_TASK" "$LW_STATE" "" 2>/dev/null | awk '{print $1}'
}

# A durable, already-overdue steer whose instruction creates $1.
lw_write_aged_record() {  # <acted-path> -> echoes record path
  local rec
  rec=$(fm_task_inbox_write "$LW_STATE" "$LW_TASK" \
    "Firstmate live check: run exactly this shell command now: touch $1 - then follow the mv instruction you were given for this message. Reply with one short line.") || return 1
  touch -t 202001010000 "$rec"
  printf '%s' "$rec"
}

# The REAL watcher on a fast cadence against this state dir. PID kept in LW_PID.
lw_start_watcher() {  # <ring-max>
  FM_STATE_OVERRIDE="$LW_STATE" FM_POLL=2 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 \
    FM_HEARTBEAT=999999 FM_TASK_INBOX_GRACE_SECS=2 FM_TASK_INBOX_RING_MAX="$1" \
    "$ROOT/bin/fm-watch.sh" > "$LW_HOME/watch.out" 2>&1 &
  LW_PID=$!
}

lw_stop_watcher() {
  [ -z "${LW_PID:-}" ] || { kill "$LW_PID" 2>/dev/null || true; wait "$LW_PID" 2>/dev/null || true; }
  LW_PID=
}

lw_fail() {  # <label> <why>
  FAILED=1
  printf 'not ok - claude (%s) %s: %s\n' "$(harness_version claude)" "$1" "$2" >&2
  tmux -L "$SOCKET" capture-pane -p -t "$SESSION:$LW_WIN" 2>/dev/null | grep '[^[:space:]]' | tail -10 | sed 's/^/#   /' >&2
  [ ! -s "$LW_STATE/.wake-queue" ] || sed 's/^/#   wake: /' "$LW_STATE/.wake-queue" >&2
}

lw_done() {
  lw_stop_watcher
  tmux -L "$SOCKET" kill-window -t "$SESSION:$LW_WIN" 2>/dev/null || true
}

# SCENARIO 1: an idle composer holding exactly firstmate's own unsent doorbell.
check_claude_recovers_own_doorbell() {
  local version acted rec doorbell handled i
  version=$(harness_version claude)
  live_claude_launch recover || return 0
  acted="$LAB/acted-recover"
  rec=$(lw_write_aged_record "$acted") || { FAILED=1; return 0; }
  handled="$LW_STATE/$LW_TASK.inbox/handled/001.msg"
  doorbell=$(fm_task_inbox_doorbell_line "$rec")
  # The state the incident produced: the doorbell typed, its Enter swallowed.
  tmux -L "$SOCKET" send-keys -t "$SESSION:$LW_WIN" -l "$doorbell"
  sleep 1
  if [ "$(fm_tmux_composer_state "$SESSION:$LW_WIN")" != pending ]; then
    lw_fail recover "the unsent doorbell did not read pending, so the scenario was not set up"
    lw_done; return 0
  fi
  lw_start_watcher 3
  i=0
  while [ "$i" -lt "$TIMEOUT" ]; do
    [ -f "$handled" ] && [ -e "$acted" ] && break
    sleep 1
    i=$((i + 1))
  done
  if [ -f "$handled" ] && [ -e "$acted" ] && [ ! -s "$LW_STATE/.wake-queue" ]; then
    CHECKED=$((CHECKED + 1))
    pass "claude ($version): the watcher re-pressed Enter on its own unsent doorbell; delivered, acted on, acked, no wake"
  else
    lw_fail recover "own unsent doorbell not recovered within ${TIMEOUT}s (acted=$([ -e "$acted" ] && echo yes || echo no) acked=$([ -f "$handled" ] && echo yes || echo no))"
  fi
  lw_done
}

# SCENARIO 2: blocked in a long foreground call with a clean composer.
check_claude_busy_is_never_disturbed() {
  local version acted rec handled i busy_polls=0 typed doorbell
  version=$(harness_version claude)
  live_claude_launch busy || return 0
  acted="$LAB/acted-busy"
  handled="$LW_STATE/$LW_TASK.inbox/handled/001.msg"
  # The worker is told, as a brief tells it, to check its inbox at the end of
  # the turn: the checkpoint at which the durable record is collected.
  tmux -L "$SOCKET" send-keys -t "$SESSION:$LW_WIN" -l \
    "Run this exact shell command in the foreground, not in the background, and wait for it: python3 -c 'import time; time.sleep(50)' - then list the directory $LW_STATE/$LW_TASK.inbox, read each .msg in it in numeric order, carry out what it says, and mv it into $LW_STATE/$LW_TASK.inbox/handled/ when done."
  sleep 0.5
  tmux -L "$SOCKET" send-keys -t "$SESSION:$LW_WIN" Enter
  i=0
  until [ "$(lw_busy_verdict)" = busy ]; do
    i=$((i + 1))
    [ "$i" -lt 60 ] || { lw_fail busy "the busy hook never recorded a busy turn"; lw_done; return 0; }
    sleep 1
  done
  sleep 8   # the foreground call is running and its output is seconds old
  rec=$(lw_write_aged_record "$acted") || { FAILED=1; lw_done; return 0; }
  doorbell=$(fm_task_inbox_doorbell_line "$rec")
  lw_start_watcher 1   # a budget of ONE: any delivery attempt would escalate at once
  i=0
  while [ "$i" -lt 25 ]; do
    [ "$(lw_busy_verdict)" = busy ] && busy_polls=$((busy_polls + 1))
    [ -f "$handled" ] && break
    sleep 1
    i=$((i + 1))
  done
  typed=$(tmux -L "$SOCKET" capture-pane -p -t "$SESSION:$LW_WIN" 2>/dev/null | grep -cF "$doorbell" || true)
  if [ "$busy_polls" -lt 10 ]; then
    lw_fail busy "the scenario never held a busy worker across the watcher's polls (busy_polls=$busy_polls)"
  elif [ "$typed" -ne 0 ] || [ -s "$LW_STATE/.wake-queue" ] \
    || tmux -L "$SOCKET" capture-pane -p -t "$SESSION:$LW_WIN" 2>/dev/null | grep -qi 'interrupted'; then
    lw_fail busy "the watcher disturbed a busy worker (doorbell-typed=$typed)"
  else
    i=0
    while [ "$i" -lt "$TIMEOUT" ]; do
      [ -f "$handled" ] && [ -e "$acted" ] && break
      sleep 1
      i=$((i + 1))
    done
    if [ -f "$handled" ] && [ -e "$acted" ] && [ ! -s "$LW_STATE/.wake-queue" ]; then
      CHECKED=$((CHECKED + 1))
      pass "claude ($version): a worker in a long foreground call was never rung into, interrupted, or alarmed on ($busy_polls busy polls), and collected its message at its own checkpoint"
    else
      lw_fail busy "the message never arrived at the worker's own checkpoint (acted=$([ -e "$acted" ] && echo yes || echo no) acked=$([ -f "$handled" ] && echo yes || echo no))"
    fi
  fi
  lw_done
}

# SCENARIO 3: composer text firstmate did not write.
check_claude_foreign_composer_text_is_untouched() {
  local version acted rec doorbell handled i foreign='echo half-written command nobody finished'
  version=$(harness_version claude)
  live_claude_launch foreign || return 0
  acted="$LAB/acted-foreign"
  rec=$(lw_write_aged_record "$acted") || { FAILED=1; return 0; }
  handled="$LW_STATE/$LW_TASK.inbox/handled/001.msg"
  doorbell=$(fm_task_inbox_doorbell_line "$rec")
  tmux -L "$SOCKET" send-keys -t "$SESSION:$LW_WIN" -l "$foreign"
  sleep 1
  lw_start_watcher 2
  i=0
  while [ "$i" -lt 90 ]; do
    grep -qF 'worker cannot receive messages' "$LW_STATE/.wake-queue" 2>/dev/null && break
    sleep 1
    i=$((i + 1))
  done
  local screen
  screen=$(tmux -L "$SOCKET" capture-pane -p -t "$SESSION:$LW_WIN" 2>/dev/null || true)
  if ! grep -qF 'worker cannot receive messages' "$LW_STATE/.wake-queue" 2>/dev/null; then
    lw_fail foreign "foreign composer text was never reported as stopping the worker receiving messages"
  elif ! grep -qF 'firstmate never typed' "$LW_STATE/.wake-queue"; then
    lw_fail foreign "the report did not name the text as not firstmate's"
  elif grep -qF "own doorbell went into" "$LW_STATE/.wake-queue"; then
    lw_fail foreign "foreign text was reported as firstmate's own stranded doorbell"
  elif ! printf '%s\n' "$screen" | grep -qF "$foreign"; then
    lw_fail foreign "the foreign composer text was cleared or altered"
  elif printf '%s\n' "$screen" | grep -qF "$doorbell" || [ -e "$acted" ] || [ -f "$handled" ] \
    || [ "$(lw_busy_verdict)" != idle ]; then
    lw_fail foreign "the watcher typed behind, or submitted, text it did not write"
  else
    CHECKED=$((CHECKED + 1))
    pass "claude ($version): foreign composer text was never submitted, typed over, or cleared, and was reported as text firstmate never typed"
  fi
  lw_done
}

CLAUDE_CHECKS=${FM_SEND_INBOX_LIVE_CLAUDE_CHECKS:-'doorbell queue recover busy foreign'}
HARNESSES=${FM_SEND_INBOX_LIVE_HARNESSES:-'claude codex opencode pi grok kimi muse'}
for h in $HARNESSES; do
  if command -v "$h" >/dev/null 2>&1; then
    case " $CLAUDE_CHECKS " in *" doorbell "*) check_harness_doorbell "$h" ;; esac
    if [ "$h" = claude ]; then
      case " $CLAUDE_CHECKS " in *" queue "*) check_claude_queued_doorbell ;; esac
      case " $CLAUDE_CHECKS " in *" recover "*) check_claude_recovers_own_doorbell ;; esac
      case " $CLAUDE_CHECKS " in *" busy "*) check_claude_busy_is_never_disturbed ;; esac
      case " $CLAUDE_CHECKS " in *" foreign "*) check_claude_foreign_composer_text_is_untouched ;; esac
    fi
  else
    note "harness absent, not verified here: $h"
  fi
done

if [ "$FAILED" -ne 0 ]; then
  printf 'not ok - live steering-inbox doorbell guard found failures above\n' >&2
  exit 1
fi
if [ "$CHECKED" -eq 0 ]; then
  printf 'not ok - live steering-inbox doorbell guard verified nothing (no harness installed?)\n' >&2
  exit 1
fi
pass "live steering-inbox doorbell guard: $CHECKED harness(es) honored the doorbell contract"
