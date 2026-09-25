#!/usr/bin/env bash
# Behavior tests for firstmate's one-way GitHub issue mirror: the issue a
# backlog item carries (bin/fm-tasks-axi.sh issue), the deliberate publish
# (bin/fm-tasks-axi.sh publish), the moves that follow the backlog
# (bin/fm-github-issue-lib.sh), the dispatch half (bin/fm-spawn.sh), the
# requeue and handback halves (bin/fm-tasks-axi.sh), and the brief line
# (bin/fm-brief.sh). The merge half lives in tests/fm-pr-merge.test.sh and the
# cleanup requeue half in tests/fm-backlog-atomicity.test.sh, beside the rest of
# those scripts' behavior.
#
# Every case reaches GitHub through the FM_GITHUB_ISSUE_CMD seam, because no
# test may call the real API. The fake answers as `gh api` would and logs every
# call it receives, so a case asserts what GitHub was actually asked to do.
#
# The single-quoted with_lib snippets are deliberate: the helper evaluates them
# in a subshell where DATA and HOME_DIR exist.
# shellcheck disable=SC2016
#
# What these pin, and the mutant each one kills:
#   - publish creates the issue from the public title and summary, NEVER the
#     item's private body ("post the body"), on exactly the named repository,
#     and records owner/repo#N on the item ("create but never record");
#   - a second publish is refused with no call at all ("publish again makes a
#     second issue"), and a failed publish records nothing;
#   - a dispatch labels the issue in progress, a merge closes it as completed
#     and drops the label, and a requeue or handback reopens it and drops the
#     label ("report the move and call nothing", "swap two phases");
#   - a transport failure and a wedged transport leave the dispatch and the
#     requeue successful and say so as an actionable line ("let the mirror
#     failure propagate");
#   - an item with no issue line is untouched and unmentioned ("call GitHub or
#     report for every item");
#   - the issue survives a body rewrite and a hold, prose that merely mentions
#     one is not one, and two lines refuse rather than the last one winning;
#   - a brief for an item with an issue tells the worker to write Refs and never
#     a closing keyword, and a brief for an item without one says nothing.
set -u

# shellcheck source=tests/fixtures.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

WRAPPER="$ROOT/bin/fm-tasks-axi.sh"
TMP_ROOT=$(fm_test_tmproot fm-gi-mirror)

unset TASKS_AXI_FILE TASKS_AXI_BACKEND FM_HOME FM_ROOT_OVERRIDE \
  FM_DATA_OVERRIDE FM_STATE_OVERRIDE FM_CONFIG_OVERRIDE \
  FM_GITHUB_ISSUE_CMD FM_GITHUB_ISSUE_TIMEOUT \
  FM_LINEAR_API_KEY FM_LINEAR_CMD FM_LINEAR_ENV_FILE

command -v tasks-axi >/dev/null 2>&1 \
  || { echo "SKIP: tasks-axi is not installed; the backlog side cannot be driven" >&2; exit 0; }
command -v jq >/dev/null 2>&1 \
  || { echo "SKIP: jq is not installed; publish reads GitHub's answer with it" >&2; exit 0; }

# The fake transport, run in place of `gh`. It logs each call as one line of
# its arguments and answers from the case directory:
#   gh-fail       present: fail as gh does on a server error
#   gh-hang       present: sleep past the bound instead of answering
#   gh-no-label   present: a label removal answers 404, as for a missing label
#   gh-calls      appended with every call's arguments
#   gh-published  the body text a publish sent
make_transport() {  # <case-dir>
  local case_dir=$1 fakebin
  fakebin=$(fm_fakebin "$case_dir/fake")
  cat > "$fakebin/fm-fake-gh-issue" <<'SH'
#!/usr/bin/env bash
set -u
dir=$FM_FAKE_GH_DIR
printf '%s\n' "$*" >> "$dir/gh-calls"
if [ -e "$dir/gh-fail" ]; then
  echo 'gh: Server Error (HTTP 500)' >&2
  exit 1
fi
if [ -e "$dir/gh-hang" ]; then
  sleep 30
  exit 0
fi
for arg in "$@"; do
  case "$arg" in
    body=@*) cat "${arg#body=@}" > "$dir/gh-published" ;;
  esac
