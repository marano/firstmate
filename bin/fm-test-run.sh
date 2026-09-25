#!/usr/bin/env bash
# fm-test-run.sh - single owner of Firstmate's behavior-test runner, lane
# composition for portable CI shards, local --jobs for proven-concurrent work,
# timing markers, and the complete-regression coverage guard.
#
# Selection modes (exactly one of: --all, --family, --changed, --lane,
# --proven-isolated, or script paths):
#   fm-test-run.sh --all
#   fm-test-run.sh --family <name>
#   fm-test-run.sh --changed [--base <git-ref>]
#   fm-test-run.sh --lane portable-parallel-1|portable-parallel-2|portable-parallel-3|portable-serial
#   fm-test-run.sh --lane portable-serial-<k>of<n>   (one CI serial shard)
#   fm-test-run.sh --lane stock-bash                (the stock-Bash 3.2 lane)
#   fm-test-run.sh --lane stock-bash-<k>of<n>       (one CI stock-Bash shard)
#   fm-test-run.sh --proven-isolated
#   fm-test-run.sh tests/<name>.test.sh [more scripts...]
#
# Inspection (no execution):
#   fm-test-run.sh --list --all
#   fm-test-run.sh --list --family <name>
#   fm-test-run.sh --list --lane portable-parallel-1
#   fm-test-run.sh --list-scheduled --family <name>
#   fm-test-run.sh --list-scheduled --lane portable-parallel-1
#   fm-test-run.sh --list-families
#   fm-test-run.sh --list-concurrent-safe-families
#   fm-test-run.sh --concurrent-safe-family-jobs-max <name>
#   fm-test-run.sh --list-lanes
#   fm-test-run.sh --list-required-tools --lane portable-parallel-1
#   fm-test-run.sh --list-stock-bash-exclusions
#   fm-test-run.sh --check-coverage
#
# Aggregation (no suite execution):
#   fm-test-run.sh --aggregate-json <out.json> <lane.json> [more lane.json...]
#
# Serial shard hints (no suite execution; inputs are lane or aggregate timing
# JSON, ideally from several green main runs; docs/fm-test-portable-shards.md):
#   fm-test-run.sh --derive-serial-hints <timing.json...>
#                   print the slowest completed duration per portable-serial
#                   script, as the hint table's "<path> <ms>" lines.
#   fm-test-run.sh --refresh-serial-hints <timing.json...>
#                   rewrite portable_serial_weight_hints in this file from them.
#   fm-test-run.sh --check-lane-timing <timing.json...>
#                   judge a completed portable-serial run against the two bounds
#                   a re-pack does not move: no shard may measure more than
#                   PORTABLE_SERIAL_MEASURED_SHARD_MAX_MS, and the lane may not
#                   measure more than PORTABLE_SERIAL_LANE_UNDERPREDICT_PERCENT
#                   above its packed weight. Refuses an input missing a shard.
#                   Per-script hint gaps are reported, never gated: see the
#                   comment on the measured-shard bound for why. CI runs it on
#                   every push and pull request.
#                   FM_PORTABLE_SERIAL_HINTS_FILE replaces the table (tests).
#
# Exclusion proof (no suite execution; inputs are lane or aggregate timing JSON):
#   fm-test-run.sh --check-exclusions [--exclude-family <name>...] [--exclude-script <path>...] <timing.json...>
#                   (with neither flag it proves the built-in default exclusions)
#                   prove, from what the run itself recorded and not from the
#                   workflow text, that (1) no script of an excluded family or
#                   named as an excluded script executed and (2) every other
#                   script did,
#                   each named on failure. Records from the stock-bash lane are
#                   ignored: it selects its own subset and keeps its own set.
#                   CI runs it in the aggregate job with no flags, proving the
#                   built-in default exclusions.
#
# Options:
#   --json <path>   write a deterministic timing artifact after the run. Each
#                   script record carries its family, expected gate-skip class,
#                   exit, duration, whether it gate-skipped, and the reason it
#                   gave (empty when it ran), so a lane can say which harness or
#                   tool this host could not exercise.
#   --list          print selected script paths (one per line) and exit 0
#   --list-required-tools
#                   print the pinned external linters the CURRENT selection
#                   needs, sorted and deduplicated, one per line, and exit 0.
#                   Nothing is printed when the selection needs none. Each CI
#                   lane job installs exactly this answer for its own lane
#                   (bin/fm-install-pinned-tools.sh), so no workflow file keeps
#                   a per-job tool matrix that can rot away from lane
#                   membership. script_required_tools below owns which test
#                   needs which tool; FM_TEST_REQUIRED_TOOLS_FILE replaces that
#                   table (tests).
#   --list-scheduled
#                   print selected paths longest-hint-first and exit 0.
#                   Only --lane portable-parallel-1, portable-parallel-2, or
#                   portable-parallel-3 uses parallel hints, falling back to
#                   serial weights if missing.
#                   Every other selection uses serial weights alone.
#                   Equal weights are ordered by path under LC_ALL=C.
#   --base <ref>    with --changed, compare against this ref (default: origin/main)
#   --exclude-family <name>
#                   drop scripts whose primary family matches <name> after selection
#                   (repeatable; portable CI lanes exclude real-herdr-gated so the
#                   dedicated required Herdr lane owns that coverage)
#   --exclude-script <path>
#                   drop this one script after selection (repeatable). The path
#                   must name an existing tests/*.test.* script; a typo is refused.
#   --include-excluded
#                   run the tests this home does not spend time on by default
#                   (--list-default-exclusions names them and why). Without it
#                   --all, --lane, --proven-isolated and --changed leave them out,
#                   locally and in CI alike; naming a script path or --family
#                   explicitly always runs it. Example, to bring Orca back:
#                     bin/fm-test-run.sh tests/fm-backend-orca.test.sh
#                   or the whole default selection plus everything excluded:
#                     bin/fm-test-run.sh --all --include-excluded
#                   FM_TEST_INCLUDE_EXCLUDED=1 in the environment does the same.
#   --list-default-exclusions
#                   print every default exclusion as <family:name|path><TAB><reason>
#   --require-ok-count <script>=<count>
#                   fail the run unless <script> printed exactly <count> lines
#                   starting "ok - " (repeatable). Exit status alone cannot see a
#                   script that stops printing cases while still exiting 0, so a
#                   lane that cares about a script's case count pins it here
#                   instead of re-running that script under a separate shell
#                   loop. A pinned script that gate-skips fails too: a skip is
#                   not the count that was pinned.
#   --fail-on-gate-skip <token>
#                   after each script, fail the run if any output line contains
#                   "skip: <token>" (e.g. --fail-on-gate-skip 'herdr not found').
#                   The required Herdr CI lane uses this so a missing pin cannot
#                   silently pass as a gate skip.
#   --jobs N        run the selected scripts with up to N concurrent workers.
#                   Plain --changed and a plain list of script paths use
#                   min(4, cpus) workers when multiple selected scripts are
#                   admissible; --lane, --family, and --all stay serial unless
#                   asked for concurrency explicitly.
#                   N>1 is allowed only when every selected script is proven
#                   safe to run concurrently: individually in the proven-isolated
#                   set (bin/fm-test-isolation-proof.sh --list), or in a family
#                   carrying a recorded concurrent proof
#                   (list_concurrent_safe_families below). Overall cap is 8;
#                   family proofs may impose a lower cap. Individually proven
#                   scripts share one phase; scripts admitted only by a family
#                   proof run in a separate phase for each family. Concurrent
#                   phases use serial weights, longest-hint-first. Unproven stateful
#                   scripts run serially after all concurrent phases. Default is
#                   1 (serial) except for plain --changed and a plain list of
#                   script paths, which use the bounded automatic scheduler.
#   --per-script-timeout-secs N
#                   terminate a script that runs longer than N seconds, record
#                   it as exit 124, print a `not ok` line naming the script and
#                   the bound it exceeded, and go on to the remaining scripts.
#                   Every executing mode defaults to
#                   DEFAULT_PER_SCRIPT_TIMEOUT_SECS below when this is not
#                   given, so a stalled script is a named, bounded failure
#                   rather than a silent unbounded run. 0 disables the bound;
#                   the CI lanes pass it explicitly because their job caps are
#                   their hang tripwire. --max-wall-ms is checked
#                   after the run and so cannot catch a hang on its own.
#                   External interruption cleanup is outside this runner's
#                   guarantee; configured per-script bounds remain authoritative.
#   --max-wall-ms N fail the run when its measured invocation wall clock, less
#                   time spent waiting for the build lock, exceeds
#                   N milliseconds, including an empty selection. It is
#                   evaluated after selection and suite execution and cannot
#                   interrupt a running script; per-script hangs are
#                   bounded by --per-script-timeout-secs. Pathological output
#                   sinks that block finalization are explicitly out of scope.
#   -h, --help      print this header
#
# Per-script machine-parseable markers (stdout):
#   FM_TEST_BEGIN <iso8601> <script> family=<family> expected_gate_skip=<class>
#   FM_TEST_END <iso8601> <script> exit=<code> duration_ms=<n> gate_skip=<true|false>
#
# After all scripts (stdout):
#   FM_TEST_SUMMARY total=<n> failed=<n> skipped_gate=<n> duration_ms=<n>
#   FM_TEST_SUMMARY_FAMILY family=<name> count=<n> duration_ms=<n> failed=<n>
#   FM_TEST_SLOWEST rank=<k> script=<path> duration_ms=<n>
#   FM_TEST_BUDGET max_wall_ms=<n> duration_ms=<n> [lock_wait_ms=<n>]
#                   (only with --max-wall-ms; duration_ms excludes lock_wait_ms,
#                   the time spent in line for the build lock)
#
# Build lock:
#   Every executing mode runs each script under bin/fm-build-lock.sh, one hold
#   per serial script, or one hold for a whole concurrent phase. Other workers'
#   builds can go between serial scripts and between concurrent phases, not
#   inside a concurrent phase. Do not wrap this runner in `mutex`: that holds
#   the lock around the whole loop, the pattern measured in
#   docs/verification/build-lock-contention.md. Lock waits are excluded from
#   script durations and per-script bounds; see build_lock_hold below.
#
# Placement refusal:
#   A task worker is assigned an isolated worktree, and that placement is
#   checked only when its task starts. When FM_TASK_ID marks such a worker and
#   this runner resolves to the repository's PRIMARY checkout, every executing
#   mode refuses before selecting a suite: the suite creates and switches
#   branches, and the primary is the checkout every linked worktree resolves
#   against. Inspection modes execute nothing and stay available, and a run with
#   no FM_TASK_ID set is unchanged.
#
# Worker environment:
#   Each script starts without the task-worker session environment (FM_TASK_ID,
#   FM_TASK_STATUS, TMUX, TMUX_PANE), so a suite run from inside a worker takes
#   its verdict from its own fixtures. tests/worker-env-helpers.sh owns the list.
#   The runner itself keeps them: the placement refusal and the build-lock
#   ceiling lines read them.
#
# A script that skipped a case for a missing pinned external tool prints
# tests/lib.sh's FM_TEST_TOOL_MISSING marker. Where those tools are supposed to
# be installed - CI, or FM_TEST_REQUIRE_DECLARED_TOOLS=1 - the run fails naming
# the script and the tool, whether script_required_tools promised that tool and
# the install did not deliver it, or the table never named it at all. Locally
# the marker is inert, so a contributor with no pinned linter still gets the
# ordinary suite result.
#
# Exit status is non-zero if any selected script exits non-zero, a selected
# script exits 0 having run no case (no line starting "ok - " and no line
# starting "skip:"), a configured --fail-on-gate-skip token appears, a selected
# script reported a missing pinned tool while those are required, the measured
# duration exceeds --max-wall-ms, timing-artifact finalization fails, or a
# concurrent worker violates its isolation check. Other gate skips (first
# meaningful line matching ^skip:) remain successful and are counted as
# skipped_gate; each one is logged with its reason and recorded in the timing
# artifact.
#
# expected_gate_skip classes name why a family is allowed to skip: herdr (the
# pinned real-Herdr lane), optional-binary (a backend whose binary is optional),
# live-capability (a live-harness guard governed by fm_live_gate, which records
# unavailable tools and explicit policy skips; see tests/lib.sh), or none.
#
# Every selected script runs isolated from the host's global and system Git
# configuration, including one that sources no test helper of its own;
# tests/git-config-helpers.sh owns that contract and its limits.
#
# Family labels, the changed-file map, and production portable-shard composition
# live in this script only (one owner). The proven-isolated candidate set remains
# owned by bin/fm-test-isolation-proof.sh; portable parallel shards are a
# duration-balanced partition of that exact set, packed from the measured hints
# in portable_parallel_weight_hints (see docs/fm-test-portable-shards.md).
# --check-coverage reports parallel_max_ms (the larger lane hint sum),
# parallel_imbalance_ms (the absolute difference between the sums), and
# parallel_unhinted (the number of members missing a parallel hint).
# These sums exclude unhinted members and are estimates, not measured job wall
# times. Missing parallel hints are reported without failing this guard.
# It also reports stock_bash (how many tests the stock-bash lane selects) and
# stock_bash_excluded (how many the exclusion table names), and refuses an
# exclusion that names a missing test, carries no admissible reason, or claims a
# cost at or under STOCK_BASH_MAX_SCRIPT_MS. The stock-bash lane's CI shards
# (stock-bash-<k>of<n>) are packed the same way as the serial shards below, from
# the measured macOS medians in stock_bash_weight_hints, and this script owns
# their <n> the same way. The guard refuses unless those shards partition the
# lane exactly and every script bin/fm-stock-bash-lane.sh --ok-count-pins names
# lands in exactly one shard, and reports stock_bash_shards, stock_bash_max_ms
# (the heaviest shard's packed weight) and stock_bash_unhinted.
#
# portable-serial stays strictly serial. Its CI shards (portable-serial-<k>of<n>)
# split it across separate runners, so two of its stateful scripts still never
# share a machine. This script owns <n>: a lane whose <n> disagrees with the
# configured shard count is refused, so a CI matrix cannot silently drop a shard.
# --check-coverage also reports serial_max_ms (the heaviest shard's packed
# weight) against serial_shard_budget_ms and refuses past it, so a shard growing
# toward its CI job cap reds the guard rather than timing out mid-lane.
# --changed is conservative: it over-selects related families rather than
# under-selecting, and never expands to the complete suite unless --all. The one
# place it is deliberately narrow is a bin/ path with no curated family: a test
# that names it is selected as that SCRIPT, because the reference is per-script
# evidence. Consumer bin/ scripts still resolve through the curated map, so
# recorded family-level coupling still expands to the whole family.
# tests/lib.sh, tests/fixtures.sh, tests/*-helpers.sh and tests/*-fixture.sh are
# shared files that map to the suites naming them; a fixture under
# tests/fixtures/<dir>/ is mapped by that directory instead. Curated family arms
# above those also name individual tests/ files explicitly.
set -eu

now_ms() {
  if command -v python3 >/dev/null 2>&1; then
    python3 -c 'import time; print(int(time.time() * 1000))'
  else
    echo $(($(date +%s) * 1000))
  fi
}

RUN_STARTED_ISO=$(date -u +%Y-%m-%dT%H:%M:%SZ)
RUN_STARTED_MS=$(now_ms)

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 1

MODE=
LIST_ONLY=0
LIST_REQUIRED_TOOLS=0
LIST_SCHEDULED=0
LIST_FAMILIES=0
LIST_CONCURRENT_SAFE_FAMILIES=0
LIST_LANES=0
CHECK_COVERAGE=0
AGGREGATE_OUT=
FAMILY=
LANE=
BASE_REF=origin/main
JSON_PATH=
SCRIPTS=()
EXCLUDE_FAMILIES=()
EXCLUDE_SCRIPTS=()
INCLUDE_EXCLUDED=${FM_TEST_INCLUDE_EXCLUDED:-0}
FAIL_ON_GATE_SKIP=
REQUIRE_OK_COUNTS=()
JOBS=1
JOBS_EXPLICIT=0
JOBS_MAX=8
MAX_WALL_MS=
PER_SCRIPT_TIMEOUT_SECS=
PER_SCRIPT_TIMEOUT_GIVEN=0
# Bound applied to every executing mode whose caller names none, derived from
# measured healthy runtimes with margin rather than picked. The slowest behavior
# script was tests/fm-watch-triage.test.sh (since split into
# tests/fm-watch-triage-*.test.sh, whose total is unchanged): 588-723s across 28
# CI serial runs on 2026-09-19, and 788s on a loaded local machine. 1800s leaves more than 2x
# headroom over that, so it cannot red-flag a healthy slow script, and it still
# ends a stall that would otherwise run until someone notices - a blocked exec
# once sat at 0% CPU for 18 minutes with nothing on its output. It is a guard,
# not a speed control: a HUNG script becomes a bounded, named failure instead
# of an unbounded suite, which is the shape that silently outruns a caller's
# invocation budget.
#
# Who reaches this default: local and CI runs that name no bound get 1800s. The
# CI portable-parallel, portable-serial and real-herdr lanes pass an explicit 0
# because their job caps are their hang tripwire. The macOS stock-bash lane
# passes its own bound in bin/fm-stock-bash-lane.sh.
DEFAULT_PER_SCRIPT_TIMEOUT_SECS=1800

# Whether a script that skipped a case for a missing pinned tool reds the run.
# On by default wherever CI sets CI=true, because there the tools are installed
# from script_required_tools below and a marker therefore means the table and
# the installed set disagree - the rot this whole mechanism exists to catch. Off
# by default locally, where a contributor with no pinned linter installed must
# still get the ordinary suite result rather than a red for a tool they never
# asked for. FM_TEST_REQUIRE_DECLARED_TOOLS=1 or 0 forces either way.
REQUIRE_DECLARED_TOOLS=0
case "${FM_TEST_REQUIRE_DECLARED_TOOLS:-}" in
  1) REQUIRE_DECLARED_TOOLS=1 ;;
  0) ;;
  '') [ "${CI:-}" != true ] || REQUIRE_DECLARED_TOOLS=1 ;;
esac

# How many separate-runner shards the portable serial remainder splits into.
# One owner: CI lane names carry this count and are refused when they disagree.
PORTABLE_SERIAL_SHARDS=5

# Balance hint for a portable-serial script with no measured duration, close to
# the measured per-script mean so a newly added test neither starves nor
# overloads the shard it lands in.
PORTABLE_SERIAL_DEFAULT_WEIGHT_MS=27000

# Largest share of the serial lane allowed to run on the default weight above.
# Hints are what keep the shards balanced, so once too much of the lane is
# unmeasured the balance is guesswork and one shard can reach its CI job cap
# while another sits idle. The coverage guard refuses past this share, which
# leaves room for newly added tests while making a stale hint table fail loudly
# instead of silently. docs/fm-test-portable-shards.md owns the refresh.
PORTABLE_SERIAL_MAX_UNHINTED_PERCENT=15

# Largest packed weight any single portable-serial shard may carry, in
# milliseconds. The unhinted bound above only catches a MISSING hint; a hint
# that is merely stale keeps the partition looking balanced while one shard
# grows into its CI job cap, which is how the lane reached that cap twice.
# This bounds the packed weight itself, so growth reds the seconds-long
# coverage guard instead of a 30-minute shard timeout.
# Derived from the job cap in .github/workflows/ci.yml, which owns that number:
# a shard measured at 25.2 minutes of script time was killed at 30m15s, so a
# slow runner costs about 20% over the packed weight. 30 minutes divided by
# that 1.2 factor leaves 25 minutes, minus the measured ~0.25 minutes of job
# setup, rounded down to 24 for margin. Re-shard when this trips; raising it
# spends the hang-tripwire margin the cap exists to keep.
PORTABLE_SERIAL_MAX_SHARD_MS=1440000

# Largest MEASURED total any single portable-serial shard may reach, in
# milliseconds. This is the same risk PORTABLE_SERIAL_MAX_SHARD_MS bounds, read
# off what actually happened instead of off the hints: the packed weight
# under-predicted the measured shard total by up to 24%, so a shard could run
# 120s past its own packed budget and the coverage guard could not see it.
# This is a TRIPWIRE in front of the hard 30-minute job cap in
# .github/workflows/ci.yml (which owns that number), not a planning budget:
# PORTABLE_SERIAL_MAX_SHARD_MS above is the budget and is answered by
# re-sharding. A tripwire must sit above observed-healthy and below the hard
# limit, or it is a permanent alarm rather than a warning.
# Observed healthy: on the packing in force the heaviest shard measured 1305s
# and 1363s on main pushes and 1416s on a pull-request run; the highest on any
# observed packing is 1567s, on a green run. The cap is 1800s of wall clock;
# job setup outside the lane run measured 15-21s across the five shards of one
# run, and allowing 60s leaves 1740s for the lane itself. 1650s sits 5.3% above
# the highest healthy measurement and 5.2% below that budget, so it cannot fire
# on a healthy shard and still names one with about 90s of lane time and 150s
# of job time in hand rather than letting the job be killed with no verdict.
# A shard at 1567s is 87% of the cap; that margin is tracked separately as
# fm-serial-shard5-near-job-cap. When this trips, the answer is still
# re-sharding, not raising it.
PORTABLE_SERIAL_MEASURED_SHARD_MAX_MS=1650000

# Largest share by which the lane's MEASURED total may exceed its packed weight
# before the hint table counts as rotted. Both sides are recomputed from the
# scripts the run actually reported, so removing or adding tests moves them
# together and neither needs re-deriving when the set changes.
# This is the bound the per-script comparison below cannot be: a script's
# measured duration is not a property of the script. A re-pack that changed no
# test file moved one script from 43663ms to 104844ms and another from 74942ms
# to 20282ms, while the lane's measured total stayed between 5860s and 6314s
# across both packings, so the total is what survives a re-pack and the
# per-script number is not.
PORTABLE_SERIAL_LANE_UNDERPREDICT_PERCENT=10

# Band for REPORTING a per-script hint gap. Not a gate: after a re-pack such a
# gap is attribution moving between scripts, not cost changing. Under a fixed
# packing a script's duration is stable - across nine consecutive green runs the
# spread of the 105 scripts over 5s had a median of 17% and a 90th percentile of
# 34% - so this band names the gaps worth a human's attention without pretending
# they are defects.
PORTABLE_SERIAL_HINT_DRIFT_PERCENT=50
PORTABLE_SERIAL_HINT_DRIFT_FLOOR_MS=30000

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0" >&2
}

die() {
  printf 'fm-test-run: %s\n' "$*" >&2
  exit 2
}

log() {
  printf 'fm-test-run: %s\n' "$*" >&2
}

now_iso() {
  date -u +%Y-%m-%dT%H:%M:%SZ
}

# Enforce the placement refusal described in this script's header.
#
# The primary checkout is the working tree whose own git dir IS the repository's
# common git dir; every linked worktree has a git dir under it instead. That is
# the same predicate bin/fm-spawn.sh uses to keep a launch out of the primary,
# and unlike comparing top-level paths it still holds when the primary is
# reached through a different path. When git resolves neither directory - a
# non-repository fixture, a detached copy - nothing proves this is the primary,
# so the run proceeds.
refuse_primary_checkout_for_task() {
  local task_id git_dir common_dir top
  task_id=${FM_TASK_ID:-}
  [ -n "$task_id" ] || return 0
  git_dir=$(git -C "$ROOT" rev-parse --absolute-git-dir 2>/dev/null) \
    && git_dir=$(cd "$git_dir" 2>/dev/null && pwd -P) || git_dir=
  common_dir=$(git -C "$ROOT" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) \
    && common_dir=$(cd "$common_dir" 2>/dev/null && pwd -P) || common_dir=
  [ -n "$git_dir" ] && [ -n "$common_dir" ] || return 0
  [ "$git_dir" = "$common_dir" ] || return 0
  top=$(cd "$ROOT" && pwd -P)
  die "refusing to run in the repository primary checkout $top while FM_TASK_ID=$task_id is set; run from the assigned task worktree instead"
}

cpu_count() {
  local n
  n=$(getconf _NPROCESSORS_ONLN 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 1)
  case "$n" in
    ''|*[!0-9]*) n=1 ;;
  esac
  [ "$n" -ge 1 ] || n=1
  printf '%s\n' "$n"
}

