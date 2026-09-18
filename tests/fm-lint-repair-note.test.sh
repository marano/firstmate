#!/usr/bin/env bash
# Regression tests for bin/fm-lint-repair-note.sh, the note a failed CI Lint job
# prints as the last thing a CI-repair agent reads. The note is the emitted
# interface delivered to that agent, so these cases assert what it tells the
# agent to run.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

NOTE="$ROOT/bin/fm-lint-repair-note.sh"

note_commands() {
  "$NOTE" | sed -n 's/^  \$ //p'
}

test_first_command_is_the_changed_file_lint() {
  local first
  first=$(note_commands | head -1)
  assert_equals "mutex bin/fm-lint.sh" "$first" \
    "the note does not name the changed-file lint as the replacement"
  pass "the note names the changed-file lint as what to run instead"
}

test_every_command_takes_the_build_lock() {
  local cmd bad=
  while IFS= read -r cmd; do
    case "$cmd" in
      "mutex "*) ;;
      *) bad="$bad$cmd"$'\n' ;;
    esac
  done < <(note_commands)
  [ -z "$bad" ] || fail "note commands that skip or bypass the build lock:"$'\n'"$bad"
  pass "every command the note prints takes the machine-wide build lock first"
}

test_full_parity_is_only_offered_bounded() {
  local cmd seen=0
  while IFS= read -r cmd; do
    case "$cmd" in
      *CI=true*)
        seen=1
        case "$cmd" in
          *FM_LINT_JOBS=1*) ;;
          *) fail "the note offers an unbounded full-parity lint: $cmd" ;;
        esac
        ;;
    esac
  done < <(note_commands)
  [ "$seen" -eq 1 ] || fail "the note no longer names the bounded full-parity fallback"
  pass "the note offers the full-parity lint only bounded to one worker"
}

test_rejects_arguments() {
  local rc=0
  "$NOTE" extra >/dev/null 2>&1 || rc=$?
  assert_equals 2 "$rc" "the note accepted an argument"
  pass "the note refuses arguments"
}

test_first_command_is_the_changed_file_lint
test_every_command_takes_the_build_lock
test_full_parity_is_only_offered_bounded
test_rejects_arguments
