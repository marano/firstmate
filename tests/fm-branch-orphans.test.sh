#!/usr/bin/env bash
# Tests for bin/fm-branch-orphans.sh and the record bin/fm-branch-orphan-lib.sh
# owns: the durable note that a merged head branch was left on the remote, and
# the later pass that sweeps it.
#
# The end-to-end path through a merge is covered by tests/fm-pr-merge.test.sh.
# These cases pin the record's own contract and the sweep's command surface:
# what a record refuses to store, that concurrent merges cannot lose one, and
# that the sweep re-reads the forge instead of trusting what was recorded.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ORPHANS="$ROOT/bin/fm-branch-orphans.sh"
TMP_ROOT=$(fm_test_tmproot fm-branch-orphans-tests)

# shellcheck source=bin/fm-wake-lib.sh
. "$ROOT/bin/fm-wake-lib.sh"
# shellcheck source=bin/fm-branch-orphan-lib.sh
. "$ROOT/bin/fm-branch-orphan-lib.sh"

make_case() {  # <name>
  local case_dir="$TMP_ROOT/$1"
  mkdir -p "$case_dir/state" "$case_dir/fakebin"
  printf '%s\n' "$case_dir"
}

# A gh that answers the reads the sweep makes, from files the case writes, and
# logs every call so a case can assert which requests were issued.
add_gh_mock() {  # <case-dir>
  cat > "$1/fakebin/gh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_GH_LOG"
case " $* " in
  *"/pulls/"*)
    cat "$FM_TEST_PR_JSON"
    ;;
  *"/pulls?"*)
    printf '0\n'
    ;;
  *"/git/refs/heads/"*)
    : > "$FM_TEST_DELETE_ATTEMPTED"
    [ ! -f "$FM_TEST_DELETE_FAILS" ] || exit 1
    : > "$FM_TEST_DELETED"
    ;;
  *"/branches/"*)
    if [ -f "$FM_TEST_BRANCH_MISSING" ]; then
      echo 'gh: Not Found (HTTP 404)' >&2
      exit 1
    fi
    if [ -f "${FM_TEST_BRANCH_READ_FAILS:-/dev/null}" ] \
      && [ -f "${FM_TEST_DELETE_ATTEMPTED:-/dev/null}" ]; then
      # Only the post-delete re-read fails transiently, so the earlier
      # protection read still succeeds and the DELETE is actually attempted.
      echo 'gh: unexpected end of JSON input' >&2
      exit 1
    fi
    printf 'false\n'
    ;;
  *) exit 1 ;;
esac
exit 0
SH
  chmod +x "$1/fakebin/gh"
}

run_orphans() {  # <case-dir> <args...>
  local case_dir=$1
  shift
  FM_STATE_OVERRIDE="$case_dir/state" \
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_TEST_GH_LOG="$case_dir/gh.log" \
  FM_TEST_PR_JSON="$case_dir/pr.json" \
  FM_TEST_DELETE_FAILS="$case_dir/delete-fails" \
  FM_TEST_DELETED="$case_dir/deleted" \
  FM_TEST_DELETE_ATTEMPTED="$case_dir/delete-attempted" \
  FM_TEST_BRANCH_MISSING="$case_dir/branch-missing" \
  FM_TEST_BRANCH_READ_FAILS="$case_dir/branch-read-fails" \
  PATH="$case_dir/fakebin:$PATH" \
    "$ORPHANS" "$@"
}

seed_record() {  # <case-dir> <branch> <pr-url>
  fm_branch_orphan_record "$1/state" github github.com example/repo "$2" "$3"
}

merged_pr_json() {  # <case-dir> <branch>
  printf '{"merged_at":"2026-09-22T12:54:45Z","head":{"ref":"%s","repo":{"full_name":"example/repo"}}}\n' \
    "$2" > "$1/pr.json"
}

