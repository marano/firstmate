#!/usr/bin/env bash
# Machine-wide build/test semaphore: run the wrapped command while holding one
# of the N slots that every local build and test invocation on this machine
# shares. N is 1 unless this machine says otherwise, and at N=1 this is one
# mutex, which is what it has always been.
#
# Usage:
#   fm-build-lock.sh [--label <text>] [--exclusive] [--] <command> [args...]
#                                               acquire a slot, run, release
#   fm-build-lock.sh --status                   print every slot and its holder
#   fm-build-lock.sh --holders                  print live holders, TAB-separated,
#                                               for a parser (see --holders below)
#   fm-build-lock.sh --lock-path                print the resolved slot 1 path
#   fm-build-lock.sh --slots-path               print the resolved slot-count file
#   fm-build-lock.sh --set-slots <n>            set this machine's slot count
#   fm-build-lock.sh --install-mutex <dir>      link <dir>/mutex at this script
#   fm-build-lock.sh --help
#
# --label names the hold for everyone who reads it - waiters, --status and the
# task status line below - in place of the rendered command, for a caller whose
# own command line says nothing useful (bin/fm-test-run.sh's per-script holder).
#
# --exclusive names this run as needing the whole machine; see A RUN THAT NEEDS
# THE WHOLE MACHINE below.
#
# Prefix it in front of any local build or test command; no repository is
# modified to make this work:
#
#   fm-build-lock.sh ./gradlew :bluejam-core-ai:test
#   mutex pnpm run ci
#
# The wrapped command's stdout, stderr, stdin and exit status pass through
# unchanged. Everything this script says about the lock goes to stderr prefixed
# `fm-build-lock:`, so stdout stays exactly the wrapped command's output.
#
# ONE SET OF SLOTS FOR THE MACHINE, NOT ONE PER REPOSITORY. A per-repository
# lock would still let a JVM build and a browser suite run together, which is
# the pairing that exhausted a 16 GB / 10-core machine and produced false test
# failures on unmodified code. The slots therefore live outside every firstmate
# home so secondmate homes share them.
#
# HOW MANY RUN AT ONCE. Each slot is its own instance of the same lockdir mutex
# - slot 1 at <root>/fm-build-lock, slot k at <root>/fm-build-lock.slot<k> - so
# there is no counter file and no second locking scheme, and each holder's death
# stays independently detectable by the liveness test the lock already relies
# on. The number of holders is never stored; it is derived from which slots a
# live process owns. A slot a dead holder left behind is retired by the next
# acquisition, so an idle machine still has no build-lock residue.
#
# N is a MACHINE-level setting, read from one file per machine rather than per
# home: the slots deliberately live outside every home, most callers (pipeline
# agents, a captain's terminal, a worktree's own copy of this script) have no
# home to read, and two callers acting on two values of N against one set of
# slots would stop excluding each other. `--slots-path` prints the file and
# `--set-slots <n>` writes it. There is deliberately no environment variable for
# it: an environment value is per process, so it is multi-valued by
# construction, which is the one property this number must not have.
#
# Absent, empty, malformed, unreadable or non-positive means N=1 and warns once
# on stderr; it never stops the build, because N=1 is the most conservative
# legal value and a typo that killed every build, lint and pipeline step on the
# machine would be far worse than one that under-admits. A value above the
# online core count is clamped to it and says so: a large number is "no lock" by
# another name, and standing down already has an explicit switch. A waiter picks
# a raised count up within one poll. Lowering it never touches a running holder:
# holders above the new count finish normally, and no claim is admitted while as
# many live holders as the new count allows remain on ANY slot on disk.
#
# A RUN THAT NEEDS THE WHOLE MACHINE TAKES EVERY SLOT. A slot is not a share of
# the machine - build tools size their worker pools from the whole machine, and
# memory is not divisible by a lock at all - so N caps how many heavy commands
# run and never how much they use. A run named as needing the whole machine
# therefore holds all N slots and starts only once nothing else is live, so it
# never runs beside anything. Name one with --exclusive, or, so that no caller
# has to know, with one shell glob per line in the pattern file beside the
# slot-count file, matched against exactly the text --status prints after
# `running:`. At N=1 neither has any effect and the pattern file is never
# opened. A pattern file that exists but cannot be read makes EVERY run
# whole-machine and warns once: that is N=1 behaviour, and the opposite choice
# would silently drop the protection the file exists to give.
#
# LOCK PATH. `FM_BUILD_LOCK_DIR` overrides it. Otherwise this resolves the
# stable per-user temporary directory (`getconf DARWIN_USER_TEMP_DIR` on macOS)
# and falls back to /tmp. It deliberately ignores `$TMPDIR`: an agent harness
# can hand a process a session-private `$TMPDIR`, and two workers that resolved
# different roots would take different locks and silently stop excluding each
# other. Every fleet agent on this machine runs as one user, so a per-user root
# is machine-wide for the fleet and cannot be hijacked in shared /tmp.
#
# SETTINGS PATH. The slot-count file and the whole-machine pattern file live in
# `<account home>/.config/firstmate/`, or, when `FM_BUILD_LOCK_DIR` is set, in
# that directory, so a root you chose always carries exactly one count of its
# own. They are deliberately NOT in the default lock root, which the operating
# system purges: a setting that silently reverts is not a deliberate switch.
# The account home is resolved from the account database rather than trusted
# from `$XDG_CONFIG_HOME`, for the same reason `$TMPDIR` is ignored above, and
# falls back to `$HOME`. A caller that resolved the wrong file reads "absent"
# and acts as N=1, which is the safe direction: it only ever uses slot 1, can
# never push the machine past the real N, and is still excluded by a
# whole-machine hold, which always includes slot 1.
#
# NEVER ON CI. Detected CI environments exec the command straight through
# without touching the lock: the commands in a project's `.no-mistakes.yaml`
# also reach GitHub's runners through the generated workflow, where a lock on
# this machine is meaningless. `FM_BUILD_LOCK_CI=0` forces local locking and
# `FM_BUILD_LOCK_CI=1` forces stand-down.
#
# HOLD CEILINGS REPORT, THEY NEVER KILL. A wrongly killed build is worse than a
# slow one, so passing a ceiling only prints a warning. A holder past its
# ceiling warns from its own pane even with nobody waiting; a waiter past its
# ceiling warns too, and every waiting line names the longest-running holder so
# an inspected quiet pane reads as waiting rather than wedged. Neither default
# moves with N: the hold ceiling is a diagnostic for a broken wrap rule rather
# than a fairness control, and a wait past the ceiling at N>1 means every slot
# has been busy that long, which is rarer and more worth acting on. At N>1 a
# waiting line also says when a slot is free but an earlier arrival goes first,
# because otherwise an inspected pane reads as wedged for a new reason.
#
# A CEILING ALSO REACHES THE SUPERVISOR. Stderr is read by nobody when the
# command runs in the background, which is where every measured long hold ran.
# When FM_TASK_STATUS names a task's status file - bin/fm-spawn.sh exports it
# into ship and scout panes next to FM_TASK_ID - the first crossing of each
# ceiling also appends one line there, which wakes firstmate through its
# ordinary status path. A holder appends an informational `note:` naming what it
# runs, how long it has held and how many are queued; it is still working, so
# the line never reads as a decision or a blocker. A waiter appends a declared
# `paused:` wait naming the holder, and a `working:` line once it gets in, the
# pairing a worker owes for any wait. Without FM_TASK_STATUS nothing is appended
# and no path is ever guessed: a captain's own terminal and pipeline agents keep
# stderr only. A failed append never fails the build.
#
# ARRIVAL ORDER, SO BARGING IS IMPOSSIBLE BY CONSTRUCTION. Acquisition is
# ticketed: every invocation claims a monotonically increasing ticket on arrival
# and may try only while its ticket is the OLDEST outstanding one, so a waiter's
# wait is bounded by the number of waiters ahead of it rather than by its luck
# in a race. N changes only what trying means - take the lowest-numbered free
# slot - and never who may try. Letting the N oldest try instead is the obvious
# generalisation and it re-admits exactly this starvation one place down the
# line: measured with N=2, a fast poller took the freed slot ahead of an earlier
# arrival in every run, overtaking it 7, 7 and 23 times inside one poll window.
# An unordered retry loop is not merely theoretically unfair either: a worker
# that wrapped each individual test in its own invocation released and
# re-acquired hundreds of times in a row and starved a fairly waiting worker
# past its 600s ceiling.
#
# ONE INVOCATION PER RUN. A run is one build or suite command a caller would
# otherwise issue once: wrap exactly that. Never split one run into per-unit
# invocations to wrap them - ordering keeps that from starving anyone, but it
# cannot make hundreds of handovers cheap. Never put one invocation around a
# loop, script or chain of several runs either, such as a baseline plus
# mutants: wrap each run in the loop, so arrival order lets a queued caller's
# run go between two of them. This matters more with slots, not less: a loop
# inside one hold occupies its slot for the whole length, and N such loops
# starve everyone exactly as one does at N=1. Every hold longer than ten minutes
# measured in docs/verification/build-lock-contention.md was one invocation
# around such a loop, the longest 107 minutes with five callers queued behind
# it. A long wait is still a wait: running the command outside this lock to
# leave the line silently breaks exclusion for every build on the machine.
#
# A COMMAND THAT TAKES THE LOCK ITSELF IS NOT WRAPPED, AND THE RUNTIME DECIDES
# THAT. bin/fm-test-run.sh and bin/fm-stock-bash-lane.sh take a hold per unit
# themselves, so wrapping either one is the loop-inside-one-hold shape above:
# the outer hold spans the whole lane and every inner acquire passes straight
# through as a nested hold. An invocation asked to wrap one of them therefore
# takes NO hold and runs it straight through, saying so on stderr, which leaves
# those per-unit holds to keep the machine protected. It stands down rather than
# refusing, because refusing would break a caller's validation run over a
# mistake this script can simply get right, and `--exclusive` cannot widen a
# hold that is never taken, so it is ignored and named. Recognition is by
# program name, stepping over an interpreter or `env` prefix; a `bash -c`
# argument that merely mentions one is a script rather than a program name and
# is deliberately not inspected. This is enforced here because prose did not
# hold: both runners' headers, CONTRIBUTING.md and the
# firstmate-coding-guidelines skill all forbade the wrap already, while the
# generated ship brief's own rule 8 told workers to wrap "a full CI script",
# which both of these are. docs/verification/build-lock-contention.md measures
# what that cost.
#
# A NESTED INVOCATION INSIDE A HOLD RUNS STRAIGHT THROUGH. A slot is not
# reentrant, so a wrapped command that itself calls this script - `mutex` around
# bin/fm-test-run.sh, which takes a slot per script - would wait on its own
# ancestor forever. A holder therefore exports FM_BUILD_LOCK_HELD_BY (its pid)
# and FM_BUILD_LOCK_HELD_LOCK (the path of the slot it holds, which is slot 1's
# path for a whole-machine hold because that always includes slot 1) to the
# wrapped command, and an invocation that finds both naming a slot of the root
# it resolved, with that pid still that slot's live owner, runs its command
# without queueing: it is already inside that hold. So does an invocation whose
# owner is a live ANCESTOR process holding any slot, which covers a hold taken
# by an older entry point that exported no variables. Neither test is bounded by
# the current N, because N can be lowered in the middle of a hold and that hold
# is still a hold. A stale or foreign value, or a non-ancestor owner, falls back
# to an ordinary acquire.
#
# Ordering never outranks getting builds run. A waiting line that cannot be
# reached at all - a process STOPPED rather than killed still owns any lock it
# held, and no liveness test may reclaim from it - is announced on stderr and
# stepped around, because wedging every build on the machine would be a worse
# failure than losing the order they run in.
#
# ORPHANED TICKETS ARE REAPED LIKE A DEAD HOLDER. One ticket left at the head of
# the line by a waiter that died would wedge every later waiter, which is
# strictly worse than the starvation being fixed. A ticket therefore records its
# waiter's pid and is removed once that pid is gone, the same liveness test that
# already reclaims a lock from a dead holder. A live waiter also renews its
# ticket on every poll, and a ticket nobody is renewing is removed too, so a
# waiter that stops polling - or a pid number an unrelated process has since
# been given - cannot hold the head of the line. A renewal always restores the
# waiter's own place, so no live waiter is ever sent to the back. A ticket whose
# age cannot be read is unknown, not old, so it is never reaped on staleness.
#
# Environment:
#   FM_BUILD_LOCK_DIR              directory holding the lock (see LOCK PATH)
#   FM_BUILD_LOCK_CI               1/true force stand-down, 0/false force lock
#   FM_BUILD_LOCK_NOTICE_INTERVAL  seconds between waiting notices (default 60)
#   FM_BUILD_LOCK_WAIT_WARN        waiter ceiling in seconds, 0 off (default 600)
#   FM_BUILD_LOCK_HOLD_WARN        holder ceiling in seconds, 0 off (default 1200)
#   FM_BUILD_LOCK_POLL             acquire poll interval in seconds (default 0.5)
#   FM_BUILD_LOCK_TICKET_STALE     seconds an unrenewed waiting-line ticket
#                                  survives, 0 off (default 30)
#   FM_TASK_STATUS                 absolute status file for ceiling lines (see
#                                  A CEILING ALSO REACHES THE SUPERVISOR)
#   FM_BUILD_LOCK_HELD_BY          set by a holder for its wrapped command;
#   FM_BUILD_LOCK_HELD_LOCK        see A NESTED INVOCATION above
#
# The slot count has no environment variable on purpose; see HOW MANY RUN AT
# ONCE. docs/configuration.md owns both machine-level files for operators.
#
# Each slot is bin/fm-wake-lib.sh's lockdir mutex, the same primitive the wake
# queue, merges, captain holds and remote handoffs run on; the waiting line is
# serialized by a second instance of that same primitive, so this script still
# adds no second locking scheme. macOS ships no flock(1), which is why that
# lockdir implementation exists in the first place.
set -u

