#!/usr/bin/env bash
# fm-task-inbox-lib.sh - the per-task steering inbox: durable records plus a
# constant doorbell.
#
# ONE owner of the steering-inbox contract: the record format, sequence
# allocation, the idempotent re-enqueue dedup, the handled/ acknowledgement,
# the self-describing doorbell line, and the watcher's re-ring ladder policy.
# bin/fm-send.sh writes and rings locally, the host-local remote steer leg
# (bin/fm-remote-secondmate-control.sh cmd_send) writes idempotently and rings
# on the remote host, bin/fm-watch.sh polls and re-rings, and the brief
# scaffold (bin/fm-brief.sh) tells the worker how to read and acknowledge;
# none of them restates the format.
#
# Design (captain-adopted, data/fm-send-reliability-reframe-s1/report.md): the
# payload moves to the filesystem, which is reliable; the terminal carries only
# a short constant doorbell line. While the endpoint remains available, that
# line does not need to be reliable because ringing it again is free. A
# duplicated doorbell is a no-op by construction (the worker finds the inbox
# empty or already handled), and a swallowed doorbell is detected by the
# absence of the worker's acknowledgement and re-rung on a bounded schedule.
# A positively dead or missing endpoint bypasses that schedule without being
# typed into, and its unhandled record surfaces through the ordinary stale wake
# into stuck-crewmate-recovery.
#
# Layout under <state-dir>:
#   <task>.inbox/NNN.msg       one durable steer, numeric sequence, atomic rename
#   <task>.inbox/handled/      the worker's `mv` here IS the acknowledgement
#   <task>.inbox/.seq.lock     serializes sequence allocation across writers
#                              (the session and the away daemon)
#   <task>.inbox/.ring-state   watcher re-ring ladder:
#                              "<msg>\t<count>\t<epoch>\t<stuck>\t<busy-since>\t<stuck-kind>",
#                              where <stuck> counts the latest consecutive
#                              attempts that found the composer holding unsent
#                              text, <busy-since> is the epoch at which the
#                              current unbroken run of busy observations started
#                              (0 when the pane is not in one), and <stuck-kind>
#                              names which stuck state the LATEST attempt found:
#                              `own`, `other`, or `none` (not stuck). A record
#                              written before a field existed reads it as
#                              absent: the busy run starts at the next busy
#                              observation, and the kind reads `other`, so an
#                              older ladder can never reach the input-dead
#                              escalation without a fresh positive proof.
#   <task>.inbox/.escalated    oldest-message name already surfaced as stale,
#                              so later polls suppress another escalation
#
# Record format (fm_task_inbox_write / fm_task_inbox_body):
#   schema=fm-task-inbox.v1
#   at=<utc timestamp>
#   delivery=fire-and-forget   present only when the re-ring ladder must ignore it
#   --
#   <exact message text; newlines are legal; a marked secondmate request keeps
#    its from-firstmate marker and corr token verbatim in this body>
#
# Sequence numbers are never reused within a task: allocation scans both the
# inbox root and handled/, so a message is processed at most once per worker
# lifetime even if every doorbell is duplicated. Concurrent writers serialize
# on .seq.lock; the worst racing outcome is ordering, never loss.
#
# Re-ring ladder (fm_task_inbox_due_action): an unhandled message older than
# FM_TASK_INBOX_GRACE_SECS is due one delivery attempt per grace period; an
# attempt may ring or be skipped to protect proven pending composer text. After
# FM_TASK_INBOX_RING_MAX attempts without an acknowledgement it escalates. The
# caller owns the busy and recovery-grade endpoint checks: a busy pane defers
# its doorbell through fm_task_inbox_busy_action below, while a positively dead
# or missing endpoint skips delivery and the ladder and escalates directly.
# This library owns only the schedule and escalation marker.
# THE FOUR COMPOSER-HOLDS-TEXT STATES (task fm-doorbell-stuck-auto-recovery).
# "Text sits unsent in the composer" is not one condition, and the fleet has
# seen it resolve four different ways. They are separated from the OUTSIDE by
# two readers that already exist - the semantic busy verdict the caller
# supplies (bin/fm-busy-lib.sh) and the composer owner's own shape and
# byte-identity proofs (bin/fm-composer-lib.sh) - never by a third reader of
# our own:
#
#   A QUEUED BEHIND A LIVE TURN. The caller classifies the pane busy. The
#     record is durable and the worker collects it at its own checkpoint, so
#     nothing is typed, nothing is pressed, and no alarm fires inside the busy
#     bound (fm_task_inbox_busy_action). Measured 2026-09-21: two instructions
#     to a worker mid-validation, both picked up by the worker itself at the
#     end of its turn. Interrupting a live pipeline run to hand over a message
#     that was going to arrive anyway is a worse outcome than the defect, which
#     is why the recovery below never fires without a positive `idle`.
#   B OUR OWN DOORBELL, UNSENT, IN AN IDLE COMPOSER. The pane is positively
#     idle and fm_composer_holds_text proves the composer holds EXACTLY the
#     doorbell line this library typed: the Enter was swallowed, and another
#     Enter submits it. fm_task_inbox_ring re-presses Enter on it through
#     fm_backend_resubmit_own_text, which never retypes and never clears.
#     Measured 2026-09-19 on fm-main-ci-intermittent-reds, where one Enter
#     driven by hand through tmux cleared it.
#   C CONTENT FIRSTMATE NEVER TYPED. The pane is idle and the composer reads
#     `pending`, but every attempt of the budget found text already sitting
#     there - firstmate typed nothing into this run. It is a worker's
#     half-written command, the captain's own typing, or a shape no reader can
#     prove (a bordered or left-bar composer). Nothing is typed and nothing is
#     cleared, because that content is not ours to submit OR to discard -
#     pressing Enter on someone's half-written command RUNS it - and a spent
#     budget escalates as `stuck` for a human to look at.
#   D OUR OWN DOORBELL WENT IN AND NEVER CAME OUT. The pane is idle, firstmate
#     typed the doorbell into it, and it has not cleared since: either proven
#     in the composer with Enter re-pressed and refused (state B that did not
#     recover), or typed and simply left there, which is how claude's stranded
#     message queue presents - the text visible with `ctrl+x ctrl+s to send
#     now` above a separate `Press up to edit queued messages` row, held
#     OUTSIDE the composer where no Enter reaches it. A spent budget escalates
#     as `stuck-input`, and the recovery is a relaunch.
#
# WHY D IS NOT CLEARED, ONLY RELAUNCHED (measured, not assumed). No mechanism
# reachable through the control plane both clears this state and preserves
# content firstmate did not write:
#   - The interrupt key does not clear it. Measured on two live workers:
#     blu-3153-help-infra-h03 (2026-09-19) and fm-worker-cannot-patch-pr-body
#     (2026-09-21), where the interrupt was DELIVERED and verified agent-alive
#     and the composer still held its text; a second doorbell after it was
#     refused identically, and only a relaunch recovered the worker. Three
#     attempts across two incidents, no clear.
#   - The plane's only composer-clear key is `C-u`, and
#     bin/fm-control-lib.sh's fm_control_interrupt_clear_key declares it for
#     muse alone, for a reason that does not generalise: muse RESTORES its own
#     cancelled prompt, so the bytes C-u removes are muse's, never a human's.
#     Sending it here would discard content firstmate did not write, and it is
#     a line kill, so it would not reach a queue held off the input line
#     anyway.
#   - claude's own `ctrl+x ctrl+s` sends the queue rather than discarding it,
#     but it sends EVERYTHING queued, including anything firstmate did not
#     write, which submits someone else's half-written command on their
#     behalf. It is also outside the control plane's key vocabulary, so it is
#     recorded here as an observed affordance and deliberately not built on.
# Relaunch is cheap and lossless by comparison: the worktree and commits
# persist and the brief carries over, which both incidents confirmed.
#
# WHY D IS NOT DETECTED FROM THOSE TWO ROWS, though they are right there on
# the pane: measured against the recorded live capture of that screen
# (tests/fm-task-inbox.test.sh's claude_queued_capture, cited to
# docs/verification/runtime-backends.md "Queued claude input"), BOTH rows
# appear identically in the benign busy variant and the hard idle one, the
# classifier returns `pending` for both, and the only difference anywhere on
# the screen is the spinner row - the one thing that scrolls away or is simply
# absent at capture time. Detection built on those rows would relaunch healthy
# workers mid-turn. What separates the two is not on the screen at all: the
# semantic busy verdict, and whether firstmate typed that doorbell into this
# pane and it never cleared. Both are what this ladder uses instead.
#
# An unreadable busy verdict is state A, not state B: the ring re-presses
# Enter only on the caller's exact `idle`, so "cannot tell" always waits.
# `escalate` remains the verb for a budget whose attempts were not all stuck -
# an ordinary unacknowledged instruction, with no composer story at all.
# The ladder only names these conditions; it never interrupts, never clears,
# and never relaunches anything itself.
#
# Busy panes (fm_task_inbox_busy_action): a busy pane is a reason to defer a
# doorbell, never a reason to stop counting. Busy means "do not type into it
# now"; it does not mean "this worker is fine". A pane held on a blocking
# harness prompt renders exactly one unbroken busy run - the harness opened a
# turn it can never close - so an unbroken busy run carrying an unhandled
# record past FM_TASK_INBOX_BUSY_MAX_SECS escalates as `wedged`, naming the
# record and the run. Inside that bound a busy pane stays quiet, which is what
# keeps a worker legitimately running a long suite with a steer queued behind
# it from being alarmed on. The run is tracked in the same ladder file as the
# delivery attempts, starts fresh whenever the oldest unhandled record changes,
# and is ended by any delivery attempt, since an attempt means the pane was
# reachable. A busy poll never rings and never spends delivery budget.
#
# If attempt bookkeeping cannot be persisted while the record remains unhandled,
# the caller surfaces that failure instead of retrying silently; a concurrently
# removed inbox is a quiet no-op. Escalation deliberately queues the wake before
# writing the deduplication marker: normal polls surface a message once, while a
# crash or marker failure may produce a rare duplicate rather than silently lose
# a wake.
#
# Inbox paths containing bytes outside printable ASCII are unsupported. The
# doorbell refuses them rather than sending terminal control bytes to a pane.
#
# fm_task_inbox_ring requires bin/fm-backend.sh's dispatch (sourced below); the
# other helpers are dependency-light. Sourced by bin/fm-send.sh, bin/fm-watch.sh,
# and tests. No side effects on source beyond its sourced libraries.
#
# Tunables (env):
#   FM_TASK_INBOX_GRACE_SECS   default 90; delivery-attempt grace and spacing
#   FM_TASK_INBOX_RING_MAX     default 3; delivery attempts before escalation
#   FM_TASK_INBOX_BUSY_MAX_SECS  default 1800; unbroken busy seconds carrying an
#                              unhandled record before it escalates as wedged.
#                              Zero and malformed settings take the default:
#                              a bound of none would alarm on every busy
#                              worker, which is the failure that makes the
#                              alarm worthless.
#                              Deliberately its own bound rather than the
#                              watcher's BUSY_TURN_MAX_SECS: that one asks
#                              whether any pane has gone too long with no
#                              completed turn, while this one asks how long a
#                              specific instruction may go unaccepted.
#                              Half an hour is pinned from both sides. The
#                              FLOOR is a legitimate uninterrupted turn: a
#                              worker running a ~20 minute suite in one tool
#                              call with a steer queued behind it is healthy,
#                              and alarming on it is what would make this wake
#                              worthless. The CEILING is the failure being
#                              answered: on 2026-09-20 a worker sat on a
#                              blocking permission dialog for about 75
#                              minutes, and the oldest instruction in its
#                              steering inbox went unaccepted for 51 of them,
#                              measured from that record's own write and
#                              acknowledgement times (the other, written
#                              later, waited 34). This bound gates that
#                              per-instruction span, not the pane's dwell.
#                              BUSY_TURN_MAX_SECS's hour would never have
#                              fired at all. Being wrong is cheap in one
#                              direction only, which is why the bound sits
#                              nearer the floor than the middle: .escalated
#                              caps a mistaken wedge at ONE wake per record,
#                              so a worker genuinely inside a very long turn
#                              costs one line of attention rather than a loop,
#                              while a missed wedge costs the whole lane for
#                              as long as nobody looks. A home whose workers
#                              routinely hold one turn for longer raises it.

