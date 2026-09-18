#!/usr/bin/env bash
# Canonical current and isolated legacy operational-input protocol matrices.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

OWNER="$ROOT/bin/fm-operational-input.sh"
# shellcheck source=/dev/null
. "$OWNER"

cleanup() {
  fm_test_cleanup
}
trap cleanup EXIT

classify_cli() {
  printf '%s' "$1" | "$OWNER" classify 2>/dev/null
}

kind_cli() {
  printf '%s' "$1" | "$OWNER" kind 2>/dev/null
}

test_current_generic_matrix() {
  local kind body encoded parsed stripped prefix_hex
  prefix_hex=$(printf '%s' "$FM_OPERATIONAL_PREFIX" | od -An -tx1 | tr -d ' \n')
  [ "$prefix_hex" = e281a346495253544d4154455f4f503a20 ] \
    || fail "current operational prefix lost the landed U+2063 FIRSTMATE_OP bytes: $prefix_hex"

  for kind in session-start watcher turn-end-guard away-supervisor launch-brief branch-outcome; do
    body="CURRENT_BODY_FOR_${kind}"
    fm_operational_input_encode "$kind" "$body" encoded \
      || fail "could not encode current $kind fixture"
    fm_operational_input_kind "$encoded" parsed \
      || fail "could not parse current $kind fixture"
    [ "$parsed" = "$kind" ] \
      || fail "current $kind fixture became $parsed"
    [ "$(kind_cli "$encoded")" = "$kind" ] \
      || fail "cross-language CLI lost current $kind"
    [ "$(classify_cli "$encoded")" = "$kind" ] \
      || fail "classifier lost current $kind"
    fm_operational_input_body "$encoded" stripped \
      || fail "could not recover current $kind body"
    [ "$stripped" = "$body" ] \
      || fail "current $kind body changed during encode/parse"
  done
  pass "operational input: every current generic envelope retains its exact structured kind"
}

test_current_from_firstmate_carrier() {
  local encoded parsed separator
  separator=$(printf '\342\201\243')
  fm_message_mark_from_firstmate "corr=0123456789abcdef inspect the report" encoded
  [ "${encoded#"[fm-from-firstmate]$separator"}" != "$encoded" ] \
    || fail "from-firstmate lost its live-charter-compatible leading carrier"
  fm_operational_input_kind "$encoded" parsed \
    || fail "from-firstmate current carrier did not parse"
  [ "$parsed" = from-firstmate ] \
    || fail "from-firstmate current carrier became $parsed"
  [ "$(classify_cli "$encoded")" = from-firstmate ] \
    || fail "cross-language classifier lost from-firstmate"
  pass "operational input: the established from-firstmate carrier remains structurally typed and byte-compatible"
}

test_landed_untyped_prefix_is_explicitly_legacy() {
  local untyped parsed
  untyped="${FM_OPERATIONAL_PREFIX}body whose historical subtype is unknowable"
  fm_legacy_operational_input_kind "$untyped" parsed \
    || fail "landed untyped FIRSTMATE_OP input was not retained"
  [ "$parsed" = legacy-operational ] \
    || fail "landed untyped FIRSTMATE_OP input falsely became $parsed"
  ! fm_operational_input_kind "$untyped" parsed \
    || fail "untyped FIRSTMATE_OP input passed the current typed parser"
  [ "$(classify_cli "$untyped")" = legacy-operational ] \
    || fail "CLI did not expose the untyped prefix as legacy-operational"
  pass "operational input: untyped landed FIRSTMATE_OP transcripts are explicit legacy-operational input"
}

