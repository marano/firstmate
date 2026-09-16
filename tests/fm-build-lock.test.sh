#!/usr/bin/env bash
# Behavior tests for bin/fm-build-lock.sh, the machine-wide build/test mutex
# behind the `mutex <command>` entry point.
#
# Every case drives the real script as a separate process against a private lock
# root, so nothing here can touch, or block on, the machine's actual build lock.
# Nothing reads the script's source text: mutual exclusion is proved by the
# recorded order of two concurrent critical sections, release by whether the next
# waiter gets in, and CI stand-down by whether the lock root stays empty.
#
# Each case names the mutant that must turn it red. Those mutants were applied
# and each case was confirmed to fail before the mutant was reverted; the PR's
# test plan records the results.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SCRIPT="$ROOT/bin/fm-build-lock.sh"
MUTEX="$ROOT/bin/mutex"

TMP_ROOT=$(fm_test_tmproot fm-build-lock)
LOCK_ROOT="$TMP_ROOT/lockroot"
CI_ROOT_OK="$TMP_ROOT/ci-lockroot"
mkdir -p "$LOCK_ROOT" "$CI_ROOT_OK"

# FM_BUILD_LOCK_CI=0 is mandatory, not tidiness: this suite runs on CI, where
# the ambient markers are set and every locking case would otherwise stand down
# and pass vacuously. The CI case below sets its own markers instead.
export FM_BUILD_LOCK_DIR="$LOCK_ROOT"
export FM_BUILD_LOCK_CI=0
export FM_BUILD_LOCK_POLL=0.1
export FM_BUILD_LOCK_NOTICE_INTERVAL=1

# Count the lock's own artifacts in a root. Zero means the lock was never taken
# or was fully released, including the owner directory the lockdir mutex links.
lock_artifacts() {  # <root>
  local n
  n=$(find "$1" -maxdepth 1 -name 'fm-build-lock*' 2>/dev/null | wc -l)
  printf '%s\n' "$((n))"
}

# Wait until <path> exists, bounded by iterations rather than a wall-clock
# budget so the bound does not shrink under load.
await_path() {  # <path> [max-iterations]
  local path=$1 max=${2:-300} i=0
  while [ "$i" -lt "$max" ]; do
    [ -e "$path" ] && return 0
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

# Bounded wait for a background invocation to finish. The two cases that use it
# prove a waiter eventually gets IN, so under their mutants they would block
# forever instead of failing; the bound is what turns that into a red.
await_pid_exit() {  # <pid> [max-iterations]
  local pid=$1 max=${2:-600} i=0
  while [ "$i" -lt "$max" ]; do
    kill -0 "$pid" 2>/dev/null || return 0
    sleep 0.1
    i=$((i + 1))
  done
  kill -9 "$pid" 2>/dev/null || true
  return 1
}

# --- exit status passthrough ------------------------------------------------
# Mutant: `exit 0` in place of `exit "$STATUS"`.

"$SCRIPT" true
expect_code 0 $? "success status must pass through"

"$SCRIPT" sh -c 'exit 37'
expect_code 37 $? "failure status must pass through"

"$SCRIPT" sh -c 'kill -TERM $$' 2>/dev/null
expect_code 143 $? "a signal-killed command must pass through as 128+signal"
pass "exit status passes through unchanged for success, failure, and signal death"

# --- stdout stays exactly the wrapped command's output ----------------------
# Mutant: write a notice to stdout instead of stderr.

OUT=$("$SCRIPT" printf 'only-this\n' 2>/dev/null)
assert_equals 'only-this' "$OUT" "stdout must carry only the wrapped command's output"

IN=$(printf 'piped-in\n' | "$SCRIPT" cat 2>/dev/null)
assert_equals 'piped-in' "$IN" "stdin must reach the wrapped command"
pass "stdout and stdin pass through untouched"

# --- mutual exclusion -------------------------------------------------------
# Two concurrent invocations each record entering and leaving a critical
# section. Serialized runs give strictly paired lines; any overlap interleaves
# them, which is what this asserts against.
# Mutant: drop the fm_build_lock_acquire call.

ORDER="$TMP_ROOT/order"
: > "$ORDER"
for worker in A B; do
  "$SCRIPT" sh -c "printf '%s in\n' '$worker' >> '$ORDER'; sleep 1; printf '%s out\n' '$worker' >> '$ORDER'" \
    >/dev/null 2>"$TMP_ROOT/excl.$worker.err" &
done
wait

RECORDED=$(tr '\n' '|' < "$ORDER")
case "$RECORDED" in
  'A in|A out|B in|B out|'|'B in|B out|A in|A out|') : ;;
  *) fail "concurrent invocations overlapped: $RECORDED" ;;
