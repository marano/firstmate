#!/usr/bin/env bash
# fm-stock-bash-lane.sh - the single owner of what the stock macOS Bash 3.2 lane
# runs, so CI's `macos-stock-bash` job and a local run before push execute the
# same checks and cannot drift apart.
#
# Usage:
#   fm-stock-bash-lane.sh [--json <path>]   run the lane
#   fm-stock-bash-lane.sh --list            print the test scripts it runs
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
# the whole ~20 minute lane.
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
# It never installs anything: `jq` and `tasks-axi` must already be on PATH, as
# must the repository-pinned linters the lint suites need. CI installs them in
# the steps before this one. docs/verification/stock-bash-lane.md records the
# measurements behind the lane's selection and what it still cannot cover.
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

list_lane() {
  "$ROOT/bin/fm-test-run.sh" --list --lane stock-bash || return 1
  printf '%s\n' "$PF_TEST"
}

require_stock() {  # <what> <version>
  case "$2" in
    3.2.57*) return 0 ;;
  esac
  lane_error "$1 would run under Bash $2, not stock 3.2.57"
  exit 1
}

JSON=
case "${1:-}" in
  --help|-h) usage; exit 0 ;;
  --list)
    [ "$#" -eq 1 ] || { lane_error "--list takes no further arguments"; exit 2; }
    list_lane
    exit $?
    ;;
  --json)
    [ "$#" -eq 2 ] || { lane_error "--json takes exactly one path"; exit 2; }
    JSON=$2
    ;;
  '') ;;
  *) lane_error "unknown argument: $1 (see --help)"; exit 2 ;;
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

parse_fail=0
while IFS= read -r f; do
  bash -n "$f" || { lane_error "stock macOS Bash 3.2 failed to parse $f"; parse_fail=1; }
done < <(CI=true "$ROOT/bin/fm-lint.sh" --list-files)
[ "$parse_fail" -eq 0 ] || { lane_error "stock macOS Bash 3.2 parse sweep failed"; exit 1; }

# --require-ok-count keeps exact case counts: exit status alone cannot see a
# script that stops printing cases while still exiting 0. A per-script bound
# well clear of the slowest member turns a HUNG script into a named failure
# instead of an unattributed job cancellation at the cap.
run_args=(--lane stock-bash
  --per-script-timeout-secs 600
  --require-ok-count tests/fm-fleet-snapshot-view.test.sh=21
  --require-ok-count tests/fm-bearings-snapshot.test.sh=59)
[ -z "$JSON" ] || run_args+=(--json "$JSON")
"$ROOT/bin/fm-test-run.sh" "${run_args[@]}" || exit 1

# The public-followup file is cost-excluded from the lane, but this lane already
# covered ONE test inside it, so that regression is retained by name rather than
# dropped with the file.
pf_output=$("$ROOT/bin/fm-build-lock.sh" -- env FM_TEST_ONLY="$PF_ONLY" bash "$PF_TEST")
printf '%s\n' "$pf_output"
pf_count=$(printf '%s\n' "$pf_output" | grep -c '^ok - ')
[ "$pf_count" -eq 1 ] || {
  lane_error "expected 1 public-followup bash 3.2 register regression, got $pf_count"
  exit 1
}
