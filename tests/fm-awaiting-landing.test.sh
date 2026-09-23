#!/usr/bin/env bash
# tests/fm-awaiting-landing.test.sh - bin/fm-awaiting-landing-lib.sh is the ONE
# representation of work that is finished and waiting only to land. Its header
# owns the derivation; this file owns the proof that each leg of it is really
# load-bearing.
#
# Two properties are defended equally hard, because the failure modes are
# opposite and a fix for one is the classic way to break the other:
#
#   QUIET.  Finished work firstmate is holding must stop looking like a wedge,
#           whether its agent was deliberately stopped or simply left alive.
#           Those were two concurrent false alarm streams on 2026-09-17.
#   SIGHT.  Nothing else may go quiet. A task with a genuinely dead agent and no
#           terminal outcome must still read as something supervision watches: a
#           fix that buys quiet by blinding supervision is worse than the noise
#           it removes.
#
# Every claim is exercised through the library's public entry points against
# real fixtures - real status logs, real metadata, real git worktrees with real
# divergent commits - never against its source text.
#
# The named mutants at the bottom are PROVEN red rather than asserted: each one
# is a surgical single-leg edit applied to a COPY of the library, run through
# the same public entry points, and required to answer differently from the real
# library on the fixture that names it. A mutation operator that no longer
# matches the library fails loudly instead of passing vacuously.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

LIB="$ROOT/bin/fm-awaiting-landing-lib.sh"
# shellcheck source=/dev/null
. "$LIB"

TMP_ROOT=$(fm_test_tmproot fm-awaiting-landing-tests)

GIT_ID=(-c user.name='Firstmate Tests' -c user.email='tests@example.invalid')

# --- fixtures ---------------------------------------------------------------

# A task home with a state directory and a plain (non-git) worktree. Enough for
# every case whose landing target is not verifiable against a branch head.
make_task() {  # <name> -> prints dir
  local dir="$TMP_ROOT/$1"
  mkdir -p "$dir/state" "$dir/wt"
  printf '%s' "$dir"
}

# The same, with a REAL git repository and worktree so branch-head reads and
# ancestry questions are answered by git rather than by a stub.
make_git_task() {  # <name> -> prints dir
  local dir="$TMP_ROOT/$1"
  mkdir -p "$dir/state"
  fm_git_worktree "$dir/repo" "$dir/wt" "fm/$1"
  printf '%s' "$dir"
}

# Add one commit to <worktree> and print its sha.
wt_commit() {  # <worktree> <message>
  local wt=$1 msg=$2
  printf '%s\n' "$msg" >> "$wt/work.txt"
  git -C "$wt" add work.txt
  git -C "$wt" "${GIT_ID[@]}" commit -qm "$msg"
  git -C "$wt" rev-parse HEAD
}

status_line() {  # <dir> <id> <line>
  printf '%s\n' "$3" >> "$1/state/$2.status"
}

task_meta() {  # <dir> <id> [extra key=value ...]
  local dir=$1 id=$2
  shift 2
  fm_write_meta "$dir/state/$id.meta" "worktree=$dir/wt" "kind=ship" "$@"
}

stop_agent() {  # <dir> <id>
  printf 'stopped_at=2026-09-17T02:00:00Z\nverb=exit\n' > "$1/state/$2.agent-stopped"
}

# --- assertions -------------------------------------------------------------

assert_class() {  # <label> <expected> <dir> <id>
  local got
  got=$(fm_awaiting_landing_class "$4" "$3/state")
  [ "$got" = "$2" ] \
    || fail "$1: expected class '$2' but the library answered '$got'"
}

assert_quiet() {  # <label> <dir> <id>
  fm_awaiting_landing "$3" "$2/state" \
    || fail "$1: finished, held work is still being watched as if a worker owed something"
}

assert_watched() {  # <label> <dir> <id>
  if fm_awaiting_landing "$3" "$2/state"; then
    fail "$1: supervision was silenced for work that is NOT finished and held"
  fi
}

assert_target() {  # <label> <expected> <dir> <id>
  fm_awaiting_landing_read "$4" "$3/state"
  [ "$FM_AWAITING_LANDING_TARGET" = "$2" ] \
    || fail "$1: expected landing target '$2' but the library reported '$FM_AWAITING_LANDING_TARGET'"
}

assert_detail_mentions() {  # <label> <substring> <dir> <id>
  local detail
  detail=$(fm_awaiting_landing_detail "$4" "$3/state")
  case "$detail" in
    *"$2"*) : ;;
    *) fail "$1: the surfaced line does not say '$2' - it reads '$detail'" ;;
  esac
}

# --- QUIET: the two false alarm streams measured on 2026-09-17 --------------

# Stream one. The worker finished, reported its PR, and firstmate left the agent
# running. Nothing is stopped, so a derivation that keys off the stop record
# alone cannot see this task at all - and it alarmed every time its idle pane
# redrew.
test_finished_work_whose_agent_is_still_alive_is_awaiting_landing() {
  local dir head
  dir=$(make_git_task alive-done)
  head=$(wt_commit "$dir/wt" "the work")
  status_line "$dir" alive-done 'done: PR https://github.com/o/r/pull/7 checks green run=r-1'
  task_meta "$dir" alive-done "pr=https://github.com/o/r/pull/7" "pr_head=$head"

  assert_class "a done agent left alive" awaiting-landing "$dir" alive-done
  assert_quiet "a done agent left alive" "$dir" alive-done
  assert_target "a done agent left alive" verified "$dir" alive-done

  fm_awaiting_landing_read alive-done "$dir/state"
  [ "$FM_AWAITING_LANDING_ACK" = pr ] \
    || fail "the recorded PR was not read as firstmate's acknowledgement (ack=$FM_AWAITING_LANDING_ACK)"

  pass "finished work whose agent is still alive is awaiting landing, not a wedge"
}

# Stream two. Firstmate deliberately stopped the agent to free a slot, leaving a
# pane holding nothing but a shell - indistinguishable from death to every
# liveness source, and the exact opposite of the intent.
test_a_deliberately_stopped_agent_on_finished_work_is_awaiting_landing() {
  local dir
  dir=$(make_task stopped-done)
  status_line "$dir" stopped-done 'done: ready in branch, waiting for the approved merge'
  task_meta "$dir" stopped-done
  stop_agent "$dir" stopped-done

  assert_class "a deliberately stopped agent" awaiting-landing "$dir" stopped-done
  assert_quiet "a deliberately stopped agent" "$dir" stopped-done
  # Local-only work has no PR to diverge from: the branch head IS the target.
  assert_target "a deliberately stopped agent" none "$dir" stopped-done

  fm_awaiting_landing_read stopped-done "$dir/state"
  [ "$FM_AWAITING_LANDING_ACK" = agent-stopped ] \
    || fail "the deliberate stop was not read as firstmate's acknowledgement (ack=$FM_AWAITING_LANDING_ACK)"

  pass "a deliberately stopped agent on finished work is awaiting landing, not death"
}

# Both records at once: the ordinary end state of a PR ship whose slot was freed.
test_a_stopped_agent_with_a_recorded_pr_is_awaiting_landing() {
  local dir head
  dir=$(make_git_task stopped-pr)
  head=$(wt_commit "$dir/wt" "the work")
  status_line "$dir" stopped-pr 'done: PR https://github.com/o/r/pull/9 checks green run=r-2'
  task_meta "$dir" stopped-pr "pr=https://github.com/o/r/pull/9" "pr_head=$head"
  stop_agent "$dir" stopped-pr

  assert_class "a stopped agent with a recorded PR" awaiting-landing "$dir" stopped-pr
  fm_awaiting_landing_read stopped-pr "$dir/state"
  [ "$FM_AWAITING_LANDING_ACK" = "pr+agent-stopped" ] \
    || fail "both acknowledgements should be reported (ack=$FM_AWAITING_LANDING_ACK)"

  pass "a stopped agent whose PR is recorded is awaiting landing on both records"
}