esac
assert_equals 0 "$(lock_artifacts "$LOCK_ROOT")" "the lock must be fully released afterwards"
pass "two concurrent invocations never overlap, and the lock is left clean"

# --- the wait is observable -------------------------------------------------
# A blocked worker must be readable as waiting rather than wedged: the holder's
# pid, age and command all appear, on stderr.
# Mutant: drop the holder description from the waiting notice.

WAITER_ERR=$(grep -l 'waiting for the machine-wide build lock' \
  "$TMP_ROOT/excl.A.err" "$TMP_ROOT/excl.B.err" 2>/dev/null | head -1)
[ -n "$WAITER_ERR" ] || fail "neither concurrent invocation reported that it was waiting"
assert_grep 'WAITING, not wedged' "$WAITER_ERR" "the waiting notice must say the process is waiting, not wedged"
assert_grep 'held by pid ' "$WAITER_ERR" "the waiting notice must name the holder's pid"
assert_grep ' running: sh -c ' "$WAITER_ERR" "the waiting notice must name the command the holder is running"
assert_grep ' [in ' "$WAITER_ERR" "the waiting notice must name the holder's working directory"
assert_grep 'acquired the machine-wide build lock after ' "$WAITER_ERR" "the waiter must report when it got in"
pass "a blocked invocation names the holder, its age and its command, on stderr"

# --- --status ---------------------------------------------------------------

assert_equals 'free' "$("$SCRIPT" --status)" "an unheld lock must report free"

STATUS_MARK="$TMP_ROOT/status-running"
"$SCRIPT" sh -c "touch '$STATUS_MARK'; sleep 5" >/dev/null 2>&1 &
STATUS_HOLDER=$!
await_path "$STATUS_MARK" || fail "the status fixture never started"
sleep 0.3
HELD_LINE=$("$SCRIPT" --status)
assert_contains "$HELD_LINE" 'held by pid ' "--status must name the holder"
assert_contains "$HELD_LINE" 'sleep' "--status must name the held command"
assert_contains "$HELD_LINE" '[in ' "--status must name the holder's working directory"
kill "$STATUS_HOLDER" 2>/dev/null || true
wait "$STATUS_HOLDER" 2>/dev/null || true
pass "--status reports the holder while held and free once released"

# --- release survives the wrapped command being SIGKILLed -------------------
# Mutant: replace the EXIT/INT/TERM trap with a release statement after the
# command; the queued waiter then never gets in and this case times out.

CHILD_PID_FILE="$TMP_ROOT/killed-child.pid"
"$SCRIPT" sh -c "printf '%s\n' \$\$ > '$CHILD_PID_FILE'.tmp; mv '$CHILD_PID_FILE'.tmp '$CHILD_PID_FILE'; sleep 120" \
  >/dev/null 2>&1 &
KILL_HOLDER=$!
await_path "$CHILD_PID_FILE" || fail "the SIGKILL fixture never published its pid"

WAITER_OUT="$TMP_ROOT/after-kill.out"
( "$SCRIPT" printf 'acquired-after-kill\n' > "$WAITER_OUT" 2>/dev/null ) &
WAITER=$!
sleep 0.5
kill -9 "$(cat "$CHILD_PID_FILE")" 2>/dev/null || true
wait "$KILL_HOLDER" 2>/dev/null
expect_code 137 $? "a SIGKILLed wrapped command must surface as 128+9"
await_pid_exit "$WAITER" || fail "the next waiter never acquired after the holder's command was SIGKILLed"
wait "$WAITER" 2>/dev/null || true
assert_equals 'acquired-after-kill' "$(cat "$WAITER_OUT" 2>/dev/null || true)" \
  "the next waiter must acquire after the wrapped command was SIGKILLed"
assert_equals 0 "$(lock_artifacts "$LOCK_ROOT")" "a SIGKILLed command must still leave the lock released"
pass "the lock is released when the wrapped command is SIGKILLed, and the next waiter gets in"

