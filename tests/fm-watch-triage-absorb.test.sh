#!/usr/bin/env bash
# tests/fm-watch-triage-absorb.test.sh - reap bounds, the pure classifier predicates, benign-wake absorption, pane churn, actionable wakes, and a turn ending with its own run in flight.
# One part of the always-on wake triage tests for bin/fm-watch.sh and the shared
# classifier (bin/fm-classify-lib.sh); shared fixtures live in
# tests/fm-watch-triage-lib.sh. Daemon-side classification/injection lives in
# fm-daemon.test.sh; watcher/lock liveness in fm-watcher-lock.test.sh; the
# durable-queue safety matrix in fm-wake-queue.test.sh.
set -u

# shellcheck source=tests/fm-watch-triage-lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/fm-watch-triage-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-watch-triage-absorb-tests)
# --- stopping a watcher is bounded ------------------------------------------
# Every case below reaps its watcher, so a reap that can block turns one lost
# signal into a silent job-long hang that reads as the fault of whatever change
# was under review. Each case runs its reap under a 20s watchdog, so the old
# unbounded `kill; wait` fails here by name instead of hanging this suite.

# Arm a 20s watchdog that SIGKILLs <pid> and records that it had to, so a reap
# that blocks returns and the case fails by name. Its own sleep is killed on
# stop and its output detached, so it never holds the suite's stdout open.
reap_watchdog() {  # <pid> <fired-flag>
  # shellcheck disable=SC2016 # Expanded by the watchdog subshell.
  ( trap 'kill "$sleeper" 2>/dev/null; exit 0' TERM
    sleep 20 & sleeper=$!
    wait "$sleeper"
    kill -KILL "$1" 2>/dev/null && : > "$2" ) >/dev/null 2>&1 &
  REAP_DOG=$!
}
reap_watchdog_stop() {
  kill "$REAP_DOG" 2>/dev/null || true
  wait "$REAP_DOG" 2>/dev/null || true
}

