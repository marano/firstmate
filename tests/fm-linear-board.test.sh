#!/usr/bin/env bash
# Behavior tests for firstmate's Linear board moves: the identifier a backlog
# item carries (bin/fm-tasks-axi.sh linear), the contract that decides each move
# (bin/fm-linear-lib.sh), and the dispatch half of the rule (bin/fm-spawn.sh).
# The merge half lives in tests/fm-pr-merge.test.sh, beside the rest of that
# script's behavior.
#
# Every case reaches Linear through the FM_LINEAR_CMD seam, because no test may
# call the real API. The fake transport answers the card lookup from the case's
# own fixture and records every mutation, so a case asserts what the board was
# actually asked to do rather than that some call was made.
#
# The single-quoted with_lib snippets are deliberate: the helper evaluates them
# in a subshell where DATA and HOME_DIR exist.
# shellcheck disable=SC2016
#
# What these pin, and the mutant each one kills:
#   - a dispatch moves the card to the team's started status ("report the
#     dispatch and leave the board alone", "record the card but never read it");
#   - a card already started, completed, or cancelled is LEFT WHERE IT IS, with
#     no mutation sent at all ("set the status unconditionally"), which is the
#     captain's own hand-move surviving a dispatch;
#   - the completed target is the team's FIRST completed status, never the
#     captain's own `Verified` ("take any completed status", "take the last
#     one"), proven on a team that defines both;
#   - a transport failure, a GraphQL error, and a wedged transport each leave the
#     spawn successful and the worker launched ("let the board failure
#     propagate"), and say so where a reader will see it;
#   - an item with no card is reported and the dispatch proceeds ("treat a
#     missing card as an error");
#   - a home with no Linear key says nothing at all ("report a missing card even
#     when this home has no board");
#   - the card survives a body rewrite and a hold, and prose that merely mentions
#     a ticket is not a card ("grep the body for BLU-", "let a note edit drop
#     it");
#   - two card lines refuse rather than the last one winning ("last one wins");
#   - a grouped dispatch moves its members' cards too, because their rows moved
#     In flight in the same commit ("move the unit's card alone").
set -u

# shellcheck source=tests/fixtures.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

WRAPPER="$ROOT/bin/fm-tasks-axi.sh"
TMP_ROOT=$(fm_test_tmproot fm-linear-board)

unset TASKS_AXI_FILE TASKS_AXI_BACKEND FM_HOME FM_ROOT_OVERRIDE \
  FM_DATA_OVERRIDE FM_STATE_OVERRIDE FM_CONFIG_OVERRIDE \
  FM_LINEAR_API_KEY FM_LINEAR_CMD FM_LINEAR_API_URL FM_LINEAR_ENV_FILE

command -v tasks-axi >/dev/null 2>&1 \
  || { echo "SKIP: tasks-axi is not installed; the backlog side cannot be driven" >&2; exit 0; }
command -v jq >/dev/null 2>&1 \
  || { echo "SKIP: jq is not installed; the Linear request builder needs it" >&2; exit 0; }

# The team every fixture answers with. Two started statuses and two completed
# ones, deliberately: `In Review` and `Verified` are the extra ones, and a move
# that picked either would be the mutant these tests exist to kill. `position`
# is out of file order so nothing can pass by reading the array as written.
TEAM_STATES='[
  {"id":"st-done","name":"Done","type":"completed","position":4},
  {"id":"st-backlog","name":"Backlog","type":"backlog","position":0},
  {"id":"st-verified","name":"Verified","type":"completed","position":5},
  {"id":"st-progress","name":"In Progress","type":"started","position":2},
  {"id":"st-todo","name":"Todo","type":"unstarted","position":1},
  {"id":"st-review","name":"In Review","type":"started","position":3}
]'

