#!/usr/bin/env bash
# Record a PR-ready task: store one validated canonical pr=<url> and the forge's
# exact pr_head=<sha> when available, then atomically arm a static merge poll.
# The watcher check source is byte-for-byte bin/fm-pr-poll.sh; task and PR data
# live only in a private sidecar and are never interpolated into shell source.
# A GitHub pull request URL and a GitLab merge request URL are both accepted,
# including a merge request on a self-hosted GitLab instance.
# Binding a PR also captures the pipeline's own proof that it validated this
# head, as state/<task-id>.validation-receipt, so a head that WAS validated
# stays provable for as long as its PR can still merge;
# bin/fm-validation-receipt-lib.sh owns that record and its trust boundary, and
# the capture is best-effort and never fails an armed watch.
# A task record holds one PR and one merge poll, so recording a DIFFERENT PR is
# refused while the recorded one's merge has not been reported: replacing it
# would drop the only watch on a PR that can still merge. The recorded PR's merge
# counts as reported once the task's merge-notification marker names it
# (bin/fm-pr-lib.sh; bin/fm-merge-outcome-lib.sh writes it for a merge this home
# performed and for one its poll detected alike). Re-recording the same PR is
# always allowed. --replace records the new PR anyway, for a recorded PR that
# was superseded (closed without merging) or that cannot be read. The refusal
# happens under the record lock and before any poll artifact or record changes.
# After arming, every registration prints why the PR waits for the captain, one
# `merge-hold: <reason>` line per reason bin/fm-merge-hold-lib.sh derives from
# the task's structured records, or a single `merge: no hold is recorded ...`
# line when nothing on record holds it. Whoever reports the PR relays that
# reason rather than composing one.
# Usage: fm-pr-check.sh <task-id> <pr-url> [--replace]
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-validation-receipt-lib.sh
. "$SCRIPT_DIR/fm-validation-receipt-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-parent-channel-lib.sh
. "$SCRIPT_DIR/fm-parent-channel-lib.sh"
# shellcheck source=bin/fm-merge-hold-lib.sh
. "$SCRIPT_DIR/fm-merge-hold-lib.sh"

REPLACE=0
if [ "$#" -eq 3 ] && [ "$3" = --replace ]; then
  REPLACE=1
elif [ "$#" -ne 2 ]; then
  echo "error: invalid PR check request" >&2
  exit 2
fi
ID=$1
RAW_URL=$2
if ! fm_pr_task_id_valid "$ID" || ! fm_pr_url_parse "$RAW_URL"; then
  echo "error: invalid PR check request" >&2
  exit 2
fi
URL=$FM_PR_URL
PROVIDER=$FM_PR_PROVIDER
HOST=$FM_PR_HOST
PROJECT_PATH=$FM_PR_PATH
NUMBER=$FM_PR_NUMBER

# Task-derived paths are constructed only after the canonical ID validation.
META="$STATE/$ID.meta"
if [ ! -f "$META" ] || [ -L "$META" ] || [ "$(fm_pr_file_link_count "$META")" != 1 ]; then
  echo "error: task metadata is unavailable" >&2
  exit 1
fi

# A prior exact merged result may have queued its durable wake immediately
# before interruption.
# Finish only its identity-bound receipt before publishing a replacement poll.
fm_pr_poll_retirement_recover_one "$STATE" "$ID" "$SCRIPT_DIR/fm-pr-poll.sh" || {
  echo "error: pending PR poll retirement could not be validated" >&2
  exit 1
}

# Refuse to arm a GitLab watch with no glab on PATH. The poll is silent on
# every error by design, so a missing CLI would be indistinguishable from a
# merge request that is never merged. Arming is the one point where that can be
# reported, so the absent tool stops the watch here instead of watching nothing.
if [ "$PROVIDER" = gitlab ] && ! command -v glab >/dev/null 2>&1; then
  echo "error: watching a GitLab merge request requires glab on PATH" >&2
  exit 1
fi

"$FM_ROOT/bin/fm-guard.sh" || true