# Resolve through symlinks: the `mutex` entry point is a symlink to this script,
# and --install-mutex puts one in a directory of the operator's choosing, so the
# invoked path's directory is not where this script's siblings live.
fm_build_lock_self_dir() {
  local src=${BASH_SOURCE[0]} dir
  while [ -L "$src" ]; do
    dir=$(cd -P "$(dirname "$src")" >/dev/null 2>&1 && pwd) || return 1
    src=$(readlink "$src") || return 1
    case "$src" in
      /*) ;;
      *) src="$dir/$src" ;;
    esac
  done
  cd -P "$(dirname "$src")" >/dev/null 2>&1 && pwd
}

SCRIPT_DIR=$(fm_build_lock_self_dir) || {
  printf 'fm-build-lock: cannot resolve this script directory\n' >&2
  exit 2
}
SELF="$SCRIPT_DIR/fm-build-lock.sh"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$SELF"
}

note() {
  printf 'fm-build-lock: %s\n' "$*" >&2
}

die() {
  printf 'fm-build-lock: %s\n' "$*" >&2
  exit 2
}

# --- lock location ----------------------------------------------------------

fm_build_lock_root() {
  local root=
  if [ -n "${FM_BUILD_LOCK_DIR:-}" ]; then
    root=${FM_BUILD_LOCK_DIR%/}
    [ -n "$root" ] || root=/
    printf '%s\n' "$root"
    return 0
  fi
  root=$(getconf DARWIN_USER_TEMP_DIR 2>/dev/null) || root=
  case "$root" in
    /*) ;;
    *) root= ;;
  esac
  if [ -z "$root" ] || [ ! -d "$root" ] || [ ! -w "$root" ]; then
    root=/tmp
  fi
  printf '%s\n' "${root%/}"
}

# --- machine-level settings -------------------------------------------------
#
# See SETTINGS PATH in the header for why this is not the lock root by default
# and why the account home is not taken from the environment.

fm_build_lock_account_home() {
  local user home
  user=$(id -un 2>/dev/null) || user=
  case "$user" in
    ''|*[!A-Za-z0-9._-]*) user= ;;
  esac
  if [ -n "$user" ]; then
    # Tilde expansion consults the account database, which is the point: an
    # agent harness can hand a worker its own $HOME or $XDG_CONFIG_HOME, and two
    # workers that resolved different settings files would act on two values of
    # a number that must be single-valued for the machine.
    eval "home=~$user" 2>/dev/null || home=
    case "$home" in
      /*) [ -d "$home" ] && { printf '%s\n' "${home%/}"; return 0; } ;;
    esac
  fi
  case "${HOME:-}" in
    /*) printf '%s\n' "${HOME%/}"; return 0 ;;
  esac
  return 1
}

# The directory holding the slot count and the whole-machine patterns. A root
# chosen with FM_BUILD_LOCK_DIR carries its own settings, so one root always has
# exactly one count by construction - and that is the whole test seam.
fm_build_lock_settings_dir() {
  local home
  if [ -n "${FM_BUILD_LOCK_DIR:-}" ]; then
    fm_build_lock_root
    return 0
  fi
  home=$(fm_build_lock_account_home) || return 1
  printf '%s/.config/firstmate\n' "$home"
}

# --- CI stand-down ----------------------------------------------------------

# True when this process is running on a continuous integration runner. The
# explicit override is checked first so firstmate's own suite can exercise both
# branches from inside CI, where the ambient markers are always set.
fm_build_lock_is_ci() {
  local marker
  case "${FM_BUILD_LOCK_CI:-}" in
    1|true|TRUE|True|yes|YES) return 0 ;;
    0|false|FALSE|False|no|NO) return 1 ;;
    '') : ;;
    *) die "FM_BUILD_LOCK_CI must be 1/true/yes or 0/false/no, got '$FM_BUILD_LOCK_CI'" ;;
  esac
  for marker in \
    "${CI:-}" "${CONTINUOUS_INTEGRATION:-}" "${BUILD_NUMBER:-}" \
    "${GITHUB_ACTIONS:-}" "${GITLAB_CI:-}" "${BUILDKITE:-}" "${CIRCLECI:-}" \
    "${TRAVIS:-}" "${APPVEYOR:-}" "${TF_BUILD:-}" "${TEAMCITY_VERSION:-}" \
    "${JENKINS_URL:-}" "${BITBUCKET_BUILD_NUMBER:-}" "${DRONE:-}" \
    "${CODEBUILD_BUILD_ID:-}"; do
    case "$marker" in
      ''|0|false|FALSE|False|no|NO) : ;;
      *) return 0 ;;
    esac
  done
  return 1
}

# --- formatting -------------------------------------------------------------

fm_build_lock_positive_int() {  # <name> <value>
  case "$2" in
    ''|*[!0-9]*) die "$1 must be a whole number of seconds, got '$2'" ;;
  esac
  [ "$2" -gt 0 ] || die "$1 must be greater than zero, got '$2'"
}

fm_build_lock_nonneg_int() {  # <name> <value>
  case "$2" in
    ''|*[!0-9]*) die "$1 must be a whole number of seconds, got '$2'" ;;
  esac
}

fm_build_lock_elapsed() {  # <seconds>
  local s=$1
  case "$s" in ''|*[!0-9]*) s=0 ;; esac
  if [ "$s" -lt 60 ]; then
    printf '%ds\n' "$s"
  elif [ "$s" -lt 3600 ]; then
    printf '%dm%02ds\n' "$((s / 60))" "$((s % 60))"
  else
    printf '%dh%02dm\n' "$((s / 3600))" "$(((s % 3600) / 60))"
  fi
}

# One display line for a command line, with every argument shell-quoted so a
# newline or a space inside an argument can never break the single-line holder
# record that waiters read back.
fm_build_lock_render_command() {
  local arg out=''
  for arg in "$@"; do
    if [ -z "$out" ]; then
      out=$(printf '%q' "$arg")
    else
      out="$out $(printf '%q' "$arg")"
    fi
  done
  printf '%s\n' "$out"
}

# --- the slot count ---------------------------------------------------------
#
# See HOW MANY RUN AT ONCE in the header for why this is a machine-level file
# with no environment variable, and why every bad value falls back to 1 instead
# of refusing to run.

FM_BUILD_LOCK_SLOTS=1
FM_BUILD_LOCK_SLOTS_PROBLEM=
FM_BUILD_LOCK_SLOTS_WARNED=0
FM_BUILD_LOCK_CORES=

# Resolved at most once per invocation, and only when the file names a value
# above 1, so an unconfigured machine forks nothing for it. A count of 0 means
# "could not tell", which declines to clamp rather than inventing a ceiling.
fm_build_lock_resolve_cores() {
  local n
  [ -z "$FM_BUILD_LOCK_CORES" ] || return 0
  n=$(getconf _NPROCESSORS_ONLN 2>/dev/null) || n=
  case "$n" in
    ''|*[!0-9]*|0) n=$(sysctl -n hw.ncpu 2>/dev/null) || n= ;;
  esac
  case "$n" in
    ''|*[!0-9]*) n=0 ;;
  esac
  FM_BUILD_LOCK_CORES=$n
}

# Stderr only, once per invocation, in the same voice as the order-abandoned
# warning. Never to FM_TASK_STATUS: one status append per `mutex` call would
# wake the supervisor on every build on the machine.
fm_build_lock_slots_warn() {
  [ "$FM_BUILD_LOCK_SLOTS_WARNED" = 0 ] || return 0
  FM_BUILD_LOCK_SLOTS_WARNED=1
  note "WARNING: $FM_BUILD_LOCK_SLOTS_PROBLEM"
}

fm_build_lock_slots_malformed() {  # <file>
  FM_BUILD_LOCK_SLOTS=1
  FM_BUILD_LOCK_SLOTS_PROBLEM="slot count file is malformed, using 1: $1"
  fm_build_lock_slots_warn
}

# The head waiter re-reads this on every poll, which is what lets a raised count
# take effect within one poll interval, so it uses shell builtins only and forks
# nothing. The grammar is config/fleet-capacity's exactly: one positive base-10
# integer on one line in a plain regular file, surrounding whitespace ignored.
fm_build_lock_read_slots() {
  local file=${SLOTS_FILE:-} first='' second='' had_second=0 value
  FM_BUILD_LOCK_SLOTS=1
  FM_BUILD_LOCK_SLOTS_PROBLEM=
  [ -n "$file" ] || return 0
  [ -e "$file" ] || [ -L "$file" ] || return 0
  if [ ! -f "$file" ] || [ -L "$file" ] || [ ! -r "$file" ]; then
    fm_build_lock_slots_malformed "$file"
    return 0
  fi
  {
    IFS= read -r first || true
    if IFS= read -r second; then
      had_second=1
    elif [ -n "$second" ]; then
      had_second=1
    fi
  } < "$file" 2>/dev/null || true
  if [ "$had_second" = 1 ]; then
    fm_build_lock_slots_malformed "$file"
    return 0
  fi
  # Trim only the ENDS. Deleting every space instead would read "5 6" as 56,
  # which is not a typo a reader gets to correct on the operator's behalf.
  value=${first#"${first%%[![:space:]]*}"}
  value=${value%"${value##*[![:space:]]}"}
  case "$value" in
    ''|*[!0-9]*) fm_build_lock_slots_malformed "$file"; return 0 ;;
  esac
  if ! [ "$value" -gt 0 ] 2>/dev/null; then
    fm_build_lock_slots_malformed "$file"
    return 0
  fi
  if [ "$value" -gt 1 ]; then
    fm_build_lock_resolve_cores
    if [ "$FM_BUILD_LOCK_CORES" -gt 0 ] && [ "$value" -gt "$FM_BUILD_LOCK_CORES" ]; then
      FM_BUILD_LOCK_SLOTS=$FM_BUILD_LOCK_CORES
      FM_BUILD_LOCK_SLOTS_PROBLEM="slot count $value is above this machine's $FM_BUILD_LOCK_CORES online cores, using $FM_BUILD_LOCK_CORES: $file"
      fm_build_lock_slots_warn
      return 0
    fi
  fi
  FM_BUILD_LOCK_SLOTS=$value
}

# --- the slots --------------------------------------------------------------
#
# A slot is one instance of the lockdir mutex, so the number of holders is
# derived from which slot paths a live process owns rather than kept in a
# counter file that would need its own crash recovery. Slots never reap or steal
# from one another: each has its own pid record and its own `.steal` guard.

FM_BUILD_LOCK_SLOT_PATH=
FM_BUILD_LOCK_SLOT_INFO=
FM_BUILD_LOCK_LIVE_HOLDERS=0

# Slot 1 keeps today's exact lock path and holder record, which is what makes
# N=1 today's lock in every observable respect.
fm_build_lock_slot_paths() {  # <index>
  if [ "$1" = 1 ]; then
    FM_BUILD_LOCK_SLOT_PATH=$LOCK
    FM_BUILD_LOCK_SLOT_INFO=$INFO
  else
    FM_BUILD_LOCK_SLOT_PATH="$LOCK.slot$1"
    FM_BUILD_LOCK_SLOT_INFO="$LOCK.slot$1.info"
  fi
}

# The slot index a path names, or failure. The suffix is matched anchored at the
# resolved lock path, so a `.slot` in the lock root cannot be mistaken for one,
# and a non-numeric suffix keeps the primitive's own siblings - `.info`,
# `.steal`, `.owner.XXXXXX` - out of every slot scan.
fm_build_lock_slot_index() {  # <path>
  local path=$1 suffix
  if [ "$path" = "$LOCK" ]; then
    printf '1\n'
    return 0
  fi
  case "$path" in
    "$LOCK".slot*) suffix=${path#"$LOCK".slot} ;;
    *) return 1 ;;
  esac
  case "$suffix" in
    ''|*[!0-9]*) return 1 ;;
  esac
  [ "$suffix" -gt 1 ] 2>/dev/null || return 1
  printf '%s\n' "$suffix"
}

# True when a slot path above <n> exists on disk, which happens only after the
# count was lowered. Globbing only, because this sits on the poll path: when it
# is false the claim skips the live-holder count entirely, which is what leaves
# a steady N=1 with literally today's single acquire.
fm_build_lock_slot_above_exists() {  # <n>
  local n=$1 entry suffix
  for entry in "$LOCK".slot*; do
    [ -e "$entry" ] || [ -L "$entry" ] || continue
    suffix=${entry#"$LOCK".slot}
    case "$suffix" in
      ''|*[!0-9]*) continue ;;
    esac
    if [ "$suffix" -gt "$n" ] 2>/dev/null; then
      return 0
    fi
  done
  return 1
}

# How many OTHER live processes own a slot, across every slot on disk whatever
# its index, counting from <min-index> up. Lowering the count relies on this:
# until the holders above the new count finish, a claim must decline rather than
# let the head take a low slot and run more than the count allows. Slots this
# process already holds are skipped, so a whole-machine run draining the machine
# never counts itself as the reason it may not start.
fm_build_lock_count_live_holders() {  # [min-index]
  local min=${1:-1} entry suffix pid n=0
  FM_BUILD_LOCK_LIVE_HOLDERS=0
  for entry in "$LOCK" "$LOCK".slot*; do
    if [ "$entry" = "$LOCK" ]; then
      suffix=1
    else
      suffix=${entry#"$LOCK".slot}
      case "$suffix" in
        ''|*[!0-9]*) continue ;;
      esac
    fi
    [ "$suffix" -ge "$min" ] 2>/dev/null || continue
    fm_build_lock_holds_slot "$suffix" && continue
    [ -e "$entry" ] || [ -L "$entry" ] || continue
    pid=
    { IFS= read -r pid; } < "$entry/pid" 2>/dev/null || true
    case "$pid" in
      ''|*[!0-9]*)
        # No pid recorded yet is the half-created state the primitive itself
        # treats as held while it is fresh.
        fm_lock_mid_acquire_is_fresh "$entry" '' && n=$((n + 1))
        continue
        ;;
    esac
    fm_pid_alive "$pid" && n=$((n + 1))
  done
  FM_BUILD_LOCK_LIVE_HOLDERS=$n
}

# The highest slot index on disk, so --status can show a slot left above a
# lowered count instead of pretending it is not there.
fm_build_lock_highest_slot() {
  local entry suffix highest=1
  for entry in "$LOCK".slot*; do
    [ -e "$entry" ] || [ -L "$entry" ] || continue
    suffix=${entry#"$LOCK".slot}
    case "$suffix" in
      ''|*[!0-9]*) continue ;;
    esac
    [ "$suffix" -gt "$highest" ] 2>/dev/null && highest=$suffix
  done
  printf '%s\n' "$highest"
}

# --- holder record ----------------------------------------------------------
#
# Only the process holding a slot ever writes that slot's file, and every reader
# validates its first line against the slot's own authoritative pid record, so a
# record left behind by a killed holder is reported as unavailable rather than
# as a live holder.
#
# A whole-machine hold adds a fourth line, `reserved` while it is still draining
# the other slots and `running` once it started. The first three lines never
# move, so an older copy of this script reads such a record exactly as before.

fm_build_lock_write_info() {  # <info-path> <pid> <started> <display> [state]
  local info=$1 pid=$2 started=$3 display=$4 state=${5:-} tmp
  tmp="$info.$pid.tmp"
  if [ -n "$state" ]; then
    { printf '%s\n%s\n%s\n%s\n' "$pid" "$started" "$display" "$state" > "$tmp"; } 2>/dev/null \
      || { rm -f -- "$tmp" 2>/dev/null; return 1; }
  else
    { printf '%s\n%s\n%s\n' "$pid" "$started" "$display" > "$tmp"; } 2>/dev/null \
      || { rm -f -- "$tmp" 2>/dev/null; return 1; }
  fi
  mv -f -- "$tmp" "$info" 2>/dev/null || { rm -f -- "$tmp" 2>/dev/null; return 1; }
}

# Read the current holder into FM_BUILD_LOCK_HOLDER_TEXT (a human sentence, or
# empty when the lock is free) and FM_BUILD_LOCK_HOLDER_SECS (its age, or
# empty). It sets globals instead of echoing because a caller that needs the
# age cannot capture it through a command substitution's subshell.
FM_BUILD_LOCK_HOLDER_TEXT=
FM_BUILD_LOCK_HOLDER_SECS=
FM_BUILD_LOCK_HOLDER_PID=
FM_BUILD_LOCK_HOLDER_DISPLAY=
FM_BUILD_LOCK_HOLDER_STATE=

fm_build_lock_read_holder() {  # <lockdir> <info-path>
  local lockdir=$1 info=$2 pid info_pid started display state now age
  FM_BUILD_LOCK_HOLDER_TEXT=
  FM_BUILD_LOCK_HOLDER_SECS=
  FM_BUILD_LOCK_HOLDER_PID=
  FM_BUILD_LOCK_HOLDER_DISPLAY=
  FM_BUILD_LOCK_HOLDER_STATE=
  pid=$(cat "$lockdir/pid" 2>/dev/null || true)
  case "$pid" in
    ''|*[!0-9]*) return 0 ;;
  esac
  FM_BUILD_LOCK_HOLDER_PID=$pid
  info_pid=
  started=
  display=
  state=
  if [ -f "$info" ] && [ ! -L "$info" ]; then
    { read -r info_pid; read -r started; IFS= read -r display; IFS= read -r state; } \
      < "$info" 2>/dev/null || true
  fi
  if [ "$info_pid" != "$pid" ]; then
    FM_BUILD_LOCK_HOLDER_TEXT="held by pid $pid (no command record)"
    return 0
  fi
  FM_BUILD_LOCK_HOLDER_DISPLAY=$display
  case "$state" in
    reserved|running) FM_BUILD_LOCK_HOLDER_STATE=$state ;;
  esac
  case "$started" in
    ''|*[!0-9]*)
      FM_BUILD_LOCK_HOLDER_TEXT="held by pid $pid running: $display"
      return 0
      ;;
  esac
  now=$(date +%s)
  age=$((now - started))
  [ "$age" -ge 0 ] || age=0
  FM_BUILD_LOCK_HOLDER_SECS=$age
  FM_BUILD_LOCK_HOLDER_TEXT="held by pid $pid for $(fm_build_lock_elapsed "$age") running: $display"
}

# A waiter can look between another process taking the lock and publishing its
# command, which would report a live holder as having no command record - the
# least useful thing to print at exactly the moment observability matters. Give
# the new holder a bounded chance to publish before settling on that answer.
fm_build_lock_read_holder_settled() {  # <lockdir> <info-path>
  local attempt=1
  while [ "$attempt" -le 3 ]; do
    fm_build_lock_read_holder "$1" "$2"
    case "$FM_BUILD_LOCK_HOLDER_TEXT" in
      *'(no command record)') : ;;
      *) return 0 ;;
    esac
    attempt=$((attempt + 1))
    [ "$attempt" -le 3 ] || break
    sleep "$POLL"
  done
  return 0
}

# --- hold ceiling ------------------------------------------------------------
#
# The ceiling is watched from this process, in the same loop that waits for the
# wrapped command, so nothing is forked to watch it. A background watcher was
# tried first and is the wrong shape: an asynchronous subshell and the `sleep`
# it forks both inherit the caller's stderr, so `mutex build 2>&1 | tee log`
# stalled for a whole tick after the build finished, waiting on a process that
# had nothing left to say. Polling here instead means the only child this script
# ever leaves behind is one short `sleep`, which holds the caller's pipe for at
# most one poll interval and only if this process is SIGKILLed.
#
# It reports and never signals the wrapped command: a wrongly killed build is
# worse than a slow one.

# Append one line to the task status file named by FM_TASK_STATUS, or do
# nothing. The directory must already exist: this never creates a home.
fm_build_lock_task_status() {  # <status-line>
  local path=${FM_TASK_STATUS:-}
  case "$path" in
    /*) ;;
    *) return 0 ;;
  esac
  [ -d "${path%/*}" ] && [ ! -d "$path" ] || return 0
  { printf '%s\n' "$1" >> "$path"; } 2>/dev/null || true
}

# A whole-machine hold keeps today's sentence, because for it the sentence is
# true. An ordinary hold at N>1 must not print it: it is blocking nobody, and a
# warning that says otherwise sends a reader looking for a contention that is
# not there.
fm_build_lock_report_ceiling() {  # <held-secs> <display>
  if [ "$FM_BUILD_LOCK_MULTI" = 1 ] && [ "$FM_BUILD_LOCK_EXCLUSIVE" = 0 ]; then
    printf 'fm-build-lock: WARNING: this command has held %s of %s machine-wide build slots for %s: %s\n' \
      "$(fm_build_lock_held_slot_count)" "$FM_BUILD_LOCK_N" "$(fm_build_lock_elapsed "$1")" "$2" >&2
    return 0
  fi
  printf 'fm-build-lock: WARNING: this command has held the machine-wide build lock for %s and is blocking every other local build: %s\n' \
    "$(fm_build_lock_elapsed "$1")" "$2" >&2
}

# --- the waiting line -------------------------------------------------------
#
# A ticket is one file per waiting invocation, named for its sequence number and
# holding the waiter's pid. Minting a number is the only step that has to be
# serialized, and it is, by a second instance of the same lockdir mutex - not a
# second locking scheme. Everything else reads and reaps without that lock,
# deliberately: the line's lock sits on the critical path of every build on the
# machine, so the less time anything holds it, the smaller the one failure it
# cannot recover from.
#
# THAT FAILURE, AND WHY THIS STEPS AROUND IT. A process STOPPED rather than
# killed - Ctrl-Z on a waiting build, a debugger - is still alive, so the lock's
# dead-owner recovery correctly refuses to reclaim from it. Waiting forever on a
# line nobody can reach would wedge every build on the machine, which is exactly
# the outcome this file exists to prevent, so the wait is bounded and a line
# that cannot be reached is announced and stepped around. Ordering is a fairness
# property layered over the build lock; the build lock alone is what makes
# exclusion correct, and it is untouched by the step-around.
#
# A ticket is dropped the moment its waiter takes the lock, so the line holds
# waiters only and the holder is never in it. The last waiter out takes the line
# itself with it, which is what keeps an idle machine free of build-lock
# residue.

# Seconds to keep trying for the line's lock before giving up on ordering.
# Generous, because every legitimate hold on it is a handful of file operations:
# reaching this bound means something is stopped, not that something is busy.
FM_BUILD_LOCK_QUEUE_LOCK_WAIT=60

FM_BUILD_LOCK_TICKET=
FM_BUILD_LOCK_UNORDERED=0
FM_BUILD_LOCK_QUEUE_MIN=
FM_BUILD_LOCK_QUEUE_MAX=
FM_BUILD_LOCK_QUEUE_COUNT=0
FM_BUILD_LOCK_QUEUE_AHEAD=0

# Bounded acquire of the line's lock. See THAT FAILURE above for why this cannot
# be an ordinary blocking acquire.
fm_build_lock_queue_lock() {
  local deadline=$((SECONDS + FM_BUILD_LOCK_QUEUE_LOCK_WAIT))
  while ! fm_lock_try_acquire "$QLOCK"; do
    [ "$SECONDS" -lt "$deadline" ] || return 1
    sleep "$POLL"
  done
}

# Give up on arrival ordering, loudly and once. Acquisition stays correct; only
# the guarantee about who goes first is lost, so this says so in the same voice
# the ceilings use rather than degrading in silence.
fm_build_lock_abandon_order() {  # <why>
  [ "$FM_BUILD_LOCK_UNORDERED" = 0 ] || return 0
  FM_BUILD_LOCK_UNORDERED=1
  FM_BUILD_LOCK_TICKET=
  note "WARNING: $1, so this build is acquiring the machine-wide build lock WITHOUT arrival ordering; it still excludes other builds, but waiters may now be overtaken"
}

# Reap every ticket nobody is waiting on, then report the line: its oldest and
# newest sequence numbers, how many waiters it holds, and how many of them are
# ahead of <mine> when a sequence number is given.
fm_build_lock_queue_scan() {  # [mine]
  local mine=${1:-} entry seq pid mtime age
  FM_BUILD_LOCK_QUEUE_MIN=
  FM_BUILD_LOCK_QUEUE_MAX=
  FM_BUILD_LOCK_QUEUE_COUNT=0
  FM_BUILD_LOCK_QUEUE_AHEAD=0
  for entry in "$QUEUE"/t.*; do
    [ -f "$entry" ] && [ ! -L "$entry" ] || continue
    seq=${entry##*/t.}
    pid=$(cat "$entry" 2>/dev/null || true)
    case "$seq" in ''|*[!0-9]*) rm -f -- "$entry" 2>/dev/null || true; continue ;; esac
    case "$pid" in ''|*[!0-9]*) rm -f -- "$entry" 2>/dev/null || true; continue ;; esac
    if ! fm_pid_alive "$pid"; then
      rm -f -- "$entry" 2>/dev/null || true
      continue
    fi
    mtime=$(fm_path_mtime "$entry" 2>/dev/null || true)
    case "$mtime" in
      ''|*[!0-9]*) ;;
      *)
        age=$(( $(date +%s) - mtime ))
        if [ "$TICKET_STALE" -gt 0 ] && [ "$age" -gt "$TICKET_STALE" ]; then
          rm -f -- "$entry" 2>/dev/null || true
          continue
        fi
        ;;
    esac
    FM_BUILD_LOCK_QUEUE_COUNT=$((FM_BUILD_LOCK_QUEUE_COUNT + 1))
    if [ -z "$FM_BUILD_LOCK_QUEUE_MIN" ] || [ "$seq" -lt "$FM_BUILD_LOCK_QUEUE_MIN" ]; then
      FM_BUILD_LOCK_QUEUE_MIN=$seq
    fi
    if [ -z "$FM_BUILD_LOCK_QUEUE_MAX" ] || [ "$seq" -gt "$FM_BUILD_LOCK_QUEUE_MAX" ]; then
      FM_BUILD_LOCK_QUEUE_MAX=$seq
    fi
    if [ -n "$mine" ] && [ "$seq" -lt "$mine" ]; then
      FM_BUILD_LOCK_QUEUE_AHEAD=$((FM_BUILD_LOCK_QUEUE_AHEAD + 1))
    fi
  done
}