# The fake transport. It reads the request body file it is handed, logs it, and
# answers from the case directory:
#   linear-state       the current status the card is in: "<id> <name> <type>"
#   linear-fail        present: exit nonzero, as a transport or network failure
#   linear-graphql     present: answer with a GraphQL errors array
#   linear-hang        present: sleep past the bound instead of answering
#   linear-missing     present: answer that no issue matches
#   linear-mutations   appended with the state id each move asks for
make_linear_transport() {  # <fakebin> <case-dir>
  local fakebin=$1 case_dir=$2
  cat > "$fakebin/fm-fake-linear" <<'SH'
#!/usr/bin/env bash
set -u
dir=$FM_FAKE_LINEAR_DIR
body=$1
printf '%s\n' "$(tr -d '\n' < "$body")" >> "$dir/linear-requests"
[ ! -e "$dir/linear-fail" ] || exit 7
if [ -e "$dir/linear-hang" ]; then
  sleep 30
  exit 0
fi
if [ -e "$dir/linear-graphql" ]; then
  printf '{"errors":[{"message":"Authentication required"}]}\n'
  exit 0
fi
case "$(cat "$body")" in
  *FmMove*)
    jq -r '.variables.state' < "$body" >> "$dir/linear-mutations"
    printf '{"data":{"issueUpdate":{"success":true}}}\n'
    exit 0
    ;;
esac
if [ -e "$dir/linear-missing" ]; then
  printf '{"data":{"issues":{"nodes":[]}}}\n'
  exit 0
fi
read -r state_id state_name state_type < "$dir/linear-state"
jq -n \
  --arg team "$(jq -r '.variables.team' < "$body")" \
  --arg number "$(jq -r '.variables.number' < "$body")" \
  --arg sid "$state_id" --arg sname "$state_name" --arg stype "$state_type" \
  --argjson states "$FM_FAKE_LINEAR_STATES" \
  '{data: {issues: {nodes: [{
      id: ("issue-" + $team + "-" + $number),
      identifier: ($team + "-" + $number),
      state: {id: $sid, name: $sname, type: $stype},
      team: {key: $team, states: {nodes: $states}}
    }]}}}'
SH
  chmod +x "$fakebin/fm-fake-linear"
  printf 'st-backlog Backlog backlog\n' > "$case_dir/linear-state"
  : > "$case_dir/linear-requests"
  : > "$case_dir/linear-mutations"
  printf '%s\n' "$fakebin/fm-fake-linear"
}

# A home with an empty markdown backlog and this repo's tracked .tasks.toml,
# plus the spawn layout and a Linear key so the board is on.
make_home() {  # <dir>
  local home=$1
  fm_test_spawn_home "$home" claude
  cp "$ROOT/.tasks.toml" "$home/.tasks.toml"
  printf '## In flight\n\n## Queued\n\n## Done\n' > "$home/data/backlog.md"
  printf 'FM_LINEAR_API_KEY=lin_api_testkey\n' > "$home/.env"
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
  fm "$home" add "$id" "Item $id" --kind ship --repo app-web "$@" >/dev/null \
    || fail "fixture: could not add $id"
}

# One full dispatch sandbox: a home with a backlog, a real isolated worktree, a
# fake harness world, and the fake Linear transport. Prints a record the cases
# split with read_case.
make_dispatch_case() {  # <name> <task-id>...
  local name=$1 case_dir home proj wt fakebin transport id
  shift
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  mkdir -p "$case_dir"
  make_home "$home"
  fakebin=$(fm_test_make_spawn_fakebin "$case_dir/fake")
  transport=$(make_linear_transport "$fakebin" "$case_dir")
  fm_git_worktree "$proj" "$wt" "wt-$name"
  for id in "$@"; do
    fm_test_spawn_brief "$home" "$id"
    add_item "$home" "$id"
  done
  printf '%s|%s|%s|%s|%s|%s\n' "$case_dir" "$home" "$proj" "$wt" "$fakebin" "$transport"
}