# --- SIGHT: what must never go quiet ----------------------------------------

# THE one that matters most. No terminal outcome, and the agent is gone. This is
# a wedge, and it must stay visible however the agent's absence is explained.
test_a_dead_agent_with_no_terminal_outcome_is_never_quiet() {
  local dir
  dir=$(make_task wedged)
  status_line "$dir" wedged 'working: implementing the parser'
  task_meta "$dir" wedged "pr=https://github.com/o/r/pull/11"

  assert_class "a wedged task with a recorded PR" none "$dir" wedged
  assert_watched "a wedged task with a recorded PR" "$dir" wedged

  # Even with the deliberate-stop record present - a stop is not an outcome.
  stop_agent "$dir" wedged
  assert_class "a wedged task whose agent was stopped" none "$dir" wedged
  assert_watched "a wedged task whose agent was stopped" "$dir" wedged

  # And with no status log at all, which is where a crashed worker leaves one.
  local bare
  bare=$(make_task wedged-silent)
  task_meta "$bare" wedged-silent "pr=https://github.com/o/r/pull/12"
  stop_agent "$bare" wedged-silent
  assert_class "a task that never reported anything" none "$bare" wedged-silent
  assert_watched "a task that never reported anything" "$bare" wedged-silent

  pass "a dead agent with no terminal outcome is never quiet, by any route"
}

# `done` specifically, not the broader terminal/captain-relevant verb set. An
# agent stopped while its work was still open genuinely needs firstmate, and
# silencing it would leave it unwatched forever.
test_work_still_open_is_never_awaiting_landing() {
  local dir verb line
  for verb in blocked needs-decision failed; do
    dir=$(make_task "open-$verb")
    case "$verb" in
      blocked)        line='blocked: the daemon socket refuses connections' ;;
      needs-decision) line='needs-decision [key=nm-3-review]: ask-user findings=F1' ;;
      failed)         line='failed: the pipeline could not recover the branch' ;;
    esac
    status_line "$dir" "open-$verb" "$line"
    task_meta "$dir" "open-$verb" "pr=https://github.com/o/r/pull/13"
    stop_agent "$dir" "open-$verb"

    assert_class "a stopped agent sitting on $verb:" none "$dir" "open-$verb"
    assert_watched "a stopped agent sitting on $verb:" "$dir" "open-$verb"
  done

  pass "a stopped agent whose work was still open stays watched, for every open verb"
}

# A `done:` line firstmate has not acted on yet is a claim the worker just made,
# not a hold firstmate is keeping. The alarm is right to keep surfacing it.
test_an_unacknowledged_done_claim_is_not_yet_awaiting_landing() {
  local dir
  dir=$(make_task unacknowledged)
  status_line "$dir" unacknowledged 'done: implementation complete on the branch'
  task_meta "$dir" unacknowledged

  assert_class "a done claim firstmate has not acted on" none "$dir" unacknowledged
  assert_watched "a done claim firstmate has not acted on" "$dir" unacknowledged

  # The evidence stays truthful: the outcome is real, the acknowledgement is not.
  fm_awaiting_landing_read unacknowledged "$dir/state"
  [ "$FM_AWAITING_LANDING_OUTCOME" = "done" ] \
    || fail "the done outcome should still be reported as observed"
  [ -z "$FM_AWAITING_LANDING_ACK" ] \
    || fail "no acknowledgement should be claimed (ack=$FM_AWAITING_LANDING_ACK)"

  pass "an unacknowledged done claim is reported as done but not yet held"
}

# The status log is an append-only EVENT log: the latest OUTCOME event is
# current, and a worker that reopens the work posts one.
test_a_worker_that_resumes_after_done_is_watched_again() {
  local dir head
  dir=$(make_git_task resumed)
  head=$(wt_commit "$dir/wt" "the work")
  status_line "$dir" resumed 'done: PR https://github.com/o/r/pull/14 checks green run=r-3'
  task_meta "$dir" resumed "pr=https://github.com/o/r/pull/14" "pr_head=$head"
  assert_class "before the worker resumed" awaiting-landing "$dir" resumed

  status_line "$dir" resumed 'working: reopened to answer a review finding'
  assert_class "after the worker resumed" none "$dir" resumed
  assert_watched "after the worker resumed" "$dir" resumed

  pass "a worker that resumes after reporting done is watched again"
}

# 2026-09-22, and the reason leg 1 reads the OUTCOME line rather than the last
# one. Closing a decision record is not a work event: bin/fm-send.sh
# --resolve-key writes a `resolved` line at answer time, and
# bin/fm-afk-return.sh's catch-up gate instructs firstmate to close every call
# still open at return with one carrying a durable reason. Following that
# instruction on a lane that had already reported done, been stopped, and whose
# recorded PR head still equalled its branch head silently dropped this
# exemption and put the lane straight back on the stale alarm. Two correct
# mechanisms, one record: the resolution must leave the outcome where it stood.
test_a_resolution_recorded_after_done_keeps_the_exemption() {
  local dir head
  dir=$(make_git_task resolved-after-done)
  head=$(wt_commit "$dir/wt" "the work")
  status_line "$dir" resolved-after-done 'done: PR https://github.com/o/r/pull/67 checks green run=r-67'
  task_meta "$dir" resolved-after-done "pr=https://github.com/o/r/pull/67" "pr_head=$head"
  stop_agent "$dir" resolved-after-done
  assert_class "before the resolution was recorded" awaiting-landing "$dir" resolved-after-done

  status_line "$dir" resolved-after-done \
    'resolved [key=default]: superseded, verified not dismissed; reason recorded for the return brief'
  assert_class "after the resolution was recorded" awaiting-landing "$dir" resolved-after-done
  assert_quiet "after the resolution was recorded" "$dir" resolved-after-done
  assert_target "after the resolution was recorded" verified "$dir" resolved-after-done
  fm_awaiting_landing_read resolved-after-done "$dir/state"
  [ "$FM_AWAITING_LANDING_ACK" = "pr+agent-stopped" ] \
    || fail "the acknowledgement was lost with the outcome (ack=$FM_AWAITING_LANDING_ACK)"

  # A return that closes several calls at once appends several of them, and a
  # correlated resolution is the same event carrying a token.
  status_line "$dir" resolved-after-done 'resolved corr=c44897ee2db4326b [key=nm-9-review]: answered by the captain'
  status_line "$dir" resolved-after-done 'resolved [key=merge]: the captain gave the word'
  assert_class "after a run of resolutions" awaiting-landing "$dir" resolved-after-done

  # And the fold reaches only record-keeping: a worker that really did reopen
  # the work is still watched, from underneath its own resolutions.
  status_line "$dir" resolved-after-done 'working: reopened to answer a review finding'
  assert_class "after the worker resumed" none "$dir" resolved-after-done
  status_line "$dir" resolved-after-done 'resolved [key=review]: the finding was answered'
  assert_class "after a resolution on top of the resumed work" none "$dir" resolved-after-done
  assert_watched "after a resolution on top of the resumed work" "$dir" resolved-after-done

  pass "a resolution recorded after done keeps the exemption, and never hides a worker that resumed"
}

# The verb grammar has one owner (bin/fm-classify-lib.sh) and this library reads
# through it, so a line carrying a correlation token is still a done outcome.
test_a_correlated_done_line_is_read_through() {
  local dir
  dir=$(make_task correlated)
  status_line "$dir" correlated 'done corr=c44897ee2db4326b: ready in branch'
  task_meta "$dir" correlated
  stop_agent "$dir" correlated

  assert_class "a done line carrying a correlation token" awaiting-landing "$dir" correlated

  pass "a done line carrying a correlation token is read through to its verb"
}

# --- LANDING TARGET: a recorded PR is not proof the PR holds this work -------

