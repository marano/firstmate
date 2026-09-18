#!/usr/bin/env bash
# fm-operational-input.sh - canonical Firstmate operational-input protocol.
#
# This file is both a source-safe shell library and the cross-language CLI used
# by JavaScript and TypeScript integrations. It is the single owner of current
# construction, current parsing, and narrow pre-protocol transcript parsing.
#
# Current generic wire form:
#   U+2063 FIRSTMATE_OP: v1 <kind>: <body>
#
# The landed U+2063 + "FIRSTMATE_OP: " prefix is permanent compatibility.
# The version and kind header make current inputs structurally typed without
# deriving provenance from body prose. The established from-firstmate routing
# marker remains a current compatibility carrier because already-running
# secondmates have its leading label in their charter context.
#
# Tailed kinds (FM_OPERATIONAL_TAILED_KINDS) are typed into a composer a human
# also uses, so their input can be cut from the front and submitted later. They
# also END with a trailing sentinel after one space:
#   U+2063 /FIRSTMATE_OP: v1 <kind>
# A leading header proves machine origin; so does the trailing sentinel alone,
# which survives a front truncation that destroyed the header. `provenance`
# names that case `truncated`: machine text that lost its header, never
# ordinary input. Only a sentinel that ends the input counts; one followed by
# more text is ordinary input that quotes or continues it.
#
# CLI:
#   fm-operational-input.sh encode <kind>  # body on stdin, encoded input stdout
#   fm-operational-input.sh kind           # current input on stdin, kind stdout
#   fm-operational-input.sh classify       # current or legacy input on stdin
#   fm-operational-input.sh body           # current generic input on stdin
#   fm-operational-input.sh provenance     # any input on stdin: operational|truncated
#   fm-operational-input.sh --help
#
# All successful data commands print exactly one value and no diagnostics.
# A non-match exits 1 silently. Invalid use exits 2. Bash 3.2 compatible.

FM_OPERATIONAL_MARK=$'\xE2\x81\xA3'
FM_OPERATIONAL_PREFIX="${FM_OPERATIONAL_MARK}FIRSTMATE_OP: "
FM_OPERATIONAL_VERSION=v1
FM_OPERATIONAL_HEADER_PREFIX="${FM_OPERATIONAL_PREFIX}${FM_OPERATIONAL_VERSION} "
FM_OPERATIONAL_KINDS='session-start watcher turn-end-guard away-supervisor launch-brief branch-outcome'
FM_OPERATIONAL_TAILED_KINDS='away-supervisor'
FM_OPERATIONAL_TAIL_PREFIX="${FM_OPERATIONAL_MARK}/FIRSTMATE_OP: ${FM_OPERATIONAL_VERSION} "

# Compatibility name retained for the away-mode owner and its tests.
# shellcheck disable=SC2034 # Public source-library variable used by callers.
FM_INJECT_MARK=$FM_OPERATIONAL_MARK

# The from-firstmate carrier stays byte-compatible with live secondmate charter
# context while this owner supplies its construction and structural kind.
FM_FROMFIRST_LABEL='[fm-from-firstmate]'
FM_FROMFIRST_SEPARATOR=$FM_OPERATIONAL_MARK
FM_FROMFIRST_MARK="${FM_FROMFIRST_LABEL}${FM_FROMFIRST_SEPARATOR}"

fm_operational_kind_is_current() {  # <kind>
  case " $FM_OPERATIONAL_KINDS " in
    *" $1 "*) return 0 ;;
  esac
  return 1
}

fm_operational_kind_is_tailed() {  # <kind>
  case " $FM_OPERATIONAL_TAILED_KINDS " in
    *" $1 "*) return 0 ;;
  esac
  return 1
}

fm_operational_input_encode() {  # <generic-kind> <body> <result-var>
  local kind=${1-} body=${2-} result_var=${3-} tail=""
  [ -n "$result_var" ] || return 2
  fm_operational_kind_is_current "$kind" || return 2
  [ -n "$body" ] || return 2
  fm_operational_kind_is_tailed "$kind" && tail=" ${FM_OPERATIONAL_TAIL_PREFIX}${kind}"
  printf -v "$result_var" '%s%s: %s%s' "$FM_OPERATIONAL_HEADER_PREFIX" "$kind" "$body" "$tail"
}

# The tailed kind whose trailing sentinel ends <message>, ignoring trailing
# whitespace a composer or transport may add; 1 when none does.
fm_operational_input_tail_kind() {  # <message> <result-var>
  local message=${1-} result_var=${2-} trimmed kind
  [ -n "$result_var" ] || return 2
  trimmed=${message%"${message##*[![:space:]]}"}
  for kind in $FM_OPERATIONAL_TAILED_KINDS; do
    case "$trimmed" in
      *"${FM_OPERATIONAL_TAIL_PREFIX}${kind}")
        printf -v "$result_var" '%s' "$kind"
        return 0
        ;;
    esac
  done
  return 1
}

