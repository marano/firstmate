#!/usr/bin/env bash
# tests/fm-afk-inject-e2e.test.sh - private-socket end-to-end test for the afk
# daemon's injection path. It covers three operator-visible injection contracts:
#
#   Scenario A (human-partial-input): a partial line is typed into the
#     supervisor pane with NO Enter, then an escalation fires. The daemon must
#     DEFER (not merge the digest into the human's text). After the pane goes
#     idle, the digest arrives as a separate, clean submission.
#
#   Scenario B (swallowed-Enter): the first Enter the daemon sends is dropped.
#     The daemon must retry Enter (NOT retype the digest) and deliver exactly
#     ONE clean submission: no concatenation, no duplicate.
#
#   Scenario C (normal digest): no human input and no swallowed Enter.
#     A captain-relevant status must deliver exactly ONE sentinel-prefixed,
#     single-line digest with no duplicate or spurious user submission, and it
#     must END with the trailing sentinel.
#
#   Scenario D (shutdown cannot confirm): escalations are buffered and every
#     Enter is swallowed, so no submit can be confirmed, when the daemon is
#     stopped with away mode still on. The shutdown must type NOTHING into the
#     supervisor composer and leave the buffer intact for the next supervisor
#     (the 2026-09-17 ghost-text incident).
#
#   Scenario E (own digest stranded): a claude-shaped composer strips the
#     digest's invisible marks, swallows its Enter, and reads `unknown`. The
#     daemon must resubmit its OWN digest (Enter only) in the same flush, and
#     a digest an earlier flush stranded must be resubmitted by the next one,
#     while text the captain typed is never submitted or changed (the
#     2026-09-18 overnight wedge).
#
#   Scenario F (unprovable stranded digest past max-defer): captain text sits
#     after the stranded digest, so the daemon cannot prove the composer holds
#     only its own text. A daemon running as the harness's tracked background
#     job must hand the undelivered events back to firstmate through its own
#     exit and clear the daemon flag, never touching the composer; a daemon
#     launched into its own terminal keeps the wedge alarm as its floor.
#
# Isolation: all test tmux runs on a dedicated socket (tmux -L afk-e2e-<pid>).
# A tmux shim first on PATH redirects the daemon's bare `tmux` calls to the
# private socket. The daemon points at a throwaway state dir (FM_STATE_OVERRIDE)
# and the test pane (FM_SUPERVISOR_TARGET). Nothing touches the live fleet.
# FM_SUPERVISOR_BACKEND=tmux is passed explicitly (not left to auto-detection):
# this test's own process may itself be running inside herdr (HERDR_ENV=1 is
# inherited by every process herdr manages a pane for), which would otherwise
# leak into the spawned daemon subprocess and misdetect backend=herdr against
# what is actually a tmux pane on the private socket.
#
# Assert on submitted CONTENT (logged verbatim by the supervisor pane), not pane
# appearance - terminal line-wrapping looks like newlines but isn't.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DAEMON="$ROOT/bin/fm-supervise-daemon.sh"

# Skip gracefully if tmux is not installed.
command -v tmux >/dev/null 2>&1 || { echo "skip: tmux not found"; exit 0; }

REAL_TMUX=$(command -v tmux)
SOCKET="afk-e2e-$$"
STATE_DIR=
TMUX_SHIM_DIR=
LOG_FILE=
DAEMON_PID=
SUPERVISOR_PANE=
LOOP_SCRIPT=

fail() { printf 'not ok - %s\n' "$1" >&2; cleanup_all; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

cleanup_all() {
  if [ -n "${DAEMON_PID:-}" ]; then
    afk_exit "${STATE_DIR:-}" 2>/dev/null || true
    kill "$DAEMON_PID" 2>/dev/null || true
    wait "$DAEMON_PID" 2>/dev/null || true
  fi
  if [ -n "${SOCKET:-}" ] && [ -n "${REAL_TMUX:-}" ]; then
    "$REAL_TMUX" -L "$SOCKET" kill-server 2>/dev/null || true
  fi
  rm -rf "${TMUX_SHIM_DIR:-}" 2>/dev/null || true
  rm -rf "${STATE_DIR:-}" 2>/dev/null || true
}
trap cleanup_all EXIT

# --- setup ------------------------------------------------------------------

STATE_DIR=$(mktemp -d "${TMPDIR:-/tmp}/fm-afk-e2e.XXXXXX")
mkdir -p "$STATE_DIR"
LOG_FILE="$STATE_DIR/submitted.log"
: > "$LOG_FILE"

# Source the daemon to get FM_INJECT_MARK, afk_enter, afk_exit.
# shellcheck source=/dev/null
. "$DAEMON"

# Private tmux server with a supervisor session.
"$REAL_TMUX" -L "$SOCKET" new-session -d -s supervisor -x 200 -y 50
SUPERVISOR_PANE=$("$REAL_TMUX" -L "$SOCKET" display-message -p -t supervisor '#{pane_id}')

# Supervisor pane loop: a small deterministic composer that logs each submitted
# line verbatim (hex + text + classification). It draws the in-progress input
# itself instead of relying on the terminal driver's canonical-mode echo, because
# tmux cursor placement for that echo varies across CI environments.
LOOP_SCRIPT="$STATE_DIR/supervisor-loop.sh"
cat > "$LOOP_SCRIPT" <<'LOOP'
#!/usr/bin/env bash
MARK=$'\xE2\x81\xA3'
LOG="$1"
OLD_STTY=$(stty -g 2>/dev/null || true)
[ -z "$OLD_STTY" ] || stty -echo -icanon min 1 time 0 2>/dev/null || true
cleanup() {
  [ -z "$OLD_STTY" ] || stty "$OLD_STTY" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

_buf=
# The drawn composer row carries a real agent prompt glyph, matching the
# production supervisor pane this daemon injects into: under the strict
# container-proof rule (captain decision blank-row-injection-posture) a bare
# unidentified row is never a safe injection target, so the fixture must
# render the shape the classifier positively proves - "❯ " when idle,
# "❯ <buffer>" while input is pending. The glyph is rendering only; it never
# enters the buffer, so submitted-content assertions are unchanged.
redraw() {
  printf '\r\033[K\xe2\x9d\xaf %s' "$_buf"
  # The composer's pending text, exactly: what a later keystroke would submit.
  printf '%s' "$_buf" > "$LOG.composer"
}
submit_line() {
  local _line=$_buf _c _hex
  if [ "${_line:0:1}" = "$MARK" ]; then
    _c="injection"
  else
    _c="user"
  fi
  _hex=$(printf '%s' "$_line" | od -An -tx1 | tr -d ' \n')
  printf '%s\t%s\t%s\n' "$_hex" "$_line" "$_c" >> "$LOG"
  _buf=
  printf '\r\033[K\n'
  redraw
}

redraw
while IFS= read -r -n 1 _ch; do
  if [ -z "$_ch" ]; then
    submit_line
    continue
  fi
  case "$_ch" in
    $'\r'|$'\n') submit_line ;;
    $'\177'|$'\b') _buf=${_buf%?}; redraw ;;
    *) _buf="${_buf}${_ch}"; redraw ;;
  esac
