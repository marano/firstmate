#!/usr/bin/env bash
# fm-idle-fleet-lib.sh - the single owner of the idle-fleet condition: this home
# has free capacity AND dispatchable work waiting for it.
#
# Sourced, never executed. bin/fm-watch.sh owns the cadence, the sustain window,
# and the wake; this file owns only what the condition IS and how each of its
# three numbers is read.
#
# WHY THIS EXISTS. A fleet that finishes everything and then sits still with a
# full ready queue used to be indistinguishable from a fleet with nothing to do.
# Both queue-re-evaluation triggers can disappear at the same time: teardown
# re-evaluates the queue only after work LANDS, so nothing merging suppresses it
# entirely, and the periodic fleet review is a `heartbeat` wake, which the
# away-mode daemon force-self-handles by design (FM_INJECT_SKIP). With both gone
# nothing anywhere asks "should we start something?", and the fleet can stay
# silent for hours with capacity free and work queued.
#
# WHERE THE CHECK LIVES, AND WHY IT IS NOT IN THE DAEMON. The away-mode
# sub-supervisor already runs a cheap fleet scan on its own cadence, so its
# housekeeping looks like the obvious host. It is the wrong one: that daemon runs
# only in the away and quiet postures, and the attended fleet has exactly the
# same blind spot - teardown is still the only queue re-evaluation trigger, and
# an attended no-change heartbeat is absorbed by watcher triage before it reaches
# anyone. A detector that lives in the daemon leaves the attended case uncovered,
# and adding a second copy for the attended case is the duplication that drifts.
# bin/fm-watch.sh runs in BOTH postures - always-on triage when attended, and as
# the daemon's own child while away - so hosting the detector there covers both
# from one implementation.
#
# WHY IT SURVIVES AWAY MODE. The watcher publishes the condition as a `check`
# wake. The daemon classifies every `check` as escalate (classify_check), and its
# force-self-handling is a literal prefix match against FM_INJECT_SKIP, which
# defaults to `heartbeat` alone. So the alarm reaches the escalation digest while
# away and the durable wake queue while attended. This is deliberate: a stopped
# fleet is not routine progress, and it is the one thing away mode must not
# absorb. It escalates to firstmate rather than to the captain, because firstmate
# can clear it without waking anyone.
#
# DETECTION ONLY. Nothing here dispatches, transitions a backlog item, or changes
# a task. What to start, and whether to start anything at all, stays firstmate's
# judgement under AGENTS.md section 7.
#
# THE THREE NUMBERS.
#
#   in-progress - this home's own task records (state/<id>.meta of kind `task`)
#       whose latest status line does NOT declare a concluded outcome. A crew
#       that reported `done:` or `failed:` is an idle agent, not in-progress
#       work: the captain's cap counts work under way, and there is no limit on
#       idle agents. That distinction is the whole point. Counting the backlog's
#       own In-flight rows instead would have read 5-of-5 busy through the exact
#       incident this detector exists for, because nothing merged, so teardown
#       never ran and every row stayed In flight while every worker sat finished.
#       `blocked:`, `needs-decision:`, `paused:` and `captain-held:` DO count as
#       in progress: that work is open, not concluded, and it already has its own
#       escalation owners, so freeing its slot here would pile a second alarm on
#       a condition someone is already being told about.
#       Persistent secondmates never count; they are not work items.
#
#   capacity - config/fleet-capacity, one positive integer, the number of tasks
#       this home runs at once. ABSENT is not zero and not unlimited: AGENTS.md
#       section 7 sets no fleet-wide concurrency cap, so with nothing configured
#       the effective capacity is 1 and the detector fires only on a completely
#       idle fleet. That is the narrowest true reading of "capacity is free" that
#       needs no invented number. MALFORMED is refused rather than defaulted, so
#       a typo cannot quietly restore the silence this detector removes; the
#       caller reports it instead of evaluating.
#
#   ready - dispatchable-now queued work, from `tasks-axi ready` through
#       bin/fm-tasks-axi.sh, which owns addressing this home's backlog. That
#       command already excludes held, blocked, and in-flight items, so the count
#       is work firstmate could start right now. An unreadable count (no
#       tasks-axi, an incompatible one, a bounded read that timed out) is not an
#       alarm here: bin/fm-bootstrap.sh's MISSING diagnostic already owns telling
#       the operator that the backlog tool is unavailable, and a second owner for
#       that same fact would report it twice on two cadences.
#
# The condition holds when in-progress < capacity AND ready > 0.
set -u

_FM_IDLE_FLEET_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Helper owners, sourced only when the caller has not already loaded them. The
# watcher has all three by the time it sources this file, so this costs it nothing;
# a test or a standalone caller gets a self-contained library either way.
if ! command -v fm_meta_get >/dev/null 2>&1; then
  # shellcheck source=/dev/null
  . "$_FM_IDLE_FLEET_LIB_DIR/fm-backend.sh"
fi
if ! command -v last_status_line >/dev/null 2>&1; then
  # shellcheck source=/dev/null
  . "$_FM_IDLE_FLEET_LIB_DIR/fm-classify-lib.sh"
fi
if ! command -v fm_run_timed >/dev/null 2>&1; then
  # shellcheck source=/dev/null
  . "$_FM_IDLE_FLEET_LIB_DIR/fm-timeout-lib.sh"
fi

# Longest this library will wait for the backlog read. bin/fm-timeout-lib.sh owns
# the bound itself; a non-positive value is not a bound, so it is rejected here.
FM_IDLE_FLEET_READY_TIMEOUT_DEFAULT=20

