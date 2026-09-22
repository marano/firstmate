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

# --- a command that takes the lock itself is never wrapped ------------------
# bin/fm-test-run.sh and bin/fm-stock-bash-lane.sh take a hold per unit
# themselves. Wrapping one is the loop-inside-one-hold shape: the outer hold
# spans the whole run while every inner acquire passes straight through as a
# nested hold, which measured as a 20-minute whole-lane hold. So an invocation
# asked to wrap one takes no hold at all and runs it straight through.
#
# Proved four ways, because they fail for different reasons: the command still
# runs, no hold is taken (against a root a real acquire would refuse), the
# inner per-unit holds are really live rather than passed through, and the same
# script under an unrecognised name still takes the hold. That last assertion
# drives the signals apart, so the case cannot pass by standing down for
# everything.
# Mutant: replace the fm_build_lock_self_locking_command branch with `if false`
# - the stand-down and per-unit assertions go red.
# Mutant: make fm_build_lock_self_locking_command return 0 unconditionally
# - the unrecognised-name assertion goes red (that mutant stands down for
# everything, so it also reds the mutual-exclusion case far above; the
# unrecognised-name run was confirmed to exit 0 instead of 2 on its own).

SELF_BIN="$TMP_ROOT/self-locking-bin"
mkdir -p "$SELF_BIN"
# A stand-in that does no locking of its own, for the "no hold is taken" proof.
for self_name in fm-test-run.sh fm-stock-bash-lane.sh ordinary-runner.sh; do
  # shellcheck disable=SC2016 # The generated script expands these itself.
  printf '#!/usr/bin/env bash\nprintf "ran-%%s\\n" "$(basename "$0")"\n' \
    > "$SELF_BIN/$self_name"
  chmod +x "$SELF_BIN/$self_name"
done

# UNUSABLE_ROOT's parent is a regular file, so a run that reaches the lock
# refuses with code 2; a run that stands down never looks at the root at all.
for self_name in fm-test-run.sh fm-stock-bash-lane.sh; do
  SELF_OUT=$(FM_BUILD_LOCK_DIR="$UNUSABLE_ROOT" "$SCRIPT" "$SELF_BIN/$self_name" 2>/dev/null)
  assert_equals "ran-$self_name" "$SELF_OUT" \
    "wrapping $self_name must run it straight through without taking a hold"
done

# The interpreter-prefixed form a caller may equally write.
SELF_OUT=$(FM_BUILD_LOCK_DIR="$UNUSABLE_ROOT" "$SCRIPT" bash "$SELF_BIN/fm-test-run.sh" 2>/dev/null)
assert_equals 'ran-fm-test-run.sh' "$SELF_OUT" \
  "wrapping a self-locking runner behind its interpreter must also stand down"

# The divergence: the very same script under a name that takes no lock of its
# own must still reach the lock, and so must refuse the unusable root.
FM_BUILD_LOCK_DIR="$UNUSABLE_ROOT" "$SCRIPT" "$SELF_BIN/ordinary-runner.sh" >/dev/null 2>&1
expect_code 2 $? \
  "an ordinary command must still reach the lock rather than stand down with it"

# --exclusive cannot widen a hold that is never taken, so it is ignored and said.
SELF_EXCL_ERR="$TMP_ROOT/self-exclusive.err"
FM_BUILD_LOCK_DIR="$UNUSABLE_ROOT" "$SCRIPT" --exclusive "$SELF_BIN/fm-test-run.sh" \
  >/dev/null 2>"$SELF_EXCL_ERR"
grep -q -- '--exclusive is ignored' "$SELF_EXCL_ERR" \
  || fail "standing down for a self-locking runner must say that --exclusive is ignored"

# The payoff: through the stand-down, the runner's own per-unit holds are the
# live ones. The unit reports what --status sees, which must name the UNIT, not
# an outer hold around the whole run.
cat > "$SELF_BIN/fm-test-run.sh" <<EOF
#!/usr/bin/env bash
set -u
"$SCRIPT" --label unit-1 -- sh -c '"$SCRIPT" --status > "\$1"' _ "$TMP_ROOT/unit-status.out"
EOF
chmod +x "$SELF_BIN/fm-test-run.sh"
"$SCRIPT" "$SELF_BIN/fm-test-run.sh" >/dev/null 2>&1 \
  || fail "the per-unit stand-in failed to run through the stand-down"
grep -q 'running: unit-1' "$TMP_ROOT/unit-status.out" \
  || fail "through the stand-down the live hold must be the runner's own per-unit hold, not an outer whole-run hold"
settle_queue
assert_equals 0 "$(lock_artifacts "$LOCK_ROOT")" \
  "the per-unit holds taken through a stand-down must all be released"
pass "a command that takes the lock itself is run straight through, leaving its per-unit holds live"

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
FM_TASK_STATUS="$HOLD_STATUS" FM_BUILD_LOCK_HOLD_WARN=2 \
  "$SCRIPT" sh -c "touch '$HOLD_MARK'; sleep 5" >/dev/null 2>&1 &
# shellcheck disable=SC2031
HOLD_HOLDER=$!
await_path "$HOLD_MARK" || fail "the holder-status fixture never started"
"$SCRIPT" true >/dev/null 2>&1 &
# shellcheck disable=SC2031
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
# shellcheck disable=SC2031
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
# shellcheck disable=SC2031
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


# ============================================================================
# The counting semaphore.
#
# Everything above this line ran with no slot-count file anywhere, which IS the
# dark landing: the effective count is 1, slot 1 is today's lock path, and every
# message, status line and --status above came from today's format strings.
# ============================================================================

# A private root per case. With FM_BUILD_LOCK_DIR set the machine-level settings
# live in that same root, which is the whole test seam: one root has exactly one
# count by construction, and no case can leak a count into another. The settings
# names deliberately do not start with `fm-build-lock`, so lock_artifacts above
# keeps meaning "lock residue" in these roots too.
slot_root() {  # <name> [<count>]
  local lockroot="$TMP_ROOT/root-$1"
  rm -rf "$lockroot"
  mkdir -p "$lockroot"
  [ "$#" -lt 2 ] || printf '%s\n' "$2" > "$lockroot/build-lock-slots"
  printf '%s\n' "$lockroot"
}

# One ordinary invocation against <root>, which also asserts the root is left
# clean. The slots are usable afterwards or the preceding case broke them.
settle_root() {  # <root>
  FM_BUILD_LOCK_DIR="$1" "$SCRIPT" true >/dev/null 2>&1 \
    || fail "the slots were unusable after the preceding case"
  assert_equals '' "$(slot_residue "$1")" \
    "the preceding case left build-lock residue behind"
}

# Residue this change owns: slot links, their owner directories, their holder
# records and their steal guards, listed by name so a failure says what is left.
#
# The waiting line's own lock is excluded, and only it. Under contention the
# lockdir primitive can strand an owner directory for that lock: one arrival's
# `ln -s` follows another's live symlink into its owner directory, and if the
# holder releases before the loser cleans up, the stray link is left inside an
# owner directory that `rmdir` can then never remove. That is nothing to do with
# slots - it reproduces at nine concurrent arrivals against the PRE-CHANGE
# script too, about one run in six - and it is reported separately. Excluding
# one name rather than dropping the assertion is the point: residue of any
# other kind still reds here.
slot_residue() {  # <root>
  find "$1" -maxdepth 1 -name 'fm-build-lock*' \
    ! -name 'fm-build-lock.queue.lock.owner.*' 2>/dev/null \
    | sed "s#^$1/##" | sort | tr '\n' ' '
}

