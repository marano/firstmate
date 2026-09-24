#!/usr/bin/env bash
# fm-stock-bash-lane.sh - the single owner of what the stock macOS Bash 3.2 lane
# runs, so CI's `macos-stock-bash` shards and a local run before push execute the
# same checks and cannot drift apart.
#
# Usage:
#   fm-stock-bash-lane.sh [--shard <k>/<n>] [--json <path>]
#                                 run the lane, or one CI shard of it
#   fm-stock-bash-lane.sh [--shard <k>/<n>] --list
#                                 print the test scripts that runs
#   fm-stock-bash-lane.sh [--shard <k>/<n>] --required-tools
#                                 print the pinned linters those tests need,
#                                 one per line, so CI installs exactly those
#                                 and no others
#   fm-stock-bash-lane.sh --ok-count-pins
#                                 print the lane's case-count pins, one
#                                 <script>=<count> per line
#   fm-stock-bash-lane.sh --help
#
# Run it locally before pushing a change to firstmate's shell, and treat a
# failure as a stop:
#
#   bin/fm-stock-bash-lane.sh
#
# Do not wrap it in `mutex`: bin/fm-test-run.sh already takes the machine-wide
# build lock once per script, and the retained regression below takes its own
# hold, so other workers' builds go between two tests instead of queueing behind
# the whole ~28 minute lane.
#
# It is where the day's CI-only failures landed. The lane does not only vary
# the shell: it runs 130-odd scripts a targeted local run never selects, and it
# pins case counts that a new test case changes. A local run of those same
# checks turns a ~20 minute CI round trip into a failure before push. The CI
# job still runs; this shortens the feedback loop and does not replace it.
#
# What it runs, in order:
#   1. Puts a private shim directory holding `bash -> /bin/bash` in front of
#      PATH, pinning ONLY Bash and leaving every other tool at its normal
#      version, then refuses unless both this script and the `bash` its tests
#      will run under report stock 3.2.57.
#   2. A `bash -n` parse sweep over the full canonical shell set that
#      `bin/fm-lint.sh --list-files` reports in CI context.
#   3. `bin/fm-test-run.sh --lane stock-bash`, which alone owns which tests the
#      lane selects and why each excluded test is left out, with the lane's
#      per-script bound and pinned case counts.
#   4. The one `tests/fm-public-followup.test.sh` regression the lane keeps by
#      name although that file is cost-excluded.
#
# CI runs the lane as separate macOS shards, one job per `--shard <k>/<n>` with
# <n> the matrix's strategy.job-total. bin/fm-test-run.sh owns the shard count
# and the packing, as its `stock-bash-<k>of<n>` lanes, and refuses an <n> that
# disagrees, so a shard is refused before it runs anything and a matrix resized
# on its own cannot leave part of the lane unrun. Step 3 runs that shard's share
# with every case-count pin; steps 2 and 4 run only in shard EXTRAS_SHARD. With
# no --shard it runs the whole lane, which is what a local run before push wants.
# `bin/fm-test-run.sh --check-coverage` proves the shards partition the lane and
# that every pinned script lands in exactly one of them.
#
# It never installs anything: `jq` and `tasks-axi` must already be on PATH, as
# must the repository-pinned linters the lint suites need.
# CI installs them in the step before this one, from this script's own
# `--required-tools` answer, so the job downloads only what this lane's
# selection actually invokes.
# docs/verification/stock-bash-lane.md records the measurements behind the
# lane's selection and what it still cannot cover.
#
# Environment:
#   FM_STOCK_BASH   the stock Bash to pin (default /bin/bash)
set -u

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
SELF="$SELF_DIR/fm-stock-bash-lane.sh"
ROOT="$(cd "$SELF_DIR/.." && pwd -P)"
cd "$ROOT" || exit 1

STOCK_BASH=${FM_STOCK_BASH:-/bin/bash}
# The one regression retained from the cost-excluded public-followup file.
PF_TEST=tests/fm-public-followup.test.sh
PF_ONLY=test_first_register_succeeds_with_empty_lock_list_under_bash32
# The shard that also runs the parse sweep and the retained regression.
EXTRAS_SHARD=1

