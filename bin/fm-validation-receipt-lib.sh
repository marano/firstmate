#!/usr/bin/env bash
# ONE owner for the evidence that the no-mistakes pipeline validated a pull
# request's head: which run records are candidates for a given pull request,
# what a record must say to prove a head, and the durable receipt that keeps
# that proof reachable after the pipeline's own record stops answering.
#
# bin/fm-pr-check.sh captures a receipt when it binds a PR; bin/fm-pr-merge.sh
# consumes both surfaces at the merge gate and owns the --unvalidated waiver;
# bin/fm-teardown.sh removes the receipt with the task's other PR artifacts.
#
# WHY THE CANDIDATE LIST IS BOUND TO THE PULL REQUEST.
# Every source firstmate used to reach a run record was keyed on the LANE'S
# MOST RECENT ACTIVITY rather than on the pull request being merged:
#   - the last run=<id> token anywhere in the task's status log, so the newest
#     run a multi-PR lane reported hid every earlier one, and a ready line that
#     carried no id at all silently resolved to some other pull request's run;
#   - `no-mistakes axi status` in the task's recorded local copy, which answers
#     for whichever branch that copy currently sits on and for that branch's
#     newest run.
# Both go stale the moment a lane ships a second pull request, so the more work
# a lane delivers the more certainly its earlier pull requests become
# unprovable. The worker's mandated ready line
# `done: PR <url> checks green run=<id>` already carries the pull request and
# its run id on ONE line, and fm_validation_run_candidates below keeps that
# binding instead of discarding it. Its order is the durable receipt's own id
# first, then the ids reported beside THIS pull request, then every other id in
# the log, then the local copy. The receipt leads because it is firstmate's own
# binding for exactly this pull request AND because the merge gate's fallback
# to it is conditional on having read its record, so that read must never be
# the one the cap discards. The number of candidates read is capped
# (_FM_VALIDATION_CANDIDATE_CAP) so a long log cannot turn one merge into an
# unbounded number of bounded pipeline reads.
# A status line is prose, so the ready line's `run=<id>` token routinely sits
# right up against trailing text with no space, as in the worker's own
# `run=<id>; loaded slow-composer 15/15 ...`. _fm_validation_strip_trailing_punct
# strips exactly one trailing sentence-punctuation character before an id is
# validated, so that token still yields the id instead of an invalid one that
# fm_validation_run_id_valid rejects outright - PR 88 (2026-09-23) was refused
# for exactly this reason, with the newer run's id dropped from BOTH tiers
# because both read it through the same extraction.
#
# Widening the candidate list cannot widen what counts as proof. A candidate id
# is only a POINTER: fm_validation_run_record_proves below independently
# requires the pipeline's own record to name this exact canonical pull request,
# this head branch, this exact head sha, and completed review and test steps
# with no other step failed. An id that reaches a record proving something else
# proves nothing here.
#
# THE DURABLE RECEIPT, AND ITS EXACT TRUST BOUNDARY.
# Pointing correctly is not enough on its own. A pipeline that stops answering
# for an older run - through record retention, a reset store, or a daemon that
# simply no longer has it - would leave a head that WAS validated unprovable,
# however well firstmate points at it. So when
# bin/fm-pr-check.sh binds a pull request - while the record is newest and
# certain to answer - it persists the verdict it just read:
#   state/<task-id>.validation-receipt
#   fm-validation-receipt-v1
#   <provider>
#   <host>
#   <path>
#   <number>
#   <head-sha>                 the run record's own head_sha
#   <branch>                   the run record's own branch
#   <run-id>
# Every field but the identity comes from the pipeline's own record, never from
# a worker's assertion: the receipt is written only after
# fm_validation_run_record_proves accepted that record, and a run id that
# reaches no proving record produces no receipt. The file is published
# atomically, mode 0600, single-link, on the state filesystem, and revalidated
# after the move, like state/<task-id>.merge-authority
# (bin/fm-merge-authority-lib.sh). One writer owns it, so it needs no lock:
# publication is a rename, and a reader sees the old record or the new one.
#
# The receipt is deliberately WEAKER evidence than the record, and the merge
# gate treats it that way: it answers only where the pipeline's own record for
# its own run id could not be read at all. A record that still answers always
# decides, so a receipt can never overrule a record that contradicts it, and
# the receipt's reach is exactly the window where nothing else can speak.
# What the receipt does NOT defend against is a writer with arbitrary access to
# firstmate's private state directory; it inherits the same trust as the task's
# own metadata and merge-authority record. That is a real boundary and is not
# the one the merge gate exists to hold. The rejected PR-body attestation is
# different in kind: the worker authors its pull request body by design and
# firstmate tells it to, so a body is a worker's claim about itself, while this
# receipt is firstmate's own record of a pipeline verdict firstmate read.
#
# Sourced by those scripts and by tests. No side effects on source beyond its
# sourced libraries.

