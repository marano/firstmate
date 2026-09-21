#!/usr/bin/env bash
# Behavioral tests for bin/fm-ask.sh, the guards behind the captain-invoked /ask
# skill: it refuses in the away posture, says plainly when nothing is open,
# spends one picker call per invocation and refuses the second, batches the
# calls that fit into that single call, refuses to present again while an
# earlier answer is unrecorded, never presents a decision that is firstmate's
# own, keeps the picker behind every queued wake, and leaves the plain-text
# default path untouched when /ask is never invoked.
#
# The one-picker-call rule has two halves that fail for different reasons, so
# each has its own regression here: the skill's declared contract is what the
# agent reads, and this script's refusal is what holds when the agent forgets.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ASK="$ROOT/bin/fm-ask.sh"
SKILL="$ROOT/.agents/skills/ask/SKILL.md"
TMP_ROOT=$(fm_test_tmproot fm-ask)
TASKS_AXI_BIN=$(command -v tasks-axi || true)

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
command -v tasks-axi >/dev/null 2>&1 || { echo "skip: tasks-axi not found"; exit 0; }

make_home() {  # <name>
  local home="$TMP_ROOT/$1" fakebin
  mkdir -p "$home/data" "$home/state" "$home/config" "$home/projects"
  cp "$ROOT/.tasks.toml" "$home/.tasks.toml"
  printf '## In flight\n\n## Queued\n\n## Done\n' > "$home/data/backlog.md"
  fakebin=$(fm_fakebin "$home")
  fm_fake_exit0 "$fakebin" tmux treehouse no-mistakes gh gh-axi
  printf '%s\n' "$home"
}

in_home() {  # <home> <command...>
  local home=$1
  shift
  PATH="$home/fakebin:$PATH" REAL_TASKS_AXI="$TASKS_AXI_BIN" \
    FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DATA_OVERRIDE="$home/data" FM_CONFIG_OVERRIDE="$home/config" "$@"
}

ask() {  # <home> <args...>
  local home=$1
  shift
  in_home "$home" "$ASK" "$@"
}

hold_call() {  # <home> <id> <title>
  in_home "$1" "$ROOT/bin/fm-captain-hold.sh" hold "$2" --title "$3" \
    --repo sample --reason "captain choice pending" >/dev/null \
    || fail "could not hold captain call $2"
}

answer_call() {  # <home> <id> <words>
  printf '%s\n' "$3" > "$1/answer-$2.txt"
  in_home "$1" "$ROOT/bin/fm-captain-hold.sh" answer "$2" \
    --decision-file "$1/answer-$2.txt" >/dev/null \
    || fail "could not record the captain's answer to $2"
}

queue_wake() {  # <home> <kind> <key>
  # shellcheck disable=SC2016 # Expanded by the inner shell, not here.
  in_home "$1" bash -c '. "$FM_ROOT_OVERRIDE/bin/fm-wake-lib.sh" && fm_wake_append "$1" "$2" "fixture wake"' \
    _ "$2" "$3" || fail "could not queue a $2 wake"
}

test_refuses_while_away_record_exists() {
  local home rc
  home=$(make_home away)
  hold_call "$home" sample-route "Choose route"
  in_home "$home" "$ROOT/bin/fm-afk-contract.sh" propose --words "back tomorrow" >/dev/null \
    || fail "could not propose the away record"
  in_home "$home" "$ROOT/bin/fm-afk-contract.sh" confirm >/dev/null \
    || fail "could not confirm the away record"

  ask "$home" inventory > "$home/inv.out" 2> "$home/inv.err"
  rc=$?
  expect_code 3 "$rc" "inventory while the away record exists"
  assert_grep "holds decisions for the captain's return" "$home/inv.err" \
    "the away refusal must say decisions are held for his return"
  assert_no_grep "sample-route" "$home/inv.out" "a refused inventory listed a call anyway"

  ask "$home" present sample-route > "$home/present.out" 2> "$home/present.err"
  rc=$?
  expect_code 3 "$rc" "present while the away record exists"
  assert_absent "$home/state/.ask-presented" "a refused presentation was recorded as presented"

  # The daemon flag alone is the same posture to the away-return owner.
  mv "$home/state/.afk-contract" "$home/away-record"
  printf 'away\n' > "$home/state/.afk"
  ask "$home" present sample-route >/dev/null 2>&1
  expect_code 3 "$?" "present while the away flag exists"
  assert_absent "$home/state/.ask-presented" "a refused presentation was recorded as presented"
  rm -f "$home/state/.afk"
  ask "$home" round-start >/dev/null || fail "the round could not start after the away posture ended"
  ask "$home" present sample-route >/dev/null 2> "$home/back.err" \
    || fail "the call could not be presented after the away posture ended: $(cat "$home/back.err")"
  pass "refuses while the away record exists"
}