# Machine provenance of any input: `operational` when it opens with a current
# or legacy operational header, `truncated` when it has no header but ends with
# a tailed kind's trailing sentinel (a front-truncated operational input), and
# 1 for ordinary input. Header first, so a back-truncated input that kept its
# header stays operational. A header anywhere later in the input is ordinary
# text quoting a whole operational input, never a truncation, which removes it.
fm_operational_input_provenance() {  # <message> <result-var>
  local message=${1-} result_var=${2-} parsed
  [ -n "$result_var" ] || return 2
  if fm_operational_input_classify "$message" parsed && [ -n "$parsed" ]; then
    printf -v "$result_var" '%s' operational
    return 0
  fi
  case "$message" in
    *"$FM_OPERATIONAL_PREFIX"*) return 1 ;;
  esac
  if fm_operational_input_tail_kind "$message" parsed && [ -n "$parsed" ]; then
    printf -v "$result_var" '%s' truncated
    return 0
  fi
  return 1
}

fm_operational_input_construct() {  # <kind> <body> <result-var>
  local kind=${1-} body=${2-} result_var=${3-}
  [ -n "$result_var" ] && [ -n "$body" ] || return 2
  if [ "$kind" = from-firstmate ]; then
    fm_message_mark_from_firstmate "$body" "$result_var"
    return
  fi
  fm_operational_input_encode "$kind" "$body" "$result_var"
}

fm_operational_generic_kind() {  # <message> <result-var>
  local message=${1-} result_var=${2-} remainder parsed_kind body
  [ -n "$result_var" ] || return 2
  case "$message" in
    "$FM_OPERATIONAL_HEADER_PREFIX"*': '?*) ;;
    *) return 1 ;;
  esac
  remainder=${message#"$FM_OPERATIONAL_HEADER_PREFIX"}
  parsed_kind=${remainder%%': '*}
  fm_operational_kind_is_current "$parsed_kind" || return 1
  body=${remainder#"${parsed_kind}: "}
  [ "$body" != "$remainder" ] && [ -n "$body" ] || return 1
  printf -v "$result_var" '%s' "$parsed_kind"
}

fm_operational_input_kind() {  # <message> <result-var>
  local message=${1-} result_var=${2-} current_kind
  [ -n "$result_var" ] || return 2
  if fm_operational_generic_kind "$message" current_kind; then
    printf -v "$result_var" '%s' "$current_kind"
    return 0
  fi
  case "$message" in
    "$FM_FROMFIRST_MARK"?*)
      printf -v "$result_var" '%s' from-firstmate
      return 0
      ;;
  esac
  return 1
}

fm_operational_input_body() {  # <current-message> <result-var>
  local message=${1-} result_var=${2-} current_kind parsed_body
  [ -n "$result_var" ] || return 2
  if fm_operational_generic_kind "$message" current_kind; then
    parsed_body=${message#"${FM_OPERATIONAL_HEADER_PREFIX}${current_kind}: "}
    if fm_operational_kind_is_tailed "$current_kind"; then
      parsed_body=${parsed_body%" ${FM_OPERATIONAL_TAIL_PREFIX}${current_kind}"}
    fi
    printf -v "$result_var" '%s' "$parsed_body"
    return 0
  fi
  case "$message" in
    "$FM_FROMFIRST_MARK"?*)
      parsed_body=${message#"$FM_FROMFIRST_MARK"}
      printf -v "$result_var" '%s' "$parsed_body"
      return 0
      ;;
  esac
  return 1
}

# Historical payload literals are intentionally isolated below this line.
# They exist only for persisted pre-protocol transcripts and must never be used
# by current producers or current-path tests.
# shellcheck disable=SC2016 # Backticks are literal historical prompt markup.
FM_LEGACY_SESSIONSTART='Run `bin/fm-session-start.sh` now, exactly once, before executing any other instructions.'
FM_LEGACY_WATCHER_PREFIX='FIRSTMATE WATCHER WAKE: '
FM_LEGACY_WATCHER_SUFFIX=$'\n\nRun bin/fm-wake-drain.sh first and handle the queued wake. Watcher continuity is extension-owned.'
FM_LEGACY_TURNEND_PREFIX=$'TURN WOULD END BLIND - supervision is off. The watcher cycle is missing, failed, or unhealthy. Follow the harness recovery instruction below before ending the turn.\n\n'
FM_LEGACY_AWAY_PREFIX="${FM_OPERATIONAL_MARK}Supervisor escalate ("

fm_legacy_operational_input_kind() {  # <message> <result-var>
  local message=${1-} result_var=${2-}
  [ -n "$result_var" ] || return 2

  # PR 899 landed an untyped FIRSTMATE_OP prefix. Its subtype cannot be
  # recovered without body prose, so it is explicitly generic.
  case "$message" in
    "$FM_OPERATIONAL_PREFIX"?*)
      printf -v "$result_var" '%s' legacy-operational
      return 0
      ;;
  esac

  if [ "$message" = "$FM_LEGACY_SESSIONSTART" ]; then
    printf -v "$result_var" '%s' session-start
    return 0
  fi
  case "$message" in
    "$FM_LEGACY_AWAY_PREFIX"*)
      printf -v "$result_var" '%s' away-supervisor
      return 0
      ;;
    "$FM_LEGACY_WATCHER_PREFIX"*"$FM_LEGACY_WATCHER_SUFFIX")
      [ "${#message}" -gt "$(( ${#FM_LEGACY_WATCHER_PREFIX} + ${#FM_LEGACY_WATCHER_SUFFIX} ))" ] || return 1
      printf -v "$result_var" '%s' watcher
      return 0
      ;;
    "$FM_LEGACY_TURNEND_PREFIX"?*)
      printf -v "$result_var" '%s' turn-end-guard
      return 0
      ;;
  esac
  return 1
}