_FM_TASK_INBOX_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Both dependencies are canonical lint roots in their own right. Keep them as
# analysis boundaries here so ShellCheck's external-source traversal does not
# recursively duplicate the full backend graph for every inbox consumer.
# shellcheck source=/dev/null
. "$_FM_TASK_INBOX_LIB_DIR/fm-wake-lib.sh"
# shellcheck source=/dev/null
. "$_FM_TASK_INBOX_LIB_DIR/fm-backend.sh"

FM_TASK_INBOX_SCHEMA='fm-task-inbox.v1'
FM_TASK_INBOX_GRACE_DEFAULT=90
FM_TASK_INBOX_RING_MAX_DEFAULT=3
FM_TASK_INBOX_BUSY_MAX_DEFAULT=1800
FM_TASK_INBOX_LOCK_WAIT_DEFAULT=5

fm_task_inbox_grace_secs() {
  local g=${FM_TASK_INBOX_GRACE_SECS:-$FM_TASK_INBOX_GRACE_DEFAULT}
  case "$g" in ''|*[!0-9]*) g=$FM_TASK_INBOX_GRACE_DEFAULT ;; esac
  printf '%s' "$g"
}

fm_task_inbox_ring_max() {
  local m=${FM_TASK_INBOX_RING_MAX:-$FM_TASK_INBOX_RING_MAX_DEFAULT}
  case "$m" in ''|*[!0-9]*) m=$FM_TASK_INBOX_RING_MAX_DEFAULT ;; esac
  printf '%s' "$m"
}

