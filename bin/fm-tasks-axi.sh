#!/usr/bin/env bash
# fm-tasks-axi.sh - run tasks-axi against THIS home's backlog from any working directory.
#
# Usage: fm-tasks-axi.sh [<tasks-axi command> [args...]]
#        fm-tasks-axi.sh --help
#
# Every routine firstmate backlog read or mutation goes through this command
# rather than a bare `tasks-axi`; `fm-tasks-axi.sh <command> --help` prints
# tasks-axi's own help. Arguments reach tasks-axi as given, apart from one
# rewrite that keeps file arguments meaning what the caller meant: a relative
# value of `--to` or any `--*-file` flag (`--body-file`, `--relation-file`, ...)
# is made absolute against the caller's working directory, because tasks-axi
# starts from the backlog root instead. `--report` stays as given: tasks-axi
# stores it verbatim as a link, which lifecycle transitions record relative to
# that same root.
#
# Why it exists: a bare `tasks-axi` resolves the tracked `.tasks.toml` paths
# against its working directory, so from the code root it forks the queue
# whenever the home lives elsewhere; docs/configuration.md ("Backlog backend")
# owns that rationale.
#
# Two verbs belong to this command rather than tasks-axi:
#   body <id>     print the task body's exact bytes, with no added newline. This
#                 is the data-mode read for a read-then-rewrite round trip
#                 (`body <id> > f`, edit f, `update <id> --body-file f`), because
#                 `show --full` is rendered text that must never be unescaped by
#                 hand; bin/fm-backlog-transition-lib.sh's fm_backlog_row_field
#                 owns the exact decode and its refusals.
#   requeue <id>  the supported reverse edge: return a Done or In flight task to
#                 Queued with its close date cleared (`tasks-axi reopen`) and the
#                 completion links a close appended to its title removed, so the
#                 row no longer reads as shipped. It refuses while this home
#                 holds a worker record for <id>, because that worker owns the
#                 In flight row until its own cleanup.
#   handback <unit> <id> --reason <text>
#                 a grouped dispatch's worker did not deliver member <id>: drop
#                 it from <unit>'s recorded membership, under <unit>'s own
#                 record lock, then record the reason as the last line of <id>'s
#                 body and return it from In flight to Queued. Run it BEFORE the
#                 unit's cleanup, which otherwise closes every member still
#                 recorded with the unit's PR. The membership is rewritten
#                 first, so an interruption strands the item In flight, where
#                 it is visible, rather than recorded for a close it never
#                 earned. bin/fm-backlog-transition-lib.sh MEMBERSHIP owns the
#                 contract.
#   group <id> [<key>|--solo]
#                 print, or record, the item's group key - an opaque slug
#                 matching [a-z0-9][a-z0-9._-]* that says which work this item
#                 belongs with. `--solo` records the verdict "considered,
#                 belongs to no group", which never matches anything. The key is
#                 one line in the item's own body, replaced where it stands and
#                 otherwise appended, never at the top, so a hold stamp keeps
#                 line 1. A body already carrying two key lines is refused
#                 rather than resolved by position.
#   linear <id> [<BLU-1234>]
#                 print, or record, the Linear card this item is tracked by, so
#                 the dispatch and merge paths can move that card without
#                 firstmate remembering. Like `group`, the value is one line in
#                 the item's own body, replaced where it stands and otherwise
#                 appended, never at the top, so a hold stamp keeps line 1; a
#                 body already carrying two card lines is refused rather than
#                 resolved by position. Printed as `none` when the item has no
#                 card, which is the ordinary case. bin/fm-linear-lib.sh owns the
#                 identifier grammar and both board transitions.
#   chunk <unit> "<title>" <member>...
#                 plan a chunk: create <unit> if it does not exist, record the
#                 members on it, stamp the shared key, and park each member
#                 behind it, so the queue offers one ready item instead of
#                 several. Every member must be Queued, unheld, a ship, in ONE
#                 repository, blocked by nothing but this unit, and carry that
#                 one key or none. It is idempotent, validates before it writes
#                 anything, and warns - never refuses - above the configured
#                 member cap. An existing unit must still be Queued and
#                 unstarted; a unit already In flight is refused with the `join`
#                 command to hand it the item instead.
#   chunk --dissolve <unit>
#                 the reverse, for a unit no worker holds: release each planned
#                 member and drop the plan line, leaving both rows in place.
#   join <unit> <id>
#                 the inverse of handback: hand a newly ready sibling to the
#                 worker already running <unit>. Under <unit>'s record lock it
#                 moves the row In flight first and then records the member, so
#                 an interruption strands a visible orphan rather than a member
#                 recorded for a close it never earned. It refuses an item that
#                 is not this unit's sibling - a different repository or key -
#                 and prints the two follow-ups firstmate owes afterwards.
#   plan          read-only: the ready ship items this home has not planned into
#                 a chunk, one `<repo> <key> <id>` line each, so planning can
#                 start from what is actually unplanned.
#
# A markdown backlog is checked before every command for entries tasks-axi
# cannot see - a checkbox flipped by hand without moving the entry to its
# section (fm_backlog_markdown_misplaced owns the rule) - and the command
# refuses naming each one, instead of letting tasks-axi report a task that is
# still in the file as NOT_FOUND.
#
# Addressing is bin/fm-backlog-transition-lib.sh's fm_backlog_tasks_axi_addressing,
# the same resolution the lifecycle transitions use: tasks-axi runs from the
# configured data directory's parent, so that home's own `.tasks.toml` (or
# tasks-axi's built-in defaults, which keep the archive beside the backlog)
# supplies the adapter, done_keep, and the archive path; a markdown backlog is
# additionally pinned to `<data>/backlog.md` through TASKS_AXI_FILE. The
# environment carries the pin rather than a trailing --file so the no-command
# dashboard works too. A configured non-markdown adapter is addressed by that
# root alone, so an inherited TASKS_AXI_FILE is cleared for it.
#
# The data directory is FM_DATA_OVERRIDE, else $FM_HOME/data, else the code
# root's data/ (FM_HOME unset keeps the single-home layout unchanged).
#
# Refusals (exit 2, nothing run):
#   - tasks-axi missing from PATH;
#   - a caller-supplied --file, because this command owns the addressing and
#     tasks-axi would silently let the last --file win;
#   - a data directory that cannot be resolved, or whose backend configuration
#     cannot be read (bin/fm-tasks-axi-lib.sh owns that diagnostic);
#   - a markdown `<data>/backlog.md` that is itself a symlink, because the
#     first write would replace the link with a private copy, exactly the fork
#     this command exists to prevent. Lifecycle transitions refuse the same file;
#   - a markdown backlog carrying a misplaced entry (above).
# `body`, `requeue`, `handback`, `group`, `chunk`, `join`, and `plan` exit 1 on a
# refusal of their own and 3 for a missing task; otherwise the exit status is
# tasks-axi's own. The grouping verbs read the posture from config/grouping only
# to decide whether to warn about a chunk's size; recording a key, planning a
# chunk, and joining a sibling are the same in every posture, because they
# describe work rather than enforce anything.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
# shellcheck source=bin/fm-tasks-axi-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-tasks-axi-lib.sh"
# shellcheck source=bin/fm-backlog-transition-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-backlog-transition-lib.sh"
# shellcheck source=bin/fm-grouping-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-grouping-lib.sh"
# shellcheck source=bin/fm-linear-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-linear-lib.sh"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