# Start a fixture that takes a slot and holds it until its release marker
# appears, recording its pid in <pid-var>. Never started through a command
# substitution: the background job would belong to that subshell and outlive the
# case that started it.
hold_slot() {  # <pid-var> <root> <tag> [args-before-the-command...]
  local var=$1 lockroot=$2 tag=$3
  shift 3
  FM_BUILD_LOCK_DIR="$lockroot" "$SCRIPT" "$@" sh -c \
    "touch '$TMP_ROOT/$tag.held'; while [ ! -e '$TMP_ROOT/$tag.release' ]; do sleep 0.05; done" \
    >/dev/null 2>&1 &
  # shellcheck disable=SC2031  # $! is the job started just above, not a subshell's
  printf -v "$var" '%s' "$!"
  await_path "$TMP_ROOT/$tag.held" || fail "the $tag fixture never took a slot"
}

release_slot() {  # <pid> <tag>
  touch "$TMP_ROOT/$2.release"
  wait "$1" 2>/dev/null || true
}

# The exclusion gauge. Each job marks itself present, waits, records how many
# marks it can see with it, then stays a little longer. The largest number any
# job recorded is the most that ever held a slot at one moment, which is both
# the upper bound exclusion needs and the lower bound that proves the slots are
# real rather than one mutex wearing N names.
GAUGE_JOB="$TMP_ROOT/gauge-job.sh"
cat > "$GAUGE_JOB" <<'JOB'
#!/usr/bin/env bash
set -u
marks=$1/marks
obs=$1/obs
: > "$marks/$$"
sleep 0.3
# A loaded runner can start the holders further apart than any fixed sleep, so
# when the caller names how many must be present, wait for them (bounded).
tries=0
while [ "$(ls "$marks" | wc -l | tr -d ' ')" -lt "${GAUGE_WANT:-0}" ] && [ "$tries" -lt 200 ]; do
  sleep 0.05
  tries=$((tries + 1))
done
ls "$marks" | wc -l | tr -d ' ' > "$obs/$$"
sleep 0.5
rm -f "$marks/$$"
JOB
chmod +x "$GAUGE_JOB"