# 2026-09-17: an open, mergeable PR whose head had been rewritten out of the
# branch's history. The PR looked perfectly healthy while containing the WRONG
# work, and the armed merge poll would have reported it landed.
test_a_pr_head_rewritten_out_of_history_is_landing_blocked() {
  local dir abandoned real
  dir=$(make_git_task rewritten)
  abandoned=$(wt_commit "$dir/wt" "the work as first written")
  git -C "$dir/wt" reset --hard -q HEAD~1
  real=$(wt_commit "$dir/wt" "the work as rewritten during the aborted run")
  [ "$abandoned" != "$real" ] || fail "fixture did not actually rewrite the commit"

  status_line "$dir" rewritten 'done: PR https://github.com/o/r/pull/15 checks green run=r-4'
  task_meta "$dir" rewritten "pr=https://github.com/o/r/pull/15" "pr_head=$abandoned"

  assert_class "a PR head rewritten out of history" landing-blocked "$dir" rewritten
  assert_watched "a PR head rewritten out of history" "$dir" rewritten
  fm_awaiting_landing_blocked rewritten "$dir/state" \
    || fail "the rewritten-history case did not report itself as blocked from landing"
  assert_target "a PR head rewritten out of history" diverged "$dir" rewritten
  assert_detail_mentions "a PR head rewritten out of history" \
    "not in this branch's history" "$dir" rewritten

  pass "a PR whose head was rewritten out of the branch is landing-blocked, not quietly mergeable"
}

# The branch advanced past what the PR holds: work that was never pushed.
test_a_pr_head_left_behind_by_the_branch_is_landing_blocked() {
  local dir pushed
  dir=$(make_git_task behind)
  pushed=$(wt_commit "$dir/wt" "the pushed work")
  wt_commit "$dir/wt" "a later commit that was never pushed" > /dev/null

  status_line "$dir" behind 'done: PR https://github.com/o/r/pull/16 checks green run=r-5'
  task_meta "$dir" behind "pr=https://github.com/o/r/pull/16" "pr_head=$pushed"

  assert_class "a branch that advanced past its PR" landing-blocked "$dir" behind
  assert_detail_mentions "a branch that advanced past its PR" \
    "never pushed" "$dir" behind

  pass "a branch holding work its PR does not is landing-blocked"
}

# The PR holds commits this copy does not, and NOTHING vouches for them.
# Narrowed deliberately: an ahead head is landing-blocked only while no
# validation receipt names it. A head the pipeline validated is the ordinary
# end state of a no-mistakes ship and is proven quiet in
# test_a_validated_ahead_head_is_awaiting_landing below; every other ahead head
# (direct-PR work, a copy that dropped commits nothing validated) stays blocked.
test_an_unvalidated_pr_head_ahead_of_the_branch_is_landing_blocked() {
  local dir ahead
  dir=$(make_git_task ahead)
  wt_commit "$dir/wt" "the base work" > /dev/null
  ahead=$(wt_commit "$dir/wt" "a commit the local copy later dropped")
  git -C "$dir/wt" reset --hard -q HEAD~1

  status_line "$dir" ahead 'done: PR https://github.com/o/r/pull/17 checks green run=r-6'
  task_meta "$dir" ahead "pr=https://github.com/o/r/pull/17" "pr_head=$ahead"

  assert_class "a PR ahead of the local copy" landing-blocked "$dir" ahead
  assert_detail_mentions "a PR ahead of the local copy" \
    "does not contain" "$dir" ahead

  pass "a PR holding commits the local copy does not, with no receipt vouching for them, is landing-blocked"
}


receipt_for() {  # <dir> <id> <pr-number> <head>
  fm_validation_receipt_write "$1/state" "$2" github github.com o/r "$3" "$4" "fm/$2" 01RUNRUNRUNRUNRUNRUNRUNRUN \
    || fail "could not write the fixture validation receipt"
}

# THE reported case. The pipeline pushed its own fix commits, so the PR head is a
# descendant of the worker's branch head; the receipt is the pipeline vouching
# for that head. Quiet, with the stop marker present, and the evidence names it.
test_a_validated_ahead_head_is_awaiting_landing() {
  local dir base pipeline
  dir=$(make_git_task validated-ahead)
  base=$(wt_commit "$dir/wt" "the worker's commit")
  pipeline=$(wt_commit "$dir/wt" "no-mistakes(review): a pipeline fix commit")
  git -C "$dir/wt" reset --hard -q "$base"

  status_line "$dir" validated-ahead 'done: PR https://github.com/o/r/pull/30 checks green run=r-30'
  task_meta "$dir" validated-ahead "pr=https://github.com/o/r/pull/30" "pr_head=$pipeline"
  stop_agent "$dir" validated-ahead
  receipt_for "$dir" validated-ahead 30 "$pipeline"

  assert_class "a validated PR ahead of the local copy" awaiting-landing "$dir" validated-ahead
  assert_quiet "a validated PR ahead of the local copy" "$dir" validated-ahead
  assert_target "a validated PR ahead of the local copy" validated "$dir" validated-ahead
  assert_detail_mentions "a validated PR ahead of the local copy" "validated by pipeline run" "$dir" validated-ahead

  # A receipt that names some OTHER head, or another PR, vouches for nothing here.
  receipt_for "$dir" validated-ahead 30 "$base"
  assert_class "a receipt naming another head" landing-blocked "$dir" validated-ahead
  receipt_for "$dir" validated-ahead 31 "$pipeline"
  assert_class "a receipt for another PR" landing-blocked "$dir" validated-ahead

  pass "a PR head the pipeline validated, ahead of the local copy, is awaiting landing and never blocked"
}

# A receipt for the recorded head must not rescue the two shapes landing-blocked
# exists for: unpushed local work (behind) and rewritten history (unrelated).
test_a_receipt_never_rescues_a_behind_or_unrelated_head() {
  local dir pushed abandoned
  dir=$(make_git_task receipt-behind)
  pushed=$(wt_commit "$dir/wt" "the pushed work")
  wt_commit "$dir/wt" "a later commit that was never pushed" > /dev/null
  status_line "$dir" receipt-behind 'done: PR https://github.com/o/r/pull/32 checks green run=r-32'
  task_meta "$dir" receipt-behind "pr=https://github.com/o/r/pull/32" "pr_head=$pushed"
  stop_agent "$dir" receipt-behind
  receipt_for "$dir" receipt-behind 32 "$pushed"
  assert_class "a validated head the branch advanced past" landing-blocked "$dir" receipt-behind
  assert_watched "a validated head the branch advanced past" "$dir" receipt-behind

  dir=$(make_git_task receipt-unrelated)
  abandoned=$(wt_commit "$dir/wt" "the work as first written")
  git -C "$dir/wt" reset --hard -q HEAD~1
  wt_commit "$dir/wt" "the work as rewritten" > /dev/null
  status_line "$dir" receipt-unrelated 'done: PR https://github.com/o/r/pull/33 checks green run=r-33'
  task_meta "$dir" receipt-unrelated "pr=https://github.com/o/r/pull/33" "pr_head=$abandoned"
  stop_agent "$dir" receipt-unrelated
  receipt_for "$dir" receipt-unrelated 33 "$abandoned"
  assert_class "a validated head rewritten out of history" landing-blocked "$dir" receipt-unrelated
  assert_watched "a validated head rewritten out of history" "$dir" receipt-unrelated

  pass "a validation receipt never rescues an unpushed-work or rewritten-history head"
}

