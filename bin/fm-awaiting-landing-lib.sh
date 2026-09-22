#!/usr/bin/env bash
# fm-awaiting-landing-lib.sh - the ONE owner of "awaiting landing": a task whose
# work is finished and whose only remaining step is landing.
#
# WHY THIS EXISTS. Firstmate frees a task's concurrency slot at DONE rather than
# at landing (AGENTS.md section 7), so "finished but not yet landed" stopped
# being a brief transient and became a normal steady state a task sits in for as
# long as its PR takes to merge. Nothing in firstmate REPRESENTED that state, so
# every consumer that cared inferred it independently from whatever it happened
# to hold, and each got it wrong differently: the staleness alarm read a quiet
# finished pane as a possible wedge and escalated, and the home summary read a
# terminal child on an in-flight row as a strict inventory error. The state is
# named once here; consumers ASK this library instead of re-deriving it.
#
# NO NEW INFORMATION IS COLLECTED. Every input is a record some other owner
# already writes:
#   state/<id>.status         the worker's append-only wake-event log.
#                             bin/fm-classify-lib.sh owns its verb grammar.
#   state/<id>.meta           pr=, pr_head= (bin/fm-pr-check.sh), worktree=.
#   state/<id>.agent-stopped  the deliberate stop (bin/fm-control.sh `exit`).
# This library WRITES NOTHING and reaches no forge, no no-mistakes daemon, and
# no pane. That purity is the contract that lets the watcher call it on every
# poll for every window, unlike crew_absorb_class in bin/fm-classify-lib.sh.
# The one subprocess it may run is a local `git rev-parse` in the task's own
# recorded worktree, and only for a task that already has both a done outcome
# and a recorded forge head - never on the hot path of an ordinary working task.
#
# THE THREE CLASSES
#   awaiting-landing  finished, held by firstmate, nothing says it cannot land.
#                     Supervision should be QUIET: there is no agent left to
#                     wedge and no worker action outstanding.
#   landing-blocked   finished and held, but the landing target this home
#                     recorded is NOT this branch's work. Must be SURFACED.
#   none              anything else. Never quiet on this library's account.
#
# THE DERIVATION, and why each leg is load-bearing. Removing any one of them
# reintroduces a defect this library exists to prevent, and tests/
# fm-awaiting-landing.test.sh reds by name for each.
#
#   1. OUTCOME. The task's current outcome line - bin/fm-classify-lib.sh's
#      status_outcome_line, which owns that question - has the verb `done`.
#      Quiet is only ever licensed by positive evidence that the WORK finished.
#      A task with a genuinely dead agent and no terminal outcome is a wedge and
#      must keep alarming: a fix that buys quiet by blinding supervision is
#      worse than the noise it removes. `done` specifically, not the broader
#      terminal/captain-relevant verb set (status_is_terminal_verb also admits
#      needs-decision, blocked, and failed): an agent stopped while its work was
#      still open genuinely needs firstmate, and silencing a stopped `blocked:`
#      task leaves it unwatched forever. The outcome line rather than the LAST
#      line, and the grammar owner's reader rather than a second fold written
#      here: 2026-09-22, appending the `resolved` line firstmate is instructed
#      to write when it closes an open call dropped this exemption from a lane
#      that was otherwise untouched, re-arming the alarms this library exists to
#      stop.
#   2. ACKNOWLEDGEMENT. A recorded pr=, or the deliberate-stop record. One of
#      these is firstmate's own durable proof that it has TAKEN THE WORK IN
#      HAND - it armed the merge poll, or it stopped the agent on purpose.
#      Without either, a `done:` line is an unacknowledged claim the worker just
#      made and the alarm is right to keep surfacing it until firstmate acts.
#   3. LANDING TARGET. When a pr_head= is recorded AND the branch head can be
#      read, they must be equal. 2026-09-17: a task sat with an open, mergeable
#      PR whose head had diverged from its branch's real head - the commits had
#      been rewritten during an aborted validation run and never pushed - so the
#      PR looked healthy while containing the WRONG work, and the armed merge
#      poll would have reported it landed. "A pr= is recorded" is therefore NOT
#      sufficient for landing-ready. The one exception is a PR head that is
#      AHEAD of the branch (the branch is an ancestor of it) AND that the
#      pipeline's durable validation receipt names: that is the ordinary end
#      state of every validated ship, because the pipeline pushes its own fix
#      commits and the local branch is never advanced to them. It reads
#      awaiting-landing with target=validated. An ahead head with no matching
#      receipt, a `behind` head (unpushed local work) and an unrelated head
#      (rewritten history) all stay landing-blocked.
#
# The target check can only ever move a task OUT of quiet, never into it.
# Absence of verification is not evidence of a problem: bin/fm-pr-check.sh
# records pr_head only when the forge CLI supplies it, so a GitLab task records
# none BY DESIGN, and bin/fm-teardown.sh, bin/fm-review-diff.sh, and
# bin/fm-pr-merge.sh all already treat it as optional and resolve the head live
# instead. Treating "no recorded head" as blocked would permanently alarm every
# GitLab task with no defect behind it, and resolving it live here would mean
# querying the forge - out of scope for this card. Such a task stays
# awaiting-landing and reports landing_target=unverified so the evidence is
# legible rather than swallowed.
#
# "Landing" is the remaining firstmate-owned step, not specifically a merge: a
# merged PR for a PR-based ship, the guarded fast-forward for local-only work,
# cleanup for a scout whose report is recorded. All three share the property
# every consumer actually asks about - the work is finished and no worker action
# is outstanding.
#
# DELIBERATELY OUT OF SCOPE. Whether the task has ALREADY landed (the merge poll
# owns that, and teardown follows it), and discovering a PR this home never
# recorded (bin/fm-detect-unrecorded-pr's card owns that forge query). This
# library is happy to be asked by either.
#
# No side effects on source. set -u / set -e safe.

