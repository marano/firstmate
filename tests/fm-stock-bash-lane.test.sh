#!/usr/bin/env bash
# Regression tests for bin/fm-stock-bash-lane.sh, the single owner of what the
# stock macOS Bash 3.2 lane runs for both CI and a local run before push.
#
# The run-path cases execute the real lane script inside a fixture tree whose
# test runner, lint listing, and public-followup file are recording fakes, so
# they prove what the lane executes without running the 130-odd real scripts.
# They need a real stock /bin/bash 3.2.57, which is exactly the host the lane
# itself runs on; elsewhere only the portable refusal and listing cases run.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

LANE="$ROOT/bin/fm-stock-bash-lane.sh"
TMP_ROOT=$(fm_test_tmproot fm-stock-bash-lane)

# A fixture repository holding the real lane script and recording fakes for
# everything it delegates to. Echoes the fixture root.
make_fixture() {  # <name>
  local fx="$TMP_ROOT/$1"
  mkdir -p "$fx/bin" "$fx/tests" "$fx/log" "$fx/path"
  cp "$LANE" "$fx/bin/fm-stock-bash-lane.sh"
  cp "$ROOT/bin/fm-timeout-lib.sh" "$fx/bin/fm-timeout-lib.sh"
  chmod +x "$fx/bin/fm-stock-bash-lane.sh"

  cat >"$fx/bin/fm-test-run.sh" <<'EOF'
#!/bin/bash
log="$(cd "$(dirname "$0")/.." && pwd)/log"
if [ "$1" = --list ]; then
  printf '%s\n' "$*" >>"$log/list-args"
  # The real runner owns the shard count; this one is configured for two.
  case "$3" in
    stock-bash-*of2|stock-bash) ;;
    *) echo "fake runner: lane $3 does not match its 2 shards" >&2; exit 2 ;;
  esac
  printf 'tests/a.test.sh\ntests/b.test.sh\n'
  exit 0
fi
printf '%s\n' "$@" >"$log/run-args"
bash -c 'printf %s "$BASH_VERSION"' >"$log/run-bash"
exit "${FAKE_RUN_RC:-0}"
EOF
  cat >"$fx/bin/fm-lint.sh" <<'EOF'
#!/bin/bash
log="$(cd "$(dirname "$0")/.." && pwd)/log"
[ "$1" = --list-files ] || exit 2
printf '%s\n' "${CI:-}" >"$log/lint-ci"
printf 'bin/good.sh\n'
[ -z "${FAKE_BAD_PARSE:-}" ] || printf 'bin/bad.sh\n'
EOF
  # The retained regression takes its own build-lock hold; record that it did.
  cat >"$fx/bin/fm-build-lock.sh" <<'EOF'
#!/bin/bash
log="$(cd "$(dirname "$0")/.." && pwd)/log"
[ "$1" = -- ] && shift
printf '%s\n' "$*" >"$log/locked"
exec "$@"
EOF
  chmod +x "$fx/bin/fm-build-lock.sh"
  printf 'echo ok\n' >"$fx/bin/good.sh"
  printf 'if then fi (\n' >"$fx/bin/bad.sh"
  cat >"$fx/tests/fm-public-followup.test.sh" <<'EOF'
log="$(cd "$(dirname "$0")/.." && pwd)/log"
printf '%s\n' "${FM_TEST_ONLY:-}" >"$log/pf-only"
printf 'ok - retained regression\n'
EOF
  chmod +x "$fx/bin/fm-test-run.sh" "$fx/bin/fm-lint.sh"

  # A newer `bash` first on PATH, as on a host with Homebrew Bash 5: the lane
  # must still pin its tests to stock Bash.
  cat >"$fx/path/bash" <<'EOF'
#!/bin/sh
[ "$1" = -c ] && { printf '5.2.37(1)-release'; exit 0; }
exec /bin/bash "$@"
EOF
  printf '#!/bin/sh\nexit 0\n' >"$fx/path/tasks-axi"
  chmod +x "$fx/path/bash" "$fx/path/tasks-axi"
  printf '%s\n' "$fx"
}

run_lane() {  # <fixture> [args...]
  local fx=$1
  shift
  (cd "$fx" && PATH="$fx/path:$PATH" "$fx/bin/fm-stock-bash-lane.sh" "$@")
}