# Replay the branch in <worktree> the way the pipeline's rebase step does when
# the base branch moved while the ship was validating: the base gains a commit
# the branch lacks, the branch's own commits are cherry-picked onto it, and the
# pipeline adds a fix commit of its own. The worktree is returned to its branch
# head untouched, because the pipeline never advances the worker's local branch.
# Prints the rebased PR head. <replay> `changed` alters the replayed content, as
# a conflict resolved differently from the branch would.
pipeline_rebase() {  # <worktree> <replay: clean|changed>
  local wt=$1 replay=$2 branch head base
  branch=$(git -C "$wt" symbolic-ref --short HEAD)
  head=$(git -C "$wt" rev-parse HEAD)
  base=$(git -C "$wt" merge-base "$head" main)
  git -C "$wt" checkout -q --detach "$base"
  printf 'the base moved on\n' > "$wt/base.txt"
  git -C "$wt" add base.txt
  git -C "$wt" "${GIT_ID[@]}" commit -qm "the base branch moved on during validation"
  # Linearized as a rebase does: a merge on the branch is dropped and the
  # commits it brought in are replayed on their own.
  git -C "$wt" rev-list --reverse --no-merges "$base..$head" | while IFS= read -r c; do
    git -C "$wt" "${GIT_ID[@]}" cherry-pick "$c" > /dev/null || exit 1
  done || fail "the rebase fixture could not replay the branch"
  if [ "$replay" = changed ]; then
    printf 'resolved differently\n' >> "$wt/work.txt"
    git -C "$wt" add work.txt
    git -C "$wt" "${GIT_ID[@]}" commit -q --amend --no-edit
  fi
  printf 'a pipeline fix\n' > "$wt/pipeline.txt"
  git -C "$wt" add pipeline.txt
  git -C "$wt" "${GIT_ID[@]}" commit -qm "no-mistakes(review): a pipeline fix commit"
  git -C "$wt" rev-parse HEAD
  git -C "$wt" checkout -q "$branch"
}

# The fixture must really be the shape under test, or every assertion below
# passes over the ahead path instead: neither head may contain the other.
assert_rebased_shape() {  # <worktree> <branch-head> <pr-head>
  [ "$(git -C "$1" rev-parse HEAD)" = "$2" ] || fail "the rebase fixture moved the worker's branch"
  if git -C "$1" merge-base --is-ancestor "$2" "$3" || git -C "$1" merge-base --is-ancestor "$3" "$2"; then
    fail "the rebase fixture is not a rebase: one head contains the other"
  fi
}

# THE 2026-09-23 false alarms. With several lanes landing at once the base branch
# routinely moves while a ship validates, and the pipeline's rebase step then
# replays the worker's commits onto the new base before it pushes. The PR head
# holds this branch's work as NEW commits on a newer base, so neither head is an
# ancestor of the other, and a stopped worker whose validated PR sat green and
# open alarmed as landing-blocked. The receipt vouches for the head; that every
# branch commit has a patch-equivalent commit in it is what proves the head
# still carries this branch's work.
test_a_validated_rebased_head_is_awaiting_landing() {
  local dir work pr_head
  dir=$(make_git_task validated-rebased)
  wt_commit "$dir/wt" "the worker's first commit" > /dev/null
  work=$(wt_commit "$dir/wt" "the worker's second commit")
  pr_head=$(pipeline_rebase "$dir/wt" clean)
  assert_rebased_shape "$dir/wt" "$work" "$pr_head"

  status_line "$dir" validated-rebased 'done: PR https://github.com/o/r/pull/37 checks green run=r-37'
  task_meta "$dir" validated-rebased "pr=https://github.com/o/r/pull/37" "pr_head=$pr_head"
  stop_agent "$dir" validated-rebased
  receipt_for "$dir" validated-rebased 37 "$pr_head"

  assert_class "a validated PR the pipeline rebased" awaiting-landing "$dir" validated-rebased
  assert_quiet "a validated PR the pipeline rebased" "$dir" validated-rebased
  assert_target "a validated PR the pipeline rebased" validated "$dir" validated-rebased
  assert_detail_mentions "a validated PR the pipeline rebased" "rebased" "$dir" validated-rebased

  # Nothing vouches for the same head without a receipt that names it.
  receipt_for "$dir" validated-rebased 37 "$work"
  assert_class "a rebased head whose receipt names the branch head" landing-blocked "$dir" validated-rebased
  rm -f "$(fm_validation_receipt_path "$dir/state" validated-rebased)"
  assert_class "a rebased head with no receipt" landing-blocked "$dir" validated-rebased

  pass "a PR head the pipeline validated after rebasing this branch onto a newer base is awaiting landing"
}

# A receipt on a rebased head must not rescue the two things landing-blocked is
# for: work the PR does not carry, and work the PR carries differently.
test_a_receipt_never_rescues_a_rebased_head_missing_the_branch_work() {
  local dir work pr_head
  # The replay changed the content: the PR holds different work than the branch.
  dir=$(make_git_task rebased-changed)
  work=$(wt_commit "$dir/wt" "the worker's commit")
  pr_head=$(pipeline_rebase "$dir/wt" changed)
  assert_rebased_shape "$dir/wt" "$work" "$pr_head"
  status_line "$dir" rebased-changed 'done: PR https://github.com/o/r/pull/38 checks green run=r-38'
  task_meta "$dir" rebased-changed "pr=https://github.com/o/r/pull/38" "pr_head=$pr_head"
  stop_agent "$dir" rebased-changed
  receipt_for "$dir" rebased-changed 38 "$pr_head"
  assert_class "a validated rebase whose replay changed the work" landing-blocked "$dir" rebased-changed
  assert_watched "a validated rebase whose replay changed the work" "$dir" rebased-changed

  # The branch gained a commit after the pipeline rebased it: never pushed.
  dir=$(make_git_task rebased-then-advanced)
  wt_commit "$dir/wt" "the worker's commit" > /dev/null
  pr_head=$(pipeline_rebase "$dir/wt" clean)
  work=$(wt_commit "$dir/wt" "a later commit that was never pushed")
  assert_rebased_shape "$dir/wt" "$work" "$pr_head"
  status_line "$dir" rebased-then-advanced 'done: PR https://github.com/o/r/pull/39 checks green run=r-39'
  task_meta "$dir" rebased-then-advanced "pr=https://github.com/o/r/pull/39" "pr_head=$pr_head"
  stop_agent "$dir" rebased-then-advanced
  receipt_for "$dir" rebased-then-advanced 39 "$pr_head"
  assert_class "a validated rebase the branch then advanced past" landing-blocked "$dir" rebased-then-advanced
  assert_watched "a validated rebase the branch then advanced past" "$dir" rebased-then-advanced

  # A merge on the branch carried a change of its own, which the rebase dropped.
  dir=$(make_git_task rebased-merge)
  work=$(branch_with_evil_merge "$dir/wt")
  pr_head=$(pipeline_rebase "$dir/wt" clean)
  assert_rebased_shape "$dir/wt" "$work" "$pr_head"
  git -C "$dir/wt" cat-file -e "$pr_head:evil.txt" 2>/dev/null \
    && fail "the merge fixture's rebased head still carries the merge's own change"
  status_line "$dir" rebased-merge 'done: PR https://github.com/o/r/pull/40 checks green run=r-40'
  task_meta "$dir" rebased-merge "pr=https://github.com/o/r/pull/40" "pr_head=$pr_head"
  stop_agent "$dir" rebased-merge
  receipt_for "$dir" rebased-merge 40 "$pr_head"
  assert_class "a validated rebase that dropped a merge's own change" landing-blocked "$dir" rebased-merge

  pass "a validation receipt never rescues a rebased head that lacks or alters this branch's work"
}