GAUGE_SEQ=0
GAUGE_MAX=0
gauge_run() {  # <root> <jobs> [extra-args-before-the-command...]
  local lockroot=$1 jobs=$2 i=0 pid pids='' dir
  shift 2
  GAUGE_SEQ=$((GAUGE_SEQ + 1))
  dir="$TMP_ROOT/gauge.$GAUGE_SEQ"
  mkdir -p "$dir/marks" "$dir/obs"
  while [ "$i" -lt "$jobs" ]; do
    i=$((i + 1))
    FM_BUILD_LOCK_DIR="$lockroot" "$SCRIPT" "$@" bash "$GAUGE_JOB" "$dir" >/dev/null 2>&1 &
    pids="$pids $!"
  done
  for pid in $pids; do
    wait "$pid" 2>/dev/null || true
  done
  GAUGE_MAX=$(cat "$dir"/obs/* 2>/dev/null | sort -n | tail -1)
  case "$GAUGE_MAX" in
    ''|*[!0-9]*) GAUGE_MAX=0 ;;
  esac
}

# --- N holders run together, and never more than N --------------------------
# A1 and A2 are two assertions on one gauge and neither is redundant: a plain
# mutex satisfies A1 and proves nothing, while A2 alone would pass a slot loop
# that ran to N+1.
# Mutants: (A1) run the slot loop to N+1 - the gauge records N+1; (A2) stop the
# slot loop at slot 1 - the gauge records 1 and A1 still passes.

for n in 2 3; do
  GAUGE_ROOT=$(slot_root "gauge$n" "$n")
  GAUGE_WANT=$n gauge_run "$GAUGE_ROOT" $((3 * n))
  [ "$GAUGE_MAX" -le "$n" ] \
    || fail "$GAUGE_MAX invocations held a slot at once under a count of $n"
  assert_equals "$n" "$GAUGE_MAX" \
    "a count of $n never actually ran $n invocations together"
  assert_equals '' "$(slot_residue "$GAUGE_ROOT")" \
    "a count of $n left build-lock residue behind"
done
pass "a count of N runs exactly N invocations at once, never more, and leaves nothing behind"

# --- only the OLDEST ticket may try, at every count -------------------------
# The rejected generalisation is "the N oldest may try". With both slots busy it
# makes the two oldest eligible, so when one frees, whichever polls first takes
# it - and a tight release-and-rejoin loop always polls first. Measured under
# that rule at N=2, the later arrival took the freed slot in every run and ran
# 7, 7 and 23 times before the earlier one.
# Mutant: in fm_build_lock_my_turn, admit while fewer than N tickets are ahead
# (`ahead < N`) instead of only the oldest.

FAIR2_ROOT=$(slot_root fair2 2)
FAIR2_ORDER="$TMP_ROOT/fair2-order"
FAIR2_PATIENT_ERR="$TMP_ROOT/fair2-patient.err"
FAIR2_BARGER_ERR="$TMP_ROOT/fair2-barger.err"
: > "$FAIR2_ORDER"
: > "$FAIR2_PATIENT_ERR"
: > "$FAIR2_BARGER_ERR"

FAIR2_A=
FAIR2_B=
hold_slot FAIR2_A "$FAIR2_ROOT" fair2-a
hold_slot FAIR2_B "$FAIR2_ROOT" fair2-b

FM_BUILD_LOCK_DIR="$FAIR2_ROOT" FM_BUILD_LOCK_POLL=2 FM_BUILD_LOCK_NOTICE_INTERVAL=1 \
  "$SCRIPT" sh -c "printf 'patient\n' >> '$FAIR2_ORDER'" >/dev/null 2>"$FAIR2_PATIENT_ERR" &
FAIR2_PATIENT=$!
await_grep 'WAITING, not wedged' "$FAIR2_PATIENT_ERR" \
  || fail "the patient waiter never reported that it was waiting for a slot"

( while [ ! -e "$TMP_ROOT/fair2-barge-stop" ]; do
    FM_BUILD_LOCK_DIR="$FAIR2_ROOT" FM_BUILD_LOCK_POLL=0.02 FM_BUILD_LOCK_NOTICE_INTERVAL=1 \
      "$SCRIPT" sh -c "printf 'barger\n' >> '$FAIR2_ORDER'" >/dev/null 2>>"$FAIR2_BARGER_ERR" || true
  done ) &
FAIR2_BARGER=$!
await_grep 'WAITING, not wedged' "$FAIR2_BARGER_ERR" \
  || fail "the barging loop never reached the slots"

# The patient waiter's own poll, observable from outside: it prints on waking,
# then sleeps its full two seconds before looking again. Freeing a slot here
# hands the barger a window in which it polls a hundred times and the patient
# waiter not once.
await_grep 'still waiting' "$FAIR2_PATIENT_ERR" || fail "the patient waiter never reported a poll"
release_slot "$FAIR2_A" fair2-a

await_pid_exit "$FAIR2_PATIENT" || fail "the patient waiter never got a slot"
wait "$FAIR2_PATIENT" 2>/dev/null || true
touch "$TMP_ROOT/fair2-barge-stop"
await_pid_exit "$FAIR2_BARGER" || fail "the barging loop never finished"
wait "$FAIR2_BARGER" 2>/dev/null || true
assert_equals 'patient' "$(head -1 "$FAIR2_ORDER")" \
  "a tight release-then-reacquire loop took the freed slot ahead of an earlier arrival"
assert_grep 'barger' "$FAIR2_ORDER" "the barging loop never got in at all, so this case proved nothing"
release_slot "$FAIR2_B" fair2-b
settle_root "$FAIR2_ROOT"
pass "with several slots, only the oldest ticket may try, so an earlier arrival still goes first"

# --- a dead holder's slot is reclaimed, a live holder's is not --------------
# Each slot is its own instance of the lockdir mutex, with its own pid record
# and its own steal guard, so reclaiming one cannot disturb another.
# Mutants: (a) make the dead-holder path unreachable - C never gets in;
# (b) reclaim the first busy slot without testing that slot's own pid - slot 1
# stops recording the live holder A.

RECLAIM_ROOT=$(slot_root reclaim 2)
RECLAIM_A_MARK="$TMP_ROOT/reclaim-a"
RECLAIM_A_RELEASE="$TMP_ROOT/reclaim-a-release"
RECLAIM_B_MARK="$TMP_ROOT/reclaim-b"
FM_BUILD_LOCK_DIR="$RECLAIM_ROOT" "$SCRIPT" sh -c \
  "touch '$RECLAIM_A_MARK'; while [ ! -e '$RECLAIM_A_RELEASE' ]; do sleep 0.05; done" \
  >/dev/null 2>&1 &
RECLAIM_A=$!
await_path "$RECLAIM_A_MARK" || fail "the live-holder fixture never took a slot"
FM_BUILD_LOCK_DIR="$RECLAIM_ROOT" "$SCRIPT" sh -c "touch '$RECLAIM_B_MARK'; sleep 120" \
  >/dev/null 2>&1 &
RECLAIM_B=$!
await_path "$RECLAIM_B_MARK" || fail "the dead-holder fixture never took a slot"
sleep 0.3
RECLAIM_A_PID=$(cat "$RECLAIM_ROOT/fm-build-lock/pid" 2>/dev/null || true)
[ -n "$RECLAIM_A_PID" ] || fail "slot 1 recorded no holder while both slots were held"
# SIGKILL the wrapper, so no trap runs and slot 2 is left recorded by a process
# that no longer exists.
kill -9 "$RECLAIM_B" 2>/dev/null || true
wait "$RECLAIM_B" 2>/dev/null || true
pkill -P "$RECLAIM_B" 2>/dev/null || true

RECLAIM_C_OUT="$TMP_ROOT/reclaim-c.out"
( FM_BUILD_LOCK_DIR="$RECLAIM_ROOT" "$SCRIPT" printf 'reclaimed\n' > "$RECLAIM_C_OUT" 2>/dev/null ) &
RECLAIM_C=$!
await_pid_exit "$RECLAIM_C" || fail "a slot left by a dead holder blocked the next invocation forever"
wait "$RECLAIM_C" 2>/dev/null || true
assert_equals 'reclaimed' "$(cat "$RECLAIM_C_OUT" 2>/dev/null || true)" \
  "a slot whose holder died must be reclaimed while another slot is still held"
kill -0 "$RECLAIM_A" 2>/dev/null || fail "the live holder stopped before this case could check its slot"
assert_equals "$RECLAIM_A_PID" "$(cat "$RECLAIM_ROOT/fm-build-lock/pid" 2>/dev/null || true)" \
  "reclaiming a dead holder's slot took the live holder's slot with it"
touch "$RECLAIM_A_RELEASE"
wait "$RECLAIM_A" 2>/dev/null || true
settle_root "$RECLAIM_ROOT"
pass "a dead holder's slot is reclaimed while a live holder keeps its own, and nothing is left behind"

# --- N=1 is today's lock, byte for byte -------------------------------------
# The whole suite above already runs with no slot-count file. This pins the
# WORDING as well: the normalised stderr of a waiter and of a holder, the three
# status-file lines, and --status held and free. The transcript below was
# captured from the pre-change script and is identical to it.
# Mutants: use the multi-slot --status format at N=1; rename slot 1's path; say
# "build slot" instead of "build lock" at N=1 - each reds this transcript, and
# the first two also red the existing --status and --lock-path cases above.

n1_transcript() {  # <root>
  local lockroot=$1
  local w="$lockroot/work"
  local e h waiter
  mkdir -p "$w"
  e='[0-9][0-9]*[hms]\([0-9][0-9]*[ms]\)\{0,1\}'
  norm() {
    sed -e "s#$w#WORK#g" -e "s#$lockroot#ROOT#g" \
        -e 's/pid [0-9][0-9]*/pid PID/g' \
        -e "s/for $e/for AGE/g" -e "s/after $e/after AGE/g" \
        -e "s/WAITING $e/WAITING AGE/g" -e "s/waiting $e/waiting AGE/g" \
        -e "s/build lock $e/build lock AGE/g" -e "s/its slot $e/its slot AGE/g" \
        -e "s#\[in [^]]*\]#[in CWD]#g"
  }
  # Never started through a command substitution: the background job would
  # belong to that subshell and outlive the section that started it.
  hold_until() {  # <mark> <release>
    FM_BUILD_LOCK_DIR="$lockroot" "$SCRIPT" sh -c \
      "touch '$1'; while [ ! -e '$2' ]; do sleep 0.05; done" >/dev/null 2>&1 &
    HOLDER=$!
    await_path "$1" || fail "a transcript fixture never took the lock"
  }

  echo "== free =="
  FM_BUILD_LOCK_DIR="$lockroot" "$SCRIPT" --status 2>&1 | norm

  echo "== held =="
  hold_until "$w/h1" "$w/r1"
  h=$HOLDER
  sleep 0.3
  FM_BUILD_LOCK_DIR="$lockroot" "$SCRIPT" --status 2>&1 | norm
  touch "$w/r1"
  wait "$h" 2>/dev/null || true

  echo "== waiter =="
  hold_until "$w/h2" "$w/r2"
  h=$HOLDER
  : > "$w/wait.status"
  ( FM_BUILD_LOCK_DIR="$lockroot" FM_TASK_STATUS="$w/wait.status" \
      FM_BUILD_LOCK_NOTICE_INTERVAL=1 FM_BUILD_LOCK_WAIT_WARN=1 FM_BUILD_LOCK_HOLD_WARN=1 \
      "$SCRIPT" sleep 2 >/dev/null 2>"$w/wait.err" ) &
  waiter=$!
  await_grep 'past the 1s ceiling' "$w/wait.err" \
    || fail "the transcript waiter never passed its wait ceiling"
  sleep 2
  # Snapshot the waiting notices while the holder is certainly still alive. A
  # notice that lands in the same instant as the release reads the lock between
  # two owners and so names no holder: a real shape of this output in every
  # version of this script, but a coin toss, and a golden transcript must not
  # turn on one.
  cp "$w/wait.err" "$w/wait.err.snapshot"
  touch "$w/r2"
  wait "$waiter" 2>/dev/null || true
  wait "$h" 2>/dev/null || true
  norm < "$w/wait.err.snapshot" | LC_ALL=C sort -u
  echo "-- after the release --"
  norm < "$w/wait.err" | LC_ALL=C sort -u \
    | grep -E 'acquired the machine-wide|this command has held' || true
  echo "-- status --"
  norm < "$w/wait.status"

  echo "== holder with a waiter =="
  : > "$w/hold.status"
  FM_BUILD_LOCK_DIR="$lockroot" FM_TASK_STATUS="$w/hold.status" FM_BUILD_LOCK_HOLD_WARN=3 \
    "$SCRIPT" sh -c "touch '$w/h3'; sleep 6" >/dev/null 2>"$w/hold.err" &
  h=$!
  await_path "$w/h3" || fail "the transcript holder fixture never started"
  : > "$w/w3.err"
  FM_BUILD_LOCK_DIR="$lockroot" "$SCRIPT" true >/dev/null 2>"$w/w3.err" &
  waiter=$!
  # The waiter must be IN LINE before the ceiling fires, or the holder's line
  # reports a queue depth that depends on the scheduler rather than on the case.
  await_grep 'WAITING, not wedged' "$w/w3.err" || fail "the transcript waiter never got into line"
  wait "$h" 2>/dev/null || true
  wait "$waiter" 2>/dev/null || true
  norm < "$w/hold.err" | LC_ALL=C sort -u
  echo "-- status --"
  norm < "$w/hold.status"

  echo "== free again =="
  FM_BUILD_LOCK_DIR="$lockroot" "$SCRIPT" --status 2>&1 | norm
  echo "== residue =="
  lock_artifacts "$lockroot"
}

