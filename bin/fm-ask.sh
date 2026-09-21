#!/usr/bin/env bash
# fm-ask.sh - deterministic guards behind the captain-invoked /ask skill.
#
# /ask is the captain's OPT-IN to having his open decisions presented through
# the interactive question picker instead of plain text. Opening that picker
# ends the supervisor's turn and halts supervision of the whole fleet until he
# answers, which is why plain text stays the standing default. Opening a
# SECOND picker call in one invocation is worse than that pause: the captain
# reports it wedges the supervisor so it stops processing messages at all.
# So an /ask invocation buys exactly ONE picker call, holding up to four
# questions, and this script refuses the second one rather than trusting the
# agent to remember. .agents/skills/ask/SKILL.md owns the policy and the
# presentation; this script owns only the mechanical checks, and it never
# reads chat, reports, or prose to decide what is a captain call.
#
# Usage:
#   fm-ask.sh round-start
#     Open this invocation's round. Run it exactly once per captain /ask, first,
#     before the posture check. It is the only thing that creates the round and
#     nothing else clears it; without it `present` refuses.
#   fm-ask.sh inventory
#     Print the live captain calls that may be presented, the open worker
#     decisions that are firstmate's own and must never be presented, any
#     earlier presentation whose answer is not yet recorded, and the count of
#     queued wake records still unhandled. With no live captain call the first
#     line is exactly "No open captain decisions."
#   fm-ask.sh present <task-id>...
#     Check that every <task-id> may be presented now, then record them as the
#     one outstanding presentation and spend this invocation's round. Run it
#     once, immediately before opening the picker, naming every call that goes
#     into that single picker call.
#   fm-ask.sh dismissed <task-id>...
#     Clear the outstanding presentation of each <task-id> when the captain
#     closed the picker without giving any answer. An answer, including
#     "later", is recorded through bin/fm-captain-hold.sh instead, never
#     through this. Dismissing does not earn another picker call.
#
# SOURCES. A captain call is a task held for the captain and nothing else
# (.agents/skills/captain-hold-lifecycle/SKILL.md). The live set is the
# canonical Captain's Call projection, `fm-bearings-snapshot.sh --json`
# decisions_open rows with verb captain-hold, so a call the captain deferred
# with --until, or one gated on other work, is not live and is not presented.
# Open worker decisions come from fm-classify-lib.sh's scan_open_decisions, the
# same fold behind the wake drain's OPEN DECISIONS section; one whose key names
# a live captain call has already been escalated and is listed only once, as
# that call.
#
# REFUSALS. Every subcommand refuses in the away posture; `present` adds the
# rest, in this order:
#   9  no round was started: `round-start` has not run for this invocation.
#   3  away posture: bin/fm-afk-return.sh guard refuses, because the away or
#      quiet record exists or the return catch-up has not cleared. Away mode
#      holds decisions for the captain's return by design, and a picker there
#      would stop that supervision too.
#   7  this invocation's one picker call is gone. Recording the answers or
#      dismissing the picker does not buy another: whatever is left goes to
#      the captain in plain text, and he types /ask again when he wants
#      another round.
#   4  queued wake records are unhandled. The picker is the last act of the
#      turn, so everything that does not need the captain happens first:
#      handle and acknowledge the queue, then ask.
#   8  more than MAX_QUESTIONS calls in one `present`. They would not fit in
#      one picker call, and a second call is what must never happen.
#   6  a <task-id> is not a live captain call: firstmate's own decision, an
#      already closed or deferred call, or an unknown id.
#   5  an earlier invocation's presentation is still a live captain call: its
#      answer has not been recorded. Record it before presenting again, or it
#      will be asked twice.
#   2  usage error, a repeated <task-id>, or the captain-call projection could
#      not be read.
#
# RECORD. state/.ask-presented holds the outstanding presented task ids, one
# per line; `present` writes them and `dismissed` removes them. A presentation
# counts as recorded once its task has left the live captain calls, whichever
# owning path closed, released, or deferred it.
#
# ROUND. state/.ask-round is created only by `round-start`, empty, and
# `present` spends it by writing the presented ids into it. It outlives both the
# recorded answers and a dismissal, so neither reopens the picker, and no other
# subcommand creates or clears it: `inventory` is strictly read-only with
# respect to it. This does NOT make a second picker call physically impossible:
# an agent that calls `round-start` twice still gets two. What it buys is a
# smaller discipline surface: instead of "call inventory exactly once, in a
# workflow whose own output invites calling it again", the rule is "call
# round-start once at the top, where nothing suggests otherwise". The skill owns
# the rule that only the captain typing /ask starts a round; a follow-up, a
# complication, or a re-ask reaches him in plain text instead.
#
# Environment: FM_HOME, FM_STATE_OVERRIDE, and FM_DATA_OVERRIDE select the home,
# exactly as for bin/fm-captain-hold.sh.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"