# Primary family for one tests/*.test.sh basename. Unmapped scripts are
# unclassified so new tests are still runnable and visible in summaries.
#
# `standalone` is the residual family: scripts that belong to no subsystem
# family above but each own their own surface. Its membership is enumerated
# rather than inherited from the `*)` catch-all precisely because the catch-all
# also swallows every test nobody has classified yet. Keeping the two separate
# is what lets `standalone` carry a concurrent proof while a brand-new test
# lands in `unclassified` and stays serial until someone proves it.
family_for_basename() {
  case "$1" in
    fm-arm-pretool-check.test.sh|fm-ask-user-authority.test.sh|\
    fm-bearings-board.test.sh|\
    fm-brief.test.sh|fm-vendor-auth-probe.test.sh|\
    fm-calm-pi-extension.test.sh|fm-cd-pretool-check.test.sh|\
    fm-classify-decision-key.test.sh|\
    fm-composer-ghost.test.sh|fm-composer-lib.test.sh|\
    fm-crew-state.test.sh|fm-captain-hold-lifecycle.test.sh|\
    fm-documentation-audiences.test.sh|fm-ensure-agents-md.test.sh|fm-grok-harness.test.sh|\
    fm-harness-precedence.test.sh|\
    fm-kimi-harness.test.sh|fm-muse-harness.test.sh|fm-rovo-harness.test.sh|fm-agy-harness.test.sh|fm-omp-harness.test.sh|fm-herdr-lab.test.sh|fm-lint.test.sh|\
    fm-lint-workflows.test.sh|\
    fm-operational-input.test.sh|fm-pi-primary-types.test.sh|\
    fm-harness-adapter-references.test.sh|\
    fm-send-popup-settle.test.sh|fm-send-settle.test.sh|\
    fm-subagent-pretool-check.test.sh|\
    fm-supervision-instructions.test.sh|fm-task-delivery.test.sh|\
    fm-tmux-submit-busy.test.sh|fm-trace-context-lib.test.sh|\
    fm-transition-lib.test.sh|\
    fm-test-run.test.sh|fm-test-isolation-proof.test.sh)
      printf '%s\n' pure-contract-unit
      ;;
    fm-daemon.test.sh|fm-guard-stale-banner.test.sh|fm-pi-watch-extension.test.sh|\
    fm-session-lock-ancestry.test.sh|fm-cursor-primary.test.sh|\
    fm-supervision-events.test.sh|fm-turnend-guard.test.sh|fm-wake-daemon-lifecycle-e2e.test.sh|\
    fm-wake-drain-unread-status.test.sh|\
    fm-tool-update-check.test.sh|\
    fm-mail.test.sh|fm-mail-check.test.sh|\
    fm-wake-queue.test.sh|fm-watch-arm.test.sh|fm-watch-checkpoint.test.sh|fm-watch-recovery-loop.test.sh|\
    fm-watch-triage-absorb.test.sh|fm-watch-triage-stale.test.sh|fm-watch-triage-declared.test.sh|fm-watch-triage-busy.test.sh|fm-task-inbox.test.sh|\
    fm-watcher-lock.test.sh|fm-inactive-reconcile.test.sh|fm-supervision-alert.test.sh)
      printf '%s\n' watcher-wake-lock
      ;;
    fm-afk-inject-herdr-e2e.test.sh|fm-afk-launch.test.sh|fm-backend-autodetect-smoke.test.sh|\
    fm-backend-herdr-eventwait-smoke.test.sh|fm-backend-herdr-presentation-e2e.test.sh|\
    fm-backend-herdr-launcher-workspace-e2e.test.sh|\
    fm-backend-herdr-prune-safety-e2e.test.sh|fm-backend-herdr-respawn-idem-e2e.test.sh|\
    fm-backend-herdr-focus-flash-e2e.test.sh|\
    fm-backend-herdr-stale-active-tab-e2e.test.sh|\
    fm-backend-herdr-agent-exit-shell-e2e.test.sh|\
    fm-herdr-attached-viewer-live-e2e.test.sh|fm-herdr-session-cleanup-e2e.test.sh|\
    fm-backend-herdr-smoke.test.sh|fm-backend-herdr-workspace-per-home-e2e.test.sh|\
    fm-control-herdr-smoke.test.sh)
      printf '%s\n' real-herdr-gated
      ;;
    fm-backlog-handoff.test.sh|fm-on.test.sh|fm-remote-backlog-handoff.test.sh|\
    fm-remote-doctor.test.sh|fm-remote-herdr-guard.test.sh|fm-remote-job.test.sh|fm-remote-job-orphan-reap.test.sh|\
    fm-remote-transport-lanes.test.sh|\
    fm-remote-reply.test.sh|fm-remote-secondmate-lifecycle-e2e.test.sh|\
    fm-remote-secondmate-trace-context.test.sh|\
    fm-secondmate-harness.test.sh|fm-secondmate-lifecycle-e2e.test.sh|\
    fm-secondmate-liveness.test.sh|fm-secondmate-reconcile.test.sh|\
    fm-secondmate-restart.test.sh|\
    fm-secondmate-safety.test.sh|fm-secondmate-sync.test.sh|\
    fm-startup-memory-budget.test.sh|fm-stow-cascade.test.sh|\
    fm-send-secondmate-marker.test.sh|fm-shared-captain-inheritance.test.sh)
      printf '%s\n' secondmate
      ;;
    fm-backlog-atomicity.test.sh|fm-grouping.test.sh|\
    fm-bootstrap.test.sh|fm-bootstrap-network-parallel.test.sh|fm-fleet-sync.test.sh|fm-gate-refuse.test.sh|fm-gotmp.test.sh|\
    fm-session-start.test.sh|fm-sessionstart-nudge.test.sh|fm-startup-network.test.sh|\
    fm-tangle-guard.test.sh|fm-update.test.sh)
      printf '%s\n' session-bootstrap
      ;;
    fm-afk-pi-herdr-return-e2e.test.sh|\
    fm-bearings-board-lavish-live-e2e.test.sh|\
    fm-claude-stop-autoarm-live-e2e.test.sh|\
    fm-claude-stopfailure-rearm-live-e2e.test.sh|\
    fm-cmux-claude-composer-live-e2e.test.sh|\
    fm-composer-matrix-live-e2e.test.sh|\
    fm-composer-codex-idle-live-e2e.test.sh|\
    fm-codex-continuity-live-e2e.test.sh|fm-grok-continuity-live-e2e.test.sh|\
    fm-cursor-primary-live-e2e.test.sh|\
    fm-grok-stop-live-e2e.test.sh|fm-harness-adapter-instructions-live-e2e.test.sh|\
    fm-harness-liveness-drift-live-e2e.test.sh|\
    fm-muse-signals-live-e2e.test.sh|fm-rovo-signals-live-e2e.test.sh|fm-agy-signals-live-e2e.test.sh|\
    fm-herdr-version-floor-live-e2e.test.sh|\
    fm-herdr-pi-stale-registration-live-e2e.test.sh|\
    fm-opencode-primary-live-e2e.test.sh|fm-pi-branch-live-e2e.test.sh|\
    fm-pi-branch-responsiveness-live-e2e.test.sh|\
    fm-pi-primary-live-e2e.test.sh|fm-pi-codex-native.test.sh|fm-omp-primary-live-e2e.test.sh|\
    fm-pr-body-write-live-e2e.test.sh|fm-pr-state-live-e2e.test.sh|\
    fm-sessionstart-hook-live-e2e.test.sh|fm-sessionstart-instruction-refresh-live-e2e.test.sh|\
    fm-quota-array-dispatch-live-e2e.test.sh|fm-send-secondmate-marker-herdr-e2e.test.sh|\
    fm-send-inbox-doorbell-live-e2e.test.sh|\
    fm-herdr-submit-confirm-live-e2e.test.sh)
      printf '%s\n' live-harness-optin
      ;;
    fm-backend-herdr.test.sh|fm-backend-tmux-smoke.test.sh|fm-backend.test.sh|\
    fm-tmux-agent-liveness.test.sh|\
    fm-control.test.sh|fm-control-relaunch.test.sh|\
    fm-herdr-session-cleanup.test.sh|fm-send-resolve-key.test.sh|fm-send-strict.test.sh|\
    fm-send-inbox.test.sh|fm-spawn-batch.test.sh|\
    fm-spawn-dispatch-profile.test.sh|fm-claude-trust.test.sh|\
    fm-trace-context-spawn.test.sh|fm-spawn-worktree-settle.test.sh|\
    fm-spawn-compact-adviser-disable.test.sh|\
    fm-spawn-compact-adviser-disable-remote.test.sh|\
    fm-teardown-endpoint-safety.test.sh)
      printf '%s\n' backend-dispatch
      ;;
    fm-check-unregister.test.sh|fm-main-ci.test.sh|fm-pr-check-security.test.sh|fm-pr-merge.test.sh|\
    fm-pr-reviewers.test.sh|fm-pr-state.test.sh|\
    fm-review-diff.test.sh|fm-teardown.test.sh|fm-x-mode.test.sh)
      printf '%s\n' pr-forge
      ;;
    fm-afk-contract.test.sh|fm-afk-inject-e2e.test.sh|fm-afk-return.test.sh)
      printf '%s\n' afk
      ;;
    fm-bearings-board-render.test.sh|fm-bearings-snapshot.test.sh|\
    fm-fleet-snapshot-view.test.sh|fm-home-summary-refresh.test.sh)
      printf '%s\n' snapshot-bearings
      ;;
    fm-backend-cmux.test.sh|fm-backend-cmux-smoke.test.sh)
      printf '%s\n' cmux
      ;;
    fm-backend-zellij.test.sh|fm-backend-zellij-smoke.test.sh)
      printf '%s\n' zellij
      ;;
    fm-backend-orca.test.sh)
      printf '%s\n' orca
      ;;
    fm-branch-supervision.test.sh|fm-busy-adapter-wiring.test.sh|\
    fm-busy-state.test.sh|fm-classify-corr-token.test.sh|\
    fm-claude-stop-autoarm.test.sh|fm-cursor-harness.test.sh|\
    fm-extension-binding.test.sh|fm-gitignore-config.test.sh|\
    fm-no-mistakes-required.test.sh|fm-peek-remote.test.sh|\
    fm-pending-reply.test.sh|fm-pi-branch-extension.test.sh|\
    fm-procevent-quota.test.sh|fm-procevent-when.test.sh|fm-procevent.test.sh|\
    fm-live-gate.test.sh|\
    fm-project-origin.test.sh|fm-public-followup.test.sh|fm-quota-choose.test.sh|\
    fm-remote-entrypoint.test.sh|fm-remote-secondmate-parent-binding.test.sh|\
    fm-send-remote-delivery.test.sh|fm-spawn-pool-base-freshen.test.sh|\
    fm-test-fixture-cleanup.test.sh|fm-test-fixtures.test.sh|\
    fm-voice-relay.test.sh|fm-wake-drain-open-decisions-cursor.test.sh|\
    fm-wake-drain-open-decisions.test.sh|fm-wake-drain-outcome-backstop.test.sh)
      printf '%s\n' standalone
      ;;
    *)
      printf '%s\n' unclassified
      ;;
  esac
}

expected_gate_skip_for_family() {
  case "$1" in
    real-herdr-gated) printf '%s\n' herdr ;;
    live-harness-optin) printf '%s\n' live-capability ;;
    cmux|zellij|orca) printf '%s\n' optional-binary ;;
    snapshot-bearings) printf '%s\n' optional-binary ;;
    *) printf '%s\n' none ;;
  esac
}

list_known_families() {
  cat <<'EOF'
pure-contract-unit
watcher-wake-lock
real-herdr-gated
secondmate
session-bootstrap
live-harness-optin
backend-dispatch
pr-forge
afk
snapshot-bearings
cmux
zellij
orca
standalone
unclassified
EOF
}

list_known_lanes() {
  local i
  printf '%s\n' portable-parallel-1
  printf '%s\n' portable-parallel-2
  printf '%s\n' portable-parallel-3
  printf '%s\n' portable-serial
  i=1
  while [ "$i" -le "$PORTABLE_SERIAL_SHARDS" ]; do
    printf 'portable-serial-%sof%s\n' "$i" "$PORTABLE_SERIAL_SHARDS"
    i=$((i + 1))
  done
  printf '%s\n' real-herdr-gated
  printf '%s\n' stock-bash
  i=1
  while [ "$i" -le "$STOCK_BASH_SHARDS" ]; do
    printf 'stock-bash-%sof%s\n' "$i" "$STOCK_BASH_SHARDS"
    i=$((i + 1))
  done
}

# Exact proven-isolated candidate set (same paths as
# bin/fm-test-isolation-proof.sh --list). Do not expand without a new concurrent
# isolation proof archive.
list_proven_isolated() {
  cat <<'EOF'
tests/fm-arm-pretool-check.test.sh
tests/fm-backend-herdr.test.sh
tests/fm-brief.test.sh
tests/fm-captain-hold-lifecycle.test.sh
tests/fm-cd-pretool-check.test.sh
tests/fm-composer-ghost.test.sh
tests/fm-composer-lib.test.sh
tests/fm-crew-state.test.sh
tests/fm-ensure-agents-md.test.sh
tests/fm-grok-harness.test.sh
tests/fm-herdr-lab.test.sh
tests/fm-lint.test.sh
tests/fm-pi-primary-types.test.sh
tests/fm-pr-merge.test.sh
tests/fm-review-diff.test.sh
tests/fm-send-popup-settle.test.sh
tests/fm-send-settle.test.sh
tests/fm-send-strict.test.sh
tests/fm-spawn-batch.test.sh
tests/fm-supervision-instructions.test.sh
tests/fm-test-run.test.sh
tests/fm-tmux-submit-busy.test.sh
tests/fm-transition-lib.test.sh
tests/fm-x-mode.test.sh
EOF
}

# Per-script serial CI duration hints, one "<path> <ms>" per line, used to
# pack only the two portable parallel lanes. Measurement provenance and the
# refresh procedure are owned by docs/fm-test-portable-shards.md.
portable_parallel_weight_hints() {
  cat <<'EOF'
tests/fm-arm-pretool-check.test.sh 31176
tests/fm-backend-herdr.test.sh 28778
tests/fm-brief.test.sh 6807
tests/fm-captain-hold-lifecycle.test.sh 357273
tests/fm-cd-pretool-check.test.sh 16060
tests/fm-composer-ghost.test.sh 2125
tests/fm-composer-lib.test.sh 8133
tests/fm-crew-state.test.sh 31724
tests/fm-ensure-agents-md.test.sh 937
tests/fm-grok-harness.test.sh 6587
tests/fm-herdr-lab.test.sh 16918
tests/fm-lint.test.sh 35383
tests/fm-pi-primary-types.test.sh 3933
tests/fm-pr-merge.test.sh 397518
tests/fm-review-diff.test.sh 3191
tests/fm-send-popup-settle.test.sh 6372
tests/fm-send-settle.test.sh 2446
tests/fm-send-strict.test.sh 5350
tests/fm-spawn-batch.test.sh 2635
tests/fm-supervision-instructions.test.sh 355
tests/fm-test-run.test.sh 214591
tests/fm-tmux-submit-busy.test.sh 4495
tests/fm-transition-lib.test.sh 97
tests/fm-x-mode.test.sh 31783
EOF
}

# Packed weight of a portable-serial script list read on stdin, in
# milliseconds. Unhinted members count at PORTABLE_SERIAL_DEFAULT_WEIGHT_MS, so
# the sum is the same estimate the LPT packing above balances on.
portable_serial_lane_weight() {
  awk -v fallback="$PORTABLE_SERIAL_DEFAULT_WEIGHT_MS" '
    NR == FNR { if (NF) { hint[$1] = $2 } ; next }
    NF { total += ($1 in hint) ? hint[$1] : fallback }
    END { printf "%d\n", total + 0 }
  ' <(portable_serial_weight_hints) -
}

# Sum the hints above for the scripts read on stdin, and report how many of
# them had no hint at all, as "<summed_ms> <unhinted_count>".
portable_parallel_lane_weight() {
  awk '
    NR == FNR { if (NF) { hint[$1] = $2 } ; next }
    NF {
      if ($1 in hint) { total += hint[$1] } else { unhinted++ }
    }
    END { printf "%d %d\n", total + 0, unhinted + 0 }
  ' <(portable_parallel_weight_hints) -
}

# Three-way LPT balance of the proven-isolated set over the hints above.
# tests/fm-captain-hold-lifecycle.test.sh alone (339763ms) already exceeds an
# even three-way split of the total, so it is the sole member of shard 3 and
# sets the lane count's floor: a fourth shard would not lower the packed max,
# only add a job for no wall-clock benefit (docs/fm-test-portable-shards.md).
#
# Portable parallel shard 1: LPT balance of the proven-isolated set over the
# hints above. Stored order agrees with this lane's --list-scheduled output.
# tests/fm-pi-primary-types.test.sh belongs to this lane because
# this is the parallel job that installs the Pi package; moving it needs that
# workflow step moved with it.
list_portable_parallel_1() {
  cat <<'EOF'
tests/fm-test-run.test.sh
tests/fm-lint.test.sh
tests/fm-x-mode.test.sh
tests/fm-crew-state.test.sh
tests/fm-arm-pretool-check.test.sh
tests/fm-backend-herdr.test.sh
tests/fm-cd-pretool-check.test.sh
tests/fm-send-popup-settle.test.sh
tests/fm-tmux-submit-busy.test.sh
tests/fm-pi-primary-types.test.sh
tests/fm-supervision-instructions.test.sh
EOF
}

# Portable parallel shard 2: the second LPT third of the proven set.
list_portable_parallel_2() {
  cat <<'EOF'
tests/fm-pr-merge.test.sh
tests/fm-review-diff.test.sh
tests/fm-spawn-batch.test.sh
tests/fm-composer-ghost.test.sh
EOF
}

# Portable parallel shard 3: the single dominant member LPT places alone
# (see the note above list_portable_parallel_1).
list_portable_parallel_3() {
  cat <<'EOF'
tests/fm-captain-hold-lifecycle.test.sh
tests/fm-herdr-lab.test.sh
tests/fm-composer-lib.test.sh
tests/fm-brief.test.sh
tests/fm-grok-harness.test.sh
tests/fm-send-strict.test.sh
tests/fm-send-settle.test.sh
tests/fm-ensure-agents-md.test.sh
tests/fm-transition-lib.test.sh
EOF
}

# Families whose scripts are proven safe to run concurrently WITH EACH OTHER
# under the bounded local scheduler. Deliberately separate from the
# proven-isolated set, which must stay exactly equal to the portable CI shard
# union (see the coverage guard); these families keep their serial CI lane and
# only gain concurrency for a local run.
#
# Membership is empirical, never assumed:
# `bin/fm-test-isolation-proof.sh --pool <family> --jobs 4` is the owner of the
# proof, and docs/fm-test-isolation-proof.md records the dated result.
list_concurrent_safe_families() {
  cat <<'EOF'
watcher-wake-lock
pure-contract-unit
pr-forge
secondmate
session-bootstrap
standalone
EOF
}

family_is_concurrent_safe() {
  local want=$1 line
  while IFS= read -r line; do
    [ "$line" = "$want" ] && return 0
  done < <(list_concurrent_safe_families)
  return 1
}

concurrent_safe_family_jobs_max() {
  case "$1" in
    watcher-wake-lock|pure-contract-unit|pr-forge) printf '4\n' ;;
    secondmate|session-bootstrap|standalone) printf '4\n' ;;
    *) printf '1\n' ;;
  esac
}

# A script may run under --jobs when it is individually proven isolated or is
# an exact repository member of a family carrying a recorded concurrent proof.
script_allows_concurrency() {
  local s=$1 family repo_script
  is_proven_isolated_script "$s" && return 0
  family=$(family_for_basename "$(basename "$s")")
  family_is_concurrent_safe "$family" || return 1
  while IFS= read -r repo_script; do
    [ "$repo_script" = "$s" ] && return 0
  done < <(all_repo_tests)
  return 1
}

is_proven_isolated_script() {
  local want=$1 line
  while IFS= read -r line; do
    [ "$line" = "$want" ] && return 0
  done < <(list_proven_isolated)
  return 1
}

# The portable serial remainder: every tests/*.test.sh that is neither
# proven-isolated nor real-herdr-gated. Watcher, lock, AFK, real tmux, daemon,
# secondmate lifecycle, bootstrap, the live-harness-optin family, GUI-backend,
# and other unproven work stays here. Derived rather than enumerated so a newly added test
# lands here by default instead of falling out of every lane.
list_portable_serial_scan() {  # [<inventory-file>]
  local s base fam
  while IFS= read -r s; do
    [ -n "$s" ] || continue
    base=$(basename "$s")
    fam=$(family_for_basename "$base")
    if [ "$fam" = "real-herdr-gated" ]; then
      continue
    fi
    if is_proven_isolated_script "$s"; then
      continue
    fi
    printf '%s\n' "$s"
  done < <(if [ -n "${1:-}" ]; then cat "$1"; else all_repo_tests; fi)
}

# The portable serial lane. Every call rescans tests/*.test.sh, which is correct
# for a one-shot selection but NOT for a caller that must compare several
# derivations of the lane against each other: the directory is shared, and a
# test may legitimately materialise a real tests/*.test.sh of its own for the
# duration of one case (tests/fm-lint.test.sh does, because the lint gate under
# test has to see a real changed repository file). A rescan that straddles that
# file answers a different question than the one before it.
#
# SERIAL_LANE_SNAPSHOT pins one scan for the caller that needs all its
# derivations to agree - run_coverage_guard, which builds the whole-lane listing
# and all five shard listings and then checks them against one another. Without
# the pin the guard could observe 179 scripts for four shards and 180 for the
# fifth, pack that one differently, and report the resulting disagreement as
# shards sharing scripts: a red with no defect behind it, seen 3 times out of 3
# under a concurrent local run. An absent or empty snapshot file falls back to a
# live scan, so a stale pin can never make the lane silently empty.
list_portable_serial() {
  if [ -n "${SERIAL_LANE_SNAPSHOT:-}" ] && [ -s "$SERIAL_LANE_SNAPSHOT" ]; then
    cat "$SERIAL_LANE_SNAPSHOT"
    return 0
  fi
  list_portable_serial_scan
}