_FM_VALIDATION_RECEIPT_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-pr-lib.sh
. "$_FM_VALIDATION_RECEIPT_LIB_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-nm-run-lib.sh
. "$_FM_VALIDATION_RECEIPT_LIB_DIR/fm-nm-run-lib.sh"

# The newest status-log lines scanned for run ids. Status appends are sparse
# supervisor-actionable events, so this reaches far past any real lane's ready
# lines while keeping the read bounded on a log that was appended to in a loop.
_FM_VALIDATION_STATUS_LINE_CAP=400
# The most run records one gate reads. Ids bound to this pull request are taken
# first, so the cap only ever discards the last-resort tiers.
_FM_VALIDATION_CANDIDATE_CAP=6

# shellcheck disable=SC2034 # Public results consumed by sourcing callers.
FM_VALIDATION_PROOF_REASON=
# shellcheck disable=SC2034 # Public results consumed by sourcing callers.
FM_VALIDATION_PROOF_HEAD=
# shellcheck disable=SC2034 # Public results consumed by sourcing callers.
FM_VALIDATION_PROOF_BRANCH=
# shellcheck disable=SC2034 # Public results consumed by sourcing callers.
FM_VALIDATION_PROOF_UNREADABLE=0
# shellcheck disable=SC2034 # Public results consumed by sourcing callers.
FM_VALIDATION_RECEIPT_HEAD=
# shellcheck disable=SC2034 # Public results consumed by sourcing callers.
FM_VALIDATION_RECEIPT_BRANCH=
# shellcheck disable=SC2034 # Public results consumed by sourcing callers.
FM_VALIDATION_RECEIPT_RUN=

# Seconds bounding each pipeline read. One knob governs the capture and the
# merge gate alike, because they read the same records the same way.
fm_validation_nm_timeout() {
  local secs=${FM_PR_MERGE_NM_TIMEOUT:-20}
  case "$secs" in ''|*[!0-9]*) secs=20 ;; esac
  printf '%s' "$secs"
}

fm_validation_receipt_path() {  # <state> <task-id>
  printf '%s/%s.validation-receipt' "$1" "$2"
}

fm_validation_run_id_valid() {  # <run-id>
  local run=${1-}
  local LC_ALL=C
  case "$run" in ''|*[!A-Za-z0-9_-]*) return 1 ;; esac
  [ "${#run}" -le 64 ]
}

fm_validation_branch_valid() {  # <branch>
  local branch=${1-}
  local LC_ALL=C
  case "$branch" in ''|*[!A-Za-z0-9._/-]*) return 1 ;; esac
  [ "${#branch}" -le 255 ]
}