# The bash 5.2 shape: the watcher's first SIGTERM trap never runs, and it keeps
# polling. A fixture child swallows its first TERM and exits on its second
# through its own EXIT cleanup, as a watcher would once its trap does run.
test_reap_recovers_a_watcher_whose_first_sigterm_was_lost() {
  local dir pid i=0
  dir="$TMP_ROOT/reap-lost-term"
  mkdir -p "$dir"
  # shellcheck disable=SC2016 # Expanded by the child shell.
  bash -c 'seen=0
    trap '\''seen=$((seen + 1)); [ "$seen" -lt 2 ] || exit 0'\'' TERM
    trap '\'': > "$1/cleaned"'\'' EXIT
    : > "$1/ready"
    while :; do sleep 0.1; done' _ "$dir" &
  pid=$!
  while [ ! -e "$dir/ready" ] && [ "$i" -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
  [ -e "$dir/ready" ] || { kill -KILL "$pid" 2>/dev/null; fail "the lost-TERM fixture never started"; }
  reap_watchdog "$pid" "$dir/watchdog-fired"
  FM_TEST_REAP_RESEND_SECS=1 reap "$pid"
  reap_watchdog_stop
  # Never leave the fixture behind: a reap that returned without stopping it
  # would otherwise leak a process into the rest of the run.
  kill -KILL "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  [ ! -e "$dir/watchdog-fired" ] \
    || fail "reap blocked on a watcher whose first SIGTERM was lost until a 20s watchdog killed it"
  [ -e "$dir/cleaned" ] \
    || fail "reap stopped a watcher whose first SIGTERM was lost without letting its own TERM exit run"
  pass "reap re-sends a lost SIGTERM, so the watcher exits through its own cleanup instead of hanging the suite"
}

# A watcher that never honors SIGTERM must end the case loudly and by name,
# within the bound, rather than blocking or vanishing silently.
test_reap_fails_loudly_on_a_watcher_that_ignores_sigterm() {
  local dir pid rc=0 i=0
  dir="$TMP_ROOT/reap-ignored-term"
  mkdir -p "$dir"
  # shellcheck disable=SC2016 # Expanded by the child shell.
  bash -c 'trap "" TERM; : > "$1/ready"; while :; do sleep 0.1; done' _ "$dir" &
  pid=$!
  while [ ! -e "$dir/ready" ] && [ "$i" -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
  [ -e "$dir/ready" ] || { kill -KILL "$pid" 2>/dev/null; fail "the TERM-ignoring fixture never started"; }
  reap_watchdog "$pid" "$dir/watchdog-fired"
  ( FM_TEST_REAP_RESEND_SECS=1 FM_TEST_REAP_BOUND_SECS=3 reap "$pid" ) 2> "$dir/reap.err" || rc=$?
  reap_watchdog_stop
  kill -KILL "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  [ ! -e "$dir/watchdog-fired" ] || fail "reap never gave up on a watcher that ignores SIGTERM"
  [ "$rc" -eq 1 ] || fail "reap let a watcher that ignores SIGTERM pass silently (rc=$rc)"
  grep -Fq "not ok - process $pid did not exit within 3s of repeated SIGTERM" "$dir/reap.err" \
    || fail "reap's failure did not name the watcher it gave up on: $(cat "$dir/reap.err")"
  pass "reap gives up on a watcher that ignores SIGTERM within its bound, kills it, and fails naming it"
}

# --- pure classifier predicates (fm-classify-lib.sh) ------------------------


test_status_span_actionable_classifier() {
  local dir state offset
  dir=$(make_case classify-signal); state="$dir/state"
  printf 'working: step 1\nworking: step 2\n' > "$state/a.status"
  status_span_has_actionable "$state/a.status" 0 && fail "benign working: span classified actionable"
  printf 'working: x\nneeds-decision: pick A or B\n' > "$state/b.status"
  status_span_has_actionable "$state/b.status" 0 || fail "captain-relevant span classified benign"
  # A failure and a merge result are captain-relevant and must always wake.
  printf 'failed: build broke on main\n' > "$state/d.status"
  status_span_has_actionable "$state/d.status" 0 || fail "a failed: line was not actionable"
  printf 'merged\n' > "$state/e.status"
  status_span_has_actionable "$state/e.status" 0 || fail "a legacy merged line was not actionable"
  # An offset past the whole log has nothing left to classify: an event already
  # classified must not re-fire on the next append.
  offset=$(size_of "$state/b.status")
  status_span_has_actionable "$state/b.status" "$offset" \
    && fail "an already-classified needs-decision re-fired from its own end offset"
  printf 'working: tidying up\n' >> "$state/b.status"
  status_span_has_actionable "$state/b.status" "$offset" \
    && fail "a routine append after a classified decision was classified actionable"
  # An unusable offset (absent, malformed, or past a truncated log) reads the
  # whole file rather than losing the events it cannot account for.
  status_span_has_actionable "$state/b.status" "" || fail "an empty offset did not read the whole log"
  status_span_has_actionable "$state/b.status" "not-a-number" || fail "a malformed offset did not read the whole log"
  status_span_has_actionable "$state/b.status" 99999 || fail "an offset past the log did not read the whole log"
  pass "status_span_has_actionable: benign absorbed, captain events surfaced, classified events not re-fired"
}

# The reported bug, at the classifier: an actionable event followed by a ROUTINE
# append must stay actionable, and must be reported as ITSELF rather than as the
# routine line that happens to sit last.
test_status_span_survives_a_later_routine_append() {
  local dir state event
  dir=$(make_case classify-masked); state="$dir/state"
  printf 'working: setup\nneeds-decision: pick A or B\nworking: still tidying the branch\n' \
    > "$state/mask.status"
  status_span_has_actionable "$state/mask.status" 0 \
    || fail "a needs-decision hidden behind a later working: line was classified routine"
  event=$(status_span_first_actionable "$state/mask.status" 0)
  [ "$event" = "needs-decision: pick A or B" ] \
    || fail "the span reported '$event' instead of the decision it found"
  # The captain-reported shape: a finished release/install reported as done and
  # then followed by routine cleanup chatter must still reach the captain.
  printf 'working: publishing\ndone: release 1.4.0 published and installed\nworking: cleaning the build dir\nnote: cache pruned\n' \
    > "$state/release.status"
  status_span_has_actionable "$state/release.status" 0 \
    || fail "a done: completion hidden behind later routine appends was classified routine"
  event=$(status_span_first_actionable "$state/release.status" 0)
  [ "$event" = "done: release 1.4.0 published and installed" ] \
    || fail "the span reported '$event' instead of the completion it found"
  # A blocker is the away-mode shape of the same masking.
  printf 'blocked: cannot reach the release host\npaused: waiting for release access\n' \
    > "$state/blocked.status"
  status_span_has_actionable "$state/blocked.status" 0 \
    || fail "a blocked: event hidden behind a current wait was classified routine"
  pass "an actionable event is not hidden by later routine appends, and is named as itself"
}

# Closure is the one thing that may retire an event inside a span, and only
# through status_open_decisions' own open/closed rule.
test_status_span_respects_decision_closure() {
  local dir state event open
  dir=$(make_case classify-closure); state="$dir/state"
  printf 'needs-decision [key=api]: pick A or B\nresolved [key=api]: took A\n' > "$state/closed.status"
  status_span_has_actionable "$state/closed.status" 0 \
    && fail "a decision the same span already closed was still classified actionable"
  # Reopening the SAME key after a close must survive: the close belongs to the
  # earlier opening, not to the one that came after it.
  printf 'needs-decision [key=api]: pick A or B\nresolved [key=api]: took A\nneeds-decision: [key=api] pick A or B\n' \
    > "$state/reopened.status"
  event=$(status_span_first_actionable "$state/reopened.status" 0) \
    || fail "a decision reopened under a key that was closed earlier was classified routine"
  [ "$event" = "needs-decision: [key=api] pick A or B" ] \
    || fail "the reopened key surfaced its closed opening instead of the live reopening: $event"
  # A terminal event is never retired by a later closure line.
  printf 'failed: build broke on main\nresolved [key=api]: unrelated\n' > "$state/term.status"
  status_span_has_actionable "$state/term.status" 0 \
    || fail "a failed: event was retired by an unrelated closure"
  # A live decision must survive a NEWER closure that belongs to another key.
  printf 'needs-decision [key=api]: pick A or B\nneeds-decision [key=db]: pick a store\nresolved [key=db]: took sqlite\n' \
    > "$state/two.status"
  event=$(status_span_first_actionable "$state/two.status" 0) \
    || fail "a still-open decision was retired by a newer closure under another key"
  [ "$event" = "needs-decision [key=api]: pick A or B" ] \
    || fail "the span reported '$event' instead of the decision still open"
  printf 'needs-decision [key=pending-reply-x]: unrelated request\nworking: awaiting reconciliation\n' \
    > "$state/rejected-reserved.status"
  event=$(status_span_first_actionable "$state/rejected-reserved.status" 0) \
    || fail "a rejected reserved-key request was silently dropped"
  [ "$event" = "reconciliation-required: needs-decision [key=pending-reply-x]: unrelated request" ] \
    || fail "a rejected reserved-key request was not labeled for reconciliation: $event"
  open=$(status_open_decisions "$state/rejected-reserved.status")
  [ -z "$open" ] \
    || fail "span classification treated a rejected reserved-key request as an open decision: $open"
  pass "span classification retires closed decisions and surfaces rejected transitions for reconciliation"
}

test_malformed_seen_signature_reads_the_whole_log() {
  local dir state f marker offset
  dir=$(make_case malformed-seen); state="$dir/state"; f="$state/task.status"
  printf 'needs-decision: choose the release target\nworking: cleanup\n' > "$f"
  marker="$state/.seen-task_status"
  printf '40' > "$marker"
  offset=$(bash -c '. "$1"; fm_wake_signal_seen_size "$2" "$3"' _ \
    "$ROOT/bin/fm-wake-lib.sh" "$state" "$f")
  [ "$offset" = 0 ] \
    || fail "a digits-only malformed seen signature was accepted as an offset"
  status_span_has_actionable "$f" "$offset" \
    || fail "a malformed seen signature skipped the actionable start of the log"
  pass "a malformed seen signature causes the whole status log to be classified"
}

test_stale_is_terminal_classifier() {
  local dir state
  dir=$(make_case classify-stale); state="$dir/state"
  printf 'done: ready in branch fm/x\n' > "$state/term.status"
  stale_is_terminal "sess:fm-term" "$state" || fail "terminal stale status not classified terminal"
  fm_write_meta "$state/herdr-term.meta" "window=default:w1:p2" "backend=herdr"
  printf 'done: ready in branch fm/herdr\n' > "$state/herdr-term.status"
  stale_is_terminal "default:w1:p2" "$state" || fail "terminal herdr stale status not resolved through metadata"
  printf 'working: compiling\n' > "$state/nonterm.status"
  stale_is_terminal "sess:fm-nonterm" "$state" && fail "non-terminal stale classified terminal"
  stale_is_terminal "sess:fm-missing" "$state" && fail "stale with no status classified terminal"
  pass "stale_is_terminal: terminal status surfaces, non-terminal and no-status are benign"
}

test_classifier_primitives() {
  local dir state open activity
  dir=$(make_case classify-primitives); state="$dir/state"
  printf 'working: a\n\ndone: b\n\n' > "$state/x.status"
  [ "$(last_status_line "$state/x.status")" = "done: b" ] || fail "last_status_line did not return the last non-blank line"
  status_is_captain_relevant "done: b" || fail "done: not recognized as captain-relevant"
  status_is_captain_relevant "needs-decision [key=q1]: b" || fail "keyed needs-decision not recognized as captain-relevant"
  status_is_captain_relevant "working: b" && fail "working: wrongly recognized as captain-relevant"
  # Incident regression: free-text "merged" inside a nonterminal working: line must
  # not become captain-relevant (AFK false-terminal path).
  status_is_captain_relevant \
    "working: stage 2 setup complete on PR #74 exact source branch rebased onto merged #76; task dates preserved" \
    && fail "working: ... merged #N wrongly recognized as captain-relevant"
  status_is_captain_relevant "working: rebased onto predecessor #76" \
    && fail "working: predecessor prose wrongly recognized as captain-relevant"
  status_is_captain_relevant "working: PR ready checks green merged ready in branch" \
    && fail "working: free-text tokens wrongly recognized as captain-relevant"
  status_is_captain_relevant "done: PR https://x/pull/76 checks green" \
    || fail "genuine done: checks green not captain-relevant"
  status_is_terminal_verb "done: PR https://x/pull/76 checks green" \
    || fail "done: not a terminal verb"
  status_is_terminal_verb "working: rebased onto merged #76" \
    && fail "working: wrongly classed as terminal verb"
  status_is_captain_relevant "merged" || fail "legacy bare merged free-text not captain-relevant"
  status_is_captain_relevant "PR ready https://x/pull/2" \
    || fail "legacy bare PR ready free-text not captain-relevant"
  [ "$(window_to_task "sess:fm-fix-login-k3")" = "fix-login-k3" ] || fail "window_to_task did not strip session+fm- prefix"
  fm_write_meta "$state/herdr-task.meta" "window=default:w1:p2" "backend=herdr"
  [ "$(window_to_task "default:w1:p2" "$state")" = "herdr-task" ] || fail "window_to_task did not resolve opaque backend target through metadata"
  FM_CAPTAIN_RE='custom-verb:' status_is_captain_relevant "custom-verb: x" || fail "FM_CAPTAIN_RE override not honored"
  FM_CAPTAIN_RE='custom-verb:' status_is_captain_relevant "done: x" && fail "FM_CAPTAIN_RE override did not replace the default verb set"
  FM_CAPTAIN_RE='merged|custom-verb:' status_is_captain_relevant "working: rebased onto merged #76" \
    && fail "FM_CAPTAIN_RE override bypassed working: suppression"
  FM_CAPTAIN_RE='checks green|custom-verb:' status_is_captain_relevant "paused: checks green pending approval" \
    && fail "FM_CAPTAIN_RE override bypassed paused: suppression"
  FM_CAPTAIN_RE='custom-verb:' status_is_captain_relevant "custom-verb: x" \
    || fail "nonterminal suppression weakened custom bare-line behavior"
  printf 'needs-decision: should docs mention [key=prose]?\nneeds-decision [key=q1]: real choice\nresolved: docs still mention [key=q1]\nneeds-decision [key=bad key]: malformed\n' > "$state/keys.status"
  open=$(status_open_decisions "$state/keys.status")
  printf '%s' "$open" | grep -F $'q1\t' >/dev/null \
    || fail "a key token in resolved note prose closed the keyed decision"
  printf '%s' "$open" | grep -F $'prose\t' >/dev/null \
    && fail "a key token in note prose changed the decision key"
  printf '%s' "$open" | grep -F $'bad key\t' >/dev/null \
    && fail "an invalid key slug entered the open-decision set"
  cat > "$state/activity.status" <<'EOF'
working [key=phase7]: Phase 7 started
working [key=phase6]: Phase 6 started
working [key=legal]: reviewing legal dependency
done [key=phase6]: Phase 6 completed
resolved [key=phase7]: Phase 7 completed and moved to Done
paused [key=legal]: awaiting external counsel
resolved [key=legal]: legal item returned to the queue
working [key=phase8]: Phase 8 started
EOF
  activity=$(status_open_activities "$state/activity.status")
  printf '%s' "$activity" | grep -F $'phase8\tworking\tPhase 8 started' >/dev/null \
    || fail "the current keyed working phase was not retained"
  printf '%s' "$activity" | grep -F $'phase7\t' >/dev/null \
    && fail "a keyed resolved event did not close the older working phase"
  printf '%s' "$activity" | grep -F $'phase6\t' >/dev/null \
    && fail "a same-key terminal event did not supersede the older working phase"
  printf '%s' "$activity" | grep -F $'legal\t' >/dev/null \
    && fail "a keyed resolved event did not close the declared pause"
  printf 'working: legacy start\ndone: legacy completion\n' > "$state/legacy-activity.status"
  [ -z "$(status_open_activities "$state/legacy-activity.status")" ] \
    || fail "a legacy terminal event did not supersede the default working phase"
  pass "classifier primitives: keyed decisions and activity phases, captain relevance, window-to-task, and overrides"
}

# crew_is_provably_working: the absorb-only-when-provably-working predicate. It is
# benign (absorb) ONLY when fm-crew-state.sh reports the crew as working from an
# actively-running pipeline step (source run-step) or a busy pane (source pane);
# everything else - a stale working: status-log line, a finished/parked/failed run,
# an unknown/torn-down crew, or an empty id - is NOT provable, so it surfaces. The
# fake fm-crew-state.sh (FM_CREW_STATE_BIN) returns a canned verdict per case.
test_crew_is_provably_working_classifier() {
  local dir fakebin
  dir=$(make_case provably-working); fakebin="$dir/fakebin"
  # Point the predicate at this case's hermetic fake and drive its verdict per case.
  # export marks the var for the fake subprocess; it is unset again at the end so it
  # cannot leak into a later test (every behavioral test sets its own verdict anyway).
  export FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh"
  export FM_FAKE_CREW_STATE
  FM_FAKE_CREW_STATE='state: working · source: run-step · validating (running)'
  crew_is_provably_working a || fail "active run-step not treated as provably working"
  FM_FAKE_CREW_STATE='state: working · source: pane · harness busy'
  crew_is_provably_working a || fail "busy pane not treated as provably working"
  FM_FAKE_CREW_STATE='state: working · source: status-log · working: compiling'
  ! crew_is_provably_working a || fail "stale status-log working: treated as provably working"
  FM_FAKE_CREW_STATE='state: done · source: run-step · checks green'
  ! crew_is_provably_working a || fail "finished run treated as provably working"
  FM_FAKE_CREW_STATE='state: parked · source: run-step · parked at review'
  ! crew_is_provably_working a || fail "parked run treated as provably working"
  FM_FAKE_CREW_STATE='state: failed · source: run-step · run failed'
  ! crew_is_provably_working a || fail "failed run treated as provably working"
  FM_FAKE_CREW_STATE='state: unknown · source: none · worktree gone'
  ! crew_is_provably_working a || fail "unknown crew treated as provably working"
  FM_FAKE_CREW_STATE='state: working · source: run-step · x'
  ! crew_is_provably_working "" || fail "empty id treated as provably working"
  unset FM_FAKE_CREW_STATE
  pass "crew_is_provably_working: only working+run-step/pane is provable; idle/finished/parked/failed/unknown surface"
}

# status_is_paused: the shared pause verb test both consumers read (so neither
# hardcodes the literal). Matches only the verb before the first colon, so a reason
# that merely mentions "paused" does not false-match, and a genuine blocker stays a
# blocker.
test_status_is_paused_classifier() {
  status_is_paused 'paused: holding for the upstream release' || fail "paused verb not recognized"
  status_is_paused '  paused:   waiting on a rate-limit reset' || fail "leading-space paused verb not recognized"
  status_is_paused 'blocked: the build is paused upstream' && fail "a blocked line mentioning paused false-matched"
  status_is_paused 'working: paused the animation loop' && fail "a working line mentioning paused false-matched"
  status_is_paused 'done: shipped' && fail "done classified as paused"
  status_is_paused '' && fail "empty line classified as paused"
  # A pause is deliberately NOT captain-relevant: it is a stop-nagging signal, not
  # work to keep surfacing.
  status_is_captain_relevant 'paused: holding for the upstream release' && fail "paused is captain-relevant (should not be)"
  status_is_paused_or_captain_held 'paused: holding for the upstream release' \
    || fail "declared pause not recognized by the bounded-idle classifier"
  status_is_paused_or_captain_held 'captain-held [key=route]: tracked by task-decision-route' \
    || fail "captain-held transfer not recognized by the bounded-idle classifier"
  status_is_paused_or_captain_held 'resolved [key=route]: captain answered' \
    && fail "resolved decision remained classed as captain-held"
  # The two declarations share one cadence but block on different humans, so the
  # combined predicate cannot be the only discriminator: a recheck has to know which
  # verb it is naming.
  status_is_captain_held 'captain-held [key=route]: tracked by task-decision-route' \
    || fail "captain-held verb not recognized"
  status_is_captain_held 'paused: holding for the upstream release' \
    && fail "a declared pause matched the captain-held verb"
  status_is_captain_held 'working: the captain-held backlog item is next' \
    && fail "a working line mentioning captain-held false-matched"
  status_is_captain_held '' && fail "empty line classified as captain-held"
  pass "status_is_paused: only the leading paused verb matches, paused is not captain-relevant, and the two declared-wait verbs stay separable"
}

# crew_absorb_class: the single fm-crew-state.sh read that returns BOTH absorb
# reasons - working (active run/busy pane), paused (declared external wait), or none
# (surface it) - so the watcher's stale path gets both for one bounded call.
# crew_is_paused delegates to it exactly as crew_is_provably_working does.
test_crew_absorb_class_classifier() {
  local dir fakebin
  dir=$(make_case absorb-class); fakebin="$dir/fakebin"
  export FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh"
  export FM_FAKE_CREW_STATE
  FM_FAKE_CREW_STATE='state: working · source: run-step · validating (running)'
  [ "$(crew_absorb_class a)" = working ] || fail "active run-step not classed working"
  FM_FAKE_CREW_STATE='state: working · source: pane · harness busy'
  [ "$(crew_absorb_class a)" = working ] || fail "busy pane not classed working"
  FM_FAKE_CREW_STATE='state: paused · source: status-log · awaiting upstream'
  [ "$(crew_absorb_class a)" = paused ] || fail "declared pause not classed paused"
  crew_is_paused a || fail "crew_is_paused did not recognize a paused verdict"
  ! crew_is_provably_working a || fail "a paused crew was treated as provably working"
  FM_FAKE_CREW_STATE='state: working · source: status-log · working: compiling'
  [ "$(crew_absorb_class a)" = none ] || fail "stale working: status-log classed absorbable"
  FM_FAKE_CREW_STATE='state: unknown · source: none · worktree gone'
  [ "$(crew_absorb_class a)" = none ] || fail "unknown crew classed absorbable"
  ! crew_is_paused a || fail "unknown crew classed paused"
  [ "$(crew_absorb_class "")" = none ] || fail "empty id not classed none"
  unset FM_FAKE_CREW_STATE
  pass "crew_absorb_class: working/paused/none from one read; crew_is_paused and crew_is_provably_working agree"
}

# The wedge detector's third liveness input: writes inside the crew's own recorded
# worktree. Every negative outcome must report "no evidence" so the caller keeps
# its existing escalation schedule, and a supervisor-side git read (which touches
# .git, never tracked files) must not be able to fake a positive.
test_crew_worktree_written_since_classifier() {
  local dir state anchor wt home statedir_wt
  dir=$(make_case classify-worktree-writes); state="$dir/state"
  anchor="$state/anchor"; wt="$dir/wt"; home="$dir/mate-home"; statedir_wt="$dir/wt-with-state"
  mkdir -p "$wt/src" "$wt/.git/objects"
  printf 'old\n' > "$wt/src/existing.c"
  set_mtime "$(( $(date +%s) - 300 ))" "$wt/src/existing.c"
  : > "$anchor"
  set_mtime "$(( $(date +%s) - 120 ))" "$anchor"

  # No recorded worktree at all: absence of evidence, never a positive.
  printf 'window=test:fm-a\nkind=ship\n' > "$state/a.meta"
  ! crew_worktree_written_since a "$state" "$anchor" \
    || fail "a task with no recorded worktree reported write evidence"
  # Recorded but gone (torn down): still no evidence.
  printf 'window=test:fm-b\nkind=ship\nworktree=%s\n' "$dir/missing" > "$state/b.meta"
  ! crew_worktree_written_since b "$state" "$anchor" \
    || fail "a torn-down worktree reported write evidence"
  # Present, but nothing written since the anchor.
  printf 'window=test:fm-c\nkind=ship\nworktree=%s\n' "$wt" > "$state/c.meta"
  ! crew_worktree_written_since c "$state" "$anchor" \
    || fail "a quiet worktree reported write evidence"
  # A missing anchor cannot be compared against: no evidence.
  ! crew_worktree_written_since c "$state" "$state/absent-anchor" \
    || fail "a missing anchor reported write evidence"
  # Only .git churn (what firstmate's own read-only git commands touch): pruned.
  printf 'pack\n' > "$wt/.git/objects/fresh"
  printf 'ref\n' > "$wt/.git/index"
  ! crew_worktree_written_since c "$state" "$anchor" \
    || fail ".git churn alone reported write evidence (a supervisor read could fake liveness)"
  # A real file written after the anchor: positive evidence.
  printf 'new\n' > "$wt/src/new.c"
  crew_worktree_written_since c "$state" "$anchor" \
    || fail "a file written after the anchor was not reported as write evidence"
  # An empty id is never evidence.
  ! crew_worktree_written_since "" "$state" "$anchor" || fail "an empty id reported write evidence"

  # A secondmate records a provisioned firstmate home, not a code tree, and such a
  # home supervises itself: its own watcher beacon, pane hashes, and heartbeats keep
  # its state/ churning whether or not the mate produced anything.
  mkdir -p "$home/state"
  printf 'sm-classify-1\n' > "$home/.fm-secondmate-home"
  printf 'beat\n' > "$home/state/.last-watcher-beat"
  printf 'window=remote:sm\nkind=secondmate\nworktree=%s\n' "$home" > "$state/sm.meta"
  ! crew_worktree_written_since sm "$state" "$anchor" \
    || fail "a secondmate's own home supervision churn reported crew write evidence"
  # The home marker alone is enough, even when the record does not say secondmate.
  printf 'window=test:fm-sm2\nkind=ship\nworktree=%s\n' "$home" > "$state/sm2.meta"
  ! crew_worktree_written_since sm2 "$state" "$anchor" \
    || fail "a marked firstmate home reported crew write evidence"
  # But an ordinary worktree that merely holds a directory named state is real
  # work: only the home is excluded, never a source directory of that name.
  mkdir -p "$statedir_wt/state"
  printf 'machine\n' > "$statedir_wt/state/machine.go"
  printf 'window=test:fm-d\nkind=ship\nworktree=%s\n' "$statedir_wt" > "$state/d.meta"
  crew_worktree_written_since d "$state" "$anchor" \
    || fail "a source directory named state was hidden from the write probe"
  pass "crew_worktree_written_since: real writes are evidence; no worktree, no anchor, quiet trees, .git churn and a mate's own home are not"
}

# FM_WORKTREE_WRITE_PRUNE is a skip list, so clearing it skips nothing and is the
# obvious way to widen the probe to the whole depth-bounded tree. An empty list must
# therefore widen the walk rather than report no evidence at all, which would
# quietly cost the wedge detector its third liveness input on a home that cleared
# the knob to get more coverage, not less.
test_empty_write_prune_widens_the_probe() {
  local dir state anchor wt saved
  dir=$(make_case classify-empty-write-prune); state="$dir/state"
  anchor="$state/anchor"; wt="$dir/wt"
  mkdir -p "$wt/src" "$wt/.git"
  : > "$anchor"
  set_mtime "$(( $(date +%s) - 120 ))" "$anchor"
  printf 'window=test:fm-e\nkind=ship\nworktree=%s\n' "$wt" > "$state/e.meta"
  saved=$FM_WORKTREE_WRITE_PRUNE
  FM_WORKTREE_WRITE_PRUNE=''
  # A quiet tree is still no evidence, so the caller's schedule is untouched.
  ! crew_worktree_written_since e "$state" "$anchor" \
    || fail "an empty prune list reported write evidence for a quiet worktree"
  printf 'new\n' > "$wt/src/new.c"
  crew_worktree_written_since e "$state" "$anchor" \
    || fail "an empty prune list disabled the probe instead of widening it"
  # Widened means nothing is skipped, including what the default list prunes.
  set_mtime "$(( $(date +%s) - 900 ))" "$wt/src/new.c"
  printf 'pack\n' > "$wt/.git/index"
  crew_worktree_written_since e "$state" "$anchor" \
    || fail "an empty prune list still skipped a directory the default list prunes"
  # Restoring the default prunes .git again, so a supervisor's own read-only git
  # command still cannot fake liveness.
  FM_WORKTREE_WRITE_PRUNE=$saved
  ! crew_worktree_written_since e "$state" "$anchor" \
    || fail "the default prune list stopped keeping .git out of the probe"
  pass "an empty FM_WORKTREE_WRITE_PRUNE widens the probe to the whole depth-bounded tree instead of disabling it"
}

# The same widening, reached the way a home actually configures it: through the
# process ENVIRONMENT, not an in-process assignment made after the library was
# sourced. An empty exported value must survive as empty, because defaulting it with
# the colon form reads "explicitly cleared" as "never set" and hands the default skip
# list straight back to the one home that asked for a wider walk.
# shellcheck disable=SC2016 # single quotes are deliberate: the library path, state dir, and anchor expand inside the bash -c child, not here
test_empty_write_prune_from_the_environment_widens_the_probe() {
  local dir state anchor wt
  dir=$(make_case classify-empty-write-prune-env); state="$dir/state"
  anchor="$state/anchor"; wt="$dir/wt"
  mkdir -p "$wt/.git/objects"
  : > "$anchor"
  set_mtime "$(( $(date +%s) - 120 ))" "$anchor"
  printf 'window=test:fm-wenv\nkind=ship\nworktree=%s\n' "$wt" > "$state/wenv.meta"
  # The one thing written since the anchor sits exactly where the DEFAULT list prunes.
  printf 'pack\n' > "$wt/.git/objects/fresh"
  env -u FM_WORKTREE_WRITE_PRUNE \
    bash -c '. "$1"; crew_worktree_written_since wenv "$2" "$3"' _ \
    "$ROOT/bin/fm-classify-lib.sh" "$state" "$anchor" \
    && fail "the default skip list let .git churn count as write evidence"
  FM_WORKTREE_WRITE_PRUNE='' \
    bash -c '. "$1"; crew_worktree_written_since wenv "$2" "$3"' _ \
    "$ROOT/bin/fm-classify-lib.sh" "$state" "$anchor" \
    || fail "an empty FM_WORKTREE_WRITE_PRUNE in the environment fell back to the default skip list instead of widening the probe"
  pass "an empty FM_WORKTREE_WRITE_PRUNE exported into the environment prunes nothing, widening the probe"
}

# The probe's walk runs synchronously inside the poll that was about to escalate, so
# it must be wall-clock bounded: -xdev keeps it out of a nested mount, but a worktree
# root that is ITSELF on a hung mount would otherwise stall the very supervisor that
# exists to notice a wedge. A fake find that never returns in time stands in for that
# mount. Hitting the bound must read as NO evidence, exactly like every other
# negative outcome, so the caller's escalation schedule is untouched.
test_worktree_write_probe_is_wall_clock_bounded() {
  local dir state anchor wt slowbin fastbin started elapsed
  dir=$(make_case classify-write-probe-bound); state="$dir/state"
  anchor="$state/anchor"; wt="$dir/wt"; slowbin="$dir/slowbin"; fastbin="$dir/fastbin"
  mkdir -p "$wt/src" "$slowbin" "$fastbin"
  : > "$anchor"
  set_mtime "$(( $(date +%s) - 120 ))" "$anchor"
  printf 'window=test:fm-slow\nkind=ship\nworktree=%s\n' "$wt" > "$state/slow.meta"
  # Both stand-ins report the same hit; only one of them takes longer than the bound
  # to do it, so the prompt one shows what a positive outcome looks like and the
  # bounded assertion below cannot pass merely because the fake failed.
  cat > "$fastbin/find" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$1/hit"
SH
  cat > "$slowbin/find" <<'SH'
#!/usr/bin/env bash
set -u
sleep 30
printf '%s\n' "$1/hit"
SH
  chmod +x "$fastbin/find" "$slowbin/find"
  PATH="$fastbin:$PATH" \
    bash -c '. "$1"; crew_worktree_written_since slow "$2" "$3"' _ \
    "$ROOT/bin/fm-classify-lib.sh" "$state" "$anchor" \
    || fail "a walk that reported a hit inside its bound was not read as write evidence"
  started=$(date +%s)
  PATH="$slowbin:$PATH" FM_WORKTREE_WRITE_TIMEOUT=1 \
    bash -c '. "$1"; crew_worktree_written_since slow "$2" "$3"' _ \
    "$ROOT/bin/fm-classify-lib.sh" "$state" "$anchor" \
    && fail "a walk that outlived its bound was reported as write evidence"
  elapsed=$(( $(date +%s) - started ))
  [ "$elapsed" -lt 10 ] \
    || fail "the worktree write probe was not wall-clock bounded: one walk held the caller for ${elapsed}s"
  pass "the worktree write probe is wall-clock bounded, and hitting the bound reads as no write evidence"
}

# signal_crew_provably_working: a no-verb "signal:" wake is benign ONLY when EVERY
# task it references is provably working; if any crew has stopped, or no task can be
# resolved, it surfaces. Files map to ids by stripping .status / .turn-ended.
test_signal_crew_provably_working_classifier() {
  local dir fakebin state
  dir=$(make_case signal-provably-working); fakebin="$dir/fakebin"; state="$dir/state"
  export FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh"
  export FM_FAKE_CREW_STATE_a='state: working · source: run-step · running'
  export FM_FAKE_CREW_STATE_b='state: done · source: run-step · run passed'
  signal_crew_provably_working "$state/a.status" "$state/a.turn-ended" \
    || fail "a single provably-working crew (status+turn-end) was not benign"
  ! signal_crew_provably_working "$state/a.status" "$state/b.turn-ended" \
    || fail "a coalesced batch including a stopped crew was treated as benign"
  ! signal_crew_provably_working "$state/b.turn-ended" \
    || fail "a stopped crew's bare turn-end was treated as benign"
  ! signal_crew_provably_working "$state/a.meta" \
    || fail "a non-signal file resolved to a benign verdict"
  ! signal_crew_provably_working \
    || fail "an empty signal file list was treated as benign"
  unset FM_FAKE_CREW_STATE_a FM_FAKE_CREW_STATE_b
  pass "signal_crew_provably_working: benign only when every referenced crew is provably working"
}

test_secondmate_status_signal_never_absorbed_classifier() {
  local dir fakebin state
  dir=$(make_case secondmate-signal-classify); fakebin="$dir/fakebin"; state="$dir/state"
  export FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh"
  # Even PROVABLY working, a secondmate's .status signal is its routed-reply
  # channel and must surface; its bare turn-ended keeps the ordinary absorb.
  export FM_FAKE_CREW_STATE_sm='state: working · source: run-step · running'
  printf 'kind=secondmate\n' > "$state/sm.meta"
  printf 'working: routed reply for the parent\n' > "$state/sm.status"
  ! signal_crew_provably_working "$state/sm.status" \
    || fail "a working secondmate's status signal was treated as absorbable"
  signal_crew_provably_working "$state/sm.turn-ended" \
    || fail "a working secondmate's bare turn-end lost its ordinary absorb"
  # An ordinary crewmate with the same verdict stays absorbable: the rule is
  # keyed on recorded kind, not on task naming or content guessing.
  export FM_FAKE_CREW_STATE_crew='state: working · source: run-step · running'
  printf 'kind=ship\n' > "$state/crew.meta"
  printf 'working: progress\n' > "$state/crew.status"
  signal_crew_provably_working "$state/crew.status" \
    || fail "the secondmate rule leaked onto an ordinary crewmate status"
  unset FM_FAKE_CREW_STATE_sm FM_FAKE_CREW_STATE_crew
  pass "a secondmate's status signal is never absorbed as provably working; crewmates are unaffected"
}

# --- benign wakes are absorbed ONLY when the crew is provably working ---------

test_provably_working_signal_absorbed() {
  local dir state fakebin out status_file pid
  dir=$(make_case provably-working-signal); state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/watch.out"
  status_file="$state/task.status"
  printf 'working: compiling step 2\n' > "$status_file"
  # The crew's pipeline is in an actively-running step: positive evidence it is
  # still working, so a no-verb working: signal is absorbed (the original low-churn
  # case during a long validation).
  export FM_FAKE_CREW_STATE='state: working · source: run-step · validating (running)'
  watch_bg "$state" "$fakebin" "$out"
  pid=$!
  if ! wait_poll_cycle "$state" "$pid"; then
    reap "$pid"; fail "watcher exited for a working: signal whose crew is provably working (should absorb): $(cat "$out")"
  fi
  [ ! -s "$out" ] || fail "provably-working signal printed a wake reason: $(cat "$out")"
  [ ! -s "$state/.wake-queue" ] || fail "provably-working signal enqueued a durable wake record"
  [ -s "$state/.seen-task_status" ] || fail "provably-working signal did not advance its .seen-* suppressor"
  [ -e "$state/.last-watcher-beat" ] || fail "watcher beacon was not touched while absorbing"
  reap "$pid"
  pass "a no-verb signal whose crew is provably working is absorbed (no exit, no queue, suppressor advanced, beacon present)"
}

test_turn_ended_provably_working_absorbed() {
  local dir state fakebin out pid
  dir=$(make_case turn-ended-working); state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/watch.out"
  : > "$state/task.turn-ended"
  # A busy pane is the second form of positive evidence (covers a queued
  # continuation right after the turn-end).
  export FM_FAKE_CREW_STATE='state: working · source: pane · harness busy'
  watch_bg "$state" "$fakebin" "$out"
  pid=$!
  if ! wait_poll_cycle "$state" "$pid"; then
    reap "$pid"; fail "watcher exited for a turn-end whose crew is provably working (should absorb): $(cat "$out")"
  fi
  [ ! -s "$out" ] || fail "provably-working turn-end printed a wake reason: $(cat "$out")"
  [ ! -s "$state/.wake-queue" ] || fail "provably-working turn-end enqueued a durable wake record"
  reap "$pid"
  pass "a bare turn-end whose crew is provably working (busy pane) is absorbed"
}

# --- a no-verb signal whose crew is NOT provably working SURFACES -------------
# This is the swallowed-finish fix: a crew that finished (or stopped and waits)
# reports its final turn-end with no captain-relevant status and no running
# pipeline, so the wake must surface instead of being absorbed.

test_turn_ended_not_working_surfaced() {
  local dir state fakebin out drain_out pid
  dir=$(make_case turn-ended-stopped); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; drain_out="$dir/drain.out"
  : > "$state/task.turn-ended"
  # No running pipeline, no busy pane: the crew has stopped (e.g. it finished via
  # an interactive menu and wrote no done: status). Default unknown verdict.
  export FM_FAKE_CREW_STATE='state: unknown · source: none · no current-state source available'
  watch_bg "$state" "$fakebin" "$out"
  pid=$!
  wait_for_exit "$pid" 100 || fail "watcher did not surface a turn-end whose crew is not provably working"
  grep -F "signal: $state/task.turn-ended" "$out" >/dev/null || fail "watcher did not print the surfaced turn-end signal"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>/dev/null || fail "drain after the surfaced turn-end failed"
  grep "$(printf '\tsignal\t')" "$drain_out" | grep -F "$state/task.turn-ended" >/dev/null || fail "surfaced turn-end was not queued"
  pass "a bare turn-end whose crew is not provably working is surfaced (the swallowed-finish fix)"
}

# --- bare turn-end, unverifiable harness: pane churn is the third proof --------
# A harness whose semantic busy state has no verified source (codex) can never
# report working, so the two proofs above are unreachable for it and EVERY worker
# turn boundary woke firstmate. Pane content that changed since the previous poll
# is harness-independent positive evidence the crew is still executing - the same
# liveness input the stale backbone already trusts - so a bare turn-end from a
# churning pane is benign. The pane going quiet afterwards is still caught by that
# backbone, which is why this widens the proof rather than bounding the wake rate.

# The pane-churn turn-end absorb is opt-in per home, so every case that exercises
# it (whether it expects an absorb or one of the guards that must still surface)
# points the watcher at a case-local config dir holding the flag. A case that must
# NOT have it points at an empty one, so no developer's real config can leak in.
churn_config() {  # <dir> [off]
  local cfg="$1/config"
  mkdir -p "$cfg"
  [ "${2:-}" = off ] || : > "$cfg/turnend-churn-absorb"
  printf '%s\n' "$cfg"
}

# Wait until the watcher records an absorbed wake matching <needle> in its triage
# log. 1 if the watcher exits first (i.e. it surfaced the wake instead), which is
# exactly the unfixed behavior this case exists to catch. Polls the log rather
# than a poll cycle so the assertion lands inside the FIRST poll, long before an
# unchanging fixture pane could reach the stale backbone.
wait_for_absorbed() {  # <state> <pid> <needle>
  local state=$1 pid=$2 needle=$3 i=0
  while [ "$i" -lt 100 ]; do
    grep -Fq "$needle" "$state/.watch-triage.log" 2>/dev/null && return 0
    kill -0 "$pid" 2>/dev/null || return 1
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

test_turn_ended_churning_pane_absorbed() {
  local dir state fakebin out capture_file window key pid
  dir=$(make_case turn-ended-churning); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"
  window="test:fm-codexer"
  : > "$state/codexer.turn-ended"
  printf 'window=%s\nkind=ship\nharness=codex\n' "$window" > "$state/codexer.meta"
  printf 'apply_patch: writing bin/thing.sh' > "$capture_file"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  # The previous poll recorded DIFFERENT pane content, so this poll's capture is
  # churn: the crew rendered output between the two polls.
  printf '%s' "$(hash_text 'reading the brief')" > "$state/.hash-$key"
  printf '0\n' > "$state/.count-$key"
  # The codex verdict verbatim: a verified dispatch adapter with no verified
  # semantic busy source, so crew_is_provably_working can never be satisfied.
  export FM_FAKE_CREW_STATE='state: unknown · source: pane · harness state unavailable (unknown codex-unverified)'
  # A slow poll leaves the first cycle's absorb assertion many ticks clear of the
  # stale backbone, which this static fixture pane would otherwise reach.
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_CONFIG_OVERRIDE="$(churn_config "$dir")" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_POLL=3 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_absorbed "$state" "$pid" "absorbed benign signal:" \
    || { reap "$pid"; fail "a bare turn-end from a churning pane was not absorbed: $(cat "$out")"; }
  [ ! -s "$out" ] || fail "an absorbed churning-pane turn-end printed a wake reason: $(cat "$out")"
  [ ! -s "$state/.wake-queue" ] || fail "an absorbed churning-pane turn-end enqueued a durable wake record"
  [ -s "$state/.churn-since-$key" ] \
    || { reap "$pid"; fail "an absorbed churning-pane turn-end did not open a bounded deferral window"; }
  reap "$pid"
  unset FM_FAKE_CREW_STATE
  pass "a bare turn-end from a pane that churned since the previous poll is absorbed"
}

# The three cases below drive the same churn-deferral bookkeeping through the
# paths where one of its arrays is empty. Stock Bash 3.2 treats expanding an
# empty array under set -u as an unbound variable and kills the watcher, so each
# case is only meaningful on that shell (the stock-bash lane) and reds by name
# there: the watcher exits with "unbound variable" instead of absorbing or
# surfacing the wake.

# A deferral window already open from an earlier poll leaves no key to create, so
# the create pass iterates an empty array. This is every poll after the first.
test_turn_ended_open_deferral_window_is_renewed_without_new_keys() {
  local dir state fakebin out err capture_file window key pid marker_before
  dir=$(make_case turn-ended-open-window); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; err="$dir/watch.err"; capture_file="$dir/pane.txt"
  window="test:fm-codexwindow"
  : > "$state/codexwindow.turn-ended"
  printf 'window=%s\nkind=ship\nharness=codex\n' "$window" > "$state/codexwindow.meta"
  printf 'apply_patch: writing bin/thing.sh' > "$capture_file"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  printf '%s' "$(hash_text 'reading the brief')" > "$state/.hash-$key"
  printf '0\n' > "$state/.count-$key"
  marker_before=$(date +%s)
  printf '%s' "$marker_before" > "$state/.churn-since-$key"
  export FM_FAKE_CREW_STATE='state: unknown · source: pane · harness state unavailable (unknown codex-unverified)'
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_CONFIG_OVERRIDE="$(churn_config "$dir")" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_POLL=3 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" 2> "$err" &
  pid=$!
  wait_for_absorbed "$state" "$pid" "absorbed benign signal:" \
    || { reap "$pid"; fail "a churning turn-end inside an already open deferral window was not absorbed: $(cat "$err")"; }
  ! grep -Fq 'unbound variable' "$err" || { reap "$pid"; fail "the open-window churn absorb hit an unbound array: $(cat "$err")"; }
  [ "$(cat "$state/.churn-since-$key")" = "$marker_before" ] \
    || { reap "$pid"; fail "an open deferral window was restarted instead of kept"; }
  reap "$pid"
  unset FM_FAKE_CREW_STATE
  pass "a churning turn-end inside an already open deferral window is absorbed without new keys"
}

# The rollback after a failed reset walks the keys this poll created. When the
# window was already open none were, and that walk is over an empty array.
test_turn_ended_churn_reset_failure_with_no_created_keys_surfaces() {
  local dir state fakebin out err capture_file window key pid
  dir=$(make_case turn-ended-reset-fails); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; err="$dir/watch.err"; capture_file="$dir/pane.txt"
  window="test:fm-codexreset"
  : > "$state/codexreset.turn-ended"
  printf 'window=%s\nkind=ship\nharness=codex\n' "$window" > "$state/codexreset.meta"
  printf 'apply_patch: writing bin/thing.sh' > "$capture_file"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  printf '%s' "$(hash_text 'reading the brief')" > "$state/.hash-$key"
  printf '0\n' > "$state/.count-$key"
  date +%s > "$state/.churn-since-$key"
  # rm -f cannot remove a non-empty directory, so the reset of the prior stale
  # classification fails after the window check has already passed.
  mkdir -p "$state/.stale-$key"
  : > "$state/.stale-$key/keep"
  export FM_FAKE_CREW_STATE='state: unknown · source: pane · harness state unavailable (unknown codex-unverified)'
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_CONFIG_OVERRIDE="$(churn_config "$dir")" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_POLL=3 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" 2> "$err" &
  pid=$!
  wait_for_exit "$pid" 100 || { reap "$pid"; fail "watcher died instead of surfacing a turn-end whose churn reset failed: $(cat "$err")"; }
  ! grep -Fq 'unbound variable' "$err" || fail "the failed churn reset hit an unbound array: $(cat "$err")"
  grep -F "signal: $state/codexreset.turn-ended" "$out" >/dev/null \
    || fail "watcher did not surface the turn-end whose churn reset failed: $(cat "$out")"
  unset FM_FAKE_CREW_STATE
  pass "a failed churn reset with no keys created this poll surfaces the wake instead of aborting"
}

# Another writer can open a deferral window between this poll noticing it was
# missing and creating it. The rollback then walks an empty created list. A fake
# cat plays the other writer at the one point between those two passes where a
# second task's window is read.
test_turn_ended_churn_lost_create_race_with_no_created_keys_surfaces() {
  local dir state fakebin out err capture_file first_window second_window first_key second_key pid real_cat
  dir=$(make_case turn-ended-create-race); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; err="$dir/watch.err"; capture_file="$dir/pane.txt"
  first_window="test:fm-aracea"; second_window="test:fm-araceb"
  : > "$state/aracea.turn-ended"
  : > "$state/araceb.turn-ended"
  printf 'window=%s\nkind=ship\nharness=codex\n' "$first_window" > "$state/aracea.meta"
  printf 'window=%s\nkind=ship\nharness=codex\n' "$second_window" > "$state/araceb.meta"
  printf 'both tasks rendered after the prior poll' > "$capture_file"
  first_key=$(printf '%s' "$first_window" | tr ':/.' '___')
  second_key=$(printf '%s' "$second_window" | tr ':/.' '___')
  printf '%s' "$(hash_text 'previous render')" > "$state/.hash-$first_key"
  printf '%s' "$(hash_text 'previous render')" > "$state/.hash-$second_key"
  printf '0\n' > "$state/.count-$first_key"
  printf '0\n' > "$state/.count-$second_key"
  date +%s > "$state/.churn-since-$second_key"
  real_cat=$(command -v cat)
  cat > "$fakebin/cat" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = "$state/.churn-since-$second_key" ] && [ ! -e "$state/.churn-since-$first_key" ]; then
  date +%s > "$state/.churn-since-$first_key"
fi
exec "$real_cat" "\$@"
SH
  chmod +x "$fakebin/cat"
  export FM_FAKE_CREW_STATE='state: unknown · source: pane · harness state unavailable (unknown codex-unverified)'
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOWS="$(printf 'fm-aracea\nfm-araceb')" \
    FM_FAKE_TMUX_CAPTURE="$capture_file" FM_CONFIG_OVERRIDE="$(churn_config "$dir")" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_POLL=3 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" 2> "$err" &
  pid=$!
  wait_for_exit "$pid" 100 || { reap "$pid"; fail "watcher died instead of surfacing a turn-end that lost the window-create race: $(cat "$err")"; }
  ! grep -Fq 'unbound variable' "$err" || fail "the lost create race hit an unbound array: $(cat "$err")"
  grep -F "signal: " "$out" >/dev/null \
    || fail "watcher did not surface the turn-end that lost the window-create race: $(cat "$out")"
  unset FM_FAKE_CREW_STATE
  pass "a lost deferral-window create race with no keys created this poll surfaces the wake instead of aborting"
}

test_turn_ended_churn_resets_prior_stale_classification() {
  local dir state fakebin out capture_file window key old_hash active_hash pid i
  dir=$(make_case turn-ended-churn-resets-stale); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"
  window="test:fm-codexreturned"
  : > "$state/codexreturned.turn-ended"
  printf 'window=%s\nkind=ship\nharness=codex\n' "$window" > "$state/codexreturned.meta"
  old_hash=$(hash_text 'idle prompt from an earlier turn')
  active_hash=$(hash_text 'rendering a new turn')
  printf 'rendering a new turn' > "$capture_file"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  printf '%s' "$old_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  printf '%s' "$old_hash" > "$state/.stale-$key"
  date +%s > "$state/.stale-since-$key"
  export FM_FAKE_CREW_STATE='state: unknown · source: pane · harness state unavailable (unknown codex-unverified)'
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_CONFIG_OVERRIDE="$(churn_config "$dir")" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=999 \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_absorbed "$state" "$pid" "absorbed benign signal:" \
    || { reap "$pid"; fail "a churning turn-end with prior stale state was not absorbed: $(cat "$out")"; }
  i=0
  while [ "$i" -lt 100 ] && [ "$(cat "$state/.hash-$key" 2>/dev/null || true)" != "$active_hash" ]; do
    kill -0 "$pid" 2>/dev/null || { reap "$pid"; fail "watcher exited before recording the active pane"; }
    sleep 0.1
    i=$((i + 1))
  done
  [ "$(cat "$state/.hash-$key" 2>/dev/null || true)" = "$active_hash" ] \
    || { reap "$pid"; fail "watcher did not record the active pane after absorbing its turn-end"; }

  # The worker stops on bytes that happened to be stale in an earlier turn.
  # This is a new quiet interval, so it must surface through ordinary staleness
  # instead of inheriting the earlier interval's wedge timer.
  printf 'idle prompt from an earlier turn' > "$capture_file"
  wait_for_exit "$pid" 100 \
    || { reap "$pid"; fail "a stopped pane matching an earlier stale render waited for the wedge timeout"; }
  grep -Fx "stale: $window" "$out" >/dev/null \
    || fail "the returned stale render did not surface through ordinary staleness"
  grep -F "possible wedge" "$out" >/dev/null \
    && fail "the returned stale render inherited the earlier quiet interval's wedge classification"
  unset FM_FAKE_CREW_STATE
  pass "pane churn starts a fresh stale-classification interval before a stopped render returns"
}

test_turn_ended_churn_resets_wedge_state_before_stale_poll() {
  local dir state fakebin out capture_file capture_count window key pid
  dir=$(make_case turn-ended-churn-resets-wedge); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"; capture_count="$dir/capture.count"
  window="test:fm-codexfreshinterval"
  : > "$state/codexfreshinterval.turn-ended"
  printf 'window=%s\nkind=ship\nharness=codex\n' "$window" > "$state/codexfreshinterval.meta"
  printf 'rendering a new turn' > "$capture_file"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  printf '%s' "$(hash_text 'idle output from the prior interval')" > "$state/.hash-$key"
  printf '2\n' > "$state/.wedge-escalations-$key"
  export FM_FAKE_CREW_STATE='state: unknown · source: pane · harness state unavailable (unknown codex-unverified)'
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_FAKE_TMUX_CAPTURE_COUNT_FILE="$capture_count" FM_FAKE_TMUX_CAPTURE_FAIL_AFTER=1 \
    FM_CONFIG_OVERRIDE="$(churn_config "$dir")" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_POLL=3 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_absorbed "$state" "$pid" "absorbed benign signal:" \
    || { reap "$pid"; fail "a churning turn-end was not absorbed before the stale-path capture failed: $(cat "$out")"; }
  [ ! -e "$state/.wedge-escalations-$key" ] \
    || { reap "$pid"; fail "churn retained the prior quiet interval's wedge-escalation count"; }
  [ ! -s "$state/.wake-queue" ] \
    || { reap "$pid"; fail "the absorbed churn fixture queued an unexpected wake"; }
  reap "$pid"
  unset FM_FAKE_CREW_STATE
  pass "pane churn resets prior wedge escalation state before the stale-path poll"
}

# The safety half: the same unverifiable harness, the same fixture, but the pane
# has NOT changed since the previous poll. There is no positive evidence, so the
# wake must still surface - a stopped worker is exactly what the turn-end marker
# earns its keep detecting, and widening the proof must not cost that.
test_turn_ended_still_pane_surfaced() {
  local dir state fakebin out drain_out capture_file window key pid
  dir=$(make_case turn-ended-still); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; drain_out="$dir/drain.out"; capture_file="$dir/pane.txt"
  window="test:fm-codexstopped"
  : > "$state/codexstopped.turn-ended"
  printf 'window=%s\nkind=ship\nharness=codex\n' "$window" > "$state/codexstopped.meta"
  printf 'apply_patch: writing bin/thing.sh' > "$capture_file"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  # The previous poll recorded THIS pane content: nothing rendered since.
  printf '%s' "$(hash_text 'apply_patch: writing bin/thing.sh')" > "$state/.hash-$key"
  printf '0\n' > "$state/.count-$key"
  export FM_FAKE_CREW_STATE='state: unknown · source: pane · harness state unavailable (unknown codex-unverified)'
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_CONFIG_OVERRIDE="$(churn_config "$dir")" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_POLL=3 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 100 || fail "watcher did not surface a bare turn-end from an unchanged pane"
  grep -F "signal: $state/codexstopped.turn-ended" "$out" >/dev/null \
    || fail "watcher did not print the surfaced still-pane turn-end signal"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>/dev/null || fail "drain after the still-pane turn-end failed"
  grep "$(printf '\tsignal\t')" "$drain_out" | grep -F "$state/codexstopped.turn-ended" >/dev/null \
    || fail "surfaced still-pane turn-end was not queued"
  unset FM_FAKE_CREW_STATE
  pass "a bare turn-end from a pane unchanged since the previous poll still surfaces"
}

test_turn_ended_malformed_prior_hash_surfaced() {
  local dir state fakebin out drain_out capture_file window key pid
  dir=$(make_case turn-ended-malformed-hash); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; drain_out="$dir/drain.out"; capture_file="$dir/pane.txt"
  window="test:fm-codexmalformed"
  : > "$state/codexmalformed.turn-ended"
  printf 'window=%s\nkind=ship\nharness=codex\n' "$window" > "$state/codexmalformed.meta"
  printf 'stopped after rendering this' > "$capture_file"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  printf 'x' > "$state/.hash-$key"
  printf '0\n' > "$state/.count-$key"
  export FM_FAKE_CREW_STATE='state: unknown · source: pane · harness state unavailable (unknown codex-unverified)'
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_CONFIG_OVERRIDE="$(churn_config "$dir")" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_POLL=3 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 100 || fail "watcher absorbed a turn-end backed by a malformed prior hash"
  grep -F "signal: $state/codexmalformed.turn-ended" "$out" >/dev/null \
    || fail "watcher did not print the surfaced malformed-hash turn-end"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>/dev/null \
    || fail "drain after the malformed-hash turn-end failed"
  grep "$(printf '\tsignal\t')" "$drain_out" | grep -F "$state/codexmalformed.turn-ended" >/dev/null \
    || fail "malformed-hash turn-end was not queued"
  unset FM_FAKE_CREW_STATE
  pass "a bare turn-end backed by a malformed prior hash surfaces"
}

test_turn_ended_trailing_newline_prior_hash_surfaced() {
  local dir state fakebin out drain_out capture_file window key pid
  dir=$(make_case turn-ended-newline-hash); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; drain_out="$dir/drain.out"; capture_file="$dir/pane.txt"
  window="test:fm-codexnewline"
  : > "$state/codexnewline.turn-ended"
  printf 'window=%s\nkind=ship\nharness=codex\n' "$window" > "$state/codexnewline.meta"
  printf 'rendered after the prior poll' > "$capture_file"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  printf '%s\n' "$(hash_text 'the previous render')" > "$state/.hash-$key"
  printf '0\n' > "$state/.count-$key"
  export FM_FAKE_CREW_STATE='state: unknown · source: pane · harness state unavailable (unknown codex-unverified)'
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_CONFIG_OVERRIDE="$(churn_config "$dir")" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_POLL=3 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 100 || fail "watcher absorbed a turn-end backed by a newline-terminated prior hash"
  grep -F "signal: $state/codexnewline.turn-ended" "$out" >/dev/null \
    || fail "watcher did not print the surfaced newline-hash turn-end"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>/dev/null \
    || fail "drain after the newline-hash turn-end failed"
  grep "$(printf '\tsignal\t')" "$drain_out" | grep -F "$state/codexnewline.turn-ended" >/dev/null \
    || fail "newline-hash turn-end was not queued"
  [ ! -e "$state/.churn-since-$key" ] \
    || fail "a newline-terminated prior hash opened a deferral window"
  unset FM_FAKE_CREW_STATE
  pass "a bare turn-end backed by a newline-terminated prior hash surfaces"
}

test_secondmate_turn_ended_churning_pane_surfaced() {
  local dir state fakebin out drain_out capture_file window key pid
  dir=$(make_case secondmate-turn-ended-churning); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; drain_out="$dir/drain.out"; capture_file="$dir/pane.txt"
  window="test:fm-mate-churning"
  : > "$state/mate.turn-ended"
  printf 'window=%s\nkind=secondmate\nharness=pi\n' "$window" > "$state/mate.meta"
  printf 'working on the next routed item' > "$capture_file"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  printf '%s' "$(hash_text 'waiting for work')" > "$state/.hash-$key"
  printf '0\n' > "$state/.count-$key"
  export FM_FAKE_CREW_STATE='state: unknown · source: pane · harness state unavailable'
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_CONFIG_OVERRIDE="$(churn_config "$dir")" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_POLL=3 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 100 || fail "watcher did not surface a churning secondmate turn-end"
  grep -F "signal: $state/mate.turn-ended" "$out" >/dev/null \
    || fail "watcher did not print the surfaced churning secondmate turn-end"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>/dev/null \
    || fail "drain after the churning secondmate turn-end failed"
  grep "$(printf '\tsignal\t')" "$drain_out" | grep -F "$state/mate.turn-ended" >/dev/null \
    || fail "churning secondmate turn-end was not queued"
  unset FM_FAKE_CREW_STATE
  pass "a churning secondmate turn-end surfaces without a stale resurface path"
}

test_turn_ended_colliding_window_key_surfaced() {
  local dir state fakebin out drain_out capture_file window colliding key pid
  dir=$(make_case turn-ended-colliding-key); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; drain_out="$dir/drain.out"; capture_file="$dir/pane.txt"
  window="test:fm-a.b"; colliding="test:fm-a_b"
  : > "$state/a.b.turn-ended"
  printf 'window=%s\nkind=ship\nharness=codex\n' "$window" > "$state/a.b.meta"
  printf 'window=%s\nkind=ship\nharness=codex\n' "$colliding" > "$state/a_b.meta"
  printf 'rendered after the prior poll' > "$capture_file"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  printf '%s' "$(hash_text 'the other window pane')" > "$state/.hash-$key"
  printf '0\n' > "$state/.count-$key"
  export FM_FAKE_CREW_STATE='state: unknown · source: pane · harness state unavailable (unknown codex-unverified)'
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_CONFIG_OVERRIDE="$(churn_config "$dir")" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_POLL=3 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 100 || fail "watcher did not surface a turn-end with an ambiguous pane marker"
  grep -F "signal: $state/a.b.turn-ended" "$out" >/dev/null \
    || fail "watcher did not print the surfaced ambiguous-marker turn-end"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>/dev/null \
    || fail "drain after the ambiguous-marker turn-end failed"
  grep "$(printf '\tsignal\t')" "$drain_out" | grep -F "$state/a.b.turn-ended" >/dev/null \
    || fail "ambiguous-marker turn-end was not queued"
  unset FM_FAKE_CREW_STATE
  pass "a turn-end whose marker key matches another recorded endpoint surfaces"
}

test_turn_ended_duplicate_endpoint_records_surfaced() {
  local dir state fakebin out drain_out capture_file window key pid
  dir=$(make_case turn-ended-duplicate-endpoint); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; drain_out="$dir/drain.out"; capture_file="$dir/pane.txt"
  window="test:fm-shared"
  : > "$state/first.turn-ended"
  printf 'window=%s\nkind=ship\nharness=codex\n' "$window" > "$state/first.meta"
  printf 'window=%s\nkind=ship\nharness=codex\n' "$window" > "$state/second.meta"
  printf 'rendered after the prior poll' > "$capture_file"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  printf '%s' "$(hash_text 'the previous render')" > "$state/.hash-$key"
  printf '0\n' > "$state/.count-$key"
  export FM_FAKE_CREW_STATE='state: unknown · source: pane · harness state unavailable (unknown codex-unverified)'
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_CONFIG_OVERRIDE="$(churn_config "$dir")" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_POLL=3 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 100 || fail "watcher absorbed a turn-end shared by two endpoint records"
  grep -F "signal: $state/first.turn-ended" "$out" >/dev/null \
    || fail "watcher did not print the surfaced duplicate-endpoint turn-end"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>/dev/null \
    || fail "drain after the duplicate-endpoint turn-end failed"
  grep "$(printf '\tsignal\t')" "$drain_out" | grep -F "$state/first.turn-ended" >/dev/null \
    || fail "duplicate-endpoint turn-end was not queued"
  [ ! -e "$state/.churn-since-$key" ] \
    || fail "duplicate endpoint records opened a deferral window"
  unset FM_FAKE_CREW_STATE
  pass "two metadata records sharing one endpoint make churn evidence ambiguous"
}

test_turn_ended_mixed_positive_evidence_batch_absorbed() {
  local dir state fakebin out capture_file first_window second_window first_key second_key pid
  dir=$(make_case turn-ended-mixed-evidence); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"
  first_window="test:fm-first"; second_window="test:fm-second"
  : > "$state/first.turn-ended"
  : > "$state/second.turn-ended"
  printf 'window=%s\nkind=ship\nharness=pi\n' "$first_window" > "$state/first.meta"
  printf 'window=%s\nkind=ship\nharness=codex\n' "$second_window" > "$state/second.meta"
  printf 'second task rendered after the prior poll' > "$capture_file"
  first_key=$(printf '%s' "$first_window" | tr ':/.' '___')
  second_key=$(printf '%s' "$second_window" | tr ':/.' '___')
  printf '%s' "$(hash_text 'first task static pane')" > "$state/.hash-$first_key"
  printf '%s' "$(hash_text 'second task previous render')" > "$state/.hash-$second_key"
  printf '0\n' > "$state/.count-$first_key"
  printf '0\n' > "$state/.count-$second_key"
  export FM_FAKE_CREW_STATE_first='state: working · source: run-step · running'
  export FM_FAKE_CREW_STATE_second='state: unknown · source: pane · harness state unavailable (unknown codex-unverified)'
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOWS="$(printf 'fm-first\nfm-second')" \
    FM_FAKE_TMUX_CAPTURE="$capture_file" FM_FAKE_TMUX_FORBIDDEN_TARGET="$first_window" \
    FM_CONFIG_OVERRIDE="$(churn_config "$dir")" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_POLL=3 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_absorbed "$state" "$pid" "absorbed benign signal:" \
    || { reap "$pid"; fail "a mixed authoritative-and-churn batch was not absorbed: $(cat "$out")"; }
  [ ! -s "$out" ] || fail "an absorbed mixed-evidence batch printed a wake reason: $(cat "$out")"
  [ ! -s "$state/.wake-queue" ] || fail "an absorbed mixed-evidence batch enqueued a durable wake record"
  [ ! -e "$state/.churn-since-$first_key" ] \
    || fail "an authoritatively working task opened a pane-churn deadline"
  [ -s "$state/.churn-since-$second_key" ] \
    || fail "the churn-proven task did not open its bounded deferral window"
  reap "$pid"
  unset FM_FAKE_CREW_STATE_first FM_FAKE_CREW_STATE_second
  pass "a batch may satisfy positive evidence independently per task"
}

test_turn_ended_mixed_positive_evidence_batch_default_off() {
  local dir state fakebin out drain_out capture_file first_window second_window first_key second_key pid
  dir=$(make_case turn-ended-mixed-evidence-off); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; drain_out="$dir/drain.out"; capture_file="$dir/pane.txt"
  first_window="test:fm-firstoff"; second_window="test:fm-secondoff"
  : > "$state/firstoff.turn-ended"
  : > "$state/secondoff.turn-ended"
  printf 'window=%s\nkind=ship\nharness=pi\n' "$first_window" > "$state/firstoff.meta"
  printf 'window=%s\nkind=ship\nharness=codex\n' "$second_window" > "$state/secondoff.meta"
  printf 'second task rendered after the prior poll' > "$capture_file"
  first_key=$(printf '%s' "$first_window" | tr ':/.' '___')
  second_key=$(printf '%s' "$second_window" | tr ':/.' '___')
  printf '%s' "$(hash_text 'first task static pane')" > "$state/.hash-$first_key"
  printf '%s' "$(hash_text 'second task previous render')" > "$state/.hash-$second_key"
  printf '0\n' > "$state/.count-$first_key"
  printf '0\n' > "$state/.count-$second_key"
  export FM_FAKE_CREW_STATE_firstoff='state: working · source: run-step · running'
  export FM_FAKE_CREW_STATE_secondoff='state: unknown · source: pane · harness state unavailable (unknown codex-unverified)'
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOWS="$(printf 'fm-firstoff\nfm-secondoff')" \
    FM_FAKE_TMUX_CAPTURE="$capture_file" FM_CONFIG_OVERRIDE="$(churn_config "$dir" off)" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_POLL=3 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 100 || fail "watcher absorbed a mixed-evidence batch without the opt-in flag"
  grep -F "$state/firstoff.turn-ended" "$out" >/dev/null \
    || fail "watcher did not print the first default-off turn-end"
  grep -F "$state/secondoff.turn-ended" "$out" >/dev/null \
    || fail "watcher did not print the second default-off turn-end"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>/dev/null \
    || fail "drain after the default-off mixed-evidence batch failed"
  grep "$(printf '\tsignal\t')" "$drain_out" | grep -F "$state/firstoff.turn-ended" >/dev/null \
    || fail "the first default-off turn-end was not queued"
  grep "$(printf '\tsignal\t')" "$drain_out" | grep -F "$state/secondoff.turn-ended" >/dev/null \
    || fail "the second default-off turn-end was not queued"
  [ ! -e "$state/.churn-since-$first_key" ] && [ ! -e "$state/.churn-since-$second_key" ] \
    || fail "the default-off mixed-evidence batch opened a deferral window"
  unset FM_FAKE_CREW_STATE_firstoff FM_FAKE_CREW_STATE_secondoff
  pass "per-task evidence composition stays off until the home opts in"
}

test_status_and_turn_end_batch_never_uses_churn_evidence() {
  local dir state fakebin out drain_out capture_file first_window second_window second_key pid
  dir=$(make_case status-and-turn-ended-churn); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; drain_out="$dir/drain.out"; capture_file="$dir/pane.txt"
  first_window="test:fm-firststatus"; second_window="test:fm-secondturn"
  printf 'working: authoritative task still running\n' > "$state/firststatus.status"
  : > "$state/secondturn.turn-ended"
  printf 'window=%s\nkind=ship\nharness=pi\n' "$first_window" > "$state/firststatus.meta"
  printf 'window=%s\nkind=ship\nharness=codex\n' "$second_window" > "$state/secondturn.meta"
  printf 'second task rendered after the prior poll' > "$capture_file"
  second_key=$(printf '%s' "$second_window" | tr ':/.' '___')
  printf '%s' "$(hash_text 'second task previous render')" > "$state/.hash-$second_key"
  printf '0\n' > "$state/.count-$second_key"
  export FM_FAKE_CREW_STATE_firststatus='state: working · source: run-step · running'
  export FM_FAKE_CREW_STATE_secondturn='state: unknown · source: pane · harness state unavailable (unknown codex-unverified)'
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOWS="$(printf 'fm-firststatus\nfm-secondturn')" \
    FM_FAKE_TMUX_CAPTURE="$capture_file" FM_CONFIG_OVERRIDE="$(churn_config "$dir")" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_POLL=3 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 100 || fail "watcher absorbed a status-and-turn-end batch on churn evidence"
  grep -F "$state/firststatus.status" "$out" >/dev/null \
    || fail "watcher did not print the status file from the surfaced mixed batch"
  grep -F "$state/secondturn.turn-ended" "$out" >/dev/null \
    || fail "watcher did not print the turn-end from the surfaced mixed batch"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>/dev/null \
    || fail "drain after the surfaced status-and-turn-end batch failed"
  grep "$(printf '\tsignal\t')" "$drain_out" | grep -F "$state/firststatus.status" >/dev/null \
    || fail "the status file from the surfaced mixed batch was not queued"
  grep "$(printf '\tsignal\t')" "$drain_out" | grep -F "$state/secondturn.turn-ended" >/dev/null \
    || fail "the turn-end from the surfaced mixed batch was not queued"
  [ ! -e "$state/.churn-since-$second_key" ] \
    || fail "a status-bearing batch opened a pane-churn deadline"
  unset FM_FAKE_CREW_STATE_firststatus FM_FAKE_CREW_STATE_secondturn
  pass "a status-bearing batch never falls through to pane-churn evidence"
}

# The opt-in half. Pane churn infers execution from rendered bytes rather than
# from a verdict the harness vouches for, so a home that has not asked for it must
# see exactly the pre-change triage: the same churning fixture that absorbs above
# surfaces here purely because the flag is absent.
test_turn_ended_churn_absorb_off_by_default() {
  local dir state fakebin out drain_out capture_file window key pid
  dir=$(make_case turn-ended-churn-default-off); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; drain_out="$dir/drain.out"; capture_file="$dir/pane.txt"
  window="test:fm-codexdefault"
  : > "$state/codexdefault.turn-ended"
  printf 'window=%s\nkind=ship\nharness=codex\n' "$window" > "$state/codexdefault.meta"
  printf 'apply_patch: writing bin/thing.sh' > "$capture_file"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  printf '%s' "$(hash_text 'reading the brief')" > "$state/.hash-$key"
  printf '0\n' > "$state/.count-$key"
  export FM_FAKE_CREW_STATE='state: unknown · source: pane · harness state unavailable (unknown codex-unverified)'
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_CONFIG_OVERRIDE="$(churn_config "$dir" off)" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_POLL=3 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 100 || fail "watcher absorbed a churning turn-end without the opt-in flag"
  grep -F "signal: $state/codexdefault.turn-ended" "$out" >/dev/null \
    || fail "watcher did not print the surfaced default-off churning turn-end"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>/dev/null \
    || fail "drain after the default-off churning turn-end failed"
  grep "$(printf '\tsignal\t')" "$drain_out" | grep -F "$state/codexdefault.turn-ended" >/dev/null \
    || fail "default-off churning turn-end was not queued"
  [ ! -e "$state/.churn-since-$key" ] \
    || fail "the default-off path opened a bounded deferral window"
  unset FM_FAKE_CREW_STATE
  pass "pane-churn turn-end absorb is off until a home opts in"
}

# The bound. Churn and pane staleness read the same pane, so a pane that renders
# continuously (a clock, a spinner, a harness that leaves a background renderer
# alive after its agent yields) never reaches the staleness backbone's two
# identical hashes either. Without a bound on the churn absorb a worker that had
# genuinely stopped behind such a renderer would have no path left to surface at
# all, so an exhausted deferral window must surface and restart.
test_turn_ended_churn_absorb_bounded() {
  local dir state fakebin out drain_out capture_file window key pid
  dir=$(make_case turn-ended-churn-bounded); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; drain_out="$dir/drain.out"; capture_file="$dir/pane.txt"
  window="test:fm-codexclock"
  : > "$state/codexclock.turn-ended"
  printf 'window=%s\nkind=ship\nharness=codex\n' "$window" > "$state/codexclock.meta"
  printf 'a background renderer that never stops' > "$capture_file"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  printf '%s' "$(hash_text 'the previous frame')" > "$state/.hash-$key"
  printf '0\n' > "$state/.count-$key"
  # This endpoint has already been riding churn evidence longer than the bound.
  printf '%s' "$(( $(date +%s) - 600 ))" > "$state/.churn-since-$key"
  export FM_FAKE_CREW_STATE='state: unknown · source: pane · harness state unavailable (unknown codex-unverified)'
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_CONFIG_OVERRIDE="$(churn_config "$dir")" FM_TURNEND_CHURN_ABSORB_SECS=60 \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_POLL=3 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 100 \
    || fail "a perpetually churning pane deferred its turn-end past the absorb bound"
  grep -F "signal: $state/codexclock.turn-ended" "$out" >/dev/null \
    || fail "watcher did not print the turn-end surfaced by the exhausted absorb bound"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>/dev/null \
    || fail "drain after the bounded churn turn-end failed"
  grep "$(printf '\tsignal\t')" "$drain_out" | grep -F "$state/codexclock.turn-ended" >/dev/null \
    || fail "the turn-end surfaced by the exhausted absorb bound was not queued"
  [ ! -e "$state/.churn-since-$key" ] \
    || fail "an exhausted deferral window was not restarted after surfacing"
  unset FM_FAKE_CREW_STATE
  pass "a perpetually churning pane surfaces once its bounded deferral window is spent"
}

test_turn_ended_churn_timer_write_failure_surfaced() {
  local dir state fakebin out drain_out capture_file window key pid
  dir=$(make_case turn-ended-churn-timer-write-failure); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; drain_out="$dir/drain.out"; capture_file="$dir/pane.txt"
  window="test:fm-codextimer"
  : > "$state/codextimer.turn-ended"
  printf 'window=%s\nkind=ship\nharness=codex\n' "$window" > "$state/codextimer.meta"
  printf 'rendered after the previous poll' > "$capture_file"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  printf '%s' "$(hash_text 'the previous render')" > "$state/.hash-$key"
  printf '0\n' > "$state/.count-$key"
  mkdir "$state/.churn-since-$key"
  export FM_FAKE_CREW_STATE='state: unknown · source: pane · harness state unavailable (unknown codex-unverified)'
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_CONFIG_OVERRIDE="$(churn_config "$dir")" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_POLL=3 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" 2>/dev/null &
  pid=$!
  wait_for_exit "$pid" 100 || fail "watcher absorbed a churning turn-end without recording its deadline"
  grep -F "signal: $state/codextimer.turn-ended" "$out" >/dev/null \
    || fail "watcher did not print the turn-end whose churn deadline could not be recorded"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>/dev/null \
    || fail "drain after the failed churn deadline write failed"
  grep "$(printf '\tsignal\t')" "$drain_out" | grep -F "$state/codextimer.turn-ended" >/dev/null \
    || fail "turn-end with an unrecordable churn deadline was not queued"
  unset FM_FAKE_CREW_STATE
  pass "an unrecordable pane-churn deadline surfaces the turn-end"
}

test_turn_ended_invalid_churn_bound_surfaced() {
  local dir state fakebin out drain_out capture_file window key pid
  dir=$(make_case turn-ended-invalid-churn-bound); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; drain_out="$dir/drain.out"; capture_file="$dir/pane.txt"
  window="test:fm-codexbound"
  : > "$state/codexbound.turn-ended"
  printf 'window=%s\nkind=ship\nharness=codex\n' "$window" > "$state/codexbound.meta"
  printf 'rendered after the previous poll' > "$capture_file"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  printf '%s' "$(hash_text 'the previous render')" > "$state/.hash-$key"
  printf '0\n' > "$state/.count-$key"
  export FM_FAKE_CREW_STATE='state: unknown · source: pane · harness state unavailable (unknown codex-unverified)'
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_CONFIG_OVERRIDE="$(churn_config "$dir")" FM_TURNEND_CHURN_ABSORB_SECS=bogus \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_POLL=3 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" 2>/dev/null &
  pid=$!
  wait_for_exit "$pid" 100 || fail "watcher did not surface a turn-end with an invalid churn bound"
  grep -F "signal: $state/codexbound.turn-ended" "$out" >/dev/null \
    || fail "watcher terminated before printing the invalid-bound turn-end"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>/dev/null \
    || fail "drain after the invalid churn bound failed"
  grep "$(printf '\tsignal\t')" "$drain_out" | grep -F "$state/codexbound.turn-ended" >/dev/null \
    || fail "turn-end with an invalid churn bound was not queued"
  [ ! -e "$state/.churn-since-$key" ] \
    || fail "an invalid churn bound opened a deferral window"
  unset FM_FAKE_CREW_STATE
  pass "an invalid pane-churn bound surfaces the turn-end"
}

test_turn_ended_oversized_churn_bound_surfaced() {
  local dir state fakebin out drain_out capture_file window key pid
  dir=$(make_case turn-ended-oversized-churn-bound); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; drain_out="$dir/drain.out"; capture_file="$dir/pane.txt"
  window="test:fm-codexoversized"
  : > "$state/codexoversized.turn-ended"
  printf 'window=%s\nkind=ship\nharness=codex\n' "$window" > "$state/codexoversized.meta"
  printf 'rendered after the previous poll' > "$capture_file"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  printf '%s' "$(hash_text 'the previous render')" > "$state/.hash-$key"
  printf '0\n' > "$state/.count-$key"
  export FM_FAKE_CREW_STATE='state: unknown · source: pane · harness state unavailable (unknown codex-unverified)'
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_CONFIG_OVERRIDE="$(churn_config "$dir")" FM_TURNEND_CHURN_ABSORB_SECS=999999999999999999999999999999999999 \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_POLL=3 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" 2>/dev/null &
  pid=$!
  wait_for_exit "$pid" 100 || fail "watcher did not surface a turn-end with an oversized churn bound"
  grep -F "signal: $state/codexoversized.turn-ended" "$out" >/dev/null \
    || fail "watcher terminated before printing the oversized-bound turn-end"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>/dev/null \
    || fail "drain after the oversized churn bound failed"
  grep "$(printf '\tsignal\t')" "$drain_out" | grep -F "$state/codexoversized.turn-ended" >/dev/null \
    || fail "turn-end with an oversized churn bound was not queued"
  [ ! -e "$state/.churn-since-$key" ] \
    || fail "an oversized churn bound opened a deferral window"
  unset FM_FAKE_CREW_STATE
  pass "an oversized pane-churn bound surfaces the turn-end"
}

# The watcher's stderr is kept in the case dir, and a failed wait names its cause
# (timed out, exited non-zero, or killed) with that stderr. Its one red, on
# 2026-09-22, said only "did not surface", with the stderr discarded, so nothing
# could tell a watcher that was too slow from one that crashed, and forced load
# never reproduced it.
test_turn_ended_invalid_churn_deadline_surfaced() {
  local variant value dir state fakebin out err drain_out capture_file window key marker pid
  for variant in empty leading-zero nonnumeric future overflow; do
    dir=$(make_case "turn-ended-invalid-churn-deadline-$variant")
    state="$dir/state"; fakebin="$dir/fakebin"
    out="$dir/watch.out"; err="$dir/watch.err"; drain_out="$dir/drain.out"; capture_file="$dir/pane.txt"
    window="test:fm-codexdeadline"
    : > "$state/codexdeadline.turn-ended"
    printf 'window=%s\nkind=ship\nharness=codex\n' "$window" > "$state/codexdeadline.meta"
    printf 'rendered after the previous poll' > "$capture_file"
    key=$(printf '%s' "$window" | tr ':/.' '___')
    marker="$state/.churn-since-$key"
    printf '%s' "$(hash_text 'the previous render')" > "$state/.hash-$key"
    printf '0\n' > "$state/.count-$key"
    case "$variant" in
      empty)        value='' ;;
      leading-zero) value=09 ;;
      nonnumeric)   value=bogus ;;
      future)       value=$(( $(date +%s) + 600 )) ;;
      overflow)     value=999999999999999999999999999999999999 ;;
    esac
    printf '%s' "$value" > "$marker"
    export FM_FAKE_CREW_STATE='state: unknown · source: pane · harness state unavailable (unknown codex-unverified)'
    PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
      FM_CONFIG_OVERRIDE="$(churn_config "$dir")" \
      FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_POLL=3 FM_SIGNAL_GRACE=1 \
      FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" 2> "$err" &
    pid=$!
    wait_for_exit "$pid" 100 \
      || fail "watcher did not surface a turn-end with a $variant churn deadline: $(watcher_exit_detail "$err")"
    grep -F "signal: $state/codexdeadline.turn-ended" "$out" >/dev/null \
      || fail "watcher terminated before printing the $variant-deadline turn-end: $(watcher_exit_detail "$err")"
    FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>/dev/null \
      || fail "drain after the $variant churn deadline failed"
    grep "$(printf '\tsignal\t')" "$drain_out" | grep -F "$state/codexdeadline.turn-ended" >/dev/null \
      || fail "turn-end with a $variant churn deadline was not queued"
    [ "$(cat "$marker")" = "$value" ] \
      || fail "the $variant churn deadline was rewritten"
  done
  unset FM_FAKE_CREW_STATE
  pass "invalid existing pane-churn deadlines surface without mutation"
}