if [ -n "${FM_AWAITING_LANDING_LIB_SOURCED:-}" ]; then
  return 0
fi
FM_AWAITING_LANDING_LIB_SOURCED=1

_FM_AWAITING_LANDING_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# bin/fm-classify-lib.sh owns the status-line verb grammar and bin/fm-pr-lib.sh
# owns the head-sha grammar. Restating either here is exactly the duplication
# this library exists to remove, so both are sourced rather than re-derived.
# Both are pure function definitions with no side effects on source, and a
# caller that already sourced them is unaffected.
# shellcheck source=bin/fm-classify-lib.sh
. "$_FM_AWAITING_LANDING_DIR/fm-classify-lib.sh"
# shellcheck source=bin/fm-pr-lib.sh
. "$_FM_AWAITING_LANDING_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-validation-receipt-lib.sh
. "$_FM_AWAITING_LANDING_DIR/fm-validation-receipt-lib.sh"
unset _FM_AWAITING_LANDING_DIR

# The evidence every read publishes. A caller that only wants the class may use
# the $(...) accessors below; a caller that wants the evidence must call
# fm_awaiting_landing_read directly, because a subshell would discard these.
# shellcheck disable=SC2034 # Output globals, read by the sourcing caller.
FM_AWAITING_LANDING_CLASS="none"
FM_AWAITING_LANDING_OUTCOME=
FM_AWAITING_LANDING_ACK=
FM_AWAITING_LANDING_TARGET=
FM_AWAITING_LANDING_PR=
FM_AWAITING_LANDING_PR_HEAD=
FM_AWAITING_LANDING_BRANCH_HEAD=
FM_AWAITING_LANDING_DETAIL=