# Exact case counts, passed to every shard: exit status alone cannot see a
# script that stops printing cases while still exiting 0. A shard ignores the
# pin of a script it does not hold.
ok_count_pins() {
  printf '%s\n' \
    tests/fm-fleet-snapshot-view.test.sh=22 \
    tests/fm-bearings-snapshot.test.sh=60
}

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$SELF"
}

# GitHub renders ::error:: as an annotation; anywhere else it is noise.
lane_error() {
  if [ "${GITHUB_ACTIONS:-}" = true ]; then
    printf '::error::%s\n' "$*"
  else
    printf 'fm-stock-bash-lane: %s\n' "$*" >&2
  fi
}

# Whether this run carries the parse sweep and the retained regression.
runs_extras() {
  [ -z "$SHARD_INDEX" ] || [ "$SHARD_INDEX" = "$EXTRAS_SHARD" ]
}

list_lane() {
  "$ROOT/bin/fm-test-run.sh" --list --lane "$RUNNER_LANE" || return 1
  if runs_extras; then
    printf '%s\n' "$PF_TEST"
  fi
}

# The pinned linters this lane's complete selection needs. Asked over --list
# rather than over the stock-bash lane alone, because the retained
# public-followup regression is part of what its shard runs and so part of what
# that job must have installed. bin/fm-test-run.sh owns which test needs which
# tool.
required_tools() {
  local scripts
  scripts=$(list_lane) || return 1
  # shellcheck disable=SC2086 # One script path per line, none with whitespace.
  "$ROOT/bin/fm-test-run.sh" --list-required-tools $scripts
}

require_stock() {  # <what> <version>
  case "$2" in
    3.2.57*) return 0 ;;
  esac
  lane_error "$1 would run under Bash $2, not stock 3.2.57"
  exit 1
}

ACTION=run
JSON=
SHARD=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --help|-h) usage; exit 0 ;;
    --list|--required-tools|--ok-count-pins)
      [ "$ACTION" = run ] || { lane_error "--$ACTION and $1 cannot be combined"; exit 2; }
      ACTION=${1#--}
      shift
      ;;
    --json|--shard)
      [ "$#" -ge 2 ] || { lane_error "$1 takes a value"; exit 2; }
      if [ "$1" = --json ]; then JSON=$2; else SHARD=$2; fi
      shift 2
      ;;
    *) lane_error "unknown argument: $1 (see --help)"; exit 2 ;;
  esac
done
[ -z "$JSON" ] || [ "$ACTION" = run ] || { lane_error "--json applies only to a run"; exit 2; }

if [ "$ACTION" = ok-count-pins ]; then
  [ -z "$SHARD" ] || { lane_error "--ok-count-pins is the same for every shard; drop --shard"; exit 2; }
  ok_count_pins
  exit 0
fi

# The runner's lane for this run, which is also what refuses a shard count that
# disagrees with bin/fm-test-run.sh.
RUNNER_LANE=stock-bash
SHARD_INDEX=
if [ -n "$SHARD" ]; then
  case "$SHARD" in
    [0-9]*/[0-9]*) ;;
    *) lane_error "--shard takes <k>/<n>, got '$SHARD'"; exit 2 ;;
  esac
  SHARD_INDEX=${SHARD%%/*}
  shard_count=${SHARD#*/}
  case "$SHARD_INDEX$shard_count" in
    *[!0-9]*) lane_error "--shard takes <k>/<n>, got '$SHARD'"; exit 2 ;;
  esac
  RUNNER_LANE="stock-bash-${SHARD_INDEX}of${shard_count}"
fi

case "$ACTION" in
  list) list_lane; exit $? ;;
  required-tools) required_tools; exit $? ;;
esac

