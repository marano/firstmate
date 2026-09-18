#!/usr/bin/env bash
# fm-ask.sh - deterministic guards behind the captain-invoked /ask skill.
#
# /ask is the captain's OPT-IN to having his open decisions presented through
# the interactive question picker instead of plain text. Opening that picker
# ends the supervisor's turn and halts supervision of the whole fleet until he
# answers, which is why plain text stays the standing default and why this
# script exists: every refusal below keeps the picker from bringing that
# failure back. .agents/skills/ask/SKILL.md owns the policy and the
# presentation; this script owns only the mechanical checks, and it never
# reads chat, reports, or prose to decide what is a captain call.
#
# Usage:
#   fm-ask.sh inventory
#     Print the live captain calls that may be presented, the open worker
#     decisions that are firstmate's own and must never be presented, any
#     earlier presentation whose answer is not yet recorded, and the count of
#     queued wake records still unhandled. With no live captain call the first
#     line is exactly "No open captain decisions."
#   fm-ask.sh present <task-id>
#     Check that <task-id> may be presented now, then record it as the one
#     outstanding presentation. Run it immediately before opening the picker.
#   fm-ask.sh dismissed <task-id>
#     Clear the outstanding presentation of <task-id> when the captain closed
#     the picker without giving any answer. An answer, including "later", is
#     recorded through bin/fm-captain-hold.sh instead, never through this.
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
#   3  away posture: bin/fm-afk-return.sh guard refuses, because the away or
#      quiet record exists or the return catch-up has not cleared. Away mode
#      holds decisions for the captain's return by design, and a picker there
#      would stop that supervision too.
#   4  queued wake records are unhandled. The picker is the last act of the
#      turn, so everything that does not need the captain happens first:
#      handle and acknowledge the queue, then ask.
#   6  <task-id> is not a live captain call: firstmate's own decision, an
#      already closed or deferred call, or an unknown id.
#   5  an earlier presentation is still a live captain call: its answer has
#      not been recorded. Record it before presenting another, or it will be
#      asked again.
#   2  usage error, or the captain-call projection could not be read.
#
# RECORD. state/.ask-presented holds the one outstanding presented task id;
# `present` writes it and `dismissed` removes it. A presentation counts as
# recorded once its task has left the live captain calls, whichever owning
# path closed, released, or deferred it.
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

outstanding() {
  [ -f "$PRESENTED" ] || return 0
  head -n 1 "$PRESENTED"
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
    printf '%s\n' "CAPTAIN CALLS (live; present one at a time, most impactful first):"
    printf '%s\n' "$CALLS" | awk -F '\t' '{ printf "  %s [%s]: %s\n", $1, $2, $3 }'
  fi
  if [ -n "$own" ]; then
    printf '%s\n' "WAITING ON FIRSTMATE, NOT THE CAPTAIN (decide or escalate under ask-user-authority; never present these as they stand):"
    printf '%s' "$own"
  fi
  prior=$(outstanding)
  if [ -n "$prior" ] && is_live "$CALLS" "$prior"; then
    printf '%s\n' "PRESENTED AND NOT YET RECORDED: $prior - record his answer through its owner before presenting another, or run 'bin/fm-ask.sh dismissed $prior' if he gave none."
  fi
  queued=$(queued_wakes) || queued='unknown'
  if [ "$queued" != 0 ]; then
    printf '%s\n' "QUEUED WAKES: $queued unhandled - handle and acknowledge them before presenting anything."
  fi
}

command_present() {
  local id=${1:-} prior queued
  if [ "$#" -ne 1 ] || ! valid_id "$id"; then usage >&2; exit 2; fi
  refuse_if_away
  queued=$(queued_wakes) || queued='unknown'
  if [ "$queued" != 0 ]; then
    printf '%s\n' "fm-ask: refused - $queued queued wake record(s) are unhandled; the picker ends the turn, so handle and acknowledge them first." >&2
    exit 4
  fi
  read_calls_or_fail
  if ! is_live "$CALLS" "$id"; then
    printf '%s\n' "fm-ask: refused - $id is not a live captain call; a decision that is firstmate's own is decided, not asked, and a closed or deferred call is not asked again." >&2
    exit 6
  fi
  prior=$(outstanding)
  if [ -n "$prior" ] && [ "$prior" != "$id" ] && is_live "$CALLS" "$prior"; then
    printf '%s\n' "fm-ask: refused - $prior was presented and its answer is not recorded yet; record it before presenting $id, or run 'bin/fm-ask.sh dismissed $prior' if he gave none." >&2
    exit 5
  fi
  if ! { printf '%s\n' "$id" > "$PRESENTED.tmp.$$" && mv "$PRESENTED.tmp.$$" "$PRESENTED"; }; then
    rm -f "$PRESENTED.tmp.$$"
    printf '%s\n' "fm-ask: could not record the presentation of $id" >&2
    exit 2
  fi
  printf 'presented: %s\n' "$id"
}

command_dismissed() {
  local id=${1:-} prior
  if [ "$#" -ne 1 ] || ! valid_id "$id"; then usage >&2; exit 2; fi
  refuse_if_away
  prior=$(outstanding)
  if [ "$prior" != "$id" ]; then
    printf '%s\n' "fm-ask: $id is not the outstanding presentation${prior:+ ($prior is)}" >&2
    exit 2
  fi
  rm -f "$PRESENTED"
  printf 'dismissed: %s\n' "$id"
}

case "${1:-}" in
  inventory) shift; command_inventory "$@" ;;
  present) shift; command_present "$@" ;;
  dismissed) shift; command_dismissed "$@" ;;
  -h|--help) usage ;;
  *) usage >&2; exit 2 ;;
esac