done
case "$*" in
  *'-X DELETE '*)
    if [ -e "$dir/gh-no-label" ]; then
      echo 'gh: Label does not exist (HTTP 404)' >&2
      exit 1
    fi
    printf '[]\n'
    ;;
  *'-X POST repos/'*'/issues -f title='*)
    printf '{"number":42,"html_url":"https://github.com/example/issues/42"}\n'
    ;;
  *) printf '{}\n' ;;
esac
SH
  chmod +x "$fakebin/fm-fake-gh-issue"
  : > "$case_dir/gh-calls"
  printf '%s\n' "$fakebin/fm-fake-gh-issue"
}

make_home() {  # <dir>
  local home=$1
  fm_test_spawn_home "$home" claude
  cp "$ROOT/.tasks.toml" "$home/.tasks.toml"
  printf '## In flight\n\n## Queued\n\n## Done\n' > "$home/data/backlog.md"
}

fm() {  # <home> <args...>
  local home=$1
  shift
  FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" FM_STATE_OVERRIDE="$home/state" \
    FM_CONFIG_OVERRIDE="$home/config" "$WRAPPER" "$@"
}

add_item() {  # <home> <id> [flag...]
  local home=$1 id=$2
  shift 2
  fm "$home" add "$id" "Item $id" --kind ship --repo firstmate "$@" >/dev/null \
    || fail "fixture: could not add $id"
}

# A plain home with the fake transport, for the cases that need no dispatch.
make_plain_case() {  # <name>; sets CASE_DIR HOME_DIR TRANSPORT
  CASE_DIR="$TMP_ROOT/$1"
  HOME_DIR="$CASE_DIR/home"
  mkdir -p "$CASE_DIR"
  make_home "$HOME_DIR"
  TRANSPORT=$(make_transport "$CASE_DIR")
}

# Run the wrapper with the fake transport wired in.
fm_gh() {  # <args...>
  FM_FAKE_GH_DIR="$CASE_DIR" FM_GITHUB_ISSUE_CMD="$TRANSPORT" \
    FM_GITHUB_ISSUE_TIMEOUT="${FM_TEST_GH_TIMEOUT:-20}" fm "$HOME_DIR" "$@"
}

with_lib() {  # <home> <shell-snippet>
  local home=$1 snippet=$2
  FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" FM_STATE_OVERRIDE="$home/state" \
    bash -c '
      set -u
      . "$1/bin/fm-github-issue-lib.sh"
      DATA=$2/data
      HOME_DIR=$2
      eval "$3"
    ' _ "$ROOT" "$home" "$snippet"
}

assert_no_calls() {  # <message>
  [ ! -s "$CASE_DIR/gh-calls" ] \
    || fail "$1 (GitHub was asked: $(tr '\n' ';' < "$CASE_DIR/gh-calls"))"
}

assert_called() {  # <pattern> <message>
  grep -qF -- "$1" "$CASE_DIR/gh-calls" \
    || fail "$2 (GitHub was asked: $(tr '\n' ';' < "$CASE_DIR/gh-calls"))"
}

# --- the identifier a backlog item carries ---------------------------------