test_turn_ended_surfaced_batch_opens_no_partial_deadline() {
  local dir state fakebin out drain_out capture_file first_window second_window first_key second_key pid
  dir=$(make_case turn-ended-no-partial-churn-deadline); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; drain_out="$dir/drain.out"; capture_file="$dir/pane.txt"
  first_window="test:fm-codexfirst"; second_window="test:fm-codexsecond"
  : > "$state/first.turn-ended"
  : > "$state/second.turn-ended"
  printf 'window=%s\nkind=ship\nharness=codex\n' "$first_window" > "$state/first.meta"
  printf 'window=%s\nkind=ship\nharness=codex\n' "$second_window" > "$state/second.meta"
  printf 'rendered after the previous poll' > "$capture_file"
  first_key=$(printf '%s' "$first_window" | tr ':/.' '___')
  second_key=$(printf '%s' "$second_window" | tr ':/.' '___')
  printf '%s' "$(hash_text 'first previous render')" > "$state/.hash-$first_key"
  printf '%s' "$(hash_text 'second previous render')" > "$state/.hash-$second_key"
  printf '0\n' > "$state/.count-$first_key"
  printf '0\n' > "$state/.count-$second_key"
  printf 'bogus' > "$state/.churn-since-$second_key"
  export FM_FAKE_CREW_STATE='state: unknown · source: pane · harness state unavailable (unknown codex-unverified)'
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOWS="$(printf 'fm-codexfirst\nfm-codexsecond')" \
    FM_FAKE_TMUX_CAPTURE="$capture_file" FM_CONFIG_OVERRIDE="$(churn_config "$dir")" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_POLL=3 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" 2>/dev/null &
  pid=$!
  wait_for_exit "$pid" 100 || fail "watcher absorbed a batch containing an invalid churn deadline"
  grep -F "$state/first.turn-ended" "$out" >/dev/null \
    || fail "watcher did not print the first turn-end from the surfaced batch"
  grep -F "$state/second.turn-ended" "$out" >/dev/null \
    || fail "watcher did not print the second turn-end from the surfaced batch"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>/dev/null \
    || fail "drain after the surfaced churn batch failed"
  grep "$(printf '\tsignal\t')" "$drain_out" | grep -F "$state/first.turn-ended" >/dev/null \
    || fail "the first turn-end from the surfaced batch was not queued"
  grep "$(printf '\tsignal\t')" "$drain_out" | grep -F "$state/second.turn-ended" >/dev/null \
    || fail "the second turn-end from the surfaced batch was not queued"
  [ ! -e "$state/.churn-since-$first_key" ] \
    || fail "a surfaced batch opened a partial churn deadline"
  [ "$(cat "$state/.churn-since-$second_key")" = bogus ] \
    || fail "the invalid churn deadline in a surfaced batch was rewritten"
  unset FM_FAKE_CREW_STATE
  pass "a surfaced batch opens no partial pane-churn deadline"
}