# pr_head is recorded only when the forge's CLI can supply it. gh exposes the
# head commit as a selectable field; plain glab exposes it only inside its JSON
# output, which would need a JSON processor firstmate does not require, so a
# GitLab task records no pr_head. Both consumers already treat it as optional:
# bin/fm-teardown.sh reads the head from the forge at teardown rather than from
# metadata and falls back to its provider-agnostic content check, and
# bin/fm-review-diff.sh resolves the head from the remote when none is recorded.
# bin/fm-pr-merge.sh reads a GitLab head live at merge time for the same reason,
# and treats a recorded value that disagrees as stale rather than authoritative.
WT=$(grep '^worktree=' "$META" | tail -1 | cut -d= -f2- || true)
PR_HEAD=
if [ "$PROVIDER" = github ] && [ -n "$WT" ] && [ -d "$WT" ] && command -v gh >/dev/null 2>&1; then
  if REMOTE_HEAD=$(cd "$WT" && gh pr view "$URL" --json headRefOid -q .headRefOid 2>/dev/null) \
    && fm_pr_head_valid "$REMOTE_HEAD"; then
    PR_HEAD=$REMOTE_HEAD
  fi
fi

META_TMP=
META_LOCK=
META_LOCK_HELD=0
pr_check_cleanup() {
  fm_pr_poll_cleanup
  [ -z "$META_TMP" ] || rm -f -- "$META_TMP"
  if [ "$META_LOCK_HELD" = 1 ]; then
    fm_lock_release "$META_LOCK" || true
    META_LOCK_HELD=0
  fi
}
trap pr_check_cleanup EXIT
trap 'exit 1' HUP INT TERM
fm_pr_poll_prepare "$STATE" "$ID" "$PROVIDER" "$URL" "$HOST" "$PROJECT_PATH" "$NUMBER" "$SCRIPT_DIR/fm-pr-poll.sh" \
  || { echo "error: could not prepare PR poll" >&2; exit 1; }

META_LOCK=$(fm_meta_lock_path "$META") || exit 1
fm_lock_acquire_wait "$META_LOCK"
META_LOCK_HELD=1
[ -f "$META" ] && [ ! -L "$META" ] && [ "$(fm_pr_file_link_count "$META")" = 1 ] \
  || { echo "error: task metadata is unavailable" >&2; exit 1; }
META_DEVICE=$(fm_pr_file_device "$META") || exit 1
STATE_DEVICE=$(fm_pr_file_device "$STATE") || exit 1
[ "$META_DEVICE" = "$STATE_DEVICE" ] || { echo "error: task metadata is unavailable" >&2; exit 1; }
# Read under the record lock, so no other recording can slip in between this
# verdict and the rewrite below.
RECORDED_URL=$(grep '^pr=' "$META" | tail -1 | cut -d= -f2- || true)
if [ -n "$RECORDED_URL" ] && [ "$REPLACE" = 0 ]; then
  RECORDED_REPORTED=0
  if fm_pr_url_parse "$RECORDED_URL"; then
    if [ "$FM_PR_URL" = "$URL" ]; then
      RECORDED_REPORTED=same
    elif fm_pr_poll_merge_already_notified "$STATE" "$ID" \
      "$FM_PR_PROVIDER" "$FM_PR_HOST" "$FM_PR_PATH" "$FM_PR_NUMBER"; then
      RECORDED_REPORTED=1
    fi
  fi
  if [ "$RECORDED_REPORTED" = 0 ]; then
    echo "error: task $ID already records PR $RECORDED_URL, and no merge of it has been reported; recording $URL would drop the merge watch on a PR that can still merge" >&2
    echo "error: record $URL after that merge is reported, or pass --replace if $RECORDED_URL was superseded (closed without merging)" >&2
    exit 1
  fi
fi
META_TMP=$(mktemp "$STATE/.fm-pr-meta.XXXXXX") || exit 1
while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in
    pr=*|pr_head=*) ;;
    *) printf '%s\n' "$line" >> "$META_TMP" || exit 1 ;;
  esac
done < "$META"
printf 'pr=%s\n' "$URL" >> "$META_TMP" || exit 1
[ -z "$PR_HEAD" ] || printf 'pr_head=%s\n' "$PR_HEAD" >> "$META_TMP" || exit 1
chmod 0600 "$META_TMP" || exit 1
fm_pr_private_file_valid "$META_TMP" 600 "$STATE_DEVICE" || exit 1
fm_pr_metadata_identity_parse "$META_TMP" || exit 1
[ "$FM_PR_META_PROVIDER" = "$PROVIDER" ] && [ "$FM_PR_META_URL" = "$URL" ] \
  && [ "$FM_PR_META_HOST" = "$HOST" ] && [ "$FM_PR_META_PATH" = "$PROJECT_PATH" ] \
  && [ "$FM_PR_META_NUMBER" = "$NUMBER" ] || exit 1