# One meta field's last recorded value, or the empty string.
_fm_awaiting_landing_meta() {  # <meta-file> <key>
  [ -f "$1" ] || return 0
  grep "^$2=" "$1" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

# The branch head of <worktree>, or the empty string when it cannot be read.
# A local read of the task's own recorded copy - never the forge.
_fm_awaiting_landing_branch_head() {  # <worktree>
  local wt=${1-} head
  [ -n "$wt" ] && [ -d "$wt" ] || return 0
  head=$(git -C "$wt" rev-parse --verify --quiet 'HEAD^{commit}' 2>/dev/null) || return 0
  fm_pr_head_valid "$head" || return 0
  printf '%s' "$head"
}

# How a recorded head and a branch head disagree. Free once both SHAs are in
# hand, and it is what makes the surfaced line actionable: `unrelated` is the
# rewritten-history case that produced this leg.
_fm_awaiting_landing_divergence() {  # <worktree> <recorded-head> <branch-head>
  local wt=$1 recorded=$2 branch=$3
  if git -C "$wt" merge-base --is-ancestor "$recorded" "$branch" 2>/dev/null; then
    printf 'behind'
  elif git -C "$wt" merge-base --is-ancestor "$branch" "$recorded" 2>/dev/null; then
    printf 'ahead'
  else
    printf 'unrelated'
  fi
}

# 0 when the durable validation receipt for THIS task's recorded PR names exactly
# <pr-head> as a head the pipeline validated. Local file read only.
_fm_awaiting_landing_head_validated() {  # <state> <id> <pr-url> <pr-head>
  local state=$1 id=$2 url=$3 head=$4
  fm_pr_url_parse "$url" || return 1
  fm_validation_receipt_read "$state" "$id" "$FM_PR_PROVIDER" "$FM_PR_HOST" \
    "$FM_PR_PATH" "$FM_PR_NUMBER" || return 1
  [ "$FM_VALIDATION_RECEIPT_HEAD" = "$head" ]
}

# THE derivation. Sets every FM_AWAITING_LANDING_* global above and returns 0.
# shellcheck disable=SC2034 # Output globals, read by the sourcing caller.
fm_awaiting_landing_read() {  # <id> <state-dir>
  local id=${1-} state=${2-}
  local meta line verb pr pr_head worktree branch_head stopped=1 shape

  FM_AWAITING_LANDING_CLASS="none"
  FM_AWAITING_LANDING_OUTCOME=
  FM_AWAITING_LANDING_ACK=
  FM_AWAITING_LANDING_TARGET=
  FM_AWAITING_LANDING_PR=
  FM_AWAITING_LANDING_PR_HEAD=
  FM_AWAITING_LANDING_BRANCH_HEAD=
  FM_AWAITING_LANDING_DETAIL=

  [ -n "$id" ] && [ -n "$state" ] || return 0

  # Leg 1: the work reported itself finished.
  line=$(status_outcome_line "$state/$id.status")
  [ -n "$line" ] || return 0
  verb=$(status_line_verb "$line")
  [ "$verb" = "done" ] || return 0
  FM_AWAITING_LANDING_OUTCOME="done"

  # Leg 2: firstmate durably acknowledged the hold.
  meta="$state/$id.meta"
  pr=$(_fm_awaiting_landing_meta "$meta" pr)
  # Spelled out rather than as a && list: bin/fm-pr-check.sh and other callers
  # run under `set -e`, where a bare failing test would abort them.
  if [ -e "$state/$id.agent-stopped" ]; then stopped=0; fi
  FM_AWAITING_LANDING_PR=$pr
  if [ -n "$pr" ] && [ "$stopped" -eq 0 ]; then
    FM_AWAITING_LANDING_ACK="pr+agent-stopped"
  elif [ -n "$pr" ]; then
    FM_AWAITING_LANDING_ACK="pr"
  elif [ "$stopped" -eq 0 ]; then
    FM_AWAITING_LANDING_ACK="agent-stopped"
  else
    # Done, but nothing records that firstmate has taken it in hand yet. The
    # evidence stays truthful (outcome=done, no acknowledgement) so a consumer
    # can tell this apart from work that never finished.
    return 0
  fi

  # Leg 3: the recorded landing target is still this branch's work.
  if [ -z "$pr" ]; then
    FM_AWAITING_LANDING_TARGET="none"
    FM_AWAITING_LANDING_CLASS="awaiting-landing"
    FM_AWAITING_LANDING_DETAIL="awaiting landing: work reported done, agent stopped deliberately, no PR recorded"
    return 0
  fi
  pr_head=$(_fm_awaiting_landing_meta "$meta" pr_head)
  FM_AWAITING_LANDING_PR_HEAD=$pr_head
  if [ -z "$pr_head" ]; then
    FM_AWAITING_LANDING_TARGET="unverified"
    FM_AWAITING_LANDING_CLASS="awaiting-landing"
    FM_AWAITING_LANDING_DETAIL="awaiting landing: work reported done, $pr recorded; no forge head recorded, so the landing target is unverified here"
    return 0
  fi
  worktree=$(_fm_awaiting_landing_meta "$meta" worktree)
  branch_head=$(_fm_awaiting_landing_branch_head "$worktree")
  FM_AWAITING_LANDING_BRANCH_HEAD=$branch_head
  if [ -z "$branch_head" ]; then
    FM_AWAITING_LANDING_TARGET="unverified"
    FM_AWAITING_LANDING_CLASS="awaiting-landing"
    FM_AWAITING_LANDING_DETAIL="awaiting landing: work reported done, $pr recorded; the local copy's branch head could not be read, so the landing target is unverified here"
    return 0
  fi
  if [ "$pr_head" = "$branch_head" ]; then
    FM_AWAITING_LANDING_TARGET="verified"
    FM_AWAITING_LANDING_CLASS="awaiting-landing"
    FM_AWAITING_LANDING_DETAIL="awaiting landing: work reported done, $pr holds this branch's head ${branch_head:0:7}"
    return 0
  fi
  shape=$(_fm_awaiting_landing_divergence "$worktree" "$pr_head" "$branch_head")
  # An `ahead` PR is the ordinary end state of a validated ship: the pipeline
  # pushes its own fix commits and the worker's local branch is never
  # fast-forwarded to them, so the PR holds everything the branch has plus the
  # pipeline's work. That is safe to land ONLY when the pipeline itself vouches
  # for the PR head, which the durable receipt records (a pure file read, no
  # forge or daemon). Without a matching receipt - direct-PR work, or a local
  # copy that dropped commits nothing validated - `ahead` stays blocked.
  if [ "$shape" = ahead ] && _fm_awaiting_landing_head_validated "$state" "$id" "$pr" "$pr_head"; then
    FM_AWAITING_LANDING_TARGET="validated"
    FM_AWAITING_LANDING_CLASS="awaiting-landing"
    FM_AWAITING_LANDING_DETAIL="awaiting landing: work reported done, $pr holds ${pr_head:0:7}, validated by pipeline run $FM_VALIDATION_RECEIPT_RUN and containing this branch's head ${branch_head:0:7}"
    return 0
  fi
  FM_AWAITING_LANDING_TARGET="diverged"
  FM_AWAITING_LANDING_CLASS="landing-blocked"
  case "$shape" in
    behind)
      FM_AWAITING_LANDING_DETAIL="landing blocked: $pr holds ${pr_head:0:7} but the branch has advanced to ${branch_head:0:7}; the PR is missing work that was never pushed" ;;
    ahead)
      FM_AWAITING_LANDING_DETAIL="landing blocked: $pr holds ${pr_head:0:7}, which the local copy at ${branch_head:0:7} does not contain" ;;
    *)
      FM_AWAITING_LANDING_DETAIL="landing blocked: $pr holds ${pr_head:0:7}, which is not in this branch's history at ${branch_head:0:7}; the commits were rewritten and the PR contains different work" ;;
  esac
  return 0
}

# The class alone: awaiting-landing, landing-blocked, or none. Safe in $(...).
fm_awaiting_landing_class() {  # <id> <state-dir>
  fm_awaiting_landing_read "${1-}" "${2-}"
  printf '%s' "$FM_AWAITING_LANDING_CLASS"
}

# 0 when this task is finished, held, and nothing says it cannot land - THE
# quiet predicate. A consumer that suppresses supervision asks this and nothing
# else, so the suppression can never be wider than the derivation above.
fm_awaiting_landing() {  # <id> <state-dir>
  [ "$(fm_awaiting_landing_class "${1-}" "${2-}")" = awaiting-landing ]
}

# 0 when this task is finished and held but its recorded landing target is not
# this branch's work. Never quiet: nobody should merge a task in this condition.
fm_awaiting_landing_blocked() {  # <id> <state-dir>
  [ "$(fm_awaiting_landing_class "${1-}" "${2-}")" = landing-blocked ]
}

# The one-line human detail for whichever class this task is in (empty for none).
fm_awaiting_landing_detail() {  # <id> <state-dir>
  fm_awaiting_landing_read "${1-}" "${2-}"
  printf '%s' "$FM_AWAITING_LANDING_DETAIL"
}