# A record whose fields would split into fields that no longer mean what they
# say is refused rather than written, because the whole file is read back by
# position.
test_record_refuses_a_field_that_would_corrupt_the_record() {
  local case_dir
  case_dir=$(make_case refuses-corrupting-fields)
  fm_branch_orphan_record "$case_dir/state" github github.com example/repo \
    "$(printf 'fm/x\tinjected')" https://github.com/example/repo/pull/1 2>/dev/null \
    && fail "refuses-corrupting-fields: a branch containing a tab was recorded"
  fm_branch_orphan_record "$case_dir/state" github github.com example/repo \
    "$(printf 'fm/x\ninjected')" https://github.com/example/repo/pull/1 2>/dev/null \
    && fail "refuses-corrupting-fields: a branch containing a newline was recorded"
  fm_branch_orphan_record "$case_dir/state" nosuch github.com example/repo \
    fm/x https://github.com/example/repo/pull/1 2>/dev/null \
    && fail "refuses-corrupting-fields: an unknown provider was recorded"
  [ ! -e "$case_dir/state/branch-orphans" ] \
    || fail "refuses-corrupting-fields: a refused record still created the file"
  pass "the branch record refuses a field that would corrupt it"
}

# Several lanes merge at once, so two failures recorded at the same moment must
# both survive; a lost record is a branch nobody ever sweeps.
test_concurrent_records_are_all_retained() {
  local case_dir i pids='' p count
  case_dir=$(make_case concurrent-records)
  for i in 1 2 3 4 5 6 7 8; do
    (
      fm_branch_orphan_record "$case_dir/state" github github.com example/repo \
        "fm/b$i" "https://github.com/example/repo/pull/$i"
    ) &
    pids="$pids $!"
  done
  for p in $pids; do
    wait "$p" || fail "concurrent-records: a recording call failed"
  done
  count=$(cut -f6 "$case_dir/state/branch-orphans" | sort -u | wc -l | tr -d ' ')
  [ "$count" = 8 ] \
    || fail "concurrent-records: expected 8 distinct branches recorded, got $count"
  pass "concurrent merges never lose a recorded branch"
}

# Recording the same branch twice is one branch, not two entries that would
# each be swept.
test_recording_one_branch_twice_keeps_one_entry() {
  local case_dir lines
  case_dir=$(make_case idempotent-record)
  seed_record "$case_dir" fm/dupe https://github.com/example/repo/pull/5
  seed_record "$case_dir" fm/dupe https://github.com/example/repo/pull/5
  lines=$(wc -l < "$case_dir/state/branch-orphans" | tr -d ' ')
  [ "$lines" = 1 ] \
    || fail "idempotent-record: expected one entry for one branch, got $lines"
  pass "recording one branch twice keeps a single entry"
}

test_list_reports_an_empty_record_without_failing() {
  local case_dir out
  case_dir=$(make_case list-empty)
  out=$(run_orphans "$case_dir" list) \
    || fail "list-empty: listing an absent record should succeed"
  case $out in
    *"no branches recorded"*) ;;
    *) fail "list-empty: an absent record was not reported as empty" ;;
  esac
  pass "listing an empty branch record succeeds and says so"
}

# A partial filter would widen to every repository, which for a sweep means
# acting outside the repository the caller named.
test_a_partial_repository_filter_is_refused() {
  local case_dir rc=0
  case_dir=$(make_case partial-filter)
  run_orphans "$case_dir" retry --provider github >/dev/null 2>&1 || rc=$?
  expect_code 2 "$rc" "partial-filter: a partial repository filter should be refused"
  pass "the sweep refuses a partial repository filter"
}

# The record says a branch was left behind; only the forge says whether it may
# be deleted now. A record whose pull request no longer reports merged must
# survive untouched.
test_sweep_refuses_a_record_whose_pr_is_not_merged() {
  local case_dir
  case_dir=$(make_case sweep-unmerged)
  add_gh_mock "$case_dir"
  seed_record "$case_dir" fm/unmerged https://github.com/example/repo/pull/5
  printf '{"merged_at":null,"head":{"ref":"fm/unmerged","repo":{"full_name":"example/repo"}}}\n' \
    > "$case_dir/pr.json"

  run_orphans "$case_dir" retry > "$case_dir/out" 2> "$case_dir/err" \
    || fail "sweep-unmerged: a deliberate skip is not an error"

  assert_no_grep 'git/refs/heads' "$case_dir/gh.log" \
    "sweep-unmerged: a branch with no merged pull request was deleted"
  assert_grep 'fm/unmerged' "$case_dir/state/branch-orphans" \
    "sweep-unmerged: the record was dropped instead of kept"
  pass "the sweep never deletes a branch whose pull request is not merged"
}