test_working_note_not_working_surfaced() {
  local dir state fakebin out drain_out status_file pid
  dir=$(make_case working-note-stopped); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; drain_out="$dir/drain.out"
  status_file="$state/task.status"
  printf 'working: compiling step 2\n' > "$status_file"
  # A non-no-mistakes crew (no run) whose pane went idle: fm-crew-state falls back
  # to the stale working: status-log line. That is NOT positive evidence, so the
  # wake must surface - these users must never be left hanging.
  export FM_FAKE_CREW_STATE='state: working · source: status-log · working: compiling step 2'
  watch_bg "$state" "$fakebin" "$out"
  pid=$!
  wait_for_exit "$pid" 100 || fail "watcher did not surface a working: note whose crew has no running pipeline and an idle pane"
  grep -F "signal: $status_file" "$out" >/dev/null || fail "watcher did not print the surfaced working: signal"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>/dev/null || fail "drain after the surfaced working: note failed"
  grep "$(printf '\tsignal\t')" "$drain_out" | grep -F "$status_file" >/dev/null || fail "surfaced working: note was not queued"
  [ -s "$state/.seen-task_status" ] || fail "surfaced working: note did not advance its .seen-* suppressor"
  pass "a no-verb working: note whose crew is idle with no running pipeline is surfaced"
}

test_secondmate_status_note_surfaced_despite_busy_agent() {
  local dir state fakebin out drain_out pid
  dir=$(make_case secondmate-note-surfaced); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; drain_out="$dir/drain.out"
  printf 'kind=secondmate\n' > "$state/mate.meta"
  printf 'working: routed reply landed in the parent stream\n' > "$state/mate.status"
  # Busy evidence that would absorb an ordinary crewmate's no-verb note must
  # not absorb a secondmate's: its status stream is the routed-reply channel.
  export FM_FAKE_CREW_STATE='state: working · source: run-step · running'
  FM_CONFIG_OVERRIDE="$(churn_config "$dir")" watch_bg "$state" "$fakebin" "$out"
  pid=$!
  wait_for_exit "$pid" 100 || fail "watcher absorbed a busy secondmate's routed status note"
  grep -F "signal: $state/mate.status" "$out" >/dev/null \
    || fail "watcher did not print the surfaced secondmate note"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>/dev/null || fail "drain after the surfaced note failed"
  grep "$(printf '\tsignal\t')" "$drain_out" | grep -F "$state/mate.status" >/dev/null \
    || fail "surfaced secondmate note was not queued"
  pass "a secondmate's status note surfaces even while its own agent is busy"
}

test_self_announced_close_does_not_rewake_but_next_note_does() {
  local dir state fakebin out status_file pid rc
  dir=$(make_case self-close-quiet); state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/watch.out"
  status_file="$state/task.status"
  printf 'needs-decision [key=k1]: pick one\n' > "$status_file"
  prime_status_seen "$state" "$status_file" || fail "could not prime the announced baseline"
  # The home's own bookkeeping close, written through the guarded
  # self-announced append this home's answerers use.
  rc=0
  FM_STATE_OVERRIDE="$state" bash -c '
    . "$1"
    fm_wake_status_append_self_announced "$2" "$3" "resolved [key=k1]: answered: closed by this home"
  ' _ "$ROOT/bin/fm-wake-lib.sh" "$state" "$status_file" || rc=$?
  [ "$rc" -eq 0 ] || fail "the bookkeeping close was not self-announced (rc=$rc)"
  export FM_FAKE_CREW_STATE='state: unknown · source: none · idle worker'
  watch_bg "$state" "$fakebin" "$out"
  pid=$!
  if ! wait_poll_cycle "$state" "$pid"; then
    reap "$pid"; fail "the home's own bookkeeping close re-woke its own watcher: $(cat "$out")"
  fi
  [ ! -s "$out" ] || { reap "$pid"; fail "self-announced close printed a wake reason: $(cat "$out")"; }
  [ ! -s "$state/.wake-queue" ] || { reap "$pid"; fail "self-announced close enqueued a durable wake"; }
  # A later, different note on the SAME task still wakes: dedup is keyed on the
  # exact announced bytes, never on task identity.
  printf 'needs-decision [key=k2]: a genuinely new decision\n' >> "$status_file"
  wait_for_exit "$pid" 100 || fail "a later different note after a self-announced close was swallowed"
  grep -F "signal: $status_file" "$out" >/dev/null \
    || fail "the later note did not surface as a signal"
  pass "a self-announced close never wakes its own home, and the next real note still does"
}

