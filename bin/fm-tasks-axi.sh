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
# `body`, `requeue`, and `handback` exit 1 on a refusal of their own and 3 for
# a missing task; otherwise the exit status is tasks-axi's own.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
# shellcheck source=bin/fm-tasks-axi-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-tasks-axi-lib.sh"
# shellcheck source=bin/fm-backlog-transition-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-backlog-transition-lib.sh"

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
  fm_backlog_body_append_line "$DATA" "$member" "Handed back undelivered by $unit: $reason"
  status=$?
  if [ "$status" -eq 0 ]; then
    fm_backlog_requeue "$DATA" "$member" "Handed back undelivered by $unit: $reason"
    status=$?
  fi
  fm_lock_release "$lock"
  [ "$status" -eq 0 ] || verb_fail 1 "$member is no longer part of $unit, but it could not be returned to Queued: $FM_BACKLOG_TRANSITION_ERROR"
  printf 'ok: handback %s from %s -> Queued\n' "$member" "$unit"
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
esac
exec tasks-axi ${ARGS[@]+"${ARGS[@]}"}