# Unbroken busy seconds an unhandled record may carry before it escalates.
# A zero or malformed setting falls back to the default rather than turning
# the bound off: an unbounded busy pane is exactly the wedge this catches.
fm_task_inbox_busy_max_secs() {
  local m=${FM_TASK_INBOX_BUSY_MAX_SECS:-$FM_TASK_INBOX_BUSY_MAX_DEFAULT}
  case "$m" in ''|*[!0-9]*|0) m=$FM_TASK_INBOX_BUSY_MAX_DEFAULT ;; esac
  printf '%s' "$m"
}

fm_task_inbox_dir() {  # <state-dir> <task-id>
  printf '%s/%s.inbox' "$1" "$2"
}

fm_task_inbox_handled_dir() {  # <state-dir> <task-id>
  printf '%s/%s.inbox/handled' "$1" "$2"
}

# Numeric sequence of one record basename, or fail for a non-record name.
fm_task_inbox_seq_of() {  # <basename>
  local n=${1%.msg}
  [ "$n" != "$1" ] || return 1
  case "$n" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s' "$((10#$n))"
}

# Next unused sequence, scanning the inbox root AND handled/ so an
# acknowledged sequence is never reissued. Caller must hold .seq.lock.
fm_task_inbox_next_seq() {  # <inbox-dir>
  local dir=$1 max=0 d f n
  for d in "$dir" "$dir/handled"; do
    for f in "$d"/*.msg; do
      [ -e "$f" ] || continue
      n=$(fm_task_inbox_seq_of "${f##*/}") || continue
      [ "$n" -le "$max" ] || max=$n
    done
  done
  printf '%03d' "$((max + 1))"
}

