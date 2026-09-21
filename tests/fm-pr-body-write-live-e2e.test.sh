#!/usr/bin/env bash
# Credentialed regression for the pull-request-body write route every worker is
# handed in rule 3 of bin/fm-brief.sh's scaffold.
#
# A worker that finished with three findings tried to prepend them to its own
# pull request body, was refused with
# "GraphQL: <login> lacks permission for UpdatePullRequest", read that as an
# account limit, and stopped; the findings reached a file nobody reads. The
# account was never the problem. gh resolves a call that does not name a
# repository from the checkout's git remotes, and a checkout that also carries
# an `upstream` (or any second GitHub remote) can resolve to that one, so the
# edit reached a repository the account cannot write. Naming the repository is
# the entire fix.
#
# Nothing hermetic reaches that: a stub gh accepts exactly what the stub was
# written to accept, while the refusal comes from GitHub deciding what the
# RESOLVED repository permits. Only a real repository-scoped write proves the
# documented route still works, so this guard performs one and names the
# refusal it exists to catch.
#
# The write is content-neutral by construction: it reads the target body's
# exact bytes, writes those same bytes back, and verifies the round trip. It
# never writes anything it did not first read, and it targets the newest MERGED
# pull request on this checkout's own `origin` - terminal work no reviewer is
# mid-way through - rather than an open one.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# The shared gate is the live-harness family's one on/off contract. This guard
# submits no model prompts, but it does WRITE to a real repository, so it stays
# opt-in rather than running wherever gh happens to be installed.
fm_live_gate opt-in FM_PR_BODY_WRITE_LIVE_E2E gh

gh auth status >/dev/null 2>&1 || fail "gh is not authenticated"

TMP_ROOT=$(fm_test_tmproot pr-body-write-live)

# The repository under test is this checkout's own origin, so the guard follows
# whichever repository the fleet actually ships from instead of pinning one.
ORIGIN_URL=$(git -C "$ROOT" remote get-url origin 2>/dev/null) \
  || fail "this checkout has no origin remote to resolve a repository from"
case "$ORIGIN_URL" in
  *github.com[:/]*) ;;
  *)
    printf 'skip: live: origin (%s) is not a github.com remote\n' "$ORIGIN_URL"
    exit 0
    ;;
esac
NWO=${ORIGIN_URL##*github.com}
NWO=${NWO#[:/]}
NWO=${NWO%.git}
case "$NWO" in
  */*) ;;
  *) fail "could not read an <owner>/<repo> out of origin ($ORIGIN_URL)" ;;
esac

PR=$(gh pr list --repo "$NWO" --state merged --limit 1 --json number --jq '.[0].number' 2>&1) \
  || fail "could not list merged pull requests on $NWO: $PR"
case "$PR" in
  '' | null) fail "no merged pull request on $NWO to exercise the PR-body write route against" ;;
  *[!0-9]*) fail "unexpected pull request number from $NWO: $PR" ;;
esac

BEFORE="$TMP_ROOT/before.md"
AFTER="$TMP_ROOT/after.md"
JQ_READ="$TMP_ROOT/jq-read.md"
EXPECT_JQ="$TMP_ROOT/expect-jq.md"

test_repository_scoped_route_patches_a_pr_body() {
  local out status=0

  # Read first and write only what was read: an unreadable body must abort
  # before the write, never write an empty one over it.
  gh api "repos/$NWO/pulls/$PR" --template '{{.body}}' > "$BEFORE" 2>"$TMP_ROOT/read.err" \
    || fail "could not read $NWO#$PR's body back as data: $(cat "$TMP_ROOT/read.err")"

  out=$(gh api -X PATCH "repos/$NWO/pulls/$PR" -F "body=@$BEFORE" --jq .number 2>&1) || status=$?
  if [ "$status" -ne 0 ]; then
    case "$out" in
      *"lacks permission"* | *UpdatePullRequest* | *"Resource not accessible"* | *"HTTP 403"*)
        fail "the documented PR-body write route was refused on $NWO#$PR as a permissions error - the exact regression this guard exists for, and it means the call reached a repository the account cannot write: $out"
        ;;
      *)
        fail "the documented PR-body write route failed on $NWO#$PR: $out"
        ;;
    esac
  fi

  gh api "repos/$NWO/pulls/$PR" --template '{{.body}}' > "$AFTER" 2>"$TMP_ROOT/verify.err" \
    || fail "could not re-read $NWO#$PR's body after writing it: $(cat "$TMP_ROOT/verify.err")"
  cmp -s "$BEFORE" "$AFTER" \
    || fail "writing $NWO#$PR's own bytes back did not round-trip: the documented read and write forms disagree about the body"
  pass "the repository-scoped route patches a pull request body on $NWO and round-trips it exactly"
}

test_template_read_is_the_exact_body_and_jq_is_not() {
  # The scaffold tells workers to read a body with --template because --jq
  # appends a newline the body does not have, so a read-edit-write round trip
  # grows the body every time it runs. Pin both halves of that claim: if gh
  # ever stops adding it, the instruction is wrong and should change with it.
  gh api "repos/$NWO/pulls/$PR" --template '{{.body}}' > "$EXPECT_JQ" 2>"$TMP_ROOT/tpl.err" \
    || fail "could not read $NWO#$PR's body with --template: $(cat "$TMP_ROOT/tpl.err")"
  gh api "repos/$NWO/pulls/$PR" --jq .body > "$JQ_READ" 2>"$TMP_ROOT/jq.err" \
    || fail "could not read $NWO#$PR's body with --jq: $(cat "$TMP_ROOT/jq.err")"
  printf '\n' >> "$EXPECT_JQ"
  cmp -s "$JQ_READ" "$EXPECT_JQ" \
    || fail "--jq .body is no longer exactly the --template body plus one newline, so the brief's read guidance no longer matches gh"
  pass "--template '{{.body}}' reads the exact body and --jq .body appends one newline"
}

test_repository_scoped_route_patches_a_pr_body
test_template_read_is_the_exact_body_and_jq_is_not