# Publish a ticket through a rename, so a scan that is deliberately unlocked
# never reads one half-written and reaps a waiter that had just arrived. The
# scratch name carries the writer's pid, and the only code that removes scratch
# files holds the line's lock, so this can never race with a cleanup.
fm_build_lock_ticket_publish() {  # <seq> <pid>
  local seq=$1 pid=$2
  local tmp="$QUEUE/tmp.$pid"
  if printf '%s\n' "$pid" > "$tmp" 2>/dev/null \
    && mv -f -- "$tmp" "$QUEUE/t.$seq" 2>/dev/null; then
    return 0
  fi
  rm -f -- "$tmp" 2>/dev/null || true
  return 1
}

# Take a ticket. The counter is advanced past any live ticket that outran it, so
# a counter lost to a partial write cannot hand a newcomer a number that would
# put it in front of waiters already in line.
fm_build_lock_queue_enter() {
  local mypid next rc=1
  if ! fm_current_pid mypid; then
    fm_build_lock_abandon_order "this process cannot name its own pid to the build lock's waiting line"
    return 0
  fi
  if ! fm_build_lock_queue_lock; then
    fm_build_lock_abandon_order "the build lock's waiting line is unreachable"
    return 0
  fi
  if mkdir -p "$QUEUE" 2>/dev/null; then
    fm_build_lock_queue_scan
    next=$(cat "$QUEUE/next" 2>/dev/null || true)
    case "$next" in ''|*[!0-9]*) next=1 ;; esac
    if [ -n "$FM_BUILD_LOCK_QUEUE_MAX" ] && [ "$next" -le "$FM_BUILD_LOCK_QUEUE_MAX" ]; then
      next=$((FM_BUILD_LOCK_QUEUE_MAX + 1))
    fi
    if printf '%s\n' "$((next + 1))" > "$QUEUE/next" 2>/dev/null \
      && fm_build_lock_ticket_publish "$next" "$mypid"; then
      FM_BUILD_LOCK_TICKET=$next
      rc=0
    fi
  fi
  fm_lock_release "$QLOCK" || true
  [ "$rc" -eq 0 ] || fm_build_lock_abandon_order "the build lock's waiting line cannot be written under $LOCK_ROOT"
  return 0
}