# A branch whose history holds one ordinary commit and a merge of a side commit,
# where the merge itself adds a change neither parent has. Prints the head.
branch_with_evil_merge() {  # <worktree>
  local wt=$1 branch side
  branch=$(git -C "$wt" symbolic-ref --short HEAD)
  wt_commit "$wt" "the worker's commit" > /dev/null
  git -C "$wt" checkout -q --detach "$(git -C "$wt" merge-base HEAD main)"
  printf 'side\n' > "$wt/side.txt"
  git -C "$wt" add side.txt
  git -C "$wt" "${GIT_ID[@]}" commit -qm "a side commit"
  side=$(git -C "$wt" rev-parse HEAD)
  git -C "$wt" checkout -q "$branch"
  git -C "$wt" "${GIT_ID[@]}" merge -q --no-ff --no-edit "$side"
  printf 'resolved only in the merge\n' > "$wt/evil.txt"
  git -C "$wt" add evil.txt
  git -C "$wt" "${GIT_ID[@]}" commit -q --amend --no-edit
  git -C "$wt" rev-parse HEAD
}

# The pipeline's gate: a bare repository on this machine that the task's copy
# names as its `no-mistakes` remote. The pipeline commits in the gate and pushes
# to the forge from there, so what it makes is in the gate's store and not in the
# task's copy until something fetches it.
make_gate() {  # <dir>
  git clone --quiet --bare "$1/repo" "$1/gate.git" || fail "could not create the fixture gate"
  git -C "$1/repo" remote add no-mistakes "$1/gate.git"
}

# The pipeline's own end state, made where the pipeline makes it: the branch is
# pushed to the gate, and in a worktree of the gate it is either replayed onto a
# moved base (rebased) or given a pipeline fix commit (ahead). The task's copy is
# left without the result. Prints the PR head.
gate_pipeline() {  # <dir> <shape: rebased|ahead>
  local dir=$1 shape=$2 branch gate_wt
  branch=$(git -C "$dir/wt" symbolic-ref --short HEAD)
  git -C "$dir/wt" push -q no-mistakes "$branch" 2>/dev/null || fail "could not push the branch to the fixture gate"
  gate_wt="$dir/gate-wt"
  git -C "$dir/gate.git" worktree add -q "$gate_wt" "$branch" 2>/dev/null || fail "could not open a worktree of the fixture gate"
  if [ "$shape" = rebased ]; then
    pipeline_rebase "$gate_wt" clean
  else
    wt_commit "$gate_wt" "no-mistakes(review): a pipeline fix commit"
  fi
}

# The measured shape is a PR head the task's copy does not hold. A fixture that
# leaked the commit into the copy would prove the older same-repository cases
# over again instead.
assert_copy_lacks() {  # <worktree> <sha>
  if git -C "$1" cat-file -e "$2^{commit}" 2>/dev/null; then
    fail "the gate fixture put the pipeline's commit in the task's copy, so this is not the measured shape"
  fi
}

# THE 2026-09-23 10:37 false alarm, in the shape it was measured. A stopped
# worker's PR head was a pipeline rebase of its branch head, and the durable
# receipt named it, yet the task alarmed as rewritten history: the pipeline made
# that head in its gate, and the task's copy fetched it only an hour and a
# quarter later, so every ancestry and patch read of it failed. The ahead end
# state is made in the gate too and failed the same way.
test_a_validated_head_only_the_gate_holds_is_awaiting_landing() {
  local dir pr_head
  dir=$(make_git_task gate-rebased)
  wt_commit "$dir/wt" "the worker's first commit" > /dev/null
  wt_commit "$dir/wt" "the worker's second commit" > /dev/null
  make_gate "$dir"
  pr_head=$(gate_pipeline "$dir" rebased)
  assert_copy_lacks "$dir/wt" "$pr_head"
  status_line "$dir" gate-rebased 'done: PR https://github.com/o/r/pull/45 checks green run=r-45'
  task_meta "$dir" gate-rebased "pr=https://github.com/o/r/pull/45" "pr_head=$pr_head"
  stop_agent "$dir" gate-rebased
  receipt_for "$dir" gate-rebased 45 "$pr_head"

  assert_class "a validated rebase only the gate holds" awaiting-landing "$dir" gate-rebased
  assert_quiet "a validated rebase only the gate holds" "$dir" gate-rebased
  assert_target "a validated rebase only the gate holds" validated "$dir" gate-rebased
  assert_detail_mentions "a validated rebase only the gate holds" "rebased onto a newer base" "$dir" gate-rebased
  assert_copy_lacks "$dir/wt" "$pr_head"

  dir=$(make_git_task gate-ahead)
  wt_commit "$dir/wt" "the worker's commit" > /dev/null
  make_gate "$dir"
  pr_head=$(gate_pipeline "$dir" ahead)
  assert_copy_lacks "$dir/wt" "$pr_head"
  status_line "$dir" gate-ahead 'done: PR https://github.com/o/r/pull/46 checks green run=r-46'
  task_meta "$dir" gate-ahead "pr=https://github.com/o/r/pull/46" "pr_head=$pr_head"
  stop_agent "$dir" gate-ahead
  receipt_for "$dir" gate-ahead 46 "$pr_head"
  assert_class "a validated ahead head only the gate holds" awaiting-landing "$dir" gate-ahead
  assert_target "a validated ahead head only the gate holds" validated "$dir" gate-ahead

  pass "a validated PR head that only the pipeline's gate holds is awaiting landing, rebased or ahead"
}

# Reading through the gate's store must not rescue anything the exceptions
# refuse, and a head no store on this machine holds is surfaced for what is
# actually known about it rather than as rewritten history.
test_a_head_only_the_gate_holds_is_still_held_to_the_branch_work() {
  local dir pr_head detail
  # The branch gained a commit after the pipeline took it: never pushed.
  dir=$(make_git_task gate-then-advanced)
  wt_commit "$dir/wt" "the worker's commit" > /dev/null
  make_gate "$dir"
  pr_head=$(gate_pipeline "$dir" rebased)
  wt_commit "$dir/wt" "a later commit that was never pushed" > /dev/null
  assert_copy_lacks "$dir/wt" "$pr_head"
  status_line "$dir" gate-then-advanced 'done: PR https://github.com/o/r/pull/47 checks green run=r-47'
  task_meta "$dir" gate-then-advanced "pr=https://github.com/o/r/pull/47" "pr_head=$pr_head"
  stop_agent "$dir" gate-then-advanced
  receipt_for "$dir" gate-then-advanced 47 "$pr_head"
  assert_class "a gate-held rebase the branch then advanced past" landing-blocked "$dir" gate-then-advanced
  assert_target "a gate-held rebase the branch then advanced past" diverged "$dir" gate-then-advanced

  # Nothing vouches for a gate-held head without a receipt naming it.
  dir=$(make_git_task gate-unvouched)
  wt_commit "$dir/wt" "the worker's commit" > /dev/null
  make_gate "$dir"
  pr_head=$(gate_pipeline "$dir" rebased)
  status_line "$dir" gate-unvouched 'done: PR https://github.com/o/r/pull/48 checks green run=r-48'
  task_meta "$dir" gate-unvouched "pr=https://github.com/o/r/pull/48" "pr_head=$pr_head"
  stop_agent "$dir" gate-unvouched
  assert_class "a gate-held rebase nothing validated" landing-blocked "$dir" gate-unvouched

  # No store on this machine holds the head: nothing can be read about it, so
  # it is neither quiet nor reported as a rewrite.
  receipt_for "$dir" gate-unvouched 48 "$pr_head"
  git -C "$dir/repo" remote remove no-mistakes
  assert_class "a validated head nothing here holds" landing-blocked "$dir" gate-unvouched
  assert_target "a validated head nothing here holds" unreadable "$dir" gate-unvouched
  assert_detail_mentions "a validated head nothing here holds" "cannot be read" "$dir" gate-unvouched
  detail=$(fm_awaiting_landing_detail gate-unvouched "$dir/state")
  case "$detail" in
    *rewritten*) fail "a head nothing here holds was reported as rewritten history: $detail" ;;
  esac

  pass "a head only the gate holds is still held to this branch's work, and one nothing here holds says so"
}