# Test scripts kept OUT of the stock-bash lane, each with the reason it cannot
# be run there. The lane is everything else, so a newly added test is covered by
# default: the guard this lane replaced was an allowlist of three files, and an
# allowlist is exactly how a job keeps its name while losing its coverage.
#
# A reason is a property of the script, not a convenience. Only two kinds are
# admissible, and --check-coverage refuses an entry naming a file that no longer
# exists so the table cannot rot into a silent exclusion:
#   cost:<ms>  measured stock-bash runtime, which must be ABOVE
#              STOCK_BASH_MAX_SCRIPT_MS. The macOS runner bills at ten times the
#              Linux rate, so the lane buys breadth with a per-script bound
#              rather than paying the whole suite's long tail.
#   incompat:  the script cannot run under stock Bash on this runner at all.
#
# The bound is a FLOOR on what "cost" may claim, not an automatic evictor: a
# script above it stays in the lane unless it is listed here, which is how the
# files this job already covered keep their coverage. Removing one of those is a
# coverage regression, not a cost saving.
#
# Gate-skipping scripts are deliberately NOT excluded. They cost milliseconds,
# the runner names each one and its reason in the log, and that record is how
# this lane reports the coverage it cannot deliver instead of hiding it.
list_stock_bash_exclusions() {
  cat <<'EOF'
tests/fm-afk-inject-e2e.test.sh	cost:35609
tests/fm-afk-launch.test.sh	cost:41076
tests/fm-agy-harness.test.sh	cost:64547
tests/fm-arm-pretool-check.test.sh	cost:38690
tests/fm-backend-herdr.test.sh	cost:75135
tests/fm-backend-orca.test.sh	cost:43220
tests/fm-backend.test.sh	cost:36016
tests/fm-backlog-atomicity.test.sh	cost:115986
tests/fm-backlog-handoff.test.sh	cost:65693
tests/fm-bearings-board.test.sh	cost:45692
tests/fm-bootstrap.test.sh	cost:176920
tests/fm-busy-adapter-wiring.test.sh	cost:38919
tests/fm-captain-hold-lifecycle.test.sh	cost:240045
tests/fm-cd-pretool-check.test.sh	cost:38736
tests/fm-claude-stop-autoarm.test.sh	cost:44392
tests/fm-control-relaunch.test.sh	cost:106513
tests/fm-control.test.sh	cost:37225
tests/fm-crew-state.test.sh	cost:43247
tests/fm-cursor-primary.test.sh	cost:65399
tests/fm-daemon.test.sh	cost:46372
tests/fm-fleet-sync.test.sh	cost:64518
tests/fm-harness-liveness-drift-live-e2e.test.sh	cost:66361
tests/fm-home-summary-refresh.test.sh	cost:42611
tests/fm-inactive-reconcile.test.sh	cost:41680
tests/fm-lint.test.sh	cost:156636
tests/fm-muse-harness.test.sh	cost:58744
tests/fm-omp-harness.test.sh	cost:53578
tests/fm-pending-reply.test.sh	cost:42048
tests/fm-pi-branch-extension.test.sh	cost:91395
tests/fm-pi-watch-extension.test.sh	cost:56962
tests/fm-pr-check-security.test.sh	cost:240057
tests/fm-pr-merge.test.sh	cost:240050
tests/fm-procevent-when.test.sh	cost:31506
tests/fm-procevent.test.sh	cost:240038
tests/fm-public-followup.test.sh	cost:92615
tests/fm-remote-backlog-handoff.test.sh	cost:102452
tests/fm-remote-doctor.test.sh	cost:31343
tests/fm-remote-job.test.sh	cost:64343
tests/fm-remote-reply.test.sh	cost:80863
tests/fm-remote-secondmate-lifecycle-e2e.test.sh	cost:240035
tests/fm-remote-secondmate-parent-binding.test.sh	cost:58404
tests/fm-remote-secondmate-trace-context.test.sh	cost:107754
tests/fm-remote-transport-lanes.test.sh	cost:48142
tests/fm-secondmate-harness.test.sh	cost:240043
tests/fm-secondmate-liveness.test.sh	cost:42071
tests/fm-secondmate-reconcile.test.sh	cost:115755
tests/fm-secondmate-restart.test.sh	cost:72408
tests/fm-secondmate-safety.test.sh	cost:100827
tests/fm-secondmate-sync.test.sh	cost:86754
tests/fm-send-remote-delivery.test.sh	cost:38022
tests/fm-send-resolve-key.test.sh	cost:38677
tests/fm-session-start.test.sh	cost:240042
tests/fm-sessionstart-nudge.test.sh	cost:72524
tests/fm-spawn-dispatch-profile.test.sh	cost:219810
tests/fm-spawn-pool-base-freshen.test.sh	cost:98209
tests/fm-startup-network.test.sh	cost:74689
tests/fm-task-delivery.test.sh	cost:31860
tests/fm-task-inbox.test.sh	cost:34876
tests/fm-teardown-endpoint-safety.test.sh	cost:54421
tests/fm-teardown.test.sh	cost:57524
tests/fm-test-run.test.sh	cost:179218
tests/fm-trace-context-spawn.test.sh	cost:67096
tests/fm-turnend-guard.test.sh	cost:65992
tests/fm-vendor-auth-probe.test.sh	cost:48388
tests/fm-voice-relay.test.sh	cost:31718
tests/fm-wake-drain-outcome-backstop.test.sh	cost:33734
tests/fm-wake-queue.test.sh	cost:79740
tests/fm-watch-arm.test.sh	cost:72925
tests/fm-watch-recovery-loop.test.sh	cost:60342
tests/fm-watch-triage-absorb.test.sh	cost:52100
tests/fm-watch-triage-busy.test.sh	cost:49300
tests/fm-watch-triage-declared.test.sh	cost:38500
tests/fm-watch-triage-stale.test.sh	cost:100200
tests/fm-watcher-lock.test.sh	cost:53686
tests/fm-x-mode.test.sh	cost:56141
EOF
}

# Per-script stock-bash runtime floor for a cost exclusion, in milliseconds.
# No script leaves the lane without an entry above; this only refuses a cost
# reason that is not actually about cost.
STOCK_BASH_MAX_SCRIPT_MS=30000

# The stock-bash lane: every tests/*.test.sh except the exclusions above.
# Derived rather than enumerated so a newly added test is guarded by default.
list_stock_bash() {
  local s excluded
  # Read the table once rather than per candidate: this runs on every --list,
  # every lane selection, and twice inside --check-coverage.
  excluded=$(list_stock_bash_exclusions | cut -f1)
  while IFS= read -r s; do
    [ -n "$s" ] || continue
    case "$excluded" in
      "$s") continue ;;
      "$s"$'\n'*) continue ;;
      *$'\n'"$s") continue ;;
      *$'\n'"$s"$'\n'*) continue ;;
    esac
    printf '%s\n' "$s"
  done < <(all_repo_tests)
}

# How many separate macOS runners the stock-bash lane splits into. One owner:
# a stock-bash-<k>of<n> lane whose <n> disagrees is refused, so the CI matrix,
# which passes its strategy.job-total through bin/fm-stock-bash-lane.sh, cannot
# silently leave part of the lane unrun. Two, by captain decision on 2026-09-24:
# the single lane was the last job to finish in most CI runs, and a third shard
# buys nothing once the Linux serial shards are the slowest jobs again
# (docs/verification/stock-bash-lane.md).
STOCK_BASH_SHARDS=2

# Balance hint for a stock-bash script with no measured duration: about the
# mean of the measured medians below, so a newly added test neither starves nor
# overloads the shard it lands in.
STOCK_BASH_DEFAULT_WEIGHT_MS=16000

# Measured stock-bash script durations on the macOS runner, in milliseconds:
# each is the script's median over the lane's timing artifacts from recent green
# CI runs. docs/verification/stock-bash-lane.md records the runs and owns the
# refresh. Balance hints only: the shard partition stays complete and disjoint
# whatever they say, so a stale hint costs balance rather than coverage.
stock_bash_weight_hints() {
  cat <<'EOF'
tests/fm-afk-contract.test.sh 27510
tests/fm-afk-pi-herdr-return-e2e.test.sh 99
tests/fm-afk-return.test.sh 44581
tests/fm-ask-user-authority.test.sh 244
tests/fm-ask.test.sh 65230
tests/fm-awaiting-landing.test.sh 31340
tests/fm-backend-tmux-smoke.test.sh 62
tests/fm-backlog-read-bound.test.sh 31107
tests/fm-bearings-board-lavish-live-e2e.test.sh 117
tests/fm-bearings-board-render.test.sh 26906
tests/fm-bearings-snapshot.test.sh 263717
tests/fm-bootstrap-network-parallel.test.sh 16201
tests/fm-branch-orphans.test.sh 3217
tests/fm-branch-supervision.test.sh 16562
tests/fm-brief.test.sh 10569
tests/fm-build-lock.test.sh 253038
tests/fm-busy-state.test.sh 7264
tests/fm-check-unregister.test.sh 812
tests/fm-ci-workflow.test.sh 29496
tests/fm-classify-corr-token.test.sh 34276
tests/fm-classify-decision-key.test.sh 1815
tests/fm-claude-stop-autoarm-live-e2e.test.sh 90
tests/fm-claude-trust.test.sh 19687
tests/fm-cmux-claude-composer-live-e2e.test.sh 96
tests/fm-codex-continuity-live-e2e.test.sh 95
tests/fm-composer-codex-idle-live-e2e.test.sh 87
tests/fm-composer-ghost.test.sh 3090
tests/fm-composer-lib.test.sh 14097
tests/fm-composer-matrix-live-e2e.test.sh 97
tests/fm-documentation-audiences.test.sh 1268
tests/fm-ensure-agents-md.test.sh 1915
tests/fm-extension-binding.test.sh 99443
tests/fm-fleet-snapshot-view.test.sh 26274
tests/fm-gate-refuse.test.sh 9391
tests/fm-gitignore-config.test.sh 187
tests/fm-gotmp.test.sh 2250
tests/fm-grouping.test.sh 71423
tests/fm-guard-stale-banner.test.sh 17602
tests/fm-harness-adapter-instructions-live-e2e.test.sh 116
tests/fm-harness-adapter-references.test.sh 143
tests/fm-herdr-lab.test.sh 24380
tests/fm-herdr-session-cleanup.test.sh 8883
tests/fm-herdr-submit-confirm-live-e2e.test.sh 129
tests/fm-herdr-version-floor-live-e2e.test.sh 129
tests/fm-idle-fleet.test.sh 14168
tests/fm-linear-board.test.sh 75871
tests/fm-lint-repair-note.test.sh 155
tests/fm-lint-workflows.test.sh 1657
tests/fm-live-gate.test.sh 3345
tests/fm-mail-check.test.sh 9182
tests/fm-mail.test.sh 16152
tests/fm-main-ci.test.sh 13054
tests/fm-nm-test-contract.test.sh 222
tests/fm-no-mistakes-required.test.sh 258
tests/fm-operational-input.test.sh 614
tests/fm-peek-remote.test.sh 1103
tests/fm-pr-body-write-live-e2e.test.sh 130
tests/fm-pr-reviewers.test.sh 313
tests/fm-pr-state-live-e2e.test.sh 135
tests/fm-pr-state.test.sh 902
tests/fm-procevent-quota.test.sh 4062
tests/fm-project-origin.test.sh 352
tests/fm-quota-array-dispatch-live-e2e.test.sh 126
tests/fm-quota-choose.test.sh 2648
tests/fm-remote-entrypoint.test.sh 235
tests/fm-review-diff.test.sh 4946
tests/fm-send-inbox-doorbell-live-e2e.test.sh 136
tests/fm-send-inbox.test.sh 43488
tests/fm-send-popup-settle.test.sh 6234
tests/fm-send-secondmate-marker-herdr-e2e.test.sh 137
tests/fm-send-settle.test.sh 2509
tests/fm-send-strict.test.sh 6789
tests/fm-session-lock-ancestry.test.sh 5145
tests/fm-sessionstart-hook-live-e2e.test.sh 112
tests/fm-sessionstart-instruction-refresh-live-e2e.test.sh 120
tests/fm-spawn-batch.test.sh 3332
tests/fm-spawn-compact-adviser-disable-remote.test.sh 55901
tests/fm-spawn-compact-adviser-disable.test.sh 30598
tests/fm-spawn-launch-confirm.test.sh 134
tests/fm-spawn-worktree-settle.test.sh 13377
tests/fm-stat-shadowing.test.sh 438
tests/fm-stock-bash-lane.test.sh 557
tests/fm-subagent-pretool-check.test.sh 2315
tests/fm-supervision-events.test.sh 955
tests/fm-supervision-instructions.test.sh 597
tests/fm-tangle-guard.test.sh 11961
tests/fm-tasks-axi.test.sh 8466
tests/fm-test-fixture-cleanup.test.sh 1695
tests/fm-test-fixtures.test.sh 7378
tests/fm-test-isolation-proof.test.sh 4909
tests/fm-tmux-agent-liveness.test.sh 43
tests/fm-tmux-submit-busy.test.sh 7598
tests/fm-tool-update-check.test.sh 22458
tests/fm-trace-context-lib.test.sh 360
tests/fm-transition-lib.test.sh 224
tests/fm-unrecorded-pr.test.sh 6186
tests/fm-update.test.sh 21765
tests/fm-wake-daemon-lifecycle-e2e.test.sh 14082
tests/fm-wake-drain-open-decisions-cursor.test.sh 27829
tests/fm-wake-drain-open-decisions.test.sh 10632
tests/fm-wake-drain-unread-status.test.sh 23685
tests/fm-watch-checkpoint.test.sh 8137
EOF
}

# "<ms>\t<script>" for every script read on stdin, longest first, then by path.
# A script the default exclusions drop weighs nothing: default exclusions apply
# after selection, so it keeps its shard, but a default run never spends a
# second on it and the lane never measured it.
stock_bash_weighted() {
  local scripts
  scripts=$(cat)
  awk -v fallback="$STOCK_BASH_DEFAULT_WEIGHT_MS" '
    FILENAME == ARGV[1] { if (NF) { hint[$1] = $2 } ; next }
    FILENAME == ARGV[2] { if (NF) { held[$1] = 1 } ; next }
    NF { printf "%d\t%s\n", ($1 in held) ? 0 : ($1 in hint) ? hint[$1] : fallback, $1 }
  ' <(stock_bash_weight_hints) <(printf '%s\n' "$scripts" | default_excluded_among) \
    <(printf '%s\n' "$scripts") | LC_ALL=C sort -t$'\t' -k1,1nr -k2,2
}

# Longest-processing-time assignment of the stock-bash lane read on stdin to
# STOCK_BASH_SHARDS macOS runners, printing "<shard>\t<script>" for every
# script. Each shard is strictly serial in itself, so two stateful scripts still
# never share a machine. FM_STOCK_BASH_ASSIGNMENTS_FILE replaces the assignment,
# for the regressions in tests/fm-test-run.test.sh that must hand the coverage
# guard a partition this packing never produces.
stock_bash_assignments() {
  if [ -n "${FM_STOCK_BASH_ASSIGNMENTS_FILE:-}" ]; then
    cat "$FM_STOCK_BASH_ASSIGNMENTS_FILE"
    return
  fi
  stock_bash_weighted | lpt_assign "$STOCK_BASH_SHARDS"
}

# Pinned external linters a test needs in order to exercise its subject, one
# "<script><TAB><tool>" line per requirement (a script needing two tools gets
# two lines). Lane membership above is what DERIVES each CI job's install set
# from this table, so no workflow file carries a per-job tool matrix of its own.
# Origin: a release-download outage on 2026-09-21 reddened six jobs across two
# main runs, and five of the six were lanes that never invoke the tool whose
# download failed. A hand-maintained matrix in ci.yml was rejected as the fix
# because a hand-maintained static table is what had already rotted into four
# of those same six reds.
#
# The table cannot rot silently in either direction, because both directions are
# proven from what a run actually did rather than from this text:
#   - a script listed here whose tool the lane did not install skips its
#     tool-dependent cases, prints tests/lib.sh's FM_TEST_TOOL_MISSING marker,
#     and reds the run (REQUIRE_DECLARED_TOOLS above);
#   - a script NOT listed here that needs a tool prints the same marker and reds
#     the same way, naming itself as missing from this table.
# --check-coverage additionally refuses an entry naming a test that does not
# exist or a tool bin/fm-install-pinned-tools.sh does not know how to install.
# FM_TEST_REQUIRED_TOOLS_FILE replaces the table, for the regressions in
# tests/fm-test-run.test.sh that must drive a requirement the real table does
# not carry. Same seam as FM_PORTABLE_SERIAL_HINTS_FILE above.
script_required_tools() {
  local t=$'\t'
  if [ -n "${FM_TEST_REQUIRED_TOOLS_FILE:-}" ]; then
    cat "$FM_TEST_REQUIRED_TOOLS_FILE"
    return
  fi
  cat <<EOF
tests/fm-arm-pretool-check.test.sh${t}shellcheck
tests/fm-cd-pretool-check.test.sh${t}shellcheck
tests/fm-lint-workflows.test.sh${t}actionlint
tests/fm-lint.test.sh${t}shellcheck
tests/fm-lint.test.sh${t}actionlint
EOF
}

# The tools <script> requires, one per line, or nothing.
required_tools_for_script() {  # <script>
  local want=$1
  script_required_tools | awk -F '\t' -v want="$want" '$1 == want { print $2 }'
}

# The tools a whole selection requires, sorted and deduplicated, one per line.
# This is what a CI job installs: the union over the scripts its lane selects.
required_tools_for_selection() {  # <script>...
  local s
  for s in "$@"; do
    required_tools_for_script "$s"
  done | LC_ALL=C sort -u
}

# Tool names bin/fm-install-pinned-tools.sh knows how to install. That script is
# the single owner of the tool-to-installer mapping; this only validates names
# against it, so a typo here is refused instead of silently requiring nothing.
installable_pinned_tools() {
  "$ROOT/bin/fm-install-pinned-tools.sh" --list
}

# The pinned tools a script's output reported missing, one name per line,
# sorted and deduplicated. tests/lib.sh's fm_tool_skip prints the marker.
tool_markers_in() {  # <output-file>
  sed -n 's/^FM_TEST_TOOL_MISSING \([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1/p' "$1" 2>/dev/null \
    | LC_ALL=C sort -u
}

# Measured portable-serial script durations in milliseconds, from the CI timing
# artifacts recorded in docs/fm-test-portable-shards.md. Each value is the
# slowest of several green runs, so the balance holds on a slow runner rather
# than only on the fastest one measured. These are balance hints only: the shard
# partition stays complete and disjoint whatever they say, so a stale hint costs
# balance rather than coverage. That doc owns the refresh procedure.
portable_serial_weight_hints() {
  if [ -n "${FM_PORTABLE_SERIAL_HINTS_FILE:-}" ]; then
    cat "$FM_PORTABLE_SERIAL_HINTS_FILE"
    return
  fi
  cat <<'EOF'
tests/fm-afk-contract.test.sh 16596
tests/fm-afk-inject-e2e.test.sh 70343
tests/fm-afk-pi-herdr-return-e2e.test.sh 101
tests/fm-afk-return.test.sh 23421
tests/fm-agy-harness.test.sh 49204
tests/fm-agy-signals-live-e2e.test.sh 48
tests/fm-ask-user-authority.test.sh 127
tests/fm-ask.test.sh 85915
tests/fm-awaiting-landing.test.sh 9253
tests/fm-backend-cmux-smoke.test.sh 34
tests/fm-backend-cmux.test.sh 3761
tests/fm-backend-orca.test.sh 25128
tests/fm-backend-tmux-smoke.test.sh 2259
tests/fm-backend-zellij-smoke.test.sh 21
tests/fm-backend-zellij.test.sh 9948
tests/fm-backend.test.sh 22855
tests/fm-backlog-atomicity.test.sh 316522
tests/fm-backlog-handoff.test.sh 105122
tests/fm-backlog-read-bound.test.sh 27750
tests/fm-bearings-board-lavish-live-e2e.test.sh 74
tests/fm-bearings-board-render.test.sh 32236
tests/fm-bearings-board.test.sh 48766
tests/fm-bearings-snapshot.test.sh 175294
tests/fm-bootstrap-network-parallel.test.sh 9848
tests/fm-bootstrap.test.sh 47100
tests/fm-branch-orphans.test.sh 1922
tests/fm-branch-supervision.test.sh 9366
tests/fm-build-lock.test.sh 168989
tests/fm-busy-adapter-wiring.test.sh 30688
tests/fm-busy-state.test.sh 3047
tests/fm-calm-pi-extension.test.sh 50567
tests/fm-check-unregister.test.sh 486
tests/fm-ci-workflow.test.sh 16693
tests/fm-classify-corr-token.test.sh 22327
tests/fm-classify-decision-key.test.sh 1147
tests/fm-claude-stop-autoarm-live-e2e.test.sh 72
tests/fm-claude-stop-autoarm.test.sh 60853
tests/fm-claude-trust.test.sh 11344
tests/fm-cmux-claude-composer-live-e2e.test.sh 74
tests/fm-codex-continuity-live-e2e.test.sh 47
tests/fm-composer-codex-idle-live-e2e.test.sh 101
tests/fm-composer-matrix-live-e2e.test.sh 148
tests/fm-control-relaunch.test.sh 91162
tests/fm-control.test.sh 55404
tests/fm-cursor-harness.test.sh 30086
tests/fm-cursor-primary-live-e2e.test.sh 105
tests/fm-cursor-primary.test.sh 57141
tests/fm-daemon.test.sh 35566
tests/fm-documentation-audiences.test.sh 2202
tests/fm-extension-binding.test.sh 44647
tests/fm-fleet-snapshot-view.test.sh 16276
tests/fm-fleet-sync.test.sh 37953
tests/fm-gate-refuse.test.sh 5833
tests/fm-gemini-harness.test.sh 940
tests/fm-gitignore-config.test.sh 129
tests/fm-gotmp.test.sh 3467
tests/fm-grok-continuity-live-e2e.test.sh 48
tests/fm-grok-stop-live-e2e.test.sh 48
tests/fm-grouping.test.sh 56981
tests/fm-guard-stale-banner.test.sh 36535
tests/fm-harness-adapter-instructions-live-e2e.test.sh 48
tests/fm-harness-adapter-references.test.sh 84
tests/fm-harness-liveness-drift-live-e2e.test.sh 114
tests/fm-harness-precedence.test.sh 4214
tests/fm-herdr-pi-stale-registration-live-e2e.test.sh 47
tests/fm-herdr-session-cleanup.test.sh 6998
tests/fm-herdr-submit-confirm-live-e2e.test.sh 50
tests/fm-herdr-version-floor-live-e2e.test.sh 101
tests/fm-home-summary-refresh.test.sh 38497
tests/fm-idle-fleet.test.sh 11163
tests/fm-inactive-reconcile.test.sh 50314
tests/fm-kimi-harness.test.sh 20306
tests/fm-linear-board.test.sh 60475
tests/fm-lint-repair-note.test.sh 64
tests/fm-lint-workflows.test.sh 864
tests/fm-live-gate.test.sh 1798
tests/fm-mail-check.test.sh 7045
tests/fm-mail.test.sh 10361
tests/fm-main-ci.test.sh 10487
tests/fm-muse-harness.test.sh 42782
tests/fm-muse-signals-live-e2e.test.sh 109
tests/fm-nm-test-contract.test.sh 3433
tests/fm-no-mistakes-required.test.sh 329
tests/fm-omp-harness.test.sh 49111
tests/fm-omp-primary-live-e2e.test.sh 47
tests/fm-on.test.sh 11943
tests/fm-opencode-primary-live-e2e.test.sh 105
tests/fm-operational-input.test.sh 388
tests/fm-peek-remote.test.sh 1043
tests/fm-pending-reply.test.sh 31046
tests/fm-pi-branch-extension.test.sh 66107
tests/fm-pi-branch-live-e2e.test.sh 48
tests/fm-pi-branch-responsiveness-live-e2e.test.sh 13246
tests/fm-pi-codex-native.test.sh 48
tests/fm-pi-primary-live-e2e.test.sh 48
tests/fm-pi-watch-extension.test.sh 85053
tests/fm-pi-windows-shell-invocation.test.sh 79
tests/fm-pr-body-write-live-e2e.test.sh 119
tests/fm-pr-check-security.test.sh 246767
tests/fm-pr-reviewers.test.sh 166
tests/fm-pr-state-live-e2e.test.sh 49
tests/fm-pr-state.test.sh 569
tests/fm-procevent-quota.test.sh 2607
tests/fm-procevent-when.test.sh 24192
tests/fm-procevent.test.sh 226549
tests/fm-project-origin.test.sh 141
tests/fm-public-followup.test.sh 162663
tests/fm-quota-array-dispatch-live-e2e.test.sh 49
tests/fm-quota-choose.test.sh 1511
tests/fm-remote-backlog-handoff.test.sh 78007
tests/fm-remote-doctor.test.sh 14282
tests/fm-remote-entrypoint.test.sh 164
tests/fm-remote-herdr-guard.test.sh 3227
tests/fm-remote-job-orphan-reap.test.sh 2963
tests/fm-remote-job.test.sh 59199
tests/fm-remote-reply.test.sh 55997
tests/fm-remote-secondmate-lifecycle-e2e.test.sh 258392
tests/fm-remote-secondmate-parent-binding.test.sh 39905
tests/fm-remote-secondmate-trace-context.test.sh 67015
tests/fm-remote-transport-lanes.test.sh 62976
tests/fm-rovo-harness.test.sh 14908
tests/fm-rovo-signals-live-e2e.test.sh 85
tests/fm-secondmate-harness.test.sh 174321
tests/fm-secondmate-lifecycle-e2e.test.sh 9429
tests/fm-secondmate-liveness.test.sh 19251
tests/fm-secondmate-reconcile.test.sh 101124
tests/fm-secondmate-restart.test.sh 54199
tests/fm-secondmate-safety.test.sh 64275
tests/fm-secondmate-sync.test.sh 54766
tests/fm-send-agy-confirm.test.sh 3687
tests/fm-send-inbox-doorbell-live-e2e.test.sh 131
tests/fm-send-inbox.test.sh 41823
tests/fm-send-remote-delivery.test.sh 29433
tests/fm-send-resolve-key.test.sh 30577
tests/fm-send-secondmate-marker-herdr-e2e.test.sh 108
tests/fm-send-secondmate-marker.test.sh 5577
tests/fm-session-lock-ancestry.test.sh 2966
tests/fm-session-start.test.sh 167881
tests/fm-sessionstart-hook-live-e2e.test.sh 49
tests/fm-sessionstart-instruction-refresh-live-e2e.test.sh 116
tests/fm-sessionstart-nudge.test.sh 66721
tests/fm-shared-captain-inheritance.test.sh 6792
tests/fm-spawn-compact-adviser-disable-remote.test.sh 33253
tests/fm-spawn-compact-adviser-disable.test.sh 20592
tests/fm-spawn-dispatch-profile.test.sh 148277
tests/fm-spawn-launch-confirm.test.sh 45558
tests/fm-spawn-pool-base-freshen.test.sh 66982
tests/fm-spawn-worktree-settle.test.sh 9436
tests/fm-startup-memory-budget.test.sh 7443
tests/fm-startup-network.test.sh 76496
tests/fm-stat-shadowing.test.sh 51
tests/fm-stock-bash-lane.test.sh 86
tests/fm-stow-cascade.test.sh 3147
tests/fm-subagent-pretool-check.test.sh 2647
tests/fm-supervision-events.test.sh 772
tests/fm-tangle-guard.test.sh 17646
tests/fm-task-delivery.test.sh 31638
tests/fm-task-inbox.test.sh 82268
tests/fm-tasks-axi.test.sh 13145
tests/fm-teardown-endpoint-safety.test.sh 35331
tests/fm-teardown.test.sh 163436
tests/fm-test-fixture-cleanup.test.sh 837
tests/fm-test-fixtures.test.sh 5132
tests/fm-test-isolation-proof.test.sh 2872
tests/fm-tmux-agent-liveness.test.sh 3659
tests/fm-tool-update-check.test.sh 14339
tests/fm-trace-context-lib.test.sh 213
tests/fm-trace-context-spawn.test.sh 53524
tests/fm-turnend-guard.test.sh 42536
tests/fm-unrecorded-pr.test.sh 3847
tests/fm-update.test.sh 12855
tests/fm-vendor-auth-probe.test.sh 43323
tests/fm-voice-relay.test.sh 32715
tests/fm-wake-daemon-lifecycle-e2e.test.sh 10355
tests/fm-wake-drain-open-decisions-cursor.test.sh 57251
tests/fm-wake-drain-open-decisions.test.sh 18264
tests/fm-wake-drain-outcome-backstop.test.sh 44246
tests/fm-wake-drain-unread-status.test.sh 17842
tests/fm-wake-queue.test.sh 93626
tests/fm-watch-arm.test.sh 58730
tests/fm-watch-checkpoint.test.sh 6659
tests/fm-watch-recovery-loop.test.sh 59501
tests/fm-watch-triage-absorb.test.sh 191735
tests/fm-watch-triage-busy.test.sh 184766
tests/fm-watch-triage-declared.test.sh 188395
tests/fm-watch-triage-stale.test.sh 391394
tests/fm-watcher-lock.test.sh 96680
EOF
}