# True only while this invocation holds the oldest outstanding ticket, which is
# the whole of the ordering guarantee: everyone else declines to even try.
# It renews the ticket first - that renewal is what tells every other waiter
# this one is still here - and restores a ticket a reaper took while this
# process was merely slow, so waiting longer can never cost a live waiter the
# place it already earned. It takes no lock, deliberately: this runs on every
# poll of every waiter, and see THAT FAILURE above for what holding one here
# would cost.
fm_build_lock_my_turn() {
  local mine=$FM_BUILD_LOCK_TICKET mypid
  [ "$FM_BUILD_LOCK_UNORDERED" = 0 ] || return 0
  [ -n "$mine" ] || return 1
  if ! fm_current_pid mypid; then
    fm_build_lock_abandon_order "this process cannot name its own pid to the build lock's waiting line"
    return 0
  fi
  if [ -f "$QUEUE/t.$mine" ]; then
    touch "$QUEUE/t.$mine" 2>/dev/null || true
  else
    mkdir -p "$QUEUE" 2>/dev/null || true
    fm_build_lock_ticket_publish "$mine" "$mypid" || true
  fi
  fm_build_lock_queue_scan "$mine"
  [ "$FM_BUILD_LOCK_QUEUE_MIN" = "$mine" ]
}

# Give the ticket back. Removing it needs no lock; taking the whole line away
# does, because an arrival is creating the same directory under that lock. That
# second step is one non-blocking attempt and nothing more: this also runs from
# the exit trap of an interrupted build, where waiting on anything would hold a
# terminal, and an empty line left behind is tidied by the next invocation.
fm_build_lock_queue_leave() {
  local mine=$FM_BUILD_LOCK_TICKET
  [ -n "$mine" ] || return 0
  FM_BUILD_LOCK_TICKET=
  rm -f -- "$QUEUE/t.$mine" 2>/dev/null || true
  fm_lock_try_acquire "$QLOCK" || return 0
  fm_build_lock_queue_scan
  if [ "$FM_BUILD_LOCK_QUEUE_COUNT" -eq 0 ]; then
    rm -f -- "$QUEUE/next" "$QUEUE"/tmp.* 2>/dev/null || true
    rmdir "$QUEUE" 2>/dev/null || true
  fi
  fm_lock_release "$QLOCK" || true
}

