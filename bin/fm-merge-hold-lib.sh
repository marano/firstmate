#!/usr/bin/env bash
# fm-merge-hold-lib.sh - the ONE owner of WHY a task's PR waits for the captain
# instead of being merged by firstmate on standing authority.
#
# WHY THIS EXISTS. Every held PR used to be reported the same way, as a merge
# waiting for the captain's word, whatever was actually holding it. A project
# registered without standing merge authority, a task dispatched below its
# project's authority, and a hold the captain asked for all read identically, so
# a default nobody chose was indistinguishable from a decision the captain made.
# Every surface that reports a PR as held names its reason from here instead of
# composing its own wording.
#
# REASONS COME FROM STRUCTURED RECORDS ONLY. No report, brief, backlog body, or
# chat prose is read. The inputs are:
#   the task's recorded merge authority   state/<id>.meta yolo= (bin/fm-spawn.sh),
#                                         the one value every merge path obeys
#   why a task carries less than its      state/<id>.meta yolo_downgrade_reason=
#   project                               (bin/fm-spawn.sh)
#   the task's delivery mode              state/<id>.meta mode=
#   the project's registered posture      data/projects.md, read only through
#                                         bin/fm-project-mode.sh --strict
#   an explicit hold on the task          the backlog row's structured hold
#                                         (tasks-axi hold --kind/--reason); its
#                                         recorded reason is quoted verbatim
# A destructive, irreversible, or security-sensitive change is named only when
# someone recorded it as such a hold: no other structured record carries that
# judgment, and this library never guesses it from a diff or a description.
# A hold that exists only in prose therefore produces no reason here; the fix is
# to record it as a backlog hold, never to teach this library to read prose.
#
# WHAT IS NOT A REASON. A task whose recorded authority is on, whose delivery
# mode is validated, and whose backlog row carries no active hold produces no
# output at all: nothing on record holds it, so no reason is rendered.
#
# OUTPUT. Zero or more lines of `<kind><TAB><text>`, in this order:
#   no_standing_authority  the task records no merge authority and neither does
#                          its project: a posture nobody has ruled on, stated as
#                          such and never as a request to approve the merge
#   task_downgrade         the project grants standing authority but this task
#                          was dispatched without it; quotes the recorded reason,
#                          or says plainly that none was recorded
#   posture_unreadable     the task records no merge authority and its project's
#                          registered posture could not be read
#   unvalidated_delivery   the task ships direct-PR, so no validation run stands
#                          behind it and standing authority cannot cover it
#                          (bin/fm-pr-merge.sh owns that refusal)
#   recorded_hold          an explicit backlog hold on the task, with its kind
#                          and its recorded reason
#   hold_unreadable        whether the task's backlog row holds it could not be
#                          read (fm_merge_hold_task only)
#
# bin/fm-merge-authority-lib.sh owns the separate record of the authority under
# which an accepted merge ran; this library only explains an absent one.
#
# No side effects on source. set -u / set -e safe.

if [ -n "${FM_MERGE_HOLD_LIB_SOURCED:-}" ]; then
  return 0
fi
FM_MERGE_HOLD_LIB_SOURCED=1

_FM_MERGE_HOLD_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# The backlog row reader and its backend gate. A caller that already sourced
# either keeps its memoised state, so each is sourced only when absent.
if ! declare -F fm_tasks_axi_backend >/dev/null 2>&1; then
  # shellcheck source=bin/fm-tasks-axi-lib.sh
  . "$_FM_MERGE_HOLD_LIB_DIR/fm-tasks-axi-lib.sh"
fi
if ! declare -F fm_backlog_row_probe >/dev/null 2>&1; then
  # shellcheck source=bin/fm-backlog-transition-lib.sh
  . "$_FM_MERGE_HOLD_LIB_DIR/fm-backlog-transition-lib.sh"
fi

# The fixed wording of the posture nobody has ruled on. Tests and every renderer
# key on it, so it lives in exactly one place.
FM_MERGE_HOLD_NO_AUTHORITY_TEXT='no standing merge authority on this project; nobody has ruled'

# Print the reasons for one task from values its caller already read.
#   <task-yolo>        the task record's yolo= value, possibly empty
#   <task-mode>        the task record's mode= value, possibly empty
#   <downgrade-reason> the task record's yolo_downgrade_reason=, possibly empty
#   <project>          the project's registry name, for wording only
#   <registry-yolo>    on | off | unregistered | unknown
#   <hold-kind>        an ACTIVE backlog hold's kind, empty when not held
#   <hold-reason>      that hold's recorded reason, empty when not held
fm_merge_hold_reasons() {
  local yolo=${1-} mode=${2-} downgrade=${3-} project=${4-} registry=${5-} hold_kind=${6-} hold_reason=${7-}
  local name=${project:-this project}
  if [ "$yolo" != on ]; then
    case "$registry" in
      off)
        printf 'no_standing_authority\t%s (the registry records no merge-authority ruling for %s)\n' \
          "$FM_MERGE_HOLD_NO_AUTHORITY_TEXT" "$name"
        ;;
      unregistered)
        printf 'no_standing_authority\t%s (%s is not in the project registry)\n' \
          "$FM_MERGE_HOLD_NO_AUTHORITY_TEXT" "$name"
        ;;
      on)
        if [ -n "$downgrade" ]; then
          printf 'task_downgrade\tthis task was dispatched without the standing merge authority %s carries: %s\n' \
            "$name" "$downgrade"
        else
          printf 'task_downgrade\tthis task records no merge authority although %s carries standing authority, and no reason for the difference was recorded\n' \
            "$name"
        fi
        ;;
      *)
        printf 'posture_unreadable\tthis task records no merge authority, and the registered posture of %s could not be read\n' \
          "$name"
        ;;
    esac
  fi
  if [ "$mode" = direct-PR ]; then
    printf 'unvalidated_delivery\tthis PR ships without a validation run, which standing merge authority never covers; it merges only on an explicit instruction for this PR\n'
  fi
  if [ -n "$hold_kind" ] && [ -n "$hold_reason" ]; then
    case "$hold_kind" in
      captain) printf 'recorded_hold\theld for the captain: %s\n' "$hold_reason" ;;
      external) printf 'recorded_hold\theld on an outside party: %s\n' "$hold_reason" ;;
      *) printf 'recorded_hold\theld (%s): %s\n' "$hold_kind" "$hold_reason" ;;
    esac
  fi
  return 0
}