fm_operational_input_classify() {  # <message> <result-var>
  local message=${1-} result_var=${2-} classified_kind
  [ -n "$result_var" ] || return 2
  if fm_operational_input_kind "$message" classified_kind ||
     fm_legacy_operational_input_kind "$message" classified_kind; then
    printf -v "$result_var" '%s' "$classified_kind"
    return 0
  fi
  return 1
}

fm_message_from_firstmate() {  # <message>
  local kind
  fm_operational_input_kind "${1-}" kind && [ "$kind" = from-firstmate ]
}

fm_message_mark_from_firstmate() {  # <message> <result-var>
  local message=${1-} result_var=${2-} transformed
  [ -n "$result_var" ] || return 2
  if fm_message_from_firstmate "$message"; then
    transformed=$message
  else
    transformed="${FM_FROMFIRST_MARK}${message}"
  fi
  printf -v "$result_var" '%s' "$transformed"
}

fm_operational_read_stdin() {  # <result-var>
  local result_var=${1-} value
  [ -n "$result_var" ] || return 2
  value=$(cat; printf x)
  value=${value%x}
  printf -v "$result_var" '%s' "$value"
}

fm_operational_usage() {
  cat <<'EOF'
Usage:
  bin/fm-operational-input.sh encode <kind>  # body on stdin
  bin/fm-operational-input.sh kind           # current input on stdin
  bin/fm-operational-input.sh classify       # current or legacy input on stdin
  bin/fm-operational-input.sh body           # current input on stdin
  bin/fm-operational-input.sh provenance     # any input on stdin

Current construction kinds:
  session-start watcher turn-end-guard away-supervisor from-firstmate launch-brief
  branch-outcome

The from-firstmate kind uses its established live-charter-compatible carrier.
Tailed kinds (away-supervisor) also end with a trailing sentinel; provenance
prints operational for a header, truncated for a trailing sentinel alone.
EOF
}

fm_operational_main() {
  local command=${1-} argument=${2-} input output
  case "$command" in
    -h|--help|help)
      fm_operational_usage
      ;;
    encode)
      [ "$#" -eq 2 ] || return 2
      fm_operational_read_stdin input || return 2
      fm_operational_input_construct "$argument" "$input" output || return 2
      printf '%s' "$output"
      ;;
    kind)
      [ "$#" -eq 1 ] || return 2
      fm_operational_read_stdin input || return 2
      fm_operational_input_kind "$input" output || return 1
      printf '%s\n' "$output"
      ;;
    classify)
      [ "$#" -eq 1 ] || return 2
      fm_operational_read_stdin input || return 2
      fm_operational_input_classify "$input" output || return 1
      printf '%s\n' "$output"
      ;;
    body)
      [ "$#" -eq 1 ] || return 2
      fm_operational_read_stdin input || return 2
      fm_operational_input_body "$input" output || return 1
      printf '%s' "$output"
      ;;
    provenance)
      [ "$#" -eq 1 ] || return 2
      fm_operational_read_stdin input || return 2
      fm_operational_input_provenance "$input" output || return 1
      printf '%s\n' "$output"
      ;;
    *)
      fm_operational_usage >&2
      return 2
      ;;
  esac
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  fm_operational_main "$@"
  exit $?
fi
