#!/usr/bin/env bash
# Regression tests for the pinned shared no-mistakes gate action.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ACTION_REF=32d396ac0f29135daf7fcb9964aba9d5f4e796d6
TMP_ROOT=$(fm_test_tmproot fm-no-mistakes-required)
VERIFY="$TMP_ROOT/verify.py"
OLD_SHA=1111111111111111111111111111111111111111
NEW_SHA=2222222222222222222222222222222222222222
SIGNATURE='Updates from [git push no-mistakes](https://github.com/kunchenguid/no-mistakes)'
COMPLETED_STEPS='[{"step":"review","status":"completed"},{"step":"test","status":"completed"},{"step":"document","status":"completed"}]'

# The verifier is vendored so this test never depends on the network.
# The vendored bytes are the pinned ACTION_REF revision's verify.py, bound by content hash.
VENDORED_VERIFIER="$(dirname "${BASH_SOURCE[0]}")/fixtures/no-mistakes-require-verify.py"
VENDORED_VERIFIER_SHA256=cd27df75b702ba34240b681b13dbaef51e84948cd4a61a6e654894fcec1a08d2
WORKFLOW="$(dirname "${BASH_SOURCE[0]}")/../.github/workflows/no-mistakes-required.yml"

load_shared_verifier() {
  local actual pinned
  command -v python3 >/dev/null 2>&1 || fail "python3 is required to exercise the pinned shared action"
  [ -s "$VENDORED_VERIFIER" ] || fail "the vendored shared action verifier is missing or empty: $VENDORED_VERIFIER"
  actual=$(python3 -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$VENDORED_VERIFIER") \
    || fail "could not hash the vendored shared action verifier"
  [ "$actual" = "$VENDORED_VERIFIER_SHA256" ] \
    || fail "vendored shared action verifier drifted from the pinned revision $ACTION_REF: sha256 $actual, expected $VENDORED_VERIFIER_SHA256"
  pinned=$(sed -n 's|.*require-no-mistakes@\([0-9a-f]\{40\}\).*|\1|p' "$WORKFLOW" | head -n 1)
  [ "$pinned" = "$ACTION_REF" ] \
    || fail "the workflow pins the shared action at '$pinned' but the vendored verifier is for $ACTION_REF; re-vendor the verifier and update ACTION_REF and its hash"
  cp "$VENDORED_VERIFIER" "$VERIFY"
  pass "vendored shared action verifier matches the pinned revision hash and the workflow pin"
}

run_verifier() {
  local body=$1 head=$2
  PR_BODY="$body" PR_HEAD_SHA="$head" PR_AUTHOR=regression PR_NUMBER=3006 \
    python3 "$VERIFY" 2>&1
}

test_matching_head_and_completed_steps_pass() {
  local body output rc
  body="$SIGNATURE
<!-- no-mistakes-pipeline-attestation:v1 {\"head_sha\":\"$NEW_SHA\",\"steps\":$COMPLETED_STEPS} -->"
  rc=0
  output=$(run_verifier "$body" "$NEW_SHA") || rc=$?
  expect_code 0 "$rc" "shared action rejected an attestation bound to the current PR head"
  assert_contains "$output" "Found structurally compliant pipeline step attestation." \
    "shared action did not report the matching attestation as compliant"
  pass "shared action accepts a matching head_sha with completed required steps"
}

test_mismatched_head_fails_with_both_shas() {
  local body output rc
  body="$SIGNATURE
<!-- no-mistakes-pipeline-attestation:v1 {\"head_sha\":\"$OLD_SHA\",\"steps\":$COMPLETED_STEPS} -->"
  rc=0
  output=$(run_verifier "$body" "$NEW_SHA") || rc=$?
  [ "$rc" -ne 0 ] || fail "shared action accepted an attestation from a different PR head"
  assert_contains "$output" "$OLD_SHA" \
    "mismatched-head failure did not name the attestation head SHA"
  assert_contains "$output" "$NEW_SHA" \
    "mismatched-head failure did not name the actual PR head SHA"
  pass "shared action rejects a mismatched head_sha and names both SHAs"
}

test_missing_head_fails() {
  local body output rc
  body="$SIGNATURE
<!-- no-mistakes-pipeline-attestation:v1 {\"steps\":$COMPLETED_STEPS} -->"
  rc=0
  output=$(run_verifier "$body" "$NEW_SHA") || rc=$?
  [ "$rc" -ne 0 ] || fail "shared action accepted an attestation without head_sha"
  assert_contains "$output" "structured pipeline step attestation" \
    "missing-head failure did not explain that the attestation is invalid"
  pass "shared action rejects an attestation with no head_sha"
}

load_shared_verifier
test_matching_head_and_completed_steps_pass
test_mismatched_head_fails_with_both_shas
test_missing_head_fails
