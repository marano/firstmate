#!/usr/bin/env bash
# Tests for bounded foreground watcher checkpoints used by Codex supervision.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHECKPOINT="$ROOT/bin/fm-watch-checkpoint.sh"
TMP_ROOT=$(fm_test_tmproot fm-watch-checkpoint)

# Ceilings a passing case never waits out: a checkpoint returns as soon as its
# watcher prints a wake or exits, and the timeout's TERM-to-KILL grace ends as
# soon as the watcher does. Fixed budgets of a few seconds were only about twice
# what a loaded machine takes, so a load burst failed cases that were correct.
WAKE_CEILING=60
EXIT_GRACE_CEILING=30

make_home() {
  local name=$1 home
  home="$TMP_ROOT/$name"
  mkdir -p "$home/state" "$home/data" "$home/config"
  printf '%s\n' "$home"
}

test_quiet_checkpoint_exits_124_cleanly() {
  local home out err status
  home=$(make_home quiet)
  out="$home/out.txt"
  err="$home/err.txt"
  status=0
  FM_HOME="$home" FM_POLL=1 FM_SIGNAL_GRACE="$EXIT_GRACE_CEILING" FM_CHECK_INTERVAL=999999 "$CHECKPOINT" --seconds 1 >"$out" 2>"$err" || status=$?
  expect_code 124 "$status" "quiet checkpoint exit"
  assert_contains "$(cat "$out")" "checkpoint: no actionable wake within 1s" "quiet checkpoint line missing"
  assert_absent "$home/state/.watch.lock/pid" "watch lock pid survived quiet checkpoint timeout"
  pass "quiet checkpoint exits 124 with a clean checkpoint line and no live lock"
}

test_signal_passes_through_and_exits_zero() {
  local home out err status drained
  home=$(make_home signal)
  out="$home/out.txt"
  err="$home/err.txt"
  (
    sleep 1
    printf 'done: synthetic wake\n' > "$home/state/demo.status"
  ) &
  status=0
  FM_HOME="$home" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 "$CHECKPOINT" --seconds "$WAKE_CEILING" >"$out" 2>"$err" || status=$?
  expect_code 0 "$status" "signal checkpoint exit"
  assert_contains "$(cat "$out")" "signal:" "signal wake was not passed through"
  drained=$(FM_HOME="$home" "$ROOT/bin/fm-wake-drain.sh")
  assert_contains "$drained" $'\tsignal\tdemo.status\t' "signal wake was not queued durably"
  pass "checkpoint passes through a real watcher wake and leaves the queue for drain"
}

test_registered_check_uses_preserved_watcher_environment() {
  local home out err status
  home=$(make_home check-env)
  out="$home/out.txt"
  err="$home/err.txt"
  cat > "$home/state/env-check.check.sh" <<'SH'
#!/usr/bin/env bash
printf 'env check fired with FM_CHECK_INTERVAL=%s\n' "${FM_CHECK_INTERVAL:-missing}"
SH
  chmod 0700 "$home/state/env-check.check.sh"
  FM_HOME="$home" "$ROOT/bin/fm-check-register.sh" env-check >/dev/null \
    || fail "could not register checkpoint custom check"
  status=0
  FM_HOME="$home" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=1 "$CHECKPOINT" --seconds "$WAKE_CEILING" >"$out" 2>"$err" || status=$?
  expect_code 0 "$status" "check checkpoint exit"
  assert_contains "$(cat "$out")" "check:" "check wake was not passed through"
  assert_contains "$(cat "$out")" "FM_CHECK_INTERVAL=1" "watcher environment was not preserved"
  pass "checkpoint preserves watcher environment for registered custom checks"
}

test_existing_singleton_watcher_is_not_success() {
  local home out err status
  home=$(make_home singleton)
  out="$home/out.txt"
  err="$home/err.txt"
  mkdir "$home/state/.watch.lock"
  printf '%s\n' "$$" > "$home/state/.watch.lock/pid"
  status=0
  FM_HOME="$home" FM_GUARD_GRACE=300 "$CHECKPOINT" --seconds "$WAKE_CEILING" >"$out" 2>"$err" || status=$?
  expect_code 1 "$status" "singleton checkpoint exit"
  assert_contains "$(cat "$out")" "watcher: already running" "singleton watcher output was not passed through"
  assert_contains "$(cat "$err")" "outside this foreground checkpoint" "singleton watcher failure was not explained"
  pass "checkpoint rejects an existing watcher singleton as unowned"
}

# A watcher can lose the deadline's TERM to Bash 5.2 ("Startup-path
# substitutions" in bin/fm-wake-lib.sh) and keep running. A copy of the
# checkpoint runs a stand-in watcher that records and survives every TERM: the
# checkpoint KILLs it FM_SIGNAL_GRACE seconds after the TERM and returns,
# instead of waiting on it for good (mutant: timeout without -k).
test_checkpoint_kills_a_watcher_that_survives_its_deadline() {
  local home bindir out err ckpt status i stand_in
  home=$(make_home term-survivor)
  bindir="$home/bin"
  out="$home/out.txt"
  err="$home/err.txt"
  mkdir -p "$bindir"
  cp "$CHECKPOINT" "$bindir/"
  cat > "$bindir/fm-watch.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$$" > "$FM_HOME/state/stand-in.pid"
trap 'printf "term\n" >> "$FM_HOME/state/stand-in.terms"' TERM
while :; do sleep 0.1; done
SH
  chmod +x "$bindir/fm-watch.sh"
  FM_HOME="$home" FM_SIGNAL_GRACE=1 "$bindir/fm-watch-checkpoint.sh" --seconds 1 >"$out" 2>"$err" &
  ckpt=$!
  i=0
  while [ "$i" -lt $((EXIT_GRACE_CEILING * 10)) ] && kill -0 "$ckpt" 2>/dev/null; do
    sleep 0.1
    i=$((i + 1))
  done
  stand_in=$(cat "$home/state/stand-in.pid" 2>/dev/null || true)
  if kill -0 "$ckpt" 2>/dev/null; then
    [ -z "$stand_in" ] || kill -KILL "$stand_in" 2>/dev/null || true
    wait "$ckpt" 2>/dev/null || true
    fail "checkpoint kept waiting on a watcher that survived its deadline TERM"
  fi
  status=0
  wait "$ckpt" || status=$?
  [ -s "$home/state/stand-in.terms" ] || fail "stand-in watcher never received the deadline TERM"
  if [ -z "$stand_in" ] || kill -0 "$stand_in" 2>/dev/null; then
    fail "checkpoint left the stand-in watcher running"
  fi
  case "$status" in
    124) ;;
    *) fail "checkpoint that killed its watcher exited $status: $(cat "$out" "$err")" ;;
  esac
  grep -q 'no actionable wake within 1s' "$out" || fail "killed watcher not reported as quiet checkpoint: $(cat "$out" "$err")"
  pass "checkpoint kills a watcher that survives its deadline TERM and returns"
}

test_quiet_checkpoint_exits_124_cleanly
test_signal_passes_through_and_exits_zero
test_checkpoint_kills_a_watcher_that_survives_its_deadline
test_registered_check_uses_preserved_watcher_environment
test_existing_singleton_watcher_is_not_success