# The check can only move a task OUT of quiet, never into it. bin/fm-pr-check.sh
# records pr_head only when the forge CLI supplies it - a GitLab task records
# none BY DESIGN - so an unverifiable target is not evidence of a problem and
# must not permanently alarm every such task.
test_an_unverifiable_landing_target_stays_awaiting_landing() {
  local dir gone
  dir=$(make_git_task no-forge-head)
  wt_commit "$dir/wt" "the work" > /dev/null
  status_line "$dir" no-forge-head 'done: PR https://gitlab.example.com/o/r/-/merge_requests/3 checks green run=r-7'
  task_meta "$dir" no-forge-head "pr=https://gitlab.example.com/o/r/-/merge_requests/3"

  assert_class "a forge that records no head" awaiting-landing "$dir" no-forge-head
  assert_target "a forge that records no head" unverified "$dir" no-forge-head
  assert_detail_mentions "a forge that records no head" "unverified" "$dir" no-forge-head

  # A recorded head with no readable local copy is equally unverifiable, and
  # equally not evidence of divergence.
  gone=$(make_task head-unreadable)
  rm -rf "$gone/wt"
  status_line "$gone" head-unreadable 'done: PR https://github.com/o/r/pull/18 checks green run=r-8'
  task_meta "$gone" head-unreadable \
    "pr=https://github.com/o/r/pull/18" \
    "pr_head=0000000000000000000000000000000000000001"
  assert_class "an unreadable local copy" awaiting-landing "$gone" head-unreadable
  assert_target "an unreadable local copy" unverified "$gone" head-unreadable

  pass "an unverifiable landing target stays awaiting landing and says so"
}

test_absent_records_read_as_none() {
  local dir
  dir=$(make_task absent)
  assert_class "a task with no records at all" none "$dir" absent
  assert_watched "a task with no records at all" "$dir" absent
  [ -z "$(fm_awaiting_landing_detail absent "$dir/state")" ] \
    || fail "a task in no state should have no detail line"
  assert_class "an empty id" none "$dir" ""

  pass "absent records read as none rather than as a held task"
}

# The library is sourced by scripts that run under `set -eu` (bin/fm-pr-check.sh
# among them), where one bare failing test aborts the caller outright. Every
# entry point must survive that on a task that matches nothing as much as on one
# that matches, or wiring a consumer would take the consumer down with it.
test_every_entry_point_is_safe_under_set_eu() {
  local dir out
  dir=$(make_task strict)
  status_line "$dir" strict 'done: ready in branch, waiting for the approved merge'
  task_meta "$dir" strict
  stop_agent "$dir" strict

  out=$(bash -c '
    set -eu
    # shellcheck disable=SC1090
    . "$1"
    fm_awaiting_landing_class "$2" "$3/state"
    printf ,
    if fm_awaiting_landing "$2" "$3/state"; then printf quiet; else printf not-quiet; fi
    printf ,
    # A task with no records at all: every leg fails in turn, and none of those
    # failures may abort the caller.
    fm_awaiting_landing_class nothing "$3/state"
    printf ,
    fm_awaiting_landing_detail nothing "$3/state"
    printf end
  ' _ "$LIB" strict "$dir") \
    || fail "the library aborted a caller running under set -eu"
  [ "$out" = "awaiting-landing,quiet,none,end" ] \
    || fail "entry points under set -eu answered '$out'"

  pass "every entry point is safe to call from a caller running under set -eu"
}

# --- the named mutants, proven red ------------------------------------------

# Run <id> through a COPY of the library with one leg surgically removed.
# Refuses an operator that no longer matches the library, so a drifted mutation
# can never make this proof vacuously green.
mutant_answer() {  # <name> <old-text> <new-text> <dir> <id> <class|quiet>
  local name=$1 old=$2 new=$3 dir=$4 id=$5 mode=$6 mdir target
  mdir="$TMP_ROOT/mutants/$name"
  mkdir -p "$mdir"
  # The whole of bin/ so the mutant's siblings resolve exactly as they do in the
  # real tree: bin/fm-classify-lib.sh sources further libraries of its own, and a
  # sandbox holding only the two this library names directly would run it with
  # part of its toolkit missing.
  local f
  for f in "$ROOT"/bin/*; do
    ln -sf "$f" "$mdir/${f##*/}"
  done
  target="$mdir/fm-awaiting-landing-lib.sh"
  # Replace the LINK before writing, or the redirection below would follow it and
  # overwrite the real library in the repository.
  rm -f "$target"
  perl -pe 'BEGIN{$o=shift;$n=shift} s/\Q$o\E/$n/g' "$old" "$new" "$LIB" > "$target"
  if cmp -s "$target" "$LIB"; then
    fail "mutant '$name' changed nothing: its operator no longer matches bin/fm-awaiting-landing-lib.sh, so this proof is vacuous"
  fi
  if [ -L "$target" ]; then
    fail "mutant '$name' was written through a link, which would have modified the repository"
  fi
  bash -c '
    set -u
    # shellcheck disable=SC1090
    . "$1"
    if [ "$4" = quiet ]; then
      if fm_awaiting_landing "$2" "$3"; then printf quiet; else printf not-quiet; fi
    else
      fm_awaiting_landing_class "$2" "$3"
    fi
  ' _ "$target" "$id" "$dir/state" "$mode"
}

# MUTANT: the state derived from the stop marker alone.
# A done agent left alive carries no stop record, so it alarms again - one of
# the two measured false streams comes straight back.
test_mutant_stop_marker_alone_is_red() {
  local dir head got
  dir=$(make_git_task mutant-marker)
  head=$(wt_commit "$dir/wt" "the work")
  status_line "$dir" mutant-marker 'done: PR https://github.com/o/r/pull/20 checks green run=r-9'
  task_meta "$dir" mutant-marker "pr=https://github.com/o/r/pull/20" "pr_head=$head"

  assert_class "the real library" awaiting-landing "$dir" mutant-marker
  # The operands below are literal library source, not expressions: expanding
  # them would rewrite the operator and the mutation would match nothing, which
  # mutant_answer then refuses as a vacuous proof.
  # shellcheck disable=SC2016
  got=$(mutant_answer stop-marker-alone \
    'elif [ -n "$pr" ]; then' 'elif false; then' \
    "$dir" mutant-marker class)
  [ "$got" = none ] \
    || fail "mutant stop-marker-alone was not red: it still answered '$got' for a done agent left alive"

  pass "MUTANT stop-marker-alone is red: a done-but-alive agent alarms again without the PR acknowledgement"
}

# MUTANT: the state derived from the terminal outcome alone.
# Accepting any terminal verb instead of a completed `done` silences a stopped
# agent whose work is still open - it goes unwatched.
test_mutant_any_terminal_verb_is_red() {
  local dir got
  dir=$(make_task mutant-verb)
  status_line "$dir" mutant-verb 'blocked: the daemon socket refuses connections'
  task_meta "$dir" mutant-verb "pr=https://github.com/o/r/pull/21"
  stop_agent "$dir" mutant-verb

  assert_class "the real library" none "$dir" mutant-verb
  # The operands below are literal library source, not expressions: expanding
  # them would rewrite the operator and the mutation would match nothing, which
  # mutant_answer then refuses as a vacuous proof.
  # shellcheck disable=SC2016
  got=$(mutant_answer any-terminal-verb \
    '[ "$verb" = "done" ] || return 0' 'status_is_terminal_verb "$line" || return 0' \
    "$dir" mutant-verb class)
  [ "$got" = awaiting-landing ] \
    || fail "mutant any-terminal-verb was not red: it answered '$got' for a stopped, still-blocked task"

  pass "MUTANT any-terminal-verb is red: a stopped pre-terminal agent would go unwatched"
}