# --- stale-holder recovery --------------------------------------------------
# SIGKILL the wrapper itself, so no trap of any kind runs and the lock record is
# left behind by a process that no longer exists. The next invocation must
# reclaim it rather than block forever.
# Mutant: make fm_lock_try_acquire's dead-holder path unreachable.

STALE_MARK="$TMP_ROOT/stale-running"
"$SCRIPT" sh -c "touch '$STALE_MARK'; sleep 120" >/dev/null 2>&1 &
STALE_WRAPPER=$!
await_path "$STALE_MARK" || fail "the stale-holder fixture never started"
sleep 0.3
kill -9 "$STALE_WRAPPER" 2>/dev/null || true
wait "$STALE_WRAPPER" 2>/dev/null || true
pkill -P "$STALE_WRAPPER" 2>/dev/null || true
[ "$(lock_artifacts "$LOCK_ROOT")" -gt 0 ] || fail "the SIGKILLed wrapper should have left a lock record behind"

RECLAIM_OUT="$TMP_ROOT/reclaimed.out"
( "$SCRIPT" printf 'reclaimed\n' > "$RECLAIM_OUT" 2>/dev/null ) &
RECLAIMER=$!
await_pid_exit "$RECLAIMER" || fail "a lock left by a dead holder blocked the next invocation forever"
wait "$RECLAIMER" 2>/dev/null || true
assert_equals 'reclaimed' "$(cat "$RECLAIM_OUT" 2>/dev/null || true)" \
  "a lock whose holder died must be reclaimed"
assert_equals 0 "$(lock_artifacts "$LOCK_ROOT")" "reclaiming must leave the lock clean"
pass "a lock left by a dead holder is reclaimed instead of blocking forever"

# --- CI stand-down ----------------------------------------------------------
# With a CI marker set the command must run and the lock must never be taken.
# "The lock root is empty afterwards" is NOT enough on its own: a run that took
# the lock and released it leaves the same empty root, which is exactly how an
# earlier version of this case let a mutant with no CI check survive. Both
# assertions below are therefore ones a locking run cannot satisfy - a root it
# could never create the lock in, and a holder it would have to queue behind.
# Mutant: replace the fm_build_lock_is_ci branch with `if false`.

# A lock root that cannot exist, because its parent is a regular file. A run
# that reaches the lock refuses here; a run that stands down never looks.
UNUSABLE_ROOT="$TMP_ROOT/not-a-directory/lockroot"
printf 'regular file\n' > "$TMP_ROOT/not-a-directory"

for marker in CI GITHUB_ACTIONS BUILDKITE; do
  CI_OUT=$(env -u FM_BUILD_LOCK_CI "$marker=true" FM_BUILD_LOCK_DIR="$UNUSABLE_ROOT" \
    "$SCRIPT" printf 'ran-under-%s\n' "$marker" 2>/dev/null)
  assert_equals "ran-under-$marker" "$CI_OUT" "the command must still run under $marker"
done

env -u FM_BUILD_LOCK_CI FM_BUILD_LOCK_DIR="$UNUSABLE_ROOT" "$SCRIPT" true >/dev/null 2>&1
expect_code 2 $? "without a CI marker the same run must reach the lock and refuse the unusable root"

env -u FM_BUILD_LOCK_CI CI=false FM_BUILD_LOCK_DIR="$CI_ROOT_OK" "$SCRIPT" sh -c 'exit 4'
expect_code 4 $? "CI=false must not be read as CI"
assert_equals 0 "$(lock_artifacts "$CI_ROOT_OK")" "CI=false must take and fully release the lock"

# Standing down must not merely skip the acquire, it must not queue either. The
# holder here outlives the CI run by a wide margin, so a run that queued would
# still be waiting when this bound expires.
CI_HOLD_MARK="$TMP_ROOT/ci-hold"
FM_BUILD_LOCK_DIR="$CI_ROOT_OK" "$SCRIPT" sh -c "touch '$CI_HOLD_MARK'; sleep 120" >/dev/null 2>&1 &
CI_HOLDER=$!
await_path "$CI_HOLD_MARK" || fail "the CI contention fixture never started"
CI_CONTENDED_OUT="$TMP_ROOT/ci-contended.out"
( env -u FM_BUILD_LOCK_CI CI=true FM_BUILD_LOCK_DIR="$CI_ROOT_OK" \
    "$SCRIPT" printf 'not-blocked\n' > "$CI_CONTENDED_OUT" 2>/dev/null ) &