# A pull request that has since been re-pointed at another head must not let
# the recorded branch be deleted on its authority.
test_sweep_refuses_a_record_whose_pr_now_has_another_head() {
  local case_dir
  case_dir=$(make_case sweep-head-moved)
  add_gh_mock "$case_dir"
  seed_record "$case_dir" fm/recorded https://github.com/example/repo/pull/5
  merged_pr_json "$case_dir" fm/something-else

  run_orphans "$case_dir" retry > "$case_dir/out" 2> "$case_dir/err" \
    || fail "sweep-head-moved: a deliberate skip is not an error"

  assert_no_grep 'git/refs/heads' "$case_dir/gh.log" \
    "sweep-head-moved: a branch was deleted on another head's merge"
  assert_grep 'fm/recorded' "$case_dir/state/branch-orphans" \
    "sweep-head-moved: the record was dropped instead of kept"
  pass "the sweep never deletes a branch its pull request no longer heads"
}

test_sweep_deletes_a_still_merged_branch_and_clears_its_record() {
  local case_dir
  case_dir=$(make_case sweep-deletes)
  add_gh_mock "$case_dir"
  seed_record "$case_dir" fm/landed https://github.com/example/repo/pull/5
  merged_pr_json "$case_dir" fm/landed

  run_orphans "$case_dir" retry > "$case_dir/out" 2> "$case_dir/err" \
    || fail "sweep-deletes: sweeping a deletable branch should succeed"

  assert_grep 'branch deleted: fm/landed' "$case_dir/out" \
    "sweep-deletes: the branch was not reported deleted"
  [ -e "$case_dir/deleted" ] \
    || fail "sweep-deletes: no delete request reached the forge"
  [ ! -e "$case_dir/state/branch-orphans" ] \
    || fail "sweep-deletes: the swept branch kept its record"
  pass "the sweep deletes a still-merged branch and clears its record"
}

# The branch being gone is the outcome the sweep wants, however it happened, so
# the record is cleared rather than retried forever.
test_sweep_clears_the_record_of_a_branch_already_gone() {
  local case_dir
  case_dir=$(make_case sweep-already-gone)
  add_gh_mock "$case_dir"
  seed_record "$case_dir" fm/vanished https://github.com/example/repo/pull/5
  merged_pr_json "$case_dir" fm/vanished
  : > "$case_dir/branch-missing"

  run_orphans "$case_dir" retry > "$case_dir/out" 2> "$case_dir/err" \
    || fail "sweep-already-gone: a branch already gone is not an error"

  assert_grep 'already gone: fm/vanished' "$case_dir/out" \
    "sweep-already-gone: the absent branch was not reported as gone"
  [ ! -e "$case_dir/state/branch-orphans" ] \
    || fail "sweep-already-gone: an absent branch kept its record"
  pass "the sweep clears the record of a branch that is already gone"
}

# A branch that genuinely could not be deleted keeps its record and reports a
# non-zero status, so the failure does not disappear a second time.
test_sweep_keeps_the_record_when_the_delete_fails() {
  local case_dir rc=0
  case_dir=$(make_case sweep-delete-fails)
  add_gh_mock "$case_dir"
  seed_record "$case_dir" fm/stuck https://github.com/example/repo/pull/5
  merged_pr_json "$case_dir" fm/stuck
  : > "$case_dir/delete-fails"

  run_orphans "$case_dir" retry > "$case_dir/out" 2> "$case_dir/err" || rc=$?

  expect_code 1 "$rc" "sweep-delete-fails: a failed sweep should report non-zero"
  assert_grep 'fm/stuck' "$case_dir/state/branch-orphans" \
    "sweep-delete-fails: the branch that could not be deleted lost its record"
  pass "a branch the sweep cannot delete keeps its record and reports a failure"
}