read -r -d '' N1_GOLDEN <<'GOLDEN' || true
== free ==
free
== held ==
held by pid PID for AGE running: sh -c touch\ \'WORK/h1\'\;\ while\ \[\ \!\ -e\ \'WORK/r1\'\ \]\;\ do\ sleep\ 0.05\;\ done [in CWD]
== waiter ==
fm-build-lock: WARNING: still WAITING AGE for the machine-wide build lock, past the 1s ceiling - held by pid PID for AGE running: sh -c touch\ \'WORK/h2\'\;\ while\ \[\ \!\ -e\ \'WORK/r2\'\ \]\;\ do\ sleep\ 0.05\;\ done [in CWD]
fm-build-lock: WARNING: the holder has held the build lock AGE, past the 1s ceiling; it is not being killed
fm-build-lock: waiting for the machine-wide build lock - this process is WAITING, not wedged (held by pid PID for AGE running: sh -c touch\ \'WORK/h2\'\;\ while\ \[\ \!\ -e\ \'WORK/r2\'\ \]\;\ do\ sleep\ 0.05\;\ done [in CWD])
-- after the release --
fm-build-lock: WARNING: this command has held the machine-wide build lock for AGE and is blocking every other local build: sleep 2 [in CWD]
fm-build-lock: acquired the machine-wide build lock after AGE
-- status --
paused: waiting AGE for the machine-wide build lock to run sleep 2 [in CWD] - held by pid PID for AGE running: sh -c touch\ \'WORK/h2\'\;\ while\ \[\ \!\ -e\ \'WORK/r2\'\ \]\;\ do\ sleep\ 0.05\;\ done [in CWD]
working: acquired the machine-wide build lock after AGE
note: holding the machine-wide build lock for AGE with 0 waiting, past the 1s ceiling; not being killed: sleep 2 [in CWD]
== holder with a waiter ==
fm-build-lock: WARNING: this command has held the machine-wide build lock for AGE and is blocking every other local build: sh -c touch\ \'WORK/h3\'\;\ sleep\ 6 [in CWD]
-- status --
note: holding the machine-wide build lock for AGE with 1 waiting, past the 3s ceiling; not being killed: sh -c touch\ \'WORK/h3\'\;\ sleep\ 6 [in CWD]
== free again ==
free
== residue ==
0
GOLDEN

N1_ABSENT_ROOT=$(slot_root n1-absent)
assert_equals "$N1_GOLDEN" "$(n1_transcript "$N1_ABSENT_ROOT")" \
  "with no slot-count file the lock must behave and speak exactly as it did before slots existed"

N1_ONE_ROOT=$(slot_root n1-one 1)
assert_equals "$N1_GOLDEN" "$(n1_transcript "$N1_ONE_ROOT")" \
  "a slot-count file holding 1 must behave and speak exactly as no file at all"
[ -z "$(find "$N1_ONE_ROOT" -maxdepth 1 -name 'fm-build-lock.slot*' 2>/dev/null)" ] \
  || fail "a count of 1 created a slot above slot 1"
pass "a count of 1, configured or not, is today's lock in every observable respect"

# --- the slot count's grammar ------------------------------------------------
# A bad value falls back to 1 and warns; it never stops a build, because one
# typo that failed every build, lint and pipeline step on the machine would be
# far worse than one that under-admits.
# Mutants: die on a malformed value (the wrapped command stops running); read a
# malformed value as a number or as unlimited (the gauge exceeds 1); drop the
# clamp (the reported count exceeds the core count).

grammar_case() {  # <name> <expected-n> <expect-warning 0|1> [writer...]
  local name=$1 expect=$2 warn=$3 lockroot err
  shift 3
  lockroot=$(slot_root "grammar-$name")
  [ "$#" -eq 0 ] || "$@" "$lockroot/build-lock-slots"
  err="$TMP_ROOT/grammar-$name.err"
  FM_BUILD_LOCK_DIR="$lockroot" "$SCRIPT" sh -c 'exit 7' 2>"$err"
  expect_code 7 $? "a slot count that is $name must still run the command and pass its status through"
  assert_equals "$warn" "$(grep -c 'fm-build-lock: WARNING' "$err" || true)" \
    "a slot count that is $name must warn exactly $warn time(s) on stderr"
  if [ "$warn" = 1 ]; then
    assert_grep "build-lock-slots" "$err" "the warning for $name must name the file"
  fi
  gauge_run "$lockroot" "$((expect + 1))"
  assert_equals "$expect" "$GAUGE_MAX" "a slot count that is $name must be read as $expect"
  settle_root "$lockroot"
}

write_line() { printf '%s\n' "$1" > "$2"; }
write_raw() { printf '%s' "$1" > "$2"; }
write_two_lines() { printf '2\n3\n' > "$1"; }
write_symlink() { ln -s /dev/null "$1"; }

grammar_case absent      1 0
grammar_case one         1 0 write_line 1
grammar_case three       3 0 write_line 3
grammar_case zero        1 1 write_line 0
grammar_case negative    1 1 write_line -2
grammar_case words       1 1 write_line two
grammar_case empty       1 1 write_raw ''
grammar_case two-lines   1 1 write_two_lines
grammar_case inner-space 1 1 write_line '2 3'
grammar_case symlink     1 1 write_symlink
pass "the slot count falls back to 1 and warns on every bad value, and never stops the build"

# Clamped to the machine rather than gauged, because proving a clamp of ten by
# running ten concurrent holders would measure this machine, not the clamp.
CLAMP_ROOT=$(slot_root clamp 100000)
CLAMP_ERR="$TMP_ROOT/clamp.err"
CLAMP_STATUS=$(FM_BUILD_LOCK_DIR="$CLAMP_ROOT" "$SCRIPT" --status 2>"$CLAMP_ERR")
CORES=$(getconf _NPROCESSORS_ONLN 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 0)
[ "$CORES" -gt 0 ] || fail "this host reports no online core count, so the clamp cannot be checked"
assert_contains "$CLAMP_STATUS" "0 of $CORES build slots held" \
  "a slot count above the online core count must be clamped to it"
assert_equals 1 "$(grep -c 'fm-build-lock: WARNING' "$CLAMP_ERR" || true)" \
  "a clamped slot count must warn exactly once"
assert_contains "$CLAMP_STATUS" '100000' "--status must name the value that was clamped"
settle_root "$CLAMP_ROOT"
pass "a slot count above the online core count is clamped to it and says so"

# --- a waiting head picks up a raised count ---------------------------------
# Mutant: read the count once at startup; the waiter stays blocked and the
# bounded wait below reds.

RAISE_ROOT=$(slot_root raise)
RAISE_MARK="$TMP_ROOT/raise-held"
RAISE_RELEASE="$TMP_ROOT/raise-release"
RAISE_ERR="$TMP_ROOT/raise.err"
: > "$RAISE_ERR"
FM_BUILD_LOCK_DIR="$RAISE_ROOT" "$SCRIPT" sh -c \
  "touch '$RAISE_MARK'; while [ ! -e '$RAISE_RELEASE' ]; do sleep 0.05; done" >/dev/null 2>&1 &
RAISE_HOLDER=$!
await_path "$RAISE_MARK" || fail "the raised-count fixture never took the lock"
FM_BUILD_LOCK_DIR="$RAISE_ROOT" "$SCRIPT" printf 'raised\n' >"$TMP_ROOT/raise.out" 2>"$RAISE_ERR" &
RAISE_WAITER=$!
await_grep 'WAITING, not wedged' "$RAISE_ERR" || fail "the raised-count waiter never got into line"
FM_BUILD_LOCK_DIR="$RAISE_ROOT" "$SCRIPT" --set-slots 2 >/dev/null 2>&1 \
  || fail "--set-slots 2 failed"
await_pid_exit "$RAISE_WAITER" 200 || fail "a waiter never picked up a raised slot count"
wait "$RAISE_WAITER" 2>/dev/null || true
kill -0 "$RAISE_HOLDER" 2>/dev/null \
  || fail "the first holder finished before the waiter got in, so the raise proved nothing"
assert_equals 'raised' "$(cat "$TMP_ROOT/raise.out" 2>/dev/null || true)" \
  "the waiter must run once the count is raised"
touch "$RAISE_RELEASE"
wait "$RAISE_HOLDER" 2>/dev/null || true
assert_equals "$RAISE_ROOT/build-lock-slots" "$(FM_BUILD_LOCK_DIR="$RAISE_ROOT" "$SCRIPT" --slots-path)" \
  "--slots-path must print the file --set-slots writes"
settle_root "$RAISE_ROOT"
pass "a waiting head picks up a raised slot count within a poll, and --slots-path names that file"

# --- a lowered count drains and is not refilled -----------------------------
# Holders above the new count finish normally, but nothing new is admitted while
# as many live holders as the new count allows remain on ANY slot on disk.
# Mutant: count holders only within 1..N; the waiter takes slot 1 and two run
# together under a count of one.

LOWER_ROOT=$(slot_root lower 2)
LOWER_OUT="$TMP_ROOT/lower.out"
LOWER_ERR="$TMP_ROOT/lower.err"
: > "$LOWER_OUT"
: > "$LOWER_ERR"
LOWER_A=
LOWER_B=
hold_slot LOWER_A "$LOWER_ROOT" lower-a
hold_slot LOWER_B "$LOWER_ROOT" lower-b
FM_BUILD_LOCK_DIR="$LOWER_ROOT" "$SCRIPT" printf 'lowered\n' >"$LOWER_OUT" 2>"$LOWER_ERR" &
LOWER_WAITER=$!
await_grep 'WAITING, not wedged' "$LOWER_ERR" || fail "the lowered-count waiter never got into line"
FM_BUILD_LOCK_DIR="$LOWER_ROOT" "$SCRIPT" --set-slots 1 >/dev/null 2>&1 || fail "--set-slots 1 failed"
release_slot "$LOWER_A" lower-a
sleep 2
kill -0 "$LOWER_WAITER" 2>/dev/null \
  || fail "a waiter was admitted under a count of 1 while a holder above that count was still running"
assert_equals '' "$(cat "$LOWER_OUT" 2>/dev/null || true)" \
  "a waiter ran under a count of 1 while a holder above that count was still running"
release_slot "$LOWER_B" lower-b
await_pid_exit "$LOWER_WAITER" || fail "the waiter never got in after the drained holder finished"
wait "$LOWER_WAITER" 2>/dev/null || true
assert_equals 'lowered' "$(cat "$LOWER_OUT" 2>/dev/null || true)" \
  "the waiter must run once the holder above the lowered count finishes"
settle_root "$LOWER_ROOT"
pass "a lowered count drains rather than being refilled, and admits nobody until it has"

# --- a slot left by a killed high holder is retired, not left on the machine -
# A claimer stops at the first free slot, so on a quiet machine nothing ever
# reaches a high one again: a record left there by a SIGKILLed holder would sit
# in the lock root for the life of the machine, and an idle machine having no
# build-lock residue is a guarantee slots do not get to drop.
# Mutant: drop the dead-slot reap from the acquire path; the single ordinary run
# below then leaves the killed holder's slot 2 behind and the residue check reds.

RESIDUE_ROOT=$(slot_root residue 2)
RESIDUE_A=
hold_slot RESIDUE_A "$RESIDUE_ROOT" residue-a
FM_BUILD_LOCK_DIR="$RESIDUE_ROOT" "$SCRIPT" sh -c \
  "touch '$TMP_ROOT/residue-high'; sleep 120" >/dev/null 2>&1 &
RESIDUE_B=$!
await_path "$TMP_ROOT/residue-high" || fail "the high-slot fixture never took slot 2"
kill -9 "$RESIDUE_B" 2>/dev/null || true
wait "$RESIDUE_B" 2>/dev/null || true
pkill -P "$RESIDUE_B" 2>/dev/null || true
release_slot "$RESIDUE_A" residue-a
[ "$(lock_artifacts "$RESIDUE_ROOT")" -gt 0 ] \
  || fail "the SIGKILLed high-slot holder should have left a slot record behind"
# One ordinary run on an otherwise idle machine, which takes slot 1 and never
# reaches slot 2 on its own.
FM_BUILD_LOCK_DIR="$RESIDUE_ROOT" "$SCRIPT" true >/dev/null 2>&1 \
  || fail "the slots were unusable after a high slot was left by a dead holder"
assert_equals '' "$(slot_residue "$RESIDUE_ROOT")" \
  "a slot left by a dead high holder was still in the lock root after an idle-machine run"
pass "a slot left by a killed high holder is retired by the next acquisition, not left behind"

# --- a nested invocation inside a HIGH slot runs straight through -----------
# An invocation nested inside a slot-2 hold that only recognised slot 1 would
# queue for a second slot while its own ancestor waits on it, taking two slots
# for one run at best and deadlocking at worst.
# Mutants: compare FM_BUILD_LOCK_HELD_LOCK only with slot 1's path; read only
# slot 1's owner in the ancestor check. Each leaves the inner invocation queued
# and the bounded wait below reds.

nested_high_slot_case() {  # <name> <inner-prefix...>
  local name=$1 lockroot mark release out
  shift
  lockroot=$(slot_root "nested-$name" 2)
  mark="$TMP_ROOT/nested-$name-held"
  release="$TMP_ROOT/nested-$name-release"
  out="$TMP_ROOT/nested-$name.out"
  FM_BUILD_LOCK_DIR="$lockroot" "$SCRIPT" sh -c \
    "touch '$mark'; while [ ! -e '$release' ]; do sleep 0.05; done" >/dev/null 2>&1 &
  local fixture=$!
  await_path "$mark" || fail "the $name fixture never took slot 1"
  # shellcheck disable=SC2016 # The inner sh expands its own positional argument.
  FM_BUILD_LOCK_DIR="$lockroot" "$SCRIPT" "$@" "$SCRIPT" sh -c 'printf "inner\n" >"$1"' _ "$out" \
    >/dev/null 2>"$TMP_ROOT/nested-$name.err" &
  local outer=$!
  await_pid_exit "$outer" 200 \
    || fail "an invocation nested inside a slot-2 hold ($name) deadlocked on its own holder"
  wait "$outer" 2>/dev/null
  expect_code 0 $? "the $name nested invocation must succeed"
  assert_equals 'inner' "$(cat "$out" 2>/dev/null || true)" "the $name nested command must run"
  kill -0 "$fixture" 2>/dev/null \
    || fail "the $name fixture released slot 1 before the inner invocation finished"
  touch "$release"
  wait "$fixture" 2>/dev/null || true
  settle_root "$lockroot"
}

nested_high_slot_case ancestor env -u FM_BUILD_LOCK_HELD_BY -u FM_BUILD_LOCK_HELD_LOCK
pass "a nested invocation under an ancestor holding a high slot runs straight through"

# --- the hold VARIABLES alone recognise a high slot -------------------------
# Driven from this suite rather than from inside the holder, because an
# invocation nested under the holder is also its descendant, so the ancestor
# check would let it through whatever the variables said. That is not a detail:
# it is what let a mutant comparing FM_BUILD_LOCK_HELD_LOCK only against slot
# 1's path survive the case above. Here nothing but the variables can work,
# because the holder is a sibling of this shell rather than an ancestor.
# Mutant: compare FM_BUILD_LOCK_HELD_LOCK only with slot 1's path; the
# invocation then queues behind two held slots and the bounded wait reds.

VARS_ROOT=$(slot_root nested-vars 2)
VARS_A=
VARS_B=
hold_slot VARS_A "$VARS_ROOT" vars-a
hold_slot VARS_B "$VARS_ROOT" vars-b
VARS_SLOT2="$VARS_ROOT/fm-build-lock.slot2"
await_path "$VARS_SLOT2" || fail "the second hold-variable fixture never took slot 2"
VARS_PID=$(cat "$VARS_SLOT2/pid" 2>/dev/null || true)
case "$VARS_PID" in
  ''|*[!0-9]*) fail "slot 2 recorded no holder for the hold-variable case" ;;
