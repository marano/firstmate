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
# unready state and correctly fails that harness's check.
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

HARNESSES=${FM_SEND_INBOX_LIVE_HARNESSES:-'claude codex opencode pi grok kimi muse'}
for h in $HARNESSES; do
  if command -v "$h" >/dev/null 2>&1; then
    check_harness_doorbell "$h"
    [ "$h" != claude ] || check_claude_queued_doorbell
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