# The portable-serial scripts with no measured hint, one per line. These fall
# back to PORTABLE_SERIAL_DEFAULT_WEIGHT_MS, so they are balanced on a guess
# rather than on evidence; the coverage guard bounds how many there may be.
portable_serial_unhinted() {
  local tmp
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-unhinted.XXXXXX") || return 1
  portable_serial_weight_hints | awk 'NF { print $1 }' | LC_ALL=C sort -u >"$tmp/hinted"
  list_portable_serial | LC_ALL=C sort -u >"$tmp/serial"
  comm -23 "$tmp/serial" "$tmp/hinted"
  rm -rf "$tmp"
}

portable_parallel_weight_for() {
  local want=$1 ms
  ms=$(portable_parallel_weight_hints | awk -v want="$want" '$1 == want { print $2; exit }')
  if [ -n "$ms" ]; then
    printf '%s\n' "$ms"
    return 0
  fi
  portable_serial_weight_for "$want"
}

portable_serial_weight_for() {
  local want=$1 path ms
  while read -r path ms; do
    if [ "$path" = "$want" ]; then
      printf '%s\n' "$ms"
      return 0
    fi
  done < <(portable_serial_weight_hints)
  printf '%s\n' "$PORTABLE_SERIAL_DEFAULT_WEIGHT_MS"
}

# Longest-processing-time assignment of "<ms>\t<script>" lines read on stdin,
# already ordered longest first, to <bins> bins, printing "<bin>\t<script>" for
# every script. Deterministic: ties between equally loaded bins always take the
# lowest bin index. Both separate-runner shardings below pack through this.
lpt_assign() {  # <bins>
  local bins=$1 ms script i best best_load
  local -a loads=()
  i=1
  while [ "$i" -le "$bins" ]; do
    loads[i]=0
    i=$((i + 1))
  done
  while IFS=$'\t' read -r ms script; do
    [ -n "$script" ] || continue
    best=1
    best_load=${loads[1]}
    i=2
    while [ "$i" -le "$bins" ]; do
      if [ "${loads[i]}" -lt "$best_load" ]; then
        best_load=${loads[i]}
        best=$i
      fi
      i=$((i + 1))
    done
    loads[best]=$((best_load + ms))
    printf '%s\t%s\n' "$best" "$script"
  done
}

# Longest-processing-time assignment of the serial remainder to
# PORTABLE_SERIAL_SHARDS bins, printing "<shard>\t<script>" for every script.
# Candidates are ordered by hint descending then path.
portable_serial_assignments() {
  local script
  while IFS= read -r script; do
    [ -n "$script" ] || continue
    printf '%s\t%s\n' "$(portable_serial_weight_for "$script")" "$script"
  done < <(list_portable_serial) | LC_ALL=C sort -t$'\t' -k1,1nr -k2,2 \
    | lpt_assign "$PORTABLE_SERIAL_SHARDS"
}

# Parse "<k>of<n>" from a shard lane "<prefix><k>of<n>" and echo <k>, refusing
# when <n> disagrees with the configured <count> so a CI matrix built for a
# different shard count fails loudly instead of dropping tests.
shard_lane_index() {  # <lane> <prefix> <count> <what>
  local lane=$1 prefix=$2 configured=$3 what=$4 spec index count
  spec=${lane#"$prefix"}
  index=${spec%%of*}
  count=${spec#*of}
  case "$spec" in
    *of*) ;;
    *) die "unknown lane '$lane' (see --list-lanes)" ;;
  esac
  case "$index" in
    ''|*[!0-9]*) die "unknown lane '$lane' (see --list-lanes)" ;;
  esac
  case "$count" in
    ''|*[!0-9]*) die "unknown lane '$lane' (see --list-lanes)" ;;
  esac
  if [ "$count" -ne "$configured" ]; then
    die "lane '$lane' asks for $count $what shards but this runner is configured for $configured (see --list-lanes)"
  fi
  if [ "$index" -lt 1 ] || [ "$index" -gt "$configured" ]; then
    die "lane '$lane' shard index is outside 1..$configured (see --list-lanes)"
  fi
  printf '%s\n' "$index"
}

select_proven_isolated() {
  local s
  while IFS= read -r s; do
    [ -n "$s" ] || continue
    add_script "$s"
  done < <(list_proven_isolated)
}

select_lane() {
  local want=$1 s shard idx found=0
  case "$want" in
    portable-parallel-1)
      while IFS= read -r s; do
        [ -n "$s" ] || continue
        add_script "$s"
        found=1
      done < <(list_portable_parallel_1)
      ;;
    portable-parallel-2)
      while IFS= read -r s; do
        [ -n "$s" ] || continue
        add_script "$s"
        found=1
      done < <(list_portable_parallel_2)
      ;;
    portable-parallel-3)
      while IFS= read -r s; do
        [ -n "$s" ] || continue
        add_script "$s"
        found=1
      done < <(list_portable_parallel_3)
      ;;
    portable-serial)
      while IFS= read -r s; do
        [ -n "$s" ] || continue
        add_script "$s"
        found=1
      done < <(list_portable_serial)
      ;;
    portable-serial-*)
      # One separate-runner shard of the same remainder, still serial in itself.
      shard=$(shard_lane_index "$want" portable-serial- "$PORTABLE_SERIAL_SHARDS" "portable serial")
      while IFS=$'\t' read -r idx s; do
        [ -n "$s" ] || continue
        if [ "$idx" = "$shard" ]; then
          add_script "$s"
          found=1
        fi
      done < <(portable_serial_assignments)
      ;;
    real-herdr-gated)
      select_family real-herdr-gated
      found=1
      ;;
    stock-bash)
      while IFS= read -r s; do
        [ -n "$s" ] || continue
        add_script "$s"
        found=1
      done < <(list_stock_bash)
      ;;
    stock-bash-*)
      # One macOS runner's share of the same lane, still serial in itself.
      shard=$(shard_lane_index "$want" stock-bash- "$STOCK_BASH_SHARDS" stock-bash)
      while IFS=$'\t' read -r idx s; do
        [ -n "$s" ] || continue
        if [ "$idx" = "$shard" ]; then
          add_script "$s"
          found=1
        fi
      done < <(list_stock_bash | stock_bash_assignments)
      ;;
    *)
      die "unknown lane '$want' (see --list-lanes)"
      ;;
  esac
  [ "$found" -eq 1 ] || die "lane '$want' selected no tests"
}

run_coverage_guard() {
  local tmp missing extra a b shard unhinted serial_total line stock_path stock_reason stock_ms
  local p1_ms p1_unhinted p2_ms p2_unhinted p3_ms p3_unhinted parallel_max_ms parallel_imbalance_ms parallel_min_ms
  local shard_ms serial_max_ms=0 serial_max_shard=0 stock_max_ms=0 stock_unhinted lands
  local -a saved_scripts=()
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-coverage.XXXXXX")

  all_repo_tests | LC_ALL=C sort -u >"$tmp/all"
  list_proven_isolated | LC_ALL=C sort -u >"$tmp/proven"
  list_portable_parallel_1 | LC_ALL=C sort -u >"$tmp/s1"
  list_portable_parallel_2 | LC_ALL=C sort -u >"$tmp/s2"
  list_portable_parallel_3 | LC_ALL=C sort -u >"$tmp/s3"

  cat "$tmp/s1" "$tmp/s2" "$tmp/s3" | LC_ALL=C sort | uniq -d >"$tmp/shard_dups"
  if [ -s "$tmp/shard_dups" ]; then
    log "coverage guard: portable parallel shards share scripts:"
    cat "$tmp/shard_dups" >&2
    rm -rf "$tmp"
    return 1
  fi
  cat "$tmp/s1" "$tmp/s2" "$tmp/s3" | LC_ALL=C sort -u >"$tmp/shards_union"
  missing=$(comm -23 "$tmp/proven" "$tmp/shards_union" || true)
  extra=$(comm -13 "$tmp/proven" "$tmp/shards_union" || true)
  if [ -n "$missing" ] || [ -n "$extra" ]; then
    log "coverage guard: portable shards must equal the proven-isolated set"
    [ -z "$missing" ] || { log "missing from shards:"; printf '%s\n' "$missing" >&2; }
    [ -z "$extra" ] || { log "extra beyond proven:"; printf '%s\n' "$extra" >&2; }
    rm -rf "$tmp"
    return 1
  fi

  # Serial (whole lane and each CI shard) + Herdr lane listings without
  # disturbing a caller's selection.
  #
  # ONE SCAN, ONE PACKING, SLICED FIVE WAYS. Everything below is compared
  # against everything else - the whole lane against the union of the shards,
  # each shard against the others - so all of it has to describe the same
  # inventory. The lane is therefore pinned to $tmp/all, the inventory this
  # guard has already been reasoning about, and the greedy packing is computed
  # once and sliced by shard index rather than recomputed per shard.
  #
  # Rescanning per shard is what made this guard red with no defect behind it:
  # tests/*.test.sh is a shared directory and a test may legitimately create a
  # real test file there for the length of one case, so two scans seconds apart
  # can disagree. An instrumented run caught four shards packing 179 scripts and
  # one packing 180, which reshuffled that shard alone and was then reported as
  # shards sharing scripts. Slicing one packing also drops roughly 900 command
  # substitutions per run to about 180, since the weight lookup is one per
  # script per packing.
  saved_scripts=("${SCRIPTS[@]+"${SCRIPTS[@]}"}")
  list_portable_serial_scan "$tmp/all" >"$tmp/serial_snapshot"
  if [ ! -s "$tmp/serial_snapshot" ]; then
    log "coverage guard: the portable serial lane scanned empty"
    SCRIPTS=("${saved_scripts[@]+"${saved_scripts[@]}"}")
    rm -rf "$tmp"
    return 1
  fi
  SERIAL_LANE_SNAPSHOT="$tmp/serial_snapshot"
  SCRIPTS=()
  select_lane portable-serial
  printf '%s\n' "${SCRIPTS[@]+"${SCRIPTS[@]}"}" | LC_ALL=C sort -u >"$tmp/serial"
  portable_serial_assignments >"$tmp/serial_assignments"
  : >"$tmp/serial_shards_raw"
  shard=1
  while [ "$shard" -le "$PORTABLE_SERIAL_SHARDS" ]; do
    awk -F '\t' -v want="$shard" '$1 == want { print $2 }' \
      "$tmp/serial_assignments" >"$tmp/serial_shard_$shard"
    if [ ! -s "$tmp/serial_shard_$shard" ]; then
      log "coverage guard: portable serial shard $shard of $PORTABLE_SERIAL_SHARDS is empty"
      SERIAL_LANE_SNAPSHOT=
      SCRIPTS=("${saved_scripts[@]+"${saved_scripts[@]}"}")
      rm -rf "$tmp"
      return 1
    fi
    cat "$tmp/serial_shard_$shard" >>"$tmp/serial_shards_raw"
    shard_ms=$(portable_serial_lane_weight <"$tmp/serial_shard_$shard")
    if [ "$shard_ms" -gt "$serial_max_ms" ]; then
      serial_max_ms=$shard_ms
      serial_max_shard=$shard
    fi
    shard=$((shard + 1))
  done
  SCRIPTS=()
  select_family real-herdr-gated
  printf '%s\n' "${SCRIPTS[@]+"${SCRIPTS[@]}"}" | LC_ALL=C sort -u >"$tmp/herdr"
  SCRIPTS=("${saved_scripts[@]+"${saved_scripts[@]}"}")
  # Every derivation that had to agree with the others has been taken; later
  # checks may scan freely. The pin is released rather than left set, so nothing
  # downstream reads a lane pinned to a directory this function is about to
  # remove (an absent snapshot would fall back to a live scan regardless).
  SERIAL_LANE_SNAPSHOT=

  # Every serial script runs in exactly one CI shard: no duplicate work across
  # runners, and no script silently left out of the required lane.
  LC_ALL=C sort "$tmp/serial_shards_raw" | uniq -d >"$tmp/serial_shard_dups"
  if [ -s "$tmp/serial_shard_dups" ]; then
    log "coverage guard: portable serial shards share scripts:"
    cat "$tmp/serial_shard_dups" >&2
    rm -rf "$tmp"
    return 1
  fi
  LC_ALL=C sort -u "$tmp/serial_shards_raw" >"$tmp/serial_shards"
  missing=$(comm -23 "$tmp/serial" "$tmp/serial_shards" || true)
  extra=$(comm -13 "$tmp/serial" "$tmp/serial_shards" || true)
  if [ -n "$missing" ] || [ -n "$extra" ]; then
    log "coverage guard: portable serial shards must equal the portable serial lane"
    [ -z "$missing" ] || { log "missing from serial shards:"; printf '%s\n' "$missing" >&2; }
    [ -z "$extra" ] || { log "extra beyond serial lane:"; printf '%s\n' "$extra" >&2; }
    rm -rf "$tmp"
    return 1
  fi

  # The heaviest shard is what meets the CI job cap first, so bound its packed
  # weight here rather than discovering the growth as a timed-out shard that
  # uploads no timing artifact and reports no verdict.
  if [ "$serial_max_ms" -gt "$PORTABLE_SERIAL_MAX_SHARD_MS" ]; then
    log "coverage guard: portable serial shard $serial_max_shard packs ${serial_max_ms}ms, over the ${PORTABLE_SERIAL_MAX_SHARD_MS}ms per-shard budget"
    log "raise PORTABLE_SERIAL_SHARDS or refresh the hints: docs/fm-test-portable-shards.md"
    rm -rf "$tmp"
    return 1
  fi

  for pair in "shards_union:serial" "shards_union:herdr" "serial:herdr"; do
    a=${pair%%:*}
    b=${pair#*:}
    comm -12 "$tmp/$a" "$tmp/$b" >"$tmp/overlap"
    if [ -s "$tmp/overlap" ]; then
      log "coverage guard: overlap between $a and $b:"
      cat "$tmp/overlap" >&2
      rm -rf "$tmp"
      return 1
    fi
  done

  cat "$tmp/shards_union" "$tmp/serial" "$tmp/herdr" | LC_ALL=C sort >"$tmp/union_raw"
  uniq -d "$tmp/union_raw" >"$tmp/union_dups"
  if [ -s "$tmp/union_dups" ]; then
    log "coverage guard: duplicate scripts across lanes:"
    cat "$tmp/union_dups" >&2
    rm -rf "$tmp"
    return 1
  fi
  LC_ALL=C sort -u "$tmp/union_raw" >"$tmp/union"
  missing=$(comm -23 "$tmp/all" "$tmp/union" || true)
  extra=$(comm -13 "$tmp/all" "$tmp/union" || true)
  if [ -n "$missing" ] || [ -n "$extra" ]; then
    log "coverage guard: union of portable shards + portable serial + Herdr must equal tests/*.test.sh"
    [ -z "$missing" ] || { log "missing from union:"; printf '%s\n' "$missing" >&2; }
    [ -z "$extra" ] || { log "extra beyond inventory:"; printf '%s\n' "$extra" >&2; }
    rm -rf "$tmp"
    return 1
  fi

  # Hint drift is what makes a balanced-looking partition run unbalanced: the
  # shards are packed from hints, so every unmeasured script is balanced on a
  # guess and enough of them let one shard reach its CI job cap while another
  # runner sits idle. Bound the unmeasured share here rather than waiting for a
  # shard to time out.
  portable_serial_unhinted >"$tmp/unhinted"
  unhinted=$(wc -l <"$tmp/unhinted" | tr -d ' ')
  serial_total=$(wc -l <"$tmp/serial" | tr -d ' ')
  if [ "$serial_total" -gt 0 ] &&
    [ "$((unhinted * 100))" -gt "$((serial_total * PORTABLE_SERIAL_MAX_UNHINTED_PERCENT))" ]; then
    log "coverage guard: $unhinted of $serial_total portable serial scripts have no measured duration hint (max ${PORTABLE_SERIAL_MAX_UNHINTED_PERCENT}%)"
    log "refresh the hints from a green run's timing artifacts: docs/fm-test-portable-shards.md"
    cat "$tmp/unhinted" >&2
    rm -rf "$tmp"
    return 1
  fi

  if [ -x "$ROOT/bin/fm-test-isolation-proof.sh" ]; then
    "$ROOT/bin/fm-test-isolation-proof.sh" --list | LC_ALL=C sort -u >"$tmp/proof_list"
    if ! cmp -s "$tmp/proven" "$tmp/proof_list"; then
      log "coverage guard: embedded proven-isolated set diverges from bin/fm-test-isolation-proof.sh --list"
      comm -3 "$tmp/proven" "$tmp/proof_list" >&2 || true
      rm -rf "$tmp"
      return 1
    fi
  fi

  # The stock-bash lane is everything minus a named-reason exclusion table. A
  # stale entry would silently shrink the lane while the table still reads as a
  # deliberate, reviewed choice, so an entry naming a file that no longer exists
  # fails here rather than quietly widening the gap this lane exists to close.
  : >"$tmp/stock_bash_bad_reason"
  : >"$tmp/stock_bash_cheap"
  : >"$tmp/stock_bash_missing"
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    case "$line" in
      *"$(printf '\t')"*) ;;
      *) printf '%s\n' "$line" >>"$tmp/stock_bash_bad_reason"; continue ;;
    esac
    stock_path=${line%%"$(printf '\t')"*}
    stock_reason=${line#*"$(printf '\t')"}
    case "$stock_reason" in
      cost:*)
        # A cost exclusion has to be justified by the bound it claims, or
        # "cost" becomes the reason anything inconvenient leaves the lane.
        stock_ms=${stock_reason#cost:}
        case "$stock_ms" in
          ''|*[!0-9]*) printf '%s\n' "$line" >>"$tmp/stock_bash_bad_reason" ;;
          *)
            if [ "$stock_ms" -le "$STOCK_BASH_MAX_SCRIPT_MS" ]; then
              printf '%s\n' "$line" >>"$tmp/stock_bash_cheap"
            fi
            ;;
        esac
        ;;
      incompat:?*) ;;
      *) printf '%s\n' "$line" >>"$tmp/stock_bash_bad_reason" ;;
    esac
    [ -f "$ROOT/$stock_path" ] || printf '%s\n' "$stock_path" >>"$tmp/stock_bash_missing"
  done < <(list_stock_bash_exclusions)
  if [ -s "$tmp/stock_bash_missing" ]; then
    log "coverage guard: stock-bash exclusions name tests that no longer exist:"
    cat "$tmp/stock_bash_missing" >&2
    rm -rf "$tmp"
    return 1
  fi
  if [ -s "$tmp/stock_bash_cheap" ]; then
    log "coverage guard: stock-bash cost exclusions at or under ${STOCK_BASH_MAX_SCRIPT_MS}ms are not cost exclusions:"
    cat "$tmp/stock_bash_cheap" >&2
    rm -rf "$tmp"
    return 1
  fi
  if [ -s "$tmp/stock_bash_bad_reason" ]; then
    log "coverage guard: stock-bash exclusions need a <path><TAB>cost:<ms>|incompat:<why> reason:"
    cat "$tmp/stock_bash_bad_reason" >&2
    rm -rf "$tmp"
    return 1
  fi
  list_stock_bash | LC_ALL=C sort -u >"$tmp/stock_bash"
  if [ ! -s "$tmp/stock_bash" ]; then
    log "coverage guard: the stock-bash lane selected no tests"
    rm -rf "$tmp"
    return 1
  fi

  # The stock-bash lane runs as STOCK_BASH_SHARDS macOS shards, so every lane
  # script must run in exactly one of them. So must every script the lane pins a
  # case count for: bin/fm-stock-bash-lane.sh passes every pin to every shard,
  # and a shard ignores the pin of a script it does not hold, so a pinned script
  # packed into no shard would drop its pin in silence. As with the serial
  # shards above, one packing of the one listing already taken is sliced by
  # shard rather than each shard rescanning tests/.
  stock_bash_assignments <"$tmp/stock_bash" >"$tmp/stock_bash_assignments"
  : >"$tmp/stock_bash_shards_raw"
  shard=1
  while [ "$shard" -le "$STOCK_BASH_SHARDS" ]; do
    awk -F '\t' -v want="$shard" '$1 == want { print $2 }' \
      "$tmp/stock_bash_assignments" >"$tmp/stock_bash_shard_$shard"
    if [ ! -s "$tmp/stock_bash_shard_$shard" ]; then
      log "coverage guard: stock-bash shard $shard of $STOCK_BASH_SHARDS is empty"
      rm -rf "$tmp"
      return 1
    fi
    cat "$tmp/stock_bash_shard_$shard" >>"$tmp/stock_bash_shards_raw"
    shard_ms=$(stock_bash_weighted <"$tmp/stock_bash_shard_$shard" | awk -F '\t' '{ t += $1 } END { printf "%d\n", t + 0 }')
    [ "$shard_ms" -le "$stock_max_ms" ] || stock_max_ms=$shard_ms
    shard=$((shard + 1))
  done
  "$ROOT/bin/fm-stock-bash-lane.sh" --ok-count-pins >"$tmp/stock_bash_pins" || {
    log "coverage guard: bin/fm-stock-bash-lane.sh --ok-count-pins failed"
    rm -rf "$tmp"
    return 1
  }
  : >"$tmp/stock_bash_pin_bad"
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    stock_path=${line%=*}
    lands=$(grep -cxF "$stock_path" "$tmp/stock_bash_shards_raw" || true)
    [ "$lands" -eq 1 ] \
      || printf '%s lands in %s stock-bash shards\n' "$stock_path" "$lands" >>"$tmp/stock_bash_pin_bad"
  done <"$tmp/stock_bash_pins"
  if [ -s "$tmp/stock_bash_pin_bad" ]; then
    log "coverage guard: every script the stock-bash lane pins a case count for must land in exactly one shard:"
    cat "$tmp/stock_bash_pin_bad" >&2
    rm -rf "$tmp"
    return 1
  fi
  LC_ALL=C sort "$tmp/stock_bash_shards_raw" | uniq -d >"$tmp/stock_bash_shard_dups"
  if [ -s "$tmp/stock_bash_shard_dups" ]; then
    log "coverage guard: stock-bash shards share scripts:"
    cat "$tmp/stock_bash_shard_dups" >&2
    rm -rf "$tmp"
    return 1
  fi
  LC_ALL=C sort -u "$tmp/stock_bash_shards_raw" >"$tmp/stock_bash_shards"
  missing=$(comm -23 "$tmp/stock_bash" "$tmp/stock_bash_shards" || true)
  extra=$(comm -13 "$tmp/stock_bash" "$tmp/stock_bash_shards" || true)
  if [ -n "$missing" ] || [ -n "$extra" ]; then
    log "coverage guard: stock-bash shards must equal the stock-bash lane"
    [ -z "$missing" ] || { log "missing from stock-bash shards:"; printf '%s\n' "$missing" >&2; }
    [ -z "$extra" ] || { log "extra beyond the stock-bash lane:"; printf '%s\n' "$extra" >&2; }
    rm -rf "$tmp"
    return 1
  fi
  # Scripts a default run executes with no measured macOS duration, so packed
  # on STOCK_BASH_DEFAULT_WEIGHT_MS. Reported for the next hint refresh.
  { default_excluded_among <"$tmp/stock_bash"; stock_bash_weight_hints | awk 'NF { print $1 }'; } \
    | LC_ALL=C sort -u >"$tmp/stock_bash_weighed"
  stock_unhinted=$(comm -23 "$tmp/stock_bash" "$tmp/stock_bash_weighed" | grep -c . || true)

  # Keep these estimates derived from the membership and hint owners; see the
  # header for the distinction between packed weights and measured job time.
  read -r p1_ms p1_unhinted <<<"$(list_portable_parallel_1 | portable_parallel_lane_weight)"
  read -r p2_ms p2_unhinted <<<"$(list_portable_parallel_2 | portable_parallel_lane_weight)"
  read -r p3_ms p3_unhinted <<<"$(list_portable_parallel_3 | portable_parallel_lane_weight)"
  parallel_max_ms=$p1_ms
  [ "$p2_ms" -le "$parallel_max_ms" ] || parallel_max_ms=$p2_ms
  [ "$p3_ms" -le "$parallel_max_ms" ] || parallel_max_ms=$p3_ms
  parallel_min_ms=$p1_ms
  [ "$p2_ms" -ge "$parallel_min_ms" ] || parallel_min_ms=$p2_ms
  [ "$p3_ms" -ge "$parallel_min_ms" ] || parallel_min_ms=$p3_ms
  parallel_imbalance_ms=$((parallel_max_ms - parallel_min_ms))

  # A default exclusion must name a real family or script: a stale entry would
  # read as a deliberate choice while excluding nothing. The excluded tests stay
  # in their lanes above, so the guard above still accounts for every file.
  local key reason known_fams
  known_fams=$(list_known_families)
  while IFS=$'\t' read -r key reason; do
    [ -n "$key" ] || continue
    [ -n "$reason" ] || { log "coverage guard: default exclusion has no reason: $key"; rm -rf "$tmp"; return 1; }
    case "$key" in
      family:*)
        printf '%s\n' "$known_fams" | grep -qxF "${key#family:}" \
          || { log "coverage guard: default exclusion names an unknown family: $key"; rm -rf "$tmp"; return 1; } ;;
      *)
        grep -qxF "$key" "$tmp/all" \
          || { log "coverage guard: default exclusion names a test that does not exist: $key"; rm -rf "$tmp"; return 1; } ;;
    esac
  done < <(list_default_exclusions)

  # The pinned-tool table is what every CI job's install set is derived from, so
  # an entry naming a test that no longer exists installs a tool for nobody, and
  # one naming a tool with no installer would silently require nothing at all.
  local tool_script tool_name installable tool_rows
  installable=$(installable_pinned_tools) \
    || { log "coverage guard: bin/fm-install-pinned-tools.sh --list failed"; rm -rf "$tmp"; return 1; }
  while IFS=$'\t' read -r tool_script tool_name; do
    [ -n "$tool_script" ] || continue
    grep -qxF "$tool_script" "$tmp/all" \
      || { log "coverage guard: script_required_tools names a test that does not exist: $tool_script"; rm -rf "$tmp"; return 1; }
    printf '%s\n' "$installable" | grep -qxF "$tool_name" \
      || { log "coverage guard: script_required_tools names a tool bin/fm-install-pinned-tools.sh cannot install: $tool_name"; rm -rf "$tmp"; return 1; }
  done < <(script_required_tools)
  tool_rows=$(script_required_tools | grep -c . || true)

  printf 'FM_TEST_COVERAGE ok total=%s parallel=%s parallel_max_ms=%s parallel_imbalance_ms=%s parallel_unhinted=%s serial=%s serial_shards=%s serial_max_ms=%s serial_shard_budget_ms=%s serial_unhinted=%s herdr=%s stock_bash=%s stock_bash_excluded=%s stock_bash_shards=%s stock_bash_max_ms=%s stock_bash_unhinted=%s required_tools=%s\n' \
    "$(wc -l <"$tmp/all" | tr -d ' ')" \
    "$(wc -l <"$tmp/shards_union" | tr -d ' ')" \
    "$parallel_max_ms" \
    "$parallel_imbalance_ms" \
    "$((p1_unhinted + p2_unhinted + p3_unhinted))" \
    "$(wc -l <"$tmp/serial" | tr -d ' ')" \
    "$PORTABLE_SERIAL_SHARDS" \
    "$serial_max_ms" \
    "$PORTABLE_SERIAL_MAX_SHARD_MS" \
    "$unhinted" \
    "$(wc -l <"$tmp/herdr" | tr -d ' ')" \
    "$(wc -l <"$tmp/stock_bash" | tr -d ' ')" \
    "$(list_stock_bash_exclusions | grep -c . || true)" \
    "$STOCK_BASH_SHARDS" \
    "$stock_max_ms" \
    "$stock_unhinted" \
    "$tool_rows"
  rm -rf "$tmp"
  return 0
}

