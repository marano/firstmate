#!/usr/bin/env bash
# tests/fm-backend-tmux-smoke.test.sh - real tmux smoke test for the tmux
# session-provider adapter (bin/backends/tmux.sh), the P1 checklist item
# "run a real tmux smoke test (create session, send text + Enter, capture,
# list, kill)" from data/fm-backend-design-d7/report.md. Every other suite in
# this repo fakes tmux; this one is the one place that talks to a REAL tmux
# server, isolated on a private socket (`-L`) so it never touches the host's
# actual sessions.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { printf 'not ok - %s\n' "$1" >&2; cleanup_all; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

wait_for_capture_text() {  # <target> <text> [samples]
  local target=$1 text=$2 samples=${3:-100} out i=0
  while [ "$i" -lt "$samples" ]; do
    out=$(fm_backend_tmux_capture "$target" 200 2>/dev/null || true)
    case "$out" in
      *"$text"*) return 0 ;;
    esac
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

command -v tmux >/dev/null 2>&1 || { echo "skip: tmux not found"; exit 0; }
REAL_TMUX=$(command -v tmux)
SOCKET="fm-backend-smoke-$$"
SHIM_DIR=
trap cleanup_all EXIT

cleanup_all() {
  "$REAL_TMUX" -L "$SOCKET" kill-server >/dev/null 2>&1 || true
  [ -n "${SHIM_DIR:-}" ] && rm -rf "$SHIM_DIR"
}

# A `tmux` shim on PATH that transparently redirects every call to the private
# socket, so bin/backends/tmux.sh's bare `tmux ...` invocations never touch the
# host's real sessions.
SHIM_DIR=$(mktemp -d "${TMPDIR:-/tmp}/fm-backend-smoke.XXXXXX")
cat > "$SHIM_DIR/tmux" <<SH
#!/usr/bin/env bash
exec "$REAL_TMUX" -L "$SOCKET" "\$@"
SH
chmod +x "$SHIM_DIR/tmux"
PATH="$SHIM_DIR:$PATH"
export PATH

# shellcheck source=/dev/null
. "$ROOT/bin/fm-backend.sh"
fm_backend_source tmux || fail "fm_backend_source tmux failed"

SESSION="smoke"
WINDOW="fm-smoke1"
TARGET="$SESSION:$WINDOW"

# --- create session ----------------------------------------------------------

tmux new-session -d -s "$SESSION" -x 200 -y 50 \
  || fail "real tmux: new-session failed"
fm_backend_tmux_create_task "$SESSION" "$WINDOW" "$HOME" \
  || fail "fm_backend_tmux_create_task failed to create the task window"
tmux list-windows -t "$SESSION" -F '#{window_name}' | grep -qx "$WINDOW" \
  || fail "created window is not visible in the real session"

# A second create for the SAME window name must refuse (mirrors fm-spawn.sh's
# duplicate-window guard).
if fm_backend_tmux_create_task "$SESSION" "$WINDOW" "$HOME" 2>/dev/null; then
  fail "fm_backend_tmux_create_task should refuse an existing window name"
fi
pass "real tmux: fm_backend_tmux_create_task creates a window and refuses a duplicate"

# --- send text + Enter -------------------------------------------------------

# A newly-created interactive shell can exist before its startup files and line
# editor are ready to accept Enter. Prove command execution with an output token
# that does not appear contiguously in the command, retrying the harmless probe
# until the shell acknowledges it.
SHELL_READY=false
for _ in $(seq 1 100); do
  tmux send-keys -t "$TARGET" C-c
  tmux send-keys -t "$TARGET" -l "printf 'shell-%s\\n' ready"
  tmux send-keys -t "$TARGET" Enter
  if wait_for_capture_text "$TARGET" "shell-ready" 10; then
    SHELL_READY=true
    break
  fi
done
[ "$SHELL_READY" = true ] || fail "the tmux task shell did not become ready"

tmux send-keys -t "$TARGET" "cd /tmp && PS1='smoke\$ ' && clear && printf 'setup-%s\\n' ready" Enter
wait_for_capture_text "$TARGET" "setup-ready" || fail "the tmux task shell did not complete setup"

fm_backend_tmux_send_text_line "$TARGET" "printf 'captain-on-deck-%s\\n' line" \
  || fail "fm_backend_tmux_send_text_line failed"
wait_for_capture_text "$TARGET" "captain-on-deck-line" \
  || fail "fm_backend_tmux_send_text_line did not execute"
out=$(fm_backend_tmux_capture "$TARGET" 20) || fail "fm_backend_tmux_capture failed after send_text_line"
case "$out" in
  *captain-on-deck-line*) : ;;
  *) fail "real tmux: fm_backend_tmux_send_text_line did not submit and echo the line"$'\n'"$out" ;;
