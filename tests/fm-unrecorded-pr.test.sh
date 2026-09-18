#!/usr/bin/env bash
# tests/fm-unrecorded-pr.test.sh - the unrecorded-PR detector: a task whose
# branch has an open PR on the forge while its record carries no pr= must wake
# someone, and every ordinary case must stay silent.
#
# Two layers, because they fail for different reasons:
#   - bin/fm-unrecorded-pr-lib.sh's condition over real git worktrees and a fake
#     `gh` that answers the one GraphQL query from a canned forge: which tasks
#     are candidates, that the forge is asked ONCE per sweep and not at all when
#     nothing is a candidate, the (repository, branch) join, and the silent
#     cases (pr= recorded, no open PR, no branch, another repository, a scout, a
#     forge that cannot answer).
#   - bin/fm-watch.sh's unrecorded_pr_tick driven directly with wake() stubbed:
#     the durable check wake naming the task and PR, its queued-key dedupe, the
#     re-surface window, and the boundary that the detector never records a PR
#     or arms a merge poll itself; plus one real watcher cycle, so the tick is
#     proved wired into the loop and not only callable.
#   - bin/fm-supervise-daemon.sh's classifier: the finding must reach firstmate
#     during an away window, where PR 19 once went red with nothing watching.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-unrecorded-pr-lib.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found (the fake forge applies gh's --jq with it)"; exit 0; }

# The daemon's pure functions for the away-mode layer; its main loop is skipped
# under sourcing via a BASH_SOURCE guard.
if [ -z "${FM_TEST_DAEMON_SOURCED:-}" ]; then
  export FM_TEST_DAEMON_SOURCED=1
  # shellcheck source=/dev/null
  . "$ROOT/bin/fm-supervise-daemon.sh"
fi

TMP_ROOT=$(fm_test_tmproot fm-unrecorded-pr-tests)
fm_git_identity fmtest fmtest@example.invalid

# A home fixture with a fake `gh` answering `gh api graphql ... --jq <filter>`
# from $home/forge.json (the GraphQL response body), applying the caller's
# filter with real jq the way gh does. Every invocation is appended to
# $home/gh-calls; FM_FAKE_GH_FAIL=1 makes the forge unreachable.
make_home() {  # <name>
  local name=$1 dir
  dir=$(make_case "$name")
  printf '{"data":{"viewer":{"pullRequests":{"nodes":[]}}}}\n' > "$dir/forge.json"
  : > "$dir/gh-calls"
  cat > "$dir/fakebin/gh" <<'SH'
#!/usr/bin/env bash
set -u
home=${FM_FAKE_GH_HOME:?}
printf '%s\n' "$*" >> "$home/gh-calls"
[ "${FM_FAKE_GH_FAIL:-0}" = 1 ] && { printf 'error connecting to api.github.com\n' >&2; exit 1; }
[ "${1:-}" = api ] && [ "${2:-}" = graphql ] || { printf 'unexpected gh call: %s\n' "$*" >&2; exit 2; }
filter=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --jq) filter=$2; shift 2 ;;
    *) shift ;;
  esac
done
if [ -n "$filter" ]; then jq -r "$filter" "$home/forge.json"; else cat "$home/forge.json"; fi
SH
  chmod +x "$dir/fakebin/gh"
  printf '%s\n' "$dir"
}

# An open PR on the fake forge.
forge_pr() {  # <home> <owner/repo> <head-branch> <url>
  local home=$1 tmp
  tmp=$(mktemp "$home/forge.XXXXXX")
  jq --arg repo "$2" --arg head "$3" --arg url "$4" \
    '.data.viewer.pullRequests.nodes += [{url:$url, headRefName:$head, repository:{nameWithOwner:$repo}}]' \
    "$home/forge.json" > "$tmp" && mv "$tmp" "$home/forge.json"
}

# A task record with a real worktree checked out on <branch> (or detached when
# <branch> is -) whose origin is <owner/repo> on GitHub.
make_task() {  # <home> <id> <owner/repo> <branch|-> [extra meta lines...]
  local home=$1 id=$2 repo=$3 branch=$4 wt
  shift 4
  wt="$home/worktrees/$id"
  mkdir -p "$wt"
  git -C "$wt" init -q
  git -C "$wt" commit -q --allow-empty -m init
  git -C "$wt" remote add origin "https://github.com/$repo.git"
  if [ "$branch" = - ]; then
    git -C "$wt" checkout -q --detach
  else
    git -C "$wt" checkout -q -b "$branch"
  fi
  {
    printf 'window=fm:fm-%s\n' "$id"
    printf 'worktree=%s\n' "$wt"
    printf 'kind=ship\n'
    for line in "$@"; do printf '%s\n' "$line"; done
  } > "$home/state/$id.meta"
}