fm_task_inbox_lock_acquire() {  # <lock-path>
  local lock=$1 wait=${FM_TASK_INBOX_LOCK_WAIT_SECS:-$FM_TASK_INBOX_LOCK_WAIT_DEFAULT}
  local deadline probe
  case "$wait" in ''|*[!0-9]*) wait=$FM_TASK_INBOX_LOCK_WAIT_DEFAULT ;; esac
  probe=$(mktemp "${lock%/*}/.lock-probe.XXXXXX") || return 1
  rm -f "$probe" || return 1
  if [ ! -e "$lock" ] && [ ! -L "$lock" ]; then
    fm_lock_try_create "$lock" && return 0
  fi
  deadline=$(( $(date +%s) + wait ))
  while ! fm_lock_try_acquire "$lock"; do
    [ "$(date +%s)" -lt "$deadline" ] || return 1
    sleep 0.1
  done
}

# Write one record into the next sequence slot: temp-write, then atomic
# rename. Prints the record path. Caller must hold .seq.lock.
_fm_task_inbox_write_record_locked() {  # <inbox-dir> <text> [delivery-mode]
  local dir=$1 text=$2 delivery_mode=${3:-} seq tmp rec status=0
  seq=$(fm_task_inbox_next_seq "$dir")
  rec="$dir/$seq.msg"
  tmp=$(mktemp "$dir/.staging.XXXXXX") || return 1
  {
    printf 'schema=%s\n' "$FM_TASK_INBOX_SCHEMA"
    printf 'at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    [ "$delivery_mode" != fire-and-forget ] || printf 'delivery=fire-and-forget\n'
    printf -- '--\n'
    printf '%s' "$text"
  } > "$tmp" && mv "$tmp" "$rec" || status=1
  [ "$status" -eq 0 ] || { rm -f "$tmp"; return 1; }
  printf '%s' "$rec"
}

# Durably enqueue one steer: temp-write, then atomic rename into the next
# sequence slot. Prints the record path. Fails without a partial record.
fm_task_inbox_write() {  # <state-dir> <task-id> <text> [delivery-mode]
  local state=$1 task=$2 text=$3 delivery_mode=${4:-} dir lock rec status=0
  dir=$(fm_task_inbox_dir "$state" "$task")
  mkdir -p "$dir/handled" || return 1
  lock="$dir/.seq.lock"
  fm_task_inbox_lock_acquire "$lock" || return 1
  rec=$(_fm_task_inbox_write_record_locked "$dir" "$text" "$delivery_mode") || status=1
  fm_lock_release "$lock"
  [ "$status" -eq 0 ] || return 1
  printf '%s' "$rec"
}

