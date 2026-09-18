#!/usr/bin/env bash
# fm-lint-repair-note.sh - print how to verify a repair of a failed CI Lint job.
#
# Usage:
#   fm-lint-repair-note.sh
#   fm-lint-repair-note.sh --help
#
# CI's Lint job runs this only when bin/fm-lint.sh itself failed, so the note is
# the last thing in that job's log. That tail is what a CI-repair agent is handed
# as the failing check's evidence, which makes it the instruction surface that
# agent actually reads; no-mistakes has no repository key for CI-fix
# instructions.
#
# Why it exists. A repair agent that re-runs CI's full canonical lint locally is
# behaving reasonably - it wants to avoid spending a CI cycle on a wrong guess -
# but that run costs 15-18 minutes and several GB on a shared machine, and CI
# re-runs the identical check on the next push anyway. So the note names what to
# run instead rather than only forbidding the expensive form.
#
# Every command line it prints starts with "  $ ", and starts `mutex` first so the
# machine-wide build lock is taken: a leading `CI=true` assignment would make the
# lock stand down.
set -u

case "${1:-}" in
  --help|-h)
    awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "${BASH_SOURCE[0]}"
    exit 0
    ;;
  '') ;;
  *) printf 'fm-lint-repair-note.sh: takes no arguments (see --help)\n' >&2; exit 2 ;;
esac

cat <<'EOF'
fm-lint repair note: this job is the full-parity lint check, and it runs again on the next push.
To verify a repair locally, run the changed-file lint instead of re-running this job:
  $ mutex bin/fm-lint.sh
With no arguments on a branch it lints only the shell files the branch changed, with the same pinned ShellCheck and rules, in seconds rather than the 15-18 minutes and several GB this job's full lint costs on a shared machine.
Changed-file mode cannot judge SC1091, SC2034, SC2153 or SC2329, because they need every sourcing script in view; this job is the only place those are evaluated, so fix such a finding from its message above and let the next CI run confirm it.
Only if a full-parity local run is genuinely unavoidable, bound it to one worker, which halves its concurrent memory peak for about twice the wall time:
  $ mutex env CI=true FM_LINT_JOBS=1 bin/fm-lint.sh
Where the machine-wide build lock is not installed, drop the leading `mutex`.
EOF