fm_pr_regular_destination_on_device_or_absent "$META" "$STATE_DEVICE" || exit 1
mv -f -- "$META_TMP" "$META" || exit 1
META_TMP=
fm_pr_private_file_valid "$META" 600 "$STATE_DEVICE" || exit 1
fm_pr_metadata_identity_parse "$META" || exit 1
[ "$FM_PR_META_PROVIDER" = "$PROVIDER" ] && [ "$FM_PR_META_URL" = "$URL" ] \
  && [ "$FM_PR_META_HOST" = "$HOST" ] && [ "$FM_PR_META_PATH" = "$PROJECT_PATH" ] \
  && [ "$FM_PR_META_NUMBER" = "$NUMBER" ] || exit 1
fm_lock_release "$META_LOCK"
META_LOCK_HELD=0

fm_pr_poll_publish_prepared || {
  echo "error: could not publish PR poll" >&2
  exit 1
}

# Binding the PR is the one moment the validating run is both known and newest,
# so the pipeline's verdict for this head is persisted here rather than left to
# be looked up again whenever the captain gets round to merging.
# bin/fm-validation-receipt-lib.sh owns the candidate rule, the record's proof
# rule, and the receipt format. This is best-effort by design: it never fails an
# armed watch, and a head with no receipt still merges on the pipeline's own
# record. Nothing is reported when no run proves this head, because
# bin/fm-pr-merge.sh's own gate names the missing evidence per candidate at the
# moment it decides, which is the moment that can act on it. A task that ships
# direct-PR or local-only has no run behind it by definition and is skipped.
# One owner for writing a proving run's receipt and reporting the outcome, so
# the freshest-run fast path below and the general candidate walk report the
# same way.
record_proving_run() {  # <run>
  local run=$1
  if fm_validation_receipt_write "$STATE" "$ID" \
    "$PROVIDER" "$HOST" "$PROJECT_PATH" "$NUMBER" \
    "$FM_VALIDATION_PROOF_HEAD" "$FM_VALIDATION_PROOF_BRANCH" "$run"; then
    printf 'recorded: no-mistakes run %s validated head %s of %s\n' \
      "$run" "$FM_VALIDATION_PROOF_HEAD" "$URL" >&2
  else
    printf 'actionable: no-mistakes run %s validated head %s of %s, but its validation receipt could not be recorded\n' \
      "$run" "$FM_VALIDATION_PROOF_HEAD" "$URL" >&2
  fi
}
capture_validation_receipt() {
  local mode run timeout freshest existing_run=''
  mode=$(grep '^mode=' "$META" | tail -1 | cut -d= -f2- || true)
  case "$mode" in direct-PR|local-only) return 0 ;; esac
  fm_validation_receipt_remove_other "$STATE" "$ID" \
    "$PROVIDER" "$HOST" "$PROJECT_PATH" "$NUMBER" || true
  freshest=$(fm_validation_status_freshest_bound_run "$STATE/$ID.status" "$URL")
  # bin/fm-pr-merge.sh re-records the PR through this script before its own
  # validation gate, so re-binding a head that already has its receipt must
  # cost nothing when the log has reported no run since the receipt's own -
  # rather than re-reading every candidate run record on every merge attempt.
  # A same-URL re-registration that DOES report a newer run beside this pull
  # request skips this fast path so the receipt can refresh to it below, even
  # when the head is unchanged: the worker can re-validate the same commit
  # under a new run id, and the receipt should name the run the captain would
  # recognise from the ready line rather than a superseded one.
  if [ -n "$PR_HEAD" ] \
    && fm_validation_receipt_read "$STATE" "$ID" "$PROVIDER" "$HOST" "$PROJECT_PATH" "$NUMBER"; then
    existing_run=$FM_VALIDATION_RECEIPT_RUN
    if [ "$FM_VALIDATION_RECEIPT_HEAD" = "$(printf '%s' "$PR_HEAD" | tr '[:upper:]' '[:lower:]')" ] \
      && { [ -z "$freshest" ] || [ "$freshest" = "$existing_run" ]; }; then
      return 0
    fi
  fi
  command -v no-mistakes >/dev/null 2>&1 || return 0
  timeout=$(fm_validation_nm_timeout)
  if [ -n "$freshest" ] && [ "$freshest" != "$existing_run" ] \
    && fm_validation_run_record_proves "$STATE" "$timeout" "$freshest" "$URL" '' "$PR_HEAD"; then
    record_proving_run "$freshest"
    return 0
  fi
  while IFS= read -r run || [ -n "$run" ]; do
    [ -n "$run" ] || continue
    [ "$run" != "$freshest" ] || continue
    # The pull request's head branch is not read here; the receipt stores the
    # run record's own branch and the merge gate checks it against the forge's
    # head branch at merge time, live.
    if fm_validation_run_record_proves "$STATE" "$timeout" "$run" "$URL" '' "$PR_HEAD"; then
      record_proving_run "$run"
      return 0
    fi
  done <<CANDIDATES