scan() {  # <home>
  PATH="$1/fakebin:$PATH" FM_FAKE_GH_HOME="$1" fm_unrecorded_pr_scan "$1/state"
}

gh_calls() {  # <home>
  grep -c . "$1/gh-calls" 2>/dev/null || true
}

# --- the condition ------------------------------------------------------------

test_open_pr_with_no_recorded_pr_is_reported() {
  local home out
  home=$(make_home reported)
  make_task "$home" task-a acme/app fm/task-a
  forge_pr "$home" acme/app fm/task-a https://github.com/acme/app/pull/13
  out=$(scan "$home") || fail "the scan failed on a reachable forge"
  [ "$out" = "task-a	https://github.com/acme/app/pull/13	fm/task-a" ] \
    || fail "an open PR on an unrecorded task's branch was not reported: '$out'"
  pass "a task whose branch has an open PR and no recorded pr= is reported with the PR URL"
}

test_ordinary_cases_stay_silent() {
  local home out
  home=$(make_home silent)
  # Recorded: the PR is open, but the task already holds it.
  make_task "$home" recorded acme/app fm/recorded "pr=https://github.com/acme/app/pull/20"
  forge_pr "$home" acme/app fm/recorded https://github.com/acme/app/pull/20
  # A branch with no open PR (never opened, or already merged or closed).
  make_task "$home" no-pr acme/app fm/no-pr
  # Same branch name, different repository.
  make_task "$home" other-repo acme/other fm/other-repo
  forge_pr "$home" acme/app fm/other-repo https://github.com/acme/app/pull/21
  # A scout never opens a PR.
  make_task "$home" scout acme/app fm/scout "kind=scout"
  sed -i.bak '/^kind=ship$/d' "$home/state/scout.meta" && rm -f "$home/state/scout.meta.bak"
  forge_pr "$home" acme/app fm/scout https://github.com/acme/app/pull/22
  # A remote secondmate's record lives on its own host.
  make_task "$home" remote acme/app fm/remote "remote_host=box.example"
  forge_pr "$home" acme/app fm/remote https://github.com/acme/app/pull/23
  out=$(scan "$home") || fail "the scan failed on a reachable forge"
  [ -z "$out" ] || fail "an ordinary case was reported: '$out'"
  pass "a recorded PR, a branch with no PR, another repository, a scout, and a remote record stay silent"
}

test_one_forge_query_per_sweep_and_none_without_candidates() {
  local home out
  home=$(make_home one-query)
  make_task "$home" detached acme/app -
  out=$(scan "$home") || fail "a sweep with no candidates failed"
  [ -z "$out" ] || fail "a task with no branch was reported: '$out'"
  [ "$(gh_calls "$home")" = 0 ] || fail "the forge was queried with no candidate to compare"
  make_task "$home" task-a acme/app fm/task-a
  make_task "$home" task-b acme/app fm/task-b
  make_task "$home" task-c acme/lib fm/task-c
  forge_pr "$home" acme/app fm/task-a https://github.com/acme/app/pull/13
  forge_pr "$home" acme/lib fm/task-c https://github.com/acme/lib/pull/16
  out=$(scan "$home") || fail "the scan failed on a reachable forge"
  [ "$(gh_calls "$home")" = 1 ] || fail "one sweep asked the forge $(gh_calls "$home") times, not once"
  assert_contains "$out" "task-a	https://github.com/acme/app/pull/13" "the first repository's unrecorded PR was missed"
  assert_contains "$out" "task-c	https://github.com/acme/lib/pull/16" "the second repository's unrecorded PR was missed"
  assert_not_contains "$out" "task-b" "a branch with no PR was reported"
  pass "one forge query serves the whole sweep, and none runs when nothing is a candidate"
}