# The effective capacity for <config-dir>.
# 0 and a value on stdout: usable (configured, or the unconfigured default of 1).
# 2 and nothing on stdout: config/fleet-capacity exists but is not one positive
# integer in a plain regular file, which the caller reports rather than defaults.
fm_idle_fleet_capacity() {  # <config-dir>
  local config=$1 file value
  file="$config/fleet-capacity"
  if [ ! -e "$file" ] && [ ! -L "$file" ]; then
    printf '1\n'
    return 0
  fi
  [ -f "$file" ] && [ ! -L "$file" ] || return 2
  # Exactly one line: a second line means the file says more than one thing, and
  # guessing which one it meant is how a capacity silently becomes wrong.
  [ "$(awk 'END { print NR + 0 }' "$file" 2>/dev/null)" = 1 ] || return 2
  value=$(head -n 1 "$file" 2>/dev/null) || return 2
  # Trim only the ENDS. Deleting every space instead would read "5 6" as 56,
  # which is not a typo the reader gets to correct on the operator's behalf.
  value=${value#"${value%%[![:space:]]*}"}
  value=${value%"${value##*[![:space:]]}"}
  case "$value" in
    ''|*[!0-9]*) return 2 ;;
  esac
  [ "$value" -gt 0 ] 2>/dev/null || return 2
  printf '%s\n' "$value"
}

# 0 when <config-dir> names a capacity of its own, 1 when the default applies.
# Only for reporting: fm_idle_fleet_capacity already returns the value to use.
fm_idle_fleet_capacity_configured() {  # <config-dir>
  [ -e "$1/fleet-capacity" ] || [ -L "$1/fleet-capacity" ]
}

# Count this home's own task records that have not reported a concluded outcome.
fm_idle_fleet_in_progress() {  # <state-dir>
  local state=$1 meta task kind count=0
  for meta in "$state"/*.meta; do
    [ -f "$meta" ] && [ ! -L "$meta" ] || continue
    task=${meta##*/}
    task=${task%.meta}
    case "$task" in ''|*[!A-Za-z0-9._-]*) continue ;; esac
    kind=$(fm_meta_get "$meta" kind)
    # An absent kind is the long-standing default for an ordinary crew task.
    case "$kind" in ''|task) ;; *) continue ;; esac
    case "$(status_line_verb "$(last_status_line "$state/$task.status")")" in
      done|failed) continue ;;
    esac
    count=$((count + 1))
  done
  printf '%s\n' "$count"
}

# The number of dispatchable-now queued items in <fm-home>'s backlog.
# 0 and a count on stdout, or 1 and nothing when the count cannot be read.
fm_idle_fleet_ready_count() {  # <fm-home>
  local home=$1 bound out status
  bound=${FM_IDLE_FLEET_READY_TIMEOUT:-$FM_IDLE_FLEET_READY_TIMEOUT_DEFAULT}
  case "$bound" in ''|*[!0-9]*|0) bound=$FM_IDLE_FLEET_READY_TIMEOUT_DEFAULT ;; esac
  out=$(FM_HOME="$home" fm_run_timed "$bound" \
    "$_FM_IDLE_FLEET_LIB_DIR/fm-tasks-axi.sh" ready 2>/dev/null)
  status=$?
  [ "$status" -eq 0 ] || return 1
  printf '%s\n' "$out" | awk '
    /^ready\[[0-9]+\]/ {
      line = $0
      sub(/^ready\[/, "", line)
      sub(/\].*$/, "", line)
      print line
      found = 1
      exit
    }
    /^ready:[[:space:]]*[0-9]+[[:space:]]/ {
      line = $0
      sub(/^ready:[[:space:]]*/, "", line)
      sub(/[^0-9].*$/, "", line)
      print line
      found = 1
      exit
    }
    END { if (!found) exit 1 }
  '
}

# Evaluate the whole condition for one home.
# Publishes FM_IDLE_FLEET_IN_PROGRESS, FM_IDLE_FLEET_CAPACITY, and
# FM_IDLE_FLEET_READY on every non-refusal return, so a caller can name the
# numbers in its wake payload without reading them again.
#   0 - the condition holds: capacity is free and ready work is queued.
#   1 - the condition does not hold. A fleet at its cap, or with nothing
#       dispatchable, is working or has nothing to do; neither is a fault.
#   2 - config/fleet-capacity is malformed. Nothing was evaluated.
#   3 - the ready count could not be read. Nothing was evaluated.
fm_idle_fleet_condition() {  # <state-dir> <config-dir> <fm-home>
  local state=$1 config=$2 home=$3 capacity in_progress ready
  FM_IDLE_FLEET_IN_PROGRESS=
  FM_IDLE_FLEET_CAPACITY=
  FM_IDLE_FLEET_READY=
  capacity=$(fm_idle_fleet_capacity "$config") || return 2
  in_progress=$(fm_idle_fleet_in_progress "$state")
  # shellcheck disable=SC2034 # Read by callers (bin/fm-watch.sh's idle_fleet_tick).
  FM_IDLE_FLEET_CAPACITY=$capacity
  # shellcheck disable=SC2034 # Read by callers (bin/fm-watch.sh's idle_fleet_tick).
  FM_IDLE_FLEET_IN_PROGRESS=$in_progress
  # Read the backlog only when a slot is actually free. A fleet at its cap is the
  # common case, and it must not pay for a subprocess on every scan.
  [ "$in_progress" -lt "$capacity" ] || return 1
  ready=$(fm_idle_fleet_ready_count "$home") || return 3
  # shellcheck disable=SC2034 # Read by callers (bin/fm-watch.sh's idle_fleet_tick).
  FM_IDLE_FLEET_READY=$ready
  [ "$ready" -gt 0 ] || return 1
  return 0
}
