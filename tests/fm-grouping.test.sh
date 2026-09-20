#!/usr/bin/env bash
# Behavior tests for the backlog side of work grouping: the posture read, the
# group key an item carries, the `chunk`, `join` and `plan` verbs, and the
# sibling definition every later consumer asks bin/fm-grouping-lib.sh for.
#
# What these pin, and the mutant each one kills:
#   - a malformed posture refuses instead of falling back to off ("unknown token
#     means off");
#   - an absent posture file reads off and makes no backlog call ("absent means
#     warn");
#   - a key survives a hold, a release, a handback, and an ordinary note
#     rewrite ("read the first body line only", "a plain update may drop it");
#   - setting a key leaves the hold stamp on line 1 ("prepend the key line");
#   - two key lines refuse rather than the last one winning ("last one wins");
#   - a chunk reads as ONE ready item ("create the unit but skip the edges");
#   - a chunk refuses a second repository before writing anything ("validate
#     after mutating");
#   - a chunk is idempotent ("append the plan line rather than replacing it",
#     which leaves a second plan and a second key line behind on a re-run);
#   - a chunk dispatches through --delivers and closes with the unit's own
#     link, which is the claim that its shape is the one spawn already accepts;
#   - a sibling never crosses a repository ("match on key alone");
#   - a live sibling comes from the worker record, and a worker that reported
#     blocked, needs-decision or even done is still live until its agent is
#     stopped ("reuse status_is_terminal_verb", "a concluded worker is idle");
#   - an unreadable backlog is "cannot tell", never an empty sibling set ("a
#     failed read means no siblings");
#   - join records a member only after its row moved ("record first, then row"),
#     refuses an unrelated item and a unit with a pending close, and resumes a
#     row an interrupted join already moved ("reuse the dispatchable check
#     alone", which refuses that retry).
# The single-quoted with_lib snippets are deliberate: the helper evaluates them
# in a subshell where DATA, STATE, CONFIG and the FM_GROUPING_* globals exist.
# shellcheck disable=SC2016

set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

WRAPPER="$ROOT/bin/fm-tasks-axi.sh"
SPAWN="$ROOT/bin/fm-spawn.sh"
TEARDOWN="$ROOT/bin/fm-teardown.sh"
TMP_ROOT=$(fm_test_tmproot fm-grouping)

unset TASKS_AXI_FILE TASKS_AXI_BACKEND FM_HOME FM_ROOT_OVERRIDE \
  FM_DATA_OVERRIDE FM_STATE_OVERRIDE FM_CONFIG_OVERRIDE FM_GROUPING

HAVE_TASKS_AXI=0
command -v tasks-axi >/dev/null 2>&1 && HAVE_TASKS_AXI=1

# A home with an empty markdown backlog and this repo's tracked .tasks.toml.
make_home() {  # <name>; prints the home directory
  local dir="$TMP_ROOT/$1"
  mkdir -p "$dir/data" "$dir/state" "$dir/config"
  cp "$ROOT/.tasks.toml" "$dir/.tasks.toml"
  printf '## In flight\n\n## Queued\n\n## Done\n' > "$dir/data/backlog.md"
  printf '%s\n' "$dir"
}

fm() {  # <home> <args...>
  local home=$1
  shift
  FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" FM_STATE_OVERRIDE="$home/state" \
    FM_CONFIG_OVERRIDE="$home/config" "$WRAPPER" "$@"
}

add_item() {  # <home> <id> <repo> [flag...]
  local home=$1 id=$2 repo=$3
  shift 3
  fm "$home" add "$id" "Item $id" --kind ship --repo "$repo" "$@" >/dev/null \
    || fail "fixture: could not add $id"
}

# A worker record for <id>, as bin/fm-spawn.sh publishes one.
write_record() {  # <home> <id> [extra=value...]
  local home=$1 id=$2
  shift 2
  fm_write_meta "$home/state/$id.meta" \
    "window=fm-$id" \
    "endpoint_task_id=$id" \
    "worktree=$home/wt-$id" \
    "project=$home/project" \
    "kind=ship" \
    "mode=no-mistakes" \
    "$@"
}