test_unreachable_forge_is_not_an_empty_forge() {
  local home out status
  home=$(make_home unreachable)
  make_task "$home" task-a acme/app fm/task-a
  forge_pr "$home" acme/app fm/task-a https://github.com/acme/app/pull/13
  out=$(PATH="$home/fakebin:$PATH" FM_FAKE_GH_HOME="$home" FM_FAKE_GH_FAIL=1 \
    fm_unrecorded_pr_scan "$home/state") && status=0 || status=$?
  [ "$status" = 2 ] || fail "an unreachable forge did not report itself (status $status)"
  [ -z "$out" ] || fail "an unreachable forge produced a finding: '$out'"
  pass "an unreachable forge reports itself instead of passing for no open PRs"
}

# --- the watcher tick ---------------------------------------------------------

# Run bin/fm-watch.sh's unrecorded_pr_tick once against <home> with the
# production wake() replaced by one that prints its reason.
run_tick() {  # <home> [extra env assignments...]
  local home=$1
  shift
  # $1 below is the bash -c child shell's positional param, not this parent shell's
  # shellcheck disable=SC2016
  env PATH="$home/fakebin:$PATH" \
    FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$home/state" \
    FM_CONFIG_OVERRIDE="$home/config" FM_FAKE_GH_HOME="$home" \
    FM_UNRECORDED_PR_SCAN_SECS=1 \
    "$@" \
    bash -c '
      set -u
      # shellcheck source=/dev/null
      . "$1/bin/fm-watch.sh"
      wake() { printf "%s\n" "$1"; }
      unrecorded_pr_tick
    ' _ "$ROOT"
}

clear_scan_gate() {  # <home>
  rm -f "$1/state/.last-unrecorded-pr-scan"
}

test_tick_wakes_naming_task_and_pr_and_binds_nothing() {
  local home out meta_before queue
  home=$(make_home tick)
  mkdir -p "$home/config"
  make_task "$home" task-a acme/app fm/task-a
  forge_pr "$home" acme/app fm/task-a https://github.com/acme/app/pull/19
  meta_before=$(cat "$home/state/task-a.meta")
  out=$(run_tick "$home")
  assert_contains "$out" "check: open PR not recorded: task-a https://github.com/acme/app/pull/19 (branch fm/task-a)" \
    "the tick did not wake naming the task and the PR"
  queue=$(cat "$home/state/.wake-queue" 2>/dev/null || true)
  assert_contains "$queue" "unrecorded-pr:task-a" "the wake was not made durable under its task key"
  # Detection only: recording a PR binds a task to a forge identity, which is
  # firstmate's verified act, never the detector's.
  [ "$(cat "$home/state/task-a.meta")" = "$meta_before" ] || fail "the detector changed the task's record"
  [ ! -e "$home/state/task-a.check.sh" ] && [ ! -e "$home/state/task-a.pr-poll" ] \
    || fail "the detector armed a merge poll"
  # Queued and unhandled: a second sweep says nothing the first did not.
  clear_scan_gate "$home"
  out=$(run_tick "$home")
  [ -z "$out" ] || fail "a still-queued finding woke again: '$out'"
  [ "$(grep -c 'unrecorded-pr:task-a' "$home/state/.wake-queue")" = 1 ] \
    || fail "a still-queued finding was queued twice"
  pass "the tick wakes once naming the task and PR, and records nothing itself"
}

test_tick_resurfaces_only_after_its_window_and_forgets_a_recorded_pr() {
  local home out
  home=$(make_home tick-resurface)
  mkdir -p "$home/config"
  make_task "$home" task-a acme/app fm/task-a
  forge_pr "$home" acme/app fm/task-a https://github.com/acme/app/pull/19
  out=$(run_tick "$home")
  assert_contains "$out" "task-a" "the first sweep did not wake"
  : > "$home/state/.wake-queue"   # firstmate handled the wake but recorded nothing
  clear_scan_gate "$home"
  out=$(run_tick "$home")
  [ -z "$out" ] || fail "a handled finding re-surfaced inside its window: '$out'"
  # The window elapses: the episode's last wake is now an hour and more ago.
  printf 'https://github.com/acme/app/pull/19\t1\n' > "$home/state/.unrecorded-pr-task-a"
  clear_scan_gate "$home"
  out=$(run_tick "$home")
  assert_contains "$out" "task-a https://github.com/acme/app/pull/19" "a finding still true past its window did not re-surface"
  # Recorded now: the condition is gone, and so is its episode.
  printf 'pr=https://github.com/acme/app/pull/19\n' >> "$home/state/task-a.meta"
  : > "$home/state/.wake-queue"
  printf 'https://github.com/acme/app/pull/19\t1\n' > "$home/state/.unrecorded-pr-task-a"
  clear_scan_gate "$home"
  out=$(run_tick "$home")
  [ -z "$out" ] || fail "a recorded PR still woke: '$out'"
  [ ! -e "$home/state/.unrecorded-pr-task-a" ] || fail "a resolved finding kept its episode marker"
  pass "a handled finding re-surfaces only past its window, and a recorded PR ends it"
}