fail() {
  printf 'fm-tasks-axi: %s\n' "$*" >&2
  exit 2
}

case "${1:-}" in
  -h|--help)
    usage
    exit 0
    ;;
esac

CALLER_DIR=$(pwd)

absolute_from_caller() {  # <path-value>
  case "$1" in
    ''|-|/*) printf '%s' "$1" ;;
    *) printf '%s/%s' "$CALLER_DIR" "$1" ;;
  esac
}

ARGS=()
path_value_next=0
for arg in "$@"; do
  if [ "$path_value_next" = 1 ]; then
    ARGS+=("$(absolute_from_caller "$arg")")
    path_value_next=0
    continue
  fi
  case "$arg" in
    --file|--file=*)
      fail "this command always addresses this home's backlog at $DATA; drop --file, or run tasks-axi directly for another backlog"
      ;;
    --to|--*-file)
      ARGS+=("$arg")
      path_value_next=1
      ;;
    --to=*|--*-file=*)
      ARGS+=("${arg%%=*}=$(absolute_from_caller "${arg#*=}")")
      ;;
    *)
      ARGS+=("$arg")
      ;;
  esac
done

command -v tasks-axi >/dev/null 2>&1 || fail "tasks-axi is not on PATH; run bin/fm-bootstrap.sh for the install command"

FM_BACKLOG_TRANSITION_ERROR=
if ! fm_backlog_tasks_axi_addressing "$DATA"; then
  fail "${FM_BACKLOG_TRANSITION_ERROR:-data directory cannot be resolved: $DATA}"
fi

if [ -n "$FM_BACKLOG_AXI_FILE" ]; then
  if [ -L "$FM_BACKLOG_AXI_FILE" ]; then
    fail "$FM_BACKLOG_AXI_FILE is a symlink; a tasks-axi write would replace it with a regular file and fork the backlog - make it this home's real file"
  fi
  export TASKS_AXI_FILE="$FM_BACKLOG_AXI_FILE"
else
  unset TASKS_AXI_FILE
fi

if [ -n "$FM_BACKLOG_AXI_FILE" ] \
   && ! MISPLACED=$(fm_backlog_markdown_misplaced "$FM_BACKLOG_AXI_FILE"); then
  fail "$FM_BACKLOG_AXI_FILE has entries tasks-axi cannot see, which it would report as NOT_FOUND:
$MISPLACED"
fi

verb_fail() {  # <status> <message>
  printf 'fm-tasks-axi: %s\n' "$2" >&2
  exit "$1"
}

verb_id() {  # <verb> <args...>; prints the one id
  local verb=$1
  shift
  if [ "$#" -ne 1 ] || [ -z "$1" ]; then
    fail "usage: fm-tasks-axi.sh $verb <id>"
  fi
  case "$1" in -*) fail "usage: fm-tasks-axi.sh $verb <id>" ;; esac
  printf '%s\n' "$1"
}

field_or_fail() {  # <id> <field>
  local status
  fm_backlog_row_field "$DATA" "$1" "$2"
  status=$?
  [ "$status" -eq 0 ] || verb_fail "$([ "$status" -eq 3 ] && echo 3 || echo 1)" \
    "${FM_BACKLOG_TRANSITION_ERROR:-cannot read the $2 of $1}"
}

requeue() {  # <id>
  local id=$1 state_dir title links link url stripped changed=1 out
  local -a link_list=()
  state_dir="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
  if [ -e "$state_dir/$id.meta" ] || [ -L "$state_dir/$id.meta" ]; then
    verb_fail 1 "$id still has a worker record at $state_dir/$id.meta; its own cleanup moves the row, so tear that task down instead of requeueing it underneath the worker"
  fi
  out=$(cd "$FM_BACKLOG_AXI_ROOT" && tasks-axi reopen "$id" 2>&1) || {
    printf '%s\n' "$out" | grep -q '^code: NOT_FOUND$' && verb_fail 3 "$(printf '%s\n' "$out" | sed -n 1p)"
    verb_fail 1 "$(printf '%s\n' "$out" | sed -n 1p)"
  }
  field_or_fail "$id" title
  title=$FM_BACKLOG_ROW_FIELD_VALUE
  field_or_fail "$id" links
  links=$FM_BACKLOG_ROW_FIELD_VALUE
  stripped=$title
  [ "$links" = none ] || IFS=, read -r -a link_list <<< "$links"
  while [ "$changed" = 1 ]; do
    changed=0
    for link in ${link_list[@]+"${link_list[@]}"}; do
      url=${link#*:}
      case "$stripped" in
        *" $url")
          stripped=${stripped% "$url"}
          changed=1
          ;;
      esac
    done
  done
  if [ "$stripped" != "$title" ]; then
    out=$(cd "$FM_BACKLOG_AXI_ROOT" && tasks-axi update "$id" --title "$stripped" 2>&1) \
      || verb_fail 1 "$id is back in Queued, but its completion links could not be cleared from its title: $(printf '%s\n' "$out" | sed -n 1p)"
  fi
  printf 'ok: requeue %s -> Queued\n' "$id"
}

handback() {  # <unit> <member> <reason>
  local unit=$1 member=$2 reason=$3 state_dir meta lock tmp kept='' m found=0 status
  state_dir="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
  meta="$state_dir/$unit.meta"
  fm_backlog_record_present "$meta" "task record" "$state_dir" \
    || verb_fail 1 "$unit has no worker record in this home, so it has no membership to hand $member back from (${FM_BACKLOG_TRANSITION_ERROR:-no record}); a closed item returns through requeue"
  # shellcheck source=bin/fm-wake-lib.sh disable=SC1091
  STATE=$state_dir . "$SCRIPT_DIR/fm-wake-lib.sh"
  lock=$(fm_meta_lock_path "$meta") || verb_fail 1 "cannot resolve the record lock for $unit"
  fm_lock_acquire_wait "$lock" || verb_fail 1 "cannot lock the record of $unit"
  fm_backlog_record_present "$meta" "task record" "$state_dir" || {
    fm_lock_release "$lock"
    verb_fail 1 "$unit's record went away while waiting for its lock; its cleanup already ran"
  }
  if ! fm_backlog_members_of_meta "$meta" "$unit"; then
    fm_lock_release "$lock"
    verb_fail 1 "$FM_BACKLOG_TRANSITION_ERROR"
  fi
  for m in "${FM_BACKLOG_TRANSITION_MEMBERS[@]+"${FM_BACKLOG_TRANSITION_MEMBERS[@]}"}"; do
    if [ "$m" = "$member" ]; then
      found=1
    else
      kept="${kept:+$kept,}$m"
    fi
  done
  if [ "$found" != 1 ]; then
    fm_lock_release "$lock"
    verb_fail 1 "$unit does not deliver $member; its recorded membership is: ${FM_BACKLOG_TRANSITION_MEMBERS[*]:-none}"
  fi
  tmp="$state_dir/.$unit.meta.handback.$$"
  if ! { awk -F= '$1 != "delivers"' "$meta" && { [ -z "$kept" ] || printf 'delivers=%s\n' "$kept"; }; } > "$tmp" \
     || ! fm_backlog_atomic_transition publish "$tmp" "$meta" "task record" "$state_dir"; then
    rm -f -- "$tmp"
    fm_lock_release "$lock"
    verb_fail 1 "could not rewrite $unit's membership (${FM_BACKLOG_TRANSITION_ERROR:-write failed}); nothing was handed back"
  fi
  fm_backlog_row_probe "$DATA" "$member"
  status=$?
  case "$status:$FM_BACKLOG_ROW_STATE" in
    0:in_flight\ *)
      fm_backlog_requeue "$DATA" "$member" "Handed back undelivered by $unit: $reason"
      status=$?
      ;;
    0:*)
      fm_lock_release "$lock"
      verb_fail 1 "$member is no longer part of $unit, but it is not In flight (${FM_BACKLOG_ROW_STATE%% *}), so it was not returned to Queued"
      ;;
    *) FM_BACKLOG_TRANSITION_ERROR=$FM_BACKLOG_ROW_ERROR ;;
  esac
  fm_lock_release "$lock"
  [ "$status" -eq 0 ] || verb_fail 1 "$member is no longer part of $unit, but it could not be returned to Queued: $FM_BACKLOG_TRANSITION_ERROR"
  printf 'ok: handback %s from %s -> Queued\n' "$member" "$unit"
}


# --- grouping verbs (bin/fm-grouping-lib.sh owns what a key and a sibling are)

GROUPING_STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
GROUPING_CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"

grouping_id_valid() {  # <id>
  case "${1-}" in
    ''|-*|*[!A-Za-z0-9._-]*) return 1 ;;
  esac
}

# The decoded body of <id> in GROUPING_BODY, refusing exactly as field_or_fail.
GROUPING_BODY=
grouping_read_body() {  # <id>
  field_or_fail "$1" body
  GROUPING_BODY=$FM_BACKLOG_ROW_FIELD_VALUE
}

grouping_write_body() {  # <id> <body>
  local id=$1 body=$2 tmp
  tmp=$(umask 077; mktemp "${TMPDIR:-/tmp}/fm-grouping-body.XXXXXX") \
    || verb_fail 1 "cannot stage the body of $id"
  if ! printf '%s\n' "$body" > "$tmp"; then
    rm -f -- "$tmp"
    verb_fail 1 "cannot stage the body of $id"
  fi
  if ! fm_backlog_mutate "$DATA" update "$id" --body-file "$tmp"; then
    rm -f -- "$tmp"
    verb_fail 1 "could not write the body of $id: ${FM_BACKLOG_TRANSITION_ERROR:-write failed}"
  fi
  rm -f -- "$tmp"
}

# Record <key> on <id>, leaving every other byte of the body where it was.
grouping_set_key() {  # <id> <key>
  local id=$1 key=$2 existing
  grouping_read_body "$id"
  existing=$(fm_grouping_key_of_body "$GROUPING_BODY") \
    || verb_fail 1 "$id carries more than one group-key line; leave exactly one and re-run"
  [ "$existing" != "$key" ] || return 0
  grouping_write_body "$id" "$(fm_grouping_body_with_line "$GROUPING_BODY" "$FM_GROUPING_KEY_PREFIX" "$key")"
}

group_verb() {  # <id> [<key>|--solo]
  local id=$1 key=${2-} status
  grouping_id_valid "$id" || fail "usage: fm-tasks-axi.sh group <id> [<key>|--solo]"
  if [ "$#" -eq 1 ]; then
    fm_grouping_key_of_row "$DATA" "$id"
    status=$?
    case "$status" in
      0) printf '%s\n' "${FM_GROUPING_KEY:-none}" ;;
      3) verb_fail 3 "$FM_GROUPING_ERROR" ;;
      *) verb_fail 1 "$FM_GROUPING_ERROR" ;;
    esac
    return 0
  fi
  [ "$key" != --solo ] || key=$FM_GROUPING_SOLO_KEY
  fm_grouping_key_valid "$key" \
    || fail "a group key is 1-64 characters of [a-z0-9._-] starting with a letter or digit; '$key' is not"
  grouping_set_key "$id" "$key"
  printf 'ok: group %s -> %s\n' "$id" "$key"
}

# Record <card> on <id>, leaving every other byte of the body where it was.
linear_set_card() {  # <id> <card>
  local id=$1 card=$2 existing
  grouping_read_body "$id"
  existing=$(fm_linear_card_of_body "$GROUPING_BODY") \
    || verb_fail 1 "$id carries more than one Linear-card line; leave exactly one and re-run"
  [ "$existing" != "$card" ] || return 0
  grouping_write_body "$id" "$(fm_grouping_body_with_line "$GROUPING_BODY" "$FM_LINEAR_CARD_PREFIX" "$card")"
}

linear_verb() {  # <id> [<card>]
  local id=$1 card=${2-} status
  grouping_id_valid "$id" || fail "usage: fm-tasks-axi.sh linear <id> [<BLU-1234>]"
  if [ "$#" -eq 1 ]; then
    fm_linear_card_of_row "$DATA" "$id"
    status=$?
    case "$status" in
      0) printf '%s\n' "${FM_LINEAR_CARD:-none}" ;;
      3) verb_fail 3 "$FM_LINEAR_ERROR" ;;
      *) verb_fail 1 "$FM_LINEAR_ERROR" ;;
    esac
    return 0
  fi
  fm_linear_identifier_valid "$card" \
    || fail "a Linear card is a team key, a hyphen, and the issue number, as Linear prints one (BLU-3268); '$card' is not"
  linear_set_card "$id" "$card"
  printf 'ok: linear %s -> %s\n' "$id" "$card"
}

# Every planning read a chunk needs about one row, refusing before any write.
GROUPING_ROW_REPO=
GROUPING_ROW_KEY=
GROUPING_ROW_PRIORITY=
grouping_row_facts() {  # <id>
  local id=$1 status
  fm_grouping_repo_of_row "$DATA" "$id"
  status=$?
  [ "$status" -eq 0 ] || verb_fail "$([ "$status" -eq 3 ] && echo 3 || echo 1)" "$FM_GROUPING_ERROR"
  GROUPING_ROW_REPO=$FM_GROUPING_REPO
  fm_grouping_key_of_row "$DATA" "$id"
  status=$?
  [ "$status" -eq 0 ] || verb_fail "$([ "$status" -eq 3 ] && echo 3 || echo 1)" "$FM_GROUPING_ERROR"
  GROUPING_ROW_KEY=$FM_GROUPING_KEY
  field_or_fail "$id" priority
  case "$FM_BACKLOG_ROW_FIELD_VALUE" in
    ''|-|'"-"'|none) GROUPING_ROW_PRIORITY= ;;
    *[!0-9]*) GROUPING_ROW_PRIORITY= ;;
    *) GROUPING_ROW_PRIORITY=$FM_BACKLOG_ROW_FIELD_VALUE ;;
  esac
}

chunk_verb() {  # <unit> <title> <member>...
  local unit=$1 title=$2 member repo='' key='' priority='' seen=' ' unit_exists=0
  local -a members
  shift 2
  members=("$@")
  grouping_id_valid "$unit" || fail "usage: fm-tasks-axi.sh chunk <unit> \"<title>\" <member>..."
  [ -n "$title" ] || fail "usage: fm-tasks-axi.sh chunk <unit> \"<title>\" <member>..."
  [ "${#members[@]}" -gt 0 ] || fail "usage: fm-tasks-axi.sh chunk <unit> \"<title>\" <member>..."
  for member in "${members[@]}"; do
    grouping_id_valid "$member" || fail "usage: fm-tasks-axi.sh chunk <unit> \"<title>\" <member>..."
    [ "$member" != "$unit" ] || verb_fail 1 "a chunk's unit cannot also be one of its members: $unit"
    case "$seen" in
      *" $member "*) verb_fail 1 "member $member is named twice" ;;
    esac
    seen="$seen$member "
  done

  # Validate every row before writing anything: a refusal here leaves the queue
  # exactly as it was, which is what makes a mistaken chunk cost nothing.
  for member in "${members[@]}"; do
    fm_backlog_member_joinable "$DATA" "$GROUPING_STATE" "$unit" "$member" \
      || verb_fail 1 "$unit cannot plan $member: $FM_BACKLOG_TRANSITION_ERROR"
    field_or_fail "$member" kind
    [ "$FM_BACKLOG_ROW_FIELD_VALUE" = ship ] \
      || verb_fail 1 "member $member is a $FM_BACKLOG_ROW_FIELD_VALUE, and a chunk delivers ship work"
    grouping_row_facts "$member"
    [ -n "$GROUPING_ROW_REPO" ] \
      || verb_fail 1 "member $member names no repository, so nothing can say what it is related to; record one first"
    if [ -z "$repo" ]; then
      repo=$GROUPING_ROW_REPO
    elif [ "$repo" != "$GROUPING_ROW_REPO" ]; then
      verb_fail 1 "a chunk is one repository: $member is in $GROUPING_ROW_REPO, not $repo"
    fi
    if [ -n "$GROUPING_ROW_KEY" ]; then
      if [ -z "$key" ]; then
        key=$GROUPING_ROW_KEY
      elif [ "$key" != "$GROUPING_ROW_KEY" ]; then
        verb_fail 1 "a chunk is one group: $member carries $GROUPING_ROW_KEY, not $key"
      fi
    fi
    if [ -n "$GROUPING_ROW_PRIORITY" ]; then
      if [ -z "$priority" ] || [ "$GROUPING_ROW_PRIORITY" -lt "$priority" ]; then
        priority=$GROUPING_ROW_PRIORITY
      fi
    fi
  done

  if fm_backlog_row_probe "$DATA" "$unit"; then
    unit_exists=1
    case "$FM_BACKLOG_ROW_STATE" in
      queued\ no\ no) ;;
      in_flight*)
        verb_fail 1 "$unit is already In flight, so its work is under way: hand it an item with 'fm-tasks-axi.sh join $unit <id>' instead of planning it"
        ;;
      *)
        verb_fail 1 "$unit is not an unheld, unblocked Queued item ($FM_BACKLOG_ROW_STATE), so it cannot take a plan"
        ;;
    esac
    [ ! -e "$GROUPING_STATE/$unit.meta" ] && [ ! -L "$GROUPING_STATE/$unit.meta" ] \
      || verb_fail 1 "$unit already has a worker record in this home; hand it an item with 'fm-tasks-axi.sh join $unit <id>' instead"
    [ ! -e "$GROUPING_STATE/$unit.backlog-close" ] && [ ! -L "$GROUPING_STATE/$unit.backlog-close" ] \
      || verb_fail 1 "$unit has a pending backlog close in this home; finish that cleanup before planning it"
    field_or_fail "$unit" kind
    [ "$FM_BACKLOG_ROW_FIELD_VALUE" = ship ] \
      || verb_fail 1 "$unit is a $FM_BACKLOG_ROW_FIELD_VALUE, and a chunk unit delivers ship work"
    grouping_row_facts "$unit"
    if [ -n "$GROUPING_ROW_REPO" ] && [ "$GROUPING_ROW_REPO" != "$repo" ]; then
      verb_fail 1 "$unit is in $GROUPING_ROW_REPO, and its members are in $repo"
    fi
    if [ -n "$GROUPING_ROW_KEY" ]; then
      if [ -z "$key" ]; then
        key=$GROUPING_ROW_KEY
      elif [ "$key" != "$GROUPING_ROW_KEY" ]; then
        verb_fail 1 "$unit carries $GROUPING_ROW_KEY, and its members carry $key"
      fi
    fi
  elif [ "$FM_BACKLOG_ROW_RESULT" != not_found ]; then
    verb_fail 1 "$unit's backlog item could not be read: $FM_BACKLOG_ROW_ERROR"
  fi
  [ -n "$key" ] \
    || verb_fail 1 "nothing in this chunk carries a group key, so it would say nothing about what belongs together; record one with 'fm-tasks-axi.sh group <id> <key>' first"
  [ "$key" != "$FM_GROUPING_SOLO_KEY" ] \
    || verb_fail 1 "$FM_GROUPING_SOLO_KEY is the recorded verdict that an item belongs to no group, so it cannot name a chunk"

  # Writes. Each one is idempotent, so a re-run converges on the same plan.
  if [ "$unit_exists" = 0 ]; then
    local -a add_args
    add_args=("$title" --kind ship --repo "$repo")
    [ -z "$priority" ] || add_args+=(--priority "$priority")
    fm_backlog_mutate "$DATA" add "$unit" "${add_args[@]}" \
      || verb_fail 1 "could not create the chunk unit $unit: ${FM_BACKLOG_TRANSITION_ERROR:-add failed}"
  fi
  grouping_set_key "$unit" "$key"
  for member in "${members[@]}"; do
    grouping_set_key "$member" "$key"
  done
  grouping_read_body "$unit"
  fm_grouping_plan_of_body "$GROUPING_BODY" >/dev/null \
    || verb_fail 1 "$unit carries more than one chunk-members line; leave exactly one and re-run"
  local members_csv
  members_csv=$(IFS=,; printf '%s' "${members[*]}")
  grouping_write_body "$unit" "$(fm_grouping_body_with_line "$GROUPING_BODY" "$FM_GROUPING_PLAN_PREFIX" "$members_csv")"
  for member in "${members[@]}"; do
    fm_backlog_mutate "$DATA" block "$member" --by "$unit" \
      || verb_fail 1 "$unit was planned, but $member could not be parked behind it: ${FM_BACKLOG_TRANSITION_ERROR:-block failed}"
  done

  if ! fm_grouping_posture "$GROUPING_CONFIG"; then
    printf 'fm-tasks-axi: cannot tell this home'"'"'s soft member cap, so no size warning was made: %s\n' "$FM_GROUPING_ERROR" >&2
  elif [ -n "$FM_GROUPING_MEMBER_CAP" ] && [ "${#members[@]}" -gt "$FM_GROUPING_MEMBER_CAP" ]; then
    printf 'fm-tasks-axi: %s has %s members, above this home'"'"'s soft cap of %s; that is a warning, not a refusal\n' \
      "$unit" "${#members[@]}" "$FM_GROUPING_MEMBER_CAP" >&2
  fi
  printf 'ok: chunk %s (%s) delivers %s\n' "$unit" "$key" "$members_csv"
}

chunk_dissolve_verb() {  # <unit>
  local unit=$1 plan member
  grouping_id_valid "$unit" || fail "usage: fm-tasks-axi.sh chunk --dissolve <unit>"
  [ ! -e "$GROUPING_STATE/$unit.meta" ] && [ ! -L "$GROUPING_STATE/$unit.meta" ] \
    || verb_fail 1 "$unit has a worker record in this home, so its chunk is under way; hand a member back instead"
  grouping_read_body "$unit"
  plan=$(fm_grouping_plan_of_body "$GROUPING_BODY") \
    || verb_fail 1 "$unit carries more than one chunk-members line; leave exactly one and re-run"
  [ -n "$plan" ] || verb_fail 1 "$unit has no planned members to release"
  while IFS= read -r member; do
    [ -n "$member" ] || continue
    fm_backlog_mutate "$DATA" unblock "$member" --by "$unit" \
      || verb_fail 1 "could not release $member from $unit: ${FM_BACKLOG_TRANSITION_ERROR:-unblock failed}"
  done <<MEMBERS
$(printf '%s\n' "$plan" | tr ',' '\n')
MEMBERS
  grouping_read_body "$unit"
  grouping_write_body "$unit" "$(fm_grouping_body_without_line "$GROUPING_BODY" "$FM_GROUPING_PLAN_PREFIX")"
  printf 'ok: chunk --dissolve %s released %s\n' "$unit" "$plan"
}

join_verb() {  # <unit> <member>
  local unit=$1 member=$2 meta lock status kind repo key member_repo member_key
  local recorded=0 m tmp kept=''
  if ! grouping_id_valid "$unit" || ! grouping_id_valid "$member"; then
    fail "usage: fm-tasks-axi.sh join <unit> <id>"
  fi
  [ "$unit" != "$member" ] || verb_fail 1 "a unit cannot join itself"
  meta="$GROUPING_STATE/$unit.meta"
  fm_backlog_record_present "$meta" "task record" "$GROUPING_STATE" \
    || verb_fail 1 "$unit has no worker record in this home, so there is no live job to hand $member to (${FM_BACKLOG_TRANSITION_ERROR:-no record}); plan a chunk instead"
  fm_backlog_transition_applies "$GROUPING_CONFIG" "$DATA" ship \
    || verb_fail 1 "joining an item moves its backlog row, which needs this home's automatic backlog transitions (${FM_BACKLOG_TRANSITION_SKIP:-unavailable}); steer the worker and track the item by hand"
  kind=$(fm_meta_get "$meta" kind)
  [ "$kind" = ship ] || verb_fail 1 "$unit is a $kind worker, and only a ship worker delivers backlog items"
  [ ! -e "$GROUPING_STATE/$unit.backlog-close" ] && [ ! -L "$GROUPING_STATE/$unit.backlog-close" ] \
    || verb_fail 1 "$unit has a pending backlog close, so its membership is already being replayed; finish that cleanup first"

  fm_grouping_repo_of_row "$DATA" "$unit"
  status=$?
  [ "$status" -eq 0 ] || verb_fail "$([ "$status" -eq 3 ] && echo 3 || echo 1)" "$FM_GROUPING_ERROR"
  repo=$FM_GROUPING_REPO
  fm_grouping_key_of_row "$DATA" "$unit"
  status=$?
  [ "$status" -eq 0 ] || verb_fail "$([ "$status" -eq 3 ] && echo 3 || echo 1)" "$FM_GROUPING_ERROR"
  key=$FM_GROUPING_KEY
  fm_grouping_relatable "$repo" "$key" \
    || verb_fail 1 "$unit names no repository and group key of its own, so nothing can say $member belongs with it; record them with 'fm-tasks-axi.sh group $unit <key>' first"
  fm_grouping_repo_of_row "$DATA" "$member"
  status=$?
  [ "$status" -eq 0 ] || verb_fail "$([ "$status" -eq 3 ] && echo 3 || echo 1)" "$FM_GROUPING_ERROR"
  member_repo=$FM_GROUPING_REPO
  fm_grouping_key_of_row "$DATA" "$member"
  status=$?
  [ "$status" -eq 0 ] || verb_fail "$([ "$status" -eq 3 ] && echo 3 || echo 1)" "$FM_GROUPING_ERROR"
  member_key=$FM_GROUPING_KEY
  [ "$member_repo" = "$repo" ] \
    || verb_fail 1 "$member is in ${member_repo:-no repository}, and $unit is in $repo, so it is not this job's sibling"
  [ "$member_key" = "$key" ] \
    || verb_fail 1 "$member carries ${member_key:-no group key}, and $unit carries $key, so it is not this job's sibling"

  # shellcheck source=bin/fm-wake-lib.sh disable=SC1091
  STATE=$GROUPING_STATE . "$SCRIPT_DIR/fm-wake-lib.sh"
  lock=$(fm_meta_lock_path "$meta") || verb_fail 1 "cannot resolve the record lock for $unit"
  fm_lock_acquire_wait "$lock" || verb_fail 1 "cannot lock the record of $unit"
  fm_backlog_record_present "$meta" "task record" "$GROUPING_STATE" || {
    fm_lock_release "$lock"
    verb_fail 1 "$unit's record went away while waiting for its lock; its cleanup already ran"
  }
  if ! fm_backlog_members_of_meta "$meta" "$unit"; then
    fm_lock_release "$lock"
    verb_fail 1 "$FM_BACKLOG_TRANSITION_ERROR"
  fi
  for m in "${FM_BACKLOG_TRANSITION_MEMBERS[@]+"${FM_BACKLOG_TRANSITION_MEMBERS[@]}"}"; do
    [ "$m" != "$member" ] || recorded=1
    kept="${kept:+$kept,}$m"
  done
  if [ "$recorded" = 1 ]; then
    fm_lock_release "$lock"
    printf 'ok: join %s already delivers %s\n' "$unit" "$member"
    return 0
  fi

  # The row moves In flight first. An interruption then leaves a row In flight
  # that no record names, which the fleet snapshot already reports as an orphan;
  # the reverse order would record a member for a close while it still reads as
  # ready work. A row this unit already moved - the resume after exactly that
  # interruption - is accepted here, where fm_backlog_member_joinable's Queued
  # rule alone would refuse the retry.
  fm_backlog_row_probe "$DATA" "$member" || {
    fm_lock_release "$lock"
    verb_fail 1 "$member's backlog item could not be read: $FM_BACKLOG_ROW_ERROR"
  }
  case "$FM_BACKLOG_ROW_STATE" in
    in_flight\ no\ *)
      if [ -e "$GROUPING_STATE/$member.meta" ] || [ -L "$GROUPING_STATE/$member.meta" ] \
        || [ -e "$GROUPING_STATE/$member.backlog-close" ] || [ -L "$GROUPING_STATE/$member.backlog-close" ] \
        || grep -qsE "^delivers=(.*,)?$member(,.*)?\$" "$GROUPING_STATE"/*.meta; then
        fm_lock_release "$lock"
        verb_fail 1 "$member is already In flight under another worker or unit, so $unit cannot also deliver it"
      fi
      ;;
    *)
      if ! fm_backlog_member_joinable "$DATA" "$GROUPING_STATE" "$unit" "$member"; then
        fm_lock_release "$lock"
        verb_fail 1 "$unit cannot take $member: $FM_BACKLOG_TRANSITION_ERROR"
      fi
      if ! fm_backlog_start "$DATA" "$member"; then
        fm_lock_release "$lock"
        verb_fail 1 "$member could not be moved In flight, so nothing was recorded: ${FM_BACKLOG_TRANSITION_ERROR:-start failed}"
      fi
      ;;
  esac
  tmp="$GROUPING_STATE/.$unit.meta.join.$$"
  if ! { awk -F= '$1 != "delivers"' "$meta" && printf 'delivers=%s\n' "${kept:+$kept,}$member"; } > "$tmp" \
     || ! fm_backlog_atomic_transition publish "$tmp" "$meta" "task record" "$GROUPING_STATE"; then
    rm -f -- "$tmp"
    fm_lock_release "$lock"
    verb_fail 1 "$member is In flight, but $unit's membership could not be rewritten (${FM_BACKLOG_TRANSITION_ERROR:-write failed}); re-run this join to finish it"
  fi
  fm_lock_release "$lock"
  printf 'ok: join %s -> %s delivers %s\n' "$member" "$unit" "${kept:+$kept,}$member"
  printf 'next: add %s'"'"'s own intent to the brief at data/%s/brief.md, then tell the worker with bin/fm-send.sh %s "<what %s asks for>"\n' \
    "$member" "$unit" "$unit" "$member"
  printf 'next: if that worker is not running, bring it back with bin/fm-control.sh %s relaunch\n' "$unit"
}

# The item and staged body file an `update` invocation rewrites, for the
# interception described at the dispatch below. Both are empty when the
# invocation does not rewrite a body at all.
REWRITE_ID=
REWRITE_BODY_FILE=
body_rewrite_target() {  # <update args...>
  local arg next=0
  REWRITE_ID=
  REWRITE_BODY_FILE=
  for arg in "$@"; do
    if [ "$next" = 1 ]; then
      REWRITE_BODY_FILE=$arg
      next=0
      continue
    fi
    case "$arg" in
      --body-file) next=1 ;;
      --body-file=*) REWRITE_BODY_FILE=${arg#*=} ;;
      --body|--body=*) REWRITE_BODY_FILE=- ;;
      -*) ;;
      *) [ -n "$REWRITE_ID" ] || REWRITE_ID=$arg ;;
    esac
  done
  [ -n "$REWRITE_ID" ] && [ -n "$REWRITE_BODY_FILE" ] || return 1
  grouping_id_valid "$REWRITE_ID"
}

# Carry one of firstmate's machine-read body lines across a body rewrite. It
# rewrites the staged body file in place, so tasks-axi still performs the update
# itself. <reader> is the owning library's own parser for that line, so each line
# keeps its own grammar and its own two-copies refusal; <noun> and <fix> name the
# line and its recording command in the refusals.
carry_body_line_through_update() {  # <id> <body-file> <existing> <prefix> <reader> <noun> <fix>
  local id=$1 body_file=$2 existing=$3 prefix=$4 reader=$5 noun=$6 fix=$7 staged current
  [ -n "$existing" ] || return 0
  if [ "$body_file" = - ]; then
    fail "a --body rewrite of $id would drop its recorded $noun ($existing); pass the new body with --body-file so it can be carried across"
  fi
  [ -f "$body_file" ] && [ ! -L "$body_file" ] || fail "cannot read the new body for $id at $body_file"
  staged=$(cat "$body_file") || fail "cannot read the new body for $id at $body_file"
  current=$("$reader" "$staged") \
    || fail "the new body for $id carries more than one $noun line"
  if [ -n "$current" ]; then
    [ "$current" = "$existing" ] \
      || fail "the new body for $id records the $noun $current, but its item carries $existing; change it with '$fix'"
    return 0
  fi
  printf '%s\n' "$(fm_grouping_body_with_line "$staged" "$prefix" "$existing")" > "$body_file" \
    || fail "could not carry $id's $noun across its body rewrite"
}

plan_verb() {
  local out line id plan key repo
  out=$(fm_backlog_row_list "$DATA" --state queued --kind ship) \
    || verb_fail 1 "cannot list this home's queued ship items: $(printf '%s\n' "$out" | sed -n 1p)"
  while IFS= read -r line; do
    case "$line" in '  '*) ;; *) continue ;; esac
    line=${line#  }
    id=${line%%,*}
    case "$id" in ''|*[!A-Za-z0-9._-]*) continue ;; esac
    fm_backlog_row_probe "$DATA" "$id" || { printf 'cannot-tell - - %s\n' "$id"; continue; }
    case "$FM_BACKLOG_ROW_STATE" in
      queued\ no\ no) ;;
      *) continue ;;
    esac
    fm_backlog_row_field "$DATA" "$id" body || { printf 'cannot-tell - - %s\n' "$id"; continue; }
    GROUPING_BODY=$FM_BACKLOG_ROW_FIELD_VALUE
    plan=$(fm_grouping_plan_of_body "$GROUPING_BODY") || { printf 'cannot-tell - - %s\n' "$id"; continue; }
    [ -z "$plan" ] || continue
    key=$(fm_grouping_key_of_body "$GROUPING_BODY") || { printf 'cannot-tell - - %s\n' "$id"; continue; }
    fm_grouping_repo_of_row "$DATA" "$id" || { printf 'cannot-tell - - %s\n' "$id"; continue; }
    repo=$FM_GROUPING_REPO
    printf '%s %s %s\n' "${repo:-none}" "${key:-none}" "$id"
  done <<ROWS
$out
ROWS
}

cd "$FM_BACKLOG_AXI_ROOT" || fail "cannot enter the backlog root $FM_BACKLOG_AXI_ROOT"
case "${ARGS[0]:-}" in
  body)
    BODY_ID=$(verb_id body "${ARGS[@]:1}") || exit 2
    field_or_fail "$BODY_ID" body
    printf '%s' "$FM_BACKLOG_ROW_FIELD_VALUE"
    exit 0
    ;;
  requeue)
    REQUEUE_ID=$(verb_id requeue "${ARGS[@]:1}") || exit 2
    requeue "$REQUEUE_ID"
    exit 0
    ;;
  handback)
    if [ "${#ARGS[@]}" -ne 5 ] || [ "${ARGS[3]}" != --reason ] || [ -z "${ARGS[4]}" ]; then
      fail "usage: fm-tasks-axi.sh handback <unit> <id> --reason <text>"
    fi
    case "${ARGS[1]}${ARGS[2]}" in -*) fail "usage: fm-tasks-axi.sh handback <unit> <id> --reason <text>" ;; esac
    case "${ARGS[4]}" in *$'\n'*|*$'\r'*) fail "handback: --reason must be one line" ;; esac
    handback "${ARGS[1]}" "${ARGS[2]}" "${ARGS[4]}"
    exit 0
    ;;
  group)
    if [ "${#ARGS[@]}" -lt 2 ] || [ "${#ARGS[@]}" -gt 3 ]; then
      fail "usage: fm-tasks-axi.sh group <id> [<key>|--solo]"
    fi
    group_verb "${ARGS[@]:1}"
    exit 0
    ;;
  chunk)
    if [ "${ARGS[1]:-}" = --dissolve ]; then
      [ "${#ARGS[@]}" -eq 3 ] || fail "usage: fm-tasks-axi.sh chunk --dissolve <unit>"
      chunk_dissolve_verb "${ARGS[2]}"
      exit 0
    fi
    [ "${#ARGS[@]}" -ge 4 ] || fail "usage: fm-tasks-axi.sh chunk <unit> \"<title>\" <member>..."
    chunk_verb "${ARGS[@]:1}"
    exit 0
    ;;
  join)
    [ "${#ARGS[@]}" -eq 3 ] || fail "usage: fm-tasks-axi.sh join <unit> <id>"
    join_verb "${ARGS[1]}" "${ARGS[2]}"
    exit 0
    ;;
  plan)
    [ "${#ARGS[@]}" -eq 1 ] || fail "usage: fm-tasks-axi.sh plan"
    plan_verb
    exit 0
    ;;
  linear)
    if [ "${#ARGS[@]}" -lt 2 ] || [ "${#ARGS[@]}" -gt 3 ]; then
      fail "usage: fm-tasks-axi.sh linear <id> [<BLU-1234>]"
    fi
    linear_verb "${ARGS[@]:1}"
    exit 0
    ;;
  update)
    # A body rewrite is the sanctioned way to replace a considered note
    # (docs/architecture.md), and firstmate's own machine-read lines live in that
    # same body. Carry each existing one across the rewrite rather than letting a
    # routine note edit silently ungroup the item or lose the Linear card the
    # dispatch and merge paths read; a rewrite that states a DIFFERENT value is
    # refused, because only `group` and `linear` record one.
    if body_rewrite_target "${ARGS[@]:1}"; then
      if fm_grouping_key_of_row "$DATA" "$REWRITE_ID"; then
        carry_body_line_through_update "$REWRITE_ID" "$REWRITE_BODY_FILE" \
          "$FM_GROUPING_KEY" "$FM_GROUPING_KEY_PREFIX" fm_grouping_key_of_body \
          "group key" "fm-tasks-axi.sh group $REWRITE_ID <key>"
      fi
      if fm_linear_card_of_row "$DATA" "$REWRITE_ID"; then
        carry_body_line_through_update "$REWRITE_ID" "$REWRITE_BODY_FILE" \
          "$FM_LINEAR_CARD" "$FM_LINEAR_CARD_PREFIX" fm_linear_card_of_body \
          "Linear card" "fm-tasks-axi.sh linear $REWRITE_ID <BLU-1234>"
      fi
    fi
    ;;
esac
exec tasks-axi ${ARGS[@]+"${ARGS[@]}"}
