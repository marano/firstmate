#!/usr/bin/env bash
# Run one bounded foreground watcher checkpoint for harnesses that should not
# rely on background-task completion to wake the model.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SECONDS_ARG=${FM_CODEX_WATCH_CHECKPOINT:-180}

usage() {
  cat <<'EOF'
Usage: fm-watch-checkpoint.sh [--seconds <n>]

Run bin/fm-watch.sh in the foreground for a bounded checkpoint.
On an actionable watcher wake, pass through the watcher output and exit 0.
On a quiet checkpoint, print "checkpoint: no actionable wake within <n>s" and exit 124.
A watcher still running FM_SIGNAL_GRACE seconds (default 5) after the deadline's
TERM is killed, and that is still reported as the quiet checkpoint (exit 124).
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --seconds)
      [ "$#" -gt 1 ] || { echo "error: --seconds requires a value" >&2; exit 2; }
      SECONDS_ARG=$2
      shift 2
      ;;
    --seconds=*)
      SECONDS_ARG=${1#--seconds=}
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "error: unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

case "$SECONDS_ARG" in
  ''|*[!0-9]*) echo "error: --seconds must be a positive integer" >&2; exit 2 ;;
  0) echo "error: --seconds must be greater than zero" >&2; exit 2 ;;
esac

# The deadline's TERM can be lost: Bash 5.2 drops a trap still pending when the
# watcher's shell parses a command substitution (bin/fm-wake-lib.sh's
# "Startup-path substitutions"), and that watcher then keeps supervising while
# this checkpoint waits on it. So every mechanism below sends KILL this many
# seconds after TERM, the grace the perl fallback has always read.
KILL_GRACE=${FM_SIGNAL_GRACE:-5}
case "$KILL_GRACE" in ''|*[!0-9]*|0) KILL_GRACE=5 ;; esac

OUT=$(mktemp "${TMPDIR:-/tmp}/fm-watch-checkpoint.out.XXXXXX") || exit 1
ERR=$(mktemp "${TMPDIR:-/tmp}/fm-watch-checkpoint.err.XXXXXX") || {
  rm -f "$OUT"
  exit 1
}
trap 'rm -f "$OUT" "$ERR"' EXIT

# The grace is polled inside the deadline handler rather than timed by a second
# alarm: Perl blocks SIGALRM while that handler runs, so a nested alarm never
# fired and a watcher that survived TERM held the checkpoint forever.
run_with_perl_timeout() {
  perl -e '
    use POSIX qw(WNOHANG);
    my $seconds = shift;
    my $grace = shift;
    my $pid = fork;
    die "fork failed\n" unless defined $pid;
    if (!$pid) {
      setpgrp(0, 0);
      exec @ARGV;
      die "exec failed: $!\n";
    }
    local $SIG{ALRM} = sub {
      kill "TERM", -$pid;
      for (1 .. $grace * 10) {
        exit 124 if waitpid($pid, WNOHANG) == $pid;
        select undef, undef, undef, 0.1;
      }
      kill "KILL", -$pid;
      waitpid $pid, 0;
      exit 124;
    };
    alarm $seconds;
    waitpid $pid, 0;
    alarm 0;
    exit($? >> 8);
  ' "$SECONDS_ARG" "$KILL_GRACE" "$SCRIPT_DIR/fm-watch.sh"
}

START=$SECONDS
set +e
if command -v timeout >/dev/null 2>&1; then
  timeout -k "$KILL_GRACE" "$SECONDS_ARG" "$SCRIPT_DIR/fm-watch.sh" >"$OUT" 2>"$ERR"
  RC=$?
elif command -v gtimeout >/dev/null 2>&1; then
  gtimeout -k "$KILL_GRACE" "$SECONDS_ARG" "$SCRIPT_DIR/fm-watch.sh" >"$OUT" 2>"$ERR"
  RC=$?
else
  run_with_perl_timeout >"$OUT" 2>"$ERR"
  RC=$?
fi
set -e

if grep -E '^(signal:|stale:|check:|heartbeat($|:))' "$OUT" >/dev/null 2>&1; then
  cat "$OUT"
  [ ! -s "$ERR" ] || cat "$ERR" >&2
  exit 0
fi

if grep -E '^watcher: already running' "$OUT" "$ERR" >/dev/null 2>&1; then
  [ ! -s "$OUT" ] || cat "$OUT"
  [ ! -s "$ERR" ] || cat "$ERR" >&2
  echo "checkpoint: watcher is already running outside this foreground checkpoint" >&2
  exit 1
fi

if [ "$RC" -eq 137 ] && [ $((SECONDS - START)) -ge "$SECONDS_ARG" ]; then
  echo "checkpoint: watcher survived the deadline TERM and was killed" >&2
  RC=124
fi

if [ "$RC" -eq 124 ]; then
  printf 'checkpoint: no actionable wake within %ss\n' "$SECONDS_ARG"
  exit 124
fi

[ ! -s "$OUT" ] || cat "$OUT"
[ ! -s "$ERR" ] || cat "$ERR" >&2
exit "$RC"