test_an_issue_is_recorded_read_back_and_survives_a_body_rewrite() {
  local out
  make_plain_case record
  add_item "$HOME_DIR" gi-1

  out=$(fm "$HOME_DIR" issue gi-1) || fail "could not read an unrecorded issue"
  assert_equals none "$out" "an item with no issue did not read back none"

  fm "$HOME_DIR" issue gi-1 marano/firstmate#12 >/dev/null || fail "could not record an issue"
  assert_equals marano/firstmate#12 "$(fm "$HOME_DIR" issue gi-1)" "the issue did not read back"

  printf 'a considered note that mentions example/other#99 in passing\n' > "$CASE_DIR/seed"
  fm "$HOME_DIR" update gi-1 --body-file "$CASE_DIR/seed" >/dev/null \
    || fail "could not rewrite the body"
  assert_equals marano/firstmate#12 "$(fm "$HOME_DIR" issue gi-1)" "a body rewrite lost the issue"

  FM_HOME="$HOME_DIR" FM_DATA_OVERRIDE="$HOME_DIR/data" FM_STATE_OVERRIDE="$HOME_DIR/state" \
    FM_CONFIG_OVERRIDE="$HOME_DIR/config" "$ROOT/bin/fm-captain-hold.sh" hold gi-1 \
    --reason "waiting on a call" >/dev/null || fail "could not hold the item"
  fm "$HOME_DIR" issue gi-1 marano/firstmate#13 >/dev/null || fail "could not re-record a held item's issue"
  case "$(fm "$HOME_DIR" body gi-1 | sed -n 1p)" in
    "Captain hold set: "*) ;;
    *) fail "recording an issue pushed the hold stamp off line 1" ;;
  esac
  assert_equals marano/firstmate#13 "$(fm "$HOME_DIR" issue gi-1)" "re-recording the issue did not take"
  pass "a GitHub issue is recorded, read back, and survives a body rewrite and a hold"
}

test_prose_and_malformed_values_are_not_an_issue() {
  local out rc
  make_plain_case prose
  add_item "$HOME_DIR" gi-2
  printf '%s\n' 'This follows marano/firstmate#12 and the GitHub issue discussion.' \
    'See GitHub issue marano/firstmate#13 for background.' > "$CASE_DIR/seed"
  fm "$HOME_DIR" update gi-2 --body-file "$CASE_DIR/seed" >/dev/null || fail "could not seed a body"
  assert_equals none "$(fm "$HOME_DIR" issue gi-2)" "prose mentioning an issue was read as the item's issue"

  for bad in '#12' 'marano/firstmate' 'marano/firstmate#0' 'marano#12' 'a/b/c#1' 'marano/firstmate#12#3'; do
    set +e
    out=$(fm "$HOME_DIR" issue gi-2 "$bad" 2>&1)
    rc=$?
    set -e
    [ "$rc" -ne 0 ] || fail "the malformed issue '$bad' was accepted: $out"
  done
  assert_equals none "$(fm "$HOME_DIR" issue gi-2)" "a refused value was recorded anyway"
  pass "prose naming an issue is not one, and a malformed reference is refused"
}