CI_CONTENDED=$!
await_pid_exit "$CI_CONTENDED" 100 || fail "a CI run queued behind a local holder instead of standing down"
wait "$CI_CONTENDED" 2>/dev/null || true
assert_equals 'not-blocked' "$(cat "$CI_CONTENDED_OUT" 2>/dev/null || true)" \
  "a CI run must not wait behind a local holder"
kill -0 "$CI_HOLDER" 2>/dev/null || fail "the contention fixture stopped holding before the CI run was checked"
kill "$CI_HOLDER" 2>/dev/null || true
wait "$CI_HOLDER" 2>/dev/null || true
pass "CI stands down: the command runs, the lock is never taken, and it never queues"

# --- hold and wait ceilings report, and never kill --------------------------
# Mutant: signal the holder at the ceiling instead of printing; the wrapped
# command's own completion line then disappears from stdout.

CEILING_OUT=$(FM_BUILD_LOCK_HOLD_WARN=1 "$SCRIPT" sh -c 'sleep 2.5; printf "survived\n"' \
  2>"$TMP_ROOT/ceiling.err")
assert_equals 'survived' "$CEILING_OUT" "the holder must not be killed at its ceiling"
assert_grep 'WARNING: this command has held the machine-wide build lock' "$TMP_ROOT/ceiling.err" \
  "a holder past its ceiling must warn from its own output"

WAIT_HOLD_MARK="$TMP_ROOT/wait-ceiling-hold"
"$SCRIPT" sh -c "touch '$WAIT_HOLD_MARK'; sleep 4" >/dev/null 2>&1 &
CEILING_HOLDER=$!
await_path "$WAIT_HOLD_MARK" || fail "the wait-ceiling fixture never started"
FM_BUILD_LOCK_WAIT_WARN=1 FM_BUILD_LOCK_HOLD_WARN=1 \
  "$SCRIPT" true >/dev/null 2>"$TMP_ROOT/wait-ceiling.err"
assert_grep 'WARNING: still WAITING' "$TMP_ROOT/wait-ceiling.err" \
  "a waiter past its ceiling must warn"
assert_grep 'it is not being killed' "$TMP_ROOT/wait-ceiling.err" \
  "the waiter must say the over-ceiling holder is not being killed"
wait "$CEILING_HOLDER" 2>/dev/null || true
pass "both ceilings warn loudly and neither kills the holder"

# --- one machine-wide lock, independent of the ambient TMPDIR ---------------
# The default lock root is resolved deliberately rather than from $TMPDIR,
# because an agent harness can hand each worker a session-private $TMPDIR and
# two workers that resolved different roots would silently stop excluding each
# other. --lock-path reports the resolution without taking the lock, which is
# how this is proved without touching the machine's real build lock.
# Mutant: resolve the root from $TMPDIR; the two paths below then differ.

# These must exist and be writable before the resolution runs: a root that is
# not a usable directory falls back, which would make both answers agree for
# the wrong reason and hide a resolver that does follow $TMPDIR.
mkdir -p "$TMP_ROOT/tmp-one" "$TMP_ROOT/tmp-two"
PATH_ONE=$(env -u FM_BUILD_LOCK_DIR TMPDIR="$TMP_ROOT/tmp-one" "$SCRIPT" --lock-path)
PATH_TWO=$(env -u FM_BUILD_LOCK_DIR TMPDIR="$TMP_ROOT/tmp-two" "$SCRIPT" --lock-path)
assert_equals "$PATH_ONE" "$PATH_TWO" "two ambient TMPDIR values must resolve one lock"
assert_not_contains "$PATH_ONE" "$TMP_ROOT" "the default lock must not follow the ambient TMPDIR"