# Durably enqueue one steer at most once: when a record with the exact same
# body already exists - unhandled or already acknowledged in handled/ - no new
# record is written and the existing record's path is printed instead.
# This is the enqueue primitive for a transport that can fail with completion
# unknown (the remote steer leg over ssh): the caller's safe recovery is to run
# the same enqueue again, and this dedup is what makes the re-run land on the
# same record instead of a duplicate the worker would act on twice. Two
# distinct logical requests never collapse in practice because a marked
# secondmate request embeds a per-request correlation token in its body. The
# local plane keeps plain fm_task_inbox_write: its outcome is synchronous, so
# a repeated identical local steer is a deliberate new instruction.
fm_task_inbox_write_idempotent() {  # <state-dir> <task-id> <text> [delivery-mode]
  local state=$1 task=$2 text=$3 delivery_mode=${4:-} dir lock want have f rec='' status=0
  dir=$(fm_task_inbox_dir "$state" "$task")
  mkdir -p "$dir/handled" || return 1
  lock="$dir/.seq.lock"
  fm_task_inbox_lock_acquire "$lock" || return 1
  if want=$(mktemp "$dir/.dedup.XXXXXX") && have=$(mktemp "$dir/.dedup.XXXXXX"); then
    if printf '%s' "$text" > "$want"; then
      for f in "$dir"/*.msg "$dir/handled"/*.msg; do
        if [ ! -e "$f" ]; then
          case "$f" in
            "$dir"/*.msg)
              f="$dir/handled/${f##*/}"
              [ -e "$f" ] || continue
              ;;
            *) continue ;;
          esac
        fi
        if [ "$delivery_mode" = fire-and-forget ]; then
          fm_task_inbox_is_fire_and_forget "$f" || continue
        elif fm_task_inbox_is_fire_and_forget "$f"; then
          continue
        fi
        if ! fm_task_inbox_body "$f" > "$have" 2>/dev/null; then
          case "$f" in
            "$dir"/*.msg)
              f="$dir/handled/${f##*/}"
              fm_task_inbox_body "$f" > "$have" 2>/dev/null || continue
              ;;
            *) continue ;;
          esac
        fi
        cmp -s "$want" "$have" || continue
        [ ! -e "$dir/handled/${f##*/}" ] || f="$dir/handled/${f##*/}"
        rec=$f
        break
      done
    else
      status=1
    fi
    rm -f "$want" "$have"
  else
    rm -f "${want:-}" 2>/dev/null || true
    status=1
  fi
  if [ "$status" -eq 0 ] && [ -z "$rec" ]; then
    rec=$(_fm_task_inbox_write_record_locked "$dir" "$text" "$delivery_mode") || status=1
  fi
  fm_lock_release "$lock"
  [ "$status" -eq 0 ] || return 1
  printf '%s' "$rec"
}

# The exact enqueued text back out of a record.
fm_task_inbox_body() {  # <record-path>
  local line
  [ -f "$1" ] || return 1
  while IFS= read -r line; do
    if [ "$line" = -- ]; then
      cat
      return 0
    fi
  done < "$1"
  return 1
}