# MUTANT: the suppression applied unconditionally.
# Real wedges are silenced - the failure that would be worse than the noise.
test_mutant_unconditional_suppression_is_red() {
  local dir got
  dir=$(make_task mutant-uncond)
  status_line "$dir" mutant-uncond 'working: implementing the parser'
  task_meta "$dir" mutant-uncond "pr=https://github.com/o/r/pull/22"

  assert_watched "the real library" "$dir" mutant-uncond
  # The operands below are literal library source, not expressions: expanding
  # them would rewrite the operator and the mutation would match nothing, which
  # mutant_answer then refuses as a vacuous proof.
  # shellcheck disable=SC2016
  got=$(mutant_answer unconditional-suppression \
    '[ "$(fm_awaiting_landing_class "${1-}" "${2-}")" = awaiting-landing ]' ':' \
    "$dir" mutant-uncond quiet)
  [ "$got" = quiet ] \
    || fail "mutant unconditional-suppression was not red: it answered '$got' for a wedged task"

  pass "MUTANT unconditional-suppression is red: a real wedge would be silenced"
}

# MUTANT: 'a pr= is recorded' treated as sufficient - today's behaviour, and
# what would have let the wrong commit merge on 2026-09-17.
test_mutant_recorded_pr_is_sufficient_is_red() {
  local dir abandoned got
  dir=$(make_git_task mutant-diverged)
  abandoned=$(wt_commit "$dir/wt" "the work as first written")
  git -C "$dir/wt" reset --hard -q HEAD~1
  wt_commit "$dir/wt" "the work as rewritten" > /dev/null

  status_line "$dir" mutant-diverged 'done: PR https://github.com/o/r/pull/23 checks green run=r-10'
  task_meta "$dir" mutant-diverged "pr=https://github.com/o/r/pull/23" "pr_head=$abandoned"

  assert_class "the real library" landing-blocked "$dir" mutant-diverged
  # The operands below are literal library source, not expressions: expanding
  # them would rewrite the operator and the mutation would match nothing, which
  # mutant_answer then refuses as a vacuous proof.
  # shellcheck disable=SC2016
  got=$(mutant_answer recorded-pr-is-sufficient \
    'if [ "$pr_head" = "$branch_head" ]; then' 'if :; then' \
    "$dir" mutant-diverged class)
  [ "$got" = awaiting-landing ] \
    || fail "mutant recorded-pr-is-sufficient was not red: it answered '$got' for a diverged PR head"

  pass "MUTANT recorded-pr-is-sufficient is red: a PR holding the wrong commit would read as ready to land"
}

# MUTANT: an ahead head is quiet with NO receipt. The dropped-commits fixture
# (nothing validated it) must go quiet under it, so the receipt requirement is
# proven load-bearing rather than assumed.
test_mutant_ahead_without_receipt_is_red() {
  local dir ahead got
  dir=$(make_git_task mutant-ahead)
  wt_commit "$dir/wt" "the base work" > /dev/null
  ahead=$(wt_commit "$dir/wt" "a commit the local copy later dropped")
  git -C "$dir/wt" reset --hard -q HEAD~1
  status_line "$dir" mutant-ahead 'done: PR https://github.com/o/r/pull/34 checks green run=r-34'
  task_meta "$dir" mutant-ahead "pr=https://github.com/o/r/pull/34" "pr_head=$ahead"
  stop_agent "$dir" mutant-ahead

  assert_class "the real library" landing-blocked "$dir" mutant-ahead
  # shellcheck disable=SC2016
  got=$(mutant_answer ahead-without-receipt \
    'if [ "$shape" = ahead ] && _fm_awaiting_landing_head_validated "$state" "$id" "$pr" "$pr_head"; then' \
    'if [ "$shape" = ahead ]; then' "$dir" mutant-ahead class)
  [ "$got" = awaiting-landing ] \
    || fail "mutant ahead-without-receipt was not red: it answered '$got' for an unvouched ahead head"

  pass "MUTANT ahead-without-receipt is red: dropped, unvalidated commits would read as ready to land"
}

# MUTANT: any recorded divergence is quiet once a receipt exists, ignoring shape.
# The unrelated (rewritten-history) fixture must stay blocked in the real library
# and go quiet under the mutant.
test_mutant_receipt_ignores_shape_is_red() {
  local dir abandoned got
  dir=$(make_git_task mutant-shape)
  abandoned=$(wt_commit "$dir/wt" "the work as first written")
  git -C "$dir/wt" reset --hard -q HEAD~1
  wt_commit "$dir/wt" "the work as rewritten" > /dev/null
  status_line "$dir" mutant-shape 'done: PR https://github.com/o/r/pull/35 checks green run=r-35'
  task_meta "$dir" mutant-shape "pr=https://github.com/o/r/pull/35" "pr_head=$abandoned"
  stop_agent "$dir" mutant-shape
  receipt_for "$dir" mutant-shape 35 "$abandoned"

  assert_class "the real library" landing-blocked "$dir" mutant-shape
  # shellcheck disable=SC2016
  got=$(mutant_answer receipt-ignores-shape \
    'if [ "$shape" = ahead ] && _fm_awaiting' 'if _fm_awaiting' "$dir" mutant-shape class)
  [ "$got" = awaiting-landing ] \
    || fail "mutant receipt-ignores-shape was not red: it answered '$got' for a rewritten-history head"

  pass "MUTANT receipt-ignores-shape is red: a validated but rewritten head would read as ready to land"
}

# MUTANT: leg 1 reads the LAST status line instead of the outcome line - the
# shape shipped until 2026-09-22. The stopped, landed-and-waiting lane whose
# only later event is the resolution firstmate is instructed to record falls
# straight out of the exemption and back onto the stale alarm.
test_mutant_last_status_line_decides_is_red() {
  local dir head got
  dir=$(make_git_task mutant-resolved)
  head=$(wt_commit "$dir/wt" "the work")
  status_line "$dir" mutant-resolved 'done: PR https://github.com/o/r/pull/36 checks green run=r-36'
  task_meta "$dir" mutant-resolved "pr=https://github.com/o/r/pull/36" "pr_head=$head"
  stop_agent "$dir" mutant-resolved
  status_line "$dir" mutant-resolved 'resolved [key=default]: superseded, verified not dismissed'

  assert_class "the real library" awaiting-landing "$dir" mutant-resolved
  # The operands below are literal library source, not expressions: expanding
  # them would rewrite the operator and the mutation would match nothing, which
  # mutant_answer then refuses as a vacuous proof.
  # shellcheck disable=SC2016
  got=$(mutant_answer last-status-line-decides \
    'line=$(status_outcome_line "$state/$id.status")' \
    'line=$(last_status_line "$state/$id.status")' \
    "$dir" mutant-resolved class)
  [ "$got" = none ] \
    || fail "mutant last-status-line-decides was not red: it answered '$got' for a resolution recorded after done"

  pass "MUTANT last-status-line-decides is red: recording a resolution would re-arm the alarm on landed work"
}

# MUTANT: no rebase exception - the library as it shipped before 2026-09-23.
# The validated head the pipeline rebased reads landing-blocked again, which is
# the verdict that raised the stale wake on two stopped workers with green PRs.
test_mutant_no_rebase_exception_is_red() {
  local dir pr_head got
  dir=$(make_git_task mutant-rebased)
  wt_commit "$dir/wt" "the worker's commit" > /dev/null
  pr_head=$(pipeline_rebase "$dir/wt" clean)
  status_line "$dir" mutant-rebased 'done: PR https://github.com/o/r/pull/41 checks green run=r-41'
  task_meta "$dir" mutant-rebased "pr=https://github.com/o/r/pull/41" "pr_head=$pr_head"
  stop_agent "$dir" mutant-rebased
  receipt_for "$dir" mutant-rebased 41 "$pr_head"

  assert_class "the real library" awaiting-landing "$dir" mutant-rebased
  # shellcheck disable=SC2016
  got=$(mutant_answer no-rebase-exception \
    'if [ "$shape" = unrelated ] && _fm_awaiting' 'if false && _fm_awaiting' \
    "$dir" mutant-rebased class)
  [ "$got" = landing-blocked ] \
    || fail "mutant no-rebase-exception was not red: it answered '$got' for a validated rebased head"

  pass "MUTANT no-rebase-exception is red: a stopped worker's validated, rebased PR would alarm again"
}