esac
pass "real tmux: fm_backend_tmux_send_text_line sends literal text and submits with Enter"

# --- send_literal + send_key(Enter), the two-step form fm-spawn.sh uses for the
# harness launch command (literal send, settle, then a separate Enter) --------

fm_backend_tmux_send_literal "$TARGET" "printf 'literal-then-key-%s\\n' captain" \
  || fail "fm_backend_tmux_send_literal failed"
fm_backend_tmux_send_key "$TARGET" Enter || fail "fm_backend_tmux_send_key Enter failed"
wait_for_capture_text "$TARGET" "literal-then-key-captain" \
  || fail "fm_backend_tmux_send_literal + fm_backend_tmux_send_key Enter did not execute"
out=$(fm_backend_tmux_capture "$TARGET" 20) || fail "fm_backend_tmux_capture failed after send_literal+send_key"
case "$out" in
  *literal-then-key-captain*) : ;;
  *) fail "real tmux: send_literal + send_key(Enter) did not submit and echo the line"$'\n'"$out" ;;
esac
pass "real tmux: fm_backend_tmux_send_literal + fm_backend_tmux_send_key Enter submit as two separate steps"

# --- capture bounds -----------------------------------------------------------
# Print enough numbered lines to overflow the pane's visible height, then
# confirm a small capture window (-S -N) surfaces only the RECENT tail (the
# earliest lines scroll out of a small window) while a large one reaches back
# far enough to still see the earliest line - the same -S -N bounding fm-peek.sh
# and fm-watch.sh rely on for a bounded, cheap pane read.
fm_backend_tmux_send_text_line "$TARGET" "for i in \$(seq 1 80); do echo tag-line-\$i; done"
wait_for_capture_text "$TARGET" "tag-line-80" \
  || fail "the numbered output did not complete before capture"
small=$(fm_backend_tmux_capture "$TARGET" 3) || fail "fm_backend_tmux_capture (small window) failed"
case "$small" in
  *tag-line-1$'\n'*) fail "a 3-line capture should not still see the very first numbered line"$'\n'"$small" ;;
esac
case "$small" in
  *tag-line-80*) : ;;
  *) fail "a 3-line capture should still contain the most recent output"$'\n'"$small" ;;
esac
large=$(fm_backend_tmux_capture "$TARGET" 200) || fail "fm_backend_tmux_capture (large window) failed"
case "$large" in
  *tag-line-1$'\n'*) : ;;
  *) fail "a 200-line capture should reach back far enough to see the first numbered line"$'\n'"$large" ;;
esac
pass "real tmux: fm_backend_tmux_capture's -S -N bound trims old history for a small window and reaches it for a large one"

# --- resolve_bare_selector (live-window-listing) -----------------------------

resolved=$(fm_backend_tmux_resolve_bare_selector "$WINDOW") \
  || fail "fm_backend_tmux_resolve_bare_selector failed to find the live window"
[ "$resolved" = "$TARGET" ] || fail "fm_backend_tmux_resolve_bare_selector resolved to '$resolved', expected '$TARGET'"
pass "real tmux: fm_backend_tmux_resolve_bare_selector (list-live) finds the created window by name"

if fm_backend_tmux_resolve_bare_selector "no-such-window-xyz" 2>/dev/null; then
  fail "fm_backend_tmux_resolve_bare_selector should fail for a nonexistent window"
fi
pass "real tmux: fm_backend_tmux_resolve_bare_selector fails for a window that does not exist"

# --- kill and recovery-grade missing-window classification ------------------

fm_backend_tmux_kill "$TARGET"
if tmux list-windows -t "$SESSION" -F '#{window_name}' 2>/dev/null | grep -qx "$WINDOW"; then
  fail "fm_backend_tmux_kill did not remove the window"
fi
state=$(fm_backend_agent_state tmux "$TARGET")
[ "$state" = missing ] \
  || fail "a real missing window in a readable session should classify as missing, got '$state'"
# Best-effort contract: killing an already-gone window must not error.
fm_backend_tmux_kill "$TARGET" || fail "fm_backend_tmux_kill on an already-dead target must stay best-effort (never fail)"
pass "real tmux: kill removes the window and the readable session inventory authoritatively classifies it missing"

# --- rebuilding a missing endpoint -------------------------------------------
# A reboot takes the server and every task window down while the task's record
# and worktree survive. The rebuild must land under the exact recorded session
# and window name, in the worktree, and must refuse beside anything that could
# still own the task. This is where the exact-session target syntax, the pane
# listing, and tmux's own no-server error text are proven against real tmux.