# The constant self-describing doorbell line for the inbox containing a record.
# Self-describing on purpose: a worker whose brief predates the inbox contract
# still receives the complete instruction in the line itself. The leading `: `
# is the POSIX shell no-op, so the same line typed into a pane whose agent has
# exited (a bare shell) runs nothing; see the dead-pane note in the header.
# A non-printable path fails without output so terminal controls never reach
# the pane's line discipline.
fm_task_inbox_doorbell_line() {  # <record-path>
  local dir=${1%/*} abs quoted LC_ALL=C
  abs=$(cd "$dir" 2>/dev/null && pwd) || abs=$dir
  case "$abs" in
    *[![:print:]]*) return 1 ;;
  esac
  quoted=$(printf '%s' "$abs" | sed "s/'/'\\\\''/g")
  printf ": Firstmate instruction waiting: list '%s'/*.msg and, in numeric order, read and act on each, then mv each handled file to '%s'/handled/." \
    "$quoted" "$quoted"
}

# Ring the doorbell, best-effort: one endpoint-liveness pre-check, one advisory
# composer pre-check, then the backend's submit machinery with a minimal retry
# budget, verdict discarded.
# Returns 0 rang, 1 skipped because the composer PROVENLY holds pending text
# that is not provably ours (state C; the watcher re-rings later), 2 the
# backend send failed, 3 skipped because the endpoint is positively dead or
# missing (nothing typed; recovery owns the record), 4 rang but the composer
# still provably holds unsent text after the submit on a pane not busy with a
# turn, 5 the composer provably held OUR OWN doorbell and re-pressing Enter
# did not submit it (state D evidence). 1, 4, and 5 are the ladder's
# stuck-attempt evidence, and only 5 names the `own` kind
# (fm_task_inbox_record_ring). No return value is delivery proof; the
# acknowledgement move is the only delivery signal.
# <pane-state> is the caller's SEMANTIC busy verdict for this endpoint
# (bin/fm-busy-lib.sh), and only its exact value `idle` unlocks the state-B
# recovery below; an absent, busy, unknown, or dead verdict defers.
# The skip is deliberately narrow: only an exact `pending` verdict defers,
# because there our Enter could submit someone's real half-typed content.
# `pending-unproven` and `unknown` still ring - the worst outcome is a garbled
# CONSTANT line the worker recovers semantically, while skipping on ambiguous
# verdicts would starve a harness whose idle screen the classifier cannot
# positively identify (that classifier is advisory here by design).
# On an exact `pending` with an idle pane, the deferral is preceded by ONE
# recovery attempt: fm_backend_resubmit_own_text presses Enter again while,
# and only while, the composer provably holds exactly the doorbell line
# computed above. That proof is byte-identity, not shape, so foreign or merely
# unprovable content answers `not-own`, sends nothing, and defers exactly as
# it always did. Nothing on this path ever retypes, clears, or interrupts:
# the recovery for a composer we did not fill is a human looking at it.
# Every backend but tmux answers `not-own` today (bin/fm-backend.sh), so they
# keep the previous behaviour unchanged rather than acting on an unprovable
# screen.
fm_task_inbox_ring() {  # <backend> <target> <record-path> [expected-label] [pane-state]
  local backend=$1 target=$2 rec=$3 label=${4:-} pane_state=${5:-} line cstate verdict
  case "$(fm_backend_agent_state "$backend" "$target" 2>/dev/null || true)" in
    dead|missing) return 3 ;;
  esac
  if ! line=$(fm_task_inbox_doorbell_line "$rec"); then
    return 2
  fi
  cstate=$(fm_backend_composer_state "$backend" "$target" "$label" 2>/dev/null) || cstate=unknown
  case "$cstate" in
    pending)
      # Pending text is only ever RE-SUBMITTED, never retyped and never
      # cleared, and only on the caller's positive idle assertion. Every other
      # pane state - busy, unknown, unasserted - defers exactly as before.
      [ "$pane_state" = idle ] || return 1
      case "$(fm_backend_resubmit_own_text "$backend" "$target" "$line" 1 0.4 || printf 'not-own')" in
        empty) return 0 ;;
        not-own) return 1 ;;
        pending) return 5 ;;
        send-failed) return 2 ;;
        *) return 0 ;;
      esac
      ;;
  esac
  # Accepted residual race: terminal input and Enter are separate delivery
  # steps, so an agent exiting after the liveness check could leave a bare
  # shell only a suffix; the `: ` prefix protects complete lines only. Do not
  # add process-bound atomic delivery here unless an incident reopens this.
  if ! verdict=$(fm_backend_send_text_submit "$backend" "$target" "$line" 1 0.4 0.3 "$label"); then
    return 2
  fi
  # The verdict is never delivery proof. Beyond a failed keystroke, only an
  # exact `pending` counts: the submit core already converted a busy pane's
  # queued Enter to `empty`, so `pending` here means the text is still sitting
  # unsent in an idle composer.
  [ "$verdict" != send-failed ] || return 2
  [ "$verdict" != pending ] || return 4
  return 0
}

fm_task_inbox_is_fire_and_forget() {  # <record-path>
  local rec=$1
  if [ ! -f "$rec" ]; then
    rec="${rec%/*}/handled/${rec##*/}"
    [ -f "$rec" ] || return 1
  fi
  awk '
    $0 == "--" { exit }
    $0 == "delivery=fire-and-forget" { found=1 }
    END { exit(found ? 0 : 1) }
  ' "$rec"
}

# Oldest escalation-tracked unhandled record, or fail when none is due.
fm_task_inbox_oldest_unhandled() {  # <state-dir> <task-id>
  local dir best='' best_n=0 f n
  dir=$(fm_task_inbox_dir "$1" "$2")
  for f in "$dir"/*.msg; do
    [ -e "$f" ] || continue
    fm_task_inbox_is_fire_and_forget "$f" && continue
    n=$(fm_task_inbox_seq_of "${f##*/}") || continue
    if [ -z "$best" ] || [ "$n" -lt "$best_n" ]; then
      best=$f
      best_n=$n
    fi
  done
  [ -n "$best" ] || return 1
  printf '%s' "$best"
}