# MUTANT: the rebase exception without the patch proof. A validated head whose
# replay changed the work would read as ready to land.
test_mutant_rebase_without_patch_proof_is_red() {
  local dir pr_head got
  dir=$(make_git_task mutant-rebase-changed)
  wt_commit "$dir/wt" "the worker's commit" > /dev/null
  pr_head=$(pipeline_rebase "$dir/wt" changed)
  status_line "$dir" mutant-rebase-changed 'done: PR https://github.com/o/r/pull/42 checks green run=r-42'
  task_meta "$dir" mutant-rebase-changed "pr=https://github.com/o/r/pull/42" "pr_head=$pr_head"
  stop_agent "$dir" mutant-rebase-changed
  receipt_for "$dir" mutant-rebase-changed 42 "$pr_head"

  assert_class "the real library" landing-blocked "$dir" mutant-rebase-changed
  # shellcheck disable=SC2016
  got=$(mutant_answer rebase-without-patch-proof \
    '&& _fm_awaiting_landing_carries_branch "$worktree" "$pr_head" "$branch_head" "$stores"; then' '; then' \
    "$dir" mutant-rebase-changed class)
  [ "$got" = awaiting-landing ] \
    || fail "mutant rebase-without-patch-proof was not red: it answered '$got' for a rebase that changed the work"

  pass "MUTANT rebase-without-patch-proof is red: a PR holding different work would read as ready to land"
}

# MUTANT: the rebase exception without the receipt. A rebased head nothing
# validated would read as ready to land.
test_mutant_rebase_without_receipt_is_red() {
  local dir pr_head got
  dir=$(make_git_task mutant-rebase-unvouched)
  wt_commit "$dir/wt" "the worker's commit" > /dev/null
  pr_head=$(pipeline_rebase "$dir/wt" clean)
  status_line "$dir" mutant-rebase-unvouched 'done: PR https://github.com/o/r/pull/43 checks green run=r-43'
  task_meta "$dir" mutant-rebase-unvouched "pr=https://github.com/o/r/pull/43" "pr_head=$pr_head"
  stop_agent "$dir" mutant-rebase-unvouched

  assert_class "the real library" landing-blocked "$dir" mutant-rebase-unvouched
  # shellcheck disable=SC2016
  got=$(mutant_answer rebase-without-receipt \
    'if [ "$shape" = unrelated ] && _fm_awaiting_landing_head_validated "$state" "$id" "$pr" "$pr_head"' \
    'if [ "$shape" = unrelated ]' "$dir" mutant-rebase-unvouched class)
  [ "$got" = awaiting-landing ] \
    || fail "mutant rebase-without-receipt was not red: it answered '$got' for an unvouched rebased head"

  pass "MUTANT rebase-without-receipt is red: a rebased head nothing validated would read as ready to land"
}

# MUTANT: merges admitted to the patch proof. A merge's own change is invisible
# to patch equivalence, so a rebase that dropped it would read as ready to land.
test_mutant_patch_proof_admits_merges_is_red() {
  local dir pr_head got
  dir=$(make_git_task mutant-merge)
  branch_with_evil_merge "$dir/wt" > /dev/null
  pr_head=$(pipeline_rebase "$dir/wt" clean)
  status_line "$dir" mutant-merge 'done: PR https://github.com/o/r/pull/44 checks green run=r-44'
  task_meta "$dir" mutant-merge "pr=https://github.com/o/r/pull/44" "pr_head=$pr_head"
  stop_agent "$dir" mutant-merge
  receipt_for "$dir" mutant-merge 44 "$pr_head"

  assert_class "the real library" landing-blocked "$dir" mutant-merge
  # shellcheck disable=SC2016
  got=$(mutant_answer patch-proof-admits-merges \
    '[ -z "$merges" ] || return 1' ':' "$dir" mutant-merge class)
  [ "$got" = awaiting-landing ] \
    || fail "mutant patch-proof-admits-merges was not red: it answered '$got' for a rebase that dropped a merge's change"

  pass "MUTANT patch-proof-admits-merges is red: a change made only in a merge could be dropped unseen"
}

# MUTANT: no borrowed stores - the library as it shipped before this change.
# A validated rebase that only the pipeline's gate holds reads landing-blocked
# again, the verdict that raised the 2026-09-23 10:37 stale wake.
test_mutant_no_borrowed_stores_is_red() {
  local dir pr_head got
  dir=$(make_git_task mutant-gate)
  wt_commit "$dir/wt" "the worker's commit" > /dev/null
  make_gate "$dir"
  pr_head=$(gate_pipeline "$dir" rebased)
  assert_copy_lacks "$dir/wt" "$pr_head"
  status_line "$dir" mutant-gate 'done: PR https://github.com/o/r/pull/49 checks green run=r-49'
  task_meta "$dir" mutant-gate "pr=https://github.com/o/r/pull/49" "pr_head=$pr_head"
  stop_agent "$dir" mutant-gate
  receipt_for "$dir" mutant-gate 49 "$pr_head"

  assert_class "the real library" awaiting-landing "$dir" mutant-gate
  # shellcheck disable=SC2016
  got=$(mutant_answer no-borrowed-stores \
    'stores=$(_fm_awaiting_landing_remote_stores "$worktree")' 'stores=' \
    "$dir" mutant-gate class)
  [ "$got" = landing-blocked ] \
    || fail "mutant no-borrowed-stores was not red: it answered '$got' for a validated head only the gate holds"

  pass "MUTANT no-borrowed-stores is red: a stopped worker's validated PR the gate rebased would alarm again"
}

test_finished_work_whose_agent_is_still_alive_is_awaiting_landing
test_a_deliberately_stopped_agent_on_finished_work_is_awaiting_landing
test_a_stopped_agent_with_a_recorded_pr_is_awaiting_landing
test_a_dead_agent_with_no_terminal_outcome_is_never_quiet
test_work_still_open_is_never_awaiting_landing
test_an_unacknowledged_done_claim_is_not_yet_awaiting_landing
test_a_worker_that_resumes_after_done_is_watched_again
test_a_resolution_recorded_after_done_keeps_the_exemption
test_a_correlated_done_line_is_read_through
test_a_pr_head_rewritten_out_of_history_is_landing_blocked
test_a_pr_head_left_behind_by_the_branch_is_landing_blocked
test_an_unvalidated_pr_head_ahead_of_the_branch_is_landing_blocked
test_a_validated_ahead_head_is_awaiting_landing
test_a_receipt_never_rescues_a_behind_or_unrelated_head
test_a_validated_rebased_head_is_awaiting_landing
test_a_receipt_never_rescues_a_rebased_head_missing_the_branch_work
test_a_validated_head_only_the_gate_holds_is_awaiting_landing
test_a_head_only_the_gate_holds_is_still_held_to_the_branch_work
test_an_unverifiable_landing_target_stays_awaiting_landing
test_absent_records_read_as_none
test_every_entry_point_is_safe_under_set_eu
test_mutant_stop_marker_alone_is_red
test_mutant_any_terminal_verb_is_red
test_mutant_unconditional_suppression_is_red
test_mutant_recorded_pr_is_sufficient_is_red
test_mutant_ahead_without_receipt_is_red
test_mutant_receipt_ignores_shape_is_red
test_mutant_last_status_line_decides_is_red
test_mutant_no_rebase_exception_is_red
test_mutant_rebase_without_patch_proof_is_red
test_mutant_rebase_without_receipt_is_red
test_mutant_patch_proof_admits_merges_is_red
test_mutant_no_borrowed_stores_is_red