# Empty unless this waiter has company, because "position 1 of 1" is noise.
fm_build_lock_queue_position() {
  [ "$FM_BUILD_LOCK_QUEUE_COUNT" -gt 1 ] || return 0
  printf 'position %d of %d in line' \
    "$((FM_BUILD_LOCK_QUEUE_AHEAD + 1))" "$FM_BUILD_LOCK_QUEUE_COUNT"
}

# --- whole-machine runs -----------------------------------------------------
#
# See A RUN THAT NEEDS THE WHOLE MACHINE in the header for why a count alone
# does not bound what N holders cost.

FM_BUILD_LOCK_EXCLUSIVE=0
FM_BUILD_LOCK_EXCLUSIVE_FLAG=0
FM_BUILD_LOCK_EXCLUSIVE_RESOLVED=0

# One shell glob per line, `#` comments and blank lines ignored, matched with a
# plain `case` against exactly the text --status prints after `running:`. That
# line carries the working directory, so a pattern can name a repository's
# worktrees as easily as a command. The classification belongs here, with the
# one person who knows this machine, rather than in each caller's brief: the
# measured record is that callers misjudge even whether a command is heavy.
fm_build_lock_matches_exclusive_patterns() {
  local file=${EXCLUSIVE_FILE:-} line
  [ -n "$file" ] || return 1
  [ -e "$file" ] || [ -L "$file" ] || return 1
  if [ ! -f "$file" ] || [ -L "$file" ] || [ ! -r "$file" ]; then
    note "WARNING: the whole-machine pattern file cannot be read, so every run is treated as needing the whole machine: $file"
    return 0
  fi
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      ''|'#'*) continue ;;
    esac
    # Unquoted deliberately: the line IS the glob, which is the whole feature.
    # shellcheck disable=SC2254
    case "$DISPLAY_LINE" in
      $line) return 0 ;;
    esac
  done < "$file" 2>/dev/null
  return 1
}

# Resolved at most once per invocation, and never at N=1, where one slot is
# every slot so neither the flag nor the file can change anything - which is why
# the pattern file is not even opened there.
fm_build_lock_resolve_exclusive() {  # <n>
  [ "$FM_BUILD_LOCK_EXCLUSIVE_RESOLVED" = 0 ] || return 0
  [ "$1" -gt 1 ] || return 0
  FM_BUILD_LOCK_EXCLUSIVE_RESOLVED=1
  if [ "$FM_BUILD_LOCK_EXCLUSIVE_FLAG" = 1 ] || fm_build_lock_matches_exclusive_patterns; then
    FM_BUILD_LOCK_EXCLUSIVE=1
  fi
}

# --- claiming a slot --------------------------------------------------------

FM_BUILD_LOCK_HELD_SLOTS=
FM_BUILD_LOCK_N=1
FM_BUILD_LOCK_SLOT_ABOVE=0
FM_BUILD_LOCK_MULTI=0
FM_BUILD_LOCK_NOUN='the machine-wide build lock'

fm_build_lock_holds_slot() {  # <index>
  case " $FM_BUILD_LOCK_HELD_SLOTS " in
    *" $1 "*) return 0 ;;
  esac
  return 1
}

fm_build_lock_held_slot_count() {
  local k n=0
  for k in $FM_BUILD_LOCK_HELD_SLOTS; do
    n=$((n + 1))
  done
  printf '%s\n' "$n"
}

# The lowest slot this process holds. A whole-machine hold always includes slot
# 1, so what it exports as FM_BUILD_LOCK_HELD_LOCK is slot 1's path and an older
# copy of this script still recognises the hold.
fm_build_lock_lowest_held_slot() {
  local k low=
  for k in $FM_BUILD_LOCK_HELD_SLOTS; do
    if [ -z "$low" ] || [ "$k" -lt "$low" ]; then
      low=$k
    fi
  done
  printf '%s\n' "${low:-1}"
}

# The head's one attempt per poll: take the lowest-numbered free slot. Lowest
# first is what makes N=1 identical to today and keeps high slots empty when the
# machine is quiet.
fm_build_lock_claim_one() {  # <n> <a-slot-above-n-exists>
  local n=$1 above=$2 k
  # The live-holder count only matters while a slot ABOVE the count exists on
  # disk, which happens only after the count was lowered. In every steady state,
  # including the unconfigured N=1, this is skipped and the claim below is
  # literally today's single acquire.
  if [ "$above" = 1 ]; then
    fm_build_lock_count_live_holders
    [ "$FM_BUILD_LOCK_LIVE_HOLDERS" -lt "$n" ] || return 1
  fi
  k=1
  while [ "$k" -le "$n" ]; do
    fm_build_lock_slot_paths "$k"
    if fm_lock_try_acquire "$FM_BUILD_LOCK_SLOT_PATH"; then
      FM_BUILD_LOCK_HELD_SLOTS=$k
      return 0
    fi
    k=$((k + 1))
  done
  return 1
}

# A whole-machine run reserves slots as they free and keeps them, so nothing
# slips past while it drains: letting later, lighter runs through would be the
# starvation ARRIVAL ORDER exists to prevent, with the roles reversed. Only an
# ORDERED head may keep a partial reservation across polls - two processes each
# holding part of the slots and waiting for the rest is a deadlock, and
# head-only admission is what makes at most one such process exist. An
# invocation that announced it abandoned ordering therefore makes one
# all-or-nothing pass per poll and gives back whatever it could not complete.
fm_build_lock_claim_exclusive() {  # <n>
  local n=$1 k now=
  k=1
  while [ "$k" -le "$n" ]; do
    if ! fm_build_lock_holds_slot "$k"; then
      fm_build_lock_slot_paths "$k"
      if fm_lock_try_acquire "$FM_BUILD_LOCK_SLOT_PATH"; then
        # Read the clock only when there is a reservation to stamp, so a poll
        # that takes nothing forks nothing.
        [ -n "$now" ] || now=$(date +%s)
        FM_BUILD_LOCK_HELD_SLOTS="${FM_BUILD_LOCK_HELD_SLOTS:+$FM_BUILD_LOCK_HELD_SLOTS }$k"
        fm_build_lock_write_info "$FM_BUILD_LOCK_SLOT_INFO" "$$" "$now" "$DISPLAY_LINE" reserved || true
      fi
    fi
    k=$((k + 1))
  done
  # "Every slot 1..n", not "n slots": the count can be lowered while this run is
  # draining, and counting instead would leave a run holding MORE than the new
  # count waiting forever for a number it had already passed.
  k=1
  while [ "$k" -le "$n" ] && fm_build_lock_holds_slot "$k"; do
    k=$((k + 1))
  done
  if [ "$k" -gt "$n" ]; then
    # A slot left above a lowered count can still be running, and the machine is
    # not this run's alone until it is gone.
    fm_build_lock_count_live_holders $((n + 1))
    if [ "$FM_BUILD_LOCK_LIVE_HOLDERS" -eq 0 ]; then
      return 0
    fi
  fi
  [ "$FM_BUILD_LOCK_UNORDERED" = 0 ] || fm_build_lock_release_slots
  return 1
}

# Retire a slot record left behind by a holder that died. The primitive already
# reclaims one when a claimer reaches that slot, but a claimer stops at the
# first free slot, so on a quiet machine nothing ever reaches a high one again -
# and an idle machine having no build-lock residue is a guarantee this change
# keeps. Reclaiming is not reimplemented here: the slot is taken through the
# primitive's own guarded dead-holder path and given straight back.
#
# Runs once per acquisition, from the head, exactly like the primitive's own
# stray-owner collection - never on the poll path, where it would cost every
# waiter a directory scan per poll.
fm_build_lock_reap_dead_slots() {
  local entry suffix pid
  for entry in "$LOCK".slot*; do
    [ -e "$entry" ] || [ -L "$entry" ] || continue
    suffix=${entry#"$LOCK".slot}
    case "$suffix" in
      ''|*[!0-9]*) continue ;;
    esac
    fm_build_lock_holds_slot "$suffix" && continue
    pid=
    { IFS= read -r pid; } < "$entry/pid" 2>/dev/null || true
    case "$pid" in
      ''|*[!0-9]*) continue ;;
    esac
    fm_pid_alive "$pid" && continue
    if fm_lock_try_acquire "$entry"; then
      rm -f -- "$entry.info" 2>/dev/null || true
      fm_lock_release "$entry" || true
    fi
  done
}

# Published once per slot this process holds. A whole-machine run rewrites the
# records it wrote while reserving, so their age becomes the run's rather than
# the drain's.
fm_build_lock_publish_holder() {  # <started>
  local k state=
  [ "$FM_BUILD_LOCK_EXCLUSIVE" = 0 ] || state=running
  for k in $FM_BUILD_LOCK_HELD_SLOTS; do
    fm_build_lock_slot_paths "$k"
    fm_build_lock_write_info "$FM_BUILD_LOCK_SLOT_INFO" "$$" "$1" "$DISPLAY_LINE" "$state" || true
  done
}

# Re-read the count, and decide which vocabulary this invocation speaks. EVERY
# waiter does this on every poll, not only the one at the head of the line: a
# waiter that is never the head would otherwise describe a machine with several
# slots in the words of a single lock, which is the pane that reads as wedged.
# It is also what lets a raised count take effect within one poll.
fm_build_lock_refresh_count() {
  local above=0
  fm_build_lock_read_slots
  FM_BUILD_LOCK_N=$FM_BUILD_LOCK_SLOTS
  fm_build_lock_slot_above_exists "$FM_BUILD_LOCK_N" && above=1
  FM_BUILD_LOCK_SLOT_ABOVE=$above
  if [ "$FM_BUILD_LOCK_N" -gt 1 ] || [ "$above" = 1 ]; then
    FM_BUILD_LOCK_MULTI=1
    FM_BUILD_LOCK_NOUN='a machine-wide build slot'
  fi
}