PRESENTED="$STATE/.ask-presented"
ROUND="$STATE/.ask-round"
# The picker holds at most this many questions in one call, and one call is all
# an /ask invocation gets. The skill declares the same two numbers in its
# ask-presentation-contract-v1 block, and tests/fm-ask.test.sh holds both sides
# to each other so the agent's contract and this enforcement cannot drift.
MAX_QUESTIONS=4

usage() {
  sed -n '/^# Usage:/,/^# SOURCES\./p' "$0" | sed '$d; s/^# \{0,1\}//'
}

# bin/fm-afk-return.sh `guard` owns whether the away posture still holds,
# including a return whose catch-up has not cleared; its message is relayed.
refuse_if_away() {
  local err
  err=$("$SCRIPT_DIR/fm-afk-return.sh" guard 2>&1 >/dev/null) && return 0
  printf '%s\n' "fm-ask: refused - away mode holds decisions for the captain's return, and opening the picker now would also stop supervision until he answers." >&2
  [ -z "$err" ] || printf '%s\n' "$err" >&2
  exit 3
}

valid_id() {
  case "$1" in ''|*[!A-Za-z0-9._/-]*) return 1 ;; esac
}

# One "<id>\t<owner>\t<summary>" line per live captain call.
live_calls() {
  local json
  json=$(FM_BEARINGS_DECISIONS=100000 "$SCRIPT_DIR/fm-bearings-snapshot.sh" --json 2>/dev/null) || return 1
  printf '%s\n' "$json" | jq -r '
    .decisions_open[]? | select(.verb == "captain-hold")
    | [.id, .owner, (.summary // "" | gsub("[\t\r\n]"; " "))] | @tsv'
}

is_live() {  # <calls> <id>
  printf '%s\n' "$1" | awk -F '\t' -v id="$2" '$1 == id { found = 1 } END { exit !found }'
}

queued_wakes() {
  local kind count=0 keys
  for kind in signal stale check heartbeat; do
    keys=$(fm_wake_queued_keys "$kind") || return 1
    [ -z "$keys" ] || count=$((count + $(printf '%s\n' "$keys" | wc -l)))
  done
  printf '%s\n' "$count"
}

# Every id recorded by the last `present`, one per line.
outstanding() {
  [ -f "$PRESENTED" ] || return 0
  cat "$PRESENTED"
}

# The outstanding ids that are still live captain calls, space separated.
unrecorded() {  # <calls>
  local id out=
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    is_live "$1" "$id" && out="${out:+$out }$id"
  done <<EOF
$(outstanding)
EOF
  printf '%s\n' "$out"
}

contains_id() {  # <id> <candidate>...
  local want=$1 got
  shift
  for got in "$@"; do [ "$got" = "$want" ] && return 0; done
  return 1
}

read_calls_or_fail() {
  CALLS=$(live_calls) || {
    printf '%s\n' "fm-ask: the captain-call projection (bin/fm-bearings-snapshot.sh --json) could not be read" >&2
    exit 2
  }
}

command_inventory() {
  local own task key verb note prior queued
  [ "$#" -eq 0 ] || { usage >&2; exit 2; }
  refuse_if_away
  read_calls_or_fail
  own=
  while IFS=$'\t' read -r task key verb note; do
    [ -n "$task" ] || continue
    is_live "$CALLS" "$key" && continue
    is_live "$CALLS" "$task-decision-$key" && continue
    own="$own  $task [key=$key] $verb: $note"$'\n'
  done <<EOF
$(scan_open_decisions "$STATE")
EOF

  if [ -z "$CALLS" ]; then
    printf '%s\n' "No open captain decisions."
  else
    printf '%s\n' "CAPTAIN CALLS (live):"
    printf '%s\n' "$CALLS" | awk -F '\t' '{ printf "  %s [%s]: %s\n", $1, $2, $3 }'
  fi
  if [ -n "$own" ]; then
    printf '%s\n' "WAITING ON FIRSTMATE, NOT THE CAPTAIN (decide or escalate under ask-user-authority; never present these as they stand):"
    printf '%s' "$own"
  fi
  prior=$(unrecorded "$CALLS")
  if [ -n "$prior" ]; then
    printf '%s\n' "PRESENTED AND NOT YET RECORDED: $prior - record his answers through their owner, or run 'bin/fm-ask.sh dismissed $prior' if he gave none."
  fi
  queued=$(queued_wakes) || queued='unknown'
  if [ "$queued" != 0 ]; then
    printf '%s\n' "QUEUED WAKES: $queued unhandled - handle and acknowledge them first."
  fi
}

# " (<ids>)" naming the round already opened, empty when it recorded nothing.
round_ids_suffix() {
  local ids
  [ -f "$ROUND" ] || return 0
  ids=$(tr '\n' ' ' < "$ROUND")
  ids=${ids% }
  [ -z "$ids" ] || printf ' (%s)' "$ids"
}

command_round_start() {
  [ "$#" -eq 0 ] || { usage >&2; exit 2; }
  refuse_if_away
  if ! : > "$ROUND.tmp.$$" || ! mv "$ROUND.tmp.$$" "$ROUND"; then
    rm -f "$ROUND.tmp.$$"
    printf '%s\n' "fm-ask: could not start the round" >&2
    exit 2
  fi
  printf '%s\n' "round started: one picker call this invocation"
}

command_present() {
  local id prior queued seen=()
  [ "$#" -ge 1 ] || { usage >&2; exit 2; }
  for id in "$@"; do
    valid_id "$id" || { usage >&2; exit 2; }
    if contains_id "$id" ${seen[@]+"${seen[@]}"}; then
      printf '%s\n' "fm-ask: $id was named twice; one picker call asks each decision once." >&2
      exit 2
    fi
    seen+=("$id")
  done
  refuse_if_away
  if [ ! -e "$ROUND" ]; then
    printf '%s\n' "fm-ask: refused - no round was started for this /ask invocation; run 'bin/fm-ask.sh round-start' once at the top of the invocation." >&2
    exit 9
  fi
  if [ -s "$ROUND" ]; then
    printf '%s\n' "fm-ask: refused - this /ask invocation's one picker call is gone$(round_ids_suffix); a second one wedges supervision. Give him the rest in plain text this turn and say he can type /ask again for another round." >&2
    exit 7
  fi
  queued=$(queued_wakes) || queued='unknown'
  if [ "$queued" != 0 ]; then
    printf '%s\n' "fm-ask: refused - $queued queued wake record(s) are unhandled; the picker ends the turn, so handle and acknowledge them first." >&2
    exit 4
  fi
  if [ "$#" -gt "$MAX_QUESTIONS" ]; then
    printf '%s\n' "fm-ask: refused - $# calls named but one picker call holds at most $MAX_QUESTIONS; present the $MAX_QUESTIONS most impactful and give him the rest in plain text this turn." >&2
    exit 8
  fi
  read_calls_or_fail
  for id in "$@"; do
    if ! is_live "$CALLS" "$id"; then
      printf '%s\n' "fm-ask: refused - $id is not a live captain call; a decision that is firstmate's own is decided, not asked, and a closed or deferred call is not asked again." >&2
      exit 6
    fi
  done
  for prior in $(unrecorded "$CALLS"); do
    contains_id "$prior" "$@" && continue
    printf '%s\n' "fm-ask: refused - $prior was presented and its answer is not recorded yet; record it before presenting $*, or run 'bin/fm-ask.sh dismissed $prior' if he gave none." >&2
    exit 5
  done
  # The round is spent first, so a half-written record refuses the next
  # picker call rather than letting a retry open one.
  if ! {
    printf '%s\n' "$@" > "$ROUND.tmp.$$" && mv "$ROUND.tmp.$$" "$ROUND" &&
      printf '%s\n' "$@" > "$PRESENTED.tmp.$$" && mv "$PRESENTED.tmp.$$" "$PRESENTED"
  }; then
    rm -f "$PRESENTED.tmp.$$" "$ROUND.tmp.$$"
    printf '%s\n' "fm-ask: could not record the presentation of $*" >&2
    exit 2
  fi
  printf 'presented: %s\n' "$*"
}

command_dismissed() {
  local id keep kept=() remaining=()
  [ "$#" -ge 1 ] || { usage >&2; exit 2; }
  for id in "$@"; do valid_id "$id" || { usage >&2; exit 2; }; done
  refuse_if_away
  while IFS= read -r keep; do
    [ -n "$keep" ] && kept+=("$keep")
  done <<EOF
$(outstanding)
EOF
  for id in "$@"; do
    contains_id "$id" ${kept[@]+"${kept[@]}"} && continue
    if [ "${#kept[@]}" -gt 0 ]; then
      printf '%s\n' "fm-ask: $id is not an outstanding presentation; these are: ${kept[*]}" >&2
    else
      printf '%s\n' "fm-ask: $id is not an outstanding presentation; nothing is outstanding" >&2
    fi
    exit 2
  done
  for keep in ${kept[@]+"${kept[@]}"}; do
    contains_id "$keep" "$@" || remaining+=("$keep")
  done
  if [ "${#remaining[@]}" -gt 0 ]; then
    printf '%s\n' "${remaining[@]}" > "$PRESENTED"
  else
    rm -f "$PRESENTED"
  fi
  # The round stays spent: a dismissed picker does not earn another call.
  printf 'dismissed: %s\n' "$*"
}

case "${1:-}" in
  round-start) shift; command_round_start "$@" ;;
  inventory) shift; command_inventory "$@" ;;
  present) shift; command_present "$@" ;;
  dismissed) shift; command_dismissed "$@" ;;
  -h|--help) usage ;;
  *) usage >&2; exit 2 ;;
esac