# The library under test, loaded in a subshell with this home's paths.
with_lib() {  # <home> <shell-snippet>
  local home=$1 snippet=$2
  FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" FM_STATE_OVERRIDE="$home/state" \
    FM_CONFIG_OVERRIDE="$home/config" \
    bash -c '
      set -u
      . "$1/bin/fm-grouping-lib.sh"
      DATA=$2/data
      STATE=$2/state
      CONFIG=$2/config
      eval "$3"
    ' _ "$ROOT" "$home" "$snippet"
}

test_a_malformed_grouping_posture_is_refused_not_defaulted() {
  local home out rc
  home=$(make_home posture-malformed)
  printf 'enfroce\n' > "$home/config/grouping"
  set +e
  out=$(with_lib "$home" 'fm_grouping_posture "$CONFIG" || printf "refused: %s\n" "$FM_GROUPING_ERROR"')
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "the posture read crashed: $out"
  assert_contains "$out" "refused:" "a malformed posture did not refuse"
  assert_contains "$out" "enfroce" "the refusal did not name the bad token"
  assert_contains "$out" "$home/config/grouping" "the refusal did not name the file"

  printf 'enforce two\n' > "$home/config/grouping"
  out=$(with_lib "$home" 'fm_grouping_posture "$CONFIG" || printf "refused: %s\n" "$FM_GROUPING_ERROR"')
  assert_contains "$out" "refused:" "a malformed member cap did not refuse"

  printf 'enforce 6\n' > "$home/config/grouping"
  out=$(with_lib "$home" 'fm_grouping_posture "$CONFIG" && printf "%s %s\n" "$FM_GROUPING_POSTURE" "$FM_GROUPING_MEMBER_CAP"')
  [ "$out" = "enforce 6" ] || fail "a posture with a cap did not read back: $out"
  pass "a malformed grouping posture is refused, never defaulted around"
}

test_grouping_is_inert_when_unconfigured() {
  local home out
  home=$(make_home posture-absent)
  out=$(with_lib "$home" 'fm_grouping_posture "$CONFIG" && printf "%s|%s\n" "$FM_GROUPING_POSTURE" "$FM_GROUPING_MEMBER_CAP"')
  [ "$out" = "off|" ] || fail "an absent posture file did not read off: $out"
  out=$(FM_GROUPING="warn" with_lib "$home" 'fm_grouping_posture "$CONFIG" && printf "%s\n" "$FM_GROUPING_POSTURE"')
  [ "$out" = warn ] || fail "the environment override did not win: $out"
  pass "an absent grouping posture reads off, and the environment can still name one"
}

test_group_key_survives_hold_and_handback_body_rewrites() {
  local home out
  home=$(make_home key-survives)
  add_item "$home" card-1 app-web
  fm "$home" group card-1 blu-3156 >/dev/null || fail "could not record a key"
  printf 'imported ticket text\n' > "$home/seed"
  fm "$home" update card-1 --body-file "$home/seed" >/dev/null || fail "could not seed a body"
  fm "$home" group card-1 blu-3156 >/dev/null || fail "could not re-record the key"

  FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" FM_STATE_OVERRIDE="$home/state" \
    FM_CONFIG_OVERRIDE="$home/config" "$ROOT/bin/fm-captain-hold.sh" hold card-1 \
    --reason "waiting on a call" >/dev/null || fail "could not hold the item"
  printf 'go ahead\n' > "$home/decision"
  out=$(fm "$home" group card-1) || fail "the key could not be read after a hold"
  [ "$out" = blu-3156 ] || fail "a hold lost the key: $out"
  out=$(fm "$home" body card-1 | sed -n 1p)
  case "$out" in
    "Captain hold set: "*) ;;
    *) fail "the hold stamp is no longer line 1: $out" ;;
  esac
  # Recording a FIRST key on an item that is already held is where a key line
  # written at the top would push the stamp down and reset the hold's age.
  add_item "$home" card-2 app-web
  printf 'imported ticket text\n' > "$home/seed-2"
  fm "$home" update card-2 --body-file "$home/seed-2" >/dev/null || fail "could not seed a second body"
  FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" FM_STATE_OVERRIDE="$home/state" \
    FM_CONFIG_OVERRIDE="$home/config" "$ROOT/bin/fm-captain-hold.sh" hold card-2 \
    --reason "waiting on a call" >/dev/null || fail "could not hold the second item"
  fm "$home" group card-2 blu-3156 >/dev/null || fail "could not key a held item"
  out=$(fm "$home" body card-2 | sed -n 1p)
  case "$out" in
    "Captain hold set: "*) ;;
    *) fail "keying a held item pushed the hold stamp off line 1: $out" ;;
  esac
  [ "$(fm "$home" group card-2)" = blu-3156 ] || fail "keying a held item did not take"

  fm "$home" group card-1 blu-3157 >/dev/null || fail "could not re-key a held item"
  out=$(fm "$home" body card-1 | sed -n 1p)
  case "$out" in
    "Captain hold set: "*) ;;
    *) fail "re-keying a held item pushed the hold stamp off line 1: $out" ;;
  esac
  [ "$(fm "$home" group card-1)" = blu-3157 ] || fail "re-keying a held item did not take"
  fm "$home" group card-1 blu-3156 >/dev/null || fail "could not restore the key"

  FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" FM_STATE_OVERRIDE="$home/state" \
    FM_CONFIG_OVERRIDE="$home/config" "$ROOT/bin/fm-captain-hold.sh" answer card-1 \
    --decision-file "$home/decision" --release >/dev/null || fail "could not release the hold"
  out=$(fm "$home" group card-1) || fail "the key could not be read after a release"
  [ "$out" = blu-3156 ] || fail "releasing a hold lost the key: $out"

  printf 'a considered replacement note\n' > "$home/new-body"
  fm "$home" update card-1 --body-file "$home/new-body" >/dev/null \
    || fail "an ordinary body rewrite failed"
  out=$(fm "$home" group card-1) || fail "the key could not be read after a note rewrite"
  [ "$out" = blu-3156 ] || fail "an ordinary note rewrite dropped the key: $out"
  assert_contains "$(fm "$home" body card-1)" "a considered replacement note" \
    "carrying the key across a rewrite lost the new note"
  pass "a group key survives a hold, a release, and an ordinary note rewrite"
}

