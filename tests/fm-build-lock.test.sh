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
# A hold inherited from whatever runs this suite names another lock; drop it so
# every case starts outside any hold.
unset FM_BUILD_LOCK_HELD_BY FM_BUILD_LOCK_HELD_LOCK
# Ceiling lines go only where a case points them.
unset FM_TASK_STATUS

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

# Wait until <pattern> appears in <file>, on the same iteration bound as
# await_path. Several cases below need a process's own stderr to tell them it
# has reached a particular point, which no marker file can report.
await_grep() {  # <pattern> <file> [max-iterations]
  local pattern=$1 file=$2 max=${3:-600} i=0
  while [ "$i" -lt "$max" ]; do
    grep -q "$pattern" "$file" 2>/dev/null && return 0
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

# One ordinary invocation, run after every case that kills a process while it is
# in line. It reaps whatever ticket that kill left behind and, finding nobody
# else waiting, takes the waiting line itself away - which is what lets the
# suite's closing "no lock behind" assertion cover the queue too.
settle_queue() {
  "$SCRIPT" true >/dev/null 2>&1 || fail "the lock was unusable after the preceding case"
  assert_equals 0 "$(lock_artifacts "$LOCK_ROOT")" \
    "the waiting line was left behind after the preceding case"
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

# --- arrival order: a barger cannot overtake an earlier waiter ---------------
# The starvation this guards against is not hypothetical: a worker that wrapped
# each individual test in its own invocation released and re-acquired hundreds
# of times in a row and pushed a fairly waiting worker past its 600s ceiling.
#
# The barger is given every advantage a race could hand it, so this case turns
# on ordering and nothing else. The patient waiter polls slowly, and the lock is
# released at the one moment its own poll has just been observed, which leaves
# the barger a whole two-second window in which it polls a hundred times and the
# waiter not once. Without arrival ordering the barger takes the lock every
# time; with it, it never can, because its ticket is younger.
# Mutant: in fm_build_lock_my_turn, return success without comparing this
# invocation's ticket against the oldest outstanding one.

FAIR_ORDER="$TMP_ROOT/fair-order"
FAIR_HOLD_MARK="$TMP_ROOT/fair-holding"
FAIR_RELEASE="$TMP_ROOT/fair-release"
BARGE_STOP="$TMP_ROOT/fair-barge-stop"
PATIENT_ERR="$TMP_ROOT/fair-patient.err"
BARGER_ERR="$TMP_ROOT/fair-barger.err"
: > "$FAIR_ORDER"
: > "$PATIENT_ERR"
: > "$BARGER_ERR"

# Released by a marker rather than a kill, so the handover under test is an
# ordinary release and not stale-holder recovery.
"$SCRIPT" sh -c "touch '$FAIR_HOLD_MARK'; while [ ! -e '$FAIR_RELEASE' ]; do sleep 0.05; done" \
  >/dev/null 2>&1 &
FAIR_HOLDER=$!
await_path "$FAIR_HOLD_MARK" || fail "the arrival-order fixture never took the lock"

FM_BUILD_LOCK_POLL=2 FM_BUILD_LOCK_NOTICE_INTERVAL=1 \
  "$SCRIPT" sh -c "printf 'patient\n' >> '$FAIR_ORDER'" >/dev/null 2>"$PATIENT_ERR" &
PATIENT=$!
await_grep 'waiting for the machine-wide build lock' "$PATIENT_ERR" \
  || fail "the patient waiter never reported that it was waiting"

( while [ ! -e "$BARGE_STOP" ]; do
    FM_BUILD_LOCK_POLL=0.02 FM_BUILD_LOCK_NOTICE_INTERVAL=1 \
      "$SCRIPT" sh -c "printf 'barger\n' >> '$FAIR_ORDER'" >/dev/null 2>>"$BARGER_ERR" || true
  done ) &
BARGER=$!
await_grep 'waiting for the machine-wide build lock' "$BARGER_ERR" \
  || fail "the barging loop never reached the lock"

# This line is the patient waiter's own poll, observable from outside: it prints
# on waking, then sleeps its full two seconds before looking again.
await_grep 'still waiting' "$PATIENT_ERR" \
  || fail "the patient waiter never reported a poll"
touch "$FAIR_RELEASE"

await_pid_exit "$PATIENT" || fail "the patient waiter never acquired the lock"
wait "$PATIENT" 2>/dev/null || true
touch "$BARGE_STOP"
await_pid_exit "$BARGER" || fail "the barging loop never finished"
wait "$BARGER" 2>/dev/null || true

assert_equals 'patient' "$(head -1 "$FAIR_ORDER")" \
  "a tight release-then-reacquire loop overtook a waiter that arrived first"
assert_grep 'barger' "$FAIR_ORDER" \
  "the barging loop never acquired at all, so this case proved nothing"
wait "$FAIR_HOLDER" 2>/dev/null || true
settle_queue
pass "a tight release-then-reacquire loop never overtakes an earlier waiter"

# --- a waiter that dies in line does not block the waiters behind it --------
# One ticket left at the head of the line by a waiter that died would wedge
# everyone behind it, which is worse than the starvation ordering fixes. The
# renewal backstop is disabled here so only the pid-liveness reaper can save the
# later waiter, and the later waiter arrives BEHIND the dead one, so it can only
# get in once that ticket is gone.
# Mutant: in fm_build_lock_queue_scan, drop the fm_pid_alive reap.

REAP_HOLD_MARK="$TMP_ROOT/reap-holding"
REAP_RELEASE="$TMP_ROOT/reap-release"
DEAD_ERR="$TMP_ROOT/reap-dead.err"
LATER_OUT="$TMP_ROOT/reap-later.out"
LATER_ERR="$TMP_ROOT/reap-later.err"
: > "$DEAD_ERR"
: > "$LATER_ERR"

export FM_BUILD_LOCK_TICKET_STALE=3600
"$SCRIPT" sh -c "touch '$REAP_HOLD_MARK'; while [ ! -e '$REAP_RELEASE' ]; do sleep 0.05; done" \
  >/dev/null 2>&1 &
REAP_HOLDER=$!
await_path "$REAP_HOLD_MARK" || fail "the dead-waiter fixture never took the lock"

"$SCRIPT" sleep 120 >/dev/null 2>"$DEAD_ERR" &
DOOMED=$!
await_grep 'waiting for the machine-wide build lock' "$DEAD_ERR" \
  || fail "the doomed waiter never got into line"

"$SCRIPT" printf 'later\n' > "$LATER_OUT" 2>"$LATER_ERR" &
LATER=$!
await_grep 'waiting for the machine-wide build lock' "$LATER_ERR" \
  || fail "the later waiter never got into line"

# SIGKILL, so no trap runs and the ticket is left behind exactly as a crash
# would leave it.
kill -9 "$DOOMED" 2>/dev/null || true
wait "$DOOMED" 2>/dev/null || true
touch "$REAP_RELEASE"

await_pid_exit "$LATER" || fail "a ticket left by a dead waiter blocked the waiters behind it"
wait "$LATER" 2>/dev/null || true
assert_equals 'later' "$(cat "$LATER_OUT" 2>/dev/null || true)" \
  "the waiter behind a dead one must still acquire"
wait "$REAP_HOLDER" 2>/dev/null || true
unset FM_BUILD_LOCK_TICKET_STALE
settle_queue
pass "a waiter that dies while in line does not block the waiters behind it"

# --- a waiter that stops polling loses its place ----------------------------
# The pid-liveness reaper cannot see a waiter that is alive but no longer
# renewing its ticket - a stopped process, or an unrelated process that was
# handed the dead waiter's pid number. The renewal ceiling is the backstop, and
# this case drives it with a SIGSTOPped waiter so nothing here touches the
# queue's files directly.
# Mutant: in fm_build_lock_queue_scan, drop the TICKET_STALE reap.

STOP_HOLD_MARK="$TMP_ROOT/stop-holding"
STOP_RELEASE="$TMP_ROOT/stop-release"
STOPPED_ERR="$TMP_ROOT/stop-stopped.err"
BEHIND_OUT="$TMP_ROOT/stop-behind.out"
BEHIND_ERR="$TMP_ROOT/stop-behind.err"
: > "$STOPPED_ERR"
: > "$BEHIND_ERR"

export FM_BUILD_LOCK_TICKET_STALE=1
"$SCRIPT" sh -c "touch '$STOP_HOLD_MARK'; while [ ! -e '$STOP_RELEASE' ]; do sleep 0.05; done" \
  >/dev/null 2>&1 &
STOP_HOLDER=$!
await_path "$STOP_HOLD_MARK" || fail "the stalled-waiter fixture never took the lock"

"$SCRIPT" sleep 120 >/dev/null 2>"$STOPPED_ERR" &
STALLED=$!
await_grep 'waiting for the machine-wide build lock' "$STOPPED_ERR" \
  || fail "the stalled waiter never got into line"

"$SCRIPT" printf 'behind\n' > "$BEHIND_OUT" 2>"$BEHIND_ERR" &
BEHIND=$!
await_grep 'waiting for the machine-wide build lock' "$BEHIND_ERR" \
  || fail "the waiter behind the stalled one never got into line"

kill -STOP "$STALLED" 2>/dev/null || fail "could not stall the leading waiter"
touch "$STOP_RELEASE"

await_pid_exit "$BEHIND" || fail "a waiter that stopped renewing its ticket blocked the line"
wait "$BEHIND" 2>/dev/null || true
assert_equals 'behind' "$(cat "$BEHIND_OUT" 2>/dev/null || true)" \
  "the waiter behind a stalled one must still acquire"
kill -CONT "$STALLED" 2>/dev/null || true
kill -9 "$STALLED" 2>/dev/null || true
wait "$STALLED" 2>/dev/null || true
pkill -P "$STALLED" 2>/dev/null || true
wait "$STOP_HOLDER" 2>/dev/null || true
unset FM_BUILD_LOCK_TICKET_STALE
settle_queue
pass "a waiter that stops renewing its ticket loses its place instead of wedging the line"

# --- an unreadable ticket age is unknown, not stale -------------------------
# A host whose stat cannot answer (the fake uname sends the lock's mtime read
# down the non-Darwin path, so this forces it on macOS too) must not make every
# ticket look old: the waiter would reap its own ticket every poll and never
# reach the front of the line.
# Mutant: treat an unreadable ticket age as stale again (the pre-fix
# behaviour); the waiter reaps its own ticket each poll and the bounded wait reds.

BLIND_BIN="$TMP_ROOT/blind-bin"
BLIND_MARK="$TMP_ROOT/blind-holding"
BLIND_RELEASE="$TMP_ROOT/blind-release"
BLIND_OUT="$TMP_ROOT/blind.out"
mkdir -p "$BLIND_BIN"
printf '#!/bin/sh\necho Linux\n' >"$BLIND_BIN/uname"
printf '#!/bin/sh\nexit 1\n' >"$BLIND_BIN/stat"
chmod +x "$BLIND_BIN/uname" "$BLIND_BIN/stat"

"$SCRIPT" sh -c "touch '$BLIND_MARK'; while [ ! -e '$BLIND_RELEASE' ]; do sleep 0.05; done" \
  >/dev/null 2>&1 &
BLIND_HOLDER=$!
await_path "$BLIND_MARK" || fail "the unreadable-age fixture never took the lock"
PATH="$BLIND_BIN:$PATH" FM_BUILD_LOCK_TICKET_STALE=1 "$SCRIPT" printf 'blind\n' \
  >"$BLIND_OUT" 2>/dev/null &
BLIND_WAITER=$!
sleep 3
touch "$BLIND_RELEASE"
await_pid_exit "$BLIND_WAITER" 100 || fail "a waiter whose ticket age is unreadable never acquired the lock"
wait "$BLIND_WAITER" 2>/dev/null || true
wait "$BLIND_HOLDER" 2>/dev/null || true
assert_equals 'blind' "$(cat "$BLIND_OUT" 2>/dev/null || true)" \
  "the waiter with an unreadable ticket age must still acquire"
settle_queue
pass "an unreadable ticket age is not treated as stale"

# --- a waiter killed in line leaves no residue in the lock root -------------
# The lockdir mutex mints its owner directory before the symlink that publishes
# it, and nothing points at one in between: a process killed inside that window
# strands a directory no release, no stale recovery and no later invocation
# would ever reach again. Minting before looking at the lock put every waiter
# through that window once per poll, so a killed waiter stranded one often
# enough to red this suite on GitHub's slower runners while passing locally.
#
# `mktemp` is shimmed to PARK a minting process inside that window rather than
# to race it, so this case decides the question instead of sampling it.
# Mutant: in fm_lock_try_create, mint the owner directory before the
# lock-exists check again.

MINT_SHIM="$TMP_ROOT/mktemp-shim"
MINT_MARK="$TMP_ROOT/minted-while-waiting"
MINT_RELEASE="$TMP_ROOT/mint-release"
mkdir -p "$MINT_SHIM"
REAL_MKTEMP=$(command -v mktemp) || fail "mktemp is required to park a minting process"

# Reports every owner directory minted for the PRIMARY build lock and holds its
# minting process there until this case releases it. The waiting line's own lock
# mints under a different name, so arriving in line is left at full speed.
cat > "$MINT_SHIM/mktemp" <<SHIM
#!/usr/bin/env bash
set -u
out=\$("$REAL_MKTEMP" "\$@") || exit \$?
printf '%s\n' "\$out"
case "\$*" in
  *fm-build-lock.owner.*)
    : > '$MINT_MARK'
    i=0
    while [ ! -e '$MINT_RELEASE' ] && [ "\$i" -lt 200 ]; do
      sleep 0.05
      i=\$((i + 1))
    done
    ;;
esac
SHIM
chmod +x "$MINT_SHIM/mktemp"

MINT_HOLD_MARK="$TMP_ROOT/mint-holding"
MINT_HOLD_RELEASE="$TMP_ROOT/mint-hold-release"
MINT_ERR="$TMP_ROOT/mint-waiter.err"
: > "$MINT_ERR"

"$SCRIPT" sh -c "touch '$MINT_HOLD_MARK'; while [ ! -e '$MINT_HOLD_RELEASE' ]; do sleep 0.05; done" \
  >/dev/null 2>&1 &
MINT_HOLDER=$!
await_path "$MINT_HOLD_MARK" || fail "the killed-waiter fixture never took the lock"

PATH="$MINT_SHIM:$PATH" "$SCRIPT" sleep 120 >/dev/null 2>"$MINT_ERR" &
MINT_WAITER=$!

# Either signal ends this wait, and which one arrives is the whole assertion:
# the waiter reporting that it is in line means it minted nothing, and the shim
# reporting a mint means it went through the strandable window to get there.
MINT_WAIT=0
while [ "$MINT_WAIT" -lt 600 ]; do
  [ -e "$MINT_MARK" ] && break
  grep -q 'waiting for the machine-wide build lock' "$MINT_ERR" 2>/dev/null && break
  sleep 0.1
  MINT_WAIT=$((MINT_WAIT + 1))
done
assert_absent "$MINT_MARK" \
  "a waiter polling a held lock minted an owner directory it could be killed inside"

kill -9 "$MINT_WAITER" 2>/dev/null || true
wait "$MINT_WAITER" 2>/dev/null || true
touch "$MINT_RELEASE"
touch "$MINT_HOLD_RELEASE"
wait "$MINT_HOLDER" 2>/dev/null || true
settle_queue
pass "a waiter killed while in line strands nothing in the lock root"

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

# This suite itself runs on CI, where CI and GITHUB_ACTIONS are real ambient
# markers - not just FM_BUILD_LOCK_CI - so "without a CI marker" and "CI=false"
# below must clear every marker fm_build_lock_is_ci checks, or they pass
# vacuously here and fail for real once actually run under CI.
CI_MARKER_UNSET_ARGS=(-u FM_BUILD_LOCK_CI)
for marker in CI CONTINUOUS_INTEGRATION BUILD_NUMBER GITHUB_ACTIONS GITLAB_CI \
  BUILDKITE CIRCLECI TRAVIS APPVEYOR TF_BUILD TEAMCITY_VERSION JENKINS_URL \
  BITBUCKET_BUILD_NUMBER DRONE CODEBUILD_BUILD_ID; do
  CI_MARKER_UNSET_ARGS+=(-u "$marker")
done

env "${CI_MARKER_UNSET_ARGS[@]}" FM_BUILD_LOCK_DIR="$UNUSABLE_ROOT" "$SCRIPT" true >/dev/null 2>&1
expect_code 2 $? "without a CI marker the same run must reach the lock and refuse the unusable root"

env "${CI_MARKER_UNSET_ARGS[@]}" CI=false FM_BUILD_LOCK_DIR="$CI_ROOT_OK" "$SCRIPT" sh -c 'exit 4'
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

# --- a nested invocation inside a hold runs straight through ----------------
# `mutex` around a command that itself takes the lock - bin/fm-test-run.sh
# takes it per script - must not wait on its own ancestor forever.
# Mutant: drop the "nested inside a hold" passthrough; the inner invocation then
# queues behind its own holder and the bounded wait below reds.

# shellcheck disable=SC2016 # The child sh expands its own positional argument.
"$SCRIPT" "$SCRIPT" sh -c 'printf "nested\n" >"$1"' _ "$TMP_ROOT/nested.out" \
  >/dev/null 2>"$TMP_ROOT/nested.err" &
NESTED=$!
await_pid_exit "$NESTED" 100 || fail "a nested invocation inside a hold deadlocked on its own holder"
wait "$NESTED" 2>/dev/null
expect_code 0 $? "a nested invocation inside a hold must succeed"
assert_equals 'nested' "$(cat "$TMP_ROOT/nested.out" 2>/dev/null)" "the nested command must run"

# A hold variable naming a process that does NOT own the lock is foreign, not a
# pass: it must queue behind the real holder like any other invocation.
# Mutant: drop the check that the named pid is the lock's recorded owner; the
# foreign invocation then runs at once, ahead of the holder finishing.
FOREIGN_ORDER="$TMP_ROOT/foreign.order"
FOREIGN_MARK="$TMP_ROOT/foreign-hold"
: >"$FOREIGN_ORDER"
"$SCRIPT" sh -c "touch '$FOREIGN_MARK'; sleep 1.5; echo holder-done >>'$FOREIGN_ORDER'" \
  >/dev/null 2>&1 &
FOREIGN_HOLDER=$!
await_path "$FOREIGN_MARK" || fail "the foreign-hold fixture never started"
FM_BUILD_LOCK_HELD_BY=$$ FM_BUILD_LOCK_HELD_LOCK="$LOCK_ROOT/fm-build-lock" \
  "$SCRIPT" sh -c "echo foreign >>'$FOREIGN_ORDER'" >/dev/null 2>&1
wait "$FOREIGN_HOLDER" 2>/dev/null || true
assert_equals "holder-done
foreign" "$(cat "$FOREIGN_ORDER")" "a hold variable naming a non-owner must not bypass the lock"
pass "a nested invocation inside a hold runs straight through, and a foreign hold variable does not"

# An outer hold that exported NO hold variables (an older installed entry point)
# must still be recognised: its pid is the lock owner and an ancestor of the
# inner invocation. The outer child runs with the variables unset via env -u.
# Mutant: drop the ancestor-owner check (keep only the variable check); the
# inner invocation queues behind its ancestor and the bounded wait reds.
# shellcheck disable=SC2016 # The child sh expands its own positional argument.
"$SCRIPT" env -u FM_BUILD_LOCK_HELD_BY -u FM_BUILD_LOCK_HELD_LOCK \
  "$SCRIPT" sh -c 'printf "ancestor\n" >"$1"' _ "$TMP_ROOT/ancestor.out" \
  >/dev/null 2>"$TMP_ROOT/ancestor.err" &
ANCESTOR=$!
await_pid_exit "$ANCESTOR" 100 || fail "a nested invocation without hold variables deadlocked on its ancestor holder"
wait "$ANCESTOR" 2>/dev/null
expect_code 0 $? "an ancestor-owned nested invocation must succeed"
assert_equals 'ancestor' "$(cat "$TMP_ROOT/ancestor.out" 2>/dev/null)" "the ancestor-nested command must run"
pass "a nested invocation under an owner that exported no hold variables runs straight through"

# --- a ceiling reaches the supervisor through the task status file ---------
# A long hold used to warn only on the holder's own stderr, which nobody reads
# when the command runs in the background. With FM_TASK_STATUS set, the first
# crossing of each ceiling appends one line to that task status file.

# Read a status line through the supervisor's own classifier, in a subshell so
# the library's globals stay out of this suite.
classify() {  # <function> <status-line>
  ( . "$ROOT/bin/fm-classify-lib.sh" && "$1" "$2" )
}

# Holder: one `note:` line naming the command and the queue, never a decision.
# Mutants: drop the holder's status append (no line); append it with a
# decision or blocker verb (the line then classifies as captain-relevant).
HOLD_STATUS="$TMP_ROOT/hold.status"
: >"$HOLD_STATUS"
HOLD_MARK="$TMP_ROOT/hold-status-running"
FM_TASK_STATUS="$HOLD_STATUS" FM_BUILD_LOCK_HOLD_WARN=1 \
  "$SCRIPT" sh -c "touch '$HOLD_MARK'; sleep 3.5" >/dev/null 2>&1 &
HOLD_HOLDER=$!
await_path "$HOLD_MARK" || fail "the holder-status fixture never started"
"$SCRIPT" true >/dev/null 2>&1 &
HOLD_WAITER=$!
wait "$HOLD_HOLDER" 2>/dev/null || true
wait "$HOLD_WAITER" 2>/dev/null || true
assert_equals 1 "$(grep -c '' "$HOLD_STATUS")" "a long hold must append exactly one status line, once per hold"
HOLD_LINE=$(cat "$HOLD_STATUS")
case "$HOLD_LINE" in
  'note: holding the machine-wide build lock for '*) : ;;
  *) fail "the holder's status line must be an informational note: $HOLD_LINE" ;;