read_case() {  # <record>
  IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR TRANSPORT <<EOF
$1
EOF
}

# Run a real ship dispatch with the fake transport wired in.
run_dispatch() {  # <case-record-globals set> <fm-spawn args...>
  FM_FAKE_LINEAR_DIR="$CASE_DIR" FM_FAKE_LINEAR_STATES="$TEAM_STATES" \
  FM_LINEAR_CMD="${FM_TEST_LINEAR_CMD-$TRANSPORT}" \
  FM_LINEAR_TIMEOUT="${FM_TEST_LINEAR_TIMEOUT:-20}" \
    fm_test_run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" \
      --mode no-mistakes --yolo off "$@"
}

# The library under test, loaded in a subshell with this home's paths, exactly
# as tests/fm-grouping.test.sh drives its own library.
with_lib() {  # <home> <shell-snippet>
  local home=$1 snippet=$2
  FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" FM_STATE_OVERRIDE="$home/state" \
    bash -c '
      set -u
      . "$1/bin/fm-linear-lib.sh"
      DATA=$2/data
      HOME_DIR=$2
      eval "$3"
    ' _ "$ROOT" "$home" "$snippet"
}

assert_no_mutation() {  # <case-dir> <message>
  [ ! -s "$1/linear-mutations" ] \
    || fail "$2 (the board was asked to move to: $(tr '\n' ' ' < "$1/linear-mutations"))"
}

assert_moved_to() {  # <case-dir> <state-id> <message>
  local got
  got=$(tr '\n' ' ' < "$1/linear-mutations")
  case " $got " in
    *" $2 "*) ;;
    *) fail "$3 (asked for: ${got:-nothing})" ;;
  esac
}

# --- the identifier a backlog item carries ---------------------------------

test_a_card_is_recorded_read_back_and_survives_a_body_rewrite() {
  local home out
  home="$TMP_ROOT/card-record/home"
  mkdir -p "$TMP_ROOT/card-record"
  make_home "$home"
  add_item "$home" card-1

  out=$(fm "$home" linear card-1) || fail "could not read an unrecorded card"
  assert_equals none "$out" "an item with no card did not read back none"

  fm "$home" linear card-1 BLU-3268 >/dev/null || fail "could not record a card"
  out=$(fm "$home" linear card-1) || fail "could not read the card back"
  assert_equals BLU-3268 "$out" "the recorded card did not read back"

  # The rewrite that would silently drop it: replacing a considered note.
  printf 'imported ticket text that mentions BLU-9999 in passing\n' > "$home/seed"
  fm "$home" update card-1 --body-file "$home/seed" >/dev/null \
    || fail "could not rewrite the body"
  out=$(fm "$home" linear card-1) || fail "could not read the card after a rewrite"
  assert_equals BLU-3268 "$out" "a body rewrite lost the card"

  # A hold stamp owns line 1; recording a card must not push it down.
  FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" FM_STATE_OVERRIDE="$home/state" \
    FM_CONFIG_OVERRIDE="$home/config" "$ROOT/bin/fm-captain-hold.sh" hold card-1 \
    --reason "waiting on a call" >/dev/null || fail "could not hold the item"
  fm "$home" linear card-1 BLU-3270 >/dev/null || fail "could not re-record a held item's card"
  out=$(fm "$home" body card-1 | sed -n 1p)
  case "$out" in
    "Captain hold set: "*) ;;
    *) fail "recording a card pushed the hold stamp off line 1: $out" ;;
  esac
  assert_equals BLU-3270 "$(fm "$home" linear card-1)" "re-recording the card did not take"
  pass "a Linear card is recorded, read back, and survives a body rewrite and a hold"
}

