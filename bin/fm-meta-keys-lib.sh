#!/usr/bin/env bash
# Single owner of the key vocabulary of a task record (state/<id>.meta).
#
# A task record is a flat key=value file with several independent producers, and
# each one rewrites only its OWN keys: it strips them and appends them again at
# the end of the file. bin/fm-spawn.sh publishes the spawn-owned block and later
# appends the trace carrier, bin/fm-pr-check.sh appends the PR identity,
# bin/fm-x-lib.sh appends the relay link, bin/fm-promote.sh appends the
# scout-to-ship axes, and bin/fm-captain-hold.sh appends its attestation.
# Whichever producer wrote last therefore owns the tail of the file, so the
# ORDER of a task record's keys is not a contract and no reader may derive
# authority from it. Deriving authority from it cost a live merge watch: a
# relaunch appended its transaction id behind an already recorded pr=, and the
# reader that required the PR identity to be last read firstmate's own write as
# tampering and refused that task's merge poll on every interval.
#
# What a task record does guarantee:
#   * every line is <key>=<value> with the key drawn from this vocabulary, and
#   * no key appears twice, bar the append-only pair below, because
#     bin/fm-backend.sh's fm_meta_get returns the LAST occurrence - so a
#     repeated key silently redefines what every consumer reads, which is the
#     shape tampering with a record takes.
# Both hold whatever order the producers happened to write in, which is what
# lets a reader authenticate a record without knowing who wrote it last.
#
# FM_META_SPAWN_OWNED_KEYS is the subset bin/fm-spawn.sh owns and rewrites on a
# relaunch; FM_META_TASK_RECORD_KEYS is the whole vocabulary and contains it.
# Teaching firstmate to write a new key means adding it here, in the one edit
# that also teaches the relaunch to rewrite it, so a key can never be written by
# one half of the fleet and refused as unknown by the other.
#
# The vocabulary is append-only. A key firstmate has ever written stays listed
# even once no producer writes it, because a home fast-forwards while its tasks
# are in flight and a record written by the previous release outlives it.

# Keys bin/fm-spawn.sh writes and, on a relaunch, replaces from the prior
# record. Its preserve_relaunch_meta strips exactly these before re-emitting
# them, so anything absent here would be duplicated by a relaunch instead. One
# line because it is passed to awk through -v, where a string may not contain a
# newline.
FM_META_SPAWN_OWNED_KEYS="window endpoint_task_id worktree project harness kind mode yolo tasktmp model effort busy_gen spawn_gen traceparent backend herdr_session herdr_workspace_id herdr_tab_id herdr_pane_id zellij_session zellij_tab_id zellij_pane_id orca_worktree_id terminal cmux_workspace_id cmux_surface_id home projects control_relaunch_tx"

# The one exception to "no key appears twice": bin/fm-captain-hold.sh's
# attestation appends a fresh decisions_reviewed/decision_keys pair whenever the
# reviewed inventory changes, rather than rewriting the pair it already wrote, so
# a record attested more than once carries more than one copy and the last is
# the live one. Anything reading a record by key already agrees with that,
# because fm_meta_get returns the last occurrence.
FM_META_APPEND_ONLY_KEYS="decisions_reviewed decision_keys"

# The rest of the vocabulary, by producer:
#   pr, pr_head       bin/fm-pr-check.sh, the canonical PR identity
#   x_*               bin/fm-x-lib.sh, the relay link and its reply context
#   remote_*          bin/fm-spawn.sh, a remotely placed secondmate
#   cleanup_recovery  bin/fm-spawn.sh, an Orca worktree left to reclaim
#   delivers          bin/fm-spawn.sh --delivers at first dispatch, rewritten only
#                     by bin/fm-tasks-axi.sh handback; not spawn-owned, so a
#                     relaunch carries it forward (bin/fm-backlog-transition-lib.sh
#                     MEMBERSHIP owns the contract)
FM_META_TASK_RECORD_KEYS="$FM_META_SPAWN_OWNED_KEYS $FM_META_APPEND_ONLY_KEYS pr pr_head x_request x_request_ts x_followups x_platform x_reply_max_chars remote_host remote_root remote_backend remote_herdr_session remote_target cleanup_recovery delivers"

# The same lists as delimited lookup sets, built once so recognising a key
# costs no process.
FM_META_TASK_RECORD_KEY_SET=" $FM_META_TASK_RECORD_KEYS "
FM_META_APPEND_ONLY_KEY_SET=" $FM_META_APPEND_ONLY_KEYS "

# fm_meta_task_key_known <key>: true when <key> belongs to the task-record
# vocabulary, in any position. An empty key is never known, and a key carrying
# pattern characters is matched literally rather than as a pattern.
fm_meta_task_key_known() {
  [ -n "${1:-}" ] || return 1
  case "$FM_META_TASK_RECORD_KEY_SET" in
    *" $1 "*) return 0 ;;
  esac
  return 1
}

# fm_meta_task_key_repeatable <key>: true when a record may legitimately carry
# more than one <key> line, which only an append-only key above ever may.
fm_meta_task_key_repeatable() {
  [ -n "${1:-}" ] || return 1
  case "$FM_META_APPEND_ONLY_KEY_SET" in
    *" $1 "*) return 0 ;;
  esac
  return 1
}
