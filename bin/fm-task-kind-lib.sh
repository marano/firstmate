#!/usr/bin/env bash
# fm-task-kind-lib.sh - the single owner of the `kind=` vocabulary that
# bin/fm-spawn.sh records in state/<id>.meta, and of which of those kinds is a
# work item rather than a standing role.
#
# Sourced, never executed.
#
# WHY THIS EXISTS. The vocabulary used to be implicit: bin/fm-spawn.sh wrote
# ship, scout, or secondmate, and every reader re-stated for itself which of
# those it cared about. bin/fm-idle-fleet-lib.sh re-stated it as the pair
# ('' and `task`) - two values fm-spawn has never written - so its in-progress
# count was structurally zero, and the idle-fleet alarm fired on a fleet with two
# workers actively working. A second list that nothing forces to agree with the
# writer is the defect; one owner both sides consult is the fix.
#
# HOW DRIFT IS PREVENTED, from both sides:
#   - bin/fm-spawn.sh validates the kind it is about to record against
#     fm_task_kind_known below and refuses rather than writing an unregistered
#     one, so a kind cannot reach a meta record without passing through here.
#     That matters most on the relaunch path, where the kind is INHERITED from an
#     existing record rather than chosen by a flag.
#   - tests/fm-idle-fleet.test.sh pins fm_task_kinds' exact membership, so
#     registering a new kind reds until someone states whether it is work.
#
# WHY THE WORK PREDICATE EXCLUDES RATHER THAN ALLOWS. fm_task_kind_is_work names
# the kinds that are NOT work and counts everything else, which is the opposite
# shape from the allowlist that shipped the bug. It is chosen for its failure
# DIRECTION: should a kind ever escape both guards above, an allowlist under-counts
# work in progress and the idle-fleet alarm cries wolf at a busy fleet, while
# exclusion over-counts and the alarm merely stays quiet. A false alarm trains its
# reader to ignore every later one; a missed alarm costs only that alarm.
set -u

# Every kind bin/fm-spawn.sh can record, space-separated.
# `ship` is also what an absent kind= means: it is the default a spawn takes with
# no --scout or --secondmate, and the fallback a relaunch applies to a record
# written before kind= existed.
fm_task_kinds() {
  printf 'ship scout secondmate\n'
}

# 0 when <kind> is one this repo records, 1 otherwise. An EMPTY kind is known: it
# is how a pre-kind= record spells `ship`.
fm_task_kind_known() {  # <kind>
  local kind=${1-} known
  [ -n "$kind" ] || return 0
  for known in $(fm_task_kinds); do
    [ "$kind" = "$known" ] || continue
    return 0
  done
  return 1
}

# 0 when a meta record of <kind> is a work item that occupies a task slot, 1 when
# it is not. An empty kind is `ship`, so it is work.
#
# `secondmate` is the only kind that is not work: a persistent secondmate is a
# standing role with its own home and charter, never a backlog item, and it holds
# no slot in the count the idle-fleet alarm compares against capacity
# (AGENTS.md sections 6 and 10).
fm_task_kind_is_work() {  # <kind>
  case "${1-}" in
    secondmate) return 1 ;;
    *) return 0 ;;
  esac
}
