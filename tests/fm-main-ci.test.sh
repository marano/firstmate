#!/usr/bin/env bash
# Behavior tests for bin/fm-main-ci.sh: the watch a confirmed merge arms on the
# base branch's own CI run for the merge commit. Each case arms through the
# public `arm` entry against a gh stub that serves a pull request and a list of
# workflow runs the way the REST API does, filtering by head_sha and branch
# only when asked, then runs the armed check exactly as the watcher's custom
# check sweep does.
#
# Mutants each case must turn red, by name:
#   red-never-reported     - a concluded failure is treated as green
#   red-not-retired        - a reported red leaves the watch armed
#   green-not-retired      - an all-green result leaves the watch armed
#   branch-latest-run      - the poll reads the branch's newest run instead of
#                            the merge commit's own run
#   appear-window-ignored  - no run ever appearing never reports or retires
#   conclude-window-ignored - a run that never concludes is polled forever
#   arm-not-called         - bin/fm-pr-merge.sh no longer arms the watch
#                            (tests/fm-pr-merge.test.sh)
#   task-scoped-watch      - the watch is named after the task, so the merged
#                            task's cleanup removes it (tests/fm-teardown.test.sh)
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

MAIN_CI="$ROOT/bin/fm-main-ci.sh"
WATCH="$ROOT/bin/fm-watch.sh"
DRAIN="$ROOT/bin/fm-wake-drain.sh"
TMP_ROOT=$(fm_test_tmproot fm-main-ci-tests)
command -v jq >/dev/null 2>&1 || fail "the gh stub applies --jq with the real jq, which was not found"

PR_URL=https://github.com/example/repo/pull/62
MERGE_SHA=f902a5ff00000000000000000000000000000001
LATER_SHA=f902a5ff00000000000000000000000000000002
RED_URL=https://github.com/example/repo/actions/runs/101
GREEN_URL=https://github.com/example/repo/actions/runs/102
LATER_URL=https://github.com/example/repo/actions/runs/103

# A case directory with a state dir and a gh stub. The stub serves
# repos/<o>/<r>/pulls/<n> from pull.json and repos/<o>/<r>/actions/runs from
# runs.json (an array, newest first), honoring the head_sha and branch query
# fields exactly when they are passed, and applies --jq with jq -r as gh does.
# A runs-fail marker makes the run list unreadable.
make_ci_case() {
  local name=$1 dir fakebin
  dir=$(make_case "$name")
  fakebin="$dir/fakebin"
  printf '{"merged":true,"merge_commit_sha":"%s","base":{"ref":"main"}}\n' "$MERGE_SHA" > "$dir/pull.json"
  printf '[]\n' > "$dir/runs.json"
  cat > "$fakebin/gh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_CI_DIR/gh.log"
[ "${1:-}" = api ] || exit 1
shift
path= jq_expr=. head_sha= branch=
while [ "$#" -gt 0 ]; do
  case "$1" in
    -X) shift 2 ;;
    -f|-F)
      case "$2" in
        head_sha=*) head_sha=${2#head_sha=} ;;
        branch=*) branch=${2#branch=} ;;
      esac
      shift 2
      ;;
    --jq) jq_expr=$2; shift 2 ;;
    *) path=$1; shift ;;
  esac
done
case "$path" in
  repos/example/repo/pulls/62)
    jq -r "$jq_expr" "$FM_TEST_CI_DIR/pull.json"
    ;;
  repos/example/repo/actions/runs)
    [ ! -e "$FM_TEST_CI_DIR/runs-fail" ] || { echo 'gh: HTTP 502' >&2; exit 1; }
    jq --arg sha "$head_sha" --arg branch "$branch" \
      '[.[] | select(($sha == "" or .head_sha == $sha) and ($branch == "" or .head_branch == $branch))]
       | {total_count: length, workflow_runs: .}' "$FM_TEST_CI_DIR/runs.json" \
      | jq -r "$jq_expr"
    ;;
  *) echo "gh: Not Found (HTTP 404)" >&2; exit 1 ;;
esac
SH
  chmod +x "$fakebin/gh"
  printf '%s\n' "$dir"
}

# run_json <sha> <status> <conclusion|null> <url> [name]: one workflow run.
run_json() {
  local conclusion=$3
  [ "$conclusion" = null ] || conclusion="\"$conclusion\""
  printf '{"head_sha":"%s","head_branch":"main","event":"push","status":"%s","conclusion":%s,"html_url":"%s","name":"%s"}' \
    "$1" "$2" "$conclusion" "$4" "${5:-CI}"
}

write_runs() {  # <dir> <run-json>...
  local dir=$1 all=''
  shift
  for run in "$@"; do
    all="${all:+$all,}$run"
  done
  printf '[%s]\n' "$all" > "$dir/runs.json"
}