# 0 when the pipeline's own record for run $3, read from directory $1 within $2
# seconds, proves pull request $4. $5 is the pull request's head branch, empty
# when the forge did not name one. $6 is the head that must match exactly,
# empty at capture time, where the record's own head_sha is the answer rather
# than something to check. On success the record's head and branch are exported
# for the caller to persist; on failure FM_VALIDATION_PROOF_REASON is one plain
# sentence naming the first piece of evidence the record lacks, and
# FM_VALIDATION_PROOF_UNREADABLE is 1 only when no record came back at all.
fm_validation_run_record_proves() {  # <dir> <timeout> <run-id> <url> <head-branch> <expected-head>
  local dir=$1 timeout=$2 run=$3 url=$4 branch=$5 expected_head=${6:-}
  local out rc=0 pr canon run_branch run_head row step rest status
  local saw_review=0 saw_test=0 incomplete='' failed=''
  FM_VALIDATION_PROOF_REASON=
  FM_VALIDATION_PROOF_HEAD=
  FM_VALIDATION_PROOF_BRANCH=
  FM_VALIDATION_PROOF_UNREADABLE=0
  out=$(fm_nm_run_bounded "$dir" "$timeout" axi status --run "$run" 2>&1) || rc=$?
  if [ "$rc" -ne 0 ] || [ -z "$out" ]; then
    out=$(printf '%s\n' "$out" | head -1)
    FM_VALIDATION_PROOF_REASON="run $run could not be read from no-mistakes${out:+ ($out)}"
    # shellcheck disable=SC2034 # Public results consumed by sourcing callers.
    FM_VALIDATION_PROOF_UNREADABLE=1
    return 1
  fi
  if [ "$(fm_nm_strip_quotes "$(fm_nm_field "$out" id)")" != "$run" ]; then
    FM_VALIDATION_PROOF_REASON="no-mistakes answered for run $run with a record that does not carry that id"
    return 1
  fi
  pr=$(fm_nm_strip_quotes "$(fm_nm_field "$out" pr)")
  # Parsed in a subshell because fm_pr_url_parse publishes the caller's
  # FM_PR_* identity, which the merge gate is still holding.
  canon=$(fm_pr_url_parse "$pr" && printf '%s' "$FM_PR_URL") || canon=
  if [ -z "$canon" ] || [ "$canon" != "$url" ]; then
    FM_VALIDATION_PROOF_REASON="run $run is for ${pr:-no pull request}, not $url"
    return 1
  fi
  run_branch=$(fm_nm_strip_quotes "$(fm_nm_field "$out" branch)")
  if [ -n "$branch" ] && [ "$run_branch" != "$branch" ]; then
    FM_VALIDATION_PROOF_REASON="run $run validated branch ${run_branch:-unknown}, not the pull request's head branch $branch"
    return 1
  fi
  run_head=$(fm_nm_strip_quotes "$(fm_nm_field "$out" head_sha)" | tr '[:upper:]' '[:lower:]')
  if [ -n "$expected_head" ]; then
    if [ "$run_head" != "$(printf '%s' "$expected_head" | tr '[:upper:]' '[:lower:]')" ]; then
      FM_VALIDATION_PROOF_REASON="run $run validated head ${run_head:-unknown}, not the pull request's current head $expected_head"
      return 1
    fi
  elif ! fm_pr_head_valid "$run_head"; then
    FM_VALIDATION_PROOF_REASON="run $run names no head commit to bind a receipt to"
    return 1
  fi
  while IFS= read -r row; do
    row=$(fm_nm_trim "$row")
    [ -n "$row" ] || continue
    step=$(fm_nm_trim "${row%%,*}")
    rest=${row#*,}
    status=$(fm_nm_strip_quotes "${rest%%,*}")
    case "$step" in
      ci) continue ;;
      review|test)
        [ "$step" = review ] && saw_review=1 || saw_test=1
        [ "$status" = completed ] || incomplete="${incomplete:+$incomplete, }$step (${status:-no status})"
        ;;
      *)
        [ "$status" != failed ] || failed="${failed:+$failed, }$step (failed)"
        ;;
    esac
  done <<ROWS