# Serial-hint tooling over measured timing JSON. One python body serves three
# modes: derive (print the table), refresh (rewrite it in this file), and lane
# (judge a completed run). Only passing portable-serial records feed the table;
# the lane bounds count every reported record, because a shard's wall clock is
# spent whether or not the script that spent it passed.
serial_hints_from_timing() {
  local mode=$1
  shift
  [ "$#" -gt 0 ] || die "serial hint modes require at least one input timing JSON"
  command -v python3 >/dev/null 2>&1 || die "serial hint tooling requires python3"
  local cur
  cur=$(mktemp "${TMPDIR:-/tmp}/fm-test-hints.XXXXXX") || return 1
  portable_serial_weight_hints >"$cur"
  # Members this home excludes by default never run in CI, so no timing input
  # can measure them: refresh keeps their existing hints, and only theirs.
  local held="$cur.held"
  : >"$held"
  if [ "$mode" = refresh ]; then
    comm -23 <("$0" --lane portable-serial --list --include-excluded | LC_ALL=C sort -u) \
      <("$0" --lane portable-serial --list | LC_ALL=C sort -u) >"$held" || return 1
  fi
  local rc=0
  python3 - "$mode" "$cur" "$0" "$held" "$PORTABLE_SERIAL_HINT_DRIFT_PERCENT" \
    "$PORTABLE_SERIAL_HINT_DRIFT_FLOOR_MS" "$PORTABLE_SERIAL_MEASURED_SHARD_MAX_MS" \
    "$PORTABLE_SERIAL_LANE_UNDERPREDICT_PERCENT" "$PORTABLE_SERIAL_DEFAULT_WEIGHT_MS" \
    "$@" <<'PY' || rc=$?
import json, re, sys
from pathlib import Path

mode, cur_path, self_path, held_path = sys.argv[1:5]
pct, floor, shard_max, over_pct, default_ms = (int(a) for a in sys.argv[5:10])
measured = {}
shards = {}
shard_count = 0
for name in sys.argv[10:]:
    doc = json.loads(Path(name).read_text(encoding="utf-8"))
    for s in doc.get("scripts") or []:
        sel = s.get("lane_selection") or doc.get("selection") or ""
        if "portable-serial" not in sel:
            continue
        ms = int(s["duration_ms"])
        # A shard's wall clock is what the job cap kills, so the lane bounds
        # count every record. The hint table stays built from passing ones: a
        # script that died early did not measure its own cost.
        m = re.search(r"portable-serial-(\d+)of(\d+)", sel)
        if m:
            shard_count = max(shard_count, int(m.group(2)))
            shards.setdefault(int(m.group(1)), {})[s["path"]] = ms
        if s.get("exit") != 0:
            continue
        measured[s["path"]] = max(measured.get(s["path"], 0), ms)
table = "".join(f"{p} {ms}\n" for p, ms in sorted(measured.items()))
if mode == "derive":
    sys.stdout.write(table)
elif mode == "refresh":
    current = [l for l in Path(cur_path).read_text(encoding="utf-8").split("\n") if len(l.split()) == 2]
    if not measured:
        sys.exit("refusing to refresh: the inputs hold no passing portable-serial records")
    if len(measured) * 2 < len(current):
        sys.exit(f"refusing to refresh: inputs cover {len(measured)} scripts but the table has {len(current)}")
    held = set(Path(held_path).read_text(encoding="utf-8").split())
    kept = {}
    for l in current:
        p, ms = l.split()
        if p in held and p not in measured:
            kept[p] = int(ms)
    table = "".join(f"{p} {ms}\n" for p, ms in sorted({**kept, **measured}.items()))
    src = Path(self_path)
    text = src.read_text(encoding="utf-8")
    pat = re.compile(r"(portable_serial_weight_hints\(\) \{\n(?:  if .*?\n  fi\n)?  cat <<'EOF'\n).*?(^EOF\n)", re.S | re.M)
    new, n = pat.subn(lambda m: m.group(1) + table + m.group(2), text, count=1)
    if n != 1:
        sys.exit("cannot locate the portable_serial_weight_hints table")
    src.write_text(new, encoding="utf-8")
    print(f"FM_HINTS_REFRESHED scripts={len(measured)} held_excluded={len(kept)}")
else:
    hints = {}
    for line in Path(cur_path).read_text(encoding="utf-8").split("\n"):
        f = line.split()
        if len(f) == 2:
            hints[f[0]] = int(f[1])

    # Refuse a partial input rather than judge it. The aggregate job runs even
    # when a shard failed or uploaded late, and summing four shards out of five
    # makes both bounds below silently lenient.
    if not shards:
        sys.exit("--check-lane-timing: the inputs hold no portable-serial shard records")
    absent = [k for k in range(1, shard_count + 1) if k not in shards]
    if absent:
        sys.exit(
            "--check-lane-timing: inputs cover shards "
            f"{sorted(shards)} of {shard_count}; missing {absent}. "
            "Re-run with every shard's timing artifact."
        )

    failures = []
    lane_measured = lane_packed = 0
    for k in sorted(shards):
        shard_ms = sum(shards[k].values())
        packed = sum(hints.get(path, default_ms) for path in shards[k])
        lane_measured += shard_ms
        lane_packed += packed
        print(
            f"FM_LANE_SHARD shard={k} scripts={len(shards[k])} "
            f"measured_ms={shard_ms} packed_ms={packed} max_ms={shard_max}"
        )
        if shard_ms > shard_max:
            failures.append(
                f"portable-serial shard {k} measured {shard_ms}ms, over the {shard_max}ms bound; "
                "re-shard (PORTABLE_SERIAL_SHARDS), do not raise the bound"
            )
    over = lane_measured * 100 - lane_packed * (100 + over_pct)
    print(
        f"FM_LANE_TIMING shards={len(shards)} measured_ms={lane_measured} "
        f"packed_ms={lane_packed} allowed_over_percent={over_pct}"
    )
    if lane_packed and over > 0:
        failures.append(
            f"the portable-serial lane measured {lane_measured}ms against a packed weight of "
            f"{lane_packed}ms, more than {over_pct}% over; the hint table under-predicts the "
            "lane, so refresh it: bin/fm-test-run.sh --refresh-serial-hints <timing.json...> "
            "(docs/fm-test-portable-shards.md)"
        )

    # Reported, never gated. After a re-pack a per-script gap is attribution
    # moving between scripts rather than cost changing, so it names something
    # worth a look and decides nothing.
    named = 0
    for path, ms in sorted(measured.items()):
        if path not in hints:
            continue
        gap = abs(ms - hints[path])
        if gap > floor and gap * 100 > pct * hints[path]:
            named += 1
            print(f"FM_HINT_DRIFT {path} hint_ms={hints[path]} measured_ms={ms}")
    print(f"FM_HINT_DRIFT_SUMMARY checked={len(measured)} named={named} gating=no")

    if failures:
        for line in failures:
            print(f"fm-test-run: {line}", file=sys.stderr)
        sys.exit(1)
PY
  rm -f "$cur" "$cur.held"
  return "$rc"
}

aggregate_timing_json() {
  local out=$1
  shift
  [ "$#" -gt 0 ] || die "--aggregate-json requires at least one input timing JSON"
  command -v python3 >/dev/null 2>&1 || die "--aggregate-json requires python3"
  python3 - "$out" "$@" <<'PY'
import json, sys
from pathlib import Path

out = Path(sys.argv[1])
inputs = [Path(p) for p in sys.argv[2:]]
lanes = []
all_scripts = []
failed = 0
skipped = 0
total = 0
wall_ms = 0
for path in inputs:
    doc = json.loads(path.read_text(encoding="utf-8"))
    summary = doc.get("summary") or {}
    lane = {
        "path": str(path),
        "run_id": doc.get("run_id"),
        "selection": doc.get("selection"),
        "started_at": doc.get("started_at"),
        "finished_at": doc.get("finished_at"),
        "summary": summary,
    }
    lanes.append(lane)
    total += int(summary.get("total") or 0)
    failed += int(summary.get("failed") or 0)
    skipped += int(summary.get("skipped_gate") or 0)
    wall_ms = max(wall_ms, int(summary.get("duration_ms") or 0))
    for s in doc.get("scripts") or []:
        row = dict(s)
        row["lane_selection"] = doc.get("selection")
        row["lane_run_id"] = doc.get("run_id")
        all_scripts.append(row)

all_scripts.sort(key=lambda s: (-int(s.get("duration_ms") or 0), s.get("path") or ""))
agg = {
    "kind": "aggregate",
    "lanes": lanes,
    "summary": {
        "lanes": len(lanes),
        "total": total,
        "failed": failed,
        "skipped_gate": skipped,
        "critical_path_duration_ms": wall_ms,
    },
    "scripts": all_scripts,
    "slowest": all_scripts[:15],
}
out.parent.mkdir(parents=True, exist_ok=True)
out.write_text(json.dumps(agg, indent=2, sort_keys=True) + "\n", encoding="utf-8")
print(f"FM_TEST_AGGREGATE lanes={len(lanes)} total={total} failed={failed} skipped_gate={skipped} critical_path_duration_ms={wall_ms}")
PY
}

# Proof that a CI exclusion is real and complete, read from the timing
# artifacts a run recorded. The workflow text cannot prove it: a misspelled
# family name excludes nothing, and a name that matches a neighbour drops a
# third family without any diff saying so. Two obligations, each named:
#   - an excluded family's script that executed is a stale or ineffective exclusion
#   - a script outside the excluded families that did not execute was dropped
check_excluded_families() {
  local ex known inv rc=0
  if [ "${#EXCLUDE_FAMILIES[@]}" -eq 0 ] && [ "${#EXCLUDE_SCRIPTS[@]}" -eq 0 ]; then
    load_default_exclusions
  fi
  [ "$#" -gt 0 ] || die "--check-exclusions requires at least one input timing JSON"
  command -v python3 >/dev/null 2>&1 || die "--check-exclusions requires python3"
  known=$(list_known_families)
  for ex in "${EXCLUDE_FAMILIES[@]+"${EXCLUDE_FAMILIES[@]}"}"; do
    printf '%s\n' "$known" | grep -qxF "$ex" || die "--exclude-family '$ex' is not a known family (see --list-families)"
  done
  for ex in "${EXCLUDE_SCRIPTS[@]+"${EXCLUDE_SCRIPTS[@]}"}"; do
    all_repo_tests | grep -qxF "$ex" || die "--exclude-script '$ex' is not a known test script"
  done
  inv=$(mktemp "${TMPDIR:-/tmp}/fm-test-inventory.XXXXXX") || return 1
  local f
  while IFS= read -r f; do
    printf '%s\t%s\n' "$f" "$(family_for_basename "$(basename "$f")")"
  done < <(all_repo_tests) >"$inv"
  python3 - "$inv" "$(IFS=,; printf '%s' "${EXCLUDE_FAMILIES[*]+"${EXCLUDE_FAMILIES[*]}"}")" "$(IFS=,; printf '%s' "${EXCLUDE_SCRIPTS[*]+"${EXCLUDE_SCRIPTS[*]}"}")" "$@" <<'PY' || rc=$?
import json, sys
from pathlib import Path

inv_path, excluded_csv, scripts_csv = sys.argv[1:4]
excluded = [e for e in excluded_csv.split(",") if e]
excluded_scripts = [e for e in scripts_csv.split(",") if e]
inventory = {}
for line in Path(inv_path).read_text(encoding="utf-8").splitlines():
    path, family = line.split("\t")
    inventory[path] = family

executed = {}
stock_ran = {}
for name in sys.argv[4:]:
    doc = json.loads(Path(name).read_text(encoding="utf-8"))
    for s in doc.get("scripts") or []:
        selection = s.get("lane_selection") or doc.get("selection") or ""
        if selection.startswith(("family=", "scripts")):
            # An explicit on-demand run (the Herdr job names its family): the
            # person asked for those scripts, so it neither proves nor breaks
            # a default exclusion.
            continue
        if "lane=stock-bash" in selection:
            # It selects its own subset, so it cannot prove a script ran, but a
            # script it did run still proves an exclusion failed.
            stock_ran[s.get("path")] = s.get("family")
            continue
        executed[s.get("path")] = s.get("family")

bad = []
for path, ran_family in sorted({**stock_ran, **executed}.items()):
    fam = inventory.get(path, ran_family)
    if fam in excluded or ran_family in excluded:
        bad.append(f"FM_EXCLUSION_EXECUTED {path} family={fam}: the exclusion did not take effect")
    elif path in excluded_scripts:
        bad.append(f"FM_EXCLUSION_EXECUTED {path} script: the exclusion did not take effect")
for path, fam in sorted(inventory.items()):
    if fam not in excluded and path not in excluded_scripts and path not in executed:
        bad.append(f"FM_EXCLUSION_DROPPED {path} family={fam}: not excluded, yet it did not run")

counts = {e: sum(1 for f in inventory.values() if f == e) for e in excluded}
for line in bad:
    print(line)
label = ",".join(excluded) + ("+" if excluded and excluded_scripts else "") + (f"{len(excluded_scripts)}scripts" if excluded_scripts else "")
if bad:
    print(f"FM_EXCLUSIONS failed excluded={label} problems={len(bad)}")
    sys.exit(1)
by_script = [p for p in excluded_scripts if inventory.get(p) not in excluded]
skipped = sum(counts.values()) + len(by_script)
detail = " ".join([f"{e}={counts[e]}" for e in excluded] + ([f"scripts={len(by_script)}"] if by_script else []))
print(f"FM_EXCLUSIONS ok excluded={label} excluded_scripts={skipped} ({detail}) executed={len(executed)} inventory={len(inventory)}")
PY
  rm -f "$inv"
  return "$rc"
}