# --- actionable wakes are surfaced (queue + exit) ---------------------------

test_actionable_signal_surfaced() {
  local dir state fakebin out drain_out status_file pid
  dir=$(make_case actionable-signal); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; drain_out="$dir/drain.out"
  status_file="$state/task.status"
  printf 'working: setup\nneeds-decision: pick A or B\n' > "$status_file"
  watch_bg "$state" "$fakebin" "$out"
  pid=$!
  wait_for_exit "$pid" 100 || fail "watcher did not exit for an actionable needs-decision signal"
  grep -F "signal: $status_file" "$out" >/dev/null || fail "watcher did not print the actionable signal reason"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>/dev/null || fail "drain after the actionable signal failed"
  grep "$(printf '\tsignal\t')" "$drain_out" | grep -F "$status_file" >/dev/null || fail "actionable signal was not queued"
  [ -s "$state/.hb-surfaced-task" ] || fail "actionable signal did not record the surfaced marker"
  pass "captain-relevant signal is surfaced (queue + exit) and marked surfaced"
}

# A needs-decision status append surfaced through this actionable signal path
# must skip the Pi supervision branch and reach main directly
# (docs/pi-supervision-branch.md "Autonomy"). The row still
# queues as an ordinary signal-kind wake - fm-branch-dispatch.ts's
# scopeForUnreadWake tells it apart from a routine signal by this payload
# marker, not by kind.
test_needs_decision_signal_payload_marked_for_branch_exclusion() {
  local dir state fakebin out status_file pid
  dir=$(make_case needs-decision-payload); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"
  status_file="$state/task.status"
  printf 'working: setup\nneeds-decision: pick A or B\n' > "$status_file"
  watch_bg "$state" "$fakebin" "$out"
  pid=$!
  wait_for_exit "$pid" 100 || fail "watcher did not exit for an actionable needs-decision signal"
  grep -F "$(printf 'signal\ttask.status\tneeds-decision:')" "$state/.wake-queue" >/dev/null \
    || fail "a needs-decision signal row was not payload-marked for branch exclusion: $(cat "$state/.wake-queue")"
  pass "a needs-decision signal row's queued payload is marked needs-decision: for branch exclusion"
}

# A needs-decision whose key transition was rejected by the reserved-key
# vocabulary is reported as a "reconciliation-required: " wrapped event
# (fm-classify-lib.sh's status_span_first_actionable_record), but it is still a
# needs-decision signal that this path routes directly to main - the payload
# marker must not be fooled by that wrapper.
test_needs_decision_reconciliation_required_still_marked() {
  local dir state fakebin out status_file pid
  dir=$(make_case needs-decision-reconciliation); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"
  status_file="$state/task.status"
  printf 'needs-decision [key=pending-reply-x]: unrelated request\nworking: awaiting reconciliation\n' \
    > "$status_file"
  watch_bg "$state" "$fakebin" "$out"
  pid=$!
  wait_for_exit "$pid" 100 || fail "watcher did not exit for a rejected-reserved-key needs-decision"
  grep -F "$(printf 'signal\ttask.status\tneeds-decision:')" "$state/.wake-queue" >/dev/null \
    || fail "a reconciliation-required needs-decision row was not payload-marked for branch exclusion: $(cat "$state/.wake-queue")"
  pass "a reconciliation-required needs-decision row's queued payload is still marked needs-decision:"
}

# A captain-held declaration is itself actionable. Positive evidence that the
# crew is still working must not absorb the signal before its main-only marker
# can be delivered.
test_captain_held_signal_payload_marked_for_branch_exclusion() {
  local dir state fakebin out status_file pid
  dir=$(make_case captain-held-signal-payload); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"
  status_file="$state/task.status"
  printf 'captain-held [key=route]: awaiting the captain\n' > "$status_file"
  export FM_FAKE_CREW_STATE='state: working · source: run-step · still wrapping up'
  watch_bg "$state" "$fakebin" "$out"
  pid=$!
  wait_for_exit "$pid" 100 || fail "watcher absorbed a captain-held signal while the crew was still working"
  grep -F "signal: $status_file" "$out" >/dev/null \
    || fail "a captain-held signal changed its wake reason: $(cat "$out")"
  grep -F "$(printf 'signal\ttask.status\tneeds-decision:')" "$state/.wake-queue" >/dev/null \
    || fail "a captain-held signal was not payload-marked for branch exclusion: $(cat "$state/.wake-queue")"
  pass "a captain-held signal stays actionable while the crew is still working"
}

test_pending_reply_escalation_signal_payload_marked_for_branch_exclusion() {
  local dir state fakebin out status_file pid corr
  dir=$(make_case pending-reply-escalation-payload); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"
  status_file="$state/task.status"
  corr=0123456789abcdef
  printf 'blocked [key=pending-reply-%s]: pending-reply-missed: task=task pending-reply-id=%s request=finish report\n' \
    "$corr" "$corr" > "$status_file"
  watch_bg "$state" "$fakebin" "$out"
  pid=$!
  wait_for_exit "$pid" 100 || fail "watcher did not exit for a pending-reply escalation"
  grep -F "$(printf 'signal\ttask.status\tneeds-decision:')" "$state/.wake-queue" >/dev/null \
    || fail "a pending-reply escalation was not payload-marked for branch exclusion: $(cat "$state/.wake-queue")"
  pass "a pending-reply second-mate escalation is marked for main-only routing"
}

test_ordinary_blocked_signal_payload_remains_branch_eligible() {
  local dir state fakebin out status_file pid
  dir=$(make_case ordinary-blocked-payload); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"
  status_file="$state/task.status"
  printf 'blocked [key=dependency]: waiting for an upstream release\n' > "$status_file"
  watch_bg "$state" "$fakebin" "$out"
  pid=$!
  wait_for_exit "$pid" 100 || fail "watcher did not exit for an ordinary blocked event"
  grep -F "$(printf 'signal\ttask.status\tsignal:')" "$state/.wake-queue" >/dev/null \
    || fail "an ordinary blocked event lost branch-eligible routing: $(cat "$state/.wake-queue")"
  if grep -F "$(printf 'signal\ttask.status\tneeds-decision:')" "$state/.wake-queue" >/dev/null; then
    fail "an ordinary blocked event was marked as a second-mate escalation"
  fi
  pass "an ordinary blocked event remains branch-eligible"
}

# A routine (non-needs-decision) captain-relevant event must keep its ordinary
# payload: only a genuine needs-decision gets the exclusion marker.
test_routine_signal_payload_not_marked_needs_decision() {
  local dir state fakebin out status_file pid
  dir=$(make_case routine-signal-payload); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"
  status_file="$state/task.status"
  printf 'working: setup\ndone: migration complete ; needs-decision: documented in follow-up\n' > "$status_file"
  watch_bg "$state" "$fakebin" "$out"
  pid=$!
  wait_for_exit "$pid" 100 || fail "watcher did not exit for an actionable done signal"
  grep -F "$(printf 'signal\ttask.status\tneeds-decision:')" "$state/.wake-queue" >/dev/null \
    && fail "a routine done signal was incorrectly payload-marked needs-decision: $(cat "$state/.wake-queue")"
  grep -F "$(printf 'signal\ttask.status\tsignal:')" "$state/.wake-queue" >/dev/null \
    || fail "a routine signal lost its ordinary payload: $(cat "$state/.wake-queue")"
  pass "a routine event containing a needs-decision phrase keeps its ordinary payload, unmarked"
}

# The reported bug, end to end through a real watcher: a crew reports something
# the captain must act on and then keeps appending routine progress, which is
# ordinary while the watcher lingers its signal grace window to coalesce a status
# write with the same turn's turn-end. Classifying only the last line reads the
# batch as routine, and because the crew IS provably working the no-verb fallback
# absorbs it too - the .seen-* suppressor then advances and nothing ever re-reads
# the event, so the work stalls with the captain never told.
test_actionable_signal_survives_a_later_routine_append() {
  local dir state fakebin out drain_out status_file sig pid
  dir=$(make_case actionable-masked); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; drain_out="$dir/drain.out"
  status_file="$state/task.status"
  # Everything through "working: setup" was already classified, so this asserts
  # the newly appended span, not merely a whole-file re-read.
  printf 'working: setup\n' > "$status_file"
  sig=$(seen_sig "$status_file"); printf '%s' "$sig" > "$state/.seen-task_status"
  printf 'needs-decision: pick A or B\nworking: still tidying the branch\n' >> "$status_file"
  # Positive evidence the crew is still working, so the no-verb fallback cannot
  # rescue the wake: only reading the event itself can surface it.
  export FM_FAKE_CREW_STATE='state: working · source: run-step · validating (running)'
  watch_bg "$state" "$fakebin" "$out"
  pid=$!
  wait_for_exit "$pid" 100 \
    || { reap "$pid"; fail "watcher absorbed a needs-decision hidden behind a later working: line"; }
  grep -F "signal: $status_file" "$out" >/dev/null || fail "watcher did not print the actionable signal reason"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>/dev/null || fail "drain after the masked signal failed"
  grep "$(printf '\tsignal\t')" "$drain_out" | grep -F "$status_file" >/dev/null \
    || fail "the masked actionable signal was not queued"
  unset FM_FAKE_CREW_STATE
  pass "a captain event hidden behind a later routine append is still surfaced (queue + exit)"
}

# The captain-reported completion shape of the same masking, end to end.
test_release_completion_survives_a_later_routine_append() {
  local dir state fakebin out drain_out status_file sig pid
  dir=$(make_case release-masked); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; drain_out="$dir/drain.out"
  status_file="$state/task.status"
  printf 'working: publishing\n' > "$status_file"
  sig=$(seen_sig "$status_file"); printf '%s' "$sig" > "$state/.seen-task_status"
  printf 'done: release 1.4.0 published and installed\nworking: cleaning the build dir\n' >> "$status_file"
  export FM_FAKE_CREW_STATE='state: working · source: pane · harness busy'
  watch_bg "$state" "$fakebin" "$out"
  pid=$!
  wait_for_exit "$pid" 100 \
    || { reap "$pid"; fail "watcher absorbed a release/install completion hidden behind later cleanup chatter"; }
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>/dev/null || fail "drain after the masked completion failed"
  grep "$(printf '\tsignal\t')" "$drain_out" | grep -F "$status_file" >/dev/null \
    || fail "the masked completion was not queued"
  unset FM_FAKE_CREW_STATE
  pass "a finished release reported before routine cleanup chatter is still surfaced"
}

# The other direction: the fix must not turn ordinary progress into wakes.
test_routine_appends_after_a_classified_event_stay_absorbed() {
  local dir state fakebin out status_file sig pid
  dir=$(make_case actionable-classified); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"
  status_file="$state/task.status"
  # The decision is BEHIND the classified position, so only the new routine line
  # is in the span. A supervisor that re-read the whole log would wake again here.
  printf 'working: setup\nneeds-decision: pick A or B\n' > "$status_file"
  sig=$(seen_sig "$status_file"); printf '%s' "$sig" > "$state/.seen-task_status"
  printf 'working: still tidying the branch\n' >> "$status_file"
  export FM_FAKE_CREW_STATE='state: working · source: run-step · validating (running)'
  watch_bg "$state" "$fakebin" "$out"
  pid=$!
  if ! wait_poll_cycle "$state" "$pid"; then
    reap "$pid"; fail "watcher re-surfaced a decision it had already classified: $(cat "$out")"
  fi
  [ ! -s "$state/.wake-queue" ] || fail "a routine append after a classified decision enqueued a wake"
  reap "$pid"
  unset FM_FAKE_CREW_STATE
  pass "a routine append after an already-classified event is absorbed (no re-wake)"
}

test_unreadable_status_reports_once_per_file_state() {
  local dir state fakebin out status_file target marker sig pid
  dir=$(make_case unreadable-status); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; status_file="$state/task.status"; target="$dir/missing-status-target"
  ln -s "$target" "$status_file"
  marker="$state/.seen-task_status"

  watch_bg "$state" "$fakebin" "$out"
  pid=$!
  wait_for_exit "$pid" 100 || { reap "$pid"; fail "a dangling status symlink was not reported"; }
  grep -Fx "signal: $status_file" "$out" >/dev/null \
    || fail "a dangling status symlink did not use the immediate signal path: $(cat "$out")"
  sig=$(status_observed_signature "$status_file")
  status_presentation_marker_reported_matches "$marker" "$sig" \
    || fail "the unreadable status report did not advance its wake signature"
  [ "$(status_presentation_marker_offset "$marker" "$status_file")" = 0 ] \
    || fail "the unreadable status report advanced its classification position"
  ack_stopped_cycle "$state" || fail "could not acknowledge the first unreadable-status wake"
  touch "$state/.last-check" "$state/.last-heartbeat"

  watch_bg "$state" "$fakebin" "$out"
  pid=$!
  wait_poll_cycle "$state" "$pid" \
    || { reap "$pid"; fail "an unchanged unreadable status reported again after restart: $(cat "$out")"; }
  reap "$pid"

  printf 'blocked: changed target state with a longer path\n' > "$dir/status-target-two-longer"
  ln -snf "$dir/status-target-two-longer" "$status_file"
  target="$dir/status-target-two-longer"
  watch_bg "$state" "$fakebin" "$out"
  pid=$!
  wait_for_exit "$pid" 100 || { reap "$pid"; fail "a changed unreadable status did not report again"; }
  [ "$(status_presentation_marker_offset "$marker" "$status_file")" = 0 ] \
    || fail "a changed unreadable status advanced its classification position"
  ack_stopped_cycle "$state" || fail "could not acknowledge the changed unreadable-status wake"

  rm -f "$status_file"
  cp "$target" "$status_file"
  watch_bg "$state" "$fakebin" "$out"
  pid=$!
  wait_for_exit "$pid" 100 || { reap "$pid"; fail "a readable replacement did not surface preserved content"; }
  [ "$(status_presentation_marker_offset "$marker" "$status_file")" = "$(size_of "$status_file")" ] \
    || fail "readable recovery did not classify content written before the failure"
  pass "unreadable status reports are bounded without advancing classification"
}

test_permission_recovery_surfaces_preserved_status() {
  local dir state fakebin out status_file marker before_ident after_ident pid
  dir=$(make_case permission-recovery); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; status_file="$state/task.status"; marker="$state/.seen-task_status"
  printf 'blocked: release approval required\nworking: preserving context\n' > "$status_file"
  before_ident=$(_fm_open_decisions_file_ident "$status_file")
  chmod 000 "$status_file"
  if [ -r "$status_file" ]; then
    chmod 600 "$status_file"
    pass "permission recovery skipped because permissions cannot deny reads"
    return
  fi

  watch_bg "$state" "$fakebin" "$out"
  pid=$!
  wait_for_exit "$pid" 100 || { reap "$pid"; chmod 600 "$status_file"; fail "an unreadable regular status was not reported"; }
  [ "$(status_presentation_marker_offset "$marker" "$status_file")" = 0 ] \
    || { chmod 600 "$status_file"; fail "an unreadable regular status advanced its classification position"; }
  ack_stopped_cycle "$state" || { chmod 600 "$status_file"; fail "could not acknowledge the unreadable regular-status wake"; }
  touch "$state/.last-check" "$state/.last-heartbeat"

  watch_bg "$state" "$fakebin" "$out"
  pid=$!
  wait_poll_cycle "$state" "$pid" \
    || { reap "$pid"; chmod 600 "$status_file"; fail "an unchanged unreadable regular status reported again"; }

  chmod 600 "$status_file"
  after_ident=$(_fm_open_decisions_file_ident "$status_file")
  [ "$after_ident" = "$before_ident" ] || { reap "$pid"; fail "the permission-only recovery changed file identity"; }
  wait_for_exit "$pid" 100 || { reap "$pid"; fail "readability recovery did not surface preserved content"; }
  grep -Fx "signal: $status_file" "$out" >/dev/null \
    || fail "readability recovery did not use the actionable signal path: $(cat "$out")"
  [ "$(status_presentation_marker_offset "$marker" "$status_file")" = "$(size_of "$status_file")" ] \
    || fail "readability recovery did not classify from the unadvanced position"
  pass "permission recovery surfaces content from the unadvanced position"
}

test_terminal_stale_surfaced() {
  local dir state fakebin out drain_out capture_file window key pane_hash sig pid
  dir=$(make_case terminal-stale); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; drain_out="$dir/drain.out"; capture_file="$dir/pane.txt"
  window="test:fm-done"
  printf 'finished, awaiting review' > "$capture_file"
  printf 'window=%s\nkind=ship\n' "$window" > "$state/done.meta"
  printf 'done: PR https://example.test/pr/3\n' > "$state/done.status"
  sig=$(seen_sig "$state/done.status"); printf '%s' "$sig" > "$state/.seen-done_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "finished, awaiting review")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 100 || fail "watcher did not exit for a stale pane on a terminal status"
  grep -Fx "stale: $window" "$out" >/dev/null || fail "watcher did not print the terminal stale wake"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>/dev/null || fail "drain after the terminal stale failed"
  grep "$(printf '\tstale\t')" "$drain_out" | grep -F "$window" >/dev/null || fail "terminal stale was not queued"
  pass "a stale pane sitting on a terminal status is surfaced (queue + exit)"
}

# --- stale pane, STALE terminal status overridden by an active run: absorbed ---
# Regression for the 2026-07 herdr false-surface incidents: a crew's own status
# log gets no new entry once firstmate hands it to a no-mistakes validation
# (AGENTS.md's sparse status-reporting contract), so the log keeps showing its
# pre-validation "done:" line as the LAST line for the run's entire (possibly
# many-minutes) duration. stale_is_terminal alone has no run-step awareness and
# would treat that leftover as still-current every time the pane goes quiet,
# immediately surfacing a crew that is actively validating. crew_is_provably_working
# must get a chance to override a captain-relevant-but-stale status line, exactly
# as it already does for a plain non-terminal one.
test_stale_terminal_status_overridden_by_active_run() {
  local dir state fakebin out drain_out capture_file window key pane_hash sig pid
  dir=$(make_case terminal-stale-overridden); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; drain_out="$dir/drain.out"; capture_file="$dir/pane.txt"
  window="test:fm-validating"
  printf 'no-mistakes axi run: validating...' > "$capture_file"
  printf 'window=%s\nkind=ship\n' "$window" > "$state/validating.meta"
  # The crew reported done BEFORE firstmate triggered no-mistakes validation;
  # this line never gets superseded by a newer status-log entry while the
  # pipeline itself runs.
  printf 'done: implementation complete, ready to validate\n' > "$state/validating.status"
  sig=$(seen_sig "$state/validating.status"); printf '%s' "$sig" > "$state/.seen-validating_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "no-mistakes axi run: validating...")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  export FM_FAKE_CREW_STATE='state: working · source: run-step · validating (running)'

  # Phase A: a high escalation threshold means the first sighting is absorbed,
  # not surfaced, despite the captain-relevant "done:" status-log line.
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  if ! wait_poll_cycle "$state" "$pid"; then
    reap "$pid"; fail "watcher exited for a stale terminal-looking status the run-step overrides (should absorb): $(cat "$out")"
  fi
  [ ! -s "$out" ] || fail "the overridden stale terminal status printed a wake reason during absorb"
  [ ! -s "$state/.wake-queue" ] || fail "the overridden stale terminal status enqueued a wake during absorb"
  [ "$(cat "$state/.stale-$key" 2>/dev/null || true)" = "$pane_hash" ] || fail "stale suppressor not advanced on absorb"
  [ -s "$state/.stale-since-$key" ] || fail "stale-since escalation timer was not recorded on absorb"
  [ ! -e "$state/.hb-surfaced-validating" ] || fail "an absorbed wake must not mark the status line as surfaced"
  reap "$pid"
  ack_stopped_cycle "$state" || fail "could not acknowledge the intentional phase-A watcher stop"

  # Phase B: backdate the idle timer past the threshold; the run genuinely
  # wedges and the next poll escalates exactly like the non-terminal case.
  echo $(( $(date +%s) - 500 )) > "$state/.stale-since-$key"
  : > "$out"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=240 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 100 || fail "watcher did not escalate an overridden stale terminal status past the threshold"
  grep -F "stale: $window" "$out" >/dev/null || fail "escalation did not print a stale wake"
  grep -F "possible wedge" "$out" >/dev/null || fail "escalation did not flag a possible wedge"
  unset FM_FAKE_CREW_STATE
  pass "a stale terminal-looking status is overridden and absorbed while a run is actively working, then wedge-escalated"
}

# --- a worker whose turn ended while its own run was still in flight ---------
#
# THE PAIRING UNDER TEST. A held build slot proves WORK is progressing; it does
# not prove an AGENT is attached to that work. Conflating the two cost two lane
# runs in two days: on 2026-09-21 a test run finished and its result sat
# uncollected while six stale escalations against that lane were dismissed on
# the strength of the lock alone, and on 2026-09-22 the worker's bare background
# job died with the turn while firstmate, reading a declared wait that named
# only a harness-internal job id, told it to keep waiting.
#
# Every fixture below takes a REAL build-slot hold from a REAL worktree with a
# real live process, against a private lock root, because the whole question is
# whether a live hold can be attributed to one task's worktree.

# Take a real build-slot hold whose recorded cwd is <worktree>, and publish the
# holder pid in TASK_HOLD_PID. `exec` so the recorded holder pid IS that pid
# rather than some wrapper's, and both its streams go to a file: a hold that
# inherited a command substitution's pipe would keep that pipe open for its whole
# life, so returning the pid on stdout would deadlock the caller instead of
# starting a fixture. The caller releases it with release_task_hold.
# The hold leads its own process group, as a command a harness ran in a fresh
# group of its own does: that is one run with one hold, which ends when the hold
# ends. Taken as a plain child of this long-lived shell it would share the
# shell's group, and the watcher would rightly read that shell as a run still
# alive between two holds (start_per_script_runner models that case on purpose).
take_task_hold() {  # <lockroot> <worktree> <label> [outfile]
  local lockroot=$1 wt=$2 label=$3 outfile=${4:-/dev/null} i=0
  TASK_HOLD_PID=
  ( cd "$wt" && exec perl -e 'setpgrp(0, 0); exec @ARGV or die "exec: $!\n"' \
      env FM_BUILD_LOCK_DIR="$lockroot" FM_BUILD_LOCK_CI=0 \
      "$ROOT/bin/fm-build-lock.sh" --label "$label" sleep 120 ) \
      > "$outfile" 2>&1 &
  TASK_HOLD_PID=$!
  # Off the job table: the fixture is always ended with a signal, and a job the
  # shell still tracks prints a "Killed" line into the suite's own output.
  disown "$TASK_HOLD_PID" 2>/dev/null || true
  while [ "$i" -lt 300 ]; do
    [ -e "$lockroot/fm-build-lock.info" ] && return 0
    sleep 0.1
    i=$((i + 1))
  done
  kill -9 "$TASK_HOLD_PID" 2>/dev/null || true
  TASK_HOLD_PID=
  return 1
}