test_empty_inventory_says_so_plainly() {
  local home out rc
  home=$(make_home empty)
  out=$(ask "$home" inventory 2>&1)
  rc=$?
  expect_code 0 "$rc" "inventory with nothing open"
  assert_equals "No open captain decisions." "$out" "an empty inventory must say so in one plain line and nothing else"
  ask "$home" round-start >/dev/null
  ask "$home" present anything > /dev/null 2>&1
  expect_code 6 "$?" "presenting from an empty inventory"
  assert_absent "$home/state/.ask-presented" "an empty inventory recorded a presentation"
  pass "presents nothing and says so plainly when the inventory is empty"
}

# The skill's text is what the agent acts on, so the contract it declares to the
# agent must say one picker call per invocation, and must be the number this
# script actually enforces. Reds if the skill is rewritten to permit a second.
test_skill_contract_permits_one_picker_call_per_invocation() {
  local home contract declared_calls declared_max ids i
  home=$(make_home skill-contract)
  contract="$home/contract.json"
  awk '
    /^```json ask-presentation-contract-v1$/ { capture = 1; next }
    capture && /^```$/ { exit }
    capture { print }
  ' "$SKILL" > "$contract"
  [ -s "$contract" ] || fail "the ask skill declares no ask-presentation-contract-v1 block"
  jq -e '.' "$contract" >/dev/null 2>&1 || fail "the ask skill's presentation contract is not valid JSON"

  declared_calls=$(jq -r '.picker_calls_per_invocation' "$contract")
  assert_equals "1" "$declared_calls" \
    "the ask skill must declare exactly one picker call per invocation; a second one wedges supervision"
  declared_max=$(jq -r '.questions_per_picker_call_max' "$contract")
  case "$declared_max" in
    ''|*[!0-9]*|0) fail "the ask skill must declare a positive question cap, got '$declared_max'" ;;
  esac

  # The script must enforce the same two numbers, or the agent's contract and
  # the guard behind it have drifted.
  ids=
  for ((i = 1; i <= declared_max + 1; i++)); do
    hold_call "$home" "sample-$i" "Choose $i"
    ids="${ids:+$ids }sample-$i"
  done
  ask "$home" round-start >/dev/null
  # shellcheck disable=SC2086 # One id per presented call, deliberately split.
  ask "$home" present $ids >/dev/null 2> "$home/over.err"
  expect_code 8 "$?" "presenting one more call than the skill's declared cap"
  assert_grep "at most $declared_max" "$home/over.err" \
    "the refusal must name the same cap the skill declares"

  ids=${ids% sample-$((declared_max + 1))}
  # shellcheck disable=SC2086 # One id per presented call, deliberately split.
  ask "$home" present $ids >/dev/null 2> "$home/fit.err" \
    || fail "the skill's declared cap did not fit in one picker call: $(cat "$home/fit.err")"
  ask "$home" present "sample-$((declared_max + 1))" >/dev/null 2>&1
  expect_code 7 "$?" \
    "the script allowed picker call number 2 while the skill declares $declared_calls per invocation"
  pass "the skill declares one picker call per invocation and the script enforces it"
}