arm() {  # <dir> [env assignments...]
  local dir=$1
  shift
  env PATH="$dir/fakebin:$PATH" FM_TEST_CI_DIR="$dir" FM_STATE_OVERRIDE="$dir/state" "$@" \
    "$MAIN_CI" arm "$PR_URL" > "$dir/arm.out" 2> "$dir/arm.err" \
    || fail "arm exited non-zero: $(cat "$dir/arm.err")"
}

check_path() {
  printf '%s/state/main-ci-%s.check.sh\n' "$1" "$MERGE_SHA"
}

# Runs the armed check the way the watcher's sweep runs a registered custom
# check, and echoes its output.
poll() {
  local dir=$1
  PATH="$dir/fakebin:$PATH" FM_TEST_CI_DIR="$dir" bash "$(check_path "$dir")" 2>"$dir/poll.err"
}

assert_armed() {
  local dir=$1 what=$2
  assert_present "$(check_path "$dir")" "$what: check was not armed"
  assert_present "$dir/state/main-ci-$MERGE_SHA.check-trust" "$what: check was not registered"
}

assert_retired() {
  local dir=$1 what=$2
  assert_absent "$(check_path "$dir")" "$what: check is still armed"
  assert_absent "$dir/state/main-ci-$MERGE_SHA.check-trust" "$what: trust binding is still present"
}

test_arm_registers_a_watch_keyed_on_the_merge_commit() {
  local dir
  dir=$(make_ci_case arm)
  arm "$dir"
  assert_armed "$dir" "arm"
  assert_contains "$(cat "$dir/arm.out")" "armed: main CI watch on example/repo at $MERGE_SHA" "arm did not report the armed watch"
  # The watch outlives the task: with no task record at all, the registered
  # check alone must keep the watcher required.
  # shellcheck source=bin/fm-supervision-lib.sh
  . "$ROOT/bin/fm-supervision-lib.sh"
  fm_supervision_needed "$dir/state" || fail "a registered main CI watch did not keep supervision required"
  pass "arm registers a watch keyed on the merge commit that keeps supervision required"
}

test_arm_refuses_an_unmerged_pull_request_without_failing() {
  local dir
  dir=$(make_ci_case arm-unmerged)
  printf '{"merged":false,"merge_commit_sha":null,"base":{"ref":"main"}}\n' > "$dir/pull.json"
  arm "$dir"
  assert_retired "$dir" "unmerged arm"
  assert_contains "$(cat "$dir/arm.err")" "actionable: merged $PR_URL but its target branch CI is not watched" \
    "an unarmable merge was not reported"
  pass "an unmerged pull request arms nothing and says so without failing"
}

# Mutants: red-never-reported, red-not-retired.
test_red_run_wakes_once_and_retires() {
  local dir out
  dir=$(make_ci_case red)
  arm "$dir"
  write_runs "$dir" "$(run_json "$MERGE_SHA" completed failure "$RED_URL")"
  out=$(poll "$dir")
  [ "$(printf '%s\n' "$out" | grep -c .)" -eq 1 ] || fail "red poll did not print exactly one line: $out"
  assert_contains "$out" "main CI red after merge" "red poll did not report red"
  assert_contains "$out" "example/repo" "red wake did not name the repository"
  assert_contains "$out" "$MERGE_SHA" "red wake did not name the merge commit"
  assert_contains "$out" "$PR_URL" "red wake did not name the pull request"
  assert_contains "$out" "$RED_URL" "red wake did not name the failing run"
  assert_retired "$dir" "red"
  pass "a red run of the merge commit wakes once and retires the watch"
}

# Mutant: green-not-retired.
test_green_run_retires_silently() {
  local dir out
  dir=$(make_ci_case green)
  arm "$dir"
  write_runs "$dir" "$(run_json "$MERGE_SHA" completed success "$GREEN_URL")" \
    "$(run_json "$MERGE_SHA" completed skipped "$GREEN_URL" Docs)"
  out=$(poll "$dir")
  assert_equals "" "$out" "green poll woke"
  assert_retired "$dir" "green"
  pass "an all-green run of the merge commit retires silently"
}

# Mutant: branch-latest-run.
test_later_push_does_not_mask_the_merge_commit_run() {
  local dir out
  dir=$(make_ci_case later-push)
  arm "$dir"
  # Newest first, as the API lists them: a later push to main went green while
  # the merge commit's own run is red.
  write_runs "$dir" "$(run_json "$LATER_SHA" completed success "$LATER_URL")" \
    "$(run_json "$MERGE_SHA" completed failure "$RED_URL")"
  out=$(poll "$dir")
  assert_contains "$out" "$RED_URL" "a later green push masked the merge commit's red run"
  assert_not_contains "$out" "$LATER_URL" "the wake named a run the merge did not cause"
  assert_retired "$dir" "later push"
  pass "a later push to main does not mask the merge commit's red run"
}