test_refuses_a_bash_that_is_not_stock() {
  local fake out rc=0
  fake="$TMP_ROOT/fake-bash"
  printf '#!/bin/sh\nprintf "5.2.37(1)-release"\n' >"$fake"
  chmod +x "$fake"
  out=$(FM_STOCK_BASH=$fake "$LANE" 2>&1) || rc=$?
  [ "$rc" -eq 1 ] || fail "lane accepted a non-stock bash (rc=$rc): $out"
  assert_contains "$out" "Bash 5.2.37(1)-release, not stock 3.2.57" \
    "refusal did not name the wrong Bash version"
  pass "the lane refuses to run under a Bash that is not stock 3.2.57"
}

test_list_is_the_runner_lane_plus_retained_regression() {
  local fx out
  fx=$(make_fixture list)
  out=$(run_lane "$fx" --list) || fail "--list failed: $out"
  assert_equals $'tests/a.test.sh\ntests/b.test.sh\ntests/fm-public-followup.test.sh' "$out" \
    "--list is not the runner's stock-bash lane plus the retained regression"
  assert_equals "--list --lane stock-bash" "$(cat "$fx/log/list-args")" \
    "--list did not ask the test runner for its own stock-bash selection"
  pass "--list delegates selection to the test runner's stock-bash lane"
}

test_shard_list_carries_the_retained_regression_in_one_shard_only() {
  local fx out
  fx=$(make_fixture shard-list)
  out=$(run_lane "$fx" --shard 1/2 --list) || fail "--shard 1/2 --list failed: $out"
  assert_equals $'tests/a.test.sh\ntests/b.test.sh\ntests/fm-public-followup.test.sh' "$out" \
    "shard 1 does not list the runner's shard plus the retained regression"
  out=$(run_lane "$fx" --shard 2/2 --list) || fail "--shard 2/2 --list failed: $out"
  assert_equals $'tests/a.test.sh\ntests/b.test.sh' "$out" \
    "shard 2 lists the retained regression that shard 1 already runs"
  assert_equals $'--list --lane stock-bash-1of2\n--list --lane stock-bash-2of2' "$(cat "$fx/log/list-args")" \
    "--shard did not ask the test runner for that shard's own selection"
  pass "--shard lists the runner's shard, with the retained regression in shard 1 only"
}

test_malformed_shard_and_option_mix_are_refused() {
  local fx arg rc
  fx=$(make_fixture shard-refusals)
  for arg in x/2 1 1/ /2 1/2/3; do
    rc=0
    run_lane "$fx" --shard "$arg" --list >/dev/null 2>&1 || rc=$?
    [ "$rc" -eq 2 ] || fail "--shard $arg was not refused as malformed (rc=$rc)"
  done
  rc=0
  run_lane "$fx" --shard 1/2 --ok-count-pins >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 2 ] || fail "--ok-count-pins accepted a --shard it ignores (rc=$rc)"
  [ ! -e "$fx/log/list-args" ] || fail "a refused call still asked the runner for a selection"
  pass "a malformed --shard, or one on the shard-independent pin listing, is refused"
}

test_run_executes_the_runner_lane_under_stock_bash() {
  local fx out args
  fx=$(make_fixture run)
  out=$(run_lane "$fx" --json "$fx/log/timing.json" 2>&1) || fail "lane run failed: $out"
  args=$(cat "$fx/log/run-args")
  assert_equals "--lane
stock-bash
--per-script-timeout-secs
1000
--require-ok-count
tests/fm-fleet-snapshot-view.test.sh=22
--require-ok-count
tests/fm-bearings-snapshot.test.sh=60
--json
$fx/log/timing.json" "$args" "lane did not run the runner's stock-bash selection with its pins"
  case "$(cat "$fx/log/run-bash")" in
    3.2.57*) ;;
    *) fail "selected tests ran under Bash $(cat "$fx/log/run-bash"), not stock 3.2.57" ;;
  esac
  assert_equals true "$(cat "$fx/log/lint-ci")" \
    "parse sweep did not list the CI-context canonical set"
  assert_equals test_first_register_succeeds_with_empty_lock_list_under_bash32 "$(cat "$fx/log/pf-only")" \
    "lane did not run the retained public-followup regression by name"
  # Mutant: run the retained regression with a bare `bash` again.
  assert_contains "$(cat "$fx/log/locked" 2>/dev/null)" "tests/fm-public-followup.test.sh" \
    "the retained regression did not run under its own build-lock hold"
  pass "the lane runs the runner's selection and pins under stock Bash despite a newer bash on PATH"
}