# The re-ring ladder decision for one task. Prints exactly one of:
#   quiet                     nothing due (healthy, within grace or spacing,
#                             or already escalated for the current oldest)
#   ring <record-path>        one doorbell re-ring is due
#   escalate <record-path> <count>   attempt budget spent; surface as stale
#   stuck <record-path> <count>      attempt budget spent and every attempt
#                             found text firstmate never typed (state C);
#                             surface as a worker that cannot receive
#                             messages, for a human to inspect rather than for
#                             anything to clear
#   stuck-input <record-path> <count>  the same spent budget, but firstmate's
#                             own doorbell went into this pane and never
#                             cleared (state D); surface as a worker that
#                             cannot receive messages whose recovery is a
#                             relaunch
# The caller reaches this only for a pane it has not classified busy; a busy
# pane goes to fm_task_inbox_busy_action instead.
# An empty inbox also resets the ladder bookkeeping so the next message starts
# a fresh ladder.
fm_task_inbox_due_action() {  # <state-dir> <task-id>
  local dir oldest base now grace max ladder rec_base count last stuck busy_since stuck_kind
  dir=$(fm_task_inbox_dir "$1" "$2")
  if ! oldest=$(fm_task_inbox_oldest_unhandled "$1" "$2"); then
    rm -f "$dir/.ring-state" "$dir/.escalated" 2>/dev/null || true
    printf 'quiet'
    return 0
  fi
  base=${oldest##*/}
  grace=$(fm_task_inbox_grace_secs)
  if [ "$(fm_path_age "$oldest")" -lt "$grace" ]; then
    printf 'quiet'
    return 0
  fi
  count=0
  last=0
  stuck=0
  busy_since=0
  stuck_kind=other
  ladder=$(cat "$dir/.ring-state" 2>/dev/null || true)
  IFS=$(printf '\t') read -r rec_base count last stuck busy_since stuck_kind <<EOF
$ladder
EOF
  if [ -n "$rec_base" ] && [ "$rec_base" != "$base" ]; then
    # A different oldest message: the previous ladder is stale. An absent
    # ladder is left alone so a dead-pane escalation, which never rings and so
    # never writes one, keeps its marker (the marker check below still ignores
    # a marker naming some other message).
    count=0
    last=0
    stuck=0
    busy_since=0
    stuck_kind=other
    rm -f "$dir/.escalated" 2>/dev/null || true
  fi
  case "$count" in ''|*[!0-9]*) count=0 ;; esac
  case "$last" in ''|*[!0-9]*) last=0 ;; esac
  case "$stuck" in ''|*[!0-9]*) stuck=0 ;; esac
  # busy_since is read and normalized but not consulted here: this decision is
  # only ever asked for a pane the caller did NOT classify busy. Reading it is
  # still required, because the last `read` variable absorbs every remaining
  # field, so dropping it would hand the busy epoch to `stuck` and silently
  # zero the composer-stuck count.
  case "$busy_since" in ''|*[!0-9]*) busy_since=0 ;; esac
  # Only a positively recorded `own` claims input-dead; a ladder written
  # before this field existed, or any other value, reads as `other`.
  [ "$stuck_kind" = own ] || stuck_kind=other
  if [ "$(cat "$dir/.escalated" 2>/dev/null || true)" = "$base" ]; then
    printf 'quiet'
    return 0
  fi
  max=$(fm_task_inbox_ring_max)
  if [ "$count" -ge "$max" ]; then
    if [ "$count" -gt 0 ] && [ "$stuck" -ge "$count" ]; then
      if [ "$stuck_kind" = own ]; then
        printf 'stuck-input %s %s' "$oldest" "$count"
      else
        printf 'stuck %s %s' "$oldest" "$count"
      fi
    else
      printf 'escalate %s %s' "$oldest" "$count"
    fi
    return 0
  fi
  now=$(date +%s)
  if [ "$((now - last))" -lt "$grace" ]; then
    printf 'quiet'
    return 0
  fi
  printf 'ring %s' "$oldest"
}

# Advance the ladder after a delivery attempt. A failed ring or a composer-
# protected skip still consumes budget so neither an unreadable pane nor a
# permanently blocked composer can retry silently forever. <stuck> is 1 when
# the attempt found the composer holding unsent text (fm_task_inbox_ring's 1,
# 4, or 5); it extends the consecutive stuck count, and any other attempt
# resets it. <stuck-kind> is `own` when THIS attempt put firstmate's own
# doorbell into the pane and it did not clear - a return of 4 (typed, still
# there) or 5 (proven in the composer, Enter refused) - and `other` for a
# return of 1, where the text was already there before firstmate typed
# anything. The kind is STICKY across one stuck run and never downgrades,
# because the later attempts of a run see only a composer they cannot prove;
# the run's FIRST attempt is what knows whether the stuck text is ours. An attempt also ends any busy run: the caller only attempts delivery on
# a pane it did not classify busy, so the run was broken by definition. A
# positively dead or missing endpoint never enters the ladder: the watcher
# escalates it directly. A concurrently removed inbox is a successful
# no-op; otherwise failure means the caller must surface the unwritable ladder
# while the record remains unhandled.
fm_task_inbox_record_ring() {  # <state-dir> <task-id> <record-path> [stuck] [stuck-kind]
  local dir base ladder rec_base count last stuck busy_since stuck_kind
  dir=$(fm_task_inbox_dir "$1" "$2")
  base=${3##*/}
  count=0
  stuck=0
  ladder=$(cat "$dir/.ring-state" 2>/dev/null || true)
  IFS=$(printf '\t') read -r rec_base count last stuck busy_since stuck_kind <<EOF
$ladder
EOF
  if [ "$rec_base" != "$base" ]; then
    count=0
    stuck=0
    stuck_kind=none
  fi
  case "$count" in ''|*[!0-9]*) count=0 ;; esac
  case "$stuck" in ''|*[!0-9]*) stuck=0 ;; esac
  if [ "${4:-0}" = 1 ]; then
    # STICKY within one stuck run: once firstmate's own doorbell has gone into
    # this pane and not come out, later attempts that can only see unprovable
    # text do not un-learn that. Without this, the live 2026-09-21 sequence -
    # attempt 1 types it and it stays, attempts 2 and 3 find text they cannot
    # prove - would forget by the third poll that the stuck text is ours.
    if [ "$stuck" -gt 0 ] && [ "$stuck_kind" = own ]; then
      :
    elif [ "${5:-}" = own ]; then
      stuck_kind=own
    else
      stuck_kind=other
    fi
    stuck=$((stuck + 1))
  else
    stuck=0
    stuck_kind=none
  fi
  [ -d "$dir" ] || return 0
  if ! { printf '%s\t%s\t%s\t%s\t0\t%s\n' "$base" "$((count + 1))" "$(date +%s)" "$stuck" "$stuck_kind" > "$dir/.ring-state"; } 2>/dev/null; then
    [ -d "$dir" ] || return 0
    return 1
  fi
}