esac
assert_contains "$HOLD_LINE" 'hold-status-running' "the holder's status line must name what it runs"
assert_contains "$HOLD_LINE" '1 waiting' "the holder's status line must say how many are queued"
assert_contains "$HOLD_LINE" 'not being killed' "the holder's status line must say the hold is not being killed"
classify status_is_captain_relevant "$HOLD_LINE" \
  && fail "the holder's status line must not wake firstmate as a decision: $HOLD_LINE"
classify status_line_is_unread_surface "$HOLD_LINE" \
  || fail "the holder's status line must reach firstmate's unread-status surface: $HOLD_LINE"
pass "a hold past its ceiling appends one informational note to the task status file"

# Waiter: a declared `paused:` wait naming the holder, then `working:` once in.
# Mutants: drop the waiter's status append; give it any verb but paused (the
# supervisor then reads the idle waiter as wedged or as a decision).
WAIT_STATUS="$TMP_ROOT/wait.status"
: >"$WAIT_STATUS"
WAIT_MARK="$TMP_ROOT/wait-status-running"
"$SCRIPT" sh -c "touch '$WAIT_MARK'; sleep 3.5" >/dev/null 2>&1 &
WAIT_HOLDER=$!
await_path "$WAIT_MARK" || fail "the waiter-status fixture never started"
FM_TASK_STATUS="$WAIT_STATUS" FM_BUILD_LOCK_WAIT_WARN=1 \
  "$SCRIPT" printf 'waited-in\n' >/dev/null 2>&1