esac
VARS_OUT="$TMP_ROOT/nested-vars.out"
FM_BUILD_LOCK_DIR="$VARS_ROOT" FM_BUILD_LOCK_HELD_BY="$VARS_PID" FM_BUILD_LOCK_HELD_LOCK="$VARS_SLOT2" \
  "$SCRIPT" printf 'by-variables\n' >"$VARS_OUT" 2>/dev/null &
VARS_INNER=$!
await_pid_exit "$VARS_INNER" 100 \
  || fail "hold variables naming slot 2 did not pass an invocation through while both slots were held"
wait "$VARS_INNER" 2>/dev/null || true
assert_equals 'by-variables' "$(cat "$VARS_OUT" 2>/dev/null || true)" \
  "the invocation carrying slot 2's hold variables must run"
if ! kill -0 "$VARS_A" 2>/dev/null || ! kill -0 "$VARS_B" 2>/dev/null; then
  fail "a hold-variable fixture ended before the case could check it"
fi
release_slot "$VARS_A" vars-a
release_slot "$VARS_B" vars-b
settle_root "$VARS_ROOT"
pass "hold variables naming a high slot pass an invocation through with no ancestor to fall back on"

# --- --status names every slot and every holder -----------------------------
# Mutant: print slot 1 only.

ST_ROOT=$(slot_root status3 3)
assert_contains "$(FM_BUILD_LOCK_DIR="$ST_ROOT" "$SCRIPT" --status)" 'free - 0 of 3 build slots held' \
  "with nothing held --status must still begin with free and name the count"