test_isolated_legacy_matrix() {
  local watcher turnend away parsed
  watcher="${FM_LEGACY_WATCHER_PREFIX}signal: legacy${FM_LEGACY_WATCHER_SUFFIX}"
  turnend="${FM_LEGACY_TURNEND_PREFIX}watcher: FAILED - legacy"
  away="${FM_LEGACY_AWAY_PREFIX}1 event(s)): done: legacy"

  for fixture in \
    "session-start|$FM_LEGACY_SESSIONSTART" \
    "watcher|$watcher" \
    "turn-end-guard|$turnend" \
    "away-supervisor|$away"
  do
    expected=${fixture%%|*}
    message=${fixture#*|}
    ! fm_operational_input_kind "$message" parsed \
      || fail "legacy $expected fixture leaked into the current parser"
    fm_legacy_operational_input_kind "$message" parsed \
      || fail "legacy $expected fixture was not recognized"
    [ "$parsed" = "$expected" ] \
      || fail "legacy $expected fixture became $parsed"
  done
  pass "operational input: historical prose compatibility is isolated from current parsing"
}

test_genuine_near_misses_remain_unclassified() {
  local marker fixture parsed
  marker=$FM_OPERATIONAL_MARK
  while IFS= read -r fixture || [ -n "$fixture" ]; do
    [ -n "$fixture" ] || continue
    ! fm_operational_input_classify "$fixture" parsed \
      || fail "genuine near miss was classified as $parsed: $fixture"
    [ -z "$(classify_cli "$fixture" || true)" ] \
      || fail "CLI classified a genuine near miss: $fixture"
  done <<EOF
Captain quote: ${FM_OPERATIONAL_PREFIX}v1 watcher
FIRSTMATE_OP: v1 watcher
$marker arbitrary captain text
Captain quote: $FM_LEGACY_SESSIONSTART
${FM_LEGACY_SESSIONSTART} Please explain this sentence.
FIRSTMATE WATCHER WAKE: can you explain this phrase?
TURN WOULD END BLIND - can you make this warning friendlier?
Supervisor escalate (1 event(s)): is this wording clear?
[fm-from-firstmate] inspect this visible label
EOF
  pass "operational input: quoted, ASCII-only, arbitrary-U+2063, altered-legacy, and label-only near misses stay genuine"
}

test_cross_language_adapter_uses_the_owner() {
  local encoded parsed
  encoded=$(FM_TEST_ROOT="$ROOT" HELPER="$ROOT/.opencode/plugins/lib/fm-operational-input.js" \
    node --input-type=module <<'JS'
import { pathToFileURL } from "node:url";
const { encodeFirstmateOperationalInput } = await import(pathToFileURL(process.env.HELPER).href);
process.stdout.write(await encodeFirstmateOperationalInput(process.env.FM_TEST_ROOT, "watcher", "CROSS_LANGUAGE_BODY"));
JS
  ) || fail "OpenCode cross-language adapter could not invoke the canonical owner"
  fm_operational_input_kind "$encoded" parsed \
    || fail "OpenCode cross-language adapter returned an invalid current envelope"
  [ "$parsed" = watcher ] \
    || fail "OpenCode cross-language adapter changed watcher to $parsed"
  pass "operational input: the OpenCode adapter constructs through the canonical owner"
}

test_invalid_current_encodings_are_rejected() {
  local output
  output=$(printf 'body' | "$OWNER" encode legacy-operational 2>/dev/null) \
    && fail "legacy-operational was accepted as a current producer kind"
  [ -z "$output" ] || fail "invalid current kind printed protocol data"
  output=$(printf '' | "$OWNER" encode watcher 2>/dev/null) \
    && fail "empty current operational body was accepted"
  [ -z "$output" ] || fail "empty current body printed protocol data"
  pass "operational input: current construction rejects legacy kinds and empty bodies"
}

# A digest typed into a composer a human also uses can be cut from the front
# and submitted later. The tailed kind ends with a trailing sentinel so the
# surviving fragment still proves machine origin; every other kind keeps its
# exact landed bytes.
test_tailed_kind_ends_with_trailing_sentinel() {
  local kind encoded tail
  tail=" ${FM_OPERATIONAL_MARK}/FIRSTMATE_OP: v1 away-supervisor"
  fm_operational_input_encode away-supervisor "Supervisor escalate (1 event(s)): done" encoded \
    || fail "could not encode an away-supervisor digest"
  case "$encoded" in
    *"$tail") ;;
    *) fail "an away-supervisor digest lacks the trailing sentinel: $encoded" ;;
  esac
  [ "$(printf '%s' "$encoded" | "$OWNER" body)" = "Supervisor escalate (1 event(s)): done" ] \
    || fail "the CLI body read kept the trailing sentinel"
  for kind in session-start watcher turn-end-guard launch-brief branch-outcome; do
    fm_operational_input_encode "$kind" "BODY" encoded || fail "could not encode $kind"
    [ "$encoded" = "${FM_OPERATIONAL_HEADER_PREFIX}${kind}: BODY" ] \
      || fail "untailed kind $kind changed its landed bytes: $encoded"
  done
  pass "operational input: the away digest ends with a trailing sentinel and untailed kinds keep their bytes"
}