# The head's one attempt per poll, against the count refreshed just above it.
fm_build_lock_claim() {
  fm_build_lock_resolve_exclusive "$FM_BUILD_LOCK_N"
  if [ "$FM_BUILD_LOCK_EXCLUSIVE" = 1 ]; then
    fm_build_lock_claim_exclusive "$FM_BUILD_LOCK_N"
    return
  fi
  fm_build_lock_claim_one "$FM_BUILD_LOCK_N" "$FM_BUILD_LOCK_SLOT_ABOVE"
}

# --- what a waiter says about the slots -------------------------------------

FM_BUILD_LOCK_WAIT_CONTEXT=
FM_BUILD_LOCK_WAIT_OLDEST_SECS=
FM_BUILD_LOCK_WAIT_OLDEST_TEXT=
FM_BUILD_LOCK_WAIT_HELD=0
FM_BUILD_LOCK_WAIT_DRAINING=0

fm_build_lock_scan_holders() {
  local n=$FM_BUILD_LOCK_N k highest
  FM_BUILD_LOCK_WAIT_HELD=0
  FM_BUILD_LOCK_WAIT_OLDEST_TEXT=
  FM_BUILD_LOCK_WAIT_OLDEST_SECS=
  FM_BUILD_LOCK_WAIT_DRAINING=0
  highest=$(fm_build_lock_highest_slot)
  [ "$highest" -ge "$n" ] 2>/dev/null || highest=$n
  k=1
  while [ "$k" -le "$highest" ]; do
    fm_build_lock_slot_paths "$k"
    fm_build_lock_read_holder "$FM_BUILD_LOCK_SLOT_PATH" "$FM_BUILD_LOCK_SLOT_INFO"
    [ "$FM_BUILD_LOCK_HOLDER_STATE" != reserved ] || FM_BUILD_LOCK_WAIT_DRAINING=1
    if [ -n "$FM_BUILD_LOCK_HOLDER_TEXT" ]; then
      FM_BUILD_LOCK_WAIT_HELD=$((FM_BUILD_LOCK_WAIT_HELD + 1))
      if [ -z "$FM_BUILD_LOCK_WAIT_OLDEST_TEXT" ] \
        || [ "${FM_BUILD_LOCK_HOLDER_SECS:-0}" -gt "${FM_BUILD_LOCK_WAIT_OLDEST_SECS:-0}" ]; then
        FM_BUILD_LOCK_WAIT_OLDEST_TEXT=$FM_BUILD_LOCK_HOLDER_TEXT
        FM_BUILD_LOCK_WAIT_OLDEST_SECS=$FM_BUILD_LOCK_HOLDER_SECS
      fi
    fi
    k=$((k + 1))
  done
}

# The sentence every waiting line carries. At N>1 it names the count and the
# longest-running holder in full and counts the rest: naming all N would grow
# the line with N and with each holder's working directory, while the oldest is
# the one a reader needs, because it is the one most likely past its ceiling.
fm_build_lock_wait_context() {
  local n=$FM_BUILD_LOCK_N attempt=1
  if [ "$FM_BUILD_LOCK_MULTI" = 0 ]; then
    fm_build_lock_read_holder_settled "$LOCK" "$INFO"
    FM_BUILD_LOCK_WAIT_CONTEXT=$FM_BUILD_LOCK_HOLDER_TEXT
    FM_BUILD_LOCK_WAIT_OLDEST_SECS=$FM_BUILD_LOCK_HOLDER_SECS
    return 0
  fi
  while [ "$attempt" -le 3 ]; do
    fm_build_lock_scan_holders
    case "$FM_BUILD_LOCK_WAIT_OLDEST_TEXT" in
      *'(no command record)') : ;;
      *) break ;;
    esac
    attempt=$((attempt + 1))
    [ "$attempt" -le 3 ] || break
    sleep "$POLL"
  done
  # At N>1 a waiter can be waiting for a reason an inspected pane cannot see:
  # behind an earlier arrival that has not polled yet while a slot sits free, or
  # behind a whole-machine run collecting the slots one by one. Both read as
  # wedged unless the line says which, and not reading as wedged is what these
  # lines are for.
  if [ "$FM_BUILD_LOCK_WAIT_DRAINING" = 1 ]; then
    FM_BUILD_LOCK_WAIT_CONTEXT='a whole-machine run is taking every slot, and an earlier arrival goes first'
  elif [ "$FM_BUILD_LOCK_WAIT_HELD" -lt "$n" ]; then
    FM_BUILD_LOCK_WAIT_CONTEXT='a slot is free, but an earlier arrival goes first'
  else
    FM_BUILD_LOCK_WAIT_CONTEXT="all $n slots held"
  fi
  if [ "$FM_BUILD_LOCK_WAIT_HELD" -gt 0 ]; then
    FM_BUILD_LOCK_WAIT_CONTEXT="$FM_BUILD_LOCK_WAIT_CONTEXT; oldest: $FM_BUILD_LOCK_WAIT_OLDEST_TEXT"
    if [ "$FM_BUILD_LOCK_WAIT_HELD" -gt 1 ]; then
      FM_BUILD_LOCK_WAIT_CONTEXT="$FM_BUILD_LOCK_WAIT_CONTEXT; $((FM_BUILD_LOCK_WAIT_HELD - 1)) more - see mutex --status"
    fi
  fi
}

# --- observable acquire -----------------------------------------------------

fm_build_lock_acquire() {
  local start waited=0 next_notice ctx now place paused=0
  fm_build_lock_queue_enter
  fm_build_lock_refresh_count
  if fm_build_lock_my_turn && fm_build_lock_claim; then
    fm_build_lock_reap_dead_slots
    fm_build_lock_queue_leave
    return 0
  fi
  start=$(date +%s)
  next_notice=$NOTICE_INTERVAL
  fm_build_lock_wait_context
  ctx=$FM_BUILD_LOCK_WAIT_CONTEXT
  note "waiting for $FM_BUILD_LOCK_NOUN - this process is WAITING, not wedged${ctx:+ (}${ctx}${ctx:+)}"
  while : ; do
    sleep "$POLL"
    fm_build_lock_refresh_count
    if fm_build_lock_my_turn && fm_build_lock_claim; then
      break
    fi
    now=$(date +%s)
    waited=$((now - start))
    [ "$waited" -ge "$next_notice" ] || continue
    next_notice=$((waited + NOTICE_INTERVAL))
    place=$(fm_build_lock_queue_position)
    fm_build_lock_wait_context
    ctx=$FM_BUILD_LOCK_WAIT_CONTEXT
    if [ "$WAIT_WARN" -gt 0 ] && [ "$waited" -ge "$WAIT_WARN" ]; then
      note "WARNING: still WAITING $(fm_build_lock_elapsed "$waited") for $FM_BUILD_LOCK_NOUN, past the ${WAIT_WARN}s ceiling${place:+ - }${place}${ctx:+ - }${ctx}"
      if [ "$paused" = 0 ]; then
        paused=1
        fm_build_lock_task_status "paused: waiting $(fm_build_lock_elapsed "$waited") for $FM_BUILD_LOCK_NOUN to run $DISPLAY_LINE${ctx:+ - }${ctx}"
      fi
    else
      note "still waiting $(fm_build_lock_elapsed "$waited") for $FM_BUILD_LOCK_NOUN${place:+ - }${place}${ctx:+ - }${ctx}"
    fi
    if [ -n "$FM_BUILD_LOCK_WAIT_OLDEST_SECS" ] && [ "$HOLD_WARN" -gt 0 ] \
      && [ "$FM_BUILD_LOCK_WAIT_OLDEST_SECS" -ge "$HOLD_WARN" ]; then
      if [ "$FM_BUILD_LOCK_MULTI" = 1 ]; then
        note "WARNING: the oldest holder has held its slot $(fm_build_lock_elapsed "$FM_BUILD_LOCK_WAIT_OLDEST_SECS"), past the ${HOLD_WARN}s ceiling; it is not being killed"
      else
        note "WARNING: the holder has held the build lock $(fm_build_lock_elapsed "$FM_BUILD_LOCK_WAIT_OLDEST_SECS"), past the ${HOLD_WARN}s ceiling; it is not being killed"
      fi
    fi
  done
  now=$(date +%s)
  waited=$((now - start))
  fm_build_lock_reap_dead_slots
  fm_build_lock_queue_leave
  note "acquired $FM_BUILD_LOCK_NOUN after $(fm_build_lock_elapsed "$waited")"
  [ "$paused" = 0 ] \
    || fm_build_lock_task_status "working: acquired $FM_BUILD_LOCK_NOUN after $(fm_build_lock_elapsed "$waited")"
}

# --- release ----------------------------------------------------------------

FM_BUILD_LOCK_CHILD=

# Give back every slot this process owns and nothing else: a slot is released by
# its own holder, which is what keeps one holder's exit from disturbing another.
# For a whole-machine run this includes slots it had only RESERVED while
# draining, so an interrupted drain frees them at once rather than leaving them
# for the next claimer's liveness reclaim.
fm_build_lock_release_slots() {
  local k
  for k in $FM_BUILD_LOCK_HELD_SLOTS; do
    fm_build_lock_slot_paths "$k"
    rm -f -- "$FM_BUILD_LOCK_SLOT_INFO" 2>/dev/null || true
    fm_lock_release "$FM_BUILD_LOCK_SLOT_PATH" || true
  done
  FM_BUILD_LOCK_HELD_SLOTS=
}

# shellcheck disable=SC2329 # Reached only through the EXIT trap below.
fm_build_lock_release_now() {
  # An invocation interrupted while still waiting holds a ticket and no slot;
  # giving it back here retires it at once rather than leaving it for the reaper.
  fm_build_lock_queue_leave
  fm_build_lock_release_slots
}

# Release runs from a trap rather than after the wrapped command, so a wrapper
# killed at any point still gives the lock back.
# shellcheck disable=SC2329 # Installed as the EXIT trap handler.
fm_build_lock_on_exit() {
  local status=$?
  fm_build_lock_release_now
  exit "$status"
}

# shellcheck disable=SC2329 # Installed as the INT/TERM/HUP trap handler.
fm_build_lock_on_signal() {  # <signal-name> <signal-number>
  local sig=$1 num=$2
  if [ -n "$FM_BUILD_LOCK_CHILD" ] && kill -0 "$FM_BUILD_LOCK_CHILD" 2>/dev/null; then
    kill -"$sig" "$FM_BUILD_LOCK_CHILD" 2>/dev/null || true
    return 0
  fi
  exit $((128 + num))
}

# --- argument handling ------------------------------------------------------

MODE=run
INSTALL_DIR=
LABEL=
SET_SLOTS=