test_prose_naming_a_ticket_is_not_a_card() {
  local home out
  home="$TMP_ROOT/card-prose/home"
  mkdir -p "$TMP_ROOT/card-prose"
  make_home "$home"
  add_item "$home" card-2
  printf '%s\n' 'This follows up BLU-3268 and the Linear card discussion.' \
    'See Linear card BLU-3271 in the thread for background.' > "$home/seed"
  fm "$home" update card-2 --body-file "$home/seed" >/dev/null || fail "could not seed a body"
  out=$(fm "$home" linear card-2) || fail "reading a card from prose failed"
  assert_equals none "$out" "prose mentioning a ticket was read as the item's card"
  pass "prose that merely mentions a ticket is not a recorded card"
}

test_two_card_lines_are_refused_rather_than_resolved_by_position() {
  local home out rc
  home="$TMP_ROOT/card-two/home"
  mkdir -p "$TMP_ROOT/card-two"
  make_home "$home"
  add_item "$home" card-3
  printf '%s\n' 'Linear card: BLU-3268' '' 'Linear card: BLU-9999' > "$home/seed"
  fm "$home" update card-3 --body-file "$home/seed" >/dev/null || fail "could not seed two lines"
  set +e
  out=$(fm "$home" linear card-3 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "two card lines were resolved instead of refused: $out"
  assert_contains "$out" "more than one" "the refusal did not name the duplication"
  pass "two Linear-card lines are refused rather than resolved by position"
}

test_a_malformed_card_is_refused_not_guessed() {
  local home out rc
  home="$TMP_ROOT/card-bad/home"
  mkdir -p "$TMP_ROOT/card-bad"
  make_home "$home"
  add_item "$home" card-4
  set +e
  out=$(fm "$home" linear card-4 blu-3268 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "a lowercase identifier was accepted: $out"
  out=$(fm "$home" linear card-4)
  assert_equals none "$out" "the refused value was recorded anyway"
  pass "a value that is not a Linear identifier is refused, never guessed at"
}

# --- the dispatch half ------------------------------------------------------

test_dispatch_moves_the_card_to_the_teams_started_status() {
  local rec out status
  rec=$(make_dispatch_case dispatch-moves task-lin1)
  read_case "$rec"
  fm "$HOME_DIR" linear task-lin1 BLU-3268 >/dev/null || fail "could not record the card"

  set +e
  out=$(run_dispatch task-lin1 "$PROJ_DIR" 2>&1)
  status=$?
  set -e
  expect_code 0 "$status" "the dispatch should succeed: $out"
  assert_contains "$out" "spawned task-lin1" "the dispatch did not report success"
  assert_contains "$out" "BLU-3268 moved to In Progress" \
    "the dispatch did not report moving the card"
  assert_moved_to "$CASE_DIR" st-progress "the card was not moved to the team's started status"
  pass "a dispatch moves its item's card to the team's started status"
}

test_dispatch_leaves_a_card_the_captain_already_moved_alone() {
  local rec out status current
  for current in "st-review In-Review started" "st-done Done completed" \
    "st-cancelled Cancelled canceled"; do
    rec=$(make_dispatch_case "dispatch-keeps-${current%% *}" task-lin2)
    read_case "$rec"
    fm "$HOME_DIR" linear task-lin2 BLU-3268 >/dev/null || fail "could not record the card"
    printf '%s\n' "$current" > "$CASE_DIR/linear-state"

    set +e
    out=$(run_dispatch task-lin2 "$PROJ_DIR" 2>&1)
    status=$?
    set -e
    expect_code 0 "$status" "the dispatch should succeed for $current: $out"
    assert_contains "$out" "spawned task-lin2" "the dispatch did not report success"
    assert_contains "$out" "left in" "the dispatch did not report leaving the card alone: $out"
    assert_no_mutation "$CASE_DIR" "a card already at $current was moved anyway"
  done
  pass "a card already started, completed, or cancelled is left exactly where it is"
}

test_a_linear_failure_never_fails_the_dispatch() {
  local rec out status mode
  for mode in linear-fail linear-graphql linear-missing; do
    rec=$(make_dispatch_case "dispatch-$mode" task-lin3)
    read_case "$rec"
    fm "$HOME_DIR" linear task-lin3 BLU-3268 >/dev/null || fail "could not record the card"
    : > "$CASE_DIR/$mode"

    set +e
    out=$(run_dispatch task-lin3 "$PROJ_DIR" 2>&1)
    status=$?
    set -e
    expect_code 0 "$status" "a board failure ($mode) must not fail the dispatch: $out"
    assert_contains "$out" "spawned task-lin3" "the worker was not launched despite $mode"
    assert_contains "$out" "actionable:" "the $mode failure was not reported where a reader sees it"
    assert_grep 'window=' "$HOME_DIR/state/task-lin3.meta" "the task record was not published"
  done
  pass "a transport failure, a GraphQL error, and an unknown card each leave the dispatch successful"
}

test_a_wedged_board_cannot_hold_a_dispatch_open() {
  local rec out status
  rec=$(make_dispatch_case dispatch-hang task-lin4)
  read_case "$rec"
  fm "$HOME_DIR" linear task-lin4 BLU-3268 >/dev/null || fail "could not record the card"
  : > "$CASE_DIR/linear-hang"

  set +e
  out=$(FM_TEST_LINEAR_TIMEOUT=2 run_dispatch task-lin4 "$PROJ_DIR" 2>&1)
  status=$?
  set -e
  expect_code 0 "$status" "a wedged board must not fail the dispatch: $out"
  assert_contains "$out" "spawned task-lin4" "the worker was not launched"
  assert_contains "$out" "did not answer within" "the bound was not reported"
  pass "a board that never answers is bounded and the dispatch still succeeds"
}

test_an_item_with_no_card_is_reported_and_the_dispatch_proceeds() {
  local rec out status
  rec=$(make_dispatch_case dispatch-nocard task-lin5)
  read_case "$rec"

  set +e
  out=$(run_dispatch task-lin5 "$PROJ_DIR" 2>&1)
  status=$?
  set -e
  expect_code 0 "$status" "an item with no card must dispatch normally: $out"
  assert_contains "$out" "spawned task-lin5" "the dispatch did not report success"
  assert_contains "$out" "has no Linear card" "the missing card was not reported"
  assert_no_mutation "$CASE_DIR" "an item with no card still moved something"
  pass "an item with no Linear card is reported and its dispatch proceeds"
}

test_a_home_with_no_linear_key_says_nothing_at_all() {
  local rec out status
  rec=$(make_dispatch_case dispatch-nokey task-lin6)
  read_case "$rec"
  rm -f "$HOME_DIR/.env"
  fm "$HOME_DIR" linear task-lin6 BLU-3268 >/dev/null || fail "could not record the card"

  set +e
  out=$(FM_TEST_LINEAR_CMD='' run_dispatch task-lin6 "$PROJ_DIR" 2>&1)
  status=$?
  set -e
  expect_code 0 "$status" "a home with no board key must dispatch normally: $out"
  assert_contains "$out" "spawned task-lin6" "the dispatch did not report success"
  assert_not_contains "$out" "linear:" "a home with no board key still reported about one"
  assert_not_contains "$out" "Linear" "a home with no board key still mentioned Linear"
  pass "a home with no Linear key says nothing about the board"
}

test_a_grouped_dispatch_moves_its_members_cards_too() {
  local rec out status
  rec=$(make_dispatch_case dispatch-grouped task-lin7 task-lin8)
  read_case "$rec"
  fm "$HOME_DIR" linear task-lin7 BLU-3268 >/dev/null || fail "could not record the unit's card"
  fm "$HOME_DIR" linear task-lin8 BLU-3270 >/dev/null || fail "could not record the member's card"

  set +e
  out=$(run_dispatch task-lin7 "$PROJ_DIR" --delivers task-lin8 2>&1)
  status=$?
  set -e
  expect_code 0 "$status" "the grouped dispatch should succeed: $out"
  assert_contains "$out" "BLU-3268 moved to In Progress" "the unit's card was not moved"
  assert_contains "$out" "BLU-3270 moved to In Progress" "the member's card was not moved"
  pass "a grouped dispatch moves the cards of every item it delivers"
}

# --- the status the board is never allowed to reach -------------------------

# The captain's own `Verified` is a second completed status on the same team.
# Nothing in the code names it, so this is the case that proves the target is
# resolved from the team's own workflow order rather than by picking any
# completed status.
test_the_completed_target_is_never_the_captains_verified() {
  local home out
  home="$TMP_ROOT/target-verified/home"
  mkdir -p "$TMP_ROOT/target-verified"
  make_home "$home"
  add_item "$home" card-v1
  fm "$home" linear card-v1 BLU-3268 >/dev/null || fail "could not record the card"
  local transport
  transport=$(make_linear_transport "$(fm_fakebin "$TMP_ROOT/target-verified/fake")" \
    "$TMP_ROOT/target-verified")
  printf 'st-review In-Review started\n' > "$TMP_ROOT/target-verified/linear-state"

  out=$(FM_FAKE_LINEAR_DIR="$TMP_ROOT/target-verified" FM_FAKE_LINEAR_STATES="$TEAM_STATES" \
    FM_LINEAR_CMD="$transport" FM_LINEAR_API_KEY=lin_api_testkey \
    with_lib "$home" 'fm_linear_board_advance "$HOME_DIR" "$DATA" merge card-v1')
  assert_contains "$out" "moved to Done" "the merge did not move the card to Done: $out"
  assert_not_contains "$out" Verified "the merge reported the captain's own status"
  assert_moved_to "$TMP_ROOT/target-verified" st-done "the merge did not target the team's first completed status"
  [ "$(grep -c . "$TMP_ROOT/target-verified/linear-mutations")" = 1 ] \
    || fail "the merge asked for more than one status"
  case "$(cat "$TMP_ROOT/target-verified/linear-mutations")" in
    *st-verified*) fail "the merge asked for the captain's Verified status" ;;
  esac
  pass "the completed target is the team's first completed status, never the captain's Verified"
}

test_an_unknown_phase_moves_nothing() {
  local home out
  home="$TMP_ROOT/phase-unknown/home"
  mkdir -p "$TMP_ROOT/phase-unknown"
  make_home "$home"
  add_item "$home" card-p1
  fm "$home" linear card-p1 BLU-3268 >/dev/null || fail "could not record the card"
  out=$(FM_LINEAR_API_KEY=lin_api_testkey FM_LINEAR_CMD=/bin/false \
    with_lib "$home" 'fm_linear_board_advance "$HOME_DIR" "$DATA" verified card-p1; printf "rc=%s\n" "$?"' 2>&1)
  assert_contains "$out" "rc=0" "an unknown phase did not return cleanly: $out"
  assert_not_contains "$out" "actionable" "an unknown phase reached the board: $out"
  pass "a phase other than the two the captain named moves nothing"
}

test_a_card_is_recorded_read_back_and_survives_a_body_rewrite
test_prose_naming_a_ticket_is_not_a_card
test_two_card_lines_are_refused_rather_than_resolved_by_position
test_a_malformed_card_is_refused_not_guessed
test_dispatch_moves_the_card_to_the_teams_started_status
test_dispatch_leaves_a_card_the_captain_already_moved_alone
test_a_linear_failure_never_fails_the_dispatch
test_a_wedged_board_cannot_hold_a_dispatch_open
test_an_item_with_no_card_is_reported_and_the_dispatch_proceeds
test_a_home_with_no_linear_key_says_nothing_at_all
test_a_grouped_dispatch_moves_its_members_cards_too
test_the_completed_target_is_never_the_captains_verified
test_an_unknown_phase_moves_nothing