# The script's own half: once this invocation has opened its picker call,
# nothing short of a new invocation opens another - not recording every answer,
# and not a dismissal. Reds if the present-and-open cycle can run twice.
test_second_present_and_open_cycle_refused() {
  local home rc
  home=$(make_home one-cycle)
  hold_call "$home" sample-route "Choose route"
  hold_call "$home" sample-cache "Choose cache"
  hold_call "$home" sample-name "Choose name"

  ask "$home" round-start >/dev/null || fail "the invocation's round could not start"
  ask "$home" present sample-route >/dev/null || fail "the first picker call could not be presented"
  assert_present "$home/state/.ask-round" "opening the picker did not spend the invocation's round"

  # Recording the answer is exactly what the old loop did next; it must not
  # buy a second call.
  answer_call "$home" sample-route "North."
  ask "$home" present sample-cache > "$home/second.out" 2> "$home/second.err"
  rc=$?
  expect_code 7 "$rc" "opening a second picker call after recording the first answer"
  assert_grep "one picker call is gone" "$home/second.err" \
    "the refusal must say this invocation's picker call is spent"
  assert_grep "plain text" "$home/second.err" \
    "the refusal must route the rest to plain text"
  assert_grep "/ask again" "$home/second.err" \
    "the refusal must say the captain can type /ask again for another round"
  assert_no_grep "sample-cache" "$home/state/.ask-presented" \
    "a refused second picker call was recorded as presented"

  # A dismissed picker does not earn another one either.
  ask "$home" dismissed sample-route >/dev/null 2>&1
  ask "$home" present sample-cache >/dev/null 2>&1
  expect_code 7 "$?" "opening a second picker call after dismissing the first"

  # Only a new invocation, which starts its own round, opens another.
  ask "$home" round-start >/dev/null || fail "the next invocation's round could not start"
  ask "$home" present sample-cache >/dev/null 2> "$home/next.err" \
    || fail "a new invocation could not open its own picker call: $(cat "$home/next.err")"
  pass "one invocation spends one picker call and the second is refused"
}

# The finding's exact trace: a read-only inventory after the answers are
# recorded must not reopen the round. Reds if inventory clears or recreates it.
test_inventory_after_recorded_answers_does_not_reopen_the_round() {
  local home
  home=$(make_home inventory-readonly)
  hold_call "$home" sample-route "Choose route"
  hold_call "$home" sample-cache "Choose cache"
  hold_call "$home" sample-name "Choose name"

  ask "$home" present sample-name >/dev/null 2> "$home/unstarted.err"
  expect_code 9 "$?" "presenting before any round was started"
  ask "$home" inventory >/dev/null
  ask "$home" present sample-name >/dev/null 2>&1
  expect_code 9 "$?" "an inventory must not start a round"

  ask "$home" round-start >/dev/null || fail "could not start the round"
  ask "$home" present sample-route sample-cache >/dev/null || fail "the one picker call could not be presented"
  answer_call "$home" sample-route "North."
  answer_call "$home" sample-cache "East."
  ask "$home" inventory > "$home/inv.out" 2>&1 || fail "inventory failed: $(cat "$home/inv.out")"
  assert_no_grep "present again" "$home/inv.out" "the inventory must never suggest presenting again"
  assert_no_grep "before presenting" "$home/inv.out" "the inventory must never suggest presenting"
  ask "$home" present sample-name >/dev/null 2>&1
  expect_code 7 "$?" "presenting a third call after an inventory that followed the recorded answers"
  pass "an inventory after recorded answers does not reopen the round"
}