[ -x "$STOCK_BASH" ] || { lane_error "stock Bash not found at $STOCK_BASH"; exit 1; }
# shellcheck disable=SC2016 # The child shell expands its own $BASH_VERSION.
require_stock "the stock Bash at $STOCK_BASH" "$("$STOCK_BASH" -c 'printf %s "$BASH_VERSION"')"
# CI runs this body under stock Bash; a local `bash` on PATH may be newer.
case "$BASH_VERSION" in
  3.2.57*) ;;
  *)
    if [ -z "${FM_STOCK_BASH_LANE_REEXEC:-}" ]; then
      FM_STOCK_BASH_LANE_REEXEC=1 exec "$STOCK_BASH" "$SELF" "$@"
    fi
    ;;
esac
require_stock "this lane script" "$BASH_VERSION"

# Refuse a shard the runner does not pack before spending anything on it.
if [ -n "$SHARD" ] && ! "$ROOT/bin/fm-test-run.sh" --list --lane "$RUNNER_LANE" >/dev/null; then
  lane_error "shard $SHARD does not match the stock-bash shards bin/fm-test-run.sh packs (see its --list-lanes)"
  exit 2
fi

SHIM=$(mktemp -d "${TMPDIR:-/tmp}/fm-stock-bash.XXXXXX") || exit 1
trap 'rm -rf "$SHIM"' EXIT
ln -s "$STOCK_BASH" "$SHIM/bash" || exit 1
PATH="$SHIM:$PATH"
export PATH

# bin/fm-test-run.sh runs every selected script with a bare `bash`, so this is a
# stock-Bash lane only while `bash` resolves to the shim. Refuse otherwise.
require_stock "selected tests" "$(bash -c 'printf %s "$BASH_VERSION"')"
bash --version | head -1

command -v jq >/dev/null || { lane_error "jq is required"; exit 1; }
command -v tasks-axi >/dev/null || { lane_error "tasks-axi is required for the stock Bash regressions"; exit 1; }

if runs_extras; then
  parse_fail=0
  while IFS= read -r f; do
    bash -n "$f" || { lane_error "stock macOS Bash 3.2 failed to parse $f"; parse_fail=1; }
  done < <(CI=true "$ROOT/bin/fm-lint.sh" --list-files)
  [ "$parse_fail" -eq 0 ] || { lane_error "stock macOS Bash 3.2 parse sweep failed"; exit 1; }
fi

# A per-script bound well clear of the slowest member turns a HUNG script into
# a named failure instead of an unattributed job cancellation at the cap. The
# slowest script measured is tests/fm-bearings-snapshot.test.sh: 321.8s in CI
# (max over 96 recent macos-stock-bash job logs) and 197.8s in a full local lane
# run on 2026-09-19. 1000s is 3.1x over the slowest CI script and still well
# under the job's cap, so a hung script fails by name rather than the job being
# cancelled with no verdict.
LANE_SCRIPT_TIMEOUT_SECS=1000
run_args=(--lane "$RUNNER_LANE" --per-script-timeout-secs "$LANE_SCRIPT_TIMEOUT_SECS")
while IFS= read -r pin; do
  run_args+=(--require-ok-count "$pin")
done < <(ok_count_pins)
[ -z "$JSON" ] || run_args+=(--json "$JSON")
"$ROOT/bin/fm-test-run.sh" "${run_args[@]}" || exit 1
runs_extras || exit 0

# The public-followup file is cost-excluded from the lane, but this lane already
# covered ONE test inside it, so that regression is retained by name rather than
# dropped with the file.
# shellcheck source=bin/fm-timeout-lib.sh
. "$ROOT/bin/fm-timeout-lib.sh"
pf_status=0
pf_output=$(fm_run_timed "$LANE_SCRIPT_TIMEOUT_SECS" "$ROOT/bin/fm-build-lock.sh" -- env FM_TEST_ONLY="$PF_ONLY" bash "$PF_TEST") || pf_status=$?
printf '%s\n' "$pf_output"
if [ "$pf_status" -eq 124 ]; then
  lane_error "$PF_TEST ($PF_ONLY) exceeded its ${LANE_SCRIPT_TIMEOUT_SECS}s bound"
  exit 1
fi
pf_count=$(printf '%s\n' "$pf_output" | grep -c '^ok - ')
[ "$pf_count" -eq 1 ] || {
  lane_error "expected 1 public-followup bash 3.2 register regression, got $pf_count"
  exit 1
}