WT="$SHIM_DIR/wt"
mkdir -p "$WT"
WT_REAL=$(cd "$WT" && pwd -P)

wait_for_pane_path() {  # <target> <path>
  local i=0 seen
  while [ "$i" -lt 100 ]; do
    seen=$(fm_backend_tmux_current_path "$1")
    [ -n "$seen" ] && [ "$(cd "$seen" 2>/dev/null && pwd -P)" = "$2" ] && return 0
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

window_count() {  # <session> <window>
  tmux list-windows -t "=$1" -F '#{window_name}' 2>/dev/null | grep -cx "$2" || true
}

fm_backend_recreate_task_endpoint tmux "$TARGET" "$WT" >/dev/null \
  || fail "a missing window in a live session was not rebuilt"
[ "$(window_count "$SESSION" "$WINDOW")" = 1 ] || fail "the rebuilt window is not in the recorded session"
[ "$(tmux show-window-options -v -t "=$SESSION:=$WINDOW" automatic-rename 2>/dev/null)" = off ] \
  || fail "the rebuilt window's name is not pinned"
wait_for_pane_path "$TARGET" "$WT_REAL" || fail "the rebuilt window's pane is not in the recorded worktree"
if fm_backend_recreate_task_endpoint tmux "$TARGET" "$WT" 2>/dev/null; then
  fail "an endpoint that is no longer missing was rebuilt a second time"
fi
[ "$(window_count "$SESSION" "$WINDOW")" = 1 ] || fail "a refused rebuild added a second window"
pass "real tmux: a missing window is rebuilt pinned and in the worktree, and never twice"

fm_backend_tmux_kill "$TARGET"
tmux new-window -d -t "=$SESSION:" -n bystander -c "$WT" || fail "could not open a pane in the worktree"
if fm_backend_recreate_task_endpoint tmux "$TARGET" "$WT" 2>/dev/null; then
  fail "an endpoint was rebuilt while another pane sat in its worktree"
fi
[ "$(window_count "$SESSION" "$WINDOW")" = 0 ] || fail "a refused rebuild created the window anyway"
tmux kill-window -t "=$SESSION:=bystander"
tmux new-session -d -s elsewhere -n "$WINDOW" -c "$HOME" || fail "could not open a same-named window elsewhere"
if fm_backend_recreate_task_endpoint tmux "$TARGET" "$WT" 2>/dev/null; then
  fail "an endpoint was rebuilt while its window name lived in another session"
fi
[ "$(window_count "$SESSION" "$WINDOW")" = 0 ] || fail "a refused rebuild created the window anyway"
tmux kill-session -t "=elsewhere"
pass "real tmux: a missing endpoint is never rebuilt beside a pane in its worktree or a same-named window"

# The whole server gone, with a session whose name the recorded one prefixes
# started afterwards: tmux resolves a bare session name by prefix, so only an
# exact-session rebuild lands in the recorded session.
tmux kill-server
[ "$(fm_backend_agent_state tmux "$TARGET")" = missing ] || fail "an endpoint on a dead server is not missing"
fm_backend_recreate_task_endpoint tmux "$TARGET" "$WT" >/dev/null \
  || fail "an endpoint whose whole server is gone was not rebuilt"
[ "$(window_count "$SESSION" "$WINDOW")" = 1 ] || fail "the server-gone rebuild missed the recorded session"
wait_for_pane_path "$TARGET" "$WT_REAL" || fail "the server-gone rebuild's pane is not in the recorded worktree"
tmux new-session -d -s "${SESSION}2" -c "$HOME" || fail "could not start a prefix-sibling session"
tmux kill-session -t "=$SESSION"
fm_backend_recreate_task_endpoint tmux "$TARGET" "$WT" >/dev/null \
  || fail "an endpoint whose session is gone was not rebuilt beside a prefix sibling"
[ "$(window_count "$SESSION" "$WINDOW")" = 1 ] || fail "the rebuild did not recreate the exact recorded session"
[ "$(window_count "${SESSION}2" "$WINDOW")" = 0 ] || fail "the rebuild landed in a prefix-sibling session"
pass "real tmux: a missing server or session is rebuilt under the exact recorded session"

tmux kill-server
rm -rf "$WT"
if fm_backend_recreate_task_endpoint tmux "$TARGET" "$WT" 2>/dev/null; then
  fail "an endpoint was rebuilt for a worktree that no longer exists"
fi
if tmux list-sessions >/dev/null 2>&1; then
  fail "a refused rebuild started a tmux server"
fi
pass "real tmux: a missing endpoint is never rebuilt without its worktree"

cleanup_all
trap - EXIT