# Kill the hold and wait for the process to be gone, DELIBERATELY leaving its
# holder record behind: SIGKILL gives the holder no chance to clean up, which is
# exactly the state in which only a liveness test can tell a running hold from a
# finished one.
kill_task_hold() {  # <pid>
  local pid=$1 i=0
  [ -n "$pid" ] || return 0
  kill -9 "$pid" 2>/dev/null || true
  while [ "$i" -lt 300 ]; do
    kill -0 "$pid" 2>/dev/null || return 0
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

# Drop the slot artifacts a killed holder left, so the next phase starts from a
# genuinely free machine rather than from the previous phase's residue.
clear_task_hold_root() {  # <lockroot>
  local lockroot=$1
  rm -rf "$lockroot/fm-build-lock" "$lockroot/fm-build-lock.info" 2>/dev/null || true
}

release_task_hold() {  # <pid> <lockroot>
  kill_task_hold "$1"
  clear_task_hold_root "$2"
}

# Drive <task>'s SEMANTIC busy verdict through the real writer, the same path a
# harness hook uses, so no test hand-writes a busy record.
set_busy_state() {  # <state> <task> <busy|idle>
  local state=$1 task=$2 want=$3 gen
  gen=$(cat "$state/$task.busy-gen" 2>/dev/null || true)
  [ -n "$gen" ] || gen=$("$ROOT/bin/fm-busy-event.sh" arm "$state" "$task") || return 1
  "$ROOT/bin/fm-busy-event.sh" apply "$state" "$task" "$want" --gen "$gen" \
    --source claude-hook --event test >/dev/null
}

# crew_task_shell_running: the WORK half, on its own. It must attribute a live
# hold to the worktree that took it, and must report no evidence for everything
# else, so a negative never changes a caller's escalation schedule.
#
# Mutants that must turn this red:
#   - match the worktree as a bare prefix (drop the `/` boundary): the
#     sibling-worktree case is then claimed by the wrong task.
#   - credit a holder with no recorded cwd to whichever task asked: the
#     unattributable-hold case then reports evidence.
test_crew_task_shell_running_classifier() {
  local dir state lockroot wt sibling hold detail
  dir=$(make_case task-shell-probe); state="$dir/state"
  lockroot="$dir/lockroot"; wt="$dir/wt"; sibling="$dir/wt-old"
  mkdir -p "$lockroot" "$wt/src" "$sibling"
  printf 'window=t:s\nkind=ship\nharness=claude\nworktree=%s\n' "$wt" > "$state/shelltask.meta"
  printf 'window=t:m\nkind=secondmate\nharness=pi\nworktree=%s\n' "$wt" > "$state/mate.meta"
  printf 'window=t:n\nkind=ship\nharness=claude\n' > "$state/noworktree.meta"
  export FM_TASK_SHELL_LOCK_BIN="$ROOT/bin/fm-build-lock.sh"
  export FM_BUILD_LOCK_DIR="$lockroot" FM_BUILD_LOCK_CI=0

  ! crew_task_shell_running shelltask "$state" >/dev/null \
    || fail "a free machine reported a task-owned run in flight"

  # Phase 1: a live hold taken in the task's own worktree.
  take_task_hold "$lockroot" "$wt" 'mutex bash tests/lane.test.sh' \
    || fail "the probe fixture never took a build slot"
  hold=$TASK_HOLD_PID
  detail=$(crew_task_shell_running shelltask "$state") \
    || { release_task_hold "$hold" "$lockroot"
         fail "a live hold taken in the task's own worktree was not attributed to it"; }
  case "$detail" in
    *"pid $hold"*"running: mutex bash tests/lane.test.sh"*) : ;;
    *) release_task_hold "$hold" "$lockroot"
       fail "the holder detail named neither the pid nor the command a supervisor must report: '$detail'" ;;
  esac
  case "$detail" in
    *held*s,*) : ;;
    *) release_task_hold "$hold" "$lockroot"
       fail "the holder detail carried no elapsed time, which is what tells a long run from a hung one: '$detail'" ;;
  esac
  ! crew_task_shell_running mate "$state" >/dev/null \
    || { release_task_hold "$hold" "$lockroot"
         fail "a secondmate home's own workers' holds were reported as that record's run"; }
  ! crew_task_shell_running noworktree "$state" >/dev/null \
    || { release_task_hold "$hold" "$lockroot"; fail "a task with no recorded worktree reported evidence"; }
  ! crew_task_shell_running "" "$state" >/dev/null \
    || { release_task_hold "$hold" "$lockroot"; fail "an empty id reported evidence"; }
  # An explicitly empty snapshot is a real negative (a free machine the caller
  # already read), never a missing read to fall back from.
  ! crew_task_shell_running shelltask "$state" "" >/dev/null \
    || { release_task_hold "$hold" "$lockroot"
         fail "an explicitly empty holder snapshot was treated as a missing read"; }

  # Phase 2: the holder dies by SIGKILL and its RECORD SURVIVES. Only a liveness
  # test can separate this from a running hold, and getting it wrong is the
  # false positive that would hold a supervisor's ladder for work that no longer
  # exists - the same conflation, one layer down.
  kill_task_hold "$hold" || { clear_task_hold_root "$lockroot"; fail "the probe fixture outlived SIGKILL"; }
  [ -e "$lockroot/fm-build-lock.info" ] \
    || { clear_task_hold_root "$lockroot"
         fail "the killed holder's record vanished on its own, so this case cannot test the liveness filter at all"; }
  ! crew_task_shell_running shelltask "$state" >/dev/null \
    || { clear_task_hold_root "$lockroot"
         fail "a dead holder's surviving record was reported as a run still in flight"; }
  clear_task_hold_root "$lockroot"

  # Phase 3: the path-prefix hazard, in the direction that actually bites. The
  # hold is taken in a LONGER path whose first characters are the task's own
  # worktree path, so a bare prefix test claims another worktree's run.
  take_task_hold "$lockroot" "$sibling" 'mutex bash tests/other.test.sh' \
    || fail "the sibling-worktree fixture never took a build slot"
  hold=$TASK_HOLD_PID
  ! crew_task_shell_running shelltask "$state" >/dev/null \
    || { release_task_hold "$hold" "$lockroot"
         fail "a hold taken in $sibling was claimed by $wt, whose path is a bare prefix of it"; }
  release_task_hold "$hold" "$lockroot"

  unset FM_TASK_SHELL_LOCK_BIN FM_BUILD_LOCK_DIR FM_BUILD_LOCK_CI
  pass "crew_task_shell_running: a live hold is attributed to the worktree that took it; a mate's home, a missing worktree, a dead holder's surviving record and a prefix-sharing sibling worktree are all no evidence"
}

# status_wait_subject_class: can a supervisor CHECK what the wait names? The two
# lines that matter are taken verbatim from the two occurrences.
#
# Mutant that must turn this red: accept a bare `run <token>` as a run id, which
# is what made `background test run bhymd1si9` read as verifiable on the first
# attempt at this classifier - the exact line firstmate believed. `waiting on run
# bhymd1si9 of the lane` is in the unverifiable list to keep that mutant
# observable on its own: it carries the same opaque token with the word
# background absent, so the pattern is the only thing standing between it and a
# verifiable verdict.
test_status_wait_subject_class_classifier() {
  local l
  for l in \
    'paused: waiting on build slot, pid 45757' \
    'paused: queued on mutex for the test lane' \
    'paused: validation round run=nm-2026-09-22-a' \
    'paused: waiting on CI for https://github.com/o/r/pull/9' \
    'paused: waiting for /Users/x/wt/build/report.json to appear' \
    'paused: rate limit resets until 2026-09-22T14:00Z' ; do
    [ "$(status_wait_subject_class "$l")" = verifiable ] \
      || fail "a wait naming a checkable subject was classified unverifiable: '$l'"
  done
  for l in \
    'paused: waiting on background test run bhymd1si9' \
    'paused: waiting on background job bhymd1si9' \
    'paused: waiting on run bhymd1si9 of the lane' \
    'paused: waiting for the upstream release' \
    'paused: unverifiable - the only handle is a harness job id' ; do
    [ "$(status_wait_subject_class "$l")" = unverifiable ] \
      || fail "a wait whose subject a supervisor cannot resolve was classified verifiable: '$l'"
  done
  # A declared clearing time does NOT rescue an opaque subject: waiting out a
  # time on a job that no longer exists is the 2026-09-22 failure exactly.
  [ "$(status_wait_subject_class 'paused: background test run bhymd1si9, until 2026-09-22T14:00Z')" = unverifiable ] \
    || fail "an opaque background job was made verifiable by declaring a clearing time"
  # A resolvable handle survives the word background appearing in the prose. The
  # first cut of this classifier read `background` before the handles and so
  # called a wait on a queued build-lock hold unverifiable purely because the
  # sentence also used the word - noise on exactly the lines that are doing the
  # right thing.
  [ "$(status_wait_subject_class 'paused: waiting on the background job, pid 45757')" = verifiable ] \
    || fail "a wait handing over a pid was classified unverifiable because it also said background"
  [ "$(status_wait_subject_class 'paused: the suite runs as a background job under the build lock')" = verifiable ] \
    || fail "a wait naming a build-lock hold was classified unverifiable because its prose said background"
  # An explicit self-declaration wins over any incidental handle in the line.
  [ "$(status_wait_subject_class 'paused: unverifiable - job bhymd1si9 under /Users/x/wt')" = unverifiable ] \
    || fail "an explicit unverifiable declaration was overridden by an incidental path"
  ! status_wait_subject_class 'working: implementing' \
    || fail "a non-wait line was classified as a declared wait"
  ! status_wait_subject_class '' || fail "an empty line was classified as a declared wait"
  pass "status_wait_subject_class: a pid, a build slot, a run id, a URL, a path or a clearing time is checkable; a harness-internal job id is not, with or without a declared time"
}

# Build a fixture sitting exactly on the at-threshold wedge branch: a quiet pane
# whose hash is already classified and whose idle window opened 500s ago, so the
# first stale poll lands straight on the branch that would otherwise escalate.
# Echoes nothing; the caller owns the names.
arm_turn_ended_fixture() {  # <state> <task> <window> <worktree> <capture-file> <status-line>
  local state=$1 task=$2 window=$3 wt=$4 capture=$5 line=$6 key pane_hash sig back
  printf 'window=%s\nkind=ship\nharness=claude\nworktree=%s\n' "$window" "$wt" > "$state/$task.meta"
  printf '%s\n' "$line" > "$state/$task.status"
  sig=$(seen_sig "$state/$task.status"); printf '%s' "$sig" > "$state/.seen-${task}_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "$(cat "$capture")")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  printf '%s' "$pane_hash" > "$state/.stale-$key"
  back=$(( $(date +%s) - 500 ))
  echo "$back" > "$state/.stale-since-$key"
  set_mtime "$back" "$state/.stale-since-$key"
}

# THE CENTRAL CASE. A turn that ended while a task-owned run is still going must
# be recognised as THAT condition - held off the wedge ladder, not escalated
# toward a relaunch that would kill a live test - and the moment that run is gone
# the supervisor must say so at once, because from then on a finished result is
# sitting there with nobody attached to collect it.
#
# Mutants that must turn this red:
#   - remove the hold (let the at-threshold branch escalate as before): phase A
#     alarms "possible wedge" against a lane that is demonstrably running tests,
#     which is the 2026-09-21 false escalation, six times over.
#   - suppress instead of hold (absorb and return without ever surfacing): phase
#     B never fires, and the finished result goes uncollected exactly as it did.
#   - advance the escalation counter while holding: the ladder keeps climbing
#     under the hold and reaches relaunch anyway.
test_turn_ended_with_a_task_owned_run_holds_the_ladder_then_reports_it_finished() {
  local dir state fakebin out capture_file window key wt lockroot hold pid
  dir=$(make_case turn-ended-task-shell); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"
  window="test:fm-shellrun"; wt="$dir/wt"; lockroot="$dir/lockroot"
  mkdir -p "$wt/src" "$lockroot"
  printf 'done 3:49 PM - 1 shell still running' > "$capture_file"
  arm_turn_ended_fixture "$state" shellrun "$window" "$wt" "$capture_file" \
    'paused: waiting on the test lane, build slot held'
  key=$(printf '%s' "$window" | tr ':/.' '___')
  # The AGENT half, established independently of the lock: a positive idle
  # verdict, which is what "the turn ended" means.
  set_busy_state "$state" shellrun idle || fail "could not record the idle turn-end verdict"
  take_task_hold "$lockroot" "$wt" 'mutex bash tests/lane.test.sh' \
    || fail "the lane fixture never took a build slot"
  hold=$TASK_HOLD_PID

  # Phase A: run in flight, turn over. HELD, not escalated, and silent on the
  # first sight exactly as the write deferral is.
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_TASK_SHELL_LOCK_BIN="$ROOT/bin/fm-build-lock.sh" \
    FM_BUILD_LOCK_DIR="$lockroot" FM_BUILD_LOCK_CI=0 \
    FM_STALE_ESCALATE_SECS=240 FM_PAUSE_RESURFACE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  if ! wait_poll_cycle "$state" "$pid"; then
    release_task_hold "$hold" "$lockroot"
    fail "the watcher escalated a lane whose turn ended while its own test run was still holding a build slot: $(cat "$out")"
  fi
  grep -F "possible wedge" "$out" >/dev/null && {
    reap "$pid"; release_task_hold "$hold" "$lockroot"
    fail "a lane running its own tests was alarmed as a possible wedge: $(cat "$out")"; }
  [ ! -s "$state/.wake-queue" ] || { reap "$pid"; release_task_hold "$hold" "$lockroot"
    fail "the hold enqueued a wake on first sight: $(cat "$state/.wake-queue")"; }
  [ -e "$state/.taskshell-since-$key" ] || { reap "$pid"; release_task_hold "$hold" "$lockroot"
    fail "the turn-ended-with-a-run-in-flight chain was not recorded, so its end cannot be noticed"; }
  grep -F "pid $hold" "$state/.taskshell-holder-$key" >/dev/null || { reap "$pid"; release_task_hold "$hold" "$lockroot"
    fail "the held run's identity was not recorded: $(cat "$state/.taskshell-holder-$key" 2>/dev/null || true)"; }
  [ ! -e "$state/.wedge-escalations-$key" ] || { reap "$pid"; release_task_hold "$hold" "$lockroot"
    fail "holding the ladder still advanced the wedge escalation counter, so it climbs to a relaunch anyway"; }
  reap "$pid"
  ack_stopped_cycle "$state" || fail "could not acknowledge the intentional phase-A watcher stop"

  # Phase B: the run ends with the turn still over. The result is now sitting
  # there uncollected - surface AT ONCE, and say that is what happened.
  release_task_hold "$hold" "$lockroot"
  : > "$out"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_TASK_SHELL_LOCK_BIN="$ROOT/bin/fm-build-lock.sh" \
    FM_BUILD_LOCK_DIR="$lockroot" FM_BUILD_LOCK_CI=0 \
    FM_STALE_ESCALATE_SECS=240 FM_PAUSE_RESURFACE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 100 \
    || { reap "$pid"; fail "the watcher stayed quiet after the worker's own run finished with its turn already over, so the result went uncollected: $(cat "$out")"; }
  grep -F "stale: $window" "$out" >/dev/null || fail "no wake was printed when the held run finished"
  grep -F "has finished and its turn was already over" "$out" >/dev/null \
    || fail "the wake did not report the uncollected-result condition as itself: $(cat "$out")"
  grep -F "possible wedge" "$out" >/dev/null \
    && fail "the finished-run wake was reported as a possible wedge instead of as its own condition: $(cat "$out")"
  grep -Fi "relaunch" "$out" >/dev/null \
    || fail "the wake did not warn against the relaunch that would kill the lane: $(cat "$out")"
  [ ! -e "$state/.taskshell-holder-$key" ] \
    || fail "the finished-run chain outlived its own wake, so it would fire again"
  pass "a turn that ends with a task-owned run in flight is held off the wedge ladder, then reported as an uncollected result the moment that run is gone"
}

# The live holders of the private lock root, one `--holders` line each.
task_holders() {  # <lockroot>
  FM_BUILD_LOCK_DIR="$1" FM_BUILD_LOCK_CI=0 "$ROOT/bin/fm-build-lock.sh" --holders 2>/dev/null
}

# Wait until the lock root has a live holder (want=held) or none (want=free).
wait_task_holders() {  # <lockroot> <held|free>
  local lockroot=$1 want=$2 i=0 now
  while [ "$i" -lt 300 ]; do
    now=$(task_holders "$lockroot")
    case "$want" in
      held) [ -n "$now" ] && return 0 ;;
      free) [ -z "$now" ] && return 0 ;;
    esac
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

# One watcher over a task-shell fixture, with the task-shell triage reading the
# fixture's private lock root, through [lock-bin] when a case supplies one.
task_shell_watch_bg() {  # <state> <fakebin> <out> <window> <capture-file> <lockroot> [lock-bin]
  PATH="$2:$PATH" FM_FAKE_TMUX_WINDOW="$4" FM_FAKE_TMUX_CAPTURE="$5" \
    FM_STATE_OVERRIDE="$1" FM_CREW_STATE_BIN="$2/fm-crew-state.sh" \
    FM_TASK_SHELL_LOCK_BIN="${7:-$ROOT/bin/fm-build-lock.sh}" FM_TASK_SHELL_TIMEOUT=60 \
    FM_BUILD_LOCK_DIR="$6" FM_BUILD_LOCK_CI=0 \
    FM_STALE_ESCALATE_SECS=240 FM_PAUSE_RESURFACE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$3" &
}

# A per-script runner shaped like bin/fm-test-run.sh under a harness's
# per-command wrapper: it leads its own process group, takes one build-slot hold
# per script, holds NOTHING between two of them, and ends only after its last.
# It also leaves a stray background job in its group that outlives it, as a
# worker's `&` job does. Driven through files in <ctl>: `release<i>` ends hold
# <i>, labelled `bin/fm-test-run.sh tests/script-<i>.test.sh`, and `next<i>`
# lets the runner ask for hold <i> once the one before it has ended; the run
# ends with its last hold ([holds], 2 by default).
# Publishes the runner pid in TASK_RUNNER_PID; the stray's pid lands in
# <ctl>/stray. Every wait is bounded, so an escaped fixture stops itself.
start_per_script_runner() {  # <lockroot> <worktree> <ctl-dir> [holds]
  local lockroot=$1 wt=$2 ctl=$3 holds=${4:-2}
  TASK_RUNNER_PID=
  mkdir -p "$ctl"
  printf '%s\n' "$holds" > "$ctl/holds"
  cat > "$ctl/runner.sh" <<'RUNNER'
lock=$1 ctl=$2 holds=$3
deadline=$((SECONDS + ${FM_TEST_STUB_MAX_BLOCK_SECONDS:-120}))
await() {
  while [ ! -e "$ctl/$1" ]; do
    [ "$SECONDS" -lt "$deadline" ] || exit 1
    sleep 0.05
  done
}
hold() {  # <label> <release-file>
  "$lock" --label "$1" -- bash -c '
    end=$((SECONDS + $2))
    while [ ! -e "$1" ] && [ "$SECONDS" -lt "$end" ]; do sleep 0.05; done
  ' _ "$ctl/$2" "$((deadline - SECONDS))"
}
sleep "$((deadline - SECONDS))" &
printf '%s\n' "$!" > "$ctl/stray"
i=1
while [ "$i" -le "$holds" ]; do
  [ "$i" -eq 1 ] || await "next$i"
  hold "bin/fm-test-run.sh tests/script-$i.test.sh" "release$i"
  i=$((i + 1))
done
RUNNER
  ( cd "$wt" && exec perl -e 'setpgrp(0, 0); exec @ARGV or die "exec: $!\n"' \
      env FM_BUILD_LOCK_DIR="$lockroot" FM_BUILD_LOCK_CI=0 \
      bash "$ctl/runner.sh" "$ROOT/bin/fm-build-lock.sh" "$ctl" "$holds" ) > "$ctl/runner.out" 2>&1 &
  TASK_RUNNER_PID=$!
  disown "$TASK_RUNNER_PID" 2>/dev/null || true
}

stop_per_script_runner() {  # <ctl-dir> <lockroot>
  local ctl=$1 stray holds i=1
  holds=$(cat "$ctl/holds" 2>/dev/null || echo 2)
  while [ "$i" -le "$holds" ]; do
    : > "$ctl/next$i"; : > "$ctl/release$i"
    i=$((i + 1))
  done
  [ -z "$TASK_RUNNER_PID" ] || kill_task_hold "$TASK_RUNNER_PID" || true
  stray=$(cat "$ctl/stray" 2>/dev/null || true)
  [ -z "$stray" ] || kill_task_hold "$stray" || true
  clear_task_hold_root "$2"
}