all_repo_tests() {
  # Deterministic lexical order (same as bash glob expansion under LC_ALL=C).
  local f
  # shellcheck disable=SC2035
  for f in tests/*.test.sh; do
    [ -f "$f" ] || continue
    printf '%s\n' "$f"
  done | LC_ALL=C sort
}

normalize_script_path() {
  local p=$1
  case "$p" in
    /*) printf '%s\n' "$p" ;;
    tests/*|./tests/*)
      p=${p#./}
      printf '%s\n' "$p"
      ;;
    *.test.sh)
      if [ -f "tests/$p" ]; then
        printf 'tests/%s\n' "$p"
      else
        printf '%s\n' "$p"
      fi
      ;;
    *)
      printf '%s\n' "$p"
      ;;
  esac
}

# Append unique relative-or-absolute script paths to SCRIPTS.
add_script() {
  local p existing
  p=$(normalize_script_path "$1")
  for existing in "${SCRIPTS[@]+"${SCRIPTS[@]}"}"; do
    [ "$existing" = "$p" ] && return 0
  done
  SCRIPTS+=("$p")
}

select_all() {
  local s
  while IFS= read -r s; do
    [ -n "$s" ] || continue
    add_script "$s"
  done < <(all_repo_tests)
}

select_family() {
  local want=$1 s base fam found=0
  [ -n "$want" ] || die "--family requires a name"
  while IFS= read -r s; do
    [ -n "$s" ] || continue
    base=$(basename "$s")
    fam=$(family_for_basename "$base")
    if [ "$fam" = "$want" ]; then
      add_script "$s"
      found=1
    fi
  done < <(all_repo_tests)
  [ "$found" -eq 1 ] || die "no tests mapped to family '$want'"
}

families_for_test_reference() {  # <needle>...
  local s needle
  local found=0
  local -a needles=()
  for needle in "$@"; do needles+=(-e "$needle"); done
  while IFS= read -r s; do
    [ -n "$s" ] || continue
    if grep -Fq "${needles[@]}" "$s"; then
      family_for_basename "$(basename "$s")"
      found=1
    fi
  done < <(all_repo_tests)
  [ "$found" -eq 1 ]
}

# Tests that name <needle>, selected as individual scripts rather than widened
# to each referencing test's whole family. A direct reference is per-script
# evidence, so it selects per script: one real-Herdr E2E sourcing a shared
# helper must not drag in every other script of that expensive family.
scripts_for_test_reference() {
  local needle=$1 s
  local found=0
  while IFS= read -r s; do
    [ -n "$s" ] || continue
    if grep -Fq "$needle" "$s"; then
      printf '__script__:%s\n' "$(basename "$s")"
      found=1
    fi
  done < <(all_repo_tests)
  [ "$found" -eq 1 ]
}

# bin/ scripts other than <needle> itself that name <needle>.
bin_consumers_of() {
  local needle=$1 b
  for b in bin/*.sh bin/backends/*.sh; do
    [ -f "$b" ] || continue
    [ "$(basename "$b")" = "$needle" ] || ! grep -Fq "$needle" "$b" || printf '%s\n' "$b"
  done
}

# An unmapped bin/ path has no curated family of its own. Its blast radius is
# the tests that name it, plus the curated families of the bin/ scripts that
# consume it. Direct test references resolve per script (above) while consumer
# scripts resolve back through the curated map, so genuine family-level
# coupling a maintainer recorded is preserved while an incidental single-script
# reference no longer selects that script's whole family.
BIN_FALLBACK_DEPTH=0
families_for_unmapped_bin() {
  local path=$1 needle consumer out found=0
  needle=$(basename "$path")
  if out=$(scripts_for_test_reference "$needle"); then
    printf '%s\n' "$out"
    found=1
  fi
  if [ "$BIN_FALLBACK_DEPTH" -lt 2 ]; then
    BIN_FALLBACK_DEPTH=$((BIN_FALLBACK_DEPTH + 1))
    while IFS= read -r consumer; do
      [ -n "$consumer" ] || continue
      out=$(families_for_changed_path "$consumer" | grep -v '^__unmapped__:' || true)
      if [ -n "$out" ]; then
        printf '%s\n' "$out"
        found=1
      fi
    done < <(bin_consumers_of "$needle")
    BIN_FALLBACK_DEPTH=$((BIN_FALLBACK_DEPTH - 1))
  fi
  [ "$found" -eq 1 ]
}

# Conservative path → family map. Over-selects rather than under-selects.
# Never expands to the complete suite.
families_for_changed_path() {
  local path=$1 fixture_ref
  case "$path" in
    tests/fm-backend-herdr-eventwait.test.py)
      printf '%s\n' real-herdr-gated
      printf '%s\n' backend-dispatch
      ;;
    tests/*.test.sh)
      # A single test file change selects only that script via basename family
      # resolution in the caller; emit a marker family of __script__
      printf '%s\n' "__script__:$(basename "$path")"
      ;;
    bin/fm-test-run.sh)
      # Deliberately the WHOLE family, not just the two contract tests. This
      # runner executes every pure-contract-unit script, so a change to it is
      # only proven by running them: its own contract test passing says the
      # runner's logic is right, not that the suite it drives still runs.
      printf '%s\n' pure-contract-unit
      # Only this script wraps each suite in run_script_bounded's fixture Git
      # isolation, and only a standalone-family script proves it.
      printf '%s\n' "__script__:fm-test-fixtures.test.sh"
      ;;
    bin/fm-test-isolation-proof.sh)
      # Same reason as the runner above: the proof drives every
      # pure-contract-unit script. It runs each candidate directly, never
      # through run_script_bounded, so it cannot regress fixture Git isolation.
      printf '%s\n' pure-contract-unit
      ;;
    bin/backends/herdr*|bin/fm-herdr-lab.sh|tests/herdr-test-safety.sh|tests/herdr-client-pair-fixture.sh)
      printf '%s\n' real-herdr-gated
      printf '%s\n' backend-dispatch
      printf '%s\n' pure-contract-unit
      ;;
    bin/fm-herdr-session-cleanup.sh)
      printf '%s\n' session-bootstrap
      printf '%s\n' real-herdr-gated
      printf '%s\n' backend-dispatch
      ;;
    bin/backends/zellij*|tests/zellij-test-safety.sh)
      printf '%s\n' zellij
      printf '%s\n' backend-dispatch
      ;;
    bin/backends/cmux*|tests/cmux-test-safety.sh)
      printf '%s\n' cmux
      printf '%s\n' backend-dispatch
      ;;
    bin/backends/orca*|bin/backends/tmux.sh)
      printf '%s\n' backend-dispatch
      printf '%s\n' orca
      ;;
    bin/fm-backend.sh|bin/fm-backend-hometag-lib.sh)
      printf '%s\n' backend-dispatch
      printf '%s\n' real-herdr-gated
      ;;
    bin/fm-agent-process-lib.sh)
      # The shared harness-process classifier feeds both the tmux and Herdr
      # liveness verdicts, so a change to it is proven by both backends' suites.
      printf '%s\n' backend-dispatch
      printf '%s\n' real-herdr-gated
      printf '%s\n' pure-contract-unit
      ;;
    bin/fm-watch*|bin/fm-wake*|bin/fm-inactive-reconcile.sh|\
    bin/fm-classify-lib.sh|bin/fm-daemon*|bin/fm-turnend-guard*|bin/fm-guard.sh)
      printf '%s\n' watcher-wake-lock
      ;;
    bin/fm-afk*)
      printf '%s\n' afk
      printf '%s\n' real-herdr-gated
      ;;
    bin/fm-supervisor-target-lib.sh)
      printf '%s\n' watcher-wake-lock
      printf '%s\n' real-herdr-gated
      printf '%s\n' live-harness-optin
      printf '%s\n' afk
      ;;
    bin/fm-startup-memory-budget.sh|bin/fm-startup-memory-budget-lib.sh)
      printf '%s\n' secondmate
      printf '%s\n' session-bootstrap
      ;;
    bin/fm-secondmate*|bin/fm-remote*|bin/fm-on.sh|bin/fm-home-seed.sh|\
    bin/fm-backlog-handoff.sh|bin/fm-backlog-receive.sh|bin/fm-procevent-remote-reply.sh|\
    bin/fm-config-inherit-lib.sh|bin/fm-config-push.sh|bin/fm-shared*|\
    bin/fm-stow-cascade.sh)
      printf '%s\n' secondmate
      ;;
    bin/fm-session-start.sh|bin/fm-fleet-sync.sh|\
    bin/fm-sessionstart-nudge.sh|bin/fm-startup-network.sh|bin/fm-tangle*|bin/fm-update.sh|\
    bin/fm-gate-refuse*|bin/fm-lock*)
      printf '%s\n' session-bootstrap
      ;;
    bin/fm-bootstrap.sh)
      printf '%s\n' session-bootstrap
      printf '%s\n' "__script__:fm-brief.test.sh"
      ;;
    bin/fm-quota-axi-lib.sh)
      printf '%s\n' session-bootstrap
      printf '%s\n' "__script__:fm-procevent-quota.test.sh"
      printf '%s\n' "__script__:fm-quota-choose.test.sh"
      ;;
    bin/fm-procevent-quota.sh)
      printf '%s\n' "__script__:fm-procevent-quota.test.sh"
      ;;
    bin/fm-quota-choose.sh)
      printf '%s\n' "__script__:fm-quota-choose.test.sh"
      ;;
    .pi/extensions/fm-branch-supervision.ts|.pi/extensions/lib/fm-async-exec.ts|\
    .pi/extensions/lib/fm-branch-dispatch.ts|.pi/extensions/lib/fm-native-contract.ts)
      # The portable suites that actually load these files, named one by one.
      # Left unmapped, a Pi extension library resolves through the reference
      # scan, which widens to each referencing suite's WHOLE family - and
      # these suites sit in four different families, so that pulls in dozens
      # of suites with nothing to do with Pi.
      printf '%s\n' __script__:fm-pi-branch-extension.test.sh
      printf '%s\n' __script__:fm-pi-watch-extension.test.sh
      printf '%s\n' __script__:fm-calm-pi-extension.test.sh
      printf '%s\n' __script__:fm-watch-recovery-loop.test.sh
      printf '%s\n' __script__:fm-wake-queue.test.sh
      printf '%s\n' __script__:fm-pi-primary-types.test.sh
      # Whether an arriving outcome still lets the captain type is a fact only
      # a real Pi TUI can answer, so the live guards are selected too.
      printf '%s\n' live-harness-optin
      ;;
    .pi/extensions/lib/fm-operational-input.ts)
      # The same rule for the operational-input library, whose reach is wider:
      # every Pi extension that classifies or encodes operational text.
      printf '%s\n' __script__:fm-pi-windows-shell-invocation.test.sh
      printf '%s\n' __script__:fm-pi-branch-extension.test.sh
      printf '%s\n' __script__:fm-pi-watch-extension.test.sh
      printf '%s\n' __script__:fm-calm-pi-extension.test.sh
      printf '%s\n' __script__:fm-watch-recovery-loop.test.sh
      printf '%s\n' __script__:fm-turnend-guard.test.sh
      printf '%s\n' __script__:fm-sessionstart-nudge.test.sh
      printf '%s\n' __script__:fm-pi-primary-types.test.sh
      printf '%s\n' live-harness-optin
      ;;
    bin/fm-sessionstart-run.sh|.claude/settings.json|.codex/hooks.json|\
    .pi/extensions/fm-primary-turnend-guard.ts)
      # The run tier's two harness-supplied facts (source vocabulary and
      # context-reset stdout injection) only show up against a real harness.
      printf '%s\n' __script__:fm-pi-windows-shell-invocation.test.sh
      printf '%s\n' session-bootstrap
      printf '%s\n' live-harness-optin
      ;;
    bin/fm-extension.mjs|bin/fm-extension.sh|docs/examples/process-event-extension/*)
      printf '%s\n' __script__:fm-extension-binding.test.sh
      ;;
    bin/fm-procevent.sh|bin/fm-procevent-lib.sh|bin/fm-procevent-extension-capture.pl)
      printf '%s\n' __script__:fm-extension-binding.test.sh
      printf '%s\n' __script__:fm-procevent.test.sh
      printf '%s\n' __script__:fm-procevent-when.test.sh
      printf '%s\n' __script__:fm-remote-reply.test.sh
      ;;
    bin/fm-timeout-lib.sh)
      # The shared hard bound: session start's runtime bound, the fleet/bearings
      # snapshots, the vendor auth probe, the stow cascade's per-home step, and
      # the wedge detector's worktree write probe all depend on it.
      printf '%s\n' session-bootstrap
      printf '%s\n' snapshot-bearings
      printf '%s\n' pure-contract-unit
      printf '%s\n' secondmate
      printf '%s\n' watcher-wake-lock
      printf '%s\n' "__script__:fm-procevent-quota.test.sh"
      ;;
    bin/fm-pr-*|bin/fm-merge-local.sh|bin/fm-teardown.sh|bin/fm-review-diff.sh|\
    bin/fm-x-*|bin/fm-check*)
      printf '%s\n' pr-forge
      ;;
    bin/fm-nm-run-lib.sh)
      # Shared no-mistakes run-attribution primitives, sourced by both
      # bin/fm-crew-state.sh (pure-contract-unit) and bin/fm-teardown.sh's
      # pre-teardown run abort (pr-forge).
      printf '%s\n' pure-contract-unit
      printf '%s\n' pr-forge
      ;;
    bin/fm-control-lib.sh)
      printf '%s\n' backend-dispatch
      printf '%s\n' session-bootstrap
      printf '%s\n' "__script__:fm-quota-choose.test.sh"
      ;;
    bin/fm-composer-lib.sh)
      # The shared shape catalogue is vendor-rendered signal; a change to it
      # re-selects the live guard (fm-composer-matrix-live-e2e) alongside the
      # portable families.
      printf '%s\n' backend-dispatch
      printf '%s\n' pure-contract-unit
      printf '%s\n' live-harness-optin
      ;;
    bin/fm-spawn.sh|bin/fm-send.sh|bin/fm-harness.sh|\
    bin/fm-peek.sh|bin/fm-composer*)
      printf '%s\n' backend-dispatch
      printf '%s\n' pure-contract-unit
      ;;
    bin/fm-task-inbox-lib.sh)
      # The steering-inbox record/doorbell/ladder owner: fm-send's data plane
      # (backend-dispatch), the watcher's re-ring check (watcher-wake-lock),
      # and the live doorbell guard against real harnesses.
      printf '%s\n' backend-dispatch
      printf '%s\n' watcher-wake-lock
      printf '%s\n' live-harness-optin
      ;;
    bin/fm-bearings-snapshot.sh|bin/fm-fleet-snapshot.sh|bin/fm-fleet-view.sh|\
    bin/fm-home-summary-refresh.sh)
      printf '%s\n' snapshot-bearings
      ;;
    bin/fm-install-herdr.sh|bin/fm-install-treehouse.sh|bin/fm-herdr-ci-cleanup.sh)
      printf '%s\n' pure-contract-unit
      # Pin or cleanup changes also select the real-Herdr family so the required
      # lane's contract coverage re-runs.
      printf '%s\n' real-herdr-gated
      ;;
    bin/fm-lint.sh|bin/fm-lint-workflows.sh|bin/fm-install-shellcheck.sh|\
    bin/fm-install-actionlint.sh|\
    bin/fm-brief.sh|bin/fm-ensure-agents-md.sh|bin/fm-crew-state.sh|\
    bin/fm-captain-hold.sh|bin/fm-decision-hold.sh|bin/fm-supervision*|bin/fm-transition-lib.sh|\
    bin/fm-tmux-lib.sh|bin/fm-marker-lib.sh|bin/fm-operational-input.sh|bin/fm-tasks-axi-lib.sh|\
    bin/fm-vendor-auth-probe.sh|\
    bin/fm-primary-scope-lib.sh|bin/fm-project-mode.sh|bin/fm-promote.sh|\
    bin/fm-ff-lib.sh|bin/fm-gotmp*|bin/*pretool*)
      printf '%s\n' pure-contract-unit
      ;;
    .agents/skills/quota-array-dispatch/SKILL.md)
      printf '%s\n' pure-contract-unit
      printf '%s\n' live-harness-optin
      ;;
    .agents/skills/harness-adapters/SKILL.md|.agents/skills/harness-adapters/references/*)
      printf '%s\n' pure-contract-unit
      printf '%s\n' live-harness-optin
      ;;
    .agents/skills/*/SKILL.md)
      printf '%s\n' pure-contract-unit
      ;;
    .github/workflows/ci.yml|.no-mistakes.yaml)
      printf '%s\n' pure-contract-unit
      printf '%s\n' real-herdr-gated
      ;;
    docs/fm-test-portable-shards.md|docs/fm-test-isolation-proof.md|\
    docs/fm-test-isolation-proof.json)
      printf '%s\n' pure-contract-unit
      ;;
    .github/*|.gitattributes|.tasks.toml|AGENTS.md|CLAUDE.md|CONTRIBUTING.md|\
    docs/configuration.md|docs/supervision-protocols/*)
      printf '%s\n' pure-contract-unit
      ;;
    tests/git-config-helpers.sh|tests/worker-env-helpers.sh)
      # The reference scan is not transitive, so match the two helpers that
      # source this one as well: most suites inherit it only through them.
      families_for_test_reference "$(basename "$path")" lib.sh herdr-test-safety.sh \
        || printf '%s\n' "__unmapped__:$path"
      ;;
    tests/fixtures/*/*)
      # A fixture belongs to whichever suite reads its directory, found by the
      # same reference scan used for shared helpers. Keyed on the directory
      # rather than the file so adding a fixture selects the same suite.
      # A removed fixture directory has no consuming suite left to select.
      fixture_ref=${path#tests/fixtures/}
      fixture_ref=${fixture_ref%%/*}
      if [ -d "tests/fixtures/$fixture_ref" ]; then
        families_for_test_reference "fixtures/$fixture_ref" \
          || printf '%s\n' "__unmapped__:$path"
      fi
      ;;
    tests/lib.sh|tests/*-helpers.sh|tests/fixtures.sh|tests/*-fixture.sh)
      # Shared top-level test files, selected by the suites that name them.
      # Must stay below the tests/fixtures/*/* arm: a case glob's * spans /, so
      # tests/*-fixture.sh would otherwise swallow a nested
      # tests/fixtures/<dir>/<name>-fixture.sh and scan for its basename
      # instead of the fixture directory its readers actually name.
      families_for_test_reference "$(basename "$path")" \
        || printf '%s\n' "__unmapped__:$path"
      ;;
    bin/*)
      # A deleted script has no consuming suite left to select, the same rule
      # the fixture case above applies. Refusing on its absent mapping would
      # make every retirement branch unable to select its changed tests.
      if [ -e "$path" ]; then
        families_for_unmapped_bin "$path" \
          || printf '%s\n' "__unmapped__:$path"
      fi
      ;;
    tests/*)
      printf '%s\n' "__unmapped__:$path"
      ;;
    README.md|LICENSE|assets/*|docs/*|.gitignore)
      ;;
    *)
      if [ -e "$path" ]; then
        families_for_test_reference "$path" \
          || printf '%s\n' "__unmapped__:$path"
      else
        # A retired source path with no remaining test consumer cannot select
        # a runnable suite. Known source paths above retain their mappings,
        # and a still-referenced removal is found by the same reference scan.
        families_for_test_reference "$path" || true
      fi
      ;;
  esac
}

select_changed() {
  local base=$1 path entry fam script_name s
  local -a wanted_families=()
  local -a wanted_scripts=()

  if ! git -C "$ROOT" rev-parse --verify "$base" >/dev/null 2>&1; then
    die "changed-file base ref not found: $base (pass --base <ref>)"
  fi

  while IFS= read -r path; do
    [ -n "$path" ] || continue
    while IFS= read -r entry; do
      [ -n "$entry" ] || continue
      case "$entry" in
        __script__:*)
          script_name=${entry#__script__:}
          wanted_scripts+=("$script_name")
          ;;
        __unmapped__:*)
          die "no changed-test mapping for source path: ${entry#__unmapped__:}"
          ;;
        *)
          wanted_families+=("$entry")
          ;;
      esac
    done < <(families_for_changed_path "$path")
  done < <(git -C "$ROOT" diff --name-only "${base}...HEAD" 2>/dev/null; \
           git -C "$ROOT" diff --name-only HEAD 2>/dev/null; \
           git -C "$ROOT" ls-files --others --exclude-standard 2>/dev/null)

  # Dedup families
  local f seen_f
  local -a unique_families=()
  for f in "${wanted_families[@]+"${wanted_families[@]}"}"; do
    seen_f=0
    for u in "${unique_families[@]+"${unique_families[@]}"}"; do
      [ "$u" = "$f" ] && { seen_f=1; break; }
    done
    [ "$seen_f" -eq 0 ] && unique_families+=("$f")
  done

  for f in "${unique_families[@]+"${unique_families[@]}"}"; do
    while IFS= read -r s; do
      [ -n "$s" ] || continue
      if [ "$(family_for_basename "$(basename "$s")")" = "$f" ]; then
        add_script "$s"
      fi
    done < <(all_repo_tests)
  done

  for script_name in "${wanted_scripts[@]+"${wanted_scripts[@]}"}"; do
    if [ -f "tests/$script_name" ]; then
      add_script "tests/$script_name"
    fi
  done

  if [ "${#SCRIPTS[@]}" -eq 0 ]; then
    log "no tests selected for changes vs $base (map is conservative; use --all for the complete suite)"
  fi
}

detect_gate_skip() {
  # True when the first non-empty output line is a skip: gate message.
  local file=$1 first
  first=$(awk 'NF { print; exit }' "$file" 2>/dev/null || true)
  case "$first" in
    skip:*) return 0 ;;
    *) return 1 ;;
  esac
}

# Echo the reason a gate skip gave, i.e. the first meaningful output line with
# its leading "skip:" removed. Tabs and stray whitespace are folded so the
# reason stays one field of the tab-separated record the JSON artifact is built
# from. Callers only use this once detect_gate_skip has already said yes.
gate_skip_reason() {
  local file=$1 first
  first=$(awk 'NF { print; exit }' "$file" 2>/dev/null || true)
  first=${first#skip:}
  printf '%s\n' "$first" | tr '\t' ' ' | sed -e 's/^ *//' -e 's/ *$//'
}

# True when any output line contains "skip: <token>" (token may contain spaces).
detect_gate_skip_token() {
  local file=$1 token=$2
  [ -n "$token" ] || return 1
  grep -F -q "skip: $token" "$file" 2>/dev/null
}

# Tests this home does not spend time on by default, for local and CI runs
# alike: one table, one behaviour. A green default run does NOT vouch for them.
# Nothing here is deleted: every file stays in the repository, stays in its
# lane's membership (so the coverage guard still accounts for it), and runs on
# demand - name the script or --family explicitly, or pass --include-excluded.
# Applied after selection, so lane packing does not move. Each line is
# <family:NAME | path><TAB><reason>. Reasons that name a card mean the exclusion
# HIDES a known red; it does not answer it.
list_default_exclusions() {
  local t=$'\t'
  cat <<EOF
family:secondmate${t}this home has never registered a secondmate. NOT because they pass: tests/fm-remote-secondmate-trace-context.test.sh gave an unattributed red on 2026-09-21 (card fm-remote-clone-source-object-red, still open); excluding it hides that red, it does not answer it
family:real-herdr-gated${t}this home runs tmux, not Herdr; CI's Herdr job is switched off unless FM_CI_RUN_HERDR is true
tests/fm-pi-watch-extension.test.sh${t}Pi is not used here. Its OpenCode external-healthy case was intermittently red until the OpenCode plugins stopped dying on an unhandled EPIPE writing to a child that had already exited; tests/fm-turnend-guard.test.sh owns that regression and is not excluded, so this exclusion now hides no red
tests/fm-calm-pi-extension.test.sh${t}Pi is not used here, and CI installs no Pi, so there every case that loads Pi would skip. Its red on main at f902a5ff ("Pi did not restore the persisted session after restart") was the test's own restart racing the exit of the tmux server it had just emptied, not Pi; the test now keeps that server up, so this exclusion now hides no red
tests/fm-pi-branch-extension.test.sh${t}Pi is not used here
tests/fm-pi-branch-responsiveness-live-e2e.test.sh${t}Pi is not used here
tests/fm-pi-primary-types.test.sh${t}Pi is not used here
tests/fm-agy-harness.test.sh${t}agy harness is not used here
tests/fm-send-agy-confirm.test.sh${t}agy harness is not used here
tests/fm-muse-harness.test.sh${t}muse harness is not used here
tests/fm-kimi-harness.test.sh${t}kimi harness is not used here
tests/fm-rovo-harness.test.sh${t}rovo harness is not used here
tests/fm-grok-harness.test.sh${t}grok harness is not used here
tests/fm-omp-harness.test.sh${t}omp harness is not used here
tests/fm-cursor-harness.test.sh${t}cursor harness is not used here
tests/fm-cursor-primary.test.sh${t}cursor harness is not used here
tests/fm-gemini-harness.test.sh${t}gemini harness is not used here
tests/fm-backend-orca.test.sh${t}orca backend is not used here
tests/fm-backend-zellij.test.sh${t}zellij backend is not used here
tests/fm-backend-cmux.test.sh${t}cmux backend is not used here
tests/fm-pi-codex-native.test.sh${t}Pi surface is not used here; currently skips (needs a real Pi install), so this hides nothing and saves no measurable time
tests/fm-pi-primary-live-e2e.test.sh${t}Pi surface is not used here; currently skips (needs a real Pi install), so this hides nothing and saves no measurable time
tests/fm-pi-branch-live-e2e.test.sh${t}Pi surface is not used here; currently skips (needs a real Pi install), so this hides nothing and saves no measurable time
tests/fm-pi-windows-shell-invocation.test.sh${t}Native Windows Pi surface is not used here; currently skips (needs native Windows), so this hides nothing and saves no measurable time
tests/fm-herdr-pi-stale-registration-live-e2e.test.sh${t}Herdr classifier against real Pi surface is not used here; currently skips (needs Herdr and a real Pi install), so this hides nothing and saves no measurable time
tests/fm-cursor-primary-live-e2e.test.sh${t}cursor harness surface is not used here; currently skips (needs a real cursor install), so this hides nothing and saves no measurable time
tests/fm-agy-signals-live-e2e.test.sh${t}agy harness surface is not used here; currently skips (needs a real agy install), so this hides nothing and saves no measurable time
tests/fm-muse-signals-live-e2e.test.sh${t}muse harness surface is not used here; currently skips (needs a real muse install), so this hides nothing and saves no measurable time
tests/fm-rovo-signals-live-e2e.test.sh${t}rovo harness surface is not used here; currently skips (needs a real rovo install), so this hides nothing and saves no measurable time
tests/fm-omp-primary-live-e2e.test.sh${t}omp harness surface is not used here; currently skips (needs a real omp install), so this hides nothing and saves no measurable time
tests/fm-opencode-primary-live-e2e.test.sh${t}opencode harness surface is not used here; currently skips (needs a real opencode install), so this hides nothing and saves no measurable time
tests/fm-grok-continuity-live-e2e.test.sh${t}grok harness surface is not used here; currently skips (needs a real grok install), so this hides nothing and saves no measurable time
tests/fm-grok-stop-live-e2e.test.sh${t}grok harness surface is not used here; currently skips (needs a real grok install), so this hides nothing and saves no measurable time
tests/fm-backend-cmux-smoke.test.sh${t}cmux backend surface is not used here; currently skips (needs a real cmux), so this hides nothing and saves no measurable time
tests/fm-backend-zellij-smoke.test.sh${t}zellij backend surface is not used here; currently skips (needs a real zellij), so this hides nothing and saves no measurable time
EOF
}

# Fill EXCLUDE_FAMILIES / EXCLUDE_SCRIPTS from the table for selections that
# mean "the default set" and that the caller did not opt out of.
load_default_exclusions() {
  local key reason
  while IFS=$'\t' read -r key reason; do
    [ -n "$key" ] || continue
    case "$key" in
      family:*) EXCLUDE_FAMILIES+=("${key#family:}") ;;
      *) EXCLUDE_SCRIPTS+=("$key") ;;
    esac
  done < <(list_default_exclusions)
}