done
LOOP
chmod +x "$LOOP_SCRIPT"

# Start the loop in the supervisor pane.
"$REAL_TMUX" -L "$SOCKET" send-keys -t "$SUPERVISOR_PANE" \
  "bash '$LOOP_SCRIPT' '$LOG_FILE'" Enter
sleep 1  # let the loop start and settle

# tmux shim: redirects bare `tmux` to the private socket. Optionally swallows
# the first Enter (file-based flag) for Scenario B, or every Enter for
# Scenario D.
TMUX_SHIM_DIR=$(mktemp -d "${TMPDIR:-/tmp}/fm-shim.XXXXXX")
cat > "$TMUX_SHIM_DIR/tmux" <<SHIM
#!/usr/bin/env bash
if [ "\${1:-}" = "send-keys" ] && [ -f "$STATE_DIR/.swallow-all-enter" ]; then
  shift
  _args=()
  for _arg in "\$@"; do
    [ "\$_arg" = "Enter" ] && continue
    _args+=("\$_arg")
  done
  [ "\${#_args[@]}" -gt 0 ] || exit 0
  exec "$REAL_TMUX" -L "$SOCKET" send-keys "\${_args[@]}"
fi
if [ "\${1:-}" = "send-keys" ] && [ -f "$STATE_DIR/.swallow-enter" ]; then
  shift
  _args=()
  for _arg in "\$@"; do
    if [ "\$_arg" = "Enter" ] && [ -f "$STATE_DIR/.swallow-enter" ]; then
      rm -f "$STATE_DIR/.swallow-enter"
      continue
    fi
    _args+=("\$_arg")
  done
  exec "$REAL_TMUX" -L "$SOCKET" send-keys "\${_args[@]}"
fi
exec "$REAL_TMUX" -L "$SOCKET" "\$@"
SHIM
chmod +x "$TMUX_SHIM_DIR/tmux"

# Create a fake crewmate window (the watcher lists fm-* windows for stale
# detection). The pane is an inert shell - it just needs to exist.
"$REAL_TMUX" -L "$SOCKET" new-window -d -n fm-fake-c1 -t supervisor

start_daemon() {
  PATH="$TMUX_SHIM_DIR:$PATH" \
  FM_STATE_OVERRIDE="$STATE_DIR" \
  FM_SUPERVISOR_TARGET="$SUPERVISOR_PANE" \
  FM_SUPERVISOR_BACKEND=tmux \
  FM_ESCALATE_BATCH_SECS="${E2E_ESCALATE_BATCH_SECS:-0}" \
  FM_HOUSEKEEPING_TICK=1 \
  FM_POLL=1 \
  FM_SIGNAL_GRACE=1 \
  FM_HEARTBEAT=999999 \
  FM_CHECK_INTERVAL=999999 \
  FM_INJECT_CONFIRM_SLEEP=0.3 \
  FM_INJECT_CONFIRM_RETRIES=5 \
  FM_STALE_ESCALATE_SECS=999999 \
  nohup "$DAEMON" >"$STATE_DIR/daemon.out" 2>"$STATE_DIR/daemon.err" &
  DAEMON_PID=$!
  # Wait for the daemon to start and acquire the lock.
  local i=0
  while [ "$i" -lt 30 ]; do
    [ -f "$STATE_DIR/.supervise-daemon.pid" ] && break
    sleep 0.2
    i=$((i + 1))
  done
  [ -f "$STATE_DIR/.supervise-daemon.pid" ] || {
    echo "daemon stderr:" >&2; cat "$STATE_DIR/daemon.err" >&2
    fail "daemon did not start (no pid file after 6s)"
  }
}

stop_daemon() {
  [ -n "${DAEMON_PID:-}" ] || return 0
  afk_exit "$STATE_DIR" 2>/dev/null || true
  kill "$DAEMON_PID" 2>/dev/null || true
  wait "$DAEMON_PID" 2>/dev/null || true
  DAEMON_PID=""
  sleep 1
}