while [ "$#" -gt 0 ]; do
  case "$1" in
    --)
      shift
      break
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --status)
      MODE=status
      shift
      [ "$#" -eq 0 ] || die "--status takes no further arguments"
      ;;
    --holders)
      MODE=holders
      shift
      [ "$#" -eq 0 ] || die "--holders takes no further arguments"
      ;;
    --lock-path)
      MODE='lock-path'
      shift
      [ "$#" -eq 0 ] || die "--lock-path takes no further arguments"
      ;;
    --slots-path)
      MODE='slots-path'
      shift
      [ "$#" -eq 0 ] || die "--slots-path takes no further arguments"
      ;;
    --set-slots)
      MODE='set-slots'
      shift
      [ "$#" -eq 1 ] || die "--set-slots takes exactly one count"
      SET_SLOTS=$1
      shift
      ;;
    --exclusive)
      FM_BUILD_LOCK_EXCLUSIVE_FLAG=1
      shift
      ;;
    --label)
      shift
      [ "$#" -gt 0 ] && [ -n "$1" ] || die "--label takes a non-empty text"
      LABEL=$1
      shift
      ;;
    --install-mutex)
      MODE=install
      shift
      [ "$#" -eq 1 ] || die "--install-mutex takes exactly one directory"
      INSTALL_DIR=$1
      shift
      ;;
    -*)
      die "unknown option '$1'; put '--' before a command that starts with a dash"
      ;;
    *)
      break
      ;;
  esac
done

if [ "$MODE" = run ] && [ "$#" -eq 0 ]; then
  usage >&2
  exit 2
fi

NOTICE_INTERVAL=${FM_BUILD_LOCK_NOTICE_INTERVAL:-60}
WAIT_WARN=${FM_BUILD_LOCK_WAIT_WARN:-600}
HOLD_WARN=${FM_BUILD_LOCK_HOLD_WARN:-1200}
POLL=${FM_BUILD_LOCK_POLL:-0.5}
TICKET_STALE=${FM_BUILD_LOCK_TICKET_STALE:-30}
fm_build_lock_positive_int FM_BUILD_LOCK_NOTICE_INTERVAL "$NOTICE_INTERVAL"
fm_build_lock_nonneg_int FM_BUILD_LOCK_WAIT_WARN "$WAIT_WARN"
fm_build_lock_nonneg_int FM_BUILD_LOCK_HOLD_WARN "$HOLD_WARN"
fm_build_lock_nonneg_int FM_BUILD_LOCK_TICKET_STALE "$TICKET_STALE"
case "$POLL" in
  ''|*[!0-9.]*|.|*.*.*) die "FM_BUILD_LOCK_POLL must be a number of seconds, got '$POLL'" ;;
esac

# --- CI stand-down, before the lock root is even resolved -------------------

if [ "$MODE" = run ] && fm_build_lock_is_ci; then
  exec "$@"
fi

# --- a command that takes the lock itself -----------------------------------
#
# firstmate ships runners that take a hold PER UNIT themselves - one per test
# script, one per concurrent phase - precisely so another worker's build goes
# between two units instead of waiting out the whole lane. Wrapping one of them
# here defeats exactly that: the outer hold spans the whole lane while every
# inner acquire passes straight through as a nested hold, which is the
# whole-lane hold measured in docs/verification/build-lock-contention.md.
#
# Prose forbade that wrap in four places - both runners' headers,
# CONTRIBUTING.md and the firstmate-coding-guidelines skill - and it still
# happened, because the ship
# brief's rule 8 tells a worker to wrap "a full CI script" and these are full
# CI scripts by any reading. The instruction was the defect, so the runtime
# decides it here rather than the caller: an invocation asked to wrap one of
# them takes no hold and runs it straight through, leaving the runner's own
# per-unit holds to keep the machine protected. Standing down is deliberately
# not a refusal; refusing would break a worker's validation run over a mistake
# the runtime can simply get right.

FM_BUILD_LOCK_SELF_LOCKING='fm-test-run.sh fm-stock-bash-lane.sh'

# Prints the recognised program's name, or fails. Wrappers whose next argument
# is the program itself are stepped over, so `bash bin/fm-test-run.sh` and
# `env FOO=1 ./bin/fm-test-run.sh` are recognised too. A `bash -c '<text>'`
# whose text merely mentions one is deliberately not recognised: that argument
# is a script, not a program name, and guessing inside it would be a parser.
fm_build_lock_self_locking_command() {
  local arg base name
  while [ "$#" -gt 0 ]; do
    arg=$1
    base=${arg##*/}
    case "$base" in
      env|time|nice|nohup|stdbuf|bash|sh|zsh|dash|ksh)
        shift
        while [ "$#" -gt 0 ]; do
          case "$1" in
            -*|*=*) shift ;;
            *) break ;;
          esac
        done
        continue
        ;;
    esac
    for name in $FM_BUILD_LOCK_SELF_LOCKING; do
      if [ "$base" = "$name" ]; then
        printf '%s\n' "$base"
        return 0
      fi
    done
    return 1
  done
  return 1
}

if [ "$MODE" = run ] && FM_BUILD_LOCK_SELF_NAME=$(fm_build_lock_self_locking_command "$@"); then
  note "$FM_BUILD_LOCK_SELF_NAME takes a build hold per unit itself, so this invocation takes none and runs it straight through; wrapping it would hold one slot for its whole run"
  [ "$FM_BUILD_LOCK_EXCLUSIVE_FLAG" = 0 ] \
    || note "--exclusive is ignored for a command that takes the lock itself"
  exec "$@"
fi

LOCK_ROOT=$(fm_build_lock_root)
[ -d "$LOCK_ROOT" ] || mkdir -p "$LOCK_ROOT" 2>/dev/null || die "lock directory is unavailable: $LOCK_ROOT"
[ -d "$LOCK_ROOT" ] && [ -w "$LOCK_ROOT" ] || die "lock directory is not writable: $LOCK_ROOT"
LOCK="$LOCK_ROOT/fm-build-lock"
INFO="$LOCK_ROOT/fm-build-lock.info"
QUEUE="$LOCK_ROOT/fm-build-lock.queue"
QLOCK="$LOCK_ROOT/fm-build-lock.queue.lock"

# The names deliberately do not start with `fm-build-lock`, so a reaper or a
# residue check that globs for lock artifacts keeps meaning "lock residue" and
# never sweeps up a machine's settings.
SETTINGS_DIR=$(fm_build_lock_settings_dir) || SETTINGS_DIR=
SLOTS_FILE=
EXCLUSIVE_FILE=
if [ -n "$SETTINGS_DIR" ]; then
  SLOTS_FILE="$SETTINGS_DIR/build-lock-slots"
  EXCLUSIVE_FILE="$SETTINGS_DIR/build-lock-exclusive"
fi

case "$MODE" in
  lock-path)
    printf '%s\n' "$LOCK"
    exit 0
    ;;
  slots-path)
    [ -n "$SLOTS_FILE" ] || die "cannot resolve this account's settings directory"
    printf '%s\n' "$SLOTS_FILE"
    exit 0
    ;;
  install)
    [ -d "$INSTALL_DIR" ] || die "not a directory: $INSTALL_DIR"
    [ -w "$INSTALL_DIR" ] || die "not writable: $INSTALL_DIR"
    TARGET="$INSTALL_DIR/mutex"
    if [ -e "$TARGET" ] && [ ! -L "$TARGET" ]; then
      die "refusing to replace the existing non-symlink $TARGET"
    fi
    ln -sfn "$SELF" "$TARGET" || die "could not link $TARGET"
    printf '%s -> %s\n' "$TARGET" "$SELF"
    exit 0
    ;;
esac

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

fm_build_lock_status_problem() {
  [ -n "$FM_BUILD_LOCK_SLOTS_PROBLEM" ] || return 0
  printf ' - %s' "$FM_BUILD_LOCK_SLOTS_PROBLEM"
}

# Nothing in this repository parses --status; its readers are people and agents.
# Every slot line reuses fm_build_lock_read_holder unchanged, including its
# "held by pid N (no command record)" answer.
fm_build_lock_print_status() {
  local n k highest held=0 last
  local -a slot_text slot_pid slot_state slot_display slot_secs
  fm_build_lock_read_slots
  n=$FM_BUILD_LOCK_SLOTS
  highest=$(fm_build_lock_highest_slot)
  [ "$highest" -ge "$n" ] 2>/dev/null || highest=$n
  if [ "$n" -le 1 ] && [ "$highest" -le 1 ]; then
    # One slot and nothing above it: today's output, from today's format string.
    fm_build_lock_read_holder "$LOCK" "$INFO"
    if [ -n "$FM_BUILD_LOCK_HOLDER_TEXT" ]; then
      printf '%s%s\n' "$FM_BUILD_LOCK_HOLDER_TEXT" "$(fm_build_lock_status_problem)"
    else
      printf 'free%s\n' "$(fm_build_lock_status_problem)"
    fi
    return 0
  fi
  k=1
  while [ "$k" -le "$highest" ]; do
    fm_build_lock_slot_paths "$k"
    fm_build_lock_read_holder "$FM_BUILD_LOCK_SLOT_PATH" "$FM_BUILD_LOCK_SLOT_INFO"
    slot_text[k]=$FM_BUILD_LOCK_HOLDER_TEXT
    slot_pid[k]=$FM_BUILD_LOCK_HOLDER_PID
    slot_state[k]=$FM_BUILD_LOCK_HOLDER_STATE
    slot_display[k]=$FM_BUILD_LOCK_HOLDER_DISPLAY
    slot_secs[k]=$FM_BUILD_LOCK_HOLDER_SECS
    [ -z "$FM_BUILD_LOCK_HOLDER_TEXT" ] || held=$((held + 1))
    k=$((k + 1))
  done
  # Still begins with `free` when nothing is held, so a reader looking for that
  # word finds it wherever the count happens to be set.
  if [ "$held" -eq 0 ]; then
    printf 'free - 0 of %s build slots held%s\n' "$n" "$(fm_build_lock_status_problem)"
  else
    fm_build_lock_queue_scan
    printf '%s of %s build slots held, %s waiting%s\n' \
      "$held" "$n" "$FM_BUILD_LOCK_QUEUE_COUNT" "$(fm_build_lock_status_problem)"
  fi
  k=1
  while [ "$k" -le "$highest" ]; do
    if [ -z "${slot_text[$k]}" ]; then
      printf 'slot %s: free\n' "$k"
      k=$((k + 1))
      continue
    fi
    if [ "${slot_state[$k]}" = reserved ]; then
      if [ -n "${slot_secs[$k]}" ]; then
        printf 'slot %s: reserved by pid %s for %s, draining for a whole-machine run: %s\n' \
          "$k" "${slot_pid[$k]}" "$(fm_build_lock_elapsed "${slot_secs[$k]}")" "${slot_display[$k]}"
      else
        printf 'slot %s: reserved by pid %s, draining for a whole-machine run: %s\n' \
          "$k" "${slot_pid[$k]}" "${slot_display[$k]}"
      fi
      k=$((k + 1))
      continue
    fi
    if [ "${slot_state[$k]}" = running ]; then
      # The slots one pid holds for one whole-machine run are one hold, so they
      # are reported as one rather than as several concurrent builds.
      last=$k
      while [ $((last + 1)) -le "$highest" ] \
        && [ "${slot_state[$((last + 1))]:-}" = running ] \
        && [ "${slot_pid[$((last + 1))]:-}" = "${slot_pid[$k]}" ]; do
        last=$((last + 1))
      done
      if [ "$last" -gt "$k" ]; then
        printf 'slots %s-%s: whole machine, %s\n' "$k" "$last" "${slot_text[$k]}"
      else
        printf 'slot %s: whole machine, %s\n' "$k" "${slot_text[$k]}"
      fi
      k=$((last + 1))
      continue
    fi
    if [ "$k" -gt "$n" ]; then
      printf 'slot %s: %s (above the configured count of %s; finishing, will not be refilled)\n' \
        "$k" "${slot_text[$k]}" "$n"
    else
      printf 'slot %s: %s\n' "$k" "${slot_text[$k]}"
    fi
    k=$((k + 1))
  done
}