$(fm_nm_steps_rows "$out")
ROWS
  if [ "$saw_review" -ne 1 ] || [ "$saw_test" -ne 1 ]; then
    FM_VALIDATION_PROOF_REASON="run $run's record lists no review and test steps"
    return 1
  fi
  if [ -n "$incomplete" ]; then
    FM_VALIDATION_PROOF_REASON="run $run did not complete its review and test steps: $incomplete"
    return 1
  fi
  if [ -n "$failed" ]; then
    # shellcheck disable=SC2034 # Public results consumed by sourcing callers.
    FM_VALIDATION_PROOF_REASON="run $run has failed steps: $failed"
    return 1
  fi
  # shellcheck disable=SC2034 # Public results consumed by sourcing callers.
  FM_VALIDATION_PROOF_HEAD=$run_head
  # shellcheck disable=SC2034 # Public results consumed by sourcing callers.
  FM_VALIDATION_PROOF_BRANCH=$run_branch
}

# The canonical form of one whitespace-delimited status-log token, with any
# single trailing sentence-punctuation character removed, because a status
# line is prose and a token routinely sits right before a comma, semicolon,
# colon, period, or closing paren with no space - the worker's mandated ready
# line `done: PR <url> checks green run=<id>; loaded slow-composer 15/15 ...`
# is exactly this shape. The one owner for that stripping, shared by the URL
# and run-id readers below so trailing prose is handled identically for both.
_fm_validation_strip_trailing_punct() {  # <token>
  printf '%s' "${1%%[.,;:)]}"
}

# The canonical form of one whitespace-delimited status-log field, or nothing.
_fm_validation_field_url() {  # <field> <canonical-url>
  local field url=$2
  field=$(_fm_validation_strip_trailing_punct "$1")
  [ "$field" != "$url" ] || { printf '%s' "$url"; return 0; }
  case "$field" in
    https://*/pull/*|https://*/-/merge_requests/*) ;;
    *) return 0 ;;
  esac
  ( fm_pr_url_parse "$field" && printf '%s' "$FM_PR_URL" ) 2>/dev/null || true
}