# A transient failure on the post-delete re-read (a 5xx, a rate limit, a
# network blip) is not a 404 and must not be read as proof the branch is gone:
# that would clear the record for a branch that is still on the remote, the
# exact leak this sweep exists to close.
test_sweep_keeps_the_record_when_the_gone_check_fails_transiently() {
  local case_dir rc=0
  case_dir=$(make_case sweep-gone-check-transient)
  add_gh_mock "$case_dir"
  seed_record "$case_dir" fm/flaky https://github.com/example/repo/pull/5
  merged_pr_json "$case_dir" fm/flaky
  : > "$case_dir/delete-fails"
  : > "$case_dir/branch-read-fails"

  run_orphans "$case_dir" retry > "$case_dir/out" 2> "$case_dir/err" || rc=$?

  expect_code 1 "$rc" "sweep-gone-check-transient: a failed sweep should report non-zero"
  assert_no_grep 'already gone' "$case_dir/out" \
    "sweep-gone-check-transient: a transient read failure was reported as the branch being gone"
  assert_grep 'fm/flaky' "$case_dir/state/branch-orphans" \
    "sweep-gone-check-transient: a transient read failure dropped the durable record"
  pass "a transient failure on the gone-check is not read as the branch being gone"
}

# --dry-run exists so an operator can see the verdict before anything
# irreversible happens, so it must reach a delete verdict and still not delete.
test_dry_run_reports_the_verdict_without_deleting() {
  local case_dir
  case_dir=$(make_case sweep-dry-run)
  add_gh_mock "$case_dir"
  seed_record "$case_dir" fm/landed https://github.com/example/repo/pull/5
  merged_pr_json "$case_dir" fm/landed

  run_orphans "$case_dir" retry --dry-run > "$case_dir/out" 2> "$case_dir/err" \
    || fail "sweep-dry-run: a dry run should succeed"

  assert_grep 'would delete: fm/landed' "$case_dir/out" \
    "sweep-dry-run: the verdict was not reported"
  assert_no_grep 'git/refs/heads' "$case_dir/gh.log" \
    "sweep-dry-run: a dry run issued a delete"
  assert_grep 'fm/landed' "$case_dir/state/branch-orphans" \
    "sweep-dry-run: a dry run cleared the record"
  pass "a dry run reports its verdict and deletes nothing"
}

# A sweep bounded to one repository must not touch another repository's record,
# which is what makes it safe to attach to a merge.
test_a_repository_filter_leaves_other_repositories_alone() {
  local case_dir
  case_dir=$(make_case sweep-filtered)
  add_gh_mock "$case_dir"
  seed_record "$case_dir" fm/landed https://github.com/example/repo/pull/5
  fm_branch_orphan_record "$case_dir/state" github github.com other/repo \
    fm/elsewhere https://github.com/other/repo/pull/9
  merged_pr_json "$case_dir" fm/landed

  run_orphans "$case_dir" retry --provider github --host github.com --path example/repo \
    > "$case_dir/out" 2> "$case_dir/err" \
    || fail "sweep-filtered: the filtered sweep should succeed"

  assert_no_grep 'other/repo' "$case_dir/gh.log" \
    "sweep-filtered: the sweep read a repository outside its filter"
  assert_grep 'fm/elsewhere' "$case_dir/state/branch-orphans" \
    "sweep-filtered: another repository's record was cleared"
  pass "a repository-bounded sweep leaves other repositories' records alone"
}

test_record_refuses_a_field_that_would_corrupt_the_record
test_concurrent_records_are_all_retained
test_recording_one_branch_twice_keeps_one_entry
test_list_reports_an_empty_record_without_failing
test_a_partial_repository_filter_is_refused
test_sweep_refuses_a_record_whose_pr_is_not_merged
test_sweep_refuses_a_record_whose_pr_now_has_another_head
test_sweep_deletes_a_still_merged_branch_and_clears_its_record
test_sweep_clears_the_record_of_a_branch_already_gone
test_sweep_keeps_the_record_when_the_delete_fails
test_sweep_keeps_the_record_when_the_gone_check_fails_transiently
test_dry_run_reports_the_verdict_without_deleting
test_a_repository_filter_leaves_other_repositories_alone