# The project's registered merge authority: prints on, off, or unregistered, and
# prints unknown when no project name is available. bin/fm-project-mode.sh is
# the one registry parser; --strict is what tells an unregistered project apart
# from one registered without authority.
fm_merge_hold_registry_yolo() {  # <home> <data-dir> <project-name>
  local home=${1-} data=${2-} project=${3-} line status=0
  if [ -z "$project" ]; then
    echo unknown
    return 0
  fi
  line=$(FM_HOME="$home" FM_DATA_OVERRIDE="$data" \
    "$_FM_MERGE_HOLD_LIB_DIR/fm-project-mode.sh" --strict "$project" 2>/dev/null) || status=$?
  case "$status" in
    0) ;;
    3) echo unregistered; return 0 ;;
    *) echo unknown; return 0 ;;
  esac
  case "${line##* }" in
    on) echo on ;;
    off) echo off ;;
    *) echo unknown ;;
  esac
}

# A home whose markdown backlog file does not exist records no holds at all,
# the same reading bin/fm-captain-hold.sh `open` gives it. A file that exists but
# cannot be read is not absent, and is left to the row probe to report.
fm_merge_hold_backlog_absent() {  # <data-dir>
  local data root backend file
  data=$(fm_backlog_data_absolute "$1" 2>/dev/null) || return 1
  root=$(fm_backlog_root "$data" 2>/dev/null) || return 1
  backend=$(fm_tasks_axi_backend "$root" 2>/dev/null) || return 1
  [ "$backend" = markdown ] || return 1
  file=$(fm_backlog_file "$data" 2>/dev/null) || return 1
  [ ! -e "$file" ] && [ ! -L "$file" ]
}

# Read every input for one task and publish its reasons in FM_MERGE_HOLD_REASONS
# (the lines fm_merge_hold_reasons prints, possibly empty). Returns 1 only when
# the task record itself is unreadable. A backlog row that cannot be read adds a
# hold_unreadable line instead of being taken as unheld.
FM_MERGE_HOLD_REASONS=
fm_merge_hold_task() {  # <home> <state-dir> <data-dir> <task-id>
  local home=${1-} state=${2-} data=${3-} id=${4-} meta yolo mode downgrade project registry
  local hold_kind='' hold_reason='' unreadable='' held
  FM_MERGE_HOLD_REASONS=
  meta="$state/$id.meta"
  [ -f "$meta" ] && [ ! -L "$meta" ] || return 1
  yolo=$(grep '^yolo=' "$meta" | tail -1 | cut -d= -f2- || true)
  mode=$(grep '^mode=' "$meta" | tail -1 | cut -d= -f2- || true)
  downgrade=$(grep '^yolo_downgrade_reason=' "$meta" | tail -1 | cut -d= -f2- || true)
  project=$(grep '^project=' "$meta" | tail -1 | cut -d= -f2- || true)
  project=${project%/}
  project=${project##*/}
  registry=$(fm_merge_hold_registry_yolo "$home" "$data" "$project")
  if fm_merge_hold_backlog_absent "$data"; then
    :
  elif fm_backlog_row_probe "$data" "$id"; then
    held=$(printf '%s\n' "$FM_BACKLOG_ROW_STATE" | awk '{print $2}')
    if [ "$held" = yes ] && [ -n "$FM_BACKLOG_ROW_HOLD_KIND" ]; then
      if fm_backlog_row_field "$data" "$id" hold_reason; then
        hold_kind=$FM_BACKLOG_ROW_HOLD_KIND
        hold_reason=$(printf '%s' "$FM_BACKLOG_ROW_FIELD_VALUE" | tr '\n' ' ')
      else
        unreadable="hold_unreadable	the task's backlog row is held, but its recorded hold reason could not be read"
      fi
    fi
  elif [ "$FM_BACKLOG_ROW_RESULT" != not_found ]; then
    unreadable="hold_unreadable	whether a hold is recorded on this task could not be read: ${FM_BACKLOG_ROW_ERROR:-backlog unreadable}"
  fi
  FM_MERGE_HOLD_REASONS=$(fm_merge_hold_reasons "$yolo" "$mode" "$downgrade" "$project" "$registry" "$hold_kind" "$hold_reason")
  if [ -n "$unreadable" ]; then
    FM_MERGE_HOLD_REASONS=${FM_MERGE_HOLD_REASONS:+$FM_MERGE_HOLD_REASONS
}$unreadable
  fi
  return 0
}

# The reasons as one line of text for a refusal or a chat-facing report: the
# texts joined by "; ", empty when nothing holds the task.
fm_merge_hold_summary() {  # <reason-lines>
  printf '%s\n' "${1-}" | awk -F '\t' 'NF >= 2 { out = out (out == "" ? "" : "; ") $2 } END { print out }'
}