provenance_cli() {
  printf '%s' "$1" | "$OWNER" provenance 2>/dev/null
}

# A front truncation removes the header, and with it the only proof the input
# was machine text. The trailing sentinel alone is that proof: a digest cut
# anywhere in front of its sentinel reads truncated, while a whole digest,
# legacy input, and a header-bearing but back-truncated digest stay operational.
test_front_truncated_digest_reads_truncated() {
  local encoded cut fragment
  fm_operational_input_encode away-supervisor \
    "Supervisor escalate (1 event(s)): fm-main-green.status: working: nothing outside the five files touched (pre-read; re-arm not needed)" encoded \
    || fail "could not encode the fixture digest"
  [ "$(provenance_cli "$encoded")" = operational ] || fail "a whole digest is not operational"
  [ "$(provenance_cli "${encoded% *}")" = operational ] \
    || fail "a back-truncated digest lost the provenance its header still proves"
  [ "$(provenance_cli "${FM_LEGACY_AWAY_PREFIX}1 event(s)): done")" = operational ] \
    || fail "a legacy away digest is not operational"
  for cut in 1 3 17 40 90; do
    fragment=${encoded:$cut}
    [ "$(provenance_cli "$fragment")" = truncated ] \
      || fail "a digest cut $cut characters from the front is not truncated: $fragment"
  done
  # The incident shape: cut mid-word, and a composer or transport may leave
  # trailing whitespace behind the sentinel.
  fragment="side the five files touched (pre-read; re-arm not needed) ${FM_OPERATIONAL_MARK}/FIRSTMATE_OP: v1 away-supervisor"
  [ "$(provenance_cli "$fragment")" = truncated ] || fail "the mid-word incident fragment is not truncated"
  [ "$(provenance_cli "$fragment"$'\n')" = truncated ] || fail "a trailing newline hid the sentinel"
  [ "$(provenance_cli "$fragment  ")" = truncated ] || fail "trailing spaces hid the sentinel"
  pass "operational input: a digest cut from the front reads truncated on its trailing sentinel alone"
}

# Refusal: ordinary input must never read as machine text. Only a sentinel that
# ENDS a header-less input counts; the sentinel followed by more text, a whole
# digest quoted after ordinary text, and ASCII look-alikes without U+2063 stay
# ordinary.
test_ordinary_input_never_reads_truncated() {
  local encoded tail fixture parsed
  fm_operational_input_encode away-supervisor "Supervisor escalate (1 event(s)): done" encoded \
    || fail "could not encode the fixture digest"
  tail="${FM_OPERATIONAL_MARK}/FIRSTMATE_OP: v1 away-supervisor"
  for fixture in \
    "I'm back, what happened overnight?" \
    "status update please" \
    "cut digest text ${tail} and then the captain kept typing" \
    "Captain quote: $encoded" \
    "what does /FIRSTMATE_OP: v1 away-supervisor mean" \
    "ends with the ASCII look-alike /FIRSTMATE_OP: v1 away-supervisor" \
    "unknown kind ${FM_OPERATIONAL_MARK}/FIRSTMATE_OP: v1 watcher"
  do
    fm_operational_input_provenance "$fixture" parsed \
      && fail "ordinary input read as $parsed: $fixture"
    [ -z "$(provenance_cli "$fixture" || true)" ] || fail "the CLI gave ordinary input a provenance: $fixture"
  done
  pass "operational input: ordinary, quoting, continued, and look-alike input never reads as machine text"
}

test_current_generic_matrix
test_tailed_kind_ends_with_trailing_sentinel
test_front_truncated_digest_reads_truncated
test_ordinary_input_never_reads_truncated
test_current_from_firstmate_carrier
test_landed_untyped_prefix_is_explicitly_legacy
test_isolated_legacy_matrix
test_genuine_near_misses_remain_unclassified
test_cross_language_adapter_uses_the_owner
test_invalid_current_encodings_are_rejected