# And it must live outside every firstmate home, so secondmate homes share it.
# Mutant: resolve the root from a home's state directory.
case "$PATH_ONE" in
  "$ROOT"/*) fail "the default lock must not live inside a firstmate checkout: $PATH_ONE" ;;
esac
assert_not_contains "$PATH_ONE" '/state/' "the default lock must not live in a per-home state directory"
pass "the default lock is one machine-wide path, outside every home and independent of TMPDIR"

# The lockdir mutex's own scratch must not drift with TMPDIR either: two workers
# given different TMPDIR values and one lock root still serialize.
SHARED_ROOT="$TMP_ROOT/shared-lockroot"
mkdir -p "$SHARED_ROOT"
SHARED_ORDER="$TMP_ROOT/shared-order"
: > "$SHARED_ORDER"
for pair in "one:$TMP_ROOT/tmp-one" "two:$TMP_ROOT/tmp-two"; do
  worker=${pair%%:*}
  worker_tmp=${pair#*:}
  TMPDIR="$worker_tmp" FM_BUILD_LOCK_DIR="$SHARED_ROOT" \
    "$SCRIPT" sh -c "printf '%s in\n' '$worker' >> '$SHARED_ORDER'; sleep 1; printf '%s out\n' '$worker' >> '$SHARED_ORDER'" \
    >/dev/null 2>&1 &
done
wait
SHARED_RECORDED=$(tr '\n' '|' < "$SHARED_ORDER")
case "$SHARED_RECORDED" in
  'one in|one out|two in|two out|'|'two in|two out|one in|one out|') : ;;
  *) fail "workers with different TMPDIR values overlapped: $SHARED_RECORDED" ;;
esac
assert_equals 0 "$(lock_artifacts "$SHARED_ROOT")" "the shared root must be left clean"
pass "workers with different TMPDIR values still exclude each other"

# --- the mutex entry point --------------------------------------------------
# Mutant: point bin/mutex at anything other than this script, or resolve
# SCRIPT_DIR from the invoked path instead of through the symlink.

[ -L "$MUTEX" ] || fail "bin/mutex must be a symlink"
assert_equals 'fm-build-lock.sh' "$(readlink "$MUTEX")" "bin/mutex must point at fm-build-lock.sh"
assert_equals 'bare-word' "$("$MUTEX" printf 'bare-word\n' 2>/dev/null)" \
  "bin/mutex must run the wrapped command"

INSTALL_DIR="$TMP_ROOT/pathdir"
mkdir -p "$INSTALL_DIR"
"$SCRIPT" --install-mutex "$INSTALL_DIR" >/dev/null || fail "--install-mutex failed"
[ -L "$INSTALL_DIR/mutex" ] || fail "--install-mutex must create a symlink"
# Run it from an unrelated working directory: an installed entry point must
# resolve its own siblings through the symlink, not from where it was invoked.
INSTALLED=$(cd "$TMP_ROOT" && "$INSTALL_DIR/mutex" printf 'installed\n' 2>/dev/null)
assert_equals 'installed' "$INSTALLED" "an installed mutex must work from any directory"

printf 'not a symlink\n' > "$INSTALL_DIR/occupied"
mkdir -p "$INSTALL_DIR/occupied.d"
cp "$INSTALL_DIR/occupied" "$INSTALL_DIR/occupied.d/mutex"
"$SCRIPT" --install-mutex "$INSTALL_DIR/occupied.d" >/dev/null 2>&1
expect_code 2 $? "--install-mutex must refuse to replace a non-symlink"
pass "the mutex entry point works as a bare word, installed elsewhere, and refuses to clobber"

# --- argument handling ------------------------------------------------------

"$SCRIPT" >/dev/null 2>&1
expect_code 2 $? "no command must be a usage error"
"$SCRIPT" --nope true >/dev/null 2>&1
expect_code 2 $? "an unknown option must be refused rather than run as a command"
"$SCRIPT" -- printf 'after-dashdash\n' >/dev/null 2>&1
expect_code 0 $? "-- must end option parsing"
assert_equals 'after-dashdash' "$("$SCRIPT" -- printf 'after-dashdash\n' 2>/dev/null)" \
  "-- must pass the rest through as the command"
FM_BUILD_LOCK_WAIT_WARN=nonsense "$SCRIPT" true >/dev/null 2>&1
expect_code 2 $? "a malformed ceiling must be refused rather than silently ignored"
assert_equals "$LOCK_ROOT/fm-build-lock" "$("$SCRIPT" --lock-path)" "--lock-path must print the resolved lock"
pass "argument and environment handling refuses bad input instead of guessing"

assert_equals 0 "$(lock_artifacts "$LOCK_ROOT")" "the suite must leave no lock behind"
pass "fm-build-lock behaves"