ST_A=
ST_B=
ST_C=
hold_slot ST_A "$ST_ROOT" st-a --label labelled-a
hold_slot ST_B "$ST_ROOT" st-b --label labelled-b
sleep 0.3
ST_OUT=$(FM_BUILD_LOCK_DIR="$ST_ROOT" "$SCRIPT" --status)
ST_PID_1=$(cat "$ST_ROOT/fm-build-lock/pid" 2>/dev/null || true)
ST_PID_2=$(cat "$ST_ROOT/fm-build-lock.slot2/pid" 2>/dev/null || true)
assert_equals '2 of 3 build slots held, 0 waiting' "$(printf '%s\n' "$ST_OUT" | head -1)" \
  "--status must report how many slots are held, of how many, and how many are waiting"
assert_contains "$ST_OUT" "slot 1: held by pid $ST_PID_1" "--status must name slot 1's holder"
assert_contains "$ST_OUT" "slot 2: held by pid $ST_PID_2" "--status must name slot 2's holder"
assert_contains "$ST_OUT" 'running: labelled-a' "--status must name what slot 1 is running"
assert_contains "$ST_OUT" 'running: labelled-b' "--status must name what slot 2 is running"
assert_contains "$ST_OUT" 'slot 3: free' "--status must report a free slot as free"

# Fill the last slot so the next invocation really has to queue: the waiting
# count is only worth printing when there is somebody to count.
hold_slot ST_C "$ST_ROOT" st-c --label labelled-c
ST_ERR="$TMP_ROOT/st-waiter.err"
: > "$ST_ERR"
FM_BUILD_LOCK_DIR="$ST_ROOT" "$SCRIPT" --label queued true >/dev/null 2>"$ST_ERR" &
ST_WAITER=$!
await_grep 'WAITING, not wedged' "$ST_ERR" || fail "the --status waiter never got into line"
ST_FULL=$(FM_BUILD_LOCK_DIR="$ST_ROOT" "$SCRIPT" --status)
release_slot "$ST_A" st-a
release_slot "$ST_B" st-b
release_slot "$ST_C" st-c
await_pid_exit "$ST_WAITER" || fail "the --status waiter never got in"
wait "$ST_WAITER" 2>/dev/null || true
assert_equals '3 of 3 build slots held, 1 waiting' "$(printf '%s\n' "$ST_FULL" | head -1)" \
  "--status must count the waiters behind full slots"
case "$(FM_BUILD_LOCK_DIR="$ST_ROOT" "$SCRIPT" --status)" in
  free*) : ;;
  *) fail "with nothing held --status must still begin with free" ;;
esac
settle_root "$ST_ROOT"
pass "--status names every slot, its holder and what it runs, and the waiting count"

# --- a waiter's lines name the count and a holder ---------------------------
# Mutants: drop the holder from the N>1 notice; give the waiter's status line
# any verb but paused - the supervisor then reads an idle waiter as wedged or as
# a decision.

W2_ROOT=$(slot_root wait2 2)
W2_STATUS="$TMP_ROOT/wait2.status"
W2_ERR="$TMP_ROOT/wait2.err"
: > "$W2_STATUS"
: > "$W2_ERR"
W2_A=
W2_B=
hold_slot W2_A "$W2_ROOT" w2-a --label busy-a
hold_slot W2_B "$W2_ROOT" w2-b --label busy-b
FM_BUILD_LOCK_DIR="$W2_ROOT" FM_TASK_STATUS="$W2_STATUS" \
  FM_BUILD_LOCK_NOTICE_INTERVAL=1 FM_BUILD_LOCK_WAIT_WARN=1 \
  "$SCRIPT" printf 'got-a-slot\n' >/dev/null 2>"$W2_ERR" &
W2_WAITER=$!
await_grep 'WAITING, not wedged' "$W2_ERR" || fail "the waiting-line waiter never got into line"
sleep 2
release_slot "$W2_A" w2-a
release_slot "$W2_B" w2-b
await_pid_exit "$W2_WAITER" || fail "the waiting-line waiter never got a slot"
wait "$W2_WAITER" 2>/dev/null || true
assert_grep 'waiting for a machine-wide build slot' "$W2_ERR" \
  "a waiter at N>1 must say it is waiting for a slot"
assert_grep 'WAITING, not wedged' "$W2_ERR" "the waiting notice must say the process is waiting, not wedged"
assert_grep 'all 2 slots held' "$W2_ERR" "the waiting notice must name the slot count"
assert_grep 'held by pid ' "$W2_ERR" "the waiting notice must name a holder's pid"
assert_grep 'running: busy-' "$W2_ERR" "the waiting notice must name what a holder is running"
assert_grep '1 more - see mutex --status' "$W2_ERR" "the waiting notice must count the holders it did not name"
assert_grep 'acquired a machine-wide build slot after ' "$W2_ERR" "the waiter must report when it got a slot"
W2_FIRST=$(sed -n 1p "$W2_STATUS")
W2_SECOND=$(sed -n 2p "$W2_STATUS")
assert_equals 2 "$(grep -c '' "$W2_STATUS")" "a long wait must append exactly a paused line and a working line"
classify status_is_paused "$W2_FIRST" \
  || fail "the waiter's first status line must be a declared paused: wait: $W2_FIRST"
assert_contains "$W2_FIRST" 'all 2 slots held' "the waiter's paused line must name the slot count"
assert_contains "$W2_FIRST" 'held by pid ' "the waiter's paused line must name a holder"
case "$W2_SECOND" in
  'working: acquired a machine-wide build slot after '*) : ;;
  *) fail "the waiter must say working: once it gets a slot: $W2_SECOND" ;;
esac
settle_root "$W2_ROOT"
pass "a waiter at N>1 names the slot count and a holder, and declares its wait as paused"

# --- an ordinary hold never claims to block everyone ------------------------
# At N>1 an ordinary hold blocks nobody, and a warning that says otherwise sends
# a reader looking for a contention that is not there.
# Mutant: keep today's sentence at N>1.