# THE RUN, NOT ONE HOLD. bin/fm-test-run.sh takes the build lock once per
# script, so between two scripts - and while its next script queues for a slot -
# the run holds nothing at all. The detector read the first holder's end as the
# end of the run and told firstmate to steer a worker whose tests were still
# running, on two lanes within an hour of shipping. The run is the holder's
# ancestors in its own process group; it has finished only when they have.
#
# Mutants that must turn this red:
#   - key the verdict on the holder alone (current main): phase B reports the
#     live runner's run as finished.
#   - count any live member of the holder's process group as the run: phase D
#     never fires, because the stray job the run left behind outlives it.
#   - never record the run (drop task_shell_run_record): phase B fires again.
test_a_per_script_runner_between_holds_is_not_reported_finished() {
  local dir state fakebin out capture_file window key wt lockroot ctl pid stray hold2 i
  dir=$(make_case turn-ended-per-script-runner); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"
  window="test:fm-scriptrunner"; wt="$dir/wt"; lockroot="$dir/lockroot"; ctl="$dir/ctl"
  mkdir -p "$wt/src" "$lockroot"
  printf 'done 3:49 PM - 1 shell still running' > "$capture_file"
  arm_turn_ended_fixture "$state" scriptrunner "$window" "$wt" "$capture_file" \
    'paused: waiting on the stock-bash lane, build slot held'
  key=$(printf '%s' "$window" | tr ':/.' '___')
  set_busy_state "$state" scriptrunner idle || fail "could not record the idle turn-end verdict"
  start_per_script_runner "$lockroot" "$wt" "$ctl"
  wait_task_holders "$lockroot" held \
    || { stop_per_script_runner "$ctl" "$lockroot"; fail "the per-script runner never took its first hold"; }

  # Phase A: first script's hold live. Held.
  task_shell_watch_bg "$state" "$fakebin" "$out" "$window" "$capture_file" "$lockroot"
  pid=$!
  if ! wait_poll_cycle "$state" "$pid"; then
    stop_per_script_runner "$ctl" "$lockroot"
    fail "the watcher did not hold a lane whose per-script runner was holding a build slot: $(cat "$out")"
  fi
  reap "$pid"
  ack_stopped_cycle "$state" || { stop_per_script_runner "$ctl" "$lockroot"; fail "could not acknowledge the phase-A watcher stop"; }

  # Phase B: between two scripts. No holder at all, the runner alive.
  : > "$ctl/release1"
  wait_task_holders "$lockroot" free \
    || { stop_per_script_runner "$ctl" "$lockroot"; fail "the first script's hold never ended"; }
  kill -0 "$TASK_RUNNER_PID" 2>/dev/null \
    || { stop_per_script_runner "$ctl" "$lockroot"; fail "the runner ended with its first hold, so phase B tests nothing"; }
  : > "$out"
  task_shell_watch_bg "$state" "$fakebin" "$out" "$window" "$capture_file" "$lockroot"
  pid=$!
  if ! wait_poll_cycle "$state" "$pid"; then
    stop_per_script_runner "$ctl" "$lockroot"
    fail "a per-script runner between two holds was reported as a finished run: $(cat "$out")"
  fi
  grep -F "has finished" "$out" >/dev/null && { reap "$pid"; stop_per_script_runner "$ctl" "$lockroot"
    fail "a live run between two holds was reported as finished: $(cat "$out")"; }
  [ ! -s "$state/.wake-queue" ] || { reap "$pid"; stop_per_script_runner "$ctl" "$lockroot"
    fail "the run between two holds enqueued a wake: $(cat "$state/.wake-queue")"; }
  [ ! -e "$state/.wedge-escalations-$key" ] || { reap "$pid"; stop_per_script_runner "$ctl" "$lockroot"
    fail "the run between two holds advanced the wedge escalation counter"; }
  reap "$pid"
  ack_stopped_cycle "$state" || { stop_per_script_runner "$ctl" "$lockroot"; fail "could not acknowledge the phase-B watcher stop"; }

  # Phase C: the next script's hold. Held again, now naming that hold.
  : > "$ctl/next2"
  wait_task_holders "$lockroot" held \
    || { stop_per_script_runner "$ctl" "$lockroot"; fail "the runner never took its second hold"; }
  hold2=$(task_holders "$lockroot" | cut -f1)
  : > "$out"
  task_shell_watch_bg "$state" "$fakebin" "$out" "$window" "$capture_file" "$lockroot"
  pid=$!
  if ! wait_poll_cycle "$state" "$pid"; then
    stop_per_script_runner "$ctl" "$lockroot"
    fail "the watcher did not hold the runner's second hold: $(cat "$out")"
  fi
  grep -F "pid $hold2" "$state/.taskshell-holder-$key" >/dev/null || { reap "$pid"; stop_per_script_runner "$ctl" "$lockroot"
    fail "the second hold was not recorded: $(cat "$state/.taskshell-holder-$key" 2>/dev/null || true)"; }
  reap "$pid"
  ack_stopped_cycle "$state" || { stop_per_script_runner "$ctl" "$lockroot"; fail "could not acknowledge the phase-C watcher stop"; }

  # Phase D: the last script ends and the run with it, leaving only its stray
  # background job alive in the group. That is a finished run: surface AT ONCE.
  : > "$ctl/release2"
  wait_task_holders "$lockroot" free \
    || { stop_per_script_runner "$ctl" "$lockroot"; fail "the second script's hold never ended"; }
  i=0
  while is_live_non_zombie "$TASK_RUNNER_PID" && [ "$i" -lt 300 ]; do sleep 0.1; i=$((i + 1)); done
  ! is_live_non_zombie "$TASK_RUNNER_PID" \
    || { stop_per_script_runner "$ctl" "$lockroot"; fail "the runner outlived its last hold"; }
  stray=$(cat "$ctl/stray" 2>/dev/null || true)
  if [ -z "$stray" ] || ! kill -0 "$stray" 2>/dev/null; then
    stop_per_script_runner "$ctl" "$lockroot"
    fail "the stray job did not outlive the run, so phase D cannot tell the run from its group"
  fi
  : > "$out"
  task_shell_watch_bg "$state" "$fakebin" "$out" "$window" "$capture_file" "$lockroot"
  pid=$!
  wait_for_exit "$pid" 100 \
    || { reap "$pid"; stop_per_script_runner "$ctl" "$lockroot"
      fail "the watcher stayed quiet after the per-script run finished with its turn over: $(cat "$out")"; }
  grep -F "has finished and its turn was already over" "$out" >/dev/null \
    || { stop_per_script_runner "$ctl" "$lockroot"; fail "the finished per-script run was not reported as itself: $(cat "$out")"; }
  stop_per_script_runner "$ctl" "$lockroot"
  pass "a per-script runner between two build-slot holds is held as a live run, and reported finished only once the run itself has ended"
}

# THE AGENT'S OWN GROUP IS NOT A RUN. A harness that runs commands inside its own
# agent's process group puts the agent among the holder's in-group ancestors,
# alive for as long as the lane is: recorded as the run, it would keep a finished
# result held off the supervisor. In a pane that group is the terminal's
# foreground group, so no run is recorded there and the single-hold reading
# stands. Modelled with a real terminal: a tmux pane's shell takes the hold as a
# plain child and stays alive after it, as such an agent does.
#
# Mutants that must turn this red:
#   - drop the foreground-group check from task_shell_run_record: the live pane
#     shell is recorded as the run, and the finished hold is never reported.
test_a_hold_in_its_terminals_foreground_group_still_reports_finished() {
  local dir state fakebin out capture_file window key wt lockroot sock tmux_bin hold parent pid
  local hold_pgid hold_tpgid parent_pgid
  tmux_bin=$(command -v tmux 2>/dev/null) || { echo "skip: tmux not found (foreground-group run guard)"; return 0; }
  dir=$(make_case turn-ended-foreground-group); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"
  window="test:fm-fggroup"; wt="$dir/wt"; lockroot="$dir/lockroot"; sock="fm-triage-fg-$$"
  mkdir -p "$wt/src" "$lockroot"
  printf 'done 3:49 PM - 1 shell still running' > "$capture_file"
  arm_turn_ended_fixture "$state" fggroup "$window" "$wt" "$capture_file" \
    'paused: waiting on the test lane, build slot held'
  key=$(printf '%s' "$window" | tr ':/.' '___')
  set_busy_state "$state" fggroup idle || fail "could not record the idle turn-end verdict"
  SHELL=/bin/sh "$tmux_bin" -L "$sock" -f /dev/null new-session -d -s fg -x 80 -y 24 \
    "cd '$wt' && FM_BUILD_LOCK_DIR='$lockroot' FM_BUILD_LOCK_CI=0 '$ROOT/bin/fm-build-lock.sh' --label 'mutex bash tests/lane.test.sh' sleep 120; sleep 120" \
    || fail "real tmux could not start the foreground-group fixture"
  if ! wait_task_holders "$lockroot" held; then
    "$tmux_bin" -L "$sock" kill-server 2>/dev/null || true
    fail "the pane never took its hold"
  fi
  hold=$(task_holders "$lockroot" | cut -f1)
  parent=$(ps -o ppid= -p "$hold" 2>/dev/null | tr -d ' ')
  read -r hold_pgid hold_tpgid <<EOF
$(ps -o pgid= -o tpgid= -p "$hold" 2>/dev/null)
EOF
  parent_pgid=$(ps -o pgid= -p "$parent" 2>/dev/null | tr -d ' ')
  # The divergence this case exists for: the hold's parent shares its group, and
  # that group is the terminal's foreground one. Without it the case is vacuous.
  if [ -z "$hold_pgid" ] || [ "$hold_pgid" != "$hold_tpgid" ] || [ "$parent_pgid" != "$hold_pgid" ]; then
    kill_task_hold "$hold"; "$tmux_bin" -L "$sock" kill-server 2>/dev/null || true
    clear_task_hold_root "$lockroot"
    fail "the fixture is not a hold in its terminal's foreground group (pgid=$hold_pgid tpgid=$hold_tpgid parent-pgid=$parent_pgid)"
  fi

  task_shell_watch_bg "$state" "$fakebin" "$out" "$window" "$capture_file" "$lockroot"
  pid=$!
  if ! wait_poll_cycle "$state" "$pid"; then
    kill_task_hold "$hold"; "$tmux_bin" -L "$sock" kill-server 2>/dev/null || true
    clear_task_hold_root "$lockroot"
    fail "the watcher did not hold the pane's live build-slot hold: $(cat "$out")"
  fi
  reap "$pid"
  ack_stopped_cycle "$state" || fail "could not acknowledge the phase-A watcher stop"

  release_task_hold "$hold" "$lockroot"
  kill -0 "$parent" 2>/dev/null || { "$tmux_bin" -L "$sock" kill-server 2>/dev/null || true
    fail "the pane shell ended with its hold, so this case tests nothing"; }
  : > "$out"
  task_shell_watch_bg "$state" "$fakebin" "$out" "$window" "$capture_file" "$lockroot"
  pid=$!
  if ! wait_for_exit "$pid" 100; then
    reap "$pid"; "$tmux_bin" -L "$sock" kill-server 2>/dev/null || true
    fail "a finished hold whose parent is its terminal's foreground group was held as a live run: $(cat "$out")"
  fi
  "$tmux_bin" -L "$sock" kill-server 2>/dev/null || true
  grep -F "has finished and its turn was already over" "$out" >/dev/null \
    || fail "the finished hold was not reported as itself: $(cat "$out")"
  pass "a hold taken inside its terminal's foreground group is never mistaken for a run, so its end is still reported at once"
}