test_running_run_stays_armed_silently() {
  local dir out
  dir=$(make_ci_case running)
  arm "$dir"
  write_runs "$dir" "$(run_json "$MERGE_SHA" in_progress null "$GREEN_URL")"
  out=$(poll "$dir")
  assert_equals "" "$out" "an in-progress run woke"
  assert_armed "$dir" "in-progress"
  : > "$dir/runs-fail"
  out=$(poll "$dir")
  assert_equals "" "$out" "an unreadable run list woke before any deadline"
  assert_armed "$dir" "unreadable before deadline"
  pass "a run still in progress, or an unreadable list, stays armed without waking"
}

# Mutant: appear-window-ignored.
test_no_run_within_the_window_wakes_once_and_retires() {
  local dir out
  dir=$(make_ci_case no-run-open-window)
  arm "$dir"
  out=$(poll "$dir")
  assert_equals "" "$out" "no run yet woke inside the window"
  assert_armed "$dir" "no run inside window"

  dir=$(make_ci_case no-run)
  arm "$dir" FM_MAIN_CI_APPEAR_SECS=0
  # A run of another commit is not a run of the merge commit.
  write_runs "$dir" "$(run_json "$LATER_SHA" completed success "$LATER_URL")"
  out=$(poll "$dir")
  [ "$(printf '%s\n' "$out" | grep -c .)" -eq 1 ] || fail "no-run poll did not print exactly one line: $out"
  assert_contains "$out" "main CI never started after merge" "no-run poll did not say no run appeared"
  assert_contains "$out" "$MERGE_SHA" "no-run wake did not name the merge commit"
  assert_contains "$out" "$PR_URL" "no-run wake did not name the pull request"
  assert_retired "$dir" "no run"
  pass "no run within the window wakes once and retires the watch"
}

# Mutant: conclude-window-ignored.
test_unconcluded_run_past_the_window_wakes_once_and_retires() {
  local dir out
  dir=$(make_ci_case unconcluded)
  arm "$dir" FM_MAIN_CI_CONCLUDE_SECS=0
  write_runs "$dir" "$(run_json "$MERGE_SHA" in_progress null "$GREEN_URL")"
  out=$(poll "$dir")
  [ "$(printf '%s\n' "$out" | grep -c .)" -eq 1 ] || fail "unconcluded poll did not print exactly one line: $out"
  assert_contains "$out" "main CI unresolved after merge" "an unconcluded run past the window did not report"
  assert_contains "$out" "$GREEN_URL" "the unresolved wake did not name the open run"
  assert_retired "$dir" "unconcluded"
  pass "a run still open when the window closes wakes once and retires the watch"
}

# The same red through the watcher's own custom-check sweep: the output
# becomes one durable check wake, and the next sweep has nothing left to run.
test_watcher_delivers_the_red_as_a_check_wake() {
  local dir state out drain_out check_file
  dir=$(make_ci_case watcher)
  state="$dir/state"
  out="$dir/watch.out"
  drain_out="$dir/drain.out"
  check_file=$(check_path "$dir")
  arm "$dir"
  write_runs "$dir" "$(run_json "$MERGE_SHA" completed failure "$RED_URL")"
  PATH="$dir/fakebin:$PATH" FM_TEST_CI_DIR="$dir" FM_STATE_OVERRIDE="$state" \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=0 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  wait_for_exit "$!" 40 || fail "watcher did not exit for the red main CI wake"
  grep -F "check: $check_file: main CI red after merge" "$out" | grep -F "$RED_URL" >/dev/null \
    || fail "watcher did not print the red main CI wake: $(cat "$out")"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>/dev/null || fail "drain after the red main CI wake failed"
  [ "$(grep "$(printf '\tcheck\t')" "$drain_out" | grep -cF "$RED_URL")" -eq 1 ] \
    || fail "the red main CI wake was not queued exactly once: $(cat "$drain_out")"
  assert_retired "$dir" "watcher red"
  pass "the watcher delivers a red main CI run as one queued check wake"
}

test_arm_registers_a_watch_keyed_on_the_merge_commit
test_arm_refuses_an_unmerged_pull_request_without_failing
test_red_run_wakes_once_and_retires
test_green_run_retires_silently
test_later_push_does_not_mask_the_merge_commit_run
test_running_run_stays_armed_silently
test_no_run_within_the_window_wakes_once_and_retires
test_unconcluded_run_past_the_window_wakes_once_and_retires
test_watcher_delivers_the_red_as_a_check_wake