test_tick_logs_an_unreachable_forge_without_waking() {
  local home out
  home=$(make_home tick-unreachable)
  mkdir -p "$home/config"
  make_task "$home" task-a acme/app fm/task-a
  forge_pr "$home" acme/app fm/task-a https://github.com/acme/app/pull/19
  out=$(run_tick "$home" FM_FAKE_GH_FAIL=1)
  [ -z "$out" ] || fail "an unreachable forge woke firstmate: '$out'"
  grep -F "unrecorded-PR detection skipped" "$home/state/.watch-triage.log" >/dev/null 2>&1 \
    || fail "an unreachable forge left no triage-log trace"
  pass "an unreachable forge is logged, not alarmed"
}

# The real watcher, not the tick alone: one bounded checkpoint against a home
# whose only task has an open, unrecorded PR must leave the durable finding.
test_watcher_cycle_raises_the_finding() {
  local home out
  home=$(make_home watch-cycle)
  mkdir -p "$home/config"
  make_task "$home" task-a acme/app fm/task-a
  forge_pr "$home" acme/app fm/task-a https://github.com/acme/app/pull/19
  out=$(PATH="$home/fakebin:$PATH" FM_FAKE_GH_HOME="$home" \
    FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" \
    FM_POLL=1 FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    FM_IDLE_FLEET_SCAN_SECS=999999 FM_STALE_ESCALATE_SECS=999999 \
    "$ROOT/bin/fm-watch-checkpoint.sh" --seconds 8 2>/dev/null || true)
  grep -F 'unrecorded-pr:task-a' "$home/state/.wake-queue" >/dev/null 2>&1 \
    || fail "a watcher cycle did not queue the unrecorded-PR finding: $out"
  [ "$(gh_calls "$home")" -ge 1 ] || fail "the watcher cycle never asked the forge"
  pass "a real watcher cycle queues the unrecorded-PR finding"
}

# --- away mode ----------------------------------------------------------------

test_away_mode_escalates_the_finding() {
  local dir state reason out
  dir=$(make_supercase away-escalates)
  state="$dir/state"
  reason="check: open PR not recorded: task-a https://github.com/acme/app/pull/19 (branch fm/task-a); verify it is this task's work, then record it with bin/fm-pr-check.sh"
  # The contrast that keeps this from going vacuous: the away daemon does
  # self-handle the periodic fleet review, the path that would have absorbed a
  # heartbeat-hosted comparison.
  should_force_self heartbeat \
    || fail "the daemon no longer self-handles heartbeat wakes; this test's contrast is gone"
  should_force_self "$reason" \
    && fail "the unrecorded-PR finding was absorbed by the away-mode self-handling path"
  FM_ESCALATE_BATCH_SECS=999 LOG="$dir/daemon.log" FM_STATE_OVERRIDE="$state" \
    handle_wake "$reason" "$state" \
    || fail "the daemon failed to classify the unrecorded-PR finding"
  out=$(cat "$state/.subsuper-escalations" 2>/dev/null || true)
  case "$out" in
    *"open PR not recorded: task-a https://github.com/acme/app/pull/19"*) ;;
    *) fail "the away-mode daemon did not escalate the unrecorded-PR finding: $out" ;;
  esac
  pass "away mode escalates an unrecorded open PR instead of self-handling it"
}

test_open_pr_with_no_recorded_pr_is_reported
test_ordinary_cases_stay_silent
test_one_forge_query_per_sweep_and_none_without_candidates
test_unreachable_forge_is_not_an_empty_forge
test_tick_wakes_naming_task_and_pr_and_binds_nothing
test_tick_resurfaces_only_after_its_window_and_forgets_a_recorded_pr
test_tick_logs_an_unreachable_forge_without_waking
test_watcher_cycle_raises_the_finding
test_away_mode_escalates_the_finding

echo "all fm-unrecorded-pr tests passed"