# Run ids the task's status log names, newest first, in two tiers printed one
# per line: ids reported on a line that also names this pull request, then
# every other id. The header above owns why that tiering is the fix. Optional
# $3 "bound-only" prints only the first tier, so a same-URL re-registration
# can ask what the log reports beside THIS pull request without paying for a
# scan of every other id in the log.
_fm_validation_status_run_ids() {  # <status-log> <canonical-url> [bound-only]
  local log=$1 url=$2 bound_only=${3:-} line field id names_pr ids i
  local bound='' other=''
  local -a lines=() fields=()
  [ -f "$log" ] && [ ! -L "$log" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    lines+=("$line")
  done < <(tail -n "$_FM_VALIDATION_STATUS_LINE_CAP" "$log" 2>/dev/null)
  for (( i=${#lines[@]}-1; i>=0; i-- )); do
    names_pr=0
    ids=''
    # read -ra splits on whitespace without globbing, so a status line
    # containing a shell metacharacter is data rather than a pattern.
    read -ra fields <<< "${lines[i]}"
    for field in ${fields[@]+"${fields[@]}"}; do
      case "$field" in
        run=*)
          id=$(_fm_validation_strip_trailing_punct "${field#run=}")
          fm_validation_run_id_valid "$id" || continue
          ids="${ids:+$ids }$id"
          ;;
        https://*)
          [ "$(_fm_validation_field_url "$field" "$url")" = "$url" ] && names_pr=1
          ;;
      esac
    done
    [ -n "$ids" ] || continue
    if [ "$names_pr" -eq 1 ]; then
      bound="${bound:+$bound }$ids"
    else
      other="${other:+$other }$ids"
    fi
  done
  for id in $bound; do
    printf '%s\n' "$id"
  done
  [ -z "$bound_only" ] || return 0
  for id in $other; do
    printf '%s\n' "$id"
  done
}

# The single freshest run id the status log reports on a line that also names
# pull request $2, or nothing when no such line exists. This is what a
# same-URL re-registration treats as "a newer run reported beside the PR",
# for fm-pr-check.sh's receipt refresh below.
fm_validation_status_freshest_bound_run() {  # <status-log> <canonical-url>
  _fm_validation_status_run_ids "$1" "$2" bound-only | head -1
}

# The run no-mistakes reports for the task's recorded local copy, or nothing.
# Last of the candidate tiers: it answers for whichever branch that copy
# currently sits on, which is the lane's present rather than this pull
# request's past.
_fm_validation_local_copy_run_id() {  # <meta> <timeout>
  local meta=$1 timeout=$2 wt out id
  [ -f "$meta" ] && [ ! -L "$meta" ] || return 0
  wt=$(grep '^worktree=' "$meta" | tail -1 | cut -d= -f2- || true)
  [ -n "$wt" ] && [ -d "$wt" ] || return 0
  out=$(fm_nm_run_checked "$wt" "$timeout" axi status) || return 0
  id=$(fm_nm_strip_quotes "$(fm_nm_field "$out" id)")
  [ -n "$id" ] || return 0
  printf '%s\n' "$id"
}

# Candidate run ids for pull request $4, best first, one per line, deduplicated
# and capped. The header above owns the order and why the receipt's own id
# leads it.
fm_validation_run_candidates() {  # <state> <task-id> <meta> <canonical-url> <provider> <host> <path> <number>
  local state=$1 id=$2 meta=$3 url=$4 provider=$5 host=$6 path=$7 number=$8
  local timeout run seen='' count=0
  timeout=$(fm_validation_nm_timeout)
  {
    if fm_validation_receipt_read "$state" "$id" "$provider" "$host" "$path" "$number"; then
      printf '%s\n' "$FM_VALIDATION_RECEIPT_RUN"
    fi
    _fm_validation_status_run_ids "$state/$id.status" "$url"
    _fm_validation_local_copy_run_id "$meta" "$timeout"
  } | while IFS= read -r run || [ -n "$run" ]; do
    fm_validation_run_id_valid "$run" || continue
    case " $seen " in *" $run "*) continue ;; esac
    seen="$seen $run"
    printf '%s\n' "$run"
    count=$((count + 1))
    [ "$count" -lt "$_FM_VALIDATION_CANDIDATE_CAP" ] || break
  done
}

# 0 when receipt $1 is a well-formed record for exactly this pull request.
_fm_validation_receipt_record_matches() {  # <record> <device> <provider> <host> <path> <number>
  local record=$1 device=$2 provider=$3 host=$4 path=$5 number=$6
  local version rec_provider rec_host rec_path rec_number head branch run _extra
  FM_VALIDATION_RECEIPT_HEAD=
  FM_VALIDATION_RECEIPT_BRANCH=
  FM_VALIDATION_RECEIPT_RUN=
  fm_pr_private_file_valid "$record" 600 "$device" || return 1
  exec 9< "$record" || return 1
  IFS= read -r version <&9 || { exec 9<&-; return 1; }
  IFS= read -r rec_provider <&9 || { exec 9<&-; return 1; }
  IFS= read -r rec_host <&9 || { exec 9<&-; return 1; }
  IFS= read -r rec_path <&9 || { exec 9<&-; return 1; }
  IFS= read -r rec_number <&9 || { exec 9<&-; return 1; }
  IFS= read -r head <&9 || { exec 9<&-; return 1; }
  IFS= read -r branch <&9 || { exec 9<&-; return 1; }
  IFS= read -r run <&9 || { exec 9<&-; return 1; }
  if IFS= read -r _extra <&9; then
    exec 9<&-
    return 1
  fi
  exec 9<&-
  [ "$version" = fm-validation-receipt-v1 ] || return 1
  [ "$rec_provider" = "$provider" ] && [ "$rec_host" = "$host" ] \
    && [ "$rec_path" = "$path" ] && [ "$rec_number" = "$number" ] || return 1
  fm_pr_head_valid "$head" || return 1
  fm_validation_branch_valid "$branch" || return 1
  fm_validation_run_id_valid "$run" || return 1
  FM_VALIDATION_RECEIPT_HEAD=$head
  FM_VALIDATION_RECEIPT_BRANCH=$branch
  FM_VALIDATION_RECEIPT_RUN=$run
}

fm_validation_receipt_read() {  # <state> <task-id> <provider> <host> <path> <number>
  local state=$1 id=$2 provider=$3 host=$4 path=$5 number=$6 record state_device
  # shellcheck disable=SC2034 # Public results consumed by sourcing callers.
  FM_VALIDATION_RECEIPT_HEAD=
  # shellcheck disable=SC2034 # Public results consumed by sourcing callers.
  FM_VALIDATION_RECEIPT_BRANCH=
  FM_VALIDATION_RECEIPT_RUN=
  fm_pr_task_id_valid "$id" || return 1
  [ -d "$state" ] && [ ! -L "$state" ] || return 1
  state_device=$(fm_pr_file_device "$state") || return 1
  record=$(fm_validation_receipt_path "$state" "$id")
  [ -e "$record" ] || return 1
  _fm_validation_receipt_record_matches "$record" "$state_device" \
    "$provider" "$host" "$path" "$number"
}

fm_validation_receipt_write() {  # <state> <task-id> <provider> <host> <path> <number> <head> <branch> <run>
  local state=$1 id=$2 provider=$3 host=$4 path=$5 number=$6
  local head=$7 branch=$8 run=$9
  local record tmp='' state_device status=0 prior_umask
  fm_pr_task_id_valid "$id" || return 1
  fm_pr_head_valid "$head" || return 1
  fm_validation_branch_valid "$branch" || return 1
  fm_validation_run_id_valid "$run" || return 1
  [ -n "$provider" ] && [ -n "$host" ] && [ -n "$path" ] && [ -n "$number" ] || return 1
  [ -d "$state" ] && [ ! -L "$state" ] || return 1
  state_device=$(fm_pr_file_device "$state") || return 1
  record=$(fm_validation_receipt_path "$state" "$id")
  fm_pr_regular_destination_on_device_or_absent "$record" "$state_device" || return 1
  # Scoped, because this library is sourced into scripts that keep writing
  # their own files after the capture returns.
  prior_umask=$(umask)
  umask 077
  tmp=$(mktemp "$state/.fm-validation-receipt.XXXXXX") || { umask "$prior_umask"; return 1; }
  umask "$prior_umask"
  printf '%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n' \
    fm-validation-receipt-v1 "$provider" "$host" "$path" "$number" \
    "$head" "$branch" "$run" > "$tmp" || status=1
  if [ "$status" -eq 0 ]; then
    chmod 0600 "$tmp" \
      && _fm_validation_receipt_record_matches "$tmp" "$state_device" \
        "$provider" "$host" "$path" "$number" \
      && fm_pr_regular_destination_on_device_or_absent "$record" "$state_device" \
      && mv -f -- "$tmp" "$record" \
      && _fm_validation_receipt_record_matches "$record" "$state_device" \
        "$provider" "$host" "$path" "$number" \
      || status=1
  fi
  [ "$status" -eq 0 ] || rm -f -- "$tmp"
  return "$status"
}

# Drop a receipt this task carries for a DIFFERENT pull request, so a rebound
# task never leaves an identity-mismatched record behind the new one.
fm_validation_receipt_remove_other() {  # <state> <task-id> <provider> <host> <path> <number>
  local state=$1 id=$2 provider=$3 host=$4 path=$5 number=$6 record
  fm_pr_task_id_valid "$id" || return 0
  [ -d "$state" ] && [ ! -L "$state" ] || return 0
  record=$(fm_validation_receipt_path "$state" "$id")
  [ -e "$record" ] || [ -L "$record" ] || return 0
  if fm_validation_receipt_read "$state" "$id" "$provider" "$host" "$path" "$number"; then
    return 0
  fi
  rm -f -- "$record"
}