H2_ROOT=$(slot_root hold2 2)
H2_STATUS="$TMP_ROOT/hold2.status"
H2_ERR="$TMP_ROOT/hold2.err"
: > "$H2_STATUS"
FM_BUILD_LOCK_DIR="$H2_ROOT" FM_TASK_STATUS="$H2_STATUS" FM_BUILD_LOCK_HOLD_WARN=1 \
  "$SCRIPT" sh -c 'sleep 2.5; printf "survived\n"' >"$TMP_ROOT/hold2.out" 2>"$H2_ERR"
assert_equals 'survived' "$(cat "$TMP_ROOT/hold2.out")" "the holder must not be killed at its ceiling"
assert_grep 'has held 1 of 2 machine-wide build slots for ' "$H2_ERR" \
  "an ordinary hold at N>1 must say how many of how many slots it holds"
assert_not_contains "$(cat "$H2_ERR")" 'blocking every other local build' \
  "an ordinary hold at N>1 must not claim to block every other local build"
H2_LINE=$(cat "$H2_STATUS")
assert_contains "$H2_LINE" 'note: holding 1 of 2 machine-wide build slots for ' \
  "the holder's status line at N>1 must say how many of how many slots it holds"
assert_not_contains "$H2_LINE" 'blocking every other local build' \
  "the holder's status line at N>1 must not claim to block every other local build"
classify status_is_captain_relevant "$H2_LINE" \
  && fail "the holder's status line must not wake firstmate as a decision: $H2_LINE"
settle_root "$H2_ROOT"
pass "an ordinary hold at N>1 reports its share of the slots and claims to block nobody"

# --- CI stands down before any setting is read ------------------------------
# Mutant: move the settings read above the CI check; the unreadable slot count
# below then warns on a run that never touches the lock at all.

CI_SETTINGS_ROOT="$TMP_ROOT/ci-settings-root"
rm -rf "$CI_SETTINGS_ROOT"
mkdir -p "$CI_SETTINGS_ROOT"
printf 'not a number\n' > "$CI_SETTINGS_ROOT/build-lock-slots"
ln -s /dev/null "$CI_SETTINGS_ROOT/build-lock-exclusive"
CI_SETTINGS_ERR="$TMP_ROOT/ci-settings.err"
CI_SETTINGS_OUT=$(env -u FM_BUILD_LOCK_CI CI=true FM_BUILD_LOCK_DIR="$CI_SETTINGS_ROOT" \
  "$SCRIPT" printf 'stood-down\n' 2>"$CI_SETTINGS_ERR")
assert_equals 'stood-down' "$CI_SETTINGS_OUT" "the command must still run on CI"
assert_equals '' "$(cat "$CI_SETTINGS_ERR")" \
  "on CI no setting is read, so a malformed one must say nothing"
assert_equals 0 "$(lock_artifacts "$CI_SETTINGS_ROOT")" "on CI nothing may be created in the lock root"
pass "on CI the slot count and the whole-machine patterns are never read and nothing is created"

# --- a whole-machine run never runs beside anything -------------------------
# A slot is not a share of the machine, so a count alone re-admits the pairing
# the one-lock rule exists to prevent. A run named as needing the whole machine
# holds every slot.
# Mutant: let --exclusive claim one slot; the ordinary runs then overlap it and
# the recorded order interleaves.

EX_ROOT=$(slot_root exclusive 3)
EX_ORDER="$TMP_ROOT/exclusive.order"
EX_ERR="$TMP_ROOT/exclusive.err"
EX_LATER_ERR="$TMP_ROOT/exclusive-later.err"
: > "$EX_ORDER"
: > "$EX_ERR"
: > "$EX_LATER_ERR"
FM_BUILD_LOCK_DIR="$EX_ROOT" "$SCRIPT" sh -c \
  "printf 'first in\n' >>'$EX_ORDER'; touch '$TMP_ROOT/ex-held'; while [ ! -e '$TMP_ROOT/ex-release' ]; do sleep 0.05; done; printf 'first out\n' >>'$EX_ORDER'" \
  >/dev/null 2>&1 &
EX_FIRST=$!
await_path "$TMP_ROOT/ex-held" || fail "the whole-machine fixture never took a slot"

FM_BUILD_LOCK_DIR="$EX_ROOT" "$SCRIPT" --exclusive sh -c \
  "printf 'whole in\n' >>'$EX_ORDER'; sleep 1.5; printf 'whole out\n' >>'$EX_ORDER'" \
  >/dev/null 2>"$EX_ERR" &
EX_WHOLE=$!
await_grep 'WAITING, not wedged' "$EX_ERR" || fail "the whole-machine run never got into line"

FM_BUILD_LOCK_DIR="$EX_ROOT" "$SCRIPT" sh -c \
  "printf 'later in\n' >>'$EX_ORDER'; sleep 0.2; printf 'later out\n' >>'$EX_ORDER'" \
  >/dev/null 2>"$EX_LATER_ERR" &
EX_LATER=$!
await_grep 'WAITING, not wedged' "$EX_LATER_ERR" || fail "the later ordinary run never got into line"

# While the whole-machine run drains, --status must show the slots it has
# reserved rather than reporting them free, and the waiter behind it must read
# as waiting for a named reason rather than as wedged.
# Mutants: show a reserved slot as free; drop the draining clause from the
# waiter's periodic line.
EX_DRAIN_STATUS=$(FM_BUILD_LOCK_DIR="$EX_ROOT" "$SCRIPT" --status)
assert_contains "$EX_DRAIN_STATUS" 'draining for a whole-machine run' \
  "--status must show a slot a whole-machine run has reserved while it drains"

touch "$TMP_ROOT/ex-release"
wait "$EX_FIRST" 2>/dev/null || true
await_pid_exit "$EX_WHOLE" || fail "the whole-machine run never started"
wait "$EX_WHOLE" 2>/dev/null || true
await_pid_exit "$EX_LATER" || fail "the run behind the whole-machine run never got in"
wait "$EX_LATER" 2>/dev/null || true

assert_equals 'first in
first out
whole in
whole out
later in
later out' "$(cat "$EX_ORDER")" "a whole-machine run must not overlap anything, before or after it"
assert_grep 'an earlier arrival goes first' "$EX_LATER_ERR" \
  "a waiter behind a draining whole-machine run must be told why, not read as wedged"
settle_root "$EX_ROOT"
pass "a run named with --exclusive holds every slot and never runs beside anything"

# --- the pattern file names a whole-machine run, so no caller has to --------
# Mutants: ignore the pattern file (the two matching runs overlap); open it at
# N=1 (the unreadable file below then warns on a run that cannot be affected).

PAT_ROOT=$(slot_root patterns 2)
cat > "$PAT_ROOT/build-lock-exclusive" <<'PATTERNS'
# a comment, and a blank line, are both ignored

*gauge-job.sh*
PATTERNS
gauge_run "$PAT_ROOT" 4
assert_equals 1 "$GAUGE_MAX" \
  "a run matching the whole-machine pattern file ran beside another under a count of 2"
settle_root "$PAT_ROOT"

# A command the file does not name still shares the machine.
PAT_SHARE_ROOT=$(slot_root patterns-share 2)
printf '*no-such-command*\n' > "$PAT_SHARE_ROOT/build-lock-exclusive"
gauge_run "$PAT_SHARE_ROOT" 4
assert_equals 2 "$GAUGE_MAX" \
  "a run the whole-machine pattern file does not name must still share the slots"
settle_root "$PAT_SHARE_ROOT"

# At a count of 1 the file is never opened, so an unusable one cannot warn.
PAT_N1_ROOT=$(slot_root patterns-n1)
ln -s /dev/null "$PAT_N1_ROOT/build-lock-exclusive"
PAT_N1_ERR="$TMP_ROOT/patterns-n1.err"
FM_BUILD_LOCK_DIR="$PAT_N1_ROOT" "$SCRIPT" true 2>"$PAT_N1_ERR"
expect_code 0 $? "a run at a count of 1 must ignore the whole-machine pattern file entirely"
assert_equals '' "$(cat "$PAT_N1_ERR")" \
  "at a count of 1 the whole-machine pattern file must not even be opened"