test_two_issue_lines_are_refused_rather_than_resolved_by_position() {
  local out rc
  make_plain_case two
  add_item "$HOME_DIR" gi-3
  printf '%s\n' 'GitHub issue: marano/firstmate#12' '' 'GitHub issue: marano/firstmate#13' > "$CASE_DIR/seed"
  fm "$HOME_DIR" update gi-3 --body-file "$CASE_DIR/seed" >/dev/null || fail "could not seed two lines"
  set +e
  out=$(fm "$HOME_DIR" issue gi-3 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "two issue lines were resolved instead of refused: $out"
  assert_contains "$out" "more than one" "the refusal did not name the duplication"
  pass "two GitHub-issue lines are refused rather than resolved by position"
}

# --- publish ------------------------------------------------------------------

test_publish_creates_the_issue_from_the_public_summary_and_records_it() {
  local out
  make_plain_case publish
  add_item "$HOME_DIR" gi-4
  printf '%s\n' 'Private: cites Bluejam work and the captain'"'"'s recorded words.' > "$CASE_DIR/seed"
  fm "$HOME_DIR" update gi-4 --body-file "$CASE_DIR/seed" >/dev/null || fail "could not seed a body"
  printf 'Mirror chosen backlog items as issues.\n' > "$CASE_DIR/summary"

  out=$(fm_gh publish gi-4 marano/firstmate --title "One-way issue mirror" \
    --summary-file "$CASE_DIR/summary" 2>&1) || fail "publish failed: $out"
  assert_contains "$out" "ok: publish gi-4 -> marano/firstmate#42" "publish did not report the issue"
  assert_equals marano/firstmate#42 "$(fm "$HOME_DIR" issue gi-4)" "publish did not record the issue"
  assert_called "api -X POST repos/marano/firstmate/issues -f title=One-way issue mirror" \
    "publish did not create the issue on the named repository with the public title"
  assert_equals 'Mirror chosen backlog items as issues.' "$(cat "$CASE_DIR/gh-published")" \
    "the issue text was not the public summary"
  assert_contains "$(fm "$HOME_DIR" body gi-4)" "Private: cites Bluejam" \
    "publish disturbed the private body"
  assert_not_contains "$(cat "$CASE_DIR/gh-calls" "$CASE_DIR/gh-published")" "Bluejam" \
    "the private body reached GitHub"
  assert_equals 1 "$(grep -c . "$CASE_DIR/gh-calls")" "a Queued item's publish made more than the one call"
  pass "publish creates the issue from the public title and summary and records it"
}

test_a_second_publish_is_refused_without_a_call() {
  local out rc
  make_plain_case publish-twice
  add_item "$HOME_DIR" gi-5
  fm "$HOME_DIR" issue gi-5 marano/firstmate#7 >/dev/null || fail "could not record an issue"
  set +e
  out=$(fm_gh publish gi-5 marano/firstmate --title "Again" --summary "Again" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "a second publish was not refused: $out"
  assert_contains "$out" "already published as marano/firstmate#7" "the refusal did not name the existing issue"
  assert_no_calls "a refused publish still called GitHub"
  pass "an item that already carries an issue is never published twice"
}

test_a_failed_publish_records_nothing() {
  local out rc
  make_plain_case publish-fails
  add_item "$HOME_DIR" gi-6
  : > "$CASE_DIR/gh-fail"
  set +e
  out=$(fm_gh publish gi-6 marano/firstmate --title "Title" --summary "Summary" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "a failed publish reported success: $out"
  assert_contains "$out" "HTTP 500" "the refusal did not carry GitHub's reason"
  assert_equals none "$(fm "$HOME_DIR" issue gi-6)" "a failed publish recorded an issue"
  pass "a publish GitHub refuses records nothing and says why"
}

test_publishing_an_in_flight_item_labels_it_at_once() {
  local out
  make_plain_case publish-in-flight
  add_item "$HOME_DIR" gi-7
  fm "$HOME_DIR" start gi-7 >/dev/null || fail "could not start the item"
  out=$(fm_gh publish gi-7 marano/firstmate --title "Title" --summary "Summary" 2>&1) \
    || fail "publish failed: $out"
  assert_called "api -X POST repos/marano/firstmate/issues/42/labels -f labels[]=in progress" \
    "an In-flight item's new issue was not labelled in progress"
  assert_contains "$out" "marano/firstmate#42 labelled in progress" "the label was not reported"
  pass "publishing an item already In flight labels its issue in progress"
}

# --- the moves ----------------------------------------------------------------

test_each_move_sets_the_state_the_backlog_implies() {
  local out
  make_plain_case moves
  add_item "$HOME_DIR" gi-8
  fm "$HOME_DIR" issue gi-8 marano/firstmate#12 >/dev/null || fail "could not record an issue"

  out=$(FM_FAKE_GH_DIR="$CASE_DIR" FM_GITHUB_ISSUE_CMD="$TRANSPORT" \
    with_lib "$HOME_DIR" 'fm_github_issue_advance "$DATA" merge gi-8')
  assert_contains "$out" "marano/firstmate#12 closed" "the merge move was not reported"
  assert_called "api -X PATCH repos/marano/firstmate/issues/12 -f state=closed -f state_reason=completed" \
    "the merge did not close the issue as completed"
  assert_called "api -X DELETE repos/marano/firstmate/issues/12/labels/in%20progress" \
    "the merge did not drop the in-progress label"

  : > "$CASE_DIR/gh-calls"
  : > "$CASE_DIR/gh-no-label"
  out=$(FM_FAKE_GH_DIR="$CASE_DIR" FM_GITHUB_ISSUE_CMD="$TRANSPORT" \
    with_lib "$HOME_DIR" 'fm_github_issue_advance "$DATA" requeue gi-8' 2>&1)
  assert_called "api -X PATCH repos/marano/firstmate/issues/12 -f state=open" \
    "the requeue did not reopen the issue"
  assert_contains "$out" "marano/firstmate#12 reopened as queued" \
    "a label the issue no longer carries was reported as a failure: $out"
  assert_not_contains "$out" "actionable" "a missing label was reported as actionable"

  : > "$CASE_DIR/gh-calls"
  out=$(FM_FAKE_GH_DIR="$CASE_DIR" FM_GITHUB_ISSUE_CMD="$TRANSPORT" \
    with_lib "$HOME_DIR" 'fm_github_issue_advance "$DATA" verified gi-8; printf "rc=%s\n" "$?"' 2>&1)
  assert_contains "$out" "rc=0" "an unknown phase did not return cleanly"
  assert_no_calls "an unknown phase reached GitHub"
  pass "merge closes the issue, requeue reopens it, and each drops the in-progress label"
}

test_the_requeue_verb_reopens_the_issue_and_never_fails_on_it() {
  local out
  make_plain_case requeue-verb
  add_item "$HOME_DIR" gi-9
  fm "$HOME_DIR" issue gi-9 marano/firstmate#12 >/dev/null || fail "could not record an issue"
  fm "$HOME_DIR" start gi-9 >/dev/null || fail "could not start the item"
  fm "$HOME_DIR" "done" gi-9 >/dev/null || fail "could not close the item"

  out=$(fm_gh requeue gi-9 2>&1) || fail "the requeue failed: $out"
  assert_contains "$out" "ok: requeue gi-9 -> Queued" "the requeue did not land"
  assert_called "api -X PATCH repos/marano/firstmate/issues/12 -f state=open" \
    "a requeued item's issue was not reopened"

  fm "$HOME_DIR" start gi-9 >/dev/null || fail "could not restart the item"
  fm "$HOME_DIR" "done" gi-9 >/dev/null || fail "could not close the item again"
  : > "$CASE_DIR/gh-fail"
  out=$(fm_gh requeue gi-9 2>&1) || fail "a mirror failure failed the requeue: $out"
  assert_contains "$out" "ok: requeue gi-9 -> Queued" "the requeue did not land despite the mirror"
  assert_contains "$out" "actionable: the GitHub issue marano/firstmate#12 recorded on gi-9 could not be reopened" \
    "the mirror failure was not reported as actionable"
  pass "requeue reopens the item's issue, and a GitHub failure never fails the requeue"
}

test_an_item_with_no_issue_is_untouched_and_unmentioned() {
  local out
  make_plain_case no-issue
  add_item "$HOME_DIR" gi-10
  fm "$HOME_DIR" start gi-10 >/dev/null || fail "could not start the item"
  fm "$HOME_DIR" "done" gi-10 >/dev/null || fail "could not close the item"
  out=$(fm_gh requeue gi-10 2>&1) || fail "the requeue failed: $out"
  out="$out$(FM_FAKE_GH_DIR="$CASE_DIR" FM_GITHUB_ISSUE_CMD="$TRANSPORT" \
    with_lib "$HOME_DIR" 'for p in start merge requeue; do fm_github_issue_advance "$DATA" $p gi-10; done' 2>&1)"
  assert_no_calls "an item with no issue reached GitHub"
  assert_not_contains "$out" "github-issue" "an item with no issue was reported on"
  assert_not_contains "$out" "GitHub" "an item with no issue mentioned GitHub"
  pass "an item with no issue line is untouched and unmentioned by every move"
}

# --- the dispatch half ----------------------------------------------------------

run_dispatch_case() {  # <name> <id> [mode-file]; sets CASE_DIR HOME_DIR, prints output
  local name=$1 id=$2 mode=${3-} proj wt fakebin
  CASE_DIR="$TMP_ROOT/$name"
  HOME_DIR="$CASE_DIR/home"
  proj="$CASE_DIR/project"
  wt="$CASE_DIR/wt"
  mkdir -p "$CASE_DIR"
  make_home "$HOME_DIR"
  TRANSPORT=$(make_transport "$CASE_DIR")
  fakebin=$(fm_test_make_spawn_fakebin "$CASE_DIR/spawn")
  fm_git_worktree "$proj" "$wt" "wt-$name"
  fm_test_spawn_brief "$HOME_DIR" "$id"
  add_item "$HOME_DIR" "$id"
  [ "${FM_TEST_NO_ISSUE:-}" = 1 ] \
    || fm "$HOME_DIR" issue "$id" marano/firstmate#12 >/dev/null || fail "could not record the issue"
  [ -z "$mode" ] || : > "$CASE_DIR/$mode"
  FM_FAKE_GH_DIR="$CASE_DIR" FM_GITHUB_ISSUE_CMD="$TRANSPORT" \
    FM_GITHUB_ISSUE_TIMEOUT="${FM_TEST_GH_TIMEOUT:-20}" \
    fm_test_run_spawn "$HOME_DIR" "$wt" "$fakebin" --mode no-mistakes --yolo off "$id" "$proj"
}

test_dispatch_labels_the_issue_in_progress() {
  local out status
  set +e
  out=$(run_dispatch_case dispatch-labels gi-d1)
  status=$?
  set -e
  CASE_DIR="$TMP_ROOT/dispatch-labels"
  expect_code 0 "$status" "the dispatch should succeed: $out"
  assert_contains "$out" "spawned gi-d1" "the dispatch did not report success"
  assert_contains "$out" "marano/firstmate#12 labelled in progress" "the dispatch did not report the label"
  assert_called "api -X POST repos/marano/firstmate/issues/12/labels -f labels[]=in progress" \
    "the dispatch did not label the issue in progress"
  pass "a dispatch labels its item's issue in progress"
}

test_a_github_failure_never_fails_the_dispatch() {
  local out status mode
  for mode in gh-fail gh-hang; do
    set +e
    out=$(FM_TEST_GH_TIMEOUT=2 run_dispatch_case "dispatch-$mode" gi-d2 "$mode")
    status=$?
    set -e
    expect_code 0 "$status" "a mirror failure ($mode) must not fail the dispatch: $out"
    assert_contains "$out" "spawned gi-d2" "the worker was not launched despite $mode"
    assert_contains "$out" "actionable: the GitHub issue marano/firstmate#12 recorded on gi-d2 could not be labelled" \
      "the $mode failure was not reported where a reader sees it"
    assert_grep 'window=' "$TMP_ROOT/dispatch-$mode/home/state/gi-d2.meta" "the task record was not published"
  done
  assert_contains "$out" "did not answer within 2s" "the bound was not reported"
  pass "a GitHub failure or a wedged transport leaves the dispatch successful"
}

test_dispatch_of_an_item_with_no_issue_calls_nothing() {
  local out status
  set +e
  out=$(FM_TEST_NO_ISSUE=1 run_dispatch_case dispatch-no-issue gi-d3)
  status=$?
  set -e
  CASE_DIR="$TMP_ROOT/dispatch-no-issue"
  expect_code 0 "$status" "an item with no issue must dispatch normally: $out"
  assert_contains "$out" "spawned gi-d3" "the dispatch did not report success"
  assert_no_calls "an item with no issue reached GitHub at dispatch"
  assert_not_contains "$out" "github-issue" "an item with no issue was reported on"
  pass "dispatching an item with no issue line makes no call and says nothing"
}

# --- handback -------------------------------------------------------------------

test_a_handback_reopens_the_members_issue_as_queued() {
  local out
  make_plain_case handback
  add_item "$HOME_DIR" gi-unit
  add_item "$HOME_DIR" gi-member
  fm "$HOME_DIR" issue gi-member marano/firstmate#21 >/dev/null || fail "could not record an issue"
  fm "$HOME_DIR" start gi-unit >/dev/null || fail "could not start the unit"
  fm "$HOME_DIR" start gi-member >/dev/null || fail "could not start the member"
  printf 'kind=ship\ndelivers=gi-member\n' > "$HOME_DIR/state/gi-unit.meta"

  out=$(fm_gh handback gi-unit gi-member --reason "out of scope" 2>&1) || fail "the handback failed: $out"
  assert_contains "$out" "ok: handback gi-member from gi-unit -> Queued" "the handback did not land"
  assert_called "api -X PATCH repos/marano/firstmate/issues/21 -f state=open" \
    "the handed-back member's issue was not reopened"
  assert_called "api -X DELETE repos/marano/firstmate/issues/21/labels/in%20progress" \
    "the handed-back member's issue kept its in-progress label"
  pass "a handback returns the member's issue to open without the in-progress label"
}

# --- the brief line ---------------------------------------------------------------

test_a_brief_for_an_item_with_an_issue_asks_for_refs_and_no_closer() {
  local brief
  make_plain_case brief
  add_item "$HOME_DIR" gi-b1
  add_item "$HOME_DIR" gi-b2
  add_item "$HOME_DIR" gi-b3
  fm "$HOME_DIR" issue gi-b1 marano/firstmate#31 >/dev/null || fail "could not record an issue"
  fm "$HOME_DIR" issue gi-b3 marano/firstmate#33 >/dev/null || fail "could not record an issue"

  FM_HOME="$HOME_DIR" FM_DATA_OVERRIDE="$HOME_DIR/data" FM_STATE_OVERRIDE="$HOME_DIR/state" \
    "$ROOT/bin/fm-brief.sh" gi-b1 firstmate --mode no-mistakes >/dev/null || fail "could not scaffold a brief"
  brief=$(cat "$HOME_DIR/data/gi-b1/brief.md")
  assert_contains "$brief" '`Refs marano/firstmate#31` in the pull request body, and never a closing keyword' \
    "the brief did not tell the worker to write Refs and no closing keyword"

  FM_HOME="$HOME_DIR" FM_DATA_OVERRIDE="$HOME_DIR/data" FM_STATE_OVERRIDE="$HOME_DIR/state" \
    "$ROOT/bin/fm-brief.sh" gi-b2 firstmate --mode no-mistakes --delivers gi-b3 >/dev/null \
    || fail "could not scaffold a grouped brief"
  brief=$(cat "$HOME_DIR/data/gi-b2/brief.md")
  assert_contains "$brief" '`Refs marano/firstmate#33`' "a delivered item's issue was not named"

  rm -rf "$HOME_DIR/data/gi-b2"
  FM_HOME="$HOME_DIR" FM_DATA_OVERRIDE="$HOME_DIR/data" FM_STATE_OVERRIDE="$HOME_DIR/state" \
    "$ROOT/bin/fm-brief.sh" gi-b2 firstmate --mode no-mistakes >/dev/null || fail "could not scaffold a plain brief"
  brief=$(cat "$HOME_DIR/data/gi-b2/brief.md")
  assert_not_contains "$brief" "Refs " "a brief for an item with no issue mentioned one"
  pass "a brief names Refs for each mirrored issue and forbids a closing keyword, and only then"
}

test_an_issue_is_recorded_read_back_and_survives_a_body_rewrite
test_prose_and_malformed_values_are_not_an_issue
test_two_issue_lines_are_refused_rather_than_resolved_by_position
test_publish_creates_the_issue_from_the_public_summary_and_records_it
test_a_second_publish_is_refused_without_a_call
test_a_failed_publish_records_nothing
test_publishing_an_in_flight_item_labels_it_at_once
test_each_move_sets_the_state_the_backlog_implies
test_the_requeue_verb_reopens_the_issue_and_never_fails_on_it
test_an_item_with_no_issue_is_untouched_and_unmentioned
test_dispatch_labels_the_issue_in_progress
test_a_github_failure_never_fails_the_dispatch
test_dispatch_of_an_item_with_no_issue_calls_nothing
test_a_handback_reopens_the_members_issue_as_queued
test_a_brief_for_an_item_with_an_issue_asks_for_refs_and_no_closer