# --- machine-readable holder list -------------------------------------------
#
# `--holders` is the ONE parseable view of the holder records above, added for
# firstmate's supervision side: it must decide whether a quiet worker still has
# a build or test run of its own in flight, and the prose `--status` lines are
# deliberately written for people, not parsers (see its header). One TAB-
# separated line per LIVE holder, nothing when none is held:
#
#   <pid>\t<held-seconds>\t<cwd>\t<command-or-label>
#
# The cwd is the holder's own `pwd -P` at acquisition, recovered from the same
# `<command> [in <cwd>]` display line `--status` prints, so a reader can
# attribute a hold to the worktree that took it. A record whose display carries
# no `[in <absolute path>]` suffix yields an empty cwd field rather than a
# guess, and a record with no usable start time yields an empty seconds field;
# neither is dropped, because a live hold a reader cannot attribute still
# matters more than a tidy table. No field contains a TAB: the command is
# rendered with newlines already flattened, and a TAB inside either field is
# stripped rather than allowed to split the line.
#
# Only holders whose process is still alive are listed, so a record a killed
# holder left behind is never reported as running work.
fm_build_lock_print_holders() {
  local k highest pid secs display cwd cmd
  fm_build_lock_read_slots
  highest=$(fm_build_lock_highest_slot)
  [ "$highest" -ge "$FM_BUILD_LOCK_SLOTS" ] 2>/dev/null || highest=$FM_BUILD_LOCK_SLOTS
  k=1
  while [ "$k" -le "$highest" ]; do
    fm_build_lock_slot_paths "$k"
    fm_build_lock_read_holder "$FM_BUILD_LOCK_SLOT_PATH" "$FM_BUILD_LOCK_SLOT_INFO"
    pid=$FM_BUILD_LOCK_HOLDER_PID
    secs=$FM_BUILD_LOCK_HOLDER_SECS
    display=$FM_BUILD_LOCK_HOLDER_DISPLAY
    k=$((k + 1))
    [ -n "$FM_BUILD_LOCK_HOLDER_TEXT" ] || continue
    case "$pid" in ''|*[!0-9]*) continue ;; esac
    fm_pid_alive "$pid" || continue
    case "$secs" in *[!0-9]*) secs= ;; esac
    case "$display" in
      *' [in /'*']')
        cwd=${display##*' [in '}
        cwd=${cwd%]}
        cmd=${display%' [in '*}
        ;;
      *)
        cwd=
        cmd=$display
        ;;
    esac
    printf '%s\t%s\t%s\t%s\n' "$pid" "$secs" \
      "$(printf '%s' "$cwd" | tr -d '\t')" "$(printf '%s' "$cmd" | tr -d '\t')"
  done
}

case "$MODE" in
  status)
    fm_build_lock_print_status
    exit 0
    ;;
  holders)
    fm_build_lock_print_holders
    exit 0
    ;;
  set-slots)
    case "$SET_SLOTS" in
      ''|*[!0-9]*) die "--set-slots takes a whole number of slots, got '$SET_SLOTS'" ;;
    esac
    [ "$SET_SLOTS" -gt 0 ] 2>/dev/null \
      || die "--set-slots must be greater than zero, got '$SET_SLOTS'"
    [ -n "$SLOTS_FILE" ] || die "cannot resolve this account's settings directory"
    mkdir -p "$SETTINGS_DIR" 2>/dev/null \
      || die "settings directory is unavailable: $SETTINGS_DIR"
    SET_SLOTS_TMP="$SLOTS_FILE.$$.tmp"
    # Through a temporary file and a rename: waiters re-read this file on every
    # poll, and a plain truncate-and-write would let one catch it empty for an
    # instant and report a count that was never written.
    if ! printf '%s\n' "$SET_SLOTS" > "$SET_SLOTS_TMP" 2>/dev/null \
      || ! mv -f -- "$SET_SLOTS_TMP" "$SLOTS_FILE" 2>/dev/null; then
      rm -f -- "$SET_SLOTS_TMP" 2>/dev/null || true
      die "could not write the slot count: $SLOTS_FILE"
    fi
    fm_build_lock_print_status
    exit 0
    ;;
esac

# --- nested inside a hold ---------------------------------------------------

# Deliberately not bounded by the current count: N can be lowered in the middle
# of a hold, and that hold is still a hold. An invocation nested inside a slot-2
# hold that only recognised slot 1 would queue for a second slot while its own
# ancestor waits on it, taking two slots for one run at best.
fm_build_lock_nested_passthrough() {
  local held=${FM_BUILD_LOCK_HELD_LOCK:-}
  case "${FM_BUILD_LOCK_HELD_BY:-}" in
    ''|*[!0-9]*) return 1 ;;
  esac
  fm_build_lock_slot_index "$held" >/dev/null || return 1
  [ "$(cat "$held/pid" 2>/dev/null || true)" = "$FM_BUILD_LOCK_HELD_BY" ] || return 1
  fm_pid_alive "$FM_BUILD_LOCK_HELD_BY"
}

# A slot's recorded owner being a live ancestor of this process also means we
# are inside its hold, whichever entry point or version took it. The ancestor
# walk runs at most once and is skipped entirely when no slot is held.
fm_build_lock_owner_is_ancestor() {
  local owners='' entry suffix owner walk=$$ depth=0
  for entry in "$LOCK" "$LOCK".slot*; do
    if [ "$entry" != "$LOCK" ]; then
      suffix=${entry#"$LOCK".slot}
      case "$suffix" in
        ''|*[!0-9]*) continue ;;
      esac
    fi
    [ -e "$entry" ] || [ -L "$entry" ] || continue
    owner=$(cat "$entry/pid" 2>/dev/null || true)
    case "$owner" in ''|*[!0-9]*) continue ;; esac
    fm_pid_alive "$owner" || continue
    owners="$owners $owner"
  done
  [ -n "$owners" ] || return 1
  while [ "$depth" -lt 64 ]; do
    walk=$(ps -o ppid= -p "$walk" 2>/dev/null | tr -d ' ')
    case "$walk" in ''|*[!0-9]*|0|1) return 1 ;; esac
    case "$owners " in
      *" $walk "*) return 0 ;;
    esac
    depth=$((depth + 1))
  done
  return 1
}

if fm_build_lock_nested_passthrough || fm_build_lock_owner_is_ancestor; then
  # --exclusive cannot widen an ancestor's hold, and waiting for the rest of the
  # machine here would be waiting on that ancestor.
  [ "$FM_BUILD_LOCK_EXCLUSIVE_FLAG" = 0 ] \
    || note "already inside a build hold, so --exclusive is ignored and this runs straight through"
  exec "$@"
fi

# --- acquire, run, release --------------------------------------------------

trap fm_build_lock_on_exit EXIT
trap 'fm_build_lock_on_signal TERM 15' TERM
trap 'fm_build_lock_on_signal INT 2' INT
trap 'fm_build_lock_on_signal HUP 1' HUP

# Rendered before the acquire so publishing the holder record costs one write
# and nothing else: every fork left inside that window is time a waiter can
# spend looking at a lock whose command is not published yet.
if [ -n "$LABEL" ]; then
  DISPLAY_LINE="$(printf '%s' "$LABEL" | tr '\n\r' '  ') [in $(pwd -P)]"
else
  DISPLAY_LINE="$(fm_build_lock_render_command "$@") [in $(pwd -P)]"
fi

fm_build_lock_acquire

STARTED=$(date +%s)
HELD_SINCE=$SECONDS

fm_build_lock_publish_holder "$STARTED"
fm_build_lock_slot_paths "$(fm_build_lock_lowest_held_slot)"

# An explicit stdin redirection is required: bash sends an asynchronous
# command's stdin to /dev/null when job control is off, which would silently
# starve any wrapped command that reads input. Job control being off is also why
# the child stays in this process group, so a terminal interrupt still reaches
# it directly.
FM_BUILD_LOCK_HELD_BY=$$ FM_BUILD_LOCK_HELD_LOCK=$FM_BUILD_LOCK_SLOT_PATH "$@" <&0 &
FM_BUILD_LOCK_CHILD=$!

# SECONDS is bash's own wall clock, so the ceiling costs no fork per tick.
NEXT_HOLD_WARN=$HOLD_WARN
HELD_REPORTED=0
while kill -0 "$FM_BUILD_LOCK_CHILD" 2>/dev/null; do
  sleep "$POLL"
  [ "$HOLD_WARN" -gt 0 ] || continue
  HELD=$((SECONDS - HELD_SINCE))
  [ "$HELD" -ge "$NEXT_HOLD_WARN" ] || continue
  NEXT_HOLD_WARN=$((HELD + HOLD_WARN))
  fm_build_lock_report_ceiling "$HELD" "$DISPLAY_LINE"
  if [ "$HELD_REPORTED" = 0 ]; then
    HELD_REPORTED=1
    fm_build_lock_queue_scan
    if [ "$FM_BUILD_LOCK_MULTI" = 1 ]; then
      fm_build_lock_task_status "note: holding $(fm_build_lock_held_slot_count) of $FM_BUILD_LOCK_N machine-wide build slots for $(fm_build_lock_elapsed "$HELD") with $FM_BUILD_LOCK_QUEUE_COUNT waiting, past the ${HOLD_WARN}s ceiling; not being killed: $DISPLAY_LINE"
    else
      fm_build_lock_task_status "note: holding the machine-wide build lock for $(fm_build_lock_elapsed "$HELD") with $FM_BUILD_LOCK_QUEUE_COUNT waiting, past the ${HOLD_WARN}s ceiling; not being killed: $DISPLAY_LINE"
    fi
  fi
done

# The loop leaves only after the child is gone; wait then reports the status
# bash recorded for it, including 128+signal when it was killed.
wait "$FM_BUILD_LOCK_CHILD"
STATUS=$?
FM_BUILD_LOCK_CHILD=

exit "$STATUS"