# The busy-pane decision for one task, called once per poll for a pane the
# caller HAS classified busy while <record-path> is the oldest unhandled
# record. Records the busy observation and prints exactly one of:
#   quiet                     the busy run is still inside the bound; the
#                             doorbell is deferred, exactly as before
#   wedged <record-path> <seconds>   the pane has been continuously busy for
#                             <seconds> while this record stayed unhandled;
#                             surface as a worker that cannot be reached
# Returns 1 only when the run could not be persisted while the inbox still
# exists, so the caller surfaces the same unwritable-ladder wake it already
# surfaces for a delivery attempt: a busy run that cannot be recorded is a
# ladder that can never reach `wedged`, which is the defect this branch exists
# to prevent. A concurrently removed inbox is a quiet no-op.
#
# Delivery budget is deliberately untouched here. A busy pane is not an
# attempt, so counting busy polls as rings would spend the budget a later idle
# pane needs, and the two escalations answer different questions.
fm_task_inbox_busy_action() {  # <state-dir> <task-id> <record-path>
  local dir base ladder rec_base count last stuck busy_since stuck_kind now elapsed max
  dir=$(fm_task_inbox_dir "$1" "$2")
  base=${3##*/}
  count=0
  last=0
  stuck=0
  busy_since=0
  stuck_kind=none
  ladder=$(cat "$dir/.ring-state" 2>/dev/null || true)
  IFS=$(printf '\t') read -r rec_base count last stuck busy_since stuck_kind <<EOF
$ladder
EOF
  if [ "$rec_base" != "$base" ]; then
    count=0
    last=0
    stuck=0
    busy_since=0
    stuck_kind=none
  fi
  case "$count" in ''|*[!0-9]*) count=0 ;; esac
  case "$last" in ''|*[!0-9]*) last=0 ;; esac
  case "$stuck" in ''|*[!0-9]*) stuck=0 ;; esac
  case "$busy_since" in ''|*[!0-9]*) busy_since=0 ;; esac
  now=$(date +%s)
  [ "$busy_since" -gt 0 ] && [ "$busy_since" -le "$now" ] || busy_since=$now
  [ -d "$dir" ] || { printf 'quiet'; return 0; }
  if ! { printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$base" "$count" "$last" "$stuck" "$busy_since" "${stuck_kind:-none}" > "$dir/.ring-state"; } 2>/dev/null; then
    [ -d "$dir" ] || { printf 'quiet'; return 0; }
    return 1
  fi
  elapsed=$((now - busy_since))
  max=$(fm_task_inbox_busy_max_secs)
  if [ "$elapsed" -ge "$max" ] && [ "$(cat "$dir/.escalated" 2>/dev/null || true)" != "$base" ]; then
    printf 'wedged %s %s' "$3" "$elapsed"
    return 0
  fi
  printf 'quiet'
}

# Mark the current oldest as escalated after its stale wake is durably queued,
# suppressing another wake on later polls. Wake-before-marker ordering favors
# at-least-once recovery: a crash or marker failure can cause a rare duplicate;
# stuck-crewmate-recovery owns the message from here.
fm_task_inbox_record_escalated() {  # <state-dir> <task-id> <record-path>
  local dir
  dir=$(fm_task_inbox_dir "$1" "$2")
  [ -d "$dir" ] || return 0
  if ! { printf '%s\n' "${3##*/}" > "$dir/.escalated"; } 2>/dev/null; then
    [ -d "$dir" ] || return 0
    return 1
  fi
}