# The rule the captain restated: several calls go into ONE picker call
# together. Batching is required, and must never be mistaken for a second call.
test_calls_are_batched_into_one_picker_call() {
  local home
  home=$(make_home batched)
  hold_call "$home" sample-route "Choose route"
  hold_call "$home" sample-cache "Choose cache"
  hold_call "$home" sample-name "Choose name"

  ask "$home" round-start >/dev/null || fail "could not start the round"
  ask "$home" present sample-route sample-cache sample-name > "$home/batch.out" 2> "$home/batch.err" \
    || fail "several calls could not be presented together: $(cat "$home/batch.err")"
  assert_grep "sample-route sample-cache sample-name" "$home/batch.out" \
    "the batched presentation must name every call it recorded"
  assert_grep "sample-route" "$home/state/.ask-presented" "the first batched call was not recorded"
  assert_grep "sample-name" "$home/state/.ask-presented" "the last batched call was not recorded"

  ask "$home" inventory > "$home/inv.out" 2>&1
  assert_grep "PRESENTED AND NOT YET RECORDED: sample-route sample-cache sample-name" "$home/inv.out" \
    "the inventory must surface every unrecorded call from the batch"

  # A dismissal clears exactly the calls it names, out of the whole batch.
  ask "$home" dismissed sample-route sample-name >/dev/null \
    || fail "could not dismiss two calls of the batch"
  assert_grep "sample-cache" "$home/state/.ask-presented" \
    "dismissing two of three calls dropped the one still outstanding"
  assert_no_grep "sample-route" "$home/state/.ask-presented" \
    "a dismissed call stayed outstanding"
  ask "$home" dismissed sample-route >/dev/null 2>&1
  expect_code 2 "$?" "dismissing a call that is no longer outstanding"

  # Asking one decision twice in a single call is a mistake, not a batch.
  ask "$home" round-start >/dev/null
  ask "$home" present sample-route sample-route >/dev/null 2> "$home/dup.err"
  expect_code 2 "$?" "naming the same call twice in one picker call"
  assert_grep "named twice" "$home/dup.err" "the refusal must say the call was named twice"
  pass "several calls are presented together as one picker call"
}

test_unrecorded_batch_blocks_the_next_invocation() {
  local home rc
  home=$(make_home record-first)
  hold_call "$home" sample-route "Choose route"
  hold_call "$home" sample-cache "Choose cache"
  hold_call "$home" sample-name "Choose name"

  ask "$home" round-start >/dev/null
  ask "$home" present sample-route >/dev/null || fail "the first live call could not be presented"
  ask "$home" round-start >/dev/null || fail "the next invocation's round could not start"
  ask "$home" present sample-cache > "$home/next.out" 2> "$home/next.err"
  rc=$?
  expect_code 5 "$rc" "presenting again before the earlier answer is recorded"
  assert_grep "sample-route" "$home/next.err" "the refusal must name the unrecorded call"
  ask "$home" inventory > "$home/inv.out" 2>&1
  assert_grep "PRESENTED AND NOT YET RECORDED: sample-route" "$home/inv.out" \
    "the inventory must surface the unrecorded presentation"

  answer_call "$home" sample-route "North."
  ask "$home" present sample-cache >/dev/null 2> "$home/after.err" \
    || fail "a recorded answer did not free the next invocation: $(cat "$home/after.err")"

  # "Later" is an answer: a dated re-hold takes the call out of the live set.
  in_home "$home" "$ROOT/bin/fm-captain-hold.sh" hold sample-cache \
    --reason "captain said later" --until 2099-01-01 >/dev/null \
    || fail "could not defer the call"
  ask "$home" round-start >/dev/null
  ask "$home" present sample-name >/dev/null 2>&1 || fail "a deferred call still blocked the next invocation"

  # A dismissed picker frees the slot only through the explicit record.
  ask "$home" round-start >/dev/null
  ask "$home" present sample-cache >/dev/null 2>&1
  expect_code 6 "$?" "presenting a call the captain deferred"
  hold_call "$home" sample-last "Choose last"
  ask "$home" round-start >/dev/null
  ask "$home" present sample-last >/dev/null 2>&1
  expect_code 5 "$?" "presenting past an unanswered, undismissed call"
  ask "$home" dismissed sample-name >/dev/null || fail "could not record a dismissed picker"
  ask "$home" round-start >/dev/null
  ask "$home" present sample-last >/dev/null 2>&1 || fail "a dismissed presentation still blocked the next invocation"
  pass "an unrecorded answer is recorded before anything is presented again"
}