wait "$WAIT_HOLDER" 2>/dev/null || true
WAIT_FIRST=$(sed -n 1p "$WAIT_STATUS")
WAIT_SECOND=$(sed -n 2p "$WAIT_STATUS")
assert_equals 2 "$(grep -c '' "$WAIT_STATUS")" "a long wait must append exactly a paused line and a working line"
classify status_is_paused "$WAIT_FIRST" \
  || fail "the waiter's first status line must be a declared paused: wait: $WAIT_FIRST"
assert_contains "$WAIT_FIRST" 'printf' "the waiter's paused line must name what it is waiting to run"
assert_contains "$WAIT_FIRST" 'held by pid ' "the waiter's paused line must name the holder"
case "$WAIT_SECOND" in
  'working: acquired the machine-wide build lock after '*) : ;;
  *) fail "the waiter must say working: once it gets in: $WAIT_SECOND" ;;
esac
pass "a wait past its ceiling appends a declared pause, then working once the lock is taken"

# No FM_TASK_STATUS, no line anywhere: a path is never guessed from the task id
# or the home. Mutant: derive a status path from FM_TASK_ID or FM_HOME when
# FM_TASK_STATUS is unset; a line then appears under this fake home.
GUESS_HOME="$TMP_ROOT/guess-home"
mkdir -p "$GUESS_HOME/state"
( unset FM_TASK_STATUS
  FM_HOME="$GUESS_HOME" FM_TASK_ID=guess-task FM_BUILD_LOCK_HOLD_WARN=1 \
    "$SCRIPT" sh -c 'sleep 2.5' >/dev/null 2>&1 )