settle_root "$PAT_N1_ROOT"
pass "the whole-machine pattern file names runs without any caller knowing, and is unread at a count of 1"

# --- an unusable pattern file is conservative -------------------------------
# Treating it as empty would silently drop the protection the file exists to
# give; making every run whole-machine is a count of 1, which is where the
# machine already is.
# Mutant: treat an unusable pattern file as empty; the two runs then overlap.

PAT_BAD_ROOT=$(slot_root patterns-bad 2)
ln -s /dev/null "$PAT_BAD_ROOT/build-lock-exclusive"
PAT_BAD_ERR="$TMP_ROOT/patterns-bad.err"
FM_BUILD_LOCK_DIR="$PAT_BAD_ROOT" "$SCRIPT" true 2>"$PAT_BAD_ERR"
assert_equals 1 "$(grep -c 'fm-build-lock: WARNING' "$PAT_BAD_ERR" || true)" \
  "an unusable whole-machine pattern file must warn exactly once"
assert_grep 'build-lock-exclusive' "$PAT_BAD_ERR" "the warning must name the pattern file"
gauge_run "$PAT_BAD_ROOT" 4
assert_equals 1 "$GAUGE_MAX" \
  "with an unusable whole-machine pattern file two runs still overlapped"
settle_root "$PAT_BAD_ROOT"
pass "an unusable whole-machine pattern file makes every run whole-machine and says so once"

# --- a whole-machine run draining through a LOWERED count still starts ------
# The count can be lowered while a whole-machine run is collecting the slots, so
# it can end up holding more slots than the new count allows. That is strictly
# more exclusive, not less, and it must not be read as "not enough yet".
# Mutants: require the number of held slots to EQUAL the count (the run holds
# every slot and waits forever); count the slots this process itself holds as
# other live holders (same wait). Either leaves the bounded wait below red.

EXLOW_ROOT=$(slot_root exclusive-lowered 2)
EXLOW_A=
hold_slot EXLOW_A "$EXLOW_ROOT" exlow-a
EXLOW_ERR="$TMP_ROOT/exlow.err"
: > "$EXLOW_ERR"
FM_BUILD_LOCK_DIR="$EXLOW_ROOT" "$SCRIPT" --exclusive printf 'whole\n' \
  >"$TMP_ROOT/exlow.out" 2>"$EXLOW_ERR" &
EXLOW_WHOLE=$!
await_grep 'WAITING, not wedged' "$EXLOW_ERR" || fail "the whole-machine run never got into line"
await_path "$EXLOW_ROOT/fm-build-lock.slot2" \
  || fail "the whole-machine run never reserved the free slot while draining"
FM_BUILD_LOCK_DIR="$EXLOW_ROOT" "$SCRIPT" --set-slots 1 >/dev/null 2>&1 \
  || fail "--set-slots 1 failed"
# The lowered count must not be read as "you already hold enough". Requiring the
# number of held slots to EQUAL the count instead of requiring every slot 1..n
# lets this run start HOLDING ONLY SLOT 2, beside the fixture still holding slot
# 1 - measured, and invisible to a case that only waits for the run to finish.
sleep 2
kill -0 "$EXLOW_WHOLE" 2>/dev/null \
  || fail "a whole-machine run started while an ordinary holder still held a slot under the lowered count"
assert_equals '' "$(cat "$TMP_ROOT/exlow.out" 2>/dev/null || true)" \
  "a whole-machine run ran beside a live holder after the count was lowered"
release_slot "$EXLOW_A" exlow-a
await_pid_exit "$EXLOW_WHOLE" 300 \
  || fail "a whole-machine run holding more slots than a lowered count never started"
wait "$EXLOW_WHOLE" 2>/dev/null || true
assert_equals 'whole' "$(cat "$TMP_ROOT/exlow.out" 2>/dev/null || true)" \
  "the whole-machine run must run once it holds every slot the lowered count names"
settle_root "$EXLOW_ROOT"
pass "a whole-machine run that outlives a lowered count still starts, holding more than it needs"

# --- an interrupted reservation is given back -------------------------------
# A whole-machine run that dies while draining must not keep the slots it had
# already taken, whether its trap ran or not.
# Mutant: release only the slot recorded as "the" held slot; the waiter behind
# then never gets in and the bounded wait reds.

interrupted_reservation_case() {  # <name> <signal>
  local name=$1 signal=$2 lockroot err waiter_out waiter_err
  lockroot=$(slot_root "reserve-$name" 2)
  err="$TMP_ROOT/reserve-$name.err"
  waiter_out="$TMP_ROOT/reserve-$name.out"
  waiter_err="$TMP_ROOT/reserve-$name-waiter.err"
  : > "$err"
  : > "$waiter_err"
  FM_BUILD_LOCK_DIR="$lockroot" "$SCRIPT" sh -c \
    "touch '$TMP_ROOT/reserve-$name-held'; while [ ! -e '$TMP_ROOT/reserve-$name-release' ]; do sleep 0.05; done" \
    >/dev/null 2>&1 &
  local fixture=$!
  await_path "$TMP_ROOT/reserve-$name-held" || fail "the $name fixture never took a slot"
  FM_BUILD_LOCK_DIR="$lockroot" "$SCRIPT" --exclusive sleep 120 >/dev/null 2>"$err" &
  local draining=$!
  await_grep 'WAITING, not wedged' "$err" || fail "the $name whole-machine run never got into line"
  # It is the head, so it reserves the free slot and keeps it across polls.
  await_path "$lockroot/fm-build-lock.slot2" || fail "the $name whole-machine run never reserved a slot"
  assert_contains "$(FM_BUILD_LOCK_DIR="$lockroot" "$SCRIPT" --status)" 'draining for a whole-machine run' \
    "--status must show the $name reservation while it drains"
  kill -"$signal" "$draining" 2>/dev/null || true
  wait "$draining" 2>/dev/null || true
  # A signal its trap can run must give the slot back THERE AND THEN. Asserting
  # only that the next waiter gets in cannot tell a release from a later
  # dead-holder reclaim, and that is exactly what let a mutant releasing nothing
  # on an interrupted drain survive this case before. SIGKILL runs no trap, so
  # there the reclaim IS the mechanism under test and the slot may persist.
  if [ "$signal" != 9 ]; then
    [ ! -e "$lockroot/fm-build-lock.slot2" ] && [ ! -L "$lockroot/fm-build-lock.slot2" ] \
      || fail "a $name-interrupted whole-machine run left its reserved slot for someone else to reclaim"
    [ ! -e "$lockroot/fm-build-lock.slot2.info" ] \
      || fail "a $name-interrupted whole-machine run left its reserved slot's holder record behind"
  fi
  FM_BUILD_LOCK_DIR="$lockroot" "$SCRIPT" printf 'behind\n' >"$waiter_out" 2>"$waiter_err" &
  local behind=$!
  await_pid_exit "$behind" 200 \
    || fail "a slot reserved by a $name-interrupted whole-machine run was never given back"
  wait "$behind" 2>/dev/null || true
  assert_equals 'behind' "$(cat "$waiter_out" 2>/dev/null || true)" \
    "the run behind a $name-interrupted whole-machine run must get in"
  kill -0 "$fixture" 2>/dev/null \
    || fail "the $name fixture released its slot before this case could check the reservation"
  touch "$TMP_ROOT/reserve-$name-release"
  wait "$fixture" 2>/dev/null || true
  settle_root "$lockroot"
}

interrupted_reservation_case term TERM
interrupted_reservation_case kill 9
pass "a whole-machine run interrupted while draining gives its reserved slots straight back"

assert_equals 0 "$(lock_artifacts "$LOCK_ROOT")" "the suite must leave no lock behind"
pass "fm-build-lock behaves"
