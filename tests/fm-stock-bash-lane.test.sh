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
  chmod +x "$fx/bin/fm-stock-bash-lane.sh"

  cat >"$fx/bin/fm-test-run.sh" <<'EOF'
#!/bin/bash
log="$(cd "$(dirname "$0")/.." && pwd)/log"
if [ "$1" = --list ]; then
  printf '%s\n' "$*" >>"$log/list-args"
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

test_run_executes_the_runner_lane_under_stock_bash() {
  local fx out args
  fx=$(make_fixture run)
  out=$(run_lane "$fx" --json "$fx/log/timing.json" 2>&1) || fail "lane run failed: $out"
  args=$(cat "$fx/log/run-args")
  assert_equals "--lane
stock-bash
--per-script-timeout-secs
600
--require-ok-count
tests/fm-fleet-snapshot-view.test.sh=21
--require-ok-count
tests/fm-bearings-snapshot.test.sh=59
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
case "$(/bin/bash -c 'printf %s "$BASH_VERSION"' 2>/dev/null)" in
  3.2.57*)
    test_run_executes_the_runner_lane_under_stock_bash
    test_runner_failure_fails_the_lane
    test_parse_failure_fails_the_lane_naming_the_file
    ;;
  *)
    printf 'note: run-path cases need stock /bin/bash 3.2.57; the macos-stock-bash lane runs them\n'
    ;;
esac