# A lock whose `--holders` answer can move a hold across the watcher's own read
# of the slots. <ctl>/before runs just before the slots are read and <ctl>/after
# just after, with that answer as its argument; each runs at most once, and the
# watcher is handed the answer exactly as it was read. Every other invocation is
# the real lock. A hook that fails appends its name to <ctl>/hook.failed, so a
# case can tell a broken fixture from a watcher verdict.
racing_task_lock() {  # <ctl-dir> -> the lock's path on stdout
  local ctl=$1
  {
    printf '#!/usr/bin/env bash\n'
    printf 'real=%q\n' "$ROOT/bin/fm-build-lock.sh"
    cat <<'LOCK'
ctl=${0%/*}
[ "${1:-}" = --holders ] || exec "$real" "$@"
hook() {  # <name> [answer]
  [ -e "$ctl/$1" ] || return 0
  mv -f "$ctl/$1" "$ctl/$1.ran" || return 1
  real=$real ctl=$ctl bash "$ctl/$1.ran" "${2-}" && return 0
  printf '%s\n' "$1" >> "$ctl/hook.failed"
  return 1
}
hook before || exit 1
answer=$("$real" --holders) || exit 1
hook after "$answer" || exit 1
[ -z "$answer" ] || printf '%s\n' "$answer"
LOCK
  } > "$ctl/racing-lock.sh"
  chmod +x "$ctl/racing-lock.sh"
  printf '%s\n' "$ctl/racing-lock.sh"
}

# Arm <ctl>/<before|after> for racing_task_lock with <body>. The body runs under
# `set -e` with the real lock in $real, the control directory in $ctl, the
# answer read in $1 (after only), and `until_holders <held|free> <text>`, which
# waits, bounded, until some live holder line contains <text> (held) or none
# does (free).
race_hook() {  # <ctl-dir> <before|after> <body>
  {
    cat <<'HOOK'
set -e
until_holders() {
  local i=0 found
  while [ "$i" -lt 300 ]; do
    found=0
    "$real" --holders 2>/dev/null | grep -F -- "$2" >/dev/null && found=1
    case "$1:$found" in held:1|free:0) return 0 ;; esac
    sleep 0.05
    i=$((i + 1))
  done
  return 1
}
HOOK
    printf '%s\n' "$3"
  } > "$1/$2"
}

# Another lane's run that needs the whole machine, from that lane's own
# worktree: it takes every slot once nothing else is live, and ends when
# <ctl>/<release-file> appears. Its pid lands in WHOLE_MACHINE_PID.
start_whole_machine_hold() {  # <lockroot> <worktree> <ctl-dir> <release-file>
  WHOLE_MACHINE_PID=
  # shellcheck disable=SC2016 # Expanded by the child shell.
  ( cd "$2" && exec env FM_BUILD_LOCK_DIR="$1" FM_BUILD_LOCK_CI=0 \
      "$ROOT/bin/fm-build-lock.sh" --exclusive --label 'other lane whole-machine run' -- bash -c '
        end=$((SECONDS + 120))
        while [ ! -e "$1" ] && [ "$SECONDS" -lt "$end" ]; do sleep 0.05; done
      ' _ "$3/$4" ) > "$3/whole-machine.out" 2>&1 &
  WHOLE_MACHINE_PID=$!
  disown "$WHOLE_MACHINE_PID" 2>/dev/null || true
}

lane_race_cleanup() {  # <ctl-dir> <lockroot>
  : > "$1/release-other"
  stop_per_script_runner "$1" "$2"
  [ -z "$WHOLE_MACHINE_PID" ] || kill_task_hold "$WHOLE_MACHINE_PID" || true
  rm -rf "$2"/fm-build-lock* 2>/dev/null || true
}

# 0 when a live holder in <lockroot> was taken in exactly <worktree>.
worktree_holds() {  # <lockroot> <worktree>
  task_holders "$1" | cut -f3 | grep -Fx -- "$2" >/dev/null
}

# THE HOLD THAT ENDS INSIDE THE POLL. The run behind a hold is found from the
# holder's ancestry in the process table, so the holder has to still be in that
# table when it is read. The watcher read the slots first and walked the
# holder's ancestry afterwards, from a live read: a per-script hold seen in its
# last moment was already gone by then, its run was recorded as that hold alone,
# and the next poll to land between two holds reported the live runner's run as
# finished and told firstmate to steer the worker. That is the 2026-09-23 alarm
# on a stock-bash lane, twice in half an hour: each hold it named had been held
# for about its script's whole runtime (4s, 16s) when the slots were read, the
# runner was alive both times, and its next script was queued behind other
# lanes' holds, whole-machine runs among them. Modelled with two slots, another
# lane's whole-machine run for the lane to queue behind, and a worker that
# declared its wait and ended its turn with shells still running.
#
# Mutants that must turn this red:
#   - walk the run from a live process read taken after the slot read (current
#     main): phase B records the lane's run as a hold that has ended, and the
#     queued runner is reported as finished.
#   - record a holder the process table does not have as a run of its own (drop
#     that guard from task_shell_run_record): phase C's hold, taken after the
#     table was read, replaces the runner's record, and the gap after it is
#     reported as finished.
#   - hold the finished report whenever the worker has declared a wait: phase D
#     never reports the run that has really ended.
test_a_lane_runner_whose_hold_ends_inside_the_poll_is_not_reported_finished() {
  local dir state fakebin out capture_file window key wt other lockroot ctl lock pid stray i
  dir=$(make_case turn-ended-lane-race); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"
  window="test:fm-lanerace"; wt="$dir/wt"; other="$dir/wt-other"; lockroot="$dir/lockroot"; ctl="$dir/ctl"
  mkdir -p "$wt/src" "$other" "$lockroot" "$ctl"
  FM_BUILD_LOCK_DIR="$lockroot" FM_BUILD_LOCK_CI=0 "$ROOT/bin/fm-build-lock.sh" --set-slots 2 >/dev/null 2>&1 \
    || fail "could not give the private lock root two build slots"
  printf 'done 3:49 PM - 3 shells still running' > "$capture_file"
  arm_turn_ended_fixture "$state" lanerace "$window" "$wt" "$capture_file" \
    'paused: stock-Bash lane running in background (bin/fm-stock-bash-lane.sh, task bf6vxplu4, unverifiable)'
  key=$(printf '%s' "$window" | tr ':/.' '___')
  set_busy_state "$state" lanerace idle || fail "could not record the idle turn-end verdict"
  lock=$(racing_task_lock "$ctl")
  start_per_script_runner "$lockroot" "$wt" "$ctl" 5
  wait_task_holders "$lockroot" held \
    || { lane_race_cleanup "$ctl" "$lockroot"; fail "the lane runner never took its first hold"; }

  # Phase A: the lane's first script holds a slot. Held.
  task_shell_watch_bg "$state" "$fakebin" "$out" "$window" "$capture_file" "$lockroot"
  pid=$!
  if ! wait_poll_cycle "$state" "$pid"; then
    lane_race_cleanup "$ctl" "$lockroot"
    fail "the watcher did not hold a lane whose runner was holding a build slot: $(cat "$out")"
  fi
  reap "$pid"
  ack_stopped_cycle "$state" || { lane_race_cleanup "$ctl" "$lockroot"; fail "could not acknowledge the phase-A watcher stop"; }

  # Phase B: the next script's hold is seen in its last moment - the watcher is
  # handed a slot answer naming it, and it has ended before that answer returns.
  # Its end lets another lane's whole-machine run take every slot, and the
  # lane's next script queues behind it. Nothing has finished.
  : > "$ctl/release1"
  wait_task_holders "$lockroot" free \
    || { lane_race_cleanup "$ctl" "$lockroot"; fail "the first script's hold never ended"; }
  : > "$ctl/next2"
  wait_task_holders "$lockroot" held \
    || { lane_race_cleanup "$ctl" "$lockroot"; fail "the runner never took its second hold"; }
  start_whole_machine_hold "$lockroot" "$other" "$ctl" release-other
  # shellcheck disable=SC2016 # Expanded by the hook's own shell.
  race_hook "$ctl" after 'printf "%s\n" "$1" > "$ctl/after.answer"
: > "$ctl/release2"
until_holders free tests/script-2.test.sh
until_holders held "other lane whole-machine run"
: > "$ctl/next3"'
  : > "$out"
  task_shell_watch_bg "$state" "$fakebin" "$out" "$window" "$capture_file" "$lockroot" "$lock"
  pid=$!
  # Two whole cycles: the one that read the vanishing hold, and at least one
  # after it that finds the lane between holds.
  if ! wait_poll_cycle "$state" "$pid" || ! wait_poll_cycle "$state" "$pid"; then
    [ ! -e "$ctl/hook.failed" ] || { lane_race_cleanup "$ctl" "$lockroot"; fail "the racing lock's $(cat "$ctl/hook.failed") hook failed, so phase B tests nothing"; }
    lane_race_cleanup "$ctl" "$lockroot"
    fail "a lane runner whose hold ended inside the watcher's read was reported as a finished run: $(cat "$out")"
  fi
  [ ! -e "$ctl/hook.failed" ] || { reap "$pid"; lane_race_cleanup "$ctl" "$lockroot"
    fail "the racing lock's $(cat "$ctl/hook.failed") hook failed, so phase B tests nothing"; }
  grep -F "tests/script-2.test.sh" "$ctl/after.answer" >/dev/null 2>&1 || { reap "$pid"; lane_race_cleanup "$ctl" "$lockroot"
    fail "the watcher was never handed the second script's hold, so phase B tests nothing"; }
  { ! worktree_holds "$lockroot" "$wt" && task_holders "$lockroot" | grep -F "other lane whole-machine run" >/dev/null; } \
    || { reap "$pid"; lane_race_cleanup "$ctl" "$lockroot"
      fail "the lane was not queued behind the other lane's whole-machine run, so phase B tests nothing: $(task_holders "$lockroot")"; }
  kill -0 "$TASK_RUNNER_PID" 2>/dev/null || { reap "$pid"; lane_race_cleanup "$ctl" "$lockroot"
    fail "the lane runner ended, so phase B tests nothing"; }
  grep -F "has finished" "$out" >/dev/null && { reap "$pid"; lane_race_cleanup "$ctl" "$lockroot"
    fail "a queued lane runner was reported as a finished run: $(cat "$out")"; }
  [ ! -s "$state/.wake-queue" ] || { reap "$pid"; lane_race_cleanup "$ctl" "$lockroot"
    fail "the lane between holds enqueued a wake: $(cat "$state/.wake-queue")"; }
  [ ! -e "$state/.wedge-escalations-$key" ] || { reap "$pid"; lane_race_cleanup "$ctl" "$lockroot"
    fail "the lane between holds advanced the wedge escalation counter"; }
  reap "$pid"
  ack_stopped_cycle "$state" || { lane_race_cleanup "$ctl" "$lockroot"; fail "could not acknowledge the phase-B watcher stop"; }

  # Phase C: the other lane finishes, the queued script gets its slot and runs,
  # and then the lane's next script asks for its slot and runs to its end
  # entirely inside the watcher's read - after the process table was taken,
  # before the slot answer returns - so the answer names a hold that table never
  # saw. Still nothing has finished.
  : > "$ctl/release-other"
  i=0
  while ! task_holders "$lockroot" | grep -F "tests/script-3.test.sh" >/dev/null && [ "$i" -lt 300 ]; do sleep 0.1; i=$((i + 1)); done
  [ "$i" -lt 300 ] || { lane_race_cleanup "$ctl" "$lockroot"; fail "the queued script never got its slot"; }
  : > "$ctl/release3"
  wait_task_holders "$lockroot" free \
    || { lane_race_cleanup "$ctl" "$lockroot"; fail "the queued script's hold never ended"; }
  # shellcheck disable=SC2016 # Expanded by the hook's own shell.
  race_hook "$ctl" before ': > "$ctl/next4"
until_holders held tests/script-4.test.sh'
  # shellcheck disable=SC2016 # Expanded by the hook's own shell.
  race_hook "$ctl" after 'printf "%s\n" "$1" > "$ctl/after.answer"
: > "$ctl/release4"
until_holders free tests/script-4.test.sh'
  : > "$out"
  task_shell_watch_bg "$state" "$fakebin" "$out" "$window" "$capture_file" "$lockroot" "$lock"
  pid=$!
  if ! wait_poll_cycle "$state" "$pid" || ! wait_poll_cycle "$state" "$pid"; then
    [ ! -e "$ctl/hook.failed" ] || { lane_race_cleanup "$ctl" "$lockroot"; fail "the racing lock's $(cat "$ctl/hook.failed") hook failed, so phase C tests nothing"; }
    lane_race_cleanup "$ctl" "$lockroot"
    fail "a lane runner whose whole hold fell inside the watcher's read was reported as a finished run: $(cat "$out")"
  fi
  [ ! -e "$ctl/hook.failed" ] || { reap "$pid"; lane_race_cleanup "$ctl" "$lockroot"
    fail "the racing lock's $(cat "$ctl/hook.failed") hook failed, so phase C tests nothing"; }
  grep -F "tests/script-4.test.sh" "$ctl/after.answer" >/dev/null 2>&1 || { reap "$pid"; lane_race_cleanup "$ctl" "$lockroot"
    fail "the watcher was never handed the fourth script's hold, so phase C tests nothing"; }
  kill -0 "$TASK_RUNNER_PID" 2>/dev/null || { reap "$pid"; lane_race_cleanup "$ctl" "$lockroot"
    fail "the lane runner ended, so phase C tests nothing"; }
  grep -F "has finished" "$out" >/dev/null && { reap "$pid"; lane_race_cleanup "$ctl" "$lockroot"
    fail "a lane runner between holds was reported as a finished run: $(cat "$out")"; }
  [ ! -s "$state/.wake-queue" ] || { reap "$pid"; lane_race_cleanup "$ctl" "$lockroot"
    fail "the lane between holds enqueued a wake: $(cat "$state/.wake-queue")"; }
  reap "$pid"
  ack_stopped_cycle "$state" || { lane_race_cleanup "$ctl" "$lockroot"; fail "could not acknowledge the phase-C watcher stop"; }

  # Phase D: the last script runs and the run ends with it, leaving only its
  # stray background job in the group. That run HAS finished, with the turn over
  # and a wait declared: surface AT ONCE.
  : > "$ctl/next5"
  i=0
  while ! task_holders "$lockroot" | grep -F "tests/script-5.test.sh" >/dev/null && [ "$i" -lt 300 ]; do sleep 0.1; i=$((i + 1)); done
  : > "$ctl/release5"
  i=0
  while is_live_non_zombie "$TASK_RUNNER_PID" && [ "$i" -lt 300 ]; do sleep 0.1; i=$((i + 1)); done
  ! is_live_non_zombie "$TASK_RUNNER_PID" \
    || { lane_race_cleanup "$ctl" "$lockroot"; fail "the lane runner outlived its last hold"; }
  stray=$(cat "$ctl/stray" 2>/dev/null || true)
  if [ -z "$stray" ] || ! kill -0 "$stray" 2>/dev/null; then
    lane_race_cleanup "$ctl" "$lockroot"
    fail "the stray job did not outlive the run, so phase D cannot tell the run from its group"
  fi
  : > "$out"
  task_shell_watch_bg "$state" "$fakebin" "$out" "$window" "$capture_file" "$lockroot"
  pid=$!
  wait_for_exit "$pid" 100 \
    || { reap "$pid"; lane_race_cleanup "$ctl" "$lockroot"
      fail "the watcher stayed quiet after the lane's run finished with its turn over: $(cat "$out")"; }
  grep -F "has finished and its turn was already over" "$out" >/dev/null \
    || { lane_race_cleanup "$ctl" "$lockroot"; fail "the finished lane run was not reported as itself: $(cat "$out")"; }
  lane_race_cleanup "$ctl" "$lockroot"
  pass "a lane runner whose hold ends inside the watcher's own read is still one live run between holds, and reported finished once it has ended"
}

# A RUN THAT ENDS INSIDE THE POLL STILL SURFACES. The other direction of the
# case above: a run that genuinely ends in the moment after the watcher's slot
# read is still reported the moment it is gone, rather than dropped as a hold
# whose run the watcher could not read. One hold, taken as a command a harness
# ran in a fresh group of its own, ends between the watcher's slot read and the
# return of that answer.
#
# Mutant that must turn this red:
#   - walk the run from a live process read taken after the slot read, and drop
#     a holder that read cannot find: the hold is never recorded, and its
#     finished run is never reported.
test_a_single_hold_that_ends_inside_the_poll_is_still_reported_finished() {
  local dir state fakebin out capture_file window wt lockroot ctl lock hold pid
  dir=$(make_case turn-ended-single-hold-race); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"
  window="test:fm-holdrace"; wt="$dir/wt"; lockroot="$dir/lockroot"; ctl="$dir/ctl"
  mkdir -p "$wt/src" "$lockroot" "$ctl"
  printf 'done 3:49 PM - 1 shell still running' > "$capture_file"
  arm_turn_ended_fixture "$state" holdrace "$window" "$wt" "$capture_file" \
    'paused: waiting on the test lane, build slot held'
  set_busy_state "$state" holdrace idle || fail "could not record the idle turn-end verdict"
  take_task_hold "$lockroot" "$wt" 'mutex bash tests/lane.test.sh' \
    || fail "the lane fixture never took a build slot"
  hold=$TASK_HOLD_PID
  lock=$(racing_task_lock "$ctl")
  # shellcheck disable=SC2016 # Expanded by the hook's own shell.
  race_hook "$ctl" after 'printf "%s\n" "$1" > "$ctl/after.answer"
kill -9 -- "-'"$hold"'"
until_holders free "mutex bash tests/lane.test.sh"'

  task_shell_watch_bg "$state" "$fakebin" "$out" "$window" "$capture_file" "$lockroot" "$lock"
  pid=$!
  if ! wait_for_exit "$pid" 100; then
    reap "$pid"; release_task_hold "$hold" "$lockroot"
    [ ! -e "$ctl/hook.failed" ] || fail "the racing lock's $(cat "$ctl/hook.failed") hook failed, so this case tests nothing"
    fail "a run that ended right after the watcher read its hold was never reported finished: $(cat "$out")"
  fi
  release_task_hold "$hold" "$lockroot"
  [ ! -e "$ctl/hook.failed" ] || fail "the racing lock's $(cat "$ctl/hook.failed") hook failed, so this case tests nothing"
  grep -F "mutex bash tests/lane.test.sh" "$ctl/after.answer" >/dev/null 2>&1 \
    || fail "the watcher was never handed the hold, so this case tests nothing"
  grep -F "has finished and its turn was already over" "$out" >/dev/null \
    || fail "the run that ended inside the watcher's read was not reported as a finished run: $(cat "$out")"
  pass "a run that ends right after the watcher reads its hold is still reported finished at once"
}

# THE FALSE-ALARM GUARD. The agent half must be a POSITIVE idle verdict. A lane
# whose semantic state is merely not-busy - unknown, because its source is
# missing, stale or unverified - has told us nothing about whether its worker is
# attached, and claiming a finished turn there is how this fix would rebuild the
# false alarm it exists to remove.
#
# Mutant that must turn this red: read the agent half as "not busy" instead of
# "== idle" (`[ "$busy_state" = busy ] && return 1`). The unknown lane below is
# then treated as a finished turn, its ladder is held for a run nobody has shown
# is unattended, and a genuinely wedged worker sitting next to a build hold
# never escalates again.
test_a_lane_that_is_not_positively_idle_is_left_to_the_ordinary_ladder() {
  local dir state fakebin out capture_file window key wt lockroot hold pid
  dir=$(make_case turn-ended-unknown-agent); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"
  window="test:fm-unknownagent"; wt="$dir/wt"; lockroot="$dir/lockroot"
  mkdir -p "$wt/src" "$lockroot"
  printf 'quiet pane' > "$capture_file"
  arm_turn_ended_fixture "$state" unknownagent "$window" "$wt" "$capture_file" \
    'working: implementing'
  key=$(printf '%s' "$window" | tr ':/.' '___')
  # No busy record at all: the verdict is unknown, NOT idle. The hold is real.
  take_task_hold "$lockroot" "$wt" 'mutex bash tests/lane.test.sh' \
    || fail "the unknown-agent fixture never took a build slot"
  hold=$TASK_HOLD_PID

  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_TASK_SHELL_LOCK_BIN="$ROOT/bin/fm-build-lock.sh" \
    FM_BUILD_LOCK_DIR="$lockroot" FM_BUILD_LOCK_CI=0 \
    FM_STALE_ESCALATE_SECS=240 FM_PAUSE_RESURFACE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 100 \
    || { reap "$pid"; release_task_hold "$hold" "$lockroot"
         fail "a lane whose agent state is unknown was held off the ladder on the strength of a build hold alone, which is the false alarm this fix must not rebuild: $(cat "$out")"; }
  release_task_hold "$hold" "$lockroot"
  [ ! -e "$state/.taskshell-since-$key" ] \
    || fail "an unknown agent state opened a turn-ended chain, so a wedged worker beside a build hold would never escalate again"
  grep -F "possible wedge" "$out" >/dev/null \
    || fail "the ordinary wedge ladder did not run for a lane that never showed a finished turn: $(cat "$out")"
  [ "$(cat "$state/.wedge-escalations-$key" 2>/dev/null || true)" = 1 ] \
    || fail "the ordinary escalation was not counted for a not-positively-idle lane"
  pass "a lane that is not POSITIVELY idle keeps the ordinary wedge ladder, however much work its worktree holds"
}

# THE OTHER HALF OF THE FALSE-ALARM GUARD, and the one the brief names: a lane
# merely waiting WITH ITS AGENT PRESENT must not be reported. A busy verdict IS
# an attached agent, so whatever its worktree is doing there is nothing to
# report - the worker is there to collect its own result.
#
# The busy case reaches the supervisor through its own door: a busy pane never
# enters the stale branch at all, and once it passes the completed-turn bound it
# goes through busy_turn_bound_check instead. This fixture is built to go through
# THAT door - busy, with a declared wait, past the bound - so the guard being
# pinned is that the new triage was not wired into the busy path and opens no
# chain there. The in-function `== idle` requirement is the second line of the
# same guard, and the not-positively-idle case above is what exercises it, on the
# `unknown` verdict that is actually reachable from the stale branch.
#
# Mutant that must turn this red: call task_shell_triage from
# busy_turn_bound_check (or from handle_paused_stale) as well. A lane whose agent
# is demonstrably present then records a held run, and the next quiet poll
# reports an uncollected result that nobody ever lost.
test_a_declared_wait_with_its_agent_present_is_not_reported() {
  local dir state fakebin out capture_file window key wt lockroot hold pid
  dir=$(make_case turn-not-ended-busy); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"
  window="test:fm-busyagent"; wt="$dir/wt"; lockroot="$dir/lockroot"
  mkdir -p "$wt/src" "$lockroot"
  printf 'esc to interrupt' > "$capture_file"
  arm_turn_ended_fixture "$state" busyagent "$window" "$wt" "$capture_file" \
    'paused: waiting on the test lane, build slot held'
  key=$(printf '%s' "$window" | tr ':/.' '___')
  set_busy_state "$state" busyagent busy || fail "could not record the busy verdict"
  # No turn-ended marker, so the busy-turn bound ages the spawn record: backdate
  # it and the pane is past the bound on the first poll.
  touch -t 200001010000 "$state/busyagent.meta"
  take_task_hold "$lockroot" "$wt" 'mutex bash tests/lane.test.sh' \
    || fail "the busy-agent fixture never took a build slot"
  hold=$TASK_HOLD_PID

  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_TASK_SHELL_LOCK_BIN="$ROOT/bin/fm-build-lock.sh" \
    FM_BUILD_LOCK_DIR="$lockroot" FM_BUILD_LOCK_CI=0 \
    FM_BUSY_TURN_MAX_SECS=1 FM_STALE_ESCALATE_SECS=240 FM_PAUSE_RESURFACE_SECS=999 \
    FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  if ! wait_poll_cycle "$state" "$pid"; then
    release_task_hold "$hold" "$lockroot"
    fail "the watcher woke for a lane that is merely waiting with its agent present: $(cat "$out")"
  fi
  reap "$pid"
  release_task_hold "$hold" "$lockroot"
  grep -F "still going" "$out" >/dev/null \
    && fail "a lane with its agent present was reported as a turn ended over a live run: $(cat "$out")"
  grep -F "was already over" "$out" >/dev/null \
    && fail "a lane with its agent present was reported as an uncollected result: $(cat "$out")"
  [ ! -e "$state/.taskshell-since-$key" ] \
    || fail "a lane with its agent present opened a turn-ended chain, so a later quiet poll would report an uncollected result that nobody lost"
  [ ! -e "$state/.taskshell-holder-$key" ] \
    || fail "a lane with its agent present recorded a held run to report the end of"
  pass "a declared wait whose agent is present is left alone through the busy door too, and records nothing that could later read as uncollected"
}

# THE COMMONEST SHAPE OF ALL, and the one a fix like this is most likely to break
# on its way past: a worker whose turn has ended, with no run of its own and no
# declared wait at all, is simply a quiet worker. That is the plain wedge case the
# alarm has always existed for, and it must still reach it - a positive idle
# verdict is the NORMAL state of every finished turn, so a new classification
# keyed on idle sits directly in front of every ordinary escalation in the fleet.
#
# Mutant that must turn this red: hold or surface on the idle verdict alone,
# without requiring a live run of the task's own (for example returning 0 from
# the fall-through instead of 1). Every finished turn in the fleet then stops
# escalating, and the alarm this whole card defends is gone.
test_an_idle_worker_with_no_run_and_no_wait_still_wedge_escalates() {
  local dir state fakebin out capture_file window key wt lockroot pid
  dir=$(make_case idle-plain-wedge); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"
  window="test:fm-plainwedge"; wt="$dir/wt"; lockroot="$dir/lockroot"
  mkdir -p "$wt/src" "$lockroot"
  printf 'quiet pane' > "$capture_file"
  arm_turn_ended_fixture "$state" plainwedge "$window" "$wt" "$capture_file" \
    'working: implementing'
  key=$(printf '%s' "$window" | tr ':/.' '___')
  set_busy_state "$state" plainwedge idle || fail "could not record the idle turn-end verdict"
  # A free machine: nothing of this task's own is running.

  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_TASK_SHELL_LOCK_BIN="$ROOT/bin/fm-build-lock.sh" \
    FM_BUILD_LOCK_DIR="$lockroot" FM_BUILD_LOCK_CI=0 \
    FM_STALE_ESCALATE_SECS=240 FM_PAUSE_RESURFACE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 100 \
    || { reap "$pid"; fail "a quiet finished-turn worker with nothing running and nothing declared never alarmed, so the new idle classification swallowed the ordinary wedge: $(cat "$out")"; }
  grep -F "stale: $window" "$out" >/dev/null || fail "the plain wedge printed no stale wake: $(cat "$out")"
  grep -F "possible wedge" "$out" >/dev/null \
    || fail "a plain quiet worker was not reported as a possible wedge: $(cat "$out")"
  [ "$(cat "$state/.wedge-escalations-$key" 2>/dev/null || true)" = 1 ] \
    || fail "the plain wedge escalation was not counted, so the ladder cannot climb"
  [ ! -e "$state/.taskshell-since-$key" ] \
    || fail "a worker with nothing running opened a turn-ended chain"
  pass "an idle worker with no run of its own and no declared wait still reaches the ordinary wedge ladder"
}

# GAP 3, end to end. Firstmate must be able to tell a wait it can CHECK from one
# it cannot, WITHOUT asking the worker. The unverifiable subject is the
# 2026-09-22 line verbatim; the checkable one names a build-lock holder, which is
# exactly what let six benign alarms be dismissed correctly the day before.
#
# The distinction rides on the declared wait's OWN bounded recheck reason rather
# than on a wake of its own. That is deliberate and was corrected here after the
# first cut surfaced unverifiable waits directly: doing so replaced the
# established bounded-pause contract for every ordinary pause whose subject
# happens to be unnamed, and broke the dead-agent declared hold, which has its
# own recheck and must keep it.
#
# Both fixtures use the same pane, harness, backdated declaration and cadence, so
# the ONLY difference between them is the text of the wait - which is the whole
# claim being made.
#
# Mutants that must turn this red:
#   - classify an opaque or unnamed subject as verifiable: phase A loses the
#     annotation and firstmate is free to instruct a wait on a dead job.
#   - annotate unconditionally: phase B gains it, and a wait naming a PR that
#     firstmate can fetch is smeared with a warning that does not apply.
#   - annotate a captain-held transfer: phase C gains it, telling the captain
#     that the wait on the captain names nothing checkable.
declared_wait_recheck_reason() {  # <case> <status-line> -> queued reason on stdout
  local name=$1 line=$2 dir state fakebin out capture window key back pid
  dir=$(make_case "$name"); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture="$dir/pane.txt"; window="test:fm-$name"
  printf 'idle bare shell\n' > "$capture"
  printf 'window=%s\nkind=ship\nharness=grok\nbackend=tmux\n' "$window" > "$state/held.meta"
  printf '%s\n' "$line" > "$state/held.status"
  record_deliberate_stop "$state" held
  back=$(( $(date +%s) - 500 ))
  set_mtime "$back" "$state/held.status"
  printf '%s' "$(seen_sig "$state/held.status")" > "$state/.seen-held_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  printf '%s' "$(hash_text "idle bare shell")" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture" \
    FM_FAKE_TMUX_CURRENT_COMMAND=zsh FM_FAKE_CREW_STATE='state: stopped · source: pane · bare shell' \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_TASK_SHELL_LOCK_BIN="$ROOT/bin/fm-build-lock.sh" FM_BUILD_LOCK_DIR="$dir/lockroot" \
    FM_BUILD_LOCK_CI=0 FM_PAUSE_RESURFACE_SECS=240 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" 2>&1 &
  pid=$!
  wait_poll_cycle "$state" "$pid" >/dev/null 2>&1 || true
  reap "$pid"
  cat "$state/.wake-queue" 2>/dev/null || true
}

test_an_unverifiable_declared_wait_is_distinguishable_from_a_checkable_one() {
  local opaque checkable held
  # Phase A: the 2026-09-22 subject. Nothing firstmate can run says whether
  # bhymd1si9 exists, and the job may already have died with the turn.
  opaque=$(declared_wait_recheck_reason opaquewait \
    'paused: waiting on background test run bhymd1si9')
  case "$opaque" in
    *'awaiting external'*) : ;;
    *) fail "the unverifiable wait lost the bounded declared-wait recheck it is entitled to: $opaque" ;;
  esac
  case "$opaque" in
    *'names nothing this supervisor can check'*) : ;;
    *) fail "a wait naming only a harness-internal job id was rechecked with no sign that firstmate cannot check it: $opaque" ;;
  esac
  case "$opaque" in
    *'rather than instructing it to keep waiting'*) : ;;
    *) fail "the recheck did not warn against the instruction that lost the 2026-09-22 round: $opaque" ;;
  esac

  # Phase B: same fixture, a subject firstmate can fetch. The reason must read
  # exactly as it always has, or the annotation is noise rather than a signal.
  checkable=$(declared_wait_recheck_reason checkablewait \
    'paused: waiting on CI for https://github.com/o/r/pull/9')
  case "$checkable" in
    *'awaiting external'*) : ;;
    *) fail "the checkable wait lost its bounded declared-wait recheck: $checkable" ;;
  esac
  case "$checkable" in
    *'names nothing this supervisor can check'*)
      fail "a wait naming a PR firstmate can fetch was annotated as uncheckable: $checkable" ;;
  esac

  # Phase C: a captain-held transfer. The subject of that wait is the captain,
  # so annotating it would point them at a job that was never the question.
  held=$(declared_wait_recheck_reason captainheldwait \
    'captain-held [key=route]: tracked by held-decision-route')
  case "$held" in
    *'names nothing this supervisor can check'*)
      fail "a captain-held transfer was annotated as naming nothing checkable: $held" ;;
  esac
  pass "an unverifiable declared wait keeps its bounded recheck and is annotated as uncheckable, while a checkable wait and a captain-held transfer read exactly as before"
}


test_reap_recovers_a_watcher_whose_first_sigterm_was_lost
test_reap_fails_loudly_on_a_watcher_that_ignores_sigterm
test_status_span_actionable_classifier
test_status_span_survives_a_later_routine_append
test_status_span_respects_decision_closure
test_malformed_seen_signature_reads_the_whole_log
test_stale_is_terminal_classifier
test_classifier_primitives
test_crew_is_provably_working_classifier
test_status_is_paused_classifier
test_crew_absorb_class_classifier
test_crew_worktree_written_since_classifier
test_empty_write_prune_widens_the_probe
test_empty_write_prune_from_the_environment_widens_the_probe
test_worktree_write_probe_is_wall_clock_bounded
test_signal_crew_provably_working_classifier
test_secondmate_status_signal_never_absorbed_classifier
test_provably_working_signal_absorbed
test_turn_ended_provably_working_absorbed
test_turn_ended_not_working_surfaced
test_turn_ended_churning_pane_absorbed
test_turn_ended_open_deferral_window_is_renewed_without_new_keys
test_turn_ended_churn_reset_failure_with_no_created_keys_surfaces
test_turn_ended_churn_lost_create_race_with_no_created_keys_surfaces
test_turn_ended_churn_resets_prior_stale_classification
test_turn_ended_churn_resets_wedge_state_before_stale_poll
test_turn_ended_still_pane_surfaced
test_turn_ended_malformed_prior_hash_surfaced
test_turn_ended_trailing_newline_prior_hash_surfaced
test_secondmate_turn_ended_churning_pane_surfaced
test_turn_ended_colliding_window_key_surfaced
test_turn_ended_duplicate_endpoint_records_surfaced
test_turn_ended_mixed_positive_evidence_batch_absorbed
test_turn_ended_mixed_positive_evidence_batch_default_off
test_status_and_turn_end_batch_never_uses_churn_evidence
test_turn_ended_churn_absorb_off_by_default
test_turn_ended_churn_absorb_bounded
test_turn_ended_churn_timer_write_failure_surfaced
test_turn_ended_invalid_churn_bound_surfaced
test_turn_ended_oversized_churn_bound_surfaced
test_turn_ended_invalid_churn_deadline_surfaced
test_turn_ended_surfaced_batch_opens_no_partial_deadline
test_working_note_not_working_surfaced
test_secondmate_status_note_surfaced_despite_busy_agent
test_self_announced_close_does_not_rewake_but_next_note_does
test_actionable_signal_surfaced
test_needs_decision_signal_payload_marked_for_branch_exclusion
test_needs_decision_reconciliation_required_still_marked
test_captain_held_signal_payload_marked_for_branch_exclusion
test_pending_reply_escalation_signal_payload_marked_for_branch_exclusion
test_ordinary_blocked_signal_payload_remains_branch_eligible
test_routine_signal_payload_not_marked_needs_decision
test_actionable_signal_survives_a_later_routine_append
test_release_completion_survives_a_later_routine_append
test_routine_appends_after_a_classified_event_stay_absorbed
test_unreadable_status_reports_once_per_file_state
test_permission_recovery_surfaces_preserved_status
test_terminal_stale_surfaced
test_stale_terminal_status_overridden_by_active_run
test_crew_task_shell_running_classifier
test_status_wait_subject_class_classifier
test_turn_ended_with_a_task_owned_run_holds_the_ladder_then_reports_it_finished
test_a_per_script_runner_between_holds_is_not_reported_finished
test_a_hold_in_its_terminals_foreground_group_still_reports_finished
test_a_lane_runner_whose_hold_ends_inside_the_poll_is_not_reported_finished
test_a_single_hold_that_ends_inside_the_poll_is_still_reported_finished
test_a_lane_that_is_not_positively_idle_is_left_to_the_ordinary_ladder
test_a_declared_wait_with_its_agent_present_is_not_reported
test_an_unverifiable_declared_wait_is_distinguishable_from_a_checkable_one
test_an_idle_worker_with_no_run_and_no_wait_still_wedge_escalates