$(fm_validation_run_candidates "$STATE" "$ID" "$META" "$URL" \
  "$PROVIDER" "$HOST" "$PROJECT_PATH" "$NUMBER" || true)
CANDIDATES
}
capture_validation_receipt || true

# Why this PR waits for the captain, from structured records only
# (bin/fm-merge-hold-lib.sh). An unreadable task record at this point is not a
# reason to fail an armed watch, so it is reported as unexplained instead.
MERGE_HOLD_REASONS=
if fm_merge_hold_task "$FM_HOME" "$STATE" "$DATA" "$ID"; then
  MERGE_HOLD_REASONS=$FM_MERGE_HOLD_REASONS
else
  MERGE_HOLD_REASONS="hold_unreadable	the task record could not be read to explain whether this PR is held"
fi
MERGE_HOLD_SUMMARY=$(fm_merge_hold_summary "$MERGE_HOLD_REASONS")

# In a secondmate home the registration itself is a captain-facing fact:
# publish the child's PR-ready line with the canonical URL just recorded, so it
# reaches the parent whether or not the mate model appends anything
# (bin/fm-parent-channel-lib.sh). A main home has no channel and this is a
# silent no-op there. The poll is armed either way; a channel that cannot be
# written is reported as actionable, and bin/fm-inactive-reconcile.sh still
# delivers the child's own ready line on the next supervision poll. The line
# carries the hold reason, which can change between registrations; every
# registration call publishes it, and the channel's own at-most-once-by-
# content dedup absorbs an unchanged repeat while still delivering a retry
# after a publish that failed to land.
READY_LINE="done [key=child-pr-$ID]: child $ID PR ready: $URL"
PR_MODE=$(grep '^mode=' "$META" | tail -1 | cut -d= -f2- || true)
PR_YOLO=$(grep '^yolo=' "$META" | tail -1 | cut -d= -f2- || true)
[ -z "$PR_MODE" ] || READY_LINE="$READY_LINE mode=$(fm_parent_channel_clean_note "$PR_MODE")"
[ -z "$PR_YOLO" ] || READY_LINE="$READY_LINE yolo=$(fm_parent_channel_clean_note "$PR_YOLO")"
[ -z "$MERGE_HOLD_SUMMARY" ] || READY_LINE="$READY_LINE held: $(fm_parent_channel_clean_note "$MERGE_HOLD_SUMMARY")"
READY_RC=0
fm_parent_channel_report "$FM_HOME" "$STATE" "$READY_LINE" || READY_RC=$?
case "$READY_RC" in
  0|1) ;;
  *) printf 'actionable: PR %s is registered but its ready line did not reach the parent channel (rc=%s)\n' "$URL" "$READY_RC" >&2 ;;
esac
if [ -n "$MERGE_HOLD_REASONS" ]; then
  printf '%s\n' "$MERGE_HOLD_REASONS" | while IFS='	' read -r _kind text; do
    [ -n "$text" ] || continue
    printf 'merge-hold: %s\n' "$text"
  done
else
  printf 'merge: no hold is recorded; standing merge authority covers this PR once it is green and validated\n'
fi
printf 'armed: state/%s.check.sh\n' "$ID"