test_group_set_preserves_the_rest_of_the_body() {
  local home before after
  home=$(make_home key-preserves)
  add_item "$home" card-1 app-web
  printf 'first paragraph\n\nsecond paragraph\n' > "$home/seed"
  fm "$home" update card-1 --body-file "$home/seed" >/dev/null || fail "could not seed a body"
  before=$(fm "$home" body card-1)
  fm "$home" group card-1 blu-3156 >/dev/null || fail "could not record a key"
  after=$(fm "$home" body card-1 | grep -v '^Group key: ' | grep -v '^$')
  [ "$(printf '%s\n' "$before" | grep -v '^$')" = "$after" ] \
    || fail "recording a key rewrote the rest of the body: '$before' vs '$after'"
  pass "recording a group key leaves every other line of the body alone"
}

test_a_repeated_group_line_is_refused() {
  local home out rc
  home=$(make_home key-repeated)
  add_item "$home" card-1 app-web
  printf 'Group key: one\n\nGroup key: two\n' > "$home/seed"
  fm "$home" update card-1 --body-file "$home/seed" >/dev/null || fail "could not seed two key lines"
  set +e
  out=$(fm "$home" group card-1 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "two key lines were resolved instead of refused: $out"
  assert_contains "$out" "more than one" "the refusal did not say what is wrong"
  pass "an item carrying two group-key lines is refused, never read by position"
}

test_a_chunk_reads_as_one_ready_item() {
  local home out
  home=$(make_home chunk-ready)
  add_item "$home" card-1 app-web --priority 2
  add_item "$home" card-2 app-web --priority 1
  add_item "$home" other-1 infra
  fm "$home" group card-1 blu-3156 >/dev/null || fail "could not key card-1"
  fm "$home" chunk help-web "Help epic: web children" card-1 card-2 >/dev/null \
    || fail "could not plan the chunk"
  out=$(fm "$home" ready)
  assert_contains "$out" "help-web" "the chunk unit is not ready"
  assert_contains "$out" "other-1" "the unrelated item stopped being ready"
  assert_not_contains "$out" "card-1" "a planned member is still offered as ready work"
  assert_not_contains "$out" "card-2" "a planned member is still offered as ready work"
  [ "$(fm "$home" group card-2)" = blu-3156 ] || fail "the chunk did not stamp its key on an unkeyed member"
  assert_contains "$(fm "$home" body help-web)" "Chunk members: card-1,card-2" \
    "the unit does not record what it plans to deliver"
  pass "a planned chunk reads as one ready item, with its members parked behind it"
}

test_chunk_refuses_a_cross_repo_member_before_any_write() {
  local home out rc before
  home=$(make_home chunk-cross-repo)
  add_item "$home" card-1 app-web
  add_item "$home" other-1 infra
  fm "$home" group card-1 blu-3156 >/dev/null || fail "could not key card-1"
  before=$(cat "$home/data/backlog.md")
  set +e
  out=$(fm "$home" chunk help-web "Mixed" card-1 other-1 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "a cross-repository chunk was accepted: $out"
  assert_contains "$out" "one repository" "the refusal did not name the rule"
  [ "$(cat "$home/data/backlog.md")" = "$before" ] \
    || fail "a refused chunk changed the backlog"
  pass "a chunk refuses a member from a second repository before it writes anything"
}

test_chunk_is_idempotent() {
  local home units edges
  home=$(make_home chunk-idempotent)
  add_item "$home" card-1 app-web
  add_item "$home" card-2 app-web
  fm "$home" group card-1 blu-3156 >/dev/null || fail "could not key card-1"
  fm "$home" chunk help-web "Help epic" card-1 card-2 >/dev/null || fail "first chunk failed"
  fm "$home" chunk help-web "Help epic" card-1 card-2 >/dev/null || fail "second chunk failed"
  units=$(grep -c '^- \[ \] help-web - ' "$home/data/backlog.md")
  [ "$units" -eq 1 ] || fail "re-running the chunk left $units unit rows"
  edges=$(fm "$home" body help-web | grep -c '^Chunk members: ')
  [ "$edges" -eq 1 ] || fail "re-running the chunk left $edges plan lines"
  edges=$(fm "$home" body card-1 | grep -c '^Group key: ')
  [ "$edges" -eq 1 ] || fail "re-running the chunk left $edges key lines on a member"
  [ "$(fm "$home" show card-2 | sed -n 's/^  blocked_by: //p')" = help-web ] \
    || fail "the second run lost a member's edge"
  pass "re-running a chunk leaves one unit row, one plan, and one edge per member"
}

test_chunk_warns_above_the_member_cap_and_never_refuses() {
  local home out
  home=$(make_home chunk-cap)
  printf 'enforce 2\n' > "$home/config/grouping"
  add_item "$home" card-1 app-web
  add_item "$home" card-2 app-web
  add_item "$home" card-3 app-web
  fm "$home" group card-1 blu-3156 >/dev/null || fail "could not key card-1"
  out=$(fm "$home" chunk help-web "Help epic" card-1 card-2 card-3 2>&1) \
    || fail "a chunk above the cap was refused: $out"
  assert_contains "$out" "above this home" "no size warning was printed"
  assert_contains "$out" "ok: chunk" "the chunk did not complete"
  pass "a chunk above the configured member cap warns and still plans"
}

test_siblings_never_cross_a_repository() {
  local home out
  home=$(make_home siblings-repo)
  add_item "$home" unit-a app-web
  add_item "$home" card-1 app-web
  add_item "$home" other-1 infra
  fm "$home" group unit-a blu-3156 >/dev/null
  fm "$home" group card-1 blu-3156 >/dev/null
  fm "$home" group other-1 blu-3156 >/dev/null
  out=$(with_lib "$home" '
    fm_grouping_ready_siblings "$DATA" "$STATE" unit-a app-web blu-3156 \
      && printf "ready:[%s]\n" "$FM_GROUPING_READY_SIBLINGS"')
  [ "$out" = "ready:[card-1]" ] || fail "the ready sibling set crossed a repository or missed one: $out"
  pass "a sibling shares the repository as well as the key"
}

test_live_siblings_come_from_worker_records() {
  local home out
  home=$(make_home siblings-live)
  add_item "$home" unit-a app-web
  add_item "$home" unit-b app-web
  fm "$home" group unit-a blu-3156 >/dev/null
  fm "$home" group unit-b blu-3156 >/dev/null
  fm "$home" start unit-b >/dev/null || fail "could not move the sibling In flight"
  write_record "$home" unit-b
  printf 'blocked: waiting on a decision\n' > "$home/state/unit-b.status"
  out=$(with_lib "$home" '
    fm_grouping_live_siblings "$DATA" "$STATE" unit-a app-web blu-3156 \
      && printf "live:[%s]\n" "$FM_GROUPING_LIVE_SIBLINGS"')
  [ "$out" = "live:[unit-b]" ] || fail "a blocked worker was not read as live: $out"

  printf 'done: PR https://example.invalid/pull/1\n' >> "$home/state/unit-b.status"
  out=$(with_lib "$home" '
    fm_grouping_live_siblings "$DATA" "$STATE" unit-a app-web blu-3156 \
      && printf "live:[%s]\n" "$FM_GROUPING_LIVE_SIBLINGS"')
  [ "$out" = "live:[unit-b]" ] \
    || fail "a worker that reported done but still holds its context was dropped: $out"

  printf 'stopped=1\n' > "$home/state/unit-b.agent-stopped"
  out=$(with_lib "$home" '
    fm_grouping_live_siblings "$DATA" "$STATE" unit-a app-web blu-3156 \
      && printf "live:[%s]\n" "$FM_GROUPING_LIVE_SIBLINGS"')
  [ "$out" = "live:[]" ] || fail "a deliberately stopped worker is still counted as live: $out"
  pass "a live sibling is a worker record whose agent has not been stopped, whatever its last status says"
}

test_an_unreadable_backlog_is_not_an_empty_sibling_set() {
  local home out
  home=$(make_home siblings-unreadable)
  add_item "$home" unit-a app-web
  add_item "$home" card-1 app-web
  fm "$home" group unit-a blu-3156 >/dev/null
  fm "$home" group card-1 blu-3156 >/dev/null
  # A backlog whose rows cannot be read at all: the list still answers, and the
  # per-row read fails, which is exactly the shape a wedged backend produces.
  chmod 000 "$home/data/backlog.md"
  out=$(with_lib "$home" '
    fm_grouping_ready_siblings "$DATA" "$STATE" unit-a app-web blu-3156
    printf "status=%s siblings=[%s] error=%s\n" "$?" "$FM_GROUPING_READY_SIBLINGS" "${FM_GROUPING_ERROR:+set}"')
  chmod 644 "$home/data/backlog.md"
  case "$out" in
    "status=0 siblings=[card-1]"*) fail "the fixture did not make the backlog unreadable: $out" ;;
    "status=2 "*) ;;
    *) fail "an unreadable backlog did not report cannot-tell: $out" ;;
  esac
  assert_contains "$out" "siblings=[]" "a cannot-tell read still published a sibling set"
  assert_contains "$out" "error=set" "a cannot-tell read named no reason"
  pass "an unreadable backlog is cannot-tell, never an empty sibling set"
}

test_a_joined_member_closes_with_its_unit() {
  local home out
  home=$(make_home join-closes)
  add_item "$home" unit-a app-web
  add_item "$home" card-1 app-web
  fm "$home" group unit-a blu-3156 >/dev/null
  fm "$home" group card-1 blu-3156 >/dev/null
  fm "$home" start unit-a >/dev/null || fail "could not move the unit In flight"
  write_record "$home" unit-a
  out=$(fm "$home" join unit-a card-1) || fail "join failed: $out"
  assert_contains "$out" "delivers card-1" "join did not report the new membership"
  assert_contains "$(cat "$home/state/unit-a.meta")" "delivers=card-1" \
    "join did not record the member"
  [ "$(fm "$home" show card-1 | sed -n 's/^  state: //p')" = in_flight ] \
    || fail "join left the member's row behind"
  assert_contains "$(fm "$home" join unit-a card-1)" "already delivers" \
    "a repeated join was not a no-op"
  pass "join records a newly ready sibling on the live unit and moves its row"
}

test_join_refuses_an_unrelated_item() {
  local home out rc before
  home=$(make_home join-unrelated)
  add_item "$home" unit-a app-web
  add_item "$home" other-1 infra
  add_item "$home" card-2 app-web
  fm "$home" group unit-a blu-3156 >/dev/null
  fm "$home" group other-1 blu-3156 >/dev/null
  fm "$home" group card-2 hel-99 >/dev/null
  fm "$home" start unit-a >/dev/null
  write_record "$home" unit-a
  before=$(cat "$home/state/unit-a.meta")
  set +e
  out=$(fm "$home" join unit-a other-1 2>&1); rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "join accepted an item from another repository"
  assert_contains "$out" "not this job's sibling" "the refusal did not say why"
  set +e
  out=$(fm "$home" join unit-a card-2 2>&1); rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "join accepted an item carrying another key"
  [ "$(cat "$home/state/unit-a.meta")" = "$before" ] || fail "a refused join changed the record"
  [ "$(fm "$home" show other-1 | sed -n 's/^  state: //p')" = queued ] \
    || fail "a refused join moved the item's row"
  pass "join refuses an item that is not the unit's sibling, and changes nothing"
}

test_join_refuses_a_unit_with_a_pending_close() {
  local home out rc
  home=$(make_home join-pending-close)
  add_item "$home" unit-a app-web
  add_item "$home" card-1 app-web
  fm "$home" group unit-a blu-3156 >/dev/null
  fm "$home" group card-1 blu-3156 >/dev/null
  fm "$home" start unit-a >/dev/null
  write_record "$home" unit-a
  printf 'id=unit-a\n' > "$home/state/unit-a.backlog-close"
  set +e
  out=$(fm "$home" join unit-a card-1 2>&1); rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "join accepted a unit whose close is already being replayed"
  assert_contains "$out" "pending backlog close" "the refusal did not name the pending close"
  assert_not_contains "$(cat "$home/state/unit-a.meta")" "delivers=" "the refused join still recorded a member"
  pass "join refuses a unit with a pending backlog close"
}

test_an_interrupted_join_leaves_a_visible_orphan_not_a_silent_member() {
  local home out rc
  home=$(make_home join-interrupted)
  add_item "$home" unit-a app-web
  add_item "$home" card-1 app-web
  fm "$home" group unit-a blu-3156 >/dev/null
  fm "$home" group card-1 blu-3156 >/dev/null
  fm "$home" start unit-a >/dev/null
  write_record "$home" unit-a
  # The interruption this order exists to survive: the row moved, the record
  # did not. The member is then In flight and named by no record, which is what
  # the fleet snapshot reports as an orphan rather than closing silently.
  fm "$home" start card-1 >/dev/null || fail "fixture: could not move the row"
  assert_not_contains "$(cat "$home/state/unit-a.meta")" "delivers=" \
    "fixture: the record already names the member"
  out=$(fm "$home" join unit-a card-1) || fail "the re-run did not converge: $out"
  assert_contains "$(cat "$home/state/unit-a.meta")" "delivers=card-1" \
    "the re-run did not finish the interrupted join"

  # The order itself: when the row cannot move, nothing is recorded. Recording
  # first would leave a member named for a close while its row still reads as
  # ready work - the failure the order exists to prevent.
  home=$(make_home join-order)
  add_item "$home" unit-a app-web
  add_item "$home" card-1 app-web
  fm "$home" group unit-a blu-3156 >/dev/null
  fm "$home" group card-1 blu-3156 >/dev/null
  fm "$home" start unit-a >/dev/null
  write_record "$home" unit-a
  chmod 500 "$home/data"
  set +e
  out=$(fm "$home" join unit-a card-1 2>&1)
  rc=$?
  set -e
  chmod 700 "$home/data"
  [ "$rc" -ne 0 ] || fail "a join whose row could not move reported success: $out"
  assert_not_contains "$(cat "$home/state/unit-a.meta")" "delivers=" \
    "the record named a member although its row never moved"
  [ "$(fm "$home" show card-1 | sed -n 's/^  state: //p')" = queued ] \
    || fail "the refused join moved the row after all"
  pass "an interrupted join converges on a re-run, and never records a member before its row moves"
}

test_a_malformed_grouping_posture_is_refused_not_defaulted
test_grouping_is_inert_when_unconfigured
if [ "$HAVE_TASKS_AXI" = 1 ]; then
  test_group_key_survives_hold_and_handback_body_rewrites
  test_group_set_preserves_the_rest_of_the_body
  test_a_repeated_group_line_is_refused
  test_a_chunk_reads_as_one_ready_item
  test_chunk_refuses_a_cross_repo_member_before_any_write
  test_chunk_is_idempotent
  test_chunk_warns_above_the_member_cap_and_never_refuses
  test_siblings_never_cross_a_repository
  test_live_siblings_come_from_worker_records
  test_an_unreadable_backlog_is_not_an_empty_sibling_set
  test_a_joined_member_closes_with_its_unit
  test_join_refuses_an_unrelated_item
  test_join_refuses_a_unit_with_a_pending_close
  test_an_interrupted_join_leaves_a_visible_orphan_not_a_silent_member
else
  echo "skip: tasks-axi not found; the backlog grouping cases were not run"
fi