# The scripts read on stdin that the default exclusions drop, one per line.
default_excluded_among() {
  local key reason s families=" " paths=$'\n'
  while IFS=$'\t' read -r key reason; do
    [ -n "$key" ] || continue
    case "$key" in
      family:*) families="$families${key#family:} " ;;
      *) paths="$paths$key"$'\n' ;;
    esac
  done < <(list_default_exclusions)
  while IFS= read -r s; do
    [ -n "$s" ] || continue
    case "$paths" in
      *$'\n'"$s"$'\n'*) printf '%s\n' "$s"; continue ;;
    esac
    case "$families" in
      *" $(family_for_basename "${s##*/}") "*) printf '%s\n' "$s" ;;
    esac
  done
}

apply_exclude_families() {
  local s fam keep ex
  local -a kept=()
  [ "${#EXCLUDE_FAMILIES[@]}" -gt 0 ] || [ "${#EXCLUDE_SCRIPTS[@]}" -gt 0 ] || return 0
  for s in "${EXCLUDE_SCRIPTS[@]+"${EXCLUDE_SCRIPTS[@]}"}"; do
    [ -f "$s" ] || die "--exclude-script '$s' is not an existing script"
  done
  for s in "${SCRIPTS[@]+"${SCRIPTS[@]}"}"; do
    fam=$(family_for_basename "$(basename "$s")")
    keep=1
    for ex in "${EXCLUDE_SCRIPTS[@]+"${EXCLUDE_SCRIPTS[@]}"}"; do
      if [ "$s" = "$ex" ]; then
        keep=0
        break
      fi
    done
    for ex in "${EXCLUDE_FAMILIES[@]+"${EXCLUDE_FAMILIES[@]}"}"; do
      if [ "$fam" = "$ex" ]; then
        keep=0
        break
      fi
    done
    [ "$keep" -eq 1 ] && kept+=("$s")
  done
  SCRIPTS=("${kept[@]+"${kept[@]}"}")
}

write_json_artifact() {
  local out=$1
  local started=$2
  local finished=$3
  local run_id=$4
  local total=$5
  local failed=$6
  local skipped=$7
  local duration=$8
  local selection=$9
  local records_file=${10}
  local families_file=${11}

  if ! command -v python3 >/dev/null 2>&1; then
    die "--json requires python3 to emit a valid timing artifact"
  fi

  python3 - "$out" "$started" "$finished" "$run_id" "$total" "$failed" "$skipped" "$duration" "$selection" "$records_file" "$families_file" <<'PY'
import json, sys

out, started, finished, run_id, total, failed, skipped, duration, selection, records_file, families_file = sys.argv[1:]

scripts = []
with open(records_file, encoding="utf-8") as fh:
    for line in fh:
        line = line.rstrip("\n")
        if not line:
            continue
        path, family, expected, exit_s, dur_s, gate, reason = line.split("\t")
        scripts.append({
            "path": path,
            "family": family,
            "expected_gate_skip": expected,
            "duration_ms": int(dur_s),
            "exit": int(exit_s),
            "gate_skip": gate == "true",
            "gate_skip_reason": reason,
        })

families = []
with open(families_file, encoding="utf-8") as fh:
    for line in fh:
        line = line.rstrip("\n")
        if not line:
            continue
        name, count_s, dur_s, failed_s = line.split("\t")
        families.append({
            "name": name,
            "count": int(count_s),
            "duration_ms": int(dur_s),
            "failed": int(failed_s),
        })

doc = {
    "run_id": run_id,
    "started_at": started,
    "finished_at": finished,
    "selection": selection,
    "summary": {
        "total": int(total),
        "failed": int(failed),
        "skipped_gate": int(skipped),
        "duration_ms": int(duration),
    },
    "scripts": scripts,
    "families": families,
}
with open(out, "w", encoding="utf-8") as fh:
    json.dump(doc, fh, indent=2, sort_keys=True)
    fh.write("\n")
PY
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --all)
      [ -z "$MODE" ] || die "only one selection mode is allowed"
      MODE=all
      shift
      ;;
    --family)
      [ -z "$MODE" ] || die "only one selection mode is allowed"
      [ "$#" -gt 1 ] || die "--family requires a name"
      MODE=family
      FAMILY=$2
      shift 2
      ;;
    --family=*)
      [ -z "$MODE" ] || die "only one selection mode is allowed"
      MODE=family
      FAMILY=${1#--family=}
      shift
      ;;
    --lane)
      [ -z "$MODE" ] || die "only one selection mode is allowed"
      [ "$#" -gt 1 ] || die "--lane requires a name (see --list-lanes)"
      MODE=lane
      LANE=$2
      shift 2
      ;;
    --lane=*)
      [ -z "$MODE" ] || die "only one selection mode is allowed"
      MODE=lane
      LANE=${1#--lane=}
      shift
      ;;
    --proven-isolated)
      [ -z "$MODE" ] || die "only one selection mode is allowed"
      MODE=proven-isolated
      shift
      ;;
    --changed)
      [ -z "$MODE" ] || die "only one selection mode is allowed"
      MODE=changed
      shift
      ;;
    --base)
      [ "$#" -gt 1 ] || die "--base requires a git ref"
      BASE_REF=$2
      shift 2
      ;;
    --base=*)
      BASE_REF=${1#--base=}
      shift
      ;;
    --json)
      [ "$#" -gt 1 ] || die "--json requires a path"
      JSON_PATH=$2
      shift 2
      ;;
    --json=*)
      JSON_PATH=${1#--json=}
      shift
      ;;
    --jobs)
      [ "$#" -gt 1 ] || die "--jobs requires a positive integer"
      JOBS=$2
      JOBS_EXPLICIT=1
      shift 2
      ;;
    --jobs=*)
      JOBS=${1#--jobs=}
      JOBS_EXPLICIT=1
      shift
      ;;
    --max-wall-ms)
      [ "$#" -gt 1 ] || die "--max-wall-ms requires a positive integer"
      MAX_WALL_MS=$2
      shift 2
      ;;
    --max-wall-ms=*)
      MAX_WALL_MS=${1#--max-wall-ms=}
      shift
      ;;
    --per-script-timeout-secs)
      [ "$#" -gt 1 ] || die "--per-script-timeout-secs requires a whole number of seconds"
      PER_SCRIPT_TIMEOUT_SECS=$2
      PER_SCRIPT_TIMEOUT_GIVEN=1
      shift 2
      ;;
    --per-script-timeout-secs=*)
      PER_SCRIPT_TIMEOUT_SECS=${1#--per-script-timeout-secs=}
      PER_SCRIPT_TIMEOUT_GIVEN=1
      shift
      ;;
    --list)
      LIST_ONLY=1
      shift
      ;;
    --list-required-tools)
      LIST_REQUIRED_TOOLS=1
      shift
      ;;
    --list-scheduled)
      LIST_SCHEDULED=1
      shift
      ;;
    --list-families)
      LIST_FAMILIES=1
      shift
      ;;
    --list-concurrent-safe-families)
      LIST_CONCURRENT_SAFE_FAMILIES=1
      shift
      ;;
    --require-ok-count)
      [ "$#" -gt 1 ] || die "--require-ok-count requires <script>=<count>"
      REQUIRE_OK_COUNTS+=("$2")
      shift 2
      ;;
    --require-ok-count=*)
      REQUIRE_OK_COUNTS+=("${1#--require-ok-count=}")
      shift
      ;;
    --list-stock-bash-exclusions)
      list_stock_bash_exclusions
      exit 0
      ;;
    --concurrent-safe-family-jobs-max)
      [ "$#" -gt 1 ] || die "--concurrent-safe-family-jobs-max requires a family name"
      concurrent_safe_family_jobs_max "$2"
      exit 0
      ;;
    --concurrent-safe-family-jobs-max=*)
      concurrent_safe_family_jobs_max "${1#--concurrent-safe-family-jobs-max=}"
      exit 0
      ;;
    --list-lanes)
      LIST_LANES=1
      shift
      ;;
    --check-coverage)
      CHECK_COVERAGE=1
      shift
      ;;
    --aggregate-json)
      [ "$#" -gt 1 ] || die "--aggregate-json requires an output path"
      AGGREGATE_OUT=$2
      shift 2
      # Remaining args after options will be collected as inputs below via MODE.
      # For aggregation we accept only input JSON paths as free args after this.
      MODE=aggregate
      ;;
    --derive-serial-hints)
      MODE=hints-derive
      shift
      ;;
    --refresh-serial-hints)
      MODE=hints-refresh
      shift
      ;;
    --check-lane-timing)
      MODE=hints-lane
      shift
      ;;
    --check-exclusions)
      MODE=exclusions
      shift
      ;;
    --exclude-family)
      [ "$#" -gt 1 ] || die "--exclude-family requires a name"
      EXCLUDE_FAMILIES+=("$2")
      shift 2
      ;;
    --include-excluded)
      INCLUDE_EXCLUDED=1
      shift
      ;;
    --list-default-exclusions)
      list_default_exclusions
      exit 0
      ;;
    --exclude-script)
      [ "$#" -gt 1 ] || die "--exclude-script requires a path"
      EXCLUDE_SCRIPTS+=("$2")
      shift 2
      ;;
    --exclude-script=*)
      EXCLUDE_SCRIPTS+=("${1#--exclude-script=}")
      shift
      ;;
    --exclude-family=*)
      EXCLUDE_FAMILIES+=("${1#--exclude-family=}")
      shift
      ;;
    --fail-on-gate-skip)
      [ "$#" -gt 1 ] || die "--fail-on-gate-skip requires a token (e.g. 'herdr not found')"
      FAIL_ON_GATE_SKIP=$2
      shift 2
      ;;
    --fail-on-gate-skip=*)
      FAIL_ON_GATE_SKIP=${1#--fail-on-gate-skip=}
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --)
      shift
      while [ "$#" -gt 0 ]; do
        SCRIPTS+=("$1")
        shift
      done
      ;;
    -*)
      die "unknown option: $1"
      ;;
    *)
      if [ "${MODE:-}" = "aggregate" ] || [ "${MODE:-}" = "exclusions" ] || [[ "${MODE:-}" == hints-* ]]; then
        SCRIPTS+=("$1")
      elif [ -z "$MODE" ] || [ "$MODE" = scripts ]; then
        MODE=scripts
        SCRIPTS+=("$1")
      else
        die "script paths cannot be combined with --$MODE"
      fi
      shift
      ;;
  esac
done

if [ "$LIST_FAMILIES" -eq 1 ]; then
  list_known_families
  exit 0
fi

if [ "$LIST_CONCURRENT_SAFE_FAMILIES" -eq 1 ]; then
  list_concurrent_safe_families
  exit 0
fi

if [ "$LIST_LANES" -eq 1 ]; then
  list_known_lanes
  exit 0
fi

if [ "$CHECK_COVERAGE" -eq 1 ]; then
  run_coverage_guard
  exit $?
fi

if [[ "${MODE:-}" == hints-* ]]; then
  for s in "${SCRIPTS[@]}"; do
    [ -f "$s" ] || die "timing input not found: $s"
  done
  serial_hints_from_timing "${MODE#hints-}" "${SCRIPTS[@]}"
  exit $?
fi

if [ "${MODE:-}" = "exclusions" ]; then
  for s in "${SCRIPTS[@]+"${SCRIPTS[@]}"}"; do
    [ -f "$s" ] || die "timing input not found: $s"
  done
  check_excluded_families "${SCRIPTS[@]+"${SCRIPTS[@]}"}"
  exit $?
fi

if [ "${MODE:-}" = "aggregate" ]; then
  [ -n "$AGGREGATE_OUT" ] || die "--aggregate-json requires an output path"
  [ "${#SCRIPTS[@]}" -gt 0 ] || die "--aggregate-json requires at least one input timing JSON"
  for s in "${SCRIPTS[@]}"; do
    [ -f "$s" ] || die "aggregate input not found: $s"
  done
  aggregate_timing_json "$AGGREGATE_OUT" "${SCRIPTS[@]}"
  exit 0
fi

case "$JOBS" in
  ''|*[!0-9]*) die "--jobs must be a positive integer" ;;
esac
[ "$JOBS" -ge 1 ] || die "--jobs must be >= 1"
[ "$JOBS" -le "$JOBS_MAX" ] || die "--jobs is capped at $JOBS_MAX (got $JOBS)"

if [ -n "$MAX_WALL_MS" ]; then
  case "$MAX_WALL_MS" in
    ''|*[!0-9]*) die "--max-wall-ms requires a positive integer" ;;
  esac
  [ "$MAX_WALL_MS" -gt 0 ] || die "--max-wall-ms requires a positive integer"
fi

[ "$PER_SCRIPT_TIMEOUT_GIVEN" -eq 1 ] || PER_SCRIPT_TIMEOUT_SECS=$DEFAULT_PER_SCRIPT_TIMEOUT_SECS
case "$PER_SCRIPT_TIMEOUT_SECS" in
  ''|*[!0-9]*) die "--per-script-timeout-secs requires a whole number of seconds (0 disables)" ;;
esac

# Refuse before any suite is selected or run. The inspection modes execute
# nothing: --list-families, --list-concurrent-safe-families, --list-lanes,
# --check-coverage, --concurrent-safe-family-jobs-max and --aggregate-json have
# already exited above, and --list/--list-scheduled print their selection and
# exit below. An unset MODE still falls through to the usage error, so a caller
# who named no selection mode is told that rather than this.
if [ -n "${MODE:-}" ] && [ "$LIST_ONLY" -eq 0 ] && [ "$LIST_SCHEDULED" -eq 0 ] \
  && [ "$LIST_REQUIRED_TOOLS" -eq 0 ]; then
  refuse_primary_checkout_for_task
fi

case "${MODE:-}" in
  all)
    select_all
    SELECTION_DESC="all"
    ;;
  family)
    select_family "$FAMILY"
    SELECTION_DESC="family=$FAMILY"
    ;;
  lane)
    select_lane "$LANE"
    SELECTION_DESC="lane=$LANE"
    ;;
  proven-isolated)
    select_proven_isolated
    SELECTION_DESC="proven-isolated"
    ;;
  changed)
    select_changed "$BASE_REF"
    SELECTION_DESC="changed:base=$BASE_REF"
    ;;
  scripts)
    # Normalize and re-add through add_script for consistent paths.
    raw=("${SCRIPTS[@]+"${SCRIPTS[@]}"}")
    SCRIPTS=()
    for s in "${raw[@]}"; do
      add_script "$s"
    done
    SELECTION_DESC="scripts"
    ;;
  *)
    die "select with --all, --family <name>, --lane <name>, --proven-isolated, --changed, or one or more script paths (see --help)"
    ;;
esac

# The default exclusions govern the selections that mean "the default set".
# An explicit script path or --family names what the person wants, so it runs.
if [ "$INCLUDE_EXCLUDED" -eq 0 ]; then
  case "${MODE:-}" in
    all|lane|proven-isolated|changed)
      load_default_exclusions
      SELECTION_DESC="${SELECTION_DESC};default-exclusions"
      ;;
  esac
fi
apply_exclude_families
if [ "${#EXCLUDE_FAMILIES[@]}" -gt 0 ]; then
  SELECTION_DESC="${SELECTION_DESC};exclude-family=$(IFS=,; printf '%s' "${EXCLUDE_FAMILIES[*]}")"
fi
if [ "${#EXCLUDE_SCRIPTS[@]}" -gt 0 ]; then
  SELECTION_DESC="${SELECTION_DESC};exclude-script=${#EXCLUDE_SCRIPTS[@]}"
fi
if [ -n "$FAIL_ON_GATE_SKIP" ]; then
  SELECTION_DESC="${SELECTION_DESC};fail-on-gate-skip=$FAIL_ON_GATE_SKIP"
fi
if [ "$LIST_REQUIRED_TOOLS" -eq 1 ]; then
  required_tools_for_selection "${SCRIPTS[@]+"${SCRIPTS[@]}"}"
  exit 0
fi
if [ "$LIST_ONLY" -eq 1 ] || [ "$LIST_SCHEDULED" -eq 1 ]; then
  if [ "$LIST_SCHEDULED" -eq 1 ]; then
    for s in "${SCRIPTS[@]+"${SCRIPTS[@]}"}"; do
      case "$MODE:$LANE" in
        lane:portable-parallel-1|lane:portable-parallel-2|lane:portable-parallel-3)
          printf '%s\t%s\n' "$(portable_parallel_weight_for "$s")" "$s"
          ;;
        *)
          printf '%s\t%s\n' "$(portable_serial_weight_for "$s")" "$s"
          ;;
      esac
    done | LC_ALL=C sort -t"$(printf '\t')" -k1,1nr -k2,2 | cut -f2-
  else
    for s in "${SCRIPTS[@]+"${SCRIPTS[@]}"}"; do
      printf '%s\n' "$s"
    done
  fi
  exit 0
fi

# An empty selection is a clean result, not a no-op that falls through. Exiting
# here also keeps every array expansion below off the empty-array path: under
# `set -u`, bash 3.2 (the stock macOS shell) treats "${arr[@]}" on an empty
# array as an unbound-variable error, while bash 4.4+ makes it a harmless no-op.
# A contributor on stock macOS who changes only documentation must still get
# total=0 and exit 0 rather than a crash.
if [ "${#SCRIPTS[@]}" -eq 0 ]; then
  log "nothing to run"
  empty_finished_ms=$(now_ms)
  empty_duration=$((empty_finished_ms - RUN_STARTED_MS))
  [ "$empty_duration" -ge 0 ] || empty_duration=0
  empty_rc=0
  printf 'FM_TEST_SUMMARY total=0 failed=0 skipped_gate=0 duration_ms=%s\n' "$empty_duration"
  # The budget covers the whole invocation, so a selection phase that outran it
  # still fails - reporting zero work is not the same as reporting no time.
  if [ -n "$MAX_WALL_MS" ]; then
    printf 'FM_TEST_BUDGET max_wall_ms=%s duration_ms=%s\n' "$MAX_WALL_MS" "$empty_duration"
    if [ "$empty_duration" -gt "$MAX_WALL_MS" ]; then
      log "wall-clock budget exceeded: ${empty_duration}ms > ${MAX_WALL_MS}ms for $SELECTION_DESC"
      empty_rc=1
    fi
  fi
  if [ -n "$JSON_PATH" ]; then
    empty_rec=$(mktemp)
    empty_fam=$(mktemp)
    : >"$empty_rec"
    : >"$empty_fam"
    empty_finished_iso=$(now_iso)
    mkdir -p "$(dirname "$JSON_PATH")"
    write_json_artifact "$JSON_PATH" "$RUN_STARTED_ISO" "$empty_finished_iso" \
      "fm-test-run-${RUN_STARTED_MS}-$$" 0 0 0 "$empty_duration" \
      "$SELECTION_DESC" "$empty_rec" "$empty_fam"
    rm -f "$empty_rec" "$empty_fam"
  fi
  exit "$empty_rc"
fi

# Verify selected scripts exist before starting.
for s in "${SCRIPTS[@]}"; do
  [ -f "$s" ] || die "test script not found: $s"
  [ -x "$s" ] || [ -r "$s" ] || die "test script not readable: $s"
done

# Plain --changed and a plain list of script paths both use the bounded
# representative-suite scheduler; numeric --jobs retains the strict all-script
# admission rule below. Naming scripts is how a local verification round asks
# for exactly those subjects, so it gets bounded concurrency rather than a
# serial chain of separate runs.
# The curated selections stay untouched: --lane composes CI shards whose serial
# lane must stay strictly serial, --family is what the required Herdr lane runs,
# and --all is a deliberate complete regression.
AUTO_CONCURRENCY=0
if { [ "$MODE" = changed ] || [ "$MODE" = scripts ]; } && [ "$JOBS_EXPLICIT" -eq 0 ]; then
  auto_admissible=0
  for s in "${SCRIPTS[@]}"; do
    script_allows_concurrency "$s" && auto_admissible=$((auto_admissible + 1))
  done
  if [ "$auto_admissible" -gt 1 ]; then
    JOBS=$(cpu_count)
    [ "$JOBS" -le 4 ] || JOBS=4
    [ "$JOBS" -ge 1 ] || JOBS=1
    [ "$JOBS" -eq 1 ] || AUTO_CONCURRENCY=1
  fi
fi
if [ "$JOBS" -gt 1 ] || [ "$MODE" = changed ] || [ "$MODE" = scripts ]; then
  SELECTION_DESC="${SELECTION_DESC};jobs=$JOBS"
fi

# An explicit --jobs names a concurrency for exactly the selection given, so an
# unproven script in it is a refusal rather than something to schedule around.
if [ "$JOBS" -gt 1 ] && [ "$AUTO_CONCURRENCY" -eq 0 ]; then
  for s in "${SCRIPTS[@]}"; do
    if ! script_allows_concurrency "$s"; then
      die "--jobs $JOBS refused: $s is not in the proven-isolated set (see bin/fm-test-isolation-proof.sh --list) and its family has no recorded concurrent proof. Unproven stateful scripts stay serial."
    fi
    if ! is_proven_isolated_script "$s"; then
      family=$(family_for_basename "$(basename "$s")")
      family_jobs_max=$(concurrent_safe_family_jobs_max "$family")
      [ "$JOBS" -le "$family_jobs_max" ] \
        || die "--jobs $JOBS refused: family $family is proven only up to $family_jobs_max concurrent workers"
    fi
  done
fi

# Split the run into proven concurrent phases and an unproven remainder.
# Individually proven scripts share one phase. Scripts admitted only by a family
# proof get a separate phase per family, because that proof establishes safety
# only among members of that family. The serial remainder runs after every
# concurrent phase, never beside another test.
CONCURRENT_SCRIPTS=()
SERIAL_TAIL_SCRIPTS=()
CONCURRENT_PHASE_BREAK=__fm_test_concurrent_phase_break__
if [ "$JOBS" -gt 1 ]; then
  SCHEDULE_TMP=$(mktemp "${TMPDIR:-/tmp}/fm-test-sched.XXXXXX")
  : >"$SCHEDULE_TMP"
  for s in "${SCRIPTS[@]}"; do
    if script_allows_concurrency "$s"; then
      if is_proven_isolated_script "$s"; then
        phase=0
      else
        family=$(family_for_basename "$(basename "$s")")
        phase=1
        while IFS= read -r admitted_family; do
          [ "$family" = "$admitted_family" ] && break
          phase=$((phase + 1))
        done < <(list_concurrent_safe_families)
      fi
      # Longest first within each isolation phase: workers are handed scripts
      # in order, so starting the longest last strands it at the tail.
      printf '%s\t%s\t%s\n' "$phase" "$(portable_serial_weight_for "$s")" "$s" >>"$SCHEDULE_TMP"
    else
      SERIAL_TAIL_SCRIPTS+=("$s")
    fi
  done
  previous_phase=
  while IFS=$'\t' read -r phase _weight s; do
    [ -n "$s" ] || continue
    if [ -n "$previous_phase" ] && [ "$phase" != "$previous_phase" ]; then
      CONCURRENT_SCRIPTS+=("$CONCURRENT_PHASE_BREAK")
    fi
    CONCURRENT_SCRIPTS+=("$s")
    previous_phase=$phase
  done < <(LC_ALL=C sort -t"$(printf '\t')" -k1,1n -k2,2nr -k3,3 "$SCHEDULE_TMP")
  rm -f "$SCHEDULE_TMP"