reset_state() {
  # Clear daemon and watcher state for a fresh scenario.
  rm -f "$STATE_DIR"/*.status \
         "$STATE_DIR"/.subsuper-* \
         "$STATE_DIR"/.wake-queue* \
         "$STATE_DIR"/.watch.lock* \
         "$STATE_DIR"/.watcher-down* \
         "$STATE_DIR"/.last-* \
         "$STATE_DIR"/.hash-* \
         "$STATE_DIR"/.count-* \
         "$STATE_DIR"/.stale-* \
         "$STATE_DIR"/.seen-* \
         "$STATE_DIR"/.heartbeat-streak \
         "$STATE_DIR"/.swallow-enter \
         "$STATE_DIR"/.swallow-all-enter \
         "$STATE_DIR"/.supervise-daemon.log \
         2>/dev/null || true
  : > "$LOG_FILE"
}

# Submitted operational headers (U+2063 FIRSTMATE_OP: ) across the log. Each
# digest also carries a U+2063 trailing sentinel, so counting bare U+2063 bytes
# would count every digest twice.
HEADER_HEX=$(printf '%s' "$FM_OPERATIONAL_PREFIX" | od -An -tx1 | tr -d ' \n')
TAIL_HEX=$(printf '%s' " ${FM_OPERATIONAL_TAIL_PREFIX}away-supervisor" | od -An -tx1 | tr -d ' \n')
header_count() {
  awk -F '\t' -v h="$HEADER_HEX" '{ hex=$1; count += gsub(h, "", hex) } END { print count + 0 }' "$LOG_FILE"
}

# --- pane_input_pending environment self-check ------------------------------
# Verify that pane_input_pending (which uses cursor_y + capture-pane) can detect
# typed text in this tmux environment. If it can't, the e2e cannot prove the
# operator-visible injection contracts it owns.

selfcheck_pane_input_pending() {
  local check_text="selfcheck-marker-12345"
  "$REAL_TMUX" -L "$SOCKET" send-keys -t "$SUPERVISOR_PANE" -l "$check_text"
  if wait_for_pane_input_pending; then
    # Detected - clean up the text and proceed.
    "$REAL_TMUX" -L "$SOCKET" send-keys -t "$SUPERVISOR_PANE" Enter
    sleep 0.3
    return 0
  fi
  # Not detected - print diagnostics and fail.
  echo "pane_input_pending cannot detect typed text in this tmux environment" >&2
  local _cy _line
  _cy=$("$REAL_TMUX" -L "$SOCKET" display-message -p -t "$SUPERVISOR_PANE" '#{cursor_y}' 2>/dev/null)
  echo "  cursor_y=$_cy" >&2
  echo "  pane capture (first 10 lines):" >&2
  "$REAL_TMUX" -L "$SOCKET" capture-pane -p -t "$SUPERVISOR_PANE" 2>/dev/null | head -10 | sed 's/^/    /' >&2
  _line=$("$REAL_TMUX" -L "$SOCKET" capture-pane -p -t "$SUPERVISOR_PANE" 2>/dev/null | sed -n "$((_cy + 1))p")
  echo "  cursor line: '$_line'" >&2
  "$REAL_TMUX" -L "$SOCKET" send-keys -t "$SUPERVISOR_PANE" Enter
  fail "pane_input_pending self-check failed"
}

wait_for_pane_input_pending() {
  local i=0
  while [ "$i" -lt 30 ]; do
    if PATH="$TMUX_SHIM_DIR:$PATH" pane_input_pending "$SUPERVISOR_PANE"; then
      return 0
    fi
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

selfcheck_pane_input_pending

# --- Scenario A: human-partial-input ----------------------------------------

test_scenario_a() {
  reset_state
  afk_enter "$STATE_DIR"
  start_daemon

  # Type partial text into the supervisor pane with NO Enter. This simulates the
  # captain returning and starting to type before afk has been cleared.
  "$REAL_TMUX" -L "$SOCKET" send-keys -t "$SUPERVISOR_PANE" -l "human draft text"
  wait_for_pane_input_pending \
    || fail "Scenario A: human draft text did not become detectable as pending input"

  # Write a captain-relevant status to trigger a real escalation through the
  # real watcher child.
  echo "done: PR https://example.test/pr/100" > "$STATE_DIR/fake-c1.status"

  # Wait for the watcher to detect the change and the daemon to attempt inject.
  sleep 6

  # Assert: the digest was NOT injected while the pane had pending input.
  if grep -q 'Supervisor escalate' "$LOG_FILE"; then
    fail "Scenario A: daemon injected while pane had pending input (merged with human text?)"
  fi

  # Assert: no merged line (human text + digest) was submitted.
  if grep -q 'human draft text.*Supervisor escalate' "$LOG_FILE" 2>/dev/null || \
     grep -q 'Supervisor escalate.*human draft text' "$LOG_FILE" 2>/dev/null; then
    fail "Scenario A: human text and digest were merged into one line"
  fi

  # Now submit the human's text (Enter). The pane goes idle.
  "$REAL_TMUX" -L "$SOCKET" send-keys -t "$SUPERVISOR_PANE" Enter
  sleep 0.5

  # Wait for the daemon to retry injection (housekeeping tick = 1s).
  sleep 6

  # Assert: human text was submitted alone (as a user message).
  grep -q 'human draft text' "$LOG_FILE" \
    || fail "Scenario A: human text not in log after submit"

  # Assert: digest arrived after the pane went idle.
  grep -q 'Supervisor escalate' "$LOG_FILE" \
    || fail "Scenario A: digest not injected after pane went idle"

  # Assert: human text and digest are on SEPARATE lines (never merged).
  if grep -q 'human draft text.*Supervisor escalate' "$LOG_FILE" || \
     grep -q 'Supervisor escalate.*human draft text' "$LOG_FILE"; then
    fail "Scenario A: human text and digest merged into one line (after idle)"
  fi

  # Assert: the human text line is classified as "user", not "injection".
  local human_line
  human_line=$(grep 'human draft text' "$LOG_FILE" | head -1)
  case "$human_line" in
    *user) ;;  # correct
    *) fail "Scenario A: human text misclassified (expected user): $human_line" ;;
  esac

  # Assert: the digest line is classified as "injection".
  local digest_line
  digest_line=$(grep 'Supervisor escalate' "$LOG_FILE" | head -1)
  case "$digest_line" in
    *injection) ;;  # correct
    *) fail "Scenario A: digest misclassified (expected injection): $digest_line" ;;
  esac

  stop_daemon
  pass "Scenario A: partial input defers injection; digest arrives clean after idle"
}

# --- Scenario B: swallowed-Enter --------------------------------------------

test_scenario_b() {
  reset_state
  afk_enter "$STATE_DIR"

  # Arm the swallow: the daemon's first Enter will be dropped by the shim.
  touch "$STATE_DIR/.swallow-enter"

  start_daemon

  # Write a captain-relevant status to trigger a real escalation.
  echo "done: PR https://example.test/pr/200" > "$STATE_DIR/fake-c1.status"

  # Wait for the daemon to process the escalation and attempt inject (with the
  # swallowed Enter, the retry path fires).
  sleep 8

  # Assert: exactly ONE operational header in the log (no duplicate, no loss).
  local marker_count
  marker_count=$(header_count)
  [ "$marker_count" -eq 1 ] \
    || fail "Scenario B: expected exactly 1 operational header, got $marker_count (duplicate or lost)"

  # Assert: the digest line is classified as "injection" and starts with the
  # terminal-safe sentinel marker (hex starts with e281a3).
  local digest_line digest_hex
  digest_line=$(grep 'Supervisor escalate' "$LOG_FILE" | head -1)
  digest_hex=$(printf '%s' "$digest_line" | cut -f1)
  case "$digest_hex" in
    e281a3*) ;;  # correct: starts with the terminal-safe sentinel marker
    *) fail "Scenario B: digest does not start with sentinel marker (hex: $digest_hex)" ;;
  esac

  # Assert: exactly ONE user-message line was submitted (no spurious empty lines
  # from extra Enters). The log should have exactly 1 injection line and 0 user
  # lines.
  local user_count
  user_count=$(grep -c $'\tuser$' "$LOG_FILE" || true)
  [ "$user_count" -eq 0 ] \
    || fail "Scenario B: expected 0 user lines, got $user_count (spurious Enter submitted empty line?)"

  stop_daemon
  pass "Scenario B: swallowed Enter produces exactly one clean digest"
}

# --- Scenario C: normal status, single clean digest -------------------------
# No human input, no swallowed Enter: a captain-relevant status must produce
# exactly ONE sentinel-prefixed, single-line digest, submitted once. This owns
# the marker + single-line + no-duplicate operator contract that the deleted
# fake-tmux units used to assert via internal send-keys counts.

test_scenario_c() {
  reset_state
  afk_enter "$STATE_DIR"
  start_daemon

  echo "done: PR https://example.test/pr/300" > "$STATE_DIR/fake-c1.status"
  sleep 6

  # Exactly one operational header in the submitted log (no duplicate, no loss).
  local marker_count
  marker_count=$(header_count)
  [ "$marker_count" -eq 1 ] \
    || fail "Scenario C: expected exactly 1 operational header, got $marker_count"

  # The digest is classified as an injection and starts with the sentinel byte.
  local digest_line digest_hex
  digest_line=$(grep 'Supervisor escalate' "$LOG_FILE" | head -1)
  case "$digest_line" in
    *injection) ;;
    *) fail "Scenario C: digest misclassified (expected injection): $digest_line" ;;
  esac
  digest_hex=$(printf '%s' "$digest_line" | cut -f1)
  case "$digest_hex" in
    e281a3*) ;;
    *) fail "Scenario C: digest does not start with sentinel marker (hex: $digest_hex)" ;;
  esac

  # The digest was submitted as ONE line (a multi-line digest would log >1 line),
  # and no spurious user-classified lines were submitted.
  local user_count
  user_count=$(grep -c $'\tuser$' "$LOG_FILE" || true)
  [ "$user_count" -eq 0 ] \
    || fail "Scenario C: expected 0 user lines, got $user_count (spurious submission?)"

  # The digest ENDS with the trailing sentinel, so a front truncation that
  # destroys the leading marker still leaves proof of machine origin.
  case "$digest_hex" in
    *"$TAIL_HEX") ;;
    *) fail "Scenario C: digest does not end with the trailing sentinel (hex: $digest_hex)" ;;
  esac

  stop_daemon
  pass "Scenario C: a normal captain status injects exactly one clean single-line sentinel digest"
}

# --- Scenario D: shutdown with an unconfirmable submit ----------------------
# The 2026-09-17 incident: the daemon deferred a digest while the captain's
# pane was busy, was stopped, and its shutdown flush typed the digest into a
# composer it could no longer confirm. The text sat there as ghost text until a
# later keystroke submitted it, front-truncated past its marker, and firstmate
# read it as the captain returning. Every Enter is swallowed here, so any typed
# digest could only be left unconfirmed in the composer.

test_scenario_d() {
  reset_state
  afk_enter "$STATE_DIR"
  E2E_ESCALATE_BATCH_SECS=999999 start_daemon

  # Buffered escalations the live loop will not flush before the stop.
  printf '%s\n' "fm-main-green.status: working: nothing outside the five files touched" \
    "done: PR https://example.test/pr/400" > "$STATE_DIR/.subsuper-escalations"
  date +%s > "$STATE_DIR/.subsuper-escalations.since"
  cp "$STATE_DIR/.subsuper-escalations" "$STATE_DIR/escalations.before"
  touch "$STATE_DIR/.swallow-all-enter"
  sleep 2

  # The correct-ordered stop: SIGTERM while away mode is still on.
  kill -TERM "$DAEMON_PID" 2>/dev/null || true
  wait "$DAEMON_PID" 2>/dev/null || true
  DAEMON_PID=""
  sleep 1

  # The fixture composer records its pending text on every keystroke, so this
  # is exactly what a later keystroke would submit (the pane's scrollback still
  # shows earlier scenarios' wrapped digests and cannot answer that).
  [ ! -s "$LOG_FILE.composer" ] \
    || fail "Scenario D: the shutdown left text in the supervisor composer: $(cat "$LOG_FILE.composer")"
  [ ! -s "$LOG_FILE" ] || fail "Scenario D: the shutdown submitted input: $(cat "$LOG_FILE")"
  cmp -s "$STATE_DIR/escalations.before" "$STATE_DIR/.subsuper-escalations" \
    || fail "Scenario D: the shutdown did not leave the escalation buffer intact"
  [ -s "$STATE_DIR/.subsuper-escalations.since" ] \
    || fail "Scenario D: the shutdown dropped the buffer's age sidecar"
  grep -F "shutdown: retained 2 buffered escalation(s)" "$STATE_DIR/.supervise-daemon.log" >/dev/null \
    || fail "Scenario D: the daemon log does not record the retained buffer"
  rm -f "$STATE_DIR/.swallow-all-enter"
  afk_exit "$STATE_DIR"
  pass "Scenario D: a shutdown that cannot confirm a submit types nothing and retains the buffer"
}

# --- Scenario E: the daemon's own digest stranded in a claude-shaped composer
# The 2026-09-18 overnight wedge. Claude Code strips the digest's invisible
# U+2063 operational marks and swallows the Enter that should submit it
# ("review and press Enter to send"), and the wrapped digest in its composer
# reads `unknown`: a continuation row that ends in the digest's own ` | `
# separator looks like a structural box edge. The submit core retried Enter
# only on `pending`, so the text stayed in the composer and every later
# injection deferred on "composer not confirmed-empty" for 7.4 hours.
# This fixture draws that measured shape deterministically: the claude-style
# bare `❯` composer between two rules, wrapped at each separator so a
# continuation row ends in ` |` at any width and under either platform's
# `wc -l` padding, with the invisible marks stripped and the next Enter
# swallowed. The real-harness proof of the wrap is the live composer guard
# (tests/fm-composer-matrix-live-e2e.test.sh).
CLAUDE_LOOP="$STATE_DIR/claude-composer-loop.sh"
CLAUDE_LOG="$STATE_DIR/claude-submitted.log"
cat > "$CLAUDE_LOOP" <<'LOOP'
#!/usr/bin/env bash
MARK=$'\xE2\x81\xA3'
LOG="$1"
RULE=$(printf '%0.s─' $(seq 1 100))
OLD_STTY=$(stty -g 2>/dev/null || true)
[ -z "$OLD_STTY" ] || stty -echo -icanon min 1 time 0 2>/dev/null || true
cleanup() {
  [ -z "$OLD_STTY" ] || stty "$OLD_STTY" 2>/dev/null || true
}
trap cleanup EXIT INT TERM
_buf=
_armed=0
_notice=
redraw() {
  local rest=$_buf i last
  local -a rows=()
  while :; do
    case "$rest" in
      *' | '*) rows+=("${rest%%' | '*} |"); rest=${rest#*' | '} ;;
      *) rows+=("$rest"); break ;;
    esac
  done
  printf '\033[H\033[2J'
  printf '\xe2\x8f\xba fixture transcript\r\n\r\n%s\r\n' "$RULE"
  for i in "${!rows[@]}"; do
    if [ "$i" -eq 0 ]; then
      printf '\xe2\x9d\xaf %s\r\n' "${rows[i]}"
    else
      printf '  %s\r\n' "${rows[i]}"
    fi
  done
  printf '%s\r\n  manual mode on    %s' "$RULE" "$_notice"
  last=$((${#rows[@]} - 1))
  printf '\033[%d;%dH' "$((4 + last))" "$((3 + ${#rows[last]}))"
  printf '%s' "$_buf" > "$LOG.composer"
}
submit_line() {
  if [ "$_armed" = 1 ]; then
    _armed=0
    redraw
    return 0
  fi
  printf '%s\n' "$_buf" >> "$LOG"
  _buf=
  _notice=
  redraw
}
redraw
while IFS= read -r -n 1 _ch; do
  if [ -z "$_ch" ]; then
    submit_line
    continue
  fi
  case "$_ch" in
    $'\r'|$'\n') submit_line ;;
    $'\177'|$'\b') _buf=${_buf%?}; redraw ;;
    *)
      _buf="${_buf}${_ch}"
      case "$_buf" in
        *"$MARK"*)
          _buf=${_buf//"$MARK"/}
          _armed=1
          _notice='Removed invisible characters - review and press Enter to send'
          ;;
      esac
      redraw
      ;;
  esac
done
LOOP
chmod +x "$CLAUDE_LOOP"
"$REAL_TMUX" -L "$SOCKET" new-session -d -s claudesup -x 240 -y 50
CLAUDE_PANE=$("$REAL_TMUX" -L "$SOCKET" display-message -p -t claudesup '#{pane_id}')

claude_fixture_restart() {
  : > "$CLAUDE_LOG"
  rm -f "$CLAUDE_LOG.composer"
  "$REAL_TMUX" -L "$SOCKET" respawn-pane -k -t "$CLAUDE_PANE" "bash '$CLAUDE_LOOP' '$CLAUDE_LOG'"
  local i=0
  while [ "$i" -lt 50 ] && [ ! -e "$CLAUDE_LOG.composer" ]; do
    sleep 0.1
    i=$((i + 1))
  done
  [ -e "$CLAUDE_LOG.composer" ] || fail "Scenario E: the claude-shaped fixture composer did not start"
}

# Wait, bounded, for the fixture's composer to hold exactly <expected>.
# The fixture redraws once per character, so how long typed text takes to land
# is a property of the machine, not of the contract under test: reading the
# composer after a fixed sleep reports a half-typed PREFIX as a wrong buffer.
# Polling the real condition cannot hide a fixture that never takes the text -
# the wait is bounded and the caller still fails, by name, when it expires.
wait_for_composer() {  # <expected>
  local expected=$1 i=0
  while [ "$i" -lt 100 ]; do
    [ "$(cat "$CLAUDE_LOG.composer" 2>/dev/null)" = "$expected" ] && return 0
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

# Fail naming what the composer actually held. A composer assertion that
# reports only "did not match" costs a whole CI run per observation and still
# does not say whether the text was truncated, altered, or never arrived.
composer_mismatch() {  # <what> <expected>
  local what=$1 expected=$2 got
  got=$(cat "$CLAUDE_LOG.composer" 2>/dev/null || true)
  fail "$what (expected ${#expected} chars: $expected; composer holds ${#got} chars: $got)"
}

# One daemon flush against the fixture, exactly as housekeeping runs it.
claude_flush() {
  PATH="$TMUX_SHIM_DIR:$PATH" FM_STATE_OVERRIDE="$STATE_DIR" LOG="$STATE_DIR/scenario-e.log" \
    FM_SUPERVISOR_TARGET="$CLAUDE_PANE" FM_SUPERVISOR_BACKEND=tmux FM_DAEMON_PRIMARY_HARNESS=claude \
    FM_INJECT_CONFIRM_SLEEP=0.3 FM_INJECT_CONFIRM_RETRIES=3 escalate_flush "$STATE_DIR"
}

# The exact text escalate_flush types for the current buffer.
claude_digest_text() {
  local n msg encoded
  n=$(wc -l < "$STATE_DIR/.subsuper-escalations")
  msg=$(awk 'NR>1{printf " | "} {printf "%s",$0} END{print ""}' "$STATE_DIR/.subsuper-escalations")
  msg=$(printf 'Supervisor escalate (%s event(s)): %s (pre-read; re-arm not needed — watcher daemon-managed)' "$n" "$msg")
  msg=$(_collapse_newlines "$msg")
  fm_operational_input_encode away-supervisor "$msg" encoded
  printf '%s' "$encoded"
}

claude_buffer_three() {
  printf '%s\n' \
    "demo-alpha.status: needs-decision [key=demo-a]: ask-user findings=test-1 file=/tmp/fm-e2e/demo-alpha/findings.txt" \
    "demo-beta.status: done: PR https://example.test/pr/501 checks green run=01DEMO" \
    "check: fleet idle with ready work: in-progress=3 capacity=5 ready=16 idle=928s" \
    > "$STATE_DIR/.subsuper-escalations"
  date +%s > "$STATE_DIR/.subsuper-escalations.since"
}

# Type text the way an earlier daemon did, and let the fixture swallow Enter.
claude_strand() {  # <text>
  local stripped=${1//$'\xE2\x81\xA3'/}
  "$REAL_TMUX" -L "$SOCKET" send-keys -t "$CLAUDE_PANE" -l "$1"
  wait_for_composer "$stripped" \
    || composer_mismatch "Scenario E: the fixture never took the whole typed digest into its composer" "$stripped"
  "$REAL_TMUX" -L "$SOCKET" send-keys -t "$CLAUDE_PANE" Enter
  # The swallowed Enter leaves the buffer intact, so it changes nothing on this
  # side to poll for. It needs no barrier either: the pane is a FIFO, so a
  # later flush's keys queue behind this Enter and it is still swallowed first.
  sleep 0.5
}

test_scenario_e() {
  local text stripped composer

  # E1: a fresh flush whose Enter claude swallows must still deliver its own
  # digest exactly once, instead of stranding it and deferring every later flush.
  reset_state
  afk_enter "$STATE_DIR"
  claude_fixture_restart
  claude_buffer_three
  text=$(claude_digest_text)
  stripped=${text//$'\xE2\x81\xA3'/}
  claude_flush || true
  sleep 0.5
  claude_flush || true
  [ "$(wc -l < "$CLAUDE_LOG" | tr -d ' ')" = 1 ] && [ "$(cat "$CLAUDE_LOG")" = "$stripped" ] \
    || fail "Scenario E: the daemon's own digest stranded in the claude composer and every later flush deferred (submitted: $(cat "$CLAUDE_LOG"); composer: $(cat "$CLAUDE_LOG.composer" 2>/dev/null); log: $(cat "$STATE_DIR/scenario-e.log" 2>/dev/null))"
  [ ! -s "$STATE_DIR/.subsuper-escalations" ] || fail "Scenario E: the delivered digest was left in the buffer"
  [ ! -e "$STATE_DIR/.subsuper-stranded" ] || fail "Scenario E: a delivered digest was left recorded as stranded"
  [ ! -s "$CLAUDE_LOG.composer" ] || fail "Scenario E: text was left in the composer: $(cat "$CLAUDE_LOG.composer")"
  pass "Scenario E: a swallowed submit of the daemon's own digest in a claude-shaped composer self-heals in the same flush"

  # E2: a digest an earlier flush stranded (the overnight state) is resubmitted
  # by the next flush, and an event buffered after it waits for the flush after.
  reset_state
  afk_enter "$STATE_DIR"
  claude_fixture_restart
  claude_buffer_three
  text=$(claude_digest_text)
  stripped=${text//$'\xE2\x81\xA3'/}
  claude_strand "$text"
  [ "$(cat "$CLAUDE_LOG.composer")" = "$stripped" ] \
    || composer_mismatch "Scenario E: the fixture did not strand the digest" "$stripped"
  printf '3\n%s\n' "$text" > "$STATE_DIR/.subsuper-stranded"
  echo "demo-gamma.status: failed: a newer event buffered behind the stranded digest" >> "$STATE_DIR/.subsuper-escalations"
  claude_flush || true
  [ "$(cat "$CLAUDE_LOG")" = "$stripped" ] \
    || fail "Scenario E: a digest stranded by an earlier flush was never resubmitted (submitted: $(cat "$CLAUDE_LOG"); log: $(cat "$STATE_DIR/scenario-e.log" 2>/dev/null))"
  [ "$(cat "$STATE_DIR/.subsuper-escalations")" = "demo-gamma.status: failed: a newer event buffered behind the stranded digest" ] \
    || fail "Scenario E: resubmitting the stranded digest did not keep exactly the newer event buffered: $(cat "$STATE_DIR/.subsuper-escalations")"
  [ ! -e "$STATE_DIR/.subsuper-stranded" ] || fail "Scenario E: the resubmitted digest stayed recorded as stranded"
  sleep 0.5
  claude_flush || true
  if [ "$(wc -l < "$CLAUDE_LOG" | tr -d ' ')" != 2 ] \
    || ! grep -F 'a newer event buffered behind the stranded digest' "$CLAUDE_LOG" >/dev/null; then
    fail "Scenario E: the event buffered behind the stranded digest was not delivered next (submitted: $(cat "$CLAUDE_LOG"))"
  fi
  pass "Scenario E: a digest stranded by an earlier flush is resubmitted, and what was buffered behind it follows"

  # E3: text the captain typed is never touched - not appended to the stranded
  # digest, and not in place of it.
  reset_state
  afk_enter "$STATE_DIR"
  claude_fixture_restart
  claude_buffer_three
  text=$(claude_digest_text)
  stripped=${text//$'\xE2\x81\xA3'/}
  claude_strand "$text"
  "$REAL_TMUX" -L "$SOCKET" send-keys -t "$CLAUDE_PANE" -l " and one more thing"
  wait_for_composer "$stripped and one more thing" \
    || composer_mismatch "Scenario E: the fixture never took the captain's appended text" "$stripped and one more thing"
  composer=$(cat "$CLAUDE_LOG.composer")
  printf '3\n%s\n' "$text" > "$STATE_DIR/.subsuper-stranded"
  claude_flush && fail "Scenario E: a flush reported success over captain text"
  [ ! -s "$CLAUDE_LOG" ] || fail "Scenario E: captain text appended to the stranded digest was submitted: $(cat "$CLAUDE_LOG")"
  [ "$(cat "$CLAUDE_LOG.composer")" = "$composer" ] || fail "Scenario E: captain text appended to the stranded digest was changed"
  grep -F "leaving it untouched" "$STATE_DIR/scenario-e.log" >/dev/null \
    || fail "Scenario E: the refusal to touch captain text was not logged"
  claude_fixture_restart
  "$REAL_TMUX" -L "$SOCKET" send-keys -t "$CLAUDE_PANE" -l "captain draft only"
  wait_for_composer "captain draft only" \
    || composer_mismatch "Scenario E: the fixture never took the captain's draft" "captain draft only"
  claude_flush && fail "Scenario E: a flush reported success over a captain draft"
  [ ! -s "$CLAUDE_LOG" ] || fail "Scenario E: a captain draft was submitted in place of the stranded digest: $(cat "$CLAUDE_LOG")"
  [ "$(cat "$CLAUDE_LOG.composer")" = "captain draft only" ] || fail "Scenario E: a captain draft was changed"
  afk_exit "$STATE_DIR"
  pass "Scenario E: captain text, appended to the stranded digest or in its place, is never submitted or changed"
}

# --- Scenario F: a stranded digest the daemon cannot prove its own, past max-defer
# The residual of the 2026-09-18 wedge fix. With captain text typed after the
# stranded digest, the ownership proof fails, so every flush defers and only
# the wedge alarm fires; nothing reaches firstmate while it sits idle. A daemon
# running as the harness's own tracked background job (the launch record reads
# `none - native`) has one path back to firstmate that does not touch the
# composer: its own exit, which the harness delivers as a job completion.
# Past max-defer it must take that path - hand the undelivered events back on
# stdout, clear the daemon flag so the ordinary cycle owns supervision, and
# exit - while the composer stays untouched. A daemon launched into its own
# terminal has no such path, and keeps the wedge alarm as its floor.
claude_daemon_start() {  # <stdout-file>
  PATH="$TMUX_SHIM_DIR:$PATH" \
  FM_STATE_OVERRIDE="$STATE_DIR" \
  FM_SUPERVISOR_TARGET="$CLAUDE_PANE" \
  FM_SUPERVISOR_BACKEND=tmux \
  FM_DAEMON_PRIMARY_HARNESS=claude \
  FM_ESCALATE_BATCH_SECS=0 \
  FM_MAX_DEFER_SECS=2 \
  FM_HOUSEKEEPING_TICK=1 \
  FM_POLL=1 \
  FM_SIGNAL_GRACE=1 \
  FM_HEARTBEAT=999999 \
  FM_CHECK_INTERVAL=999999 \
  FM_INJECT_CONFIRM_SLEEP=0.3 \
  FM_INJECT_CONFIRM_RETRIES=3 \
  FM_STALE_ESCALATE_SECS=999999 \
  nohup "$DAEMON" >"$1" 2>"$STATE_DIR/daemon-f.err" &
  DAEMON_PID=$!
}

# Strand the daemon's own digest, then type captain text after it, so the
# composer cannot be proven to hold only the daemon's text; the buffer has
# waited well past max-defer.
claude_strand_unprovable() {
  local text stripped
  claude_fixture_restart
  claude_buffer_three
  echo $(( $(date +%s) - 60 )) > "$STATE_DIR/.subsuper-escalations.since"
  text=$(claude_digest_text)
  stripped=${text//$'\xE2\x81\xA3'/}
  claude_strand "$text"
  "$REAL_TMUX" -L "$SOCKET" send-keys -t "$CLAUDE_PANE" -l " and one more thing"
  wait_for_composer "$stripped and one more thing" \
    || composer_mismatch "Scenario F: the fixture never took the captain's appended text" "$stripped and one more thing"
  printf '3\n%s\n' "$text" > "$STATE_DIR/.subsuper-stranded"
}

test_scenario_f() {
  local out composer i

  # F1: a natively tracked daemon hands supervision back through its own exit.
  reset_state
  afk_enter "$STATE_DIR"
  claude_strand_unprovable
  composer=$(cat "$CLAUDE_LOG.composer")
  printf 'none\t-\tnative\n' > "$STATE_DIR/.afk-daemon-terminal"
  out="$STATE_DIR/daemon-f1.out"
  claude_daemon_start "$out"
  i=0
  while kill -0 "$DAEMON_PID" 2>/dev/null && [ "$i" -lt 100 ]; do
    sleep 0.2
    i=$((i + 1))
  done
  if kill -0 "$DAEMON_PID" 2>/dev/null; then
    fail "Scenario F: a natively tracked daemon kept deferring an unprovable stranded digest past max-defer instead of handing supervision back (stdout: $(cat "$out"); log: $(tail -5 "$STATE_DIR/.supervise-daemon.log" 2>/dev/null))"
  fi
  wait "$DAEMON_PID" 2>/dev/null || true
  DAEMON_PID=""
  grep -F "HANDED SUPERVISION BACK" "$out" >/dev/null \
    || fail "Scenario F: the daemon exited without a handback report on stdout: $(cat "$out")"
  grep -F "demo-beta.status: done: PR https://example.test/pr/501 checks green run=01DEMO" "$out" >/dev/null \
    || fail "Scenario F: the handback report did not carry the undelivered events: $(cat "$out")"
  [ ! -e "$STATE_DIR/.afk" ] || fail "Scenario F: the handback left the daemon flag set, so nothing owns supervision"
  [ ! -s "$CLAUDE_LOG" ] || fail "Scenario F: the handback submitted composer text: $(cat "$CLAUDE_LOG")"
  [ "$(cat "$CLAUDE_LOG.composer")" = "$composer" ] || fail "Scenario F: the handback changed the composer"
  [ "$(wc -l < "$STATE_DIR/.subsuper-escalations" | tr -d ' ')" = 3 ] \
    || fail "Scenario F: the handback did not retain the undelivered events for the return brief"
  [ -e "$STATE_DIR/.subsuper-inject-wedged" ] || fail "Scenario F: the wedge alarm floor did not fire before the handback"
  [ ! -e "$STATE_DIR/.supervise-daemon.pid" ] || fail "Scenario F: the handback exit left the daemon pid file"
  pass "Scenario F: a natively tracked daemon hands an unprovable stranded digest back to firstmate through its own exit"

  # F2: a daemon launched into its own terminal has no path back to firstmate
  # but the composer, so it keeps supervising and keeps the wedge alarm.
  reset_state
  afk_enter "$STATE_DIR"
  claude_strand_unprovable
  printf 'tmux\t%%0\t-\n' > "$STATE_DIR/.afk-daemon-terminal"
  out="$STATE_DIR/daemon-f2.out"
  claude_daemon_start "$out"
  i=0
  while [ ! -e "$STATE_DIR/.subsuper-inject-wedged" ] && [ "$i" -lt 100 ]; do
    sleep 0.2
    i=$((i + 1))
  done
  [ -e "$STATE_DIR/.subsuper-inject-wedged" ] || fail "Scenario F: the terminal-launched daemon never raised the wedge alarm"
  sleep 4
  kill -0 "$DAEMON_PID" 2>/dev/null || fail "Scenario F: a terminal-launched daemon exited, although nothing would deliver its exit to firstmate: $(cat "$out")"
  [ -e "$STATE_DIR/.afk" ] || fail "Scenario F: a terminal-launched daemon cleared the daemon flag"
  [ ! -s "$out" ] || fail "Scenario F: a terminal-launched daemon printed a handback nobody reads: $(cat "$out")"
  stop_daemon
  rm -f "$STATE_DIR/.afk-daemon-terminal"
  pass "Scenario F: a terminal-launched daemon keeps supervising behind the wedge alarm"
}

test_scenario_a
test_scenario_b
test_scenario_c
test_scenario_d
test_scenario_e
test_scenario_f

echo "all e2e injection tests passed"