test_firstmate_own_decision_never_presented() {
  local home rc
  home=$(make_home own-decision)
  printf 'needs-decision [key=nm-7-review]: ask-user findings=f1\n' > "$home/state/worker-a.status"
  printf 'needs-decision [key=sample-scope]: widen the scope?\n' > "$home/state/worker-b.status"
  hold_call "$home" sample-scope "Widen the sample scope"

  ask "$home" inventory > "$home/inv.out" 2>&1 || fail "inventory failed: $(cat "$home/inv.out")"
  assert_grep "WAITING ON FIRSTMATE, NOT THE CAPTAIN" "$home/inv.out" \
    "the worker's own decision was not separated from captain calls"
  assert_grep "worker-a [key=nm-7-review]" "$home/inv.out" "the worker's own decision is missing"
  assert_no_grep "worker-b [key=sample-scope]" "$home/inv.out" \
    "an escalated worker decision was listed twice, once as firstmate's own"
  sed -n '/^CAPTAIN CALLS/,/^WAITING/p' "$home/inv.out" > "$home/calls.out"
  assert_grep "sample-scope" "$home/calls.out" "the escalated call is not listed as a captain call"
  assert_no_grep "nm-7-review" "$home/calls.out" "firstmate's own decision was listed as a captain call"

  ask "$home" round-start >/dev/null
  ask "$home" present nm-7-review > "$home/present.out" 2> "$home/present.err"
  rc=$?
  expect_code 6 "$rc" "presenting a decision that is firstmate's own"
  assert_absent "$home/state/.ask-presented" "firstmate's own decision was recorded as presented"
  pass "a decision that is firstmate's own is never presented"
}

test_queued_wakes_block_the_picker() {
  local home rc
  home=$(make_home queued)
  hold_call "$home" sample-route "Choose route"
  queue_wake "$home" signal worker-a

  ask "$home" round-start >/dev/null
  ask "$home" present sample-route > "$home/present.out" 2> "$home/present.err"
  rc=$?
  expect_code 4 "$rc" "presenting while a wake is queued"
  assert_absent "$home/state/.ask-presented" "a presentation was recorded ahead of queued work"
  ask "$home" inventory > "$home/inv.out" 2>&1
  assert_grep "QUEUED WAKES: 1 unhandled" "$home/inv.out" "the inventory must report the queued wake"

  : > "$home/state/.wake-queue"
  ask "$home" present sample-route >/dev/null 2>&1 || fail "an empty queue still blocked the picker"
  pass "every queued wake is handled before the picker opens"
}

# Must stay green: /ask is an opt-in, never the default. With captain calls and a
# worker decision open, the ordinary surfaces keep directing a plain answer and
# a captain call still closes through its owner with no /ask record created.
test_plain_text_default_unaffected_without_ask() {
  local home drain bearings
  home=$(make_home default-path)
  hold_call "$home" sample-route "Choose route"
  printf 'needs-decision [key=nm-3-review]: ask-user findings=f2\n' > "$home/state/worker-c.status"

  drain=$(in_home "$home" "$ROOT/bin/fm-wake-drain.sh" 2>/dev/null)
  bearings=$(in_home "$home" "$ROOT/bin/fm-bearings-snapshot.sh" 2>/dev/null)
  # shellcheck disable=SC2016 # Literal command text in the drain's output.
  assert_contains "$drain" "bin/fm-send.sh <task> --resolve-key <key> '<answer>'" \
    "the drain no longer directs a plain answer for an open decision"
  assert_contains "$bearings" "sample-route" "Bearings no longer lists the captain call"
  assert_not_contains "$drain$bearings" "fm-ask.sh" "a default surface routes decisions through /ask"
  assert_not_contains "$drain$bearings" "/ask" "a default surface routes decisions through /ask"

  answer_call "$home" sample-route "South."
  assert_absent "$home/state/.ask-presented" "the plain path created an /ask presentation record"
  pass "the plain-text default is unaffected when /ask is not invoked"
}

test_refuses_while_away_record_exists
test_empty_inventory_says_so_plainly
test_skill_contract_permits_one_picker_call_per_invocation
test_second_present_and_open_cycle_refused
test_inventory_after_recorded_answers_does_not_reopen_the_round
test_calls_are_batched_into_one_picker_call
test_unrecorded_batch_blocks_the_next_invocation
test_firstmate_own_decision_never_presented
test_queued_wakes_block_the_picker
test_plain_text_default_unaffected_without_ask