fi

if [ "$PER_SCRIPT_TIMEOUT_SECS" -gt 0 ]; then
  [ -r "$ROOT/bin/fm-timeout-lib.sh" ] || die "per-script timeout helper not found: bin/fm-timeout-lib.sh"
  # shellcheck source=bin/fm-timeout-lib.sh
  . "$ROOT/bin/fm-timeout-lib.sh"
fi

RUN_TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run.XXXXXX")
RECORDS="$RUN_TMP/records.tsv"
FAMILIES_TSV="$RUN_TMP/families.tsv"
: >"$RECORDS"
declare -a WORKER_PIDS=()
declare -a WORKER_IDX=()
declare -a WORKER_SCRIPTS=()

# --- the machine-wide build lock, one hold per script ------------------------
#
# Every script this runner executes runs under bin/fm-build-lock.sh, one hold
# per serial script (released between scripts), or one hold for a whole
# concurrent phase (held from its first worker until its last finishes or the
# next phase break, so its length is the phase's): never one hold around the whole
# loop, which is what kept every other worker's build waiting 20-30 minutes
# behind a single firstmate test run (docs/verification/build-lock-contention.md).
# So a caller does not wrap this runner in `mutex`; one that still does keeps
# the legacy whole-run hold, because a nested acquire inside a hold runs
# straight through rather than deadlocking.
#
# The hold is taken by a small holder process started under the lock, which
# signals once it is in and releases when told to or when this runner dies. That
# keeps the lock's waiting notices on this runner's stderr, out of the script
# output that gate-skip detection reads, and keeps the wait outside each
# script's duration and its --per-script-timeout-secs bound: a healthy script
# must never be timed out, or reported slow, for time it spent in line. The
# holder's hold is handed to the script through the lock's own nested-hold
# variables, so a script that itself runs this runner or `mutex` passes through.
BUILD_LOCK="$ROOT/bin/fm-build-lock.sh"
BUILD_LOCK_N=0
BUILD_LOCK_PID=
BUILD_LOCK_RELEASE=
BUILD_LOCK_HELD_BY=
BUILD_LOCK_HELD_LOCK=
BUILD_LOCK_WAIT_MS=0

# <label> names the hold for waiters, --status and any ceiling status line.
build_lock_hold() {  # <label>
  local label=$1 acquired begin rc=0 held
  [ -z "$BUILD_LOCK_PID" ] || return 0
  [ -x "$BUILD_LOCK" ] || die "build lock not found: $BUILD_LOCK"
  BUILD_LOCK_N=$((BUILD_LOCK_N + 1))
  acquired="$RUN_TMP/build-lock.$BUILD_LOCK_N.in"
  BUILD_LOCK_RELEASE="$RUN_TMP/build-lock.$BUILD_LOCK_N.release"
  begin=$(now_ms)
  # Expansion is intentionally deferred to the child bash passed to -c.
  # shellcheck disable=SC2016
  FM_BUILD_LOCK_POLL=${FM_BUILD_LOCK_POLL:-0.2} "$BUILD_LOCK" --label "$label" -- bash -c '
    printf "%s\t%s\n" "${FM_BUILD_LOCK_HELD_BY:-}" "${FM_BUILD_LOCK_HELD_LOCK:-}" >"$1.tmp" \
      && mv -f "$1.tmp" "$1" || exit 1
    while [ ! -e "$2" ] && kill -0 "$3" 2>/dev/null; do sleep 0.05; done
  ' _ "$acquired" "$BUILD_LOCK_RELEASE" "$$" >/dev/null </dev/null &
  BUILD_LOCK_PID=$!
  while [ ! -e "$acquired" ]; do
    if ! kill -0 "$BUILD_LOCK_PID" 2>/dev/null; then
      set +e
      wait "$BUILD_LOCK_PID"
      rc=$?
      set -e
      BUILD_LOCK_PID=
      die "could not take the machine-wide build lock (bin/fm-build-lock.sh exit $rc)"
    fi
    sleep 0.02
  done
  IFS=$'\t' read -r BUILD_LOCK_HELD_BY BUILD_LOCK_HELD_LOCK <"$acquired" || true
  held=$(( $(now_ms) - begin ))
  [ "$held" -ge 0 ] || held=0
  BUILD_LOCK_WAIT_MS=$((BUILD_LOCK_WAIT_MS + held))
}

build_lock_release() {
  [ -n "$BUILD_LOCK_PID" ] || return 0
  : >"$BUILD_LOCK_RELEASE" 2>/dev/null || true
  set +e
  wait "$BUILD_LOCK_PID" 2>/dev/null
  set -e
  BUILD_LOCK_PID=
  BUILD_LOCK_HELD_BY=
  BUILD_LOCK_HELD_LOCK=
}

# Invoked indirectly by the EXIT trap below.
# shellcheck disable=SC2329
cleanup_run() {
  build_lock_release
  rm -rf "$RUN_TMP"
}

trap cleanup_run EXIT

RUN_ID="fm-test-run-${RUN_STARTED_MS}-$$"
TOTAL=0
FAILED=0
SKIPPED_GATE=0
AGG_RC=0

# Family accumulators as TSV lines updated in-memory via temp files.
# family -> count, duration_ms, failed
family_bump() {
  local fam=$1 dur=$2 failed_delta=$3
  local line name count duration failed_count rest
  local found=0
  local tmp="$RUN_TMP/families.new"
  : >"$tmp"
  if [ -s "$FAMILIES_TSV" ]; then
    while IFS= read -r line; do
      name=${line%%$'\t'*}
      rest=${line#*$'\t'}
      count=${rest%%$'\t'*}
      rest=${rest#*$'\t'}
      duration=${rest%%$'\t'*}
      failed_count=${rest#*$'\t'}
      if [ "$name" = "$fam" ]; then
        count=$((count + 1))
        duration=$((duration + dur))
        failed_count=$((failed_count + failed_delta))
        found=1
      fi
      printf '%s\t%s\t%s\t%s\n' "$name" "$count" "$duration" "$failed_count" >>"$tmp"
    done <"$FAMILIES_TSV"
  fi
  if [ "$found" -eq 0 ]; then
    printf '%s\t%s\t%s\t%s\n' "$fam" 1 "$dur" "$failed_delta" >>"$tmp"
  fi
  mv "$tmp" "$FAMILIES_TSV"
}

# Required "ok - " count for <script>, or empty when the caller pinned none.
required_ok_count_for() {
  local want=$1 entry path count
  for entry in ${REQUIRE_OK_COUNTS[@]+"${REQUIRE_OK_COUNTS[@]}"}; do
    path=${entry%%=*}
    count=${entry#*=}
    case "$entry" in
      *=*) ;;
      *) die "--require-ok-count needs <script>=<count>, got '$entry'" ;;
    esac
    case "$count" in
      ''|*[!0-9]*) die "--require-ok-count needs a whole count, got '$entry'" ;;
    esac
    if [ "$(normalize_script_path "$path")" = "$want" ]; then
      printf '%s\n' "$count"
      return 0
    fi
  done
  return 1
}

record_script_result() {
  local script=$1 rc=$2 duration=$3 out=$4 end_iso=$5
  local base family expected gate_skip gate_reason fail_delta want_ok got_ok
  local missing_tool
  base=$(basename "$script")
  family=$(family_for_basename "$base")
  expected=$(expected_gate_skip_for_family "$family")

  if [ -n "$FAIL_ON_GATE_SKIP" ] && detect_gate_skip_token "$out" "$FAIL_ON_GATE_SKIP"; then
    log "required gate skip token seen in $script: skip: $FAIL_ON_GATE_SKIP"
    rc=1
  fi

  gate_skip=false
  gate_reason=
  if [ "$rc" -eq 0 ] && detect_gate_skip "$out"; then
    gate_skip=true
    gate_reason=$(gate_skip_reason "$out")
    SKIPPED_GATE=$((SKIPPED_GATE + 1))
    # A capability skip is the runner's only record of what this host could not
    # exercise, so name it rather than leaving a silent green.
    log "gate skip: $script: ${gate_reason:-<no reason given>}"
  fi

  # A script that exits 0 having run no case proved nothing, and its exit status
  # alone reads as a pass. A skip line, first or not, says why nothing ran.
  # Measured: tests/fm-build-lock.test.sh banked zero of its 51 cases as a pass
  # on the macOS lane for every run after its wrapper began dying mid-run.
  if [ "$rc" -eq 0 ] && ! grep -q -e '^ok - ' -e '^skip:' "$out" 2>/dev/null; then
    log "ran no cases: $script exited 0 without printing an \"ok - \" line or a skip: line"
    rc=1
  fi

  # A missing pinned tool is silent coverage loss: the case passes as a skip and
  # the run stays green. Where those tools are supposed to be installed, red it
  # and say which side is wrong, so neither this lane's install set nor
  # script_required_tools can drift away from what the tests actually need. This
  # runs after the gate-skip accounting above, so a script that both gate-skips
  # and reports a missing tool is still recorded as the gate skip it was.
  if [ "$REQUIRE_DECLARED_TOOLS" -eq 1 ]; then
    while IFS= read -r missing_tool; do
      [ -n "$missing_tool" ] || continue
      if required_tools_for_script "$script" | LC_ALL=C grep -q -x -F "$missing_tool"; then
        log "pinned tool missing in $script: $missing_tool is required by script_required_tools but was not on PATH for this lane"
      else
        log "pinned tool missing in $script: $missing_tool is needed but script_required_tools does not list it, so no lane installs it"
      fi
      rc=1
    done < <(tool_markers_in "$out")
  fi

  if want_ok=$(required_ok_count_for "$script"); then
    got_ok=$(grep -c '^ok - ' "$out" || true)
    if [ "$got_ok" -ne "$want_ok" ]; then
      log "required ok-count mismatch in $script: expected $want_ok, got $got_ok"
      rc=1
    fi
  fi

  printf 'FM_TEST_END %s %s exit=%s duration_ms=%s gate_skip=%s\n' \
    "$end_iso" "$script" "$rc" "$duration" "$gate_skip"

  fail_delta=0
  if [ "$rc" -ne 0 ]; then
    FAILED=$((FAILED + 1))
    fail_delta=1
    AGG_RC=1
  fi

  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$script" "$family" "$expected" "$rc" "$duration" "$gate_skip" "$gate_reason" >>"$RECORDS"
  family_bump "$family" "$duration" "$fail_delta"
  TOTAL=$((TOTAL + 1))
}

# Run <script>, capturing output to <out>. <stream> 1 also echoes it live.
# <id> only has to be unique within this run. When PER_SCRIPT_TIMEOUT_SECS is
# positive, a script that outruns it is terminated and reported as exit 124: a
# hung script must become a bounded failure rather than an unbounded suite,
# because an unbounded suite is what silently outruns its caller's budget.
run_script_bounded() {  # <script> <out> <stream> <id>
  local script=$1 out=$2 stream=$3 id=$4
  # Declaring the variables local first keeps the helper's export scoped to this
  # call and its child script, so the runner's own environment is left as the
  # caller had it.
  local GIT_CONFIG_GLOBAL GIT_CONFIG_NOSYSTEM
  # shellcheck source=tests/git-config-helpers.sh
  . "$ROOT/tests/git-config-helpers.sh" || return
  # The task-worker session environment is dropped from the script alone, never
  # from the runner, whose build-lock ceiling lines still need FM_TASK_STATUS.
  # tests/worker-env-helpers.sh owns the list.
  # shellcheck source=tests/worker-env-helpers.sh
  . "$ROOT/tests/worker-env-helpers.sh" || return
  # The same scoping hands the script this runner's build-lock hold, so a
  # nested acquire inside it passes straight through instead of deadlocking.
  local FM_BUILD_LOCK_HELD_BY FM_BUILD_LOCK_HELD_LOCK
  if [ -n "$BUILD_LOCK_HELD_BY" ]; then
    export FM_BUILD_LOCK_HELD_BY="$BUILD_LOCK_HELD_BY" FM_BUILD_LOCK_HELD_LOCK="$BUILD_LOCK_HELD_LOCK"
  fi
  local rc
  : "$id"
  set +e
  if [ "$stream" -eq 1 ]; then
    if [ "$PER_SCRIPT_TIMEOUT_SECS" -gt 0 ]; then
      # Expansion is intentionally deferred to the child bash passed to -c.
      # shellcheck disable=SC2016
      fm_run_timed "$PER_SCRIPT_TIMEOUT_SECS" "${FM_TEST_SCRUB_ENV_CMD[@]}" bash -c \
        'bash "$1" 2>&1 | tee "$2"; exit "${PIPESTATUS[0]}"' _ "$script" "$out"
      rc=$?
    else
      "${FM_TEST_SCRUB_ENV_CMD[@]}" bash "$script" 2>&1 | tee "$out"
      rc=${PIPESTATUS[0]}
    fi
  elif [ "$PER_SCRIPT_TIMEOUT_SECS" -gt 0 ]; then
    # The wrapper bash turns a script killed by a signal into an ordinary
    # 128+signal exit, as the streaming form above already does, because the
    # perl mechanism in bin/fm-timeout-lib.sh reports a signal death as 0.
    # shellcheck disable=SC2016
    fm_run_timed "$PER_SCRIPT_TIMEOUT_SECS" "${FM_TEST_SCRUB_ENV_CMD[@]}" bash -c 'bash "$1"; exit "$?"' _ "$script" \
      >"$out" 2>&1
    rc=$?
  else
    "${FM_TEST_SCRUB_ENV_CMD[@]}" bash "$script" >"$out" 2>&1
    rc=$?
  fi
  if [ "$PER_SCRIPT_TIMEOUT_SECS" -gt 0 ] && [ "$rc" -eq 124 ]; then
    printf 'not ok - %s exceeded the per-script bound of %ss and was terminated\n' \
      "$script" "$PER_SCRIPT_TIMEOUT_SECS" >>"$out"
    [ "$stream" -eq 1 ] && tail -1 "$out"
  fi
  return "$rc"
}

run_one_serial() {
  local script=$1
  local base family expected out begin_iso begin_ms end_ms end_iso duration rc
  base=$(basename "$script")
  family=$(family_for_basename "$base")
  expected=$(expected_gate_skip_for_family "$family")
  out="$RUN_TMP/out.$TOTAL"
  build_lock_hold "bin/fm-test-run.sh $script"
  begin_iso=$(now_iso)
  begin_ms=$(now_ms)

  printf 'FM_TEST_BEGIN %s %s family=%s expected_gate_skip=%s\n' \
    "$begin_iso" "$script" "$family" "$expected"

  set +e
  # Stream live output while retaining a copy for gate-skip detection.
  run_script_bounded "$script" "$out" 1 "s$TOTAL"
  rc=$?
  set -e
  : "${rc:=1}"

  end_ms=$(now_ms)
  end_iso=$(now_iso)
  build_lock_release
  duration=$((end_ms - begin_ms))
  if [ "$duration" -lt 0 ]; then
    duration=0
  fi
  record_script_result "$script" "$rc" "$duration" "$out" "$end_iso"
}

if [ "$JOBS" -eq 1 ]; then
  for script in "${SCRIPTS[@]}"; do
    run_one_serial "$script"
  done
else
  # Bounded concurrent execution for admitted scripts. Each worker gets a
  # private mode-0700 TMPDIR so mktemp roots cannot collide. Native Windows
  # Bash layers report synthetic POSIX modes, so retain chmod there but enforce
  # its observed mode only where the host reports real POSIX permissions.
  # Retries are never used as a green strategy.
  worker_n=0
  active_workers=0

  worker_root_mode_is_enforceable() {
    case "$(uname -s)" in
      MINGW*|MSYS*) return 1 ;;
      *) return 0 ;;
    esac
  }

  wait_one_job_worker() {
    local slot=$1 pid idx work script rc duration mode out end_iso
    pid=${WORKER_PIDS[$slot]}
    idx=${WORKER_IDX[$slot]}
    script=${WORKER_SCRIPTS[$slot]}
    set +e
    wait "$pid"
    set -e
    unset 'WORKER_PIDS[slot]'
    unset 'WORKER_IDX[slot]'
    unset 'WORKER_SCRIPTS[slot]'
    active_workers=$((active_workers - 1))
    work="$RUN_TMP/w$idx"
    rc=$(cat "$work/exit" 2>/dev/null || echo 1)
    duration=$(cat "$work/duration_ms" 2>/dev/null || echo 0)
    out="$work/output"
    end_iso=$(now_iso)
    # Replay captured output after the worker finishes so markers stay ordered.
    if [ -s "$out" ]; then
      cat "$out"
    fi
    if worker_root_mode_is_enforceable; then
      mode=$(stat -c %a "$work" 2>/dev/null || /usr/bin/stat -f %Lp "$work" 2>/dev/null || echo unknown)
      case "$mode" in
        700|0700) ;;
        *)
          log "isolation failure: worker root mode is $mode, expected 0700 ($work)"
          rc=1
          ;;
      esac
    fi
    record_script_result "$script" "$rc" "$duration" "$out" "$end_iso"
  }

  worker_pid_is_running() {
    local want=$1 running inventory="$RUN_TMP/running-pids"
    # Keep `jobs` in this shell. A process substitution runs it in a subshell
    # without this shell's job table on Bash 3.2/5.x, falsely reporting every
    # worker complete and making the scheduler wait for the oldest PID.
    jobs -r -p >"$inventory"
    while IFS= read -r running; do
      [ "$running" = "$want" ] && return 0
    done <"$inventory"
    return 1
  }

  wait_one_completed_job_worker() {
    local slot work
    while :; do
      for slot in "${!WORKER_PIDS[@]}"; do
        work="$RUN_TMP/w${WORKER_IDX[$slot]}"
        if [ -f "$work/exit" ] || ! worker_pid_is_running "${WORKER_PIDS[$slot]}"; then
          wait_one_job_worker "$slot"
          return
        fi
      done
      sleep 0.01
    done
  }

  for script in "${CONCURRENT_SCRIPTS[@]+"${CONCURRENT_SCRIPTS[@]}"}"; do
    if [ "$script" = "$CONCURRENT_PHASE_BREAK" ]; then
      while [ "$active_workers" -gt 0 ]; do
        wait_one_completed_job_worker
      done
      build_lock_release
      continue
    fi
    while [ "$active_workers" -ge "$JOBS" ]; do
      wait_one_completed_job_worker
    done
    # One hold spans the whole concurrent phase, not each script in it: its workers
    # share the machine together, and it is released only at a phase break or drain.
    build_lock_hold "bin/fm-test-run.sh concurrent phase starting with $script"
    worker_n=$((worker_n + 1))
    work="$RUN_TMP/w$worker_n"
    mkdir -p "$work/tmp"
    chmod 0700 "$work" "$work/tmp" || die "could not chmod 0700 worker root $work"
    base=$(basename "$script")
    family=$(family_for_basename "$base")
    expected=$(expected_gate_skip_for_family "$family")
    printf 'FM_TEST_BEGIN %s %s family=%s expected_gate_skip=%s\n' \
      "$(now_iso)" "$script" "$family" "$expected"
    (
      trap - EXIT HUP INT TERM
      set +e
      export TMPDIR="$work/tmp"
      export TMP="$work/tmp"
      unset FM_HOME FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_ROOT_OVERRIDE \
        FM_PROJECTS_OVERRIDE FM_CONFIG_OVERRIDE FM_BACKEND 2>/dev/null || true
      cd "$ROOT" || exit 1
      begin_ms=$(now_ms)
      set +e
      run_script_bounded "$script" "$work/output" 0 "w$worker_n"
      rc=$?
      set -e
      end_ms=$(now_ms)
      duration=$((end_ms - begin_ms))
      if [ "$duration" -lt 0 ]; then
        duration=0
      fi
      printf '%s\n' "$duration" >"$work/duration_ms"
      printf '%s\n' "$rc" >"$work/exit"
      exit 0
    ) &
    worker_pid=$!
    WORKER_PIDS[worker_n]=$worker_pid
    WORKER_IDX[worker_n]=$worker_n
    WORKER_SCRIPTS[worker_n]=$script
    active_workers=$((active_workers + 1))
  done
  while [ "$active_workers" -gt 0 ]; do
    wait_one_completed_job_worker
  done
  build_lock_release
  # Unproven remainder, after every concurrent worker has finished.
  for script in "${SERIAL_TAIL_SCRIPTS[@]+"${SERIAL_TAIL_SCRIPTS[@]}"}"; do
    run_one_serial "$script"
  done
fi

RUN_FINISHED_ISO=$(now_iso)
RUN_FINISHED_MS=$(now_ms)
RUN_DURATION=$((RUN_FINISHED_MS - RUN_STARTED_MS))
if [ "$RUN_DURATION" -lt 0 ]; then
  RUN_DURATION=0
fi

printf 'FM_TEST_SUMMARY total=%s failed=%s skipped_gate=%s duration_ms=%s\n' \
  "$TOTAL" "$FAILED" "$SKIPPED_GATE" "$RUN_DURATION"

if [ -s "$FAMILIES_TSV" ]; then
  # Stable family summary order by name.
  sort -t$'\t' -k1,1 "$FAMILIES_TSV" | while IFS=$'\t' read -r name count duration failed_count; do
    printf 'FM_TEST_SUMMARY_FAMILY family=%s count=%s duration_ms=%s failed=%s\n' \
      "$name" "$count" "$duration" "$failed_count"
  done
fi

# Slowest scripts (top 15) from records.
if [ -s "$RECORDS" ]; then
  rank=1
  sort -t$'\t' -k5,5nr "$RECORDS" | head -n 15 | while IFS=$'\t' read -r path _family _expected _rc duration _gate; do
    printf 'FM_TEST_SLOWEST rank=%s script=%s duration_ms=%s\n' \
      "$rank" "$path" "$duration"
    rank=$((rank + 1))
  done
fi

if [ -n "$JSON_PATH" ]; then
  mkdir -p "$(dirname "$JSON_PATH")"
  # Families file may be unsorted; write_json reads as-is (deterministic sort in python).
  if [ -s "$FAMILIES_TSV" ]; then
    sort -t$'\t' -k1,1 "$FAMILIES_TSV" -o "$FAMILIES_TSV"
  else
    : >"$FAMILIES_TSV"
  fi
  set +e
  write_json_artifact "$JSON_PATH" \
    "$RUN_STARTED_ISO" "$RUN_FINISHED_ISO" "$RUN_ID" \
    "$TOTAL" "$FAILED" "$SKIPPED_GATE" "$RUN_DURATION" \
    "$SELECTION_DESC" "$RECORDS" "$FAMILIES_TSV"
  json_rc=$?
  set -e
  if [ "$json_rc" -eq 0 ]; then
    log "wrote timing artifact: $JSON_PATH"
  else
    log "timing artifact finalization failed: $JSON_PATH"
    AGG_RC=1
  fi
fi

if [ -n "$MAX_WALL_MS" ]; then
  # Time spent waiting in line for the build lock is other workers' work, not
  # this run's, so the budget measures the run without it.
  BUDGET_DURATION=$((RUN_DURATION - BUILD_LOCK_WAIT_MS))
  [ "$BUDGET_DURATION" -ge 0 ] || BUDGET_DURATION=0
  printf 'FM_TEST_BUDGET max_wall_ms=%s duration_ms=%s lock_wait_ms=%s\n' \
    "$MAX_WALL_MS" "$BUDGET_DURATION" "$BUILD_LOCK_WAIT_MS"
  if [ "$BUDGET_DURATION" -gt "$MAX_WALL_MS" ]; then
    log "wall-clock budget exceeded: ${BUDGET_DURATION}ms > ${MAX_WALL_MS}ms for $SELECTION_DESC"
    AGG_RC=1
  fi
fi

exit "$AGG_RC"