assert_equals '' "$(find "$GUESS_HOME" -type f 2>/dev/null)" \
  "without FM_TASK_STATUS a ceiling must append nothing, not guess a status file"
FM_TASK_STATUS=relative.status FM_BUILD_LOCK_HOLD_WARN=1 \
  "$SCRIPT" sh -c 'sleep 2.5' >/dev/null 2>&1
[ ! -e relative.status ] || { rm -f relative.status; fail "a relative FM_TASK_STATUS must be ignored"; }
pass "without an absolute FM_TASK_STATUS a ceiling appends nothing"

# --- --label names the hold ---------------------------------------------------
# bin/fm-test-run.sh's holder is a bare `bash -c` loop; the label is what lets a
# waiter, --status and a status line say which script the hold is for.
# Mutant: ignore --label and render the command.

LABEL_MARK="$TMP_ROOT/label-running"
"$SCRIPT" --label 'bin/fm-test-run.sh tests/labelled.test.sh' \
  sh -c "touch '$LABEL_MARK'; sleep 3" >/dev/null 2>&1 &
LABEL_HOLDER=$!
await_path "$LABEL_MARK" || fail "the label fixture never started"
sleep 0.3
LABEL_LINE=$("$SCRIPT" --status)
wait "$LABEL_HOLDER" 2>/dev/null || true
assert_contains "$LABEL_LINE" 'running: bin/fm-test-run.sh tests/labelled.test.sh [in ' \
  "--status must show the label in place of the command"
assert_not_contains "$LABEL_LINE" 'sleep 3' "--label must replace the rendered command"
"$SCRIPT" --label '' true >/dev/null 2>&1
expect_code 2 $? "an empty --label must be refused"
pass "--label names the hold in place of the rendered command"

# --- --help teaches one invocation per run ----------------------------------
# Workers are pointed at --help as the contract, so it must carry the wrap rule.
# Mutant: drop the "Never put one invocation around a loop" sentence.

"$SCRIPT" --help >"$TMP_ROOT/help.out" 2>&1 || fail "--help failed"
assert_grep 'ONE INVOCATION PER RUN' "$TMP_ROOT/help.out" "--help must state one invocation per run"
assert_grep 'Never put one invocation around a' "$TMP_ROOT/help.out" \
  "--help must forbid one invocation around a loop of separate runs"
pass "--help states one invocation per run, never one around a loop of runs"

assert_equals 0 "$(lock_artifacts "$LOCK_ROOT")" "the suite must leave no lock behind"
pass "fm-build-lock behaves"