# Every shard gets every pin, and only shard 1 runs the parse sweep and the
# retained regression, so each runs exactly once across the matrix.
test_shards_split_the_extras_and_share_every_pin() {
  local fx pins args
  fx=$(make_fixture shard-2)
  pins=$(run_lane "$fx" --ok-count-pins) || fail "--ok-count-pins failed"
  [ "$(printf '%s\n' "$pins" | grep -c .)" -ge 2 ] || fail "the lane lists fewer than two case-count pins: $pins"
  run_lane "$fx" --shard 2/2 >/dev/null 2>&1 || fail "shard 2 failed"
  args=$(cat "$fx/log/run-args")
  assert_equals stock-bash-2of2 "$(printf '%s\n' "$args" | sed -n 2p)" "shard 2 did not run the runner's second shard"
  assert_equals "$pins" "$(printf '%s\n' "$args" | awk 'prev == "--require-ok-count" { print } { prev = $0 }')" \
    "shard 2 was not handed every case-count pin"
  [ ! -e "$fx/log/lint-ci" ] || fail "shard 2 ran the parse sweep shard 1 owns"
  [ ! -e "$fx/log/pf-only" ] || fail "shard 2 ran the retained regression shard 1 owns"

  fx=$(make_fixture shard-1)
  run_lane "$fx" --shard 1/2 >/dev/null 2>&1 || fail "shard 1 failed"
  args=$(cat "$fx/log/run-args")
  assert_equals stock-bash-1of2 "$(printf '%s\n' "$args" | sed -n 2p)" "shard 1 did not run the runner's first shard"
  assert_equals "$pins" "$(printf '%s\n' "$args" | awk 'prev == "--require-ok-count" { print } { prev = $0 }')" \
    "shard 1 was not handed every case-count pin"
  assert_equals true "$(cat "$fx/log/lint-ci" 2>/dev/null)" "shard 1 did not run the parse sweep"
  assert_equals test_first_register_succeeds_with_empty_lock_list_under_bash32 "$(cat "$fx/log/pf-only" 2>/dev/null)" \
    "shard 1 did not run the retained regression"
  pass "every shard gets every pin; the parse sweep and retained regression run in shard 1 only"
}

# The runner owns the shard count, so a matrix of the wrong size stops before
# the lane spends anything, rather than running a partial lane that looks whole.
test_a_shard_count_the_runner_refuses_stops_the_lane() {
  local fx out rc=0
  fx=$(make_fixture shard-count)
  out=$(run_lane "$fx" --shard 1/3 2>&1) || rc=$?
  [ "$rc" -eq 2 ] || fail "a shard count the runner refuses did not stop the lane (rc=$rc): $out"
  assert_contains "$out" "shard 1/3 does not match" "the refusal did not name the shard"
  [ ! -e "$fx/log/lint-ci" ] || fail "the lane ran its parse sweep for a refused shard"
  [ ! -e "$fx/log/run-args" ] || fail "the lane ran tests for a refused shard"
  pass "a shard count the runner refuses stops the lane before it runs anything"
}

test_runner_failure_fails_the_lane() {
  local fx rc=0
  fx=$(make_fixture runner-red)
  FAKE_RUN_RC=1 run_lane "$fx" >/dev/null 2>&1 || rc=$?
  [ "$rc" -ne 0 ] || fail "lane stayed green when the selected tests failed"
  [ ! -e "$fx/log/pf-only" ] || fail "lane kept running after the selected tests failed"
  pass "a failing selected test fails the lane"
}

test_parse_failure_fails_the_lane_naming_the_file() {
  local fx out rc=0
  fx=$(make_fixture parse-red)
  out=$(FAKE_BAD_PARSE=1 run_lane "$fx" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "lane stayed green over a file stock Bash cannot parse"
  assert_contains "$out" "failed to parse bin/bad.sh" "parse failure did not name the file"
  [ ! -e "$fx/log/run-args" ] || fail "lane ran tests after the parse sweep failed"
  pass "a parse failure under stock Bash fails the lane and names the file"
}

test_refuses_a_bash_that_is_not_stock
test_list_is_the_runner_lane_plus_retained_regression
test_shard_list_carries_the_retained_regression_in_one_shard_only
test_malformed_shard_and_option_mix_are_refused
case "$(/bin/bash -c 'printf %s "$BASH_VERSION"' 2>/dev/null)" in
  3.2.57*)
    test_run_executes_the_runner_lane_under_stock_bash
    test_shards_split_the_extras_and_share_every_pin
    test_a_shard_count_the_runner_refuses_stops_the_lane
    test_runner_failure_fails_the_lane
    test_parse_failure_fails_the_lane_naming_the_file
    ;;
  *)
    printf 'note: run-path cases need stock /bin/bash 3.2.57; the macos-stock-bash lane runs them\n'
    ;;
esac
